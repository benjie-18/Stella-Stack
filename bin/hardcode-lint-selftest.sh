#!/usr/bin/env bash
# Self-test for bin/hardcode-lint.sh (K12, E8). The lint itself, and its header, say where the literals come from.
# Case 1-3 run it on this tree; every planted case runs on a scratch copy of the scanned files (a temp root with its own
# .stella/, a scratch HARDCODE_HOME), never the live tree. The planted names are invented here.
set -u
BIN=$(dirname "$(readlink -f "$0")"); W=$(dirname "$BIN"); L=$BIN/hardcode-lint.sh; A=$W/docs/hermes-local/hardcode-allow.json; fails=0   # not HARDCODE_ALLOW: case 1 checks this tree with this list (L5)
T=$(mktemp -d -t hardcode-lint-selftest.XXXXXX); trap 'rm -rf "$T"' EXIT
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
S=$T/root; H=$T/home
mkhome() {  # a scratch home whose projects.db holds one slug
  rm -rf "$H"; mkdir -p "$H/.hermes"
  python3 -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1] + "/.hermes/projects.db"); c.execute("create table projects (slug text)"); c.execute("insert into projects values (?)", (sys.argv[2],)); c.commit()' "$H" "$slug"
}
fresh() {  # a clean scratch root (the whole tree but .git and local state), and a fresh scratch home
  rm -rf "$S"; mkdir -p "$S"; mkhome
  tar -C "$W" --exclude=./.git --exclude=./node_modules --exclude=./docs/spec --exclude=./.scratch -cf - . | tar -C "$S" -xf -
}
lint() { STELLA_ROOT=$S HARDCODE_ALLOW= HARDCODE_HOME=$H "$S/bin/hardcode-lint.sh" "$@" 2>&1; }   # empty HARDCODE_ALLOW: the copy's own list
plant() { printf '\n# %s\n' "$2" >>"$S/$1"; }   # one use of a literal in a scanned file
fails_on() { out=$(lint) ; [ $? = 1 ] && grep -qF -- "$1" <<<"$out"; }   # exit 1 and a line naming the literal
slug=$(jq -r '.own_names[0].text | ltrimstr(".")' "$A")   # the stack's own name doubles as a retired project slug in the board data
own=$(jq -r '.own_names[0].text' "$A")
plug=$(cd "$W" && ls docs/hermes-local/plugins/*/*.py docs/hermes-local/plugins/*.py 2>/dev/null | head -1)
row=$(jq -r '.baseline[0] | "\(.file)\t\(.literal)"' "$A"); rf=${row%%$'\t'*}; rl=${row#*$'\t'}
fp=zzprov-testonly; fm=zzmodel:testonly-1b; fh=zz-testonly.invalid; fb=zzboard-testonly

mkhome; ok 'env -u HARDCODE_ALLOW -u STELLA_ROOT HARDCODE_HOME=$H "$L" --check >/dev/null 2>&1' "the lint passes on this tree (every scanned file read, every literal from data)"
ok '[ -n "$plug" ]' "the terminal backend plugin (docs/hermes-local/plugins) is there to be scanned"
ok 'jq -e "(.schema_version == 1) and all(.baseline[]?; (.phase // \"\") != \"\" and (.count | type) == \"number\") and all(.allow[]?, .own_names[]?; (.phase // \"\") != \"\")" "$A" >/dev/null' "every allow-list entry names its phase (schema_version 1)"
fresh
ok 'lint >/dev/null' "the untouched scratch copy passes"
ok 'lint --dump | grep -q "	"' "--dump prints the counts"
fresh; python3 - "$S/.stella/connections.json" "$fp" "$fm" "$fh" <<'P'
import json, sys
p, i, m, h = sys.argv[1:]; d = json.load(open(p)); e = json.loads(json.dumps(d["entries"][0]))
e["id"], e["hosts"], e["models"] = i, [{"host": h, "port": 1, "purpose": "test"}], [dict(e["models"][0], id=m)]
d["entries"].append(e); json.dump(d, open(p, "w"))
P
cp "$S/.stella/connections.json" "$T/cat.json"
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
ok 'lint >/dev/null' "L4: a text that only contains a literal stays allowed"
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
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
