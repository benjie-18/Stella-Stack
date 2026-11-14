#!/usr/bin/env python3
"""The agents' event stream (F1c B7, design D1), stdlib only. Appends one `"trusted": false` line to the file the index names
`untrusted_events`. Anyone may run it, a worker included: it is not an owner command, it holds no key and writes no chain, so a
line here is proof of nothing, and no reader of proof opens this file (bin/event_log.py proof_lines() reads the trusted log only).
It runs with the caller's own rights, so it guards the shape of the stream, not a privilege: one whole JSON line (ASCII only, checked
by the event schema, within the trusted writer's size and depth limits, which live here because this file may not import that one),
appended under a lock, never through a symbolic link, a FIFO or a second hard link, with its own global_id and this install's id.
Not masked: the line has no keyed values (no old/new), and the caller already holds whatever text it writes.
CLI: event_untrusted.py append --type T --what W [--source S] [--detail D]
Exit: 0 written; 1 refused (STL-CFG-310 no install id, STL-CFG-313 invalid line, STL-CFG-318 not writable); 2 usage."""
import argparse, fcntl, json, os, stat, sys, time, uuid

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import alert_catalog
import stella_data as sd

WRITE_DEPTH, WRITE_MAX = 16, 1 << 20   # nesting and bytes of a line, for both streams (event_log.py takes them from here)


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


class Refused(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def line_of(kind, what, source=None, detail=None):
    """(line, bytes): a valid untrusted line, or Refused."""
    try:
        iid = sd.install_id()
    except Exception as e:
        raise Refused("STL-CFG-310", f"the install id cannot be read ({type(e).__name__}); no event line was written")
    line = {"schema_version": 3, "trusted": False, "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "type": kind,
            "who": {"role": None, "channel": None, "user": None}, "what": what, "source": source,
            "global_id": str(uuid.uuid4()), "install_id": iid, **({"detail": detail} if detail is not None else {})}
    errs = [f"{k} must not be empty" for k in ("type", "what") if not line[k]]
    errs += sd.validate_doc(line, sd.load(f"{sd.SCHEMAS}/event.schema.json")) if depth(line) <= WRITE_DEPTH else ["nested too deeply"]
    if errs:
        raise Refused("STL-CFG-313", "untrusted event line: " + "; ".join(errs)[:180])
    data = (json.dumps(line, ensure_ascii=True, separators=(",", ":")) + "\n").encode()
    if len(data) > WRITE_MAX:
        raise Refused("STL-CFG-313", f"untrusted event line: larger than {WRITE_MAX} bytes")
    return line, data


def append(data):
    """Append the bytes whole under a lock, or not at all (a short or failed write is cut back)."""
    try:
        p = sd.plain(sd.load(sd.INDEX)["untrusted_events"])   # as spelled under the root, no link on the way
        os.makedirs(os.path.dirname(p), 0o700, exist_ok=True)
        fd = os.open(p, os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)   # read: the last byte (a fragment)
    except (OSError, sd.DataError, KeyError, TypeError) as e:
        raise Refused("STL-CFG-318", f"the untrusted event stream cannot be opened ({type(e).__name__})")
    size = None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            raise OSError("not a regular file with one link")
        fcntl.flock(fd, fcntl.LOCK_EX)
        size = os.fstat(fd).st_size
        if size and os.pread(fd, 1, size - 1) != b"\n":
            data = b"\n" + data   # a fragment from a killed writer: the new line starts on its own
        if os.write(fd, data) != len(data):
            raise OSError("short write")
        os.fsync(fd)
    except BaseException as e:
        if size is not None:
            try:
                os.ftruncate(fd, size)
            except OSError:
                pass
        if isinstance(e, OSError):
            raise Refused("STL-CFG-318", f"the untrusted event stream cannot be written ({e.strerror or e})")
        raise
    finally:
        os.close(fd)


def main(argv):
    ap = argparse.ArgumentParser(prog="event_untrusted.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("append")
    a.add_argument("--type", required=True)
    a.add_argument("--what", required=True)
    a.add_argument("--source")
    a.add_argument("--detail")
    o = ap.parse_args(argv)
    try:
        line, data = line_of(o.type, o.what, o.source, o.detail)
        append(data)
    except Refused as e:
        body = alert_catalog.render(e.code, {"problem": e.problem})[0]
        print(f"{e.code} {body.split(chr(10))[1]}", file=sys.stderr)   # no alert line: an agent's stream must not page the owner
        return 1
    except Exception as e:   # shortcut: one code for every surprise; a bug is told apart by the exception type
        print(f"STL-CFG-313 untrusted event line: unexpected {type(e).__name__}", file=sys.stderr)
        return 1
    print(json.dumps(line))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
