#!/usr/bin/env python3
"""The usage ledger and limits core (F2c item A1), stdlib only. One place that counts what every link (a connection plus a model) is used
for and how much of its limits is left. No model, provider, host or number is in this file: links come from the catalog, limits from the
catalog's `limits` / `concurrency_limit` (a number, or the name of a .supervisor/limits.env key, exactly as bin/escalate.sh reads them: a
name the file does not define, or a value that is no whole number, is ZERO, so the link serves nothing until it is fixed), the answers and
CLI texts that mean "limited" from .stella/limit-signals.json and the wire shapes' `errors`.
Module: record(call, cost=None), status(connection, model=None), acquire/slot(connection, model, holder), observe_limit(...),
observe_response(...), observe_cli_text(...), plan_share_from(connection, text), report(by). CLI (host only: every command refuses in a
worker environment, STL-CFG-312; JSON out, --json accepted everywhere):
  ledger.py record --json                      one call as JSON on stdin; one line appended to the usage file (index key usage_ledger).
  ledger.py status --connection C [--model M]  {concurrency:{limit,in_use,free}, daily:{cap,used,resets_at}, observed, plan_share, problems}
  ledger.py hold --connection C --model M [--holder H] -- CMD...   take a slot (the connection's and the model's), then become CMD: the
        slot is held by the process across every worker, so it is released when CMD ends or is killed. Exit 75 no free slot, 76 daily cap
        used, 77 an observed limit is active (catalog code STL-LIM-412 on stderr); otherwise CMD's own exit code.
  ledger.py observe --connection C [--model M] [--status N [--header 'Name: v']...]   the answer body (or, with no --status, a CLI's
        output) on stdin; prints the observed limit, or null when the answer is no limit.
  ledger.py report --by card|project|role|model|connection     calls, tokens and cost per key.
  ledger.py check                              the usage file and the state file against their schemas.
Slots are open-file-description locks (fcntl F_OFD_SETLK; status asks with F_OFD_GETLK, which takes none) on files under <ledger_state path>.slots/. A daily cap counts the records of the day of the signals data's day_reset clock (an outcome whose outcome_classes say it is no call is left out).
Every state change that is no plain call record (a limit observed, a hold refused) is one trusted event line (bin/event_log.py).
Exit: 0 ok; 1 refused or failed (catalog code and plain message on stderr, {code, problem} on stdout); 2 usage; 75, 76, 77 of hold.
shortcut: struct flock is the 64-bit Linux layout (FLOCK). shortcut: the usage file is read whole on every status, hold and report; upgrade (an index or a daily counter file) when it grows past
a few hundred thousand lines. shortcut: a daily cap is checked, not reserved: callers that run in parallel past a cap with no slot limit
can overshoot it by the calls in flight; give the model a max_concurrent to close that."""
import os, sys

if __name__ == "__main__" and not sys.flags.isolated:   # run directly: PYTHONPATH and the current folder must not decide what is imported
    try:
        os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
    except OSError:   # fail closed: a tool that counts limits does not go on with modules it cannot vouch for
        sys.exit("STL-CFG-310 ledger.py could not restart itself isolated (python3 -I); nothing was done")

import argparse, contextlib, datetime, email.utils, fcntl, json, math, re, struct, urllib.parse, uuid, zoneinfo

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import stella_data as sd
import worker_env

UNKNOWN, INVALID, LIMITED, FILE, BADFILE, BADLIMIT, UNEXPECTED = ("STL-LIM-410", "STL-LIM-411", "STL-LIM-412", "STL-LIM-413", "STL-LIM-414",
                                                                 "STL-LIM-415", "STL-CFG-310")
EX_SLOT, EX_DAILY, EX_OBSERVED = 75, 76, 77   # hold: no free slot, daily cap used, an observed limit is active
BY = {"card": "card", "project": "project", "role": "role", "model": "model", "connection": "connection"}
KEYRE = re.compile(r"[A-Z][A-Z0-9_]*")
TS = "%Y-%m-%dT%H:%M:%SZ"


