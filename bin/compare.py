#!/usr/bin/env python3
"""Sound comparison of two arms (a model, a profile, a harness) on the same tasks (F2c item E), stdlib only, no model call. Every number
that acts (confidence level, trials, pass^k's k, the non-inferiority margin, the minimum sample, the regression rule, the stale-catalog
days) is data: .stella/model-check.json (schema model-check). Nothing here names a model, a provider, a connection or a role.
Method. An arm is a list of trial records {task, trial, passed, score?} (the value of a trial is its score, else 1 or 0 for passed).
Only tasks both arms ran are paired. Per task the mean over its trials, per arm; the paired difference a - b per task; the mean
difference with a t-interval over tasks (n-1 degrees of freedom; the interval's unit is the task, never the trial, because trials of
one task are not independent samples of the task distribution). The t quantile is computed here from the regularized incomplete beta
function (continued fraction, Lentz), then a bisection: exact to about 1e-12, any degrees of freedom, no table, no scipy.
pass^k of an arm: per task with n >= k trials and c passes, comb(c, k) / comb(n, k) (the chance that k trials drawn without
replacement all pass), averaged over those tasks; none when no task has k trials.
decide(a, b, params, cheaper=False) is one of: better (interval above zero), worse (interval below zero), non_inferior (only when the
caller says a is the cheaper one: the lower bound stays above minus the margin; checked before worse, so a cheaper arm inside the
margin is never called worse), inconclusive (never act). Fewer paired tasks than min_tasks is inconclusive, reason min_sample.
A regression-set failure is worse, reason regression_set, whatever the mean. regression set: records {task, source_card, passing} of
tasks from failed cards; those with passing true must keep passing (a task never fixed is not enforced); a task passes when its trials'
pass share is at least regression_set.min_pass_rate; a task the candidate did not run does not pass.
Benchmark results (index key benchmark_results, schema benchmarks): the reader keeps the valid records of this install and ignores
the rest, and only a record whose digest a trusted `benchmark.recorded` event line (event_log.proof_lines) lists: a hand-edited file or
a record with no line proves nothing. record_results(rows) is the one writer: the file, then the lines (a crash between them leaves
unproved records, which are ignored). A file or proof it cannot read is no record, with the problem (fail closed). routing_stats(records, prior, params): per (role,
connection, model), the benchmark mean (of the newest suite version, over tasks) when it has routing_min_tasks tasks, else the prior
(the advertised score) with the reason.
CLI (output is JSON; --json is accepted and is the only form):
  compare.py compare --a FILE --b FILE [--cheaper] [--regression FILE]   FILEs hold JSON lists of records; a is the candidate
  compare.py stats [--prior FILE]    routing_stats of the benchmark file; the prior is a JSON list of {role, connection, model, score}
  compare.py record --file FILE      host only: add the benchmark records of FILE (a JSON list, no install_id) and their trusted lines
  compare.py check                   model-check.json and the benchmark file are usable
Exit: 0 ok; 1 refused or failed (catalog code and plain message on stderr, {code, problem} on stdout); 2 usage."""
import os, sys

if __name__ == "__main__" and not sys.flags.isolated:   # run directly: PYTHONPATH and the current folder must not decide what is imported
    try:
        os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
    except OSError:
        sys.exit("STL-CFG-310 compare.py could not restart itself isolated (python3 -I)")

import argparse, hashlib, json, math

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder

BAD_INPUT, REGRESSION, BAD_PARAMS, BAD_BENCH, UNEXPECTED = "STL-MDL-750", "STL-MDL-751", "STL-MDL-752", "STL-MDL-753", "STL-CFG-310"
KEY, SCHEMA_ID, LINE, CHUNK = "benchmark_results", "model-check", "benchmark.recorded", 100   # CHUNK: record digests in one event line   # the index key of the results file; the schema id of the parameters

class Stop(Exception):
    def __init__(self, code, problem, alert=True, out=None):
        super().__init__(problem)
        self.code, self.problem, self.alert, self.out = code, problem, alert, out or {}

# ---- the t quantile ----
def _betacf(a, b, x):
    """Continued fraction of the incomplete beta function (modified Lentz)."""
    tiny = 1e-300
    fix = lambda v: v if abs(v) > tiny else tiny
    c, d = 1.0, 1.0 / fix(1.0 - (a + b) * x / (a + 1.0))
    h = d
    for m in range(1, 1000):
        for num in (m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m)), -(a + m) * (a + b + m) * x / ((a + 2 * m) * (a + 2 * m + 1))):
            d = 1.0 / fix(1.0 + num * d)
            c = fix(1.0 + num / c)
            h *= d * c
        if abs(d * c - 1.0) < 1e-15:
            break
    return h

