#!/usr/bin/env bash
# Hermetic self-test for bin/escalation-complete.sh (D30): stub hermes, scratch state, no network.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sup/state"
: > "$T/sup/limits.env"
{ cat /workspace/config/owner.example.env; printf "ESCALATIONS_CHANNEL_ID='100'\\nDISCORD_GUILD_ID='200'\\nSUPERVISOR_CHANNEL_ID='300'\\n"; } > "$T/owner.env"; export OWNER_CONFIG="$T/owner.env"   # scratch owner config (D39)
printf '555\tt_aaaaaaaa\tnow\tT16 escalation test: pick a colour\n556\tt_bbbbbbbb\tnow\tGeneric card\n557\tt_cccccccc\tnow\tNot done yet\n558\tt_dddddddd\tnow\tLegacy\n559\tt_ffffffff\tnow\tCreate phase4-test.md\n560\tt_fffffff0\tnow\tTrailing backslash\n' \
  > "$T/sup/state/escalation-threads.tsv"
printf 't_dddddddd\tlegacy\tnow\n' > "$T/sup/state/escalation-completed.tsv"
cat > "$T/sup/escalations.log" <<'L'
{"time":"x","card":"t_aaaaaaaa","event":"REPLY","detail":"thread 555 from owner (poll, message 1)","reply":"A"}
{"time":"x","card":"t_bbbbbbbb","event":"REPLY","detail":"thread 556 from owner (poll, message 2)","reply":"Option B"}
L
cat > "$T/bin/hermes" <<'S'
#!/usr/bin/env bash
[ "$1 $2" = "kanban --board" ] && set -- "$1" "${@:4}"   # scripts name the board (F4)
case "$1 $2" in
  "kanban show") case "$3" in
      t_aaaaaaaa) echo '{"task":{"status":"done","title":"Rewritten title"},"latest_summary":"Decision: A","runs":[{"summary":"Decision: A","metadata":{"decision":"A"}}]}';;
      t_bbbbbbbb) echo '{"task":{"status":"done","title":"Generic card"},"latest_summary":"Task complete.","runs":[{"summary":"Task complete.","metadata":{}}]}';;
      t_ffffffff) echo '{"task":{"status":"done","title":"x","workspace_path":"/workspace/.worktrees/t_ffffffff"},"latest_summary":"Created phase4-test.md","runs":[{"summary":"Created phase4-test.md","metadata":{"files_created":["phase4-test.md","/workspace/.worktrees/t_ffffffff/sub/b.txt"]}}]}';;
      t_fffffff0) echo '{"task":{"status":"done","title":"x","workspace_path":"/workspace/.worktrees/t_fffffff0"},"latest_summary":"Created a.md","runs":[{"summary":"Created a.md","metadata":{"files_created":["a.md"]}}]}';;
      *) echo '{"task":{"status":"running","title":"x"}}';;
    esac;;
  send*) shift; printf '%s\n' "$*" >> "$ESCALATE_SUP_DIR/sends";;
esac
exit 0
S
cat > "$T/bin/fakepy" <<'S'
#!/usr/bin/env bash
cat >/dev/null   # stub Discord helper: log the action, answer like Hermes's helper would
echo "$*" >> "$ESCALATE_SUP_DIR/discord_calls"
case "$3" in   # argv: -I - <action> ...
  send_message) echo '{"success": true, "message_id": "900"}';;
  *)            echo '{"success": true}';;
esac
S
chmod +x "$T/bin/hermes" "$T/bin/fakepy"
printf '1\tt_aaaaaaaa\t555\tnow\n' > "$T/sup/state/escalation-replies.tsv"   # the recorded reply on t_aaaaaaaa
printf 't_aaaaaaaa\t1\t👀\t1\tnow\n' > "$T/sup/state/escalation-reactions.tsv" # current status: answer recorded
export PATH="$T/bin:$PATH" ESCALATE_SUP_DIR="$T/sup" HERMES_PY="$T/bin/fakepy"
X=/workspace/bin/escalation-complete.sh
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
completed() { jq -r --arg c "$1" 'select(.card == $c and .event == "COMPLETED") | .card' "$T/sup/escalations.log" | wc -l; }
posts() { cat "$T/sup/sends" 2>/dev/null; grep "^-I - send_message 300 " "$T/sup/discord_calls" 2>/dev/null; }   # thread (hermes send) + #supervisor (REST)
sends_for() { posts | awk -v k="$1" 'index($0, k) { n++ } END { print n + 0 }'; }

