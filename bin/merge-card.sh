#!/usr/bin/env bash
# Merge a reviewed card branch into main (F31, Stage 6 T7): the owner's step, never a worker's.
# usage: merge-card.sh <card-id> [--push] [--repo <dir>] [--owner-approved]
# Refuses (exit 3) unless: no worker environment (HERMES_KANBAN_TASK, HERMES_KANBAN_WORKSPACE, a delegated child, or a
# worker profile's HERMES_HOME); the repo's main checkout is clean and on main; exactly one card branch
# <project>/<id>-* exists and is ahead of main; the card's worktree is clean; the reviewer approved (its latest kanban run
# on the card is completed with metadata.review "approved", see docs/hermes-local/board.md) or --owner-approved is
# given; the card worktree's tests pass (npm test, package.json scripts.test).
# Then: git merge --no-ff into main; on any failure git merge --abort (main is left as it was, exit 1). Never forces,
# never rewrites history, never deletes the branch or the worktree. --push: npm test on the merged main first, then
# git push of main to its upstream, no force.
# Exit 0 merged (and pushed), 1 merge, test run or push failed, 2 usage, 3 refused.
set -uo pipefail
export LC_ALL=C.UTF-8
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
. "$(dirname "$(readlink -f "$0")")/kanban-board.sh"
usage() { echo "usage: merge-card.sh <card-id> [--push] [--repo <dir>] [--owner-approved]" >&2; exit 2; }
refuse() { echo "merge-card.sh: refused: $1" >&2; exit 3; }
card="${1:-}"; [[ "$card" =~ ^t_[0-9a-f]{8}$ ]] || usage; shift
push="" repo=. owner=""
while [ $# -gt 0 ]; do
  case "$1" in
    --push) push=1 ;;
    --owner-approved) owner=1 ;;
    --repo) [ -n "${2:-}" ] || usage; repo=$2; shift ;;
    *) usage ;;
  esac
  shift
done

[ -z "${HERMES_KANBAN_TASK:-}${HERMES_KANBAN_WORKSPACE:-}${HERMES_DELEGATED_CHILD_CONTEXT:-}" ] \
  || refuse "worker environment (a kanban worker or delegated child); merging is the owner's step"
