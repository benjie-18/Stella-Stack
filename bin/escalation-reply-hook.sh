#!/usr/bin/env bash
# Hermes post_gateway_admission shell hook: a Discord message in a card's #escalations thread is
# recorded against that card (escalations.log + card comment) and unblocks it. Prints nothing,
# so the message still reaches the supervisor agent as usual.
set -uo pipefail
export PATH="$PATH:/home/node/.local/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
SUP="${ESCALATE_SUP_DIR:-/workspace/.supervisor}"
MAP="$SUP/state/escalation-threads.tsv"
p=$(cat)
[ "$(jq -r '.extra.platform // ""' <<<"$p")" = discord ] || exit 0
thread=$(jq -r '.extra.source.thread_id // .extra.source.chat_id // ""' <<<"$p")
card=$(awk -F'\t' -v t="$thread" '$1 == t && t != "" { print $2; exit }' "$MAP" 2>/dev/null)
[ -n "$card" ] || exit 0
user=$(jq -r '.extra.source.user_name // .extra.source.user_id // "unknown"' <<<"$p")
text=$(jq -r '.extra.text // ""' <<<"$p")
jq -nc --arg time "$(date -u +%FT%TZ)" --arg card "$card" --arg thread "$thread" --arg user "$user" --arg text "$text" \
  '{time: $time, card: $card, event: "REPLY", detail: ("thread " + $thread + " from " + $user), reply: $text}' >>"$SUP/escalations.log"
hermes kanban unblock --reason "escalation reply from discord:$user in thread $thread: $text" "$card" >/dev/null 2>&1
exit 0
