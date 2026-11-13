#!/usr/bin/env bash
# Self-test for bin/hardcode-lint.sh (K12, E8). The lint itself, and its header, say where the literals come from.
# Case 1-3 run it on this tree with the real home; every planted case runs on a scratch root that holds only what the lint
# lists (`hardcode-lint.sh --list`: the files it scans and the data it reads, never an owner setting or the apply tool's state)
# with a scratch HARDCODE_HOME, never the live tree. The planted names are invented here.
set -u
BIN=$(dirname "$(readlink -f "$0")"); W=$(dirname "$BIN"); L=$BIN/hardcode-lint.sh; A=$W/docs/hermes-local/hardcode-allow.json; fails=0   # not HARDCODE_ALLOW: case 1 checks this tree with this list (L5)
T=$(mktemp -d -t hardcode-lint-selftest.XXXXXX); trap 'rm -rf "$T"' EXIT
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
S=$T/root; H=$T/home
mkhome() {  # a scratch home whose projects.db holds one slug
  rm -rf "$H"; mkdir -p "$H/.hermes"
  python3 -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1] + "/.hermes/projects.db"); c.execute("create table projects (slug text)"); c.execute("insert into projects values (?)", (sys.argv[2],)); c.commit()' "$H" "$slug"
}
cp_listed() {  # cp_listed <source root> <dest>: copy the lint's own list of that root, each line a file name (never an option); a failed list, tar or extract is a failure
  local l; l=$(STELLA_ROOT=$1 HARDCODE_ALLOW= "$L" --list) && printf '%s\n' "$l" >"$T/list" \
    && ( set -o pipefail; tar -C "$1" --no-recursion --verbatim-files-from -T "$T/list" -cf - | tar -C "$2" -xf - )
}
fresh() {  # a clean scratch root (the listed files only, never the tree), and a fresh scratch home; a failed copy ends the selftest
  rm -rf "$S"; mkdir -p "$S"; mkhome
  cp_listed "$W" "$S" || { echo "FAIL fresh: the scratch root could not be made (the lint's list or the copy failed)"; echo "selftest FAIL"; exit 1; }
}
tree_check() {  # tree_check <lint>: the one case that checks THIS tree with THIS list and the machine's own home (the suite clears the switches)
  env -u HARDCODE_ALLOW -u STELLA_ROOT -u HARDCODE_HOME "$1" --check 2>&1
}
lint() { STELLA_ROOT=$S HARDCODE_ALLOW= HARDCODE_HOME=$H "$S/bin/hardcode-lint.sh" "$@" 2>&1; }   # empty HARDCODE_ALLOW: the copy's own list
plant() { printf '\n# %s\n' "$2" >>"$S/$1"; }   # one use of a literal in a scanned file
fails_on() { out=$(lint) ; [ $? = 1 ] && grep -qF -- "$1" <<<"$out"; }   # exit 1 and a line naming the literal
slug=$(jq -r '.own_names[0].text | ltrimstr(".")' "$A")   # the stack's own name doubles as a retired project slug in the board data
own=$(jq -r '.own_names[0].text' "$A")
plug=$(cd "$W" && ls docs/hermes-local/plugins/*/*.py docs/hermes-local/plugins/*.py 2>/dev/null | head -1)
row=$(jq -r '.baseline[0] | "\(.file)\t\(.literal)"' "$A"); rf=${row%%$'\t'*}; rl=${row#*$'\t'}
fp=zzprov-testonly; fm=zzmodel:testonly-1b; fh=zz-testonly.invalid; fb=zzboard-testonly

out=$(tree_check "$L"); rc=$?; grep 'not checked' <<<"$out" | sed 's/^/info   /'   # F2: the real home; what it could not check is shown
[ "$rc" = 0 ] || echo "$out" | head -20
ok '[ "$rc" = 0 ]' "the lint passes on this tree with the real home (every tracked file read, every literal from data)"
ok '[ -n "$plug" ]' "the terminal backend plugin (docs/hermes-local/plugins) is there to be scanned"
ok 'jq -e "(.schema_version == 1) and all(.baseline[]?; (.phase // \"\") != \"\" and (.count | type) == \"number\") and all(.allow[]?, .own_names[]?; (.phase // \"\") != \"\")" "$A" >/dev/null' "every allow-list entry names its phase (schema_version 1)"
fresh
ok 'lint >/dev/null' "the untouched scratch copy passes"
ok 'lint --dump | grep -q "	"' "--dump prints the counts"
fresh; python3 - "$S/.stella/connections.json" "$fp" "$fm" "$fh" <<'P'
import json, sys
p, i, m, h = sys.argv[1:]; d = json.load(open(p)); e = json.loads(json.dumps(next(x for x in d["entries"] if x["kind"] == "provider" and x["locality"] != "local")))   # a remote provider: a local one must name a local host
e["id"], e["hosts"], e["models"] = i, [{"host": h, "port": 1, "purpose": "test"}], [dict(e["models"][0], id=m)]
d["entries"].append(e); json.dump(d, open(p, "w"))
P
cp "$S/.stella/connections.json" "$T/cat.json"
ok 'STELLA_ROOT=$S python3 -I -B "$S/bin/stella_data.py" check >/dev/null 2>&1' "control: the fake provider is a valid entry (stella_data.py check passes in the scratch root)"
ok 'lint >/dev/null' "a fake provider added to a scratch catalog is picked up with no code change, and passes while unused"
plant "bin/alert.sh" "$fp";  ok 'fails_on "\"$fp\""' "a planted new provider id fails"
fresh; cp "$T/cat.json" "$S/.stella/connections.json"; plant "bin/alert.sh" "$fm"; ok 'fails_on "\"$fm\""' "a planted new model id fails"
fresh; cp "$T/cat.json" "$S/.stella/connections.json"; plant "bin/alert.sh" "$fh"; ok 'fails_on "\"$fh\""' "a planted new host fails"
fresh; sed -i "s/^KANBAN_BOARD=[A-Za-z0-9_-]*/KANBAN_BOARD=$fb/" "$S/bin/kanban-board.sh"
plant "$plug" "$fb"; ok 'fails_on "\"$fb\""' "a planted board name fails (in the plugin folder, so it is scanned)"
fresh; plant "$rf" "$rl"; ok 'fails_on "\"$rl\""' "one extra use of an already-baselined literal fails"
fresh; plant "bin/alert.sh" "$slug"; ok 'fails_on "\"$slug\""' "the bare stack name used as a project slug fails"
fresh; plant "bin/alert.sh" "$own/data"; ok 'lint >/dev/null' "the stack's own data folder name is allowed in every scanned file"
fresh; echo '{}' >"$S/.stella/connections.json"; ok 'out=$(lint); [ $? = 2 ] && grep -q STL-CFG-310 <<<"$out"' "an unreadable catalog is refused with STL-CFG-310 and exit 2"
# ---- round 2 (QA W5 r1): the cases below were written before the fix and failed on 900d9b3 ----
export PATH=$T/stub:$PATH; mkdir -p "$T/stub"; printf '#!/bin/sh\nexit 1\n' >"$T/stub/hermes"; chmod +x "$T/stub/hermes"
AL=docs/hermes-local/hardcode-allow.json; out=
refused() { out=$(lint "$@"); [ $? = 2 ] && grep -q STL-CFG-310 <<<"$out"; }   # exit 2 and the catalog code
edit() { jq "$@" "$S/$AL" >"$T/x" && cp "$T/x" "$S/$AL"; }
withcat() { cp "$T/cat.json" "$S/.stella/connections.json"; }
# L1: an allow list of the wrong shape is refused, never passed
fresh; edit '.allow += [{"text": "zz-nofile", "why": "x", "phase": "p"}]';  ok 'refused' "L1: an allow row with no file is refused (exit 2, STL-CFG-310)"
fresh; edit '.own_names += [{"text": 7, "why": "x", "phase": "p"}]';       ok 'refused' "L1: an own_names text that is a number is refused"
fresh; edit '.allow = {"x": .allow[0]}';                                   ok 'refused' "L1: allow as an object instead of a list is refused"
fresh; edit '.baseline[0].count = -1';                                     ok 'refused' "L1: a negative baseline count is refused"
fresh; edit '.baseline[0].count = 1.5';                                    ok 'refused' "L1: a baseline count that is not a whole number is refused"
fresh; edit 'del(.scan)';                                                  ok 'refused' "L1: an allow list with no scan list is refused"
# L2: a source that cannot be read stops the lint, naming the source
fresh; echo '{' >"$S/docs/hermes-local/roles.json";                        ok 'refused && grep -q roles.json <<<"$out"' "L2: an unparsable role table is refused, the source is named"
fresh; rm "$S/docs/hermes-local/roles.json";                               ok 'refused' "L2: an absent role table is refused"
fresh; echo 'not a database' >"$H/.hermes/projects.db";                    ok 'refused && grep -q projects.db <<<"$out"' "L2: a projects database that is not a database is refused"
fresh; rm -f "$H/.hermes/projects.db";                                     ok 'out=$(lint); [ $? = 0 ] && grep -q "not checked" <<<"$out"' "L2: an absent projects database is allowed (a fresh home has none) with one stderr line"
fresh; chmod 000 "$S/.supervisor/limits.env";                              ok 'refused && grep -q limits.env <<<"$out"' "L2: an unreadable limits file is refused"
fresh; rm "$S/.supervisor/limits.env";                                     ok 'refused' "L2: an absent limits file is refused"
fresh; sed -i 's/^KANBAN_BOARD=\(.*\)$/KANBAN_BOARD="\1"/' "$S/bin/kanban-board.sh"; b=$(sed -n 's/^KANBAN_BOARD="\(.*\)"$/\1/p' "$S/bin/kanban-board.sh")
plant bin/alert.sh "$b";                                                   ok '[ -n "$b" ] && fails_on "\"$b\""' "L2: the board value is read when it is double-quoted"
for q in "'" '' '"'; do fresh; printf 'ALERT_TARGET=%s%s%s\n' "$q" 'discord:#zzchan' "$q" >"$S/.supervisor/limits.env"; plant bin/alert.sh '#zzchan'
  ok 'fails_on "\"#zzchan\""' "L2: the alerts target is read with quote $q (none, single, double)"; done
fresh; : >"$H/.hermes/config.yaml"
ok 'refused' "L2: a Hermes home whose model cannot be read (hermes exits 1) is refused"
fresh; : >"$H/.hermes/config.yaml"; printf '#!/bin/sh\nprintf "default: zzmodel:stub-1b\\nbase_url: http://zz-stub.invalid:1/v1\\n"\n' >"$T/stub/hermes"
plant bin/alert.sh "zzmodel:stub-1b";                                      ok 'fails_on "\"zzmodel:stub-1b\""' "L2: a Hermes home's model is read through hermes and counted"
printf '#!/bin/sh\nexit 1\n' >"$T/stub/hermes"
# L3: what is scanned is data (the allow list's scan and skip lists); a file name is read as that file
glob_name='bin/[a]lert.sh'; space_name='bin/new tool.sh'
for f in "$glob_name" "$space_name" bin/lib/x.sh bin/newtool bin/crontab.txt scripts/post-edit-check.sh docs/hermes-local/review-prompt.txt opencode.json .devcontainer/init-firewall.sh bin/kanban-board.sh; do
  fresh; withcat; mkdir -p "$S/$(dirname "$f")"; [ -e "$S/$f" ] || printf '#!/usr/bin/env bash\n' >"$S/$f"; plant "$f" "$fp"
  ok 'fails_on "\"$fp\"" && grep -qF -- "$f" <<<"$out"' "L3: a provider id planted in $f is counted, in that file"; done
fresh; withcat; printf '# %s\n' "$fp" >"$S/bin/new
tool.sh";                                                                  ok 'refused' "L3: a file name with a newline is refused, not swapped for another file"
# L4: an own name or an allow text equal to a data literal is refused
fresh; withcat; edit --arg t "$fp" '.own_names += [{"text": $t, "why": "x", "phase": "p"}]'; plant bin/alert.sh "$fp"
ok 'refused' "L4: an own_names text equal to a catalog provider id is refused"
fresh; withcat; edit --arg t "$fm" '.allow += [{"file": "bin/alert.sh", "text": $t, "why": "x", "phase": "p"}]'
ok 'refused' "L4: an allow text equal to a catalog model id is refused"
fresh; withcat; edit --arg t "x$fh" '.own_names += [{"text": $t, "why": "x", "phase": "p"}]'
ok 'refused' "L4 (was: a text that only contains a literal stays allowed): an own_names text with a literal glued to other letters is refused (RT2-07)"
# L5: the suite clears the lint's switches as it clears STELLA_ROOT
ok 'grep -Eq "unset[^#]*HARDCODE_ALLOW" "$BIN/selftests.sh" && grep -Eq "unset[^#]*HARDCODE_HOME" "$BIN/selftests.sh"' "L5: bin/selftests.sh clears HARDCODE_ALLOW and HARDCODE_HOME"
# L6: the lint's own failures carry a catalog code
fresh; plant "$rf" "$rl"; ok 'fails_on "$rl" && [ "$(grep -c "\[STL-CFG-320\]" <<<"$out")" = 1 ]' "L6: exit 1 prints STL-CFG-320 once, then the per-file lines"
fresh; ok 'out=$(lint --bogus); [ $? = 2 ] && grep -q STL-CFG-310 <<<"$out"' "L6: the usage error prints STL-CFG-310"
# L7: role names are literals except the plain words listed in the allow list
np=$(jq -r --argjson pw "$(jq '[.plain_words[].word]' "$A")" '.roles | keys[] | select(IN($pw[]) | not)' "$W/docs/hermes-local/roles.json" | head -1)
pw=$(jq -r '.plain_words[0].word' "$A")
fresh; plant bin/alert.sh "$np"; ok '[ -n "$np" ] && fails_on "\"$np\""' "L7: a role name that is not a plain word fails when planted"
fresh; plant bin/alert.sh "$pw"; ok '[ -n "$pw" ] && lint >/dev/null' "L7: a plain word from the allow list passes when planted"
# ---- round 3 (QA W5 r2): the cases below were written before the fix ----
# F1: a scratch root holds what the lint lists, never an owner file or the apply tool's state, and a failed copy fails
fresh; echo "info   one scratch root: $(find "$S" -type f | wc -l) files, $(du -sb "$S" | cut -f1) bytes (the tree: $(cd "$W" && git ls-files 2>/dev/null | wc -l) tracked files)"
ow=$(jq -r '.owner_settings[0]' "$W/docs/hermes-local/roles.json"); idx=$(jq -r '.data_index' "$W/docs/hermes-local/roles.json")
bk=$(jq -r '.backup_dir' "$W/$idx"); ap=$(jq -r '.applied_state' "$W/$idx"); ev=$(jq -r '.event_log' "$W/$idx")
SRC=$T/src; rm -rf "$SRC"; mkdir -p "$SRC"; cp_listed "$W" "$SRC"   # a source tree with no git: the lint walks it
for f in "$ow" "$bk/zz-backup.json" "$ap" "$ev"; do mkdir -p "$SRC/$(dirname "$f")"; printf 'FAKE %s\n' "$fp" >"$SRC/$f"; done
lst=$(STELLA_ROOT=$SRC HARDCODE_ALLOW= "$L" --list)
ok '[ -n "$lst" ] && ! grep -qF -e "$ow" -e "$bk" -e "$ap" -e "$ev" <<<"$lst"' "F1: the lint lists no owner setting and none of the apply tool's state, though the scan list covers them"
rm -rf "$T/dst"; mkdir "$T/dst"; cp_listed "$SRC" "$T/dst"
ok '[ ! -e "$T/dst/$ow" ] && [ ! -e "$T/dst/$bk" ] && [ ! -e "$T/dst/$ap" ] && [ ! -e "$T/dst/$ev" ] && [ -f "$T/dst/bin/hardcode-lint.sh" ]' "F1: a scratch root made from a tree with a fake owner file and a fake backup holds neither"
fresh; for f in "$ow" "$bk/zz-backup.json"; do mkdir -p "$S/$(dirname "$f")"; printf '%s\n' "$fp" >"$S/$f"; done
ok 'lint >/dev/null' "F1: a literal in an owner file or a backup file is never read, so never counted"
mkdir -p "$T/badtar"; printf '#!/bin/sh\ncase " $* " in *" -xf "*) exit 1;; esac\nexec /usr/bin/tar "$@"\n' >"$T/badtar/tar"; chmod +x "$T/badtar/tar"
ok '! (PATH=$T/badtar:$PATH; fresh) >/dev/null 2>&1' "F1: a copy step that fails makes the selftest fail (the extract fails)"
printf '#!/bin/sh\ncase " $* " in *" -cf "*) exit 1;; esac\nexec /usr/bin/tar "$@"\n' >"$T/badtar/tar"
ok '! (PATH=$T/badtar:$PATH; fresh) >/dev/null 2>&1' "F1: a copy step that fails makes the selftest fail (the archive fails)"
ok '! (L=/nonexistent; fresh) >/dev/null 2>&1' "F1: a list that cannot be made makes the selftest fail"
# F2: the case that checks this tree reads the machine's home: a project slug planted in a script and in a home's projects database fails it
fresh; H2=$T/home2; mkdir -p "$H2/.hermes"
python3 -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1] + "/.hermes/projects.db"); c.execute("create table projects (slug text)"); c.execute("insert into projects values (?)", (sys.argv[2],)); c.commit()' "$H2" zzproj-testonly
plant bin/alert.sh zzproj-testonly
ok 'out=$(HOME=$H2 tree_check "$S/bin/hardcode-lint.sh"); [ $? = 1 ] && grep -qF "\"zzproj-testonly\"" <<<"$out"' "F2: the tree check fails on a slug planted in a script and in HOME's projects database"
ok 'out=$(HOME=$H tree_check "$S/bin/hardcode-lint.sh"); [ $? = 0 ]' "F2: the same tree passes with a home that does not hold that slug"
ok 'grep -q "tree_check \"\$L\"" "$0"' "F2: case 1 runs this tree's lint through tree_check with no home switch"
# F3: every tracked file is scanned, minus the skip rows
fresh; withcat
mkdir -p "$S/lib" "$S/deep/er" "$S/bin/lib" "$S/bin/__pycache__"; printf '# x\n' >"$S/lib/zz-net.sh"; printf '# x\n' >"$S/.zzrc"; printf 'x\n' >"$S/deep/er/x.txt"
printf '# x\n' >"$S/bin/zz-selftest.sh"; printf '# x\n' >"$S/bin/lib/zz-selftest.sh"; printf '# x\n' >"$S/bin/alert-selftest.sh"; printf 'x\n' >"$S/bin/__pycache__/zz.cpython-312.pyc"
for f in lib/zz-net.sh .zzrc deep/er/x.txt bin/zz-selftest.sh bin/lib/zz-selftest.sh bin/__pycache__/zz.cpython-312.pyc; do plant "$f" "$fp"
  ok 'fails_on "\"$fp\"" && grep -qF -- "$f" <<<"$out"' "F3: a provider id in $f (new folder, dot file, subfolder, a helper named like a selftest, a compiled file) is counted with no data change"; done
