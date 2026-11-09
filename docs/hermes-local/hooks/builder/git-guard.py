#!/usr/bin/env python3
"""Builder git guard (D36): pre_tool_call on terminal and process_manage for every
profile whose role installs it (docs/hermes-local/roles.json, D46).
Refuses git config (and git -c), --no-verify (and commit -n), git add -A/--all/., and git push to main, including inside
quoted strings (bash -c '…', opencode run '…'). K1b: any ref update of main (update-ref, branch -f/-M/-C/-D, fetch or push
to :main), and any git run against a main checkout (-C/--git-dir/--work-tree naming a repo whose git dir is its common
dir, the stack or a project repo) other than reading it: a merge into main is the owner's step (F31). A denylist, since builders need a working shell: git run inside
OpenCode or Claude Code is not a Hermes tool call, so bin/commit-guard.sh (pre-commit) is the enforcement there.
Exit 2 = block; any error blocks."""
import fnmatch, json, os, re, shlex, subprocess, sys
# RT-RTA-01: HOME is a folder the worker writes; a planted ~/.gitconfig or ~/.config/git/config (trace2 appends to any file) must not
# reach our git. Global only: /etc/gitconfig (root) carries safe.directory for the root-owned /workspace.
GIT_ENV = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "LC_ALL": "C"}   # C: git's "dubious ownership" text is matched below

SEP = {"&&", "||", ";", "|", "&"}
READ = {"status", "log", "show", "diff", "rev-parse", "ls-files", "blame", "grep", "describe", "cat-file", "show-ref",
        "for-each-ref", "shortlog", "rev-list", "ls-tree", "merge-base", "name-rev"}
MAIN = re.compile(r"(?:^|:)\+?(?:refs/heads/)?main$", re.I)   # RT19-01: the repos sit on a case-insensitive mount


def dest_is_main(a):
    """RT18d-01: a push or fetch refspec whose destination git resolves to refs/heads/main: the destination written in any
    qualified form (main, heads/main, refs/heads/main, with or without +), or a pattern that can match it. A pattern that
    cannot (refs/remotes/origin/*) is the default fetch form and stays allowed."""
    d = a.rsplit(":", 1)[-1].lstrip("+").lower()   # RT19-01: MAIN, Main and refs/HEADS/main name the same ref file here
    if re.search(r"[*?\[]", d):
        return any(fnmatch.fnmatchcase("refs/heads/main", x) for x in (d, "refs/" + d, "refs/heads/" + d))
    for pre in ("refs/heads/", "heads/"):
        if d.startswith(pre):
            d = d[len(pre):]; break
    return d == "main"


def positional(rest):
    """RT19-02, RT20-01: the arguments git reads as refspecs: those not starting with a dash, and everything after a bare --
    or --end-of-options (where -x:heads/main is a refspec)."""
    out, past = [], False
    for a in rest:
        if past or not a.startswith("-"):
            out.append(a)
        elif a in ("--", "--end-of-options"):
            past = True
    return out


def refmaps(rest):
    """RT20-02: the values of fetch/pull --refmap (glued with = or as the next argument, any unambiguous abbreviation): each is a
    refspec whose destination git writes."""
    out = []
    for i, a in enumerate(rest):
        m = re.fullmatch(r"--ref(?:m(?:a(?:p)?)?)?(=(.*))?", a, re.S)
        if m and m[1] is not None:
            out.append(m[2])
        elif m and i + 1 < len(rest):
            out.append(rest[i + 1])
    return out


def main_checkout(path):
    """K1b: path is (inside) a repo's main checkout, not a linked worktree: its git dir is its common dir."""
    try:
        r = [subprocess.run(["git", "-C", path, "rev-parse", "--path-format=absolute", o], capture_output=True, text=True,
                            timeout=10, env=GIT_ENV) for o in ("--git-dir", "--git-common-dir")]
    except Exception:
        return True
    if any(x.returncode or not x.stdout.strip() for x in r):
        return True   # cannot tell (not a repo, dubious ownership, a bare git dir): treat as a main checkout, fail closed
    return r[0].stdout.strip() == r[1].stdout.strip()


def tokens(cmd, depth=0, commenters=""):
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.commenters = commenters   # RT22-01: "" = a # inside a word is text; "#" = the parse used before RT22-01 (see all_tokens)
    lex.whitespace_split = True
    out = list(lex)
    for t in list(out):
        if depth < 3 and re.search(r"\s", t):   # a quoted command line: bash -c '…', opencode run '…'
            yield from tokens(t, depth + 1, commenters)
    yield out


def all_tokens(cmd):
    """RT22-01 round 3: two views of the command. The first reads a `#` inside a word as text (bash starts a comment only at the
    start of a word); the second is the parse the hooks used before RT22-01, where the shlex default hid everything after any `#`
    but ended a comment at its newline. A command is refused when either view refuses it, so no hook is weaker than before
    RT22-01 on a leading comment line or a comment ending in a backslash. A command the old view cannot parse is refused, as the hooks did before RT22-01 (RT25-01)."""
    yield from tokens(cmd)
    yield from tokens(cmd, 0, "#")   # RT25-01: a command only this view cannot parse is refused (the ValueError), as before RT22-01


def output_into_main(path):
    """K1c: a git output file (--output, -o) whose folder is inside a main checkout. A folder that is no repo is fine."""
    d = os.path.dirname(os.path.abspath(os.path.expanduser(path))) or "/"
    try:
        r = [subprocess.run(["git", "-C", d, "rev-parse", "--path-format=absolute", o], capture_output=True, text=True,
                            timeout=10, env=GIT_ENV) for o in ("--git-dir", "--git-common-dir")]
    except Exception:
        return True
    if any("dubious ownership" in x.stderr for x in r):
        return True   # as _is_main: the stack's safe.directory list sat in the ~/.gitconfig this call no longer reads; refuse rather than guess
    return all(x.returncode == 0 for x in r) and r[0].stdout.strip() == r[1].stdout.strip()


