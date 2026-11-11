#!/usr/bin/env bash
# Hermetic self-test for bin/test-map.py (product rule 8): the lint over .stella/test-map.json and the selection of test
# targets from changed files. Everything but case 1 runs in a scratch root (STELLA_ROOT), so no map row is named here.
set -u
BIN=$(dirname "$(readlink -f "$0")"); TM="$BIN/test-map.py"
T=$(mktemp -d -t test-map-selftest.XXXXXX); trap 'rm -rf "$T"' EXIT
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
root() {  # <dir> <map json>: a scratch root with selftests a and b in its suite list
  mkdir -p "$1/bin" "$1/.stella"; printf '%s\n' "$2" >"$1/.stella/test-map.json"
  printf '#!/usr/bin/env bash\nfor t in a b; do\n  :\ndone\n' >"$1/bin/selftests.sh"
  for t in a b; do printf '#!/usr/bin/env bash\necho "selftest PASS"\n' >"$1/bin/$t-selftest.sh"; chmod 755 "$1/bin/$t-selftest.sh"; done
}
MAP='{"schema_version": 1, "always": ["a"], "full": ["lock.json"], "map": [{"globs": ["bin/a-selftest.sh", "src/a*"], "targets": ["a"]}, {"globs": ["bin/b-selftest.sh", "src/b/*"], "targets": ["b"]}, {"globs": ["notes/*"], "targets": []}]}'
chk() { STELLA_ROOT=$1 python3 -I "$TM" check >"$T/out" 2>&1; }
sel() { STELLA_ROOT=$T/good python3 -I "$TM" select --json "$@" 2>"$T/err"; }

ok 'python3 -I "$TM" check >"$T/live" 2>&1' "1 the map of this tree passes the lint$(sed 's/^/\n     /' "$T/live" 2>/dev/null | head -5)"
root "$T/good" "$MAP"
ok 'chk "$T/good"' "2 a complete scratch map passes"
cp -r "$T/good" "$T/missing"; printf '#!/usr/bin/env bash\necho "selftest PASS"\n' >"$T/missing/bin/c-selftest.sh"; chmod 755 "$T/missing/bin/c-selftest.sh"
ok '! chk "$T/missing" && grep -q "c-selftest" "$T/out"' "3 a selftest missing from the map fails the lint, by name"
cp -r "$T/good" "$T/nosuite"; sed -i 's/for t in a b;/for t in a;/' "$T/nosuite/bin/selftests.sh"
ok '! chk "$T/nosuite" && grep -q "b" "$T/out"' "4 a mapped selftest missing from the suite list fails"
cp -r "$T/good" "$T/ghost"; rm "$T/ghost/bin/b-selftest.sh"
ok '! chk "$T/ghost"' "5 a target with no selftest file fails"
cp -r "$T/good" "$T/noexec"; chmod 644 "$T/noexec/bin/b-selftest.sh"
ok '! chk "$T/noexec" && grep -q "executable" "$T/out"' "6 a suite selftest that is not executable fails (the suite runs it directly)"
cp -r "$T/good" "$T/broken"; echo '{' >"$T/broken/.stella/test-map.json"
ok '! chk "$T/broken"' "7 an unreadable map fails"
cp -r "$T/good" "$T/nolist"; echo '#!/usr/bin/env bash' >"$T/nolist/bin/selftests.sh"
ok '! chk "$T/nolist"' "8 a suite runner with no readable list fails (never an empty pass)"
cp -r "$T/good" "$T/v2"; sed -i 's/"schema_version": 1/"schema_version": 2/' "$T/v2/.stella/test-map.json"
ok '! chk "$T/v2"' "9 an unknown schema_version fails"

ok '[ "$(sel src/a1.py | jq -c "[.full, .targets]")" = "[false,[\"a\"]]" ]' "10 a mapped file selects its targets plus the always gates"
ok '[ "$(sel src/b/x/y.py | jq -c "[.full, .targets]")" = "[false,[\"a\",\"b\"]]" ]' "11 a glob crosses folders; targets are merged and sorted"
ok '[ "$(sel notes/x.md | jq -c "[.full, .targets]")" = "[false,[\"a\"]]" ]' "12 a row with no targets selects the always gates only"
ok '[ "$(sel src/a1.py other/z | jq -r .full)" = true ] && sel src/a1.py other/z | jq -e ".reason | any(test(\"other/z\"))" >/dev/null' "13 a file no row matches selects the full suite, and the reason names it"
ok '[ "$(sel lock.json | jq -r .full)" = true ]' "14 a full-suite glob selects the full suite"
ok '[ "$(sel | jq -c "[.full, .targets]")" = "[false,[\"a\"]]" ]' "15 no changed file selects the always gates"
ok '[ "$(printf "src/a1.py\nsrc/b/q\n" | STELLA_ROOT=$T/good python3 -I "$TM" select --json - | jq -c .targets)" = "[\"a\",\"b\"]" ]' "16 file names are also read from stdin (-), one per line"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
