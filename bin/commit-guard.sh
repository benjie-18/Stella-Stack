#!/usr/bin/env bash
# pre-commit hook (D36, .pre-commit-config.yaml), run for every commit in this repo and its worktrees (they share
# .git/hooks):
#  - a Kanban worker commits only in its own card worktree, on its own card branch: never on main, never in /workspace.
#    A worker is proven from the board and the kernel (K1, bin/roles.py prove: an open run of a running card is bound to
#    an ancestor of this commit, however git was started: a Hermes terminal, OpenCode or claude -p); the card's recorded
#    workspace and branch must then be this commit's toplevel and branch. HERMES_KANBAN_WORKSPACE / _TASK / _BRANCH still
#    mark a worker too, and when set must match; so does HERMES_DELEGATED_CHILD_CONTEXT, which Hermes puts in every process
#    a worker spawns (agent/delegation_context.py scrub_kanban_env): a marked commit nothing proves is refused (the marker names are
#    roles.json worker_markers); a worker's commit never holds owner data (bin/roles.py owner_paths: the index, its owner_only rows and the table's owner_data list; a deletion and a rename out of it count);
#  - no commit with an empty or test@test.com author email (t_a837104f: cfac3ff and 434c896 on STACK main).
set -uo pipefail
refuse() { echo "commit-guard: $1 (D36)" >&2; exit 1; }
email=$(git var GIT_AUTHOR_IDENT 2>/dev/null | sed -n 's/.*<\(.*\)>.*/\1/p')
[ -n "$email" ] || refuse "author email is empty"
[ "$email" != test@test.com ] || refuse "author email test@test.com refused"
# K6: the owner settings files (roles.json owner_settings) are never committed, by anyone (D39: they hold values). G3 (F1 W4): the staged
# names are read whole (-z, no rename detection): a name with a non-ASCII or special character, a rename out of an owner folder (old and
# new path both listed) and a deletion are all seen.
here=$(dirname "$(readlink -f "$0")"); tbl="$here/../docs/hermes-local/roles.json"
owner=$(jq -r '.owner_settings[]?' "$tbl" 2>/dev/null)
[ -n "$owner" ] || refuse "the owner settings list in roles.json cannot be read"
zf=$(mktemp) || refuse "cannot list the staged files"; trap 'rm -f "$zf"' EXIT
git diff --cached --name-only -z --no-renames >"$zf" || refuse "cannot list the staged files"   # not piped: a reader that stops early must not SIGPIPE git (RT7-05)
mapfile -d '' -t staged <"$zf"
while IFS= read -r o; do
  for f in "${staged[@]}"; do [[ ${f,,} == "${o,,}" ]] && refuse "a staged file is an owner settings file; unstage it"; done   # lower-cased: /workspace is case-insensitive (B2V-01)
done <<<"$owner"
# F1 W4: the worker markers come from the table's list only; owner data is one definition in bin/roles.py (G1: the index, its owner_only
# rows, the table's own list), read for this tree. Without either list no commit is allowed (fail closed).
marks=$(jq -r '.worker_markers[]?' "$tbl" 2>/dev/null)
odata=$(ROLES_FILE=$tbl python3 -I "$here/roles.py" owner-data "$here/.." 2>/dev/null | jq -r '.[]?' 2>/dev/null)
[ -n "$marks" ] && [ -n "$odata" ] || refuse "the worker marker or owner data list in roles.json (or the data index it needs) cannot be read"
wsv=$(jq -r '.worker_pins.workspace // empty' "$tbl" 2>/dev/null); brv=$(jq -r '.worker_pins.branch // empty' "$tbl" 2>/dev/null)   # the box's workspace and branch pins: names from the table too
[[ $wsv =~ ^[A-Z][A-Z0-9_]*$ && $brv =~ ^[A-Z][A-Z0-9_]*$ ]] || refuse "the worker pin names in roles.json cannot be read"
marked=
while IFS= read -r m; do
  [[ $m =~ ^[A-Z][A-Z0-9_]*$ ]] || refuse "the worker marker list in roles.json cannot be read: a name in it is not a variable name"   # ${!m} below must never see anything else
  [ -z "${!m:-}" ] || marked=1
done <<<"$marks"
# shortcut: this hook runs in the committing process's own environment, so it stops mistakes, not a determined worker
# (D40): a process re-parented out of the worker's tree (setsid) or a PATH that shadows python3/hermes is not caught.
proof=$(python3 -I "$here/roles.py" prove 2>/dev/null)
if [ -n "$proof" ] || [ -n "$marked" ]; then
  [ -n "$proof" ] || [ -n "${!wsv:-}" ] \
    || refuse "a kanban worker's commit, but its card cannot be proven (the board could not be read or no run is bound to this process)"
  # a worker never commits owner data (the owner and the build do); exact path or inside it, case-insensitive like the owner list above
  for f in "${staged[@]}"; do
    while IFS= read -r p; do
      [[ ${f,,} == "${p,,}" || ${f,,} == "${p,,}/"* ]] && refuse "a staged file is owner data ($p); a worker never commits it (a deletion or a rename out of it counts), unstage it"
    done <<<"$odata"
  done
  top=$(git rev-parse --show-toplevel) && branch=$(git branch --show-current) || refuse "cannot read toplevel or branch"
  [ "$top" != /workspace ] || refuse "worker commit in /workspace refused: commit only in your card worktree"
  [ "$branch" != main ] || refuse "worker commit on main refused"
  if [ -n "$proof" ]; then
    ws=$(jq -r '.workspace // empty' <<<"$proof") cb=$(jq -r '.branch // empty' <<<"$proof") card=$(jq -r .card <<<"$proof")
    [ -n "$ws" ] && [ "$top" = "$(realpath -m -- "$ws")" ] || refuse "toplevel $top is not card $card's workspace ${ws:-(none recorded)}"
    [ -n "$cb" ] && [ "$branch" = "$cb" ] || refuse "branch $branch is not card $card's branch ${cb:-(none recorded)}"
  fi
  [ -z "${!wsv:-}" ] || [ "$top" = "${!wsv}" ] \
    || refuse "toplevel $top is not the card workspace ${!wsv}"
  [ -z "${!brv:-}" ] || [ "$branch" = "${!brv}" ] \
    || refuse "branch $branch is not the card branch ${!brv}"
fi
exit 0
