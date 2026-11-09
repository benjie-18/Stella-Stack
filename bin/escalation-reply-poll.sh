#!/usr/bin/env bash
# Container cron, every minute: record a reply in each blocked card's #escalations thread (D28). The Discord gateway
# does not deliver #escalations thread messages to Hermes (no inbound line, so the post_gateway_admission reply hook
# never sees them), so read each thread through the Discord API instead, with Hermes's own token loader.
# Each run makes POLL_PASSES passes POLL_EVERY seconds apart under the one lock (F5: a reply is seen within ~15 s, not
# up to a minute). For every mapped thread whose card is still `blocked`: take the oldest human (non-bot) message not
# yet seen, log it as REPLY, and unblock the card with the reply as the reason. Discord errors are logged as POLL_FAIL.
# A reply is not applied (F2), only logged, when the card was already answered twice (LOOP_HELD: #alerts + comment),
# when its block is kind capability (triage), or when it is a bare "A"/"Option B" and the block reason has no options
# (REPLY_UNMATCHED: ❓ on the reply and one line asking for an instruction).
# For a mapped card that is `done`: report its completion once (bin/escalation-complete.sh, D30).
# Also: 👀 reaction on a recorded reply, and the completion prompts: archive or delete (D32, D37).
# Who may answer (D39): only OWNER_DISCORD_USER_ID's replies and 🔒/🗑️ reactions count (bots never do). Another human's
# reply is REPLY_IGNORED_NOT_OWNER (logged once per message, at most one #alerts line an hour) and is NOT marked seen, so
# it is applied on the next pass after a wrong id is fixed. config/owner.env is re-read on every pass: no restart.
# Fail closed (D72): with an empty or malformed id nobody may answer. No reply or reaction counts, replies are not marked
# seen (the owner's is applied on the next pass after the fix), and STL-CFG-302 is alerted (empty: hourly; malformed: once).
# Failure paths: every pass writes state/reply-poll.heartbeat (watchdog.sh alerts when it goes stale); an unreadable
# board is POLL_FAIL plus #alerts at most hourly (F3); 3 failed reads of one thread in a row raise #alerts at most hourly
# (F6); a reply is marked seen only after its unblock worked (F2); a blocked needs_input card with no thread is retried
# (F1, first pass of a run only, at most 3 attempts 1, 5 and 15 min apart, then one #alerts line). A silent block (D46
# item 9: blocked with no `blocked` event, e.g. the dispatcher gave up, so no hook fired) gets one STL-ESC-232 alert and
# the same escalation path, once per block, after a 3-minute grace, retried the same way.
set -uo pipefail
card=""
. /workspace/bin/escalation-discord.sh
exec 9>"$SUP/state/reply-poll.lock"
flock -n 9 || exit 0   # one poll at a time; a slow Discord call must not stack cron runs
POLL_EVERY="${POLL_EVERY:-12}" POLL_PASSES="${POLL_PASSES:-5}"
RETRY="$SUP/state/thread-retry.tsv"   # card <TAB> block created_at <TAB> attempts <TAB> last attempt (epoch) <TAB> state (F1)
SILENT="$SUP/state/silent-blocks.tsv"   # card <TAB> block event time <TAB> event kind <TAB> attempts <TAB> last (epoch) <TAB> state (D46)
read -r -a BACKOFF <<<"${RETRY_BACKOFF:-60 300 900}"   # seconds before attempts 1, 2 and 3
SKIP="$SUP/state/escalation-skipped.tsv"   # message_id <TAB> card_id <TAB> thread_id <TAB> why <TAB> at: replies not applied
BARE_OPTION='^[[:space:]]*([Oo]ption[[:space:]]+)?[A-Da-d][.!)]?[[:space:]]*$'
IGNORED="$SUP/state/escalation-ignored.tsv"   # message_id <TAB> card_id <TAB> thread_id <TAB> author_id <TAB> at (D39)

