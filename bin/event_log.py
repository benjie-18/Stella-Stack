#!/usr/bin/env python3
"""The one writer of the event log (core contract item 4, spec E6), stdlib only. The log path is data: `event_log` in
.stella/data-files.json. One line = one JSON object that validates against .stella/schemas/event.schema.json, appended
under a lock, never rewritten or truncated. Values of keys that match a `redact_keys` pattern of the index, and of settings
the registry marks `secret`, become *** before the line is validated, written or printed. A key written as a JSON pointer
("/a/b") is masked when any of its segments matches.
CLI: event_log.py append --type T --what W [--old JSON] [--new JSON] [--code C] [--detail D] [--role R] [--channel C] [--user U]
     event_log.py tail [--json] [-n N]       the last N lines (default 20), masked again on the way out
Exit: 0 ok; 1 refused (STL-CFG-313 invalid line, STL-CFG-318 log not writable; the catalog's plain message on stderr); 2 usage.
The stack root is the parent of this file's folder, or STELLA_ROOT (a scratch root in tests). Importers use build, append,
preflight, mask, redactor, path, locked and fail."""
import argparse, contextlib, fcntl, json, os, re, sys, time

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import alert_catalog
import stella_data as sd

OWN = os.path.realpath(os.path.dirname(BIN))
ROOT = os.path.realpath(sd.ROOT)
MASK = "***"

class EventError(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem

def path(rel):
    """Absolute path of a root-relative path from the index. Refused when it leaves the root (symlinks resolved), and, when
    STELLA_ROOT names another tree than this tool's own, when it lands inside this tool's own tree: pointing the tool at
    a parent folder of the real stack must not reach the real files."""
    p = os.path.realpath(os.path.join(ROOT, rel))
    if p != ROOT and not p.startswith(ROOT + os.sep):
        raise ValueError(f"{rel} is outside the stack root")
    if ROOT != OWN and (p == OWN or p.startswith(OWN + os.sep)):
        raise ValueError(f"{rel} is inside another stack tree")
    return p

@contextlib.contextmanager
def locked(p):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)

def fail(code, problem):
    """Print the catalog code and its plain message, log one alert line; the exit code to return."""
    body, tag, kv = alert_catalog.render(code, {"problem": problem})
    alert_catalog.log(tag, kv)
    print(f"{code} {body.split(chr(10))[1]}", file=sys.stderr)
    return 1

# ---- masking ----
def redactor(row_id=None):
    """key -> True when its value must be masked: a redact_keys pattern of the index row (every row when row_id is None),
    or the store key of a registry setting marked secret."""
    pats = [re.compile(p) for r in sd.rows() if row_id in (None, r["id"]) for p in r["redact_keys"]]
    secret = {k for e in sd.load(".stella/settings.json")["entries"] if e["sensitivity"] == "secret" for k in (e["key"], e["store"]["key"])}
    def red(k):
        segs = [s.replace("~1", "/").replace("~0", "~") for s in k.split("/")[1:]] if k.startswith("/") else [k]
        return any(s in secret or any(p.search(s) for p in pats) for s in segs)
    return red

def mask(v, red):
    if isinstance(v, dict):
        return {k: MASK if red(str(k)) else mask(x, red) for k, x in v.items()}
    return [mask(x, red) for x in v] if isinstance(v, list) else v

# ---- the log ----
def build(type, what, old=None, new=None, code=None, detail=None, who=None):
    line = {"schema_version": 1, "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "type": type,
            "who": {"role": None, "channel": None, "user": None, **(who or {})}, "what": what}
    for k, v in (("old", old), ("new", new), ("code", code), ("detail", detail)):
        if v is not None:
            line[k] = v
    return line

def log_path():
    return path(sd.load(sd.INDEX)["event_log"])

def preflight():
    """Raises EventError(318) when the log cannot be appended to now; creates an empty log if there is none."""
    try:
        os.close(os.open(log_path(), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600))
    except (OSError, ValueError) as e:
        raise EventError("STL-CFG-318", str(e))

def append(line, row_id=None):
    """Mask, validate, append one line under the lock; returns the line written. EventError 313 (invalid, nothing
    written) or 318 (not written). The write is one os.write on an O_APPEND descriptor."""
    try:
        line = mask(line, redactor(row_id))
        errs = sd.validate_doc(line, sd.load(f"{sd.SCHEMAS}/event.schema.json"))
    except Exception as e:
        raise EventError("STL-CFG-313", f"event line: {type(e).__name__}")
    errs += [f"{k} must not be empty" for k in ("type", "what") if line.get(k) == ""]   # the schema subset has no minLength here
    if errs:
        raise EventError("STL-CFG-313", "event line: " + "; ".join(errs)[:300])
    data = (json.dumps(line, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    try:
        p = log_path()
        with locked(p + ".lock"):
            fd = os.open(p, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            try:
                if os.write(fd, data) != len(data):
                    raise OSError("short write")
            finally:
                os.close(fd)
    except (OSError, ValueError) as e:
        raise EventError("STL-CFG-318", str(e))
    return line

def tail(n=20):
    """The last n lines as dicts, masked again. A line that is not JSON is skipped."""
    try:
        with open(log_path(), encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()[-n:] if n > 0 else []
    except FileNotFoundError:
        return []
    red, out = redactor(), []
    for s in lines:
        try:
            out.append(mask(json.loads(s), red))
        except ValueError:
            pass
    return out

def jarg(s):
    return json.loads(s)

def main(argv):
    ap = argparse.ArgumentParser(prog="event_log.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("append")
    a.add_argument("--type", required=True)
    a.add_argument("--what", required=True)
    a.add_argument("--old", type=jarg)
    a.add_argument("--new", type=jarg)
    a.add_argument("--code")
    a.add_argument("--detail")
    for w in ("role", "channel", "user"):
        a.add_argument("--" + w)
    t = sub.add_parser("tail")
    t.add_argument("--json", action="store_true")
    t.add_argument("-n", type=int, default=20)
    o = ap.parse_args(argv)
    try:
        if o.cmd == "append":
            who = {w: getattr(o, w) for w in ("role", "channel", "user") if getattr(o, w)}
            print(json.dumps(append(build(o.type, o.what, o.old, o.new, o.code, o.detail, who)), ensure_ascii=False))
        else:
            ls = tail(o.n)
            print(json.dumps(ls, indent=2, ensure_ascii=False) if o.json else "\n".join(
                f"{l.get('time')} {l.get('type')} {l.get('what')}" for l in ls))
    except EventError as e:
        return fail(e.code, e.problem)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
