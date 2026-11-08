#!/usr/bin/env bash
# Read-only overview of every escalated card (D31): card, live kanban status, latest escalation event and time,
# original title, and the thread URL. No Discord calls, no writes, also on a missing config (F27: the quiet reader,
# not escalation-discord.sh, which logs and alerts). usage: escalations-status.sh [--all]
# Default: only cards that are not archived; --all includes archived ones.
set -uo pipefail
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
. /workspace/bin/kanban-board.sh
. /workspace/bin/owner-config.sh
owner_config_read || { echo "escalations-status: owner config: $OWNER_CONFIG_ERROR" >&2; exit 3; }
SUP="${ESCALATE_SUP_DIR:-/workspace/.supervisor}"; LOG="$SUP/escalations.log"; MAP="$SUP/state/escalation-threads.tsv"
[ -s "$MAP" ] || { echo "no escalated cards"; exit 0; }
printf '%-11s %-9s %-16s %-20s %s\n' CARD STATUS LAST_EVENT AT TITLE
while IFS=$'\t' read -r -u 3 thread c _opened title; do
  [[ "$c" =~ ^t_[0-9a-f]{8}$ ]] || continue
  status=$(kanban show "$c" --json 2>/dev/null | jq -r '.task.status // "unknown"')
  [ "$status" = archived ] && [ "${1:-}" != --all ] && continue
  last=$(jq -r --arg c "$c" 'select(.card == $c) | "\(.event)\t\(.time)"' "$LOG" 2>/dev/null | tail -1)
  printf '%-11s %-9s %-16s %-20s %s\n' "$c" "$status" "$(cut -f1 <<<"$last")" "$(cut -f2 <<<"$last")" "${title:-?}"
  printf '%-11s %s\n' "" "https://discord.com/channels/${DISCORD_GUILD_ID:-?}/${thread}"
done 3<"$MAP"
