#!/usr/bin/env python3
"""The generic apply contract (core contract item 8, spec E9), stdlib only. Works for every row of .stella/data-files.json
(format json, or env for KEY='value' files); a folder row takes <id>/<entry file name>. No data file is special-cased.
CLI: stella-apply.py apply <id> --from <file> [--dry-run]   validate the candidate (the whole-set check with the candidate in
                                                           place of its file), back up, replace atomically, one event line
     stella-apply.py check [<id>] [--json]                  drift: sha256 or mode differs from the last applied one, or (never
                                                           applied) the sha256 from the committed blob; no baseline is not drift
     stella-apply.py rollback <id>                          restore the newest backup, one event line
     stella-apply.py history <id> [--json]                  the event lines of <id> and its backups
Exit: 0 ok (a no-change apply too); 1 refused or failed, or drift (check); 2 usage. Every failure prints its catalog code
(STL-CFG-310 unreadable data, 311 unknown id, 312 owner-only, 313 failed/invalid, 314 drift, 315 a setting's own code, 316 no
or damaged backup, 318 event log) and plain message; an unexpected exception is exit 1 and one coded line, never a traceback.
One lock covers a whole apply or rollback (validation included). Order of an apply: event log checked writable; backup (bytes,
mode, previous applied record, status pending) -> atomic replace -> applied state -> event line -> backup status done. Event
line not written: file and applied state are put back, the exit is 318, nothing changed. A kill in between leaves the backup
with status pending: `check` reports it (314), apply refuses unless the file already holds the candidate (then it finishes the
bookkeeping and writes the missing event line), `rollback` restores the file. A rollback marks its backup rollback-pending
first, so a kill at any step is finished by the next run, which writes the event line the killed one did not.
Rollback restores only what this tool saved: the saved copy must match its sha256, the file must hold the bytes the apply wrote
or the bytes it replaced (anything else is a hand edit: 314), and the restored content must pass the same checks as a candidate.
Every path (a row, the folders on the way, the backup folder, the applied state, the event log, their locks) must be the real
file the index names: a symbolic link or a path that resolves elsewhere is refused (313), and no two rows or index paths may be one file.
Owner-only rows (index owner_only) are refused (312) for a worker: a worker marker variable is set (the names are the role
table's `worker_markers`; missing or empty = refuse), or `roles.py prove` says this process is a worker or cannot tell.
That gate is a second line only: a caller can clear its markers, shadow the board tool on PATH or detach from its parent. The
boundary is the hooks of every role refusing to run this tool at all (item W4); see the contract docs.
Values under redact_keys / non-plain settings never appear in a diff, event, or message (***)."""
import argparse, contextlib, datetime, difflib, hashlib, json, os, pwd, re, shutil, subprocess, sys, tempfile
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import owner_config as oc
import stella_data as sd

EventError = el.EventError
SECRETS = el.SECRETS   # values seen under masked keys; scrubbed from any message and event detail
TMP = ".stella-apply."   # the prefix of this tool's own temp files
ENTRY = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._-]*\.json")   # a folder entry's file name, for every command
NOT_DONE = "a backup whose status is not done"
CTX = {}

def bad(problem, code="STL-CFG-313"):
    return EventError(code, problem)

def qs(x):
    """Text for a line of output: JSON-escaped, so a name or value cannot start a line of its own."""
    return json.dumps(str(x))[1:-1]

def sha(b):
    return hashlib.sha256(b).hexdigest()

def path(rel):
    try:
        return el.path(rel)
    except ValueError as e:
        raise bad(str(e))

def read(p):
    """The bytes of a data, state or backup file (None when missing). A symbolic link is never followed."""
    try:
        fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "rb") as f:
        return f.read()

def mkdir_p(p):
    """p and the folders on the way, each created 0700 (they hold or lead to full copies of owner files)."""
    if not os.path.isdir(p):
        mkdir_p(os.path.dirname(p))
        os.mkdir(p, 0o700)

