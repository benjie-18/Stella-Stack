#!/usr/bin/env bash
# Hermetic self-test for bin/check-guard.py (RU-01, D63): a worker may request review only after it ran the card's own
# `Check:` command. Scratch session store (GUARD_STATE_DB), scratch ESCALATE_SUP_DIR, a stub `hermes` for kanban show/list,
# no network, never ~/.hermes, the live board or the live alerts.log. Every row goes through the real hook in a real
# process tree (D48): a fake worker (what the card's worker_bound event names) -> shell -> interpreter -> guard, with no
# HERMES_KANBAN_* in the environment, as Hermes runs a hook.
# Overrides (the negative control, or after the staged files are installed): CHECK_GUARD=<guard under test>,
# ROLES_FILE=<table> (default: the staged roles.json.new if present, else roles.json), DOCS=<docs/hermes-local dir>,
# ESC_THREAD=<escalation-thread.sh under test>. A *.new beside a default file is the staged copy and wins. A guard outside
# /workspace/bin needs PYTHONPATH=/workspace/bin (it imports roles).
set -u
T=$(mktemp -d); trap 'kill $STR 2>/dev/null; rm -rf "$T"' EXIT
staged() { if [ -f "$1.new" ]; then echo "$1.new"; else echo "$1"; fi; }   # the staged copy while it is being installed
CG=${CHECK_GUARD:-$(staged /workspace/bin/check-guard.py)}
DOCS=${DOCS:-/workspace/docs/hermes-local}
RF=${ROLES_FILE:-$(staged "$DOCS/roles.json")}
ET=${ESC_THREAD:-$(staged /workspace/bin/escalation-thread.sh)}
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -n "${msg:-}" ] && echo "     ${msg:0:200}"; fi; }
mkdir -p "$T/bin" "$T/sup/logs" "$T/cards" "$T/home/.hermes"
# Stub hermes: `kanban --board <b> show <id> --json` prints $T/cards/<id>.json; `kanban --board <b> list --assignee <p>
# --status running --json` prints $T/running-<p>.json (default []); anything else fails. Only the stack's board answers.
B=$(sed -n 's/^KANBAN_BOARD=\([A-Za-z0-9_-]*\).*/\1/p' /workspace/bin/kanban-board.sh)
cat >"$T/bin/hermes" <<EOF
#!/usr/bin/env bash
[ "\$3" = "$B" ] || exit 1
[ "\$1 \$2 \$4 \$6" = "kanban --board show --json" ] && [ -f "$T/cards/\$5.json" ] && exec cat "$T/cards/\$5.json"
[ "\$1 \$2 \$4 \$5" = "kanban --board list --assignee" ] && { [ -f "$T/running-\$6.json" ] && exec cat "$T/running-\$6.json"; echo "[]"; exit 0; }
exit 1
EOF
chmod +x "$T/bin/hermes"
cp /workspace/config/owner.example.env "$T/owner.env"   # scratch owner config (D39): the escalation-thread copy below reads it
export OWNER_CONFIG="$T/owner.env" ROLES_FILE="$RF" ESCALATE_SUP_DIR="$T/sup" GUARD_STATE_DB="$T/state.db" PATH="$T/bin:$PATH"
unset HERMES_KANBAN_TASK HERMES_KANBAN_RUN_ID HERMES_KANBAN_BOARD HERMES_HOME
BP=$(jq -r '[.profiles | to_entries[] | select(.value.role == "builder") | .key][0]' "$RF")
[ -n "$BP" ] && [ "$BP" != null ] || { echo "FAIL the table has no builder profile"; echo "selftest FAIL (1)"; exit 1; }
WS=/workspace/.worktrees/t_0000c0de
C='python3 -m unittest -q tests.test_a.b'   # the card's check: dots and spaces, to prove the match is literal

# card <id> <assignee> <open run id> <worker pid> <its fingerprint> [claim lock]: a running card whose run is bound to that pid
# (Hermes's worker_bound event); pid 0 = no binding. Body and worktree path come from $BODY and $WS.
card() {
  jq -nca --arg id "$1" --arg a "$2" --argjson r "${3:-0}" --argjson pid "${4:-0}" --arg fp "${5:-}" --arg lock "${6:-host:1}" --arg body "$BODY" --arg ws "$WS" '
    {task: ({id: $id, assignee: $a, status: "running", body: $body} + (if $ws == "" then {} else {workspace_path: $ws} end)),
     runs: (if $r == 0 then [] else [{id: $r, ended_at: null}] end),
     events: (if $pid == 0 then [] else [{kind: "claimed", run_id: $r, payload: {lock: "host:1"}},
       {kind: "worker_bound", run_id: $r, payload: {pid: $pid, claim_lock: $lock, started_at: $fp}}] end)}' >"$T/cards/$1.json"
  jq -nc --arg id "$1" '[{id: $id}]' >"$T/running-$2.json"; }
fp() { echo "$(cat /proc/sys/kernel/random/boot_id):$(sed 's/.*) //' /proc/1/stat | awk '{print $20}')|$(sed 's/.*) //' /proc/$1/stat | awk '{print $20}')"; }
cat >"$T/hookcall.py" <<'EOF'
import subprocess, sys
sys.exit(subprocess.call(["python3", sys.argv[1]], stdin=open(sys.argv[2])))
EOF
cat >"$T/worker.sh" <<'EOF'
#!/usr/bin/env bash
echo $$ >"$1/pid"
until [ -f "$1/go" ]; do sleep 0.05; done
sh -c 'python3 "$0" "$1" "$2"' "$2" "$3" "$1/payload" >"$1/out" 2>&1
echo $? >"$1/rc"
EOF
sleep 600 & STR=$!   # a stranger: alive, nobody's ancestor
fx_ok()       { card t_0000c0de "$PROF" 7 "$1" "$2"; }
fx_nobind()   { card t_0000c0de "$PROF" 7 0; }
fx_stranger() { card t_0000c0de "$PROF" 7 "$STR" "$(fp "$STR")"; }
fx_stale()    { card t_0000c0de "$PROF" 7 "$1" "$(fp "$STR")"; }
fx_lock()     { card t_0000c0de "$PROF" 7 "$1" "$2" host:2; }
fx_closed()   { fx_ok "$@"; jq -c '.runs[0].ended_at = 1' "$T/cards/t_0000c0de.json" >"$T/c.tmp" && mv "$T/c.tmp" "$T/cards/t_0000c0de.json"; }
fx_other()    { card t_0000c0de "$OTHER" 7 "$1" "$2"; }
fx_wrongcard() { fx_ok "$@"; card t_0000beef "$PROF" 8 "$STR" "$(fp "$STR")"; }
fx_nows()     { WS= fx_ok "$@"; }
fx_relws()    { WS=relative/path fx_ok "$@"; }
# Defaults for one call; go resets them. INPUT = the tool_input, RAW = a stdin payload sent as is, TOOL = the tool name.
body() { BODY=$(printf 'Create docs/x.md with one line.\nAcceptance: the file exists.\n%s' "$1"); }
# go [fixture]: the guard's exit code in rc, its refusal text in msg (JSON decoded), under a fresh fake worker.
go() { local d="$T/w$RANDOM$RANDOM" w
  mkdir -p "$d"
  if [ -n "${RAW+x}" ]; then printf '%s' "$RAW" >"$d/payload"; else
    jq -nc --arg p "$PROF" --arg t "${TOOL:-kanban_request_review}" --arg s "${SID-s1}" --argjson i "${INPUT:-{\"task_id\":\"t_0000c0de\",\"reviewer\":\"r\",\"summary\":\"done\"\}}" \
      '{hook_event_name: "pre_tool_call", tool_name: $t, tool_input: $i, session_id: $s, cwd: "/tmp", profile: $p, extra: {}}' >"$d/payload"; fi
  bash "$T/worker.sh" "$d" "$T/hookcall.py" "$CG" & w=$!
  until [ -s "$d/pid" ]; do sleep 0.02; done
  fx_${1:-ok} "$(cat "$d/pid")" "$(fp "$(cat "$d/pid")")"; touch "$d/go"; wait $w; rc=$(cat "$d/rc"); out=$(cat "$d/out")
  msg=$(jq -r '.message // empty' <<<"$out" 2>/dev/null || true); [ -n "$msg" ] || msg=$out; }
