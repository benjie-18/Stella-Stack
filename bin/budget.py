#!/usr/bin/env python3
"""Budgets, pause-or-defer holds, estimates and anomaly alerts (F2c item C), stdlib only. Every number, scope, window, threshold, word of the
request and detector parameter is in .stella/budgets.json (schema budgets); this file only reads it. Spend is read from the usage ledger
(bin/ledger.py lines) and summed by bin/cost.py rollup; the state (index key budget_state) is written here only.
Module: check(facts) -> {result: allow|warn|held, threshold, defer_to, code, reason, holds[]}; before_call(**facts) = check(), raises Held
when held (the hook other code calls before a call); estimate(kind, card), close(card), anomalies(), problems(doc).
CLI (host only, JSON out, --json accepted everywhere):
  budget.py check [--<scope> NAME]...   the facts of one call (a scope is a usage record field the data names). Exit 0 allow or warn; 1 held or failed.
  budget.py hold list                   the holds with their request ids, refreshed from the trusted answers
  budget.py estimate --kind K [--card C]   {estimate, basis: history|default|none, samples}; with --card the estimate is kept for close
  budget.py close --card C              the actual cost from the ledger, the estimate and the difference
  budget.py anomalies                   run the detectors: {new[], known[]}; one alert and one event line per new episode
  budget.py check-data                  judge .stella/budgets.json
A soft threshold alerts once per budget, key, period, cap and percent (STL-LIM-430). A hard cap makes one hold: one alert (431), one approval
request (bin/approvals.py request/deliver, class and text from the data), and every call of that key is refused with STL-LIM-432 until an
answer READ FROM THE TRUSTED EVENT LOG (approvals.current): approved applies the budget's on_approve (raise the cap by a percent, or defer to a
link the data policy allows for the project); denied, expired, unanswered, or a defer the policy refuses = paused. Text and the store's own
note decide nothing. A hold ends with its period (window_days). Anomalies (433): spend_rate, retry_loop, growing_session, outlier_card,
one alert and one trusted event line per fingerprint. 434 the budget data or state cannot be used (fail closed); 435 input unusable.
Exit: 0 ok; 1 refused or failed (catalog code and plain message on stderr, JSON on stdout); 2 usage.
shortcut: spend in a currency other than the cap's is not counted; an expired request is not renewed (a hold whose request could not be raised is retried at the next check);
in a worker environment check() only reads: it answers held for a hold or a new cap hit but writes no state, line or alert (the host's check makes the hold); the defer check reads resolve._data (the resolver's private loader); upgrade when it gets a public one."""
import argparse, datetime, hashlib, json, os, statistics, sys

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import approvals, cost, event_log as el, ledger, owner_auth as oa, stella_data as sd

SOFT, HOLD, HELD, ANOMALY, BADDATA, BADINPUT = "STL-LIM-430", "STL-LIM-431", "STL-LIM-432", "STL-LIM-433", "STL-LIM-434", "STL-LIM-435"
ROW, STATE_KEY = "budgets", "budget_state"   # the data row id and the index key of the state file

class Stop(Exception):
    def __init__(self, code, problem, alert=True):
        super().__init__(problem)
        self.code, self.problem, self.alert = code, problem, alert

class Held(Exception):
    def __init__(self, result):
        super().__init__(result["reason"])
        self.code, self.result = result["code"], result

def utcnow():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

# ---- data and state ----
def load_doc(judge=True):
    """The budgets data, schema-checked and (judge) its problems() empty; else Stop(STL-LIM-434): nothing is checked against data the tool would misread."""
    try:
        row = next(r for r in sd.rows() if r["id"] == ROW)
        doc = sd.checked(sd.load(row["path"]), row["path"], row["schema"])
    except (sd.DataError, StopIteration, KeyError) as e:
        raise Stop(BADDATA, f"the budgets data cannot be used: {str(e)[:160] or 'no row'}")
    bad = problems(doc) if judge else []
    if bad:
        raise Stop(BADDATA, f"the budgets data cannot be used: {bad[0][:160]}")
    return doc

