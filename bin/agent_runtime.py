#!/usr/bin/env python3
"""Agent-runtime adapter kind (X1 item A; body B1, AC1, AC2, AC5; design section A with rulings X1-DC-01..06), stdlib only.
An adapters.json entry of kind agent-runtime is an agent built on any framework, spoken to through a protocol of
.stella/agent-protocols.json (AG-UI first; a second protocol is a data entry). bin/adapter.py start keeps every step of a run (status,
binary, version, worktree, the resolver's link, conformance gate, run token, ledger lease, box, worker markers, record) and, for this
kind, calls loop() instead of reading a CLI's stdout. The loop (engine side, in the run's supervisor, the only writer of its stream):
  1 the agent binds a loopback port itself and prints one ready line (the protocol's ready pointer names the port); the listening socket
    must belong to the agent's process tree and a loopback address (/proc), else the run stops (DC-06);
  2 each turn POSTs the run input (the rendered prompt as the user message, the offered tools, the messages so far, the model) and
    reads the event stream; messages and state become message / state records of the run stream (redacted, capped) and one trusted
    adapter.agent-message / adapter.agent-state line each; a custom event whose name is a UI name goes to bin/agui_ui.py ingest
    (only when that module is there; otherwise nothing is recorded for it);
  3 each completed tool call is a tool_use record; a tool that was not offered stops the run (an agent-side tool cannot be gated);
    an offered one passes gates() and then runs as a child bin/agent_tool.py <executor> with the agent's own environment and box
    (DC-01); its answer is a tool_result record and a tool message for the next turn;
  4 the turn's end with no pending call ends the run (outcome 0); an agent error, an agent-side tool result, max_turns or a broken
    stream stop it with a catalog code, whose number is the record's exit (DC-05).
Offered tools: the adapters.json agent_tools rows whose toolset the role's platform toolsets hold (a row with no toolset: any role),
capability rows only when the role's run policy core_tools name them.
CLI: agent_runtime.py check [--json]   the protocols data, the agent_tools rows (executor matches class, DC-02) and every agent-runtime
                                       entry (protocol, tool map, policy {hook: {kinds}} with no target, DC-03/04); exit 1 with STL-GRD-700
Exit: 0 ok; 1 a problem (catalog code and plain message); 2 usage. Codes STL-GRD-700..711."""
import os, sys

if __name__ == "__main__" and not sys.flags.isolated:   # run directly: PYTHONPATH and the current folder must not decide what is imported
    try:
        os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
    except OSError:
        sys.exit("STL-CFG-310 agent_runtime.py could not restart itself isolated (python3 -I)")

import argparse, contextlib, hashlib, http.client, ipaddress, json, re, select, signal, subprocess, threading, time, uuid

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import event_log as el
import policy
import stella_data as sd

AGENT = policy.AGENT
C = {"data": "STL-GRD-700", "ready": "STL-GRD-701", "socket": "STL-GRD-702", "unoffered": "STL-GRD-703", "agent_tool": "STL-GRD-704",
     "turns": "STL-GRD-705", "stream": "STL-GRD-706", "agent_error": "STL-GRD-707", "executor": "STL-GRD-708", "words": "STL-GRD-709",
     "path": "STL-GRD-710", "input": "STL-GRD-711"}   # literal: the alert lint finds each sender by its code
ROW, ADAPTERS = "agent-protocols", "adapters"
GIT_VALUE = ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env")   # git words before the subcommand that take a value
LOCK = threading.Lock()   # the run log: the agent's own output (a thread) and the loop's records


