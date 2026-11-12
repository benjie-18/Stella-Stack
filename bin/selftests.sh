#!/usr/bin/env bash
# Run every hermetic self-test (stubs, scratch state, no network, no secrets). Part of `npm test`, so the 15-minute
# watchdog (bin/watchdog.sh) also catches escalation-script regressions and alerts #alerts (D31).
# usage: selftests.sh [name...]   no name = the whole list below; a name without a selftest file is FAIL.
# Each selftest runs ISOLATED: the tree this script lies in is copied as it is on disk (tracked files plus untracked files
# git does not ignore) into a one-commit repository, and the selftest runs in a bubblewrap mount namespace with that copy
# bound at the stack's path and a private folder bound over the system temp folder. So it has its own tree, alert log and
# temp names; the source tree, the live alert log and the shared temp folder get nothing. Fail closed: a selftest is only
# ever started inside the namespace; if the copy or the namespace cannot be made, every selftest is FAIL with one plain line
# (inside a box that forbids nested namespaces the suite therefore fails: an open owner decision, not designed around).
# The owner settings files the copy's role table lists and node_modules are bound read-only from the source tree.
set -u
unset STELLA_ROOT   # an inherited scratch root must not re-target the data tools and the gates that run them
unset HARDCODE_ALLOW HARDCODE_HOME   # likewise the hard-code lint's own switches (another list or home would turn its gate green)
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
STACK=/workspace   # shortcut: the path the stack's scripts name literally; upgrade when they take their root from their own location
TD=${TMPDIR:-/tmp}
suite=()
for t in alert alert-page delegation escalate escalation-thread escalation-reply-poll escalation-reply-hook escalation-complete kanban-guard false-close-guard check-guard complete-gate roles-complete profile-hooks commit-guard owner-config owner-leak write-guard roles role-guard secret-read matcher-audit kanban-board merge-card owner-settings watchdog model-watch hardcode-lint init-firewall firewall-probe container-start post-edit-check box bench approval-sim omniroute-run reviewer-claude approval-evidence routing broker-put test-map stella-data event-log stella-apply settings; do
  suite+=("$t")
done
[ $# = 0 ] && set -- "${suite[@]}"
R=$(mktemp -d) || { echo "selftests FAIL (1)"; echo "     FAIL cannot make a temp folder"; exit 1; }
trap 'chmod -R u+rwX "$R" 2>/dev/null; rm -rf "$R"' EXIT

# The copy is made once; a job duplicates it. Sets binds (the read-only mounts); returns 1 with the reason on stdout.
prep() {
  command -v bwrap >/dev/null || { echo "bwrap (bubblewrap) is not installed"; return 1; }
  ( set -o pipefail
    git -C "$ROOT" ls-files -z --cached --others --exclude-standard | sed -z 's|^|./|' >"$R/files" &&   # names, never options
    mkdir "$R/base" && tar -c -C "$ROOT" --null -T "$R/files" -f - | tar -x -C "$R/base" -f - &&
    git -C "$R/base" init -q -b qa && git -C "$R/base" add -A &&
    git -C "$R/base" -c user.name=selftests -c user.email=selftests@scratch.invalid -c commit.gpgsign=false commit -q --no-verify -m "scratch copy"
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

# run_one <name>: writes $R/res-<name> (the result lines), rc-<name> (0 pass or skip, 1 FAIL), ms-<name> (milliseconds)
run_one() {
  local t=$1 out s=${EPOCHREALTIME//[.,]/}; local k=${t//[^A-Za-z0-9._-]/_}; local p=$R/job-$k
  if [[ ! $t =~ ^[A-Za-z0-9._-]+$ || ! -f $ROOT/bin/$t-selftest.sh ]]; then out="no such selftest: bin/$t-selftest.sh"
  elif [ -n "$bad" ]; then out="cannot make the private copy or the mount namespace ($bad)"
  elif ! mkdir -p "$p/tmp/.bin" || ! cp -a "$R/base" "$p/tree"; then out="cannot make the private copy or the mount namespace (cp failed)"
  else
    # K11: no selftest posts to Discord. A `hermes` first on PATH refuses `send` and passes every other call to the real one;
    # a selftest's own stub, put before it, still wins. It lives in the private temp folder, which the selftest sees as $TD.
    printf '#!/usr/bin/env bash\n[ "${1:-}" = send ] && { echo "selftests: hermes send refused in a selftest" >&2; exit 1; }\nexec %q "$@"\n' "$real_hermes" >"$p/tmp/.bin/hermes"
    chmod +x "$p/tmp/.bin/hermes"
    # the temp folder is bound last: the other sources may lie under it
    out=$(nice bwrap --dev-bind / / --bind "$p/tree" "$STACK" "${binds[@]}" --bind "$p/tmp" "$TD" --chdir "$STACK" \
      --setenv PATH "$TD/.bin:$PATH" -- "$STACK/bin/$t-selftest.sh" </dev/null 2>&1 | grep -v setlocale)
    rm -rf "$p"
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
  k=${n//[^A-Za-z0-9._-]/_}; cat "$R/res-$k"; [ "$(cat "$R/rc-$k")" = 0 ] || fails=$((fails+1))
  # SELFTESTS_TIMES=<file>: one line "<seconds>	<name>	<ok|skip|FAIL>" per selftest
  [ -z "${SELFTESTS_TIMES:-}" ] || printf '%d.%03d\t%s\t%s\n' $(( $(<"$R/ms-$k") / 1000 )) $(( $(<"$R/ms-$k") % 1000 )) "$n" "$(head -1 "$R/res-$k" | cut -d' ' -f1)" >>"$SELFTESTS_TIMES"
done
[ "$fails" = 0 ] && echo "selftests PASS" || { echo "selftests FAIL ($fails)"; exit 1; }
