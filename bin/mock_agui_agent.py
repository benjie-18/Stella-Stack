#!/usr/bin/env python3
"""A fake framework agent for tests (X1 item A, design section A "Fake agent" with ruling X1-DC-06), stdlib only: an AG-UI server over
HTTP + server-sent events on the loopback address. It is the test fixture of bin/agent-runtime-selftest.sh: a builder never changes it.
  mock_agui_agent.py [--port P] [--protocol-map F] [--model M] [--cwd W] [--prompt-file F] [--idle-s N]      mock_agui_agent.py --version
Start: binds the IPv4 loopback address, port P (default 0: a free port it picks itself, DC-06) and prints ONE ready line on stdout, {"ready": true, "port": N}
  (the protocol entry's ready pointer is /port); nothing else goes to stdout. It exits after --idle-s seconds (default 600) with no request.
A run: any POST. The body is the run input (AG-UI RunAgentInput: threadId, runId, messages, tools, state; the model at any key "model",
  else --model). The actions are the JSON list between the lines BEGIN-ACTIONS and END-ACTIONS of the first user message (content a
  string or a list of {text} parts; else of --prompt-file), the bin/mock_agent.py contract 3b. Turns: every tool action (write, read,
  edit, shell, undeclared_tool) ends a turn with RUN_FINISHED and waits for its result; the next POST holds one more tool message
  (role "tool", or a toolCallId), so a POST with k tool messages resumes after the k-th tool action. The agent keeps no state.
Actions -> events (the answer is text/event-stream, one "data: <json>" per event, RUN_STARTED first, RUN_FINISHED or RUN_ERROR last):
  write {path, text} | read {path} | edit {path, old, new} | shell {cmd}: TOOL_CALL_START/ARGS (the arguments in two chunks)/END for the
    offered tool the action names ("tool": NAME), else the offered tool whose name is the op, else whose name holds the op; the action's
    fields are put under the tool's parameter names (path|file_path|file|filename, text|content|contents, cmd|command,
    old|old_string|old_text, new|new_string|new_text); a tool with no parameter properties gets the fields as they are
  undeclared_tool {name, args}: a tool call for a tool that was not offered
  say {text} -> TEXT_MESSAGE_START/CONTENT (in chunks)/END | env -> a text message of this process's environment (NAME=value lines)
  model_call {prompt, shape?} -> a POST to the model proxy: base URL and token from the variables its adapters.json entry names
    (start.env base_url_env, token_env; the entry is the one the run_env.adapter variable names), the wire shape "shape" else the
    entry's first protocols id else the first of .stella/protocols.json; then a text message "model_call <status>"
  direct_call {url} -> an HTTP GET to that URL itself (the item C tripwire), then a text message "direct_call <status>"
  state {snapshot} -> STATE_SNAPSHOT | state_delta {delta} -> STATE_DELTA | ui {name, component, props, actions} -> CUSTOM {name, value:
    {component, props, actions}} | fail {message} -> RUN_ERROR | repeat {times, actions}
--protocol-map F (the fake second protocol, AC5): JSON {type_key, types: {AG-UI type: name}, keys: {AG-UI field: name}}: every event is
  sent with its type under type_key (default "type"), its type renamed by types and its top-level fields renamed by keys.
shortcut: one request at a time per run and no cancel; enough for a fixture, not an AG-UI server."""
import argparse, http.client, http.server, json, os, re, socket, struct, sys, threading, time, urllib.parse, uuid

VERSION = "0.1.0"
BIN = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.realpath(os.environ.get("STELLA_ROOT") or os.path.dirname(BIN))
TOOL_OPS = ("write", "read", "edit", "shell", "undeclared_tool")
ALIAS = {"path": ("path", "file_path", "file", "filename"), "text": ("text", "content", "contents"), "cmd": ("cmd", "command"),
         "old": ("old", "old_string", "old_text"), "new": ("new", "new_string", "new_text")}
OUT_CAP = 1 << 20
A = None   # the parsed argv
PMAP = {}
LAST = [time.monotonic()]


