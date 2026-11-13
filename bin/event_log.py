#!/usr/bin/env python3
"""The one writer of the event log (core contract item 4, spec E6), stdlib only. The log path is data: `event_log` in
.stella/data-files.json. One line = one JSON object that validates against .stella/schemas/event.schema.json (schema_version 2: every line written
gets a global_id, the caller's or a new UUID4, refused when a line of the log already has it, and this install's install_id from
stella_data.install_id(); when that cannot be read nothing is written, STL-CFG-310; lines from before are never rewritten), ASCII only
(non-ASCII is escaped, so no value can hold a line separator), appended whole or not at all under a lock: a log that does
not end in a newline gets one first, and after a failed or short write the file is cut back to the size it had. Existing
lines are never rewritten. Values of keys that match a `redact_keys` pattern of the index, and of settings the registry
marks `secret`, become *** before the line is validated, written or printed (a scalar old / new of a row that
has redact keys or stores a secret setting is masked whole). A key written as a JSON pointer ("/a/b") is masked when any of its
segments matches. The log path and its lock are refused (STL-CFG-318) when they are, or pass through, a symbolic link.
Limits (not fixable here): `who` is what the caller says, the OS user name for the apply tool; any caller that can run
this tool can append a line of any type; keeping roles from writing the file directly is the job of the hooks' path rules.
CLI: event_log.py append --type T --what W [--old JSON] [--new JSON] [--code C] [--detail D] [--role R] [--channel C] [--user U]
     event_log.py tail [--json] [-n N]       the last N lines (default 20), masked again on the way out; lines that are not
                                             event objects are counted and reported on stderr (one STL-CFG-318 line)
Exit: 0 ok; 1 refused (STL-CFG-313 invalid line, STL-CFG-318 log not writable; the catalog's plain message on stderr); 2 usage.
The stack root is the parent of this file's folder, or STELLA_ROOT (a scratch root in tests). Importers use build, prepare,
append, preflight, mask, redactor, scrub, SECRETS, note_secrets, depth, read_log, path, locked, open_file, open_dir, mkdirs,
say and fail. A file opened for writing (the log, a lock) must have one hard link; every line written is synced.
Limits of a line (one rule for the writer and the reader, the reader's with a margin): the writer refuses nesting beyond
WRITE_DEPTH or a line beyond WRITE_MAX bytes (313); the reader counts a line beyond READ_DEPTH / READ_MAX, or one it cannot
parse, mask or print for any reason, as unreadable (reported, 318) and goes on. Every file opened (log, lock) must be a regular
file, opened without blocking, through a folder checked at the moment of the open: a FIFO is refused (318), never waited for."""
import argparse, contextlib, fcntl, json, os, re, stat, sys, time, uuid

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import alert_catalog
import stella_data as sd

OWN = os.path.realpath(os.path.dirname(BIN))
ROOT = os.path.realpath(sd.ROOT)
MASK = "***"
MAX_FILE = 8 << 20   # shortcut: a data, state or backup file larger than this is refused, not read; the limit is in code, upgrade when the index carries one
WRITE_DEPTH, READ_DEPTH = 16, 64   # nesting of a line: the writer's limit is far below the reader's, so a written line always reads back
WRITE_MAX, READ_MAX = 1 << 20, 4 << 20   # bytes of a line, same idea

class EventError(Exception):
    def __init__(self, code, problem, extra=None):
        super().__init__(problem)
        self.code, self.problem, self.extra = code, problem, extra or {}   # extra: more placeholders of the catalog row

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

def open_dir(d):
    """An open folder that is d itself: no link on its last part, and the path the kernel gives the descriptor is d (a parent
    swapped for a link after the path was checked is refused here; later steps work relative to this descriptor)."""
    fd = os.open(d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:   # the same name (up to case only where no folder on the way is a link: the stack's disk ignores case) and the same folder
        real, parts = os.readlink(f"/proc/self/fd/{fd}"), d.split(os.sep)
        if (real != d and (real.casefold() != d.casefold() or any(os.path.islink(os.sep.join(parts[:i])) for i in range(2, len(parts) + 1)))) \
                or not os.path.samestat(os.fstat(fd), os.lstat(d)):
            raise ValueError("a folder on the way is not where the index puts it")
    except BaseException:
        os.close(fd)
        raise
    return fd

def open_file(p, flags, mode=0o600):
    """An open regular file, never through a link and never blocking (a FIFO or device is refused, not waited for)."""
    d, name = os.path.split(p)
    dfd = open_dir(d)
    try:
        fd = os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, mode, dir_fd=dfd)
    finally:
        os.close(dfd)
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or (flags & (os.O_WRONLY | os.O_RDWR) and st.st_nlink > 1):
        os.close(fd)
        raise ValueError("is not a regular file" if not stat.S_ISREG(st.st_mode) else "has more than one hard link (it may be another file)")
    return fd

