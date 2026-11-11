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
keywords still apply), $defs, $schema, $id, title, description, and x-one-document (true: the schema is one document by
nature, so a second file of it is refused). Any other keyword, or a wrong keyword value, is an error, never ignored.
Two rules hold the rest: every file an index row names is judged by every rule of its schema (all rows of a schema form one
merged view, which is what check judges and what the read commands serve); and a read command runs the same rules on the
files it serves and refuses, with the same STL-CFG-310 line, whatever check refuses."""
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
            "pattern", "minimum", "maximum", "x-one-document"}
MAX_DEPTH = 64   # a data file nests far less; one limit makes `check` and the read commands agree on a deep object
TYPES = {"object": dict, "array": list, "string": str, "integer": int, "number": (int, float), "boolean": bool, "null": type(None)}


class DataError(Exception):
    """A data file or path this tool cannot use; the message names it and never holds a data value."""


# ---- strict JSON loading, paths inside the root ----
def _pairs(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise ValueError(f"repeated key {kname(k)}")
        d[k] = v
    return d


def _bad_const(c):
    raise ValueError(f"{c} is not JSON")


def _float(s):
    v = float(s)
    if v in (float("inf"), float("-inf")) or (v == 0 and re.search(r"[1-9]", s.lower().split("e")[0])):   # overflow, underflow
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


def files_of(row):
    """[(relative path, absolute path)]: the file a row names, or every *.json of a JSON row's folder; each inside the root."""
    p = safe(row["path"])
    if row["format"] == "json" and os.path.isdir(p):
        return [(rel, safe(rel)) for rel in (os.path.relpath(f, ROOT) for f in sorted(glob.glob(os.path.join(p, "*.json"))))]
    return [(row["path"], p)]


def owner_files(table):
    """The resolved paths of the role table's owner settings, or None when the table does not say (then no JSON row is opened)."""
    try:
        return {safe(f) for f in table["owner_settings"]}
    except Exception:
        return None


def layout(rs, owner):
    """Where every row's files are, and which rows may be opened: ([(row id, problem)], [(row, files)] of the JSON rows that
    may be opened). A file named by two rows is opened by neither; a row on an owner setting must be an env row and owner_only,
    and is never opened."""
    probs, named, by_file = [], [], {}
    for r in rs:
        try:
            fs = files_of(r)
        except DataError as e:
            probs.append((r["id"], str(e)))
            continue
        named.append((r, fs))
        for _, a in fs:
            by_file.setdefault(a, []).append(r)
    if owner is None:   # shortcut: with no readable role table only the env rows' files are kept closed; check reports the table
        probs.append(("role-table", "the role table's owner_settings cannot be read, so only the files of env rows are kept closed"))
        owner = {a for r, fs in named if r["format"] == "env" for _, a in fs}
    shut = set()
    for a, rr in by_file.items():
        rel = os.path.relpath(a, ROOT)
        if len(rr) > 1:
            shut |= {id(r) for r in rr}
            probs.append((rr[-1]["id"], f"{rel} is named by more than one index row ({', '.join(r['id'] for r in rr)}), so none of them is opened"))
        for r in rr if owner and a in owner else []:
            shut.add(id(r))
            if r["format"] != "env" or not r["owner_only"]:
                probs.append((r["id"], f"{rel} is an owner setting of the role table: its row must be format env and owner_only, and it is never opened here"))
    return probs, [(r, fs) for r, fs in named if r["format"] == "json" and id(r) not in shut]


_pats = "unread"


def value_pats():
    """The value patterns the connections catalog carries (redaction_patterns of every entry of every connections file),
    compiled; None when they cannot be read. Read leniently (a repeated key, NaN), so a broken file still masks: check says
    what is wrong with it. While they are being read the answer is None (fail closed: every key name is masked)."""
    global _pats
    if _pats == "unread":
        _pats, out = None, []
        try:
            def lax(rel):
                with open(safe(rel), encoding="utf-8") as f:
                    return json.load(f)
            idx = lax(INDEX)
            try:
                table = lax(idx["role_table"])
            except Exception:
                table = None
            for r, fs in layout(idx["files"], owner_files(table))[1]:
                for rel, _ in fs if r["schema"] == "connections" else []:
                    d = lax(rel)
                    for e in d.get(r["list_key"]) or [] if isinstance(d, dict) else []:
                        for p in e.get("redaction_patterns") or [] if isinstance(e, dict) else []:
                            try:
                                out.append(re.compile(p))
                            except (re.error, TypeError):
                                pass   # check reports a pattern that does not compile
            _pats = out
        except Exception:
            pass
    return _pats


