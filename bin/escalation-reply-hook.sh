#!/usr/bin/env bash
# Hermes post_gateway_admission shell hook: a Discord message in a card's #escalations thread is
# recorded against that card (escalations.log + card comment) and unblocks it. Prints nothing,
# so the message still reaches the supervisor agent as usual.
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
acct_home=$(getent passwd "$(id -u)" | cut -d: -f6)
[ -n "$acct_home" ] && export HOME=$acct_home  # RT-RTA-01: hermes reads pip.conf, ~/.hermes and git config under HOME, a folder the worker writes; run as cron does
set -uo pipefail
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C.UTF-8   # F19: the inherited en_US.UTF-8 is not installed, so bash falls back to C and ${s:0:N} cuts bytes
. /workspace/bin/kanban-board.sh   # kanban(): every kanban call names its board (F4)
SUP="${ESCALATE_SUP_DIR:-/workspace/.supervisor}"
MAP="$SUP/state/escalation-threads.tsv"
p=$(cat)
[ "$(jq -r '.extra.platform // ""' <<<"$p")" = discord ] || exit 0
thread=$(jq -r '.extra.source.thread_id // .extra.source.chat_id // ""' <<<"$p")
card=$(awk -F'\t' -v t="$thread" '$1 == t && t != "" { print $2; exit }' "$MAP" 2>/dev/null)
[ -n "$card" ] || exit 0
# Only the owner's reply is recorded here (D39, D72). Anything else, an empty or malformed id, or an unreadable config, is
# left to bin/escalation-reply-poll.sh, which logs and alerts it and never marks a non-owner reply seen.
. /workspace/bin/owner-config.sh
owner_config_read || exit 0
[[ $OWNER_DISCORD_USER_ID =~ $OWNER_ID_RE ]] && [ "$(jq -r '.extra.source.user_id // empty' <<<"$p")" = "$OWNER_DISCORD_USER_ID" ] || exit 0
# Same ledger as bin/escalation-reply-poll.sh (D28): a reply is recorded once, whichever path sees it first.
SEEN="$SUP/state/escalation-replies.tsv"
mid=$(jq -r '.extra.message_id // empty' <<<"$p")
[ -n "$mid" ] && grep -q "^${mid}"$'\t' "$SEEN" 2>/dev/null && exit 0
[ "$(kanban show "$card" --json 2>/dev/null | jq -r '.task.status // empty')" = blocked ] || exit 0
user=$(jq -r '.extra.source.user_name // .extra.source.user_id // "unknown"' <<<"$p")
text=$(jq -r '.extra.text // ""' <<<"$p")
# Seen only once applied (F2, review M4): a failed unblock leaves the reply to the poller, which retries it.
kanban unblock --reason "escalation reply from discord:$user in thread $thread: $text" "$card" >/dev/null 2>&1 || exit 0
[ -n "$mid" ] && printf '%s\t%s\t%s\t%s\n' "$mid" "$card" "$thread" "$(date -u +%FT%TZ)" >>"$SEEN"
jq -nc --arg time "$(date -u +%FT%TZ)" --arg card "$card" --arg thread "$thread" --arg user "$user" --arg text "$text" \
  '{time: $time, card: $card, event: "REPLY", detail: ("thread " + $thread + " from " + $user), reply: $text}' >>"$SUP/escalations.log"
exit 0
