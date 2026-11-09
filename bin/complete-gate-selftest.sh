#!/usr/bin/env bash
# Hermetic self-test for bin/complete-gate.py (S3A-03, S3A-04; D66): the pre_tool_call hook on kanban_complete that reads two
# data-driven rules from the caller's role row in roles.json: complete_metadata (a reviewing role's completion must carry
# exactly those metadata pairs) and complete_needs_review (a builder role may not complete a card whose Check line is a
# command). Scratch session-free board (stub `hermes` for kanban show/list), scratch ESCALATE_SUP_DIR, no network, never
# ~/.hermes, the live board or the live alerts.log. Every row goes through the real hook in a real process tree (D48): a fake
# worker (what the card's worker_bound event names) -> shell -> interpreter -> hook, no HERMES_KANBAN_* in the environment.
# Profiles are read from the table by what their role says (complete_metadata, complete_needs_review), never by name.
# Overrides: STAGE=<dir holding complete-gate.py and roles.py> (default /workspace/bin), ROLES_FILE=<table> (default
# /workspace/docs/hermes-local/roles.json). A staged table lists the hook at its staged path; roles.load() requires the listed
# hook files to exist, so a staged run needs a table whose complete-gate.py path is the staged one (roles.staged.json).
set -u
T=$(mktemp -d); trap 'kill $STR 2>/dev/null; rm -r "$T"' EXIT
S=${STAGE:-/workspace/bin}
CG=$S/complete-gate.py
RF=${ROLES_FILE:-/workspace/docs/hermes-local/roles.json}
fails=0; nok=0
ok() { if eval "$1"; then echo "ok   $2"; nok=$((nok+1)); else echo "FAIL $2"; fails=$((fails+1)); [ -n "${msg:-}" ] && echo "     ${msg:0:200}"; fi; }
mkdir -p "$T/bin" "$T/sup/logs" "$T/cards"
B=$(sed -n 's/^KANBAN_BOARD=\([A-Za-z0-9_-]*\).*/\1/p' /workspace/bin/kanban-board.sh)
cat >"$T/bin/hermes" <<EOF
#!/usr/bin/env bash
[ "\$3" = "$B" ] || exit 1
[ "\$1 \$2 \$4 \$6" = "kanban --board show --json" ] && [ -f "$T/cards/\$5.json" ] && exec cat "$T/cards/\$5.json"
[ "\$1 \$2 \$4 \$5" = "kanban --board list --assignee" ] && { [ -f "$T/running-\$6.json" ] && exec cat "$T/running-\$6.json"; echo "[]"; exit 0; }
exit 1
EOF
chmod +x "$T/bin/hermes"
cp /workspace/config/owner.example.env "$T/owner.env"   # scratch owner config (D39)
# PYTHONPATH: a hook outside /workspace/bin still finds alert_catalog (roles.log_alert); the hook's own dir stays first (roles).
export OWNER_CONFIG="$T/owner.env" ROLES_FILE="$RF" ESCALATE_SUP_DIR="$T/sup" PYTHONPATH=/workspace/bin PATH="$T/bin:$PATH"
unset HERMES_KANBAN_TASK HERMES_KANBAN_RUN_ID HERMES_KANBAN_BOARD HERMES_HOME GUARD_STATE_DB
AL="$T/sup/logs/alerts.log"
# The roles and profiles under test, from the table by what the role says.
RR=$(jq -r '[.roles | to_entries[] | select(.value.complete_metadata != null) | .key][0]' "$RF")                       # reviewing role
BR=$(jq -r '[.roles | to_entries[] | select(.value.complete_needs_review == true) | .key][0]' "$RF")                   # builder role
DR=$(jq -r '[.roles | to_entries[] | select(.value.complete_metadata == null and .value.complete_needs_review != true) | .key][0]' "$RF")
RP=$(jq -r --arg r "$RR" '[.profiles | to_entries[] | select(.value.role == $r) | .key][0]' "$RF")
BP=$(jq -r --arg r "$BR" '[.profiles | to_entries[] | select(.value.role == $r) | .key][0]' "$RF")
DP=$(jq -r --arg r "$DR" '[.profiles | to_entries[] | select(.value.role == $r) | .key][0]' "$RF")
UP=zz-not-in-the-table   # a profile with no row: the fallback role
for v in RR BR DR RP BP DP; do
  [ -n "${!v}" ] && [ "${!v}" != null ] || { echo "FAIL the table has no $v (reviewing role / builder role / role with neither field / their profiles)"; echo "selftest FAIL (1)"; exit 1; }
