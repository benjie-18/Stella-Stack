#!/usr/bin/env bash
# Run every hermetic self-test (stubs, scratch state, no network, no secrets). Part of `npm test`, so the 15-minute
# watchdog (bin/watchdog.sh) also catches escalation-script regressions and alerts #alerts (D31).
# usage: selftests.sh [name...|--quick]   no name = the whole list below (merge, final hash); --quick = the quick tier the
# watchdog runs (decided by the owner 2026-11-12; list: "quick" in .stella/test-map.json); a name without a selftest file is FAIL.
# Each selftest runs ISOLATED: the tree this script lies in is copied as it is on disk (tracked files plus untracked files
# git does not ignore; a tracked file deleted on disk is in neither the copy nor its commit) into a one-commit repository, and the selftest runs in a bubblewrap mount namespace with that copy
# bound at the stack's path and a private folder bound over the system temp folder. So it has its own tree, alert log and
# temp names; the source tree, the live alert log and the shared temp folder get nothing. Fail closed: a selftest is only
# ever started inside the namespace; if the copy or the namespace cannot be made, every selftest is FAIL with one plain line
# (inside a box that forbids nested namespaces the suite therefore fails: an open owner decision, not designed around).
# Cost on this mount (v9fs, measured): the base copy about 10 s once, then about 5 s per selftest for its copy; that is the price of
# testing on the filesystem the stack lives on (the same copy on /tmp took about 0.13 s per selftest).
# The owner settings files the copy's role table lists and node_modules are bound read-only from the source tree.
set -u
unset STELLA_ROOT   # an inherited scratch root must not re-target the data tools and the gates that run them
unset HARDCODE_ALLOW HARDCODE_HOME   # likewise the hard-code lint's own switches (another list or home would turn its gate green)
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
STACK=/workspace   # shortcut: the path the stack's scripts name literally; upgrade when they take their root from their own location
TD=${TMPDIR:-/tmp}
suite=()
for t in alert alert-page delegation escalate escalation-thread escalation-reply-poll escalation-reply-hook escalation-complete kanban-guard false-close-guard check-guard complete-gate roles-complete profile-hooks commit-guard owner-config owner-leak write-guard roles role-guard secret-read matcher-audit kanban-board merge-card owner-settings watchdog model-watch hardcode-lint init-firewall firewall-probe container-start post-edit-check box bench approval-sim omniroute-run reviewer-claude approval-evidence routing broker-put test-map stella-data event-log stella-apply settings selftests; do
  suite+=("$t")
done
if [ "${1:-}" = --quick ]; then   # the quick tier (the "quick" list of the test map): the watchdog's; no argument stays the full suite
  # outside the namespace: no bytecode written into the tree (-B) and none read from it (the cache prefix is no folder at all)
  q=$(python3 -I -B -X pycache_prefix=/dev/null "$ROOT/bin/test-map.py" quick 2>&1) && [ -n "$q" ] || { printf 'FAIL quick-tier\n     FAIL the quick list cannot be read: %s\nselftests FAIL (1)\n' "${q:-empty answer}"; exit 1; }
  mapfile -t q <<<"$q"; set -- "${q[@]}"
