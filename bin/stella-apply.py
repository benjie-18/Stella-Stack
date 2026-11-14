#!/usr/bin/env python3
"""The generic apply contract (core contract item 8, spec E9), stdlib only. Works for every row of .stella/data-files.json
(format json, or env for KEY='value' files); a folder row takes <id>/<entry file name>. No data file is special-cased.
CLI: stella-apply.py apply <id> --from <file> [--dry-run]   validate the candidate (the whole-set check with the candidate in
                                                           place of its file), back up, replace atomically, one event line
     stella-apply.py check [<id>] [--json]                  drift: sha256 or mode differs from the last applied one, or (never
                                                           applied) the sha256 from the committed blob; no baseline is not drift
                                                           (`--check` is accepted for `check`)
     stella-apply.py rollback <id>                          restore the newest backup, one event line
     stella-apply.py history <id> [--json]                  the event lines of <id> and its backups
Exit: 0 ok (a no-change apply too); 1 refused or failed, or drift (check); 2 usage. Every failure prints its catalog code and a
plain message (310 unreadable data, 311 unknown id, 312 owner-only, 313 a change refused before it started, 314 drift, 315 a
setting's own code, 316 no, damaged or unrecorded backup, 318 event log, 321 a change that stopped after it started (what is
left and the one command that finishes or undoes it), 322 a read command refused, 323 an unfinished step seen by check); an
unexpected exception or an interrupt (Ctrl-C, SIGTERM) is exit 1 and one coded line, never a traceback.
Every write of a command is entered in STEPS, with how to undo it, BEFORE it starts (did); a failure or an interrupt undoes
them, newest first, up to the first that stays (an event line in the log, a removed folder, a file someone wrote over), and
the one coded line says what is left (failed/told). One lock is held from before the command's first read of the row until its
line is printed (exclusive): the validation, every step, every undo, the disk read that makes the failure line and the line;
the index, the gate and the target path are read again once it is held. Order of an apply: the candidate is validated; the
file is read and the start state taken at one point (begin); event log checked writable and the line built and judged; the
backup is entered in the applied state (name, token, and what the saved copy is: its hash, whether the file existed, its
mode); backup folder (bytes, mode, previous applied record, the token) -> atomic replace (the file compared once more right
before the rename) -> applied state -> event line (it carries the backup's name and token) -> `done` in the backup's record of
the applied state. The state of a backup (pending, done, rollback-pending, set aside) is word() of that record alone; the
meta file's status decides nothing. A kill in between leaves the backup pending: `check` reports it (323), apply refuses
unless the file already holds the candidate (then it finishes the bookkeeping and writes the event line only if none has the
backup's name and token), `rollback` restores the file (writing the apply line first when the apply's replace happened and
its line is missing). A rollback marks its backup in the applied state with a fresh token first, so a kill at any step is
finished by the next run, which writes the event line the killed one did not. When the event log is read: logged, state_of.
Provenance: rollback restores or deletes only from a backup folder that the applied state (written by this tool only) records
for that key, whose meta file holds the recorded token, hash, existence and mode; a folder the applied state does not know is
never restored from and never makes the tool delete or overwrite a file (316, the folder's path is given). Beyond that, the
saved copy must match its sha256, the file must hold the bytes the apply wrote or the bytes it replaced (anything else is a
hand edit: 314), and restored content that parses must pass the checks a candidate passes (bytes the reader cannot parse
were in use so and are restored as they are). A meta file that is missing is an unfinished folder
while the file still holds the bytes it saved (removed by `rollback`, which then stops), else damage (316, nothing deleted).
Every path (a row, the folders on the way, the backup folder, the applied state, the event log, their locks) must be the real
file the index names: a symbolic link or a path that resolves elsewhere is refused (313), no two rows or index paths may be one
file (same device and inode, or the same name up to case), a file with more than one hard link or a mount point is not used (for
a row: that row only), and every file opened must be a regular file, opened without blocking, through folders checked at that
moment. Whether a row is one file or a folder of entries is the data tool's one rule (folder_row): not the disk, not the record.
Owner-only rows (index owner_only) are refused (312) for a worker: a worker marker variable is set (the names are the role
table's `worker_markers`; missing or empty = refuse), or `roles.py prove` says this process is a worker or cannot tell.
That gate is a second line only: a caller can clear its markers, shadow the board tool on PATH or detach from its parent. The
boundary is the hooks of every role refusing to run this tool at all (item W4); see the contract docs.
Values under redact_keys / secret settings never appear in a diff, event, or message (***)."""
import argparse, contextlib, datetime, difflib, errno, hashlib, json, os, pwd, re, secrets, shutil, signal, stat, subprocess, sys, tempfile
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import owner_config as oc
import stella_data as sd

EventError = el.EventError
SECRETS = el.SECRETS   # values seen under masked keys; scrubbed from any message
TMP = ".stella-apply."   # the prefix of this tool's own temp files
TMP_RE = re.compile(re.escape(TMP) + r"[0-9a-f]{16}")   # their whole name (tmp_name)
GONE = ".gone-"   # a backup folder renamed so: removed, its content is being deleted
BACKUP_RE = re.compile(r"\d{8}-\d{8}T\d{12}Z")   # a backup folder's whole name: the counter and the time (apply_locked)
STAGE = "stella-apply-stage-"   # staging folders in the temp folder: <STAGE><pid>-<process start time>-<random>
MAXSEQ = 99999999   # the counter in a backup folder's name has eight digits
STATUSES = ("pending", "done", "rollback-pending", "superseded")
CTX = {}
STEPS = []   # [(key, what is on disk after the step, undo or None, the command that finishes it)] of the running change
REFUSE = ["STL-CFG-313"]   # the code of a refusal: 313 for a command that changes, 322 for a read command (main sets it)
UNDONE_OK = {"STL-CFG-318", "STL-CFG-314"}   # codes whose catalog frame stays true for a change that was undone whole
SNAP = {}   # the start of a writing command: key, file, what it writes, and state_of() then; a failure is compared with it
STOPPING = []   # the first interrupt received: from then on the run is stopping and further ones change nothing

class Interrupted(BaseException):
    pass

def bad(problem, code=None):
    return EventError(code or REFUSE[0], problem)

def qs(x):
    """Text for a line of output: JSON-escaped, so a name or value cannot start a line of its own."""
    return json.dumps(str(x))[1:-1]

def sha(b):
    return hashlib.sha256(b).hexdigest()

def rel_of(p):
    return os.path.relpath(p, el.ROOT)

def path(rel):
    try:
        return el.path(rel)
    except ValueError as e:
        raise bad(str(e)[:120])

def read(p, code=None):
    """The bytes of a data, state or backup file (None when missing). Only a regular file, opened without blocking and never
    through a link, of at most el.MAX_FILE bytes; anything else is one coded problem that names the file."""
    try:
        fd = el.open_file(p, os.O_RDONLY)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        raise EventError(code or REFUSE[0], f"{qs(rel_of(p))}: {el.why(e)[:60]}")
    with os.fdopen(fd, "rb") as f:
        b = f.read(el.MAX_FILE + 1)
    if len(b) > el.MAX_FILE:
        raise EventError(code or REFUSE[0], f"{qs(rel_of(p))}: larger than {el.MAX_FILE} bytes")
    return b

def try_read(p):
    try:
        return read(p, "STL-CFG-316")
    except EventError:
        return None

def mkdir_p(p):
    """p and the folders on the way, each created 0700 through its checked parent (they hold or lead to full copies of owner
    files). A folder another run made in between is fine."""
    try:
        el.mkdirs(p)
    except ValueError as e:
        raise bad(f"{qs(rel_of(p))}: {e}")

def tmp_name():
    """The one shape of this tool's temp files: TMP and 16 hex digits (TMP_RE: what sweep() removes, nothing wider)."""
    return TMP + os.urandom(8).hex()

def atomic_write(p, data, mode, judge=None):
    """Temp file (0600) in the same folder, fsync, rename, fsync the folder. Everything is done relative to the folder as
    opened (checked to be where its path says), so a folder swapped for a link afterwards changes nothing. judge: called when
    the temp file is written, synced and closed, right before the rename; when it raises, nothing is replaced."""
    d, name = os.path.split(p)
    dfd = el.open_dir(d)
    try:
        tmp = tmp_name()
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
                os.fchmod(f.fileno(), mode)
            if judge:
                judge()
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

def restore(p, data, mode, judge=None):
    if data is not None:
        return atomic_write(p, data, mode, judge)
    if judge:
        judge()
    unlink(p)

def drop_backup(bd):
    """Remove a backup folder: one rename to a GONE name first (after it the backup no longer exists for any command, and a
    kill leaves a folder the next run sweeps), then the content."""
    d, name = os.path.split(bd)
    if not os.path.lexists(bd):   # an undo of a step whose folder was never made
        return
    dfd = el.open_dir(d)
    try:
        gone = GONE + name
        with contextlib.suppress(FileNotFoundError):
            shutil.rmtree(os.path.join(d, gone))
        os.rename(name, gone, src_dir_fd=dfd, dst_dir_fd=dfd)
        os.fsync(dfd)
    finally:
        os.close(dfd)
    shutil.rmtree(os.path.join(d, gone), ignore_errors=True)

def mounted(p):
    """True when p is a mount point (a bind-mounted file looks like any file by device and inode)."""
    with open("/proc/self/mountinfo", encoding="utf-8", errors="replace") as f:
        return any(re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), l.split()[4]) == p for l in f if len(l.split()) > 4)

def link_problem(what, rel, st, p):
    """Why a regular file is not used (more than one hard link, a mount point), with where to look and what to do; or None."""
    if st.st_nlink > 1:
        return fit(f"{what} has more than one hard link: find them (`find / -xdev -samefile {rel}` from the stack root), remove the extras",
                   f"find the other links of {rel} (`find / -xdev -samefile {rel}` from the stack root) and remove them")
    if mounted(p):
        return f"{what} is a mount point, not the file the index names: unmount it or point the index row at the real file"
    return None

