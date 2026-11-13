#!/usr/bin/env python3
"""Contract data (core contract items 1, 5, 6, 7), stdlib only: the index .stella/data-files.json, the schemas in
.stella/schemas/, and the cross-file rules. No provider, app, channel, role or feature name is in this file.
CLI: stella_data.py check [--json] [<id>]       validate every data file against its schema, then the cross-file rules.
                                                With an id: that file's problems plus every cross-file problem.
     stella_data.py validate <schema> <file>    one JSON file against .stella/schemas/<schema>.schema.json
     stella_data.py list [--json] [<id>]        the data files, or the entries of one
     stella_data.py get [--json] <id> [<entry>] a whole data file, or one entry by its id (alias) or global_id (secrets masked)
     stella_data.py search [--json] <words...>  entries whose values hold all the words; approved first. Finding grants nothing.
     stella_data.py ids-migrate <id>[/<file>] --out <file>  a candidate of that row's file (<id>/<file>.json for a folder row)
                                                with global_id and install_id added to every record that lacks them, nothing
                                                else changed; apply it with stella-apply.py apply. Never writes over a file.
     stella_data.py owner-only [--json]         the paths (JSON pointer, * for any item) each schema marks x-owner-only
Exit: 0 ok; 1 a problem (one line per problem or unreadable file, code STL-CFG-310) or an unknown id (STL-CFG-311, one
alert line); 2 usage. No command ends in a traceback.
The stack root is the parent of this file's folder, or STELLA_ROOT (a scratch root in tests; the alert line then goes under it).
Data files must be strict JSON: a repeated key, NaN and Infinity are errors. A problem message never prints the rejected value.
Schema subset: type, enum, const, properties, propertyNames, required, additionalProperties, items, minItems, maxItems,
uniqueItems, minLength, maxLength, pattern ($ matches only at the very end), minimum, maximum, $ref (#/$defs/x; sibling
keywords still apply), $defs, $schema, $id, title, description, x-one-document (true: the schema is one document by
nature, so a second file of it is refused), x-ref (an index row id: a string must be the id, the alias, or the global_id of a
record of that row's merged view) and x-owner-only (true: only the owner's path writes the field; owner-only lists them). Any
other keyword, or a wrong keyword value, is an error, never ignored.
A record is one entry of an index row with a list_key, or one file of a folder row: it carries global_id (a lower-case version
4 UUID, unique across every data file) and install_id (the UUID of the install that made it); its old id is its alias. Both
are required unless the install's one document says ids_required false (a migration in progress).
Every file an index row names is judged by every rule of its schema (all rows of a schema form one merged view, which is what
check judges and what the read commands serve). A file that fails its schema feeds no rule. A read is judged by exactly the
files its rules use (RULES, DEPS): it is served only when none of them has a problem, and its refusal names the first one."""
import datetime, functools, json, os, re, sys, uuid

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
            "pattern", "minimum", "maximum", "x-one-document", "x-ref", "x-owner-only"}
MAX_DEPTH = 64   # a data file nests far less; one limit makes `check` and the read commands agree on a deep object
TABLE, FRAME, NOROW = "role-table", "data-files", "schema:"   # members that are no index row: the role table, the index, a schema with no JSON row
MASK_LIMIT = 1024   # a value pattern never runs on a longer string (it is masked whole): a pattern's time grows with the length
UUID4 = r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"   # global_id
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"   # install_id: any UUID (a record may come from another install)
INSTALL = "install"   # the schema of the install's one document (install_id, ids_required)
CLI_LOGIN = ("cli", "quota_source", "concurrency_limit", "credential_store", "terms_ok")   # every cli-login entry has these, no api entry
STRICTEST = {"sync": "never", "store": "owner_asks", "hosted": "never", "context": "text_only"}   # a data class with no rule row
TYPES = {"object": dict, "array": list, "string": str, "integer": int, "number": (int, float), "boolean": bool, "null": type(None)}


class DataError(Exception):
    """A data file or path this tool cannot use; the message names it and never holds a data value."""


# ---- strict JSON loading, paths inside the root ----
def _pairs(pairs):
    d = {}
    for i, (k, v) in enumerate(pairs):
        if k in d:   # the position is no value: it locates the key also when its name is masked
            raise ValueError(f"repeated key {kname(k)} (key {i + 1} of its object)")
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


_closed = None


def closed_ids():
    """(device, inode) of every file this tool never opens: the role table's owner_settings and the file of every env row.
    A hard link or a link swapped during the run shares the identity, so jload compares it before a byte is read."""
    global _closed
    if _closed is None:
        _closed, paths = set(), set()   # empty while the index and the role table themselves are read
        try:
            idx = load(INDEX)
            for r in idx["files"]:
                try:
                    if r["format"] == "env":
                        paths.add(safe(r["path"]))
                except Exception:
                    pass
            try:
                paths |= owner_files(load(idx["role_table"])) or set()
            except DataError:
                pass
        except Exception:
            pass   # no readable index: check says so; then only the caller's own path rules hold
        ids = set()
        for p in paths:
            try:
                st = os.stat(p)
                ids.add((st.st_dev, st.st_ino))
            except OSError:
                pass
        _closed = ids
    return _closed


def jload(path, label=None):
    shut, ident = closed_ids(), lambda st: (st.st_dev, st.st_ino)
    no = DataError(f"{label or path}: is an owner setting of the role table or the file of an env row, which this tool never opens")
    try:
        if shut and ident(os.stat(path)) in shut:
            raise no
        with open(path, encoding="utf-8") as f:
            if shut and ident(os.fstat(f.fileno())) in shut:   # swapped between the stat and the open: nothing is read
                raise no
            doc = json.load(f, object_pairs_hook=_pairs, parse_constant=_bad_const, parse_float=_float, parse_int=_int)
        _sound(doc)
        return doc
    except (ValueError, RecursionError) as e:
        raise DataError(f"{label or path}: {e if isinstance(e, ValueError) else 'nested too deeply'}")
    except OSError as e:
        raise DataError(f"{label or path}: cannot be read ({type(e).__name__})")


def spelled(rel):
    """A path from the data as it is written: relative, no .. part; else a DataError."""
    if not isinstance(rel, str) or not rel or rel.startswith("/") or ".." in rel.replace("\\", "/").split("/"):
        raise DataError(f"{rel}: a path in the data must be relative and have no .. part")
    return rel


def safe(rel):
    """The absolute path of a path from the data: relative, no .. part, inside the root once symlinks are followed."""
    root, p = os.path.realpath(ROOT), os.path.realpath(os.path.join(ROOT, spelled(rel)))
    if p != root and not p.startswith(root.rstrip(os.sep) + os.sep):
        raise DataError(f"{rel}: leaves the stack root")
    return p


def linked(rel, at):
    """The refusal of a JSON row's path `rel` whose part `at` (absolute) is a symbolic link. One reason per case: a link that
    leaves the root is refused as leaving it (safe()); any other link is refused as a link, and the line also says so when it
    leads to a file this tool never opens. The target is looked at by stat only, never opened."""
    p, where = safe(rel), os.path.relpath(at, ROOT)
    try:
        st = os.stat(p)
        shut = (st.st_dev, st.st_ino) in closed_ids()
    except OSError:
        shut = False
    return DataError(f"{rel}: {'it' if where == os.path.normpath(rel) else where} is a symbolic link"   # short: a catalog line holds 200 characters
                     + (" (to an owner setting or an env row's file, never opened here)" if shut else "")
                     + "; a JSON row's path and entry files must not be a symbolic link")