[[ "${HERMES_HOME:-}" != */profiles/* && "${HOME:-}" != */.hermes/profiles/* ]] || refuse "worker profile environment (HERMES_HOME or HOME of a profile)"
# shortcut: like the commit guard, this runs in the caller's own environment: a re-parented process (setsid, a double
# fork) or a PATH that shadows python3/hermes escapes the worker proof, and --owner-approved is a flag any caller can pass
# (D40: mistakes, not a determined worker); builders' hooks also refuse any command naming this script (D51).
python3 -I "$(dirname "$(readlink -f "$0")")/roles.py" prove >/dev/null 2>&1; rc=$?   # 0 a worker, 3 board unreadable
[ "$rc" != 0 ] || refuse "this runs under a kanban worker's own run (K1: proven from the board and the process tree); merging is the owner's step"
[ "$rc" != 3 ] || refuse "the board cannot be read, so it is not known whether this runs under a kanban worker"
top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || refuse "$repo is not a git repository"
g() { git -C "$top" "$@"; }
[ "$(g rev-parse --git-dir)" = "$(g rev-parse --git-common-dir)" ] || refuse "$top is a worktree, not the main checkout"
[ "$(g symbolic-ref --short -q HEAD)" = main ] || refuse "the main checkout $top is not on main"
[ -z "$(g status --porcelain)" ] || refuse "the main checkout $top is not clean"
mapfile -t branches < <(g for-each-ref --format='%(refname:short)' "refs/heads/*/$card-*")   # K12: <project-slug>/<card>-<title>
[ "${#branches[@]}" = 1 ] || refuse "expected one branch <project>/$card-*, found ${#branches[@]}"
branch=${branches[0]}
[ "$(g rev-list --count "main..$branch")" -gt 0 ] || refuse "$branch is not ahead of main"
wt=$(g worktree list --porcelain | awk -v b="branch refs/heads/$branch" '/^worktree / { w = substr($0, 10) } $0 == b { print w }')
[ -n "$wt" ] || refuse "no worktree has $branch checked out"
# RT-A-02: a worker can rewrite $wt/.git and the commondir/gitdir files of its entry (case variants on the 9p mount), so git
# reads the worktree through the main checkout's own entry, with the common dir fixed, and runs no fsmonitor or hook command;
# a submodule's git dir sits in that same entry (its config is the worker's too), so status does not descend into it.
common=$(g rev-parse --absolute-git-dir); wtg=
for d in "$common"/worktrees/*/; do [ "$(cat "$d/gitdir" 2>/dev/null)" = "$wt/.git" ] && wtg=${d%/}; done
[ -n "$wtg" ] || refuse "no worktree entry of $top points at $wt"
st=$(GIT_COMMON_DIR=$common git --git-dir="$wtg" --work-tree="$wt" -c core.fsmonitor= -c core.hooksPath=/dev/null status --porcelain --ignore-submodules=dirty) \
  || refuse "cannot read the status of the card worktree $wt"
[ -z "$st" ] || refuse "the card worktree $wt is not clean"
tip=$(g rev-parse --verify "refs/heads/$branch^{commit}") || refuse "cannot read the tip of $branch"   # read first: the commit checked and tested below is the commit merged
# VH-02: a box writes the shared objects folder, so a commit can keep its id while its content changes; fsck compares every object with its id
g fsck --no-dangling --no-progress >/dev/null 2>&1 || refuse "git fsck reports a damaged or altered object in $top; nothing was merged"
if [ -z "$owner" ]; then
  read -r verdict started < <(kanban show "$card" --json 2>/dev/null \
    | jq -r --argjson r "$(python3 -I "$(dirname "$(readlink -f "$0")")/roles.py" reviewers 2>/dev/null || echo '[]')" \
      '[.runs[]? | select(.profile as $p | $r | index($p))] | last | if .outcome == "completed" then "\(.metadata.review // "none") \(.started_at // "none")" else "none none" end')   # K8/K12: the reviewing roles, from roles.json
  [ "${verdict:-none}" = approved ] || refuse "no reviewer approval on $card (the reviewer's last run must complete with metadata.review \"approved\"); after your own review, rerun with --owner-approved"
  # HH-05: the approval counts for the commit that was reviewed, so the branch must not have moved since the review run
  # started. Its reflog is written outside the box only (box.py), so a boxed builder cannot forge it.
  [[ "${started:-none}" =~ ^[0-9]+$ ]] || refuse "the review run on $card has no start time: its approval cannot be tied to a commit"
  moved=$(g reflog show --format=%gd --date=unix -1 "refs/heads/$branch" 2>/dev/null | sed -n 's/.*@{\([0-9]*\)}$/\1/p')
  [ -n "$moved" ] || refuse "$branch has no reflog: cannot tell whether it moved after the review"
  [ "$moved" -lt "$started" ] || refuse "$branch moved after the review started (branch ${moved}, review ${started}): the approval does not cover its tip; review it again"
fi
jq -e '.scripts.test' "$wt/package.json" >/dev/null 2>&1 || refuse "no test command in $wt/package.json (scripts.test)"
echo "merge-card.sh: running this branch's own test command in your shell; review the diff first" >&2
(cd "$wt" && timeout 1800 npm test) || refuse "tests failed in $wt (npm test)"
[ "$(g rev-parse --verify "refs/heads/$branch^{commit}")" = "$tip" ] || refuse "$branch moved while its tests ran; nothing was merged"
# N1: the tests ran for up to 30 minutes with the shared objects folder writable by a box; check the objects again before the merge
g fsck --no-dangling --no-progress >/dev/null 2>&1 || refuse "git fsck reports a damaged or altered object in $top after the tests; nothing was merged"

before=$(g rev-parse HEAD)
if ! g merge --no-ff --no-edit -m "Merge $branch (card $card)" "$tip"; then
  g rev-parse -q --verify MERGE_HEAD >/dev/null && g merge --abort
  [ "$(g rev-parse HEAD)" = "$before" ] || echo "merge-card.sh: main moved during a failed merge: check $top by hand" >&2
  echo "merge-card.sh: merge of $branch failed (conflict or hook); aborted, main left at ${before:0:12}" >&2
  exit 1
fi
echo "merged $branch into main: $(g rev-parse --short HEAD)"
[ -n "$push" ] || exit 0
# AGENTS.md: never push to main with a failing check, so the merged tree is tested again first (review H4). History is
# never rewritten here: on failure the merge stays local for the owner to inspect or undo.
(cd "$top" && timeout 1800 npm test) \
  || { echo "merge-card.sh: tests fail on the merged main: merged locally, NOT pushed (undo: git -C $top reset --hard $before)" >&2; exit 1; }
g rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || { echo "merge-card.sh: main has no upstream; merged, not pushed" >&2; exit 1; }
g push || { echo "merge-card.sh: push failed; merged locally, not pushed" >&2; exit 1; }
echo "pushed main to $(g rev-parse --abbrev-ref --symbolic-full-name '@{u}')"
