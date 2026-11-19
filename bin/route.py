#!/usr/bin/env python3
"""Model calls and failover (F2 B5, design D3 with design-check DC-06, DC-07, DC-10, DC-11), stdlib only. It only walks the chain
bin/resolve.py gives it (resolve(ctx) -> the chain document, link_key(link)): no routing rule lives here, and a provider's answer can
only move a task along that chain. Nothing here names a model, a provider, a host, a role, a preset or a link class: all are data.
CLI (host only: every command refuses in a worker environment, STL-CFG-312; the output is always JSON):
  route.py call --role R --project P [--card C] [--tier T] [--driver D] [--pending-tool-call] [--rung N] --task ID [--schema FILE] [--json]   (prompt on stdin)
      the engine loop's driver: calls the first link the task may use through its connection's wire shape (.stella/protocols.json),
      and on a failure moves on until a link answers. Output: {task, link {connection, model}, link_class, text, tool_calls, usage,
      model, switches, failure_history, refused, stubs}, plus logprobs (the per-token {token, logprob} items) when the link's answer has them
      at the wire shape's response.logprobs pointer (bin/triage.py reads the route label's probability from it).
      --rung N (the escalation script): the chain is the resolver's rung walk from N (resolve(ctx) with ctx["rung"]): the served rung's link only.
      --schema FILE (F2b B): the answer must be JSON that meets the object schema in FILE, which gets a short `reasoning` string as its first
      property. The link's newest probe record (bin/probe.py) names the output shape: the schema goes at that wire-shape pointer; with none
      (or no record) it goes in the prompt. A wrong answer gets routing probe.repair_retries repair retries, then STL-MDL-736: never a guessed value.
  route.py attempt --role R --project P [--card C] [--tier T] [--driver D] --task ID [--tokens N] [--json]
      for a worker CLI's launcher: ONE link (the next the task may use) and the task's failure_history; it calls no model and
      never switches inside an attempt.
  route.py result --task ID --link <connection>/<model> --outcome ok|<trigger id>
      the launcher reports how the attempt ended: a trigger puts the link in cooldown, so the next attempt starts on the next link.
      One trusted event line per change: `routing.cooldown` (set), `routing.cooldown-cleared` (ok cleared one; none when it cleared none).
Usage ledger (F2c A2, bin/ledger.py): call holds each link's slots for the whole call (every try and repair); a link the ledger refuses (a limit
observed, a daily cap used, no free slot) is left for the next link. Every request sent (call, and probe through send) is one usage record: the five
token types of the answer (cost.usage_of), role, project, card and task, outcome, status and latency, its cost priced from the pricing table. An answer
the wire shape's `errors` classify as a limit is observed by the ledger (the wait from the headers named in the data limit-signals) and the cooldown
entry's observed_limit holds it.
A card app the resolver refuses (`apps[]` with a code) stops the task with that code before any link is judged.
A step (one pick of a link, the same for call and attempt), in this order:
  1. the next link: the first of the chain that is usable or needs a grant, is not in cooldown, did not already fail in this task
     (the loop guard) and was not refused in this run; when the link the task last used is none of these, a link of that link's
     connection goes first (failover.same_connection_first). None left: STL-MDL-710 (nothing failed yet) or STL-MDL-723.
  2. a switch: the task's entry keeps the link it last used, and any other link is a switch from it, whoever made that link cool
     down (this task's failure, another task's, a launcher's report) and also back to an earlier link that is usable again. A
     switch past failover.max_switches_per_task stops the task (STL-MDL-723); a task with no switch left stays on its last link
     while that one can be used.
  3. call only: a link with no wire shape cannot be called here, nor one whose probed effective context (its newest probe record,
     stella_data.probed; a link with no record may serve, unproven) is below the conversation, on the first pick too; a switch is
     mid-task, so the link must also allow it (`mid_task` of the chain) and a pending tool call must stay on the same wire shape;
     else the link is refused (a switch: STL-MDL-722, one event line) and the next link is judged. The resolver is asked with the conversation's size (call: the prompt's estimate, on
     every pick; attempt: --tokens when the launcher gives it), so a link whose effective context is below it is never in the chain.
     A pick or switch of a link with no probe record for a role with requirements, or with a task size (call always has one),
     writes one STL-MDL-738 warning alert line
     (owner ruling 2026-11-18: it may serve, flagged).
  4. a link that needs a grant is never skipped: with a card and a module `consent`, consent.gate(ctx, link) -> {status: granted |
     waiting | queued, code?, request_id?} decides; with no card or no such module the task stops with STL-MDL-719 and one inbox
     alert, and no approval request is raised. A task that waits exits 3.
  5. a link of a less private class (higher privacy_rank) than the link the task used before (design D4), or, on the task's first
     pick, than the chain's first link that is not excluded (a head that cools down or needs a grant is that bar; only an
     excluded head is skipped): one inbox alert and one event line with the routing data's consent.alert_code_notice, whatever
     the grant.
  6. one trusted event line: `routing.switch` (STL-MDL-721) from the link left, else `routing.pick` with the resolver's reason; for
     a review role (the answer's cross_family), one `routing.cross-family-waiver` line (STL-MDL-737) before it when the answer is
     waived or the link is of the builder's family or of none known (a switch back to the builder's family too). A line that
     cannot be written stops the task with the event log's code before any model is called.
A failure becomes a trigger by the wire shape's `errors` rows (status, body pattern; first match wins); the transport says timeout
(the whole call has one wall-clock deadline of CALL_TIMEOUT seconds: name lookup, connect, status line, headers and body, however
the bytes arrive) and server_error (no answer, no connection, an
answer that cannot be parsed as JSON, whatever the reason, or that holds no text and no tool call) and the answer check says
malformed_tool_call (tool-call arguments that do not parse). An error no row maps is no failover trigger: the task stops
(STL-MDL-710). A redirect is never followed, and no proxy named in the environment is ever used. The prompt is read as bytes: what
is not UTF-8 is replaced.
State (index key routing_state; not proof of anything): {links {"<connection>/<model>" or, for a trigger of scope connection,
"<connection>": {trigger, since, until, failures, observed_limit}}, tasks {task: {switches, visited[], history[{link, trigger, at}],
last}}}, read and written whole under a lock (temp file, rename), refused when it is, or passes through, a link. Cooldown: until =
now + cooldown_s, doubled per repeated failure up to max_cooldown_s; one success clears it (re-promotion: one
`routing.cooldown-cleared` event line, in call too).
A task id longer than MAX_TASK characters is refused (STL-MDL-711), and a write keeps the MAX_TASKS task entries used last.
shortcut: a task's entry leaves the state only when MAX_TASKS other tasks were used after it (its loop guard and history go with
it), upgrade (prune at the task's end) when the board reports task ends to this tool.
Keys: bin/credentials.py get, into the request header only; never in a message, an event, the state or the output (an answer that
repeats the key is printed with the key masked, where it stands whole and where it is glued to other characters).
Imports: run without -I the tool restarts itself under `python3 -I`; the consent module is imported from this tool's own folder only.
Exit: 0 ok; 1 refused or failed (the catalog code and its plain message on stderr, {code, problem, ...} on stdout; an error the
tool did not foresee is STL-CFG-310 with the error's type, never a traceback); 2 usage; 3 the task waits for the owner (a grant is
needed)."""
import os, sys