def plain(rel):
    """The absolute path of a JSON row's path: as spelled, with no symbolic link in any part below the stack root (so it is
    inside the root without following anything). A link is that row's own fault (linked()), whatever it points to."""
    a = ROOT
    for part in os.path.normpath(spelled(rel)).split(os.sep):
        a = os.path.join(a, part)
        if os.path.islink(a):
            raise linked(rel, a)
    return os.path.normpath(a)


def load(rel):
    return jload(safe(rel), rel)


def folder_row(row):
    """What an index row IS, the one rule (this tool and the apply tool both call it): a row is a folder of entries when its
    format is json and its path does not end in the format's own suffix (.json); every other row is one file. Nothing else
    decides it: not the list key, not what is on the disk (kind_problem() reports a disk that disagrees)."""
    return row["format"] == "json" and not row["path"].endswith("." + row["format"])


def kind_problem(row, p):
    """None, or how the disk at p (the row's path) disagrees with folder_row(row), and the repair. JSON rows only."""
    if row["format"] != "json":
        return None
    sfx, isdir = "." + row["format"], os.path.isdir(p)
    if folder_row(row) and not isdir:
        if not os.path.lexists(p):
            return f"{row['path']}: the folder does not exist (a json row whose path does not end in {sfx} is a folder of entries)"
        return f"{row['path']} is one file, but a json row whose path does not end in {sfx} is a folder of entries: rename the path in the index so it ends in {sfx}"
    if isdir and not folder_row(row):
        return f"{row['path']} is a folder, but a json row whose path ends in {sfx} is one file: rename the path in the index so it does not end in {sfx}"
    return None


def files_of(row):
    """[(relative path, absolute path)]: the file a row names, or every *.json of a folder row's folder (folder_row() says which;
    a path whose disk disagrees is returned as itself, so it is still compared with the other rows, and layout() closes it).
    A JSON row's path and each entry file must be free of symbolic links (plain()); a row this tool never opens (env) is found
    by where it resolves, inside the root (safe())."""
    if row["format"] != "json":
        return [(row["path"], safe(row["path"]))]
    p = plain(row["path"])
    if not folder_row(row) or not os.path.isdir(p):
        return [(row["path"], p)]
    out = []
    for n in sorted(n for n in os.listdir(p) if n.endswith(".json") and not n.startswith(".")):   # by name: never a glob
        a = os.path.join(p, n)
        if os.path.islink(a):
            raise linked(os.path.relpath(a, ROOT), a)
        out.append((os.path.relpath(a, ROOT), a))
    return out


def owner_files(table):
    """The resolved paths of the role table's owner settings, or None when the table does not say (then no JSON row is opened)."""
    try:
        return {safe(f) for f in table["owner_settings"]}
    except Exception:
        return None


def layout(rs, owner):
    """Where every row's files are, and which rows may be opened: ([(row id, problem)], [(row, files)] of the JSON rows that
    may be opened). A row is charged for its own fault only. Which rule a case falls under (never two for one fault):
    - a JSON row whose path, a folder in it below the root, or an entry file of its folder is a symbolic link: THAT row is
      refused as a link (plain(), linked()); it is compared with no other row, so no other row gets a line or is closed;
    - two rows that SPELL the same file (./x and x, a folder row and a row on one of its files; an env row is taken where it
      resolves): each is refused as "named by more than one index row", and neither is opened;
    - a JSON row whose disk disagrees with its kind (kind_problem()): that row, and it is not opened;
    - a row on an owner setting must be an env row and owner_only, and is never opened."""
    probs, named, by_file, shut = [], [], {}, set()
    for r in rs:
        try:
            fs = files_of(r)
        except DataError as e:
            probs.append((r["id"], str(e)))
            continue
        named.append((r, fs))
        for _, a in fs:
            by_file.setdefault(a, []).append(r)
        bad = kind_problem(r, fs[0][1]) if fs and fs[0][0] == r["path"] else None   # a listed folder agrees with its kind
        if bad:
            probs.append((r["id"], bad))
            shut.add(id(r))
    if owner is None:   # shortcut: with no readable role table only the env rows' files are kept closed; check reports the table
        probs.append((TABLE, "the role table's owner_settings cannot be read, so only the files of env rows are kept closed"))
        owner = {a for r, fs in named if r["format"] == "env" for _, a in fs}
    for a, rr in by_file.items():
        rel = os.path.relpath(a, ROOT)
        if len(rr) > 1:
            shut |= {id(r) for r in rr}
            probs += [(r["id"], f"{rel} is named by more than one index row ({', '.join(x['id'] for x in rr)}), so none of them is opened") for r in rr]
        for r in rr if owner and a in owner else []:
            shut.add(id(r))
            if r["format"] != "env" or not r["owner_only"]:
                probs.append((r["id"], f"{rel} is an owner setting of the role table: its row must be format env and owner_only, and it is never opened here"))
    return probs, [(r, fs) for r, fs in named if r["format"] == "json" and id(r) not in shut]


_pats = "unread"


CATALOG = "connections"   # the schema whose entries carry the value patterns (redaction_patterns) that mask every read


def value_pats():
    """The value patterns of the connections catalog (redaction_patterns of every entry of every file of every row of its
    schema), compiled. Every pattern a file holds counts, also in a file check refuses for another field (one more pattern
    never prints a value). None when the patterns cannot be read: no JSON row of the catalog, a row of it that is not opened,
    a file that does not load, entries or a redaction_patterns that are not what the schema says, a pattern that does not
    compile. None means every string is masked (fail closed): a read keeps working (numbers, and key names the schema fixes,
    are shown) and never prints an unmasked value; check says what is wrong with the catalog. While the patterns are being
    read the answer is None too."""
    global _pats
    if _pats == "unread":
        _pats, out, n = None, [], 0
        try:
            idx = load(INDEX)
            if validate_doc(idx, schema_of("data-files")):
                raise DataError("index")
            try:
                table = load(idx["role_table"])
            except DataError:
                table = None
            mine = [r for r in idx["files"] if r["format"] == "json" and r["schema"] == CATALOG]
            opened = [(r, fs) for r, fs in layout(idx["files"], owner_files(table))[1] if r["schema"] == CATALOG]
            if mine and len(opened) == len(mine):
                for r, fs in opened:
                    for rel, _ in fs:
                        n += 1
                        for _, e in file_entries(r, rel, load(rel)):
                            ps = e.get("redaction_patterns", [])   # null, false, 0, "" and {} are not "no patterns"
                            if not isinstance(ps, list) or not all(isinstance(x, str) for x in ps):
                                raise DataError(rel)
                            out += [re.compile(x) for x in ps]
                _pats = out if n else None
        except Exception:
            _pats = None
    return _pats


def hidden(text):
    """True when the text is to be masked: a value pattern matches it, it is longer than MASK_LIMIT (no pattern runs on it),
    or the patterns cannot be read."""
    v = value_pats()
    return v is None or len(text) > MASK_LIMIT or any(p.search(text) for p in v)


def kname(k):
    """A key name taken from a file, as a problem line shows it: quoted, unless a value pattern matches it."""
    return "a masked key" if hidden(k) else repr(k)


