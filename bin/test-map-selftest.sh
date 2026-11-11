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
root gitmode '.map += [{"globs": [".stella/*", "bin/selftests.sh"], "targets": ["b"]}]'; git -C "$T/gitmode" init -q && git -C "$T/gitmode" add -A && git -C "$T/gitmode" update-index --chmod=-x bin/b-selftest.sh
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

# A row with no targets (notes/*, map row 3) may match only prose: nothing that runs, nothing read as code or data names it.
pr() { root "$1" "${2:-.}"; mkdir -p "$T/$1/notes"; }
pr catch '.map += [{"globs": ["**"], "targets": []}]'
ok 'bad catch "map row 4 (\*\*) has no targets and its glob \*\* matches every path"' "22 a row with no targets whose glob matches every path is refused"
pr k1; echo x >"$T/k1/notes/x.sh"
pr k2; echo x >"$T/k2/notes/run"; chmod 755 "$T/k2/notes/run"
pr k3; printf '#!/bin/sh\n' >"$T/k3/notes/tool"
pr k4 '.not_tests += ["notes/*"]'; echo x >"$T/k4/notes/test-plan.md"
pr k5 '.data = ["*.json"]'; echo '{"hooks": ["notes/x.cfg"]}' >"$T/k5/src/hooks.json"; echo x >"$T/k5/notes/x.cfg"
pr k6; echo 'notes/y.md' >"$T/k6/src/list"; echo x >"$T/k6/notes/y.md"
ok 'bad k1 "map row 3 (notes/\*) has no targets, so it may match only prose, but it matches notes/x.sh: code" \
 && bad k2 "matches notes/run: an executable file" && bad k3 "matches notes/tool: a script" && bad k4 "matches notes/test-plan.md: a test-like file" \
 && bad k5 "matches notes/x.cfg: named by src/hooks.json" && bad k6 "matches notes/y.md: named by src/list"' \
   "22b a row with no targets that matches code, an executable, a #! script, a test-like file (even in not_tests) or a file a data file names is refused"
pr k7 '.data = ["*.json"]'; echo x >"$T/k7/notes/x.sh"; echo x >"$T/k7/notes/y.sh"
ok 'bad k7 "notes/x.sh: code" && [ "$(grep -c "map row 3" "$T/out")" = 1 ]' "22c one line per row, naming the first offending file"
pr k8 '.data = ["*.json"]'; mkdir -p "$T/k8/docs"; echo 'see notes/plan.md' >"$T/k8/docs/guide.md"; echo x >"$T/k8/notes/plan.md"
ok 'chk k8' "22d a row with no targets that matches only prose (named only in a file that is not data) passes"

# Every line says where it looked, stays one line, and loses nothing to the catalog's 200-character limit.
val() { sed -n 's/^STL-CFG-310 A data file that Stella reads is not valid: \(.*\)\. What the file describes.*$/\1/p' "$T/out"; }
allroot() { [ "$(grep -c "" "$T/out")" = "$(grep -cF "(root $T/$1, from STELLA_ROOT)" "$T/out")" ]; }
root long; long=$(printf 'x%.0s' $(seq 170)); echo x >"$T/long/bin/$long-test.sh"
ok '! chk long && allroot long && [ "$(grep -c "" "$T/out")" -gt 1 ] && val | sed "s/^(part [0-9]* of [0-9]*) //; s/ (root .*//" | tr -d "\n" | grep -q "bin/$long-test.sh looks like a test"' \
   "23 a problem longer than the limit is split: every piece names the root, and the pieces join to the whole problem"
names=$(seq -f 'b%g' 60 | tr '\n' ' '); root many '.map[0].globs = ["bin/a-selftest.sh", "src/shared.sh"]' "a b $names"
jq --arg n "$names" '.map[1] = {globs: ["bin/b*-selftest.sh"], targets: (["b"] + ($n | split(" ") | map(select(. != ""))))}' "$T/many/.stella/test-map.json" >"$T/m.json" && mv "$T/m.json" "$T/many/.stella/test-map.json"
for t in $names; do st "$T/many/bin/$t-selftest.sh" 'bash "$(dirname "$0")/../src/shared.sh"'; done; st "$T/many/src/shared.sh"
miss() { for t in $names; do grep -q "src/shared.sh: its map rows leave out \(.*, \)\?$t\(, .*\)\?, which can reach it" "$T/out" || return 1; done; }
ok '! chk many && allroot many && [ "$(grep -c "" "$T/out")" -gt 1 ] && miss' "23b a list of selftests longer than the limit is split into whole lines: every name is there, every line names the root"
nlr=$'nlroot\nSTL-CFG-310 forged'; NLR=$T/$nlr; root "$nlr"
ok 'STELLA_ROOT=$NLR python3 -I "$TM" check >"$T/out" 2>&1 && [ "$(grep -c "" "$T/out")" = 1 ] && ! grep -q "^STL-CFG-310" "$T/out"' "23c the pass line is escaped: a root with a newline stays one line"
deep=$(printf 'd%.0s' $(seq 150)); root "$deep/r"; echo x >"$T/$deep/r/bin/c-test.sh"
ok '! chk "$deep/r" && val | sed "s/^(part [0-9]* of [0-9]*) //" | tr -d "\n" | grep -qF "$T/$deep/r" && grep -q "bin/c-test.sh looks like a test" "$T/out"' \
   "23d a root too long to ride on every line is named once, in whole pieces"
