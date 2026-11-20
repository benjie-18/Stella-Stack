#!/usr/bin/env python3
"""The scheduled full-suite run of the QA loop (phase Q1 item C2; design.md C2, copy rule DG-7), stdlib only. Engine side, host
only: refuses in a worker environment (STL-CFG-312) before anything is read or parsed.
  tick --repo PATH [--now T]   does nothing (exit 0, no line) until full_suite.interval_s of .stella/qa-loop.json has passed since
       this repo's last trusted qa.full-run line (none yet: it runs). Then the full suite runs on the repo's HEAD in a disposable
       copy (qa_loop.make_copy: a standalone clone under qa_copies, hooks off, removed after the run) through bin/qa_tests.py's box
       (qa_tests.run: no network, only the copy writable, killed at full_suite.timeout_s). The suite's argv is the "runner" of
       .stella/test-map.json (bin/test-map.py load), run at the copy's root with no argument; with test names it runs only those.
       On a failure the failing tests (the runner's "FAIL <name>" lines) are bisected over the done hashes since the last green
       run: the qa.passed hash (qa_loop.state) of each card not reopened since, that is an ancestor of HEAD and not of the last
       green head, in commit order; each step runs only the failing tests in a fresh copy of that hash. The first hash where
       they fail is the culprit: one trusted qa.reopened {card, hash, tests} per card done on it (qa_loop.state then gives done
       false for it). Then one trusted qa.full-run {repo, head, result, failing, last_green, culprit, reopened} (what = the
       repo's real path) per run, pass or fail.
Output: JSON on stdout. Exit 0 (ran, or not due yet); 1 refused or a red suite no done card explains (catalog code, plain message
and one alert line; the qa.full-run line is written first); 2 usage. One tick at a time per stack (a lock under qa_copies)."""
import os, sys

if __name__ == "__main__" and not sys.flags.isolated:   # run directly: PYTHONPATH and the current folder must not decide what is imported
    try:
        os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
    except OSError:
        sys.exit("STL-CFG-310 qa_schedule.py could not restart itself isolated (python3 -I); nothing was done")

import argparse, importlib.util, json, re, shutil, time

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import event_log as el
import qa_loop as ql
import qa_tests as qt
import stella_data as sd

DATA, REPO, RED, COPY, FAILED = (f"STL-QA-{n}" for n in range(210, 215))
RUN, REOPENED = "qa.full-run", "qa.reopened"
SCOPE = "_full-suite"   # the copies' folder under qa_copies: a card id starts with a letter or digit, so no card shares it
FAIL = re.compile(r"^FAIL (\S+)", re.M)   # the runner's line for a failing test; it takes the name back to run only that test


