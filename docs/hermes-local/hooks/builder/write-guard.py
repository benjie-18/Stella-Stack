#!/usr/bin/env python3
"""Write guard (D40, D46): pre_tool_call on write_file, patch, terminal and process_manage for every profile whose role
installs it (docs/hermes-local/roles.json: the roles whose hook entry says writes: judged). It stops mistaken writes to the main
checkout; it is not a security boundary, and since F1 W4 round 2 nothing claims it is. A text guard cannot decide what a shell will do,
so the owner-only write path is three layers, each holding on its own for the roles it covers (the contract's owner-only write path section says it):
 1. a role that runs in the OS box (sandbox.boxed_profiles) has the box as its boundary: the main checkout is read-only there, and the
    owner settings and every owner state path are not mounted;
 2. a role that does not (runs_unboxed: the coordinator, the fallback role) has hooks that refuse every write, not this guard (the table
    checks it: bin/roles.py unboxed_problems);
 3. whatever reaches a card branch by any route (git plumbing, another agent CLI's git, a patch) meets one check at the merge
    (bin/merge-card.sh), the single place every card change passes. The git routes this guard cannot judge are that layer's job.
This guard is the mistake guard in front of them. It reads a command the way the shell will: $'..' decoded, an unquoted newline is a
`;`, every redirect operator (> >> >| &> &>> >&word <>) is judged, and every word it judges (a redirect target, an argument of a write
verb, a git path, the command word, each argument of an interpreter) is expanded first (quotes, braces, globs, ~, the variables the
hook can know) with the code the read guard shares (roles.expand_word, bounded in work) and compared as a real path BY IDENTITY
(roles.overlap: the device and inode of each existing component, so a short 8.3 name, a case variant or a link is the same path).
The rule is turned around for the paths no role may write (owner data, the owner settings, the apply tool's state): a command that
NAMES one (as a word, inside interpreter code or a quoted command line, in a here-document body, or as a folder that holds one) runs
only when its verb is a known reader (roles.json read_verbs); an unknown writer needs no entry to be refused. Here-document bodies
are also judged by the text checks they had before round 2 (an owner command by name, the worker markers). A judged word that still
holds an expansion only the shell can compute ($(..), an unknown variable) is refused when the command could write or run.
What it cannot see, each with the layer that covers it (the contract's list a to g): a path the shell builds at run time in a command
that is neither a reader nor a listed write verb (the box, the merge); an interpreter that loads code from a file this guard does not
name, by import, -m or a pipe (the box, the merge); code run inside another agent CLI and that CLI's own git and file tools (the box,
the merge); a name that is the same path only across a mount this hook does not see (the box mounts none of the protected paths); git
routes it does not classify, plumbing built in a script or a patch from stdin (the commit guard, the merge); a hook that times out or
crashes (Hermes's policy; the stack registers every guard fail_closed and bounds the work of every expansion, K5).
The protected paths are the one list in roles.json (shared with the card guard, bin/role-guard.py). Only a role whose workspace is
git-worktree has a card worktree; any other role writes only to its profile's own cache/scratch.
 1. write_file / patch (also V4A patch text, its headers parsed with Hermes's own grammar, tools/patch_parser.py: both
    ends of a Move; a *** header that does not parse refuses the patch): every target must be an absolute path (K1b:
    Hermes resolves a relative one against the terminal's current folder, which a hook cannot see), and, resolved with
    realpath, inside the card's own worktree or outside /workspace. Anything else under /workspace (the main checkout,
    other cards' worktrees) is refused, and so is a file with more than one hard link (K1b).
 2. terminal / process_manage: the command text (and command lines nested in quotes, tokenized as git-guard.py does, with
    backticks as separators) must not mention owner.env or HERMES_DELEGATED_CHILD_CONTEXT, must not run an owner command (roles.json
    owner_commands, matched by the file the word resolves to; owner_commands_by_name also by the name anywhere in the text) or
    `hermes ... kanban` (the board is changed through the kanban tools, never the CLI: K1b), and must not point a write
    command or a redirect at a protected path or at /workspace outside the card's worktree, resolved against
    `workdir` or the payload cwd and any earlier `cd` on the same line. A `cd`/`pushd` or `workdir` into /workspace outside
    the worktree or into the agent configuration, a relative write target with `..`, and a hard link (`ln`, `cp -l`,
    `link`) of a file outside the worktree are refused (K1b: the terminal's current folder then stays where a relative
    path means what this guard reads). Reads stay allowed. Merging a card into main is the owner's step (F31).
    F1 W4: no write tool, redirect, copy/move/delete or git command writes owner data (the index, its owner_only rows, the table's
    owner_data list: bin/roles.py owner_paths) or an owner state path, in the main checkout or in a card worktree; no role runs an owner
    command. A git command that writes the working tree, the index or the refs (GIT_WRITERS, git's own command classes) is judged like
    any write: every path it names against the protected set, and the tree it runs in must be the caller's card worktree (or outside any
    repo); inside the worktree a tree-wide form (`.`, `:/`) is allowed, because the merge check judges what comes out of it.
The worktree (K1): the recorded workspace of the card whose own worker run this call belongs to, proven from the board
and the kernel by roles.prove_card (the card is the profile's, its open run is bound to an ancestor of this hook), never
from HERMES_KANBAN_TASK or /proc/<pid>/environ, which do not show the ids to a hook (D48). HERMES_KANBAN_WORKSPACE,
when set, must equal it. The proof is read only when a target needs it (inside /workspace or the agent configuration).
A workspace inside a bound repo (the deepest one holding it: the stack root or a project repo inside it) counts only if it is that card's own <repo>/.worktrees/<card> (F8: workspace_path is
whatever kanban_create was given, /workspace itself or another card's worktree included); else no worktree is known.
 3. Both tools: a target under the agent configuration (~/.hermes, ~/.claude, ~/.config/opencode, ~/.local/share/opencode) is
    refused (F-batch6): builders do not edit agent configuration. Only the profile's own cache/scratch and the card's own
    Hermes kanban workspace are allowed.
Refusals on the owner boundary print STL-CFG-312 with the catalog's plain message and write one alert line (no owner value).
Exit 2 = block; any error blocks, with a coded line."""
import glob, json, os, pwd, re, shlex, shutil, sys