def atomic_write(p, data, mode):
    """Temp file (0600) in the same folder, fsync, rename, fsync the folder."""
    d = os.path.dirname(p)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=TMP)
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
        if os.path.lexists(p):
            os.unlink(p)
    else:
        atomic_write(p, data, mode)

# ---- the index, read once ----
def context():
    """The index and its rows, read once per process, with the checks that no two paths of the index are one file."""
    if CTX:
        return CTX
    idx, rows = sd.load(sd.INDEX), sd.rows()
    el.LOG_REL = idx["event_log"]
    named = [("the event log", idx["event_log"]), ("the backup folder", idx["backup_dir"]), ("the applied state", idx["applied_state"])] \
        + [(f"the file of {r['id']}", r["path"]) for r in rows]
    real, seen = (lambda rel: os.path.realpath(os.path.join(el.ROOT, rel))), {}
    for what, rel in named:
        if real(rel) in seen:
            raise bad(f"{what} and {seen[real(rel)]} are the same file; the index must name each file once")
        seen[real(rel)] = what
    bd = real(idx["backup_dir"])
    for what, rel in named:
        if real(rel).startswith(bd + os.sep):
            raise bad(f"{what} lies inside the backup folder")
    CTX.update(idx=idx, rows=rows)
    return CTX

# ---- which file ----
def target(arg, whole=False):
    """(row, key, absolute path, root-relative path). Unknown id: STL-CFG-311 and exit (stella_data.refuse). One name per row:
    <id> for a single file, <id>/<entry> for a folder entry (whole: a folder's bare id is allowed for the read commands)."""
    did, slash, entry = arg.partition("/")
    row = sd.row_of(did)
    if sd.is_folder(row):
        if not slash and not whole:
            raise bad(f"{did} is a folder: name a file as <id>/<file>")
        if slash and not ENTRY.fullmatch(entry):
            raise bad(f"{json.dumps(arg)}: not a plain file name (letters, digits, dot, dash, underscore; ends in .json)")
    elif slash:
        raise bad(f"{did} is a single file: give just its id")
    rel = row["path"] + ("/" + entry if slash else "")
    return row, (arg if slash else did), path(rel), rel

def gate(row):
    """Owner-only rows: refuse for a worker, and when that cannot be told (STL-CFG-312).
    shortcut: this cannot prove an owner from inside the process (a caller can clear its marker variables, shadow the board
    tool on PATH, or detach from its parent); the boundary is item W4, whose hooks refuse every role the right to run this
    tool. Until W4 is in, a worker can still write an owner-only row through it. Upgrade: none here, W4 owns it."""
    if not row["owner_only"]:
        return
    why = None
    try:
        marks = sd.load(context()["idx"]["role_table"])["worker_markers"]
    except Exception:
        marks = None
    if not (isinstance(marks, list) and marks and all(isinstance(m, str) and m for m in marks)):
        why = "the list of worker markers is not available, so it cannot be told that this is not a worker"
    elif any(os.environ.get(m) for m in marks):
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

def private(row):
    """True when no hash of the file may reach a log: owner-only, redact keys, or a non-plain registry setting is stored in it."""
    return bool(row["owner_only"] or row["redact_keys"]
                or any(e["sensitivity"] != "plain" and e["store"]["data"] == row["id"] for e in el.registry()["entries"]))

# ---- the applied state, backups, locks ----
def state_path():
    return path(context()["idx"]["applied_state"])

def load_state():
    """({key: record}, counter). The counter orders the backups; a record is {sha256, mode, time}."""
    raw = read(state_path())
    if raw is None:
        return {}, 0
    try:
        d = json.loads(raw)
        a, c = d["applied"], d.get("counter", 0)
        if not isinstance(a, dict) or type(c) is not int or not all(isinstance(v, dict) and isinstance(v.get("sha256"), str) for v in a.values()):
            raise TypeError
        return a, c
    except (ValueError, KeyError, TypeError, RecursionError):
        raise bad("the applied state is unreadable; nothing was changed", "STL-CFG-310")

def applied():
    return load_state()[0]