def load(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return json.load(f)


def find_key(x, k):
    """The first string value under key k at any depth (messages excepted), else None."""
    if isinstance(x, dict):
        if isinstance(x.get(k), str):
            return x[k]
        x = [v for kk, v in x.items() if kk != "messages"]
    for v in x if isinstance(x, list) else []:
        r = find_key(v, k)
        if r:
            return r
    return None


def text_of(c):
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(p.get("text", "") if isinstance(p, dict) else str(p) for p in c)
    return ""


def actions_of(text):
    lines = text.splitlines()
    s = [ln.strip() for ln in lines]
    if "BEGIN-ACTIONS" not in s or "END-ACTIONS" not in s:
        return []
    acts = json.loads("\n".join(lines[s.index("BEGIN-ACTIONS") + 1:s.index("END-ACTIONS")]))
    out = []
    def flat(xs):
        for x in xs:
            if isinstance(x, dict) and x.get("op") == "repeat":
                for _ in range(int(x.get("times", 1))):
                    flat(x.get("actions", []))
            elif isinstance(x, dict):
                out.append(x)
    flat(acts)
    return out


def pick_tool(tools, a):
    names = [t.get("name") for t in tools if isinstance(t, dict) and isinstance(t.get("name"), str)]
    want = a.get("tool")
    if want:
        return next((t for t in tools if isinstance(t, dict) and t.get("name") == want), None)
    op = a["op"].casefold()
    n = next((x for x in names if x.casefold() == op), None) or next((x for x in names if op in x.casefold()), None)
    return next((t for t in tools if isinstance(t, dict) and t.get("name") == n), None) if n else None


def args_for(tool, a):
    fields = {k: v for k, v in a.items() if k not in ("op", "tool", "step")}
    props = ((tool or {}).get("parameters") or {}).get("properties") or {}
    if not props:
        return fields
    out = {}
    for p in props:
        for k, v in fields.items():
            if p == k or p in ALIAS.get(k, ()):
                out[p] = v
    return out or fields


def post(url, headers, body, timeout=60):
    u = urllib.parse.urlsplit(url)
    c = (http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection)(u.hostname, u.port, timeout=timeout)
    try:
        c.request("POST", (u.path or "/") + ("?" + u.query if u.query else ""), body=json.dumps(body).encode(),
                  headers={"Content-Type": "application/json", **headers})
        r = c.getresponse()
        return r.status, r.read(OUT_CAP).decode("utf-8", "replace")
    finally:
        c.close()


def fill(t, v):
    if isinstance(t, str):
        m = re.fullmatch(r"\{(\w+)\}", t)
        return v[m[1]] if m and m[1] in v else re.sub(r"\{(\w+)\}", lambda m: str(v.get(m[1], m[0])), t)
    if isinstance(t, list):
        return [fill(x, v) for x in t]
    if isinstance(t, dict):
        return {k: fill(x, v) for k, x in t.items()}
    return t


def model_call(a, model):
    try:
        doc = load(".stella/adapters.json")
        var = (doc.get("run_env") or {}).get("adapter")
        ent = next((e for e in doc.get("entries", []) if var and e.get("id") == os.environ.get(var)), {})
        env = (ent.get("start") or {}).get("env") or {}
        base, tok = os.environ.get(env.get("base_url_env") or ""), os.environ.get(env.get("token_env") or "")
        protos = {p["id"]: p for p in load(".stella/protocols.json")["entries"]}
        shape = a.get("shape") or (ent.get("protocols") or [None])[0] or next(iter(protos))
        rq = protos[shape]["request"]
        if not base or not tok:
            return "model_call failed: no base URL or token in the environment"
        v = {"model": model or "", "prompt": str(a.get("prompt", "")), "max_tokens": 16, "key": tok}
        st, _ = post(base.rstrip("/") + fill(rq["path"], v), fill(rq.get("headers") or {}, v), fill(rq.get("body") or {}, v))
        return f"model_call {st}"
    except (OSError, KeyError, ValueError, StopIteration, http.client.HTTPException) as e:
        return f"model_call failed: {type(e).__name__}"


def direct_call(a):
    try:
        u = urllib.parse.urlsplit(str(a.get("url", "")))
        c = http.client.HTTPConnection(u.hostname, u.port, timeout=5)
        c.request("GET", u.path or "/")
        st = c.getresponse().status
        c.close()
        return f"direct_call {st}"
    except (OSError, ValueError, http.client.HTTPException) as e:
        return f"direct_call failed: {type(e).__name__}"


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, ev):
        tk = PMAP.get("type_key") or "type"
        keys = PMAP.get("keys") or {}
        t = ev.pop("type")
        out = {tk: (PMAP.get("types") or {}).get(t, t), **{keys.get(k, k): v for k, v in ev.items()}}
        self.wfile.write(b"data: " + json.dumps(out).encode() + b"\n\n")
        self.wfile.flush()

    def text(self, s):
        mid = "msg-" + uuid.uuid4().hex[:12]
        self.send({"type": "TEXT_MESSAGE_START", "messageId": mid, "role": "assistant"})
        for i in range(0, max(len(s), 1), 200):
            self.send({"type": "TEXT_MESSAGE_CONTENT", "messageId": mid, "delta": s[i:i + 200]})
        self.send({"type": "TEXT_MESSAGE_END", "messageId": mid})

    def do_POST(self):
        LAST[0] = time.monotonic()
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        except ValueError:
            body = {}
        msgs = body.get("messages") if isinstance(body.get("messages"), list) else []
        tools = body.get("tools") if isinstance(body.get("tools"), list) else []
        model = find_key(body, "model") or A.model
        thread, run = body.get("threadId") or "t", body.get("runId") or "r"
        first = next((m for m in msgs if isinstance(m, dict) and m.get("role") == "user"), None)
        src = text_of(first.get("content")) if first else ""
        if "BEGIN-ACTIONS" not in src and A.prompt_file:
            src = open(A.prompt_file, encoding="utf-8").read()
        acts = actions_of(src)
        k = sum(1 for m in msgs if isinstance(m, dict) and (m.get("role") == "tool" or ("toolCallId" in m and not m.get("toolCalls"))))
        pos, seen = 0, 0   # resume after the k-th tool action
        while pos < len(acts) and seen < k:
            if acts[pos].get("op") in TOOL_OPS:
                seen += 1
            pos += 1
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.send({"type": "RUN_STARTED", "threadId": thread, "runId": run})
        for a in acts[pos:]:
            op = a.get("op")
            if op in TOOL_OPS:
                if op == "undeclared_tool":
                    name, args = str(a.get("name", "qa_not_offered")), a.get("args") or {}
                else:
                    t = pick_tool(tools, a)
                    if t is None:
                        self.text(f"no offered tool for {op}")
                        continue
                    name, args = t["name"], args_for(t, a)
                cid, raw = "call-" + uuid.uuid4().hex[:12], json.dumps(args)
                self.send({"type": "TOOL_CALL_START", "toolCallId": cid, "toolCallName": name, "parentMessageId": None})
                h = len(raw) // 2
                for part in (raw[:h], raw[h:]):
                    self.send({"type": "TOOL_CALL_ARGS", "toolCallId": cid, "delta": part})
                self.send({"type": "TOOL_CALL_END", "toolCallId": cid})
                break   # the turn ends; the result comes in the next run input
            if op == "say":
                self.text(str(a.get("text", "")))
            elif op == "env":
                self.text("\n".join(f"{k_}={v}" for k_, v in sorted(os.environ.items())))
            elif op == "model_call":
                self.text(model_call(a, model))
            elif op == "direct_call":
                self.text(direct_call(a))
            elif op == "state":
                self.send({"type": "STATE_SNAPSHOT", "snapshot": a.get("snapshot", {})})
            elif op == "state_delta":
                self.send({"type": "STATE_DELTA", "delta": a.get("delta", [])})
            elif op == "ui":
                self.send({"type": "CUSTOM", "name": a.get("name", "ui"),
                           "value": {k_: a[k_] for k_ in ("component", "props", "actions") if k_ in a}})
            elif op == "fail":
                self.send({"type": "RUN_ERROR", "message": str(a.get("message", "failed")), "code": a.get("code")})
                return
            else:
                self.text(f"unknown op {op!r}")
        self.send({"type": "RUN_FINISHED", "threadId": thread, "runId": run})
        LAST[0] = time.monotonic()


def main(argv):
    global A, PMAP
    if argv == ["--version"]:
        print(f"mock-agui-agent {VERSION}")
        return 0
    ap = argparse.ArgumentParser(prog="mock_agui_agent.py")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--idle-s", type=float, default=600)
    for k in ("protocol-map", "model", "cwd", "prompt-file"):
        ap.add_argument("--" + k)
    A = ap.parse_args(argv)
    if A.protocol_map:
        PMAP = json.load(open(A.protocol_map, encoding="utf-8"))
    if A.cwd:
        os.chdir(A.cwd)
    srv = http.server.ThreadingHTTPServer((socket.inet_ntoa(struct.pack("!I", socket.INADDR_LOOPBACK)), A.port), Handler)
    print(json.dumps({"ready": True, "port": srv.server_address[1]}), flush=True)
    def idle():
        while time.monotonic() - LAST[0] < A.idle_s:
            time.sleep(1)
        os._exit(0)
    threading.Thread(target=idle, daemon=True).start()
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
