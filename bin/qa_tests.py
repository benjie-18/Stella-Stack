#!/usr/bin/env python3
"""QA tests (phase Q1 item C1; design.md C1, rulings DG-6, DG-7, DG-9), stdlib only, host only (STL-CFG-312 in a worker
environment). Every command runs the card's tests ({id, argv} JSON, argv never a shell string) in the copy the caller names: a
directory under the index key qa_copies (the caller made it; refused anywhere else), each argv with that copy as its working
folder, a private HOME and TMPDIR, killed at tests.timeout_s of .stella/qa-loop.json, in a box (see box_argv below). State goes
out as one trusted line through bin/event_log.py; nothing here reads the untrusted stream.
The run rule (run, fresh): no run ever writes the folder it is given. Every run works in a throwaway copy of it under
qa_copies/<card>/ (made by fresh, removed after); a round copy (one a trusted qa.frozen line names) is first checked against
that line's tree, hashed from its files by git in a scratch repository, and refused with STL-QA-186 when they differ.
A finding's repro and the scheduled full-suite run go through the same two functions.
  baseline    --card C --copy DIR --tests J   qa.base-failures {tests: [failing ids], classes}: tests failing on the base copy,
              never charged to the builder.
  tests-first --card C --copy DIR --tests J   each test must fail on the base copy with a class of kind assertion; a pass, an
              error class (whatever else matched) or the runner's timeout kill refuses it (DG-6): qa.tests-first {accepted, refused}.
  flaky       --card C --copy DIR --test J    reruns the test alone tests.reruns times in one throwaway copy of DIR; mixed
              results: qa.flaky, then a quarantine row {test, card, expires, files} in qa_quarantine (atomic, under a lock) that
              bin/test-map.py select honours. Never for a test the card owns (DG-9, own_tests): a tests-first test of the card, or
              a test whose files (the test map's file of its id, the paths in its argv) the card changed from its base to its
              frozen hash; nor a test not flaky on the card's base hash (qa.opened), rerun as often in a copy qa_loop.make_copy
              makes from the round copy (DIR without one): the card made it flaky (RTF-07). That one stays a blocking finding.
              No round is used.
  mutants     --card C --copy DIR --file F --test J   the test must pass on the copy; then each operator of mutants.operators is
              applied to one line of F holding its find text outside a string or a # comment: a line the card changed (base to
              frozen hash) when it has a frozen round, each operator on a line no earlier one took where it can; each in a
              fresh copy (no bytecode carried), up to
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

import argparse, calendar, functools, hashlib, importlib.util, json, pwd, re, shutil, signal, stat, subprocess, tempfile, time, uuid

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import box
import event_log as el
import qa_loop as ql
import roles
import stella_data as sd
import worker_env

DATA, INPUT, COPY, NOBOX, NOPASS, QUAR, TREE = "STL-QA-180", "STL-QA-181", "STL-QA-182", "STL-QA-183", "STL-QA-184", "STL-QA-185", "STL-QA-186"
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


MADE = set()   # real paths of the throwaway copies this process made (fresh): run() works in these and copies anything else first


def run(copy, argv, timeout, scan=()):
    """(exit code or None on the timeout kill, output) of argv in the box, cwd a throwaway copy: a folder not in MADE (a round or
    base copy) is copied first by fresh() (which checks a round copy's tree) and the copy removed after, so no run ever writes
    the folder it was given. A long output keeps its head and tail; each string of scan found anywhere in it is named on a last
    line, so a class pattern in the cut middle still counts. Stop when the box did not start."""
    real = os.path.realpath(copy)
    if real not in MADE:
        top = index_path("qa_copies")
        if not el.inside(real, top) or real == top:
            raise Stop(COPY, f"{copy} is not a folder inside the QA copies folder ({top}); tests never run anywhere else"[:200])
        d = fresh(real, os.path.relpath(real, top).split(os.sep)[0])
        try:
            return run(d, argv, timeout, scan)
        finally:
            drop(d)
    # DG-7 asks for box.py exec; it refuses a standalone clone (not a linked worktree), so this box is the house flags (box.BASE)
    # with the stack roots, the homes and /tmp hidden, no network, and only the throwaway copy writable.
    cmd = box.BASE + ["--unshare-net"] + [a for x in hidden() for a in ("--tmpfs", x)] + [
        "--dir", "/tmp/qa-home", "--dir", "/tmp/qa-tmp", "--bind", real, real, "--chdir", real,
        "bash", "-c", 'echo started >&"$0" || exit 1; eval "exec $0>&-"; exec "$@"']
    env = {k: os.environ[k] for k in ("PATH", "LANG", "LC_ALL") if k in os.environ}
    env.update(HOME="/tmp/qa-home", TMPDIR="/tmp/qa-tmp", PYTHONDONTWRITEBYTECODE="1")
    sr, sw = os.pipe()
    with tempfile.TemporaryFile() as log:
        try:
            p = subprocess.Popen(cmd + [str(sw), *argv], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=env,
                                 cwd=real, start_new_session=True, pass_fds=(sw,))
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
        if size > MAX_OUT:   # the head and the tail of a long output, and which scan strings the whole of it holds (RT1-11)
            want, seen, prev = [s.encode() for s in scan], set(), b""
            log.seek(0)
            for chunk in iter(lambda: log.read(MAX_OUT), b""):
                w = prev + chunk
                seen |= {s for s in want if s in w}
                prev = w[-max(map(len, want), default=1):]   # a string cut by the chunk border is seen in the next window
            log.seek(size - half)
            out += log.read(half)
            if seen:
                out += b"\n[the cut middle of the output holds: " + b", ".join(sorted(seen)) + b"]\n"
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
    rc, out = run(copy, t["argv"], q["tests"]["timeout_s"], [p for c in q["tests"]["classes"] for p in c["patterns"]])
    res, cid, kind = classify(rc, out, q["tests"]["classes"])
    return {"id": t["id"], "result": res, "class": cid, "kind": kind, "exit": rc}


def payload(d):
    """A trusted line's own fields merged with its detail and new where those are objects."""
    return {**d, **(d["detail"] if isinstance(d.get("detail"), dict) else {}), **(d["new"] if isinstance(d.get("new"), dict) else {})}


def card_lines(card, type_):
    return [payload(d) for d in el.proof_lines() if d.get("type") == type_ and ql.same(d.get("what"), card)]


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
            ref.append({"id": r["id"], "class": r["class"], "why": "passes on the base copy" if r["result"] == "pass" else f"fails with a class of kind {r['kind']}, not an assertion"})
    new = {"accepted": acc, "refused": ref}
    write("qa.tests-first", a.card, new)
    return new


@functools.cache
def test_map():
    """The test map, read by bin/test-map.py's own loader."""
    try:
        spec = importlib.util.spec_from_file_location("test_map", os.path.join(BIN, "test-map.py"))
        tm = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(tm)
        return tm.load()
    except Exception as e:
        raise Stop(DATA, f"the test map cannot be read ({str(e)[:160] or type(e).__name__})") from None


def files_of(test, paths=()):
    """The repository files a test stands for: the test map's file of its id, and each relative path among paths (its argv)."""
    out = {os.path.normpath(p) for p in paths if isinstance(p, str) and p and not os.path.isabs(p) and not p.startswith("-")}
    try:
        tf = test_map()["test_file"]
        if isinstance(tf, str):
            out.add(tf.replace("{name}", test))
    except (Stop, KeyError, TypeError):
        pass   # no test map: the argv paths alone
    return out


def frozen(card):
    """(round copy, base, frozen hash, qa_loop data) of the card's last frozen round; None when it has none."""
    d = ql.data()
    s = ql.state(card, d)
    f = s["frozen"]
    return (el.path(f["copy"]), f.get("base") or s["base"], f["hash"], d) if f else None


def changed_by(card):
    """The paths the card changed from its base to its frozen hash (both sides of a rename), read in its round copy: set() when
    it has no frozen round, None when the diff cannot be read (the caller fails closed)."""
    try:
        f = frozen(card)
        c = ql.changed(*f) if f else ([], [])
    except Exception:   # unreadable data, state or copy: unknown, never "nothing changed"
        return None
    return set(c[0]) if c else None


def quarantine_rows():
    """The unexpired rows of qa_quarantine; none when it cannot be read."""
    try:
        v = read_json(index_path("qa_quarantine"))
    except Stop:
        return []
    rows = v.get("rows") if isinstance(v, dict) else None
    return [r for r in rows or [] if isinstance(r, dict) and isinstance(r.get("test"), str) and (expiry(r.get("expires")) or 0) > time.time()]


def own_tests(card):
    """DG-9: the tests never quarantined for the card: its tests-first tests (accepted or refused), and each quarantined test
    whose files (its row's, or the test map's file of its id) the card changed; every quarantined one when that is unknown."""
    own = {x["id"] for p in card_lines(card, "qa.tests-first") for k in ("accepted", "refused") for x in p.get(k) or [] if isinstance(x, dict)}
    rows = quarantine_rows()
    ch = changed_by(card) if rows else set()
    return own | {r["test"] for r in rows if ch is None or files_of(r["test"], r.get("files") or []) & ch}


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


def quarantine(test, card, until, files):
    """Add the row {test, card, expires, files} to qa_quarantine: under its lock, written whole to a new file and renamed over it.
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
            rows.append({"test": test, "card": card, "expires": until, "files": files})
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


def reruns(d, t, q):
    """The test's results over tests.reruns runs in the one throwaway d (what a run leaves is what the next one meets), then d goes."""
    try:
        return [run_test(d, t, q)["result"] for _ in range(q["tests"]["reruns"])]
    finally:
        drop(d)


def base_runs(card, copy, t, q):
    """RTF-07: the test's reruns on the card's base hash, in a copy made the way freeze makes a round copy (qa_loop.make_copy)
    from the round copy (DIR when the card has no frozen round); None when that copy cannot be made (the caller fails closed)."""
    try:
        f = frozen(card)
        d = f[3] if f else ql.data()
        repo, base = (f[0], f[1]) if f else (copy, ql.state(card, d)["base"])
        dest = ql.make_copy(repo, base, card, "base-" + uuid.uuid4().hex[:12], d)[0]
    except Exception:   # no base, no state, or the base not in the copy: unknown, never "flaky on the base too"
        return None
    MADE.add(os.path.realpath(dest))
    return reruns(dest, t, q)


def cmd_flaky(a, q):
    t = tests_of(a.test, True)[0]
    rs = reruns(fresh(a.copy, a.card), t, q)
    out = {"test": t["id"], "runs": rs, "flaky": len(set(rs)) > 1}
    if not out["flaky"]:
        return out
    files = files_of(t["id"], t["argv"])
    ch = changed_by(a.card)
    own = t["id"] in own_tests(a.card) or ch is None or bool(files & ch)
    if not own:   # flaky here but stable on the base hash: the card made it flaky (RTF-07)
        out["base_runs"] = base_runs(a.card, a.copy, t, q)
        own = not out["base_runs"] or len(set(out["base_runs"])) < 2
    until = None if own else iso(time.time() + q["tests"]["quarantine_days"] * 86400)
    out.update(quarantined=not own, expires=until)
    if own:
        out["why"] = ("a tests-first test of this card, a test whose file it changed, or one not flaky on the card's base hash: never "
                      "quarantined for it, it stays a blocking finding")
    write("qa.flaky", a.card, out)
    if not own:
        quarantine(t["id"], a.card, until, sorted(files))
    return out


def severity(q, tiers):
    """The mildest severity that blocks on every tier: a mutant survivor is a mechanical result, never excused by depth."""
    s = [x["id"] for x in q["severities"] if x["blocks_on"] == "all" or set(tiers) <= set(x["blocks_on"])]
    if not s:
        raise Stop(DATA, "no severity of qa-loop.json blocks on every tier, so a surviving mutant has no severity")
    return s[-1]


def fingerprint(f):
    import qa_findings   # the one fingerprint (item B); imported here, since qa_findings imports this module
    return qa_findings.fingerprint(f)


def verify(src):
    """A round copy (one a trusted qa.frozen line names) must still hold that line's tree: its files (its .git aside) are hashed
    by git into a scratch repository, so the copy's own config, hooks, index and objects are never used. Stop otherwise; a
    folder no qa.frozen line names passes."""
    real = os.path.realpath(src)
    trees = [p.get("tree") for p in (payload(d) for d in el.proof_lines() if d.get("type") == "qa.frozen")
             if isinstance(p.get("copy"), str) and os.path.realpath(os.path.join(el.ROOT, p["copy"])) == real]
    if not trees:
        return
    want, rel = trees[-1], os.path.relpath(real, el.ROOT)
    q, _ = data()
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0")
    try:
        with tempfile.TemporaryDirectory() as g:
            git = ["git", "-c", f"core.hooksPath={os.devnull}", "-c", "core.fsmonitor=false", f"--git-dir={g}", f"--work-tree={real}"]
            fmt = ["--object-format=sha256"] if isinstance(want, str) and len(want) == 64 else []
            for cmd in (["git", "init", "-q", "--bare", "--template=", *fmt, g], git + ["add", "-A", "--force", "--", "."], git + ["write-tree"]):
                r = subprocess.run(cmd, cwd=real, env=env, capture_output=True, text=True, errors="replace", timeout=q["tests"]["timeout_s"])
                if r.returncode:
                    raise OSError(r.stdout.strip()[-120:] or f"git {cmd[1]} failed")
    except (OSError, subprocess.SubprocessError) as e:
        raise Stop(TREE, f"the round copy {rel} cannot be checked against its frozen tree ({str(e)[:100]}); nothing was run") from None
    if r.stdout.strip() != want:
        raise Stop(TREE, f"the round copy {rel} no longer holds the tree frozen for it; nothing was run in it"[:200])


def fresh(src, card, rel=None, text=None):
    """A throwaway copy of src inside qa_copies/<card>/ with no bytecode (a stale .pyc can hide a same-size edit), added to MADE;
    rel gets text. A round copy is checked against its frozen tree first (verify)."""
    verify(src)
    top = index_path("qa_copies")
    d = os.path.join(top, card, "run-" + uuid.uuid4().hex[:12])
    el.mkdirs(os.path.dirname(d), top)
    shutil.copytree(src, d, symlinks=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    MADE.add(os.path.realpath(d))
    if rel is not None:
        with open(os.path.join(d, rel), "w", encoding="utf-8") as f:
            f.write(text)
    return d


def drop(d):
    shutil.rmtree(d, ignore_errors=True)
    MADE.discard(os.path.realpath(d))


def in_fresh(a, t, q, rel=None, text=None):
    d = fresh(a.copy, a.card, rel, text)
    try:
        return run_test(d, t, q)
    finally:
        drop(d)


STR = re.compile(r"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'")
HUNK = re.compile(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@", re.M)


def code_of(line):
    """The line with each quoted string blanked (same length) and a # comment cut: an operator there is no code to mutate.
    shortcut: a # that is code (shell $#, ${#x}) cuts the line early; read the file's language when a mutant needs those lines."""
    return STR.sub(lambda m: m[0][0] + " " * (len(m[0]) - 2) + m[0][-1], line).split("#", 1)[0]


def changed_lines(card, rel):
    """The line numbers of rel the card added or changed (base to frozen hash, new side); None when the card has no frozen round
    or the diff cannot be read: then every line is a candidate, as for a copy outside a round."""
    try:
        f = frozen(card)
        if not f:
            return None
        r = ql.diff(f[0], f[1], f[2], f[3], "-U0", paths=[rel])   # RTF-02: the engine's one diff (text, the copy's attributes not followed)
    except Exception:   # unreadable data, state or copy
        return None
    if r.returncode:
        return None
    return {n for m in HUNK.finditer(r.stdout) for n in range(int(m[1]), int(m[1]) + int(m[2] if m[2] is not None else 1))}


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
    if run_test(a.copy, t, q)["result"] != "pass":
        raise Stop(NOPASS, f"the test {t['id']} does not pass on the copy, so no mutant can say anything about it")
    sev, frozen = severity(q, tiers), card_lines(a.card, "qa.frozen")
    found, want, used = [], changed_lines(a.card, rel), set()
    for op in q["mutants"]["operators"]:
        if len(out["applied"]) >= left:
            break
        cands = [i for i, ln in enumerate(lines) if (want is None or i + 1 in want) and op["find"] in code_of(ln)]
        if not cands:
            continue
        n = next((i for i in cands if i not in used), cands[0])   # spread: a line no earlier operator took, where there is one
        used.add(n)
        c = code_of(lines[n]).index(op["find"])
        text = "".join(lines[:n] + [lines[n][:c] + op["replace"] + lines[n][c + len(op["find"]):]] + lines[n + 1:])
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
