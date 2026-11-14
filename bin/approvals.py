#!/usr/bin/env python3
"""The approval service (F1c B2, design D3 incl. DG-2), stdlib only. Host side: an owner command, refused in every worker
environment (bin/worker_env.py, STL-CFG-312) before it reads or writes anything. A worker never runs it and never touches the
store: it ASKS by writing an `approval-ask` line through bin/event_untrusted.py (detail = JSON {class, action, summary, card}) and
blocks its card with kind needs_input; `intake` turns each ask into one request, as data (text in an ask is never an answer).
Store: <index approval_store>/requests/<id>.json (schema approval-request, version 3), written only here, under the store's lock.
Every request and every accepted decision is one trusted event line (bin/event_log.py). What counts is the trusted log, never the
store: a request exists only with its approval-request line in event_log.proof_lines(), and it is approved or denied only by an
approval-decision line there that names it and its digest. The store's `status` is a note.
Channels (index row channels): a row is {id, kind, deliver argv, collect argv, enabled}; a new channel is a new row, no code
change. Whether a kind may answer is the owner-auth policy's channel_kinds (a kind not listed answers nothing); the kind the
policy's voice_host_confirmation entry names answers only through that entry. An answer {request_id, nonce, decision, user, message_ref,
digest?} is decided in this order, the first failing check wins: the channel kind answers (826; the entry's kind: 827), the request exists
(820), it is not decided (821), not expired (822), the nonce is the request's (823), the digest when given is the request's (824),
message_ref is the ref that channel was given (825), the owner proof passes: owner_auth.require(channel_answer) with the
channel-identity providers of that kind, bound to the stored delivery ref (828). On a decision the channels file's resume argv
runs once, with the card id and the decision word.
CLI: approvals.py request --class C --action F --summary S --card K --ttl SECONDS [--requester PROFILE] [--json]
     approvals.py intake [--json]                 one request per new approval-ask line, delivered on every answering channel
     approvals.py deliver ID --channel CH         the row's deliver argv gets the request on stdin; prints the message ref
     approvals.py collect --channel CH            the row's collect argv; each answer line is decided
     approvals.py answer ID --decision approved|denied   the host terminal's answer, proved by the owner key
     approvals.py status ID [--json]              pending | approved | denied | expired, from the trusted log
     approvals.py wait ID                         never blocks: approved = exit 0; pending prints needs_input, exit 1
Exit: 0 ok; 1 refused (the code and its plain message on stderr: STL-CFG-312 a worker, STL-OWN-820..831, owner_auth's codes,
STL-CFG-310/311/318); 2 usage. No command ends in a traceback."""
import argparse, hmac, json, os, re, secrets, signal, subprocess, sys, time, uuid
sys.dont_write_bytecode = True   # an owner command leaves nothing in the code folder
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import owner_auth as oa
import stella_data as sd

CHANNELS = "channels"   # the index row of the channel adapters
ANSWER_CLASS, HOST_CLASS = "channel_answer", "owner_write"   # owner-auth action classes: a channel answer; an owner act on the host
ID = re.compile(r"[a-z0-9][a-z0-9._:-]{0,127}")      # request ids, channel ids (the schemas' id pattern, bounded)
CARD = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}")   # never starts with "-": it becomes an argument of resume
REF = re.compile(r"[\x21-\x7e]{1,200}")               # a message ref: one printable token
DECISIONS = ("approved", "denied")
Refusal = oa.Refusal


def now():
    return time.strftime(oa.TIME, time.gmtime())


def lock():
    return el.locked(os.path.join(oa.store_dir(), "lock"))


def rec_path(rid):
    return os.path.join(oa.store_dir(), "requests", rid + ".json")


def load(rid):
    """The store record of rid, valid; None when there is none (or rid is no id)."""
    if not (isinstance(rid, str) and ID.fullmatch(rid)) or not os.path.lexists(rec_path(rid)):
        return None
    try:   # never through a link, never a FIFO
        with os.fdopen(el.open_file(rec_path(rid), os.O_RDONLY), encoding="utf-8") as f:
            return sd.checked(json.load(f), f"request {rid}", "approval-request")
    except (OSError, ValueError, sd.DataError) as e:
        raise Refusal("STL-OWN-820", f"the store record of {rid} cannot be used ({type(e).__name__})") from None


