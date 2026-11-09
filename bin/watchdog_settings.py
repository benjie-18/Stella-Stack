#!/usr/bin/env python3
"""Watchdog settings (D47), stdlib only: reads docs/hermes-local/watchdog-settings.json (${WATCHDOG_SETTINGS} in tests).
CLI: watchdog_settings.py --check     validate the file; prints "settings OK" or the problems, exit 1 on any
     watchdog_settings.py gateway     JSON verdict on the gateway: {state, cause, evidence, marker_time}
                                       state: paused | down | active | quiet | unknown
     watchdog_settings.py failures FILE   "check<TAB>first failing line" per failed check in a test run's output
     watchdog_settings.py get KEY     one value (a dotted path, e.g. test_rerun.rerun_command); exit 1 if unreadable
Every path, marker, process name and threshold comes from the file; none is written here."""
import json, os, re, subprocess, sys, time
from datetime import datetime, timezone

BIN = os.path.dirname(os.path.abspath(__file__))
PATH = os.environ.get("WATCHDOG_SETTINGS") or f"{os.path.dirname(BIN)}/docs/hermes-local/watchdog-settings.json"
GATEWAY_KEYS = {"process_match": str, "pause_file": str, "activity_logs": list, "activity_window_minutes": int,
                "connected_marker": str, "disconnected_marker": str, "marker_scan_bytes": int,
                "log_time_format": str, "log_timezone": str}
RERUN_KEYS = {"failed_check_line": str, "failed_detail_line": str, "rerun_command": str}
MW_KEYS = {"window_minutes": int, "min_errors": int, "error_line": str, "progress_line": str, "log_time_format": str,
           "log_timezone": str, "loaded_models_path": str}   # K4: bin/model_watch.py


def load():
    with open(PATH, encoding="utf-8") as f:
        return json.load(f)


def zone(name):
    """tzinfo for log_timezone: "owner" is the alert renderer's rule (OWNER_TIMEZONE, else $TZ, else UTC)."""
    if name == "owner":
        sys.path.insert(0, BIN)
        import alert_catalog
        return alert_catalog.zone()[0]
    from zoneinfo import ZoneInfo
    return ZoneInfo(name)


def validate():
    """Problems with the settings file, as a list of strings (empty = valid)."""
    try:
        s = load()
    except Exception as e:
        return [f"{PATH}: {type(e).__name__}: {e}"]
    errs = [] if s.get("schema_version") == 1 else [f"schema_version is {s.get('schema_version')!r}, expected 1"]
    for section, keys in (("gateway", GATEWAY_KEYS), ("test_rerun", RERUN_KEYS), ("model_watch", MW_KEYS)):
        d = s.get(section)
        if not isinstance(d, dict):
            errs.append(f"{section}: missing")
            continue
        for k, t in keys.items():
            if not isinstance(d.get(k), t) or isinstance(d.get(k), bool) or d.get(k) in ("", [], 0):
                errs.append(f"{section}.{k}: must be a non-empty {t.__name__}")
    g, r = s.get("gateway", {}), s.get("test_rerun", {})
    mw = s["model_watch"] if isinstance(s.get("model_watch"), dict) else {}
    if isinstance(g.get("activity_logs"), list) and not all(isinstance(p, str) and p for p in g["activity_logs"]):
        errs.append("gateway.activity_logs: every entry must be a non-empty string")
    for name, rx in (("gateway.connected_marker", g.get("connected_marker")), ("gateway.disconnected_marker", g.get("disconnected_marker")),
                     ("test_rerun.failed_check_line", r.get("failed_check_line")), ("test_rerun.failed_detail_line", r.get("failed_detail_line")),
                     ("model_watch.error_line", mw.get("error_line")), ("model_watch.progress_line", mw.get("progress_line"))):
        try:
            re.compile(rx or "")
        except (re.error, TypeError) as e:
            errs.append(f"{name}: not a regex ({e})")
    if isinstance(r.get("failed_check_line"), str) and re.compile(r["failed_check_line"]).groups != 1:
        errs.append("test_rerun.failed_check_line: needs exactly one capture group (the check name)")
    if "state_file" in g and not (isinstance(g["state_file"], str) and g["state_file"]
                                  and isinstance(g.get("state_max_age_minutes"), int)
                                  and not isinstance(g["state_max_age_minutes"], bool) and g["state_max_age_minutes"] > 0):
        errs.append("gateway.state_file needs a path and a positive state_max_age_minutes (K10)")
    if isinstance(r.get("rerun_command"), str) and "{check}" not in r["rerun_command"]:
        errs.append("test_rerun.rerun_command: must contain {check}")
    for name, tzname in (("gateway", g.get("log_timezone")), ("model_watch", mw.get("log_timezone"))):
        try:
            zone(tzname or "")
        except Exception as e:
            errs.append(f"{name}.log_timezone: {type(e).__name__}: {e}")
    return errs