def hidden(text):
    """True when a value pattern matches the text, or the patterns cannot be read."""
    v = value_pats()
    return v is None or any(p.search(text) for p in v)


def kname(k):
    """A key name taken from a file, as a problem line shows it: quoted, unless a value pattern matches it."""
    return "a masked key" if hidden(k) else repr(k)


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
    for k in ("uniqueItems", "x-one-document"):
        if k in s and not isinstance(s[k], bool):
            bad(k, "must be true or false")
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
                errs.append(f"{p}: {kname(k)} is not allowed")
            elif isinstance(extra, dict):
                check_value(x, extra, defs, f"{p}.{'<a masked key>' if hidden(k) else k}", errs)


def validate_doc(doc, schema):
    errs = lint_schema(schema)
    if not errs:
        check_value(doc, schema, schema.get("$defs", {}), "$", errs)
    return errs


# ---- the index and the entries ----
def checked(doc, rel, schema):
    """doc if it passes its schema, else a DataError naming the file. The read commands of this tool also run the cross-file
    rules on what they serve (served()), so they never serve data `check` refuses."""
    errs = validate_doc(doc, load(f"{SCHEMAS}/{schema}.schema.json"))
    if errs:
        raise DataError(f"{rel}: {errs[0]}" + (f" (and {len(errs) - 1} more)" if len(errs) > 1 else ""))
    return doc


def rows():
    return checked(load(INDEX), INDEX, "data-files")["files"]


def is_folder(row):
    return os.path.isdir(safe(row["path"]))


