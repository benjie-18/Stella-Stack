#!/usr/bin/env python3
"""The resolver (F2 design D2, with the design check and the wave-2 rulings), stdlib only: the ordered chain of model links a
role may use right now, and why. Read-only: no network, no write to any data file; it reads the failover state file (index key
routing_state; absent = no cooldown, no history) and the card facts store (index key card_facts) and creates neither. No role,
preset, link class, tier, driver, provider or model is named in this file: every id comes from the data, and every rule is the
one function of bin/stella_data.py (reach, policy_allows, route_problems, grant_in_force, link_class, unmet).
CLI: resolve.py resolve --role R --project P [--card C] [--tier T] [--driver D] [--task ID] [--json]   (JSON is the only output)
Import: resolve(ctx) -> the same dict (ctx: {role, project, card, tier, driver, task}); link_key(link) -> "<connection>/<model>",
the state file's key; role_view(role, project, card=None) -> what routing gives the role before any link is judged (its
docstring has the keys), the one copy of that rule: resolve() reads it there. Both write nothing and alert nothing: a
fail-closed answer is a stella_data.DataError (Refusal carries its code; any other one is data that `check` refuses, STL-CFG-310).
Output: {role, project, card, preset {id, source: card|project|global}, policy: project|default (a project the data policy
does not list follows the default), local_only, tier, driver, chain[], decision {rule, reason}, failure_history[] (the task's,
from the state file), stubs[] (features ids the answer rests on), apps[] {app, status, code, reason} (the card's apps),
code, reason (null when a link is usable and no app is refused)}. A chain entry: {connection, model, parameters, link_class,
source: pin:card|pin:project|pin:global|preset|fallback|last_resort, status: usable|needs_grant|cooldown|excluded, code,
reason, grant: null or {kind: privacy, data_class} or {kind: crossing, to_class}, mid_task, cooldown_until}.
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
 4 the role's requirements against the advertised capabilities (unmet; a stub);
 5 the preset: its allowed localities (the last-resort class is the one exception) and the role's class order; the
   last-resort class needs a crossing grant; any other class is excluded. An exempt role (routing data exempt_roles) follows
   its own class order instead, and is never a crossing;
 6 the data classes the role handles: hosted never excludes, and does so before the crossing grant of rule 5 is asked;
   hosted grant needs a privacy grant (route_problems);
 7 health: a link, or its connection, in cooldown in the state file (an `until` that is text but no date counts as ahead).
Chain order: the owner's pins (card, project, global assignment rows), the preset's pins for the role, the catalog's links
of each class of the order (a list item of the order is a group: best(), the one ranking), the preset's fallbacks, the
last-resort class. A link listed twice keeps its first place."""
import argparse, datetime, json, os, sys, types

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import stella_data as sd

# spelled out: the alert selftest counts a code as used only when a script holds it as a literal
NO_LINK, UNKNOWN, TERMS, AGGREGATOR, HARD = "STL-MDL-710", "STL-MDL-711", "STL-MDL-712", "STL-MDL-713", "STL-MDL-714"
UNMET, POLICY, PRIVACY, CROSSING, COOLDOWN = "STL-MDL-715", "STL-MDL-716", "STL-MDL-717", "STL-MDL-718", "STL-MDL-724"
READS = ("role-assignments", "routing", "connections", "data-policy", "grants", "features")   # the schemas a resolve reads
STUBS = ("routing-advertised-capabilities", "routing-advertised-context", "routing-observed-quota")   # features ids every answer rests on
STUB_SCORES = "routing-advertised-scores"   # and this one when a group was ranked


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
    healthy (not in cooldown), then the higher advertised score (none: last), then the more private class, then catalog order.
    A link waiting for a grant is not ranked down: it is never skipped silently. The links of one connection and class stay
    adjacent, placed by their best link."""
    def key(i):
        e, s = entries[i], scores.get(link_key(entries[i]))
        return (e["status"] == "excluded", e["status"] == "cooldown", s is None, -(s or 0), ranks[e["link_class"]], i)
    groups = {}
    for i, e in enumerate(entries):
        groups.setdefault((e["connection"], e["link_class"]), []).append(i)
    order = [i for g in sorted(groups.values(), key=lambda g: min(map(key, g))) for i in sorted(g, key=key)]
    if not order:
        return [], "the group has no link in the catalog"
    e = entries[order[0]]
    return [entries[i] for i in order], (
        f"{link_key(e)} ranks first of {len(order)} (ranked by: not excluded, healthy, advertised score, privacy rank, catalog order): "
        f"status {e['status']}, advertised score {json.dumps(scores.get(link_key(e)))}, privacy rank {ranks[e['link_class']]}")


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
        if not isinstance(p, str) or p in projects:
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
                                 policies=policies, local_only=any(p["mode"] == "local_only" for p in policies))


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
     pins[] {scope: card|project|global, chain[]}: the owner's, in chain order, preset_pins[], fallbacks[]: the preset's for the role}"""
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
            "fallbacks": rp.get("fallbacks", []) if not exempt or exempt["in_fallback_chain"] else []}


