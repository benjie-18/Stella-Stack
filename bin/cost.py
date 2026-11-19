#!/usr/bin/env python3
"""Cost accounting (F2c item B), stdlib only: prices a usage record from the dated table of the data row pricing, turns it into an
OpenTelemetry GenAI span, rolls records up, and (behind the features.json flag otlp-export, off) exports spans as OTLP/HTTP JSON.
Usage record and span: the shapes in the F2c design (usage record: one JSON line per call; tokens input, output, cache_write, cache_read,
reasoning, counted apart; cost {amount, currency, entry, priced}|null).
Module: price(record, table) -> cost object | None; span_of(record); write_span(span); rollup(records, by); cache_hit_rate(records, by);
usage_of(protocol, body) -> the five token counts of an answer (protocols.json response.usage and usage_extra); export(spans) -> count.
  price     [--record FILE|-] --json   {cost, plan_share}: a cli-login record has cost null; a model with no row is cost.priced false and one STL-LIM-420
  span      [--record FILE|-] [--write] --json   the span (--write appends it to the file of index key spans)
  rollup    --by card|project|role|model|connection [--records FILE] --json   calls, tokens, cost per currency, unpriced, cache_hit_rate per group
  check     --json   judge the table: schema, the connection and model are in the catalog, one row per link and date
  export    [--record FILE|-|--spans] --json   send spans to the endpoint of the enabled connections-catalog app whose subkind is otlp-export
Exit: 0 ok; 1 refused or failed (catalog code and plain message on stderr, {code, problem} on stdout); 2 usage.
The endpoint is owner data: a connections catalog entry (kind app, subkind otlp-export, its first host, its first secret as the bearer token);
with the flag off, or no such enabled entry, nothing is sent and no socket is opened. Secrets are scrubbed from the payload and every output.
shortcut: the unpriced alert is once per model per process (no state file), upgrade when the ledger holds a per-model alert state."""
import argparse, hashlib, ipaddress, json, os, sys, urllib.request
from datetime import datetime

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import stella_data as sd

UNPRICED, BADTABLE, EXPORT, BADINPUT = "STL-LIM-420", "STL-LIM-421", "STL-LIM-422", "STL-LIM-423"
SPANS, LEDGER, FLAG, TABLE = "spans", "usage_ledger", "otlp-export", "pricing"   # index keys; the feature flag and the pricing row id (the app's subkind is the flag)
NS = "stella"   # the attribute namespace of the span design, also the service name
TYPES = ("input", "output", "cache_write", "cache_read", "reasoning")
BY = ("card", "project", "role", "model", "connection")
SAID = set()   # (connection, model) already alerted unpriced in this process

class Stop(Exception):
    def __init__(self, code, problem, alert=True):
        super().__init__(problem)
        self.code, self.problem, self.alert = code, problem, alert

def _route():
    import route   # heavy: only where a call goes out or a pointer is read
    return route

# ---- the table ----
def load_table():
    """The pricing rows (a list), judged by the data tool (schema, every connection in the catalog); Stop when it is broken."""
    try:
        return list(sd.served([TABLE])[TABLE].values())
    except (sd.DataError, KeyError) as e:
        raise Stop(BADTABLE, f"the pricing table cannot be used: {str(e)[:160]}")

def table_problems(table):
    """Plain problems of a loaded table the schema cannot say: a model the connection does not list, a link and date twice."""
    try:
        cat = sd.served(["connections"])["connections"]
    except sd.DataError as e:
        return [f"the connections catalog cannot be read: {str(e)[:120]}"]
    out, seen = [], set()
    for e in table:
        c = cat.get(e["connection"]) or next((x for x in cat.values() if x.get("global_id") == e["connection"]), {})
        if e["model"] not in [m["id"] for m in c.get("models", [])]:
            out.append(f"row {sd.idn(e['id'])}: connection {sd.idn(e['connection'])} does not list model {sd.idn(e['model'])}")
        k = (e["connection"], e["model"], e["effective_from"])
        if k in seen:
            out.append(f"row {sd.idn(e['id'])}: this link already has a row from {e['effective_from']}")
        seen.add(k)
    return out

def cli_links():
    try:
        return {i for i, c in sd.served(["connections"])["connections"].items() if c.get("type") == "cli-login"}
    except sd.DataError:
        return set()

