#!/usr/bin/env bash
# Hermetic self-test for bin/test-map.py (product rule 8): the lint over .stella/test-map.json and the selection of test
# targets from changed files. Everything but case 1 runs in a scratch root (STELLA_ROOT), so no map row is named here.
set -u
BIN=$(dirname "$(readlink -f "$0")"); TM="$BIN/test-map.py"
T=$(mktemp -d -t tm-self.XXXXXX); trap 'rm -rf "$T"' EXIT
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
MAP='{"schema_version": 1, "runner": "bin/selftests.sh", "test_file": "bin/{name}-selftest.sh", "test_like": ["*test*"], "not_tests": ["bin/selftests.sh", ".stella/*", "fixtures/*"], "follow": ["*.sh"], "always": ["a"], "full": ["lock.json"], "map": [{"globs": ["bin/a-selftest.sh", "src/a*"], "targets": ["a"]}, {"globs": ["bin/b-selftest.sh", "src/b/*"], "targets": ["b"]}, {"globs": ["notes/*"], "targets": []}]}'
st() { printf '#!/usr/bin/env bash\n%s\necho "selftest PASS"\n' "${2:-}" >"$1"; chmod 755 "$1"; }   # <file> [a line of code]
root() {  # <name> [jq filter over MAP] [suite names]: a scratch root with selftests a and b
  local r=$T/$1; mkdir -p "$r/bin" "$r/.stella" "$r/src"; jq "${2:-.}" <<<"$MAP" >"$r/.stella/test-map.json"
  printf '#!/usr/bin/env bash\nfor t in %s; do\n  :\ndone\n' "${3:-a b}" >"$r/bin/selftests.sh"
  st "$r/bin/a-selftest.sh"; st "$r/bin/b-selftest.sh"
}
chk() { STELLA_ROOT=$T/$1 python3 -I "$TM" check >"$T/out" 2>&1; }
bad() { ! chk "$1" && grep -q "^STL-CFG-310 .*$2" "$T/out" && ! grep -q Traceback "$T/out"; }   # refused, by code, with this text
sel() { STELLA_ROOT=$T/good python3 -I "$TM" select --json "$@" 2>"$T/err"; }