OB = "STL-CFG-312"   # the catalog code of a refusal on the owner boundary; the alert line is written once, where the refusal is printed
try:
    sys.path.insert(0, "/workspace/bin")
    import roles   # noqa: E402  (the role table: one protected list, the caller's role)
    ROOT = roles.ROOT
    try:
        RT = roles.load()
        PROTECTED, CONFIG = roles.protected(RT)
        OWNER_FILES = roles.owner_settings(RT)
        OWNER_REL = [p for p in roles.owner_paths(RT) if p not in RT["owner_settings"]] + roles.state_paths(RT)   # G1/B1: owner data and the apply tool's state, from the index and the table, never named here (the owner settings keep their older refusals)
        OWNER_CMDS = roles.owner_commands(RT)
        BY_NAME = [os.path.splitext(os.path.basename(c))[0].casefold() for c in OWNER_CMDS if c[len(ROOT) + 1:] in RT["owner_commands_by_name"]]   # K9: the stem, so a copy without its extension is the same name
        WT_DIRS = glob.glob(f"{ROOT}/.worktrees/*")   # K1b: a path is protected by what it is, in the main checkout and in every card worktree of the stack
        OWNER_CH = roles.chains([f"{b}/{d}" for b in [ROOT, *WT_DIRS] for d in OWNER_REL])
        CMD_MSG = {}
        MARKERS, PINS = RT["worker_markers"], RT["worker_pins"]   # K9: the worker markers and pins are the table's, named nowhere else
        READERS = {v for v in RT["read_verbs"] if " " not in v}   # K7: the verbs that may name an owner path (data: the role table)
        GIT_READS = {v.split(" ", 1)[1] for v in RT["read_verbs"] if v.startswith("git ")}
    except Exception as e:   # every call is refused below until the table (and the index it names) can be read
        RT, PROTECTED, CONFIG, OWNER_FILES, OWNER_REL, OWNER_CMDS, BY_NAME, OWNER_CH, CMD_MSG, READERS, GIT_READS, WT_DIRS, MARKERS, PINS, RT_ERROR = None, [], [], [], [], [], [], [], {}, set(), set(), [], [], {}, str(e)[:200]
    HOMES = roles.homes()
except Exception as e:   # not even the role module loads: refuse, with a coded line
    print(json.dumps({"action": "block", "message": f"write guard: [{OB}] the role module cannot be loaded ({type(e).__name__}); every write is refused until it is fixed"}))
    sys.exit(2)
CALL = {}   # this call's payload, and its card worktree once a target needs it (proven at most once per call)
CONFIG_MSG = "builders do not edit agent configuration (~/.hermes, ~/.claude, ~/.config/opencode, ~/.local/share/opencode)"
SEP = {"&&", "||", ";", "|", "&", "(", ")", "|&", ";;"}
PREFIXES = {"sudo", "env", "nohup", "time", "command", "exec", "builtin", "timeout", "nice", "ionice", "stdbuf", "setsid",
            "chroot", "doas", "xargs", "{", "}", "!", "then", "do", "else"}   # K1c: wrappers whose command is the real one
WRITE_VERBS = {"cp", "install", "ln", "mv", "rm", "truncate", "tee", "chmod", "chown", "chattr", "dd", "sed", "rsync",
               "find", "tar", "unzip", "patch"}   # the commands write_targets reads; xargs feeding one is refused
WRAP_ARG = re.compile(r"-.*|[0-9.]+[smhd]?")   # a wrapper's own options and numbers (timeout 5, nice -n 0)
ASSIGN = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", re.S)


