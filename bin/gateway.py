#!/usr/bin/env python3
"""The policy gateway core (X1 item G1; body B4, AC4, AC5; design G1 with rulings X1-DC-07, X1-DC-09), stdlib only. One fail-closed
decision point every registered action passes before it runs. Stack data: the index row of schema `gateway` (action kinds with
their hook sites, evaluators, the decision event type); owner data: the row of schema `gateway-policy` (modes, the evaluator id,
the policies; written only through bin/stella-apply.py).
Library: check(kind, inputs, ctx) -> Decision {verdict, mode, code, reason, policy_version} (a dict, also read as attributes);
ctx = {role, run, card, project, adapter}. The caller runs its action unless verdict == "refuse".
  Mode: the project's own mode, else the global one; with no project, the strictest mode present (global or any project; DC-09).
  off: allow at once (no evaluation, no line, nothing read beyond the mode). audit / enforce: an unknown kind (731), no policy
  covering the kind (732), an evaluator not there or off (733), that cannot start (734), that fails (735), times out (736) or
  answers no allow/deny (737), or a deny (738) refuse in enforce and give would-refuse in audit; unreadable data refuses (730; an
  unreadable owner file counts as enforce). Then, before returning, one trusted line through event_log.append (type: the data's
  decision_event): kind, inputs masked (the index's redact keys and the catalog's value patterns), policy_version (sha256 of the
  canonical policies plus the evaluator entry used, DC-07), evaluator, mode, verdict, reason, code. When that line cannot be
  written (739, alerted): enforce refuses, audit allows. In a worker environment the log refuses, so only off passes there: a
  worker-side caller asks the engine-side PDP route (item G2).
  An evaluator is a subprocess (its argv, {stack} filled, no shell) fed the entry's request template on stdin: a string that is
  exactly one placeholder becomes the value itself (typed), other {name}s are filled as text (policy.fill). It runs in its own
  process group with PATH only in its environment and is killed whole at its timeout_s.
CLI: gateway.py check [--json]       the gateway data, the owner file and every evaluator entry (741)
     gateway.py decide --kind K --inputs JSON [--project P] [--role R] [--run X] [--card C] [--adapter A] [--json]
                                     check() once; exit 0 when the action may run (allow, or audit's would-refuse), 1 refused;
                                     refused in a worker environment (STL-CFG-312: it writes the trusted log)
     gateway.py lint [--json]        740: a kind with no hook, a hook file or function missing or not calling gateway.check with
                                     its kind (a literal, or a kind read from data), or code in this folder calling gateway.check
                                     with a literal kind the data does not hold
Exit: 0 ok; 1 refused or problems; 2 usage."""
import argparse, ast, glob, hashlib, json, os, re, signal, subprocess, sys
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import stella_data as sd
import worker_env

GW, POL = "gateway", "gateway-policy"   # the schemas of the two rows; each row is found in the index by its schema
MODES = ("off", "audit", "enforce")   # least to most strict
NAME = os.path.splitext(os.path.basename(__file__))[0]   # the module name a hook calls check() through
C = {"data": "STL-GRD-730", "kind": "STL-GRD-731", "nopol": "STL-GRD-732", "noeval": "STL-GRD-733", "start": "STL-GRD-734",
     "crash": "STL-GRD-735", "timeout": "STL-GRD-736", "garbage": "STL-GRD-737", "deny": "STL-GRD-738", "log": "STL-GRD-739",
     "lint": "STL-GRD-740", "check": "STL-GRD-741", "bug": "STL-GRD-742"}
OUT_MAX = 1 << 20   # shortcut: an evaluator answer above 1 MiB is a bad answer; the limit is in code, upgrade when the data carries one
PLACE = re.compile(r"\{(\w+)\}")
REQ_NAMES = {"kind", "role", "project", "run", "card", "adapter", "target", "inputs", "policies", "stack"}


