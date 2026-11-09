#!/usr/bin/env bash
# Hard-code lint (K12, standing rule 1): no literal profile, model, provider host, board, project or channel name in
# scripts, hooks, SOULs or the board text outside the data files. The literals come from data, never from this file:
# profile names (roles.json, the root profile "default" aside: Hermes's own word), the board (bin/kanban-board.sh), the
# board's project slugs (projects.db), each profile's model and model-server host (`hermes config get model` in its home)
# and the alerts channel (.supervisor/limits.env ALERT_TARGET), plus hardcode-allow.json "watch" (names no data file holds
# yet: the other channels, Claude model names). docs/stella-recover.ps1 is scanned too. hardcode-allow.json lists what may stay:
# "allow" (exact text, e.g. a Hermes API word) and "baseline" (per file and literal, at most `count` whole-word uses, each
# with the phase that removes it). A new literal, or one more use than the baseline, fails. LINT_DUMP=1 prints the counts.
set -u
W=/workspace; A=${HARDCODE_ALLOW:-$W/docs/hermes-local/hardcode-allow.json}; fails=0
watch=$(jq -r '.watch[]?' "$A")
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
lits=$( {
  jq -r '.profiles | keys[] | select(. != "default")' "$W/docs/hermes-local/roles.json"
  sed -n 's/^KANBAN_BOARD=\([A-Za-z0-9_-]*\).*/\1/p' "$W/bin/kanban-board.sh"
  python3 -c 'import sqlite3, os, sys; [print(r[0]) for r in sqlite3.connect("file:" + os.path.expanduser("~/.hermes/projects.db") + "?mode=ro", uri=True).execute("select slug from projects")]' 2>/dev/null
  for h in ~/.hermes ~/.hermes/profiles/*/; do
    HERMES_HOME=${h%/} timeout 20 hermes config get model 2>/dev/null | sed -n 's/^default: *//p; s#^base_url: *[a-z]*://\([^:/]*\).*#\1#p'
  done
  sed -n 's/^ALERT_TARGET="[a-z]*:\(#[A-Za-z0-9_-]*\)".*/\1/p' "$W/.supervisor/limits.env"
  jq -r '.watch[]?' "$A"   # B2V-05: names no data file holds yet (other channels, Claude model names)
} | tr -d "\"'" | sort -u | grep -v '^$')
files=$(cd "$W" && { ls bin/*.sh bin/*.py | grep -v -e '-selftest\.sh$' -e '^bin/selftests\.sh$' -e '^bin/kanban-board\.sh$'
  find docs/hermes-local/hooks -type f \( -name '*.py' -o -name '*.sh' \); ls docs/hermes-local/soul/*.md docs/hermes-local/board.md docs/stella-recover.ps1; } | sort)
counts=$(cd "$W" && for f in $files; do
  text=$(python3 -c 'import json, sys
t = open(sys.argv[1]).read()
for a in json.load(open(sys.argv[2])).get("allow", []):
    if a["file"] == sys.argv[1]:
        t = t.replace(a["text"], "")
print(t)' "$f" "$A") || { echo "ERROR $f"; continue; }
  while IFS= read -r l; do
    ci=; grep -qxF -- "$l" <<<"$watch" && ci=i   # B2V-13: a watch name counts in any case (Sonnet, OPUS); data literals stay exact
    n=$(grep -ow${ci}F -- "$l" <<<"$text" | wc -l); [ "$n" -gt 0 ] && printf '%s\t%s\t%s\n' "$f" "$l" "$n"
  done <<<"$lits"
done)
[ "${LINT_DUMP:-}" = 1 ] && { printf '%s\n' "$counts"; exit 0; }
ok '[ -n "$lits" ] && ! grep -q ^ERROR <<<"$counts"' "the literals come from data ($(wc -l <<<"$lits") found) and every scanned file was read"
ok 'jq -e "(.schema_version == 1) and all(.baseline[]?; (.phase // \"\") != \"\" and (.count | type) == \"number\") and all(.allow[]?; (.phase // \"\") != \"\")" "$A" >/dev/null' "every allow-list entry names its phase (schema_version 1)"
over=$(while IFS=$'\t' read -r f l n; do [ -n "$f" ] || continue
  max=$(jq -r --arg f "$f" --arg l "$l" '[.baseline[]? | select(.file == $f and .literal == $l) | .count] | add // 0' "$A")
  [ "$n" -le "$max" ] || echo "$f: \"$l\" x$n (allowed $max)"; done <<<"$counts")
ok '[ -z "$over" ]' "no new hard-coded name in scripts, hooks, SOULs or the board text${over:+:
$(sed 's/^/     /' <<<"$over")}"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
