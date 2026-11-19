#!/usr/bin/env python3
"""The weekly model check (F2c item F), stdlib only. Code computes model picks from probed catalog data and benchmark results only: the
connections catalog, each enabled connection's model list read through its own wire shape (probe.py's fetch), the probe records
(bin/probe.py's reader), the benchmark results (bin/compare.py's reader: protected state, each record backed by a trusted event line)
and the pricing rows applied before the run (bin/cost.py). Never news, web pages, model output or card text; a model list item is data:
only the fields the wire shape's pointers name are read, an id the catalog does not list is never a candidate, and no field is ever
read as an instruction. Nothing here names a model, a provider, a connection, a role or a preset: every rule value is
.stella/model-check.json (weekly), the settings registry and the protocol data.
Pick rule per link of weekly.pick_fields of each preset role in scope (a built-in preset while the owner setting weekly.setting is on; a
custom preset while its model_check grant is in force, read at apply time): a candidate is a model the catalog lists, on the same
connection or on another enabled one of the same link class and reach, with the same data policy, every host approved
(approved-hosts) and its class in the preset's class order for the role; that the link judge accepts for the role; that the model list
shows; with a probe record for the version the list shows, not older than stale_catalog_days, that meets the role's requirements. With
benchmark data for the role: compare.decide against the current pick must give a decision of weekly.accept (non_inferior only for a
cheaper link); worse or inconclusive refuses. With none: only a newer version of the same family on the same connection with probe
capabilities at least the current pick's. A link whose model list cannot be read is skipped; a role whose every listable link is skipped
fails the run loudly: one alert (STL-MDL-762), the state flag paused (until `resume`), exit 1, nothing changed.
Apply: each pick is one apply through bin/stella-apply.py (in process, its engine exception: stella_data.frozen proves the pick again
under the apply lock), with one appended changelog entry, the owner proof of this host, backup, check and one trusted event line (who:
the engine; the detail names the pick id); one alert (STL-MDL-760) names preset, role, old, new, reason and the rollback command. Then
the pricing refresh: new dated rows for the catalog's models from the price fields the wire shape's models_list.prices pointers name,
one apply of the pricing row.
CLI (host only: every command refuses in a worker environment, STL-CFG-312; the output is JSON):
  model_check.py run [--dry-run] [--json]   check, apply the picks (--dry-run: report only, nothing written)
  model_check.py status [--json]            the state and the picks of the trusted event lines
  model_check.py rollback <pick id> [--json]  reverse one pick: a forward apply that puts back the old link of the pick's trusted event line
        (refused, STL-MDL-765, when no trusted line names it or the live link is no longer what the pick set); allowed with the setting off
  model_check.py resume [--json]            clear the paused flag (one trusted event line)
  model_check.py check [--json]             the check's data and its state file are usable
Exit: 0 ok; 1 refused or failed (catalog code and plain message on stderr, {code, problem} on stdout); 2 usage."""
import os, sys

if __name__ == "__main__" and not sys.flags.isolated:   # run directly: PYTHONPATH and the current folder must not decide what is imported
    try:
        os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
    except OSError:
        sys.exit("STL-CFG-310 model_check.py could not restart itself isolated (python3 -I); nothing was changed")

import argparse, contextlib, datetime, hashlib, importlib.util, io, json, re, secrets, signal, tempfile, uuid

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import compare
import cost
import event_log as el
import probe
import stella_data as sd
import worker_env

APPLIED, NOT_APPLIED, PAUSE, PAUSED, ROLLBACK, UNEXPECTED = "STL-MDL-760", "STL-MDL-761", "STL-MDL-762", "STL-MDL-763", "STL-MDL-765", "STL-CFG-310"
KEY, STATE_SCHEMA = "model_check_state", "model-check-state"   # the index key of the state file; its schema
PAUSE_LINE, RESUME_LINE = "model_check.paused", "model_check.resume"   # the event types of the state changes


