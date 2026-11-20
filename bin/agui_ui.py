#!/usr/bin/env python3
"""Generative UI passthrough (X1 item U; body B3, AC3; design section U with ruling X1-DC-07), stdlib only, engine side.
A widget (an AG-UI UI event's value {component, props, actions: [{id}]}) is untrusted content. It renders only from the allowlist
(index row ui-components: components [{id, summary, props: a flat JSON Schema, actions: [{id, approval_class, summary}]}] and
limits), is redacted before it is stored, can never approve, and its actions reach nothing but `act`, which OPENS one approval
request through bin/approvals.py (never answers, approves or runs anything).
Library: ingest(run, payload, ctx) -> the stored record | None   ctx {role, card, project, adapter}; the run id and the payload's size
           are checked before any path is built; a component not listed (721), props failing its schema (722), an action it does not
           list (723), a malformed or oversized widget or a full stream (724), a store failure (725) drop the widget: one alert line,
           None. Keys outside {component, props, actions} and props outside the component's schema are stripped, never stored.
           Kept: one line {seq, at, run, component, props, actions, global_id, install_id} in <index ui_streams>/<run>.jsonl, the props
           redacted (event_log's redact keys, run tokens, the connections catalog's value patterns), and one trusted event line.
         read(run, after=0) -> [records with seq > after], redacted again on the way out (the read-scope reader the loopback API's
           run-ui endpoint serves).
         act(run, seq, action) -> {id, run, seq, action, approval_class}: one approval request of the action's approval_class, the
           card from the run record (index adapter_runs), the summary from the action's data template ({prop}: the redacted prop,
           capped at limits.summary_value_chars), the action {op: ui-action, target: <run>/<seq>/<action>, new_digest: sha256 of the
           stored record}.
CLI (host only: refuses in a worker environment, STL-CFG-312, before reading anything):
  agui_ui.py read --run R [--after SEQ] [--json]           JSON {run, records}
  agui_ui.py act --run R --seq N --action A [--json]        JSON {ok, id, run, seq, action, approval_class}
Exit: 0 ok; 1 refused (the catalog code and its plain message on stderr, one alert line: STL-GRD-720..726, approvals' STL-OWN-829,
STL-CFG-312); 2 usage."""
import argparse, hashlib, json, os, re, sys, time, uuid
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import redact_all as redact
import stella_data as sd
import worker_env

ROW, KEY, RUNS = "ui-components", "ui_streams", "adapter_runs"   # the allowlist's index row; the index keys of the stream and run records
RUN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}")   # the adapter's run id rule (adapter.ID)
PLACE = re.compile(r"\{([A-Za-z][A-Za-z0-9_]{0,63})\}")   # a summary template's {prop}
OP = "ui-action"   # the approval action's op: a widget action, judged by the owner from the summary and the stored record's digest