class Stop(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def doc(rid):
    row = next((r for r in sd.rows() if r["id"] == rid), None)
    if row is None:
        raise Stop(C["data"], f"the index has no {rid} row")
    try:
        return sd.checked(sd.load(row["path"]), row["path"], row["schema"])
    except sd.DataError as e:
        raise Stop(C["data"], f"{row['path']} cannot be used: {str(e)[:160]}") from None


def protocol(e, protos=None):
    p = next((x for x in (protos or doc(ROW))["entries"] if x["id"] == e.get("protocol")), None)
    if p is None:
        raise Stop(C["data"], f"adapter {e['id']}: its protocol {sd.idn(str(e.get('protocol')))} is not in the agent protocols data")
    return p


def fill(t, v):
    """A template with {name} filled from v in one pass: a string that is exactly one placeholder takes the typed value."""
    if isinstance(t, str):
        m = re.fullmatch(r"\{(\w+)\}", t)
        return v[m[1]] if m and m[1] in v else re.sub(r"\{(\w+)\}", lambda m: str(v[m[1]]) if m[1] in v else m[0], t)
    if isinstance(t, list):
        return [fill(x, v) for x in t]
    return {k: fill(x, v) for k, x in t.items()} if isinstance(t, dict) else t


# ---- the check (DC-02, DC-03, DC-04): the policy tool's rules for this kind, and each entry's protocol ----
def problems():
    try:
        d, protos = doc(ADAPTERS), doc(ROW)
    except Stop as x:
        return [(x.code, x.problem)]
    out = policy.agent_tool_problems(d)
    for e in (x for x in d["entries"] if x.get("kind") == AGENT):
        out += policy.agent_problems(e, d)
        try:
            protocol(e, protos)
        except Stop as x:
            out.append((x.code, x.problem))
    return out


# ---- the gates (design A step 4) ----
def offered(d, role, core):
    import roles
    try:
        r = roles.load()["roles"][role]
    except (roles.RolesError, KeyError):
        raise Stop(C["data"], f"role {sd.idn(role)} is not in the role table") from None
    sets = {s for plat in (r.get("platform_toolsets") or {}).values() for s in plat}
    return [t for t in d.get("agent_tools", []) if (t["executor"] != "capability" or t["name"] in core) and (not t.get("toolset") or t["toolset"] in sets)]


def words(e, cmd, wt):
    """(code, why) when a shell command line names a git word of the commit rule or a board command of the dispatcher_only rule (DC-04),
    read with the policy tool's shell grammar, at any place a word can start a command (after a wrapper, in bash -c '...')."""
    import roles
    p, table, ads = roles.policy(), roles.load(), roles.adapters()
    kinds = e["policy"]["hook"]["kinds"]
    g = policy.items("commit_rule", p, table, e, ads, wt) if "commit_rule" in kinds else {}
    cmds = [c["command"].split() for c in policy.items("dispatcher_only", p, table, e, ads, wt)["command"]] if "dispatcher_only" in kinds else []
    glob = {x["word"] for x in g.get("global", [])}
    subs = {x["word"] for x in g.get("sub", [])}
    opts = {x["word"] for x in g.get("option", [])}
    subargs = [(x["sub"], x["word"]) for x in g.get("sub_args", [])]
    def named(a, ws):   # a word, or an unambiguous prefix git accepts for a long option
        k = a.split("=", 1)[0]
        return k in ws or (k.startswith("--") and len(k) > 2 and any(w.startswith("--") and w.startswith(k) for w in ws))
    try:
        views = list(policy._views(roles.ansi(cmd)))
    except ValueError:
        return "STL-GRD-617", "the command line cannot be parsed, so its git words cannot be judged"
    for toks in views:
        for i, t in enumerate(toks):
            base = t.rsplit("/", 1)[-1]
            for c in cmds:
                if base == c[0] and toks[i + 1:i + len(c)] == c[1:]:
                    return C["words"], f"the command runs {' '.join(c)}, a board action this role's adapter may not take"
            if base != "git" or not g:
                continue
            args = []
            for a in toks[i + 1:]:
                if a in policy.SEP:
                    break
                args.append(a)
            j = 0
            while j < len(args) and args[j].startswith("-"):
                if named(args[j], glob):
                    return C["words"], f"git {args[j].split('=', 1)[0]}: the commit rule denies it"
                j += 2 if args[j] in GIT_VALUE else 1
            sub, rest = (args[j], args[j + 1:]) if j < len(args) else ("", [])
            hit = (sub if sub in subs else next((a for a in args if named(a, opts)), None)
                   or next((a for s_, w in subargs if s_ == sub for a in rest
                            if a == w or (re.fullmatch(r"-[A-Za-z]", w) and re.fullmatch(rf"-[A-Za-z]*{w[1]}[A-Za-z]*", a))), None))
            if hit:
                return C["words"], f"git {sub} {hit if hit != sub else ''}".rstrip() + ": the commit rule denies it"
    return None


def gates(e, names, name, inp, wt):
    """(code, why) of the first gate that refuses a completed tool call, else None. In order: (a) the role's offered set and the entry's
    tool map (an unknown name is refused, never judged as None), (b) policy.judge with the pinned payload {tool_name, tool_input, cwd}
    (DC-02; the same judge as the CLI hook), (c) the shell words of the commit and dispatcher rules (DC-04).
    Item G2 adds gateway.check here, after (c)."""
    if name not in names or not isinstance((e.get("tools") or {}).get(name), dict):
        return C["unoffered"], f"tool {sd.idn(str(name))[:80]} was not offered to this run"
    if not isinstance(inp, dict):
        return C["input"], "the tool call's arguments are not a JSON object"
    try:
        got = policy.judge(e, {"tool_name": name, "tool_input": inp, "cwd": wt}, wt)
        spec = e["tools"][name]
        if not got and spec["class"] == "shell":
            got = words(e, str(policy.get(inp, spec["command"]) or ""), wt)
    except Exception as x:   # fail closed, as the hook does
        return "STL-GRD-617", f"the policy check cannot judge this call ({type(x).__name__})"
    return got


def execute(row, inp, wt, env, pre, timeout):
    """The executor of an offered call as a child: bin/agent_tool.py <executor>, the payload on stdin, the agent's environment and box (DC-01)."""
    argv = (pre or []) + [sys.executable, "-I", os.path.join(BIN, "agent_tool.py"), row["executor"]]
    pl = json.dumps({"tool_name": row["name"], "tool_input": inp, "cwd": wt}).encode()
    try:
        p = subprocess.Popen(argv, cwd=wt, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError as x:
        return {"ok": False, "output": f"{C['executor']} the executor could not start ({type(x).__name__})"}
    try:
        out, err = p.communicate(pl, timeout=timeout)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(OSError):
            os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return {"ok": False, "output": f"{C['executor']} the tool call ran over {timeout} s and was ended"}
    try:
        r = json.loads(out.decode("utf-8", "replace").strip().splitlines()[-1])
        assert isinstance(r, dict) and isinstance(r.get("ok"), bool)
        return r
    except (ValueError, IndexError, AssertionError):
        return {"ok": False, "output": f"{C['executor']} the executor gave no answer (exit {p.returncode}): {err.decode('utf-8', 'replace')[-300:]}"}


# ---- the agent: ready line, socket owner (DC-06) ----
def drain(p, rest, s):
    def run():
        with contextlib.suppress(Exception):
            if rest:
                with LOCK:
                    s.line(rest)
            for raw in p.stdout:
                with LOCK:
                    s.line(raw)
    threading.Thread(target=run, daemon=True).start()


def ready(p, pr, s):
    """The agent's port from its one ready line on stdout (within ready_timeout_s); its other output goes to the run log."""
    fd, buf, end = p.stdout.fileno(), b"", time.monotonic() + pr["ready_timeout_s"]
    while b"\n" not in buf:
        left = end - time.monotonic()
        if left <= 0 or not select.select([fd], [], [], left)[0]:
            raise Stop(C["ready"], f"the agent printed no ready line in {pr['ready_timeout_s']} s")
        b = os.read(fd, 4096)
        if not b or len(buf) > 65536:
            raise Stop(C["ready"], "the agent ended, or printed too much, before its ready line")
        buf += b
    line, rest = buf.split(b"\n", 1)
    with LOCK:
        s.line(line)
    drain(p, rest, s)
    import adapter
    try:
        port = adapter.get(json.loads(line), pr["ready"]["pointer"])
    except ValueError:
        port = None
    if type(port) is not int or not 0 < port < 65536:
        raise Stop(C["ready"], "the agent's ready line names no port")
    return port


def addr(h):
    b = bytes.fromhex(h)
    if len(b) == 4:
        return ipaddress.IPv4Address(b[::-1])
    a = ipaddress.IPv6Address(b"".join(b[i:i + 4][::-1] for i in range(0, 16, 4)))
    return a.ipv4_mapped or a


def listener(port, pid):
    """The loopback address the agent's process tree listens on at port (/proc), else Stop (DC-06: no foreign or outward socket)."""
    socks = {}
    for fam in ("tcp", "tcp6"):
        with contextlib.suppress(OSError), open(f"/proc/net/{fam}", encoding="ascii") as f:
            for l in f.read().splitlines()[1:]:
                x = l.split()
                h, _, pt = x[1].partition(":")
                if x[3] == "0A" and int(pt, 16) == port:   # 0A: LISTEN
                    socks[x[9]] = addr(h)
    parent = {}
    for n in os.listdir("/proc"):
        if n.isdigit():
            with contextlib.suppress(OSError, IndexError, ValueError), open(f"/proc/{n}/stat", encoding="utf-8", errors="replace") as f:
                parent[int(n)] = int(f.read().rsplit(")", 1)[1].split()[1])
    def mine(n):
        for _ in range(64):
            if n == pid:
                return True
            n = parent.get(n)
            if not n:
                return False
        return False
    hits = []
    for n in parent:
        if mine(n):
            with contextlib.suppress(OSError):
                for fd in os.listdir(f"/proc/{n}/fd"):
                    with contextlib.suppress(OSError):
                        t = os.readlink(f"/proc/{n}/fd/{fd}")
                        if t.startswith("socket:[") and t[8:-1] in socks:
                            hits.append(socks[t[8:-1]])
    if not hits or not all(a.is_loopback for a in hits):
        raise Stop(C["socket"], f"port {port} is not a loopback socket of the agent's own processes")
    return str(hits[0])


# ---- the run loop ----
def events(r, cap, end):
    """The JSON objects of a server-sent event stream (data lines; other fields ignored), each at most cap bytes, until the monotonic end."""
    data = []
    while True:
        if time.monotonic() > end:
            raise Stop(C["stream"], "the agent's turn ran over its turn timeout")
        line = r.readline(cap + 1)
        if len(line) > cap or sum(map(len, data)) > cap:
            raise Stop(C["stream"], f"an event of the agent is over {cap} bytes")
        if not line.strip():
            if data:
                try:
                    x = json.loads(b"\n".join(data))
                except ValueError:
                    x = None
                if isinstance(x, dict):
                    yield x
                data = []
            if not line:
                return
            continue
        if line.startswith(b"data:"):
            data.append(line[5:].rstrip(b"\r\n").removeprefix(b" "))


class Run:
    def __init__(self, p, s, rec, e, env, d, agent):
        import adapter
        self.p, self.s, self.rec, self.e, self.env, self.d, self.a, self.ad = p, s, rec, e, env, d, agent, adapter
        self.pr = protocol(e)
        self.ex = doc(ROW).get("excerpt_chars", 240)
        self.cap = d.get("read_cap_bytes", 1 << 20)

    def put(self, ev):
        self.s.put(ev)
        with LOCK:
            self.s.log.write(json.dumps(ev) + "\n")
            self.s.log.flush()

    def line(self, kind, text):
        self.ad.event(kind, self.rec["run"], self.rec["role"], adapter=self.e["id"], card=self.rec["card"],
                      digest=hashlib.sha256(text.encode()).hexdigest(), excerpt=text[:self.ex])

    def message(self, mid, text):
        t = self.s.red(text[:self.cap])[:self.s.cap]
        self.put({"type": "message", "name": None, "input": {}, "id": self.s.red(str(mid))[:128], "text": t})
        self.line("adapter.agent-message", t)

    def state(self, v, snapshot):
        v = self.s.red(v)
        t = json.dumps(v)
        self.put({"type": "state", "name": None, "input": {}, "snapshot": snapshot, "state": v if len(t) <= self.s.cap else t[:self.s.cap]})
        if snapshot:
            self.line("adapter.agent-state", t)

    def ui(self, value):
        try:
            import agui_ui
        except ImportError:   # item U not there: nothing is recorded for UI events
            return
        with contextlib.suppress(Exception):   # U writes its own alert for what it drops; a UI failure never ends the run
            agui_ui.ingest(self.rec["run"], value, {"role": self.rec["role"], "card": self.rec["card"], "project": self.rec.get("project"), "adapter": self.e["id"]})

    def turn(self, host, port, msgs, tdefs, n):
        """One POST and its event stream: (completed tool calls [(id, name, args text)], whether the turn ended)."""
        pr, get = self.pr, self.ad.get
        rq, ev = pr["request"], pr["events"]
        ptr = lambda x, k: get(x, ev["pointers"].get(k))
        body = fill(rq["body"], {"thread": self.rec["run"], "run": f"{self.rec['run']}-{n}", "messages": msgs, "tools": tdefs, "state": {},
                                 "model": self.a["model"]})
        c = http.client.HTTPConnection(host, port, timeout=pr["turn_timeout_s"])
        try:
            c.request(rq["method"], rq["path"], body=json.dumps(body).encode(), headers=rq.get("headers") or {})
            r = c.getresponse()
            if r.status != 200:
                raise Stop(C["stream"], f"the agent answered the run input with HTTP {r.status}")
            bufs, calls, done = {}, {}, []
            for x in events(r, self.cap, time.monotonic() + pr["turn_timeout_s"]):
                t = ev["map"].get(get(x, ev["type"])) if isinstance(get(x, ev["type"]), str) else None
                mid, tid = ptr(x, "message_id"), ptr(x, "tool_id")
                if t == "message_start":
                    bufs[str(mid)] = []
                elif t == "message_delta" and isinstance(ptr(x, "delta"), str):
                    b = bufs.setdefault(str(mid), [])
                    if sum(map(len, b)) < self.cap:
                        b.append(ptr(x, "delta"))
                elif t == "message_end":
                    self.message(mid, "".join(bufs.pop(str(mid), [])))
                elif t == "tool_start":
                    calls[str(tid)] = (ptr(x, "tool_name"), [])
                elif t == "tool_args" and str(tid) in calls and isinstance(ptr(x, "args_delta"), str):
                    if sum(map(len, calls[str(tid)][1])) < self.cap:
                        calls[str(tid)][1].append(ptr(x, "args_delta"))
                elif t == "tool_end" and str(tid) in calls:
                    done.append(str(tid))
                elif t == "tool_result":
                    raise Stop(C["agent_tool"], "the agent reported the result of a tool it ran itself: an agent-side tool cannot be gated")
                elif t in ("state_snapshot", "state_delta"):
                    self.state(ptr(x, "state" if t == "state_snapshot" else "delta_ops"), t == "state_snapshot")
                elif t == "custom" and ptr(x, "custom_name") in (pr.get("ui_custom_names") or []):
                    self.ui(ptr(x, "custom_value"))
                elif t == "error":
                    raise Stop(C["agent_error"], "the agent reported a run error: " + self.s.red(str(ptr(x, "error")))[:200])
                elif t == "lifecycle_end":
                    return [(i, calls[i][0], "".join(calls[i][1])) for i in done], True
            return [(i, calls[i][0], "".join(calls[i][1])) for i in done], False
        except (OSError, http.client.HTTPException) as x:
            raise Stop(C["stream"], f"the agent's event stream failed ({type(x).__name__})") from None
        finally:
            c.close()

    def call(self, tid, name, raw, rows, msgs):
        s, wt = self.s, self.rec["worktree"]
        try:
            inp = json.loads(raw) if raw.strip() else {}
        except ValueError:
            inp = None
        shown = s.red(inp if isinstance(inp, dict) else {"value": raw[:s.cap]})
        name = name if isinstance(name, str) else str(name)[:128]
        self.put({"type": "tool_use", "name": name, "input": shown, "signature": self.ad.canon([name, shown])})
        got = gates(self.e, rows, name, inp, wt)
        r = {"ok": False, "code": got[0], "output": f"{got[0]} {got[1]}"} if got else \
            execute(rows[name], inp, wt, self.env, self.a["pre"], self.pr["turn_timeout_s"])
        out = s.filt(s.red(r.get("output") if isinstance(r.get("output"), str) else json.dumps(r.get("output"))))
        self.put({"type": "tool_result", "name": name, "input": shown, "ok": r["ok"] is True, "output": out, "diff": s.diff(),
                  "signature": self.ad.canon([name, shown])})
        if got and got[0] == C["unoffered"]:
            raise Stop(*got)
        m = self.pr["messages"]
        msgs += [fill(m["assistant_tool_calls"], {"id": uuid.uuid4().hex, "tool_id": tid, "tool_name": name, "args": raw}),
                 fill(m["tool"], {"id": uuid.uuid4().hex, "tool_id": tid, "result": json.dumps({"ok": r["ok"] is True, "output": out})})]

    def go(self):
        pr = self.pr
        port = ready(self.p, pr, self.s)
        host = listener(port, self.p.pid)
        rows = {t["name"]: t for t in offered(self.d, self.rec["role"], self.a["core"])}
        tdefs = [fill(pr["tool"], {"name": t["name"], "description": t["description"], "parameters": t["parameters"]}) for t in rows.values()]
        msgs = [fill(pr["messages"]["user"], {"id": uuid.uuid4().hex, "text": self.a["prompt"]})]
        for n in range(pr["max_turns"]):
            calls, ended = self.turn(host, port, msgs, tdefs, n)
            if not calls:
                if not ended:
                    raise Stop(C["stream"], "the agent's event stream ended before the end of its turn")
                return 0
            for tid, name, raw in calls:
                self.call(tid, name, raw, rows, msgs)
        raise Stop(C["turns"], f"the agent did not finish in {pr['max_turns']} turns")


def loop(p, s, rec, e, env, d, agent):
    """The run loop of an agent-runtime run (engine side, the supervisor). agent: {pre, prompt, model, core}. The loop outcome (DC-05):
    0 at the end of a turn with no pending tool call and no error, else the Stop code's number, or -1 on an unexpected failure."""
    try:
        return Run(p, s, rec, e, env, d, agent).go()
    except Stop as x:
        code, problem = x.code, x.problem
    except Exception as x:   # never a traceback in the supervisor: the run still ends, snapshotted and revoked
        code, problem = None, f"{type(x).__name__} in the run loop"
    with contextlib.suppress(Exception):
        s.put({"type": "error", "name": None, "input": {}, "output": s.red(f"{code or ''} {problem}".strip())})
    with contextlib.suppress(Exception):
        if code:
            el.say(code, f"run {rec['run']}: {problem}", alert=True)
    return int(code[-3:]) if code else -1


def main(argv):
    ap = argparse.ArgumentParser(prog="agent_runtime.py", description="Agent-runtime adapter kind: check its data.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check").add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    probs = problems()
    if a.json:
        print(json.dumps({"ok": not probs, "problems": [{"code": c, "problem": x} for c, x in probs]}))
    for c, x in probs:
        el.say(c, x)
    if not a.json:
        print("agent runtime data ok" if not probs else f"{len(probs)} problem(s)")
    return 1 if probs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
