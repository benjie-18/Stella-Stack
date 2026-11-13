#!/usr/bin/env bash
# Apply the repo-managed Hermes local config (D31). Hermes keeps these in the ~/.hermes volume, which survives a rebuild
# but not a volume reset, so the repo is the source of truth and this script re-applies it. Idempotent.
#   SOUL rules: docs/hermes-local/soul/<profile>.md -> a marked region of each profile's SOUL.md. An unmarked SOUL keeps
#     its first line (Hermes's base persona line, or whatever line 1 is) above the region; the rest is replaced once (S24).
#     A changed SOUL.md is backed up to ~/.hermes/backups/apply-<UTC time>/ first and replaced atomically (F25).
#   Board:      docs/hermes-local/board.md -> the description of the board bin/kanban-board.sh names (board.json).
#   Both are rendered with the owner config (D39): {{KEY}} becomes that config/owner.env value, exactly (no sed: values
#     hold backslashes). An unknown placeholder, or one left in a live SOUL, is an error; --check reports it as drift.
#   Roles (D46): docs/hermes-local/roles.json names each profile's role and SOUL file; a SOUL's {{CARD_ASSIGNEES}},
#               {{CARD_PROJECTS}} and {{ROLE_DENIED}} are rendered from that table and the board's projects (projects.db),
#               so --check reports drift when roles change. `roles.py check`: a profile without a row is an error.
#   Hooks:      bin/register-escalation-hook.sh (block, completion, claim, kanban guard, role guard; D25-D32, D46; and the
#               fail-closed guards each role installs, from roles.json; D34-D36).
#   Toolsets:   bin/register-toolsets.sh (per role from roles.json: toolsets, skill denies, hook files, and config keys
#               such as kanban.auto_subscribe_on_create (D29) and auxiliary.background_review.enabled (D46)).
#   Git:        a role's git_identity {name, email} (D48) names two owner config keys; every profile of that role gets
#               user.name, user.email and safe.directory (the stack and the board's project repos) in <profile>/home/.gitconfig,
#               so its worker can commit. Only those keys are managed, through `git config --file`: other lines stay. A differing
#               user.name/email is replaced after a backup (the owner config is the source of truth, as for SOULs); keys the
#               owner has not set are reported, not drift. --check reports a home that differs.
#   Owner:      bin/owner-config.sh --check (config/owner.env, D39), first, in both modes.
# usage: apply-hermes-local.sh           apply everything
#        apply-hermes-local.sh --check   change nothing; report drift (exit 1 if any profile differs)
set -euo pipefail
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
mode="${1:-apply}"
rc=0
/workspace/bin/owner-config.sh --check || rc=1   # D39; in both modes, so container start reports it too
python3 -I - "$mode" <<'PY' || rc=$?
import json, os, re, sys
sys.path.insert(0, "/workspace/bin")
import owner_config
mode = sys.argv[1]
H = os.path.expanduser("~/.hermes"); D = "/workspace/docs/hermes-local/soul"
BK = f"{H}/backups/apply-{__import__('time').strftime('%Y%m%dT%H%M%SZ', __import__('time').gmtime())}"
try:
    cfg = owner_config.load()
except owner_config.OwnerConfigError as e:
    sys.exit(f"owner config: {e}; SOULs and board description not rendered")


import roles
try:
    R = roles.load()
except roles.RolesError as e:
    sys.exit(f"roles: INVALID {e}; nothing applied ({roles.log_alert('STL-CFG-303', problem=str(e)[:300])})")
os.environ.setdefault("PROJECTS_DB", f"{H}/projects.db")   # the binding of this Hermes root (scratch in self-tests)


def render(src, profile=None):
    """The owner config's {{KEY}}s, plus for a SOUL the role values (roles.soul_values, D46): --check reports drift when
    the role table or the board's projects change."""
    text = open(src).read().strip("\n")
    extra = {}
    if profile and re.search(r"\{\{(CARD_|ROLE_|REVIEWERS|BOARD)", text):
        try:
            extra = roles.soul_values(R, profile)
        except Exception as e:
            sys.exit(f"{src}: the role values cannot be rendered ({type(e).__name__}: {e}); SOUL not rendered")
    try:
        return owner_config.render(text, dict(cfg, **extra))
    except owner_config.OwnerConfigError as e:
        sys.exit(f"{src}: {e}")


PROFILES = {n: (f"{pdir}/SOUL.md", R["profiles"][n]["soul"]) for n, pdir, _, listed in roles.profiles(R, H)
            if listed and R["profiles"][n].get("soul")}
