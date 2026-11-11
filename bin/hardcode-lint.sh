#!/usr/bin/env bash
# Hard-code lint (K12, standing rule 1; Body B7): no literal profile, role, model, provider, host, board, project or channel
# name in scripts, hooks, SOULs or the board text outside the data files. The literals come from data, never from this file:
# profile and role names (docs/hermes-local/roles.json; the words hardcode-allow.json "plain_words" lists are left out), the
# board (bin/kanban-board.sh), the board's project slugs (projects.db), each profile's model and model-server host (`hermes
# config get model`), the alerts channel (.supervisor/limits.env ALERT_TARGET), the connections catalog (entry ids, model ids
# and host names, read through bin/stella_data.py) and hardcode-allow.json "watch" (names no data file holds yet).
# hardcode-allow.json lists what is scanned and what may stay: "scan" (patterns of files to scan), "skip" (files left out, each
# with its reason), "plain_words" (role names that are ordinary words, not counted), "allow" (exact text in one file),
# "own_names" (exact text that is the stack's own name, removed in every file) and "baseline" (per file and literal, at most
# `count` whole-word uses, each with the phase that removes it). An own_names or allow text that equals a literal is refused.
# A short or common literal (an id that is also an English word) is counted like any other, never dropped.
# usage: hardcode-lint.sh [--check | --dump]   --check (default): exit 0, or 1 with STL-CFG-320 and one line per file and
#        literal over its baseline; --dump: "file<TAB>literal<TAB>count" for every use.
# Exit 2 (STL-CFG-310): an input cannot be read or has the wrong shape: the allow list, any source of literals (present but
# unreadable or unparsable, or absent), a scanned file. Only a source the live stack runs without by design may be absent:
# the projects database and the Hermes homes; then one stderr line says which literals were not checked.
# Inputs: STELLA_ROOT (the tree scanned, default: parent of bin/), HARDCODE_ALLOW (default <root>/docs/hermes-local/
# hardcode-allow.json), HARDCODE_HOME (default $HOME: where .hermes/projects.db and the Hermes homes live).
set -u
jq() { env -u HOME jq "$@"; }   # jq always loads ~/.jq; every script under bin/ runs it without HOME (RT-RTA-02)
R=${STELLA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}; A=${HARDCODE_ALLOW:-$R/docs/hermes-local/hardcode-allow.json}
H=${HARDCODE_HOME:-$HOME}; mode=${1:---check}
# The code with its message (preview form); with no catalog tool the code and a plain line still come out.
say() { local c=$1 p=$2; shift 2; python3 -I "$R/bin/alert_catalog.py" preview "$c" "$@" >&2 2>/dev/null || echo "$c $p" >&2; }
die() { say STL-CFG-310 "$1" problem="$1"; exit 2; }
warn() { echo "hardcode-lint: not checked: $1" >&2; }
case $mode in --check|--dump) ;; *) die "usage: hardcode-lint.sh [--check | --dump]";; esac
jq -e 'def S: type == "string" and length > 0; def rows(f): type == "array" and all(.[]; type == "object" and f);
  (.schema_version == 1) and (.baseline | rows((.file | S) and (.literal | S) and (.phase | S) and (.count | type == "number" and . >= 0 and . == floor)))
  and (.allow | rows((.file | S) and (.text | S) and (.phase | S))) and (.own_names | rows((.text | S) and (.phase | S)))
  and (.plain_words | rows((.word | S) and (.why | S))) and (.skip | rows((.file | S) and (.why | S)))
  and (.scan | type == "array" and length > 0 and all(.[]; S)) and (.watch | type == "array" and all(.[]; S))' "$A" >/dev/null 2>&1 \
  || die "$A is not a valid allow list (schema_version 1; baseline, allow, own_names, plain_words, skip, scan and watch are lists of well-formed rows)"
# shortcut: the paths of the sources below are written here, not read from the data index; they move when the index names them
catalog=$(STELLA_ROOT=$R python3 -I "$R/bin/stella_data.py" get --json connections 2>/dev/null) || die "the connections catalog cannot be read"
catlits=$(jq -r '.entries[] | .id, (.models[]?.id), (.hosts[]?.host)' <<<"$catalog" 2>/dev/null) || die "the connections catalog has no entries list"
watch=$(jq -r '.watch[]' "$A") || die "the watch list of the allow list cannot be read"
roles=$(jq -r --argjson pw "$(jq -c '[.plain_words[].word]' "$A")" '[(.profiles | keys[]), (.roles | keys[])][] | select(IN($pw[]) | not)' \
  "$R/docs/hermes-local/roles.json" 2>/dev/null) || die "the role table (docs/hermes-local/roles.json) cannot be read"