class Stop(Exception):
    def __init__(self, code, problem, alert=True):
        super().__init__(problem)
        self.code, self.problem, self.alert = code, problem, alert


class Refusal(Exception):
    """A hold the limits refuse: kind slot, daily or observed; exit code and plain reason."""
    def __init__(self, kind, problem):
        super().__init__(problem)
        self.kind, self.problem = kind, problem
        self.rc = {"slot": EX_SLOT, "daily": EX_DAILY, "observed": EX_OBSERVED}[kind]


def utcnow():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def iso(dt):
    return dt.strftime(TS)


def when(s):
    return datetime.datetime.strptime(s, TS).replace(tzinfo=datetime.timezone.utc)


def day_bounds(now):
    """(start, end) in UTC of the day `now` is in, by the reset clock of the signals data (day_reset: a UTC offset or a zone name)."""
    dr = signals()["day_reset"]
    try:
        if len(dr) != 1:
            raise ValueError
        tz = zoneinfo.ZoneInfo(dr["zone"]) if "zone" in dr else datetime.timezone(datetime.timedelta(minutes=dr["utc_offset_minutes"]))
    except (ValueError, KeyError, OSError):   # an unknown zone is a KeyError (ZoneInfoNotFoundError)
        raise Stop(BADFILE, "the signals data's day_reset is exactly one of utc_offset_minutes or a zone name the system knows")
    start = now.astimezone(tz).replace(hour=0, minute=0, second=0, microsecond=0)
    end = (start + datetime.timedelta(days=1)).replace(hour=0)
    return start.astimezone(datetime.timezone.utc), end.astimezone(datetime.timezone.utc)


def midnight(now):
    return day_bounds(now)[1]


# ---- the files ----
def rel(key):
    return sd.load(sd.INDEX)[key]


def usage_path():
    return el.path(rel("usage_ledger"))   # refused when it is, or passes through, a symbolic link


def state_path():
    return el.path(rel("ledger_state"))


def slots_dir():
    return el.path(rel("ledger_state") + ".slots")


def one_doc(schema):
    """The one data file of that schema (a Stop when the index has none or it breaks the schema)."""
    r = next((r for r in sd.rows() if r["schema"] == schema), None)
    if r is None:
        raise Stop(BADFILE, f"the index has no {schema} row")
    return sd.checked(sd.load(r["path"]), r["path"], schema)


def signals():
    return one_doc("limit-signals")


def token_types():
    """The token types: the properties of the usage schema's tokens, the one list every other file follows."""
    return list(sd.schema_of("usage")["properties"]["tokens"]["properties"])


def outcome_flag(sig, outcome, flag):
    """counts_as_call or is_error of an outcome word by the signals data; a word the data does not list is both."""
    c = sig["outcome_classes"].get(outcome)
    return c[flag] if c else True


def plan_billed(sig, prov):
    """True when the connection's type is billed by plan (no cost, a plan share) by the signals data's billing."""
    return sig["billing"].get(prov.get("type")) == "plan"


def limits_env():
    """{KEY: value} of the limits store (the index row `limits`), as a shell would source plain KEY=value lines (last wins, a trailing
    ` # comment` of an unquoted value dropped); {} when the file is missing."""
    r = next((r for r in sd.rows() if r["id"] == "limits"), None)
    out = {}
    try:
        with open(sd.safe(r["path"]), encoding="utf-8") as f:
            for line in f:
                m = re.fullmatch(r"(?:export\s+)?([A-Z][A-Z0-9_]*)=(.*)", line.rstrip("\n"))
                if m:
                    v = m[2].strip()
                    out[m[1]] = v[1:-1] if len(v) > 1 and v[0] == v[-1] and v[0] in "'\"" else re.split(r"\s#", v)[0].strip()
    except (OSError, TypeError, sd.DataError):
        pass   # no store: every key it should hold is undefined, so the limit that names one is zero
    return out