fresh; withcat; printf '# x\n' >"$S/bin/alert-selftest.sh"; plant bin/alert-selftest.sh "$fp"
ok 'lint >/dev/null' "F3: a file the suite runner lists as a selftest (bin/alert-selftest.sh) is skipped by its row"
fresh; withcat; git -C "$S" init -q && git -C "$S" add -A 2>/dev/null; printf '# %s\n' "$fp" >"$S/bin/zz-untracked.sh"; plant bin/alert.sh "$fp"
ok 'out=$(lint --dump); grep -q "^bin/alert.sh	" <<<"$out" && ! grep -q "zz-untracked" <<<"$out"' "F3: with git the tracked files are scanned, not what git does not track"
git -C "$S" add bin/zz-untracked.sh 2>/dev/null; ok 'lint --dump | grep -q "^bin/zz-untracked.sh	"' "F3: a file git tracks is scanned"
fresh; ln -s /etc/hostname "$S/bin/zz-link"; ok 'refused' "F6/RT2-09: a scanned file that resolves outside the root is refused"
fresh; edit '.scan = ["../**/*"]';       ok 'refused' "F6/RT2-09: a scan pattern with a .. segment is refused"
fresh; edit '.scan = ["/etc/*"]';        ok 'refused' "F6/RT2-09: an absolute scan pattern is refused"
fresh; edit '.skip += [{"file": "*", "why": "x"}]'; ok 'refused' "F3: a skip row that is only wildcards is refused"
# F5/F6 cheap ones
fresh; ok '! lint --dump | grep -q "^bin/kanban-board.sh	"' "F5: the line the board value is read from is not counted (VER2-06)"
ok 'jq -e "all(.allow[]; .file != \"bin/kanban-board.sh\")" "$A" >/dev/null' "F5: the allow list has no row for the board value line"
ok 'jq -e ".about | test(\"scan\") and test(\"skip\") and test(\"plain_words\") and test(\"bin/hardcode-lint.sh\")" "$A" >/dev/null' "F5: the about text describes scan, skip, plain_words and names the reader (VER2-07)"
ok '! jq -r ".baseline[].phase" "$A" | grep -q "red-team\|red team" || ! jq -r ".baseline[] | select(.phase | test(\"red.team\"; \"i\")) | .phase" "$A" | grep -vq "comment"' "F5: a baseline label that mentions the red team says the uses are comments citing a finding (VER2-07)"
fresh; withcat; plant bin/alert.sh "$fp"; printf '#x\n' >"$S/bin/zz-unreadable.sh"; chmod 000 "$S/bin/zz-unreadable.sh"
ok 'refused && ! grep -q "x1 (allowed" <<<"$out"' "F6/RT2-10: a refusal after a hit prints no partial count line"
fresh; ok 'out=$(env -u HOME -u HARDCODE_HOME STELLA_ROOT=$S "$S/bin/hardcode-lint.sh" 2>&1); [ $? = 2 ] && grep -q STL-CFG-310 <<<"$out" && ! grep -q "unbound" <<<"$out"' "F5: with neither HOME nor HARDCODE_HOME the lint exits 2 with the code (VER2-09)"
# own_names: a whole word-like token of 4 or more characters, removed at word borders; a repeated baseline row is refused
for t in ' ' 'o' '--model opus' 'model opus'; do fresh; withcat; printf '\nclaude -p --model opus --output-format json\n' >>"$S/bin/alert.sh"; edit --arg t "$t" '.own_names += [{"text": $t, "why": "x", "phase": "p"}]'
  ok 'refused' "F6/RT2-07: an own_names text '$t' is refused (not one word-like token of 4 or more characters)"; done
