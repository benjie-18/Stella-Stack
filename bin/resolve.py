#!/usr/bin/env python3
"""The resolver (F2 design D2, with the design check and the wave-2 rulings), stdlib only: the ordered chain of model links a
role may use right now, and why. Read-only: no network, no write to any data file; it reads the failover state file (index key
routing_state; absent = no cooldown, no history) and the card facts store (index key card_facts) and creates neither. No role,
preset, link class, tier, driver, provider or model is named in this file: every id comes from the data, and every rule is the
one function of bin/stella_data.py (reach, policy_allows, route_problems, grant_in_force, link_class, probed, unmet).
CLI: resolve.py resolve --role R --project P [--card C] [--tier T] [--driver D] [--task ID] [--rung N] [--tokens N] [--json]   (JSON only)
Import: resolve(ctx) -> the same dict (ctx: {role, project, card, tier, driver, task, rung, tokens}); link_key(link) -> "<connection>/<model>",
the state file's key; role_view(role, project, card=None) -> what routing gives the role before any link is judged (its
docstring has the keys), the one copy of that rule: resolve() reads it there. Both write nothing and alert nothing: a
fail-closed answer is a stella_data.DataError (Refusal carries its code; any other one is data that `check` refuses, STL-CFG-310).
Output: {role, project, card, preset {id, source: card|project|global}, policy: project|default (a project the data policy
does not list follows the default), local_only, tier, driver, chain[], decision {rule, reason}, failure_history[] (the task's,
from the state file), stubs[] (features ids the answer rests on), apps[] {app, status, code, reason} (the card's apps),
cross_family (only for a role of routing cross_family.reviewer_roles, not on a rung walk: {builder_family, served_family, status:
met|waived, reason, logged}), code, reason (null when a link is usable and no app is refused)}. A chain entry: {connection, model, parameters, link_class,
source: pin:card|pin:project|pin:global|preset|fallback|last_resort, status: usable|needs_grant|cooldown|excluded, code,
reason, grant: null or {kind: privacy, data_class} or {kind: crossing, to_class}, mid_task, cooldown_until, effort: its
parameters.effort, else routing effort.by_role[role].tiers[tier], else .default, else null, family: its probe record's, else null,
probed: whether it has a probe record}.
Ranking (F2c item G): a best-of group ranks by score: the benchmark mean of the role's link (compare.routing_stats) once its sample reaches
routing_min_tasks, else the catalog's advertised models[].score (the prior), else none (last); decision.reason lists each link's score, source
and n. Benchmark data or parameters that cannot be used leave the prior with one STL-MDL-780 alert line per resolve (the CLI writes it,
resolve(ctx) returns it as out["ranking_alerts"], which the CLI removes); one STL-MDL-781 info line when a too-small sample kept a pick the
smaller sample would have changed.
Probe data (F2b item C, owner ruling 2026-11-18): what a link can do is read from its probe record only (stella_data.probed():
bin/probe.py's records, the newest not dated in the future; the catalog's advertised capabilities are not read). A link with no
record may serve (a CLI-login link cannot be probed at all): rule 4 refuses only a link whose record fails a requirement; the CLI
writes one STL-MDL-738 warning alert line when the link its answer serves (the served rung, else the first usable link) has no
record and the role has requirements or --tokens gives a size (route.py does the same for each pick; resolve(ctx) writes none); a
line that cannot be written withdraws the answer (STL-CFG-318). A records file present but unusable fails closed: every link with
no usable record counts as failing every requirement (stella_data.probe_records, STL-MDL-739 in check). Rule 4 reads it, and through rule 4 the needs-class trigger, --tokens and cross_family. The records file is
protected state (index key probe_records: no role may write it, records of another install are ignored); a forged record can make a
link look able (it then fails at run time and fails over) or unable (no link: fail closed), never widen reach: rules 1 to 3 and 5 to
7 do not read it. --tokens N: after the class order is fixed, a link whose probed effective context is below N is excluded
(STL-MDL-715); a link with no record is not (it may serve, unproven). Cross-family review (a role of cross_family.reviewer_roles, with a card; on a rung walk the served rung is judged, never moved): see
crossed(); a waived answer is written by the CLI alone as one trusted routing.cross-family-waiver line (STL-MDL-737; logged true), none
in a worker environment (logged false: information only); a line that cannot be written withdraws the answer (chain [], the log's
code, exit 1).
Rung walk (F2b item D; --rung N >= 1, ctx["rung"]; 0 is the answer without it): rungs N.. of the role's escalation_chain in the
active preset are judged alone in order by the rules below (rule 5's class order widened to the preset's needs class and last
resort; the last resort outside the order still needs a crossing grant, the order read before any class is put first (DC-05); an exempt role keeps its own order); an excluded or
waiting (needs_grant) rung is skipped, the first other one served (a rung in cooldown is answered as itself, STL-MDL-724). The
answer adds rung {requested, served, last, link, skipped[] {rung, connection, model, link_class, status, code, reason}} and its
chain is [link] or []; none served: STL-MDL-731 (escalate to the owner), exit 1. The CLI alone writes the walk to the event log:
one routing.rung-skipped line (STL-MDL-732) per skip, one routing.rung-exhausted line (731) when none is served; a line that cannot
be written withdraws a served rung (the log's code) or, exhausted, names it in rung.log_code. --rung in a worker environment
fails closed (STL-CFG-312) before anything is judged. A role the preset turns off answers as without --rung (NO_LINK, no rung key).
Exit: 0 one usable link or more and no app refused; 1 no usable link (NO_LINK, the same JSON) or a refused card app (its
code, the same JSON), or fail closed with one catalog line, one alert line and no JSON: an unknown role, tier, driver, card
id, preset or link class, a role that works a card called with no card, a project id that is a listed one but for case or
outer spaces or that is no project key by the data policy schema's pattern (UNKNOWN), a card whose facts record names
another project (NO_LINK), data that `check` refuses (STL-CFG-310); 2 usage.
Every link is judged by all the rules, in this order; the first that fails names its status:
 1 hard exclusions: a card fact the record does not state as false (the facts: the keys of routing data
   card_facts.when_missing and every other key of the record) or a private project excludes every link that leaves the
   machine (reach()); no grant, setting, preset or routing data changes it;
 2 the data policy of the project, and of the default when that is Local only (policy_allows); Local only overrides any
   preset: the class order is the classes that are not hosted, with no last resort and no crossing (an exempt role keeps its own);
 3 the connection: switched off, a CLI login without terms_ok, an aggregator whose broker entries do not resolve
   (credentials.check, when that module exists), allowed_roles, data_classes_allowed;
 4 the role's requirements against the link's probe record (probed, unmet): no record meets none; then --tokens;
 5 the preset: its allowed localities (the last-resort class is the one exception) and the role's class order; the
   last-resort class needs a crossing grant; any other class is excluded. An exempt role (routing data exempt_roles) follows
   its own class order instead, and is never a crossing;
 6 the data classes the role handles: hosted never excludes, and does so before the crossing grant of rule 5 is asked;
   hosted grant needs a privacy grant (route_problems);
 7 health: a link, or its connection, in cooldown in the state file (an `until` that is text but no date counts as ahead).
Chain order: the owner's pins (card, project, global assignment rows), the preset's pins for the role, the catalog's links
of each class of the order (a list item of the order is a group: best(), the one ranking), the preset's fallbacks, the
last-resort class. A link listed twice keeps its first place."""
import argparse, datetime, json, os, re, sys, types

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import stella_data as sd

