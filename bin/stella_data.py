#!/usr/bin/env python3
"""Contract data (core contract items 1, 5, 6, 7), stdlib only: the index .stella/data-files.json, the schemas in
.stella/schemas/, and the cross-file rules. No provider, app, channel, role or feature name is in this file.
CLI: stella_data.py check [--json] [<id>]       validate every data file against its schema, then the cross-file rules.
                                                With an id: that file's problems plus every cross-file problem.
     stella_data.py validate <schema> <file>    one JSON file against .stella/schemas/<schema>.schema.json
     stella_data.py list [--json] [<id>]        the data files, or the entries of one
     stella_data.py get [--json] <id> [<entry>] a whole data file, or one entry (secret values are masked)
     stella_data.py search [--json] <words...>  entries whose values hold all the words; approved first. Finding grants nothing.
Exit: 0 ok; 1 a problem (one line per problem or unreadable file, code STL-CFG-310) or an unknown id (STL-CFG-311, one
alert line); 2 usage. No command ends in a traceback.
The stack root is the parent of this file's folder, or STELLA_ROOT (a scratch root in tests; the alert line then goes under it).
Data files must be strict JSON: a repeated key, NaN and Infinity are errors. A problem message never prints the rejected value.
Schema subset: type, enum, const, properties, propertyNames, required, additionalProperties, items, minItems, maxItems,
uniqueItems, minLength, maxLength, pattern ($ matches only at the very end), minimum, maximum, $ref (#/$defs/x; sibling
keywords still apply), $defs, $schema, $id, title, description. Any other keyword, or a wrong keyword value, is an error,
never ignored."""
import datetime, functools, glob, json, os, re, sys

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import alert_catalog

ROOT = os.path.realpath(os.environ.get("STELLA_ROOT") or os.path.dirname(BIN))   # resolved once: every path is compared to it
if os.environ.get("STELLA_ROOT") and not os.environ.get("ESCALATE_SUP_DIR"):
    os.environ["ESCALATE_SUP_DIR"] = os.path.join(ROOT, ".supervisor")   # a scratch root never writes the live alert log
INDEX = ".stella/data-files.json"
SCHEMAS = ".stella/schemas"
KEYWORDS = {"$schema", "$id", "$ref", "$defs", "title", "description", "type", "enum", "const", "properties", "propertyNames",
            "required", "additionalProperties", "items", "minItems", "maxItems", "uniqueItems", "minLength", "maxLength",
            "pattern", "minimum", "maximum"}
MAX_DEPTH = 64   # a data file nests far less; one limit makes `check` and the read commands agree on a deep object
TYPES = {"object": dict, "array": list, "string": str, "integer": int, "number": (int, float), "boolean": bool, "null": type(None)}


class DataError(Exception):
    """A data file or path this tool cannot use; the message names it and never holds a data value."""


# ---- strict JSON loading, paths inside the root ----
def _pairs(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise ValueError(f"repeated key {k!r}")
        d[k] = v
    return d


def _bad_const(c):
    raise ValueError(f"{c} is not JSON")


def _float(s):
    v = float(s)
    if v in (float("inf"), float("-inf")):
        raise ValueError("a number does not fit a float")
    return v


def _int(s):
    v = int(s)
    try:
        float(v)
    except OverflowError:
        raise ValueError("a number does not fit a float") from None
    return v


def _sound(doc):
    """No string (value or key) that is not valid Unicode text, no nesting past MAX_DEPTH; iterative, so no recursion limit."""
    todo = [(doc, 1)]
    while todo:
        x, d = todo.pop()
        if d > MAX_DEPTH:
            raise ValueError("nested too deeply")
        if isinstance(x, dict):
            todo += [(k, d + 1) for k in x] + [(v, d + 1) for v in x.values()]
        elif isinstance(x, list):
            todo += [(v, d + 1) for v in x]
        elif isinstance(x, str):
            try:
                x.encode("utf-8")
            except UnicodeEncodeError:
                raise ValueError("a string is not valid Unicode text") from None


def jload(path, label=None):
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f, object_pairs_hook=_pairs, parse_constant=_bad_const, parse_float=_float, parse_int=_int)
        _sound(doc)
        return doc
    except (ValueError, RecursionError) as e:
        raise DataError(f"{label or path}: {e if isinstance(e, ValueError) else 'nested too deeply'}")
    except OSError as e:
        raise DataError(f"{label or path}: cannot be read ({type(e).__name__})")