fresh; withcat; printf '\n%s\n' "$fp-x" >>"$S/bin/alert.sh"; edit '.own_names += [{"text": "zzprov-testonly-x", "why": "x", "phase": "p"}]'
ok 'lint >/dev/null' "F6/RT2-07: an own_names token removes a text at word borders only (a name that is no literal is removed)"
fresh; withcat; plant bin/alert.sh "$fp"; edit --arg t "q$fp" '.own_names += [{"text": $t, "why": "x", "phase": "p"}]'; plant bin/alert.sh "q$fp"
ok 'refused' "F6/RT2-07: an own_names text that holds a literal glued to other letters is refused"
fresh; edit '.baseline += [.baseline[0]]'; ok 'refused' "F6/RT2-08: a baseline row repeated (same file and literal) is refused"
# F5/F6: the CLI's model answer is read by model_watch.py's rule; no model line is a "not checked" line, never silence
rxl='^\s*([A-Za-z_]+):\s*(\S.*?)\s*$'
ok 'grep -qF -- "$rxl" "$W/bin/model_watch.py" && grep -q "from model_watch import model_answer" "$L" && ! grep -qF -- "$rxl" "$L"' "F6/RT2-05/V5 (was: the same regex in both): the lint reads the CLI answer with bin/model_watch.py's own reader (model_answer), not a copy of its regex"
mdl=zzlocal-testonly:9b; mh=zz-rt2.invalid
modelcase() {  # modelcase <answer text>: the stub hermes prints it (exit 0)
  fresh; withcat; : >"$H/.hermes/config.yaml"; plant bin/alert.sh "model $mdl on $mh"; printf '#!/bin/sh\ncat "%s/model.out"\n' "$T" >"$T/stub/hermes"; printf '%s' "$1" >"$T/model.out"; }
