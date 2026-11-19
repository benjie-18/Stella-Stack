#!/usr/bin/env python3
"""Run policy per role (F3 item X; body B7, B8), stdlib only. Every number, text and pattern is data: .stella/run-policy.json (schema run-policy).
  check [--json]                     the data file: schema, every role of docs/hermes-local/roles.json has an entry, the default is complete,
                                     output styles and filters named by a role exist, every filter pattern compiles.
  show --role R                      the role's effective policy (default with the role's fields on top).
  translate --adapter A --role R     the settings fragment for adapter A: each policy feature the adapter's .stella/adapters.json entry says it
                                     supports (supports.<feature> is true) is filled into that entry's run_policy.<feature> template; the rest
                                     are listed under unsupported (false, "unverified" or absent). A template string that is exactly "{name}"
                                     takes the typed value of the policy field's key, inside a longer string it is replaced as text.
  prefill --role R (--tokens N | --file F)   compare the first-call prefill (from the CLI's usage, or estimated from a file) with prefill_budget_tokens.
  output-check --role R --events F   sum the output tokens of the run's trusted tool stream (usage events) and compare with output_budget_tokens;
                                     over budget is flagged (one event line, STL-LIM-452), the run is not stopped.
Exit: 0 ok; 1 refused or over budget ({code, problem} on stdout, catalog code and plain message on stderr); 2 usage.
Codes: STL-LIM-450 run policy file unusable, 451 prefill over budget, 452 output over budget, 453 an input unusable (adapter, role, file).
shortcut: a template's placeholders are whole-string or embedded text only (no nesting rules), upgrade when an adapter needs computed values."""
import argparse, json, math, os, sys

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import stella_data as sd

BADDATA, PREFILL, OUTPUT, BADINPUT = "STL-LIM-450", "STL-LIM-451", "STL-LIM-452", "STL-LIM-453"
OVER_EVENT = "run.output_over_budget"
ROW, ADAPTERS, ROLES = "run-policy", ".stella/adapters.json", "docs/hermes-local/roles.json"
# adapter supports key -> run-policy field it carries (the CLI features of body B7 and B8)
FEATURES = {"deferred_tools": "core_tools", "compaction": "compaction", "clear_tool_results": "clear_tool_results", "subagent": "explore_in_subagent",
            "working_notes": "working_notes", "hook": "filters"}
FIELDS = ["core_tools", "prefill_budget_tokens", "output_budget_tokens", "compaction", "clear_tool_results", "working_notes", "explore_in_subagent",
          "graph_first", "output_style", "filters"]

class Stop(Exception):
    def __init__(self, code, problem, alert=True):
        super().__init__(problem)
        self.code, self.problem, self.alert = code, problem, alert

def role_names():
    try:
        with open(os.path.join(sd.ROOT, ROLES), encoding="utf-8") as f:
            return list(json.load(f)["roles"])
    except (OSError, ValueError, KeyError, TypeError):
        raise Stop(BADDATA, "the role table cannot be read to check the run policy")

def load():
    import re
    try:
        sd.served([ROW])
        row = next(r for r in sd.rows() if r["id"] == ROW)
        t = sd.checked(sd.load(row["path"]), row["path"], row["schema"])
    except (sd.DataError, StopIteration) as e:
        raise Stop(BADDATA, f"the run policy file cannot be used: {str(e)[:160]}")
    bad = [f"default has no {sd.idn(k)}" for k in FIELDS if k not in t["default"]]
    bad += [f"role {sd.idn(r)} has no entry" for r in role_names() if r not in t["roles"]]
    ids = [f["id"] for f in t["filters"]]
    bad += [f"filter {sd.idn(i)} is defined twice" for i in set(ids) if ids.count(i) > 1]
    for f in t["filters"]:
        try:
            re.compile(f["pattern"])
        except re.error:
            bad.append(f"filter {sd.idn(f['id'])} has a pattern that does not compile")
    for who, s in [("default", t["default"]), *t["roles"].items()]:
        bad += [f"{sd.idn(who)} names filter {sd.idn(i)}, which is not defined" for i in s.get("filters", []) if i not in ids]
        if s.get("output_style", t["default"].get("output_style")) not in t["output_styles"]:
            bad.append(f"{sd.idn(who)} names an output style that is not defined")
    if bad:
        raise Stop(BADDATA, bad[0] + (f" (and {len(bad) - 1} more)" if len(bad) > 1 else ""))
    return t

def effective(t, role):
    if role not in t["roles"]:
        raise Stop(BADINPUT, f"there is no run policy for role {sd.idn(role)}", alert=False)
    return {**t["default"], **t["roles"][role]}

def estimate(t, text):
    return math.ceil(len(text) / t["token_estimate"]["chars_per_token"])

def fill(tpl, ctx):
    if isinstance(tpl, str):
        if tpl.startswith("{") and tpl.endswith("}") and tpl[1:-1] in ctx:
            return ctx[tpl[1:-1]]
        for k, v in ctx.items():
            tpl = tpl.replace("{" + k + "}", json.dumps(v) if not isinstance(v, str) else v)
        return tpl
    if isinstance(tpl, list):
        return [fill(x, ctx) for x in tpl]
    if isinstance(tpl, dict):
        return {k: fill(v, ctx) for k, v in tpl.items()}
    return tpl