def idn(k, quote=False):
    """An entry id taken from a file, as a problem line shows it: itself (quoted if asked), unless a value pattern matches it."""
    return "a masked id" if not isinstance(k, str) or hidden(k) else repr(k) if quote else k


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
    for k in ("uniqueItems", "x-one-document", "x-owner-only"):
        if k in s and not isinstance(s[k], bool):
            bad(k, "must be true or false")
    for k in ("title", "description", "$schema", "$id"):
        if k in s and not isinstance(s[k], str):
            bad(k, "must be a string")
    if "x-ref" in s and not (isinstance(s["x-ref"], str) and re.fullmatch(r"[a-z0-9][a-z0-9._:-]*", s["x-ref"])):
        bad("x-ref", "must be the id of an index row")
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


def check_value(v, s, defs, p, errs, refs=None):
    """Problems of v against schema s into errs; with a list refs, also every x-ref string as (path, value, index row id)."""
    if "$ref" in s:
        check_value(v, defs[s["$ref"].rsplit("/", 1)[-1]], defs, p, errs, refs)   # the siblings of $ref apply below
    t = s.get("type")
    if t is not None:
        ts = [t] if isinstance(t, str) else t
        if not any(type_ok(v, x) for x in ts):
            return errs.append(f"{p}: expected {'/'.join(ts)}, got {desc(v)}")
    if refs is not None and isinstance(v, str) and "x-ref" in s:
        refs.append((p, v, s["x-ref"]))
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
            check_value(x, s.get("items", {}), defs, f"{p}[{i}]", errs, refs)
    if isinstance(v, dict):
        errs += [f"{p}: missing {k}" for k in s.get("required", []) if k not in v]
        props, extra = s.get("properties", {}), s.get("additionalProperties", True)
        for k, x in v.items():
            if "propertyNames" in s:
                check_value(k, s["propertyNames"], defs, f"{p}.<name of {desc(k)}>", errs)
            if k in props:
                check_value(x, props[k], defs, f"{p}.{k}", errs, refs)
            elif extra is False:
                errs.append(f"{p}: {kname(k)} is not allowed")
            elif isinstance(extra, dict):
                check_value(x, extra, defs, f"{p}.{'<a masked key>' if hidden(k) else k}", errs, refs)


def validate_doc(doc, schema, refs=None):
    errs = lint_schema(schema)
    if not errs:
        check_value(doc, schema, schema.get("$defs", {}), "$", errs, refs)
    return errs


def ref_rows(s):
    """The index row ids the x-ref keywords of a schema (or any part of one) name."""
    if isinstance(s, dict):
        return ({s["x-ref"]} if isinstance(s.get("x-ref"), str) else set()).union(*map(ref_rows, s.values()))
    return set().union(*map(ref_rows, s)) if isinstance(s, list) else set()


def entry(ents, k):
    """The entry of {entry id: entry} whose id (its alias) or global_id is k; None when there is none."""
    return ents[k] if k in ents else next((e for e in ents.values() if e.get("global_id") == k), None)


def ref_problems(refs, by, rs, refused=()):
    """[(kind, line)] for the x-ref values of one document: kind "row" when the schema names no JSON row of the index or the
    row cannot be read, "id" when the value is no id or global_id of a record of that row's merged view (never the value)."""
    out = []
    for p, v, target in refs:
        row = next((r for r in rs if r["id"] == target and r["format"] == "json"), None)
        if row is None:
            out.append(("row", f"{p}: x-ref names {target!r}, which is no JSON row of the index"))
        elif target in refused or target not in by["_rows"]:
            out.append(("row", f"{p}: cannot be checked, {target} is refused"))
        elif entry(by.get(row["schema"], {}), v) is None:
            out.append(("id", f"{p} ({desc(v)}) is not an id or global_id of a record of {target}"))
    return out


def owner_paths(s, defs, at="", seen=()):
    """The paths (JSON pointer; * for any array item or map value) of what a schema marks x-owner-only, through $ref too."""
    if not isinstance(s, dict):
        return []
    out = [at or "/"] if s.get("x-owner-only") is True else []
    r = s.get("$ref")
    if isinstance(r, str) and r not in seen:   # a definition already on this path is not walked again (a tree of itself)
        out += owner_paths(defs.get(r.rsplit("/", 1)[-1]), defs, at, seen + (r,))
    for k, sub in (s.get("properties") or {}).items():
        out += owner_paths(sub, defs, f"{at}/{k.replace('~', '~0').replace('/', '~1')}", seen)
    for k in ("items", "additionalProperties"):
        out += owner_paths(s.get(k), defs, f"{at}/*", seen)
    return list(dict.fromkeys(out))


# ---- the index and the entries ----
def schema_of(name):
    """The schema of that name: the file <name>.schema.json in the schemas folder, which must not be a symbolic link (a schema's
    identity is its name there; a link would give one schema two names, and the rules key on the name)."""
    rel = f"{SCHEMAS}/{name}.schema.json"
    if os.path.islink(os.path.join(ROOT, rel)):
        raise DataError(f"{rel}: a schema file must not be a symbolic link")
    return load(rel)


def checked(doc, rel, schema):
    """doc if it passes its schema, else a DataError naming the file. The read commands of this tool also run the cross-file
    rules on what they serve (served()), so they never serve data `check` refuses."""
    errs = validate_doc(doc, schema_of(schema))
    if errs:
        raise DataError(f"{rel}: {errs[0]}" + (f" (and {len(errs) - 1} more)" if len(errs) > 1 else ""))
    return doc


def rows():
    return checked(load(INDEX), INDEX, "data-files")["files"]


def is_folder(row):
    return folder_row(row)


def has_records(row):
    """A row whose entries are records (each with global_id and install_id): a JSON row with a list key, or a folder row."""
    return row["format"] == "json" and (row["list_key"] is not None or folder_row(row))


def ids_required(opened):
    """False only while the install's one document says ids_required false (a migration in progress); anything else, also an
    install document that is missing, refused or not valid, is True (fail closed). opened: layout()'s rows that may be opened."""
    docs = [rel for r, fs in opened if r["schema"] == INSTALL for rel, _ in fs]
    try:
        return len(docs) != 1 or checked(load(docs[0]), docs[0], INSTALL)["ids_required"] is not False
    except Exception:
        return True


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
            raise DataError(f"{rel}: entry {idn(k)} is not an object")
    return pairs


# ---- check ----
def why(e):
    return str(e) if isinstance(e, (DataError, ValueError)) else type(e).__name__


def policy_allows(pol, prov):
    if pol.get("private") and prov["data_policy"].get("hosted"):   # a private project never uses a hosted connection, whatever its mode
        return False
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
        return validate_doc(doc, schema_of("roles")) + roles.validate(doc, ROOT)
    except DataError:
        raise
    except Exception as e:
        return [f"bin/roles.py could not validate the table ({type(e).__name__})"]


def nm(v, known, path):
    """A value from the file under check as a problem line may show it: an id that exists in the data (and that no value pattern
    matches). Any other value is not printed (it may be a pasted secret): its place and JSON type are."""
    return repr(v) if isinstance(v, str) and v in known and not hidden(v) else f"the value at {path} ({desc(v)})"


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


