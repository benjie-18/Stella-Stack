#!/usr/bin/env python3
"""Routing consent (F2 B6, B7; design D4 with design-check DC-02, DC-10, DC-11 and the wave-3 rulings), stdlib only: the accept
popup, the grants it leads to, and unattended run mode. No preset, link class, project, approval class or alert code of the
routing data is named in this file: all are data (routing data `consent`, the resolver's answer, the index).
Library (bin/route.py calls it when the next link a task would use needs a grant; host only):
  gate(ctx, link) -> {status: granted | waiting | queued, code, request_id}
      The resolver alone says what is in force: gate asks it again and answers `granted` only when it no longer asks for a grant.
      Else, for the grant it names (kind crossing: preset and link class, in the grants data; kind privacy: data class and
      connection, in the data policy; always scoped to the task's project, a Stella-wide grant is the owner's own apply):
      - a request of this grant is approved: the candidate is applied through bin/stella-apply.py with this host's owner key,
        bound to the bytes it was built on. Where the change is identity-critical (the shipped data) the apply tool needs the
        typed phrase, which is never asked in the middle of a call: the task stays `waiting`, and the owner is told (one inbox
        alert per request, STL-MDL-719, and a line on stderr) the one host command that finishes it, `consent.py complete <id>`;
      - a request of this grant is pending: it is reused, never made twice;
      - none (or the last one was denied, expired, or made for another state of the grant file): one approval request (class
        and ttl of the routing data), delivered on every channel that may answer, and one trusted event line `routing.consent`.
        The candidate must pass the apply tool's dry run first (no request for a grant that could not be applied).
      Then: unattended run mode off: `waiting` (STL-MDL-719); on: the task is noted in the state's queue, the inbox gets one
      alert with the routing data's consent.alert_code_queue (shipped: STL-MDL-720) when it is newly queued, and the answer
      is `queued`.
CLI (host only: every command refuses in a worker environment, STL-CFG-312, before it reads or writes anything):
  consent.py pending --json             the consent requests not yet settled: pending, approved and waiting for `complete`,
                                        or changed (made for another state of the grant file: it grants nothing any more)
  consent.py complete <request id>      the approved request's grant, applied on this terminal (the apply tool shows the change
                                        and asks the typed phrase when the change needs it; no terminal: STL-OWN-808)
  consent.py revoke <grant id> --out F  writes the candidate file F (0600, never over a file) in which that grant carries
                                        revoked_at; the owner applies it (the command is printed). Nothing is applied here.
The proof (DC-02). A request counts only by the approval service's word (approvals.current: the trusted log) and only while
its digest is the digest of {op: apply, target: the index row of the grant file, old_digest: sha256 of that file now,
new_digest: sha256 of the candidate rebuilt on it}; a file that changed since asks again, so no answer is replayed onto
another state of the grants (a revoke included). The candidate hashed for the request is the file with the grant row
appended; the row cannot hold its request's id then (the id exists only once the request is stored), so the candidate applied
is that same document with `request_id` set on the row. `granted_at` is the time of the request.
State (route.py's state file, under its lock; proof of nothing): `consents` {grant key: {request_id, kind, row, task, card,
told}} (which request stands for which grant, and the row to rebuild its candidate from: both are judged against the trusted
log and the digests on every use) and `queue` {task: {request_id, link, card, at}}.
shortcut: a queued task is taken off the queue when its grant is applied, not when its request is denied or expires; upgrade
when the board reports task ends to route.py (its own shortcut).
Exit: 0 ok; 1 refused or failed (the catalog code and its plain message); 2 usage."""
import argparse, contextlib, hashlib, json, os, re, secrets, subprocess, sys, tempfile, time, uuid
sys.dont_write_bytecode = True   # an owner command leaves nothing in the code folder
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import approvals
import event_log as el
import owner_auth as oa
import owner_config as oc
import resolve
import route   # its state file and lock, its inbox alert; route.py imports this module too, and each calls the other only inside functions
import settings
import stella_data as sd

