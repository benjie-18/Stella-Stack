#!/usr/bin/env python3
"""Role guard (D46): fail-closed pre_tool_call hook in every profile, on kanban_create, kanban_complete, kanban_unblock,
kanban_claim and delegate_task. It reads the role table (bin/roles.py) and names no profile, model or display name.
  1. A tool the caller's role may not use is refused (may_create_cards, may_complete, may_unblock, may_claim,
     may_delegate). A profile with no row in roles.json gets fallback_role, which opens nothing (STL-CFG-303).
  2. kanban_complete only from the card's own worker run (D48): the caller is the card's assignee, and the card's open run
     is bound (worker_bound event, same claim lock) to a process among the hook's ancestors with the recorded start
     time. The ids in HERMES_KANBAN_* are not used: the bound interpreter sets them after it starts, so its /proc file
     does not show them, and Hermes strips them from hooks.
     Anything unproven is refused with STL-GRD-601 naming the proof that failed, and one alerts.log line; the owner
     completes a stuck card from the CLI, which runs no hooks.
  3. kanban_create only for a valid card: an assignable assignee; the workspace its role needs (git-worktree: a project
     bound to the board, workspace_kind worktree, no workspace_path; read-parent-worktree: a parent card's worktree); no
     model or provider override its role does not allow; no path into the stack's configuration (the write guard's
     protected list) or a main checkout; no request to change the creator's own configuration (a configuration kind
     next to its role, profile or display name). The board's projects come from Hermes's projects.db, read at call
     time; unreadable = refused (STL-GRD-602).
  4. kanban_comment (A1-01): a role without `may_answer_for_owner` (listed or not), or a profile with no row, names no other card than its own proven
     running card (roles.prove_card). Hermes itself rejects a call without task_id, so the guard lets that through.
Exit 2 + block JSON refuses; any error refuses."""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import roles

GATED = {"kanban_create": "may_create_cards", "kanban_complete": "may_complete", "kanban_unblock": "may_unblock",
         "kanban_claim": "may_claim", "delegate_task": "may_delegate"}
VERB = {"may_create_cards": "create cards", "may_complete": "complete cards", "may_unblock": "unblock cards",
        "may_claim": "claim cards", "may_delegate": "delegate to subagents"}
INSTEAD = {"may_create_cards": "hand the card on with kanban_request_review, or note follow-up work with kanban_comment",
           "may_complete": "a card is completed by its own worker run, or by the escalation flow",
           "may_unblock": "a blocked card is unblocked by the owner's reply in its #escalations thread",
           "may_claim": "the dispatcher claims cards for their workers",
           "may_delegate": "put the work on a card for a worker with kanban_create"}
# A path token: ~, $HOME or / at the start of a word (after space, quote, =, ( or :).
PATH = re.compile(r"(?:^|(?<=[\s'\"`=(:,]))((?:~|\$HOME|\$\{HOME\})(?:/[^\s'\"`<>|;&(),]*)?|/[^\s'\"`<>|;&(),]+)")


def refuse(msg):
    print(json.dumps({"action": "block", "message": f"role guard: {msg}"}))
    sys.exit(2)


