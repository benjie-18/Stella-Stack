#!/usr/bin/env python3
"""The capability probe (F2b item B), stdlib only. It tries a link through route.py's wire shape and records what the link does, never
what the catalog says: tool calling, parallel tool calls, JSON, vision, the strongest output shape it proves, the model family and the
effective context. Nothing here names a model, a provider, a shape or an output shape: all are data (routing probe, the wire shapes).
CLI (host only: every command refuses in a worker environment, STL-CFG-312; the output is JSON):
  probe.py run --connection C --model M [--again] [--json]   probe one link; one record keyed (connection, model, version), the version
        being the one the connection's model list shows; one trusted `probe.recorded` event line. A version that has a record is refused
        (STL-MDL-735) unless --again, which replaces that record.
  probe.py due [--json]    {due: [{connection, model, version[, probeable: false]}], unreachable: [{connection, problem}]}: the links of the catalog whose
        current model-list version has no record (the batch lane's input; scheduling it is later work), and with version null and
        probeable false the links with no record of a CLI-login connection: they serve unproven, flagged (STL-MDL-738), and no probe
        run can record them. An api connection whose protocol is missing or unknown is unreachable, the field named.
  probe.py show [--connection C] [--model M] [--json]    the records.
  probe.py check [--json]  the records file against its schema and the routing data (the file is protected state, not a data row).
Records: the file the index key probe_records names (a protected state path: no role writes it, git never holds it), schema
.stella/schemas/probes.schema.json. A reader (records()) takes nothing from a file that is unreadable or invalid, and ignores a record of
another install; routing then fails closed (stella_data.probe_records: no link counts as unprobed), and a run drops the bad records. A capability the probe could not test is null (null meets no requirement). A link that never answers: STL-MDL-736,
nothing recorded. An unknown connection or model: STL-MDL-734. Tests (each a smoke test judged here, never by the model's word):
  json: an object came back. tool_calling / parallel_tool_calls: the wire shape's own request carries a tool; one / two calls in one
  answer. vision: false (shortcut: no wire shape has an image form, upgrade when protocols define one). output_shape: for each id of
  routing probe.output_shapes, strongest first, that the wire shape names a pointer for, the test schema is sent there shape_trials
  times; the first id with no invalid answer is recorded, else none. context: `needles` chains of `hops` hops planted in a filler
  prompt at each length (about four bytes a token); the score of a length is the share of chains answered (the last code, and no other planted code); effective = the longest
  length whose score >= the shortest's * (1 - tolerance); when the shortest scores 0, the shortest length (never 0).
Exit: 0 ok; 1 refused or failed (catalog code and plain message on stderr, {code, problem} on stdout); 2 usage."""
import os, sys

if __name__ == "__main__" and not sys.flags.isolated:   # run directly: PYTHONPATH and the current folder must not decide what is imported
    try:
        os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
    except OSError:   # fail closed: a tool that holds keys does not go on with modules it cannot vouch for
        sys.exit("STL-CFG-310 probe.py could not restart itself isolated (python3 -I); nothing was called")

import argparse, json, random, time, urllib.request, uuid

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import credentials
import event_log as el
import stella_data as sd
import worker_env

UNKNOWN, DONE, FAILED, UNEXPECTED = "STL-MDL-734", "STL-MDL-735", "STL-MDL-736", "STL-CFG-310"
KEY, UNVERSIONED = "probe_records", "unversioned"   # the index key of the records file; the version of a model list that shows none
SCHEMA = {"type": "object", "properties": {"reasoning": {"type": "string"}, "verdict": {"enum": ["a", "b"]}},
          "required": ["reasoning", "verdict"], "additionalProperties": False}   # what the output-shape test asks for
FILLER = "the quick brown fox jumps over the lazy dog and then rests. "   # lower case, no digits: it never looks like a code


class Stop(Exception):
    def __init__(self, code, problem, alert=True):
        super().__init__(problem)
        self.code, self.problem, self.alert = code, problem, alert


