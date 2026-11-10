#!/usr/bin/env bash
# Hermetic self-test for the approval-evidence rule of bin/complete-gate.py (Stage 6 follow-up 3, D100). A profile row in roles.json
# may carry approval_evidence {tool, command, output}: its kanban_complete (a reviewing role's completion is its approval) is refused
# unless THIS run's session shows a call of that tool whose command matches `command` and whose result exited 0 with output matching
# `output` (for the Claude reviewer: a `claude -p` call whose answer starts with APPROVE). The session is read from the profile's
# own state.db. Fixture roles table, fixture Hermes root with a scratch state.db; never ~/.hermes, no board, no Claude call.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
RJ=/workspace/docs/hermes-local/roles.json
# the rule under test is the shipped one (D100, fix round 1: the shipped regex once refused Claude's own **APPROVE** formatting)
# the Claude reviewer profile and the 9B reviewer, from the table by their worker kind (no name in this file)
CP=$(jq -r '[.profiles | to_entries[] | select(.value.role == "reviewer" and .value.worker == "claude-code") | .key][0]' "$RJ")
NP=$(jq -r '[.profiles | to_entries[] | select(.value.role == "reviewer" and .value.worker == "opencode") | .key][0]' "$RJ")
cp "$RJ" "$T/roles.json"
export ROLES_FILE=$T/roles.json HERMES_ROOT=$T/root ESCALATE_SUP_DIR=$T/sup PYTHONPATH=/workspace/bin
mkdir -p "$T/sup/logs"; cp /workspace/config/owner.example.env "$T/owner.env"; export OWNER_CONFIG=$T/owner.env
for pr in $(jq -r '.profiles | keys[]' "$RJ"); do   # a Hermes root that has every profile of the table (roles.py check also checks coverage)
  if [ "$pr" = default ]; then : >"$T/root/config.yaml"; else mkdir -p "$T/root/profiles/$pr"; : >"$T/root/profiles/$pr/config.yaml"; fi
done
DB=$T/root/profiles/$CP/state.db
python3 - "$DB" <<'P'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("create table sessions (id text primary key, started_at real, source text)")
c.execute("create table messages (id integer primary key autoincrement, session_id text, role text, content text, tool_call_id text, tool_calls text, tool_name text)")
P
# add <session> <command> <result json>: an assistant terminal call and its tool result
add() { python3 - "$DB" "$1" "$2" "$3" "${4:-terminal}" <<'P'
import sqlite3, sys, json
db, sid, cmd, res, tool = sys.argv[1:6]
c = sqlite3.connect(db); cid = "call_" + str(abs(hash(sid + cmd + res)))[:8]
c.execute("insert into messages (session_id, role, content, tool_calls) values (?, 'assistant', '', ?)",
          (sid, json.dumps([{"call_id": cid, "id": cid, "function": {"name": tool, "arguments": json.dumps({"command": cmd})}, "type": "function"}])))
c.execute("insert into messages (session_id, role, content, tool_call_id) values (?, 'tool', ?, ?)", (sid, res, cid))
c.commit()
P
}
# gate <profile> <session> [metadata json]: the hook's exit code and message
gate() { jq -nc --arg p "$1" --arg s "$2" --argjson m "${3:-{\"review\":\"approved\"\}}" \
  '{hook_event_name:"pre_tool_call", tool_name:"kanban_complete", tool_input:{task_id:"t_aaaaaaaa", summary:"s", metadata:$m}, session_id:$s, cwd:"/tmp", profile:$p}' \
  | python3 -I /workspace/bin/complete-gate.py >"$T/out" 2>"$T/err"; echo $?; }
CLAUDE="claude -p 'Read docs/colour.txt and say APPROVE or CHANGES' --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob"

