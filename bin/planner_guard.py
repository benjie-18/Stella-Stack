"""The planner's start guard (phase P1 item E, design check DG-1), stdlib only: the one rule the adapter's start, the role guard's
kanban_claim and the planner's may-start share. A module of its own: a hook loads only it and the data tools, never the engine.
It reads the start projection (index key planner_cards) that the planner engine alone writes, under its lock, never through a link:
{projects: {P: {open_runs: [run]}}, cards: {card: {run, version, phase, startable, reason}}}. No projection: no project ever used the
planner, nothing changes. Refusals: STL-PLN-316 (the projection cannot be read), STL-PLN-317 (the card may not start)."""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import event_log as el
import stella_data as sd

PROJ, GUARD = "STL-PLN-316", "STL-PLN-317"


def path():
    """The projection's absolute path; ValueError, KeyError or sd.DataError when the index cannot give it."""
    return el.path(sd.load(sd.INDEX)["planner_cards"])


def read(p):
    with os.fdopen(el.open_file(p, os.O_RDONLY), "rb") as f:
        doc = json.loads(f.read(el.MAX_FILE + 1))
    if not (isinstance(doc, dict) and isinstance(doc.get("projects"), dict) and isinstance(doc.get("cards"), dict)):
        raise ValueError("it is not a start projection")
    return doc


def start_problem(card, role, project_of):
    """None, or (code, problem) for a card of a builder role (routing builder_roles): a card in the projection starts only when it is
    startable; a card of a project with an open run that is not bound to it does not start. project_of() gives the card's board
    project (None: it has none) and raises when the binding cannot be read. An unreadable projection refuses (fail closed)."""
    try:
        p = path()
        if not os.path.lexists(p):
            return None
        doc = read(p)
        rows = [r for r in sd.rows() if r["schema"] == "routing" and r["format"] == "json"]
        builders = sd.load(rows[0]["path"])["builder_roles"]
    except Exception as e:
        return PROJ, f"the planner's start projection cannot be read ({type(e).__name__}), so no builder card starts now"
    if role not in builders:
        return None
    e = doc["cards"].get(str(card).lower())
    if isinstance(e, dict):
        return None if e.get("startable") is True else (GUARD, f"card {card} belongs to planner run {e.get('run')}: {str(e.get('reason'))[:200]}")
    busy = {k for k, v in doc["projects"].items() if isinstance(v, dict) and v.get("open_runs")}
    if not busy:
        return None
    try:
        proj = project_of()
    except Exception:
        return GUARD, f"the project of card {card} cannot be read, and a project has an open planner run"
    if proj in busy:
        return GUARD, f"project {proj} has an open planner run and card {card} is not bound to its roadmap (the planner's bind command)"
    return None
