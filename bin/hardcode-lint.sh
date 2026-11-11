#!/usr/bin/env bash
# Hard-code lint (K12, standing rule 1; Body B7): no literal profile, role, model, provider, host, board, project or channel
# name in scripts, hooks, SOULs or the board text outside the data files. The literals come from data, never from this file:
# profile and role names (docs/hermes-local/roles.json; the words hardcode-allow.json "plain_words" lists are left out), the
# board (bin/kanban-board.sh), the board's project slugs (projects.db), each profile's model and model-server host (`hermes
# config get model`), the alerts channel (.supervisor/limits.env ALERT_TARGET), the connections catalog (entry ids, model ids
# and host names, read through bin/stella_data.py) and hardcode-allow.json "watch" (names no data file holds yet).
# What is scanned: every file git tracks in the root (a walk of the root where there is no git), that matches a "scan" pattern
# and no "skip" row. A pattern is a whole path: `*` and `?` stop at a folder border, `**` crosses folders; none may start with
# `/` or hold a `..` segment. The paths the role table lists as owner settings and the data index lists as the apply tool's state
# (backup folder, applied state, event log) are never listed, read or copied, whatever the lists say.
# hardcode-allow.json: "scan" (patterns of files to scan), "skip" (files left out, each with its reason; "run_by" names the file
# that must list the stem the row's first `*` matched, as the suite runner lists the selftests), "plain_words" (role names that
# are ordinary words, not counted), "allow" (exact text in one file), "own_names" (one word-like token of 4 or more characters,
# removed at word borders in every file) and "baseline" (per file and literal, at most `count` whole-word uses, each with the
# phase that removes it; a file and literal once). An own_names or allow text that equals a literal, or an own_names text that
# holds a literal glued to other letters, is refused. The line the board value is read from is left out of its file.
# A short or common literal (an id that is also an English word) is counted like any other, never dropped.
# usage: hardcode-lint.sh [--check | --dump | --list]   --check (default): exit 0, or 1 with STL-CFG-320 and one line per file
#        and literal over its baseline; --dump: "file<TAB>literal<TAB>count" for every use; --list: the files a scratch root needs
#        to run the lint (the scanned files and the data it reads), one per line; reads no home folder and no literal source.
# Exit 2 (STL-CFG-310): an input cannot be read or has the wrong shape: the allow list, any source of literals (present but
# unreadable or unparsable, or absent), a scanned file. Only a source the live stack runs without by design may be absent:
# the projects database and the Hermes homes; then one stderr line says which literals were not checked.
# The model and host of a Hermes home are read from `hermes config get model` by the rule of bin/model_watch.py (model_config).
# Inputs: STELLA_ROOT (the tree scanned, default: parent of bin/), HARDCODE_ALLOW (default <root>/docs/hermes-local/
# hardcode-allow.json), HARDCODE_HOME (default $HOME: where .hermes/projects.db and the Hermes homes live).
set -u
jq() { env -u HOME jq "$@"; }   # jq always loads ~/.jq; every script under bin/ runs it without HOME (RT-RTA-02)
R=${STELLA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}; A=${HARDCODE_ALLOW:-$R/docs/hermes-local/hardcode-allow.json}
H=${HARDCODE_HOME:-${HOME:-}}; mode=${1:---check}
# The code with its message (preview form); with no catalog tool the code and a plain line still come out.
say() { local c=$1 p=$2; shift 2; python3 -I -B "$R/bin/alert_catalog.py" preview "$c" "$@" >&2 2>/dev/null || echo "$c $p" >&2; }
die() { say STL-CFG-310 "$1" problem="$1"; exit 2; }
warn() { echo "hardcode-lint: not checked: $1" >&2; }
case $mode in --check|--dump|--list) ;; *) die "usage: hardcode-lint.sh [--check | --dump | --list]";; esac
jq -e 'def S: type == "string" and length > 0; def rows(f): type == "array" and all(.[]; type == "object" and f);
  def P: S and (test("^/|(^|/)\\.\\.(/|$)") | not);
  (.schema_version == 1) and (.baseline | rows((.file | S) and (.literal | S) and (.phase | S) and (.count | type == "number" and . >= 0 and . == floor)))
  and ([.baseline[] | [.file, .literal]] | length == (unique | length))
  and (.allow | rows((.file | S) and (.text | S) and (.phase | S))) and (.own_names | rows((.text | S) and (.phase | S)))
  and (.plain_words | rows((.word | S) and (.why | S)))
  and (.skip | rows((.file | P and test("[A-Za-z0-9_]")) and (.why | S) and ((.run_by // "x") | P)))
  and (.scan | type == "array" and length > 0 and all(.[]; P)) and (.watch | type == "array" and all(.[]; S))' "$A" >/dev/null 2>&1 \
  || die "$A is not a valid allow list (schema_version 1; baseline, allow, own_names, plain_words, skip, scan and watch are lists of well-formed rows; patterns are paths inside the root; no baseline row twice)"
BOARD=bin/kanban-board.sh
# The files: tracked (git) or walked, minus the owner paths, the scan patterns and the skip rows; $PY also lists them (--list) and counts.
PY=$(cat <<'EOF'
import json, os, re, subprocess, sys
from pathlib import Path
def err(m): print("ERROR\t" + m); sys.exit(3)
root, ap, mode, board = Path(sys.argv[1]).resolve(), sys.argv[2], sys.argv[3], sys.argv[5]; watch = set(sys.argv[4].split("\n")) - {""}
allow = json.load(open(ap))
def rx(p, cap=False):  # a whole path; ** crosses folders, * and ? stop at a border; cap: the first * is captured
    out, i = "", 0
    while i < len(p):
        if p.startswith("**/", i): out += "(?:.*/)?"; i += 3
        elif p.startswith("**", i): out += ".*"; i += 2
        elif p[i] == "*": out += "([^/]*)" if cap else "[^/]*"; cap = False; i += 1
        elif p[i] == "?": out += "[^/]"; i += 1
        else: out += re.escape(p[i]); i += 1
    return re.compile(out + r"\Z")
try:
    rt = json.load(open(root / "docs/hermes-local/roles.json")); idx = json.load(open(root / rt["data_index"]))
    owner = [*rt["owner_settings"], idx["backup_dir"], idx["applied_state"], idx["event_log"]]
    data = [rt["data_index"], *(f["path"] for f in idx["files"]), idx["role_table"]]
    assert all(isinstance(o, str) and o for o in owner + data)
except (OSError, ValueError, KeyError, TypeError, AssertionError): err("the role table (docs/hermes-local/roles.json) or the data index it names cannot be read or has no owner paths")
owner = [o.rstrip("/") for o in owner]; under = lambda f, d: f == d or f.startswith(d.rstrip("/") + "/")
data = [d for d in data if not any(under(d, o) for o in owner)] + [".supervisor/limits.env", "docs/hermes-local/alert-catalog.json"]
data.append(str(Path(rt["data_index"]).parent / "schemas"))   # shortcut: the schema folder is beside the index; read it from the index when it names it
try: data.append(Path(ap).resolve().relative_to(root).as_posix())
except ValueError: pass
try: r = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True) if (root / ".git").exists() else None
except OSError: r = None   # no git on this machine: walk the tree
if r is not None and r.returncode: err("git ls-files failed in the root")
if r is not None: universe = [f.decode("utf-8", "surrogateescape") for f in r.stdout.split(b"\0") if f]
else:
    universe = []
    for d, ds, fs in os.walk(root):
        ds[:] = sorted(x for x in ds if x != ".git" or Path(d) != root)
        rel = Path(d).relative_to(root).as_posix()
        universe += [(rel + "/" if rel != "." else "") + f for f in fs + [x for x in ds if os.path.islink(Path(d) / x)]]
universe = [f for f in universe if not any(under(f, o) for o in owner)]
for f in universe:
    if "\n" in f or "\t" in f: err("a file name has a tab or a newline: " + json.dumps(f))
scan = [rx(p) for p in allow["scan"]]; skip = [(rx(s["file"], bool(s.get("run_by"))), s.get("run_by")) for s in allow["skip"]]
def skipped(f):
    for rg, rb in skip:
        m = rg.match(f)
        if not m: continue
        if not rb: return True
        try: txt = (root / rb).read_text(encoding="utf-8", errors="replace")
        except OSError: err("the file a skip row names as its runner cannot be read: " + rb)
        if re.search(r"(?<![\w-])" + re.escape(m.group(1)) + r"(?![\w-])", txt): return True
    return False
files = sorted(f for f in universe if any(g.match(f) for g in scan) and not skipped(f))
if not files: err("no file matches the scan list")
if mode == "--list":
    print("\n".join(sorted(set(files) | {f for f in universe if any(under(f, d) for d in data)}))); sys.exit(0)
lits = [l for l in sys.stdin.read().split("\n") if l]
flag = lambda l: re.I if l in watch else 0
own = [a["text"] for a in allow["own_names"]]
for a in own + [a["text"] for a in allow["allow"]]:
    if a in lits: err("the allow list has an own_names or allow text equal to a name that must come from data: " + json.dumps(a[:60]))
for a in own:
    if not re.fullmatch(r"[A-Za-z0-9._-]{4,}", a): err("an own_names text must be one word-like token of 4 or more characters: " + json.dumps(a[:60]))
    for l in lits:
        if re.search(r"(?<=\w)" + re.escape(l) + "|" + re.escape(l) + r"(?=\w)", a, flag(l)): err("an own_names text holds a name that must come from data: " + json.dumps(a[:60]))
pats = [(l, re.compile(r"(?<!\w)" + re.escape(l) + r"(?!\w)", flag(l))) for l in lits]
owns = [re.compile(r"(?<!\w)" + re.escape(a) + r"(?!\w)") for a in own]
base = {(b["file"], b["literal"]): b["count"] for b in allow["baseline"]}   # a file and literal twice is refused by the shape check
out = []
for f in files:
    if not (root / f).resolve().is_relative_to(root): err("a scanned file resolves outside the root: " + json.dumps(f))
    try: t = (root / f).read_text(encoding="utf-8", errors="replace")
    except OSError: err("a scanned file cannot be read: " + f)
    if f == board: t = re.sub(r"(?m)^KANBAN_BOARD=.*$", "", t)   # the line the board value is read from
    for g in owns: t = g.sub("", t)
    for a in [a["text"] for a in allow["allow"] if a["file"] == f]: t = t.replace(a, "")
    for l, g in pats:
        n = len(g.findall(t))
        if n and mode == "--dump": out.append(f"{f}\t{l}\t{n}")
        elif n > base.get((f, l), 0): out.append(f"{f}: \"{l}\" x{n} (allowed {base.get((f, l), 0)})")
print("\n".join(out))
EOF
)
# A model answer is read by the rule of bin/model_watch.py model_config (the same regex); a host is the URL's whole host.
PYM=$(cat <<'EOF'
import re, sys
from urllib.parse import urlparse
c = dict(re.findall(r"^\s*([A-Za-z_]+):\s*(\S.*?)\s*$", sys.stdin.read(), re.M))
m, b = c.get("default", "").strip("'\""), c.get("base_url", "").strip("'\"")
if not m: sys.exit(1)
print(m)
try: h = urlparse(b).hostname if b else None
except ValueError: h = None
if h: print(h)
EOF
)
if [ "$mode" = --list ]; then counts=$(python3 -I -c "$PY" "$R" "$A" --list "" "$BOARD") || die "the file list failed: ${counts#ERROR$'\t'}"; printf '%s\n' "$counts"; exit 0; fi
[ -n "$H" ] || die "neither HARDCODE_HOME nor HOME is set: no home folder to read the projects database and the Hermes homes from"
roles=$(jq -r --argjson pw "$(jq -c '[.plain_words[].word]' "$A")" '[(.profiles | keys[]), (.roles | keys[])][] | select(IN($pw[]) | not)' \
  "$R/docs/hermes-local/roles.json" 2>/dev/null) || die "the role table (docs/hermes-local/roles.json) cannot be read"
# shortcut: the paths of the sources below are written here, not read from the data index; they move when the index names them
catalog=$(STELLA_ROOT=$R python3 -I -B "$R/bin/stella_data.py" get --json connections 2>&1) || die "the connections catalog cannot be read: $(head -c 300 <<<"$catalog" | tr '\n' ' ')"
catlits=$(jq -r '.entries[] | .id, (.models[]?.id), (.hosts[]?.host)' <<<"$catalog" 2>/dev/null) || die "the connections catalog has no entries list"
watch=$(jq -r '.watch[]' "$A") || die "the watch list of the allow list cannot be read"
board=$(sed -n -E "s/^KANBAN_BOARD=[\"']?([A-Za-z0-9_-]+).*/\1/p" "$R/$BOARD" 2>/dev/null); [ -n "$board" ] || die "the board value (KANBAN_BOARD in $BOARD) cannot be read"
target=$(sed -n -E "s/^ALERT_TARGET=[\"']?[a-z]*:(#[A-Za-z0-9_-]+).*/\1/p" "$R/.supervisor/limits.env" 2>/dev/null); [ -n "$target" ] || die "the alerts target (ALERT_TARGET in .supervisor/limits.env) cannot be read"
slugs=; if [ -e "$H/.hermes/projects.db" ]; then   # absent by design on a fresh install: no board has been made yet
  slugs=$(python3 -I -c 'import sqlite3, sys; [print(r[0]) for r in sqlite3.connect("file:" + sys.argv[1] + "/.hermes/projects.db?mode=ro", uri=True).execute("select slug from projects")]' "$H" 2>/dev/null) \
    || die "the projects database (.hermes/projects.db under the home folder) cannot be read"
else warn "project slugs (no .hermes/projects.db under the home folder)"; fi
models=; homes=0
[ ! -d "$H/.hermes/profiles" ] || { [ -r "$H/.hermes/profiles" ] && [ -x "$H/.hermes/profiles" ]; } || die "the Hermes profiles folder (.hermes/profiles under the home folder) cannot be read"
for h in "$H/.hermes" "$H"/.hermes/profiles/*/; do
  h=${h%/}; [ -e "$h" ] || continue
  if [ ! -f "$h/config.yaml" ]; then
    [ "$h" != "$H/.hermes" ] || continue   # the root home may hold only the projects database; no home at all is reported below
    { [ -r "$h" ] && [ -x "$h" ]; } || die "the Hermes profile folder ${h#"$H"/} cannot be read"
    warn "model and host of the Hermes profile ${h#"$H"/} (no config.yaml in its folder)"; continue
  fi
  homes=$((homes+1))
  m=$(HERMES_HOME=$h timeout 20 hermes config get model 2>/dev/null) || die "the model of the Hermes home ${h#"$H"/} cannot be read (hermes config get model failed)"
  p=$(python3 -I -c "$PYM" <<<"$m") || { warn "model and host of the Hermes home ${h#"$H"/} (hermes printed no default: model line)"; continue; }
  models+=$p$'\n'
done
[ "$homes" -gt 0 ] || warn "model and host of the Hermes profiles (no Hermes home with a config.yaml under the home folder)"
lits=$( { printf '%s\n' "$roles" "$board" "$slugs" "$models" "$target" "$catlits"
  printf '%s\n' "$watch"   # B2V-05: names no data file holds yet (other channels, Claude model names)
} | tr -d "\"'" | sort -u | grep -v '^$')
[ -n "$lits" ] || die "no literal could be read from the data"
# A watch name counts in any case (B2V-13); data literals stay exact. A word is [A-Za-z0-9_] on both sides, as grep -w.
counts=$(python3 -I -c "$PY" "$R" "$A" "$mode" "$watch" "$BOARD" <<<"$lits"); crc=$?
if [ $crc != 0 ]; then   # only a single ERROR line is a message; anything else (a crash) gets a fixed text, never partial output
  case $counts in "ERROR"$'\t'*) [ "$(wc -l <<<"$counts")" = 1 ] && die "the counting step failed: ${counts#ERROR$'\t'}";; esac
  die "the counting step failed (it ended without a result)"
fi
[ "$mode" = --dump ] && { [ -z "$counts" ] || printf '%s\n' "$counts"; exit 0; }
[ -z "$counts" ] || { say STL-CFG-320 "a hard-coded name is used more often than its baseline allows" problem="$(wc -l <<<"$counts") file and name pairs"; printf '%s\n' "$counts"; exit 1; }
