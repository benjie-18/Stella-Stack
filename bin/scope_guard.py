#!/usr/bin/env python3
"""Scope guard (phase P1 item G), stdlib only. Read only, no model call.
  check --roadmap FILE [--built FILE] [--json]   findings in the qa_findings submit format ({findings: [...]}); exit 0 with none, 1 with some.
Request terms are computed here: the words of request.text minus the planner data's scope_guard.stopwords (never the planner's own
list). A phase whose builds terms share fewer than scope_guard.min_shared_terms with them is flagged. --built FILE
({paths, titles, artifacts}, lists of strings) is built work: an item that shares a word with an out_of_scope entry, or with no
phase's builds terms, is flagged. Severity comes from the data. It can serve as the validator stub slot (qa_stub_role fixture
<qa_evidence>/<card>/stub/<round>-<role>.json holds {"result": ..., "findings": [this output's findings]}) until D1.
Roadmap and built files are untrusted: size capped (the data's roadmap.max_bytes), shape checked.
Failures: STL-PLN-500 (roadmap), 501 (built file), 502 (unexpected); JSON {ok: false, code, problem} on stdout, exit 2."""
import argparse, json, os, re, sys

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import roadmap as rm

ROADMAP, BUILT, ODD = "STL-PLN-500", "STL-PLN-501", "STL-PLN-502"
TEST = "scope-guard"


def terms(*texts, stop=()):
    return {w for t in texts for w in re.split(r"[^a-z0-9]+", t.lower()) if w and w not in stop}


def built_file(path, cap):
    try:
        if os.path.getsize(path) > cap:
            raise rm.Refuse(BUILT, f"the built file is larger than {cap} bytes")
        d = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError, RecursionError):
        raise rm.Refuse(BUILT, "the built file cannot be read as JSON")
    ok = isinstance(d, dict) and all(isinstance(d.get(k, []), list) and all(isinstance(x, str) for x in d.get(k, [])) for k in ("paths", "titles", "artifacts"))
    if not ok:
        raise rm.Refuse(BUILT, "the built file must be {paths, titles, artifacts}, each a list of strings")
    return list(dict.fromkeys(d.get("paths", []) + d.get("titles", []) + d.get("artifacts", [])))


def cmd_check(a, pl):
    sg = pl["scope_guard"]
    try:
        d = rm.load(a.roadmap, pl)
    except rm.Refuse as e:
        raise rm.Refuse(ROADMAP, e.problem)
    stop = set(sg["stopwords"])
    want, sev = terms(d["request"]["text"], stop=stop), sg["severity"]
    out = []

    def add(check, file):
        out.append({"check": check, "file": file, "lines": [1, 1], "test": TEST, "severity": sev, "repro": None, "evidence": None, "static": True})

    have = set()
    for p in d["phases"]:
        t = terms(*p["builds"], stop=stop)
        have |= t
        if len(t & want) < sg["min_shared_terms"]:
            add(f"phase {p['id']} ({p['title']}) builds nothing the request asked for", a.roadmap)
    if a.built:
        odd = [terms(o, stop=stop) for o in d["out_of_scope"]]
        for item in built_file(a.built, pl["roadmap"]["max_bytes"]):
            t = terms(item, stop=stop)
            if any(t & o for o in odd):
                add(f"built work {item} is out of scope", a.built)
            elif not t & have:
                add(f"built work {item} matches no phase of the roadmap", a.built)
    return {"findings": out}


def main(argv):
    ap = argparse.ArgumentParser(prog="scope_guard.py", allow_abbrev=False, description=__doc__.split("\n", 1)[0])
    s = ap.add_subparsers(dest="cmd", required=True).add_parser("check", allow_abbrev=False)
    s.add_argument("--roadmap", required=True)
    s.add_argument("--built")
    s.add_argument("--json", action="store_true", help="accepted: JSON is the only output")
    a = ap.parse_args(argv)
    try:
        out = cmd_check(a, rm.doc("planner"))
    except (rm.Refuse, rm.sd.DataError) as e:
        code, why = (e.code, e.problem) if isinstance(e, rm.Refuse) else (ODD, str(e))
        print(json.dumps({"ok": False, "code": code, "problem": el.scrub(why)}))
        el.say(code, why, alert=True)   # one alert line per refusal, secrets masked
        return 2
    print(json.dumps(out, indent=2))
    return 1 if out["findings"] else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:   # never the value: the type only
        print(json.dumps({"ok": False, "code": ODD, "problem": type(e).__name__}))
        el.say(ODD, f"{type(e).__name__}, an unexpected failure of scope_guard.py", alert=True)
        sys.exit(2)