WAITING, PHRASE = "STL-MDL-719", "STL-OWN-808"   # a task waits for the owner; the apply tool's refusal where the typed phrase cannot be asked
UNATTENDED = "UNATTENDED_MODE"   # the settings registry key
CONSENTS, QUEUE = "consents", "queue"   # this module's keys of the state document
# grant kind (the resolver's word) -> the schema of the data file that holds it, its list there, the fields that name it
KINDS = {"crossing": ("grants", "crossing_grants", ("preset", "to_class")),
         "privacy": ("data-policy", "privacy_grants", ("data_class", "connection"))}
CODE = re.compile(r"STL-[A-Z]+-[0-9]{3}")
# what `pending` lists, and what comes next for each (changed: the grant file is no longer the one the request was made for)
NEXT = {"pending": "the owner's answer", "approved": "consent.py complete {rid}", "changed": "it grants nothing; the task's next call asks again"}


class Refused(sd.DataError):
    """A refusal with its catalog code, in the form route.py's main reports (a DataError that carries a code)."""
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


# ---- the state (not proof) ----
@contextlib.contextmanager
def state():
    try:
        with route.state() as st:   # the block only reads and changes the document
            yield st
    except route.Stop as s:   # the module's class: route.py run as a program holds another one and would not catch it
        raise Refused(s.code, s.problem) from None


def box(st, k):
    """A dict of the state document, made when it is missing or of another shape."""
    if not isinstance(st.get(k), dict):
        st[k] = {}
    return st[k]


def saved(k):
    """A copy of one of this module's keys of the state; a read writes nothing."""
    with state() as st:
        return dict(st[k]) if isinstance(st.get(k), dict) else {}


def settled(gk, rid):
    """A grant was applied: its entry, and every task queued for its request, leave the state."""
    with state() as st:
        box(st, CONSENTS).pop(gk, None)
        q = box(st, QUEUE)
        for t in [t for t, v in q.items() if isinstance(v, dict) and v.get("request_id") == rid]:
            del q[t]


# ---- the grant file, the candidate, the apply ----
def grant_file(kind):
    """(index row id, list key, the file's bytes, its document) of the one data file that holds grants of this kind."""
    schema, lkey, _ = KINDS[kind]
    row = next((r for r in sd.rows() if r["format"] == "json" and r["schema"] == schema and not sd.is_folder(r)), None)
    if row is None:
        raise Refused("STL-CFG-311", f"a data file of schema {schema} (the index has none)")
    try:
        with os.fdopen(el.open_file(el.path(row["path"]), os.O_RDONLY), "rb") as f:   # never through a link, never a FIFO
            cur = f.read(el.MAX_FILE + 1)
        doc = json.loads(cur)
        if len(cur) > el.MAX_FILE or not isinstance(doc, dict) or not isinstance(doc.get(lkey, []), list):
            raise ValueError("is too large, or holds no list of grants")
    except (OSError, ValueError) as e:
        raise Refused("STL-CFG-310", f"{row['id']}: {el.why(e)[:120]}") from None
    return row["id"], lkey, cur, doc


def dump(doc):
    return (json.dumps(doc, indent=2, ensure_ascii=False) + "\n").encode()


def with_row(doc, lkey, row):
    return dump({**doc, lkey: [*doc.get(lkey, []), row]})


def action(target, cur, cand):
    """The apply tool's own action for this change (stella-apply.py action_of): the row, sha256 of the bytes before and after."""
    return {"op": "apply", "target": target, "old_digest": hashlib.sha256(cur).hexdigest(), "new_digest": hashlib.sha256(cand).hexdigest()}


def apply(target, cur, cand, tty=False, dry=False):
    """(exit code, output) of bin/stella-apply.py for the candidate. Not a dry run: with a proof of this host's owner key for
    exactly {target, cur -> cand}, so a file that changed after it was read here is refused (STL-OWN-805), never written over.
    tty: on the caller's terminal, where the owner types the phrase (the output goes there). Else in a session of its own
    with no terminal: a change that needs the typed phrase is refused there (PHRASE), never asked in the middle of a call."""
    with tempfile.TemporaryDirectory(prefix="consent-") as d:   # 0700: the candidate is a whole owner file
        argv = [sys.executable, "-I", os.path.join(BIN, "stella-apply.py"), "apply", target, "--from", os.path.join(d, "candidate")]
        with open(argv[-1], "wb") as f:
            f.write(cand)
        if dry:
            argv.append("--dry-run")
        else:
            argv += ["--proof", os.path.join(d, "proof")]
            with open(argv[-1], "w", encoding="utf-8") as f:
                json.dump(oa.prove(approvals.HOST_CLASS, action(target, cur, cand)), f)
        if tty:
            return subprocess.run(argv).returncode, ""
        r = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, start_new_session=True)
        return r.returncode, r.stdout + r.stderr


