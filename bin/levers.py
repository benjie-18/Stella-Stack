#!/usr/bin/env python3
"""Cost levers (F2c item D), stdlib only. Every policy value is data (.stella/levers.json, schema levers): the job kinds that may wait for a
batch answer, which connections offer batch, the cache policy per connection (kind, breakpoint positions, lifetimes), the share of gaps a
lifetime must cover, the part order and separator of a prompt, the patterns that must never stand in a stable part, the fan-out wait.
Module: load(); lane(job, table); policy_of(connection, table); gap_seconds(records, connection, table); lifetime_for(policy, gap, table);
tool_parts(tools); next_tools(previous, wanted); layout(parts, policy, table); lint(prompts, table); fanout(shared, members, send, policy, timeout, table).
  lane --job FILE|- --json                      {lane: batch|live, batch: bool, reason}; the caller copies batch into the usage record.
  policy --connection C [--records FILE] --json {kind, breakpoints, lifetime, gap_seconds, covered, source}; the gap is measured from the ledger.
  lint-prefix PATH... --json                    prompts (files of layout output, or folders of them, in name order): the stable part of each
        must start with the stable part of the one before (a tool may be added, nothing else changes) and hold no volatile text.
  hitrate --by card|project|role|model|connection [--records FILE] --json   cache-hit rate per group (cost.cache_hit_rate).
  check --json                                  the data file (schema, a connection once, lifetimes shortest first).
Exit: 0 ok; 1 refused or failed (catalog code and plain message on stderr, {code, problem} on stdout); 2 usage.
Codes: STL-LIM-440 data unusable, 441 a tool removed or changed in a session, 442 prefix lint failed, 443 fan-out stopped, 444 input unusable.
fanout() is a TEST DOUBLE of the scheduler M1, which does not exist yet: the first-token wait is a threading.Event the caller's send() sets.
shortcut: the lane and policy are read from the data on every call (no cache), upgrade when a hot path calls them per token."""
import argparse, json, math, os, re, sys, threading
from datetime import datetime

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import cost
import event_log as el
import stella_data as sd

BADDATA, TOOLS, PREFIX, FANOUT, BADINPUT = "STL-LIM-440", "STL-LIM-441", "STL-LIM-442", "STL-LIM-443", "STL-LIM-444"
ROW, LEDGER = "levers", "usage_ledger"   # the data row id and the index key of the ledger file

class Stop(Exception):
    def __init__(self, code, problem, alert=True):
        super().__init__(problem)
        self.code, self.problem, self.alert = code, problem, alert

def canon(v):
    """Byte-stable text of a value: a string as it is, anything else canonical JSON (sorted keys, no spaces)."""
    return v if isinstance(v, str) else json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)

# ---- the data ----
def table_problems(t):
    out, seen = [], set()
    for e in t["entries"]:
        if e["connection"] in seen:
            out.append(f"connection {sd.idn(e['connection'])} has more than one row")
        seen.add(e["connection"])
    for name, c in [("default_cache", t["default_cache"])] + [(sd.idn(e["id"]), e["cache"]) for e in t["entries"]]:
        s = [x["seconds"] for x in c.get("lifetimes", [])]
        if s != sorted(set(s)):
            out.append(f"{name}: lifetimes must be shortest first, none twice")
        if c["kind"] == "breakpoints" and not s:
            out.append(f"{name}: a breakpoints policy needs a lifetime")
    for p in t["lint"]["volatile_patterns"]:
        try:
            re.compile(p["pattern"])
        except re.error:
            out.append(f"lint pattern {sd.idn(p['id'])} is not a regular expression")
    return out

def load():
    """The levers document, judged by the data tool and by table_problems; Stop 440 when it cannot be used."""
    try:
        sd.served([ROW])
        row = next(r for r in sd.rows() if r["id"] == ROW)
        t = sd.checked(sd.load(row["path"]), row["path"], row["schema"])
    except (sd.DataError, StopIteration) as e:
        raise Stop(BADDATA, f"the levers file cannot be used: {str(e)[:160]}")
    bad = table_problems(t)
    if bad:
        raise Stop(BADDATA, bad[0] + (f" (and {len(bad) - 1} more)" if len(bad) > 1 else ""))
    return t

