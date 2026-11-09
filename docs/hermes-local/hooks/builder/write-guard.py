#!/usr/bin/env python3
"""Write guard (D40, D46): pre_tool_call on write_file, patch, terminal and process_manage for every profile whose role
installs it (docs/hermes-local/roles.json: the builder role, and the fallback role of a profile with no row). It stops
mistaken writes to the main checkout; it is not a security boundary (see D40's limits). The protected paths are the one
list in roles.json (shared with the card guard, bin/role-guard.py). Only a role whose workspace is git-worktree has a card
worktree; any other role writes only to its profile's own cache/scratch.
 1. write_file / patch (also V4A patch text, its headers parsed with Hermes's own grammar, tools/patch_parser.py: both
    ends of a Move; a *** header that does not parse refuses the patch): every target must be an absolute path (K1b:
    Hermes resolves a relative one against the terminal's current folder, which a hook cannot see), and, resolved with
    realpath, inside the card's own worktree or outside /workspace. Anything else under /workspace (the main checkout,
    other cards' worktrees) is refused, and so is a file with more than one hard link (K1b).
 2. terminal / process_manage: the command text (and command lines nested in quotes, tokenized as git-guard.py does, with
    backticks as separators) must not mention owner.env or HERMES_DELEGATED_CHILD_CONTEXT, must not run merge-card.sh or
    `hermes ... kanban` (the board is changed through the kanban tools, never the CLI: K1b), and must not point a write
    command or a > / >> redirect at a protected path or at /workspace outside the card's worktree, resolved against
    `workdir` or the payload cwd and any earlier `cd` on the same line. A `cd`/`pushd` or `workdir` into /workspace outside
    the worktree or into the agent configuration, a relative write target with `..`, and a hard link (`ln`, `cp -l`,
    `link`) of a file outside the worktree are refused (K1b: the terminal's current folder then stays where a relative
    path means what this guard reads). Reads stay allowed. Merging a card into main is the owner's step (F31).
The worktree (K1): the recorded workspace of the card whose own worker run this call belongs to, proven from the board
and the kernel by roles.prove_card (the card is the profile's, its open run is bound to an ancestor of this hook), never
from HERMES_KANBAN_TASK or /proc/<pid>/environ, which do not show the ids to a hook (D48). HERMES_KANBAN_WORKSPACE,
when set, must equal it. The proof is read only when a target needs it (inside /workspace or the agent configuration).
A workspace inside a bound repo (the deepest one holding it: the stack root or a project repo inside it) counts only if it is that card's own <repo>/.worktrees/<card> (F8: workspace_path is
whatever kanban_create was given, /workspace itself or another card's worktree included); else no worktree is known.
 3. Both tools: a target under the agent configuration (~/.hermes, ~/.claude, ~/.config/opencode, ~/.local/share/opencode) is
    refused (F-batch6): builders do not edit agent configuration. Only the profile's own cache/scratch and the card's own
    Hermes kanban workspace are allowed. Not closed (D42): a script written to /tmp and run, interpreters, variable-built commands.
Exit 2 = block; any error blocks."""
import json, os, pwd, re, shlex, sys

sys.path.insert(0, "/workspace/bin")
import roles   # noqa: E402  (the role table: one protected list, the caller's role)

ROOT = roles.ROOT
try:
    RT = roles.load()
    PROTECTED, CONFIG = roles.protected(RT)
    OWNER_FILES = roles.owner_settings(RT)
except roles.RolesError as e:   # every call is refused below until the table is fixed
    RT, PROTECTED, CONFIG, OWNER_FILES, RT_ERROR = None, [], [], [], str(e)[:200]
