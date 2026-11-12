#!/usr/bin/env python3
"""The dispatcher role's terminal is read-only (D35, D46): pre_tool_call on terminal and process_manage in every profile
whose role installs it (docs/hermes-local/roles.json).
An allowlist, not a denylist: every command in the line must be allowed below. No redirection except 2>/dev/null and
2>&1, no command substitution, subshells, heredocs, backgrounding or newlines. Reading a secret path is refused
whatever the command (F11). Exit 2 = block; any error blocks."""
import json, re, shlex, sys

# --- secret paths (F11, F12): this block is identical in hooks/default/read-only-terminal.py and
# hooks/builder/secret-guard.py (bin/secret-read-selftest.sh checks it). A path counts however it is written: ~, $HOME
# and other variables (also NAME=value earlier on the line), cd, git -C or workdir then a relative path, globs (expanded
# as the shell would), brace expansion ({a,b}), $'…' escapes, option values (--include=…) and command lines nested in
# quotes. Recursing into a folder that holds secrets counts too. Not caught: a path the shell builds at run time (an
# unknown variable, $(…), an encoder).
import codecs, fnmatch, glob, os, pwd, re, shlex
SECRETS = (".env*", "*.pem", "*.key", "~/.hermes/.env", "~/.hermes/auth.json", "~/.claude/.credentials*",
           "~/.local/share/opencode/auth.json", "~/.hermes/broker", "~/.ssh", "~/.aws", "~/.config/gh")
SECRET_OK = (".env.example", ".env.sample", ".env.template")
HOMES = sorted({pwd.getpwuid(os.getuid()).pw_dir, os.environ.get("HOME") or pwd.getpwuid(os.getuid()).pw_dir})
UNREADABLE = ""   # set when the role table or the data index cannot be read: every read is refused, with this message
try:   # K6: the owner settings files (roles.json owner_settings) are read by no agent role; an unreadable table refuses all
    sys.path.insert(0, "/workspace/bin")
    import roles as _roles
    _t = _roles.load()
    OWNER_FILES = {os.path.realpath(f).casefold() for f in _roles.owner_settings(_t)}   # B2V-01: /workspace is case-insensitive
    OWNER_TREES = [os.path.realpath(t).casefold() for t in _roles.state_trees(_t)]   # B1 (F1 W4): the apply tool's backups, applied state and event log hold owner values: no role reads them
    OWNER_TEXT = [p.casefold() for p in _roles.state_paths(_t)]   # ... however the path is spelled in a command (an interpreter's code included)
except Exception as _e:
    OWNER_FILES, OWNER_TREES, OWNER_TEXT = None, [], []
    UNREADABLE = f"the role table or the data index cannot be read ({type(_e).__name__}), so every read is refused until it is fixed [STL-CFG-303]"
SECRET_DIRS = [f"{h}/{d}" for h in HOMES for d in (".hermes", ".claude", ".local/share/opencode", ".ssh", ".aws", ".config/gh")]
SECRET_DIRS.append("/proc")   # a recursive search of /proc reads every process's environment
SECRET_TEXT = re.compile(r"(?<![\w.-])\.env(?!\.(?:example|sample|template)\b)|\.claude/\.credentials|\.hermes/auth\.json|"
                         r"opencode/auth\.json|\.hermes/broker\b|(?:(?<![\w.~-])|(?<=-[A-Za-z]))/proc/(?:self|thread-self|\d|[*?\[$])|(?<![\w.-])\.(?:ssh|aws)\b|\.config/gh\b")
RECURSIVE = {"rg", "ag", "ack", "rgrep", "find", "tar", "zip", "cp", "rsync", "scp", "diff"}   # diff: two folders compare every file (B2V-14)
GIT_READERS = {"diff", "grep", "difftool"}   # B2V-14: a path outside the repo turns them into plain file readers
WRAPPERS = {"sudo", "env", "nohup", "time", "command", "exec", "builtin", "timeout", "nice", "ionice", "stdbuf", "setsid",
            "chroot", "doas", "xargs", "{", "}", "!", "if", "elif", "then", "while", "until", "do", "else"}   # as write-guard PREFIXES
SPLIT = {"&&", "||", ";", "|", "&", "(", ")"}


def _within(p, root):
    return p == root or p.startswith(root.rstrip("/") + "/")

