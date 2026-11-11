#!/usr/bin/env python3
"""The owner's settings commands (F1 W4, spec E6/E7), stdlib only. Driven by the registry .stella/settings.json; no key, file or
role name is in this file. Not a tool of any role: roles.json lists it under owner_commands, so every role's hooks refuse to run it,
and it refuses itself in a worker's environment.
CLI: settings.py get <key> [--json]            the stored value (the default when none is stored); *** for a secret
     settings.py set <key> <value> [--dry-run]  validate the value against the entry, build the candidate file in canonical form
                                                and apply it through bin/stella-apply.py (backup, one event line, rollback);
                                                --dry-run prints the diff and changes nothing
     settings.py check [--json]                 the registry is valid and every stored value satisfies its entry
     settings.py list --json                    the registry entries (never a stored value)
Refused: a secret entry (secrets live in the vault; the registry never stores or shows one), STL-CFG-315; a value the entry
rejects or the owner file format cannot hold, STL-CFG-315; a worker (a marker variable from the role table's worker_markers is set,
or bin/roles.py prove says this process is a worker or cannot tell), STL-CFG-312; an identity_critical entry without the key typed
back on the controlling terminal (none = no terminal), STL-CFG-317; an unknown key, STL-CFG-311 with one alert line.
Exit: 0 ok (a set of the value already stored is "no change"); 1 refused or failed; 2 usage. The value of a secret is never
printed, logged or put in a message. Only env-format stores are written (the stores of the registry today)."""
import json, os, re, subprocess, sys, tempfile
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import owner_config as oc
import stella_data as sd

SECRET, CRITICAL = "secret", "identity_critical"


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


def worker_reason():
    """Why this process may not use an owner path (None = it is not a worker): the same proof the apply tool uses."""
    try:
        marks = role_table()["worker_markers"]
        assert isinstance(marks, list) and marks and all(isinstance(m, str) and m for m in marks)
    except Exception:
        return "the list of worker markers is not available, so it cannot be told that this is not a worker"
    if any(os.environ.get(m) for m in marks):
        return "a worker marker is set"
    try:   # exit 1 + "not proven" = no worker run; 0 = a worker; anything else (3, a crash) = cannot tell
        r = subprocess.run([sys.executable, "-I", os.path.join(BIN, "roles.py"), "prove"], capture_output=True, text=True, timeout=60)
    except Exception:
        return "it could not be proven that this process is not a worker"
    if r.returncode == 0:
        return "this process belongs to a worker's run"
    return None if r.returncode == 1 and "roles: not proven" in r.stderr else "it could not be proven that this process is not a worker"


def need_owner(what):
    why = worker_reason()
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


def read_store(row):
    """(file bytes or None, {key: value}) of an env-format store."""
    try:
        with open(el.path(row["path"]), "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        return None, {}
    except (OSError, ValueError) as e:
        raise Refuse("STL-CFG-313", f"{row['id']} cannot be read: {type(e).__name__}")
    try:
        return raw, oc.parse_env(raw.decode("utf-8-sig"), row["id"])
    except (oc.OwnerConfigError, UnicodeDecodeError) as e:
        raise Refuse("STL-CFG-313", f"{row['id']} is not a valid env file: {str(e)[:120]}")


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
    _, cfg = read_store(row)
    if k in cfg:
        return typed_stored(e, cfg[k]), "store"
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


def confirm(e):
    """The owner types the key back on the controlling terminal; no terminal, or another text, is STL-CFG-317."""
    try:
        out, inp = open("/dev/tty", "w"), open("/dev/tty", "r")   # two handles: a terminal is not seekable, so no "r+"
    except OSError:
        raise Refuse("STL-CFG-317", f"{e['key']} is identity-critical and there is no terminal to ask on")
    with out, inp:
        out.write(f"{e['key']} ({e['label']}) is identity-critical. Type the key name to confirm: ")
        out.flush()
        said = inp.readline().strip()
    if said != e["key"]:
        raise Refuse("STL-CFG-317", f"{e['key']}: the confirmation did not match")


def do_set(key, text, dry):
    need_owner("a settings change")
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
    if not dry and e["sensitivity"] == CRITICAL:
        confirm(e)
    lines = (raw.decode("utf-8-sig") if raw is not None else "").split("\n")
    hit = [i for i, l in enumerate(lines) if l.startswith(k + "=")]   # parse_env accepted the file: at most one such line
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
        r = subprocess.run([sys.executable, "-I", os.path.join(BIN, "stella-apply.py"), "apply", row["id"], "--from", src] + (["--dry-run"] if dry else []))
    return r.returncode


def do_check(as_json):
    out = [{"code": "STL-CFG-310", "key": None, "problem": m} for d, m in sd.check("settings") if d == "settings"]
    why = None if out else worker_reason()
    if not out:
        for e in registry():
            row, k = store(e)
            if e["sensitivity"] == SECRET or (is_owner_file(row) and why):
                continue   # a secret is never read; an owner file is not read for a worker
            _, cfg = read_store(row)
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


def main(argv):
    as_json, dry = "--json" in argv, "--dry-run" in argv
    a = [x for x in argv if x not in ("--json", "--dry-run")]
    cmd, args = (a[0] if a else ""), a[1:]
    try:
        if cmd == "get" and len(args) == 1 and not dry:
            return do_get(args[0], as_json)
        if cmd == "set" and len(args) == 2 and not as_json:
            return do_set(args[0], args[1], dry)
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