def _betai(a, b, x):
    """Regularized incomplete beta I_x(a, b)."""
    if x <= 0.0 or x >= 1.0:
        return 0.0 if x <= 0.0 else 1.0
    bt = math.exp(math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b) + a * math.log(x) + b * math.log1p(-x))
    return bt * _betacf(a, b, x) / a if x < (a + 1.0) / (a + b + 2.0) else 1.0 - bt * _betacf(b, a, 1.0 - x) / b

def t_quantile(q, df):
    """The t value t with P(T <= t) = q for df degrees of freedom (0.5 < q < 1)."""
    if not (0.5 < q < 1.0) or df < 1:
        raise ValueError("t_quantile needs 0.5 < q < 1 and df >= 1")
    tail = lambda t: 0.5 * _betai(df / 2.0, 0.5, df / (df + t * t))   # P(T > t), falling in t
    lo, hi = 0.0, 1.0
    while tail(hi) > 1.0 - q:
        lo, hi = hi, hi * 2.0
    for _ in range(200):
        mid = (lo + hi) / 2.0
        lo, hi = (mid, hi) if tail(mid) > 1.0 - q else (lo, mid)
    return (lo + hi) / 2.0

# ---- one comparison ----
def per_task(records):
    """{task: [trial values]} and {task: [passed flags]} of an arm; a malformed record is a ValueError."""
    vals, passes = {}, {}
    for r in records:
        if not (isinstance(r, dict) and isinstance(r.get("task"), str) and isinstance(r.get("passed"), bool)):
            raise ValueError("a record needs a string task and a boolean passed")
        s = r.get("score")
        if s is not None and (isinstance(s, bool) or not isinstance(s, (int, float)) or not 0 <= s <= 1):
            raise ValueError("a record's score is a number from 0 to 1")
        vals.setdefault(r["task"], []).append(float(r["passed"]) if s is None else float(s))
        passes.setdefault(r["task"], []).append(r["passed"])
    return vals, passes

def pass_k(records, k):
    """pass^k of an arm (see the module text); None when no task has k trials."""
    ps = [p for p in per_task(records)[1].values() if len(p) >= k]
    return math.fsum(math.comb(sum(p), k) / math.comb(len(p), k) for p in ps) / len(ps) if ps else None

def regression_ok(results, regression, params):
    """{ok, failed, checked}: the tasks of the regression set (passing true) the candidate's results do not keep passing."""
    _, passes = per_task(results)
    need, floor = sorted({r["task"] for r in regression if r.get("passing") is True}), params["regression_set"]["min_pass_rate"]
    failed = [t for t in need if t not in passes or sum(passes[t]) / len(passes[t]) < floor - 1e-12]
    return {"ok": not failed, "failed": failed, "checked": len(need)}

def compare_arms(a, b, params, cheaper=False, regression=None):
    """The full comparison of candidate a against b: {decision, reason, n_tasks, n_unpaired, mean_diff, ci, confidence, pass_k, ...}."""
    (va, _), (vb, _) = per_task(a), per_task(b)
    both = sorted(set(va) & set(vb))
    out = {"decision": "inconclusive", "reason": None, "n_tasks": len(both), "n_unpaired": len(set(va) ^ set(vb)), "mean_diff": None,
           "ci": None, "confidence": params["confidence"], "cheaper": bool(cheaper), "margin": params["margin"], "k": params["pass_k"],
           "pass_k": {"a": pass_k(a, params["pass_k"]), "b": pass_k(b, params["pass_k"])}}
    if regression is not None:
        g = regression_ok(a, regression, params)
        if not g["ok"]:
            return {**out, "decision": "worse", "reason": "regression_set", "failed": g["failed"]}
    n = len(both)
    if n < max(2, params["min_tasks"]):
        return {**out, "reason": "min_sample"}
    d = [math.fsum(va[t]) / len(va[t]) - math.fsum(vb[t]) / len(vb[t]) for t in both]
    m = math.fsum(d) / n
    sd = math.sqrt(math.fsum((x - m) ** 2 for x in d) / (n - 1))
    hw = t_quantile(1.0 - (1.0 - params["confidence"]) / 2.0, n - 1) * sd / math.sqrt(n)
    lo, hi = m - hw, m + hw
    out.update(mean_diff=m, ci=[lo, hi])
    if lo > 0:
        return {**out, "decision": "better", "reason": "interval_excludes_zero"}
    if cheaper and lo > -params["margin"]:
        return {**out, "decision": "non_inferior", "reason": "lower_bound_above_margin"}
    if hi < 0:
        return {**out, "decision": "worse", "reason": "interval_excludes_zero"}
    return {**out, "reason": "interval_crosses_margin" if cheaper else "interval_includes_zero"}