# spelled out: the alert selftest counts a code as used only when a script holds it as a literal
NO_LINK, UNKNOWN, TERMS, AGGREGATOR, HARD = "STL-MDL-710", "STL-MDL-711", "STL-MDL-712", "STL-MDL-713", "STL-MDL-714"
UNMET, POLICY, PRIVACY, CROSSING, COOLDOWN = "STL-MDL-715", "STL-MDL-716", "STL-MDL-717", "STL-MDL-718", "STL-MDL-724"
EXHAUSTED, RUNG_SKIPPED, WORKER, LOG_FAILED = "STL-MDL-731", "STL-MDL-732", "STL-CFG-312", "STL-CFG-318"   # the rung walk (F2b item D)
WAIVER = "STL-MDL-737"   # a review role answered with no link of another family than the builder (F2b item C)
READS = ("role-assignments", "routing", "connections", "data-policy", "grants", "features")   # the schemas a resolve reads
STUBS = ()   # features ids every answer rests on (the quota stub is gone: the usage ledger answers, F2c item A2)
BENCH_UNUSABLE, PRIOR_ONLY = "STL-MDL-780", "STL-MDL-781"   # the ranking (F2c item G): benchmark data unusable; a sample below the minimum kept the prior


class Refusal(sd.DataError):
    """A request the resolver fails closed on: its catalog code and a plain problem, no chain."""
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code = code


def link_key(link):
    return f"{link['connection']}/{link['model']}"


def dig(d, *keys):
    """A value of the state file, which is not validated data: None when any step is not an object."""
    for k in keys:
        d = d.get(k) if isinstance(d, dict) else None
    return d


def brokered(prov):
    """Whether an aggregator's broker entries resolve through the credentials interface (wave-2 ruling 11): only a True from
    credentials.check(names) counts; no such module, a refusal or any other answer is not resolved (fail closed)."""
    names = sorted(set(sd.leaves(prov.get("broker_entries") or {})))
    try:
        import credentials
        return bool(names) and credentials.check(names) is True
    except (Exception, SystemExit):
        return False


def best(entries, scores, ranks):
    """The one best-suited ranking of a class-order group: (the judged links in order, the reason). Not excluded first, then
    healthy (not in cooldown), then the higher score (benchmark mean past the minimum sample, else the advertised prior; none:
    last, see scored()), then the more private class, then catalog order. scores: link key -> {score, source, n}.
    A link waiting for a grant is not ranked down: it is never skipped silently. The links of one connection and class stay
    adjacent, placed by their best link."""
    def key(i):
        e, s = entries[i], scores[link_key(entries[i])]["score"]
        return (e["status"] == "excluded", e["status"] == "cooldown", s is None, -(s or 0), ranks[e["link_class"]], i)
    groups = {}
    for i, e in enumerate(entries):
        groups.setdefault((e["connection"], e["link_class"]), []).append(i)
    order = [i for g in sorted(groups.values(), key=lambda g: min(map(key, g))) for i in sorted(g, key=key)]
    if not order:
        return [], "the group has no link in the catalog"
    e = entries[order[0]]
    seen = ", ".join(f"{link_key(entries[i])} {json.dumps(scores[link_key(entries[i])]['score'])} ({scores[link_key(entries[i])]['source']}, n={scores[link_key(entries[i])]['n']})" for i in order)
    return [entries[i] for i in order], (
        f"{link_key(e)} ranks first of {len(order)} (ranked by: not excluded, healthy, score, privacy rank, catalog order): "
        f"status {e['status']}, privacy rank {ranks[e['link_class']]}; scores: {seen}")

def scored(role, models):
    """(link key -> {score, source (benchmark|prior|none), n}, the same with the smaller samples' mean, the problem or None) for the
    role's links. compare.routing_stats does the statistics (the minimum sample is its parameter routing_min_tasks); a benchmark file or
    parameters that cannot be used leave the advertised prior (the problem names why), never a refusal."""
    import compare
    prior = [{"role": role, "connection": c, "model": m, "score": x["score"]} for (c, m), x in models.items() if x.get("score") is not None]
    try:
        par, (recs, why) = compare.model_params(), compare.read_benchmarks()
    except compare.Stop as x:
        par, recs, why = {"routing_min_tasks": 1}, [], f"{x.code} {x.problem}"
    recs = [] if why else [r for r in recs if r["role"] == role]
    def table(p):
        got = {f"{r['connection']}/{r['model']}": r for r in compare.routing_stats(recs, prior, p) if r["role"] == role}
        return {link_key({"connection": c, "model": m}): {k: got.get(f"{c}/{m}", {"score": None, "source": "none", "n": 0})[k] for k in ("score", "source", "n")} for c, m in models}
    return table(par), table({**par, "routing_min_tasks": 1}), why


