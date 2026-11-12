#!/usr/bin/env bash
# Hermetic self-test for docs/hermes-local/hooks/builder/write-guard.py (D40): synthetic payloads, a scratch worktree
# under /workspace/.scratch (gitignored), no network, nothing written outside the scratch dirs.
set -u
# The scratch worktree is a card's own workspace outside /workspace (HERMES_KANBAN_WORKSPACE, as a kanban scratch
# workspace is), under this run's temp root: never in the real /workspace/.worktrees (D46: a force-killed run, which skips
# the EXIT trap, left 67 folders there). A startup sweep removes this test's own temp roots older than an hour.
P=write-guard-selftest
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "$P.*" -mmin +60 -exec rm -rf {} + 2>/dev/null
REAL_BEFORE=$(ls -A /workspace/.worktrees 2>/dev/null | sort)
T=$(mktemp -d -t "$P.XXXXXX"); trap 'rm -rf "$T"' EXIT
# K2: the guard logs STL-GRD-603 through roles.log_alert; every case logs into this test's own folder, never the live log.
LIVE_ALERTS=/workspace/.supervisor/logs/alerts.log; LIVE_SIZE=$(stat -c %s "$LIVE_ALERTS" 2>/dev/null || echo 0)
export ESCALATE_SUP_DIR=$T/sup; mkdir -p "$T/sup/logs" "$T/sup/state"
C=t_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n'); W=$T/wt/$C; mkdir -p "$W"
ln -s /workspace/config "$W/link"
G=${WG:-/workspace/docs/hermes-local/hooks/builder/write-guard.py}
fails=0
ok() { local REAL=; case $1 in *'$WGA'*|*'$AL'*|*FAKE_LOG*) REAL=1 ;; esac   # T1 (r5): a case that reads the alert log or the board calls runs its hooks as real processes
  if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
