#!/usr/bin/env bash
# Hermetic self-test for K14: what a delegate_task child can and cannot do under each guard. Layer 1 imports Hermes's own
# modules with Hermes's interpreter (no stubs: they import without a gateway) and pins its fences. Layers 2-4 run the stack's
# real hooks below a fake Kanban worker bound to a running card on a stub board: the same call is made from the worker's main
# thread (the parent) and from a second thread of that same process (how an in-process child's tool call reaches its hook),
# and the verdicts must match. Commits run in a scratch repo under this run's temp root. The stub `hermes` refuses `send`;
# ESCALATE_SUP_DIR is this run's own folder: nothing reaches the live alerts.log or Discord. STACK=<tree> runs the guards of
# another tree (the negative control: .scratch/readiness-pre).
set -u
P=delegation-selftest
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "$P.*" -mmin +60 -exec rm -rf {} + 2>/dev/null
REAL_BEFORE=$(ls -A /workspace/.worktrees 2>/dev/null | sort)
T=$(mktemp -d -t "$P.XXXXXX"); STR=
trap '[ -n "$STR" ] && kill "$STR" 2>/dev/null; rm -rf "$T"' EXIT
LIVE_ALERTS=/workspace/.supervisor/logs/alerts.log; LIVE_SIZE=$(stat -c %s "$LIVE_ALERTS" 2>/dev/null || echo 0)
export ESCALATE_SUP_DIR=$T/sup; mkdir -p "$T/sup/logs" "$T/sup/state"
unset HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB HERMES_KANBAN_BOARD \
  HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT
STACK=${STACK:-/workspace}
WG=$STACK/docs/hermes-local/hooks/builder/write-guard.py; GG=$STACK/docs/hermes-local/hooks/builder/git-guard.py
CG=$STACK/bin/commit-guard.sh; RG=$STACK/bin/role-guard.py; RF=/workspace/docs/hermes-local/roles.json
HERMES_PY=${HERMES_PY:-$HOME/.hermes/tools/python-3.14.9+20261021-linux-x64/bin/python3}; HS=$HOME/.hermes/hermes-agent
# A missing runtime is a failure, not a skip (as matcher-audit-selftest.sh): after a Hermes upgrade this test must not go quiet.
[ -x "$HERMES_PY" ] && [ -f "$HS/tools/kanban_tools.py" ] && [ -f "$HS/hermes_cli/kanban.py" ] \
  || { echo "FAIL Hermes runtime not found ($HERMES_PY, $HS): update HERMES_PY here"; echo "selftest FAIL (1)"; exit 1; }
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }

# Layer 1: Hermes's real code, one process. It writes name=value lines to $T/h.env, which this shell reads back.
(cd "$T" && "$HERMES_PY" -I - "$T" "$T/h.env" 2>"$T/hermes.err") <<'PY'
import argparse, contextlib, io, os, sys
T, out = sys.argv[1], open(sys.argv[2], "w")
def put(name, val):
    out.write(f"{name}={val}\n")
for k in ("PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV", "HERMES_DELEGATED_CHILD_CONTEXT", "HERMES_KANBAN_TASK", "HERMES_KANBAN_HOME"):
    os.environ.pop(k, None)
sys.path.insert(0, os.path.join(os.path.expanduser("~"), ".hermes", "hermes-agent"))
sys._hermes_pin_default_home = True
import hermes_bootstrap  # noqa: F401  (Hermes's own sys.path)
import tools.kanban_tools as kt        # the kanban tools' visibility check (check_fn)
from agent import delegation_context as dc   # the fence, and the in-process child context
import hermes_cli.kanban as hk         # the CLI gate
import hermes_cli.kanban_db as kb      # the DB-level fence: the backstop for a child that imports the module itself
ns = lambda action: argparse.Namespace(kanban_action=action, boards_action=None)
def raises(f):
    try:
        f()
    except PermissionError:
        return True
    return False
