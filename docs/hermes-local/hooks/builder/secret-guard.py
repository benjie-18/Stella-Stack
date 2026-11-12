#!/usr/bin/env python3
"""Secret-read guard (F12): pre_tool_call on terminal, process_manage, read_file, search_files, vision_analyze
and skill_view for the builder role, and on read_file and search_files only for the dispatcher and reviewer roles
(D42, D46: the matchers are in docs/hermes-local/roles.json; those roles' terminals have their own guards). Refuses reading
the secret paths below (the same list as the dispatcher's read-only terminal, F11). A mistake guard, not a boundary: the builder's own shell can still build a path at run time.
Exit 2 = block; any error blocks."""
import json, sys

# --- secret paths (F11, F12): this block is identical in hooks/default/read-only-terminal.py and
# hooks/builder/secret-guard.py (bin/secret-read-selftest.sh checks it). A path counts however it is written: ~, $HOME
# and other variables (also NAME=value earlier on the line), cd, git -C or workdir then a relative path, globs (expanded
# as the shell would), brace expansion ({a,b}), $'…' escapes, option values (--include=…) and command lines nested in
# quotes. Recursing into a folder that holds secrets counts too. Not caught: a path the shell builds at run time (an
# unknown variable, $(…), an encoder).
import codecs, fnmatch, glob, os, pwd, re, shlex, time
SECRETS = (".env*", "*.pem", "*.key", "~/.hermes/.env", "~/.hermes/auth.json", "~/.claude/.credentials*",
           "~/.local/share/opencode/auth.json", "~/.hermes/broker", "~/.ssh", "~/.aws", "~/.config/gh")
SECRET_OK = (".env.example", ".env.sample", ".env.template")
HOMES = sorted({pwd.getpwuid(os.getuid()).pw_dir, os.environ.get("HOME") or pwd.getpwuid(os.getuid()).pw_dir})
UNREADABLE = ""   # set when the role table or the data index cannot be read: every read is refused, with this message
try:   # K6: the owner settings files (roles.json owner_settings) are read by no agent role; an unreadable table refuses all
    sys.path.insert(0, "/workspace/bin")
    import roles as _roles
    _t = _roles.load(files=False)
    OWNER_FILES = {os.path.realpath(f).casefold() for f in _roles.owner_settings(_t)}   # B2V-01: /workspace is case-insensitive
    OWNER_TREES = [os.path.realpath(t).casefold() for t in _roles.state_trees(_t)]   # B1 (F1 W4): the apply tool's backups, applied state and event log hold owner values: no role reads them
    OWNER_TEXT = [p.casefold() for p in _roles.state_paths(_t)]   # ... however the path is spelled in a command (an interpreter's code included)
    FILE_CH = _roles.chains(_roles.owner_settings(_t))   # K1b: a path is one of these by what it IS (identity: a short name, a case variant, a link), never by its spelling
    TREE_CH = _roles.chains(_roles.state_trees(_t))
    DIR_CH = _roles.chains({os.path.dirname(f) for f in _roles.owner_settings(_t)} | set(_roles.state_trees(_t)))
except Exception as _e:
    OWNER_FILES, OWNER_TREES, OWNER_TEXT, FILE_CH, TREE_CH, DIR_CH = None, [], [], [], [], []
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

def _hit(p, ch, rels):
    x = _roles.overlap(p, ch)
    return bool(x) and x[0] in rels


def _owner_dir(p):
    """True when p is a folder that holds an owner settings file, or inside one (RT7-01: never the terminal's folder)."""
    return _hit(p, DIR_CH, ("equal", "inside"))

def secret_path(p):
    n = os.path.normpath(p)
    if re.match(r"/proc/(?:self|thread-self|\d+)(?:/|$)", n):   # another process's environment, memory, fds: a review token lives there while a review runs
        return True
    if OWNER_FILES is None or _hit(p, FILE_CH, ("equal",)) or _hit(p, TREE_CH, ("equal", "inside")):
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


DEADLINE = [0.0]   # K5: when the look-ups of one command must be done (monotonic); 0 = no limit (a single path from a tool call)


SEEN = {}   # T1: the verdict of each (word, folder, names it uses, recursive) of this call; a command that repeats a path looks it up once


def path_why(word, cwd, names=None, recursive=False):
    """Why reading `word` (a path as written, relative to `cwd`) reads a secret, or None."""
    if OWNER_FILES is None:
        return UNREADABLE
    if DEADLINE[0] and time.monotonic() > DEADLINE[0]:
        return "the command names too many paths to check in time"
    key = (word, cwd, recursive, tuple(sorted((names or {}).items())) if "$" in word else ())
    if key not in SEEN:
        SEEN[key] = _path_why(word, cwd, names, recursive)
    return SEEN[key]