if __name__ == "__main__" and not sys.flags.isolated:   # run directly: PYTHONPATH and the current folder must not decide what is imported
    try:
        os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
    except OSError:   # fail closed: a tool that holds keys does not go on with modules it cannot vouch for
        sys.exit("STL-CFG-310 route.py could not restart itself isolated (python3 -I); nothing was called")

import argparse, contextlib, datetime, http.client, ipaddress, json, re, subprocess, threading, time, urllib.error, urllib.parse, urllib.request

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import budget
import cost
import credentials
import event_log as el
import ledger
import settings
import stella_data as sd
import worker_env
try:
    import resolve
except ImportError:   # main() refuses: nothing is routed without the resolver
    resolve = None
consent = None   # step 4: without it a link that needs a grant stops the task
if os.path.isfile(os.path.join(BIN, "consent.py")):   # this tool's own folder only: a module of that name elsewhere on the path never answers the gate
    with contextlib.suppress(ImportError):
        import consent

# the alert selftest counts a code as used only when a script holds it as a literal: the notice's code is data (consent.alert_code_notice), shipped as STL-MDL-729
NO_LINK, UNKNOWN, WAITING, SWITCH, MID_REFUSED, STOPPED = "STL-MDL-710", "STL-MDL-711", "STL-MDL-719", "STL-MDL-721", "STL-MDL-722", "STL-MDL-723"
BUDGET_HELD = "STL-LIM-432"   # a call refused by a budget hold (bin/budget.py holds the same code)
PROBE_FAILED = "STL-MDL-736"   # a structured-output call that got no valid answer (bin/probe.py holds the same code for a probe)
UNEXPECTED = "STL-CFG-310"   # an error this tool did not foresee: one coded line with the error's type, never its text
LOG_FAILED = "STL-CFG-318"   # a flag line that could not be written: the pick is not used (CRT-04)
TIMEOUT_KEY = "CALL_TIMEOUT"   # the settings registry key: the seconds one model call may take
TIMED_OUT, DOWN, MALFORMED = "timeout", "server_error", "malformed_tool_call"   # triggers no errors row of a wire shape can say
WAIVER = "STL-MDL-737"   # a review role on a link of no other family than the builder's (the resolver's cross_family)
USABLE, NEEDS_GRANT, EXCLUDED, GRANTED = "usable", "needs_grant", "excluded", "granted"   # the resolver's and the consent gate's words
KEYS = set()   # the keys read in this run and their JSON-escaped forms: masked in the output wherever they stand, glued to other characters too
TIME = "%Y-%m-%dT%H:%M:%SZ"
HOST = re.compile(r"[A-Za-z0-9]([A-Za-z0-9.-]{0,253}[A-Za-z0-9])?")   # a host name or IPv4 address: nothing that could add a path or a user
WAIT = 3
MAX_TASK, MAX_TASKS = 200, 1000   # shortcut: the longest task id and the task entries the state keeps are limits in code, upgrade when the routing data carries them


class Stop(Exception):
    """The task ends here: a catalog code, the problem, the exit code, and whether the alert line is still to be written."""
    def __init__(self, code, problem, rc=1, alert=True):
        super().__init__(problem)
        self.code, self.problem, self.rc, self.alert = code, problem, rc, alert


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)   # naive UTC, as stella_data.when reads dates


# ---- the data ----
def data():
    """(routing document, {connection id: entry}, {wire shape id: entry}, local host names), as a read serves them."""
    rt = sd.routing()
    rs = [r for r in sd.rows() if r["format"] == "json" and r["schema"] in (sd.CATALOG, "protocols", "data-policy")]
    by = sd.served([r["id"] for r in rs])
    docs = lambda sch: [d for r in rs if r["schema"] == sch for _, d in by["_rows"][r["id"]][0]]
    return (rt, by.get(sd.CATALOG, {}), {e["id"]: e for d in docs("protocols") for e in d["entries"]},
            {h for d in docs("data-policy") for h in d["local_hosts"]})