def _owner_dir(p):
    """True when p is a folder that holds an owner settings file, or inside one (RT7-01: never the terminal's folder)."""
    return any(_within(os.path.realpath(p).casefold(), os.path.dirname(f)) for f in OWNER_FILES or ()) or any(_within(os.path.realpath(p).casefold(), t) for t in OWNER_TREES)

def secret_path(p):
    n = os.path.normpath(p)
    if re.match(r"/proc/(?:self|thread-self|\d+)(?:/|$)", n):   # another process's environment, memory, fds: a review token lives there while a review runs
        return True
    if OWNER_FILES is None or os.path.realpath(p).casefold() in OWNER_FILES or any(_within(os.path.realpath(p).casefold(), t) for t in OWNER_TREES):
        return True
    b = os.path.basename(p).casefold()   # B2V-01: .ENV is .env on a case-insensitive mount
    if b not in SECRET_OK and any(fnmatch.fnmatch(b, s) for s in SECRETS if "/" not in s):
        return True
    return any(fnmatch.fnmatch(p, h + s[1:]) or fnmatch.fnmatch(p, h + s[1:] + "/*")
               for h in HOMES for s in SECRETS if s.startswith("~/"))


def _where(word, cwd, names):
    w = re.sub(r"\$\{?([A-Za-z_]\w*)\}?", lambda m: names.get(m[1], os.environ.get(m[1], m[0])), word)
    return os.path.normpath(os.path.join(cwd, os.path.expanduser(w)))


def _braces(word):
    """bash brace expansion of {a,b} (innermost first; not {1..3}); over 64 words is refused by path_why. One copy, shared with the write guard."""
    return _roles.braces(word)


def _ansi(cmd):
    """bash $'…' strings decoded as bash does, and $"…" as plain "…", so escapes cannot hide a name. One copy, shared with the write guard."""
    return _roles.ansi(cmd)


def path_why(word, cwd, names=None, recursive=False):
    """Why reading `word` (a path as written, relative to `cwd`) reads a secret, or None."""
    if OWNER_FILES is None:
        return UNREADABLE
    words = _braces(word)
    if len(words) > 64:
        return f"{word[:60]}… expands to more than 64 words, too many to check"
    for w in words:
        if w in ("/dev/stdin", "/dev/stdout", "/dev/stderr", "/dev/fd/0", "/dev/fd/1", "/dev/fd/2"):
            continue   # the standard streams as written (they resolve to this process's own pipes); a link that resolves to one is not exempt
        p = _where(w, cwd, names or {})
        raw = os.path.realpath(os.path.join(cwd or "/", os.path.expanduser(w)))   # without normpath first: the kernel follows a link before it applies ..
        for x in [p, raw] + (glob.glob(p) if glob.has_magic(p) else []):
            for q in {x, os.path.realpath(x)}:
                if OWNER_FILES and os.path.realpath(q).casefold() in OWNER_FILES:
                    return f"{word} is an owner settings file ({q})"   # B2V-16
                if any(_within(os.path.realpath(q).casefold(), t) for t in OWNER_TREES):
                    return f"{word} is an owner state path of the apply tool ({q}) [STL-CFG-312]"
                if secret_path(q):
                    return f"{word} is a secret path ({q})"
                if recursive and os.path.isdir(q) and any(_within(q, d) or _within(d, q) for d in SECRET_DIRS):
                    return f"recursing into {q} reads secret files"
                if recursive and any(_within(f, os.path.realpath(q).casefold()) for f in list(OWNER_FILES or ()) + OWNER_TREES):   # also a folder that does not exist (yet)
                    return f"recursing into {q} reads an owner settings file or an owner state path [STL-CFG-312]"   # K6: the folder that holds one
        b = os.path.basename(w)
        if b.startswith(".") and glob.has_magic(b) and any(fnmatch.fnmatch(n, b) for n in (".env", ".env.local", ".credentials.json")):
            return f"the glob {word} matches secret files"
    return None


