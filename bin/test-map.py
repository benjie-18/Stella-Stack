#!/usr/bin/env python3
"""Test map (product rule 8), stdlib only: the lint over .stella/test-map.json and the selection of test targets.
CLI: test-map.py check                           lint: exit 1 and one STL-CFG-310 line per problem
     test-map.py select [--json] [--] <file>...  the selftests a change to these files can affect ("-" alone reads names
                                                 from stdin, one per line); prints "full" (exit 0) when the whole suite
                                                 must run, else one target per line. Only the first argument may be an
                                                 option; "--" ends the options.
The stack root is the parent of this file's folder, or STELLA_ROOT (a scratch root in tests). Under STELLA_ROOT every
`check` line ends with the root (a root too long for that is named once, first), a narrow `select` names it on stderr,
and `select --json` has a `root` key. A problem longer than the catalog keeps is split into numbered parts, and a long
list of selftests into whole lines: nothing is cut. git runs with no global, system or XDG config and no personal
ignore list (only the caller's safe.directory is kept).
check fails when: the map is unreadable, repeats a key or breaks its schema; a selftest is not a target of any row; a
target or an always gate has no selftest file; a selftest is missing from the suite list of the runner (or the list
cannot be read); a suite selftest is not executable, on disk or in the mode git records; a file that looks like a test
(test_like) is neither a suite selftest nor listed in not_tests; a selftest can reach a file (see reach) whose
selection leaves that selftest out; or a row with no targets matches more than prose (see prose).
select: a file on the full list (matched without regard to case), or matched by no row, selects the full suite; so does
no file name at all. `scan` rows add targets (a selftest that reads a whole folder) but do not count as a match. Pass
both sides of a rename (`git diff --name-only --no-renames`): the new path alone can narrow the selection. A name with
white space (at either end too, on stdin as well), a control character or a leading dash selects the full suite."""
import fnmatch, json, os, re, subprocess, sys, textwrap

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import alert_catalog, stella_data

ROOT = os.environ.get("STELLA_ROOT") or os.path.dirname(BIN)
MAP = ".stella/test-map.json"
SCHEMA = os.path.join(os.path.dirname(BIN), ".stella", "schemas", "test-map.schema.json")   # ships with this tool, so a scratch root needs none


def no_repeats(pairs):
    d = dict(pairs)
    if len(d) != len(pairs):
        raise ValueError("a key is repeated")   # json.load would keep the last one silently
    return d


def read():
    """(map, schema problems)."""
    with open(os.path.join(ROOT, MAP), encoding="utf-8") as f:
        m = json.load(f, object_pairs_hook=no_repeats)
    with open(SCHEMA, encoding="utf-8") as f:
        errs = stella_data.validate_doc(m, json.load(f))
    if not errs and type(m["schema_version"]) is not int:
        errs = ["$.schema_version: must be the integer 1"]   # true and 1.0 equal 1 in Python
    return m, errs


def load():
    m, errs = read()
    if errs:
        raise ValueError("; ".join(errs))
    return m


def matches(f, globs):
    return any(fnmatch.fnmatchcase(f, g) for g in globs)


LIMIT = 200   # alert_catalog.render keeps the first 200 characters of a value


def esc(s):
    return "".join(c if c.isprintable() else repr(c)[1:-1] for c in s)   # a name may hold a newline: keep the line whole


WHERE = esc(f" (root {ROOT}, from STELLA_ROOT)") if os.environ.get("STELLA_ROOT") else ""   # so nobody fixes the wrong tree
ROOM = LIMIT - (len(WHERE) if len(WHERE) <= LIMIT // 2 else 0)   # a longer root is named once, on its own lines


def pack(head, names, tail):
    """head + names + tail in as many lines as the names need, each within ROOM: no name is cut off."""
    lines, cur = [], []
    for n in names:
        if cur and len(esc(head + ", ".join(cur + [n]) + tail)) > ROOM:
            lines.append(cur)
            cur = []
        cur.append(n)
    return [head + ", ".join(c) + tail for c in lines + [cur]]


def tree():
    """{path: the mode git records, or None} for every file of the root: git's list (tracked and untracked, ignored
    files left out) when the root is a git tree, else a walk."""
    if not os.path.exists(os.path.join(ROOT, ".git")):
        return {os.path.relpath(os.path.join(d, f), ROOT): None for d, _, fs in os.walk(ROOT) for f in fs}
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}   # a caller's GIT_DIR (a git hook) must not point at another repo
    # the caller's safe.directory is the one setting kept (a tree owned by another user is refused without it); no other
    # global, system or XDG setting and no personal ignore list applies: the tree's own .gitignore decides
    trust = [f"safe.directory={d}" for scope in ("--system", "--global") for d in subprocess.run(
        ["git", "config", scope, "--get-all", "safe.directory"], capture_output=True, text=True, env=env).stdout.splitlines()]
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, HOME=os.devnull, XDG_CONFIG_HOME=os.devnull)
    def git(*args):
        return subprocess.run(["git", *[x for t in trust for x in ("-c", t)], "-C", ROOT, "ls-files", "-z", *args],
                              capture_output=True, text=True, check=True, env=env).stdout.split("\0")
    files = dict.fromkeys(filter(None, git("-co", "--exclude-standard")))
    for line in filter(None, git("-s")):
        files[line.split("\t", 1)[1]] = line.split()[0]
    return {f: mode for f, mode in files.items() if os.path.isfile(os.path.join(ROOT, f))}