def model_of(cat, link):
    """(connection entry, model entry) of a chain link; Stop when the catalog has no such link (fail closed)."""
    prov = sd.entry(cat, link["connection"])
    mod = next((m for m in prov["models"] if m["id"] == link["model"]), None) if prov and prov["kind"] == "provider" else None
    if mod is None:
        raise Stop(UNKNOWN, f"link {sd.idn(link['connection'])}/{sd.idn(link['model'])} (the catalog has no such connection and model)")
    return prov, mod


# ---- the state file ----
def write_whole(p, st):
    d, name = os.path.split(p)
    el.mkdirs(d)
    dfd = el.open_dir(d)
    try:
        tmp = name + ".tmp"   # under the lock: no other writer
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp, dir_fd=dfd)
        try:
            with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd), "wb") as f:
                f.write(json.dumps(st, indent=1).encode() + b"\n")
                f.flush()
                os.fsync(f.fileno())
            os.rename(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd)
        except BaseException:
            with contextlib.suppress(OSError):
                os.unlink(tmp, dir_fd=dfd)
            raise
    finally:
        os.close(dfd)


@contextlib.contextmanager
def state():
    """The state document under its lock; written whole when the block changed it and ended without an error. The block only
    reads and changes the document (no model call, no alert, no event line under the lock)."""
    try:
        p = el.path(sd.load(sd.INDEX)["routing_state"])   # refused when it is, or passes through, a symbolic link
        with el.locked(p + ".lock"):
            try:
                with os.fdopen(el.open_file(p, os.O_RDONLY), "rb") as f:
                    if os.fstat(f.fileno()).st_nlink != 1:
                        raise ValueError("has more than one hard link (it may be another file)")
                    st = json.loads(f.read(el.MAX_FILE + 1))
            except FileNotFoundError:
                st = {}
            except RecursionError:
                raise ValueError("is nested too deeply") from None
            if not (isinstance(st, dict) and all(isinstance(st.setdefault(k, {}), dict) and all(isinstance(v, dict) for v in st[k].values())
                                                 for k in ("links", "tasks"))):
                raise ValueError("does not hold links and tasks")
            st.setdefault("schema_version", 1)
            before = json.dumps(st, sort_keys=True)
            yield st
            if json.dumps(st, sort_keys=True) != before:
                for k in list(st["tasks"])[:-MAX_TASKS]:   # the oldest entries go (task_of moves a used one to the end): the file stays bounded
                    del st["tasks"][k]
                write_whole(p, st)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:   # the last three: a state of another shape met inside the block
        raise Stop(NO_LINK, f"the failover state file cannot be used ({el.why(e)[:120] if isinstance(e, (OSError, ValueError)) else 'it has another shape'})") from None


def task_of(st, task):
    """The task's entry, made when new, moved to the end of the tasks (the order a write prunes by). last: the link the task last used."""
    ts = st["tasks"][task] = st["tasks"].pop(task, None) or {"switches": 0, "visited": [], "history": [], "last": None}
    return ts


def cooling(st, link, t):
    """Whether the link, or its whole connection, is in cooldown at t; an `until` that is no date counts as ahead (fail closed)."""
    for k in (resolve.link_key(link), link["connection"]):
        c = st["links"].get(k, {})
        w = sd.when(c, "until") if c.get("until") is not None else None
        if w is False or (w is not None and w > t):
            return True
    return False


def observed_of(link):
    """The limit the usage ledger holds for the link now ({until, source, reason}), else None; a ledger that cannot be read gives None (the cooldown stands without it)."""
    try:
        o = ledger.active(ledger.state(), link["connection"], link["model"], ledger.utcnow())
    except (ledger.Stop, el.EventError, sd.DataError):
        return None
    return {k: o[k] for k in ("until", "source", "reason")} if o else None


def failed(st, rt, task, link, trigger, t):
    """The link (or its connection, by the trigger's scope) goes into cooldown, and the task notes the failure and leaves the link.
    Returns the state key that cools."""
    tr, key = rt["failover"]["triggers"][trigger], resolve.link_key(link)
    at = link["connection"] if tr["scope"] == "connection" else key
    old = st["links"].get(at, {})
    n = old.get("failures", 0) + 1
    secs = min(tr["cooldown_s"] * 2 ** min(n - 1, 32), tr["max_cooldown_s"])
    st["links"][at] = {"trigger": trigger, "since": old.get("since") or t.strftime(TIME), "until": (t + datetime.timedelta(seconds=secs)).strftime(TIME),
                       "failures": n, "observed_limit": observed_of(link)}
    ts = task_of(st, task)
    ts["history"].append({"link": key, "trigger": trigger, "at": t.strftime(TIME)})
    ts["visited"] += [key] if key not in ts["visited"] else []
    ts["last"] = key   # also when a launcher reports a link no attempt of this tool named
    return at


def succeeded(st, link):
    """One success clears the link's cooldown, and its connection's (re-promotion): the state keys it cleared."""
    return [k for k in (resolve.link_key(link), link["connection"]) if st["links"].pop(k, None) is not None]


# ---- alerts and events ----
def alert(code, problem):
    """One inbox alert through bin/alert.sh (one alert log line, one send). A send that fails never stops the task: the line is logged first."""
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        subprocess.run(["bash", os.path.join(BIN, "alert.sh"), code, f"problem={el.scrub(problem)}"], stdin=subprocess.DEVNULL, capture_output=True, timeout=60)


def event(kind, a, code=None, old=None, new=None, detail=None):
    el.append(el.build(kind, f"task {a.task}", old=old, new=new, code=code, detail=detail, who={"role": getattr(a, "role", None)}))   # result names no role


def cleared_event(a, keys, detail):
    """One trusted line for the cooldowns a success cleared (re-promotion); none when it cleared nothing."""
    if keys:
        event("routing.cooldown-cleared", a, old={"links": keys}, detail=detail)