ok '[ "$(gate "$CP" s_none)" = 2 ] && grep -q "Claude" "$T/out"' "approval with no terminal call in the session is refused (and says why)"
add s_changes "$CLAUDE" '{"output":"CHANGES\n\nthe file has no newline","exit_code":0,"error":null}'
ok '[ "$(gate "$CP" s_changes)" = 2 ]' "approval after a Claude answer of CHANGES is refused"
add s_ok "$CLAUDE" '{"output":"APPROVE. The file holds exactly red and one newline.","exit_code":0,"error":null}'
ok '[ "$(gate "$CP" s_ok)" = 0 ]' "approval after a Claude answer of APPROVE (exit 0) passes"
add s_refused "$CLAUDE" '{"error":"the reviewer role: terminal is limited to npm test"}'
ok '[ "$(gate "$CP" s_refused)" = 2 ]' "approval when the Claude call was refused by the hook (an error result) is refused"
add s_exit1 "$CLAUDE" '{"output":"APPROVE","exit_code":1,"error":null}'
ok '[ "$(gate "$CP" s_exit1)" = 2 ]' "approval when the Claude call exited non-zero is refused even if the text says APPROVE"
add s_other "git log --oneline" '{"output":"APPROVE abc123 message","exit_code":0,"error":null}'
ok '[ "$(gate "$CP" s_other)" = 2 ]' "a different command whose output starts with APPROVE does not count"
add s_md "$CLAUDE" '{"output":"**APPROVE**\n\n`docs/colour.txt` holds blue and one newline.","exit_code":0,"error":null}'
ok '[ "$(gate "$CP" s_md)" = 0 ]' "fix round 1 (verifier H1): an answer in Markdown bold (**APPROVE**) counts as APPROVE"
add s_md2 "$CLAUDE" '{"output":"## APPROVE\nall good","exit_code":0,"error":null}'
ok '[ "$(gate "$CP" s_md2)" = 0 ]' "fix round 1: a heading (## APPROVE) counts as APPROVE"
add s_mdc "$CLAUDE" '{"output":"**CHANGES**\n\nnot APPROVE yet","exit_code":0,"error":null}'
ok '[ "$(gate "$CP" s_mdc)" = 2 ]' "fix round 1: **CHANGES** is still refused"
add s_appd "$CLAUDE" '{"output":"APPROVED? no: CHANGES","exit_code":0,"error":null}'
ok '[ "$(gate "$CP" s_appd)" = 2 ]' "fix round 1: APPROVED (a longer word) is not APPROVE"
add s_not "$CLAUDE" '{"output":"NOT APPROVE","exit_code":0,"error":null}'
ok '[ "$(gate "$CP" s_not)" = 2 ]' "fix round 1: text that only contains APPROVE later is refused"
add s_late "$CLAUDE" '{"output":"CHANGES: not APPROVE","exit_code":0,"error":null}'
ok '[ "$(gate "$CP" s_late)" = 2 ]' "APPROVE inside the text but not first does not count"
add s_tool "$CLAUDE" '{"output":"APPROVE","exit_code":0,"error":null}' read_file
ok '[ "$(gate "$CP" s_tool)" = 2 ]' "a result of another tool (read_file) does not count"
ok '[ "$(gate "$CP" s_ok2)" = 2 ]' "another session's call does not count for this run (s_ok2 has none)"
ok '[ "$(gate "$CP" "")" = 2 ]' "no session id: refused"
ok '[ "$(gate "$CP" s_ok "{\"review\":\"changes\"}")" = 2 ]' "wrong metadata is still refused by the existing rule"
ok '[ "$(gate "$NP" s_none)" = 0 ]' "the 9B reviewer (no approval_evidence) completes as before"
rm -f "$DB"; ok '[ "$(gate "$CP" s_ok)" = 2 ]' "an unreadable session store refuses (fail closed)"
python3 - "$DB" <<'P'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("create table sessions (id text)"); c.commit()
P
ok '[ "$(gate "$CP" s_ok)" = 2 ]' "a session store without the messages table refuses"

# the table: a bad approval_evidence is refused by roles.py check
bad() { jq --arg cp "$CP" "$1" "$RJ" >"$T/bad.json"; ROLES_FILE=$T/bad.json python3 -I /workspace/bin/roles.py check "$T/root" >/dev/null 2>&1; }
ok 'bad ".profiles[\$cp].approval_evidence.command = \"^ok\""' "control: roles.py check accepts a valid approval_evidence on the fixture root"
ok '! bad ".profiles[\$cp].approval_evidence.command = \"(\""' "roles.py check refuses an approval_evidence regex that does not compile"
ok '! bad ".profiles[\$cp].approval_evidence = \"x\""' "roles.py check refuses approval_evidence that is not an object"
ok '! bad "del(.profiles[\$cp].approval_evidence.output) | .profiles[\$cp].approval_evidence = {tool: \"terminal\", command: \"x\"}"' "roles.py check refuses approval_evidence without an output pattern"
ok 'jq -e ".profiles[\"$CP\"].approval_evidence.command | length > 0" "$RJ" >/dev/null' "the shipped table gives the Claude reviewer an approval_evidence rule"
ok '! jq -e ".profiles[\"$NP\"].approval_evidence" "$RJ" >/dev/null 2>&1' "the 9B reviewer has none"
# D103: the refusal shows the exact call (live T7d: told only "see your SOUL", the model never made the call); the flags are the hook's own
HOOKTAIL=$(sed -n 's/^tail="\(.*\)"; nl=.*/\1/p' /workspace/docs/hermes-local/hooks/reviewer/claude-review-terminal.sh)
ok '[ -n "$HOOKTAIL" ] && jq -e --arg t "$HOOKTAIL" ".profiles[\"$CP\"].approval_evidence.hint | contains(\$t)" "$RJ" >/dev/null' "the shipped hint spells out the Claude call's flags exactly as the terminal hook requires them"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