def safe(rel):
    """The absolute path of a path from the data: relative, no .. part, inside the root once symlinks are followed."""
    if not isinstance(rel, str) or not rel or rel.startswith("/") or ".." in rel.replace("\\", "/").split("/"):
        raise DataError(f"{rel}: a path in the data must be relative and have no .. part")
    root, p = os.path.realpath(ROOT), os.path.realpath(os.path.join(ROOT, rel))
    if p != root and not p.startswith(root.rstrip(os.sep) + os.sep):
        raise DataError(f"{rel}: leaves the stack root")
    return p


def load(rel):
    return jload(safe(rel), rel)


# ---- the JSON Schema subset validator ----
@functools.lru_cache(maxsize=None)
def rx(p):
    """A pattern as ECMA-262 reads it: $ means the very end (Python's $ also matches before a final newline)."""
    out, i, cls = [], 0, False
    while i < len(p):
        c = p[i]
        if c == "\\":
            out.append(p[i:i + 2]); i += 2
            continue
        cls = c == "[" or (cls and c != "]")
        out.append("\\Z" if c == "$" and not cls else c); i += 1
    return re.compile("".join(out))


def desc(v):
    """What a rejected value is, without the value: its JSON type and, for a string, its length."""
    n = {dict: "object", list: "array", bool: "boolean", type(None): "null", str: "string"}.get(type(v), "number")
    return f"a string of {len(v)} characters" if isinstance(v, str) else f"{'an' if n[0] in 'ao' else 'a'} {n}"


def lint_schema(s, path="$", root=None):
    """Problems with the schema itself: a keyword outside the supported subset, or a keyword with a wrong value."""
    if not isinstance(s, dict):
        return [f"schema {path}: not an object"]
    root = s if root is None else root
    errs = [f"schema {path}: keyword {k!r} is not supported by the validator" for k in s if k not in KEYWORDS]
    bad = lambda k, why: errs.append(f"schema {path}: {k} {why}")
    t = s.get("type")
    if "type" in s and not (t in TYPES if isinstance(t, str) else isinstance(t, list) and t and all(isinstance(x, str) and x in TYPES for x in t)):
        bad("type", "must be a known type or a list of them")
    if "required" in s and not (isinstance(s["required"], list) and all(isinstance(x, str) for x in s["required"])):
        bad("required", "must be a list of names")
    if "enum" in s and not (isinstance(s["enum"], list) and s["enum"]):
        bad("enum", "must be a non-empty list")
    if not isinstance(s.get("additionalProperties", True), (bool, dict)):
        bad("additionalProperties", "must be true, false or a schema")
    for k in ("properties", "$defs"):
        if k in s and not isinstance(s[k], dict):
            bad(k, "must be an object")
    for k in ("items", "propertyNames"):
        if k in s and not isinstance(s[k], dict):
            bad(k, "must be a schema")
    for k in ("minLength", "maxLength", "minItems", "maxItems"):
        if k in s and not (isinstance(s[k], int) and not isinstance(s[k], bool) and s[k] >= 0):
            bad(k, "must be a non-negative integer")
    for k in ("minimum", "maximum"):
        if k in s and not (isinstance(s[k], (int, float)) and not isinstance(s[k], bool)):
            bad(k, "must be a number")
    if "uniqueItems" in s and not isinstance(s["uniqueItems"], bool):
        bad("uniqueItems", "must be true or false")
    for k in ("title", "description", "$schema", "$id"):
        if k in s and not isinstance(s[k], str):
            bad(k, "must be a string")
    if "pattern" in s:
        try:
            rx(s["pattern"])
        except (TypeError, re.error):
            bad("pattern", "must be a regular expression")
    if "$ref" in s:
        m = re.fullmatch(r"#/\$defs/([^/]+)", s["$ref"]) if isinstance(s["$ref"], str) else None
        if not m or not isinstance(root.get("$defs"), dict) or m.group(1) not in root["$defs"]:
            bad("$ref", "must be #/$defs/<name> naming an entry of $defs in this schema")
        else:   # a chain of $ref that comes back to itself never reaches the data
            seen, n = set(), m.group(1)
            while isinstance(root["$defs"].get(n), dict) and isinstance(root["$defs"][n].get("$ref"), str) and n not in seen:
                seen.add(n)
                n = (re.fullmatch(r"#/\$defs/([^/]+)", root["$defs"][n]["$ref"]) or [None, None])[1]
            if n in seen:
                bad("$ref", "loops back to itself")
    for k in ("properties", "$defs"):
        if isinstance(s.get(k), dict):
            for n, sub in s[k].items():
                if k == "$defs" and "/" in n:
                    bad("$defs", "names hold no /")
                errs += lint_schema(sub, f"{path}.{n}", root)
    for k, mark in (("items", "[]"), ("additionalProperties", ".*"), ("propertyNames", ".<name>")):
        if isinstance(s.get(k), dict):
            errs += lint_schema(s[k], path + mark, root)
    return errs