def ctx_of(a):
    """What the resolver and the consent gate are asked with."""
    return {k: getattr(a, k, None) for k in ("role", "project", "card", "tier", "driver", "task", "rung", "tokens")}


# ---- one step: the next link the task uses ----
def next_link(chain, st, ts, rt, t, skip):
    """The first link the task may use now (step 1). A task with no switch left stays on the link it last used while it can."""
    key, last, fo = resolve.link_key, ts.get("last"), rt["failover"]
    c = [e for e in chain if e["status"] in (USABLE, NEEDS_GRANT) and key(e) not in ts["visited"] and key(e) not in skip and not cooling(st, e, t)]
    stay = next((e for e in c if key(e) == last), None)
    if stay is not None and ts["switches"] >= fo["max_switches_per_task"]:
        return stay
    if last and stay is None and fo["same_connection_first"]:   # the task leaves its link: that connection's other links first
        c.sort(key=lambda e: e["connection"] != last.split("/", 1)[0])   # stable: the chain order holds inside each group
    return c[0] if c else None


def unfit(a, link, left, cat, tokens, recs):
    """Why the engine loop cannot use this link now (None: it can). Without `left` (the link the task leaves) this is no switch:
    the task's first link, or the link it last used. recs: the probe records (stella_data.probe_records)."""
    prov, _ = model_of(cat, link)
    if not prov.get("protocol"):
        return "its connection has no wire shape (a worker CLI drives it, between attempts)"
    r = sd.probed(recs, prov["id"], link["model"])
    if r is not None and r["context"]["effective"] < tokens:   # the first pick too; a link with no record may serve (owner ruling 2026-11-18)
        return f"its probed effective context ({r['context']['effective']} tokens) does not hold the conversation (about {tokens} tokens)"
    if not left:
        return None
    if link.get("mid_task") is not True:
        return "the link may not be switched to in the middle of a task (between attempts only)"
    if a.pending_tool_call and prov["protocol"] != (sd.entry(cat, left.split("/", 1)[0]) or {}).get("protocol"):
        return "a tool call is pending and the link speaks another wire shape, so the call's state does not carry over"
    return None


def advance(a, doc, rt, cat, refused, tokens=None):
    """The next link of the task after every gate of a step (module text), or Stop. tokens: the conversation's size for the engine
    loop's mid-task checks; None for an attempt (a worker CLI switches between attempts only)."""
    chain, rank, recs = doc["chain"], {c["id"]: c["privacy_rank"] for c in rt["link_classes"]}, sd.probe_records(rt)
    req = sd.load(sd.load(sd.INDEX)["role_table"])["roles"].get(a.role, {}).get("requirements", {})
    while True:
        with state() as st:
            ts = task_of(st, a.task)
            link, prev, hist = next_link(chain, st, ts, rt, now(), {r["link"] for r in refused}), ts.get("last"), list(ts["history"])
            key = resolve.link_key(link) if link else None
            left = prev if prev and key != prev else None   # any other link than the one last used is a switch from it, whoever made that one cool down
            if link and left and ts["switches"] >= rt["failover"]["max_switches_per_task"]:
                raise Stop(STOPPED, f"task {a.task} already switched {ts['switches']} times, the most the routing data allows")
        if link is None:
            why = "; ".join(dict.fromkeys(str(e.get("reason")) for e in chain if e.get("reason"))) or "the chain is empty"
            raise Stop(*((STOPPED, f"task {a.task} has no link left after {len(hist)} failed") if hist else (NO_LINK, f"role {a.role}: {why}")))
        why = unfit(a, link, left, cat, tokens, recs) if tokens is not None else None
        if why:
            refused.append({"link": key, "code": MID_REFUSED if left else NO_LINK, "reason": why})
            if left:
                event("routing.switch-refused", a, MID_REFUSED, old={"link": left}, new={"link": key}, detail=why)
            continue
        if link["status"] == NEEDS_GRANT:
            if a.card is None or consent is None:   # DC-10: nothing to hang a request on; never proceeds, raises no approval request
                problem = f"task {a.task}: link {key} needs a grant ({link.get('reason') or link.get('code')})"
                alert(WAITING, problem)
                raise Stop(WAITING, problem, WAIT, alert=False)
            g = consent.gate(ctx_of(a), link)
            if g.get("status") != GRANTED:
                raise Stop(g.get("code") or WAITING, f"task {a.task}: link {key} needs a grant (request {g.get('request_id')})", WAIT, alert=False)
        # the notice's bar: the link the task used before (design D4); on a first pick the chain's first link that is not excluded.
        # Only an excluded head is skipped: a head that cools down or needs a grant is the bar, so a task that starts while a more
        # private link cools is told of. A class the routing data does not rank, or a bar the chain no longer holds: the link's
        # class counts as least private, the bar's as most (the owner is told).
        base = next((e for e in chain if (resolve.link_key(e) == prev if prev else e["status"] != EXCLUDED)), None) or {}
        inf = float("inf")
        if rank.get(link.get("link_class"), inf) > rank.get(base.get("link_class"), -inf):
            was = f"the link it used before ({prev}, class {base.get('link_class')})" if prev else f"the first link of its chain that is not excluded (class {base.get('link_class')})"
            code, problem = rt["consent"]["alert_code_notice"], f"task {a.task} uses link {key} (class {link.get('link_class')}), less private than {was}"
            alert(code, problem)
            event("routing.notice", a, code, new={"link": key, "link_class": link.get("link_class")}, detail=problem)
        cf = doc.get("cross_family") if isinstance(doc.get("cross_family"), dict) else None   # a review role: the waiver goes next to its pick or switch
        lrec = sd.probed(recs, link["connection"], link["model"])
        fam = (lrec or {}).get("family")   # the probe record's, as the resolver judged it
        if sd.needs_probe(req, lrec, getattr(a, "tokens", None)):   # it may serve unproven, flagged once per pick or switch (a task size counts as a requirement)
            if sd.alert_line(sd.UNPROBED, f"task {a.task}, role {a.role}: link {key} has no probe record (run bin/probe.py due)") is False:   # CRT-04: never served unflagged
                raise Stop(LOG_FAILED, f"task {a.task}: link {key} has no probe record and its {sd.UNPROBED} alert line could not be written, so it is not used")
        if cf and (cf.get("status") != "met" or fam in (None, cf.get("builder_family"))):
            event("routing.cross-family-waiver", a, WAIVER, new={"link": key, "family": fam},
                  detail=f"card {a.card or 'none'}, role {a.role}, preset {(doc.get('preset') or {}).get('id')}, builder family {cf.get('builder_family') or 'not known'}, served family "
                         f"{fam or 'not known'}: " + str(cf.get("reason") if cf.get("status") != "met" else "the task moved to a link of no other known family than the builder's")[:300])
        if left:
            h = hist[-1] if hist and isinstance(hist[-1], dict) else {}   # a history entry is read as data: any shape
            own = h.get("link") == left and isinstance(h.get("trigger"), str)
            event("routing.switch", a, SWITCH, old={"link": left}, new={"link": key},
                  detail=f"after {h['trigger']}" if own else "no failure of this task: its last link is not the next link it may use now")
        else:
            dec = doc.get("decision") or {}
            event("routing.pick", a, new={"link": key, "link_class": link.get("link_class"), "preset": (doc.get("preset") or {}).get("id")},
                  detail=str(dec.get("reason") or dec.get("rule") or "the first link of the chain")[:500])
        with state() as st:
            ts = task_of(st, a.task)
            ts["switches"], ts["last"] = ts["switches"] + (1 if left else 0), key
        return link


