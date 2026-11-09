#!/usr/bin/env bash
# Hermetic self-test for bin/escalation-reply-poll.sh: stub hermes and a stub Discord helper, scratch state dir,
# no network. Checks: a human reply on a blocked card is logged as REPLY and unblocks it; the bot's own message and
# non-blocked cards are ignored; a later poll never records the same message again.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sup/state"
printf 'ALERT_TARGET="discord:#alerts"\n' > "$T/sup/limits.env"
{ cat /workspace/config/owner.example.env; printf "ESCALATIONS_CHANNEL_ID='1'\\n"; } > "$T/owner.env"; export OWNER_CONFIG="$T/owner.env"   # scratch owner config (D39)
printf '900\tt_aaaaaaaa\t2026\n901\tt_bbbbbbbb\t2026\n' > "$T/sup/state/escalation-threads.tsv"
# The done fixture cards' completion is already reported: the old fixture had no #supervisor id, so the completion
# backstop never finished for them; owner config now requires one (D39).
printf 't_%s\tlegacy\tnow\n' bbbbbbbb cccccccc dddddddd > "$T/sup/state/escalation-completed.tsv"
cat > "$T/bin/hermes" <<'S'
#!/usr/bin/env bash
# FAKE_BLOCKED: the blocked cards (default t_aaaaaaaa); every other mapped card is done. A blocked card's last block
# has kind FAKE_KIND and reason FAKE_REASON, and FAKE_NBLOCKS blocks in all.
# FAKE_EXTRA_BLOCKED: blocked cards with no thread (F1 retry); FAKE_LIST_FAIL / FAKE_UNBLOCK_FAIL: that call exits 1.
blocked=" ${FAKE_BLOCKED:-t_aaaaaaaa} ${FAKE_EXTRA_BLOCKED:-} "
[ "$1 $2" = "kanban --board" ] && set -- "$1" "${@:4}"   # scripts name the board (F4)
case "$1 $2" in
  "kanban list")    [ -z "${FAKE_LIST_FAIL:-}" ] || exit 1
                    { cut -f2 "$ESCALATE_SUP_DIR/state/escalation-threads.tsv" 2>/dev/null; printf '%s\n' ${FAKE_EXTRA_BLOCKED:-}; } | sort -u \
                      | jq -R --arg b "$blocked" '. as $id | {id: $id, status: (if ($b | contains(" " + $id + " ")) then "blocked" else "done" end)}' | jq -s .;;
  "kanban show")    if [[ " ${FAKE_SILENT:-} " == *" $3 "* ]]; then   # D46 item 9: the dispatcher gave up, no blocked event
                      jq -nc --argjson at "${FAKE_SILENT_AT:-0}" '{task: {status: "blocked", title: "Silent"}, events: [{kind: "created", created_at: ($at - 60)},
                        {kind: "spawn_failed", created_at: ($at - 30), run_id: 37, payload: {error: "workspace: not a git repo"}},
                        {kind: "gave_up", created_at: $at, run_id: 39, payload: {failures: 2, error: "workspace: not a git repo"}}]}'
                    elif [[ "$blocked" == *" $3 "* ]]; then
                      jq -nc --arg k "${FAKE_KIND:-needs_input}" --arg r "${FAKE_REASON:-Decision needed: Option A: blue, or Option B: green.}" \
                        --argjson n "${FAKE_NBLOCKS:-1}" '{task: {status: "blocked", title: "T16"}, events: [range($n) | {kind: "blocked", created_at: 0, payload: {kind: $k, reason: $r}}]}'
                    else echo '{"task":{"status":"done"}}'; fi;;
  "kanban unblock") echo "$*" >> "$ESCALATE_SUP_DIR/unblock_tries"; [ -z "${FAKE_UNBLOCK_FAIL:-}" ] || exit 1
                    echo "$*" >> "$ESCALATE_SUP_DIR/unblocked";;
  "kanban comment") echo "$*" >> "$ESCALATE_SUP_DIR/comments";;
  "send "*)         [ -n "${FAKE_THREAD_SEND_FAIL:-}" ] && [[ "$3" == discord:1:* ]] && exit 1
                    [ -n "${FAKE_ALERT_SEND_FAIL:-}" ] && [[ "$3" == discord:#alerts ]] && exit 1   # K10: an undelivered #alerts line
                    shift; printf '%s\n' "$*" >> "$ESCALATE_SUP_DIR/sends";;
esac
S
cat > "$T/bin/fakepy" <<'S'
#!/usr/bin/env bash
cat >/dev/null   # stub Discord helper; argv: -I - <action> <channel> [...]
uid() { [ "$1" = owner ] && echo 100000000000000001 || echo 200000000000000002; }   # FAKE_* reactors by name: owner, or anyone else
echo "$*" >> "$ESCALATE_SUP_DIR/discord_calls"
[ "$3" = react_add ] && echo "$(date +%s.%N) $5 $6 $(grep -cE 'fetch_messages 995( |$)' "$ESCALATE_SUP_DIR/discord_calls")" >> "$ESCALATE_SUP_DIR/reacts_at"   # 4th field: fetches of thread 995 so far (the F5 pass count)
case "$3" in
  create_thread) n=$(( $(cat "$ESCALATE_SUP_DIR/create_n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$ESCALATE_SUP_DIR/create_n"
                 if [ "$n" -le "${FAKE_CREATE_FAILS:-0}" ]; then echo '{"error": "Discord API error 503: Service Unavailable"}'
                 else echo "{\"success\": true, \"thread_id\": \"$((5000 + n))\"}"; fi;;
  fetch_messages) [ "$4" != "${FAKE_FETCH_FAIL:-}" ] || { echo '{"error": "Discord API error 403: Missing Access"}'; exit 0; }
                  [ "$4" = 900 ] || { cat "$ESCALATE_SUP_DIR/msgs_$4" 2>/dev/null || echo '{"messages":[]}'; exit 0; }
                  echo '{"messages":[{"id":"3","content":"thanks","author":{"id":"100000000000000001","username":"owner","bot":false}},{"id":"2","content":"Option A","author":{"id":"100000000000000001","username":"owner","bot":false}},{"id":"1","content":"Escalation for card t_aaaaaaaa","author":{"username":"Stella","bot":true}}]}';;
  reaction_users) case "$6" in            # human reactors per emoji come from FAKE_<choice>; Stella (bot) always there
                    "✅") u="${FAKE_OLD_YES:-}";; "📌") u="${FAKE_KEEP:-}";; "🔒") u="${FAKE_ARCH:-}";; "🗑️") u="${FAKE_DEL:-}";; *) u="";;
                  esac
                  echo "{\"users\":[{\"username\":\"Stella\",\"bot\":true}${u:+,{\"id\":\"$(uid "$u")\",\"username\":\"$u\",\"bot\":false\}}]}";;
  send_message) echo '{"success": true, "message_id": "777"}';;
  *) echo '{"success": true}';;
