#!/usr/bin/env python3
"""The QA loop's round state, tier floor, freeze and plan (phase Q1 item A1: design A1 with rulings DG-3, DG-5, DG-7), stdlib
only. Engine side, host only: every subcommand refuses in a worker environment (STL-CFG-312) before anything is read or parsed.
No role, tier, preset, trigger, severity or path is named here: ids come from .stella/qa-loop.json, .stella/routing.json and the
presets (through bin/resolve.py), paths from the index (qa_copies).
State is never a file of its own. state(card) is the fold of the trusted event lines (event_log.proof_lines(): chained lines of
this writer whose mac verifies) whose type starts with "qa." and whose what is the card id; a line's payload is its fields
outside the event envelope, then detail and new where those are objects. The untrusted stream, unchained and forged lines are
never read. Lines the fold reads (who writes them):
  qa.opened {project, tier, base, builder_role, preset, local_only}   (open) tier of record: the highest opened or raised
  qa.tier-raised {tier, from, reason}                                 (raise)
  qa.triggered {id, source, evidence, round}                          (open, freeze, trigger; B/A2 for a verdict source)
  qa.frozen {round, hash, tree, rung, depth, copy, base}              (freeze)
  qa.passed {round, hash} | qa.round-failed {round, open} | qa.escalated {round}   (A2 close): each closes its round
  qa.climbed {from_rung, to_rung, ...}: rung = to_rung, cap = rounds.cap_climb; qa.no-climb: cap = rounds.cap_no_climb
  qa.depth-raised {depth}: depth of record = the higher of it and the tier                                       (A2 close)
  qa.reopened {hash, tests}: not done until a round after it passes                                              (C2)
  qa.evidence {path, sha256, round}; qa.finding {fingerprint, round, role, severity, status, static, ...} (same fingerprint:
  roles merged, highest severity kept); qa.finding-confirmed | qa.finding-unconfirmed {fingerprint}: its status;
  qa.verdict {round, role, result, evidence}: the last per round and role                                       (B)
Before any climb the card is on rung 1 (bin/escalate.sh reads a card with no rungs.json entry as 1) and its cap is rounds.normal.
CLI (on failure a catalog code and its plain message on stderr, one alert line, exit 1, and with --json {card, code, problem}
on stdout; 2 usage):
  open --card C --project P --tier T --base H --builder-role R [--trigger ID]...   qa.opened (preset and local_only from
       resolve.py role_view for R); each named trigger one qa.triggered line. A lower tier than the one of record: STL-QA-101.
  raise --card C --tier T --reason TEXT       only upward (else STL-QA-101); qa.tier-raised
  trigger --card C --id ID                    a trigger whose source is owner only (STL-QA-102 otherwise); qa.triggered once
  freeze --card C --repo PATH --hash H        H a full commit id; refused (STL-QA-103) while the last round is not closed, past
       the cap or after an escalation. The copy: a standalone clone under qa_copies (--no-local --no-checkout, hooks off, no
       config of the builder's repo or the user's, H checked out on a throwaway branch); the builder's repo is only read.
       Triggers of source diff fire on the diff base..H (match.paths globs on changed paths, match.words regexes, case
       insensitive, on added lines); of source fix from round 2 on, when this fix changes more files than the original change
       (base..round 1) or is the second fix attempt; a diff that cannot be computed fires (fail closed). qa.triggered lines
       first, then qa.frozen.
  plan --card C --json                        per QA role {kind, count, depth, forced, slots[], note}: the card's depth capped
       by its preset's max_tier, counts from the role (or the preset's counts), extra_attacks for an attack role that runs;
       a fired trigger forces its force_roles on (no max_tier, own depth off ignored: the role's deepest depth) and sets the
       depth of the role kind it names; under when_local_only (resolve answered local_only, or a listed preset) every count is
       its count and parallel its parallel. Slots get distinct links of the resolver's usable chain for the role, reused (noted)
       when it has fewer. Data check refuses -> STL-QA-105, no plan (DG-3, fail closed).
  status --card C [--head H] --json           {tier, depth, round, rung, cap, frozen_hash, fix_list, open_blocking, pending,
       state, done, ...}; with --head, done also needs H to be the passed hash.
  done --card C --hash H                      exit 0 only when the last frozen round passed on exactly H and nothing was frozen
       or reopened after it (else STL-QA-106, no alert line).
Python: state(card, d=None) -> the fold; data() -> the served documents; is_done(s, h=None); plan(card, s, d)."""
import argparse, fnmatch, json, os, re, shutil, subprocess, sys, types

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import stella_data as sd

