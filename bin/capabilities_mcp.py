#!/usr/bin/env python3
"""The capability MCP server (F3 item M; body B4, B6, AC4, AC6; design section 5 with ruling DC-05), stdlib only. Every role reaches
capability search, describe, request and load through it; the visibility rules and the trusted lines stay in bin/capabilities.py,
which it calls in-process.
CLI (host only: refuses in a worker environment, STL-CFG-312):
  capabilities_mcp.py serve [--port P]   MCP over streamable HTTP on .stella/run-gateway.json mcp.bind (loopback only) and port P
                                         (default mcp.port; 0 = ephemeral); {bind, port, path, pid} to stdout and the index key
                                         capabilities_mcp_state.
One request, in this order (an HTTP refusal answers a JSON-RPC error object with id null; its data.code is the catalog code):
  1. the run token: mcp.auth_header with mcp.auth_scheme; none, unknown, expired or revoked: 401 STL-GRD-675, one event line, nothing
     else of the request is read; role, card and run come from the token record only (a role argument is never read);
  2. the Host header (and an Origin header when sent) must name one of mcp.hosts: 403 STL-GRD-676 (a rebound DNS name);
  3. POST on mcp.path only (GET 405, other paths 404), a plain Content-Length up to mcp.max_body_bytes, one JSON-RPC 2.0 object,
     a listed MCP-Protocol-Version header when sent: else 4xx STL-GRD-677;
  4. methods initialize, notifications/initialized (and any notification or response: 202, no body), ping, tools/list, tools/call;
     another method or bad params: a JSON-RPC error with STL-GRD-678. Tools: search {query, limit?}, describe {id},
     request {id, reason}, load {id}. A refusal of bin/capabilities.py (STL-GRD-660..667) is a tool result with isError true.
     load and request write their trusted lines through bin/capabilities.py and bin/approvals.py (engine side).
Importers (the worker side of bin/capabilities.py, DC-05): call(tool, arguments) -> the tool's structured result, or raises
ClientError(code, problem); the token comes from the owner-auth worker_signals.token_env variables, the address from the state file.
Exit: 0 when stopped; 1 refused (the catalog code and its plain message on stderr); 2 usage."""
import os, sys

if __name__ == "__main__" and not sys.flags.isolated:   # run directly: PYTHONPATH and the current folder must not decide what is imported
    try:
        os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
    except OSError:
        sys.exit("STL-CFG-310 capabilities_mcp.py could not restart itself isolated (python3 -I); nothing was served")

import argparse, contextlib, http.client, http.server, ipaddress, json, types, urllib.parse

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import capabilities as cap
import event_log as el
import run_token
import stella_data as sd
import worker_env

AUTH, HOST, BADREQ, BADCALL, FAILED, SERVE, UNREACHABLE, ANSWER = (f"STL-GRD-{n}" for n in range(675, 683))
STATE_KEY = "capabilities_mcp_state"
STR, INT = {"type": "string"}, {"type": "integer", "minimum": 1}
TOOLS = {   # name -> (description, properties, required); the role is never an argument
    "search": ("Find the capabilities (skills, tools, commands, MCP servers) this run's role may use now or may request, ranked by keyword.",
               {"query": STR, "limit": INT}, ["query"]),
    "describe": ("Describe one capability by id: its kind, summary, inputs, outputs, hosts and visibility for this run's role.", {"id": STR}, ["id"]),
    "request": ("Ask for a capability this run's role may request: opens one approval with the reason.", {"id": STR, "reason": STR}, ["id", "reason"]),
    "load": ("Load an available capability: returns its definition (a skill's instructions, a tool's definition); the load is logged.", {"id": STR}, ["id"]),
}


class Refuse(Exception):
    def __init__(self, status, code, problem, rpc=-32600):
        super().__init__(problem)
        self.status, self.code, self.problem, self.rpc = status, code, problem, rpc