def state():
    """The ledger state document; a missing file is an empty one; a file that cannot be used stops the call (fail closed)."""
    try:
        with open(state_path(), "rb") as f:
            doc = json.loads(f.read(el.MAX_FILE + 1))
    except FileNotFoundError:
        return {"schema_version": 1, "observed": []}
    except (OSError, ValueError, RecursionError, el.EventError) as e:
        raise Stop(BADFILE, f"the ledger state file cannot be read ({type(e).__name__})")
    errs = sd.validate_doc(doc, sd.schema_of("ledger-state"))
    if errs:
        raise Stop(BADFILE, f"the ledger state file breaks its schema ({errs[0]})")
    return doc


def good(d):
    """A usage line the schema accepts, with a ts that is a real time (the pattern alone lets month 99 through)."""
    if sd.validate_doc(d, sd.schema_of("usage")):
        return False
    try:
        when(d["ts"])
    except ValueError:
        return False
    return True


def lines(valid=True):
    """([the JSON objects of the usage file], torn): a line that is no JSON object (a writer killed mid-line) or, with `valid`, breaks the
    usage schema is skipped and counted, with one alert per read (check() reads them all: it reports what the schema says)."""
    try:
        with open(usage_path(), "rb") as f:
            data = f.read()
    except FileNotFoundError:
        return [], 0
    except (OSError, el.EventError, ValueError) as e:
        raise Stop(BADFILE, f"the usage file cannot be read ({type(e).__name__})")
    out, torn = [], 0
    for ln in data.split(b"\n"):
        if not ln.strip():
            continue
        try:
            d = json.loads(ln)
        except (ValueError, RecursionError):
            d = None
        if isinstance(d, dict) and (not valid or good(d)):
            out.append(d)
        else:
            torn += 1
    if torn and valid:
        el.say(BADFILE, f"{torn} line(s) of the usage file are no valid call record: skipped", alert=True)
    return out, torn


# ---- the catalog ----
def catalog():
    import route
    return route.data()


def link_of(cat, connection, model):
    """(connection entry, model entry or None); Stop(410) when the catalog has no such connection, or no such model of it."""
    prov = sd.entry(cat, connection) if isinstance(connection, str) else None
    mod = next((m for m in prov["models"] if m["id"] == model), None) if prov and prov["kind"] == "provider" and model is not None else None
    if not prov or prov["kind"] != "provider" or (model is not None and mod is None):
        raise Stop(UNKNOWN, f"link {sd.idn(connection)}" + (f"/{sd.idn(model)}" if model is not None else "") + " (the catalog has no such connection and model)")
    return prov, mod


def limit_of(raws, env):
    """(the tightest of the values, a problem or None): a value is a whole number or the name of a limits.env key; one that cannot be
    read is 0 (fail closed, as escalate.sh's empty L). None when no value is given."""
    vals, bad = [], None
    for r in raws:
        if r is None:
            continue
        v = env().get(r) if isinstance(r, str) and KEYRE.fullmatch(r) else r
        if isinstance(v, str) and re.fullmatch(r"[0-9]+", v):
            v = int(v)
        if type(v) is int and v >= 0:
            vals.append(v)
        else:
            vals.append(0)
            bad = f"the limit {sd.idn(r) if isinstance(r, str) else 'value'} is not a whole number or a key of the limits store that holds one, so it counts as 0"
    return (min(vals) if vals else None), bad


def scopes(prov, mod, model):
    """The scopes of a link, the connection's first: [{model: None|id, conc, day, problems}]; each limit is resolved (limit_of)."""
    cache = []
    env = lambda: cache[0] if cache else (cache.append(limits_env()) or cache[0])
    out = []
    for m, lim, extra in (((None, prov.get("limits") or {}, [prov.get("concurrency_limit")]),) +
                          (((model, (mod or {}).get("limits") or {}, []),) if model is not None else ())):
        conc, p1 = limit_of(extra + [lim.get("max_concurrent")], env)
        day, p2 = limit_of([lim.get("per_day")], env)
        out.append({"model": m, "conc": conc, "day": day, "problems": [p for p in (p1, p2) if p]})
    return out