esac
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" ESCALATE_SUP_DIR="$T/sup" HERMES_PY="$T/bin/fakepy" TZ=America/Toronto   # alert times in a fixed zone (as watchdog-selftest)
export POLL_PASSES=1   # one pass per run, except in the F5 latency test
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
replies() { jq -r 'select(.event=="REPLY") | .reply' "$T/sup/escalations.log" | tr '\n' ,; }

/workspace/bin/escalation-reply-poll.sh
ok '[ "$(replies)" = "Option A," ]' "oldest human reply recorded as REPLY (bot message skipped)"
ok '[ "$(wc -l < "$T/sup/unblocked")" = 1 ] && grep -q t_aaaaaaaa "$T/sup/unblocked"' "blocked card unblocked with the reply"
ok '! grep -q t_bbbbbbbb "$T/sup/escalations.log"' "non-blocked card ignored"
/workspace/bin/escalation-reply-poll.sh
ok '[ "$(replies)" = "Option A,thanks," ]' "a later poll takes the next unseen message, never message 2 again"
ok 'grep -q "react_add 900 2 👀" "$T/sup/discord_calls" && [ "$(cut -f3 "$T/sup/state/escalation-reactions.tsv" | tail -1)" = "👀" ]' "👀 on the recorded reply"

# Reactions are single and never go backwards: ✨ replaces 👀, 🌟 replaces ✨, a late ✨ after 🌟 is ignored.
( card=""; . /workspace/bin/escalation-discord.sh; set_status_reaction t_aaaaaaaa working; set_status_reaction t_aaaaaaaa completed; set_status_reaction t_aaaaaaaa working )
ok 'grep -q "react_remove 900 2 👀" "$T/sup/discord_calls"' "a newer recorded reply takes over: 👀 removed from the older reply"
ok 'grep -q "react_remove 900 3 👀" "$T/sup/discord_calls" && grep -q "react_remove 900 3 ✨" "$T/sup/discord_calls" && [ "$(grep -c "react_add 900 3 ✨" "$T/sup/discord_calls")" = 1 ] && [ "$(cut -f3 "$T/sup/state/escalation-reactions.tsv" | tail -1)" = "🌟" ]' "one reaction at a time: 👀 → ✨ → 🌟, late ✨ ignored"

