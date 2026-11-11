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
mk 'test -f f && echo "$BENCH_NONCE"'; ok '! BENCH_DIR=$T/b "$B" check >/dev/null 2>&1' "refuses a task that passes before any work"
mk 'test "$(cat f)" = 3 && echo "$BENCH_NONCE"'; ok '! BENCH_DIR=$T/b "$B" check >/dev/null 2>&1' "refuses a task its own solution does not fix"
mk 'test "$(cat f)" = 2 && echo "$BENCH_NONCE"'; ok 'BENCH_DIR=$T/b "$B" check >/dev/null 2>&1' "accepts a red-then-green task"
mk 'test "$(cat f)" = 2'; ok '! BENCH_DIR=$T/b "$B" check >/dev/null 2>&1' "S6C-06: refuses a task whose green run passes but prints no completion nonce"
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
  printf '%s\n' 'test -f f && echo "$BENCH_NONCE"' >"$T/v/b/tasks/x/repo/test.sh"; : >"$T/v/b/tasks/x/solution/f"; cp "$T/v/b/tasks/x/repo/test.sh" "$T/v/b/tasks/x/solution/test.sh"
  git init -q -b main "$T/v/r" && git -C "$T/v/r" -c user.name=t -c user.email=t@localhost commit -q --allow-empty -m s
  git -C "$T/v/r" checkout -q -b card; printf 'false\n' >"$T/v/r/test.sh"; : >"$T/v/r/f"; mkdir "$T/v/outside"; }
commit_card() { git -C "$T/v/r" add -A && git -C "$T/v/r" -c user.name=t -c user.email=t@localhost commit -q -m c; }
vf() { BENCH_DIR=$T/v/b "$B" verify "$T/v/r" card x; }
mkb 'bash test.sh'; commit_card
ok 'vf >/dev/null 2>&1' "verify: an honest branch passes, and the task's own test.sh replaces the worker's"
mkb 'bash test.sh'; printf 'echo pwned > %s/outside/marker\ntrue\n' "$T/v" >"$T/v/r/f.sh"; commit_card
mkb 'test -f f && sh f.sh >/dev/null 2>&1; test ! -e /home/node/.hermes && test -z "$(ls /workspace)" && echo "$BENCH_NONCE"'; : >"$T/v/r/f"; printf 'echo pwned > %s/outside/marker\n' "$T/v" >"$T/v/r/f.sh"; commit_card
vf >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 0 ] && [ ! -e "$T/v/outside/marker" ]' "verify: worker code cannot write outside its folder, and the home and /workspace are hidden (rc $rc)"
mkb 'bash test.sh'; ln -sf "$T/v/outside/victim" "$T/v/r/test.sh"; : >"$T/v/outside/victim"; commit_card
vf >/dev/null 2>&1; rc=$?
ok '[ "$rc" != 0 ] && [ ! -s "$T/v/outside/victim" ]' "verify: a symlink in the branch is refused and nothing outside is written (rc $rc)"
mkb 'bash test.sh'; : >"$T/v/r/f"; rm "$T/v/r/test.sh"; mkdir "$T/v/r/d"; ln -s "$T/v/outside" "$T/v/r/d/l"; commit_card
ok '! vf >/dev/null 2>&1' "verify: a symlinked folder is refused too"