def file_entries(row, rel, d):
    """[(entry id, entry)] of one parsed file. id_field may list fields (a,b): the id is their values joined with ':'.
    Raises DataError on a file that is not an object holding the entries, or an entry that is not an object with its id."""
    idf, lk = row["id_field"].split(","), row["list_key"]
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
    return pairs


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
        return validate_doc(doc, load(f"{SCHEMAS}/roles.schema.json")) + roles.validate(doc, ROOT)
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
    """Cross-file rules over the merged view. by: schema name -> {entry id: entry} (every file of every row of the schema);
    whole: schema name -> [(row id, parsed file)] (every file); by["_src"]: schema -> {entry id: row id}; P(data id, problem)
    records one against the row that holds it. Files are found by the row's schema, so a renamed row switches no rule off."""
    src = by["_src"]
    D = lambda sch, k=None: src.get(sch, {}).get(k) or next((rid for rid, _ in whole.get(sch, [])), sch)
    conn, feats, sets = by.get("connections", {}), by.get("features", {}), by.get("settings", {})
    try:
        table = load(load(INDEX)["role_table"])
    except DataError:   # the rules that read it cannot run: the rows they judge are refused, the others still judged
        table = None
        for sch in ("role-assignments", "capabilities", "extension", "connections"):
            for rid in dict(whole.get(sch, [])):
                P(rid, "the rules that read the role table could not run: it cannot be read")
    allroles = table["roles"] if table else {}
    roles = set(allroles) - {table["fallback_role"]} if table else set()   # the fail-closed row is no role to assign or allow
    pols, ras = whole.get("data-policy", []), whole.get("role-assignments", [])
    if pols:   # several policy files (a schema not marked one document): a value must pass every one of them
        classes = set.intersection(*(set(d["data_classes"]) for _, d in pols))
        local = set.intersection(*(set(d["local_hosts"]) for _, d in pols))
        projects = {k: v for _, d in pols for k, v in d["projects"].items()}
        for rid, pol in pols:
            for proj, p in [("default", pol["default"])] + list(pol["projects"].items()):
                for i, prov in enumerate(p["allowed_providers"]):
                    if prov not in conn:
                        P(rid, f"{'default' if proj == 'default' else kname(proj)}: allowed_providers[{i}] ({desc(prov)}) is not in the connections catalog")
        for c in conn.values():
            for i, k in enumerate(c["data_policy"]["data_classes_allowed"]):
                if k not in classes:
                    P(D("connections", c["id"]), f"{c['id']}: data_classes_allowed[{i}] ({desc(k)}) is not in data-policy data_classes")
            hosts = [h["host"] for h in c["hosts"]]
            if c["kind"] == "provider" and c["locality"] == "local" and (not hosts or not set(hosts) <= local):
                P(D("connections", c["id"]), f"{c['id']}: locality is local, but it lists no host or a host outside the data policy local_hosts")
        for m in class_problems(table, classes) if table else []:
            P("role-table", m)
    seen, cards = {}, {}
    for rid, ra in ras if table else []:
        for a in ra["assignments"]:
            sc, lvl = a["scope"], a["scope"]["level"]
            want = {"global": (), "project": ("project",), "card": ("project", "card")}[lvl]
            for k in ("project", "card"):
                if (k in want) != (k in sc):
                    P(rid, f"{a['id']}: scope.level {lvl} {'needs' if k in want else 'has no'} {k}")
            key = (lvl, sc.get("project"), sc.get("card"), a["role"], a["effort_mode"])
            if key in seen:
                P(rid, f"{a['id']}: same scope, role and effort mode as {seen[key]}")
            seen[key] = a["id"]
            if "card" in sc:
                if cards.setdefault(sc["card"], (sc.get("project"), a["id"]))[0] != sc.get("project"):
                    P(rid, f"{a['id']}: its card is also filed under another project, in {cards[sc['card']][1]}")
            if a["role"] not in roles:
                P(rid, f"{a['id']}: {nm(a['role'], allroles, 'role')} is not an assignable role in the role table")
            mode = ra["effort_modes"].get(a["effort_mode"])
            if mode is None:
                P(rid, f"{a['id']}: effort_mode ({desc(a['effort_mode'])}) is not defined")
            if not pols:
                P(rid, f"{a['id']}: cannot be judged, the data policy is not readable")
            proj = sc.get("project") if sc.get("project") in (projects if pols else {}) else None
            policies = ([projects[proj]] if proj else [d["default"] for _, d in pols]) if pols else []
            need = allroles.get(a["role"], {}).get("requirements", {}).get("allowed_data_classes", [])
            for i, c in enumerate(a["chain"]):
                prov, w = conn.get(c["provider"]), f"{a['id']}: chain[{i}]"
                if prov is None or prov["kind"] != "provider":
                    P(rid, f"{w}.provider ({desc(c['provider'])}) is not a provider in the connections catalog")
                    continue
                if not prov["enabled"]:
                    P(rid, f"{w}: {c['provider']} is switched off")
                if c["model"] not in [m["id"] for m in prov["models"]]:
                    P(rid, f"{w}.model ({desc(c['model'])}) is not listed for {c['provider']}")
                if mode and prov["locality"] not in mode["allowed_localities"]:
                    P(rid, f"{w}: {c['provider']} is {prov['locality']}, which effort mode {a['effort_mode']} forbids")
                if not all(policy_allows(p, prov) for p in policies):
                    P(rid, f"{w}: {c['provider']} is not allowed by the data policy for {proj or 'the default'} (an override never widens the policy)")
                if any(k not in prov["data_policy"]["data_classes_allowed"] for k in need):   # an empty list allows no class
                    P(rid, f"{w}: {c['provider']} does not allow every data class that role {a['role']} handles")
                if a["role"] not in prov.get("allowed_roles", []):   # an empty list allows no role
                    P(rid, f"{w}: {c['provider']} does not list role {nm(a['role'], allroles, 'role')} in its allowed_roles")
    for f in feats.values():
        for i, d in enumerate(f["depends_on"]):
            if d not in feats:
                P(D("features", f["id"]), f"{f['id']}: depends_on[{i}] ({desc(d)}) is not a feature")
            elif f["status"] == "on" and feats[d]["status"] != "on":
                P(D("features", f["id"]), f"{f['id']} is on but depends on {d}, which is {feats[d]['status']}")
    for start in feats:   # a cycle: walking depends_on from a feature gets back to it
        seen, todo = set(), [d for d in feats[start]["depends_on"] if d in feats]
        while todo:
            n = todo.pop()
            if n == start:
                P(D("features", start), f"{start} depends on itself through a cycle")
                break
            if n not in seen:
                seen.add(n)
                todo += [d for d in feats[n]["depends_on"] if d in feats]
    for sch in ("capabilities", "extension", "connections") if table else ():
        for k, e in by.get(sch, {}).items():
            for i, r in enumerate(e.get("allowed_roles", [])):
                if r not in roles:
                    P(D(sch, k), f"{e['id']}: {nm(r, allroles, f'allowed_roles[{i}]')} is not an assignable role in the role table")
    for k, e in by.get("extension", {}).items():
        if e["enabled"] and e["status"] != "approved":
            P(D("extension", k), f"{e['id']}: switched on while its status is {e['status']}; only an approved extension may be on")
    for k, e in conn.items():
        if e["kind"] != "app" and not {"allowed_roles", "risk_class"} <= set(e):
            P(D("connections", k), f"{e['id']}: a provider or channel states its allowed_roles and risk_class")
        for p in e.get("redaction_patterns", []):
            try:
                re.compile(p)
            except re.error:
                P(D("connections", k), f"{e['id']}: a redaction pattern is not a regular expression")
    for k, h in by.get("approved-hosts", {}).items():
        a, x = when(h, "approved_at"), when(h, "expires_at")
        for f, v in (("approved_at", a), ("expires_at", x)):
            if v is False:
                P(D("approved-hosts", k), f"{k}: {f} is not a real date")
        if a and x and x <= a:
            P(D("approved-hosts", k), f"{k}: expires_at is not after approved_at")
    codes = alert_catalog.catalog() if sets else {}
    for k, s in sets.items():
        if s["store"]["data"] not in by["_ids"]:
            P(D("settings", k), f"{s['key']}: store.data ({desc(s['store']['data'])}) is not a data file in the index")
        if s["code"] not in codes:
            P(D("settings", k), f"{s['key']}: code ({desc(s['code'])}) is not in the alert catalog")
        for m in setting_problems(s) + store_problems(s, rs):
            P(D("settings", k), f"{s['key']}: {m}")


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