ok 'STELLA_ROOT=$T/good python3 -I "$TM" select src/a1.py 2>"$T/e" >/dev/null && grep -qF "$T/good" "$T/e" && [ "$(sel src/a1.py | jq -r .root)" = "$T/good" ] && ! env -u STELLA_ROOT python3 -I "$TM" select --json bin/test-map.py | jq -e "has(\"root\")" >/dev/null' \
   "23e select names the root it used when STELLA_ROOT is set (stderr, and root in --json), and only then"

# git answers for the tree, not for the caller: no personal config or ignore list hides an untracked file.
root gcfg; git -C "$T/gcfg" init -q; mkdir -p "$T/gh" "$T/gx/git"; st "$T/gcfg/bin/c-test.sh"
printf '*-test.sh\n' >"$T/gx/git/ignore"; printf 'bin/c-test.sh\n' >"$T/gh/ign"; printf '[core]\n\texcludesFile = %s\n' "$T/gh/ign" >"$T/gh/.gitconfig"
ok 'HOME=$T/gh XDG_CONFIG_HOME=$T/gx STELLA_ROOT=$T/gcfg python3 -I "$TM" check >"$T/out" 2>&1; [ $? = 1 ] && grep -q "bin/c-test.sh looks like a test" "$T/out"' \
   "24 a global ignore list (core.excludesFile, XDG git/ignore) does not hide an untracked test"

# A name is a name: only the first argument may be an option, "--" ends the options, stdin is not stripped, the full list ignores case.
ok '[ "$(STELLA_ROOT=$T/good python3 -I "$TM" select -- --json 2>/dev/null)" = full ] && [ "$(STELLA_ROOT=$T/good python3 -I "$TM" select src/a1.py --json 2>/dev/null)" = full ] && [ "$(sel -- src/a1.py | jq -c .targets)" = "[\"a\"]" ]' \
   "25 a changed file named --json is a name (after \"--\", or not first), and selects full"
ok '[ "$(printf " src/a1.py\n" | sel - | jq -r .full)" = true ] && [ "$(printf "src/a1.py \n" | sel - | jq -r .full)" = true ]' "25b a name on stdin with white space at either end selects full, as an argument does"
root case '.full += ["*guard*"]'
ok '[ "$(STELLA_ROOT=$T/case python3 -I "$TM" select src/aGuard.py 2>/dev/null)" = full ] && [ "$(STELLA_ROOT=$T/case python3 -I "$TM" select src/a1.py 2>/dev/null)" = a ]' "25c a full-list glob matches without regard to case"
ok '[ "$(printf "src/a1.py\n" | sel -- - | jq -r .full)" = true ] && [ "$(printf "src/a1.py\n" | STELLA_ROOT=$T/good python3 -I "$TM" select -- - 2>/dev/null)" = full ]' "25d a name \"-\" after \"--\" is a name (leading dash: full), not a read of stdin"
ok '[ "$(printf "src/a\xe9.py\n" | LC_ALL=C.UTF-8 sel - | jq -r .full)" = true ] && [ "$(sel "$(printf "src/a\xe9.py")" | jq -r .full)" = true ]' "25e a name that is not valid UTF-8 text (on stdin or as an argument) selects full"
ok '! STELLA_ROOT=$T/good python3 -I "$TM" select - <&- >"$T/o" 2>"$T/e" && [ ! -s "$T/o" ] && grep -q "^STL-CFG-310 .*stdin" "$T/e" && ! grep -q "test-map.json" "$T/e" && ! grep -q Traceback "$T/e"' \
   "25f stdin that cannot be read fails with its own message, which does not blame the map"

