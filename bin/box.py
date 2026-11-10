"""OS box (option A), stdlib only: the bubblewrap mount list for one terminal call of a boxed profile.
plan() turns the card proof and the `sandbox` block of roles.json into mounts; box_argv() makes the bwrap argv. No profile,
role, path or project is named here: they come from the table, the card proof and the board's project roots. A path
the box must not show (owner settings, the canary, secret classes, hidden folders) is never mounted: every parent of
one is a tmpfs and each safe child is bound on its own, because /workspace is case-insensitive (9p) and a bind over one
spelling hides only that spelling. Any doubt raises BoxError and the terminal is refused (fail closed).
The card's branch ref is not bound from the shared refs/heads/<project> folder (HH-05: on the case-insensitive 9p mount a bind
over one spelling of a sibling's ref hides only that spelling): the box sees a private copy of its own ref, and run() applies
it to the real repo after the call, for this ref only, as a compare-and-swap.
"""
import ast, fnmatch, json, os, re, shutil, signal, stat, subprocess, sys, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import roles

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs/hermes-local/hooks/builder/secret-guard.py")
BASE = ["bwrap", "--unshare-user", "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup-try",
        "--disable-userns", "--die-with-parent", "--new-session", "--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev"]


class BoxError(Exception):
    pass


def secret_classes():
    """(SECRETS, SECRET_OK) read, not run, from secret-guard.py: the one list (no copy to drift)."""
    got = {}
    try:
        for n in ast.parse(open(HOOK, encoding="utf-8").read()).body:
            if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in ("SECRETS", "SECRET_OK"):
                got[n.targets[0].id] = [str(x) for x in ast.literal_eval(n.value)]
    except (OSError, SyntaxError, ValueError) as e:
        raise BoxError(f"secret classes cannot be read from secret-guard.py: {e}")
    if set(got) != {"SECRETS", "SECRET_OK"}:
        raise BoxError("secret-guard.py has no SECRETS / SECRET_OK constants")
    return got["SECRETS"], got["SECRET_OK"]


def _worktree(ws):
    """(worktree, git dir of the worktree, common git dir) from the worktree's own .git file; BoxError if it is not one."""
    ws = os.path.realpath(ws)
    try:
        line = open(ws + "/.git", encoding="utf-8").read().strip() if os.path.isfile(ws + "/.git") else ""
    except OSError:
        line = ""
    if not line.startswith("gitdir:"):
        raise BoxError(f"{ws} is not a linked worktree (no .git file with a gitdir: line)")
    gd = os.path.realpath(line[7:].strip())
    common = os.path.dirname(os.path.dirname(gd))
    if os.path.basename(os.path.dirname(gd)) != "worktrees" or not os.path.isdir(gd) or not os.path.isdir(common + "/objects"):
        raise BoxError(f"{ws}: its gitdir {gd} is not <repo>/.git/worktrees/<id>")
    try:
        back = open(gd + "/gitdir", encoding="utf-8").read().strip()
    except OSError:
        back = ""
    if os.path.realpath(back) != ws + "/.git":   # a worker can rewrite its .git file (a case variant of the read-only overlay): it must point at a git dir that points back
        raise BoxError(f"{ws}: its gitdir {gd} does not point back at {ws}/.git (the .git file was changed?)")
    return ws, gd, common


