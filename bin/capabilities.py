#!/usr/bin/env python3
"""Capability registry: find, describe, request and load capabilities by role (F3 item C; body B4, AC4). Stdlib only.
Sources (index key capability_sources -> .stella/capability-sources.json): the registry, skill folders (SKILL.md frontmatter), MCP
manifests and extension folders. A skill or server found in a source with no registry entry is HIDDEN from every role and raises one
alert per search (fail closed). Visibility for a role: allowed_roles -> available, requestable_roles -> requestable (+ approval class),
else hidden; a hidden id answers exactly like an unknown id (no existence leak). A risk class named in gated_risk_classes is never
"available" unless bin/host_access.py decide allows the caller's own run and host request (--run, --host-request: {target, action,
confirmation}; nothing is invented); else it shows as gated and load refuses it. A role's own platform toolsets (role table) are entries of that
role alone. An entry not yet approved (an outside skill or server) is requestable only: the request is one approval request (an install
escalation; no extensions-manager triage exists yet), nothing is installed here.
CLI (host side; --role names a role of the role table):
  search WORDS... --role R [--limit N] [--json]    ranked by id / keywords / summary weights from the sources file
  describe ID --role R [--json]
  request ID --reason TEXT --card C --role R [--json]   one approval through bin/approvals.py (class from the entry)
  load ID --role R --run RUN [--card C] [--json]    the definition; one trusted capability-load line (engine side only)
  check-card --role R --card FILE [--json]          every skill / tool of a card JSON must be available to R
  prompt-line [--json]                              the capability line every role prompt carries
  check [--json]                                    completeness lint (item R): every command file, skill, MCP server and extension of the sources
                                                    has a registry entry; STL-CFG-340 names the ones without
In a worker environment (DC-05) search / describe / request / load go to the capability server (bin/capabilities_mcp.py) with the
run token of the environment, without --role, --card or --run (role, card and run come from the token); nothing local is read or
written. Those flags, check-card and prompt-line are refused there (STL-GRD-662); a server that cannot be reached: STL-GRD-681.
Exit: 0 ok; 1 refused (catalog code STL-GRD-660..667 on stderr); 2 usage."""
import argparse, fnmatch, json, os, re, sys
sys.dont_write_bytecode = True
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import stella_data as sd
import worker_env

SKILL_FILE = "SKILL.md"   # the skill convention's file name, not a project name
ID = re.compile(r"[a-z0-9][a-z0-9._:-]{0,127}")
RUN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}")


class Refuse(Exception):
    def __init__(self, code, problem, alert=False):   # code: a STL-GRD number, or a whole code such as STL-CFG-340
        super().__init__(problem)
        self.code, self.problem, self.alert = code, problem, alert

    def full(self):
        return self.code if isinstance(self.code, str) else f"STL-GRD-{self.code}"


def sources():
    return sd.checked(sd.load(sd.load(sd.INDEX)["capability_sources"]), "capability sources", "capability-sources")


def registry():
    row = next(r for r in sd.rows() if r["id"] == "capabilities")
    return sd.checked(sd.load(row["path"]), row["path"], "capabilities")["entries"]


def role_ok(role):
    return role in sd.load(sd.load(sd.INDEX)["role_table"])["roles"]


def host_allows(e, role, a):
    """Item H's decision for a gated entry: the caller's own run and host request (target, action, confirmation) go to host_access.decide
    unchanged; no run or request, or any refusal or failure, is no (fail closed). No fact is made up here."""
    req, run = getattr(a, "host_request", None), getattr(a, "run", None)
    if not (isinstance(req, dict) and run):
        return False
    try:
        import host_access
        host_access.decide({"capability": e["id"], "role": role, "run": run} | req)
        return True
    except Exception:
        return False


def visibility(e, role, src, a=None):
    """available | requestable | gated | None (hidden or unknown: the same answer). An entry not yet approved (an outside skill or
    server) is only ever requestable: a request to install it, never a use."""
    requestable = role in e.get("requestable_roles", []) and e.get("request_approval")
    if e["status"] == "proposed":
        return "requestable" if requestable else None
    if e["status"] != "approved":
        return None
    if role in e["allowed_roles"]:
        return ("available" if host_allows(e, role, a) else "gated") if e["risk_class"] in src["gated_risk_classes"] else "available"
    return "requestable" if requestable else None