HOMES = roles.homes()
CALL = {}   # this call's payload, and its card worktree once a target needs it (proven at most once per call)
CONFIG_MSG = "builders do not edit agent configuration (~/.hermes, ~/.claude, ~/.config/opencode, ~/.local/share/opencode)"
REDIRECTS = {">", ">>", "&>", "&>>", ">|"}
SEP = {"&&", "||", ";", "|", "&", "(", ")"}
PREFIXES = {"sudo", "env", "nohup", "time", "command", "exec", "builtin", "timeout", "nice", "ionice", "stdbuf", "setsid",
            "chroot", "doas", "xargs", "{", "}", "!", "then", "do", "else"}   # K1c: wrappers whose command is the real one
WRITE_VERBS = {"cp", "install", "ln", "mv", "rm", "truncate", "tee", "chmod", "chown", "chattr", "dd", "sed", "rsync",
               "find", "tar", "unzip", "patch"}   # the commands write_targets reads; xargs feeding one is refused
WRAP_ARG = re.compile(r"-.*|[0-9.]+[smhd]?")   # a wrapper's own options and numbers (timeout 5, nice -n 0)


def strip_prefixes(words):
    """(the simple command without its wrappers and VAR=value words, whether xargs fed it)."""
    xargs, wrapped = False, False
    while words:
        w = words[0].rsplit("/", 1)[-1]
        if w in PREFIXES or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[0]):
            xargs, wrapped = xargs or w == "xargs", w in PREFIXES
        elif not (wrapped and WRAP_ARG.fullmatch(words[0])):
            break
        words = words[1:]
    return words, xargs
V4A_MARK = re.compile(r"\*\*\*\s*(?:Begin|End)\s+Patch\s*")   # Hermes's V4A grammar (tools/patch_parser.py), K1b
V4A_OPS = (re.compile(r"\*\*\*\s*Move\s+File:\s*(.+?)\s*->\s*(.+)"), re.compile(r"\*\*\*\s*(?:Update|Add|Delete)\s+File:\s*(.+)"),
           re.compile(r"\*\*\*\s*Move\s+to:\s*(.+)"))
OWNER_ENV = ("commands may not mention owner.env: it holds the owner config. If it must change, call kanban_block with "
             "kind needs_input and say what should change")
MERGE = "builders never run bin/merge-card.sh: merging a card into main is the owner's step (F31)"
KANBAN_CLI = ("builders never run `hermes kanban` or touch HERMES_DELEGATED_CHILD_CONTEXT: change your card with the "
              "kanban tools (kanban_comment, kanban_block, kanban_complete, ...)")
CD_MSG = ("the terminal stays inside your worktree: Hermes keeps its folder between calls, so a later relative path would "
          "write wherever it moved. Use absolute paths to read or write elsewhere (for example /tmp)")


