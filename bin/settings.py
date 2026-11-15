#!/usr/bin/env python3
"""The owner's settings commands (F1 W4, spec E6/E7), stdlib only. Driven by the registry .stella/settings.json; no key, file or
role name is in this file. Not a tool of any role: roles.json lists it under owner_commands, so every role's hooks refuse to run it,
and it refuses itself in a worker's environment.
CLI: settings.py get <key> [--json]            the stored value (the default when none is stored); *** for a secret
     settings.py set <key> <value> [--dry-run] [--proof <file>]
                                                validate the value against the entry, build the candidate file in canonical form
                                                and apply it through bin/stella-apply.py (backup, one event line, rollback),
                                                which asks the owner proof (the --proof file, else this host's owner key; an
                                                identity-critical change also the typed phrase); --dry-run prints the diff and
                                                the action a proof must cover, and changes nothing
     settings.py check [--json]                 the registry is valid and every stored value satisfies its entry
     settings.py list --json                    the registry entries (never a stored value)
     settings.py explain --project P [--json]   what holds for project P and where each value comes from (default, global, project):
                                                settings (a secret shown ***), the active preset, Local only, the data policy, per role the
                                                class order and its source, the grants in force and the revoked ones; read only; an unknown
                                                project follows the default policy (said so); an unknown preset fails closed, STL-CFG-311
Refused: a secret entry (secrets live in the vault; the registry never stores or shows one), STL-CFG-315; a value the entry
rejects or the owner file format cannot hold, STL-CFG-315; a worker environment (bin/worker_env.py), STL-CFG-312; no owner proof,
the codes of bin/owner_auth.py (806 no owner key, 808 the typed phrase of an identity-critical change missing or wrong, ...); an
unknown key, STL-CFG-311 with one alert line.
Exit: 0 ok (a set of the value already stored is "no change"); 1 refused or failed; 2 usage. The value of a secret is never
printed, logged or put in a message. Only env-format stores are written (the stores of the registry today)."""
import datetime, fcntl, json, os, re, subprocess, sys, tempfile
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import owner_config as oc
import stella_data as sd
import worker_env

SECRET = "secret"


