#!/usr/bin/env python3
"""Alert catalog (D44), stdlib only: the one renderer of docs/hermes-local/alert-catalog.json (${ALERT_CATALOG} in tests).
CLI: alert_catalog.py render <CODE> [key=value ...]   the #alerts body on stdout; one line to the alerts log
     alert_catalog.py preview <CODE> [key=value ...]  the same body, nothing logged (for a hand run: render pollutes the live log)
     alert_catalog.py sample <CODE>                   the body with sample values and "(sample)" in the title
     alert_catalog.py docs | explain <CODE> | validate | codes | classify <raw error>
     alert_catalog.py streak < card.json                K3: "<code> <n>", the card's run of same-code guard refusals
     alert_catalog.py field <CODE> <field>              one catalog field (for example the action)
Keys: since=/now= are times (UTC ISO 8601 or epoch seconds), shown as HH:MM in the owner's zone; error=<raw> becomes
{what}, a plain phrase; resolved=1 renders the recovery form. Every key goes to the log, only placeholders reach Discord.
An unknown code renders STL-GEN-000; render never exits non-zero (bin/alert.sh still has a last-resort text)."""
import calendar, json, os, re, sys, time
from datetime import datetime, timezone

BIN = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BIN)
ICON = {"info": "ℹ️", "warning": "⚠️", "critical": "🚨"}
MAX = 1800
FIELDS = ("code", "area", "severity", "title", "message", "action", "cause", "check", "related", "resolvable")
UTC_NAMES = {"UTC", "Etc/UTC", "Etc/GMT", "GMT", "Etc/Zulu", "Zulu", "Universal", "Etc/Universal"}
# raw error -> plain phrase; first match wins (an SSL error also says "urlopen error")
CLASSES = (
    (r"SSL|TLS|handshake|UNEXPECTED_EOF|EOF occurred", "a network problem: the secure connection to Discord dropped"),
    (r"(error|status|HTTP)\D{0,6}429\b|rate.?limit|Too Many Requests", "Discord is rate-limiting Stella"),
    (r"(error|status|HTTP)\D{0,6}40[134]\b|Missing Access|Missing Permissions|Unknown (Channel|Message)|Forbidden|Unauthorized",
     "Discord refused the request: missing permission or a missing channel"),
    (r"(error|status|HTTP)\D{0,6}5\d\d\b|Internal Server Error|Bad Gateway|Service Unavailable|Gateway Timeout",
     "Discord had a server error"),
    (r"urlopen error|Name or service not known|name resolution|getaddrinfo|Connection (refused|reset|aborted)|timed? ?out|"
     r"Network is unreachable|No route to host|ConnectionError|ClientConnector|Cannot connect", "a network or DNS problem reaching Discord"),
    (r"No space left|Permission denied|Read-only file system|Disk quota", "a disk or permissions problem"),
    (r"exit \d+|exit code|command not found|failed|non-zero", "a local command failed"),
)
SAMPLE = {"served": "a free model", "card": "t_0000a1b2", "commit": "abc1234", "count": "3", "title": "Sample card title", "model": "Haiku",
          "minutes": "12", "max": "50", "check": "test run", "restarted": "the Stella container",
          "failing": "the local model server", "requested": "a code that is not listed", "parts": "ssh,web443", "summary": "This is a sample.",
          "error": "<urlopen error [Errno -3] Temporary failure in name resolution>",
          "problem": "profile x-new has no row in roles.json", "missing": "the worker's run id is missing", "board": "main",
          "by": "the dispatcher gave up after 2 failed starts", "reason": "the card's workspace could not be prepared",
          "detail": " First failing line: \"a sample check line\".",
          "fix": " The problem is line 19: it is not in an accepted form, which are KEY=value, KEY='value' or KEY=\"value\" (no $, backtick or backslash inside double quotes)."}


def classify(raw):
    for pat, phrase in CLASSES:
        if re.search(pat, raw or "", re.I):
            return phrase
    return "an unknown problem"


def catalog():
    with open(os.environ.get("ALERT_CATALOG") or f"{ROOT}/docs/hermes-local/alert-catalog.json", encoding="utf-8") as f:
        return {a["code"]: a for a in json.load(f)["alerts"]}


def zone():
    """(tzinfo, label): OWNER_TIMEZONE, else $TZ, else UTC; label " UTC" whenever the zone is UTC."""
    sys.path.insert(0, BIN)
    try:
        import owner_config
        owner = owner_config.get("OWNER_TIMEZONE")
    except Exception:
        owner = None
    from zoneinfo import ZoneInfo
    for name in (owner, os.environ.get("TZ", "").lstrip(":")):
        if not name:
            continue
        try:
            return ZoneInfo(name), (" UTC" if name in UTC_NAMES else "")
        except Exception:
            continue
    return timezone.utc, " UTC"