# Completion prompts (D37): only 🔒 Archive and 🗑️ Delete; no reaction keeps the thread. Rows: a legacy ✅/❌ prompt
# (no version) and a v2 📌/🔒/🗑️ prompt, both migrated once; then a v3 prompt.
calls() { grep -c -- "$1" "$T/sup/discord_calls" 2>/dev/null || true; }
ev() { jq -r --arg e "$1" 'select(.event == $e) | .card' "$T/sup/escalations.log" | wc -l; }
printf '950\tt_cccccccc\t2026\tT16 escalation test: pick a colour\n' >> "$T/sup/state/escalation-threads.tsv"
printf '960\tt_dddddddd\t2026\t%s\n' "$(printf 'x%.0s' $(seq 1 120))" >> "$T/sup/state/escalation-threads.tsv"
printf 't_cccccccc\t950\t951\tpending\tnow\n' > "$T/sup/state/escalation-delete.tsv"
printf 't_dddddddd\t960\t961\tkept\tnow\tv2\n' >> "$T/sup/state/escalation-delete.tsv"
FAKE_OLD_YES=owner FAKE_KEEP=owner /workspace/bin/escalation-reply-poll.sh
ok 'grep -q "edit_message 950 951 What should happen to this thread? React 🔒 Archive" "$T/sup/discord_calls" && grep -q "react_remove 950 951 ✅" "$T/sup/discord_calls" && grep -q "react_add 950 951 🔒" "$T/sup/discord_calls" && grep -q "react_add 950 951 🗑️" "$T/sup/discord_calls" && [ "$(calls "react_add 950 951 📌")" = 0 ]' "legacy ✅/❌ prompt migrated to the two-choice prompt"
ok 'grep -q "edit_message 960 961 What should happen to this thread? React 🔒 Archive" "$T/sup/discord_calls" && grep -q "react_remove 960 961 📌" "$T/sup/discord_calls" && [ "$(calls "react_add 960")" = 0 ] && [ "$(ev PROMPT_MIGRATED)" = 2 ]' "v2 prompt: text migrated, Stella's own 📌 removed, no other reaction swap"
ok '! grep -q "📌" <<<"$(grep "edit_message" "$T/sup/discord_calls")"' "the new prompt text offers no 📌 Keep"
ok '[ "$(calls delete_thread)" = 0 ] && [ "$(calls archive_thread)" = 0 ]' "an old ✅ never deletes, 📌 does nothing"
FAKE_KEEP=owner /workspace/bin/escalation-reply-poll.sh
ok '[ "$(ev PROMPT_MIGRATED)" = 2 ] && [ "$(ev THREAD_KEPT)" = 0 ] && [ "$(calls delete_thread)" = 0 ] && [ "$(calls archive_thread)" = 0 ]' "📌 is ignored: no action, no log, migrated only once"
FAKE_ARCH=owner FAKE_DEL=owner /workspace/bin/escalation-reply-poll.sh; FAKE_ARCH=owner FAKE_DEL=owner /workspace/bin/escalation-reply-poll.sh
ok '[ "$(ev PROMPT_CONFLICT)" = 2 ] && [ "$(calls "send_message 960 Both")" = 1 ] && [ "$(calls delete_thread)" = 0 ] && [ "$(calls archive_thread)" = 0 ]' "🔒 + 🗑️ together: one note per prompt, no action"
FAKE_KEEP=owner FAKE_ARCH=owner /workspace/bin/escalation-reply-poll.sh
ok '[ "$(calls "archive_thread 950 1 🔒 T16 escalation test: pick a colour")" = 1 ] && [ "$(calls "send_message 950 Archived by owner")" = 1 ] && [ "$(ev THREAD_ARCHIVED)" = 2 ]' "🗑️ removed: 🔒 archives and renames to 🔒 <original title>"
long=$(grep "archive_thread 960 1 " "$T/sup/discord_calls" | sed 's/.*archive_thread 960 1 //')
ok '[ "$long" = "🔒 $(printf "x%.0s" $(seq 1 97))" ]' "archived name cut to Discord's 100-character limit (🔒 counts as 2)"
n=$(calls "reaction_users 9[56]0"); FAKE_DEL=owner /workspace/bin/escalation-reply-poll.sh
ok '[ "$(calls "reaction_users 9[56]0")" = "$n" ] && [ "$(calls delete_thread)" = 0 ]' "archived threads are final: never polled or deleted afterwards"
printf 't_eeeeeeee\t970\t971\tpending\tnow\tv3\n' >> "$T/sup/state/escalation-delete.tsv"
FAKE_KEEP=owner FAKE_DEL=owner /workspace/bin/escalation-reply-poll.sh
ok '[ "$(calls "delete_thread 970 1")" = 1 ] && [ "$(ev THREAD_DELETED)" = 1 ] && [ "$(calls "edit_message 970")" = 0 ]' "🗑️ deletes a v3 prompt's thread, no migration"
n=$(calls "reaction_users 970"); FAKE_DEL=owner /workspace/bin/escalation-reply-poll.sh
ok '[ "$(calls "reaction_users 970")" = "$n" ]' "deleted threads are never polled again"
P=${POLL:-/workspace/bin/escalation-reply-poll.sh}   # POLL=<copy>: a staged copy while it is being replaced
nunb() { wc -l < "$T/sup/unblocked"; }
msg() { jq -nc --arg i "$1" --arg c "$2" --arg a "${3:-100000000000000001}" '{id: $i, content: $c, author: {id: $a, username: (if $a == "100000000000000001" then "owner" else "intruder" end), bot: false}}'; }   # msg <id> <text> [author id]
# F2d (t_fbfdaf63): a bare "A" on a block whose reason has no options is not applied: REPLY_UNMATCHED, ❓ on the reply,
# the card stays blocked, one line in the thread. A later reply in plain words is applied as usual.
NOOPT="Task body specifies \"Do not do the work yourself\" but I created phase4-test.md via heredoc terminal command."
printf '980\tt_ffffffff\t2026\tCreate phase4-test.md\n' >> "$T/sup/state/escalation-threads.tsv"
jq -nc --argjson a "$(msg 50 A)" '{messages: [$a]}' > "$T/sup/msgs_980"
u=$(nunb)
FAKE_BLOCKED=t_ffffffff FAKE_REASON="$NOOPT" $P; FAKE_BLOCKED=t_ffffffff FAKE_REASON="$NOOPT" $P
ok '[ "$(nunb)" = "$u" ] && [ "$(ev REPLY_UNMATCHED)" = 1 ] && [ "$(calls "react_add 980 50 ❓")" = 1 ]' "bare A on a reason without options: REPLY_UNMATCHED once, ❓, card left blocked"
ok '[ "$(calls "send_message 980 Card t_ffffffff: Create phase4-test.md")" = 1 ] && grep -q "Reply with your instruction in plain words" "$T/sup/discord_calls"' "one line in the thread asking for an instruction"
ok '! grep -q "^50"$'"'"'\t'"'"' "$T/sup/state/escalation-replies.tsv"' "the unmatched reply is not recorded as an answer"
jq -nc --argjson a "$(msg 51 "Delete the file with git rm and run OpenCode again")" --argjson b "$(msg 50 A)" '{messages: [$a, $b]}' > "$T/sup/msgs_980"
FAKE_BLOCKED=t_ffffffff FAKE_REASON="$NOOPT" $P
ok '[ "$(nunb)" = $((u + 1)) ] && tail -1 "$T/sup/unblocked" | grep -q "t_ffffffff" && tail -1 "$T/sup/unblocked" | grep -q "git rm"' "a plain-words instruction is applied"

# F2a at the poller: a card answered twice that is blocked again is never unblocked by a reply: LOOP_HELD once, one
# #alerts line, one card comment; a second reply only logs REPLY_HELD.
printf '990\tt_99999999\t2026\tT16 retest\n' >> "$T/sup/state/escalation-threads.tsv"
printf '61\tt_99999999\t990\tnow\n62\tt_99999999\t990\tnow\n' >> "$T/sup/state/escalation-replies.tsv"
jq -nc --argjson a "$(msg 63 A)" '{messages: [$a]}' > "$T/sup/msgs_990"
u=$(nunb)
FAKE_BLOCKED=t_99999999 FAKE_NBLOCKS=3 $P
jq -nc --argjson a "$(msg 64 "A again")" --argjson b "$(msg 63 A)" '{messages: [$a, $b]}' > "$T/sup/msgs_990"
FAKE_BLOCKED=t_99999999 FAKE_NBLOCKS=3 $P
ok '[ "$(nunb)" = "$u" ] && [ "$(ev LOOP_HELD)" = 1 ] && [ "$(ev REPLY_HELD)" = 1 ]' "third block of a twice-answered card: no unblock, LOOP_HELD once"
ok '[ "$(grep -c "^--to discord:#alerts --quiet .*\[STL-ESC-230\]\*\*$" "$T/sup/sends")" = 1 ] && grep -q "^Card t_99999999 (\"T16 retest\") was blocked again after you already answered twice (3 blocks so far)" "$T/sup/sends" && [ "$(grep -c "t_99999999 Loop held" "$T/sup/comments")" = 1 ]' "one #alerts line and one card comment"