def plan(d, profile, proof, *, hermes_root, home, roots, stack_root=None, spec=None):
    """([mount tuples], env overrides) for one call. Mounts, in order (later ones override earlier ones):
    ("tmpfs", p), ("ro", src, dst), ("rw", src, dst), ("remount_ro", p). A role that commits also fills `spec` (when given):
    what run() needs to apply the card's own ref after the call."""
    sb = roles.sandbox(d)
    if not sb or profile not in sb["boxed_profiles"]:
        raise BoxError(f"profile {profile} is not in sandbox.boxed_profiles")
    role = d["roles"][d["profiles"][profile]["role"]]
    stack = os.path.realpath(stack_root or roles.ROOT)
    pdir = roles.pdir(hermes_root, profile, d["profiles"][profile])
    phome = pdir + "/home"
    if not os.path.isdir(phome):
        raise BoxError(f"profile {profile} has no home folder {phome}")
    roots_in = list(roots)
    roots = list(dict.fromkeys(os.path.realpath(r) for r in [stack, *roots]))   # the stack repo is always walked: the hide rules never depend on the board's project list
    roots = [r for r in roots if not any(r != o and r.startswith(o + "/") for o in roots)]   # a nested root is reached through its parent
    cf = lambda p: p.casefold()
    prot = [os.path.join(stack, p) for p in d["owner_settings"]] + [os.path.join(stack, sb["canary"])]
    protcf = {cf(x) for x in prot} | {cf(os.path.realpath(x)) for x in prot}
    for x in prot:
        if os.path.isfile(x) and os.stat(x).st_nlink > 1:
            raise BoxError(f"{x} has more than one hard link: a copy could be read through another name")
    hidecf = {cf(os.path.join(r, h)) for r in roots for h in sb["hide"]}
    secrets, secret_ok = secret_classes()
    for x in sb["home_ro"]:   # a read-only home bind must not be, or hold, a secret class folder (~/.claude, ~/.hermes, ~/.ssh ...)
        for sec in (z[2:] for z in secrets if z.startswith("~/")):
            if x == sec or sec.startswith(x + "/") or x.startswith(sec + "/"):
                raise BoxError(f"sandbox.home_ro entry {x} is or holds a secret class ({sec})")
    pats = [cf(s) for s in secrets if not s.startswith("~")]
    oks = {cf(s) for s in secret_ok}
    secret = lambda name: cf(name) not in oks and any(fnmatch.fnmatchcase(cf(name), p) for p in pats)

    must, env = {}, dict(sb.get("env", {}))   # path -> mounts emitted when the walk reaches it (the card's folders, wherever they sit)
    mode = role["workspace"]
    if mode != "none":
        wt, gd, common = _worktree(proof.get("workspace") or "")
        if common not in {os.path.realpath(r) + "/.git" for r in [stack, *roots_in]}:   # VH-01: the .git file is the box's to rewrite (case variant); the launcher runs git on this folder
            raise BoxError(f"{wt}: its git folder {common} is not the .git of the stack or of a board project root")
        wid, branch = os.path.basename(gd), proof.get("branch") or ""
        rw = mode == "git-worktree"
        if rw:
            bd = os.path.dirname(branch)
            if not bd or ".." in branch.split("/") or branch.startswith("/") or branch.endswith("/"):
                raise BoxError(f"branch {branch!r} has no folder part: refs/heads itself would become writable")
            refs, logs = f"{common}/refs/heads/{bd}", f"{common}/logs/refs/heads/{bd}"
            os.makedirs(refs, exist_ok=True); os.makedirs(logs, exist_ok=True)   # mount points, made outside the box: bwrap cannot make them under a read-only bind
            for f in ("commondir", "gitdir"):
                if not os.path.isfile(f"{gd}/{f}"):
                    raise BoxError(f"{gd}/{f} is missing")
            priv = sb["tmp_dir"].replace("{profile_dir}", pdir) + ".refs/" + uuid.uuid4().hex   # not under tmp_dir: the box does not see it, run() makes it
            if spec is not None:
                spec.update(common=common, branch=branch, priv=priv)
            must[wt] = [("rw", wt, wt), ("ro", f"{wt}/.git", f"{wt}/.git")]
            must[common] = [("ro", common, common)] + [("rw", x, x) for x in (f"{common}/objects", gd)] + \
                           [("rw", priv + "/refs", refs), ("rw", priv + "/logs", logs)] + \
                           [("ro", f"{gd}/{f}", f"{gd}/{f}") for f in ("commondir", "gitdir")]   # read-only over the writable folder
            env["HERMES_KANBAN_BRANCH"] = branch
            env["GIT_CONFIG_GLOBAL"] = pdir + "/home/.gitconfig"   # HH-06: HOME=<dir> / XDG_CONFIG_HOME=<dir> cannot make git read a planted config (the commit hook stays on); the file is read-only (home_protect)
        else:
            must[wt], must[common] = [("ro", wt, wt)], [("ro", common, common)]
            env["GIT_DIR"], env["GIT_WORK_TREE"] = gd, wt   # S6I-01: git here never discovers a repo the builder planted in a subfolder (its config can name programs git runs)
        env["HERMES_KANBAN_WORKSPACE"] = wt   # the commit guard's marker: the proof cannot run inside the box (design 4.4)
    inside = lambda p, m: p == m or p.startswith(m + "/")
    out, done = [("tmpfs", "/tmp")] + ([("tmpfs", "/commandhistory")] if os.path.isdir("/commandhistory") else []), set()

    def kid(root, parent, name, hidden):
        full = f"{parent}/{name}"
        if cf(full) in protcf or secret(name):
            return
        if os.path.islink(full):
            r = os.path.realpath(full)
            if not r.startswith(root + "/") or any(inside(cf(r), h) or inside(h, cf(r)) for h in hidecf | protcf):
                return   # leaves the root, or points at / into a hidden or owner path
            out.append(("ro", r, full))
        else:
            walk(root, full, hidden)

    def walk(root, p, hidden, top=False):
        if p in must:
            out.extend(must[p]); done.add(p); return
        anc = any(m.startswith(p + "/") for m in must)
        pc = cf(p)
        hidden = hidden or pc in hidecf
        if (hidden or os.path.basename(p) in sb["sibling_dirs"]) and not anc:
            return   # not mounted: a hidden folder, or a folder of sibling cards
        if os.path.isdir(p) and not (top or anc or any(x.startswith(pc + "/") for x in protcf | hidecf)):
            out.append(("ro", p, p)); return
        if not os.path.isdir(p):
            out.append(("ro", p, p)); return
        out.append(("tmpfs", p))
        for name in sorted(os.listdir(p)):
            full = f"{p}/{name}"
            need = full in must or any(m.startswith(full + "/") for m in must)
            if (hidden or os.path.basename(p) in sb["sibling_dirs"]) and not need:
                continue
            kid(root, p, name, hidden)
        out.append(("remount_ro", p))

    for r in sorted(roots):
        if os.path.isdir(r):
            walk(r, r, False, top=True)
    for m in sorted(must):
        if m not in done:
            out.extend(must[m]); done.add(m)

    ro_home = mode == "read-parent-worktree"   # a role that only reads: its profile home is read-only and HOME is a private tmpfs, so builder code it runs cannot persist anything
    h, H = os.path.realpath(home), hermes_root
    if h == os.path.realpath(phome) or h.startswith(os.path.realpath(phome) + "/"):
        raise BoxError(f"home {h} is inside the profile home {phome}: pass the real home, not $HOME of a worker")
    out.append(("tmpfs", h))
    out += [("ro", f"{h}/{x}", f"{h}/{x}") for x in sb["home_ro"] if os.path.exists(f"{h}/{x}")]
    tmpd = sb["tmp_dir"].replace("{profile_dir}", pdir)
    os.makedirs(tmpd, exist_ok=True)
    out += [("tmpfs", H), ("ro" if ro_home else "rw", phome, phome)]
    for x in ([] if ro_home else sb.get("home_protect", [])):   # unboxed Hermes runs hooks with HOME set to this folder: nothing a worker plants here may be code they load
        pth = phome + "/" + x.rstrip("/")
        if any(os.path.islink(q) for q in (pth, os.path.dirname(pth))):
            raise BoxError(f"home_protect entry {x} is, or sits in, a symlink")
        if not os.path.exists(pth):
            (os.makedirs(pth) if x.endswith("/") else (os.makedirs(os.path.dirname(pth), exist_ok=True), open(pth, "a").close()))
        out.append(("ro", pth, pth))
    out += ([("ro", pdir + "/skills", pdir + "/skills")] if os.path.isdir(pdir + "/skills") else []) \
        + [("rw", tmpd, tmpd), ("remount_ro", H), ("remount_ro", h)]
    env.update(HOME="/tmp" if ro_home else phome, TMPDIR="/tmp", TMP="/tmp", TEMP="/tmp")
    ov = sb["profile_overrides"].get(profile, {})
    if ov.get("claude_config_dir"):
        cdir = ov["claude_config_dir"].replace("{home}", phome)
        if any(os.path.islink(q) for q in (cdir, os.path.dirname(cdir))):
            raise BoxError(f"{cdir} is, or sits in, a symlink: nothing is created through it")
        os.makedirs(cdir, exist_ok=True); env["CLAUDE_CONFIG_DIR"] = cdir
        out.append(("ro" if ro_home else "rw", cdir, cdir))   # a mount point cannot be renamed or removed (EBUSY): the folder cannot be swapped for a planted one; writes inside it still work
        for name in ov.get("ro_over", []):
            x = f"{cdir}/{name}"
            if os.path.islink(x):
                raise BoxError(f"{x} is a symlink")
            if not os.path.exists(x):   # shortcut: a dotted name is a file, else a folder; put a type in the data if an entry breaks that
                (open(x, "a").close() if "." in name else os.makedirs(x))
            out.append(("ro", x, x))
        for name in ov.get("rw_files", []):   # D102: one writable file in a read-only folder (the login's token refresh); a file bind, so it cannot be renamed, removed or swapped for a link
            x = f"{cdir}/{name}"
            if os.path.islink(x) or not os.path.isfile(x):   # shortcut: the file must already exist (the owner's login made it); nothing creates it here
                continue
            out.append(("rw", x, x))
    verify(out, hidecf, protcf, list(must))
    return out, env


