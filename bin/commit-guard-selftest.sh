#!/usr/bin/env bash
# Hermetic self-test for bin/commit-guard.sh (D36): scratch repos and worktrees, identity from env only, no network.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CG=${CG:-/workspace/bin/commit-guard.sh}
export GIT_AUTHOR_NAME=owner GIT_AUTHOR_EMAIL=owner@example.invalid GIT_COMMITTER_NAME=owner GIT_COMMITTER_EMAIL=owner@example.invalid
unset HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH
# K1: the card is proven by its own worker process, never by HERMES_KANBAN_* (Hermes sets them after the worker starts and
# strips them from hooks). A fake worker, bound to a running card on a stub board (`hermes` first on PATH), runs the hook
# three levels below itself: worker -> sh -> python3 runner -> hook, as a worker's tool call does.
export PATH="$T/bin:$PATH" FAKE_CARDS=$T/cards FAKE_LOG=$T/hermes.log
EXPECT_HOME=$(getent passwd "$(id -u)" | cut -d: -f6)/.hermes; export EXPECT_HOME
mkdir -p "$T/bin" "$FAKE_CARDS"
sleep 600 & STR=$!   # a live process that is no ancestor of any hook
trap 'kill $STR 2>/dev/null; rm -rf "$T"' EXIT
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
# kcommit <fixture> <card> <workspace> <branch> <dir> [env...]: a stand-in coding CLI (worker -> sh -> python3 -> git commit)
# in <dir>, run by a worker bound per <fixture> to <card>, with the env assignments given; its exit code is printed, the hook's
# message left in $T/out
printf '%s\n' 'import subprocess, sys' 'sys.exit(subprocess.call(["git", "commit", "-q", "-m", "worker commit"], cwd=sys.argv[1]))' >"$T/cli.py"
kcommit() { local fx=$1 c=$2 w=$3 b=$4 d=$5; shift 5; bound "$fx" "$c" builder-x "$w" "$b" "" -- env "$@" python3 "$T/cli.py" "$d"; }
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
# guard <dir> [env...]: the guard's exit code in <dir>; its stderr goes to $T/err
guard() { local d=$1; shift; (cd "$d" && env "$@" "$CG" 2>"$T/err" >/dev/null); echo $?; }
R="$T/repo"; W="$T/repo/.worktrees/t_aaaaaaaa"; BR=stella/t_aaaaaaaa-card
git init -q -b main "$R" && (cd "$R" && echo a > a && git add a && git commit -q -m init && git worktree add -q -b "$BR" "$W")