def merge(a, b):
    for k, v in b.items():
        a[k] = merge(a[k], v) if isinstance(a.get(k), dict) and isinstance(v, dict) else v
    return a

def translate(t, adapter, role):
    pol = effective(t, role)
    try:
        with open(os.path.join(sd.ROOT, ADAPTERS), encoding="utf-8") as f:
            ents = json.load(f)["entries"]
        ent = next((e for e in ents if e["id"] == adapter), None)
    except (OSError, ValueError, KeyError, TypeError):
        raise Stop(BADINPUT, "the adapter table cannot be read", alert=False)
    if ent is None:
        raise Stop(BADINPUT, f"there is no adapter {sd.idn(adapter)}", alert=False)
    sup, tpls = ent.get("supports") or {}, ent.get("run_policy") or {}
    settings, applied, unsupported = {}, [], []
    for feat, field in FEATURES.items():
        if sup.get(feat) is not True:
            unsupported.append(feat)
            continue
        v = pol[field]
        ctx = dict(v) if isinstance(v, dict) else {}
        ctx["value"] = v
        if feat in tpls:
            merge(settings, fill(tpls[feat], ctx))
        applied.append(feat)
    return {"adapter": adapter, "role": role, "settings": settings, "applied": applied, "unsupported": unsupported,
            "supports": {f: sup.get(f, False) for f in FEATURES}, "output_style": t["output_styles"][pol["output_style"]], "core_tools": pol["core_tools"],
            "notes": pol["working_notes"], "graph_first": pol["graph_first"]}

def over(code, what, used, budget, role):
    ok = used <= budget
    out = {"role": role, "used": used, "budget": budget, "ok": ok}
    if not ok:
        out.update(code=code, problem=f"{what} of role {sd.idn(role)} is {used} tokens, over its budget of {budget}")
    return out

def main(argv):
    ap = argparse.ArgumentParser(prog="run_policy.py", description="Run policy per role.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check"); c.add_argument("--json", action="store_true")
    for n in ("show", "translate", "prefill", "output-check"):
        p = sub.add_parser(n); p.add_argument("--role", required=True); p.add_argument("--json", action="store_true")
        if n == "translate":
            p.add_argument("--adapter", required=True)
        if n == "prefill":
            p.add_argument("--tokens", type=int); p.add_argument("--file")
        if n == "output-check":
            p.add_argument("--events", required=True)
    a = ap.parse_args(argv)
    try:
        t = load()
        if a.cmd == "check":
            out = {"ok": True, "roles": len(t["roles"]), "filters": len(t["filters"])}
        elif a.cmd == "show":
            out = {"role": a.role, **effective(t, a.role)}
        elif a.cmd == "translate":
            out = translate(t, a.adapter, a.role)
        elif a.cmd == "prefill":
            pol = effective(t, a.role)
            if (a.tokens is None) == (a.file is None):
                ap.error("give exactly one of --tokens, --file")
            try:
                n = a.tokens if a.file is None else estimate(t, open(a.file, encoding="utf-8", errors="replace").read())
            except OSError:
                raise Stop(BADINPUT, "the prefill file cannot be read", alert=False)
            out = over(PREFILL, "the prefill", n, pol["prefill_budget_tokens"], a.role)
        else:
            pol = effective(t, a.role)
            n, run = 0, None
            try:
                with open(a.events, encoding="utf-8", errors="replace") as f:
                    for line in f:
                        try:
                            e = json.loads(line)
                        except ValueError:
                            continue   # a torn last line of a live stream
                        if isinstance(e, dict) and e.get("type") == "usage":
                            run = run or e.get("run")
                            n += int((e.get("tokens") or {}).get("output") or 0)
            except (OSError, TypeError, ValueError):
                raise Stop(BADINPUT, "the events file cannot be read", alert=False)
            out = over(OUTPUT, "the output", n, pol["output_budget_tokens"], a.role)
            if not out["ok"]:   # the one event line of the flag; a flag, not a stop
                el.append(el.build(OVER_EVENT, f"run {run}", code=OUTPUT, new={"role": a.role, "used": n, "budget": out["budget"]}, who={"role": a.role}))
        print(json.dumps(out))
        if out.get("ok") is False:   # over budget: flagged, never a stop of the run (that is the caller's choice)
            el.say(out["code"], out["problem"], alert=a.cmd == "output-check")
            return 1
        return 0
    except Stop as x:
        s = x
    except el.EventError as e:
        s = Stop(e.code, e.problem)
    except sd.DataError as e:
        s = Stop(BADDATA, str(e)[:180])
    except Exception as e:   # never a traceback, never the error's text (it could repeat a value): the type only
        s = Stop(BADINPUT, f"{type(e).__name__}, an unexpected failure of run_policy.py {a.cmd}")
    print(json.dumps({"code": s.code, "problem": el.scrub(s.problem)}))
    el.say(s.code, s.problem, alert=s.alert)
    return 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
