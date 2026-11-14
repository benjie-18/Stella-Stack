#!/usr/bin/env python3
"""Test map (product rule 8), stdlib only: the lint over .stella/test-map.json and the selection of test targets.
CLI: test-map.py check                           lint: exit 1 and one STL-CFG-310 line per problem
     test-map.py quick                           the quick tier (the "quick" list of the map), one suite name per line; any
                                                 failure is exit 1 and one plain line on stderr, never an empty answer
     test-map.py select [--json] [--] <file>...  the selftests a change to these files can affect ("-" alone reads names
                                                 from stdin, one per line); prints "full" (exit 0) when the whole suite
                                                 must run, else one target per line. Only the first argument may be an
                                                 option; "--" ends the options.
The stack root is the parent of this file's folder, or STELLA_ROOT (a scratch root in tests; made absolute once, so
a relative one means the same to git as to this tool). Under STELLA_ROOT every
`check` line ends with the root (a root too long for that is named once, first), a narrow `select` names it on stderr,
and `select --json` has a `root` key. A problem longer than the catalog keeps is split into numbered parts, and a long
list of selftests into whole lines: nothing is cut. git runs with no global, system or XDG config, no ignore list but
the tree's .gitignore files, the work tree given and no fsmonitor program (only the caller's safe.directory is kept).
shortcut: an untracked .gitignore, or an untracked folder that is a repository of its own, still hides untracked files
from check (a tracked file is always listed); upgrade when check may not trust the working tree it runs in.
check fails when: a quick entry is not in the suite list; the map is unreadable, repeats a key or breaks its schema; a selftest is not a target of any row; a
target or an always gate has no selftest file; a selftest is missing from the suite list of the runner (or the list
cannot be read); a suite selftest is not executable, on disk or in the mode git records; a file that looks like a test
(test_like) is neither a suite selftest nor listed in not_tests; a selftest can reach a file (see reach) whose
selection leaves that selftest out; a row that is not a scan row has a glob that does not start with a literal first
path component (see loose: such a glob matches paths under names the map does not spell); a row that, for a file it
matches, adds no target beyond the always gates and the scan rows matching that file, matches more than prose (see
prose); a file a row matches has a name select never narrows; or a tracked file is matched by no row (and is not on
the full list, which the stack ships empty); a selftest without a mark, a mark for no selftest, a shared mark with no why, a mark that is
not {mark: hermetic or shared, why: text} (a coded line, even under a schema file that checks nothing); or two selftest names (marks, row
targets, always gates, selftest files, suite list) that differ only in case.
Marks (lock scope, the owner's rule): the map's `marks` gives every selftest hermetic or shared. Hermetic = the selftest touches no live
state outside its own scratch root and the runner's copy (no live board, no installed Hermes, no real ~/.hermes, no live owner settings
file, no write into the real home): it may run outside the test lock. Shared = anything else, with a `why` that is true under the runner
(bin/selftests.sh binds each copy over /workspace, so a reason naming a path the runner already isolates is not true there). An
unmarked selftest counts as shared. `select --json` has `shared`: the selftests that run and are not hermetic, so the ones that need the
lock: the selected targets, or on a full answer every selftest of the suite (the runner's suite list, else the selftest files). When
select could not trust what it read (an unreadable map or schema, a map of the wrong shape) no mark counts: every name is shared, and
with no suite to name the answer is ["*"], never [].
select: full is the answer for an input or a map that cannot be trusted; for a tracked file of a checked tree only when
the stack put it on the full list (shipped empty; matched without regard to case). A file matched by no row selects
the full suite (check refuses a tracked one, and a file with a row whose name select never narrows); so does no file
name at all. The map, its schema and this tool select their rows' targets like any other file: safe, because select
itself adds this tool's selftest to every narrow answer (below), and that selftest runs `check`, which refuses a map
whose rows leave out a selftest that reaches a file. `scan` rows add targets (a selftest that reads a whole folder) but do not count as a match. Pass
both sides of a rename (`git diff --name-only --no-renames`): the new path alone can narrow the selection. A name with
white space (at either end too, on stdin as well), a control character (U+0000 to U+001F, U+007F to U+009F), a leading
dash or bytes that are not UTF-8 selects the full suite. A narrow answer always holds this tool's own selftest (named
from this file's name and test_file) when the root has it, whatever the map says, so a map cannot drop the gate that
runs `check`; in the tool's own tree a missing selftest of the tool is the answer full. select checks itself the shape
of what it reads (always, full, globs and targets are lists of names), whatever the schema file accepts. Whatever stops select before it has an answer IS the answer full (exit 0 like every full answer,
so a caller that pipes the answer into a runner runs everything; the plain reason on stderr; with --json `full` true,
the reason and no targets): names on stdin that cannot be read, a map or a schema (each named as itself) that is missing, unreadable, a
folder or other non-regular file, empty, not JSON, no object or against its schema, a module of this tool that is missing
or broken, a root that does not exist, any other error. select also
answers full when the map breaks the rule that needs no file list (loose), and when the selection would be empty. The
answer is written to stdout first and alone; the diagnostics follow on stderr and are dropped when stderr is closed or
cannot be written. Only a missing python3, or a stdout that cannot be written, gives no answer (and a non-zero exit): a
caller treats a non-zero exit or an empty answer as full. Run
directly (no -I), the tool restarts itself under `python3 -I`, so PYTHONPATH and the current folder do not decide what
it imports. shortcut: a file planted in this tool's own folder under a standard module's name is still imported;
upgrade with the boundary rule for that folder. shortcut: the rules that need the file list (prose, reach, selftests, suite list, modes) are
left to `check` (about 2 s on the stack tree against 0.05 s for a select), which every narrow selection runs through
this tool's own selftest."""
import fnmatch, json, os, re, subprocess, sys, textwrap

