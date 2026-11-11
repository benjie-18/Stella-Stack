"""Role table reader (D46), stdlib only: the one parser of ${ROLES_FILE:-/workspace/docs/hermes-local/roles.json}.
Guards and apply scripts ask it for a profile's role and permissions, the hooks and toolsets each profile gets, the shared
protected-path list, the calling process's ancestry (lineage: how the guard proves a worker's run) and the board-to-project
binding. None of them names a profile. A role may carry git_identity {name, email}: the owner config keys (D48) whose
values the role's worker profiles commit as (bin/apply-hermes-local.sh writes them into each profile's home).

CLI: roles.py check [hermes-root]     validate the table and its coverage of the profiles in hermes-root; exit 1 on any gap
     roles.py spec [hermes-root]      JSON {profile: {dir, role, listed, platform_toolsets, skills_disabled, hook_files,
                                       config}} for bin/register-toolsets.sh and bin/apply-hermes-local.sh
     roles.py field <profile> <key>   one permission of the profile's role, as JSON (unlisted profiles get fallback_role)
     roles.py requirements <role>     JSON {tool_calling, min_context_tokens, vision, allowed_data_classes}: what a model needs
                                       to hold the role (exit 1, nothing on stdout, the code and its message on stderr: STL-CFG-311 for a role not in the
                                       table, STL-CFG-303 for a table that fails validation)
     roles.py reviewers               JSON list of the profiles whose role may review (K8)
     roles.py prove [--profile P] [--task T]   the card whose own worker run this process belongs to (prove_card): JSON
                                       {card, workspace, branch} and exit 0; else the failed proof on stderr, exit 1
                                       (exit 3: the board could not be read)
"""
import json, os, pwd, re, sqlite3, subprocess, sys

ROOT = "/workspace"   # the stack repo: roles.json, the protected repo paths and the hook sources live here
PERMS = ("assignable", "may_answer_for_owner", "may_complete", "may_unblock", "may_claim", "may_delegate", "may_create_cards", "may_review")
WORKSPACES = ("git-worktree", "read-parent-worktree", "none")
OVERRIDES = ("model", "provider")
NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
KEY = re.compile(r"[A-Z][A-Z0-9_]*")   # an owner config key (config/owner.env)
BACKEND = re.compile(r"[a-z0-9_]+")   # a Hermes terminal.backend name
SANDBOX_KEYS = {"schema_version", "backend", "unboxed_backend", "boxed_profiles", "plugin_dir", "tmp_dir", "home_ro", "hide",
                "sibling_dirs", "canary", "env", "env_unset", "snapshot_keep_hours", "home_protect", "profile_overrides"}
BOX_OWNED_ENV = {"HOME", "TMPDIR", "TMP", "TEMP", "CLAUDE_CONFIG_DIR", "HERMES_KANBAN_WORKSPACE", "HERMES_KANBAN_BRANCH",
                 "PATH", "BASH_ENV", "ENV", "IFS", "SHELL"}   # set by the box itself, or able to run code before the command
BOX_SHELL_ENV = {"BASH_ENV", "ENV", "PATH", "IFS", "SHELLOPTS", "BASHOPTS", "PROMPT_COMMAND", "GIT_DIR", "GIT_WORK_TREE", "REVIEW_PROMPT_FILE", "REVIEW_MODEL", "REVIEW_EXPORT_DIR", "REVIEW_SENT_FILE"}   # a broker secret is a token, never one of these
BOX_DENY_ENV_PREFIX = ("LD_", "PYTHON")   # dynamic loader and interpreter start-up variables
REVIEW_INT_KEYS = ("review_max_files", "review_max_mb", "review_clip_body", "review_clip_evidence", "review_clip_answers", "review_commits", "review_export_keep_hours")
OVERRIDE_KEYS = {"claude_config_dir", "ro_over", "hide_files", "broker_env", "broker_when", "review_prompt", "review_model", "review_answer_prefix", "review_link_allow"} | set(REVIEW_INT_KEYS)
REQ_BOOLS = ("tool_calling", "vision")
REQ_KEYS = set(REQ_BOOLS) | {"min_context_tokens", "allowed_data_classes"}
MAX_TOKENS = 2**53 - 1   # the largest integer every JSON reader (a double) holds exactly
SCHEMA_VERSION = 1
ROOT_PROFILE = "default"   # Hermes's own name for the profile that lives in the root of ~/.hermes


class RolesError(Exception):
    pass


def path():
    return os.environ.get("ROLES_FILE") or f"{ROOT}/docs/hermes-local/roles.json"


