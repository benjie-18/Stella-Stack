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
import ast, contextlib, fnmatch, json, os, re, shutil, signal, stat, subprocess, sys, tarfile, time, uuid

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
    try:
        cd = open(gd + "/commondir", encoding="utf-8").read().strip()
    except OSError:
        cd = ""
    if not cd or os.path.realpath(os.path.join(gd, cd)) != common:   # on the case-insensitive mount a builder can rewrite gd/COMMONDIR although commondir is a read-only bind: git would then read a config of its choosing
        raise BoxError(f"{ws}: the git dir {gd} has a changed commondir ({cd[:80]!r}); it must point at {common}")
    try:
        r = subprocess.run(["git", "config", "--file", common + "/config", "--type=bool", "--get", "extensions.worktreeConfig"], capture_output=True, text=True,
                           timeout=60, env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"})
        bad_cfg = r.returncode not in (0, 1) or r.stdout.strip() == "true"
    except (OSError, subprocess.SubprocessError):
        bad_cfg = True
    if bad_cfg:   # <gd>/config.worktree is writable in a builder box and would become a config git reads; an unreadable or odd value refuses too
        raise BoxError(f"{common}/config sets extensions.worktreeConfig (or git cannot read it): a worktree's own config file would be builder-writable")
    return ws, gd, common


def _broker(hermes_root, name):
    """The secret `name` from the host-side broker folder <hermes root>/broker (never mounted in a box), or "" when it holds none yet.
    shortcut: a plain folder of 0600 files stands in for the broker of SUPERVISOR.md (D20, not built); swap this one function when it exists."""
    path = os.path.join(hermes_root, "broker", name)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return ""
    except OSError as e:
        raise BoxError(f"broker secret {name} cannot be opened safely ({type(e).__name__})")
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise BoxError(f"broker secret {name} is not a plain file owned by this user with mode 600")
        val = os.read(fd, 4097).decode("ascii", "replace")
    finally:
        os.close(fd)
    val = val[:-1] if val.endswith("\n") else val
    if not re.fullmatch(r"[A-Za-z0-9_.~+/=-]{16,4096}", val):
        raise BoxError(f"broker secret {name} does not look like a token (16-4096 characters of A-Za-z0-9_.~+/=-)")
    return val


def _escaping_links(wt, allow=()):
    """The first symlink in the worktree that resolves outside it, or whose target is under /proc ('' if none): a read-only role's box does not
    start with one (follow-up 4, item 3). A folder that cannot be listed refuses the box (a link inside it would be invisible here). `allow` are absolute
    folders from the role table (review_link_allow, each ending in /) that a link's REAL target may sit in (a tool link such as .venv/bin/python -> /usr/bin/python3);
    /proc is never allowed."""
    stack = [wt]
    while stack:
        d = stack.pop()
        try:
            with os.scandir(d) as it:
                for e in it:
                    if e.is_symlink():
                        t = os.path.realpath(e.path)
                        inside = t.casefold() == wt.casefold() or t.casefold().startswith(wt.casefold() + "/")
                        if (not inside and not any(t.startswith(a if a.endswith("/") else a + "/") for a in allow)) or t.startswith("/proc"):
                            return f"{os.path.relpath(e.path, wt)} -> {t}"
                    elif e.is_dir(follow_symlinks=False):
                        stack.append(e.path)
        except OSError as err:
            raise BoxError(f"the worktree folder {d} cannot be scanned for symlinks ({type(err).__name__}); the reviewing box does not start")
    return ""


def trusted_answers(d, comments, prefix):
    """The owner's answers recorded on a card: comment bodies that start with the escalation poller's prefix AND were written by a profile whose role has may_answer_for_owner
    (the coordinator's, which the poller runs as). The kanban guard also refuses that text from agents, but it is fail-open; the author is the second check."""
    if not prefix:
        return []
    poller = {n for n, pr in d["profiles"].items() if d["roles"][pr["role"]].get("may_answer_for_owner") is True}
    return [c["body"] for c in comments or [] if isinstance(c, dict) and c.get("author") in poller and isinstance(c.get("body"), str)
            and c["body"].startswith(prefix)]


def _clip(text, n):
    return text if len(text) <= n else text[:n] + "\n[clipped]"


def _git_ro(common, *a):
    """git over the shared object store only (--git-dir=<common>): never the builder's worktree, index or worktree git dir, so no config,
    attribute, submodule or filter a builder wrote can make this host-side call run code. The common config is read-only to builders."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
    base = ["git", f"--git-dir={common}", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "log.showSignature=false",
            "-c", "safe.directory=*", "-c", "diff.external=", "-c", "core.pager=cat"]
    return subprocess.run(base + list(a), env=env, capture_output=True, timeout=60)


def _export_tip(common, branch, dest_root, card, max_files, max_bytes, allow, keep_hours):
    """Export exactly the committed tree of `branch` (git archive, read in-process) to <dest_root>/<card>-<tip>; returns that folder.
    Claude reads this folder, not the builder's worktree: what is not committed is not there, and a detached HEAD, an index flag or an
    ignore file in the worktree changes nothing. Regular files and folders first, symlinks last and only where the parent folder really is
    inside the export (a member below a symlink member is refused before anything is written); caps on size and count come from the role table."""
    r = _git_ro(common, "rev-parse", "--verify", "-q", f"refs/heads/{branch}^{{commit}}")
    tip = r.stdout.decode("ascii", "replace").strip()
    if r.returncode or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", tip):
        raise BoxError(f"the card branch {branch} cannot be read, so there is nothing to review")
    safe_card = re.sub(r"[^A-Za-z0-9_.-]", "_", card)[:40]
    dest = os.path.join(dest_root, f"{safe_card}-{tip[:16]}")
    os.makedirs(dest_root, exist_ok=True)
    for old in os.listdir(dest_root):   # an older export of the same card, and any export (finished cards) older than review_export_keep_hours
        full = os.path.join(dest_root, old)
        if full == dest:
            continue
        try:
            stale = time.time() - os.lstat(full).st_mtime > keep_hours * 3600
        except OSError:
            stale = False
        if old.startswith(safe_card + "-") or stale:
            shutil.rmtree(full, ignore_errors=True)
    if os.path.isdir(dest):   # reuse: refresh its age (another card's call must not prune it mid-review) and check its links again against the current allow-list
        with contextlib.suppress(OSError):
            os.utime(dest)
        bad = _escaping_links(dest, allow)
        if bad:
            raise BoxError(f"the cached export of {branch} holds a symlink that leaves it ({bad}); the reviewing box does not start")
        return dest
    tmp = dest + ".part"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    root = os.path.realpath(tmp)
    empty = dest + ".empty"   # git archive reads attributes (export-ignore hides files, export-subst rewrites content and may run gpg): read none, from an empty folder
    os.makedirs(empty, exist_ok=True)
    proc = subprocess.Popen(["git", f"--git-dir={common}", "-c", "core.hooksPath=/dev/null", "-c", "core.attributesFile=/dev/null", "-c", "gpg.program=false",
                             "-c", "gpg.ssh.program=false", "-c", "gpg.x509.program=false", "archive", "--format=tar", "--worktree-attributes", tip],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=empty,
                            env={"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_INDEX_FILE": os.path.join(empty, "no-index"),
                                 "PATH": os.environ.get("PATH", "/usr/bin:/bin")})
    links, total, count = [], 0, 0
    try:
        with tarfile.open(fileobj=proc.stdout, mode="r|") as tf:
            for m in tf:
                count += 1
                name = os.path.normpath(m.name)
                if count > max_files:
                    raise BoxError(f"the committed tree of {branch} has more than {max_files} files (review_max_files)")
                if name.startswith("/") or name == ".." or name.startswith("../"):
                    raise BoxError(f"the committed tree of {branch} has an unsafe path")
                target = os.path.join(tmp, name)
                if m.isdir():
                    os.makedirs(target, exist_ok=True)
                elif m.isreg():
                    total += m.size
                    if total > max_bytes:
                        raise BoxError(f"the committed tree of {branch} is over {max_bytes // (1024 * 1024)} MB (review_max_mb)")
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    with open(target, "wb") as fh:
                        shutil.copyfileobj(tf.extractfile(m), fh)
                    os.chmod(target, 0o755 if m.mode & 0o111 else 0o644)
                elif m.issym():
                    links.append((m.linkname, target, name))
                # anything else (devices, fifos, hard links) is skipped
        for linkname, target, name in links:
            parent = os.path.dirname(target)
            if os.path.realpath(parent) != os.path.join(root, os.path.dirname(name)).rstrip("/") and os.path.realpath(parent) != root:
                raise BoxError(f"the committed tree of {branch} has a member below a symlink ({name}); the reviewing box does not start")
            if not os.path.isdir(parent):
                raise BoxError(f"the committed tree of {branch} has a symlink ({name}) without its folder; the reviewing box does not start")
            if os.path.lexists(target):
                raise BoxError(f"the committed tree of {branch} names {name} twice; the reviewing box does not start")
            os.symlink(linkname, target)
    except (tarfile.TarError, OSError) as e:
        shutil.rmtree(tmp, ignore_errors=True)
        raise BoxError(f"the committed tree of {branch} cannot be exported: {type(e).__name__}")
    except BoxError:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    finally:
        proc.stdout.close(); proc.wait()
        shutil.rmtree(empty, ignore_errors=True)
    bad = _escaping_links(tmp, allow)
    if bad:
        shutil.rmtree(tmp, ignore_errors=True)
        raise BoxError(f"the committed tree holds a symlink that leaves it ({bad}); the reviewing box does not start")
    os.rename(tmp, dest)
    return dest


def _review_prompt(path, proof, common, lim):
    """The text Claude is asked (follow-up 4, item 5): the owner's fixed template with four slots filled by the stack, in one pass, from the
    card (id, body, the owner's recorded answers) and from git read over the shared object store only: {{CARD}}, {{BODY}}, {{ANSWERS}}, {{EVIDENCE}}.
    The commit subjects and file names inside the evidence are still the worker's own text; the template says so."""
    try:
        template = open(path, encoding="utf-8").read()
    except OSError as e:
        raise BoxError(f"the review prompt template {path} cannot be read: {e}")
    branch = proof.get("branch") or "HEAD"

    def g(label, *a):
        try:
            r = _git_ro(common, *a)
            out = r.stdout.decode("utf-8", "replace").strip() if r.returncode == 0 else f"(unavailable: git exited {r.returncode})"
        except (OSError, subprocess.TimeoutExpired) as e:
            out = f"(unavailable: {type(e).__name__})"
        return f"{label}\n{_clip(out, lim['review_clip_evidence']) or '(none)'}"

    evidence = "\n\n".join([
        g("The newest commits on the card's branch, with the files each one changed (newest first):",
          "log", "-n", str(lim["review_commits"]), "--stat", "--no-ext-diff", "--no-textconv", "--format=commit %h %s", f"refs/heads/{branch}", "--")])
    vals = {"CARD": str(proof.get("card") or "")[:40], "BODY": _clip(str(proof.get("body") or ""), lim["review_clip_body"]),
            "ANSWERS": _clip("\n".join(str(x) for x in proof.get("answers") or []) or "(none)", lim["review_clip_answers"]), "EVIDENCE": evidence}
    vals = {k: v.replace("===", "= = =") for k, v in vals.items()}   # the template's fence lines cannot be forged from inside a slot
    return re.sub(r"\{\{(CARD|BODY|ANSWERS|EVIDENCE)\}\}", lambda m: vals[m[1]], template)


def plan(d, profile, proof, *, hermes_root, home, roots, stack_root=None, spec=None, command=None):
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

    must, env = {}, dict(sb.get("env", {}))
    review_mount = None   # path -> mounts emitted when the walk reaches it (the card's folders, wherever they sit)
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
                spec.update(common=common, branch=branch, priv=priv, wt=wt, gd=gd, expect=_expected(wt, gd, common))
            must[wt] = [("rw", wt, wt), ("ro", f"{wt}/.git", f"{wt}/.git")]
            must[common] = [("ro", common, common)] + [("rw", x, x) for x in (f"{common}/objects", gd)] + \
                           [("rw", priv + "/refs", refs), ("rw", priv + "/logs", logs)] + \
                           [("ro", f"{gd}/{f}", f"{gd}/{f}") for f in ("commondir", "gitdir")]   # read-only over the writable folder
            env["HERMES_KANBAN_BRANCH"] = branch
            env["GIT_CONFIG_GLOBAL"] = pdir + "/home/.gitconfig"   # HH-06: HOME=<dir> / XDG_CONFIG_HOME=<dir> cannot make git read a planted config (the commit hook stays on); the file is read-only (home_protect)
        else:
            ov_r = sb["profile_overrides"].get(profile, {})
            rpath = ov_r.get("review_prompt")
            if rpath:
                missing = [k for k in roles.REVIEW_INT_KEYS if not isinstance(ov_r.get(k), int)]
                if missing or not isinstance(ov_r.get("review_answer_prefix"), str):
                    raise BoxError(f"a review_prompt needs {', '.join(missing + ([] if isinstance(ov_r.get('review_answer_prefix'), str) else ['review_answer_prefix']))} in the role table (no limit is hard-coded)")
                text = _review_prompt(os.path.join(stack, rpath), proof, common, ov_r)
                tmp_for_prompt = sb["tmp_dir"].replace("{profile_dir}", pdir)
                os.makedirs(tmp_for_prompt, exist_ok=True)
                rdir = pdir + "/review"   # host-only: bound read-only into the box, so nothing in the box can change the prompt or the export (red-team S6M-RC C-04)
                if os.path.islink(rdir):
                    raise BoxError(f"{rdir} is a symlink")
                os.makedirs(rdir, mode=0o700, exist_ok=True)
                card = re.sub(r"[^A-Za-z0-9_.-]", "_", str(proof.get("card") or "card"))[:40]
                pf = os.path.join(rdir, f"review-prompt-{card}.txt")   # one file per card: concurrent cards of the profile never share a prompt
                fd = os.open(pf + ".new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write(text)
                os.replace(pf + ".new", pf)
                env["REVIEW_PROMPT_FILE"] = pf
                env["REVIEW_SENT_FILE"] = os.path.join(tmp_for_prompt, f"review-sent-{card}.txt")
                if ov_r.get("review_model"):
                    env["REVIEW_MODEL"] = ov_r["review_model"]
                env["REVIEW_EXPORT_DIR"] = _export_tip(common, proof.get("branch") or "", os.path.join(rdir, "export"), card,
                                                       ov_r["review_max_files"], ov_r["review_max_mb"] * 1024 * 1024,
                                                       ov_r.get("review_link_allow", []), ov_r["review_export_keep_hours"])
                review_mount = rdir
            env["GIT_COMMON_DIR"] = common   # a rewritten commondir cannot send git to a config of the builder's choosing
            bad = _escaping_links(wt, ov_r.get("review_link_allow", []))
            if bad:   # a read-only role's tools follow links: one to the login, /proc or anywhere else outside the card would read it
                raise BoxError(f"the worktree holds a symlink that leaves it ({bad}); the reviewing box does not start")
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
        + [("rw", tmpd, tmpd)] + ([("ro", review_mount, review_mount)] if review_mount else []) + [("remount_ro", H), ("remount_ro", h)]
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
    got_all = True
    when = ov.get("broker_when")
    gets = not when or (command is not None and re.fullmatch(when, command) is not None)   # the token goes to the one command that needs it (red-team S6L-H1)
    for var, secret_name in ov.get("broker_env", {}).items():
        val = _broker(hermes_root, secret_name)
        if val:
            if gets:
                env[var] = val
        else:
            got_all = False
    if ov.get("claude_config_dir") and got_all:   # the login file is hidden only once the broker supplies the token; before that it is the stop-gap
        cdir = ov["claude_config_dir"].replace("{home}", phome)
        for name in ov.get("hide_files", []):   # follow-up 4: the login file reads empty in the box (the token comes from the broker), so no symlink or tool can read it there
            x = f"{cdir}/{name}"
            if os.path.islink(x) or (os.path.isfile(x) and os.stat(x).st_nlink > 1):
                raise BoxError(f"{x} is a symlink or has more than one hard link: a copy could be read under another name")
            if os.path.isfile(x):
                empty = pdir + "/.empty"   # not /dev/null: a bind of a device node is nodev inside the box and reads EACCES
                if not os.path.isfile(empty):
                    open(empty, "w").close()
                out.append(("ro", empty, x))
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


def box_argv(d, profile, proof, *, hermes_root, home, roots, stack_root=None, command=None):
    """(bwrap argv prefix, env overrides): append `--chdir <cwd> bash -c <script>` to run a command in the box."""
    spec = {}
    mounts, env = plan(d, profile, proof, hermes_root=hermes_root, home=home, roots=roots, stack_root=stack_root, spec=spec, command=command)
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


def _expected(wt, gd, common):
    """The three files as git writes them for a linked worktree whose triple (worktree, git dir, common dir) plan() has validated: never read back from disk."""
    return {wt + "/.git": f"gitdir: {gd}\n", gd + "/commondir": os.path.relpath(common, gd) + "\n", gd + "/gitdir": wt + "/.git\n"}


def _snapshot_git(spec):
    """The bytes of the three files that tell git where a card's repo is: <wt>/.git, <gd>/commondir, <gd>/gitdir (None when absent)."""
    out = {}
    if "expect" in spec:   # what plan() validated, not what an overlapping call may have left on disk
        return {p: t.encode() for p, t in spec["expect"].items()}
    if "wt" not in spec or "gd" not in spec:   # a spec that plan() did not build (the launcher's own tests) has nothing to check
        return out
    for p in (spec["wt"] + "/.git", spec["gd"] + "/commondir", spec["gd"] + "/gitdir"):
        try:
            out[p] = open(p, "rb").read()
        except OSError:
            out[p] = None
    return out


def _unique(path):
    """A name next to `path` that does not exist yet (a quarantine never replaces or deletes anything)."""
    n, i = path, 0
    while os.path.lexists(n):
        i += 1
        n = f"{path}.{os.getpid()}.{i}"
    return n


def _restore_file(path, data):
    """`path` becomes a regular file holding exactly `data`, whatever spelling of its name (the 9p mount ignores case) or kind (a symlink, a folder) the box left there.
    The old entries are removed, never written through, and the new file is created exclusively without following links."""
    d, base = os.path.split(path)
    names = [n for n in os.listdir(d) if n.casefold() == base.casefold()]
    try:
        ok = names == [base] and not os.path.islink(path) and os.path.isfile(path) and open(path, "rb").read() == data
    except OSError:
        ok = False
    if ok:
        return
    for n in names:
        full = os.path.join(d, n)
        if os.path.isdir(full) and not os.path.islink(full):
            shutil.rmtree(full, ignore_errors=True)
        else:
            os.unlink(full)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)


def _sanitise(spec, snap):
    """The sweep, with a last resort: if it cannot finish for any reason (a folder the box made read-only ...), the card's git dir is renamed aside so the host cannot read the builder's repo through it."""
    try:
        _sanitise_inner(spec, snap)
    except Exception:
        _last_resort(spec)


def _last_resort(spec):
    gd = spec.get("gd")
    if not gd:
        return
    for p in (spec.get("wt"), gd):
        with contextlib.suppress(Exception):
            os.chmod(p, 0o755)
    with contextlib.suppress(Exception):
        os.rename(gd, _unique(gd + ".box-quarantined"))   # the parent (<common>/worktrees) is read-only in the box: this rename needs no right on gd itself


def _sanitise_inner(spec, snap):
    """After a builder's boxed call (final red-team S6N-01, S6O-01..04). Hermes runs `git status` / `git log` in the card's worktree on the HOST when the card
    completes or is archived, with no `--ignore-submodules`: a nested repo behind a gitlink with a `filter.<x>.clean` command, or a .git / commondir the builder
    rewrote (a case variant or a symlink on the 9p mount), would run builder code as the owner. So the files git trusts go back to the recorded bytes, and a nested
    repo's own .git (any spelling) behind a gitlink of the card's index is moved aside; the gitlink itself stays. Anything the sweep cannot account for (an index git
    cannot list, a gitlink path outside the worktree, an error on one entry) fails closed: the card's index is moved aside, so the host sees no gitlink at all.
    The host reads the index with --git-dir=<common> only. A launcher killed with SIGKILL is covered by a detached helper (run()); the full fix is in Hermes."""
    if not snap:
        return
    for p in (spec["wt"], spec["gd"]):   # a box can leave its folders unwritable (9p honours modes)
        with contextlib.suppress(OSError):
            os.chmod(p, os.stat(p).st_mode | 0o700)
    for p, data in snap.items():
        if data is not None:
            _restore_file(p, data)
    bad = False
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_INDEX_FILE": spec["gd"] + "/index"}
    root = os.path.realpath(spec["wt"])
    try:
        r = subprocess.run(["git", f"--git-dir={spec['common']}", "-c", "core.fsmonitor=false", "ls-files", "-s", "-z"], env=env, cwd="/",
                           capture_output=True, timeout=60)
        entries = r.stdout.split(b"\0") if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        entries = None
    if entries is None:
        bad = os.path.lexists(spec["gd"] + "/index")
        entries = []
    for ent in entries:
        meta, _, path = ent.partition(b"\t")
        if not meta.startswith(b"160000"):
            continue
        try:
            rel = os.path.normpath(path.decode("utf-8", "surrogateescape"))
            if rel.startswith("/") or rel == ".." or rel.startswith("../") or rel == ".":
                bad = True
                continue
            d = os.path.join(spec["wt"], rel)
            if not os.path.lexists(d):
                continue
            if os.path.islink(d) or os.path.realpath(d) != os.path.join(root, rel) or not os.path.isdir(d):
                bad = True
                continue
            os.chmod(d, os.stat(d).st_mode | 0o700)
            for name in os.listdir(d):
                if name.casefold() == ".git":
                    os.rename(os.path.join(d, name), _unique(os.path.join(d, ".box-quarantined-git")))
        except (OSError, UnicodeError):
            bad = True
    if bad and os.path.lexists(spec["gd"] + "/index"):
        os.rename(spec["gd"] + "/index", _unique(spec["gd"] + "/index.box-quarantined"))


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
    snap = _snapshot_git(spec)
    if snap:   # a launcher that Hermes kills with SIGKILL after a timeout cannot sweep: a helper in its own session does it once the launcher is gone
        import base64
        enc = json.dumps({k: (base64.b64encode(v).decode() if v is not None else None) for k, v in snap.items()})
        subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "sweep", json.dumps(spec), enc, str(os.getpid())], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
    child.append(subprocess.Popen(cmd))
    for n in early:   # a signal that came before the box existed
        child[0].send_signal(n)
    ppid0 = os.getppid()   # a launcher already reparented to init (parent 1) at start is orphaned from the first moment
    while True:   # a launcher whose parent (the Hermes worker) died ends its box instead of outliving it: archive/cleanup could otherwise run while the box is still writing
        try:
            rc = child[0].wait(timeout=0.5)
            break
        except subprocess.TimeoutExpired:
            if os.getppid() != ppid0 or ppid0 == 1:
                child[0].send_signal(signal.SIGTERM)
                try:
                    rc = child[0].wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child[0].kill()
                    rc = child[0].wait()
                break
    rc = rc if rc >= 0 else 128 - rc
    try:
        _sanitise(spec, snap)
    except (OSError, subprocess.SubprocessError) as e:
        print(f"box: the card's git files were not checked after the call ({type(e).__name__})", file=sys.stderr)
    new = _plain_id(f"{priv}/refs/{name}")
    if not new:
        print("box: the card branch in the box is not a plain commit id; not applied", file=sys.stderr)
    elif new != old:
        r = _git(spec, "update-ref", "--no-deref", "-m", "box: card branch after a boxed call", ref, new, old)
        if r.returncode:
            print(f"box: the card branch was not updated ({r.stderr.strip()[:200]})", file=sys.stderr)
    shutil.rmtree(priv, ignore_errors=True)
    return rc


def _sweep_after(spec, enc, pid):
    """The detached helper of run(): wait until the launcher `pid` is gone (and with it the box, which dies with its parent), then sweep."""
    import base64, time
    while True:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            break
        except PermissionError:
            pass
        time.sleep(0.2)
    time.sleep(0.5)
    snap = {k: (base64.b64decode(v) if v is not None else None) for k, v in json.loads(enc).items()}
    try:
        _sanitise(spec, snap)
    except (OSError, subprocess.SubprocessError):
        pass


if __name__ == "__main__" and sys.argv[1:2] == ["run"]:
    sys.exit(run(json.loads(sys.argv[2]), sys.argv[4:]))
if __name__ == "__main__" and sys.argv[1:2] == ["sweep"]:
    _sweep_after(json.loads(sys.argv[2]), sys.argv[3], int(sys.argv[4]))
