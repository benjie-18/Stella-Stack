#!/usr/bin/env python3
"""False-close guard: Hermes pre_tool_call hook on kanban_complete for every profile whose role and worker kind install it
(docs/hermes-local/roles.json: the builder role, worker kind opencode; D46) (exit 2 = block).

A card may complete only if
  1. the worker's session ran `opencode run --standalone --auto ...` in the terminal tool and that call exited 0
     with non-empty output (read from the session store, not from what the worker claims);
  2. the evidence (metadata) has delegate_exit_code 0, a non-empty delegate_output, and a non-empty files_created;
  3. every file in files_created exists, OpenCode's own output names it, and no other tool call in the session
     wrote it (write_file/patch, or a terminal command with a write operator that mentions it), unless that write was
     undone the way the refusal says: `git rm <file>`, then a successful OpenCode run that writes it again;
  4. no Windows path in the summary or metadata differs from the deliverable's, computed from the file paths (F4).
     delegate_output is not scanned: it is OpenCode's own text, not the worker's claim about where the deliverable is.
Every refusal says what to do next and that it is final for this attempt (F3).
Payload on stdin: {tool_name, tool_input: {task_id, summary, metadata}, session_id, cwd, profile}.
GUARD_STATE_DB overrides the session store path (tests).
"""
import json, os, pwd, re, sqlite3, sys, time

import owner_config  # bin/owner_config.py, next to this file (D39)

DELEGATE = "opencode run --standalone --auto"
# Workers often prefix `cd <worktree> &&`; nothing else may precede the delegate.
DELEGATE_RE = re.compile(r"^\s*(cd\s+\S+\s*&&\s*)?opencode run --standalone --auto\b")
WRITE_OPS = re.compile(r"(>|\btee\b|\bcp\b|\bmv\b|\btouch\b|\bsed\s+-i|\bdd\b|\binstall\b|\bprintf\b|\becho\b)")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
# What ends a path in prose: whitespace, surrounding punctuation, and the characters Windows forbids in a path.
PATH_END = r"\s\"'`,;)<>|?*"
# No letter or digit before the drive, and a first folder of 2+ characters: `Usage:\n` and `"a:\n\n"` are string escapes.
# shortcut: a wrong path whose first folder is one letter is not caught, tighten if a stack path ever has one.
WINPATH = re.compile(rf"(?<![A-Za-z0-9])[A-Za-z]:\\[^{PATH_END}\\]{{2,}}[^{PATH_END}]*")
FAILED_TWICE = "if OpenCode fails twice, call kanban_block once with kind capability and the error."
FINAL = " This refusal is final for this attempt: do not argue with it or ask anyone to override it."


def block(msg):
    print(json.dumps({"action": "block", "message": "false-close guard: " + msg.rstrip(".") + "." + FINAL}))
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


def windows(path):
    """The owner's Windows path (config/owner.env, D39) for a path under /workspace, else None."""
    path = os.path.normpath(path)
    if not path.startswith("/workspace/"):
        return None
    try:
        return owner_config.windows(owner_config.load(), path[len("/workspace/"):])
    except owner_config.OwnerConfigError as e:
        log = os.path.join(os.environ.get("ESCALATE_SUP_DIR") or "/workspace/.supervisor", "escalations.log")
        with open(log, "a") as f:
            f.write(json.dumps({"time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "card": "",
                                "event": "OWNER_CONFIG_MISSING", "detail": f"false-close guard: {e}"}) + "\n")
        block(f"OWNER_CONFIG_MISSING: {e}; the deliverable's Windows path cannot be computed. Report it with "
              f"kanban_block kind capability")