owner_id() {  # sets OWNER: the owner's valid id, or empty: nobody may answer until it is fixed (D72)
  owner_config_load || exit 3
  OWNER=""
  if [ -z "$OWNER_DISCORD_USER_ID" ]; then
    [ -n "${warned:-}" ] || { warned=1; echo "escalation-reply-poll: OWNER_DISCORD_USER_ID is empty; no reply or reaction is applied" >&2
      once_per_hour owner-id-empty && { log OWNER_ID_EMPTY "OWNER_DISCORD_USER_ID is empty in config/owner.env: no reply or reaction is applied until it is set"; alert STL-CFG-302; }; }
  elif [[ $OWNER_DISCORD_USER_ID =~ $OWNER_ID_RE ]]; then
    OWNER=$OWNER_DISCORD_USER_ID; rm -f "$SUP/state/owner-id-invalid"
  elif [ "$(cat "$SUP/state/owner-id-invalid" 2>/dev/null)" != "$OWNER_DISCORD_USER_ID" ]; then
    printf '%s' "$OWNER_DISCORD_USER_ID" >"$SUP/state/owner-id-invalid"
    log OWNER_ID_INVALID "OWNER_DISCORD_USER_ID \"${OWNER_DISCORD_USER_ID:0:40}\" is not a 17-20 digit id; no reply or reaction is applied until it is fixed"
    alert STL-CFG-302
  fi
}

ignore_reply() {  # ignore_reply <message id> <author id>: a non-owner's reply, never marked seen
  grep -q "^$1"$'\t' "$IGNORED" 2>/dev/null && return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$card" "$thread" "$2" "$(date -u +%FT%TZ)" >>"$IGNORED"
  log REPLY_IGNORED_NOT_OWNER "reply $1 in thread $thread from id ${2:-unknown} is not OWNER_DISCORD_USER_ID; not applied, not marked seen"
  # With no valid id, STL-CFG-302 is the alert: "someone else replied" would point the owner at the wrong problem.
  if [ -n "$OWNER" ] && once_per_hour reply-ignored; then
    alert STL-ESC-240 card="$card" author="${2:-unknown}" message="$1" thread="$thread"
  fi
}

silent_block() {  # D46 item 9: blocked, but its latest block is not a `blocked` event (the dispatcher gave up after its retry
  # limit, t_53af3e0d), so kanban_task_blocked never fired and no thread opened. One alert and one escalation per block,
  # keyed on card + that event's time in $SILENT (survives restarts; a re-block after an unblock is a new key), after a
  # grace of SILENT_GRACE s (at least two runs), retried like F1 (3 attempts on BACKOFF, then STL-ESC-221).
  local c=$1 show=$2 ev=$3 at kind row n last st now title why by rc
  now=$(date +%s); at=$(jq -r '.created_at // 0' <<<"$ev"); kind=$(jq -r '.kind // "unknown"' <<<"$ev")
  row=$(awk -F'\t' -v c="$c" -v a="$at" '$1 == c && $2 == a { r = $0 } END { print r }' "$SILENT" 2>/dev/null)
  n=$(cut -f4 <<<"$row"); n=${n:-0}; last=$(cut -f5 <<<"$row"); st=$(cut -f6 <<<"$row")
  case "$st" in posted|already_posted|gave_up) return 0 ;; esac
  [ $((now - at)) -ge "${SILENT_GRACE:-180}" ] || return 0
  [ -z "$row" ] || [ "$n" = 0 ] || [ $((now - ${last:-0})) -ge "${BACKOFF[$n]:-900}" ] || return 0
  if [ -z "$row" ] && awk -F'\t' -v c="$c" -v a="$(date -u -d "@$at" +%FT%TZ)" '$1 == c && $4 >= a { f = 1 } END { exit !f }' \
       "$SUP/state/escalation-posted.tsv" 2>/dev/null; then   # this block already has its thread message: nothing to add
    printf '%s\t%s\t%s\t0\t%s\talready_posted\n' "$c" "$at" "$kind" "$now" >>"$SILENT"; return 0
  fi
  title=$(jq -r '.task.title // empty' <<<"$show")
  why=$(jq -r '.payload.error // .payload.reason // empty' <<<"$ev" | tr '\n' ' ' | cut -c1-300)
  if [ "$kind" = gave_up ]; then by="the dispatcher gave up after $(jq -r '.payload.failures // "repeated"' <<<"$ev") failed starts"; else by="event $kind"; fi
  if [ -z "$row" ]; then
    card="$c" log SILENT_BLOCK "blocked by $kind at $(date -u -d "@$at" +%FT%TZ) with no blocked event, so no hook fired: escalating"
    alert STL-ESC-232 card="$c" title="${title:0:80}" by="$by" reason="${why:-see the card}"
    printf '%s\t%s\t%s\t0\t%s\tdetected\n' "$c" "$at" "$kind" "$now" >>"$SILENT"
  fi
  ESCALATION_RETRY=1 /workspace/bin/escalation-thread.sh "$c" "${title:0:100}" "Blocked at $(date -u -d "@$at" +%FT%TZ) without an escalation ($by): ${why:-see the card}" >/dev/null 2>&1
  rc=$?
  [ "$rc" = 75 ] && return 0   # the card lock is busy: not an attempt
  n=$((n + 1))
  if [ "$rc" = 0 ]; then st=posted; elif [ "$n" -ge 3 ]; then st=gave_up; else st=retrying; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$at" "$kind" "$n" "$(date +%s)" "$st" >>"$SILENT"
  card="$c" log SILENT_BLOCK "escalation attempt $n of 3: $st"
  [ "$st" = gave_up ] && alert STL-ESC-221 card="$c" title="${title:0:80}"
  return 0
}