class Stop(Exception):
    def __init__(self, code, problem, alert=True):
        super().__init__(problem)
        self.code, self.problem, self.alert = code, problem, alert


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)


def stamp(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def params():
    try:
        p = compare.model_params()
    except compare.Stop as e:
        raise Stop(UNEXPECTED, e.problem)
    if not isinstance(p.get("weekly"), dict):
        raise Stop(UNEXPECTED, "model-check.json has no weekly section: the weekly check has no rules to run by")
    return p


def said(w, reason):
    return w["reasons"].get(reason, reason)


# ---- the state file (protected state; never a source of a pick or a rollback) ----
def state_path():
    return el.path(sd.load(sd.INDEX)[KEY])


def read_state():
    """(the state, None), or (None, the problem): a missing file is a fresh state; one that cannot be used counts as paused."""
    try:
        with open(state_path(), "rb") as f:
            doc = json.loads(f.read(el.MAX_FILE + 1))
    except FileNotFoundError:
        return {"schema_version": 1, "paused": None, "last_run": None, "listed": {}}, None
    except (OSError, ValueError, RecursionError, sd.DataError, el.EventError) as e:
        return None, f"the state file cannot be read ({type(e).__name__})"
    errs = sd.validate_doc(doc, sd.schema_of(STATE_SCHEMA))
    return (None, f"the state file is not valid ({errs[0]})") if errs else (doc, None)


def write_state(doc):
    import route
    errs = sd.validate_doc(doc, sd.schema_of(STATE_SCHEMA))
    if errs:
        raise Stop(UNEXPECTED, f"the state would not be valid ({errs[0]})")
    p = state_path()
    with el.locked(p + ".lock"):
        route.write_whole(p, doc)


# ---- the apply contract (in process, so the engine exception knows its caller) ----
def apply(rid, doc, pick, reverses=None):
    """(exit code, output) of one apply of `doc` to data row rid through bin/stella-apply.py with the engine context."""
    spec = importlib.util.spec_from_file_location("stella_apply_engine", os.path.join(BIN, "stella-apply.py"))
    ap = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ap)
    fd, tmp = tempfile.mkstemp(prefix="model-check.", suffix=".json")
    handlers = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM)}
    try:
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
        ap.ENGINE.update(pick=pick, reverses=reverses)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = ap.main(["apply", rid, "--from", tmp])
        return rc, (out.getvalue() + err.getvalue()).strip()
    finally:
        ap.ENGINE.clear()
        for s, h in handlers.items():
            signal.signal(s, h)
        with contextlib.suppress(OSError):
            os.unlink(tmp)


def row_of_schema(schema):
    r = next((r for r in sd.rows() if r["format"] == "json" and r["schema"] == schema), None)
    if r is None:
        raise Stop(UNEXPECTED, f"the index has no row of schema {schema}")
    return r


def doc_of(schema):
    r = row_of_schema(schema)
    return r["id"], sd.checked(sd.load(r["path"]), r["path"], schema)


def new_pick(w):
    return f"{w['pick_id_prefix']}-{secrets.token_hex(6)}"


def alert(code, problem):
    import route
    route.alert(code, problem)


