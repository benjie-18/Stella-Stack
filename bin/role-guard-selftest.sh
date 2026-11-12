#!/usr/bin/env bash
# Hermetic self-test for bin/role-guard.py (D46), table-driven from docs/hermes-local/roles.json: every profile row x
# every gated tool, expected allow/refuse read from its role's permissions; the Phase 4 bad cards with their recorded
# arguments; the card rules; completion identity; fallback and malformed tables. Scratch projects.db, a stub `hermes`
# for kanban show, scratch alerts.log; never touches ~/.hermes or the board.
# K8 (reviewer named, never the caller): ROLES_FILE=<table> and STAGE=<dir> point the run at a staged table and guard; TREE_TOOL sets the
# tool `tree` sends (default kanban_complete).
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
S=${STAGE:-/workspace/bin}   # the guard under test (a staged copy while it is being replaced)
G=$S/role-guard.py
RF=${ROLES_FILE:-/workspace/docs/hermes-local/roles.json}   # the table under test (a staged copy while it is being replaced)
fails=0
ok() { local REAL=; case $1 in *alerts.log*) REAL=1 ;; esac   # T1 (r5): a case that reads the alert log runs its guard as a real process
  if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/out" ] && sed 's/^/     /' "$T/out" | head -3; fi; }
mkdir -p "$T/bin" "$T/sup" "$T/cards"
# Stub hermes: `kanban --board <b> show <id> --json` prints $T/cards/<id>.json; `kanban --board <b> list --assignee <p>
# --status running --json` prints $T/running-<p>.json (default []); anything else fails. Only the stack's board answers (B).
B=$(sed -n 's/^KANBAN_BOARD=\([A-Za-z0-9_-]*\).*/\1/p' /workspace/bin/kanban-board.sh)   # K1: the stack's one board, never the caller's env
cat >"$T/bin/hermes" <<EOF
#!/usr/bin/env bash
[ "\$3" = "$B" ] || exit 1
[ "\$1 \$2 \$4 \$6" = "kanban --board show --json" ] && [ -f "$T/cards/\$5.json" ] && exec cat "$T/cards/\$5.json"
[ "\$1 \$2 \$4 \$5" = "kanban --board list --assignee" ] && { [ -f "$T/running-\$6.json" ] && exec cat "$T/running-\$6.json"; echo "[]"; exit 0; }
exit 1
EOF
chmod +x "$T/bin/hermes"
python3 - "$T/projects.db" "$B" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("create table projects (id text, slug text, name text, board_slug text, primary_path text, archived int)")
c.execute("insert into projects values ('p_0000aaaa', 'proj-a', 'A', ?, '/workspace', 0)", (sys.argv[2],))
c.execute("insert into projects values ('p_0000bbbb', 'proj-old', 'Old', ?, '/workspace', 1)", (sys.argv[2],))
c.commit()
PY
export ROLES_FILE="$RF" PROJECTS_DB="$T/projects.db" ESCALATE_SUP_DIR="$T/sup" PATH="$T/bin:$PATH"
unset HERMES_KANBAN_TASK HERMES_KANBAN_RUN_ID
# run <profile> <tool> <tool_input json> [env...]: the guard's exit code; its stdout in $T/out
# T1 (F1 W4 r5): a run row (the guard on a payload, no process tree) is judged by ONE judge process that runs the guard's whole script with the
# row's environment, folder and payload, stdout and stderr as one stream and its exit code, as the process does. The first row of each (role,
# exit code) class also runs as a real process and both must agree; an agreement case with a planted-difference control is at the end.
# The process-tree rows (tree) and the rows that read the alert log stay real processes.
cat >"$T/rjudge.py" <<'PY'
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
    os.environ.clear(); os.environ.update(r["env"] if "env" in r else {**keep[4], **r["add"]}); os.chdir(r["cwd"])   # the full environment, or the one at start plus the row's own
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

mkdir -p "$T/rj/seen"; mkfifo "$T/rj/in" "$T/rj/oq"; python3 -I "$T/rjudge.py" "$T/rj/in" "$T/rj/oq" </dev/null >/dev/null 2>&1 & RJP=$!; : >"$T/rjrows"
RJENV=$(env | sort | md5sum)   # the judge's environment at start; a row is sent with its own variables only while the exported environment is the same
declare -A ROLE_OF; while IFS=$'\t' read -r p r; do ROLE_OF[$p]=$r; done < <(jq -r '.profiles | to_entries[] | "\(.key)\t\(.value.role)"' "$RF"); ROLE_FB=$(jq -r .fallback_role "$RF")
rjudge() {   # rjudge <guard> <payload> [env...]: exit code echoed, output in $T/out
  local g=$1 pay=$2 rc b; shift 2
  if [ "$(env | sort | md5sum)" = "$RJENV" ]; then
    jq -nc --arg p "$pay" --arg h "$g" --arg w "$PWD" '{hook: $h, payload: $p, cwd: $w, add: ($ARGS.positional | map(capture("^(?<key>[^=]*)=(?<value>.*)$"; "s")) | from_entries)}' --args "$@" >"$T/rj/in"
  else
    env -0 "$@" | jq -Rsc --arg p "$pay" --arg h "$g" --arg w "$PWD" '{hook: $h, payload: $p, cwd: $w, env: (split("\u0000") | map(select(length > 0) | capture("^(?<key>[^=]*)=(?<value>.*)$"; "s")) | from_entries)}' >"$T/rj/in"
  fi
  IFS=$'\t' read -r rc b <"$T/rj/oq"; printf '%s' "$b" | base64 -d >"$T/out"; echo "$rc"; }
