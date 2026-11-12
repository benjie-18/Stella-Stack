#!/usr/bin/env bash
# Hard-code lint (K12, standing rule 1; Body B7): no literal profile, role, model, provider, host, board, project or channel
# name in scripts, hooks, SOULs or the board text outside the data files. The literals come from data, never from this file:
# profile and role names (docs/hermes-local/roles.json; the words hardcode-allow.json "plain_words" lists are left out), the
# board (bin/kanban-board.sh), the board's project slugs (projects.db), each profile's model and model-server host (`hermes
# config get model`), the alerts channel (.supervisor/limits.env ALERT_TARGET), the connections catalog (entry ids, model ids
# and host names, read through bin/stella_data.py) and hardcode-allow.json "watch" (names no data file holds yet).
# What is scanned: every file git tracks in the root (a walk of the root where there is no git), that matches a "scan" pattern
# and no "skip" row. A pattern is a whole path: `*` and `?` stop at a folder border, `**` crosses folders; none may start with
# `/` or hold a `..` segment. The owner settings and the apply tool's state (bin/roles.py owner_settings and state_paths, the
# functions the guards use) are never listed, read or copied: every entry is judged by what it resolves to before anything opens
# it, and one that is, lies in or holds such a path, is a hard link to one, or is a link loop, is dropped; a link that points
# outside the root is refused, and a dangling one is refused when it is read (exit 2). A link to a file that is scanned anyway is
# read once, under the file's own name. A role table the role tool refuses (an empty owner_settings list) is refused.
# hardcode-allow.json: "scan" (patterns of files to scan), "skip" (files left out, each with its reason; "run_by" names the file
# whose `for <name> in <words>;` list must hold the stem the row's first `*` matched, as the suite runner lists the selftests), "plain_words" (role names that
# are ordinary words, not counted), "allow" (exact text in one file), "own_names" (one word-like token of 4 or more characters,
# removed at word borders in every file) and "baseline" (per file and literal, at most `count` whole-word uses, each with the
# phase that removes it; a file and literal once). An own_names or allow text that equals a literal, or an own_names text that
# holds a literal glued to other letters, is refused. The line the board value is read from is left out of its file.
# A short or common literal (an id that is also an English word) is counted like any other, never dropped.
# usage: hardcode-lint.sh [--check | --dump | --list]   --check (default): exit 0, or 1 with STL-CFG-320 and one line per file
#        and literal over its baseline; --dump: "file<TAB>literal<TAB>count" for every use; --list: the files a scratch root needs
#        to run the lint (the scanned files and the data it reads), one per line; reads no home folder and no literal source.
# Exit 2 (STL-CFG-310): an input cannot be read or has the wrong shape: the allow list, any source of literals (present but
# unreadable or unparsable, or absent), a scanned file or folder. Every path the shell opens or hands to a tool passes need()
# first (parents before children, so "absent" is only said where the folder could be read): there but unreadable is exit 2 with
# one line naming it, never a warning and never a default a tool prints. Only a source the live stack runs without by design may
# be absent: the projects database and the Hermes homes; then one stderr line says which literals were not checked.
# The model and host of a Hermes home are read from `hermes config get model` by bin/model_watch.py's own reader (model_answer).
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
# need <what> <path>...: a path that is there but cannot be read (a folder: read and entered) stops the lint, naming it; give parents first
need() { local w=$1 p n; shift; for p; do n=${p#"$R"/}; [ "$p" = "$H" ] && n="HARDCODE_HOME or HOME" || n=${n#"$H"/}
  { [ ! -e "$p" ] && [ ! -L "$p" ]; } || { [ -r "$p" ] && { [ ! -d "$p" ] || [ -x "$p" ]; }; } || die "the $w ($n) is there but cannot be read"; done; }
case $mode in --check|--dump|--list) ;; *) die "usage: hardcode-lint.sh [--check | --dump | --list]";; esac
need "allow list" "$A"
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
import errno, json, os, re, subprocess, sys
from pathlib import Path
def err(m): print("ERROR\t" + m); sys.exit(3)
root, ap, mode, board = Path(sys.argv[1]).resolve(), sys.argv[2], sys.argv[3], sys.argv[5]; watch = set(sys.argv[4].split("\n")) - {""}
sys.path.insert(0, str(root / "bin"))
try: import roles   # the role tool of the tree scanned: its owner and state paths are the ones its guards refuse
except Exception as e: err(f"the role tool (bin/roles.py) cannot be loaded ({type(e).__name__})")
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
    with open(root / "docs/hermes-local/roles.json", encoding="utf-8") as fh: rt = json.load(fh, object_pairs_hook=roles._pairs)