# S6C-06: a branch that exits 0 before the test finishes does not pass; settle waits for a worker that is still running
mkb 'bash test.sh'; printf '%s\n' '. ./f.sh; test -f f && echo "$BENCH_NONCE"' >"$T/v/b/tasks/x/repo/test.sh"; : >"$T/v/r/f"; printf 'exit 0\n' >"$T/v/r/f.sh"; rm "$T/v/r/test.sh"; commit_card
ok '! vf >/dev/null 2>&1' "S6C-06: worker code that exits 0 before the test prints the nonce does not pass"
mkb 'bash test.sh'; printf '%s\n' '. ./f.sh; test -f f && echo "$BENCH_NONCE"' >"$T/v/b/tasks/x/repo/test.sh"; : >"$T/v/r/f"; : >"$T/v/r/f.sh"; rm "$T/v/r/test.sh"; commit_card
ok 'vf >/dev/null 2>&1' "S6C-06 control: the same task with honest worker code passes"
mkb 'bash test.sh'; printf '%s\n' 'echo ok; test -f f' >"$T/v/b/tasks/x/repo/test.sh"; : >"$T/v/r/f"; rm "$T/v/r/test.sh"; commit_card
ok '! vf >/dev/null 2>&1' "S6C-06: a test that prints a fixed word instead of the nonce does not pass"
sleep 2 & sp=$!; t0=$SECONDS; "$B" settle "$sp" 20; rc=$?
ok '[ "$rc" = 0 ] && [ $((SECONDS - t0)) -ge 1 ] && [ $((SECONDS - t0)) -lt 15 ]' "settle: returns once the worker process has exited (rc $rc)"
sleep 30 & sp=$!; t0=$SECONDS; "$B" settle "$sp" 2; rc=$?; kill $sp 2>/dev/null
ok '[ "$rc" = 1 ] && [ $((SECONDS - t0)) -le 6 ]' "settle: gives up after the limit with rc 1 (rc $rc)"
ok '"$B" settle "" 5' "settle: no pid recorded means nothing to wait for"

# --- follow-up fix round 1 (verifier HIGH-1, red-team S6D-01..03) ---
# the worker's pid comes from the board's worker_bound event (runs[].worker_pid is never filled in by Hermes)
mkdir -p "$T/bin2"; cat >"$T/bin2/hermes" <<'S'
#!/usr/bin/env bash
cat <<J
{"task":{"id":"t_1","status":"blocked"},"runs":[{"id":1,"worker_pid":null},{"id":2,"worker_pid":null}],
 "events":[{"kind":"spawned","run_id":1,"payload":{"pid":111}},{"kind":"worker_bound","run_id":1,"payload":{"pid":222}},
           {"kind":"blocked","run_id":1,"payload":{}},{"kind":"worker_bound","run_id":2,"payload":{"pid":333}}]}
J
S
chmod +x "$T/bin2/hermes"
ok '[ "$(PATH="$T/bin2:$PATH" "$B" pid t_1 2>/dev/null)" = 333 ]' "pid: the newest worker_bound event's pid, though every runs[].worker_pid is null"
ok '[ -z "$(PATH="$T/bin:$PATH" "$B" pid t_1 2>/dev/null)" ]' "pid: a board with no worker_bound event gives nothing to wait for"
# a protected path that the branch made a folder, a check that ignores SIGTERM, a check that writes without limit
mkb 'bash test.sh'; rm "$T/v/r/test.sh"; mkdir "$T/v/r/test.sh"; printf 'x\n' >"$T/v/r/test.sh/inner"; : >"$T/v/r/f"; commit_card
ok '! vf >/dev/null 2>&1' "S6D-02: a branch that turns a protected test path into a folder is refused"
mkdir -p "$T/tmpd"; mkb 'trap "" TERM; sleep 25; echo "$BENCH_NONCE"'; : >"$T/v/r/f"; commit_card
t0=$SECONDS; TMPDIR=$T/tmpd BENCH_TIMEOUT=2 vf >/dev/null 2>&1; rc=$?; el=$((SECONDS - t0))
ok '[ "$rc" != 0 ] && [ "$el" -le 15 ] && [ -z "$(ls -A "$T/tmpd")" ]' "S6D-03: a check that ignores SIGTERM is killed (-k), fails, and leaves no temp folder (rc $rc, ${el}s)"
mkb 'head -c 150000000 /dev/zero > big && echo "$BENCH_NONCE"'; : >"$T/v/r/f"; commit_card
ok '! vf >/dev/null 2>&1' "S6D-03: a check that writes more than the file-size limit fails"
# a worker module that no-ops assert.* cannot subvert a test that took its assert functions first (S6D-01, interim)
mkb 'node test.js'; printf '%s\n' "const { strictEqual } = require('assert'); const f = require('./lib.js'); strictEqual(f(), 1); console.log(process.env.BENCH_NONCE);" >"$T/v/b/tasks/x/repo/test.js"
jq '.protected = ["test.js"]' "$T/v/b/tasks/x/task.json" >"$T/v/t" && mv "$T/v/t" "$T/v/b/tasks/x/task.json"; : >"$T/v/r/f"; rm -f "$T/v/r/test.sh"
printf '%s\n' "const a = require('assert'); for (const k of Object.keys(a)) if (typeof a[k] === 'function') a[k] = () => {}; module.exports = () => 2;" >"$T/v/r/lib.js"; commit_card
ok '! vf >/dev/null 2>&1' "S6D-01 (interim): a worker module that no-ops assert.* still fails a test that destructured assert first"
for t in bugfix-range bugfix-nullguard feature-multifile migration-rename; do
  ok 'head -3 /workspace/bench/tasks/'$t'/repo/test.js | grep -q "^const { *[a-zA-Z, ]* *} *= *require(.assert.)"' "shipped $t test takes its assert functions before loading worker code"
