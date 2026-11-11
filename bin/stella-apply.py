#!/usr/bin/env python3
"""The generic apply contract (core contract item 8, spec E9), stdlib only. Works for every row of .stella/data-files.json
(format json, or env for KEY='value' files); a folder row takes <id>/<entry file name>. No data file is special-cased.
CLI: stella-apply.py apply <id> --from <file> [--dry-run]   validate the candidate (the whole-set check with the candidate in
                                                           place of its file), back up, replace atomically, one event line
     stella-apply.py check [<id>] [--json]                  drift: sha256 differs from the last applied one, or (never
                                                           applied) from the committed blob; no baseline is not drift
     stella-apply.py rollback <id>                          restore the newest backup, one event line
     stella-apply.py history <id> [--json]                  the event lines of <id> and its backups
Exit: 0 ok (a no-change apply too); 1 refused or failed, or drift (check); 2 usage. Every failure prints its catalog code
(STL-CFG-311 unknown id, 312 owner-only, 313 failed/invalid, 314 drift, 316 no backup, 318 event log) and plain message.
Order of an apply, under one lock per id: event log checked writable; backup (bytes, mode, previous applied record, status
pending) -> atomic replace -> applied state -> event line -> backup status done. Event line not written: file and applied
state are put back, the exit is 318, nothing changed. A kill in between leaves the backup with status pending: `check`
reports it (314), apply refuses, `rollback` restores the file (or, if the file was never replaced, just discards the backup).
Owner-only rows (index owner_only) are refused (312) for a worker: a worker marker variable is set (the names are the role
table's `worker_markers`; missing = refuse), or `roles.py prove` says this process is a worker or cannot tell.
Values under redact_keys / secret settings never appear in a diff, event, or message (***)."""
import argparse, datetime, difflib, hashlib, json, os, pwd, shutil, subprocess, sys, tempfile
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import owner_config as oc
import stella_data as sd

EventError = el.EventError
SECRETS = set()   # values seen under masked keys; scrubbed from any message

def bad(problem, code="STL-CFG-313"):
    return EventError(code, problem)

def sha(b):
    return hashlib.sha256(b).hexdigest()

def read(p):
    try:
        with open(p, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None

def atomic_write(p, data, mode):
    """Temp file in the same folder, fsync, rename, fsync the folder."""
    d = os.path.dirname(p)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".stella-apply.")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, p)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    dfd = os.open(d, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)

def restore(p, data, mode):
    if data is None:
        if os.path.exists(p):
            os.unlink(p)
    else:
        atomic_write(p, data, mode)

# ---- which file ----
def target(arg):
    """(row, key, absolute path, root-relative path). Unknown id: STL-CFG-311 and exit (stella_data.refuse)."""
    did, _, entry = arg.partition("/")
    row = sd.row_of(did)
    if sd.is_folder(row) != bool(entry):
        raise bad(f"{did} " + ("is a folder: name a file as <id>/<file>" if entry == "" else "is a single file: give just its id"))
    if entry and (entry != os.path.basename(entry) or entry.startswith(".") or not entry.endswith(".json")):
        raise bad(f"{arg}: not a plain *.json file name")
    rel = row["path"] + ("/" + entry if entry else "")
    try:
        return row, arg, el.path(rel), rel
    except ValueError as e:
        raise bad(str(e))

def gate(row):
    """Owner-only rows: refuse for a worker, and when that cannot be told (STL-CFG-312)."""
    if not row["owner_only"]:
        return
    why = None
    try:
        marks = sd.load(sd.load(sd.INDEX)["role_table"])["worker_markers"]
        assert isinstance(marks, list) and all(isinstance(m, str) and m for m in marks)
    except Exception:
        why = "the list of worker markers is not available, so it cannot be told that this is not a worker"
    else:
        if any(os.environ.get(m) for m in marks):
            why = "a worker marker is set"
        else:
            try:   # exit 1 + "not proven" = no worker run; 0 = a worker; anything else (3, a crash) = cannot tell
                r = subprocess.run([sys.executable, "-I", os.path.join(BIN, "roles.py"), "prove"], capture_output=True, text=True, timeout=60)
                if r.returncode == 0:
                    why = "this process belongs to a worker's run"
                elif r.returncode != 1 or "roles: not proven" not in r.stderr:
                    why = "it could not be proven that this process is not a worker"
            except Exception:
                why = "it could not be proven that this process is not a worker"
    if why:
        raise bad(f"{row['id']} is owner-only: {why}", "STL-CFG-312")