def _lines(cmd, depth=0, commenters=""):
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.commenters = commenters   # RT22-01: "" = a # inside a word is text; "#" = the parse used before RT22-01 (see all_lines)
        lex.whitespace_split = True
        out = list(lex)
    except ValueError:   # shlex is not bash (heredocs, an apostrophe in prose): scan the plain words instead
        if commenters:
            return   # the pre-RT22-01 view is only an extra view: skipped when it cannot parse
        out = [re.sub(r"[\"'\\]", "", w) for w in re.findall(r"[();<>|&]+|[^\s();<>|&]+", cmd)]   # RT23-02: same words and operators shlex would give, quote marks dropped, not a bare whitespace split
    for t in list(out):
        if depth < 3 and re.search(r"\s", t):   # a quoted command line: bash -c '…', opencode run '…'
            yield from _lines(t, depth + 1, commenters)
    yield out


def all_lines(cmd):
    """RT22-01 round 3: two views of the command. The first reads a `#` inside a word as text (bash starts a comment only at the
    start of a word); the second is the parse the hooks used before RT22-01, where the shlex default hid everything after any `#`
    but ended a comment at its newline. A command is refused when either view refuses it, so no hook is weaker than before
    RT22-01 on a leading comment line or a comment ending in a backslash. A command the old view cannot parse is skipped there."""
    yield from _lines(cmd)
    try:
        yield from _lines(cmd, 0, "#")
    except ValueError:
        pass


SEARCH = {"grep", "egrep", "fgrep", "rgrep", "rg", "ag", "ack", "find"}
VALUE_OPTS = {"-e", "-f", "-m", "-A", "-B", "-C", "-d", "-D", "-g", "-t", "-T", "-j", "-M", "--regexp", "--file", "--max-count",
              "--context", "--after-context", "--before-context", "--glob", "--type", "--type-not", "--max-depth"}

def _search_paths(name, words, base, names):
    """The paths a recursive search names; none means it reads the current folder (RT7-01: grep -r, rg, find with no path)."""
    if name == "find":   # find's paths come before its first expression word
        ws = [w for w in words if w not in ("-H", "-L", "-P")]
        return [w for w in ws[:next((i for i, w in enumerate(ws) if w.startswith(("-", "(", "!"))), len(ws))]]
    ops, skip = [], False
    for w in words:
        if skip or w in VALUE_OPTS:
            skip = not skip
            continue
        if not w.startswith("-"):
            ops.append(w)
    if not any(w in ("-e", "-f", "--regexp", "--file") or w.startswith(("--regexp=", "--file=")) for w in words):
        ops = ops[1:]   # the first operand is the pattern
    # shortcut: a value-taking option missing from VALUE_OPTS shifts the words; only an existing path counts, so a shifted
    # pattern word never hides the current folder unless it also names an existing path. Session 2 option A replaces this.
    return [w for w in ops if os.path.exists(p := _where(w, base, names)) or (glob.has_magic(p) and glob.glob(p))]   # RT8-01: a glob that matches names paths

def secret_why(cmd, cwd):
    """Why the shell command line `cmd`, run in `cwd`, reads a secret path, or None."""
    cmd = _ansi(cmd)
    if OWNER_FILES is None:
        return UNREADABLE
    if any(os.path.basename(f) in cmd.casefold() for f in OWNER_FILES):
        return "the command names an owner settings file"   # B2V-16: the owner-settings tail, not "block for a secret"
    if any(t in cmd.casefold() for t in OWNER_TEXT):
        return "the command names an owner state path of the apply tool (its backups, applied state or event log) [STL-CFG-312]"
    if SECRET_TEXT.search(cmd):
        return "the command names a secret path"
    if _owner_dir(cwd):
        return f"{cwd} is the folder that holds an owner settings file"
    for toks in all_lines(cmd):
        here, names, seg = cwd, {}, []
        for t in toks + [";"]:
            if t not in SPLIT:
                seg.append(t)
                continue
            wrapped = False
            while seg:   # B2V-15: VAR=value words, then wrappers and keywords (if, { }, builtin, ...) before the real command
                w = seg[0].rsplit("/", 1)[-1]
                if w in WRAPPERS:
                    wrapped = True
                elif re.fullmatch(r"[A-Za-z_]\w*=.*", seg[0]):
                    k, v = seg[0].split("=", 1)
                    names[k] = v
                elif not (wrapped and re.fullmatch(r"-.*|[0-9.]+[smhd]?", seg[0])):
                    break
                seg.pop(0)
            if seg:
                if "/" in seg[0]:   # a path as the command word (inside an interpreter's code it is the first word of its own line)
                    why = path_why(seg[0], here, names)
                    if why:
                        return why
                name = seg[0].rsplit("/", 1)[-1]
                sub = next((w for i, w in enumerate(seg[1:], 1) if not w.startswith("-") and seg[i - 1] not in ("-C", "-c")),
                           "") if name == "git" else ""
                if sub in GIT_READERS and "--no-index" in seg:
                    return f"git {sub} --no-index reads files outside any repository"   # B2V-14
                rec = name in RECURSIVE or sub in GIT_READERS or (name in ("grep", "egrep", "fgrep") and any(
                    re.fullmatch(r"-[a-zA-Z]*[rR][a-zA-Z]*|--(?:dereference-)?recursive|--directories=recurse|recurse", w)
                    for w in seg[1:]))
                base = _where(seg[seg.index("-C") + 1], here, names) if name == "git" and "-C" in seg[:-1] else here
                for i, w in enumerate(seg[1:], 1):
                    r = rec and not (name == "git" and seg[i - 1] in ("-C", "-c"))   # git -C <dir> names where, not what it reads
                    for v in [w] + ([w.split("=", 1)[1]] if w.startswith("-") and "=" in w else []):
                        why = None if v.startswith("-") or not v else path_why(v, base, names, r)
                        if why:
                            return why
                if rec and name in SEARCH and not _search_paths(name, seg[1:], base, names):
                    why = path_why(".", base, names, True)
                    if why:
                        return why
                to = next((w for w in seg[1:] if not w.startswith("-")), None)
                if name in ("cd", "pushd") and to:
                    here = _where(to, here, names)
                    if _owner_dir(here):
                        return f"cd into {here}, the folder that holds an owner settings file"
            seg = []
    return None
