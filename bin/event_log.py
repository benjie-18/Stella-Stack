#!/usr/bin/env python3
"""The one writer of the event log (core contract item 4, spec E6), stdlib only. The log path is data: `event_log` in
.stella/data-files.json. One line = one JSON object that validates against .stella/schemas/event.schema.json, ASCII only
(non-ASCII is escaped, so no value can hold a line separator), appended whole or not at all under a lock: a log that does
not end in a newline gets one first, and after a failed or short write the file is cut back to the size it had. Existing
lines are never rewritten. Values of keys that match a `redact_keys` pattern of the index, and of settings the registry
marks anything but `plain`, become *** before the line is validated, written or printed (a scalar old / new of a row that
is owner-only or has redact keys is masked whole). A key written as a JSON pointer ("/a/b") is masked when any of its
segments matches. The log path and its lock are refused (STL-CFG-318) when they are, or pass through, a symbolic link.
Limits (not fixable here): `who` is what the caller says, the OS user name for the apply tool; any caller that can run
this tool can append a line of any type; keeping roles from writing the file directly is the job of the hooks' path rules.
CLI: event_log.py append --type T --what W [--old JSON] [--new JSON] [--code C] [--detail D] [--role R] [--channel C] [--user U]
     event_log.py tail [--json] [-n N]       the last N lines (default 20), masked again on the way out; lines that are not
                                             event objects are counted and reported on stderr (one STL-CFG-318 line)
Exit: 0 ok; 1 refused (STL-CFG-313 invalid line, STL-CFG-318 log not writable; the catalog's plain message on stderr); 2 usage.
The stack root is the parent of this file's folder, or STELLA_ROOT (a scratch root in tests). Importers use build, append,
preflight, mask, redactor, scrub, SECRETS, read_log, path, locked, say and fail."""
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
    if not isinstance(rel, str) or ".." in rel.replace("\\", "/").split("/"):
        raise ValueError(f"{rel}: a path in the data must have no .. part")
    lex = os.path.normpath(os.path.join(ROOT, rel))
    p = os.path.realpath(lex)
    within = lambda d: p == d or p.startswith(d.rstrip(os.sep) + os.sep)   # rstrip: the root may be "/"
    if not within(ROOT):
        raise ValueError(f"{rel} is outside the stack root")
    if ROOT != OWN and within(OWN):
        raise ValueError(f"{rel} is inside another stack tree")
    if p != lex:   # a symbolic link on the way (a folder or the file itself) or a path that resolves elsewhere
        raise ValueError(f"{rel} is, or passes through, a symbolic link")
    return p

@contextlib.contextmanager
def locked(p):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    fd = os.open(p, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)

SECRETS = set()   # values seen under masked keys; scrub() removes them from any text

def scrub(text):
    for x in sorted(SECRETS, key=len, reverse=True):
        if x:   # an empty value would match between every two characters
            text = text.replace(x, MASK)
    return text

def say(code, problem, alert=False):
    """The catalog code and its plain message on stderr (the problem text scrubbed); with alert=True one alert line too."""
    body, tag, kv = alert_catalog.render(code, {"problem": scrub(problem)})
    if alert:
        alert_catalog.log(tag, kv)
    print(f"{code} {body.split(chr(10))[1]}", file=sys.stderr)

def fail(code, problem):
    """Print the catalog code and its plain message, log one alert line; the exit code to return."""
    say(code, problem, alert=True)
    return 1

# ---- masking ----
def registry():
    """The settings registry, found through the index row whose schema is the settings schema."""
    row = next((r for r in sd.rows() if r["schema"] == "settings"), None)
    if row is None:
        raise sd.DataError("the index has no settings registry row")
    return sd.load(row["path"])

def redactor(row_id=None):
    """key -> True when its value must be masked: a redact_keys pattern of the index row (every row when row_id is None),
    or the key / store key of a registry setting whose sensitivity is not plain."""
    pats = [re.compile(p) for r in sd.rows() if row_id in (None, r["id"]) for p in r["redact_keys"]]
    secret = {k for e in registry()["entries"] if e["sensitivity"] != "plain" for k in (e["key"], e["store"]["key"])}
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

LOG_REL = None   # the index's event_log value, read once per process

def log_path():
    global LOG_REL
    if LOG_REL is None:
        LOG_REL = sd.load(sd.INDEX)["event_log"]
    return path(LOG_REL)