def scopes():
    return sd.schema_of("budgets")["properties"]["budgets"]["items"]["properties"]["scope"]["enum"]

def problems(doc):
    """Plain problems the schema cannot say."""
    out, seen = [], set()
    try:
        cat = sd.served(["connections"])["connections"]
        classes = sd.schema_of("approval-request")["properties"]["approval_class"]["enum"]
    except (sd.DataError, KeyError) as e:
        return [f"the catalog or the approval schema cannot be read: {str(e)[:100]}"]
    if doc["approval"]["class"] not in classes:
        out.append(f"approval.class is one of {', '.join(classes)}")
    out += [f"unnamed_keys: {sc} is not a scope of the budgets schema" for sc in doc["unnamed_keys"] if sc not in scopes()]
    for b in doc["budgets"]:
        name = f"budget {sd.idn(b['id'])}"
        if (b["scope"], b["key"]) in seen:
            out.append(f"{name}: the scope and key are used twice")
        seen.add((b["scope"], b["key"]))
        if b["hard"] is None and b["plan_share_cap"] is None:
            out.append(f"{name}: it has neither a hard cap nor a plan-share cap")
        if b["hard"] is not None and b["hard"]["amount"] <= 0:
            out.append(f"{name}: the hard cap is more than zero")
        a = b["on_approve"]
        if a["option"] == "raise" and a["raise_percent"] is None:
            out.append(f"{name}: a raise needs raise_percent")
        if a["option"] == "defer":
            c = sd.entry(cat, a["connection"]) if a["connection"] else None
            if c is None or a["model"] not in [m["id"] for m in c.get("models", [])]:
                out.append(f"{name}: a defer needs a connection and model of the catalog")
    return out

def state_path():
    return el.path(sd.load(sd.INDEX)[STATE_KEY])

def load_state():
    try:
        with open(state_path(), "rb") as f:
            doc = json.loads(f.read(el.MAX_FILE + 1))
    except FileNotFoundError:
        return {"schema_version": 1, "soft": {}, "holds": {}, "cards": {}, "episodes": {}}
    except (OSError, ValueError, RecursionError, el.EventError) as e:
        raise Stop(BADDATA, f"the budget state cannot be read ({type(e).__name__})")
    errs = sd.validate_doc(doc, sd.schema_of("budget-state"))
    if errs:
        raise Stop(BADDATA, f"the budget state is not valid: {errs[0][:120]}")
    return doc

class Session:
    """The budget lock, held for one operation: data, state and ledger read under it, the state written whole on exit when it changed."""
    def __init__(self, quiet=False):
        self.quiet = quiet   # check(): in a worker environment nothing is written (see RO)
    def __enter__(self):
        global RO
        RO = self.quiet and readonly()
        el.preflight()   # no state change without its trusted event line
        self.lk = el.locked(state_path() + ".lock")
        self.lk.__enter__()
        self.doc, self.st = load_doc(), load_state()
        self.before = json.dumps(self.st, sort_keys=True)
        return self
    def __exit__(self, *a):
        try:
            if a[0] is None and not RO and json.dumps(self.st, sort_keys=True) != self.before:
                import route
                route.write_whole(state_path(), self.st)
        finally:
            return self.lk.__exit__(*a)
    def recs(self):
        try:
            return ledger.lines()[0]
        except ledger.Stop as e:
            raise Stop(e.code, e.problem)

RO = False   # set for one check() in a worker environment: no state, trusted line or alert is written

def readonly():
    try:
        oa.need_host("the budget state")
        return False
    except oa.Refusal:
        return True

def event(kind, what, new):
    if not RO:
        el.append(el.build(kind, what, new=new))

def say(code, what):
    if not RO:
        el.say(code, what, alert=True)

def when(ts):
    try:
        return ledger.when(ts)
    except (ValueError, TypeError):
        return None

# ---- the periods and the spend ----
def period(days, now):
    """(index, start time) of the budget period of `now`: whole days counted from the epoch; no days = one period for ever."""
    if days is None:
        return 0, datetime.datetime.fromtimestamp(0, datetime.timezone.utc)
    sec = int(datetime.timedelta(days=days).total_seconds())
    i = int(now.timestamp()) // sec
    return i, datetime.datetime.fromtimestamp(i * sec, datetime.timezone.utc)