class Stop(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def runner():
    """The suite's argv[0] relative to a copy's root: the test map's runner, read by bin/test-map.py's own loader."""
    try:
        spec = importlib.util.spec_from_file_location("test_map", os.path.join(BIN, "test-map.py"))
        tm = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(tm)
        r = os.path.normpath(tm.load()["runner"])
    except Exception as e:
        raise Stop(DATA, f"the test map's runner cannot be read ({str(e)[:160] or type(e).__name__})") from None
    if os.path.isabs(r) or r.split(os.sep)[0] == "..":
        raise Stop(DATA, "the test map's runner is not a path inside the repository")
    return r


def when(v):
    """Epoch seconds of v (epoch seconds or ISO-8601 UTC), or None."""
    try:
        return float(v)
    except (TypeError, ValueError):
        return qt.expiry(v)


def suite(repo, h, n, rel, d, names=()):
    """(exit code or None at the timeout kill, failing test names) of the runner on h in a fresh copy, removed after."""
    try:
        copy, _ = ql.make_copy(repo, h, SCOPE, n, d)
    except ql.Refuse as e:
        raise Stop(COPY, f"the copy of {h[:12]}: {e.problem}"[:200]) from None
    try:
        rc, out = qt.run(copy, [os.path.join(copy, rel), *names], d.qa["full_suite"]["timeout_s"])
    finally:
        shutil.rmtree(copy, ignore_errors=True)
    return rc, sorted(set(FAIL.findall(out)))


def done_hashes(repo, head, green, d):
    """{hash: [cards]} in commit order: each card's passed hash (not reopened since) that HEAD has and the last green head has not."""
    def order(*exclude):
        r = ql.git(["rev-list", "--topo-order", "--reverse", head, *exclude, "--"], repo, d)
        return r.stdout.split() if r.returncode == 0 else None
    pos = order(f"^{green}") if green else None
    pos = {h: i for i, h in enumerate(pos if pos is not None else order() or [])}   # a green head gone from the history bounds nothing
    by = {}
    for card in dict.fromkeys(l.get("what") for l in el.proof_lines() if l.get("type") == ql.CLOSE[0]):
        # shortcut: one fold (a read of the log) per card ever passed; index the cards by hash when the log grows large
        s = ql.state(card, d) if isinstance(card, str) else None
        if s and s["passed"] and not s["reopened"] and s["passed"]["hash"] in pos:
            by.setdefault(s["passed"]["hash"], []).append(card)
    return {h: by[h] for h in sorted(by, key=pos.get)}


def tick(o, d):
    repo = os.path.realpath(o.repo)
    now = time.time() if o.now is None else when(o.now)
    if now is None:
        raise Stop(REPO, "--now is neither epoch seconds nor an ISO-8601 UTC time")
    r = ql.git(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], repo, d) if os.path.isdir(repo) else None
    head = r.stdout.strip() if r and r.returncode == 0 else ""
    if not ql.HASH.fullmatch(head):
        raise Stop(REPO, f"{o.repo[:120]} is not a git repository with a commit checked out")
    rel = runner()
    top = el.path(d.idx["qa_copies"])
    with el.locked(os.path.join(top, SCOPE + ".lock")):   # a tick that waited here sees the run before it and is not due
        runs = [(l.get("time"), ql.payload(l, d.envelope)) for l in el.proof_lines() if l.get("type") == RUN and l.get("what") == repo]
        last = when(runs[-1][0]) if runs else None
        if last is not None and now - last < d.qa["full_suite"]["interval_s"]:
            return {"ran": False, "repo": repo, "due": last + d.qa["full_suite"]["interval_s"]}, None
        green = next((p.get("head") for _, p in reversed(runs) if p.get("result") == "pass"), None)
        rc, failing = suite(repo, head, "head", rel, d)
        new = {"repo": repo, "head": head, "result": "pass" if rc == 0 else "timeout" if rc is None else "fail",
               "failing": failing[:ql.CAP], "last_green": green, "culprit": None, "reopened": []}
        problem = None
        if rc != 0 and not failing:
            problem = f"the full suite on {head[:12]} ended {new['result']} without naming a failing test, so nothing was bisected"
        elif rc != 0:
            cands = done_hashes(repo, head, green, d)
            hs, lo, hi, tests = list(cands), -1, len(cands), failing
            while hi - lo > 1:   # the first done hash where the failing tests fail; the last green head (lo) passed them
                mid = (lo + hi) // 2
                mrc, mf = suite(repo, hs[mid], f"bisect-{mid}", rel, d, failing)
                lo, hi, tests = (mid, hi, tests) if mrc == 0 else (lo, mid, mf or failing)
            if hi == len(hs):
                problem = f"the failing tests ({', '.join(failing[:5])}) fail on {head[:12]} but on no done card's hash since the last green run"
            else:
                new.update(culprit=hs[hi], reopened=cands[hs[hi]])
                for card in cands[hs[hi]]:
                    el.append(el.build(REOPENED, card, new={"card": card, "hash": hs[hi], "tests": tests[:ql.CAP]}))
        el.append(el.build(RUN, repo, new=new))
        return {"ran": True, **new}, problem


def main(argv):
    try:   # before the arguments: in a worker environment every call is refused the same way
        el.owner_only()
    except el.EventError as e:
        return el.fail(e.code, e.problem)
    ap = argparse.ArgumentParser(prog="qa_schedule.py", description="The scheduled full-suite run with bisection (host only).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("tick")
    t.add_argument("--repo", required=True)
    t.add_argument("--now", help="epoch seconds or ISO-8601 UTC (default: the clock)")
    t.add_argument("--json", action="store_true", help="the output is JSON in any case")
    o = ap.parse_args(argv)
    try:
        out, problem = tick(o, ql.data())
        print(json.dumps(out))
        return el.fail(RED, problem) if problem else 0
    except Stop as e:
        code, problem = e.code, e.problem
    except (qt.Stop, el.EventError) as e:
        code, problem = e.code, e.problem
    except sd.DataError as e:
        code, problem = DATA, str(e)[:180]
    except Exception as e:   # never a traceback: the type only
        code, problem = FAILED, f"unexpected {type(e).__name__}"
    return el.fail(code, problem)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