def strings(x):
    if isinstance(x, str):
        yield x
    elif isinstance(x, dict):
        for v in x.values():
            yield from strings(v)
    elif isinstance(x, list):
        for v in x:
            yield from strings(v)


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
             os.path.join(real_home, ".hermes", "profiles", p["profile"], "state.db")
             if re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", str(p.get("profile") or "")) else None]
    db = next((d for d in tried if d and os.path.exists(d)), None)
    if not sid or not db:
        block(f"cannot read the worker session ({sid or 'no session id'}); tried {[d for d in tried if d]}")
    calls = session_calls(db, sid)

    delegate = [(i, a, r) for i, (n, a, r) in enumerate(calls)
                if n == "terminal" and DELEGATE_RE.match(str(a.get("command", "")))]
    if not delegate:
        block(f"no terminal call to `{DELEGATE}` in this session; the delegate did not run. "
              f"Run `{DELEGATE} '<instruction>'` in your worktree; {FAILED_TWICE} "
              "If the card has no code or files for OpenCode to produce (a `Check: none` card), this worker cannot complete it and "
              "the guard is not wrong: call kanban_block once with kind capability and ask for it to be reassigned to a worker that "
              "does not delegate to OpenCode (S3A-06)")
    _, _, res = delegate[-1]
    res = res if isinstance(res, dict) else {}
    out = ANSI.sub("", str(res.get("output") or ""))
    if res.get("exit_code") != 0:
        block(f"last `{DELEGATE}` call exited {res.get('exit_code')!r}, not 0. Run it again with a short, plain "
              f"instruction; {FAILED_TWICE}")
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
    want = set()
    for f in files:
        path = f if os.path.isabs(f) else os.path.join(cwd, f)
        base = os.path.basename(f)
        if not os.path.exists(path):
            block(f"{f} does not exist")
        want.add(windows(path))
        # OpenCode logs each file it writes as "← Write <path>"; the indices of successful delegate calls that did.
        wrote = [i for i, _, r in delegate if isinstance(r, dict) and r.get("exit_code") == 0
                 and re.search(r"\bWrite\b.*" + re.escape(base), ANSI.sub("", str(r.get("output") or "")))]
        if not wrote:
            block(f"no successful OpenCode run shows `Write {f}`; it was not created by the delegate. "
                  f"Run `{DELEGATE} '<instruction>'` so OpenCode writes it; {FAILED_TWICE}")
        own = [(i, n, str(a.get("command", ""))) for i, (n, a, _) in enumerate(calls)
               if (n in ("write_file", "patch") and base in json.dumps(a))
               or (n == "terminal" and not DELEGATE_RE.match(str(a.get("command", "")))
                   and base in str(a.get("command", "")) and WRITE_OPS.search(str(a.get("command", ""))))]
        if own:
            last, n, cmd = own[-1]
            rm = [i for i, (m, a, _) in enumerate(calls) if i > last and m == "terminal"
                  and re.search(r"\bgit\s+rm\b.*" + re.escape(base), str(a.get("command", "")))]
            if not (rm and any(i > rm[0] for i in wrote)):
                block(f"{f} was written outside OpenCode by your own {n} call{': ' + cmd[:120] if cmd else ''}. "
                      f"Next: `git rm {base}` and commit, then run `{DELEGATE} '<instruction>'` again so OpenCode "
                      f"writes it; {FAILED_TWICE}")

    want.discard(None)
    shown = ", ".join(sorted(want)) or "container-only (outside /workspace)"
    # The deliverable's paths go first, whole and in any case (Windows paths are case-insensitive): free text cannot show
    # where a path with a space ends. A longer name that only starts with one is not removed, so it is still refused.
    known = re.compile(r"(?<![A-Za-z0-9])(?:" + ("|".join(map(re.escape, sorted(want, key=len, reverse=True))) or "(?!)")
                       + rf")[.:]*(?![^{PATH_END}])", re.I)
    claims = {k: v for k, v in md.items() if k != "delegate_output"}
    for text in strings([p.get("tool_input", {}).get("summary"), claims]):
        if "/mnt/c/" in text.lower():
            block(f"a /mnt/c/ path is not a Windows path. The deliverable's Windows path is {shown}.")
        if m := WINPATH.search(known.sub(" ", text)):
            block(f"{m.group().rstrip('.:')} is not the deliverable's Windows path; it is {shown}. "
                  "Correct or remove it in the summary and metadata, then call kanban_complete again")


if __name__ == "__main__":
    main()