ok '[ "$(guard "$R" HERMES_KANBAN_WORKSPACE="$W" HERMES_KANBAN_BRANCH="$BR")" = 1 ] && grep -q "on main" "$T/err"' "worker commit on main refused"
ok '[ "$(guard "$R" HERMES_KANBAN_TASK=t_aaaaaaaa)" = 1 ]' "worker marked only by HERMES_KANBAN_TASK: commit on main refused"
ok '[ "$(guard /workspace HERMES_KANBAN_WORKSPACE=/workspace/.worktrees/t_aaaaaaaa)" = 1 ] && grep -q "/workspace" "$T/err"' "worker commit in /workspace refused"
ok '[ "$(guard "$W" HERMES_KANBAN_WORKSPACE="$W" HERMES_KANBAN_BRANCH="$BR")" = 0 ]' "worker commit on its card branch in its worktree allowed"
ok '[ "$(guard "$W" HERMES_KANBAN_WORKSPACE="$T/other" HERMES_KANBAN_BRANCH="$BR")" = 1 ]' "worker commit in a worktree that is not its card workspace refused"
ok '[ "$(guard "$W" HERMES_KANBAN_WORKSPACE="$W" HERMES_KANBAN_BRANCH=stella/t_bbbbbbbb-x)" = 1 ]' "worker commit on another card's branch refused"
ok '[ "$(guard "$R")" = 0 ]' "The owner's normal commit (no worker marker) allowed, on main too"
ok '[ "$(guard "$R" GIT_AUTHOR_EMAIL=test@test.com)" = 1 ] && grep -q "test@test.com" "$T/err"' "author test@test.com refused"
ok '[ "$(guard "$R" GIT_AUTHOR_EMAIL=)" = 1 ] && grep -q "empty" "$T/err"' "empty author email refused"
# F1 W4 round 2 (G3, G1): the staged names are read whole (-z, no rename detection); owner data is the one definition in bin/roles.py.
WK=(HERMES_KANBAN_WORKSPACE="$W" HERMES_KANBAN_BRANCH="$BR")
SETP=$(jq -r '.files[] | select(.id == "settings") | .path' "/workspace/$(jq -r .data_index /workspace/docs/hermes-local/roles.json)")   # an owner_only index row, found by its id
mkdir -p "$W/.stella/extensions" "$W/.stella/schemas"; echo x >"$W/.stella/schemas/zz-w4.json"
git -C "$W" add -f .stella/schemas/zz-w4.json && git -C "$W" -c core.hooksPath=/dev/null commit -q -m "owner data, as the owner committed it"
echo x >"$W/.stella/extensions/é.json"; git -C "$W" add -f ".stella/extensions/é.json"
ok '[ "$(guard "$W" "${WK[@]}")" = 1 ] && grep -q "owner data" "$T/err"' "G3: a non-ASCII name under owner data (it printed quoted and escaped before -z): refused for a worker"
ok '[ "$(guard "$W")" = 0 ]' "G3: the same name staged by the owner (no worker marker): allowed"
git -C "$W" reset -q; rm -f "$W/.stella/extensions/é.json"
git -C "$W" mv .stella/schemas/zz-w4.json moved-w4.json
ok '[ "$(guard "$W" "${WK[@]}")" = 1 ] && grep -q "owner data" "$T/err"' "G3: a rename out of an owner folder (the old path is listed, no rename detection): refused for a worker"
git -C "$W" reset -q --hard
git -C "$W" rm -q .stella/schemas/zz-w4.json
ok '[ "$(guard "$W" "${WK[@]}")" = 1 ] && grep -q "owner data" "$T/err"' "G3: a deletion of owner data: refused for a worker"
ok '[ "$(guard "$W")" = 0 ]' "G3: the same deletion by the owner: allowed"
git -C "$W" reset -q --hard
mkdir -p "$W/.stella"; echo x >"$W/$SETP"; echo x >"$W/.stella/capabilities.json"; echo x >"$W/.stella/test-map.json"
git -C "$W" add -f "$SETP"
ok '[ "$(guard "$W" "${WK[@]}")" = 1 ] && grep -q "owner data" "$T/err"' "G1: a worker staging an owner_only index row (the settings row): refused"
git -C "$W" reset -q; git -C "$W" add -f .stella/capabilities.json .stella/test-map.json
ok '[ "$(guard "$W" "${WK[@]}")" = 0 ]' "G1: a worker staging the capability registry and the test map (rows that are not owner-only; product rules 4 and 8): allowed"
git -C "$W" reset -q
# G1: flip a row's flag in a scratch index and the same file moves in or out of the refusal, with no other edit
GT=$T/gt; mkdir -p "$GT/bin" "$GT/docs/hermes-local" "$GT/.stella"; cp "$CG" /workspace/bin/roles.py "$GT/bin/"; cp /workspace/docs/hermes-local/roles.json "$GT/docs/hermes-local/"
jq '(.files[] | select(.id == "capabilities") | .owner_only) = true | (.files[] | select(.id == "settings") | .owner_only) = false' /workspace/.stella/data-files.json >"$GT/.stella/data-files.json"
git -C "$W" add -f .stella/capabilities.json
ok '[ "$(CG=$GT/bin/commit-guard.sh guard "$W" "${WK[@]}")" = 1 ] && grep -q "owner data" "$T/err"' "G1: capabilities.json made owner_only in a scratch index: now refused for a worker"
git -C "$W" reset -q; git -C "$W" add -f "$SETP"
ok '[ "$(CG=$GT/bin/commit-guard.sh guard "$W" "${WK[@]}")" = 0 ]' "G1: the settings row made not owner_only in the scratch index: now allowed (no other edit)"
git -C "$W" reset -q
printf '{}' >"$GT/.stella/data-files.json"; git -C "$W" add -f .stella/capabilities.json
ok '[ "$(CG=$GT/bin/commit-guard.sh guard "$W")" = 1 ] && grep -qi "cannot be read" "$T/err"' "G1: an index the guard cannot read: every commit is refused, the owner's too (fail closed)"
git -C "$W" reset -q --hard "$(git -C "$R" rev-parse main)"   # back to the first commit: the end-to-end counts below start there
# End to end: the guard as the repo's real pre-commit hook, through git commit (worktrees share .git/hooks).
ln -s "$CG" "$R/.git/hooks/pre-commit"
ok '! (cd "$R" && echo b > b && git add b && HERMES_KANBAN_WORKSPACE="$W" git commit -q -m x 2>/dev/null) && [ "$(git -C "$R" rev-list --count HEAD)" = 1 ]' "git commit by a worker on main: refused, no commit made"
ok '(cd "$W" && echo c > c && git add c && HERMES_KANBAN_WORKSPACE="$W" HERMES_KANBAN_BRANCH="$BR" git commit -q -m y) && [ "$(git -C "$W" rev-list --count HEAD)" = 2 ]' "git commit by a worker in its worktree: committed"
# K1 (real tree): the proof reads the board and the process tree, however git was started. Card t_aaaaaaaa, on its branch in
# worktree wa, is bound to the worker; wb is another card's worktree; main is the main checkout (scratch repo only).
K=$T/k1; BRA=stella/t_aaaaaaaa-card
git init -q -b main "$K/main" && (cd "$K/main" && echo a > a && git add a && git commit -q -m init) \
  && git -C "$K/main" worktree add -q -b "$BRA" "$K/wa" && git -C "$K/main" worktree add -q -b stella/t_bbbbbbbb-card "$K/wb" \
  && ln -s "$CG" "$K/main/.git/hooks/pre-commit"