def words(text):
    return {w.strip(".") for w in re.findall(r"[\w.-]+", text)}


def content(f):
    try:
        with open(os.path.join(ROOT, f), encoding="utf-8") as fh:
            return fh.read()
    except (OSError, UnicodeDecodeError):
        return ""


def uncommented(text):
    return re.sub(r"(?m)^[ \t]*#(?!!).*$", "", text)


# shortcut: a glob is taken to match every path when it matches these unlikely names; upgrade if a real glob needs them
PROBES = ("zq9", ".zq9", "zq9/.zq9/zq9.zq9")


def prose(m, files):
    """A row with no targets may match only prose, since a change to its files runs no selftest: refuse a row whose glob
    matches every path, or that matches code (follow, #!), an executable, a test-like file, or a file that a code or data
    file (the `data` globs; every file when the map has none) names, by the name search reach uses. One problem per row."""
    rows = [(i, r["globs"]) for i, r in enumerate(m["map"], 1) if not r["targets"] and not r.get("scan")]
    if not rows:
        return []
    by_base, named = {}, {}
    for f in files:
        by_base.setdefault(os.path.basename(f), set()).add(f)
    for g in sorted(files):
        text = content(g)
        if g != MAP and (text.startswith("#!") or matches(g, m["follow"]) or matches(g, m.get("data", ["*"]))):
            for w in words(uncommented(text)) & by_base.keys():
                for f in by_base[w] - {g}:
                    named.setdefault(f, g)

    def why(f):
        if matches(f, m["follow"]):
            return "code (a follow pattern)"
        if os.access(os.path.join(ROOT, f), os.X_OK) or files[f] == "100755":
            return "an executable file"
        if content(f).startswith("#!"):
            return "a script (#!)"
        if matches(f.lower(), m["test_like"]):
            return "a test-like file"
        return f in named and f"named by {named[f]}"

    probs = []
    for i, globs in rows:
        row = f"map row {i} ({', '.join(globs)}) has no targets"
        wide = [g for g in globs if all(fnmatch.fnmatchcase(p, g) for p in PROBES)]
        if wide:
            probs.append(f"{row} and its glob {wide[0]} matches every path")
            continue
        bad = next(((f, w) for f in sorted(files) if matches(f, globs) for w in [why(f)] if w), None)
        if bad:
            probs.append(f"{row}, so it may match only prose, but it matches {bad[0]}: {bad[1]}")
    return probs


def reach(m, files, tests):
    """{selftest: the files it can reach}: its own file, every file it names (by base name, or a Python module by its
    import), and on through each named file that is code (starts with #! or matches a follow glob). Whole-line #
    comments name nothing: without that, one remark in a shared script ties every selftest to the file it mentions.
    shortcut: a name built at run time or a folder read by a glob is not seen, those need a `scan` row or the full list."""
    by_base, mods, named = {}, {}, {}
    for f in files:
        by_base.setdefault(os.path.basename(f), set()).add(f)
        if f.endswith(".py"):
            mods.setdefault(os.path.basename(f)[:-3], set()).add(f)

    def names(f):
        if f not in named:
            text = content(f)
            named[f] = set()
            if text.startswith("#!") or matches(f, m["follow"]):
                text = uncommented(text)
                seen = words(text)
                imports = words(" ".join(re.findall(r"\b(?:import|from)\s+([\w., ]+)", text)))
                for index, hits in ((by_base, seen), (mods, imports)):
                    named[f].update(x for name in index.keys() & hits for x in index[name])
        return named[f]

    out = {}
    for t, f in tests.items():
        out[t], todo = {f}, [f]
        while todo:
            new = names(todo.pop()) - out[t]
            out[t] |= new
            todo += new
    return out


def select(files, m=None):
    m = m or load()
    targets, reason = set(m["always"]), []
    for f in files:
        if re.search(r"[\s\x00-\x1f\x7f]", f) or f.startswith("-"):   # several names joined into one (a quoted $(git diff), -z output) would match one narrow row
            reason.append(f"{f!r}: not one plain file name (white space, a control character or a leading dash)")
            continue
        f = os.path.normpath(f)
        if matches(f.lower(), [g.lower() for g in m["full"]]):   # a guard is a guard in any case (Guard.js)
            reason.append(f"{f}: a shared contract (full list)")
            continue
        if not any(matches(f, row["globs"]) for row in m["map"] if not row.get("scan")):
            reason.append(f"{f}: no map row matches")
        for row in m["map"]:
            if matches(f, row["globs"]):
                targets.update(row["targets"])
    return {"full": bool(reason), "reason": reason, "targets": sorted(targets)}