def type_ok(v, t):
    return isinstance(v, TYPES[t]) and not (t in ("integer", "number") and isinstance(v, bool))


def same(a, b):
    """JSON equality: true is not 1, and nothing is equal across types."""
    if isinstance(a, bool) != isinstance(b, bool):
        return False
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    return type(a) is type(b) and a == b


def check_value(v, s, defs, p, errs):
    if "$ref" in s:
        check_value(v, defs[s["$ref"].rsplit("/", 1)[-1]], defs, p, errs)   # the siblings of $ref apply below
    t = s.get("type")
    if t is not None:
        ts = [t] if isinstance(t, str) else t
        if not any(type_ok(v, x) for x in ts):
            return errs.append(f"{p}: expected {'/'.join(ts)}, got {desc(v)}")
    if "const" in s and not same(v, s["const"]):
        errs.append(f"{p}: must be {s['const']!r}")
    if "enum" in s and not any(same(v, x) for x in s["enum"]):
        errs.append(f"{p}: {desc(v)} is not one of {s['enum']}")
    if isinstance(v, str):
        if len(v) < s.get("minLength", 0) or len(v) > s.get("maxLength", 1 << 30):
            errs.append(f"{p}: length {len(v)} is out of range")
        if "pattern" in s and not rx(s["pattern"]).search(v):
            errs.append(f"{p}: {desc(v)} does not match {s['pattern']}")
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        if v < s.get("minimum", v) or v > s.get("maximum", v):
            errs.append(f"{p}: {desc(v)} is out of range")
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
            if "propertyNames" in s:
                check_value(k, s["propertyNames"], defs, f"{p}.<name of {desc(k)}>", errs)
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
def checked(doc, rel, schema):
    """doc if it passes its schema, else a DataError naming the file: read commands never serve data `check` refuses."""
    errs = validate_doc(doc, load(f"{SCHEMAS}/{schema}.schema.json"))
    if errs:
        raise DataError(f"{rel}: {errs[0]}" + (f" (and {len(errs) - 1} more)" if len(errs) > 1 else ""))
    return doc


def rows():
    return checked(load(INDEX), INDEX, "data-files")["files"]


def is_folder(row):
    return os.path.isdir(safe(row["path"]))


def docs_of(row, strict=True):
    """[(relative path, parsed doc)] for a JSON data file, or for every *.json of a folder. strict: each must pass its schema."""
    rels = [os.path.relpath(f, os.path.realpath(ROOT)) for f in sorted(glob.glob(os.path.join(safe(row["path"]), "*.json")))] if is_folder(row) else [row["path"]]
    if strict and not row["schema"]:
        raise DataError(f"{row['id']}: no schema named, so its data is not served")
    return [(rel, checked(load(rel), rel, row["schema"]) if strict else load(rel)) for rel in rels]