done
[ "$(jq -r --arg p "$UP" '.profiles[$p] // "none"' "$RF")" = none ] || { echo "FAIL $UP is in the table"; echo "selftest FAIL (1)"; exit 1; }
NEED=$(jq -c --arg r "$RR" '.roles[$r].complete_metadata' "$RF")
K=$(jq -r 'keys[0]' <<<"$NEED"); V=$(jq -r --arg k "$K" '.[$k]' <<<"$NEED")
NEEDTXT=$(python3 -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1])))' "$NEED")   # the form the refusal prints
WS=/workspace/.worktrees/t_0000c0de
C='python3 -m unittest -q tests.test_a.b'

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
fx_badbody()  { fx_ok "$@"; jq -c '.task.body = ["Check: x"]' "$T/cards/t_0000c0de.json" >"$T/c.tmp" && mv "$T/c.tmp" "$T/cards/t_0000c0de.json"; }
fx_nobody()   { fx_ok "$@"; jq -c 'del(.task.body)' "$T/cards/t_0000c0de.json" >"$T/c.tmp" && mv "$T/c.tmp" "$T/cards/t_0000c0de.json"; }
DIN='{"task_id":"t_0000c0de","summary":"done"}'
body() { BODY=$(printf 'Create docs/x.md with one line.\nAcceptance: the file exists.\n%s' "$1"); }
mdin() { INPUT=$(jq -nc --argjson m "$1" '{task_id: "t_0000c0de", summary: "done", metadata: $m}'); }   # tool_input with that metadata
# go [fixture]: the hook's exit code in rc, its refusal text in msg (JSON decoded), under a fresh fake worker.
go() { local d="$T/w$RANDOM$RANDOM" w
  mkdir -p "$d"
  if [ -n "${RAW+x}" ]; then printf '%s' "$RAW" >"$d/payload"; else
    jq -nc --arg p "$PROF" --arg t "${TOOL:-kanban_complete}" --argjson i "${INPUT:-$DIN}" \
      '{hook_event_name: "pre_tool_call", tool_name: $t, tool_input: $i, session_id: "s1", cwd: "/tmp", profile: $p, extra: {}}' >"$d/payload"; fi
  bash "$T/worker.sh" "$d" "$T/hookcall.py" "$CG" & w=$!
  until [ -s "$d/pid" ]; do sleep 0.02; done
  fx_${1:-ok} "$(cat "$d/pid")" "$(fp "$(cat "$d/pid")")"; touch "$d/go"; wait $w; rc=$(cat "$d/rc"); out=$(cat "$d/out")
  msg=$(jq -r '.message // empty' <<<"$out" 2>/dev/null || true); [ -n "$msg" ] || msg=$out; }
reset() { PROF=$RP; unset RAW TOOL INPUT; ROLES_FILE=$RF; body "Check: $C"; }
refused() { [ "$rc" = 2 ] && jq -e '.action == "block"' <<<"$out" >/dev/null; }   # exit 2 and the block JSON Hermes reads
allowed() { [ "$rc" = 0 ] && [ -z "$out" ]; }
reset

echo "# 1. The reviewing role ($RR): kanban_complete must carry exactly $NEEDTXT"
PROF=$RP
mdin "$NEED"; go
ok 'allowed' "metadata $NEEDTXT: allowed"
mdin "$(jq -nc --arg k "${K}_outcome" --arg v "$V" '{($k): $v}')"; go
ok 'refused && grep -qF "$NEEDTXT" <<<"$msg" && grep -qF "kanban_request_changes" <<<"$msg"' "metadata {\"${K}_outcome\":\"$V\"} (the live failure): refused, names the exact metadata and kanban_request_changes"
INPUT=$DIN; go
ok 'refused && grep -qF "$NEEDTXT" <<<"$msg" && grep -qF "kanban_request_changes" <<<"$msg"' "no metadata at all: refused"
for m in null '"approved"' "[$NEED]" "[\"$K\",\"$V\"]" 7 true '{}'; do
  mdin "$m"; go
  ok 'refused && grep -qF "$NEEDTXT" <<<"$msg"' "metadata $m (not the pairs): refused"
done
mdin "$(jq -nc --arg k "$K" '{($k): "rejected"}')"; go
ok 'refused && grep -qF "kanban_request_changes" <<<"$msg"' "right key, value \"rejected\": refused"
for bad in " $V" "$V " "${V^^}" "${V}x" ""; do
  mdin "$(jq -nc --arg k "$K" --arg v "$bad" '{($k): $v}')"; go
  ok 'refused' "right key, value \"$bad\" (not exactly the table's): refused"