# ---- pricing ----
def need(rec):
    """The record's fields cost.py reads, or a Stop: a record is data from outside this file."""
    t = rec.get("tokens") if isinstance(rec, dict) else None
    if not (isinstance(rec, dict) and all(isinstance(rec.get(k), str) and rec[k] for k in ("connection", "model", "ts"))
            and isinstance(t, dict) and all(type(t.get(k, 0)) is int and t.get(k, 0) >= 0 for k in TYPES)):
        raise Stop(BADINPUT, "a usage record needs connection, model and ts (text) and token counts that are whole numbers", alert=False)
    return rec

def price(rec, table, cli=None, alert=True):
    """The cost object of one record: None for a cli-login connection (its plan_share speaks); else the newest table row for the link whose
    effective_from is not after the call's ts prices the five token types apart (a batch call loses the row's batch_discount). No row:
    {amount: None, priced: False} and one alert per model, never a guess. cli: the cli-login connection ids (default: the catalog's)."""
    need(rec)
    if rec["connection"] in (cli_links() if cli is None else cli):
        return None
    rows = [e for e in table if e["connection"] == rec["connection"] and e["model"] == rec["model"] and e["effective_from"] <= rec["ts"]]
    if not rows:
        k = (rec["connection"], rec["model"])
        if alert and k not in SAID:
            SAID.add(k)
            el.say(UNPRICED, f"model {sd.idn(rec['model'])} of connection {sd.idn(rec['connection'])} has no pricing row dated {rec['ts'][:10]} or earlier", alert=True)
        return {"amount": None, "currency": None, "entry": None, "priced": False}
    e = max(rows, key=lambda x: x["effective_from"])
    amount = sum(rec["tokens"].get(t, 0) * e["per_million"][t] for t in TYPES) / 1e6
    if rec.get("batch"):
        amount *= 1 - e["batch_discount"]
    return {"amount": round(amount, 10), "currency": e["currency"], "entry": e["id"], "priced": True}

# ---- spans ----
def span_of(rec):
    """The OpenTelemetry GenAI span of a usage record (attribute names as the design lists them; an unknown value is left out)."""
    need(rec)
    dt = datetime.fromisoformat(rec["ts"].replace("Z", "+00:00"))
    start = int(dt.timestamp()) * 10**9 + dt.microsecond * 1000
    h = hashlib.sha256((rec.get("id") or json.dumps(rec, sort_keys=True)).encode()).hexdigest()
    c, t = rec.get("cost"), rec["tokens"]
    attrs = {"gen_ai.operation.name": "chat", "gen_ai.request.model": rec["model"], "gen_ai.provider.name": rec["connection"],
             "gen_ai.usage.input_tokens": t.get("input", 0), "gen_ai.usage.output_tokens": t.get("output", 0),
             "gen_ai.usage.cache_creation.input_tokens": t.get("cache_write", 0), "gen_ai.usage.cache_read.input_tokens": t.get("cache_read", 0),
             "gen_ai.usage.reasoning.output_tokens": t.get("reasoning", 0), f"{NS}.role": rec.get("role"), f"{NS}.project": rec.get("project"),
             f"{NS}.card": rec.get("card"), f"{NS}.cost": c["amount"] if c and c.get("priced") else None, f"{NS}.batch": bool(rec.get("batch"))}
    return {"name": f"chat {rec['model']}", "trace_id": h[:32], "span_id": h[32:48], "start_time_unix_nano": start,
            "end_time_unix_nano": start + int(rec.get("latency_ms") or 0) * 10**6, "status": 1 if rec.get("outcome", "ok") == "ok" else 2,
            "attributes": {k: v for k, v in attrs.items() if v is not None}}

def write_span(span):
    """Append the span as one line to the file of index key spans (under its lock)."""
    p = el.path(sd.load(sd.INDEX)[SPANS])
    with el.locked(p + ".lock"):
        fd = el.open_file(p, os.O_WRONLY | os.O_APPEND | os.O_CREAT)
        with os.fdopen(fd, "a", encoding="utf-8") as f:
            f.write(el.scrub(json.dumps(span)) + "\n")