def verify(mounts, hidecf, protcf, musts):
    """Pre-exec check: no bind source is, contains, or (unless it is a card folder) lies inside an owner, canary or hidden path."""
    mc = [m.casefold() for m in musts]
    for op, *p in mounts:
        if op not in ("ro", "rw"):
            continue
        s = p[0].casefold()
        if any(x == s or x.startswith(s + "/") for x in protcf | hidecf):
            raise BoxError(f"bind source {p[0]} is or contains an owner, canary or hidden path")
        if any(s.startswith(h + "/") for h in hidecf) and not any(s == m or s.startswith(m + "/") for m in mc):
            raise BoxError(f"bind source {p[0]} lies inside a hidden folder")


def box_argv(d, profile, proof, *, hermes_root, home, roots, stack_root=None):
    """(bwrap argv prefix, env overrides): append `--chdir <cwd> bash -c <script>` to run a command in the box."""
    spec = {}
    mounts, env = plan(d, profile, proof, hermes_root=hermes_root, home=home, roots=roots, stack_root=stack_root, spec=spec)
    flag = {"tmpfs": ["--tmpfs"], "ro": ["--ro-bind"], "rw": ["--bind"], "remount_ro": ["--remount-ro"]}
    argv = BASE + [a for op, *p in mounts for a in flag[op] + p]
    if spec:   # a role that commits: the launcher applies the card's own ref when the call ends
        argv = [sys.executable, "-I", os.path.abspath(__file__), "run", json.dumps(spec), "--"] + argv
    return argv, env