# F2b: a reply in an older thread of a card whose current block is kind capability is not applied.
printf '991\tt_88888888\t2026\tCapability card\n' >> "$T/sup/state/escalation-threads.tsv"
jq -nc --argjson a "$(msg 70 "try again")" '{messages: [$a]}' > "$T/sup/msgs_991"
u=$(nunb)
FAKE_BLOCKED=t_88888888 FAKE_KIND=capability $P
ok '[ "$(nunb)" = "$u" ] && [ "$(ev REPLY_HELD)" = 2 ]' "capability block: a thread reply is held for triage, not applied"

# F5: several passes per cron run under the one lock, so a reply posted between passes is seen on the next pass, not a
# minute later. Counted in passes, not seconds (a busy machine stretches seconds, never the order of passes): the reply is
# posted once pass 1 has fetched the thread, k = fetches counted after it was posted; 👀 must land on fetch k+1 at the latest.
printf '995\tt_77777777\t2026\tLatency\n' >> "$T/sup/state/escalation-threads.tsv"
fetched() { grep -cE 'fetch_messages 995( |$)' "$T/sup/discord_calls" 2>/dev/null || true; }
( until [ "$(fetched)" -ge 1 ]; do sleep 0.05; done
  jq -nc --argjson a "$(msg 80 "Option B")" '{messages: [$a]}' > "$T/sup/msgs_995"; fetched > "$T/sup/replied_after" ) &
t0=$SECONDS
FAKE_BLOCKED=t_77777777 POLL_PASSES=4 POLL_EVERY=1 $P
wait
seen=$(awk '$2 == 80 { print $4 }' "$T/sup/reacts_at")
ok '[ -n "$seen" ] && [ "$seen" -le $(( $(cat "$T/sup/replied_after") + 1 )) ]' "reply between passes gets 👀 on the next pass (posted after fetch $(cat "$T/sup/replied_after"), 👀 on fetch ${seen:-none})"
ok '[ $((SECONDS - t0)) -le 6 ]' "four 1 s passes finish within the run budget"

# D39 authorization: only OWNER_DISCORD_USER_ID's replies and reactions are applied; config re-read on every pass.
setid() { printf "OWNER_DISCORD_USER_ID='%s'\n" "$1" >> "$T/owner.env"; }   # the last key wins
alerts() { grep -c -- "$1" "$T/sup/sends" 2>/dev/null || true; }
abody() { awk '/^--to /{ a = ($0 ~ /^--to discord:#alerts /) } a' "$T/sup/sends" | grep -c -- "$1" || true; }   # lines of #alerts messages only (D44: multi-line)
X=200000000000000002   # someone else
newcard() { printf '%s\t%s\t2026\t%s\n' "$1" "$2" "$3" >> "$T/sup/state/escalation-threads.tsv"; printf '%s\tlegacy\tnow\n' "$2" >> "$T/sup/state/escalation-completed.tsv"; }
newcard 1001 t_66666666 "Auth card"
jq -nc --argjson a "$(msg 101 "Option A" $X)" '{messages: [$a]}' > "$T/sup/msgs_1001"
u=$(nunb)
FAKE_BLOCKED=t_66666666 $P; FAKE_BLOCKED=t_66666666 $P
ok '[ "$(nunb)" = "$u" ] && [ "$(ev REPLY_IGNORED_NOT_OWNER)" = 1 ]' "a non-owner reply is not applied, and logged once, not once per poll"
ok '[ "$(alerts "^--to discord:#alerts --quiet .*\[STL-ESC-240\]\*\*$")" = 1 ] && [ "$(abody "replied in the escalation thread for card t_66666666")" = 1 ] && [ "$(abody "$X")" = 0 ] && grep -q "^STL-ESC-240 .*author=.$X" "$T/sup/logs/alerts.log"' "one #alerts line naming the card (D44: the author id and the fix steps only in alerts.log and docs/alert-codes.md)"
ok '! grep -q "^101"$'"'"'\t'"'"' "$T/sup/state/escalation-replies.tsv" "$T/sup/state/escalation-skipped.tsv"' "the ignored reply is not marked seen"
jq -nc --argjson b "$(msg 102 "Option B" $X)" --argjson a "$(msg 101 "Option A" $X)" '{messages: [$b, $a]}' > "$T/sup/msgs_1001"
FAKE_BLOCKED=t_66666666 $P
ok '[ "$(ev REPLY_IGNORED_NOT_OWNER)" = 2 ] && [ "$(alerts "\[STL-ESC-240\]")" = 1 ]' "a second non-owner reply is logged, but no second #alerts line within the hour"
setid $X   # the "non-owner" was the owner after all: the id is corrected
FAKE_BLOCKED=t_66666666 $P
ok '[ "$(nunb)" = $((u + 1)) ] && tail -1 "$T/sup/unblocked" | grep -q "t_66666666" && tail -1 "$T/sup/unblocked" | grep -q "Option A" && grep -q "^101"$'"'"'\t'"'"' "$T/sup/state/escalation-replies.tsv"' "after the id is corrected, the same reply is applied on the next poll, no restart"
setid 12345
newcard 1002 t_44444444 "Malformed id card"
jq -nc --argjson a "$(msg 111 "Option A" 300000000000000003)" '{messages: [$a]}' > "$T/sup/msgs_1002"
u=$(nunb)
FAKE_BLOCKED=t_44444444 $P; FAKE_BLOCKED=t_44444444 $P
ok '[ "$(nunb)" = "$u" ] && [ "$(ev OWNER_ID_INVALID)" = 1 ] && [ "$(alerts "\[STL-CFG-302\]\*\*$")" = 1 ] && ! grep -q "^111"$'"'"'\t'"'"' "$T/sup/state/escalation-replies.tsv"' "a malformed id fails closed (D72): the reply is not applied and not marked seen; OWNER_ID_INVALID logged and alerted once"
setid 300000000000000003   # the id is corrected to the real owner's
FAKE_BLOCKED=t_44444444 $P
ok '[ "$(nunb)" = $((u + 1)) ]' "control: after a malformed id is corrected, the reply held back is applied on the next poll, nothing lost"
setid 100000000000000001
printf 't_55555555\t1010\t1011\tpending\tnow\tv3\n' >> "$T/sup/state/escalation-delete.tsv"
FAKE_DEL=intruder $P; FAKE_ARCH=intruder $P
ok '[ "$(calls "delete_thread 1010")" = 0 ] && [ "$(calls "archive_thread 1010")" = 0 ]' "a non-owner 🗑️ or 🔒 does nothing"
FAKE_DEL=owner $P
ok '[ "$(calls "delete_thread 1010 1")" = 1 ]' "the owner's 🗑️ deletes the thread"
printf 't_22222222\t1020\t1021\tpending\tnow\tv3\n' >> "$T/sup/state/escalation-delete.tsv"
FAKE_ARCH=owner $P
ok '[ "$(calls "archive_thread 1020 1")" = 1 ] && [ "$(calls "send_message 1020 Archived by owner")" = 1 ]' "the owner's 🔒 archives the thread"
setid ""
newcard 1003 t_33333333 "Empty id card"
jq -nc --argjson a "$(msg 121 "Option A" $X)" '{messages: [$a]}' > "$T/sup/msgs_1003"
printf 't_11111111\t1030\t1031\tpending\tnow\tv3\n' >> "$T/sup/state/escalation-delete.tsv"
u=$(nunb)
FAKE_BLOCKED=t_33333333 FAKE_DEL=intruder $P
ok '[ "$(nunb)" = "$u" ] && [ "$(calls "delete_thread 1030 1")" = 0 ] && [ "$(ev OWNER_ID_EMPTY)" = 1 ] && [ "$(alerts "\[STL-CFG-302\]\*\*$")" = 2 ] && ! grep -q "^121"$'"'"'\t'"'"' "$T/sup/state/escalation-replies.tsv"' "an empty id fails closed (D72): no reply or reaction counts, nothing marked seen; OWNER_ID_EMPTY logged, STL-CFG-302 alerted"
FAKE_DEL=owner $P
ok '[ "$(calls "delete_thread 1030 1")" = 0 ]' "an empty id: a reaction from anyone, the usual owner's account included, does nothing"
setid 100000000000000001
FAKE_DEL=owner $P
ok '[ "$(calls "delete_thread 1030 1")" = 1 ]' "control: once the id is set, the owner's 🗑️ on the same prompt acts"