run() { local prof=$1 tool=$2 in=$3 pay rc rrc; shift 3
  pay=$(jq -nc --arg p "$prof" --arg t "$tool" --argjson i "$in" '{hook_event_name: "pre_tool_call", tool_name: $t, tool_input: $i, profile: $p, extra: {}}')
  if [ -n "${REAL:-}" ]; then printf '%s' "$pay" | env "$@" python3 "$G" >"$T/out" 2>&1; echo $?; return; fi
  rc=$(rjudge "$G" "$pay" "$@"); printf '%s\t%s\n' "$(printf '%s' "$pay" | base64 -w0)" "$([ $# -gt 0 ] && printf '%s\0' "$@" | base64 -w0)" >>"$T/rjrows"
  local k="${ROLE_OF[${prof:-?}]:-$ROLE_FB}|$rc"   # the class: the profile's role (the fallback for a profile with no row) and the verdict
  if [ ! -e "$T/rj/seen/$k" ]; then
    : >"$T/rj/seen/$k"; cp "$T/out" "$T/out.judge"; printf '%s' "$pay" | env "$@" python3 "$G" >"$T/out" 2>&1; rrc=$?
    if [ "$rrc" != "$rc" ] || [ "$(sort "$T/out")" != "$(sort "$T/out.judge")" ]; then echo "     route agreement: $prof $tool exit $rc in the judge, $rrc as a process" >&2; echo 99; return; fi
  fi
  echo "$rc"; }
card() {  # card <id> <assignee> <open run id> <worker pid> <its fingerprint> [bound claim lock]: a running card whose run
  # is bound to that pid, as Hermes's worker_bound event records it (pid 0 = no binding recorded)
  jq -nc --arg id "$1" --arg a "$2" --argjson r "${3:-0}" --argjson pid "${4:-0}" --arg fp "${5:-}" --arg lock "${6:-host:1}" '
    {task: {id: $id, assignee: $a, status: "running"}, runs: (if $r == 0 then [] else [{id: $r, ended_at: null}] end),
     events: (if $pid == 0 then [] else [{kind: "claimed", run_id: $r, payload: {lock: "host:1"}},
       {kind: "worker_bound", run_id: $r, payload: {pid: $pid, claim_lock: $lock, started_at: $fp}}] end)}' >"$T/cards/$1.json"
  jq -nc --arg id "$1" '[{id: $id}]' >"$T/running-$2.json"; }
# fp <pid>: Hermes's fingerprint of a live process, computed here without bin/roles.py.
fp() { echo "$(cat /proc/sys/kernel/random/boot_id):$(sed 's/.*) //' /proc/1/stat | awk '{print $20}')|$(sed 's/.*) //' /proc/$1/stat | awk '{print $20}')"; }
# A real process tree (D48): a fake worker (its pid is what the card is bound to) runs the guard through a shell and an
# interpreter, as an agent loop's hook subprocess would be. Hermes sets the worker's ids after it started and strips them
# from the hook's environment, so the worker here exports nothing. A stranger process is alive but nobody's ancestor.
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
sleep 600 & STR=$!; trap 'kill $STR $RJP 2>/dev/null; rm -rf "$T"' EXIT
wn=0
# tree <profile> <tool_input json> <fixture>: the guard's exit code when run under a fresh fake worker; output in $T/out.
# The fixture (fx_<name> <worker pid> <its fingerprint>) writes the board state the test needs, with the worker's real pid.
tree() { local d="$T/w$RANDOM$RANDOM" w; P=$1; mkdir -p "$d"
  jq -nc --arg p "$1" --argjson i "$2" '{hook_event_name: "pre_tool_call", tool_name: "'"${TREE_TOOL:-kanban_complete}"'", tool_input: $i, profile: $p, extra: {}}' >"$d/payload"
  bash "$T/worker.sh" "$d" "$T/hookcall.py" "$G" & w=$!
  until [ -s "$d/pid" ]; do sleep 0.02; done
  fx_$3 "$(cat "$d/pid")" "$(fp "$(cat "$d/pid")")"; touch "$d/go"; wait $w; cp "$d/out" "$T/out"; cat "$d/rc"; }
fx_ok()      { card t_0000c0de "$P" 7 "$1" "$2"; }
fx_nobind()  { card t_0000c0de "$P" 7 0; }
fx_stranger() { card t_0000c0de "$P" 7 "$STR" "$(fp "$STR")"; }
fx_stale()   { card t_0000c0de "$P" 7 "$1" "$(fp "$STR")"; }
fx_lock()    { card t_0000c0de "$P" 7 "$1" "$2" host:2; }
fx_closed()  { fx_ok "$@"; jq -c '.runs[0].ended_at = 1' "$T/cards/t_0000c0de.json" >"$T/c.tmp" && mv "$T/c.tmp" "$T/cards/t_0000c0de.json"; }
fx_other()   { card t_0000c0de "$OTHER" 7 "$1" "$2"; }
fx_wrongcard() { fx_ok "$@"; card t_0000beef "$P" 8 "$STR" "$(fp "$STR")"; }
role() { jq -r --arg p "$1" '.profiles[$p].role' "$RF"; }
perm() { jq -r --arg p "$1" --arg k "$2" '.roles[.profiles[$p].role][$k]' "$RF"; }
want() { [ "$1" = true ] && echo 0 || echo 2; }
PROFILES=$(jq -r '.profiles | keys[]' "$RF")
WT=$(jq -r '.profiles | to_entries[] | select(.value.role as $r | $r != null) | .key' "$RF" | while read -r p; do
  [ "$(jq -r --arg p "$p" '.roles[.profiles[$p].role] | "\(.assignable) \(.workspace)"' "$RF")" = "true git-worktree" ] && echo "$p"; done | head -1)
RV=$(jq -r '.profiles | keys[]' "$RF" | while read -r p; do
  [ "$(jq -r --arg p "$p" '.roles[.profiles[$p].role] | "\(.assignable) \(.workspace)"' "$RF")" = "true read-parent-worktree" ] && echo "$p"; done | head -1)
CR=$(for p in $PROFILES; do [ "$(perm "$p" may_create_cards)" = true ] && echo "$p"; done | head -1)
[ -n "$WT" ] && [ -n "$CR" ] || { echo "FAIL roles.json has no assignable git-worktree role or no card-creating role"; echo "selftest FAIL (1)"; exit 1; }
good() { jq -nc --arg a "$1" '{title: "docs/scratch/phase4-local.md: \"phase 4 builder-local ok\"", assignee: $a, project: "proj-a",
  workspace_kind: "worktree", body: "Create file docs/scratch/phase4-local.md with the single line \"phase 4 builder-local ok\" and commit it in the worktree. Touch no other file. When done, request review."}'; }