def check():
    try:
        m, errs = read()
    except Exception as e:
        return [f"{MAP}: {type(e).__name__}: {e}"]
    if errs:
        return [f"{MAP}: ValueError: {e}" for e in errs]   # one line per problem
    try:
        files = tree()
    except Exception as e:
        return [f"the files of {ROOT} cannot be listed with git: {type(e).__name__}"]
    head, tail = m["test_file"].split("{name}")
    path = lambda t: head + t + tail
    tests = {f[len(head):len(f) - len(tail)]: f for f in files
             if f.startswith(head) and f.endswith(tail) and "/" not in f[len(head):len(f) - len(tail)]}
    if not tests:
        return [f"no selftest ({path('<name>')}) found under {ROOT}"]
    targets = {t for row in m["map"] for t in row["targets"]}
    probs = [f"{tests[t]} is not a target of any map row" for t in sorted(tests.keys() - targets)]
    probs += [f"target {t}: {path(t)} does not exist" for t in sorted((targets | set(m["always"])) - tests.keys())]
    # shortcut: a test is known by its name only (test_like globs), a test named otherwise is not seen; upgrade when a second test runner arrives
    probs += [f"{f} looks like a test but is neither a suite selftest nor listed in not_tests" for f in sorted(files)
              if f not in tests.values() and matches(f.lower(), m["test_like"]) and not matches(f, m["not_tests"])]
    try:
        with open(os.path.join(ROOT, m["runner"]), encoding="utf-8") as fh:
            suite = set(re.search(r"^for t in (.+); do$", fh.read(), re.M)[1].split())
    except Exception:
        return probs + [f"the suite list of {m['runner']} cannot be read (expected one line: for t in <names>; do)"]
    probs += [f"{tests[t]} is not in the suite list of {m['runner']}" for t in sorted(tests.keys() - suite)]
    probs += [f"suite entry {t}: {path(t)} does not exist" for t in sorted(suite - tests.keys())]
    for t in sorted(suite & tests.keys()):   # the suite runs each file directly
        if not os.access(os.path.join(ROOT, tests[t]), os.X_OK):
            probs.append(f"{tests[t]} is not executable")
        elif files[tests[t]] not in (None, "100755"):
            probs.append(f"{tests[t]} is not executable in git (mode {files[tests[t]]}): a fresh checkout cannot run it")
    reached = reach(m, files, tests)
    for f in sorted(files):
        sel = select([f], m)
        missing = [] if sel["full"] else sorted(t for t in tests if f in reached[t] and t not in sel["targets"])
        if missing:
            probs += pack(f"{f}: its map rows leave out ", missing, ", which can reach it")
    return probs + prose(m, files)


def fail(problem, out=sys.stdout, where=""):
    """One catalog line per piece: a problem longer than the catalog keeps is split, `where` ends every piece."""
    text = esc(problem)
    parts = [text] if len(text) + len(where) <= LIMIT else textwrap.wrap(
        text, LIMIT - len(where) - len("(part 99 of 99) "), break_on_hyphens=False, drop_whitespace=False)
    for i, part in enumerate(parts, 1):
        part = part if len(parts) == 1 else f"(part {i} of {len(parts)}) {part}"
        print("STL-CFG-310 " + alert_catalog.render("STL-CFG-310", {"problem": part + where})[0].split("\n")[1], file=out)   # the plain message line


def complain(probs, out=sys.stdout):
    where = WHERE
    if len(where) > LIMIT // 2:
        fail(f"the problems below are in the root {ROOT}, from STELLA_ROOT", out)
        where = ""
    for p in probs:
        fail(p, out, where)


def main(argv):
    if argv == ["check"]:
        probs = check()
        complain(probs)
        if not probs:
            print("test map ok" + WHERE)
        return 1 if probs else 0
    if argv[:1] == ["select"]:
        files, as_json = argv[1:], argv[1:2] == ["--json"]   # only the first argument may be an option
        files = files[as_json:]
        files = files[files[:1] == ["--"]:]   # "--" ends the options; every later argument is a name
        try:
            if files == ["-"]:
                sys.stdin.reconfigure(newline="")   # no CR translation, no strip: white space at either end selects full
                files = [f for f in sys.stdin.read().split("\n") if f]
            # no file name at all (an empty stdin, no argument) is a failed diff, not "nothing changed": the full suite
            sel = select(files) if files else {"full": True, "reason": ["no file name given"], "targets": sorted(load()["always"])}
        except Exception as e:
            complain([f"{MAP}: {type(e).__name__}: {e}"], sys.stderr)
            return 1
        if os.environ.get("STELLA_ROOT"):
            sel["root"] = ROOT
            if not sel["full"]:   # a narrow answer from another tree must say so; "full" runs everything whatever the tree
                print(f"selected from the test map of {esc(ROOT)}, from STELLA_ROOT", file=sys.stderr)
        print(json.dumps(sel) if as_json else "full" if sel["full"] else "\n".join(sel["targets"]))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
