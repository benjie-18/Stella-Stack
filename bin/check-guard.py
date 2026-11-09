#!/usr/bin/env python3
"""Check guard (RU-01, D63): Hermes pre_tool_call hook on kanban_request_review and kanban_complete for the roles whose hooks list it
(docs/hermes-local/roles.json: the builder role; exit 2 = block).

A worker hands a card on only after it ran the card's own check. The dispatcher writes a line `Check: <command>` in the
card body (or `Check: none: <reason>`, which the reviewing role and the owner can read). This hook proves from the board and the
worker's session store, never from what the worker says, that
  1. the call is the card's own worker run (roles.prove_card, the one proof every hook uses);
  2. the body has exactly one Check line (a missing or doubled one is the dispatcher's omission: the worker blocks
     needs_input and asks);
  3. unless it says `none: <reason>`, the worker's session holds a foreground terminal call of exactly that command, run as
     `cd <worktree> &&` (a plain or single-quoted path equal to the card's worktree) or with the terminal's workdir equal to
     the worktree, exit code 0, output beyond the shell's locale warning, and no write_file, patch or delegate_task call
     after it (rows are read in timestamp order: Hermes re-stores old rows after a compaction).
The hook runs nothing itself: the command ran in the worker's own terminal, under the builder terminal guards.
The hook listens on kanban_complete as well as kanban_request_review: a builder may complete its own card, so the gate
must not be skippable by completing (RT12-01). A decision card says `Check: none: <reason>`.
Limits (shortcut, RT12): a terminal write after the check is not seen; a shell function or alias defined in an earlier
call, a script written to /tmp, or a direct write to the session store (D42 class, option A) can fake a pass; a command
that passes without testing anything is the dispatcher's check to get right. The reviewing role re-runs the check.
Payload on stdin: {tool_name, tool_input: {task_id, ...}, session_id, cwd, profile}.
GUARD_STATE_DB overrides the session store path (tests). Any error refuses."""
import json, os, pwd, re, shlex, sqlite3, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import roles

CHECK = re.compile(r"^[ \t]*check[ \t]*:(.*)$", re.I | re.A | re.M)   # strip afterwards: no lazy tail (RT12-08 ReDoS)
NONE = re.compile(r"none[ \t]*:[ \t]*(\S.*)", re.I)
ANSI = re.compile(r"\x1b\[[0-9;]*m")
NOISE = re.compile(r"^(?:\S*/)?bash: warning: setlocale.*$", re.M)   # every terminal result starts with it (RT12-07)
DIR = re.compile(r"[A-Za-z0-9_./-]+")   # a plain path: no ; | & $ quotes (RT12-03)
ASK = ("If the check cannot run here, call kanban_block with kind needs_input and say which part cannot run; "
       "do not request review without it.")


def refuse(msg):
    print(json.dumps({"action": "block", "message": f"check guard: {msg}"}))
    sys.exit(2)


def session_calls(db, sid):
    """[(tool_name, args_dict, result)] in order, paired by call id (copy of false-close-guard.session_calls)."""
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    calls, results = [], {}
    for role, tcid, tcs, content in con.execute(
            "select role, tool_call_id, tool_calls, content from messages where session_id=? order by timestamp, rowid", (sid,)):
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


def check_line(body):
    """The card's check: None (no line), ('none', reason) or ('cmd', command)."""
    found = CHECK.findall(body or "")
    if len(found) != 1:   # none, or several: an earlier planted line must not win (RT12-04)
        return ("many",) if found else None
    v = found[0].strip()
    if v[:1] == "`" and "`" in v[1:]:   # `cmd` (note): the first backticked span is the command (RT13-05)
        v = v[1:v.index("`", 1)].strip()
    if re.fullmatch(r"none[ \t]*:?", v, re.I):   # `none` without a reason is no check at all
        return None
    n = NONE.fullmatch(v)
    return ("none", n[1].strip()) if n else ("cmd", v) if v else None