NOT_OPEN, LOWER, BAD, NOT_NOW, NO_COPY = "STL-QA-100", "STL-QA-101", "STL-QA-102", "STL-QA-103", "STL-QA-104"
QA_DATA, NOT_DONE, ROUTING, FAILED = sd.QA_DATA, "STL-QA-106", "STL-QA-107", "STL-QA-108"
PREFIX = "qa."
CLOSE = ("qa.passed", "qa.round-failed", "qa.escalated")
NOT_FIX = ("void", "pending", "unconfirmed")   # finding statuses that are not on the fix list
SRC_DIFF, SRC_FIX, SRC_OWNER = "diff", "fix", "owner"   # trigger sources (qa-loop schema)
ATTACK = "attacker"   # the role kind extra_attacks adds to
FIRST_RUNG = 1
CARD = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
HASH = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")   # a full commit id (SHA-1 or SHA-256 repository)
CAP = 20   # list items kept in a line's evidence


class Refuse(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def data():
    """The QA loop data and routing, served (sd.served: never while check refuses them or what they depend on, the presets
    included), the index and the QA depths in order. sd.DataError otherwise."""
    rows = {r["schema"]: r["id"] for r in sd.rows() if r["format"] == "json" and r["schema"] in ("qa-loop", "routing")}
    if len(rows) != 2:
        raise sd.DataError("the index has no qa-loop or no routing row")
    by = sd.served(list(rows.values()))
    one = lambda s: by["_rows"][rows[s]][0][0][1]
    return types.SimpleNamespace(qa=one("qa-loop"), rt=one("routing"), idx=sd.load(sd.INDEX), depths=sd.qa_depths(),
                                 tiers=[t["id"] for t in one("routing")["task_tiers"]],
                                 envelope=set(sd.load(f"{sd.SCHEMAS}/event.schema.json")["properties"]) - {"new", "detail"})


def payload(line, envelope):
    p = {k: v for k, v in line.items() if k not in envelope}
    for k in ("detail", "new"):
        if isinstance(line.get(k), dict):
            p.update(line[k])
    return p


def state(card, d=None):
    """The fold of the card's trusted qa.* lines (module docstring)."""
    d = d or data()
    q, tiers = d.qa, d.tiers
    sev = [x["id"] for x in q["severities"]]
    hi = lambda a, b: b if b in tiers and (a is None or tiers.index(b) > tiers.index(a)) else a
    s = {"card": card, "opened": False, "project": None, "base": None, "builder_role": None, "preset": None, "local_only": False,
         "tier": None, "depth": None, "triggers": [], "round": 0, "rung": FIRST_RUNG, "cap": q["rounds"]["normal"], "frozen": None,
         "rounds": {}, "closed": [], "passed": None, "reopened": False, "escalated": False, "findings": {}, "verdicts": {}, "evidence": {}}
    raised, reopened = None, -1
    mine = [l for l in el.proof_lines() if l.get("what") == card and str(l.get("type", "")).startswith(PREFIX)]
    for n, line in enumerate(mine):
        t, p = line["type"], payload(line, d.envelope)
        rnd = p["round"] if type(p.get("round")) is int else s["round"]
        if t == "qa.opened":
            s.update(opened=True, project=p.get("project"), base=p.get("base"), builder_role=p.get("builder_role"),
                     preset=p.get("preset"), local_only=p.get("local_only") is True, tier=hi(s["tier"], p.get("tier")))
        elif t == "qa.tier-raised":
            s["tier"] = hi(s["tier"], p.get("tier"))
        elif t == "qa.depth-raised":
            raised = hi(raised, p.get("depth"))
        elif t == "qa.triggered":
            if p.get("id") in q["triggers"] and p["id"] not in s["triggers"]:
                s["triggers"].append(p["id"])
        elif t == "qa.frozen":
            s["round"] = rnd
            s["frozen"] = s["rounds"][rnd] = {**{k: p.get(k) for k in ("round", "hash", "tree", "rung", "depth", "copy", "base")}, "at": n}
        elif t in CLOSE:
            s["closed"] += [rnd] if rnd not in s["closed"] else []
            if t == CLOSE[0]:
                s["passed"] = {"round": rnd, "hash": p.get("hash"), "at": n}
            if t == CLOSE[2]:
                s["escalated"] = True
        elif t == "qa.climbed":
            s["rung"], s["cap"] = p["to_rung"] if type(p.get("to_rung")) is int else s["rung"], q["rounds"]["cap_climb"]
        elif t == "qa.no-climb":
            s["cap"] = q["rounds"]["cap_no_climb"]
        elif t == "qa.reopened":
            reopened = n
        elif t == "qa.evidence" and isinstance(p.get("path"), str):
            s["evidence"][p["path"]] = {"sha256": p.get("sha256"), "round": rnd}
        elif t == "qa.finding" and isinstance(p.get("fingerprint"), str):
            f = s["findings"].setdefault(p["fingerprint"], {"roles": []})
            old = f.get("severity")
            f.update({k: v for k, v in p.items() if k not in ("fingerprint", "role")}, round=rnd)
            if old in sev and (f.get("severity") not in sev or sev.index(old) < sev.index(f["severity"])):
                f["severity"] = old
            f["roles"] += [p["role"]] if p.get("role") not in f["roles"] else []
        elif t.startswith("qa.finding-") and p.get("fingerprint") in s["findings"]:
            s["findings"][p["fingerprint"]]["status"] = t[len("qa.finding-"):]
        elif t == "qa.verdict" and isinstance(p.get("role"), str):
            s["verdicts"].setdefault(rnd, {})[p["role"]] = {"result": p.get("result"), "evidence": p.get("evidence")}
    s["depth"] = hi(s["tier"], raised)
    s["reopened"] = reopened > (s["passed"]["at"] if s["passed"] else -1)
    return s


def is_done(s, h=None):
    """The last frozen round passed on its frozen hash (h too, when given), and nothing was frozen or reopened after the pass."""
    p, f = s["passed"], s["frozen"]
    return bool(p and f and not s["reopened"] and p["round"] == f["round"] and p["at"] > f["at"] and p["hash"] == f["hash"]
                and (h is None or h == p["hash"]))


def put(card, t, new, text):
    el.append(el.build(t, card, new=new, detail=text), scrub_detail=False)
    print(json.dumps({"type": t, "card": card, **new}))


def opened(o, d):
    if not isinstance(o.card, str) or not CARD.fullmatch(o.card):
        raise Refuse(BAD, "the card id is not a plain id (letters, digits, dot, dash, underscore; at most 64)")
    s = state(o.card, d)
    if not s["opened"]:
        raise Refuse(NOT_OPEN, f"card {o.card}")
    return s


def known_tier(t, d):
    if t not in d.tiers:
        raise Refuse(BAD, f"the tier is not a task tier of the routing data ({sd.desc(t)})")


def full_hash(h, what):
    if not isinstance(h, str) or not HASH.fullmatch(h):
        raise Refuse(BAD, f"{what} is not a full commit id (40 or 64 lowercase hex characters)")


# ---- open, raise, trigger ----
def cmd_open(o, d):
    if not CARD.fullmatch(o.card):
        raise Refuse(BAD, "the card id is not a plain id (letters, digits, dot, dash, underscore; at most 64)")
    known_tier(o.tier, d)
    full_hash(o.base, "the base")
    if o.builder_role not in d.rt["builder_roles"]:
        raise Refuse(BAD, "the builder role is not one of the routing data's builder_roles")
    for t in o.trigger:
        if t not in d.qa["triggers"]:
            raise Refuse(BAD, "a trigger is not one of the QA loop data's triggers")
    s = state(o.card, d)
    if s["opened"] and d.tiers.index(o.tier) < d.tiers.index(s["tier"]):
        raise Refuse(LOWER, f"open at tier {o.tier} is below the card's tier of record {s['tier']}")
    import resolve
    try:
        v = resolve.role_view(o.builder_role, o.project, o.card)
    except sd.DataError as e:
        raise Refuse(ROUTING, f"{getattr(e, 'code', 'STL-CFG-310')} {str(e)[:200]}")
    put(o.card, "qa.opened", {"project": o.project, "tier": o.tier, "base": o.base, "builder_role": o.builder_role,
                              "preset": v["preset"]["id"], "preset_source": v["preset"]["source"], "local_only": v["local_only"] is True},
        f"QA loop opened at tier {o.tier}")
    for t in dict.fromkeys(o.trigger):
        if t not in s["triggers"]:
            put(o.card, "qa.triggered", {"id": t, "source": d.qa["triggers"][t]["source"], "evidence": "named when the QA loop was opened",
                                         "round": s["round"]}, f"trigger {t} named at open")
    return 0


def cmd_raise(o, d):
    s = opened(o, d)
    known_tier(o.tier, d)
    if d.tiers.index(o.tier) <= d.tiers.index(s["tier"]):
        raise Refuse(LOWER, f"raise to {o.tier} is not above the card's tier of record {s['tier']}")
    put(o.card, "qa.tier-raised", {"tier": o.tier, "from": s["tier"], "reason": o.reason[:200]}, f"QA tier raised to {o.tier}")
    return 0


def cmd_trigger(o, d):
    s = opened(o, d)
    t = d.qa["triggers"].get(o.id)
    if t is None or t["source"] != SRC_OWNER:
        raise Refuse(BAD, "the trigger is not one of the QA loop data's triggers whose source is the owner's command")
    if o.id in s["triggers"]:
        print(json.dumps({"type": "qa.triggered", "card": o.card, "id": o.id, "already": True}))
        return 0
    put(o.card, "qa.triggered", {"id": o.id, "source": t["source"], "evidence": "the owner's trigger command", "round": s["round"]},
        f"trigger {o.id} by the owner")
    return 0


# ---- freeze: the disposable copy and the triggers on its diff ----
def git(args, cwd, d):
    """git with no hook, no fsmonitor and no config but the repository's own (no system or user config); never a prompt."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0")
    # shortcut: git calls share the test runner's limit (tests.timeout_s); give them their own when the data has one
    return subprocess.run(["git", "-c", f"core.hooksPath={os.devnull}", "-c", "core.fsmonitor=false", *args], cwd=cwd, env=env,
                          capture_output=True, text=True, errors="replace", timeout=d.qa["tests"]["timeout_s"])


def make_copy(repo, h, card, n, d):
    """(copy folder, tree id): H cloned standalone under qa_copies/<card>/round-<n>, checked out on a branch of its own."""
    base = el.path(d.idx["qa_copies"])
    el.mkdirs(os.path.join(base, card))
    dest = os.path.join(base, card, f"round-{n}")
    if os.path.islink(dest):
        raise Refuse(NO_COPY, "the copy's folder is a symbolic link")
    if os.path.lexists(dest):
        shutil.rmtree(dest)   # a copy left by a freeze that wrote no line
    try:
        steps = (["clone", "--quiet", "--no-local", "--no-checkout", "--no-hardlinks", "-c", f"core.hooksPath={os.devnull}", "--", repo, dest], None), \
                (["checkout", "--quiet", "-b", f"qa/{card}/round-{n}", h], dest)
        for args, cwd in steps:
            r = git(args, cwd, d)
            if r.returncode:
                raise Refuse(NO_COPY, f"git {args[0]} failed (exit {r.returncode}): {r.stdout.strip()[-160:]}")
        head, tree = (git(["rev-parse", "--verify", x], dest, d).stdout.strip() for x in ("HEAD", "HEAD^{tree}"))
        if head != h or not HASH.fullmatch(tree):
            raise Refuse(NO_COPY, "the copy's HEAD is not the commit asked for")
    except BaseException:
        shutil.rmtree(dest, ignore_errors=True)
        raise
    return dest, tree


def changed(dest, a, b, d):
    """The paths changed from a to b and the added lines, or None when the diff cannot be computed."""
    names = git(["diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", a, b, "--"], dest, d)
    patch = git(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "-U0", a, b, "--"], dest, d)
    if names.returncode or patch.returncode:
        return None
    # shortcut: an added line whose text starts with "++ " is read as a file header and not scanned; parse hunks if that matters
    return [p for p in names.stdout.split("\0") if p], [l[1:] for l in patch.stdout.splitlines() if l.startswith("+") and not l.startswith("+++ ")]


def glob(p, g):
    """fnmatch (a * crosses folders); a leading **/ also matches at the top folder."""
    return fnmatch.fnmatchcase(p, g) or (g.startswith("**/") and fnmatch.fnmatchcase(p, g[3:]))


def fired(s, d, dest, h, n):
    """[(trigger id, source, evidence)] of the triggers this freeze fires (DG-5); a trigger already fired is not fired again."""
    out = []
    for tid, t in d.qa["triggers"].items():
        if tid in s["triggers"]:
            continue
        if t["source"] == SRC_DIFF:
            c = changed(dest, s["base"], h, d)
            if c is None:
                ev = {"unreadable": "the diff from the base cannot be computed (fail closed)"}
            else:
                m = t.get("match") or {"paths": [], "words": []}
                paths = [p for p in c[0] if any(glob(p, g) for g in m["paths"])]
                words = [w for w in m["words"] if any(re.search(w, l, re.I) for l in c[1])]
                ev = {"paths": paths[:CAP], "words": words[:CAP]} if paths or words else None
        elif t["source"] == SRC_FIX and n > 1:
            first, prev = s["rounds"].get(1), s["rounds"].get(n - 1)
            a = changed(dest, s["base"], first["hash"], d) if first else None
            b = changed(dest, prev["hash"], h, d) if prev else None
            if a is None or b is None:
                ev = {"unreadable": "the fix or the original change cannot be diffed (fail closed)"}
            elif n - 1 >= 2:   # the design's "second fix attempt": round 1 is the change, every later round a fix
                ev = {"fix_attempt": n - 1}
            elif len(b[0]) > len(a[0]):
                ev = {"files_fix": len(b[0]), "files_original": len(a[0])}
            else:
                ev = None
        else:
            continue
        if ev:
            out.append((tid, t["source"], ev))
    return out


def cmd_freeze(o, d):
    s = opened(o, d)
    full_hash(o.hash, "the hash")
    if s["escalated"]:
        raise Refuse(NOT_NOW, "the card's QA loop was escalated to the owner")
    if s["round"] and s["round"] not in s["closed"]:
        raise Refuse(NOT_NOW, f"round {s['round']} is not closed yet")
    n = s["round"] + 1
    if n > s["cap"]:
        raise Refuse(NOT_NOW, f"round {n} would pass the card's round cap of {s['cap']}")
    repo = os.path.abspath(o.repo)
    if not os.path.isdir(repo):
        raise Refuse(BAD, "the repository path is not a folder")
    dest, tree = make_copy(repo, o.hash, o.card, n, d)
    for tid, src, ev in fired(s, d, dest, o.hash, n):
        put(o.card, "qa.triggered", {"id": tid, "source": src, "evidence": ev, "round": n}, f"trigger {tid} fired at the round {n} freeze")
    put(o.card, "qa.frozen", {"round": n, "hash": o.hash, "tree": tree, "rung": s["rung"], "depth": s["depth"],
                              "copy": os.path.relpath(dest, el.ROOT), "base": s["base"]}, f"QA round {n} frozen")
    return 0


# ---- plan, status, done ----
def plan(card, s, d):
    """The round's plan (module docstring)."""
    q, depths, tiers = d.qa, d.depths, d.tiers
    off, deeper = depths[0], lambda a, b: b if depths.index(b) > depths.index(a) else a
    if not any(s["depth"] in x[f] for x in q["roles"].values() for f in ("depth", "count")):   # check judges only the tiers QA roles name
        raise Refuse(QA_DATA, f"no QA role names the card's depth {s['depth']}: the QA loop data has no plan for it")
    pre = q["presets"].get(s["preset"]) or {"max_tier": None, "extra_attacks": 0, "counts": {}}
    capped = s["depth"] if pre["max_tier"] is None or tiers.index(s["depth"]) <= tiers.index(pre["max_tier"]) else pre["max_tier"]
    lo = q["when_local_only"]
    local = s["local_only"] or s["preset"] in lo["presets"]
    trig = [q["triggers"][t] for t in s["triggers"]]
    forced = {r for t in trig for r in t["force_roles"]}
    roles = {}
    for r, x in q["roles"].items():
        t = s["depth"] if r in forced else capped
        depth, count = x["depth"].get(t, off), pre["counts"].get(r, {}).get(t, x["count"].get(t, 0))
        if r in forced:
            depth, count = deeper(depth, max(x["depth"].values(), key=depths.index, default=off)), max(count, 1)
        for tr in trig:   # a trigger names the depth of a role kind under that kind's name
            if tr.get(x["kind"]) in depths:
                depth = deeper(depth, tr[x["kind"]])
        if x["kind"] == ATTACK and depth != off and count >= 1:
            count += pre["extra_attacks"]
        roles[r] = {"kind": x["kind"], "count": lo["count"] if local else count, "depth": depth, "forced": r in forced}
    import resolve
    try:
        rd = resolve._data(s["project"])
    except Exception:
        rd = None   # each resolve() below loads (and refuses) on its own
    for r, e in roles.items():
        n = e["count"] if e["depth"] != off else 0
        links, why = [], None
        if n:
            try:
                a = resolve.resolve({"role": r, "project": s["project"], "card": card, "tier": s["tier"]}, rd)
                links = list(dict.fromkeys(resolve.link_key(l) for l in a["chain"] if l.get("status") == "usable"))
                why = None if links else a.get("code") or "no usable link"
            except Exception as x:
                why = getattr(x, "code", None) or type(x).__name__
        e["slots"] = [{"slot": i + 1, "link": links[i % len(links)] if links else None, "reused": bool(links) and i >= len(links)} for i in range(n)]
        if why:
            e["note"] = f"the resolver gives this role no link here ({why}): its own routing picks one when it runs"
        elif n > len(links):
            e["note"] = "the chain has fewer distinct links than slots: links are reused"
    return {"card": card, "tier": s["tier"], "depth": s["depth"], "round": s["round"], "preset": s["preset"], "local_only": local,
            "parallel": lo["parallel"] if local else True, "triggers": s["triggers"], "roles": roles}


def status(s, d, head=None):
    q = d.qa
    sev = [x["id"] for x in q["severities"]]
    blocks = {x["id"]: x["blocks_on"] for x in q["severities"]}
    cur = [dict(f, fingerprint=k) for k, f in s["findings"].items() if f.get("round") == s["round"]]
    fix = sorted((f for f in cur if f.get("status") not in NOT_FIX),
                 key=lambda f: (sev.index(f["severity"]) if f.get("severity") in sev else len(sev), f["fingerprint"]))
    blocking = [f["fingerprint"] for f in fix if blocks.get(f.get("severity")) == "all" or s["depth"] in blocks.get(f.get("severity"), [])]
    done = is_done(s, head)
    f = s["frozen"] or {}
    st = ("escalated" if s["escalated"] else "done" if done else "reopened" if s["reopened"] else "opened" if not s["round"]
          else "in-round" if s["round"] not in s["closed"] else "passed" if s["passed"] and s["passed"]["round"] == s["round"] else "failed")
    return {"card": s["card"], "tier": s["tier"], "depth": s["depth"], "round": s["round"], "rung": s["rung"], "cap": s["cap"],
            "frozen_hash": f.get("hash"), "tree": f.get("tree"), "copy": f.get("copy"), "preset": s["preset"], "local_only": s["local_only"],
            "triggers": s["triggers"], "fix_list": fix, "open_blocking": len(blocking), "blocking": blocking,
            "pending": sum(1 for x in cur if x.get("status") == NOT_FIX[1]), "passed_hash": (s["passed"] or {}).get("hash"),
            "state": st, "done": done}


def cmd_plan(o, d):
    print(json.dumps(plan(o.card, opened(o, d), d)))
    return 0


def cmd_status(o, d):
    if o.head is not None:
        full_hash(o.head, "the head")
    print(json.dumps(status(opened(o, d), d, o.head)))
    return 0


def cmd_done(o, d):
    s = opened(o, d)
    full_hash(o.hash, "the hash")
    if not is_done(s, o.hash):
        el.say(NOT_DONE, f"card {o.card}, hash {o.hash}")   # an answer, not a failure: no alert line
        return 1
    print(json.dumps({"card": o.card, "hash": o.hash, "done": True}))
    return 0


CMDS = {"open": cmd_open, "raise": cmd_raise, "trigger": cmd_trigger, "freeze": cmd_freeze, "plan": cmd_plan, "status": cmd_status, "done": cmd_done}


def main(argv):
    try:   # before the arguments: in a worker environment every subcommand, known or not, is refused the same way
        el.owner_only()
    except el.EventError as e:
        return el.fail(e.code, e.problem)
    ap = argparse.ArgumentParser(prog="qa_loop.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = {c: sub.add_parser(c) for c in CMDS}
    for p in a.values():
        p.add_argument("--card", required=True)
    for c in ("plan", "status"):
        a[c].add_argument("--json", action="store_true")
    a["open"].add_argument("--project", required=True)
    a["open"].add_argument("--tier", required=True)
    a["open"].add_argument("--base", required=True)
    a["open"].add_argument("--builder-role", required=True)
    a["open"].add_argument("--trigger", action="append", default=[])
    a["raise"].add_argument("--tier", required=True)
    a["raise"].add_argument("--reason", required=True)
    a["trigger"].add_argument("--id", required=True)
    a["freeze"].add_argument("--repo", required=True)
    a["freeze"].add_argument("--hash", required=True)
    a["status"].add_argument("--head")
    a["done"].add_argument("--hash", required=True)
    o = ap.parse_args(argv)
    try:
        d = data()
        return CMDS[o.cmd](o, d)
    except (Refuse, el.EventError) as e:
        code, problem = e.code, e.problem
    except sd.DataError as e:
        code, problem = QA_DATA, str(e)[:300]
    except Exception as e:   # shortcut: one code for every surprise; the exception type tells a bug apart
        code, problem = FAILED, f"unexpected {type(e).__name__}"
    if getattr(o, "json", False):   # a --json caller gets an answer it can parse: the code, no plan or status
        print(json.dumps({"card": o.card, "code": code, "problem": el.scrub(problem)}))
    return el.fail(code, problem)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
