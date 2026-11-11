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
c.execute("create table sessions (id text primary key, started_at real, source text, parent_session_id text, end_reason text)")
c.execute("create table messages (id integer primary key autoincrement, session_id text, role text, content text, tool_call_id text, tool_calls text, tool_name text, active integer default 1, compacted integer default 0)")
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
CLAUDE="bash /workspace/bin/claude-review.sh"

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
# follow-up 4, item 4 (D105): a context compression mid-run gives the session a new id whose parent_session_id is the old one; the call made before
# it still counts for the run (the lineage, child to parents). Never the other way round, never an unrelated session, never a cycle.
link() { python3 - "$DB" "$1" "$2" "${3:-compression}" <<'P2'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("insert into sessions (id, parent_session_id) values (?, ?) on conflict(id) do update set parent_session_id = excluded.parent_session_id", (sys.argv[2], sys.argv[3]))
if sys.argv[3]:   # Hermes marks the parent it compressed away with end_reason compression; any other parent link (a reset, a branch, a sub-agent) is not the same run
    c.execute("insert or ignore into sessions (id) values (?)", (sys.argv[3],)); c.execute("update sessions set end_reason = ? where id = ?", (sys.argv[4], sys.argv[3]))
c.commit()
P2
}
link s_comp1 s_ok; link s_comp2 s_comp1; link s_comp2b s_ok; python3 - "$DB" <<'P3'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("update sessions set end_reason = null where id = 's_ok'"); c.commit()
P3
ok '[ "$(gate "$CP" s_comp2b)" = 2 ]' "item 4: a parent link whose parent did not end by compression (a reset, a branch, a sub-agent) is not followed"
link s_comp1 s_ok
ok '[ "$(gate "$CP" s_comp1)" = 0 ]' "item 4: after a compression (child of the session that holds the call) the approval counts"
ok '[ "$(gate "$CP" s_comp2)" = 0 ]' "item 4: after two compressions (grandchild) the approval counts"
link s_lone ""; ok '[ "$(gate "$CP" s_lone)" = 2 ]' "item 4: a session with no parent link and no call is refused"
link s_kid s_none; ok '[ "$(gate "$CP" s_kid)" = 2 ]' "item 4: a child of a session that holds no call is refused"
link s_okchild s_changes; ok '[ "$(gate "$CP" s_okchild)" = 2 ]' "item 4: a child of a session whose call answered CHANGES is refused"
add s_child_only "$CLAUDE" '{"output":"APPROVE fine","exit_code":0,"error":null}'; link s_child_only s_lone
ok '[ "$(gate "$CP" s_lone)" = 2 ]' "item 4: the parent never inherits a call made by its child (direction)"
link s_cyc_a s_cyc_b; link s_cyc_b s_cyc_a; ok '[ "$(gate "$CP" s_cyc_a)" = 2 ]' "item 4: a parent cycle terminates and refuses"
prev=s_ok; for i in $(seq 1 60); do link s_long$i $prev; prev=s_long$i; done
ok '[ "$(gate "$CP" s_long60)" = 2 ]' "item 4: a chain longer than the cap (50) does not reach the call (bounded walk)"
ok '[ "$(gate "$CP" s_long20)" = 0 ]' "item 4: a chain within the cap reaches the call"
python3 - "$DB" <<'P4'
import sqlite3, sys, json
c = sqlite3.connect(sys.argv[1])
c.execute("insert into messages (session_id, role, content, tool_calls, active, compacted) values ('s_inplace', 'assistant', '', ?, 0, 1)",
          (json.dumps([{"call_id": "call_ip", "function": {"name": "terminal", "arguments": json.dumps({"command": "bash /workspace/bin/claude-review.sh"})}}]),))
