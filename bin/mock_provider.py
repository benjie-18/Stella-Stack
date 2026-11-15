#!/usr/bin/env python3
"""Mock model server for tests (F2 test rig), stdlib only. Serves every shape of .stella/protocols.json (under STELLA_ROOT) on the
path prefix /<shape id>, and a model list per shape. Nothing here names a shape, a model or a trigger beyond the fault ids.
First stdout line: {"port": N, "control": URL}. POST the control document to that URL (it replaces models and faults; call counts stay):
  {"models": {shape: [model ids]}, "faults": [{"shape", "model", "fault", "calls"?, "seconds"?, "tokens"?}]}
faults: rate_limit daily_cap server_error model_gone context_too_small (the shape's own error row for that trigger),
timeout (no answer for `seconds`), malformed_tool_call (200 with a tool call whose arguments do not parse).
A fault with "calls" fires that many times, without it until a new document. GET /_calls: {"counts": {"shape/model": n},
"requests": [{"shape", "model", "headers", "body"}]}. The protocols file is read on every call: a new shape needs no restart.
shortcut: state lives in memory and the control is a URL only (no control file), upgrade if a test must set faults before start."""
import http.server, json, os, re, socket, sys, threading, time

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import stella_data as sd

REL = ".stella/protocols.json"
LOCK = threading.Lock()
STATE = {"models": {}, "faults": [], "counts": {}, "requests": []}


def shapes():
    return {e["id"]: e for e in sd.checked(sd.load(REL), REL, "protocols")["entries"]}


def render(v, ctx):
    if isinstance(v, str):
        return ctx["max_tokens"] if v == "{max_tokens}" else v.replace("{model}", ctx["model"])
    if isinstance(v, list):
        return [render(x, ctx) for x in v]
    if isinstance(v, dict):
        return {k: render(x, ctx) for k, x in v.items()}
    return v


def setptr(doc, ptr, val):
    """Put val at the RFC 6901 pointer, making dicts and lists on the way (a number segment makes a list)."""
    parts = [p.replace("~1", "/").replace("~0", "~") for p in ptr.split("/")[1:]]
    cur = doc
    for i, p in enumerate(parts):
        last = i == len(parts) - 1
        nxt = None if last else ([] if parts[i + 1].isdigit() else {})
        if isinstance(cur, list):
            n = int(p)
            cur.extend([None] * (n + 1 - len(cur)))
            if last:
                cur[n] = val
            else:
                cur[n] = cur[n] if cur[n] is not None else nxt
            cur = cur[n]
        else:
            if last:
                cur[p] = val
            else:
                cur = cur.setdefault(p, nxt)


PATH_ID, BODY_ID = "([^/:?]+)", "(.+)"   # a model id in a path stops at / : ?, in a body it is any text (ids hold : and /)


def model_of(tmpl, actual, pat=BODY_ID):
    """The text a {model} placeholder stands for, found by walking the template beside the real value; None when there is none."""
    if isinstance(tmpl, str):
        if "{model}" in tmpl and isinstance(actual, str):
            m = re.fullmatch(re.escape(tmpl).replace(re.escape("{model}"), pat), actual)
            return m.group(1) if m else None
    elif isinstance(tmpl, list) and isinstance(actual, list):
        for t, a in zip(tmpl, actual):
            if (r := model_of(t, a)) is not None:
                return r
    elif isinstance(tmpl, dict) and isinstance(actual, dict):
        for k, t in tmpl.items():
            if k in actual and (r := model_of(t, actual[k])) is not None:
                return r
    return None


