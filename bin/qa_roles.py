#!/usr/bin/env python3
"""Run the QA roles of a card's round (phase Q1 item D: design D), stdlib only. Engine side, host only: every subcommand refuses
in a worker environment (STL-CFG-312) before anything is read. No role, preset or path is named here: the plan comes from
bin/qa_loop.py plan(), ids from .stella/qa-loop.json and the index.
  run --card C --round N     reads the plan and starts every slot as a process of its own, all at once (one after another
       when the plan says parallel is false, as under when_local_only). Until D1 each slot is the stub double
       bin/qa_stub_role.py, allowed only while the features entry named by qa-loop.json stub_roles.feature is on (STL-QA-230).
       A slot that fails -> STL-QA-231 (the others still finish; what they recorded stays).
  diagnose --card C          only while the features entry named by qa-loop.json diagnosis.flag is on (STL-QA-232): one call
       (the stub's text until D1) writes a brief file <qa_evidence>/<card>/<round>/diagnosis-brief.md and one trusted
       qa.diagnosed line {round, path, sha256}. It is not a round: no round line, no count change.
Other failures (round not open, data, unexpected): STL-QA-233. With --json a failure also prints {card, code, problem}."""
import argparse, hashlib, json, os, subprocess, sys

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import qa_findings
import qa_loop
import stella_data as sd

STUB_OFF, SLOT_FAILED, DIAG_OFF, FAILED = "STL-QA-230", "STL-QA-231", "STL-QA-232", "STL-QA-233"
Refuse = qa_loop.Refuse


def feature_on(fid):
    """True when the features entry fid (its id or its flag) has status on."""
    row = next((r for r in sd.rows() if r["schema"] == "features"), None)
    if row is None:
        raise Refuse(FAILED, "the index has no features row")
    return any(fid in (e.get("id"), e.get("flag")) and e.get("status") == "on" for e in sd.load(row["path"])["entries"])


def cmd_run(o, d):
    fid = d.qa["stub_roles"]["feature"]
    if not feature_on(fid):   # first: with the stubs off nothing else is read or judged
        raise Refuse(STUB_OFF, f"the stub QA roles are off (features entry {fid}) and the real roles are not built yet")
    s = qa_findings.current(o, d)   # the card is opened and o.round is its open, frozen round
    p = qa_loop.plan(o.card, s, d)
    jobs = [(r, sl["slot"]) for r, e in p["roles"].items() for sl in e["slots"]]
    cmd = lambda j: [sys.executable, "-I", os.path.join(BIN, "qa_stub_role.py"), "--card", o.card, "--round", str(o.round), "--role", j[0], "--slot", str(j[1])]
    run = lambda j: subprocess.Popen(cmd(j), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    done = []
    if p["parallel"]:
        procs = [(j, run(j)) for j in jobs]
        done = [(j, x.communicate(), x) for j, x in procs]
    else:
        for j in jobs:
            x = run(j)
            done.append((j, x.communicate(), x))
    bad = [f"{j[0]}#{j[1]}: {(out[1] or out[0]).strip()[:150]}" for j, out, x in done if x.returncode]
    if bad:
        raise Refuse(SLOT_FAILED, f"{len(bad)} of {len(jobs)} QA slots failed ({'; '.join(bad)})"[:600])
    print(json.dumps({"card": o.card, "round": o.round, "parallel": p["parallel"], "slots": [{"role": j[0], "slot": j[1]} for j in jobs]}))
    return 0


def cmd_diagnose(o, d):
    flag = d.qa["diagnosis"]["flag"]
    if not feature_on(flag):
        raise Refuse(DIAG_OFF, f"the round-2 diagnosis is off (features entry {flag})")
    s = qa_findings.current(o, d)
    if not s["round"]:
        raise Refuse(FAILED, f"card {o.card} has no frozen round to diagnose")
    m = qa_findings.cmd_merge(argparse.Namespace(card=o.card, round=None), d)
    text = f"# Diagnosis brief (stub), card {o.card}, round {s['round']}\n\nOpen fix-list entries: {len(m['fix_list'])}, blocking: {m['blocking']}.\n" + \
        "".join(f"- {e['severity']} {e['file']}:{e['lines'][0]} {e['check']} (roles: {', '.join(e['roles'])})\n" for e in m["fix_list"])
    folder = os.path.join(el.path(d.idx["qa_evidence"]), o.card, str(s["round"]))
    os.makedirs(folder, exist_ok=True)
    fd = el.open_file(os.path.join(folder, "diagnosis-brief.md"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    new = {"round": s["round"], "path": os.path.join(d.idx["qa_evidence"], o.card, str(s["round"]), "diagnosis-brief.md"),
           "sha256": hashlib.sha256(text.encode()).hexdigest()}
    with qa_loop.card_lock(o.card, d):   # RTF-05 family: the card's one lock around its line
        qa_findings.write("qa.diagnosed", o.card, new)
    print(json.dumps({"card": o.card, **new}))
    return 0


def main(argv):
    try:   # before the arguments: in a worker environment every subcommand, known or not, is refused the same way
        el.owner_only()
    except el.EventError as e:
        return el.fail(e.code, e.problem)
    ap = argparse.ArgumentParser(prog="qa_roles.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = {c: sub.add_parser(c) for c in ("run", "diagnose")}
    for p in a.values():
        p.add_argument("--card", required=True)
        p.add_argument("--json", action="store_true", help="a failure also prints {card, code, problem} as JSON")
    a["run"].add_argument("--round", type=int, required=True)
    o = ap.parse_args(argv)
    try:
        d = qa_loop.data(o.card)   # the card's own settings (overrides), as qa_loop plans and closes with them
        return {"run": cmd_run, "diagnose": cmd_diagnose}[o.cmd](o, d)
    except (Refuse, qa_findings.Refuse, el.EventError) as e:
        code, problem = e.code, e.problem
    except sd.DataError as e:
        code, problem = FAILED, str(e)[:300]
    except Exception as e:   # shortcut: one code for every surprise; the exception type tells a bug apart
        code, problem = FAILED, f"unexpected {type(e).__name__}"
    if o.json:
        print(json.dumps({"card": o.card, "code": code, "problem": el.scrub(problem)}))
    return el.fail(code, problem)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