board=$(sed -n -E "s/^KANBAN_BOARD=[\"']?([A-Za-z0-9_-]+).*/\1/p" "$R/bin/kanban-board.sh" 2>/dev/null); [ -n "$board" ] || die "the board value (KANBAN_BOARD in bin/kanban-board.sh) cannot be read"
target=$(sed -n -E "s/^ALERT_TARGET=[\"']?[a-z]*:(#[A-Za-z0-9_-]+).*/\1/p" "$R/.supervisor/limits.env" 2>/dev/null); [ -n "$target" ] || die "the alerts target (ALERT_TARGET in .supervisor/limits.env) cannot be read"
slugs=; if [ -e "$H/.hermes/projects.db" ]; then   # absent by design on a fresh install: no board has been made yet
  slugs=$(python3 -I -c 'import sqlite3, sys; [print(r[0]) for r in sqlite3.connect("file:" + sys.argv[1] + "/.hermes/projects.db?mode=ro", uri=True).execute("select slug from projects")]' "$H" 2>/dev/null) \
    || die "the projects database (.hermes/projects.db under the home folder) cannot be read"
else warn "project slugs (no .hermes/projects.db under the home folder)"; fi
models=; homes=0
for h in "$H/.hermes" "$H"/.hermes/profiles/*/; do
  [ -f "${h%/}/config.yaml" ] || continue; homes=$((homes+1))
  m=$(HERMES_HOME=${h%/} timeout 20 hermes config get model 2>/dev/null) || die "the model of the Hermes home ${h#"$H"/} cannot be read (hermes config get model failed)"
  models+=$(sed -n 's/^default: *//p; s#^base_url: *[a-z]*://\([^:/]*\).*#\1#p' <<<"$m")$'\n'
done
[ "$homes" -gt 0 ] || warn "model and host of the Hermes profiles (no Hermes home with a config.yaml under the home folder)"
lits=$( { printf '%s\n' "$roles" "$board" "$slugs" "$models" "$target" "$catlits"
  printf '%s\n' "$watch"   # B2V-05: names no data file holds yet (other channels, Claude model names)
} | tr -d "\"'" | sort -u | grep -v '^$')
[ -n "$lits" ] || die "no literal could be read from the data"
# A watch name counts in any case (B2V-13); data literals stay exact. A word is [A-Za-z0-9_] on both sides, as grep -w.
# The files are listed here from the allow list's patterns (no shell splitting: a name is data); a name with a tab or a newline is refused.
counts=$(python3 -I -c '
import fnmatch, json, re, sys
from pathlib import Path
def err(m): print("ERROR\t" + m); sys.exit(3)
root, ap, mode = Path(sys.argv[1]), sys.argv[2], sys.argv[3]; watch = set(sys.argv[4].split("\n")) - {""}
allow = json.load(open(ap)); lits = [l for l in sys.stdin.read().split("\n") if l]
own = [a["text"] for a in allow["own_names"]]
for a in own + [a["text"] for a in allow["allow"]]:
    if a in lits: err(f"the allow list has an own_names or allow text equal to a name that must come from data: {a}")
skip = [s["file"] for s in allow["skip"]]; files = set()
for pat in allow["scan"]:
    for p in root.glob(pat):
        rel = p.relative_to(root).as_posix()
        if (p.is_file() or p.is_symlink()) and not any(fnmatch.fnmatchcase(rel, s) for s in skip): files.add(rel)
if not files: err("no file matches the scan list")
pats = [(l, re.compile(r"(?<!\w)" + re.escape(l) + r"(?!\w)", re.I if l in watch else 0)) for l in lits]
base = {}
for b in allow["baseline"]: base[b["file"], b["literal"]] = base.get((b["file"], b["literal"]), 0) + b["count"]
for f in sorted(files):
    if "\n" in f or "\t" in f: err("a scanned file name has a tab or a newline: " + json.dumps(f))
    try: t = (root / f).read_text(encoding="utf-8", errors="replace")
    except OSError: err("a scanned file cannot be read: " + f)
    for a in own + [a["text"] for a in allow["allow"] if a["file"] == f]: t = t.replace(a, "")
    for l, rx in pats:
        n = len(rx.findall(t))
        if n and mode == "--dump": print(f"{f}\t{l}\t{n}")
        elif n > base.get((f, l), 0): print(f"{f}: \"{l}\" x{n} (allowed {base.get((f, l), 0)})")' "$R" "$A" "$mode" "$watch" <<<"$lits") || die "the counting step failed: ${counts#ERROR$'\t'}"
[ "$mode" = --dump ] && { [ -z "$counts" ] || printf '%s\n' "$counts"; exit 0; }
[ -z "$counts" ] || { say STL-CFG-320 "a hard-coded name is used more often than its baseline allows" problem="$(wc -l <<<"$counts") file and name pairs"; printf '%s\n' "$counts"; exit 1; }
