#!/usr/bin/env python3
"""Policy layer (F3 item P; body B3, AC2, AC3), stdlib only: the stack rules of .stella/policy.json rendered into each worker CLI's
own permission config through the shapes of .stella/adapters.json. No CLI, path, role or model name is in this file: a new CLI is a
new adapter entry. A shape renders the items of one rule kind through its templates at a JSON pointer of the CLI's config: "list"
appends each rendered string, "map" sets rendered key -> the shape's value. Only the adapter's owned pointers are written or compared.
CLI: policy.py check [--json]          validate the policy and every adapter's policy part (exit 1, STL-GRD-610..612, 614)
     policy.py generate --adapter A [--worktree W] [--out F] [--json]
                                       render A's config for worktree W (default: the adapter's worktree_ref), only the owned
                                       pointers; to F, or stdout. --json: a summary {adapter, file, pointers} (or {adapter, config})
     policy.py generate --all [--write] [--json]   every committed generated file (each adapter's policy.target.file): which differ;
                                       --write rewrites their owned pointers (the rest of each file is kept)
     policy.py drift [--json]          exit 1 and STL-GRD-613 per committed file whose owned pointers differ from a fresh render
     policy.py hook --adapter A [--worktree W]   a pre-tool-call decision on the payload on stdin {tool_name, tool_input, cwd}:
                                       no output = no objection; a refusal is the adapter's deny template (STL-GRD-615 a write
                                       outside the write boundary, 616 a read of a secret or protected path, 617 an unreadable
                                       payload or policy)
Exit: 0 ok; 1 a problem (a catalog code and its plain message); 2 usage."""
import argparse, copy, fnmatch, json, os, re, shlex, sys, tempfile

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import roles, stella_data as sd, worker_env

ROOT = roles.DATA_ROOT   # the tree whose data is read and whose generated files are written
STACK = roles.ROOT    # the stack folder every rendered path names (as the role table's paths do), whichever tree renders


def fail_line(code, problem):
    return roles.plain(code, problem=problem)


def items(kind, p, table, ad, all_ads, worktree):
    """{set name: [vars]} of one rule kind: what an adapter's templates render."""
    r = roles.policy_rule(kind, p)
    if kind == "write_boundary":
        return {"outside": [{}], "writable": [{"path": p} for p in writable(r, worktree)], "config": [{"name": n} for n in config_files(all_ads)]}
    if kind == "protected_read":
        return {"repo": [{"path": x} for x in roles.protected(table)[0]],
                "home": [{"home": x} for x in table["protected"]["home"]],
                "owner": [{"name": os.path.basename(x)} for x in table["owner_settings"]]}
    if kind == "secret_read":
        names, homes = [g for g in r["deny"] if "/" not in g], [g[2:] for g in r["deny"] if g.startswith("~/")]
        return {"name": [{"name": g} for g in names], "home": [{"home": g} for g in homes], "allow": [{"name": g} for g in r["allow"] + r.get("file_allow", [])],
                "file": [{"name": g} for g in r.get("file_deny", [])],   # judged against file paths only (a read config), never a command line
                # for a command line: a name glob that starts a word (prefix), one whose literal end ends a word (suffix: *.key, not .keys()),
                # and the last two parts of a home glob, as the rule's text patterns name them (tail: opencode/auth.json from any folder)
                "prefix": [{"name": g} for g in names if not g.startswith("*")],
                "suffix": [{"name": g} for g in names if g.startswith("*") and "*" not in g[1:] and "?" not in g and "[" not in g],
                "tail": [{"tail": "/".join(g.split("/")[-2:])} for g in homes if "/" in g]}
    if kind == "commit_rule":
        out = {f: [] for f in roles.GIT_FORMS}
        for e in r["deny_git"]:
            (f, v), = ((k, x) for k, x in e.items() if k != "why")
            out[f] += [{"sub": v["sub"], "word": a} for a in v["args"]] if f == "sub_args" else [{"word": v}]
        return out
    if kind == "dispatcher_only":
        kinds = {pr.get("worker") for pr in table["profiles"].values()}
        held = {f for pr in table["profiles"].values() if pr.get("worker") == ad["id"] for f in roles.PERMS if table["roles"].get(pr["role"], {}).get(f)}
        return {"command": [{"command": c} for f, c in r["commands"].items() if f not in held]} if ad["id"] in kinds else {"command": [{"command": c} for c in r["commands"].values()]}
    if kind == "model_limits":
        return {"forbidden": [{"binary": n, "pattern": x} for a in all_ads.values() for n in (a.get(r["forbidden_flags_key"]) or {}).get("names", [])
                              for x in (a.get(r["forbidden_flags_key"]) or {}).get("deny_patterns", [])]}
    raise roles.RolesError(f"no items for rule kind {kind}")


