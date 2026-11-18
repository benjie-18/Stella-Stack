#!/usr/bin/env bash
# Hermetic self-test for bin/mock_provider.py and bin/mock_cli.py (F2 W2, the test rig): in a scratch root (STELLA_ROOT, a copy
# of .stella/) it starts the server on a free port and proves, for every shape of protocols.json and one fake shape added as data
# only: a request built from the shape's own templates answers 200; each fault fires, lasts its calls and clears; /_calls counts
# exactly; then the fake CLI's modes. Nothing here names a shape or a model.
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/mock-provider-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
R=$T/root; mkdir -p "$R"; cp -r "$H/bin" "$H/.stella" "$H/docs" "$R/"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env; unset MOCK_CLI_MODE MOCK_CLI_CALLS MOCK_CLI_SECONDS
fails=0
ok() { if ( eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
# a fourth shape: a copy of the first with another id and prefix, no code change
jq '.entries += [.entries[0] | .id = "extra-shape" | .request.path = "/x" + .request.path | .models_path = "/x" + .models_path]' "$R/.stella/protocols.json" >"$T/p" && mv "$T/p" "$R/.stella/protocols.json"
ok 'python3 -I "$R/bin/stella_data.py" check' "S0 the data, with the extra shape, passes stella_data.py check"
python3 -I "$R/bin/mock_provider.py" >"$T/out" 2>"$T/err" & 
for i in $(seq 100); do [ -s "$T/out" ] && break; sleep 0.1; done
cat >"$T/drive.py" <<'PY'
import json, re, sys, time, urllib.error, urllib.request
first = json.loads(open(sys.argv[1]).readline()); port, ctl = first["port"], first["control"]
BASE = ctl.rsplit("/", 1)[0]
protos = {e["id"]: e for e in json.load(open(sys.argv[2]))["entries"]}
res = []
def ok(c, m): res.append(("ok  " if c else "FAIL") + " " + m)
def http(url, data=None, headers=None, timeout=5):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers or {}), timeout=timeout) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as x:
        return x.code, x.read().decode()
    except OSError:
        return None, ""
def sub(v, m, p="hi"):
    if isinstance(v, str):
        return 8 if v == "{max_tokens}" else v.replace("{model}", m).replace("{key}", "k-" + m).replace("{prompt}", p)
    if isinstance(v, list): return [sub(x, m, p) for x in v]
    if isinstance(v, dict): return {k: sub(x, m, p) for k, x in v.items()}
    return v
def call(s, m, p="hi", t=5):
    q = protos[s]["request"]
    return http(f"{BASE}/{s}{sub(q['path'], m)}", json.dumps(sub(q["body"], m, p)).encode(),
                {**sub(q["headers"], m), "Content-Type": "application/json"}, t)
def ptr(d, p):
    for x in p.split("/")[1:]:
        d = d[int(x)] if isinstance(d, list) else d[x]
    return d