def decide(a, b, params, cheaper=False, regression=None):
    return compare_arms(a, b, params, cheaper, regression)["decision"]

# ---- routing stats ----
def routing_stats(records, prior, params):
    """[{role, connection, model, score, source (benchmark|prior|none), n (tasks), reason}] per link and role of the records and the prior."""
    by, adv = {}, {}
    for r in records:
        by.setdefault((r["role"], r["connection"], r["model"]), []).append(r)
    for p in prior:
        adv[(p["role"], p["connection"], p["model"])] = p["score"]
    out = []
    for k in sorted(set(by) | set(adv)):
        rs = by.get(k, [])
        if rs:   # the newest suite version only: scores of different suites are not one sample
            newest = max(rs, key=lambda r: (r["ts"], r["suite_version"]))["suite_version"]
            rs = [r for r in rs if r["suite_version"] == newest]
        vals = per_task(rs)[0] if rs else {}
        n = len(vals)
        if n and n >= params["routing_min_tasks"]:
            score, src, why = math.fsum(math.fsum(v) / len(v) for v in vals.values()) / n, "benchmark", "enough_tasks"
        else:
            score = adv.get(k)
            src, why = ("prior" if score is not None else "none"), ("min_sample" if n else "no_benchmark")
        out.append({"role": k[0], "connection": k[1], "model": k[2], "score": score, "source": src, "n": n, "reason": why})
    return out

# ---- the data: parameters and the benchmark file ----
def model_params():
    """The parameters of .stella/model-check.json as the data index serves them; a Stop (STL-MDL-752) when they cannot be used."""
    import stella_data as sd
    try:
        ids = [r["id"] for r in sd.rows() if r["format"] == "json" and r["schema"] == SCHEMA_ID]
        docs = [d for i in ids for _, d in sd.served(ids)["_rows"][i][0]]
        if len(docs) != 1:
            raise sd.DataError("the index has no single file of schema model-check")
    except (sd.DataError, OSError, ValueError, KeyError) as e:
        raise Stop(BAD_PARAMS, str(e)[:180])
    if docs[0]["pass_k"] > docs[0]["trials"]:
        raise Stop(BAD_PARAMS, "pass_k is above trials: pass^k could never be computed")
    return docs[0]

