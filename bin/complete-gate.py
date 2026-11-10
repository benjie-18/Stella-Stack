#!/usr/bin/env python3
"""Complete gate (S3A-03, S3A-04; D66): Hermes pre_tool_call hook on kanban_complete for the roles whose hooks list it
(docs/hermes-local/roles.json; exit 2 = block). It names no profile, role, key or value: both rules read the caller's role row.
  1. complete_metadata (reviewing role, S3A-03): a kanban_complete must carry exactly these metadata pairs, e.g.
     {"review": "approved"}. bin/merge-card.sh merges only a card whose reviewing run completed with them, and a local-model reviewing worker wrote
     another key in 6 of 8 live completions by the reviewing role, so a merge-card run would refuse a card that is already done (S3A-03).
  2. complete_needs_review (builder role, S3A-04): a card whose Check line is a command is reviewed and completed by a reviewing
     role, never by its own builder (a code card reached done with no review, t_2e63cd37). A card that says
     `Check: none: <reason>` (a decision card) still completes. A missing or doubled Check line is check-guard's refusal, not this one.
Neither rule widens anything: this hook only adds refusals, the other guards on the tool still run.
Payload on stdin: {tool_name, tool_input: {task_id, metadata, ...}, session_id, cwd, profile}. Any error refuses."""
import json, os, re, sqlite3, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import roles

# shortcut: a copy of bin/check-guard.py CHECK, NONE and check_line (that file runs main() on import); complete-gate-selftest
# compares the two sources, so a drift fails the suite. Upgrade: move them into roles.py when check-guard next changes.
CHECK = re.compile(r"^[ \t]*check[ \t]*:(.*)$", re.I | re.A | re.M)   # strip afterwards: no lazy tail (RT12-08 ReDoS)
NONE = re.compile(r"none[ \t]*:[ \t]*(\S.*)", re.I)


def refuse(msg):
    print(json.dumps({"action": "block", "message": f"complete gate: {msg}"}))
    sys.exit(2)


def check_line(body):
    """The card's check: None (no line), ('many',), ('none', reason) or ('cmd', command)."""
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


def approval_evidence(profile, session_id, ev):
    """None when the profile's own session (read-only from its state.db) holds a call of ev["tool"] whose command matches ev["command"]
    and whose result exited ev.get("exit_code", 0) with output matching ev["output"]; else the refusal text. Any error refuses."""
    need = (f"approving needs this run's own evidence: a {ev['tool']} call matching /{ev['command']}/ whose answer matches /{ev['output']}/. "
            + str(ev.get("hint") or ""))
    if not isinstance(session_id, str) or not session_id:
        return f"{need}. No session id came with this call"
    row = (roles.load()["profiles"].get(profile) or {})
    root = os.environ.get("HERMES_ROOT") or os.path.join(roles.homes()[0], ".hermes")
    db = os.path.join(roles.pdir(root, profile, row), "state.db")
    try:
        c = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
        calls = {}
        for (tc,) in c.execute("select tool_calls from messages where session_id = ? and role = 'assistant' and tool_calls is not null", (session_id,)):
            for call in json.loads(tc):
                f = call.get("function") or {}
                if f.get("name") != ev["tool"]:
                    continue
                cmd = json.loads(f.get("arguments") or "{}").get("command")
                if isinstance(cmd, str) and re.search(ev["command"], cmd):
                    calls[call.get("call_id") or call.get("id")] = cmd
        for cid, content in c.execute("select tool_call_id, content from messages where session_id = ? and role = 'tool'", (session_id,)):
            if cid not in calls:
                continue
            try:
                r = json.loads(content)
            except ValueError:
                continue
            if isinstance(r, dict) and r.get("exit_code") == ev.get("exit_code", 0) and not r.get("error") \
                    and isinstance(r.get("output"), str) and re.search(ev["output"], r["output"]):
                return None
    except Exception as e:
        return f"{need}. The session store could not be read ({type(e).__name__})"
    return need + ". None was found in this session"


def main():
    p = json.load(sys.stdin)
    if p.get("tool_name") != "kanban_complete":
        return
    a = p.get("tool_input")
    if not isinstance(a, dict):
        refuse("unreadable tool arguments")
    try:
        d = roles.load()
    except roles.RolesError as e:
        roles.log_alert("STL-CFG-303", problem=str(e)[:300])
        refuse("[STL-CFG-303] the role table cannot be read, so kanban_complete is refused until it is fixed")
    profile = p.get("profile")
    _, role, _ = roles.role_of(d, profile)
    need = role.get("complete_metadata")
    if need:
        md = a.get("metadata")
        if not isinstance(md, dict) or any(md.get(k) != v for k, v in need.items()):
            refuse("completing a card is your verdict that the work is accepted, and the stack reads that verdict from the metadata. "
                   f"Call kanban_complete again with metadata exactly {json.dumps(need)} (your findings go in the summary). If the work "
                   "is not good enough, do not complete it: call kanban_request_changes with what must change")
    ev = ((d["profiles"].get(profile) if isinstance(profile, str) else None) or {}).get("approval_evidence")
    if ev:   # D100: this profile approves only on evidence in its own session (the profile row says which call and which answer)
        why = approval_evidence(profile, p.get("session_id"), ev)
        if why:
            refuse(why)
    if role.get("complete_needs_review"):
        j, why = roles.prove_card(profile, str(a.get("task_id") or ""), roles.board())
        if why:
            refuse(f"the stack could not prove this is a card's own worker run ({why}); if you are its worker this is a fault in "
                   "the stack, not a rule you broke: call kanban_block with kind needs_input and the reason "
                   "\"the stack could not identify this worker run\"")
        chk = check_line((j.get("task") or {}).get("body"))
        if chk and chk[0] == "cmd":
            refuse("a card with a `Check:` command is reviewed before it is done, and a reviewing role completes it, not you. "
                   "Call kanban_request_review naming a reviewing profile (the check guard confirms "
                   "on that call that your check ran). Only a card that says `Check: none: <reason>` is completed by its own worker")


try:
    main()
except SystemExit:
    raise
except Exception as e:  # fail closed: anything unexpected refuses
    refuse(f"internal error ({type(e).__name__}: {e}); the call is refused")
sys.exit(0)
