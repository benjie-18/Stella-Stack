#!/usr/bin/env python3
"""Builder model guard (F14): pre_tool_call on terminal and process_manage for every
profile whose role installs it (docs/hermes-local/roles.json, D46).
Claude Code runs here only as Sonnet: every `claude` that runs a model (-p/--print, or a bare interactive claude) needs
--model sonnet (or claude-sonnet-*), and no claude call may skip permissions (--dangerously-skip-permissions,
--allow-dangerously-skip-permissions, --permission-mode bypassPermissions, --yolo) or fall back to another model.
A bare claude -p is refused because the builder's default model is not Sonnet (~/.claude/settings.json: opus).
Opus and Haiku go only through bin/escalate.sh (allowed; its extra claude args after -- are checked for the
permission flags). Nested quoted command lines are tokenized as git-guard.py does. Exit 2 = block; any error blocks."""
import json, re, shlex, sys

SEP = {"&&", "||", ";", "|", "&"}
SKIP = {"--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--yolo"}
NO_MODEL = {"--version", "-v", "-V", "--help", "-h", "mcp", "doctor", "update", "config", "plugin"}
SONNET = re.compile(r"(claude-)?sonnet\S*")
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


def why(args, escalate=False):
    if SKIP & set(args) or "bypassPermissions" in opt(args, "--permission-mode"):
        return "claude may not skip permissions"
    if escalate:
        return None
    if any(not SONNET.fullmatch(m) for m in opt(args, "--fallback-model")):
        return "claude may fall back only to Sonnet"
    models = opt(args, "--model")
    if any(not SONNET.fullmatch(m) for m in models):
        return f"claude --model {models[0]}: builders run Claude Code only as Sonnet"
    if not models and not (args and args[0] in NO_MODEL):
        return "claude without --model sonnet runs the default model, which is not Sonnet here"
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
            if name == "escalate.sh":
                args = args[args.index("--") + 1:] if "--" in args else []
            elif not (i == 0 or toks[i - 1] in SEP or toks[i - 1].rsplit("/", 1)[-1] in PREFIX
                      or (i >= 2 and toks[i - 2].rsplit("/", 1)[-1] == "timeout" and re.fullmatch(r"[\d.]+[smhd]?", toks[i - 1]))) \
                    and not any(a.split("=", 1)[0] in RUN for a in args):
                continue   # a word, not a run: `which claude`, `grep -rn claude docs`
            r = why(args, name == "escalate.sh")
            if r:
                return r
    return None


PAY = sys.stdin.read()
try:
    p = json.loads(PAY)
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
print(json.dumps({"action": "block", "message": f"model guard: {coded('the model guard refused a command its role may not run')} {reason} (F14). Run Claude Code only as `claude -p --model "
                  "sonnet ...`, never skipping permissions. Opus and Haiku go only through /workspace/bin/escalate.sh, "
                  "run by the supervisor."}))
sys.exit(2)
