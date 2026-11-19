#!/usr/bin/env bash
# Hermetic self-test for bin/levers.py (F2c item D): the batch lane, the stable-first prompt layout (tools only added), the cache policy per
# connection with the lifetime chosen from the measured gap, the prefix lint, the cache-hit rate per role, and the parallel-reviewer fan-out
# (a test double: the scheduler M1 does not exist yet) against the mock provider's cached tokens. In a scratch root (copy of bin, .stella,
# docs; its own HOME and temp). A fake connection with a cache policy and a batch flag is added as data: no code change.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/levers-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'kill $(jobs -p) 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "# KEPT $T"; else chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; fi' EXIT
R=$T/root; MR=$T/mockroot
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$MR" "$T/home" "$T/tmp" "$T/sup/logs" "$T/o" "$T/pb"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"; cp -r "$ROOT/.stella" "$ROOT/docs" "$MR/"
cd "$T" || exit 1
jq() { env -u HOME jq "$@"; }
IX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IX"; }
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$ROOT/$(ix .role_table)" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
for v in $(jq -r '.worker_signals.token_env[]?' "$R/$(ix '.files[] | select(.id == "owner-auth") | .path')" 2>/dev/null); do unset "$v"; done
cat >"$T/pb/hermes" <<'S'
#!/usr/bin/env bash
echo "[]"
S
chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH
AL=$T/sup/logs/alerts.log; : >"$AL"
fails=0
ok() { if ( eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
fixture() { echo "FIXTURE $1"; exit 3; }
ed() { local f=$R/.stella/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <data file> <jq args and filter>
uuid() { cat /proc/sys/kernel/random/uuid; }
LV() { python3 -I "$R/bin/levers.py" "$@"; }
PY() { python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); sys.argv = sys.argv[1:]; exec(sys.stdin.read())' "$R/bin" "$@"; }
export LED=$T/led.jsonl

# ---- fixture: a fake api connection with a batch flag and a cache policy, a fake local one, all as data ----
TPL='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "cloud" and (.aggregator | not))][0]'
mdl() { echo "{\"id\":\"$1\",\"capabilities\":{\"tool_calling\":true,\"json_mode\":true,\"context_tokens\":32768,\"vision\":false,\"streaming\":true},\"probed_at\":null,\"probe_source\":\"advertised\",\"cost\":null,\"limits\":null}"; }
ed connections.json --arg g "$(uuid)" --arg g2 "$(uuid)" --argjson m "$(mdl qa-m)" \
  ".entries += [($TPL + {id: \"qa-batch\", label: \"qa-batch\", enabled: true, global_id: \$g, models: [\$m], secrets: [], hosts: []} | del(.protocol)),
   ($TPL + {id: \"qa-plain\", label: \"qa-plain\", enabled: true, global_id: \$g2, models: [\$m], secrets: [], hosts: []} | del(.protocol))]"
II=$(jq -r .install_id "$R/.stella/install.json")
ed levers.json --arg g "$(uuid)" --arg ii "$II" '.entries += [{global_id: $g, install_id: $ii, id: "qa-batch-row", connection: "qa-batch", batch: true, cache: {kind: "breakpoints", breakpoints: ["after_tools", "after_stable"], lifetimes: [{id: "short", seconds: 60}, {id: "mid", seconds: 600}, {id: "long", seconds: 7200}]}}]'
python3 -I -B "$R/bin/stella_data.py" check >"$T/o/fx" 2>&1 || fixture "the scratch data does not pass check: $(head -c 400 "$T/o/fx")"
KIND0=$(jq -r '.batch_kinds[0]' "$R/.stella/levers.json"); [ -n "$KIND0" ] && [ "$KIND0" != null ] || fixture "the shipped levers file lists no batch kind"
LOCAL=$(jq -r '.entries[] | select(.cache.kind == "server-prefix") | .connection' "$R/.stella/levers.json" | head -1)
lane() { echo "$1" | LV lane --json; }

# ---- T-CORE-LEVERS: the data file ----
ok 'python3 -I -B "$R/bin/stella_data.py" check && LV check --json | jq -e ".ok == true"' "D1 the shipped levers file passes the data check and levers.py check"
ok 'jq -e "(.batch_kinds | length) >= 4 and .fanout.first_token_timeout_s > 0 and (.about | test(\"M1\"))" "$R/.stella/levers.json"' "D2 the file lists the batch kinds, the fan-out timeout, and its about says the scheduler M1 is a test double"
ok '[ -n "$LOCAL" ] && [ "$LOCAL" != null ]' "D3 a local link has the server-prefix policy kind in the shipped data"
cp "$R/.stella/levers.json" "$T/levers.bak"
ed levers.json --arg g "$(uuid)" '.entries += [.entries[0] + {id: "dup", global_id: $g}]'; LV check --json >"$T/o/d4" 2>/dev/null; rc=$?
ok '[ $rc = 1 ] && jq -e ".code == \"STL-LIM-440\"" "$T/o/d4"' "D4 a connection with two rows is refused with STL-LIM-440"
cp "$T/levers.bak" "$R/.stella/levers.json"
ed levers.json '(.entries[] | select(.id == "qa-batch-row") | .cache.lifetimes) |= reverse'; LV check --json >"$T/o/d5" 2>/dev/null; rc=$?
ok '[ $rc = 1 ] && jq -e ".code == \"STL-LIM-440\"" "$T/o/d5"' "D5 lifetimes that are not shortest first are refused with STL-LIM-440"
cp "$T/levers.bak" "$R/.stella/levers.json"; ed levers.json '(.entries[] | select(.id == "qa-batch-row") | .cache.lifetimes) = [{id: "short", seconds: 60}, {id: "mid", seconds: 600}, {id: "long", seconds: 7200}]'

# ---- T-LEV-BATCH ----
ok 'lane "{\"kind\":\"$KIND0\",\"connection\":\"qa-batch\"}" | jq -e ".lane == \"batch\" and .batch == true"' "B1 an eligible kind on a batch connection that is not urgent goes to the batch lane (batch:true, for the usage record)"
ok 'for k in $(jq -r ".batch_kinds[]" "$R/.stella/levers.json"); do for u in true "\"yes\"" 1; do lane "{\"kind\":\"$k\",\"connection\":\"qa-batch\",\"urgent\":$u}" | jq -e ".lane == \"live\" and .batch == false" || exit 1; done; done' "B2 an urgent job never goes to batch, whatever its kind (every kind of the data, urgent as true, a word, a number)"
ok 'lane "{\"kind\":\"$KIND0\",\"connection\":\"qa-batch\",\"urgent\":false}" | jq -e ".batch == true"' "B3 urgent false is not urgent"
ok 'lane "{\"kind\":\"not-a-batch-kind\",\"connection\":\"qa-batch\"}" | jq -e ".batch == false"' "B4 a kind the data does not list stays live"
ok 'lane "{\"kind\":\"$KIND0\",\"connection\":\"qa-plain\"}" | jq -e ".batch == false" && lane "{\"kind\":\"$KIND0\",\"connection\":\"no-such\"}" | jq -e ".batch == false"' "B5 a connection that does not offer batch (or is unknown) stays live"
ok 'echo "{\"connection\":\"qa-batch\"}" | LV lane --json; [ $? = 1 ]' "B6 a job with no kind is refused (exit 1)"
ok 'PY <<"E"
import levers
t = levers.load()
j = {"kind": levers.sd.load(".stella/levers.json")["batch_kinds"][0], "connection": "qa-batch"}
r = levers.lane(j, t)
rec = {"v": 1, "batch": r["batch"]}
assert rec["batch"] is True
assert levers.lane(dict(j, urgent=True), t)["batch"] is False
E' "B7 lane() as a module: the caller copies batch into the usage record"

# ---- T-LEV-HIT ----
rec() { jq -nc --arg r "$1" --arg c "$2" --arg ts "$3" --argjson i "$4" --argjson cr "$5" --argjson cw "$6" '{v:1, id:"u", install_id:"i", ts:$ts, connection:$c, model:"qa-m", role:$r, project:"p", card:"c", session:"s", kind:"call", outcome:"ok", status:200, tokens:{input:$i, output:5, cache_write:$cw, cache_read:$cr, reasoning:0}, latency_ms:10, batch:false, cost:null, plan_share:null}'; }
{ rec r-a qa-batch 2026-11-18T10:00:00Z 100 0 100; rec r-a qa-batch 2026-11-18T10:05:00Z 0 200 0; rec r-b qa-batch 2026-11-18T10:06:00Z 100 0 0; echo 'torn line'; } >"$LED"
LV hitrate --by role --records "$LED" --json >"$T/o/h1"; rc=$?
ok '[ $rc = 0 ] && jq -e ".by == \"role\" and .groups[\"r-a\"] == 0.5 and .groups[\"r-b\"] == 0 and .skipped == 1" "$T/o/h1"' "H1 the cache-hit rate per role is cache_read over input+cache_read+cache_write, through cost.cache_hit_rate (a torn line is counted, not fatal)"
ok 'LV hitrate --by project --records "$LED" --json | jq -e ".groups.p > 0"' "H2 --by takes the other keys"
ok 'LV hitrate --by nonsense --records "$LED" --json; [ $? = 1 ]' "H3 an unknown --by is refused (exit 1)"
ok 'cp "$LED" "$R/.supervisor/state/usage.jsonl" && LV hitrate --by role --json | jq -e ".groups[\"r-a\"] == 0.5"' "H4 with no --records the ledger file of the index is read"

# ---- cache policy ----
gaps() { for i in 0 1 2 3 4 5 6 7 8 9; do rec r-a "$1" "$(date -u -d @$((1763460000 + i * $2)) +%Y-%m-%dT%H:%M:%SZ)" 1 0 0; done >"$LED"; }
pol() { LV policy --connection "$1" --records "$LED" --json; }
gaps qa-batch 30; ok 'pol qa-batch | jq -e ".kind == \"breakpoints\" and .lifetime == \"short\" and .gap_seconds == 30 and .breakpoints == [\"after_tools\", \"after_stable\"]"' "P1 the shortest lifetime of the data that covers the measured gap (30 s -> short)"
gaps qa-batch 300; ok 'pol qa-batch | jq -e ".lifetime == \"mid\" and .gap_seconds == 300"' "P2 300 s gap -> the next lifetime that covers it"
gaps qa-batch 9000; ok 'pol qa-batch | jq -e ".lifetime == null and .covered == false"' "P3 a gap no allowed lifetime covers: no lifetime (a cache write would never be read)"
: >"$LED"; ok 'pol qa-batch | jq -e ".lifetime == \"short\" and .gap_seconds == null"' "P4 no measurement: the shortest lifetime, gap null"
gaps "$LOCAL" 30; ok 'pol "$LOCAL" | jq -e ".kind == \"server-prefix\" and .lifetime == null and (.breakpoints | length) == 0"' "P5 a local link uses the model server prefix cache: no breakpoints, no lifetime"
gaps qa-plain 30; ok 'pol qa-plain | jq -e ".kind == \"breakpoints\" and .lifetime != null and .source == \"default\"" && pol qa-batch | jq -e ".source == \"entry\""' "P6 a connection with no row gets the default policy (source default)"
ok 'PY <<"E"
import levers
t = levers.load()
recs = [{"connection": "qa-batch", "role": "x", "ts": "2026-11-18T10:00:00Z"}, {"connection": "qa-batch", "role": "x", "ts": "2026-11-18T10:00:30Z"},
        {"connection": "other", "role": "x", "ts": "2026-11-18T11:00:00Z"}, {"connection": "qa-batch", "role": "x", "ts": "bad"}]
assert levers.gap_seconds(recs, "qa-batch") == 30
assert levers.gap_seconds(recs, "none") is None
E' "P7 the gap is measured per connection from the ledger records, other connections and bad timestamps left out"

# ---- prompt layout ----
ok 'PY <<"E"
import levers
t = levers.load()
tools = [{"name": "t1", "description": "d", "schema": {"b": 1, "a": 2}}]
def build(task, tl=tools, extra="x"):
    parts = [{"name": "task", "stable": False, "value": task}, {"name": "role", "stable": True, "value": "role text"},
             {"name": "rules", "stable": True, "value": {"z": 1, "a": [1, 2]}}] + levers.tool_parts(tl) + [{"name": "ev", "stable": True, "value": extra}]
    return levers.layout(parts, levers.policy_of("qa-batch", t))
a, b = build("task one"), build("task two")
assert [p["name"] for p in a["parts"]] == ["role", "rules", "tool:t1", "ev", "task"], [p["name"] for p in a["parts"]]
assert a["prefix"] == b["prefix"] and a["prefix_sha256"] == b["prefix_sha256"] and a["text"] != b["text"]
assert a["text"].startswith(a["prefix"])
assert a["parts"][1]["text"] == "{\"a\":[1,2],\"z\":1}", a["parts"][1]["text"]
tools2 = [{"schema": {"a": 2, "b": 1}, "description": "d", "name": "t1"}]
assert build("task one", tools2)["prefix"] == a["prefix"]
assert a["breakpoints"] == [2, 3], a["breakpoints"]
E' "Y1 stable parts come first in the given order, changing parts last; canonical serialization (sorted keys, no spaces) so the prefix is byte-identical for the same content whatever the key order; breakpoints follow the policy"
ok 'PY <<"E"
import levers
t = levers.load()
loc = levers.policy_of(next(e["connection"] for e in t["entries"] if e["cache"]["kind"] == "server-prefix"), t)
r = levers.layout([{"name": "p", "stable": True, "value": "v"}, {"name": "q", "stable": False, "value": "w"}], loc)
assert r["breakpoints"] == [] and r["parts"][0]["name"] == "p"
E' "Y2 a server-prefix link gets the same stable-first layout and no breakpoints"
ok 'PY <<"E"
import levers
a = {"name": "a", "description": "x"}; b = {"name": "b", "description": "y"}
assert levers.next_tools([], [a]) == [a]
assert levers.next_tools([a], [a, b]) == [a, b]
assert levers.next_tools([a, b], [b, a, {"name": "c"}]) == [a, b, {"name": "c"}]
for bad in ([b], [], [dict(a, description="changed"), b]):
    try:
        levers.next_tools([a, b], bad)
    except levers.Stop as e:
        assert e.code == "STL-LIM-441", e.code
    else:
        raise SystemExit("no refusal for %r" % (bad,))
E' "Y3 tools are only added within a session: a removal or a changed definition is refused with STL-LIM-441"
ok 'PY <<"E"
import levers
try:
    levers.layout([{"name": "p", "stable": True, "value": "v"}, {"name": "p", "stable": False, "value": "w"}], levers.policy_of(None, levers.load()))
except levers.Stop as e:
    assert e.code == "STL-LIM-444"
else:
    raise SystemExit("a part name twice was taken")
E' "Y4 a part name twice is refused (STL-LIM-444)"

# ---- T-LEV-LINT ----
mk() {  # <dir> <n> <rules text> [tools json]: one prompt file of the layout
  mkdir -p "$1"; PY "$2" "$3" "${4:-[]}" "$1" <<'E'
import json, sys, levers
n, rules, tools, d = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4]
p = levers.layout([{"name": "role", "stable": True, "value": "role text"}, {"name": "rules", "stable": True, "value": rules}] + levers.tool_parts(tools)
                  + [{"name": "task", "stable": False, "value": "task " + n}], levers.policy_of(None, levers.load()))
open(f"{d}/p{n}.json", "w").write(json.dumps(p))
E
}
mk "$T/l1" 1 "be careful"; mk "$T/l1" 2 "be careful"; mk "$T/l1" 3 "be careful" '[{"name":"t1"}]'
LV lint-prefix "$T/l1" --json >"$T/o/l1"; rc=$?
ok '[ $rc = 0 ] && jq -e ".ok == true and .compared == 2" "$T/o/l1"' "L1 consecutive prompts with the same stable part pass (a changing last part and an added tool are no change of the prefix)"
mk "$T/l2" 1 "be careful, 2026-11-18T10:00:00Z"; mk "$T/l2" 2 "be careful, 2026-11-18T10:05:00Z"
LV lint-prefix "$T/l2" --json >"$T/o/l2" 2>"$T/o/l2.err"; rc=$?
ok '[ $rc = 1 ] && jq -e ".code == \"STL-LIM-442\" and (.problem | test(\"rules\"))" "$T/o/l2"' "L2 a planted timestamp in the stable part fails the lint with STL-LIM-442 and names the part"
mk "$T/l3" 1 "be careful, run r-0001"; mk "$T/l3" 2 "be careful, run r-0002"
LV lint-prefix "$T/l3" --json >"$T/o/l3" 2>/dev/null; rc=$?
ok '[ $rc = 1 ] && jq -e ".code == \"STL-LIM-442\"" "$T/o/l3"' "L3 a planted run id in the stable part fails the lint"
mk "$T/l4" 1 "be careful" '[{"name":"t1"},{"name":"t2"}]'; mk "$T/l4" 2 "be careful" '[{"name":"t1"}]'
LV lint-prefix "$T/l4" --json >"$T/o/l4" 2>/dev/null; rc=$?
ok '[ $rc = 1 ] && jq -e ".code == \"STL-LIM-442\"" "$T/o/l4"' "L4 a tool removed between prompts fails the lint"
ok 'LV lint-prefix "$T/l2/p1.json" "$T/l2/p2.json" --json; [ $? = 1 ]; LV lint-prefix "$T/l1/p1.json" "$T/l1/p2.json" --json' "L5 the lint takes files as well as a folder"
ok 'echo "{\"parts\":[{\"name\":\"a\",\"stable\":false,\"text\":\"x\"},{\"name\":\"b\",\"stable\":true,\"text\":\"y\"}]}" >"$T/bad.json"; LV lint-prefix "$T/bad.json" --json; [ $? = 1 ]' "L6 a stable part after a changing part (no prefix) fails even for one prompt"
ok 'LV lint-prefix "$T/nonexistent" --json; [ $? = 1 ]' "L7 a path that is not there is refused with exit 1"

# ---- T-LEV-FANOUT: three mock reviewers, one cache write, two cache reads ----
STELLA_ROOT=$MR python3 -I "$R/bin/mock_provider.py" >"$T/mock.out" 2>"$T/mock.err" &
for _ in $(seq 100); do [ -s "$T/mock.out" ] && break; sleep 0.1; done
MPORT=$(jq -r '.port' "$T/mock.out" 2>/dev/null); CTL=$(jq -r '.control' "$T/mock.out" 2>/dev/null)
[ -n "$MPORT" ] && [ "$MPORT" != null ] || fixture "the mock did not start: $(head -c 300 "$T/mock.err")"
export CTL MPORT
ok 'PY <<"E"
import json, os, threading, time, urllib.request, levers, cost, stella_data as sd
op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def post(url, doc):
    return json.loads(op.open(urllib.request.Request(url, data=json.dumps(doc).encode(), method="POST"), timeout=10).read().decode())
shapes = {e["id"]: e for e in sd.checked(sd.load(".stella/protocols.json"), ".stella/protocols.json", "protocols")["entries"]}
sid, shape = next((i, e) for i, e in shapes.items() if {"cache_write", "cache_read"} <= set(e["response"].get("usage_extra") or {}))
url = "http://127.0.0.1:" + os.environ["MPORT"] + "/" + sid + shape["request"]["path"].replace("{model}", "t1")
trait = lambda w, r: post(os.environ["CTL"], {"models": {sid: ["t1"]}, "faults": [], "traits": [{"shape": sid, "model": "t1", "cache_write": w, "cache_read": r}]})
trait(900, 0)
log = []
def send(prompt, reviewer, first_token):
    log.append(("start", reviewer["id"], time.monotonic()))
    got = post(url, {"model": "t1", "messages": [{"role": "user", "content": prompt}], "max_tokens": 5})
    u = cost.usage_of(shape, got)
    if reviewer["id"] == "rev-1":
        trait(0, 900)   # the provider has the cache now: every later call reads it
        log.append(("token", "rev-1", time.monotonic()))
        first_token.set()
    return {"id": reviewer["id"], "usage": u}
shared = [{"name": "rules", "stable": True, "value": "rules of review"}] + levers.tool_parts([{"name": "t1", "description": "d"}]) + [
          {"name": "evidence", "stable": True, "value": {"checks": ["a", "b"]}}, {"name": "diff", "stable": True, "value": "frozen diff"}]
revs = [{"id": f"rev-{i}", "instructions": f"look at aspect {i}"} for i in (1, 2, 3)]
res = levers.fanout(shared, revs, send, levers.policy_of("qa-batch", levers.load()), timeout=10)
assert [r["id"] for r in res] == ["rev-1", "rev-2", "rev-3"]
assert res[0]["usage"]["cache_write"] > 0 and res[0]["usage"]["cache_read"] == 0, res[0]
for r in res[1:]:
    assert r["usage"]["cache_read"] > 0 and r["usage"]["cache_write"] == 0, r
tok = next(t for k, i, t in log if k == "token")
assert all(t >= tok for k, i, t in log if k == "start" and i != "rev-1"), log   # the others start after the first token
calls = json.loads(op.open("http://127.0.0.1:" + os.environ["MPORT"] + "/_calls", timeout=10).read().decode())["requests"]
texts = [r["body"]["messages"][0]["content"] for r in calls]
assert len(texts) == 3
pre = levers.layout(shared + [{"name": "i", "stable": False, "value": "x"}], levers.policy_of("qa-batch", levers.load()))["prefix"]
for t, r in zip(sorted(texts), revs):
    assert t.startswith(pre + "\n") and t.endswith(r["instructions"]) and "frozen diff" in pre and "rules of review" in pre, t
E' "F1 three mock reviewers: the first call writes the cache (cache_write > 0), it is waited for until its first token, then the other two read it (cache_read > 0, cache_write 0); the prefix (rules, tools, evidence, diff) is byte-identical and the role instructions come last"
ok 'PY <<"E"
import levers, threading
def send(prompt, reviewer, ft):
    raise RuntimeError("boom")
pol = levers.policy_of(None, levers.load())
for s in (send, lambda p, r, ft: {"id": r["id"]}):   # a first call that fails, and one that never signals its first token
    try:
        levers.fanout([{"name": "rules", "stable": True, "value": "r"}], [{"id": "a", "instructions": "x"}, {"id": "b", "instructions": "y"}], s, pol, timeout=0.5)
    except levers.Stop as e:
        assert e.code == "STL-LIM-443"
    else:
        raise SystemExit("fan-out went on without a first token")
E' "F2 a first call that fails or never signals a first token stops the fan-out with STL-LIM-443 (the others are not sent)"
ok 'PY <<"E"
import levers
pol = levers.policy_of(None, levers.load())
calls = []
def send(p, r, ft):
    calls.append(r["id"]); ft.set(); return r["id"]
assert levers.fanout([{"name": "rules", "stable": True, "value": "r"}], [{"id": "only", "instructions": "x"}], send, pol, timeout=1) == ["only"]
assert levers.fanout([{"name": "rules", "stable": True, "value": "r"}], [], send, pol, timeout=1) == []
E' "F3 one reviewer is just sent; none is an empty list"

# ---- the rules are data: change the file, the behavior follows ----
irr() { : >"$LED"; for o in 0 30 60 90 120 150 180 210 240 9240; do rec r-a qa-batch "$(date -u -d @$((1763460000 + o)) +%Y-%m-%dT%H:%M:%SZ)" 1 0 0 >>"$LED"; done; }
irr; ok 'pol qa-batch | jq -e ".lifetime == null and .gap_seconds == 9000"' "R1 the lifetime covers the data's share of the gaps (90 percent: the one long gap of ten decides, no lifetime covers it)"
cp "$R/.stella/levers.json" "$T/levers.keep"; ed levers.json '.lifetime_gap_percentile = 50'
ok 'pol qa-batch | jq -e ".lifetime == \"short\" and .gap_seconds == 30"' "R2 the percentile is data: 50 gives the median gap"
ed levers.json '.layout.order = ["changing", "stable"]'
ok 'PY <<"E"
import levers
t = levers.load()
r = levers.layout([{"name": "a", "stable": True, "value": "s"}, {"name": "b", "stable": False, "value": "c"}], levers.policy_of(None, t), t)
assert [p["name"] for p in r["parts"]] == ["b", "a"]
E' "R3 the part order is data"
cp "$T/levers.keep" "$R/.stella/levers.json"
mkdir -p "$T/v1"; echo "{\"parts\":[{\"name\":\"rules\",\"stable\":true,\"text\":\"as of 2026-11-18 10:00\"}]}" >"$T/v1/p1.json"
LV lint-prefix "$T/v1" --json >"$T/o/v1" 2>/dev/null; rc=$?
ok '[ $rc = 1 ] && jq -e ".code == \"STL-LIM-442\" and (.problem | test(\"timestamp\"))" "$T/o/v1"' "R4 one prompt with a timestamp in a stable part fails the lint (the volatile patterns are data)"
ed levers.json '.lint.volatile_patterns = []'; LV lint-prefix "$T/v1" --json >/dev/null 2>&1; rc=$?
ok '[ $rc = 0 ]' "R5 with the patterns removed from the data the same prompt passes"
cp "$T/levers.keep" "$R/.stella/levers.json"
ed levers.json '.lint.volatile_patterns += [{id: "bad", pattern: "("}]'; LV check --json >"$T/o/r6" 2>/dev/null; rc=$?
ok '[ $rc = 1 ] && jq -e ".code == \"STL-LIM-440\"" "$T/o/r6"' "R6 a pattern that is no regular expression is refused with STL-LIM-440"
cp "$T/levers.keep" "$R/.stella/levers.json"

# ---- T-CORE-LEVERS: fake entry, codes, CLI contract ----
ok 'for c in 440 441 442 443 444; do jq -e --arg c "STL-LIM-$c" "[.alerts[].code] | index(\$c)" "$R/docs/hermes-local/alert-catalog.json" || exit 1; done' "C1 the codes STL-LIM-440..444 are in the alert catalog"
: >"$LED"
ok 'lane "{\"kind\":\"$KIND0\",\"connection\":\"qa-batch\"}" | jq -e ".batch == true" && pol qa-batch | jq -e ".lifetime != null"' "C2 fake entry: a new connection with a cache policy and a batch flag, added as data only, is used with no code change"
LV --help >/dev/null 2>&1; rc=$?; ok '[ $rc = 0 ]' "C3 --help exits 0"
LV >/dev/null 2>&1; rc=$?; ok '[ $rc = 2 ]' "C4 no command is a usage error (exit 2)"
echo "not json" | LV lane --json >"$T/o/c5" 2>"$T/o/c5.err"; rc=$?
ok '[ $rc = 1 ] && jq -e ".code == \"STL-LIM-444\"" "$T/o/c5" && grep -q STL-LIM-444 "$T/o/c5.err"' "C5 an unreadable job is exit 1 with the catalog code on stdout and its plain message on stderr"
ok '! grep -rn "qa-batch\|qa-plain" "$ROOT/bin/levers.py"' "C6 no connection id of the fixture is in the code"

echo "# levers-selftest: $fails failed"; [ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