# 1. Role x tool matrix, expectations from the table.
for p in $PROFILES; do
  r=$(role "$p")
  ok '[ "$(run "$p" delegate_task "{\"tasks\":[{\"goal\":\"x\"}]}")" = "$(want "$(perm "$p" may_delegate)")" ]' "$p ($r): delegate_task follows may_delegate=$(perm "$p" may_delegate)"
  ok '[ "$(run "$p" kanban_unblock "{\"task_id\":\"t_0000c001\"}")" = "$(want "$(perm "$p" may_unblock)")" ]' "$p ($r): kanban_unblock follows may_unblock=$(perm "$p" may_unblock)"
  ok '[ "$(run "$p" kanban_claim "{\"task_id\":\"t_0000c001\"}")" = "$(want "$(perm "$p" may_claim)")" ]' "$p ($r): kanban_claim follows may_claim=$(perm "$p" may_claim)"
  ok '[ "$(run "$p" kanban_create "$(good "$WT")")" = "$(want "$(perm "$p" may_create_cards)")" ]' "$p ($r): a valid card follows may_create_cards=$(perm "$p" may_create_cards)"
  ok '[ "$(tree "$p" "{\"task_id\":\"t_0000c0de\",\"summary\":\"x\"}" ok)" = "$(want "$(perm "$p" may_complete)")" ]' "$p ($r): completing its own card from its own worker's process tree follows may_complete=$(perm "$p" may_complete)"
done
ND=$(for p in $PROFILES; do [ "$(perm "$p" may_delegate)" = false ] && echo "$p"; done | head -1)
[ -n "$ND" ] && ok '[ "$(run "$ND" delegate_task "{}")" = 2 ] && grep -q "the $(role "$ND") role does not delegate" "$T/out" && ! grep -qw "$ND" "$T/out"' "a refused permission names the role in one line, not the profile"

# 2. Phase 4 bad cards, recorded arguments (assignees that were valid profiles are taken from the table).
B53=$(jq -nc --arg a "$WT" '{title: "docs/scratch/phase4-local.md: \"phase 4 builder-local ok\"", assignee: $a, body: "Create file docs/scratch/phase4-local.md with single line content \"phase 4 builder-local ok\", commit it in the worktree, then touch no other file. After commit, request review for the card.\n\nRequired command for the task: cd ~/.hermes/cache/scratch && mkdir -p docs && echo \"phase 4 builder-local ok\" > docs/phase4-local.md && (cd ~/.hermes/cache/scratch/docs && git add phase4-local.md && git commit -m \"Create phase 4 marker\" --allow-empty)", workspace_kind: "worktree", workspace_path: "/workspace/.worktrees/t_<generated_id>"}')
ok '[ "$(run "$CR" kanban_create "$B53")" = 2 ] && grep -q "remove workspace_path" "$T/out" && grep -q "set project to one of: proj-a" "$T/out" && grep -q "/.hermes/cache/scratch" "$T/out"' "t_53af3e0d as recorded: refused (placeholder path, no project, writes into ~/.hermes)"
ok '[ "$(run "$CR" kanban_create "$(good "$WT")")" = 0 ]' "t_53af3e0d corrected (project, worktree, no path, worktree-relative body): allowed"
ok '[ "$(run "$CR" kanban_create "{\"title\":\"phase4-local.md: marker commit\",\"assignee\":\"opencode\",\"body\":\"Create docs/scratch/phase4-local.md in the worktree with single line \\\"phase 4 builder-local ok\\\" and git commit it.\\n\\nCommand to run: cd ~/.hermes/cache/scratch/docs && echo \\\"phase 4 builder-local ok\\\" > phase4-local.md && git add phase4-local.md && git commit -m \\\"phase 4 marker\\\"\\n\\nNo additional files. After commit, request review of this card.\",\"workspace_kind\":\"worktree\",\"workspace_path\":\"/workspace/.worktrees/t_53af3e0d\"}")" = 2 ] && grep -q "is not an assignable worker" "$T/out" && grep -q "Valid assignees: " "$T/out"' "t_736d8641 as recorded: refused (opencode is no profile, another card's worktree)"
ok '[ "$(run "$CR" kanban_create "{\"assignee\":\"opencode\",\"body\":\"Create docs/scratch/phase4-local.md with content \\\"phase 4 builder-local ok\\\" and git commit. Then request review.\\n\\nRun in current worktree t_736d8641. Do not touch other files.\",\"title\":\"docs/scratch/phase4-local.md: marker commit\",\"workspace_kind\":\"worktree\",\"workspace_path\":\"/workspace/.worktrees/t_736d8641\"}")" = 2 ]' "t_06de4c40 as recorded: refused"
ok '[ "$(run "$CR" kanban_create "{\"title\":\"write dispatcher-discipline skill\",\"assignee\":\"opencode\",\"body\":\"Write /home/node/.hermes/skills/operational/dispatcher-discipline/SKILL.md with full content below, then commit to worktree.\",\"workspace_kind\":\"worktree\",\"workspace_path\":\"/workspace/.worktrees/t_dispatcher_discipline\"}")" = 2 ]' "t_04c1cdd7 as recorded: refused"
ok '[ "$(run "$CR" kanban_create "{\"title\":\"dispatcher-discipline skill with correct content\",\"assignee\":\"opencode\",\"body\":\"Patch /home/node/.hermes/skills/operational/dispatcher-discipline/SKILL.md with concise operational rules only.\\n\\nFile must exist at: /home/node/.hermes/skills/operational/dispatcher-discipline/SKILL.md\",\"workspace_kind\":\"worktree\",\"workspace_path\":\"/workspace/.worktrees/t_dispatcher_discipline\"}")" = 2 ]' "t_eb8c5e97 as recorded: refused"
ok '[ "$(run "$CR" kanban_create "$(jq -nc --arg a "$WT" --arg b "$B" '"'"'{title: "Create phase4-test.md in worktree", assignee: $a, board: $b, project: "proj-a", workspace_kind: "worktree", body: "x"}'"'"')")" = 0 ]' "t_fbfdaf63 recorded form (project, worktree, no path, board named): allowed"