def strip_prefixes(words):
    """(the simple command without its wrappers and VAR=value words, whether xargs fed it)."""
    xargs, wrapped = False, False
    while words:
        w = words[0].rsplit("/", 1)[-1]
        if w in PREFIXES or ASSIGN.fullmatch(words[0]):
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
KANBAN_CLI = ("builders never run `hermes kanban` or touch " + ", ".join(MARKERS or ["the worker markers"]) + ": change your card with the "
              "kanban tools (kanban_comment, kanban_block, kanban_complete, ...)")
OWNER_DATA_MSG = ("owner data: only the owner's apply path writes it. If it must change, call kanban_block with kind needs_input "
                  "and say what should change")
# git's own command classes that write the working tree, the index, the refs or the object store (porcelain and plumbing); the rest of the
# git routes (a commit built by plumbing, another CLI's git, a patch) is the merge check's job (bin/merge-card.sh).
GIT_WRITERS = {"add", "rm", "mv", "commit", "checkout", "switch", "restore", "reset", "stash", "apply", "am", "cherry-pick", "revert",
               "merge", "rebase", "pull", "clean", "read-tree", "checkout-index", "update-index", "write-tree", "hash-object", "commit-tree",
               "mktree", "mktag", "update-ref", "filter-branch", "fetch", "replace", "gc", "prune", "repack"}
GIT_CREATORS = {"clone", "init"}   # create a repository at a named path (judged by the path, not by the tree they run in)
GIT_PATCHES = {"apply", "am"}      # take their paths from a patch
INTERPRETERS = {"bash", "sh", "zsh", "dash", "ksh", "source", ".", "python", "perl", "node", "ruby", "php", "awk", "gawk", "mawk", "lua", "deno", "bun"}
CD_MSG = ("the terminal stays inside your worktree: Hermes keeps its folder between calls, so a later relative path would "
          "write wherever it moved. Use absolute paths to read or write elsewhere (for example /tmp)")
# F1 W4: one rule per owner command (roles.json owner_commands): matched by the file a command word or an interpreter's argument resolves to
# (its real path, without regard to case): the stack's own file or its copy in a card worktree of the stack (a copy runs on whatever tree
# STELLA_ROOT names); a project's own file with the same base name is no mention.
CMDS = {c[len(ROOT) + 1:]: f"{c[len(ROOT) + 1:]} is an owner command: no role runs it (the owner runs it from the owner's own path; merging a card into main is the owner's step, F31)"
        for c in OWNER_CMDS}
CMD_CH = roles.chains([f"{b}/{c}" for b in [ROOT, *(WT_DIRS if RT else [])] for c in CMDS])
CMD_MSG.update({f"{b}/{c}": m for b in [ROOT, *(WT_DIRS if RT else [])] for c, m in CMDS.items()})
NAME_RX = re.compile("|".join(r"(?<![\w-])" + re.escape(n) + r"(?![\w-])" for n in BY_NAME)) if BY_NAME else None


def owner_cmd_of(rp):
    """The refusal text when rp (a path) is an owner command of the stack, or its copy in a card worktree of the stack, by what the path IS (a short name
    or a case variant included); else None. A copy elsewhere is a different file: the name check (named_cmd) and the box and the merge cover it."""
    r = roles.overlap(rp, CMD_CH)
    return CMD_MSG.get(r[1]) if r and r[0] in ("equal", "unknown") else None


def named_cmd(text):
    """The refusal text of the first owner_commands_by_name command whose name (without its extension) appears in text (already lower-cased), else None."""
    m = NAME_RX.search(text) if NAME_RX else None
    return next((msg for rel, msg in CMDS.items() if m and os.path.splitext(os.path.basename(rel))[0].casefold() == m[0]), None)


FINAL = {KANBAN_CLI}


def ob(detail):
    """A refusal on the owner boundary: coded here, logged once where it is printed."""
    return f"[{OB}] {detail}"


def inside(path, root):
    path, root = path.casefold(), root.casefold()   # /workspace is case-insensitive (B2V-01)
    return path == root or path.startswith(root.rstrip("/") + "/")


def resolve(path, base):
    return os.path.realpath(os.path.join(base, os.path.expanduser(os.path.expandvars(path))))


def owner_data_hit(rp):
    """F1 W4/K1b: rp (a path) is, or is inside, an owner data path of the stack (bin/roles.py owner_paths: owner data, the owner settings, the apply
    tool's state), in its main checkout or in a card worktree of it, decided by identity (roles.overlap): another spelling of it, a short name or a
    case variant, is the same path, and a name that cannot be classified counts. Reading owner data stays allowed; this is asked of writes only."""
    r = roles.overlap(rp, OWNER_CH)
    return bool(r) and r[0] in ("equal", "inside", "unknown")


def words_of(w, cwd, names):
    """(real paths the shell can make of word w, whether an expansion is left only the shell can compute)."""
    return roles.expand_word(w, cwd, names)


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
    CALL["card"] = card
    env = os.environ.get(PINS["workspace"], "")
    if env and os.path.realpath(env) != ws:
        return None, f"no card worktree known: {PINS['workspace']} {env} is not card {card}'s workspace {ws}"
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