def known(kind, v, ids):
    if v not in ids:
        raise Refusal(UNKNOWN, f"{kind} {sd.idn(str(v)[:64], True)}")


def _data(project):
    """What every answer reads, loaded once: the served documents (a DataError while `check` refuses anything a resolve rests
    on) and the project's policies (a project the policy does not list follows the default; DC-04: a Local only default always
    holds). alias(p) is the one place a project id is compared: the listed id of p (its own id or its global_id, exactly), p
    itself when it matches no listed project, and a Refusal when it only matches one with case and outer spaces ignored, or is
    no project key by the pattern of the data policy schema (an invisible, full-width or look-alike character, a combining
    mark), so a misspelling never drops a project's private or Local only marking."""
    idx = sd.load(sd.INDEX)
    mine = [r for r in sd.rows() if r["format"] == "json" and r["schema"] in READS]
    by = sd.served([r["id"] for r in mine])
    docs = lambda s: [d for r in mine if r["schema"] == s for _, d in by["_rows"][r["id"]][0]]

    def one(s):
        ds = docs(s)
        if len(ds) != 1:
            raise sd.DataError(f"the {s} data cannot be read (no file of its schema)")
        return ds[0]
    ra, rt, table, conn = one("role-assignments"), one("routing"), sd.load(idx["role_table"]), by.get("connections", {})
    pols = [(None, d) for d in docs("data-policy")]
    if not pols:
        raise sd.DataError("the data policy cannot be read (no file of its schema)")
    projects = {k: v for _, d in pols for k, v in d["projects"].items()}
    gids = {v["global_id"]: k for k, v in reversed(projects.items()) if isinstance(v.get("global_id"), str)}   # the first row of a global_id wins

    def alias(p):
        if not isinstance(p, str) or not p or p in projects:   # None or "": no project (what a caller with no card gives), the default policy
            return p
        if p in gids:
            return gids[p]
        if p.strip().casefold() in {x.strip().casefold() for x in (*projects, *gids)}:
            raise Refusal(UNKNOWN, f"project {sd.idn(p[:64], True)}: it is not a listed project, but it is one when case and outer spaces are ignored")
        pat = dig(sd.schema_of("data-policy"), "properties", "projects", "propertyNames", "pattern")   # no pattern: no id is one (fail closed)
        if not isinstance(pat, str) or not sd.rx(pat).search(p):   # ascii(): an invisible or look-alike character shows as its code point
            raise Refusal(UNKNOWN, f"project {ascii(sd.idn(p[:64]))}: it is not a project id (the data policy schema's pattern for a project key)")
        return p
    pid, defaults = alias(project), [d["default"] for _, d in pols]
    policies = [dict(p, allowed_providers=[(sd.entry(conn, x) or {}).get("id", x) for x in p["allowed_providers"]])
                for p in ([projects[pid]] if pid in projects else defaults) + [d for d in defaults if d["mode"] == "local_only"]]
    return types.SimpleNamespace(idx=idx, by=by, docs=docs, ra=ra, rt=rt, table=table, conn=conn, pols=pols, alias=alias, pid=pid, listed=pid in projects,
                                 policies=policies, local_only=any(p["mode"] == "local_only" for p in policies), recs=sd.probe_records(rt))


def role_view(role, project, card=None, d=None):
    """What routing gives a role in a project (on a card when one is named), before any link is judged. It answers for a role
    the preset turns off and for a role that works a card asked with no card. d: the data resolve() has loaded already.
    {role, project, card, preset {id, source: card|project|global}, local_only, exempt, active,
     class_order (a list item is a best-of group): the effective order, before resolve() puts any class first,
     order_source: exempt (routing data exempt_roles) | local_only (the data policy: the classes that are not hosted) |
       assignment:card|project|global (the owner's override at that scope) | preset,
     needs_class: the class resolve() puts first for a listed task tier or when no link of the order meets the role's
       requirements (null: none, always so for an exempt role and under Local only),
     last_resort (null for an exempt role and under Local only),
     pins[] {scope: card|project|global, chain[]}: the owner's, in chain order, preset_pins[], fallbacks[]: the preset's for the role,
     escalation_chain[]: the preset's rungs for the role (rung N is entry N-1)}"""
    d = d or _data(project)
    ra, rt = d.ra, d.rt
    known("role", role, set(d.table["roles"]) - {d.table["fallback_role"]})
    # the active preset: the card's beats the project's beats the global one
    sel = ra.get("selection", {})
    preset, source = next(((v, s) for v, s in ((sel.get("cards", {}).get(card), "card"), (sel.get("projects", {}).get(d.pid, sel.get("projects", {}).get(project)), "project"),
                                              (sel.get("global"), "global")) if v), (None, None))
    if preset is None:
        raise Refusal(UNKNOWN, "no preset is selected (role assignments, selection.global)")
    known("preset", preset, ra["effort_modes"])
    mode = ra["effort_modes"][preset]
    rp = mode.get("roles", {}).get(role, {"active": True})   # a role the preset does not list follows the preset and is active
    exempt = next((x for x in rt["exempt_roles"] if x["role"] == role), None)
    scoped = [(lvl, a) for lvl in ("card", "project", "global") for a in ra["assignments"]
              if a["role"] == role and a["effort_mode"] == preset and a["scope"]["level"] == lvl
              and (lvl == "global" or d.alias(a["scope"].get("project")) == d.pid and (lvl == "project" or a["scope"].get("card") == card))]
    # the class order: an exempt role's own (ruling 1); Local only overrides any preset (B4); else the owner's override, the preset's for the role, the preset's
    if exempt:
        src, order, last, needs = "exempt", exempt["class_order"], None, None
    elif d.local_only:
        src, order, last, needs = "local_only", [c["id"] for c in rt["link_classes"] if not c["hosted"]], None, None
    else:
        src, order = next(((f"assignment:{lvl}", a["class_order"]) for lvl, a in scoped if "class_order" in a), ("preset", rp.get("class_order", mode.get("class_order", []))))
        last, needs = rp["last_resort"] if "last_resort" in rp else mode.get("last_resort"), mode.get("needs_class")
    return {"role": role, "project": project, "card": card, "preset": {"id": preset, "source": source}, "local_only": d.local_only, "exempt": bool(exempt),
            "active": rp["active"], "class_order": order, "order_source": src, "needs_class": needs, "last_resort": last,
            "pins": [{"scope": lvl, "chain": a["chain"]} for lvl, a in scoped], "preset_pins": rp.get("pins", []),
            "fallbacks": rp.get("fallbacks", []) if not exempt or exempt["in_fallback_chain"] else [], "escalation_chain": rp.get("escalation_chain", [])}