put("H_outside_fenced", dc.kanban_path_is_fenced(T))
put("H_plain_env_no_marker", "HERMES_DELEGATED_CHILD_CONTEXT" not in dc.delegated_child_subprocess_env({"PATH": "/x"}))
with dc.delegated_child_context():
    put("H_child_env_marker", "HERMES_DELEGATED_CHILD_CONTEXT" in dc.delegated_child_subprocess_env({"PATH": "/x"}))
    put("H_child_env_no_task", "HERMES_KANBAN_TASK" not in dc.delegated_child_subprocess_env({"PATH": "/x", "HERMES_KANBAN_TASK": "t_00000001"}))
    put("H_child_fenced", dc.kanban_path_is_fenced(T))
    put("H_child_visible", kt._check_kanban_mode())
    put("H_child_orch_visible", kt._check_kanban_orchestrator_mode())
    put("H_child_db_refused", raises(lambda: kb._assert_not_delegated_child_mutation(T)))
    os.environ["HERMES_KANBAN_TASK"] = "t_00000001"
    put("H_child_visible_with_task", kt._check_kanban_mode())
    del os.environ["HERMES_KANBAN_TASK"]
os.environ["HERMES_KANBAN_TASK"] = "t_00000001"   # control: a dispatched worker outside a child sees its kanban tools
put("H_dispatcher_visible", kt._check_kanban_mode())
del os.environ["HERMES_KANBAN_TASK"]
put("H_outside_db_ok", not raises(lambda: kb._assert_not_delegated_child_mutation(T)))
os.environ["HERMES_DELEGATED_CHILD_CONTEXT"] = os.path.join(T, "root")   # the marker names the fenced board root
os.environ["HERMES_KANBAN_HOME"] = os.path.join(T, "root")               # a board under that root
for a in ("complete", "block", "unblock"):
    put(f"H_cli_{a}_gate", hk._is_delegated_child_cli_mutation(ns(a)))
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        rc = hk.kanban_command(ns(a))
    put(f"H_cli_{a}_rc", rc)
    put(f"H_cli_{a}_msg", "cannot mutate Kanban tasks via the CLI" in buf.getvalue())
put("H_cli_show_gate", hk._is_delegated_child_cli_mutation(ns("show")))      # control: a read is not refused
os.environ["HERMES_KANBAN_HOME"] = os.path.join(T, "other")                  # control: a board outside the root
put("H_cli_other_board_gate", hk._is_delegated_child_cli_mutation(ns("complete")))
out.close()
PY
. "$T/h.env" 2>/dev/null
ok '[ "${H_outside_fenced:-}" = False ]' "1 Hermes, real import: outside a child, kanban_path_is_fenced(a temp dir) is False with the marker unset"
ok '[ "${H_child_fenced:-}" = True ]' "1 Hermes: inside delegated_child_context(), kanban_path_is_fenced(the same dir) is True"
ok '[ "${H_child_env_marker:-}" = True ] && [ "${H_child_env_no_task:-}" = True ]' "1 Hermes: a child's hook environment carries HERMES_DELEGATED_CHILD_CONTEXT and no HERMES_KANBAN_TASK (what the stack's guards are handed)"
ok '[ "${H_plain_env_no_marker:-}" = True ]' "1 Hermes control: a plain process's hook environment has no marker"
ok '[ "${H_child_visible:-}" = False ]' "1 Hermes: inside a child, the kanban tools' visibility (_check_kanban_mode) is False: a child cannot see complete/block/unblock"
ok '[ "${H_child_orch_visible:-}" = False ]' "1 Hermes: inside a child, the board-routing tools' visibility (_check_kanban_orchestrator_mode) is False"
ok '[ "${H_child_visible_with_task:-}" = False ]' "1 Hermes: inside a child with HERMES_KANBAN_TASK set, the kanban tools stay hidden"
ok '[ "${H_dispatcher_visible:-}" = True ]' "1 Hermes control: outside a child, a dispatched worker (HERMES_KANBAN_TASK) sees its kanban tools"
ok '[ "${H_child_db_refused:-}" = True ]' "1 Hermes: inside a child, kanban_db's own fence raises PermissionError (a child that imports kanban_db directly is refused)"
ok '[ "${H_outside_db_ok:-}" = True ]' "1 Hermes control: outside a child the same kanban_db check does not raise"
for a in complete block unblock; do
  ok "[ \"\${H_cli_${a}_gate:-}\" = True ] && [ \"\${H_cli_${a}_rc:-}\" = 1 ] && [ \"\${H_cli_${a}_msg:-}\" = True ]" "1 Hermes CLI: hermes kanban $a is refused for a child, for a board under the marker's root (rc 1, the child message)"