class Refusal(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


class Decision(dict):
    __getattr__ = dict.get   # d["verdict"] and d.verdict both read it


def doc(schema):
    """(row, document) of the one row of that schema, the document passing its schema; Refusal 730 otherwise."""
    try:
        row = next((r for r in sd.rows() if r["schema"] == schema), None)
        if row is None:
            raise Refusal(C["data"], f"the index has no row of schema {schema}")
        return row, sd.checked(sd.load(row["path"]), row["path"], schema)
    except Refusal:
        raise
    except Exception as e:
        raise Refusal(C["data"], f"the {schema} data cannot be used: {str(e)[:160] if isinstance(e, sd.DataError) else type(e).__name__}")


def mode_of(pol, project):
    m = pol["mode"]
    if project is None:
        return max([m["global"], *m["projects"].values()], key=MODES.index)
    return m["projects"].get(project, m["global"])


def ptr(doc_, p):
    """The value at an RFC 6901 pointer; None when there is nothing there."""
    for x in p.split("/")[1:]:
        try:
            doc_ = doc_[int(x)] if isinstance(doc_, list) else doc_[x.replace("~1", "/").replace("~0", "~")]
        except (KeyError, IndexError, ValueError, TypeError):
            return None
    return doc_


def fill(t, v):
    """A request template filled from v: a string that is exactly one known placeholder becomes the value, typed."""
    if isinstance(t, str):
        m = PLACE.fullmatch(t)
        return v[m[1]] if m and m[1] in v else PLACE.sub(lambda m: str(v[m[1]]) if m[1] in v else m[0], t)
    if isinstance(t, list):
        return [fill(x, v) for x in t]
    if isinstance(t, dict):
        return {k: fill(x, v) for k, x in t.items()}
    return t


def version(pol, ev):
    """DC-07: sha256 of the canonical policies (id, kinds, text) plus the evaluator entry used (null when there is none)."""
    body = {"policies": [{k: p[k] for k in ("id", "kinds", "text")} for p in pol["policies"]], "evaluator": ev}
    return hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()


def shown(v, red):
    """v as a line may show it: keys the redactor names are ***, a string a value pattern hides is ***, an object with such a key is
    *** whole."""
    def m(x):
        if isinstance(x, str):
            return el.MASK if sd.hidden(x) else x
        if isinstance(x, list):
            return [m(y) for y in x]
        if isinstance(x, dict):
            return el.MASK if any(sd.hidden(str(k)) for k in x) else {k: m(y) for k, y in x.items()}
        return x
    return m(el.mask(v, red))


def text(x):
    return x if isinstance(x, str) else None if x is None else str(x)


def evaluate(gw, pol, kind, inputs, ctx, d):
    """Judge one action (mode audit or enforce): fills d's evaluator, policy_version and reason; Refusal for every refusal."""
    ev = next((e for e in gw["evaluators"] if e["id"] == pol["evaluator"]), None)
    d["evaluator"], d["policy_version"] = pol["evaluator"], version(pol, ev)
    kinds = {k["id"]: k for k in gw["action_kinds"]}
    if not isinstance(kind, str) or kind not in kinds:
        raise Refusal(C["kind"], f"action kind {sd.idn(kind, True)} is not in the gateway data")
    if not isinstance(inputs, dict):
        raise Refusal(C["kind"], f"the inputs of a {kind} action are not a JSON object")
    cover = [{"id": p["id"], "text": p["text"]} for p in pol["policies"] if kind in p["kinds"]]
    if not cover:
        raise Refusal(C["nopol"], f"no policy covers the action kind {kind}")
    if ev is None or ev["status"] != "approved":
        raise Refusal(C["noeval"], f"evaluator {sd.idn(pol['evaluator'], True)} is " + ("not in the gateway data" if ev is None else f"{ev['status']}"))
    target = ptr(inputs, kinds[kind]["target"]) if "target" in kinds[kind] else None
    vals = {"kind": kind, "inputs": inputs, "policies": cover, "stack": sd.ROOT, "target": target if isinstance(target, str) else "",
            **{k: "" if ctx.get(k) is None else text(ctx.get(k)) for k in ("role", "project", "run", "card", "adapter")}}
    argv = fill(ev["argv"], {"stack": sd.ROOT})   # only the stack folder: no input reaches a command line
    name, t = ev["id"], ev.get("timeout_s", gw["default_timeout_s"])
    try:
        req = json.dumps(fill(ev["request"], vals), ensure_ascii=True).encode()
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=sd.ROOT,
                             env={k: os.environ[k] for k in ("PATH",) if k in os.environ}, start_new_session=True)
    except (OSError, ValueError, TypeError) as e:
        raise Refusal(C["start"], f"evaluator {name} could not start: {type(e).__name__}")
    try:
        out, _ = p.communicate(req, timeout=t)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)   # the whole group: a child left holding the pipe would block the read below
        p.communicate()
        raise Refusal(C["timeout"], f"evaluator {name} gave no answer within {t} s")
    if p.returncode != 0:
        raise Refusal(C["crash"], f"evaluator {name} failed (exit {p.returncode})")
    try:
        if len(out) > OUT_MAX:
            raise ValueError("too long")
        ans = json.loads(out)
        verdict = ptr(ans, ev["verdict"]) if isinstance(ans, dict) else None
    except ValueError:
        verdict = None
    if verdict not in ("allow", "deny"):
        raise Refusal(C["garbage"], f"evaluator {name} gave no allow or deny")
    why = ptr(ans, ev["reason"])
    d["reason"] = f"evaluator {name}: {verdict} {kind}" + (f" ({why[:200]})" if isinstance(why, str) and why else "")
    if verdict == "deny":
        raise Refusal(C["deny"], d["reason"])