# The cross-file rules. Each gets c = {"by": schema -> {entry id: entry} (the merged view), "whole": schema -> [(row id, parsed
# file)], "src": schema -> {entry id: row id}, "P": P(row id, problem), "rs": the index rows, "ids": the index row ids, "table":
# the role table} and reads only the schemas its row in RULES names (TABLE is the role table). Only files that passed
# their schema reach it. D(c, schema, entry id) is the row that holds an entry, so a problem is charged to that row.
def D(c, sch, k=None):
    return c["src"].get(sch, {}).get(k) or next((rid for rid, _ in c["whole"].get(sch, [])), sch)


def rule_policy(c):
    """The data policy and the catalog against each other: providers it names exist, classes exist, local providers are local; a hosted
    connection takes no class that never reaches a cloud store and no private project names it; an input source's subkind is a class."""
    conn, pols, P = c["by"].get("connections", {}), c["whole"].get("data-policy", []), c["P"]
    if not pols:   # a folder row with no file: nothing to judge against (the assignments say so)
        return
    classes = set.intersection(*(set(d["data_classes"]) for _, d in pols))
    local = set.intersection(*(set(d["local_hosts"]) for _, d in pols))
    # what a hosted connection (the provider's cloud keeps it) may never take: a class never synced or never hosted, and the
    # class of a never_cloud record kind (secrets, vault content)
    barred = {k for _, d in pols for k in d["data_classes"] if class_rule(d, k)["sync"] == "never" or class_rule(d, k)["hosted"] == "never"} \
        | {kd["data_class"] for _, d in pols for kd in d["record_kinds"].values() if kd.get("never_cloud") and "data_class" in kd}
    for rid, pol in pols:
        for proj, p in [("default", pol["default"])] + list(pol["projects"].items()):
            for i, prov in enumerate(p["allowed_providers"]):
                if prov not in conn:
                    P(rid, f"{'default' if proj == 'default' else kname(proj)}: allowed_providers[{i}] ({desc(prov)}) is not in the connections catalog")
                elif p.get("private") and conn[prov]["data_policy"].get("hosted"):
                    P(rid, f"{kname(proj)}: allowed_providers[{i}] {idn(prov, True)} is hosted, and a private project never uses a hosted connection")
    for c_ in conn.values():
        hosted = c_["data_policy"].get("hosted")
        for i, k in enumerate(c_["data_policy"]["data_classes_allowed"]):
            if k not in classes:
                P(D(c, "connections", c_["id"]), f"{idn(c_['id'])}: data_classes_allowed[{i}] ({desc(k)}) is not in data-policy data_classes")
            elif hosted and k in barred:
                P(D(c, "connections", c_["id"]), f"{idn(c_['id'])}: data_classes_allowed[{i}] {idn(k, True)} never reaches a cloud store, and this connection is hosted")
        if c_["kind"] == "input_source" and c_["subkind"] not in classes:   # an input source's subkind is the class of what it produces
            P(D(c, "connections", c_["id"]), f"{idn(c_['id'])}: an input source's subkind ({desc(c_['subkind'])}) is not in data-policy data_classes")
        hosts = [h["host"] for h in c_["hosts"]]
        if c_["kind"] == "provider" and c_["locality"] == "local" and (not hosts or not set(hosts) <= local):
            P(D(c, "connections", c_["id"]), f"{idn(c_['id'])}: locality is local, but it lists no host or a host outside the data policy local_hosts")


def class_rule(pol, k):
    """The rules of data class k in one data policy; a class with no rule row gets the most restrictive (fail closed)."""
    return pol["class_rules"].get(k, STRICTEST)


def rule_sync(c):
    """Sync classes (item 8) and data-class rules (item 9): every record kind names a known sync class (and a known data class);
    a kind that never reaches a cloud store (never_cloud, or a data class whose rule is sync never) and a private or local_only
    project (its own sync class, else its row's kind's) have a sync class whose cloud is false; rule rows and grants name known
    classes; every index row with records names a kind of the data policy."""
    P, pols = c["P"], c["whole"].get("data-policy", [])
    for rid, pol in pols:
        sc, classes, kinds = {x["id"]: x["cloud"] for x in pol["sync_classes"]}, set(pol["data_classes"]), pol["record_kinds"]
        if len(sc) != len(pol["sync_classes"]):
            P(rid, "sync_classes: an id is listed twice")
        for k in pol["class_rules"]:
            if k not in classes:
                P(rid, f"class_rules: {kname(k)} is not in data_classes")
        for k, kd in kinds.items():
            w = f"record kind {kname(k)}"
            if kd["sync_class"] not in sc:
                P(rid, f"{w}: sync_class ({desc(kd['sync_class'])}) is not in sync_classes")
            if "data_class" in kd and kd["data_class"] not in classes:
                P(rid, f"{w}: data_class ({desc(kd['data_class'])}) is not in data_classes")
            if sc.get(kd["sync_class"]) and (kd.get("never_cloud") or "data_class" in kd and class_rule(pol, kd["data_class"])["sync"] == "never"):
                P(rid, f"{w}: sync class {idn(kd['sync_class'], True)} is a cloud class, but this kind never reaches a cloud store (never_cloud, or a data class that is never synced)")
        pk = next((r.get("record_kind") for r in c["rs"] if r["id"] == rid), None)
        for name, p in pol["projects"].items():
            own = p.get("sync_class")
            if own is not None and own not in sc:
                P(rid, f"project {kname(name)}: sync_class ({desc(own)}) is not in sync_classes")
            eff = own if own is not None else kinds.get(pk, {}).get("sync_class")
            if sc.get(eff) and (p.get("private") or p["mode"] == "local_only"):
                P(rid, f"project {kname(name)}: a private or local_only project never reaches a cloud store, but its sync class {idn(eff, True)} is a cloud class")
        for i, g in enumerate(pol["privacy_grants"]):
            if g["data_class"] not in classes:
                P(rid, f"privacy_grants[{i}].data_class ({desc(g['data_class'])}) is not in data_classes")
    known = set.intersection(*(set(d["record_kinds"]) for _, d in pols)) if pols else set()
    for r in c["rs"]:
        if has_records(r) and isinstance(r.get("record_kind"), str) and r["record_kind"] not in known:
            P(r["id"], f"record_kind ({desc(r['record_kind'])}) is not a kind of the data policy's record_kinds")


def rule_role_classes(c):
    """Every data class a role of the role table handles is one the data policy defines."""
    pols = c["whole"].get("data-policy", [])
    classes = set.intersection(*(set(d["data_classes"]) for _, d in pols)) if pols else set()
    for m in class_problems(c["table"], classes):
        c["P"](TABLE, m)