def save(rec):
    d = os.path.dirname(rec_path(rec["id"]))
    el.mkdirs(d)
    p, tmp = rec_path(rec["id"]), rec_path(rec["id"]) + ".tmp"
    fd = el.open_file(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(rec, f, indent=2, ensure_ascii=False)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)


def records():
    d = os.path.join(oa.store_dir(), "requests")
    names = sorted(n[:-5] for n in os.listdir(d) if n.endswith(".json")) if os.path.isdir(d) else []
    out = []
    for n in names:
        try:
            out.append(load(n))
        except Refusal:   # a broken record decides nothing and stops no other request
            pass
    return [r for r in out if r]


def view():
    """{request id: [request line's new, decision line's new or None]} from the lines that count as proof."""
    out = {}
    for d in el.proof_lines():
        new, rid = d.get("new"), d.get("what")
        if not isinstance(new, dict) or new.get("request_id") != rid:
            continue
        if d.get("type") == "approval-request" and rid not in out:
            out[rid] = [new, None]
        elif d.get("type") == "approval-decision" and rid in out and out[rid][1] is None \
                and new.get("digest") == out[rid][0].get("digest") and new.get("decision") in DECISIONS:
            out[rid][1] = new
    return out


def state(rid, v=None):
    """(record, request line, decision, word): word None = no such request (no record, or no trusted request line for it)."""
    rec = load(rid)
    req, dec = (v if v is not None else view()).get(rid, [None, None])
    if rec is None or req is None or req.get("digest") != rec["digest"]:
        return rec, req, None, None
    if dec:
        return rec, req, dec, dec["decision"]
    return rec, req, None, "expired" if oa.when(req.get("expires_at")) is None or oa.when(req["expires_at"]) <= time.time() else "pending"


def channel_doc():
    row = next((r for r in sd.rows() if r["id"] == CHANNELS), None)
    if row is None:
        raise Refusal("STL-CFG-310", f"the index has no {CHANNELS} row")
    try:
        return row, sd.checked(sd.load(row["path"]), row["path"], row["schema"])
    except sd.DataError as e:
        raise Refusal("STL-CFG-310", str(e)) from None


def channels():
    row, doc = channel_doc()
    return doc, {c["id"]: c for c in doc[row["list_key"]] if c["enabled"]}


def channel(cid):
    doc, rows = channels()
    if cid not in rows:
        raise Refusal("STL-CFG-311", f"channel {sd.shown(cid)} (not in the channels file, or switched off)")
    return doc, rows[cid]


