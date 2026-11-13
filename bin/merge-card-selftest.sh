#!/usr/bin/env bash
# Hermetic self-test for bin/merge-card.sh (F31): a scratch repo with a scratch bare remote, card branches in
# worktrees, a stub hermes for the reviewer verdict. Nothing outside the scratch dir is touched; no network.
# K8 (the approval is read from the table's reviewing profiles): MC=<merge-card.sh> and ROLES_FILE=<table> point the run at a staged copy
# (its roles.py must sit next to it); FAKE_REVIEWER names the profile of the stub's reviewer run.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; export ESCALATE_SUP_DIR=$T/sup; mkdir -p "$T/sup/logs"   # T7: a refusal the box or roles.py codes logs here from the first case on (one line: qa harnesses take lines 1..81)
cat > "$T/bin/hermes" <<'S'
#!/usr/bin/env bash
[ "$1 $2" = "kanban --board" ] && [ "$3" != ai-stack ] && { echo "board $3 not found" >&2; exit 1; }
[ "$1 $2" = "kanban --board" ] && set -- "$1" "${@:4}"
[ "$1 $2" = "kanban show" ] && [ -f "$FAKE_CARDS/$3.json" ] && { jq -c --arg c "$3" --arg a " ${FAKE_APPROVED:-} " 'def st: if ($ENV.FAKE_REVIEW_STARTED // "") == "none" then {} else {started_at: (($ENV.FAKE_REVIEW_STARTED // "9999999999") | tonumber)} end; . + {runs: (.runs + (if ($a | contains(" " + $c + " ")) then [{id: 8, profile: ($ENV.FAKE_REVIEWER // "reviewer"), ended_at: 1, outcome: "completed", metadata: {review: "approved"}} + st] else [] end))}' "$FAKE_CARDS/$3.json"; exit 0; }
[ "$1 $2" = "kanban list" ] && { [ -z "${FAKE_UNREADABLE:-}" ] || exit 1; cat "$FAKE_CARDS"/*.json 2>/dev/null | jq -sc '[.[] | select(.task.status == "running") | {id: .task.id}]'; exit 0; }
# FAKE_REVIEWER: the profile of that reviewer run (default reviewer). FAKE_APPROVED: cards whose latest reviewer run is completed with metadata.review = approved; FAKE_BUILDER_APPROVED:
# cards where only the builder's own run carries that marker.
case "$1 $2" in
  "kanban show") jq -nc --arg c "$3" --arg a " ${FAKE_APPROVED:-} " --arg b " ${FAKE_BUILDER_APPROVED:-} " 'def st: if ($ENV.FAKE_REVIEW_STARTED // "") == "none" then {} else {started_at: (($ENV.FAKE_REVIEW_STARTED // "9999999999") | tonumber)} end; {task: {id: $c, status: "done"},
                   runs: ([{profile: "builder-claude", outcome: "completed", metadata: (if ($b | contains(" " + $c + " ")) then {review: "approved"} else {} end)}]
                          + (if ($a | contains(" " + $c + " ")) then [{profile: ($ENV.FAKE_REVIEWER // "reviewer"), outcome: "completed", metadata: {review: "approved"}} + st] else [] end))}';;
esac
S
chmod +x "$T/bin/hermes"
export PATH="$T/bin:$PATH" BOX_HERMES_ROOT=$T/hermes; jq -r '.sandbox.boxed_profiles[] as $p | .profiles[$p].dir // ("profiles/" + $p)' "${ROLES_FILE:-/workspace/docs/hermes-local/roles.json}" | while read -r d; do mkdir -p "$T/hermes/$d/home"; done   # K2: the card tests run in the OS box; its profile homes are scratch
unset HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_DELEGATED_CHILD_CONTEXT
export HERMES_HOME=/home/node/.hermes GIT_AUTHOR_NAME=selftest GIT_AUTHOR_EMAIL=selftest@example.invalid GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@example.invalid
g() { git -C "$T/repo" "$@"; }
git init -q --bare -b main "$T/remote.git"
git init -q -b main "$T/repo"
printf '.worktrees/\n' > "$T/repo/.gitignore"; printf '{"scripts": {"test": "sh test.sh"}}\n' > "$T/repo/package.json"
printf 'exit 0\n' > "$T/repo/test.sh"; printf 'base\n' > "$T/repo/a.txt"
g add .gitignore package.json test.sh a.txt; g -c core.hooksPath=/dev/null commit -qm base
g remote add origin "$T/remote.git"; g push -q -u origin main
card() {  # card <id> <file> <content> [test.sh body]: branch stella/<id>-x with one commit, in its worktree
  g worktree add -q -b "stella/$1-x" "$T/repo/.worktrees/$1" main
  printf '%s\n' "$3" > "$T/repo/.worktrees/$1/$2"; [ -z "${4:-}" ] || printf '%s\n' "$4" > "$T/repo/.worktrees/$1/test.sh"
  git -C "$T/repo/.worktrees/$1" add -A; git -C "$T/repo/.worktrees/$1" -c core.hooksPath=/dev/null commit -qm "card $1"
}
export FAKE_CARDS=$T/cards; mkdir -p "$FAKE_CARDS"
sleep 600 & STR=$!   # a live process that is no ancestor of any hook
trap 'kill $STR 2>/dev/null; rm -rf "$T"' EXIT
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
        {kind: "worker_bound", run_id: 7, payload: {pid: $pid, claim_lock: $lock, started_at: $sig}}] end)}' >"$FAKE_CARDS/$c.json"
}
bound() {  # bound <fixture> <card> <assignee> <workspace> <branch> <payload> -- <cmd...>: <cmd> run by a fake worker bound per
  # the fixture; its exit code is printed, its output left in $T/out. The card is on the board before the worker is released.
  local fx=$1 c=$2 a=$3 ws=$4 br=$5 pl=$6 d w; shift 7; d=$(mktemp -d -p "$T")
  printf '%s' "$pl" >"$d/payload"; rm -f "$FAKE_CARDS"/*.json
  bash "$T/worker.sh" "$d" "$T/runner.py" "$@" </dev/null & w=$!
  for _ in $(seq 200); do [ -s "$d/pid" ] && break; sleep 0.02; done
  [ "$fx" = none ] || mk "$fx" "$c" "$a" "$ws" "$br" "$(cat "$d/pid")"
  touch "$d/go"; wait "$w"; cp "$d/out" "$T/out"; cat "$d/rc"; }
M=${MC:-/workspace/bin/merge-card.sh} fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/out" ] && sed 's/^/     /' "$T/out" | tail -4; fi; }   # a failing case shows the last lines the merge printed
mc() { (cd "$T/repo" && "$M" "$@") >"$T/out" 2>&1; echo $?; }
head_of() { git -C "$1" rev-parse "${2:-HEAD}"; }

card t_00000001 b.txt one
card t_00000002 c.txt two
card t_00000003 a.txt conflict
card t_00000004 d.txt failing 'exit 1'
card t_00000005 e.txt five
card t_00000006 f.txt six
h0=$(head_of "$T/repo")
ok '[ "$(mc t_00000001)" = 3 ] && grep -q "review" "$T/out" && [ "$(head_of "$T/repo")" = "$h0" ]' "unreviewed card refused, main untouched"
ok '! grep -q "running this branch" "$T/out"' "D42: a refusal before the tests (unreviewed) prints no test-run warning"
ok '[ "$(FAKE_BUILDER_APPROVED=t_00000001 mc t_00000001)" = 3 ]' "a builder's own approved marker does not count, only the reviewer's run"
ok '[ "$(HERMES_KANBAN_TASK=t_00000001 FAKE_APPROVED=t_00000001 mc t_00000001)" = 3 ] && grep -q "worker" "$T/out"' "refused in a worker environment (HERMES_KANBAN_TASK)"
ok '[ "$(HERMES_KANBAN_WORKSPACE=/workspace/.worktrees/t_00000001 FAKE_APPROVED=t_00000001 mc t_00000001)" = 3 ] && [ "$(HERMES_HOME=/home/node/.hermes/profiles/builder-local FAKE_APPROVED=t_00000001 mc t_00000001)" = 3 ] && [ "$(HERMES_DELEGATED_CHILD_CONTEXT=1 FAKE_APPROVED=t_00000001 mc t_00000001)" = 3 ]' "refused with a worker's workspace, profile home or delegation marker"
printf 'x\n' > "$T/repo/stray.txt"
ok '[ "$(FAKE_APPROVED=t_00000001 mc t_00000001)" = 3 ] && grep -q "clean" "$T/out" && [ "$(head_of "$T/repo")" = "$h0" ]' "dirty main checkout refused"
rm "$T/repo/stray.txt"; g checkout -q -b other
ok '[ "$(FAKE_APPROVED=t_00000001 mc t_00000001)" = 3 ] && grep -q "on main" "$T/out"' "main checkout not on main refused"
g checkout -q main
printf 'dirty\n' >> "$T/repo/.worktrees/t_00000001/b.txt"
ok '[ "$(FAKE_APPROVED=t_00000001 mc t_00000001)" = 3 ] && grep -q "worktree" "$T/out"' "dirty card worktree refused"
git -C "$T/repo/.worktrees/t_00000001" checkout -q b.txt
ok '[ "$(FAKE_APPROVED=t_00000004 mc t_00000004)" = 3 ] && grep -q "test" "$T/out" && [ "$(head_of "$T/repo")" = "$h0" ]' "failing tests in the card worktree refused"
ok '[ "$(grep -c "merge-card.sh: running this branch'"'"'s own test command in the OS box (the card worktree writable, the rest read-only); review the diff first" "$T/out")" = 1 ] && [ "$(grep -n "running this branch" "$T/out" | cut -d: -f1)" -lt "$(grep -n "tests failed" "$T/out" | cut -d: -f1)" ]' "D42: one warning line, printed before the branch's tests run"
ok '[ "$(FAKE_APPROVED=t_00000001 mc t_00000001)" = 0 ] && [ "$(g rev-list --parents -n1 HEAD | wc -w)" = 3 ] && [ "$(head_of "$T/remote.git" main)" = "$h0" ]' "clean merge: --no-ff merge commit on main; without --push the remote is untouched"
ok '[ "$(grep -c "running this branch" "$T/out")" = 1 ] && [ "$(grep -n "running this branch" "$T/out" | cut -d: -f1)" -lt "$(grep -n "^merged " "$T/out" | cut -d: -f1)" ]' "D42: a clean merge prints the warning once, before the merge"
ok 'g rev-parse -q --verify stella/t_00000001-x >/dev/null && [ -d "$T/repo/.worktrees/t_00000001" ]' "the card branch and worktree are kept"
sleep 1.5   # B.1 (r5): longer than the box's sweep helper waits after its launcher ends
ok '[ ! -e "$T/repo/.worktrees/merge-check-t_00000001" ] && [ ! -e "$T/repo/.git/worktrees/merge-check-t_00000001" ] && ! g rev-parse -q --verify merge-check/t_00000001 >/dev/null' "B.1 (r5): the throw-away test worktree, its git dir entry and its branch are gone after the merge, and stay gone (no late sweep re-makes them)"
ok '[ "$(FAKE_APPROVED=t_00000001 mc t_00000001)" = 3 ] && grep -q "ahead" "$T/out"' "a merged branch (not ahead of main) is refused"
h1=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_00000002 mc t_00000002 --push)" = 0 ] && [ "$(head_of "$T/remote.git" main)" = "$(head_of "$T/repo")" ] && [ "$(head_of "$T/repo")" != "$h1" ]' "--push pushes main to its upstream (the scratch bare remote)"
printf 'main change\n' > "$T/repo/a.txt"; g -c core.hooksPath=/dev/null commit -qam "main edit"   # a.txt now conflicts with t_00000003
h2=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_00000003 mc t_00000003)" = 1 ] && grep -q "conflict" "$T/out" && [ "$(head_of "$T/repo")" = "$h2" ] && [ -z "$(g status --porcelain)" ] && ! g rev-parse -q --verify MERGE_HEAD >/dev/null' "a conflict aborts the merge: main untouched and clean"
ok '[ "$(mc t_00000005 --owner-approved)" = 0 ]' "--owner-approved stands in for the reviewer's marker"
ok '[ "$(mc t_0000000z)" = 2 ] && [ "$(mc)" = 2 ] && [ "$(FAKE_APPROVED=t_00000099 mc t_00000099)" = 3 ]' "bad card id or no branch: usage error or refused"
ok '[ "$(cd /tmp && FAKE_APPROVED=t_00000006 "$M" t_00000006 --repo "$T/repo" >"$T/out" 2>&1; echo $?)" = 0 ]' "--repo <dir> works from another directory"
ok '! grep -n "/workspace" "$M" | grep -v "^[0-9]*:#"' "no /workspace path hard-coded (the default repo is ., the board helper sits next to the script)"
# Review H4: with --push the merged tree is tested first; a merge that passes on the branch but fails on main is not pushed.
printf 'if [ -f g1 ] && [ -f g2 ]; then exit 1; fi\n' > "$T/repo/test.sh"; g -c core.hooksPath=/dev/null commit -qam "test: g1 and g2 together fail"
g push -q
card t_00000007 g2 two
printf 'one\n' > "$T/repo/g1"; g add g1; g -c core.hooksPath=/dev/null commit -qm "g1 on main"
r0=$(head_of "$T/remote.git" main)
ok '[ "$(FAKE_APPROVED=t_00000007 mc t_00000007 --push)" = 1 ] && grep -q "NOT pushed" "$T/out" && [ "$(head_of "$T/remote.git" main)" = "$r0" ]' "H4: tests fail on the merged main: merged locally, not pushed"
# K1 (real tree): merge-card.sh run from under a kanban worker's own run is refused; with no run bound it is not.
card t_00000010 f10.txt ten 'exit 0'   # its own passing test command: main's (H4) fails once g1 and g2 are both merged
h10=$(head_of "$T/repo")
ok '[ "$(cd "$T/repo" && bound bind t_00000010 builder-x "$T/repo/.worktrees/t_00000010" stella/t_00000010-x "" -- env FAKE_APPROVED=t_00000010 "$M" t_00000010)" = 3 ] && grep -qF "K1" "$T/out" && [ "$(head_of "$T/repo")" = "$h10" ]' "run from under a worker's own bound run (real process tree), the reviewer approved: refused with the K1 message, main untouched"
rm -f "$FAKE_CARDS"/*.json; card t_00000011 f11.txt eleven 'exit 0'   # a card of its own: the control is not the bound case's cascade
h11=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_00000011 mc t_00000011)" = 0 ] && [ "$(head_of "$T/repo")" != "$h11" ]' "the same kind of card merged from a shell with no bound run: merged (the K1 refusal needs the worker)"
# K1 round 2 (verifier): the board is the stack's one board, and an unreadable board refuses. Each case has its own card, so
# a case that merges (the earlier code) does not change what the next one is checked against.
card t_00000012 f12.txt twelve 'exit 0'
h12=$(head_of "$T/repo")
ok '[ "$(cd "$T/repo" && bound bind t_00000012 builder-x "$T/repo/.worktrees/t_00000012" stella/t_00000012-x "" -- env -u HERMES_KANBAN_TASK -u HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BOARD=nosuch FAKE_APPROVED=t_00000012 "$M" t_00000012 --owner-approved)" = 3 ] && grep -qF "K1" "$T/out" && [ "$(head_of "$T/repo")" = "$h12" ]' "a bound worker with HERMES_KANBAN_BOARD=nosuch, TASK and WORKSPACE unset, --owner-approved: refused (K1), main untouched"
card t_00000013 f13.txt thirteen 'exit 0'
h13=$(head_of "$T/repo")
ok '[ "$(cd "$T/repo" && bound bind t_00000013 builder-x "$T/repo/.worktrees/t_00000013" stella/t_00000013-x "" -- env FAKE_UNREADABLE=1 FAKE_APPROVED=t_00000013 "$M" t_00000013 --owner-approved)" = 3 ] && [ "$(head_of "$T/repo")" = "$h13" ]' "a bound worker and an unreadable board (no hermes answer for the board): refused, main untouched"
rm -f "$FAKE_CARDS"/*.json; card t_00000014 f14.txt fourteen 'exit 0'
h14=$(head_of "$T/repo")
ok '[ "$(cd "$T/repo" && FAKE_UNREADABLE=1 FAKE_APPROVED=t_00000014 "$M" t_00000014 --owner-approved >"$T/out" 2>&1; echo $?)" = 3 ] && [ "$(head_of "$T/repo")" = "$h14" ]' "an owner shell with the board unreadable, --owner-approved: refused, main untouched"
# F1 W4 round 2 (B3): the merge is the single place every card change passes. Owner data is refused however the commit was made, the boundary
# itself needs the owner's explicit flag, and an ordinary branch (the cases above) merges as before.
export ESCALATE_SUP_DIR=$T/sup; mkdir -p "$T/sup/logs"; : >"$T/sup/logs/alerts.log"
SETP=$(jq -r '.files[] | select(.id == "settings") | .path' "/workspace/$(jq -r .data_index /workspace/docs/hermes-local/roles.json)")   # an owner_only index row, found by its id
mkdir -p "$T/repo/.stella/extensions" "$T/repo/.stella/schemas"; printf '{}\n' >"$T/repo/.stella/extensions/zz-own.json"; printf '{}\n' >"$T/repo/.stella/schemas/zz.schema.json"
g add -f .stella; g -c core.hooksPath=/dev/null commit -qm "owner data, as the owner committed it"
wcard() {  # wcard <id>: a worktree on a new branch off main; the commands that change it follow
  g worktree add -q -b "stella/$1-x" "$T/repo/.worktrees/$1" main; }
wcommit() {  # wcommit <id>: commit everything staged in the worktree, no hook
  git -C "$T/repo/.worktrees/$1" -c core.hooksPath=/dev/null commit -qm "card $1"; }
wcard t_0000c001   # plumbing only: hash-object, update-index --cacheinfo, write-tree, commit-tree, update-ref (no commit hook ever runs)
W1=$T/repo/.worktrees/t_0000c001
sha=$(printf '{"x": 1}\n' | git -C "$W1" hash-object -w --stdin)
git -C "$W1" update-index --add --cacheinfo 100644,$sha,$SETP
tr1=$(git -C "$W1" write-tree); c1=$(git -C "$W1" commit-tree "$tr1" -p HEAD -m plumbing); git -C "$W1" update-ref refs/heads/stella/t_0000c001-x "$c1"; git -C "$W1" reset -q --hard
h=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_0000c001 mc t_0000c001)" = 3 ] && grep -q "STL-CFG-312" "$T/out" && grep -qF "$SETP" "$T/out" && grep -q "nothing was merged" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ] && [ "$(grep -c "^STL-CFG-312 " "$T/sup/logs/alerts.log")" = 1 ]' "B3: an owner-data file added by plumbing (hash-object, update-index, commit-tree, update-ref): refused with the code, one alert line, main untouched"
ok '[ "$(mc t_0000c001 --owner-approved)" = 3 ] && grep -q "owner data" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "B3: --owner-approved does not lift it (owner data changes only through the apply tool)"
wcard t_0000c002; git -C "$T/repo/.worktrees/t_0000c002" mv .stella/extensions/zz-own.json moved-out.json; wcommit t_0000c002
ok '[ "$(FAKE_APPROVED=t_0000c002 mc t_0000c002)" = 3 ] && grep -q ".stella/extensions/zz-own.json" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "B3: a rename out of an owner folder is refused (both sides of a rename count)"
wcard t_0000c003; mkdir -p "$T/repo/.worktrees/t_0000c003/.stella/extensions"; echo x >"$T/repo/.worktrees/t_0000c003/.stella/extensions/é.json"; git -C "$T/repo/.worktrees/t_0000c003" add -f -A; wcommit t_0000c003
ok '[ "$(FAKE_APPROVED=t_0000c003 mc t_0000c003)" = 3 ] && grep -q "owner data" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "B3: a non-ASCII name under owner data is refused"
wcard t_0000c004; git -C "$T/repo/.worktrees/t_0000c004" rm -q .stella/schemas/zz.schema.json; wcommit t_0000c004
ok '[ "$(FAKE_APPROVED=t_0000c004 mc t_0000c004)" = 3 ] && grep -q "owner data" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "B3: a deletion of owner data is refused"
wcard t_0000c005; mkdir -p "$T/repo/.worktrees/t_0000c005/config"; echo x >"$T/repo/.worktrees/t_0000c005/config/owner.env"; git -C "$T/repo/.worktrees/t_0000c005" add -f -A; wcommit t_0000c005
ok '[ "$(FAKE_APPROVED=t_0000c005 mc t_0000c005)" = 3 ] && grep -q "owner" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "B3: an owner settings file is refused too"
wcard t_0000c006; mkdir -p "$T/repo/.worktrees/t_0000c006/docs/hermes-local/hooks"; echo '#!/bin/sh' >"$T/repo/.worktrees/t_0000c006/docs/hermes-local/hooks/zz-guard.sh"; git -C "$T/repo/.worktrees/t_0000c006" add -A; wcommit t_0000c006
ok '[ "$(FAKE_APPROVED=t_0000c006 mc t_0000c006)" = 3 ] && grep -q "define the boundary" "$T/out" && grep -q "docs/hermes-local/hooks/zz-guard.sh" "$T/out" && grep -q "i-have-read-the-boundary-changes" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "B3: a branch that edits a hook is refused without the flag, the paths listed"
ok '[ "$(FAKE_APPROVED=t_0000c006 mc t_0000c006 --i-have-read-the-boundary-changes)" = 0 ] && [ "$(head_of "$T/repo")" != "$h" ]' "B3: the same branch merges with the flag"
h=$(head_of "$T/repo")
wcard t_0000c007; mkdir -p "$T/repo/.worktrees/t_0000c007/.stella"; echo '{"x": 2}' >"$T/repo/.worktrees/t_0000c007/.stella/capabilities.json"; git -C "$T/repo/.worktrees/t_0000c007" add -f -A; wcommit t_0000c007
ok '[ "$(FAKE_APPROVED=t_0000c007 mc t_0000c007)" = 0 ] && [ "$(head_of "$T/repo")" != "$h" ]' "B3/G1: the capability registry (not an owner-only row) merges as before (product rule 4)"
# r7 A4: the test map selects a stack card's own merge tests, so it is a boundary path since round 6: a card that changes only the map needs the owner's flag
h=$(head_of "$T/repo"); wcard t_0000c008; mkdir -p "$T/repo/.worktrees/t_0000c008/.stella"; echo '{}' >"$T/repo/.worktrees/t_0000c008/.stella/test-map.json"; git -C "$T/repo/.worktrees/t_0000c008" add -f -A; wcommit t_0000c008; a0=$(wc -l <"$T/sup/logs/alerts.log")
ok '[ "$(FAKE_APPROVED=t_0000c008 mc t_0000c008)" = 3 ] && grep -q "STL-CFG-312" "$T/out" && grep -q "define the boundary.*\.stella/test-map\.json" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ] && [ "$(wc -l <"$T/sup/logs/alerts.log")" = $((a0+1)) ]' "r7 A4 (B3/G1): a card that changes only the test map is refused without the owner's flag (boundary code, the map named, one alert line), main untouched"
ok '[ "$(FAKE_APPROVED=t_0000c008 mc t_0000c008 --i-have-read-the-boundary-changes)" = 0 ] && [ "$(head_of "$T/repo")" != "$h" ]' "r7 A4 (B3/G1): the same card merges with --i-have-read-the-boundary-changes"
# K8/K12: the approval is read from runs of the profiles the role table lists as reviewing (roles.py reviewers), not from the
# literal name "reviewer". Fixture change: the stub's reviewer run takes its profile from FAKE_REVIEWER (default unchanged).
RT=${ROLES_FILE:-/workspace/docs/hermes-local/roles.json}
RVP=$(jq -r '. as $d | [.profiles | to_entries[] | select($d.roles[.value.role].may_review == true) | .key][0]' "$RT")
BLP=$(jq -r '. as $d | [.profiles | to_entries[] | select($d.roles[.value.role].may_review != true and $d.roles[.value.role].assignable == true) | .key][0]' "$RT")
ok '[ "$RVP" != null ] && [ "$BLP" != null ]' "K8: the role table has a reviewing profile ($RVP) and a non-reviewing assignable one ($BLP)"
rm -f "$FAKE_CARDS"/*.json
jq --arg o "$RVP" '.profiles["qa-x"] = .profiles[$o] | del(.profiles[$o]) | .sandbox.boxed_profiles += ["qa-x"]' "$RT" >"$T/renamed.json"   # the reviewing role, another profile name
echo not-json >"$T/garbage.json"; jq 'del(.roles[].may_review)' "$RT" >"$T/nomr.json"
card t_00000020 f20.txt twenty 'exit 0'; card t_00000021 f21.txt twentyone 'exit 0'; card t_00000022 f22.txt twentytwo 'exit 0'
card t_00000023 f23.txt twentythree 'exit 0'; card t_00000024 f24.txt twentyfour 'exit 0'; card t_00000025 f25.txt twentyfive 'exit 0'
h20=$(head_of "$T/repo")
ok '[ "$(FAKE_REVIEWER=$BLP FAKE_APPROVED=t_00000020 mc t_00000020)" = 3 ] && grep -q "no reviewer approval" "$T/out" && [ "$(head_of "$T/repo")" = "$h20" ]' "K8: the approved marker in a completed run of a non-reviewing profile ($BLP): refused, main untouched"
ok '[ "$(FAKE_REVIEWER=nobody-x FAKE_APPROVED=t_00000020 mc t_00000020)" = 3 ] && [ "$(head_of "$T/repo")" = "$h20" ]' "K8: the marker in a run of a profile the table does not list: refused"
for tf in garbage nomr nope; do
  ok '[ "$(ROLES_FILE=$T/$tf.json FAKE_REVIEWER=$RVP FAKE_APPROVED=t_00000020 mc t_00000020)" = 3 ] && [ "$(head_of "$T/repo")" = "$h20" ]' "K8: the table unreadable or invalid ($tf): the reviewer's marker counts for nothing, refused, main untouched"
done
ok '[ "$(ROLES_FILE=$T/renamed.json FAKE_REVIEWER=$RVP FAKE_APPROVED=t_00000020 mc t_00000020)" = 3 ] && [ "$(head_of "$T/repo")" = "$h20" ]' "K8: the old reviewer name when the table no longer lists it as reviewing: refused"
ok '[ "$(FAKE_REVIEWER=$RVP FAKE_APPROVED=t_00000020 mc t_00000020)" = 0 ] && [ "$(head_of "$T/repo")" != "$h20" ]' "K8: the marker in a completed run of a reviewing profile ($RVP) per the table: merged"
h21=$(head_of "$T/repo")
ok '[ "$(ROLES_FILE=$T/renamed.json FAKE_REVIEWER=qa-x FAKE_APPROVED=t_00000021 mc t_00000021)" = 0 ] && [ "$(head_of "$T/repo")" != "$h21" ]' "K8: the reviewing role under another profile name (no literal reviewer in merge-card.sh): merged"
mkdir -p "$T/lnk"; ln -s "$M" "$T/lnk/mc-link"; h22=$(head_of "$T/repo")
ok '[ "$(cd "$T/repo" && FAKE_REVIEWER=$RVP FAKE_APPROVED=t_00000022 "$T/lnk/mc-link" t_00000022 >"$T/out" 2>&1; echo $?)" = 0 ] && [ "$(head_of "$T/repo")" != "$h22" ]' "K8: run through a symlink: roles.py is found next to the real script, reviewer approval merges"
h23=$(head_of "$T/repo")
ok '[ "$(cd "$T/repo" && ROLES_FILE=$T/garbage.json FAKE_REVIEWER=$RVP FAKE_APPROVED=t_00000023 "$T/lnk/mc-link" t_00000023 >"$T/out" 2>&1; echo $?)" = 3 ] && [ "$(head_of "$T/repo")" = "$h23" ]' "K8: through a symlink with an unreadable table: refused"
ok '[ "$(FAKE_BUILDER_APPROVED=t_00000024 mc t_00000024)" = 3 ] && [ "$(FAKE_BUILDER_APPROVED=t_00000024 FAKE_REVIEWER=$BLP FAKE_APPROVED=t_00000024 mc t_00000024)" = 3 ]' "K8: a builder's own approved marker (alone, or beside a non-reviewer's) never merges"
ok '[ "$(FAKE_BUILDER_APPROVED=t_00000025 FAKE_REVIEWER=$RVP FAKE_APPROVED=t_00000025 mc t_00000025)" = 0 ]' "K8: a builder's marker beside a reviewing profile's approval: the reviewer's last run decides, merged"
# RT-A-02 (red-team of option A): on the case-insensitive /workspace mount a boxed worker can still rewrite the card worktree's
# .git file and the commondir/gitdir files under .git/worktrees/<id>. A plain `git -C <worktree> status` (merge-card's clean check)
# then runs the core.fsmonitor command of the config they point at, in the owner's shell. merge-card.sh must read the worktree
# through the main checkout's own entry (--git-dir, GIT_COMMON_DIR) with fsmonitor and hooks forced off, and a status that
# cannot be read must refuse (it used to read as "clean").
card t_0000a001 g1.txt one 'exit 0'; card t_0000a002 g2.txt two 'exit 0'; card t_0000a003 g3.txt three 'exit 0'; card t_0000a004 g4.txt four 'exit 0'; card t_0000a005 g5.txt five 'exit 0'; card t_0000a006 g6.txt six 'exit 0'; card t_0000a007 g7.txt seven 'exit 0'; card t_0000a008 g8.txt eight 'exit 0'
evil() { rm -rf "$T/evilcommon"; cp -a "$T/repo/.git" "$T/evilcommon"; git config --file "$T/evilcommon/config" core.fsmonitor "touch $T/fsm #"
  git config --file "$T/evilcommon/config" filter.evil.clean "touch $T/fsm #"; mkdir -p "$T/evilcommon/info"; echo "* filter=evil" > "$T/evilcommon/info/attributes"; rm -f "$T/fsm"; }
evil; printf 'gitdir: %s\n' "$T/evilcommon/worktrees/t_0000a004" > "$T/repo/.worktrees/t_0000a004/.git"
git -C "$T/repo/.worktrees/t_0000a004" status --porcelain >/dev/null 2>&1
ok '[ -e "$T/fsm" ]' "RT-A-02 premise: a plain git -C <worktree> status runs the fsmonitor command of a rewritten .git file"
git -C "$T/evilcommon" worktree prune 2>/dev/null; evil
printf 'gitdir: %s\n' "$T/evilcommon/worktrees/t_0000a001" > "$T/repo/.worktrees/t_0000a001/.git"; touch "$T/repo/.worktrees/t_0000a001/g1.txt"; h=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_0000a001 mc t_0000a001)" = 0 ] && [ ! -e "$T/fsm" ] && [ "$(head_of "$T/repo")" != "$h" ]' "RT-A-02: a rewritten .git file: merge-card runs neither its fsmonitor nor its clean filter (the clean card still merges)"
evil; printf '%s\n' "$T/evilcommon" > "$T/repo/.git/worktrees/t_0000a002/commondir"; touch "$T/repo/.worktrees/t_0000a002/g2.txt"; h=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_0000a002 mc t_0000a002)" = 0 ] && [ ! -e "$T/fsm" ] && [ "$(head_of "$T/repo")" != "$h" ]' "RT-A-02: a rewritten commondir: merge-card runs neither the fsmonitor nor the clean filter of the config it points at"
# config.worktree sits in the writable worktree entry and counts once the repo sets extensions.worktreeConfig (git sparse-checkout does)
g config core.repositoryformatversion 1; g config extensions.worktreeConfig true; rm -f "$T/fsm"
printf '[core]\n\tfsmonitor = touch %s #\n' "$T/fsm" > "$T/repo/.git/worktrees/t_0000a005/config.worktree"; h=$(head_of "$T/repo")
# T6 (F1 W4 r4): the card's tests run only in the OS box (K2), and the box refuses a repository whose worktrees read a config of their own
# (extensions.worktreeConfig: that file is builder-writable): such a card is refused, and nothing of its config runs (was: merged)
ok '[ "$(FAKE_APPROVED=t_0000a005 mc t_0000a005)" = 3 ] && grep -q "worktreeConfig" "$T/out" && [ ! -e "$T/fsm" ] && [ "$(head_of "$T/repo")" = "$h" ]' "RT-A-02: a worktree config.worktree with core.fsmonitor: not run (-c core.fsmonitor=)"
mkdir -p "$T/evilhooks"; printf '#!/bin/sh\ntouch %s\n' "$T/fsm" > "$T/evilhooks/post-index-change"; chmod +x "$T/evilhooks/post-index-change"
printf '[core]\n\thooksPath = %s\n' "$T/evilhooks" > "$T/repo/.git/worktrees/t_0000a006/config.worktree"; touch "$T/repo/.worktrees/t_0000a006/g6.txt"
git -C "$T/repo/.worktrees/t_0000a006" status --porcelain >/dev/null 2>&1; ok '[ -e "$T/fsm" ]' "RT-A-02 premise: a plain status that refreshes the index runs the post-index-change hook of a worktree config.worktree"
rm -f "$T/fsm"; touch "$T/repo/.worktrees/t_0000a006/g6.txt"; h=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_0000a006 mc t_0000a006)" = 3 ] && grep -q "worktreeConfig" "$T/out" && [ ! -e "$T/fsm" ] && [ "$(head_of "$T/repo")" = "$h" ]' "RT-A-02: a worktree config.worktree with core.hooksPath: its index hook is not run (-c core.hooksPath=/dev/null)"
g config --unset extensions.worktreeConfig; g config core.repositoryformatversion 0   # the cases below are not about worktree configs
printf 'dirty\n' >> "$T/repo/.worktrees/t_0000a007/g7.txt"; printf 'garbage\n' > "$T/repo/.worktrees/t_0000a007/.git"; h=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_0000a007 mc t_0000a007)" = 3 ] && grep -q "is not clean" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "RT-A-02: a dirty worktree whose .git file was overwritten is read through the main checkout's entry: refused as not clean"
# a submodule's git dir lives inside the writable worktree entry (worktrees/<id>/modules/<name>): its config is worker-controlled too, and
# status descends into the submodule (V-RTA-01)
git init -q "$T/subrepo"; printf 'in\n' > "$T/subrepo/s.txt"; git -C "$T/subrepo" add s.txt; git -C "$T/subrepo" -c core.hooksPath=/dev/null commit -qm sub
W8="$T/repo/.worktrees/t_0000a008"; git -C "$W8" -c protocol.file.allow=always submodule add -q "$T/subrepo" sub >/dev/null 2>&1; git -C "$W8" -c core.hooksPath=/dev/null commit -qm "add sub"
SM="$T/repo/.git/worktrees/t_0000a008/modules/sub"; printf '[filter "evil"]\n\tclean = touch %s #\n[core]\n\tfsmonitor = touch %s #\n' "$T/fsm" "$T/fsm" >> "$SM/config"; mkdir -p "$SM/info"; echo "* filter=evil" > "$SM/info/attributes"
rm -f "$T/fsm"; touch "$W8/sub/s.txt"; h=$(head_of "$T/repo")
git -C "$W8" status --porcelain >/dev/null 2>&1; ok '[ -e "$T/fsm" ]' "RT-A-02 premise: a plain status in a worktree with a submodule runs the clean filter or fsmonitor in the submodule's worktree-entry config"
rm -f "$T/fsm"; touch "$W8/sub/s.txt"
ok '[ "$(FAKE_APPROVED=t_0000a008 mc t_0000a008)" = 0 ] && [ ! -e "$T/fsm" ] && [ "$(head_of "$T/repo")" != "$h" ]' "RT-A-02: a submodule config in the worktree entry: its clean filter and fsmonitor are not run (--ignore-submodules=dirty)"
printf 'garbage' > "$T/repo/.git/worktrees/t_0000a003/index"; h=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_0000a003 mc t_0000a003)" = 3 ] && grep -q "cannot read" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "RT-A-02: a worktree whose status cannot be read is refused, not taken as clean"
# HH-05: the approval counts for the commit the reviewer saw: the branch must not have moved since the reviewer's run started
# (the branch reflog is written only outside the box, so a boxed builder cannot forge it). FAKE_REVIEW_STARTED: epoch seconds
# of that run (default: far future, so the older cases above are unchanged); "none": the run record has no start time.
for n in 1 2 3 4; do card t_0000b00$n b$n.txt b$n 'exit 0'; done
h=$(head_of "$T/repo")
ok '[ "$(FAKE_REVIEW_STARTED=1 FAKE_APPROVED=t_0000b001 mc t_0000b001)" = 3 ] && grep -q "moved after the review" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "HH-05: the branch changed after the reviewer's run started: refused, main untouched"
ok '[ "$(FAKE_REVIEW_STARTED=none FAKE_APPROVED=t_0000b002 mc t_0000b002)" = 3 ] && grep -q "no start time" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "HH-05: a reviewer run with no start time cannot be tied to a commit: refused"
rm -f "$T/repo/.git/logs/refs/heads/stella/t_0000b003-x"
ok '[ "$(FAKE_APPROVED=t_0000b003 mc t_0000b003)" = 3 ] && grep -q "no reflog" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "HH-05: a branch with no reflog cannot be checked: refused"
ok '[ "$(FAKE_APPROVED=t_0000b004 mc t_0000b004)" = 0 ] && [ "$(head_of "$T/repo")" != "$h" ]' "HH-05: the branch last moved before the reviewer's run started: merged"
h=$(head_of "$T/repo"); card t_0000b005 b5.txt b5 'exit 0'
ok '[ "$(FAKE_REVIEW_STARTED=1 mc t_0000b005 --owner-approved)" = 0 ] && [ "$(head_of "$T/repo")" != "$h" ]' "HH-05: --owner-approved is the owner's own review of the branch as it is now: no reviewer timing applies"
# N1: an object swapped while the card's own tests run (after the first fsck, before the merge): the second fsck refuses it.
# Before the VH-02 row, which leaves a damaged object in this repo for every later card.
bh=$(printf 'b7\n' | git hash-object --stdin); of7="$T/repo/.git/objects/${bh:0:2}/${bh:2}"
body=$(cat <<B
chmod u+w $of7; python3 -c 'import sys,zlib; open(sys.argv[1],"wb").write(zlib.compress(b"blob 5\0EVIL\n"))' $of7
B
)
card t_0000b007 b7.txt b7 "$body"; h=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_0000b007 mc t_0000b007)" = 3 ] && grep -q "fsck" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "N1: an object swapped while the card's tests ran: refused by the second fsck, main untouched"
rm -f "$of7"; printf 'b7\n' | g hash-object -w --stdin >/dev/null   # put the blob back: VH-02 below must fail on its own damage, not on this one
# VH-02: a box writes the shared objects folder, so the content behind an unmoved, reviewed commit can change; git fsck sees it
card t_0000b006 b6.txt b6 'exit 0'; h=$(head_of "$T/repo")
blob=$(g rev-parse "stella/t_0000b006-x:b6.txt"); of="$T/repo/.git/objects/${blob:0:2}/${blob:2}"
chmod u+w "$of"; python3 -c 'import sys,zlib; open(sys.argv[1],"wb").write(zlib.compress(b"blob 5\0EVIL\n"))' "$of"
ok '[ "$(FAKE_APPROVED=t_0000b006 mc t_0000b006)" = 3 ] && grep -q "fsck" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "VH-02: an object whose content does not match its id (written through a shared objects folder): refused, main untouched"
rm -f "$of"; printf 'b6\n' | g hash-object -w --stdin >/dev/null   # put the blob back: the cases below must fail (or merge) on their own merits, not on this damage
# F1 W4 round 3 (K1, K2, K8): the merge judges the tree the merge will produce, the card's tests run in the box, every refusal is coded once.
RF=${ROLES_FILE:-/workspace/docs/hermes-local/roles.json}; IDX=/workspace/$(jq -r .data_index "$RF")
mapfile -t STATE < <(jq -r '.backup_dir + "/planted-by-card", .applied_state, .event_log' "$IDX")   # the apply tool's state paths, from the index
cat /workspace/.gitignore >>"$T/repo/.gitignore"; g add .gitignore; g -c core.hooksPath=/dev/null commit -qm "the stack's ignore rules"   # the state paths are ignored in a real main checkout
for s in "${STATE[@]}"; do mkdir -p "$T/repo/${s%/*}"; printf 'OWNER-STATE\n' >"$T/repo/$s"; done
nal() { wc -l <"$T/sup/logs/alerts.log"; }
k=0
for s in "${STATE[@]}"; do   # K1: a state path force-added by a card (the parent folder, the form no hook refuses) is refused like owner data
  k=$((k+1)); c=t_0000d00$k; wcard $c; mkdir -p "$T/repo/.worktrees/$c/${s%/*}"; printf 'WORKER\n' >"$T/repo/.worktrees/$c/$s"
  git -C "$T/repo/.worktrees/$c" add -f -- "${s%%/*}"; wcommit $c; h=$(head_of "$T/repo")
  ok '[ "$(FAKE_APPROVED='$c' mc '$c')" = 3 ] && grep -q "STL-CFG-312" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ] && [ "$(cat "$T/repo/'$s'")" = OWNER-STATE ]' "K1: a branch that commits the state path $s is refused, the owner's file is kept"
done
# K1: two merge bases (a criss-cross): a branch that rolls an owner-data file back to an older version is refused like any other change of it
mkdir -p "$T/repo/${SETP%/*}"; printf '{"v": "old"}\n' >"$T/repo/$SETP"; g add -f "$SETP"; g -c core.hooksPath=/dev/null commit -qm "owner data baseline"
wt_() { git -C "$T/repo/.worktrees/$1" "${@:2}"; }
wcard t_0000d0a1; printf 'a\n' >"$T/repo/.worktrees/t_0000d0a1/a-card.txt"; wt_ t_0000d0a1 add a-card.txt; GIT_COMMITTER_DATE="2030-01-01T00:00:00Z" wt_ t_0000d0a1 -c core.hooksPath=/dev/null commit -qm "card A"
C1=$(wt_ t_0000d0a1 rev-parse HEAD)
printf '{"v": "new"}\n' >"$T/repo/$SETP"; g -c core.hooksPath=/dev/null commit -qam "owner: a new value"; P=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_0000d0a1 mc t_0000d0a1)" = 0 ]' "K1 setup: card A merges"
g worktree add -q -b stella/t_0000d0b2-x "$T/repo/.worktrees/t_0000d0b2" "$C1"; wt_ t_0000d0b2 -c core.hooksPath=/dev/null merge -q --no-edit "$P" >/dev/null
printf '{"v": "old"}\n' >"$T/repo/.worktrees/t_0000d0b2/$SETP"; printf 'b\n' >"$T/repo/.worktrees/t_0000d0b2/b-card.txt"; wt_ t_0000d0b2 add b-card.txt; wt_ t_0000d0b2 -c core.hooksPath=/dev/null commit -qam "card B"
h=$(head_of "$T/repo")
ok '[ "$(g merge-base --all main stella/t_0000d0b2-x | wc -l)" = 2 ] && [ "$(FAKE_APPROVED=t_0000d0b2 mc t_0000d0b2)" = 3 ] && [ "$(head_of "$T/repo")" = "$h" ] && grep -q "\"new\"" "$T/repo/$SETP"' "K1: a branch with two merge bases that rolls owner data back is refused, main keeps the owner's value"
# K1: main renames a plain file into owner data; a branch that edits the old name would carry its edit into owner data
OD=$(jq -r '.owner_data[0]' "$RF"); seq 1 40 | sed 's/^/line /' >"$T/repo/rn.txt"; g add rn.txt; g -c core.hooksPath=/dev/null commit -qm "plain file"
wcard t_0000d0c3; sed -i 's/^line 20$/line 20 edited by a card/' "$T/repo/.worktrees/t_0000d0c3/rn.txt"; git -C "$T/repo/.worktrees/t_0000d0c3" add -A; wcommit t_0000d0c3
mkdir -p "$T/repo/$OD"; g mv rn.txt "$OD/rn.txt"; g add -f "$OD"; g -c core.hooksPath=/dev/null commit -qm "owner: the file moves into owner data"; h=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_0000d0c3 mc t_0000d0c3)" = 3 ] && grep -qF "$OD/rn.txt" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "K1: a main-side rename into owner data cannot carry a branch edit of the old name in (the merged tree is compared)"
# K1b: a protected folder is the same folder under any spelling (case, and the 8.3 short name where this mount has one)
wcard t_0000d0d4; mkdir -p "$T/repo/.worktrees/t_0000d0d4/${OD%%/*}"; mkdir -p "$T/repo/.worktrees/t_0000d0d4/$(echo "$OD" | tr a-z A-Z)"; printf 'x\n' >"$T/repo/.worktrees/t_0000d0d4/$(echo "$OD" | tr a-z A-Z)/new.json"
git -C "$T/repo/.worktrees/t_0000d0d4" add -f -A; wcommit t_0000d0d4; h=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_0000d0d4 mc t_0000d0d4)" = 3 ] && [ "$(head_of "$T/repo")" = "$h" ]' "K1b: a new file in an upper-case spelling of an owner data folder is refused"
# K2: the card's test command runs in the OS box: it cannot write the owner settings file, owner data of the main checkout or a state path, and no owner command works
OSF=/workspace/$(jq -r '.owner_settings[0]' "$RF"); osum=$(cksum <"$OSF" 2>/dev/null); ssum=$(cksum <"$T/repo/$SETP"); stsum=$(cksum <"$T/repo/${STATE[1]}")
body=$(cat <<B
printf x >>$OSF; printf x >>"$T/repo/$SETP"; printf x >>"$T/repo/${STATE[1]}"; python3 /workspace/bin/settings.py set zz yy; /workspace/bin/merge-card.sh t_00000000; true
B
)
card t_0000d0e5 e5.txt e5 "$body"; h=$(head_of "$T/repo")
mc t_0000d0e5 --owner-approved >/dev/null
ok '[ "$(cksum <"$OSF" 2>/dev/null)" = "$osum" ] && [ "$(cksum <"$T/repo/$SETP")" = "$ssum" ] && [ "$(cksum <"$T/repo/${STATE[1]}")" = "$stsum" ]' "K2: a test command that writes the owner settings file, owner data and a state path, and runs owner commands, changes none of them"
bad=$(printf 'echo $HERMES_KANBAN_TASK $HERMES_KANBAN_WORKSPACE >/tmp/marked; test -n "$(cat /tmp/marked | cut -d" " -f1)"; ls /workspace/%s >/dev/null 2>&1 && exit 1; exit 0' "$(jq -r '.owner_settings[0]' "$RF")")
card t_0000d0f6 f6.txt f6 "$bad"
ok '[ "$(mc t_0000d0f6 --owner-approved)" = 0 ]' "K2: in the box the worker markers are set and the owner settings file is not mounted"
# K2: where the box cannot start the merge is refused, coded, and the tests do not run unboxed
card t_0000d0f7 f7.txt f7 "touch $T/ran-unboxed"; h=$(head_of "$T/repo")
ok '[ "$(BOX_HERMES_ROOT=$T/nohermes mc t_0000d0f7 --owner-approved)" = 3 ] && grep -q "STL-GRD-605" "$T/out" && grep -q "could not start" "$T/out" && [ ! -e "$T/ran-unboxed" ] && [ "$(head_of "$T/repo")" = "$h" ]' "K2: the box cannot start: refused with a coded line, nothing ran outside it, main untouched"
# B.2 point 11 (r5, W4-VAL3-01, W4-CV3-05): a card test that itself exits 126 is a test failure, never "box could not start"; a lock a test writes into its
# throw-away worktree entry does not refuse the next merge of the same card uncoded
card t_0000e126 e126.txt e126 'exit 126'; h=$(head_of "$T/repo")
ok '[ "$(mc t_0000e126 --owner-approved)" = 3 ] && grep -q "tests failed" "$T/out" && ! grep -q "could not start" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "B.2 point 11: a card test that exits 126 is a test failure, not 'box could not start'"
card t_0000e127 e127.txt e127 'mkdir -p "$(git rev-parse --git-dir)/worktrees"; d="$(git rev-parse --git-common-dir)/worktrees/merge-check-t_0000e127"; touch "$d/locked" 2>/dev/null || true; exit 0'; h=$(head_of "$T/repo")
ok '[ "$(mc t_0000e127 --owner-approved)" = 0 ] && [ "$(head_of "$T/repo")" != "$h" ] && [ "$(mc t_0000e127 --owner-approved)" = 3 ]' "B.2 point 11: a test that locks its throw-away worktree entry still merges, and the entry is cleared (the next merge of the same card is not refused by a stale lock; second run refused because it is no longer ahead)"
# r6 (R14): the verdict of the boxed run comes on a pipe the test never holds, so every exit code a test can choose is "tests failed" with that code
for x in 1 70 124 125 137 255; do c=t_0000c6$(printf %02x $x); card $c f$x.txt f$x "echo QA-RAN-$x; exit $x"; h=$(head_of "$T/repo")
  ok '[ "$(mc $c --owner-approved)" = 3 ] && grep -q "QA-RAN-$x" "$T/out" && grep -q "STL-GRD-606.*tests failed.*exit $x)" "$T/out" && ! grep -q "could not" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "r6: a card test that ran and exited $x is 'tests failed' with that code, never a box or worktree fault"
done
card t_0000f301 f301.txt f301 'd=$(git rev-parse --absolute-git-dir); rm -f "$d/box-started"; echo 9 >"$d/box-signal"; exit 0'; h=$(head_of "$T/repo")
ok '[ "$(mc t_0000f301 --owner-approved)" = 0 ] && [ "$(head_of "$T/repo")" != "$h" ]' "r6: files a test writes or removes in its git dir (the round-5 start marker and signal file) say nothing: a passing test merges"
card t_0000f302 f302.txt f302 'd=$(git rev-parse --absolute-git-dir); rm -f "$d/box-started"; echo 9 >"$d/box-signal"; echo "ran 0" >&3; echo "ran 0"; exit 7'; h=$(head_of "$T/repo")
ok '[ "$(mc t_0000f302 --owner-approved)" = 3 ] && grep -q "tests failed.*exit 7)" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "r6: a failing test that forges the old markers and prints a verdict line is still 'tests failed' with its own code"
# B.2 point 11 (W4-VAL3-12), not run by tester R14: a table whose only boxed profiles with a card worktree carry broker variables has no box for a card's tests
jq '. as $d | reduce (.sandbox.boxed_profiles[] | select($d.roles[$d.profiles[.].role].workspace == "git-worktree")) as $p (.; .sandbox.profile_overrides[$p].broker_env = {QA_TOKEN: "qa-broker"})' "$RF" >"$T/brokeronly.json"
card t_0000f303 f303.txt f303 'echo QA-RAN-BROKER; exit 0'; h=$(head_of "$T/repo"); a0=$(nal)
ok '[ "$(ROLES_FILE=$T/brokeronly.json mc t_0000f303 --owner-approved)" = 3 ] && grep -q "without broker variables" "$T/out" && grep -q "STL-GRD-605" "$T/out" && ! grep -q QA-RAN-BROKER "$T/out" && [ "$(nal)" = $((a0+1)) ] && [ "$(head_of "$T/repo")" = "$h" ]' "B.2 point 11: only broker-carrying profiles: refused with one coded line, the test never ran, main untouched"
# r6 C5 (W4-CV3-11): a commit hook of the owner's repository that still runs (post-commit) and changes the merge commit is said loudly, exit 1
card t_0000f304 f304.txt f304; h=$(head_of "$T/repo")
printf '#!/bin/sh\necho hooked >zz-hooked.txt; git add zz-hooked.txt; git -c core.hooksPath=/dev/null commit -q --amend --no-edit\n' >"$T/repo/.git/hooks/post-commit"; chmod +x "$T/repo/.git/hooks/post-commit"
ok '[ "$(mc t_0000f304 --owner-approved)" = 1 ] && grep -q "NOT THE TREE THAT WAS CHECKED" "$T/out" && ! grep -q "^merged " "$T/out"' "r6 C5 (W4-CV3-11): a merge commit changed by a commit hook is not the checked tree: said loudly, exit 1, no 'merged' line"
rm -f "$T/repo/.git/hooks/post-commit"; g reset -q --hard "$h"
# K8: the boundary refusal and an unreadable list are coded, with one alert line each
HOOK=$(jq -r '[.roles[].hooks[]? | .file // empty] | first' "$RF"); mkdir -p "$T/repo/${HOOK%/*}"; printf '#!/bin/sh\n' >"$T/repo/$HOOK"; g add -f "$HOOK"; g -c core.hooksPath=/dev/null commit -qm "a hook file"
wcard t_0000d0a8; printf '#!/bin/sh\nexit 0\n' >"$T/repo/.worktrees/t_0000d0a8/$HOOK"; git -C "$T/repo/.worktrees/t_0000d0a8" add -f -A; wcommit t_0000d0a8
a0=$(nal); ok '[ "$(FAKE_APPROVED=t_0000d0a8 mc t_0000d0a8)" = 3 ] && grep -q "STL-CFG-312" "$T/out" && [ "$(nal)" = $((a0+1)) ]' "K8: the boundary refusal carries a catalog code and writes one alert line"
a0=$(nal); ok '[ "$(ROLES_FILE=$T/garbage.json FAKE_APPROVED=t_0000d0a8 mc t_0000d0a8)" = 3 ] && grep -q "STL-CFG-303" "$T/out" && [ "$(nal)" -le $((a0+2)) ]' "K8: the lists unreadable: a coded refusal"
# B.3 point 17 (r5, W4-VER3-01): the merge never replaces or removes a file of the main checkout that git does not track there. A card that force-adds a
# path main's ignore rules ignore, or turns an ignored folder into a file, is refused before anything is written; main (its ignored file too) unchanged
printf 'zz-ign.txt\nzz-idir/\n' >>"$T/repo/.gitignore"; g add .gitignore; g -c core.hooksPath=/dev/null commit -qm "ignore two local paths"
printf 'OWNER-LOCAL\n' >"$T/repo/zz-ign.txt"; mkdir -p "$T/repo/zz-idir"; printf 'OWNER-LOCAL\n' >"$T/repo/zz-idir/f"
k7=0; for sp in zz-ign.txt zz-idir; do k7=$((k7+1)); c=t_0000f0$(printf '%02x' "$k7"); wcard $c
  printf 'CARD\n' >"$T/repo/.worktrees/$c/$sp"; git -C "$T/repo/.worktrees/$c" add -f -- "$sp"; wcommit $c; h=$(head_of "$T/repo")
  ok '[ "$(FAKE_APPROVED='$c' mc '$c' --owner-approved)" = 3 ] && grep -q "STL-GRD-607" "$T/out" && grep -qF "'$sp'" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ] && [ "$(cat "$T/repo/zz-ign.txt")" = OWNER-LOCAL ] && [ "$(cat "$T/repo/zz-idir/f")" = OWNER-LOCAL ]' "B.3 point 17: a card whose merge would replace the untracked $sp of the main checkout is refused, the main checkout byte-identical"
done
c=t_0000f0a1; wcard $c; mkdir -p "$T/repo/.worktrees/$c/zz-idir/sub"; printf 'CARD\n' >"$T/repo/.worktrees/$c/zz-idir/sub/new.txt"; git -C "$T/repo/.worktrees/$c" add -f -- zz-idir/sub/new.txt; wcommit $c; h=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED='$c' mc '$c' --owner-approved)" = 3 ] && grep -q "STL-GRD-607" "$T/out" && grep -qF "zz-idir/sub/new.txt (untracked at zz-idir)" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "r6 T5: the refusal names the path the merge would write and the untracked folder above it, not the folder alone"
printf 'local\n' >"$T/repo/zz-untracked-local.txt"; a0=$(nal)
ok '[ "$(FAKE_APPROVED='$c' mc '$c' --owner-approved)" = 3 ] && grep -q "STL-GRD-607" "$T/out" && grep -q "is not clean" "$T/out" && [ "$(nal)" = $((a0+1)) ] && [ "$(head_of "$T/repo")" = "$h" ]' "r6 C2: a main checkout that is not clean (an untracked file) is refused with a code and one alert line"
rm -f "$T/repo/zz-untracked-local.txt"
c=t_0000f0a0; wcard $c; printf 'new\n' >"$T/repo/.worktrees/$c/zz-new-tracked.txt"; git -C "$T/repo/.worktrees/$c" add zz-new-tracked.txt; wcommit $c; h=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED='$c' mc '$c' --owner-approved)" = 0 ] && [ "$(head_of "$T/repo")" != "$h" ]' "B.3 point 17 control: a card adding a new tracked path where nothing exists merges"
# r7 A2 (W4-CV4-01): a card that turns a TRACKED folder of main into a file or a link: git's checkout would remove the folder with every ignored file in it, so
# an untracked file below it refuses the merge before anything is written; with no such file the same card merges
printf 'zz-td/keep.local\n' >>"$T/repo/.gitignore"; mkdir -p "$T/repo/zz-td"; printf 'tracked\n' >"$T/repo/zz-td/a.txt"; g add .gitignore zz-td/a.txt; g -c core.hooksPath=/dev/null commit -qm "a tracked folder with an ignored local file rule"
printf 'OWNER-LOCAL\n' >"$T/repo/zz-td/keep.local"
for kd in file link; do c=t_0000f7a4; [ $kd = file ] || c=t_0000f7a6; wcard $c; rm -rf "$T/repo/.worktrees/$c/zz-td"
  if [ $kd = file ]; then printf 'CARD\n' >"$T/repo/.worktrees/$c/zz-td"; else ln -s /tmp "$T/repo/.worktrees/$c/zz-td"; fi
  git -C "$T/repo/.worktrees/$c" add -A; wcommit $c; h=$(head_of "$T/repo")
  ok '[ "$(mc '$c' --owner-approved)" = 3 ] && grep -q "STL-GRD-607" "$T/out" && grep -qF "zz-td/keep.local" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ] && [ "$(cat "$T/repo/zz-td/keep.local")" = OWNER-LOCAL ]' "r7 A2: a card that turns the tracked folder zz-td into a $kd is refused (607 names the untracked file below it), head unchanged, the file byte-identical"
done
rm -f "$T/repo/zz-td/keep.local"; h=$(head_of "$T/repo")
ok '[ "$(mc t_0000f7a4 --owner-approved)" = 0 ] && [ "$(head_of "$T/repo")" != "$h" ] && [ -f "$T/repo/zz-td" ]' "r7 A2 control: the same folder-to-file card merges when the folder holds no untracked file"
# B.1 point 6 (r5, W1-RT6-01): a card branch that replaces a folder holding an owner path (the owner settings' folder, owner data's, the apply tool's
# state's) by a symbolic link is refused, and the main checkout's folder stays a folder
for hd in "$(jq -r '.owner_settings[0]' "$RF" | cut -d/ -f1)" "$(jq -r '.owner_data[0]' "$RF" | cut -d/ -f1)" "$(jq -r .applied_state "$IDX" | cut -d/ -f1)"; do
  mkdir -p "$T/repo/$hd"; echo x >"$T/repo/$hd/zz-held-$k.txt"; g add -f "$hd/zz-held-$k.txt"; g -c core.hooksPath=/dev/null commit -qm "a file in $hd"; k=$((k+1))
  c=t_0000e0$(printf '%02x' "$k"); wcard $c; W6=$T/repo/.worktrees/$c
  git -C "$W6" rm -r -q --cached "$hd"; rm -rf "${W6:?}/$hd"; ln -s /tmp "$W6/$hd"; git -C "$W6" add -f "$hd"; wcommit $c; h=$(head_of "$T/repo")
  ok '[ "$(FAKE_APPROVED='$c' mc '$c' --owner-approved)" = 3 ] && grep -q "STL-CFG-312" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ] && [ -d "$T/repo/'$hd'" ] && [ ! -L "$T/repo/'$hd'" ]' "B.1 (r5): a card branch replacing the folder $hd (it holds an owner path) by a symbolic link is refused, the main checkout's folder kept"
done
# T9 (F1 W4 r4): a data file the boundary code loads by a fixed path (the alert catalog, and the alert-code page made from it) is a boundary path: a card that
# changes it is refused without the owner's flag, with the boundary code, and lands with it (the owner path)
CAT=$(jq -r '[.boundary_paths[] | select(endswith(".json")) | select(. != "docs/hermes-local/roles.json")][0]' "$RF"); ACD=$(jq -r '[.boundary_paths[] | select(endswith(".md"))][0]' "$RF")
for f in "$CAT" "$ACD"; do mkdir -p "$T/repo/${f%/*}"; printf 'owner version\n' >"$T/repo/$f"; g add -f "$f"; done; g -c core.hooksPath=/dev/null commit -qm "catalog and code page, as the owner has them"
wcard t_0000d0a9; for f in "$CAT" "$ACD"; do printf 'a card adds a code\n' >"$T/repo/.worktrees/t_0000d0a9/$f"; done; git -C "$T/repo/.worktrees/t_0000d0a9" add -f -A; wcommit t_0000d0a9; h=$(head_of "$T/repo")
a0=$(nal); ok '[ "$(FAKE_APPROVED=t_0000d0a9 mc t_0000d0a9)" = 3 ] && grep -q "STL-CFG-312" "$T/out" && grep -q "define the boundary" "$T/out" && grep -qF "$CAT" "$T/out" && grep -qF "$ACD" "$T/out" && [ "$(nal)" = $((a0+1)) ] && [ "$(head_of "$T/repo")" = "$h" ]' "T9: a card that changes the alert catalog ($CAT) and its code page is refused without the flag (boundary code, one alert line, both listed), main untouched"
ok '[ "$(FAKE_APPROVED=t_0000d0a9 mc t_0000d0a9 --i-have-read-the-boundary-changes)" = 0 ] && [ "$(head_of "$T/repo")" != "$h" ] && grep -q "a card adds a code" "$T/repo/$CAT"' "T9: the same card lands by the owner path (--i-have-read-the-boundary-changes)"
# r6 B2 (owner decision 4, W4-CV3-02; phase finding ORCH-03): a card of the stack itself merges with the test map's selection for its diff plus the quick tier,
# read from and run in the tree under test, through the real suite runner, in the box. The scratch stack is this tree's tracked files with a two-name suite and a
# stub map tool (select: zz-mapped.txt -> zz-alpha, zz-red.txt -> zz-red, zz-full.txt -> full; quick: zz-beta, or an error once zz-noquick.txt is in the tree).
SR=$T/srepo; mkdir -p "$SR"; git -C /workspace ls-files -z | tar -c -C /workspace --null -T - -f - | tar -x -C "$SR" -f -
sed -i 's/^for t in alert .*; do$/for t in zz-alpha zz-beta; do/' "$SR/bin/selftests.sh"
cat >"$SR/bin/test-map.py" <<'S'
#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
if a == ["quick"]:
    sys.exit(1) if os.path.exists("zz-noquick.txt") else print("zz-beta")
elif a[:1] == ["select"]:
    f = sys.stdin.read().split("\n")
    print("full" if "zz-full.txt" in f else "zz-red" if "zz-red.txt" in f else "zz-alpha" if "zz-mapped.txt" in f else "zz-alpha")
S
for n in alpha beta; do printf '#!/usr/bin/env bash\necho "ok   %s ran in $(pwd)"; echo "selftest PASS"\n' "$n" >"$SR/bin/zz-$n-selftest.sh"; done
printf '#!/usr/bin/env bash\necho "FAIL zz-red case"; echo "selftest FAIL (1)"; exit 1\n' >"$SR/bin/zz-red-selftest.sh"; chmod +x "$SR"/bin/zz-*-selftest.sh "$SR/bin/test-map.py"
git -C "$SR" init -q -b main; git -C "$SR" add -A; git -C "$SR" -c core.hooksPath=/dev/null commit -qm "a scratch stack"
smc() { (cd "$SR" && "$SR/bin/merge-card.sh" "$@") >"$T/out" 2>&1; echo $?; }
scard() {  # scard <id> <file> <content>...: a card of the scratch stack with one commit changing the files given as pairs
  local c=$1 w="$SR/.worktrees/$1"; shift; git -C "$SR" worktree add -q -b "stella/$c-x" "$w" main
  while [ $# -ge 2 ]; do mkdir -p "$w/$(dirname "$1")"; printf '%s\n' "$2" >"$w/$1"; shift 2; done
  git -C "$w" add -f -A; git -C "$w" -c core.hooksPath=/dev/null commit -qm "card $c"; }
ok 'grep -q "zz-alpha zz-beta" "$SR/bin/selftests.sh" && [ "$(readlink -f "$SR/bin/merge-card.sh")" != "$(readlink -f "$M")" ]' "B2 set-up: the scratch stack has its own merge script and a two-name suite"
scard t_0000b201 zz-mapped.txt x; h=$(head_of "$SR")
ok '[ "$(smc t_0000b201 --owner-approved)" = 0 ] && grep -q "^ok   zz-alpha-selftest" "$T/out" && grep -q "^ok   zz-beta-selftest" "$T/out" && ! grep -q "the whole suite" "$T/out" && [ "$(head_of "$SR")" != "$h" ]' "B2: a stack card touching one mapped file runs the selected selftest and the quick tier through the runner (isolated, in the box) and merges"
scard t_0000b202 zz-red.txt x; h=$(head_of "$SR")
ok '[ "$(smc t_0000b202 --owner-approved)" = 3 ] && grep -q "FAIL zz-red-selftest" "$T/out" && grep -q "^ok   zz-beta-selftest" "$T/out" && grep -q "tests failed" "$T/out" && ! grep -q "(npm test" "$T/out" && [ "$(head_of "$SR")" = "$h" ]' "B2: a stack card whose selected selftest fails is refused (tests failed; r7 B6: the line does not call the selected selftests npm test), main untouched"
scard t_0000b203 zz-full.txt x; h=$(head_of "$SR")
ok '[ "$(smc t_0000b203 --owner-approved)" = 0 ] && grep -q "the whole suite" "$T/out" && grep -q "^ok   zz-alpha-selftest" "$T/out" && grep -q "^ok   zz-beta-selftest" "$T/out" && [ "$(head_of "$SR")" != "$h" ]' "B2: select answers full: the whole suite of the tree under test runs"
scard t_0000b204 zz-mapped.txt y bin/zz-alpha-selftest.sh 'echo "FAIL the card changed this selftest"; exit 1'; h=$(head_of "$SR")
ok '[ "$(smc t_0000b204 --owner-approved)" = 3 ] && grep -q "FAIL zz-alpha-selftest" "$T/out" && grep -q "tests failed" "$T/out" && [ "$(head_of "$SR")" = "$h" ]' "B2 (ORCH-03): the selftest that runs is the one of the tree under test (the card's own version), never the main checkout's file"
scard t_0000b205 zz-noquick.txt x; h=$(head_of "$SR")
ok '[ "$(smc t_0000b205 --owner-approved)" = 3 ] && grep -q "quick list of the test map cannot be read" "$T/out" && grep -q "tests failed" "$T/out" && [ "$(head_of "$SR")" = "$h" ]' "B2: a quick list that cannot be read fails the tests (never a set without the quick tier)"
k=5; for bp in bin/test-map.py bin/selftests.sh .stella/test-map.json; do k=$((k+1)); c=t_0000b20$k; scard $c "$bp" '# a card edits it'; h=$(head_of "$SR")
  ok '[ "$(smc $c --owner-approved)" = 3 ] && grep -q "STL-CFG-312" "$T/out" && grep -q "define the boundary" "$T/out" && grep -qF "$bp" "$T/out" && [ "$(head_of "$SR")" = "$h" ]' "B2: a card that changes $bp (what selects or runs its own tests) is behind the owner's flag"
done
II=__init''__.py; scard t_0000b2a8 "bin/roles/$II" '# a comment'; h=$(head_of "$SR")   # r8 A (W4-CV5-01): python loads the package folder instead of the module beside it
ok '[ "$(smc t_0000b2a8 --owner-approved)" = 3 ] && grep -q "STL-CFG-312" "$T/out" && grep -q "define the boundary" "$T/out" && grep -qF "bin/roles/$II" "$T/out" && [ "$(head_of "$SR")" = "$h" ]' "r8 A (W4-CV5-01): a stack card that adds a package folder named like a module of the boundary's own folder is refused STL-CFG-312 without the flag, main untouched"
ok '[ "$(smc t_0000b2a8 --owner-approved --i-have-read-the-boundary-changes)" = 0 ] && [ "$(head_of "$SR")" != "$h" ]' "r8 A: the same card merges with the flag"
git -C "$SR" rm -rq bin/roles; git -C "$SR" -c core.hooksPath=/dev/null commit -qm "the scratch stack takes the stand-in out again"   # the later rows import from this stack's bin
# r6 C4: what the nest costs. In the box of a stack card's merge test, code that makes its own user and mount namespace and then tries to unmount and to remount
# read-write every mount it can see still cannot write the read-only main checkout, see the hidden owner settings path or read a broker file. The probe is the
# card's own map tool (run in that box before the runner; behind the owner's flag); the owner settings path is only tested for existence, never read.
OSF4=/workspace/$(jq -r '.owner_settings[0]' "$RF"); mkdir -p "$T/hermes/broker"; printf 'C4-BROKER-CANARY-AAAAAAAAAAAAAAAA' >"$T/hermes/broker/qa-canary"; chmod 600 "$T/hermes/broker/qa-canary"
cat >"$T/c4-map.py" <<S
#!/usr/bin/env python3
import subprocess, sys
PROBE = r'''
echo "C4 in-ns uid=\$(id -u)"
tac /proc/self/mountinfo | cut -d" " -f5 | while read -r m; do umount "\$m" 2>/dev/null && echo "C4 unmounted \$m"; mount -o remount,rw,bind "\$m" 2>/dev/null && echo "C4 remounted \$m"; done
( : >"$SR/zz-c4-written" ) 2>/dev/null && echo "C4 BAD wrote the read-only main checkout" || echo "C4 ok read-only"
[ -e "$OSF4" ] && echo "C4 BAD the hidden owner settings path is visible" || echo "C4 ok hidden"
cat "$T/hermes/broker/qa-canary" 2>/dev/null | grep -q . && echo "C4 BAD the broker file is readable" || echo "C4 ok broker"
'''
if sys.argv[1:] == ["quick"]:
    print("zz-beta")
else:
    sys.stdin.read()
    subprocess.run(["unshare", "-Urm", "bash", "-c", PROBE], stdout=sys.stderr)
    print("zz-alpha")
S
scard t_0000b20a zz-c4.txt x; cp "$T/c4-map.py" "$SR/.worktrees/t_0000b20a/bin/test-map.py"; git -C "$SR/.worktrees/t_0000b20a" add -A; git -C "$SR/.worktrees/t_0000b20a" -c core.hooksPath=/dev/null commit -qm "a probing map tool"
ok '[ -e "$OSF4" ] && [ "$(smc t_0000b20a --owner-approved --i-have-read-the-boundary-changes)" = 0 ] && grep -q "^C4 in-ns uid=0" "$T/out" && grep -q "^C4 ok read-only" "$T/out" && grep -q "^C4 ok hidden" "$T/out" && grep -q "^C4 ok broker" "$T/out" && ! grep -q "C4 BAD\|C4-BROKER-CANARY" "$T/out" && [ ! -e "$SR/zz-c4-written" ]' "r6 C4: in the nested-namespace box of a stack card's merge test, code in its own user and mount namespace cannot write the read-only checkout, see the hidden owner settings path or read a broker file"; grep "^C4 " "$T/out" | sed 's/^/     info /' | head -12
card t_0000b209 b209.txt b209 'echo QA-NPM-RAN; unshare -Ur true 2>/dev/null && exit 1; exit 0'; h=$(head_of "$T/repo")
ok '[ "$(mc t_0000b209 --owner-approved)" = 0 ] && grep -q QA-NPM-RAN "$T/out" && ! grep -q "merge test:" "$T/out" && [ "$(head_of "$T/repo")" != "$h" ]' "B2: a project card is unchanged: its own test command runs, in a box that still forbids nested namespaces"
# r7 B3 (W4-CV4-08): a merge-check/<card> branch left by an interrupted merge does not block the next merge of that card
card t_0000f7b3 f7b3.txt f7b3 'exit 0'; g branch merge-check/t_0000f7b3 main; h=$(head_of "$T/repo")
ok '[ "$(mc t_0000f7b3 --owner-approved)" = 0 ] && [ "$(head_of "$T/repo")" != "$h" ] && ! g rev-parse -q --verify merge-check/t_0000f7b3 >/dev/null' "r7 B3: a leftover merge-check/<card> branch is reused, the card merges and the branch is gone after"
# r7 A5 (W4-VER4-02): with --push the card is merged locally before the merged main's tests run: a box or worktree fault there (STL-GRD-605) never says "nothing was merged"
card t_0000f7a5 f7a5.txt f7a5 'exit 0'; mkdir -p "$T/repo/.worktrees/merge-test-t_0000f7a5"; : >"$T/repo/.worktrees/merge-test-t_0000f7a5/leftover"; h=$(head_of "$T/repo"); r0=$(head_of "$T/remote.git" main); a0=$(nal)
ok '[ "$(mc t_0000f7a5 --owner-approved --push)" = 3 ] && grep -q "STL-GRD-605" "$T/out" && grep -q "Merged locally, NOT pushed" "$T/out" && ! grep -qi "nothing was merged" "$T/out" && [ "$(nal)" = $((a0+1)) ] && tail -n 1 "$T/sup/logs/alerts.log" | grep -q "^STL-GRD-605 " && ! tail -n 1 "$T/sup/logs/alerts.log" | grep -qi "nothing was merged" && [ "$(head_of "$T/repo")" != "$h" ] && [ "$(head_of "$T/remote.git" main)" = "$r0" ]' "r7 A5: --push, the throw-away worktree of the merged main cannot be made: STL-GRD-605 says merged locally, not pushed; neither the output nor the one alert line says 'nothing was merged'"
rm -rf "$T/repo/.worktrees/merge-test-t_0000f7a5"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