# ---- the index, read once ----
def alias_problems(idx, rows):
    """[(row id or None for the index's own paths, why)]: paths of an index that are not each their own real file: the same
    file by name (up to case) or by device and inode, a file with more than one hard link, a mount point, a path inside a
    folder that is another path of the index. A problem that touches the index file, the log, the backup folder or the
    applied state is None (it stops every command); one of rows only names those rows."""
    named = [("the event log", idx["event_log"], None), ("the backup folder", idx["backup_dir"], None),
             ("the applied state", idx["applied_state"], None)] \
        + [(f"the file of {r['id']}", r["path"], None if sd.same_path(r["path"], sd.INDEX) else r["id"]) for r in rows]
    seen, found, out = {}, [], []
    for what, rel, rid in named:
        p = os.path.realpath(os.path.join(el.ROOT, rel))   # confinement and links are refused where a path is used (el.path)
        try:
            st = os.stat(p)
        except OSError:
            st = None
        keys = [("name", p.casefold())] + ([("file", st.st_dev, st.st_ino)] if st else [])
        for k in keys:
            if k in seen:
                w2, r2 = seen[k]
                why = f"{what} and {w2} are the same file (one name, a hard link or a link): give each index row its own file"
                out += [(None, why)] if rid is None or r2 is None else [(rid, why), (r2, why)]
                break
        seen.update(dict.fromkeys(keys, (what, rid)))
        found.append((what, rel, p, st, rid))
    for what, rel, p, st, rid in found:
        if st and stat.S_ISREG(st.st_mode) and (why := link_problem(what, rel, st, p)):
            out.append((rid, why))
    for what, rel, p, st, rid in found:
        if st and stat.S_ISDIR(st.st_mode):
            for w2, _, p2, _, r2 in found:
                if w2 != what and p2.casefold().startswith(p.casefold().rstrip(os.sep) + os.sep):
                    why = f"{w2} lies inside {what}: give it a path outside that folder in the index"
                    out += [(None, why)] if rid is None or r2 is None else [(rid, why), (r2, why)]
    return out

def context():
    """The index and its rows, read once per process, with the checks that no two paths of the index are one file. A problem of
    the index's own paths stops the command; a row's problem refuses that row only (target())."""
    if CTX:
        return CTX
    idx, rows = sd.load(sd.INDEX), sd.rows()
    el.LOG_REL = idx["event_log"]
    probs = alias_problems(idx, rows)
    for rid, why in probs:
        if rid is None:
            raise bad(why)
    CTX.update(idx=idx, rows=rows, bad={rid: why for rid, why in reversed(probs)})
    return CTX

def records():
    """{key: applied record} as stored, or {} when the state cannot be read (a caller that needs it reads it itself)."""
    try:
        return load_state()[0]
    except EventError:
        return {}

def folder_row(row):
    """What a row IS: the data tool's one rule (stella_data.folder_row: a json row whose path does not end in the format's own
    suffix is a folder of entries, every other row one file). Not the list key, not the disk, not the applied record (a record
    that disagrees is a refusal of that row: kind_drift)."""
    return sd.folder_row(row)

def kind_drift(row, folder):
    """None, or how the row disagrees with its kind, with the way out: the applied state records it as the other kind (its index
    path was changed after an apply), the folder of a folder row is missing or is a file, the file of a one-file row is a folder.
    The data tool's check refuses the same row (STL-CFG-310) and does not open it."""
    keys = {k.partition("/")[1] for k in records() if k.partition("/")[0] == row["id"]}
    if keys and keys != {"/" if folder else ""}:
        return (f"put the index path of {row['id']} back as it was when it was applied: the applied state records it as "
                + ("one file" if "" in keys else "a folder of entries"))
    p, sfx = path(row["path"]), "." + row["format"]
    try:
        st = os.lstat(p)
    except FileNotFoundError:
        if folder:
            return fit(f"make the folder of {row['id']} (`mkdir -p {row['path']}`) or restore it from git: it does not exist",
                       f"make the folder (`mkdir -p {row['path']}`): it does not exist")
        d = rel_of(os.path.dirname(p))   # a one-file row whose folder is missing: one line in check too, as in apply
        return None if os.path.isdir(os.path.dirname(p)) else fit(
            f"make its folder first (`mkdir -p {d}`), then run this command again: the folder of {row['id']} does not exist",
            f"make its folder first (`mkdir -p {d}`): it does not exist")
    if folder and not stat.S_ISDIR(st.st_mode):
        return fit(f"rename the path of {row['id']} in the index so it ends in {sfx}, or put its folder back: {qs(row['path'])} is one file",
                   f"rename the path of {row['id']} in the index so it ends in {sfx}, or put its folder back")
    if not folder and stat.S_ISDIR(st.st_mode):
        return fit(f"put the file back, or rename the path of {row['id']} in the index (a folder's path has no {sfx}): {qs(row['path'])} is a folder",
                   f"put the file of {row['id']} back: its path is a folder") if row["format"] == "json" else \
            fit(f"put the file of {row['id']} back: {qs(row['path'])} is a folder", f"put the file of {row['id']} back: its path is a folder")
    return None

# ---- which file ----
def target(arg, read_only=False):
    """(row, key, absolute path, root-relative path). Unknown id: STL-CFG-311 and exit (stella_data.refuse). One name per row:
    <id> for a single file, <id>/<entry> for a folder entry (read_only: a folder's bare id is allowed, and a row whose disk
    differs from its kind is not refused here: check reports it)."""
    did, slash, entry = arg.partition("/")
    row = sd.row_of(did)
    if did in context()["bad"]:
        raise bad(context()["bad"][did])
    folder = folder_row(row)
    if not read_only and (why := kind_drift(row, folder)):   # what the row is, and whether the disk and the record agree, comes first
        raise bad(why)
    if folder:
        if not slash and not read_only:
            raise bad(f"{did} is a folder: name a file as <id>/<file>")
        if slash and (why := sd.bad_entry(entry, arg)):   # the one entry rule of check and ids-migrate
            raise bad(why)
    elif slash:
        raise bad(f"{did} is a single file: give just its id")
    rel = row["path"] + ("/" + entry if slash else "")
    p = path(rel)
    key = arg if slash else did
    fs_fits(p, os.path.join(os.path.dirname(p), tmp_name()), os.path.join(bdir(key), GONE + "0" * 31, tmp_name()), lock_of(key))
    if slash and os.path.isdir(os.path.dirname(p)):   # names that differ only by case are one name: one file never gets two keys
        for n in os.listdir(os.path.dirname(p)):
            if n != entry and n.casefold() == entry.casefold():
                raise bad(f"{json.dumps(arg)} differs only by case from the existing {qs(n)}; they are one name, use that one")
    try:
        st = os.lstat(p)
    except FileNotFoundError:
        st = None
    if st and stat.S_ISREG(st.st_mode) and (why := link_problem(qs(rel), rel, st, p)):
        raise bad(why)
    return row, key, p, rel

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

def fit(*texts):
    """The first text that the catalog prints whole (its cut is 200 characters), else the last one (the shortest): no text
    is cut here and no path is left out, and a text the catalog would cut is printed whole on a line of its own (whole())."""
    return next((t for t in texts if len(t) <= 200), texts[-1])

def whole(problem, to=None):
    """The catalog cuts a value at 200 characters (alert_catalog.render, not this tool's): a longer problem text, which only a
    long name or path makes, follows its coded line whole on a line of its own, so a printed path or command is never cut."""
    if len(el.scrub(problem)) > 200:
        print("whole text: " + el.scrub(problem), file=to or sys.stderr)

def fail(code, problem, extra=None):
    rc = el.fail(code, problem, extra)
    whole(problem)
    return rc

def lock_of(key):
    """The row's lock file: named by the key, or by its hash when that name is longer than a file name may be."""
    n = key.replace("/", "__") + ".lock"
    return path(os.path.join(context()["idx"]["backup_dir"], ".locks", n if len(os.fsencode(n)) <= 255 else hashlib.sha256(n.encode()).hexdigest() + ".lock"))

def fs_fits(*paths):
    """A name may be as long as the file system allows, and one it refuses is refused here, before anything is written: each
    path this tool would make for the key is asked of the file system's own limits (no number of this tool's)."""
    for p in paths:
        d = os.path.dirname(p)
        while not os.path.isdir(d):
            d = os.path.dirname(d)
        nmax, pmax = os.pathconf(d, "PC_NAME_MAX"), os.pathconf(d, "PC_PATH_MAX") - 1
        n = max(len(os.fsencode(c)) for c in os.path.relpath(p, d).split(os.sep))
        if n > nmax or len(os.fsencode(p)) > pmax:
            raise bad(f"give the entry a shorter name: the file system allows {nmax} bytes for a name and {pmax} for a path, and this "
                      f"one needs {n} and {len(os.fsencode(p))}")

def writable(key, tgt):
    """Refused before any write when a folder this run must write in (the file's, the applied state's, the backups') cannot be
    written by this user. The tool never changes the mode of a folder it did not make: lifting the owner's read-only layout is
    the owner's decision. A folder whose mode allows the write and that still cannot be written is read-only where it is
    mounted (or not this user's): no chmod line then. The path is printed whole."""
    if not os.path.isdir(os.path.dirname(tgt)):   # the file's own folder is the owner's to make, like the file's mode
        r = rel_of(os.path.dirname(tgt))
        raise bad(fit(f"make its folder first (`mkdir -p {r}`), then run this command again: the folder of {key} does not exist",
                      f"make its folder first (`mkdir -p {r}`): it does not exist"))
    for p in (os.path.dirname(tgt), os.path.dirname(state_path()), bdir(key)):
        d = p
        while not os.path.isdir(d) and d != el.ROOT:
            d = os.path.dirname(d)
        if os.access(d, os.W_OK | os.X_OK):
            continue
        st, r = os.stat(d), rel_of(d)
        if st.st_uid == os.geteuid() and st.st_mode & 0o300 == 0o300:
            raise bad(f"make the folder {qs(r)} writable where it is mounted: its mode allows the write, but it is read-only there "
                      "(or not yours), so chmod does not help")
        m = f"{st.st_mode & 0o7777:o}"
        raise bad(fit(f"run `chmod u+w {r}`, this command again, then `chmod {m} {r}`: that folder is read-only and this tool does "
                      "not change modes",
                      f"run `chmod u+w {r}` and this command again, then set its mode back to {m}"))

def private(row):
    """True when no hash of the file may reach a log: it has redact keys or stores a secret registry setting (owner-only alone does not)."""
    return bool(row["redact_keys"]
                or any(e["sensitivity"] == "secret" and e["store"]["data"] == row["id"] for e in el.registry()["entries"]))

# ---- the applied state, backups, locks ----
def state_path():
    return path(context()["idx"]["applied_state"])

def rec_ok(v):
    return isinstance(v, dict) and isinstance(v.get("sha256"), str) and (v.get("adopt") is None or isinstance(v["adopt"], str))

BOUND = ("token", "sha256", "existed", "mode", "new_sha256", "prev_applied")   # what a backup's record binds of its meta file

def saved_ok(v):
    """A backup's record in the applied state: its token and what the saved copy is, all of BOUND. The older forms (a bare
    token, a record with only a token) are refused (310): no applied state of that form exists (the phase was never merged)."""
    return isinstance(v, dict) and isinstance(v.get("token"), str) and all(k in v for k in BOUND)