# session <json list of [tool, args, result(, timestamp, call id)]> [sid]: a fresh store (or the same one when KEEP=1) holding
# that session. Like Hermes's messages table it has a REAL timestamp per row, increasing by call order unless an entry gives one
# (a compaction replay is a copy of an early entry: its original timestamp and call id, stored after newer rows). NOTS=1 builds
# a store without the timestamp column.
session() {
  [ "${KEEP:-0}" = 1 ] || rm -f "$T/state.db"
  python3 -I - "$T/state.db" "$1" "${2:-s1}" <<'PY'
import json, os, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
nots = os.environ.get("NOTS") == "1"
con.execute("create table if not exists messages (session_id, role, tool_call_id, tool_calls, content" + ("" if nots else ", timestamp real") + ")")
sid = sys.argv[3]
cols = "(session_id, role, tool_call_id, tool_calls, content" + ("" if nots else ", timestamp") + ")"
q = "(?, ?, ?, ?, ?" + ("" if nots else ", ?") + ")"
for i, (name, args, res, *more) in enumerate(json.loads(sys.argv[2])):
    ts, cid = (more + [None, None])[:2]
    ts = [float(ts if ts is not None else 1700000000.0 + i)] if not nots else []
    cid = cid or f"{sid}c{i}"
    tc = [{"id": cid, "function": {"name": name, "arguments": json.dumps(args)}}]
    con.execute("insert into messages " + cols + " values " + q, (sid, "assistant", None, json.dumps(tc), "", *ts))
    con.execute("insert into messages " + cols + " values " + q, (sid, "tool", cid, None, json.dumps(res), *ts))
con.commit()
PY
}
tc() { jq -nc --arg c "$1" --argjson e "$2" --arg o "$3" '["terminal", {command: $c}, {exit_code: $e, output: $o}]'; }   # tc <cmd> <exit> <output>
CW="cd $WS && $C"   # RT12-03: the only form that counts, besides the bare command with workdir = the worktree
PASS=$(tc "$CW" 0 "Ran 3 tests in 0.1s OK")
WF='["write_file", {"path": "docs/x.md", "content": "x"}, {"bytes_written": 1}]'
PT='["patch", {"path": "docs/x.md", "old_string": "a", "new_string": "b"}, {"success": true}]'
LS='["terminal", {"command": "ls docs"}, {"exit_code": 0, "output": "x.md"}]'
S() { local IFS=,; session "[$*]"; }
reset() { PROF=$BP; unset RAW TOOL INPUT; SID=s1; KEEP=0; WS=/workspace/.worktrees/t_0000c0de; body "Check: $C"; }
reset
refused() { [ "$rc" = 2 ] && jq -e '.action == "block"' <<<"$out" >/dev/null; }   # exit 2 and the block JSON Hermes reads

echo "# 1. Unit rows through the real hook"
# 1a. The card's Check line.
body "Reply when done."; S "$PASS"; go
ok 'refused && grep -qF "dispatcher" <<<"$msg" && grep -qF "omission" <<<"$msg" && grep -qF "kanban_block" <<<"$msg" && grep -qF "needs_input" <<<"$msg"' "no Check line: refused, says dispatcher omission and kanban_block needs_input"
body "Check: none: docs only, nothing to run"; S; go
ok '[ "$rc" = 0 ] && [ -z "$out" ]' "Check: none: <reason>: allowed (no command to prove)"
for l in "Check: none:" "Check: none" "Check: None :  " "Check:" "check:   "; do
  body "$l"; S "$PASS"; go
  ok 'refused && grep -qF "omission" <<<"$msg"' "\"$l\" (no command, no reason): refused as no check"
