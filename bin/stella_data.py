#!/usr/bin/env python3
"""Contract data (core contract items 1, 5, 6, 7), stdlib only: the index .stella/data-files.json, the schemas in
.stella/schemas/, and the cross-file rules. No provider, app, channel, role or feature name is in this file.
CLI: stella_data.py check [--json] [<id>]       validate every data file against its schema, then the cross-file rules
     stella_data.py validate <schema> <file>    one JSON file against .stella/schemas/<schema>.schema.json
     stella_data.py list [--json] [<id>]        the data files, or the entries of one
     stella_data.py get [--json] <id> [<entry>] a whole data file, or one entry
     stella_data.py search [--json] <words...>  entries holding all the words; approved first. Finding grants nothing.
Exit: 0 ok; 1 a problem (check: one line per problem, code STL-CFG-310) or an unknown id (STL-CFG-311, one alert line); 2 usage.
The stack root is the parent of this file's folder, or STELLA_ROOT (a scratch root in tests).
Schema subset: type, enum, const, properties, required, additionalProperties, items, minItems, maxItems, uniqueItems,
minLength, maxLength, pattern, minimum, maximum, $ref (#/$defs/x), $defs, $schema, title, description. Any other keyword
in a schema is an error, never ignored."""
import glob, json, os, re, sys

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import alert_catalog

ROOT = os.environ.get("STELLA_ROOT") or os.path.dirname(BIN)
INDEX = ".stella/data-files.json"
SCHEMAS = ".stella/schemas"
KEYWORDS = {"$schema", "$id", "$ref", "$defs", "title", "description", "type", "enum", "const", "properties", "required",
            "additionalProperties", "items", "minItems", "maxItems", "uniqueItems", "minLength", "maxLength", "pattern",
            "minimum", "maximum"}
TYPES = {"object": dict, "array": list, "string": str, "integer": int, "number": (int, float), "boolean": bool, "null": type(None)}