def why(args, env_targets=()):
    j, targets = 0, list(env_targets)
    while j < len(args) and args[j].startswith("-"):
        if args[j] == "-c" or args[j].startswith("--config-env"):
            return "git -c sets config"
        if args[j] in ("-C", "--git-dir", "--work-tree") and j + 1 < len(args):
            targets.append(args[j + 1])
        elif re.match(r"--(git-dir|work-tree)=", args[j]):
            targets.append(args[j].split("=", 1)[1])
        j += 2 if args[j] in ("-C", "--git-dir", "--work-tree", "--namespace") else 1
    sub, rest = (args[j], args[j + 1:]) if j < len(args) else ("", [])
    plain_branch = sub == "branch" and all(a in ("--list", "-l", "-a", "-r", "-v", "-vv", "--show-current") for a in rest)
    outs = [a.split("=", 1)[1] for a in rest if re.match(r"--output(-directory)?=", a)] + \
           [rest[i + 1] for i, a in enumerate(rest[:-1]) if a in ("--output", "--output-directory", "-o")]
    if any(output_into_main(o) for o in outs):
        return f"git {sub} writing its output into a main checkout"
    if sub not in READ and not plain_branch and any(not os.path.isabs(os.path.expanduser(t)) for t in targets):
        return f"git {sub} with a relative -C/--git-dir/--work-tree or GIT_DIR: use an absolute path"
    if sub not in READ and not plain_branch and any(main_checkout(os.path.expanduser(t.rstrip("/") or "/")) for t in targets):
        return f"git {sub} against a main checkout: builders work in their own card worktree; merging into main is the owner's step"
    if sub == "update-ref" and any(MAIN.search(a) for a in rest):
        return "git update-ref of main"
    if sub == "branch" and any(MAIN.search(a) for a in rest) and any(re.fullmatch(r"-[a-zA-Z]*[fMCD][a-zA-Z]*|--force|--move|--copy|--delete", a) for a in rest):
        return "git branch rewriting main"
    if sub in ("fetch", "pull") and (any(":" in a and MAIN.search(a) for a in rest) or any(":" in a and dest_is_main(a) for a in positional(rest)) or
                                     any(dest_is_main(v) for v in refmaps(rest))):
        return f"git {sub} into main"
    if sub == "config":
        return "git config"
    if "--no-verify" in args or (sub == "commit" and any(re.fullmatch(r"-[a-zA-Z]*n[a-zA-Z]*", a) for a in rest)):
        return "--no-verify skips the commit guard"
    if sub == "add" and any(a in ("-A", "--all", ".", "./", ":/") or re.fullmatch(r"-[a-zA-Z]*A[a-zA-Z]*", a) for a in rest):
        return "git add -A/--all/. sweeps unrelated files; add files by name"
    if sub == "push" and (any(a in ("--all", "--mirror") or (len(a) > 2 and a.startswith("--") and ("--all".startswith(a) or "--mirror".startswith(a))) or a.lower() in ("main", "+main", "refs/heads/main") or
                              re.search(r":(refs/heads/)?main$", a, re.I) for a in rest) or any(dest_is_main(a) for a in positional(rest))):
        return "git push to main"
    return None


def check(cmd):
    for toks in all_tokens(cmd):
        for i, t in enumerate(toks):
            if t.rsplit("/", 1)[-1] != "git":
                continue
            cfg_env = False   # RT20-04: GIT_CONFIG_COUNT/KEY_n/VALUE_n/PARAMETERS/GLOBAL/SYSTEM change remote.<n>.push, push.default, hooksPath
            env_targets = []   # K1c: GIT_DIR=, GIT_WORK_TREE=, GIT_COMMON_DIR= before git (also after env) are -C targets
            for u in reversed(toks[:i]):
                if u in SEP:
                    break
                cfg_env = cfg_env or re.match(r"(GIT_CONFIG[A-Z0-9_]*|HOME|XDG_CONFIG_HOME)=", u) is not None   # HH-06: git reads a planted config from another HOME / XDG folder
                m = re.fullmatch(r"(GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_INDEX_FILE)=(.*)", u)
                if m:
                    env_targets.append(m[2] or ".")
            args = []
            for u in toks[i + 1:]:
                if u in SEP or u.rsplit("/", 1)[-1] == "git":
                    break
                args.append(u)
            r = "git config through the environment (GIT_CONFIG_*, HOME=, XDG_CONFIG_HOME=)" if cfg_env else why(args, env_targets)
            if r:
                return r
    return None


try:
    p = json.load(sys.stdin)
    a = p.get("tool_input") or {}
    cmd = a.get("data") if p.get("tool_name") == "process_manage" else a.get("command")
    reason = check(str(cmd or ""))
except Exception as e:  # fail closed: a payload we cannot read is refused
    reason = f"unreadable payload: {type(e).__name__}"
if reason is None:
    sys.exit(0)
print(json.dumps({"action": "block", "message": f"git guard: {reason} (D36). Before any git command, "
                  "`git rev-parse --show-toplevel` must equal your card workspace and `git branch --show-current` your "
                  "card branch; otherwise kanban_block with kind capability. Never git config, --no-verify, git add -A "
                  "or ., or push to main."}))
sys.exit(2)