HEREDOC = re.compile(r"<<(-?)[ \t]*(?:'([^'\n]*)'|\"([^\"\n]*)\"|(\\?)([A-Za-z_][A-Za-z0-9_]*))")


BODIES = []   # the here-document bodies of this call's command (K7: judged by the text checks, and when they name an owner path by the verb that reads them)


def clean(cmd):
    """The command as the shell reads its lines: $'..' decoded; a backslash-newline joined; an unquoted newline outside a comment is a
    `;` (G2: a second line is a command of its own); a here-document's body is text, not commands (only the $(..) and backtick parts of an
    unquoted one are kept, they run)."""
    cmd = roles.ansi(cmd)
    out, q, i, n, comment, pending = [], "", 0, len(cmd), False, []
    while i < n:
        c = cmd[i]
        if comment:   # the newline that ends a comment stays a newline: all_tokens' second view reads a comment as ending there
            out.append(c)
            comment = c != "\n"
        elif c == "\\" and q != "'" and i + 1 < n:
            if cmd[i + 1] != "\n":
                out.append(cmd[i:i + 2])
            i += 1
        elif q:
            q = "" if c == q else q
            out.append(c)
        elif c in "'\"":
            q = c
            out.append(c)
        elif c == "#" and (i == 0 or cmd[i - 1] in " \t\n;&|()<>"):
            comment = True
            out.append(c)
        elif c == "<" and cmd.startswith("<<", i) and not cmd.startswith("<<<", i) and (m := HEREDOC.match(cmd, i)):
            pending.append((m[2] if m[2] is not None else m[3] if m[3] is not None else m[5], m[2] is not None or m[3] is not None or bool(m[4]), m[1] == "-"))
            out.append(m[0])
            i = m.end() - 1
        elif c == "\n":
            out.append(" ; ")
            for delim, quoted, tabs in pending:   # the body: lines up to the delimiter line (or the end of the text, as the shell reads it)
                while i + 1 < n:
                    j = cmd.find("\n", i + 1)
                    line = cmd[i + 1:j if j >= 0 else n]
                    i = j if j >= 0 else n
                    if (line.lstrip("\t") if tabs else line) == delim:
                        break
                    BODIES.append(line)
                    if not quoted:
                        out += [f" {x} ; " for x in re.findall(r"\$\([^)\n]*\)|`[^`\n]*`", line)]
            pending = []
        else:
            out.append(c)
        i += 1
    return "".join(out)


OPS = re.compile(r"&>>|<<<|>>&|&>|>>|>&|>\||<>|<<|<&|\|\||&&|;;|\|&|[;|&()<>]")


def split_ops(out):
    """shlex joins operator characters that touch (`);`, `))`, `;&`) into one token the SEP set does not know: cut them into single operators."""
    res = []
    for t in out:
        res += OPS.findall(t) if t and re.fullmatch(r"[();|&<>]+", t) else [t]
    return res


def tokens(cmd, depth=0, commenters=""):
    # K1b: a backtick or $(..) command is a command of its own; the word it stands in keeps an unresolvable variable, so a path built from it is never judged as a literal
    cmd = re.sub(r"`([^`]*)`", r" $STELLA_CMDSUB ; \1 ; ", cmd).replace("`", " ; ").replace("$(", "$STELLA_CMDSUB(")
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.commenters = commenters   # RT22-01: "" = a # inside a word is text; "#" = the parse used before RT22-01 (see all_tokens)
        lex.whitespace_split = True
        out = list(lex)
    except ValueError:   # shlex is not bash (heredocs, $'…', an apostrophe in prose): scan the plain words instead
        if commenters:
            return   # the pre-RT22-01 view is only an extra view: skipped when it cannot parse
        out = [re.sub(r"[\"'\\]", "", w) for w in re.findall(r"[();<>|&]+|[^\s();<>|&]+", cmd.replace("\n", " ; "))]   # RT23-02: same words and operators shlex would give, quote marks dropped, not a bare whitespace split
    out = split_ops(out)
    for t in list(out):
        if depth < 3 and re.search(r"\s", t):   # a quoted command line: bash -c '…', opencode run '…'
            yield from tokens(clean(t), depth + 1, commenters)
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


def redirect(t):
    """True for a redirect operator that opens a file for writing: > >> >| &> &>> >& <> (a leading descriptor number is its own word)."""
    return bool(re.fullmatch(r"[<>&|]+", t)) and (">" in t)