def standing(e):
    """What a consents entry of the state is worth: (word, request id, target, the grant file's bytes, the candidate to apply).
    The word is the approval service's (the trusted log; a pending request past its expiry is settled there), and approved or
    pending count only while the request's digest is the digest of the action rebuilt now from the entry's row; else the
    word is "changed". The candidate to apply is the rebuilt one with the request id on its row."""
    rid, row = e.get("request_id"), e.get("row")
    if e.get("kind") not in KINDS or not isinstance(row, dict):
        return None, rid, None, None, None
    target, lkey, cur, doc = grant_file(e["kind"])
    cdoc, _ = approvals.channels()
    try:
        with approvals.lock():
            rec, _, _, word = approvals.current(rid, cdoc)
    except approvals.Refusal:   # a store record that cannot be used decides nothing
        return None, rid, None, None, None
    if word in ("approved", "pending") and oa.digest(action(target, cur, with_row(doc, lkey, row))) != rec["digest"]:
        word = "changed"
    return word, rid, target, cur, with_row(doc, lkey, {**row, "request_id": rid})


# ---- the gate ----
def project_id(project):
    """The project as a grant's scope spells it, by the resolver's rule: its key in the data policy, also when its global_id
    was given; a project the policy does not list, as given."""
    ps = settings.doc(KINDS["privacy"][0])["projects"]
    return project if project in ps else next((k for k, v in ps.items() if v.get("global_id") == project), project)


def unattended():
    """Whether unattended run mode is on: the registry entry as bin/settings.py's reader gives it; when its store holds no
    value, the owner file where the owner config reader finds it (OWNER_CONFIG), typed by the same entry. Anything but a
    stored true is off (the popup waits)."""
    e = settings.entry(UNATTENDED)
    v, src = settings.current(e)
    if src == "default" and (own := oc.get(e["store"]["key"])) is not None:
        v = settings.typed_stored(e, own)
    return v is True


def ask(ctx, key, kind, fields, pid, gk, con):
    """One approval request for a project-scoped grant, and its id: the candidate passes the apply tool's dry run, the request
    is stored with its trusted line and delivered on every channel that may answer, the state notes it (the next call
    reuses it) and one trusted event line says so."""
    target, lkey, cur, doc = grant_file(kind)
    row = {"id": f"{kind}-{secrets.token_hex(6)}", "global_id": str(uuid.uuid4()), "install_id": sd.install_id(), **fields,
           "scope": {"level": "project", "project": pid}, "granted_at": time.strftime(oa.TIME, time.gmtime())}
    cand = with_row(doc, lkey, row)
    rc, out = apply(target, cur, cand, dry=True)
    if rc:
        m = CODE.search(out)
        raise Refused(m[0] if m else "STL-CFG-313", f"the grant candidate for task {ctx['task']} (link {key}) does not pass the apply tool's check; no request was made")
    what = ", ".join(f"{n} {sd.shown(str(v))}" for n, v in fields.items())
    summary = (f"Routing consent, project {pid} only: accept a {kind} grant ({what}) so that task {ctx['task']} of role {ctx['role']} "
               f"may use link {key}. It holds for this project until you revoke it.")
    pol, (cdoc, rows) = oa.policy(), approvals.channels()
    with approvals.lock():
        rec = approvals.request(con["approval_class"], action(target, cur, cand), summary, ctx["card"], con["ttl_s"])
        for cid, ch in rows.items():   # as approvals.py intake delivers a new request: every enabled channel whose kind may answer
            if ch["kind"] != pol["voice_host_confirmation"]["channel_kind"] and pol["channel_kinds"].get(ch["kind"]) is True:
                try:
                    approvals.deliver(rec["id"], cid, cdoc, ch)
                except approvals.Refusal as x:
                    sd.say(x.code, x.problem)
    with state() as st:
        box(st, CONSENTS)[gk] = {"request_id": rec["id"], "kind": kind, "row": row, "task": ctx["task"], "card": ctx["card"], "told": False}
    el.append(el.build("routing.consent", f"task {ctx['task']}", code=WAITING, detail=summary, who={"role": ctx["role"]},
                       new={"request_id": rec["id"], "link": key, "kind": kind, "project": pid, **fields}))
    return rec["id"]


