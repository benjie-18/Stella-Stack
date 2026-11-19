#!/usr/bin/env python3
"""The loopback model proxy (F3 item T; body B1 api, AC7; design section 2 with ruling DC-04), stdlib only. A CLI on an api link
points at it and holds only its run token (bin/run_token.py); the proxy swaps the token for the real key and the client never sees it.
CLI (host only: refuses in a worker environment, STL-CFG-312):
  model_proxy.py serve [--port P]   listens on the bind address of .stella/run-gateway.json proxy.bind (loopback only) and port P
                                    (default proxy.port; 0 = ephemeral); {bind, port, pid} goes to stdout and to the index key model_proxy_state.
One request, in this order (a refusal answers an HTTP status >= 400 with {"error": {"code", "message"}} and writes one event line):
  1. the target is a path (an absolute-form target is refused: STL-MDL-794);
  2. the run token is read from the auth headers the protocols use (the union of every .stella/protocols.json header template that
     holds {key}, the template's text around {key} taken off); none, unknown 790, expired 791, revoked 792: 401;
     a token of a link that is no api connection (DC-04) or has no wire shape: 403, STL-MDL-793;
  3. the path must be the connection's protocol request path (method included; {model} matches one segment) or its models path
     (GET); else 404, STL-MDL-794, never forwarded. The query keeps only the parameters proxy.forward_query names;
  4. a model call: the body is one JSON object (proxy.max_body_bytes, else 400/413 STL-MDL-795) and the model is set to the run's
     at every place the protocol's body template holds {model} (the path's {model} too): a token is valid for its run's model only;
     the budget gate (bin/route.py budget_gate: bin/budget.py) and a ledger slot (bin/ledger.py acquire; refused: 429 STL-MDL-798);
  5. every client header is dropped but proxy.forward_headers (never an auth header); the key (bin/credentials.py get) goes in the
     protocol's own header templates (route.headers_of); the request goes to the connection's catalog host only (route.url_of),
     with http.client: no redirect is followed and no proxy from the environment is used; no answer: 502 STL-MDL-796;
  6. the answer streams back as it arrives (the key masked wherever it stands, also across chunks); a model call's usage (the JSON
     answer, or the stream's data lines, at the protocol's usage pointer) goes to the ledger with its cost (route.note_call);
  7. one event line per request through bin/event_log.py: the run, the token id (a hash prefix), the link, the status; never a token or a key.
Exit: 0 when stopped; 1 refused (the catalog code and its plain message on stderr); 2 usage."""
import os, sys

if __name__ == "__main__" and not sys.flags.isolated:   # run directly: PYTHONPATH and the current folder must not decide what is imported
    try:
        os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
    except OSError:
        sys.exit("STL-CFG-310 model_proxy.py could not restart itself isolated (python3 -I); nothing was served")

import argparse, contextlib, http.client, http.server, ipaddress, json, re, time, urllib.parse

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import cost
import credentials
import event_log as el
import ledger
import route
import run_token
import stella_data as sd
import worker_env

UNKNOWN, NOT_API, BADPATH, BADBODY, UPSTREAM, STORE, LIMITED, SERVE = (
    run_token.UNKNOWN, "STL-MDL-793", "STL-MDL-794", "STL-MDL-795", "STL-MDL-796", run_token.STORE, "STL-MDL-798", "STL-MDL-799")
STATE_KEY = "model_proxy_state"
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "trailers", "transfer-encoding", "upgrade", "content-length"}
CHUNK = 1 << 14
API = "api"   # the connection type the proxy serves (the catalog's word; DC-04)


class Refuse(Exception):
    def __init__(self, status, code, problem):
        super().__init__(problem)
        self.status, self.code, self.problem = status, code, problem


def auth_headers(protos):
    """{lower-case header name: [(text before {key}, text after)]} over every protocol: where a client may put its run token."""
    out = {}
    for p in protos.values():
        for k, v in p["request"]["headers"].items():
            if "{key}" in v:
                out.setdefault(k.lower(), []).append(tuple(v.split("{key}", 1)))
    return out