# ---- batch lane ----
def lane(job, t):
    """batch only when the kind is listed, the job is not urgent (anything but a missing or false flag counts as urgent) and the
    connection offers batch; else live."""
    if not isinstance(job, dict) or not isinstance(job.get("kind"), str) or not job["kind"]:
        raise Stop(BADINPUT, "a job needs a kind (text)", alert=False)
    row = next((e for e in t["entries"] if e["connection"] == job.get("connection")), None)
    if job.get("urgent") not in (None, False):
        why = "urgent"
    elif job["kind"] not in t["batch_kinds"]:
        why = "kind may not wait"
    elif not (row and row["batch"]):
        why = "connection offers no batch"
    else:
        return {"lane": "batch", "batch": True, "reason": "may wait"}
    return {"lane": "live", "batch": False, "reason": why}

# ---- cache policy ----
def policy_of(connection, t):
    row = next((e for e in t["entries"] if e["connection"] == connection), None)
    return {**(row["cache"] if row else t["default_cache"]), "source": "entry" if row else "default"}

def gap_seconds(records, connection, t=None):
    """The gap between calls of one connection (the data's percentile of the gaps between consecutive calls), seconds; None below two calls."""
    t = t or load()
    ts = []
    for r in records:
        if r.get("connection") != connection:
            continue
        try:
            ts.append(datetime.fromisoformat(r["ts"].replace("Z", "+00:00")).timestamp())
        except (KeyError, ValueError, AttributeError, TypeError):
            pass   # a record with no usable time says nothing about the gap
    ts.sort()
    gaps = sorted(b - a for a, b in zip(ts, ts[1:]))
    if not gaps:
        return None
    return gaps[max(0, math.ceil(t["lifetime_gap_percentile"] / 100 * len(gaps)) - 1)]

def choose(pol, gap):
    """{kind, breakpoints, lifetime, gap_seconds, covered, source}: the shortest lifetime that covers the gap; none covers it: lifetime None
    (a write nobody reads); no measurement: the shortest; a policy with no lifetimes (server prefix): None."""
    lts = pol.get("lifetimes", [])
    pick = next((x for x in lts if gap is None or x["seconds"] >= gap), None)
    return {"kind": pol["kind"], "breakpoints": pol.get("breakpoints", []), "lifetime": pick and pick["id"], "gap_seconds": gap,
            "covered": bool(pick) if lts else None, "source": pol["source"]}

# ---- prompt layout ----
def tool_parts(tools, t=None):
    p = (t or load())["layout"]["tool_part_prefix"]
    return [{"name": p + x["name"], "stable": True, "value": x} for x in tools]

def next_tools(prev, wanted):
    """The tool list of a session after this call: every earlier tool, unchanged and in place, then the new ones. A removal or a changed
    definition would change the prefix: Stop 441."""
    w = {x["name"]: x for x in wanted}
    for x in prev:
        if canon(w.get(x["name"])) != canon(x):
            raise Stop(TOOLS, f"tool {sd.idn(x['name'])} was {'removed' if x['name'] not in w else 'changed'} in the session", alert=False)
    return list(prev) + [x for x in wanted if x["name"] not in {y["name"] for y in prev}]

