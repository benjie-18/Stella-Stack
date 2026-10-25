#!/usr/bin/env bash
# The only sanctioned way to run Claude Opus, Haiku or Sonnet: card-scoped, logged, rate-limited.
# usage: escalate.sh <card-id> <haiku|sonnet|opus> <purpose> <reason...> [-- <extra claude args>]
#   prompt on stdin; opus purpose must be in OPUS_PURPOSES (plan runs --model opusplan).
# Exit: 0 ok, 2 usage, 3 over a limit (never retried), 75 pool exhausted, else claude's exit code.
# Test hook (Stage 6 T15): ESCALATE_FORCE_POOL_EXHAUSTED=1 skips claude and takes the fallback path.
set -uo pipefail
# cron/hook callers start with a minimal PATH; append so test stubs earlier in PATH still win.
export PATH="$PATH:/home/node/.local/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"

SUP="${ESCALATE_SUP_DIR:-/workspace/.supervisor}"
LOG="$SUP/escalations.log"
STATE="$SUP/state"
mkdir -p "$STATE"
# shellcheck source=/dev/null
. "$SUP/limits.env" || { echo "escalate.sh: cannot read $SUP/limits.env" >&2; exit 2; }

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
note() { hermes kanban comment --author escalate.sh "$card" "$1" >/dev/null 2>&1; }

[[ "$card" =~ ^t_[0-9a-f]{8}$ ]] || refuse USAGE 2 "card id required (t_xxxxxxxx), got '${card}'"
[ -n "$reason" ] || refuse USAGE 2 "reason required"
card_json=$(hermes kanban show "$card" --json 2>/dev/null) || refuse USAGE 2 "card $card not found on the board"
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
  [ -n "$got" ] || refuse LIMIT 3 "an Opus call is already running (OPUS_MAX_CONCURRENT=$OPUS_MAX_CONCURRENT); not retrying"
fi
if [ "$model" = haiku ]; then
  counter="$STATE/haiku-$(date -u +%F).count"
  exec 7>"$STATE/haiku.lock"
  flock 7
  n=$(cat "$counter" 2>/dev/null || echo 0)
  [ "$n" -lt "$HAIKU_MAX_PER_DAY" ] || refuse LIMIT 3 "Haiku daily limit reached ($n/$HAIKU_MAX_PER_DAY for $(date -u +%F)); not retrying"
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
  hermes send --to "$ALERT_TARGET" --quiet \
    "escalate.sh POOL_EXHAUSTED: $card $model ($purpose) at $(date -u +%FT%TZ); matched '$p'" >/dev/null 2>&1
  alert_rc=$?
  log POOL_EXHAUSTED "$rc" none true null "matched '$p'; alert $ALERT_TARGET exit $alert_rc"
  # shortcut: no low-risk reroute, OmniRoute is deferred (T14); add it here when OmniRoute is installed.
  if jq -e '.task.body // "" | test("(?im)^risk: *high")' <<<"$card_json" >/dev/null; then
    jq -nc --arg card "$card" --arg model "$model" --arg purpose "$purpose" --arg reason "$reason" \
      --arg prompt "$prompt" --arg time "$(date -u +%FT%TZ)" \
      '{time: $time, card: $card, model: $model, purpose: $purpose, reason: $reason, prompt_file: $prompt}' >>"$STATE/queue.jsonl"
    log QUEUED "$rc" none true null "high-risk card; queued in state/queue.jsonl"
    disposition="queued for retry (high-risk card)"
  else
    log NO_REROUTE "$rc" none true null "low-risk card; OmniRoute reroute deferred"
    disposition="not queued (low-risk; OmniRoute reroute deferred)"
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
  printf '%s\n' "$out"; printf '%s\n' "$err" >&2
  exit "$rc"
fi
log OK 0 "$model_used" false "$cost"
note "escalate.sh OK: $model ($purpose) for '$reason'. model_used: $model_used, fallback: false, cost_usd: $cost."
rm -f "$prompt"
printf '%s\n' "$out"