# ---- the wire ----
DROP = object()   # render(): this part of the template leaves the request


def render(v, vals, max_tokens=None):
    """A template filled in one pass (text a value holds is never filled again). A string that is exactly {max_tokens} becomes the
    link's max_tokens parameter, and its key leaves the body when the link sets none (the server's own default holds).
    shortcut: a wire shape whose server demands the field needs max_tokens in the link's parameters, upgrade when F2b's probe records the model's output limit."""
    if isinstance(v, str):
        if v == "{max_tokens}":
            return max_tokens if max_tokens is not None else DROP
        return re.sub("|".join(re.escape("{%s}" % k) for k in vals), lambda m: vals[m[0][1:-1]], v)
    if isinstance(v, list):
        return [x for x in (render(y, vals, max_tokens) for y in v) if x is not DROP]
    if isinstance(v, dict):
        return {k: x for k, y in v.items() if (x := render(y, vals, max_tokens)) is not DROP}
    return v


def ptr(doc, p):
    """The value at an RFC 6901 pointer; None when the document has nothing there."""
    for x in p.split("/")[1:]:
        try:
            doc = doc[int(x)] if isinstance(doc, list) else doc[x.replace("~1", "/").replace("~0", "~")]
        except (KeyError, IndexError, ValueError, TypeError):
            return None
    return doc