def judge(reads=None):
    """(problems, view). problems: [(data id, problem)] over every data file in the index; view: by schema name the merged
    {entry id: entry} of every file of every row of that schema, plus "_rows": {row id: ([(rel, doc)], {entry id: entry})},
    "_src", "_ids". reads: the row ids a read command serves: then the role table itself is not validated (it is not served)
    and a row is opened only when its schema is one the cross-file rules read or one of a served row. Third value, for
    check <id>: where the per-file problems start and end, and the ids of the index's own rows."""
    probs = []
    P = lambda d, m: probs.append((d, m))
    try:
        idx = load(INDEX)
        errs = validate_doc(idx, load(f"{SCHEMAS}/data-files.schema.json"))
        if errs:
            return [("data-files", e) for e in errs], None, (0, 0, [])
        rs = idx["files"]
    except Exception as e:
        return [("data-files", f"{INDEX}: {why(e)}")], None, (0, 0, [])
    by, whole = {"_ids": [r["id"] for r in rs], "_src": {}, "_rows": {}}, {}
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
    for rel in [idx[k] for k in ("event_log", "backup_dir", "applied_state", "role_table")]:
        try:
            safe(rel)
        except DataError as e:
            P("data-files", str(e))
    try:
        table = load(idx["role_table"])
    except Exception:
        table = None   # reported below as a role-table problem
    found, opened = layout(rs, owner_files(table))
    probs += found
    head = len(probs)
    want = NEEDED | {r["schema"] for r in rs if reads is not None and r["id"] in reads}
    where = {}   # schema -> {entry id: the file that holds it}
    for r, fs in opened:
        if reads is not None and r["schema"] not in want:
            continue
        try:
            if not r["schema"]:
                raise DataError("no schema named")
            name, sch = r["schema"], load(f"{SCHEMAS}/{r['schema']}.schema.json")
            docs, ents = [], {}
            for rel, _ in fs:
                d = load(rel)
                if not isinstance(d, dict) or "schema_version" not in d:
                    P(r["id"], f"{rel}: schema_version is missing")
                for e in validate_doc(d, sch):
                    P(r["id"], f"{rel}: {e}")
                if sch.get("x-one-document") is True and whole.get(name):
                    P(r["id"], f"{rel}: schema {name} is one document, and {whole[name][0][2]} already holds it")
                    continue
                pairs = file_entries(r, rel, d)
                whole.setdefault(name, []).append((r["id"], d, rel))
                docs.append((rel, d))
                for k, e in pairs:
                    if k in where.setdefault(name, {}):
                        P(r["id"], f"{rel}: duplicate entry id {k!r}" + ("" if where[name][k] == rel else f", also in {where[name][k]}"))
                        continue
                    where[name][k] = rel
                    by.setdefault(name, {})[k] = ents[k] = e
                    by["_src"].setdefault(name, {})[k] = r["id"]
            by["_rows"][r["id"]] = (docs, ents)
        except Exception as e:
            P(r["id"], f"{r['path']}: {why(e)}")
    mid = len(probs)
    if reads is None:
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
            cross_rules(by, {k: [(rid, d) for rid, d, _ in v] for k, v in whole.items()}, P, rs)
        except Exception as e:
            P("data-files", f"cross-file rules could not run: {why(e)}")
    return probs, by, (head, mid, [r["id"] for r in own])