ok 'env -u STELLA_ROOT python3 -I "$TM" check >"$T/live" 2>&1' "1 the map of this tree passes the lint$(sed 's/^/\n     /' "$T/live" 2>/dev/null | head -5)"
ok 'grep -q "^unset STELLA_ROOT" "$BIN/selftests.sh" && [ "$(STELLA_ROOT=/nonexistent env -u STELLA_ROOT python3 -I "$TM" check)" = "test map ok" ]' "1b the suite runner drops an inherited STELLA_ROOT, and case 1 does not read it"
root good
ok 'chk good && grep -q "root $T/good, from STELLA_ROOT" "$T/out"' "2 a complete scratch map passes, and the lint names the root it was pointed at"
root missing . "a b c"; st "$T/missing/bin/c-selftest.sh"
ok 'bad missing "bin/c-selftest.sh is not a target of any map row" && ! grep -q "suite list" "$T/out"' "3 a selftest missing from the map fails the lint, by name"
root nosuite . a
ok 'bad nosuite "bin/b-selftest.sh is not in the suite list of bin/selftests.sh"' "4 a mapped selftest missing from the suite list fails"
root ghost; rm "$T/ghost/bin/b-selftest.sh"
ok 'bad ghost "target b: bin/b-selftest.sh does not exist" && grep -q "suite entry b" "$T/out"' "5 a target or a suite entry with no selftest file fails"
root noexec; chmod 644 "$T/noexec/bin/b-selftest.sh"
ok 'bad noexec "bin/b-selftest.sh is not executable"' "6 a suite selftest that is not executable fails (the suite runs it directly)"
root gitmode; git -C "$T/gitmode" init -q && git -C "$T/gitmode" add -A && git -C "$T/gitmode" update-index --chmod=-x bin/b-selftest.sh
ok '[ -x "$T/gitmode/bin/b-selftest.sh" ] && bad gitmode "bin/b-selftest.sh is not executable in git (mode 100644)"' "6b executable on disk but not in the mode git records fails (a fresh checkout could not run it)"
ok '( cd "$T" && git init -q other 2>/dev/null; GIT_DIR=$T/other/.git STELLA_ROOT=$T/gitmode python3 -I "$TM" check >"$T/out" 2>&1; [ $? = 1 ] && grep -q "not executable in git" "$T/out" )' "6d a GIT_DIR inherited from the caller does not hide the git mode"
git -C "$T/gitmode" update-index --chmod=+x bin/b-selftest.sh
ok 'chk gitmode' "6c the same git tree passes once git records the mode"
root broken; echo '{' >"$T/broken/.stella/test-map.json"
ok 'bad broken "test-map.json"' "7 an unreadable map fails with the catalog code, not a traceback"
root nolist; echo '#!/usr/bin/env bash' >"$T/nolist/bin/selftests.sh"
ok 'bad nolist "the suite list of bin/selftests.sh cannot be read"' "8 a suite runner with no readable list fails (never an empty pass)"
root empty; rm "$T"/empty/bin/*-selftest.sh; jq '.always = [] | .map = []' <<<"$MAP" >"$T/empty/.stella/test-map.json"; printf 'for t in ; do\n' >"$T/empty/bin/selftests.sh"
ok 'bad empty "no selftest"' "8b a root with no selftest at all fails"
i=0; for f in '.schema_version = 2' '.schema_version = true' '.schema_version = 1.5' 'del(.schema_version)' 'del(.follow)' '.extra = 1' \
              '.map[0].globs = [1]' '.full = [7]' '.map[0].targets = [["a"]]' '.map[0].globs = []' '.always = "a"' '.map[0].scan = "yes"' '.test_file = "bin/x.sh"'; do
  i=$((i+1)); root "s$i" "$f"
  ok 'bad "s$i" "test-map.json: ValueError" && [ "$(grep -c "" "$T/out")" = 1 ]' "9.$i a map that breaks the schema fails with one line: $f"
done
root float; sed -i 's/"schema_version": 1,/"schema_version": 1.0,/' "$T/float/.stella/test-map.json"
ok 'grep -q "\"schema_version\": 1.0," "$T/float/.stella/test-map.json" && bad float "test-map.json: ValueError"' "9.14 schema_version 1.0 (written as a float) fails"
root two 'del(.follow) | .extra = 1'
ok 'bad two "test-map.json: ValueError" && [ "$(grep -c "^STL-CFG-310 " "$T/out")" = 2 ]' "9.15 two schema problems are two lines"
ok 'grep -q "(root $T/two, from STELLA_ROOT)" "$T/out"' "9.16 a failure line names the scratch root"
root dup; sed -i 's/^{/{"full": ["x"],/' "$T/dup/.stella/test-map.json"
ok 'bad dup "a key is repeated"' "9b a repeated key fails (the last one would win silently)"

root like; st "$T/like/bin/c-test.sh"; st "$T/like/bin/d-SELFTEST.sh"; st "$T/like/bin/.e-selftest.sh"; mkdir -p "$T/like/fixtures"; st "$T/like/fixtures/test.sh"
ok 'bad like "bin/c-test.sh looks like a test" && grep -q "bin/d-SELFTEST.sh looks like a test" "$T/out" && grep -q "bin/.e-selftest.sh is not a target of any map row" "$T/out" && ! grep -q fixtures "$T/out"' \
   "17 a test-like file outside the suite fails by name (another name, another case, a dot file); a not_tests fixture does not"
root spec ".test_like = $(jq -c .test_like "$BIN/../.stella/test-map.json")"; mkdir -p "$T/spec/spec"; st "$T/spec/spec/roles.spec.js"; st "$T/spec/src/x_spec.rb"; echo x >"$T/spec/src/a-spec.md"
ok 'bad spec "spec/roles.spec.js looks like a test" && grep -q "src/x_spec.rb looks like a test" "$T/out" && ! grep -q "a-spec.md" "$T/out"' \
   "17b the shipped test_like globs also know the spec naming (x.spec.js, x_spec.rb), not a document named -spec"

helper='bash "$(dirname "$0")/../src/a-helper.sh"'   # selftest a is an always gate, so b is the one a row can leave out
root dep; st "$T/dep/bin/b-selftest.sh" "$helper"; st "$T/dep/src/a-helper.sh" 'cat notes/data.txt'; mkdir -p "$T/dep/notes"; echo x >"$T/dep/notes/data.txt"
ok 'bad dep "src/a-helper.sh: its map rows leave out b, which can reach it" && grep -q "notes/data.txt: its map rows leave out b" "$T/out"' \
   "18 a row that leaves out a selftest which runs the file fails, also through a script that selftest runs"
jq '.map[0].targets = ["a", "b"] | .map[2].targets = ["b"]' <<<"$MAP" >"$T/dep/.stella/test-map.json"
ok 'chk dep' "18b the same root passes once the rows name that selftest"
root all '.map[0].globs = ["bin/a-selftest.sh"] | .map += [{"globs": ["*"], "targets": []}]'; st "$T/all/bin/b-selftest.sh" "$helper"; st "$T/all/src/a-helper.sh"
ok 'bad all "src/a-helper.sh: its map rows leave out b"' "18c a catch-all row with no targets does not hide a dependency"
root cross; st "$T/cross/bin/b-selftest.sh" '. "$(dirname "$0")/a-selftest.sh"'
ok 'bad cross "bin/a-selftest.sh: its map rows leave out b"' "19 a selftest that sources another selftest must be selected when that one changes"
root remark; st "$T/remark/bin/b-selftest.sh" '# see a-selftest.sh for the other half'
ok 'chk remark' "19b a file named only in a whole-line comment is not a dependency"
root py '.follow = ["*.py"]'; st "$T/py/bin/b-selftest.sh" 'python3 -c "import sys; import a_mod"'; echo 'x = 1' >"$T/py/src/a_mod.py"
ok 'bad py "src/a_mod.py: its map rows leave out b"' "19c a Python module is reached by its import"

ok '[ "$(sel src/a1.py | jq -c "[.full, .targets]")" = "[false,[\"a\"]]" ]' "10 a mapped file selects its targets plus the always gates"
ok '[ "$(sel src/b/x/y.py | jq -c "[.full, .targets]")" = "[false,[\"a\",\"b\"]]" ]' "11 a glob crosses folders; targets are merged and sorted"
ok '[ "$(sel notes/x.md | jq -c "[.full, .targets]")" = "[false,[\"a\"]]" ]' "12 a row with no targets selects the always gates only"
ok '[ "$(sel src/a1.py other/z | jq -r .full)" = true ] && sel src/a1.py other/z | jq -e ".reason | any(test(\"other/z\"))" >/dev/null' "13 a file no row matches selects the full suite, and the reason names it"
ok '[ "$(sel lock.json | jq -r .full)" = true ]' "14 a full-suite glob selects the full suite"
ok '[ "$(sel | jq -c "[.full, .targets]")" = "[true,[\"a\"]]" ] && [ "$(STELLA_ROOT=$T/good python3 -I "$TM" select)" = full ]' "15 no file name at all selects the full suite (as 16b: a failed diff is not \"nothing changed\")"
ok '[ "$(printf "src/a1.py\nsrc/b/q\n" | STELLA_ROOT=$T/good python3 -I "$TM" select --json - | jq -c .targets)" = "[\"a\",\"b\"]" ]' "16 file names are also read from stdin (-), one per line"
ok '[ "$(sel - </dev/null | jq -r .full)" = true ] && [ "$(STELLA_ROOT=$T/good python3 -I "$TM" select - </dev/null)" = full ]' "16b an empty list on stdin selects the full suite (a failed diff is not \"nothing changed\")"
ok '[ "$(sel "$(printf "src/a1.py\nlock.json")" | jq -r .full)" = true ] && [ "$(sel "src/a1.py lock.json" | jq -r .full)" = true ] && [ "$(printf "src/a1.py\0lock.json\0" | STELLA_ROOT=$T/good python3 -I "$TM" select --json - | jq -r .full)" = true ]' "16c names joined into one (newline, space, NUL) select the full suite, never the first name's row"
root nl; st "$T/nl/bin/$(printf 'a\nb-test.sh')"
ok '! chk nl && [ "$(grep -c "" "$T/out")" = 1 ] && grep -q "looks like a test" "$T/out"' "17c a file name with a newline stays one whole problem line"
root scan '.map += [{"scan": true, "globs": ["src/*", "new/*"], "targets": ["b"]}]'
ok '[ "$(STELLA_ROOT=$T/scan python3 -I "$TM" select --json src/a1.py | jq -c "[.full, .targets]")" = "[false,[\"a\",\"b\"]]" ] && [ "$(STELLA_ROOT=$T/scan python3 -I "$TM" select new/x)" = full ]' \
   "20 a scan row adds its targets and does not count as a match (an unmapped file still selects the full suite)"
ok '! STELLA_ROOT=$T/broken python3 -I "$TM" select x >"$T/o" 2>"$T/e" && [ ! -s "$T/o" ] && grep -q "^STL-CFG-310 " "$T/e" && ! grep -q Traceback "$T/e"' "21 select on an unreadable map exits 1 with the catalog code and prints no selection"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