# ---- the data a run reads ----
class World:
    """Everything a run reads, read once: routing, catalog, wire shapes, role table, probe records, benchmarks, prices, approved hosts."""
    def __init__(self, p):
        import route
        self.route, self.p, self.w, self.t = route, p, p["weekly"], now()
        self.rt, self.cat, self.protos, self.local = route.data()
        self.table = sd.load(sd.load(sd.INDEX)["role_table"])
        self.recs = probe.records(self.rt)
        self.bench, self.bench_why = compare.read_benchmarks()
        try:
            self.prices = cost.load_table()   # the rows applied before this run: what "cheaper" is judged by (F-CVER-07)
        except cost.Stop:
            self.prices = []
        try:
            self.hosts = list(sd.one_doc("approved-hosts")["hosts"])
        except sd.DataError:
            self.hosts = []
        self.lists, self.ignored, self.timeout = {}, {}, route.timeout_of()

    def proto(self, prov):
        return None if prov.get("type") == "cli-login" else self.protos.get(prov.get("protocol"))

    def listing(self, prov):
        """{model id: item} of the connection's model list (once per run), or None when it cannot be read; ids the catalog lacks are dropped."""
        if prov["id"] not in self.lists:
            try:
                items = probe.listing(self.route, prov, self.proto(prov), self.local, probe.key_of(self.route, prov), self.timeout)
            except probe.Stop:
                items = None
            if items is not None:
                known = {m["id"] for m in prov["models"]}
                self.ignored[prov["id"]] = sum(1 for k in items if k not in known)
                items = {k: v for k, v in items.items() if k in known}
            self.lists[prov["id"]] = items
        return self.lists[prov["id"]]

    def version(self, prov, item):
        return probe.version_of(self.proto(prov), item)

    def record(self, prov, model, item):
        """The newest probe record of the link for the version its model list shows (None: no record)."""
        v = self.version(prov, item)
        got = [r for r in self.recs if r["connection"] == prov["id"] and r["model"] == model and r["version"] == v and r["probed_at"] <= stamp(self.t)]
        return max(got, key=lambda r: r["probed_at"]) if got else None

    def approved(self, prov):
        ok = lambda h: any(a["host"] == h["host"] and a["port"] == h["port"] and sd.when(a, "approved_at") and sd.when(a, "approved_at") <= self.t
                           and (a.get("expires_at") is None or (sd.when(a, "expires_at") or self.t) > self.t) for a in self.hosts)
        return all(ok(h) for h in prov["hosts"])

    def cheaper(self, a, b):
        """Whether link a costs less than link b on the reference call (both priced in one currency by rows applied before the run)."""
        rec = lambda l: {"connection": l[0], "model": l[1], "ts": stamp(self.t), "tokens": self.w["cheaper_tokens"]}
        try:
            ca, cb = (cost.price(rec(l), self.prices, cli=set(), alert=False) for l in (a, b))
        except cost.Stop:
            return False
        return bool(ca and cb and ca["priced"] and cb["priced"] and ca["currency"] == cb["currency"] and ca["amount"] < cb["amount"])


def vkey(v):
    """A version as a sort key: its digit runs as numbers, the rest as text."""
    return [(0, int(x), "") if x.isdigit() else (1, 0, x) for x in re.findall(r"\d+|[^\d]+", str(v))]


def caps_at_least(a, b):
    import roles
    return all(a.get(k) is True for k in roles.REQ_BOOLS if b.get(k) is True) and \
        ((a.get("context") or {}).get("effective") or 0) >= ((b.get("context") or {}).get("effective") or 0)


def classes_of(mode, role_row):
    flat = lambda o: {k for it in (o or []) for k in (it if isinstance(it, list) else [it])}
    return flat(role_row.get("class_order") or mode.get("class_order"))