drift = 0
for name, (path, soul) in PROFILES.items():
    begin = (f"<!-- stella-rules:begin (managed: edit /workspace/docs/hermes-local/soul/{soul}, "
             "then run /workspace/bin/apply-hermes-local.sh) -->")
    end = "<!-- stella-rules:end -->"
    rules = render(f"{D}/{soul}", name)
    region = f"{begin}\n{rules}\n{end}"
    cur = open(path).read() if os.path.exists(path) else ""
    if begin in cur and end in cur:
        head, rest = cur.split(begin, 1)
        new = head + region + rest.split(end, 1)[1]
    else:
        base = cur.split("\n", 1)[0].strip()   # S24: line 1 is kept, persona line or not
        new = (base + "\n\n" if base else "") + region + "\n"
    if new == cur and "{{" not in cur:
        print(f"{name}: SOUL in sync"); continue
    drift += 1
    if mode == "--check":
        print(f"{name}: SOUL DRIFT (repo rules differ from {path})"); continue
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if cur:
        os.makedirs(BK, exist_ok=True); open(f"{BK}/{name}.SOUL.md", "w").write(cur)
    open(path + ".tmp", "w").write(new); os.replace(path + ".tmp", path)
    print(f"{name}: SOUL updated{' (backup ' + BK + ')' if cur else ''}")
B = f"{H}/kanban/boards/{roles.board()}/board.json"   # K12: the board from bin/kanban-board.sh
board, desc = json.load(open(B)), render("/workspace/docs/hermes-local/board.md")
if board.get("description") == desc:
    print("board: description in sync")
elif mode == "--check":
    drift += 1; print(f"board: description DRIFT (docs/hermes-local/board.md differs from {B})")
else:
    board["description"] = desc
    open(B + ".tmp", "w").write(json.dumps(board, indent=2) + "\n"); os.replace(B + ".tmp", B)
    print("board: description updated")
import subprocess
def gitcfg(f, *a):
    r = subprocess.run(["git", "config", "--file", f, *a], capture_output=True, text=True)
    if r.returncode not in (0, 1):   # 1 = key not set
        sys.exit(f"git config --file {f} {' '.join(a)}: {r.stderr.strip()}")
    return r.stdout.splitlines()
try:
    repos = sorted({roles.ROOT} | {p["repo"] for p in roles.board_projects(roles.board()) if p["repo"]})
except Exception as e:
    repos = [roles.ROOT]; print(f"git: the board's projects cannot be read ({type(e).__name__}: {e}); safe.directory for {roles.ROOT} only")
for name, pdir, role, _ in roles.profiles(R, H):
    gi = R["roles"][role].get("git_identity")
    if not gi:
        continue
    f = f"{pdir}/home/.gitconfig"
    want = {"user.name": owner_config.get(gi["name"]), "user.email": owner_config.get(gi["email"])}
    if not all(want.values()):
        print(f"{name}: git identity NOT SET ({gi['name']} and {gi['email']} are missing in the owner config): nothing written, the home keeps the .gitconfig it has")
        continue
    have = {k: gitcfg(f, "--get-all", k) for k in want} if os.path.exists(f) else {}
    wrong = [k for k, v in want.items() if have.get(k) != [v]]
    unsafe = [r for r in repos if r not in (gitcfg(f, "--get-all", "safe.directory") if os.path.exists(f) else [])]
    if not wrong and not unsafe:
        print(f"{name}: git config in sync"); continue
    drift += 1
    if mode == "--check":
        print(f"{name}: git config DRIFT ({', '.join(wrong + unsafe)} differ in {f})"); continue
    os.makedirs(os.path.dirname(f), exist_ok=True)
    if any(have.get(k) for k in wrong):   # a different identity is replaced, not lost
        os.makedirs(BK, exist_ok=True); open(f"{BK}/{name}.gitconfig", "w").write(open(f).read())
    for k in wrong:
        gitcfg(f, "--replace-all", k, want[k])
    for r in unsafe:
        gitcfg(f, "--add", "safe.directory", r)
    print(f"{name}: git config updated ({', '.join(wrong + ['safe.directory ' + r for r in unsafe])})")
sys.exit(1 if (mode == "--check" and drift) else 0)
PY
ESCALATE_SUP_DIR="${ESCALATE_SUP_DIR:-/workspace/.supervisor}" python3 /workspace/bin/roles.py check "$HOME/.hermes" || rc=1   # D46: every profile has a row
/workspace/bin/register-escalation-hook.sh "$mode" || rc=1
/workspace/bin/register-toolsets.sh "$mode" || rc=1
exit $rc