done


# --- follow-up 2, S6C-06 general fix: node tasks run under bench/guard.js (preloaded before any worker code) ---
# The guard freezes and counts the assert functions and reports, signed with a nonce the harness sends on stdin, how many assertions
# passed and failed and how the process ended. A branch passes only on a valid report with 0 failed, at least `guard` passed, exit 0.
gmk() {  # gmk <worker lib.js body> [min] [test.js body]: a node task whose protected test calls strictEqual(f(), 1) unless a body is given
  rm -rf "$T/g"; mkdir -p "$T/g/b/tasks/x/repo" "$T/g/b/tasks/x/solution"; echo '{"missing":[]}' >"$T/g/b/suite.json"; cp /workspace/bench/guard.js "$T/g/b/guard.js" 2>/dev/null
  jq -n --argjson m "${2:-1}" '{id:"x",category:"c",title:"t",body:"b",check:"node test.js",protected:["test.js"],guard:$m,subset:true}' >"$T/g/b/tasks/x/task.json"
  dflt="const { strictEqual } = require('assert'); const f = require('./lib.js'); strictEqual(f(), 1);"
  printf '%s\n' "${3:-$dflt}" >"$T/g/b/tasks/x/repo/test.js"
  printf 'module.exports = () => 0;\n' >"$T/g/b/tasks/x/repo/lib.js"; printf 'module.exports = () => 1;\n' >"$T/g/b/tasks/x/solution/lib.js"
  git init -q -b main "$T/g/r" && git -C "$T/g/r" -c user.name=t -c user.email=t@localhost commit -q --allow-empty -m s && git -C "$T/g/r" checkout -q -b card
  printf '%s\n' "$1" >"$T/g/r/lib.js"; printf '%s\n' "const { strictEqual } = require('assert'); strictEqual(1, 1);" >"$T/g/r/test.js"
  git -C "$T/g/r" add -A && git -C "$T/g/r" -c user.name=t -c user.email=t@localhost commit -q -m c; }
