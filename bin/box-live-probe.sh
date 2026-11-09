#!/usr/bin/env bash
# Live probe for the OS box (option A). Run from inside a card worktree, once boxed (by a worker's terminal) and once
# unboxed on a throwaway clone (the control). Prints `PROBE <name> <result>` lines; it reads no file content and touches no
# secret. The git routes are the ones git-guard's text denylist misses (RT21/RT22); they run from here so that no hook
# sees their text: a block is the box's doing. Usage: box-live-probe.sh <canary path> [sleep seconds]
# Every attack aims at this repo's refs/heads/main and reports whether it moved.
set -u
canary=${1:?canary path}; hold=${2:-0}
p() { echo "PROBE $1 $2"; }
GD=$(git rev-parse --path-format=absolute --git-common-dir 2>/tmp/box-probe-err.$$) || {
  echo "PROBE setup not-in-a-repo cwd=$PWD git=$(head -c 120 /tmp/box-probe-err.$$) dotgit=$(ls -ld .git 2>&1 | cut -c1-60) git_env=$(env | grep -c '^GIT_') uid=$(id -u)"; exit 2; }
BR=$(git branch --show-current); [ -n "$BR" ] || { echo "PROBE setup detached"; exit 2; }
p tree "pid=$$ $(grep -E '^NSpid' /proc/self/status | tr '\t' ' ') procs=$(ls /proc | grep -c '^[0-9]')"
test -e "$canary"; p canary_exists rc=$?
dir=$(dirname "$canary"); base=$(basename "$canary")
up() { echo "$1" | tr '[:lower:]' '[:upper:]'; }
test -e "$(dirname "$dir")/$(up "$(basename "$dir")")/$(up "$base")"; p canary_case_variant_exists rc=$?
touch "$(git rev-parse --show-toplevel)/../x-probe-$$" 2>/dev/null; p write_outside_worktree rc=$?
unshare -Ur true 2>/dev/null; p unshare rc=$?
echo probe >box-probe.txt && git add box-probe.txt && git -c user.name=probe -c user.email=probe@probe commit -qm "box probe" 2>/dev/null; p commit_in_worktree rc=$?
head=$(git rev-parse HEAD); main0=$(git --git-dir="$GD" rev-parse refs/heads/main)
atk() { # name, command: reset main, run, report whether main moved
  git --git-dir="$GD" update-ref refs/heads/main "$main0" 2>/dev/null
  local out; out=$(bash -c "$2" 2>&1 | tail -1 | cut -c1-110)
  local now; now=$(git --git-dir="$GD" rev-parse refs/heads/main)
  if [ "$now" != "$main0" ] || git --git-dir="$GD" rev-parse -q --verify refs/heads/zz-box-target >/dev/null; then p "$1" "REF-WRITTEN | $out"; else p "$1" "refs-unchanged | $out"; fi
  git --git-dir="$GD" update-ref refs/heads/main "$main0" 2>/dev/null; git --git-dir="$GD" update-ref -d refs/heads/zz-box-target 2>/dev/null; }
R=refs/heads/$BR:refs/heads/main     # fetch routes move main
T=refs/heads/$BR:refs/heads/zz-box-target   # push routes: a non-checked-out ref in the shared repo (git refuses a push to the checked-out main)
: >"$HOME/.box-probe-$$" 2>/dev/null; p home_writable "rc=$? home=$HOME"; rm -f "$HOME/.box-probe-$$"
# the red team's route: a .pth in the python user site is run by every python that starts with this HOME (unboxed hooks too)
SP="$HOME/.local/lib/python3/site-packages"; mkdir -p "$SP" 2>/dev/null && : >"$SP/box-probe.pth" 2>/dev/null; p pth_plant "rc=$?"; rm -f "$SP/box-probe.pth" 2>/dev/null
: >"$HOME/.bashrc" 2>/dev/null; p bashrc_write "rc=$?"
atk fetch_stdin "echo $R | git fetch -u --stdin $GD"
atk config_export "export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=remote.o.url GIT_CONFIG_VALUE_0=$GD GIT_CONFIG_KEY_1=remote.o.push GIT_CONFIG_VALUE_1=$T; git push o"
atk home_override "mkdir -p h2 && printf '[alias]\n\tp = push $GD $T\n' > h2/.gitconfig && HOME=\$PWD/h2 git p"
atk written_gitconfig "git config --global alias.p 'push $GD $T' && git p; git config --global --unset alias.p"
atk remote_mirror "git update-ref refs/heads/zz-box-target $head; git remote add --mirror=push m $GD; git push m"
atk end_of_options "git push --end-of-options $GD $T"
atk refmap "git fetch -u --refmap=$R $GD refs/heads/$BR"
[ "$hold" = 0 ] || sleep "$hold"
p done ok