retry_threads() {  # F1: escalation-thread.sh again for each blocked needs_input card with no thread, or a thread with nothing posted (H1)
  local c st show block at row n last title reason now th q rc
  now=$(date +%s)
  while IFS=$'\t' read -r c st; do
    [ "$st" = blocked ] && [[ "$c" =~ ^t_[0-9a-f]{8}$ ]] || continue
    th=$(map_row "$c" | cut -f1)
    show=$(kanban show "$c" --json 2>/dev/null) || continue
    ev=$(jq -c '[.events[]? | select(.kind == "blocked" or .kind == "gave_up")] | sort_by(.created_at) | last // ([.events[]?] | last) // {}' <<<"$show")
    if [ "$(jq -r '.kind // empty' <<<"$ev")" != blocked ]; then silent_block "$c" "$show" "$ev"; continue; fi
    block=$(jq -c '[.events[]? | select(.kind == "blocked")] | last // {}' <<<"$show")
    [ "$(jq -r '.payload.kind // empty' <<<"$block")" = needs_input ] && [ "$(answers "$c")" = 0 ] || continue
    # Already posted in its thread = this decision's fingerprint is in the ledger (as escalation-thread.sh computes it).
    q=$(normalize_reason "$(jq -r '.payload.reason // empty' <<<"$block")"); [ -n "$q" ] || q="see the card for the decision needed"
    [ -z "$th" ] || ! grep -q "^${c}"$'\t'"${th}"$'\t'"$(printf '%s' "$q" | sha256sum | cut -c1-16)"$'\t' "$SUP/state/escalation-posted.tsv" 2>/dev/null || continue
    at=$(jq -r '.created_at // 0' <<<"$block")
    row=$(awk -F'\t' -v c="$c" -v a="$at" '$1 == c && $2 == a { r = $0 } END { print r }' "$RETRY" 2>/dev/null)
    n=$(cut -f3 <<<"$row"); n=${n:-0}; last=$(cut -f4 <<<"$row"); last=${last:-$at}
    [ "$(cut -f5 <<<"$row")" != gave_up ] && [ "$n" -lt 3 ] && [ $((now - last)) -ge "${BACKOFF[$n]:-900}" ] || continue
    n=$((n + 1))
    title=$(jq -r '.task.title // empty' <<<"$show"); reason=$(jq -r '.payload.reason // empty' <<<"$block")
    # The thread script's per-card lock (F7) and map check: a retry never opens a second thread.
    ESCALATION_RETRY=1 /workspace/bin/escalation-thread.sh "$c" "${title:0:100}" "${reason:-see the card for the decision needed}" >/dev/null 2>&1
    rc=$?
    [ "$rc" = 75 ] && continue   # the card lock is busy (another run is on it): not an attempt
    if [ "$rc" = 0 ]; then st=posted
    elif [ "$n" -ge 3 ]; then st=gave_up
    else st=retrying; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$c" "$at" "$n" "$(date +%s)" "$st" >>"$RETRY"
    card="$c" log THREAD_RETRY "attempt $n of 3: $st"
    [ "$st" = gave_up ] && alert STL-ESC-221 card="$c" title="${title:0:80}"
  done <<<"$statuses"
  card=""
}

