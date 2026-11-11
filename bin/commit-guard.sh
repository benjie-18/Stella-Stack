#!/usr/bin/env bash
# pre-commit hook (D36, .pre-commit-config.yaml), run for every commit in this repo and its worktrees (they share
# .git/hooks):
#  - a Kanban worker commits only in its own card worktree, on its own card branch: never on main, never in /workspace.
#    A worker is proven from the board and the kernel (K1, bin/roles.py prove: an open run of a running card is bound to
#    an ancestor of this commit, however git was started: a Hermes terminal, OpenCode or claude -p); the card's recorded
#    workspace and branch must then be this commit's toplevel and branch. HERMES_KANBAN_WORKSPACE / _TASK / _BRANCH still
#    mark a worker too, and when set must match; so does HERMES_DELEGATED_CHILD_CONTEXT, which Hermes puts in every process
#    a worker spawns (agent/delegation_context.py scrub_kanban_env): a marked commit nothing proves is refused (the marker names are
#    roles.json worker_markers); a worker's commit never holds owner data (roles.json owner_data);
#  - no commit with an empty or test@test.com author email (t_a837104f: cfac3ff and 434c896 on STACK main).
set -uo pipefail
refuse() { echo "commit-guard: $1 (D36)" >&2; exit 1; }
email=$(git var GIT_AUTHOR_IDENT 2>/dev/null | sed -n 's/.*<\(.*\)>.*/\1/p')
[ -n "$email" ] || refuse "author email is empty"
[ "$email" != test@test.com ] || refuse "author email test@test.com refused"
# K6: the owner settings files (roles.json owner_settings) are never committed, by anyone (D39: they hold owner values)
owner=$(jq -r '.owner_settings[]?' "$(dirname "$(readlink -f "$0")")/../docs/hermes-local/roles.json" 2>/dev/null)
[ -n "$owner" ] || refuse "the owner settings list in roles.json cannot be read"
staged=$(git diff --cached --name-only) || refuse "cannot list the staged files"   # not piped: grep -q must not SIGPIPE git (RT7-05)
grep -qixF -f <(printf '%s\n' "$owner") <<<"$staged" && refuse "a staged file is an owner settings file; unstage it"   # -i: /workspace is case-insensitive (B2V-01)
# F1 W4: the worker markers and the owner data paths come from the same table; without either list no commit is allowed (fail closed)
tbl="$(dirname "$(readlink -f "$0")")/../docs/hermes-local/roles.json"
marks=$(jq -r '.worker_markers[]?' "$tbl" 2>/dev/null); odata=$(jq -r '.owner_data[]?' "$tbl" 2>/dev/null)
[ -n "$marks" ] && [ -n "$odata" ] || refuse "the worker marker or owner data list in roles.json cannot be read"
marked=
while IFS= read -r m; do
  [[ $m =~ ^[A-Z][A-Z0-9_]*$ ]] || refuse "a worker marker name in roles.json is not a variable name"   # ${!m} below must never see anything else
  [ -z "${!m:-}" ] || marked=1
done <<<"$marks"
# shortcut: this hook runs in the committing process's own environment, so it stops mistakes, not a determined worker
# (D40): a process re-parented out of the worker's tree (setsid) or a PATH that shadows python3/hermes is not caught.
proof=$(python3 -I "$(dirname "$(readlink -f "$0")")/roles.py" prove 2>/dev/null)
if [ -n "$proof" ] || [ -n "$marked" ]; then
  [ -n "$proof" ] || [ -n "${HERMES_KANBAN_WORKSPACE:-}" ] \
    || refuse "a kanban worker's commit, but its card cannot be proven (the board could not be read or no run is bound to this process)"
  # a worker never commits owner data (the owner and the build do); exact path or inside it, case-insensitive like the owner list above
  while IFS= read -r f; do
    while IFS= read -r p; do
      [[ ${f,,} == "${p,,}" || ${f,,} == "${p,,}/"* ]] && refuse "a staged file is owner data ($p); a worker never commits it, unstage it"
    done <<<"$odata"
  done <<<"$staged"
  top=$(git rev-parse --show-toplevel) && branch=$(git branch --show-current) || refuse "cannot read toplevel or branch"
  [ "$top" != /workspace ] || refuse "worker commit in /workspace refused: commit only in your card worktree"
  [ "$branch" != main ] || refuse "worker commit on main refused"
  if [ -n "$proof" ]; then
    ws=$(jq -r '.workspace // empty' <<<"$proof") cb=$(jq -r '.branch // empty' <<<"$proof") card=$(jq -r .card <<<"$proof")
    [ -n "$ws" ] && [ "$top" = "$(realpath -m -- "$ws")" ] || refuse "toplevel $top is not card $card's workspace ${ws:-(none recorded)}"
    [ -n "$cb" ] && [ "$branch" = "$cb" ] || refuse "branch $branch is not card $card's branch ${cb:-(none recorded)}"
  fi
  [ -z "${HERMES_KANBAN_WORKSPACE:-}" ] || [ "$top" = "$HERMES_KANBAN_WORKSPACE" ] \
    || refuse "toplevel $top is not the card workspace $HERMES_KANBAN_WORKSPACE"
  [ -z "${HERMES_KANBAN_BRANCH:-}" ] || [ "$branch" = "$HERMES_KANBAN_BRANCH" ] \
    || refuse "branch $branch is not the card branch $HERMES_KANBAN_BRANCH"
fi
exit 0
