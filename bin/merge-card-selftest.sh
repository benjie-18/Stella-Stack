#!/usr/bin/env bash
# Hermetic self-test for bin/merge-card.sh (F31): a scratch repo with a scratch bare remote, card branches in
# worktrees, a stub hermes for the reviewer verdict. Nothing outside the scratch dir is touched; no network.
# K8 (the approval is read from the table's reviewing profiles): MC=<merge-card.sh> and ROLES_FILE=<table> point the run at a staged copy
# (its roles.py must sit next to it); FAKE_REVIEWER names the profile of the stub's reviewer run.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
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
export PATH="$T/bin:$PATH"
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
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
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
ok '[ "$(grep -c "merge-card.sh: running this branch'"'"'s own test command in your shell; review the diff first" "$T/out")" = 1 ] && [ "$(grep -n "running this branch" "$T/out" | cut -d: -f1)" -lt "$(grep -n "tests failed" "$T/out" | cut -d: -f1)" ]' "D42: one warning line, printed before the branch's tests run"
ok '[ "$(FAKE_APPROVED=t_00000001 mc t_00000001)" = 0 ] && [ "$(g rev-list --parents -n1 HEAD | wc -w)" = 3 ] && [ "$(head_of "$T/remote.git" main)" = "$h0" ]' "clean merge: --no-ff merge commit on main; without --push the remote is untouched"
ok '[ "$(grep -c "running this branch" "$T/out")" = 1 ] && [ "$(grep -n "running this branch" "$T/out" | cut -d: -f1)" -lt "$(grep -n "^merged " "$T/out" | cut -d: -f1)" ]' "D42: a clean merge prints the warning once, before the merge"
ok 'g rev-parse -q --verify stella/t_00000001-x >/dev/null && [ -d "$T/repo/.worktrees/t_00000001" ]' "the card branch and worktree are kept"
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
mkdir -p "$T/repo/.stella/extensions" "$T/repo/.stella/schemas"; printf '{}\n' >"$T/repo/.stella/extensions/zz-own.json"; printf '{}\n' >"$T/repo/.stella/schemas/zz.schema.json"
g add -f .stella; g -c core.hooksPath=/dev/null commit -qm "owner data, as the owner committed it"
wcard() {  # wcard <id>: a worktree on a new branch off main; the commands that change it follow
  g worktree add -q -b "stella/$1-x" "$T/repo/.worktrees/$1" main; }
wcommit() {  # wcommit <id>: commit everything staged in the worktree, no hook
  git -C "$T/repo/.worktrees/$1" -c core.hooksPath=/dev/null commit -qm "card $1"; }
