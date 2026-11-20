#!/usr/bin/env python3
"""Executors of an agent runtime's tool calls (X1 item A, ruling X1-DC-01), stdlib only. bin/agent_runtime.py runs one per offered call,
after its gates, as a child with the agent's own environment and box; this file runs worker side and writes no log.
  agent_tool.py read|write|edit|shell|capability   stdin: {tool_name, tool_input, cwd} (the judge payload, DC-02); stdout: one JSON line
                                                   {ok, output[, code][, exit]}
The tool's adapters.json agent_tools row must name this executor; its inputs map the values used (path, text, old, new, command,
query, id) to pointers into tool_input. Paths are checked again at open time: a path is opened (its folder for a write) and the real
path of the open file must lie inside the worktree (cwd) or the run's temporary folder; the last part is never followed when it is a
link (O_NOFOLLOW), so a link that leaves the worktree is refused, not followed. A read lists a folder or reads a regular file (at most
read_cap_bytes); a write makes the folders it needs inside; an edit replaces one exact occurrence; shell runs the command line with the
platform shell in cwd; capability runs bin/capabilities.py <operation> (in a worker environment it asks the capability server, which
knows the run from its token).
Exit: 0 the call ran (ok says whether it succeeded); 1 refused or failed (ok false, a catalog code STL-GRD-708, 710, 711); 2 usage."""
import json, os, stat, subprocess, sys, tempfile

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import stella_data as sd

FAILED, PATH, INPUT = "STL-GRD-708", "STL-GRD-710", "STL-GRD-711"   # literal: the alert lint finds each sender by its code


class Refused(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def adapters():
    row = next(r for r in sd.rows() if r["id"] == "adapters")
    return sd.checked(sd.load(row["path"]), row["path"], row["schema"])


def val(t, inp, k):
    import policy
    v = policy.get(inp, t["inputs"][k])
    if not isinstance(v, str):
        raise Refused(INPUT, f"the tool's {k} is not a text")
    return v


def inside(p, roots):
    return any(p == r or p.startswith(r.rstrip("/") + "/") for r in roots)


def real(fd):
    return os.readlink(f"/proc/self/fd/{fd}")


def checked(fd, raw, roots):
    if not inside(real(fd), roots):
        os.close(fd)
        raise Refused(PATH, f"{raw} leads outside the worktree (through a link)")
    return fd


def folder(cwd, raw, roots):
    """(an open fd of the folder of raw, the last part): the folder made when missing, after its real path is known to lie inside."""
    full = os.path.normpath(os.path.join(cwd, os.path.expanduser(raw)))
    par, name = os.path.split(full)
    if not name or name in (".", ".."):
        raise Refused(PATH, f"{raw} names no file")
    if not inside(os.path.realpath(par), roots):
        raise Refused(PATH, f"{raw} is outside the worktree")
    os.makedirs(par, exist_ok=True)
    return checked(os.open(par, os.O_RDONLY | os.O_DIRECTORY), raw, roots), name


def regular(fd, raw):
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise Refused(PATH, f"{raw} is not a regular file")
    return fd


def op_read(t, inp, cwd, roots, cap):
    raw = val(t, inp, "path")
    fd = checked(os.open(os.path.join(cwd, os.path.expanduser(raw)), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), raw, roots)
    if stat.S_ISDIR(os.fstat(fd).st_mode):
        try:
            return {"ok": True, "output": "\n".join(sorted(os.listdir(fd)))}
        finally:
            os.close(fd)
    with os.fdopen(regular(fd, raw), "rb") as f:
        return {"ok": True, "output": f.read(cap).decode("utf-8", "replace")}


def op_write(t, inp, cwd, roots, cap):
    raw, text = val(t, inp, "path"), val(t, inp, "text")
    d, name = folder(cwd, raw, roots)
    try:
        fd = regular(os.open(name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_NONBLOCK, 0o644, dir_fd=d), raw)
    finally:
        os.close(d)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    return {"ok": True, "output": f"wrote {len(text.encode())} bytes to {raw}"}


def op_edit(t, inp, cwd, roots, cap):
    raw, old, new = val(t, inp, "path"), val(t, inp, "old"), val(t, inp, "new")
    d, name = folder(cwd, raw, roots)
    try:
        fd = regular(os.open(name, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=d), raw)
    finally:
        os.close(d)
    with os.fdopen(fd, "r+", encoding="utf-8") as f:
        text = f.read()
        n = text.count(old) if old else 0
        if n != 1:
            return {"ok": False, "code": INPUT, "output": f"{INPUT} the text to replace occurs {n} times in {raw}, not once"}
        f.seek(0)
        f.write(text.replace(old, new))
        f.truncate()
    return {"ok": True, "output": f"edited {raw}"}


def op_shell(t, inp, cwd, roots, cap):
    r = subprocess.run(val(t, inp, "command"), shell=True, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return {"ok": r.returncode == 0, "exit": r.returncode, "output": r.stdout[-cap:].decode("utf-8", "replace")}


def op_capability(t, inp, cwd, roots, cap):
    args = val(t, inp, "query").split() if "query" in t["inputs"] else [val(t, inp, "id")]
    r = subprocess.run([sys.executable, "-I", os.path.join(BIN, "capabilities.py"), t["capability"], "--json", "--", *args], cwd=cwd,
                       stdin=subprocess.DEVNULL, capture_output=True)
    return {"ok": r.returncode == 0, "exit": r.returncode, "output": (r.stdout + r.stderr)[-cap:].decode("utf-8", "replace")}


OPS = {"read": op_read, "write": op_write, "edit": op_edit, "shell": op_shell, "capability": op_capability}


def main(argv):
    if len(argv) != 1 or argv[0] not in OPS:
        print("usage: agent_tool.py " + "|".join(OPS) + " < {tool_name, tool_input, cwd}", file=sys.stderr)
        return 2
    try:
        d = adapters()
        cap = d.get("read_cap_bytes", 1 << 20)
        pl = json.loads(sys.stdin.read(cap))
        if not (isinstance(pl, dict) and isinstance(pl.get("tool_name"), str) and isinstance(pl.get("tool_input"), dict) and isinstance(pl.get("cwd"), str)):
            raise Refused(INPUT, "the payload is not {tool_name, tool_input, cwd}")
        t = next((x for x in d.get("agent_tools", []) if x["name"] == pl["tool_name"]), None)
        if t is None or t["executor"] != argv[0]:
            raise Refused(INPUT, f"no agent tool {sd.idn(pl['tool_name'])[:80]} runs on the {argv[0]} executor")
        cwd = os.path.realpath(pl["cwd"])
        r = OPS[argv[0]](t, pl["tool_input"], cwd, [cwd, os.path.realpath(tempfile.gettempdir())], cap)
    except Refused as x:
        r = {"ok": False, "code": x.code, "output": f"{x.code} {x.problem}"}
    except Exception as x:   # an open refused with O_NOFOLLOW (ELOOP), a missing file, unreadable data: never a traceback
        r = {"ok": False, "code": FAILED, "output": f"{FAILED} the call failed ({type(x).__name__}: {getattr(x, 'strerror', None) or 'see the input'})"}
    print(json.dumps(r))
    return 0 if r["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