done
body "  CHECK :  $C  "; S "$PASS"; go
ok '[ "$rc" = 0 ]' "the Check keyword is case-insensitive and indented, the command trimmed: allowed"
# 1b. The command ran in the worker's own terminal.
body "Check: $C"; S "$PASS"; go
ok '[ "$rc" = 0 ] && [ -z "$out" ]' "check ran, exit 0, output: allowed"
S "$(tc "cd $WS && $C" 0 "OK")"; go
ok '[ "$rc" = 0 ]' "cd <worktree> && <check>: allowed"
S "$(tc "cd $WS/docs && $C" 0 "OK")"; go
ok 'refused && grep -qF "cd $WS && $C" <<<"$msg"' "cd into a folder of the worktree: refused (RT12-03, was allowed), names the exact form"
S "$(jq -nc --arg c "$C" --arg w "$WS" '["terminal", {command: $c, workdir: $w}, {exit_code: 0, output: "OK"}]')"; go
ok '[ "$rc" = 0 ]' "the terminal call's workdir equal to the worktree: allowed"
S "$(jq -nc --arg c "$C" --arg w "$WS/docs" '["terminal", {command: $c, workdir: $w}, {exit_code: 0, output: "OK"}]')"; go
ok 'refused && grep -qF "cd $WS && $C" <<<"$msg"' "the terminal call's workdir a folder inside the worktree: refused (RT12-03)"
body "Check: \`$C\`"; S "$PASS"; go
ok '[ "$rc" = 0 ]' "backticks around the command in the card: allowed"
body "Check: $C"
S "$(tc "cd /tmp && $C" 0 "OK")"; go
ok 'refused && grep -qF "was not run" <<<"$msg"' "cd /tmp && <check>: refused (not run in the worktree)"
S "$(tc "cd /workspace/.worktrees/t_0000c0de/../t_0000beef && $C" 0 "OK")"; go
ok 'refused && grep -qF "was not run" <<<"$msg"' "cd into a sibling worktree through ..: refused"
S "$(tc "cd /workspace/.worktrees/t_0000c0de2 && $C" 0 "OK")"; go
ok 'refused && grep -qF "was not run" <<<"$msg"' "cd into a folder whose name only starts like the worktree: refused"
S "$(jq -nc --arg c "$C" '["terminal", {command: $c, workdir: "/tmp"}, {exit_code: 0, output: "OK"}]')"; go
ok 'refused && grep -qF "was not run" <<<"$msg"' "the terminal call's workdir outside the worktree: refused"
S "$(tc "python3 -m unittest -q tests.test_a" 0 "OK")"; go
ok 'refused && grep -qF "was not run" <<<"$msg" && grep -qF "$C" <<<"$msg"' "a different command: refused, names the exact command to run"
for v in "$C | tail -1" "$C || true" "echo $C" "$C; true" "$C extra" "x$C"; do
  S "$(tc "$v" 0 "OK")"; go
  ok 'refused && grep -qF "was not run" <<<"$msg"' "a command that only contains the check ($v): refused"
done
S "$LS"; go
ok 'refused && grep -qF "was not run" <<<"$msg"' "only other commands ran: refused"
S "$(jq -nc --arg c "$C" '["execute_code", {command: $c}, {exit_code: 0, output: "OK"}]')"; go
ok 'refused && grep -qF "was not run" <<<"$msg"' "the command text in a tool other than terminal: refused"
S "$(tc "$CW" 1 "FAILED (failures=1)")"; go
ok 'refused && grep -qF "exited 1" <<<"$msg"' "exit 1: refused, names the exit code"
S "$(tc "$CW" 127 "sh: not found")"; go
ok 'refused && grep -qF "exited 127" <<<"$msg"' "exit 127: refused, names the exit code"
S '["terminal", {"command": "cd /workspace/.worktrees/t_0000c0de && python3 -m unittest -q tests.test_a.b"}, {"output": "OK"}]'; go
ok 'refused && grep -qF "not 0" <<<"$msg"' "no exit code in the result: refused"
S '["terminal", {"command": "cd /workspace/.worktrees/t_0000c0de && python3 -m unittest -q tests.test_a.b"}, {"exit_code": "0", "output": "OK"}]'; go
ok 'refused' "exit code the string \"0\": refused (only the number 0 passes)"
S '["terminal", {"command": "cd /workspace/.worktrees/t_0000c0de && python3 -m unittest -q tests.test_a.b"}, "Ran OK"]'; go
ok 'refused' "a result that is not an object: refused"
S "$(tc "$CW" 0 "")"; go
ok 'refused && grep -qF "printed nothing" <<<"$msg"' "exit 0, empty output: refused"
S "$(tc "$CW" 0 $'  \n\t ')"; go
ok 'refused && grep -qF "printed nothing" <<<"$msg"' "exit 0, whitespace-only output: refused"
S "$(tc "$CW" 0 $'\x1b[32m\x1b[0m')"; go
ok 'refused && grep -qF "printed nothing" <<<"$msg"' "exit 0, colour codes only: refused"
S "$(jq -nc --arg c "$CW" '["terminal", {command: $c}, {exit_code: 0}]')"; go
ok 'refused && grep -qF "printed nothing" <<<"$msg"' "exit 0, no output field: refused"
# 1c. Files changed after the check; the last matching call counts.
S "$PASS" "$WF"; go
ok 'refused && grep -qF "files changed after" <<<"$msg"' "write_file after the check: refused"
S "$PASS" "$PT"; go
ok 'refused && grep -qF "files changed after" <<<"$msg"' "patch after the check: refused"
S "$WF" "$PT" "$PASS"; go
ok '[ "$rc" = 0 ]' "write_file and patch BEFORE the check: allowed"
S "$PASS" "$WF" "$PASS"; go
ok '[ "$rc" = 0 ]' "a write, then the check run again on the final files: allowed"
S "$PASS" "$LS"; go
ok '[ "$rc" = 0 ]' "a read-only command after the check: allowed"
S "$PASS" "$(tc "$CW" 1 "FAILED")"; go
ok 'refused && grep -qF "exited 1" <<<"$msg"' "an early pass then a later failing run: refused (the last run counts)"
S "$(tc "$CW" 1 "FAILED")" "$PASS"; go
ok '[ "$rc" = 0 ]' "an early failure then a later pass: allowed (the last run counts)"
S "$PASS" "$(tc "$CW" 0 "")"; go
ok 'refused && grep -qF "printed nothing" <<<"$msg"' "an early pass then a later silent run: refused"
# 1d. Session id and store, fail closed.
S "$PASS"; SID=""; go
ok 'refused && grep -qF "no session id" <<<"$msg"' "session id missing: refused"
reset
S "$PASS"; SID=s9; go; SID=s1
ok 'refused && grep -qF "was not run" <<<"$msg"' "a session id the store does not hold: refused"
S; KEEP=1 session "[$PASS]" s2; go
ok 'refused && grep -qF "was not run" <<<"$msg"' "the check ran in ANOTHER session: refused"
KEEP=0; S "$PASS"
PROF=zz-no-such-store GUARD_STATE_DB="$T/none.db" go
ok 'refused && grep -qF "cannot read the worker session" <<<"$msg"' "session store missing: refused (fail closed)"
echo "not a database" >"$T/junk.db"; PROF=$BP GUARD_STATE_DB="$T/junk.db" go
ok 'refused && grep -qF "internal error" <<<"$msg"' "session store not a database: refused (fail closed)"
python3 -I -c 'import sqlite3, sys; sqlite3.connect(sys.argv[1]).execute("create table t (a)")' "$T/empty.db"; GUARD_STATE_DB="$T/empty.db" go
ok 'refused && grep -qF "internal error" <<<"$msg"' "session store without the messages table: refused (fail closed)"
S '["terminal", {"command": "cd /workspace/.worktrees/t_0000c0de && python3 -m unittest -q tests.test_a.b"}, {"exit_code": 0, "output": "OK"}]'
python3 -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("insert into messages (session_id, role, tool_call_id, tool_calls, content, timestamp) values (?, ?, null, ?, ?, 1800000000.0)", ("s1", "assistant", "not json", "")); c.commit()' "$T/state.db"
go
ok 'refused && grep -qF "internal error" <<<"$msg"' "a damaged tool_calls row in the session: refused (fail closed)"
# 1e. Payload shape and card identity.
S "$PASS"
RAW='not json'; go; ok 'refused && grep -qF "internal error" <<<"$msg"' "malformed stdin: refused"; unset RAW
RAW=''; go; ok 'refused' "empty stdin: refused"; unset RAW
RAW='[1]'; go; ok 'refused' "stdin that is a list: refused"; unset RAW
for ti in '"a string"' '[]' '["t_0000c0de"]' '7' 'null'; do
  INPUT=$ti; go
  ok 'refused' "tool_input $ti (not an object) with the check run: refused"
