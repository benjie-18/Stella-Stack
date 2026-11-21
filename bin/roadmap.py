#!/usr/bin/env python3
"""Roadmap format, validator, acceptance lint and model pick (phase P1 item D), stdlib only. No role, model, provider or path is
named here: ids, limits, words and index keys come from .stella/planner.json (roadmap, lint, model_pick), routing and the index.
roadmap.md = prose plus exactly one fenced block (the planner data's roadmap.fence) whose body is the JSON document, validated
by .stella/schemas/roadmap.schema.json. The file and the block are untrusted model output: size and depth are capped first.
  check FILE --project P [--json]   schema; phase ids unique, depends_on known and acyclic; vm is the data's placeholder while the
        VM feature is not on; estimate.cost <= budget_cap <= the project's budget cap; install id and request digest are ours;
        every assignment and card builder link is one of resolve.py's chain or rung walk for that role and project.
  lint FILE [--json]                every acceptance check has an action, an observe and a numeric threshold with a data
        comparator, or owner_confirm; a check with no threshold and a feel word is refused unless owner_confirm; a probe sketch
        comes from the deterministic stub (features planner-probe-sketch-stub, due D1); prints {owner_confirm, checks[]}.
  pick --project P --role R --kind K [--card C] [--critical] [--json]   the start rung with the least expected cost to an accepted
        card: per rung p = first-pass rate of (kind, link) from the routing stats when n >= min_samples, else the benchmark prior
        (both mock files until D1 and W2); k rounds per rung (qa-loop rounds); E_i = c_i*sum_{j<k}(1-p_i)^j + (1-p_i)^k*E_{i+1};
        past the last rung the owner penalty (owner_penalty_cost times the dearest round). Ties go to the lower rung.
        Exploration only behind its features flag and never with --critical. Without --card the resolver is asked with the
        data's no_card_id, a card with no facts record (links that leave the machine are then out); pass --card for the real one.
Failures: STL-PLN-200..209, a JSON answer {ok: false, code, problem} on stdout, the plain message on stderr, exit 1."""
import argparse, datetime, hashlib, json, os, random, re, sys

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import stella_data as sd
import resolve

BLOCK, SCHEMA, GRAPH, VM, DIGEST = "STL-PLN-200", "STL-PLN-201", "STL-PLN-202", "STL-PLN-203", "STL-PLN-204"   # literal: the alert suite finds a code by its text
BUDGET, LINK, LINT, NOPROBE, PICK = "STL-PLN-205", "STL-PLN-206", "STL-PLN-207", "STL-PLN-208", "STL-PLN-209"


