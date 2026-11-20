#!/usr/bin/env python3
"""QA tests (phase Q1 item C1; design.md C1, rulings DG-6, DG-7, DG-9), stdlib only, host only (STL-CFG-312 in a worker
environment). Every command runs the card's tests ({id, argv} JSON, argv never a shell string) in the copy the caller names: a
directory under the index key qa_copies (the caller made it; refused anywhere else), each argv with that copy as its working
folder, a private HOME and TMPDIR, killed at tests.timeout_s of .stella/qa-loop.json, in a box (see box_argv below). State goes
out as one trusted line through bin/event_log.py; nothing here reads the untrusted stream.
  baseline    --card C --copy DIR --tests J   qa.base-failures {tests: [failing ids], classes}: tests failing on the base copy,
              never charged to the builder.
  tests-first --card C --copy DIR --tests J   each test must fail on the base copy with a class of kind assertion; a pass, an
              error class (whatever else matched) or the runner's timeout kill refuses it (DG-6): qa.tests-first {accepted, refused}.
  flaky       --card C --copy DIR --test J    reruns the test alone tests.reruns times in DIR; mixed results: qa.flaky, then a
              quarantine row {test, card, expires} in qa_quarantine (atomic, under a lock) that bin/test-map.py select honours. Never
              for a tests-first test of the same card (DG-9): that one stays a blocking finding. No round is used.
  mutants     --card C --copy DIR --file F --test J   the test must pass on the copy; then each operator of mutants.operators is
              applied to the first line of F holding its find text, each in a fresh copy (no bytecode carried), up to
              mutants.cap_per_card applications counted over the card's trusted qa.mutants lines. qa.mutants {test, file, applied};
              a surviving mutant is a qa.finding of kind test against the test (status confirmed; the mildest severity that blocks
              on every tier). DIR is never changed.
J is a JSON file: a list of {id, argv} (--tests) or one {id, argv} (--test). Output: JSON on stdout.
Exit: 0 done (refusals of single tests are recorded, not errors); 1 refused (the catalog code and its plain message on stderr,
nothing written); 2 usage."""
import os, sys

if __name__ == "__main__" and not sys.flags.isolated:   # run directly: PYTHONPATH and the current folder must not decide what is imported
    try:
        os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
    except OSError:
        sys.exit("STL-CFG-310 qa_tests.py could not restart itself isolated (python3 -I); nothing was done")

import argparse, calendar, hashlib, json, pwd, re, shutil, signal, stat, subprocess, tempfile, time, uuid

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import box
import event_log as el
import roles
import stella_data as sd
import worker_env

DATA, INPUT, COPY, NOBOX, NOPASS, QUAR = (f"STL-QA-{n}" for n in range(180, 186))
ROW, ROUTING = "qa_loop", "routing"
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:@+/-]{0,199}")   # a test id: no white space, no leading dash
CARD = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,99}")   # a card id is also a folder name under qa_copies
MAX_JSON, MAX_TESTS, MAX_ARGV, MAX_ARG, MAX_OUT = 1 << 20, 500, 200, 8192, 1 << 20   # shortcut: input and output caps in code, move to qa-loop.json when an owner needs to tune them


