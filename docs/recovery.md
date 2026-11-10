# Stack recovery (Windows host)

The devcontainer's `postStartCommand` restores, in this order, the firewall, cron, the user-space config
(`bin/container-start.sh`: crontab, OpenCode user config, Hermes SOULs, hooks and toolsets) and the Hermes gateway tmux
session (`hermes`, running `bin/hermes-gateway-loop.sh`). The firewall must succeed: if it fails, nothing else runs, no
gateway starts and the command exits non-zero; `init-firewall.sh` then leaves every policy at DROP, so the network stays
closed until a later run succeeds. A cron or `container-start.sh` failure is logged, the gateway still starts, and the
command exits non-zero. Each `container-start.sh` step is non-fatal; a failed Hermes apply step also sends one #alerts
line an hour ("guards may not be registered"). It runs on **VS Code reopen** and **`devcontainer up`**,
but **not** on a plain `docker start`: a Docker Desktop restart, update or restart policy can bring the container back
without the firewall (egress unfiltered), without cron, and without the gateway, or leave it stopped.
The in-container watchdogs (cron `bin/watchdog.sh`, the gateway restart loop) cannot help when the container is down.

Two Windows Task Scheduler tasks close that gap. Both start **at system startup** and run **whether or not you are
logged on**, with no auto-logon. The tasks themselves need no logon, but the Docker Desktop engine they depend on does
not reliably come up without one: see "Headless status" below. Both run `docs/stella-recover.ps1`, which is idempotent
and runs one at a time: a named lock (`Global\StellaRecover`) makes a second concurrent run wait 15 s, log
`another recovery run is active` and exit 0.
`-WorkspaceFolder` (the repo root on the host) is optional; by default it is the parent of the script's folder.

0. checks that Ollama answers on `<OllamaUrl>/api/tags` (default `http://localhost:11434`, override with `-OllamaUrl`)
   within 5 s. If not, it finds `ollama.exe` (in order: `-OllamaExe`, the per-user
   `%LOCALAPPDATA%\Programs\Ollama\ollama.exe`, `ollama` on PATH, `%ProgramFiles%\Ollama\ollama.exe`), logs
   `ollama silent: launching <path>`, starts `ollama serve` hidden, and polls every 5 s for up to 120 s, logging
   `ollama ok` or `ollama did not answer within 120s` (or `ollama not found`). An Ollama failure never stops the
   steps below; it only makes the script exit 1 at the end;
1. waits (retrying every 10 s, up to 10 min) until `docker info` answers. **Power-on fix:** if it has not answered
   after 60 s, the script launches Docker Desktop, at most once per boot (the launch time is kept in
   `%LOCALAPPDATA%\stella-recover.docker-launch`; a launch after the current boot time means this boot already had one):
   `-DockerDesktopExe` if given, otherwise the first that exists
   of `%LOCALAPPDATA%\Programs\DockerDesktop\Docker Desktop.exe` (per-user install) and
   `%ProgramFiles%\Docker\Docker\Docker Desktop.exe` (all-users install). It logs the path it launched, or
   `Docker Desktop not found`, then keeps waiting up to the same 10-minute limit;
2. finds the container among all containers (`docker ps -a`) with a `devcontainer.local_folder` label whose value
   equals the repo path, case-insensitively and ignoring trailing backslashes: a running one if any, otherwise the
   most recently created stopped one. A stopped one is started with `docker start` (step 3 then re-runs the
   postStart steps); only if no container exists at all, it runs `devcontainer up --workspace-folder <repo path>`,
   which needs the devcontainer CLI, and fails with a log line if the CLI is missing. A failed `docker ps` or
   `docker inspect`, or inspect output that does not parse, exits 1 and never falls through to `devcontainer up`;
   nor does a `devcontainer up` still running from an earlier run (logged `a devcontainer up is still running`).
   A path mismatch still does: a container whose label differs from the repo path is not found, and `devcontainer up`
   creates a second one, so check the label once (Prerequisites);