def measures(b, key, recs, start, cap_of, unnamed=None):
    """The measures of budget b for `key` in the period: [{measure, spent, cap, currency}] (cost and plan_share; cap_of raises a cap).
    A record without the scope counts for the scope's unnamed key (the data's unnamed_keys)."""
    sc, none = b["scope"], (unnamed or {}).get(b["scope"])
    mine = [dict(r, **{sc: key}) for r in recs if (r.get(sc) if r.get(sc) is not None else none) == key and (when(r.get("ts")) or start) >= start]
    g = cost.rollup(mine, b["scope"]).get(key, {"cost": {}, "plan_share": 0})
    out = []
    if b["hard"] is not None:
        c = b["hard"]["currency"]
        out.append({"measure": "cost", "spent": g["cost"].get(c, 0), "cap": cap_of("cost", b["hard"]["amount"]), "currency": c})
    if b["plan_share_cap"] is not None:
        out.append({"measure": "plan_share", "spent": g["plan_share"], "cap": cap_of("plan_share", b["plan_share_cap"]), "currency": None})
    return out

def defer_ok(project, connection, model):
    """Whether the data policy of the project allows the link (the resolver's own rule: policy_allows for every policy of the project)."""
    try:
        import resolve
        d = resolve._data(project)
        prov = sd.entry(d.conn, connection)
        return bool(prov and prov.get("enabled") is not False and model in [m["id"] for m in prov.get("models", [])]
                    and all(sd.policy_allows(p, prov) for p in d.policies))
    except Exception:   # fail closed: a policy that cannot be read allows nothing
        return False

# ---- the approval request ----
def answer_word(rid):
    """pending|approved|denied|expired from the trusted log (approvals.current), None when it cannot be told."""
    try:
        cdoc, _ = approvals.channels()
        with approvals.lock():
            return approvals.current(rid, cdoc)[3]
    except (approvals.Refusal, sd.DataError, el.EventError, OSError):
        return None

def raise_request(doc, h):
    """(request id or None, problem): one request for the hold, delivered on every channel that may answer (as intake does)."""
    ap, a = doc["approval"], h["on_approve"]
    try:
        oa.need_host("a budget hold")
        action = {"op": ap["op"], "target": f"{ap['op']}:{h['id']}", "old_digest": hashlib.sha256(json.dumps(a, sort_keys=True).encode()).hexdigest(), "new": {k: h[k] for k in ("scope", "key", "measure", "spent", "cap")} | {"on_approve": a}}
        text = ap["summary"].format(scope=h["scope"], key=h["key"], measure=h["measure"], spent=h["spent"], cap=h["cap"], options="; ".join(ap["options"].values()))
        pol = oa.policy()
        cdoc, rows = approvals.channels()
        with approvals.lock():
            rec = approvals.request(ap["class"], action, text, h["card"] or f"{ap['card_prefix']}-{h['id']}", ap["ttl_s"])
            for cid, row in rows.items():
                if row["kind"] != pol["voice_host_confirmation"]["channel_kind"] and pol["channel_kinds"].get(row["kind"]) is True:
                    try:
                        approvals.deliver(rec["id"], cid, cdoc, row)
                    except approvals.Refusal as x:
                        sd.say(x.code, x.problem)
        return rec["id"], None
    except (approvals.Refusal, sd.DataError, el.EventError, OSError) as e:
        return None, str(getattr(e, "problem", e))[:160]

