#!/usr/bin/env bash
# The only sanctioned way to run Claude Opus, Haiku or Sonnet: card-scoped, logged, rate-limited.
# usage: escalate.sh <card-id> <haiku|sonnet|opus> <purpose> <reason...> [-- <extra claude args>]
#   prompt on stdin; opus purpose must be in OPUS_PURPOSES (plan runs --model opusplan).
# Exit: 0 ok, 2 usage, 3 over a limit (never retried), 75 pool exhausted, else claude's exit code.
# Queue (F15, F28, F29): a call refused by a zeroed or exceeded limit (Opus slots, Haiku per day) and every pool-exhausted
# call is recorded in state/queue.jsonl with its prompt file, and raises one #alerts line; the caller still gets 3 or 75.
# Nothing retries it: bin/escalate-drain.sh (manual) replays it. Beyond QUEUE_MAX queued entries the call is refused
# unqueued (one #alerts line an hour). ESCALATE_REPLAY=<id> (set by the drain) never queues or alerts again.
# Test hook (Stage 6 T15): ESCALATE_FORCE_POOL_EXHAUSTED=1 skips claude and takes the fallback path.
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
set -uo pipefail
# cron/hook callers start with a minimal PATH; append so test stubs earlier in PATH still win.
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C.UTF-8   # F19: the inherited en_US.UTF-8 is not installed, so bash falls back to C and ${s:0:N} cuts bytes

SUP="${ESCALATE_SUP_DIR:-/workspace/.supervisor}"
LOG="$SUP/escalations.log"
STATE="$SUP/state"
mkdir -p "$STATE"
# shellcheck source=/dev/null
. "$SUP/limits.env" || { echo "escalate.sh: cannot read $SUP/limits.env" >&2; exit 2; }
. /workspace/bin/kanban-board.sh   # kanban(): every kanban call names its board (F4)
# `timeout 0` means no timeout, so 0, empty or non-numeric CALL_TIMEOUT falls back to the default (warned below, D42).
[[ "${CALL_TIMEOUT:-}" =~ ^[1-9][0-9]*[smhd]?$ ]] || { bad_timeout="${CALL_TIMEOUT:-}"; CALL_TIMEOUT=600; }

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
[ -z "${bad_timeout+x}" ] || { log WARN null "" false null "CALL_TIMEOUT='$bad_timeout' is not a positive duration (0 would disable the timeout); using 600"
  echo "escalate.sh: warning: CALL_TIMEOUT='$bad_timeout' is not a positive duration; using 600" >&2; }
refuse() { log "$1" "$2" "" false null "$3"; echo "escalate.sh: $1: $3" >&2; exit "$2"; }
note() { kanban comment --author escalate.sh "$card" "$1" >/dev/null 2>&1; }
. /workspace/bin/owner-config.sh   # once_per_hour, and alert_text (D44) through it
QUEUE="$STATE/queue.jsonl"
queue() {  # queue <LIMIT|POOL_EXHAUSTED> <what happened>: one entry and one #alerts line; sets qid ("" if not queued), qnote
  qid="" qnote="not queued"
  [ -z "${ESCALATE_REPLAY:-}" ] || { qnote="left in the queue as $ESCALATE_REPLAY"; rm -f "$prompt"; return 0; }
  exec 6>"$STATE/queue.lock"; flock 6
  if [ "$(jq -s '[.[] | select(.state == "queued")] | length' "$QUEUE" 2>/dev/null || echo 0)" -ge "${QUEUE_MAX:-50}" ]; then
    flock -u 6; rm -f "$prompt"
    qnote="not queued: the queue is full (QUEUE_MAX=${QUEUE_MAX:-50})"
    once_per_hour queue-full && hermes send --to "$ALERT_TARGET" --quiet "$(alert_text STL-LIM-403 max="${QUEUE_MAX:-50}" why="$1" card="$card" since="$(date -u +%FT%TZ)")" >/dev/null 2>&1
    return 0
  fi
  qid="q_$(date -u +%Y%m%dT%H%M%SZ)_${card}_$$"
  jq -nc --arg id "$qid" --arg card "$card" --arg model "$model" --arg purpose "$purpose" --arg call_reason "$reason" \
    --argjson claude_args "$(if [ ${#extra_args[@]} -gt 0 ]; then printf '%s\n' "${extra_args[@]}" | jq -Rsc 'split("\n")[:-1]'; else echo '[]'; fi)" \
    --arg why "$1" --arg detail "$2" --arg created "$(date -u +%FT%TZ)" --arg prompt_file "$prompt" \
    '{id: $id, card: $card, model: $model, purpose: $purpose, call_reason: $call_reason, claude_args: $claude_args,
      reason: $why, detail: $detail, created: $created, state: "queued", prompt_file: $prompt_file}' >>"$QUEUE"
  flock -u 6
  qnote="recorded in the queue as $qid; run bin/escalate-drain.sh"
  log QUEUED null none "$([ "$1" = POOL_EXHAUSTED ] && echo true || echo false)" null "$1; $qid"
  [ "$1" = POOL_EXHAUSTED ] && acode=STL-LIM-402 || acode=STL-LIM-401
  hermes send --to "$ALERT_TARGET" --quiet "$(alert_text "$acode" card="$card" model="${model^}" purpose="$purpose" queue_id="$qid" detail="$2" since="$(date -u +%FT%TZ)")" >/dev/null 2>&1
  alert_rc=$?
}
limit() { queue LIMIT "$1"; note "escalate.sh LIMIT: $model ($purpose) for '$reason': $1. No result; $qnote."; refuse LIMIT 3 "$1; $qnote"; }
extra_args=("$@")   # claude args after --, kept with a queue entry
for a in "${extra_args[@]}"; do   # review H2: claude takes the last of a repeated option, so these would override ours
  case "${a%%=*}" in
    --model|--fallback-model|--max-budget-usd|--permission-mode|--dangerously-skip-permissions|--allow-dangerously-skip-permissions|--yolo|--settings|--add-dir|--allowedTools|--allowed-tools)
      refuse USAGE 2 "extra claude arg $a would override escalate.sh's model, budget or permissions" ;;
  esac
done

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

prompt="$STATE/prompt-$(date -u +%Y%m%dT%H%M%SZ)-$card-$$.txt"
cat >"$prompt"
[ -s "$prompt" ] || { rm -f "$prompt"; refuse USAGE 2 "prompt required on stdin"; }

if [ "$model" = opus ]; then
  got=""
  for i in $(seq 1 "$OPUS_MAX_CONCURRENT"); do
    exec 8>"$STATE/opus.$i.lock"
    flock -n 8 && { got=1; break; }
  done
  [ -n "$got" ] || limit "no Opus slot free (OPUS_MAX_CONCURRENT=$OPUS_MAX_CONCURRENT)"
fi
if [ "$model" = haiku ]; then
  counter="$STATE/haiku-$(date -u +%F).count"
  exec 7>"$STATE/haiku.lock"
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
  queue POOL_EXHAUSTED "pool exhausted at $(date -u +%FT%TZ) (matched '$p')"   # the one #alerts line for this call
  # shortcut: no low-risk reroute, OmniRoute is deferred (T14); add it here when OmniRoute is installed.
  if jq -e '.task.body // "" | test("(?im)^risk: *high")' <<<"$card_json" >/dev/null; then
    disposition="high-risk card; $qnote"
  else
    log NO_REROUTE "$rc" none true null "low-risk card; OmniRoute reroute deferred; $qnote"
    disposition="low-risk card, OmniRoute reroute deferred (NO_REROUTE); $qnote"
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