wcard t_0000c001   # plumbing only: hash-object, update-index --cacheinfo, write-tree, commit-tree, update-ref (no commit hook ever runs)
W1=$T/repo/.worktrees/t_0000c001
sha=$(printf '{"x": 1}\n' | git -C "$W1" hash-object -w --stdin)
git -C "$W1" update-index --add --cacheinfo 100644,$sha,.stella/settings.json
tr1=$(git -C "$W1" write-tree); c1=$(git -C "$W1" commit-tree "$tr1" -p HEAD -m plumbing); git -C "$W1" update-ref refs/heads/stella/t_0000c001-x "$c1"; git -C "$W1" reset -q --hard
h=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_0000c001 mc t_0000c001)" = 3 ] && grep -q "STL-CFG-312" "$T/out" && grep -q ".stella/settings.json" "$T/out" && grep -q "nothing was merged" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ] && [ "$(grep -c "^STL-CFG-312 " "$T/sup/logs/alerts.log")" = 1 ]' "B3: an owner-data file added by plumbing (hash-object, update-index, commit-tree, update-ref): refused with the code, one alert line, main untouched"
ok '[ "$(mc t_0000c001 --owner-approved)" = 3 ] && grep -q "owner data" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "B3: --owner-approved does not lift it (owner data changes only through the apply tool)"
wcard t_0000c002; git -C "$T/repo/.worktrees/t_0000c002" mv .stella/extensions/zz-own.json moved-out.json; wcommit t_0000c002
ok '[ "$(FAKE_APPROVED=t_0000c002 mc t_0000c002)" = 3 ] && grep -q ".stella/extensions/zz-own.json" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "B3: a rename out of an owner folder is refused (both sides of a rename count)"
wcard t_0000c003; mkdir -p "$T/repo/.worktrees/t_0000c003/.stella/extensions"; echo x >"$T/repo/.worktrees/t_0000c003/.stella/extensions/é.json"; git -C "$T/repo/.worktrees/t_0000c003" add -f -A; wcommit t_0000c003
ok '[ "$(FAKE_APPROVED=t_0000c003 mc t_0000c003)" = 3 ] && grep -q "owner data" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "B3: a non-ASCII name under owner data is refused"
wcard t_0000c004; git -C "$T/repo/.worktrees/t_0000c004" rm -q .stella/schemas/zz.schema.json; wcommit t_0000c004
ok '[ "$(FAKE_APPROVED=t_0000c004 mc t_0000c004)" = 3 ] && grep -q "owner data" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "B3: a deletion of owner data is refused"
wcard t_0000c005; mkdir -p "$T/repo/.worktrees/t_0000c005/config"; echo x >"$T/repo/.worktrees/t_0000c005/config/owner.env"; git -C "$T/repo/.worktrees/t_0000c005" add -f -A; wcommit t_0000c005
ok '[ "$(FAKE_APPROVED=t_0000c005 mc t_0000c005)" = 3 ] && grep -q "owner" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "B3: an owner settings file is refused too"
wcard t_0000c006; mkdir -p "$T/repo/.worktrees/t_0000c006/docs/hermes-local/hooks/builder"; echo '#!/bin/sh' >"$T/repo/.worktrees/t_0000c006/docs/hermes-local/hooks/builder/zz-guard.sh"; git -C "$T/repo/.worktrees/t_0000c006" add -A; wcommit t_0000c006
ok '[ "$(FAKE_APPROVED=t_0000c006 mc t_0000c006)" = 3 ] && grep -q "define the boundary" "$T/out" && grep -q "docs/hermes-local/hooks/builder/zz-guard.sh" "$T/out" && grep -q "i-have-read-the-boundary-changes" "$T/out" && [ "$(head_of "$T/repo")" = "$h" ]' "B3: a branch that edits a hook is refused without the flag, the paths listed"
ok '[ "$(FAKE_APPROVED=t_0000c006 mc t_0000c006 --i-have-read-the-boundary-changes)" = 0 ] && [ "$(head_of "$T/repo")" != "$h" ]' "B3: the same branch merges with the flag"
h=$(head_of "$T/repo")
wcard t_0000c007; mkdir -p "$T/repo/.worktrees/t_0000c007/.stella"; echo '{"x": 2}' >"$T/repo/.worktrees/t_0000c007/.stella/capabilities.json"; echo '{}' >"$T/repo/.worktrees/t_0000c007/.stella/test-map.json"; git -C "$T/repo/.worktrees/t_0000c007" add -f -A; wcommit t_0000c007
ok '[ "$(FAKE_APPROVED=t_0000c007 mc t_0000c007)" = 0 ] && [ "$(head_of "$T/repo")" != "$h" ]' "B3/G1: the capability registry and the test map (not owner-only rows) merge as before (product rules 4 and 8)"
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
ok '[ "$(FAKE_APPROVED=t_0000a005 mc t_0000a005)" = 0 ] && [ ! -e "$T/fsm" ] && [ "$(head_of "$T/repo")" != "$h" ]' "RT-A-02: a worktree config.worktree with core.fsmonitor: not run (-c core.fsmonitor=)"
mkdir -p "$T/evilhooks"; printf '#!/bin/sh\ntouch %s\n' "$T/fsm" > "$T/evilhooks/post-index-change"; chmod +x "$T/evilhooks/post-index-change"
printf '[core]\n\thooksPath = %s\n' "$T/evilhooks" > "$T/repo/.git/worktrees/t_0000a006/config.worktree"; touch "$T/repo/.worktrees/t_0000a006/g6.txt"
git -C "$T/repo/.worktrees/t_0000a006" status --porcelain >/dev/null 2>&1; ok '[ -e "$T/fsm" ]' "RT-A-02 premise: a plain status that refreshes the index runs the post-index-change hook of a worktree config.worktree"
rm -f "$T/fsm"; touch "$T/repo/.worktrees/t_0000a006/g6.txt"; h=$(head_of "$T/repo")
ok '[ "$(FAKE_APPROVED=t_0000a006 mc t_0000a006)" = 0 ] && [ ! -e "$T/fsm" ] && [ "$(head_of "$T/repo")" != "$h" ]' "RT-A-02: a worktree config.worktree with core.hooksPath: its index hook is not run (-c core.hooksPath=/dev/null)"
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
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
