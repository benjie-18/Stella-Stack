#!/usr/bin/env bash
# Hermetic self-test for bin/selftests.sh (the suite runner): a scratch tree holds a copy of the runner and four fake
# selftests (a, b: the same fixed temp name and alert log; s: serial; f: fails). Checks isolation per selftest, the output
# lines, a named run, an unknown name, and fail closed when bubblewrap is missing or refuses. Takes a few seconds.
set -u
T=$(mktemp -d); trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
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

# fail closed: no bubblewrap on PATH, and a bubblewrap that refuses: every selftest FAIL with a plain line, nothing ran
mkdir -p "$T/nobwrap" "$T/badbwrap"
for f in /usr/bin/* /bin/*; do [ "${f##*/}" = bwrap ] || ln -sf "$f" "$T/nobwrap/" 2>/dev/null; done
printf '#!/bin/sh\necho "bwrap: refused for the test" >&2\nexit 1\n' >"$T/badbwrap/bwrap"; chmod +x "$T/badbwrap/bwrap"
for p in "$T/nobwrap" "$T/badbwrap:$PATH"; do
  rm -f "$T/marks"/*; PATH=$p run a b
  ok 'grep -qx "FAIL a-selftest" "$T/out" && grep -qx "FAIL b-selftest" "$T/out" && grep -q "     FAIL cannot make the private copy or the mount namespace" "$T/out" && [ "$(tail -1 "$T/out")" = "selftests FAIL (2)" ] && [ "$(cat "$T/rc")" = 1 ] && [ -z "$(ls -A "$T/marks")" ]' "S1 fail closed ($(basename "${p%%:*}")): every selftest FAIL with the plain line, nothing ran"
done

[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