if __name__ == "__main__" and not sys.flags.isolated:   # run directly: PYTHONPATH and the current folder must not decide what is imported
    try:
        os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
    except OSError:
        pass   # no interpreter to restart under: go on as started

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder; this tool's modules are imported where they are used

ROOT = os.path.abspath(os.environ.get("STELLA_ROOT") or os.path.dirname(BIN))   # absolute once: git is sent to the root and would resolve a relative one again
MAP = ".stella/test-map.json"
FALLBACK = ("bin/selftests.sh", "bin/{name}-selftest.sh")   # runner and test_file, for suite() when the map cannot say
SCHEMA = os.path.join(os.path.dirname(BIN), ".stella", "schemas", "test-map.schema.json")   # ships with this tool, so a scratch root needs none


def no_repeats(pairs):
    d = dict(pairs)
    if len(d) != len(pairs):
        raise ValueError("a key is repeated")   # json.load would keep the last one silently
    return d


class Unusable(Exception):
    """Something this tool reads cannot be used; the message starts with its own name (the map, the schema, a module)."""


def read():
    """(map, schema problems); what cannot be used raises Unusable under its own name."""
    name = "a module of this tool (stella_data)"
    try:
        import stella_data   # here, not at the top: select owes its answer even when a module of this tool is missing or broken
        name = MAP
        if os.path.exists(os.path.join(ROOT, MAP)) and not os.path.isfile(os.path.join(ROOT, MAP)):
            raise ValueError("not a regular file")   # a FIFO would hang the open
        with open(os.path.join(ROOT, MAP), encoding="utf-8") as f:
            m = json.load(f, object_pairs_hook=no_repeats)
        name = f"schema {SCHEMA}"
        with open(SCHEMA, encoding="utf-8") as f:
            errs = stella_data.validate_doc(m, json.load(f))
        name = MAP
        if not errs and type(m["schema_version"]) is not int:
            errs = ["$.schema_version: must be the integer 1"]   # true and 1.0 equal 1 in Python
    except Exception as e:
        raise Unusable(f"{name}: {type(e).__name__}: {e}") from None
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
    # the tree's own untracked settings neither hide a file (info/exclude, core.excludesFile, core.worktree) nor run a
    # program (core.fsmonitor, switched off as bin/box.py does)
    def git(*args):
        return subprocess.run(["git", *[x for t in trust for x in ("-c", t)], "-c", "core.fsmonitor=false", "-C", ROOT,
                               f"--work-tree={ROOT}", "ls-files", "-z", *args],
                              capture_output=True, text=True, check=True, env=env).stdout.split("\0")
    files = dict.fromkeys(filter(None, git("-co", "--exclude-per-directory=.gitignore")))
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