def layout(parts, pol, t=None):
    """parts: [{name, stable, value}]. The stable group comes first (the data's order), each group in the order given; serialization is
    canonical, so the same content is the same bytes. {parts: [{name, stable, text}], prefix, prefix_sha256, text, breakpoints}; a
    breakpoint is the index of the part after which the policy marks one."""
    import hashlib
    t = t or load()
    names = [p.get("name") for p in parts]
    if not all(isinstance(n, str) and n for n in names) or len(set(names)) != len(names):
        raise Stop(BADINPUT, "every prompt part needs its own name", alert=False)
    L = t["layout"]
    key = lambda p: L["order"].index("stable" if p["stable"] else "changing")
    out = [{"name": p["name"], "stable": bool(p["stable"]), "text": canon(p["value"])} for p in sorted(parts, key=key)]
    n = sum(p["stable"] for p in out)
    marks = {"after_stable": n - 1, "after_tools": max([i for i, p in enumerate(out) if p["name"].startswith(L["tool_part_prefix"])], default=-1)}
    bps = sorted({marks[b] for b in pol.get("breakpoints", []) if marks[b] >= 0})
    prefix = L["separator"].join(p["text"] for p in out if p["stable"])
    return {"parts": out, "prefix": prefix, "prefix_sha256": hashlib.sha256(prefix.encode()).hexdigest(),
            "text": L["separator"].join(p["text"] for p in out), "breakpoints": bps}

# ---- prefix lint ----
def lint(prompts, t):
    """prompts: [(label, layout output)] in order. The first problem as text, or None: a changing part before a stable one, volatile text in
    a stable part, a stable part list that does not start with the one before (a part changed or was removed)."""
    pats = [(p["id"], re.compile(p["pattern"])) for p in t["lint"]["volatile_patterns"]]
    prev = None
    for label, p in prompts:
        parts = p.get("parts") if isinstance(p, dict) else None
        if not (isinstance(parts, list) and all(isinstance(x, dict) and isinstance(x.get("name"), str) and isinstance(x.get("text"), str) for x in parts)):
            return f"{label}: not a prompt layout (parts with name and text)"
        stable = [x for x in parts if x.get("stable")]
        if parts[:len(stable)] != stable:
            return f"{label}: a changing part comes before a stable one"
        for x in stable:
            for pid, rx in pats:
                m = rx.search(x["text"])
                if m:
                    return f"{label}: stable part {sd.idn(x['name'])} holds {pid} text at byte {m.start()}"
        if prev is not None:
            for i, x in enumerate(prev[1]):
                y = stable[i] if i < len(stable) else None
                if y is None or (y["name"], y["text"]) != (x["name"], x["text"]):
                    at = "was removed" if y is None else f"changed at byte {next((k for k, (a, b) in enumerate(zip(x['text'], y['text'])) if a != b), min(len(x['text']), len(y['text'])))}"
                    return f"{label}: stable part {sd.idn(x['name'])} {at} since {prev[0]}"
        prev = (label, stable)
    return None

# ---- fan-out (test double of the scheduler M1) ----
def fanout(shared, members, send, pol, timeout=None, t=None):
    """One call first, its first token awaited, then the rest in parallel. shared: stable parts (rules, tools, evidence, frozen diff);
    members: [{id, instructions}] (instructions go last); send(prompt_text, member, first_token_event) -> result must set the event when
    the first token arrived. Results in member order. A first call that fails or never signals: Stop 443, the others are not sent."""
    t = t or load()
    if not members:
        return []
    wait = timeout if timeout is not None else t["fanout"]["first_token_timeout_s"]
    prompts = [layout(list(shared) + [{"name": "instructions", "stable": False, "value": r["instructions"]}], pol, t) for r in members]
    if len({p["prefix_sha256"] for p in prompts}) != 1:
        raise Stop(FANOUT, "the members' prefixes are not byte-identical")
    res, errs, tok = [None] * len(members), [], threading.Event()
    def run(i, ev):
        try:
            res[i] = send(prompts[i]["text"], members[i], ev)
        except Exception as e:   # the type only: the text could repeat a value
            errs.append(type(e).__name__)
            ev.set()   # wake the waiting caller at once; errs says it was a failure
    first = threading.Thread(target=run, args=(0, tok), daemon=True)
    first.start()
    tok.wait(wait)
    if errs or not tok.is_set():
        raise Stop(FANOUT, "the first member call " + (f"failed ({errs[0]})" if errs else "gave no first token in time") + "; the others were not sent")
    rest = [threading.Thread(target=run, args=(i, threading.Event()), daemon=True) for i in range(1, len(members))]
    for th in rest:
        th.start()
    first.join()
    for th in rest:
        th.join()
    if errs:
        raise Stop(FANOUT, f"a member call failed ({errs[0]})")
    return res