def protected(arg, cwd, names):
    """The resolved path (or the reason) when writing arg is refused: a protected path, the agent configuration, an owner data or state
    path, /workspace outside the card's worktree (K1b, the same rule as write_file), a relative path with .. (the terminal's folder
    is not known), or a word with an expansion only the shell can compute."""
    if not arg:
        return None
    if not os.path.isabs(os.path.expanduser(os.path.expandvars(arg))) and ".." in arg.split("/"):
        return f"{arg} (a relative path with ..)"
    paths, unres = words_of(arg, cwd, names)
    if unres:
        return f"{arg} (a path the shell builds at run time, which this guard cannot check)"
    for rp in paths:
        if any(inside(rp, p) for p in PROTECTED) or config_hit(rp) or owner_data_hit(rp):
            return rp
        if os.path.isfile(rp) and os.stat(rp).st_nlink > 1:   # K1c: a hard link reaches a file outside the worktree
            return f"{rp} (more than one hard link)"
        if outside_worktree(rp):
            return rp
    return None


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


def git_why(words, cwd, names, cmd):
    """The reason a git command is refused, or None. A git command that writes (GIT_WRITERS) is judged like any write: every path it names
    (update-index --cacheinfo: its path too) against the protected set and the owner data, and the tree it runs in (-C, the folder) must be
    the caller's card worktree or outside every repo: in the main checkout, or another card's worktree, every form is refused. In the
    worktree a form with no path or a tree-wide one (`.`, `:/`, a pathspec with magic) is allowed: the merge check judges what comes out of
    it. --pathspec-from-file, --git-dir, --work-tree and GIT_* variables name paths or trees the hook cannot see: refused for a writer."""
    w, base = strip_prefixes(words)[0], cwd
    if not w or w[0].rsplit("/", 1)[-1] != "git":
        return None
    i, blind = 1, any(re.match(r"GIT_(?:DIR|WORK_TREE|INDEX_FILE|OBJECT_DIRECTORY|COMMON_DIR|NAMESPACE)=", x) for x in words)
    while i < len(w) and w[i].startswith("-"):
        if w[i] == "-C" and i + 1 < len(w):
            paths, unres = words_of(w[i + 1], base, names)
            base, blind = (paths[0] if paths and not unres else base), blind or unres
        blind = blind or w[i].split("=", 1)[0] in ("--git-dir", "--work-tree")
        i += 2 if w[i] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path") else 1
    sub, args = (w[i] if i < len(w) else ""), w[i + 1:]
    if sub not in GIT_WRITERS | GIT_CREATORS:
        return None
    if blind or any(a.startswith(("--pathspec-from-file", "--git-dir", "--work-tree", "--index-info")) for a in args) or (sub == "update-index" and "--stdin" in args):
        return "git is given a tree or a list of paths this guard cannot see (--git-dir, --work-tree, GIT_DIR, --pathspec-from-file, --index-info)"
    if sub in GIT_WRITERS and in_repo(base) and not in_worktree(base):
        return f"`git {sub}` changes {base}, which is not your own card worktree (the main checkout and other cards' worktrees are the owner's)"
    named = [a for a in args if not a.startswith("-")]
    if sub == "update-index":   # --cacheinfo <mode>,<sha>,<path> or <mode> <sha> <path>: the path is the last field
        for k, a in enumerate(args):
            if a == "--cacheinfo" or a.startswith("--cacheinfo="):
                f = (a.split("=", 1)[1] if "=" in a else args[k + 1] if k + 1 < len(args) else "").split(",")
                named += [f[-1]] if len(f) == 3 else args[k + 3:k + 4]
    dirs = [base] + [resolve(a.split("=", 1)[1], base) for a in args if a.startswith("--directory=")]
    for a in named:
        if sub in GIT_WRITERS and not in_repo(base):   # a tree outside every repo: its paths are its own (option values and messages are not paths)
            break
        if a.startswith(":") and sub in GIT_WRITERS:   # pathspec magic (:/ :(top)): the tree it runs in was judged above
            continue
        for d in dirs:
            if sub in GIT_WRITERS and in_worktree(d) and not owner_hit_word(a, d, names):
                continue   # a path in the card's own worktree: only owner data matters there (the merge check and the commit guard judge the rest)
            hit = protected(a, d, names)
            if hit:
                return hit
    if sub in GIT_PATCHES:
        for a in named:   # the files a patch names, with and without the a/ b/ prefix
            for f in words_of(a, base, names)[0]:
                if not os.path.isfile(f):
                    continue
                try:
                    with open(f, encoding="utf-8", errors="replace") as fh:
                        text = fh.read()
                except OSError:
                    return f  # a patch that cannot be read cannot be checked
                for n in (x for pair in re.findall(r"^(?:\+\+\+ |--- |diff --git |rename (?:to|from) |copy (?:to|from) )(\S+)(?: (\S+))?", text, re.M) for x in pair if x and x != "/dev/null"):
                    for d in dirs:
                        for cand in (n, n.split("/", 1)[-1]):
                            if owner_data_hit(resolve(cand, d)):
                                return resolve(cand, d)
        if any(d.casefold() in cmd.casefold() for d in OWNER_REL):   # a patch given on stdin: its text is in the command
            return f"a patch naming one of {len(OWNER_REL)} owner data paths"
    return None