3. runs the firewall probe (below) as root in the container. If any check fails (a plain `docker start`, a firewall run
   that failed and left only the DROP policies, or an old or half-applied ruleset), it logs `firewall probe failed:
   <tokens>`, then `firewall missing in <id>: re-running the postStart steps`, and re-runs `init-firewall.sh` via
   `docker exec`; if that fails, the run exits 1 before step 4 (the network stays closed, no gateway is started). It
   probes again right after: if the ruleset still fails, it logs `firewall still failing after re-apply: <tokens>`,
   adds `firewall (<tokens>)` to the failures and does not loop. Then `service cron start` and
   `bin/container-start.sh`: a failure of either is logged, step 4 still runs, and the run ends with a
   `FAILED container=... gateway-session=hermes: <steps>` line and exit 1;
4. checks `tmux has-session -t hermes` via `docker exec -u node`; recreates the session if missing and re-checks. It
   checks the session only, not whether the gateway is connected to Discord: the in-container watchdog
   (`bin/watchdog.sh`) alerts #alerts while Hermes is not paused when the gateway process is gone (**STL-GW-101**),
   when the newest connection line in `gateway.log` is a disconnect (**STL-GW-102**), or when it cannot tell
   (**STL-GW-103**). A log that is merely quiet is not an alert (D47). What it reads (process, logs, connection markers,
   thresholds) is in `docs/hermes-local/watchdog-settings.json`; `bin/watchdog_settings.py gateway` prints the verdict.

After a run that restarted something (container started or created, firewall re-applied, gateway session recreated),
it posts one #alerts message through `docker exec ... /workspace/bin/alert.sh` (D44): **STL-RCV-502** "Stella was
restarted by the recovery script", naming what was restarted and the minutes down, counted from the last ok run (kept
in `%LOCALAPPDATA%\stella-recover.lastok`), or **STL-RCV-503** when step 3 failures remain (it names them), or **STL-RCV-504** "Stella's network protection is
incomplete" when the firewall still fails the probe after the re-apply (see below). The wording
lives in `docs/hermes-local/alert-catalog.json` (see `docs/alert-codes.md`). The send's exit code is logged; a failed
send, or a container that cannot run `alert.sh`, never fails the run and posts nothing else.

### The firewall probe (step 3) and STL-RCV-504

The probe is one constant in `docs/stella-recover.ps1`, between the comments `# FIREWALL-PROBE-BEGIN` and
`# FIREWALL-PROBE-END`, run as `docker exec -u root <id> sh -c <probe>` with `iptables -S`, `ip6tables -S` (when
installed) and `ipset list -n`. It is inline on purpose: `bin/` is writable by the node user, so root never executes a
repo file on this path. It passes only when all of these hold; each failed check prints one short token and the probe
exits 1:

| Token | Check |
|---|---|
| `policy` | INPUT, OUTPUT and FORWARD policies are all DROP |
| `web443` | every rule that accepts the `allowed-domains` set is `tcp` and `dport 443`, and there is at least one |
| `ssh` | every tcp/22 accept is matched against the `github-ssh` set (no open `--dport 22 -j ACCEPT`) |
| `lan` | no accept rule for a /24 or /16 network |
| `dns` | every accept for port 53 names a nameserver address (never `0.0.0.0/0` or no address) |
| `reject` | the last OUTPUT rule is `-j REJECT` |
| `ollama` | the tcp/11434 accept to a named address exists |
| `ipv6` | the IPv6 policies are DROP (skipped when `ip6tables` is not installed) |
| `sets` | both `allowed-domains` and `github-ssh` exist |
| `unchecked` | (made by the script) the probe could not run at all |

It checks rule shapes and set names only: no host, provider, id or path, so it passes unchanged after hosts are added
to the allowlist. `bin/firewall-probe-selftest.sh` runs it against stubs, with the passing ruleset taken from what
`init-firewall.sh` records under the stubs of `bin/init-firewall-selftest.sh`. It cannot prove real iptables behaviour:
that is the drill below.

