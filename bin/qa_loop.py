#!/usr/bin/env python3
"""The QA loop's round state, tier floor, freeze, plan and close (phase Q1 items A1 and A2: design A1, A2 with rulings DG-1, DG-2,
DG-3, DG-5, DG-7), stdlib
only. Engine side, host only: every subcommand refuses in a worker environment (STL-CFG-312) before anything is read or parsed.
No role, tier, preset, trigger, severity or path is named here: ids come from .stella/qa-loop.json, .stella/routing.json and the
presets (through bin/resolve.py), paths from the index (qa_copies).
State is never a file of its own. state(card) is the fold of the trusted event lines (event_log.proof_lines(): chained lines of
this writer whose mac verifies) whose type starts with "qa." and whose what is the card id; a line's payload is its fields
outside the event envelope, then detail and new where those are objects. The untrusted stream, unchained and forged lines are
never read. Lines the fold reads (who writes them):
  qa.opened {project, tier, base, builder_role, preset, local_only}   (open) the first line is of record; tier: the highest opened or raised
  qa.tier-raised {tier, from, reason}                                 (raise)
  qa.triggered {id, source, evidence, round}                          (open, freeze, trigger; B/A2 for a verdict source)
  qa.frozen {round, hash, tree, rung, depth, copy, base}              (freeze)
  qa.passed {round, hash} | qa.round-failed {round, open} | qa.escalated {round}   (A2 close): each closes its round
  qa.climbed {from_rung, to_rung, ...}: rung = to_rung, cap = rounds.cap_climb; qa.no-climb: cap = rounds.cap_no_climb
  qa.depth-raised {depth}: depth of record = the higher of it and the tier                                       (A2 close)
  qa.reopened {hash, tests}: not done until a round after it passes; after a pass in the last round the cap
  becomes that round + rounds.normal (RT1-12: a reopened card gets rounds, then escalates)                       (C2)
  qa.evidence {path, sha256, round}; qa.finding {fingerprint, round, role, severity, status, static, ...} (same fingerprint and
  round: roles merged, highest severity and strongest status (STRENGTH) kept, each copy's role, repro, evidence and status kept
  in subs, never replaced; a later round starts afresh); qa.finding-confirmed {fingerprint, round}: confirmed;
  qa.finding-unconfirmed: unconfirmed, only from pending (or reported judged pending, below);
  qa.verdict {round, role, slot, result, hash, evidence}: per round, role and slot (a line with no slot is slot 1); a fail or
  unverified is never replaced by a later line (RTF-01)                                                          (B)
After the fold a reported finding of the current round whose highest severity blocks at the depth of record is judged again
(RTF-04): pending when a copy that counts has a repro, else unconfirmed.
Every command that writes a card's state (here open, raise, trigger, freeze, close; qa_findings evidence, submit, repro,
verdict) runs under card_lock(card): one lock per card whatever the id's spelling, so close reads the state it decides on
with no writer in between (RTF-05).
Card ids compare case-insensitively (same(): one card whatever the spelling); the spelling of the first qa.opened line is the
card's (s["card"]), and every command writes its lines and paths under it.
Before any climb the card is on rung 1 (bin/escalate.sh reads a card with no rungs.json entry as 1) and its cap is rounds.normal.
CLI (every subcommand takes --json: its answer is JSON in any case; on failure a catalog code and its plain message on stderr,
one alert line, exit 1, and with --json {card, code, problem} on stdout; 2 usage):
  open --card C --project P --tier T --base H --builder-role R [--trigger ID]...   qa.opened (preset and local_only from
       resolve.py role_view for R); each named trigger one qa.triggered line. Opened once: a card already open under any
       spelling is refused (STL-QA-101); raise and trigger change it.
  raise --card C --tier T --reason TEXT       only upward (else STL-QA-101); qa.tier-raised
  trigger --card C --id ID                    a trigger whose source is owner only (STL-QA-102 otherwise); qa.triggered once
  freeze --card C --repo PATH --hash H        H a full commit id; refused (STL-QA-103) while the last round is not closed, past
       the cap or after an escalation. The copy: a standalone clone under qa_copies (--no-local --no-checkout, hooks off, no
       config of the builder's repo or the user's, H checked out on a throwaway branch); the builder's repo is only read.
       Triggers of source diff fire on the diff base..H (diff(): text, attributes of the copy not followed), rename detection off (match.paths globs on changed paths, both
       sides of a rename, match.words regexes on added lines, both case insensitive); of source fix from round 2 on, when this fix changes more files than the original change
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
  close --card C                              the open round (else STL-QA-110): refused (STL-QA-109, nothing written) while a
       finding of the round is pending its repro (DG-2). The fix list is qa_findings.merge() of the round's findings that
       still stand (qa_findings.stands: confirmed and static ones always, others while the evidence of a copy holds). No
       blocking finding and no verdict other than pass from any slot: qa.passed {round, hash} when every slot the plan lists
       has a trusted pass on the frozen hash with evidence that holds, else STL-QA-110 (the round stays open, DG-1). A
       blocking finding or a failed verdict of any slot fails the round: after round rounds.normal the builder role
       climbs (bin/resolve.py resolve --rung rounds.climb_rung: a served rung, in cooldown too, -> qa.climbed {from_rung,
       to_rung, from_link, to_link, open, reason}, cap rounds.cap_climb, then the rungs.json projection (index qa_rungs) under
       its lock, STL-QA-112 when it cannot be written; no higher rung (STL-MDL-731) -> qa.no-climb, cap rounds.cap_no_climb; any
       other answer: STL-QA-111, nothing written); a card at depth_bump.from failing round after_failed_round or later ->
       qa.depth-raised {depth: depth_bump.to}; then qa.round-failed {round, open}, or at the cap qa.escalated {round, open} and
       one owner alert (STL-QA-113, the fix list) through bin/alert.sh: the card's QA loop is paused (freeze refuses).
Python: state(card, d=None) -> the fold; data() -> the served documents; is_done(s, h=None); plan(card, s, d)."""
import argparse, contextlib, fnmatch, json, os, re, shutil, subprocess, sys, types

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import stella_data as sd

