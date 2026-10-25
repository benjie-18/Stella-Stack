# Stella stack recovery for Windows Task Scheduler (see docs/recovery.md).
# Brings the devcontainer up, restores what postStartCommand would have done, and makes sure the
# Hermes gateway tmux session "hermes" exists. Safe to run repeatedly; it only acts on what is missing.
param(
  [Parameter(Mandatory = $true)][string]$WorkspaceFolder,   # host path of the Stella repo, e.g. C:\dev\Stella
  [int]$DockerWaitSeconds = 600
)
$ErrorActionPreference = "Continue"
$log = Join-Path $env:LOCALAPPDATA "stella-recover.log"
function Log([string]$m) { "$(Get-Date -Format o) $m" | Add-Content -Path $log }

# 1. Wait until Docker answers (Docker Desktop can take minutes after logon or an update).
$deadline = (Get-Date).AddSeconds($DockerWaitSeconds)
while ($true) {
  docker info *> $null
  if ($LASTEXITCODE -eq 0) { break }
  if ((Get-Date) -gt $deadline) { Log "docker info did not answer within $DockerWaitSeconds s"; exit 1 }
  Start-Sleep -Seconds 10
}

# 2. Container must be running. `devcontainer up` starts a stopped container and runs postStartCommand.
function Get-StellaContainer {
  docker ps -q --filter "label=devcontainer.local_folder=$WorkspaceFolder" | Select-Object -First 1
}
$id = Get-StellaContainer
if (-not $id) {
  Log "container not running: devcontainer up --workspace-folder $WorkspaceFolder"
  devcontainer up --workspace-folder "$WorkspaceFolder" *>> $log
  if ($LASTEXITCODE -ne 0) { Log "devcontainer up failed rc=$LASTEXITCODE"; exit 1 }
  $id = Get-StellaContainer
  if (-not $id) { Log "devcontainer up returned 0 but no running container matches the label"; exit 1 }
}

# 3. A plain `docker start` (Docker restart policy, Docker Desktop restart) skips postStartCommand:
#    no firewall (egress open!), no cron, no OpenCode user config. Detect by the firewall's default DROP policy.
docker exec -u root $id sh -c "iptables -S OUTPUT | grep -q -- '-P OUTPUT DROP'"
if ($LASTEXITCODE -ne 0) {
  Log "firewall missing in ${id}: re-running the postStart steps"
  docker exec -u root $id /usr/local/bin/init-firewall.sh *>> $log
  if ($LASTEXITCODE -ne 0) { Log "init-firewall.sh failed rc=$LASTEXITCODE"; exit 1 }
  docker exec -u root $id service cron start *>> $log
  docker exec -u node $id /workspace/bin/container-start.sh *>> $log
}

# 4. Gateway session: recreate if missing, then verify.
docker exec -u node $id tmux has-session -t hermes 2> $null
if ($LASTEXITCODE -ne 0) {
  Log "tmux session hermes missing in ${id}: recreating"
  docker exec -u node $id tmux new-session -d -s hermes /workspace/bin/hermes-gateway-loop.sh
  docker exec -u node $id tmux has-session -t hermes 2> $null
  if ($LASTEXITCODE -ne 0) { Log "tmux session hermes still missing after recreate"; exit 1 }
}
Log "ok container=$id firewall=on gateway-session=hermes"
exit 0