def hit(spec, status):
    """A status against an errors row's spec: an integer, [lo, hi], "5xx", "500-599"."""
    if isinstance(spec, list):
        return len(spec) == 2 and spec[0] <= status <= spec[1]
    m = re.fullmatch(r"(\d)xx|(\d+)(?:-(\d+))?", str(spec).strip().lower())
    return bool(m) and (status // 100 == int(m[1]) if m[1] else int(m[2]) <= status <= int(m[3] or m[2]))


def classify(proto, status, body):
    """The failover trigger of an error answer: the first errors row whose status and body pattern match; None when none does."""
    for e in proto["errors"]:
        with contextlib.suppress(re.error):
            if hit(e["status"], status) and ("body_pattern" not in e or re.search(e["body_pattern"], body)):
                return e["trigger"]
    return None


def malformed(sample, got):
    """Whether tool-call arguments, found where the wire shape's sample holds {arguments}, are text that does not parse as JSON."""
    if sample == "{arguments}":
        if isinstance(got, str):
            try:
                json.loads(got)
            except (ValueError, RecursionError):   # nested too deeply is no ValueError
                return True
        return False
    if isinstance(sample, list) and isinstance(got, list):
        return any(malformed(sample[0], g) for g in got) if sample else False
    if isinstance(sample, dict) and isinstance(got, dict):
        return any(malformed(s, got[k]) for k, s in sample.items() if k in got)
    return False


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None   # the key goes to the catalog's host and nowhere else


OPENER = urllib.request.build_opener(NoRedirect, urllib.request.ProxyHandler({}))   # no proxy from the environment, ever: the prompt and the key go to the catalog's host


def fetch(req, timeout, headers=None):
    """(status, raw answer) of one request; a dict given as headers is filled with the answer's headers. One wall-clock deadline covers the whole call (name lookup, connect, status line,
    headers, body): past it TimeoutError, whatever the server still sends.
    shortcut: a call cut at the deadline leaves its thread behind until that thread's own socket wait ends or the process does, upgrade to a transport that can be cancelled when streaming lands."""
    got = []

    def work():
        try:
            try:
                with OPENER.open(req, timeout=timeout) as r:
                    got.append((r.status, r.read(el.MAX_FILE + 1)))
                    hs = r.headers
            except urllib.error.HTTPError as e:
                got.append((e.code, e.read(el.MAX_FILE + 1)))
                hs = e.headers
            if headers is not None:
                headers.update(hs.items())
        except Exception as e:   # handed to the caller, which classes it
            got.append(e)

    t = threading.Thread(target=work, daemon=True)
    t.start()
    t.join(timeout)
    if not got:
        raise TimeoutError
    if isinstance(got[0], Exception):
        raise got[0]
    return got[0]


def url_of(prov, link, local, path):
    """The URL of a path on the connection's endpoint (also the probe's model list); Stop when the connection has no plain host."""
    h = next(iter(prov["hosts"]), None)   # shortcut: the entry's first host is its API endpoint, upgrade when hosts carry a purpose id
    if h is None or not HOST.fullmatch(h["host"]) or not path.startswith("/"):
        raise Stop(NO_LINK, f"link {resolve.link_key(link)}: its connection has no host that is a plain host name, or its request path does not start with /")
    try:
        plain = h["host"] in local or ipaddress.ip_address(h["host"]).is_loopback
    except ValueError:
        plain = False   # TLS to every host but a model server on this machine (a local host of the data policy, a loopback address)
    return f"{'http' if plain else 'https'}://{h['host']}:{h['port']}{path}"


def headers_of(rq, key):
    return {"Content-Type": "application/json", **{k: render(v, {"key": key or ""}) for k, v in rq["headers"].items() if key or "{key}" not in v}}


def put(doc, p, v):
    """Set the value at an RFC 6901 pointer, making objects on the way."""
    *path, last = [x.replace("~1", "/").replace("~0", "~") for x in p.split("/")[1:]]
    for x in path:
        doc = doc[int(x)] if isinstance(doc, list) else doc.setdefault(x, {})
    doc[int(last) if isinstance(doc, list) else last] = v


def note_call(proto, link, who, outcome, status, tokens, t0, plan_share=None):
    """One usage record of the call just made (the ledger's schema; its cost priced from the pricing table). A record that cannot be
    written is one alert, never the end of a call that already went out."""
    try:
        call = {"connection": link["connection"], "model": link["model"], "outcome": outcome, "status": status, "tokens": tokens,
                "latency_ms": int((time.monotonic() - t0) * 1000), "plan_share": plan_share, **(who or {})}
        rec = ledger.record(call, cost.price({**call, "ts": ledger.iso(ledger.utcnow())}, cost.load_table()))
    except (ledger.Stop, cost.Stop) as x:
        el.say(x.code, x.problem, alert=True)
    except (el.EventError, sd.DataError, OSError) as e:
        el.say(getattr(e, "code", UNEXPECTED), f"a usage record was not written ({type(e).__name__})", alert=True)


def send(prov, proto, link, prompt, key, timeout, local, edit=None, who=None):
    """One request to the link: (answer, None, status) or (None, trigger, status); trigger None with no answer: no row maps the error.
    edit: a function that changes the rendered body (the structured-output schema, the probe's tests) before it is sent.
    No text of an exception or of an error answer leaves here (either could repeat the key)."""
    rq, rs = proto["request"], proto["response"]
    vals = {"model": link["model"], "prompt": prompt}
    mt = (link.get("parameters") or {}).get("max_tokens")
    b = render(rq["body"], vals, mt if type(mt) is int else None)
    if edit:
        edit(b)
    req = urllib.request.Request(url_of(prov, link, local, render(rq["path"], dict(vals, model=urllib.parse.quote(link["model"], safe="")))),
                                 data=json.dumps(b).encode(), headers=headers_of(rq, key), method=rq.get("method", "POST"))
    t0, zero, hs = time.monotonic(), dict.fromkeys(cost.types(), 0), {}
    try:
        status, raw = fetch(req, timeout, hs)   # one deadline for the whole call: a server that drips bytes, in the head or the body, holds no task
    except (OSError, http.client.HTTPException, ValueError) as e:
        slow = isinstance(e, TimeoutError) or isinstance(getattr(e, "reason", None), TimeoutError)
        note_call(proto, link, who, "timeout" if slow else "error", None, zero, t0)
        return None, TIMED_OUT if slow else DOWN, None
    text = raw.decode("utf-8", "replace")
    if not 200 <= status < 300:
        limited = None
        with contextlib.suppress(ledger.Stop, el.EventError, sd.DataError, OSError):   # an answer that is a limit is kept by the ledger (its wait from the headers, in data)
            limited = ledger.observe_response(link["connection"], link["model"], status, hs, text)
        note_call(proto, link, who, "limit" if limited else "error", status, zero, t0)
        return None, classify(proto, status, text), status
    try:
        doc = json.loads(text)
    except Exception:   # an answer that cannot be parsed, whatever the reason (a body nested too deeply raises RecursionError, no ValueError)
        note_call(proto, link, who, "error", status, zero, t0)
        return None, DOWN, status
    text, calls = ptr(doc, rs["text"]), ptr(doc, rs["tool_calls"])
    got = cost.usage_of(proto, doc)
    if malformed(rs.get("tool_calls_sample"), calls) or (not text and not calls):   # nothing for the task: no success, so it clears no cooldown
        note_call(proto, link, who, "error", status, got, t0)
        return None, MALFORMED if calls and malformed(rs.get("tool_calls_sample"), calls) else DOWN, status
    note_call(proto, link, who, "ok", status, got, t0)
    lp = ptr(doc, rs["logprobs"]) if rs.get("logprobs") else None   # the per-token items, when the wire shape names a pointer and the answer has them
    return {"text": text, "tool_calls": calls, "usage": ptr(doc, rs["usage"]), "model": ptr(doc, rs["model"]), **({"logprobs": lp} if lp else {})}, None, status


# ---- the commands ----
def resolved(a, rt, mid):
    """The resolver's chain document for the task; the driver defaults to the routing data's first one that does (call) or does
    not (attempt) switch mid-task."""
    a.driver = a.driver or next((d["id"] for d in rt["drivers"] if d["mid_task"] is mid), None)
    doc = resolve.resolve(ctx_of(a))
    if not (isinstance(doc, dict) and isinstance(doc.get("chain"), list) and all(isinstance(e, dict) for e in doc["chain"])):
        raise Stop((doc.get("code") if isinstance(doc, dict) else None) or NO_LINK, f"role {a.role}: the resolver gave no chain")
    bad = next((x for x in doc.get("apps") or [] if isinstance(x, dict) and x.get("code")), None)
    if bad:   # a card app the resolver refuses stops the task, whatever the chain holds
        raise Stop(bad["code"], f"task {a.task}: card app {bad.get('app')} is refused ({bad.get('reason')})")
    return doc


def out(a, link, hist, refused, stubs, **more):
    """The one output line with no key in it: an answer may repeat the key it was sent, whole or glued to other characters."""
    line = json.dumps({"task": a.task, "link": {"connection": link["connection"], "model": link["model"]}, "link_class": link.get("link_class"),
                       "parameters": link.get("parameters") or {}, **more, "failure_history": hist, "refused": refused, "stubs": stubs})
    for k in sorted(KEYS, key=len, reverse=True):   # wherever it stands; the scrub alone masks a value only where it stands whole
        line = line.replace(k, el.MASK) if k else line
    print(el.scrub(line))


def timeout_of():
    """The seconds one model call may take (the settings registry's CALL_TIMEOUT); Stop when the stored value is rejected."""
    e = settings.entry(TIMEOUT_KEY)
    timeout = settings.current(e)[0]
    if type(timeout) is not int or settings.problems(e, timeout):
        raise Stop(e["code"], f"{TIMEOUT_KEY}: the stored value is rejected by the setting's own rules")
    return timeout


def with_reasoning(s):
    """The caller's object schema with a short `reasoning` string as its first property, before the verdict (one already there is kept as given)."""
    if not (isinstance(s, dict) and s.get("type") == "object" and not sd.lint_schema(s)):
        raise Stop(UNKNOWN, "the --schema file is not an object schema in the subset stella_data.py validates")
    props = dict(s.get("properties") or {})
    why = props.pop("reasoning", {"type": "string", "description": "a short reasoning, written before the other fields"})
    return {**{k: v for k, v in s.items() if k not in ("properties", "required")}, "properties": {"reasoning": why, **props},
            "required": ["reasoning", *[x for x in s.get("required", []) if x != "reasoning"]]}


def invalid(text, schema):
    """Why the answer is no JSON that meets the schema; None when it is."""
    try:
        doc = json.loads(text)
    except (TypeError, ValueError, RecursionError):
        return "it is not JSON"
    errs = sd.validate_doc(doc, schema)
    return errs[0][:200] if errs else None


def budget_gate(a):
    """Ask the budgets before any request is sent, for every scope the budget data lists (the call's own argument of that name): the link
    an approved defer allows (or None); a hold, or budget data or state that cannot be read, stops the call with its catalog code."""
    try:
        return budget.before_call(**{sc: getattr(a, sc, None) for sc in budget.scopes()})["defer_to"]
    except budget.Held as h:
        raise Stop(h.code, h.result["problem"], alert=False) from None   # the hold's own alert went out once, when it was made
    except budget.Stop as x:
        raise Stop(x.code, x.problem, alert=x.alert) from None


def cmd_call(a):
    prompt = sys.stdin.buffer.read().decode("utf-8", "replace")   # bytes that are not UTF-8 (a tool's binary output) are replaced, whatever the locale
    rt, cat, protos, local = data()
    a.tokens = tokens = len(prompt.encode()) // 4 + 1   # shortcut: about four bytes a token (the probe's own estimate), upgrade when a wire shape counts tokens
    defer = budget_gate(a)   # a defer answer is no advice: the call goes to that link only
    doc = resolved(a, rt, True)
    timeout = timeout_of()
    schema = with_reasoning(json.load(open(a.schema))) if a.schema else None   # an unreadable file ends in main()'s coded line
    a.refused = refused = []
    stubs = list(doc.get("stubs") or [])
    while True:
        link = advance(a, doc, rt, cat, refused, tokens)
        if defer and (link["connection"], link["model"]) != (defer["connection"], defer["model"]):
            refused.append({"link": resolve.link_key(link), "code": BUDGET_HELD, "reason": "the budget is deferred to another link"})
            continue
        prov, _ = model_of(cat, link)
        key = None
        if prov["secrets"]:   # shortcut: the entry's first secret is its API key, upgrade when secrets carry a purpose
            try:
                key = credentials.get(prov["secrets"][0])
            except credentials.Refused as x:
                raise Stop(x.code, f"link {resolve.link_key(link)}: {x.problem}") from None
            forms = (key, json.dumps(key)[1:-1])   # the output is JSON: the key's escaped form too
            KEYS.update(forms)
            el.SECRETS.update(forms)   # scrubbed from every event detail, alert text and output of this run
        proto, text, edit = protos[prov["protocol"]], prompt, None
        if schema:   # the strongest shape the probe proved for this link puts the schema at its pointer; else (or no record) it goes in the prompt
            import probe
            where = proto["request"].get("output_shape", {}).get(probe.shape_of(prov["id"], link["model"]))
            if where:
                edit = lambda b, w=where: put(b, w, schema)
            else:
                text = f"{prompt}\n\nAnswer with one JSON object and nothing else. It must follow this JSON Schema:\n{json.dumps(schema)}"
        who = {"role": a.role, "project": a.project, "card": a.card, "session": a.task}
        try:   # the call holds the link's slots for its whole duration (every try and repair of it); a link the ledger refuses is left for the next
            fds = ledger.acquire(link["connection"], link["model"], f"route.py task {a.task}")
        except ledger.Refusal as r:
            refused.append({"link": resolve.link_key(link), "code": STOPPED, "reason": r.problem})
            continue
        try:
            for _ in range(rt["failover"]["retry_count"] + 1):
                ans, trigger, status = send(prov, proto, link, text, key, timeout, local, edit, who)
                if ans is not None:
                    break
            for n in range(rt["probe"]["repair_retries"] + 1 if ans is not None and schema else 0):   # a wrong answer gets the repair retries, then a code: never a guessed value
                err = invalid(ans["text"], schema)
                if err is None:
                    break
                if n == rt["probe"]["repair_retries"]:
                    raise Stop(PROBE_FAILED, f"link {resolve.link_key(link)}: the answer is not JSON that meets the schema ({err}), also after {n} repair retries")
                ans, trigger, status = send(prov, proto, link, f"{text}\n\nYour answer was:\n{ans['text']}\n\nIt was refused: {err}. Answer again with one JSON object that follows the schema.", key, timeout, local, edit, who)
                if ans is None:
                    break
        finally:
            for fd in fds:
                os.close(fd)
        with state() as st:
            if ans is not None:
                cleared = succeeded(st, link)
            elif trigger in rt["failover"]["triggers"]:
                failed(st, rt, a.task, link, trigger, now())
            ts = task_of(st, a.task)
            hist, n = list(ts["history"]), ts["switches"]
        if ans is not None:
            cleared_event(a, cleared, "the link answered")
            out(a, link, hist, refused, stubs, **ans, switches=n)
            return 0
        if trigger not in rt["failover"]["triggers"]:
            raise Stop(NO_LINK, f"link {resolve.link_key(link)} failed (status {status or 'none'}) in a way that is no failover trigger of its wire shape and the routing data")


def cmd_attempt(a):
    rt, cat, _, _ = data()
    doc = resolved(a, rt, False)
    a.refused = refused = []
    link = advance(a, doc, rt, cat, refused)
    with state() as st:
        hist = list(task_of(st, a.task)["history"])
    out(a, link, hist, refused, list(doc.get("stubs") or []))
    return 0


def cmd_result(a):
    rt, cat, _, _ = data()
    conn, _, model = a.link.partition("/")
    link = {"connection": conn, "model": model}
    link["connection"] = model_of(cat, link)[0]["id"]   # the state is keyed by the connection's id, also when its global_id was given
    if a.outcome != "ok" and a.outcome not in rt["failover"]["triggers"]:
        raise Stop(UNKNOWN, "the outcome is neither ok nor a failover trigger of the routing data")
    with state() as st:
        if a.outcome == "ok":
            cleared = succeeded(st, link)
        else:
            at = failed(st, rt, a.task, link, a.outcome, now())
            cooled = {"link": at, **st["links"][at]}
    if a.outcome == "ok":   # one trusted line per change of a cooldown, written after the state (never under its lock)
        cleared_event(a, cleared, "the launcher reported a success")
    else:
        event("routing.cooldown", a, new=cooled, detail=f"the launcher reported {a.outcome}")
    print(json.dumps({"task": a.task, "link": link, "outcome": a.outcome}))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="route.py", description="Model calls and failover along the resolver's chain (host only).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("call", "attempt"):
        p = sub.add_parser(name)
        for k, req in (("role", True), ("project", True), ("card", False), ("tier", False), ("driver", False), ("task", True)):
            p.add_argument("--" + k, required=req)
        p.add_argument("--json", action="store_true")
    sub.choices["call"].add_argument("--pending-tool-call", action="store_true")
    sub.choices["call"].add_argument("--rung", type=int, help="the chain is that rung of the role's escalation chain (resolve --rung): the escalation script's call")
    sub.choices["attempt"].add_argument("--tokens", type=int, help="the task's size in tokens: a link whose probed effective context is below it is not in the chain")
    sub.choices["call"].add_argument("--schema", help="a JSON Schema file: the answer must be JSON that meets it (one short `reasoning` property is added first)")
    p = sub.add_parser("result")
    for k in ("task", "link", "outcome"):
        p.add_argument("--" + k, required=True)
    p.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    extra = None   # an event-log refusal's own values for its catalog message
    try:
        w = worker_env.reason()
        if w:
            raise Stop(sd.Refused.code, f"route.py {a.cmd} runs on the host only ({w}); nothing was called")
        if len(a.task) > MAX_TASK:
            a.task = a.task[:MAX_TASK]   # the refusal does not repeat the whole of it
            raise Stop(UNKNOWN, f"the task id is longer than {MAX_TASK} characters")
        if resolve is None:
            raise Stop(NO_LINK, "the resolver is not installed, so no chain can be read")
        return {"call": cmd_call, "attempt": cmd_attempt, "result": cmd_result}[a.cmd](a)
    except Stop as x:
        s = x
    except el.EventError as e:   # no pick, switch or notice without its trusted line
        s, extra = Stop(e.code, e.problem), e.extra
    except settings.Refuse as e:
        s = Stop(e.code, e.problem)
    except sd.DataError as e:
        s = Stop(getattr(e, "code", "STL-CFG-310"), str(e)[:180])
    except Exception as e:   # never a traceback, never the error's text (it could repeat a value): the type only
        s = Stop(UNEXPECTED, f"{type(e).__name__}, an unexpected failure of route.py {a.cmd}")
    # every refusal, whichever module raised it: the JSON line on stdout and the catalog line on stderr
    print(json.dumps({"task": a.task, "code": s.code, "problem": el.scrub(s.problem), "refused": getattr(a, "refused", [])}))
    el.say(s.code, s.problem, alert=s.alert, extra=extra)
    return s.rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