done
for badv in "[\"$V\"]" true 1 null '{}'; do
  mdin "$(jq -nc --arg k "$K" --argjson v "$badv" '{($k): $v}')"; go
  ok 'refused' "right key, value $badv (not the text): refused"
done
mdin "$(jq -nc --arg k "${K^^}" --arg v "$V" '{($k): $v}')"; go
ok 'refused' "key in another case (${K^^}): refused"
mdin "$(jq -nc --arg k " $K" --arg v "$V" '{($k): $v}')"; go
ok 'refused' "key with a leading space: refused"
mdin "$(jq -nc --arg k "$K" --arg v "$V" '{($k): $v, findings: "all good", delegate_exit_code: 0}')"; go
ok 'allowed' "the right pair plus extra keys: allowed (findings may ride along)"
mdin "$(jq -nc --arg k "$K" --arg v "$V" '{findings: "x", ($k): "rejected"}')"; go
ok 'refused' "extra keys and the wrong value: refused"
# The hook proves nothing for this role: the same call with an unbound card and a Check command in the body still passes.
body "Check: $C"; mdin "$NEED"; go nobind
ok 'allowed' "the reviewing role, right metadata, card with a Check command and no bound run: allowed (only the builder role is proven)"
go stranger; ok 'allowed' "the reviewing role, run bound to a stranger: allowed"
body "no check line"; go; ok 'allowed' "the reviewing role, right metadata, no Check line: allowed"
reset

echo "# 2. The builder role ($BR): a card whose Check line is a command is not completed by its own worker"
PROF=$BP
body "Check: $C"; go
ok 'refused && grep -qF "kanban_request_review" <<<"$msg" && grep -qF "Check: none: <reason>" <<<"$msg"' "Check: <cmd>: refused, names kanban_request_review and the Check: none form"
body "Check: none: decision card"; go
ok 'allowed' "Check: none: decision card: allowed"
body "Check: None: Decision, nothing to run"; go
ok 'allowed' "Check: None: <reason> (case): allowed"
body "Check: \`none: decision card\`"; go
ok 'allowed' "Check: \`none: <reason>\` (backticks): allowed"
body "Reply when done."; go
ok 'allowed' "no Check line: allowed by this hook (check-guard refuses it as the dispatcher's omission)"
body "- Check: $C"; go
ok 'allowed' "a bullet before Check: no Check line by the guards' own regex: allowed by this hook"
body "Recheck: $C"; go
ok 'allowed' "Recheck: <cmd> is no Check line: allowed by this hook"
for l in "Check: none" "Check: none:" "Check: None :  " "Check:" "check:   " 'Check: ``' 'Check: `  `'; do
  body "$l"; go
  ok 'allowed' "[$l] (no command): allowed by this hook (check-guard refuses it)"
done
for b in "Check: $C
Check: none: planted" "Check: none: planted
Check: $C" "Check: $C
  CHECK: true" "Check: $C
Check: $C" "Check: none: a
Check: none: b"; do
  BODY=$b; go
  ok 'allowed' "two Check lines ($(head -1 <<<"$b" | cut -c1-20)... / $(tail -1 <<<"$b" | cut -c1-20)...): allowed by this hook (check-guard refuses them)"
done
for b in "  CHECK :  $C  " $'\tcheck\t:\t'"$C" "check : $C" "CHECK:$C" "Check: \`$C\` (prints PASS)" "Check: \`$C\`." "Check: \`$C\` and \`echo other\`" "Check: node t.js"; do
  body "$b"; go
  ok 'refused && grep -qF "kanban_request_review" <<<"$msg"' "[${b//$'\t'/<TAB>}]: a command, case/space/backtick variant: refused"
done
KEL=$(printf 'Chec\xe2\x84\xaa')   # Kelvin sign in place of K: not the word Check under re.A
BODY=$(printf 'Check: %s\n%s: true' "$C" "$KEL"); go
ok 'refused && grep -qF "kanban_request_review" <<<"$msg"' "a Kelvin-sign Check line is not a second Check line: the one command still refuses"
BODY=$(printf 'Create x.\n%s: %s' "$KEL" "$C"); go
ok 'allowed' "only a Kelvin-sign Check line: no Check line, allowed by this hook"
body "Check: $C"
for fx in nobind stranger stale lock closed; do
  go $fx; ok 'refused && grep -qF "could not prove" <<<"$msg" && grep -qF "needs_input" <<<"$msg"' "Check: <cmd>, worker proof fails ($fx): refused, way out named"