done
INPUT='{"task_id":["t_0000c0de"]}'; go; ok 'refused' "task_id a list: refused"
INPUT='{"task_id":" t_0000c0de"}'; go; ok 'refused' "task_id with a leading space: refused"
INPUT='{"task_id":"t_0000beef"}'; go wrongcard
ok 'refused && grep -qF "stack could not prove" <<<"$msg"' "task_id of another card (bound to another process): refused"
INPUT='{"task_id":"t_0000dead"}'; go
ok 'refused && grep -qF "stack could not prove" <<<"$msg"' "task_id of a card the board does not know: refused"
INPUT='{"reviewer":"r","summary":"done"}'; go
ok '[ "$rc" = 0 ]' "no task_id: the profile's own running card is proven and used: allowed"
unset INPUT
OTHER=someone-else go other
ok 'refused && grep -qF "is assigned to" <<<"$msg"' "a card assigned to another profile: refused"
go nows
ok 'refused && grep -qF "no worktree path" <<<"$msg"' "a card with no worktree path on the board: refused"
go relws
ok 'refused && grep -qF "no worktree path" <<<"$msg"' "a relative worktree path on the board: refused"
# 1f. Other tools are untouched, whatever the card or the session says.
body "no check line at all"; S
for t in kanban_block kanban_comment kanban_show terminal write_file; do
  TOOL=$t go; ok '[ "$rc" = 0 ] && [ -z "$out" ]' "tool $t: allowed untouched (no check line, empty session)"
done
TOOL=kanban_request_review_x go; ok '[ "$rc" = 0 ]' "a tool name that only starts like the gated one: allowed untouched"
reset

# 1g. RT12: kanban_complete is gated like kanban_request_review; background runs; the worktree form; many Check lines; compaction;
# locale noise; a linear Check regex.
reset
for t in kanban_request_review kanban_complete; do
  TOOL=$t
  S "$PASS"; go
  ok '[ "$rc" = 0 ] && [ -z "$out" ]' "$t: check ran in the worktree, exit 0, output: allowed"
  S "$LS"; go
  ok 'refused && grep -qF "was not run" <<<"$msg" && grep -qF "needs_input" <<<"$msg"' "$t: check not run: refused, way out named"
  S "$(tc "$CW" 1 "FAILED")"; go
  ok 'refused && grep -qF "exited 1" <<<"$msg"' "$t: check failed: refused"
  S "$PASS" "$WF"; go
  ok 'refused && grep -qF "files changed after" <<<"$msg"' "$t: write after the check: refused"
  body "Reply when done."; S "$PASS"; go
  ok 'refused && grep -qF "omission" <<<"$msg"' "$t: no Check line: refused"
  body "Check: none: decision card, nothing to run"; S; go
  ok '[ "$rc" = 0 ] && [ -z "$out" ]' "$t: Check: none: decision card: allowed"
  body "Check: $C"; S "$PASS"
  for fx in nobind stranger stale lock closed; do
    go $fx; ok 'refused && grep -qF "the stack could not prove" <<<"$msg"' "$t: check ran but worker proof fails ($fx): refused with the could-not-prove wording"
  done
  OTHER=someone-else go other; ok 'refused && grep -qF "is assigned to" <<<"$msg"' "$t: another profile's card: refused"
  INPUT='"x"'; go; ok 'refused && grep -qF "unreadable tool arguments" <<<"$msg"' "$t: tool_input not an object: refused"
  RAW='not json'; go; ok 'refused' "$t: malformed stdin: refused"; unset RAW INPUT
  go nows; ok 'refused && grep -qF "no worktree path" <<<"$msg"' "$t: no worktree path on the card: refused"
done
reset
# RT12-02: a background start (or any result with a pid) reports exit 0 without running the check to its end.
S "$(jq -nc --arg c "$CW" '["terminal", {command: $c, background: true}, {exit_code: 0, output: "Background process started"}]')"; go
ok 'refused && grep -qF "was not run" <<<"$msg"' "RT12-02: a background terminal call (background true): not the check run, refused"
S "$(jq -nc --arg c "$CW" '["terminal", {command: $c}, {exit_code: 0, output: "started", pid: 4242}]')"; go
ok 'refused && grep -qF "was not run" <<<"$msg"' "RT12-02: a terminal result holding a pid: not the check run, refused"
S "$(jq -nc --arg c "$CW" '["terminal", {command: $c, background: false}, {exit_code: 0, output: "OK"}]')"; go
ok '[ "$rc" = 0 ]' "RT12-02: background false is a foreground call: allowed"
S "$(jq -nc --arg c "$CW" '["terminal", {command: $c, background: true}, {exit_code: 0, output: "started", pid: 4242}]')" "$PASS"; go
ok '[ "$rc" = 0 ]' "RT12-02: a background start followed by the real foreground run: allowed"
S "$PASS" "$(jq -nc --arg c "$CW" '["terminal", {command: $c, background: true}, {exit_code: 0, output: "started", pid: 4242}]')"; go
ok '[ "$rc" = 0 ]' "RT12-02: a real run followed by a background start of it: allowed (the start is no check run, the earlier run stands)"
# RT12-03: the check counts only in the worktree itself.
S "$(tc "$C" 0 "OK")"; go
ok 'refused && grep -qF "was not run" <<<"$msg" && grep -qF "cd $WS && $C" <<<"$msg"' "RT12-03: the bare command: refused, the refusal names the exact form cd <worktree> && <check>"
S "$(tc "cd $WS/sub && $C" 0 "OK")"; go
ok 'refused && grep -qF "cd $WS && $C" <<<"$msg"' "RT12-03: cd <worktree>/sub: refused"
S "$(tc "cd /tmp && $C" 0 "OK")"; go
ok 'refused && grep -qF "cd $WS && $C" <<<"$msg"' "RT12-03: cd /tmp: refused, the refusal names the exact form"
INJ="cd $WS/;npm()(echo\${IFS}ok);true && $C"
S "$(tc "$INJ" 0 "ok")"; go
ok 'refused && grep -qF "was not run" <<<"$msg"' "RT12-03: cd <ws>/;npm()(echo\${IFS}ok);true && <check> (a function that fakes the check): refused"
for pre in "cd $WS; " "cd $WS || true; " "cd \"$WS\" && " "cd \$HOME && " "cd $WS && cd /tmp && "; do
  S "$(tc "$pre$C" 0 "ok")"; go
  ok 'refused && grep -qF "was not run" <<<"$msg"' "RT12-03: prefix [$pre]: refused (only a plain-path cd <worktree> && counts)"