unset HERMES_KANBAN_WORKSPACE HERMES_KANBAN_TASK
# K1: the card is proven by its own worker process, never by HERMES_KANBAN_* (Hermes sets them after the worker starts and
# strips them from hooks). A fake worker, bound to a running card on a stub board (`hermes` first on PATH), runs the hook
# three levels below itself: worker -> sh -> python3 runner -> hook, as a worker's tool call does.
export PATH="$T/bin:$PATH" FAKE_CARDS=$T/cards FAKE_LOG=$T/hermes.log
EXPECT_HOME=$(getent passwd "$(id -u)" | cut -d: -f6)/.hermes; export EXPECT_HOME
mkdir -p "$T/bin" "$FAKE_CARDS"
sleep 600 & STR=$!   # a live process that is no ancestor of any hook
trap 'kill $STR $(cat "$T"/bj/*/jpid 2>/dev/null) 2>/dev/null; rm -rf "$T" ${NR:+"$NR"} ${NR2:+"$NR2"} ${LN:+"$LN"}' EXIT   # NR, NR2, LN: the S3A-01 rows build folders under /workspace/.scratch, outside $T
cat >"$T/bin/hermes" <<'SH'
#!/usr/bin/env bash
# stub: `kanban --board <b> show <id> --json` and `kanban --board <b> list [--assignee <p>] --status running --json`, from
# the card files in $FAKE_CARDS; FAKE_LOG, when set, records each call. Anything else fails.
[ "$1" = kanban ] || exit 1
b=$3; shift 3
[ "$b" = ai-stack ] || { echo "board $b not found" >&2; exit 1; }
# a caller's HERMES_KANBAN_HOME / HERMES_HOME names another board database: it holds none of the stack's cards
root=${HERMES_KANBAN_HOME:-${HERMES_HOME:-$EXPECT_HOME}}; [ "$root" = "$EXPECT_HOME" ] || { [ "$1" = list ] && echo "[]" && exit 0; exit 1; }
[ -n "${FAKE_LOG:-}" ] && echo "$*" >>"$FAKE_LOG"
case "$1" in
  show) exec cat "$FAKE_CARDS/$(printf '%s' "$2" | tr -c 'A-Za-z0-9_' '_').json" ;;
  list) a=; [ "$2" = --assignee ] && a=$3
        cat "$FAKE_CARDS"/*.json 2>/dev/null | jq -sc --arg a "$a" '[.[] | select(.task.status == "running" and ($a == "" or .task.assignee == $a)) | {id: .task.id}]' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/hermes"
printf '%s\n' 'import subprocess, sys' 'sys.exit(subprocess.call(sys.argv[2:], stdin=open(sys.argv[1], "rb")))' >"$T/runner.py"
cat >"$T/worker.sh" <<'SH'
#!/usr/bin/env bash
# worker.sh <dir> <runner> <cmd...>: records its pid, waits for <dir>/go, runs <cmd> with <dir>/payload as stdin, two levels
# below itself (a shell, then python3 <runner>); output to <dir>/out, exit code to <dir>/rc.
d=$1 r=$2; shift 2; echo $$ >"$d/pid"
until [ -f "$d/go" ]; do sleep 0.02; done
sh -c 'python3 "$@"; exit $?' sh "$r" "$d/payload" "$@" >"$d/out" 2>&1; echo $? >"$d/rc"
SH
fp() { echo "$(cat /proc/sys/kernel/random/boot_id):$(sed 's/.*) //' /proc/1/stat | awk '{print $20}')|$(sed 's/.*) //' /proc/$1/stat | awk '{print $20}')"; }
mk() {  # mk <fixture> <card> <assignee> <workspace> <branch> <worker pid>: the card on the stub board, bound per the fixture:
  # bind = its own open run; nobind = no worker_bound event; stranger = bound to a process no hook descends from; stale =
  # the worker's pid with another start time; lock = another claim lock; closed = its run ended
  local fx=$1 c=$2 a=$3 ws=$4 br=$5 wp=$6 pid sig="" lock=host:1 ended=null
  case $fx in
    bind) pid=$wp; sig=$(fp "$wp") ;;
    nobind) pid=0 ;;
    stranger) pid=$STR; sig=$(fp "$STR") ;;
    stale) pid=$wp; sig=$(fp "$STR") ;;
    lock) pid=$wp; sig=$(fp "$wp"); lock=host:2 ;;
    closed) pid=$wp; sig=$(fp "$wp"); ended=1 ;;
  esac
  jq -nc --arg id "$c" --arg a "$a" --arg ws "$ws" --arg br "$br" --argjson pid "$pid" --arg sig "$sig" --arg lock "$lock" \
    --argjson ended "$ended" '{task: {id: $id, assignee: $a, status: "running", workspace_path: $ws, branch_name: $br},
      runs: [{id: 7, ended_at: $ended}],
      events: (if $pid == 0 then [] else [{kind: "claimed", run_id: 7, payload: {lock: "host:1"}},
        {kind: "worker_bound", run_id: 7, payload: {pid: $pid, claim_lock: $lock, started_at: $sig}}] end)}' >"$FAKE_CARDS/$(printf '%s' "$c" | tr -c 'A-Za-z0-9_' '_').json"
}
bound() {  # bound <fixture> <card> <assignee> <workspace> <branch> <payload> -- <cmd...>: <cmd> run by a fake worker bound per
  # the fixture; its exit code is printed, its output left in $T/out. The card is on the board before the worker is released.
  local fx=$1 c=$2 a=$3 ws=$4 br=$5 pl=$6 d w; shift 7; d=$(mktemp -d -p "$T")
  printf '%s' "$pl" >"$d/payload"; rm -f "$FAKE_CARDS"/*.json
  bash "$T/worker.sh" "$d" "$T/runner.py" "$@" </dev/null & w=$!
  for _ in $(seq 200); do [ -s "$d/pid" ] && break; sleep 0.02; done
  [ "$fx" = none ] || mk "$fx" "$c" "$a" "$ws" "$br" "$(cat "$d/pid")"
  touch "$d/go"; wait "$w"; cp "$d/out" "$T/out"; cat "$d/rc"; }
hookrun() {  # hookrun <fixture> <card> <profile> <workspace> <tool> <tool_input json> <cwd> [env...]: the guard's exit code, as run
  # by a worker bound per <fixture> to <card>, assigned to ${ASG:-<profile>}; the payload names <profile>
  local fx=$1 c=$2 pr=$3 ws=$4 tool=$5 in=$6 cwd=$7 pay; shift 7
  pay=$(jq -nc --arg t "$tool" --argjson a "$in" --arg c "$cwd" --arg p "$pr" '{tool_name: $t, tool_input: $a, session_id: "s1", cwd: $c, profile: $p, extra: {}}')
  if [ "$fx" = bind ] && [ -z "${REAL:-}" ]; then bjrun "$c" "${ASG:-$pr}" "$ws" "stella/$c-x" "$pay" "$pr|$tool" "$@"; return; fi
  bound "$fx" "$c" "${ASG:-$pr}" "$ws" "stella/$c-x" "$pay" -- env "$@" python3 "$G"; }
# T1 (F1 W4 r5): a bound row (fixture bind, no alert or board-call assertion) is judged by a judge that runs AS the bound worker's child, one per
# (card, assignee, workspace, branch): the card proof is the real one (the process tree, the stub board), and the hook's whole script runs in it with
# the row's environment, folder and payload, its exit code and printed output as a process gives them. The first row of each (profile, tool,
# exit code) class also runs through bound() as a real hook process, and both must agree. The other fixtures (the proof failing) stay processes.
cat >"$T/bjudge.py" <<'PY'
import base64, io, json, os, sys, traceback
inp, outp = sys.argv[1:3]; codes = {}; open(os.path.join(os.path.dirname(inp), "jpid"), "w").write(str(os.getpid())); keep = (sys.stdout, sys.stderr, sys.stdin, sys.argv, dict(os.environ), os.getcwd())
while True:
    with open(inp, encoding="utf-8") as f:
        line = f.readline()
    if not line.strip() or line.strip() == "QUIT":
        break
    r = json.loads(line); g = r["hook"]
    if g not in codes:
        codes[g] = compile(open(g, encoding="utf-8").read(), g, "exec")
    for m in [m for m in sys.modules if m in ("roles", "alert_catalog")]:
        del sys.modules[m]   # as a fresh process: the stack modules read their environment when imported
    os.environ.clear(); os.environ.update(r["env"]); os.chdir(r["cwd"])
    out = io.StringIO(); sys.stdout = sys.stderr = out; sys.stdin = io.StringIO(r["payload"]); sys.argv = [g]
    try:
        exec(codes[g], {"__name__": "__main__", "__file__": g}); rc = 0
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else 0 if e.code is None else 1
        if isinstance(e.code, str):
            print(e.code, file=out)
    except BaseException:
        traceback.print_exc(file=out); rc = 1
    finally:
        sys.stdout, sys.stderr, sys.stdin, sys.argv = keep[:4]; os.environ.clear(); os.environ.update(keep[4]); os.chdir(keep[5])
    with open(outp, "w", encoding="utf-8") as f:
        f.write(f"{rc}\t{base64.b64encode(out.getvalue().encode()).decode()}\n")
PY
: >"$T/bjseen"; : >"$T/bjrows"
bjrun() {   # bjrun <card> <assignee> <workspace> <branch> <payload> <class> [env...]: exit code echoed, output in $T/out
  local c=$1 a=$2 ws=$3 br=$4 pay=$5 cls=$6 d rc b req; shift 6
  d=$T/bj/$(printf '%s' "$c|$a|$ws|$br" | md5sum | cut -c1-16)
  if [ ! -s "$d/card.json" ]; then   # a judge for this binding: a fake worker that runs it, the card bound to that worker
    mkdir -p "$d"; mkfifo "$d/in" "$d/oq"; : >"$d/payload"; rm -f "$FAKE_CARDS"/*.json
    bash "$T/worker.sh" "$d" "$T/runner.py" python3 -I "$T/bjudge.py" "$d/in" "$d/oq" </dev/null >/dev/null 2>&1 &
    for _ in $(seq 200); do [ -s "$d/pid" ] && break; sleep 0.02; done
    mk bind "$c" "$a" "$ws" "$br" "$(cat "$d/pid")"; cp "$FAKE_CARDS"/*.json "$d/card.json"; echo "$d" >>"$T/bjdirs"; touch "$d/go"
  fi
  rm -f "$FAKE_CARDS"/*.json; cp "$d/card.json" "$FAKE_CARDS/$(printf '%s' "$c" | tr -c 'A-Za-z0-9_' '_').json"
  req=$(env -0 "$@" | jq -Rsc --arg p "$pay" --arg h "$G" --arg w "$PWD" '{hook: $h, payload: $p, cwd: $w, env: (split("\u0000") | map(select(length > 0) | capture("^(?<key>[^=]*)=(?<value>.*)$"; "s")) | from_entries)}')
  printf '%s\n' "$req" >"$d/in"; IFS=$'\t' read -r rc b <"$d/oq"; printf '%s' "$b" | base64 -d >"$T/out"
  [ -n "${NOCLS:-}" ] || printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$a" "$ws" "$br" "$(printf '%s' "$pay" | base64 -w0)" "$(printf '%s\0' "$@" | base64 -w0)" >>"$T/bjrows"
  if [ -z "${NOCLS:-}" ] && ! grep -qxF -- "$cls|$rc" "$T/bjseen"; then
    echo "$cls|$rc" >>"$T/bjseen"; cp "$T/out" "$T/out.judge"
    local rrc; rrc=$(bound bind "$c" "$a" "$ws" "$br" "$pay" -- env "$@" python3 "$G")
    if [ "$rrc" != "$rc" ] || [ "$(sort "$T/out")" != "$(sort "$T/out.judge")" ]; then echo "     route agreement: $cls exit $rc in the judge, $rrc as a process" >&2; echo 99; return; fi
    cp "$T/out.judge" "$T/out"
  fi
  echo "$rc"; }
bjstop() { local d; [ -s "$T/bjdirs" ] || return 0; while read -r d; do printf 'QUIT\n' >"$d/in"; done <"$T/bjdirs"; : >"$T/bjdirs"; }
wjson() { jq -nc --arg p "$1" '{path: $p, content: "x"}'; }
tjson() { jq -nc --arg c "$1" '{command: $c}'; }
# run <tool> <tool_input json> [cwd]: the guard's exit code; its message in $T/out. The card is ${CARD-$C} (none when CARD is
# empty) and its recorded workspace ${WS-$W}; HERMES_KANBAN_WORKSPACE is set to the same value, as Hermes keeps it. No
# HERMES_KANBAN_TASK: Hermes strips it from the hook, so the card comes from the worker's process tree only.
run() { local c=${CARD-$C} fx=bind; [ -n "$c" ] || fx=none
  hookrun "$fx" "$c" builder-local "${WS-$W}" "$1" "$2" "${3:-$W}" "HERMES_KANBAN_WORKSPACE=${WS-$W}"; }
wf() { run write_file "$(jq -nc --arg p "$1" '{path: $p, content: "x"}')" "${2:-$W}"; }
sh() { run terminal "$(jq -nc --arg c "$1" '{command: $c}')" "${2:-$W}"; }
said() { grep -q -- "$1" "$T/out"; }

ok '[ "$(wf "$W/a.md")" = 0 ] && [ "$(wf sub/b.md)" = 0 ]' "write_file inside the own worktree (absolute and relative): allowed"
ok '[ "$(wf /workspace/config/owner.env)" = 2 ] && said "only inside their own worktree"' "write_file /workspace/config/owner.env: refused, says to write in the worktree"
ok '[ "$(wf /workspace/bin/x)" = 2 ]' "write_file /workspace/bin/x: refused"
ok '[ "$(wf /workspace/.worktrees/t_00000000/a.md)" = 2 ]' "write_file into another card's worktree: refused"
ok '[ "$(wf /workspace/new.md)" = 2 ]' "write_file in the main checkout root: refused"
ok '[ "$(wf /tmp/x)" = 0 ]' "write_file /tmp/x: allowed"
ok '[ "$(wf ../../config/owner.env /workspace/.worktrees/$C)" = 2 ]' "../../config/owner.env from a worktree cwd: refused"
ok '[ "$(wf link/owner.env)" = 2 ]' "a symlink in the worktree pointing at /workspace/config: refused"
ok '[ "$(run patch "$(jq -nc --arg p "$W/a.md" '"'"'{path: $p, old_string: "a", new_string: "b"}'"'"')")" = 0 ] && [ "$(run patch '"'"'{"path": "/workspace/SUPERVISOR.md", "old_string": "a", "new_string": "b"}'"'"')" = 2 ]' "patch: inside the worktree allowed, SUPERVISOR.md refused"
ok '[ "$(run patch '"'"'{"mode": "patch", "patch": "*** Begin Patch\n*** Update File: /workspace/decisions.md\n@@\n-a\n+b\n*** End Patch"}'"'"')" = 2 ]' "a V4A patch naming a main-checkout file: refused"
ok '[ "$(WS= CARD= wf /workspace/x.md)" = 2 ] && said "no card worktree known" && [ "$(WS= CARD= wf /tmp/x)" = 0 ]' "no worktree known: /workspace refused, /tmp allowed"
# F8: the card workspace counts only when it is /workspace/.worktrees/<this card> or outside /workspace.
ok '[ "$(WS=/workspace wf /workspace/bin/new.sh)" = 2 ] && said "no card worktree known" && said "is not this card" && [ "$(WS=/workspace wf /workspace/SUPERVISOR.md)" = 2 ]' "workspace /workspace: bin/new.sh and SUPERVISOR.md refused"
ok '[ "$(WS=/workspace/.worktrees/t_00000000 wf /workspace/.worktrees/t_00000000/x)" = 2 ] && [ "$(WS=/workspace/.worktrees wf /workspace/.worktrees/x)" = 2 ] && [ "$(WS=/workspace/docs wf /workspace/docs/x.md)" = 2 ]' "another card's worktree, the worktrees root, or a protected folder as workspace: refused"
ok '[ "$(WS=/workspace/.worktrees/t_00000000 wf "/workspace/.worktrees/$C/a.md")" = 2 ]' "a foreign workspace never falls back to the card id"
ok '[ "$(WS=/ wf /workspace/bin/x)" = 2 ] && [ "$(WS=/ wf /tmp/x)" = 0 ]' "review L1: a workspace that contains /workspace (/) is not a worktree"
ok '[ "$(WS="$T" wf "$T/a.md")" = 0 ] && [ "$(WS="$T" wf /workspace/a.md)" = 2 ] && [ "$(WS="$T" CARD= wf "$T/b.md")" = 0 ]' "workspace outside /workspace: writes there allowed, /workspace refused"
# Live hook env: Hermes strips HERMES_KANBAN_TASK from every subprocess a worker spawns, hooks included (scrub_kanban_env),
# and keeps HERMES_KANBAN_WORKSPACE. The card is the worker's own, proven from its process tree (its hook is the worker's
# descendant), with no id in the hook's environment; the bound card's worktree is the one that counts.
jq -nc --arg p "/workspace/.worktrees/$C/a.md" '{tool_name: "write_file", tool_input: {path: $p, content: "x"}, cwd: "/tmp", profile: "builder-local", extra: {task_id: "sandbox-1"}}' > "$T/p.json"
viaparent() { hookrun bind "$1" builder-local "/workspace/.worktrees/$1" write_file "$(jq -c .tool_input "$T/p.json")" /tmp; }
ok '[ "$(viaparent "$C")" = 0 ] && [ "$(viaparent t_00000000)" = 2 ]' "card id from the worker process when the hook env lacks it: own worktree allowed, a mismatch refused"
ok '[ "$(hookrun bind t_0000000a builder-local /workspace/.worktrees/t_0000000a write_file "$(wjson /workspace/.worktrees/t_0000000a/a.md)" /tmp)" = 0 ]' "worktree from the bound card when HERMES_KANBAN_WORKSPACE is unset"

ok '[ "$(sh "cat config/owner.env" /workspace)" = 2 ] && said "may not mention owner.env"' "cat config/owner.env: refused (mentions it)"
ok '[ "$(sh "echo hi > /tmp/x")" = 0 ]' "echo hi > /tmp/x: allowed"
ok '[ "$(sh "sed -i s/a/b/ file")" = 0 ]' "sed -i inside the worktree: allowed"
ok '[ "$(sh "sed -i s/a/b/ /workspace/docs/recovery.md")" = 2 ] && [ "$(sh "sed -n 1p /workspace/docs/recovery.md")" = 0 ]' "sed -i on docs/ refused; sed -n (a read) allowed"
ok '[ "$(sh "chmod u+w /workspace/config/owner.env")" = 2 ] && [ "$(sh "chmod u+w /workspace/config")" = 2 ]' "chmod u+w on config/ or owner.env: refused"
ok '[ "$(sh "bash -c '"'"'echo x >> /workspace/config/owner.env'"'"'")" = 2 ] && [ "$(sh "bash -c '"'"'echo x > /workspace/bin/y'"'"'")" = 2 ]' "bash -c with a nested redirect into config/ or bin/: refused"
ok '[ "$(sh "cd /workspace/bin && rm x")" = 2 ] && [ "$(sh "rm bin/x" /workspace)" = 2 ] && [ "$(sh "rm bin/x")" = 0 ]' "rm resolved against cd and cwd: main bin/ refused, the worktree's own bin/ allowed"
ok '[ "$(run terminal '"'"'{"command": "rm x", "workdir": "/workspace/.supervisor"}'"'"')" = 2 ]' "workdir is used to resolve targets"
ok '[ "$(sh "cp /workspace/bin/x /tmp/")" = 0 ] && [ "$(sh "cp a /workspace/bin/")" = 2 ] && [ "$(sh "sudo tee /workspace/decisions.md")" = 2 ]' "cp from bin/ (a read) allowed; cp into bin/ and sudo tee refused"
ok '[ "$(sh "git status && git commit -m \"Add a\"")" = 0 ] && [ "$(sh "npm test")" = 0 ] && [ "$(sh "cd $W && opencode run --standalone --auto '"'"'create a.md'"'"'")" = 0 ]' "git commit, npm test and opencode run in the worktree: allowed"
ok '[ "$(sh "ls /workspace/bin && cat /workspace/SUPERVISOR.md 2>/dev/null")" = 0 ]' "reads of protected paths (and a 2>/dev/null) are allowed"
ok '[ "$(run process_manage '"'"'{"action": "write", "session_id": "p1", "data": "echo x > /workspace/bin/y\n"}'"'"')" = 2 ] && [ "$(run process_manage '"'"'{"action": "poll", "session_id": "p1"}'"'"')" = 0 ]' "process_manage: stdin writing into bin/ refused, poll allowed"
ok '[ "$(sh "touch /workspace/bin/x")" = 0 ]' "touch is not in D40's write-command list (documented limit)"
ok '[ "$(sh "opencode run --standalone --auto \"don'"'"'t touch other files\"")" = 0 ] && [ "$(sh "cat > notes.md <<EOF
it'"'"'s fine
EOF")" = 0 ]' "replay regressions: an apostrophe in an instruction or a heredoc (shlex cannot parse it) is allowed in the worktree"
ok '[ "$(sh "echo don'"'"'t > /workspace/bin/x")" = 2 ]' "an unparseable command is still scanned word by word: a redirect into bin/ is refused"
# RT22-01: a # inside a word is not a comment in bash, so what follows `;` still runs: the write guard must still see it.
ok '[ "$(sh "echo x#; echo y > /workspace/bin/y")" = 2 ] && [ "$(sh "echo x#y && rm /workspace/bin/x")" = 2 ]' "RT22-01: a write into bin/ after a # inside a word: refused"
ok '[ "$(sh "echo x#; sed -i s/a/b/ /workspace/docs/recovery.md")" = 2 ]' "RT22-01: sed -i on docs/ after a # inside a word: refused"
ok '[ "$(sh "echo x#y")" = 0 ] && [ "$(sh "echo a#b > /tmp/x")" = 0 ] && [ "$(sh "echo x#; echo y > $W/z")" = 0 ]' "RT22-01: a # inside a word in a harmless command, and a write into the own worktree after one: allowed"
ok '[ "$(sh "ls # note")" = 0 ] && [ "$(sh "ls # note > /tmp/x")" = 0 ]' "RT22-01: a real comment (also one that contains a redirect into /tmp) stays allowed"
ok '[ "$(sh "ls # note; echo y > /workspace/bin/y")" = 2 ]' "RT22-01: a real comment followed by ; and a write into bin/ is refused (accepted fail-safe: the tail after a comment is scanned)"
# RT23-02: a quote mark in a real comment makes shlex fail; the fallback must still split `;` `<` `>` from words and drop the quote
# marks, so a redirect or an rm glued to a word is still seen. Read literally from this block (no shell quoting layer).
while IFS= read -r c; do
  ok '[ "$(sh "$c")" = 2 ]' "RT23-02: refused (a quote mark in a comment, operator glued to a word): $c"
done <<'RT23'
x>/workspace/bin/y # don't
true;rm /workspace/bin/x # don't
echo x # don't; rm /workspace/bin/x
x>/workspace/bin/y # "lone
true;sed -i s/a/b/ /workspace/docs/recovery.md # don't
RT23
while IFS= read -r c; do
  c=${c//@W@/$W}
  ok '[ "$(sh "$c")" = 0 ]' "RT23-02: allowed (harmless apostrophe, or a write into the own worktree/tmp): ${c//$W/<worktree>}"
done <<'RT23'
echo it's fine
ls # don't
echo it's fine > /tmp/x
echo it's fine > @W@/z
true;echo ok>@W@/z # don't
RT23
# RT23-01 (write guard): $'\'' hiding a write was refused before the read-only terminal fix; recorded so it stays so
while IFS= read -r c; do
  ok '[ "$(sh "$c")" = 2 ]' "RT23-01: a write into bin/ hidden behind \$'\\'' : refused: $c"
done <<'RT23'
echo $'\'' ; echo y > /workspace/bin/y ; echo \'
echo $'\'' ; cp a /workspace/bin/ ; echo \'
RT23
# RT24 (R2-01, R2-02, differential): with commenters off a leading comment line made `#` the command word (a newline is not a
# separator) and a comment ending in a backslash glued the next line onto the comment word: the write guard missed what followed.
NL=$'\n'
for c in "# note${NL}rm /workspace/bin/x" "#!/bin/bash${NL}rm /workspace/bin/x" "# note${NL}sed -i s/a/b/ /workspace/docs/recovery.md" \
         "#\\${NL}rm /workspace/bin/x" "# note \\${NL}rm /workspace/bin/x" "echo a # note\\${NL}echo y > /workspace/bin/y" "# note${NL}echo y > /workspace/bin/y"; do
  ok '[ "$(sh "$c")" = 2 ]' "RT24: refused (a comment line before a write; a comment ending in a backslash): ${c//$NL/<NL>}"
done
for c in "echo x#y" "ls # note" "echo a # note${NL}ls" "# build${NL}ls -la" "# note \\${NL}ls" "# note${NL}echo y > $W/z" "# note${NL}echo y > /tmp/x"; do
  ok '[ "$(sh "$c")" = 0 ]' "RT24: allowed (comments around harmless or in-worktree commands): ${c//$NL/<NL>}"
done
# Differential: at least as strict as the pre-RT22-01 parse (copy of the guard under test with its `lex.commenters = …` line removed).
sed '/^ *lex\.commenters = /d' "$G" >"$T/pre-wg.py"; chmod +x "$T/pre-wg.py"; WGREAL=$G
DIFF=("# note${NL}rm /workspace/bin/x" "#!/bin/bash${NL}rm /workspace/bin/x" "# note${NL}sed -i s/a/b/ /workspace/docs/recovery.md" "#\\${NL}rm /workspace/bin/x"
      "# note \\${NL}rm /workspace/bin/x" "echo a # note\\${NL}echo y > /workspace/bin/y" "echo x#; echo y > /workspace/bin/y" "echo x#y && rm /workspace/bin/x"
      "echo x#; sed -i s/a/b/ /workspace/docs/recovery.md" "ls # note; echo y > /workspace/bin/y" "x>/workspace/bin/y # don't" "true;rm /workspace/bin/x # don't"
      "echo x # don't; rm /workspace/bin/x" "echo \$'\\'' ; echo y > /workspace/bin/y ; echo \\'" "echo a # build > /workspace/bin/y" "echo y > /workspace/bin/y # done"
      "# build${NL}ls -la" "echo a # note${NL}ls" "echo it's fine" "ls # note" "echo x#y" "cp a /workspace/bin/ # c" "echo y > $W/z # c")
dgood=1; for c in "${DIFF[@]}"; do
  pre=$(G=$T/pre-wg.py sh "$c"); now=$(G=$WGREAL sh "$c")
  [ "$pre" = 2 ] && [ "$now" != 2 ] && { dgood=0; echo "     not as strict as pre-RT22-01: ${c//$NL/<NL>}"; }; done
ok '[ "$dgood" = 1 ]' "RT24 differential: the write guard refuses everything its pre-RT22-01 parse refuses (${#DIFF[@]} mixed commands)"
ok '[ "$(G=$T/pre-wg.py sh "# note${NL}rm /workspace/bin/x")" = 2 ]' "RT24 differential premise: the pre-RT22-01 copy does refuse a command after a leading comment line"
ok '[ "$(echo "not json" | python3 "$G" >/dev/null 2>&1; echo $?)" = 2 ]' "an unreadable payload is refused (fail closed)"
ok '[ "$(sh "bin/merge-card.sh t_aaaaaaaa --push" /workspace)" = 2 ] && said "merge-card.sh" && [ "$(sh "bash -c '"'"'/workspace/bin/merge-card.sh t_aaaaaaaa --owner-approved'"'"'")" = 2 ] && [ "$(run process_manage '"'"'{"action": "write", "session_id": "p1", "data": "merge-card.sh t_aaaaaaaa\n"}'"'"')" = 2 ]' "F31: a builder command mentioning merge-card.sh is refused (terminal, nested, process stdin)"
ok '[ "$(run read_file '"'"'{"path": "/workspace/config/owner.env"}'"'"')" = 0 ]' "other tools are not this guard's business (the matcher never sends them)"
# Batch 6: builders do not edit agent configuration (~/.hermes, ~/.claude, ~/.config/opencode, ~/.local/share/opencode).
# The guard only inspects paths; nothing below writes under the real home except one dangling symlink in the scratch worktree.
CFG="agent configuration"
ok '[ "$(wf ~/.hermes/profiles/builder-local/config.yaml)" = 2 ] && said "builders do not edit $CFG"' "write_file to a profile config.yaml: refused, says builders do not edit agent configuration"
ok '[ "$(wf "$HOME/.hermes/config.yaml")" = 2 ] && [ "$(wf "$HOME/.hermes/profiles/builder-local/hooks/write-guard.py")" = 2 ] && [ "$(wf "$HOME/.hermes/shell-hooks-allowlist.json")" = 2 ] && [ "$(wf "$HOME/.hermes/profiles/builder-local/SOUL.md")" = 2 ] && [ "$(wf "$HOME/.hermes/.env")" = 2 ]' "write_file to ~/.hermes config, hooks, allowlist, SOUL and .env: refused"
ok '[ "$(wf ~/.claude/settings.json)" = 2 ] && [ "$(wf ~/.config/opencode/opencode.json)" = 2 ] && [ "$(wf ~/.local/share/opencode/auth.json)" = 2 ]' "write_file to ~/.claude, ~/.config/opencode and ~/.local/share/opencode: refused"
ln -s "$HOME/.hermes/profiles/builder-local/config.yaml" "$W/cfg"
ok '[ "$(wf cfg)" = 2 ] && said "$CFG" && [ "$(wf "../../../../../../../..$HOME/.hermes/x")" = 2 ]' "a symlink in the worktree into ~/.hermes, and ../ up to it: refused"
ok '[ "$(run patch "$(jq -nc --arg p "$HOME/.hermes/config.yaml" '"'"'{path: $p, old_string: "a", new_string: "b"}'"'"')")" = 2 ] && [ "$(run patch "$(jq -nc --arg p "$HOME/.claude/settings.json" '"'"'{mode: "patch", patch: ("*** Begin Patch\n*** Update File: " + $p + "\n@@\n-a\n+b\n*** End Patch")}'"'"')")" = 2 ]' "patch (plain and V4A) on ~/.hermes and ~/.claude: refused"
ok '[ "$(wf /tmp/x)" = 0 ] && [ "$(wf "$W/a.md")" = 0 ] && [ "$(wf "$HOME/.hermes/profiles/builder-local/cache/scratch/$C/a.txt")" = 0 ]' "/tmp, the worktree and the profile's own cache/scratch: still allowed"
ok '[ "$(wf "$HOME/.hermes/profiles/builder-claude/cache/scratch/$C/a.txt")" = 2 ] && [ "$(wf "$HOME/.hermes/profiles/builder-local/cache/a.txt")" = 2 ] && [ "$(wf "$HOME/.hermes/profiles/builder-local/cache/scratch/../config.yaml")" = 2 ]' "another profile's scratch, the wider cache dir, and a ../ out of scratch: refused"
KW="$HOME/.hermes/kanban/boards/ai-stack/workspaces/$C"
ok '[ "$(WS=$KW wf "$KW/e.json")" = 0 ] && [ "$(WS=$KW wf "$HOME/.hermes/kanban/kanban.db")" = 2 ] && [ "$(WS="$HOME/.hermes/kanban" wf "$HOME/.hermes/kanban/kanban.db")" = 2 ] && [ "$(WS="$HOME/.hermes" wf "$HOME/.hermes/config.yaml")" = 2 ]' "the card's own kanban workspace is writable; the kanban root, db and ~/.hermes as workspace are not"
ok '[ "$(sh "echo x > ~/.hermes/profiles/builder-local/config.yaml")" = 2 ] && said "$CFG" && [ "$(sh "echo x >> \$HOME/.claude/settings.json")" = 2 ] && [ "$(sh "echo x > $HOME/.config/opencode/opencode.json")" = 2 ]' "terminal redirect into the config prefixes (also ~ and \$HOME): refused"
ok '[ "$(sh "sed -i s/a/b/ ~/.claude/settings.json")" = 2 ] && [ "$(sh "cp a ~/.hermes/hooks/x")" = 2 ] && [ "$(sh "rm ~/.local/share/opencode/auth.json")" = 2 ] && [ "$(sh "tee $HOME/.hermes/config.yaml")" = 2 ] && [ "$(sh "chmod 777 ~/.hermes/config.yaml")" = 2 ]' "terminal sed -i, cp, rm, tee and chmod on the config prefixes: refused"
ok '[ "$(sh "bash -c '"'"'echo x > ~/.hermes/config.yaml'"'"'")" = 2 ] && [ "$(run process_manage '"'"'{"action": "write", "session_id": "p1", "data": "echo x > ~/.claude/settings.json\n"}'"'"')" = 2 ]' "nested bash -c and process_manage stdin writing into the config prefixes: refused"
ok '[ "$(sh "cat ~/.hermes/config.yaml")" = 0 ] && [ "$(sh "ls ~/.claude && grep x ~/.config/opencode/opencode.json")" = 0 ] && [ "$(sh "cp ~/.hermes/config.yaml /tmp/c")" = 0 ]' "terminal reads of the config prefixes stay allowed (secrets are secret-guard.py's job)"
ok '[ "$(sh "echo x > /tmp/x && cp a $HOME/.hermes/profiles/builder-local/cache/scratch/$C-a.txt")" = 0 ] && [ "$(sh "echo x > ~/.hermes/profiles/builder-local/cache/scratch/$C/a.txt")" = 0 ]' "terminal writes to /tmp and the profile's own cache/scratch: allowed"
# Known limit (D42): a script written to /tmp and run, an interpreter, or a variable-built path is not caught.
ok '[ "$(sh "python3 /tmp/edit-config.py")" = 0 ]' "known limit: running a script from /tmp is not closed"

# D46: one protected list. Every repo and home entry of roles.json is refused by this guard, and the card guard reads the
# same list (bin/role-guard-selftest.sh covers its side), so the two cannot drift.
for p in $(python3 -c 'import sys; sys.path.insert(0, "/workspace/bin"); import roles; a, b = roles.protected(roles.load()); print(" ".join(a + b))'); do
  ok '[ "$(wf "$p/zz-probe")" = 2 ]' "protected (roles.json): $p refused"
done
ok '! grep -nE "^(PROTECTED|CONFIG) = \[" "$G"' "the write guard keeps no protected list of its own"
ok '[ "$(ROLES_FILE=/nonexistent wf "$W/a.md")" = 2 ] && said "STL-CFG-303"' "a missing role table: every write refused (STL-CFG-303)"
ok '[ "$(hookrun bind "$C" x-unlisted "/workspace/.worktrees/$C" write_file "$(wjson "/workspace/.worktrees/$C/a.md")" /tmp)" = 2 ] && grep -q "has no card worktree" "$T/out" && [ "$(jq -nc --arg p "$HOME/.hermes/profiles/x-unlisted/cache/scratch/a" '"'"'{tool_name: "write_file", tool_input: {path: $p, content: "x"}, cwd: "/tmp", profile: "x-unlisted", extra: {}}'"'"' | python3 "$G" >/dev/null 2>&1; echo $?)" = 0 ] && [ "$(jq -nc '"'"'{tool_name: "write_file", tool_input: {path: "/tmp/x"}, cwd: "/tmp", profile: "x-unlisted", extra: {}}'"'"' | python3 "$G" >/dev/null 2>&1; echo $?)" = 0 ]' "a profile with no row: no card worktree (refused there), /tmp still allowed"
# K1 (real tree): for every builder profile of the role table, the card is proven by a fake worker bound to a running card.
# OWN is the card's own worktree inside /workspace (F8: that path is what counts); it need not exist, nothing is written.
BUILDERS=$(jq -r '.roles as $r | .profiles | to_entries[] | select($r[.value.role].workspace == "git-worktree") | .key' /workspace/docs/hermes-local/roles.json)
for p in $BUILDERS; do
  OWN=/workspace/.worktrees/$C; OP=$(jq -r --arg p "$p" '.profiles | keys[] | select(. != $p)' /workspace/docs/hermes-local/roles.json | head -1)
  WO=$(wjson "$OWN/a.md"); WR=$(wjson sub/b.md); WM=$(wjson /workspace/decisions.md); WX=$(wjson /workspace/.worktrees/t_0000beef/a.md)
  PO=$(jq -nc --arg p "$OWN/a.md" '{path: $p, old_string: "a", new_string: "b"}'); PM=$(jq -nc '{path: "/workspace/SUPERVISOR.md", old_string: "a", new_string: "b"}')
  TO=$(tjson "echo x > $OWN/a.md"); TC=$(tjson "cd $OWN && echo x > a.md"); TB=$(tjson "echo x > /workspace/bin/y")
  ok '[ "$(hookrun bind $C $p $OWN write_file "$WO" $OWN)" = 0 ] && [ "$(hookrun bind $C $p $OWN write_file "$WR" $OWN)" = 0 ] && [ "$(hookrun bind $C $p $OWN patch "$PO" $OWN)" = 0 ]' "$p: write_file (absolute and relative) and patch in its own worktree, card proven from its bound worker: allowed"
  ok '[ "$(hookrun bind $C $p $OWN terminal "$TO" $OWN)" = 0 ] && [ "$(hookrun bind $C $p $OWN terminal "$TC" /tmp)" = 0 ]' "$p: a terminal redirect into its own worktree, and a cd there first: allowed"
  ok '[ "$(hookrun bind $C $p $OWN write_file "$WM" $OWN)" = 2 ] && grep -qF "builders write only inside their own worktree ($OWN)" "$T/out" && [ "$(hookrun bind $C $p $OWN write_file "$WX" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$TB" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN patch "$PM" $OWN)" = 2 ]' "$p: main checkout file, another card's worktree, a redirect into bin/, and a patch on SUPERVISOR.md: refused"
  while IFS='|' read -r fx needle label; do
    ok '[ "$(hookrun $fx $C $p $OWN write_file "$WO" $OWN)" = 2 ] && grep -qF -- "$needle" "$T/out" && grep -qE "no card worktree known|STL-GRD-603" "$T/out"' "$p: $label: refused, the failed proof named"
  done <<'LIST'
nobind|has no recorded worker process|the run has no worker process bound
stranger|is not an ancestor of this call|the run is bound to a process that is no ancestor
stale|start time differs|the run is bound to an ancestor pid with another start time
lock|claim lock is not|the worker is bound under another claim lock
closed|has no open run|the run is closed
LIST
  ok '[ "$(ASG=$OP hookrun bind $C $p $OWN write_file "$WO" $OWN)" = 2 ] && grep -qF "no running card is assigned to this profile" "$T/out"' "$p: the bound card is assigned to another profile: refused"
  ok '[ "$(hookrun stranger $C $p $OWN write_file "$WO" $OWN HERMES_KANBAN_TASK=$C HERMES_KANBAN_WORKSPACE=$OWN)" = 2 ] && grep -qF "is not an ancestor of this call" "$T/out"' "$p: HERMES_KANBAN_TASK and HERMES_KANBAN_WORKSPACE set, the run bound to no ancestor: refused, the ids not trusted"
  ok '[ "$(hookrun none "" $p $OWN write_file "$WO" $OWN HERMES_KANBAN_TASK=$C HERMES_KANBAN_WORKSPACE=$OWN)" = 2 ] && grep -qF "no running card is assigned to this profile" "$T/out"' "$p: the same ids with no running card at all: refused"
  ok '[ "$(hookrun bind $C $p $OWN write_file "$WO" $OWN PATH=/usr/bin:/bin)" = 2 ] && grep -qF "the board cannot be read" "$T/out"' "$p: an unreadable board (no hermes on PATH): refused, the failed proof named"
  ok '[ "$(hookrun bind $C $p $OWN write_file "$WO" $OWN HERMES_KANBAN_WORKSPACE=$T/other)" = 2 ] && grep -qF "is not card $C" "$T/out" && [ "$(hookrun bind $C $p $OWN write_file "$WO" $OWN HERMES_KANBAN_WORKSPACE=$OWN)" = 0 ]' "$p: HERMES_KANBAN_WORKSPACE other than the proven card's workspace: refused; equal to it: allowed"
  ok '(: >"$FAKE_LOG"; [ "$(hookrun bind $C $p $OWN write_file "$(wjson /tmp/x)" /tmp)" = 0 ] && [ ! -s "$FAKE_LOG" ]) && [ "$(hookrun none "" $p $OWN write_file "$(wjson /tmp/x)" /tmp)" = 0 ]' "$p: /tmp needs no proof: allowed, and the board is not asked"
done
# S3A-01 (live, 2026-11-08): a project repo inside the stack root. The first bound repo holding the workspace was the stack
# root, so the card's own project worktree was judged against /workspace/.worktrees/<card> and refused. The deepest repo decides.
NR=/workspace/.scratch/wgst-nested-$C; PDB=$T/projects.db
sqlite3 "$PDB" "create table projects(id,slug,primary_path,board_slug,archived); insert into projects values ('p1','nested','$NR','ai-stack',0)" 2>/dev/null \
  || python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('create table projects(id,slug,primary_path,board_slug,archived)'); c.execute('insert into projects values (?,?,?,?,0)',('p1','nested',sys.argv[2],'ai-stack')); c.commit()" "$PDB" "$NR"
export PROJECTS_DB=$PDB
ok '[ "$(WS=$NR/.worktrees/$C wf $NR/.worktrees/$C/a.md)" = 0 ]' "project repo inside /workspace: write inside the card's own project worktree: allowed"
ok '[ "$(WS=$NR/.worktrees/$C wf $NR/main.txt)" = 2 ] && [ "$(WS=$NR/.worktrees/$C wf /workspace/decisions.md)" = 2 ]' "project repo inside /workspace: the project's main checkout and the stack's files: refused"
ok '[ "$(WS=$NR wf $NR/x)" = 2 ] && [ "$(WS=$NR/.worktrees/t_00000000 wf $NR/.worktrees/t_00000000/x)" = 2 ] && [ "$(WS=$NR/.worktrees/t_00000000 wf $NR/.worktrees/$C/a.md)" = 2 ]' "project repo inside /workspace: the repo root or another card's worktree as workspace: refused"
ok '[ "$(WS=/workspace/.worktrees/$C wf /workspace/.worktrees/$C/a.md)" = 0 ] && [ "$(WS=/workspace/.worktrees/$C wf $NR/.worktrees/$C/a.md)" = 2 ]' "stack worktree still works beside a nested project; it cannot write the project's worktree"
# S3A-01b (RT15): a worktree swapped for a symlink to the repo root must not make the repo root the worktree.
mkdir -p "$NR/.worktrees" && ln -sfn "$NR" "$NR/.worktrees/$C"
ok '[ "$(WS=$NR/.worktrees/$C wf $NR/live.sh)" = 2 ] && [ "$(WS=$NR/.worktrees/$C wf $NR/.worktrees/$C/live.sh)" = 2 ]' "a worktree replaced by a symlink to the repo root: writes into the repo root refused"
rm -rf "${NR:?}"
# S3A-01b (verifier note): a project bound by a symlinked primary_path is judged by its real folder.
NR2=/workspace/.scratch/wgst-real-$C; LN=/workspace/.scratch/wgst-link-$C; mkdir -p "$NR2" && ln -sfn "$NR2" "$LN"
python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('delete from projects'); c.execute('insert into projects values (?,?,?,?,0)',('p2','linked',sys.argv[2],'ai-stack')); c.commit()" "$PDB" "$LN"
ok '[ "$(WS=$NR2/.worktrees/$C wf $NR2/main.txt)" = 2 ] && [ "$(WS=$NR2/.worktrees/$C wf $NR2/.worktrees/$C/a.md)" = 0 ]' "a project bound by a symlinked path: its real main checkout refused, its own worktree allowed"
rm -rf "${NR2:?}" "${LN:?}"
python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('delete from projects'); c.commit()" "$PDB"
ok '[ "$(WS=$NR/.worktrees/$C wf $NR/.worktrees/$C/a.md)" = 2 ]' "a project repo that is not bound to the board: its worktree is not trusted"
unset PROJECTS_DB
# K1 round 2: a card id that is not t_<8 hex> is refused before the F8 comparison. With workspace "/" (its path contains every
# path under /workspace) the bound worker's card must not make /workspace writable.
ok '[ "$(hookrun bind "../.." builder-local / write_file "$(wjson /workspace/bin/k1-x)" /tmp)" = 2 ] && said "no card worktree known" && [ "$(hookrun bind "../.." builder-local / write_file "$(wjson /tmp/k1-x)" /tmp)" = 0 ]' "a card id like ../.. with workspace /: /workspace/bin refused (no card worktree known), /tmp still allowed"
# K1b (red team): the write guard reads what Hermes does, not only the plain path. Each case is a bound worker of each builder
# profile of the role table. V4A headers are parsed as Hermes parses them (tools/patch_parser.py).
V4A() { printf '*** Begin Patch\n%s\n@@\n-a\n+b\n*** End Patch' "$1"; }
pj() { jq -nc --arg p "$1" '{mode: "patch", patch: $p}'; }
echo y > "$W/plain.md"; echo x > "$W/hl.md"; ln "$W/hl.md" "$T/outside-hl.md"   # hl.md has two hard links; plain.md has one
BT='echo `cp /tmp/x /workspace/bin/y`'
BQ="bash bin/merge''-card.sh t_x"
BK='hermes kanban --board ai-stack complete t_x'
BE='env -u HERMES_DELEGATED_CHILD_CONTEXT true'
WDJ=$(jq -nc '{command: "ls", workdir: "/workspace"}')
for p in $BUILDERS; do
  OWN=/workspace/.worktrees/$C
  P1=$(pj "$(V4A '***Update File: /workspace/bin/x')"); P2=$(pj "$(V4A '*** Update  File: /workspace/bin/x')")
  P3=$(pj "$(V4A '*** Update File:/workspace/bin/x')"); P4=$(pj "$(V4A "*** Move File: /workspace/bin/x -> $OWN/y")")
  P5=$(pj "$(V4A "*** Move File: $OWN/a -> /workspace/bin/b")"); P6=$(pj "$(V4A '*** Frobnicate File: x')")
  P7=$(pj "$(V4A "*** Update File: $OWN/a")")
  ok '[ "$(hookrun bind $C $p $OWN patch "$P1" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN patch "$P2" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN patch "$P3" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN patch "$P4" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN patch "$P5" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN patch "$P6" $OWN)" = 2 ] && grep -qF "is not a header Hermes" "$T/out" && [ "$(hookrun bind $C $p $OWN patch "$P7" $OWN)" = 0 ]' "$p: V4A headers naming /workspace/bin refused (spacing variants too), a Move with either end outside refused, an unparseable header refused; a correct Update in the worktree allowed"
  ok '[ "$(hookrun bind $C $p $W write_file "$(wjson ../x.md)" $W)" = 2 ] && [ "$(hookrun bind $C $p $W write_file "$(wjson sub/../../bin/x)" $W)" = 2 ] && [ "$(hookrun bind $C $p $OWN write_file "$(wjson plain/b.md)" $OWN)" = 0 ]' "$p: a relative write_file path containing .. refused (from the worktree folder, outside /workspace too); a plain relative path allowed"
  ok '[ "$(hookrun bind $C $p $OWN terminal "$(tjson "cd /workspace/bin")" $OWN)" = 2 ] && grep -qF "moves the terminal" "$T/out" && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "pushd /workspace")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "cd ~/.hermes")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$WDJ" $OWN)" = 2 ]' "$p: cd /workspace/bin, pushd /workspace, cd ~/.hermes and a workdir of /workspace refused"
  ok '[ "$(hookrun bind $C $p $OWN terminal "$(tjson "cd $OWN/sub && echo x > a.md")" /tmp)" = 0 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "cd /tmp")" $OWN)" = 2 ]' "$p: cd into its own worktree (and a redirect after it) and cd /tmp refused (K1c: a cd must stay inside the proven worktree)"
  ok '[ "$(hookrun bind $C $p $OWN terminal "$(tjson "ln /workspace/bin/role-guard.py $OWN/rg.py")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "cp -l /workspace/bin/role-guard.py $OWN/rg.py")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "link /workspace/bin/role-guard.py $OWN/rg.py")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "ln -s /workspace/bin/role-guard.py $OWN/rg.py")" $OWN)" = 0 ]' "$p: a hard link (ln, cp -l, link) of a file outside the worktree refused; ln -s allowed"
  ok '[ "$(hookrun bind $C $p $W write_file "$(wjson "$W/hl.md")" $W)" = 2 ] && grep -qF "more than one hard link" "$T/out" && [ "$(hookrun bind $C $p $W write_file "$(wjson "$W/plain.md")" $W)" = 0 ]' "$p: write_file to a worktree file with more than one hard link refused; a file with one link allowed"
  ok '[ "$(hookrun bind $C $p $OWN terminal "$(tjson "$BT")" $OWN)" = 2 ]' "$p: a backtick command that copies into /workspace/bin refused"
  ok '[ "$(hookrun bind $C $p $OWN terminal "$(tjson "$BQ")" $OWN)" = 2 ] && grep -qF "merge-card" "$T/out"' "$p: bash bin/merge''-card.sh (quote-split) refused"
  ok '[ "$(hookrun bind $C $p $OWN terminal "$(tjson "$BK")" $OWN)" = 2 ] && grep -qF "kanban" "$T/out" && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "$BE")" $OWN)" = 2 ]' "$p: hermes kanban --board ... complete refused; env -u HERMES_DELEGATED_CHILD_CONTEXT refused"
  ok '[ "$(hookrun bind $C $p $OWN terminal "$(tjson "echo x >> /workspace/AGENTS.md")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "cp /tmp/x /workspace/.claude/settings.json")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "cp /tmp/x /workspace/package.json")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "cp /tmp/x $OWN/package.json")" $OWN)" = 0 ]' "$p: terminal writes into the main checkout outside the protected list refused (a redirect, two cp); a write into the own worktree allowed"
done
# K1c (red team, X2): wrappers, builtins, grouping, option spellings and xargs do not hide a write or a worktree exit, and the
# marker, kanban and merge-card checks run on the command word, so a quoted message or a read is not a run.
UQ="unset HERMES_DELEGATED_CHILD_CONTEX''T"; UI='unset ${!HERMES_DELEG*}'   # literal: the quote-split and the indirect expansion stay for the guard
for p in $BUILDERS; do
  OWN=/workspace/.worktrees/$C
  ok '[ "$(hookrun bind $C $p $OWN terminal "$(tjson "cd /home/node")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "cd")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "cd -P /workspace/bin")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "builtin cd /workspace/bin")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "{ cd /workspace/bin; }")" $OWN)" = 2 ]' "$p: cd /home/node, a bare cd, cd -P, builtin cd and a braced cd out of the worktree refused"
  ok '[ "$(hookrun bind $C $p $OWN terminal "$(tjson "timeout 5 cp /tmp/x /workspace/bin/y")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "nice -n 0 cp /tmp/x /workspace/bin/y")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "ls /tmp | xargs rm -f /workspace/bin/x")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "find /workspace/bin -name y -delete")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "rsync -a /tmp/x /workspace/bin/y")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "tar -xf /tmp/x.tar -C /workspace/bin")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "unzip -o /tmp/z.zip -d /workspace/bin")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "patch /workspace/bin/y < /tmp/p")" $OWN)" = 2 ]' "$p: timeout, nice, an xargs-fed rm, find -delete, rsync, tar -C, unzip -d and patch into /workspace/bin refused"
  ok '[ "$(hookrun bind $C $p $OWN terminal "$(tjson "timeout 5 ln /workspace/bin/role-guard.py $OWN/rg.py")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $W terminal "$(tjson "echo x >> $W/hl.md")" $W)" = 2 ]' "$p: timeout 5 ln from outside into the worktree refused; a redirect into a worktree file with two hard links refused"
  ok '[ "$(hookrun bind $C $p $OWN terminal "$(tjson "$UQ")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "$UI")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "hk kanban --board ai-stack unblock t_x")" $OWN)" = 2 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "\"\$(command -v hermes)\" kanban show t_x")" $OWN)" = 2 ]' "$p: unset of HERMES_DELEGATED_CHILD_CONTEXT (quote-split and indirect), hk kanban, and \"\$(command -v hermes)\" kanban refused"
  ok '[ "$(hookrun bind $C $p $OWN terminal "$(tjson "git commit -m \"notes on hermes kanban\"")" $OWN)" = 0 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "grep -rn HERMES_DELEGATED_CHILD_CONTEXT $OWN")" $OWN)" = 0 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "cat $OWN/merge-card-notes.md")" $OWN)" = 0 ]' "$p: false-positive checks allowed: a commit message naming hermes kanban, a grep for the marker's name, cat of a merge-card notes file"
done
# K2: when the stack, not the worker, is at fault (the profile has a running card and its proof fails, or the board cannot be
# read), a write into /workspace is refused with STL-GRD-603, which says it is a fault in the stack and is not blamed on the
# worker or on the path. One alerts.log line per refusal (K11 pages it once per card per streak: alert-page-selftest).
export ESCALATE_SUP_DIR=$T/sup ALERT_CATALOG=${ACAT:-/workspace/docs/hermes-local/alert-catalog.json}
mkdir -p "$T/sup/logs"; AL=$T/sup/logs/alerts.log; CQ="card='$C'"
for p in $BUILDERS; do
  OWN=/workspace/.worktrees/$C
  : >"$AL"
  ok '[ "$(hookrun stranger $C $p $OWN write_file "$(wjson "$OWN/a.md")" $OWN)" = 2 ] && grep -qF "[STL-GRD-603]" "$T/out" && grep -qF "the stack could not identify this card" "$T/out" && grep -qF "fault in the stack, not a rule about" "$T/out" && ! grep -qF "(D40)" "$T/out" && [ "$(grep -c "^STL-GRD-603 " "$AL")" = 1 ] && grep -qF "$CQ" "$AL"' "$p: a card runs for this profile and its proof fails (bound to no ancestor): refused with STL-GRD-603 (a fault in the stack, no (D40) tail), one alerts.log line naming the card"
  : >"$AL"
  ok '[ "$(hookrun none "" $p $OWN write_file "$(wjson "$OWN/a.md")" $OWN)" = 2 ] && grep -qF "builders write only inside their own worktree" "$T/out" && [ ! -s "$AL" ]' "$p: no running card for the profile: the old rule message and no STL-GRD-603"
  : >"$AL"
  ok '[ "$(hookrun bind $C $p $OWN write_file "$(wjson "$OWN/a.md")" $OWN PATH=/usr/bin:/bin)" = 2 ] && grep -qF "[STL-GRD-603]" "$T/out" && [ "$(grep -c "^STL-GRD-603 " "$AL")" = 1 ]' "$p: the board cannot be read: refused with STL-GRD-603, one alerts.log line"
  : >"$AL"   # K2, terminal path (verifier round 4): a terminal write under the same stack fault names STL-GRD-603 too
  ok '[ "$(hookrun stranger $C $p $OWN terminal "$(tjson "echo x > $OWN/a.md")" $OWN)" = 2 ] && grep -qF "[STL-GRD-603]" "$T/out" && [ "$(grep -c "^STL-GRD-603 " "$AL")" = 1 ]' "$p: a terminal write under a failed proof (card running): refused with STL-GRD-603, one alerts.log line"
  : >"$AL"   # K2 (RT5-04): a terminal call whose workdir is the own worktree, under the same stack fault
  ok '[ "$(hookrun stranger $C $p $OWN terminal "$(jq -nc --arg w "$OWN" '"'"'{command: "npm test", workdir: $w}'"'"')" $OWN)" = 2 ] && grep -qF "[STL-GRD-603]" "$T/out" && [ "$(grep -c "^STL-GRD-603 " "$AL")" = 1 ]' "$p: workdir = own worktree under a failed proof: STL-GRD-603, one alerts.log line"
  ok '[ "$(hookrun bind $C $p $OWN terminal "$(tjson "HERMES_HOME=$HOME/.hermes hermes send --to discord:#alerts hi")" $OWN)" = 2 ] && grep -qF "never post with" "$T/out"' "$p: hermes send from a builder terminal refused (RT5-05)"
  # xargs regression (verifier F2 / RT4-14): a read-only xargs pipeline is allowed, an xargs-fed write verb is refused
  ok '[ "$(hookrun bind $C $p $OWN terminal "$(tjson "ls /tmp | xargs -n1 echo")" $OWN)" = 0 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "ls $OWN | xargs wc -l")" $OWN)" = 0 ] && [ "$(hookrun bind $C $p $OWN terminal "$(tjson "ls /tmp | xargs rm -f")" $OWN)" = 2 ] && grep -qF "feeds paths this guard cannot see" "$T/out"' "$p: ls | xargs echo and xargs wc allowed; xargs rm refused for the right reason"
done
# ---- F1 W4 round 2 (G2, G4): the guard reads a command the way the shell will. A card worktree OWN under /workspace is the proven one.
NL=$'\n'; WGA=$T/sup/logs/alerts.log
for p in $BUILDERS; do
  OWN=/workspace/.worktrees/$C
  wg() { hookrun bind $C $p $OWN terminal "$(tjson "$1")" "${2:-$OWN}"; }
  # the false-positive controls: everyday commands in the worktree, with literal paths, stay allowed
  while IFS= read -r c; do
    c=${c//@O@/$OWN}; ok '[ "$(wg "$c")" = 0 ]' "G2 $p: allowed (an everyday command in the worktree): $c"
  done <<'G2OK'
git checkout -- .
git restore .
git reset --hard
git stash
git add app/settings.py
git commit -m "touch settings"
git status
git diff --stat
cat src/settings.py
python3 settings.py --help
grep -rn settings src
for f in $(ls); do cat $f; done
out=@O@/o.txt; echo x > "$out"
echo hi > @O@/n.txt
find . -name '*.py' -exec echo {} \;
npm test
cp a b
echo $(date); ls
for f in *.txt; do mv "$f" "$f.bak"; done
G2OK
  ok '[ "$(wg "cat > $OWN/n.md <<'"'"'EOF'"'"'${NL}rm /workspace/bin/x${NL}EOF")" = 0 ] && [ "$(wg "cat > $OWN/n.md <<EOF${NL}text${NL}EOF${NL}ls")" = 0 ]' "G2 $p: allowed: a here-document's body is text, not commands"
  ok '[ "$(wg "cat <<EOF${NL}\$(rm /workspace/bin/x)${NL}EOF")" = 2 ] && [ "$(wg "cat > $OWN/n.md <<'"'"'EOF'"'"'${NL}text${NL}EOF${NL}rm /workspace/bin/x")" = 2 ] && [ "$(wg "echo \"<<X\"${NL}rm /workspace/bin/x${NL}X")" = 2 ]' "G2 $p: refused: a command substitution inside an unquoted here-document runs; a command after the body, and a << inside quotes, are commands"
  ok '[ "$(wg "echo ok${NL}ls")" = 0 ] && [ "$(wg "ls${NL}git status")" = 0 ]' "G2 $p: allowed: two harmless lines"
  ok '[ "$(wg "ls 2>&1")" = 0 ] && [ "$(wg "echo x >&2")" = 0 ] && [ "$(wg "echo x 2>/dev/null")" = 0 ]' "G2 $p: allowed: descriptor duplicates open no file"
  # refused: every redirect form, a second line, expansions, case, unresolved words, git, owner commands by resolved file
  while IFS= read -r c; do
    ok '[ "$(wg "$c")" = 2 ]' "G2 $p: refused: $c"
  done <<'G2NO'
echo x >& /workspace/bin/y
echo x >&/workspace/bin/y
: <> /workspace/bin/y
echo x &> /workspace/bin/y
echo x >| /workspace/bin/y
echo x 2> /workspace/bin/y
echo x > /workspace/bi{n,}/y
echo x > $'/workspace/b\151n/y'
echo x > /workspace/BIN/y
echo x > /workspace/bi?/roles.py
echo x > "$ZZ_UNSET_VAR/y"
cp a "$ZZ_UNSET_VAR"
x=/workspace/bin/y; echo x > "$x"
ls | xargs python3
find . -name x -exec python3 {} ;
python3 /workspace/bin/event_log.py append --type apply
python3 /workspace/bin/Settings.py get X
python3 /workspace/bin/set*.py get X
python3 /workspace/bin/set{t,}ings.py get X
python3 -I -B /workspace/bin/sett''ings.py get X
python3 $'/workspace/bin/set\164ings.py' get X
bash /tmp/x-merge-card.sh
x=/workspace/bin/settings.py; python3 "$x" get X
python3 "$ZZ_UNSET_VAR" get X
git checkout HEAD -- .stella/settings.json
git -C /workspace checkout -- .
git update-index --add --cacheinfo 100644,0000000000000000000000000000000000000000,.stella/settings.json
git add --pathspec-from-file=/tmp/l
git --git-dir=/workspace/.git add x
git -C /workspace/.worktrees/t_00000000 add x
echo $(date); rm /workspace/bin/x
cp a $(echo /workspace/bin/x)
cp a `echo /workspace/bin/x`
for f in /workspace/bin/*.py; do rm "$f"; done
for f in $(ls); do rm "$f"; done
(cd .); cp a /workspace/bin/b
G2NO
  for c in "echo ok${NL}cp /tmp/x /workspace/bin/y" "ls${NL}tee /workspace/bin/y" "ls${NL}dd of=/workspace/bin/y" "echo ok \\${NL}> /workspace/bin/y"; do
    ok '[ "$(wg "$c")" = 2 ]' "G2 $p: refused (a second line is a command of its own): ${c//$NL/<NL>}"
  done
  # git in the main checkout: every form, whatever its paths
  while IFS= read -r c; do
    ok '[ "$(wg "$c" /workspace)" = 2 ]' "G2 $p: refused in the main checkout: $c"
  done <<'G2GIT'
git checkout -- .
git checkout HEAD -- docs/hermes-local/roles.json
git restore .
git restore --source=HEAD --worktree -- .
git reset --hard HEAD
git stash
git clean -fd
git hash-object -w x
git commit-tree HEAD^{tree} -m x
git update-ref refs/heads/f1/card HEAD
git am /tmp/p.patch
git apply --cached /tmp/p.patch
git commit -m x
G2GIT
  : >"$WGA"
  ok '[ "$(wg "python3 /workspace/bin/settings.py get X")" = 2 ] && grep -qF "[STL-CFG-312]" "$T/out" && grep -q "an owner command" "$T/out" && [ "$(grep -c "^STL-CFG-312 " "$WGA")" = 1 ] && ! grep -q "owner.env" "$WGA"' "G4 $p: an owner command run: the code, the catalog message, one alert line"
  : >"$WGA"
  ok '[ "$(run write_file "$(wjson /workspace/.stella/settings.json)")" = 2 ] && grep -qF "[STL-CFG-312]" "$T/out" && [ "$(grep -c "^STL-CFG-312 " "$WGA")" = 1 ]' "G4 $p: a write of owner data: the code, one alert line"
  : >"$WGA"
  ok '[ "$(wg "echo x > /workspace/.stella/settings.json")" = 2 ] && grep -qF "[STL-CFG-312]" "$T/out" && [ "$(grep -c "^STL-CFG-312 " "$WGA")" = 1 ]' "G4 $p: a redirect into owner data: the code, one alert line"
  : >"$WGA"
  ok '[ "$(wg "echo x > /workspace/.supervisor/logs/events.jsonl")" = 2 ] && grep -qF "[STL-CFG-312]" "$T/out" && [ "$(grep -c "^STL-CFG-312 " "$WGA")" = 1 ]' "G4 $p: a redirect into an owner state path (the event log): the code, one alert line"
  : >"$WGA"
  ok '[ "$(wg "echo x > /workspace/bin/y")" = 2 ] && ! grep -qF "STL-CFG-312" "$T/out" && [ ! -s "$WGA" ]' "G4 $p: an older refusal keeps its text and writes no alert line"
done
# ---- F1 W4 round 3 (K7, K1b, K8, K9): the rule turned around. A command that names a path no role may write (owner data, the owner settings, the apply tool's
# state) runs only when its verb is a known reader (the table's read_verbs); an unknown writer needs no list entry to be refused.
ODF=$(jq -r '.files[] | select(.id == "settings") | .path' "/workspace/$(jq -r .data_index /workspace/docs/hermes-local/roles.json)"); ODD=${ODF%/*}; SCH=$(jq -r '.owner_data[0]' /workspace/docs/hermes-local/roles.json)
# the 8.3 short name of the first owner command named by name, as this mount gives it (T3: a name is judged by what it resolves to; the short name is found with -ef)
MCMD=/workspace/$(jq -r '.owner_commands_by_name[0]' /workspace/docs/hermes-local/roles.json); MST=$(basename "${MCMD%.*}" | tr a-z A-Z | cut -c1-6)
MSN=$(for i in 1 2 3 4 5 6 7 8 9; do x="$(dirname "$MCMD")/$MST~$i.$(printf '%s' "${MCMD##*.}" | tr a-z A-Z | cut -c1-3)"; [ "$x" -ef "$MCMD" ] && echo "$x" && break; done)   # readdir lists no short name: each is tried
for p in $BUILDERS; do
  OWN=/workspace/.worktrees/$C
  wg() { hookrun bind $C $p $OWN terminal "$(tjson "$1")" "${2:-$OWN}"; }
  for c in "sort -o /workspace/$ODF /etc/hostname" "perl -pi -e s/a/b/ /workspace/$ODF" "touch /workspace/$ODF" "gzip -f /workspace/$ODF" "awk -i inplace 1 /workspace/$ODF" \
           "curl -s -o /workspace/$ODF file:///etc/hostname" "ex -sc wq /workspace/$ODF" "split -b1 /etc/hostname /workspace/$ODD/x" "tar -C /workspace/$ODD -xf /tmp/x.tar" "cp /tmp/x /workspace/$ODD/" "mkdir /workspace/$ODD/zz-new" "cp -t/workspace/$ODD /tmp/x" \
           "python3 -c \"open('/workspace/$ODF','w').write('y')\"" "node -e \"require('fs').writeFileSync('/workspace/$ODF','y')\"" "perl -e 'open(F, \">/workspace/$ODF\")'" \
           "git checkout HEAD -- $ODD" "git restore $ODD" "git rm -r -q $SCH" "git clean -fdx $SCH" "rm -rf $SCH" "mv $SCH moved" "touch $ODF" "cp /tmp/x $SCH/"; do
    ok '[ "$(wg "$c")" = 2 ] && grep -qF "STL-CFG-312" "$T/out"' "K7 $p: refused, an unknown writer or a folder that holds owner data: $c"
  done
  ok '[ "$(wg "python3 - <<EOF${NL}open(\"/workspace/$ODF\",\"w\").write(\"y\")${NL}EOF")" = 2 ] && [ "$(wg "bash <<EOF${NL}echo x > /workspace/$ODF${NL}EOF")" = 2 ]' "K7 $p: refused: an interpreter given owner-path code in a here-document"
  ok '[ "$(wg "cat <<EOF${NL}notes about /workspace/$ODF${NL}EOF")" = 0 ] && [ "$(wg "cat /workspace/$ODF")" = 0 ]' "K7 $p: allowed: a reader that names an owner path (a here-document body for cat, cat itself)"
  ok '[ "$(wg "bash <<EOF${NL}export HERMES_DELEGATED_CHILD_CONTEXT=1${NL}EOF")" = 2 ] && [ "$(wg "sh <<EOF${NL}/workspace/bin/merge-card.sh x${NL}EOF")" = 2 ]' "K7 $p: refused: a here-document body is judged by the text checks it had before round 2 (the marker, an owner command by name)"
  for c in "cat $ODF" "grep -n schema $ODF" "jq . $ODF" "diff $ODF /tmp/x" "git show HEAD:$ODF" "git diff main -- $ODF" "ls $SCH" "head -3 $SCH/zz" "git log --oneline -3 -- $ODD" "wc -l $ODF"; do
    ok '[ "$(wg "$c")" = 0 ]' "K7 $p: allowed, a known reader names owner data: $c"
  done
  ok '[ "$(wg "git add .")" = 0 ] && [ "$(wg "git diff --output=/tmp/x -- $ODF")" = 2 ] && [ "$(wg "find . -name x -fprint /workspace/$ODF")" = 2 ]' "K7 $p: the tree-wide form in the worktree is allowed; a reader that writes by an option is not a reader"
  ok '[ "$(wg "cp /tmp/x $(echo /workspace/STELLA~1)/schemas/x")" = 2 ] && [ "$(wg "cp /tmp/x /workspace/STELLA~1/schemas/x")" = 2 ] && [ "$(wg "cp /tmp/x /workspace/.STELLA/schemas/x")" = 2 ] && [ -n "$MSN" ] && [ "$(wg "bash $MSN x")" = 2 ]' "K1b $p: a short name and a case variant are the same folder and the same owner command ($MSN)"
  : >"$WGA"; ok '[ "$(wg "touch /workspace/$ODF")" = 2 ] && [ "$(grep -c "^STL-CFG-312 " "$WGA")" = 1 ] && grep -q "role " "$WGA"' "K8 $p: the alert line names the role"
  ok '[ "$(wg "echo owner.env")" = 2 ] && grep -qF "[STL-CFG-312]" "$T/out"' "K8 $p: an older rule that catches a mention of the owner settings file first still says so with the code"
  ok '[ "$(wg "cp bin/merge-card.sh /tmp/mc; bash /tmp/merge-card x")" = 2 ] && [ "$(wg "bash /tmp/merge-card x")" = 2 ] && [ "$(wg "bash bin/merge-card-selftest.sh")" = 0 ]' "K9 $p: a copy of the merge script under another name (no extension) is refused as at 900d9b3; its selftest is not the script"
  B40=$(printf '{a,b}%.0s' $(seq 1 40))   # T4: built outside the quoted case (its quotes ended the case's own string)
  ok '[ "$(wg "tee /tmp/zz ${B40}x")" = 2 ]' "K5 $p: a brace-bomb word is refused (more than 64 words), not expanded"
done
# T4 (F1 W4 r4): the rule once, proven over a generated set. A verb that is not a known reader (the table's read_verbs) and names a path no role writes, or a
# folder that holds one, in any argument position, as an attached option value or in a -C / --directory form, is refused with the code. The matrix (every verb
# x every form x every target) judges through the guard's own reason() in one process (the same code from the parsed payload to the verdict; only the card
# proof is given: the worktree a bound worker would prove); one command of each form also goes through a real hook process, end to end.
cat >"$T/matrix.py" <<'PY'
import json, sys
G, own, prof = sys.argv[1:4]
src = open(G).read().split("\nPAY = sys.stdin.read()")[0]   # the guard without its stdin read and exit: its functions, its table
ns = {"__name__": "wg_matrix", "__file__": G}
exec(compile(src, G, "exec"), ns)
ns["own_worktree"] = lambda: (own, "")   # the proof a bound worker gives (the real hook runs below prove it from the process tree)
bad = 0
for line in sys.stdin:
    want, cmd = line.rstrip("\n").split("\t", 1)
    why = ns["reason"]({"tool_name": "terminal", "tool_input": {"command": cmd}, "cwd": own, "profile": prof})
    got = "refused" if why and why.startswith("[STL-CFG-312]") else "allowed" if why is None else "other"
    if got != want:
        bad += 1; print(f"     {want} expected, {got}: {cmd} :: {(why or '')[:160]}")
print(f"matrix-bad={bad}")
PY
MV=(cp mv install ln tar rsync unzip sort touch gzip perl sed tee dd truncate curl split cpio zip chmod)
MF=("@V @P" "@V /tmp/x @P" "@V @P/" "@V -C @P" "@V -C@P" "@V --directory=@P" "@V -t @P" "@V -o @P" "@V -x /tmp/x -f @P")
MT=("/workspace/$ODD" "/workspace/$ODF" "/workspace/$(printf '%s' "$ODD" | tr a-z A-Z)" "/workspace/$(jq -r .applied_state "/workspace/$(jq -r .data_index /workspace/docs/hermes-local/roles.json)" | cut -d/ -f1)")   # the folder, a file, a case variant, a folder above the state paths
MR=(cat head wc grep jq ls stat cmp)
{ for v in "${MV[@]}"; do for f in "${MF[@]}"; do for t in "${MT[@]}"; do c=${f//@V/$v}; printf 'refused\t%s\n' "${c//@P/$t}"; done; done; done
  for v in "${MR[@]}"; do for t in "${MT[@]}"; do printf 'allowed\t%s %s\n' "$v" "$t"; printf 'allowed\t%s /tmp/x %s\n' "$v" "$t"; done; done; } >"$T/matrix.txt"
MXP=(); for p in $BUILDERS; do python3 -I "$T/matrix.py" "$G" "/workspace/.worktrees/$C" "$p" <"$T/matrix.txt" >"$T/matrix-$p.out" 2>&1 & MXP+=($!); done; wait "${MXP[@]}"   # the builders' matrices side by side (only these: the stranger sleep is a job too)
for p in $BUILDERS; do
  OWN=/workspace/.worktrees/$C
  ok 'grep -q "^matrix-bad=0$" "$T/matrix-$p.out"' "T4 $p: $(grep -c ^refused "$T/matrix.txt") generated non-reader commands (${#MV[@]} verbs x ${#MF[@]} forms x ${#MT[@]} targets) refused with the code, $(grep -c ^allowed "$T/matrix.txt") reader commands allowed"
  grep "^     " "$T/matrix-$p.out" | head -5
  wg() { hookrun bind $C $p $OWN terminal "$(tjson "$1")" "${2:-$OWN}"; }
  k=0; for f in "${MF[@]}"; do v=${MV[$((k % ${#MV[@]}))]}; t=${MT[$((k % ${#MT[@]}))]}; k=$((k+1)); c=${f//@V/$v}; c=${c//@P/$t}
    ok '[ "$(wg "$c")" = 2 ] && grep -qF "STL-CFG-312" "$T/out"' "T4 $p: the real hook process agrees with the matrix: $c"
  done
done
# K5: no input of any length makes the guard run longer than a fraction of its hook timeout
BOMB=$(printf '{a,b}%.0s' $(seq 1 24))x; LONG=$(head -c 100000 /dev/zero | tr '\0' 'a')
for inp in "tee /tmp/zz $BOMB" "cat $BOMB" "echo $LONG" "python3 -c \"print('$LONG')\"" "cp $(printf '/workspace/bin/x%.0s ' $(seq 1 3000)) /tmp"; do
  st=$(date +%s%N); jq -nc --arg c "$inp" '{tool_name: "terminal", tool_input: {command: $c}, cwd: "/tmp", profile: "zz-qa"}' | python3 "$G" >/dev/null 2>&1; en=$(( ($(date +%s%N) - st) / 1000000 ))
  ok '[ "$en" -lt 5000 ]' "K5: the write guard answers in ${en} ms (limit 5000, hook timeout 20 s) on a ${#inp}-byte command"
done
ROLES_BAD=$T/roles-typeerr.json; jq '.roles[(.profiles | to_entries[0].value.role)].allowed_overrides = [{}]' /workspace/docs/hermes-local/roles.json >"$ROLES_BAD"
ok '[ "$(jq -nc "{tool_name: \"terminal\", tool_input: {command: \"ls\"}, cwd: \"/tmp\", profile: \"x\"}" | ROLES_FILE=$ROLES_BAD python3 "$G" >"$T/out" 2>"$T/err"; echo $?)" = 2 ] && ! grep -q Traceback "$T/err" && grep -q "STL-" "$T/out"' "CV-12: a table that makes validation raise (not a RolesError) is a refusal with a coded line, never a traceback"
ok '[ "$(echo "{" | python3 "$G" >"$T/out" 2>"$T/err"; echo $?)" = 2 ] && ! grep -q Traceback "$T/err" && grep -q "STL-CFG-312" "$T/out"' "an exception inside the guard (unreadable payload) is a coded refusal"
ok '[ "$(ls -A /workspace/.worktrees 2>/dev/null | sort)" = "$REAL_BEFORE" ]' "the real /workspace/.worktrees gained no entries during the run"
ok '[ "$(tail -c +$((LIVE_SIZE + 1)) "$LIVE_ALERTS" 2>/dev/null | grep -c "^STL-GRD-603 ")" = 0 ]' "no STL-GRD-603 line from this test reached the live alerts.log"
# T1 (r5): the two routes agree on every 10th bound row judged above (the judge and a real bound hook process, the same row), and a planted
# difference (the judge given a copy of the guard whose refusal reads otherwise) is caught
bjagree() { local n=0 i=0 c a ws br p e pay rc rrc args
  while IFS=$'\t' read -r c a ws br p e; do i=$((i+1)); [ $((i % 10)) = 1 ] || continue
    mapfile -d '' -t args < <(printf '%s' "$e" | base64 -d); pay=$(printf '%s' "$p" | base64 -d)
    rc=$(G=$1 NOCLS=1 bjrun "$c" "$a" "$ws" "$br" "$pay" agree "${args[@]}"); cp "$T/out" "$T/ag.judge"
    [ -f "$T/ag.real.$i" ] || { bound bind "$c" "$a" "$ws" "$br" "$pay" -- env "${args[@]}" python3 "$G" >"$T/ag.rc.$i"; cp "$T/out" "$T/ag.real.$i"; }   # the process run once per row, kept for the control
    { [ "$rc" = "$(<"$T/ag.rc.$i")" ] && [ "$(sort "$T/ag.real.$i")" = "$(sort "$T/ag.judge")" ]; } || n=$((n+1))
  done < <(cat "$T/bjrows"); echo "$n"; }
sed 's/"action": "block"/"action": "blocked"/' "$G" >"$T/wg-planted.py"
BN=$(wc -l <"$T/bjrows"); BD=$(bjagree "$G"); BX=$(bjagree "$T/wg-planted.py")
ok '[ "$BN" -ge 100 ] && [ "$BD" = 0 ]' "T1 route agreement: every 10th of $BN bound rows judged in the worker's judge gives the same exit code and output as a real bound hook process ($BD differ)"
ok '[ "$BX" -gt 0 ]' "T1 route agreement, negative control: a planted difference in the judge's guard is caught ($BX differ)"
bjstop   # the judges end
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