def inside(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def complete_problem(d, a, profile, b):
    """Why this kanban_complete is not the card's own worker run, or None. The caller is proven from the board and the
    kernel (roles.prove_card, the one proof every hook uses), never from anything it says: the card is assigned to the
    caller's profile, its role may complete, and the card's open run is bound to a process among the hook's ancestors.
    Hermes writes the binding; the model cannot move its hook under another worker. Without a task_id the call means the
    profile's own running card."""
    j, why = roles.prove_card(profile, str(a.get("task_id") or ""), b)
    task = (j or {}).get("task") or {}
    card, assignee = task.get("id") or str(a.get("task_id") or ""), task.get("assignee")
    if not re.fullmatch(r"t_[0-9a-f]{8}", card):   # RT4-13: a made-up id never reaches the log, a page or the dedupe key
        card = "not a card id" if card else ""
    if j and assignee != profile:
        return (f"kanban_complete refused: card {card} is assigned to {assignee}, and only its own worker completes "
                "it. Use kanban_comment on your own card to hand over information")
    if j and not roles.role_of(d, assignee)[1]["may_complete"]:
        return f"kanban_complete refused: the role of card {card}'s assignee does not complete cards"
    if not why:
        return None
    roles.log_alert("STL-GRD-601", streak=roles.streak(j), card=card or "?", missing=why, profile=str(profile))
    if j and any(r.get("ended_at") is None for r in j.get("runs") or []):   # K2: its own open run, unproven: the stack's fault
        return (f"[STL-GRD-601] kanban_complete refused: the stack could not prove this is card {card}'s own worker run "
                f"({why}). If you are its worker, this is a fault in the stack, not a rule you broke: the owner has been "
                "alerted. Stop and call kanban_block with kind needs_input and the reason \"STL-GRD-601: the stack could not "
                "identify this worker run\"")
    named = f"card {card}" if card.startswith("t_") else "the given task id (not a card id)" if card else "this card"
    return (f"[STL-GRD-601] kanban_complete refused: this call is not {named}'s own worker run ({why}). "
            "The card's worker completes it; the owner can complete a stuck card from the CLI (SUPERVISOR.md)")


def paths(text):
    """Every absolute path a title or body names, with ~ and $HOME expanded for each home."""
    out = []
    for tok in PATH.findall(text):
        tok = tok.rstrip(".:")
        m = re.match(r"(?:~|\$HOME|\$\{HOME\})(/.*)?$", tok)
        out += [os.path.normpath(h + (m[1] or "")) for h in roles.homes()] if m else [os.path.normpath(tok)]
    return out


def create_problems(d, a, profile, b):
    prof_rows = d["profiles"]
    workers = sorted(p for p, row in prof_rows.items() if d["roles"][row["role"]]["assignable"])
    assignee = a.get("assignee")
    row = prof_rows.get(assignee) if isinstance(assignee, str) else None
    if not row or not d["roles"][row["role"]]["assignable"]:
        return [f"assignee {assignee!r} is not an assignable worker. Valid assignees: {', '.join(workers)}"]
    arole = d["roles"][row["role"]]
    if row.get("review_callers") is not None and roles.role_of(d, profile)[0] not in row["review_callers"]:   # D101
        return [f"assignee {assignee!r} may only be assigned by the roles {', '.join(row['review_callers'])} (the owner's setting, "
                "review_callers): it is reached through the review flow"]
    try:
        projects = roles.board_projects(a.get("board") or b)
    except Exception as e:
        roles.log_alert("STL-GRD-602", board=str(a.get("board") or b), error=f"{type(e).__name__}: {e}"[:300])
        return [f"[STL-GRD-602] the projects bound to board {a.get('board') or b} cannot be read, so no card is created "
                "now; try again later"]
    repos = sorted({p["repo"] for p in projects if p["repo"]} | {roles.ROOT})
    probs, parent_wts = [], []
    kind, wpath = a.get("workspace_kind") or "scratch", a.get("workspace_path")
    if arole["workspace"] == "git-worktree":
        if kind != "worktree":
            probs.append("set workspace_kind to worktree")
        if wpath:
            probs.append("remove workspace_path (Hermes makes the card's own worktree)")
        if a.get("project") not in {p["slug"] for p in projects} | {p["id"] for p in projects}:
            probs.append(f"set project to one of: {', '.join(sorted(p['slug'] for p in projects)) or '(none bound to this board)'}")
    elif arole["workspace"] == "read-parent-worktree":
        parents = [p for p in a.get("parents") or [] if isinstance(p, str) and re.fullmatch(r"t_[0-9a-f]{8}", p)]
        parent_wts = [f"{r}/.worktrees/{p}" for r in repos for p in parents]
        if not wpath or os.path.normpath(str(wpath)) not in parent_wts:
            probs.append("set workspace_path to the worktree of a card listed in parents (<repo>/.worktrees/<parent id>)")
    present = [k for k in roles.OVERRIDES if a.get(k)]
    bad = [k for k in present if k not in arole["allowed_overrides"]]
    if bad:
        probs.append(f"remove {' and '.join(bad)} (the assignee's role takes no such override)")
    text = f"{a.get('title') or ''}\n{a.get('body') or ''}"
    repo_prot, home_prot = roles.protected(d)
    for p in paths(text):
        if any(inside(p, x) for x in repo_prot + home_prot):
            probs.append(f"remove {p}: it is the stack's own configuration (protected)"); break
        if any(inside(p, r) for r in repos) and not any(inside(p, w) for w in parent_wts):
            probs.append(f"remove {p}: it is in a main checkout or another card's worktree; use paths relative to the "
                         "card's own worktree"); break
    me = {profile, roles.role_of(d, profile)[0], (prof_rows.get(profile) or {}).get("display_name")} - {None, ""}
    low = text.lower()
    kinds = [k for k in d.get("self_config_kinds", []) if re.search(rf"\b{re.escape(k)}\b", low)]
    if kinds and any(re.search(rf"\b{re.escape(m.lower())}\b", low) for m in me):
        probs.append(f"the card asks to change your own configuration ({kinds[0]}); that is the owner's change, ask the "
                     "owner instead")
    return probs


def review_by_card(d, p, a, named, callers):
    """D101: True when the owner's setting lists "card" and this is the caller's own proven running card whose body, written by whoever
    created the card (never a worker), has a line `Review-by: <named>`."""
    if "card" not in callers:
        return False
    j, why = roles.prove_card(p.get("profile"), str(a.get("task_id") or ""), roles.board())
    if why:
        return False
    body = ((j or {}).get("task") or {}).get("body") or ""
    return re.search(rf"(?im)^[ \t]*review-by[ \t]*:[ \t]*{re.escape(named)}[ \t]*$", body) is not None


def card_review_by(p, a):
    """The set of profiles named by `Review-by:` lines in the caller's own proven running card (empty when none or no proof)."""
    j, why = roles.prove_card(p.get("profile"), str(a.get("task_id") or ""), roles.board())
    if why:
        return set()
    body = ((j or {}).get("task") or {}).get("body") or ""
    return set(re.findall(r"(?im)^[ \t]*review-by[ \t]*:[ \t]*(\S+)[ \t]*$", body))


def main():
    p = json.load(sys.stdin)
    tool, a = p.get("tool_name"), p.get("tool_input") or {}
    if tool == "kanban_request_review":   # K8: a card is reviewed by a reviewing role, never by its own builder
        try:
            d = roles.load()
        except roles.RolesError as e:
            roles.log_alert("STL-CFG-303", problem=str(e)[:300])
            refuse(f"[STL-CFG-303] the role table cannot be read, so {tool} is refused until it is fixed")
        crole = roles.role_of(d, p.get("profile"))[0]
        named = a.get("reviewer") if isinstance(a, dict) else None
        row = d["profiles"].get(named) if isinstance(named, str) else None
        via_card = False
        if row and named != p.get("profile") and row.get("review_callers") is not None and crole not in row["review_callers"]:   # D101: the owner's setting
            via_card = review_by_card(d, p, a, named, row["review_callers"])
            if not via_card:
                refuse(f"{named} reviews only when it is named by the roles {', '.join(c for c in row['review_callers'] if c != 'card')} or, "
                       f"if the owner's setting (review_callers) allows, by a `Review-by: {named}` line in the card's own body; the {crole} "
                       f"role names one of {', '.join(r for r in roles.reviewers(d, crole) if r != p.get('profile')) or '(none)'}")
        revs = [r for r in roles.reviewers(d, crole) if r != p.get("profile")] + ([named] if via_card else [])
        if not isinstance(a, dict) or a.get("reviewer") not in revs:
            refuse(f"a review request names the profile that reviews the card, one of "
                   f"{', '.join(revs) or '(none listed: ask the owner)'}; call kanban_request_review again naming it. A card "
                   "is never reviewed by its own builder (K8)")
        # S6I-04: a card that says `Review-by: <profile>` is reviewed by that profile, whoever the caller is (the line is the creator's choice)
        want = card_review_by(p, a)
        if want and a.get("reviewer") not in want:
            refuse(f"this card's body says Review-by: {', '.join(sorted(want))}; name that profile in the review request")
        return
    if tool == "kanban_comment":   # A1-01: a card's worker comments on its own card only (Hermes leaves cross-card open), so a
        # comment on a card is never a worker's forged "owner answer". The one role with may_answer_for_owner (the coordinator) is free.
        try:
            d = roles.load()
        except roles.RolesError as e:
            roles.log_alert("STL-CFG-303", problem=str(e)[:300])
            refuse(f"[STL-CFG-303] the role table cannot be read, so {tool} is refused until it is fixed")
        rname, role, listed = roles.role_of(d, p.get("profile"))
        tid = a.get("task_id") if isinstance(a, dict) else None
        if not role["may_answer_for_owner"] and tid not in (None, ""):   # W2-RT-01: the coordinator is its own field; every other role, listed or not, proves the card is its own
            j, why = roles.prove_card(p.get("profile"), str(tid), roles.board())
            if why:
                refuse(f"kanban_comment refused: {tid!r} is not your own running card ({why}). A worker comments on its own "
                       "card only: pass your own card's id as task_id; to tell the owner something, use kanban_block")
        return
    if tool not in GATED:
        return
    if not isinstance(a, dict):
        refuse("unreadable tool arguments")
    try:
        d = roles.load()
    except roles.RolesError as e:
        roles.log_alert("STL-CFG-303", problem=str(e)[:300])
        refuse(f"[STL-CFG-303] the role table cannot be read, so {tool} is refused until it is fixed")
    profile = p.get("profile")
    rname, role, listed = roles.role_of(d, profile)
    perm = GATED[tool]
    if not role[perm]:
        note = "" if listed else f" [STL-CFG-303: this profile has no row in roles.json, so it gets the {rname} role]"
        refuse(f"the {rname} role does not {VERB[perm]}: {INSTEAD[perm]}.{note}")
    b = roles.board()
    if tool == "kanban_complete":
        why = complete_problem(d, a, profile, b)
        if why:
            refuse(why)
    elif tool == "kanban_create":
        probs = create_problems(d, a, profile, b)
        if probs:
            refuse("card refused: " + "; ".join(probs) + ". A valid card: title, assignee, project, workspace_kind "
                   "worktree, body with the task and its acceptance; no workspace_path, model or provider")


try:
    main()
except SystemExit:
    raise
except Exception as e:  # fail closed: anything unexpected refuses
    refuse(f"internal error ({type(e).__name__}: {e}); the call is refused")
sys.exit(0)