def status_of(spec):
    """A status to answer for a status spec of errors[]: an integer, [lo, hi], "5xx", "500-599"."""
    if isinstance(spec, int):
        return spec
    if isinstance(spec, list):
        return spec[0]
    m = re.match(r"(\d)xx$", spec.strip().lower())
    return int(m[1]) * 100 if m else int(re.match(r"\d+", spec)[0])


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, status, doc):
        raw = doc if isinstance(doc, str) else json.dumps(doc)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw.encode())))
        self.end_headers()
        self.wfile.write(raw.encode())

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/_calls":
            with LOCK:
                return self.send(200, {"counts": STATE["counts"], "requests": STATE["requests"]})
        shape, e, rest = self.shape(path)
        if e is None or rest != e["models_path"]:
            return self.send(404, {"error": "no such path"})
        ml = e["models_list"]
        with LOCK:
            gone = {f["model"] for f in STATE["faults"] if f["shape"] == shape and f["fault"] == "model_gone" and f["left"] != 0}
            ids = [m for m in STATE["models"].get(shape, []) if m not in gone]
        doc = {}
        setptr(doc, ml["items"], [{ml["field"]: ml["prefix"] + m} for m in ids])
        self.send(200, doc)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode("utf-8", "replace")
        if self.path == "/_control":
            try:
                d = json.loads(raw)
                faults = [dict(f, left=f.get("calls", -1)) for f in d.get("faults", [])]
                for f in faults:
                    if not all(isinstance(f.get(k), str) and f[k] for k in ("shape", "model", "fault")) or \
                       not all(isinstance(f.get(k, 0), (int, float)) and not isinstance(f.get(k, 0), bool) for k in ("calls", "seconds", "tokens")):
                        return self.send(400, {"error": "each fault needs a shape, a model and a fault (text), and calls, seconds, tokens only as numbers"})
                models = {k: list(v) for k, v in d.get("models", {}).items()}
            except (ValueError, AttributeError, TypeError):
                return self.send(400, {"error": "bad control document"})
            with LOCK:
                STATE.update(models=models, faults=faults)   # counts survive a new document
            return self.send(200, {"ok": True})
        shape, e, rest = self.shape(self.path.split("?")[0])
        if e is None:
            return self.send(404, {"error": "no such shape"})
        try:
            body = json.loads(raw)
        except ValueError:
            body = raw
        rq = e["request"]
        m = re.fullmatch(re.escape(rq["path"]).replace(re.escape("{model}"), PATH_ID), rest)
        model = (m.group(1) if m and "{model}" in rq["path"] else None) or model_of(rq["body"], body) or ""
        key = f"{shape}/{model}"
        with LOCK:
            STATE["counts"][key] = STATE["counts"].get(key, 0) + 1
            STATE["requests"].append({"shape": shape, "model": model, "headers": dict(self.headers), "body": body})
            f = self.pick(shape, model, len(raw) // 4) if m else None
            served = model in STATE["models"].get(shape, [])
        if not m:   # counted and recorded above, like every call
            return self.send(404, {"error": "no such path"})
        if f is None and not served:
            f = {"fault": "model_gone"}   # a model nobody serves is gone
        fault = f and f["fault"]
        if fault == "timeout":
            time.sleep(float(f.get("seconds", 30)))
            self.close_connection = True
            return
        if fault in (None, "malformed_tool_call"):
            return self.send(200, self.answer(e, model, fault))
        row = next((x for x in e["errors"] if x["trigger"] == fault), None)
        if row is None:
            return self.send(500, {"error": f"{fault}: this shape has no error row for it"})
        self.send(status_of(row["status"]), row.get("sample_body") or json.dumps({"error": fault}))

    def shape(self, path):
        """(shape id, its entry, the path under its prefix); entry None when the first path segment is no shape."""
        head, _, tail = path[1:].partition("/")
        try:
            e = shapes().get(head)
        except sd.DataError:
            e = None
        return head, e, "/" + tail

    def pick(self, shape, model, tokens):
        """The first fault that fires for this call (caller holds LOCK); a firing one with calls left loses one."""
        for f in STATE["faults"]:
            if f["shape"] == shape and f["model"] == model and f["left"] != 0:
                if f["fault"] == "context_too_small" and tokens <= f.get("tokens", 0):
                    continue
                f["left"] -= 1 if f["left"] > 0 else 0
                return f
        return None

    def answer(self, e, model, fault):
        r = e["response"]
        doc = {}
        setptr(doc, r["text"], "ok")
        setptr(doc, r["model"], model)
        k = r.get("usage_keys") or ["input_tokens", "output_tokens"]
        setptr(doc, r["usage"], {k[0]: 1, k[1]: 1})
        if fault == "malformed_tool_call":
            sample = json.dumps(r.get("tool_calls_sample", {"arguments": "{arguments}"}))
            setptr(doc, r["tool_calls"], json.loads(sample.replace("{arguments}", "{not json")))
        return doc


def main():
    try:
        shapes()
    except sd.DataError as x:   # a broken protocols file: say so with the data tool's code and message, do not serve
        sd.say("STL-CFG-310", str(x))
        sys.exit(1)
    host = socket.inet_ntoa(b"\x7f\x00\x00\x01")   # the loopback address, built so no host name is written in the code
    srv = http.server.ThreadingHTTPServer((host, 0), H)
    srv.daemon_threads = True
    port = srv.server_address[1]
    print(json.dumps({"port": port, "control": f"http://{host}:{port}/_control"}), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