def with_toolsets(entries, role, src):
    """The registry plus the role's own platform toolsets (role table), as entries of that role alone: never in another role's answer,
    and a registry entry of the same id wins."""
    rt = sd.load(sd.load(sd.INDEX)["role_table"])["roles"].get(role, {})
    have, t = {e["id"] for e in entries}, src["toolset_entry"]
    names = sorted({n for names in rt.get("platform_toolsets", {}).values() for n in names if isinstance(n, str) and ID.fullmatch(n)} - have)
    return entries + [{"id": n, "kind": t["kind"], "summary": t["summary"].format(name=n), "keywords": [n], "inputs": "", "outputs": "",
                       "allowed_roles": [role], "risk_class": t["risk_class"], "hosts": [], "secrets": [], "status": "approved",
                       "source": "role toolset"} for n in names]


def shown(e, vis, score=None):
    o = {"id": e["id"], "kind": e["kind"], "summary": e["summary"], "risk_class": e["risk_class"], "visibility": vis}
    if vis == "requestable":
        o["request_approval"] = e["request_approval"]
        if e["status"] != "approved":
            o["install"] = True
    if score is not None:
        o["score"] = score
    return o


def frontmatter(text):
    """(name or None, body) of a SKILL.md; shortcut: only a top-level name: line is read, no YAML parser."""
    m = re.match(r"---\n(.*?)\n---\n?(.*)", text, re.S)
    if not m:
        return None, text
    n = re.search(r"^name:\s*(\S+)\s*$", m.group(1), re.M)
    return (n.group(1) if n else None), m.group(2)


def skills(src):
    """{skill name: SKILL.md path} of the skill folders (a folder that resolves outside the root is skipped)."""
    out = {}
    for d in src["skill_folders"]:
        base = os.path.realpath(os.path.join(sd.ROOT, d))
        if not (base + os.sep).startswith(sd.ROOT + os.sep) or not os.path.isdir(base):
            continue
        for n in sorted(os.listdir(base)):
            f = os.path.join(base, n, SKILL_FILE)
            if os.path.isfile(f) and os.path.realpath(f).startswith(base + os.sep):
                name = frontmatter(open(f, encoding="utf-8", errors="replace").read())[0]
                out[name if name and ID.fullmatch(name) else n] = f
    return out


def found_ids(src):
    """Every skill, MCP server and extension id the sources hold, registered or not."""
    ids = set(skills(src))
    for m in src["mcp_manifests"]:
        p = os.path.join(sd.ROOT, m)
        if os.path.isfile(p):
            try:
                ids |= set(json.load(open(p, encoding="utf-8")).get("mcpServers", {}))
            except (OSError, ValueError, AttributeError):
                raise Refuse(667, f"{m} is not readable JSON", True) from None
    for d in src["extension_folders"]:
        p = os.path.join(sd.ROOT, d)
        for n in sorted(os.listdir(p)) if os.path.isdir(p) else ():
            if n.endswith(".json"):
                try:
                    ids.add(json.load(open(os.path.join(p, n), encoding="utf-8"))["id"])
                except (OSError, ValueError, KeyError, TypeError):
                    raise Refuse(667, f"{d}/{n} is not a readable manifest", True) from None
    return ids


def find(entries, cid, role, src, a=None):
    for e in with_toolsets(entries, role, src):
        if e["id"] == cid and (v := visibility(e, role, src, a)):
            return e, v
    raise Refuse(660, "unknown capability")   # hidden and unknown: one message, the id is not echoed