def set_applied(key, rec, seq=None):
    p = state_path()
    mkdir_p(os.path.dirname(p))
    with el.locked(p + ".lock"):
        a, c = load_state()
        if rec is None:
            a.pop(key, None)
        else:
            a[key] = rec
        atomic_write(p, json.dumps({"schema_version": 1, "applied": a, "counter": max(c, seq or 0)}, indent=1).encode(), 0o600)

def bdir(key):
    return path(os.path.join(context()["idx"]["backup_dir"], key))

def seq_of(name):
    m = re.match(r"(\d+)-", name)
    return int(m[1]) if m else -1

def backups(key):
    """[(name, meta)] oldest first (by the counter in the name). meta is None when meta.json is missing or unreadable: an
    unfinished backup (a kill before the file was touched) that check reports and rollback removes."""
    d, out = bdir(key), []
    for n in os.listdir(d) if os.path.isdir(d) else []:
        if not os.path.isdir(os.path.join(d, n)) or os.path.islink(os.path.join(d, n)):
            continue
        try:
            m = json.loads(read(os.path.join(d, n, "meta.json")) or b"")
        except (OSError, ValueError, RecursionError):
            m = None
        out.append((n, m if m is None or isinstance(m, dict) else {}))   # {} = valid JSON that is not a meta object: damaged, not unfinished
    return sorted(out, key=lambda x: (seq_of(x[0]), x[0]))

def backed_ids():
    """Ids (first part of a key) that still have a file under the backup folder."""
    d = path(context()["idx"]["backup_dir"])
    return [n for n in (os.listdir(d) if os.path.isdir(d) else []) if not n.startswith(".") and any(fs for _, _, fs in os.walk(os.path.join(d, n)))]

@contextlib.contextmanager
def exclusive(key):
    """One lock for the whole apply or rollback (every id: the cross-file rules see one change at a time), taken before the
    validation. The row's own lock file is kept as well (a second name for the same wait)."""
    lk = path(os.path.join(context()["idx"]["backup_dir"], ".locks"))
    mkdir_p(lk)
    with el.locked(os.path.join(lk, ".all.lock")), el.locked(os.path.join(lk, key.replace("/", "__") + ".lock")):
        yield

def sweep(key, tgt):
    """A temp file of this tool's own name, found while holding the lock, is the leftover of a crash and holds file bytes."""
    dirs = {os.path.dirname(tgt), os.path.dirname(state_path())} | {r for r, _, _ in os.walk(bdir(key))}
    for d in dirs:
        for n in os.listdir(d) if os.path.isdir(d) else []:
            f = os.path.join(d, n)
            if n.startswith(TMP) and os.path.isfile(f) and not os.path.islink(f):
                with contextlib.suppress(OSError):
                    os.unlink(f)

def logged(key, kind, name):
    evs, _ = el.read_log()
    return any(e.get("what") == key and e.get("type") == kind and name in str(e.get("detail", "")) for e in evs)

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

def parse_or_none(fmt, data):
    """(doc, parses). A current file that does not parse is no basis for a diff, but it can be replaced."""
    if data is None:
        return None, True
    try:
        return parse(fmt, data), True
    except (ValueError, UnicodeDecodeError, RecursionError):
        return None, False

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
        src = path(s)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(tmp, s), dirs_exist_ok=True, symlinks=True)
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

def registry_problems(row, doc):
    """An env file against the registry: every setting stored in this data file is checked with the registry's own type and
    validation (stella_data.setting_problems on the value as the default), and a setting with no default must be present.
    Keys the registry does not know stay allowed. A failure carries that entry's own code."""
    for e in el.registry()["entries"]:
        if e["store"]["data"] != row["id"]:
            continue
        k = e["store"]["key"]
        if k not in doc:
            if e["default"] is None:
                raise EventError(e["code"], f"{k} must be present in {row['id']} (it has no default)")
            continue
        v, t = doc[k], e["type"]
        # shortcut: env values are text; only plain integers, finite numbers and true/false are converted, any other text stays a string
        if t == "integer" and re.fullmatch(r"-?[0-9]+", v):
            v = int(v)
        elif t == "number" and re.fullmatch(r"-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?", v):
            v = float(v)
        elif t == "boolean" and v in ("true", "false"):
            v = v == "true"
        errs = sd.setting_problems({**e, "default": v, "sensitivity": "plain"})   # plain: a secret has no default, but the value is checked
        if errs:
            raise EventError(e["code"], f"{k}: " + re.sub(r"^default (\$: )?", "", errs[0]))

