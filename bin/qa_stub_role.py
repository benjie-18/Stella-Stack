#!/usr/bin/env python3
"""The stub QA role: a deterministic test double for one QA slot (phase Q1 item D; due to be replaced by the real roles at D1).
Engine side, host only (refuses in a worker environment, STL-CFG-312). Run by bin/qa_roles.py as a process of its own:
  qa_stub_role.py --card C --round N --role R --slot I
It registers one evidence file of its own and submits its findings and its verdict through bin/qa_findings.py (the same
trusted path a real role uses). Its fixture for the card, round and role is the optional file
<qa_evidence>/<card>/stub/<round>-<role>.json: {"result": pass|fail|unverified, "findings": [finding without evidence]}.
With no fixture every slot reports the same one finding at the data's lowest severity (so a role's slots merge into one fix-list
entry) and passes. No role, severity or path is named here: they come from .stella/qa-loop.json and the index."""
import argparse, json, os, subprocess, sys, tempfile

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import qa_findings
import qa_loop
import qa_roles
import qa_tests

STUB_OFF, STUB_FAILED = "STL-QA-230", "STL-QA-231"
MAX_FIXTURE = 1 << 16


def fixture(d, card, rnd, role):
    """The fixture for this card, round and role: the file if there is one (checked by submit), else the default."""
    p = os.path.join(el.path(d.idx["qa_evidence"]), card, "stub", f"{rnd}-{role}.json")
    if os.path.isfile(p) and not os.path.islink(p) and os.path.getsize(p) <= MAX_FIXTURE:
        v = qa_tests.read_json(p)
        if isinstance(v, dict) and isinstance(v.get("findings", []), list):
            return v
    low = d.qa["severities"][-1]["id"]
    return {"result": qa_findings.RESULTS[0], "findings": [{"check": "stub double finding", "file": "stub.txt", "lines": [1, 1],
                                                    "test": "stub-check", "severity": low, "static": False, "repro": None}]}


def call(*a):
    r = subprocess.run([sys.executable, "-I", os.path.join(BIN, "qa_findings.py"), *a], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(f"qa_findings.py {a[0]}: {(r.stderr or r.stdout).strip()[:300]}")


def main(argv):
    try:
        el.owner_only()
    except el.EventError as e:
        return el.fail(e.code, e.problem)
    ap = argparse.ArgumentParser(prog="qa_stub_role.py")
    ap.add_argument("--card", required=True)
    ap.add_argument("--round", type=int, required=True)
    ap.add_argument("--role", required=True)
    ap.add_argument("--slot", type=int, required=True)
    o = ap.parse_args(argv)
    try:
        d = qa_loop.data(o.card)   # the card's own settings (overrides)
        if not qa_roles.feature_on(d.qa["stub_roles"]["feature"]):   # D-CHK-01: a slot started directly obeys the same switch as run
            return el.fail(STUB_OFF, f"the stub QA roles are off (features entry {d.qa['stub_roles']['feature']}); slot {o.slot} of {o.role} not run")
        if not qa_loop.CARD.fullmatch(o.card) or o.role not in d.qa["roles"]:
            raise ValueError("the card id or the role is not one the QA loop data knows")
        fx = fixture(d, o.card, o.round, o.role)
        folder = os.path.join(el.path(d.idx["qa_evidence"]), o.card, str(o.round))
        os.makedirs(folder, exist_ok=True)
        ev = os.path.join(folder, f"stub-{o.role}-{o.slot}.json")
        with open(ev, "w") as f:
            json.dump({"stub": True, "card": o.card, "round": o.round, "role": o.role, "slot": o.slot}, f)
        rel = os.path.relpath(ev, el.ROOT)
        base = ("--card", o.card, "--round", str(o.round))
        call("evidence", *base, "--file", rel)
        if fx.get("findings"):
            with tempfile.NamedTemporaryFile("w", suffix=".json", dir=os.environ.get("TMPDIR")) as t:
                json.dump({"findings": [{"evidence": [rel], **x} for x in fx["findings"]]}, t)
                t.flush()
                call("submit", *base, "--role", o.role, "--file", t.name)
        call("verdict", *base, "--role", o.role, "--slot", str(o.slot), "--result", str(fx.get("result")), "--evidence", rel)
    except Exception as e:   # shortcut: one code for every failure of a slot; the text tells them apart
        return el.fail(STUB_FAILED, f"slot {o.slot} of {o.role}: {type(e).__name__}: {str(e)[:250]}")
    print(json.dumps({"card": o.card, "round": o.round, "role": o.role, "slot": o.slot, "ok": True}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