def resolve(ctx):
    role, project, card, tier, driver, task = (ctx.get(k) for k in ("role", "project", "card", "tier", "driver", "task"))
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    d = _data(project)
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
           "failure_history": history if isinstance(history, list) else [], "stubs": [s for s in STUBS if sd.phases(feats.get(s, {}))],
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
    need = req.get("allowed_data_classes", [])
    providers = [p for p in conn.values() if p["kind"] == "provider"]
    models = {(p["id"], m["id"]): m for p in providers for m in p["models"]}
    catalog = lambda group: [(p, m["id"]) for p in providers for m in p["models"] if sd.link_class(p, m["id"], rt) in group]
    crossing = [g for d in docs("grants") for g in d.get("crossing_grants", [])]
    broker = {}
    X = lambda code, why: ("excluded", code, why, None, None)

    def early(prov, model):
        """Rules 1 to 4: None, or why this link cannot serve the role at all."""
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
        mod = models.get((prov["id"], model))
        miss = ["its model is not listed for its connection"] if mod is None else sd.unmet(req, mod["capabilities"])
        return X(UNMET, f"the advertised capabilities do not meet the role's requirements ({', '.join(miss)})") if miss else None

    # the preset's needs class goes first for a listed task tier, or when no link of the order can serve the role (rules 1 to 4)
    notes = [f"class order {json.dumps(order)} of " + ("the exempt role" if exempt else "the Local only policy, which overrides the preset" if local_only
                                                       else f"preset {sd.idn(preset, True)}")]
    if needs is not None and needs not in flat(order):
        listed = tier in mode.get("frontier_when", {}).get("tiers", [])
        if listed or not any(early(p, m) is None for p, m in catalog(flat(order))):
            order = [needs] + order
            notes.append(f"class {sd.idn(needs, True)} goes first: " + (f"task tier {sd.idn(tier, True)} is listed for it" if listed
                                                                         else "no link of the class order meets the role's requirements"))
    inorder = flat(order)

    def judge(prov, model):
        """(status, code, reason, grant, cooldown_until) of one link: the first rule that fails names it."""
        cls, reach, no = sd.link_class(prov, model, rt), sd.reach(prov), early(prov, model)
        if no:
            return no
        if cls is None:
            return X(POLICY, "the link has no link class (its connection names none), so it is not routable")
        if not (exempt or local_only) and reach not in mode["allowed_localities"] and cls != last:   # Local only overrides the preset's localities
            return X(POLICY, f"preset {sd.idn(preset, True)} allows no link that is {reach} for routing")
        if cls not in inorder and (exempt or cls != last):
            return X(POLICY, f"link class {sd.idn(cls, True)} is not in the class order of " + (
                "this exempt role" if exempt else "the Local only policy" if local_only else f"preset {sd.idn(preset, True)} for this role"))
        probs = {m["kind"]: m for m in reversed(sd.route_problems(pols, need, prov, now, pid))}   # the first problem of each kind
        if "never" in probs:   # a class that never reaches a hosted link refuses before any grant is offered, a crossing grant too (DC-08)
            return X(POLICY, f"the connection {probs['never']['text']}")
        if cls not in inorder and not any(g["preset"] == preset and g["to_class"] == cls and sd.grant_in_force(g, pid, now) for g in crossing):
            return ("needs_grant", CROSSING, f"link class {sd.idn(cls, True)} is the last resort of preset {sd.idn(preset, True)}, and no crossing grant is in force here",
                    {"kind": "crossing", "to_class": cls}, None)
        if "grant" in probs:
            return ("needs_grant", PRIVACY, f"the connection {probs['grant']['text']}", {"kind": "privacy", "data_class": probs["grant"]["data_class"]}, None)
        cool = [u for u in (cooling(f"{prov['id']}/{model}"), cooling(prov["id"])) if u is not None]
        until = next((u for u in cool if u), None)
        return ("cooldown", COOLDOWN, "the link failed recently and cools down until " + (until or "a time its state entry gives as no date (it counts as ahead)"),
                None, until) if cool else ("usable", None, None, None, None)

    # ---- the chain
    seen = set()

    def links(pairs, source):
        got = []
        for prov, model, params in pairs:
            if prov is None or prov["kind"] != "provider" or (prov["id"], model) in seen:
                continue   # a pin that names no provider is refused by `check`; a link keeps its first place
            seen.add((prov["id"], model))
            status, code, why, grant, until = judge(prov, model)
            got.append({"connection": prov["id"], "model": model, "parameters": params, "link_class": sd.link_class(prov, model, rt), "source": source,
                        "status": status, "code": code, "reason": why, "grant": grant, "mid_task": False, "cooldown_until": until})
        return got
    pinned = lambda ls: [(sd.entry(conn, l["connection"]), l["model"], l["parameters"]) for l in ls]
    pins = [(pinned(p["chain"]), f"pin:{p['scope']}") for p in view["pins"]] + [(pinned(view["preset_pins"]), "preset")]
    chain = [e for ls, src in pins for e in links(ls, src)]
    ranked = False
    for it in order:
        got = links([(p, m, {}) for p, m in catalog(it if isinstance(it, list) else [it])], "preset")
        if isinstance(it, list):
            got, why = best(got, {link_key({"connection": c, "model": m}): x.get("score") for (c, m), x in models.items()}, {k: x["privacy_rank"] for k, x in classes.items()})
            notes.append(f"best suited of {json.dumps(it)}: {why}")
            ranked = True
        chain += got
    chain += links(pinned(view["fallbacks"]), "fallback")
    if last is not None and last not in inorder:
        chain += links([(p, m, {}) for p, m in catalog([last])], "last_resort")
    drv, named = drivers.get(driver), {(p["id"], m) for ls, _ in pins for p, m, _ in ls if p}
    for e in chain:   # mid-task only under a driver that allows it, never on a CLI login, on an aggregator only for the role pinned to that link
        p = conn[e["connection"]]
        e["mid_task"] = bool(drv and drv["mid_task"]) and p["type"] != "cli-login" and (not p.get("aggregator") or (p["id"], e["model"]) in named)
    out["chain"], out["decision"] = chain, {"rule": "best_suited" if ranked else "class_order", "reason": "; ".join(notes)}
    if ranked and sd.phases(feats.get(STUB_SCORES, {})):
        out["stubs"].append(STUB_SCORES)
    bad = next((a for a in apps if a["code"]), None)
    if not any(e["status"] == "usable" for e in chain):
        count = {s: sum(e["status"] == s for e in chain) for s in ("excluded", "needs_grant", "cooldown")}
        out["code"], out["reason"] = NO_LINK, (f"role {sd.idn(role, True)} under preset {sd.idn(preset, True)}: none of the {len(chain)} links of its chain is usable "
                                               f"({count['excluded']} excluded, {count['needs_grant']} waiting for a grant, {count['cooldown']} cooling down)")
    elif bad:
        out["code"], out["reason"] = bad["code"], f"card app {sd.idn(bad['app'], True)}: {bad['reason']}"
    return out


def main(argv):
    p = argparse.ArgumentParser(prog="resolve.py", allow_abbrev=False, description="The ordered chain of model links a role may use right now, and why (JSON).")
    p.add_argument("command", choices=["resolve"])
    for flag, required in (("role", True), ("project", True), ("card", False), ("tier", False), ("driver", False), ("task", False)):
        p.add_argument(f"--{flag}", required=required)
    p.add_argument("--json", action="store_true", help="accepted: JSON is the only output")
    out = resolve(vars(p.parse_args(argv)))   # a usage error exits 2 with a usage line (argparse)
    print(json.dumps(out, indent=2, ensure_ascii=False))
    if out["code"]:
        sd.say(out["code"], out["reason"])
    return 1 if out["code"] else 0


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