def resolve(ctx, d=None):
    """The answer (module docstring). ctx["rung"] N >= 1 walks the role's escalation chain instead (0 or None: the chain); ctx["tokens"]
    N excludes a link whose probed effective context is below N. Pure: no event line is written for a skipped or exhausted walk or a
    cross-family waiver on this path (cross_family.logged is false); only the CLI (main) logs them. d: the data _data() loaded (the
    builder's resolve of a review role's answer reads the same data)."""
    role, project, card, tier, driver, task, rung, tokens = (ctx.get(k) for k in ("role", "project", "card", "tier", "driver", "task", "rung", "tokens"))
    for k, v in (("rung", rung), ("tokens", tokens)):
        if v is not None and (type(v) is not int or v < 0):
            raise Refusal(UNKNOWN, f"the {k} is not a non-negative integer")
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    d = d or _data(project)
    idx, by, docs, ra, rt, table, conn, pols, alias, pid, policies, local_only = (
        d.idx, d.by, d.docs, d.ra, d.rt, d.table, d.conn, d.pols, d.alias, d.pid, d.policies, d.local_only)
    known("role", role, set(table["roles"]) - {table["fallback_role"]})
    drivers = {x["id"]: x for x in rt["drivers"]}
    if tier is not None:
        known("task tier", tier, {x["id"] for x in rt["task_tiers"]})
    if driver is not None:
        known("driver", driver, drivers)
    if card is None and role in rt["card_roles"]:
        raise Refusal(UNKNOWN, f"role {sd.idn(role, True)} works a card, and the request names no card")
    hard = ["the project is marked private"] if any(p.get("private") for p in policies) else []   # why no link may leave the machine

    # ---- the card: its facts from the host-side store (DC-01), its apps (DC-12)
    apps = []
    if card is not None:
        if not isinstance(card, str) or sd.bad_entry(f"{card}.json", card):
            raise Refusal(UNKNOWN, "the card id is not a plain id (letters, digits, dot, dash, underscore)")
        rel = os.path.join(idx["card_facts"], f"{card}.json")
        rec = sd.load(rel) if os.path.lexists(os.path.join(sd.ROOT, rel)) else {}
        rec = rec if isinstance(rec, dict) else {}
        if "project" in rec and (not isinstance(rec["project"], str) or alias(rec["project"]) != pid):
            raise Refusal(NO_LINK, "the card's facts record names another project than the request")
        if "project" not in rec:
            hard.append("the card has no facts record, or one that names no project")
        # a fact holds unless the record says false: no routing data switches one off, and a record key the data does not name is a fact too
        hard += [f"the card's fact {sd.kname(k)} holds, or is not recorded as true or false and counts as holding"
                 for k in dict.fromkeys((*rt["card_facts"]["when_missing"], *rec)) if k not in ("project", "apps") and rec.get(k) is not False]
        for a in rec["apps"] if isinstance(rec.get("apps"), list) else []:
            e = sd.entry(conn, a) if isinstance(a, str) else None
            terms = [m for m in sd.route_problems(pols, [], e, now, pid) if m["kind"] == "terms"] if e else []
            if e is None or e["kind"] != "app":
                code, why = UNKNOWN, "it is not an app of the connections catalog"
            elif terms:
                code, why = TERMS, f"the app {terms[0]['text']}"
            elif hard and e.get("integration_aggregator") and sd.reach(e) != "local":
                code, why = HARD, f"the app is a hosted integration aggregator, and {hard[0]}"
            else:
                code = why = None
            apps.append({"app": a if isinstance(a, str) else None, "status": "excluded" if code else "usable", "code": code, "reason": why})

    # ---- the preset, the class order, the last resort and the pins of the role: role_view(), the one copy of that rule
    view = role_view(role, project, card, d)
    preset, source, exempt, order, last, needs = (view["preset"]["id"], view["preset"]["source"], view["exempt"], view["class_order"],
                                                  view["last_resort"], view["needs_class"])
    mode = ra["effort_modes"][preset]

    # ---- the failover state (not proof, not validated data: read defensively)
    srel = idx["routing_state"]
    state = sd.load(srel) if os.path.lexists(os.path.join(sd.ROOT, srel)) else {}
    history = dig(state, "tasks", task, "history") if task else None

    def cooling(key):
        """The `until` of the entry while it is ahead; "" for one that is text but no date: it counts as ahead (fail closed, as
        route.py reads it) and is not echoed; None: not cooling."""
        c = dig(state, "links", key)
        u = sd.when(c, "until") if isinstance(dig(c, "until"), str) else None
        return "" if u is False else c["until"] if u and u > now else None

    feats = by.get("features", {})
    out = {"role": role, "project": project, "card": card, "preset": {"id": preset, "source": source}, "policy": "project" if d.listed else "default",
           "local_only": local_only, "tier": tier, "driver": driver, "chain": [], "decision": {"rule": None, "reason": None},
           "failure_history": history if isinstance(history, list) else [], "stubs": [s for s in STUBS if sd.phases(feats.get(s, {}))], "ranking_alerts": [],
           "apps": apps, "code": None, "reason": None}
    if not view["active"]:   # ruling 10: an inactive role does not resolve
        out["code"], out["reason"] = NO_LINK, f"role {sd.idn(role, True)} is not active under preset {sd.idn(preset, True)}"
        out["decision"] = {"rule": "inactive", "reason": out["reason"]}
        return out

    classes = {x["id"]: x for x in rt["link_classes"]}
    flat = lambda o: [k for it in o for k in (it if isinstance(it, list) else [it])]
    for k in flat(order) + [k for k in (last, needs) if k is not None]:
        known("link class", k, classes)

    req = table["roles"][role].get("requirements", {})
    eff = rt.get("effort", {}).get("by_role", {}).get(role, {})
    eff = {"default": eff} if isinstance(eff, str) else eff   # an id alone is the role's default
    effort = lambda params: params["effort"] if params.get("effort") is not None else eff.get("tiers", {}).get(tier, eff.get("default"))
    need = req.get("allowed_data_classes", [])
    providers = [p for p in conn.values() if p["kind"] == "provider"]
    models = {(p["id"], m["id"]): m for p in providers for m in p["models"]}
    catalog = lambda group: [(p, m["id"]) for p in providers for m in p["models"] if sd.link_class(p, m["id"], rt) in group]
    crossing = [g for d in docs("grants") for g in d.get("crossing_grants", [])]
    broker = {}
    X = lambda code, why: ("excluded", code, why, None, None)

    rec = lambda prov, model: sd.probed(d.recs, prov["id"], model, now)

    def early(prov, model):
        """Rules 1 to 4: None, or why this link cannot serve the role at all (a link with no probe record may: owner ruling 2026-11-18)."""
        if sd.reach(prov) != "local" and hard:
            return X(HARD, f"the link leaves the machine, and {hard[0]}")
        if not all(sd.policy_allows(p, prov) for p in policies):
            return X(POLICY, "the data policy does not allow this connection for the project" + (" (Local only: local links only)" if local_only else ""))
        if not prov["enabled"]:
            return X(POLICY, "the connection is switched off")
        terms = [m for m in sd.route_problems(pols, [], prov, now, pid) if m["kind"] == "terms"]
        if terms:
            return X(TERMS, f"the connection {terms[0]['text']}")
        if prov.get("aggregator"):
            if prov["id"] not in broker:
                broker[prov["id"]] = brokered(prov)
            if not broker[prov["id"]]:
                return X(AGGREGATOR, "the connection is an aggregator, and its broker entries do not resolve through the credentials interface")
        if role not in prov.get("allowed_roles", []):
            return X(POLICY, "the connection does not list this role in its allowed_roles")
        if any(k not in prov["data_policy"]["data_classes_allowed"] for k in need):
            return X(POLICY, "the connection does not allow every data class the role handles")
        if models.get((prov["id"], model)) is None:
            return X(UNMET, "its model is not listed for its connection")
        r = rec(prov, model)
        miss = sd.unmet(req, r)
        return X(UNMET, f"its probe record does not meet the role's requirements ({', '.join(miss)})" + (f": {r[sd.BROKEN]}" if r.get(sd.BROKEN) else "")) if miss else None

    # the preset's needs class goes first for a listed task tier, or when no link of the order can serve the role (rules 1 to 4)
    notes = [f"class order {json.dumps(order)} of " + ("the exempt role" if exempt else "the Local only policy, which overrides the preset" if local_only
                                                       else f"preset {sd.idn(preset, True)}")]
    effective = flat(order)   # DC-05: the crossing test reads the order before any class is put first
    if needs is not None and needs not in effective:
        listed = tier in mode.get("frontier_when", {}).get("tiers", [])
        if listed or not any(early(p, m) is None for p, m in catalog(flat(order))):
            order = [needs] + order
            notes.append(f"class {sd.idn(needs, True)} goes first: " + (f"task tier {sd.idn(tier, True)} is listed for it" if listed
                                                                         else "no link of the class order meets the role's requirements"))
    inorder = flat(order)

    def quota(connection, model):
        """(reason, until) when the usage ledger says the link cannot be used now: its daily cap is used, a limit is observed, its plan share
        is at the limit of the data (limit-signals), or no slot is free; None otherwise. Read-only (the ledger creates nothing here)."""
        import ledger
        try:
            st, lim = ledger.status(connection, model), ledger.signals()["plan_share_limit"]
        except ledger.Stop as x:   # fail closed for this link only: a lock or usage file that cannot be used leaves the link, not every answer
            return f"the usage ledger cannot be used for the link ({x.code} {x.problem})", None
        if st["daily"]["cap"] is not None and st["daily"]["used"] >= st["daily"]["cap"]:
            return f"the link's daily limit is used ({st['daily']['used']} of {st['daily']['cap']} calls); it resets at {st['daily']['resets_at']}", st["daily"]["resets_at"]
        if st["observed"]:
            return f"a limit is observed on the link until {st['observed']['until']} ({st['observed']['source']})", st["observed"]["until"]
        if st["plan_share"] is not None and st["plan_share"] >= lim:
            return "the plan's share is at its limit", None
        if st["concurrency"]["free"] is not None and st["concurrency"]["free"] <= 0:
            return "no free slot", None

    def judge(prov, model, rung=False):
        """(status, code, reason, grant, cooldown_until) of one link: the first rule that fails names it. A rung's class may also
        be the preset's needs class or its last resort (rule 5 only); the last resort outside the order still needs a crossing grant."""
        cls, reach, no = sd.link_class(prov, model, rt), sd.reach(prov), early(prov, model)
        if no:
            return no
        r = rec(prov, model)
        if tokens and r is not None and r["context"]["effective"] < tokens:   # A4a: a task longer than the probed effective context (no record: may serve)
            return X(UNMET, f"its probed effective context ({r['context']['effective']} tokens) is below the task's {tokens} tokens")
        if cls is None:
            return X(POLICY, "the link has no link class (its connection names none), so it is not routable")
        if not (exempt or local_only) and reach not in mode["allowed_localities"] and cls != last:   # Local only overrides the preset's localities
            return X(POLICY, f"preset {sd.idn(preset, True)} allows no link that is {reach} for routing")
        if cls not in inorder and (exempt or cls not in ({last, needs} if rung else {last})):
            return X(POLICY, f"link class {sd.idn(cls, True)} is not in the class order of " + (
                "this exempt role" if exempt else "the Local only policy" if local_only else f"preset {sd.idn(preset, True)} for this role"))
        probs = {m["kind"]: m for m in reversed(sd.route_problems(pols, need, prov, now, pid))}   # the first problem of each kind
        if "never" in probs:   # a class that never reaches a hosted link refuses before any grant is offered, a crossing grant too (DC-08)
            return X(POLICY, f"the connection {probs['never']['text']}")
        if cls == last and cls not in effective and not any(g["preset"] == preset and g["to_class"] == cls and sd.grant_in_force(g, pid, now) for g in crossing):
            return ("needs_grant", CROSSING, f"link class {sd.idn(cls, True)} is the last resort of preset {sd.idn(preset, True)}, and no crossing grant is in force here",
                    {"kind": "crossing", "to_class": cls}, None)
        if "grant" in probs:
            return ("needs_grant", PRIVACY, f"the connection {probs['grant']['text']}", {"kind": "privacy", "data_class": probs["grant"]["data_class"]}, None)
        cool = [u for u in (cooling(f"{prov['id']}/{model}"), cooling(prov["id"])) if u is not None]
        until = next((u for u in cool if u), None)
        if cool:
            return ("cooldown", COOLDOWN, "the link failed recently and cools down until " + (until or "a time its state entry gives as no date (it counts as ahead)"), None, until)
        busy = quota(prov["id"], model)
        return ("cooldown", COOLDOWN, busy[0], None, busy[1]) if busy else ("usable", None, None, None, None)

    # ---- the chain
    seen = set()

    def judged(prov, model, params, source, rung=False):
        status, code, why, grant, until = judge(prov, model, rung)
        return {"connection": prov["id"], "model": model, "parameters": params, "effort": effort(params), "link_class": sd.link_class(prov, model, rt), "source": source,
                "status": status, "code": code, "reason": why, "grant": grant, "mid_task": False, "cooldown_until": until,
                "family": (rec(prov, model) or {}).get("family"), "probed": rec(prov, model) is not None}

    def links(pairs, source):
        got = []
        for prov, model, params in pairs:
            if prov is None or prov["kind"] != "provider" or (prov["id"], model) in seen:
                continue   # a pin that names no provider is refused by `check`; a link keeps its first place
            seen.add((prov["id"], model))
            got.append(judged(prov, model, params, source))
        return got
    pinned = lambda ls: [(sd.entry(conn, l["connection"]), l["model"], l["parameters"]) for l in ls]
    pins = [(pinned(p["chain"]), f"pin:{p['scope']}") for p in view["pins"]] + [(pinned(view["preset_pins"]), "preset")]
    chain = [e for ls, src in pins for e in links(ls, src)]
    ranked, items, sc = False, [], None   # items: the chain's slices that are one class-order item (one class or one best-of group), for cross_family
    for it in order:
        got = links([(p, m, {}) for p, m in catalog(it if isinstance(it, list) else [it])], "preset")
        if isinstance(it, list):
            if sc is None:   # once per resolve: the same data for every group
                sc = scored(role, models)
                if sc[2]:
                    out["ranking_alerts"].append((BENCH_UNUSABLE, f"role {role}: {sc[2]}; the advertised scores rank the links"))
            pr = {k: x["privacy_rank"] for k, x in classes.items()}
            small = best(got, sc[1], pr)[0]
            got, why = best(got, sc[0], pr)
            if small and got and link_key(small[0]) != link_key(got[0]):
                out["ranking_alerts"].append((PRIOR_ONLY, f"role {role}: {link_key(got[0])} ranks first on the prior because a sample is below the minimum; the smaller sample would put {link_key(small[0])} first"))
            notes.append(f"best suited of {json.dumps(it)}: {why}")
            ranked = True
        items.append((len(chain), len(chain) + len(got)))
        chain += got
    chain += links(pinned(view["fallbacks"]), "fallback")
    if last is not None and last not in inorder:
        got = links([(p, m, {}) for p, m in catalog([last])], "last_resort")
        items.append((len(chain), len(chain) + len(got)))
        chain += got
    drv, named = drivers.get(driver), {(p["id"], m) for ls, _ in pins for p, m, _ in ls if p}

    def mid(e):   # mid-task only under a driver that allows it, never on a CLI login, on an aggregator only for the role pinned to that link
        p = conn[e["connection"]]
        e["mid_task"] = bool(drv and drv["mid_task"]) and p["type"] != "cli-login" and (not p.get("aggregator") or (p["id"], e["model"]) in named)
    for e in chain:
        mid(e)
    out["chain"], out["decision"] = chain, {"rule": "best_suited" if ranked else "class_order", "reason": "; ".join(notes)}
    cf = rt.get("cross_family")
    if cf and role in cf["reviewer_roles"] and not rung:
        out["cross_family"] = crossed(ctx, d, out, mode, cf, items, {k: x["privacy_rank"] for k, x in classes.items()})
    bad = next((a for a in apps if a["code"]), None)
    if rung:   # the escalation chain: rungs N.. judged alone, in order; an excluded or waiting rung is skipped, the first other one served
        rungs, skipped, link = view["escalation_chain"], [], None
        for n in range(rung, len(rungs) + 1):
            l, prov = rungs[n - 1], sd.entry(conn, rungs[n - 1]["connection"])
            e = judged(prov, l["model"], l["parameters"], "rung", True) if prov and prov["kind"] == "provider" else {
                "connection": l["connection"], "model": l["model"], "link_class": None, "status": "excluded", "code": UNKNOWN,
                "reason": "the rung's connection is not a provider of the connections catalog"}   # skipped, never dropped: rung numbers stay
            if e["status"] in ("usable", "cooldown"):   # a rung in cooldown is answered as itself: failover, not the walk, waits it out
                mid(e)
                link = (n, e)
                break
            skipped.append({"rung": n, **{k: e[k] for k in ("connection", "model", "link_class", "status", "code", "reason")}})
        out["rung"] = {"requested": rung, "served": link and link[0], "last": len(rungs), "link": link and link[1], "skipped": skipped}
        out["chain"] = [link[1]] if link else []
        head = f"role {sd.idn(role, True)} under preset {sd.idn(preset, True)}: "
        if link is None:
            out["code"], out["reason"] = EXHAUSTED, head + (f"no rung from {rung} on is usable ({len(skipped)} skipped)" if skipped else
                                                            f"its escalation chain has {len(rungs)} rung(s), none from {rung} on")
        elif link[1]["status"] == "cooldown":
            out["code"], out["reason"] = COOLDOWN, head + f"rung {link[0]}: {link[1]['reason']}"
        elif bad:
            out["code"], out["reason"] = bad["code"], f"card app {sd.idn(bad['app'], True)}: {bad['reason']}"
        out["decision"] = {"rule": "rung", "reason": head + (f"rung {link[0]} of {len(rungs)} served" if link else "no rung served") + f", {len(skipped)} skipped"}
        if cf and role in cf["reviewer_roles"]:   # CRT-05: the served rung is judged too (one link: nothing to reorder)
            out["cross_family"] = crossed(ctx, d, out, mode, cf, [], {})
        return out
    if not any(e["status"] == "usable" for e in chain):
        count = {s: sum(e["status"] == s for e in chain) for s in ("excluded", "needs_grant", "cooldown")}
        out["code"], out["reason"] = NO_LINK, (f"role {sd.idn(role, True)} under preset {sd.idn(preset, True)}: none of the {len(chain)} links of its chain is usable "
                                               f"({count['excluded']} excluded, {count['needs_grant']} waiting for a grant, {count['cooldown']} cooling down)")
    elif bad:
        out["code"], out["reason"] = bad["code"], f"card app {sd.idn(bad['app'], True)}: {bad['reason']}"
    return out