def rule_assignments(c):
    """Role assignments against the role table, the catalog, the effort modes and the data policy."""
    P, table, conn, pols = c["P"], c["table"], c["by"].get("connections", {}), c["whole"].get("data-policy", [])
    allroles = table["roles"]
    roles = set(allroles) - {table["fallback_role"]}   # the fail-closed row is no role to assign or allow
    projects = {k: v for _, d in pols for k, v in d["projects"].items()}
    seen, cards = {}, {}
    for rid, ra in c["whole"].get("role-assignments", []):
        for a in ra["assignments"]:
            sc, lvl, aid = a["scope"], a["scope"]["level"], idn(a["id"])
            want = {"global": (), "project": ("project",), "card": ("project", "card")}[lvl]
            for k in ("project", "card"):
                if (k in want) != (k in sc):
                    P(rid, f"{aid}: scope.level {lvl} {'needs' if k in want else 'has no'} {k}")
            key = (lvl, sc.get("project"), sc.get("card"), a["role"], a["effort_mode"])
            if key in seen:
                P(rid, f"{aid}: same scope, role and effort mode as {idn(seen[key])}")
            seen[key] = a["id"]
            if "card" in sc:
                if cards.setdefault(sc["card"], (sc.get("project"), a["id"]))[0] != sc.get("project"):
                    P(rid, f"{aid}: its card is also filed under another project, in {idn(cards[sc['card']][1])}")
            if a["role"] not in roles:
                P(rid, f"{aid}: {nm(a['role'], allroles, 'role')} is not an assignable role in the role table")
            mode = ra["effort_modes"].get(a["effort_mode"])
            if mode is None:
                P(rid, f"{aid}: effort_mode ({desc(a['effort_mode'])}) is not defined")
            if not pols:
                P(rid, f"{aid}: cannot be judged, the data policy has no file")
            proj = sc.get("project") if sc.get("project") in projects else None
            policies = [projects[proj]] if proj else [d["default"] for _, d in pols]
            need = allroles.get(a["role"], {}).get("requirements", {}).get("allowed_data_classes", [])
            for i, ch in enumerate(a["chain"]):
                prov, w = conn.get(ch["provider"]), f"{aid}: chain[{i}]"
                if prov is None or prov["kind"] != "provider":
                    P(rid, f"{w}.provider ({desc(ch['provider'])}) is not a provider in the connections catalog")
                    continue
                pn = idn(ch["provider"])
                if not prov["enabled"]:
                    P(rid, f"{w}: {pn} is switched off")
                if ch["model"] not in [m["id"] for m in prov["models"]]:
                    P(rid, f"{w}.model ({desc(ch['model'])}) is not listed for {pn}")
                if mode and prov["locality"] not in mode["allowed_localities"]:
                    P(rid, f"{w}: {pn} is {prov['locality']}, which effort mode {idn(a['effort_mode'])} forbids")
                if not all(policy_allows(p, prov) for p in policies):
                    P(rid, f"{w}: {pn} is not allowed by the data policy for {idn(proj) if proj else 'the default'} (an override never widens the policy)")
                if any(k not in prov["data_policy"]["data_classes_allowed"] for k in need):   # an empty list allows no class
                    P(rid, f"{w}: {pn} does not allow every data class that role {idn(a['role'])} handles")
                if a["role"] not in prov.get("allowed_roles", []):   # an empty list allows no role
                    P(rid, f"{w}: {pn} does not list role {nm(a['role'], allroles, 'role')} in its allowed_roles")


def rule_features(c):
    """depends_on: no missing target, no cycle, an on feature depends only on on features."""
    feats, P = c["by"].get("features", {}), c["P"]
    for f in feats.values():
        for i, d in enumerate(f["depends_on"]):
            if d not in feats:
                P(D(c, "features", f["id"]), f"{idn(f['id'])}: depends_on[{i}] ({desc(d)}) is not a feature")
            elif f["status"] == "on" and feats[d]["status"] != "on":
                P(D(c, "features", f["id"]), f"{idn(f['id'])} is on but depends on {idn(d)}, which is {feats[d]['status']}")
    for start in feats:   # a cycle: walking depends_on from a feature gets back to it
        seen, todo = set(), [d for d in feats[start]["depends_on"] if d in feats]
        while todo:
            n = todo.pop()
            if n == start:
                P(D(c, "features", start), f"{idn(start)} depends on itself through a cycle")
                break
            if n not in seen:
                seen.add(n)
                todo += [d for d in feats[n]["depends_on"] if d in feats]


def rule_allowed_roles(sch):
    """allowed_roles of every entry of one schema against the role table."""
    def rule(c):
        roles = set(c["table"]["roles"]) - {c["table"]["fallback_role"]}
        for k, e in c["by"].get(sch, {}).items():
            for i, r in enumerate(e.get("allowed_roles", [])):
                if r not in roles:
                    c["P"](D(c, sch, k), f"{idn(e['id'])}: {nm(r, c['table']['roles'], f'allowed_roles[{i}]')} is not an assignable role in the role table")
    return rule


def rule_extensions_on(c):
    for k, e in c["by"].get("extension", {}).items():
        if e["enabled"] and e["status"] != "approved":
            c["P"](D(c, "extension", k), f"{idn(e['id'])}: switched on while its status is {e['status']}; only an approved extension may be on")


def rule_catalog(c):
    """A provider or channel states allowed_roles and risk_class; the fields of each type, aggregator, integration aggregator, realtime
    and input source go with their kind (F1b D5, what the schema subset cannot say); every redaction pattern compiles."""
    for k, e in c["by"].get("connections", {}).items():
        say_ = lambda m: c["P"](D(c, "connections", k), f"{idn(e['id'])}: {m}")
        if e["kind"] != "app" and not {"allowed_roles", "risk_class"} <= set(e):
            say_("a provider or channel states its allowed_roles and risk_class")
        cli = e["type"] == "cli-login"
        for f in CLI_LOGIN:
            if cli and f not in e:
                say_(f"a cli-login entry names its {f}")
            elif not cli and f in e:
                say_(f"{f} is a field of a cli-login entry, and this one is {e['type']}")
        if cli and e["kind"] not in ("provider", "app"):
            say_("only a provider or an app may be cli-login")
        if e.get("aggregator") and (cli or e["kind"] != "provider"):
            say_("an aggregator is an api provider")
        if e.get("aggregator") and "broker_entries" not in e:
            say_("an aggregator names its broker_entries (names only)")
        if "broker_entries" in e and not e.get("aggregator"):
            say_("broker_entries belong to an aggregator only")
        if e.get("integration_aggregator") and e["kind"] != "app":
            say_("only an app may be an integration_aggregator")
        if e.get("integration_aggregator") and not e["data_policy"].get("hosted"):
            say_("an integration_aggregator keeps its tokens in its provider's cloud: its data_policy says hosted true")
        if "realtime" in e and e["kind"] != "provider":
            say_("realtime is for a provider (its models take live audio or video)")
        if e["locality"] == "hub" and e["kind"] != "input_source":
            say_("locality hub is for an input source only")
        if e["kind"] == "input_source" and e["locality"] == "cloud":
            say_("an input source's locality is local or hub")
        for p in e.get("redaction_patterns", []):
            try:
                re.compile(p)
            except re.error:   # this fault makes the patterns unreadable, so the id is masked: the position (no value) locates the entry
                c["P"](D(c, "connections", k), f"{idn(e['id'])} (entry {c['by']['_at']['connections'][k]} of its file): a redaction pattern is not a regular expression")


def rule_hosts(c):
    for k, h in c["by"].get("approved-hosts", {}).items():
        a, x = when(h, "approved_at"), when(h, "expires_at")
        for f, v in (("approved_at", a), ("expires_at", x)):
            if v is False:
                c["P"](D(c, "approved-hosts", k), f"{idn(k)}: {f} is not a real date")
        if a and x and x <= a:
            c["P"](D(c, "approved-hosts", k), f"{idn(k)}: expires_at is not after approved_at")


def rule_settings(c):
    """A setting's store (an index row), its code (in the alert catalog), its default and validation, its store key."""
    sets = c["by"].get("settings", {})
    codes = alert_catalog.catalog() if sets else {}
    for k, s in sets.items():
        say_ = lambda m: c["P"](D(c, "settings", k), f"{idn(s['key'])}: {m}")
        if s["store"]["data"] not in c["ids"]:
            say_(f"store.data ({desc(s['store']['data'])}) is not a data file in the index")
        if s["code"] not in codes:
            say_(f"code ({desc(s['code'])}) is not in the alert catalog")
        for m in setting_problems(s) + store_problems(s, c["rs"]):
            say_(m)


