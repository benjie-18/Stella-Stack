#!/usr/bin/env bash
# Open (or reuse) the one #escalations thread for a blocked card. One card = one thread = one #supervisor
# notification; a new message in the thread only for a new, different decision (D29).
# usage: escalation-thread.sh <card-id> <card title> <decision or question needed...>
#        escalation-thread.sh --check          (read-only: channel_info on #escalations through the same helper path)
#        escalation-thread.sh --check create   (creates ONE clearly named test thread; isolation test only)
# Replies in the thread are recorded against the card by bin/escalation-reply-poll.sh (cron, every minute).
# Only a human decision gets a thread (F2): a capability block, or any block of a card already answered twice, goes to
# #alerts and a card comment instead, and stays blocked for triage.
set -uo pipefail
card=""
. /workspace/bin/escalation-discord.sh
POSTED="$SUP/state/escalation-posted.tsv"   # card_id <TAB> thread_id <TAB> reason_sha <TAB> posted_at
fail() {  # THREAD_FAIL, and one #alerts message per card an hour (F1, STL-ESC-220): card, title cut to 80 characters; the error logged
  local t="${summary:-}"
  log THREAD_FAIL "$1"; echo "escalation-thread.sh: $1" >&2
  # A poller retry (ESCALATION_RETRY) stays quiet: it raises its own single line after the third attempt.
  [ -z "${ESCALATION_RETRY:-}" ] && once_per_hour "thread-fail-${card//[^a-z0-9_]/}" \
    && alert STL-ESC-220 card="${card:-unknown}" title="${t:0:80}" error="${1:0:900}"
  exit "${2:-1}"
}

if [ "${1:-}" = "--check" ]; then
  [ -n "$ESCALATIONS_CHANNEL_ID" ] || { log CHECK_FAIL "ESCALATIONS_CHANNEL_ID is empty in config/owner.env"; exit 3; }
  if [ "${2:-}" = create ]; then   # `--check create`: one real, clearly named test thread, for an isolation test only
    res=$(discord_action create_thread "$ESCALATIONS_CHANNEL_ID" "T16 create_thread self-test $(date -u +%FT%TZ), safe to delete")
    log CHECK "create_thread channel=$ESCALATIONS_CHANNEL_ID result=${res:0:700}"
  else
    res=$(discord_action channel_info "$ESCALATIONS_CHANNEL_ID")
    log CHECK "channel_info channel=$ESCALATIONS_CHANNEL_ID result=${res:0:700}"
  fi
  printf '%s\n' "$res"
  exit 0
fi