modelcase $'default: '"$mdl"$'\nprovider: custom\nbase_url: http://'"$mh"$':1/v1\n'; ok 'fails_on "\"$mdl\"" && grep -qF "\"$mh\"" <<<"$out"' "F6/RT2-05: control: column-0 lines: the model and the host are counted"
modelcase $'  default: '"$mdl"$'\n  base_url: http://'"$mh"$':1/v1\n'; ok 'fails_on "\"$mdl\"" && grep -qF "\"$mh\"" <<<"$out"' "F6/RT2-05: indented lines (model_watch.py reads them) are counted"
modelcase ''; ok 'out=$(lint); [ $? = 0 ] && grep -q "not checked: model" <<<"$out"' "F5/VER2-08: a home whose answer has no model line prints its not-checked line"
modelcase $'default: '"$mdl"$'\nbase_url: http://[::1]:1/v1\n'; plant bin/alert.sh "::1"; ok 'fails_on "\"::1\""' "F6/RT2-05: a host is taken whole (an address in brackets is not the literal [)"
printf '#!/bin/sh\nexit 1\n' >"$T/stub/hermes"
fresh; mkdir -p "$H/.hermes/profiles/zzp"; ok 'out=$(lint); [ $? = 0 ] && grep -q "not checked: model and host of the Hermes profile .hermes/profiles/zzp" <<<"$out"' "F5/VER2-08: a profile folder with no config prints its not-checked line"
fresh; mkdir -p "$H/.hermes/profiles/zzp"; chmod 000 "$H/.hermes/profiles/zzp"; ok 'refused && grep -q "zzp" <<<"$out"' "F5/VER2-08: a profile folder that cannot be read is refused"; chmod 755 "$H/.hermes/profiles/zzp"
# F7: a source the data tool refuses makes the lint exit 2, naming what the tool names
fresh; withcat; jq '.entries[-1].locality = "local"' "$S/.stella/connections.json" >"$T/x" && cp "$T/x" "$S/.stella/connections.json"
ok 'refused && grep -q "connections" <<<"$out"' "F7: a catalog the data tool refuses (a local provider on a host not in the local list) is refused, the source is named"
# ---- round 4 (QA W5 r3): the cases below were written before the fix ----
# V1: an owner or state path is never listed, read or copied, judged by what an entry resolves to (fake owner file, scratch root only)
gitroot() {  # a git scratch root, and an untracked fake owner file in it that holds a data literal
  fresh; withcat; git -C "$S" init -q && git -C "$S" add -A; mkdir -p "$S/$(dirname "$ow")"; printf 'FAKE=%s\n' "$fp" >"$S/$ow"; }