def judge_link(W, preset, mode, role, link):
    """{state: checked|skipped|unlisted, reason, pick: (prov, model, reason) or None, refused: [...]} for one link."""
    w, cat = W.w, W.cat
    p0 = sd.entry(cat, link.get("connection"))
    if not p0 or p0.get("kind") != "provider" or W.proto(p0) is None:
        return {"state": "unlisted", "reason": "no_list", "pick": None, "refused": []}
    items0 = W.listing(p0)
    if items0 is None:
        return {"state": "skipped", "reason": "fetch_failed", "pick": None, "refused": []}
    m0, rrow = link.get("model"), mode.get("roles", {}).get(role, {})
    cls0, req = sd.link_class(p0, m0, W.rt), W.table["roles"].get(role, {}).get("requirements", {})
    rec0 = W.record(p0, m0, items0[m0]) if m0 in items0 else None
    bench = [r for r in W.bench if r["role"] == role]
    stale = stamp(W.t - datetime.timedelta(days=W.p["stale_catalog_days"]))
    ok, refused = [], []
    for prov in cat.values():
        if prov.get("kind") != "provider":
            continue
        same_conn = prov["id"] == p0["id"]
        for m in prov["models"]:
            mid = m["id"]
            if same_conn and mid == m0:
                continue
            why, item, rec = None, None, None
            if sd.link_class(prov, mid, W.rt) != cls0 or sd.reach(prov) != sd.reach(p0):
                why = "link_class"
            elif not same_conn and not (prov.get("enabled") and cls0 in classes_of(mode, rrow)):
                why = "connection"
            elif not same_conn and not sd.same(prov["data_policy"], p0["data_policy"]):
                why = "privacy"
            elif not same_conn and not W.approved(prov):
                why = "host"
            elif sd.link_problems(W.table, role, prov, mid):
                why = "link"
            elif W.proto(prov) is None or W.listing(prov) is None:
                why = "fetch_failed"
            elif mid not in W.listing(prov):
                why = "unlisted"
            else:
                item = W.listing(prov)[mid]
                rec = W.record(prov, mid, item)
                why = "no_probe" if rec is None else "stale" if rec["probed_at"] < stale else "probe_unmet" if sd.unmet(req, rec) else None
            if why is None and bench:
                if W.bench_why:
                    why = "inconclusive"
                else:
                    a = [r for r in bench if r["connection"] == prov["id"] and r["model"] == mid]
                    b = [r for r in bench if r["connection"] == p0["id"] and r["model"] == m0]
                    d = compare.decide(a, b, W.p, cheaper=W.cheaper((prov["id"], mid), (p0["id"], m0)))
                    why = None if d in w["accept"] else "worse" if d == "worse" else "inconclusive"
                    if why is None:
                        ok.append((w["accept"].index(d), 0, prov, mid, d))
            elif why is None:
                if same_conn and rec0 and rec.get("family") and rec["family"] == rec0.get("family") and \
                        vkey(rec["version"]) > vkey(rec0["version"]) and caps_at_least(rec, rec0):
                    ok.append((0, [(-a, -b, c) for a, b, c in vkey(rec["version"])], prov, mid, "newer"))
                else:
                    why = "not_newer"
            if why:
                refused.append({"connection": prov["id"], "model": mid, "reason": why})
    ok.sort(key=lambda x: (x[0], x[1]))
    return {"state": "checked", "reason": None if ok else "no_candidate", "pick": ok[0][2:] if ok else None, "refused": refused}


def plan(W, doc):
    """(picks, refused, skipped, failing roles) of the presets in scope, against the document as it is now."""
    w = W.w
    picks, refused, skipped, failing = [], [], [], []
    setting = sd.engine_setting_on(w)
    for pid, mode in doc["effort_modes"].items():
        if not isinstance(mode, dict):
            continue
        if mode.get("builtin") is True and not setting:
            skipped.append({"preset": pid, "reason": "setting_off", "text": said(w, "setting_off")})
            continue
        if mode.get("builtin") is not True and not sd.model_check_granted(pid, W.t):
            skipped.append({"preset": pid, "reason": "no_grant", "text": said(w, "no_grant")})
            continue
        for role, rrow in (mode.get("roles") or {}).items():
            listable = worked = 0
            for f in w["pick_fields"]:
                for i, link in enumerate(rrow.get(f) or []):
                    j = judge_link(W, pid, mode, role, link)
                    at = {"preset": pid, "role": role, "field": f, "index": i}
                    listable += j["state"] != "unlisted"
                    worked += j["state"] == "checked"
                    refused += [{**at, **r, "text": said(w, r["reason"])} for r in j["refused"]]
                    if j["pick"]:
                        prov, mid, why = j["pick"]
                        picks.append({**at, "old": {k: link.get(k) for k in w["pick_keys"]}, "new": {**{k: link.get(k) for k in w["pick_keys"]}, "connection": prov["id"], "model": mid},
                                      "reason": why, "text": said(w, why)})
                    elif j["state"] != "checked" or j["reason"]:
                        skipped.append({**at, "reason": j["reason"], "text": said(w, j["reason"])})
            if listable and not worked:
                failing.append({"preset": pid, "role": role})
    return picks, refused, skipped, failing