def hhmm(value, tz):
    v = str(value).strip()
    try:
        t = datetime.fromtimestamp(int(v), timezone.utc) if v.isdigit() else datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=timezone.utc)
    return t.astimezone(tz[0]).strftime("%H:%M") + tz[1]


class Vals(dict):
    def __missing__(self, k):
        return "unknown"


def render(code, kv, sample=False):
    """(body, code as logged, key=values to log: the caller's plus why a fallback was used)."""
    try:
        cat = catalog()
    except Exception as e:
        cat, kv = {}, dict(kv, catalog_error=f"{type(e).__name__}: {e}")
    entry, used = cat.get(code), code
    if entry is None or entry.get("status") == "retired":
        kv = dict(kv, requested=code)
        used, entry = "STL-GEN-000", cat.get("STL-GEN-000") or {
            "severity": "warning", "title": "something needs a look", "action": "see STL-GEN-000 in docs/alert-codes.md.",
            "message": "A part of Stella reported a problem, but its description is missing from the alert list ({requested}). {summary}"}
    tz = zone()
    vals = Vals({k: str(v)[:200] for k, v in kv.items()})
    vals["summary"] = vals.get("summary", "")
    vals["detail"] = vals.get("detail", "")   # D47: STL-WDG-101's optional "First failing line" sentence
    vals["fix"] = vals.get("fix", "")   # K5: STL-CFG-301's optional "which line, which forms" sentence
    if "commit" in vals:
        vals["commit"] = vals["commit"][:7]
    if "error" in kv:
        vals["what"] = classify(kv["error"])
    if "parts" in kv:   # failure tokens -> phrases from the entry's own "parts" table; an unknown token is never echoed
        table = entry.get("parts", {})
        vals["parts"] = "; ".join(dict.fromkeys(table.get(t, table.get("_other", "another problem")) for t in sorted(set(kv["parts"].split(","))) if t)) or "unknown"
    vals["now"] = hhmm(kv.get("now") or int(time.time()), tz)
    if kv.get("since"):
        vals["since"] = hhmm(kv["since"], tz) or "unknown"
    vals["at"] = hhmm(kv["at"], tz) or "an unknown time" if kv.get("at") else "an unknown time"   # D47: when the event happened (STL-GW-102)
    if kv.get("last_ok"):   # D46: the last healthy check (STL-RCV-502/503), a time like since
        vals["last_ok"] = hhmm(kv["last_ok"], tz) or "an unknown time"
    else:
        vals["last_ok"] = "an unknown time (none recorded yet)"
    resolved = kv.get("resolved") == "1" and entry.get("resolvable")
    tag = f"{used} resolved" if resolved else used
    title = (entry.get("resolved_title") if resolved else entry["title"]) + (" (sample)" if sample else "")
    icon = "✅" if resolved else ICON.get(entry.get("severity"), "⚠️")
    lines = [f"{icon} Stella: {title}  **[{tag}]**"]
    if resolved:
        lines.append(entry["resolved_message"].format_map(vals))
    else:
        lines.append(entry["message"].format_map(vals).strip())
        lines.append("What to do: " + entry["action"].format_map(vals))
        if kv.get("since"):
            lines.append(f"First seen {vals['since']}")
    body = "\n".join(lines)
    return (body if len(body) <= MAX else body[:MAX - 1] + "…"), tag, kv


def log(tag, kv):
    """One line per alert, code first, raw values (repr: newlines escaped). A log failure never stops the alert."""
    sup = os.environ.get("ESCALATE_SUP_DIR") or f"{ROOT}/.supervisor"
    try:
        os.makedirs(f"{sup}/logs", exist_ok=True)
        fields = " ".join(f"{k}={str(v)!r}"[:2000] for k, v in kv.items())
        with open(f"{sup}/logs/alerts.log", "a", encoding="utf-8") as f:
            f.write(f"{tag} {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {fields}\n")
    except OSError:
        pass


def pairs(args):
    kv = {}
    for a in args:
        k, sep, v = a.partition("=")
        if sep and re.fullmatch(r"[a-z_]+", k):
            kv[k] = v
        else:
            kv.setdefault("summary", a)   # a stray word is kept as the generic alert's summary, never dropped
    return kv