# F2: a reply is marked seen only after its unblock worked. A failed unblock keeps it unapplied: retried on the next
# pass, one #alerts line.
setid 100000000000000001
newcard 1100 t_aa000001 "Unblock fail card"
jq -nc --argjson a "$(msg 201 "Option A")" '{messages: [$a]}' > "$T/sup/msgs_1100"
u=$(nunb)
FAKE_BLOCKED=t_aa000001 FAKE_UNBLOCK_FAIL=1 $P; FAKE_BLOCKED=t_aa000001 FAKE_UNBLOCK_FAIL=1 $P
ok '[ "$(nunb)" = "$u" ] && ! grep -q "^201"$'"'"'\t'"'"' "$T/sup/state/escalation-replies.tsv" && [ "$(grep -c t_aa000001 "$T/sup/unblock_tries")" = 2 ]' "F2: unblock failed twice: the reply is not marked seen, and was tried again"
ok '[ "$(alerts "\[STL-ESC-212\]\*\*$")" = 1 ] && [ "$(abody "Your reply for card t_aa000001 was seen")" = 1 ] && [ "$(jq -r "select(.card == \"t_aa000001\" and .event == \"UNBLOCK_FAIL\") | .card" "$T/sup/escalations.log" | wc -l)" = 2 ]' "F2: UNBLOCK_FAIL logged each time, one #alerts line"
FAKE_BLOCKED=t_aa000001 $P
ok '[ "$(nunb)" = $((u + 1)) ] && grep -q "^201"$'"'"'\t'"'"' "$T/sup/state/escalation-replies.tsv" && [ "$(jq -r "select(.card == \"t_aa000001\" and .event == \"REPLY\") | .card" "$T/sup/escalations.log" | wc -l)" = 1 ]' "F2: the next pass applies it: unblocked, seen, one REPLY line"

# F3 + poller liveness: an unreadable board is POLL_FAIL and at most one #alerts line an hour; every pass writes the
# heartbeat, also when the board cannot be read or no thread is mapped.
rm -f "$T/sup/state/reply-poll.heartbeat"
FAKE_LIST_FAIL=1 $P; FAKE_LIST_FAIL=1 $P
ok '[ "$(jq -r "select(.event == \"POLL_FAIL\") | .detail" "$T/sup/escalations.log" | grep -c "kanban list")" = 2 ] && [ "$(alerts "\[STL-ESC-211\]\*\*$")" = 1 ]' "F3: kanban list fails: POLL_FAIL each run, one #alerts line"
ok '[ $(( $(date +%s) - $(cat "$T/sup/state/reply-poll.heartbeat") )) -le 5 ]' "liveness: heartbeat written by a pass whose board read failed"
mkdir -p "$T/sup2/state"; cp "$T/sup/limits.env" "$T/sup2/"
ESCALATE_SUP_DIR="$T/sup2" $P
ok '[ -s "$T/sup2/state/reply-poll.heartbeat" ]' "liveness: heartbeat written with no thread mapped at all"