def index_moves(doc):
    """Applying the index through itself: the paths the running apply already uses cannot move under it, the index keeps its
    own row, and no row with a backup may go."""
    idx = context()["idx"]
    for k in ("event_log", "backup_dir", "applied_state"):
        if doc.get(k) != idx[k]:
            raise bad(f"the index cannot change {k} through its own apply (the backup, state and log of this run would move under it); "
                      "stop everything that uses the tool, move the file by hand and edit the index by hand, then run check")
    files = [r for r in doc.get("files", []) if isinstance(r, dict)] if isinstance(doc.get("files"), list) else []
    if not any(r.get("path") == sd.INDEX for r in files):
        raise bad("the candidate index has no row for the index itself; keep it")
    gone = [i for i in backed_ids() if i not in {r.get("id") for r in files}]
    if gone:
        raise bad(f"the candidate index drops a row that still has a backup ({', '.join(gone)}); roll those back first, then drop the row")

def validate(row, rel, data):
    try:
        doc = parse(row["format"], data)
    except (ValueError, UnicodeDecodeError, RecursionError) as e:
        raise bad(f"the candidate is not valid {row['format']}: {type(e).__name__} {e}"[:300])
    if not isinstance(doc, dict):
        raise bad("the candidate must be an object / a list of settings")
    note_secrets(doc, el.redactor(row["id"]))
    if row["format"] != "json":
        registry_problems(row, doc)
        return doc
    if rel == sd.INDEX:
        index_moves(doc)
    try:
        after = problems(rel, data)
        base = problems(rel, None) if after else set()
        new = sorted(p for p in after if p[0] == row["id"] or p not in base or "could not run" in p[1])   # a set that cannot be checked is no set to write into
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
    """(old, new): the changed JSON pointers (json) or keys (env) with their values; a missing document has no values."""
    side = lambda d: {} if d is None else dict(flat(d)) if fmt == "json" else d
    o, n = side(old), side(new)
    key = lambda d, k: json.dumps(d[k], sort_keys=True) if k in d else None
    ch = [k for k in dict.fromkeys([*o, *n]) if key(o, k) != key(n, k)]
    return {k: o[k] for k in ch if k in o}, {k: n[k] for k in ch if k in n}

def text(fmt, doc, red):
    if doc is None:
        return []
    m = el.mask(doc, red)
    return json.dumps(m, indent=2, ensure_ascii=False).splitlines() if fmt == "json" else [f"{k}='{v}'" for k, v in m.items()]

def who():
    try:
        return {"user": pwd.getpwuid(os.getuid()).pw_name}
    except KeyError:   # a container run with --user: no passwd entry
        return {"user": str(os.getuid())}

def commit_event(row, key, kind, fmt, old, new, detail):
    o, n = changes(fmt, old, new)
    line = el.build(kind, key, o, n, detail=detail, who=who())
    for k, d in (("old", old), ("new", new)):
        if d is None:
            line[k] = None   # no file on that side: null, not an empty change
    el.append(line, row["id"])

def rec_of(cand, mode):
    return {"sha256": sha(cand), "mode": mode, "time": el.build("x", "x")["time"]}

# ---- commands ----
def drift_of(key, rel, tgt, cur, rec):
    """(baseline, state, problem): state ok, drift or no_baseline. Applied: sha256 and mode; never applied: the committed blob."""
    if rec:
        base, want = "applied", rec["sha256"]
    elif (blob := git_blob(rel)) is not None:
        base, want = "git", sha(blob)
    else:
        return "none", "no_baseline", None
    if cur is None or sha(cur) != want:
        return base, "drift", f"{key} " + ("is missing" if cur is None else "differs") + f" from its {base} baseline"
    mode = os.lstat(tgt).st_mode & 0o7777
    if type(rec and rec.get("mode")) is int and mode != rec["mode"]:
        return base, "drift", f"{key} has mode {mode:04o}, applied as {rec['mode']:04o}"
    return base, "ok", None