def check(only=None):
    """[(data id, problem)] over every data file in the index. With `only`: that file's problems, the index's own, and
    every cross-file problem (a candidate file is judged against the rest of the data)."""
    probs, _, (head, mid, own) = judge()
    return [p for i, p in enumerate(probs) if only is None or only in own or p[0] == only or i < head or i >= mid]


def served(ids):
    """The merged view, for a read of the rows `ids`, after the rules `check` runs on them (schema and cross-file): a problem
    of one of them, or of the index, refuses the read with that STL-CFG-310 line and no data."""
    probs, by, cut = judge(reads=set(ids))
    index = {"data-files", *cut[2]}   # the index's own problems refuse every read
    bad = [f"{d}: {m}" for d, m in probs if d in ids or d in index]
    if bad:
        raise DataError(bad[0] + (f" (and {len(bad) - 1} more)" if len(bad) > 1 else ""))
    return by


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


def find_entries(row, by):
    """{entry id: entry} of one row from the view served() returned; a row with no list and no folder has none."""
    if row["format"] != "json" or not (row["list_key"] or is_folder(row)):
        return {}
    if row["id"] not in by["_rows"]:
        raise DataError(f"{row['id']}: not read")   # served() refuses first; never serve a row the rules did not see
    return by["_rows"][row["id"]][1]


def masked(row, x, pats=None):
    """x with every value under a key that matches the row's redact_keys (at any depth, free-form objects too), a secret
    setting's default, and every string a value pattern of the catalog matches (lists too), replaced. Every read command
    goes through here."""
    if pats is None:
        try:
            pats = [re.compile(p) for p in row["redact_keys"]]
        except re.error:
            raise DataError(f"{row['id']}: a redact_keys pattern is not a regular expression") from None
        if value_pats() is None:
            raise DataError("the value patterns of the connections catalog cannot be read, so nothing is served")
    if isinstance(x, str):
        return "***" if hidden(x) else x
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
        label = "role table" if args[0] == "roles" else f"{args[0]} file"
        errs = [f"STL-CFG-310 {alert_catalog.render('STL-CFG-310', {'problem': f'{label}: {e}'})[0].split(chr(10))[1]}" for e in errs]
        print("\n".join(errs) or "valid")
        return 1 if errs else 0
    if cmd == "list" and len(args) <= 1:
        if args:
            row = known_json(args[0])
            ents = {k: masked(row, e) for k, e in find_entries(row, served([row["id"]])).items()}
            emit([{"id": k, **{f: e[f] for f in ("kind", "subkind", "label", "status", "summary") if f in e}} for k, e in ents.items()],
                 as_json, lambda x: "\t".join([shown(x["id"])] + [str(v) for v in list(x.values())[1:]]))
        else:
            rs = rows()
            by = served([r["id"] for r in rs])
            emit([{"id": r["id"], "path": r["path"], "schema": r["schema"], "owner_only": r["owner_only"],
                   "entries": len(find_entries(r, by))} for r in rs], as_json, lambda x: "\t".join(str(v) for v in x.values()))
        return 0
    if cmd == "get" and 1 <= len(args) <= 2:
        row = known_json(args[0])
        by = served([row["id"]])
        if len(args) == 1:
            if row["id"] not in by["_rows"] or not (is_folder(row) or by["_rows"][row["id"]][0]):
                raise DataError(f"{row['id']}: not read")
            docs, ents = by["_rows"][row["id"]]
            emit(masked(row, ents if is_folder(row) else docs[0][1]), True)
            return 0
        ents = find_entries(row, by)
        if args[1] not in ents:
            refuse(f"entry of {args[0]}", args[1])
        emit(masked(row, ents[args[1]]), True)
        return 0
    if cmd == "search" and args:
        words, hits, rs = [w.casefold() for w in args], [], rows()
        by = served([r["id"] for r in rs])
        for r in rs:
            for k, e in find_entries(r, by).items():
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
