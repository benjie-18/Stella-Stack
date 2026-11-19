#!/usr/bin/env python3
"""A fake coding CLI for tests (F3 item A, design 3b), stdlib only. It runs the action list of its prompt file and prints jsonl.
  mock_agent.py --prompt-file F --config C [--model M] [--mcp-config J] [--cwd W]      mock_agent.py --version
Actions: a JSON list between the prompt lines BEGIN-ACTIONS and END-ACTIONS (the rest of the prompt is ignored):
  write {path, text} | read {path} | read_notes {path} | edit {path, old, new} | shell {cmd} (bash, in the worktree, with this
  process's environment) | mcp {tool, args} (JSON-RPC tools/call to the server the --mcp-config file names, with its headers) |
  model_call {prompt} (to the base URL and with the token of the variables its adapters.json entry names, in the entry's first wire
  shape) | env | usage {input, output} | say {text} | repeat {times, actions}.
Any action may carry "step": ID; it is skipped (nothing emitted) when a read_notes before it showed "- ID" under the notes heading "done".
Its adapters.json entry is the one the adapter's run_env.adapter variable names. Before a write, edit, read or shell it applies its
--config the way the entry's policy says: a map pointer or a list item "Tool(pattern)" judges the action when it names a tool of
the action's class in some adapter's tool map (the last matching map pattern decides; any matching list item denies); a write
also meets the entry's write_boundary map pointers; when the config holds a hook at the entry's hook pointer whose matcher takes
the action, the hook command runs with {tool, input, tool_name, tool_input, cwd} on stdin (exit 2, or a "deny" value in its JSON
answer, denies). A denied action prints a tool_result with ok false and "denied" in its output and is not done.
Output: {"type":"tool_use","name","input"} {"type":"tool_result","name","ok","output"[,"error" when not ok]} {"type":"usage","input_tokens","output_tokens"}
{"type":"result","text","exit":0}. Exit 0, or 1 when an action crashes.
shortcut: pattern semantics are fnmatch on the raw and the absolute value, not each CLI's own; enough for a fake, not a CLI model."""
import argparse, fnmatch, http.client, json, os, re, subprocess, sys, urllib.parse

VERSION = "0.3.0"
BIN = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.realpath(os.environ.get("STELLA_ROOT") or os.path.dirname(BIN))
OUT_CAP = 1 << 20


def emit(o):
    print(json.dumps(o), flush=True)


def get(doc, ptr):
    for p in [x.replace("~1", "/").replace("~0", "~") for x in ptr.split("/")[1:]] if ptr else []:
        if isinstance(doc, dict) and p in doc:
            doc = doc[p]
        elif isinstance(doc, list) and p.isdigit() and int(p) < len(doc):
            doc = doc[int(p)]
        else:
            return None
    return doc