# ---- slots ----
def slot_file(connection, model, i):
    q = lambda s: urllib.parse.quote(s or "", safe="")   # injective: no two links share a file name
    return os.path.join(slots_dir(), f"{q(connection)}@{q(model)}.{i}.lock")


def open_slot(connection, model, i):
    try:
        el.mkdirs(slots_dir())
        return el.open_file(slot_file(connection, model, i), os.O_RDWR | os.O_CREAT)   # never through a link or a hard-linked file
    except (OSError, ValueError, el.EventError) as e:
        raise Stop(FILE, f"a slot lock file of {sd.idn(connection)} cannot be used ({el.why(e)})")


FLOCK = "hhqqi"   # struct flock: type, whence, start, len, pid (64-bit Linux)


def ofd(fd, cmd):
    """An open-file-description write lock request (F_OFD_SETLK takes it, F_OFD_GETLK only asks): unlike flock, asking never blocks a taker."""
    return fcntl.fcntl(fd, cmd, struct.pack(FLOCK, fcntl.F_WRLCK, 0, 0, 0, 0))


def take(connection, model, n):
    """An open, flocked slot fd of the n of the scope, or None when all are taken."""
    for i in range(1, n + 1):
        fd = open_slot(connection, model, i)
        try:
            ofd(fd, fcntl.F_OFD_SETLK)
            return fd
        except OSError:
            os.close(fd)
    return None


def in_use(connection, model, n):
    """How many of the n slots are held now, asked with F_OFD_GETLK: it takes no lock, so it never costs a holder its slot."""
    used = 0
    for i in range(1, n + 1):
        try:
            fd = el.open_file(slot_file(connection, model, i), os.O_RDONLY)   # read-only: a lock file that is not there is held by no one, and a reader makes none (the resolver)
        except FileNotFoundError:
            continue
        except (OSError, ValueError, el.EventError) as e:
            raise Stop(FILE, f"a slot lock file of {sd.idn(connection)} cannot be used ({el.why(e)})")
        try:
            used += struct.unpack(FLOCK, ofd(fd, fcntl.F_OFD_GETLK))[0] != fcntl.F_UNLCK
        finally:
            os.close(fd)
    return used


def day_used(recs, connection, model, now):
    """The calls of the link in the day `now` is in (the data's reset clock); an outcome that does not count as a call is left out."""
    sig, (a, b) = signals(), day_bounds(now)
    a, b = iso(a), iso(b)
    return sum(1 for r in recs if r.get("kind") == "call" and outcome_flag(sig, r.get("outcome"), "counts_as_call") and r.get("connection") == connection
               and model in (None, r.get("model")) and a <= str(r.get("ts", "")) < b)


def active(doc, connection, model, now):
    """The observed limit in force for the link (latest end first), or None."""
    live = [o for o in doc["observed"] if o["connection"] == connection and o["model"] in (None, model) and when(o["until"]) > now]
    return max(live, key=lambda o: o["until"]) if live else None