done
ok '[ "${H_cli_show_gate:-}" = False ]' "1 Hermes control: a read (kanban show) is not refused by the CLI gate"
ok '[ "${H_cli_other_board_gate:-}" = False ]' "1 Hermes control: complete is not refused for a board outside the marker's root"

# Layers 2-4: the stack's hooks below a fake worker. The stub board answers for the stack's board only and refuses `send`.
mkdir -p "$T/bin" "$T/cards"
export PATH="$T/bin:$PATH" FAKE_CARDS=$T/cards
EXPECT_HOME=$(getent passwd "$(id -u)" | cut -d: -f6)/.hermes; export EXPECT_HOME
sleep 600 & STR=$!   # a live process that is no ancestor of any hook
cat >"$T/bin/hermes" <<'SH'
#!/usr/bin/env bash
# stub: refuses `send`; `kanban --board ai-stack show <id>` and `list [--assignee <p>] --status running` answer from the card
# files in $FAKE_CARDS. Anything else fails.
[ "${1:-}" = send ] && { echo "delegation-selftest: hermes send refused" >&2; exit 1; }
[ "$1" = kanban ] || exit 1
b=$3; shift 3
[ "$b" = ai-stack ] || { echo "board $b not found" >&2; exit 1; }
root=${HERMES_KANBAN_HOME:-${HERMES_HOME:-$EXPECT_HOME}}; [ "$root" = "$EXPECT_HOME" ] || { [ "$1" = list ] && echo "[]" && exit 0; exit 1; }
case "$1" in
  show) exec cat "$FAKE_CARDS/$(printf '%s' "$2" | tr -c 'A-Za-z0-9_' '_').json" ;;
  list) a=; [ "$2" = --assignee ] && a=$3
        cat "$FAKE_CARDS"/*.json 2>/dev/null | jq -sc --arg a "$a" '[.[] | select(.task.status == "running" and ($a == "" or .task.assignee == $a)) | {id: .task.id}]' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/hermes"
printf '%s\n' 'import subprocess, sys' 'sys.exit(subprocess.call(sys.argv[2:], stdin=open(sys.argv[1], "rb")))' >"$T/runner.py"
# worker.py <dir> <main|thread> <cmd...>: this process is the bound worker (its pid goes to <dir>/pid). It waits for <dir>/go,
# then runs <cmd> under a shell, from its main thread (a parent's tool call) or from a second thread (a child's tool call: the
# same process, another thread). Output to <dir>/out, exit code to <dir>/rc, the thread's kind to <dir>/where.
cat >"$T/worker.py" <<'PY'
import os, subprocess, sys, threading, time
d, mode, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(f"{d}/pid", "w") as f:
    f.write(str(os.getpid()))
while not os.path.exists(f"{d}/go"):
    time.sleep(0.02)
def run():
    with open(f"{d}/out", "wb") as out:
        rc = subprocess.call(["sh", "-c", '"$@"', "sh", *cmd], stdout=out, stderr=subprocess.STDOUT)
    with open(f"{d}/rc", "w") as f:
        f.write(str(rc))
    with open(f"{d}/where", "w") as f:
        f.write("main" if threading.current_thread() is threading.main_thread() else "thread")
if mode == "thread":
    th = threading.Thread(target=run); th.start(); th.join()
else:
    run()
PY
fp() { echo "$(cat /proc/sys/kernel/random/boot_id):$(sed 's/.*) //' /proc/1/stat | awk '{print $20}')|$(sed 's/.*) //' /proc/$1/stat | awk '{print $20}')"; }
mk() {  # mk <fixture> <card> <assignee> <workspace> <branch> <worker pid>: the card on the stub board, bound per the fixture:
  # bind = its own open run; stranger = bound to a process no hook descends from (the run is no child's either)
  local fx=$1 c=$2 a=$3 ws=$4 br=$5 wp=$6 pid sig="" lock=host:1
  case $fx in
    bind) pid=$wp; sig=$(fp "$wp") ;;
    stranger) pid=$STR; sig=$(fp "$STR") ;;
  esac
  jq -nc --arg id "$c" --arg a "$a" --arg ws "$ws" --arg br "$br" --argjson pid "$pid" --arg sig "$sig" --arg lock "$lock" \
    '{task: {id: $id, assignee: $a, status: "running", workspace_path: $ws, branch_name: $br},
      runs: [{id: 7, ended_at: null}],
      events: [{kind: "claimed", run_id: 7, payload: {lock: "host:1"}},
        {kind: "worker_bound", run_id: 7, payload: {pid: $pid, claim_lock: $lock, started_at: $sig}}]}' \
    >"$FAKE_CARDS/$(printf '%s' "$c" | tr -c 'A-Za-z0-9_' '_').json"
}
bound() {  # bound <main|thread> <fixture> <card> <assignee> <workspace> <branch> <payload> <cmd...>: runs <cmd> (@P stands for
  # the payload file) below a fake worker bound per <fixture>, from its main thread or a second thread. Prints the exit code;
  # the output is left in $T/out-<mode>, the thread kind in $T/where-<mode>.
  local m=$1 fx=$2 c=$3 a=$4 ws=$5 br=$6 pl=$7 d w x; shift 7; d=$(mktemp -d -p "$T"); local cmd=()
  printf '%s' "$pl" >"$d/payload"; rm -f "$FAKE_CARDS"/*.json
  for x; do cmd+=("${x//@P/"$d/payload"}"); done
  python3 "$T/worker.py" "$d" "$m" "${cmd[@]}" </dev/null & w=$!
  for _ in $(seq 200); do [ -s "$d/pid" ] && break; sleep 0.02; done
  mk "$fx" "$c" "$a" "$ws" "$br" "$(cat "$d/pid")"
  touch "$d/go"; wait "$w"
  cp -f "$d/out" "$T/out-$m" 2>/dev/null || : >"$T/out-$m"; cp -f "$d/where" "$T/where-$m" 2>/dev/null
  cat "$d/rc" 2>/dev/null || echo missing
}
# hook <mode> <script> <fixture> <profile> <payload json> [env...]: the hook's exit code. The payload is its stdin, as Hermes
# sends it; the hook runs two levels below the worker (a shell, then python3 runner.py) like a tool call's hook.
hook() {
  local m=$1 s=$2 fx=$3 pr=$4 pl=$5; shift 5
  bound "$m" "$fx" "$C" "$pr" "$OWN" "$BRA" "$pl" python3 "$T/runner.py" @P env "$@" python3 "$s"
}
# run_as <mode> <script> <payload json> [fixture]: a tool call of the card's own worker (card $C, assigned to $BP, workspace $OWN):
# the marker and the card workspace are set as Hermes sets them for a worker's hooks.
run_as() { hook "$1" "$2" "${4:-bind}" "$BP" "$3" "HERMES_KANBAN_WORKSPACE=$OWN" "HERMES_DELEGATED_CHILD_CONTEXT=$FENCE"; }
pair() { echo "$(run_as main "$@") $(run_as thread "$@")"; }   # "<the parent's exit code> <the child's exit code>"
wpl() {  # wpl <tool> <tool_input json> <cwd>: the payload Hermes sends a pre_tool_call hook
  jq -nc --arg t "$1" --argjson a "$2" --arg c "$3" --arg p "$BP" '{tool_name: $t, tool_input: $a, session_id: "s1", cwd: $c, profile: $p, extra: {}}'
}
wj() { jq -nc --arg p "$1" '{path: $p, content: "x"}'; }
tj() { jq -nc --arg c "$1" '{command: $c}'; }

BP=$(jq -r '.roles as $r | .profiles | to_entries[] | select($r[.value.role].workspace == "git-worktree") | .key' "$RF" | head -1)
[ -n "$BP" ] || { echo "FAIL no git-worktree profile in roles.json"; echo "selftest FAIL (1)"; exit 1; }
C=t_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n'); OWN=/workspace/.worktrees/$C; BRA=stella/$C-x
FENCE=$T/fenced   # the marker Hermes puts in every process a worker spawns (scrub_kanban_env): the fenced board root

# Layer 2: write guard and git guard, the same call from the parent and from the child.
J=$(wpl write_file "$(wj "$OWN/a.md")" "$OWN")
P=$(pair "$WG" "$J" ); ok '[ "$P" = "0 0" ]' "2 write_file in its own worktree (the card's own /workspace/.worktrees/<card>): allowed for the parent and for the child"
J=$(wpl write_file "$(wj /workspace/decisions.md)" "$OWN")
P=$(pair "$WG" "$J" ); ok '[ "$P" = "2 2" ] && grep -qF "builders write only inside their own worktree" "$T/out-main" && cmp -s "$T/out-main" "$T/out-thread"' "2 write_file on the main checkout (decisions.md): refused for the parent and the child, identical message"
J=$(wpl write_file "$(wj /workspace/.worktrees/t_0000beef/a.md)" "$OWN")
P=$(pair "$WG" "$J"); ok '[ "$P" = "2 2" ]' "2 write_file into another card's worktree: refused for the parent and the child"
J=$(wpl terminal "$(tj 'echo x > /workspace/bin/y')" "$OWN")
P=$(pair "$WG" "$J"); ok '[ "$P" = "2 2" ]' "2 terminal redirect into /workspace/bin: refused for the parent and the child"
J=$(wpl terminal "$(tj 'hermes kanban --board ai-stack complete t_0000beef')" "$OWN")
P=$(pair "$WG" "$J"); ok '[ "$P" = "2 2" ] && grep -qF "kanban" "$T/out-thread"' "2 terminal hermes kanban complete: refused for the parent and the child (the board changes through the kanban tools, which a child does not have)"
J=$(wpl terminal "$(tj 'unset HERMES_DELEGATED_CHILD_CONTEXT')" "$OWN")
P=$(pair "$WG" "$J"); ok '[ "$P" = "2 2" ] && grep -qF "HERMES_DELEGATED_CHILD_CONTEXT" "$T/out-thread"' "2 terminal unset of HERMES_DELEGATED_CHILD_CONTEXT: refused for the parent and the child"
J=$(wpl terminal "$(tj "echo x > $OWN/a.md")" "$OWN")
P=$(pair "$WG" "$J"); ok '[ "$P" = "0 0" ]' "2 terminal redirect into its own worktree: allowed for the parent and the child"
J=$(wpl write_file "$(wj "$OWN/a.md")" "$OWN")
P=$(run_as thread "$WG" "$J" stranger); ok '[ "$P" = 2 ] && grep -qF "is not an ancestor of this call" "$T/out-thread"' "2 control: the child's write when its card is bound to no ancestor: refused (the proof decides, not the thread)"
J=$(wpl terminal "$(tj 'python3 -c "import hermes_cli.kanban_db"')" "$OWN")
P=$(pair "$WG" "$J"); ok '[ "$P" = "0 0" ]' "2 documented limit (D42, K14): an interpreter that imports kanban_db is not a command the write guard parses, so it is allowed for both; kanban_db's fence refuses it (layer 1)"
ok '[ "$(cat "$T/where-thread")" = thread ] && [ "$(cat "$T/where-main")" = main ]' "2 the child's hooks ran from a second thread of the worker, the parent's from its main thread"
J=$(wpl terminal "$(tj 'git push origin HEAD:main')" "$OWN")
P=$(pair "$GG" "$J"); ok '[ "$P" = "2 2" ]' "2 git guard: git push to main refused for the parent and the child"
J=$(wpl terminal "$(tj 'git add -A')" "$OWN")
P=$(pair "$GG" "$J"); ok '[ "$P" = "2 2" ]' "2 git guard: git add -A refused for the parent and the child"
J=$(wpl terminal "$(tj 'git commit --no-verify -m x')" "$OWN")
P=$(pair "$GG" "$J"); ok '[ "$P" = "2 2" ]' "2 git guard: git commit --no-verify refused for the parent and the child"
J=$(wpl terminal "$(tj 'git status')" "$OWN")
P=$(pair "$GG" "$J"); ok '[ "$P" = "0 0" ]' "2 git guard: git status (a read) allowed for the parent and the child"

# Layer 3: the pre-commit guard on a commit made from the parent's thread and from the child's, in a scratch repo.
export GIT_AUTHOR_NAME=worker GIT_AUTHOR_EMAIL=worker@example.invalid GIT_COMMITTER_NAME=worker GIT_COMMITTER_EMAIL=worker@example.invalid
K=$T/k14; WA=$K/wa
git init -q -b main "$K/main" && (cd "$K/main" && echo a >a && git add a && git commit -q -m init) \
  && git -C "$K/main" worktree add -q -b "$BRA" "$WA" && ln -s "$CG" "$K/main/.git/hooks/pre-commit"
ok '[ "$(git -C "$WA" branch --show-current)" = "$BRA" ] && [ "$(git -C "$K/main" branch --show-current)" = main ]' "3 scratch repo: the card worktree on its card branch, beside a main checkout, both under this run's temp root"
# gc <mode> <fixture> <dir> <file>: `git add` and `git commit` of <file> in <dir> as a tool call of the card's worker, marker set.
gc() {
  bound "$1" "$2" "$C" "$BP" "$WA" "$BRA" '{}' env "HERMES_DELEGATED_CHILD_CONTEXT=$FENCE" \
    sh -c 'cd "$1" && echo x >"$2" && git add -- "$2" && git commit -q -m "$2"' sh "$3" "$4"
}
N0=$(git -C "$WA" rev-list --count HEAD)
G1=$(gc main bind "$WA" p1.txt); G2=$(gc thread bind "$WA" c1.txt)
ok '[ "$G1" = 0 ] && [ "$G2" = 0 ] && [ "$(git -C "$WA" rev-list --count HEAD)" = $((N0+2)) ]' "3 a commit in the card worktree on its card branch: allowed for the parent and for the child"
H0=$(git -C "$K/main" rev-parse HEAD)
G3=$(gc main bind "$K/main" m1.txt); G4=$(gc thread bind "$K/main" m2.txt)
ok '[ "$G3" = 1 ] && [ "$G4" = 1 ] && grep -qF "worker commit on main refused" "$T/out-main" && grep -qF "worker commit on main refused" "$T/out-thread" && [ "$(git -C "$K/main" rev-parse HEAD)" = "$H0" ]' "3 a commit on main: refused for the parent and the child, main unchanged"
git -C "$K/main" reset -q --hard && git -C "$K/main" clean -qf
G5=$(gc thread stranger "$WA" s1.txt)
ok '[ "$G5" = 1 ] && grep -qF "cannot be proven" "$T/out-thread" && [ "$(git -C "$WA" rev-list --count HEAD)" = $((N0+2)) ]' "3 control: a child's commit when its card is bound to no ancestor, marker set: refused (cannot be proven), no commit made"
git -C "$WA" reset -q --hard && git -C "$WA" clean -qf

# Layer 4: the role guard on the child's kanban_complete. Hermes hides the kanban tools from children (layer 1), so the stack's
# proof is only asked about the worker's own run; the same ancestry passes it.
RJ=$(jq -nc --arg p "$BP" --arg c "$C" '{hook_event_name: "pre_tool_call", tool_name: "kanban_complete", tool_input: {task_id: $c}, profile: $p, extra: {}}')
P=$(run_as main "$RG" "$RJ"); CH=$(run_as thread "$RG" "$RJ")
ok '[ "$P" = 0 ] && [ "$CH" = 0 ]' "4 documented fact, relies on Hermes's layer (1): kanban tools are hidden from children, so kanban_complete under the same ancestry passes the stack's proof, for the parent and the child"
CH=$(run_as thread "$RG" "$RJ" stranger)
ok '[ "$CH" = 2 ] && grep -qF "STL-GRD-601" "$T/out-thread"' "4 control: the same kanban_complete from a child whose card is bound to no ancestor: refused (STL-GRD-601)"

# The refusals above log to this run's own alerts.log; the live one is untouched and the real worktrees gained nothing.
ok '[ "$(grep -cF "$C" "$T/sup/logs/alerts.log" 2>/dev/null)" -ge 1 ]' "the stranger refusals logged to this run's own alerts.log"
ok '! tail -c +$((LIVE_SIZE + 1)) "$LIVE_ALERTS" 2>/dev/null | grep -qF "$C"' "no alerts.log line naming this run's card reached the live alerts.log"
ok '[ "$(ls -A /workspace/.worktrees 2>/dev/null | sort)" = "$REAL_BEFORE" ]' "the real /workspace/.worktrees gained no entries during the run"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