# (name, the schemas whose rows it judges, the schemas it reads, the rule). A read of a row of schema S depends on DEPS[S]: S and
# every schema a rule that judges S reads. The index is the frame of every rule (its row ids, its redact_keys), not one of them.
RULES = [("data policy and catalog", ("data-policy", "connections"), ("data-policy", "connections"), rule_policy),
         ("sync classes and record kinds", ("data-policy",), ("data-policy",), rule_sync),
         ("role data classes", (TABLE,), (TABLE, "data-policy"), rule_role_classes),
         ("role assignments", ("role-assignments",), ("role-assignments", "connections", "data-policy", TABLE), rule_assignments),
         ("features", ("features",), ("features",), rule_features),
         *((f"{s} allowed_roles", (s,), (s, TABLE), rule_allowed_roles(s)) for s in ("capabilities", "extension", "connections")),
         ("extensions switched on", ("extension",), ("extension",), rule_extensions_on),
         ("catalog shape", ("connections",), ("connections",), rule_catalog),
         ("approved hosts", ("approved-hosts",), ("approved-hosts",), rule_hosts),
         ("settings", ("settings",), ("settings",), rule_settings)]
DEPS = {}
for _n, _judges, _reads, _f in RULES:
    for _s in _judges:
        DEPS.setdefault(_s, {_s}).update(_reads)
NEEDED = {s for _, _, rd, _ in RULES for s in rd} - {TABLE}   # schemas the cross-file rules read


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


def plan(rs, reads):
    """What a read of the rows `reads` needs: (the schemas to open, the rules to run, the members it depends on). Members are row
    ids, TABLE (the role table), FRAME (the index) and NOROW + a schema name (a schema with no JSON row). A rule runs when it reads a
    member: a rule that raises is a problem of every row it read."""
    dep = set().union(*(DEPS.get(r["schema"], {r["schema"]}) for r in rs if r["id"] in reads and r["schema"]))
    todo = list(dep)
    while todo:   # the rows an x-ref of a schema it depends on names, and theirs
        sch = todo.pop()
        try:
            names = set() if sch == TABLE else ref_rows(schema_of(sch))
        except Exception:
            continue   # an unreadable schema is a problem of its own rows
        for r in rs:
            if r["id"] in names and r["schema"] and r["schema"] not in dep:
                dep.add(r["schema"])
                todo.append(r["schema"])
    run = [R for R in RULES if set(R[2]) & dep]
    members = set(reads) | {FRAME} | {r["id"] for r in rs if r["schema"] in dep} | {NOROW + s for s in dep - {TABLE}}
    return dep | {s for R in run for s in R[2]}, run, members | ({TABLE} if TABLE in dep else set())


def judge(reads=None):
    """(problems, view, cut). problems: [(data id, problem, members)] over every data file in the index; members are what the
    problem belongs to (see plan()). view: by schema name the merged {entry id: entry} of the files that passed their schema,
    plus "_rows": {row id: ([(rel, doc)], {entry id: entry})}, "_src", "_ids". reads: the row ids a read command serves; then
    only what plan() names is opened and run. cut: where the per-file problems start and end, the ids of the index's own rows,
    and the members a read depends on."""
    probs = []

    def P(d, m, members=None):
        probs.append((d, m, frozenset(members or (d,))))
    try:
        idx = load(INDEX)
        errs = validate_doc(idx, schema_of("data-files"))
        if errs:
            return [(FRAME, e, frozenset({FRAME})) for e in errs], None, {}
        rs = idx["files"]
    except Exception as e:
        return [(FRAME, why(e) if isinstance(e, DataError) else f"{INDEX}: {why(e)}", frozenset({FRAME}))], None, {}
    ids = [r["id"] for r in rs]
    by = {"_ids": ids, "_src": {}, "_rows": {}, "_at": {}}
    if len(set(ids)) != len(rs):
        P(FRAME, "an id is listed twice in the index")
    own = [r for r in rs if r["format"] == "json" and os.path.normpath(r["path"]) == INDEX]   # as spelled: a link to the index is the linking row's fault
    if not own or not all(r["owner_only"] for r in own):
        P(FRAME, "the index row that describes the index must exist and be owner_only")
    for r in rs:   # a row id that is one of this tool's own member names would take that member's problems, and give it its own
        if r["id"] == TABLE or r["id"].startswith(NOROW) or (r["id"] == FRAME and r not in own):
            P(FRAME, f"row id {r['id']} is a name this tool keeps for the role table, the index or a schema with no row: give the row another id")
    for r in rs:
        for i, p in enumerate(r["redact_keys"]):
            try:
                re.compile(p)
            except re.error:
                P(r["id"], f"redact_keys[{i}] is not a regular expression")
        if has_records(r) and not r.get("record_kind"):
            P(r["id"], "a row with records names its record_kind (a kind of the data policy's record_kinds)")
    for rel in [idx[k] for k in ("event_log", "backup_dir", "applied_state", "role_table")]:
        try:
            safe(rel)
        except DataError as e:
            P(FRAME, str(e))
    try:
        table = load(idx["role_table"])
    except Exception:
        table = None   # reported below as a role-table problem
    found, opened = layout(rs, owner_files(table))
    for d, m in found:
        P(d, m)
    refused = {d for d, _ in found}   # rows whose files feed no rule
    head = len(probs)
    want, run, members = plan(rs, reads) if reads is not None else (None, RULES, None)
    loaded, nfiles, good, onedoc, need_ids = [], {}, [], {}, ids_required(opened)
    for r, fs in opened:
        if want is not None and r["id"] not in reads and r["schema"] not in want:
            continue
        loaded.append(r)
        try:
            if not r["schema"]:
                raise DataError(f"{r['path']}: no schema named")
            sch = schema_of(r["schema"])
        except Exception as e:
            P(r["id"], why(e) if isinstance(e, DataError) else f"{r['path']}: {why(e)}")
            refused.add(r["id"])
            continue
        onedoc[r["schema"]] = sch.get("x-one-document") is True
        for rel, _ in fs:
            nfiles.setdefault(r["schema"], []).append((r, rel))
            try:
                d, refs = load(rel), []
                errs = ([] if isinstance(d, dict) and "schema_version" in d else ["schema_version is missing"]) + validate_doc(d, sch, refs)
                for e in errs:
                    P(r["id"], f"{rel}: {e}")
                if not errs:
                    good.append((r, rel, d, file_entries(r, rel, d), refs))
            except Exception as e:
                P(r["id"], why(e) if isinstance(e, DataError) else f"{rel}: {why(e)}")
                errs = [e]
            if errs:
                refused.add(r["id"])
    for name, fl in nfiles.items():   # one document: a second file makes every file of the schema unusable, whatever the order
        if onedoc.get(name) and len(fl) > 1:
            for r, rel in fl:
                P(r["id"], f"{rel}: schema {name} is one document, and {len(fl)} files hold it ({', '.join(x for _, x in fl)}); none is used")
                refused.add(r["id"])
    whole, where = {}, {}
    for r in loaded:
        if r["id"] not in refused:
            by["_rows"][r["id"]] = ([], {})
    gids = {}   # global_id -> [(row id, file, entry id)]: one global_id in two records is a problem of every row that holds it
    for r, rel, d, pairs, _ in good:
        if r["id"] in refused:
            continue
        name, (docs, ents) = r["schema"], by["_rows"][r["id"]]
        whole.setdefault(name, []).append((r["id"], d))
        docs.append((rel, d))
        for n, (k, e) in enumerate(pairs):
            for f, pat in (("global_id", UUID4), ("install_id", UUID)) if has_records(r) else ():
                v = e.get(f)
                if (v is None and need_ids) or not (v is None or isinstance(v, str) and re.fullmatch(pat, v)):
                    P(r["id"], f"{rel}: entry {idn(k, True)}: {f} is " + ("missing" if v is None else "not a lower-case UUID" + (" of version 4" if f == "global_id" else "")))
            if has_records(r) and isinstance(e.get("global_id"), str):
                gids.setdefault(e["global_id"], []).append((r["id"], rel, k, name))
            if k in where.setdefault(name, {}):
                P(r["id"], f"{rel}: duplicate entry id {idn(k, True)}" + ("" if where[name][k] == rel else f", also in {where[name][k]}"))
                continue
            where[name][k] = rel
            by.setdefault(name, {})[k] = ents[k] = e
            by["_src"].setdefault(name, {})[k] = r["id"]
            by["_at"].setdefault(name, {})[k] = n + 1
    for g, at in gids.items():
        for x in at:
            if len(at) > 1:
                P(x[0], f"{x[1]}: entry {idn(x[2], True)}: its global_id is also the global_id of "
                        + ", ".join(f"entry {idn(y[2], True)} of {y[1]}" for y in at if y is not x))
            if g in by.get(x[3], {}) and by[x[3]][g].get("global_id") != g:   # an alias that is another record's global_id: a read by it is ambiguous
                P(x[0], f"{x[1]}: entry {idn(x[2], True)}: its global_id is the id of another entry of its schema")
    for r, rel, _, _, refs in good:   # x-ref values against the merged view of the row they name
        if r["id"] not in refused:
            for _, m in ref_problems(refs, by, rs, refused):
                P(r["id"], f"{rel}: {m}")
    mid = len(probs)
    table_ok = table is not None
    if reads is None or TABLE in want:
        try:
            for m in role_problems(load(idx["role_table"])):
                P(TABLE, f"{idx['role_table']}: {m}")
                table_ok = False
        except Exception as e:
            P(TABLE, why(e) if isinstance(e, DataError) else f"{idx['role_table']}: {why(e)}")
            table_ok = False
    have, rows_of = {r["schema"] for r in rs if r["format"] == "json"}, {}
    for r in rs:
        if r["format"] == "json":
            rows_of.setdefault(r["schema"], []).append(r["id"])
    for n in sorted(NEEDED - have):
        P(FRAME, f"cross-file rules could not run: no JSON data file has schema {n}", {NOROW + n})
    members_of = lambda s: [TABLE] if s == TABLE else rows_of.get(s, [])
    c = {"by": by, "whole": whole, "src": by["_src"], "P": P, "rs": rs, "ids": ids, "table": table}
    blocked = {}   # judged member -> the refused members that kept its rules from running
    for name, judges, rd, fn in run:
        blk = [m for s in rd for m in (([TABLE] if not table_ok else []) if s == TABLE else [NOROW + s] if s not in have
                                        else [x for x in members_of(s) if x in refused])]
        if blk:
            for m in (m for s in judges for m in members_of(s) if m not in refused):
                blocked.setdefault(m, []).extend(blk)
            continue
        try:
            fn(c)
        except Exception as e:   # one coded line naming the rows it read; never the index, never a value
            read = [m for s in rd for m in members_of(s)]
            P(read[0], f"the cross-file rule '{name}' could not run ({type(e).__name__}); it read {', '.join(read)}", read)
    for m, blk in blocked.items():
        blk = list(dict.fromkeys(blk))
        first = blk[0].replace(NOROW, "schema ") + (" (no JSON row)" if blk[0].startswith(NOROW) else "")
        P(m, f"not judged by the cross-file rules: {first} is refused" + (f" (and {len(blk) - 1} more)" if len(blk) > 1 else ""), blk)
    return probs, by, {"head": head, "mid": mid, "own": [r["id"] for r in own], "members": members}