fi
[ $# = 0 ] && set -- "${suite[@]}"
set -- "${@%-selftest}"   # the watchdog reruns a failed check by the name it printed (<name>-selftest)
mapfile -t u < <(printf '%s\n' "$@" | awk '!seen[$0]++'); set -- "${u[@]}"   # a name given twice runs once (first-seen order): job folders are per name
# The tree copies lie on the tree's own filesystem (a selftest that checks the filesystem the stack lives on must see it), in the
# tree's ignored .scratch (a real folder of the tree, never a link); the selftests' temp folders lie in a twin of the run folder,
# same name, in the caller's temp folder (fast), whose .alive names the run folder. Each runner holds a lock on its run folder's
# .alive (a KILLed runner's children keep it while they run); the next run sweeps run folders whose lock is free, and their twins.
# The gate (a lock on .scratch itself) makes make-and-lock one step.
# Twin rule: whoever can write <tree>/.scratch can only plant names; a twin goes only if its .alive names this tree's dead run
# folder, so the worst is a name clash (a FAIL of somebody's run), never a pass, never a removal outside the two places.
times=${SELFTESTS_TIMES:-}; unset SELFTESTS_TIMES   # the caller's times file is the runner's; a started selftest (a nested runner) never sees it
# setup_fail <reason> <name>...: the same output form as a failed prep(), so the watchdog's parser names the checks
setup_fail() { local n; for n in "${@:2}"; do printf 'FAIL %s-selftest\n     FAIL %s\n' "$n" "$1"; done; echo "selftests FAIL ($(($# - 1)))"; exit 1; }
R= Q=
# unlock <folder>...: make the folders removable; modes of FOLDERS only (rm needs no write bit on a file; a hard link stays as it is)
unlock() { [ $# = 0 ] || find "$@" -type d ! -perm -u=rwx -exec chmod u+rwx {} \; 2>/dev/null; }
trap 'unlock ${R:+"$R"} ${Q:+"$Q"}; rm -rf ${R:+"$R"} ${Q:+"$Q"}' EXIT
[ ! -L "$ROOT/.scratch" ] || setup_fail "$ROOT/.scratch is a symbolic link, not a folder of the tree: nothing started" "$@"
{ mkdir -p "$ROOT/.scratch" && exec 8<"$ROOT/.scratch" && flock 8; } 2>/dev/null || setup_fail "cannot make or lock $ROOT/.scratch: nothing started" "$@"
for d in "$ROOT"/.scratch/selftests.*/; do
  d=${d%/}; [ ! -L "$d" ] && { [ ! -f "$d/.alive" ] || flock -n "$d/.alive" true; } || continue
  q=$TD/${d##*/}   # a twin's .alive is read only as a plain file, at most 4096 bytes (a FIFO would block under the gate); an empty twin (KILL before its .alive) goes with rmdir
  if [ -d "$q" ] && [ ! -L "$q" ]; then
    if [ -f "$q/.alive" ] && [ ! -L "$q/.alive" ] && [ "$(head -c 4096 "$q/.alive" 2>/dev/null)" = "$d" ]; then unlock "$q"; rm -rf "$q"; else rmdir "$q" 2>/dev/null; fi
  fi
  unlock "$d"; rm -rf "$d"
done
{ R=$(mktemp -d "$ROOT/.scratch/selftests.XXXXXX") && exec 9>"$R/.alive" && flock -n 9 && mkdir "$TD/${R##*/}" && Q=$TD/${R##*/} && echo "$R" >"$Q/.alive"; } 2>/dev/null ||
  setup_fail "cannot make a run folder in $ROOT/.scratch and its twin in $TD: nothing started" "$@"
exec 8<&-
set -m   # each job is its own process group: a TERM to the runner stops what it started, then the EXIT trap removes the folders
trap 'trap "" TERM INT HUP; for j in $(jobs -p); do kill -TERM -- "-$j" 2>/dev/null; done; wait; echo "selftests FAIL (stopped by a signal)"; exit 143' TERM INT HUP

# The copy is made once; a job duplicates it. Sets binds (the read-only mounts); returns 1 with the reason on stdout.
prep() {
  command -v bwrap >/dev/null || { echo "bwrap (bubblewrap) is not installed"; return 1; }
  ( set -o pipefail
    git -C "$ROOT" ls-files -z --deleted -- . ':!.scratch' | sort -z >"$R/gone" &&   # tracked, deleted on disk: in neither list
    git -C "$ROOT" ls-files -z --cached --others --exclude-standard -- . ':!.scratch' | sort -z | comm -z -23 - "$R/gone" | sed -z 's|^|./|' >"$R/files" &&   # names, never options
    git -C "$ROOT" ls-files -z --cached -- . ':!.scratch' | sort -z | comm -z -23 - "$R/gone" >"$R/tracked" &&   # the copy's one commit holds exactly these
    mkdir "$R/base" && tar -c -C "$ROOT" --null -T "$R/files" -f - | tar -x -C "$R/base" -f - &&
    git -C "$R/base" init -q -b qa && { [ ! -s "$R/tracked" ] || GIT_LITERAL_PATHSPECS=1 git -C "$R/base" add --pathspec-from-file="$R/tracked" --pathspec-file-nul; } &&
    git -C "$R/base" -c user.name=selftests -c user.email=selftests@scratch.invalid -c commit.gpgsign=false commit -q --allow-empty --no-verify -m "scratch copy" &&
    git -C "$R/base" repack -adq   # one pack instead of a loose object per file: a job copy (cp -a) has fewer files to copy
  ) 2>&1 || { echo "cannot copy $ROOT"; return 1; }
  binds=(); local f
  while IFS= read -r f; do
    if [ -e "$ROOT/$f" ]; then mkdir -p "$R/base/$(dirname "$f")"; [ -e "$R/base/$f" ] || : >"$R/base/$f"; binds+=(--ro-bind "$ROOT/$f" "$STACK/$f"); fi
  done < <(jq -r '.owner_settings[]?' "$ROOT/docs/hermes-local/roles.json" 2>/dev/null)
  if [ -d "$ROOT/node_modules" ]; then mkdir -p "$R/base/node_modules"; binds+=(--ro-bind "$ROOT/node_modules" "$STACK/node_modules"); fi
  bwrap --dev-bind / / --bind "$R/base" "$STACK" "${binds[@]}" -- true 2>&1 || { echo "bwrap cannot make the namespace"; return 1; }
}
bad=""; prep >"$R/why" 2>&1 || bad=$(head -c 300 "$R/why" | head -3 | tr '\n' ' ')
real_hermes=$(command -v hermes || echo /bin/false)

# key <name>: sets k, the name's result-file key: a valid name itself; any other name an escaped form starting with %, which no valid name can take
key() { if [[ $1 =~ ^[A-Za-z0-9._-]+$ ]]; then k=$1; else k=${1//%/%25}; k=%${k//\//%2F}; fi; }
# run_one <name>: writes $R/res-<key> (the result lines), rc-<key> (0 pass or skip, 1 FAIL), ms-<key> (milliseconds)
run_one() {
  local t=$1 out s=${EPOCHREALTIME//[.,]/} k; key "$t"; local p=$R/job-$k q=$Q/job-$k
  if [[ ! $t =~ ^[A-Za-z0-9._-]+$ || ! -f $ROOT/bin/$t-selftest.sh ]]; then out="no such selftest: bin/$t-selftest.sh"
  elif [ -n "$bad" ]; then out="cannot make the private copy or the mount namespace ($bad)"
  elif ! mkdir -p "$q/.bin" "$p" || ! cp -a "$R/base" "$p/tree"; then out="cannot make the private copy or the mount namespace (cp failed)"
  else
    # K11: no selftest posts to Discord. A `hermes` first on PATH refuses any call with a `send` argument (also after -p <profile>)
    # and passes every other call to the real one; a selftest's own stub, put before it, still wins. It lives in the private temp
    # folder, which the selftest sees as $TD. shortcut: the real binary called by its path is not refused (no stack script does
    # that); upgrade: bind a refusing stub over the real path.
    printf '#!/usr/bin/env bash\nfor a; do [ "$a" != send ] || { echo "selftests: hermes send refused in a selftest" >&2; exit 1; }; done\nexec %q "$@"\n' "$real_hermes" >"$q/.bin/hermes"
    chmod +x "$q/.bin/hermes"
    # the temp folder is bound last: the other sources may lie under it
    out=$(nice bwrap --die-with-parent --dev-bind / / --bind "$p/tree" "$STACK" "${binds[@]}" --bind "$q" "$TD" --chdir "$STACK" \
      --setenv PATH "$TD/.bin:$PATH" -- "$STACK/bin/$t-selftest.sh" </dev/null 2>&1 | grep -v setlocale)
    rm -rf "$p" "$q"
    if printf '%s\n' "$out" | tail -1 | grep -q "selftest PASS"; then echo "ok   $t-selftest" >"$R/res-$k"; echo 0 >"$R/rc-$k"
    elif printf '%s\n' "$out" | tail -1 | grep -q "selftest SKIP"; then echo "skip $t-selftest: $(printf '%s\n' "$out" | grep -m1 '^SKIP' | cut -c6-)" >"$R/res-$k"; echo 0 >"$R/rc-$k"
    else { echo "FAIL $t-selftest"; printf '%s\n' "$out" | grep -E "^FAIL" | sed 's/^/     /'; } >"$R/res-$k"; echo 1 >"$R/rc-$k"
    fi
    echo $(( (${EPOCHREALTIME//[.,]/} - s) / 1000 )) >"$R/ms-$k"; return
  fi
  { echo "FAIL $t-selftest"; echo "     FAIL $out"; } >"$R/res-$k"; echo 1 >"$R/rc-$k"; echo 0 >"$R/ms-$k"
}
# N at once, from the watchdog settings (test_rerun.parallel; 1 = serial, the same path); shortcut: 4 when unreadable, a data file of its own if more knobs come.
N=$(python3 -I "$ROOT/bin/watchdog_settings.py" get test_rerun.parallel 2>/dev/null); [[ $N =~ ^[1-9][0-9]*$ ]] || N=4
run_set() { local n=$1 t; shift; for t; do while [ "$(jobs -rp | wc -l)" -ge "$n" ]; do wait -n; done; run_one "$t" & done; wait; }
par=(); ser=()   # a selftest that must not share the machine says so in its own file: a line "# selftest: serial"; those run after the batch, alone
for n in "$@"; do if grep -qs '^# selftest: serial$' "$ROOT/bin/$n-selftest.sh"; then ser+=("$n"); else par+=("$n"); fi; done
run_set "$N" "${par[@]}"; run_set 1 "${ser[@]}"

fails=0   # printed in list order, whatever order they finished in
for n in "$@"; do
  key "$n"; cat "$R/res-$k"; [ "$(cat "$R/rc-$k")" = 0 ] || fails=$((fails+1))
  # SELFTESTS_TIMES=<file>: one line "<seconds>	<name>	<ok|skip|FAIL>" per selftest
  [ -z "$times" ] || printf '%d.%03d\t%s\t%s\n' $(( $(<"$R/ms-$k") / 1000 )) $(( $(<"$R/ms-$k") % 1000 )) "$n" "$(head -1 "$R/res-$k" | cut -d' ' -f1)" >>"$times"
done
[ "$fails" = 0 ] && echo "selftests PASS" || { echo "selftests FAIL ($fails)"; exit 1; }
