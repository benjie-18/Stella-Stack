#!/usr/bin/env bash
# The only sanctioned way to run Claude Opus, Haiku or Sonnet: card-scoped, logged, rate-limited.
# usage: escalate.sh <card-id> <haiku|sonnet|opus> <purpose> <reason...> [--]
#   prompt on stdin; opus purpose must be in OPUS_PURPOSES (plan runs --model opusplan). Anything after -- is refused (exit 2): no caller passes an extra arg.
# Exit: 0 ok, 2 usage or a refusal (a setting's registry default unreadable: STL-CFG-310; the log or a state file of the call is a link; nothing run), 3 over a limit (never retried), 75 pool exhausted, else claude's exit code.
# Queue (F15, F28, F29): a call refused by a zeroed or exceeded limit (Opus slots, Haiku per day) and every pool-exhausted
# call is recorded in state/queue.jsonl with its prompt file, and raises one #alerts line; the caller still gets 3 or 75.
# A queue file that cannot be read, parsed or written is never read as empty and never reported as written: the call is not queued,
# the caller still gets 3 or 75, the stderr line, the card note and a NOT_QUEUED log line say it was lost, and STL-LIM-405 tells the
# owner (one alert an hour: the file stays broken until it is fixed). An unreadable settings registry is checked after the
# usage checks and refuses the call (STL-CFG-310, one alert an hour). Nothing retries a call: bin/escalate-drain.sh (manual)
# replays a queued one. Beyond QUEUE_MAX queued entries the call is refused unqueued (NOT_QUEUED, one #alerts line an hour).
# ESCALATE_REPLAY=<id> (set by the drain) never queues or alerts again.
# Test hook (Stage 6 T15): ESCALATE_FORCE_POOL_EXHAUSTED=1 skips claude and takes the fallback path. The fallback config
# (FALLBACK_CONFIG, default docs/hermes-local/fallback-routing.json) says whether a low-risk call is served by a fallback runner
# when the pool is exhausted and which models it tries; disabled or missing = NO_REROUTE and queue.
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
set -uo pipefail
# cron/hook callers start with a minimal PATH; append so test stubs earlier in PATH still win.
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C.UTF-8   # F19: the inherited en_US.UTF-8 is not installed, so bash falls back to C and ${s:0:N} cuts bytes

SUP="${ESCALATE_SUP_DIR:-/workspace/.supervisor}"
FALLBACK_CONFIG="${FALLBACK_CONFIG:-/workspace/docs/hermes-local/fallback-routing.json}"
LOG="$SUP/escalations.log"
STATE="$SUP/state"
mkdir -p "$STATE"
# shellcheck source=/dev/null
. "$SUP/limits.env" || { echo "escalate.sh: cannot read $SUP/limits.env" >&2; exit 2; }
. /workspace/bin/kanban-board.sh   # kanban(): every kanban call names its board (F4)
. /workspace/bin/owner-config.sh   # once_per_hour, and alert_text (D44) through it

# Rate-limit / pool-exhausted output, verified in claude 2.1.310 (bin/claude.exe strings).
POOL_PATTERNS=("You've hit your" "You've reached your" "You're out of usage credits" "You're out of extra usage"
  "Your org is out of usage" "usage limit reached" "rate_limit_error" "Rate limit exceeded")