poll_pass() {  # poll_pass <pass number>
  local statuses author
  date +%s >"$SUP/state/reply-poll.heartbeat"   # liveness, also when nothing below works (watchdog.sh checks it)
  owner_id
  if ! statuses=$(kanban list --json 2>/dev/null | jq -r '.[] | "\(.id)\t\(.status)"'); then
    if [ "$1" = 1 ]; then   # F3: once per run, not per pass
      log POLL_FAIL "hermes kanban list failed: the board cannot be read; no replies or completions are processed"
      once_per_hour poll-list-fail && alert STL-ESC-211 error="hermes kanban list failed"
    fi
    return 0
  fi
  [ "$1" = 1 ] && retry_threads
  [ -s "$MAP" ] || return 0
  while IFS=$'\t' read -r -u 3 thread card _opened maptitle; do
    [ -n "$thread" ] && [[ "$card" =~ ^t_[0-9a-f]{8}$ ]] || continue
    thread_closed "$thread" && continue   # deleted or archived from the completion prompt (D33)
    status=$(awk -F'\t' -v c="$card" '$1 == c { print $2; exit }' <<<"$statuses")
    # Backstop for the kanban_task_completed hook (D30): report an escalated card's completion exactly once.
    if [ "$status" = done ]; then [ "$1" = 1 ] && /workspace/bin/escalation-complete.sh "$card" </dev/null; continue; fi
    [ "$status" = blocked ] || continue
    res=$(discord_action fetch_messages "$thread")
    err=$(jq -r '.error // empty' <<<"$res" 2>/dev/null)
    if [ -n "$err" ]; then
      log POLL_FAIL "thread=$thread error=${err:0:600}$(jq -r '.traceback // empty | if . == "" then "" else " traceback=" + . end' <<<"$res" 2>/dev/null)"
      [ -s "$SUP/state/poll-fail-$thread.count" ] || date -u +%FT%TZ >"$SUP/state/poll-fail-$thread.since"   # K10: when it began
      n=$(( $(cat "$SUP/state/poll-fail-$thread.count" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$SUP/state/poll-fail-$thread.count"
      if [ "$n" -ge 3 ] && once_per_hour "poll-fail-$thread"; then   # F6
        alert STL-ESC-210 card="$card" count="$n" thread="$thread" error="${err:0:600}" && touch "$SUP/state/poll-fail-$thread.alerted"
      fi
      continue
    fi
    if [ -e "$SUP/state/poll-fail-$thread.alerted" ]; then   # K10: the owner was told it broke, so tell them it works again
      alert STL-ESC-210 resolved=1 card="$card" thread="$thread" since="$(cat "$SUP/state/poll-fail-$thread.since" 2>/dev/null)"
    fi
    rm -f "$SUP/state/poll-fail-$thread.count" "$SUP/state/poll-fail-$thread.alerted" "$SUP/state/poll-fail-$thread.since"
    reply=""
    # Discord returns newest first; walk oldest first and take the first human message not seen yet.
    while IFS= read -r m; do
      id=$(jq -r '.id' <<<"$m")
      grep -q "^${id}"$'\t' "$SEEN" "$SKIP" 2>/dev/null && continue
      author=$(jq -r '.author.id // empty' <<<"$m")
      if [ -z "$OWNER" ] || [ "$author" != "$OWNER" ]; then ignore_reply "$id" "$author"; continue; fi
      reply=$m
      break
    done < <(jq -c '(.messages // []) | reverse | .[] | select((.author.bot // false) | not) | select((.content // "") != "")' <<<"$res")
    [ -n "$reply" ] || continue

    id=$(jq -r '.id' <<<"$reply")
    user=$(jq -r '.author.username // .author.id // "unknown"' <<<"$reply")
    text=$(jq -r '.content' <<<"$reply")
    show=$(kanban show "$card" --json 2>/dev/null)
    block=$(jq -c '[.events[]? | select(.kind == "blocked")] | last | .payload // {}' <<<"$show" 2>/dev/null)
    title="${maptitle:-$(jq -r '.task.title // empty' <<<"$show" 2>/dev/null)}"
    why=""
    if [ "$(answers "$card")" -ge 2 ]; then why=loop
    elif [ "$(jq -r '.kind // empty' <<<"$block" 2>/dev/null)" = capability ]; then why=capability
    elif grep -qE "$BARE_OPTION" <<<"$text" && ! has_options "$(jq -r '.reason // empty' <<<"$block" 2>/dev/null)"; then why=unmatched
    fi
    if [ -n "$why" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$card" "$thread" "$why" "$(date -u +%FT%TZ)" >>"$SKIP"
      case "$why" in
        loop)
          if log_has "$card" LOOP_HELD; then
            log REPLY_HELD "reply $id in thread $thread not applied: the card is held as a loop"
          else
            n=$(jq -r '[.events[]? | select(.kind == "blocked")] | length' <<<"$show" 2>/dev/null)
            log LOOP_HELD "reply $id in thread $thread not applied: block ${n:-?} after 2 recorded answers; card left blocked for triage"
            alert STL-ESC-230 card="$card" count="${n:-unknown}" title="$title" thread="$thread"
            kanban comment --author escalation-reply-poll.sh "$card" "Loop held: block ${n:-?} after two answered escalations. The reply in thread $thread was not applied and no reply unblocks this card automatically; held for triage." >/dev/null
          fi ;;
        capability)
          log REPLY_HELD "reply $id in thread $thread not applied: the card's block is kind capability (triage, not a decision)" ;;
        unmatched)
          log REPLY_UNMATCHED "reply $id (\"${text:0:40}\") in thread $thread names an option, but the block reason has none; not applied"
          react_add_retry "$thread" "$id" "❓" || true
          res=$(discord_action send_message "$thread" "Card ${card}: ${title}
This block offers no options, so \"${text}\" was not applied. Reply with your instruction in plain words.")
          [ -n "$(jq -r '.message_id // empty' <<<"$res" 2>/dev/null)" ] || log POST_FAIL "unmatched-reply note in thread $thread: $(jq -r '.error // empty' <<<"$res" 2>/dev/null | cut -c1-300)" ;;
      esac
      continue
    fi

    if kanban unblock --reason "escalation reply from discord:$user in thread $thread: $text" "$card" >/dev/null 2>&1; then
      # F2: seen and REPLY only once applied; a failed unblock leaves the reply unseen, so the next pass tries again.
      printf '%s\t%s\t%s\t%s\n' "$id" "$card" "$thread" "$(date -u +%FT%TZ)" >>"$SEEN"
      jq -nc --arg time "$(date -u +%FT%TZ)" --arg card "$card" --arg thread "$thread" --arg user "$user" --arg text "$text" \
        --arg mid "$id" '{time: $time, card: $card, event: "REPLY",
          detail: ("thread " + $thread + " from " + $user + " (poll, message " + $mid + ")"), reply: $text}' >>"$LOG"
      log UNBLOCKED "card unblocked from thread $thread reply $id"
      set_status_reaction "$card" recorded   # 👀 on the reply (D32)
    else
      log UNBLOCK_FAIL "hermes kanban unblock failed for thread $thread reply $id; not marked seen, tried again next pass"
      once_per_hour "unblock-fail-$id" && alert STL-ESC-212 card="$card" thread="$thread" message="$id" error="hermes kanban unblock failed"
    fi
  done 3<"$MAP"
  card=""
}