done
body "Check: none: decision card"
for fx in nobind stranger stale lock closed; do
  go $fx; ok 'refused && grep -qF "could not prove" <<<"$msg"' "Check: none, worker proof fails ($fx): refused (the card cannot be proven)"
done
body "no check line"
go nobind; ok 'refused && grep -qF "could not prove" <<<"$msg"' "no Check line, worker proof fails (nobind): refused"
body "Check: $C"
OTHER=someone-else go other; ok 'refused && grep -qF "is assigned to" <<<"$msg"' "another profile's card (Check: <cmd>): refused"
body "Check: none: decision card"
OTHER=someone-else go other; ok 'refused && grep -qF "is assigned to" <<<"$msg"' "another profile's card (Check: none): refused"
INPUT='{"task_id":"t_0000beef"}'; go wrongcard
ok 'refused && grep -qF "could not prove" <<<"$msg"' "task_id of another card (bound to another process): refused"
INPUT='{"task_id":"t_0000dead"}'; go
ok 'refused && grep -qF "could not prove" <<<"$msg"' "task_id of a card the board does not know: refused"
INPUT='{"task_id":["t_0000c0de"]}'; go; ok 'refused' "task_id a list: refused"
INPUT='{"task_id":" t_0000c0de"}'; go; ok 'refused' "task_id with a leading space: refused"
INPUT='{"summary":"done"}'; go; ok 'allowed' "no task_id, Check: none card: the profile's own running card is proven and read: allowed"
body "Check: $C"; go; ok 'refused && grep -qF "kanban_request_review" <<<"$msg"' "no task_id, Check: <cmd> card: refused (the proven own card is read)"
unset INPUT
HERMES_KANBAN_TASK=t_0000c0de HERMES_KANBAN_RUN_ID=7 go nobind
ok 'refused && grep -qF "could not prove" <<<"$msg"' "ids only in the environment, no run bound: refused (the environment proves nothing)"
body "Check: none: decision card"
HERMES_KANBAN_BOARD=other go; ok 'allowed' "HERMES_KANBAN_BOARD=other in the hook's environment: still proven on the stack's board, allowed"
PATH=/usr/bin:/bin go; ok 'refused && grep -qF "could not prove" <<<"$msg"' "kanban show unavailable: refused"
body "Check: $C"
go badbody; ok 'refused && grep -qF "internal error" <<<"$msg"' "a card body that is not text: refused as an internal error (fail closed)"
go nobody; ok 'allowed' "a card with no body field: no Check line, allowed by this hook"
# The builder's own metadata is not read by this rule: the right pair does not turn a command card into a completable one.
mdin "$NEED"; go; ok 'refused && grep -qF "kanban_request_review" <<<"$msg"' "a command card with the reviewing role's metadata pair: still refused"
reset

echo "# 3. Roles with neither field, and other tools: untouched"
for p in $DP $UP; do
  PROF=$p; body "Check: $C"; unset INPUT
  go nobind; ok 'allowed' "$([ "$p" = "$UP" ] && echo "a profile with no row (fallback role)" || echo "the role with neither field"): kanban_complete with a command card, no bound run, no metadata: allowed untouched"
  mdin '"x"'; go; ok 'allowed' "same role, metadata \"x\": allowed untouched"
done
PROF=$BP; body "Check: $C"; unset INPUT
for t in kanban_request_review kanban_comment kanban_block kanban_show terminal kanban_complete_x xkanban_complete kanban_completed KANBAN_COMPLETE "kanban_complete "; do
  TOOL=$t PROF=$BP go; ok 'allowed' "builder role, tool \"$t\", command card: allowed untouched"
  TOOL=$t PROF=$RP INPUT='{"task_id":"t_0000c0de"}' go; ok 'allowed' "reviewing role, tool \"$t\", no metadata: allowed untouched"
done
reset

