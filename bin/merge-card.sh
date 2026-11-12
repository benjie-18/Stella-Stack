#!/usr/bin/env bash
# Merge a reviewed card branch into main (F31, Stage 6 T7): the owner's step, never a worker's.
# usage: merge-card.sh <card-id> [--push] [--repo <dir>] [--owner-approved] [--i-have-read-the-boundary-changes]
# Refuses (exit 3) unless: no worker environment (a worker marker of the role table's worker_markers, or a worker profile's HERMES_HOME); the repo's main checkout is clean and on main; exactly one card branch
# <project>/<id>-* exists and is ahead of main; the card's worktree is clean; the reviewer approved (its latest kanban run
# on the card is completed with metadata.review "approved", see docs/hermes-local/board.md) or --owner-approved is
# given; the card worktree's tests pass (npm test, package.json scripts.test).
# F1 W4 (B3/K1, the merge is the single place every card change passes, however it was made: a Hermes terminal, plumbing, another agent
# CLI's git, a patch): git computes the tree the merge would produce (git merge-tree: every merge base, nothing written to the checkout), and the
# paths that tree changes in main (-z, no rename detection in the compare) must hold no path a role may not write: owner data, the owner
# settings files and the apply tool's state paths (bin/roles.py owner_paths, one list), compared by identity, not spelling (roles.py hits: a
# short 8.3 name or a case variant of a protected folder is that folder); nothing is merged and every offending path is listed. If the merged
# tree cannot be computed the merge is refused, never guessed. The merge is then made in the index (--no-commit) and its tree must equal the
# tree that was checked. A path that defines the boundary itself (roles.py boundary: the role table, the hooks, the guards, the box and every file
# they load, and a new module in bin/ named like a standard-library module) is listed, and refused unless --i-have-read-the-boundary-changes.
# K2: the card's test command is the card's code: it runs in the OS box (bin/box.py exec: the card worktree writable, the rest read-only, the
# owner settings files and state paths not mounted, the worker markers set); where the box cannot start the merge is refused (STL-CFG-312, coded),
# there is no unboxed run. The tests run in a throw-away worktree of the branch tip that this script makes (never the card's own worktree, whose
# .git file and git dir entry a worker can rewrite: the box refuses those, T6). What the box does not stop: the test code still decides its own
# exit code (the review reads the diff), and it can read
# whatever the box shows read-only. Every refusal here prints a catalog code with its plain message and writes one alert line.
# Then: git merge --no-ff into main; on any failure git merge --abort (main is left as it was, exit 1). Never forces,
# never rewrites history, never deletes the branch or the worktree. --push: npm test on the merged main first, then
# git push of main to its upstream, no force. --push: the merged main's tests run in the box too (a throw-away worktree).
# Exit 0 merged (and pushed), 1 merge, test run or push failed, 2 usage, 3 refused.
set -uo pipefail
export LC_ALL=C.UTF-8
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
. "$(dirname "$(readlink -f "$0")")/kanban-board.sh"
usage() { echo "usage: merge-card.sh <card-id> [--push] [--repo <dir>] [--owner-approved] [--i-have-read-the-boundary-changes]" >&2; exit 2; }
refuse() { echo "merge-card.sh: refused: $1" >&2; exit 3; }
card="${1:-}"; [[ "$card" =~ ^t_[0-9a-f]{8}$ ]] || usage; shift
push="" repo=. owner="" readb=""
while [ $# -gt 0 ]; do
  case "$1" in
    --push) push=1 ;;
    --owner-approved) owner=1 ;;
    --i-have-read-the-boundary-changes) readb=1 ;;
    --repo) [ -n "${2:-}" ] || usage; repo=$2; shift ;;
    *) usage ;;
  esac
  shift
done

