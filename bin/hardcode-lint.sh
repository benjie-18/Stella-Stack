#!/usr/bin/env bash
# Hard-code lint (K12, standing rule 1; Body B7): no literal profile, model, provider, host, board, project or channel
# name in scripts, hooks, SOULs or the board text outside the data files. The literals come from data, never from this file:
# profile names (docs/hermes-local/roles.json, the root profile "default" aside: Hermes's own word), the board
# (bin/kanban-board.sh), the board's project slugs (projects.db), each profile's model and model-server host (`hermes config
# get model`), the alerts channel (.supervisor/limits.env ALERT_TARGET), the connections catalog (entry ids, model ids and
# host names, read through bin/stella_data.py) and hardcode-allow.json "watch" (names no data file holds yet). The allow
# list lists what may stay: "allow" (exact text in one file), "own_names" (exact text that is the stack's own name, removed
# in every file) and "baseline" (per file and literal, at most `count` whole-word uses, each with the phase that removes it).
# A short or common literal (an id that is also an English word) is counted like any other, never dropped.
# usage: hardcode-lint.sh [--check | --dump]   --check (default): exit 0, or 1 with one line per file and literal over its
#        baseline; --dump: "file<TAB>literal<TAB>count" for every use. Exit 2: an input cannot be read (STL-CFG-310).
# Inputs: STELLA_ROOT (the tree scanned, default: parent of bin/), HARDCODE_ALLOW (default <root>/docs/hermes-local/
# hardcode-allow.json), HARDCODE_HOME (default $HOME: where ~/.hermes/projects.db and the Hermes homes live).
set -u
jq() { env -u HOME jq "$@"; }   # jq always loads ~/.jq; every script under bin/ runs it without HOME (RT-RTA-02)
R=${STELLA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}; A=${HARDCODE_ALLOW:-$R/docs/hermes-local/hardcode-allow.json}
H=${HARDCODE_HOME:-$HOME}; mode=${1:---check}
case $mode in --check|--dump) ;; *) echo "usage: hardcode-lint.sh [--check | --dump]" >&2; exit 2;; esac
die() { python3 -I "$R/bin/alert_catalog.py" preview STL-CFG-310 problem="$1" >&2 2>/dev/null || echo "STL-CFG-310 $1" >&2; exit 2; }
jq -e '(.schema_version == 1) and all(.baseline[]?; (.phase // "") != "" and (.count | type) == "number")
  and all(.allow[]?, .own_names[]?; (.phase // "") != "" and (.text // "") != "")' "$A" >/dev/null 2>&1 \
  || die "$A is not a valid allow list (schema_version 1; every entry names its phase)"
catalog=$(STELLA_ROOT=$R python3 -I "$R/bin/stella_data.py" get --json connections 2>/dev/null) || die "the connections catalog cannot be read"
catlits=$(jq -r '.entries[] | .id, (.models[]?.id), (.hosts[]?.host)' <<<"$catalog" 2>/dev/null) || die "the connections catalog has no entries list"
watch=$(jq -r '.watch[]?' "$A")
lits=$( {
  jq -r '.profiles | keys[] | select(. != "default")' "$R/docs/hermes-local/roles.json"
  sed -n 's/^KANBAN_BOARD=\([A-Za-z0-9_-]*\).*/\1/p' "$R/bin/kanban-board.sh"
  python3 -c 'import sqlite3, sys; [print(r[0]) for r in sqlite3.connect("file:" + sys.argv[1] + "/.hermes/projects.db?mode=ro", uri=True).execute("select slug from projects")]' "$H" 2>/dev/null
  for h in "$H/.hermes" "$H"/.hermes/profiles/*/; do
    [ -f "${h%/}/config.yaml" ] && HERMES_HOME=${h%/} timeout 20 hermes config get model 2>/dev/null | sed -n 's/^default: *//p; s#^base_url: *[a-z]*://\([^:/]*\).*#\1#p'
  done
  sed -n 's/^ALERT_TARGET="[a-z]*:\(#[A-Za-z0-9_-]*\)".*/\1/p' "$R/.supervisor/limits.env" 2>/dev/null
  printf '%s\n' "$catlits"
  printf '%s\n' "$watch"   # B2V-05: names no data file holds yet (other channels, Claude model names)
} | tr -d "\"'" | sort -u | grep -v '^$')
[ -n "$lits" ] || die "no literal could be read from the data"
files=$(cd "$R" && { ls bin/*.sh bin/*.py | grep -v -e '-selftest\.sh$' -e '^bin/selftests\.sh$' -e '^bin/kanban-board\.sh$'
  find docs/hermes-local/hooks docs/hermes-local/plugins -type f \( -name '*.py' -o -name '*.sh' \); ls docs/hermes-local/soul/*.md docs/hermes-local/board.md docs/stella-recover.ps1; } | sort)
# A watch name counts in any case (B2V-13); data literals stay exact. A word is [A-Za-z0-9_] on both sides, as grep -w.
counts=$(cd "$R" && python3 -I -c '
import json, re, sys
allow = json.load(open(sys.argv[1])); watch = set(sys.argv[2].split("\n")) - {""}
lits = [l for l in sys.stdin.read().split("\n") if l]
own = [a["text"] for a in allow.get("own_names", [])]
for f in sys.argv[3:]:
    try: t = open(f, encoding="utf-8", errors="replace").read()
    except OSError: print("ERROR\t" + f); continue
    for a in own + [a["text"] for a in allow.get("allow", []) if a["file"] == f]: t = t.replace(a, "")
    for l in lits:
        n = len(re.findall(r"(?<!\w)" + re.escape(l) + r"(?!\w)", t, re.I if l in watch else 0))
        if n: print(f"{f}\t{l}\t{n}")' "$A" "$watch" $files <<<"$lits")
grep -q '^ERROR' <<<"$counts" && die "a scanned file cannot be read: $(grep -m1 '^ERROR' <<<"$counts" | cut -f2)"
[ "$mode" = --dump ] && { [ -z "$counts" ] || printf '%s\n' "$counts"; exit 0; }
over=$(while IFS=$'\t' read -r f l n; do [ -n "$f" ] || continue
  max=$(jq -r --arg f "$f" --arg l "$l" '[.baseline[]? | select(.file == $f and .literal == $l) | .count] | add // 0' "$A")
  [ "$n" -le "$max" ] || echo "$f: \"$l\" x$n (allowed $max)"; done <<<"$counts")
[ -z "$over" ] || { printf '%s\n' "$over"; exit 1; }