def stuck(ctx, key, gk, rid, out):
    """An approved request whose apply did not go through here. The typed phrase is needed (PHRASE): the owner is told the one
    host command, by one inbox alert per request and a line on stderr. Anything else: the apply tool's own code."""
    if PHRASE not in out:
        m = CODE.search(out)
        return {"status": "waiting", "code": m[0] if m else WAITING, "request_id": rid}
    problem = f"request {rid} is approved and its grant needs your typed phrase: run bin/consent.py complete {rid} on the host terminal (task {ctx['task']}, link {key})"
    with state() as st:
        e = box(st, CONSENTS).get(gk)
        told = not isinstance(e, dict) or e.get("request_id") != rid or e.get("told") is True
        if not told:
            e["told"] = True
    if not told:
        route.alert(WAITING, problem)
    el.say(WAITING, problem)
    return {"status": "waiting", "code": WAITING, "request_id": rid}


def pause(ctx, key, rid, con):
    """The task does not go on. Unattended run mode off: it waits for the popup. On: it is noted in the state's queue and,
    when newly queued for this request, the inbox gets one alert."""
    if not unattended():
        return {"status": "waiting", "code": WAITING, "request_id": rid}
    with state() as st:
        q = box(st, QUEUE)
        new = not (isinstance(q.get(ctx["task"]), dict) and q[ctx["task"]].get("request_id") == rid)
        if new:
            q[ctx["task"]] = {"request_id": rid, "link": key, "card": ctx["card"], "at": time.strftime(oa.TIME, time.gmtime())}
    if new:
        route.alert(con["alert_code_queue"], f"task {ctx['task']} is queued: link {key} waits for request {rid} (bin/consent.py pending --json lists what waits)")
    return {"status": "queued", "code": con["alert_code_queue"], "request_id": rid}


def judged(ctx, link):
    con, key, applied = sd.routing()["consent"], resolve.link_key(link), set()
    while True:
        doc = resolve.resolve(ctx)   # the resolver alone says whether a grant is in force
        e = next((x for x in doc["chain"] if resolve.link_key(x) == key), None)
        if e is None or e["status"] == "excluded":   # the data changed under the call: nothing is used, the next call judges afresh
            return {"status": "waiting", "code": WAITING, "request_id": None}
        if e["status"] != route.NEEDS_GRANT:
            return {"status": route.GRANTED, "code": None, "request_id": None}
        kind = (e.get("grant") or {}).get("kind")
        if kind not in KINDS:
            raise Refused(route.UNKNOWN, f"grant kind {sd.shown(str(kind))} of link {key} (this tool knows no data file for it)")
        src = {**e["grant"], "preset": (doc.get("preset") or {}).get("id"), "connection": e["connection"]}
        fields, pid = {n: src[n] for n in KINDS[kind][2]}, project_id(ctx["project"])
        gk = json.dumps([kind, pid, *fields.values()])
        if gk in applied:   # applied, and the resolver still asks for it: never a loop
            return {"status": "waiting", "code": WAITING, "request_id": None}
        ent = saved(CONSENTS).get(gk)
        word, rid, target, cur, cand = standing(ent) if isinstance(ent, dict) else (None, None, None, None, None)
        if word == "approved":
            rc, out = apply(target, cur, cand)
            if rc:
                return stuck(ctx, key, gk, rid, out)
            settled(gk, rid)
            applied.add(gk)
            continue
        if word != "pending":
            rid = ask(ctx, key, kind, fields, pid, gk, con)
        return pause(ctx, key, rid, con)