def mkdirs(p, base=None):
    """p and the folders on the way below base (the stack root), each made 0700 through its parent opened and checked by
    open_dir: a parent swapped for a link is refused, nothing is made outside base."""
    base = base or ROOT
    rel = os.path.relpath(p, base)
    if rel == ".":
        return
    if rel == ".." or rel.startswith(".." + os.sep):
        raise ValueError("a folder to make is outside the stack root")
    d = base
    for part in rel.split(os.sep):
        fd = open_dir(d)
        try:
            os.mkdir(part, 0o700, dir_fd=fd)
        except FileExistsError:
            pass
        finally:
            os.close(fd)
        d = os.path.join(d, part)
    os.close(open_dir(d))

@contextlib.contextmanager
def locked(p):
    """flock on p. After the lock is taken the file at the path must still be the file that was locked (it can be replaced while
    a run waits): else the run locks again, a few times, then refuses. A lock that was taken is released on every path: the
    descriptor belongs to a file object from before the flock, closed by the one `finally`, and by the object's own end when an
    interrupt lands anywhere else (between the flock and the guarded block, or inside the `finally`)."""
    if not os.path.isdir(os.path.dirname(p)):
        mkdirs(os.path.dirname(p))
    f = None
    try:
        for _ in range(5):
            f = os.fdopen(open_file(p, os.O_RDWR | os.O_CREAT), "rb+", buffering=0)
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                same = os.path.samestat(os.fstat(f.fileno()), os.lstat(p))
            except FileNotFoundError:
                same = False
            if same:
                break
            f.close()
        else:
            raise OSError("the lock file keeps being replaced")
        yield
    finally:
        if f is not None:
            f.close()

SECRETS = set()   # values seen under masked keys; scrub() removes them from any text

def scrub(text):
    """Each value seen under a masked key, where it stands as a whole value (not inside a longer run of letters and digits), is
    ***: the tool's own text (a folder name, a code, a command) is never garbled by a short value like 1 or on."""
    for x in sorted(SECRETS, key=len, reverse=True):
        if x:   # an empty value would match between every two characters
            text = re.sub(r"(?<![A-Za-z0-9])" + re.escape(x) + r"(?![A-Za-z0-9])", MASK, text)
    return text

def depth(v):
    """The nesting of a value, counted without recursion (the input's depth must not decide the stack)."""
    todo, d = [(v, 1)], 0
    while todo:
        x, n = todo.pop()
        d = max(d, n)
        if isinstance(x, dict):
            todo += [(y, n + 1) for y in x.values()]
        elif isinstance(x, list):
            todo += [(y, n + 1) for y in x]
    return d

def say(code, problem, alert=False, extra=None):
    """The catalog code and its plain message on stderr (the problem text and extra values scrubbed); with alert=True one alert
    line too."""
    body, tag, kv = alert_catalog.render(code, {"problem": scrub(problem), **{k: scrub(str(v)) for k, v in (extra or {}).items()}})
    if alert:
        alert_catalog.log(tag, kv)
    print(f"{code} {body.split(chr(10))[1]}", file=sys.stderr)