here=$(dirname "$(readlink -f "$0")"); tbl=${ROLES_FILE:-$here/../docs/hermes-local/roles.json}
coded() {   # coded <code> <problem> <message>: the catalog code and plain message, one alert line, then the refusal; the problem is cleaned (it may hold worker text)
  local m; m=$(python3 -I "$here/roles.py" refusal "$1" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9_./ ,:~+=@()-' '?' | cut -c1-240)" 2>/dev/null)
  refuse "${m:-$1} $3"; }
marks=$(jq -r '.worker_markers[]?' "$tbl" 2>/dev/null); [ -n "$marks" ] || coded STL-CFG-303 "the worker marker list in the role table cannot be read" "so it is not known whether this is a worker's environment; nothing was merged"
while IFS= read -r m; do   # the marker names are the table's (worker_markers), never typed here; ${!m} must see nothing but a variable name
  [[ $m =~ ^[A-Z][A-Z0-9_]*$ ]] || refuse "the worker marker list in the role table holds a name that is not a variable name"
  [ -z "${!m:-}" ] || refuse "worker environment (a kanban worker or delegated child: $m is set); merging is the owner's step"
done <<<"$marks"
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
# K1 (F1 W4): the check judges what the merge will do. git computes the tree the merge would produce (merge-tree: every merge base, the
# merge's own rename handling, nothing written to the checkout), and the paths compared are the ones that tree changes in main (-z, no
# rename detection in the compare). After the merge below, its tree must be that tree. Names are compared with the lists by identity
# (roles.py hits), not by spelling: 8.3 short names and case variants of a protected folder are that folder.
before=$(g rev-parse --verify "HEAD^{commit}") || refuse "cannot read main"
zf=$(mktemp) || refuse "cannot list what $branch changes"; trap 'rm -f "$zf"' EXIT
mt=$(g merge-tree --write-tree --no-messages "$before" "$tip" 2>/dev/null); mrc=$?
mtree=
if [ "$mrc" = 0 ] && [[ "${mt%%$'\n'*}" =~ ^[0-9a-f]{40,64}$ ]]; then
  mtree=${mt%%$'\n'*}
  g diff-tree -r --name-only -z --no-renames "$before" "$mtree" >"$zf" || coded STL-CFG-303 "git cannot list what merging $branch changes" "so what $branch changes cannot be checked; nothing was merged"
elif [ "$mrc" != 1 ]; then   # 1 = a conflict: the merge below fails and is aborted, so there is nothing to judge
  coded STL-CFG-303 "git cannot compute the tree merging $branch would produce" "so what the merge changes cannot be checked; nothing was merged"
fi
if [ -n "$mtree" ]; then
  # B.3 point 17 (W4-VER3-01): git's merge overwrites an ignored file without a word. Every path the merged tree changes, and each folder above it, that
  # exists in the main checkout but is not tracked in main is refused before anything is written (ignored or not, any name)
  tz=$(mktemp) && g ls-tree -r -z --name-only "$before" >"$tz" || coded STL-CFG-303 "git cannot list what main tracks" "nothing was merged"
  over=$(python3 -I -c '
import os, sys
top, zf, tz = sys.argv[1:4]
tracked = {x for x in open(tz, "rb").read().decode("utf-8", "surrogateescape").split("\0") if x}
dirs = {os.path.dirname(x) for x in tracked}; dirs = {d for x in list(dirs) for d in [x] + [x.rsplit("/", i)[0] for i in range(1, x.count("/") + 1)]}
out = []
for n in (x for x in open(zf, "rb").read().decode("utf-8", "surrogateescape").split("\0") if x):
    parts = n.split("/")
    for i in range(1, len(parts) + 1):
        p = "/".join(parts[:i])
        if p not in tracked and p not in dirs and os.path.lexists(os.path.join(top, p)):
            out.append(p); break
print(", ".join(sorted(set(out)))[:240])' "$top" "$zf" "$tz") || coded STL-CFG-303 "the main checkout's untracked files cannot be compared with the merge" "nothing was merged"
  rm -f "$tz"
  [ -z "$over" ] || coded STL-CFG-312 "$branch would replace files of the main checkout that git does not track there: $over" "Those files (ignored local files, owner files) are never replaced by a merge; nothing was merged"
  hits=$(python3 -I "$here/roles.py" hits "$top" refused "$here/.." <"$zf" 2>/dev/null | tr '\0' '\n'; exit "${PIPESTATUS[0]}") \
    || coded STL-CFG-303 "the owner data list (role table or data index) cannot be read" "so what $branch changes cannot be checked; nothing was merged"
  bhits=$(python3 -I "$here/roles.py" hits "$top" boundary "$here/.." <"$zf" 2>/dev/null | tr '\0' '\n'; exit "${PIPESTATUS[0]}") \
    || coded STL-CFG-303 "the boundary path list cannot be read from the role table" "so what $branch changes cannot be checked; nothing was merged"
  hits=$(printf '%s' "$hits" | tr '\n' ',' | sed 's/,$//; s/,/, /g'); bhits=$(printf '%s' "$bhits" | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  if [ -n "$hits" ]; then
    coded STL-CFG-312 "$branch changes owner data, an owner settings file or an apply-tool state path" "Owner data changes only through the apply tool (bin/stella-apply.py), never through a card. $branch changes: $(printf '%s' "$hits" | tr -c '[:print:]' '?'); nothing was merged"
  fi
  if [ -n "$bhits" ] && [ -z "$readb" ]; then
    echo "merge-card.sh: $branch changes paths that define the boundary itself (the role table, hook files, guard scripts, the box): $(printf '%s' "$bhits" | tr -c '[:print:]' '?')" >&2
    coded STL-CFG-312 "$branch changes paths that define the boundary itself" "Read those changes, then rerun with --i-have-read-the-boundary-changes; nothing was merged"
  fi
  [ -z "$bhits" ] || echo "merge-card.sh: $branch changes paths that define the boundary itself: $(printf '%s' "$bhits" | tr -c '[:print:]' '?')" >&2
fi
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
g show "$tip:package.json" 2>/dev/null | jq -e '.scripts.test' >/dev/null 2>&1 || refuse "no test command in $branch:package.json (scripts.test)"
# K2: the card's test command is the card's code: it runs in the OS box (bin/box.py exec) with the plan a worker gets, never in this shell
intree() {   # intree <commit> <name>: npm test of <commit> in the box, in a throw-away worktree made here (owner-made git files; T6) and removed
  # after without running git in it; 125 the worktree cannot be made, 70 the box could not start (the box printed the coded line), else the tests' exit code (126 included)
  local pw="$top/.worktrees/$2-$card" pb="$2/$card" r
  rm -rf "$pw"; rm -f "$common/worktrees/$2-$card/locked"; g worktree prune; g branch -D "$pb" >/dev/null 2>&1   # W4-VAL3-01: a lock a previous test wrote into the entry would keep it; clear it so this merge of the same card is not refused uncoded
  g -c core.hooksPath=/dev/null -c core.fsmonitor= worktree add -q -b "$pb" "$pw" "$1" >/dev/null 2>&1 || return 125
  python3 -I "$here/box.py" exec "$top" "$pw" "$pb" "$card" 'timeout 1800 npm test' >&2; r=$?
  rm -rf "$pw"; rm -f "$common/worktrees/$2-$card/locked"; g worktree prune; g branch -D "$pb" >/dev/null 2>&1
  return "$r"; }
echo "merge-card.sh: running this branch's own test command in the OS box (the card worktree writable, the rest read-only); review the diff first" >&2
intree "$tip" merge-check; trc=$?
[ "$trc" != 125 ] || coded STL-CFG-312 "the throw-away worktree $top/.worktrees/merge-check-$card for the card's tests could not be made" "The tests never run outside the box; remove a leftover of an earlier run (git -C $top worktree remove $top/.worktrees/merge-check-$card), then merge again; nothing was merged"
[ "$trc" != 70 ] || refuse "the box for the tests could not start, and the tests never run outside it; nothing was merged"
[ "$trc" = 0 ] || refuse "tests failed on $branch (npm test, in the box); nothing was merged"
[ "$(g rev-parse --verify "refs/heads/$branch^{commit}")" = "$tip" ] || refuse "$branch moved while its tests ran; nothing was merged"
# N1: the tests ran for up to 30 minutes with the shared objects folder writable by a box; check the objects again before the merge
g fsck --no-dangling --no-progress >/dev/null 2>&1 || refuse "git fsck reports a damaged or altered object in $top after the tests; nothing was merged"

[ "$(g rev-parse HEAD)" = "$before" ] || refuse "main moved while the tests ran; nothing was merged"
# --no-commit: the merge is made in the index first and its tree compared with the tree that was checked (K1); only then committed
if ! g merge --no-ff --no-commit "$tip" >/dev/null; then
  g rev-parse -q --verify MERGE_HEAD >/dev/null && g merge --abort
  [ "$(g rev-parse HEAD)" = "$before" ] || echo "merge-card.sh: main moved during a failed merge: check $top by hand" >&2
  echo "merge-card.sh: merge of $branch failed (conflict or hook); aborted, main left at ${before:0:12}" >&2
  exit 1
fi
if [ -z "$mtree" ] || [ "$(g write-tree)" != "$mtree" ]; then
  g merge --abort; coded STL-CFG-312 "the merge of $branch did not produce the tree that was checked" "nothing was merged"
fi
if ! g commit --no-verify -q --no-edit -m "Merge $branch (card $card)"; then
  g merge --abort 2>/dev/null; echo "merge-card.sh: merge of $branch failed (commit); aborted, main left at ${before:0:12}" >&2; exit 1
fi
echo "merged $branch into main: $(g rev-parse --short HEAD)"
[ -n "$push" ] || exit 0
# AGENTS.md: never push to main with a failing check, so the merged tree is tested again first (review H4). History is
# never rewritten here: on failure the merge stays local for the owner to inspect or undo.
intree "$(g rev-parse HEAD)" merge-test; trc=$?   # K2: main's tests run in the box too, from a throw-away worktree of the merged commit
[ "$trc" != 125 ] || coded STL-CFG-312 "the throw-away worktree $top/.worktrees/merge-test-$card for the merged main's tests could not be made" "Merged locally, NOT pushed (undo: git -C $top reset --hard $before)"
[ "$trc" != 70 ] || refuse "the box for the tests of the merged main could not start; merged locally, NOT pushed (undo: git -C $top reset --hard $before)"
[ "$trc" = 0 ] \
  || { echo "merge-card.sh: tests fail on the merged main: merged locally, NOT pushed (undo: git -C $top reset --hard $before)" >&2; exit 1; }
g rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || { echo "merge-card.sh: main has no upstream; merged, not pushed" >&2; exit 1; }
g push || { echo "merge-card.sh: push failed; merged locally, not pushed" >&2; exit 1; }
echo "pushed main to $(g rev-parse --abbrev-ref --symbolic-full-name '@{u}')"