def gate(ctx, link):
    try:
        oa.need_host("a routing consent")
        with el.locked(el.path(sd.load(sd.INDEX)["routing_state"]) + ".consent.lock"):   # one gate at a time: two tasks never make two requests for one grant
            return judged(ctx, link)
    except oa.Refusal as r:   # the owner check's and the approval service's refusals
        raise Refused(r.code, r.problem) from None
    except (OSError, ValueError, KeyError, TypeError) as e:   # route.py's main reports a coded line, never a traceback
        raise Refused("STL-CFG-310", f"routing consent: {el.why(e)[:120] if isinstance(e, (OSError, ValueError)) else type(e).__name__ + ', a value of another shape'}") from None


# ---- the commands ----
def cmd_pending(a):
    out = []
    for e in saved(CONSENTS).values():
        word, rid, *_ = standing(e) if isinstance(e, dict) else (None, None)
        if word in NEXT:
            out.append({"request_id": rid, "status": word, "kind": e["kind"], "grant": e["row"], "task": e.get("task"), "card": e.get("card"),
                        "next": NEXT[word].format(rid=rid)})
    print(json.dumps(out, indent=2, ensure_ascii=False))
    return 0


def cmd_complete(a):
    gk, e = next(((k, e) for k, e in saved(CONSENTS).items() if isinstance(e, dict) and e.get("request_id") == a.id), (None, None))
    if e is None:
        sd.refuse("routing consent request", sd.shown(a.id))
    word, rid, target, cur, cand = standing(e)
    if word != "approved":
        raise Refused(*(approvals.refusal_of(rid, word) if word in (None, "denied", "expired") else
                        (WAITING, f"request {rid} is not answered yet; nothing was applied") if word == "pending" else
                        (WAITING, f"request {rid} was made for another state of the grant file, which changed since; nothing was applied, and the task's next call asks again")))
    rc, _ = apply(target, cur, cand, tty=True)
    if rc:
        return 1   # the apply tool said why
    settled(gk, rid)
    print(json.dumps({"request_id": rid, "status": route.GRANTED, "grant": e["row"].get("id"), "target": target}))
    return 0


def cmd_revoke(a):
    now = time.strftime(oa.TIME, time.gmtime())
    mine = lambda g: isinstance(g, dict) and a.id in (g.get("id"), g.get("global_id"))
    for kind in KINDS:
        target, lkey, _, doc = grant_file(kind)
        if any(map(mine, doc.get(lkey, []))):
            break
    else:
        sd.refuse("grant", sd.shown(a.id))
    # an earlier real revocation date stays (the same text form sorts by time)
    gone = lambda g: isinstance(g.get("revoked_at"), str) and bool(sd.when(g, "revoked_at")) and g["revoked_at"] <= now
    cand = dump({**doc, lkey: [dict(g, revoked_at=now) if mine(g) and not gone(g) else g for g in doc[lkey]]})
    try:
        fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)   # never over a file, never through a link
    except OSError as x:
        raise Refused("STL-CFG-313", f"the candidate file cannot be made ({el.why(x)}); --out names a file that does not exist yet") from None
    with os.fdopen(fd, "wb") as f:
        f.write(cand)
    print(json.dumps({"grant": a.id, "kind": kind, "target": target, "candidate": a.out, "apply": f"stella-apply.py apply {target} --from {a.out}"}))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="consent.py", description="Routing consent requests and grants (host only).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("pending").add_argument("--json", action="store_true", help="accepted: JSON is the only output")
    sub.add_parser("complete").add_argument("id")
    p = sub.add_parser("revoke")
    p.add_argument("id")
    p.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    try:
        oa.need_host("a routing consent command")
        return {"pending": cmd_pending, "complete": cmd_complete, "revoke": cmd_revoke}[a.cmd](a)
    except (oa.Refusal, el.EventError, settings.Refuse) as r:
        return el.fail(r.code, r.problem)
    except sd.DataError as e:
        return el.fail(getattr(e, "code", "STL-CFG-310"), str(e)[:180])


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as e:   # never a traceback, never a value: the type only
        sd.say("STL-CFG-310", f"consent: {type(e).__name__}, an unexpected failure")
        sys.exit(1)