def entries(row, strict=True):
    """{entry id: entry} for one data file. id_field may list fields (a,b): the id is their values joined with ':'.
    Raises DataError on a repeated id, a file that is not an object, or an entry that is not an object with its id."""
    out, idf, lk = {}, row["id_field"].split(","), row["list_key"]
    for rel, d in docs_of(row, strict):
        items = [d] if lk is None and isinstance(d, dict) else d.get(lk) if isinstance(d, dict) else None
        if isinstance(items, dict):
            pairs = list(items.items())
        elif isinstance(items, list):
            if not all(isinstance(x, dict) and all(f in x for f in idf) for x in items):
                raise DataError(f"{rel}: an entry is not an object with {row['id_field']}")
            pairs = [(":".join(str(x[f]) for f in idf), x) for x in items]
        else:
            raise DataError(f"{rel}: not a JSON object holding the entries")
        for k, e in pairs:
            if not isinstance(e, dict):
                raise DataError(f"{rel}: entry {k} is not an object")
            if k in out:
                raise DataError(f"{rel}: duplicate entry id {k!r}")
            if strict and row["schema"] == "settings" and (setting_problems(e) or store_problems(e, rows())):
                raise DataError(f"{rel}: setting {k}: {(setting_problems(e) or store_problems(e, rows()))[0]}")
            out[k] = e
    return out


# ---- check ----
def why(e):
    return str(e) if isinstance(e, (DataError, ValueError)) else type(e).__name__


NEEDED = {"connections", "data-policy", "role-assignments", "features", "settings", "capabilities", "extension", "approved-hosts"}   # schemas the cross-file rules read


def policy_allows(pol, prov):
    return pol["mode"] == "open" or (pol["mode"] == "local_only" and prov["locality"] == "local") \
        or (pol["mode"] == "allowed_providers" and prov["id"] in pol["allowed_providers"])


def class_problems(table, classes):
    return [f"{n}: requirements.allowed_data_classes[{i}] ({desc(k)}) is not in data-policy data_classes" for n, r in table["roles"].items()
            for i, k in enumerate(r.get("requirements", {}).get("allowed_data_classes", [])) if k not in classes]


def role_problems(doc):
    """A role table is valid only when its schema AND bin/roles.py's own validation pass (the one source of the rules the schema subset
    cannot say); roles.py stays dependency-free, so it is imported here and never the other way round."""
    import roles
    try:
        return validate_doc(doc, load(f"{SCHEMAS}/roles.schema.json")) + roles.validate(doc)
    except DataError:
        raise
    except Exception as e:
        return [f"bin/roles.py could not validate the table ({type(e).__name__})"]


def nm(v, known, path):
    """A value from the file under check as a problem line may show it: an id that exists in the data. Any other value is
    not printed (it may be a pasted secret): its place and JSON type are."""
    return repr(v) if isinstance(v, str) and v in known else f"the value at {path} ({desc(v)})"


def when(h, f):
    try:
        return datetime.datetime.strptime(h[f], "%Y-%m-%dT%H:%M:%SZ") if h[f] is not None else None
    except ValueError:
        return False


def store_problems(s, rs):
    """A setting not marked secret whose store key matches a redact_keys pattern of its store row: its default would be shown."""
    row = next((r for r in rs if r["id"] == s["store"]["data"]), None)
    for p in (row or {}).get("redact_keys", []):
        try:
            if s["sensitivity"] != "secret" and re.search(p, s["store"]["key"]):
                return ["its store key is one its data file redacts, so it must be marked secret"]
        except re.error:
            pass   # check reports a pattern that does not compile
    return []