# ---- rollups ----
def rollup(records, by):
    """{group key: {calls, tokens per type, cost per currency, unpriced, plan_share, cache_hit_rate}} for records grouped by `by`."""
    if by not in BY:
        raise Stop(BADINPUT, f"--by is one of {', '.join(BY)}", alert=False)
    g = {}
    for r in records:
        k = r.get(by)
        x = g.setdefault("(none)" if k is None else str(k), {"calls": 0, "tokens": dict.fromkeys(TYPES, 0), "cost": {}, "unpriced": 0, "plan_share": 0})
        x["calls"] += 1
        for t in TYPES:
            x["tokens"][t] += (r.get("tokens") or {}).get(t, 0)
        c = r.get("cost")
        if c and c.get("priced"):
            x["cost"][c["currency"]] = round(x["cost"].get(c["currency"], 0) + c["amount"], 10)
        elif c:
            x["unpriced"] += 1
        x["plan_share"] = round(x["plan_share"] + (r.get("plan_share") or 0), 10)
    for x in g.values():
        x["cache_hit_rate"] = _rate(x["tokens"])
    return g

def _rate(t):
    d = t["input"] + t["cache_read"] + t["cache_write"]
    return round(t["cache_read"] / d, 6) if d else None

def cache_hit_rate(records, by="role"):
    """{group: cache_read / (input + cache_read + cache_write)}; None for a group with nothing on the input side."""
    return {k: v["cache_hit_rate"] for k, v in rollup(records, by).items()}

# ---- usage of an answer ----
def usage_of(protocol, body):
    """The five token counts an answer shows, per the shape's response.usage, usage_keys and usage_extra; 0 for what it does not show.
    A count the provider adds to input or output (usage_extra included_in) is taken out of it: the five are disjoint."""
    r, out = protocol["response"], dict.fromkeys(TYPES, 0)
    u = _route().ptr(body, r["usage"])
    if not isinstance(u, dict):
        return out
    n = lambda v: v if type(v) is int and v >= 0 else 0
    k = r.get("usage_keys") or ["input_tokens", "output_tokens"]
    out["input"], out["output"] = n(u.get(k[0])), n(u.get(k[1]))
    for t, spec in (r.get("usage_extra") or {}).items():
        out[t] = n(_route().ptr(u, spec["pointer"]))
        if spec["included_in"]:
            out[spec["included_in"]] = max(0, out[spec["included_in"]] - out[t])
    return out

# ---- OTLP export ----
def flag_on():
    try:
        return sd.served(["features"])["features"].get(FLAG, {}).get("status") == "on"
    except sd.DataError:
        return False   # fail closed: nothing leaves the machine on a feature list nobody can read

def endpoint():
    """The enabled catalog app that is the owner's OTLP backend, or None."""
    try:
        cat = sd.served(["connections"])["connections"].values()
    except sd.DataError:
        return None
    return next((c for c in cat if c["kind"] == "app" and c.get("subkind") == FLAG and c.get("enabled") is not False and c["hosts"]), None)

def _attr(k, v):
    return {"key": k, "value": {"boolValue": v} if isinstance(v, bool) else {"intValue": str(v)} if isinstance(v, int)
            else {"doubleValue": v} if isinstance(v, float) else {"stringValue": str(v)}}

def otlp(spans):
    return {"resourceSpans": [{"resource": {"attributes": [_attr("service.name", NS)]}, "scopeSpans": [{"scope": {"name": NS + "-cost"}, "spans": [
        {"traceId": s["trace_id"], "spanId": s["span_id"], "name": s["name"], "kind": 3, "startTimeUnixNano": str(s["start_time_unix_nano"]),
         "endTimeUnixNano": str(s["end_time_unix_nano"]), "status": {"code": s["status"]}, "attributes": [_attr(k, v) for k, v in s["attributes"].items()]}
        for s in spans]}]}]}

def export(spans):
    """Send spans to the OTLP endpoint; the number sent. 0 and no socket when the flag is off or the catalog has no enabled endpoint."""
    ep = endpoint() if flag_on() and spans else None
    if ep is None:
        return 0
    import credentials, urllib.error
    route, h, hdr = _route(), ep["hosts"][0], {"Content-Type": "application/json"}
    if ep["secrets"]:
        try:
            key = credentials.get(ep["secrets"][0])   # shortcut: the entry's first secret is the bearer token, as route.py's api key
        except credentials.Refused as x:
            raise Stop(x.code, f"connection {sd.idn(ep['id'])}: {x.problem}")
        forms = (key, json.dumps(key)[1:-1])
        route.KEYS.update(forms)
        el.SECRETS.update(forms)
        hdr["Authorization"] = f"Bearer {key}"
    try:
        plain = ep.get("locality") == "local" or ipaddress.ip_address(h["host"]).is_loopback
    except ValueError:
        plain = False   # TLS to every other host
    req = urllib.request.Request(f"{'http' if plain else 'https'}://{h['host']}:{h['port']}/v1/traces", data=el.scrub(json.dumps(otlp(spans))).encode(), headers=hdr, method="POST")
    try:
        status, _ = route.fetch(req, route.timeout_of())
    except Exception as e:   # the type only: the text could repeat a value
        raise Stop(EXPORT, f"connection {sd.idn(ep['id'])} did not take the spans ({type(e).__name__})")
    if status >= 300:
        raise Stop(EXPORT, f"connection {sd.idn(ep['id'])} answered {status} to the spans")
    return len(spans)