NOT_OPEN, LOWER, BAD, NOT_NOW, NO_COPY = "STL-QA-100", "STL-QA-101", "STL-QA-102", "STL-QA-103", "STL-QA-104"
QA_DATA, NOT_DONE, ROUTING, FAILED = sd.QA_DATA, "STL-QA-106", "STL-QA-107", "STL-QA-108"
PENDING, NOT_CLOSED, NO_CLIMB, RUNGS, ESCALATED = "STL-QA-109", "STL-QA-110", "STL-QA-111", "STL-QA-112", "STL-QA-113"   # close (A2)
PREFIX = "qa."
CLOSE = ("qa.passed", "qa.round-failed", "qa.escalated")
NOT_FIX = ("void", "pending", "unconfirmed")   # finding statuses that are not on the fix list
STRENGTH = ("void", "unconfirmed", "reported", "pending", "static", "confirmed")   # finding statuses, weakest first
RESULTS = ("pass", "fail", "unverified")   # verdict results (qa-loop schema), the pass first
FIRST_SLOT = 1   # a verdict line that names no slot
SRC_DIFF, SRC_FIX, SRC_OWNER = "diff", "fix", "owner"   # trigger sources (qa-loop schema)
ATTACK = "attack"   # the role kind extra_attacks adds to
FIRST_RUNG = 1
CARD = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
HASH = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")   # a full commit id (SHA-1 or SHA-256 repository)
CAP = 20   # list items kept in a line's evidence