def run_tmp():
    """The run's temporary folder: the TMPDIR the CLI (and so its hook, and the engine that renders its config) runs with."""
    return os.path.realpath(tempfile.gettempdir())


def writable(rule, worktree):
    """The write_boundary rule's writable paths for a run in worktree (none when no worktree is known)."""
    return [fill(w, {"worktree": worktree, "run_tmp": run_tmp()}) for w in rule["writable"]] if worktree else []


def config_files(ads):
    """RT3-07: every adapter's own project config names (globs relative to a project folder): a worker never writes them."""
    return sorted({n for a in ads.values() for n in a.get("config_files", [])})


def config_hit(x, names):
    """The config name a path is, or lies under, at any depth (a CLI reads its project config from the folders above its cwd too)."""
    parts = x.strip("/").split("/")
    return next((n for n in names for i in range(len(parts)) for j in range(i + 1, len(parts) + 1) if fnmatch.fnmatchcase("/".join(parts[i:j]), n)), None)


def fill(t, v):
    """A template (a string, or JSON holding strings) with {name} placeholders filled from v; other braces stay."""
    if isinstance(t, str):
        return re.sub(r"\{(\w+)\}", lambda m: str(v[m[1]]) if m[1] in v else m[0], t)
    if isinstance(t, list):
        return [fill(x, v) for x in t]
    if isinstance(t, dict):
        return {fill(k, v): fill(x, v) for k, x in t.items()}
    return t


def hook_command(ad, worktree):
    cmd = ["python3", "-I", os.path.join(STACK, "bin", "policy.py"), "hook", "--adapter", ad["id"]]
    return shlex.join(cmd) + (f' --worktree "{worktree}"' if worktree and worktree == ad["policy"].get("worktree_ref") else
                              f" --worktree {shlex.quote(worktree)}" if worktree else "")


def render(aid, worktree=None, p=None, table=None, ads=None):
    """{owned pointer: value} of adapter aid for worktree (None: the adapter's worktree_ref, which may be null)."""
    p, table, ads = p or roles.policy(), table or roles.load(), ads or roles.adapters()
    ad = ads[aid]
    pol = ad["policy"]
    wt = worktree if worktree is not None else pol.get("worktree_ref")
    base = {"stack": STACK}
    out = {}
    def put(ptr, form, key, value=None):
        if form == "map":
            out.setdefault(ptr, {})[key] = value
        elif key not in out.setdefault(ptr, []):
            out[ptr].append(key)
    for f in pol.get("fixed", []):
        put(f["pointer"], "map", fill(f["key"], base), f["value"])
    for kind, shapes in pol.get("shapes", {}).items():
        sets = items(kind, p, table, ad, ads, wt)
        for s in shapes:
            for name, temps in s["templates"].items():
                for v in sets.get(name, []):
                    for t in temps:
                        put(s["pointer"], s["form"], fill(t, {**base, **v}), s.get("value"))
    h = pol.get("hook")
    if h:
        matcher = "|".join(n for n, t in ad["tools"].items() if t["class"] != "other")
        out.setdefault(h["pointer"], []).append(fill(h["template"], {"matcher": matcher, "command": hook_command(ad, wt)}))
    for ptr in pol["target"]["owned_pointers"]:
        out.setdefault(ptr, {} if any(s["pointer"] == ptr and s["form"] == "map" for ss in pol.get("shapes", {}).values() for s in ss) else [])
    return out