**STL-RCV-504** replaces STL-RCV-503 for this one case. The script calls `alert.sh STL-RCV-504 parts=<tokens>`
(sorted, comma separated, no spaces); the catalog turns each token into a plain phrase (the table is in
`docs/alert-codes.md`; a new token is a catalog edit). The same alert for the same sorted tokens is sent at most once
every 6 hours: the time and tokens are kept in `%LOCALAPPDATA%\stella-recover.firewall-alert`, and a repeat logs
`alert STL-RCV-504 not sent again within 6 hours: ...`. The log lines `firewall probe failed: ...` and
`firewall still failing after re-apply: ...` are written on every run; only the alert is limited. A failed send does not
start the 6 hours. See the alert text once with `bin/alert.sh --sample STL-RCV-504` (posts a sample to #alerts).

**Adding a provider host.** Edit the allowlist in `.devcontainer/init-firewall.sh` (the single `for domain in ...` list),
rebuild the image, recreate the container, run `bin/firewall-check.sh` as root. The probe needs no change. A host on a
port other than 443 needs a new rule, which the probe does not know yet: see `docs/stella-app-wiring-notes.md`.

Every external call (`docker`, `devcontainer`, and `tmux` and `hermes` through `docker exec`) runs in a background job
under a time limit: a hung call is abandoned with `timed out after N s: <command>` and counts as a failure (exit code
124). Before every call `$LASTEXITCODE` is -1, so a missing command never reads as a stale 0.
It logs to `%LOCALAPPDATA%\stella-recover.log` (the task user's profile), every line in UTF-8 through
`Out-File -Encoding utf8` (no mix of UTF-16 redirection and plain text), and exits non-zero on any failure, which shows
as the task's "Last Run Result". Steps 1 to 4 exit 1 at the first failure, except the step 3 cron and
`container-start.sh` failures described above; an Ollama failure (step 0) exits 1 only after steps 1 to 4 have run,
with the log line `exit 1: ollama did not answer`. `-SelfTest` checks the time limit, exit codes, lock and marker
times without touching Docker (see Verify).

| Task | Trigger | Purpose |
|---|---|---|
| **Stella Startup Recovery** | At startup | Bring the stack up after a reboot, with or without a logon |
| **Stella Watchdog** | At startup, then every 15 minutes, indefinitely | Catch a Docker restart or update, a stopped container, a missing firewall, or a missing gateway session between reboots |

## Headless status (no logon after a reboot)

- **2026-10-26 morning, reboot 1: FAIL.** The bot showed online at first (Discord presence lag), a test message 5
  minutes after the reboot with nobody logged on got no reply, and the bot then went offline. Bot presence proves
  nothing; only a reply to a message counts.
- **2026-10-26 evening, after the fixes below: mechanism proven in principle.** Reboot 3: boot 22:35, answer 22:40,
  logon 22:41. Reboot 4: boot 22:46, container ok 22:48:20, answers 22:51 to 22:53, logon 23:08. These passes predate
  later changes to this script and do not count as the final test; the final no-logon test is redone after the freeze.
- Docker documents Docker Desktop autostart only as a sign-in behaviour and documents no pre-logon mode. Launching it
  from the task (step 1) runs it in Session 0: **unsupported by Docker, but it passed** reboots 3 and 4.
- A headless fix that keeps every constraint (Docker Engine in a dedicated WSL2 distro instead of Docker Desktop) is a
  Docker architecture change and is **not adopted**: it needs a human decision and is blocked on open questions,
  including where `devcontainer up` runs.

### Verified causes of the morning failure, in order

1. **Broken task arguments.** `ExecutionPolicy` was missing its dash, and the then-mandatory `-WorkspaceFolder` was
   missing, so `powershell.exe` never ran the script and no log was created. `-WorkspaceFolder` is now optional.
2. **Docker Desktop path.** Docker Desktop is installed per-user (`%LOCALAPPDATA%\Programs\DockerDesktop`), not in
   Program Files; the script now checks the per-user path first.
3. **devcontainer CLI missing**, and a stale `$LASTEXITCODE` from an earlier command was read as 0, so a step that
   never ran "succeeded" in 0.2 seconds. The script now checks the CLI first and resets the exit code before each call.
4. **VS Code WSLg Wayland socket mount.** The container was created with a `/tmp/vscode-wayland-*.sock` mount, which
   does not exist after a reboot, so `docker start` failed. Check that the container's mounts are only the ones in
   `.devcontainer/devcontainer.json` (the `/commandhistory`, `/home/node/.claude` and `/home/node/.hermes` volumes, the
   read-only `/plan` bind and the `/workspace` bind), with no `/tmp/vscode-wayland-*.sock` line:
   `docker inspect -f "{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}" <container>`.
5. **Ollama started only at sign-in.** The script now starts `ollama serve` when port 11434 is silent and waits up to
   120 s.
6. **Docker Desktop autostart is sign-in only.** The script launches it after 60 s of silence (Session 0, see above).

### Session 0

Tasks set to "Run whether user is logged on or not" run in Session 0: non-interactive, no desktop. Docker Desktop and
`ollama serve` started by the task live there, keep running after you sign in, and have no tray icon. After sign-in,
Windows startup apps would start a second, idle Ollama in Session 1: disable Ollama in Task Manager, Startup apps.
Check with `Get-Process "Docker Desktop",ollama -EA 0 | Select-Object Name, SessionId, StartTime` (SessionId 0 =
started by the task).

### After a boot

The gateway needs about 2 minutes after boot. Discord does not redeliver messages sent before it is connected, so a
message sent at T+0 to T+2 is dropped and proves nothing; test at T+5 and T+15.

## Prerequisites (host)

- **A Docker engine that answers without an interactive logon.** Docker Desktop normally starts its engine only when
  you sign in, so at a startup with nobody logged on `docker info` would never answer. The script's launch attempt
  after 60 s of silence is unsupported by Docker: the 2026-10-26 morning no-logon test (reboot 1) failed, reboots 3
  and 4 passed with it (see "Headless status").
- Docker Desktop installed per-user (`%LOCALAPPDATA%\Programs\DockerDesktop\Docker Desktop.exe`) or for all users
  (`%ProgramFiles%\Docker\Docker\Docker Desktop.exe`); the script finds either. If it is elsewhere, add
  `-DockerDesktopExe "<full path>"` to the task argument. The script logs `Docker Desktop not found` instead of
  guessing. Ollama likewise: `-OllamaExe "<full path>"` if it is not on PATH or in either standard folder.
- Dev Containers CLI on the task user's PATH: `npm install -g @devcontainers/cli` (check: `devcontainer --version`
  in a new PowerShell). The task runs with that user's profile and environment, so a per-user npm global works.
- The repo path must match the container's `devcontainer.local_folder` label, apart from letter case and trailing
  backslashes. The default (the script's repo root) does when the tasks run the script from the repo itself. Check
  once: `docker ps -a --filter label=devcontainer.local_folder --format "{{.ID}} {{.State}} {{.Labels}}"`.

## Security settings (both tasks)

- **Run whether user is logged on or not**, as **your own Windows account**, with the Windows password stored by
  Task Scheduler. Not SYSTEM: Docker's context and the devcontainer CLI belong to your user.
- **Run with highest privileges: off** (run level Limited). Docker Desktop's CLI does not need elevation; raise this
  only if a run fails with a permission error, and record why.
- The password is typed once into a credential prompt and stored by Task Scheduler. It is never written into this
  repo, a script, or a log, and is never pasted to an agent. If you change your Windows password, update the stored
  one (re-run the registration below).
- No auto-logon is configured or required.

## Register the tasks (PowerShell, as your user, not elevated)

`Register-ScheduledTask` with `-User` and `-Password` creates a "Run whether user is logged on or not" task
(logon type Password).

```powershell
$repo   = "<repo root on the host>"   # must match the devcontainer.local_folder label (case-insensitive)
$script = Join-Path $repo "docs\stella-recover.ps1"
$cred   = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message "Windows password for the Stella recovery tasks"
$plain  = $cred.GetNetworkCredential().Password   # handed to Task Scheduler only; not stored anywhere else

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""
# With IgnoreNew ("do not start a new instance"), a hung run blocks every later Watchdog run until this limit.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstancesPolicy IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

# Task 1: Stella Startup Recovery, at system startup.
Register-ScheduledTask -TaskName "Stella Startup Recovery" -Action $action `
  -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $settings `
  -User $cred.UserName -Password $plain -RunLevel Limited

# Task 2: Stella Watchdog, at system startup and then every 15 minutes, indefinitely.
$watch = New-ScheduledTaskTrigger -AtStartup
$watch.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)).Repetition
Register-ScheduledTask -TaskName "Stella Watchdog" -Action $action -Trigger $watch -Settings $settings `
  -User $cred.UserName -Password $plain -RunLevel Limited

Remove-Variable plain, cred
```

The resulting task argument, for a repo at `C:\stack` (yours is `OWNER_STACK_PATH_WIN` in `config/owner.env`), is exactly:
`-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\stack\docs\stella-recover.ps1"`.
Triggers are At startup only (no At logon trigger).

If you previously registered the old logon-based tasks ("Stella recover at logon", "Stella watch every 15 min"),
remove them first so two copies do not run:
`Unregister-ScheduledTask -TaskName "Stella recover at logon","Stella watch every 15 min" -Confirm:$false`.

## Verify

```powershell
# Settings: LogonType must be Password (run whether logged on or not), RunLevel Limited, triggers at startup.
Get-ScheduledTask -TaskName "Stella Startup Recovery","Stella Watchdog" |
  Select-Object TaskName, @{n="LogonType";e={$_.Principal.LogonType}}, @{n="RunLevel";e={$_.Principal.RunLevel}},
                @{n="Triggers";e={($_.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ","}},
                @{n="Repetition";e={($_.Triggers | ForEach-Object { "$($_.Repetition.Interval)/$($_.Repetition.Duration)" }) -join ","}}
# Repetition: the Watchdog must show PT15M before the slash; after it, an empty Duration means indefinitely, while a
# value such as P1D means the repetition stops after that long. The Startup task shows "/" (no repetition).

# The script itself, once after every change to it: a parse check (no output = it parses), then its self-test
# (ends with "selftest PASS"; it writes only %TEMP%\stella-recover-selftest.*, never touches Docker).
$repo = "<repo root on the host>"
$e = $null; [System.Management.Automation.Language.Parser]::ParseFile("$repo\docs\stella-recover.ps1", [ref]$null, [ref]$e) | Out-Null; $e
powershell -NoProfile -ExecutionPolicy Bypass -File "$repo\docs\stella-recover.ps1" -SelfTest

# A run now:
Start-ScheduledTask -TaskName "Stella Watchdog"; Start-Sleep 30
Get-ScheduledTaskInfo -TaskName "Stella Watchdog" | Select-Object LastRunTime, LastTaskResult   # 0 = ok
Get-Content "$env:LOCALAPPDATA\stella-recover.log" -Tail 5
```

Failure drills:
- `docker stop <id>`, then run the Watchdog: the log shows `container stopped: docker start <id>`, then
  `firewall missing … re-running the postStart steps`, then `ok … gateway-session=hermes`.
- `docker restart <id>` (plain start, no postStart), then run the Watchdog: the log shows `firewall probe failed: <tokens>`, then `firewall missing … re-running the postStart steps`.
- Firewall probe drill: as root in the container, `iptables -I OUTPUT 1 -p tcp --dport 22 -j ACCEPT`, then run the Watchdog: `firewall probe failed: ssh`, the re-apply lines, one **[STL-RCV-502]** alert (no STL-RCV-504: the re-apply fixes it), then `ok …`. Afterwards `iptables -S OUTPUT | grep -c 'dport 22 -j ACCEPT'` shows only the `github-ssh` rule (1) and `bin/firewall-check.sh` passes.
- In the container, `tmux kill-session -t hermes`, then run the Watchdog: the log shows `recreating`.
- Each drill that restarts something also posts one #alerts message, **[STL-RCV-502]** "Stella was restarted by the
  recovery script", and the log shows `recovered alert sent rc=0: STL-RCV-502 restarted=...`.

Firewall (T11), from the host, as root because node cannot read iptables: every line `PASS`, last line
`firewall-check PASS` (exit 0). It is read-only: TCP connects, one DNS query and `iptables -S`.
`docker exec -u root <id> /workspace/bin/firewall-check.sh`

### No-logon reboot test

Before: record both tasks' state (`Get-ScheduledTaskInfo` below) and the tail of `%LOCALAPPDATA%\stella-recover.log`.

1. Use **Start > Restart**, not Shut down (Fast Startup's hybrid boot may not behave like a clean boot for an
   At startup trigger). Do not sign in, unlock, or use RDP: RDP counts as a logon.
2. At **T+5 min** and again at **T+15 min**, from your phone, send unique messages to #supervisor, for example
   `headless-T5-<time>` and `headless-T15-<time>`.
3. Result: a reply at T+5 and T+15 is **PASS**; no reply at T+5 but a reply at T+15 is **PASS, slow** (record the
   latency); no reply at T+15 is **FAIL**. Bot presence counts for nothing either way.
4. A PASS also needs post-logon evidence that the task `LastRunTime`, the container `StartedAt`, the gateway process
   start time and the Discord READY line are all after boot and before your logon.

### Diagnostics, in failure order (stop at the first step that fails: that is the root cause)

Reference times first, in PowerShell: boot `(Get-CimInstance Win32_OperatingSystem).LastBootUpTime`, your logon
`quser`. Anything that started after your logon did not happen headless.

1. Did the task run? `Get-ScheduledTaskInfo -TaskName "Stella Startup Recovery","Stella Watchdog" | fl TaskName,LastRunTime,LastTaskResult,NumberOfMissedRuns`
   and `(Get-ScheduledTask "Stella Watchdog").Principal | fl UserId,LogonType,RunLevel` (expect Password, Limited).
   `LastTaskResult`: `0x41303` never ran; `0x8007052E` bad username or password (re-enter it yourself in Task
   Scheduler's own prompt); `0x80070569` logon type not granted (batch right missing); `0x1` the script exited 1
   (for example the Docker timeout); `0x0` success. Account type: `Get-LocalUser $env:USERNAME | fl Name,PrincipalSource`
   (MicrosoftAccount: the task password is the Microsoft account password, never the PIN).
2. Task ran, Docker silent: `stella-recover.log`;
   `Get-Process "Docker Desktop",com.docker.backend -EA 0 | select Name,StartTime` (StartTime after logon means the
   engine started only after sign-in); `wsl -l -v`; Docker Desktop logs in `%LOCALAPPDATA%\Docker\log`.
3. Docker answered, `devcontainer up` failed: `docker ps -a --format "{{.Names}} {{.Status}}"` and
   `docker inspect -f "{{.State.StartedAt}} {{.State.ExitCode}}" <container>`.
4. Container up, gateway loop failed (container terminal): `tmux ls`; `ps -eo lstart,cmd | grep -i hermes`;
   `head -3 ~/.hermes/logs/gateway-restarts.log`. Firewall, from the host (node has no sudo for iptables):
   `docker exec -u root <id> iptables -S OUTPUT` (expect `-P OUTPUT DROP` and the
   `--dport 443 -m set --match-set allowed-domains dst -j ACCEPT` rule), or the full check
   `docker exec -u root <id> /workspace/bin/firewall-check.sh`.
5. Gateway up, Discord disconnected (container terminal): `getent hosts discord.com gateway.discord.gg`;
   `curl -s -o /dev/null -w "%{http_code}\n" https://discord.com/api/v10/gateway`; the last connect, disconnect and
   DNS lines in `~/.hermes/logs/gateway.log`, by timestamp:
   `grep -E '\[Discord\] (Connected as|Disconnected)|discord reconnected successfully|Name or service not known' ~/.hermes/logs/gateway.log | tail -5`
   (Hermes v0.22.5 logs no READY or RESUMED lines).
6. Also: Security log events 4624 or 4625 for your account, logon type 4 (batch), after boot.

## Owner config (`config/owner.env`)

The owner's name, Discord ids, Windows stack path and GitHub owner live in `config/owner.env` (D39), never in a tracked
file. It sits in the host folder, so it survives a container rebuild, but it is not in git: after a fresh clone,
recreate it from the example, fill it in, and make it and its folder read-only (D40; a builder that runs as the same
user can still `chmod` them back, so this stops accidents, not a determined worker):

```bash
cp config/owner.example.env config/owner.env   # then edit the values
chmod 555 config; chmod 444 config/owner.env
bin/owner-config.sh --check    # offline: keys present, ids are 17-20 digits, path non-empty
bin/owner-config.sh --verify   # read-only Discord GETs: channels exist, the owner is a member of the server
bin/apply-hermes-local.sh      # renders the SOULs and the board description from it
```

Keys: `OWNER_NAME`, `OWNER_DISCORD_USER_ID`, `OWNER_STACK_PATH_WIN`, `GITHUB_OWNER`, `DISCORD_GUILD_ID`,
`ESCALATIONS_CHANNEL_ID`, `SUPERVISOR_CHANNEL_ID`. Ids, names and a path only: never a token or secret (the Discord bot
token stays in Hermes's own secret store). Optional: `OWNER_TIMEZONE` (an IANA name such as `America/Toronto`) for the
times in #alerts messages; unset means the container's `TZ`, then UTC (D44). Without the file, escalation scripts log
`OWNER_CONFIG_MISSING`, post one #alerts message an hour (**STL-CFG-301**), and exit non-zero.

Only `OWNER_DISCORD_USER_ID`'s thread replies and 🔒/🗑️ reactions are applied; with the id empty or malformed, nobody's are (D72). If #alerts shows **STL-ESC-240**
("ignored a reply from someone else") or **STL-CFG-302**, or your own replies stop working, fix the id (the poller re-reads the file on every poll, no restart;
an ignored reply is not marked seen, so it is applied on the next poll after the fix):

```bash
chmod u+w config config/owner.env
# edit OWNER_DISCORD_USER_ID (Discord: Settings > Advanced > Developer Mode, then right-click your name > Copy User ID)
chmod 555 config; chmod 444 config/owner.env
```

Editing the file from Windows (Explorer or an editor on the host folder) needs none of these steps: the modes apply
inside the container only. `config/` at 555 also means a `git checkout` or `git pull` that changes
`config/owner.example.env` needs `chmod u+w config` first, then `chmod 555 config` again.

## The OS box host file (option A, D73)

Boxed worker terminals (bubblewrap) need two lines in `runArgs` of `.devcontainer/devcontainer.json`:
`--security-opt seccomp=${localWorkspaceFolder}/.devcontainer/seccomp-userns.json` (Docker's default profile plus one
entry for `clone`, `unshare`, `mount`, `umount2`, `pivot_root`) and `--security-opt systempaths=unconfined`. The seccomp
file is read by **Docker on the host** when the container starts. If the file is missing, unreadable or not valid JSON,
`docker start` or `devcontainer up` fails and the container does not come up: `stella-recover.log` shows
`docker start failed rc=...` (or the `devcontainer up` error) and the script now adds the hint line
`seccomp file`. Fix, in this order:

1. Restore `.devcontainer/seccomp-userns.json` from the repo (it is kept in the repo as a whole file, so a rebuild needs no network; it stays untracked until the `.devcontainer` change is committed, so commit it with that change). Then
   `Start-ScheduledTask "Stella Startup Recovery"`.
2. If the container must come up without the box: edit `devcontainer.json` on the host, remove the two
   `--security-opt` lines from `runArgs`, and rebuild. Boxed terminals then **refuse to run** (fail closed, not
   unboxed). To go back to unboxed terminals as well, in a container shell set `sandbox.boxed_profiles` to `[]` in
   `docs/hermes-local/roles.json` and run `bin/apply-hermes-local.sh` (each profile's `terminal.backend` returns to
   `local`). Do that first when the container is still running: reverting the host lines first leaves boxed profiles refused
   until they are applied.

The box adds no Windows-side task and changes none of the two tasks; `.devcontainer/` stays human-gated.

## The fallback gateway (OmniRoute, D83, D93)

When `docs/hermes-local/fallback-routing.json` has `enabled: true`, `bin/container-start.sh` starts the gateway at container start (`bin/omniroute-ctl.sh start`, in the background; its log is `.scratch/omniroute-start.log`). If it is not up, a rerouted call fails and queues as before; start it with `bin/omniroute-ctl.sh start` and check it with `bin/omniroute-ctl.sh status` (4 ok lines). It needs the endpoint key file and the admin password the owner set in its dashboard; neither is in the repo.

## If Discord is down: what answers an approval (T12, D79)

Nothing in a terminal answers a tool approval. Checked on this stack (Stage 6 closeout, with `hermes pause` on and a DM from a second account): `hermes pairing list/approve` only handles access codes for people, never a command approval; the gateway's control socket has no verb that answers an approval; and with an allow-list set the Discord bot drops a stranger's DM before it offers a code, so a new account cannot even get one. A command approval that is already waiting in the gateway is answered by the Discord button or `/approve`, and `hermes pause` does not stop that answer (it holds new turns). If Discord or the gateway is down, a waiting approval stays unanswered and the worker waits or times out: use `hermes resume`, fix the gateway (the sections above), and ask again. The Stella app's inbox is the planned second path and is not built.

## Notes

- **Image-baked files.** `.devcontainer/init-firewall.sh` and `.devcontainer/managed-settings.json` are copied into the
  image at build time (`/usr/local/bin/init-firewall.sh`, `/etc/claude-code/managed-settings.json`); postStart and step
  3 run the image copy. An edit to either takes effect only after an image rebuild and container recreate (VS Code:
  Dev Containers: Rebuild Container), as does a `devcontainer.json` change. Step 3's probe (QB2-4) fails the pre-rebuild
  ruleset (its allowlist rule has no port, tcp/22 is open): a container on an old image re-applies the old script and
  then raises STL-RCV-504 (at most every 6 hours) until the rebuild; `bin/firewall-check.sh` shows which ruleset is live. `bin/container-start.sh` and this script are read from the repo at every run.
- Supervisor rules live in `/workspace/SUPERVISOR.md` and the `ai-stack` Kanban board description, **not** in Hermes
  memory: gateway memory may not inject on messaging channels (open issue 96134).
- **Discord outages: container DNS, not stale IPs.** `grep -c` over the whole `gateway.log` counted 339
  `Name or service not known` lines in the Part A audit and 372 in Part B2 (2026-10-28; each failed connect logs several
  such lines), 40 `timed out` and 0 `No route to host` (the firewall REJECT signature), and the
  cron poller logged the same DNS error, so the gateway could not resolve discord.com. Re-resolving the allowlist (a
  container restart) does not fix that. During an outage, in the container: `getent hosts discord.com
  gateway.discord.gg` and `cat /etc/resolv.conf`; on the host, whether Docker Desktop's DNS answers. The root cause is
  not known. DNS is allowed only to the `/etc/resolv.conf` nameservers read when the firewall starts: if that file
  changes later, re-run the firewall (restart the container).
- **Discord IP allowlist staleness (a separate, rarer case).** The firewall resolves its allowed hosts (including
  discord.com and gateway.discord.gg) to IPs once, at container start. If Discord moves to new IPs, the gateway logs
  `No route to host` until the next container start re-resolves them (a container restart, or step 3 of this script
  after one).
