#!/usr/bin/env bash
# Self-test for bin/hardcode-lint.sh (K12, E8). The lint itself, and its header, say where the literals come from.
# Case 1-3 run it on this tree; every planted case runs on a scratch copy of the scanned files (a temp root with its own
# .stella/, a scratch HARDCODE_HOME), never the live tree. The planted names are invented here.
set -u
BIN=$(dirname "$(readlink -f "$0")"); W=$(dirname "$BIN"); L=$BIN/hardcode-lint.sh; A=${HARDCODE_ALLOW:-$W/docs/hermes-local/hardcode-allow.json}; fails=0
T=$(mktemp -d -t hardcode-lint-selftest.XXXXXX); trap 'rm -rf "$T"' EXIT
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
S=$T/root; H=$T/home
fresh() {  # a clean scratch root with the scanned files, and a scratch home whose projects.db holds one slug
  rm -rf "$S" "$H"; mkdir -p "$S/docs" "$S/.supervisor" "$H/.hermes"
  cp -r "$W/bin" "$S/bin"; cp -r "$W/docs/hermes-local" "$S/docs/hermes-local"; cp "$W/docs/stella-recover.ps1" "$S/docs/"; cp -r "$W/.stella" "$S/.stella"
  cp "$W/.supervisor/limits.env" "$S/.supervisor/"; cp "$A" "$S/docs/hermes-local/hardcode-allow.json"
  python3 -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1] + "/.hermes/projects.db"); c.execute("create table projects (slug text)"); c.execute("insert into projects values (?)", (sys.argv[2],)); c.commit()' "$H" "$slug"
}
lint() { STELLA_ROOT=$S HARDCODE_ALLOW= HARDCODE_HOME=$H "$S/bin/hardcode-lint.sh" "$@" 2>&1; }   # empty HARDCODE_ALLOW: the copy's own list
plant() { printf '\n# %s\n' "$2" >>"$S/$1"; }   # one use of a literal in a scanned file
fails_on() { out=$(lint) ; [ $? = 1 ] && grep -qF -- "$1" <<<"$out"; }   # exit 1 and a line naming the literal
slug=$(jq -r '.own_names[0].text | ltrimstr(".")' "$A")   # the stack's own name doubles as a retired project slug in the board data
own=$(jq -r '.own_names[0].text' "$A")
plug=$(cd "$W" && ls docs/hermes-local/plugins/*/*.py docs/hermes-local/plugins/*.py 2>/dev/null | head -1)
row=$(jq -r '.baseline[0] | "\(.file)\t\(.literal)"' "$A"); rf=${row%%$'\t'*}; rl=${row#*$'\t'}
fp=zzprov-testonly; fm=zzmodel:testonly-1b; fh=zz-testonly.invalid; fb=zzboard-testonly

ok '"$L" --check >/dev/null 2>&1' "the lint passes on this tree (every scanned file read, every literal from data)"
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
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