def do_apply(arg, src, dry):
    context()
    row, key, tgt, rel = target(arg)
    gate(row)
    try:
        with open(src, "rb") as f:   # the candidate is the caller's own file: a link is followed
            cand = f.read()
    except FileNotFoundError:
        raise bad("the candidate file does not exist")
    except OSError as e:
        raise bad(f"cannot read the candidate file: {e.strerror}")
    if dry:
        return dry_run(row, key, tgt, rel, cand)
    with exclusive(key):
        return apply_locked(row, key, tgt, rel, cand)

def dry_run(row, key, tgt, rel, cand):
    fmt, red = row["format"], el.redactor(row["id"])
    new_doc = validate(row, rel, cand)
    cur = read(tgt)
    old_doc, parses = parse_or_none(fmt, cur)
    note_secrets(old_doc, red)
    if cur == cand:
        st = drift_of(key, rel, tgt, cur, applied().get(key))[1]
        print(f"would record the current file as applied (it was changed by hand): {key}" if st == "drift" else f"no change: {key}")
    elif not parses:
        print(f"the current file does not parse, so there is no diff; the candidate would replace it: {key}")
    else:
        d = list(difflib.unified_diff(text(fmt, old_doc, red), text(fmt, new_doc, red), "current", "candidate", lineterm=""))
        if d:
            print("\n".join(d))
        else:
            print("no visible change: only masked values or the formatting differ")
            o, n = changes(fmt, old_doc, new_doc)
            for k in list(dict.fromkeys([*o, *n]))[:20]:
                print(f"-{qs(k)} (masked)\n+{qs(k)} (masked)")
    return 0

def apply_locked(row, key, tgt, rel, cand):
    fmt, red = row["format"], el.redactor(row["id"])
    sweep(key, tgt)
    new_doc = validate(row, rel, cand)
    cur = read(tgt)
    old_doc, parses = parse_or_none(fmt, cur)
    note_secrets(old_doc, red)
    bs = backups(key)
    if any(m is None or m.get("status") != "done" for _, m in bs):
        name, meta = next((n, m) for n, m in reversed(bs) if m is None or m.get("status") != "done")
        if cur == cand and meta is not None and meta.get("status") == "pending" and meta.get("new_sha256") == sha(cand) and (name, meta) == bs[-1]:
            return finish_apply(row, key, tgt, cand, new_doc, name, meta)
        raise bad(f"{key}: an earlier change was interrupted; run rollback {key} first")
    if cur == cand:
        rec = applied().get(key)
        if drift_of(key, rel, tgt, cur, rec)[1] != "drift":
            print(f"no change: {key}")
            return 0
        el.preflight()   # the bytes are already there (a hand edit): record them, no backup
        set_applied(key, rec_of(cand, os.lstat(tgt).st_mode & 0o7777))
        try:
            commit_event(row, key, "adopt", fmt, old_doc, new_doc, "recorded the current file as applied (it was changed by hand)")
        except BaseException:
            set_applied(key, rec)
            raise
        print(f"recorded: {key} (the current file was changed by hand; no backup)")
        return 0
    el.preflight()
    mode = os.lstat(tgt).st_mode & 0o7777 if cur is not None else 0o600 if row["owner_only"] or row["redact_keys"] else 0o644
    a, counter = load_state()
    prev, seq = a.get(key), max([counter] + [seq_of(n) for n, _ in bs]) + 1
    name = f"{seq:08d}-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    bd = os.path.join(bdir(key), name)
    meta = {"path": rel, "existed": cur is not None, "mode": mode, "sha256": sha(cur) if cur is not None else None,
            "new_sha256": sha(cand), "prev_applied": prev, "seq": seq, "status": "pending"}
    mkdir_p(os.path.dirname(bd))
    os.mkdir(bd, 0o700)
    try:
        if cur is not None:
            atomic_write(os.path.join(bd, "file"), cur, 0o600)
        atomic_write(os.path.join(bd, "meta.json"), json.dumps(meta).encode(), 0o600)
    except BaseException:
        shutil.rmtree(bd, ignore_errors=True)
        raise
    replaced = recorded = False
    try:
        atomic_write(tgt, cand, mode)
        replaced = True
        set_applied(key, rec_of(cand, mode), seq)
        recorded = True
        hashes = "" if private(row) else f"sha256 {(meta['sha256'] or 'none')[:12]} -> {sha(cand)[:12]} "
        commit_event(row, key, "apply", fmt, old_doc, new_doc, hashes + f"backup {name}" + ("" if parses else " (the current file did not parse)"))
    except BaseException:
        if replaced:
            restore(tgt, cur, mode)   # if this fails the backup stays pending: the state is unknown, rollback sorts it out
        if recorded:
            set_applied(key, prev)
        shutil.rmtree(bd, ignore_errors=True)
        raise
    meta["status"] = "done"
    atomic_write(os.path.join(bd, "meta.json"), json.dumps(meta).encode(), 0o600)
    print(f"applied: {key} (backup {name})")
    return 0