# 3. Card rules, one at a time on top of a valid card.
# try <jq filter on the valid card> <expected exit> <text the message must hold, or ""> <label>
try() { local c="$(good "$WT" | jq -c "$1")" exp="$2" needle="$3"
  ok '[ "$(run "$CR" kanban_create "$c")" = "$exp" ] && { [ -z "$needle" ] || grep -qF -- "$needle" "$T/out"; }' "$4"; }
try 'del(.project)' 2 "proj-a" "no project: refused, listing the board's projects"
try '.project = "proj-zzz"' 2 "" "a project not bound to the board: refused"
try '.project = "proj-old"' 2 "" "an archived project: refused"
try '.project = "p_0000aaaa"' 0 "" "the project by id: allowed"
try 'del(.workspace_kind)' 2 "workspace_kind to worktree" "no workspace_kind (Hermes default scratch): refused"
for w in /workspace /workspace/.worktrees/t_0000abcd /tmp/x /home/node/x; do
  try ".workspace_path = \"$w\"" 2 "remove workspace_path" "worktree role with workspace_path $w: refused"
done
try '.model = "some-other-model"' 2 "remove model" "a model override the role does not allow: refused"
try '.provider = "other"' 2 "remove provider" "a provider override the role does not allow: refused"
try '.body = "Edit /workspace/docs/hermes-local/soul/default.md"' 2 "protected" "a body pointing at a protected repo path: refused"
try '.body = "update the file /workspace/src/app.js"' 2 "main checkout" "a body pointing into the main checkout: refused"
try '.body = "copy ~/.claude/settings.json and $HOME/.config/opencode/x"' 2 "protected" "a body pointing at ~/.claude or \$HOME/.config/opencode: refused"
try '.body = "write it under /tmp/notes.md and cd src/ && npm test"' 0 "" "worktree-relative and /tmp paths: allowed"
if [ -n "$RV" ]; then
  ok '[ "$(run "$CR" kanban_create "{\"title\":\"review\",\"assignee\":\"$RV\",\"parents\":[\"t_0000a001\"],\"workspace_kind\":\"dir\",\"workspace_path\":\"/workspace/.worktrees/t_0000a001\",\"body\":\"review it\"}")" = 0 ]' "parent-worktree role on its parent card's worktree: allowed"
  ok '[ "$(run "$CR" kanban_create "{\"title\":\"review\",\"assignee\":\"$RV\",\"parents\":[\"t_0000a001\"],\"workspace_kind\":\"dir\",\"workspace_path\":\"/workspace/.worktrees/t_0000a002\",\"body\":\"review it\"}")" = 2 ]' "parent-worktree role on an unrelated card's worktree: refused"
  ok '[ "$(run "$CR" kanban_create "{\"title\":\"review\",\"assignee\":\"$RV\",\"workspace_kind\":\"dir\",\"workspace_path\":\"/workspace\",\"body\":\"review it\"}")" = 2 ]' "parent-worktree role on /workspace: refused"
fi
# 4. Self-modification: path-based, plus the role-and-kind rule for path-less cards.
try '.title = "write a dispatcher-discipline skill" | .body = "write it into ~/.hermes/skills/dispatcher-discipline/SKILL.md"' 2 "protected" "write a dispatcher-discipline skill into ~/.hermes/skills: refused"
try ".title = \"write $(role "$CR")-discipline skill\" | .body = \"keep it short\"" 2 "own configuration" "a path-less card asking for a skill for the creator's own role: refused"
DN=$(jq -r --arg p "$CR" '.profiles[$p].display_name // empty' "$RF")
[ -n "$DN" ] && try ".title = \"new hook for $DN\" | .body = \"x\"" 2 "own configuration" "a path-less card asking for a hook for the creator by its display name: refused"
try '.title = "add a skills screen to the app" | .body = "Add a skills screen to the app in src/screens/skills.vue, with tests."' 0 "" "add a skills screen to the app in src/: allowed"
# 5. Binding unreadable: fail closed with STL-GRD-602 and one alerts.log line.
mkdir -p "$T/sup/logs"; : >"$T/sup/logs/alerts.log"
ok '[ "$(run "$CR" kanban_create "$(good "$WT")" PROJECTS_DB=$T/missing.db)" = 2 ] && grep -q "STL-GRD-602" "$T/out" && [ "$(grep -c "^STL-GRD-602" "$T/sup/logs/alerts.log")" = 1 ]' "projects.db unreadable: refused with STL-GRD-602, one alerts.log line"

# 6. Completion identity (for every role that may complete): proven from the board's worker_bound event and the hook's
# ancestry, never from environment variables.
for p in $PROFILES; do
  [ "$(perm "$p" may_complete)" = true ] || continue
  : >"$T/sup/logs/alerts.log"
  ok '[ "$(tree "$p" "{\"task_id\":\"t_0000c0de\"}" ok)" = 0 ] && [ ! -s "$T/sup/logs/alerts.log" ]' "$p: own card, run bound to the worker three levels above the hook (real process tree): allowed, no alert"
  ok '[ "$(tree "$p" "{}" ok)" = 0 ]' "$p: own card by the default task id (the profile's running card): allowed"
  while IFS='|' read -r fx needle label; do
    : >"$T/sup/logs/alerts.log"
    ok '[ "$(tree "$p" "{\"task_id\":\"t_0000c0de\"}" "$fx")" = 2 ] && grep -q "STL-GRD-601" "$T/out" && grep -qF -- "$needle" "$T/out" && [ "$(grep -c "^STL-GRD-601" "$T/sup/logs/alerts.log")" = 1 ]' "$p: $label: refused, STL-GRD-601 names the failed proof, one alerts.log line"
  done <<'LIST'
