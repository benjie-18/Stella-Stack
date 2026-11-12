#!/usr/bin/env python3
"""Model-call watch (K4, readiness run): a worker that keeps its card running while every model call fails (t_14f8f08b,
2026-10-29: 45 minutes of heartbeats, APIConnectionError, nobody told). Run by bin/watchdog.sh.

For each running card on the board: its open run's session (the run's `owner_admitted` event), then that session's lines in
its profile's agent log over the last `window_minutes`: model-call errors (`error_line`) and tool progress
(`progress_line`). `min_errors` or more errors and no progress in the window is a problem. For a problem the model server is
checked from the profile's own config (`hermes config get model` in that profile's home: default model and base_url, never
a name in code): does it answer, which models are loaded (`loaded_models_path` under the server root), is the profile's
model one of them. Settings: the `model_watch` section of docs/hermes-local/watchdog-settings.json.
CLI: model_watch.py   JSON list of {card, profile, errors, minutes, cause, detail} on stdout (cause: a GW-style token for
the catalog's parts table: unreachable, not_loaded, other_loaded, loaded, unknown). A card that cannot be read is
one entry with cause "unknown" and "unchecked": true (the watchdog neither pages nor resolves it); when the board cannot be
read, nothing on stdout and exit 1 (could not check, never an empty "all clear" list)."""
import json, os, re, subprocess, sys, time, urllib.request
from datetime import datetime
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import roles, watchdog_settings   # noqa: E402

TAIL = 8 << 20   # read at most the last 8 MiB of an agent log


def settings():
    return watchdog_settings.load()["model_watch"]


def model_answer(text):
    """(model, base_url) from what `hermes config get model` prints (lines `key: value`, quotes stripped; "" when absent). The one
    reader of that answer: bin/hardcode-lint.sh reads a profile's model and host with it too."""
    c = dict(re.findall(r"^\s*([A-Za-z_]+):\s*(\S.*?)\s*$", text, re.M))
    return c.get("default", "").strip("'\""), c.get("base_url", "").strip("'\"")


def model_config(profile_home):
    """(model, base_url) from `hermes config get model` in the profile's own home; ("", "") when the call fails."""
    r = subprocess.run(["hermes", "config", "get", "model"], capture_output=True, text=True, timeout=30,
                       env=dict(os.environ, HERMES_HOME=profile_home))
    return model_answer(r.stdout) if r.returncode == 0 else ("", "")


def server_cause(cfg, s):
    """(cause token, detail for alerts.log): what the profile's model server says about the profile's model."""
    model, base = cfg
    if not base or not model:
        return "unknown", "the profile's model or base_url is not configured"
    root = re.sub(r"/v1/?$", "", base.rstrip("/"))
    try:
        with urllib.request.urlopen(root + s["loaded_models_path"], timeout=5) as r:
            loaded = [m.get("name") or m.get("model") for m in json.load(r).get("models", [])]
    except Exception as e:
        return "unreachable", f"{root}: {type(e).__name__}"
    if model in loaded:
        return "loaded", f"{model} loaded at {root}"
    return ("other_loaded" if loaded else "not_loaded"), f"{model} not loaded at {root}; loaded: {', '.join(loaded) or 'none'}"


def session_lines(log, session, since, s, tz):
    """[(epoch, line)] of one session's lines in log, newer than since."""
    try:
        with open(os.path.expanduser(log), "rb") as f:
            f.seek(max(0, os.path.getsize(f.name) - TAIL))
            text = f.read().decode("utf-8", "replace")
    except OSError:
        return []
    out = []
    for line in text.splitlines():
        if f"[{session}]" not in line:
            continue
        try:
            t = datetime.strptime(line[:len(time.strftime(s["log_time_format"]))], s["log_time_format"]).replace(tzinfo=tz).timestamp()   # the stamp only, not Hermes's ",mmm"
        except ValueError:
            continue
        if t >= since:
            out.append((t, line))
    return out


def check():
    s, b = settings(), roles.board()
    tz = watchdog_settings.zone(s["log_timezone"])
    d = roles.load()
    homes = {n: pdir for n, pdir, _, _ in roles.profiles(d, os.path.expanduser("~/.hermes"))}
    cards = [c["id"] for c in roles.kanban(b, "list", "--status", "running")]   # unreadable board: raise, never "all clear"
    now, since, problems = time.time(), time.time() - s["window_minutes"] * 60, []
    for card in cards:
        try:
            j = roles.kanban(b, "show", card)
            run = next(r for r in j.get("runs") or [] if r.get("ended_at") is None)
            adm = next(e["payload"] for e in reversed(j.get("events") or [])
                       if e.get("kind") == "owner_admitted" and e.get("run_id") == run["id"])
            profile, pdir = run.get("profile"), homes.get(run.get("profile"))
            lines = session_lines(f"{pdir}/logs/agent.log", adm["session_id"], since, s, tz) if pdir else []
            errors = sum(1 for _, l in lines if re.search(s["error_line"], l))
            progress = any(re.search(s["progress_line"], l) for _, l in lines)
            if errors >= s["min_errors"] and not progress:
                cause, detail = server_cause(model_config(pdir), s)
                problems.append({"card": card, "profile": profile, "errors": errors, "minutes": s["window_minutes"],
                                 "cause": cause, "detail": detail})
        except StopIteration:
            continue   # no open run or no session recorded: nothing to watch
        except Exception as e:
            problems.append({"card": card, "profile": "", "errors": 0, "minutes": s["window_minutes"], "cause": "unknown",
                             "unchecked": True, "detail": f"{type(e).__name__}: {e}"[:200]})   # not a finding: no page, no resolve
    return problems


if __name__ == "__main__":
    try:
        print(json.dumps(check()))
    except Exception as e:   # could not check: nothing on stdout, exit 1, so the watchdog neither pages nor resolves
        print(f"model_watch: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)