def link_at(doc, pk):
    return doc["effort_modes"][pk["preset"]]["roles"][pk["role"]][pk["field"]][pk["index"]]


def changelog_entry(w, pick, pk, old, new, reason, t):
    what = w["changelog"].format(pick=pick, role=pk["role"], field=pk["field"], index=pk["index"],
                                 old="/".join(str(old.get(k)) for k in w["pick_keys"]), new="/".join(str(new.get(k)) for k in w["pick_keys"]), reason=reason)
    return {"at": stamp(t), "by": sd.load(sd.INDEX)["event_writer_id"], "what": what[:1024]}


def apply_pick(W, rid, pk, reverses=None):
    """Apply one pick to the document as it is now; the pick dict gets id, applied and (when refused) code and problem."""
    w = W.w
    _, doc = doc_of("role-assignments")
    try:
        link = link_at(doc, pk)
    except (KeyError, IndexError, TypeError):
        link = None
    if not isinstance(link, dict) or any(link.get(k) != pk["old"].get(k) for k in w["pick_keys"]):
        pk.update(applied=False, code=NOT_APPLIED, problem="the link changed since the check read it")
        return pk
    pk["id"] = new_pick(w)
    link.update(pk["new"])
    mode = doc["effort_modes"][pk["preset"]]
    mode["changelog"] = list(mode.get("changelog") or []) + [changelog_entry(w, pk["id"], pk, pk["old"], pk["new"], pk["reason"], W.t)]
    rc, out = apply(rid, doc, pk["id"], reverses)
    if rc:
        m = re.search(r"STL-[A-Z]+-\d{3}", out)
        pk.update(applied=False, code=m[0] if m else NOT_APPLIED, problem=el.scrub(out)[:300])
        alert(NOT_APPLIED, f"pick {pk['id']} of preset {pk['preset']} role {pk['role']} was not applied ({pk['code']})")
        return pk
    pk["applied"] = True
    show = lambda l: "/".join(str(l.get(k)) for k in w["pick_keys"])
    alert(APPLIED, f"preset {pk['preset']} role {pk['role']} {pk['field']}[{pk['index']}]: {show(pk['old'])} -> {show(pk['new'])} ({pk['text']}); "
                   f"undo: python3 {w['engine_tool']} rollback {pk['id']}")
    return pk


# ---- the pricing refresh ----
def pricing_rows(W):
    """New dated pricing rows from the price fields the model lists show (only under the wire shape's models_list.prices pointers)."""
    w, today, out = W.w, stamp(W.t)[:10], []
    for prov in W.cat.values():
        proto = W.proto(prov) if prov.get("kind") == "provider" and prov.get("enabled") else None
        pp = (proto or {}).get("models_list", {}).get("prices")
        if not pp or not pp["scale"] > 0:
            continue
        items = W.listing(prov)
        for mid, item in (items or {}).items():
            num = lambda ptr: (lambda v: v if isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 else None)(W.route.ptr(item, ptr))
            try:
                per = {k: num(v) for k, v in pp["per_million"].items()}
                bd = num(pp["batch_discount"]) if "batch_discount" in pp else 0
            except Exception:   # a pointer that does not resolve in this item: no row (never a guess)
                continue
            if any(v is None for v in per.values()) or bd is None or bd > 1:
                continue
            per = {k: round(v * pp["scale"], 10) for k, v in per.items()}
            rows = [e for e in W.prices + out if e["connection"] == prov["id"] and e["model"] == mid]
            last = max(rows, key=lambda e: e["effective_from"]) if rows else None
            if last and last["per_million"] == per and last["currency"] == pp["currency"] and last["batch_discount"] == bd or \
                    any(e["effective_from"] == today for e in rows):
                continue
            cid = prov["id"]
            out.append({"id": f"{w['pick_id_prefix']}-{hashlib.sha256(f'{cid}|{mid}|{today}'.encode()).hexdigest()[:16]}",
                        "connection": prov["id"], "model": mid, "effective_from": today,
                        "source": w["pricing_source"].format(connection=prov["id"], date=today)[:1024], "currency": pp["currency"],
                        "per_million": per, "batch_discount": bd, "global_id": str(uuid.uuid4()), "install_id": sd.install_id()})
    return out