# Passes at 0, 12, 24, 36, 48 s; none starts after 50 s, so the next cron run finds the lock free.
t0=$SECONDS
for ((pass = 1; pass <= POLL_PASSES; pass++)); do
  wait=$(( t0 + (pass - 1) * POLL_EVERY - SECONDS ))
  [ "$wait" -le 0 ] || sleep "$wait"
  [ $(( SECONDS - t0 )) -le 50 ] || break
  poll_pass "$pass"
done

# Completion prompts (D37): 🔒 Archive (renamed "🔒 <original title>", then read-only) or 🗑️ Delete, from human reactions
# only (bots, Stella's own pre-added ones included, never count), and only the owner's: with no valid OWNER_DISCORD_USER_ID, nobody's (D39, D72). No reaction keeps the thread; 📌 on an older prompt does
# nothing. 🔒 + 🗑️ together is a conflict: one note, then nothing until one is removed. Archive and Delete are final.
# Older prompts are migrated once to the two-choice text: v2 (📌/🔒/🗑️) loses Stella's own 📌; legacy ✅/❌ (no
# version column) gets its reactions swapped. Old reactions never act.
if [ -s "$DEL" ]; then
  owner_id
  owner_reactors() { jq -r --arg o "$OWNER" '[.users[]? | select(.bot | not) | select($o != "" and .id == $o) | .username] | join(",")' 2>/dev/null; }
  humans() { discord_action reaction_users "$th" "$pm" "$1" | owner_reactors; }
  while IFS=$'\t' read -r -u 4 card th pm st ver first; do
    # F21: a prompt nobody answered in 7 days is no longer polled (two reaction reads a minute); the thread is kept.
    if [ $(( $(date +%s) - $(date -d "$first" +%s 2>/dev/null || date +%s) )) -gt 604800 ]; then
      printf '%s\t%s\t%s\texpired\t%s\tv3\n' "$card" "$th" "$pm" "$(date -u +%FT%TZ)" >>"$DEL"
      log PROMPT_EXPIRED "prompt $pm in thread $th unanswered since $first; no longer polled, thread kept"
      continue
    fi
    if [ "$ver" != v3 ]; then
      res=$(discord_action edit_message "$th" "$pm" "$PROMPT_TEXT"); err=$(jq -r '.error // empty' <<<"$res" 2>/dev/null)
      if [ -n "$err" ]; then
        if grep -q "10003\|10008\|Unknown Channel\|Unknown Message" <<<"$err"; then
          printf '%s\t%s\t%s\tdeleted\t%s\tv3\n' "$card" "$th" "$pm" "$(date -u +%FT%TZ)" >>"$DEL"; log THREAD_GONE "thread $th or its prompt no longer exists"
        else log PROMPT_FAIL "migrate prompt $pm in thread $th: ${err:0:300}"; fi
        continue
      fi
      if [ "$ver" = v2 ]; then
        discord_action react_remove "$th" "$pm" "$LEGACY_KEEP" >/dev/null
      else
        for e in "✅" "❌"; do discord_action react_remove "$th" "$pm" "$e" >/dev/null; done
        for e in "$CHOICE_ARCHIVE" "$CHOICE_DELETE"; do react_add_retry "$th" "$pm" "$e"; done
      fi
      [ "$st" = conflict ] || st=pending   # a v2 "kept" row has no meaning any more
      printf '%s\t%s\t%s\t%s\t%s\tv3\n' "$card" "$th" "$pm" "$st" "$(date -u +%FT%TZ)" >>"$DEL"
      log PROMPT_MIGRATED "prompt $pm in thread $th now offers $CHOICE_ARCHIVE archive, $CHOICE_DELETE delete"
      continue
    fi
    res=$(discord_action reaction_users "$th" "$pm" "$CHOICE_DELETE"); err=$(jq -r '.error // empty' <<<"$res" 2>/dev/null)
    if [ -n "$err" ]; then
      if grep -q "10003\|10008\|Unknown Channel\|Unknown Message" <<<"$err"; then   # thread or prompt deleted by hand
        printf '%s\t%s\t%s\tdeleted\t%s\tv3\n' "$card" "$th" "$pm" "$(date -u +%FT%TZ)" >>"$DEL"
        log THREAD_GONE "thread $th or its prompt no longer exists; stopped polling it"
      else
        log PROMPT_FAIL "thread $th prompt $pm: ${err:0:400}"
      fi
      continue
    fi
    del_by=$(owner_reactors <<<"$res")
    arch_by=$(humans "$CHOICE_ARCHIVE")
    if [ -n "$del_by" ] && [ -n "$arch_by" ]; then
      if [ "$st" != conflict ]; then
        discord_action send_message "$th" "Both $CHOICE_ARCHIVE Archive and $CHOICE_DELETE Delete are selected. Remove one and the other happens within a minute." >/dev/null
        printf '%s\t%s\t%s\tconflict\t%s\tv3\n' "$card" "$th" "$pm" "$(date -u +%FT%TZ)" >>"$DEL"
        log PROMPT_CONFLICT "thread $th: archive ($arch_by) and delete ($del_by) both selected; waiting for one to be removed"
      fi
      continue
    fi
    if [ -n "$del_by" ]; then
      res=$(discord_action delete_thread "$th" "$ESCALATIONS_CHANNEL_ID"); err=$(jq -r '.error // empty' <<<"$res" 2>/dev/null)
      if [ -z "$err" ]; then
        printf '%s\t%s\t%s\tdeleted\t%s\tv3\n' "$card" "$th" "$pm" "$(date -u +%FT%TZ)" >>"$DEL"
        log THREAD_DELETED "thread $th deleted after $CHOICE_DELETE from $del_by"
      else
        log THREAD_DELETE_FAIL "thread $th: ${err:0:400}"
      fi
      continue
    fi
    if [ -n "$arch_by" ]; then
      discord_action send_message "$th" "Archived by $arch_by: this thread is now read-only." >/dev/null
      # renamed to "🔒 <original title>" from the thread map; a pre-D29 row without a title is archived unrenamed
      title=$(awk -F'\t' -v t="$th" '$1 == t { r = $4 } END { print r }' "$MAP" 2>/dev/null)
      name=""; [ -z "$title" ] || name=$(lock_name "$title")
      res=$(discord_action archive_thread "$th" "$ESCALATIONS_CHANNEL_ID" "$name"); err=$(jq -r '.error // empty' <<<"$res" 2>/dev/null)
      if [ -z "$err" ]; then
        printf '%s\t%s\t%s\tarchived\t%s\tv3\n' "$card" "$th" "$pm" "$(date -u +%FT%TZ)" >>"$DEL"
        log THREAD_ARCHIVED "thread $th renamed \"${name:-unchanged}\", archived and locked (read-only) after $CHOICE_ARCHIVE from $arch_by"
      else
        log THREAD_ARCHIVE_FAIL "thread $th: ${err:0:400}"
      fi
      continue
    fi
  done 4< <(awk -F'\t' '{ if (!($1 in f)) f[$1] = $5; t[$1] = $2; m[$1] = $3; s[$1] = $4; v[$1] = $6 }
                  END { for (c in s) if (s[c] != "deleted" && s[c] != "archived" && s[c] != "expired")
                          print c "\t" t[c] "\t" m[c] "\t" s[c] "\t" v[c] "\t" f[c] }' "$DEL")
fi