# ---- the records file ----
def path():
    return el.path(sd.load(sd.INDEX)[KEY])   # refused when it is, or passes through, a symbolic link


def problems(doc, rt=None):
    """What is wrong with a records document: its schema, an output_shape the routing data does not list, a record key twice.
    rt: the routing document when the caller holds it (a cross-file rule of `check` must not read the routing data again)."""
    errs = sd.validate_doc(doc, sd.schema_of("probes"))
    if errs:
        return errs
    known, seen = set((rt or sd.routing())["probe"]["output_shapes"]), set()
    for i, r in enumerate(doc["records"]):
        k = (r["install_id"], r["connection"], r["model"], r["version"])   # a record of another install is no duplicate: readers ignore it
        if r["output_shape"] not in known:
            errs.append(f"records[{i}]: output_shape {r['output_shape']!r} is not one of routing probe.output_shapes")
        if k in seen:
            errs.append(f"records[{i}]: the version is recorded twice for this connection and model (of one install)")
        seen.add(k)
    return errs


def raw():
    """The records file as parsed (not judged); a missing file is an empty one. Raises when it cannot be read."""
    try:
        with open(path(), "rb") as f:
            return json.loads(f.read(el.MAX_FILE + 1))
    except FileNotFoundError:
        return {"schema_version": 1, "records": []}


def load(rt=None):
    """(the whole document, None) or (None, the problem): a missing file is an empty one."""
    try:
        doc = raw()
    except (OSError, ValueError, RecursionError, sd.DataError, el.EventError) as e:
        return None, f"the records file cannot be read ({type(e).__name__})"
    errs = problems(doc, rt)
    return (None, errs[0]) if errs else (doc, None)


def read(rt=None):
    """(the valid records of this install, None), or ([], the problem) for a file that is present but cannot be used whole. Routing
    reads it through stella_data.probe_records(), which fails closed on the problem (CRT-01): a missing file is no record, a broken
    one never makes a link look unprobed."""
    doc, why = load(rt)
    iid = sd.install_id() if doc else None
    return ([r for r in doc["records"] if r["install_id"] == iid] if doc else []), why


def records(rt=None):
    """The valid records of this install; none when the file is unreadable or invalid (fail closed)."""
    return read(rt)[0]


def shape_of(connection, model):
    """The output shape the newest record of the link proves; None when there is none (the caller then treats it as none)."""
    try:
        got = [r for r in records() if r["connection"] == connection and r["model"] == model]
    except Exception:   # shortcut: any trouble reading is "no record", which is the safe answer (the schema goes in the prompt), upgrade if a reader must tell why
        return None
    return max(got, key=lambda r: r["probed_at"])["output_shape"] if got else None


def save(rec):
    """Add the record (replacing the one of its key) under the file's lock, written whole after it passes its own check. A record
    that breaks the file (one that fails alone, or the earlier of a key twice) is dropped, so one bad record never blocks the
    probe that repairs it (CRT-01); a file that cannot be read at all is refused (the owner fixes it: probe.py check names it)."""
    import route
    p = path()
    with el.locked(p + ".lock"):
        try:
            got, rt = raw(), sd.routing()
        except (OSError, ValueError, RecursionError, sd.DataError, el.EventError) as e:
            raise Stop(FAILED, f"the records file cannot be read ({type(e).__name__})")
        keep = {}
        for r in got.get("records") if isinstance(got, dict) and isinstance(got.get("records"), list) else []:
            if not problems({"schema_version": 1, "records": [r]}, rt):
                keep.pop(k := (r["install_id"], r["connection"], r["model"], r["version"]), None)
                keep[k] = r
        doc = {"schema_version": 1, "records": [r for r in keep.values() if (r["connection"], r["model"], r["version"]) != (rec["connection"], rec["model"], rec["version"])] + [rec]}
        errs = problems(doc)
        if errs:
            raise Stop(FAILED, f"the record would break the records file ({errs[0]})")
        route.write_whole(p, doc)