def _parts(ptr):
    return [x.replace("~1", "/").replace("~0", "~") for x in ptr.lstrip("/").split("/")]


def get(doc, ptr):
    for k in _parts(ptr):
        if not isinstance(doc, dict) or k not in doc:
            return None
        doc = doc[k]
    return doc


def setp(doc, ptr, value):
    ks = _parts(ptr)
    for k in ks[:-1]:
        doc = doc.setdefault(k, {})
    doc[ks[-1]] = value


def merged(doc, rendered):
    doc = copy.deepcopy(doc)
    for ptr, v in rendered.items():
        setp(doc, ptr, v)
    return doc


def problems():
    """[(code, problem)] of the policy data and every adapter's policy part."""
    out = []
    try:
        p, table, ads = roles.policy(), roles.load(), roles.adapters()
    except roles.RolesError as e:
        return [("STL-GRD-610", str(e))]
    for rel, schema in ((".stella/policy.json", "policy"), (".stella/adapters.json", "adapters")):
        try:
            sd.checked(sd.load(rel), rel, schema)
        except Exception as e:
            out.append(("STL-GRD-610", f"{rel} fails its schema: {e}"))
    for where, ws in (("sandbox.writable", p.get("sandbox", {}).get("writable", [])), ("the write_boundary rule", roles.policy_rule("write_boundary", p)["writable"])):
        if not ws or any(not w.startswith(("{worktree}", "{run_tmp}")) for w in ws):
            out.append(("STL-GRD-614", f"{where} names a writable path beyond the worktree and the run tmp: only {{worktree}} and {{run_tmp}} (and paths under them) may be writable"))
    unknown = sorted(set(roles.policy_rule("dispatcher_only", p)["commands"]) - set(roles.PERMS))
    if unknown:
        out.append(("STL-GRD-610", f"the dispatcher_only rule names flags the role table does not have: {', '.join(unknown)}"))
    try:
        tokens = set(worker_env.signals()["token_env"])
    except Exception as e:
        tokens = None
        out.append(("STL-GRD-612", f"the worker signals cannot be read ({type(e).__name__}), so no adapter token variable can be checked"))
    for aid, ad in ads.items():
        pol = ad.get("policy")
        if not pol:
            continue
        if tokens is not None and ad.get("token_env") not in tokens:
            out.append(("STL-GRD-612", f"adapter {aid}: its token_env {ad.get('token_env')!r} is not an owner-auth worker_signals.token_env name, so a CLI run would not count as a worker"))
        hook = pol.get("hook") or {}
        covered = set(hook.get("kinds", []))
        for kind, shapes in pol.get("shapes", {}).items():   # a shape covers its kind only when it renders something for this adapter (V1-11)
            try:
                sets = items(kind, p, table, ad, ads, "/dev/null/wt")
            except Exception:
                continue   # the render check below names it
            own = kind != "model_limits" or (ad.get(roles.policy_rule(kind, p)["forbidden_flags_key"]) or {}).get("deny_patterns")
            if own and any(sets.get(name) and temps for s in shapes for name, temps in s["templates"].items()):
                covered.add(kind)
            else:
                out.append(("STL-GRD-611", f"adapter {aid}: its {kind} shapes render nothing" + (" (it has no model flags of its own)" if not own else "")))
        for kind in roles.POLICY_KINDS:
            if kind not in covered:
                out.append(("STL-GRD-611", f"adapter {aid}: rule kind {kind} has neither a config shape nor the adapter's hook"))
        owned = set(pol["target"]["owned_pointers"])
        for kind, shapes in pol.get("shapes", {}).items():
            for s in shapes:
                if s["pointer"] not in owned:
                    out.append(("STL-GRD-611", f"adapter {aid}: a {kind} shape writes {s['pointer']}, which is not an owned pointer"))
        if hook and hook["pointer"] not in owned:
            out.append(("STL-GRD-611", f"adapter {aid}: its hook writes {hook['pointer']}, which is not an owned pointer"))
        if hook and not any(t["class"] in ("read", "write", "shell") for t in ad.get("tools", {}).values()):
            out.append(("STL-GRD-611", f"adapter {aid}: a hook with no tool map entry to judge"))
        for f in pol.get("fixed", []):
            if f["pointer"] not in owned:
                out.append(("STL-GRD-611", f"adapter {aid}: a fixed entry writes {f['pointer']}, which is not an owned pointer"))
        try:
            render(aid, "/dev/null/wt", p, table, ads)
        except Exception as e:
            out.append(("STL-GRD-611", f"adapter {aid}: its policy part does not render ({type(e).__name__}: {e})"))
    return out