class Refuse(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def doc(schema):
    """The one JSON document of that schema in the index, validated."""
    rows = [r for r in sd.rows() if r["schema"] == schema and r["format"] == "json"]
    if not rows:
        raise sd.DataError(f"the index has no {schema} data")
    return sd.checked(sd.load(rows[0]["path"]), rows[0]["path"], schema)


def feature_on(fid):
    return any(e.get("id") == fid and e.get("status") == "on" or e.get("flag") == fid and e.get("status") == "on" for e in doc("features")["entries"])


def depth(x, n=1):
    if isinstance(x, dict):
        x = list(x.values())
    return max([depth(v, n + 1) for v in x] + [n]) if isinstance(x, list) else n


def load(path, pl):
    """The roadmap document of a roadmap.md: the one fenced block, parsed and checked against the schema."""
    rm = pl["roadmap"]
    try:
        if os.path.getsize(path) > rm["max_bytes"]:
            raise Refuse(BLOCK, f"the file is larger than {rm['max_bytes']} bytes")
        text = open(path, encoding="utf-8").read()
    except (OSError, UnicodeError) as e:
        raise Refuse(BLOCK, f"the file cannot be read ({type(e).__name__})")
    blocks, cur, fence = [], None, "```"
    for line in text.split("\n"):
        s = line.rstrip()
        if cur is None and s == fence + rm["fence"]:
            cur = []
        elif cur is not None and s == fence:
            blocks.append("\n".join(cur))
            cur = None
        elif cur is not None:
            cur.append(line)
    if cur is not None or len(blocks) != 1:
        raise Refuse(BLOCK, f"the file must hold exactly one closed {rm['fence']} block, it holds {len(blocks)}" + (" and one that is not closed" if cur is not None else ""))
    try:
        d = json.loads(blocks[0])
    except (ValueError, RecursionError):
        raise Refuse(BLOCK, "the block is not JSON")
    if depth(d) > rm["max_depth"]:
        raise Refuse(BLOCK, f"the block is nested deeper than {rm['max_depth']}")
    errs = sd.validate_doc(d, sd.schema_of("roadmap"))
    if errs:
        raise Refuse(SCHEMA, errs[0] + (f" (and {len(errs) - 1} more)" if len(errs) > 1 else ""))
    return d


def allowed(role, project, pl, d, cache):
    """The links resolve.py may serve for the role in the project: its chain (not excluded) and its rung walk."""
    if role not in cache:
        ctx = {"role": role, "project": project, "card": pl["model_pick"]["no_card_id"]}
        try:
            out = resolve.resolve(ctx, d)
            cache[role] = {(e["connection"], e["model"]) for e in out["chain"] if e["status"] != "excluded"} | {(l["connection"], l["model"]) for _, l in rungs(ctx, d)}
        except sd.DataError as e:
            raise Refuse(LINK, f"role {sd.idn(str(role)[:64], True)}: {e}")
    return cache[role]


def rungs(ctx, d):
    """[(rung number served, link)] of the escalation walk, rung 1 on."""
    out, n = [], 1
    while True:
        r = resolve.resolve({**ctx, "rung": n}, d).get("rung")
        if not r or r["served"] is None:
            return out
        out.append((r["served"], r["link"]))
        n = r["served"] + 1
        if n > r["last"]:
            return out


def project_cap(project):
    rows = [b for b in doc("budgets")["budgets"] if b["scope"] == "project" and b["key"] in (project, "*") and b.get("hard")]
    rows.sort(key=lambda b: b["key"] == "*")
    return rows[0]["hard"]["amount"] if rows else None


def cmd_check(a, pl):
    d = load(a.file, pl)
    if d["project"] != a.project:
        raise Refuse(SCHEMA, "the roadmap names another project than --project")
    if d["install_id"] != doc("install")["install_id"]:
        raise Refuse(DIGEST, "the roadmap is from another install")
    if hashlib.sha256(d["request"]["text"].encode("utf-8")).hexdigest() != d["request"]["digest"]:
        raise Refuse(DIGEST, "request.digest is not the sha256 of request.text")
    tiers = {t["id"] for t in doc("routing")["task_tiers"]}
    for t in [d["tier"]] + [p["qa_tier"] for p in d["phases"]]:
        if t not in tiers:
            raise Refuse(SCHEMA, f"tier {sd.idn(t[:64], True)} is not a task tier of the routing data")
    ids = [p["id"] for p in d["phases"]]
    if len(set(ids)) != len(ids) or len({c["id"] for p in d["phases"] for c in p["cards"]}) != sum(len(p["cards"]) for p in d["phases"]):
        raise Refuse(GRAPH, "a phase id or a card id is used twice")
    dep = {p["id"]: p["depends_on"] for p in d["phases"]}
    if any(x not in dep for v in dep.values() for x in v):
        raise Refuse(GRAPH, "a depends_on names no phase")
    left = dict(dep)
    while left:   # peel the phases whose dependencies are all peeled; none left to peel is a cycle
        ready = [k for k, v in left.items() if not set(v) & set(left)]
        if not ready:
            raise Refuse(GRAPH, "depends_on has a cycle")
        for k in ready:
            del left[k]
    for p in d["phases"]:   # DG-5: every acceptance check is covered by a card of its phase, and a card names only checks of its phase
        acc, cov = [c["id"] for c in p["acceptance"]], {x for c in p["cards"] for x in c["checks"]}
        if len(set(acc)) != len(acc) or cov - set(acc) or set(acc) - cov:
            raise Refuse(GRAPH, f"phase {sd.idn(p['id'], True)}: its acceptance checks and the checks of its cards are not the same ids")
        if any(re.fullmatch(r"(\./)?(\*+/?)+", g.strip()) for c in p["cards"] for g in c["files"]):
            raise Refuse(GRAPH, f"phase {sd.idn(p['id'], True)}: a card files glob matches everything")
    ph = pl["roadmap"]["vm_placeholder"]
    if not feature_on(pl["roadmap"]["vm_feature"]) and any(p["vm"] != ph for p in d["phases"]):
        raise Refuse(VM, f"vm must be {ph!r} while the {pl['roadmap']['vm_feature']} feature is not on")
    e, cap = d["estimate"], project_cap(a.project)
    if e["cost"] > e["budget_cap"] or cap is not None and e["budget_cap"] > cap:
        raise Refuse(BUDGET, "estimate.cost is over budget_cap, or budget_cap is over the project's budget cap")
    data, cache = resolve._data(a.project), {}
    want = [(r, l) for r, l in d["assignments"].items()] + [(p["builder_role"], c["builder"]) for p in d["phases"] for c in p["cards"]]
    for role, l in want:
        if (l["connection"], l["model"]) not in allowed(role, a.project, pl, data, cache):
            raise Refuse(LINK, f"a link for role {sd.idn(role[:64], True)} is not one resolve.py serves for the project")
    return {"ok": True, "project": a.project, "phases": len(ids), "cards": sum(len(p["cards"]) for p in d["phases"])}


def sketch(c, th):
    """The probe sketch stub (due D1): steps from the action, an assert from observe and threshold."""
    return {"steps": [s for s in re.split(r",\s*(?:then\s+)?|\s+then\s+", c["action"]) if s.strip()], "assert": f"{c['observe']} {th['comparator']} {th['value']}"}


def cmd_lint(a, pl):
    d = load(a.file, pl)
    stub, lint, out = feature_on(pl["roadmap"]["probe_stub_feature"]), pl["lint"], []
    feel = re.compile("|".join(re.escape(w) for w in lint["feel_words"]), re.I)
    for p in d["phases"]:
        for c in p["acceptance"]:
            th, who = c["threshold"], f"check {sd.idn(c['id'][:64], True)}"
            if th is not None:
                if th["comparator"] not in lint["comparators"] or type(th["value"]) not in (int, float):
                    raise Refuse(LINT, f"{who}: the threshold needs a number and a comparator from the lint data")
            elif not c["owner_confirm"]:
                raise Refuse(LINT, f"{who}: no threshold" + (" and a feel word" if feel.search(c["action"] + " " + c["observe"]) else "") + f" and not marked owner_confirm. {lint['owner_confirm_note']}")
            probe = sketch(c, th) if th is not None and stub else None
            if probe is None and not c["owner_confirm"]:
                raise Refuse(NOPROBE, f"{who}: no probe sketch, so the owner must confirm it")
            out.append({"id": c["id"], "ok": True, "probe": probe})
    return {"owner_confirm": sum(c["owner_confirm"] for p in d["phases"] for c in p["acceptance"]), "checks": out}


def first_pass(key, rows_key):
    """{(kind, connection, model): row} of a state file named by an index key; {} when the file is not there."""
    rel = sd.load(sd.INDEX).get(key)
    if not isinstance(rel, str) or not os.path.lexists(os.path.join(sd.ROOT, rel)):
        return {}
    rows = sd.load(rel).get(rows_key)
    return {(r["kind"], r["connection"], r["model"]): r for r in rows if isinstance(r, dict) and {"kind", "connection", "model"} <= set(r)} if isinstance(rows, list) else {}


def price(prices, link):
    """Cost of one round on a link: the input plus output price per million of its newest price row in force."""
    today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    rows = sorted((e for e in prices if (e["connection"], e["model"]) == (link["connection"], link["model"]) and e["effective_from"] <= today), key=lambda e: e["effective_from"])
    if not rows:
        raise Refuse(PICK, f"link {link['connection']}/{link['model']} has no price in force")
    return rows[-1]["per_million"]["input"] + rows[-1]["per_million"]["output"]


def cmd_pick(a, pl):
    import worker_env
    w = worker_env.reason()
    if w:   # DC-01: the rung walk comes from a host-side caller
        raise Refuse("STL-CFG-312", f"pick is asked from a worker environment ({w})")
    mp, qa = pl["model_pick"], doc("qa-loop")["rounds"]
    ctx = {"role": a.role, "project": a.project, "card": a.card or mp["no_card_id"]}
    try:
        data = resolve._data(a.project)
        base = next((e for e in resolve.resolve(ctx, data)["chain"] if e["status"] == "usable"), None)
        if base is None:
            raise Refuse(PICK, "the role has no usable link")
        ladder = [(0, base)] + rungs(ctx, data)
    except sd.DataError as e:
        raise Refuse(PICK, str(e))
    stats, prior, prices = first_pass(pl["card_size"]["stats_index_key"], "first_pass"), first_pass(mp["prior_index_key"], "entries"), doc("pricing")["entries"]
    rows = []
    for n, l in ladder:
        k = (a.kind, l["connection"], l["model"])
        s, pr = stats.get(k), prior.get(k)
        if s and isinstance(s.get("n"), int) and s["n"] >= mp["min_samples"] and isinstance(s.get("passed"), (int, float)) and 0 <= s["passed"] <= s["n"]:
            p, src = s["passed"] / s["n"], "stats"
        elif pr and isinstance(pr.get("first_pass"), (int, float)) and 0 <= pr["first_pass"] <= 1:
            p, src = pr["first_pass"], "prior"
        else:
            p, src = mp["unknown_first_pass"], "default"
        rows.append({"rung": n, "link": {"connection": l["connection"], "model": l["model"]}, "p": p, "source": src, "round_cost": price(prices, l),
                     "samples": s["n"] if src == "stats" else 0})
    e = mp["owner_penalty_cost"] * max(r["round_cost"] for r in rows)   # past the last rung
    for i in reversed(range(len(rows))):
        r, kk = rows[i], qa["normal"] if i == 0 else qa["climb_rung"]
        r["expected_cost"] = e = r["round_cost"] * sum((1 - r["p"]) ** j for j in range(kk)) + (1 - r["p"]) ** kk * e
    best = min(rows, key=lambda r: (r["expected_cost"], r["rung"]))
    explored = False
    # shortcut: exploration (flag off) has no test, it picks the least-sampled rung; give it a case before the flag is turned on
    if not a.critical and feature_on(mp["exploration"]["flag"]) and random.random() < mp["exploration"]["share"]:
        best, explored = min(rows, key=lambda r: (r["samples"], r["rung"])), True
    return {"rung": best["rung"], "link": best["link"], "explored": explored, "rungs": rows}


def main(argv):
    ap = argparse.ArgumentParser(prog="roadmap.py", allow_abbrev=False, description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("check", "lint", "pick"):
        s = sub.add_parser(name, allow_abbrev=False)
        s.add_argument("--json", action="store_true", help="accepted: JSON is the only output")
        if name != "pick":
            s.add_argument("file")
        if name != "lint":
            s.add_argument("--project", required=True)
        if name == "pick":
            s.add_argument("--role", required=True)
            s.add_argument("--kind", required=True)
            s.add_argument("--card")
            s.add_argument("--critical", action="store_true")
    a = ap.parse_args(argv)
    try:
        out = {"check": cmd_check, "lint": cmd_lint, "pick": cmd_pick}[a.cmd](a, doc("planner"))
    except (Refuse, sd.DataError) as e:
        code, why = (e.code, e.problem) if isinstance(e, Refuse) else (getattr(e, "code", None) or PICK, str(e))
        print(json.dumps({"ok": False, "code": code, "problem": el.scrub(why)}))
        el.say(code, why, alert=True)   # one alert line per refusal, secrets masked (as qa_loop.py)
        return 1
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except RecursionError:
        el.say(PICK, "a data file is nested too deeply", alert=True)
        sys.exit(1)
    except Exception as e:   # never the value: the type only
        print(json.dumps({"ok": False, "code": PICK, "problem": type(e).__name__}))
        el.say(PICK, f"{type(e).__name__}, an unexpected failure of roadmap.py", alert=True)
        sys.exit(1)