def acquire(connection, model, holder, now=None):
    """The open flocked fds of the slots of the link (its connection's and its model's), held until they are closed (or the process
    ends or is killed). Refusal (an observed limit, a daily cap used, no free slot) is written as one trusted limit.hit line and raised
    as Refusal; an unknown link is Stop(410)."""
    now = now or utcnow()
    _, cat, _, _ = catalog()
    prov, mod = link_of(cat, connection, model)
    connection = prov["id"]   # the global_id is the same link: one key for slots, count and limits
    fds = []
    try:
        o = active(state(), connection, model, now)
        if o:
            raise Refusal("observed", f"a limit is observed on {sd.idn(connection)}/{sd.idn(model)} until {o['until']} ({o['source']}: {o['reason']})")
        recs, _ = lines()
        for s in scopes(prov, mod, model):
            where = f"{sd.idn(connection)}/{sd.idn(s['model'])}" if s["model"] else f"connection {sd.idn(connection)}"
            if s["day"] is not None and day_used(recs, connection, s["model"], now) >= s["day"]:
                raise Refusal("daily", f"{where}: the daily limit is used ({s['day']} calls) until {iso(midnight(now))}" + "".join(f"; {p}" for p in s["problems"]))
            if s["conc"] is not None:
                fd = take(connection, s["model"], s["conc"])
                if fd is None:
                    raise Refusal("slot", f"{where}: no free slot (max concurrent {s['conc']})" + "".join(f"; {p}" for p in s["problems"]))
                fds.append(fd)
    except Refusal as r:
        for fd in fds:
            os.close(fd)
        with contextlib.suppress(el.EventError, sd.DataError, Stop):   # the refusal stands whether or not its line could be written
            el.append(el.build("limit.hit", f"{r.kind} limit refused a call of {connection}/{model}", new={
                "connection": connection, "model": model, "holder": str(holder)[:signals()["field_limits"]["holder"]], "kind": r.kind}))
        raise
    except BaseException:
        for fd in fds:
            os.close(fd)
        raise
    return fds


@contextlib.contextmanager
def slot(connection, model, holder):
    fds = acquire(connection, model, holder)
    try:
        yield
    finally:
        for fd in fds:
            os.close(fd)


# ---- records ----
def scrubbed(v):
    if isinstance(v, str):
        return el.scrub(v)
    if isinstance(v, dict):
        return {k: scrubbed(x) for k, x in v.items()}
    return v


def record(call, cost=None):
    """Append one call record; returns it. The call holds connection, model and what is known of role, project, card, session, outcome,
    status, tokens, latency_ms, batch, plan_share; cost (already priced, or None) may be a key of the call or the argument. Stop(411)
    when the record breaks its schema, Stop(410) when the catalog has no such connection and model, nothing written."""
    if not isinstance(call, dict):
        raise Stop(INVALID, "a call record is a JSON object")
    zero = dict.fromkeys(token_types(), 0)
    rec = scrubbed({"v": 1, "id": str(uuid.uuid4()), "install_id": sd.install_id(), "ts": iso(utcnow()), "role": None, "project": None,
                    "card": None, "session": None, "kind": "call", "status": None, "latency_ms": 0, "batch": False, "cost": None,
                    "plan_share": None, **call, "tokens": {**zero, **(call.get("tokens") or {})}, **({"cost": cost} if cost is not None else {})})
    errs = sd.validate_doc(rec, sd.schema_of("usage"))
    if errs:
        raise Stop(INVALID, f"the call record breaks the usage schema ({errs[0]})")
    rec["connection"] = link_of(catalog()[1], rec["connection"], rec["model"])[0]["id"]
    p = usage_path()
    with el.locked(p + ".lock"):
        fd = el.open_file(p, os.O_RDWR | os.O_APPEND | os.O_CREAT)
        try:
            size = os.fstat(fd).st_size
            lead = b"\n" if size and os.pread(fd, 1, size - 1) != b"\n" else b""   # a killed writer's torn line stays its own line
            data = lead + json.dumps(rec, separators=(",", ":")).encode() + b"\n"
            if os.write(fd, data) != len(data):
                os.ftruncate(fd, size)
                raise Stop(FILE, "the usage file could not be written whole; nothing was recorded")
            os.fsync(fd)
        finally:
            os.close(fd)
    try:   # every record is also one span (local file; the OTLP export is a separate command); a span that fails is one alert, the record stands
        import cost   # lazy: cost.py imports this module
        cost.write_span(cost.span_of(rec))
    except Exception as e:
        el.say(getattr(e, "code", UNEXPECTED), f"a span was not written ({type(e).__name__})", alert=True)
    return rec