def loose(globs):
    """The first glob that does not start with a literal first path component: a folder or top-level file name with no
    wildcard character, not empty, "." or "..". A glob that does can only match paths under the name it spells, so a
    path under a name no row spells (a new folder, a new top-level file) is matched by no such glob, whatever follows."""
    return next((g for g in globs for first in [g.split("/")[0]] if first in ("", ".", "..") or re.search(r"[*?\[]", first)), None)


def shape(m):
    """select reads these whatever the schema file accepts: a string where a list belongs would be read letter by letter."""
    names = lambda v: isinstance(v, list) and all(isinstance(x, str) for x in v)
    if not (isinstance(m, dict) and names(m.get("always")) and names(m.get("full")) and isinstance(m.get("test_file"), str)
            and m["test_file"].count("{name}") == 1 and isinstance(m.get("map"), list)
            and all(isinstance(r, dict) and names(r.get("globs")) and names(r.get("targets")) for r in m["map"])
            and isinstance(m.get("marks", {}), dict) and all(isinstance(v, dict) and v.get("mark") in ("hermetic", "shared") and isinstance(v.get("why", ""), str)
                                                             for v in m.get("marks", {}).values())):
        raise ValueError("always, full, and the globs and targets of every map row must be lists of names, test_file one {name} pattern, "
                         "and marks an object of {mark: hermetic or shared, why: text}")


def suite_list(path):
    """The names of the line `for t in <names>; do` of the runner; raises when the file or the line is not there."""
    with open(path, encoding="utf-8") as fh:
        return set(re.search(r"^for t in (.+); do$", fh.read(), re.M)[1].split())


def suite(m):
    """The selftests the runner would run: its suite list, else the selftest files of the root. When the map cannot name the runner or
    the test file, FALLBACK does; with nothing to go on the answer is {"*"}: every selftest, never none.
    shortcut: FALLBACK spells where this stack keeps its runner and selftests, for a map that cannot be read; upgrade when a second stack layout needs this tool."""
    try:
        pick = lambda k, i: m.get(k) if isinstance(m.get(k), str) else FALLBACK[i]
        try:
            return suite_list(os.path.join(ROOT, pick("runner", 0)))
        except Exception:
            head, tail = pick("test_file", 1).split("{name}")
            return {f[len(head):len(f) - len(tail)] for f in tree() if f.startswith(head) and f.endswith(tail)} or {"*"}
    except Exception:
        return {"*"}


def hermetic(m):
    """The selftests whose mark is exactly hermetic; a marks of another shape marks none (shared is the default)."""
    marks = m.get("marks")
    return {t for t, v in marks.items() if isinstance(v, dict) and v.get("mark") == "hermetic"} if isinstance(marks, dict) else set()


def wide(m):
    """The rule that needs no file list: every glob of a row that is not a scan row starts with a literal first path
    component (loose), so no such row matches a path under a name the map does not spell."""
    return [f"map row {i} ({', '.join(r['globs'])}) {'is not a scan row,' if r['targets'] else 'has no targets'} and its "
            f"glob {loose(r['globs'])} matches every path of a folder or top-level file it does not name: start each glob with a literal folder or file name"
            for i, r in enumerate(m["map"], 1) if not r.get("scan") and loose(r["globs"])]