def trig(s, st, body):
    for e in protos[s]["errors"]:
        sp = e["status"]; hit = st == sp if isinstance(sp, int) else (st // 100 == int(sp[0]) if "x" in sp else False)
        if hit and (not e.get("body_pattern") or re.search(e["body_pattern"], body)): return e["trigger"]
def setc(models, faults):
    return http(ctl, json.dumps({"models": {s: models for s in protos}, "faults": faults}).encode())[0] == 200
def listed(s):
    st, b = http(f"{BASE}/{s}{protos[s]['models_path']}")
    return b
sent = {}
def c(s, m, *a):
    sent[f"{s}/{m}"] = sent.get(f"{s}/{m}", 0) + 1
    return call(s, m, *a)
ok(setc(["m1", "m2"], []), "control takes a document")
for s in protos:
    st, b = c(s, "m1")
    ok(st == 200 and ptr(json.loads(b), protos[s]["response"]["model"]) == "m1", f"[{s}] a request from its templates answers 200 with the served model")
    ok("m1" in listed(s) and "m2" in listed(s), f"[{s}] the model list holds the served models")
    st, b = c(s, "unserved")
    ok(trig(s, st, b) == "model_gone", f"[{s}] a model nobody serves gets the not-found error")
    for f in ("rate_limit", "daily_cap", "server_error", "model_gone"):
        setc(["m1", "m2"], [{"shape": s, "model": "m1", "fault": f, "calls": 1}])
        st, b = c(s, "m1"); st2, _ = c(s, "m1"); st3, _ = c(s, "m2")
        ok(trig(s, st, b) == f and st2 == 200 and st3 == 200, f"[{s}] fault {f}: fires once, then ends; the other model is untouched")
    setc(["m1", "m2"], [{"shape": s, "model": "m1", "fault": "model_gone", "calls": 1}])
    gone_listed = "m1" in listed(s); c(s, "m1")
    ok(not gone_listed and "m1" in listed(s), f"[{s}] model_gone with a call count: off the list, and back on it once its calls are used")
    setc(["m1", "m2"], [{"shape": s, "model": "m1", "fault": "model_gone"}])
    ok("m1" not in listed(s) and "m2" in listed(s), f"[{s}] a gone model leaves the model list")
    setc(["m1", "m2"], [{"shape": s, "model": "m1", "fault": "context_too_small", "tokens": 100}])
    st, _ = c(s, "m1"); st2, b2 = c(s, "m1", "word " * 2000)
    ok(st == 200 and trig(s, st2, b2) == "context_too_small", f"[{s}] context_too_small: short answers, long is refused")
    setc(["m1", "m2"], [{"shape": s, "model": "m1", "fault": "timeout", "seconds": 3}])
    t0 = time.time(); st, _ = c(s, "m1", "hi", 1); dt = time.time() - t0; st2, _ = c(s, "m2")
    ok(st is None and dt < 2.5 and st2 == 200, f"[{s}] timeout: no answer within 1 s, another model answers")
    setc(["m1", "m2"], [{"shape": s, "model": "m1", "fault": "malformed_tool_call", "calls": 1}])
    st, b = c(s, "m1"); tc = ptr(json.loads(b), protos[s]["response"]["tool_calls"])
    ok(st == 200 and "{not json" in json.dumps(tc), f"[{s}] malformed_tool_call answers 200 with unparseable arguments")
    st, b = c(s, "m1")
    ok(st == 200 and "not json" not in b, f"[{s}] and then is well-formed again")
    setc(["m1", "m2"], [])
    ok(c(s, "m1")[0] == 200, f"[{s}] cleared: answers")
st, b = http(f"{BASE}/_calls"); d = json.loads(b)
ok(all(d["counts"].get(k) == n for k, n in sent.items()) and sum(d["counts"].values()) == sum(sent.values()), "/_calls counts every call exactly")
ok(len(d["requests"]) == sum(sent.values()) and all(r["headers"].get("x-api-key", r["headers"].get("Authorization", "k-" + r["model"])).endswith("k-" + r["model"]) or "k-" + r["model"] in json.dumps(r["headers"]) for r in d["requests"]), "/_calls records each request with its headers")
# traits (F2b A): every shape, the extra one included; behavior comes from the control document and the shape's data
def tctl(s, tr, faults=()):
    return http(ctl, json.dumps({"models": {s: ["t1"]}, "faults": list(faults), "traits": [dict(tr, shape=s, model="t1")]}).encode())[0] == 200
V = json.dumps({"route": "work", "confidence": 0.9})
for s in protos:
    q, r = protos[s]["request"], protos[s]["response"]
    if r.get("logprobs"):
        tctl(s, {"answers": [V], "logprob": -0.5}); items = ptr(json.loads(call(s, "t1")[1]), r["logprobs"])
        ok("".join(i["token"] for i in items) == V and any(i["token"] == "work" and i["logprob"] == -0.5 for i in items), f"[{s}] logprob: tokens join to the answer, the label's token has the set value")
    tctl(s, {"recall_tokens": 100}); a = json.loads(call(s, "t1", "code AB1234 here")[1]); b = json.loads(call(s, "t1", "code AB1234 " + "x " * 800)[1])
    ok("AB1234" in ptr(a, r["text"]) and "AB1234" not in ptr(b, r["text"]), f"[{s}] recall_tokens: a needle is found in a short prompt and missed in a long one")
    tctl(s, {"answers": list("abcd"), "seed": 5}); x = [ptr(json.loads(call(s, "t1")[1]), r["text"]) for _ in range(10)]
    tctl(s, {"answers": list("abcd"), "seed": 5}); y = [ptr(json.loads(call(s, "t1")[1]), r["text"]) for _ in range(10)]
    ok(x == y and len(set(x)) > 1, f"[{s}] seed: answers vary and the same seed repeats them")
    ml = protos[s]["models_list"]; tctl(s, {"family": "fam", "version": "v9"})
    it = ptr(json.loads(listed(s)), ml["items"])[0]; ok(it.get(ml["family"]) == "fam" and it.get(ml["version"]) == "v9", f"[{s}] family and version show in the model list")
    for at in q.get("output_shape", {}).values():   # grammar: JSON back whenever the schema is sent, whatever the fault
        tctl(s, {"grammar": True}, [{"shape": s, "model": "t1", "fault": "non_json"}]); body = sub(q["body"], "t1")
        d = body
        for k in at.split("/")[1:-1]: d = d.setdefault(k, {})
        d[at.split("/")[-1]] = {"type": "object"}
        st, b = http(f"{BASE}/{s}{sub(q['path'], 't1')}", json.dumps(body).encode(), {**sub(q["headers"], "t1"), "Content-Type": "application/json"})
        t = ptr(json.loads(b), r["text"])
        try: json.loads(t); j = True
        except ValueError: j = False
        ok(st == 200 and j, f"[{s}] grammar: JSON answer with a schema at {at} though non_json is set")
        t2 = ptr(json.loads(call(s, "t1")[1]), r["text"])
        ok(t2 == "this is not json", f"[{s}] grammar: no schema in the request, the non_json fault reaches it")
print("\n".join(res)); sys.exit(any(r.startswith("FAIL") for r in res))
PY
python3 -I "$T/drive.py" "$T/out" "$R/.stella/protocols.json" >"$T/drive.out" 2>"$T/drive.err"; rc=$?
cat "$T/drive.out"; [ $rc = 0 ] || { fails=$((fails+1)); echo "FAIL the driver ended with exit $rc: $(tail -n 3 "$T/drive.err")"; }
# ---- the fake CLI ----
CF=$T/calls; cli() { echo "do it" | env SECRET_X=v1 MOCK_CLI_CALLS="$CF" "$@" python3 -I "$R/bin/mock_cli.py" --model m1 >"$T/o" 2>"$T/e"; }
cli MOCK_CLI_MODE=ok; ok '[ $? = 0 ]' "cli ok: exit 0"; ok 'jq -e ".result | type == \"string\"" "$T/o"' "cli ok: a result JSON"
cli MOCK_CLI_MODE=usage_limit; rc=$?; ok '[ $rc != 0 ] && cat "$T/o" "$T/e" | grep -qi limit' "cli usage_limit: non-zero and a limit message"
cli MOCK_CLI_MODE=model_gone; rc=$?; ok '[ $rc != 0 ] && grep -q m1 "$T/e"' "cli model_gone: non-zero and names the model"
echo x | env SECRET_X=v1 MOCK_CLI_MODE=timeout MOCK_CLI_SECONDS=4 MOCK_CLI_CALLS="$CF" timeout 1 python3 -I "$R/bin/mock_cli.py" >/dev/null 2>&1; rc=$?
ok '[ $rc = 124 ]' "cli timeout: hangs until the caller's timeout"
ok 'jq -se "length == 4 and all(.[]; (.env | index(\"SECRET_X\")) != null)" "$CF" && ! grep -q v1 "$CF"' "cli: one line per call, env names only"
echo "# mock-provider-selftest: $fails failed"; [ $fails = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