def cross_rules(by, whole, P, rs):
    """Cross-file rules. by: schema name -> {entry id: entry}; whole: schema name -> the parsed file; P(data id, problem) records
    one; rs: the index rows. Files are found by the row's schema, so a renamed row switches no rule off."""
    dids = {r["schema"]: r["id"] for r in rs if r["format"] == "json"}
    D = lambda sch: dids.get(sch, sch)
    conn, feats, sets = by.get("connections", {}), by.get("features", {}), by.get("settings", {})
    table = load(load(INDEX)["role_table"])
    allroles = table["roles"]
    roles = set(allroles) - {table["fallback_role"]}   # the fail-closed row is no role to assign or allow
    pol, ra = whole.get("data-policy"), whole.get("role-assignments")
    if pol:
        classes = set(pol["data_classes"])
        for proj, p in [("default", pol["default"])] + list(pol["projects"].items()):
            for i, prov in enumerate(p["allowed_providers"]):
                if prov not in conn:
                    P(D("data-policy"), f"{proj}: allowed_providers[{i}] ({desc(prov)}) is not in the connections catalog")
        for c in conn.values():
            for i, k in enumerate(c["data_policy"]["data_classes_allowed"]):
                if k not in classes:
                    P(D("connections"), f"{c['id']}: data_classes_allowed[{i}] ({desc(k)}) is not in data-policy data_classes")
            hosts = [h["host"] for h in c["hosts"]]
            if c["kind"] == "provider" and c["locality"] == "local" and (not hosts or not set(hosts) <= set(pol["local_hosts"])):
                P(D("connections"), f"{c['id']}: locality is local, but it lists no host or a host outside the data policy local_hosts")
        for m in class_problems(table, classes):
            P("role-table", m)
    if ra:
        seen, cards = {}, {}
        for a in ra["assignments"]:
            sc, lvl = a["scope"], a["scope"]["level"]
            want = {"global": (), "project": ("project",), "card": ("project", "card")}[lvl]
            for k in ("project", "card"):
                if (k in want) != (k in sc):
                    P(D("role-assignments"), f"{a['id']}: scope.level {lvl} {'needs' if k in want else 'has no'} {k}")
            key = (lvl, sc.get("project"), sc.get("card"), a["role"], a["effort_mode"])
            if key in seen:
                P(D("role-assignments"), f"{a['id']}: same scope, role and effort mode as {seen[key]}")
            seen[key] = a["id"]
            if "card" in sc:
                if cards.setdefault(sc["card"], (sc.get("project"), a["id"]))[0] != sc.get("project"):
                    P(D("role-assignments"), f"{a['id']}: its card is also filed under another project, in {cards[sc['card']][1]}")
            if a["role"] not in roles:
                P(D("role-assignments"), f"{a['id']}: {nm(a['role'], allroles, 'role')} is not an assignable role in the role table")
            mode = ra["effort_modes"].get(a["effort_mode"])
            if mode is None:
                P(D("role-assignments"), f"{a['id']}: effort_mode ({desc(a['effort_mode'])}) is not defined")
            if pol is None:
                P(D("role-assignments"), f"{a['id']}: cannot be judged, the data policy is not readable")
            proj = sc.get("project") if pol and sc.get("project") in pol["projects"] else None
            policy = (pol["projects"][proj] if proj else pol["default"]) if pol else None
            need = allroles.get(a["role"], {}).get("requirements", {}).get("allowed_data_classes", [])
            for i, c in enumerate(a["chain"]):
                prov, w = conn.get(c["provider"]), f"{a['id']}: chain[{i}]"
                if prov is None or prov["kind"] != "provider":
                    P(D("role-assignments"), f"{w}.provider ({desc(c['provider'])}) is not a provider in the connections catalog")
                    continue
                if not prov["enabled"]:
                    P(D("role-assignments"), f"{w}: {c['provider']} is switched off")
                if c["model"] not in [m["id"] for m in prov["models"]]:
                    P(D("role-assignments"), f"{w}.model ({desc(c['model'])}) is not listed for {c['provider']}")
                if mode and prov["locality"] not in mode["allowed_localities"]:
                    P(D("role-assignments"), f"{w}: {c['provider']} is {prov['locality']}, which effort mode {a['effort_mode']} forbids")
                if policy and not policy_allows(policy, prov):
                    P(D("role-assignments"), f"{w}: {c['provider']} is not allowed by the data policy for {proj or 'the default'} (an override never widens the policy)")
                if any(k not in prov["data_policy"]["data_classes_allowed"] for k in need):   # an empty list allows no class
                    P(D("role-assignments"), f"{w}: {c['provider']} does not allow every data class that role {a['role']} handles")
    for f in feats.values():
        for i, d in enumerate(f["depends_on"]):
            if d not in feats:
                P(D("features"), f"{f['id']}: depends_on[{i}] ({desc(d)}) is not a feature")
            elif f["status"] == "on" and feats[d]["status"] != "on":
                P(D("features"), f"{f['id']} is on but depends on {d}, which is {feats[d]['status']}")
    for start in feats:   # a cycle: walking depends_on from a feature gets back to it
        seen, todo = set(), [d for d in feats[start]["depends_on"] if d in feats]
        while todo:
            n = todo.pop()
            if n == start:
                P(D("features"), f"{start} depends on itself through a cycle")
                break
            if n not in seen:
                seen.add(n)
                todo += [d for d in feats[n]["depends_on"] if d in feats]
    for sch in ("capabilities", "extension", "connections"):
        for e in by.get(sch, {}).values():
            for i, r in enumerate(e.get("allowed_roles", [])):
                if r not in roles:
                    P(D(sch), f"{e['id']}: {nm(r, allroles, f'allowed_roles[{i}]')} is not an assignable role in the role table")
    for e in by.get("extension", {}).values():
        if e["enabled"] and e["status"] != "approved":
            P(D("extension"), f"{e['id']}: switched on while its status is {e['status']}; only an approved extension may be on")
    for e in conn.values():
        if e["kind"] != "app" and not {"allowed_roles", "risk_class"} <= set(e):
            P(D("connections"), f"{e['id']}: a provider or channel states its allowed_roles and risk_class")
        for p in e.get("redaction_patterns", []):
            try:
                re.compile(p)
            except re.error:
                P(D("connections"), f"{e['id']}: a redaction pattern is not a regular expression")
    for k, h in by.get("approved-hosts", {}).items():
        a, x = when(h, "approved_at"), when(h, "expires_at")
        for f, v in (("approved_at", a), ("expires_at", x)):
            if v is False:
                P(D("approved-hosts"), f"{k}: {f} is not a real date")
        if a and x and x <= a:
            P(D("approved-hosts"), f"{k}: expires_at is not after approved_at")
    codes = alert_catalog.catalog() if sets else {}
    for s in sets.values():
        k = s["key"]
        if s["store"]["data"] not in by["_ids"]:
            P(D("settings"), f"{k}: store.data ({desc(s['store']['data'])}) is not a data file in the index")
        if s["code"] not in codes:
            P(D("settings"), f"{k}: code ({desc(s['code'])}) is not in the alert catalog")
        for m in setting_problems(s) + store_problems(s, rs):
            P(D("settings"), f"{k}: {m}")


