#!/usr/bin/env python3
"""Test map (product rule 8), stdlib only: the lint over .stella/test-map.json and the selection of test targets.
CLI: test-map.py check                      lint: exit 1 and one STL-CFG-310 line per problem
     test-map.py select [--json] <file>...  the selftests a change to these files can affect ("-" reads names from stdin);
                                            prints "full" (exit 0) when the whole suite must run, else one target per line
The stack root is the parent of this file's folder, or STELLA_ROOT (a scratch root in tests; `check` then names the root).
check fails when: the map is unreadable, repeats a key or breaks its schema; a selftest is not a target of any row; a
target or an always gate has no selftest file; a selftest is missing from the suite list of the runner (or the list
cannot be read); a suite selftest is not executable, on disk or in the mode git records; a file that looks like a test
(test_like) is neither a suite selftest nor listed in not_tests; or a selftest can reach a file (see reach) whose
selection leaves that selftest out.
select: a file on the full list, or matched by no row, selects the full suite. `scan` rows add targets (a selftest that
reads a whole folder) but do not count as a match. Pass both sides of a rename (`git diff --name-only --no-renames`):
the new path alone can narrow the selection."""
import fnmatch, json, os, re, subprocess, sys

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


def load():
    with open(os.path.join(ROOT, MAP), encoding="utf-8") as f:
        m = json.load(f, object_pairs_hook=no_repeats)
    with open(SCHEMA, encoding="utf-8") as f:
        errs = stella_data.validate_doc(m, json.load(f))
    if not errs and type(m["schema_version"]) is not int:
        errs = ["$.schema_version: must be the integer 1"]   # true and 1.0 equal 1 in Python
    if errs:
        raise ValueError("; ".join(errs))
    return m


def matches(f, globs):
    return any(fnmatch.fnmatchcase(f, g) for g in globs)


def tree():
    """{path: the mode git records, or None} for every file of the root: git's list (tracked and untracked, ignored
    files left out) when the root is a git tree, else a walk."""
    if not os.path.exists(os.path.join(ROOT, ".git")):
        return {os.path.relpath(os.path.join(d, f), ROOT): None for d, _, fs in os.walk(ROOT) for f in fs}
    def git(*args):
        return subprocess.run(["git", "-C", ROOT, "ls-files", "-z", *args], capture_output=True, text=True, check=True).stdout.split("\0")
    files = dict.fromkeys(filter(None, git("-co", "--exclude-standard")))
    for line in filter(None, git("-s")):
        files[line.split("\t", 1)[1]] = line.split()[0]
    return {f: mode for f, mode in files.items() if os.path.isfile(os.path.join(ROOT, f))}


def words(text):
    return {w.strip(".") for w in re.findall(r"[\w.-]+", text)}


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
            try:
                with open(os.path.join(ROOT, f), encoding="utf-8") as fh:
                    text = fh.read()
            except (OSError, UnicodeDecodeError):
                text = ""
            named[f] = set()
            if text.startswith("#!") or matches(f, m["follow"]):
                text = re.sub(r"(?m)^[ \t]*#(?!!).*$", "", text)
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
        f = os.path.normpath(f)
        if matches(f, m["full"]):
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
        m = load()
    except Exception as e:
        return [f"{MAP}: {type(e).__name__}: {e}"]
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
            probs.append(f"{f}: its map rows leave out {', '.join(missing)}, which can reach it")
    return probs


def fail(problem, out=sys.stdout):
    print("STL-CFG-310 " + alert_catalog.render("STL-CFG-310", {"problem": problem})[0].split("\n")[1], file=out)   # the plain message line


def main(argv):
    if argv == ["check"]:
        probs = check()
        for p in probs:
            fail(p)
        if not probs:
            print("test map ok" + (f" (root {ROOT}, from STELLA_ROOT)" if os.environ.get("STELLA_ROOT") else ""))
        return 1 if probs else 0
    if argv[:1] == ["select"]:
        files = [a for a in argv[1:] if a != "--json"]
        try:
            if files == ["-"]:
                files = [line.strip() for line in sys.stdin if line.strip()]
                sel = select(files) if files else {"full": True, "reason": ["no file name on stdin"], "targets": sorted(load()["always"])}
            else:
                sel = select(files)
        except Exception as e:
            fail(f"{MAP}: {type(e).__name__}: {e}", sys.stderr)
            return 1
        print(json.dumps(sel) if "--json" in argv else "full" if sel["full"] else "\n".join(sel["targets"]))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