# ---- observed limits ----
def observe_limit(connection, model, source, until, reason, now=None):
    """Keep a limit observed on the connection (model None: every model of it) until the UTC time `until` (a datetime); one trusted
    limit.observed line. An observation of the same source that already lasts longer is kept as it is (None changes, no line).
    Returns the observation."""
    now = now or utcnow()
    connection = link_of(catalog()[1], connection, model)[0]["id"]
    new = {"connection": connection, "model": model, "source": source, "until": iso(until), "reason": el.scrub(str(reason))[:signals()["field_limits"]["reason"]]}
    p = state_path()
    el.preflight()   # no state change without its trusted line
    with el.locked(p + ".lock"):
        doc = state()
        same = [o for o in doc["observed"] if (o["connection"], o["model"], o["source"]) == (connection, model, source) and when(o["until"]) > now]
        if same and same[0]["until"] >= new["until"]:
            return same[0]
        doc["observed"] = [o for o in doc["observed"] if when(o["until"]) > now and o not in same] + [new]
        import route
        route.write_whole(p, doc)
    el.append(el.build("limit.observed", f"limit observed on {connection}/{model or '*'} until {new['until']}", new=new))
    return new


def seconds_of(v, now):
    """The wait a header value names: seconds, a duration (1m30s, 250ms), an epoch, an ISO time or an HTTP date; None when none fits."""
    v, sig = str(v).strip(), signals()
    try:
        n = float(v)
        return n - now.timestamp() if n > sig["epoch_min_seconds"] else n
    except ValueError:
        pass
    units = sig["duration_units"]
    parts = re.findall(r"([0-9]+(?:\.[0-9]+)?)(" + "|".join(map(re.escape, sorted(units, key=len, reverse=True))) + ")", v) if units else []
    if parts and "".join(a + b for a, b in parts) == v:
        return sum(float(a) * units[b] for a, b in parts)
    for parse in (lambda: datetime.datetime.fromisoformat(v.replace("Z", "+00:00")), lambda: email.utils.parsedate_to_datetime(v)):
        try:
            t = parse()
            return ((t if t.tzinfo else t.replace(tzinfo=datetime.timezone.utc)) - now).total_seconds()
        except (ValueError, TypeError):
            continue
    return None


def observe_response(connection, model, status, headers, body, now=None):
    """Observe the limit an API answer shows, when the wire shape's `errors` classify it as one (rate_limit, daily_cap); the wait is
    the first the signals data's limit_triggers lists for the trigger that gives a time (the retry-after header, the longest reset
    header, the next reset of the daily clock, the default). None when the answer is no limit."""
    import route
    now = now or utcnow()
    _, cat, protos, _ = catalog()
    prov, _ = link_of(cat, connection, model)
    proto = protos.get(prov.get("protocol"))
    if proto is None:
        raise Stop(UNKNOWN, f"connection {sd.idn(connection)} has no wire shape, so its answers cannot be classified")
    trigger = route.classify(proto, status, body)
    sig, h = signals(), {k.lower(): v for k, v in headers.items()}
    if trigger not in sig["limit_triggers"]:
        return None
    pick = lambda names: [s for s in (seconds_of(h[n], now) for n in names if n in h) if s is not None and math.isfinite(s)]   # nan, inf: no wait named
    ra, rs = pick(sig["headers"]["retry_after"]), pick(sig["headers"]["reset"])
    for src in sig["limit_triggers"][trigger]:
        if src == "retry_after" and ra:
            source, wait = src, max(ra)
        elif src == "reset_header" and rs:
            source, wait = src, max(rs)
        elif src == "day_reset":
            source, wait = trigger, (midnight(now) - now).total_seconds()
        elif src == "default":
            source, wait = trigger, sig["default_wait_seconds"]
        else:
            continue
        break
    else:   # no listed source gave a time: the default wait, never no wait
        source, wait = trigger, sig["default_wait_seconds"]
    wait = min(max(wait, sig["min_wait_seconds"]), sig["max_wait_seconds"])
    return observe_limit(connection, model, source, now + datetime.timedelta(seconds=wait), f"{trigger} (HTTP {status})", now)


def cli_of(connection):
    prov, _ = link_of(catalog()[1], connection, None)
    return prov.get("cli") if plan_billed(signals(), prov) else None


