#!/usr/bin/env python3
"""QA findings, evidence, verdicts and the mechanical merge (phase Q1 item B: design B with rulings DG-1, DG-2, DG-7), stdlib only.
Engine side, host only: every subcommand refuses in a worker environment (STL-CFG-312) before anything is read or parsed. No
role, tier, severity, trigger or path is named here: ids come from .stella/qa-loop.json (through bin/qa_loop.py data()), paths
from the index (qa_evidence, qa_copies, qa_quarantine). Round state is bin/qa_loop.py state(card): the fold of trusted qa.* lines.
Inputs from QA roles (findings files, paths, verdicts) are data: shapes and sizes checked, paths confined, a repro only an argv
list run in a disposable copy of the round's frozen copy through bin/qa_tests.py run() (its box), never a shell string.
Evidence: a file inside qa_evidence/<card>/<round>/ (no link on the way), registered by a trusted qa.evidence {path, sha256,
round} line; it holds only while the file's sha256 still equals the registered one and the one the finding or verdict recorded
(re-hashed on every read: a changed file voids it).
CLI (on failure a catalog code STL-QA-150..155 and its plain message on stderr, one alert line, exit 1; with --json also
{card, code, problem} on stdout; 2 usage). --round must be the card's current round, frozen and not closed.
  evidence --card C --round N --file F        qa.evidence {path (root-relative), sha256, round}
  submit   --card C --round N --role R --file J   J: {"findings": [...]} or the list itself; each {check, file, lines: [a, b],
           test, severity, repro: argv|null, evidence: [paths]|null, static: bool}; other keys (a role-assigned id, a detail text)
           are ignored. One qa.finding {fingerprint, round, role, status, ...} per finding. status: void (no evidence that holds;
           counts for nothing, and a void copy of a finding the round already has is not written), static, pending (blocking
           at the card's depth, not static, with a repro), unconfirmed (the same with no repro), reported (not blocking, not
           static); a same-round resubmission never lowers the status the round already has (STRENGTH).
  repro    --card C --fingerprint F           a pending finding of the round: its argv in a fresh copy of the frozen copy (box,
           tests.timeout_s); a non-zero exit or the timeout kill -> qa.finding-confirmed, exit 0 -> qa.finding-unconfirmed.
  verdict  --card C --round N --role R --result pass|fail|unverified --evidence P   qa.verdict {round, role, result, hash,
           evidence: {path, sha256}}; refused without evidence that holds. A fail or unverified from a role of kind review
           fires each trigger whose source is verdict (one qa.triggered line each, once per card).
  merge    --card C [--round N] --json         {card, round, depth, fix_list, blocking, pending}; see merge().
Python: fingerprint(f); merge(findings, depth, qa, exempt=()); holds(card, entry, s=None)."""
import argparse, hashlib, json, os, shutil, sys, time

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import qa_loop
import qa_tests
import stella_data as sd

BAD, EVID, ROUND, NOFIND, NORUN, FAILED = (f"STL-QA-{n}" for n in range(150, 156))
STRENGTH = ("void", "unconfirmed", "reported", "pending", "static", "confirmed")   # weakest first
LISTED, BLOCKS = ("reported", "static", "confirmed"), ("static", "confirmed")   # statuses on the fix list; that can block
RESULTS = ("pass", "fail", "unverified")
REVIEWER, SRC_VERDICT = "review", "verdict"   # the role kind whose fail fires the triggers of source verdict (qa-loop schema)
# shortcut: input caps in code (as bin/qa_tests.py has them), move to qa-loop.json when an owner needs to tune them
MAX_FINDINGS, MAX_TEXT, MAX_PATH, MAX_EVIDENCE, MAX_ARGV, MAX_ARG = 200, 200, 400, 20, 64, 2000