# ---- the commands ----
def cmd_run(a):
    p = params()
    st, why = read_state()
    if why or st["paused"]:
        raise Stop(PAUSED, f"the weekly check is paused ({why or st['paused']['reason']}); nothing was checked. The owner clears it with model_check.py resume")
    W = World(p)
    rid, doc = doc_of("role-assignments")
    picks, refused, skipped, failing = plan(W, doc)
    ignored = {k: n for k, n in W.ignored.items() if n}
    for k, n in ignored.items():
        print(f"model_check: connection {sd.idn(k)}: {n} model list entries the catalog does not list were ignored", file=sys.stderr)
    out = {"dry_run": a.dry_run, "picks": picks, "refused": refused, "skipped": skipped, "ignored": ignored, "failing": failing, "paused": None, "pricing": {"rows": 0}}
    if failing and not a.dry_run:
        reason = "no link of " + ", ".join(f"preset {f['preset']} role {f['role']}" for f in failing[:5]) + " could be checked (model list unreadable)"
        st["paused"] = {"at": stamp(W.t), "reason": reason[:1000]}
        write_state(st)
        el.append(el.build(PAUSE_LINE, "model check", new={"reason": reason[:1000]}, code=PAUSE))
        raise Stop(PAUSE, reason)
    if not a.dry_run:
        for pk in picks:
            apply_pick(W, rid, pk)
        rows = pricing_rows(W)
        if rows:
            prid, pdoc = doc_of("pricing")
            rc, msg = apply(prid, {**pdoc, "entries": list(pdoc["entries"]) + rows}, new_pick(W.w))
            out["pricing"] = {"rows": 0 if rc else len(rows), "problem": el.scrub(msg)[:300] if rc else None}
            if rc:
                alert(NOT_APPLIED, f"the pricing refresh was not applied ({el.scrub(msg)[:160]})")
        st["last_run"] = stamp(W.t)
        st["listed"].update({k: stamp(W.t) for k, v in W.lists.items() if v is not None})
        write_state(st)
    print(json.dumps(out))
    return 1 if any(pk.get("applied") is False for pk in picks) else 0


def parse_line(w, line):
    """[(preset, role, field, index)] the trusted pick line changed (from its pointers), with {key: (old, new)}."""
    got = {}
    rx = re.compile(r"/effort_modes/([^/]+)/roles/([^/]+)/([^/]+)/(\d+)/([^/]+)")
    un = lambda s: s.replace("~1", "/").replace("~0", "~")
    for side in ("old", "new"):
        for ptr, v in (line.get(side) or {}).items():
            m = rx.fullmatch(ptr)
            if m and m[3] in w["pick_fields"] and m[5] in w["pick_keys"]:
                got.setdefault((un(m[1]), un(m[2]), m[3], int(m[4])), {}).setdefault(m[5], [None, None])[side == "new"] = v
    return got


