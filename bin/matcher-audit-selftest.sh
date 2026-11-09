#!/usr/bin/env bash
# Matcher audit (F9, D46): for each profile in docs/hermes-local/roles.json, every tool its role's toolsets expose (resolved
# by Hermes's own toolsets.py; kanban_* for assignable roles, which the dispatcher adds), whether it can write, and the
# registered pre_tool_call hooks whose matcher fullmatches it (as agent/shell_hooks.py does). Hooks come from
# bin/register-escalation-hook.sh run against a scratch HOME. Fails when a matcher matches no real tool, or a
# write-capable tool has no covering hook and is not in ACCEPTED below. usage: matcher-audit-selftest.sh [--table]
set -u
HERMES_PY="${HERMES_PY:-/home/node/.hermes/tools/python-3.14.9+20261021-linux-x64/bin/python3}"
# A missing runtime is a failure, not a skip (review M1): after a Hermes upgrade the audit must not go quiet.
[ -x "$HERMES_PY" ] && [ -f /home/node/.hermes/hermes-agent/toolsets.py ] || { echo "FAIL Hermes runtime not found ($HERMES_PY): update HERMES_PY here and in the Discord helper library"; echo "selftest FAIL (1)"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H="$T/home/.hermes"
for d in $(python3 -c 'import sys; sys.path.insert(0, "/workspace/bin"); import roles; [print(f) for _, f, _, l in roles.profiles(roles.load(), sys.argv[1]) if l]' "$H"); do
  mkdir -p "$d"; printf 'model: x\n' > "$d/config.yaml"; done
HOME="$T/home" /workspace/bin/register-escalation-hook.sh >/dev/null || { echo "FAIL hook registration"; echo "selftest FAIL (1)"; exit 1; }
cd /tmp && "$HERMES_PY" -I - "$H" "${1:-}" <<'PY'
import json, os, re, sys
for k in ("PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV"):
    os.environ.pop(k, None)
sys.path.insert(0, "/home/node/.hermes/hermes-agent")
sys.path.insert(0, "/workspace/bin")
sys._hermes_pin_default_home = True
import hermes_bootstrap  # noqa: F401  (Hermes's own sys.path)
import toolsets
import roles
H, table = sys.argv[1], sys.argv[2] == "--table"
# What a tool can change (the F9 categories); tools absent here are read-only or local to the session.
WRITE = {"write_file": "file write", "patch": "file write", "execute_code": "code execution", "skill_manage": "skill write",
         "memory": "memory write", "terminal": "process", "process_manage": "process", "cronjob_manage": "cron",
         "discord": "outbound message", "delegate_task": "delegation"}
WRITE.update({t: "board write" for t in toolsets.resolve_toolset("kanban")
              if t not in ("kanban_show", "kanban_list", "kanban_attachments")})
# Write-capable tools with no covering hook, each with its reason. A new uncovered write tool fails this test.
ACCEPTED = {   # (role, tool)
    ("dispatcher", "discord"): "the dispatcher's own channel tool: talking on Discord is its job (D34 removed discord_admin)",
    ("dispatcher", "memory"): "ACCEPTED (D42): a deny would stop the dispatcher's memory (MEMORY.md, USER.md); it writes only that profile's memory files, never code or hooks",
    ("builder", "memory"): "ACCEPTED (D42): writes only the profile's memory files; a deny would stop session notes",
}
R = roles.load()
dirs = {n: (f + "/", role) for n, f, role, listed in roles.profiles(R, H) if listed}
known = set(toolsets.BUILTIN_TOOL_NAMES) if hasattr(toolsets, "BUILTIN_TOOL_NAMES") else set()
fails, rows = 0, []
for prof, (d, role) in dirs.items():
    sets = sorted({s for plat in R["roles"][role].get("platform_toolsets", {}).values() for s in plat})
    if R["roles"][role]["assignable"]:
        sets.append("kanban")   # dispatched workers get the kanban tools
    tools = sorted({t for s in sets for t in toolsets.resolve_toolset(s)})
    y = open(f"{d}config.yaml").read()
    hooks = re.findall(r'- matcher: "([^"]*)"\n      command: "([^"]*)"', y)
    for m, c in hooks:
        if not any(re.fullmatch(m, t) for t in tools):
            print(f"FAIL {prof}: matcher {m} ({os.path.basename(c)}) matches none of the profile's tools"); fails += 1
    for t in tools:
        cover = [os.path.basename(c) for m, c in hooks if re.fullmatch(m, t)]
        acc = ACCEPTED.get((role, t), "")
        if t in WRITE and not cover and not acc:
            print(f"FAIL {prof}: {t} ({WRITE[t]}) has no covering hook and is not accepted"); fails += 1
        rows.append(f"| {prof} ({role}) | {t} | {WRITE.get(t, '-')} | {', '.join(cover) or '-'} | {acc or ''} |")
stale = [k for k in ACCEPTED if any(f"({k[0]}) | {k[1]} |" in r and "| - |" not in r for r in rows)]
for k in stale:
    print(f"FAIL {k[0]}: {k[1]} is accepted as uncovered but a hook now covers it: drop it from ACCEPTED"); fails += 1
if table:
    print("| profile (role) | tool | can write | covering hooks (matcher fullmatch) | accepted uncovered |\n|---|---|---|---|---|")
    print("\n".join(rows))
print(f"ok   {len(rows)} profile tools audited; every matcher matches a real tool; every write-capable tool covered or accepted" if not fails else "")
print("selftest PASS" if not fails else f"selftest FAIL ({fails})")
sys.exit(1 if fails else 0)
PY