def prose(m, files, reached):
    """A row is judged file by file: where it adds no target beyond the always gates and the scan rows that match the
    file, the file is selected as by a row with no targets, so it must be prose: refuse a row that so matches code
    (follow, #!), an executable, a test-like file, or a file that a code or data file (the `data` globs; every file when
    the list is empty or missing) names, by the name search reach uses. The exception is the selftest file of a target
    the row names, and that selftest's tool: the file named like the target beside it (bin/test-map.py for
    bin/test-map-selftest.sh) that the selftest itself names (reached). One problem per row; a loose glob is wide()'s."""
    scans = [r for r in m["map"] if r.get("scan")]
    adds = lambda r, f: set(r["targets"]) - set(m["always"]) - {t for s in scans if matches(f, s["globs"]) for t in s["targets"]}
    rows = [(i, r, fs) for i, r in enumerate(m["map"], 1) if not r.get("scan") and not loose(r["globs"])
            for fs in [[f for f in sorted(files) if matches(f, r["globs"]) and not adds(r, f)]] if fs]
    if not rows:
        return []
    by_base, named = {}, {}
    for f in files:
        by_base.setdefault(os.path.basename(f), set()).add(f)
    for g in sorted(files):
        text = content(g)
        if g != MAP and (text.startswith("#!") or matches(g, m["follow"]) or matches(g, m.get("data") or ["*"])):
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

    head, tail = m["test_file"].split("{name}")
    path = lambda t: head + t + tail
    probs = []
    for i, r, fs in rows:
        # a target's own files: its selftest, and the tool named like it (bin/{name}.<ext>) that this selftest names
        own = lambda f: any(f == path(t) or (f in reached.get(t, ()) and f.startswith(head + t + ".") and "/" not in f[len(head):])
                            for t in r["targets"])
        bad = next(((f, w) for f in fs if not own(f) for w in [why(f)] if w), None)
        if bad:
            row = f"map row {i} ({', '.join(r['globs'])}) " + (
                "has no targets" if not r["targets"] else
                f"adds no target beyond the always gates ({', '.join(r['targets'])})" if not set(r["targets"]) - set(m["always"]) else
                f"adds no target ({', '.join(r['targets'])}) for {bad[0]} beyond the always gates and the scan rows that match it")
            probs.append(f"{row}, so it may match only prose, but it matches {bad[0]}: {bad[1]}")
    return probs


def reach(m, files, tests):
    """{selftest: the files it can reach}: its own file, every file it names (by base name, or a Python module by its
    import), and on through each named file that is code (starts with #! or matches a follow glob). Whole-line #
    comments name nothing: without that, one remark in a shared script ties every selftest to the file it mentions.
    shortcut: a name built at run time or a folder read by a glob is not seen, those need a `scan` row or targets found by reading (said in the row's why)."""
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


# several names joined into one (a quoted $(git diff), -z output) would match one narrow row; C0 and C1 controls; a surrogate is a byte that is not UTF-8
ODD = re.compile(r"^-|[\s\x00-\x1f\x7f-\x9f\ud800-\udfff]")


def select(files, m=None):
    m = m or load()
    targets, reason = set(m["always"]), []
    for f in files:
        if ODD.search(f):
            reason.append(f"{f!r}: not one plain file name (white space, a control character, a leading dash or not UTF-8)")
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
    if not targets:
        reason.append("the selection is empty (no always gate, no target), and an empty run proves nothing")
    return {"full": bool(reason), "reason": reason, "targets": sorted(targets)}