def load(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return json.load(f)


class Ctx:
    def __init__(self, a):
        self.cwd = os.path.realpath(a.cwd or os.getcwd())
        self.model = a.model
        self.config = json.load(open(a.config, encoding="utf-8")) if a.config else {}
        self.mcp = json.load(open(a.mcp_config, encoding="utf-8")) if a.mcp_config else {}
        try:
            doc = load(".stella/adapters.json")
        except (OSError, ValueError):
            doc = {}
        self.ads = doc.get("entries", [])
        var = (doc.get("run_env") or {}).get("adapter")
        self.ent = next((e for e in self.ads if var and e.get("id") == os.environ.get(var)), {})


def names_of(ctx, cls):
    return {n.casefold() for e in ctx.ads for n, t in (e.get("tools") or {}).items() if t.get("class") == cls}


def denied(ctx, op, inp):
    spec = (ctx.ent.get("tools") or {}).get(op)
    if not spec or spec.get("class") == "other":
        return None
    cls = spec["class"]
    raw = str(get(inp, spec.get("command") if cls == "shell" else spec.get("path")) or "")
    vals = [raw] if cls == "shell" else [raw, os.path.realpath(os.path.join(ctx.cwd, os.path.expanduser(raw)))]
    pol = ctx.ent.get("policy") or {}
    names = names_of(ctx, cls)
    bound = {s["pointer"] for s in (pol.get("shapes") or {}).get("write_boundary", [])}
    hit = lambda pat: any(fnmatch.fnmatchcase(v, os.path.expanduser(pat.replace("//", "/", 1) if pat.startswith("//") else pat)) for v in vals)
    for ptr in (pol.get("target") or {}).get("owned_pointers", []):
        node = get(ctx.config, ptr)
        last = ptr.rsplit("/", 1)[-1].casefold()
        if isinstance(node, dict) and (last in names or (cls == "write" and ptr in bound)):
            verdict = None
            for pat, v in node.items():
                if isinstance(v, str) and hit(pat):
                    verdict = v
            if verdict == "deny":
                return f"{ptr} denies {raw}"
        elif isinstance(node, list):
            for item in node:
                m = re.fullmatch(r"(\w+)\((.*)\)", item) if isinstance(item, str) else None
                if m and m[1].casefold() in names and hit(m[2]):
                    return f"{ptr} denies {raw} ({item})"
    hook = pol.get("hook") or {}
    for h in get(ctx.config, hook.get("pointer", "")) or [] if hook else []:
        if not isinstance(h, dict) or not re.search(h.get("matcher") or "", op):
            continue
        for c in [x.get("command") for x in h.get("hooks", []) if isinstance(x, dict)] or [h.get("command")]:
            if not c:
                continue
            pay = json.dumps({"tool": op, "input": inp, "tool_name": op, "tool_input": inp, "cwd": ctx.cwd})
            r = subprocess.run(c, shell=True, input=pay, capture_output=True, text=True, cwd=ctx.cwd)
            try:
                ans = json.loads(r.stdout or "null")
            except ValueError:
                ans = None
            if r.returncode == 2 or "deny" in leaves(ans):
                return f"the hook denies {raw}"
    return None


def leaves(x):
    if isinstance(x, dict):
        return [y for v in x.values() for y in leaves(v)]
    if isinstance(x, list):
        return [y for v in x for y in leaves(v)]
    return [x]


def post(url, headers, body, timeout=60):
    u = urllib.parse.urlsplit(url)
    c = (http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection)(u.hostname, u.port, timeout=timeout)
    try:
        c.request("POST", (u.path or "/") + ("?" + u.query if u.query else ""), body=json.dumps(body).encode(),
                  headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream", **headers})
        r = c.getresponse()
        return r.status, r.read(OUT_CAP).decode("utf-8", "replace")
    finally:
        c.close()


def server(doc):
    """The first object of the MCP config that has a url (and its headers)."""
    if isinstance(doc, dict):
        if isinstance(doc.get("url"), str):
            return doc
        doc = list(doc.values())
    for v in doc if isinstance(doc, list) else []:
        s = server(v)
        if s:
            return s
    return None


def fill(t, v):
    if isinstance(t, str):
        m = re.fullmatch(r"\{(\w+)\}", t)
        return v[m[1]] if m and m[1] in v else re.sub(r"\{(\w+)\}", lambda m: str(v.get(m[1], m[0])), t)
    if isinstance(t, list):
        return [fill(x, v) for x in t]
    if isinstance(t, dict):
        return {k: fill(x, v) for k, x in t.items()}
    return t


def done_steps(text):
    """The list items ("- ID") under a "done" heading (any level, any case) of a notes file, up to the next heading."""
    out, on = set(), False
    for ln in text.splitlines():
        h = re.match(r"#+\s*(.*?)\s*$", ln)
        if h:
            on = h[1].casefold() == "done"
        elif on and ln.startswith("- "):
            out.add(ln[2:].strip())
    return out

def act(ctx, a):
    op = a.get("op")
    inp = {k: v for k, v in a.items() if k != "op"}
    if op == "repeat":
        for _ in range(int(a.get("times", 1))):
            for x in a.get("actions", []):
                act(ctx, x)
        return
    if op == "usage":
        emit({"type": "usage", "input_tokens": int(a.get("input", 0)), "output_tokens": int(a.get("output", 0))})
        return
    if a.get("step") in getattr(ctx, "done", ()):   # a step the notes read earlier list as done is not done again (resume)
        return
    emit({"type": "tool_use", "name": op, "input": inp})
    why = denied(ctx, op, inp) if op in ("write", "edit", "read", "read_notes", "shell") else None
    if why:
        emit({"type": "tool_result", "name": op, "ok": False, "output": f"denied: {why}", "error": f"denied: {why}"})
        return
    path = os.path.join(ctx.cwd, os.path.expanduser(str(a.get("path", ""))))
    ok, out = True, ""
    try:
        if op == "write":
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(str(a.get("text", "")))
            out = f"wrote {a['path']}"
        elif op in ("read", "read_notes"):
            with open(path, encoding="utf-8", errors="replace") as f:
                out = f.read(OUT_CAP)
            if op == "read_notes":
                ctx.done = getattr(ctx, "done", set()) | done_steps(out)
        elif op == "edit":
            with open(path, encoding="utf-8") as f:
                text = f.read()
            ok = a["old"] in text
            if ok:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(text.replace(a["old"], a["new"], 1))
            out = f"edited {a['path']}" if ok else f"{a['old']!r} is not in {a['path']}"
        elif op == "shell":
            r = subprocess.run(["bash", "-c", str(a["cmd"])], cwd=ctx.cwd, capture_output=True, text=True, errors="replace")
            ok, out = r.returncode == 0, (r.stdout + r.stderr)[-OUT_CAP:]
        elif op == "env":
            out = "\n".join(f"{k}={v}" for k, v in sorted(os.environ.items()))
        elif op == "say":
            out = str(a.get("text", ""))
        elif op == "mcp":
            s = server(ctx.mcp)
            if not s:
                ok, out = False, "the MCP config names no server"
            else:
                st, out = post(s["url"], s.get("headers") or {}, {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                   "params": {"name": a.get("tool"), "arguments": a.get("args") or {}}})
                ok = st == 200 and '"isError": true' not in out and '"error"' not in out
        elif op == "model_call":
            env = (ctx.ent.get("start") or {}).get("env") or {}
            base, tok = os.environ.get(env.get("base_url_env") or ""), os.environ.get(env.get("token_env") or "")
            protos = {p["id"]: p for p in load(".stella/protocols.json")["entries"]}
            rq = protos[(ctx.ent.get("protocols") or [None])[0]]["request"]
            if not base or not tok:
                ok, out = False, "no base URL or token in the environment"
            else:
                v = {"model": ctx.model or "", "prompt": str(a.get("prompt", "")), "max_tokens": 16, "key": tok}
                st, out = post(base.rstrip("/") + fill(rq["path"], v), fill(rq.get("headers") or {}, v), fill(rq.get("body") or {}, v))
                ok = st == 200
        else:
            ok, out = False, f"unknown op {op!r}"
    except (OSError, KeyError, ValueError, http.client.HTTPException) as e:
        ok, out = False, f"{type(e).__name__}: {e}"
    emit({"type": "tool_result", "name": op, "ok": ok, "output": out, **({} if ok else {"error": out})})


def main(argv):
    if argv == ["--version"]:
        print(f"mock-agent {VERSION}")
        return 0
    ap = argparse.ArgumentParser(prog="mock_agent.py")
    for k in ("prompt-file", "config"):
        ap.add_argument("--" + k, required=True)
    for k in ("model", "mcp-config", "cwd"):
        ap.add_argument("--" + k)
    a = ap.parse_args(argv)
    ctx = Ctx(a)
    lines = open(a.prompt_file, encoding="utf-8").read().splitlines()
    s = [ln.strip() for ln in lines]
    acts = json.loads("\n".join(lines[s.index("BEGIN-ACTIONS") + 1:s.index("END-ACTIONS")])) if "BEGIN-ACTIONS" in s else []
    for x in acts:
        act(ctx, x)
    emit({"type": "result", "text": "done", "exit": 0})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