def lift(seg, want, rank):
    """seg with the links `want` holds moved ahead, stably, past links it does not hold, never past one of a lower privacy rank."""
    got = []
    for e in seg:
        i = len(got)
        while want(e) and i and not want(got[i - 1]) and rank(got[i - 1]) >= rank(e):
            i -= 1
        got.insert(i, e)
    return got

def crossed(ctx, d, out, mode, cf, items, ranks):
    """Cross-family review (body B2, ruling (2) of design C): the review role's chain reordered so that its usable links of another
    family than the builder's come first, inside each class-order item only (owner pins, preset pins and fallbacks keep place and
    order; no link moves ahead of a link of a lower privacy rank; nothing is added or unexcluded). The builder's family is that of
    the first usable link of builder_role resolved for the same card and project from the same data. Returns {builder_family,
    served_family, status: met|waived, reason, logged: false} (the CLI logs a waiver)."""
    chain, preset = out["chain"], out["preset"]["id"]
    res = lambda st, why, bf=None: {"builder_family": bf, "served_family": next((e["family"] for e in chain if e["status"] == "usable"), None),
                                    "status": st, "reason": why, "logged": False}
    if ctx.get("card") is None:
        return res("waived", "the review role is asked with no card, so there is no builder to differ from")
    if mode.get("cross_family_review") is not True:
        return res("waived", f"preset {sd.idn(preset, True)} does not ask for cross-family review (cross_family_review is not true)")
    try:
        b = resolve({**ctx, "role": cf["builder_role"], "rung": None, "tokens": None}, d)
    except sd.DataError as e:
        return res("waived", f"the builder's resolve refuses ({getattr(e, 'code', 'STL-CFG-310')}), so its family is not known")
    bf = next((e["family"] for e in b["chain"] if e["status"] == "usable"), None)
    if bf is None:
        return res("waived", "the builder's family is not known (its first usable link has no probe record or a null family, or it has no usable link)")
    other = lambda e: e["status"] == "usable" and e["family"] not in (None, bf)
    for a, z in items:
        chain[a:z] = lift(chain[a:z], other, lambda e: ranks.get(e["link_class"], float("inf")))
    r = res("met", None, bf)
    if r["served_family"] not in (None, bf):
        out["decision"]["reason"] += f"; cross-family review: links of a family other than the builder's ({bf}) go first inside each class-order item"
        return r
    return {**r, "status": "waived", "reason": "a usable link of another family is reachable only across a pin, a class-order item, a source or the privacy order"
            if any(map(other, chain)) else "no usable link of the review role has a known family other than the builder's"}