echo "# 4. Failure modes: the call is refused"
for p in $BP $RP; do
  PROF=$p
  for ti in '"a string"' '[]' '["t_0000c0de"]' '7' 'null'; do
    INPUT=$ti; go
    ok 'refused && grep -qF "unreadable tool arguments" <<<"$msg"' "profile role $([ "$p" = "$BP" ] && echo "builder" || echo "reviewing"): tool_input $ti (not an object): refused"
  done
  unset INPUT
  RAW='not json'; go; ok 'refused && grep -qF "internal error" <<<"$msg"' "malformed stdin: refused"
  RAW=''; go; ok 'refused' "empty stdin: refused"
  RAW='[1]'; go; ok 'refused && grep -qF "internal error" <<<"$msg"' "stdin that is a list: refused (internal error path)"
  RAW=$(jq -nc --arg p "$p" '{tool_name: "kanban_complete", profile: $p}'); go; ok 'refused && grep -qF "unreadable tool arguments" <<<"$msg"' "no tool_input at all: refused"
  unset RAW
done
printf '{"profile": 1}' >"$T/short.json"
printf 'not json' >"$T/junk.json"
jq 'del(.roles)' "$RF" >"$T/noroles.json"
jq --arg r "$RR" '.roles[$r].complete_metadata = {}' "$RF" >"$T/emptymd.json"
jq --arg r "$BR" '.roles[$r].complete_needs_review = "yes"' "$RF" >"$T/strbool.json"
for p in $BP $RP; do
  for f in "$T/missing.json" "$T/junk.json" "$T/short.json" "$T/noroles.json" "$T/emptymd.json" "$T/strbool.json"; do
    : >"$AL"; PROF=$p ROLES_FILE=$f go
    ok 'refused && grep -qF "STL-CFG-303" <<<"$msg" && [ "$(grep -c STL-CFG-303 "$AL")" = 1 ]' "table ${f##*/} for $([ "$p" = "$BP" ] && echo "the builder" || echo "the reviewing") profile: refused, STL-CFG-303 in the message and one line in the alerts log"
  done
done
PROF=$RP; mdin "$NEED"; go; ok 'allowed' "control: the same call with the real table is allowed (the refusals above come from the table)"
reset

echo "# 5. Real path (D48): worker -> shell -> interpreter -> hook, no HERMES_KANBAN_* in the environment"
PROF=$BP; body "Check: $C"; go
ok 'refused && grep -qF "kanban_request_review" <<<"$msg" && [ -z "$(env | grep ^HERMES_KANBAN)" ]' "bound card, command Check, no ids in the environment: refused on the card read through the board"
body "Check: none: decision card"; go
ok 'allowed && [ -z "$(env | grep ^HERMES_KANBAN)" ]' "bound card, Check: none, no ids in the environment: allowed"
PROF=$RP; mdin "$NEED"; go; ok 'allowed' "reviewing profile, right metadata: allowed"
mdin "$(jq -nc --arg k "${K}_outcome" --arg v "$V" '{($k): $v}')"; go; ok 'refused && grep -qF "$NEEDTXT" <<<"$msg"' "reviewing profile, other key: refused"
reset

echo "# 6. Registration (table: $RF)"
msg=
ok '[ -z "$(jq -r ".roles | to_entries[] | select(((.value.complete_metadata != null) or (.value.complete_needs_review == true)) != ([.value.hooks[]? | select((.command // \"\") | endswith(\"/complete-gate.py\"))] | length == 1)) | .key" "$RF")" ]' "exactly the roles with complete_metadata or complete_needs_review list the hook once, no other role lists it"
ok '[ "$(jq "[.roles[][\"hooks\"][]? | select((.command // \"\") | endswith(\"/complete-gate.py\")) | .timeout | numbers | select(. > 0)] | length" "$RF")" = 2 ]' "both listings carry a timeout"
for r in $RR $BR; do
  M=$(jq -r --arg r "$r" '.roles[$r].hooks[] | select((.command // "") | endswith("/complete-gate.py")) | .matcher' "$RF")
  ok 'python3 -c "import re, sys; m = sys.argv[1]; sys.exit(not (re.fullmatch(m, \"kanban_complete\") and not any(re.fullmatch(m, t) for t in (\"kanban_complete_x\", \"xkanban_complete\", \"kanban_request_review\", \"kanban_comment\", \"kanban_block\", \"terminal\", \"\"))))" "$M"' "role $r: matcher $M fullmatches kanban_complete and no neighbouring tool"
