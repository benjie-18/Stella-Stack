#!/usr/bin/env python3
"""Builder model guard (F14): pre_tool_call on terminal and process_manage for every
profile whose role installs it (docs/hermes-local/roles.json, D46).
Claude Code runs here only as the worker model: the model of the first usable link, on a connection whose `cli` is this CLI,
of the chain the resolver (bin/resolve.py, read-only) answers for the role of the payload's profile; this file names no model.
A role that works a card (routing data card_roles) is asked with the card the role tool proves and that card's project; any
other role with no card. Every `claude` that
runs a model (-p/--print, or a bare interactive claude) needs --model <the worker model> (its id, or a longer name of it:
claude-<id>-*), and no claude call may skip permissions (--dangerously-skip-permissions,
--allow-dangerously-skip-permissions, --permission-mode bypassPermissions, --yolo) or fall back to another model.
A bare claude -p is refused because the builder's default model is no worker model (~/.claude/settings.json).
Every other model goes only through bin/escalate.sh, which only the supervisor runs: every call of it is refused here (owner
decision 2026-11-17; the supervisor's role installs no model guard, so the role table alone keeps it free). When the resolver, the catalog or the role table cannot be asked, or the resolver lists no usable
link of this CLI, there is no worker model: every model is refused (fail closed).
Nested quoted command lines are tokenized as git-guard.py does. Exit 2 = block; any error blocks."""
import functools, json, re, shlex, sys

SEP = {"&&", "||", ";", "|", "&"}
SKIP = {"--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--yolo"}
NO_MODEL = {"--version", "-v", "-V", "--help", "-h", "mcp", "doctor", "update", "config", "plugin"}
CLI = ("claude", "claude-code")   # this CLI's command names; a catalog connection whose `cli` is one of them holds its models
CATALOG = "connections"           # the schema of the index rows that hold the catalog
ROUTING = "routing"               # the schema of the routing data (card_roles: the roles the resolver needs a card for)
PROFILE = None                    # the payload's profile: the resolver is asked for its role
NOASK = []                        # why the worker model could not be asked, once it could not (the refusal does not ask again)
RUN = {"-p", "--print", "--model", "--fallback-model", "--permission-mode"} | SKIP   # flags only a run of claude takes
PREFIX = {"sudo", "env", "nohup", "time", "exec", "nice", "stdbuf"}


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


def opt(args, name):
    """Values of --name X and --name=X."""
    return [args[i + 1] for i, a in enumerate(args[:-1]) if a == name] + [a.split("=", 1)[1] for a in args if a.startswith(name + "=")]


def docs(sd, schema):
    """[(index row, file, its document)] of a schema, each file checked against it first."""
    return [(row, rel, sd.checked(sd.load(rel), rel, schema)) for row in sd.rows() if row["schema"] == schema for rel, _ in sd.files_of(row)]


@functools.lru_cache(maxsize=None)
def catalog_models():
    """{model id: is it the worker model} over the catalog's connections whose cli is this CLI: the worker model is the model of
    the resolver's first usable link on one of them, for the role of the payload's profile. Anything that cannot be read or
    asked raises, and the caller refuses."""
    sys.path.insert(0, "/workspace/bin")
    import stella_data as sd, roles, resolve
    mine = [e for row, rel, d in docs(sd, CATALOG) for _, e in sd.file_entries(row, rel, d) if e.get("cli") in CLI]
    out = {m["id"]: False for e in mine for m in e["models"]}
    role = roles.role_of(roles.load(), PROFILE)[0]
    ask = {"role": role, "project": "", "card": None}   # a role that works no card has no project: the default policy judges it
    if any(role in d["card_roles"] for _, _, d in docs(sd, ROUTING)):
        j, unproven = roles.prove_card(PROFILE)
        if not unproven:   # no proven card: the resolver refuses a card role asked with none
            t = j["task"]
            ask.update(card=t["id"], project=t.get("project") or (t.get("branch_name") or "").partition("/")[0])
    ans = resolve.resolve(ask)
    usable = [l["model"] for l in ans["chain"] if l["status"] == "usable" and l["connection"] in {e["id"] for e in mine}]
    if usable and usable[0] in out and not ans["code"]:   # a refused answer (a card app the resolver refuses) allows no model
        out[usable[0]] = True
    return out


