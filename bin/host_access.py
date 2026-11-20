#!/usr/bin/env python3
"""Host-session and input-source risk decisions (F3 item H; body B11, AC10; design section 10, rulings DC-08, DC-09 amended, DC-10),
stdlib only. Host side: refused in a worker environment (bin/worker_env.py, STL-CFG-312) before it reads anything.
decide() is pure over data and host-written facts; it changes nothing. The request carries only {capability, role, run, request, target
{app, domain}, action {type}, confirmation} (request: the id the host wrote when the owner started the request): every other fact comes
from a record, never from the request:
  the capability's risk class and roles from the registry (index row capabilities, validated with its schema; risk_class
  host_session | input_source; status approved);
  the role's host_operator flag from the role table (absent = false; never a role's name);
  attended/background from the run record (index key adapter_runs, <dir>/<run>.json, written by the adapter);
  route, presence (indicator, kill switch, each input source's own indicator), device id + biometric and turn finality from the host
  presence record (index key host_presence, written by the host), which counts only when its run and request are the request's and its
  at is at most host-policy.json presence_max_age_s old (not in the future);
  the vault ids from .stella/host-policy.json never_targets (stack data, not a setting), read before the owner's host access settings;
  what may run from the owner's host access settings (index row host-access: master, routes, apps, domains, input sources, actions
  {state off|ask|run, reversible}, overrides {route|app, reversible_only});
  an ask-first confirmation from the approval service: the confirmation id names an approval request of the owner-auth policy's
  voice_host_confirmation action_class, approved in the trusted log, not expired, ttl at most the entry's max_ttl_s, whose action is
  exactly asked(request). A missing or unreadable fact refuses.
Refusal order, the first failing check wins: request shape (620), vault (623), capability (621), role flag (624), run record (625),
unattended/background (626), presence record (627), indicators (628), route (629), device + biometric (630), master switch (631),
app/domain (632), input source (633), action state (634), override (635), finality of an irreversible action (636), confirmation (637);
data that cannot be read: 622.
Final: a submitted typed or device command; a spoken turn the semantic detector closed (push-to-talk: its release) that did not reopen
within its grace window. A silence timeout alone is never final.
CLI: host_access.py decide --request FILE [--json]
Exit: 0 allowed; 1 refused (the code and its plain message on stderr; with --json also {allowed: false, code, problem} on stdout);
2 usage. No command ends in a traceback."""
import argparse, calendar, hashlib, hmac, json, os, re, sys, time
sys.dont_write_bytecode = True
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import roles
import stella_data as sd
import worker_env

RISK = ("host_session", "input_source")   # the risk classes this module decides
ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")   # capability, role, run, action and confirmation ids (no path separator)
NEEDED = {"capability", "role", "run", "request", "target", "action"}
KEYS = NEEDED | {"confirmation"}
VOICE = {"voice_ptt", "voice_wake", "voice_toggle"}   # route kinds whose request is a spoken turn (the schema's enum)
SUBMITTED = {"typed_host", "device"}   # route kinds whose request is final once submitted


