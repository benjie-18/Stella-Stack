#!/usr/bin/env bash
# Hermetic self-test for bin/selftests.sh (the suite runner): a scratch tree holds a copy of the runner and four fake
# selftests (a, b: the same fixed temp name and alert log; s: serial; f: fails). Checks isolation per selftest, the output
# lines, a named run, an unknown name, and fail closed when bubblewrap is missing or refuses. Takes a few seconds.
set -u
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d); mkdir -p "$SRC/.scratch"; T2=$(mktemp -d "$SRC/.scratch/selftests-self.XXXXXX")   # a second tree on the stack tree's filesystem (ignored folder), not the temp folder's
trap 'chmod -R u+rwX "$T" "$T2" 2>/dev/null; rm -rf "$T" "$T2"; [ -z "${SLP:-}" ] || kill $SLP 2>/dev/null' EXIT
fails=0; export LC_ALL=C   # no locale warning lines in the runner output
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/out" ] && sed 's/^/     /' "$T/out" | tail -6; fi; }
mkdir -p "$T/tree/bin" "$T/tmp" "$T/marks"
# the runner under test, its list cut down to the fakes (the real names would run real selftests)
sed 's/^for t in [a-z].*; do$/for t in a b s f; do/' "$SRC/bin/selftests.sh" >"$T/tree/bin/selftests.sh"
cp "$SRC/bin/watchdog_settings.py" "$T/tree/bin/"; chmod +x "$T/tree/bin/selftests.sh"
git -C "$T/tree" init -q
# a, b: write the SAME fixed temp name and the tree's alert log, sleep, assert they see only their own bytes; they record when they ran
for n in a b; do cat >"$T/tree/bin/$n-selftest.sh" <<S
#!/usr/bin/env bash
s=\$EPOCHREALTIME; F=\${TMPDIR:-/tmp}/fixed; L=/workspace/.supervisor/logs/alerts.log
mkdir -p "\$(dirname \$L)"; printf 'own-$n' >"\$F"; printf 'alert-$n\n' >>"\$L"; sleep 1
[ "\$(cat \$F)" = own-$n ] && [ "\$(cat \$L)" = alert-$n ] || { echo "FAIL $n saw bytes of another selftest"; exit 1; }
[ $n != a ] || { hermes send x 2>/dev/null && { echo "FAIL hermes send was not refused"; exit 1; }; }
echo "\$s \$EPOCHREALTIME" >"\$MARKS/$n"; echo "selftest PASS"
S
done
printf '#!/usr/bin/env bash\n# selftest: serial\ns=$EPOCHREALTIME; sleep 1; echo "$s $EPOCHREALTIME" >"$MARKS/s"; echo "selftest PASS"\n' >"$T/tree/bin/s-selftest.sh"
printf '#!/usr/bin/env bash\necho "FAIL boom line"; echo "selftest FAIL"; exit 1\n' >"$T/tree/bin/f-selftest.sh"
chmod +x "$T"/tree/bin/*-selftest.sh
# the runner's temp folder is $T/tmp (TMPDIR), so $T itself stays visible inside the namespace for the marks
run() { TMPDIR="$T/tmp" MARKS="$T/marks" WATCHDOG_SETTINGS="$T/set.json" "$T/tree/bin/selftests.sh" "$@" >"$T/out" 2>&1; echo $? >"$T/rc"; }
echo '{"test_rerun": {"parallel": 1}}' >"$T/set.json"

run a b
ok 'grep -qx "ok   a-selftest" "$T/out" && grep -qx "ok   b-selftest" "$T/out" && [ "$(tail -1 "$T/out")" = "selftests PASS" ] && [ "$(cat "$T/rc")" = 0 ]' "S1 two selftests that share a fixed temp name and an alert log pass (each sees only its own bytes), hermes send refused inside"
ok '[ -z "$(ls -A "$T/tmp")" ] && [ ! -e "$T/tree/.supervisor" ] && [ -z "$(git -C "$T/tree" status --short -uall | grep -v "bin/")" ]' "S1 the source tree, its alert log and the shared temp folder hold nothing the fakes wrote"
ok '[ "$(grep -c "^ok " "$T/out")" = 2 ]' "S1 a named run runs only the named selftests"

run f a
ok '[ "$(sed -n 1p "$T/out")" = "FAIL f-selftest" ] && sed -n 2p "$T/out" | grep -qx "     FAIL boom line" && [ "$(sed -n 3p "$T/out")" = "ok   a-selftest" ] && [ "$(tail -1 "$T/out")" = "selftests FAIL (1)" ] && [ "$(cat "$T/rc")" = 1 ]' "S1 a failing selftest: its FAIL line and its detail in list order, selftests FAIL (1), exit 1"
run nope
ok 'grep -qx "FAIL nope-selftest" "$T/out" && grep -q "no such selftest" "$T/out" && [ "$(tail -1 "$T/out")" = "selftests FAIL (1)" ] && [ "$(cat "$T/rc")" = 1 ]' "S1 an unknown name is FAIL, not skipped"
run ../x
ok 'grep -qx "FAIL ../x-selftest" "$T/out" && [ "$(cat "$T/rc")" = 1 ]' "S1 a name that is not plain characters is FAIL"

# S2 up to N at once (N is data: test_rerun.parallel in the watchdog settings); a selftest marked serial runs alone, after the batch
overlap() { awk 'FNR==1{s[++n]=$1; e[n]=$2} END{exit !(s[1] < e[2] && s[2] < e[1])}' "$T/marks/$1" "$T/marks/$2"; }
echo '{"test_rerun": {"parallel": 2}}' >"$T/set.json"; rm -f "$T/marks"/*; run a b s
ok 'overlap a b && ! overlap a s && ! overlap b s && [ "$(grep -c "^ok " "$T/out")" = 3 ] && [ "$(tail -1 "$T/out")" = "selftests PASS" ]' "S2 N=2: a and b run at the same time (and pass), the serial selftest overlaps neither"
echo '{"test_rerun": {"parallel": 1}}' >"$T/set.json"; rm -f "$T/marks"/*; run a b
ok '! overlap a b && [ "$(grep -c "^ok " "$T/out")" = 2 ]' "S2 N=1: the same path run one at a time, no overlap"
echo '{"test_rerun": {"parallel": 2}}' >"$T/set.json"; rm -f "$T/marks"/*; SELFTESTS_TIMES="$T/times" run f a b
ok '[ "$(sed -n 1p "$T/out")" = "FAIL f-selftest" ] && [ "$(grep "^ok " "$T/out" | tr -d "\n")" = "ok   a-selftestok   b-selftest" ] && [ "$(cut -f2,3 "$T/times" | tr "\n" " ")" = "f	FAIL a	ok b	ok " ] && grep -Eq "^[0-9]+\.[0-9]{3}	f	FAIL$" "$T/times"' "S2 the output is in list order whatever finished first; SELFTESTS_TIMES gets one line per selftest"

run a a-selftest a
ok '[ "$(cat "$T/out")" = "$(printf "ok   a-selftest\nselftests PASS")" ]' "S2 a name given twice (also as <name>-selftest) runs once, first-seen order"
# S4 the quick tier: --quick runs the names `test-map.py quick` prints, same isolation and output; an unreadable or empty list is one FAIL, never the full list, never nothing
cat >"$T/tree/bin/test-map.py" <<'S'
import os, sys
d = os.path.dirname(os.path.abspath(__file__))
if os.path.exists(d + "/qfail"): sys.exit(print("list unreadable", file=sys.stderr) or 1)
if not os.path.exists(d + "/qempty"): print("a\nf")
S
rm -f "$T/marks"/*; run --quick
ok '[ "$(sed -n 1p "$T/out")" = "ok   a-selftest" ] && [ "$(sed -n 2p "$T/out")" = "FAIL f-selftest" ] && [ "$(tail -1 "$T/out")" = "selftests FAIL (1)" ] && [ -e "$T/marks/a" ] && [ ! -e "$T/marks/b" ]' "S4 --quick runs the quick list of the test map and only that"
touch "$T/tree/bin/qfail"; rm -f "$T/marks"/*; run --quick
ok 'grep -q "FAIL the quick list cannot be read: list unreadable" "$T/out" && [ "$(tail -1 "$T/out")" = "selftests FAIL (1)" ] && [ "$(cat "$T/rc")" = 1 ] && [ -z "$(ls -A "$T/marks")" ]' "S4 --quick with a list that cannot be read: one FAIL, exit 1, nothing ran"
rm "$T/tree/bin/qfail"; touch "$T/tree/bin/qempty"; run --quick
ok 'grep -q "FAIL the quick list cannot be read" "$T/out" && [ "$(cat "$T/rc")" = 1 ] && [ -z "$(ls -A "$T/marks")" ]' "S4 --quick with an empty list: one FAIL, exit 1, nothing ran"
run a-selftest
ok '[ "$(cat "$T/out")" = "$(printf "ok   a-selftest\nselftests PASS")" ]' "S2 a failed check named as the watchdog sees it (a-selftest) reruns that selftest, isolated"

# R16 faults of the runner, on a second tree (the stack tree's filesystem, not the temp folder's):
# F1 the copy lies on the tree's own filesystem; F2 a tracked file is tracked in the copy and an untracked one is not (odd names too); F3 a started selftest never sees SELFTESTS_TIMES;
# F4 a folder of a runner that is no longer alive is swept, one of a live runner is not.
mkdir -p "$T2/bin" "$T2/tmp"; sed 's/^for t in [a-z].*; do$/for t in t; do/' "$SRC/bin/selftests.sh" >"$T2/bin/selftests.sh"; cp "$SRC/bin/watchdog_settings.py" "$T2/bin/"; chmod +x "$T2/bin/selftests.sh"
cat >"$T2/bin/t-selftest.sh" <<'S'
#!/usr/bin/env bash
n=$(git -C /workspace ls-files | grep -c 'untracked'); k=$(git -C /workspace ls-files -- bin/tracked.txt ./-tracked.txt | wc -l)
[ "$(stat -f -c %T /workspace)" = "$FSWANT" ] || { echo "FAIL the copy is on a $(stat -f -c %T /workspace) filesystem, the source tree on $FSWANT"; echo "selftest FAIL"; exit 1; }
[ "$n" = 0 ] && [ "$k" = 2 ] && [ -e /workspace/bin/untracked.txt ] && [ -e "/workspace/-untracked name.txt" ] || { echo "FAIL tracked/untracked files differ in the copy (untracked tracked: $n, tracked seen: $k)"; echo "selftest FAIL"; exit 1; }
[ -z "${SELFTESTS_TIMES:-}" ] || { echo "FAIL a started selftest sees SELFTESTS_TIMES"; echo "selftest FAIL"; exit 1; }
echo "selftest PASS"
S
chmod +x "$T2/bin/t-selftest.sh"; echo tracked >"$T2/bin/tracked.txt"; echo tracked >"$T2/-tracked.txt"
git -C "$T2" init -q; git -C "$T2" add -- bin ./-tracked.txt; git -C "$T2" -c user.name=t -c user.email=t@scratch.invalid commit -qm t
echo u >"$T2/bin/untracked.txt"; echo u >"$T2/-untracked name.txt"
mkdir -p "$T2/.scratch/selftests.dead" "$T2/.scratch/selftests.live"; : >"$T2/.scratch/selftests.dead/.alive"; : >"$T2/.scratch/selftests.live/.alive"
flock "$T2/.scratch/selftests.live/.alive" sleep 60 & SLP=$!; sleep 0.3
FSWANT=$(stat -f -c %T "$T2") SELFTESTS_TIMES="$T/times2" TMPDIR="$T/tmp" WATCHDOG_SETTINGS="$T/set.json" "$T2/bin/selftests.sh" >"$T/out" 2>&1; echo $? >"$T/rc"
ok '[ "$(cat "$T/out")" = "$(printf "ok   t-selftest\nselftests PASS")" ]' "F1 F2 F3 the copy is on the tree's own filesystem, tracks what the tree tracks (odd names too), and the selftest sees no SELFTESTS_TIMES"
ok '[ "$(cut -f2,3 "$T/times2")" = "$(printf "t\tok")" ]' "F3 the caller's times file holds only the runner's own line"
ok '[ ! -e "$T2/.scratch/selftests.dead" ] && [ -e "$T2/.scratch/selftests.live" ] && [ "$(ls -A "$T2/.scratch" | wc -l)" = 1 ]' "F4 a folder of a runner that is gone is swept, one of a live runner and the runner's own are not left/removed"
kill $SLP 2>/dev/null; SLP=

# fail closed: no bubblewrap on PATH, and a bubblewrap that refuses: every selftest FAIL with a plain line, nothing ran
mkdir -p "$T/nobwrap" "$T/badbwrap"
for f in /usr/bin/* /bin/*; do [ "${f##*/}" = bwrap ] || ln -sf "$f" "$T/nobwrap/" 2>/dev/null; done
printf '#!/bin/sh\necho "bwrap: refused for the test" >&2\nexit 1\n' >"$T/badbwrap/bwrap"; chmod +x "$T/badbwrap/bwrap"
for p in "$T/nobwrap" "$T/badbwrap:$PATH"; do
  rm -f "$T/marks"/*; PATH=$p run a b
  ok 'grep -qx "FAIL a-selftest" "$T/out" && grep -qx "FAIL b-selftest" "$T/out" && grep -q "     FAIL cannot make the private copy or the mount namespace" "$T/out" && [ "$(tail -1 "$T/out")" = "selftests FAIL (2)" ] && [ "$(cat "$T/rc")" = 1 ] && [ -z "$(ls -A "$T/marks")" ]' "S1 fail closed ($(basename "${p%%:*}")): every selftest FAIL with the plain line, nothing ran"
done

[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
