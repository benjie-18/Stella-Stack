#!/usr/bin/env python3
"""Executors of an agent runtime's tool calls (X1 item A, ruling X1-DC-01), stdlib only. bin/agent_runtime.py runs one per offered call,
after its gates, as a child with the agent's own environment and box; this file runs worker side and writes no log.
  agent_tool.py read|write|edit|shell|capability   stdin: {tool_name, tool_input, cwd} (the judge payload, DC-02); stdout: one JSON line
                                                   {ok, output[, code][, exit]}
The tool's adapters.json agent_tools row must name this executor; its inputs map the values used (path, text, old, new, command,
query, id) to pointers into tool_input. Paths are checked again at open time: a path is opened (its folder for a write) and the real
path of the open file must lie inside the worktree (cwd) or the run's temporary folder; the last part is never followed when it is a
link (O_NOFOLLOW), so a link that leaves the worktree is refused, not followed. A read lists a folder or reads a regular file (at most
read_cap_bytes); a write makes the folders it needs inside and, like an edit (one exact occurrence), refuses a file with a second name
(a hard link); shell runs the command line with the platform shell in cwd, a shim of every guarded command name first on PATH that
judges the real argv and environment by the commit and dispatcher rules before the real program runs (STL-GRD-709); capability runs bin/capabilities.py <operation> (in a worker environment it asks the capability server, which
knows the run from its token).
Exit: 0 the call ran (ok says whether it succeeded); 1 refused or failed (ok false, a catalog code STL-GRD-708..711); 2 usage."""
import json, os, stat, subprocess, sys, tempfile

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import stella_data as sd

FAILED, WORDS, PATH, INPUT = "STL-GRD-708", "STL-GRD-709", "STL-GRD-710", "STL-GRD-711"   # literal: the alert lint finds each sender by its code


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


def regular(fd, raw, one=False):
    """fd when it is a regular file (one: and it has one name only: a hard link may be a file outside the worktree, A-CRT-05)."""
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or (one and st.st_nlink > 1):
        os.close(fd)
        raise Refused(PATH, f"{raw} is not a regular file" if not stat.S_ISREG(st.st_mode) else f"{raw} has another name (a hard link): it is not written")
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
        fd = regular(os.open(name, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o644, dir_fd=d), raw, one=True)
    finally:
        os.close(d)
    os.ftruncate(fd, 0)   # only after the checks: a refused target is never emptied
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    return {"ok": True, "output": f"wrote {len(text.encode())} bytes to {raw}"}


def op_edit(t, inp, cwd, roots, cap):
    raw, old, new = val(t, inp, "path"), val(t, inp, "old"), val(t, inp, "new")
    d, name = folder(cwd, raw, roots)
    try:
        fd = regular(os.open(name, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=d), raw, one=True)
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


SHIM = """#!{exe} -I
import sys
sys.path.insert(0, {bin!r})
import agent_tool
sys.exit(agent_tool.shim({name!r}, {rules!r}, {dir!r}))
"""


def shim(name, rules, here):
    """A guarded command as the shell really runs it (A-CRT-02): its real argv and environment judged by the commit and dispatcher
    rules (the rules baked in when the shim was made, so nothing the command sets can change them), then the real program, found on
    PATH without the shim folder, run in its place."""
    import policy, shutil
    argv = [name] + sys.argv[1:]
    why = policy.agent_shell_refusal(json.loads(rules), argv, os.environ)
    if why:
        print(f"{WORDS} {why}", file=sys.stderr)
        return 126
    path = os.pathsep.join(x for x in os.environ.get("PATH", "").split(os.pathsep) if x and os.path.realpath(x) != os.path.realpath(here))
    real = shutil.which(name, path=path)
    if not real:
        print(f"{name}: not found", file=sys.stderr)
        return 127
    os.execv(real, argv)


def op_shell(t, inp, cwd, roots, cap):
    """The command line with the platform shell, a shim of every guarded command name first on PATH (A-CRT-02). shortcut: a command that
    reaches the real program by a computed absolute path, a PATH of its own or another interpreter is not seen here; the OS box (E1) is
    the boundary for that."""
    import policy, roles, shutil
    cmd = val(t, inp, "command")
    try:
        var = (adapters().get("run_env") or {}).get("adapter")
        rules = policy.agent_shell_rules(roles.adapters()[os.environ[var]], cwd)
    except Exception as x:   # fail closed: no rules, no shell
        raise Refused(WORDS, f"the commit and dispatcher rules of this run cannot be read ({type(x).__name__})") from None
    here = tempfile.mkdtemp(prefix="shim-")
    try:
        for n in sorted(set(rules["git_names"]) | {c[0] for c in rules["commands"]}):
            if not n or os.sep in n or n in (".", ".."):
                raise Refused(WORDS, f"a guarded command name is not a plain name: {n!r}")
            f = os.path.join(here, n)
            with open(f, "x", encoding="utf-8") as h:
                h.write(SHIM.format(exe=sys.executable, bin=BIN, name=n, rules=json.dumps(rules), dir=here))
            os.chmod(f, 0o555)
        env = dict(os.environ, PATH=here + os.pathsep + os.environ.get("PATH", ""))
        r = subprocess.run(cmd, shell=True, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    finally:
        shutil.rmtree(here, ignore_errors=True)
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