# --- end secret paths

READ = {"ls", "cat", "head", "tail", "grep", "wc", "jq", "echo", "pwd", "/workspace/bin/escalations-status.sh",
        "/workspace/bin/alert-explain.sh"}   # D44: prints one alert catalog entry, nothing else
GIT_READ = {"status", "log", "show", "diff", "rev-parse"}
SEP = {"&&", "||", ";", "|"}
ALLOWED = ("hermes kanban list|show, /workspace/bin/escalations-status.sh, /workspace/bin/alert-explain.sh <code>, "
           "git status|log|show|diff|rev-parse, "
           "ls, cat, head, tail, grep, wc, jq, echo, pwd (no cd: use absolute paths or git -C)")


def _vouched():
    """K4: the repositories this terminal may run git in: the stack's own folder and the main checkout of each project bound to the board (the binding the
    hooks already read). None when the binding cannot be read: then only the stack is vouched for."""
    out = {os.path.realpath(_roles.ROOT).casefold()}
    try:
        out |= {os.path.realpath(p["repo"]).casefold() for p in _roles.board_projects(_roles.board()) if p["repo"]}
    except Exception:
        pass
    return out


def _git_dir_why(here):
    """Why git must not run in `here`. A repository's own config can name a program git runs (core.fsmonitor, diff.external, textconv and clean
    filters, core.pager, core.hooksPath, aliases, gpg.program), and a boxed worker can leave a repository of its own anywhere it can write (its profile
    home, the box tmp folder, /tmp, a card worktree), so git runs only where the repository can be vouched for (K4): the toplevel found by looking for
    .git (a short 8.3 or odd spelling of the path does not matter) is the stack's folder or the main checkout of a bound project, and its .git is a folder
    (a linked worktree has a file). Anything else, or a table that cannot be read, refuses."""
    try:
        siblings = {x.casefold() for x in _roles.sandbox(_roles.load())["sibling_dirs"]}
    except Exception:
        return "the sandbox table cannot be read, so git is not run in a card folder"
    rp = os.path.realpath(here)
    a = rp
    while a and a != "/":
        if os.path.lexists(os.path.join(a, ".git")):
            break
        a = os.path.dirname(a)
    else:
        return f"git is not run in {here}: it is not inside the stack or a bound project's main checkout"
    if not os.path.isdir(os.path.join(a, ".git")) or os.path.islink(os.path.join(a, ".git")):
        return f"git is not run inside a linked worktree or a repository whose .git is not a plain folder ({here}): its config could run code there"
    if a.casefold() not in _vouched():
        return f"git is not run in {here}: only the stack and the main checkout of a bound project are vouched for, any other repository's config could run code"
    parts = [x.casefold() for x in rp.split("/") if x]
    parts += [x.casefold() for x in os.path.normpath(here).split("/") if x]
    if any(x in siblings for x in parts):
        return f"git is not run inside a card worktree ({here}): a builder's repo config could run code there"
    if ".git" in parts:
        return f"git is not run inside a .git folder ({here})"
    return None