def why(e):
    return e.strerror or type(e).__name__ if isinstance(e, OSError) else str(e)   # never the path an OSError carries

def preflight():
    """Raises EventError(318) when the log cannot be appended to now; creates the log folder and an empty log if there are none."""
    try:
        p = log_path()
        os.makedirs(os.path.dirname(p), mode=0o700, exist_ok=True)
        os.close(os.open(p, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600))
    except (OSError, ValueError) as e:
        raise EventError("STL-CFG-318", why(e))

def sensitive_row(line, row_id):
    """The index row a line is about (row_id, else the first part of `what`) when it is owner-only or has redact keys."""
    rid = row_id or str(line.get("what", "")).partition("/")[0]
    return next((r for r in sd.rows() if r["id"] == rid and (r["owner_only"] or r["redact_keys"])), None)

def append(line, row_id=None):
    """Mask, validate, append one line under the lock; returns the line written. EventError 313 (invalid, nothing
    written) or 318 (not written). The line goes out in one write; if that fails or is short, the file is cut back."""
    try:
        sens = sensitive_row(line, row_id)
        line = mask(line, redactor(row_id))
        for k in ("old", "new"):
            if sens and k in line and line[k] is not None and not isinstance(line[k], (dict, list)):
                line[k] = MASK   # a scalar has no key to match: for such a row it is masked whole
        if isinstance(line.get("detail"), str):
            line["detail"] = scrub(line["detail"])
        errs = sd.validate_doc(line, sd.load(f"{sd.SCHEMAS}/event.schema.json"))
        if "code" in line and line["code"] not in alert_catalog.catalog():
            errs.append(f"code {line['code']} is not in the alert catalog")
    except Exception as e:
        raise EventError("STL-CFG-313", f"event line: {type(e).__name__}")
    errs += [f"{k} must not be empty" for k in ("type", "what") if line.get(k) == ""]   # the schema subset has no minLength here
    if errs:
        raise EventError("STL-CFG-313", "event line: " + "; ".join(errs)[:300])
    data = (json.dumps(line, ensure_ascii=True, separators=(",", ":")) + "\n").encode()
    try:
        p = log_path()
        with locked(p + ".lock"):
            fd = os.open(p, os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            try:
                size = os.fstat(fd).st_size
                if size and os.pread(fd, 1, size - 1) != b"\n":
                    data = b"\n" + data   # a fragment from a killed writer: the new line starts on its own
                try:
                    if os.write(fd, data) != len(data):
                        raise OSError("short write")
                except BaseException:
                    try:
                        os.ftruncate(fd, size)   # whole or not at all
                    except OSError:
                        pass
                    raise
            finally:
                os.close(fd)
    except (OSError, ValueError) as e:
        raise EventError("STL-CFG-318", why(e))
    return line

def read_log(n=None):
    """([events], bad): the last n lines (all when None), split on \\n only, masked again; bad = lines that are not a JSON object."""
    try:
        fd = os.open(log_path(), os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as f:
            lines = f.read().split(b"\n")
    except FileNotFoundError:
        return [], 0
    except (OSError, ValueError) as e:
        raise EventError("STL-CFG-318", why(e))
    if lines[-1] == b"":
        lines.pop()
    if n is not None:
        lines = lines[-n:] if n > 0 else []
    red, out, bad = redactor(), [], 0
    for s in lines:
        try:
            d = json.loads(s.decode("utf-8", "replace"))
        except (ValueError, RecursionError):
            d = None
        if isinstance(d, dict):
            out.append(mask(d, red))
        else:
            bad += 1
    return out, bad

def tail(n=20):
    """The last n event lines as dicts (see read_log for the lines that are not events)."""
    return read_log(n)[0]

def jarg(s):
    try:
        return json.loads(s)
    except (ValueError, RecursionError):
        raise argparse.ArgumentTypeError("not JSON")   # never the argument itself

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
            ls, bad = read_log(o.n)
            print(json.dumps(ls, indent=2, ensure_ascii=False) if o.json else "\n".join(
                f"{l.get('time')} {l.get('type')} {json.dumps(str(l.get('what')))[1:-1]}" for l in ls))
            if bad:
                say("STL-CFG-318", f"{bad} line(s) of the event log are not event lines")
    except EventError as e:
        return fail(e.code, e.problem)
    except Exception as e:   # shortcut: one code for every surprise; a bug is told apart by the exception type in the line
        return fail("STL-CFG-313", f"unexpected {type(e).__name__}")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
