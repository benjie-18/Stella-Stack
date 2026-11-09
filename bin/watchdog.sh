#!/usr/bin/env bash
# Build watchdog (no LLM): run the project's test and lint scripts (and build, when package.json has one), write
# .supervisor/status.json, and check that the reply poller and the gateway are alive. Each problem sends one message to
# discord:#alerts when it starts and one when it clears (S11, S5); a failed send is retried once. Wording and codes
# (STL-WDG-101/102, STL-ESC-201, STL-GW-101/102/103) come from the alert catalog (D44).
# Runs from container cron, not hermes cron: the hermes cron ticker lives in the gateway, so it could not report gateway
# death. Checks: a step over WATCHDOG_STEP_TIMEOUT (600 s) is killed and recorded as hung (S10); the poller heartbeat
# (state/reply-poll.heartbeat) older than 5 minutes; a gateway that is down (no process, or the newest connection line in
# its logs is a disconnect) or unknown (the check cannot tell), while Hermes is not paused. A quiet log alone is not an
# alert (D47): bin/watchdog_settings.py decides from the settings file docs/hermes-local/watchdog-settings.json. A failed
# test is run again, check by check, before it alerts (D47); the alert names the check and its first failing line.
# Test hooks: WATCHDOG_FORCE_FAIL=<step>; WATCHDOG_ROOT, ESCALATE_SUP_DIR, WATCHDOG_SETTINGS and WATCHDOG_ALERT_TARGET
# point it at scratch files (bin/watchdog-selftest.sh).
set -uo pipefail
# cron starts jobs with a minimal PATH that lacked hermes ("hermes: command not found", S11); append, so test stubs win
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C.UTF-8

BIN="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="${WATCHDOG_ROOT:-/workspace}"
SUP="${ESCALATE_SUP_DIR:-$ROOT/.supervisor}"
STATUS="$SUP/status.json"
LOG="$SUP/logs/watchdog.log"
ALERT_TARGET="${WATCHDOG_ALERT_TARGET:-discord:#alerts}"
STEP_TIMEOUT="${WATCHDOG_STEP_TIMEOUT:-600}"
MW_FAILS_N="${WATCHDOG_MODEL_WATCH_FAILS_N:-2}"   # B2V-12: runs in a row the model watch could not check before STL-MDL-702 (2 = 30 min)
OPEN="$SUP/state/watchdog-open"   # one file per open problem (its start time); removed when it clears
mkdir -p "$SUP/logs" "$OPEN"
. "${BASH_SOURCE[0]%/*}/alert.sh"   # alert_text: the #alerts wording from the catalog (D44)
cd "$ROOT" || exit 1

# One run at a time; a slow suite must not stack cron runs.
exec 9>"$SUP/logs/watchdog.lock"
flock -n 9 || { echo "$(date -u +%FT%TZ) skipped: previous run still active" >>"$LOG"; exit 0; }

send() { hermes send --to "$ALERT_TARGET" --quiet "$1" >>"$LOG" 2>&1 || { sleep 3; hermes send --to "$ALERT_TARGET" --quiet "$1" >>"$LOG" 2>&1; }; }
# problem <key> <CODE> [key=value ...]: alert once when a problem starts. Marked open (start time, then code) only once
# the alert went out, so an undelivered alert is tried again on the next run.
problem() {
  [ -e "$OPEN/$1" ] && return 0
  local key=$1 now; now=$(date -u +%FT%TZ); shift
  send "$(alert_text "$@" since="$now")" && printf '%s\n%s\n' "$now" "$1" >"$OPEN/$key"
}
# cleared <key> <CODE> [key=value ...]: one message when an open problem clears, the resolved form of the code that
# opened it (an open file from before D44 holds only the time: <CODE> then).
cleared() {
  [ -e "$OPEN/$1" ] || return 0
  local since code; since=$(sed -n 1p "$OPEN/$1"); code=$(sed -n 2p "$OPEN/$1")
  send "$(alert_text "${code:-$2}" resolved=1 since="$since" "${@:3}")" && rm -f "$OPEN/$1"
}

