# Stella stack recovery for Windows Task Scheduler (see docs/recovery.md).
# Brings the devcontainer up, restores what postStartCommand would have done, and makes sure the
# Hermes gateway tmux session "hermes" exists. Safe to run repeatedly; it only acts on what is missing.
# -SelfTest exercises the helpers below (time limit, exit codes, lock, boot time) without touching Docker, then exits.
param(
  [string]$WorkspaceFolder,   # host path of the Stella repo; default: the parent of this script's folder (the repo root)
  [int]$DockerWaitSeconds = 600,
  # Optional; default: the per-user install, then the all-users install, whichever exists first.
  [string]$DockerDesktopExe,
  [string]$OllamaUrl = "http://localhost:11434",
  # Optional; default: the per-user install, then ollama on PATH, then the all-users install.
  [string]$OllamaExe,
  [switch]$SelfTest
)
$ErrorActionPreference = "Continue"
$log = Join-Path $env:LOCALAPPDATA "stella-recover.log"
if ($SelfTest) { $log = Join-Path $env:TEMP "stella-recover-selftest.log" }
$okMarker = Join-Path $env:LOCALAPPDATA "stella-recover.lastok"            # time of the last ok run (S6)
$launchMarker = Join-Path $env:LOCALAPPDATA "stella-recover.docker-launch" # time of the last Docker Desktop launch (S16)
$fwAlertMarker = Join-Path $env:LOCALAPPDATA "stella-recover.firewall-alert" # "<time>|<failed checks>" of the last STL-RCV-504 alert (QB2-4)
# One encoding for every line, UTF-8 via Out-File: Windows PowerShell 5.1 append redirection writes UTF-16.
function Log([string]$m) { "$(Get-Date -Format o) $m" | Out-File -FilePath $log -Append -Encoding utf8 }
function LogOutput { process { "$_" | Out-File -FilePath $log -Append -Encoding utf8 } }
if (-not $WorkspaceFolder) { $WorkspaceFolder = Split-Path -Parent $PSScriptRoot }
function First-Existing([string[]]$paths) {
  $paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
}
if (-not $DockerDesktopExe) {
  $DockerDesktopExe = First-Existing @(
    (Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\Docker Desktop.exe"),
    (Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"))
}

# S15: every external call (docker, devcontainer, tmux via docker exec) runs in a background job under a time limit, so
# a hung call is abandoned with a "timed out" log line instead of running into the task's 30-minute limit unlogged.
# Returns the call's stdout lines, logs its stderr lines (unless -Quiet), and sets $LASTEXITCODE: the call's exit code,
# 124 when the limit passed, -1 when it never ran (a stale 0 from an earlier call must never read as success).
# The job passes arguments exactly as a direct call does. If Start-Job itself fails, the call runs directly, unlimited.
$nativeCall = {
  param($e, $a)
  & $e @a 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { "##err $_" } else { "$_" } }
  "##rc=$LASTEXITCODE"
}
function Invoke-Timed([int]$Seconds, [string]$Exe, [string[]]$Arguments, [switch]$Quiet) {
  $global:LASTEXITCODE = -1
  $job = $null
  try { $job = Start-Job -ScriptBlock $nativeCall -ArgumentList $Exe, $Arguments -ErrorAction Stop }
  catch { Log "Start-Job failed ($($_.Exception.Message)): running $Exe without a time limit" }
  if ($job) {
    if (-not (Wait-Job $job -Timeout $Seconds)) {
      Stop-Job $job; Remove-Job $job -Force
      Log "timed out after $Seconds s: $Exe $($Arguments -join ' ')"
      $global:LASTEXITCODE = 124
      return
    }
    $lines = @(Receive-Job $job); Remove-Job $job -Force
  } else {
    $lines = @(& $nativeCall $Exe $Arguments)
  }
  $rc = -1
  foreach ($l in $lines) {
    $s = "$l"
    if ($s -match '^##rc=(-?\d+)$') { $rc = [int]$Matches[1] }
    elseif ($s.StartsWith('##err ')) { if (-not $Quiet) { Log "$Exe stderr: $($s.Substring(6))" } }
    else { $s }
  }
  $global:LASTEXITCODE = $rc
}
function Get-BootTime {
  try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime }
  catch { Log "boot time unknown: $($_.Exception.Message)"; $null }
}
function Read-Time([string]$path) {   # a time written with Get-Date -Format o, or $null
  try { [DateTime]::Parse("$(Get-Content -LiteralPath $path -Raw -ErrorAction Stop)".Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
  catch { $null }
}
# S9 lock: true when taken. A lock left by a run that ended without releasing it (every run: the process exit releases
# it) counts as taken; PowerShell may wrap that AbandonedMutexException, so both levels are checked.
function Lock-Recovery([System.Threading.Mutex]$m, [int]$ms) {
  try { $m.WaitOne($ms) }
  catch {
    $x = $_.Exception
    if ($x -is [System.Threading.AbandonedMutexException] -or $x.InnerException -is [System.Threading.AbandonedMutexException]) { $true }
    else { throw }
  }
}

# QB2-4: the firewall probe. It runs as root in the container (docker exec ... sh -c), so it is inline here: root must never
# run a file the node user can write. Rule shapes and set names only: no host, provider or id, so adding a host to the
# allowlist in init-firewall.sh needs no change here. Prints the failed checks as comma-separated tokens and exits 1; prints
# nothing and exits 0 when every check passes. The tokens are explained in the alert catalog (STL-RCV-504, "parts").
# Sent as one line with no double quote: Windows PowerShell 5.1 mangles double quotes in native arguments.
# FIREWALL-PROBE-BEGIN
$firewallProbeSrc = @'
f=,;
bad() { case $f in *,$1,*) ;; *) f=$f$1,;; esac; };
S() { iptables -S; };
for p in INPUT OUTPUT FORWARD; do S | grep -Eq -- '^-P '$p' DROP$' || bad policy; done;
n=$(S | grep -c -- '--match-set allowed-domains dst');
m=$(S | grep -Ec -- '^-A OUTPUT .*-p tcp .*--dport 443 .*allowed-domains dst -j ACCEPT$');
[ $n -ge 1 ] && [ $n = $m ] || bad web443;
S | grep -E -- '--dport 22 .*-j ACCEPT' | grep -qv -- '--match-set github-ssh dst' && bad ssh;
S | grep -Eq -- '-[sd] [0-9.]+/(16|24) .*-j ACCEPT' && bad lan;
S | grep -E -- '--dport 53 .*-j ACCEPT' | grep -Eqv -- ' -d [0-9.]+(/32)? ' && bad dns;
S | grep '^-A OUTPUT ' | tail -n 1 | grep -Eq -- ' -j REJECT( |$)' || bad reject;
S | grep '^-A OUTPUT ' | grep -E -- '-p tcp ' | grep -E -- ' -d [0-9.]+(/32)? ' | grep -Eq -- '--dport 11434 .*-j ACCEPT$' || bad ollama;
if command -v ip6tables >/dev/null; then for p in INPUT OUTPUT FORWARD; do ip6tables -S | grep -Eq -- '^-P '$p' DROP$' || bad ipv6; done; fi;
ipset list -n | grep -qx allowed-domains && ipset list -n | grep -qx github-ssh || bad sets;
S | grep -E -- '^-A (INPUT|OUTPUT) .*-j ACCEPT$' | grep -Evx -- '-A INPUT -i lo -j ACCEPT|-A OUTPUT -o lo -j ACCEPT|-A (INPUT|OUTPUT) -m (state --state|conntrack --ctstate) (ESTABLISHED,RELATED|RELATED,ESTABLISHED) -j ACCEPT|-A OUTPUT (-d [0-9.]+(/32)? )?-p (udp|tcp)( -m (udp|tcp))?( -d [0-9.]+(/32)?)? --dport 53 -j ACCEPT|-A INPUT (-s [0-9.]+(/32)? )?-p (udp|tcp)( -m (udp|tcp))?( -s [0-9.]+(/32)?)? --sport 53 -j ACCEPT|-A OUTPUT -p tcp( -m tcp)? --dport 443 -m set --match-set allowed-domains dst -j ACCEPT|-A OUTPUT -p tcp( -m tcp)? --dport 22 -m set --match-set github-ssh dst -j ACCEPT|-A OUTPUT (-d [0-9.]+(/32)? )?-p tcp( -m tcp)?( -d [0-9.]+(/32)?)? --dport 11434 -j ACCEPT' | grep -q . && bad extra;
[ $f = , ] && exit 0;
f=${f#,};
echo ${f%,};
exit 1;
'@
$firewallProbe = (($firewallProbeSrc -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' ')
# FIREWALL-PROBE-END
# '' when the ruleset passes, else the failed checks as sorted, comma-separated tokens ("unchecked": the probe could not run).
function Test-Firewall([string]$cid) {
  $out = @(Invoke-Timed 30 docker @('exec', '-u', 'root', $cid, 'sh', '-c', $firewallProbe))
  if ($LASTEXITCODE -eq 0) { return '' }
  $t = @($out | Where-Object { "$_" -match '^[a-z0-9]+(,[a-z0-9]+)*$' } | Select-Object -Last 1)
  if ($t) { return ((("$($t[0])" -split ',') | Sort-Object -Unique) -join ',') }
  'unchecked'
}
# Alert rate limit: the marker holds "<time>|<key>"; true when the same key was recorded less than $Hours ago.
function Test-AlertSent([string]$path, [string]$key, [int]$Hours) {
  try {
    $t, $k = "$(Get-Content -LiteralPath $path -Raw -ErrorAction Stop)".Trim() -split '\|', 2
    $age = ((Get-Date) - [DateTime]::Parse($t, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).TotalHours
    ($k -ceq $key) -and ($age -ge 0) -and ($age -lt $Hours)
  } catch { $false }
}

if ($SelfTest) {
  $script:fails = 0
  function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Output "ok   $what" } else { Write-Output "FAIL $what"; $script:fails++ }
  }
  Invoke-Timed 30 cmd @('/c', 'exit', '3') | Out-Null
  Check ($LASTEXITCODE -eq 3) "S15/S17: a call's exit code passes through (cmd /c exit 3 -> $LASTEXITCODE)"
  $out = @(Invoke-Timed 30 cmd @('/c', 'echo', 'hello'))
  Check (($LASTEXITCODE -eq 0) -and ($out -contains 'hello')) "S15: stdout is returned, exit 0 (got '$($out -join '|')', rc $LASTEXITCODE)"
  $t0 = Get-Date
  Invoke-Timed 3 powershell @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') | Out-Null
  $took = [int]((Get-Date) - $t0).TotalSeconds
  Check (($LASTEXITCODE -eq 124) -and ($took -lt 25)) "S15: a call over its limit is abandoned as 124 (rc $LASTEXITCODE after $took s)"
  Invoke-Timed 30 no-such-command-stella @() | Out-Null
  Check ($LASTEXITCODE -ne 0) "S15: a missing command never reads as 0 (rc $LASTEXITCODE)"
  Check ($null -ne (Get-BootTime)) "S16: boot time readable for the Docker Desktop launch marker"
  Check ("$((Get-CimInstance Win32_Process -Filter "ProcessId = $PID").CommandLine)" -match 'SelfTest') "S8: process command lines readable (the running devcontainer up check)"
  $tmpMarker = Join-Path $env:TEMP "stella-recover-selftest.time"
  Set-Content -LiteralPath $tmpMarker -Value (Get-Date -Format o) -Encoding ascii
  Check ($null -ne (Read-Time $tmpMarker)) "S6/S16: a marker time written by this script reads back"
  Check (($firewallProbe -notmatch "[`r`n`"]") -and ($firewallProbe -match 'bad web443')) "QB2-4: the firewall probe is one line with no double quote"
  $fwMark = Join-Path $env:TEMP "stella-recover-selftest.fw"
  Set-Content -LiteralPath $fwMark -Value "$(Get-Date -Format o)|a,b" -Encoding ascii
  Check ((Test-AlertSent $fwMark 'a,b' 6) -and -not (Test-AlertSent $fwMark 'a,c' 6) -and -not (Test-AlertSent $fwMark 'a,b' 0)) "QB2-4: the alert rate limit holds only for the same failed checks within the window"
  Set-Content -LiteralPath $fwMark -Value "$((Get-Date).AddHours(-7).ToString('o'))|a,b" -Encoding ascii
  Check (-not (Test-AlertSent $fwMark 'a,b' 6)) "QB2-4: an alert recorded 7 hours ago no longer suppresses"
  Check (-not (Test-AlertSent (Join-Path $env:TEMP "stella-recover-selftest.missing") 'a,b' 6)) "QB2-4: no marker file means not suppressed"
  $m = [System.Threading.Mutex]::new($false, "Global\StellaRecover")
  if (-not (Lock-Recovery $m 0)) {
    Write-Output "SKIP S9: a recovery run holds the lock right now; run -SelfTest again later"
  } else {
    $j = Start-Job -ScriptBlock {
      $o = [System.Threading.Mutex]::new($false, "Global\StellaRecover")
      try { $o.WaitOne(2000) } catch { $true }
    }
    $other = $null
    if (Wait-Job $j -Timeout 30) { $other = Receive-Job $j }
    Remove-Job $j -Force
    Check ($other -eq $false) "S9: a second process cannot take the lock while a run holds it (got '$other')"
    $m.ReleaseMutex()
    $j = Start-Job -ScriptBlock { [System.Threading.Mutex]::new($false, "Global\StellaRecover").WaitOne(5000) }   # ends holding it
    $held = $null
    if (Wait-Job $j -Timeout 30) { $held = Receive-Job $j }
    Remove-Job $j -Force
    $taken = $false
    try { $taken = Lock-Recovery $m 10000 } catch { }
    Check (($held -eq $true) -and $taken) "S9: a lock left by a run that ended without releasing it is taken over (job took it: '$held', taken over: $taken)"
    if ($taken) { $m.ReleaseMutex() }
  }
  Write-Output "log lines written to $log"
  if ($script:fails -eq 0) { Write-Output "selftest PASS"; exit 0 }
  Write-Output "selftest FAIL ($($script:fails))"; exit 1
}

# S9: one run at a time. Both tasks start at boot, so a second run waits briefly, then leaves the work to the first.
$owned = $false
try {
  $mutex = [System.Threading.Mutex]::new($false, "Global\StellaRecover")
  $owned = Lock-Recovery $mutex 15000
} catch { Log "recovery lock failed: $($_.Exception.Message)"; exit 1 }
if (-not $owned) { Log "another recovery run is active"; exit 0 }
$restarted = @()   # what this run restarted, for the "recovered" alert (S6)
$failed = @()      # non-fatal step failures: the run goes on to the gateway step, then exits 1 (S17)

# 0. Ollama (the local model server) must answer. A failure here is reported by the exit code at the end,
#    but never stops the Docker, container and gateway steps.
function Test-Ollama {
  try { Invoke-WebRequest -Uri "$OllamaUrl/api/tags" -UseBasicParsing -TimeoutSec 5 | Out-Null; $true } catch { $false }
}
$ollamaOk = Test-Ollama
if (-not $ollamaOk) {
  $ollamaPath = First-Existing @(
    $OllamaExe,
    (Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"),
    (Get-Command ollama -ErrorAction SilentlyContinue).Source,
    (Join-Path $env:ProgramFiles "Ollama\ollama.exe"))
  if ($ollamaPath) {
    Log "ollama silent: launching $ollamaPath"
    try { Start-Process -FilePath $ollamaPath -ArgumentList "serve" -WindowStyle Hidden -ErrorAction Stop }
    catch { Log "ollama launch failed: $($_.Exception.Message)" }
    $ollamaDeadline = (Get-Date).AddSeconds(120)
    while (-not $ollamaOk -and (Get-Date) -lt $ollamaDeadline) {
      Start-Sleep -Seconds 5
      $ollamaOk = Test-Ollama
    }
    if ($ollamaOk) { Log "ollama ok" } else { Log "ollama did not answer within 120s" }
  } else {
    Log "ollama not found"
  }
}

# 1. Wait until Docker answers (Docker Desktop can take minutes after logon or an update).
#    Power-on fix: Docker Desktop normally starts only at sign-in, so if docker info has not answered after 60 s,
#    launch Docker Desktop, at most once per boot (S16: a marker holds the time of the last launch; a launch after the
#    current boot time means this boot already had one), then keep waiting up to the same deadline.
$deadline = (Get-Date).AddSeconds($DockerWaitSeconds)
$launchAt = (Get-Date).AddSeconds(60)
$launchTried = $false
while ($true) {
  Invoke-Timed 30 docker @('info') -Quiet | Out-Null
  if ($LASTEXITCODE -eq 0) { break }
  if ((Get-Date) -gt $deadline) { Log "docker info did not answer within $DockerWaitSeconds s"; exit 1 }
  if (-not $launchTried -and (Get-Date) -gt $launchAt) {
    $launchTried = $true
    $boot = Get-BootTime
    $lastLaunch = Read-Time $launchMarker
    if ($boot -and $lastLaunch -and $lastLaunch -gt $boot) {
      Log "docker info silent for 60 s; Docker Desktop was already launched this boot (S16), still waiting"
    } elseif ($DockerDesktopExe -and (Test-Path -LiteralPath $DockerDesktopExe -PathType Leaf)) {
      Log "docker info silent for 60 s: launching $DockerDesktopExe"
      Set-Content -LiteralPath $launchMarker -Value (Get-Date -Format o) -Encoding ascii
      try { Start-Process -FilePath $DockerDesktopExe -ErrorAction Stop }
      catch { Log "Docker Desktop launch failed: $($_.Exception.Message)" }
    } else {
      Log "docker info silent for 60 s, and Docker Desktop not found; still waiting"
    }
  }
  Start-Sleep -Seconds 10
}

# 2. Make sure the devcontainer is running. After a reboot it is normally stopped, not missing:
#    start it with docker start; step 3 then re-runs the postStart steps it skipped.
#    The container is the one whose devcontainer.local_folder label equals the workspace path (case-insensitive,
#    trailing backslashes ignored): a running one if any, otherwise the most recently created stopped one.
#    S8: a failed docker ps or inspect, or output that does not parse, exits 1: never fall through to devcontainer up.
function Find-StellaContainer {
  $ids = @(Invoke-Timed 60 docker @('ps', '-aq', '--filter', 'label=devcontainer.local_folder') | Where-Object { $_ })   # newest first
  if ($LASTEXITCODE -ne 0) { Log "docker ps failed rc=$LASTEXITCODE"; exit 1 }
  if (-not $ids) { return }
  $json = Invoke-Timed 60 docker (@('inspect') + $ids)
  if ($LASTEXITCODE -ne 0) { Log "docker inspect failed rc=$LASTEXITCODE"; exit 1 }
  try { $all = ($json -join "`n") | ConvertFrom-Json -ErrorAction Stop }
  catch { Log "docker inspect output did not parse: $($_.Exception.Message)"; exit 1 }
  if (-not $all) { Log "docker inspect returned nothing for $($ids -join ' ')"; exit 1 }
  $want = $WorkspaceFolder.TrimEnd('\')
  $mine = @($all | Where-Object { "$($_.Config.Labels.'devcontainer.local_folder')".TrimEnd('\') -ieq $want })
  @($mine | Where-Object { $_.State.Running }) + $mine | Select-Object -First 1
}
$c = Find-StellaContainer
$id = if ($c -and $c.State.Running) { $c.Id }
if (-not $id) {
  if ($c) {
    $cid = $c.Id
    Log "container stopped: docker start $cid"
    Invoke-Timed 120 docker @('start', $cid) | LogOutput
    if ($LASTEXITCODE -ne 0) { Log "docker start failed rc=$LASTEXITCODE; if the OS box is installed, check the seccomp file .devcontainer\seccomp-userns.json (docs/recovery.md, The OS box host file)"; exit 1 }
    $restarted += "container started"
  } else {
    if (-not (Get-Command devcontainer -ErrorAction SilentlyContinue)) {
      Log "no container exists and devcontainer CLI not found"; exit 1
    }
    # A devcontainer up left running by an earlier run's time limit may still be creating the container: never start
    # a second one (two containers would mean two gateways on one Discord bot).
    try { $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction Stop) }
    catch { Log "process list failed ($($_.Exception.Message)): not running devcontainer up"; exit 1 }
    $busy = @($procs | Where-Object { $_.CommandLine -match 'devcontainer' -and $_.CommandLine -match ' up( |$)' })
    if ($busy) { Log "a devcontainer up is still running (pid $($busy.ProcessId -join ',')): not starting another"; exit 1 }
    Log "no container: devcontainer up --workspace-folder $WorkspaceFolder"
    Invoke-Timed 600 devcontainer @('up', '--workspace-folder', $WorkspaceFolder) | LogOutput
    if ($LASTEXITCODE -ne 0) { Log "devcontainer up failed rc=$LASTEXITCODE"; exit 1 }
    $restarted += "container created (devcontainer up)"
  }
  $c = Find-StellaContainer
  $id = if ($c -and $c.State.Running) { $c.Id }
  if (-not $id) { Log "container still not running after start"; exit 1 }
}

# 3. A plain `docker start` (Docker restart policy, Docker Desktop restart) skips postStartCommand:
#    no firewall (egress open!), no cron, no OpenCode user config. Detect with the firewall probe above (QB2-4): every part of the
#    ruleset init-firewall.sh builds, not just the default policy and one rule (S34: a half-applied or old ruleset must not pass).
#    A firewall failure exits 1 before the gateway step (init-firewall.sh leaves the network closed, S3); a cron or container-start
#    failure is recorded, the gateway step still runs, and the run exits 1 at the end (S17). A ruleset that still fails the probe
#    after the re-apply is recorded the same way ($fwFail), and never retried in a loop.
$fwFail = ''
$fw = Test-Firewall $id
if ($fw) {
  Log "firewall probe failed: $fw"
  Log "firewall missing in ${id}: re-running the postStart steps"
  Invoke-Timed 300 docker @('exec', '-u', 'root', $id, '/usr/local/bin/init-firewall.sh') | LogOutput
  if ($LASTEXITCODE -ne 0) { Log "init-firewall.sh failed rc=$LASTEXITCODE"; exit 1 }
  $restarted += "firewall re-applied"
  $fwFail = Test-Firewall $id
  if ($fwFail) { Log "firewall still failing after re-apply: $fwFail"; $failed += "firewall ($fwFail)" }
  Invoke-Timed 60 docker @('exec', '-u', 'root', $id, 'service', 'cron', 'start') | LogOutput
  if ($LASTEXITCODE -ne 0) { Log "service cron start failed rc=$LASTEXITCODE"; $failed += "cron rc=$LASTEXITCODE" }
  Invoke-Timed 300 docker @('exec', '-u', 'node', $id, '/workspace/bin/container-start.sh') | LogOutput
  if ($LASTEXITCODE -ne 0) { Log "container-start.sh failed rc=$LASTEXITCODE"; $failed += "container-start rc=$LASTEXITCODE" }
}

# 4. Gateway session: recreate if missing, then verify.
Invoke-Timed 30 docker @('exec', '-u', 'node', $id, 'tmux', 'has-session', '-t', 'hermes') -Quiet | Out-Null
if ($LASTEXITCODE -ne 0) {
  Log "tmux session hermes missing in ${id}: recreating"
  Invoke-Timed 30 docker @('exec', '-u', 'node', $id, 'tmux', 'new-session', '-d', '-s', 'hermes', '/workspace/bin/hermes-gateway-loop.sh') | LogOutput
  Invoke-Timed 30 docker @('exec', '-u', 'node', $id, 'tmux', 'has-session', '-t', 'hermes') -Quiet | Out-Null
  if ($LASTEXITCODE -ne 0) { Log "tmux session hermes still missing after recreate"; exit 1 }
  $restarted += "gateway session recreated"
}

# S6: anything restarted -> one #alerts line: when this run noticed it, and the last ok run (D46: no outage length is
# claimed; this script only knows its own runs). A failed post never fails the run.
if ($restarted) {
  $last = Read-Time $okMarker
  $lastOk = if ($last) { @("last_ok=$($last.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))") } else { @() }
  # D44: the wording lives in the alert catalog; bin/alert.sh renders it and sends it with hermes send, in the container.
  $code = if ($fwFail) { 'STL-RCV-504' } elseif ($failed) { 'STL-RCV-503' } else { 'STL-RCV-502' }
  $kv = if ($fwFail) { @("parts=$fwFail") } else { @("restarted=$($restarted -join ', ')") + $lastOk + @("failing=$($failed -join ', ')") }
  $text = "$code $($kv -join ' ')"
  # QB2-4: the same incomplete firewall is announced once per 6 hours; the log line below is written on every run.
  if ($fwFail -and (Test-AlertSent $fwAlertMarker $fwFail 6)) {
    Log "alert $code not sent again within 6 hours: $text"
  } else {
    Invoke-Timed 60 docker (@('exec', '-u', 'node', $id, '/workspace/bin/alert.sh', $code) + $kv) | LogOutput
    if ($fwFail -and $LASTEXITCODE -eq 0) { Set-Content -LiteralPath $fwAlertMarker -Value "$(Get-Date -Format o)|$fwFail" -Encoding ascii }
    Log "recovered alert sent rc=${LASTEXITCODE}: $text"
  }
}
if ($failed) { Log "FAILED container=$id gateway-session=hermes: $($failed -join ', ')"; exit 1 }
Log "ok container=$id firewall=on gateway-session=hermes"
Set-Content -LiteralPath $okMarker -Value (Get-Date -Format o) -Encoding ascii
if (-not $ollamaOk) { Log "exit 1: ollama did not answer"; exit 1 }
exit 0