def word(rec):
    """The state of a backup, computed from its record in the applied state ALONE: set aside (an adopt), rollback-pending (a
    rollback marked it), done (written as a step after the apply's event line), else pending. A missing word is pending."""
    return "superseded" if rec.get("superseded") else "rollback-pending" if rec.get("rb") else "done" if rec.get("done") else "pending"

def load_state():
    """({key: record}, counter, {key: {backup name: record}}). The counter orders the backups; a record is {sha256, mode, time}
    (and `adopt`, a token, between an adopt's state write and its event line). The third is what this tool recorded for each
    apply (the token; the saved copy's sha256, whether the file existed, its mode): only these folders are ever restored from.
    shortcut: a counter beyond what the folder name carries (or negative) counts as 0, the backups' own names order them;
    upgrade: none needed."""
    raw = read(state_path(), "STL-CFG-310")
    if raw is None:
        return {}, 0, {}
    rel = qs(context()["idx"]["applied_state"])
    try:
        d = json.loads(raw)
    except (ValueError, RecursionError):
        d = None
    if not isinstance(d, dict):
        raise bad(f"fix {rel} by hand (it records which backups are this tool's): it is not a JSON object", "STL-CFG-310")
    a, c, b = d.get("applied"), d.get("counter", 0), d.get("backups", {})
    for ok_, field, want in ((isinstance(a, dict), "applied", "an object"), (type(c) is int, "counter", "a whole number (0 is safe)"),
                             (isinstance(b, dict), "backups", "an object"),
                             (isinstance(a, dict) and all(rec_ok(v) for v in a.values()), "applied", "a set of well-formed records"),
                             (isinstance(b, dict) and all(isinstance(v, dict) and all(saved_ok(t) for t in v.values()) for v in b.values()),
                              "backups", "a set of well-formed records")):
        if not ok_:
            raise bad(f"set `{field}` in {rel} by hand: it must be {want}", "STL-CFG-310")
    return a, (c if 0 <= c <= MAXSEQ else 0), b

def applied():
    return load_state()[0]

def update_state(fn, seq=0):
    """One change of the applied state. Its lock is held by the command (exclusive(), from its first read to its printed line):
    the state is read here, inside that lock, and nothing is decided from an earlier read; no lock is taken here, so an undo
    never waits. A change that changes nothing is not written. A change that brings the records back to what they were at the
    start of the command (an undo) puts the start's own bytes back: its counter, or no file at all."""
    p = state_path()
    a, c, b = load_state()
    old = json.dumps([a, b], sort_keys=True)
    fn(a, b)
    if "raw" in SNAP and not seq:
        raw = SNAP["raw"]
        d = json.loads(raw) if raw is not None else {}
        if (a, b) == (d.get("applied", {}), d.get("backups", {})):
            if read(p, "STL-CFG-310") != raw:
                restore(p, raw, 0o600)
            return
    if json.dumps([a, b], sort_keys=True) == old and seq <= c:
        return
    atomic_write(p, json.dumps({"schema_version": 1, "applied": a, "backups": b, "counter": max(c, seq)}, indent=1).encode(), 0o600)

def set_applied(key, rec, seq=None):
    def f(a, b):
        if rec is None:
            a.pop(key, None)
        else:
            a[key] = rec
    update_state(f, seq or 0)

def register(key, name, saved, seq):
    update_state(lambda a, b: b.setdefault(key, {}).update({name: saved}), seq)

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

UNKNOWN = object()

def scan(key, now=UNKNOWN):
    """(good, junk, strange, stale) for the backup folders of a key. good: [(name, meta)] oldest first, recorded in the applied
    state with the token in their meta (a meta of `status` alone = damage: unreadable, or missing while the change it saved went
    through); `status` is always word() of the applied state's record, whatever the meta file says. junk: recorded names whose meta file is missing while the
    file (sha256 now) still holds the bytes recorded as saved (a kill before the meta was written: unfinished; with now unknown
    every such name). strange: names the applied state does not record (with a meta file or without), or whose token differs:
    never used, never deleted. stale: recorded names with no folder."""
    d, known, good, junk, strange, here = bdir(key), load_state()[2].get(key, {}), [], [], [], set()
    for n in os.listdir(d) if os.path.isdir(d) else []:
        p = os.path.join(d, n)
        if n.startswith(".") or os.path.islink(p) or not os.path.isdir(p):
            continue
        here.add(n)
        try:
            raw = read(os.path.join(p, "meta.json"), "STL-CFG-316")
            m = None if raw is None else json.loads(raw)
        except (EventError, ValueError, RecursionError):
            m = {}
        rec = known.get(n)
        if n not in known:
            strange.append((n, m if isinstance(m, dict) else {}))
            continue
        if m is None:
            if now is not UNKNOWN and rec["sha256"] != now:
                good.append((n, {"status": word(rec)}))   # its change went through (or the file moved on): the missing meta is damage, nothing is deleted
            else:
                junk.append(n)
            continue
        m = {**(m if isinstance(m, dict) else {}), "status": word(rec)}   # the meta's own status word decides nothing
        (good if len(m) == 1 or rec["token"] == m.get("token") else strange).append((n, m))
    order = lambda x: (seq_of(x[0] if isinstance(x, tuple) else x), x[0] if isinstance(x, tuple) else x)
    return sorted(good, key=order), sorted(junk, key=order), sorted(strange, key=order), sorted(n for n in known if n not in here)

def live_of(good):
    return [x for x in good if x[1].get("status") != "superseded"]

def backed_ids():
    """Ids (first part of a key) that still have a backup the rollback can use (a superseded one is history only)."""
    return sorted({k.partition("/")[0] for k in load_state()[2] if live_of(scan(k)[0])})

class Told(BaseException):
    """A failure that was undone and told inside the lock; it carries the exit code out of exclusive()."""

@contextlib.contextmanager
def exclusive(key):
    """The one lock of an apply or rollback, held from before its first read of the row until its one line is printed (every
    id: the cross-file rules see one change at a time): the apply lock, the row's own lock file (a second name for the same
    wait) and the applied state's lock. A failure is undone and told HERE, before the lock is released: every step, every undo,
    the disk read that makes the failure line and the line itself happen inside it. The lock folders and files are made before
    the first step and are not a change."""
    lk, sp = path(os.path.join(context()["idx"]["backup_dir"], ".locks")), state_path()
    mkdir_p(lk)
    mkdir_p(os.path.dirname(sp))
    with el.locked(os.path.join(lk, ".all.lock")), el.locked(lock_of(key)), el.locked(sp + ".lock"):
        try:
            yield
        except BaseException as e:
            try:   # the one interrupt a run can get (interrupted()) may land before failed() is in its stopping state: told again
                rc = failed(e, False)
            except Interrupted:
                rc = failed(e, False)
            if rc is None:
                raise
            raise Told(rc)

def out(text):
    """The one line of a change that is complete, printed and flushed while the lock is held. From here an interrupt changes
    nothing, and a reader that is gone (a closed pipe) does not turn the finished change into a failure."""
    STOPPING.append(0)
    with contextlib.suppress(OSError):
        print(text)
    flush()

def flush():
    try:
        sys.stdout.flush()
    except OSError:   # nothing can be printed: point stdout at the null device so the exit does not fail on the same line (exit 120)
        with contextlib.suppress(OSError):
            os.dup2(os.open(os.devnull, os.O_WRONLY), 1)