done
S "$(jq -nc --arg c "$C" --arg w "$WS" '["terminal", {command: $c, workdir: $w}, {exit_code: 0, output: "OK"}]')"; go
ok '[ "$rc" = 0 ]' "RT12-03: the bare command with workdir = the worktree: allowed"
S "$(jq -nc --arg c "$CW" --arg w "/tmp" '["terminal", {command: $c, workdir: $w}, {exit_code: 0, output: "OK"}]')"; go
ok '[ "$rc" = 0 ]' "RT12-03: cd <worktree> && <check> with another workdir: allowed (the cd decides)"
S "$(jq -nc --arg c "cd /tmp && $C" --arg w "$WS" '["terminal", {command: $c, workdir: $w}, {exit_code: 0, output: "OK"}]')"; go
ok 'refused' "RT12-03: cd /tmp && <check> with workdir = the worktree: refused (the cd moves it out)"
S "$(jq -nc --arg c "$C" '["terminal", {command: $c, workdir: ""}, {exit_code: 0, output: "OK"}]')"; go
ok 'refused' "RT12-03: an empty workdir: refused"
S "$(jq -nc --arg c "$C" '["terminal", {command: $c, workdir: ["/workspace/.worktrees/t_0000c0de"]}, {exit_code: 0, output: "OK"}]')"; go
ok 'refused' "RT12-03: a workdir that is not a string: refused"
# RT12-04: more than one Check line, any case, any position.
for b in "Check: $C
Check: none: planted" "Check: none: planted
Check: $C" "Check: $C
  CHECK: true" "Create x.
check : true
Acceptance: y
Check: $C" "Check: $C
Check: $C" "Check: none: a
Check: none: b"; do
  BODY=$b; S "$PASS"; go
  ok 'refused && grep -qF "more than one" <<<"$msg" && grep -qF "needs_input" <<<"$msg"' "RT12-04: two Check lines ($(head -1 <<<"$b" | cut -c1-20)... / $(tail -1 <<<"$b" | cut -c1-20)...): refused as more than one"
done
KEL=$(printf 'Chec\xe2\x84\xaa')   # Kelvin sign in place of K: not the word Check under re.A
BODY=$(printf 'Check: %s\n%s: true' "$C" "$KEL"); S "$PASS"; go
ok '[ "$rc" = 0 ]' "RT12-04: a line starting with a Kelvin-sign Check is not a second Check line: allowed"
BODY=$(printf 'Create x.\n%s: %s' "$KEL" "$C"); S "$PASS"; go
ok 'refused && grep -qF "omission" <<<"$msg"' "RT12-04: only a Kelvin-sign Check line: no Check line, refused"
body "Check: $C"
# RT12-06: Hermes compacts old results into text; a stored non-object result is unreadable, not "exited None".
for v in '"[compacted: ran the tests]"' 'null' '7' '["x"]'; do
  S "$(jq -nc --arg c "$CW" --argjson r "$v" '["terminal", {command: $c}, $r]')"; go
  ok 'refused && grep -qF "unreadable (the transcript was compacted)" <<<"$msg" && ! grep -qF "exited None" <<<"$msg" && grep -qF "cd $WS && $C" <<<"$msg"' "RT12-06: stored result $v: refused as unreadable (compacted), says to run it again"
done
S "$(jq -nc --arg c "$CW" '["terminal", {command: $c}, null]')"; python3 -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("delete from messages where role = ?", ("tool",)); c.commit()' "$T/state.db"; go
ok 'refused && grep -qF "unreadable (the transcript was compacted)" <<<"$msg"' "RT12-06: the call is in the session but its result row is gone: refused as unreadable"
# RT12-07: every terminal result starts with the locale warning of the shell; it is not output.
W1='/usr/bin/bash: warning: setlocale: LC_ALL: cannot change locale (en_US.UTF-8)'   # the live form (RT13-03); the bare form is W0 below
S "$(tc "$CW" 0 "$W1"$'\n'"$W1")"; go
ok 'refused && grep -qF "printed nothing" <<<"$msg"' "RT12-07: output of setlocale warnings only: refused as printed nothing"
S "$(tc "$CW" 0 "$W1"$'\n'"$W1"$'\n  \n')"; go
ok 'refused && grep -qF "printed nothing" <<<"$msg"' "RT12-07: setlocale warnings and blank lines only: refused as printed nothing"
S "$(tc "$CW" 0 "$W1"$'\n'"Ran 3 tests OK")"; go
ok '[ "$rc" = 0 ]' "RT12-07: setlocale warning then real output: allowed"
S "$(tc "$CW" 0 "bash: warning: something else")"; go
ok '[ "$rc" = 0 ]' "RT12-07: only the setlocale warning is noise: another warning counts as output"
# RT12-08: the Check regex is linear. Bound is generous (the quadratic regex took many times longer on this body).
SP=$(head -c 60000 /dev/zero | tr '\0' ' ')
for b in "Check:${SP}x" "Check:${SP}" "Check: ${C}${SP}x"; do
  BODY=$b; S "$PASS"; t0=$SECONDS; go; dt=$((SECONDS - t0))
  ok '[ "$dt" -lt 8 ] && [ "$rc" != "" ]' "RT12-08: a Check line with 60,000 spaces (${b:0:12}...) finishes ($dt s, bound 8 s incl. the process tree)"
done
reset