def setting_problems(s):
    """A settings entry against itself: no default for a secret, coherent validation, a default that satisfies type and validation."""
    v, errs = s["validation"], []
    if s["sensitivity"] == "secret" and s["default"] is not None:
        errs.append("a secret setting has no default (secrets are never stored in the registry)")
    if s["type"] == "enum" and not v.get("values"):
        errs.append("type enum needs validation.values")
    if "minimum" in v and "maximum" in v and v["minimum"] > v["maximum"]:
        errs.append("validation minimum is above maximum")
    if "pattern" in v:
        try:
            rx(v["pattern"])
        except re.error:
            errs.append("validation pattern is not a regular expression")
    if not errs and s["default"] is not None:
        sch = {"type": "string" if s["type"] == "enum" else s["type"], **{a: v[a] for a in ("pattern", "minimum", "maximum") if a in v}}
        if "values" in v:
            sch["enum"] = v["values"]
        errs += [f"default {m}" for m in validate_doc(s["default"], sch)]
    return errs


def same_path(a, b):
    try:
        return safe(a) == safe(b)
    except DataError:
        return False


def check(only=None):
    """[(data id, problem)] over every data file in the index. With `only`: that file's problems, the index's own, and
    every cross-file problem (a candidate file is judged against the rest of the data)."""
    probs = []
    P = lambda d, m: probs.append((d, m))
    try:
        idx = load(INDEX)
        errs = validate_doc(idx, load(f"{SCHEMAS}/data-files.schema.json"))
        if errs:
            return [("data-files", e) for e in errs]
        rs = idx["files"]
    except Exception as e:
        return [("data-files", f"{INDEX}: {why(e)}")]
    by, whole = {"_ids": [r["id"] for r in rs]}, {}
    if len(set(by["_ids"])) != len(rs):
        P("data-files", "an id is listed twice in the index")
    own = [r for r in rs if r["format"] == "json" and same_path(r["path"], INDEX)]
    if not own or not all(r["owner_only"] for r in own):
        P("data-files", "the index row that describes the index must exist and be owner_only")
    for r in rs:
        for i, p in enumerate(r["redact_keys"]):
            try:
                re.compile(p)
            except re.error:
                P(r["id"], f"redact_keys[{i}] is not a regular expression")
    for rel in [idx[k] for k in ("event_log", "backup_dir", "applied_state", "role_table")] + [r["path"] for r in rs if r["format"] != "json"]:
        try:
            safe(rel)
        except DataError as e:
            P("data-files", str(e))
    head = len(probs)
    for r in rs:
        if r["format"] != "json":
            continue   # shortcut: env files are not read here (the owner's file never is), `check` says so; upgrade with W3
        try:
            if not r["schema"]:
                raise DataError("no schema named")
            sch = load(f"{SCHEMAS}/{r['schema']}.schema.json")
            ds = docs_of(r, False)
            for rel, d in ds:
                if not isinstance(d, dict) or "schema_version" not in d:
                    P(r["id"], f"{rel}: schema_version is missing")
                for e in validate_doc(d, sch):
                    P(r["id"], f"{rel}: {e}")
            by.setdefault(r["schema"], {}).update(entries(r, False))
            whole.setdefault(r["schema"], ds[0][1] if ds else None)
        except Exception as e:
            P(r["id"], f"{r['path']}: {why(e)}")
    mid = len(probs)
    try:
        for m in role_problems(load(idx["role_table"])):
            P("role-table", f"{idx['role_table']}: {m}")
    except Exception as e:
        P("role-table", f"{idx['role_table']}: {why(e)}")
    have = {r["schema"] for r in rs if r["format"] == "json"}
    for n in sorted(NEEDED - have):
        P("data-files", f"cross-file rules could not run: no JSON data file has schema {n}")
    if NEEDED <= have:
        try:
            cross_rules(by, whole, P, rs)
        except Exception as e:
            P("data-files", f"cross-file rules could not run: {why(e)}")
    return [p for i, p in enumerate(probs) if only is None or only in [r["id"] for r in own] or p[0] == only or i < head or i >= mid]