except (OSError, ValueError) as e: err(f"the role table (docs/hermes-local/roles.json) cannot be read ({type(e).__name__})")
bad = roles.validate(rt, str(root), files=False)   # as the role tool refuses it (an empty owner_settings list among the rest)
if bad: err("the role table (docs/hermes-local/roles.json) is refused by bin/roles.py: " + "; ".join(bad)[:400])
try:
    idx = roles.index(rt, str(root))
    owner = [os.path.relpath(p, roles.ROOT) for p in roles.owner_settings(rt)] + roles.state_paths(rt, str(root))
    data = [rt["data_index"], *(f["path"] for f in idx["files"]), idx["role_table"]]
    assert all(isinstance(d, str) and d for d in data)
except roles.RolesError as e: err(f"the data index the role table names cannot be read: {e}")
except (KeyError, AssertionError): err("the data index the role table names has no role_table path")
under = lambda f, d: f == d or f.startswith(d.rstrip("/") + "/")
data += [".supervisor/limits.env", "docs/hermes-local/alert-catalog.json"]
data.append(str(Path(rt["data_index"]).parent / "schemas"))   # shortcut: the schema folder is beside the index; read it from the index when it names it
try: data.append(Path(ap).resolve().relative_to(root).as_posix())
except ValueError: pass
try: r = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True) if (root / ".git").exists() else None
except OSError: r = None   # no git on this machine: walk the tree
if r is not None and r.returncode: err("git ls-files failed in the root")
if r is not None: universe = [f.decode("utf-8", "surrogateescape") for f in r.stdout.split(b"\0") if f]
else:
    universe = []
    def walkerr(e): err("a folder of the root cannot be read: " + json.dumps(os.path.relpath(e.filename, root)))
    for d, ds, fs in os.walk(root, onerror=walkerr):
        ds[:] = sorted(x for x in ds if x != ".git" or Path(d) != root)
        rel = Path(d).relative_to(root).as_posix()
        universe += [(rel + "/" if rel != "." else "") + f for f in fs + [x for x in ds if os.path.islink(Path(d) / x)]]
# Each entry by what it resolves to (resolved, stat'ed, never opened): an owner or state path, one in or above it, a hard link to
# one, or a loop is dropped; an entry that cannot be resolved for another reason than a missing target is refused.
rs = str(root); prot = [os.path.realpath(root / o) for o in owner]
def ident(p):
    try: st = os.stat(p); return st.st_dev, st.st_ino
    except OSError: return None
ids = {ident(o) for o in prot} | {ident(os.path.join(d, x)) for o in prot for d, _, fs in os.walk(o) for x in fs}   # shortcut: a state folder that cannot be listed hides its hard links, upgrade when a state folder is not the owner's to read
ids.discard(None); real = {}
def kept(f):
    p = root / f
    try: rp = os.path.realpath(p, strict=True)
    except OSError as e:
        if e.errno == errno.ELOOP: return False
        if e.errno != errno.ENOENT: err(f"a file of the root cannot be read (resolving its path failed): {json.dumps(f)} ({e.strerror})")
        rp = os.path.realpath(p)   # dangling: judged by where it points; reading it is refused below (exit 2)
    if any(under(rp, o) or under(o, rp) for o in prot): return False
    st = ident(p)
    if st is not None and st in ids: return False
    real[f] = (rp, st); return True
universe = [f for f in universe if kept(f)]
for f in universe:
    if "\n" in f or "\t" in f: err("a file name has a tab or a newline: " + json.dumps(f))
scan = [rx(p) for p in allow["scan"]]; skip = [(rx(s["file"], bool(s.get("run_by"))), s.get("run_by")) for s in allow["skip"]]
runs = {}
def listed(rb):  # the words of the runner's `for <name> in <words>;` lists: what it runs, not any word of its text
    if rb not in runs:
        try: txt = (root / rb).read_text(encoding="utf-8", errors="replace")
        except OSError: err("the file a skip row names as its runner cannot be read: " + rb)
        runs[rb] = {w for m in re.finditer(r"(?m)^\s*for\s+\w+\s+in\s+([^;\n]*);", txt) for w in m.group(1).split()}
    return runs[rb]