def check():
    try:
        m, errs = read()
    except Unusable as e:
        return [str(e)]
    if errs:
        return [f"{MAP}: ValueError: {e}" for e in errs]   # one line per problem
    try:
        shape(m)   # the schema file may let anything through: what check reads below must still be what it expects
    except ValueError as e:
        return [f"{MAP}: ValueError: {e}"]
    probs = wide(m)
    try:
        files = tree()
    except Exception as e:
        return probs + [f"the files of {ROOT} cannot be listed with git: {type(e).__name__}"]
    head, tail = m["test_file"].split("{name}")
    path = lambda t: head + t + tail
    tests = {f[len(head):len(f) - len(tail)]: f for f in files
             if f.startswith(head) and f.endswith(tail) and "/" not in f[len(head):len(f) - len(tail)]}
    if not tests:
        return probs + [f"no selftest ({path('<name>')}) found under {ROOT}"]
    targets = {t for row in m["map"] for t in row["targets"]}
    marks = m.get("marks", {})   # lock scope: an unmarked selftest counts as shared, and the lint refuses it (shape(): an object of {mark, why})
    probs += [f"{tests[t]} has no mark: add it to marks as hermetic, or as shared with its why" for t in sorted(tests.keys() - marks.keys())]
    probs += [f"mark for {t}: no such selftest ({path(t)})" for t in sorted(marks.keys() - tests.keys())]
    probs += [f"shared mark of {t} gives no why" for t in sorted(marks) if marks[t]["mark"] == "shared" and not marks[t].get("why", "").strip()]
    probs += [f"{tests[t]} is not a target of any map row" for t in sorted(tests.keys() - targets)]
    probs += [f"target {t}: {path(t)} does not exist" for t in sorted((targets | set(m["always"])) - tests.keys())]
    # shortcut: a test is known by its name only (test_like globs), a test named otherwise is not seen; upgrade when a second test runner arrives
    probs += [f"{f} looks like a test but is neither a suite selftest nor listed in not_tests" for f in sorted(files)
              if f not in tests.values() and matches(f.lower(), m["test_like"]) and not matches(f, m["not_tests"])]
    probs += [f"{f}: no map row matches this tracked file; add a row whose targets are the selftests that use it (when unsure, "
              "its folder's tests: the targets of the other rows of its folder)" for f, mode in sorted(files.items())
              if mode and not any(matches(f, r["globs"]) for r in m["map"] if not r.get("scan"))
              and not matches(f.lower(), [g.lower() for g in m["full"]])]
    try:
        runs = suite_list(os.path.join(ROOT, m["runner"]))
    except Exception:
        return probs + [f"the suite list of {m['runner']} cannot be read (expected one line: for t in <names>; do)"]
    probs += [f"{tests[t]} is not in the suite list of {m['runner']}" for t in sorted(tests.keys() - runs)]
    probs += [f"suite entry {t}: {path(t)} does not exist" for t in sorted(runs - tests.keys())]
    probs += [f"quick entry {t} is not in the suite list of {m['runner']}" for t in m["quick"] if t not in runs]
    # one name, one selftest: the stack's mount ignores case, so two names that differ only in case can be one file, marked twice (once hermetic)
    folded = {}
    for t in marks.keys() | targets | set(m["always"]) | tests.keys() | runs:
        folded.setdefault(t.casefold(), set()).add(t)
    probs += [f"selftest names {' and '.join(sorted(ns))} differ only in case: a filesystem that ignores case runs one file for both, so one name each" for ns in folded.values() if len(ns) > 1]
    for t in sorted(runs & tests.keys()):   # the suite runs each file directly
        if not os.access(os.path.join(ROOT, tests[t]), os.X_OK):
            probs.append(f"{tests[t]} is not executable")
        elif files[tests[t]] not in (None, "100755"):
            probs.append(f"{tests[t]} is not executable in git (mode {files[tests[t]]}): a fresh checkout cannot run it")
    reached = reach(m, files, tests)
    for f in sorted(files):
        if ODD.search(f) and any(matches(os.path.normpath(f), r["globs"]) for r in m["map"] if not r.get("scan")):
            probs.append(f"{f}: a row matches this file, but select never narrows such a name (white space, a control character "
                         "or a leading dash): every change to it would select the full suite; rename the file")
        sel = select([f], m)
        missing = [] if sel["full"] else sorted(t for t in tests if f in reached[t] and t not in sel["targets"])
        if missing:
            probs += pack(f"{f}: its map rows leave out ", missing, ", which can reach it")
    return probs + prose(m, files, reached)