def last_marker(path, g, tz):
    """(sort key, kind, UTC time or None) of the newest connected/disconnected line in the tail of one log, or None."""
    con, dis = re.compile(g["connected_marker"]), re.compile(g["disconnected_marker"])
    with open(path, "rb") as f:
        f.seek(0, 2)
        f.seek(max(0, f.tell() - g["marker_scan_bytes"]))
        lines = f.read().decode("utf-8", "replace").splitlines()
    hit = next((l for l in reversed(lines) if con.search(l) or dis.search(l)), None)
    if hit is None:
        return None
    kind = "disconnected" if dis.search(hit) else "connected"   # shortcut: a line matching both counts as disconnected, fix the regexes if it matters
    try:
        t = datetime.strptime(hit[:19], g["log_time_format"]).replace(tzinfo=tz).astimezone(timezone.utc)
    except ValueError:
        return hit[:19], kind, None
    return hit[:19], kind, t.strftime("%Y-%m-%dT%H:%M:%SZ")


def gateway():
    """The verdict. An alert is only for down and unknown; active and quiet are healthy (D47)."""
    def v(state, cause, evidence, marker_time=None):
        return {"state": state, "cause": cause, "evidence": evidence, "marker_time": marker_time}
    try:
        g = load()["gateway"]
        errs = validate()
        if errs:
            return v("unknown", "settings", "the watchdog settings are invalid: " + "; ".join(errs[:3]))
        if os.path.exists(os.path.expanduser(g["pause_file"])):   # K10/A-06: ~ in the settings, never a user's path
            return v("paused", "paused", "Hermes is paused on purpose")
    except Exception as e:
        return v("unknown", "settings", f"the watchdog settings cannot be read: {type(e).__name__}")
    try:
        up = subprocess.run(["pgrep", "-f", "--", g["process_match"]], capture_output=True, timeout=30).returncode
    except Exception as e:
        return v("unknown", "process_check", f"the process check could not run: {type(e).__name__}")
    if up == 1:
        return v("down", "process", "no process matches the gateway command")
    if up != 0:
        return v("unknown", "process_check", f"the process check failed (pgrep exit {up})")
    mtimes, markers, tz = {}, [], zone(g["log_timezone"])
    for p in map(os.path.expanduser, g["activity_logs"]):
        try:
            mtimes[p] = os.stat(p).st_mtime
            m = last_marker(p, g, tz)
            if m:
                markers.append(m)
        except OSError:
            continue
    if not mtimes:
        return v("unknown", "logs", "none of the activity logs can be read")
    age = int((time.time() - max(mtimes.values())) / 60)
    last = max(markers, key=lambda m: m[0]) if markers else None   # shortcut: markers from different logs compare by their timestamp text, same zone assumed
    if last and last[1] == "disconnected":
        return v("down", "disconnect", f"the newest connection line in the logs is a disconnect ({last[0]}); newest log write {age} min ago", last[2])
    if age <= g["activity_window_minutes"]:
        return v("active", "activity", f"a log was written {age} min ago" + (f"; the newest connection line is a connect ({last[0]})" if last else ""))
    if last and g.get("state_file"):   # K10: a quiet gateway must still refresh its own status file, or it is wedged
        try:
            st = json.load(open(os.path.expanduser(g["state_file"])))
            st_age = int((time.time() - datetime.fromisoformat(str(st.get("updated_at"))).timestamp()) / 60)
        except (OSError, ValueError, TypeError, AttributeError):   # unreadable or not an object: keep the log verdict
            st_age = None
        if st_age is not None and st_age > g["state_max_age_minutes"]:
            return v("unknown", "state_stale", f"process up and the newest connection line is a connect ({last[0]}), but the "
                     f"gateway has not refreshed its status file for {st_age} min; no log write for {age} min", last[2])
    if last:
        return v("quiet", "quiet", f"process up; the newest connection line is a connect ({last[0]}); no log write for {age} min", last[2])
    return v("unknown", "no_marker", f"process up, but no connection line in the logs and no log write for {age} min")


def failures(path):
    """(check, first failing line) per failed check in a test run's output; the line is cut and stripped of @ and backticks (it goes to Discord)."""
    r = load()["test_rerun"]
    chk, det, out = re.compile(r["failed_check_line"]), re.compile(r["failed_detail_line"]), []
    for line in open(path, encoding="utf-8", errors="replace").read().splitlines():
        if m := chk.search(line):
            out.append([m[1], ""])
        elif out and not out[-1][1] and (m := det.search(line)):
            out[-1][1] = re.sub(r"[@`\x00-\x1f]", "", m[1])[:160]
    return out


if __name__ == "__main__":
    cmd, args = (sys.argv[1] if len(sys.argv) > 1 else ""), sys.argv[2:]
    if cmd == "--check":
        errs = validate()
        print("\n".join(errs) or "settings OK")
        sys.exit(1 if errs else 0)
    elif cmd == "gateway":
        print(json.dumps(gateway()))
    elif cmd == "failures" and args:
        try:
            print("\n".join(f"{c}\t{d}" for c, d in failures(args[0])))
        except Exception:
            sys.exit(1)
    elif cmd == "get" and args:
        try:
            val = load()
            for k in args[0].split("."):
                val = val[k]
            print(val)
        except Exception:
            sys.exit(1)
    else:
        print(__doc__.split("\n", 1)[1], file=sys.stderr)
        sys.exit(2)