def skipped(f):
    for rg, rb in skip:
        m = rg.match(f)
        if m and (not rb or m.group(1) in listed(rb)): return True
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
out, first = [], {}
for f in files:   # a link to a file that is scanned anyway is read once, under the file's own name
    rp, st = real[f]
    if not under(rp, rs): err("a scanned file resolves outside the root: " + json.dumps(f))
    if st is not None and (st not in first or os.path.islink(root / first[st]) and not os.path.islink(root / f)): first[st] = f
for f in files:
    if real[f][1] is not None and first[real[f][1]] != f: continue
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
# A model answer is read by bin/model_watch.py's own reader (model_answer); a host is the URL's whole host. Exit 4: no model line.
PYM=$(cat <<'EOF'
import sys
from urllib.parse import urlparse
sys.path.insert(0, sys.argv[1] + "/bin")
from model_watch import model_answer
m, b = model_answer(sys.stdin.read())
if not m: sys.exit(4)
print(m)
try: h = urlparse(b).hostname if b else None
except ValueError: h = None
if h: print(h)
EOF
)
if [ "$mode" = --list ]; then counts=$(python3 -I -B -c "$PY" "$R" "$A" --list "" "$BOARD") || die "the file list failed: ${counts#ERROR$'\t'}"; printf '%s\n' "$counts"; exit 0; fi
[ -n "$H" ] || die "neither HARDCODE_HOME nor HOME is set: no home folder to read the projects database and the Hermes homes from"
need "role table" "$R/docs/hermes-local/roles.json"; need "limits file" "$R/.supervisor/limits.env"; need "board file" "$R/$BOARD"
need "home folder" "$H"; need "Hermes folder" "$H/.hermes" "$H/.hermes/projects.db" "$H/.hermes/profiles"
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
for h in "$H/.hermes" "$H"/.hermes/profiles/*/; do
  h=${h%/}; [ -e "$h" ] || continue
  need "Hermes profile folder" "$h" "$h/config.yaml"
  if [ ! -f "$h/config.yaml" ]; then
    [ "$h" != "$H/.hermes" ] || continue   # the root home may hold only the projects database; no home at all is reported below
    warn "model and host of the Hermes profile ${h#"$H"/} (no config.yaml in its folder)"; continue
  fi
  homes=$((homes+1))
  m=$(HERMES_HOME=$h timeout 20 hermes config get model 2>/dev/null) || die "the model of the Hermes home ${h#"$H"/} cannot be read (hermes config get model failed)"
  p=$(python3 -I -B -c "$PYM" "$R" <<<"$m"); prc=$?
  [ $prc != 4 ] || { warn "model and host of the Hermes home ${h#"$H"/} (hermes printed no default: model line)"; continue; }
  [ $prc = 0 ] || die "the model reader (bin/model_watch.py model_answer) failed for the Hermes home ${h#"$H"/}"
  models+=$p$'\n'
done
[ "$homes" -gt 0 ] || warn "model and host of the Hermes profiles (no Hermes home with a config.yaml under the home folder)"
lits=$( { printf '%s\n' "$roles" "$board" "$slugs" "$models" "$target" "$catlits"
  printf '%s\n' "$watch"   # B2V-05: names no data file holds yet (other channels, Claude model names)
} | tr -d "\"'" | sort -u | grep -v '^$')
[ -n "$lits" ] || die "no literal could be read from the data"
# A watch name counts in any case (B2V-13); data literals stay exact. A word is [A-Za-z0-9_] on both sides, as grep -w.
counts=$(python3 -I -B -c "$PY" "$R" "$A" "$mode" "$watch" "$BOARD" <<<"$lits"); crc=$?
if [ $crc != 0 ]; then   # only a single ERROR line is a message; anything else (a crash) gets a fixed text, never partial output
  case $counts in "ERROR"$'\t'*) [ "$(wc -l <<<"$counts")" = 1 ] && die "the counting step failed: ${counts#ERROR$'\t'}";; esac
  die "the counting step failed (it ended without a result)"
fi
[ "$mode" = --dump ] && { [ -z "$counts" ] || printf '%s\n' "$counts"; exit 0; }
[ -z "$counts" ] || { say STL-CFG-320 "a hard-coded name is used more often than its baseline allows" problem="$(wc -l <<<"$counts") file and name pairs"; printf '%s\n' "$counts"; exit 1; }