def fail(problem, out=sys.stdout, where=""):
    """One catalog line per piece: a problem longer than the catalog keeps is split, `where` ends every piece."""
    text, parts, n = esc(problem), [esc(problem)], 9
    while len(text) + len(where) > LIMIT:   # leave room for the widest prefix "(part n of n) " the real count needs
        parts = textwrap.wrap(text, LIMIT - len(where) - len(f"(part {n} of {n}) "), break_on_hyphens=False, drop_whitespace=False)
        if len(parts) <= n:
            break
        n = n * 10 + 9
    for i, part in enumerate(parts, 1):
        part = part if len(parts) == 1 else f"(part {i} of {len(parts)}) {part}"
        line = part + where   # what goes out when the catalog module or its list is missing or broken: the problem itself
        try:
            import alert_catalog
            text = alert_catalog.render("STL-CFG-310", {"problem": line})[0].split("\n")[1]   # the plain message line
            line = text if line in text else line
        except Exception:
            pass
        print("STL-CFG-310 " + line, file=out)


def complain(probs, out=sys.stdout):
    where = WHERE
    if probs and len(where) > LIMIT // 2:
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
    if argv == ["quick"]:
        try:
            q = load()["quick"]
            if not q:
                raise ValueError("the quick list is empty")
        except Exception as e:
            print(f"test-map.py quick: the quick list cannot be read: {e}", file=sys.stderr)
            return 1
        print("\n".join(q))
        return 0
    if argv[:1] == ["select"]:
        files, as_json = argv[1:], argv[1:2] == ["--json"]   # only the first argument may be an option
        files = files[as_json:]
        ended = files[:1] == ["--"]
        files = files[ended:]   # "--" ends the options; every later argument is a name, "-" too
        what, notes, m, trust = "the file names on stdin cannot be read", [], {}, True   # what was being done, for the reason; the diagnostics; whether the marks may be read
        try:   # the one rule: whatever stops select before it has an answer IS the answer full, never an empty selection
            if files == ["-"] and not ended:   # bytes: no CR translation, no strip (white space at either end selects full); a non-UTF-8 byte stays visible
                files = [f for f in sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\n") if f]
            what = MAP
            m = load()
            shape(m)
            what = "the selection could not be made"
            # no file name at all (an empty stdin, no argument) is a failed diff, not "nothing changed": the full suite
            sel = select(files, m) if files else {"full": True, "reason": ["no file name given"], "targets": sorted(m["always"])}
            broken = wide(m)
            if broken:   # a map that fails check cannot narrow anything
                notes += broken
                sel["full"], sel["reason"] = True, sel["reason"] + [f"the map fails check: {p}" for p in broken]
            if not sel["full"]:   # a narrow answer holds this tool's own selftest, which runs check: no map can drop its gate
                gate = os.path.splitext(os.path.basename(__file__))[0]
                mine = m["test_file"].replace("{name}", gate)
                if os.path.isfile(os.path.join(ROOT, mine)):
                    sel["targets"] = sorted({*sel["targets"], gate})
                elif os.path.realpath(ROOT) == os.path.realpath(os.path.dirname(BIN)):   # a scratch root has no selftest of this tool
                    raise ValueError(f"{mine}, the selftest of this tool, is missing from its own tree, so nothing would check the map")
        except Exception as e:
            sel = {"full": True, "reason": [str(e) if isinstance(e, Unusable) else f"{what}: {type(e).__name__}: {e}"], "targets": []}
            notes += sel["reason"]
            trust = False   # whatever stopped select, nothing it read says which selftest may skip the lock
        # the selftests that need the lock: those run (the targets, or the whole suite when the answer is full) and not marked hermetic
        sel["shared"] = sorted((set(sel["targets"]) | (suite(m) if sel["full"] else set())) - (hermetic(m) if trust else set()))
        if os.environ.get("STELLA_ROOT"):
            sel["root"] = ROOT
        print(json.dumps(sel) if as_json else "full" if sel["full"] else "\n".join(sel["targets"]))
        sys.stdout.flush()   # the answer first and alone; a diagnostic that cannot be written is dropped
        try:
            if sys.stderr:   # closed (2>&-): print would fall back to stdout and spoil the answer
                complain(notes, sys.stderr)
                if "root" in sel and not sel["full"]:   # a narrow answer from another tree must say so; "full" runs everything whatever the tree
                    print(f"selected from the test map of {esc(ROOT)}, from STELLA_ROOT", file=sys.stderr)
                sys.stderr.flush()
        except Exception:
            pass
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