class Refuse(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def registry():
    return sd.checked(sd.load(".stella/settings.json"), ".stella/settings.json", "settings")["entries"]


def entry(key):
    return next((e for e in registry() if e["key"] == key), None) or sd.refuse("setting", key)


def role_table():
    return sd.load(sd.load(sd.INDEX)["role_table"])


def need_owner(what):
    why = worker_env.reason()
    if why:
        raise Refuse("STL-CFG-312", f"{what} is the owner's: {why}")


def store(e):
    """(index row, store key) of an entry; only env-format files are read and written here."""
    row = sd.row_of(e["store"]["data"])
    if row["format"] != "env":
        raise Refuse("STL-CFG-313", f"{e['key']}: its store is not an env-format file")
    return row, e["store"]["key"]


def is_owner_file(row):
    return row["owner_only"] or row["path"] in role_table()["owner_settings"]


def read_store(row, code="STL-CFG-313"):
    """(file bytes or None, {key: value}) of an env-format store. code: the catalog code of a store that cannot be read (a change that failed, or for a read, a data file that is invalid)."""
    try:
        with open(el.path(row["path"]), "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        return None, {}
    except (OSError, ValueError) as e:
        raise Refuse(code, f"{row['id']} cannot be read: {type(e).__name__}")
    try:
        text = raw.decode("utf-8-sig")
        cfg = oc.parse_env(text, row["id"])
    except (oc.OwnerConfigError, UnicodeDecodeError) as e:
        raise Refuse(code, f"{row['id']} is not a valid env file: {str(e)[:120]}")
    keys = [m[1] for l in text.split("\n") if (m := oc.LINE.fullmatch(l))]
    dup = sorted({k for k in keys if keys.count(k) > 1})   # G5: the apply tool refuses a key held twice, so no verdict ("no change") is given on such a file
    if dup:
        raise Refuse(code, f"{row['id']} holds a key twice ({', '.join(dup)[:80]}): fix the file first; the apply tool refuses it too")
    return raw, cfg


def typed(e, text):
    """text as the entry's type, or Refuse: an integer or boolean written in its plain form only."""
    t = e["type"]
    if t == "integer":
        if not re.fullmatch(r"-?[0-9]{1,18}", text):
            raise Refuse("STL-CFG-315", f"{e['key']}: not a whole number")
        return int(text)
    if t == "boolean":
        if text not in ("true", "false"):
            raise Refuse("STL-CFG-315", f"{e['key']}: not true or false")
        return text == "true"
    return text


def problems(e, value):
    """The entry's own rules against a typed value, as the registry check judges a default (no value is quoted)."""
    v = e["validation"]
    sch = {"type": "string" if e["type"] == "enum" else e["type"], **{a: v[a] for a in ("pattern", "minimum", "maximum") if a in v}}
    if "values" in v:
        sch["enum"] = v["values"]
    return sd.validate_doc(value, sch)


def current(e):
    """(value or None, where it came from) of an entry; the default when nothing is stored."""
    row, k = store(e)
    _, cfg = read_store(row)   # T2: a store that does not parse is refused with the one code set uses too (G5: "refused the same way")
    if k in cfg:
        return typed_stored(e, cfg[k]), "store"
    if e["default"] is not None and problems(e, e["default"]):   # the registry's own default is refused by its own rules: no value is served
        raise Refuse("STL-CFG-310", f"{e['key']}: the default in the registry is rejected by the entry's own rules")
    return e["default"], "default"


def typed_stored(e, text):
    try:
        return typed(e, text)
    except Refuse:
        return text   # `check` reports it; `get` shows what is stored


def shown(e, value):
    return "***" if e["sensitivity"] == SECRET else value


def do_get(key, as_json):
    e = entry(key)
    row, _ = store(e)
    if e["sensitivity"] != SECRET and is_owner_file(row):
        need_owner(f"{key} (stored in {row['path']})")
    value, src = ("***", "store") if e["sensitivity"] == SECRET else current(e)
    print(json.dumps({"key": key, "value": value, "source": src, "sensitivity": e["sensitivity"]}, ensure_ascii=False) if as_json
          else ("" if value is None else str(value).lower() if isinstance(value, bool) else value))
    return 0


def do_set(key, text, dry, proof):
    need_owner("a settings change")
    # K9: the read of the store, the candidate and the apply are one critical section (a lock of this tool's own): two sets at once are two
    # changes in turn, never one lost and never one reported as failed because the other was running. Blocks until the other is done.
    lock = el.path(os.path.dirname(sd.load(sd.INDEX)["applied_state"]) + "/settings.lock")
    os.makedirs(os.path.dirname(lock), exist_ok=True)
    with open(lock, "a") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        return set_locked(key, text, dry, proof)


def set_locked(key, text, dry, proof):
    e = entry(key)
    if e["sensitivity"] == SECRET:
        raise Refuse("STL-CFG-315", f"{key} is a secret: secrets live in the vault, never in the registry or here")
    value = typed(e, text)
    bad = problems(e, value)
    if bad:
        raise Refuse("STL-CFG-315", f"{key}: {bad[0]}"[:200])
    row, k = store(e)
    stored = str(value).lower() if isinstance(value, bool) else str(value)
    try:
        newline = oc.line(k, stored)
    except oc.OwnerConfigError as err:
        raise Refuse("STL-CFG-315", str(err)[:200])
    raw, cfg = read_store(row)
    if k in cfg and cfg[k] == stored:
        print(f"no change: {key}")
        return 0
    lines = (raw.decode("utf-8-sig") if raw is not None else "").split("\n")
    hit = [i for i, l in enumerate(lines) if l.startswith(k + "=")]   # read_store refused a file that holds a key twice: at most one such line
    if hit:
        lines[hit[0]] = newline
    else:
        if lines[-1] == "":
            lines.pop()
        lines += [newline, ""]
    cand = "\n".join(lines).encode("utf-8")
    with tempfile.TemporaryDirectory(prefix="settings-") as d:   # 0700 folder: the candidate holds the owner's values
        src = os.path.join(d, "candidate")
        with open(src, "wb") as f:
            f.write(cand)
        r = subprocess.run([sys.executable, "-I", os.path.join(BIN, "stella-apply.py"), "apply", row["id"], "--from", src] + (["--dry-run"] if dry else ["--proof", proof] if proof else []))
    return r.returncode


def do_check(as_json):
    out = [{"code": "STL-CFG-310", "key": None, "problem": m} for d, m in sd.check("settings") if d == "settings"]
    why = None if out else worker_env.reason()
    if not out:
        for e in registry():
            row, k = store(e)
            if e["sensitivity"] == SECRET or (is_owner_file(row) and why):
                continue   # a secret is never read; an owner file is not read for a worker
            _, cfg = read_store(row, "STL-CFG-310")
            if k in cfg:
                try:
                    bad = problems(e, typed(e, cfg[k]))
                except Refuse as r:
                    bad = [r.problem]
                if bad:
                    out.append({"code": e["code"], "key": e["key"], "problem": f"{e['key']}: the stored value is rejected ({str(bad[0])[:100]})"})
    if as_json:
        print(json.dumps({"ok": not out, "problems": out, "values_read": why is None}, indent=2, ensure_ascii=False))
    else:
        print("\n".join(f"{p['code']} {p['problem']}" for p in out) or "settings OK")
    return 1 if out else 0


def do_list():
    keep = ("key", "label", "type", "validation", "scope", "sensitivity", "default", "store", "apply", "code")
    print(json.dumps([{k: e[k] for k in keep} for e in registry()], indent=2, ensure_ascii=False))
    return 0


def doc(schema):
    """The one document of a schema, found by the index (no path is named here), validated by its schema."""
    row = next((r for r in sd.rows() if r["schema"] == schema), None) or sd.refuse("data file of schema", schema)
    return sd.checked(sd.load(row["path"]), row["path"], schema)


def choose(order, sources):
    """(value, source) of the first (value, source) pair whose value is set."""
    return next(((v, s) for v, s in zip(order, sources) if v is not None), (None, None))


def explain(project):
    """What holds for `project`, and where each value comes from. Read-only; every id and name is read from the data."""
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    ra, pol, gr, rt = doc("role-assignments"), doc("data-policy"), doc("grants"), sd.routing()
    row = sd.entry(pol["projects"], project)
    names = {project} | ({row.get("global_id")} | {k for k, v in pol["projects"].items() if v is row} if row else set())   # a project is its alias or its global_id
    settings = []
    for e in registry():
        srow, _ = store(e)
        if e["sensitivity"] != SECRET and is_owner_file(srow):
            need_owner(f"{e['key']} (stored in {srow['path']})")
        value, src = ("***", "global") if e["sensitivity"] == SECRET else current(e)
        settings.append({"key": e["key"], "value": value, "source": "default" if src == "default" else "global", "sensitivity": e["sensitivity"]})
    sel = ra.get("selection", {})   # selection, selection.projects and crossing_grants are optional in their schemas
    pid, psrc = next(((sel["projects"][n], "project") for n in sorted(names) if n in sel.get("projects", {})), (sel.get("global"), "global"))
    preset = ra["effort_modes"].get(pid) or sd.refuse("preset", pid or "(none selected)")
    mode = pol["default"]["mode"] == "local_only" or bool(row) and row["mode"] == "local_only"   # DC-04: the default policy binds every project
    eff = pol["default"] if pol["default"]["mode"] == "local_only" or not row else row
    esrc = "default" if eff is pol["default"] else "project"
    exempt = {x["role"]: x for x in rt["exempt_roles"]}
    mine = [a for a in ra["assignments"] if a.get("class_order") is not None and a["scope"]["level"] in ("project", "global")
            and (a["scope"]["level"] == "global" or a["scope"].get("project") in names)]
    roles = {}
    for r in sorted(set(role_table()["roles"]) - {role_table()["fallback_role"]}):
        x = preset.get("roles", {}).get(r, {})
        ov = next((a for lvl in ("project", "global") for a in mine if a["role"] == r and a["scope"]["level"] == lvl), None)
        if r in exempt:
            order, osrc = exempt[r]["class_order"], "exempt role (routing data)"
        else:
            order, osrc = choose([ov and ov["class_order"], x.get("class_order"), preset.get("class_order")],
                                 ["assignment override", "preset role entry", "preset default"])
        roles[r] = {"active": x.get("active", True), "class_order": order, "class_order_source": osrc, "pins": x.get("pins", []),
                    "fallbacks": x.get("fallbacks", []), "last_resort": x.get("last_resort", preset.get("last_resort"))}
    grants = []
    for kind, lst in (("privacy", pol["privacy_grants"]), ("crossing", gr.get("crossing_grants", []))):
        for g in lst:
            sc = g.get("scope", {"level": "global"})
            if not (sc["level"] == "global" or sc.get("project") in names):
                continue   # another project's grant is not in force here, and not this project's business
            rv = g.get("revoked_at") is not None and not (sd.when(g, "revoked_at") and now < sd.when(g, "revoked_at"))   # a date that is no date counts as revoked
            live = not rv and any(sd.grant_in_force(g, n, now) for n in names)
            grants.append({"kind": kind, "id": g["id"], "scope": sc, "expires_at": g.get("expires_at"), "revoked_at": g.get("revoked_at"), "revoked": rv, "in_force": live,
                           "status": "revoked" if rv else "in force" if live else "not in force",
                           **{k: g[k] for k in ("data_class", "connection", "preset", "to_class") if k in g}})
    return {"project": project, "project_known": row is not None,
            **({} if row else {"note": "unknown project: the default data policy applies"}),
            "settings": settings, "preset": {"id": pid, "source": psrc},
            "local_only": {"value": mode, "source": esrc},
            "data_policy": {"mode": eff["mode"], "source": esrc}, "roles": roles, "grants": grants}


def do_explain(project, as_json):
    out = explain(project)
    if as_json:
        print(json.dumps(out, indent=2, ensure_ascii=False))
        return 0
    flat = lambda v: json.dumps(v, ensure_ascii=False)
    print(f"project {project}" + ("" if out["project_known"] else f" ({out['note']})"))
    print(f"preset {out['preset']['id']} ({out['preset']['source']})")
    print(f"local only {flat(out['local_only']['value'])} ({out['local_only']['source']}); data policy {out['data_policy']['mode']} ({out['data_policy']['source']})")
    for s in out["settings"]:
        print(f"setting {s['key']} = {flat(s['value'])} ({s['source']})")
    for r, v in out["roles"].items():
        print(f"role {r}: {'active' if v['active'] else 'off'}; order {flat(v['class_order'])} ({v['class_order_source']}); pins {flat(v['pins'])}; fallbacks {flat(v['fallbacks'])}; last resort {flat(v['last_resort'])}")
    for g in out["grants"]:
        print(f"grant {g['id']} ({g['kind']}): {g['status']}; scope {flat(g['scope'])}; expires {g['expires_at'] or 'never'}")
    return 0


def main(argv):
    as_json, dry = "--json" in argv, "--dry-run" in argv
    a, proof, proj, it = [], [], [], iter(argv)
    for x in it:
        if x == "--proof":
            proof.append(next(it, ""))
        elif x == "--project":
            proj.append(next(it, ""))
        elif x not in ("--json", "--dry-run"):
            a.append(x)
    cmd, args = (a[0] if a else ""), a[1:]
    if proof and (cmd != "set" or len(proof) > 1 or not proof[0]) or proj and cmd != "explain":
        cmd = ""   # --proof once, with a file, and for set only; --project for explain only: else usage
    try:
        if cmd == "get" and len(args) == 1 and not dry:
            return do_get(args[0], as_json)
        if cmd == "set" and len(args) == 2 and not as_json:
            return do_set(args[0], args[1], dry, proof[0] if proof else None)
        if cmd == "explain" and not args and len(proj) == 1 and proj[0] and not dry:
            return do_explain(proj[0], as_json)
        if cmd == "check" and not args and not dry:
            return do_check(as_json)
        if cmd == "list" and not args and as_json and not dry:
            return do_list()
    except Refuse as r:
        return el.fail(r.code, r.problem)
    except el.EventError as r:
        return el.fail(r.code, r.problem)
    except sd.DataError as r:
        return el.fail("STL-CFG-313", str(r)[:300])
    print(__doc__.split("\n", 1)[1].split("Refused:")[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
