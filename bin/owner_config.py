#!/usr/bin/env python3
"""Owner config reader (D39), stdlib only: the one parser of ${OWNER_CONFIG:-/workspace/config/owner.env}.

Grammar: one KEY=value, KEY='value' or KEY="value" per line, blank lines and # comments. Single quotes are literal (no
escapes, no expansion); a double-quoted value has no $, `, backslash or " (K5); an unquoted value has no whitespace,
quotes, $, `, backslash or shell operator, glob or tilde character. The file is never sourced; the grammar still keeps
every accepted line one that bash would read the same way, except that a CR at a line end and a leading UTF-8 BOM are
dropped (Windows editors write them): lines end at "\n" only, only space, tab or CR may follow a value, the text is UTF-8. A missing file, a bad line, or a missing or
empty key (OWNER_DISCORD_USER_ID may be empty) raises OwnerConfigError: there is no fallback to other values.
CLI: owner_config.py --shell   the keys as shell assignments, for bin/owner-config.sh; exit 2 and a reason on error.
OPTIONAL keys are never required; get(key) reads one and never raises (D44).
"""
import os, re, shlex, sys

KEYS = ("OWNER_NAME", "OWNER_DISCORD_USER_ID", "OWNER_STACK_PATH_WIN", "GITHUB_OWNER",
        "DISCORD_GUILD_ID", "ESCALATIONS_CHANNEL_ID", "SUPERVISOR_CHANNEL_ID")
MAY_BE_EMPTY = {"OWNER_DISCORD_USER_ID"}
OPTIONAL = ("OWNER_TIMEZONE",)   # D44: IANA zone for alert times; absent = the container's TZ, then UTC
LINE = re.compile(r"([A-Z][A-Z0-9_]*)=(?:'([^']*)'|\"([^\"$`\\]*)\"|([^\s'\"$`\\;&|<>()*?~{}\[\]]*))[ \t\r]*")
FORMS = "KEY=value, KEY='value' or KEY=\"value\" (no $, backtick or backslash inside double quotes)"


class OwnerConfigError(Exception):
    pass


def path():
    return os.environ.get("OWNER_CONFIG") or "/workspace/config/owner.env"


def _parse():
    p = path()
    try:
        with open(p, "rb") as f:
            raw = f.read()
    except OSError as e:
        raise OwnerConfigError(f"cannot read {p}: {e.strerror}")
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError as e:   # an editor's ANSI save: name the line like any other bad line, never crash
        raise OwnerConfigError(f"{p} line {raw[:e.start].count(10) + 1}: not {FORMS} (the line is not UTF-8 text)")
    cfg = {}
    for n, line in enumerate(text.split("\n"), 1):
        if not line.strip(" \t\r") or line.lstrip(" \t").startswith("#"):
            continue
        m = LINE.fullmatch(line)
        if not m:
            raise OwnerConfigError(f"{p} line {n}: not {FORMS}")
        cfg[m[1]] = next(v for v in m.groups()[1:] if v is not None)
    return p, cfg


def load():
    p, cfg = _parse()
    missing =[k for k in KEYS if not cfg.get(k) and not (k in MAY_BE_EMPTY and k in cfg)]
    if missing:
        raise OwnerConfigError(f"{p}: missing or empty {', '.join(missing)}")
    return {k: cfg[k] for k in KEYS}


def get(key):
    """One OPTIONAL key's value, or None when it, its line or the whole file is missing or bad. Never raises: the
    missing-config alert itself renders times with it."""
    try:
        return _parse()[1].get(key) or None
    except OwnerConfigError:
        return None


def windows(cfg, rel):
    """The owner's Windows path of /workspace/<rel>."""
    return cfg["OWNER_STACK_PATH_WIN"].removesuffix("\\") + "\\" + rel.replace("/", "\\")


def render(text, cfg):
    """{{KEY}} -> cfg[KEY], exact text (values hold backslashes). The path loses one trailing backslash: sources join it
    as {{OWNER_STACK_PATH_WIN}}\\<path>. An unknown placeholder, or a {{ left after rendering, is an error."""
    vals = dict(cfg, OWNER_STACK_PATH_WIN=cfg["OWNER_STACK_PATH_WIN"].removesuffix("\\"))

    def value(m):
        if m[1] not in vals:
            raise OwnerConfigError(f"unknown placeholder {m[0]}")
        return vals[m[1]]
    out = re.sub(r"\{\{([^{}]*)\}\}", value, text)
    if "{{" in out:
        raise OwnerConfigError("placeholder left after rendering")
    return out


if __name__ == "__main__" and sys.argv[1:] == ["--shell"]:
    try:
        print("\n".join(f"{k}={shlex.quote(v)}" for k, v in load().items()))
    except OwnerConfigError as e:
        print(e, file=sys.stderr)
        sys.exit(2)