def git_hit(words, cwd, names, cmd):
    """git_why, coded when the refusal is about owner data."""
    why = git_why(words, cwd, names, cmd)
    if not why:
        return None
    msg = f"`{' '.join(words)[:120]}`: {why}"
    return ob(f"{msg} ({OWNER_DATA_MSG})") if owner_data_hit(why.split(" ")[0]) else msg


def owner_hit_word(a, d, names):
    """True when the word a, read in folder d, is (or may be) an owner data or state path."""
    paths, unres = words_of(a, d, names)
    return any(owner_data_hit(p) for p in paths)


def owner_cmd_why(words, cwd, names):
    """The refusal when this simple command runs an owner command: the command word resolves (braces, globs, ~, known variables, PATH, case)
    to the file of one; and when the command word is a wrapper (env, timeout, sudo, xargs ...) or an interpreter, so does any other word of the
    command, because a wrapper's option values (env -u NAME, timeout -s KILL 5) cannot be told from the program it runs. A word of the command
    (or the script an interpreter is given) that holds an expansion only the shell can compute is refused too: the hook cannot tell what runs."""
    k = 0
    while k < len(words) and ASSIGN.fullmatch(words[k]):
        k += 1
    rest = words[k:]
    if not rest:
        return None
    norm = lambda w: re.sub(r"(?<=[A-Za-z])[0-9.]+$", "", w.rsplit("/", 1)[-1])
    judged = rest if norm(rest[0]) in INTERPRETERS | PREFIXES else rest[:1]
    cmdw = strip_prefixes(words)[0]   # the program the wrappers run, as far as their options can be told apart
    for wd in judged:
        paths = words_of(wd, cwd, names)[0]
        if wd == rest[0] and "/" not in wd and (found := shutil.which(wd)):
            paths.append(os.path.realpath(found))
        for p in paths:
            if owner_cmd_of(p):
                return ob(owner_cmd_of(p))
    script = next((w for w in cmdw[1:] if not w.startswith("-")), None) if cmdw and norm(cmdw[0]) in INTERPRETERS else None
    for wd in cmdw[:1] + ([script] if script else []):
        if words_of(wd, cwd, names)[1]:
            return ob(f"`{' '.join(words)[:120]}` runs a command or script built at run time, which this guard cannot check; owner commands are never run by a role")
    return None


def target_why(t, cwd, names, kind):
    hit = protected(t, cwd, names)
    if not hit:
        return None
    msg = f"{kind} {hit}"
    return ob(f"{msg} ({OWNER_DATA_MSG})") if owner_data_hit(hit) else msg + (f" ({CONFIG_MSG})" if config_hit(hit) else "")


def note_names(words, names, cwd):
    """Variables a line sets for later words: NAME=value alone, or after export/declare/local/readonly/typeset; and the variable of
    `for NAME in words`, which stands for the word the guard likes least (a protected or owner path, else the first), so
    `for f in *.txt; do mv "$f" "$f.bak"; done` is judged on its literal list while a list built at run time stays unresolved."""
    if words[:1] == ["for"] and words[2:3] == ["in"] and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", words[1] if len(words) > 1 else ""):
        items = words[3:]
        if items and not any(words_of(it, cwd, names)[1] for it in items):
            bad = [it for it in items if any(any(inside(p, x) for x in PROTECTED) or owner_data_hit(p) for p in words_of(it, cwd, names)[0])]
            names[words[1]] = (bad or items)[0]
        return
    k = 0
    while k < len(words) and ASSIGN.fullmatch(words[k]):
        k += 1
    rest = words[k:]
    if not rest or rest[0].rsplit("/", 1)[-1] in ("export", "declare", "typeset", "readonly", "local"):
        for x in (words[:k] + rest[1:]):
            m = ASSIGN.fullmatch(x)
            if m:
                names[m[1]] = m[2]


PATHLIKE = re.compile(r"[\w.~$@+%/-]+")   # runs of path characters; those with a slash in them are paths, or the path inside a quoted word or interpreter code (linear: K5)
MAX_CANDS = 3000   # K5: no command costs more than this many path look-ups; past it the command is refused


def cands(w):
    """The strings of a shell word that may be a path: the word, and the path-like pieces of a word that holds code, an assignment or an option value."""
    out = [w]
    if re.search(r"[\s'\"(){};=,\[\]<>|&]", w) or len(w) > 80:
        out += [x for x in PATHLIKE.findall(w) if "/" in x]
    return out


def named_path(texts, cwd, names, budget):
    """K7: the first owner path the strings name, as (path, relation), or None; budget is a one-item list, counted down (K5). The tree-wide form (the card's
    own worktree root, `.`) is not a naming: the merge check judges what comes out of it."""
    for t in texts:
        for c in cands(t):
            budget[0] -= 1
            if budget[0] < 0:
                return "(too many paths in this command to check)", "unknown"
            if not c or (c.startswith("-") and "/" not in c):
                continue
            for rp in words_of(c, cwd, names)[0]:
                r = roles.overlap(rp, OWNER_CH)
                if r and r[0] == "contains" and (wt := own_worktree()[0]) and os.path.realpath(rp) == os.path.realpath(wt):
                    continue   # the proven worktree is looked up only when a folder that holds owner data is named
                if r:
                    return rp, r[0]
    return None