def token_of(headers, auth, prefix):
    for name, forms in auth.items():
        for v in headers.get_all(name) or []:
            for pre, post in forms:
                if v.startswith(pre) and v.endswith(post) and len(v) > len(pre) + len(post):
                    t = v[len(pre):len(v) - len(post)] if post else v[len(pre):]
                    if t.startswith(prefix):
                        return t
    return None


def model_pointers(v, at=""):
    """The pointers where a body template holds exactly {model}."""
    if v == "{model}":
        return [at]
    if isinstance(v, dict):
        return [p for k, x in v.items() for p in model_pointers(x, f"{at}/{k.replace('~', '~0').replace('/', '~1')}")]
    if isinstance(v, list):
        return [p for i, x in enumerate(v) for p in model_pointers(x, f"{at}/{i}")]
    return []


def path_rx(tpl):
    return re.compile("".join("[^/?#]+" if part == "{model}" else re.escape(part) for part in re.split(r"(\{model\})", tpl)))


class Masker:
    """Streams bytes with every form of the key masked, also where a form is split across two chunks: only a tail that could
    start a form is held back."""
    def __init__(self, forms):
        self.forms, self.held = [f.encode() for f in forms if f], b""

    def feed(self, b, last=False):
        buf = self.held + b
        for f in sorted(self.forms, key=len, reverse=True):
            buf = buf.replace(f, el.MASK.encode())
        keep = 0 if last else max([n for f in self.forms for n in range(min(len(f) - 1, len(buf)), 0, -1) if buf.endswith(f[:n])][:1] or [0])
        self.held = buf[len(buf) - keep:] if keep else b""
        return buf[:len(buf) - keep] if keep else buf