def check(kind, inputs, ctx):
    """The decision for one action, written to the trusted log before it is returned (mode audit or enforce)."""
    ctx = ctx if isinstance(ctx, dict) else {}
    d = {"mode": "enforce", "code": None, "reason": "", "policy_version": None, "evaluator": None}
    gw = None
    try:
        _, pol = doc(POL)
        project = ctx.get("project")
        d["mode"] = mode_of(pol, None if project is None else text(project))
        if d["mode"] == "off":
            return Decision(verdict="allow", mode="off", code=None, reason="the policy gateway is off", policy_version=None)
        grow, gw = doc(GW)
        evaluate(gw, pol, kind, inputs, ctx, d)
    except Refusal as r:
        d["code"], d["reason"] = r.code, r.problem
    except Exception as e:   # fail closed: what cannot be judged is a refusal
        d["code"], d["reason"] = C["bug"], f"{type(e).__name__} while judging the action"
    verdict = "allow" if d["code"] is None else "refuse" if d["mode"] == "enforce" else "would-refuse"
    try:
        red = el.redactor()
        el.note_secrets(inputs, red)   # a value under a masked key is scrubbed from the reason too
        reason = el.scrub(d["reason"])
        d["reason"] = el.MASK if sd.hidden(reason) else reason
        if gw is None:
            raise Refusal(C["data"], "the gateway data names no decision event type it can be read from")
        k = kind if isinstance(kind, str) and kind in {x["id"] for x in gw["action_kinds"]} else None
        new = {"kind": k or shown(text(kind), red), "inputs": shown(inputs, red), "policy_version": d["policy_version"],
               "evaluator": d["evaluator"], "mode": d["mode"], "verdict": verdict, "reason": d["reason"], "code": d["code"],
               **{x: shown(text(ctx.get(x)), red) for x in ("run", "card", "project", "adapter")}}
        el.append(el.build(gw["decision_event"], f"{grow['id']}/{k or 'unknown'}", new=new, code=d["code"],
                           who={"role": shown(text(ctx.get("role")), red)}))
    except Exception as e:
        why = f"{e.code} {e.problem}" if isinstance(e, (el.EventError, Refusal)) else type(e).__name__
        with_alert(C["log"], f"the decision ({verdict}) was not logged: {why[:200]}; " +
                   ("the action was refused" if d["mode"] == "enforce" else "the action may run (audit)"))
        if d["mode"] == "enforce":
            verdict, d["code"] = "refuse", d["code"] or C["log"]
    return Decision(verdict=verdict, mode=d["mode"], code=d["code"], reason=d["reason"], policy_version=d["policy_version"])


def with_alert(code, problem):
    try:
        el.say(code, problem, alert=True)
    except Exception:   # the alert is a second record; the decision stands without it
        print(f"{code} {problem}", file=sys.stderr)


# ---- check and lint ----
def problems():
    """[(code, problem)] of the gateway data, the owner file and the evaluator entries."""
    out = []
    try:
        rows = {s: doc(s) for s in (GW, POL)}
    except Refusal as r:
        return [(C["check"], r.problem)]
    for s, (row, _) in rows.items():
        out += [(C["check"], f"{d_}: {m}") for d_, m in sd.check(row["id"]) if d_ == row["id"]]
    gw, pol = rows[GW][1], rows[POL][1]
    kinds = [k["id"] for k in gw["action_kinds"]]
    evs = {e["id"]: e for e in gw["evaluators"]}
    for what, ids in (("action kind", kinds), ("evaluator", [e["id"] for e in gw["evaluators"]]), ("policy", [p["id"] for p in pol["policies"]])):
        out += [(C["check"], f"{what} {i} is listed twice") for i in sorted({i for i in ids if ids.count(i) > 1})]
    for e in gw["evaluators"]:
        bad = {n for s in sd.leaves(e["argv"]) for n in PLACE.findall(s)} - {"stack"}
        bad |= {n for s in [*sd.leaves(e["request"]), *iter_keys(e["request"])] if isinstance(s, str) for n in PLACE.findall(s)} - REQ_NAMES
        if bad:
            out.append((C["check"], f"evaluator {e['id']}: unknown placeholder(s) {', '.join(sorted(bad))}"))
    if pol["evaluator"] not in evs:
        out.append((C["check"], f"the gateway policy names evaluator {sd.idn(pol['evaluator'], True)}, not in the gateway data"))
    elif evs[pol["evaluator"]]["status"] != "approved":
        out.append((C["check"], f"the gateway policy names evaluator {pol['evaluator']}, which is {evs[pol['evaluator']]['status']}"))
    for p in pol["policies"]:
        out += [(C["check"], f"policy {p['id']} covers kind {k}, not in the gateway data") for k in p["kinds"] if k not in kinds]
    return out


