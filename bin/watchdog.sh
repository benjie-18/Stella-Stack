#!/usr/bin/env bash
# Build watchdog (no LLM): run the project's test, lint and build scripts, write
# .supervisor/status.json, and on failure send a one-line alert to discord:#alerts.
# Runs from container cron, not hermes cron: the hermes cron ticker lives in the
# gateway, so it could not report gateway death (that is the Stage 5 gateway watchdog).
set -uo pipefail
# cron starts jobs with a minimal PATH
export PATH="/home/node/.local/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"

ROOT=/workspace
SUP="$ROOT/.supervisor"
STATUS="$SUP/status.json"
LOG="$SUP/logs/watchdog.log"
ALERT_TARGET="${WATCHDOG_ALERT_TARGET:-discord:#alerts}"
mkdir -p "$SUP/logs"
cd "$ROOT" || exit 1

# One run at a time; a slow suite must not stack cron runs.
exec 9>"$SUP/logs/watchdog.lock"
flock -n 9 || { echo "$(date -u +%FT%TZ) skipped: previous run still active" >>"$LOG"; exit 0; }

started=$(date -u +%FT%TZ)
steps='[]'
failed=""
for step in test lint build; do
  if ! jq -e --arg s "$step" '.scripts[$s]' package.json >/dev/null; then
    steps=$(jq -c --arg s "$step" '. + [{step: $s, exit_code: null, skipped: "no npm script"}]' <<<"$steps")
    continue
  fi
  echo "== $(date -u +%FT%TZ) npm run $step" >>"$LOG"
  npm run --silent "$step" >>"$LOG" 2>&1
  rc=$?
  # Test hook: WATCHDOG_FORCE_FAIL=<step> simulates that step failing (alert-path test).
  [ "${WATCHDOG_FORCE_FAIL:-}" = "$step" ] && rc=99
  steps=$(jq -c --arg s "$step" --argjson rc "$rc" '. + [{step: $s, exit_code: $rc}]' <<<"$steps")
  [ "$rc" -ne 0 ] && [ -z "$failed" ] && failed="$step (exit $rc)"
done

alert_rc=null
if [ -n "$failed" ]; then
  summary="build watchdog FAIL: $failed on $(git rev-parse --short HEAD 2>/dev/null) at $started; see .supervisor/logs/watchdog.log"
  hermes send --to "$ALERT_TARGET" --quiet "$summary" >>"$LOG" 2>&1
  alert_rc=$?
fi

jq -n --arg started "$started" --arg finished "$(date -u +%FT%TZ)" \
  --arg trigger "${WATCHDOG_TRIGGER:-manual}" --arg head "$(git rev-parse HEAD 2>/dev/null)" \
  --arg failed "$failed" --argjson steps "$steps" --argjson alert_rc "$alert_rc" \
  --arg target "$ALERT_TARGET" \
  '{started: $started, finished: $finished, trigger: $trigger, head: $head,
    ok: ($failed == ""), failed: (if $failed == "" then null else $failed end),
    steps: $steps, alert: {target: $target, exit_code: $alert_rc}}' >"$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"

[ -z "$failed" ]
