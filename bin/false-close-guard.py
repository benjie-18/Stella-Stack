#!/usr/bin/env python3
"""False-close guard: Hermes pre_tool_call hook on builder-local's kanban_complete (exit 2 = block).

A card may complete only if
  1. the worker's session ran `opencode run --standalone --auto ...` in the terminal tool and that call exited 0
     with non-empty output (read from the session store, not from what the worker claims);
  2. the evidence (metadata) has delegate_exit_code 0, a non-empty delegate_output, and a non-empty files_created;
  3. every file in files_created exists, OpenCode's own output names it, and no other tool call in the session
     wrote it (write_file/patch, or a terminal command with a write operator that mentions it).
Payload on stdin: {tool_name, tool_input: {task_id, summary, metadata}, session_id, cwd, profile}.
GUARD_STATE_DB overrides the session store path (tests).
"""
import json, os, pwd, re, sqlite3, sys

DELEGATE = "opencode run --standalone --auto"
# Workers often prefix `cd <worktree> &&`; nothing else may precede the delegate.
DELEGATE_RE = re.compile(r"^\s*(cd\s+\S+\s*&&\s*)?opencode run --standalone --auto\b")
WRITE_OPS = re.compile(r"(>|\btee\b|\bcp\b|\bmv\b|\btouch\b|\bsed\s+-i|\bdd\b|\binstall\b|\bprintf\b|\becho\b)")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def block(msg):
    print(json.dumps({"action": "block", "message": "false-close guard: " + msg}))
    sys.exit(2)


def session_calls(db, sid):
    """[(tool_name, args_dict, result_dict_or_text)] in order, paired by call id."""
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    calls, results = [], {}
    for role, tcid, tcs, content in con.execute(
            "select role, tool_call_id, tool_calls, content from messages where session_id=? order by rowid", (sid,)):
        if role == "tool" and tcid:
            try:
                results[tcid] = json.loads(content or "")
            except json.JSONDecodeError:
                results[tcid] = content or ""
        for tc in json.loads(tcs) if tcs else []:
            f = tc.get("function", tc)
            try:
                args = json.loads(f.get("arguments") or "{}")
            except json.JSONDecodeError:
                args = {}
            calls.append((f.get("name"), args, tc.get("call_id") or tc.get("id")))
    return [(name, args, results.get(cid)) for name, args, cid in calls]


def main():
    try:
        p = json.load(sys.stdin)
    except json.JSONDecodeError:
        block("unreadable hook payload")
    if p.get("tool_name") != "kanban_complete":
        return
    md = (p.get("tool_input") or {}).get("metadata") or {}
    sid = p.get("session_id") or ""
    # Workers run with a per-profile HOME, so `~` is not /home/node here: use HERMES_HOME, then the real home.
    real_home = pwd.getpwuid(os.getuid()).pw_dir
    tried = [os.environ.get("GUARD_STATE_DB"),
             os.path.join(os.environ["HERMES_HOME"], "state.db") if os.environ.get("HERMES_HOME") else None,
             os.path.join(real_home, ".hermes", "profiles", p.get("profile") or "builder-local", "state.db")]
    db = next((d for d in tried if d and os.path.exists(d)), None)
    if not sid or not db:
        block(f"cannot read the worker session ({sid or 'no session id'}); tried {[d for d in tried if d]}")
    calls = session_calls(db, sid)

    delegate = [(a, r) for n, a, r in calls if n == "terminal" and DELEGATE_RE.match(str(a.get("command", "")))]
    if not delegate:
        block(f"no terminal call to `{DELEGATE}` in this session; the delegate did not run")
    _, res = delegate[-1]
    res = res if isinstance(res, dict) else {}
    out = ANSI.sub("", str(res.get("output") or ""))
    if res.get("exit_code") != 0:
        block(f"last `{DELEGATE}` call exited {res.get('exit_code')!r}, not 0")
    if not out.strip():
        block("delegate produced no output")

    if md.get("delegate_exit_code") != 0:
        block(f"evidence delegate_exit_code is {md.get('delegate_exit_code')!r}, must be 0")
    if not str(md.get("delegate_output") or "").strip():
        block("evidence delegate_output is empty")
    files = md.get("files_created")
    if not isinstance(files, list) or not files:
        block("evidence files_created must list the files the delegate created")

    cwd = p.get("cwd") or os.getcwd()
    for f in files:
        path = f if os.path.isabs(f) else os.path.join(cwd, f)
        base = os.path.basename(f)
        if not os.path.exists(path):
            block(f"{f} does not exist")
        # OpenCode logs each file it writes as "← Write <path>"; any successful delegate call counts.
        if not any(re.search(r"\bWrite\b.*" + re.escape(base), ANSI.sub("", str(r.get("output") or "")))
                   for _, r in delegate if isinstance(r, dict) and r.get("exit_code") == 0):
            block(f"no successful OpenCode run shows `Write {f}`; it was not created by the delegate")
        for n, a, _ in calls:
            cmd = str(a.get("command", ""))
            if n in ("write_file", "patch") and base in json.dumps(a):
                block(f"{f} was written by the worker's own {n} call, not by the delegate")
            if n == "terminal" and not DELEGATE_RE.match(cmd) and base in cmd and WRITE_OPS.search(cmd):
                block(f"{f} was written by the worker's own terminal command: {cmd[:120]}")


if __name__ == "__main__":
    main()