# A row is judged by what it adds beyond the always gates (a is the gate here): adding none, it may match only prose.
pr g1 '.map[2].targets = ["a"]'; echo x >"$T/g1/notes/x.sh"
pr g2 '.data = ["*.json"] | .map[2].targets = ["a"]'; echo '{"hooks": ["notes/x.cfg"]}' >"$T/g2/src/hooks.json"; echo x >"$T/g2/notes/x.cfg"
ok 'bad g1 "map row 3 (notes/\*) adds no target beyond the always gates (a), so it may match only prose, but it matches notes/x.sh: code" && bad g2 "matches notes/x.cfg: named by src/hooks.json"' \
   "26 a row whose targets are only always gates is refused like a row with no targets"
pr g3 '.map[0].globs += ["src/a-tool.sh"]'; st "$T/g3/src/a-tool.sh"
joined() { val | sed "s/^(part [0-9]* of [0-9]*) //; s/ (root .*//" | tr -d "\n"; }   # a long problem is split into parts
ok '! chk g3 && joined | grep -qF "map row 1 (bin/a-selftest.sh, src/a*, src/a-tool.sh) adds no target beyond the always gates (a), so it may match only prose, but it matches src/a-tool.sh" && ! grep -q "matches bin/a-selftest.sh" "$T/out" && chk good' \
   "26b the gate's own selftest file is the one code file such a row may match"
pr g4 '.map += [{"globs": ["src/*", "*"], "targets": ["b"]}]'
ok 'bad g4 "map row 4 (src/\*, \*) is not a scan row, and its glob \* matches every path"' "26c a glob that matches every path is refused in a row with targets too"
pr g5 '.data = [] | .map[2].targets = ["a"]'; echo '{"hooks": ["notes/x.cfg"]}' >"$T/g5/src/hooks.json"; echo x >"$T/g5/notes/x.cfg"
ok 'bad g5 "matches notes/x.cfg: named by src/hooks.json"' "26d an empty data list means every file is data (it cannot switch the rule off)"
mkdir -p "$T/ship/.stella"
for g in $(jq -r '.always[]' "$BIN/../.stella/test-map.json"); do
  jq --arg g "$g" '.map += [{globs: ["*"], targets: [$g]}]' "$BIN/../.stella/test-map.json" >"$T/ship/.stella/test-map.json"
  ok 'bad ship "is not a scan row, and its glob \* matches every path"' "26e the shipped map plus a row * -> [$g] (an always gate) is refused"
done

# The map, its schema and the tool select their users like any other file (the always gate of this tool runs check); select
# answers full only for a map it cannot trust: one that breaks a rule that needs no file list, or an empty selection.
root own '.map += [{"globs": [".stella/*", "bin/*.py"], "targets": ["b"]}]'
ok 'chk own && [ "$(STELLA_ROOT=$T/own python3 -I "$TM" select bin/other.py 2>/dev/null)" = "a
b" ] && ( for f in .stella/test-map.json .stella/schemas/test-map.schema.json bin/test-map.py; do [ "$(STELLA_ROOT=$T/own python3 -I "$TM" select "$f" 2>/dev/null)" = "a
b" ] || exit 1; done )' \
   "27 a change to the map, its schema or the tool selects the targets of its rows, like any other file"
# a map edit that drops a reaching selftest from a row, with a change to that file: the gate stays selected and check fails
root drop '.always = ["a"] | .map[1].globs += ["src/h.sh"] | .map += [{"globs": ["bin/c-selftest.sh"], "targets": ["c"]}]' "a b c"
st "$T/drop/bin/c-selftest.sh"; st "$T/drop/bin/b-selftest.sh" 'bash "$(dirname "$0")/../src/h.sh"'; st "$T/drop/src/h.sh"
ok 'chk drop' "27d control: the row for src/h.sh names b, the selftest that runs it: check passes"
jq '.map[1].targets = ["c"]' "$T/drop/.stella/test-map.json" >"$T/m.json" && mv "$T/m.json" "$T/drop/.stella/test-map.json"
me=$(basename "$0" | sed "s/-selftest\.sh$//")
ok '[ "$(STELLA_ROOT=$T/drop python3 -I "$TM" select src/h.sh 2>/dev/null | tr "\n" " ")" = "a c " ] && bad drop "src/h.sh: its map rows leave out b, which can reach it" && jq -e --arg me "$me" ".always | index(\$me)" "$BIN/../.stella/test-map.json" >/dev/null' \
   "27e the same edit dropping b selects the gate a and c, and check on that tree fails naming the file; the shipped gates hold this tool's selftest ($me), which runs check"