class Stop(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def data():
    try:
        rows = {r["id"]: r for r in sd.rows()}
        q, r = (sd.checked(sd.load(rows[i]["path"]), rows[i]["path"], rows[i]["schema"]) for i in (ROW, ROUTING))
        return q, [t["id"] for t in r["task_tiers"]]
    except (sd.DataError, KeyError, TypeError) as e:
        raise Stop(DATA, f"the QA loop data cannot be used: {str(e)[:160] or 'no index row'}") from None


def index_path(key):
    try:
        return el.path(sd.load(sd.INDEX)[key])
    except (sd.DataError, KeyError, ValueError) as e:
        raise Stop(DATA, f"the index key {key} cannot be used: {str(e)[:160]}") from None


def read_json(p):
    """The JSON value of the file p (by value: read once, a regular file, at most MAX_JSON bytes)."""
    try:
        fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                raise ValueError("not a regular file")
            raw = f.read(MAX_JSON + 1)
        if len(raw) > MAX_JSON:
            raise ValueError(f"larger than {MAX_JSON} bytes")
        return json.loads(raw)
    except (OSError, ValueError, RecursionError) as e:
        raise Stop(INPUT, f"{p} cannot be read as JSON ({el.why(e) if isinstance(e, OSError) else e})"[:200]) from None


def test_of(t):
    ok = (isinstance(t, dict) and isinstance(t.get("id"), str) and NAME.fullmatch(t["id"]) and isinstance(t.get("argv"), list)
          and 0 < len(t["argv"]) <= MAX_ARGV and all(isinstance(a, str) and 0 < len(a) <= MAX_ARG and "\0" not in a for a in t["argv"]))
    if not ok:
        raise Stop(INPUT, "a test must be {id: a name with no white space, argv: a non-empty list of strings}; a shell string is never run")
    return {"id": t["id"], "argv": list(t["argv"])}


def tests_of(p, one):
    v = read_json(p)
    if one:
        return [test_of(v)]
    if not isinstance(v, list) or not 0 < len(v) <= MAX_TESTS:
        raise Stop(INPUT, f"--tests must name a JSON list of 1 to {MAX_TESTS} tests")
    ts = [test_of(t) for t in v]
    if len({t["id"] for t in ts}) != len(ts):
        raise Stop(INPUT, "two tests of the list have the same id")
    return ts


def copy_dir(p):
    """The real path of a copy: a folder (not a link) strictly inside qa_copies."""
    top = index_path("qa_copies")
    real = os.path.realpath(p)
    if os.path.islink(p) or not os.path.isdir(real) or not el.inside(real, top) or real == top:
        raise Stop(COPY, f"{p} is not a folder inside the QA copies folder ({top}); tests never run anywhere else")
    return real


def hidden():
    """Folders the box shows empty: the stack roots (live and scratch), the homes and /tmp. shortcut: a fixed list, not box.plan's
    walk of owner and secret paths; use box.py exec once it can run a standalone clone (it takes linked worktrees only)."""
    try:
        home = pwd.getpwuid(os.getuid()).pw_dir
    except KeyError:
        home = ""
    xs = {os.path.realpath(x) for x in (el.ROOT, roles.ROOT, home, os.environ.get("HOME", ""), os.environ.get("BOX_HERMES_ROOT", ""), "/tmp") if x}
    xs = {x for x in xs if os.path.isdir(x) and x != "/"}
    return sorted(x for x in xs if not any(o != x and el.inside(x, o) for o in xs))   # a folder inside another is hidden with it


def run(copy, argv, timeout):
    """(exit code or None on the timeout kill, output) of argv in the box, cwd the copy. Stop when the box did not start."""
    # DG-7 asks for box.py exec; it refuses a standalone clone (not a linked worktree), so this box is the house flags (box.BASE)
    # with the stack roots, the homes and /tmp hidden, no network, and only the copy writable.
    cmd = box.BASE + ["--unshare-net"] + [a for x in hidden() for a in ("--tmpfs", x)] + [
        "--dir", "/tmp/qa-home", "--dir", "/tmp/qa-tmp", "--bind", copy, copy, "--chdir", copy,
        "bash", "-c", 'echo started >&"$0" || exit 1; eval "exec $0>&-"; exec "$@"']
    env = {k: os.environ[k] for k in ("PATH", "LANG", "LC_ALL") if k in os.environ}
    env.update(HOME="/tmp/qa-home", TMPDIR="/tmp/qa-tmp", PYTHONDONTWRITEBYTECODE="1")
    sr, sw = os.pipe()
    with tempfile.TemporaryFile() as log:
        try:
            p = subprocess.Popen(cmd + [str(sw), *argv], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=env,
                                 cwd=copy, start_new_session=True, pass_fds=(sw,))
        except OSError as e:
            os.close(sr); os.close(sw)
            raise Stop(NOBOX, f"the box could not be started ({el.why(e)[:100]}); the tests never run outside it") from None
        os.close(sw)
        try:
            rc = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            rc = None
            try:
                os.killpg(p.pid, signal.SIGKILL)   # the box dies with its launcher (--die-with-parent), and every process in it
            except ProcessLookupError:
                pass
            p.wait()
        os.set_blocking(sr, False)
        try:
            started = os.read(sr, 64).startswith(b"started")
        except BlockingIOError:
            started = False
        finally:
            os.close(sr)
        if not started:
            raise Stop(NOBOX, "the box for the tests did not start (bwrap could not make it); the tests never run outside it")
        size, half = log.seek(0, 2), MAX_OUT // 2
        log.seek(0)
        out = log.read(MAX_OUT if size <= MAX_OUT else half)
        if size > MAX_OUT:   # the head and the tail of a long output: a class pattern sits at one end or the other
            log.seek(size - half)
            out += log.read(half)
    return rc, out.decode("utf-8", "replace")


def classify(rc, out, classes):
    """(result, class id or None, kind) by DG-6: the runner's kill is a timeout; else any error class wins; an assertion only
    when no error class matched and an assertion class did; a failure no class names is "unclassified"."""
    if rc is None:
        return "fail", next((c["id"] for c in classes if c["kind"] == "timeout"), "timeout"), "timeout"
    if rc == 0:
        return "pass", None, None
    for kind in ("error", "assertion"):
        c = next((c for c in classes if c["kind"] == kind and (rc in c["exit_codes"] or any(x in out for x in c["patterns"]))), None)
        if c:
            return "fail", c["id"], kind
    return "fail", None, "unclassified"


def run_test(copy, t, q):
    rc, out = run(copy, t["argv"], q["tests"]["timeout_s"])
    res, cid, kind = classify(rc, out, q["tests"]["classes"])
    return {"id": t["id"], "result": res, "class": cid, "kind": kind, "exit": rc}


def payload(d):
    """A trusted line's own fields merged with its detail and new where those are objects."""
    return {**d, **(d["detail"] if isinstance(d.get("detail"), dict) else {}), **(d["new"] if isinstance(d.get("new"), dict) else {})}


def card_lines(card, type_):
    return [payload(d) for d in el.proof_lines() if d.get("type") == type_ and d.get("what") == card]


def write(type_, card, new):
    el.append(el.build(type_, card, new=new))


def cmd_baseline(a, q):
    rs = [run_test(a.copy, t, q) for t in tests_of(a.tests, False)]
    failing = [r for r in rs if r["result"] != "pass"]
    new = {"tests": [r["id"] for r in failing], "classes": {r["id"]: r["class"] or r["kind"] for r in failing}}
    write("qa.base-failures", a.card, new)
    return new


def cmd_tests_first(a, q):
    acc, ref = [], []
    for r in (run_test(a.copy, t, q) for t in tests_of(a.tests, False)):
        if r["kind"] == "assertion":
            acc.append({"id": r["id"], "class": r["class"]})
        else:
            ref.append({"id": r["id"], "class": r["class"], "why": "passes on the base copy" if r["result"] == "pass" else f"fails with a {r['kind']} class, not an assertion"})
    new = {"accepted": acc, "refused": ref}
    write("qa.tests-first", a.card, new)
    return new


def own_tests(card):
    """DG-9: the tests-first tests of the card (accepted or refused) are never quarantined for it."""
    return {x["id"] for p in card_lines(card, "qa.tests-first") for k in ("accepted", "refused") for x in p.get(k) or [] if isinstance(x, dict)}


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def expiry(v):
    """Epoch seconds of an expires value (ISO-8601 UTC or epoch seconds); None when it cannot be read."""
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return float(v)
    try:
        return float(calendar.timegm(time.strptime(v, "%Y-%m-%dT%H:%M:%SZ")))
    except (TypeError, ValueError):
        return None


def quarantine(test, card, until):
    """Add the row {test, card, expires} to qa_quarantine: under its lock, written whole to a new file and renamed over it.
    Expired rows and an earlier row of the same test and card go; a file that is not JSON is replaced (it skips nothing anyway)."""
    p, now = index_path("qa_quarantine"), time.time()
    try:
        with el.locked(p + ".lock"):
            try:
                fd = el.open_file(p, os.O_RDONLY)
                with os.fdopen(fd, "rb") as f:
                    old = json.loads(f.read(MAX_JSON))
                rows = old.get("rows") if isinstance(old, dict) else None
            except FileNotFoundError:
                rows = []
            except ValueError:
                rows = []
            rows = [r for r in rows or [] if isinstance(r, dict) and (expiry(r.get("expires")) or 0) > now and (r.get("test"), r.get("card")) != (test, card)]
            rows.append({"test": test, "card": card, "expires": until})
            tmp = f"{p}.{uuid.uuid4().hex}.new"
            fd = el.open_file(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    json.dump({"rows": rows}, f, indent=1)
                    f.write("\n")
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(tmp, p)
            finally:
                if os.path.lexists(tmp):
                    os.unlink(tmp)
    except (OSError, ValueError) as e:
        raise Stop(QUAR, f"the quarantine row for {test} was not written ({el.why(e) if isinstance(e, OSError) else e}); the trusted qa.flaky line stands"[:200]) from None


def cmd_flaky(a, q):
    t = tests_of(a.test, True)[0]
    rs = [run_test(a.copy, t, q)["result"] for _ in range(q["tests"]["reruns"])]
    out = {"test": t["id"], "runs": rs, "flaky": len(set(rs)) > 1}
    if not out["flaky"]:
        return out
    own = t["id"] in own_tests(a.card)
    until = None if own else iso(time.time() + q["tests"]["quarantine_days"] * 86400)
    out.update(quarantined=not own, expires=until)
    if own:
        out["why"] = "a tests-first test of this card: never quarantined for it, it stays a blocking finding"
    write("qa.flaky", a.card, out)
    if not own:
        quarantine(t["id"], a.card, until)
    return out


def severity(q, tiers):
    """The mildest severity that blocks on every tier: a mutant survivor is a mechanical result, never excused by depth."""
    s = [x["id"] for x in q["severities"] if x["blocks_on"] == "all" or set(tiers) <= set(x["blocks_on"])]
    if not s:
        raise Stop(DATA, "no severity of qa-loop.json blocks on every tier, so a surviving mutant has no severity")
    return s[-1]


def fingerprint(f):
    return hashlib.sha256(json.dumps([f["check"], f["file"], f["lines"], f["test"]], separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def fresh(src, card, rel=None, text=None):
    """A fresh copy of src inside qa_copies/<card>/ with no bytecode (a stale .pyc can hide a same-size edit); rel gets text."""
    top = index_path("qa_copies")
    d = os.path.join(top, card, "mutant-" + uuid.uuid4().hex[:12])
    el.mkdirs(os.path.dirname(d), top)
    shutil.copytree(src, d, symlinks=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    if rel is not None:
        with open(os.path.join(d, rel), "w", encoding="utf-8") as f:
            f.write(text)
    return d


def in_fresh(a, t, q, rel=None, text=None):
    d = fresh(a.copy, a.card, rel, text)
    try:
        return run_test(d, t, q)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def cmd_mutants(a, q, tiers):
    t = tests_of(a.test, True)[0]
    rel = os.path.normpath(a.file)
    src = os.path.join(a.copy, rel)
    # no link anywhere on the way: an absolute link copied into a fresh copy would send the mutant back into DIR
    if os.path.isabs(a.file) or rel.split(os.sep)[0] == ".." or not os.path.isfile(src) or os.path.realpath(src) != src:
        raise Stop(INPUT, f"--file {a.file[:100]} is not a plain file inside the copy (no link on the way)")
    try:
        with open(src, encoding="utf-8") as f:
            body = f.read(MAX_JSON + 1)
    except (OSError, UnicodeDecodeError) as e:
        raise Stop(INPUT, f"--file {rel} cannot be read as text ({type(e).__name__})") from None
    if len(body) > MAX_JSON:
        raise Stop(INPUT, f"--file {rel} is larger than {MAX_JSON} characters")
    lines = body.splitlines(keepends=True)
    left = q["mutants"]["cap_per_card"] - sum(len(p.get("applied") or []) for p in card_lines(a.card, "qa.mutants"))
    out = {"test": t["id"], "file": rel, "applied": [], "cap_left": max(left, 0)}
    if left <= 0:
        return out
    if in_fresh(a, t, q)["result"] != "pass":
        raise Stop(NOPASS, f"the test {t['id']} does not pass on the copy, so no mutant can say anything about it")
    sev, frozen = severity(q, tiers), card_lines(a.card, "qa.frozen")
    found = []
    for op in q["mutants"]["operators"]:
        if len(out["applied"]) >= left:
            break
        n = next((i for i, ln in enumerate(lines) if op["find"] in ln), None)
        if n is None:
            continue
        text = "".join(lines[:n] + [lines[n].replace(op["find"], op["replace"], 1)] + lines[n + 1:])
        killed = in_fresh(a, t, q, rel, text)["result"] != "pass"
        out["applied"].append({"operator": op["id"], "line": n + 1, "killed": killed})
        if not killed:
            f = {"kind": "test", "status": "confirmed", "static": False, "check": f"mutant survived: {op['id']}", "file": rel,
                 "lines": [n + 1, n + 1], "test": t["id"], "severity": sev, "repro": None, "evidence": None,
                 "round": frozen[-1].get("round") if frozen else None}
            found.append({**f, "fingerprint": fingerprint(f)})
    out["cap_left"] = left - len(out["applied"])
    if out["applied"]:
        write("qa.mutants", a.card, {k: out[k] for k in ("test", "file", "applied")})
    for f in found:
        write("qa.finding", a.card, f)
    out["findings"] = [f["fingerprint"] for f in found]
    return out


def main(argv):
    ap = argparse.ArgumentParser(prog="qa_tests.py", description="Tests first, baseline, flaky and mutants of a card's tests (host only).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, many in (("baseline", True), ("tests-first", True), ("flaky", False), ("mutants", False)):
        p = sub.add_parser(name)
        p.add_argument("--card", required=True)
        p.add_argument("--copy", required=True)
        p.add_argument("--tests" if many else "--test", required=True)
        p.add_argument("--json", action="store_true", help="the output is JSON in any case")
        if name == "mutants":
            p.add_argument("--file", required=True)
    a = ap.parse_args(argv)
    try:
        w = worker_env.reason()
        if w:
            raise Stop(sd.Refused.code, f"qa_tests.py {a.cmd} runs on the host only ({w}); nothing was run")
        if not CARD.fullmatch(a.card):
            raise Stop(INPUT, "--card must be a card id (letters, digits and _.-)")
        q, tiers = data()
        a.copy = copy_dir(a.copy)
        out = {"baseline": cmd_baseline, "tests-first": cmd_tests_first, "flaky": cmd_flaky}[a.cmd](a, q) if a.cmd != "mutants" else cmd_mutants(a, q, tiers)
        print(json.dumps(out))
        return 0
    except Stop as x:
        return el.fail(x.code, x.problem)
    except el.EventError as e:
        return el.fail(e.code, e.problem, e.extra)
    except sd.DataError as e:
        return el.fail(getattr(e, "code", DATA), str(e)[:180])
    except Exception as e:   # never a traceback: the type only
        return el.fail("STL-CFG-310", f"{type(e).__name__}, an unexpected failure of qa_tests.py {a.cmd}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
