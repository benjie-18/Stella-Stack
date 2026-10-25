#!/usr/bin/env bash
# Open (or reuse) the one #escalations thread for a blocked card and post the escalation message.
# usage: escalation-thread.sh <card-id> <short summary> <decision or question needed...>
# Replies in the thread are recorded against the card by bin/escalation-reply-hook.sh.
set -uo pipefail
export PATH="$PATH:/home/node/.local/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
SUP="${ESCALATE_SUP_DIR:-/workspace/.supervisor}"
LOG="$SUP/escalations.log"
MAP="$SUP/state/escalation-threads.tsv"   # thread_id <TAB> card_id <TAB> opened_at
HERMES_PY=/home/node/.hermes/tools/python-3.14.9+20261021-linux-x64/bin/python3
mkdir -p "$SUP/state"
# shellcheck source=/dev/null
. "$SUP/limits.env"

card="${1:-}" summary="${2:-}"
shift $(( $# < 2 ? $# : 2 ))
question="$*"
log() { jq -nc --arg time "$(date -u +%FT%TZ)" --arg card "$card" --arg event "$1" --arg detail "$2" \
  '{time: $time, card: $card, event: $event, detail: $detail}' >>"$LOG"; }
fail() { log THREAD_FAIL "$1"; echo "escalation-thread.sh: $1" >&2; exit "${2:-1}"; }

[[ "$card" =~ ^t_[0-9a-f]{8}$ ]] && [ -n "$summary" ] && [ -n "$question" ] \
  || fail "usage: escalation-thread.sh <card-id> <summary> <question>" 2
card_json=$(hermes kanban show "$card" --json 2>/dev/null) || fail "card $card not found" 2
[ -n "$ESCALATIONS_CHANNEL_ID" ] || fail "ESCALATIONS_CHANNEL_ID is empty in limits.env (Discord not connected yet)" 3

title=$(jq -r '.task.title' <<<"$card_json")
blocked=$(jq -r '[.events[]? | select(.kind | test("block"))] | last | .payload.reason? // empty' <<<"$card_json")
thread=$(awk -F'\t' -v c="$card" '$2 == c { print $1; exit }' "$MAP" 2>/dev/null)
if [ -z "$thread" ]; then
  # Hermes's own Discord helper resolves the bot token; this script never sees it.
  res=$(cd /tmp && "$HERMES_PY" -I - "$ESCALATIONS_CHANNEL_ID" "${card} ${summary:0:80}" <<'PY'
import sys; sys.path.insert(0, "/home/node/.hermes/hermes-agent")
from tools.discord_tool import _run_discord_action, _CORE_ACTIONS
print(_run_discord_action("create_thread", _CORE_ACTIONS, "discord", channel_id=sys.argv[1], name=sys.argv[2]))
PY
  )
  thread=$(jq -r '.thread_id // empty' <<<"$res" 2>/dev/null)
  [ -n "$thread" ] || fail "create_thread failed: ${res:0:300}"
  printf '%s\t%s\t%s\n' "$thread" "$card" "$(date -u +%FT%TZ)" >>"$MAP"
fi

msg="Escalation ${card}
Task: ${title}
Blocked: ${blocked:-see card}
Decision needed: ${question}
Reply in this thread: the reply is recorded on ${card} and unblocks it."
hermes send --to "discord:${ESCALATIONS_CHANNEL_ID}:${thread}" --quiet "$msg" || fail "hermes send to thread $thread failed"
log THREAD_OPENED "thread $thread"
hermes kanban comment --author escalation-thread.sh "$card" "Escalation thread opened in #escalations: thread_id $thread" >/dev/null
echo "$thread"