track() { git -C "$S" add -- "$@"; }
listed() { STELLA_ROOT=$S HARDCODE_ALLOW= "$S/bin/hardcode-lint.sh" --list 2>&1; }
copied() { rm -rf "$T/dst"; mkdir "$T/dst"; cp_listed "$S" "$T/dst"; }
gone() { local f; out=$(listed); for f; do ! grep -qxF -- "$f" <<<"$out" && [ ! -e "$T/dst/$f" ] && [ ! -L "$T/dst/$f" ] || return 1; done; [ ! -e "$T/dst/$ow" ]; }
gitroot; ln -s "$S/$ow" "$S/bin/zz-owner"; track bin/zz-owner
ok 'lint >/dev/null && copied && gone bin/zz-owner' "V1: a tracked link to the owner file under a scanned name: not listed, not read (its data literal is not counted), not copied"
gitroot; ln -s "$S/$(dirname "$ow")" "$S/bin/zz-cfg"; ln -s "$S/bin/zz-cfg/$(basename "$ow")" "$S/bin/zz-via"; track bin/zz-cfg bin/zz-via
ok 'lint >/dev/null && copied && gone bin/zz-cfg bin/zz-via' "V1: the same through a linked parent folder (and the folder link itself, which holds the owner file)"
gitroot; ln "$S/$ow" "$S/bin/zz-hard"; track bin/zz-hard
ok 'lint >/dev/null && copied && gone bin/zz-hard' "V1: a hard link to the owner file: not listed, not read, not copied"
gitroot; printf '#x\n' >"$S/-h"; printf '#x\n' >"$S/--dereference"; ln -s alert.sh "$S/bin/zz-ln"; ln -s "$S/$ow" "$S/bin/zz-owner"; track -h --dereference bin/zz-ln bin/zz-owner
ok 'copied && [ -f "$T/dst/-h" ] && [ -f "$T/dst/--dereference" ] && [ -L "$T/dst/bin/zz-ln" ] && gone bin/zz-owner' "V1: the copy takes every list line as a file name, never as an option (files named -h and --dereference are copied, a link stays a link)"
fresh; jq '.owner_settings = []' "$S/docs/hermes-local/roles.json" >"$T/x" && cp "$T/x" "$S/docs/hermes-local/roles.json"
ok 'refused && grep -q owner_settings <<<"$out" && out=$(listed); [ $? = 2 ]' "V1: owner_settings [] is refused as the role tool refuses it (check and list)"
fresh; withcat; jq '.event_log = "docs/zz-state.log"' "$S/$idx" >"$T/x" && cp "$T/x" "$S/$idx"; printf '%s\n' "$fp" >"$S/docs/zz-state.log"
ok 'lint >/dev/null && ! listed | grep -qxF docs/zz-state.log' "V1: a state path the index names is filtered with no code change (not listed, not read)"
fresh; ln -s zz-loop "$S/bin/zz-loop"; ok 'lint >/dev/null && ! listed | grep -qxF bin/zz-loop' "V1: a link that cannot be resolved (a loop) is dropped before anything opens it"
fresh; ln -s zz-none "$S/bin/zz-dang"; ok 'refused && grep -q zz-dang <<<"$out"' "V1: a dangling link is refused (exit 2), naming it"
fresh; withcat; plant bin/alert.sh "$fp"; ln -s alert.sh "$S/bin/zz-ln"
ok 'out=$(lint --dump); [ "$(grep -c "	$fp	" <<<"$out")" = 1 ] && grep -qx "bin/alert.sh	$fp	1" <<<"$out"' "V1 control: an ordinary link to a scanned file is still scanned, once (under the file's own name)"
fakeowner() { mkdir -p "$S/$(dirname "$ow")"; printf 'ALERT_TARGET=discord:#zzown\nKANBAN_BOARD=zzown\n' >"$S/$ow"; }
fresh; fakeowner; rm "$S/.supervisor/limits.env"; ln -s "$S/$ow" "$S/.supervisor/limits.env"
ok 'refused && grep -q "owner or state path" <<<"$out" && grep -q limits.env <<<"$out"' "V1 sibling: a file the shell reads by name (the limits file) that is a link to the owner file is refused before the shell reads it"
fresh; fakeowner; printf '# x\n' >"$S/bin/zz-selftest.sh"; edit --arg o "$ow" '(.skip[] | select(.run_by) | .run_by) = $o'
ok 'refused && grep -q "runner is not a file of the root the lint may read" <<<"$out"' "V1 sibling: a skip row whose runner is the owner file is refused, the file is not read"
# V2: an input that is there but cannot be read is exit 2 with STL-CFG-310 and its name, never a pass
cat_path=$(jq -r '.files[] | select(.id == "connections") | .path' "$W/$idx")
unread() {  # unread <path> <name the message must hold>: mode 000, then refused naming it
  chmod 000 "$1"; refused && grep -q "cannot be read" <<<"$out" && grep -qF -- "$2" <<<"$out"; local r=$?; chmod 755 "$1"; return $r; }