# ---- the link ----
def listing(route, prov, proto, local, key, timeout):
    """{model id: its model-list item} of the connection, as the wire shape lays the list out; Stop when it cannot be read."""
    ml = proto["models_list"]
    link = {"connection": prov["id"], "model": ""}
    req = urllib.request.Request(route.url_of(prov, link, local, proto["models_path"]), headers=route.headers_of(proto["request"], key), method="GET")
    try:
        status, raw = route.fetch(req, timeout)
        items = route.ptr(json.loads(raw.decode("utf-8", "replace")), ml["items"]) if 200 <= status < 300 else None
    except Exception:   # a refusal, a timeout or an answer that is no JSON: all are "no list" (no text of the error leaves: it could repeat the key)
        items = None
    if not isinstance(items, list):
        raise Stop(FAILED, f"connection {sd.idn(prov['id'])}: its model list cannot be read")
    return {i[ml["field"]][len(ml["prefix"]):]: i for i in items if isinstance(i, dict) and str(i.get(ml["field"], "")).startswith(ml["prefix"])}


def key_of(route, prov):
    if not prov["secrets"]:
        return None
    try:
        key = credentials.get(prov["secrets"][0])   # shortcut: the entry's first secret is its API key (as route.py)
    except credentials.Refused as x:
        raise Stop(x.code, f"connection {sd.idn(prov['id'])}: {x.problem}") from None
    forms = (key, json.dumps(key)[1:-1])
    route.KEYS.update(forms)
    el.SECRETS.update(forms)   # scrubbed from every event detail, alert text and output of this run
    return key


def version_of(proto, item):
    v = item.get(proto["models_list"].get("version") or "")
    return str(v) if v not in (None, "") else UNVERSIONED


def link_of(route, a):
    """(rt, connection entry, model entry, wire shape, local hosts, link) for the named link; Stop(734) when the catalog has none."""
    rt, cat, protos, local = route.data()
    prov = sd.entry(cat, a.connection)
    mod = next((m for m in prov["models"] if m["id"] == a.model), None) if prov and prov["kind"] == "provider" else None
    proto = protos.get(prov.get("protocol")) if prov else None
    if mod is None or proto is None:
        raise Stop(UNKNOWN, f"link {sd.idn(a.connection)}/{sd.idn(a.model)} (the catalog has no such connection and model, or the connection has no wire shape)")
    return rt, prov, mod, proto, local, {"connection": prov["id"], "model": a.model}