def withdraw(out, code, why):
    """A served answer whose log or alert line could not be written: no link (a rung's too), the code and why."""
    if out.get("rung"):
        out["rung"]["served"] = out["rung"]["link"] = None
    out["chain"], out["code"], out["reason"] = [], code, why

def waived_line(out):
    """The CLI's one trusted routing.cross-family-waiver line (STL-MDL-737) for a waived answer; in a worker environment none can
    be written, and the answer stays information (logged false). A line that cannot be written withdraws the answer (chain [],
    the log's code): an unlogged waiver is never silent."""
    import event_log as el, worker_env
    cf, nn = out["cross_family"], lambda v, none: none if v is None else v   # a missing card or family reads as missing, never as None
    if worker_env.reason():
        return
    try:
        el.append(el.build("routing.cross-family-waiver", f"role {out['role']} on " + nn(out["card"] and f"card {out['card']}", "no card"), code=WAIVER,
                           who={"role": out["role"]}, detail=f"card {nn(out['card'], 'none')}, role {out['role']}, preset {out['preset']['id']}, builder family "
                                  f"{nn(cf['builder_family'], 'not known')}, served family {nn(cf['served_family'], 'not known')}: {cf['reason']}"))
        cf["logged"] = True
    except Exception as e:   # fail closed
        code, why = (e.code, e.problem) if isinstance(e, el.EventError) else (LOG_FAILED, f"{type(e).__name__} while writing the waiver's event line")
        withdraw(out, code, f"the cross-family waiver's event line could not be written ({why}), so no link is served")