def cli_limit_hit(cli, text):
    """The 1-based number of the first limit pattern of the data (cli_patterns of that CLI) the text holds; None when none."""
    return next((i + 1 for i, p in enumerate(signals()["cli_patterns"].get(cli) or []) if p in text), None)


def observe_cli_text(connection, model, text, now=None):
    """Observe the limit a cli-login CLI's output shows (its patterns, by the connection's `cli`, from the signals data); None when
    the text is no limit error."""
    now = now or utcnow()
    sig, cli = signals(), cli_of(connection)
    hit = cli_limit_hit(cli, text)
    if hit is None:
        return None
    return observe_limit(connection, model, "cli_limit_error", now + datetime.timedelta(seconds=sig["default_wait_seconds"]),
                         f"the CLI's limit error (pattern {hit})", now)


def plan_share_from(connection, text):
    """The fraction of the plan a CLI's usage output shows (the data's cli_usage patterns, group pct); None when none matches."""
    for p in signals()["cli_usage"].get(cli_of(connection)) or []:
        m = re.search(p, text)
        if m and m.groupdict().get("pct"):
            with contextlib.suppress(ValueError):
                return float(m["pct"]) / 100
    return None


# ---- status and report ----
def status(connection, model=None, now=None):
    now = now or utcnow()
    _, cat, _, _ = catalog()
    prov, mod = link_of(cat, connection, model)
    connection = prov["id"]
    recs, _ = lines()
    conc, day, problems = None, None, []
    for s in scopes(prov, mod, model):
        problems += s["problems"]
        if s["conc"] is not None:
            used = in_use(connection, s["model"], s["conc"])
            if conc is None or s["conc"] - used < conc["free"]:
                conc = {"limit": s["conc"], "in_use": used, "free": s["conc"] - used}
        if s["day"] is not None:
            u = day_used(recs, connection, s["model"], now)
            if day is None or s["day"] - u < day["cap"] - day["used"]:
                day = {"cap": s["day"], "used": u, "resets_at": iso(midnight(now))}
    o = active(state(), connection, model, now)
    share = None
    sig = signals()
    if plan_billed(sig, prov):
        age = sig["plan_share_max_age_seconds"]
        got = [r for r in recs if r.get("connection") == connection and r.get("plan_share") is not None and
               (now - when(r["ts"])).total_seconds() <= age] if all(isinstance(r.get("ts"), str) for r in recs) else []
        share = sig["limit_error_plan_share"] if o and o["source"] == "cli_limit_error" else (max(got, key=lambda r: r["ts"])["plan_share"] if got else None)
    return {"concurrency": conc or {"limit": None, "in_use": 0, "free": None}, "daily": day or {"cap": None, "used": 0, "resets_at": None},
            "observed": {k: o[k] for k in ("until", "source", "reason")} if o else None, "plan_share": share, "problems": problems}


def report(by):
    if by not in BY:
        raise ValueError(by)
    recs, torn = lines()
    groups, sig, types = {}, signals(), token_types()
    for r in recs:
        g = groups.setdefault(str(r.get(BY[by]) or "(none)"), {"calls": 0, "errors": 0, "tokens": dict.fromkeys(types, 0), "cost": {}, "unpriced": 0})
        g["calls"] += 1
        g["errors"] += outcome_flag(sig, r.get("outcome"), "is_error")
        for k, v in (r.get("tokens") or {}).items():
            if k in g["tokens"] and type(v) is int:
                g["tokens"][k] += v
        c = r.get("cost")
        if c and c.get("priced") and isinstance(c.get("amount"), (int, float)):
            g["cost"][c["currency"]] = round(g["cost"].get(c["currency"], 0) + c["amount"], 10)
        elif c is not None:
            g["unpriced"] += 1
    return {"by": by, "groups": dict(sorted(groups.items())), "torn": torn}