# ---- the applied state, backups ----
def state_path():
    return el.path(sd.load(sd.INDEX)["applied_state"])

def applied():
    raw = read(state_path())
    try:
        return {} if raw is None else json.loads(raw)["applied"]
    except (ValueError, KeyError, TypeError):
        raise bad("the applied state is unreadable; nothing was changed")

def set_applied(key, rec):
    p = state_path()
    with el.locked(p + ".lock"):
        a = applied()
        if rec is None:
            a.pop(key, None)
        else:
            a[key] = rec
        atomic_write(p, json.dumps({"schema_version": 1, "applied": a}, indent=1).encode(), 0o600)

def bdir(key):
    return el.path(os.path.join(sd.load(sd.INDEX)["backup_dir"], key))

def backups(key):
    """[(name, meta)] oldest first. A folder without meta.json is an unfinished backup and is dropped."""
    d, out = bdir(key), []
    for n in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        try:
            out.append((n, json.load(open(os.path.join(d, n, "meta.json"), encoding="utf-8"))))
        except (OSError, ValueError):
            if os.path.isfile(os.path.join(d, n, "file")) or os.path.isdir(os.path.join(d, n)):
                shutil.rmtree(os.path.join(d, n), ignore_errors=True)
    return out

def lockfile(key):
    return os.path.join(el.path(sd.load(sd.INDEX)["backup_dir"]), ".locks", key.replace("/", "__") + ".lock")

# ---- parse, validate, diff ----
def parse(fmt, data):
    if fmt == "json":
        def obj(pairs):
            d = dict(pairs)
            if len(d) != len(pairs):
                raise ValueError("a key is repeated")
            return d
        def const(c):
            raise ValueError(f"{c} is not valid JSON")
        return json.loads(data.decode("utf-8"), object_pairs_hook=obj, parse_constant=const)
    cfg = {}
    for n, line in enumerate(data.decode("utf-8-sig").split("\n"), 1):
        if not line.strip(" \t\r") or line.lstrip(" \t").startswith("#"):
            continue
        m = oc.LINE.fullmatch(line)
        if not m or m[1] in cfg:
            raise ValueError(f"line {n}: " + ("a key is repeated" if m else f"not {oc.FORMS}"))
        cfg[m[1]] = next(v for v in m.groups()[1:] if v is not None)
    return cfg

def note_secrets(doc, red):
    if isinstance(doc, dict):
        for k, v in doc.items():
            if red(str(k)):
                SECRETS.update(str(x) for x in leaves(v))
            else:
                note_secrets(v, red)
    elif isinstance(doc, list):
        for v in doc:
            note_secrets(v, red)

def leaves(v):
    if isinstance(v, dict):
        for x in v.values():
            yield from leaves(x)
    elif isinstance(v, list):
        for x in v:
            yield from leaves(x)
    elif v is not None:
        yield v

def stage(tmp, rel, data):
    """A scratch root holding what the whole-set check reads: index, schemas, role table, every json row; the candidate
    (when not None) in place of its file. Every path is confined to the root first."""
    idx = sd.load(sd.INDEX)
    srcs = {sd.INDEX, sd.SCHEMAS}
    docs = [idx] + ([json.loads(data)] if data is not None and rel == sd.INDEX else [])
    for d in docs:
        srcs |= {d["role_table"]} | {r["path"] for r in d["files"] if r["format"] == "json"}
    for s in srcs:
        src = el.path(s)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(tmp, s), dirs_exist_ok=True)
        elif os.path.isfile(src):
            os.makedirs(os.path.dirname(os.path.join(tmp, s)), exist_ok=True)
            shutil.copy2(src, os.path.join(tmp, s))
    if data is not None:
        os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
        with open(os.path.join(tmp, rel), "wb") as f:
            f.write(data)