def iter_keys(t):
    if isinstance(t, dict):
        for k, v in t.items():
            yield k
            yield from iter_keys(v)
    elif isinstance(t, list):
        for v in t:
            yield from iter_keys(v)


def calls(tree):
    """(call node, kind literal or None for a kind read at run time) of every gateway.check(...) call under tree."""
    for n in ast.walk(tree):
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "check" \
                and isinstance(n.func.value, ast.Name) and n.func.value.id == NAME:
            a = n.args[0] if n.args else next((k.value for k in n.keywords if k.arg == "kind"), None)
            yield n, a.value if isinstance(a, ast.Constant) and isinstance(a.value, str) else None


def parse(p):
    with open(p, encoding="utf-8") as f:
        return ast.parse(f.read(), p)


def lint():
    """[problem] (each naming its kind) of the hook rule."""
    gw = doc(GW)[1]
    out, known = [], {k["id"] for k in gw["action_kinds"]}
    for k in gw["action_kinds"]:
        if not k["hooks"]:
            out.append(f"action kind {k['id']}: no hook (name the function that calls {NAME}.check with it before the action)")
        for h in k["hooks"]:
            p = os.path.realpath(os.path.join(sd.ROOT, h["file"]))
            at = f"action kind {k['id']}: hook {h['file']}:{h['function']}"
            if not el.inside(p, sd.ROOT) or not os.path.isfile(p):
                out.append(f"{at}: the file is missing")
                continue
            try:
                fns = [n for n in ast.walk(parse(p)) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == h["function"]]
            except (OSError, SyntaxError, ValueError) as e:
                out.append(f"{at}: the file cannot be read ({type(e).__name__})")
                continue
            if not fns:
                out.append(f"{at}: the function is missing")
            elif not any(lit in (k["id"], None) for fn in fns for _, lit in calls(fn)):
                out.append(f"{at}: the function does not call {NAME}.check with {k['id']}")
    for f in sorted(glob.glob(os.path.join(BIN, "*.py"))):
        if os.path.realpath(f) == os.path.realpath(__file__):
            continue
        try:
            found = list(calls(parse(f)))
        except (OSError, SyntaxError, ValueError):
            continue   # a file that does not parse fails its own checks; it holds no call this lint can read
        out += [f"action kind {lit}: {os.path.relpath(f, sd.ROOT)}:{n.lineno} calls {NAME}.check with it, but it is not in the gateway data"
                for n, lit in found if lit is not None and lit not in known]
    return out


def main(argv):
    ap = argparse.ArgumentParser(prog="gateway.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("check", "lint"):
        sub.add_parser(c).add_argument("--json", action="store_true")
    dp = sub.add_parser("decide")
    dp.add_argument("--kind", required=True)
    dp.add_argument("--inputs", required=True)
    for x in ("project", "role", "run", "card", "adapter"):
        dp.add_argument(f"--{x}")
    dp.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "decide":
            w = worker_env.reason()
            if w:
                el.say("STL-CFG-312", f"{w}: a gateway decision writes the trusted event log, the engine's own; nothing was decided")
                return 1
            try:
                inputs = json.loads(a.inputs)
            except ValueError:
                print("gateway.py decide: --inputs is not JSON", file=sys.stderr)
                return 2
            d = check(a.kind, inputs, {x: getattr(a, x) for x in ("role", "run", "card", "project", "adapter")})
            print(json.dumps(d) if a.json else f"{d['verdict']} ({d['mode']}){' ' + d['code'] if d['code'] else ''}: {d['reason']}")
            if d["verdict"] == "refuse":
                el.say(d["code"], d["reason"])
                return 1
            return 0
        found = problems() if a.cmd == "check" else [(C["lint"], m) for m in lint()]
        if a.json:
            print(json.dumps({"ok": not found, "problems": [{"code": c, "problem": m} for c, m in found]}, indent=2))
        else:
            print("\n".join(f"{c} {m}" for c, m in found) or f"gateway {a.cmd} OK")
        if found:
            el.say(found[0][0], f"{len(found)} problem(s), the first: {found[0][1][:200]}")
        return 1 if found else 0
    except Refusal as r:
        el.say(r.code, r.problem)
        return 1
    except Exception as e:
        el.say(C["bug"], f"{type(e).__name__} in gateway.py {a.cmd}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
