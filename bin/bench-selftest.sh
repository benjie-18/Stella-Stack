#!/usr/bin/env bash
# Hermetic self-test for the R1.4 benchmark suite (T10): bench/ holds the tasks, bin/bench.sh validates them and
# measures a finished card. Stub hermes and a scratch escalations log; no board, no network, no model.
set -u
B=/workspace/bin/bench.sh; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }

# 1. the shipped suite: every task is red at its start and green with its reference solution
out=$("$B" check 2>&1); rc=$?
ok '[ $rc = 0 ]' "check passes on the shipped suite (rc $rc)"
ok 'printf "%s\n" "$out" | grep -q "^5 tasks, 5 in the subset"' "five tasks, five in the subset"
ok '[ "$("$B" list --subset | wc -l)" = 5 ]' "list --subset prints five ids"
ok 'jq -e "(.missing | length) > 0" /workspace/bench/suite.json >/dev/null' "suite.json names the categories not written yet"

# 2. negative controls: a task already green at its start, a task whose solution stays red, a missing field
mk() { rm -rf "$T/b"; mkdir -p "$T/b/tasks/x/repo" "$T/b/tasks/x/solution"
  jq -n --arg c "$1" '{id:"x",category:"bugfix",title:"t",body:"b",check:$c,protected:[],subset:true}' >"$T/b/tasks/x/task.json"
  echo 1 >"$T/b/tasks/x/repo/f"; echo 2 >"$T/b/tasks/x/solution/f"; echo '{"missing":[]}' >"$T/b/suite.json"; }
mk 'test -f f'; ok '! BENCH_DIR=$T/b "$B" check >/dev/null 2>&1' "refuses a task that passes before any work"
mk 'test "$(cat f)" = 3'; ok '! BENCH_DIR=$T/b "$B" check >/dev/null 2>&1' "refuses a task its own solution does not fix"
mk 'test "$(cat f)" = 2'; ok 'BENCH_DIR=$T/b "$B" check >/dev/null 2>&1' "accepts a red-then-green task"
jq 'del(.check)' "$T/b/tasks/x/task.json" >"$T/b/t" && mv "$T/b/t" "$T/b/tasks/x/task.json"
ok '! BENCH_DIR=$T/b "$B" check >/dev/null 2>&1' "refuses a task with no check"

# 3. metrics of a finished card from the board and the escalations log
mkdir -p "$T/bin"; cat >"$T/bin/hermes" <<'S'
#!/usr/bin/env bash
cat <<J
{"task":{"id":"t_1","status":"done","assignee":"w","created_at":1000,"completed_at":1090},
 "runs":[{"profile":"w","outcome":"crashed"},{"profile":"w","outcome":"review_requested"},{"profile":"r","outcome":"completed"}]}
J
S
chmod +x "$T/bin/hermes"
cat >"$T/esc.log" <<'L'
{"card":"t_1","event":"START","cost_usd":null}
{"card":"t_1","event":"OK","cost_usd":0.25}
{"card":"t_2","event":"START","cost_usd":null}
{"card":"t_2","event":"OK","cost_usd":9}
{"card":"t_1","event":"START","cost_usd":null}
{"card":"t_1","event":"FAIL","cost_usd":0.5}
L
m=$(PATH="$T/bin:$PATH" ESCALATIONS_LOG="$T/esc.log" "$B" metrics t_1 2>/dev/null)
ok '[ "$(jq -r .status <<<"$m")" = done ]' "metrics: status"
ok '[ "$(jq -r .wall_s <<<"$m")" = 90 ]' "metrics: wall time from the card's own timestamps"
ok '[ "$(jq -r .retries <<<"$m")" = 1 ]' "metrics: retries = the assignee's runs beyond the first"
ok '[ "$(jq -r .escalations <<<"$m")" = 2 ]' "metrics: escalations = START lines of this card only"
ok '[ "$(jq -r .cost_usd <<<"$m")" = 0.75 ]' "metrics: cost sums this card's calls only"
ok '! PATH="$T/bin:$PATH" ESCALATIONS_LOG="$T/none" "$B" metrics >/dev/null 2>&1' "metrics without a card id fails"