gv() { BENCH_DIR=$T/g/b "$B" verify "$T/g/r" card x; }
ok '[ -f /workspace/bench/guard.js ] && node --check /workspace/bench/guard.js' "bench/guard.js exists and parses"
gmk 'module.exports = () => 1;'; ok 'gv >/dev/null 2>&1' "guard: honest worker code passes (the test's own assertion counted and passed)"
gmk 'module.exports = () => 2;'; ok '! gv >/dev/null 2>&1' "guard: honest but wrong worker code fails"
gmk "const a = require('assert'); for (const k of Object.keys(a)) if (typeof a[k] === 'function') a[k] = () => {}; module.exports = () => 2;"; ok '! gv >/dev/null 2>&1' "guard: worker code that replaces every assert function with a no-op still fails (S6D-01)"
gmk "'use strict'; const a = require('assert'); a.strictEqual = () => {}; a.strict.strictEqual = () => {}; module.exports = () => 2;"; ok '! gv >/dev/null 2>&1' "guard: the same in strict mode (the frozen export throws) fails"
gmk "const a = require('assert'); const c = require('module'); require.cache[require.resolve('assert')] = { id: 'x', filename: 'x', loaded: true, exports: { strictEqual() {}, deepStrictEqual() {} } }; module.exports = () => 2;"; ok '! gv >/dev/null 2>&1' "guard: swapping the cached assert module for a fake fails (the test took its functions first)"
gmk 'process.exit(0);'; ok '! gv >/dev/null 2>&1' "guard: process.exit(0) before the test's assertions ran fails"
gmk "process.on('uncaughtException', () => {}); module.exports = () => 2;"; ok '! gv >/dev/null 2>&1' "guard: swallowing the AssertionError with an uncaughtException handler fails"
gmk "console.log('@@BENCH-REPORT passed=1 failed=0 code=0 mac=0000'); process.exit(0);"; ok '! gv >/dev/null 2>&1' "guard: a forged report line without the nonce fails"
gmk "process.removeAllListeners('exit'); process.exit(0);"; ok '! gv >/dev/null 2>&1' "guard: removing the exit listeners (no report at all) fails"
gmk "let s = ''; try { s = require('fs').readFileSync(0, 'utf8'); } catch (e) {} console.log('@@BENCH-REPORT passed=1 failed=0 code=0 mac=' + require('crypto').createHash('sha256').update(s + ':1:0:0').digest('hex')); process.exit(0);"; ok '! gv >/dev/null 2>&1' "guard: reading stdin for the nonce finds nothing (it was consumed before any worker code), so a report cannot be forged"
gmk 'module.exports = () => 1;' 3; ok '! gv >/dev/null 2>&1' "guard: fewer assertions than the task's minimum (1 of 3) fails"
ok '[ "$(jq -r .guard /workspace/bench/tasks/bugfix-range/task.json)" -ge 1 ] && [ "$(jq -r .guard /workspace/bench/tasks/migration-rename/task.json)" -ge 1 ]' "the shipped node tasks name their minimum assertion count"
ok 'bin_out=$("$B" check 2>&1); [ "$?" = 0 ] && grep -q "^5 tasks" <<<"$bin_out"' "bench.sh check still passes on the shipped suite under the guard"


# --- follow-up 2, fix round 1 (red-team S6E-01, S6E-08; verifier blocker): the nonce is in no environment variable, only the protected test's
# own assertion calls count, and an async assertion counts when it settles ---
gmk "const c = require('crypto'); const n = process.env.BENCH_NONCE || ''; console.log('@@BENCH-REPORT passed=1 failed=0 code=0 mac=' + c.createHash('sha256').update(n + ':1:0:0').digest('hex')); process.exit(0);"; ok '! gv >/dev/null 2>&1' "S6E-08: a worker that signs a report with process.env.BENCH_NONCE fails (the nonce is not in the environment of a node task)"
gmk "const a = require('assert'); a.ok(true); process.exit(0);"; ok '! gv >/dev/null 2>&1' "S6E-01: padding the count with the worker's own assert calls, then exit(0), fails"
gmk "const a = require('assert'); for (let i = 0; i < 20; i++) a.strictEqual(1, 1); process.on('uncaughtException', () => {}); module.exports = () => { throw new Error('x'); };" 5; ok '! gv >/dev/null 2>&1' "S6E-01: padding with 20 calls, then a throwing function and a swallowed exception, fails (the test's own assertion never ran)"
gmk "module.exports = () => { process.exit(0); };"; ok '! gv >/dev/null 2>&1' "S6E-01: an exit(0) inside the function the test calls fails"
gmk "const a = require('assert'); module.exports = () => { try { a.ok(false); } catch (e) {} try { a.strictEqual(1, 2); } catch (e) {} return 1; };"; ok 'gv >/dev/null 2>&1' "S6E-01 control: correct worker code that uses assert itself (and catches its own failures) still passes"
TA="const { rejects } = require('assert'); const f = require('./lib.js'); rejects(f());"
gmk "module.exports = async () => 1; process.on('unhandledRejection', () => {});" 1 "$TA"; ok '! gv >/dev/null 2>&1' "S6E-01: a wrong async function (the rejects assertion fails) with unhandledRejection swallowed fails"
gmk "module.exports = async () => { throw new Error('boom'); };" 1 "$TA"; ok 'gv >/dev/null 2>&1' "S6E-01 control: an async function that rejects as the test expects passes (counted when it settles)"

