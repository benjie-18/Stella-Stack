#!/usr/bin/env bash
# Re-register the escalation shell hooks in every Hermes profile (T16 #escalations):
#   kanban_task_blocked   -> bin/escalation-on-block.sh     (open the card's thread, D25)
#   kanban_task_completed -> bin/escalation-on-complete.sh  (report its completion once, D30)
#   kanban_task_claimed   -> bin/escalation-on-claim.sh     (✨ status reaction when work resumes, D32)
#   pre_tool_call ^kanban_ -> bin/kanban-guard.sh           (wrong board, re-block of an answered decision, D31)
# and the fail-closed guards each profile's role installs (D34, D46): the hooks listed for that role in
# docs/hermes-local/roles.json (dispatcher-only, reviewer read-only, builder write, git, secret and model guards, the
# false-close guard for the worker kinds it names). The profiles come from that table plus the profiles found in ~/.hermes;
# one with no row gets the fallback role, which opens nothing, and an STL-CFG-303 line (exit 1). A broken table registers
# nothing (exit 1). Hook files are restored from the repo by bin/register-toolsets.sh.
# The hook config lives in the ~/.hermes volume, not the repo: run this after a volume reset (bin/apply-hermes-local.sh
# runs it). Idempotent: hooks already present are left unchanged, except a wrong matcher, which is corrected in place;
# existing hook lists are extended, never duplicated. A profile's config.yaml and allowlist are written only when they
# change: backed up first to ~/.hermes/backups/hooks-<UTC time>/, then replaced atomically (F25, S25). A registered hook
# this script does not list is reported as UNLISTED (never removed: remove a stale one by hand).
# usage: register-escalation-hook.sh           register
#        register-escalation-hook.sh --check   change nothing; report missing hooks or approvals (exit 1 if any)
set -euo pipefail
python3 - "${1:-apply}" <<'PY'
import json, os, re, sys, time
check = sys.argv[1] == "--check"
drift = 0
H = os.path.expanduser("~/.hermes")
BK = f"{H}/backups/hooks-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
HOOKS = [("kanban_task_blocked", None, "/workspace/bin/escalation-on-block.sh"),
         ("kanban_task_completed", None, "/workspace/bin/escalation-on-complete.sh"),
         ("kanban_task_claimed", None, "/workspace/bin/escalation-on-claim.sh"),
         ("pre_tool_call", "^kanban_.*", "/workspace/bin/kanban-guard.sh")]
# D46, every profile, fail-closed: role permissions, completion by the card's own run, valid cards only (bin/role-guard.py).
GUARDS = [("pre_tool_call", "^(kanban_create|kanban_complete|kanban_unblock|kanban_claim|kanban_request_review|kanban_comment|delegate_task)$",
           "/workspace/bin/role-guard.py", 30)]
sys.path.insert(0, "/workspace/bin")
import roles
try:
    R = roles.load()
except roles.RolesError as e:   # a broken role table registers nothing: never guess at access (D46)
    print(f"roles: INVALID {e}; no hook registered or checked ({roles.log_alert('STL-CFG-303', problem=str(e)[:300])})")
    sys.exit(1)
for name, folder, role, listed in roles.profiles(R, H):
    cfg = f"{folder}/config.yaml"
    if not os.path.exists(cfg):
        print(f"{name}: no config.yaml, skipped"); continue
    if not listed:   # no row: the fallback role's hooks, which open nothing, and one alert line; never left unguarded
        drift += 1
        print(f"{name}: no row in roles.json, registering role {role} (STL-CFG-303; roles.py check logs the alert)")
    PROFILE = [("pre_tool_call", m, c, t) for m, c, t, _ in roles.hooks_for(R, H, name, folder, role)]
    s = s0 = open(cfg).read()
    al = f"{folder}/shell-hooks-allowlist.json"
    d = json.load(open(al)) if os.path.exists(al) else {"approvals": []}
    d0 = json.dumps(d)
    listed = {h[2] for h in HOOKS + GUARDS + PROFILE}
    for cmd in re.findall(r'\n\s*(?:- )?command: "([^"]*)"', s):
        if cmd not in listed:
            print(f"{name}: UNLISTED hook {cmd} (registered, not in this script; remove it by hand if stale)")
    added = []
    for event, matcher, cmd, timeout, closed in ([h + (10, False) for h in HOOKS]
                                                  + [h + (True,) for h in GUARDS + PROFILE]):
        # Hermes fullmatches the matcher (agent/shell_hooks.py): a registered command with a different matcher is
        # corrected in place, never skipped (D31 matcher fix: "^kanban_" matched no tool).
        old = re.search(r'- matcher: "([^"]*)"\n      command: "' + re.escape(cmd) + '"', s)
        if old and matcher and old.group(1) != matcher:
            if check:
                print(f"{name}: MATCHER DRIFT {cmd}: {old.group(1)} (want {matcher})"); drift += 1
            else:
                s = s[:old.start(1)] + matcher + s[old.end(1):]
                added.append(f"{event} matcher {old.group(1)} -> {matcher}")
        # K1-RT-11: a registered command with another timeout than the table's is corrected the same way
        ot = re.search(r'command: "' + re.escape(cmd) + r'"\n      timeout: (\d+)', s)
        if ot and int(ot.group(1)) != int(timeout):
            if check:
                print(f"{name}: TIMEOUT DRIFT {cmd}: {ot.group(1)} (want {timeout})"); drift += 1
            else:
                s = s[:ot.start(1)] + str(timeout) + s[ot.end(1):]
                added.append(f"{event} timeout {ot.group(1)} -> {timeout}")
        if cmd not in s and check:
            print(f"{name}: MISSING {event} {matcher or ''} {cmd}"); drift += 1
        elif cmd not in s:
            item = (f'    - matcher: "{matcher}"\n      command: "{cmd}"\n      timeout: {timeout}\n' if matcher
                    else f'    - command: "{cmd}"\n      timeout: {timeout}\n') + ("      fail_closed: true\n" if closed else "")
            if "\nhooks:\n" not in s:
                s = s.rstrip("\n") + "\n\n# T16 escalation hooks (bin/register-escalation-hook.sh).\nhooks:\n"
            if f"\n  {event}:\n" in s:          # extend the existing list for this event
                s = s.replace(f"\n  {event}:\n", f"\n  {event}:\n" + item, 1)
            else:
                s = s.replace("\nhooks:\n", f"\nhooks:\n  {event}:\n" + item, 1)
            added.append(event)
        a = {"event": event, "command": cmd}
        if a not in d["approvals"] and check:
            print(f"{name}: NOT APPROVED {event} {cmd}"); drift += 1
        elif a not in d["approvals"]:
            d["approvals"].append(a)
    if check:
        continue
    for path, old, new in ((cfg, s0, s), (al, d0, json.dumps(d))):
        if new == old:
            continue
        if os.path.exists(path):
            os.makedirs(BK, exist_ok=True)
            open(f"{BK}/{name}.{os.path.basename(path)}", "w").write(open(path).read())
        open(path + ".tmp", "w").write(new if path == cfg else json.dumps(d, indent=2) + "\n")
        os.replace(path + ".tmp", path)
    print(f"{name}: {'added ' + ', '.join(added) if added else 'already registered'}")
if check:
    print(f"hooks: {'DRIFT (' + str(drift) + ')' if drift else 'all registered and approved'}")
sys.exit(1 if drift else 0)
PY