nobind|has no recorded worker process|run bound to no worker process (ids missing from every ancestor)
stranger|is not an ancestor of this call|run bound to a process that is not an ancestor
stale|start time differs|run bound to an ancestor pid with another start time (recycled pid)
lock|claim lock|worker bound under another claim lock
closed|has no open run|a closed run
LIST
  : >"$T/sup/logs/alerts.log"
  ok '[ "$(tree "$p" "{\"task_id\":\"t_0000beef\"}" wrongcard)" = 2 ] && grep -q "is not an ancestor" "$T/out"' "$p: a card id that is not the worker's own card (bound to another process): refused"
  ok '[ "$(tree "$p" "{}" nobind)" = 2 ] && grep -q "STL-GRD-601" "$T/out"' "$p: default task id with no bound run: refused"
  card t_0000c0de "$p" 7 "$STR" "$(fp "$STR")"
  ok '[ "$(run "$p" kanban_complete "{\"task_id\":\"t_0000c0de\"}" HERMES_KANBAN_TASK=t_0000c0de HERMES_KANBAN_RUN_ID=7)" = 2 ] && grep -q "is not an ancestor" "$T/out"' "$p: ids set only in the command the model runs (not an ancestor's): refused"
  card t_0000c0de "$p" 7 0
  ok '[ "$(run "$p" kanban_complete "{\"task_id\":\"t_0000c0de\"}" HERMES_KANBAN_TASK=t_0000c0de HERMES_KANBAN_RUN_ID=7)" = 2 ] && grep -q "has no recorded worker process" "$T/out"' "$p: ids in the environment but no run bound to any process: refused"
  for q in $PROFILES; do [ "$q" = "$p" ] && continue
    OTHER=$q
    ok '[ "$(tree "$p" "{\"task_id\":\"t_0000c0de\"}" other)" = 2 ] && grep -q "is assigned to" "$T/out"' "$p: a card assigned to another profile, run bound to this worker: refused"
  done
done
ok '[ "$(run "$CR" kanban_complete "{\"task_id\":\"t_0000c0de\"}" PATH=/usr/bin:/bin)" = 2 ]' "kanban show unavailable: refused"
: >"$T/sup/logs/alerts.log"   # RT4-13: a made-up task_id never reaches alerts.log, a page or its dedupe key as raw text
CP=$(for q in $PROFILES; do [ "$(perm "$q" may_complete)" = true ] && echo "$q" && break; done)
ok '[ "$(run "$CP" kanban_complete "{\"task_id\":\"x@here card=t_0000c0de\"}")" = 2 ] && grep -q "card=.not a card id." "$T/sup/logs/alerts.log" && ! grep -q "@here" "$T/sup/logs/alerts.log"' "a made-up task_id is logged as 'not a card id', never as its text (RT4-13)"

# 7. A profile with no row, and a malformed table: nothing opens.
echo '{"profiles": {}, "roles": {}}' >"$T/bad.json"
for t in kanban_create kanban_complete kanban_unblock kanban_claim delegate_task; do
  ok '[ "$(run x-unlisted $t "$(good "$WT")" HERMES_KANBAN_TASK=t_0000c0de HERMES_KANBAN_RUN_ID=7)" = 2 ] && grep -q "STL-CFG-303" "$T/out"' "profile with no row: $t refused (STL-CFG-303)"
  ok '[ "$(run "$CR" $t "$(good "$WT")" ROLES_FILE=$T/bad.json)" = 2 ]' "malformed roles.json: $t refused"
done
ok '[ "$(echo not-json | python3 "$G" >/dev/null 2>&1; echo $?)" = 2 ]' "garbage payload: refused"
ok '[ "$(run "$CR" kanban_show "{\"task_id\":\"t_0000c0de\"}")" = 0 ]' "an ungated tool passes through"
# 8. The guard source names no profile, role-table value or display name.
# (The root profile's name is Hermes's own word "default", so it is not searched for.)
names=$(jq -r '(.profiles | to_entries[] | select(.value.dir != "") | .key), (.profiles[] | .display_name // empty)' "$RF" | sort -u | paste -sd'|')
# Owner decision 2026-11-04: Hermes API words that equal a profile name are listed in docs/hermes-local/hardcode-allow.json.
# Fails closed (verifier note): the scan must read all three files and print text before grep looks for names.
ok 'src=$(python3 - "$G" "$S/roles.py" "$S/watchdog_settings.py" <<PY
import json, sys
allow = json.load(open("/workspace/docs/hermes-local/hardcode-allow.json"))["allow"]
for p, rel in zip(sys.argv[1:], ("bin/role-guard.py", "bin/roles.py", "bin/watchdog_settings.py")):
    t = open(p).read()
    for a in allow:
        if a["file"] == rel:
            t = t.replace(a["text"], "")
    print(t)