# ---- CLI ----
def read_json(path):
    try:
        return json.loads(sys.stdin.read() if path in (None, "-") else open(path, encoding="utf-8").read())
    except (OSError, ValueError) as e:
        raise Stop(BADINPUT, f"the input cannot be read ({type(e).__name__})", alert=False)

def ledger_records(path):
    key = sd.load(sd.INDEX).get(LEDGER)
    if not (path or key):
        raise Stop(BADINPUT, "no --records file and the data index names no usage_ledger", alert=False)
    return cost.read_lines(path or el.path(key))

def cmd_lane(a, t):
    print(json.dumps(lane(read_json(a.job), t)))

def cmd_policy(a, t):
    recs, _ = ledger_records(a.records)
    print(json.dumps(choose(policy_of(a.connection, t), gap_seconds(recs, a.connection, t))))

def cmd_lint(a, t):
    files = []
    for p in a.paths:
        if os.path.isdir(p):
            files += sorted(os.path.join(p, f) for f in os.listdir(p) if os.path.isfile(os.path.join(p, f)))
        elif os.path.isfile(p):
            files.append(p)
        else:
            raise Stop(BADINPUT, f"{p}: no such file or folder", alert=False)
    if not files:
        raise Stop(BADINPUT, "no prompt files to lint", alert=False)
    bad = lint([(os.path.basename(f), read_json(f)) for f in files], t)
    if bad:
        raise Stop(PREFIX, bad, alert=False)
    print(json.dumps({"ok": True, "compared": len(files) - 1}))

def cmd_hitrate(a, t):
    if a.by not in cost.BY:
        raise Stop(BADINPUT, f"--by must be one of {', '.join(cost.BY)}", alert=False)
    recs, skipped = ledger_records(a.records)
    print(json.dumps({"by": a.by, "groups": cost.cache_hit_rate(recs, a.by), "skipped": skipped}))

def cmd_check(a, t):
    print(json.dumps({"ok": True, "entries": len(t["entries"])}))

def main(argv):
    ap = argparse.ArgumentParser(prog="levers.py", description="Cost levers: batch lane, prompt layout, cache policy, prefix lint, hit rate.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("lane", "policy", "lint-prefix", "hitrate", "check"):
        p = sub.add_parser(name)
        p.add_argument("--json", action="store_true")
        if name == "lane":
            p.add_argument("--job", help="a job as JSON: {kind, connection, urgent?}; a file, - or nothing for stdin")
        if name == "policy":
            p.add_argument("--connection", required=True)
        if name in ("policy", "hitrate"):
            p.add_argument("--records", help="a usage ledger file (default: the file of index key usage_ledger)")
        if name == "hitrate":
            p.add_argument("--by", required=True)
        if name == "lint-prefix":
            p.add_argument("paths", nargs="+")
    a = ap.parse_args(argv)
    try:
        {"lane": cmd_lane, "policy": cmd_policy, "lint-prefix": cmd_lint, "hitrate": cmd_hitrate, "check": cmd_check}[a.cmd](a, load())
        return 0
    except Stop as x:
        s = x
    except el.EventError as e:
        s = Stop(e.code, e.problem)
    except sd.DataError as e:
        s = Stop(BADDATA, str(e)[:180])
    except Exception as e:   # never a traceback, never the error's text (it could repeat a value): the type only
        s = Stop(BADINPUT, f"{type(e).__name__}, an unexpected failure of levers.py {a.cmd}")
    print(json.dumps({"code": s.code, "problem": el.scrub(s.problem)}))
    el.say(s.code, s.problem, alert=s.alert)
    return 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