def settle(h):
    """Read the answer of the hold's request from the trusted log and set the hold's status; a change but held->held is one event line."""
    was = h["status"]
    word = answer_word(h["request_id"]) if h["request_id"] else None
    a = h["on_approve"]
    if word == "approved" and a["option"] == "raise":
        h.update(status="raised", reason=word, new_cap=round(h["cap"] * (1 + a["raise_percent"] / 100), 10))
    elif word == "approved" and a["option"] == "defer" and (h["scope"] != "project" or defer_ok(h["key"], a["connection"], a["model"])):   # other scopes: judged per caller in check()
        h.update(status="deferred", reason=word, defer_to={"connection": a["connection"], "model": a["model"]})
    else:
        h.update(status="held", reason=("defer-refused" if word == "approved" else word or "unanswered"), defer_to=None)
    if was != h["status"] and not (was == "held" and h["status"] == "held"):
        event("budget.hold-resolved", f"hold {h['id']} is now {h['status']}", {"hold": h["id"], "status": h["status"], "reason": h["reason"]})

# ---- check ----
def candidates(doc, facts):
    """[(budget, key)]: for each scope the call names, the budget of its key, else the * budget of the scope."""
    out = []
    for b in doc["budgets"]:
        v = facts.get(b["scope"])
        if v is not None and (b["key"] == v or (b["key"] == "*" and not any(x["scope"] == b["scope"] and x["key"] == v for x in doc["budgets"]))):
            out.append((b, v))
    return out

def announce(doc, h, b, m):
    """One alert, one trusted line and one approval request for a hold that is new or goes back to open."""
    h["request_id"], why = raise_request(doc, h)
    what = f"{b['scope']} {sd.idn(h['key'])}: {m['measure']} {m['spent']} reached the cap {m['cap']}; " + (f"approval request {h['request_id']}" if h["request_id"] else f"no approval request could be raised ({why})")
    say(HOLD, what)
    event("budget.hold", what, {k: h[k] for k in ("id", "budget", "scope", "key", "measure", "cap", "spent", "request_id")})

def refusal(h, reason, threshold=None):
    return {"result": "held", "code": HELD, "reason": reason, "threshold": threshold, "defer_to": None, "holds": [h],
            "problem": f"{h['scope']} {sd.idn(h['key'])} is held at its cap ({reason}); hold {h['id']}, request {h['request_id']}"}