def check(only=None):
    """[(data id, problem)] over every data file in the index. With `only`: that file's problems, the index's own, and
    every cross-file problem (a candidate file is judged against the rest of the data)."""
    probs, _, cut = judge()
    head, mid, own = cut.get("head", 0), cut.get("mid", 0), cut.get("own", [])
    return [(d, m) for i, (d, m, _) in enumerate(probs) if only is None or only in own or d == only or i < head or i >= mid]


def served(ids):
    """The merged view, for a read of the rows `ids`, when no member it depends on (plan()) has a problem: else a DataError
    with the first problem (naming the member it belongs to) and how many more, and no data."""
    probs, by, cut = judge(reads=set(ids))
    deps = (cut.get("members") or set()) | {FRAME, *cut.get("own", [])}
    bad = [(d, m) for d, m, ms in probs if ms & deps]
    if bad:
        d, m = bad[0]
        raise DataError((f"{d}: {m}" if d in ids else f"{d}, which this read depends on: {m}") + (f" (and {len(bad) - 1} more)" if len(bad) > 1 else ""))
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


def policy_classes():
    """The data classes of the data policy, for `validate roles`: every file of every JSON row of the data-policy schema (found
    by the schema, opened only through layout(), so never an owner setting), each passing its schema."""
    rs = rows()
    try:
        table = load(load(INDEX)["role_table"])
    except DataError:
        table = None
    opened = [fs for r, fs in layout(rs, owner_files(table))[1] if r["schema"] == "data-policy"]
    docs = [checked(load(rel), rel, "data-policy") for fs in opened for rel, _ in fs]
    if not docs or len(opened) < sum(1 for r in rs if r["format"] == "json" and r["schema"] == "data-policy"):
        raise DataError("the data policy cannot be read (no file of its schema, or a row of it that is not opened)")
    return set.intersection(*(set(d["data_classes"]) for d in docs))


def install_id():
    """This install's id: install_id of the one document of the install schema, served like every read (a DataError when the
    index has no single such row or it is refused). New event lines and approval records read it here."""
    ids = [r["id"] for r in rows() if r["format"] == "json" and r["schema"] == INSTALL]
    if len(ids) != 1:
        raise DataError(f"the index has {len(ids)} JSON rows of schema {INSTALL}; exactly one holds the install id")
    docs = served(ids)["_rows"][ids[0]][0]
    if len(docs) != 1:
        raise DataError(f"{ids[0]}: holds {len(docs)} files; exactly one holds the install id")
    return docs[0][1]["install_id"]


def find_entries(row, by):
    """{entry id: entry} of one row from the view served() returned; a row with no list and no folder has none."""
    if row["format"] != "json" or not (row["list_key"] or is_folder(row)):
        return {}
    if row["id"] not in by["_rows"]:
        raise DataError(f"{row['id']}: not read")   # served() refuses first; never serve a row the rules did not see
    return by["_rows"][row["id"]][1]