def main(argv):
    p = argparse.ArgumentParser(prog="resolve.py", allow_abbrev=False, description="The ordered chain of model links a role may use right now, and why (JSON).")
    p.add_argument("command", choices=["resolve"])
    for flag, required in (("role", True), ("project", True), ("card", False), ("tier", False), ("driver", False), ("task", False)):
        p.add_argument(f"--{flag}", required=required)
    p.add_argument("--rung", type=rung_arg, help="walk the role's escalation chain from rung N (0: the chain itself)")
    p.add_argument("--tokens", type=rung_arg, help="the task's size: a link whose probed effective context is below it is excluded")
    p.add_argument("--json", action="store_true", help="accepted: JSON is the only output")
    a = vars(p.parse_args(argv))   # a usage error exits 2 with a usage line (argparse)
    if a["rung"]:   # DC-01: the rung number comes from a host-side caller; a worker never asks, before anything is judged
        import worker_env
        w = worker_env.reason()
        if w:
            raise Refusal(WORKER, f"resolve --rung is asked from a worker environment ({w}); only a host-side caller walks the escalation chain")
    out = resolve(a)
    for code, problem in out.pop("ranking_alerts", []):
        sd.say(code, problem, alert=True)
    log = out.get("rung") and walked(out)
    lk = (out["rung"].get("link") if out.get("rung") else None) or next((e for e in out["chain"] if e["status"] == "usable"), None)   # the link this answer serves
    if lk and out["chain"] and lk.get("probed") is False and sd.needs_probe(sd.load(sd.load(sd.INDEX)["role_table"])["roles"][out["role"]].get("requirements", {}), None, a["tokens"]):
        if sd.alert_line(sd.UNPROBED, f"role {out['role']}: the answer serves link {link_key(lk)}, which has no probe record (run bin/probe.py due)") is False:
            withdraw(out, LOG_FAILED, f"the {sd.UNPROBED} alert line for unprobed link {link_key(lk)} could not be written, so no link is served")   # CRT-04: never served unflagged
    if (out.get("cross_family") or {}).get("status") == "waived" and any(e["status"] == "usable" for e in out["chain"]):   # no link served: no review to waive
        waived_line(out)
    print(json.dumps(out, indent=2, ensure_ascii=False))
    if out["code"]:
        sd.say(out["code"], out["reason"])
    if log:
        sd.say(log[0], log[1])
    return 1 if out["code"] else 0


