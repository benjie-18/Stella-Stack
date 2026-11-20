#!/usr/bin/env python3
"""Stuck detection (F3 item S; body B10; design section 8 and 3c), stdlib only. Reads the trusted tool stream of a run
(runs/<id>/events.jsonl under index key adapter_runs, written by the adapter) and finds no-progress patterns defined as data in
.stella/stuck.json, thresholds per role (a role not listed gets "default"):
  repeat_action  N tool results in a row with the same signature, ok and output
  repeat_error   N failed results in a row with the same action signature and the same output
  alternate      N results alternating A,B,A,B (A and B differ)
  edit_revert    N times the worktree diff digest returns to any of the last revert_window earlier digests (the working-notes file is not in the digest)
  tokens_no_diff usage tokens summed since the diff digest last changed reach N
CLI (host only, STL-CFG-312 in a worker environment):
  stuck.py scan FILE [--role R] [--json]       matches of the file's events: {stuck, matches [{pattern, detail, evidence}]}; exit 0 even on a match
  stuck.py watch --run R --card C [--role R] [--events FILE]   follow the stream; on a match: stop argv (adapter.py stop --reason stuck),
        one trusted run-block line {pattern, kind, reason, evidence, card}, the block argv (data) for the card; exit 0 after a block
        or when the run record says the run ended (a result line in the stream does not end it), 1 refused
Exit: 0 ok; 1 refused (the catalog code and its plain message on stderr); 2 usage."""
import os, sys

if __name__ == "__main__" and not sys.flags.isolated:   # run directly: PYTHONPATH and the current folder must not decide what is imported
    try:
        os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
    except OSError:
        sys.exit("STL-CFG-310 stuck.py could not restart itself isolated (python3 -I); nothing was done")

import argparse, json, subprocess, time

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import event_log as el
import stella_data as sd
import worker_env

DATA, STOPFAIL, BLOCKFAIL, NOSTREAM = "STL-ESC-250", "STL-ESC-251", "STL-ESC-252", "STL-ESC-253"
ROW, KEY, STREAM = "stuck", "adapter_runs", "events.jsonl"
DIFF_KINDS = ("edit_revert", "tokens_no_diff")
KINDS = ("repeat_action", "repeat_error", "alternate", "edit_revert", "tokens_no_diff")