def check(facts, now=None, session=None, link=None):
    """The verdict for one call whose facts are {scope: name}: held (a hold in force), warn (a soft threshold crossed), or allow.
    link {connection, model}: the link the call would use; after an approved defer only the defer link is allowed."""
    if session is None:
        with Session(quiet=True) as s:
            return check(facts, now, s, link)
    now, doc, st, recs = now or utcnow(), session.doc, session.st, session.recs()
    facts = {**{sc: k for sc, k in doc["unnamed_keys"].items() if facts.get(sc) is None}, **{k: v for k, v in facts.items() if v is not None}}   # a scope the call does not name: its unnamed key
    seen, held, defer, threshold = set(), [], None, None
    def deferred(h):   # a deferred hold: the caller's project must be allowed the link, else the hold stands for it
        nonlocal defer
        if defer_ok(facts.get("project"), h["defer_to"]["connection"], h["defer_to"]["model"]):
            defer = h["defer_to"]
        else:
            held.append(dict(h, status="held", reason="defer-refused", defer_to=None))
    for b, key in candidates(doc, facts):
        idx, start = period(b["window_days"], now)
        for h in st["holds"].values():   # a hold of an earlier period ends with it
            if (h["budget"], h["key"]) == (b["id"], key) and h["period"] != idx and h["status"] in ("held", "deferred"):
                h["status"] = "ended"
                event("budget.hold-resolved", f"hold {h['id']} ended with its period", {"hold": h["id"], "status": "ended", "reason": "period"})
        raised = lambda m, base: max([base] + [x["new_cap"] for x in st["holds"].values() if (x["budget"], x["key"], x["period"], x["measure"], x["status"]) == (b["id"], key, idx, m, "raised")])
        for m in measures(b, key, recs, start, raised, doc["unnamed_keys"]):
            hid = "h-" + hashlib.sha256("|".join(map(str, (b["id"], key, idx, m["measure"], m["cap"]))).encode()).hexdigest()[:12]
            fresh = hid not in st["holds"]
            if fresh and m["spent"] >= m["cap"]:
                h = st["holds"][hid] = {"id": hid, "budget": b["id"], "scope": b["scope"], "key": key, "project": facts.get("project"), "card": facts.get("card"),
                                        "measure": m["measure"], "period": idx, "cap": m["cap"], "spent": m["spent"], "currency": m["currency"], "on_approve": b["on_approve"],
                                        "status": "held", "reason": "pending", "request_id": None, "defer_to": None, "since": ledger.iso(now)}
                announce(doc, h, b, m)
            if hid in st["holds"]:
                h = st["holds"][hid]
                if h["status"] == "held" and h["request_id"] is None and not fresh and not RO:   # the request could not be raised before: try again
                    h["request_id"], _ = raise_request(doc, h)
                    if h["request_id"]:
                        event("budget.hold-requested", f"hold {h['id']} has its approval request {h['request_id']}", {"hold": h["id"], "request_id": h["request_id"]})
                if h["status"] in ("held", "deferred"):
                    settle(h)
                seen.add(hid)
                if h["status"] == "deferred":   # the budget is still measured: spend on any link but the defer link past what it was at the approval is a new hold
                    dl = h["defer_to"]
                    far = next(x for x in measures(b, key, [r for r in recs if (r.get("connection"), r.get("model")) != (dl["connection"], dl["model"])], start, raised, doc["unnamed_keys"]) if x["measure"] == m["measure"])["spent"]
                    if h.get("base") is None:
                        h["base"] = far
                    elif far > h["base"]:
                        h.update(status="held", reason="pending", defer_to=None, base=None, spent=far, since=ledger.iso(now))
                        announce(doc, h, b, dict(m, spent=far))
                        event("budget.hold-resolved", f"hold {h['id']} is held again: spend passed the cap while deferred", {"hold": h["id"], "status": "held", "reason": "deferred-overspend"})
                if h["status"] == "held":
                    held.append(h)
                elif h["status"] == "deferred":
                    deferred(h)
                continue
            for pct in sorted(b["soft_percent"]):
                if m["spent"] >= m["cap"] * pct / 100:
                    threshold = max(threshold or pct, pct)
                    k = "|".join(map(str, (b["id"], key, idx, m["measure"], m["cap"], pct)))
                    if k not in st["soft"]:
                        st["soft"][k] = ledger.iso(now)
                        what = f"{b['scope']} {sd.idn(key)}: {m['measure']} {m['spent']} passed {pct} percent of the cap {m['cap']}"
                        say(SOFT, what)
                        event("budget.soft", what, {"budget": b["id"], "key": key, "measure": m["measure"], "percent": pct, "spent": m["spent"], "cap": m["cap"]})
    for h in st["holds"].values():   # a hold whose budget is gone still refuses until it is answered
        if h["id"] not in seen and h["status"] in ("held", "deferred") and facts.get(h["scope"]) == h["key"]:
            settle(h)
            if h["status"] == "held":
                held.append(h)
            elif h["status"] == "deferred":
                deferred(h)
    if held:
        return refusal(held[0], held[0]["reason"], threshold) | {"holds": held}
    if defer and link and (link.get("connection"), link.get("model")) != (defer["connection"], defer["model"]):   # a deferred scope: no other link
        h = next(x for x in st["holds"].values() if x["status"] == "deferred" and x["defer_to"] == defer)
        return refusal(h, "deferred-link", threshold)
    return {"result": "warn" if threshold is not None else "allow", "threshold": threshold, "defer_to": defer, "holds": []}

def before_call(link=None, **facts):
    """The hook other code calls before a call: the verdict, or Held (its .code is the hold's catalog code) when the scope is held.
    A verdict with defer_to is no advice: the call goes to that link only (link names the one it would use; any other is Held)."""
    r = check(facts, link=link)
    if r["result"] == "held":
        raise Held(r)
    return r