def reader_ok(words):
    """K7: the verb of the simple command is a known reader (the role table's read_verbs; `git show|diff|log ...` by subcommand), and not a reader that writes by an option."""
    w = strip_prefixes(words)[0]
    if not w:
        return True
    v = w[0].rsplit("/", 1)[-1]
    if v == "git":
        i = 1
        while i < len(w) and w[i].startswith("-"):
            i += 2 if w[i] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path") else 1
        return i < len(w) and w[i] in GIT_READS and not any(a.startswith(("--output", "-o")) for a in w[i + 1:])
    if v == "find" and any(a in ("-delete", "-exec", "-execdir", "-ok", "-okdir") or a.startswith(("-fprint", "-fls")) for a in w[1:]):
        return False
    return v in READERS


def named_why(words, cwd, names, budget):
    """K7, the rule turned around: a command that names a path no role may write (owner data, the owner settings, an apply-tool state path), as a word, inside
    interpreter code or a quoted command line, or as a folder that holds one, runs only when its verb is a known reader. An unknown writer (sort -o, perl -pi,
    touch, gzip, curl -o, tar -C, cp x <folder>/) needs no entry to be refused. A command run with an owner folder as its folder counts the same."""
    if reader_ok(words):
        return None
    found = named_path([w for w in words if not ASSIGN.fullmatch(w) or "/" in w], cwd, names, budget)
    if not found and (r := roles.overlap(cwd, OWNER_CH)) and r[0] in ("equal", "inside", "unknown"):
        found = cwd, r[0]
    if not found:
        return None
    return ob(f"`{' '.join(words)[:120]}` names {found[0]}, which is owner data or an apply-tool state path ({found[1]}); only a known reader of files (cat, grep, jq, diff, git show ...) may name it. {OWNER_DATA_MSG}")


def marker_reason(cmd):
    """The per-command text checks a here-document body is judged by too (they are run on the command and on each body line): `hermes kanban`, `hermes send`,
    HERMES_DELEGATED_CHILD_CONTEXT set, unset or exported, an owner command by name."""
    low = cmd.casefold()
    if NAME_RX and NAME_RX.search(low):
        return ob(named_cmd(low))
    for toks in all_tokens(cmd):
        simple, cur = [], []
        for t in toks + [";"]:
            if t in SEP:
                simple, cur = simple + [cur] if cur else simple, []
            else:
                cur.append(t)
        for raw in simple:
            if any(NAME_RX and NAME_RX.search(w.casefold()) for w in raw):   # a spelling the text match missed (merge''-card.sh): the shell's word is the name
                return ob(named_cmd(" ".join(raw).casefold()))
            if any(m in w for w in raw for m in MARKERS) and (any(re.fullmatch("(?:" + "|".join(map(re.escape, MARKERS)) + r")\w*=.*", w) for w in raw) or
                    {w.rsplit("/", 1)[-1] for w in raw} & {"unset", "export", "env", "declare", "typeset", "readonly", "local"}):
                return KANBAN_CLI
            words = strip_prefixes(raw)[0]
            name = words[0].rsplit("/", 1)[-1] if words else ""
            if name == "hermes" and "send" in words:   # RT5-05: alerts come from the stack, never from a builder's terminal
                return "builders never post with `hermes send`: report through your card (kanban_comment, kanban_block)"
            if name == "kanban" or words[1:2] == ["kanban"]:
                return KANBAN_CLI
    return None