# ---- reading ----
def unopened():
    return [r["id"] for r in rows() if r["format"] != "json"]


def say(code, problem, alert=False):
    """The catalog's plain message for a code, on stderr; with alert=True also one line in the alert log."""
    body, tag, kv = alert_catalog.render(code, {"problem": problem})
    if alert:
        sup = os.environ.get("ESCALATE_SUP_DIR") or f"{alert_catalog.ROOT}/.supervisor"
        size = lambda: os.path.getsize(f"{sup}/logs/alerts.log") if os.path.exists(f"{sup}/logs/alerts.log") else 0
        before = size()
        alert_catalog.log(tag, kv)
        if size() == before:
            print("the alert line could not be written to the alert log", file=sys.stderr)
    print(f"{code} {body.split(chr(10))[1]}", file=sys.stderr)


def refuse(kind, name):
    """Unknown fails closed: STL-CFG-311, the catalog's plain message, exactly one alert line."""
    say("STL-CFG-311", f"{kind} {name}", alert=True)
    sys.exit(1)


def row_of(did):
    return next((r for r in rows() if r["id"] == did), None) or refuse("data file", did)


def known_json(did):
    """The index row of a data file this tool can read; an env row is known but never read here (no alert line)."""
    row = row_of(did)
    if row["format"] != "json":
        say("STL-CFG-319", f"{did} is in env format, read only by the apply tool")
        sys.exit(1)
    return row


def find_entries(row):
    return entries(row) if row["format"] == "json" and (row["list_key"] or is_folder(row)) else {}


def masked(row, x, pats=None):
    """x with every value under a key that matches the row's redact_keys (at any depth, free-form objects too), and a secret
    setting's default, replaced. Every read command goes through here."""
    if pats is None:
        try:
            pats = [re.compile(p) for p in row["redact_keys"]]
        except re.error:
            raise DataError(f"{row['id']}: a redact_keys pattern is not a regular expression") from None
    if isinstance(x, dict):
        hide = x.get("sensitivity") == "secret"
        return {k: "***" if v is not None and ((hide and k == "default") or any(p.search(k) for p in pats)) else masked(row, v, pats)
                for k, v in x.items()}
    return [masked(row, i, pats) for i in x] if isinstance(x, list) else x


def leaves(x):
    if isinstance(x, dict):
        for v in x.values():
            yield from leaves(v)
    elif isinstance(x, list):
        for v in x:
            yield from leaves(v)
    elif x is not None:
        yield x if isinstance(x, str) else json.dumps(x)


def shown(k):
    """An id as a text line shows it: quoted when it holds anything but name characters (a line break cannot forge a row)."""
    return k if re.fullmatch(r"[\w.:,@/-]+", k) else json.dumps(k, ensure_ascii=False)