card="${1:-}" model="${2:-}" purpose="${3:-}"
shift $(( $# < 3 ? $# : 3 ))
reason=""
while [ $# -gt 0 ] && [ "$1" != "--" ]; do reason="${reason:+$reason }$1"; shift; done
[ "${1:-}" = "--" ] && shift

log() {  # log <event> <exit_code|null> [model_used] [fallback] [cost] [detail]
  jq -nc --arg time "$(date -u +%FT%TZ)" --arg card "$card" --arg model "$model" --arg purpose "$purpose" \
    --arg reason "$reason" --arg event "$1" --argjson exit_code "${2:-null}" --arg model_used "${3:-}" \
    --argjson fallback "${4:-false}" --argjson cost_usd "${5:-null}" --arg detail "${6:-}" \
    '{time: $time, card: $card, model: $model, purpose: $purpose, reason: $reason, event: $event,
      exit_code: $exit_code, model_used: $model_used, fallback: $fallback, cost_usd: $cost_usd, detail: $detail}' >>"$LOG"
}
refuse() { log "$1" "$2" "" false null "$3"; echo "escalate.sh: $1: $3" >&2; exit "$2"; }
registry() {  # registry <KEY>: sets reg_def reg_min reg_max from the settings registry; unreadable = refuse (exit 2, STL-CFG-310)
  local v p="the default and range of setting $1 cannot be read"
  v=$(python3 -I /workspace/bin/stella_data.py get --json settings "$1" 2>/dev/null | jq -er '[.default, .validation.minimum, .validation.maximum]
    | select(all(type == "number" and . == floor) and .[1] <= .[0] and .[0] <= .[2]) | @tsv') && read -r reg_def reg_min reg_max <<<"$v" && [ -n "$reg_max" ] && return
  python3 -I /workspace/bin/alert_catalog.py preview STL-CFG-310 problem="$p" >&2 2>/dev/null || echo "STL-CFG-310 $p" >&2   # fallback: no catalog, still a code
  # Nothing is queued (the queue bound is what could not be read) and the prompt is not read: the caller keeps it. The owner is told
  # on the alerts channel once an hour (a standing condition), never for a replay; each refused call has its own log line.
  if [ -z "${ESCALATE_REPLAY:-}" ] && once_per_hour registry-unreadable; then
    hermes send --to "$ALERT_TARGET" --quiet "$(alert_text STL-CFG-310 problem="$p; escalate.sh refused the call for card $card ($model $purpose): it was not run and not queued, the caller still holds the prompt; later calls are refused the same way until it is fixed (each in escalations.log, SETTING_UNREADABLE)")" >/dev/null 2>&1
  fi
  refuse SETTING_UNREADABLE 2 "$p; no call without a timeout, no unbounded queue"
}
note() { kanban comment --author escalate.sh "$card" "$1" >/dev/null 2>&1; }
QUEUE="$STATE/queue.jsonl"
# nolink <file>: false, with a warning, when a file of the state folder (or the log) is a symbolic link or has a second hard link;
# no write there opens one (W5-RT4-01).
# shortcut: whoever can write the state folder can put a link in between this test and the open; upgrade to an O_NOFOLLOW open if a less trusted user can write it
nolink() { { [ ! -L "$1" ] && { [ ! -f "$1" ] || [ "$(stat -c %h "$1")" = 1 ]; }; } || { echo "escalate.sh: warning: ${1#"$SUP"/} is a link: not written through it" >&2; return 1; }; }
nolink "$LOG" || exit 2   # every call logs: checked once, before the first line is appended
nolink "$STATE" || refuse STATE_LINK 2 "the state folder is a link: nothing is made in it"
queue_failed() {  # queue_failed <what>: the call is not in the queue, and every message says so (the prompt goes: nothing points at it)
  flock -u 6 2>/dev/null; rm -f "$prompt"; qid=""   # fd 6 is not open when the lock file was refused
  qnote="NOT queued: $1; fix the file (the call is lost, run it again)"
  echo "escalate.sh: warning: $1" >&2
  log NOT_QUEUED null none false null "$1; the call is lost"   # every lost call has its own line; the alert below is once an hour
  once_per_hour queue-unusable && hermes send --to "$ALERT_TARGET" --quiet "$(alert_text STL-LIM-405 card="$card" model="${model^}" problem="$1" since="$(date -u +%FT%TZ)")" >/dev/null 2>&1
}
queue() {  # queue <LIMIT|POOL_EXHAUSTED> <what happened>: one entry and one #alerts line; sets qid ("" if not queued), qnote
  qid="" qnote="not queued"
  [ -z "${ESCALATE_REPLAY:-}" ] || { qnote="left in the queue as $ESCALATE_REPLAY"; rm -f "$prompt"; return 0; }
  nolink "$STATE/queue.lock" || { queue_failed "the queue lock state/queue.lock is a link"; return 0; }
  exec 6>>"$STATE/queue.lock"; flock 6
  nolink "$QUEUE" || { queue_failed "the queue file state/queue.jsonl is a link"; return 0; }
  nq=0   # a missing file is an empty queue; a file that cannot be read or parsed is not (the count is unknown, so nothing is queued past the limit)
  if [ -e "$QUEUE" ] && ! nq=$(jq -s '[.[] | select(.state == "queued")] | length' "$QUEUE" 2>/dev/null); then
    queue_failed "the queue file state/queue.jsonl cannot be read or parsed"; return 0
  fi
  if [ "$nq" -ge "$QUEUE_MAX" ]; then
    flock -u 6; rm -f "$prompt"
    qnote="not queued: the queue is full (QUEUE_MAX=$QUEUE_MAX)"
    log NOT_QUEUED null none false null "the queue is full (QUEUE_MAX=$QUEUE_MAX); the call is lost"
    once_per_hour queue-full && hermes send --to "$ALERT_TARGET" --quiet "$(alert_text STL-LIM-403 max="$QUEUE_MAX" why="$1" card="$card" since="$(date -u +%FT%TZ)")" >/dev/null 2>&1
    return 0
  fi
  qid="q_$(date -u +%Y%m%dT%H%M%SZ)_${card}_$$"
  entry=$(jq -nc --arg id "$qid" --arg card "$card" --arg model "$model" --arg purpose "$purpose" --arg call_reason "$reason" \
    --argjson claude_args "$(if [ ${#extra_args[@]} -gt 0 ]; then printf '%s\n' "${extra_args[@]}" | jq -Rsc 'split("\n")[:-1]'; else echo '[]'; fi)" \
    --arg why "$1" --arg detail "$2" --arg created "$(date -u +%FT%TZ)" --arg prompt_file "$prompt" \
    '{id: $id, card: $card, model: $model, purpose: $purpose, call_reason: $call_reason, claude_args: $claude_args,
      reason: $why, detail: $detail, created: $created, state: "queued", prompt_file: $prompt_file}')
  # a cut last line (no newline) would swallow this entry: end it first; a write that fails is not a queued call
  { [ ! -s "$QUEUE" ] || [ -z "$(tail -c1 "$QUEUE")" ] || echo >>"$QUEUE"; } && printf '%s\n' "$entry" >>"$QUEUE" \
    || { queue_failed "the queue file state/queue.jsonl cannot be written"; return 0; }
  flock -u 6
  qnote="recorded in the queue as $qid; run bin/escalate-drain.sh"
  log QUEUED null none "$([ "$1" = POOL_EXHAUSTED ] && echo true || echo false)" null "$1; $qid"
  [ "$1" = POOL_EXHAUSTED ] && acode=STL-LIM-402 || acode=STL-LIM-401
  hermes send --to "$ALERT_TARGET" --quiet "$(alert_text "$acode" card="$card" model="${model^}" purpose="$purpose" queue_id="$qid" detail="$2" since="$(date -u +%FT%TZ)")" >/dev/null 2>&1
  alert_rc=$?
}
limit() { queue LIMIT "$1"; note "escalate.sh LIMIT: $model ($purpose) for '$reason': $1. No result; $qnote."; refuse LIMIT 3 "$1; $qnote"; }
# W5-RT6-01: an extra arg is passed on only if a caller of the stack uses it. None does (the drain replays the empty list every
# caller queues), so every one is refused, here, where a direct call and a replay both pass. To allow one, name it in this test.
extra_args=("$@")   # always empty past the next line; kept with a queue entry
[ $# -eq 0 ] || refuse USAGE 2 "extra claude arg $1 is refused: no caller of the stack passes one (it could override escalate.sh's model, budget or permissions, or make the model command read a file or start a command)"

[[ "$card" =~ ^t_[0-9a-f]{8}$ ]] || refuse USAGE 2 "card id required (t_xxxxxxxx), got '${card}'"
[ -n "$reason" ] || refuse USAGE 2 "reason required"
card_json=$(kanban show "$card" --json 2>/dev/null) || refuse USAGE 2 "card $card not found on the board"
case "$model" in
  haiku|sonnet) claude_model="$model" ;;
  opus)
    [[ " $OPUS_PURPOSES " == *" $purpose "* ]] || refuse LIMIT 3 "opus is allowed only for: $OPUS_PURPOSES"
    claude_model=$([ "$purpose" = plan ] && echo opusplan || echo opus) ;;
  *) refuse USAGE 2 "model must be haiku, sonnet or opus" ;;
esac
# The settings registry is read after the usage checks: a bad call is refused for what it is, before any alert.
# A limit that is set but outside the registry's type and range is treated like a bad timeout: one warning, then the registry
# default (`timeout 0` means no timeout; a non-number makes `[ -ge ]` fail, which would queue without bound).
registry CALL_TIMEOUT; ct_def=$reg_def ct_min=$reg_min ct_max=$reg_max
registry QUEUE_MAX; qm_def=$reg_def qm_min=$reg_min qm_max=$reg_max
# shortcut: nine digits at most (a number of days still fits in 64 bits); longer is out of range anyway
secs=; if [[ "${CALL_TIMEOUT:-}" =~ ^([1-9][0-9]{0,8})([smhd]?)$ ]]; then
  case "${BASH_REMATCH[2]}" in m) mul=60;; h) mul=3600;; d) mul=86400;; *) mul=1;; esac; secs=$(( ${BASH_REMATCH[1]} * mul )); fi