def docs():
    cell = lambda s: re.sub(r"\{(\w+)\}", r"<\1>", str(s)).replace("|", "\\|")
    out = ["# Stella alert codes", "",
           "Generated from `docs/hermes-local/alert-catalog.json` by `bin/alert-catalog.sh --docs`; do not edit by hand (D44).",
           "Each #alerts message ends its title with a code such as **[STL-ESC-210]**. Find the code below. `<card>` and the",
           "like stand for the values in the real message. Every alert is also logged, code first, with the raw technical",
           "details, in `.supervisor/logs/alerts.log`: `grep STL-ESC-210 .supervisor/logs/alerts.log`.", "",
           "| Code | Severity | What it means | Likely causes | What to check | What to do |",
           "|---|---|---|---|---|---|"]
    for a in catalog().values():
        status = f" ({a['status']})" if a.get("status") else ""
        meaning = f"**{a['title']}**{status}. {a['message']}" + (" Sends a ✅ resolved message when it clears." if a["resolvable"] else "")
        out.append("| " + " | ".join(cell(x) for x in (a["code"], a["severity"], meaning, a["cause"], a["check"], a["action"])) + " |")
    for a in catalog().values():
        if a.get("parts"):
            out += ["", f"## {a['code']}: what each part means", "", "The `<parts>` of the message are filled from these short names (the recovery log shows the names).", "",
                    "| Name | Shown as |", "|---|---|"] + [f"| `{k}` | {cell(v)} |" for k, v in a["parts"].items()]
    return "\n".join(out) + "\n"


def explain(code):
    a = catalog().get(code)
    if not a:
        return None
    rows = [("Code", a["code"] + (f" ({a['status']})" if a.get("status") else "")), ("Severity", a["severity"]),
            ("Title", a["title"]), ("Means", a["message"]), ("Do", a["action"]), ("Causes", a["cause"]),
            ("Check", a["check"]), ("Related", a["related"]), ("Clears", "yes, with a resolved message" if a["resolvable"] else "no message")]
    return "\n".join(f"{k:9}{v}" for k, v in rows)


PAGE = ("log", "hourly", "card_streak")   # K11: when a code sent through roles.log_alert also goes to #alerts


def page_due(code, key, streak=""):
    """K11: (due, state file) for an alert raised through roles.log_alert, by its catalog "page" policy. "card_streak":
    once per key (the card) per streak, a streak ending when the card is unblocked (streak = the time of its last unblock);
    "hourly": once an hour per key; "log" or no field: never (alerts.log only). The state file is written by mark_paged,
    only after a send that worked, so a failed send is tried again by the next alert."""
    try:
        policy = (catalog().get(code) or {}).get("page", "log")
    except Exception:   # a broken catalog must not silence the alert: page it once an hour
        policy = "hourly"
    sup = os.environ.get("ESCALATE_SUP_DIR") or f"{ROOT}/.supervisor"
    f = f"{sup}/state/page/{code}-{re.sub(r'[^A-Za-z0-9_.-]', '_', key or '-')[:80]}"
    try:
        old, age = open(f).read().strip(), time.time() - os.path.getmtime(f)
    except OSError:
        old, age = None, None
    if policy == "card_streak":
        return old != streak, f
    if policy == "hourly":
        return age is None or age >= 3600, f
    return False, f


def mark_paged(f, streak=""):
    try:
        os.makedirs(os.path.dirname(f), exist_ok=True)
        with open(f + ".tmp", "w") as h:
            h.write(streak)
        os.replace(f + ".tmp", f)
    except OSError:
        pass


def refusal_streak(j, log_path=None):
    """K3: (code, n) for a card (`hermes kanban show --json`): n consecutive runs, newest first, since the card's last
    unblock, each with at least one guard refusal (an STL-GRD-* line in alerts.log naming the card, logged between the
    run's start and its end, or now for the open run) of the same code as the newest run's. ("", 0) when there is none."""
    sup = os.environ.get("ESCALATE_SUP_DIR") or f"{ROOT}/.supervisor"
    card = j["task"]["id"]
    since = max((e.get("created_at") or 0 for e in j.get("events") or [] if e.get("kind") == "unblocked"), default=0)
    hits = []
    try:
        for line in open(log_path or f"{sup}/logs/alerts.log", encoding="utf-8", errors="replace"):
            m = re.match(r"(STL-GRD-\d{3}) (\S+) ", line)
            if m and re.search(rf"\bcard={re.escape(repr(card))}( |$)", line):   # RT4-10: the whole field, not a substring
                hits.append((calendar.timegm(time.strptime(m[2], "%Y-%m-%dT%H:%M:%SZ")), m[1]))
    except (OSError, ValueError):
        return "", 0
    runs = sorted((r for r in j.get("runs") or [] if (r.get("started_at") or 0) >= since),
                  key=lambda r: r.get("started_at") or 0, reverse=True)
    per_run = [{c for t, c in hits if (r.get("started_at") or 0) <= t <= (r.get("ended_at") or time.time()) + 1}
               for r in runs]
    best = ("", 0)   # RT4-11: each code of the newest run, counted on its own; a second code never collapses a streak
    for code in sorted(per_run[0]) if per_run else []:
        n = next((i for i, cs in enumerate(per_run) if code not in cs), len(per_run))
        best = max(best, (code, n), key=lambda x: x[1])
    return best


