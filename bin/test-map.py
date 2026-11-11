#!/usr/bin/env python3
"""Test map (product rule 8), stdlib only: the lint over .stella/test-map.json and the selection of test targets.
CLI: test-map.py check                      lint: exit 1 and one line per problem when the map and the tests disagree
     test-map.py select [--json] <file>...  the selftests a change to these files can affect ("-" reads names from stdin);
                                            prints "full" (exit 0) when the whole suite must run, else one target per line
The stack root is the parent of this file's folder, or STELLA_ROOT (a scratch root in tests).
check fails when: the map is unreadable or not schema_version 1; a bin/*-selftest.sh is not a target of any row; a target
or an always gate has no selftest file; a selftest is missing from the suite list of bin/selftests.sh (or the list cannot
be read); a suite selftest is not executable (the suite runs each file directly)."""
import fnmatch, glob, json, os, re, sys

ROOT = os.environ.get("STELLA_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAP = os.path.join(ROOT, ".stella", "test-map.json")
SUFFIX = "-selftest.sh"


def load():
    m = json.load(open(MAP, encoding="utf-8"))
    if m.get("schema_version") != 1:
        raise ValueError(f"schema_version {m.get('schema_version')!r} is not 1")
    for key in ("always", "full", "map"):
        if not isinstance(m.get(key), list):
            raise ValueError(f"{key} must be a list")
    for row in m["map"]:
        if not (isinstance(row, dict) and isinstance(row.get("globs"), list) and row["globs"]
                and isinstance(row.get("targets"), list)):
            raise ValueError(f"a map row needs a non-empty globs list and a targets list: {row!r}")
    return m


def check():
    try:
        m = load()
    except Exception as e:
        return [f"{MAP}: {type(e).__name__}: {e}"]
    probs = []
    files = {os.path.basename(f)[:-len(SUFFIX)] for f in glob.glob(os.path.join(ROOT, "bin", "*" + SUFFIX))}
    targets = {t for row in m["map"] for t in row["targets"]}
    probs += [f"bin/{t}{SUFFIX} is not a target of any map row" for t in sorted(files - targets)]
    probs += [f"target {t}: bin/{t}{SUFFIX} does not exist" for t in sorted((targets | set(m["always"])) - files)]
    try:
        runner = open(os.path.join(ROOT, "bin", "selftests.sh"), encoding="utf-8").read()
        suite = set(re.search(r"^for t in (.+); do$", runner, re.M)[1].split())
    except Exception:
        return probs + ["the suite list of bin/selftests.sh cannot be read (expected one line: for t in <names>; do)"]
    probs += [f"bin/{t}{SUFFIX} is not in the suite list of bin/selftests.sh" for t in sorted(files - suite)]
    probs += [f"suite entry {t}: bin/{t}{SUFFIX} does not exist" for t in sorted(suite - files)]
    probs += [f"bin/{t}{SUFFIX} is not executable" for t in sorted(suite & files)
              if not os.access(os.path.join(ROOT, "bin", t + SUFFIX), os.X_OK)]
    return probs


def select(files):
    m = load()
    targets, reason = set(m["always"]), []
    for f in files:
        f = os.path.normpath(f)
        if any(fnmatch.fnmatchcase(f, g) for g in m["full"]):
            reason.append(f"{f}: a shared contract (full list)")
            continue
        rows = [row for row in m["map"] if any(fnmatch.fnmatchcase(f, g) for g in row["globs"])]
        if not rows:
            reason.append(f"{f}: no map row matches")
        for row in rows:
            targets.update(row["targets"])
    return {"full": bool(reason), "reason": reason, "targets": sorted(targets)}


def main(argv):
    if argv[:1] == ["check"] and len(argv) == 1:
        probs = check()
        print("\n".join(probs) if probs else "test map ok")
        return 1 if probs else 0
    if argv[:1] == ["select"]:
        args = argv[1:]
        as_json = "--json" in args
        files = [a for a in args if a != "--json"]
        if files == ["-"]:
            files = [line.strip() for line in sys.stdin if line.strip()]
        try:
            sel = select(files)
        except Exception as e:
            print(f"{MAP}: {type(e).__name__}: {e}", file=sys.stderr)
            return 1
        print(json.dumps(sel) if as_json else "full" if sel["full"] else "\n".join(sel["targets"]))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