def rung_arg(v):
    if not re.fullmatch(r"[0-9]+", v):
        raise argparse.ArgumentTypeError("must be a non-negative integer")
    return int(v)


def walked(out):
    """One trusted event line per skipped rung and one when no rung is served (the CLI's only writes). A line that cannot be
    written: a served rung is withdrawn (the log's code); an exhausted walk keeps its code and names the log's in rung.log_code.
    Returns None, or (the log's code, its problem)."""
    import event_log as el
    r, role, preset = out["rung"], out["role"], out["preset"]["id"]
    try:
        for x in r["skipped"]:
            el.append(el.build("routing.rung-skipped", f"rung {x['rung']} of role {role}", code=RUNG_SKIPPED, who={"role": role},
                               detail=f"role {role}, preset {preset}, rung {x['rung']}, link {link_key(x)}, status {x['status']}, code {x['code']}"))
        if r["served"] is None:
            el.append(el.build("routing.rung-exhausted", f"rung {r['requested']} of role {role}", code=EXHAUSTED, who={"role": role},
                               detail=f"role {role}, preset {preset}, rung {r['requested']}, last {r['last']}, skipped {len(r['skipped'])}"))
    except Exception as e:   # fail closed: an unlogged skip is never silent
        code, why = (e.code, e.problem) if isinstance(e, el.EventError) else (LOG_FAILED, f"{type(e).__name__} while writing the walk's event line")
        if r["served"] is not None:
            withdraw(out, code, f"the walk's event line could not be written ({why}), so no rung is served")
            return None
        r["log_code"] = code
        return code, why
    return None


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except sd.DataError as e:   # fail closed: one catalog line and one alert line, no chain, never a traceback
        sd.say(getattr(e, "code", "STL-CFG-310"), str(e), alert=True)
        sys.exit(1)
    except RecursionError:
        sd.say("STL-CFG-310", "a data file is nested too deeply", alert=True)
        sys.exit(1)
    except Exception as e:   # never the value: the type only
        sd.say("STL-CFG-310", f"{type(e).__name__}, an unexpected failure of the resolver", alert=True)
        sys.exit(1)