class Refused(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def canon(x):
    return json.dumps(x, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def asked(q):
    """The approval action an ask-first request needs: bound to the whole request (old_digest), its details shown (new)."""
    core = {k: q[k] for k in sorted(NEEDED)}
    return {"op": "host:" + q["action"]["type"], "target": q["capability"],
            "old_digest": hashlib.sha256(canon(core).encode()).hexdigest(), "new": {k: core[k] for k in ("role", "run", "target", "action")}}


def shape(q):
    """None when q is a request of DC-10's shape, else the problem."""
    t, a = q.get("target") if isinstance(q, dict) else None, q.get("action") if isinstance(q, dict) else None
    if not (isinstance(q, dict) and set(q) <= KEYS and NEEDED <= set(q)):
        return "a request is {capability, role, run, request, target, action, confirmation} and nothing else (facts come from the records)"
    if not all(isinstance(q[k], str) and ID.fullmatch(q[k]) for k in ("capability", "role", "run", "request")):
        return "capability, role, run and request are ids"
    if not (isinstance(t, dict) and set(t) <= {"app", "domain"} and all(v is None or (isinstance(v, str) and ID.fullmatch(v)) for v in t.values())):
        return "target is {app, domain}, each an id or null"
    if not (isinstance(a, dict) and set(a) == {"type"} and isinstance(a["type"], str) and ID.fullmatch(a["type"])):
        return "action is {type}"
    c = q.get("confirmation")
    if not (c is None or (isinstance(c, str) and ID.fullmatch(c))):
        return "confirmation is an approval request id or null"
    return None


def low(v):
    return v.lower().rstrip(".") if isinstance(v, str) else None


def row(rid):
    """The validated document of the index row rid (one file)."""
    rel = next(r["path"] for r in sd.rows() if r["id"] == rid)
    return sd.checked(sd.load(rel), rel, rid)


def fact(key, schema, sub=None):
    """A host-written record under the index key (a folder of <sub>.json when sub is given), validated; None when there is none."""
    rel = sd.checked(sd.load(sd.INDEX), sd.INDEX, "data-files")[key]
    rel = f"{rel}/{sub}.json" if sub is not None else rel
    if not os.path.lexists(sd.safe(rel)):
        return None
    return sd.checked(sd.load(rel), rel, schema) if schema else sd.load(rel)


def need(ok, code, problem):
    if not ok:
        raise Refused(code, problem)


def final(kind, fin):
    """Whether the request is final for a route of this kind (E4: a silence timeout alone never is; a reopened turn never was)."""
    if not isinstance(fin, dict):
        return False
    turn = fin.get("turn") if isinstance(fin.get("turn"), dict) else {}
    if kind in SUBMITTED:
        return fin.get("state") == "submitted"
    ended = turn.get("detector") == "semantic" or (kind == "voice_ptt" and turn.get("detector") == "release")
    return kind in VOICE and fin.get("state") == "closed" and ended and turn.get("reopened_within_grace") is False


def confirmed(q):
    """None when q's confirmation is a matching approved host confirmation, else the problem."""
    import approvals, owner_auth as oa   # only an ask-first action reads the approval store and the trusted log
    rid = q.get("confirmation")
    if rid is None:
        return "an ask-first action has no confirmation"
    try:
        e = oa.policy()["voice_host_confirmation"]
        rec, req, dec, word = approvals.state(rid)
    except Exception as x:   # a store or log that cannot be read confirms nothing
        return f"the confirmation cannot be read ({getattr(x, 'code', type(x).__name__)})"
    if word != "approved":
        return f"confirmation {rid} is not an approved request of the approval service ({word or 'unknown'})"
    t0, t1 = oa.when(req.get("requested_at")), oa.when(req.get("expires_at"))
    if req.get("approval_class") != e["action_class"] or rec.get("approval_class") != e["action_class"]:
        return f"confirmation {rid} is not of class {e['action_class']}"
    if t0 is None or t1 is None or t1 - t0 > e["max_ttl_s"] or t1 <= time.time():
        return f"confirmation {rid} has expired or was asked for longer than {e['max_ttl_s']} s"
    try:
        want = oa.digest(asked(q))
    except ValueError:
        return "the request cannot be bound to a confirmation"
    if not isinstance(req.get("digest"), str):
        return f"confirmation {rid} has no digest of its action"
    if not hmac.compare_digest(req["digest"].encode(), want.encode()):
        return f"confirmation {rid} is for another action"
    return None


def decide(q):
    """{allowed: True, ...} or raise Refused(code, problem). Pure: reads data and host-written records, writes nothing."""
    bad = shape(q)
    need(bad is None, "STL-GRD-620", bad or "")
    cap, role, run, tgt, act = q["capability"], q["role"], q["run"], q["target"], q["action"]["type"]
    app, dom = low(tgt.get("app")), low(tgt.get("domain"))
    try:   # DC-09: the vault first, before the owner's settings are read
        hp = row("host-policy")
        never = hp["never_targets"]
    except (sd.DataError, StopIteration, KeyError) as e:
        raise Refused("STL-GRD-622", f"the host policy cannot be read: {e}") from None
    need(app not in {low(x) for x in never["apps"]} and not (dom and any(dom == low(v) or dom.endswith("." + low(v)) for v in never["domains"])),
         "STL-GRD-623", "the target is the Stella vault, which is never a host target")
    try:
        ent = next((e for e in row("capabilities")["entries"] if e["id"] == cap), None)
        rt = roles.load()
    except (sd.DataError, StopIteration, KeyError, TypeError, roles.RolesError) as e:
        raise Refused("STL-GRD-622", f"the capability registry or the role table cannot be read: {e}") from None
    need(ent is not None and ent["risk_class"] in RISK and ent["status"] == "approved", "STL-GRD-621",
         f"capability {cap} is not an approved host-session or input-source capability of the registry")
    need(isinstance(ent.get("allowed_roles"), list) and role in ent["allowed_roles"], "STL-GRD-621", f"capability {cap} is not granted to role {role}")
    need(isinstance(rt["roles"].get(role), dict) and rt["roles"][role].get("host_operator") is True, "STL-GRD-624",
         f"role {role} is not marked host_operator in the role table")
    try:
        rr = fact("adapter_runs", None, run)
        pres = fact("host_presence", "host-presence")
        ha = row("host-access")
    except (sd.DataError, KeyError) as e:
        raise Refused("STL-GRD-622", f"a record or the host access settings cannot be read: {e}") from None
    need(isinstance(rr, dict) and rr.get("run") == run and rr.get("role") == role, "STL-GRD-625", f"run {run} has no run record of role {role}")
    att = (rr.get("attended") is True or rr.get("unattended") is False) and rr.get("attended") is not False and rr.get("unattended") is not True
    need(att and rr.get("background") is False, "STL-GRD-626", f"run {run} is unattended or in the background (or its record does not say)")
    need(pres is not None, "STL-GRD-627", "there is no host presence record")
    need(pres["run"] == run and pres["request"] == q["request"], "STL-GRD-627", f"the host presence record is for another run or request than run {run}, request {q['request']}")
    try:   # the schema pins the format; a date that does not exist (Feb 30) is no time
        age = time.time() - calendar.timegm(time.strptime(pres["at"], "%Y-%m-%dT%H:%M:%SZ"))
    except ValueError:
        age = -1
    need(0 <= age <= hp["presence_max_age_s"], "STL-GRD-627", f"the host presence record is older than {hp['presence_max_age_s']} s or dated in the future")
    p = pres["presence"]
    need(p["indicator"] is True and p["kill_switch"] is True, "STL-GRD-628", "the on-screen indicator or the kill switch is not active")
    kind_cls = ent["risk_class"]
    need(kind_cls != "input_source" or p.get("input_indicators", {}).get(cap) is True, "STL-GRD-628", f"input source {cap} has no indicator of its own on")
    route = next((r for r in ha["routes"] if r["id"] == pres["route"]), None)
    need(route is not None and route["enabled"] is True, "STL-GRD-629", f"route {pres['route']} is not switched on in the host access settings")
    if route["kind"] == "device":
        dev = pres.get("device") or {}
        try:
            paired = {d["id"] for d in row("devices")["entries"]}
        except (sd.DataError, StopIteration) as e:
            raise Refused("STL-GRD-622", f"the device registry cannot be read: {e}") from None
        need(dev.get("id") is not None and dev.get("id") == route.get("device_id") and dev["id"] in paired and dev.get("biometric") is True,
             "STL-GRD-630", f"route {route['id']} needs its own paired device with its biometric")
    need(ha["enabled"] is True, "STL-GRD-631", "host access is switched off")
    on = lambda key, v: any(low(x["id"]) == v and x["enabled"] is True for x in ha.get(key, []))
    need(kind_cls == "input_source" or app or dom, "STL-GRD-632", "a host-session request names an app or a domain")
    need((app is None or on("apps", app)) and (dom is None or on("domains", dom)), "STL-GRD-632", "the app or the domain is not switched on in the host access settings")
    need(kind_cls != "input_source" or on("input_sources", low(cap)), "STL-GRD-633", f"input source {cap} is not switched on in the host access settings")
    a = next((x for x in ha["actions"] if x["id"] == act), None)
    need(a is not None and a["state"] in ("ask", "run"), "STL-GRD-634", f"action {act} is off or not in the host access settings")
    lim = [o for o in ha.get("overrides", []) if o.get("reversible_only") is True and (o.get("route") == route["id"] or (app and low(o.get("app")) == app))]
    need(a["reversible"] is True or not lim, "STL-GRD-635", f"an override allows only reversible actions here; {act} is not reversible")
    need(a["reversible"] is True or final(route["kind"], pres.get("final")), "STL-GRD-636", f"{act} is irreversible and its request is not final")
    if a["state"] == "ask":
        why = confirmed(q)
        need(why is None, "STL-GRD-637", why or "")
    return {"allowed": True, "capability": cap, "risk_class": kind_cls, "action": act, "state": a["state"], "route": route["id"]}


def main(argv):
    ap = argparse.ArgumentParser(prog="host_access.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decide")
    d.add_argument("--request", required=True)
    d.add_argument("--json", action="store_true")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    try:
        why = worker_env.reason()
        if why:
            raise Refused("STL-CFG-312", f"host access decisions are the host's: {why}")
        try:
            with open(a.request, encoding="utf-8") as f:
                q = json.load(f)
        except (OSError, ValueError, RecursionError) as e:
            raise Refused("STL-GRD-620", f"the request file cannot be read as JSON ({type(e).__name__})") from None
        out = decide(q)
    except Refused as r:
        if a.json:
            print(json.dumps({"allowed": False, "code": r.code, "problem": r.problem}))
        sd.say(r.code, r.problem)
        return 1
    print(json.dumps(out) if a.json else "allowed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