def load(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return json.load(f)


# ---- the JSON Schema subset validator ----
def lint_schema(s, path="$"):
    """Problems with the schema itself: a keyword outside the supported subset is an error."""
    if not isinstance(s, dict):
        return [f"schema {path}: not an object"]
    errs = [f"schema {path}: keyword {k!r} is not supported by the validator" for k in s if k not in KEYWORDS]
    for k in ("properties", "$defs"):
        for n, sub in (s.get(k) or {}).items():
            errs += lint_schema(sub, f"{path}.{n}")
    if isinstance(s.get("items"), dict):
        errs += lint_schema(s["items"], f"{path}[]")
    if isinstance(s.get("additionalProperties"), dict):
        errs += lint_schema(s["additionalProperties"], f"{path}.*")
    return errs


def type_ok(v, t):
    return isinstance(v, TYPES[t]) and not (t in ("integer", "number") and isinstance(v, bool))


def check_value(v, s, defs, p, errs):
    if "$ref" in s:
        s = defs[s["$ref"].rsplit("/", 1)[-1]]
    t = s.get("type")
    if t is not None:
        ts = [t] if isinstance(t, str) else t
        if not any(type_ok(v, x) for x in ts):
            return errs.append(f"{p}: expected {'/'.join(ts)}, got {json.dumps(v)[:60]}")
    if "const" in s and v != s["const"]:
        errs.append(f"{p}: must be {s['const']!r}")
    if "enum" in s and v not in s["enum"]:
        errs.append(f"{p}: {v!r} is not one of {s['enum']}")
    if isinstance(v, str):
        if len(v) < s.get("minLength", 0) or len(v) > s.get("maxLength", 1 << 30):
            errs.append(f"{p}: length {len(v)} is out of range")
        if "pattern" in s and not re.search(s["pattern"], v):
            errs.append(f"{p}: {v[:60]!r} does not match {s['pattern']}")
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        if v < s.get("minimum", v) or v > s.get("maximum", v):
            errs.append(f"{p}: {v} is out of range")
    if isinstance(v, list):
        if len(v) < s.get("minItems", 0) or len(v) > s.get("maxItems", 1 << 30):
            errs.append(f"{p}: {len(v)} items is out of range")
        if s.get("uniqueItems") and len({json.dumps(x, sort_keys=True) for x in v}) != len(v):
            errs.append(f"{p}: items are not unique")
        for i, x in enumerate(v):
            check_value(x, s.get("items", {}), defs, f"{p}[{i}]", errs)
    if isinstance(v, dict):
        errs += [f"{p}: missing {k}" for k in s.get("required", []) if k not in v]
        props, extra = s.get("properties", {}), s.get("additionalProperties", True)
        for k, x in v.items():
            if k in props:
                check_value(x, props[k], defs, f"{p}.{k}", errs)
            elif extra is False:
                errs.append(f"{p}: {k!r} is not allowed")
            elif isinstance(extra, dict):
                check_value(x, extra, defs, f"{p}.{k}", errs)


def validate_doc(doc, schema):
    errs = lint_schema(schema)
    if not errs:
        check_value(doc, schema, schema.get("$defs", {}), "$", errs)
    return errs


# ---- the index and the entries ----
def rows():
    return load(INDEX)["files"]


def is_folder(row):
    return os.path.isdir(os.path.join(ROOT, row["path"]))


def docs_of(row):
    """[(relative path, parsed doc)] for a JSON data file, or for every *.json of a folder."""
    if is_folder(row):
        return [(os.path.relpath(f, ROOT), json.load(open(f, encoding="utf-8")))
                for f in sorted(glob.glob(os.path.join(ROOT, row["path"], "*.json")))]
    return [(row["path"], load(row["path"]))]


def entries(row):
    """{entry id: entry} for one data file. Raises ValueError on a repeated id."""
    out, idf, lk = {}, row["id_field"], row["list_key"]
    for rel, d in docs_of(row):
        items = [d] if lk is None else d[lk]   # a folder row: each file is one entry
        for k, e in (items.items() if isinstance(items, dict) else [(x[idf], x) for x in items]):
            if k in out:
                raise ValueError(f"{rel}: duplicate entry id {k!r}")
            out[k] = e
    return out


# ---- check ----
def role_names():
    return set(load(load(INDEX)["role_table"])["roles"])


def policy_allows(pol, prov):
    return pol["mode"] == "open" or (pol["mode"] == "local_only" and prov["locality"] == "local") \
        or (pol["mode"] == "allowed_providers" and prov["id"] in pol["allowed_providers"])


def cross_rules(by_id, whole, P):
    """Cross-file rules. by_id: data id -> {entry id: entry}; whole: data id -> the parsed file. P(data id, problem) records one."""
    conn, roles = by_id.get("connections", {}), role_names()
    pol, ra = whole.get("data-policy"), whole.get("role-assignments")
    if pol:
        for proj, p in [("default", pol["default"])] + list(pol["projects"].items()):
            for prov in p["allowed_providers"]:
                if prov not in conn:
                    P("data-policy", f"{proj}: allowed provider {prov!r} is not in the connections catalog")
    if ra and pol:
        for a in ra["assignments"]:
            scope = a["scope"]
            if a["role"] not in roles:
                P("role-assignments", f"{a['id']}: role {a['role']!r} is not in the role table")
            mode = ra["effort_modes"].get(a["effort_mode"])
            if mode is None:
                P("role-assignments", f"{a['id']}: effort mode {a['effort_mode']!r} is not defined")
            policy = pol["projects"].get(scope.get("project"), pol["default"])
            for c in a["chain"]:
                prov = conn.get(c["provider"])
                if prov is None or prov["kind"] != "provider":
                    P("role-assignments", f"{a['id']}: {c['provider']!r} is not a provider in the connections catalog")
                    continue
                if c["model"] not in [m["id"] for m in prov["models"]]:
                    P("role-assignments", f"{a['id']}: model {c['model']!r} is not listed for {c['provider']}")
                if mode and prov["locality"] not in mode["allowed_localities"]:
                    P("role-assignments", f"{a['id']}: {c['provider']} is {prov['locality']}, which effort mode {a['effort_mode']} forbids")
                if not policy_allows(policy, prov):
                    P("role-assignments", f"{a['id']}: {c['provider']} is not allowed by the data policy for {scope.get('project') or 'the default'} (an override never widens the policy)")
    feats = by_id.get("features", {})
    for f in feats.values():
        for d in f["depends_on"]:
            if d not in feats:
                P("features", f"{f['id']} depends on {d!r}, which is not a feature")
    for start in feats:   # a cycle: walking depends_on from a feature gets back to it
        seen, todo = set(), [d for d in feats[start]["depends_on"] if d in feats]
        while todo:
            n = todo.pop()
            if n == start:
                P("features", f"{start} depends on itself through a cycle")
                break
            if n not in seen:
                seen.add(n)
                todo += [d for d in feats[n]["depends_on"] if d in feats]
    for did in ("capabilities", "extensions"):
        for e in by_id.get(did, {}).values():
            for r in e["allowed_roles"]:
                if r not in roles:
                    P(did, f"{e['id']}: allowed role {r!r} is not in the role table")
    for s in by_id.get("settings", {}).values():
        if s["store"]["data"] not in by_id["_ids"]:
            P("settings", f"{s['key']}: stored in {s['store']['data']!r}, which is not a data file in the index")


def check(only=None):
    """[(data id, problem)] over every data file in the index."""
    probs = []
    P = lambda d, m: probs.append((d, m))
    try:
        idx = load(INDEX)
        errs = validate_doc(idx, load(f"{SCHEMAS}/data-files.schema.json"))
        if errs:
            return [("data-files", e) for e in errs]
        rs = idx["files"]
    except Exception as e:
        return [("data-files", f"{INDEX}: {type(e).__name__}: {e}")]
    by_id, whole = {"_ids": [r["id"] for r in rs]}, {}
    if len(set(by_id["_ids"])) != len(rs):
        P("data-files", "an id is listed twice in the index")
    for r in rs:
        if r["format"] != "json":
            continue   # shortcut: env files are not read here (the owner's file never is), the apply tool parses them; upgrade with W3
        try:
            if not r["schema"]:
                raise ValueError("no schema named")
            sch = load(f"{SCHEMAS}/{r['schema']}.schema.json")
            ds = docs_of(r)
            for rel, d in ds:
                if not isinstance(d, dict) or "schema_version" not in d:
                    P(r["id"], f"{rel}: schema_version is missing")
                for e in validate_doc(d, sch):
                    P(r["id"], f"{rel}: {e}")
            by_id[r["id"]], whole[r["id"]] = entries(r), (ds[0][1] if ds else None)
        except Exception as e:
            P(r["id"], f"{r['path']}: {type(e).__name__}: {e}")
    try:
        cross_rules(by_id, whole, P)
    except Exception as e:
        P("data-files", f"cross-file rules could not run: {type(e).__name__}: {e}")
    return [p for p in probs if only in (None, p[0])]


# ---- reading ----
def refuse(kind, name):
    """Unknown fails closed: STL-CFG-311, the catalog's plain message, exactly one alert line."""
    body, tag, kv = alert_catalog.render("STL-CFG-311", {"problem": f"{kind} {name}"})
    alert_catalog.log(tag, kv)
    print(f"STL-CFG-311 {body.split(chr(10))[1]}", file=sys.stderr)
    sys.exit(1)


def row_of(did):
    return next((r for r in rows() if r["id"] == did), None) or refuse("data file", did)


def find_entries(row):
    try:
        return entries(row) if row["format"] == "json" and (row["list_key"] or is_folder(row)) else {}
    except (OSError, ValueError, KeyError):
        return {}   # a broken file lists nothing; `check` names the problem


def emit(obj, as_json, line=None):
    print(json.dumps(obj, indent=2, ensure_ascii=False) if as_json or line is None else "\n".join(line(x) for x in obj))


def main(argv):
    as_json = "--json" in argv
    a = [x for x in argv if x != "--json"]
    cmd, args = (a[0] if a else ""), a[1:]
    if cmd == "check" and len(args) <= 1:
        if args:
            row_of(args[0])
        probs = check(args[0] if args else None)
        lines = []
        for d, m in probs:
            body = alert_catalog.render("STL-CFG-310", {"problem": f"{d}: {m}"})[0]
            lines.append({"code": "STL-CFG-310", "data": d, "problem": m, "message": body.split("\n")[1]})
        if as_json:
            print(json.dumps({"ok": not probs, "problems": lines}, indent=2, ensure_ascii=False))
        else:
            print("\n".join(f"STL-CFG-310 {l['message']}" for l in lines) or "data OK")
        return 1 if probs else 0
    if cmd == "validate" and len(args) == 2:
        errs = validate_doc(json.load(open(args[1], encoding="utf-8")), load(f"{SCHEMAS}/{args[0]}.schema.json"))
        print("\n".join(errs) or "valid")
        return 1 if errs else 0
    if cmd == "list" and len(args) <= 1:
        if args:
            ents = find_entries(row_of(args[0]))
            emit([{"id": k, **{f: e[f] for f in ("kind", "subkind", "label", "status", "summary") if f in e}} for k, e in ents.items()],
                 as_json, lambda x: "\t".join(str(v) for v in x.values()))
        else:
            emit([{"id": r["id"], "path": r["path"], "schema": r["schema"], "owner_only": r["owner_only"],
                   "entries": len(find_entries(r))} for r in rows()], as_json, lambda x: "\t".join(str(v) for v in x.values()))
        return 0
    if cmd == "get" and 1 <= len(args) <= 2:
        row = row_of(args[0])
        if row["format"] != "json":
            refuse("readable data file", args[0])   # env files (the owner's settings among them) are never read here
        if len(args) == 1:
            d = docs_of(row)
            emit(d[0][1] if not is_folder(row) else {x["id"]: x for _, x in d}, True)
            return 0
        ents = find_entries(row)
        if args[1] not in ents:
            refuse(f"entry of {args[0]}", args[1])
        emit(ents[args[1]], True)
        return 0
    if cmd == "search" and args:
        words, hits = [w.lower() for w in args], []
        for r in rows():
            for k, e in find_entries(r).items():
                if all(w in json.dumps(e).lower() for w in words):
                    hits.append({"data": r["id"], "id": k, "status": e.get("status", ""), "summary": e.get("summary") or e.get("label") or ""})
        hits.sort(key=lambda h: (h["status"] != "approved", h["data"], h["id"]))
        emit(hits, as_json, lambda h: f"{h['data']}\t{h['id']}\t{h['status']}\t{h['summary']}")
        return 0
    print(__doc__.split("\n", 1)[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