def fail(code, problem, extra=None):
    """Print the catalog code and its plain message, log one alert line; the exit code to return."""
    say(code, problem, alert=True, extra=extra)
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
    or the key / store key of a registry setting whose sensitivity is secret (identity_critical values are shown)."""
    pats = [re.compile(p) for r in sd.rows() if row_id in (None, r["id"]) for p in r["redact_keys"]]
    secret = {k for e in registry()["entries"] if e["sensitivity"] == "secret" for k in (e["key"], e["store"]["key"])}
    def red(k):
        segs = [s.replace("~1", "/").replace("~0", "~") for s in k.split("/")[1:]] if k.startswith("/") else [k]
        return any(s in secret or any(p.search(s) for p in pats) for s in segs)
    return red

def leaves(v):
    todo = [v]
    while todo:
        x = todo.pop()
        if isinstance(x, dict):
            todo += list(x.values())
        elif isinstance(x, list):
            todo += x
        elif x is not None:
            yield x

def note_secrets(doc, red):
    """Remember the values found under masked keys, so scrub() removes them from any text of the same call."""
    todo = [doc]
    while todo:
        x = todo.pop()
        if isinstance(x, dict):
            for k, v in x.items():
                if red(str(k)):
                    SECRETS.update(str(y) for y in leaves(v))
                else:
                    todo.append(v)
        elif isinstance(x, list):
            todo += x

def mask(v, red):
    if isinstance(v, dict):
        return {k: MASK if red(str(k)) else mask(x, red) for k, x in v.items()}
    return [mask(x, red) for x in v] if isinstance(v, list) else v

# ---- the log ----
def build(type, what, old=None, new=None, code=None, detail=None, who=None):
    line = {"schema_version": 2, "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "type": type,
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
    """Raises EventError(318) when the log cannot be appended to now. It makes nothing: an existing log is opened for appending, a
    missing one needs its nearest existing folder writable (append makes the folder and the log)."""
    try:
        p = log_path()
        if os.path.lexists(p):
            os.close(open_file(p, os.O_WRONLY | os.O_APPEND))
        else:
            d = os.path.dirname(p)
            while not os.path.isdir(d):
                d = os.path.dirname(d)
            if not os.access(d, os.W_OK | os.X_OK):
                raise PermissionError(13, "Permission denied")
    except (OSError, ValueError) as e:
        raise EventError("STL-CFG-318", why(e))

def sensitive_row(line, row_id):
    """The index row a line is about (row_id, else the first part of `what`) when masking could apply to it: it has redact keys
    or stores a secret setting."""
    rid = row_id or str(line.get("what", "")).partition("/")[0]
    secret_rows = {e["store"]["data"] for e in registry()["entries"] if e["sensitivity"] == "secret"}
    return next((r for r in sd.rows() if r["id"] == rid and (r["redact_keys"] or rid in secret_rows)), None)

def prepare(line, row_id=None, scrub_detail=True):
    """(the line as written, its bytes): masked and validated, or EventError 313. A caller judges a line with this before it
    changes anything; append() does the same again when it writes.
    scrub_detail=False: the caller's detail is the tool's own text (no outside value in it), which a scrub by substring could garble.
    The ids are set after masking (they are not secrets): the caller's global_id or a new one, and always this install's id."""
    try:
        iid = sd.install_id()   # no line without the install id
    except Exception as e:
        raise EventError("STL-CFG-310", f"the install id cannot be read ({str(e)[:100] if isinstance(e, sd.DataError) else type(e).__name__}); no event line was written")
    gid = line["global_id"] if "global_id" in line else str(uuid.uuid4())
    try:
        if depth(line) > WRITE_DEPTH:
            raise ValueError("nested too deeply")
        sens, red = sensitive_row(line, row_id), redactor(row_id)
        for k in ("old", "new"):
            note_secrets(line.get(k), red)   # the values masked in this line are scrubbed from its detail too
            if sens and line.get(k) is not None and not isinstance(line[k], (dict, list)):
                SECRETS.add(str(line[k]))
        line = {**mask(line, red), "schema_version": 2, "global_id": gid, "install_id": iid}
        for k in ("old", "new"):
            if sens and k in line and line[k] is not None and not isinstance(line[k], (dict, list)):
                line[k] = MASK   # a scalar has no key to match: for such a row it is masked whole
        if scrub_detail and isinstance(line.get("detail"), str):
            line["detail"] = scrub(line["detail"])
        errs = sd.validate_doc(line, sd.load(f"{sd.SCHEMAS}/event.schema.json"))
        if "code" in line and line["code"] not in alert_catalog.catalog():
            errs.append(f"code {line['code']} is not in the alert catalog")
    except Exception as e:
        raise EventError("STL-CFG-313", f"event line: {type(e).__name__}" + (" (nested too deeply)" if depth(line) > WRITE_DEPTH else ""))
    errs += [f"{k} must not be empty" for k in ("type", "what") if line.get(k) == ""]   # the schema subset has no minLength here
    if errs:
        raise EventError("STL-CFG-313", "event line: " + "; ".join(errs)[:180])
    data = (json.dumps(line, ensure_ascii=True, separators=(",", ":")) + "\n").encode()
    if len(data) > WRITE_MAX:
        raise EventError("STL-CFG-313", f"event line: larger than {WRITE_MAX} bytes")
    return line, data

def repeated(data, gid):
    """True when a line of the log (bytes) already has this global_id; a line no reader can read has none."""
    for s in data.split(b"\n"):
        if gid.encode() in s and len(s) <= READ_MAX:
            with contextlib.suppress(Exception):
                if json.loads(s)["global_id"] == gid:
                    return True
    return False

def append(line, row_id=None, scrub_detail=True):
    """Mask, validate, append one line under the lock and sync it; returns the line written. EventError 313 (invalid, nothing
    written, also for a global_id already in the log) or 318 (not written). The line goes out in one write; if that fails or is