def emit(obj, as_json, line=None):
    print(json.dumps(obj, indent=2, ensure_ascii=False) if as_json or line is None else "\n".join(line(x) for x in obj))


def main(argv):
    as_json = "--json" in argv
    a = [x for x in argv if x != "--json"]
    cmd, args = (a[0] if a else ""), a[1:]
    if cmd == "check" and len(args) <= 1:
        if args:
            try:
                row_of(args[0])
            except DataError:
                pass   # an unreadable index is itself a problem that check prints
        probs = check(args[0] if args else None)
        lines = []
        for d, m in probs:
            body = alert_catalog.render("STL-CFG-310", {"problem": f"{d}: {m}"})[0]
            lines.append({"code": "STL-CFG-310", "data": d, "problem": m, "message": body.split("\n")[1]})
        try:
            skipped = unopened()
        except DataError:
            skipped = []
        if as_json:
            print(json.dumps({"ok": not probs, "problems": lines, "not_opened": skipped}, indent=2, ensure_ascii=False))
        else:
            print("\n".join(f"STL-CFG-310 {l['message']}" for l in lines) or "data OK")
            if skipped:
                print(f"not opened (env format, read by the apply tool): {', '.join(skipped)}")
        return 1 if probs else 0
    if cmd == "validate" and len(args) == 2:
        doc = jload(args[1])
        errs = [] if args[0] == "roles" else validate_doc(doc, load(f"{SCHEMAS}/{args[0]}.schema.json"))
        if args[0] == "roles":   # the role table has two judges, and a data class must be one the data policy defines
            errs = role_problems(doc)
            if not errs:
                errs = class_problems(doc, set(load(row_of("data-policy")["path"])["data_classes"]))
            errs = [f"STL-CFG-310 {alert_catalog.render('STL-CFG-310', {'problem': 'role table: ' + e})[0].split(chr(10))[1]}" for e in errs]
        print("\n".join(errs) or "valid")
        return 1 if errs else 0
    if cmd == "list" and len(args) <= 1:
        if args:
            row = known_json(args[0])
            ents = {k: masked(row, e) for k, e in find_entries(row).items()}
            emit([{"id": k, **{f: e[f] for f in ("kind", "subkind", "label", "status", "summary") if f in e}} for k, e in ents.items()],
                 as_json, lambda x: "\t".join([shown(x["id"])] + [str(v) for v in list(x.values())[1:]]))
        else:
            emit([{"id": r["id"], "path": r["path"], "schema": r["schema"], "owner_only": r["owner_only"],
                   "entries": len(find_entries(r))} for r in rows()], as_json, lambda x: "\t".join(str(v) for v in x.values()))
        return 0
    if cmd == "get" and 1 <= len(args) <= 2:
        row = known_json(args[0])
        if len(args) == 1:
            ents = entries(row) if row["list_key"] or is_folder(row) else {}   # also refuses an entry check refuses
            emit(masked(row, ents if is_folder(row) else docs_of(row)[0][1]), True)
            return 0
        ents = find_entries(row)
        if args[1] not in ents:
            refuse(f"entry of {args[0]}", args[1])
        emit(masked(row, ents[args[1]]), True)
        return 0
    if cmd == "search" and args:
        words, hits = [w.casefold() for w in args], []
        for r in rows():
            for k, e in find_entries(r).items():
                e = masked(r, e)
                text = " ".join([k, *leaves(e)]).casefold()
                if all(w in text for w in words):
                    hits.append({"data": r["id"], "id": k, "status": e.get("status", ""), "summary": e.get("summary") or e.get("label") or ""})
        hits.sort(key=lambda h: (h["status"] != "approved", h["data"], h["id"]))
        emit(hits, as_json, lambda h: f"{h['data']}\t{shown(h['id'])}\t{h['status']}\t{h['summary']}")
        return 0
    print(__doc__.split("\n", 1)[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except DataError as e:   # a file this tool cannot read: one catalog line naming it, never a traceback
        say("STL-CFG-310", str(e))
        sys.exit(1)
    except RecursionError:
        say("STL-CFG-310", "a data file is nested too deeply")
        sys.exit(1)
    except Exception as e:   # never a traceback, never the value: the type only
        say("STL-CFG-310", f"{type(e).__name__}, an unexpected failure")
        sys.exit(1)