# F6: three consecutive failed reads of one thread raise one #alerts line (at most one an hour); POLL_FAIL each time.
newcard 1200 t_aa000002 "Fetch fail card"
for _ in 1 2 3 4; do FAKE_BLOCKED=t_aa000002 FAKE_FETCH_FAIL=1200 $P; done
ok '[ "$(alerts "\[STL-ESC-210\]\*\*$")" = 1 ] && [ "$(abody "could not read the thread for card")" = 1 ] && [ "$(abody 1200)" = 0 ] && grep -q "^STL-ESC-210 .*thread=.1200" "$T/sup/logs/alerts.log" && [ "$(jq -r "select(.event == \"POLL_FAIL\") | .detail" "$T/sup/escalations.log" | grep -c "thread=1200")" = 4 ]' "F6: 4 failed reads: 4 POLL_FAIL, one #alerts line"
# K10: the owner was told a thread could not be read; the first good read of it says it works again, once.
pf() { echo "$T/sup/state/poll-fail-$1"; }   # state file prefix of one thread: .count .since .alerted
res() { alerts "\[STL-ESC-210 resolved\]\*\*$"; }
na() { alerts "^--to discord:#alerts"; }   # messages to #alerts (a first pass on a blocked card also posts in its thread)
rmsg() { awk '/^--to /{ p = 0 } /\[STL-ESC-210 resolved\]/{ p = 1 } p' "$T/sup/sends"; }
ok '[ "$(cat "$(pf 1200).count")" = 4 ] && [ -e "$(pf 1200).alerted" ] && grep -qE "^20[0-9-]+T[0-9:]+Z$" "$(pf 1200).since" && [ "$(res)" = 0 ]' "K10: after the alert: the streak start, the alerted mark and the count are recorded, nothing resolved yet"
printf '2026-10-28T13:00:00Z\n' > "$(pf 1200).since"; FAKE_BLOCKED=t_aa000002 FAKE_FETCH_FAIL=1200 $P
ok 'grep -qx 2026-10-28T13:00:00Z "$(pf 1200).since" && [ "$(res)" = 0 ] && [ "$(alerts "\[STL-ESC-210\]\*\*$")" = 1 ]' "K10: a further failed read keeps the recorded start and sends nothing (the start is the first failure)"
FAKE_BLOCKED=t_aa000002 $P
ok '[ "$(res)" = 1 ] && [ "$(rmsg | grep -c "can read the thread for card t_aa000002 again")" = 1 ] && grep "^STL-ESC-210 " "$T/sup/logs/alerts.log" | grep -E "resolved=.?1" | grep -qE "since=.?2026-10-28T13:00:00Z"' "K10: the first good read sends one resolved STL-ESC-210 naming the card, since = the recorded first failure"
ok '! rmsg | grep -qE "[{}]|unknown|1200|exit [0-9]|urlopen|Traceback|\.sh\b|[Hh]ermes|[0-9]{15,}|poller|flock|hook" && rmsg | grep -qE "from [0-9]{2}:[0-9]{2} to [0-9]{2}:[0-9]{2}"' "K10: the resolved text has no leftover placeholder, no thread id, no forbidden term, and a from/to time"
ok '[ ! -e "$(pf 1200).count" ] && [ ! -e "$(pf 1200).alerted" ] && [ ! -e "$(pf 1200).since" ]' "K10: the good read removes .count, .alerted and .since"
FAKE_BLOCKED=t_aa000002 $P; FAKE_BLOCKED=t_aa000002 $P
ok '[ "$(res)" = 1 ] && [ "$(alerts "\[STL-ESC-210\]\*\*$")" = 1 ]' "K10: further good reads send nothing more (resolved is sent once)"
# Two failed reads (below the alert threshold of 3), then a good one: the owner was never told, so nothing is sent.
newcard 1201 t_aa0000a1 "Short blip card"
FAKE_BLOCKED=t_aa0000a1 FAKE_FETCH_FAIL=1201 $P; FAKE_BLOCKED=t_aa0000a1 FAKE_FETCH_FAIL=1201 $P
ok '[ -s "$(pf 1201).since" ] && [ ! -e "$(pf 1201).alerted" ]' "K10: the first failed read records the start even before any alert"
r0=$(na); FAKE_BLOCKED=t_aa0000a1 $P
ok '[ "$(res)" = 1 ] && [ "$(na)" = "$r0" ] && [ ! -e "$(pf 1201).since" ] && [ ! -e "$(pf 1201).count" ]' "K10: a good read after a short blip with no alert sends nothing, and clears the recorded start"
# A thread that never failed.
newcard 1202 t_aa0000a2 "Never failed card"
r0=$(na); FAKE_BLOCKED=t_aa0000a2 $P
ok '[ "$(res)" = 1 ] && [ "$(na)" = "$r0" ] && [ -z "$(ls "$T"/sup/state/poll-fail-1202* 2>/dev/null)" ]' "K10: a good read of a thread that never failed sends nothing and leaves no state"
# The alert itself was not delivered: the owner was never told, so no recovery line either.
newcard 1203 t_aa0000a3 "Undelivered alert card"
for _ in 1 2 3 4; do FAKE_ALERT_SEND_FAIL=1 FAKE_BLOCKED=t_aa0000a3 FAKE_FETCH_FAIL=1203 $P; done
ok '[ "$(cat "$(pf 1203).count")" = 4 ] && [ ! -e "$(pf 1203).alerted" ] && [ "$(alerts "\[STL-ESC-210\]\*\*$")" = 1 ]' "K10: an alert whose send failed is not marked alerted"
FAKE_BLOCKED=t_aa0000a3 $P
ok '[ "$(res)" = 1 ] && [ ! -e "$(pf 1203).count" ] && [ ! -e "$(pf 1203).since" ]' "K10: so the good read after it sends no recovery line"
# A second outage on the same thread: alerted and resolved again (threads are reused, state does not stick).
newcard 1204 t_aa0000a4 "Two outages card"; r0=$(res); a0=$(alerts "\[STL-ESC-210\]\*\*$")
for _ in 1 2; do
  rm -f "$T/sup/state/alert-poll-fail-1204.stamp"   # the once-an-hour limit would hide a second outage inside the hour
  for _ in 1 2 3; do FAKE_BLOCKED=t_aa0000a4 FAKE_FETCH_FAIL=1204 $P; done
  FAKE_BLOCKED=t_aa0000a4 $P
