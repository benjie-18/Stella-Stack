#!/usr/bin/env python3
"""Deterministic log filter (F3 item X; body B8), stdlib only: tool output passes it before a model sees it.
  log_filter.py [--role R] < log > filtered
The role's filters (ids from .stella/run-policy.json, default when the role names none) run in file order:
  drop             lines matching the pattern are removed;
  collapse         a run of identical lines matching the pattern becomes the first line and the "repeated" marker;
  trim_to_failing  when some line matches, only matching lines and "context" lines around them are kept, each cut becomes the "trimmed" marker.
A line matching any trim_to_failing pattern is a failing line and is never dropped or collapsed, whatever the other filters say.
A log with no failing line is not trimmed. Same input, same output. Exit 0; 1 with the catalog code on stderr when the policy is unusable (no output).
shortcut: collapse matches identical single lines, not repeated multi-line frame groups, upgrade when a runtime repeats whole groups."""
import argparse, json, re, sys, os

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import run_policy as rp

def apply(t, role, text):
    pol = rp.effective(t, role)
    fs = [f for f in t["filters"] if f["id"] in pol["filters"]]
    pats = {f["id"]: re.compile(f["pattern"]) for f in fs}
    trims = [f for f in fs if f["kind"] == "trim_to_failing"]
    lines = text.split("\n")
    tail = lines.pop() if lines and lines[-1] == "" else None   # keep a final newline as it came
    fail = lambda l: any(pats[f["id"]].search(l) for f in trims)
    for f in fs:
        p = pats[f["id"]]
        if f["kind"] == "drop":
            lines = [l for l in lines if fail(l) or not p.search(l)]
        elif f["kind"] == "collapse":
            out, n = [], 0
            for l in lines:
                if out and l == out[-1] and p.search(l) and not fail(l):
                    n += 1
                    continue
                if n:
                    out.append(t["markers"]["repeated"].format(n=n)); n = 0
                out.append(l)
            if n:
                out.append(t["markers"]["repeated"].format(n=n))
            lines = out
    keep = set()
    for f in trims:
        for i, l in enumerate(lines):
            if pats[f["id"]].search(l):
                keep.update(range(max(0, i - f["context"]), min(len(lines), i + f["context"] + 1)))
    if keep:
        out, i = [], 0
        while i < len(lines):
            if i in keep:
                out.append(lines[i]); i += 1
                continue
            j = i
            while j < len(lines) and j not in keep:
                j += 1
            out.append(t["markers"]["trimmed"].format(n=j - i)); i = j
        lines = out
    return "\n".join(lines + ([] if tail is None else [tail]))

def main(argv):
    ap = argparse.ArgumentParser(prog="log_filter.py")
    ap.add_argument("--role", default=None)
    a = ap.parse_args(argv)
    try:
        t = rp.load()
        role = a.role if a.role is not None else json.load(open(os.path.join(rp.sd.ROOT, rp.ROLES), encoding="utf-8"))["fallback_role"]
        out = apply(t, role, sys.stdin.buffer.read().decode("utf-8", errors="replace"))
    except rp.Stop as s:
        print(json.dumps({"code": s.code, "problem": el.scrub(s.problem)}), file=sys.stderr)
        el.say(s.code, s.problem, alert=s.alert)
        return 1
    sys.stdout.write(out)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