started=$(date -u +%FT%TZ)
steps='[]'
failed=""
for step in test lint build; do
  if ! jq -e --arg s "$step" '.scripts[$s]' package.json >/dev/null; then
    steps=$(jq -c --arg s "$step" '. + [{step: $s, exit_code: null, skipped: "no npm script"}]' <<<"$steps")
    continue
  fi
  echo "== $(date -u +%FT%TZ) npm run $step" >>"$LOG"
  out=$(mktemp "$SUP/state/step-out.XXXXXX")
  timeout "$STEP_TIMEOUT" npm run --silent "$step" >"$out" 2>&1
  rc=$?
  cat "$out" >>"$LOG"
  # Test hook: WATCHDOG_FORCE_FAIL=<step> simulates that step failing (alert-path test).
  [ "${WATCHDOG_FORCE_FAIL:-}" = "$step" ] && rc=99
  hung=false; [ "$rc" = 124 ] && hung=true
  # A failed test is run again, check by check (a busy machine can fail one timing check once); only a check that fails
  # again counts. A check name that is not plain characters, or no failed check found in the output, is not rerun.
  detail="" names="" flaky=""
  if [ "$step" = test ] && [ "$rc" -ne 0 ] && ! $hung; then
    rerun=$(python3 -I "$BIN/watchdog_settings.py" get test_rerun.rerun_command 2>/dev/null)
    while IFS=$'\t' read -r c d; do
      [ -n "$c" ] || continue
      if [ -n "$rerun" ] && [[ $c =~ ^[A-Za-z0-9._-]+$ ]] && timeout "$STEP_TIMEOUT" ${rerun//\{check\}/$c} </dev/null >>"$LOG" 2>&1; then
        flaky="${flaky:+$flaky, }$c"; echo "$(date -u +%FT%TZ) flaky: $c failed once and passed on the rerun (${d:-no detail})" >>"$LOG"
      else
        names="${names:+$names, }$c"; [ -n "$detail" ] || detail="$c: $d"
      fi
    done < <(python3 -I "$BIN/watchdog_settings.py" failures "$out" 2>/dev/null)
    [ -n "$flaky" ] && [ -z "$names" ] && rc=0
  fi
  rm -f "$out"
  steps=$(jq -c --arg s "$step" --argjson rc "$rc" --argjson h "$hung" --arg f "$flaky" '. + [{step: $s, exit_code: $rc} + (if $h then {hung: true} else {} end) + (if $f != "" then {rerun_passed: $f} else {} end)]' <<<"$steps")
  if [ "$rc" -ne 0 ] && [ -z "$failed" ]; then
    if $hung; then failed="$step (hung, killed after ${STEP_TIMEOUT} s)" fcode=STL-WDG-102; else failed="$step (exit $rc)${detail:+: $detail}" fcode=STL-WDG-101; fi
    case "$step" in test) fcheck="test run${names:+ ($names)}" ;; lint) fcheck="code style check" ;; *) fcheck=$step ;; esac
    fdetail=""; [ -n "$detail" ] && fdetail=" First failing line: \"${detail#*: }\"."
  fi
done

head=$(git rev-parse --short HEAD 2>/dev/null)
if [ -n "$failed" ]; then
  problem build "$fcode" check="$fcheck" commit="${head:-unknown}" detail="$fdetail" failed="$failed" started="$started"
else
  cleared build STL-WDG-101 commit="${head:-unknown}"
fi

# Reply poller liveness: every pass writes its heartbeat, also while Hermes is paused.
hb=$(cat "$SUP/state/reply-poll.heartbeat" 2>/dev/null)
age=$(( $(date +%s) - ${hb:-0} ))
if [ "$age" -gt 300 ]; then
  poller="stale ${age}s"
  [ -n "$hb" ] && mins=$((age / 60)) || mins="an unknown number of"   # K10: no heartbeat file yet is not 29 million minutes
  problem poller STL-ESC-201 minutes="$mins" heartbeat_age_s="${hb:+$age}"