done
ok '[ "$(res)" = $((r0 + 2)) ] && [ "$(alerts "\[STL-ESC-210\]\*\*$")" = $((a0 + 2)) ] && [ "$(rmsg | grep -c "card t_aa0000a4")" = 2 ]' "K10: two separate outages of one thread: each is alerted and resolved once"
FAKE_BLOCKED=t_aa000002 $P; FAKE_BLOCKED=t_aa000002 FAKE_FETCH_FAIL=1200 $P
ok '[ ! -s "$T/sup/state/poll-fail-1200.count" ] || [ "$(cat "$T/sup/state/poll-fail-1200.count")" = 1 ]' "F6: a good read resets the streak"

# F1 retry: a blocked needs_input card with no thread gets escalation-thread.sh again on the first pass of a run, at most
# 3 attempts (backoff 1, 5, 15 min; 0 here), under the thread script's per-card lock.
export RETRY_BACKOFF="0 0 0"
rm -f "$T/sup/create_n"
for _ in 1 2 3 4; do FAKE_EXTRA_BLOCKED=t_aa000003 FAKE_BLOCKED=t_aa000003 FAKE_CREATE_FAILS=2 POLL_PASSES=2 POLL_EVERY=0 $P; done
ok '[ "$(cat "$T/sup/create_n")" = 3 ] && [ "$(awk -F"\t" "\$2 == \"t_aa000003\"" "$T/sup/state/escalation-threads.tsv" | wc -l)" = 1 ]' "F1 retry: create fails twice then works: three attempts, exactly one thread"
ok '[ "$(alerts "\[STL-ESC-221\]")" = 0 ] && [ "$(abody t_aa000003)" = 0 ]' "F1 retry: a retry that ends in a thread raises no alert"
rm -f "$T/sup/create_n"
for _ in 1 2 3 4 5; do FAKE_EXTRA_BLOCKED=t_aa000004 FAKE_BLOCKED=t_aa000004 FAKE_CREATE_FAILS=99 $P; done
ok '[ "$(cat "$T/sup/create_n")" = 3 ] && [ "$(abody "^Card t_aa000004 ")" = 1 ] && [ "$(alerts "\[STL-ESC-221\]\*\*$")" = 1 ] && [ "$(abody "could not post it in #escalations after 3 tries")" = 1 ]' "F1 retry: fails 3 times: one #alerts line, no fourth attempt"
rm -f "$T/sup/create_n"
FAKE_EXTRA_BLOCKED=t_aa000005 FAKE_BLOCKED=t_aa000005 FAKE_CREATE_FAILS=99 RETRY_BACKOFF="0 600 600" $P; FAKE_EXTRA_BLOCKED=t_aa000005 FAKE_BLOCKED=t_aa000005 FAKE_CREATE_FAILS=99 RETRY_BACKOFF="0 600 600" $P
ok '[ "$(cat "$T/sup/create_n")" = 1 ]' "F1 retry: the backoff is respected (second attempt not due yet)"
rm -f "$T/sup/create_n"
FAKE_EXTRA_BLOCKED=t_aa000006 FAKE_BLOCKED=t_aa000006 FAKE_KIND=capability $P
ok '[ ! -s "$T/sup/create_n" ]' "F1 retry: a capability block is never retried into a thread"
# Review H1: the thread was created but its first message failed, so the map has it and nothing was posted. The retry
# posts the question in that same thread, then THREAD_OPENED and the #supervisor link, once.
rm -f "$T/sup/create_n"
FAKE_EXTRA_BLOCKED=t_aa000007 FAKE_BLOCKED=t_aa000007 FAKE_THREAD_SEND_FAIL=1 $P
th7=$(awk -F'\t' '$2 == "t_aa000007" { print $1 }' "$T/sup/state/escalation-threads.tsv")
ok '[ -n "$th7" ] && ! grep -q "^t_aa000007" "$T/sup/state/escalation-posted.tsv"' "H1 setup: thread created, its first message failed"
FAKE_EXTRA_BLOCKED=t_aa000007 FAKE_BLOCKED=t_aa000007 $P; FAKE_EXTRA_BLOCKED=t_aa000007 FAKE_BLOCKED=t_aa000007 $P
ok '[ "$(cat "$T/sup/create_n")" = 1 ] && [ "$(grep -c "^--to discord:1:$th7 --quiet Card t_aa000007" "$T/sup/sends")" = 1 ] && [ "$(calls "send_message 100000000000000004 Escalation t_aa000007")" = 1 ] && [ "$(jq -r "select(.card == \"t_aa000007\" and .event == \"THREAD_OPENED\") | .card" "$T/sup/escalations.log" | wc -l)" = 1 ]' "H1: the retry posts in the same thread (no second thread), then one THREAD_OPENED and one link"

