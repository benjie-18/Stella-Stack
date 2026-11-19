#!/usr/bin/env python3
"""Prompt profiles (F3 item PP), stdlib only. The same role instructions rendered in the form the model's family follows best; every form is
data (.stella/prompt-profiles.json, schema prompt-profiles) and the family is a field of the catalog's model entry (.stella/connections.json).
  render --role R --link CONNECTION/MODEL --brief FILE [--profile P] [--evidence FILE] [--attached FILE] [--notes FILE]
         [--instructions FILE] [--question FILE|TEXT] --json
      Sections, in the profile's order (evidence and context first, the question last): evidence, card brief, attached capabilities,
      working notes (path, then the file's content), capability line (the text of key capability_prompt_line in
      .stella/capability-sources.json), role instructions (with the family's parallel-tool-call line, where it has one), question.
      A section with no input is left out, the question never. Output {profile, family, role, link, sections, reasoning, example_placement, parallel_tools, text}.
      The profile: --profile, else the role's override, else the family's, else the default.
  check --json    the data file (schema, every profile named by the maps exists).
Exit: 0 ok; 1 refused (catalog code and plain message on stderr, {code, problem} on stdout); 2 usage.
Codes: STL-CFG-330 profiles file unusable, 331 profile, link or model not found, 332 an input file unreadable, 333 capability line missing.
shortcut: a section body is the file text as it is (no escaping of the template's own tags), upgrade when a body may hold a closing tag."""
import argparse, json, os, sys

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import stella_data as sd

BADDATA, NOPROFILE, BADINPUT, NOLINE = "STL-CFG-330", "STL-CFG-331", "STL-CFG-332", "STL-CFG-333"
ROW, CATALOG, SOURCES = "prompt-profiles", ".stella/connections.json", ".stella/capability-sources.json"

class Stop(Exception):
    def __init__(self, code, problem, alert=True):
        super().__init__(problem)
        self.code, self.problem, self.alert = code, problem, alert

def load():
    try:
        sd.served([ROW])
        row = next(r for r in sd.rows() if r["id"] == ROW)
        t = sd.checked(sd.load(row["path"]), row["path"], row["schema"])
    except (sd.DataError, StopIteration) as e:
        raise Stop(BADDATA, f"the prompt profiles file cannot be used: {str(e)[:160]}")
    ids = [p["id"] for p in t["profiles"]]
    named = [t["default"], *t["family_map"].values(), *t["role_overrides"].values()]
    bad = [f"profile {sd.idn(n)} is not defined" for n in named if n not in ids] + [f"profile {sd.idn(i)} is defined twice" for i in set(ids) if ids.count(i) > 1]
    if bad:
        raise Stop(BADDATA, bad[0] + (f" (and {len(bad) - 1} more)" if len(bad) > 1 else ""))
    return t

def family_of(link):
    conn, _, model = link.partition("/")
    try:
        cat = sd.load(CATALOG)
        m = next(m for e in cat["entries"] if e["id"] == conn for m in e.get("models", []) if m["id"] == model)
    except (sd.DataError, StopIteration):
        raise Stop(NOPROFILE, f"the link {sd.idn(link)} is not a model of the catalog", alert=False)
    return m.get("family")

def pick(t, role, family, wanted):
    pid = wanted or t["role_overrides"].get(role) or t["family_map"].get(family) or t["default"]
    p = next((p for p in t["profiles"] if p["id"] == pid), None)
    if p is None:
        raise Stop(NOPROFILE, f"there is no profile {sd.idn(pid)}", alert=False)
    return p

def text_of(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except (OSError, UnicodeError):
        raise Stop(BADINPUT, f"cannot read {sd.idn(path)}", alert=False)

def capability_line():
    try:
        with open(os.path.join(sd.ROOT, SOURCES), encoding="utf-8") as f:
            line = json.load(f).get("capability_prompt_line")
    except (OSError, ValueError, AttributeError):
        line = None
    if not isinstance(line, str) or not line.strip():
        raise Stop(NOLINE, "the capability prompt line is missing from the capability sources", alert=False)
    return line.strip()

def render(a, t):
    family = family_of(a.link)
    p = pick(t, a.role, family, a.profile)
    ins = text_of(a.instructions) if a.instructions else ""
    if p["parallel_tools_line"]:
        ins = (ins + "\n\n" if ins else "") + p["parallel_tools_line"]
    notes = f"{a.notes}\n\n{text_of(a.notes)}" if a.notes else ""
    q = text_of(a.question) if a.question and os.path.isfile(a.question) else (a.question or "")
    body = {"evidence": text_of(a.evidence) if a.evidence else "", "brief": text_of(a.brief), "capabilities": text_of(a.attached) if a.attached else "",
            "notes": notes, "capability_line": capability_line(), "instructions": ins, "question": q}
    used = [n for n in p["order"] if body.get(n) or n == "question"]   # the question always stands, last, even when empty
    parts = [p["section_template"].format(name=n, title=p["titles"].get(n, n), body=body[n]) for n in used]
    return {"profile": p["id"], "family": family, "role": a.role, "link": a.link, "sections": used, "reasoning": p["reasoning"],
            "example_placement": p["example_placement"], "parallel_tools": bool(p["parallel_tools_line"]), "text": "\n\n".join(parts) + "\n"}

def main(argv):
    ap = argparse.ArgumentParser(prog="prompt.py", description="Render a role prompt in the profile of the model's family.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check"); c.add_argument("--json", action="store_true")
    r = sub.add_parser("render"); r.add_argument("--json", action="store_true")
    r.add_argument("--role", required=True); r.add_argument("--link", required=True); r.add_argument("--brief", required=True)
    for n in ("profile", "evidence", "attached", "notes", "instructions", "question"):
        r.add_argument("--" + n)
    a = ap.parse_args(argv)
    try:
        t = load()
        out = {"ok": True, "entries": len(t["profiles"])} if a.cmd == "check" else render(a, t)
        print(json.dumps(out) if a.json or a.cmd == "check" else out["text"], end="" if not (a.json or a.cmd == "check") else "\n")
        return 0
    except Stop as x:
        s = x
    except el.EventError as e:
        s = Stop(e.code, e.problem)
    except sd.DataError as e:
        s = Stop(BADDATA, str(e)[:180])
    except Exception as e:   # never a traceback, never the error's text (it could repeat a value): the type only
        s = Stop(BADINPUT, f"{type(e).__name__}, an unexpected failure of prompt.py {a.cmd}")
    print(json.dumps({"code": s.code, "problem": el.scrub(s.problem)}))
    el.say(s.code, s.problem, alert=s.alert)
    return 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