class Refuse(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def data(card=None, project=None):
    """The QA loop data and routing, served (sd.served: never while check refuses them or what they depend on, the presets
    included), the index and the QA depths in order. sd.DataError otherwise. With a card: its settings, the file with its
    project's and then its own overrides merged in (sd.qa_scoped; the project is open's --project, else the card's trusted
    qa.opened line), refused when the merged settings break a rule."""
    rows = {r["schema"]: r["id"] for r in sd.rows() if r["format"] == "json" and r["schema"] in ("qa-loop", "routing")}
    if len(rows) != 2:
        raise sd.DataError("the index has no qa-loop or no routing row")
    by = sd.served(list(rows.values()))
    one = lambda s: by["_rows"][rows[s]][0][0][1]
    env = set(sd.load(f"{sd.SCHEMAS}/event.schema.json")["properties"]) - {"new", "detail"}
    q = one("qa-loop")
    if card is not None:
        if project is None:
            project = next((payload(x, env).get("project") for x in el.proof_lines() if x.get("type") == "qa.opened" and same(x.get("what"), card)), None)
        q = sd.qa_scoped(q, one("routing"), project if isinstance(project, str) else None, card)
    return types.SimpleNamespace(qa=q, rt=one("routing"), idx=sd.load(sd.INDEX), depths=sd.qa_depths(),
                                 tiers=[t["id"] for t in one("routing")["task_tiers"]], envelope=env)


def payload(line, envelope):
    p = {k: v for k, v in line.items() if k not in envelope}
    for k in ("detail", "new"):
        if isinstance(line.get(k), dict):
            p.update(line[k])
    return p


def state(card, d=None):
    """The fold of the card's trusted qa.* lines (module docstring)."""
    d = d or data(card)
    q, tiers = d.qa, d.tiers
    sev = [x["id"] for x in q["severities"]]
    hi = lambda a, b: b if b in tiers and (a is None or tiers.index(b) > tiers.index(a)) else a
    s = {"card": card, "opened": False, "project": None, "base": None, "builder_role": None, "preset": None, "local_only": False,
         "tier": None, "depth": None, "triggers": [], "round": 0, "rung": FIRST_RUNG, "cap": q["rounds"]["normal"], "frozen": None,
         "rounds": {}, "closed": [], "passed": None, "reopened": False, "escalated": False, "findings": {}, "verdicts": {}, "evidence": {}}
    rank = lambda x: sev.index(x) if x in sev else len(sev)
    strong = lambda x: STRENGTH.index(x) if x in STRENGTH else -1
    raised, reopened = None, -1
    mine = [l for l in el.proof_lines() if same(l.get("what"), card) and str(l.get("type", "")).startswith(PREFIX)]
    for n, line in enumerate(mine):
        t, p = line["type"], payload(line, d.envelope)
        rnd = p["round"] if type(p.get("round")) is int else s["round"]
        if t == "qa.opened":
            if not s["opened"]:   # opened once (RT1-08): the first line is of record, a later one can only raise the tier
                s.update(opened=True, card=line["what"], project=p.get("project"), base=p.get("base"), builder_role=p.get("builder_role"),
                         preset=p.get("preset"), local_only=p.get("local_only") is True)
            s["tier"] = hi(s["tier"], p.get("tier"))
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
            if s["passed"] and s["passed"]["round"] == s["round"]:   # RT1-12: a passed card reopened gets rounds.normal more rounds
                s["cap"] = max(s["cap"], s["round"] + q["rounds"]["normal"])
        elif t == "qa.evidence" and isinstance(p.get("path"), str):
            s["evidence"][p["path"]] = {"sha256": p.get("sha256"), "round": rnd}
        elif t == "qa.finding" and isinstance(p.get("fingerprint"), str):
            f = s["findings"].get(p["fingerprint"])
            if not f or f["round"] != rnd:   # a round judges its findings afresh
                f = s["findings"][p["fingerprint"]] = {"round": rnd, "severity": None, "status": None, "static": False, "roles": [], "subs": []}
            # RT1-02: a copy adds its own repro and evidence (subs), never replaces them; severity and status only climb
            f.update({k: p.get(k) for k in ("check", "file", "lines", "test")}, static=f["static"] or p.get("static") is True)
            f["severity"] = p.get("severity") if rank(p.get("severity")) < rank(f["severity"]) else f["severity"]
            f["status"] = p.get("status") if strong(p.get("status")) > strong(f["status"]) else f["status"]
            f["subs"].append({k: p.get(k) for k in ("role", "repro", "evidence", "status")})
            f["roles"] += [p["role"]] if isinstance(p.get("role"), str) and p["role"] not in f["roles"] else []
        elif t in ("qa.finding-confirmed", "qa.finding-unconfirmed") and p.get("fingerprint") in s["findings"]:
            f = s["findings"][p["fingerprint"]]
            if f["round"] == rnd and (t == "qa.finding-confirmed" or f["status"] in (NOT_FIX[1], STRENGTH[2])):   # only a pending (or judged pending) one goes unconfirmed
                f["status"] = t[len("qa.finding-"):]
        elif t == "qa.verdict" and isinstance(p.get("role"), str):
            by = s["verdicts"].setdefault(rnd, {}).setdefault(p["role"], {})
            slot = p["slot"] if type(p.get("slot")) is int else FIRST_SLOT
            if by.get(slot, {}).get("result", RESULTS[0]) == RESULTS[0]:   # RTF-01: a fail or unverified is never replaced
                by[slot] = {"result": p.get("result"), "hash": p.get("hash"), "evidence": p.get("evidence")}
    s["depth"] = hi(s["tier"], raised)
    blocks = {x["id"]: x["blocks_on"] for x in q["severities"]}
    for f in s["findings"].values():   # RTF-04: blocking is judged now, from the depth of record and the highest severity
        b = blocks.get(f["severity"], [])
        if f["round"] == s["round"] and f["status"] == STRENGTH[2] and (b == "all" or s["depth"] in b):
            f["status"] = NOT_FIX[1] if any(x.get("repro") is not None and x.get("status") != NOT_FIX[0] for x in f["subs"]) else NOT_FIX[2]
    s["reopened"] = reopened > (s["passed"]["at"] if s["passed"] else -1)
    return s


def same(what, card):
    """RT1-07: one card id whatever its letter case (ids are ASCII: CARD)."""
    return isinstance(what, str) and what.isascii() and isinstance(card, str) and what.lower() == card.lower()


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
    o.card = s["card"]   # the spelling the card was opened under: every line and path uses it
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
    if s["opened"]:   # RT1-08, RT1-07: opened once, under one spelling; the tier changes only through raise, triggers through trigger
        raise Refuse(LOWER, f"card {s['card']} is already open at tier {s['tier']}: open is not run again (raise or trigger change it)")
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
    r = subprocess.run(["git", "-c", f"core.hooksPath={os.devnull}", "-c", "core.fsmonitor=false", *args], cwd=cwd, env=env,
                       capture_output=True, timeout=d.qa["tests"]["timeout_s"])
    # bytes decoded here, not text=True: universal newlines would turn a CR inside a line into a line break (Q1-OF-CVER-01)
    r.stdout, r.stderr = r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")
    return r


def make_copy(repo, h, card, n, d):
    """(copy folder, tree id): H cloned standalone under qa_copies/<card>/round-<n>, checked out on a branch of its own. Before anything
    is cloned, the builder repo's history the clone takes (rev-list --all --disk-usage) plus H's tree (ls-tree -r -l: every blob) is
    checked against the project's limit (RTF-08, Q1-OF-CVER-03)."""
    sizes = [git(["ls-tree", "-r", "-l", "-z", h], repo, d), git(["rev-list", "--objects", "--all", "--disk-usage"], repo, d)]
    bad = next((r for r in sizes if r.returncode), None)
    if bad:
        raise Refuse(NO_COPY, f"the size of the repository at that hash cannot be read (exit {bad.returncode}): {bad.stderr.strip()[-160:]}")
    try:   # <mode> <type> <object> <size>\t<path>; a submodule's size is "-"
        size = sum(int(e.split(None, 4)[3]) for e in sizes[0].stdout.split("\0") if e and e.split(None, 4)[1] == "blob") + int(sizes[1].stdout.strip())
    except (ValueError, IndexError):
        raise Refuse(NO_COPY, "the size of the repository at that hash cannot be read") from None
    cap = d.qa["tests"]["max_copy_bytes"]   # d holds the card's settings (its project's and its own overrides)
    if size > cap:
        # shortcut: --disk-usage is the history as stored in the builder repo; the clone repacks it, close to it, not equal
        raise Refuse(NO_COPY, f"the frozen tree and the history the copy would clone hold {size} bytes, over the limit of {cap} "
                              f"(qa-loop tests.max_copy_bytes: the owner may set a project's or a card's own in overrides); nothing was cloned")
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


def diff(dest, a, b, d, *opts, paths=()):
    """Every diff the engine reads (RTF-02): text whatever the copy's .gitattributes say (--text beats -diff and binary), no
    external diff, no textconv, no attributes file of the user's; --no-renames (RT1-06): a renamed file lists its old path too."""
    return git(["-c", f"core.attributesFile={os.devnull}", "diff", "--text", "--no-ext-diff", "--no-textconv", "--no-renames", "--no-color",
                *opts, a, b, "--", *paths], dest, d)


def changed(dest, a, b, d):
    """The paths changed from a to b and the added lines, or None when the diff cannot be computed."""
    names, patch = diff(dest, a, b, d, "--name-only", "-z"), diff(dest, a, b, d, "-U0")
    if names.returncode or patch.returncode:
        return None
    added, hunk = [], False
    for l in patch.stdout.split("\n"):   # Q1-CVER-04: a file's header lines come before its first @@, so "+++ " inside a hunk is an added line; only \n ends a line (Q1-OF-CVER-01)
        if l.startswith("diff --git "):
            hunk = False
        elif l.startswith("@@"):
            hunk = True
        elif hunk and l.startswith("+"):
            added.append(l[1:])
    return [p for p in names.stdout.split("\0") if p], added


def glob(p, g):
    """fnmatch (a * crosses folders), whatever the letter case (RT1-06); a leading **/ also matches at the top folder."""
    p, g = p.lower(), g.lower()
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


# ---- close: pass, fail, climb, cap (A2) ----
def climb(card, s, d):
    """{from_rung, to_rung, from_link, to_link} of the rung bin/resolve.py serves the card's builder role from
    rounds.climb_rung on (its CLI: it logs the walk), None when the chain has no higher rung; Refuse on any other answer."""
    import resolve
    role, to = s["builder_role"] or d.rt["builder_roles"][0], d.qa["rounds"]["climb_rung"]
    # shortcut: the resolver call shares the test runner's limit (tests.timeout_s), as git does here
    r = subprocess.run([sys.executable, "-I", os.path.join(BIN, "resolve.py"), "resolve", "--role", role, "--project", str(s["project"]),
                        "--card", card, "--rung", str(to), "--json"], capture_output=True, text=True, errors="replace",
                       stdin=subprocess.DEVNULL, timeout=d.qa["tests"]["timeout_s"])
    try:
        out = json.loads(r.stdout)
    except ValueError:
        out = None
    out = out if isinstance(out, dict) else {}
    rung, code = out.get("rung") if isinstance(out.get("rung"), dict) else {}, out.get("code")
    if type(rung.get("served")) is int and rung["served"] > s["rung"] and isinstance(rung.get("link"), dict) and code in (None, resolve.COOLDOWN):
        try:
            frm = resolve.link_key(resolve.role_view(role, s["project"], card)["escalation_chain"][s["rung"] - 1])
        except Exception:
            frm = None   # the record of where the card climbed from, not a decision: the climb stands without it
        return {"from_rung": s["rung"], "to_rung": rung["served"], "from_link": frm, "to_link": resolve.link_key(rung["link"])}
    if r.returncode == 1 and code == resolve.EXHAUSTED and rung.get("served") is None:
        return None
    raise Refuse(NO_CLIMB, f"resolve --rung {to} for role {role} answered {code or 'no code'} (exit {r.returncode}), served "
                           f"{rung.get('served')}: no climb decision; the round stays open")


def project_rung(card, role, rung, d):
    """rungs.json (index qa_rungs) {card: {role: rung}} for bin/escalate.sh: under its lock, written whole and renamed over it.
    A file that is not a JSON object is not overwritten (it holds other cards' rungs)."""
    try:
        p = el.path(d.idx["qa_rungs"])
        with el.locked(p + ".lock"):
            try:
                with os.fdopen(el.open_file(p, os.O_RDONLY), "rb") as f:
                    v = json.loads(f.read())
            except FileNotFoundError:
                v = {}
            if not isinstance(v, dict):
                raise ValueError("it is not a JSON object")
            card = card.lower()   # RTF-09: the board's id form (t_ and lowercase hex), the key bin/escalate.sh reads
            v[card] = {**(v[card] if isinstance(v.get(card), dict) else {}), role: rung}
            tmp = f"{p}.{os.getpid()}.new"
            fd = el.open_file(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    json.dump(v, f, indent=1)
                    f.write("\n")
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(tmp, p)
            finally:
                if os.path.lexists(tmp):
                    os.unlink(tmp)
    except (OSError, ValueError) as e:
        # shortcut: the projection is written once, after the trusted line; rewrite it from the fold if a lost write ever matters
        raise Refuse(RUNGS, f"{d.idx['qa_rungs']} was not written ({el.why(e) if isinstance(e, OSError) else e}); the trusted "
                            f"qa.climbed line stands: set {card}.{role} to {rung} there by hand"[:300]) from None


def alert_owner(card, n, fix):
    """The escalation alert through bin/alert.sh; finding texts come from QA roles, so only plain characters reach the chat."""
    items = "; ".join(f"{x.get('severity')} {x.get('file')}:{(x.get('lines') or ['?'])[0]} {x.get('check')} ({x['fingerprint'][:12]})" for x in fix)
    text = re.sub(r"[^A-Za-z0-9_./:;(), -]", "?", f"card {card}, round {n}: " + (items or "no blocking finding, a role's verdict failed"))
    # a send that fails never undoes the escalation: alert.sh logs its line first (as route.py does)
    subprocess.run(["bash", os.path.join(BIN, "alert.sh"), ESCALATED, f"problem={el.scrub(text)}"], stdin=subprocess.DEVNULL, capture_output=True, timeout=60)


def cmd_close(o, d):
    s = opened(o, d)
    n, f, q = s["round"], s["frozen"], d.qa
    if s["escalated"] or not n or n in s["closed"]:
        raise Refuse(NOT_CLOSED, f"card {o.card} has no open round (round {n}, escalated {s['escalated']})")
    import qa_findings as qf
    cur = [dict(x, fingerprint=k) for k, x in s["findings"].items() if x.get("round") == n]
    pend = [x["fingerprint"][:12] for x in cur if x.get("status") == NOT_FIX[1]]
    if pend:
        raise Refuse(PENDING, f"round {n} has {len(pend)} finding(s) pending their repro ({', '.join(pend[:CAP])})")
    cur = [x for x in cur if qf.stands(o.card, x, s, d)]   # re-hashed: a changed file voids its copy
    fix = qf.merge(cur, s["depth"], q, qf.exempt(o.card))
    blocking = [x["fingerprint"] for x in fix if x["blocking"]][:CAP]
    pl = plan(o.card, s, d)["roles"]
    roles = [r for r, e in pl.items() if e["slots"]]
    v = s["verdicts"].get(n, {})
    failed = [r for r in roles if any(x["result"] != RESULTS[0] for x in v.get(r, {}).values())]   # RTF-01: any slot's fail
    if not blocking and not failed:
        good = lambda x: x and x["result"] == RESULTS[0] and x["hash"] == f["hash"] and qf.holds(o.card, x["evidence"], s, d)
        missing = [f"{r} slot {i}" for r, e in pl.items() for i in range(1, len(e["slots"]) + 1) if not good(v.get(r, {}).get(i))]
        if missing:
            raise Refuse(NOT_CLOSED, f"round {n} is not finished: no trusted pass on the frozen hash with evidence that holds from {', '.join(missing[:CAP])}")
        put(o.card, "qa.passed", {"round": n, "hash": f["hash"]}, f"QA round {n} passed")
        return 0
    reason = f"round {n} failed: " + (f"{len(blocking)} blocking finding(s)" if blocking else f"verdict not pass from {', '.join(failed)}")
    lines, cap, c = [], s["cap"], None
    if n == q["rounds"]["normal"]:   # decided before any line is written: a refused answer changes nothing
        c = climb(o.card, s, d)
        cap = q["rounds"]["cap_climb"] if c else q["rounds"]["cap_no_climb"]
        lines.append(("qa.climbed", {**c, "open": blocking, "reason": reason, "round": n}, f"QA climbs to rung {c['to_rung']}") if c else
                     ("qa.no-climb", {"rung": s["rung"], "open": blocking, "reason": reason, "round": n}, "QA: no higher rung to climb to"))
    b = q["depth_bump"]
    if n < cap and s["depth"] == b["from"] and n >= b["after_failed_round"]:
        lines.append(("qa.depth-raised", {"depth": b["to"], "from": s["depth"], "round": n}, f"QA depth raised to {b['to']}"))
    lines.append(("qa.escalated", {"round": n, "open": blocking}, f"QA round {n} failed at the cap of {cap}: escalated to the owner") if n >= cap else
                 ("qa.round-failed", {"round": n, "open": blocking}, reason))
    for t, new, text in lines:
        put(o.card, t, new, text)
    if n >= cap:
        alert_owner(o.card, n, [x for x in fix if x["blocking"]])
    if c:
        project_rung(o.card, s["builder_role"] or d.rt["builder_roles"][0], c["to_rung"], d)
    return 0


CMDS = {"open": cmd_open, "raise": cmd_raise, "trigger": cmd_trigger, "freeze": cmd_freeze, "plan": cmd_plan, "status": cmd_status, "done": cmd_done, "close": cmd_close}
WRITES = ("open", "raise", "trigger", "freeze", "close")   # the subcommands that write the card's state


def card_lock(card, d):
    """RTF-05: the one lock of a card (any spelling of its id), next to its copies under qa_copies; a plain id only (CARD)."""
    if not CARD.fullmatch(card):
        raise Refuse(BAD, "the card id is not a plain id (letters, digits, dot, dash, underscore; at most 64)")
    return el.locked(os.path.join(el.path(d.idx["qa_copies"]), card.lower() + ".lock"))


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
        p.add_argument("--json", action="store_true", help="the output is JSON in any case")
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
        d = data(o.card, o.project if o.cmd == "open" else None)
        with card_lock(o.card, d) if o.cmd in WRITES else contextlib.nullcontext():
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