def check():
    recs, torn = lines(False)
    errs, seen = [], set()
    for i, r in enumerate(recs):
        e = sd.validate_doc(r, sd.schema_of("usage"))
        if e:
            errs.append(f"record {i + 1}: {e[0]}")
        elif r["id"] in seen:
            errs.append(f"record {i + 1}: its id is used twice")
        seen.add(r.get("id"))
    obs = len(state()["observed"])   # Stop when the state file cannot be used
    signals()
    return {"ok": not errs, "records": len(recs), "torn": torn, "observed": obs, "problem": errs[0] if errs else None}


# ---- the CLI ----
def say_json(a, doc):
    print(json.dumps(doc, indent=None if a.json else 1))


def cmd_record(a):
    try:
        call = json.loads(sys.stdin.read(el.MAX_FILE))
    except (ValueError, RecursionError):
        raise Stop(INVALID, "the call record on stdin is not JSON")
    say_json(a, record(call))
    return 0


def cmd_status(a):
    say_json(a, status(a.connection, a.model))
    return 0


def cmd_hold(a):
    cmd = a.command[1:] if a.command[:1] == ["--"] else a.command
    if not cmd:
        raise SystemExit(2)
    try:
        fds = acquire(a.connection, a.model, a.holder or f"pid {os.getpid()}")
    except Refusal as r:
        el.say(LIMITED, r.problem)
        print(json.dumps({"code": LIMITED, "problem": el.scrub(r.problem), "kind": r.kind}))
        return r.rc
    for fd in fds:
        os.set_inheritable(fd, True)   # the command inherits the locks: they end with it, or when it is killed
    try:
        os.execvp(cmd[0], cmd)
    except OSError as e:
        raise Stop(UNEXPECTED, f"the command cannot be started ({type(e).__name__})", alert=False)


def cmd_observe(a):
    body = sys.stdin.read(el.MAX_FILE)
    if a.status is None:
        got = observe_cli_text(a.connection, a.model, body)
    else:
        hs = {}
        for h in a.header:
            k, _, v = h.partition(":")
            hs[k.strip()] = v.strip()
        got = observe_response(a.connection, a.model, a.status, hs, body)
    say_json(a, got)
    return 0


def cmd_report(a):
    say_json(a, report(a.by))
    return 0


def cmd_check(a):
    out = check()
    say_json(a, out)
    if out["problem"]:
        raise Stop(BADFILE, out["problem"], alert=False)
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="ledger.py", description="Usage ledger and limits (host only).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, flags in (("record", ()), ("status", ("connection", "model")), ("hold", ("connection", "model", "holder")),
                        ("observe", ("connection", "model")), ("report", ("by",)), ("check", ())):
        p = sub.add_parser(name)
        for f in flags:
            p.add_argument("--" + f, required=f == "by" or (f == "connection") or (f == "model" and name == "hold"), **({"choices": sorted(BY)} if f == "by" else {}))
        p.add_argument("--json", action="store_true")
    sub.choices["observe"].add_argument("--status", type=int)
    sub.choices["observe"].add_argument("--header", action="append", default=[])
    sub.choices["hold"].add_argument("command", nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    try:
        w = worker_env.reason()
        if w:
            raise Stop(sd.Refused.code, f"ledger.py {a.cmd} runs on the host only ({w}); nothing was done")
        return {"record": cmd_record, "status": cmd_status, "hold": cmd_hold, "observe": cmd_observe, "report": cmd_report, "check": cmd_check}[a.cmd](a)
    except Stop as x:
        s = x
    except el.EventError as e:   # no state change without its trusted line
        s = Stop(e.code, e.problem)
    except sd.DataError as e:
        s = Stop(getattr(e, "code", UNEXPECTED), str(e)[:180])
    except Exception as e:   # never a traceback, never the error's text (it could repeat a value): the type only
        s = Stop(UNEXPECTED, f"{type(e).__name__}, an unexpected failure of ledger.py {a.cmd}")
    print(json.dumps({"code": s.code, "problem": el.scrub(s.problem)}))
    el.say(s.code, s.problem, alert=s.alert)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
