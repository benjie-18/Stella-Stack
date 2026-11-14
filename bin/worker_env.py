#!/usr/bin/env python3
"""The one answer to "does this process run in a worker environment" (F1c B4, B7), stdlib only. Every owner command (settings, the
apply tool, approvals, owner_auth) and the event writer ask reason(). Signals, any one of which makes a worker: a marker variable of the
role table's worker_markers; an agent token variable, an agent user, a sandbox file or a working folder inside a run worktree folder
(owner-auth policy worker_signals); `roles.py prove` saying this process belongs to a worker's run or that it cannot tell. Fail closed:
data that cannot be read, or a check that cannot run, is a worker ("cannot tell"). No signal name is in this file: all are data.
shortcut: until E1 runs agents as their own OS user in a sandbox, every signal here is one a caller could clear (unset a variable,
leave the folder); the guards' path rules are the first line. Upgrade: E1 makes `users` and `sandbox_files` real.
CLI: worker_env.py [--json]   prints why this is a worker (exit 0), or "not a worker" (exit 1); 2 usage."""
import json, os, pwd, subprocess, sys
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import stella_data as sd

POLICY = "owner-auth"   # the index row (and schema) that holds worker_signals


def _row_path(row_id):
    return next(r["path"] for r in sd.load(sd.INDEX)["files"] if r["id"] == row_id)


def signals():
    """worker_signals of the owner-auth policy, validated. Raises on any problem (callers fail closed)."""
    rel = _row_path(POLICY)
    return sd.checked(sd.load(rel), rel, POLICY)["worker_signals"]


def _inside(p, d):
    return p == d or p.startswith(d.rstrip(os.sep) + os.sep)


def reason(env=None, cwd=None):
    """None when this process is not a worker environment, else a plain reason."""
    env = os.environ if env is None else env
    try:
        marks = sd.load(sd.load(sd.INDEX)["role_table"])["worker_markers"]
        assert isinstance(marks, list) and marks and all(isinstance(m, str) and m for m in marks)
    except Exception:
        return "the list of worker markers is not available, so it cannot be told that this is not a worker"
    if any(env.get(m) for m in marks):
        return "a worker marker is set"
    try:
        sig = signals()
    except Exception:
        return "the worker signals of the owner-auth policy cannot be read, so it cannot be told that this is not a worker"
    if any(env.get(v) for v in sig["token_env"]):
        return "an agent token is present"
    try:
        user = pwd.getpwuid(os.geteuid()).pw_name
    except KeyError:
        return "this process runs as a user with no name, so it cannot be told that this is not a worker"
    if user in sig["users"]:
        return "this process runs as an agent user"
    if any(os.path.lexists(p) for p in sig["sandbox_files"]):
        return "this process runs in the agent sandbox"
    try:
        here = os.path.realpath(cwd or os.getcwd())
    except OSError:
        return "the working folder cannot be read, so it cannot be told that this is not a worker"
    for d in sig["worktree_dirs"]:
        base = os.path.realpath(os.path.join(sd.ROOT, d))
        if _inside(here, base) and here != base:
            return "this process runs inside a run worktree"
    try:   # exit 1 + "not proven" = no worker run; 0 = a worker; anything else (3, a crash) = cannot tell
        r = subprocess.run([sys.executable, "-I", os.path.join(BIN, "roles.py"), "prove"], capture_output=True, text=True, timeout=60)
    except Exception:
        return "it could not be proven that this process is not a worker"
    if r.returncode == 0:
        return "this process belongs to a worker's run"
    return None if r.returncode == 1 and "roles: not proven" in r.stderr else "it could not be proven that this process is not a worker"


def main(argv):
    if argv not in ([], ["--json"]):
        print("usage: worker_env.py [--json]", file=sys.stderr)
        return 2
    why = reason()
    if argv:
        print(json.dumps({"worker": why is not None, "reason": why}))
    else:
        print(why or "not a worker")
    return 0 if why else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