def validate():
    """Problems with the catalog, as a list of strings (empty = valid)."""
    path = os.environ.get("ALERT_CATALOG") or f"{ROOT}/docs/hermes-local/alert-catalog.json"
    try:
        alerts = json.load(open(path, encoding="utf-8"))["alerts"]
    except Exception as e:
        return [f"{path}: {type(e).__name__}: {e}"]
    errs, seen = [], set()
    for a in alerts:
        c = a.get("code", "?")
        errs += [f"{c}: missing {k}" for k in FIELDS if k not in a]
        m = re.fullmatch(r"STL-([A-Z]+)-\d{3}", c)
        if not m or m[1] != a.get("area"):
            errs.append(f"{c}: code is not STL-<area>-<nnn> with area {a.get('area')}")
        if c in seen:
            errs.append(f"{c}: duplicate code")
        seen.add(c)
        if a.get("severity") not in ICON:
            errs.append(f"{c}: severity {a.get('severity')}")
        if len(a.get("title", "")) >= 60:
            errs.append(f"{c}: title is 60 characters or more")
        if a.get("status") not in (None, "reserved", "retired"):
            errs.append(f"{c}: status {a.get('status')}")
        if "parts" in a and not (isinstance(a["parts"], dict) and a["parts"].get("_other") and all(isinstance(v, str) and v for v in a["parts"].values())):
            errs.append(f"{c}: parts must map each token to a phrase and include _other")
        if "{parts}" in a.get("message", "") and "parts" not in a:
            errs.append(f"{c}: message uses {{parts}} but has no parts table")
        if a.get("page", "log") not in PAGE:
            errs.append(f"{c}: page {a.get('page')} (one of {', '.join(PAGE)})")
        if a.get("resolvable") and not (a.get("resolved_title") and a.get("resolved_message")):
            errs.append(f"{c}: resolvable without resolved_title and resolved_message")
    if "STL-GEN-000" not in seen:
        errs.append("STL-GEN-000 is missing")
    return errs


if __name__ == "__main__":
    cmd, args = (sys.argv[1] if len(sys.argv) > 1 else ""), sys.argv[2:]
    if cmd in ("render", "preview", "sample") and args:
        kv = (dict(SAMPLE, since=str(int(time.time()) - 900), at=str(int(time.time()) - 1200), last_ok=str(int(time.time()) - 1500)) if cmd == "sample"
              else pairs(args[1:]))
        body, tag, kv = render(args[0], kv, sample=cmd == "sample")
        if cmd != "preview":
            log(tag, dict(kv, sample="1") if cmd == "sample" else kv)
        print(body)
    elif cmd == "docs":
        sys.stdout.write(docs())
    elif cmd == "explain" and args:
        text = explain(args[0].strip("[]*").upper())
        print(text or f"{args[0]} is not an alert code (see docs/alert-codes.md)")
        sys.exit(0 if text else 1)
    elif cmd == "validate":
        errs = validate()
        print("\n".join(errs) or "catalog OK")
        sys.exit(1 if errs else 0)
    elif cmd == "codes":
        print("\n".join(f"{c}\t{a.get('status', 'active')}\t{a['resolvable']}" for c, a in catalog().items()))
    elif cmd == "classify" and args:
        print(classify(" ".join(args)))
    elif cmd == "streak":   # K3: a card's `hermes kanban show --json` on stdin -> "<code> <n>" (n 0 and no code: none)
        code, n = refusal_streak(json.load(sys.stdin))
        print(f"{code} {n}".strip())
    elif cmd == "field" and len(args) == 2:   # K3: one catalog field of a code, e.g. its action
        print((catalog().get(args[0]) or {}).get(args[1], ""))
    else:
        print(__doc__.split("\n", 1)[1], file=sys.stderr)
        sys.exit(2)
