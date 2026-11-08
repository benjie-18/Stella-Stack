#!/usr/bin/env bash
# Report the completion of an escalated card, exactly once (D30): one COMPLETED line in escalations.log, one message in
# the card's #escalations thread (which doubles as its "Resolved" marker; the thread is not archived or locked), and
# one message in #supervisor. Both carry the deliverable's Windows path when the card created files (F4). Only for cards that have an escalation thread and are `done`.
# usage: escalation-complete.sh <card-id> [summary from the kanban_task_completed hook]
# Called by bin/escalation-on-complete.sh (hook) and by bin/escalation-reply-poll.sh (cron backstop).
set -uo pipefail
card="${1:-}"
hook_summary="${2:-}"
. /workspace/bin/escalation-discord.sh
DONE="$SUP/state/escalation-completed.tsv"   # card_id <TAB> target (thread|supervisor|legacy) <TAB> recorded_at
[[ "$card" =~ ^t_[0-9a-f]{8}$ ]] || exit 0
row=$(map_row "$card")
[ -n "$row" ] || exit 0                        # not an escalated card: nothing to report
exec 8>"$SUP/state/complete.lock"
flock 8                                        # hook and cron backstop never post twice
done_for() { grep -q "^${card}"$'\t'"$1"$'\t' "$DONE" 2>/dev/null; }
done_for legacy && exit 0
done_for thread && done_for supervisor && done_for delete_prompt && exit 0

json=$(kanban show "$card" --json 2>/dev/null) || exit 0
[ "$(jq -r '.task.status' <<<"$json")" = done ] || exit 0
thread=$(cut -f1 <<<"$row")
title=$(cut -f4 <<<"$row"); [ -n "$title" ] || title=$(jq -r '.task.title' <<<"$json")

# The worker's own summary first; a generic one ("Task complete.") falls back to the recorded thread reply.
summary=$(jq -r '.latest_summary // (.runs[-1].summary) // empty' <<<"$json")
[ -n "$summary" ] || summary="$hook_summary"
meta=$(jq -c '.runs[-1].metadata // {}' <<<"$json")
reply=$(jq -r --arg c "$card" 'select(.card == $c and .event == "REPLY") | .reply' "$LOG" 2>/dev/null | tail -1)
answered_by=$(jq -r --arg c "$card" 'select(.card == $c and .event == "REPLY") | .detail' "$LOG" 2>/dev/null | tail -1 | sed -nE 's/.* from ([^ ]+) .*/\1/p')
decision=$(jq -r '.decision // empty' <<<"$meta"); [ -n "$decision" ] || decision="$reply"
if [ -z "$summary" ] || grep -qiE '^[[:space:]]*(task complete|completed?|done|ok|finished)[.!]?[[:space:]]*$' <<<"$summary"; then
  summary="Decision: ${decision:-see card} (source: escalation reply, thread ${thread}${answered_by:+, answered by ${answered_by}})"
fi
# Polish: when the summary is just "Decision: <decision>", do not repeat it on a second line.
extra=""
[ "$summary" = "Decision: ${decision}" ] || extra=" Summary: ${summary}."
# The deliverable's Windows path (F4), computed here from workspace_path + files_created, never taken from the model.
win=$(jq -r --arg ws "$(jq -r '.task.workspace_path // empty' <<<"$json")" --arg root "${OWNER_STACK_PATH_WIN%\\}\\" \
  '[.files_created[]? | strings | if startswith("/") then . else $ws + "/" + . end | select(startswith("/workspace/"))
  | $root + (.[11:] | gsub("/"; "\\"))] | join(", ")' <<<"$meta")
[ -z "$win" ] || extra="${extra} Path: ${win}."
thread_line="Card ${card}: ${title}
Resolved: done. Decision: ${decision:-see summary}.${extra} Status: done."
sup_line="Done ${card}: \"${title}\". Decision: ${decision:-see summary}.${extra} Status: done."

if ! done_for thread; then
  if hermes send --to "discord:${ESCALATIONS_CHANNEL_ID}:${thread}" --quiet "$thread_line"; then
    printf '%s\tthread\t%s\n' "$card" "$(date -u +%FT%TZ)" >>"$DONE"
  else
    log COMPLETE_FAIL "hermes send to thread $thread failed"
  fi
fi
if ! done_for supervisor && [ -n "${SUPERVISOR_CHANNEL_ID:-}" ]; then
  # REST, not `hermes send`, which mirrors the line into Stella's #supervisor session as her own turn (F1).
  res=$(discord_action send_message "$SUPERVISOR_CHANNEL_ID" "$sup_line")
  if [ -n "$(jq -r '.message_id // empty' <<<"$res" 2>/dev/null)" ]; then
    printf '%s\tsupervisor\t%s\n' "$card" "$(date -u +%FT%TZ)" >>"$DONE"
  else
    log COMPLETE_FAIL "#supervisor (${SUPERVISOR_CHANNEL_ID}) post failed: $(jq -r '.error // empty' <<<"$res" 2>/dev/null | cut -c1-300)"
  fi
fi
set_status_reaction "$card" completed   # 🌟 on the reply (D32)
if done_for thread && done_for supervisor && ! done_for delete_prompt; then
  # Completion prompt (D37): 🔒 Archive (renamed, read-only) or 🗑️ Delete; no reaction keeps it. A Discord button click
  # would go to Hermes's gateway, which has no handler for it, so the choices are reactions; bin/escalation-reply-poll.sh
  # acts on them.
  res=$(discord_action send_message "$thread" "$PROMPT_TEXT")
  pm=$(jq -r '.message_id // empty' <<<"$res" 2>/dev/null)
  if [ -n "$pm" ]; then
    for e in "$CHOICE_ARCHIVE" "$CHOICE_DELETE"; do react_add_retry "$thread" "$pm" "$e"; done
    printf '%s\t%s\t%s\tpending\t%s\tv3\n' "$card" "$thread" "$pm" "$(date -u +%FT%TZ)" >>"$DEL"
    printf '%s\tdelete_prompt\t%s\n' "$card" "$(date -u +%FT%TZ)" >>"$DONE"
    log DELETE_PROMPT "posted in thread $thread (message $pm): $CHOICE_ARCHIVE archive (renamed, read-only), $CHOICE_DELETE delete"
  else
    log COMPLETE_FAIL "delete prompt in thread $thread failed: $(jq -r '.error // "no message id"' <<<"$res" 2>/dev/null | cut -c1-300)"
  fi
fi
if done_for thread && done_for supervisor && ! log_has "$card" COMPLETED; then
  jq -nc --arg time "$(date -u +%FT%TZ)" --arg card "$card" --arg thread "$thread" --arg reply "$reply" \
    --arg summary "$summary" --arg decision "$decision" \
    '{time: $time, card: $card, event: "COMPLETED",
      detail: ("thread " + $thread + "; decision \"" + $decision + "\"; summary \"" + $summary + "\"; status done"),
      thread: $thread, reply: $reply, summary: $summary, status: "done"}' >>"$LOG"
fi