def finish_apply(row, key, tgt, cand, new_doc, name, meta):
    """A retry of an apply killed after the file was replaced: the bookkeeping that is missing is done now."""
    fmt, bd = row["format"], os.path.join(bdir(key), name)
    old_doc, _ = parse_or_none(fmt, read(os.path.join(bd, "file")) if meta.get("existed") else None)
    note_secrets(old_doc, el.redactor(row["id"]))
    el.preflight()
    set_applied(key, rec_of(cand, os.lstat(tgt).st_mode & 0o7777), meta.get("seq"))
    if not logged(key, "apply", name):
        hashes = "" if private(row) else f"sha256 {(meta.get('sha256') or 'none')[:12]} -> {sha(cand)[:12]} "
        commit_event(row, key, "apply", fmt, old_doc, new_doc, hashes + f"backup {name}")
    meta["status"] = "done"
    atomic_write(os.path.join(bd, "meta.json"), json.dumps(meta).encode(), 0o600)
    print(f"applied: {key} (backup {name}; the bookkeeping of an interrupted apply was finished)")
    return 0

def meta_problem(m):
    pa = m.get("prev_applied")
    return not (isinstance(m.get("existed"), bool) and type(m.get("mode")) is int and m.get("status") in ("pending", "done", "rollback-pending")
                and (m.get("sha256") is None or isinstance(m["sha256"], str)) and m["existed"] == (m.get("sha256") is not None)
                and isinstance(m.get("new_sha256"), str) and (pa is None or (isinstance(pa, dict) and isinstance(pa.get("sha256"), str))))