def problems(rel, data):
    with tempfile.TemporaryDirectory(prefix="stella-apply-") as tmp:
        stage(tmp, rel, data)
        r = subprocess.run([sys.executable, "-I", os.path.join(BIN, "stella_data.py"), "check", "--json"],
                           env={**os.environ, "STELLA_ROOT": tmp}, capture_output=True, text=True, timeout=120)
    if r.returncode not in (0, 1):
        raise bad("the validity check could not run")
    return {(p["data"], p["problem"]) for p in json.loads(r.stdout)["problems"]}

def validate(row, rel, data):
    try:
        doc = parse(row["format"], data)
    except (ValueError, UnicodeDecodeError) as e:
        raise bad(f"the candidate is not valid {row['format']}: {type(e).__name__} {e}"[:300])
    if not isinstance(doc, dict):
        raise bad("the candidate must be an object / a list of settings")
    note_secrets(doc, el.redactor(row["id"]))
    if row["format"] != "json":
        return doc
    try:
        after = problems(rel, data)
        new = sorted(p for p in after if p[0] == row["id"] or p not in (problems(rel, None) if after else set()))
    except EventError:
        raise
    except Exception as e:
        raise bad(f"the validity check failed: {type(e).__name__}")
    if new:
        raise bad(f"the candidate is invalid: {new[0][0]}: {new[0][1]}" + (f" (+{len(new) - 1} more)" if len(new) > 1 else ""))
    return doc

def flat(v, ptr=""):
    if isinstance(v, dict) and v:
        for k, x in v.items():
            yield from flat(x, ptr + "/" + str(k).replace("~", "~0").replace("/", "~1"))
    elif isinstance(v, list) and v:
        for i, x in enumerate(v):
            yield from flat(x, f"{ptr}/{i}")
    else:
        yield ptr, v

def changes(fmt, old, new):
    """(old, new): the changed JSON pointers (json) or keys (env) with their values."""
    o, n = (dict(flat(old)), dict(flat(new))) if fmt == "json" else (old, new)
    key = lambda d, k: json.dumps(d[k], sort_keys=True) if k in d else None
    ch = [k for k in dict.fromkeys([*o, *n]) if key(o, k) != key(n, k)]
    return {k: o[k] for k in ch if k in o}, {k: n[k] for k in ch if k in n}

def text(fmt, doc, red):
    if doc is None:
        return []
    m = el.mask(doc, red)
    return json.dumps(m, indent=2, ensure_ascii=False).splitlines() if fmt == "json" else [f"{k}='{v}'" for k, v in m.items()]

def who():
    return {"user": pwd.getpwuid(os.getuid()).pw_name}

def commit_event(row, key, kind, fmt, old, new, detail):
    o, n = changes(fmt, old if old is not None else {}, new if new is not None else {})
    el.append(el.build(kind, key, o, n, detail=detail, who=who()), row["id"])