def command_reason(cmd, base):
    BODIES.clear()
    whole = roles.ansi(cmd)   # K7: the text checks see the whole command, here-document bodies included
    cmd = clean(cmd)
    low = whole.casefold()
    if any(os.path.basename(f).casefold() in low for f in OWNER_FILES):   # K6: the owner settings files, from roles.json
        return ob(OWNER_ENV)   # K8: an older rule that catches it first still says so with the code
    if NAME_RX and NAME_RX.search(low):   # owner_commands_by_name: any command text naming it (the breadth it had at 900d9b3)
        return ob(named_cmd(low))
    for part in [cmd, *BODIES]:   # the command, then each here-document line: judged by the text checks they had before round 2 (VER2-08)
        r = marker_reason(part)
        if r:
            return r
    budget, users = [MAX_CANDS], []
    for toks in all_tokens(cmd):
        cwd, words, names, skip = base, [], {}, False
        for i, t in enumerate(toks + [";"]):
            if skip:
                skip = False
                continue
            if redirect(t):
                tgt = toks[i + 1] if i + 1 < len(toks) else ""
                if tgt and tgt not in SEP and not (t.endswith("&") and re.fullmatch(r"\d+-?|-", tgt)):   # >&2 duplicates a descriptor, it opens no file
                    why = target_why(tgt, cwd, names, f"a {t} redirect writes")
                    if why:
                        return why
                skip = True
                continue
            if t not in SEP:
                words.append(t)
                continue
            note_names(words, names, cwd)
            hit = next(filter(None, (target_why(w, cwd, names, f"`{' '.join(words)[:120]}` changes") for w in write_targets(words))), None) \
                or git_hit(words, cwd, names, cmd) or owner_cmd_why(words, cwd, names) or named_why(words, cwd, names, budget)
            if hit:
                return hit
            if "<<" in words or "<<-" in words:
                users.append(list(words))
            src = next((rp for w in link_sources(words) if outside_worktree(rp := resolve(w, cwd))), None)
            if src:
                return f"`{' '.join(words)[:120]}` hard-links {src}, a file outside your worktree"
            cmdw, xargs = strip_prefixes(words)
            cname = re.sub(r"(?<=[A-Za-z])[0-9.]+$", "", cmdw[0].rsplit("/", 1)[-1]) if cmdw else ""
            if xargs and cname in WRITE_VERBS | INTERPRETERS:
                return f"`{' '.join(words)[:120]}` feeds paths this guard cannot see to a write command or an interpreter"
            if cname == "find":   # find -exec <interpreter>: the command it runs is built from files found at run time
                ex = [cmdw[k + 1] for k, x in enumerate(cmdw[:-1]) if x in ("-exec", "-execdir", "-ok", "-okdir")]
                if any(re.sub(r"(?<=[A-Za-z])[0-9.]+$", "", x.rsplit("/", 1)[-1]) in INTERPRETERS for x in ex):
                    return f"`{' '.join(words)[:120]}` runs an interpreter on files found at run time, which this guard cannot check"
            if cmdw[:1] in (["cd"], ["pushd"]):
                target = next((w for w in cmdw[1:] if not w.startswith("-")), "~")   # K1c: cd -P / -L / -- target
                if "$(" in target or "`" in target:
                    return f"`{' '.join(words)[:120]}`: a cd target built at run time cannot be checked; {CD_MSG}"
                cwd = resolve(target, cwd)
                if not in_worktree(cwd):   # K1c: Hermes keeps this folder for later relative paths, so it never leaves the card
                    return f"`{' '.join(words)[:120]}` moves the terminal to {cwd}: {CD_MSG}"
            words = []
    if any(named_path([b], base, {}, budget) for b in BODIES) and not (users and all(reader_ok(u) for u in users)):   # K7: a body that names an owner path, read by a verb that is no reader
        return ob(f"a here-document body names an owner data or apply-tool state path, and the command that reads it is no known reader of files. {OWNER_DATA_MSG}")
    return None


def reason(p):
    if RT is None:
        return f"the role table cannot be read ({RT_ERROR}); every write is refused until it is fixed [STL-CFG-303]"
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
            if owner_data_hit(rp):   # F1 W4: before the worktree rule: the owner's data is not writable even in a card's own worktree
                return ob(f"{raw} resolves to {rp}, {OWNER_DATA_MSG}")
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
        elif r and not r.startswith(f"[{OB}]") and r not in FINAL and "owner data" not in r and "moves the terminal" not in r and "hard-links" not in r and "hermes send" not in r:
            r += (f". Protected: {', '.join(PROTECTED)}. Builders write only inside their own worktree: make the "
                  "change there, on your card branch")
        return r
    return None


PAY = sys.stdin.read()
try:
    P = json.loads(PAY)
    why = reason(P)
except Exception as e:  # fail closed: a call we cannot judge is refused, with a coded line
    P, why = {}, ob(f"the write guard could not judge this call ({type(e).__name__})")
if why is None:
    sys.exit(0)


def coded(code, problem):   # K8: the catalog code, its plain message, one alert line for the call (the role's other hook that refuses it writes none); the role and the card named
    try:
        role = roles.role_of(RT, P.get("profile"))[0]
    except Exception:
        role = "unknown"
    card = CALL.get("card")
    return roles.plain(code, once=PAY, problem=f"{problem} (role {role}{', card ' + card if card else ''})")


if why.endswith("[STL-CFG-303]"):
    print(json.dumps({"action": "block", "message": "write guard: " + coded("STL-CFG-303", "the role table or the data index cannot be read by the write guard") + " Every write is refused until it is fixed."}))
    sys.exit(2)
if why.startswith(f"[{OB}] "):   # one alert line per refusal, the catalog's plain message, no value from any owner file
    why = coded(OB, "a role's attempt on owner data, an owner state path or an owner command") + " " + why[len(OB) + 3:]
tail = "" if why.startswith("[STL-GRD-603]") else " (D40). This refusal is final for this attempt."
print(json.dumps({"action": "block", "message": f"write guard: {why}{tail}"}))
sys.exit(2)