def do_rollback(arg):
    context()
    row, key, tgt, rel = target(arg)
    gate(row)
    fmt, red = row["format"], el.redactor(row["id"])
    with exclusive(key):
        sweep(key, tgt)
        junk = [n for n, m in backups(key) if m is None]
        for n in junk:   # an unfinished backup folder: nothing was replaced, so it only holds a stray copy
            shutil.rmtree(os.path.join(bdir(key), n))
        bs = [(n, m) for n, m in backups(key)]
        if not bs:
            if junk:
                print(f"removed an unfinished backup folder of {key}; nothing else to restore")
                return 0
            raise bad(f"{key}: nothing was applied through the apply command", "STL-CFG-316")
        name, meta = bs[-1]
        bd = os.path.join(bdir(key), name)
        if meta_problem(meta):
            raise bad(f"{key}: the backup {name} is damaged (its meta file is not what this tool writes); nothing was restored", "STL-CFG-316")
        cur = read(tgt)
        back = read(os.path.join(bd, "file")) if meta["existed"] else None
        if meta["existed"] and (back is None or sha(back) != meta["sha256"]):
            raise bad(f"{key}: the saved copy in backup {name} is " + ("missing" if back is None else "damaged (its sha256 differs)") + "; nothing was restored", "STL-CFG-316")
        now = sha(cur) if cur is not None else None
        if now not in (meta["new_sha256"], meta["sha256"]):
            raise bad(f"{key} was changed outside the apply command after the apply; rollback would overwrite that edit. "
                      f"Keep or revert it by hand, or apply the content you want", "STL-CFG-314")
        same = now == meta["sha256"]   # the file already holds the bytes the backup saved
        if not same and back is not None:
            try:
                validate(row, rel, back)
            except EventError as e:
                raise bad(f"{key}: the saved content no longer passes the checks ({e.problem}); apply the content you want instead", "STL-CFG-313")
        # shortcut: a restore that deletes a file (the apply created it) is not checked against the whole set, upgrade if a deleted row file can break a cross-file rule
        el.preflight()
        resumed, old_status, cur_rec = meta["status"] == "rollback-pending", meta["status"], applied().get(key)
        old_doc, _ = parse_or_none(fmt, cur)
        new_doc, _ = parse_or_none(fmt, back)
        for d in (old_doc, new_doc):
            note_secrets(d, red)
        cur_mode = os.lstat(tgt).st_mode & 0o7777 if cur is not None else 0o644
        marked = restored = recorded = False
        try:
            if not resumed:
                atomic_write(os.path.join(bd, "meta.json"), json.dumps({**meta, "status": "rollback-pending"}).encode(), 0o600)
                marked = True
            if not same:
                restore(tgt, back, meta["mode"])
                restored = True
            set_applied(key, meta["prev_applied"])
            recorded = True
            if not logged(key, "rollback", name):
                commit_event(row, key, "rollback", fmt, old_doc, new_doc, f"restored backup {name}")
        except BaseException:
            if restored:
                restore(tgt, cur, cur_mode)
            if recorded:
                set_applied(key, cur_rec)
            if marked:
                atomic_write(os.path.join(bd, "meta.json"), json.dumps({**meta, "status": old_status}).encode(), 0o600)
            raise
        shutil.rmtree(bd, ignore_errors=True)
    if same and not resumed:
        print(f"nothing to restore: {key} already matches its backup {name}")
    else:
        print(f"rolled back: {key} (backup {name}" + ("; an interrupted rollback was finished)" if resumed else ")"))
    return 0