# F21: a completion prompt nobody answered in 7 days is marked expired once and no longer polled; the thread is kept.
printf 't_ee000001\t1500\t1501\tpending\t2026-10-01T00:00:00Z\tv3\n' >> "$T/sup/state/escalation-delete.tsv"
FAKE_DEL=owner $P; FAKE_DEL=owner $P
ok '[ "$(calls "reaction_users 1500")" = 0 ] && [ "$(calls "delete_thread 1500")" = 0 ] && [ "$(ev PROMPT_EXPIRED)" = 1 ] && grep -q "^t_ee000001	1500	1501	expired	" "$T/sup/state/escalation-delete.tsv"' "F21: a prompt older than 7 days: expired once, not polled, not deleted"
ok '[ -z "$(card=""; . /workspace/bin/escalation-discord.sh; thread_closed 1500 && echo closed)" ]' "F21: an expired prompt's thread stays open for reuse"
# Review round 2: an unanswered card whose first decision was posted blocks again with a new decision whose post failed;
# the retry is keyed on the decision's fingerprint, so it posts the new decision in the same thread (no new thread, no
# second link).
printf '1300\tt_aa000008\t2026\tCard 8\n' >> "$T/sup/state/escalation-threads.tsv"; printf 't_aa000008\tlegacy\tnow\n' >> "$T/sup/state/escalation-completed.tsv"
printf 't_aa000008\t1300\tdeadbeefdeadbeef\tnow\n' >> "$T/sup/state/escalation-posted.tsv"
rm -f "$T/sup/create_n"
FAKE_BLOCKED=t_aa000008 FAKE_REASON="Decision needed: pick (A) or (B) for card 8." $P; FAKE_BLOCKED=t_aa000008 FAKE_REASON="Decision needed: pick (A) or (B) for card 8." $P
ok '[ ! -s "$T/sup/create_n" ] && [ "$(grep -c "^--to discord:1:1300 --quiet Card t_aa000008" "$T/sup/sends")" = 1 ] && [ "$(calls "send_message 100000000000000004 Escalation t_aa000008")" = 0 ]' "a later unposted decision of an unanswered card is retried in its thread, once, no new link"
# Review round 2: a retry that finds the card lock busy does not use up one of its 3 attempts.
mkdir -p "$T/lk"; ( flock 8; sleep 7 ) 8>"$T/sup/state/thread-t_aa000009.lock" & sleep 0.3
FAKE_EXTRA_BLOCKED=t_aa000009 FAKE_BLOCKED=t_aa000009 $P
ok '! grep -q "^t_aa000009" "$T/sup/state/thread-retry.tsv"' "a busy card lock is not counted as an attempt"
wait
# D46 item 9: a silent block (blocked, latest event gave_up, no blocked event, so no hook fired): one escalation and one
# STL-ESC-232 alert per block, after the grace period; none again; a re-block after an unblock alerts again; a block that
# already has its thread message adds nothing.
now=$(date +%s); : >"$T/sup/sends"
echo 100 >"$T/sup/create_n"; c0=100   # the stub numbers threads 5000+n; earlier cases reset n, so start past their ids
cn() { echo $(( $(cat "$T/sup/create_n" 2>/dev/null || echo 0) - c0 )); }
sil() { FAKE_EXTRA_BLOCKED="$1" FAKE_BLOCKED="$1" FAKE_SILENT="$1" FAKE_SILENT_AT="$2" $P; }
sil t_ab000001 $((now - 60))
ok '[ "$(cn)" = 0 ] && [ "$(alerts "\[STL-ESC-232\]")" = 0 ]' "silent block inside the grace period: nothing yet (the normal path may still post)"
sil t_ab000001 $((now - 600))
ok '[ "$(cn)" = 1 ] && [ "$(alerts "\[STL-ESC-232\]\*\*$")" = 1 ] && [ "$(abody "^Card t_ab000001 ")" = 1 ] && [ "$(abody "the dispatcher gave up after 2 failed starts")" = 1 ] && [ "$(jq -r "select(.card == \"t_ab000001\" and .event == \"SILENT_BLOCK\") | .detail" "$T/sup/escalations.log" | grep -c "no blocked event")" = 1 ]' "silent block (gave_up after the retry limit, no blocked event): one escalation, one STL-ESC-232 alert, logged"
sil t_ab000001 $((now - 600)); sil t_ab000001 $((now - 600))
ok '[ "$(cn)" = 1 ] && [ "$(alerts "\[STL-ESC-232\]")" = 1 ]' "the same silent block on later runs: no second escalation or alert"
th=$(awk -F'\t' '$2 == "t_ab000001" { print $1 }' "$T/sup/state/escalation-threads.tsv")
sleep 1; SILENT_GRACE=0 sil t_ab000001 "$(date +%s)"   # the re-block comes after the first escalation was posted
ok '[ "$(alerts "\[STL-ESC-232\]")" = 2 ] && [ "$(cn)" = 1 ] && [ "$(grep -c "^--to discord:1:$th --quiet" "$T/sup/sends")" = 2 ]' "blocked again after an unblock (a new gave_up event): alerts again, posts in the same thread"
printf 't_ab000002\t1400\tx\t%s\n' "$(date -u +%FT%TZ)" >>"$T/sup/state/escalation-posted.tsv"; c0=$(cat "$T/sup/create_n" 2>/dev/null || echo 0)
sil t_ab000002 $((now - 600))
ok '[ "$(cn)" = 0 ] && [ "$(alerts "\[STL-ESC-232\]")" = 2 ] && grep -q "^t_ab000002	.*	already_posted$" "$T/sup/state/silent-blocks.tsv"' "a silent block that already has its thread message: no escalation, no alert"
FAKE_EXTRA_BLOCKED=t_ab000003 FAKE_BLOCKED=t_ab000003 FAKE_SILENT=t_ab000003 FAKE_SILENT_AT=$((now - 600)) FAKE_CREATE_FAILS=9999 RETRY_BACKOFF="0 0 0" $P
for _ in 1 2 3; do FAKE_EXTRA_BLOCKED=t_ab000003 FAKE_BLOCKED=t_ab000003 FAKE_SILENT=t_ab000003 FAKE_SILENT_AT=$((now - 600)) FAKE_CREATE_FAILS=9999 RETRY_BACKOFF="0 0 0" $P; done
ok '[ "$(grep -c "^t_ab000003	" "$T/sup/state/silent-blocks.tsv")" = 4 ] && grep -q "^t_ab000003	.*	3	.*	gave_up$" "$T/sup/state/silent-blocks.tsv" && [ "$(abody "^Card t_ab000003 ")" = 2 ]' "a silent block whose thread cannot be posted: 3 attempts, then STL-ESC-221 (one alert each), no fourth"
: >"$T/sup/sends"; FAKE_LIST_FAIL=1 $P; FAKE_LIST_FAIL=1 $P
ok '[ "$(alerts "\[STL-ESC-211\]")" -le 1 ]' "board unreadable: at most one alert, not one per run"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