c.execute("insert into messages (session_id, role, content, tool_call_id, active, compacted) values ('s_inplace', 'tool', ?, 'call_ip', 0, 1)", (json.dumps({"output": "APPROVE ok", "exit_code": 0, "error": None}),))
c.commit()
P4
ok '[ "$(gate "$CP" s_inplace)" = 0 ]' "item 4 (the live default, compression.in_place true): a call that sits in compacted rows of the same session still counts"
# red-team S6K-RT1-01/04: ids are only unique inside one session, and the last answered call decides
python3 - "$DB" <<'P5'
import sqlite3, sys, json
c = sqlite3.connect(sys.argv[1])
def call(sid, cid, cmd): c.execute("insert into messages (session_id, role, content, tool_calls) values (?, 'assistant', '', ?)", (sid, json.dumps([{"call_id": cid, "function": {"name": "terminal", "arguments": json.dumps({"command": cmd})}}])))
def res(sid, cid, out): c.execute("insert into messages (session_id, role, content, tool_call_id) values (?, 'tool', ?, ?)", (sid, json.dumps({"output": out, "exit_code": 0, "error": None}), cid))
# parent: the review call answered CHANGES under id call_0; child: a git command with the SAME id whose output starts with APPROVE (a file named APPROVE.md)
call("s_par", "call_0", "bash /workspace/bin/claude-review.sh"); res("s_par", "call_0", "CHANGES: no")
call("s_kid", "call_0", "git diff --name-only main...HEAD"); res("s_kid", "call_0", "APPROVE.md\nsrc/app.js")
# last answer decides: APPROVE then CHANGES in one session
call("s_two", "call_a", "bash /workspace/bin/claude-review.sh"); res("s_two", "call_a", "APPROVE ok")
call("s_two", "call_b", "bash /workspace/bin/claude-review.sh"); res("s_two", "call_b", "CHANGES now")
# and CHANGES then APPROVE
call("s_two2", "call_a", "bash /workspace/bin/claude-review.sh"); res("s_two2", "call_a", "CHANGES first")
call("s_two2", "call_b", "bash /workspace/bin/claude-review.sh"); res("s_two2", "call_b", "APPROVE after the fix")
# a result stored BEFORE its call (id order) does not pair
res("s_early", "call_x", "APPROVE early"); call("s_early", "call_x", "bash /workspace/bin/claude-review.sh")
c.commit()
P5
link s_kid s_par
ok '[ "$(gate "$CP" s_kid)" = 2 ]' "red-team S6K-RT1-01: a git result with the same call id in the child session is not the parent's Claude answer"
ok '[ "$(gate "$CP" s_two)" = 2 ]' "red-team S6K-RT1-04: an APPROVE followed by a later CHANGES is refused (the last answered call decides)"
ok '[ "$(gate "$CP" s_two2)" = 2 ]' "red-team S6L-RT-08: once Claude answered CHANGES in this run, a later APPROVE does not count (a read-only reviewer cannot change anything between two calls, so that is only a re-roll)"
python3 - "$DB" <<'P6'
import sqlite3, sys, json
c = sqlite3.connect(sys.argv[1])
def call(sid, cid): c.execute("insert into messages (session_id, role, content, tool_calls) values (?, 'assistant', '', ?)", (sid, json.dumps([{"call_id": cid, "function": {"name": "terminal", "arguments": json.dumps({"command": "bash /workspace/bin/claude-review.sh"})}}])))
def res(sid, cid, out, code=0, err=None): c.execute("insert into messages (session_id, role, content, tool_call_id) values (?, 'tool', ?, ?)", (sid, json.dumps({"output": out, "exit_code": code, "error": err}), cid))
call("s_retry", "c1"); res("s_retry", "c1", "Failed to authenticate. API Error: 401", 1)
call("s_retry", "c2"); res("s_retry", "c2", "APPROVE after the failed call")
c.commit()
P6
ok '[ "$(gate "$CP" s_retry)" = 0 ]' "a call that FAILED (exit 1) may be repeated: the later APPROVE counts (only an answered CHANGES is final)"
ok '[ "$(gate "$CP" s_early)" = 2 ]' "a result that precedes its call does not pair"
# cluster A round (verifier MEDIUM-1/LOW-4, red-team S6M-RA-01..04)
python3 - "$DB" <<'P7'
import sqlite3, sys, json
c = sqlite3.connect(sys.argv[1])
R = "bash /workspace/bin/claude-review.sh"
def call(sid, cid, cmd=R, args=None):
    a = json.dumps({"command": cmd}) if args is None else args
    c.execute("insert into messages (session_id, role, content, tool_calls) values (?, 'assistant', '', ?)", (sid, json.dumps([{"call_id": cid, "function": {"name": "terminal", "arguments": a}}])))
def res(sid, cid, out, code=0, err=None, raw=None):
    c.execute("insert into messages (session_id, role, content, tool_call_id) values (?, 'tool', ?, ?)", (sid, raw if raw is not None else json.dumps({"output": out, "exit_code": code, "error": err}), cid))