# ---- estimate and close ----
def estimate(kind, card=None):
    with Session() as s:
        e = s.doc["estimate"]
        hist = [c["actual"] for c in s.st["cards"].values() if c.get("kind") == kind and c.get("actual")]
        dflt = e["kinds"].get(kind)
        ccy = dflt["currency"] if dflt else max((x["currency"] for x in hist), key=lambda c: sum(x["currency"] == c for x in hist), default=None)
        vals = [x["amount"] for x in hist if x["currency"] == ccy]
        if len(vals) >= e["min_history"]:
            out = {"amount": round(statistics.median(vals), 10), "currency": ccy}, "history"
        elif dflt:
            out = dict(dflt), "default"
        else:
            out = None, "none"
        if card is not None:
            s.st["cards"].setdefault(card, {})
            s.st["cards"][card].update(kind=kind, estimate=out[0], estimated_at=ledger.iso(utcnow()))
            event("budget.estimated", f"card {sd.idn(card)} of kind {sd.idn(kind)} estimated", {"card": card, "kind": kind, "estimate": out[0], "basis": out[1]})
        return {"kind": kind, "card": card, "estimate": out[0], "basis": out[1], "samples": len(vals)}

def close(card):
    with Session() as s:
        c = s.st["cards"].setdefault(card, {"kind": None, "estimate": None})
        spent = cost.rollup([r for r in s.recs() if r.get("card") == card], "card").get(card, {"cost": {}})["cost"]
        est = c.get("estimate")
        ccy = est["currency"] if est else next(iter(spent), None)
        actual = {"amount": spent.get(ccy, 0), "currency": ccy}
        diff = {"amount": round(actual["amount"] - est["amount"], 10), "currency": ccy} if est else None
        c.update(actual=actual, difference=diff, closed_at=ledger.iso(utcnow()))
        event("budget.closed", f"card {sd.idn(card)} closed", {"card": card, "actual": actual, "estimate": est, "difference": diff})
        return {"card": card, "kind": c.get("kind"), "estimate": est, "actual": actual, "difference": diff}

# ---- anomalies ----
def runs(seq, counts):
    """After each call of seq (one card or session, by time): the run (record, input) of calls that count and whose input tokens rise."""
    run = []
    for r in seq:
        i = r["tokens"]["input"] if isinstance(r.get("tokens"), dict) else 0
        if counts(r) and run and i > run[-1][1]:
            run.append((r, i))
        elif counts(r):
            run = [(r, i)]
        else:
            run = []
        yield list(run)

def detect(doc, st, recs, now):
    p, found = doc["anomalies"], []
    def recent(minutes):
        t = now - datetime.timedelta(minutes=minutes)
        return sorted([r for r in recs if (when(r.get("ts")) or t) >= t], key=lambda r: r.get("ts", ""))
    def amount(r):
        c = r.get("cost")
        return (c["currency"], c["amount"]) if c and c.get("priced") and isinstance(c.get("amount"), (int, float)) else None
    q = p["spend_rate"]
    w = datetime.timedelta(minutes=q["window_minutes"])
    sums = {}
    for r in recent(q["lookback_minutes"]):
        t, a = when(r["ts"]), amount(r)
        if a and t and t <= now:
            n = int((now - t) / w)   # 0 = the current window, 1.. the trailing ones
            sums.setdefault(a[0], {}).setdefault(n, 0)
            sums[a[0]][n] += a[1]
    for ccy, by in sums.items():
        med = statistics.median([by.get(i, 0) for i in range(1, q["trailing_windows"] + 1)])
        cur = by.get(0, 0)
        if med >= q["min_amount"] and cur >= q["min_amount"] and cur > q["factor"] * med:
            found.append({"kind": "spend_rate", "fp": f"spend_rate:{ccy}:{int(now.timestamp() // w.total_seconds())}",
                          "text": f"spend_rate: {cur:g} {ccy} in the last {q['window_minutes']} minutes against a normal {med:g}"})
    for kind, field, ok in (("retry_loop", "card", lambda r: r.get("outcome") not in ("ok", "refused")), ("growing_session", "session", lambda r: r.get("outcome") != "refused")):
        q = p[kind]
        groups = {}
        for r in recent(q["lookback_minutes"]):
            if r.get(field) is not None:
                groups.setdefault(r[field], []).append(r)
        for name, seq in groups.items():
            for run in runs(seq, ok):
                if len(run) >= q["min_calls"]:
                    found.append({"kind": kind, "fp": f"{kind}:{name}:{run[0][0]['ts']}", field: name, "calls": len(run),
                                  "text": f"{kind}: {field} {sd.idn(name)}: {len(run)} calls in a row with rising input tokens"})
    q = p["outlier_card"]
    per = cost.rollup(recent(q["lookback_minutes"]), "card")
    kinds = {}
    for card, c in st["cards"].items():
        for ccy, amt in per.get(card, {"cost": {}})["cost"].items():
            if c.get("kind"):
                kinds.setdefault((c["kind"], ccy), {})[card] = amt
    for (kind, ccy), cards in kinds.items():
        for card, amt in cards.items():
            others = [v for k, v in cards.items() if k != card]
            if len(others) >= q["min_cards"] and statistics.median(others) > 0 and amt > q["factor"] * statistics.median(others):
                found.append({"kind": "outlier_card", "fp": f"outlier_card:{card}", "card": card,
                              "text": f"outlier_card: card {sd.idn(card)} cost {amt:g} {ccy}, far above the usual {statistics.median(others):g} for kind {sd.idn(kind)}"})
    return list({f["fp"]: f for f in found}.values())   # a run is seen at every call that extends it: the last (longest) one stands