def _git(spec, *args):
    """git on the real repo, outside the box, with no config but the system file (its safe.directory list)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    return subprocess.run(["git", "--git-dir", spec["common"], "-c", "core.hooksPath=/dev/null", *args], env=env,
                          capture_output=True, text=True, timeout=60)


def _plain_id(path):
    """The one commit id a plain file holds, else "": a symlink, a device or garbage written by the box is never followed or applied."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return ""
    try:
        text = os.read(fd, 100).decode("ascii", "replace").strip() if stat.S_ISREG(os.fstat(fd).st_mode) else ""
    finally:
        os.close(fd)
    return text if re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", text) else ""


def run(spec, cmd):
    """Run `cmd` (the bwrap argv) with a private copy of the card's ref; afterwards apply that ref, and only that ref, to the real repo.
    Exit code = the command's. shortcut: a launcher killed with SIGKILL applies nothing (the commit objects stay, the ref does not
    move) and leaves its private folder behind; a call that overlaps another call of the same card loses its ref update (compare-and-swap)."""
    ref, name, priv = "refs/heads/" + spec["branch"], os.path.basename(spec["branch"]), spec["priv"]
    old = _git(spec, "rev-parse", "--verify", "-q", ref + "^{commit}").stdout.strip()
    if not old:
        print(f"box: cannot read the card branch {spec['branch']}; nothing was run", file=sys.stderr)
        return 126
    os.makedirs(priv + "/refs"); os.makedirs(priv + "/logs")
    with open(f"{priv}/refs/{name}", "w") as f:
        f.write(old + "\n")
    child, early = [], []
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):   # a kill meant for the call ends the box; this process stays to apply the ref
        signal.signal(sig, lambda n, _f: child[0].send_signal(n) if child else early.append(n))
    child.append(subprocess.Popen(cmd))
    for n in early:   # a signal that came before the box existed
        child[0].send_signal(n)
    rc = child[0].wait()
    rc = rc if rc >= 0 else 128 - rc
    new = _plain_id(f"{priv}/refs/{name}")
    if not new:
        print("box: the card branch in the box is not a plain commit id; not applied", file=sys.stderr)
    elif new != old:
        r = _git(spec, "update-ref", "--no-deref", "-m", "box: card branch after a boxed call", ref, new, old)
        if r.returncode:
            print(f"box: the card branch was not updated ({r.stderr.strip()[:200]})", file=sys.stderr)
    shutil.rmtree(priv, ignore_errors=True)
    return rc


if __name__ == "__main__" and sys.argv[1:2] == ["run"]:
    sys.exit(run(json.loads(sys.argv[2]), sys.argv[4:]))
