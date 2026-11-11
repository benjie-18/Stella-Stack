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
(STL-CFG-310 unreadable data, or a change that stopped half-way (the message says what was left), 311 unknown id, 312
owner-only, 313 failed/invalid, 314 drift, 315 a setting's own code, 316 no, damaged or unrecorded backup, 318 event log) and a
plain message; an unexpected exception is exit 1 and one coded line, never a traceback.
One lock covers a whole apply or rollback (validation included); the index, the gate and the target path are read again once the
lock is held. Order of an apply: event log checked writable; the backup is entered in the applied state (name and a random
token); backup folder (bytes, mode, previous applied record, the token, status pending) -> atomic replace -> applied state ->
event line (it carries the token) -> backup status done. Event line not written: file and applied state are put back, the exit
is 318. A kill in between leaves the backup with status pending: `check` reports it (314), apply refuses unless the file already
holds the candidate (then it finishes the bookkeeping and writes the event line only if none carries the backup's token),
`rollback` restores the file. A rollback marks its backup rollback-pending first, so a kill at any step is finished by the next
run, which writes the event line the killed one did not. The event log is read for a token only when a run resumes a step.
Provenance: rollback restores or deletes only from a backup folder that the applied state (written by this tool only) records
for that key, whose meta file holds the recorded token and a well-formed record; a folder the applied state does not know is
never restored from and never makes the tool delete or overwrite a file (316, the folder is named). Beyond that, the saved copy
must match its sha256, the file must hold the bytes the apply wrote or the bytes it replaced (anything else is a hand edit:
314), and the restored content must pass the same checks as a candidate. A meta file that is missing is an unfinished folder
(removed by `rollback`, which then stops); one that is present but unreadable is damage (316, nothing deleted).
Every path (a row, the folders on the way, the backup folder, the applied state, the event log, their locks) must be the real
file the index names: a symbolic link or a path that resolves elsewhere is refused (313), no two rows or index paths may be one
file (same device and inode, or the same name up to case), a file with more than one hard link or a mount point is not used, and
every file opened must be a regular file, opened without blocking, through folders checked at that moment.
Owner-only rows (index owner_only) are refused (312) for a worker: a worker marker variable is set (the names are the role
table's `worker_markers`; missing or empty = refuse), or `roles.py prove` says this process is a worker or cannot tell.
That gate is a second line only: a caller can clear its markers, shadow the board tool on PATH or detach from its parent. The
boundary is the hooks of every role refusing to run this tool at all (item W4); see the contract docs.
Values under redact_keys / secret settings never appear in a diff, event, or message (***)."""
import argparse, contextlib, datetime, difflib, hashlib, json, os, pwd, re, secrets, shutil, stat, subprocess, sys, tempfile
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import owner_config as oc
import stella_data as sd

EventError = el.EventError
SECRETS = el.SECRETS   # values seen under masked keys; scrubbed from any message
TMP = ".stella-apply."   # the prefix of this tool's own temp files
ENTRY = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._-]*\.json")   # a folder entry's file name, for every command
MAXSEQ = 99999999   # the counter in a backup folder's name has eight digits
STATUSES = ("pending", "done", "rollback-pending", "superseded")
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

def read(p, code="STL-CFG-313"):
    """The bytes of a data, state or backup file (None when missing). Only a regular file, opened without blocking and never
    through a link, of at most el.MAX_FILE bytes; anything else is one coded problem that names the file."""
    try:
        fd = el.open_file(p, os.O_RDONLY)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        raise EventError(code, f"{qs(os.path.relpath(p, el.ROOT))}: {el.why(e)}")
    with os.fdopen(fd, "rb") as f:
        b = f.read(el.MAX_FILE + 1)
    if len(b) > el.MAX_FILE:
        raise EventError(code, f"{qs(os.path.relpath(p, el.ROOT))}: larger than {el.MAX_FILE} bytes")
    return b

def try_read(p):
    try:
        return read(p, "STL-CFG-316")
    except EventError:
        return None

def mkdir_p(p):
    """p and the folders on the way, each created 0700 (they hold or lead to full copies of owner files). A folder another
    run made in between is fine."""
    if not os.path.isdir(p):
        mkdir_p(os.path.dirname(p))
        try:
            os.mkdir(p, 0o700)
        except FileExistsError:
            if not os.path.isdir(p):
                raise

def atomic_write(p, data, mode):
    """Temp file (0600) in the same folder, fsync, rename, fsync the folder. Everything is done relative to the folder as
    opened (checked to be where its path says), so a folder swapped for a link afterwards changes nothing."""
    d, name = os.path.split(p)
    os.makedirs(d, exist_ok=True)
    dfd = el.open_dir(d)
    try:
        tmp = TMP + os.urandom(8).hex()
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
                os.fchmod(f.fileno(), mode)
            os.replace(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd)
        except BaseException:
            with contextlib.suppress(OSError):
                os.unlink(tmp, dir_fd=dfd)
            raise
        os.fsync(dfd)
    finally:
        os.close(dfd)

def unlink(p):
    d, name = os.path.split(p)
    try:
        dfd = el.open_dir(d)
    except FileNotFoundError:
        return
    try:
        os.unlink(name, dir_fd=dfd)
    except FileNotFoundError:
        pass
    finally:
        os.close(dfd)

def restore(p, data, mode):
    if data is None:
        unlink(p)
    else:
        atomic_write(p, data, mode)

def drop_backup(bd):
    """Remove a backup folder. The meta file goes first: a kill in between leaves a folder that reads as unfinished (the next
    rollback removes it), never a damaged one."""
    unlink(os.path.join(bd, "meta.json"))
    shutil.rmtree(bd, ignore_errors=True)

def mounted(p):
    """True when p is a mount point (a bind-mounted file looks like any file by device and inode)."""
    with open("/proc/self/mountinfo", encoding="utf-8", errors="replace") as f:
        return any(re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), l.split()[4]) == p for l in f if len(l.split()) > 4)

# ---- the index, read once ----
def alias_problem(idx, rows):
    """None, or why the paths of an index are not each their own real file: the same file by name (up to case) or by device and
    inode, a file with more than one hard link, a mount point, a path inside a folder that is another path of the index."""
    named = [("the event log", idx["event_log"]), ("the backup folder", idx["backup_dir"]), ("the applied state", idx["applied_state"])] \
        + [(f"the file of {r['id']}", r["path"]) for r in rows]
    seen, found = {}, []
    for what, rel in named:
        p = os.path.realpath(os.path.join(el.ROOT, rel))   # confinement and links are refused where a path is used (el.path)
        try:
            st = os.stat(p)
        except OSError:
            st = None
        keys = [("name", p.casefold())] + ([("file", st.st_dev, st.st_ino)] if st else [])
        for k in keys:
            if k in seen:
                return f"{what} and {seen[k]} are the same file (one name for it, or a hard link or a link); the index must name each file once"
        seen.update(dict.fromkeys(keys, what))
        found.append((what, p, st))
    for what, p, st in found:
        if st and stat.S_ISREG(st.st_mode) and st.st_nlink > 1:
            return f"{what} has more than one hard link, so it may be another path's file; remove the extra link"
        if st and stat.S_ISREG(st.st_mode) and mounted(p):
            return f"{what} is a mount point; it is not used"
    for what, p, st in found:
        if st and stat.S_ISDIR(st.st_mode):
            for w2, p2, _ in found:
                if w2 != what and p2.casefold().startswith(p.casefold().rstrip(os.sep) + os.sep):
                    return f"{w2} lies inside {what}"
    return None

def context():
    """The index and its rows, read once per process, with the checks that no two paths of the index are one file."""
    if CTX:
        return CTX
    idx, rows = sd.load(sd.INDEX), sd.rows()
    el.LOG_REL = idx["event_log"]
    why = alias_problem(idx, rows)
    if why:
        raise bad(why)
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
    p = path(rel)
    if slash:   # names that differ only by case are one name: one file never gets two keys
        for n in os.listdir(os.path.dirname(p)):
            if n != entry and n.casefold() == entry.casefold():
                raise bad(f"{json.dumps(arg)} differs only by case from the existing {qs(n)}; they are one name, use that one")
    try:
        st = os.lstat(p)
    except FileNotFoundError:
        st = None
    if st and stat.S_ISREG(st.st_mode) and (st.st_nlink > 1 or mounted(p)):
        raise bad(f"{qs(rel)} has more than one hard link or is a mount point, so it may be another path's file; it is not read")
    return row, (arg if slash else did), p, rel

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

def relock(arg, row):
    """Under the lock the index, the row, the target path and the gate are read again: a run that waited acts on the state of
    the moment (an index applied meanwhile, a folder swapped meanwhile)."""
    CTX.clear()
    el.LOG_REL = None
    context()
    row2, key, tgt, rel = target(arg)
    if row2 != row:
        gate(row2)
    return row2, key, tgt, rel

def private(row):
    """True when no hash of the file may reach a log: it has redact keys or stores a secret registry setting (owner-only alone does not)."""
    return bool(row["redact_keys"]
                or any(e["sensitivity"] == "secret" and e["store"]["data"] == row["id"] for e in el.registry()["entries"]))

# ---- the applied state, backups, locks ----
def state_path():
    return path(context()["idx"]["applied_state"])

def rec_ok(v):
    return isinstance(v, dict) and isinstance(v.get("sha256"), str) and (v.get("adopt") is None or isinstance(v["adopt"], str))

def load_state():
    """({key: record}, counter, {key: {backup name: token}}). The counter orders the backups; a record is {sha256, mode, time}
    (and `adopt`, a token, between an adopt's state write and its event line). The third is what this tool recorded for each
    apply: only these folders are ever restored from. shortcut: a counter beyond what the folder name carries (or negative)
    counts as 0, the backups' own names order them; upgrade: none needed."""
    raw = read(state_path(), "STL-CFG-310")
    if raw is None:
        return {}, 0, {}
    try:
        d = json.loads(raw)
        a, c, b = d["applied"], d.get("counter", 0), d.get("backups", {})
        if (not isinstance(a, dict) or type(c) is not int or not isinstance(b, dict) or not all(rec_ok(v) for v in a.values())
                or not all(isinstance(v, dict) and all(isinstance(t, str) for t in v.values()) for v in b.values())):
            raise TypeError
        return a, (c if 0 <= c <= MAXSEQ else 0), b
    except (ValueError, KeyError, TypeError, RecursionError):
        raise bad("the applied state is unreadable; nothing was changed", "STL-CFG-310")

def applied():
    return load_state()[0]

def update_state(fn, seq=0):
    p = state_path()
    mkdir_p(os.path.dirname(p))
    with el.locked(p + ".lock"):
        a, c, b = load_state()
        fn(a, b)
        atomic_write(p, json.dumps({"schema_version": 1, "applied": a, "backups": b, "counter": max(c, seq)}, indent=1).encode(), 0o600)

def set_applied(key, rec, seq=None):
    def f(a, b):
        if rec is None:
            a.pop(key, None)
        else:
            a[key] = rec
    update_state(f, seq or 0)

def register(key, name, token, seq):
    update_state(lambda a, b: b.setdefault(key, {}).update({name: token}), seq)

def unregister(key, *names):
    def f(a, b):
        for n in names:
            b.get(key, {}).pop(n, None)
        if not b.get(key, True):
            del b[key]
    update_state(f)

def bdir(key):
    return path(os.path.join(context()["idx"]["backup_dir"], key))

def seq_of(name):
    m = re.match(r"(\d{1,8})-", name)
    return int(m[1]) if m else -1

def scan(key):
    """(good, junk, strange, stale) for the backup folders of a key. good: [(name, meta)] oldest first, recorded in the applied
    state with the token in their meta (meta {} = its file is unreadable: damage); junk: names whose meta file is missing
    (a kill before it was written: unfinished); strange: names with a meta file that the applied state does not know or whose
    token differs (never used); stale: recorded names with no folder."""
    d, known, good, junk, strange, here = bdir(key), load_state()[2].get(key, {}), [], [], [], set()
    for n in os.listdir(d) if os.path.isdir(d) else []:
        p = os.path.join(d, n)
        if os.path.islink(p) or not os.path.isdir(p):
            continue
        here.add(n)
        try:
            raw = read(os.path.join(p, "meta.json"), "STL-CFG-316")
            m = None if raw is None else json.loads(raw)
        except (EventError, ValueError, RecursionError):
            m = {}
        if m is None:
            junk.append(n)
            continue
        m = m if isinstance(m, dict) else {}
        (good if n in known and (not m or known[n] == m.get("token")) else strange).append((n, m))
    order = lambda x: (seq_of(x[0] if isinstance(x, tuple) else x), x[0] if isinstance(x, tuple) else x)
    return sorted(good, key=order), sorted(junk, key=order), sorted(strange, key=order), sorted(n for n in known if n not in here)

def live_of(good):
    return [x for x in good if x[1].get("status") != "superseded"]

def backed_ids():
    """Ids (first part of a key) that still have a backup the rollback can use (a superseded one is history only)."""
    return sorted({k.partition("/")[0] for k in load_state()[2] if live_of(scan(k)[0])})

@contextlib.contextmanager
def exclusive(key):
    """One lock for the whole apply or rollback (every id: the cross-file rules see one change at a time), taken before the
    validation. The row's own lock file is kept as well (a second name for the same wait)."""
    lk = path(os.path.join(context()["idx"]["backup_dir"], ".locks"))
    mkdir_p(lk)
    with el.locked(os.path.join(lk, ".all.lock")), el.locked(os.path.join(lk, key.replace("/", "__") + ".lock")):
        yield

def stage_root():
    return path(os.path.join(context()["idx"]["backup_dir"], ".stage"))

def sweep(key, tgt):
    """A temp file of this tool's own name, found while holding the lock, is the leftover of a crash and holds file bytes; so is
    a staging folder whose run is gone (its name starts with the process id)."""
    dirs = {os.path.dirname(tgt), os.path.dirname(state_path())} | {r for r, _, _ in os.walk(bdir(key))}
    for d in dirs:
        for n in os.listdir(d) if os.path.isdir(d) else []:
            f = os.path.join(d, n)
            if n.startswith(TMP) and os.path.isfile(f) and not os.path.islink(f):
                with contextlib.suppress(OSError):
                    os.unlink(f)
    sr = stage_root()
    for n in os.listdir(sr) if os.path.isdir(sr) else []:
        try:
            os.kill(int(n.partition("-")[0]), 0)
        except ProcessLookupError:
            shutil.rmtree(os.path.join(sr, n), ignore_errors=True)
        except (ValueError, PermissionError):
            pass

def logged(key, kind, token):
    """True when a line of this kind for this key carries the token: the token is random, written into the backup's meta before
    the line exists, so no line written by anyone else can match it. Asked only when a run resumes an unfinished step."""
    evs, _ = el.read_log()
    return any(e.get("what") == key and e.get("type") == kind and token in str(e.get("detail", "")) for e in evs)

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
        doc = json.loads(data.decode("utf-8"), object_pairs_hook=obj, parse_constant=const)
        if el.depth(doc) > sd.MAX_DEPTH:
            raise ValueError("nested too deeply")
        return doc
    cfg, text = {}, data.decode("utf-8")
    if text.startswith("\ufeff") or "\r" in text:   # the shell reads `. file` byte for byte: a BOM or a CR is part of a name or value there
        raise ValueError("a byte-order mark or a carriage return (a shell would read the value differently)")
    for n, line in enumerate(text.split("\n"), 1):
        if not line.strip(" \t") or line.lstrip(" \t").startswith("#"):
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

note_secrets = el.note_secrets


def stage(tmp, rel, data):
    """A scratch root holding what the whole-set check reads: index, schemas, role table and the hook files it names, every json
    row; the candidate (when not None) in place of its file. Every path is confined to the root first; a folder is copied entry
    by entry, only plain regular files of the entry rule, none larger than the read limit (a stray entry is left out here and
    reported by `check`, it does not refuse an unrelated change). The candidate index was validated before this is called."""
    idx = sd.load(sd.INDEX)
    docs = [idx] + ([json.loads(data)] if data is not None and rel == sd.INDEX else [])
    srcs = {sd.INDEX, sd.SCHEMAS}
    for d in docs:
        srcs |= {d["role_table"]} | {r["path"] for r in d["files"] if r["format"] == "json"}
        table = sd.load(d["role_table"]) if os.path.isfile(path(d["role_table"])) else {}
        srcs |= {h["file"] for r in (table.get("roles") or {}).values() if isinstance(r, dict) for h in r.get("hooks", [])
                 if isinstance(h, dict) and isinstance(h.get("file"), str)}   # the files the table names: the table check looks them up
    def put(s, b):
        dst = os.path.join(tmp, s)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as f:
            f.write(b)
    for s in srcs:
        src = path(s)
        if os.path.isdir(src):
            for n in sorted(os.listdir(src)):
                if ENTRY.fullmatch(n) and (b := try_read(os.path.join(src, n))) is not None:
                    put(f"{s}/{n}", b)
        elif (b := try_read(src)) is not None:
            put(s, b)
    if data is not None:
        put(rel, data)

def problems(rel, data):
    root = stage_root()
    mkdir_p(root)
    tmp = tempfile.mkdtemp(prefix=f"{os.getpid()}-", dir=root)   # under the backup folder, where the sweep of a later run finds it
    try:
        stage(tmp, rel, data)
        r = subprocess.run([sys.executable, "-I", os.path.join(BIN, "stella_data.py"), "check", "--json"],
                           env={**os.environ, "STELLA_ROOT": tmp}, capture_output=True, text=True, timeout=120)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if r.returncode not in (0, 1):
        raise bad("the validity check could not run")
    return {(p["data"], p["problem"]) for p in json.loads(r.stdout)["problems"]}

def registry_problems(row, doc):
    """An env file against the registry: every setting stored in this data file is checked with the registry's own type and
    validation (stella_data.setting_problems on the value as the default), and a setting with no default must be present.
    Keys the registry does not know stay allowed. A failure carries that entry's own code. An integer must be plain decimal
    (a sign or a leading zero is read differently by the shell users of the file)."""
    for e in el.registry()["entries"]:
        if e["store"]["data"] != row["id"]:
            continue
        k = e["store"]["key"]
        if k not in doc:
            if e["default"] is None:
                raise EventError(e["code"], f"{k} must be present in {row['id']} (it has no default)")
            continue
        v, t = doc[k], e["type"]
        if t == "integer" and not re.fullmatch(r"0|[1-9][0-9]*", v):
            raise EventError(e["code"], f"{k}: an integer is written as plain decimal digits (no sign, no leading zero)")
        # shortcut: env values are text; only plain integers, finite numbers and true/false are converted, any other text stays a string
        if t == "integer":
            v = int(v)
        elif t == "number" and re.fullmatch(r"-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?", v):
            v = float(v)
        elif t == "boolean" and v in ("true", "false"):
            v = v == "true"
        errs = sd.setting_problems({**e, "default": v, "sensitivity": "plain"})   # plain: a secret has no default, but the value is checked
        if errs:
            raise EventError(e["code"], f"{k}: " + re.sub(r"^default (\$: )?", "", errs[0]))

def index_moves(doc):
    """Applying the index through itself: the candidate must be a valid index whose paths are each their own file, the paths the
    running apply already uses cannot move under it, the index keeps its own row, and no row with a backup may go."""
    try:
        sd.checked(doc, sd.INDEX, "data-files")
    except sd.DataError as e:
        raise bad(f"the candidate index is not valid: {str(e)[:200]}")
    idx = context()["idx"]
    for k in ("event_log", "backup_dir", "applied_state"):
        if doc.get(k) != idx[k]:
            raise bad(f"the index cannot change {k} through its own apply (the backup, state and log of this run would move under it); "
                      "stop everything that uses the tool, move the file by hand and edit the index by hand, then run check")
    files = doc["files"]
    if not any(r.get("path") == sd.INDEX for r in files):
        raise bad("the candidate index has no row for the index itself; keep it")
    why = alias_problem(doc, files)
    if why:
        raise bad(f"the candidate index: {why}")
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
    """One event line. The detail is the tool's own text (hashes, the backup name, the token): it is not scrubbed by substring,
    which could garble the name or the token when a masked value is a few characters long."""
    o, n = changes(fmt, old, new)
    line = el.build(kind, key, o, n, detail=detail, who=who())
    for k, d in (("old", old), ("new", new)):
        if d is None:
            line[k] = None   # no file on that side: null, not an empty change
    el.append(line, row["id"], scrub_detail=False)

def rec_of(cand, mode):
    return {"sha256": sha(cand), "mode": mode, "time": el.build("x", "x")["time"]}

def hashes(row, old, new):
    return "" if private(row) else f"sha256 {(old or 'none')[:12]} -> {new[:12]} "

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

def meta_problem(m, name):
    """True when a meta file is not what this tool writes: every field is checked before it is used."""
    pa, sq = m.get("prev_applied"), m.get("seq")
    return not (isinstance(m.get("existed"), bool) and type(m.get("mode")) is int and m.get("status") in STATUSES
                and (m.get("sha256") is None or isinstance(m["sha256"], str)) and m["existed"] == (m.get("sha256") is not None)
                and isinstance(m.get("new_sha256"), str) and (pa is None or rec_ok(pa)) and isinstance(m.get("token"), str)
                and type(sq) is int and 0 < sq <= MAXSEQ and sq == seq_of(name))

def pending_action(key, cur, cand, good, junk, strange, rec):
    """(action, text, code) for what an unfinished step of this key means for an apply of cand (None: for `check`):
    none | refuse | finish (an apply killed after the replace, repeated) | adopt (the file was edited by hand since the
    interrupted change and cand holds those bytes) | finish_adopt (an adopt killed before its event line)."""
    if strange:
        return "refuse", (f"{key}: the backup folder {qs(strange[0][0])} is not one this tool recorded in the applied state (or its token "
                          "differs); it is never restored from and nothing was changed. Look at it, then remove it by hand"), "STL-CFG-316"
    if junk:
        return "refuse", (f"{key}: an unfinished backup folder ({qs(junk[-1])}) was left by a stopped run before anything was replaced; "
                          f"`rollback {key}` removes it and restores nothing"), "STL-CFG-313"
    if rec and rec.get("adopt"):
        if cur is not None and cur == cand:
            return "finish_adopt", "", ""
        return "refuse", (f"{key}: recording a hand edit was interrupted before its event line; apply a file that holds the "
                          f"file's current bytes (`apply {key} --from <file>`) to finish it"), "STL-CFG-313"
    live = live_of(good)
    open_ = [x for x in live if x[1].get("status") != "done"]
    if not open_:
        return "none", "", ""
    name, m = open_[-1]
    if meta_problem(m, name):
        return "refuse", (f"{key}: the backup {qs(name)} is damaged (its meta file is not what this tool writes); nothing was "
                          "changed. The saved copy in that folder is kept: look at it by hand"), "STL-CFG-316"
    if (name, m) == live[-1] and m["status"] == "pending" and cur is not None and cur == cand and m["new_sha256"] == sha(cand):
        return "finish", "", ""
    now = sha(cur) if cur is not None else None
    if now in (m["new_sha256"], m["sha256"]):
        return "refuse", (f"{key}: an earlier change was interrupted; run `rollback {key}` first (it puts the file back to the saved "
                          "bytes or finishes what was started, and writes the missing event line)"), "STL-CFG-313"
    if cur is not None and cur == cand:
        return "adopt", "", ""
    return "refuse", (f"{key}: an earlier change was interrupted and the file was edited by hand since. Apply a file that holds its "
                      f"current bytes (`apply {key} --from <file>`) to record them (the interrupted backup is then set aside), "
                      "or put the file back by hand"), "STL-CFG-313"

def do_apply(arg, src, dry):
    context()
    row, key, tgt, rel = target(arg)
    gate(row)
    try:   # the candidate is the caller's own file: a link is followed, a FIFO or device is not waited for
        fd = os.open(src, os.O_RDONLY | os.O_NONBLOCK)
    except FileNotFoundError:
        raise bad("the candidate file does not exist")
    except OSError as e:
        raise bad(f"cannot read the candidate file: {e.strerror}")
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise bad("the candidate is not a regular file")
        cand = f.read(el.MAX_FILE + 1)
    if len(cand) > el.MAX_FILE:
        raise bad(f"the candidate is larger than {el.MAX_FILE} bytes")
    if dry:
        return dry_run(row, key, tgt, rel, cand)
    with exclusive(key):
        return apply_locked(*relock(arg, row), cand)

def dry_run(row, key, tgt, rel, cand):
    fmt, red = row["format"], el.redactor(row["id"])
    new_doc = validate(row, rel, cand)
    tgt = path(rel)
    cur = read(tgt)
    old_doc, parses = parse_or_none(fmt, cur)
    note_secrets(old_doc, red)
    good, junk, strange, _ = scan(key)
    act, why, code = pending_action(key, cur, cand, good, junk, strange, applied().get(key))
    if act == "refuse":
        raise EventError(code, why)
    if act in ("finish", "finish_adopt", "adopt"):
        print({"finish": f"would finish the interrupted apply of {key}: the missing bookkeeping and event line are written, no new backup",
               "finish_adopt": f"would finish recording the hand edit of {key}: the missing event line is written",
               "adopt": f"would record the current file as applied (it was changed by hand since an interrupted change) and set the "
                        f"interrupted backup of {key} aside"}[act])
        return 0
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

def prior_doc(fmt, key, good, rec):
    """The document last applied (the newest backup keeps a copy of the bytes its apply wrote), None when that is not known."""
    live = live_of(good)
    if rec and live and not meta_problem(live[-1][1], live[-1][0]):
        b = try_read(os.path.join(bdir(key), live[-1][0], "file.applied"))
        if b is not None and sha(b) == rec["sha256"]:
            return parse_or_none(fmt, b)[0]
    return None

def adopt(row, key, tgt, cand, new_doc, rec, good, resume):
    """Record bytes a hand edit put there: the applied state first (with a marker token), then the event line, then the older
    backups are set aside (they cannot be rolled back over a recorded edit) and the marker is cleared. A kill in between is
    finished by the next run, which writes the one `adopt` line."""
    fmt, red = row["format"], el.redactor(row["id"])
    el.preflight()
    mode = os.lstat(tgt).st_mode & 0o7777
    old_doc = prior_doc(fmt, key, good, None if resume else rec)
    note_secrets(old_doc, red)
    if resume:
        token = rec["adopt"]
    else:
        token = secrets.token_hex(16)
        set_applied(key, {**rec_of(cand, mode), "adopt": token})
    try:
        if not (resume and logged(key, "adopt", token)):
            commit_event(row, key, "adopt", fmt, old_doc, new_doc, hashes(row, rec and rec["sha256"], sha(cand))
                         + f"recorded the current file as applied (it was changed by hand); older backups set aside; token {token}"
                         + ("" if old_doc is not None else " (the content applied before is not known)"))
    except BaseException:
        if not resume:
            set_applied(key, rec)
        raise
    for n, m in good:
        if m.get("status") != "superseded" and not meta_problem(m, n):
            atomic_write(os.path.join(bdir(key), n, "meta.json"), json.dumps({**m, "status": "superseded"}).encode(), 0o600)
    set_applied(key, rec_of(cand, mode))
    print(f"recorded: {key} (the current file was changed by hand; no backup; the older backups are kept as history only)")
    return 0

def apply_locked(row, key, tgt, rel, cand):
    fmt, red = row["format"], el.redactor(row["id"])
    sweep(key, tgt)
    new_doc = validate(row, rel, cand)
    tgt = path(rel)   # validation took time: the folders on the way are looked at again before the read
    cur = read(tgt)
    old_doc, parses = parse_or_none(fmt, cur)
    note_secrets(old_doc, red)
    rec = applied().get(key)
    good, junk, strange, _ = scan(key)
    act, why, code = pending_action(key, cur, cand, good, junk, strange, rec)
    if act == "refuse":
        raise EventError(code, why)
    if act == "finish":
        return finish_apply(row, key, tgt, cand, new_doc, *live_of(good)[-1])
    if act in ("adopt", "finish_adopt"):
        return adopt(row, key, tgt, cand, new_doc, rec, good, act == "finish_adopt")
    if cur == cand:
        if drift_of(key, rel, tgt, cur, rec)[1] != "drift":
            print(f"no change: {key}")
            return 0
        return adopt(row, key, tgt, cand, new_doc, rec, good, False)   # the bytes are already there (a hand edit): record them, no backup
    el.preflight()
    mode = os.lstat(tgt).st_mode & 0o7777 if cur is not None else 0o600 if row["owner_only"] or row["redact_keys"] else 0o644
    a, counter, _ = load_state()
    prev, seq = a.get(key), max([counter] + [seq_of(n) for n, _ in good]) + 1
    if seq > MAXSEQ:
        raise bad(f"{key}: the backup counter reached {MAXSEQ}, the most a backup folder name carries. Repair: roll the backups of "
                  f"{key} back or remove the ones you no longer need by hand, then set `counter` in the applied state to 0")
    name = f"{seq:08d}-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    token, bd = secrets.token_hex(16), os.path.join(bdir(key), name)
    meta = {"path": rel, "existed": cur is not None, "mode": mode, "sha256": sha(cur) if cur is not None else None,
            "new_sha256": sha(cand), "prev_applied": prev, "seq": seq, "token": token, "status": "pending"}
    mkdir_p(os.path.dirname(bd))
    replaced = recorded = False
    try:
        register(key, name, token, seq)   # the applied state knows the backup before the file is touched: a kill leaves a known folder
        os.mkdir(bd, 0o700)
        if cur is not None:
            atomic_write(os.path.join(bd, "file"), cur, 0o600)
        atomic_write(os.path.join(bd, "file.applied"), cand, 0o600)   # the bytes this apply writes: old side of a rollback's line
        atomic_write(os.path.join(bd, "meta.json"), json.dumps(meta).encode(), 0o600)
        tgt = path(rel)
        atomic_write(tgt, cand, mode)
        replaced = True
        set_applied(key, rec_of(cand, mode), seq)
        recorded = True
        commit_event(row, key, "apply", fmt, old_doc, new_doc, hashes(row, meta["sha256"], sha(cand))
                     + f"backup {name} token {token}" + ("" if parses else " (the current file did not parse)"))
    except BaseException as e:
        try:
            if replaced:
                restore(tgt, cur, mode)
            if recorded:
                set_applied(key, prev)
            drop_backup(bd)
            unregister(key, name)
        except BaseException as e2:
            raise EventError("STL-CFG-310", f"{key}: the change failed ({el.why(e)}) and putting things back failed too ({el.why(e2)}); "
                             f"the file and the backup {name} are as the change left them; run `rollback {key}` to sort it out") from e
        raise
    meta["status"] = "done"
    try:
        atomic_write(os.path.join(bd, "meta.json"), json.dumps(meta).encode(), 0o600)
    except OSError as e:
        raise EventError("STL-CFG-310", f"{key}: the change was applied and logged, but its backup {name} could not be marked done "
                         f"({el.why(e)}); apply the same file again to finish")
    print(f"applied: {key} (backup {name})")
    return 0

def finish_apply(row, key, tgt, cand, new_doc, name, meta):
    """A retry of an apply killed after the file was replaced: the bookkeeping that is missing is done now."""
    fmt, bd = row["format"], os.path.join(bdir(key), name)
    old_doc, _ = parse_or_none(fmt, read(os.path.join(bd, "file"), "STL-CFG-316") if meta["existed"] else None)
    note_secrets(old_doc, el.redactor(row["id"]))
    el.preflight()
    set_applied(key, rec_of(cand, os.lstat(tgt).st_mode & 0o7777), meta["seq"])
    if not logged(key, "apply", meta["token"]):
        commit_event(row, key, "apply", fmt, old_doc, new_doc, hashes(row, meta["sha256"], sha(cand)) + f"backup {name} token {meta['token']}")
    meta["status"] = "done"
    atomic_write(os.path.join(bd, "meta.json"), json.dumps(meta).encode(), 0o600)
    print(f"applied: {key} (backup {name}; the bookkeeping of an interrupted apply was finished)")
    return 0

def do_rollback(arg):
    context()
    row, key, tgt, rel = target(arg)
    gate(row)
    with exclusive(key):
        row, key, tgt, rel = relock(arg, row)
        fmt, red = row["format"], el.redactor(row["id"])
        sweep(key, tgt)
        good, junk, strange, stale = scan(key)
        if strange:
            _, why, code = pending_action(key, None, None, good, junk, strange, None)
            raise EventError(code, why)
        if junk:   # an unfinished backup folder: nothing was replaced, so it only holds a stray copy. Removing it is a step of its own.
            for n in junk:
                drop_backup(os.path.join(bdir(key), n))
            unregister(key, *junk, *stale)
            print(f"removed the unfinished backup folder {', '.join(qs(n) for n in junk)} of {key}; nothing was restored "
                  f"(the file was not touched). Run rollback {key} again to undo the last change")
            return 0
        if stale:   # recorded, but the folder is gone
            unregister(key, *stale)
        live = live_of(good)
        if not live:
            raise bad(f"{key}: nothing was applied through the apply command" + (
                " that a rollback can still undo (the earlier backups were set aside when a hand edit was recorded; they stay in the backup folder as history)"
                if good else ""), "STL-CFG-316")
        name, meta = live[-1]
        bd = os.path.join(bdir(key), name)
        if meta_problem(meta, name):
            raise bad(f"{key}: the backup {name} is damaged (its meta file is not what this tool writes); nothing was restored or deleted", "STL-CFG-316")
        tgt = path(rel)
        cur = read(tgt)
        back = read(os.path.join(bd, "file"), "STL-CFG-316") if meta["existed"] else None
        if meta["existed"] and (back is None or sha(back) != meta["sha256"]):
            raise bad(f"{key}: the saved copy in backup {name} is " + ("missing" if back is None else "damaged (its sha256 differs)") + "; nothing was restored", "STL-CFG-316")
        now = sha(cur) if cur is not None else None
        if now not in (meta["new_sha256"], meta["sha256"]):
            raise bad(f"{key} was changed outside the apply command after the apply; rollback would overwrite that edit. "
                      f"Keep or revert it by hand, or apply a file that holds its current bytes (`apply {key} --from <file>`) to record them", "STL-CFG-314")
        same = now == meta["sha256"]   # the file already holds the bytes the backup saved
        if not same and back is not None:
            try:
                validate(row, rel, back)
            except EventError as e:
                raise bad(f"{key}: the saved content no longer passes the checks ({e.problem}); apply the content you want instead", "STL-CFG-313")
        # shortcut: a restore that deletes a file (the apply created it) is not checked against the whole set, upgrade if a deleted row file can break a cross-file rule
        el.preflight()
        resumed, old_status, cur_rec = meta["status"] == "rollback-pending", meta["status"], applied().get(key)
        was = try_read(os.path.join(bd, "file.applied"))   # the bytes the apply wrote: the old side of the line, also when the restore already happened
        was = was if was is not None and sha(was) == meta["new_sha256"] else cur
        old_doc, _ = parse_or_none(fmt, was)
        new_doc, _ = parse_or_none(fmt, back)
        for d in (old_doc, new_doc):
            note_secrets(d, red)
        cur_mode = os.lstat(tgt).st_mode & 0o7777 if cur is not None else 0o644
        new_rec = meta["prev_applied"]
        if new_rec is None and back is not None and git_blob(rel) is None:   # a file git does not track keeps the restored hash as its baseline
            new_rec = rec_of(back, meta["mode"])
        marked = restored = recorded = False
        try:
            if not resumed:
                atomic_write(os.path.join(bd, "meta.json"), json.dumps({**meta, "status": "rollback-pending"}).encode(), 0o600)
                marked = True
            if not same:
                tgt = path(rel)
                restore(tgt, back, meta["mode"])
                restored = True
            set_applied(key, new_rec)
            recorded = True
            if not (resumed and logged(key, "rollback", meta["token"])):
                commit_event(row, key, "rollback", fmt, old_doc, new_doc,
                             (f"nothing to restore: the file already held the saved bytes of backup {name}" if same and not resumed
                              else f"restored backup {name}") + f" token {meta['token']}")
        except BaseException:
            if restored:
                restore(tgt, cur, cur_mode)
            if recorded:
                set_applied(key, cur_rec)
            if marked:
                atomic_write(os.path.join(bd, "meta.json"), json.dumps({**meta, "status": old_status}).encode(), 0o600)
            raise
        drop_backup(bd)
        unregister(key, name)
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
    good, junk, strange, _ = scan(key)
    act, text_, code = pending_action(key, cur, None, good, junk, strange, rec)
    if act != "none":
        r.update(state="refused" if code == "STL-CFG-316" else "pending", problem=text_, code="STL-CFG-316" if code == "STL-CFG-316" else "STL-CFG-314")
    elif why:
        r["problem"] = why
    if r["state"] in ("drift", "pending", "refused"):
        r["code"] = r.get("code", "STL-CFG-314")
        r["message"], tag, kv = msg(r["code"], r["problem"])
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
        if only and not sd.is_folder(rs[0]):
            raise bad(f"{did} is a single file: give just its id")
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
    bs = []
    for k in keys:
        good, junk, strange, _ = scan(k)
        bs += [{"name": n, "status": m.get("status", "unreadable")} for n, m in good] + [{"name": n, "status": "unfinished"} for n in junk] \
            + [{"name": n, "status": "unrecorded"} for n, _ in strange]
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