card="${1:-}" summary="${2:-}"
shift $(( $# < 2 ? $# : 2 ))
question="$*"

[[ "$card" =~ ^t_[0-9a-f]{8}$ ]] && [ -n "$summary" ] && [ -n "$question" ] \
  || fail "usage: escalation-thread.sh <card-id> <card title> <question>" 2
[ -n "$ESCALATIONS_CHANNEL_ID" ] || fail "ESCALATIONS_CHANNEL_ID is empty in config/owner.env" 3

q=$(normalize_reason "$question")
[ -n "$q" ] || q="see the card for the decision needed"
qsha=$(printf '%s' "$q" | sha256sum | cut -c1-16)
# One run per card at a time (F7), from the map lookup to the last post: a second block inside the create window waits,
# then finds this run's thread and fingerprint. The poller's retry (F1) runs this script, so it takes the same lock.
exec 8>"$SUP/state/thread-$card.lock"
lw=120; [ -z "${ESCALATION_RETRY:-}" ] || lw=5   # a poller retry must not stall its pass (review M3); it comes back later
flock -w "$lw" 8 || { [ -z "${ESCALATION_RETRY:-}" ] || exit 75; fail "another escalation-thread.sh run for $card still holds state/thread-$card.lock after $lw s"; }   # 75: busy, the retry comes back

show=$(kanban show "$card" --json 2>/dev/null)
if [ "$(answers "$card")" -ge 2 ]; then
  n=$(jq -r '[.events[]? | select(.kind == "blocked")] | length' <<<"$show" 2>/dev/null)
  log LOOP_HELD "block ${n:-?} after 2 recorded answers; nothing posted, card left blocked for triage; cause: ${q:0:300}"
  alert STL-ESC-230 card="$card" count="${n:-unknown}" title="$summary" reason="${q:0:300}"
  kanban comment --author escalation-thread.sh "$card" "Loop held: block ${n:-?} after two answered escalations. No new escalation is posted and no reply unblocks this card automatically; held for triage." >/dev/null
  exit 0
fi
if [ "$(jq -r '[.events[]? | select(.kind == "blocked")] | last | .payload.kind // empty' <<<"$show" 2>/dev/null)" = capability ]; then
  # K12: the profile's capability_fallback (roles.json) names who may manage what this one could not; none = no suggestion
  alt=$(jq -r --arg a "$(jq -r '.task.assignee // empty' <<<"$show" 2>/dev/null)" '.profiles[$a].capability_fallback // empty' \
    /workspace/docs/hermes-local/roles.json 2>/dev/null)
  sug=""; [ -z "$alt" ] || sug=" Suggestion: reassign to $alt."
  log CAPABILITY_HELD "capability block routed to triage, no thread; error: ${q:0:300}"
  alert STL-ESC-231 card="$card" title="$summary" error="$q" suggestion="${sug# }"
  kanban comment --author escalation-thread.sh "$card" "Capability block held for triage (not a human decision, no #escalations thread). What the worker wrote is its own claim, not checked by the stack. Error: ${q}${sug}" >/dev/null
  exit 0
fi

# The thread map is checked first: an existing thread for this card is reused, never re-created or re-announced.
row=$(map_row "$card")              # a deleted thread (D32) is never reused: the card then gets a new one
thread=$(cut -f1 <<<"$row")
title=$(cut -f4 <<<"$row")          # original title, saved when the thread was created
if [ -n "$thread" ]; then
  # Same card, same decision (fingerprint already posted): nothing to post. That is a re-block of an answered or
  # pending decision, which is the loop signal when the card already has a recorded reply.
  if grep -q "^${card}"$'\t'"${thread}"$'\t'"${qsha}"$'\t' "$POSTED" 2>/dev/null; then
    if grep -q $'\t'"${card}"$'\t'"${thread}"$'\t' "$SEEN" 2>/dev/null; then
      log LOOP_DETECTED "re-block for the same decision after a recorded reply in thread $thread; nothing posted; cause: ${q:0:300}"
      kanban comment --author escalation-thread.sh "$card" "Loop detected: this card blocked again for the same decision after the reply in thread $thread was recorded. No new escalation was posted. The recorded reply is the answer; use it and complete the card." >/dev/null
    else
      log ESCALATION_SKIP "same decision already posted in thread $thread; nothing posted"
    fi
    exit 0
  fi
  [ -n "$title" ] || title="${summary:0:100}"
  log THREAD_REUSED "thread $thread; new, different decision"
else
  # A new card: the thread name is "<card id> · <original title>" (F6), so two threads opened together never look alike.
  title=$(printf '%s' "${summary:0:100}" | tr '\t\n' '  ')
  res=$(discord_action create_thread "$ESCALATIONS_CHANNEL_ID" "$(name100 "$card · $title")")
  thread=$(jq -r '.thread_id // empty' <<<"$res" 2>/dev/null)
  if [ -z "$thread" ]; then
    err=$(jq -r '.error // empty' <<<"$res" 2>/dev/null)
    stage=$(jq -r '.stage // "create_thread (Discord or helper returned an error)"' <<<"$res" 2>/dev/null)
    tb=$(jq -r '.traceback // empty' <<<"$res" 2>/dev/null)
    [ -n "$err" ] || err="unparseable helper output: ${res:-(empty)}"
    code=$(grep -oE 'Discord API error [0-9]{3}' <<<"$err" | grep -oE '[0-9]{3}$' | head -1)
    fail "create_thread failed: channel=$ESCALATIONS_CHANNEL_ID name=\"$title\" http=${code:-none} stage=${stage:-unknown} error=${err:0:900}${tb:+ traceback=${tb}}"
  fi
  printf '%s\t%s\t%s\t%s\n' "$thread" "$card" "$(date -u +%FT%TZ)" "$title" >>"$MAP"
fi

# The first message posted in this thread opens it (THREAD_OPENED, card comment, #supervisor link): normally a new
# thread, or a mapped thread whose first message failed and is retried by the poller (review H1).
first=1; [ -n "$row" ] && grep -q "^${card}"$'\t'"${thread}"$'\t' "$POSTED" 2>/dev/null && first=""
ask="Reply with your instruction in plain words."
has_options "$q" && ask="Reply in this thread with your decision (for example: Option A)."
msg="Card ${card}: ${title}
Decision needed: ${q}
${ask} Your reply is recorded on ${card} and unblocks it."
hermes send --to "discord:${ESCALATIONS_CHANNEL_ID}:${thread}" --quiet "$msg" || fail "hermes send to thread $thread failed"
printf '%s\t%s\t%s\t%s\n' "$card" "$thread" "$qsha" "$(date -u +%FT%TZ)" >>"$POSTED"

if [ -n "$first" ]; then
  log THREAD_OPENED "thread $thread"
  link="https://discord.com/channels/${DISCORD_GUILD_ID}/${thread}"
  kanban comment --author escalation-thread.sh "$card" "Escalation thread opened in #escalations: thread_id $thread, $link" >/dev/null
  # One #supervisor notification per card, on the first thread only (D29): card id, original title, decision once,
  # one link in one format (a <#thread> mention, which Discord shows as a clickable thread name).
  # REST, not `hermes send`: hermes send mirrors the text into Stella's #supervisor session as her own turn, and she
  # then copies it into her replies (F1).
  if [ -n "${SUPERVISOR_CHANNEL_ID:-}" ]; then
    res=$(discord_action send_message "$SUPERVISOR_CHANNEL_ID" "Escalation ${card}: \"${title}\". Decision needed: ${q} Reply in <#${thread}>")
    if [ -n "$(jq -r '.message_id // empty' <<<"$res" 2>/dev/null)" ]; then
      log LINK_POSTED "supervisor ${SUPERVISOR_CHANNEL_ID}: <#${thread}>"
    else
      log LINK_FAIL "#supervisor (${SUPERVISOR_CHANNEL_ID}) post failed for thread ${thread}: $(jq -r '.error // empty' <<<"$res" 2>/dev/null | cut -c1-300)"
      # F5: the link is the only notice outside #escalations; never posted again, so say it once.
      once_per_hour "link-fail-$card" && alert STL-ESC-222 card="$card" thread="$thread" error="$(jq -r '.error // "no message id"' <<<"$res" 2>/dev/null | cut -c1-300)"
    fi
  else
    log LINK_FAIL "SUPERVISOR_CHANNEL_ID missing in config/owner.env"
  fi
else
  log ESCALATION_POSTED "new decision posted in existing thread $thread (no new link)"
fi
echo "$thread"