def usage_from(proto, raw):
    """The five token counts of an answer: a JSON body, or a stream's data lines (each at the usage pointer, the largest count of each type).
    shortcut: a stream event that nests its usage elsewhere than the protocol's usage pointer is not counted, upgrade when protocols.json carries a stream usage pointer."""
    text = raw.decode("utf-8", "replace")
    with contextlib.suppress(ValueError, RecursionError):
        return cost.usage_of(proto, json.loads(text))
    got = dict.fromkeys(cost.types(), 0)
    for line in text.splitlines():
        if line.startswith("data:"):
            with contextlib.suppress(ValueError, RecursionError):
                u = cost.usage_of(proto, json.loads(line[5:]))
                got = {k: max(got[k], u[k]) for k in got}
    return got


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"   # one request per connection; a streamed answer ends when the connection closes
    gw = None   # the run-gateway data, set by serve

    def log_message(self, *a):   # the event lines are the log; the default writes request lines to stderr
        pass

    def do_GET(self):
        self.handle_one()

    do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = do_GET

    def refuse(self, x):
        body = json.dumps({"error": {"code": x.code, "message": el.scrub(x.problem)}}).encode()
        with contextlib.suppress(OSError):
            self.send_response(x.status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def event(self, kind, what, code=None, role=None, **new):
        try:
            el.append(el.build(kind, what, new=new, code=code, who={"role": role}))
        except (el.EventError, sd.DataError, OSError) as e:   # the request's answer stands; the missing line is one alert
            el.say(getattr(e, "code", "STL-CFG-318"), f"a model proxy event line was not written ({type(e).__name__})", alert=True)

    def handle_one(self):
        tid, rec = None, None
        try:
            if not self.path.startswith("/"):
                raise Refuse(400, BADPATH, "the request target is not a path (an absolute-form target names another host)")
            _, cat, protos, local = route.data()
            self.auth = auth_headers(protos)
            tok = token_of(self.headers, self.auth, self.gw["token"]["prefix"])
            if tok is None:
                raise Refuse(401, UNKNOWN, "the request carries no run token")
            tid = run_token.tid(tok)
            rec, code = run_token.lookup(tok)
            if code:
                raise Refuse(401, code, f"run token {tid} is {'not known' if code == UNKNOWN else 'expired' if code == run_token.EXPIRED else 'revoked'}")
            self.serve_run(rec, tid, protos, cat, local)
        except Refuse as x:
            self.refuse(x)
            self.event("model-proxy.refused", f"run {rec['run']}" if rec else f"token {tid}" if tid else "a request with no run token", x.code,
                       token_id=tid, status=x.status, role=(rec or {}).get("role"))
        except (run_token.Stop, route.Stop) as x:   # the token state, the data or the call timeout setting cannot be used
            self.refuse(Refuse(500, x.code, x.problem))
        except Exception as e:   # never a traceback, never the error's text: the type only
            self.refuse(Refuse(500, "STL-CFG-310", f"{type(e).__name__}, an unexpected failure of the model proxy"))

    def serve_run(self, rec, tid, protos, cat, local):
        link = {"connection": rec["connection"], "model": rec["model"]}
        try:
            prov, _ = route.model_of(cat, link)
        except route.Stop as x:
            raise Refuse(403, NOT_API, x.problem) from None
        if prov.get("type") != API or rec.get("type") != API or prov.get("protocol") not in protos:
            raise Refuse(403, NOT_API, f"run {rec['run']}: link {prov['id']}/{rec['model']} is no api link with a wire shape (DC-04: the proxy serves api links only)")
        proto = protos[prov["protocol"]]
        rq, px = proto["request"], self.gw["proxy"]
        path, _, query = self.path.partition("?")
        call = self.command == rq.get("method", "POST") and path_rx(rq["path"]).fullmatch(path)
        if not call and not (self.command == "GET" and proto.get("models_path") == path):
            raise Refuse(404, BADPATH, f"{self.command} on that path is not a request of wire shape {proto['id']}")
        q = urllib.parse.urlencode([(k, v) for k, v in urllib.parse.parse_qsl(query, keep_blank_values=True) if k in px["forward_query"]])
        out_path = (route.render(rq["path"], {"model": urllib.parse.quote(rec["model"], safe="")}) if call else path) + ("?" + q if q else "")
        n = self.headers.get("Content-Length")
        if self.headers.get("Transfer-Encoding") or (n is not None and not n.isdigit()):
            raise Refuse(400, BADBODY, "the request body has no plain Content-Length")
        if int(n or 0) > px["max_body_bytes"]:
            raise Refuse(413, BADBODY, f"the request body is larger than {px['max_body_bytes']} bytes")
        body = self.rfile.read(int(n or 0))
        if call:
            try:
                doc = json.loads(body)
            except (ValueError, RecursionError):
                doc = None
            if not isinstance(doc, dict):
                raise Refuse(400, BADBODY, "the request body is not one JSON object")
            for p in model_pointers(rq["body"]):
                route.put(doc, p, rec["model"])   # the run's model, whatever the client asked
            body = json.dumps(doc).encode()
            who = argparse.Namespace(role=rec["role"], card=rec["card"], project=None, task=rec["run"])
            try:
                defer = route.budget_gate(who)
            except route.Stop as x:
                raise Refuse(429, x.code, x.problem) from None
            if defer and (defer["connection"], defer["model"]) != (prov["id"], rec["model"]):
                raise Refuse(429, route.BUDGET_HELD, f"run {rec['run']}: the budget is deferred to another link than the run's")
            try:
                fds = ledger.acquire(prov["id"], rec["model"], f"model proxy run {rec['run']}")
            except ledger.Refusal as r:
                raise Refuse(429, LIMITED, r.problem) from None
        else:
            fds = []
        try:
            self.forward(rec, tid, prov, proto, link, local, out_path, body, call)
        finally:
            for fd in fds:
                os.close(fd)

    def forward(self, rec, tid, prov, proto, link, local, out_path, body, call):
        key = None
        if prov["secrets"]:   # shortcut: the entry's first secret is its API key (as route.py reads it), upgrade when secrets carry a purpose
            try:
                key = credentials.get(prov["secrets"][0])
            except credentials.Refused as x:
                raise Refuse(503, x.code, f"link {prov['id']}/{rec['model']}: {x.problem}") from None
        forms = (key, json.dumps(key)[1:-1]) if key else ()
        el.SECRETS.update(forms)
        hs = {k: v for k, v in self.headers.items() if k.lower() in self.gw["proxy"]["forward_headers"] and k.lower() not in self.auth}
        hs.update(route.headers_of(proto["request"], key))
        u = urllib.parse.urlsplit(route.url_of(prov, link, local, out_path))
        t0, zero, status = time.monotonic(), dict.fromkeys(cost.types(), 0), None
        conn = (http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection)(u.hostname, u.port, timeout=route.timeout_of())
        try:
            try:   # http.client follows no redirect and reads no proxy from the environment
                conn.request(self.command, out_path, body=body if body or self.command != "GET" else None, headers=hs)
                r = conn.getresponse()
            except (OSError, http.client.HTTPException) as e:
                if call:
                    route.note_call(proto, link, self.who(rec), "timeout" if isinstance(e, TimeoutError) else "error", None, zero, t0)
                raise Refuse(502, UPSTREAM, f"link {prov['id']}/{rec['model']}: the upstream gave no answer ({type(e).__name__})") from None
            status, got, cut = r.status, bytearray(), False
            self.send_response(status)
            for k, v in r.getheaders():
                if k.lower() not in HOP:
                    self.send_header(k, el.scrub(Masker(forms).feed(v.encode("latin-1", "replace"), True).decode("latin-1")))
            self.end_headers()
            m = Masker(forms)
            try:
                while True:
                    b = r.read1(CHUNK) if hasattr(r, "read1") else r.read(CHUNK)
                    if len(got) <= el.MAX_FILE:
                        got += b
                    self.wfile.write(m.feed(b, not b))
                    self.wfile.flush()
                    if not b:
                        break
            except (OSError, http.client.HTTPException):
                cut = True   # the client or the upstream went away mid-stream
        finally:
            conn.close()
        if call:
            text = bytes(got).decode("utf-8", "replace")
            limited = None
            if not 200 <= status < 300:
                with contextlib.suppress(ledger.Stop, el.EventError, sd.DataError, OSError):   # an answer that is a limit is kept by the ledger
                    limited = ledger.observe_response(prov["id"], rec["model"], status, dict(r.getheaders()), text)
            outcome = "ok" if 200 <= status < 300 and not cut else "limit" if limited else "error"
            route.note_call(proto, link, self.who(rec), outcome, status, usage_from(proto, bytes(got)) if 200 <= status < 300 else zero, t0)
        self.event("model-proxy.call", f"run {rec['run']}", token_id=tid, link=f"{prov['id']}/{rec['model']}", status=status, role=rec["role"])

    @staticmethod
    def who(rec):
        return {"role": rec["role"], "project": None, "card": rec["card"], "session": rec["run"]}


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


def serve(a):
    try:
        gw = run_token.gateway()
    except run_token.Stop as x:
        return el.fail(x.code, x.problem)
    px = gw["proxy"]
    try:
        loop = ipaddress.ip_address(px["bind"]).is_loopback
    except ValueError:
        loop = False
    if not loop:
        return el.fail(SERVE, f"the bind address {px['bind']} is not a loopback address (run-gateway proxy.bind)")
    Handler.gw = gw
    try:
        srv = Server((px["bind"], px["port"] if a.port is None else a.port), Handler)
    except OSError as e:
        return el.fail(SERVE, f"the proxy cannot listen ({el.why(e)})")
    info = {"bind": px["bind"], "port": srv.server_address[1], "pid": os.getpid()}
    try:
        route.write_whole(el.path(sd.load(sd.INDEX)[STATE_KEY]), {"schema_version": 1, **info})
    except (OSError, ValueError, KeyError, sd.DataError) as e:
        return el.fail(STORE, f"the model proxy state cannot be written ({type(e).__name__})")
    print(json.dumps(info), flush=True)
    with contextlib.suppress(KeyboardInterrupt):
        srv.serve_forever()
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="model_proxy.py", description="The loopback model proxy for api links (host only).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve").add_argument("--port", type=int)
    a = ap.parse_args(argv)
    w = worker_env.reason()
    if w:
        return el.fail(sd.Refused.code, f"model_proxy.py {a.cmd} runs on the host only ({w}); nothing was served")
    return serve(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