PY
) && [ -n "$src" ] && [ -n "$names" ] && ! grep -Eiw "$names" <<<"$src"' "role-guard.py, roles.py and watchdog_settings.py (D47) name no profile or display name (Hermes API words in hardcode-allow.json aside)"
# K1 round 2 (verifier): the hook's HERMES_KANBAN_BOARD does not change the board: the card is proven on the stack's board
CP=$(for p in $PROFILES; do [ "$(perm "$p" may_complete)" = true ] && echo "$p"; done | head -1)
ok '[ "$(HERMES_KANBAN_BOARD=other tree "$CP" "{\"task_id\":\"t_0000c0de\"}" ok)" = 0 ] && [ "$(tree "$CP" "{\"task_id\":\"t_0000c0de\"}" ok)" = 0 ]' "HERMES_KANBAN_BOARD=other in the hook's environment: still proven on the stack's board, allowed"
# K2: a refused completion of the card's own open run, unproven, is the stack's fault, not the worker's: the wording says so and
# tells the worker to block needs_input (STL-GRD-601 in the reason). Otherwise the old wording stands, and every needle above holds.
KP=$(for p in $PROFILES; do [ "$(perm "$p" may_complete)" = true ] && echo "$p"; done | head -1)
ok '[ "$(tree "$KP" "{\"task_id\":\"t_0000c0de\"}" stranger)" = 2 ] && grep -qF "fault in the stack" "$T/out" && grep -qF "kind needs_input" "$T/out" && grep -qF "STL-GRD-601: the stack could not identify this worker run" "$T/out" && grep -qF "is not an ancestor of this call" "$T/out"' "K2: an open run whose worker is not an ancestor: the stack-fault wording, tells the worker to block needs_input, the needle kept"
ok '[ "$(tree "$KP" "{\"task_id\":\"t_0000c0de\"}" nobind)" = 2 ] && grep -qF "fault in the stack" "$T/out" && grep -qF "has no recorded worker process" "$T/out"' "K2: an open run with no worker bound: the stack-fault wording, the needle kept"
ok '[ "$(tree "$KP" "{\"task_id\":\"t_0000c0de\"}" closed)" = 2 ] && grep -qF "the owner can complete a stuck card" "$T/out" && ! grep -qF "fault in the stack" "$T/out"' "K2: no open run (closed): the old wording, no stack-fault claim"
# K8: a card is reviewed by a reviewing role (may_review), never by its own builder (t_14f8f08b reviewed itself). The payload
# is the tool's real shape (task_id, summary, reviewer, metadata). Expectations come from the table, per profile pair.
REVS=$(for q in $PROFILES; do [ "$(perm "$q" may_review)" = true ] && echo "$q"; done)
ok '[ -n "$REVS" ]' "K8: the role table has a reviewing profile (may_review true on a role)"
rr() { jq -nc --arg r "$1" '{task_id: "t_0000c001", summary: "done, tests pass", reviewer: $r, metadata: {commit: "abc1234"}}'; }
# D101: a profile's review_callers (absent = anyone) limits which roles may name it; REVS_FOR p = the reviewers p's role may name
callers_ok() { jq -e --arg q "$2" --arg r "$(role "$1")" '(.profiles[$q].review_callers // null) as $c | ($c == null) or ($c | index($r) != null)' "$RF" >/dev/null; }
REVS_FOR() { for q in $REVS; do [ "$q" != "$1" ] && callers_ok "$1" "$q" && echo "$q"; done; }
for p in $PROFILES; do
  for q in $PROFILES; do
    if [ "$(perm "$q" may_review)" = true ] && [ "$q" != "$p" ] && callers_ok "$p" "$q"; then
      ok '[ "$(run "$p" kanban_request_review "$(rr "$q")")" = 0 ]' "K8: $p ($(role "$p")) asks $q ($(role "$q")) to review: allowed"
    elif [ "$(perm "$q" may_review)" = true ] && [ "$q" != "$p" ]; then
      ok '[ "$(run "$p" kanban_request_review "$(rr "$q")")" = 2 ] && grep -q "review_callers" "$T/out"' "K8: $p ($(role "$p")) asks $q ($(role "$q")) to review: refused by the owner's review_callers setting (D101)"
    else
      ok '[ "$(run "$p" kanban_request_review "$(rr "$q")")" = 2 ] && grep -q "its own builder" "$T/out" && for r in $(REVS_FOR "$p"); do grep -qF "$r" "$T/out" || exit 1; done' "K8: $p ($(role "$p")) asks $q ($(role "$q")) to review: refused, valid reviewers named"
    fi
  done
  ok '[ "$(run "$p" kanban_request_review "{\"task_id\":\"t_0000c001\",\"summary\":\"x\"}")" = 2 ] && grep -q "names the profile that reviews the card" "$T/out" && for r in $(REVS_FOR "$p"); do grep -qF "$r" "$T/out" || exit 1; done' "K8: $p: no reviewer: refused, valid reviewers named"
  for bad in '""' 'null' '123' '["'"$(echo $REVS | cut -d" " -f1)"'"]' '"nobody-x"' '"REVIEWER"' '" reviewer"'; do
    ok '[ "$(run "$p" kanban_request_review "{\"task_id\":\"t_0000c001\",\"reviewer\":$bad}")" = 2 ]' "K8: $p: reviewer=$bad: refused"
  done
  ok '[ "$(run "$p" kanban_request_review "\"not-an-object\"")" = 2 ] && [ "$(run "$p" kanban_request_review "[]")" = 2 ]' "K8: $p: tool_input not an object, or empty: refused"
done
# An unreadable table refuses every request, even one naming a valid reviewer (STL-CFG-303).
RV1=$(echo $REVS | cut -d" " -f1)
echo not-json >"$T/garbage.json"; jq 'del(.roles[].may_review)' "$RF" >"$T/nomr.json"; jq '.roles[].may_review = "yes"' "$RF" >"$T/strmr.json"
for tf in "$T/bad.json" "$T/garbage.json" "$T/nope.json" "$T/nomr.json" "$T/strmr.json"; do
  for p in $PROFILES; do
    ok '[ "$(run "$p" kanban_request_review "$(rr "$RV1")" ROLES_FILE=$tf)" = 2 ] && grep -q "STL-CFG-303" "$T/out"' "K8: $p: request naming $RV1 with the table ${tf##*/}: refused (STL-CFG-303)"
  done