# ---- commands ----
def do_apply(arg, src, dry):
    row, key, tgt, rel = target(arg)
    gate(row)
    try:
        cand = read(src)
    except OSError as e:
        raise bad(f"cannot read the candidate file: {e.strerror}")
    if cand is None:
        raise bad("the candidate file does not exist")
    fmt, red = row["format"], el.redactor(row["id"])
    new_doc = validate(row, rel, cand)
    if dry:
        cur = read(tgt)
        old_doc = parse(fmt, cur) if cur is not None else None
        note_secrets(old_doc, red)
        d = list(difflib.unified_diff(text(fmt, old_doc, red), text(fmt, new_doc, red), "current", "candidate", lineterm=""))
        print("\n".join(d) if cur != cand else f"no change: {key}")
        return 0
    with el.locked(lockfile(key)):
        cur = read(tgt)
        if cur == cand:
            print(f"no change: {key}")
            return 0
        if any(m.get("status") == "pending" for _, m in backups(key)):
            raise bad(f"{key}: an earlier change was interrupted; run rollback {key} first")
        old_doc = parse(fmt, cur) if cur is not None else None
        note_secrets(old_doc, red)
        el.preflight()
        mode = os.stat(tgt).st_mode & 0o7777 if cur is not None else 0o644
        prev = applied().get(key)
        name = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + f"-{len(backups(key)) + 1:04d}"
        bd = os.path.join(bdir(key), name)
        meta = {"path": rel, "existed": cur is not None, "mode": mode, "sha256": sha(cur) if cur is not None else None,
                "new_sha256": sha(cand), "prev_applied": prev, "status": "pending"}
        os.makedirs(bd, mode=0o700)
        try:
            if cur is not None:
                atomic_write(os.path.join(bd, "file"), cur, 0o600)
            atomic_write(os.path.join(bd, "meta.json"), json.dumps(meta).encode(), 0o600)
        except BaseException:
            shutil.rmtree(bd, ignore_errors=True)
            raise
        try:
            atomic_write(tgt, cand, mode)
            set_applied(key, {"sha256": sha(cand), "time": el.build("x", "x")["time"]})
            commit_event(row, key, "apply", fmt, old_doc, new_doc, f"sha256 {(meta['sha256'] or 'none')[:12]} -> {sha(cand)[:12]}")
        except BaseException:
            restore(tgt, cur, mode)
            set_applied(key, prev)
            shutil.rmtree(bd, ignore_errors=True)
            raise
        meta["status"] = "done"
        atomic_write(os.path.join(bd, "meta.json"), json.dumps(meta).encode(), 0o600)
    print(f"applied: {key} (backup {name})")
    return 0

def do_rollback(arg):
    row, key, tgt, rel = target(arg)
    gate(row)
    fmt = row["format"]
    with el.locked(lockfile(key)):
        bs = backups(key)
        if not bs:
            raise bad(f"{key}: nothing was applied through the apply command", "STL-CFG-316")
        name, meta = bs[-1]
        bd = os.path.join(bdir(key), name)
        cur, back = read(tgt), read(os.path.join(bd, "file")) if meta["existed"] else None
        if cur == back:   # already restored (a kill after the event line, or a hand revert): only the bookkeeping is left
            set_applied(key, meta["prev_applied"])
            shutil.rmtree(bd, ignore_errors=True)
            print(f"nothing to restore: {key} already matches its backup {name}")
            return 0
        el.preflight()
        mode = os.stat(tgt).st_mode & 0o7777 if cur is not None else 0o644
        cur_rec = applied().get(key)
        try:
            restore(tgt, back, meta["mode"])
            set_applied(key, meta["prev_applied"])
            red = el.redactor(row["id"])
            docs = [parse(fmt, b) if b is not None else None for b in (cur, back)]
            for d in docs:
                note_secrets(d, red)
            commit_event(row, key, "rollback", fmt, docs[0], docs[1], f"restored backup {name}")
        except BaseException:
            restore(tgt, cur, mode)
            set_applied(key, cur_rec)
            raise
        shutil.rmtree(bd, ignore_errors=True)
    print(f"rolled back: {key} (backup {name})")
    return 0