def inside(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def resolve(path, base):
    return os.path.realpath(os.path.join(base, os.path.expanduser(os.path.expandvars(path))))


def worktree(p):
    """(the card's own worktree or None, why None)."""
    rname, role, _ = roles.role_of(RT, p.get("profile"))
    if role["workspace"] != "git-worktree":
        return None, f"the {rname} role has no card worktree"
    j, why = roles.prove_card(str(p.get("profile") or ""))
    if why:
        if j or why.startswith("the board cannot be read"):   # K2: the profile has a running card, the stack failed to prove it
            CALL["fault"] = ((j or {}).get("task") or {}).get("id") or "?", roles.streak(j), why
        return None, f"no card worktree known: {why}"
    card, ws = j["task"]["id"], os.path.realpath(j["task"].get("workspace_path") or "/")
    env = os.environ.get("HERMES_KANBAN_WORKSPACE", "")
    if env and os.path.realpath(env) != ws:
        return None, f"no card worktree known: HERMES_KANBAN_WORKSPACE {env} is not card {card}'s workspace {ws}"
    for repo in sorted(repos() or [ROOT], key=len, reverse=True):   # RT6-01: the F8 rule in the deepest bound repo holding the workspace (S3A-01: a project repo inside the stack root)
        rr = os.path.realpath(repo)   # S3A-01b (RT15): never realpath `own`, a worktree swapped for a symlink to the repo root would resolve to itself
        if inside(ws, rr) or inside(rr, ws):   # / contains every repo too
            own = f"{rr}/.worktrees/{card}" if re.fullmatch(r"t_[0-9a-f]{8}", card) else ""
            if not (own and ws == own):
                return None, f"no card worktree known: the card workspace {ws} is not this card's worktree ({own or 'no card id'})"
            break
    return ws, ""


def stack_fault(p, raw):
    """K2: the refusal when the stack, not the worker, is at fault: one STL-GRD-603 line in alerts.log per refusal; the
    catalog's page policy sends it to #alerts once per card per streak (K11)."""
    card, streak, why = CALL["fault"]
    roles.log_alert("STL-GRD-603", streak=streak, card=card, missing=why, profile=str(p.get("profile") or ""))
    return (f"[STL-GRD-603] the stack could not identify this card's worker run ({why}), so it cannot tell which worktree "
            f"is yours. This is a fault in the stack, not a rule about {raw}: do not report it as a missing capability. "
            "The owner has been alerted. Stop and call kanban_block with kind needs_input and the reason \"STL-GRD-603: "
            "the stack could not identify this worker run\"")


def own_worktree():
    if "wt" not in CALL:
        CALL["wt"] = worktree(CALL["p"])
    return CALL["wt"]


def v4a_targets(text):
    """Every path a V4A patch touches (both ends of a Move), or None when a *** header does not parse."""
    out = []
    for line in str(text).splitlines():
        line = line.strip()
        if not line.startswith("***") or V4A_MARK.fullmatch(line):
            continue
        m = next((m for r in V4A_OPS if (m := r.fullmatch(line))), None)
        if not m:
            return None
        out += [g.strip() for g in m.groups()]
    return out


def tokens(cmd, depth=0, commenters=""):
    cmd = cmd.replace("`", " ; ")   # K1b: a backtick command is a command of its own
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.commenters = commenters   # RT22-01: "" = a # inside a word is text; "#" = the parse used before RT22-01 (see all_tokens)
        lex.whitespace_split = True
        out = list(lex)
    except ValueError:   # shlex is not bash (heredocs, $'…', an apostrophe in prose): scan the plain words instead
        if commenters:
            return   # the pre-RT22-01 view is only an extra view: skipped when it cannot parse
        out = [re.sub(r"[\"'\\]", "", w) for w in re.findall(r"[();<>|&]+|[^\s();<>|&]+", cmd)]   # RT23-02: same words and operators shlex would give, quote marks dropped, not a bare whitespace split
    for t in list(out):
        if depth < 3 and re.search(r"\s", t):   # a quoted command line: bash -c '…', opencode run '…'
            yield from tokens(t, depth + 1, commenters)
    yield out


def all_tokens(cmd):
    """RT22-01 round 3: two views of the command. The first reads a `#` inside a word as text (bash starts a comment only at the
    start of a word); the second is the parse the hooks used before RT22-01, where the shlex default hid everything after any `#`
    but ended a comment at its newline. A command is refused when either view refuses it, so no hook is weaker than before
    RT22-01 on a leading comment line or a comment ending in a backslash. A command the old view cannot parse is skipped there."""
    yield from tokens(cmd)
    try:
        yield from tokens(cmd, 0, "#")
    except ValueError:
        pass


def protected(arg, cwd):
    """The resolved path when writing arg is refused: a protected path, the agent configuration, /workspace outside the
    card's worktree (K1b, the same rule as write_file), or a relative path with .. (the terminal's folder is not known)."""
    if not arg:
        return None
    if not os.path.isabs(os.path.expanduser(os.path.expandvars(arg))) and ".." in arg.split("/"):
        return f"{arg} (a relative path with ..)"
    rp = resolve(arg, cwd)
    if any(inside(rp, p) for p in PROTECTED) or config_hit(rp):
        return rp
    if os.path.isfile(rp) and os.stat(rp).st_nlink > 1:   # K1c: a hard link reaches a file outside the worktree
        return f"{rp} (more than one hard link)"
    return rp if outside_worktree(rp) else None


def repos():
    """RT6-01: the repos whose checkouts a builder writes only inside its own card worktree: the stack and every repo bound
    to the board (projects.db, read at call time as the card guard does). None when the binding cannot be read."""
    if "repos" not in CALL:
        try:
            CALL["repos"] = [ROOT] + [r for r in (os.path.realpath(p["repo"]) for p in roles.board_projects(roles.board()) if p["repo"]) if r != ROOT]   # S3A-01b: a symlinked primary_path is judged by its real folder, like every target
        except Exception:
            CALL["repos"] = None
    return CALL["repos"]


def in_repo(rp):
    """rp is inside a repo of repos(); with the binding unreadable, anything outside /tmp counts (fail closed)."""
    r = repos()
    return not inside(rp, "/tmp") if r is None else any(inside(rp, x) for x in r)


def outside_worktree(rp):
    """K1b: rp is in a bound repo (RT6-01: not only /workspace) outside the card's worktree, or in the agent configuration."""
    return config_hit(rp) or (in_repo(rp) and not ((wt := own_worktree()[0]) and inside(rp, wt)))


def in_worktree(rp):
    """K1c: rp is inside the card's own (proven) worktree."""
    return bool((wt := own_worktree()[0]) and inside(rp, wt))


def link_sources(words):
    """The existing files a hard link would reach (ln without -s, cp -l/--link, link): K1b."""
    words = strip_prefixes(words)[0]
    if not words:
        return []
    name, opts = words[0].rsplit("/", 1)[-1], [w for w in words[1:] if w.startswith("-")]
    args = [w for w in words[1:] if not w.startswith("-")]
    if name == "link":
        return args[:1]
    hard = (name == "ln" and not any(o == "--symbolic" or re.fullmatch(r"-[a-zA-Z]*s[a-zA-Z]*", o) for o in opts)) or \
           (name == "cp" and any(o == "--link" or re.fullmatch(r"-[a-zA-Z]*l[a-zA-Z]*", o) for o in opts))
    if not hard:
        return []
    return args if "-t" in words or any(o.startswith("--target-directory") for o in opts) else args[:-1]


def config_hit(rp):
    return any(inside(rp, c) for c in CONFIG) and not any(inside(rp, a) for a in allowed_config(CALL["p"]))


def allowed_config(p):
    """The only config-prefix places a builder writes: its profile's cache/scratch and its card's kanban workspace."""
    prof = str(p.get("profile") or "")
    folder = (RT["profiles"].get(prof) or {}).get("dir", f"profiles/{prof}")
    roots = ([f"{h}/.hermes/{folder}/cache/scratch".replace("//", "/") for h in HOMES]
             if roles.NAME.fullmatch(prof) and ".." not in folder.split("/") else [])
    wt = own_worktree()[0]
    return roots + ([wt] if wt and any(re.fullmatch(re.escape(h) + r"/\.hermes/kanban/(?:boards/[^/]+/)?workspaces/[^/]+", wt) for h in HOMES) else [])


def write_targets(words):
    """The paths a simple command writes, for the write commands D40 names; [] for anything else."""
    words = strip_prefixes(words)[0]
    if not words:
        return []
    name, opts = words[0].rsplit("/", 1)[-1], [w for w in words[1:] if w.startswith("-")]
    args = [w for w in words[1:] if not w.startswith("-")]
    if name == "rsync":   # K1c: archive, sync and patch tools write too
        return args[-1:]
    if name == "find" and any(o in ("-delete", "-exec", "-execdir", "-ok", "-okdir") for o in opts):
        return [w for w in words[1:words.index(next(o for o in words[1:] if o.startswith("-")))]] or ["."]
    if name == "tar" and any(re.fullmatch(r"-?[a-zA-Z]*x[a-zA-Z]*|--extract|--get", w) for w in words[1:2] + opts):
        d = [words[i + 1] for i, w in enumerate(words[:-1]) if w in ("-C", "--directory")]
        return d + [w.split("=", 1)[1] for w in opts if w.startswith("--directory=")] or ["."]
    if name == "unzip":
        return [words[i + 1] for i, w in enumerate(words[:-1]) if w == "-d"] or ["."]
    if name == "patch":
        return args[:1] or ["."]
    if name in ("cp", "install", "ln"):   # only the destination changes
        return [words[words.index("-t") + 1]] if "-t" in words[:-1] else args[-1:]
    if name in ("mv", "rm", "truncate", "tee"):
        return args
    if name in ("chmod", "chown"):
        return args[1:]
    if name == "chattr":
        return [a for a in args if a[:1] not in "+="]
    if name == "dd":
        return [w[3:] for w in words if w.startswith("of=")]
    if name == "sed" and any(o.startswith("-i") or o.startswith("--in-place") for o in opts):
        return args[1:]
    return []


def command_reason(cmd, base):
    if any(os.path.basename(f) in cmd for f in OWNER_FILES):   # K6: the owner settings files, from roles.json
        return OWNER_ENV
    if "merge-card.sh" in cmd:
        return MERGE
    for toks in all_tokens(cmd):   # K1b/K1c: per simple command, on the command word (a quoted message or a read is not a run)
        simple, cur = [], []
        for t in toks + [";"]:
            if t in SEP:
                simple, cur = simple + [cur] if cur else simple, []
            else:
                cur.append(t)
        for raw in simple:
            if any("HERMES_DELEG" in w for w in raw) and (any(re.fullmatch(r"HERMES_DELEG\w*=.*", w) for w in raw) or
                    {w.rsplit("/", 1)[-1] for w in raw} & {"unset", "export", "env", "declare", "typeset", "readonly", "local"}):
                return KANBAN_CLI
            words = strip_prefixes(raw)[0]
            name = words[0].rsplit("/", 1)[-1] if words else ""
            if name == "hermes" and "send" in words:   # RT5-05: alerts come from the stack, never from a builder's terminal
                return "builders never post with `hermes send`: report through your card (kanban_comment, kanban_block)"
            if name == "kanban" or words[1:2] == ["kanban"]:
                return KANBAN_CLI
            if "merge-card" in name or (name in ("bash", "sh", "zsh", "dash", "source", ".") and any("merge-card" in w for w in words[1:2])):
                return MERGE
    for toks in all_tokens(cmd):
        cwd, words, skip = base, [], False
        for i, t in enumerate(toks + [";"]):
            if skip:
                skip = False
                continue
            if t in REDIRECTS:
                hit = protected(toks[i + 1] if i + 1 < len(toks) else "", cwd)
                if hit:
                    return f"a {t} redirect writes {hit}" + (f" ({CONFIG_MSG})" if config_hit(hit) else "")
                skip = True
                continue
            if t not in SEP:
                words.append(t)
                continue
            hit = next(filter(None, (protected(w, cwd) for w in write_targets(words))), None)
            if hit:
                return f"`{' '.join(words)[:120]}` changes {hit}" + (f" ({CONFIG_MSG})" if config_hit(hit) else "")
            src = next((rp for w in link_sources(words) if outside_worktree(rp := resolve(w, cwd))), None)
            if src:
                return f"`{' '.join(words)[:120]}` hard-links {src}, a file outside your worktree"
            cmdw, xargs = strip_prefixes(words)
            if xargs and cmdw and cmdw[0].rsplit("/", 1)[-1] in WRITE_VERBS:
                return f"`{' '.join(words)[:120]}` feeds paths this guard cannot see to a write command"
            if cmdw[:1] in (["cd"], ["pushd"]):
                target = next((w for w in cmdw[1:] if not w.startswith("-")), "~")   # K1c: cd -P / -L / -- target
                if "$(" in target or "`" in target:
                    return f"`{' '.join(words)[:120]}`: a cd target built at run time cannot be checked; {CD_MSG}"
                cwd = resolve(target, cwd)
                if not in_worktree(cwd):   # K1c: Hermes keeps this folder for later relative paths, so it never leaves the card
                    return f"`{' '.join(words)[:120]}` moves the terminal to {cwd}: {CD_MSG}"
            words = []
    return None


def reason(p):
    if RT is None:
        return f"the role table cannot be read ({RT_ERROR}) [STL-CFG-303]; every write is refused until it is fixed"
    name, a = p.get("tool_name"), p.get("tool_input") or {}
    base = p.get("cwd") or os.getcwd()
    CALL.clear()
    CALL["p"] = p
    if name in ("write_file", "patch"):
        v4a = v4a_targets(a.get("patch") or "")
        if v4a is None:
            return ("a *** line in the patch is not a header Hermes's patch format knows; write each header as "
                    "`*** Update File: <absolute path>`")
        for raw in ([a["path"]] if a.get("path") else []) + v4a:
            if not os.path.isabs(os.path.expanduser(os.path.expandvars(str(raw).strip()))) and ".." in str(raw).split("/"):
                return (f"{raw} is a relative path with ..: Hermes resolves it against the terminal's current folder, "
                        "which this guard cannot see. Use the absolute path inside your worktree")
            rp = resolve(str(raw).strip(), base)
            if config_hit(rp):
                return f"{CONFIG_MSG}: {raw} resolves to {rp}. Write it inside your worktree, or under /tmp for scratch files"
            wt, why = own_worktree() if in_repo(rp) else (None, "")
            if in_repo(rp) and not wt and CALL.get("fault"):
                return stack_fault(p, raw)
            if in_repo(rp) and not (wt and inside(rp, wt)):
                return (f"builders write only inside their own worktree ({wt or why}); {raw} "
                        f"resolves to {rp}, the main checkout or another card's worktree. Write it inside your "
                        "worktree, or under /tmp for scratch files")
            if os.path.isfile(rp) and os.stat(rp).st_nlink > 1:   # K1b: a hard link reaches a file outside the worktree
                return f"{raw} has more than one hard link, so writing it may change a file outside your worktree"
        return None
    if name in ("terminal", "process_manage"):
        wd = a.get("workdir")
        if wd and not in_worktree(resolve(str(wd), base)):
            return stack_fault(p, f"workdir {wd}") if CALL.get("fault") else f"workdir {wd}: {CD_MSG}"   # K2 (RT5-04)
        cmd = str((a.get("data") if name == "process_manage" else a.get("command")) or "")
        r = command_reason(cmd, a.get("workdir") or base)
        if r and CALL.get("fault"):   # K2: the refusal came from an unproven card while the profile runs one
            return stack_fault(p, cmd[:120])
        if r and CONFIG_MSG in r:
            r += ". Reads stay allowed; to change a setting, call kanban_block with kind needs_input and say what"
        elif r and r not in (OWNER_ENV, MERGE, KANBAN_CLI) and "moves the terminal" not in r and "hard-links" not in r and "hermes send" not in r:
            r += (f". Protected: {', '.join(PROTECTED)}. Builders write only inside their own worktree: make the "
                  "change there, on your card branch")
        return r
    return None


try:
    why = reason(json.load(sys.stdin))
except Exception as e:  # fail closed: a payload we cannot read is refused
    why = f"unreadable payload: {type(e).__name__}"
if why is None:
    sys.exit(0)
tail = "" if why.startswith("[STL-GRD-603]") else " (D40). This refusal is final for this attempt."
print(json.dumps({"action": "block", "message": f"write guard: {why}{tail}"}))
sys.exit(2)