def _pairs(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise ValueError(f"a key is repeated: {k!r}")   # json would keep the last copy, so a reader of the first is shown another table
        d[k] = v
    return d


def _int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _set(v):
    """A list the code treats as a set: no repeated entry."""
    return isinstance(v, list) and all(isinstance(x, str) for x in v) and len(set(v)) == len(v)


def load():
    try:
        d = json.load(open(path(), encoding="utf-8"), object_pairs_hook=_pairs)
    except Exception as e:
        raise RolesError(f"{path()}: {type(e).__name__}: {e}")
    errs = validate(d)
    if errs:
        raise RolesError(f"{path()}: " + "; ".join(errs))
    return d


def validate(d):
    """Problems with the table, as a list of strings (empty = valid)."""
    roles, profs = d.get("roles") if isinstance(d, dict) else None, d.get("profiles") if isinstance(d, dict) else None
    if not isinstance(roles, dict) or not isinstance(profs, dict) or not roles:
        return ["profiles and roles must be objects, roles not empty"]
    errs = [] if _int(d.get("schema_version")) and d["schema_version"] == SCHEMA_VERSION else [f"schema_version must be {SCHEMA_VERSION}"]
    for n, r in roles.items():
        if not NAME.fullmatch(n) or not isinstance(r, dict):
            errs.append(f"role {n!r}: bad name or not an object"); continue
        errs += validate_requirements(n, r.get("requirements"))
        errs += [f"role {n}: {k} must be true or false" for k in PERMS if not isinstance(r.get(k), bool)]
        if r.get("workspace") not in WORKSPACES:
            errs.append(f"role {n}: workspace must be one of {', '.join(WORKSPACES)}")
        ov = r.get("allowed_overrides")
        if not isinstance(ov, list) or not set(ov) <= set(OVERRIDES) or len(set(ov)) != len(ov):
            errs.append(f"role {n}: allowed_overrides must be a list of {', '.join(OVERRIDES)}, each once")
        if "background_review" in r and not isinstance(r["background_review"], bool):
            errs.append(f"role {n}: background_review must be true or false")
        cm = r.get("complete_metadata")   # S3A-03: the metadata pairs a reviewing role's kanban_complete must carry
        if "complete_metadata" in r and not (isinstance(cm, dict) and cm and all(isinstance(k, str) and k and isinstance(v, str) and v
                                                                      for k, v in cm.items())):
            errs.append(f"role {n}: complete_metadata must be a non-empty object of text pairs")
        if "complete_needs_review" in r and not isinstance(r["complete_needs_review"], bool):   # S3A-04
            errs.append(f"role {n}: complete_needs_review must be true or false")
        workers = r.get("workers", [])
        if not _set(workers) or not all(workers):
            errs.append(f"role {n}: workers must be a list of worker kinds, each once")
        sd_, pt = r.get("skills_disabled", []), r.get("platform_toolsets", {})
        if not _set(sd_) or not isinstance(pt, dict) or not all(_set(v) for v in pt.values()):
            errs.append(f"role {n}: skills_disabled and each platform_toolsets entry must be a list of names, each once")
        if not isinstance(r.get("config", {}), dict):
            errs.append(f"role {n}: config must be an object")
        gi = r.get("git_identity")
        if gi is not None and not (isinstance(gi, dict) and set(gi) == {"name", "email"}
                                   and all(isinstance(v, str) and KEY.fullmatch(v) for v in gi.values())):
            errs.append(f"role {n}: git_identity must be {{name, email}}, each the name of an owner config key")
        for h in r.get("hooks", []):
            if not isinstance(h, dict) or not isinstance(h.get("matcher"), str) or ("file" in h) == ("command" in h):
                errs.append(f"role {n}: a hook needs a matcher and exactly one of file, command"); continue
            try:
                re.compile(h["matcher"])
            except re.error:
                errs.append(f"role {n}: matcher {h['matcher']} is not a regex")
            src = h.get("file") or h["command"]
            if ".." in src.split("/") or not os.path.isfile(src if "command" in h else f"{ROOT}/{src}"):
                errs.append(f"role {n}: hook {src} does not exist")
            if not set(h.get("workers", [])) <= set(workers):
                errs.append(f"role {n}: hook {src} names a worker kind the role does not list")
    fb = roles.get(d.get("fallback_role"))
    if not isinstance(fb, dict):
        errs.append("fallback_role must name a role")
    elif any(fb.get(k) for k in PERMS) or fb.get("workspace") != "none" or fb.get("allowed_overrides"):
        errs.append("fallback_role must open nothing: every may_* and assignable false, workspace none, no overrides")
    elif not errs:
        errs += fallback_problems(d)
    for p, row in profs.items():
        if not NAME.fullmatch(p) or not isinstance(row, dict):
            errs.append(f"profile {p!r}: bad name or not an object"); continue
        if row.get("role") not in roles:
            errs.append(f"profile {p}: role {row.get('role')!r} is not in roles"); continue
        if "worker" in row and row["worker"] not in roles[row["role"]].get("workers", []):
            errs.append(f"profile {p}: worker {row['worker']!r} is not one of its role's workers")
        if ".." in str(row.get("dir", "")).split("/") or str(row.get("dir", "")).startswith("/"):
            errs.append(f"profile {p}: dir must be relative to ~/.hermes")
        ae = row.get("approval_evidence")   # D100: complete-gate refuses this profile's completion without this evidence in its session
        if ae is not None:
            ok_ae = isinstance(ae, dict) and set(ae) <= {"tool", "command", "output", "exit_code", "hint", "chain_max"} \
                and all(isinstance(ae.get(k), str) and ae[k] for k in ("tool", "command", "output")) \
                and isinstance(ae.get("exit_code", 0), int) and isinstance(ae.get("hint", ""), str) \
                and isinstance(ae.get("chain_max"), int) and not isinstance(ae.get("chain_max"), bool) and 0 < ae["chain_max"] <= 1000
            if ok_ae:
                try: re.compile(ae["command"]); re.compile(ae["output"])
                except re.error: ok_ae = False
            if not ok_ae:
                errs.append(f"profile {p}: approval_evidence must be {{tool, command, output, chain_max[, exit_code, hint]}} with regexes that compile (hint is optional text, chain_max a positive integer)")
        rc = row.get("review_callers")   # D101: the roles that may name this profile for a card review or assign a card to it
        if rc is not None and not (isinstance(rc, list) and rc and all(isinstance(x, str) and (x in roles or x == "card") for x in rc)):
            errs.append(f"profile {p}: review_callers must be a non-empty list of role names (and \"card\": the card's own Review-by line)")
        fbp = row.get("capability_fallback")   # B2V-08: the escalation thread suggests it; it must be a real peer
        if fbp is not None and (not isinstance(fbp, str) or fbp == p or not isinstance(profs.get(fbp), dict)
                                or profs[fbp].get("role") != row["role"]):   # RT10-01: a list or object is named, not a crash
            errs.append(f"profile {p}: capability_fallback must name another profile of the same role")
    pr = d.get("protected")
    if not isinstance(pr, dict) or not all(_set(pr.get(k)) and pr[k] for k in ("repo", "home")):
        errs.append("protected needs non-empty repo and home lists, no entry twice")
    os_ = d.get("owner_settings")   # K6: the owner's settings files, refused to every agent role for reading and writing
    if not (isinstance(os_, list) and os_ and _set(os_) and all(x and not x.startswith("/") and ".." not in x.split("/")
                                                   for x in os_)):
        errs.append("owner_settings needs a non-empty list of paths relative to the stack repo, no path twice")
    for k, what in (("owner_data", "paths no role writes (all may read them)"), ("owner_commands", "commands no role runs")):   # F1 W4 (E7)
        v = d.get(k)
        if not (isinstance(v, list) and v and _set(v) and all(_rel(x) for x in v)):
            errs.append(f"{k} needs a non-empty list of {what}, relative to the stack repo, no . or .. segment, no path twice")
    wm = d.get("worker_markers")   # the environment variables that mark a worker's process (commit guard, apply tool, settings tool)
    if not (isinstance(wm, list) and wm and _set(wm) and all(KEY.fullmatch(x) for x in wm)):
        errs.append("worker_markers needs a non-empty list of environment variable names (A-Z, digits, _), no name twice")
    return errs + validate_sandbox(d)


def _hooks(r):
    return {(h["matcher"], h.get("file"), h.get("command")) for h in r.get("hooks", [])}


def fallback_problems(d):
    """The fallback is the narrowest row: it allows no data class another role lacks, has hooks, and every role no profile
    names (so a profile never reaches it by a row) carries at least its hooks. Run on a table whose rows are already well formed."""
    roles, fbn = d["roles"], d["fallback_role"]
    fb, named = roles[fbn], {row.get("role") for row in d["profiles"].values() if isinstance(row, dict)}
    errs = [f"fallback_role {fbn} allows data class {c!r}, which role {n} does not (the fallback is the narrowest)"
            for c in fb["requirements"]["allowed_data_classes"]
            for n in [next((n for n, r in roles.items() if c not in r["requirements"]["allowed_data_classes"]), None)] if n]
    if not _hooks(fb):
        errs.append(f"fallback_role {fbn} must have at least one hook")
    errs += [f"role {n} is named by no profile and lacks a hook the fallback role {fbn} has" for n, r in roles.items()
             if n != fbn and n not in named and not _hooks(fb) <= _hooks(r)]
    return errs


def validate_requirements(n, q):
    """E3: what a model needs to hold role n: all four keys, nothing else."""
    if not isinstance(q, dict):
        return [f"role {n}: requirements must be an object"]
    errs = [f"role {n}: requirements has unknown key {k}" for k in sorted(set(q) - REQ_KEYS)]
    errs += [f"role {n}: requirements.{k} must be true or false" for k in REQ_BOOLS if not isinstance(q.get(k), bool)]
    c, dc = q.get("min_context_tokens"), q.get("allowed_data_classes")
    if not _int(c) or not 0 <= c <= MAX_TOKENS:
        errs.append(f"role {n}: requirements.min_context_tokens must be an integer from 0 to {MAX_TOKENS}")
    if not (isinstance(dc, list) and all(isinstance(x, str) and NAME.fullmatch(x) for x in dc) and len(set(dc)) == len(dc)):
        errs.append(f"role {n}: requirements.allowed_data_classes must be a list of distinct class names")
    return errs


def _rel(x):
    return isinstance(x, str) and bool(x) and not x.startswith("/") and all(seg not in ("", ".", "..") for seg in x.split("/"))   # a . or empty segment aliases another path


def validate_sandbox(d):
    """Problems with the optional `sandbox` block (option A, the OS box), as validate(); no block = no problems."""
    sb = d.get("sandbox")
    if sb is None:
        return []
    if not isinstance(sb, dict):
        return ["sandbox must be an object"]
    errs = [f"sandbox: unknown key {k!r}" for k in sb if k not in SANDBOX_KEYS]
    if not _int(sb.get("schema_version")) or sb["schema_version"] != 1:
        errs.append("sandbox: schema_version must be 1")
    names = [sb.get(k) for k in ("backend", "unboxed_backend")]
    if not all(isinstance(n, str) and BACKEND.fullmatch(n) for n in names) or names[0] == names[1]:
        errs.append("sandbox: backend and unboxed_backend must be different names matching [a-z0-9_]+")
    bp, profs = sb.get("boxed_profiles"), d.get("profiles", {})
    if not isinstance(bp, list) or not all(isinstance(p, str) and p for p in bp):   # a name without a row is a coverage gap (roles.py check), not a table error
        errs.append("sandbox: boxed_profiles must be a list of profile names")
    t = sb.get("tmp_dir")
    if not (isinstance(t, str) and t.startswith("{profile_dir}/") and _rel(t[len("{profile_dir}/"):])):
        errs.append("sandbox: tmp_dir must be a path template starting with {profile_dir}/ and no ..")
    hp = sb.get("home_protect", [])   # profile-home entries bound read-only in the box (a trailing / marks a folder)
    if not (isinstance(hp, list) and all(isinstance(x, str) and _rel(x.rstrip("/")) for x in hp)):
        errs.append("sandbox: home_protect must be a list of relative paths without . or ..")
    for k in ("home_ro", "hide"):
        if not (isinstance(sb.get(k), list) and all(_rel(x) for x in sb[k])):
            errs.append(f"sandbox: {k} must be a list of relative paths without ..")
    sk = sb.get("snapshot_keep_hours")
    if not (isinstance(sk, int) and not isinstance(sk, bool) and 0 < sk <= 10000):
        errs.append("sandbox: snapshot_keep_hours must be a positive integer (session snapshot files older than this are removed when a session starts)")
    eu = sb.get("env_unset", [])
    if not (isinstance(eu, list) and all(isinstance(x, str) and re.fullmatch(r"[A-Z][A-Z0-9_]*", x) for x in eu)):
        errs.append("sandbox: env_unset must be a list of upper-case variable names the box removes from the parent environment")
    sd = sb.get("sibling_dirs")
    if not (isinstance(sd, list) and all(_rel(x) and "/" not in x for x in sd)):
        errs.append("sandbox: sibling_dirs must be a list of folder names")
    for k in ("canary", "plugin_dir"):
        if not _rel(sb.get(k)):
            errs.append(f"sandbox: {k} must be a relative path without ..")
    ev = sb.get("env", {})   # extra environment for every boxed command (for example a locale that exists in the image)
    if not (isinstance(ev, dict) and all(KEY.fullmatch(k) and k not in BOX_OWNED_ENV and not k.startswith(BOX_DENY_ENV_PREFIX) and isinstance(v, str) and "\0" not in v
                                         for k, v in ev.items())):
        errs.append(f"sandbox: env must be an object of string values with upper-case names, none of {', '.join(sorted(BOX_OWNED_ENV))}")
    po = sb.get("profile_overrides")
    if not isinstance(po, dict) or not all(p in profs and isinstance(o, dict) for p, o in po.items()):
        return errs + ["sandbox: profile_overrides must be an object keyed by profiles that have a row"]
    for p, o in po.items():
        errs += [f"sandbox: profile_overrides.{p}: unknown key {k!r}" for k in o if k not in OVERRIDE_KEYS]
        c = o.get("claude_config_dir")
        if c is not None and not (isinstance(c, str) and c.startswith("{home}/") and _rel(c[len("{home}/"):])):
            errs.append(f"sandbox: profile_overrides.{p}.claude_config_dir must start with {{home}}/ and have no ..")
        ro = o.get("ro_over", [])
        if not (isinstance(ro, list) and all(_rel(x) and "/" not in x for x in ro)):
            errs.append(f"sandbox: profile_overrides.{p}.ro_over must be a list of names inside the folder")
        hf = o.get("hide_files", [])
        if not (isinstance(hf, list) and all(isinstance(x, str) and _rel(x) and "/" not in x for x in hf)):
            errs.append(f"sandbox: profile_overrides.{p}.hide_files must be a list of file names inside the folder")
        for k in REVIEW_INT_KEYS:
            v = o.get(k)
            if v is not None and not (isinstance(v, int) and not isinstance(v, bool) and 0 < v <= 1_000_000):
                errs.append(f"sandbox: profile_overrides.{p}.{k} must be a positive integer")
        ap = o.get("review_answer_prefix")
        if ap is not None and not (isinstance(ap, str) and 0 < len(ap) <= 200 and "\n" not in ap):
            errs.append(f"sandbox: profile_overrides.{p}.review_answer_prefix must be a non-empty single-line text")
        la = o.get("review_link_allow", [])
        if not (isinstance(la, list) and all(isinstance(x, str) and x.startswith("/") and x.endswith("/") and ".." not in x.split("/") and len(x) > 1 for x in la)):
            errs.append(f"sandbox: profile_overrides.{p}.review_link_allow must be a list of absolute folders ending in / without ..")
        rm = o.get("review_model")
        if rm is not None and not (isinstance(rm, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,63}", rm)):
            errs.append(f"sandbox: profile_overrides.{p}.review_model must be a model name (letters, digits, . _ : -)")
        rp = o.get("review_prompt")
        if rp is not None and not (isinstance(rp, str) and _rel(rp)):
            errs.append(f"sandbox: profile_overrides.{p}.review_prompt must be a path inside the stack folder, with no ..")
        bw = o.get("broker_when")
        if bw is not None:
            try:
                re.compile(bw)
            except (re.error, TypeError):
                errs.append(f"sandbox: profile_overrides.{p}.broker_when must be a regular expression for the one command that gets the broker's variables")
        be = o.get("broker_env", {})
        if not (isinstance(be, dict) and all(re.fullmatch(r"[A-Z][A-Z0-9_]*", k) and k not in BOX_OWNED_ENV and not k.startswith(BOX_DENY_ENV_PREFIX + ("GIT_",)) and k not in BOX_SHELL_ENV and isinstance(v, str) and re.fullmatch(r"[a-z0-9][a-z0-9_.-]{0,63}", v) and ".." not in v
                                             for k, v in be.items())):
            errs.append(f"sandbox: profile_overrides.{p}.broker_env must map variable names (A-Z0-9_) to broker secret names (a-z0-9_.-)")
    return errs


def sandbox(d):
    """The validated `sandbox` block, or None when the table has none."""
    return d.get("sandbox")


def homes():
    """The real home and $HOME (a profile's subprocesses may get its own HOME)."""
    real = pwd.getpwuid(os.getuid()).pw_dir
    return sorted({real, os.environ.get("HOME") or real})


def owner_settings(d):
    """K6: the owner settings files (absolute), from roles.json; every role's read and write guards refuse them."""
    return [f"{ROOT}/{p}" for p in d["owner_settings"]]


def owner_data(d):
    """F1 W4: the owner's data paths (absolute): no role writes them, every role may read them."""
    return [f"{ROOT}/{p}" for p in d["owner_data"]]


def owner_commands(d):
    """F1 W4: the owner's commands (absolute): no role runs them."""
    return [f"{ROOT}/{p}" for p in d["owner_commands"]]


def worker_markers(d):
    """F1 W4: the environment variable names that mark a worker's process."""
    return list(d["worker_markers"])


def protected(d):
    """(repo paths, home config paths): the one protected list (D40 write guard, D46 card guard)."""
    return ([f"{ROOT}/{p}" for p in d["protected"]["repo"]],
            [f"{h}/{c}" for h in homes() for c in d["protected"]["home"]])


def discovered(H):
    """{profile: dir} of the profiles that exist in a Hermes root (a config.yaml in their folder)."""
    out = {ROOT_PROFILE: H} if os.path.isfile(f"{H}/config.yaml") else {}
    if os.path.isdir(f"{H}/profiles"):
        out.update({p: f"{H}/profiles/{p}" for p in sorted(os.listdir(f"{H}/profiles"))
                    if os.path.isfile(f"{H}/profiles/{p}/config.yaml")})
    return out


def pdir(H, name, row):
    return f"{H}/{row.get('dir', 'profiles/' + name)}".rstrip("/")


def profiles(d, H):
    """[(name, dir, role name, listed)] for every profile with a row or present in H; a missing row = fallback_role."""
    out = {n: (pdir(H, n, row), row["role"], True) for n, row in d["profiles"].items()}
    for n, folder in discovered(H).items():
        if not any(v[0] == folder for v in out.values()):
            out[n] = (folder, d["fallback_role"], False)
    return [(n,) + v for n, v in sorted(out.items())]


def coverage(d, H):
    """Gaps between the table and H: a profile with no row, or a row naming a profile that does not exist."""
    have = set(discovered(H).values())
    gaps = [f"profile {n} has no row in roles.json: it gets role {r} (opens nothing)" for n, _, r, listed in profiles(d, H)
            if not listed]
    gaps += [f"roles.json row {n} names a profile that does not exist ({folder}/config.yaml missing)"
             for n, folder, _, listed in profiles(d, H) if listed and folder not in have]
    gaps += [f"sandbox.boxed_profiles names {n}, which has no row in roles.json: it is NOT boxed"
             for n in (d.get("sandbox") or {}).get("boxed_profiles", []) if n not in d["profiles"]]
    return gaps


def role_of(d, profile):
    """(role name, role, listed) for a profile name from a hook payload; unknown or malformed = fallback_role."""
    row = d["profiles"].get(profile) if isinstance(profile, str) else None
    name = row["role"] if row else d["fallback_role"]
    return name, d["roles"][name], bool(row)


def hook_command(path):
    """The registered command of a hook. A python hook runs as `python3 -I`: it runs unboxed with HOME set to the profile home,
    which a boxed worker can write, so no user-site .pth or PYTHON* variable may reach it (RT-A-01)."""
    return f"python3 -I {path}" if path.endswith(".py") else path

def hooks_for(d, H, name, folder, role):
    """[(matcher, command, timeout, repo source or None)] the profile's role installs, filtered by its worker kind."""
    worker = (d["profiles"].get(name) or {}).get("worker")
    out = []
    for h in d["roles"][role].get("hooks", []):
        if "workers" in h and worker not in h["workers"]:
            continue
        cmd = hook_command(h.get("command") or f"{folder}/hooks/{os.path.basename(h['file'])}")
        out.append((h["matcher"], cmd, int(h.get("timeout", 10)), h.get("file")))
    return out


def spec(d, H):
    out = {}
    for n, folder, role, listed in profiles(d, H):
        r = d["roles"][role]
        cfg = dict(r.get("config", {}))
        if "background_review" in r:
            cfg["auxiliary.background_review.enabled"] = r["background_review"]
        out[n] = {"dir": folder, "role": role, "listed": listed, "platform_toolsets": r.get("platform_toolsets", {}),
                  "hook_files": {f"{folder}/hooks/{os.path.basename(s)}": s for _, _, _, s in hooks_for(d, H, n, folder, role) if s},
                  "config": cfg}
        if "skills_disabled" in r:
            out[n]["skills_disabled"] = r["skills_disabled"]
        sb = d.get("sandbox")
        if sb:   # option A: the backend is per profile (a role's profiles flip one at a time), the plugin files with it
            boxed = n in sb["boxed_profiles"]
            cfg["terminal.backend"] = sb["backend"] if boxed else sb["unboxed_backend"]
            if boxed:
                src = f"{ROOT}/{sb['plugin_dir']}"
                if not os.path.isdir(src):
                    raise RolesError(f"sandbox plugin_dir {sb['plugin_dir']} is not a folder in the stack repo")
                name = os.path.basename(sb["plugin_dir"].rstrip("/"))
                cfg["plugins.isolation"] = "in_process"   # Hermes refuses a user terminal backend under `host`
                out[n]["plugin_enable"] = name
                out[n]["hook_files"].update({f"{folder}/plugins/{name}/{f}": f"{sb['plugin_dir']}/{f}"
                                             for f in sorted(os.listdir(src)) if not f.startswith((".", "__pycache__"))})
    return out


def _stat(pid):
    """Fields of /proc/<pid>/stat after the command name: [0] state, [1] ppid, [19] start time (clock ticks)."""
    s = open(f"/proc/{pid}/stat").read()
    return s[s.rindex(")") + 2:].split()


def fingerprint(pid):
    """Hermes's worker fingerprint "<boot_id>:<pid 1 start>|<start>" (hermes_cli.kanban_db_dispatch._process_fingerprint)
    of a live process, from /proc only; "" when unreadable. A recycled pid or a rebooted container never matches."""
    try:
        return f"{open('/proc/sys/kernel/random/boot_id').read().strip()}:{_stat(1)[19]}|{_stat(pid)[19]}"
    except (OSError, IndexError):
        return ""


def lineage(depth=32):
    """[(pid, fingerprint)] of this process and its ancestors up to pid 1, nearest first, at most depth. Kernel state
    only: no process name, no environment (the agent interpreter a run is bound to sets HERMES_KANBAN_* after it
    started, so its /proc/<pid>/environ does not show them, and Hermes strips them from the hook's own environment)."""
    out, pid = [], os.getpid()
    while pid > 1 and len(out) < depth:
        out.append((pid, fingerprint(pid)))
        try:
            pid = int(_stat(pid)[1])
        except (OSError, IndexError, ValueError):
            break
    return out


def kanban(b, *args):
    """`hermes kanban --board <b> <args> --json`, parsed. Raises when it fails: callers fail closed.
    shortcut: one CLI call is about 0.7 s; read kanban.db read-only if a guard on every tool call gets too slow."""
    # K1 (FAIL-A): the caller's environment never chooses which board database is read: the HERMES_KANBAN_* and
    # delegation pins are dropped and HERMES_HOME is the user's root home (Hermes shares the board across profiles).
    env = {k: v for k, v in os.environ.items() if not k.startswith("HERMES_KANBAN") and k != "HERMES_DELEGATED_CHILD_CONTEXT"}
    env["HERMES_HOME"] = f"{pwd.getpwuid(os.getuid()).pw_dir}/.hermes"
    env["HOME"] = pwd.getpwuid(os.getuid()).pw_dir   # RT-RTA-01: hermes reads pip.conf, ~/.hermes and git config under HOME, which the worker writes
    r = subprocess.run(["hermes", "kanban", "--board", b, *args, "--json"], capture_output=True, text=True, timeout=25,
                       env=env)
    if r.returncode:
        raise RuntimeError(f"hermes kanban {args[0]} failed (exit {r.returncode})")
    return json.loads(r.stdout)


def run_problem(j, lin):
    """None when one of the card's open runs is bound (the worker_bound event Hermes writes before the first model call)
    to a process in lin, this process's ancestry, with the same start time and claim lock; else the first proof that failed."""
    card, ev, why = j["task"]["id"], j.get("events") or [], f"card {j['task']['id']} has no open run"
    for run in (r["id"] for r in j.get("runs") or [] if r.get("ended_at") is None):
        last = lambda kind: next((e["payload"] for e in reversed(ev) if e.get("kind") == kind and e.get("run_id") == run), None)
        bound, claim = last("worker_bound"), last("claimed")
        if not bound or not claim:
            why = f"run {run} has no recorded worker process or claim"
        elif bound.get("claim_lock") != claim.get("lock"):
            why = f"run {run}: the worker's claim lock is not the run's claim lock"
        elif bound.get("pid") not in dict(lin):
            why = f"run {run}: its worker process {bound.get('pid')} is not an ancestor of this call"
        elif not bound.get("started_at") or dict(lin)[bound["pid"]] != bound["started_at"]:   # "" = /proc unreadable
            why = f"run {run}: process {bound['pid']} is not the process bound to the run (start time differs)"
        else:
            return None
    return why


def prove_card(profile=None, task_id="", b=None):
    """The card whose own worker run this process belongs to (D48, K1: the one proof every hook uses), from the board and
    the kernel, never from HERMES_KANBAN_* or anything the model says: the card is assigned to profile (any assignee when
    profile is None) and one of its open runs is bound to a process among this process's ancestors (run_problem). task_id
    names the candidate; without it every running card of the profile (of the board) is tried.
    Returns (card json, None) when proven, else (the last card json read or None, why). A card assigned to another profile
    comes back with its json, so a caller can say so. A board that cannot be read is a failed proof."""
    j, why = None, "no running card is assigned to this profile" if profile else "no running card on the board"
    try:
        b = b or board()
        lin = lineage()
        listing = ["--assignee", str(profile)] if profile else []
        for card in [task_id] if task_id else [t["id"] for t in kanban(b, "list", *listing, "--status", "running")]:
            j = kanban(b, "show", card)
            assignee = (j.get("task") or {}).get("assignee")
            if profile and assignee != profile:
                return j, f"card {card} is assigned to {assignee}"
            why = run_problem(j, lin)
            if not why:
                return j, None
    except Exception as e:   # a proof that cannot be checked is a proof that failed
        why = f"the board cannot be read: {e}"
    return j, why


def board():
    """The stack's one board, bin/kanban-board.sh's KANBAN_BOARD (F4). Never the caller's HERMES_KANBAN_BOARD (K1): a
    guard that runs in a worker's own shell (the commit guard) must not let that shell choose the board it is proven on."""
    m = re.search(r"^KANBAN_BOARD=([A-Za-z0-9_-]+)", open(f"{ROOT}/bin/kanban-board.sh").read(), re.M)
    return m[1] if m else ""


def board_projects(b):
    """[{id, slug, repo}] the projects bound to board b, read-only from Hermes's projects.db (the one binding). Raises
    on any read failure: callers fail closed."""
    db = os.environ.get("PROJECTS_DB") or f"{pwd.getpwuid(os.getuid()).pw_dir}/.hermes/projects.db"
    if not os.path.isfile(db):
        raise RolesError(f"{db} does not exist")
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        rows = c.execute("select id, slug, primary_path from projects where board_slug = ? and coalesce(archived, 0) = 0",
                         (b,)).fetchall()
    finally:
        c.close()
    return [{"id": i, "slug": s, "repo": (p or "").rstrip("/")} for i, s, p in rows]


def reviewers(d, caller_role=None):
    """K8: the profiles whose role may review a card (may_review); a builder's review request names one of them. With caller_role,
    only those the caller's role may name (a profile's review_callers, D101; absent = anyone)."""
    return sorted(p for p, row in d["profiles"].items() if d["roles"][row["role"]].get("may_review")
                  and (caller_role is None or row.get("review_callers") is None or caller_role in row["review_callers"]))


def soul_values(d, profile):
    """{{CARD_ASSIGNEES}}, {{CARD_PROJECTS}}, {{ROLE_DENIED}} for a profile's SOUL, from the table and the board binding,
    so a SOUL never names a profile or project and stays right when roles change. Raises when the binding is unreadable."""
    r = role_of(d, profile)[1]
    denied = [v for k, v in (("may_complete", "complete a card"), ("may_claim", "claim a card"),
                             ("may_unblock", "unblock a card"), ("may_delegate", "delegate to a subagent")) if not r[k]]
    projects = board_projects(board())
    return {"BOARD": board(),   # K12: the board name in a SOUL comes from bin/kanban-board.sh
            "REVIEWERS":", ".join(f"`{p}`" for p in reviewers(d, role_of(d, profile)[0])) or "(no reviewing profile listed)",
            "CARD_ASSIGNEES": ", ".join(f"`{p}`" for p, row in sorted(d["profiles"].items())
                                        if d["roles"][row["role"]]["assignable"]),
            "CARD_PROJECTS": ", ".join(f"`{p['slug']}`" for p in projects) or "(none bound to the board)",
            "ROLE_DENIED": " or ".join(", ".join(denied).rsplit(", ", 1)) or "(nothing denied)"}


def streak(j):
    """A card's last unblock time, "" if never (K11: a run of refusals for one card ends when the card is unblocked)."""
    return str(max((e.get("created_at") or 0 for e in (j or {}).get("events") or [] if e.get("kind") == "unblocked"),
                   default=""))


def log_alert(code, streak="", **kv):
    """One line in .supervisor/logs/alerts.log (bin/alert_catalog.py), and the rendered message's first line. K11: when
    the code's catalog "page" policy says so (once per card per streak, or once an hour), the message also goes to #alerts
    as bin/alert.sh sends it (`hermes send` to $ALERT_TARGET, with the root profile's home, which owns the Discord bot:
    a worker's hook runs with its own profile's); later repeats are logged only."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import alert_catalog
        body, tag, kv2 = alert_catalog.render(code, kv)
        alert_catalog.log(tag, kv2)
        due, f = alert_catalog.page_due(tag, str(kv.get("card") or ""), streak)
        if due:
            env = dict(os.environ, HERMES_HOME=f"{pwd.getpwuid(os.getuid()).pw_dir}/.hermes", HOME=pwd.getpwuid(os.getuid()).pw_dir)   # RT-RTA-01: as kanban()
            r = subprocess.run(["hermes", "send", "--to", os.environ.get("ALERT_TARGET") or "discord:#alerts", "--quiet", body],
                               env=env, capture_output=True, timeout=5)   # shorter than the hook's own timeout; an unsent page is retried
            if r.returncode == 0:
                alert_catalog.mark_paged(f, streak)
        return body.split("\n", 1)[0]
    except Exception as e:   # the alert must never stop the guard or the check that raised it
        return f"{code} ({type(e).__name__})"


def fail(code, **kv):
    """Exit 1 with the alert line logged and the catalog's plain message (not its title) on stderr."""
    tag = log_alert(code, **kv)
    try:
        import alert_catalog
        msg = alert_catalog.render(code, kv)[0].split("\n")[1]
    except Exception:
        msg = tag
    print(f"{code} {msg}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    cmd, args = (sys.argv[1] if len(sys.argv) > 1 else ""), sys.argv[2:]
    if cmd == "prove":   # needs no role table: the board and the kernel only
        o = dict(zip(args[::2], args[1::2]))
        j, why = prove_card(o.get("--profile"), o.get("--task", ""))
        if why:
            print(f"roles: not proven: {why}", file=sys.stderr)
            sys.exit(3 if why.startswith("the board cannot be read") else 1)
        t = j["task"]
        print(json.dumps({"card": t["id"], "workspace": t.get("workspace_path") or "", "branch": t.get("branch_name") or ""}))
        sys.exit(0)
    H = args[0] if args and cmd in ("check", "spec") else os.path.expanduser("~/.hermes")
    try:
        d = load()
    except RolesError as e:
        if cmd == "requirements":   # a JSON read: stdout stays empty; the code, its plain message and one alert line say why
            fail("STL-CFG-303", problem=str(e)[:300])
        print(f"roles: INVALID {e}")
        if cmd == "check":
            print(log_alert("STL-CFG-303", problem=str(e)[:300]))
        sys.exit(1)
    if cmd == "check":
        gaps = coverage(d, H)
        for g in gaps:
            print(f"roles: GAP {g}")
            print(log_alert("STL-CFG-303", problem=g))
        print("roles: table valid, every profile has a row" if not gaps else f"roles: {len(gaps)} gap(s)")
        sys.exit(1 if gaps else 0)
    elif cmd == "spec":
        print(json.dumps(spec(d, H), indent=1))
    elif cmd == "requirements" and len(args) == 1:
        if args[0] not in d["roles"]:
            fail("STL-CFG-311", problem=f"role {args[0][:80]} is not in the role table")
        print(json.dumps(d["roles"][args[0]]["requirements"]))
    elif cmd == "reviewers":
        print(json.dumps(reviewers(d)))
    elif cmd == "field" and len(args) == 2:
        print(json.dumps(role_of(d, args[0])[1].get(args[1])))
    else:
        print(__doc__.split("\n", 1)[1], file=sys.stderr)
        sys.exit(2)