def anomalies(now=None):
    with Session() as s:
        now, new, known = now or utcnow(), [], []
        for f in detect(s.doc, s.st, s.recs(), now or utcnow()):
            if f["fp"] in s.st["episodes"]:
                known.append(f)
                continue
            s.st["episodes"][f["fp"]] = ledger.iso(now)
            el.say(ANOMALY, f["text"], alert=True)
            event("budget.anomaly", f["text"], {k: v for k, v in f.items() if k != "text"})
            new.append(f)
        return {"new": new, "known": known}

def hold_list():
    with Session() as s:
        for h in s.st["holds"].values():
            if h["status"] in ("held", "deferred"):
                settle(h)
        return {"holds": list(s.st["holds"].values())}

# ---- CLI ----
def main(argv):
    ap = argparse.ArgumentParser(prog="budget.py", description="Budgets, holds, estimates and anomaly alerts.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("check", "hold", "estimate", "close", "anomalies", "check-data"):
        p = sub.add_parser(name)
        p.add_argument("--json", action="store_true")
        if name == "check":
            for sc in scopes():
                p.add_argument(f"--{sc}")
        if name == "hold":
            p.add_argument("what", choices=["list"])
        if name == "estimate":
            p.add_argument("--kind", required=True)
        if name in ("estimate", "close"):
            p.add_argument("--card", required=name == "close")
    a = ap.parse_args(argv)
    try:
        oa.need_host("the budget tool")
        out = {"check": lambda: check({k: getattr(a, k) for k in scopes() if getattr(a, k)}), "hold": hold_list, "anomalies": anomalies,
               "estimate": lambda: estimate(a.kind, a.card), "close": lambda: close(a.card), "check-data": lambda: cmd_data()}[a.cmd]()
        print(json.dumps(out))
        if a.cmd == "check" and out["result"] == "held":
            el.say(out["code"], out["problem"])
            return 1
        return 0 if a.cmd != "check-data" or out["ok"] else 1
    except Stop as x:
        s = x
    except oa.Refusal as e:
        s = Stop(e.code, e.problem)
    except el.EventError as e:
        s = Stop(e.code, e.problem)
    except sd.DataError as e:
        s = Stop(BADDATA, str(e)[:180])
    except Exception as e:   # never a traceback, never the error's text (it could repeat a value): the type only
        s = Stop(BADINPUT, f"{type(e).__name__}, an unexpected failure of budget.py {a.cmd}")
    print(json.dumps({"code": s.code, "problem": el.scrub(s.problem), "ok": False}))
    el.say(s.code, s.problem, alert=s.alert)
    return 1

def cmd_data():
    try:
        bad = problems(load_doc(False))
    except Stop as x:
        bad = [x.problem]
    return {"ok": not bad, "problems": bad}

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