fresh; ok 'unread "$S/$AL" "$AL"' "V2: the allow file (and so its watch list) present but unreadable"
fresh; ok 'unread "$S/docs/hermes-local/roles.json" roles.json' "V2: the role table present but unreadable"
fresh; ok 'unread "$S/$idx" "$idx"' "V2: the data index present but unreadable"
fresh; ok 'unread "$S/$cat_path" connections' "V2: the connections catalog present but unreadable"
fresh; ok 'unread "$H" "home folder"' "V2: the home folder present but unreadable"
fresh; ok 'unread "$H/.hermes" ".hermes"' "V2: the Hermes root home present but unreadable"
fresh; ok 'unread "$H/.hermes/projects.db" projects.db' "V2: the projects database present but unreadable"
fresh; mkdir -p "$H/.hermes/profiles/zzp"; printf 'model:\n  default: zzm-x\n' >"$H/.hermes/profiles/zzp/config.yaml"
printf '#!/bin/sh\nprintf "default: zzmodel:stub-1b\\n"\n' >"$T/stub/hermes"
ok 'unread "$H/.hermes/profiles/zzp/config.yaml" "zzp/config.yaml"' "V2: a profile config.yaml present but unreadable, with a hermes that exits 0 and prints a default: refused, never that default"
printf '#!/bin/sh\nexit 1\n' >"$T/stub/hermes"
fresh; withcat; mkdir "$S/zzdir"; printf '%s\n' "$fp" >"$S/zzdir/x.sh"; ok 'unread "$S/zzdir" zzdir' "V2: a folder of a tree without git present but unreadable (the walk does not skip it)"
fresh; withcat; git -C "$S" init -q && git -C "$S" add -A; mkdir "$S/zzdir"; printf '%s\n' "$fp" >"$S/zzdir/x.sh"; track zzdir/x.sh
ok 'unread "$S/zzdir" zzdir' "V2: a folder that holds a tracked file present but unreadable"
# V3: run_by means the runner's list: a selftest stem the runner does not run is scanned, even when its word is in the runner's text
for f in bin/hermes-selftest.sh bin/grep-selftest.sh; do fresh; withcat; printf '# x\n' >"$S/$f"; plant "$f" "$fp"
  ok 'fails_on "\"$fp\"" && grep -qF -- "$f" <<<"$out"' "V3: a provider id in $f (its stem is a word of the runner, not in its list) is counted"; done