# 1h. RT13: message order, subagents, the live locale form, worktree paths that need quoting, prose after the backticked command.
reset
# RT13-01: Hermes compaction stores copies of early rows AFTER newer ones, with their original timestamps and call ids.
at() { jq -c --argjson ts "$2" --arg id "$3" '. + [$ts, $id]' <<<"$1"; }   # at <entry> <timestamp> <call id>: the entry as stored again
P0=$(at "$PASS" 1700000000.0 s1c0)   # a copy of the first call (the check, ok)
S "$PASS" "$WF" "$P0"; go
ok 'refused && grep -qF "files changed after" <<<"$msg"' "RT13-01: check ok, write_file, then a compaction replay of the check stored last: refused (the replay is not newer than the write)"
S "$PASS" "$PT" "$P0"; go
ok 'refused && grep -qF "files changed after" <<<"$msg"' "RT13-01: the same with patch: refused"
S "$PASS" "$WF" "$(tc "$CW" 1 "FAILED")" "$P0"; go
ok 'refused && grep -qF "exited 1" <<<"$msg"' "RT13-01: check ok, write_file, a failing re-run, then the replay: refused (the failing re-run is the last run)"
S "$LS" "$PASS" "$(at "$LS" 1700000000.0 s1c0)"; go
ok '[ "$rc" = 0 ]' "RT13-01: a clean run (ls, check) with a replay of the first call: still allowed"
S "$WF" "$PASS" "$(at "$WF" 1700000000.0 s1c0)"; go
ok '[ "$rc" = 0 ]' "RT13-01: a write BEFORE the check, replayed after it: still allowed (the replay keeps its original time)"
S "$PASS" "$PASS" "$P0"; go
ok '[ "$rc" = 0 ]' "RT13-01: the check twice and a replay: allowed"
S "$PASS"; NOTS=1 S "$PASS"; go
ok 'refused && grep -qF "internal error" <<<"$msg"' "RT13-01: a store without a timestamp column: refused (fail closed, an error message not a crash)"
# RT13-02: a subagent writes in its own session; the worker's own session shows only delegate_task.
DT='["delegate_task", {"tasks": [{"goal": "edit docs/x.md"}]}, {"results": [{"status": "completed"}]}]'
S "$PASS" "$DT"; go
ok 'refused && grep -qF "files changed after" <<<"$msg"' "RT13-02: delegate_task after the check: refused like write_file"
S "$DT" "$PASS"; go
ok '[ "$rc" = 0 ]' "RT13-02: delegate_task before the check: allowed"
S "$PASS" "$DT" "$PASS"; go
ok '[ "$rc" = 0 ]' "RT13-02: delegate_task, then the check run again: allowed"
TOOL=kanban_complete; S "$PASS" "$DT"; go
ok 'refused && grep -qF "files changed after" <<<"$msg"' "RT13-02: the same on kanban_complete: refused"
reset
# RT13-03: the live shell prints /usr/bin/bash: warning: setlocale..., a minority /bin/bash: and bash: .
W0='bash: warning: setlocale: LC_ALL: cannot change locale (en_US.UTF-8)'
W2='/bin/bash: warning: setlocale: LC_ALL: cannot change locale (en_US.UTF-8)'
S "$(tc "$CW" 0 "$W1")"; go
ok 'refused && grep -qF "printed nothing" <<<"$msg"' "RT13-03: one /usr/bin/bash: warning: setlocale line (the live form): refused as printed nothing"
S "$(tc "$CW" 0 "$W0")"; go
ok 'refused && grep -qF "printed nothing" <<<"$msg"' "RT13-03: one bare bash: warning: setlocale line: refused as printed nothing"
S "$(tc "$CW" 0 "$W1"$'\n'"$W0"$'\n'"$W2"$'\n\n \n')"; go
ok 'refused && grep -qF "printed nothing" <<<"$msg"' "RT13-03: the three forms and blank lines, nothing else: refused as printed nothing"
S "$(tc "$CW" 0 "$W0"$'\n'"Ran 3 tests OK")"; go
ok '[ "$rc" = 0 ]' "RT13-03: bare warning then real output: allowed"
S "$(tc "$CW" 0 "$W1"$'\n'"Ran 3 tests OK"$'\n'"$W1")"; go
ok '[ "$rc" = 0 ]' "RT13-03: live warning around real output: allowed"
S "$(tc "$CW" 0 "/usr/bin/bash: warning: something else")"; go
ok '[ "$rc" = 0 ]' "RT13-03: another warning from the live shell counts as output"
S "$(tc "$CW" 0 "/usr/bin/bash: line 1: setlocale: command not found")"; go
ok '[ "$rc" = 0 ]' "RT13-03: only the warning line is noise: a line that merely mentions setlocale counts as output"
# RT13-04: a worktree path that needs quoting. The accepted forms: cd '<path>' && cmd, and workdir == the worktree.
for W in "/workspace/projects/My Game/.worktrees/t_0000c0de" "/workspace/projets/jeu-$(printf '\xc3\xa9')/.worktrees/t_0000c0de" "/workspace/c++lib/@a=b,c/.worktrees/t_0000c0de"; do
  WS=$W; body "Check: $C"; Q=$(python3 -c 'import shlex, sys; print(shlex.quote(sys.argv[1]))' "$W"); n="[${W#/workspace/}]"
  S "$(tc "cd '$W' && $C" 0 "OK")"; go
  ok '[ "$rc" = 0 ]' "RT13-04 $n: cd '<path>' && <check> (single-quoted, equal to the worktree): allowed"
  S "$(jq -nc --arg c "$C" --arg w "$W" '["terminal", {command: $c, workdir: $w}, {exit_code: 0, output: "OK"}]')"; go
  ok '[ "$rc" = 0 ]' "RT13-04 $n: workdir = the worktree, bare command: allowed"
  S "$(tc "cd $W && $C" 0 "OK")"; go
  ok 'refused && grep -qF "was not run" <<<"$msg"' "RT13-04 $n: the unquoted cd form: refused"
  S "$(tc "cd \"$W\" && $C" 0 "OK")"; go
  ok 'refused && grep -qF "was not run" <<<"$msg"' "RT13-04 $n: the double-quoted cd form: refused (expansion inside)"
  S "$(tc "cd '$W/sub' && $C" 0 "OK")"; go
  ok 'refused && grep -qF "was not run" <<<"$msg"' "RT13-04 $n: a quoted path that differs (a subfolder): refused"
  S "$(tc "cd '/tmp' && $C" 0 "OK")"; go
  ok 'refused && grep -qF "was not run" <<<"$msg"' "RT13-04 $n: a quoted /tmp: refused"
  S "$(tc "cd '$W;x' && $C" 0 "OK")"; go
  ok 'refused' "RT13-04 $n: a quoted path with a ; added: refused"
  S "$(tc "cd '$W\\x' && $C" 0 "OK")"; go
  ok 'refused' "RT13-04 $n: a quoted path with a backslash added: refused"
  S "$(tc "cd '$W'\\''x' && $C" 0 "OK")"; go
  ok 'refused' "RT13-04 $n: a quoted path with a single quote added: refused"
  S "$(tc "cd '$W' ; $C" 0 "OK")"; go
  ok 'refused' "RT13-04 $n: cd '<path>' ; <check> (; is not &&): refused"
  S "$LS"; go
  ok 'refused && grep -qF "cd $Q && $C" <<<"$msg"' "RT13-04 $n: the refusal prints the path shell-quoted ($Q) in the cd form"
  ok 'refused && grep -qF "workdir" <<<"$msg"' "RT13-04 $n: the refusal mentions the workdir form (the only form besides cd '<path>' that a worktree path with odd characters can use)"