done
# Not hard-coded to the stack's profiles: a second reviewing profile in the table is accepted and listed; with none, the
# refusal says so; a profile of another role that gets may_review is accepted.
jq --arg r "$(role "$RV1")" '.profiles["qa-x"] = {role: $r, soul: "reviewer.md"} | .sandbox.boxed_profiles += ["qa-x"]' "$RF" >"$T/two.json"
ok '[ "$(run "$WT" kanban_request_review "$(rr qa-x)" ROLES_FILE=$T/two.json)" = 0 ] && [ "$(run "$WT" kanban_request_review "$(rr "$RV1")" ROLES_FILE=$T/two.json)" = 0 ] && [ "$(run "$WT" kanban_request_review "$(rr "$WT")" ROLES_FILE=$T/two.json)" = 2 ] && grep -qF qa-x "$T/out" && grep -qF "$RV1" "$T/out"' "K8: a second reviewing profile in the table: accepted, and listed in a refusal"
ok '[ "$(run "$RV1" kanban_request_review "$(rr qa-x)" ROLES_FILE=$T/two.json)" = 0 ] && [ "$(run qa-x kanban_request_review "$(rr qa-x)" ROLES_FILE=$T/two.json)" = 2 ] && grep -qF "$RV1" "$T/out" && ! grep -qF "ask the owner" "$T/out"' "K8: one reviewing profile may hand to the other, never to itself"
jq '.roles[].may_review = false' "$RF" >"$T/nobody.json"
ok '[ "$(run "$WT" kanban_request_review "$(rr "$RV1")" ROLES_FILE=$T/nobody.json)" = 2 ] && grep -qF "ask the owner" "$T/out"' "K8: no profile may review: refused, says to ask the owner"
jq --arg w "$(role "$WT")" '.roles[$w].may_review = true' "$RF" >"$T/bmr.json"
OC=$(for q in $PROFILES; do [ "$q" != "$WT" ] && echo "$q" && break; done)
ok '[ "$(run "$OC" kanban_request_review "$(rr "$WT")" ROLES_FILE=$T/bmr.json)" = 0 ]' "K8: the table decides, not the role name: a builder role with may_review true is accepted as reviewer by another profile"
ok '[ "$(run "$WT" kanban_request_review "$(rr "$WT")" ROLES_FILE=$T/bmr.json)" = 2 ]' "K8: even then a profile never reviews its own card"
# Real path (D48): the request comes from a fake worker's process tree (worker, shell, interpreter, guard) with no ids in the
# environment, as Hermes runs the hook.
KB=$(for q in $PROFILES; do [ "$(perm "$q" may_review)" != true ] && [ "$(perm "$q" may_create_cards)" != true ] && echo "$q" && break; done)
KB=${KB:-$WT}
ok '[ "$(TREE_TOOL=kanban_request_review tree "$KB" "$(rr "$RV1")" ok)" = 0 ]' "K8: from a fake worker's process tree: $KB naming $RV1: allowed"
ok '[ "$(TREE_TOOL=kanban_request_review tree "$KB" "$(rr "$KB")" ok)" = 2 ] && grep -qF "$RV1" "$T/out" && [ "$(TREE_TOOL=kanban_request_review tree "$KB" "{\"task_id\":\"t_0000c001\"}" ok)" = 2 ]' "K8: from a fake worker's process tree: its own profile, or no reviewer: refused"
# D101, the "card" setting: a role that is not listed in a reviewer's review_callers may still name it when the card's own body (written by
# whoever created the card, never by a worker) says `Review-by: <that profile>` and review_callers contains "card".
RCP=$(jq -r '[.profiles | to_entries[] | select(.value.review_callers != null) | .key][0] // empty' "$RF")
if [ -n "$RCP" ]; then
  CB=$(role "$KB")
  fx_reviewby() { fx_ok "$@"; jq -c --arg b "$(printf 'Do the task.\n  Review-by:  %s \nCheck: none: x' "$RCP")" '.task.body = $b' "$T/cards/t_0000c0de.json" >"$T/c.tmp" && mv "$T/c.tmp" "$T/cards/t_0000c0de.json"; }
  fx_reviewby_other() { fx_ok "$@"; jq -c --arg b "Review-by: $RV1" '.task.body = $b' "$T/cards/t_0000c0de.json" >"$T/c.tmp" && mv "$T/c.tmp" "$T/cards/t_0000c0de.json"; }
  rbc() { jq -nc --arg r "$RCP" '{task_id: "t_0000c0de", reviewer: $r}'; }
  jq --arg q "$RCP" '.profiles[$q].review_callers |= map(select(. != "card"))' "$RF" >"$T/nocard.json"
  jq -e --arg q "$RCP" '.profiles[$q].review_callers | index("card") != null' "$RF" >/dev/null && HAVE_CARD=1 || HAVE_CARD=
  if [ -n "$HAVE_CARD" ] && [ "$(jq -r --arg q "$RCP" --arg r "$CB" '.profiles[$q].review_callers | index($r) == null' "$RF")" = true ]; then
    ok '[ "$(TREE_TOOL=kanban_request_review tree "$KB" "$(rbc)" ok)" = 2 ] && grep -q "review_callers" "$T/out"' "D101: $KB naming $RCP when the card says nothing about it: refused"
    ok '[ "$(TREE_TOOL=kanban_request_review tree "$KB" "$(rbc)" reviewby)" = 0 ]' "D101: $KB naming $RCP when the card's body says Review-by: $RCP (any spacing): allowed"
    ok '[ "$(TREE_TOOL=kanban_request_review tree "$KB" "$(rbc)" reviewby_other)" = 2 ]' "D101: the card names another reviewer: naming $RCP is still refused"
    ok '[ "$(ROLES_FILE=$T/nocard.json TREE_TOOL=kanban_request_review tree "$KB" "$(rbc)" reviewby)" = 2 ]' "D101: the owner removes \"card\" from the setting: the same request is refused (the setting takes effect)"
    ok '[ "$(TREE_TOOL=kanban_request_review tree "$KB" "$(rbc)" stranger)" = 2 ]' "D101: a request for a card that is not the caller's own running card (no proof) is refused"
    rb1() { jq -nc --arg r "$RV1" '{task_id: "t_0000c0de", reviewer: $r}'; }
    ok '[ "$(TREE_TOOL=kanban_request_review tree "$KB" "$(rb1)" reviewby)" = 2 ] && grep -q "Review-by" "$T/out"' "S6I-04: the card says Review-by: $RCP, so naming another reviewer ($RV1) is refused (the line binds the caller)"
    ok '[ "$(TREE_TOOL=kanban_request_review tree "$KB" "$(rb1)" reviewby_other)" = 0 ]' "S6I-04 control: the card says Review-by: $RV1 and the caller names $RV1: allowed"
  fi