# a backgrounded review: Hermes stores a background-start result (it carries a session_id and is not Claude's answer)
call("s_bg", "b1"); res("s_bg", "b1", None, raw=json.dumps({"output": "Background process started", "exit_code": 0, "error": None, "session_id": "proc_1"}))
call("s_bg", "b2"); res("s_bg", "b2", "APPROVE after the real run")
# Hermes appends a hint after the stored JSON: it must not turn a CHANGES into "not an answer"
call("s_hint", "h1"); res("s_hint", "h1", None, raw=json.dumps({"output": "CHANGES no", "exit_code": 0, "error": None}) + "\n\n[Subdirectory hint: AGENTS.md here ...]")
call("s_hint", "h2"); res("s_hint", "h2", "APPROVE on the second ask")
# a malformed call (arguments null / not an object) is not evidence and must not break the gate
call("s_badargs", "m1", args="null"); call("s_badargs", "m2", args="[1]")
call("s_badargs", "m3"); res("s_badargs", "m3", "APPROVE with junk calls before it")
# an unanswered review call does not stay open for a later call that reuses its id
call("s_orphan", "o1"); call("s_orphan", "o1", cmd="git diff --name-only main...HEAD"); res("s_orphan", "o1", "APPROVE.md\nsrc/a.js")
# cross-session pairing (the parent holds the call, the child holds a result with the same id)
call("s_xp", "call_0"); call("s_xk", "call_0", cmd="git diff --name-only main...HEAD"); res("s_xk", "call_0", "APPROVE.md\nsrc/app.js")
# an error with exit 0 is not an answer; parent APPROVE then a failed call in the child
call("s_err", "e1"); res("s_err", "e1", "APPROVE", 0, "boom")
call("s_pa", "pa1"); res("s_pa", "pa1", "APPROVE in the parent")
call("s_ck", "ck1"); res("s_ck", "ck1", "Failed to authenticate", 1)
c.commit()
P7
link s_xk s_xp; link s_ck s_pa
ok '[ "$(gate "$CP" s_bg)" = 0 ]' "red-team S6M-RA-01: a background-start result (it carries a session id) is not an answer: the real APPROVE after it counts"
ok '[ "$(gate "$CP" s_hint)" = 2 ]' "red-team S6M-RA-02: text Hermes appends after the stored result does not turn a CHANGES into an unanswered call"
ok '[ "$(gate "$CP" s_badargs)" = 0 ]' "red-team S6M-RA-03: a call with malformed arguments is skipped, the real APPROVE counts"
ok '[ "$(gate "$CP" s_orphan)" = 2 ]' "red-team S6M-RA-04: an unanswered review call does not pair with a later call's result"
ok '[ "$(gate "$CP" s_xk)" = 2 ]' "verifier MEDIUM-1: a result in the child with the same id as the parent's call is not the parent's answer (no parent CHANGES to mask it)"
ok '[ "$(gate "$CP" s_err)" = 2 ]' "an error with exit 0 is not an answer"
ok '[ "$(gate "$CP" s_ck)" = 2 ]' "a failed call in the child after a parent's APPROVE refuses (the last result decides; repeat the call)"
ok '[ "$(gate "$CP" s_long49)" = 0 ] && [ "$(gate "$CP" s_long50)" = 2 ]' "the chain cap: 50 sessions are walked (49 parents), the 51st is not"
jq --arg cp "$CP" '.profiles[$cp].approval_evidence.chain_max = 10' "$RJ" >"$T/roles-cap10.json"
ok '[ "$(ROLES_FILE=$T/roles-cap10.json gate "$CP" s_long9)" = 0 ] && [ "$(ROLES_FILE=$T/roles-cap10.json gate "$CP" s_long10)" = 2 ]' "D122 the chain cap is read from the row (10 here): 9 parents are walked, the 10th is not"
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
ok '! bad "del(.profiles[\$cp].approval_evidence.output) | .profiles[\$cp].approval_evidence = {tool: \"terminal\", command: \"x\", chain_max: 50}"' "roles.py check refuses approval_evidence without an output pattern"
ok '! bad "del(.profiles[\$cp].approval_evidence.chain_max)"' "D122 follow-up 5: roles.py check refuses approval_evidence without chain_max (the session chain cap is data, not a literal)"
ok '! bad ".profiles[\$cp].approval_evidence.chain_max = 0"' "chain_max must be a positive integer"
ok 'jq -e ".profiles[\"$CP\"].approval_evidence.chain_max | type == \"number\" and . > 0" "$RJ" >/dev/null' "the shipped table gives the Claude reviewer a chain_max"
ok 'jq -e ".profiles[\"$CP\"].approval_evidence.command | length > 0" "$RJ" >/dev/null' "the shipped table gives the Claude reviewer an approval_evidence rule"
ok '! jq -e ".profiles[\"$NP\"].approval_evidence" "$RJ" >/dev/null 2>&1' "the 9B reviewer has none"
# follow-up 4 (item 5): the call is the stack's review command; the hint spells it out exactly as the terminal hook allows it
HOOKCMD=$(sed -n 's/^allowed="\(.*\)"$/\1/p' /workspace/docs/hermes-local/hooks/reviewer/claude-review-terminal.sh)
ok '[ -n "$HOOKCMD" ] && jq -e --arg t "$HOOKCMD" ".profiles[\"$CP\"].approval_evidence.hint | contains(\$t)" "$RJ" >/dev/null' "the shipped hint spells out the review command exactly as the terminal hook allows it"
RULE=$(jq -r ".profiles[\"$CP\"].approval_evidence.command" "$RJ")
ok '[ -n "$HOOKCMD" ] && printf %s "$HOOKCMD" | grep -Eq "$RULE" && ! printf %s "claude -p x" | grep -Eq "$RULE" && ! printf %s "$HOOKCMD x" | grep -Eq "$RULE" && ! printf %s "echo $HOOKCMD" | grep -Eq "$RULE"' "the shipped command rule accepts the hook's command and nothing around it, not the old direct call"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