done
ok '[ -x "$CG" ] && head -1 "$CG" | grep -q "^#!/usr/bin/env python3"' "the hook under test is executable with a python shebang (it is installed by mv)"
ok 'python3 -c "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], \"exec\")" "$CG"' "the hook compiles"
if [ -f "$S/roles.json" ]; then   # the staged table the install copies: it names the installed path
  ok '[ "$(jq -r "[.roles[][\"hooks\"][]? | select((.command // \"\") | endswith(\"/complete-gate.py\")) | .command] | unique | .[]" "$S/roles.json")" = /workspace/bin/complete-gate.py ]' "the table beside the hook lists the installed path /workspace/bin/complete-gate.py"
fi
msg=; : >"$AL"
ok 'python3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); import roles; roles.load()" "$S" && [ ! -s "$AL" ]' "roles.py under test loads the table (so the hook files it names exist)"

echo "# 7. Source drift and hard-coding"
# check-guard.py runs main() on import, so the sources are compared as syntax trees: CHECK, NONE and check_line must be the
# same code in both files (the docstring of check_line is prose and is not compared).
msg=
ok 'python3 -I - "$CG" /workspace/bin/check-guard.py <<PY
import ast, sys
def pick(p):
    out = {}
    for n in ast.parse(open(p).read()).body:
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name) and n.targets[0].id in ("CHECK", "NONE"):
            out[n.targets[0].id] = ast.dump(n)
        elif isinstance(n, ast.FunctionDef) and n.name == "check_line":
            if n.body and isinstance(n.body[0], ast.Expr) and isinstance(n.body[0].value, ast.Constant) and isinstance(n.body[0].value.value, str):
                n.body = n.body[1:]
            out[n.name] = ast.dump(n)
    return out
a, b = pick(sys.argv[1]), pick(sys.argv[2])
bad = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
if bad or set(a) != {"CHECK", "NONE", "check_line"}:
    print("drift or missing:", bad or sorted(a), file=sys.stderr); sys.exit(1)
PY' "CHECK, NONE and check_line in complete-gate.py are AST-identical to check-guard.py's (docstring aside)"
names=$(jq -r '(.profiles | to_entries[] | select(.value.dir != "") | .key), (.profiles[] | .display_name // empty)' "$RF" | sort -u | paste -sd'|')
# role-guard-selftest section 8 style: the whole file, Hermes API words in hardcode-allow.json removed first (fails closed on an empty scan).
ok 'src=$(python3 - "$CG" <<PY
import json, sys
allow = json.load(open("/workspace/docs/hermes-local/hardcode-allow.json"))["allow"]
t = open(sys.argv[1]).read()
for a in allow:
    if a["file"] == "bin/complete-gate.py":
        t = t.replace(a["text"], "")
print(t)
PY
) && [ -n "$src" ] && [ -n "$names" ] && ! grep -Eiwn "$names" <<<"$src"' "complete-gate.py (comments and docstring included) names no profile or display name (Hermes API words in hardcode-allow.json aside)"
# The code itself (string literals and identifiers; comments and the docstring are prose): no profile, display name, role name
# or complete_metadata key or value of the table.
rnames=$(jq -r '(.roles | keys[]), (.roles[].complete_metadata // {} | to_entries[] | .key, .value)' "$RF" | sort -u | paste -sd'|')
ok 'python3 -I - "$CG" "$names|$rnames" <<PY
import ast, io, re, sys, tokenize
src = open(sys.argv[1]).read()
docs = {n.body[0].value.lineno for n in ast.walk(ast.parse(src)) if isinstance(n, (ast.Module, ast.FunctionDef)) and n.body
        and isinstance(n.body[0], ast.Expr) and isinstance(n.body[0].value, ast.Constant) and isinstance(n.body[0].value.value, str)}
code = [t.string for t in tokenize.generate_tokens(io.StringIO(src).readline)
        if t.type in (tokenize.NAME, tokenize.STRING) and t.start[0] not in docs]
words = [w for w in sys.argv[2].split("|") if w]
hits = [(w, c) for c in code for w in words if re.search(r"(?<![A-Za-z0-9_-])" + re.escape(w) + r"(?![A-Za-z0-9_-])", c, re.I)]
if not code or not words or hits:
    print("hard-coded:", hits[:5] or "empty scan", file=sys.stderr); sys.exit(1)
PY' "complete-gate.py code (strings, identifiers) names no profile, display name, role name or complete_metadata key or value"
ok '! grep -Eiq "claude|opencode|qwen|llama|gpt|anthropic|openai|ollama|lmstudio|discord|localhost|127\.0\.0\.1|/home/[a-z]|/mnt/c" "$CG"' "complete-gate.py names no model, provider, host, channel or user path"

echo "complete-gate-selftest: $nok ok, $fails FAIL"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
