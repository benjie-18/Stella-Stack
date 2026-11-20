#!/usr/bin/env python3
"""The one redactor of agent-chosen data (X1 A-CRT-01, A-CVER-01), stdlib only. An agent picks values AND names: dict keys, tool
names, message ids, UI component and action ids. Every one of them passes the same masks before it reaches the run stream, the run
log (peek), the trusted event log, an alert line or the UI read stream: run tokens (run_token's prefix) and the connections catalog's
value patterns, where they stand, in values and in keys alike; values under event_log's redact keys and values seen under masked keys
(event_log.scrub). Patterns that cannot be read: every string is *** (fail closed). Library only:
  redactor(count=None, limit=None) -> red(x)   x redacted (str, dict keys and values, lists); count(class, n) gets each pattern hit
                                               (class run_token or token); a string longer than limit is *** whole
  name(x, n=64) -> str                         an agent-chosen id for a problem line: redacted, then cut to n characters"""
import os, re, sys

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import stella_data as sd


def patterns():
    """[(class, compiled pattern)]: run tokens first, then the catalog's value patterns; None when they cannot be read."""
    try:
        import run_token
        v = sd.value_pats()
        if v is None:
            return None
        return [("run_token", re.compile(re.escape(run_token.gateway()["token"]["prefix"]) + r"[A-Za-z0-9_-]+"))] + [("token", p) for p in v]
    except Exception:
        return None


def redactor(count=None, limit=None):
    pats = patterns()
    try:
        redk = el.redactor()
    except Exception:   # fail closed: every value under any key masked
        redk = lambda k: True

    def text(x):
        if pats is None or (limit and len(x) > limit):
            return el.MASK
        for c, p in pats:
            x, n = p.subn(el.MASK, x)
            if n and count:
                count(c, n)
        return el.scrub(x)

    def red(x):
        if isinstance(x, str):
            return text(x)
        if isinstance(x, dict):   # the key is agent text too: masked like a value (two masked keys fold into one ***)
            return {text(str(k)): el.MASK if redk(str(k)) else red(v) for k, v in x.items()}
        return [red(v) for v in x] if isinstance(x, list) else x
    return red


def name(x, n=64):
    return redactor(limit=sd.MASK_LIMIT)(x)[:n] if isinstance(x, str) else "a non-text id"