def digest(rec):
    return hashlib.sha256(json.dumps(rec, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

def read_benchmarks():
    """(the valid, proved records of this install, None), or ([], the problem) for a file or proof that cannot be read; a missing file is no record."""
    import event_log as el, stella_data as sd
    try:
        with open(el.path(sd.load(sd.INDEX)[KEY]), "rb") as f:
            doc = json.loads(f.read(el.MAX_FILE + 1))
        if not (isinstance(doc, dict) and isinstance(doc.get("records"), list) and doc.get("schema_version") == 1):
            return [], "the benchmark results file is not a document with schema_version 1 and records"
        item, iid = sd.schema_of("benchmarks")["properties"]["records"]["items"], sd.install_id()
        mine = [r for r in doc["records"] if not sd.validate_doc(r, item) and r["install_id"] == iid]
        proved = {x for d in el.proof_lines() if d.get("type") == LINE and isinstance(d.get("new"), dict)
                  for x in d["new"].get("digests", []) if isinstance(x, str)}
        return [r for r in mine if digest(r) in proved], None
    except FileNotFoundError:
        return [], None
    except (OSError, ValueError, RecursionError, KeyError, sd.DataError, el.EventError) as e:
        return [], f"the benchmark results cannot be read ({type(e).__name__})"

def record_results(rows):
    """Append benchmark records (dicts without install_id) to the results file and one trusted line per CHUNK of them; returns the count.
    A Stop (STL-MDL-753) when a row is invalid, the file cannot be read or no line can be written (nothing is written then)."""
    import event_log as el, stella_data as sd
    try:
        el.preflight()   # no record without its trusted line
        item, iid, p = sd.schema_of("benchmarks")["properties"]["records"]["items"], sd.install_id(), el.path(sd.load(sd.INDEX)[KEY])
        new = [{"install_id": iid, **r} for r in rows]
        for i, r in enumerate(new):
            if sd.validate_doc(r, item):
                raise Stop(BAD_BENCH, f"row {i} is not a benchmark record (schema benchmarks)", alert=False)
        import route
        with el.locked(p + ".lock"):
            try:
                with open(p, "rb") as f:
                    old = json.loads(f.read(el.MAX_FILE + 1))["records"]
            except FileNotFoundError:
                old = []
            route.write_whole(p, {"schema_version": 1, "records": old + new})
        for i in range(0, len(new), CHUNK):
            el.append(el.build(LINE, f"{len(new[i:i + CHUNK])} benchmark records", new={"digests": [digest(r) for r in new[i:i + CHUNK]]}))
    except (OSError, ValueError, RecursionError, KeyError, TypeError, sd.DataError, el.EventError) as e:
        raise Stop(BAD_BENCH, f"the benchmark results cannot be written ({type(e).__name__})")
    return len(new)

# ---- the CLI ----
def _load(path):
    try:
        with open(path, "rb") as f:
            got = json.loads(f.read(8 << 20))
    except (OSError, ValueError, RecursionError) as e:
        raise Stop(BAD_INPUT, f"{os.path.basename(path)}: cannot be read ({type(e).__name__})", alert=False)
    if not isinstance(got, list):
        raise Stop(BAD_INPUT, f"{os.path.basename(path)}: expected a JSON list", alert=False)
    return got

def cmd_compare(a):
    params = model_params()
    try:
        res = compare_arms(_load(a.a), _load(a.b), params, a.cheaper, _load(a.regression) if a.regression else None)
    except (ValueError, KeyError, TypeError) as e:
        raise Stop(BAD_INPUT, f"the records are not usable ({e})", alert=False)
    if res["reason"] == "regression_set":
        raise Stop(REGRESSION, "the candidate fails " + ", ".join(res["failed"]) + " of the regression set", alert=False, out=res)
    print(json.dumps(res))
    return 0

def cmd_stats(a):
    params = model_params()
    recs, why = read_benchmarks()   # fail closed: an unreadable file is no record, so the prior stands
    try:
        print(json.dumps(routing_stats(recs, _load(a.prior) if a.prior else [], params)))
    except (ValueError, KeyError, TypeError) as e:
        raise Stop(BAD_INPUT, f"the prior is not usable ({e})", alert=False)
    return 0

def cmd_record(a):
    import worker_env
    w = worker_env.reason()
    if w:
        raise Stop("STL-CFG-312", f"compare.py record runs on the host only ({w}); nothing was written")
    print(json.dumps({"recorded": record_results(_load(a.file))}))
    return 0

def cmd_check(a):
    model_params()
    recs, why = read_benchmarks()
    if why:
        raise Stop(BAD_BENCH, why, out={"ok": False, "benchmark_records": 0})
    print(json.dumps({"ok": True, "benchmark_records": len(recs), "problem": None}))
    return 0

def main(argv):
    ap = argparse.ArgumentParser(prog="compare.py", description="Sound comparison of two arms (paired trials, interval, pass^k).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("compare")
    p.add_argument("--a", required=True); p.add_argument("--b", required=True); p.add_argument("--regression")
    p.add_argument("--cheaper", action="store_true")
    sub.add_parser("stats").add_argument("--prior")
    sub.add_parser("check")
    sub.add_parser("record").add_argument("--file", required=True)
    for q in sub.choices.values():
        q.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    import event_log as el, stella_data as sd
    try:
        return {"compare": cmd_compare, "stats": cmd_stats, "check": cmd_check, "record": cmd_record}[a.cmd](a)
    except Stop as x:
        s = x
    except sd.DataError as e:
        s = Stop(BAD_PARAMS, str(e)[:180])
    except Exception as e:   # never a traceback, never the error's text (it could repeat a value): the type only
        s = Stop(UNEXPECTED, f"{type(e).__name__}, an unexpected failure of compare.py {a.cmd}")
    print(json.dumps({**s.out, "code": s.code, "problem": el.scrub(s.problem)}))
    el.say(s.code, s.problem, alert=s.alert)
    return 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