def look(s, k, defs):
    """Keyword k of schema s, following $ref (the referencing schema's own keyword wins); None when absent."""
    for _ in range(MAX_DEPTH):
        if not isinstance(s, dict):
            return None
        if k in s:
            return s[k]
        r = s.get("$ref")
        s = defs.get(r.rsplit("/", 1)[-1]) if isinstance(r, str) else None
    return None


def shapes(row):
    """(the schema of a whole file of the row, the schema of one entry, $defs): what masked() needs to tell a key name the
    schema fixes from a key name taken from the data."""
    s = schema_of(row["schema"])
    defs = s.get("$defs", {})
    if row["list_key"] is None:
        return s, s, defs
    box = (look(s, "properties", defs) or {}).get(row["list_key"], {})
    one = look(box, "items", defs) or look(box, "additionalProperties", defs)
    return s, one if isinstance(one, dict) else {}, defs


def masked(row, x, s, defs, pats=None):
    """x as a read shows it. Masked ("***"): every value under a key that matches the row's redact_keys (at any depth, free-form
    objects too), a secret setting's default, every string hidden() says (a value pattern of the catalog matches it, it is too
    long to match, or the catalog cannot be read), and every key name the schema s does not fix (a free-form key, an entry id
    used as a key) that hidden() says ("***", "***2", ...). Every read command goes through here."""
    if pats is None:
        try:
            pats = [re.compile(p) for p in row["redact_keys"]]
        except re.error:
            raise DataError(f"{row['id']}: a redact_keys pattern is not a regular expression") from None
    if isinstance(x, str):
        return "***" if hidden(x) else x
    if isinstance(x, dict):
        hide, out, n = x.get("sensitivity") == "secret", {}, 0
        props, extra = look(s, "properties", defs), look(s, "additionalProperties", defs)
        props = props if isinstance(props, dict) else {}
        for k, v in x.items():
            sub = props[k] if k in props else extra if isinstance(extra, dict) else {}
            v = "***" if v is not None and ((hide and k == "default") or any(p.search(k) for p in pats)) else masked(row, v, sub, defs, pats)
            if k not in props and hidden(k):
                n += 1
                k = "***" if n == 1 else f"***{n}"
            out[k] = v
        return out
    return [masked(row, i, look(s, "items", defs) or {}, defs, pats) for i in x] if isinstance(x, list) else x


def mid_(k):
    """An entry id as a read shows it (list, search): "***" when hidden() says."""
    return "***" if hidden(k) else k


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
        try:
            rows()   # the index says which files are never opened (closed_ids): without it nothing is opened
        except DataError:
            raise DataError(f"{INDEX}: cannot be read or is not valid (run check), so validate opens no file") from None
        doc, refs = jload(args[1]), []   # refused unread when it is an owner setting (closed_ids)
        errs = [] if args[0] == "roles" else validate_doc(doc, schema_of(args[0]), refs)
        if args[0] == "roles":   # the role table has two judges, and a data class must be one the data policy defines
            errs = role_problems(doc)
            if not errs:
                errs = class_problems(doc, policy_classes())
        label = "role table" if args[0] == "roles" else f"{args[0]} file"
        rs = rows() if refs and not errs else []
        targets = sorted({t for _, _, t in refs if any(r["id"] == t and r["format"] == "json" for r in rs)})
        found = ref_problems(refs, served(targets) if targets else {"_rows": {}}, rs) if rs else []
        errs += [m for k, m in found if k == "row"]
        unknown = [m for k, m in found if k == "id"]
        if unknown and not errs:   # unknown fails closed: STL-CFG-311 and one alert line, never the value
            say("STL-CFG-311", f"{label}: {unknown[0]}" + (f" (and {len(unknown) - 1} more)" if len(unknown) > 1 else ""), alert=True)
            return 1
        errs = [f"STL-CFG-310 {alert_catalog.render('STL-CFG-310', {'problem': f'{label}: {e}'})[0].split(chr(10))[1]}" for e in errs]
        print("\n".join(errs) or "valid")
        return 1 if errs else 0
    if cmd == "list" and len(args) <= 1:
        if args:
            row = known_json(args[0])
            by = served([row["id"]])
            _, one, defs = shapes(row)
            ents = {mid_(k): masked(row, e, one, defs) for k, e in find_entries(row, by).items()}
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
            whole, one, defs = shapes(row)
            emit(masked(row, ents, {"additionalProperties": one}, defs) if is_folder(row) else masked(row, docs[0][1], whole, defs), True)
            return 0
        e = entry(find_entries(row, by), args[1])   # the old id is the record's alias; its global_id finds it too
        if e is None:
            refuse(f"entry of {args[0]}", args[1])
        emit(masked(row, e, shapes(row)[1], shapes(row)[2]), True)
        return 0
    if cmd == "search" and args:
        words, hits, rs = [w.casefold() for w in args], [], rows()
        by = served([r["id"] for r in rs])
        for r in rs:
            ents = find_entries(r, by)
            _, one, defs = shapes(r) if ents else (None, None, None)
            for k, e in ents.items():
                k, e = mid_(k), masked(r, e, one, defs)
                text = " ".join([k, *leaves(e)]).casefold()
                if all(w in text for w in words):
                    hits.append({"data": r["id"], "id": k, "status": e.get("status", ""), "summary": e.get("summary") or e.get("label") or ""})
        hits.sort(key=lambda h: (h["status"] != "approved", h["data"], h["id"]))
        emit(hits, as_json, lambda h: f"{h['data']}\t{shown(h['id'])}\t{h['status']}\t{h['summary']}")
        return 0
    if cmd == "ids-migrate" and len(args) == 3 and args[1] == "--out":
        rid, _, name = args[0].partition("/")
        row = known_json(rid)
        if not has_records(row) or folder_row(row) != bool(name) or name and not re.fullmatch(r"[^./\\][^/\\]*\.json", name):
            print(f"ids-migrate: {rid} takes " + ("<id>/<file>.json (a folder row)" if folder_row(row) else "<id> alone" if has_records(row)
                                                 else "nothing: its row has no records"), file=sys.stderr)
            return 2
        rel = f"{row['path'].rstrip('/')}/{name}" if name else row["path"]
        doc, iid, n = jload(plain(rel), rel), install_id(), 0
        for _, e in file_entries(row, rel, doc):
            n += "global_id" not in e or "install_id" not in e
            e.setdefault("global_id", str(uuid.uuid4()))
            e.setdefault("install_id", iid)
        try:
            with open(args[2], "x", encoding="utf-8") as f:   # x: never over an existing file
                f.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
        except OSError as e:
            raise DataError(f"{args[2]}: cannot be written ({type(e).__name__}); ids-migrate never writes over a file") from None
        print(f"{rel}: {n} records given ids; apply with: stella-apply.py apply {args[0]} --from {args[2]}")
        return 0
    if cmd == "owner-only" and not args:
        out = {}
        for n in sorted(x[:-len(".schema.json")] for x in os.listdir(os.path.join(ROOT, SCHEMAS)) if x.endswith(".schema.json")):
            sch = schema_of(n)
            errs = lint_schema(sch)
            if errs:   # fail closed: a schema that cannot be read hides no owner-only field
                raise DataError(f"{SCHEMAS}/{n}.schema.json: {errs[0]}")
            out[n] = owner_paths(sch, sch.get("$defs", {}))
        print(json.dumps(out, indent=2) if as_json else "\n".join(f"{n}\t{p}" for n, ps in out.items() for p in ps))
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