# V6: the labels and the about text say what is true
ok 'jq -r ".baseline[] | select(.phase | test(\"build-team preset\")) | .file" "$A" | sort -u | while read -r f; do grep -q "build-team preset" "$W/$f" || exit 1; done' "V6: a baseline row that says its file is generated from the build-team preset names a file that says so"
ok 'jq -e ".about | test(\"joined\") and test(\"for <name> in\")" "$A" >/dev/null' "V6: the about text states the joined-literal rule of own_names and that run_by reads the runner's list"
# ---- W5 r5: written before the fix ----
# VER4-01: the allow list is judged against the owner and state paths before anything opens it (a FIFO owner file with a writer that marks an open)
fresh; withcat; git -C "$S" init -q; rm "$S/$AL"; ln -s "$(realpath -m --relative-to="$(dirname "$S/$AL")" "$S/$ow")" "$S/$AL"; git -C "$S" add -A
mkdir -p "$S/$(dirname "$ow")"; rm -f "$S/$ow" "$T/opened"; mkfifo "$S/$ow"; ( exec 3>"$S/$ow"; touch "$T/opened" ) & wp=$!
ok 'out=$(lint --list); [ $? = 2 ] && grep -q "is, or points at, an owner or state path" <<<"$out" && [ ! -e "$T/opened" ]' "VER4-01: an allow list that is a tracked link to the owner file is refused before it is opened (exit 2, no open)"
kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; rm -f "$S/$ow"
# VER4-03: run_by keeps only the words of the runner's lists that are selftest names; a stem that is another word is scanned
fresh; withcat; f='bin/"$@"-selftest.sh'; printf '# x\n' >"$S/$f"; plant "$f" "$fp"
ok 'fails_on "\"$fp\"" && grep -qF -- "$f" <<<"$out"' "VER4-03: a provider id in $f (its stem is a word of a runner's for line, not a selftest name) is counted"
# W5 r6 (VER5-06): the root's own allow list as a tracked link to outside the root is refused in every mode, --list too
gitroot; cp "$S/$AL" "$T/al-out.json"; rm -f "$S/$AL"; ln -s "$T/al-out.json" "$S/$AL"; track "$AL"
ok 'refused --list && refused --check' "Q7: the default allow list linked outside the root is refused by --list and --check (exit 2, the code)"
# W5 (D8): one list, one owner. A list kept in a second data file fails; a list of plain ids is a reference and passes.
V=.stella/versions.json; C=.stella/capabilities.json
setkey() { jq --argjson v "$1" '.zzdup = $v' "$S/$V" >"$T/x" && cp "$T/x" "$S/$V"; }   # setkey <json>: a planted list in the second data file
dup_ids() {  # dup_ids <kind>: two ids the owner of that kind holds, as JSON
  case $1 in
    models) jq -c '[.entries[].models[]?.id][:2]' "$S/.stella/connections.json";;
    providers) jq -c '[.entries[].id][:2]' "$S/.stella/connections.json";;
    hosts) jq -c '[.entries[].hosts[]?.host] | unique | .[:2]' "$S/.stella/connections.json";;
    roles) jq -c '.roles | keys | .[:2]' "$S/docs/hermes-local/roles.json";;
  esac; }