def git_blob(rel):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_CEILING_DIRECTORIES"] = os.path.dirname(el.ROOT)   # a scratch root is never read through an outer repo
    try:
        r = subprocess.run(["git", "-C", el.ROOT, "show", f"HEAD:./{rel}"], capture_output=True, env=env, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None

def check_one(key, rel, tgt):
    cur, rec = read(tgt), applied().get(key)
    r = {"id": key, "path": rel, "baseline": "none", "state": "no_baseline"}
    pend = [n for n, m in backups(key) if m.get("status") == "pending"]
    if rec:
        r["baseline"], want = "applied", rec["sha256"]
    elif (blob := git_blob(rel)) is not None:
        r["baseline"], want = "git", sha(blob)
    else:
        want = None
    if pend:
        r.update(state="pending", problem=f"an earlier change was interrupted (backup {pend[-1]}); run rollback {key}")
    elif want is not None:
        r["state"] = "ok" if cur is not None and sha(cur) == want else "drift"
        if r["state"] == "drift":
            r["problem"] = f"{key} " + ("is missing" if cur is None else "differs") + f" from its {r['baseline']} baseline"
    if r["state"] in ("drift", "pending"):
        r["code"] = "STL-CFG-314"
        body, tag, kv = el.alert_catalog.render("STL-CFG-314", {"problem": r["problem"]})
        el.alert_catalog.log(tag, kv)
        r["message"] = body.split("\n")[1]
    return r

def do_check(arg, as_json):
    rs = [sd.row_of(arg.partition("/")[0])] if arg else sd.rows()
    out = []
    for row in rs:
        if sd.is_folder(row):
            d = el.path(row["path"])
            names = {f"{row['id']}/{f}" for f in os.listdir(d) if f.endswith(".json")} | {k for k in applied() if k.startswith(row["id"] + "/")}
            names = [arg] if "/" in (arg or "") else sorted(names)
        else:
            names = [row["id"]]
        for k in names:
            _, key, tgt, rel = target(k)
            out.append(check_one(key, rel, tgt))
    bad_ = [r for r in out if r["state"] in ("drift", "pending")]
    if as_json:
        print(json.dumps({"ok": not bad_, "files": out}, indent=2))
    else:
        for r in out:
            print(f"{r['code']} {r['message']}" if "code" in r else f"{r['state']:<12} {r['id']} (baseline {r['baseline']})")
    return 1 if bad_ else 0

def do_history(arg, as_json):
    row, key, _, _ = target(arg) if "/" in arg or not sd.is_folder(sd.row_of(arg)) else (sd.row_of(arg), arg, None, None)
    gate(row)
    evs = [e for e in el.tail(sys.maxsize) if e.get("what") == key or str(e.get("what", "")).startswith(key + "/")]
    bs = [{"name": n, "status": m.get("status")} for n, m in backups(key)] if not sd.is_folder(row) or "/" in arg else []
    if as_json:
        print(json.dumps({"id": key, "events": evs, "backups": bs}, indent=2, ensure_ascii=False))
    else:
        print("\n".join(f"{e['time']} {e['type']} {e['what']} {e.get('detail', '')}" for e in evs))
    return 0

def main(argv):
    ap = argparse.ArgumentParser(prog="stella-apply.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("apply")
    a.add_argument("id")
    a.add_argument("--from", dest="src", required=True)
    a.add_argument("--dry-run", action="store_true")
    c = sub.add_parser("check")
    c.add_argument("id", nargs="?")
    c.add_argument("--json", action="store_true")
    r = sub.add_parser("rollback")
    r.add_argument("id")
    h = sub.add_parser("history")
    h.add_argument("id")
    h.add_argument("--json", action="store_true")
    o = ap.parse_args(argv)
    try:
        if o.cmd == "apply":
            return do_apply(o.id, o.src, o.dry_run)
        if o.cmd == "rollback":
            return do_rollback(o.id)
        return do_check(o.id, o.json) if o.cmd == "check" else do_history(o.id, o.json)
    except EventError as e:
        msg = e.problem
        for s in sorted(SECRETS, key=len, reverse=True):
            msg = msg.replace(s, el.MASK)
        return el.fail(e.code, msg)
    except OSError as e:
        return el.fail("STL-CFG-313", f"{type(e).__name__}: {e.strerror}")

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