# ---- CLI ----
def read_json(path):
    try:
        return json.loads(sys.stdin.read() if path in (None, "-") else open(path, encoding="utf-8").read())
    except (OSError, ValueError) as e:
        raise Stop(BADINPUT, f"the record cannot be read ({type(e).__name__})", alert=False)

def read_lines(path):
    good, skipped = [], 0
    try:
        for line in open(path, encoding="utf-8"):
            try:
                d = json.loads(line)
                if isinstance(d, dict):
                    good.append(d)
                else:
                    skipped += 1
            except ValueError:
                skipped += bool(line.strip())
    except OSError as e:
        raise Stop(BADINPUT, f"{path}: cannot be read ({type(e).__name__})", alert=False)
    return good, skipped

def cmd_price(a):
    rec = read_json(a.record)
    print(json.dumps({"cost": price(rec, load_table()), "plan_share": rec.get("plan_share")}))

def cmd_span(a):
    s = span_of(read_json(a.record))
    if a.write:
        write_span(s)
    print(json.dumps(s))

def cmd_rollup(a):
    key = sd.load(sd.INDEX).get(LEDGER)
    if not (a.records or key):
        raise Stop(BADINPUT, "no --records file and the data index names no usage_ledger", alert=False)
    path = a.records or el.path(key)
    recs, skipped = read_lines(path)
    print(json.dumps({"by": a.by, "groups": rollup(recs, a.by), "skipped": skipped}))

def cmd_check(a):
    t = load_table()
    bad = table_problems(t)
    if bad:
        raise Stop(BADTABLE, bad[0] + (f" (and {len(bad) - 1} more)" if len(bad) > 1 else ""))
    print(json.dumps({"ok": True, "entries": len(t)}))

def cmd_export(a):
    if a.spans:
        spans, _ = read_lines(el.path(sd.load(sd.INDEX)[SPANS]))
    else:
        spans = [span_of(read_json(a.record))]
    out = {"exported": 0, "flag": "on" if flag_on() else "off"}
    if out["flag"] == "on" and endpoint() is None:
        out["reason"] = "no enabled connection of kind app and subkind otlp-export in the catalog"
    out["exported"] = export(spans)
    print(json.dumps(out))

def main(argv):
    ap = argparse.ArgumentParser(prog="cost.py", description="Cost accounting: pricing, spans, rollups, OTLP export.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("price", "span", "rollup", "check", "export"):
        p = sub.add_parser(name)
        p.add_argument("--json", action="store_true")
        if name in ("price", "span", "export"):
            p.add_argument("--record", help="a usage record file, - or nothing for stdin")
        if name == "span":
            p.add_argument("--write", action="store_true")
        if name == "export":
            p.add_argument("--spans", action="store_true", help="export the spans file instead of one record")
        if name == "rollup":
            p.add_argument("--by", required=True)
            p.add_argument("--records", help="a usage ledger file (default: the file of index key usage_ledger)")
    a = ap.parse_args(argv)
    try:
        {"price": cmd_price, "span": cmd_span, "rollup": cmd_rollup, "check": cmd_check, "export": cmd_export}[a.cmd](a)
        return 0
    except Stop as x:
        s = x
    except el.EventError as e:
        s = Stop(e.code, e.problem)
    except sd.DataError as e:
        s = Stop(getattr(e, "code", BADINPUT), str(e)[:180])
    except Exception as e:   # never a traceback, never the error's text (it could repeat a value): the type only
        s = Stop(BADINPUT, f"{type(e).__name__}, an unexpected failure of cost.py {a.cmd}")
    print(json.dumps({"code": s.code, "problem": el.scrub(s.problem)}))
    el.say(s.code, s.problem, alert=s.alert)
    return 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