if [ -z "$secs" ] || [ "$secs" -lt "$ct_min" ] || [ "$secs" -gt "$ct_max" ]; then bad_timeout="${CALL_TIMEOUT:-}"; CALL_TIMEOUT=$ct_def
  log WARN null "" false null "CALL_TIMEOUT='$bad_timeout' is not a positive duration of $ct_min to $ct_max seconds (0 would disable the timeout); using $CALL_TIMEOUT"
  echo "escalate.sh: warning: CALL_TIMEOUT='$bad_timeout' is not a positive duration of $ct_min to $ct_max seconds; using $CALL_TIMEOUT" >&2; fi
if [ -z "${QUEUE_MAX:-}" ]; then QUEUE_MAX=$qm_def   # unset or empty: the default, silently
elif ! [[ "$QUEUE_MAX" =~ ^[0-9]{1,9}$ ]] || [ "$((10#$QUEUE_MAX))" -lt "$qm_min" ] || [ "$((10#$QUEUE_MAX))" -gt "$qm_max" ]; then
  log WARN null "" false null "QUEUE_MAX='$QUEUE_MAX' is not a whole number from $qm_min to $qm_max; using $qm_def"
  echo "escalate.sh: warning: QUEUE_MAX='$QUEUE_MAX' is not a whole number from $qm_min to $qm_max; using $qm_def" >&2; QUEUE_MAX=$qm_def