# 4. fix round 1 (red-team S6C-01, S6C-10; verifier): the repo reset keeps card worktrees out of the commit, and the branch check
# runs boxed: worker code cannot write outside its folder or see the home, a symlink in the branch is refused
mkb() {  # mkb <check>: a bench dir with task x, and a repo whose branch "card" holds the worker's files
  rm -rf "$T/v"; mkdir -p "$T/v/b/tasks/x/repo" "$T/v/b/tasks/x/solution"; echo '{"missing":[]}' >"$T/v/b/suite.json"
  jq -n --arg c "$1" '{id:"x",category:"c",title:"t",body:"b",check:$c,protected:["test.sh"],subset:true}' >"$T/v/b/tasks/x/task.json"
  printf '%s\n' 'test -f f' >"$T/v/b/tasks/x/repo/test.sh"; : >"$T/v/b/tasks/x/solution/f"; cp "$T/v/b/tasks/x/repo/test.sh" "$T/v/b/tasks/x/solution/test.sh"
  git init -q -b main "$T/v/r" && git -C "$T/v/r" -c user.name=t -c user.email=t@localhost commit -q --allow-empty -m s
  git -C "$T/v/r" checkout -q -b card; printf 'false\n' >"$T/v/r/test.sh"; : >"$T/v/r/f"; mkdir "$T/v/outside"; }
commit_card() { git -C "$T/v/r" add -A && git -C "$T/v/r" -c user.name=t -c user.email=t@localhost commit -q -m c; }
vf() { BENCH_DIR=$T/v/b "$B" verify "$T/v/r" card x; }
mkb 'bash test.sh'; commit_card
ok 'vf >/dev/null 2>&1' "verify: an honest branch passes, and the task's own test.sh replaces the worker's"
mkb 'bash test.sh'; printf 'echo pwned > %s/outside/marker\ntrue\n' "$T/v" >"$T/v/r/f.sh"; commit_card
mkb 'test -f f && sh f.sh >/dev/null 2>&1; test ! -e /home/node/.hermes && test -z "$(ls /workspace)"'; : >"$T/v/r/f"; printf 'echo pwned > %s/outside/marker\n' "$T/v" >"$T/v/r/f.sh"; commit_card
vf >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 0 ] && [ ! -e "$T/v/outside/marker" ]' "verify: worker code cannot write outside its folder, and the home and /workspace are hidden (rc $rc)"
mkb 'bash test.sh'; ln -sf "$T/v/outside/victim" "$T/v/r/test.sh"; : >"$T/v/outside/victim"; commit_card
vf >/dev/null 2>&1; rc=$?
ok '[ "$rc" != 0 ] && [ ! -s "$T/v/outside/victim" ]' "verify: a symlink in the branch is refused and nothing outside is written (rc $rc)"
mkb 'bash test.sh'; : >"$T/v/r/f"; rm "$T/v/r/test.sh"; mkdir "$T/v/r/d"; ln -s "$T/v/outside" "$T/v/r/d/l"; commit_card
ok '! vf >/dev/null 2>&1' "verify: a symlinked folder is refused too"
# the reset keeps a card worktree out of the start commit and keeps the worktree
mkb 'bash test.sh'; git -C "$T/v/r" checkout -q main; mkdir -p "$T/v/r/.worktrees"; git -C "$T/v/r" worktree add -q "$T/v/r/.worktrees/w1" -b wb 2>/dev/null; echo old >"$T/v/r/.worktrees/w1/keep"
BENCH_DIR=$T/v/b "$B" reset x "$T/v/r" >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 0 ] && [ "$(git -C "$T/v/r" ls-tree -r HEAD | grep -c "^160000")" = 0 ] && [ -f "$T/v/r/.worktrees/w1/keep" ] && [ -f "$T/v/r/test.sh" ]' "reset: the start commit has the task files, no worktree gitlink, and the old worktree survives (rc $rc)"

[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