short, the file is cut back."""
    line, data = prepare(line, row_id, scrub_detail)
    try:
        p = log_path()
        with locked(p + ".lock"):
            made = not os.path.lexists(p)   # a log this append makes and then cannot write a line to is removed again
            fd = size = None
            try:
                fd = open_file(p, os.O_RDWR | os.O_APPEND | os.O_CREAT)
                size = os.fstat(fd).st_size
                # shortcut: the whole log is read on every append to find a repeated global_id; keep an id index when the log grows large
                if size and repeated(os.pread(fd, size, 0), line["global_id"]):
                    raise EventError("STL-CFG-313", "event line: its global_id is already in the log; nothing was written")
                if size and os.pread(fd, 1, size - 1) != b"\n":
                    data = b"\n" + data   # a fragment from a killed writer: the new line starts on its own
                if os.write(fd, data) != len(data):
                    raise OSError("short write")
                os.fsync(fd)   # a line is as durable as the state it reports
            except BaseException:   # whatever stops it after the create (a failure, an interrupt): whole or not at all
                with contextlib.suppress(OSError):
                    if made:   # the lock is held: no other line can be in a log this call made
                        os.unlink(p)
                    elif size is not None:
                        os.ftruncate(fd, size)
                raise
            finally:
                if fd is not None:
                    os.close(fd)
    except (OSError, ValueError) as e:
        raise EventError("STL-CFG-318", why(e))
    return line

def read_log(n=None):
    """([events], bad): the last n lines (all when None), split on \\n only, masked again; bad = lines that are not a JSON object,
    are larger or nested deeper than the writer's limits allow for, or cannot be masked (any exception): one unreadable line
    never stops a reader."""
    try:
        with os.fdopen(open_file(log_path(), os.O_RDONLY), "rb") as f:
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
            d = json.loads(s.decode("utf-8", "replace")) if len(s) <= READ_MAX else None
            if isinstance(d, dict) and depth(d) <= READ_DEPTH:
                out.append(mask(d, red))
                continue
        except Exception:   # RecursionError, MemoryError, a pattern error: this line only
            pass
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
        if o.cmd == "append":   # B.1 (r5, W4-CRT3-01): the owner's command refuses itself in a worker's environment (a marker of the role table's worker_markers)
            try:
                marks = sd.load(sd.load(sd.INDEX)["role_table"])["worker_markers"]
                assert isinstance(marks, list) and marks and all(isinstance(m, str) and m for m in marks)
            except Exception:
                return fail("STL-CFG-312", "the list of worker markers is not available, so it cannot be told that this is not a worker; nothing was appended")
            if any(os.environ.get(m) for m in marks):
                return fail("STL-CFG-312", "a worker marker is set: the event log is appended by the owner's tools only; nothing was appended")
            who = {w: getattr(o, w) for w in ("role", "channel", "user") if getattr(o, w)}
            print(json.dumps(append(build(o.type, o.what, o.old, o.new, o.code, o.detail, who)), ensure_ascii=False))
        else:
            ls, bad = read_log(o.n)
            esc = lambda x: json.dumps(str(x))[1:-1]   # a field cannot start a line of its own
            print(json.dumps(ls, indent=2, ensure_ascii=False) if o.json else "\n".join(
                f"{esc(l.get('time'))} {esc(l.get('type'))} {esc(l.get('what'))}" for l in ls))
            if bad:
                say("STL-CFG-318", f"{bad} line(s) of the event log are not event lines")
    except EventError as e:
        return fail(e.code, e.problem)
    except Exception as e:   # shortcut: one code for every surprise; a bug is told apart by the exception type in the line
        return fail("STL-CFG-313" if o.cmd == "append" else "STL-CFG-322", f"unexpected {type(e).__name__}")   # tail changes nothing
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