class Stop(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def data():
    try:
        row = next(r for r in sd.rows() if r["id"] == ROW)
        return sd.checked(sd.load(row["path"]), row["path"], row["schema"])
    except (sd.DataError, StopIteration, KeyError) as e:
        raise Stop(DATA, f"the stuck detection data cannot be used: {str(e)[:160] or 'no index row'}") from None


def thresholds(doc, role):
    return {**doc["default"], **doc["roles"].get(role, {})}


def read_events(text):
    """The valid event objects of a jsonl text (a half-written last line is skipped), in order."""
    out = []
    for ln in text.splitlines():
        try:
            e = json.loads(ln)
        except ValueError:
            continue
        if isinstance(e, dict):
            out.append(e)
    return out


def scan(events, th, window, baseline=0):
    """The first match of each pattern kind in th: [{pattern, detail, evidence [events]}]; window: how many earlier diff digests a revert may return to;
    baseline: the adapter's fixed prompt tokens, re-read every turn, left out of each usage event for tokens_no_diff (live finding M)."""
    res = [e for e in events if e.get("type") == "tool_result"]
    found = []

    def hit(kind, detail, ev):
        found.append({"pattern": kind, "detail": detail, "evidence": ev})

    def run_of(kind, n, key, only=lambda e: True):   # n consecutive results with an equal key
        streak = []
        for e in res:
            if only(e) and streak and key(e) == key(streak[-1]):
                streak.append(e)
            else:
                streak = [e] if only(e) else []
            if len(streak) >= n:
                return streak
        return None

    if "repeat_action" in th:
        s = run_of("repeat_action", th["repeat_action"], lambda e: (e.get("signature"), e.get("ok"), e.get("output")))
        if s:
            hit("repeat_action", f"the same action and result {len(s)} times", s)
    if "repeat_error" in th:
        s = run_of("repeat_error", th["repeat_error"], lambda e: (e.get("signature"), e.get("output")), lambda e: e.get("ok") is False)
        if s:
            hit("repeat_error", f"the same error {len(s)} times", s)
    if "alternate" in th:
        n = th["alternate"]
        sig = [e.get("signature") for e in res]
        for i in range(len(res) - n + 1):
            w = sig[i:i + n]
            if w[0] != w[1] and all(w[j] == w[j % 2] for j in range(n)):
                hit("alternate", f"two actions alternating {n} times", res[i:i + n])
                break
    if "edit_revert" in th or "tokens_no_diff" in th:
        chain, reverts, just, tokens, span, prev = [], 0, False, 0, [], None   # chain: the distinct consecutive diff digests
        for e in events:
            if e.get("type") == "usage":
                tokens += max(0, sum(v for v in (e.get("tokens") or {}).values() if isinstance(v, int)) - baseline)
                span.append(e)
            d = e.get("diff") if e.get("type") == "tool_result" else None
            if not d:
                continue
            if chain and d != chain[-1]:
                back = d in chain[-window - 1:-1] and not just   # a change right after a revert is the next edit, not a revert
                just = back
                if back:
                    reverts += 1
                    if reverts >= th.get("edit_revert", 10**9) and not any(f["pattern"] == "edit_revert" for f in found):
                        hit("edit_revert", f"the diff went back to an earlier state {reverts} times", [prev, e])
                chain.append(d)
                prev = e
                tokens, span = 0, []
            elif not chain:
                chain.append(d)
            if tokens >= th.get("tokens_no_diff", 10**18) and not any(f["pattern"] == "tokens_no_diff" for f in found):
                hit("tokens_no_diff", f"{tokens} tokens with the diff unchanged", span[-10:] + [e])
        if tokens >= th.get("tokens_no_diff", 10**18) and not any(f["pattern"] == "tokens_no_diff" for f in found):
            hit("tokens_no_diff", f"{tokens} tokens with the diff unchanged", span[-10:])
    return found


def sub(argv, vals):
    return [a.format_map(vals) if "{" in a else a for a in argv]


def runs_dir():
    try:
        return el.path(sd.load(sd.INDEX)[KEY])
    except (KeyError, OSError, sd.DataError):
        raise Stop(NOSTREAM, f"the index has no usable {KEY} (the adapter's run folder)") from None


def call(argv, code, what):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as e:
        raise Stop(code, f"{what} could not run ({type(e).__name__})") from None
    if r.returncode:
        raise Stop(code, f"{what} failed (exit {r.returncode}): {(r.stderr or r.stdout).strip()[-160:]}")


def baseline_of(aid):
    """The adapter's prefill_baseline_tokens (its own fixed prompt, re-read every turn); 0 when absent or unreadable."""
    try:
        import roles
        return max(0, int(roles.adapters().get(aid, {}).get("prefill_baseline_tokens") or 0))
    except Exception:
        return 0


def cmd_scan(a):
    doc = data()
    try:
        with open(a.file, encoding="utf-8") as f:
            events = read_events(f.read())
    except OSError as e:
        raise Stop(NOSTREAM, f"{a.file} cannot be read ({el.why(e)[:100]})") from None
    m = scan(events, thresholds(doc, a.role), doc["revert_window"], a.baseline)
    if a.json:
        print(json.dumps({"stuck": bool(m), "role": a.role, "matches": m}))
    else:
        print("\n".join(f"{x['pattern']}: {x['detail']}" for x in m) or "no pattern")
    return 0


def cmd_watch(a):
    doc = data()
    path = a.events or os.path.join(runs_dir(), a.run, STREAM)
    th = thresholds(doc, a.role)
    rec = os.path.join(runs_dir(), a.run + ".json")
    while True:
        try:
            with open(rec, encoding="utf-8") as f:   # read before the stream: the adapter writes the last event before it records the end
                r = json.load(f)
            ended = r.get("ended") is not None
        except (OSError, ValueError, AttributeError):
            raise Stop(NOSTREAM, f"the record of run {a.run} ({rec}) cannot be read") from None
        try:
            with open(path, encoding="utf-8") as f:
                events = read_events(f.read())
        except FileNotFoundError:
            events = []
        except OSError as e:
            raise Stop(NOSTREAM, f"{path} cannot be read ({el.why(e)[:100]})") from None
        m = scan(events, th, doc["revert_window"], baseline_of(r.get("adapter")))
        if m:
            break
        if ended:
            return 0
        time.sleep(doc["poll_s"])
    first = max(m, key=lambda x: x["pattern"] in DIFF_KINDS)   # a pattern that saw the worktree diff names the loop better than one that saw only signatures; ties keep file order
    vals = {"python": sys.executable, "bin": BIN, "run": a.run, "card": a.card, "kind": doc["block"]["kind"],
            "pattern": first["pattern"], "detail": first["detail"]}
    reason = doc["block"]["reason"].format_map(vals)
    # the evidence line and the card block come first: the stop ends the run, and a reader that sees the run ended must find both; a failing block never keeps the run alive
    el.append(el.build("run-block", f"run {a.run}", new={"pattern": first["pattern"], "kind": doc["block"]["kind"], "reason": reason,
                       "card": a.card, "evidence": first["evidence"]}, who={"role": a.role}))
    blocked = None
    try:
        if a.card:
            call(sub(doc["block"]["argv"], {**vals, "reason": reason}), BLOCKFAIL, "the card block command")
    except Stop as x:
        blocked = x
    call(sub(doc["stop"]["argv"], vals), STOPFAIL, "the adapter stop")   # frees the lease with the run
    if blocked:
        raise blocked
    print(json.dumps({"run": a.run, "blocked": a.card, "pattern": first["pattern"], "reason": reason}))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="stuck.py", description="No-progress detection on a run's trusted tool stream (host only).")
    sub_ = ap.add_subparsers(dest="cmd", required=True)
    p = sub_.add_parser("scan")
    p.add_argument("file")
    p.add_argument("--role")
    p.add_argument("--baseline", type=int, default=0, help="the adapter's fixed prompt tokens per usage event, left out of tokens_no_diff")
    p.add_argument("--json", action="store_true")
    p = sub_.add_parser("watch")
    p.add_argument("--run", required=True)
    p.add_argument("--card", help="the card to block; a run with no card gets the run-block line and the stop only")
    p.add_argument("--role")
    p.add_argument("--events", help="the stream file (default: the run's events.jsonl)")
    a = ap.parse_args(argv)
    try:
        w = worker_env.reason()
        if w:
            raise Stop(sd.Refused.code, f"stuck.py {a.cmd} runs on the host only ({w}); nothing was read")
        return {"scan": cmd_scan, "watch": cmd_watch}[a.cmd](a)
    except Stop as x:
        return el.fail(x.code, x.problem)
    except el.EventError as e:
        return el.fail(e.code, e.problem, e.extra)
    except sd.DataError as e:
        return el.fail(getattr(e, "code", "STL-CFG-310"), str(e)[:180])
    except Exception as e:   # never a traceback: the type only
        return el.fail("STL-CFG-310", f"{type(e).__name__}, an unexpected failure of stuck.py {a.cmd}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
