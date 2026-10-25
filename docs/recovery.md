# Stack recovery (Windows host)

The devcontainer's `postStartCommand` restores the firewall, cron, the OpenCode user config, and the Hermes gateway
tmux session (`hermes`, running `bin/hermes-gateway-loop.sh`). It runs on **VS Code reopen** and **`devcontainer up`**,
but **not** on a plain `docker start`: a Docker Desktop restart, update or restart policy can bring the container back
without the firewall (egress unfiltered), without cron, and without the gateway, or leave it stopped until the next logon.
The in-container watchdogs (cron `bin/watchdog.sh`, the gateway restart loop) cannot help when the container is down.

Two Windows Task Scheduler tasks close that gap. Both run `docs/stella-recover.ps1`, which is idempotent:

1. waits (retrying every 10 s, up to 10 min) until `docker info` answers;
2. if no running container carries `label=devcontainer.local_folder=<repo path>`, runs
   `devcontainer up --workspace-folder <repo path>` (starts it and runs postStartCommand);
3. if the firewall's `-P OUTPUT DROP` policy is missing (plain `docker start`), re-runs `init-firewall.sh`,
   `service cron start` and `bin/container-start.sh` via `docker exec`;
4. checks `tmux has-session -t hermes` via `docker exec -u node`; recreates the session if missing and re-checks.

It logs to `%LOCALAPPDATA%\stella-recover.log` and exits non-zero on any failure (visible as "Last Run Result").

## Prerequisites (host)

- Docker Desktop, signed in as the same Windows user that runs the tasks.
- Dev Containers CLI on the host PATH: `npm install -g @devcontainers/cli` (check: `devcontainer --version`).
- The repo path exactly as the devcontainer label stores it. Check once:
  `docker ps --format "{{.ID}} {{.Label \"devcontainer.local_folder\"}}"`. Use that string as `-WorkspaceFolder`.

## Register the tasks (PowerShell, as your user, not elevated)

```powershell
$repo   = "C:\path\to\Stella"   # exactly the devcontainer.local_folder label value
$script = Join-Path $repo "docs\stella-recover.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -WorkspaceFolder `"$repo`""
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstancesPolicy IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 20)

# Task 1: at logon (Docker Desktop starts after logon; the script waits for it).
Register-ScheduledTask -TaskName "Stella recover at logon" -Action $action `
  -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME) -Settings $settings

# Task 2: every 15 minutes, so a Docker restart or update does not leave the stack down until the next logon.
$every15 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15)
Register-ScheduledTask -TaskName "Stella watch every 15 min" -Action $action -Trigger $every15 -Settings $settings
```

## Verify

```powershell
Start-ScheduledTask -TaskName "Stella watch every 15 min"; Start-Sleep 30
Get-ScheduledTaskInfo -TaskName "Stella watch every 15 min" | Select-Object LastRunTime, LastTaskResult   # 0 = ok
Get-Content "$env:LOCALAPPDATA\stella-recover.log" -Tail 5
```

Failure drills:
- `docker stop <id>`, then run the task: the log shows `devcontainer up`, then `ok … gateway-session=hermes`.
- `docker restart <id>` (plain start, no postStart), then run the task: the log shows `firewall missing … re-running the postStart steps`.
- In the container, `tmux kill-session -t hermes`, then run the task: the log shows `recreating`.

## Notes

- Supervisor rules live in `/workspace/SUPERVISOR.md` and the `ai-stack` Kanban board description, **not** in Hermes
  memory: gateway memory may not inject on messaging channels (open issue 96134).
- The firewall resolves allowed hosts once at start. If Discord or OSV move to new IPs, a restart (or step 3 of this
  script after a restart) picks them up.