dups_fail() { out=$(lint); [ $? = 1 ] && grep -q "STL-CFG-320" <<<"$out" && grep -qF -- "$V: keeps the $1 list" <<<"$out" && [ "$(grep -c "$V: " <<<"$out")" = 1 ]; }
for k in $(jq -r '.lists[] | select(.owner != null) | .kind' "$A"); do
  fresh; ids=$(dup_ids "$k"); ok '[ "$(jq length <<<"$ids")" = 2 ]' "D8: the scratch data holds two $k ids to plant"
  setkey "$(jq -c '[.[] | {id: ., host: ., name: .}]' <<<"$ids")"
  ok 'dups_fail "$k"' "D8: a $k list kept as objects in a second data file fails (STL-CFG-320, one line for the file)"
  fresh; setkey "$(jq -c 'map({(.): {}}) | add' <<<"$ids")"
  ok 'dups_fail "$k"' "D8: a $k list kept as a map of objects in a second data file fails"
  fresh; setkey "$ids"
  ok 'lint >/dev/null' "D8: the $k ids as plain strings (a reference) pass"
  fresh; setkey "$(jq -c '[.[0] | {id: ., host: .}]' <<<"$ids")"
  ok 'lint >/dev/null' "D8: one $k id as an object is no list kept twice and passes"
done
for k in $(jq -r '.lists[] | select(.owner == null) | .kind' "$A"); do
  fresh; jq --arg k "$k" '.[$k] = [{"id": "zza"}]' "$S/$V" >"$T/x" && cp "$T/x" "$S/$V"
  ok 'lint >/dev/null' "D8: a $k list in one data file passes (no owner yet, defined once)"
  jq --arg k "$k" '.[$k] = {"zzb": {}}' "$S/$C" >"$T/x" && cp "$T/x" "$S/$C"
  ok 'out=$(lint); [ $? = 1 ] && grep -q "STL-CFG-320" <<<"$out" && grep -qF -- "$V: keeps a $k list" <<<"$out" && grep -qF -- "$C: keeps a $k list" <<<"$out"' "D8: a $k list in two data files fails, one line per file"
done
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