# The map stays finished: a tracked file no row matches fails check; on the shipped tree no tracked file selects full.
root rowless '.map += [{"globs": [".stella/*", "bin/selftests.sh"], "targets": ["b"]}]'; mkdir -p "$T/rowless/docs" "$T/rowless/scratch"
echo x >"$T/rowless/docs/new.txt"; git -C "$T/rowless" init -q && git -C "$T/rowless" add -A; echo x >"$T/rowless/scratch/u.txt"
ok 'bad rowless "docs/new.txt: no map row matches this tracked file; add a row whose targets are the selftests that use it (when unsure, its folder" && ! grep -q "scratch/u.txt" "$T/out"' \
   "28 a tracked file that no row matches fails check, with what to do; an untracked one does not"
jq '.map[-1].globs += ["docs/*"]' "$T/rowless/.stella/test-map.json" >"$T/m.json" && mv "$T/m.json" "$T/rowless/.stella/test-map.json"
ok 'chk rowless' "28b the same tree passes once a row matches the file"
sweep() { env -u STELLA_ROOT python3 -I - "$TM" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tm", sys.argv[1]); tm = importlib.util.module_from_spec(spec); spec.loader.exec_module(tm)
m, files = tm.load(), tm.tree()
sel = {f: tm.select([f], m) for f, mode in files.items() if mode}   # tracked files only
full = sorted(f for f, s in sel.items() if s["full"])
wide = max(sel, key=lambda f: (len(sel[f]["targets"]), f))
print(len(sel), len(full), " ".join(full[:5]) or "-", len(sel[wide]["targets"]), wide, sep="\t")   # no empty field: read joins tabs
EOF
}
IFS=$'\t' read -r n_all n_full first_full n_wide f_wide < <(sweep)
ok '[ "${n_all:-0}" -gt 0 ] && [ "$n_full" = 0 ]' "29 none of the $n_all tracked files of this tree selects the full suite (full: ${n_full:-?} ${first_full:-})"
ok '[ "${n_wide:-0}" -gt 0 ]' "29b the widest selection of this tree: $n_wide selftests, for $f_wide"
root wide '.map += [{"globs": ["*"], "targets": ["b"]}]'
ok '( for f in src/a1.py notes/x.md bin/a-selftest.sh; do [ "$(STELLA_ROOT=$T/wide python3 -I "$TM" select "$f" 2>"$T/e")" = full ] && grep -q "matches every path" "$T/e" || exit 1; done )' \
   "27b a map that fails a check rule selects full for every file, with the reason on stderr"
root none '.always = []'
ok '[ "$(STELLA_ROOT=$T/none python3 -I "$TM" select notes/x.md 2>/dev/null)" = full ] && [ "$(STELLA_ROOT=$T/none python3 -I "$TM" select --json notes/x.md 2>/dev/null | jq -r .full)" = true ]' \
   "27c an empty selection is never printed: full"

# git answers for the tree: the tree's own untracked settings (info/exclude, a local excludesFile or worktree) hide nothing
# and run nothing (core.fsmonitor).
root gl; git -C "$T/gl" init -q; st "$T/gl/bin/c-test.sh"; echo 'bin/c-test.sh' >>"$T/gl/.git/info/exclude"; echo 'c-*' >"$T/gl-ign"; mkdir -p "$T/gl-wt"
git -C "$T/gl" config core.excludesFile "$T/gl-ign"; git -C "$T/gl" config core.worktree "$T/gl-wt"
printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$T/gl-ran" >"$T/gl-mon"; chmod 755 "$T/gl-mon"; git -C "$T/gl" config core.fsmonitor "$T/gl-mon"
ok 'bad gl "bin/c-test.sh looks like a test" && [ ! -e "$T/gl-ran" ]' "24b info/exclude, a repo-local excludesFile or worktree hide no untracked test, and the tree's fsmonitor program is not run"

# A problem in 100 or more parts keeps the whole root note on every part.
root parts ".map += [{globs: ([range(100)] | map(\"docs/$(printf 'g%.0s' $(seq 240))\\(.).md\") + [\"*\"]), targets: []}]"   # globs longer than a line: every part is cut at full width
ok '! chk parts && [ "$(grep -c "" "$T/out")" -ge 100 ] && allroot parts' "23f a problem split into 100 or more parts keeps the root note on every part"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
