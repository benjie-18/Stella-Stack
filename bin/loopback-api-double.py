#!/usr/bin/env python3
"""The loopback API's test double (F1c B5/A5, design D6): serves the contract's endpoints with
bin/loopback_guard.py in front, so the guard can be tested over real HTTP before E1 builds the API. It does nothing else: an
allowed request gets HTTP 200 {"ok": true, "endpoint": id} and changes nothing (an endpoint of BODIES also gets its body: run-ui
the run's generative UI read stream from bin/agui_ui.py read, X1 item U); a refused one gets HTTP 4xx {"ok": false, "code",
["cause",] "message"} and one alert line. Every method reaches the guard. No CORS header is sent.
Usage: loopback-api-double.py --port P --session F
  P: the port to bind on the IPv4 loopback address only (0 = a free one); the bound port is printed alone on the first stdout line.
  F: a JSON file {api_token, csrf_token}; the session port is the bound port. The contract is read once, at start.
Exit 1 (code and plain message): the contract cannot be used (STL-OWN-858) or the port cannot be bound (STL-OWN-859); exit 2: usage."""
import http.server, json, os, socket, struct, sys
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import agui_ui
import loopback_guard as guard
import stella_data as sd

LOOPBACK = socket.inet_ntoa(struct.pack("!I", socket.INADDR_LOOPBACK))
BODIES = {"run-ui": lambda a: {"run": a["run"], "records": agui_ui.read(a["run"])}}   # endpoint id -> its body from the path's {name} parts


class Handler(http.server.BaseHTTPRequestHandler):
    def __getattr__(self, name):   # every method, known or not, reaches the guard (an unlisted one is 857, never a 501)
        if name.startswith("do_"):
            return self.serve
        raise AttributeError(name)

    def log_message(self, *args):   # the refusal's alert line is the record; the access log would hold paths only
        pass

    def serve(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n < 0:
                raise ValueError
            body = self.rfile.read(n)
            code, cause, problem = guard.judge(self.command, self.path, self.headers.items(), body, self.server.session, self.server.doc)
        except Exception as e:   # fail closed: a request the guard cannot judge is refused
            code, cause, problem = "STL-OWN-858", None, f"the request could not be judged ({type(e).__name__})"
        out = {"ok": True} if code is None else {"ok": False, "code": code, **({"cause": cause} if cause else {})}
        if code is None:
            ep = next(e for e in self.server.doc["endpoints"] if e["method"] == self.command and guard.match(e["path"], self.path) is not None)
            out["endpoint"] = ep["id"]
            try:   # served only after the guard allowed the request
                out.update(BODIES[ep["id"]](guard.match(ep["path"], self.path)) if ep["id"] in BODIES else {})
            except agui_ui.Refusal as r:
                code, out = r.code, {"ok": False, "code": r.code}
                problem = r.problem
        if code is not None:
            out["message"] = guard.report(code, problem)
        data = json.dumps(out).encode()
        self.send_response(200 if code is None else 404 if code == "STL-OWN-857" else 403)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main(argv):
    o = dict(zip(argv[::2], argv[1::2]))
    if len(argv) != 4 or set(o) != {"--port", "--session"} or not o["--port"].isdigit() or int(o["--port"]) > 65535:
        print(__doc__.split("Usage: ", 1)[1].split("Exit")[0], file=sys.stderr)
        return 2
    try:
        s = sd.jload(o["--session"])
        if not (isinstance(s, dict) and all(isinstance(s.get(k), str) and s[k] for k in ("api_token", "csrf_token"))):
            raise sd.DataError("the session file is not {api_token, csrf_token} (two non-empty strings)")
        doc = guard.contract()
    except sd.DataError as e:
        sd.say("STL-OWN-858", str(e), alert=True)
        return 1
    except guard.Refusal as r:
        sd.say(r.code, r.problem, alert=True)
        return 1
    try:
        srv = http.server.ThreadingHTTPServer((LOOPBACK, int(o["--port"])), Handler)
    except OSError as e:
        sd.say("STL-OWN-859", f"the loopback port cannot be bound ({e.strerror})", alert=True)
        return 1
    srv.doc, srv.session = doc, {"api_token": s["api_token"], "csrf_token": s["csrf_token"], "port": srv.server_address[1]}
    print(srv.server_address[1], flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