H0=$(git -C "$K/main" rev-parse HEAD)
ok '(echo one > $K/wa/f1 && git -C $K/wa add f1) && [ "$(kcommit bind t_aaaaaaaa $K/wa $BRA $K/wa)" = 0 ] && [ "$(git -C $K/wa rev-list --count HEAD)" = 2 ]' "a proven worker commits in its card worktree on its card branch: allowed, committed"
ok '(echo two > $K/main/f2 && git -C $K/main add f2) && [ "$(kcommit bind t_aaaaaaaa $K/wa $BRA $K/main)" = 1 ] && grep -qF "worker commit on main refused" "$T/out" && [ "$(git -C $K/main rev-parse HEAD)" = "$H0" ]' "a proven worker committing on main, no env marker set: refused by its proof, main unchanged"
git -C "$K/main" reset -q -- f2; rm -f "$K/main/f2"
ok '(echo three > $K/wb/f3 && git -C $K/wb add f3) && [ "$(kcommit bind t_aaaaaaaa $K/wa $BRA $K/wb)" = 1 ] && grep -qF "is not card t_aaaaaaaa" "$T/out" && [ "$(git -C $K/wb rev-list --count HEAD)" = 1 ]' "a proven worker committing in another card's worktree (another toplevel): refused"
git -C "$K/wb" reset -q -- f3; rm -f "$K/wb/f3"
ok '(git -C $K/wa checkout -q -b other-x && echo four > $K/wa/f4 && git -C $K/wa add f4) && [ "$(kcommit bind t_aaaaaaaa $K/wa $BRA $K/wa)" = 1 ] && grep -qF "branch other-x is not card t_aaaaaaaa" "$T/out"' "a proven worker committing on another branch of its own worktree: refused"
git -C "$K/wa" reset -q -- f4; rm -f "$K/wa/f4"; git -C "$K/wa" checkout -q "$BRA"
ok '(echo five > $K/main/f5 && git -C $K/main add f5) && [ "$(kcommit stranger t_aaaaaaaa $K/wa $BRA $K/main)" = 0 ] && [ "$(git -C $K/main rev-list --count HEAD)" = 2 ]' "a commit with the card bound to no ancestor and no env marker: not a worker commit, allowed on main as before"
ok '(echo six > $K/main/f6 && git -C $K/main add f6) && [ "$(kcommit none "" "" "" $K/main)" = 0 ] && [ "$(git -C $K/main rev-list --count HEAD)" = 3 ]' "a commit with no running card at all: allowed on main as before"
# K1 round 2 (verifier): the worker's board, home and delegation are not the caller's to choose. Each refusal leaves main as it was.
N0=$(git -C "$K/main" rev-list --count HEAD)
ok '(echo nine > $K/main/f9 && git -C $K/main add f9) && [ "$(kcommit bind t_aaaaaaaa $K/wa $BRA $K/main -u HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BOARD=nosuch)" = 1 ] && grep -qF "worker commit on main refused" "$T/out" && [ "$(git -C $K/main rev-list --count HEAD)" = "$N0" ]' "a bound worker commits on main with HERMES_KANBAN_BOARD=nosuch and no HERMES_KANBAN_WORKSPACE: refused, main unchanged"
git -C "$K/main" reset -q -- f9; rm -f "$K/main/f9"
ok '(echo ten > $K/main/f10 && git -C $K/main add f10) && [ "$(kcommit bind t_aaaaaaaa $K/wa $BRA $K/main -u HERMES_KANBAN_WORKSPACE HERMES_HOME=/tmp/x)" = 1 ] && grep -qF "worker commit on main refused" "$T/out" && [ "$(git -C $K/main rev-list --count HEAD)" = "$N0" ]' "the same with HERMES_HOME=/tmp/x: refused, main unchanged"
git -C "$K/main" reset -q -- f10; rm -f "$K/main/f10"
ok '(echo eleven > $K/main/f11 && git -C $K/main add f11) && [ "$(kcommit bind t_aaaaaaaa $K/wa $BRA $K/main -u HERMES_KANBAN_WORKSPACE HERMES_KANBAN_HOME=/tmp/x)" = 1 ] && grep -qF "worker commit on main refused" "$T/out" && [ "$(git -C $K/main rev-list --count HEAD)" = "$N0" ]' "the same with HERMES_KANBAN_HOME=/tmp/x: refused, main unchanged"
git -C "$K/main" reset -q -- f11; rm -f "$K/main/f11"
ok '[ "$(guard "$K/main" HERMES_DELEGATED_CHILD_CONTEXT=1)" = 1 ] && grep -qF "cannot be proven" "$T/err"' "HERMES_DELEGATED_CHILD_CONTEXT=1 with no bound run and no workspace env: refused (cannot be proven)"
N1=$(git -C "$K/main" rev-list --count HEAD)   # counted here: an earlier case's commit (the pre-K1 code) must not shift this one
ok '(echo own > $K/main/fo && git -C $K/main add fo) && (cd $K/main && env PATH=/usr/bin:/bin git commit -q -m owner) && [ "$(git -C $K/main rev-list --count HEAD)" = "$((N1+1))" ]' "owner commit with no markers and hermes off PATH: allowed"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