else
  poller=ok
  cleared poller STL-ESC-201
fi

# Workers whose model calls keep failing (K4, bin/model_watch.py; settings model_watch): one streak per card, the cause from
# the model server the worker's own profile uses, resolved when the card's calls work again or it stops running.
if ! mw=$(python3 -I "$BIN/model_watch.py" 2>/dev/null) || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$mw"; then
  echo "$(date -u +%FT%TZ) model watch could not check; open STL-MDL-701 streaks kept" >>"$LOG"; mw=skip   # K4: no page, no resolve
  mwf=$(( $(cat "$SUP/state/model-watch.fails" 2>/dev/null || echo 0) + 1 )); echo "$mwf" >"$SUP/state/model-watch.fails"
  [ "$mwf" -lt "$MW_FAILS_N" ] || problem model-watch STL-MDL-702 count="$mwf"   # B2V-12: a watch that stays broken pages
else
  rm -f "$SUP/state/model-watch.fails"; cleared model-watch STL-MDL-702
fi
[ "$mw" = skip ] || for card in $(jq -r '.[] | select(.unchecked | not) | .card' <<<"$mw"); do
  e=$(jq -c --arg c "$card" 'map(select(.card == $c))[0]' <<<"$mw")
  problem "model-$card" STL-MDL-701 card="$card" count="$(jq -r .errors <<<"$e")" minutes="$(jq -r .minutes <<<"$e")" \
    parts="$(jq -r .cause <<<"$e")" error="$(jq -r .detail <<<"$e")"
done
[ "$mw" = skip ] || for f in "$OPEN"/model-t_*; do
  [ -e "$f" ] || continue; c=${f##*/model-}
  jq -e --arg c "$c" 'any(.[]; .card == $c)' >/dev/null <<<"$mw" || cleared "model-$c" STL-MDL-701 card="$c"
done

# Gateway (S5, D47): only while Hermes is not paused; one streak per outage, whatever its cause. Only down and unknown
# alert; a log that is merely quiet does not (a healthy gateway is often quiet for hours), it gets one line in the log.
verdict=$(python3 -I "$BIN/watchdog_settings.py" gateway 2>/dev/null)
jq -e '.state' >/dev/null 2>&1 <<<"$verdict" || verdict='{"state":"unknown","cause":"check","evidence":"the gateway check did not run","marker_time":null}'
gstate=$(jq -r .state <<<"$verdict"); gcause=$(jq -r .cause <<<"$verdict"); gmark=$(jq -r '.marker_time // empty' <<<"$verdict")
[ "$gstate" = active ] || [ "$gstate" = paused ] || echo "$(date -u +%FT%TZ) gateway $gstate ($gcause): $(jq -r .evidence <<<"$verdict")" >>"$LOG"
gateway=$gstate
case "$gstate" in
  paused) ;;
  down)    if [ "$gcause" = process ]; then problem gateway STL-GW-101; else problem gateway STL-GW-102 at="$gmark"; fi ;;
  unknown) problem gateway STL-GW-103 parts="$gcause" ;;
  *)       cleared gateway STL-GW-101 parts="$gcause" ;;
esac

jq -n --arg started "$started" --arg finished "$(date -u +%FT%TZ)" \
  --arg trigger "${WATCHDOG_TRIGGER:-manual}" --arg head "$(git rev-parse HEAD 2>/dev/null)" \
  --arg failed "$failed" --argjson steps "$steps" --arg target "$ALERT_TARGET" \
  --arg poller "$poller" --arg gateway "$gateway" --argjson open "$(ls "$OPEN" | jq -Rsc 'split("\n")[:-1]')" \
  '{started: $started, finished: $finished, trigger: $trigger, head: $head,
    ok: ($failed == ""), failed: (if $failed == "" then null else $failed end),
    steps: $steps, health: {poller: $poller, gateway: $gateway}, alert: {target: $target, open: $open}}' >"$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"

[ -z "$failed" ]
