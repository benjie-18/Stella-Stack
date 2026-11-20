#!/usr/bin/env python3
"""A raw-event AG-UI agent for tests (X1 fix round, after the red team's crt-AU agent), stdlib only: it sends exactly the events a
scenario file lists, so bin/agent-runtime-selftest.sh can play a hostile agent (malformed calls, names that carry secrets, a foreign
port). Not product code. argv: --scenario F --token-env NAME [ignored extras];  --version
F: {"ready": "auto" | {"port_of": <other port>} | raw string, "turns": [[event, ...], ...], "dump": path|null, "handoff": bool,
"foreign_dump": path}. An event is a dict (sent as one SSE data line), {"raw": "<text>"}, {"sleep": s} or {"repeat": k, "event": ev,
"pad": n} (k events, @I@ the index, @PAD@ n bytes). Any string "@TOKEN@" is replaced by the run token from the env. Turn n answers
the n-th POST (the last turn repeats). handoff: after the first turn the agent closes its port and a process outside its tree (own
session) binds it and answers the later turns."""
import http.server, json, os, socket, struct, sys, time

LOOP = socket.inet_ntoa(struct.pack("!I", socket.INADDR_LOOPBACK))

a = sys.argv[1:]
if "--version" in a:
    print("qa-raw 1.0"); sys.exit(0)
opt = dict(zip(a[::2], a[1::2]))
S = json.load(open(opt["--scenario"]))
TOK = os.environ.get(opt.get("--token-env", ""), "")
n = [0]


def sub(x):
    if isinstance(x, str):
        return x.replace("@TOKEN@", TOK)
    if isinstance(x, list):
        return [sub(v) for v in x]
    return {sub(k): sub(v) for k, v in x.items()} if isinstance(x, dict) else x


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *x):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if S.get("dump"):
            with open(S["dump"], "ab") as f:
                f.write(body + b"\n")
        turns = S["turns"]
        evs = turns[min(n[0], len(turns) - 1)]
        n[0] += 1
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for e in evs:
            if isinstance(e, dict) and "sleep" in e:
                time.sleep(e["sleep"]); continue
            if isinstance(e, dict) and "raw" in e:
                self.wfile.write(sub(e["raw"]).encode())
            elif isinstance(e, dict) and "repeat" in e:   # {"repeat": k, "event": ev, "pad": bytes}: k events, each padded
                for i in range(e["repeat"]):
                    ev = dict(sub(e["event"]))
                    for k, v in list(ev.items()):
                        if isinstance(v, str):
                            ev[k] = v.replace("@I@", str(i)).replace("@PAD@", "x" * e.get("pad", 0))
                    self.wfile.write(b"data: " + json.dumps(ev).encode() + b"\n\n")
            else:
                self.wfile.write(b"data: " + json.dumps(sub(e)).encode() + b"\n\n")
            self.wfile.flush()


srv = http.server.ThreadingHTTPServer((LOOP, 0), H)
r = S.get("ready", "auto")
if r == "auto":
    print(json.dumps({"port": srv.server_address[1]}), flush=True)
elif isinstance(r, dict) and "port_of" in r:
    print(json.dumps({"port": r["port_of"]}), flush=True)
else:
    print(r, flush=True)
if not S.get("handoff"):
    srv.serve_forever()
    sys.exit(0)
# handoff: after the first turn, the agent closes its listener and a process outside its tree (double fork, own session) binds the same port
import threading
threading.Thread(target=srv.serve_forever, daemon=True).start()
while n[0] < 1:
    time.sleep(0.05)
time.sleep(0.3)
port = srv.server_address[1]
srv.shutdown(); srv.server_close()
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        time.sleep(0.2)
        S["dump"] = S.get("foreign_dump")
        f = http.server.ThreadingHTTPServer((LOOP, port), H)
        f.serve_forever()
    os._exit(0)
time.sleep(600)