else QUEUE_MAX=$((10#$QUEUE_MAX)); fi

prompt="$STATE/prompt-$(date -u +%Y%m%dT%H%M%SZ)-$card-$$.txt"
{ nolink "$prompt" && nolink "$prompt.err"; } || refuse STATE_LINK 2 "the prompt file of this call in the state folder is a link"
cat >"$prompt"
[ -s "$prompt" ] || { rm -f "$prompt"; refuse USAGE 2 "prompt required on stdin"; }

if [ "$model" = opus ]; then
  got=""
  for i in $(seq 1 "$OPUS_MAX_CONCURRENT"); do
    lk="$STATE/opus.$i.lock"; nolink "$lk" || continue
    exec 8>>"$lk"
    flock -n 8 && { got=1; break; }
  done
  [ -n "$got" ] || limit "no Opus slot free (OPUS_MAX_CONCURRENT=$OPUS_MAX_CONCURRENT)"
fi
if [ "$model" = haiku ]; then
  counter="$STATE/haiku-$(date -u +%F).count"
  lk="$STATE/haiku.lock"; { nolink "$lk" && nolink "$counter"; } || limit "the lock or counter of the daily limit in the state folder is a link"
  exec 7>>"$lk"
  flock 7
  n=$(cat "$counter" 2>/dev/null || echo 0)
  [ "$n" -lt "$HAIKU_MAX_PER_DAY" ] || { flock -u 7; limit "Haiku daily limit reached ($n/$HAIKU_MAX_PER_DAY for $(date -u +%F))"; }
  echo $((n + 1)) >"$counter"
  flock -u 7
fi

log START null
if [ "${ESCALATE_FORCE_POOL_EXHAUSTED:-}" = 1 ]; then
  out="" err="You've hit your session limit (forced by ESCALATE_FORCE_POOL_EXHAUSTED)" rc=1
else
  out=$(timeout "$CALL_TIMEOUT" claude -p --model "$claude_model" --output-format json \
    --max-budget-usd "$MAX_BUDGET_USD" "$@" <"$prompt" 2>"$prompt.err")
  rc=$?
  err=$(cat "$prompt.err"); rm -f "$prompt.err"
fi

for p in "${POOL_PATTERNS[@]}"; do
  [[ "$out$err" == *"$p"* ]] || continue
  alert_rc=none
  log POOL_EXHAUSTED "$rc" none true null "matched '$p'"
  # High risk fails closed: the word "high" within 40 characters of "risk", in either order and any spelling, counts (zero-width
  # characters removed, other unicode spaces made spaces), and so does a card whose JSON cannot be read. A false alarm only queues.
  jq -e '(.task.body // "") | gsub("[\u00ad\u180e\u200b-\u200f\u2060-\u2064\ufeff]"; "") | gsub("[\r\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]"; " ") | test("risk.{0,40}high|high.{0,40}risk"; "is")' <<<"$card_json" >/dev/null 2>&1; jrc=$?
  case $jrc in 1) high="" ;; *) high=1 ;; esac   # 0 match = high, 1 no match = low, anything else (unreadable card) = high
  # T15: a low-risk call is served by the fallback runner (bin/omniroute-run.sh via the OmniRoute gateway) when the fallback config
  # (docs/hermes-local/fallback-routing.json) is enabled; the runner gets the call's purpose as its role. High-risk calls queue, never reroute; a replay stays a queued Claude call. The result is labelled
  # fallback with the model that served it and carries none of Claude's fields; a runner that names Claude or the
  # requested model family is refused, so a fallback cannot pass for a Claude result.
  FALLBACK_RUNNER=""
  if [ -z "$high" ] && [ -z "${ESCALATE_REPLAY:-}" ] && jq -e '.enabled == true' "$FALLBACK_CONFIG" >/dev/null 2>&1; then
    FALLBACK_RUNNER=$(jq -r '.runner // empty' "$FALLBACK_CONFIG"); [[ "$FALLBACK_RUNNER" == /* ]] || FALLBACK_RUNNER=/workspace/$FALLBACK_RUNNER
  fi
  skip_reason=""   # S6D-05: a prompt that looks like it holds a secret never leaves the machine (patterns are config data; the match is never logged)
  if [ -x "$FALLBACK_RUNNER" ]; then
    pi=0; while IFS= read -r pat; do pi=$((pi+1)); grep -Eq -- "$pat" "$prompt" 2>/dev/null && { skip_reason="the prompt matches blocked pattern #$pi (prompt_block_patterns)"; break; }; done < <(jq -r '.prompt_block_patterns[]? | strings' "$FALLBACK_CONFIG")
    [ -z "$skip_reason" ] || { log FALLBACK_SKIPPED null none true null "$skip_reason; queued instead"; FALLBACK_RUNNER=""; }
  fi
  if [ -x "$FALLBACK_RUNNER" ]; then
    fb=$(timeout "$CALL_TIMEOUT" "$FALLBACK_RUNNER" --role "$purpose" <"$prompt" 2>/dev/null); frc=$?
    served=""; jq -s -e 'length == 1 and (.[0] | type == "object" and (.model_used | type == "string") and (.text | type == "string"))' <<<"$fb" >/dev/null 2>&1 \
      && served=$(jq -r '.model_used' <<<"$fb"); sl=${served,,}
    if [ "$frc" = 0 ] && [[ "$served" =~ ^[A-Za-z0-9._:/+@-]{1,128}$ ]] && [[ "$sl" != *claude* && "$sl" != *"$model"* ]]; then
      log FALLBACK 0 "$served" true null "rerouted after POOL_EXHAUSTED (matched '$p')"
      hermes send --to "$ALERT_TARGET" --quiet "$(alert_text STL-LIM-404 card="$card" model="${model^}" served="$served" since="$(date -u +%FT%TZ)")" >/dev/null 2>&1; alert_rc=$?
      note "escalate.sh FALLBACK: $model ($purpose) for '$reason' was answered by a fallback model, not Claude. model_used: $served, fallback: true. Alert to $ALERT_TARGET exit $alert_rc."
      rm -f "$prompt"
      jq -c --arg m "$served" '{type: "result", is_error: false, fallback: true, model_used: $m, text: (.text // "")}' <<<"$fb"
      exit 0
    fi
    log FALLBACK_FAILED "$frc" "${served:-none}" true null "runner rc $frc, model '${served:-}': not usable; queued instead"
  fi
  queue POOL_EXHAUSTED "pool exhausted at $(date -u +%FT%TZ) (matched '$p')"   # the one #alerts line for this call
  if [ -n "$high" ]; then
    disposition="high-risk card; $qnote"
  else
    log NO_REROUTE "$rc" none true null "low-risk card; no usable fallback runner; $qnote"
    disposition="low-risk card, no usable fallback runner (NO_REROUTE); $qnote"
  fi
  note "escalate.sh POOL_EXHAUSTED: $model ($purpose) for '$reason'. No result. model_used: none, fallback: true. $disposition. Alert to $ALERT_TARGET exit $alert_rc."
  echo "escalate.sh: POOL_EXHAUSTED ($p); $disposition" >&2
  exit 75
done

model_used=$(jq -r '.modelUsage // {} | keys | join(",")' <<<"$out" 2>/dev/null)
cost=$(jq -r '.total_cost_usd // "null"' <<<"$out" 2>/dev/null) || cost=null
# exit 0 counts only with a parseable, non-error result
[ "$rc" -eq 0 ] && ! jq -e '.is_error == false' <<<"$out" >/dev/null 2>&1 && rc=1
if [ "$rc" -ne 0 ]; then
  log FAIL "$rc" "${model_used:-unknown}" false "${cost:-null}" "$(head -c 300 <<<"$out$err")"
  note "escalate.sh FAIL: $model ($purpose) exit $rc for '$reason'. model_used: ${model_used:-unknown}, fallback: false."
  rm -f "$prompt"   # F16: kept only while a queue entry points at it
  printf '%s\n' "$out"; printf '%s\n' "$err" >&2
  exit "$rc"
fi
log OK 0 "$model_used" false "$cost"
note "escalate.sh OK: $model ($purpose) for '$reason'. model_used: $model_used, fallback: false, cost_usd: $cost."
rm -f "$prompt"
printf '%s\n' "$out"