def _path_why(word, cwd, names, recursive):
    words = _braces(word)
    if len(words) > 64:
        return f"{word[:60]}… expands to more than 64 words, too many to check"
    for w in words:
        if w in ("/dev/stdin", "/dev/stdout", "/dev/stderr", "/dev/fd/0", "/dev/fd/1", "/dev/fd/2"):
            continue   # the standard streams as written (they resolve to this process's own pipes); a link that resolves to one is not exempt
        p = _where(w, cwd, names or {})
        raw = os.path.realpath(os.path.join(cwd or "/", os.path.expanduser(w)))   # without normpath first: the kernel follows a link before it applies ..
        g = _roles.globs(p) if glob.has_magic(p) else []   # K5: bounded
        if g is None:
            return f"{word} is a glob with too many wildcard parts to check"
        for x in [p, raw] + g:
            for q in {x, os.path.realpath(x)}:
                if _hit(q, FILE_CH, ("equal",)):
                    return f"{word} is an owner settings file ({q})"   # B2V-16
                if _hit(q, TREE_CH, ("equal", "inside")):
                    return f"{word} is an owner state path of the apply tool ({q}) [STL-CFG-312]"
                if secret_path(q):
                    return f"{word} is a secret path ({q})"
                if recursive and os.path.isdir(q) and any(_within(q, d) or _within(d, q) for d in SECRET_DIRS):
                    return f"recursing into {q} reads secret files"
                if recursive and (_hit(q, FILE_CH, ("contains",)) or _hit(q, TREE_CH, ("contains",))):   # also a folder that does not exist (yet)
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
    return [w for w in ops if os.path.exists(p := _where(w, base, names)) or (glob.has_magic(p) and _roles.globs(p))]   # RT8-01: a glob that matches names paths

def secret_why(cmd, cwd):
    """Why the shell command line `cmd`, run in `cwd`, reads a secret path, or None."""
    cmd = _ansi(cmd)
    DEADLINE[0] = time.monotonic() + 4.0
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
    for piece in sorted({x for x in re.findall(r"[\w.~$@+%/*?\[\]-]+", cmd) if "/" in x})[:2000]:   # K1b: any path-like piece of the command text, in code or in quotes, by identity (bounded: K5, linear)
        if len(piece) > 1:
            why = path_why(piece, cwd, {})
            if why and ("owner settings" in why or "[STL-CFG-312]" in why):
                return why
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


def reason(p):
    name, a = p.get("tool_name"), p.get("tool_input") or {}
    base = p.get("cwd") or os.getcwd()
    if name == "terminal":
        return secret_why(str(a.get("command") or ""), a.get("workdir") or base)
    if name == "process_manage":
        return secret_why(str(a.get("data") or ""), base)
    if name == "read_file" and a.get("path"):
        return path_why(str(a["path"]), base)
    if name == "search_files":
        where = _where(str(a.get("path") or "."), base, {})
        if a.get("target") == "files":   # a find-by-name search lists names, it reads no file content
            return path_why(where, base)
        return path_why(where, base, recursive=True) or (path_why(str(a["file_glob"]), where) if a.get("file_glob") else None)
    if name == "vision_analyze" and a.get("image_url") and not re.match(r"(?i)(https?|data):", str(a["image_url"])):
        return path_why(str(a["image_url"]).removeprefix("file://"), base)
    if name == "skill_view" and a.get("file_path"):
        return path_why(str(a["file_path"]), base)
    return None


PAY = sys.stdin.read()
try:
    P = json.loads(PAY)
    why = reason(P)
except Exception as e:  # fail closed: a payload we cannot read is refused
    P, why = {}, f"unreadable payload: {type(e).__name__}"
if why is None:
    sys.exit(0)


def coded(code, problem):   # K8: the catalog code, its plain message, one alert line for the call (the role's other hook that refuses it writes none); the role named, no owner value
    try:
        role = _roles.role_of(_t, P.get("profile"))[0]
    except Exception:
        role = "unknown"
    try:
        return _roles.plain(code, once=PAY, problem=f"{problem} (role {role})")
    except Exception:   # the role module itself is missing: the code and the problem still print
        return f"[{code}] {problem}"


if why.startswith("the role table or the data index cannot be read"):
    print(json.dumps({"action": "block", "message": "secret guard: " + coded("STL-CFG-303", "the role table or the data index cannot be read by a read guard") + " Every read is refused until it is fixed."}))
    sys.exit(2)
if "[STL-CFG-312]" in why:   # G4: the code, the catalog's plain message, one alert line; no value from any owner file
    why = coded("STL-CFG-312", "a role tried to read an owner state path of the apply tool") + " " + why.replace(" [STL-CFG-312]", "")
elif "owner settings" in why:   # an older rule caught it first: it still says so with the code
    why = coded("STL-CFG-312", "a role tried to read an owner settings file") + " " + why
tail = ("No agent reads the owner settings file (the owner's rule): leave it out of the task. To search, name a narrower "
        "folder that does not hold it (for example bin or docs)." if "owner settings" in why else   # RT7-03, B2V-16
        "Agents here never read secrets (.env files, keys, Hermes, Claude, OpenCode, GitHub, SSH or AWS credentials). If the "
        "task needs one, kanban_block with kind needs_input and say which secret and why.")
print(json.dumps({"action": "block", "message": f"secret guard: {why}. {tail}"}))
sys.exit(2)