def problem(body, calls, workspace):
    """Why the card may not go to review, or None. calls = session_calls output."""
    chk = check_line(body)
    if chk and chk[0] == "many":
        return ("the card body has more than one `Check:` line, so the stack cannot tell which one the dispatcher meant. That is the "
                "dispatcher's mistake: call kanban_block with kind needs_input and ask for one `Check:` line")
    if not chk:
        return ("the card has no `Check: <command>` line (or `Check: none: <reason>`), so there is nothing to run before review. "
                "That is the dispatcher's omission, not your mistake: call kanban_block with kind needs_input and the question "
                "\"What command shows this card's result works?\"")
    if chk[0] == "none":
        return None
    cmd = chk[1]
    pre = re.compile(r"cd\s+(?:(" + DIR.pattern + r")|'([^'\\]*)')\s*&&\s*" + re.escape(cmd))   # a quoted path: spaces, accents (RT13-04)
    hit = None
    for i, (name, a, res) in enumerate(calls):
        if name != "terminal" or not isinstance(a, dict) or a.get("background") or (isinstance(res, dict) and "pid" in res):
            continue   # a background start reports exit 0 without running the check to its end (RT12-02)
        c = str(a.get("command", "")).strip()
        m = pre.fullmatch(c)
        # the worktree itself, named by `cd <worktree> &&` or the workdir argument: the terminal keeps its folder between
        # calls, so a bare command may run in a subfolder holding a fake project (RT12-03)
        wd = os.path.normpath(m[1] or m[2]) if m else os.path.normpath(a["workdir"]) if c == cmd and isinstance(a.get("workdir"), str) and a["workdir"] else None
        if wd == workspace:
            hit = (i, res)
    if not hit:
        return (f"the card's check was not run in this session in the worktree. Run exactly `cd {shlex.quote(workspace)} && {cmd}` (a "
                f"foreground call), or set the terminal's workdir to {workspace} and run `{cmd}`; read its output, then request review. {ASK}")
    i, res = hit
    if not isinstance(res, dict):   # Hermes rewrites old results when it compacts the transcript (RT12-06)
        return (f"the stored result of the card's check `{cmd}` is unreadable (the transcript was compacted). Run `cd {shlex.quote(workspace)} && {cmd}` "
                "again, then request review.")
    if res.get("exit_code") != 0:
        return (f"the card's check `{cmd}` exited {res.get('exit_code')!r}, not 0. Fix what it shows, run it again until it "
                f"exits 0, then request review. {ASK}")
    if not NOISE.sub("", ANSI.sub("", str(res.get("output") or ""))).strip():
        return f"the card's check `{cmd}` printed nothing, so it shows nothing. Run it so that it prints what it checked. {ASK}"
    if any(n in ("write_file", "patch", "delegate_task") for n, _, _ in calls[i + 1:]):   # a child's writes are in its own session (RT13-02)
        return f"files changed after the card's check `{cmd}` ran. Run `cd {shlex.quote(workspace)} && {cmd}` again on the final files, then request review."
    return None


def main():
    p = json.load(sys.stdin)
    if p.get("tool_name") not in ("kanban_request_review", "kanban_complete"):
        return
    a = p.get("tool_input")
    if not isinstance(a, dict):
        refuse("unreadable tool arguments")
    profile, sid = p.get("profile"), p.get("session_id") or ""
    j, why = roles.prove_card(profile, str(a.get("task_id") or ""), roles.board())
    if why:
        refuse(f"the stack could not prove this is a card's own worker run ({why}); if you are its worker this is a fault in "
               "the stack, not a rule you broke: call kanban_block with kind needs_input and the reason "
               "\"the stack could not identify this worker run\"")
    task = j.get("task") or {}
    ws = os.path.normpath(str(task.get("workspace_path") or ""))
    if not ws.startswith("/"):
        refuse("the card has no worktree path on the board, so its check cannot be tied to it; call kanban_block with kind needs_input")
    real_home = pwd.getpwuid(os.getuid()).pw_dir
    tried = [os.environ["GUARD_STATE_DB"]] if os.environ.get("GUARD_STATE_DB") else [   # tests: the only store, a missing one refuses
        os.path.join(os.environ["HERMES_HOME"], "state.db") if os.environ.get("HERMES_HOME") else None,
        os.path.join(real_home, ".hermes", "profiles", profile, "state.db")
        if re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", str(profile or "")) else None]
    db = next((d for d in tried if d and os.path.exists(d)), None)
    if not sid or not db:
        refuse(f"cannot read the worker session ({sid or 'no session id'}), so the card's check cannot be confirmed; "
               "call kanban_block with kind needs_input")
    why = problem(task.get("body"), session_calls(db, sid), ws)
    if why:
        refuse(why)


try:
    main()
except SystemExit:
    raise
except Exception as e:  # fail closed: anything unexpected refuses
    refuse(f"internal error ({type(e).__name__}: {e}); the call is refused")
sys.exit(0)