def targets():
    ads = roles.adapters()
    return [(aid, os.path.join(ROOT, ad["policy"]["target"]["file"])) for aid, ad in ads.items() if ad.get("policy", {}).get("target", {}).get("file")]


def read_doc(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def write_doc(path, doc):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def drift():
    out = []
    for aid, path in targets():
        rel = os.path.relpath(path, ROOT)
        try:
            doc = read_doc(path)
        except (OSError, ValueError) as e:
            out.append({"adapter": aid, "file": rel, "pointers": [], "problem": f"{rel} cannot be read ({type(e).__name__})"})
            continue
        r = render(aid)
        bad = [ptr for ptr, v in r.items() if get(doc, ptr) != v]
        if bad:
            out.append({"adapter": aid, "file": rel, "pointers": bad, "problem": f"{rel}: {', '.join(bad)} differ from the policy render (a hand edit, or the policy changed: run policy.py generate --all --write)"})
    return out


# --- hook: the same rules, judged on one tool call
def _within(p, d):
    return p == d or p.startswith(d.rstrip("/") + "/")


# Shell grammar the hook reads a command line with (bash words, not stack data): what a command writes.
SEP = {"&&", "||", ";", "|", "&", "|&", ";;", "(", ")"}
REDIRECT = {">", ">>", ">|", "&>", "&>>", "<>", ">&"}
WRAPPERS = {"sudo", "doas", "env", "nohup", "time", "command", "exec", "builtin", "nice", "ionice", "stdbuf", "setsid", "timeout", "xargs", "chroot",
            "export", "declare", "local", "readonly", "typeset", "if", "elif", "then", "else", "while", "until", "do", "!", "{", "}"}
WRITE_ALL = {"tee", "touch", "mkdir", "rm", "rmdir", "unlink", "truncate", "shred", "chmod", "chown", "chgrp", "mkfifo", "mknod"}   # every operand is written
WRITE_LAST = {"cp", "mv", "install", "ln", "rsync", "scp"}   # the last operand is written
TARGET_OPTS = {"-t", "--target-directory", "-C", "--directory", "--git-dir", "--work-tree"}   # an option whose value is a folder written in (cp -t, git -C, tar -C, make -C)
IN_PLACE = {"sed", "perl"}   # with -i every operand is written
ASSIGN = re.compile(r"([A-Za-z_]\w*)=(.*)", re.S)


def _views(cmd, depth=0):
    """The token lists of a command line and of every quoted command line in it (bash -c '...'), an unquoted newline read as ';'.
    Raises ValueError when the top line cannot be read (the caller refuses); a nested string that cannot be read is no command."""
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.commenters = ""   # a # inside a word is text; a real comment only adds words, so a write it hides is still judged (fail closed)
    lex.whitespace_split = True
    toks, line = [], lex.lineno
    while (t := lex.get_token()) is not None:
        if lex.lineno - line > t.count("\n") and toks:
            toks.append(";")
        line = lex.lineno
        toks.append(t)
    yield toks
    for t in toks:
        if depth < 3 and re.search(r"\s", t):
            try:
                yield from _views(t, depth + 1)
            except ValueError:
                pass


def _resolve(w, here, names, text):
    """(real paths, unresolved) of a shell word in folder here: unresolved when it uses a variable the command may set other than by
    NAME=value (read, for, ...), a relative path in an unknown folder, or anything only the shell can compute."""
    bare = re.sub(r"\$\{?[A-Za-z_]\w*\}?", "", text)
    for v in re.findall(r"\$\{?([A-Za-z_]\w*)", w) + (["HOME"] if w.startswith("~") else []):
        if v not in names and re.search(rf"\b{v}\b", bare):
            return [], True
    if here is None and not w.startswith(("/", "~", "$")):
        return [], True
    return roles.expand_word(w, here or "/", names)


def _shell(cmd, cwd):
    """(writes, reads) of a command line: the words it writes to and every word it names, each (word, folder, names)."""
    writes, reads = [], []
    for toks in _views(cmd):
        here, names = cwd, {}
        segs, seg = [], []
        for t in toks + [";"]:
            if t in SEP:
                segs.append(seg)
                seg = []
            else:
                seg.append(t)
        for seg in segs:
            words, skip = [], False
            for i, t in enumerate(seg):   # redirections: the word after > is written, after >& unless it is a file descriptor
                if skip:
                    skip = False
                    continue
                if t in REDIRECT or t in ("<", "<<", "<<<"):
                    skip = True
                    if i + 1 < len(seg):
                        reads.append((seg[i + 1], here, dict(names)))
                        if t in REDIRECT and not (t == ">&" and re.fullmatch(r"\d+|-", seg[i + 1])):
                            writes.append((seg[i + 1], here, dict(names)))
                    continue
                words.append(t)
            wrapped = False
            while words:   # NAME=value words, then wrappers (sudo, env, timeout 5, ...) before the command
                m = ASSIGN.fullmatch(words[0])
                if m:
                    names[m[1]] = m[2]
                elif words[0] in WRAPPERS:
                    wrapped = True
                elif not (wrapped and re.fullmatch(r"-.*|[0-9.]+[smhd]?", words[0])):
                    break
                words.pop(0)
            for w in words:
                reads += [(x, here, dict(names)) for x in [w] + w.split("=", 1)[1:]]
            if not words:
                continue
            name, args = words[0].rsplit("/", 1)[-1], words[1:]
            ops = [w for w in args if not w.startswith("-")]
            out = [args[i + 1] for i, w in enumerate(args[:-1]) if w in TARGET_OPTS]
            out += [w.split("=", 1)[1] for w in args if "=" in w and w.split("=", 1)[0] in TARGET_OPTS]
            if name == "dd":
                out += [w[3:] for w in args if w.startswith("of=")]
            if name in WRITE_ALL or (name in IN_PLACE and any(re.fullmatch(r"-[A-Za-z]*i\S*|--in-place\S*", w) for w in args)):
                out += ops
            if name in WRITE_LAST and ops and not any(w in TARGET_OPTS or w.split("=", 1)[0] in TARGET_OPTS for w in args):
                out.append(ops[-1])
            if name == "git" and ops and ops[0] in ("clone", "init"):
                out.append(ops[-1])
            writes += [(w, here, dict(names)) for w in out]
            if name in ("cd", "pushd", "popd"):
                to = ops[0] if ops else "~"
                ps, unres = _resolve(to, here, names, cmd) if name != "popd" and to != "-" else ([], True)
                here = None if unres or not ps else ps[0]
    return writes, reads


def judge(ad, payload, worktree):
    """(code, why) when the call breaks a rule the adapter's hook enforces, else None."""
    p, table = roles.policy(), roles.load()
    kinds = set(ad["policy"]["hook"]["kinds"])
    spec = ad["tools"].get(payload.get("tool_name"))
    if not spec or spec["class"] == "other":
        return None
    a = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    homes = roles.homes()
    s = roles.policy_rule("secret_read", p)
    wb = roles.policy_rule("write_boundary", p)
    roots = [os.path.realpath(w) for w in writable(wb, worktree)]
    cfg = config_files(roles.adapters())
    sdirs = [os.path.realpath(d if d.startswith("/") else f"{h}/{d[2:]}") for d in s["dirs"] for h in homes]
    def secret(x, word=False):   # word: a shell word only counts by its file name when that file exists (process.env.HOME is no file)
        b = os.path.basename(x).casefold()
        if any(fnmatch.fnmatch(b, g) for g in s["allow"] + s.get("file_allow", [])):
            return False
        return ((any(fnmatch.fnmatch(b, g) for g in s["deny"] + s.get("file_deny", []) if "/" not in g) and (not word or os.path.lexists(x)))
                or any(fnmatch.fnmatch(x, f"{h}/{g[2:]}") or _within(x, f"{h}/{g[2:]}") for h in homes for g in s["deny"] if g.startswith("~/")))
    def protected(x):
        repo, home = roles.protected(table)
        owners = [os.path.realpath(o) for o in roles.owner_settings(table)]
        return (any(_within(x, os.path.realpath(d)) for d in repo + home + [os.path.dirname(o) for o in owners]) or x in owners) \
            and not (worktree and _within(x, os.path.realpath(worktree)))
    def outside(x, raw, here):
        if any(fnmatch.fnmatch(os.path.normpath(os.path.join(here or "/", raw)), d) for d in wb.get("devices", [])):
            return False
        return not any(_within(x, r) for r in roots)
    if spec["class"] == "shell":
        cmd = str(get(a, spec["command"]) or "")
        text = re.compile("|".join(s["text"]))
        for w in re.findall(r"[^\s'\"\x60;|&<>(){}=,]+", cmd):   # a word that names a secret, unless its file name is an allowed one
            if "secret_read" in kinds and text.search(w) and not any(fnmatch.fnmatch(w.rsplit("/", 1)[-1].casefold(), g) for g in s["allow"]):
                return "STL-GRD-616", f"the command names a secret path ({w})"
        try:
            writes, reads = _shell(roles.ansi(cmd), cwd)
        except ValueError:
            return "STL-GRD-617", "the command line cannot be parsed, so its paths cannot be judged"
        if "write_boundary" in kinds:
            for w, here, names in writes:
                if not worktree:
                    return "STL-GRD-615", "no worktree is known for this run, so no write is inside it"
                ps, unres = _resolve(w, here, names, cmd)
                if unres or not ps:
                    return "STL-GRD-615", f"the command writes to {w}, which cannot be resolved before it runs"
                bad = next((x for x in ps if outside(x, w, here)), None)
                if bad:
                    return "STL-GRD-615", f"the command writes to {w} ({bad}), outside the worktree and the run tmp"
                hit = next((n for x in ps if (n := config_hit(x, cfg))), None)
                if hit:
                    return "STL-GRD-615", f"the command writes to {w}, a CLI's own config ({hit}), which would override the generated policy"
        for w, here, names in reads:
            for x in _resolve(w, here, names, cmd)[0]:
                if "secret_read" in kinds and secret(x, True):
                    return "STL-GRD-616", f"the command names a secret path ({w})"
                if "protected_read" in kinds and protected(x):
                    return "STL-GRD-616", f"the command names a protected path ({w})"
        return None
    raw = get(a, spec["path"]) or ("." if spec["class"] == "read" else None)   # a search with no path searches the current folder
    if not raw:
        return None
    x = os.path.realpath(os.path.join(cwd, os.path.expanduser(str(raw))))
    if "secret_read" in kinds and secret(x):
        return "STL-GRD-616", f"{raw} is a secret path"
    if "secret_read" in kinds and spec["class"] == "read" and os.path.isdir(x) and any(_within(x, d) or _within(d, x) for d in sdirs):
        return "STL-GRD-616", f"a search over {raw} enters a secret folder"
    if "protected_read" in kinds and protected(x):
        return "STL-GRD-616", f"{raw} is a protected path"
    if spec["class"] == "write" and "write_boundary" in kinds:
        if not worktree:
            return "STL-GRD-615", "no worktree is known for this run, so no write is inside it"
        if outside(x, str(raw), cwd):
            return "STL-GRD-615", f"{raw} is outside the worktree {worktree} and the run tmp"
        if config_hit(x, cfg):
            return "STL-GRD-615", f"{raw} is a CLI's own config ({config_hit(x, cfg)}), which would override the generated policy"
    return None


def hook(aid, worktree):
    raw = sys.stdin.read()
    try:
        ad = roles.adapters()[aid]
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise ValueError("not an object")
        got = judge(ad, payload, worktree)
    except Exception as e:   # fail closed: an unreadable payload, policy or adapter refuses the call
        ad = ad if "ad" in locals() else None
        got = ("STL-GRD-617", f"the policy check cannot judge this call ({type(e).__name__})")
    if not got:
        return 0
    code, why = got
    msg = f"{fail_line(code, why)} {why}"
    if not ad:
        print(msg, file=sys.stderr)
        return 2
    print(json.dumps(fill(ad["policy"]["hook"]["deny"], {"reason": msg})))
    return ad["policy"]["hook"].get("deny_exit", 2)


def main(argv):
    ap = argparse.ArgumentParser(prog="policy.py", add_help=True)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check"); c.add_argument("--json", action="store_true")
    g = sub.add_parser("generate"); g.add_argument("--adapter"); g.add_argument("--all", action="store_true"); g.add_argument("--worktree")
    g.add_argument("--out"); g.add_argument("--write", action="store_true"); g.add_argument("--json", action="store_true")
    d = sub.add_parser("drift"); d.add_argument("--json", action="store_true")
    h = sub.add_parser("hook"); h.add_argument("--adapter", required=True); h.add_argument("--worktree")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    if a.cmd == "hook":
        return hook(a.adapter, a.worktree)
    try:
        if a.cmd == "check":
            probs = problems()
            lines = [f"{fail_line(c, x)} {x}" for c, x in probs]
            print(json.dumps({"ok": not probs, "problems": [{"code": c, "problem": x} for c, x in probs]}) if a.json else "\n".join(lines) or "policy ok")
            return 1 if probs else 0
        if a.cmd == "drift":
            ds = drift()
            for x in ds:
                x["code"] = "STL-GRD-613"
                fail_line("STL-GRD-613", x["problem"])
            print(json.dumps({"ok": not ds, "drift": ds}) if a.json else "\n".join(f"[STL-GRD-613] {x['problem']}" for x in ds) or "no drift")
            return 1 if ds else 0
        if a.all == bool(a.adapter):
            print("usage: policy.py generate --adapter A [--worktree W] [--out F] [--json] | --all [--write] [--json]", file=sys.stderr)
            return 2
        probs = problems()
        if probs:
            print("\n".join(f"{fail_line(c, x)} {x}" for c, x in probs), file=sys.stderr)
            return 1
        if a.all:
            done = []
            for aid, path in targets():
                old = read_doc(path)
                new = merged(old, render(aid))
                if new != old:
                    done.append(os.path.relpath(path, ROOT))
                    if a.write:
                        write_doc(path, new)
            print(json.dumps({"changed": done, "written": a.write}) if a.json else "\n".join(("wrote " if a.write else "differs ") + x for x in done) or "nothing to change")
            return 0
        ads = roles.adapters()
        if a.adapter not in ads or not ads[a.adapter].get("policy"):
            print(fail_line("STL-GRD-618", f"no adapter {a.adapter!r} with a policy part") , file=sys.stderr)
            return 1
        doc = merged({}, render(a.adapter, a.worktree))
        if a.out:
            write_doc(a.out, doc)
            if a.json:
                print(json.dumps({"adapter": a.adapter, "file": a.out, "pointers": list(render(a.adapter, a.worktree))}))
        else:
            print(json.dumps({"adapter": a.adapter, "config": doc} if a.json else doc, indent=None if a.json else 2))
        return 0
    except (roles.RolesError, OSError, ValueError, KeyError) as e:
        print(fail_line("STL-GRD-610", f"the policy or adapter data cannot be used ({type(e).__name__}: {e})"), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