def git_blob(rel):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_CEILING_DIRECTORIES"] = os.path.dirname(el.ROOT)   # a scratch root is never read through an outer repo
    try:
        r = subprocess.run(["git", "-C", el.ROOT, "show", f"HEAD:./{rel}"], capture_output=True, env=env, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None

def git_names(rel):
    """The names the committed folder holds (none when git cannot say)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_CEILING_DIRECTORIES"] = os.path.dirname(el.ROOT)
    try:
        r = subprocess.run(["git", "-C", el.ROOT, "ls-tree", "-z", "--name-only", f"HEAD:./{rel}"], capture_output=True, env=env, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return []
    return [n.decode("utf-8", "replace") for n in r.stdout.split(b"\0") if n] if r.returncode == 0 else []

def msg(code, problem):
    body, tag, kv = el.alert_catalog.render(code, {"problem": el.scrub(problem)})
    return body.split("\n")[1], tag, kv

def check_one(key, rel, tgt, A):
    cur, rec = read(tgt), A.get(key)
    r = {"id": key, "path": rel}
    r["baseline"], r["state"], why = drift_of(key, rel, tgt, cur, rec)
    pend = [n for n, m in backups(key) if m is None or m.get("status") != "done"]
    if pend:
        r.update(state="pending", problem=f"an earlier change was interrupted or left an unfinished backup ({qs(pend[-1])}); run rollback {key}")
    elif why:
        r["problem"] = why
    if r["state"] in ("drift", "pending"):
        r["code"] = "STL-CFG-314"
        r["message"], tag, kv = msg("STL-CFG-314", r["problem"])
        el.alert_catalog.log(tag, kv)
    return r

def refused(label, e):
    """One problem line for something check cannot read; the other rows are still checked."""
    code = e.code if isinstance(e, EventError) else "STL-CFG-313"
    why = e.problem if isinstance(e, EventError) else f"cannot be read ({type(e).__name__})"
    m, tag, kv = msg(code, f"{label}: {why}")
    el.alert_catalog.log(tag, kv)
    return {"id": label, "path": None, "baseline": "none", "state": "refused", "code": code, "message": m}

def names_of(row, only, A):
    if not sd.is_folder(row):
        return [row["id"]]
    if only:
        return [only]
    d = path(row["path"])
    names = {n for n in os.listdir(d) if n.endswith(".json")} | set(git_names(row["path"])) | {k.partition("/")[2] for k in A if k.startswith(row["id"] + "/")}
    return [f"{row['id']}/{n}" for n in sorted(names) if n.endswith(".json")]

def do_check(arg, as_json):
    context()
    A = applied()
    if arg:
        did = arg.partition("/")[0]
        rs, only = [sd.row_of(did)], (arg if "/" in arg else None)
    else:
        rs, only = sd.rows(), None
    out = []
    for row in rs:
        try:
            names = names_of(row, only, A)
        except (EventError, OSError) as e:
            out.append(refused(row["id"], e))
            continue
        for k in names:
            try:
                _, key, tgt, rel = target(k)
                out.append(check_one(key, rel, tgt, A))
            except (EventError, OSError) as e:
                out.append(refused(k, e))
    bad_ = [r for r in out if r["state"] in ("drift", "pending", "refused")]
    if as_json:
        print(json.dumps({"ok": not bad_, "files": out}, indent=2))
    else:
        for r in out:
            print(f"{r['code']} {r['message']}" if "code" in r else f"{r['state']:<12} {qs(r['id'])} (baseline {r['baseline']})")
    return 1 if bad_ else 0

def do_history(arg, as_json):
    context()
    row, key, tgt, rel = target(arg, whole=True)
    gate(row)
    evs, nbad = el.read_log()
    evs = [e for e in evs if isinstance(e.get("what"), str) and (e["what"] == key or e["what"].startswith(key + "/"))]
    keys = [key]
    if sd.is_folder(row) and "/" not in arg:
        d = bdir(key)
        keys = [f"{key}/{n}" for n in (os.listdir(d) if os.path.isdir(d) else [])]
    bs = [{"name": n, "status": (m or {}).get("status", "unreadable")} for k in keys for n, m in backups(k)]
    if nbad:
        el.say("STL-CFG-318", f"{nbad} line(s) of the event log are not event lines")
    if as_json:
        print(json.dumps({"id": key, "events": evs, "backups": bs, "unreadable_lines": nbad}, indent=2, ensure_ascii=True))
    else:
        print("\n".join(f"{qs(e.get('time'))} {qs(e.get('type'))} {qs(e['what'])} {qs(e.get('detail', ''))}" for e in evs))
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
    CTX.clear()
    el.LOG_REL = None
    unreadable = "STL-CFG-310" if o.cmd in ("check", "history") else "STL-CFG-313"   # a read command that cannot read says so, not "a change failed"
    try:
        if o.cmd == "apply":
            return do_apply(o.id, o.src, o.dry_run)
        if o.cmd == "rollback":
            return do_rollback(o.id)
        return do_check(o.id, o.json) if o.cmd == "check" else do_history(o.id, o.json)
    except EventError as e:
        return el.fail(e.code, e.problem)
    except sd.DataError as e:   # the data tool refuses a path or a row itself (leaves the root, bad index)
        return el.fail(unreadable, str(e)[:300])
    except OSError as e:
        return el.fail(unreadable, f"{type(e).__name__}: {e.strerror or ''}")
    except Exception as e:   # never a traceback, never a value: the type of the exception only
        return el.fail(unreadable, f"unexpected {type(e).__name__}")

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