def cmd_rollback(a):
    p = params()
    w = p["weekly"]
    try:
        line = sd.pick_line(a.pick)
    except el.EventError as e:
        raise Stop(e.code, e.problem)
    got = parse_line(w, line) if line else {}
    if len(got) != 1:
        raise Stop(ROLLBACK, f"no trusted event line names pick {sd.idn(a.pick)} as a change of one link; nothing was changed")
    (preset, role, f, i), keys = next(iter(got.items()))
    rid, doc = doc_of("role-assignments")
    try:
        link = link_at(doc, {"preset": preset, "role": role, "field": f, "index": i})
    except (KeyError, IndexError, TypeError):
        link = None
    if not isinstance(link, dict) or any(link.get(k) != new for k, (old, new) in keys.items()):
        raise Stop(ROLLBACK, f"pick {sd.idn(a.pick)}: the live link is no longer what the pick set; nothing was changed")
    pk = {"preset": preset, "role": role, "field": f, "index": i, "old": {k: link.get(k) for k in w["pick_keys"]},
          "new": {**{k: link.get(k) for k in w["pick_keys"]}, **{k: old for k, (old, new) in keys.items()}}, "reason": "reversal", "text": said(w, "reversal")}
    W = type("W", (), {"w": w, "t": now()})()
    apply_pick(W, rid, pk, reverses=a.pick)
    print(json.dumps({"rollback": a.pick, "pick": pk}))
    if not pk["applied"]:
        raise Stop(pk["code"], f"pick {sd.idn(a.pick)} was not reversed: {pk.get('problem', '')[:160]}")
    return 0


def cmd_resume(a):
    st, why = read_state()
    if st and not st["paused"]:
        print(json.dumps({"resumed": False, "paused": None}))
        return 0
    was = st["paused"]["reason"] if st else why
    st = {**(st or {"schema_version": 1, "last_run": None, "listed": {}}), "paused": None}
    el.preflight()   # no state change without its trusted line
    write_state(st)
    el.append(el.build(RESUME_LINE, "model check", old={"paused": was[:1000]}, new={"paused": None}))
    print(json.dumps({"resumed": True, "paused": None}))
    return 0


def cmd_status(a):
    st, why = read_state()
    try:
        lines = sd.engine_lines()
    except el.EventError as e:
        raise Stop(e.code, e.problem)
    picks = [{"pick": sd.pick_of(d["detail"])[0], "reverses": sd.pick_of(d["detail"])[1], "time": d.get("time"), "what": d.get("what")} for d in lines]
    print(json.dumps({"state": st, "problem": why, "picks": picks}))
    return 0


def cmd_check(a):
    p = params()
    st, why = read_state()
    e = next((e for e in __import__("settings").registry() if e["key"] == p["weekly"]["setting"]), None)
    probs = [x for x in (why, None if e and e["type"] == "boolean" else f"the settings registry has no boolean entry {p['weekly']['setting']}") if x]
    print(json.dumps({"ok": not probs, "problems": probs}))
    if probs:
        raise Stop(UNEXPECTED, probs[0], alert=False)
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="model_check.py", description="The weekly model check (host only).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("run", "status", "rollback", "resume", "check"):
        s = sub.add_parser(name)
        s.add_argument("--json", action="store_true")
    sub.choices["run"].add_argument("--dry-run", action="store_true")
    sub.choices["rollback"].add_argument("pick")
    a = ap.parse_args(argv)
    import route
    try:
        w = worker_env.reason()
        if w:
            raise Stop(sd.Refused.code, f"model_check.py {a.cmd} runs on the host only ({w}); nothing was changed")
        return {"run": cmd_run, "status": cmd_status, "rollback": cmd_rollback, "resume": cmd_resume, "check": cmd_check}[a.cmd](a)
    except Stop as x:
        s = x
    except route.Stop as x:
        s = Stop(x.code, x.problem, x.alert)
    except el.EventError as e:
        s = Stop(e.code, e.problem)
    except sd.DataError as e:
        s = Stop(getattr(e, "code", UNEXPECTED), str(e)[:180])
    except Exception as e:   # never a traceback, never the error's text (it could repeat a value): the type only
        s = Stop(UNEXPECTED, f"{type(e).__name__}, an unexpected failure of model_check.py {a.cmd}")
    print(json.dumps({"code": s.code, "problem": el.scrub(s.problem)}))
    el.say(s.code, s.problem, alert=s.alert)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