def cmd_search(a, src, entries):
    toks = [t for t in re.split(r"[^a-z0-9]+", " ".join(a.words).casefold()) if t]
    w, hits = src["ranking"], []
    for e in with_toolsets(entries, a.role, src):
        if not (v := visibility(e, a.role, src, a)):
            continue
        s = sum(w["id"] * (t in e["id"]) + w["keywords"] * any(t in k.casefold() for k in e["keywords"])
                + w["summary"] * (t in e["summary"].casefold()) for t in toks)
        if s:
            hits.append((-s, e["id"], shown(e, v, s)))
    hits.sort(key=lambda h: h[:2])   # deterministic: score, then id
    out = [h[2] for h in hits[:a.limit or src["default_limit"]]]
    for n in sorted(found_ids(src) - {e["id"] for e in entries}):   # one alert per unregistered skill / server
        sd.say("STL-GRD-661", f"{n} has no registry entry", alert=True)
    return out


def cmd_describe(a, src, entries):
    e, v = find(entries, a.id, a.role, src, a)
    return shown(e, v) | {k: e[k] for k in ("keywords", "inputs", "outputs", "hosts")}


def cmd_request(a, src, entries):
    e, v = find(entries, a.id, a.role, src, a)
    if v != "requestable":
        return {"id": e["id"], "visibility": v, "note": "no approval needed"}
    import approvals as ap
    # An install (status not approved) is an escalation to the owner: one approval request, nothing is installed or enabled here.
    # shortcut: no extensions-manager triage exists yet (roadmap 4e; .stella/extensions holds manifests only), so every install is escalated; route it there when it ships.
    what = "install" if e["status"] != "approved" else "request"
    try:
        rec = ap.request(e["request_approval"], {"op": f"capability-{what}", "target": e["id"], "old_digest": "0" * 64,   # nothing before: a new grant
                          "new": {"role": a.role, "reason": a.reason[:500]}},
                         f"capability {what} {e['id']} for role {a.role}: {a.reason[:200]}", a.card, src["request_ttl_s"], requester=a.role)
    except (ap.Refusal, sd.DataError, ValueError) as ex:
        raise Refuse(664, str(ex)[:180]) from None
    except Exception as ex:   # EventError (a worker environment, a log that cannot be written)
        raise Refuse(664, getattr(ex, "problem", type(ex).__name__)[:180]) from None
    return {"id": e["id"], "request_id": rec["id"], "approval_class": rec["approval_class"], "status": rec["status"]}


def cmd_load(a, src, entries):
    e, v = find(entries, a.id, a.role, src, a)
    if v != "available":
        raise Refuse(665, "the capability is not available to this role" if v == "requestable" else "the capability needs the host check first")
    if not RUN.fullmatch(a.run) or (a.card and not RUN.fullmatch(a.card)):
        raise Refuse(665, "the run or card id is not well formed")
    f = skills(src).get(e["id"]) if e["kind"] == "skill" else None
    d = e.get("definition", {})
    body = frontmatter(open(f, encoding="utf-8", errors="replace").read())[1] if f else d.get("text") or d.get("schema")
    if body is None:
        raise Refuse(665, "the capability holds no definition")
    import event_log as el
    new = {"run": a.run, "role": a.role, "capability": e["id"], "source": e["source"]} | ({"card": a.card} if a.card else {})
    try:
        el.append(el.build("capability-load", e["id"], new=new, who={"role": a.role}))
    except Exception as ex:   # EventError: a worker environment or an invalid line; no line, no load
        raise Refuse(665, getattr(ex, "problem", type(ex).__name__)[:180]) from None
    return {"id": e["id"], "definition": body}


def cmd_check_card(a, src, entries):
    try:
        card = json.load(open(a.card, encoding="utf-8"))
        ids = [i for k in ("skills", "tools") for i in card.get(k) or []]
        assert all(isinstance(i, str) for i in ids)
    except (OSError, ValueError, AttributeError, AssertionError, TypeError):
        raise Refuse(666, "the card file is not readable JSON with lists of ids") from None
    bad = [i for i in ids if not any(e["id"] == i and visibility(e, a.role, src) == "available" for e in with_toolsets(entries, a.role, src))]
    if bad:
        raise Refuse(666, "not available to the card's role: " + ", ".join(i[:64] for i in bad[:5]))
    return {"ok": True, "checked": ids}