class ClientError(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def conf():
    return run_token.gateway()["mcp"]


def host_name(v):
    """The host of a Host header or an Origin URL, lower case, without port or brackets; None when it is not one."""
    try:
        return urllib.parse.urlsplit(v if "//" in v else "//" + v).hostname
    except ValueError:
        return None


def rpc_error(rid, rpc, code, problem):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": rpc, "message": f"{code} {el.scrub(problem)}", "data": {"code": code}}}


def tool_call(rec, params):
    """The tools/call result for the token's run: role, card and run from the record; a capabilities.py refusal is isError true."""
    name, args = params.get("name"), params.get("arguments", {})
    if name not in TOOLS:
        raise Refuse(200, BADCALL, "no such tool", -32602)
    _, props, req = TOOLS[name]
    if not isinstance(args, dict) or any(k not in args for k in req) or any(
            k in args and not (isinstance(args[k], str) and args[k].strip() if s is STR else type(args[k]) is int and args[k] >= 1)
            for k, s in props.items()):
        raise Refuse(200, BADCALL, f"the arguments of {name} must be " + ", ".join(f"{k} ({s['type']})" for k, s in props.items()), -32602)
    a = types.SimpleNamespace(role=rec["role"], card=rec["card"], run=rec["run"], id=args.get("id"), reason=args.get("reason"),
                              words=[args.get("query", "")], limit=args.get("limit"))
    try:
        if not cap.role_ok(a.role):
            raise cap.Refuse(663, "the role of the run token is not in the role table")
        out = getattr(cap, "cmd_" + name)(a, cap.sources(), cap.registry())
    except cap.Refuse as r:
        sd.say(f"STL-GRD-{r.code}", r.problem, alert=r.alert)   # the server's own stderr and alert log, as the CLI does
        err = {"code": f"STL-GRD-{r.code}", "message": r.problem}
        return {"content": [{"type": "text", "text": json.dumps({"error": err})}], "structuredContent": {"error": err}, "isError": True}
    out = {"results": out} if isinstance(out, list) else out
    return {"content": [{"type": "text", "text": json.dumps(out)}], "structuredContent": out, "isError": False}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"   # one request per connection
    mc = None   # the mcp section, set by serve

    def log_message(self, *a):   # the event lines are the log
        pass

    def do_POST(self):
        self.handle_one()

    do_GET = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = do_POST

    def send(self, status, doc=None):
        body = b"" if doc is None else json.dumps(doc).encode()
        with contextlib.suppress(OSError):
            self.send_response(status)
            if status == 401:
                self.send_header("WWW-Authenticate", self.mc["auth_scheme"])
            if status == 405:
                self.send_header("Allow", "POST")
            if body:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def event(self, kind, what, code=None, role=None, **new):
        try:
            el.append(el.build(kind, what, new=new, code=code, who={"role": role}))
        except (el.EventError, sd.DataError, OSError) as e:   # the answer stands; the missing line is one alert
            el.say(getattr(e, "code", "STL-CFG-318"), f"a capability server event line was not written ({type(e).__name__})", alert=True)

    def token(self):
        scheme, _, tok = (self.headers.get(self.mc["auth_header"]) or "").strip().partition(" ")
        return tok.strip() if scheme.lower() == self.mc["auth_scheme"].lower() and tok.strip() else None

    def handle_one(self):
        tid = None
        try:
            tok = self.token()   # first: nothing else of the request is read without a token in force
            if tok is None:
                raise Refuse(401, AUTH, "the request carries no run token")
            tid = run_token.tid(tok)
            rec, code = run_token.lookup(tok)
            if code:
                raise Refuse(401, AUTH, f"run token {tid} is {'not known' if code == run_token.UNKNOWN else 'expired' if code == run_token.EXPIRED else 'revoked'}")
            self.serve_run(rec)
        except Refuse as x:
            self.send(x.status, rpc_error(None, x.rpc, x.code, x.problem))
            if x.code == AUTH:
                self.event("capabilities-mcp.refused", f"token {tid}" if tid else "a request with no run token", x.code, token_id=tid, status=x.status)
        except run_token.Stop as x:   # the token state or the gateway data cannot be used
            self.send(500, rpc_error(None, -32603, x.code, x.problem))
        except Exception as e:   # never a traceback, never the error's text: the type only
            self.send(500, rpc_error(None, -32603, FAILED, f"{type(e).__name__}, an unexpected failure of the capability server"))

    def serve_run(self, rec):
        mc = self.mc
        hosts = {h.lower() for h in mc["hosts"]}
        if host_name(self.headers.get("Host") or "") not in hosts or (
                self.headers.get("Origin") is not None and host_name(self.headers["Origin"]) not in hosts):
            raise Refuse(403, HOST, "the Host or Origin header names no loopback host of the server")
        if self.path.partition("?")[0] != mc["path"]:
            raise Refuse(404, BADREQ, "no such path")
        if self.command != "POST":
            raise Refuse(405, BADREQ, f"{self.command} is not served: JSON-RPC requests are POSTs")
        ver = self.headers.get("MCP-Protocol-Version")
        if ver is not None and ver not in mc["protocol_versions"]:
            raise Refuse(400, BADREQ, "the MCP-Protocol-Version is not one this server speaks")
        n = self.headers.get("Content-Length")
        if self.headers.get("Transfer-Encoding") or n is None or not n.isdigit():
            raise Refuse(411, BADREQ, "the request body has no plain Content-Length")
        if int(n) > mc["max_body_bytes"]:
            raise Refuse(413, BADREQ, f"the request body is larger than {mc['max_body_bytes']} bytes")
        try:
            msg = json.loads(self.rfile.read(int(n)))
        except (ValueError, RecursionError):
            raise Refuse(400, BADREQ, "the body is not JSON", -32700) from None
        if not (isinstance(msg, dict) and msg.get("jsonrpc") == "2.0"):
            raise Refuse(400, BADREQ, "the body is not one JSON-RPC 2.0 message")
        if "method" not in msg or "id" not in msg:   # a notification or a response: accepted, nothing to answer
            return self.send(202)
        rid, method, params = msg["id"], msg["method"], msg.get("params", {})
        try:
            if not isinstance(params, dict):
                raise Refuse(200, BADCALL, "params is not an object", -32602)
            if method == "initialize":
                v = params.get("protocolVersion")
                res = {"protocolVersion": v if v in mc["protocol_versions"] else mc["protocol_versions"][0],
                       "capabilities": {"tools": {"listChanged": False}}, "serverInfo": mc["server_info"]}
            elif method == "ping":
                res = {}
            elif method == "tools/list":
                res = {"tools": [{"name": k, "description": d, "inputSchema": {"type": "object", "properties": p, "required": r,
                                                                                "additionalProperties": True}}
                                 for k, (d, p, r) in TOOLS.items()]}
            elif method == "tools/call":
                res = tool_call(rec, params)
            else:
                raise Refuse(200, BADCALL, "no such method", -32601)
        except Refuse as x:
            return self.send(200, rpc_error(rid, x.rpc, x.code, x.problem))
        self.send(200, {"jsonrpc": "2.0", "id": rid, "result": res})


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


def serve(a):
    try:
        mc = conf()
    except run_token.Stop as x:
        return el.fail(x.code, x.problem)
    try:
        loop = ipaddress.ip_address(mc["bind"]).is_loopback
    except ValueError:
        loop = False
    if not loop:
        return el.fail(SERVE, f"the bind address {mc['bind']} is not a loopback address (run-gateway mcp.bind)")
    Handler.mc, Handler.timeout = mc, mc["timeout_s"]
    try:
        srv = Server((mc["bind"], mc["port"] if a.port is None else a.port), Handler)
    except OSError as e:
        return el.fail(SERVE, f"the capability server cannot listen ({el.why(e)})")
    info = {"bind": mc["bind"], "port": srv.server_address[1], "path": mc["path"], "pid": os.getpid()}
    try:
        import route   # its write_whole: temp file, fsync, rename
        route.write_whole(el.path(sd.load(sd.INDEX)[STATE_KEY]), {"schema_version": 1, **info})
    except (OSError, ValueError, KeyError, sd.DataError) as e:
        return el.fail(SERVE, f"the capability server state cannot be written ({type(e).__name__})")
    print(json.dumps(info), flush=True)
    with contextlib.suppress(KeyboardInterrupt):
        srv.serve_forever()
    return 0


def call(tool, arguments):
    """The worker side (DC-05): one tools/call on loopback with the run token of this environment; nothing else is read locally."""
    try:
        pre, mc = run_token.gateway()["token"]["prefix"], conf()
        tok = next((v for v in (os.environ.get(n) for n in worker_env.signals()["token_env"]) if v and v.startswith(pre)), None)
        st = sd.load(sd.load(sd.INDEX)[STATE_KEY])
        host, port, path = st["bind"], st["port"], st["path"]
        assert ipaddress.ip_address(host).is_loopback and type(port) is int and isinstance(path, str)
    except (run_token.Stop, sd.DataError, OSError, KeyError, TypeError, ValueError, AssertionError) as e:
        raise ClientError(UNREACHABLE, f"the capability server address cannot be read ({type(e).__name__})") from None
    if tok is None:
        raise ClientError(UNREACHABLE, "this environment holds no run token")
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": arguments}}).encode()
    conn = http.client.HTTPConnection(host, port, timeout=mc["timeout_s"])   # no proxy from the environment
    try:
        conn.request("POST", path, body, {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                                          mc["auth_header"]: f"{mc['auth_scheme']} {tok}"})
        r = conn.getresponse()
        doc = json.loads(r.read(el.MAX_FILE))
    except (OSError, http.client.HTTPException, ValueError) as e:
        raise ClientError(UNREACHABLE, f"the capability server did not answer ({type(e).__name__})") from None
    finally:
        conn.close()
    res = doc.get("result") if isinstance(doc, dict) else None
    if not isinstance(res, dict):
        err = (doc.get("error") or {}) if isinstance(doc, dict) else {}
        raise ClientError(((err.get("data") or {}).get("code")) or ANSWER, str(err.get("message") or "the answer is not a tool result")[:200])
    out = res.get("structuredContent") or {}
    if res.get("isError"):
        e = out.get("error") or {}
        raise ClientError(e.get("code") or ANSWER, str(e.get("message") or "the tool call failed")[:200])
    return out.get("results", out) if tool == "search" else out


def main(argv):
    ap = argparse.ArgumentParser(prog="capabilities_mcp.py", description="The capability MCP server on loopback (host only).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve").add_argument("--port", type=int)
    a = ap.parse_args(argv)
    w = worker_env.reason()
    if w:
        return el.fail(sd.Refused.code, f"capabilities_mcp.py {a.cmd} runs on the host only ({w}); nothing was served")
    return serve(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