def run(argv, payload, limit, code):
    """(exit code, stdout) of argv with payload (JSON) on stdin; argv[0] relative = under the stack root. Else Refusal(code)."""
    try:
        exe = argv[0] if os.path.isabs(argv[0]) else sd.safe(argv[0])
        p = subprocess.Popen([exe, *argv[1:]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, start_new_session=True)
    except (OSError, sd.DataError) as e:
        raise Refusal(code, f"{sd.shown(argv[0])} cannot start ({type(e).__name__})") from None
    try:   # its own session: a timeout kills it and everything it started
        out, _ = p.communicate(json.dumps(payload).encode(), timeout=limit)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
        raise Refusal(code, f"{sd.shown(argv[0])} ran past its {limit} s") from None
    return p.returncode, out.decode("utf-8", "replace")


def event(type, rid, new, who):
    el.append(el.build(type, rid, new=new, who=who), scrub_detail=False)


def request(cls, action, summary, card, ttl, requester=None, ask=None):
    """A new request: stored, then its trusted approval-request line (no line, no record). Refusal 829 when not well formed."""
    try:
        dg = oa.digest(action)
    except ValueError as e:
        raise Refusal("STL-OWN-829", f"action: {e}") from None
    bad = ("summary is empty" if not (isinstance(summary, str) and summary.strip()) else
           "card is not a card id" if not (isinstance(card, str) and CARD.fullmatch(card)) else
           "ttl is not a whole number of seconds (1 or more)" if not (isinstance(ttl, int) and not isinstance(ttl, bool) and ttl >= 1) else
           "requester is not a profile id" if requester is not None and not (isinstance(requester, str) and ID.fullmatch(requester)) else None)
    if bad:
        raise Refusal("STL-OWN-829", bad)
    t, rid = int(time.time()), f"apr-{secrets.token_hex(8)}"
    rec = {"schema_version": 3, "global_id": str(uuid.uuid4()), "install_id": sd.install_id(), "id": rid,
           "requested_at": time.strftime(oa.TIME, time.gmtime(t)), "requester": {"role": requester, "channel": None, "user": None},
           "approval_class": cls, "action": action, "summary": summary, "target": action["target"], "card": card,
           "expires_at": time.strftime(oa.TIME, time.gmtime(t + ttl)), "nonce": secrets.token_hex(16), "digest": dg,
           "status": "pending", "deliveries": {}, "decision": None, "ask": ask}
    try:
        sd.checked(rec, "the request", "approval-request")
    except sd.DataError as e:
        raise Refusal("STL-OWN-829", str(e)[:180]) from None
    save(rec)
    try:
        event("approval-request", rid, {k: rec[k] for k in ("digest", "approval_class", "card", "requested_at", "expires_at")}
              | {"request_id": rid, "requester": requester}, {"role": requester})
    except BaseException:
        os.unlink(rec_path(rid))   # no trusted line, no request
        raise
    return rec


def deliver(rid, cid, doc, row):
    """The message ref of rid on channel row (the lock is held): the stored one, or the adapter's (then stored)."""
    rec, _, _, word = state(rid)
    if word != "pending":
        raise Refusal(*refusal_of(rid, word))
    if cid in rec["deliveries"]:   # delivering twice shows it once
        return rec["deliveries"][cid]
    payload = {k: rec[k] for k in ("id", "nonce", "summary", "approval_class", "card", "target", "expires_at", "digest")}
    rc, out = run(row["deliver"], payload, doc["adapter_timeout_s"], "STL-OWN-830")
    ref = (out.splitlines() or [""])[0].strip()
    if rc != 0 or not REF.fullmatch(ref):
        raise Refusal("STL-OWN-830", f"channel {cid}: deliver exited {rc}" + ("" if REF.fullmatch(ref) else " and gave no message ref"))
    rec["deliveries"][cid] = ref
    save(rec)
    return ref


def refusal_of(rid, word):
    return {None: ("STL-OWN-820", f"no request {sd.shown(rid)} was made by the approval service"),
            "expired": ("STL-OWN-822", f"request {rid} expired")}.get(word, ("STL-OWN-821", f"request {rid} is already {word}"))


def accept(rec, req, decision, cid, used, doc):
    """The trusted decision line, then the store's note, then resume (its failure is reported; the decision stands)."""
    rid = rec["id"]
    drec = {"schema_version": 3, "global_id": str(uuid.uuid4()), "install_id": sd.install_id(), "request_id": rid,
            "decided_at": now(), "decision": decision, "decided_by": {"channel": cid, "user": ",".join(used)}, "note": None,
            "digest": req["digest"]}
    sd.checked(drec, "the decision", "approval-decision")
    event("approval-decision", rid, drec, {"channel": cid})
    rec["status"], rec["decision"] = decision, drec
    save(rec)
    r = doc["resume"]
    try:
        rc, _ = run([*r["argv"], rec["card"], decision], {"request_id": rid, "card": rec["card"], "decision": decision}, r["timeout_s"], "STL-OWN-831")
        if rc != 0:
            raise Refusal("STL-OWN-831", f"resume for card {rec['card']} exited {rc}")
    except Refusal as x:
        sd.say(x.code, x.problem, alert=True)


def decide(ans, row, pol, doc):
    """Accept one channel answer, or raise its Refusal (the lock is held). Returns (request id, decision)."""
    if not (isinstance(ans, dict) and all(isinstance(ans.get(k), str) for k in ("request_id", "nonce", "decision", "user", "message_ref"))
            and ans["decision"] in DECISIONS and isinstance(ans.get("digest", ""), str)):
        raise Refusal("STL-OWN-830", f"channel {row['id']}: an answer line is not {{request_id, nonce, decision: approved|denied, user, message_ref, digest?}}")
    rid, kind, given = ans["request_id"], row["kind"], ans.get("digest") or None
    rec, req, dec, word = state(rid)
    e = pol["voice_host_confirmation"]
    if kind == e["channel_kind"]:   # this kind answers only through the entry, whatever channel_kinds says
        why = ("the policy's voice_host_confirmation entry is off" if not e["enabled"] else
               "the request is unknown" if word is None else
               "the request is not the entry profile's own" if req.get("requester") != e["profile"] else
               f"the request is not of class {e['action_class']}" if req.get("approval_class") != e["action_class"] else
               f"the request's ttl is longer than {e['max_ttl_s']} s" if (oa.when(req.get("expires_at")) or 0) - (oa.when(req.get("requested_at")) or 0) > e["max_ttl_s"] else
               "the answer carries no digest of the details shown, or another one" if not (given and hmac.compare_digest(given.encode(), req["digest"].encode())) else None)
        if why:
            raise Refusal("STL-OWN-827", f"channel {row['id']} (kind {kind}): {why}")
    elif pol["channel_kinds"].get(kind) is not True:
        raise Refusal("STL-OWN-826", f"channel {row['id']} is of kind {kind}, which " + ("the policy does not list" if kind not in pol["channel_kinds"] else "may not answer"))
    if word != "pending":
        raise Refusal(*refusal_of(rid, word))
    if not hmac.compare_digest(ans["nonce"].encode(), rec["nonce"].encode()):
        raise Refusal("STL-OWN-823", f"the answer does not carry the nonce of request {rid}")
    if given is not None and not hmac.compare_digest(given.encode(), req["digest"].encode()):
        raise Refusal("STL-OWN-824", f"the answer's digest is not the action of request {rid}")
    ref = rec["deliveries"].get(row["id"])
    if ref is None or not hmac.compare_digest(ans["message_ref"].encode(), ref.encode()):
        raise Refusal("STL-OWN-825", f"the answer is not on the message request {rid} was delivered as on channel {row['id']}")
    exp = min(oa.when(req["expires_at"]), int(time.time()) + pol["proof_ttl_s"])
    proofs = [{"provider": p["id"], "digest": req["digest"], "nonce": rec["nonce"], "expires_at": time.strftime(oa.TIME, time.gmtime(exp)),
               "user": ans["user"], "message_ref": ans["message_ref"]}
              for p in pol["providers"] if p["kind"] == "channel-identity" and p["enabled"] and p["params"]["channel_kind"] == kind]
    try:
        used = oa.require(ANSWER_CLASS, rec["action"], proofs, bound={"channel_kind": kind, "message_ref": ref})
    except Refusal as r:
        raise Refusal("STL-OWN-828", f"{r.code}: {r.problem}") from None
    accept(rec, req, ans["decision"], row["id"], used, doc)
    return rid, ans["decision"]


def intake():
    """(records made, refused asks): one request per approval-ask line not yet taken, delivered on each answering channel."""
    try:
        p = el.path(sd.load(sd.INDEX)["untrusted_events"])
        # shortcut: the whole stream is read on every intake; keep a read offset when it grows large
        data = open(p, "rb").read() if os.path.lexists(p) else b""
    except (OSError, ValueError, KeyError, sd.DataError) as e:
        raise Refusal("STL-CFG-318", f"the untrusted event stream cannot be read ({type(e).__name__})") from None
    pol = oa.policy()
    doc, rows = channels()
    made, bad = [], 0
    with lock():
        taken = {r["ask"] for r in records() if r.get("ask")}
        for raw in data.split(b"\n"):
            try:
                d = json.loads(raw)
            except ValueError:
                continue
            if not (isinstance(d, dict) and d.get("type") == "approval-ask" and d.get("trusted") is False and isinstance(d.get("global_id"), str)) or d["global_id"] in taken:
                continue
            taken.add(d["global_id"])
            try:
                a = json.loads(d.get("detail") or "")
                if not (isinstance(a, dict) and set(a) <= {"class", "action", "summary", "card"}):
                    raise Refusal("STL-OWN-829", "the ask's detail is not {class, action, summary, card}")
                made.append(request(a.get("class"), a.get("action"), a.get("summary"), a.get("card"), doc["ask_ttl_s"], ask=d["global_id"]))
            except (Refusal, ValueError) as x:
                bad += 1
                code, why = (x.code, x.problem) if isinstance(x, Refusal) else ("STL-OWN-829", "the ask's detail is not JSON")
                sd.say(code, f"approval-ask line {d['global_id']}: {why}; no request made")
                continue
            for cid, row in rows.items():
                if row["kind"] != pol["voice_host_confirmation"]["channel_kind"] and pol["channel_kinds"].get(row["kind"]) is True:
                    try:
                        deliver(made[-1]["id"], cid, doc, row)
                    except Refusal as x:
                        sd.say(x.code, x.problem)
    return [load(r["id"]) for r in made], bad


def main(argv):
    ap = argparse.ArgumentParser(prog="approvals.py", description="the approval service (host side)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("request")
    for o in ("--class", "--action", "--summary", "--card", "--ttl"):
        a.add_argument(o, required=True)
    a.add_argument("--requester")
    a.add_argument("--json", action="store_true")
    sub.add_parser("intake").add_argument("--json", action="store_true")
    a = sub.add_parser("deliver")
    a.add_argument("id")
    a.add_argument("--channel", required=True)
    sub.add_parser("collect").add_argument("--channel", required=True)
    a = sub.add_parser("answer")
    a.add_argument("id")
    a.add_argument("--decision", required=True, choices=DECISIONS)
    a = sub.add_parser("status")
    a.add_argument("id")
    a.add_argument("--json", action="store_true")
    sub.add_parser("wait").add_argument("id")
    o = ap.parse_args(argv)
    try:
        oa.need_host("the approval service")
        if o.cmd == "request":
            try:
                action, ttl = sd.jload(o.action), int(o.ttl) if re.fullmatch(r"[0-9]{1,9}", o.ttl) else None
            except sd.DataError as e:
                raise Refusal("STL-OWN-829", f"the action file cannot be read: {e}") from None
            with lock():
                rec = request(o.__dict__["class"], action, o.summary, o.card, ttl, o.requester)
            print(json.dumps(rec, indent=2, ensure_ascii=False) if o.json else rec["id"])
            return 0
        if o.cmd == "intake":
            made, bad = intake()
            print(json.dumps(made, indent=2, ensure_ascii=False) if o.json else "\n".join(f"{r['id']}\t{r['card']}" for r in made))
            return 0
        if o.cmd == "deliver":
            doc, row = channel(o.channel)
            with lock():
                print(deliver(o.id, o.channel, doc, row))
            return 0
        if o.cmd == "collect":
            doc, row = channel(o.channel)
            pol = oa.policy()
            v = view()
            pending = [{"id": r["id"], "nonce": r["nonce"], "message_ref": r["deliveries"][o.channel]} for r in records()
                       if o.channel in r["deliveries"] and state(r["id"], v)[3] == "pending"]
            rc, out = run(row["collect"], pending, doc["adapter_timeout_s"], "STL-OWN-830")
            refused = 0
            if rc != 0:
                refused += 1
                sd.say("STL-OWN-830", f"channel {o.channel}: collect exited {rc}")
            for line in filter(str.strip, out.splitlines()):
                try:
                    try:
                        ans = json.loads(line)
                    except ValueError:
                        raise Refusal("STL-OWN-830", f"channel {o.channel}: an answer line is not JSON") from None
                    with lock():
                        rid, d = decide(ans, row, pol, doc)
                    print(f"{rid}\t{d}")
                except Refusal as x:
                    refused += 1
                    sd.say(x.code, x.problem)
            return 1 if refused else 0
        if o.cmd == "answer":
            pol, (doc, _) = oa.policy(), channels()
            if pol["channel_kinds"].get(doc["host_kind"]) is not True:
                raise Refusal("STL-OWN-826", f"the policy does not let kind {doc['host_kind']} (the host terminal) answer")
            with lock():
                rec, req, _, word = state(o.id)
                if word != "pending":
                    raise Refusal(*refusal_of(o.id, word))
                used = oa.require(HOST_CLASS, rec["action"], oa.prove(HOST_CLASS, rec["action"]))
                accept(rec, req, o.decision, doc["host_kind"], used, doc)
            print(f"{o.id}\t{o.decision}")
            return 0
        word = state(o.id)[3]   # status, wait
        if word is None:
            raise Refusal(*refusal_of(o.id, None))
        if o.cmd == "status":
            print(json.dumps({"id": o.id, "status": word}) if o.json else word)
            return 0
        print("needs_input" if word == "pending" else word)
        return 0 if word == "approved" else 1
    except Refusal as r:
        sd.say(r.code, r.problem, alert=True)
        return 1
    except el.EventError as e:
        sd.say(e.code, e.problem, alert=True)
        return 1
    except sd.DataError as e:
        sd.say("STL-CFG-310", str(e)[:180], alert=True)
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as e:   # never a traceback, never a value: the type only
        sd.say("STL-CFG-310", f"approvals: {type(e).__name__}, an unexpected failure")
        sys.exit(1)