def commands(src):
    """Repo-relative path of every command file of the command folders (selftests excluded by the sources' patterns)."""
    out = []
    for d in src["command_folders"]:
        base = os.path.join(sd.ROOT, d)
        for n in sorted(os.listdir(base)) if os.path.isdir(base) else ():
            if os.path.isfile(os.path.join(base, n)) and any(fnmatch.fnmatch(n, g) for g in src["command_globs"]) \
                    and not any(fnmatch.fnmatch(n, g) for g in src["command_exclude"]):
                out.append(f"{d}/{n}")
    return out


def cmd_check(a, src, entries):
    """The completeness lint (item R, body B5): every command file, skill, MCP server and extension of the sources has a registry entry."""
    cmds = commands(src)
    missing = [c for c in cmds if c not in {e["source"] for e in entries}] + sorted(found_ids(src) - {e["id"] for e in entries})
    if missing:
        raise Refuse("STL-CFG-340", f"{len(missing)} without a registry entry: " + ", ".join(m[:80] for m in missing[:10]) + (" ..." if len(missing) > 10 else ""))
    return {"ok": True, "commands": len(cmds), "entries": len(entries)}


def main(argv):
    p = argparse.ArgumentParser(prog="capabilities.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    need = {}   # flags required on the host; a worker names none of them (DC-05)
    def add(name, *args, **kw):
        s = sub.add_parser(name)
        need[name] = [flag for flag, req in args if req]
        for flag, _ in args:
            s.add_argument(flag, **kw.get(flag, {}))
        s.add_argument("--json", action="store_true")
        return s
    hr = {"--host-request": {"metavar": "FILE"}}   # gated entries: the run's host request JSON {target, action, confirmation} for host_access.decide
    add("search", ("--role", True), ("--limit", False), ("--run", False), ("--host-request", False), **{"--limit": {"type": int}} | hr).add_argument("words", nargs="+")
    add("describe", ("--role", True), ("--run", False), ("--host-request", False), **hr).add_argument("id")
    add("request", ("--role", True), ("--reason", True), ("--card", True)).add_argument("id")
    add("load", ("--role", True), ("--run", True), ("--card", False), ("--host-request", False), **hr).add_argument("id")
    add("check-card", ("--role", True), ("--card", True))
    add("check")
    add("prompt-line")
    a = p.parse_args(argv)
    try:
        if w := worker_env.reason():   # before reading anything: a worker asks the capability server (DC-05)
            if a.cmd in ("check-card", "prompt-line", "check") or any(getattr(a, f, None) is not None for f in ("role", "card", "run", "host_request")):
                raise Refuse(662, w + "; role, card and run come from the run token, through the capability server")
            import capabilities_mcp as mcp
            args = ({"query": " ".join(a.words)} if a.cmd == "search" else {}) | {
                k: v for k in ("limit", "id", "reason") if (v := getattr(a, k, None)) is not None}
            try:
                out = mcp.call(a.cmd, args)
            except mcp.ClientError as x:
                sd.say(x.code, x.problem)
                return 1
        else:
            if missing := [f for f in need[a.cmd] if getattr(a, f[2:]) is None]:
                p.error("the following arguments are required: " + ", ".join(missing))
            src = sources()
            if getattr(a, "host_request", None):
                try:
                    a.host_request = json.load(open(a.host_request, encoding="utf-8"))
                except (OSError, ValueError):
                    raise Refuse(667, "the host request file is not readable JSON") from None
            if a.cmd == "prompt-line":
                out = {"line": src["capability_prompt_line"]}
            elif a.cmd == "check":
                out = cmd_check(a, src, registry())
            elif not role_ok(a.role):
                raise Refuse(663, "the role is not in the role table")
            else:
                fn = {"check-card": cmd_check_card}.get(a.cmd) or globals()["cmd_" + a.cmd]
                out = fn(a, src, registry())
    except Refuse as r:
        sd.say(r.full(), r.problem, alert=r.alert)
        return 1
    except (sd.DataError, OSError, KeyError, ValueError) as e:
        sd.say("STL-GRD-667", f"{type(e).__name__}: {str(e)[:160]}")
        return 1
    if a.json:
        print(json.dumps(out, indent=1))
    elif isinstance(out, list):
        for o in out:
            print(f"{o['id']}\t{o['visibility']}\t{o['summary']}")
    else:
        print(out.get("line") or json.dumps(out, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