# the reset keeps a card worktree out of the start commit and keeps the worktree
mkb 'bash test.sh'; git -C "$T/v/r" checkout -q main; mkdir -p "$T/v/r/.worktrees"; git -C "$T/v/r" worktree add -q "$T/v/r/.worktrees/w1" -b wb 2>/dev/null; echo old >"$T/v/r/.worktrees/w1/keep"
BENCH_DIR=$T/v/b "$B" reset x "$T/v/r" >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 0 ] && [ "$(git -C "$T/v/r" ls-tree -r HEAD | grep -c "^160000")" = 0 ] && [ -f "$T/v/r/.worktrees/w1/keep" ] && [ -f "$T/v/r/test.sh" ]' "reset: the start commit has the task files, no worktree gitlink, and the old worktree survives (rc $rc)"

# S6C-06 for the bash task (D103): deploy-recovery's protected test.sh accepts only a config of plain NAME=value lines, so a config that prints
# the expected line and exits (or that prints anything, or runs code) cannot pass; only the real fix does
DR=/workspace/bench/tasks/deploy-recovery
dr() { rm -rf "$T/dr"; cp -r "$DR/repo" "$T/dr"; printf '%s\n' "$1" >"$T/dr/deploy.conf"; ( cd "$T/dr" && BENCH_NONCE=n123 bash test.sh 2>/dev/null | tail -n1 ); }
ok '[ "$(dr "TARGET_DIR=./out")" = n123 ]' "S6C-06 bash: the honest fix (TARGET_DIR=./out) prints the nonce"
ok '[ "$(dr "echo would deploy to ./out; exit 0")" != n123 ]' "S6C-06 bash: a config that prints the expected line and exits 0 does not pass"
ok '[ "$(dr "TARGET_DIR=./out
echo would deploy to ./out
exit 0")" != n123 ]' "S6C-06 bash: a valid assignment followed by code in the config does not pass"
ok '[ "$(dr "")" != n123 ]' "S6C-06 bash: an empty config does not pass"
ok '[ "$(dr "TARGET_DIR=\$(echo ./out)")" != n123 ]' "S6C-06 bash: a command substitution in the config does not pass"
ok '[ "$(dr "TARGET=./out")" != n123 ]' "S6C-06 bash: the original fault (wrong variable name) still fails"

# fix round 1 (verifier B1): a NUL byte makes grep treat the config as binary and split the line, and bash drops the NUL when it sources the file
rm -rf "$T/dr"; cp -r "$DR/repo" "$T/dr"; printf 'TARGET=./out\nA=b\0# echo would deploy to ./out; exit 0\n' >"$T/dr/deploy.conf"
ok '[ "$(cd "$T/dr" && BENCH_NONCE=n123 bash test.sh 2>/dev/null | tail -n1)" != n123 ]' "S6C-06 bash: a NUL byte hiding code from the plain-assignment check does not pass"

[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