$X t_aaaaaaaa "Decision: A"
ok '[ "$(sends_for t_aaaaaaaa)" = 2 ]' "done escalated card: one thread message + one #supervisor message"
ok 'grep -qx -- "--to discord:100:555 --quiet Card t_aaaaaaaa: T16 escalation test: pick a colour" "$T/sup/sends" && grep -qx "Resolved: done. Decision: A. Status: done." "$T/sup/sends"' "thread message: Card <id>: <title> first (F6), then the Resolved marker, decision once, no repeated summary"
ok 'grep -qx -- "-I - send_message 300 Done t_aaaaaaaa: \"T16 escalation test: pick a colour\". Decision: A. Status: done." "$T/sup/discord_calls"' "#supervisor message uses the original title, no link"
ok '! grep -q -- "--to discord:300" "$T/sup/sends"' "#supervisor message goes by REST, never hermes send (no mirror into Stella's session, F1)"
ok '! posts | grep -q "discord.com/channels\|<#"' "no link in either completion message"
ok '[ "$(completed t_aaaaaaaa)" = 1 ] && jq -s -e "any(.[]; .event==\"COMPLETED\" and .status == \"done\" and .reply == \"A\" and .thread == \"555\")" "$T/sup/escalations.log" >/dev/null' "one COMPLETED event with thread, reply, summary, status done"
ok 'grep -q "react_remove 555 1 👀" "$T/sup/discord_calls" && grep -q "react_add 555 1 🌟" "$T/sup/discord_calls" && [ "$(tail -1 "$T/sup/state/escalation-reactions.tsv" | cut -f3)" = "🌟" ]' "🌟 replaces 👀 on the reply (one reaction)"
ok '[ "$(grep -c "send_message 555 What should happen to this thread? React 🔒 Archive" "$T/sup/discord_calls")" = 1 ] && grep -q "react_add 555 900 🔒" "$T/sup/discord_calls" && grep -q "react_add 555 900 🗑️" "$T/sup/discord_calls" && ! grep -q "📌" "$T/sup/discord_calls"' "one prompt with only 🔒 archive and 🗑️ delete pre-added, no 📌"
ok 'grep -qP "^t_aaaaaaaa\t555\t900\tpending\t[^\t]+\tv3$" "$T/sup/state/escalation-delete.tsv"' "prompt recorded as pending (v3)"
n_calls=$(wc -l < "$T/sup/discord_calls")
$X t_aaaaaaaa "Decision: A"
ok '[ "$(sends_for t_aaaaaaaa)" = 2 ] && [ "$(completed t_aaaaaaaa)" = 1 ] && [ "$(wc -l < "$T/sup/discord_calls")" = "$n_calls" ]' "second check of a done card: nothing posted, no second COMPLETED, no Discord call"
sed -i '/^t_aaaaaaaa\tdelete_prompt\t/d' "$T/sup/state/escalation-completed.tsv"   # prompt not yet recorded: the retry path that duplicated t_16d371f3
$X t_aaaaaaaa "Decision: A"
ok '[ "$(sends_for t_aaaaaaaa)" = 2 ] && [ "$(completed t_aaaaaaaa)" = 1 ]' "completion prompt retried later: no second message, no second COMPLETED"

$X t_bbbbbbbb ""
ok 'grep -q "Done t_bbbbbbbb: \"Generic card\". Decision: Option B. Summary: Decision: Option B (source: escalation reply, thread 556, answered by owner). Status: done." "$T/sup/discord_calls"' "generic worker summary falls back to the recorded reply"
$X t_cccccccc ""
ok '[ "$(sends_for t_cccccccc)" = 0 ] && [ "$(completed t_cccccccc)" = 0 ]' "card not done: nothing"
$X t_dddddddd ""
ok '[ "$(sends_for t_dddddddd)" = 0 ]' "legacy-recorded card: nothing"
$X t_eeeeeeee ""
ok '[ "$(sends_for t_eeeeeeee)" = 0 ]' "card without an escalation thread: nothing"
# F4: the deliverable's Windows path, computed from workspace_path + files_created (relative or absolute), never the model's.
$X t_ffffffff ""
W='C:\stack\.worktrees\t_ffffffff\phase4-test.md, C:\stack\.worktrees\t_ffffffff\sub\b.txt'   # OWNER_STACK_PATH_WIN='C:\stack' (D39)
ok 'grep -qF "Done t_ffffffff: \"Create phase4-test.md\". Decision: see summary. Summary: Created phase4-test.md. Path: $W. Status: done." "$T/sup/discord_calls" && grep -qF "Path: $W. Status: done." "$T/sup/sends"' "completion lines carry the computed Windows path"
printf "OWNER_STACK_PATH_WIN='C:\\\\stack\\\\'\n" >> "$T/owner.env"   # the same path with a trailing backslash: one is dropped
$X t_fffffff0 ""
ok 'grep -qF "Path: C:\\stack\\.worktrees\\t_fffffff0\\a.md. Status: done." "$T/sup/sends"' "a trailing backslash on OWNER_STACK_PATH_WIN is dropped when joining (shell)"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