def started(pid):
    """The start time of process pid (from /proc), None when there is no such process; the text 'unknown' when it cannot be told."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as f:
            return f.read().rpartition(b")")[2].split()[19].decode()
    except FileNotFoundError:
        return None
    except (OSError, IndexError, ValueError):
        return "unknown"

def sweep_stage():
    """Staging folders whose run is gone: the name holds the process id and its start time, so a reused id does not keep a
    leftover alive. Only folders of this user, never through a link; a name of another shape is not this tool's and is left.
    No usable temp folder: nothing to sweep (a command that does not stage needs none)."""
    try:
        tmp = tempfile.gettempdir()
        names = os.listdir(tmp)
    except OSError:
        return
    for n in names:
        m = re.fullmatch(re.escape(STAGE) + r"(\d+)-(\d+)-.*", n, re.S)
        if not m:
            continue
        p = os.path.join(tmp, n)
        with contextlib.suppress(OSError):
            st = os.lstat(p)
            if stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and started(m[1]) not in (m[2], "unknown"):
                shutil.rmtree(p)

def sweep(key, tgt):
    """A temp file of this tool's own name, found while holding the lock, is the leftover of a crash and holds file bytes; so is
    a backup folder renamed for removal. Each removal is a clean-up step (not a change); a failure here is ignored (the next
    run tries again)."""
    dirs = {os.path.dirname(tgt), os.path.dirname(state_path())} | {r for r, _, _ in os.walk(bdir(key))}
    for d in dirs:
        for n in os.listdir(d) if os.path.isdir(d) else []:
            f = os.path.join(d, n)
            with contextlib.suppress(OSError):
                if TMP_RE.fullmatch(n) and os.path.isfile(f) and not os.path.islink(f):
                    did(key, "a leftover temp file: removed", lambda: None, None, lambda: os.unlink(f), clean=True)
                elif n.startswith(GONE) and BACKUP_RE.fullmatch(n[len(GONE):]) and d == bdir(key) and os.path.isdir(f) and not os.path.islink(f):
                    did(key, "a removed backup's leftover: deleted", lambda: None, None, lambda: shutil.rmtree(f), clean=True)

def logged(key, kind, token, name=None):
    """True when a line of this kind for this key has the tool's own shape: `backup <name> token <token>` (apply, rollback) or
    `token <token>` (adopt), not the token as a loose word. That an apply's line is written is a fact of the applied state
    (`done`); the log is read for it only where that fact is missing or being made: by the finish of a killed apply or adopt,
    by a rollback of a backup not marked done or that resumes a marked one, and by the undo of an event-line step (did its
    write land?)."""
    evs, _ = el.read_log()
    shape = re.compile(r"(^|\s)" + re.escape((f"backup {name} " if name else "") + f"token {token}") + r"(\s|$)")
    return any(e.get("what") == key and e.get("type") == kind and shape.search(str(e.get("detail", ""))) for e in evs)

# ---- parse, validate, diff ----
def shell_read(row):
    """How an env row's file is read, from data: by the stack's own parser (owner_config.py: a path the role table lists under
    `owner_settings`), which drops a BOM and a CR at a line end; else a shell sources it, byte for byte. Unreadable table: a shell."""
    try:
        listed = sd.load(context()["idx"]["role_table"]).get("owner_settings") or []
    except Exception:
        listed = []
    return not any(isinstance(p, str) and sd.same_path(row["path"], p) for p in listed)

def parse(row, data):
    if row["format"] == "json":
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
    shell = shell_read(row)
    cfg, text = {}, data.decode("utf-8" if shell else "utf-8-sig")
    if shell and (text.startswith("\ufeff") or "\r" in text or "\0" in text):   # the shell reads `. file` byte for byte: a BOM or a CR is part of a name or value there, a NUL is dropped
        raise ValueError("a byte-order mark, a carriage return or a NUL byte (a shell would read the value differently)")
    for n, line in enumerate(text.split("\n"), 1):
        if not line.strip(" \t\r") or line.lstrip(" \t").startswith("#"):
            continue
        m = oc.LINE.fullmatch(line)
        if not m or m[1] in cfg:
            raise ValueError(f"line {n}: " + ("a key is repeated" if m else f"not {oc.FORMS}"))
        cfg[m[1]] = next(v for v in m.groups()[1:] if v is not None)
    return cfg

def parse_or_none(row, data):
    """(doc, parses). A current file that does not parse is no basis for a diff, but it can be replaced."""
    if data is None:
        return None, True
    try:
        return parse(row, data), True
    except (ValueError, UnicodeDecodeError, RecursionError):
        return None, False

note_secrets = el.note_secrets

def stage(tmp, rel, data):
    """A scratch root holding what the whole-set check reads: index, schemas, role table and the hook files it names, every json
    row; the candidate (when not None) in place of its file. Every path is confined to the root first; a folder is copied entry
    by entry, only plain regular files of the entry rule, none larger than the read limit (a stray entry is left out here and
    reported by `check`, it does not refuse an unrelated change). The candidate index was validated before this is called.
    Each file is made 0600 through its checked folder, never through a link."""
    idx = sd.load(sd.INDEX)
    docs = [idx] + ([json.loads(data)] if data is not None and sd.same_path(rel, sd.INDEX) else [])
    srcs = {sd.INDEX, sd.SCHEMAS}
    for d in docs:
        srcs |= {d["role_table"]} | {r["path"] for r in d["files"] if r["format"] == "json"}
        table = sd.load(d["role_table"]) if os.path.isfile(path(d["role_table"])) else {}
        srcs |= {h["file"] for r in (table.get("roles") or {}).values() if isinstance(r, dict) for h in r.get("hooks", [])
                 if isinstance(h, dict) and isinstance(h.get("file"), str)}   # the files the table names: the table check looks them up
    def put(s, b):
        dst = os.path.join(tmp, os.path.normpath(s))
        el.mkdirs(os.path.dirname(dst), tmp)
        dfd = el.open_dir(os.path.dirname(dst))
        try:
            fd = os.open(os.path.basename(dst), os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
        finally:
            os.close(dfd)
        with os.fdopen(fd, "wb") as f:
            f.write(b)
    for s in srcs:
        src = path(s)
        if os.path.isdir(src):
            for n in sorted(os.listdir(src)):
                if sd.ENTRY.fullmatch(n) and (b := try_read(os.path.join(src, n))) is not None:
                    put(f"{s}/{n}", b)
        elif (b := try_read(src)) is not None:
            put(s, b)
    if data is not None:
        put(rel, data)

def problems(rel, data):
    """The whole-set check on a staged copy. The staging folder is in the temp folder, never inside the root (a dry run leaves
    the root as it was; Python's fallback to the current folder is refused there), 0700, named for this run (process id and
    start time); removed at the end, and a kill leftover by the next command of this tool (sweep_stage)."""
    try:
        base = os.path.realpath(tempfile.gettempdir())
        if base == el.ROOT or base.startswith(el.ROOT.rstrip(os.sep) + os.sep):
            raise OSError(errno.EPERM, "it is inside the stack root")
        tmp = os.path.realpath(tempfile.mkdtemp(prefix=f"{STAGE}{os.getpid()}-{started(os.getpid())}-", dir=base))
    except OSError as e:
        raise bad(f"set TMPDIR to a folder you can write, outside the stack: no usable temp folder ({el.why(e)[:60]})")
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
            raise EventError(e["code"], f"{k}: " + re.sub(r"^default (\$: )?", "", errs[0])[:120])

def index_moves(doc):
    """Applying the index through itself: the candidate must be a valid index whose paths are each their own file, the paths the
    running apply already uses cannot move under it, the index keeps its own row, and no row with a backup may go."""
    try:
        sd.checked(doc, sd.INDEX, "data-files")
    except sd.DataError as e:
        raise bad(f"the candidate index is not valid: {str(e)[:140]}")
    idx = context()["idx"]
    for k in ("event_log", "backup_dir", "applied_state"):
        if not sd.same_path(doc.get(k), idx[k]):
            raise bad(f"stop every run of the tool, move it and edit the index by hand, then run check: the index cannot change {k} "
                      "through its own apply")
    files = doc["files"]
    if not any(sd.same_path(r.get("path"), sd.INDEX) for r in files):
        raise bad("keep the row for the index itself: the candidate index has none")
    why = alias_problems(doc, files)
    if why:
        raise bad(f"the candidate index: {why[0][1][:160]}")
    gone = [i for i in backed_ids() if i not in {r.get("id") for r in files}]
    if gone:
        raise bad(f"roll those back first, then drop the row: the candidate index drops a row that still has a backup ({', '.join(gone)})")

def validate(row, rel, data):
    try:
        doc = parse(row, data)
    except (ValueError, UnicodeDecodeError, RecursionError) as e:
        raise bad(f"the candidate is not valid {row['format']}: {type(e).__name__} {e}"[:160])
    if not isinstance(doc, dict):
        raise bad("the candidate must be an object / a list of settings")
    note_secrets(doc, el.redactor(row["id"]))
    if row["format"] != "json":
        registry_problems(row, doc)
        return doc
    if sd.same_path(rel, sd.INDEX):
        index_moves(doc)
    try:
        after = problems(rel, data)
        base = problems(rel, None) if after else set()
    except EventError:
        raise
    except Exception as e:
        raise bad(f"the validity check failed: {type(e).__name__}")
    why = added(row["id"], base, after)
    if why:
        raise bad(why)
    return doc

def added(rid, base, after):
    """The one rule of the whole-set check: a candidate (and a saved copy a rollback restores) may not add a problem to the set.
    Each problem LINE is judged, never a whole row: a line (row, text) of the data tool that was not there before the change
    refuses, in any row; a line of the candidate's own row refuses also when it was there; a set that cannot be checked is no
    set to write into. A line of another row that only reworded itself is refused too (the price of comparing texts): the
    message names that row, says it already had a problem and gives the way out. None when nothing refuses."""
    new = sorted(p for p in after if p[0] == rid or p not in base or "could not run" in p[1])
    if not new:
        return None
    row, text = new[0]
    more = f" (+{len(new) - 1} more)" if len(new) > 1 else ""
    if row != rid and "could not run" not in text and any(p[0] == row for p in base):
        way = f"fix {row} first (`stella_data.py check` lists its problems), then run this again"
        why = f"{way}: {row} already had a problem, and the candidate adds a line to its check"
        return fit(f"{why} ({text}){more}", why + more, f"{way}: it already had a problem, the candidate adds a line{more}")
    return fit(f"the candidate is invalid: {row}: {text}{more}", f"the candidate is invalid: {row}: {text}"[:190 - len(more)] + more)

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

UNPARSED = {"unparsed": True}   # a side of an event line whose file exists and does not parse (null is: no file)

def event(row, key, kind, old, new, detail, unparsed=(), iid=None):
    """One event line, built and judged (size, shape, schema) now, before anything changes; written later by log(). The detail is
    the tool's own text (hashes, the backup name, the token): it is not scrubbed by substring, which could garble the name or
    the token when a masked value is a few characters long. iid: cand_iid() of an apply (None: the install's own id)."""
    o, n = changes(row["format"], old, new)
    line = el.build(kind, key, o, n, detail=detail, who=who())
    for k, d in (("old", old), ("new", new)):
        if d is None:   # no file on that side: null, not an empty change; a file that is there and does not parse says so
            line[k] = UNPARSED if k in unparsed else None
    el.prepare(line, row["id"], scrub_detail=False, install_id=iid)
    return line

def log(row, line, iid=None):
    el.append(line, row["id"], scrub_detail=False, install_id=iid)

def cand_iid(row, doc):
    """The install id of an apply's event line: for the install row the candidate's, once it passes the install schema (owner
    decision 2026-11-14 b: a damaged install file is repaired through the contract); None for every other row, whose line reads
    the install's own id and is refused when that cannot be read."""
    return sd.checked(doc, row["path"], sd.INSTALL)["install_id"] if row["format"] == "json" and row["schema"] == sd.INSTALL else None

def rec_of(cand, mode):
    return {"sha256": sha(cand), "mode": mode, "time": el.build("x", "x")["time"]}

def hashes(row, old, new):
    return "" if private(row) else f"sha256 {(old or 'none')[:12]} -> {new[:12]} "

class Stay(Exception):
    """An undo that finds its step's effect permanent (an event line written, a folder removed): the undo stops there."""

def did(key, what, undo, way, act=None, clean=False):
    """Enter one write of the running change, then do it (act). The step is entered BEFORE its effect can exist, so a write that
    lands and then raises is still undone. undo looks at the disk: it is safe whether the effect happened or not and safe twice,
    and raises Stay when the effect is permanent. way: the command that finishes the change if it stops here (None: nothing is
    left to finish). clean: a clean-up of this tool's own leftovers, not a change. No signal is held: an interrupt anywhere is
    one more failure, and the undo reads the disk."""
    STEPS.append((key, what, undo, way, clean))
    if act:
        act()

def line_undo(key, kind, token, name=None):
    """The undo of an event line: nothing when the line is not in the log (the write never landed), else it stays."""
    def u():
        if logged(key, kind, token, name):
            raise Stay
    return u

def mark_done(key, name, saved):
    """The step that says an apply is complete: `done` in the backup's record of the applied state, written after the event
    line (so done also means: the apply line is in the log). Its undo is nothing: the line before it stays."""
    did(key, f"backup {name}: done in the applied state", lambda: None, None, lambda: register(key, name, {**saved, "done": True}, 0))

def judged(tgt, before):
    """The file must still hold the bytes the command read; else 314 (a hand edit made while the command ran): nothing is
    replaced and the edit is kept. Called once before the first step and again at the replace. What it finds (the edit's hash
    and the file's mode) is recorded as the file's state at the start: the edit is not this run's change."""
    now = read(tgt)
    if now != before:
        key = SNAP.get("key", "<id>")
        if SNAP:
            SNAP["state"].update(file=sha(now) if now is not None else None, mode=mode_of(tgt))
            SNAP["edited"] = True
        raise bad(fit(f"record the edit (`apply {key} --from <file>` with a copy of the file as it is) or revert it by hand, then run "
                      f"this command again: {qs(rel_of(tgt))} was changed while this command ran; nothing was replaced, the edit is kept",
                      f"record the edit (`apply {key} --from <file>` with a copy of the file as it is) or revert it by hand: the file "
                      "was changed while this command ran; the edit is kept"), "STL-CFG-314")

def mode_of(tgt):
    try:
        return os.lstat(tgt).st_mode & 0o7777
    except FileNotFoundError:
        return None

def swap(key, what, tgt, before, data, mode, mode0, way):
    """The step that replaces a data file (apply and rollback): the temp file is written and synced, THEN the file is compared
    once more with what was read (judged), then the one rename. Its undo asks one question, at its own rename too: does the
    file hold the bytes this run wrote? Yes: the bytes it replaced go back. No: nothing is written, and that is never a failure
    of the undo: when this run never replaced the file (the compare refused, or the rename never landed) the undo goes on and
    everything the run entered is undone; when it did and someone wrote over that, the undo stops here (Stay) and the saved copy
    is kept."""
    passed = []
    def mine():
        now = read(tgt)
        if now != data and passed and now != before:
            raise Stay
        return now == data
    def judge():
        judged(tgt, before)
        passed.append(1)
    def stay():
        if not mine():
            raise Stay
    did(key, what, lambda: mine() and restore(tgt, before, mode0, stay), way, lambda: restore(tgt, data, mode, judge))

def state_of(key, tgt, cur=UNKNOWN):
    """What an owner can see of a key, read from the disk: the file (sha256, mode; cur: its bytes when the caller just read
    them), its applied record, the backups recorded for it, its backup folders with their state, the event lines about it (the
    event log is read here: at the start of every writing command and once more when one fails)."""
    def safe(f):
        try:
            return f()
        except Exception as e:
            return f"unreadable ({type(e).__name__})"
    def folders():
        d, out, known = bdir(key), {}, load_state()[2].get(key, {})
        for n in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if not n.startswith("."):   # the applied state's word for it, and whether its meta file is there
                out[n] = (word(known[n]) if n in known else "not recorded") + ("" if os.path.lexists(os.path.join(d, n, "meta.json")) else ", no meta")
        return out
    def file():
        b = read(tgt) if cur is UNKNOWN else cur
        return sha(b) if b is not None else None
    return {"file": safe(file), "mode": safe(lambda: mode_of(tgt)), "record": safe(lambda: load_state()[0].get(key)),
            "saved": safe(lambda: load_state()[2].get(key)), "backups": safe(folders),
            "lines": safe(lambda: len([e for e in el.read_log()[0] if e.get("what") == key]))}

def begin(key, tgt, want):
    """The one point where a writing command reads the file and takes the state a failure is compared with: after the
    validation, before the first step. Returns the file's bytes; want: the sha256 of what the command writes. The applied
    state's bytes are kept too: an undo that brings its records back puts them back (update_state)."""
    cur = read(tgt)
    SNAP.update(key=key, tgt=tgt, want=want, state=state_of(key, tgt, cur), raw=read(state_path(), "STL-CFG-310"))
    return cur

def described(s0, s1, want):
    """What is on disk now against the start, in the owner's words (file, backups, applied state, event line)."""
    f = s1["file"]
    out = ["file: " + ("as before" if f == s0["file"] else "the bytes this command writes" if f == want else "gone" if f is None
                       else "other bytes")]
    r = s1["record"]
    out.append("applied state: " + ("as before" if (r, s1["saved"]) == (s0["record"], s0["saved"]) else "no record" if r is None
                                    else "records the bytes this command writes" if isinstance(r, dict) and r.get("sha256") == want
                                    else "changed"))
    n = s1["lines"] - s0["lines"] if isinstance(s1["lines"], int) and isinstance(s0["lines"], int) else None
    out.append("event line: " + ("not written" if n == 0 else "written" if n else "unknown"))
    b0, b1 = (s0["backups"] if isinstance(s0["backups"], dict) else {}), (s1["backups"] if isinstance(s1["backups"], dict) else {})
    bs = [f"backup {n}: " + ("removed" if n not in b1 else str(b1[n])) for n in sorted(set(b0) | set(b1)) if b0.get(n) != b1.get(n)]
    return fit("; ".join(out + bs), "; ".join(out + [f"{len(bs)} backups changed (see `history`)"]))   # never a list cut in the middle

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

def meta_problem(m, name, saved=None):
    """True when a meta file is not what this tool writes: every field is checked before it is used, against what the applied
    state recorded for the saved copy (token, hashes, existence, mode, previous record) when it holds that; a mode a data file
    may not have is damage. What a rollback marked (its token and what it found) is read from the applied state only."""
    pa, sq = m.get("prev_applied"), m.get("seq")
    ok = (isinstance(m.get("existed"), bool) and type(m.get("mode")) is int and not m["mode"] & ~0o777 and m.get("status") in STATUSES
          and (m.get("sha256") is None or isinstance(m["sha256"], str)) and m["existed"] == (m.get("sha256") is not None)
          and isinstance(m.get("new_sha256"), str) and (pa is None or rec_ok(pa)) and isinstance(m.get("token"), str)
          and type(sq) is int and 0 < sq <= MAXSEQ and sq == seq_of(name))
    if ok and isinstance(saved, dict):
        ok = all(saved[k] == m.get(k) for k in BOUND)
        rb = saved.get("rb")
        ok = ok and (rb is None or (isinstance(rb, dict) and isinstance(rb.get("token"), str) and isinstance(rb.get("same"), bool)
                                    and isinstance(rb.get("logged"), bool)))
    return not ok

def saved_of(key, name):
    return load_state()[2].get(key, {}).get(name)

def unfinished_text(key, name):
    return f"run `rollback {key}`, which removes it: backup {qs(name)} is unfinished (stopped before the replace)"

def pending_action(key, cur, cand, good, junk, strange, rec):
    """(action, error) for what an unfinished step of this key means for an apply of cand (None: for `check`): none | refuse
    (the EventError to raise) | finish (an apply killed after the replace, repeated) | adopt (the file was edited by hand since
    the interrupted change and cand holds those bytes) | finish_adopt (an adopt killed before its event line)."""
    if strange:
        d, why = qs(rel_of(os.path.join(bdir(key), strange[0][0]))), "the applied state does not record it"
        return "refuse", bad(fit(
            f"look at the folder {d}, then remove it by hand: {why} (if the applied state was lost or put back from an older copy, "
            "it may be this tool's own saved copy of the file)",
            f"look at the folder {d}, then remove it by hand: {why}; it may be this tool's own saved copy of the file",
            f"look at the folder {d}, then remove it by hand: {why} (it may be this tool's saved copy)",
            f"look at the folder {d}, then remove it by hand: {why}"            ), "STL-CFG-316")
    if junk:
        return "refuse", bad(unfinished_text(key, junk[-1]))
    if rec and rec.get("adopt"):
        if cur is not None and cur == cand:
            return "finish_adopt", None
        return "refuse", bad(f"run `apply {key} --from <file>` with a copy of the file as it is: recording a hand edit stopped "
                             "before its line")
    live = live_of(good)
    open_ = [x for x in live if x[1]["status"] != "done" or meta_problem(x[1], x[0], saved_of(key, x[0]))]   # the applied state's word; a damaged meta is told too
    if not open_:
        return "none", None
    name, m = open_[-1]
    if meta_problem(m, name, saved_of(key, name)):
        return "refuse", bad(f"look at backup {qs(name)} of {key} by hand (its copy is kept): its meta is missing, wrong or not "
                             "as recorded", "STL-CFG-316")
    if (name, m) == live[-1] and m["status"] == "pending" and cur is not None and cur == cand and m["new_sha256"] == sha(cand):
        return "finish", None
    now = sha(cur) if cur is not None else None
    if m["status"] == "rollback-pending" and now in (m["new_sha256"], m["sha256"]):
        return "refuse", bad(f"run `rollback {key}` to finish it: a rollback of {key} was interrupted")
    if now == m["new_sha256"]:
        return "refuse", bad(finish_text(key) + f", or `rollback {key}` (interrupted)")
    if now == m["sha256"]:
        return "refuse", bad(f"run `rollback {key}` first, which removes its backup: an earlier apply stopped before the replace")
    if cur is not None and cur == cand:
        return "adopt", None
    return "refuse", bad(f"run `apply {key} --from <file>` with a copy of the file as it is (that records the edit), or put the file "
                         "back by hand: a change was interrupted, then the file was edited")

def unfinished(key, cur):
    """The one source of the way out of a change that is not finished: the refusal `check` prints for the key as the disk is
    now (None: nothing is unfinished). The failure line of a change that stopped takes its way out from here too, so the
    command a 321 line names is the command `check` names."""
    good, junk, strange, _ = scan(key, sha(cur) if cur is not None else None)
    act, err = pending_action(key, cur, None, good, junk, strange, applied().get(key))
    return err if act != "none" else None

def finish_text(key):
    """The one way out of a pending apply whose file holds the new bytes (apply and rollback both print it)."""
    return f"run `apply {key} --from <file>` with a copy of the file as it is"

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
    writable(key, tgt)   # before the lock files are made
    with exclusive(key):
        return apply_locked(*relock(arg, row), cand)

def dry_run(row, key, tgt, rel, cand):
    red = el.redactor(row["id"])
    writable(key, tgt)   # the refusals an apply makes before its first write, made here too (neither changes anything)
    el.preflight()
    new_doc = validate(row, rel, cand)
    tgt = path(rel)
    cur = read(tgt)
    old_doc, parses = parse_or_none(row, cur)
    note_secrets(old_doc, red)
    good, junk, strange, _ = scan(key, sha(cur) if cur is not None else None)
    act, err = pending_action(key, cur, cand, good, junk, strange, applied().get(key))
    if act == "refuse":
        raise err
    if act in ("finish", "finish_adopt", "adopt"):
        print({"finish": f"would finish the interrupted apply of {key}: the missing bookkeeping and event line are written, no new backup",
               "finish_adopt": f"would finish recording the hand edit of {key}: the missing event line is written",
               "adopt": f"would record the current file as applied (it was changed by hand since an interrupted change) and set the "
                        f"interrupted backup of {key} aside"}[act])
        return 0
    st = drift_of(key, rel, tgt, cur, applied().get(key))[1]   # the refusals the apply makes, in its order: the baseline, the mode, the counter
    if cur == cand:
        print(f"would record the current file as applied (it was changed by hand): {key}" if st == "drift" else f"no change: {key}")
        return 0
    mode_ok(rel, mode_of(tgt) or 0)
    next_seq(key, good)
    if not parses:
        print(f"the current file does not parse, so there is no diff; the candidate would replace it: {key}")
    else:
        d = list(difflib.unified_diff(text(row["format"], old_doc, red), text(row["format"], new_doc, red), "current", "candidate", lineterm=""))
        if d:
            print("\n".join(d))
        else:
            print("no visible change: only masked values or the formatting differ")
            o, n = changes(row["format"], old_doc, new_doc)
            for k in list(dict.fromkeys([*o, *n]))[:20]:
                print(f"-{qs(k)} (masked)\n+{qs(k)} (masked)")
    return 0

def prior_doc(row, key, good, rec):
    """The document last applied (the newest backup keeps a copy of the bytes its apply wrote), None when that is not known."""
    live = live_of(good)
    if rec and live and not meta_problem(live[-1][1], live[-1][0]):
        b = try_read(os.path.join(bdir(key), live[-1][0], "file.applied"))
        if b is not None and sha(b) == rec["sha256"]:
            return parse_or_none(row, b)[0]
    return None

def adopt(row, key, tgt, cand, new_doc, rec, good, resume):
    """Record bytes a hand edit put there: the applied state first (with a marker token), then the event line, then the older
    backups are set aside (in the applied state, then in their meta files) and the marker is cleared. A kill in between is
    finished by the next run, which writes the one `adopt` line."""
    red = el.redactor(row["id"])
    el.preflight()
    mode = os.lstat(tgt).st_mode & 0o7777
    old_doc = prior_doc(row, key, good, None if resume else rec)
    note_secrets(old_doc, red)
    token = rec["adopt"] if resume else secrets.token_hex(16)
    iid = cand_iid(row, new_doc)
    line = None if resume and logged(key, "adopt", token) else event(
        row, key, "adopt", old_doc, new_doc, hashes(row, rec and rec["sha256"], sha(cand))
        + f"recorded the current file as applied (it was changed by hand); older backups set aside; token {token}"
        + ("" if old_doc is not None else " (the content applied before is not known)"), iid=iid)
    again = f"`apply {key} --from <file>` with a copy of the file as it is"
    marked = {**rec_of(cand, mode), "adopt": token} if not resume else rec
    if not resume:
        did(key, "applied state: the hand edit, marked unfinished", lambda: set_applied(key, rec), again, lambda: set_applied(key, marked))
    if line:
        did(key, "event line: written", line_undo(key, "adopt", token), again, lambda: log(row, line, iid))
    aside = [(n, m) for n, m in good if m.get("status") != "superseded" and not meta_problem(m, n)]
    if aside:
        saved = load_state()[2].get(key, {})
        def mark(on):
            def f(a, b):
                for n, _ in aside:
                    if isinstance(b.get(key, {}).get(n), dict):
                        b[key][n] = {**b[key][n], "superseded": on} if on else {k: v for k, v in b[key][n].items() if k != "superseded"}
            update_state(f)
        did(key, "older backups: set aside in the applied state", lambda: mark(False), again, lambda: mark(True))
    for n, m in aside:
        mp = os.path.join(bdir(key), n, "meta.json")
        did(key, f"backup {n}: set aside", lambda mp=mp, m=m: atomic_write(mp, json.dumps(m).encode(), 0o600), again,
            lambda: atomic_write(mp, json.dumps({**m, "status": "superseded"}).encode(), 0o600))
    did(key, "applied state: the hand edit", lambda: set_applied(key, marked), again, lambda: set_applied(key, rec_of(cand, mode)))
    out(f"recorded: {key} (the current file was changed by hand; no backup; the older backups are kept as history only)")
    return 0

def mode_ok(rel, mode):
    """One mask for a data file's mode everywhere (never applied and then stuck in rollback); apply and its dry run refuse alike."""
    if mode & ~0o777:
        m = f"{mode & 0o777:o}"
        raise bad(fit(f"run `chmod {m} {rel}` first: a data file may not have mode {mode:o} (setuid, setgid or sticky)",
                      f"run `chmod {m} {rel}` first: a setuid, setgid or sticky bit"))

def next_seq(key, good):
    """The counter of the next backup; a full counter is refused (apply and its dry run alike)."""
    seq = max([load_state()[1]] + [seq_of(n) for n, _ in good]) + 1
    if seq > MAXSEQ:
        raise bad(f"roll back or remove by hand the old backups of {key}, then set `counter` to 0 in the applied state: it is full")
    return seq

def apply_locked(row, key, tgt, rel, cand):
    red = el.redactor(row["id"])
    writable(key, tgt)
    sweep(key, tgt)
    new_doc = validate(row, rel, cand)
    tgt = path(rel)   # validation took time: the folders on the way are looked at again before the read
    cur = begin(key, tgt, sha(cand))   # the one read of the file, and the snapshot, after the validation
    old_doc, parses = parse_or_none(row, cur)
    note_secrets(old_doc, red)
    rec = applied().get(key)
    good, junk, strange, _ = scan(key, sha(cur) if cur is not None else None)
    act, err = pending_action(key, cur, cand, good, junk, strange, rec)
    if act == "refuse":
        raise err
    if act == "finish":
        return finish_apply(row, key, tgt, cand, new_doc, *live_of(good)[-1])
    if act in ("adopt", "finish_adopt"):
        return adopt(row, key, tgt, cand, new_doc, rec, good, act == "finish_adopt")
    drift = drift_of(key, rel, tgt, cur, rec)[1]   # every apply asks for the baseline: one that cannot be read refuses here, before any step
    if cur == cand:
        if drift != "drift":
            out(f"no change: {key}")
            return 0
        return adopt(row, key, tgt, cand, new_doc, rec, good, False)   # the bytes are already there (a hand edit): record them, no backup
    el.preflight()
    mode = os.lstat(tgt).st_mode & 0o7777 if cur is not None else 0o600 if row["owner_only"] or row["redact_keys"] else 0o644
    mode_ok(rel, mode)
    prev, seq = rec, next_seq(key, good)
    name =f"{seq:08d}-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    token, bd = secrets.token_hex(16), os.path.join(bdir(key), name)
    meta = {"path": rel, "existed": cur is not None, "mode": mode, "sha256": sha(cur) if cur is not None else None,
            "new_sha256": sha(cand), "prev_applied": prev, "seq": seq, "token": token, "status": "pending"}
    iid = cand_iid(row, new_doc)
    line = event(row, key, "apply", old_doc, new_doc, hashes(row, meta["sha256"], sha(cand))
                 + f"backup {name} token {token}" + ("" if parses else " (the current file did not parse)"), () if parses else ("old",), iid)
    back = f"`rollback {key}`"
    def drop_if_old():   # the same one question: the saved copy goes unless the file holds the bytes this run wrote
        if read(tgt) == cand:
            raise OSError(errno.EBUSY, "the file still holds the bytes this run wrote")
        drop_backup(bd)
    saved = {k: meta[k] for k in BOUND}
    judged(tgt, cur)
    did(key, f"backup {name}: recorded", lambda: unregister(key, name), back, lambda: register(key, name, saved, seq))   # known before the file is touched
    did(key, "its folder made", drop_if_old, back, lambda: mkdir_p(bd))
    if cur is not None:
        did(key, "its saved copy written", lambda: None, back, lambda: atomic_write(os.path.join(bd, "file"), cur, 0o600))
    did(key, "its copy of the new bytes written", lambda: None, back,   # the old side of a rollback's line
        lambda: atomic_write(os.path.join(bd, "file.applied"), cand, 0o600))
    did(key, "its meta written (pending)", lambda: None, back, lambda: atomic_write(os.path.join(bd, "meta.json"), json.dumps(meta).encode(), 0o600))
    tgt = path(rel)
    swap(key, "file: the new bytes", tgt, cur, cand, mode, mode, back)
    did(key, "applied state: the new bytes", lambda: set_applied(key, prev), back, lambda: set_applied(key, rec_of(cand, mode), seq))
    did(key, "event line: written", line_undo(key, "apply", token, name), f"`apply {key} --from <file>` with the same file", lambda: log(row, line, iid))
    mark_done(key, name, saved)
    meta["status"] = "done"
    did(key, "backup: status done", lambda: None, None, lambda: atomic_write(os.path.join(bd, "meta.json"), json.dumps(meta).encode(), 0o600))
    out(f"applied: {key} (backup {name})")
    return 0

def finish_apply(row, key, tgt, cand, new_doc, name, meta):
    """A retry of an apply killed after the file was replaced: the bookkeeping that is missing is done now."""
    bd = os.path.join(bdir(key), name)
    old_doc, _ = parse_or_none(row, read(os.path.join(bd, "file"), "STL-CFG-316") if meta["existed"] else None)
    note_secrets(old_doc, el.redactor(row["id"]))
    el.preflight()
    iid = cand_iid(row, new_doc)
    line = None if logged(key, "apply", meta["token"], name) else event(
        row, key, "apply", old_doc, new_doc, hashes(row, meta["sha256"], sha(cand)) + f"backup {name} token {meta['token']}", iid=iid)
    again = f"`apply {key} --from <file>` with the same file"
    before = applied().get(key)
    did(key, "applied state: the new bytes", lambda: set_applied(key, before), again,
        lambda: set_applied(key, rec_of(cand, os.lstat(tgt).st_mode & 0o7777), meta["seq"]))
    if line:
        did(key, "event line: written", line_undo(key, "apply", meta["token"], name), again, lambda: log(row, line, iid))
    mark_done(key, name, saved_of(key, name))
    meta["status"] = "done"
    did(key, "backup: status done", lambda: None, None, lambda: atomic_write(os.path.join(bd, "meta.json"), json.dumps(meta).encode(), 0o600))
    out(f"applied: {key} (backup {name}; the bookkeeping of an interrupted apply was finished)")
    return 0

def do_rollback(arg):
    context()
    row, key, tgt, rel = target(arg)
    gate(row)
    writable(key, tgt)
    with exclusive(key):
        row, key, tgt, rel = relock(arg, row)
        writable(key, tgt)
        red = el.redactor(row["id"])
        sweep(key, tgt)
        again, checked = f"`rollback {key}`", None
        while True:   # the saved copy is validated first (it takes time); the file is read, and everything decided, after it
            cur = begin(key, tgt, None)
            v = rollback_view(row, key, rel, cur)
            if v["check"] in (None, checked):
                break
            checked = v["check"]
            v["validate"]()
        good, junk, strange, stale = v["good"], v["junk"], v["strange"], v["stale"]
        now = sha(cur) if cur is not None else None
        if strange:
            raise pending_action(key, None, None, good, junk, strange, None)[1]
        return rollback_locked(row, key, tgt, rel, cur, now, again, red, good, junk, stale)

def rollback_view(row, key, rel, cur):
    """What a rollback finds for the file as just read: the backups, and the saved copy that has to pass the validation before
    the file is read for the last time (check: its identity, None when nothing has to be validated)."""
    now = sha(cur) if cur is not None else None
    good, junk, strange, stale = scan(key, now)
    v = {"good": good, "junk": junk, "strange": strange, "stale": stale, "check": None}
    live = live_of(good)
    if strange or junk or not live or meta_problem(live[-1][1], live[-1][0], saved_of(key, live[-1][0])):
        return v   # refused or settled without a restore: rollback_locked says which
    name, meta = live[-1]
    back = try_read(os.path.join(bdir(key), name, "file")) if meta["existed"] else None
    if back is None or sha(back) != meta["sha256"] or now != meta["new_sha256"] or not parse_or_none(row, back)[1]:
        return v   # no copy to restore, nothing to restore (or a hand edit: 314), or saved bytes the reader cannot parse (in use as they are)
    def validate_saved():
        try:
            validate(row, rel, back)
        except EventError as e:
            why = re.sub(r"^the candidate (is not valid|is invalid)[: ]*", "", e.problem)
            way = finish_text(key) if meta["status"] == "pending" else f"apply the content you want (`apply {key} --from <file>`)"
            raise bad(fit(f"{way}: the saved copy fails a check a candidate must pass ({why})",
                          f"{way}: the saved copy fails a check a candidate must pass"))
    return {**v, "check": (name, meta["sha256"]), "validate": validate_saved}

def rollback_locked(row, key, tgt, rel, cur, now, again, red, good, junk, stale):
    known = load_state()[2].get(key, {})
    done = [n for n in stale if isinstance(known.get(n), dict) and known[n].get("rb")]
    if done:   # a rollback that removed its backup and stopped before its last bookkeeping was complete: say so, undo no more
        did(key, "stale records: removed", lambda: None, None, lambda: unregister(key, *stale))
        out(f"the rollback of {key} (backup {done[-1]}) was already complete; nothing more was done. Run rollback {key} again "
            "to undo the change before it")
        return 0
    if junk:   # an unfinished backup folder: nothing was replaced, so it only holds a stray copy. Removing it is a step of its own.
        for n in junk:
            p = os.path.join(bdir(key), n)
            did(key, f"unfinished backup {n}: removed", gone_undo(p), again, lambda: drop_backup(p))
        did(key, "their records: removed", lambda: None, None, lambda: unregister(key, *junk, *stale))
        out(f"removed the unfinished backup folder {', '.join(qs(n) for n in junk)} of {key}; nothing was restored "
            f"(the file was not touched). Run rollback {key} again to undo the last change")
        return 0
    live = live_of(good)
    if not live:
        raise bad(f"restore it by hand or from git if needed: no apply of {key} can be undone" + (
            " (older backups were set aside when a hand edit was recorded)" if good else ""), "STL-CFG-316")
    name, meta = live[-1]
    bd, saved = os.path.join(bdir(key), name), known.get(name)
    if meta_problem(meta, name, saved):
        raise bad(f"look at backup {qs(name)} of {key} by hand (its copy is kept): its meta is missing, wrong or not "
                  "as recorded", "STL-CFG-316")
    back = read(os.path.join(bd, "file"), "STL-CFG-316") if meta["existed"] else None
    if meta["existed"] and (back is None or sha(back) != meta["sha256"]):
        raise bad(f"restore {key} by hand or from git: the saved copy in backup {name} is " + ("missing" if back is None else "damaged (its sha256 differs)")
                  , "STL-CFG-316")
    if now not in (meta["new_sha256"], meta["sha256"]):
        raise bad(f"revert the edit by hand, or record it (`apply {key} --from <file>` with a copy of it): it changed after the apply",
                  "STL-CFG-314")
    saved_d = saved
    rb = saved_d.get("rb")   # what a rollback marked: the applied state's word only (a meta file can be rewritten)
    resumed = rb is not None
    same = now == meta["sha256"]   # the file holds the bytes the backup saved now
    judged(tgt, cur)   # once before the first step (the reads above took time), again at the replace
    # done in the applied state says the apply's line is written; the log is read only for a backup not marked done
    same0, apply_logged = (rb["same"], rb["logged"]) if resumed else (same, bool(saved_d.get("done")) or logged(key, "apply", meta["token"], name))
    rbt = rb["token"] if resumed else secrets.token_hex(16)
    # shortcut: a restore that deletes a file (the apply created it) is not checked against the whole set, upgrade if a deleted row file can break a cross-file rule
    el.preflight()
    old_status, cur_rec = meta["status"], applied().get(key)
    was = try_read(os.path.join(bd, "file.applied"))   # the bytes the apply wrote: the old side of the line, also when the restore already happened
    was = was if was is not None and sha(was) == meta["new_sha256"] else cur
    old_doc, _ = parse_or_none(row, was)
    new_doc, _ = parse_or_none(row, back)
    for d in (old_doc, new_doc):
        note_secrets(d, red)
    cur_mode = os.lstat(tgt).st_mode & 0o7777 if cur is not None else 0o644
    new_rec = saved_d.get("prev_applied", meta["prev_applied"])   # the applied state's own copy where it has one
    if new_rec is None and back is not None and git_blob(rel) is None:   # a file git does not track keeps the restored hash as its baseline
        new_rec = rec_of(back, meta["mode"])
    # the lines this rollback owes, judged before anything changes: the apply line when the apply replaced the file but never
    # logged it (L2), and its own line when there was a logged change or the file changes (a never-logged apply that never
    # took effect needs none, L1)
    aline = None if apply_logged or same0 or (resumed and logged(key, "apply", meta["token"], name)) else event(
        row, key, "apply", new_doc, old_doc, hashes(row, meta["sha256"], meta["new_sha256"])
        + f"backup {name} token {meta['token']} (written by the rollback that undoes it)")
    owes = apply_logged or not same0
    rline = None if not owes or (resumed and logged(key, "rollback", rbt, name)) else event(
        row, key, "rollback", old_doc, new_doc,
        (f"nothing to restore: the file already held the saved bytes of backup {name}" if same0 else f"restored backup {name}") + f" token {rbt}"
        + ("" if new_doc is not None or back is None else " (the restored file does not parse)"), () if new_doc is not None or back is None else ("new",))
    SNAP["want"] = meta["sha256"]
    if stale:   # recorded, but the folder is gone by hand: bookkeeping after every refusal, undone like any step
        gone = {n: known[n] for n in stale}
        did(key, "records of missing backup folders: removed", lambda: update_state(lambda a, b: b.setdefault(key, {}).update(gone)),
            again, lambda: unregister(key, *stale))
    if not resumed:
        marked = {**saved_d, "rb": {"token": rbt, "same": same0, "logged": apply_logged}}
        did(key, f"backup {name}: marked for rollback in the applied state", lambda: register(key, name, saved_d, 0), again,
            lambda: register(key, name, marked, 0))
        mp = os.path.join(bd, "meta.json")
        did(key, "its meta: rollback-pending", lambda: atomic_write(mp, json.dumps({**meta, "status": old_status}).encode(), 0o600), again,
            lambda: atomic_write(mp, json.dumps({**meta, "status": "rollback-pending"}).encode(), 0o600))
    tgt = path(rel)
    if not same:
        swap(key, "file: the saved bytes", tgt, cur, back, meta["mode"], cur_mode, again)
    did(key, "applied state: the saved bytes", lambda: set_applied(key, cur_rec), again, lambda: set_applied(key, new_rec))
    if aline:
        did(key, "apply line: written", line_undo(key, "apply", meta["token"], name), again, lambda: log(row, aline))
    if rline:
        did(key, "rollback line: written", line_undo(key, "rollback", rbt, name), again, lambda: log(row, rline))
    did(key, "backup: removed", gone_undo(bd), None, lambda: drop_backup(bd))
    did(key, "its record: removed", lambda: None, None, lambda: unregister(key, name))
    out(f"nothing to restore: the apply of {key} stopped before it took effect; its backup {name} was removed" if not owes else
        f"nothing to restore: {key} already matches its backup {name}" if same0 and not resumed else
        f"rolled back: {key} (backup {name}" + ("; an interrupted rollback was finished)" if resumed else ")"))
    return 0

def gone_undo(bd):
    """The undo of a folder removal: nothing while the folder is still there; once renamed away it stays removed."""
    def u():
        if not os.path.lexists(bd):
            raise Stay
    return u

def git(*args):
    """(exit status, stdout) of one git command in the stack root; (None, b"") when git could not be run (not found, a
    timeout). Only the exit status and the data on stdout are used, never git's wording (the locale is pinned all the same)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CEILING_DIRECTORIES=os.path.dirname(el.ROOT), LC_ALL="C", LANGUAGE="C")   # a scratch root is never read through an outer repo
    try:
        r = subprocess.run(["git", "-C", el.ROOT, *args], capture_output=True, env=env, timeout=30)
        return r.returncode, r.stdout
    except (OSError, subprocess.SubprocessError):
        return None, b""

def no_baseline(rc):
    return bad("run `git status` in the stack root to see why: the committed baseline cannot be read ("
               + ("git could not be run" if rc is None else "its .git cannot be looked at" if rc == "lstat" else f"git exit status {rc}") + ")")

def committed(rel):
    """(type, object id) of the entry HEAD holds for a root-relative path, or None for the one answer "no committed baseline",
    given only for a proven fact:
    - the root has no `.git` entry at all (this tool's own lstat), or
    - the repository has no commit yet: HEAD is a symbolic ref (exit 0) that resolves to nothing (exit 1 exactly; nothing can
      have been committed, so nothing can have been edited away from a commit), or
    - HEAD resolves to a commit object (exit 0 twice) and git lists the path with exit 0 and no entry.
    Every other answer (git cannot be run, any other exit status, a `.git` git cannot use, a missing object) is a refusal that
    gives the exit status, for every caller of the baseline: check, a dry run, apply, rollback."""
    try:
        os.lstat(os.path.join(el.ROOT, ".git"))
    except FileNotFoundError:
        return None
    except OSError:
        raise no_baseline("lstat")
    rc, _ = git("rev-parse", "-q", "--verify", "HEAD")
    if rc == 1 and git("symbolic-ref", "-q", "HEAD")[0] == 0:
        return None
    if rc == 0:
        rc, _ = git("cat-file", "-e", "HEAD^{commit}")
    if rc == 0:
        rc, out = git("ls-tree", "-z", "HEAD", "--", os.path.normpath(rel))
    if rc != 0:
        raise no_baseline(rc)
    return tuple(x.decode() for x in out.split(b"\t")[0].split()[1:3]) if out else None

def git_out(*args):
    rc, out = git(*args)
    if rc != 0:
        raise no_baseline(rc)
    return out

def git_blob(rel):
    """The committed bytes of a path, or None (a folder committed at a file's path gives its tree, which no file equals)."""
    e = committed(rel)
    return git_out("cat-file", *e) if e else None

def git_names(rel):
    """The names the committed folder holds (none when it is not committed; a git that cannot answer is a refusal)."""
    e = committed(rel)
    return [n.decode("utf-8", "replace") for n in git_out("ls-tree", "-z", "--name-only", e[1]).split(b"\0") if n] if e and e[0] == "tree" else []

def msg(code, problem):
    body, tag, kv = el.alert_catalog.render(code, {"problem": el.scrub(problem)})
    return body.split("\n")[1], tag, kv

def finding(r):
    """Code, message and one alert line for a check result that is not clean."""
    r["message"], tag, kv = msg(r["code"], r["problem"])
    el.alert_catalog.log(tag, kv)
    return r

def check_one(key, rel, tgt, A):
    rec = A.get(key)
    r = {"id": key, "path": rel}
    try:
        cur = read(tgt)
    except EventError:
        if not (os.path.isdir(tgt) and not os.path.islink(tgt) and (rec or git_blob(rel) is not None)):
            raise
        return finding({**r, "baseline": "applied" if rec else "git", "state": "drift", "code": "STL-CFG-314",
                        "problem": f"move the folder away and restore the file: {key} is a folder, its baseline is a file"})
    r["baseline"], r["state"], why = drift_of(key, rel, tgt, cur, rec)
    err = unfinished(key, cur)
    if err:   # an unfinished step is not a hand edit: its own code; an untrusted backup keeps 316
        r.update(state="refused" if err.code == "STL-CFG-316" else "pending", problem=err.problem,
                 code="STL-CFG-316" if err.code == "STL-CFG-316" else "STL-CFG-323")
    elif why:
        r.update(problem=why, code="STL-CFG-314")
    return finding(r) if "code" in r else r

def refused(label, e):
    """One problem line for something check cannot read; the other rows are still checked."""
    code = e.code if isinstance(e, EventError) else REFUSE[0]
    why = e.problem if isinstance(e, EventError) else f"cannot be read ({type(e).__name__})"
    m, tag, kv = msg(code, f"{label}: {why}")
    el.alert_catalog.log(tag, kv)
    return {"id": label, "path": None, "baseline": "none", "state": "refused", "code": code, "message": m, "problem": f"{label}: {why}"}

def names_of(row, only, A):
    if only:
        return [only]
    if not folder_row(row):
        return [row["id"]]
    d = path(row["path"])
    names = {n for n in (os.listdir(d) if os.path.isdir(d) else []) if n.endswith(".json")} | set(git_names(row["path"])) \
        | {k.partition("/")[2] for k in A if k.startswith(row["id"] + "/")}
    return [f"{row['id']}/{n}" for n in sorted(names) if n.endswith(".json")]

def do_check(arg, as_json):
    context()
    A = applied()
    if arg:
        did_ = arg.partition("/")[0]
        rs, only = [sd.row_of(did_)], (arg if "/" in arg else None)
        if only and not folder_row(rs[0]):
            raise bad(f"{did_} is a single file: give just its id")
    else:
        rs, only = sd.rows(), None
    out = []
    for row in rs:
        try:
            if row["id"] in context()["bad"]:
                raise bad(context()["bad"][row["id"]])
            if why := kind_drift(row, folder_row(row)):
                out.append(finding({"id": row["id"], "path": row["path"], "baseline": "index", "state": "refused", "code": "STL-CFG-310", "problem": why}))
                continue
            names = names_of(row, only, A)
        except (EventError, OSError) as e:
            out.append(refused(row["id"], e))
            continue
        for k in names:
            try:
                _, key, tgt, rel = target(k, read_only=True)
                out.append(check_one(key, rel, tgt, A))
            except (EventError, OSError) as e:
                out.append(refused(k, e))
    bad_ = [r for r in out if r["state"] in ("drift", "pending", "refused")]
    if as_json:
        print(json.dumps({"ok": not bad_, "files": out}, indent=2))
    else:
        for r in out:
            print(f"{r['code']} {r['message']}" if "code" in r else f"{r['state']:<12} {qs(r['id'])} (baseline {r['baseline']})")
            whole(r.get("problem", ""), sys.stdout)
    return 1 if bad_ else 0

def do_history(arg, as_json):
    context()
    row, key, tgt, rel = target(arg, read_only=True)
    gate(row)
    evs, nbad = el.read_log()
    evs = [e for e in evs if isinstance(e.get("what"), str) and (e["what"] == key or e["what"].startswith(key + "/"))]
    keys = [key]
    if folder_row(row) and "/" not in arg:
        d = bdir(key)
        keys = [f"{key}/{n}" for n in (os.listdir(d) if os.path.isdir(d) else []) if not n.startswith(".")]
    bs = []
    for k in keys:
        good, junk, strange, _ = scan(k)
        bs += [{"name": n, "status": m.get("status", "unreadable")} for n, m in good] + [{"name": n, "status": "unfinished"} for n in junk] \
            + [{"name": n, "status": "unrecorded"} for n, _ in strange]
    if nbad:
        el.say("STL-CFG-318", f"{nbad} line(s) of the event log are not event lines; they were skipped, the rest is shown")
    if as_json:
        print(json.dumps({"id": key, "events": evs, "backups": bs, "unreadable_lines": nbad}, indent=2, ensure_ascii=True))
    else:
        print("\n".join(f"{qs(e.get('time'))} {qs(e.get('type'))} {qs(e['what'])} {qs(e.get('detail', ''))}" for e in evs))
    return 0

def cause_of(e, read_cmd):
    """(code, text) of what stopped a command."""
    if isinstance(e, EventError):
        return e.code, e.problem
    if isinstance(e, sd.DataError):   # the data tool refuses a path or a row itself (leaves the root, bad index)
        return ("STL-CFG-310" if read_cmd else REFUSE[0]), str(e)[:160]
    if isinstance(e, OSError):
        return REFUSE[0], f"{type(e).__name__}: {e.strerror or ''}"
    if isinstance(e, (Interrupted, KeyboardInterrupt)):
        return REFUSE[0], "stopped by an interrupt"
    return REFUSE[0], f"unexpected {type(e).__name__}"   # never a value: the type of the exception only

def failed(e, read_cmd):
    """The one place a command's failure is told; whatever goes wrong while telling it is still one coded line. Its first
    statement puts the run in the stopping state (interrupted() raises nothing from then on): one undo, one line."""
    if isinstance(e, SystemExit):   # the data tool's own exit (an unknown id: its line is printed): nothing to tell unless steps were begun
        if not STEPS:
            return None
        e = Interrupted()
    STOPPING.append(0)
    for s in (signal.SIGINT, signal.SIGTERM):
        signal.signal(s, signal.SIG_IGN)
    try:
        return told(e, read_cmd)
    except BaseException as x:
        key = SNAP.get("key") or "the row"
        return fail("STL-CFG-321" if STEPS else REFUSE[0], f"run `check {key}`: the command stopped and what is left could not be read ({type(x).__name__})")

def told(e, read_cmd):
    """Undo the steps newest first, up to one that stays (an event line written, a folder removed) or an undo that fails. No step
    begun is the cause (its frame, or the problem, says nothing was changed). Else the text is read from the disk, compared with
    the start: equal says it was undone; else 321 with what is there and the one command."""
    code, why = cause_of(e, read_cmd)
    left = list(STEPS)
    while left:
        try:
            left[-1][2]()
        except BaseException:
            break
        left.pop()
    began = any(not s[4] for s in STEPS)
    if not began:   # every write is a step entered before it starts: none begun is nothing changed (no disk read needed, which a
        # swapped folder could make fail); said in the problem when the code's own frame does not say it
        try:
            frame = (el.alert_catalog.catalog().get(code) or {}).get("message", "")
        except Exception:   # the catalog is unreadable: say it in the problem
            frame = ""
        return fail(code, why if "nothing was changed" in frame.lower() else fit(f"{why}; nothing was changed", why), getattr(e, "extra", None))
    now = state_of(SNAP["key"], SNAP["tgt"]) if SNAP else None
    key, stop = SNAP.get("key"), isinstance(e, (Interrupted, KeyboardInterrupt))
    if not SNAP or SNAP["state"] == now:   # every text goes through fit(): the way out first, no cause cut by a fixed number
        undone = "what this command began was undone (the file holds the edit)" if SNAP.get("edited") else "it was undone (the file is as before)"
        again = f"run it again{'' if stop else ' once the cause is fixed'}: {key} stopped"
        return fail(code if code in UNDONE_OK else "STL-CFG-321",
                       fit(f"{why}; {undone}", why) if code in UNDONE_OK else fit(f"{again} ({why}); {undone}", f"{again}; {undone}"),
                       {"detail": "backups, applied state and event log as before; the file holds the edit" if SNAP.get("edited")
                        else "file, backups, applied state and event log as before"})
    try:   # the way out is the one `check` names for the key as the disk is now (unfinished)
        err = unfinished(key, read(SNAP["tgt"]))
        way = err.problem if err else "nothing to run (the change is complete)" if any(not s[4] for s in left) else f"run `check {key}`"
    except Exception:
        way = f"run `check {key}`"
    return fail("STL-CFG-321", fit(f"{way} (this command stopped: {why})", way),
                   {"detail": described(SNAP["state"], now, SNAP["want"])})

def interrupted(sig, frame):
    """The first SIGINT or SIGTERM puts the run in one state, stopping: both are ignored from then on (a second one, the same or
    the other, changes nothing) and the run ends through failed()."""
    if STOPPING:
        return
    STOPPING.append(sig)
    for s in (signal.SIGINT, signal.SIGTERM):
        signal.signal(s, signal.SIG_IGN)
    raise Interrupted(sig)

def main(argv):
    if argv[:1] == ["--check"]:   # the requirement text spells check as a flag
        argv = ["check", *argv[1:]]
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
    for x in (CTX, STEPS, SNAP, STOPPING):
        x.clear()
    el.LOG_REL = None
    read_cmd = o.cmd in ("check", "history")
    REFUSE[0] = "STL-CFG-322" if read_cmd else "STL-CFG-313"
    for s in (signal.SIGINT, signal.SIGTERM):
        signal.signal(s, interrupted)
    try:
        sweep_stage()
        if o.cmd == "apply":
            return do_apply(o.id, o.src, o.dry_run)
        if o.cmd == "rollback":
            return do_rollback(o.id)
        return do_check(o.id, o.json) if o.cmd == "check" else do_history(o.id, o.json)
    except Told as t:   # undone and told inside the lock
        return t.args[0]
    except SystemExit:
        raise
    except BaseException as e:   # never a traceback; no step is begun outside the lock
        try:
            return failed(e, read_cmd)
        except Interrupted:
            return failed(e, read_cmd)
    finally:   # an interrupt after the command's last line is too late to change anything
        with contextlib.suppress(Interrupted):
            STOPPING.append(0)
        for s in (signal.SIGINT, signal.SIGTERM):
            signal.signal(s, signal.SIG_IGN)
        flush()

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