class Refuse(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def fingerprint(f):
    """sha256 of the compact JSON [check, file, lines, test]: a finding's identity, whatever its wording or role-assigned id."""
    return hashlib.sha256(json.dumps([f["check"], f["file"], f["lines"], f["test"]], separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def write(t, card, new):
    el.append(el.build(t, card, new=new), scrub_detail=False)


def blocks_on(qa, severity, depth):
    b = {x["id"]: x["blocks_on"] for x in qa["severities"]}.get(severity, [])
    return b == "all" or depth in b


# ---- evidence ----
def confine(card, rnd, p, d):
    """(root-relative path, real path) of p (absolute, or relative to the stack root), refused unless it lies inside
    qa_evidence/<card>/<rnd>/ with no link on the way."""
    if not isinstance(p, str) or not p or "\0" in p or len(p) > MAX_PATH * 4:
        raise Refuse(EVID, "an evidence path must be a non-empty path")
    a = os.path.normpath(p if os.path.isabs(p) else os.path.join(el.ROOT, p))
    rel, top = os.path.relpath(a, el.ROOT), os.path.normpath(os.path.join(d.idx["qa_evidence"], card, str(rnd)))
    if not rel.startswith(top + os.sep):
        raise Refuse(EVID, f"{p[-120:]} is not inside {top}/ (the evidence folder of the card's round)")
    try:
        return rel, el.path(rel)
    except ValueError as e:
        raise Refuse(EVID, f"{rel[-120:]}: {e}"[:200]) from None


def digest(real):
    """sha256 of a regular file, opened with no link followed; Refuse when it cannot be read."""
    try:
        fd = el.open_file(real, os.O_RDONLY)
        h = hashlib.sha256()
        with os.fdopen(fd, "rb") as f:
            for b in iter(lambda: f.read(1 << 20), b""):
                h.update(b)
        return h.hexdigest()
    except (OSError, ValueError) as e:
        raise Refuse(EVID, f"{os.path.basename(real)[:100]} cannot be read as a regular file ({el.why(e) if isinstance(e, OSError) else e})"[:200]) from None


def entry(s, rnd, p, d):
    """{path, sha256} of evidence that holds now: confined to the round's folder, registered, its digest unchanged. Refuse."""
    rel, real = confine(s["card"], rnd, p, d)
    reg = s["evidence"].get(rel)
    if not reg:
        raise Refuse(EVID, f"{rel[-120:]} is not registered by a trusted qa.evidence line")
    if digest(real) != reg.get("sha256"):
        raise Refuse(EVID, f"{rel[-120:]} changed after it was registered")
    return {"path": rel, "sha256": reg["sha256"]}


def holds(card, ev, s=None, d=None):
    """Evidence recorded by a finding or verdict ({path, sha256} or a list of them, non-empty) still holds: each re-hashed."""
    d = d or qa_loop.data()
    s = s or qa_loop.state(card, d)
    evs = ev if isinstance(ev, list) else [ev]
    try:
        return bool(evs) and all(isinstance(e, dict) and isinstance(s["evidence"].get(e.get("path")), dict) and
                                 entry(s, s["evidence"][e["path"]].get("round"), e["path"], d)["sha256"] == e.get("sha256") for e in evs)
    except Refuse:
        return False


# ---- inputs ----
def current(o, d):
    """The state of an opened card whose current round is o.round, frozen and not closed."""
    if not isinstance(o.card, str) or not qa_loop.CARD.fullmatch(o.card):
        raise Refuse(BAD, "the card id is not a plain id (letters, digits, dot, dash, underscore; at most 64)")
    s = qa_loop.state(o.card, d)
    if not s["opened"]:
        raise Refuse(ROUND, f"card {o.card} has no trusted qa.opened line")
    if getattr(o, "round", None) is not None and (o.round != s["round"] or not s["round"] or s["round"] in s["closed"] or s["escalated"]):
        raise Refuse(ROUND, f"round {o.round} is not the card's open round (current round {s['round']}, closed {s['closed'][-3:]})")
    return s


def text(x, n, what):
    if not isinstance(x, str) or not x or len(x) > n or "\0" in x:
        raise Refuse(BAD, f"a finding's {what} must be a non-empty text of at most {n} characters")
    return x


def argv_of(x):
    if isinstance(x, str):
        raise Refuse(BAD, "a repro must be an argv list (or null), never a shell string; nothing was run")
    ok = isinstance(x, list) and 0 < len(x) <= MAX_ARGV and all(isinstance(a, str) and 0 < len(a) <= MAX_ARG and "\0" not in a for a in x)
    if not ok:
        raise Refuse(BAD, f"a repro must be a list of 1 to {MAX_ARGV} non-empty strings (or null)")
    return list(x)


def finding_of(x, sev):
    """The checked finding (only its own keys); Refuse on any shape problem."""
    if not isinstance(x, dict):
        raise Refuse(BAD, "a finding must be an object")
    f = {"check": text(x.get("check"), MAX_TEXT, "check"), "file": text(x.get("file"), MAX_PATH, "file"), "lines": x.get("lines"),
         "test": text(x.get("test"), MAX_TEXT, "test"), "severity": x.get("severity"), "static": x.get("static"),
         "repro": None if x.get("repro") is None else argv_of(x["repro"]), "evidence": x.get("evidence")}
    if os.path.isabs(f["file"]) or os.path.normpath(f["file"]) != f["file"] or f["file"].split(os.sep)[0] == "..":
        raise Refuse(BAD, "a finding's file must be a normalised path inside the repository (relative, no ..)")
    ln = f["lines"]
    if not (isinstance(ln, list) and len(ln) == 2 and all(type(n) is int for n in ln) and 1 <= ln[0] <= ln[1]):
        raise Refuse(BAD, "a finding's lines must be [first, last] with 1 <= first <= last")
    if not qa_tests.NAME.fullmatch(f["test"]):
        raise Refuse(BAD, "a finding's test must be a test id (no white space, no leading dash)")
    if f["severity"] not in sev:
        raise Refuse(BAD, "a finding's severity is not one of the QA loop data's severities")
    if type(f["static"]) is not bool:
        raise Refuse(BAD, "a finding's static must be true or false")
    ev = f["evidence"]
    if ev is not None and not (isinstance(ev, list) and len(ev) <= MAX_EVIDENCE and all(isinstance(p, str) and 0 < len(p) <= MAX_PATH for p in ev)):
        raise Refuse(BAD, f"a finding's evidence must be a list of at most {MAX_EVIDENCE} paths (or null)")
    return f


# ---- commands ----
def cmd_evidence(o, d):
    s = current(o, d)
    rel, real = confine(o.card, o.round, o.file, d)
    new = {"path": rel, "sha256": digest(real), "round": o.round}
    write("qa.evidence", o.card, new)
    return new


def cmd_submit(o, d):
    s = current(o, d)
    if o.role not in d.qa["roles"]:
        raise Refuse(BAD, "the role is not one of the QA loop data's roles")
    try:
        v = qa_tests.read_json(o.file)
    except qa_tests.Stop as e:
        raise Refuse(BAD, e.problem) from None
    v = v.get("findings") if isinstance(v, dict) else v
    if not isinstance(v, list) or not 0 < len(v) <= MAX_FINDINGS:
        raise Refuse(BAD, f'the findings file must hold {{"findings": [...]}} or a list of 1 to {MAX_FINDINGS} findings')
    sev = [x["id"] for x in d.qa["severities"]]
    fs = [finding_of(x, sev) for x in v]   # every finding checked before any line is written
    out, seen = [], {}
    for f in fs:
        fp = fingerprint(f)
        try:
            ev = [entry(s, o.round, p, d) for p in f["evidence"] or []] or None
            why = None if ev else "no evidence"
        except Refuse as e:
            ev, why = None, e.problem
        old = s["findings"].get(fp, {})
        old = seen.get(fp) or (old.get("status") if old.get("round") == o.round else None)
        if not ev:
            st = "void"
        elif f["static"]:
            st = "static"
        elif blocks_on(d.qa, f["severity"], s["depth"]):
            st = "pending" if f["repro"] else "unconfirmed"
        else:
            st = "reported"
        if st == "void" and old not in (None, "void"):
            out.append({"fingerprint": fp, "status": old, "ignored": f"a void copy ({why}) of a finding the round has"[:200]})
            continue
        if old in STRENGTH and STRENGTH.index(old) > STRENGTH.index(st):
            st = old
        new = {**f, "evidence": ev or (f["evidence"] or [])[:MAX_EVIDENCE], "fingerprint": fp, "round": o.round, "role": o.role, "status": st}
        if why:
            new["why"] = why[:200]
        write("qa.finding", o.card, new)
        seen[fp] = st
        out.append({"fingerprint": fp, "status": st})
    return {"card": o.card, "round": o.round, "findings": out}


def cmd_repro(o, d):
    s = current(o, d)
    f = s["findings"].get(o.fingerprint)
    if not f or f.get("round") != s["round"] or f.get("status") != "pending" or s["round"] in s["closed"]:
        raise Refuse(NOFIND, f"no finding {str(o.fingerprint)[:64]} of the open round {s['round']} is pending its repro")
    argv = argv_of(f.get("repro"))
    try:
        src = qa_tests.copy_dir(el.path((s["frozen"] or {}).get("copy")))
        copy = qa_tests.fresh(src, o.card)   # a disposable copy: a repro never changes the frozen copy
        try:
            rc, _ = qa_tests.run(copy, argv, d.qa["tests"]["timeout_s"])
        finally:
            shutil.rmtree(copy, ignore_errors=True)
    except qa_tests.Stop as e:
        raise Refuse(NORUN, e.problem) from None
    except (OSError, ValueError, TypeError) as e:
        raise Refuse(NORUN, f"the round's frozen copy cannot be used ({type(e).__name__}: {str(e)[:120]})") from None
    t = "qa.finding-confirmed" if rc != 0 else "qa.finding-unconfirmed"
    new = {"fingerprint": o.fingerprint, "round": s["round"], "exit": rc, "hash": s["frozen"].get("hash")}
    write(t, o.card, new)
    return {"type": t, **new}


def cmd_verdict(o, d):
    s = current(o, d)
    role = d.qa["roles"].get(o.role)
    if role is None:
        raise Refuse(BAD, "the role is not one of the QA loop data's roles")
    if o.result not in RESULTS:
        raise Refuse(BAD, f"the result must be one of {', '.join(RESULTS)}")
    new = {"round": o.round, "role": o.role, "result": o.result, "hash": s["frozen"].get("hash"), "evidence": entry(s, o.round, o.evidence, d)}
    write("qa.verdict", o.card, new)
    fired = []
    if role["kind"] == REVIEWER and o.result != RESULTS[0]:
        for tid, t in d.qa["triggers"].items():
            if t.get("source") == SRC_VERDICT and tid not in s["triggers"]:
                write("qa.triggered", o.card, {"id": tid, "source": SRC_VERDICT, "evidence": f"verdict {o.result} by {o.role} in round {o.round}", "round": o.round})
                fired.append(tid)
    return {**new, "triggered": fired}


def merge(findings, depth, qa, exempt=()):
    """The fix list: findings whose status is listed (static, confirmed, reported), deduped by fingerprint (highest severity of
    the data's order kept, every role listed), sorted by that order then fingerprint. blocking: a status that can block, a
    severity whose blocks_on holds the depth, and a test not in exempt (base failures, quarantined tests: listed, not charged)."""
    sev = [x["id"] for x in qa["severities"]]
    rank = lambda x: sev.index(x) if x in sev else len(sev)
    out = {}
    for f in findings:
        if f.get("status") not in LISTED:
            continue
        fp = f.get("fingerprint") or fingerprint(f)
        e = out.setdefault(fp, {"fingerprint": fp, **{k: f.get(k) for k in ("check", "file", "lines", "test", "severity", "static", "status")}, "roles": []})
        if rank(f.get("severity")) < rank(e["severity"]):
            e["severity"] = f.get("severity")
        if STRENGTH.index(f["status"]) > STRENGTH.index(e["status"]):
            e["status"] = f["status"]
        for r in f.get("roles") or [f.get("role")]:
            if r and r not in e["roles"]:
                e["roles"].append(r)
    for e in out.values():
        e["charged"] = e["test"] not in exempt
        e["blocking"] = e["charged"] and e["status"] in BLOCKS and blocks_on(qa, e["severity"], depth)
    return sorted(out.values(), key=lambda e: (rank(e["severity"]), e["fingerprint"]))


def exempt(card):
    """Tests a finding is not charged for: the last trusted qa.base-failures line's tests, and the tests of unexpired
    qa_quarantine rows other than the card's own tests-first tests (DG-9); an unreadable quarantine file exempts nothing."""
    base = qa_tests.card_lines(card, "qa.base-failures")
    out = {t for t in (base[-1].get("tests") or []) if isinstance(t, str)} if base else set()
    try:
        v = qa_tests.read_json(qa_tests.index_path("qa_quarantine"))
    except qa_tests.Stop:
        return out
    rows, now = v.get("rows") if isinstance(v, dict) else None, time.time()
    q = {r["test"] for r in rows or [] if isinstance(r, dict) and isinstance(r.get("test"), str) and (qa_tests.expiry(r.get("expires")) or 0) > now}
    return out | (q - qa_tests.own_tests(card))


def cmd_merge(o, d):
    s = current(argparse.Namespace(card=o.card), d)
    rnd = s["round"] if o.round is None else o.round
    fs = [dict(f, fingerprint=k) for k, f in s["findings"].items() if f.get("round") == rnd]
    fs = [f for f in fs if not f.get("evidence") or holds(o.card, f["evidence"], s, d)]   # re-hashed: a changed file voids it
    fix = merge(fs, s["depth"], d.qa, exempt(o.card))
    return {"card": o.card, "round": rnd, "depth": s["depth"], "fix_list": fix, "blocking": sum(e["blocking"] for e in fix),
            "pending": sum(1 for f in fs if f.get("status") == "pending")}


CMDS = {"evidence": cmd_evidence, "submit": cmd_submit, "repro": cmd_repro, "verdict": cmd_verdict, "merge": cmd_merge}


def main(argv):
    try:   # before the arguments: in a worker environment every subcommand, known or not, is refused the same way
        el.owner_only()
    except el.EventError as e:
        return el.fail(e.code, e.problem)
    ap = argparse.ArgumentParser(prog="qa_findings.py", description="QA evidence, findings, repro, verdicts and the fix list (host only).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = {c: sub.add_parser(c) for c in CMDS}
    for c, p in a.items():
        p.add_argument("--card", required=True)
        p.add_argument("--json", action="store_true", help="the output is JSON in any case")
        if c != "repro":
            p.add_argument("--round", type=int, required=c != "merge")
    a["evidence"].add_argument("--file", required=True)
    a["submit"].add_argument("--role", required=True)
    a["submit"].add_argument("--file", required=True)
    a["repro"].add_argument("--fingerprint", required=True)
    a["verdict"].add_argument("--role", required=True)
    a["verdict"].add_argument("--result", required=True)
    a["verdict"].add_argument("--evidence", required=True)
    o = ap.parse_args(argv)
    try:
        print(json.dumps(CMDS[o.cmd](o, qa_loop.data())))
        return 0
    except (Refuse, el.EventError) as e:
        code, problem = e.code, e.problem
    except sd.DataError as e:
        code, problem = FAILED, f"the QA loop data cannot be used: {str(e)[:200]}"
    except Exception as e:   # shortcut: one code for every surprise; the exception type tells a bug apart
        code, problem = FAILED, f"unexpected {type(e).__name__} in qa_findings.py {o.cmd}"
    if o.json:
        print(json.dumps({"card": o.card, "code": code, "problem": el.scrub(problem)}))
    return el.fail(code, problem)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