fi
# A1-01: a role that takes cards, or a profile with no row, comments on its own proven running card only. Fake worker's
# process tree again (D48); the coordinator (the role with may_answer_for_owner) comments anywhere.
DISP=$(for q in $PROFILES; do [ "$(jq -r --arg p "$q" '.roles[.profiles[$p].role].may_answer_for_owner' "$RF")" = true ] && echo "$q" && break; done)   # W2-RT-01: the field, never `assignable`
cm() { printf '{"task_id":"%s","comment":"UNBLOCK: escalation reply\\nGo on."}' "$1"; }
export TREE_TOOL=kanban_comment
ok '[ "$(tree "$WT" "$(cm t_0000c0de)" ok)" = 0 ]' "A1-01: $WT comments on its own proven card: allowed"
ok '[ "$(tree "$WT" "{\"comment\":\"x\"}" ok)" = 0 ] && [ "$(tree "$WT" "{\"task_id\":\"\",\"comment\":\"x\"}" ok)" = 0 ]' "A1-01: no task_id: not the guard's business (Hermes rejects it itself): allowed"
ok '[ "$(tree "$WT" "$(cm t_0000beef)" wrongcard)" = 2 ] && grep -qF "not your own running card" "$T/out"' "A1-01: a card the caller is assigned to but not running as (no worker binding): refused"
ok '[ "$(tree "$WT" "$(cm t_0000c0de)" other)" = 2 ] && grep -qF "assigned to" "$T/out"' "A1-01: a card assigned to another profile: refused, forged UNBLOCK text or not"
ok '[ "$(tree "$WT" "$(cm t_0000c0de)" nobind)" = 2 ] && [ "$(tree "$WT" "$(cm t_0000c0de)" stranger)" = 2 ]' "A1-01: own card without a bound worker run in the caller's ancestors: refused"
ok '[ "$(tree "$WT" "{\"task_id\":[\"t_0000c0de\"],\"comment\":\"x\"}" ok)" = 2 ] && [ "$(tree "$WT" "{\"task_id\":\" t_0000c0de\",\"comment\":\"x\"}" ok)" = 2 ]' "A1-01: a task_id that is not exactly a card id: refused (fail closed)"
ok '[ "$(run no-such-profile kanban_comment "$(cm t_0000c001)")" = 2 ] && [ "$(run no-such-profile kanban_comment "{\"comment\":\"x\"}")" = 0 ]' "A1-01: a profile with no row: cross-card refused; no task_id left to Hermes: allowed"
[ -n "$DISP" ] && ok '[ "$(run "$DISP" kanban_comment "$(cm t_0000c001)")" = 0 ]' "A1-01: $DISP ($(role "$DISP"), may_answer_for_owner) comments on any card: allowed"
[ -n "$RV1" ] && ok '[ "$(tree "$RV1" "$(cm t_0000beef)" wrongcard)" = 2 ]' "A1-01: the reviewing role is a worker too: other card refused"
ok '[ -n "$DISP" ] && [ "$(jq "[.roles[] | select(.may_answer_for_owner == true)] | length" "$RF")" = 1 ]' "W2-RT-01: exactly one role has may_answer_for_owner, and a profile has it ($DISP)"
# W2-RT-01: a role without the field is a worker for this rule, listed or not, whatever its `assignable`: foreign comment refused
for r in $(jq -r '.roles | to_entries[] | select(.value.may_answer_for_owner != true) | .key' "$RF"); do
  # a served role needs explicit platform_toolsets (W4 r3 table rule); one that has none gets those of the first boxed profile's role
  jq --arg r "$r" '. as $d | .profiles["qa-p"] = {"role": $r} | .sandbox.boxed_profiles += ["qa-p"] | .roles[$r].platform_toolsets |= (if [(. // {})[] | length] | add // 0 > 0 then . else $d.roles[$d.profiles[$d.sandbox.boxed_profiles[0]].role].platform_toolsets end)' "$RF" >"$T/qa-t.json"
  ok '[ "$(ROLES_FILE=$T/qa-t.json run qa-p kanban_comment "$(cm t_0000c001)")" = 2 ] && grep -qF "not your own running card" "$T/out"' "W2-RT-01: a profile with role $r (no may_answer_for_owner) is refused a foreign comment by the own-card proof"
done
unset TREE_TOOL
GM=$(sed -n 's/^GUARDS = \[("pre_tool_call", "\(.*\)",$/\1/p' /workspace/bin/register-escalation-hook.sh)
ok '[ -n "$GM" ] && [[ kanban_comment =~ $GM ]] && [[ kanban_complete =~ $GM ]] && ! [[ kanban_show =~ $GM ]]' "A1-01: the registered role-guard matcher covers kanban_comment (and still not kanban_show)"
# T1 (r5): the two routes agree on every 10th run row (the judge and a real guard process, the same row), and a planted difference (the judge
# given a copy of the guard whose refusal reads otherwise) is caught
ragree() { local n=0 i=0 p e pay rc rrc args
  while IFS=$'\t' read -r p e; do i=$((i+1)); [ $((i % 10)) = 1 ] || continue
    mapfile -d '' -t args < <(printf '%s' "$e" | base64 -d); pay=$(printf '%s' "$p" | base64 -d)
    rc=$(rjudge "$1" "$pay" "${args[@]}"); cp "$T/out" "$T/ag.judge"
    [ -f "$T/ag.real.$i" ] || { printf '%s' "$pay" | env "${args[@]}" python3 "$G" >"$T/ag.real.$i" 2>&1; echo $? >"$T/ag.rc.$i"; }   # the process run once per row, kept for the control
    { [ "$rc" = "$(<"$T/ag.rc.$i")" ] && [ "$(sort "$T/ag.real.$i")" = "$(sort "$T/ag.judge")" ]; } || n=$((n+1))
  done < <(cat "$T/rjrows"); echo "$n"; }
sed 's/"action": "block"/"action": "blocked"/' "$G" >"$T/rg-planted.py"
RN=$(wc -l <"$T/rjrows"); RD=$(ragree "$G"); RX=$(ragree "$T/rg-planted.py")
ok '[ "$RN" -ge 100 ] && [ "$RD" = 0 ]' "T1 route agreement: every 10th of $RN run rows judged in one process gives the same exit code and output as a real guard process ($RD differ)"
ok '[ "$RX" -gt 0 ]' "T1 route agreement, negative control: a planted difference in the judge's guard is caught ($RX differ)"
printf 'QUIT\n' >"$T/rj/in"; wait "$RJP"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