def worker(name, models):
    """A worker model's id, or a longer name of it; a name the catalog lists is judged by its own row only."""
    return models.get(name, True) and any(re.fullmatch(rf"(claude-)?{re.escape(i)}\S*", name) for i, ok in models.items() if ok)


def why(args):
    if SKIP & set(args) or "bypassPermissions" in opt(args, "--permission-mode"):
        return "claude may not skip permissions"
    asked, fallback = opt(args, "--model"), opt(args, "--fallback-model")
    if asked or fallback:
        try:
            models = catalog_models()
        except (Exception, SystemExit) as e:   # fail closed: with no answer no model is known to be the worker model
            NOASK.append(type(e).__name__)
            return f"the resolver, the connections catalog or the role table cannot be asked ({type(e).__name__}), so no model can be allowed"
        if any(not worker(m, models) for m in fallback):
            return "claude may fall back only to the worker model"
        if any(not worker(m, models) for m in asked):
            return f"claude --model {asked[0]}: workers run Claude Code only as the worker model"
    if not asked and not (args and args[0] in NO_MODEL):
        return "claude without --model runs the default model, which is no worker model here"
    return None


def check(cmd):
    if re.search(r"ESCALATE_(SUP_DIR|REPLAY)\b", cmd):   # review H2: a builder's own limits.env or queue bypass
        return "ESCALATE_SUP_DIR and ESCALATE_REPLAY are for the self-tests and the drain, never set by a builder"
    for toks in all_tokens(cmd):
        for i, t in enumerate(toks):
            name = t.rsplit("/", 1)[-1]
            if name not in ("claude", "claude-code", "escalate.sh"):   # claude-code: npx @anthropic-ai/claude-code
                continue
            args = []
            for u in toks[i + 1:]:
                if u in SEP or u.rsplit("/", 1)[-1] in ("claude", "claude-code", "escalate.sh"):
                    break
                args.append(u)
            if name == "escalate.sh":   # any word naming it, run or not: a worker steers it through its own environment (W7b-CVER-01)
                return "bin/escalate.sh is run by the supervisor, never by a worker profile"
            if not (i == 0 or toks[i - 1] in SEP or toks[i - 1].rsplit("/", 1)[-1] in PREFIX
                      or (i >= 2 and toks[i - 2].rsplit("/", 1)[-1] == "timeout" and re.fullmatch(r"[\d.]+[smhd]?", toks[i - 1]))) \
                    and not any(a.split("=", 1)[0] in RUN for a in args):
                continue   # a word, not a run: `which claude`, `grep -rn claude docs`
            r = why(args)
            if r:
                return r
    return None


PAY = sys.stdin.read()
try:
    p = json.loads(PAY)
    PROFILE = p.get("profile")
    a = p.get("tool_input") or {}
    reason = check(str((a.get("data") if p.get("tool_name") == "process_manage" else a.get("command")) or ""))
except Exception as e:  # fail closed: a payload we cannot read is refused
    reason = f"unreadable payload: {type(e).__name__}"
if reason is None:
    sys.exit(0)

def coded(problem):   # B.1 (r5): the one way a hook refuses (bin/roles.py hook_refusal): the catalog code, one alert line per call naming the role
    try:
        sys.path.insert(0, "/workspace/bin")
        import roles
        return roles.hook_refusal("STL-GRD-604", problem, PAY)
    except Exception:   # the role module itself is missing: the code and the problem still print
        return f"[STL-GRD-604] {problem}"
try:
    names = "unknown, the resolver cannot be asked" if NOASK else " or ".join(sorted(i for i, ok in catalog_models().items() if ok)) or "none: the resolver lists no usable link of this CLI for the role"
except (Exception, SystemExit):
    names = "unknown, the resolver cannot be asked"
print(json.dumps({"action": "block", "message": f"model guard: {coded('the model guard refused a command its role may not run')} {reason} (F14). Run Claude Code only as `claude -p --model "
                  f"<worker model> ...` (worker model: {names}), never skipping permissions. Every other model goes only through "
                  "/workspace/bin/escalate.sh, run by the supervisor."}))
sys.exit(2)