# ---- the tests ----
def chain_prompt(tokens, needles, hops, rnd):
    """[(prompt, its chain's last code, every planted code)]: filler of about `tokens` tokens with chains of codes planted at even gaps, and one question per chain asked after it."""
    codes, chains = set(), []
    for _ in range(needles):
        c = []
        while len(c) <= hops:
            x = "".join(rnd.choices("ABCDEFGHJKLMNPQRSTUVWXYZ", k=2)) + str(rnd.randrange(1000, 10000))
            if x not in codes:
                codes.add(x)
                c.append(x)
        chains.append(c)
    facts = [f"The key to code {c[i]} is code {c[i + 1]}. " for c in chains for i in range(hops)]
    rnd.shuffle(facts)
    gap = max((tokens * 4 - sum(map(len, facts))) // (len(facts) + 1), 0)
    body = "".join((FILLER * (gap // len(FILLER) + 1))[:gap] + f for f in facts)
    asks = [f"Start from code {c[0]} and follow the keys, each code to the code it is the key to, until a code has no key. Answer with the last code only." for c in chains]
    return [(f"{body}\n\n{q}", c[-1], codes) for q, c in zip(asks, chains)]


def answered(text, last, codes):
    """The answer holds the chain's last code and no other planted code (CRT-03: an echo of every code is no answer)."""
    return last in text and not any(c in text for c in codes - {last})


def context(route, ask, p, rnd):
    pts = []
    for n in sorted(p["lengths"]):
        got = sum(1 for prompt, last, codes in chain_prompt(n, p["needles"], p["hops"], rnd) if answered(str((ask(prompt)[0] or {}).get("text") or ""), last, codes))
        pts.append({"tokens": n, "score": round(got / p["needles"], 4)})
    short = pts[0]["score"]
    # W23P-02: a link that fails the multi-hop test even at the shortest length answered prompts of that length, so that length is
    # what it is known to hold (never 0, which would refuse every call); a score that never left 0 cannot drop from there either
    return {"short_score": short, "points": pts,
            "effective": pts[0]["tokens"] if short == 0 else max(x["tokens"] for x in pts if x["score"] >= short * (1 - p["tolerance"]))}


def probe(route, rt, prov, mod, proto, local, link, key, item, timeout):
    p, seen = rt["probe"], []

    def ask(prompt, edit=None):
        ans, trigger, _ = route.send(prov, proto, link, prompt, key, timeout, local, edit)
        seen.append(ans is not None)
        return ans, trigger

    def calls(prompt):
        ans, trigger = ask(prompt)
        if trigger == route.MALFORMED:
            return 0   # a call whose arguments do not parse is a tested failure
        tc = None if ans is None else ans["tool_calls"]
        return None if ans is None else len(tc) if isinstance(tc, list) else 1 if tc else 0   # a pointer that holds one call (a wire shape's dict sample) never shows two

    def valid(ans):
        try:
            return ans is not None and not sd.validate_doc(json.loads(ans["text"]), SCHEMA)
        except (TypeError, ValueError, RecursionError):
            return False

    ans, _ = ask("Reply with a JSON object with the key ok set to true, and nothing else.")
    try:
        js = None if ans is None else isinstance(json.loads(ans["text"]), dict)
    except (TypeError, ValueError, RecursionError):
        js = False
    one, two = calls("Call the tool once."), calls("Call the tool twice, both calls in this one answer.")
    ptrs, shape = proto["request"].get("output_shape") or {}, "none"
    for sid in p["output_shapes"]:
        if sid in ptrs:
            edit = lambda b, w=ptrs[sid]: route.put(b, w, SCHEMA)
            if all(valid(ask("Reply with a JSON object: a short reasoning, then the verdict a or b.", edit)[0]) for _ in range(p["shape_trials"])):
                shape = sid
                break
    ctx = context(route, ask, p, random.Random())
    if not any(seen):
        raise Stop(FAILED, f"link {sd.idn(link['connection'])}/{sd.idn(link['model'])} gave no answer to any call")
    fam = item.get(proto["models_list"].get("family") or "")
    cap = (mod.get("capabilities") or {}).get("context_tokens")
    return {"global_id": str(uuid.uuid4()), "install_id": sd.install_id(), "connection": link["connection"], "model": link["model"],
            "version": version_of(proto, item), "probed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "family": fam if isinstance(fam, str) and fam else None,
            "tool_calling": None if one is None else one >= 1, "parallel_tool_calls": None if two is None else two >= 2, "json": js,
            "vision": False, "output_shape": shape,
            "context": {"advertised": cap if type(cap) is int else None, **ctx}, "code": None}


# ---- the commands ----
def cmd_run(a):
    import route
    rt, prov, mod, proto, local, link = link_of(route, a)
    timeout, key = route.timeout_of(), key_of(route, prov)
    item = listing(route, prov, proto, local, key, timeout).get(a.model)
    if item is None:
        raise Stop(UNKNOWN, f"link {sd.idn(a.connection)}/{sd.idn(a.model)} (the connection's model list does not show the model)")
    ver = version_of(proto, item)
    if not a.again and any((r["connection"], r["model"], r["version"]) == (prov["id"], a.model, ver) for r in records()):
        raise Stop(DONE, f"link {sd.idn(prov['id'])}/{sd.idn(a.model)} version {sd.idn(ver)} has a record already (--again probes it again)", alert=False)
    el.preflight()   # no record without its trusted line
    rec = probe(route, rt, prov, mod, proto, local, link, key, item, timeout)
    save(rec)
    el.append(el.build("probe.recorded", f"probe of {rec['connection']}/{rec['model']} version {rec['version']}",
                       new={k: rec[k] for k in ("connection", "model", "version", "output_shape", "tool_calling", "json")} | {"effective": rec["context"]["effective"]}))
    print(json.dumps(rec))
    return 0


def cmd_due(a):
    import route
    rt, cat, protos, local = route.data()
    recs = records()
    have, due, bad = {(r["connection"], r["model"], r["version"]) for r in recs}, [], []
    seen = {(r["connection"], r["model"]) for r in recs}
    timeout = route.timeout_of()
    for prov in cat.values():
        if prov["kind"] != "provider" or prov.get("enabled") is False:
            continue
        if prov["type"] == "cli-login":   # no wire shape: it cannot be probed; its links with no record serve unproven (owner ruling 2026-11-18)
            due += [{"connection": prov["id"], "model": m["id"], "version": None, "probeable": False} for m in prov["models"] if (prov["id"], m["id"]) not in seen]
            continue
        proto = protos.get(prov.get("protocol"))
        if proto is None:   # an api connection a probe could reach once its catalog entry names its wire shape (B-VER-02)
            bad.append({"connection": prov["id"], "problem": f"connection {sd.idn(prov['id'])}: its protocol (wire shape) is " +
                        ("not set in the catalog" if not prov.get("protocol") else f"{sd.idn(prov['protocol'])}, not an entry of the wire shapes")})
            continue
        try:
            items = listing(route, prov, proto, local, key_of(route, prov), timeout)
        except Stop as x:
            bad.append({"connection": prov["id"], "problem": el.scrub(x.problem)})
            continue
        due += [{"connection": prov["id"], "model": m["id"], "version": version_of(proto, items[m["id"]])} for m in prov["models"]
                if m["id"] in items and (prov["id"], m["id"], version_of(proto, items[m["id"]])) not in have]
    print(json.dumps({"due": due, "unreachable": bad}))
    return 0


def cmd_show(a):
    out = [r for r in records() if a.connection in (None, r["connection"]) and a.model in (None, r["model"])]
    print(json.dumps({"records": out, "problem": load()[1]}))
    return 0


def cmd_check(a):
    doc, why = load()
    print(json.dumps({"ok": why is None, "records": len(doc["records"]) if doc else 0, "problem": why}))
    if why:
        raise Stop(UNEXPECTED, f"{why}", alert=False)
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="probe.py", description="Capability probe of model links (host only).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, flags in (("run", ("connection", "model")), ("due", ()), ("show", ("connection", "model")), ("check", ())):
        p = sub.add_parser(name)
        for f in flags:
            p.add_argument("--" + f, required=name == "run")
        p.add_argument("--json", action="store_true")
    sub.choices["run"].add_argument("--again", action="store_true")
    a = ap.parse_args(argv)
    import route
    try:
        w = worker_env.reason()
        if w:
            raise Stop(sd.Refused.code, f"probe.py {a.cmd} runs on the host only ({w}); nothing was called")
        return {"run": cmd_run, "due": cmd_due, "show": cmd_show, "check": cmd_check}[a.cmd](a)
    except Stop as x:
        s = x
    except route.Stop as x:   # route.py's own refusals (no plain host, a rejected setting)
        s = Stop(x.code, x.problem, x.alert)
    except el.EventError as e:   # no record without its trusted line
        s = Stop(e.code, e.problem)
    except sd.DataError as e:
        s = Stop(getattr(e, "code", UNEXPECTED), str(e)[:180])
    except Exception as e:   # never a traceback, never the error's text (it could repeat a value): the type only
        s = Stop(UNEXPECTED, f"{type(e).__name__}, an unexpected failure of probe.py {a.cmd}")
    print(json.dumps({"code": s.code, "problem": el.scrub(s.problem)}))
    el.say(s.code, s.problem, alert=s.alert)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
