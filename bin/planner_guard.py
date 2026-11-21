"""The planner's start guard (phase P1 item E, design check DG-1), stdlib only: the one rule the adapter's start, the role guard's
kanban_claim and the planner's may-start share. A module of its own: a hook loads only it and the data tools, never the engine.
It reads the start projection (index key planner_cards) that the planner engine alone writes, under its lock, never through a link:
{projects: {P: {open_runs: [run]}}, cards: {card: {run, version, phase, startable, reason}}, stamps: {run: [seq, mac]}}, where a run's
stamp is the newest trusted planner.* line of that run the engine had folded when it wrote the run's rows. The planner.* lines of the
log file (read as written, no key needed: a hook may run where the key is not) say which runs exist; the projection counts for a run
only while its stamp is that run's newest line there (CRT-846d43e-1/2: a line written after the projection, or a projection put back
or gone, makes it not current). Those unverified lines only ever add refusals: a run they name (any planner.routed line of it that is
not direct) makes its project busy unless the projection is current for it and says the run is closed. Judged: a card the caller's
role or the card's assignee role (task.assignee) makes a builder card (CRT-846d43e-5); an assignee that cannot be read is judged.
The card's board task is read here (roles.kanban show), and an unreadable board refuses (CRT-846d43e-4). Refusals: STL-PLN-316 (the
projection or the log cannot be read, or the projection is not current for the card's run), STL-PLN-317 (the card may not start)."""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import event_log as el
import stella_data as sd

PROJ, GUARD = "STL-PLN-316", "STL-PLN-317"
PREFIX = "planner."


def path():
    """The projection's absolute path; ValueError, KeyError or sd.DataError when the index cannot give it."""
    return el.path(sd.load(sd.INDEX)["planner_cards"])


def read(p):
    with os.fdopen(el.open_file(p, os.O_RDONLY), "rb") as f:
        doc = json.loads(f.read(el.MAX_FILE + 1))
    if not (isinstance(doc, dict) and isinstance(doc.get("projects"), dict) and isinstance(doc.get("cards"), dict)
            and isinstance(doc.get("stamps", {}), dict)):
        raise ValueError("it is not a start projection")
    return doc


def run_of(x):
    """The run a planner.* line belongs to (the planner engine's fold uses this rule): new.run, else what."""
    n = x.get("new") if isinstance(x.get("new"), dict) else {}
    return n.get("run", x.get("what"))


def stamp(x):
    return [x.get("seq"), x.get("mac")]


def task_of(card):
    import roles
    t = roles.kanban(roles.board(), "show", card)["task"]
    if not isinstance(t, dict):
        raise ValueError("the board's answer has no task")
    return t


def start_problem(card, role):
    """None, or (code, problem) for a judged card: a card bound to a run starts only when the projection is current for that run and
    says startable; an unbound card of a busy project does not start. Anything that cannot be read refuses (fail closed)."""
    card = str(card)
    try:
        p = path()
        doc = read(p) if os.path.lexists(p) else None
        rows = {r["schema"]: r["path"] for r in sd.rows() if r["format"] == "json"}
        builders, direct = sd.load(rows["routing"])["builder_roles"], sd.load(rows["planner"])["behaviors"][0]
        runs, last, bound = {}, {}, None
        for s in el.split(el.raw()):
            x = el.loads(s) if PREFIX.encode() in s else None
            if not x or not str(x.get("type", "")).startswith(PREFIX) or not isinstance(run_of(x), str):
                continue
            r, n = run_of(x), x.get("new") if isinstance(x.get("new"), dict) else {}
            last[r] = stamp(x)
            if x["type"] == "planner.routed" and n.get("behavior") != direct:
                runs.setdefault(r, set()).add(n.get("project"))
            elif x["type"] == "planner.card-bound" and str(n.get("card")).lower() == card.lower():
                bound = r
    except Exception as e:
        return PROJ, f"the planner's start projection or the event log cannot be read ({type(e).__name__}), so no builder card starts now"
    if not runs:
        return None   # no project ever used the planner
    task = {}

    def board():
        task.setdefault("t", task_of(card))
        return task["t"]
    if role not in builders:
        try:
            import roles
            name, _, listed = roles.role_of(roles.load(), board().get("assignee"))
            if listed and name not in builders:
                return None
        except Exception:   # the card's role cannot be read: judged as a builder card
            pass
    current = lambda r: doc is not None and doc.get("stamps", {}).get(r) == last[r]
    if bound in runs:
        e = doc["cards"].get(card.lower()) if doc else None
        if not current(bound) or not isinstance(e, dict) or e.get("run") != bound:
            return PROJ, (f"card {card} belongs to planner run {bound}, and the start projection is " +
                          ("missing" if doc is None else "not current for that run") + " (any planner engine command of the run brings it up to date)")
        return None if e.get("startable") is True else (GUARD, f"card {card} belongs to planner run {bound}: {str(e.get('reason'))[:200]}")
    closed = lambda r: current(r) and not any(isinstance(v, dict) and r in (v.get("open_runs") or []) for v in doc["projects"].values())
    busy = {pr for r, ps in runs.items() if not closed(r) for pr in ps}
    if not busy:
        return None
    try:
        proj = board().get("project")
    except Exception:
        return GUARD, f"the project of card {card} cannot be read, and a project has an open planner run"
    if proj in busy:
        return GUARD, f"project {proj} has an open planner run and card {card} is not bound to its roadmap (the planner's bind command)"
    return None