class Refusal(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def data():
    """The allowlist, schema-checked, plus what the schema cannot say (each props schema lints, every string prop has a maxLength,
    every approval_class is one of the approval-request schema's); else Refusal 720 (fail closed: nothing renders)."""
    try:
        row = next(r for r in sd.rows() if r["id"] == ROW)
        doc = sd.checked(sd.load(row["path"]), row["path"], row["schema"])
        classes = sd.schema_of("approval-request")["properties"]["approval_class"]["enum"]
    except (sd.DataError, StopIteration, KeyError, TypeError) as e:
        raise Refusal("STL-GRD-720", str(e)[:200] or f"the index has no {ROW} row") from None
    for c in doc["components"]:
        ps = c["props"]
        bad = (sd.lint_schema(ps) + [f"string prop {k} has no maxLength" for k, s in ps["properties"].items() if s["type"] == "string" and "maxLength" not in s]
               + [f"action {a['id']} names no approval class" for a in c["actions"] if a["approval_class"] not in classes])
        if bad:
            raise Refusal("STL-GRD-720", f"component {c['id']}: {bad[0][:160]}")
    return doc


def redactor():
    """x -> x redacted by the one shared redactor (bin/redact_all.py: values and keys, run tokens and the catalog's value patterns, event_log's
    redact keys); patterns that cannot be read, or a string longer than sd.MASK_LIMIT: the whole string ***."""
    return redact.redactor(limit=sd.MASK_LIMIT)


def stream(run):
    """The read stream file of a run, the run id checked first."""
    if not (isinstance(run, str) and RUN.fullmatch(run)):
        raise Refusal("STL-GRD-724", "the run id is not well formed")
    try:
        return os.path.join(el.path(sd.load(sd.INDEX)[KEY]), run + ".jsonl")
    except (KeyError, TypeError, ValueError, sd.DataError):
        raise Refusal("STL-GRD-725", f"the index has no usable {KEY}") from None


def lines(p):
    """The records of a stream file ([] when there is none); Refusal 725 when it cannot be read."""
    try:
        with os.fdopen(el.open_file(p, os.O_RDONLY), "rb") as f:
            raw = f.read(el.MAX_FILE + 1)
        if len(raw) > el.MAX_FILE:
            raise ValueError("too large")
        return [json.loads(s) for s in raw.splitlines() if s.strip()]
    except FileNotFoundError:
        return []
    except (OSError, ValueError) as e:
        raise Refusal("STL-GRD-725", f"the read stream of run {p.rsplit('/', 1)[-1]} cannot be read ({type(e).__name__})") from None


def ingest(run, payload, ctx):
    """The stored record, or None after one alert line (the widget dropped). Never raises."""
    try:
        return store(run, payload, ctx if isinstance(ctx, dict) else {})
    except Refusal as r:
        el.say(r.code, r.problem, alert=True)
    except el.EventError as e:
        el.say(e.code, e.problem, alert=True, extra=e.extra)
    except Exception as e:   # fail closed: a widget that cannot be judged is dropped
        el.say("STL-GRD-725", f"the widget could not be stored ({type(e).__name__})", alert=True)
    return None


def store(run, payload, ctx):
    el.owner_only()   # the read stream and the trusted log are the engine's
    p = stream(run)
    doc = data()
    lim = doc["limits"]
    if not isinstance(payload, dict):
        raise Refusal("STL-GRD-724", "the widget is not a JSON object")
    try:
        size = len(json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8", "surrogatepass"))
    except (TypeError, ValueError, RecursionError):
        raise Refusal("STL-GRD-724", "the widget is not JSON") from None
    if size > lim["payload_bytes"]:
        raise Refusal("STL-GRD-724", f"the widget is {size} bytes, more than limits.payload_bytes {lim['payload_bytes']}")
    cid = payload.get("component")
    comp = next((c for c in doc["components"] if c["id"] == cid), None)
    if comp is None:
        raise Refusal("STL-GRD-721", f"component {redact.name(cid)} is not in the allowlist")
    props = payload.get("props", {})
    if not isinstance(props, dict):
        raise Refusal("STL-GRD-722", f"the props of component {cid} are {sd.desc(props)}, not an object")
    props = {k: v for k, v in props.items() if k in comp["props"]["properties"]}   # keys outside the schema are stripped
    errs = sd.validate_doc(props, comp["props"], [])
    if errs:
        raise Refusal("STL-GRD-722", f"the props of component {cid} fail its schema: {errs[0][:160]}")
    acts = payload.get("actions", [])
    if not (isinstance(acts, list) and all(isinstance(a, dict) for a in acts)):
        raise Refusal("STL-GRD-724", "the widget's actions are not a list of {id}")
    known = [a["id"] for a in comp["actions"]]
    ids = [a.get("id") for a in acts]
    bad = [i for i in ids if not (isinstance(i, str) and i in known)]
    if bad:
        raise Refusal("STL-GRD-723", f"component {cid} lists no action {redact.name(bad[0])}")
    red = redactor()
    with el.locked(p[:-len(".jsonl")] + ".lock"):
        n = len(lines(p))
        if n >= lim["records_per_run"]:
            raise Refusal("STL-GRD-724", f"the read stream of run {run} holds limits.records_per_run {n} widgets")
        rec = {"seq": n + 1, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "run": run, "component": cid, "props": red(props),
               "actions": [{"id": i} for i in dict.fromkeys(ids)], "global_id": str(uuid.uuid4()), "install_id": sd.install_id()}
        line = (json.dumps(rec, ensure_ascii=True, separators=(",", ":")) + "\n").encode()
        fd = el.open_file(p, os.O_WRONLY | os.O_APPEND | os.O_CREAT)
        try:
            at = os.fstat(fd).st_size
            os.write(fd, line)
            os.fsync(fd)
            try:   # no trusted line, no record
                who = ctx.get("role") if isinstance(ctx.get("role"), str) else None
                el.append(el.build("ui-widget", run, new={"seq": rec["seq"], "component": cid, "actions": list(dict.fromkeys(ids)),
                                                          "card": ctx.get("card") if isinstance(ctx.get("card"), str) else None,
                                                          "digest": hashlib.sha256(line).hexdigest()}, who={"role": who}))
            except BaseException:
                os.ftruncate(fd, at)
                raise
        finally:
            os.close(fd)
    return rec


def read(run, after=0):
    p = stream(run)
    if type(after) is not int or after < 0:
        raise Refusal("STL-GRD-726", "--after is not a whole number of 0 or more")
    red = redactor()
    return [{**r, "props": red(r.get("props"))} for r in lines(p) if isinstance(r, dict) and type(r.get("seq")) is int and r["seq"] > after]


def act(run, seq, action):
    """Open one approval request for a stored widget's action; never answers it."""
    import approvals   # host side, only here
    el.owner_only()
    p = stream(run)
    rec = next((r for r in lines(p) if isinstance(r, dict) and r.get("seq") == seq), None) if type(seq) is int else None
    if rec is None:
        raise Refusal("STL-GRD-726", f"run {run} has no widget {seq}")
    doc = data()
    comp = next((c for c in doc["components"] if c["id"] == rec.get("component")), None)
    a = next((x for x in (comp or {}).get("actions", []) if x["id"] == action and {"id": action} in rec.get("actions", [])), None)
    if a is None:
        raise Refusal("STL-GRD-723", f"widget {seq} of run {run} lists no action {redact.name(action)}")
    try:
        with os.fdopen(el.open_file(os.path.join(el.path(sd.load(sd.INDEX)[RUNS]), run + ".json"), os.O_RDONLY), "rb") as f:
            rr = json.loads(f.read(el.MAX_FILE))
        card, role = rr["card"], rr.get("role")
    except (OSError, ValueError, KeyError, TypeError, sd.DataError):
        raise Refusal("STL-GRD-726", f"run {run} has no readable run record with its card") from None
    red, cap, props = redactor(), doc["limits"]["summary_value_chars"], rec.get("props") or {}
    def fill(m):
        v = red(props.get(m.group(1), "")) if isinstance(props, dict) else ""
        return (v if isinstance(v, str) else json.dumps(v))[:cap]
    summary = PLACE.sub(fill, a["summary"])
    what = {"op": OP, "target": f"{run}/{seq}/{action}", "old_digest": "0" * 64,
              "new_digest": hashlib.sha256(json.dumps(rec, sort_keys=True, ensure_ascii=True, separators=(",", ":")).encode()).hexdigest()}
    requester = role if isinstance(role, str) and approvals.ID.fullmatch(role) else None
    try:
        with approvals.lock():
            r = approvals.request(a["approval_class"], what, summary, card, doc["limits"]["approval_ttl_s"], requester)
    except approvals.Refusal as x:
        raise Refusal(x.code, x.problem) from None
    return {"id": r["id"], "run": run, "seq": seq, "action": action, "approval_class": a["approval_class"]}


def main(argv):
    ap = argparse.ArgumentParser(prog="agui_ui.py", description=__doc__.split("CLI ", 1)[1].split("Exit:")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("read")
    r.add_argument("--run", required=True)
    r.add_argument("--after", type=int, default=0)
    r.add_argument("--json", action="store_true")
    a = sub.add_parser("act")
    a.add_argument("--run", required=True)
    a.add_argument("--seq", type=int, required=True)
    a.add_argument("--action", required=True)
    a.add_argument("--json", action="store_true")
    o = ap.parse_args(argv)
    try:
        w = worker_env.reason()
        if w:
            return el.fail("STL-CFG-312", f"agui_ui.py {o.cmd} runs on the host only ({w}); nothing was read")
        out = {"run": o.run, "records": read(o.run, o.after)} if o.cmd == "read" else {"ok": True, **act(o.run, o.seq, o.action)}
        print(json.dumps(out, indent=2, ensure_ascii=True))
        return 0
    except Refusal as x:
        return el.fail(x.code, x.problem)
    except el.EventError as e:
        return el.fail(e.code, e.problem, e.extra)
    except Exception as e:   # never a traceback: the type only
        return el.fail("STL-GRD-725", f"agui_ui.py {o.cmd} failed ({type(e).__name__})")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