def why_not(cmd, cwd):
    if not cmd.strip():
        return "empty command"
    secret = secret_why(cmd, cwd)
    if secret:
        return f"secret paths are never read: {secret}"
    if re.search(r"[\n\r`]|\$\(|\$\{|<\(|>\(", cmd):
        return "newline, backtick, ${…} or command substitution"
    lex = shlex.shlex(_ansi(cmd), posix=True, punctuation_chars=True)   # RT23-01: $'\'' is one quote character to bash, two to shlex
    lex.commenters = ""   # RT22-01: bash starts a comment only at the start of a word; shlex hid everything after a # inside one
    lex.whitespace_split = True
    toks = list(lex)
    segs, cur, i = [], [], 0
    while i < len(toks):
        t = toks[i]
        if t in SEP:
            segs.append(cur); cur = []
        elif t in (">", ">&") and cur and cur[-1] == "2" and i + 1 < len(toks) \
                and (t, toks[i + 1]) in ((">", "/dev/null"), (">&", "1")):
            cur.pop(); i += 1                      # 2>/dev/null or 2>&1: stderr only, nothing written
        elif not re.search(r"[^();<>|&]", t):
            return f"operator {t!r}"               # redirection, background, subshell
        else:
            cur.append(t)
        i += 1
    segs.append(cur)
    here = cwd
    for s in segs:
        if not s:
            return "empty command in a chain"
        if s[0] == "cd":   # the session keeps the folder of a cd for the NEXT call while the hook judges relative paths against its own process folder (red-team F5RT-01)
            return "cd is not allowed: the next call would inherit the folder; use absolute paths or git -C"
        if s[0] == "hermes":
            if s[1:2] != ["kanban"] or s[2:3] not in (["list"], ["ls"], ["show"]):
                return "hermes: only kanban list|show"
        elif s[0] == "git":
            j = 1
            while j < len(s) and s[j].startswith("-"):
                if s[j] not in ("-C", "--no-pager"):
                    return f"git option {s[j]}"
                j += 2 if s[j] == "-C" else 1
            if j >= len(s) or s[j] not in GIT_READ:
                return f"git {s[j] if j < len(s) else ''}".strip()
            if any(a.startswith(("--output", "--ext-diff")) for a in s[j + 1:]):
                return "git --output/--ext-diff"
            gdir, k = here, 1
            while k < j:   # every -C, in order: each one is relative to the one before
                if s[k] == "-C":
                    if re.search(r"[*?\[{$]|~[^/]", s[k + 1]):
                        return "git -C a folder written as a pattern, a variable or a ~ form"
                    gdir = os.path.normpath(os.path.join(gdir, os.path.expanduser(s[k + 1])))
                    k += 2
                else:
                    k += 1
            bad = _git_dir_why(gdir)
            if bad:
                return bad
        elif s[0] not in READ:
            return f"{s[0]} is not allowed"
    return None


try:
    p = json.load(sys.stdin)
    args = p.get("tool_input") or {}
    if p.get("tool_name") == "process_manage":
        reason = None if args.get("action") in ("list", "poll", "log", "wait") else f"process_manage {args.get('action')}"
    else:
        reason = why_not(str(args.get("command") or ""), args.get("workdir") or p.get("cwd") or os.getcwd())
except Exception as e:  # fail closed: a payload we cannot read is refused
    reason = f"unreadable payload: {type(e).__name__}"
if reason is None:
    sys.exit(0)
if "[STL-CFG-312]" in reason:   # G4: the code, the catalog's plain message, one alert line; no value from any owner file
    reason = _roles.plain("STL-CFG-312", problem="a role tried to read an owner state path of the apply tool") + " " + reason.replace(" [STL-CFG-312]", "")
print(json.dumps({"action": "block", "message": f"The dispatcher's terminal is read-only ({reason}). Allowed: {ALLOWED}. "
                  "Dispatchers do not change files: create a card for a worker instead."}))
sys.exit(2)