done
reset
# a plain path may also be quoted; the quoted path must still equal the worktree
S "$(tc "cd '$WS' && $C" 0 "OK")"; go
ok '[ "$rc" = 0 ]' "RT13-04: a plain worktree path in single quotes: allowed"
S "$(tc "cd '/workspace/.worktrees/t_0000beef' && $C" 0 "OK")"; go
ok 'refused && grep -qF "cd $WS && $C" <<<"$msg"' "RT13-04: a plain worktree: a quoted path of another worktree: refused, plain path printed unquoted"
# RT13-05: prose after the backticked command.
S "$PASS"
body "Check: \`$C\` (prints PASS)"; go
ok '[ "$rc" = 0 ]' "RT13-05: Check: \`cmd\` (prints PASS): the command is cmd, run as cd <ws> && cmd: allowed"
body "Check: \`$C\`."; go
ok '[ "$rc" = 0 ]' "RT13-05: Check: \`cmd\`. (trailing period): allowed"
body "Check: \`$C\` and \`echo other\`"; go
ok '[ "$rc" = 0 ]' "RT13-05: Check: \`a\` and \`b\`: the first span is the command: allowed when a ran"
S "$(tc "cd $WS && echo other" 0 "other")"; go
ok 'refused && grep -qF "was not run" <<<"$msg" && grep -qF "$C" <<<"$msg"' "RT13-05: Check: \`a\` and \`b\`: only b ran: refused, the refusal names a"
body "Check: \`$C (prints PASS)"; S "$PASS"; go
ok 'refused && grep -qF "was not run" <<<"$msg"' "RT13-05: an unclosed leading backtick keeps the whole value as the command: running the bare command is refused"
S "$(tc "cd $WS && \`$C (prints PASS)" 0 "OK")"; go
ok '[ "$rc" = 0 ]' "RT13-05: ...and the whole value as written is what counts: allowed"
body "Check: node t.js"; S "$(tc "cd $WS && node t.js" 0 "PASS")"; go
ok '[ "$rc" = 0 ]' "RT13-05: plain Check: node t.js (no backticks): unchanged, allowed"
S "$(tc "cd $WS && node t.js extra" 0 "PASS")"; go
ok 'refused && grep -qF "was not run" <<<"$msg"' "RT13-05: plain Check: node t.js, node t.js extra ran: refused"
for b in 'Check: ``' 'Check: `  `' 'Check: `` (see the card)'; do
  BODY=$b; S "$PASS"; go
  ok 'refused && grep -qF "omission" <<<"$msg"' "RT13-05: [$b] (an empty backtick span): no command, refused as omission (no Check line), nothing runs"
done
reset

echo "# 2. Real path (D48): worker -> shell -> interpreter -> guard, no HERMES_KANBAN_* in the environment"
S "$PASS"; go
ok '[ "$rc" = 0 ] && [ -z "$out" ] && [ -z "$(env | grep ^HERMES_KANBAN)" ]' "bound card, Check line, check ran, no ids in the environment: allowed"
S "$LS"; go
ok 'refused && grep -qF "was not run" <<<"$msg" && grep -qF "needs_input" <<<"$msg"' "same card, check not run: refused, and the way out (kanban_block needs_input) is named"
S "$(tc "$CW" 1 "FAILED")"; go
ok 'refused && grep -qF "exited 1" <<<"$msg"' "same card, check failed: refused"
S "$PASS"
while IFS='|' read -r fx needle label; do
  go "$fx"
  ok 'refused && grep -qF "the stack could not prove" <<<"$msg" && grep -qF "fault in the stack" <<<"$msg" && grep -qF "needs_input" <<<"$msg" && grep -qF -- "$needle" <<<"$msg"' "check ran but $label: refused with the could-not-prove wording"
done <<'LIST'
nobind|has no recorded worker process|the run is bound to no worker process (nobind)
stranger|is not an ancestor of this call|the run is bound to a process that is not an ancestor (stranger)
stale|start time differs|the run is bound to an ancestor pid with another start time
lock|claim lock|the worker bound under another claim lock
closed|has no open run|the card's run is closed
LIST
OTHER=someone-else go other
ok 'refused && grep -qF "the stack could not prove" <<<"$msg"' "check ran but the card is another profile's (other-assignee): refused with the could-not-prove wording"
HERMES_KANBAN_TASK=t_0000c0de HERMES_KANBAN_RUN_ID=7 go nobind
ok 'refused && grep -qF "the stack could not prove" <<<"$msg"' "ids only in the environment, no run bound: refused (the environment proves nothing)"
HERMES_KANBAN_BOARD=other go
ok '[ "$rc" = 0 ]' "HERMES_KANBAN_BOARD=other in the hook's environment: still proven on the stack's board, allowed"
PATH=/usr/bin:/bin go
ok 'refused && grep -qF "the stack could not prove" <<<"$msg"' "kanban show unavailable: refused"
# the worker's own claim is not evidence: a summary that says the check passed, a check that did not run
INPUT='{"task_id":"t_0000c0de","reviewer":"r","summary":"verified, the check passes"}'; S "$LS"; go
ok 'refused' "a summary that claims the check passed, with no run: refused (the claim is not evidence)"
reset

echo "# 3. Registration (staged table: $RF)"
msg=
ok '[ "$(jq -r --arg p "$BP" ".roles[.profiles[\$p].role].hooks | map(select(.matcher == \"^(kanban_request_review|kanban_complete)\$\")) | map(.command) | .[]" "$RF")" = /workspace/bin/check-guard.py ]' "the builder role ($BP) lists ^(kanban_request_review|kanban_complete)\$ -> /workspace/bin/check-guard.py (RT12-01: was kanban_request_review only)"
ok '[ "$(jq "[.roles.builder.hooks[] | select(.command == \"/workspace/bin/check-guard.py\")] | length" "$RF")" = 1 ] && [ "$(jq "[.roles.builder.hooks[] | select(.command == \"/workspace/bin/check-guard.py\") | .timeout | numbers | select(. > 0)] | length" "$RF")" = 1 ]' "the hook is listed once on the builder role, with a timeout"
ok '[ -x /workspace/bin/check-guard.py ] && head -1 /workspace/bin/check-guard.py | grep -q "^#!/usr/bin/env python3"' "the registered command exists, is executable, and has a python shebang"
for r in $(jq -r '.roles | keys[] | select(. != "builder")' "$RF"); do
  ok '! jq -e ".roles[\"$r\"].hooks // [] | any(.[]; ((.command // .file // \"\") | test(\"check-guard\")))" "$RF" >/dev/null' "the $r role does not list the check guard"
done
ok '! jq -e "[.roles | to_entries[] | select(.key != \"builder\") | .value.hooks // [] | .[] | select(.matcher | test(\"kanban_request_review\"))] | length > 0" "$RF" >/dev/null' "no other role has a hook on kanban_request_review"
ok 'python3 -c "import re, sys; m = sys.argv[1]; sys.exit(not (re.fullmatch(m, \"kanban_request_review\") and re.fullmatch(m, \"kanban_complete\") and not any(re.fullmatch(m, t) for t in (\"kanban_complete_x\", \"kanban_request_review_x\", \"terminal\", \"kanban_block\", \"kanban_comment\", \"kanban_show\"))))" "$(jq -r ".roles.builder.hooks[] | select(.command == \"/workspace/bin/check-guard.py\") | .matcher" "$RF")"' "the matcher fullmatches kanban_request_review and kanban_complete and no neighbouring tool (was: kanban_request_review only)"
msg=; H="$T/home/.hermes"; : >"$T/sup/logs/alerts.log"
for d in $(python3 -c 'import sys; sys.path.insert(0, "/workspace/bin"); import roles; [print(f) for _, f, _, l in roles.profiles(roles.load(), sys.argv[1]) if l]' "$H"); do mkdir -p "$d"; printf 'model: x\n' >"$d/config.yaml"; done
ok '[ "$(python3 /workspace/bin/roles.py check "$H" >"$T/rc.out" 2>&1; echo $?)" = 0 ] && grep -q "table valid" "$T/rc.out" && [ ! -s "$T/sup/logs/alerts.log" ]' "roles.py check passes on the table (scratch alerts sink, nothing written to the live alerts.log)"
ok '[ -x "$CG" ] && head -1 "$CG" | grep -q "^#!/usr/bin/env python3"' "the guard under test is executable with a python shebang (it is installed by mv)"
ok 'python3 -c "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], \"exec\")" "$CG"' "the guard compiles"
# The guard source names no profile, role-table display name or the board (copy of role-guard-selftest section 8).
names=$(jq -r --arg b "$B" '(.profiles | to_entries[] | select(.value.dir != "") | .key), (.profiles[] | .display_name // empty), $b' "$RF" | sort -u | paste -sd'|')
ok 'src=$(python3 - "$CG" <<PY
import json, sys
allow = json.load(open("/workspace/docs/hermes-local/hardcode-allow.json"))["allow"]
t = open(sys.argv[1]).read()
for a in allow:
    if a["file"] == "bin/check-guard.py":
        t = t.replace(a["text"], "")
print(t)
PY
) && [ -n "$src" ] && [ -n "$names" ] && ! grep -Eiwn "$names" <<<"$src"' "check-guard.py names no profile, display name or board (Hermes API words in hardcode-allow.json aside)"
ok '! grep -Eiq "claude|opencode|qwen|llama|gpt|anthropic|openai|ollama|lmstudio|discord|localhost|127\.0\.0\.1|/home/[a-z]|/mnt/c" "$CG"' "check-guard.py names no model, provider, host, channel or user path"

echo "# 4. Wording (staged files)"
SD=$DOCS/soul
f() { staged "$SD/$1.md"; }
ok 'grep -qF "Check: <" "$(f default)" && grep -qF "Check: none: <reason>" "$(f default)" && grep -q "RU-01" "$(f default)"' "default SOUL: the Check line template and the none: <reason> form"
ok 'grep -qi "not reviewed" "$(f default)" && grep -qF "the worker says" "$(f default)" && grep -qiF "never say" "$(f default)"' "default SOUL: the \"not reviewed\" rule (a worker's summary is its claim)"
ok 'grep -qF "Check:" "$(f default)" && grep -F "Card template" "$(f default)" | grep -qF "Check:"' "default SOUL: the Check line sits in the card template"
for s in builder-claude builder-local; do
  ok 'grep -qF "Check:" "$(f $s)" && grep -qF "kanban_request_review" "$(f $s)" && grep -qF "needs_input" "$(f $s)" && grep -qF "write_file, patch or delegate_task" "$(f $s)"' "$s SOUL: names the Check line, the exit-0 run before review, no write after it, and needs_input when absent"
  ok 'grep -qF "reports what you ran and saw" "$(f $s)" && grep -qi "never write \"verified\"" "$(f $s)"' "$s SOUL: a block reason reports what ran, never an unproven \"verified\""
done
ok 'grep -qi "approve only on evidence you read" "$(f reviewer)" && grep -qF "claim, not evidence" "$(f reviewer)" && grep -qF "Check:" "$(f reviewer)"' "reviewer SOUL: approve only on evidence read, a builder's summary is a claim, the Check line named"
ok 'grep -qF "What the worker wrote is its own claim, not checked by the stack." "$ET"' "escalation-thread.sh: the capability-block comment carries the claim sentence"
ok 'grep "kanban comment" "$ET" | grep -F "not checked by the stack." | grep -q "not checked by the stack\. Error:"' "escalation-thread.sh: the claim sentence comes right before \"Error:\""
ok 'bash -n "$ET"' "escalation-thread.sh: parses"
# escalation-thread-selftest.sh hard-codes E=/workspace/bin/escalation-thread.sh and cannot be pointed at another copy; the
# run below is a copy of that selftest with only the E= line changed (the selftest file itself is untouched).
cp "$ET" "$T/escalation-thread.sh"; chmod +x "$T/escalation-thread.sh"
sed "s#^E=/workspace/bin/escalation-thread.sh #E=$T/escalation-thread.sh #" /workspace/bin/escalation-thread-selftest.sh >"$T/est.sh"
grep -q "^E=$T/escalation-thread.sh " "$T/est.sh" && bash "$T/est.sh" >"$T/est.out" 2>&1
ok '[ "$(tail -1 "$T/est.out")" = "selftest PASS" ] && [ "$(grep -c "^ok " "$T/est.out")" -gt 0 ] && ! grep -q "^FAIL" "$T/est.out"' "escalation-thread-selftest.sh (a copy pointed at the staged script) passes: $(grep -c '^ok ' "$T/est.out" 2>/dev/null) ok rows, last line: $(tail -1 "$T/est.out" 2>/dev/null)"

[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
