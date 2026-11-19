#!/usr/bin/env bash
# Hermetic self-test for bin/cost.py (F2c item B): the dated pricing table (.stella/pricing.json), price() with five token types, the
# GenAI span and its spans file, rollups and the cache-hit rate, the OTLP export behind the otlp-export flag, usage_of() over the wire
# shapes (with the mock's cached and reasoning tokens). In a scratch root (copy of bin, .stella, docs; its own HOME, temp, loopback
# listener and folder key backend). Fake connections and fake prices are added as data: a new model is priced with no code change.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/cost-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
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
CO() { python3 -I "$R/bin/cost.py" "$@"; }
PY() { python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); sys.argv = sys.argv[1:]; exec(sys.stdin.read())' "$R/bin" "$@"; }   # python on stdin, the module path set
export LED=$T/led.jsonl RJSON=$T/r.json

# ---- fixture: a key, fake connections (an api link, a cli-login link, a local listener as the OTLP backend), the pricing rows ----
KN=ST_FAKE_KEY; KEY="stkey$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
CD=$(ix .backup_dir)/st-keys; mkdir -p "$R/$CD"; chmod 700 "$R/$CD"; (umask 077; printf '%s' "$KEY" >"$R/$CD/$KN")
ed routing.json --arg p "$CD" '.credentials.backend = "st-dir" | .credentials.backends["st-dir"] = {kind: "dir", path: $p}'
TPL='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "cloud" and (.aggregator | not))][0]'
CLI='[.entries[] | select(.kind == "provider" and .type == "cli-login")][0]'
mdl() { echo "{\"id\":\"$1\",\"capabilities\":{\"tool_calling\":true,\"json_mode\":true,\"context_tokens\":32768,\"vision\":false,\"streaming\":true},\"probed_at\":null,\"probe_source\":\"advertised\",\"cost\":null,\"limits\":null}"; }
cat >"$T/listen.py" <<'P'
import http.server, json, socket, sys
host = socket.inet_ntoa(b"\x7f\x00\x00\x01")
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        with open(sys.argv[1], "a") as f: f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"), "body": raw}) + "\n")
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
s = http.server.ThreadingHTTPServer((host, 0), H)
print(s.server_address[1], flush=True); s.serve_forever()
P
python3 -I "$T/listen.py" "$T/got.jsonl" >"$T/listen.out" 2>/dev/null &
for _ in $(seq 50); do [ -s "$T/listen.out" ] && break; sleep 0.1; done
LP=$(cat "$T/listen.out"); [ -n "$LP" ] || fixture "the listener did not start"
LO=127.0.0.1; export NO_PROXY=$LO no_proxy=$LO
ed connections.json --arg g "$(uuid)" --arg g2 "$(uuid)" --arg g3 "$(uuid)" --arg h "$LO" --argjson p "$LP" --arg k "$KN" --argjson m "$(mdl qa-m)" --argjson n "$(mdl qa-n)" \
  ".entries += [$TPL + {id: \"qa-p\", label: \"qa-p\", enabled: true, global_id: \$g, models: [\$m, \$n], secrets: [], hosts: []} | del(.protocol),
   $CLI + {id: \"qa-cli\", label: \"qa-cli\", enabled: true, global_id: \$g2, models: [\$m]},
   $TPL + {id: \"qa-otlp\", kind: \"app\", subkind: \"otlp-export\", label: \"qa-otlp\", enabled: true, locality: \"local\", global_id: \$g3, models: [], secrets: [\$k], hosts: [{host: \$h, port: \$p, purpose: \"traces\"}]} | del(.protocol)]"
python3 -I -B "$R/bin/stella_data.py" check >"$T/o/fx" 2>&1 || fixture "the scratch data does not pass check: $(head -c 400 "$T/o/fx")"
PRC=$R/$(ix '.files[] | select(.id == "pricing") | .path')
SP=$R/$(ix .spans)
row() {  # <id> <effective_from> <input price>: a fake price row for qa-p/qa-m (fake numbers, a scratch root only)
  jq -n --arg id "$1" --arg d "$2" --argjson i "$3" --arg g "$(uuid)" --arg ii "$(jq -r .install_id "$R/.stella/install.json")" \
   '{id: $id, connection: "qa-p", model: "qa-m", effective_from: $d, source: "qa fixture", currency: "QAC", per_million: {input: $i, output: 15, cache_write: 3.75, cache_read: 0.3, reasoning: 15}, batch_discount: 0.5, global_id: $g, install_id: $ii}'
}
jq --argjson r "[$(row r1 2026-01-01 3), $(row r2 2026-06-01 5)]" '.entries = $r' "$PRC" >"$PRC.n" && mv "$PRC.n" "$PRC"
rec() {  # <connection> <model> <ts> [extra jq object]: a usage record
  local x=${4:-}; [ -n "$x" ] || x='{}'
  jq -nc --arg c "$1" --arg m "$2" --arg ts "$3" --argjson x "$x" '{v:1, id:"u1", install_id:"i", ts:$ts, connection:$c, model:$m, role:"r-a", project:"p-a", card:"c-1", session:"s", kind:"call",
   outcome:"ok", status:200, tokens:{input:1000000, output:2000000, cache_write:500000, cache_read:4000000, reasoning:250000}, latency_ms:1500, batch:false, cost:null, plan_share:null} + $x'
}
price() { rec "$@" | CO price --json 2>"$T/o/price.err"; }
amt() { jq -r '.cost.amount' <<<"$1"; }

# ---- T-COST-TABLE: the dated table is data ----
ok 'CO check --json >"$T/o/chk" && jq -e ".ok == true and .entries == 2" "$T/o/chk"' "T1 check passes a table of two dated rows for a catalog link"
ok 'jq -e ".schema_version == 1 and (.entries | type == \"array\")" "$ROOT/.stella/pricing.json"' "T2 the shipped file has schema_version 1 and an entries list (no invented prices)"
cp "$PRC" "$T/prc.keep"
ed pricing.json '.entries[0].per_million.input = -1'; ok '! CO check --json >"$T/o/c2" && jq -e ".code == \"STL-LIM-421\"" "$T/o/c2"' "T3 a negative price fails check with STL-LIM-421"
cp "$T/prc.keep" "$PRC"; ed pricing.json '.entries[1].effective_from = .entries[0].effective_from'; ok '! CO check --json >"$T/o/c3"' "T4 two rows of one link and date fail check"
cp "$T/prc.keep" "$PRC"; ed pricing.json '.entries[0].connection = "no-such-connection"'; ok '! CO check --json >"$T/o/c4"' "T5 a row for a link the catalog lacks fails check"
cp "$T/prc.keep" "$PRC"

# ---- T-COST-PRICE ----
A=$(price qa-p qa-m 2026-03-01T00:00:00Z)
ok '[ "$(amt "$A")" = 39.825 ] && jq -e ".cost.priced == true and .cost.entry == \"r1\" and .cost.currency == \"QAC\"" <<<"$A"' "P1 the five token types are priced separately (3+30+1.875+1.2+3.75)"
ok '[ "$(amt "$(price qa-p qa-m 2026-07-01T00:00:00Z)")" = 41.825 ] && [ "$(price qa-p qa-m 2026-06-01T00:00:00Z | jq -r .cost.entry)" = r2 ]' "P2 the newest row whose effective_from is not after the call applies (r2 from its own date)"
ok '[ "$(price qa-p qa-m 2026-03-01T00:00:00Z "{\"batch\":true}" | jq -r .cost.amount)" = 19.9125 ]' "P3 a batch call takes the row's batch discount off"
ok '[ "$(price qa-p qa-m 2026-03-01T00:00:00Z "{\"tokens\":{\"input\":0,\"output\":0,\"cache_write\":0,\"cache_read\":0,\"reasoning\":1000000}}" | jq -r .cost.amount)" = 15 ]' "P4 reasoning tokens are billed at the row's reasoning price"
ed pricing.json '.entries[0].per_million.input = 6'
ok '[ "$(amt "$(price qa-p qa-m 2026-03-01T00:00:00Z)")" = 42.825 ]' "P5 editing the table file changes the cost with no code change"
cp "$T/prc.keep" "$PRC"
B=$(price qa-cli qa-m 2026-03-01T00:00:00Z '{"plan_share":0.25}')
ok 'jq -e ".cost == null and .plan_share == 0.25" <<<"$B"' "P6 a cli-login record has cost null and keeps its plan share"
n0=$(grep -c "STL-LIM-420" "$AL"); U=$(price qa-p qa-n 2026-03-01T00:00:00Z)
ok 'jq -e ".cost.priced == false and .cost.amount == null and .cost.entry == null" <<<"$U" && [ "$(grep -c STL-LIM-420 "$AL")" = "$((n0+1))" ]' "P7 a model with no row is unpriced (amount null, never a guess) with one STL-LIM-420 alert"
ok 'PY <<"E" | grep -qx 1
import cost, os
t = cost.load_table()
r = {"connection": "qa-p", "model": "qa-n", "ts": "2026-03-01T00:00:00Z", "tokens": {"input": 1, "output": 1, "cache_write": 0, "cache_read": 0, "reasoning": 0}, "batch": False}
log = os.environ["ESCALATE_SUP_DIR"] + "/logs/alerts.log"
a = open(log).read().count("STL-LIM-420")
cost.price(r, t); cost.price(r, t); cost.price(dict(r), t)
print(open(log).read().count("STL-LIM-420") - a)
E' "P8 a module run alerts once per unpriced model, not once per call"
# the fake-entry test: a model nobody coded for gets a row and is priced; no code is edited
ed connections.json --argjson n "$(mdl qa-new)" '(.entries[] | select(.id == "qa-p") | .models) += [$n]'
jq --argjson r "$(row r9 2026-01-01 8 | jq '.model = "qa-new"')" '.entries += [$r]' "$PRC" >"$PRC.n" && mv "$PRC.n" "$PRC"
ok '[ "$(amt "$(price qa-p qa-new 2026-03-01T00:00:00Z)")" = 44.825 ] && CO check --json >/dev/null' "P9 fake-entry: a new model plus one pricing row is priced with no code change"
cp "$T/prc.keep" "$PRC"

# ---- T-COST-SPAN: the GenAI span and the spans file ----
rec qa-p qa-m 2026-03-01T00:00:00Z '{"cost":{"amount":39.825,"currency":"QAC","entry":"r1","priced":true},"batch":true}' >"$RJSON"
CO span --json --record "$RJSON" >"$T/o/span"; ok '[ ! -e "$SP" ]' "S1 span without --write writes no file"
ok 'jq -e ".attributes | (keys | sort) == ([\"gen_ai.operation.name\",\"gen_ai.request.model\",\"gen_ai.provider.name\",\"gen_ai.usage.input_tokens\",\"gen_ai.usage.output_tokens\",\"gen_ai.usage.cache_creation.input_tokens\",\"gen_ai.usage.cache_read.input_tokens\",\"gen_ai.usage.reasoning.output_tokens\",\"stella.role\",\"stella.project\",\"stella.card\",\"stella.cost\",\"stella.batch\"] | sort)" "$T/o/span"' "S2 the span carries exactly the GenAI attribute names of the design"
ok 'jq -e ".attributes | .[\"gen_ai.provider.name\"] == \"qa-p\" and .[\"gen_ai.request.model\"] == \"qa-m\" and .[\"gen_ai.usage.cache_creation.input_tokens\"] == 500000 and .[\"gen_ai.usage.reasoning.output_tokens\"] == 250000 and .[\"stella.batch\"] == true and .[\"stella.cost\"] == 39.825" "$T/o/span"' "S3 attribute values come from the record (connection as provider, five token counts, cost, batch)"
CO span --json --write --record "$RJSON" >/dev/null; CO span --json --write --record "$RJSON" >/dev/null
ok '[ "$(wc -l <"$SP")" = 2 ] && jq -e ".attributes" "$SP"' "S4 --write appends one JSON line per call to the file of index key spans"

# ---- T-COST-ROLLUP ----
{ rec qa-p qa-m 2026-03-01T00:00:00Z '{"id":"a","role":"r-a","card":"c-1","tokens":{"input":100,"output":10,"cache_write":100,"cache_read":300,"reasoning":0},"cost":{"amount":1.5,"currency":"QAC","entry":"r1","priced":true}}'
  rec qa-p qa-m 2026-03-01T00:00:00Z '{"id":"b","role":"r-a","card":"c-2","tokens":{"input":100,"output":10,"cache_write":0,"cache_read":0,"reasoning":5},"cost":{"amount":0.5,"currency":"QAC","entry":"r1","priced":true}}'
  rec qa-cli qa-m 2026-03-01T00:00:00Z '{"id":"c","role":"r-b","card":"c-1","tokens":{"input":50,"output":5,"cache_write":0,"cache_read":50,"reasoning":0},"cost":null,"plan_share":0.1}'
  rec qa-p qa-n 2026-03-01T00:00:00Z '{"id":"d","role":"r-b","card":null,"tokens":{"input":10,"output":1,"cache_write":0,"cache_read":0,"reasoning":0},"cost":{"amount":null,"currency":null,"entry":null,"priced":false}}'; } >"$LED"
CO rollup --by role --records "$LED" --json >"$T/o/ru"
ok 'jq -e ".by == \"role\" and .groups[\"r-a\"].calls == 2 and .groups[\"r-a\"].cost.QAC == 2 and .groups[\"r-a\"].tokens.input == 200 and .groups[\"r-a\"].tokens.reasoning == 5 and .groups[\"r-b\"].unpriced == 1" "$T/o/ru"' "R1 rollup by role: calls, tokens per type, cost per currency, unpriced count"
ok 'for k in card project model connection; do CO rollup --by $k --records "$LED" --json | jq -e ".by == \"$k\" and (.groups | length) >= 1" >/dev/null || exit 1; done; CO rollup --by card --records "$LED" --json | jq -e ".groups[\"c-1\"].calls == 2 and .groups[\"(none)\"].calls == 1"' "R2 rollup by card, project, role, model and connection (a missing key groups under (none))"
ok 'jq -e ".groups[\"r-a\"].cache_hit_rate == 0.5 and .groups[\"r-b\"].cache_hit_rate == 0.454545" "$T/o/ru"' "R3 cache_hit_rate = cache_read / (input + cache_read + cache_write), per role"
ok 'PY <<"E"
import cost, json, os
h = cost.cache_hit_rate([json.loads(l) for l in open(os.environ["LED"])], by="role")
assert h["r-a"] == 0.5 and abs(h["r-b"] - 50 / 110) < 1e-5, h
assert cost.cache_hit_rate([{"role": "x", "tokens": {"input": 0, "output": 1, "cache_write": 0, "cache_read": 0, "reasoning": 0}}], by="role") == {"x": None}
E' "R4 cache_hit_rate in the module; a role with no input side has no rate (None, not a division by zero)"

# ---- T-COST-OTLP: export behind the flag ----
: >"$T/got.jsonl"
CO export --json --record "$RJSON" >"$T/o/ex0"; rc0=$?
ok '[ "$rc0" = 0 ] && jq -e ".exported == 0 and .flag == \"off\"" "$T/o/ex0" && [ ! -s "$T/got.jsonl" ]' "O1 the flag is off by default: nothing is sent"
ok 'PY <<"E"
import socket, cost, json, os
def boom(*a, **k): raise SystemExit("a socket was opened")
socket.socket.connect = boom; socket.create_connection = boom; socket.getaddrinfo = boom
assert cost.export([cost.span_of(json.load(open(os.environ["RJSON"])))]) == 0
E' "O2 with the flag off, nothing opens a socket (connect and name lookup trapped)"
ed features.json '(.entries[] | select(.id == "otlp-export")) |= (.status = "on")'
python3 -I -B "$R/bin/stella_data.py" check >"$T/o/fx2" 2>&1 || fixture "check after the flag: $(head -c 300 "$T/o/fx2")"
rec qa-p qa-m 2026-03-01T00:00:00Z "{\"card\":\"leak-$KEY\"}" >"$T/r2.json"
CO export --json --record "$T/r2.json" >"$T/o/ex1"; rc1=$?
ok '[ "$rc1" = 0 ] && jq -e ".exported == 1" "$T/o/ex1" && [ "$(wc -l <"$T/got.jsonl")" = 1 ]' "O3 flag on, endpoint from the connections catalog: one OTLP/HTTP-JSON POST"
ok 'jq -e ".path == \"/v1/traces\" and (.body | fromjson | .resourceSpans[0].scopeSpans[0].spans[0].attributes | map(select(.key == \"gen_ai.request.model\" and .value.stringValue == \"qa-m\")) | length == 1)" "$T/got.jsonl"' "O4 the body is an OTLP resourceSpans document with the GenAI attributes"
ok '! grep -q "$KEY" "$T/o/ex1" "$AL" && jq -e ".auth == \"Bearer $KEY\"" "$T/got.jsonl" && ! jq -r .body "$T/got.jsonl" | grep -q "$KEY"' "O5 the key goes in the header only; the payload, output and alert log never hold it (a card text with the key is masked)"
ed connections.json '(.entries[] | select(.id == "qa-otlp") | .enabled) = false'
: >"$T/got.jsonl"; CO export --json --record "$RJSON" >"$T/o/ex2"
ok '[ ! -s "$T/got.jsonl" ] && jq -e ".exported == 0" "$T/o/ex2"' "O6 flag on but no enabled endpoint in the catalog: nothing sent, exit 0 with a plain reason"
ed connections.json '(.entries[] | select(.id == "qa-otlp") | .enabled) = true | (.entries[] | select(.id == "qa-otlp") | .hosts[0].port) = 1'
CO export --json --record "$RJSON" >"$T/o/ex3" 2>"$T/o/ex3.err"; rc3=$?
ok '[ "$rc3" = 1 ] && jq -e ".code == \"STL-LIM-422\"" "$T/o/ex3" && grep -q STL-LIM-422 "$AL"' "O7 an endpoint that does not answer fails with STL-LIM-422 and one alert line"

# ---- T-CORE-COST: usage_of over the wire shapes, with the mock's cached and reasoning tokens ----
STELLA_ROOT=$MR python3 -I "$R/bin/mock_provider.py" >"$T/mock.out" 2>"$T/mock.err" &
for _ in $(seq 100); do [ -s "$T/mock.out" ] && break; sleep 0.1; done
MPORT=$(jq -r '.port' "$T/mock.out" 2>/dev/null); CTL=$(jq -r '.control' "$T/mock.out" 2>/dev/null)
[ -n "$MPORT" ] && [ "$MPORT" != null ] || fixture "the mock did not start: $(head -c 300 "$T/mock.err")"
export CTL MPORT LO
ok 'PY <<"E"
import json, os, urllib.request, cost, stella_data as sd
op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def post(url, doc):
    return json.loads(op.open(urllib.request.Request(url, data=json.dumps(doc).encode(), method="POST"), timeout=10).read().decode())
shapes = {e["id"]: e for e in sd.checked(sd.load(".stella/protocols.json"), ".stella/protocols.json", "protocols")["entries"]}
seen = {"cache_read": 0, "cache_write": 0, "reasoning": 0}
for sid, e in shapes.items():
    post(os.environ["CTL"], {"models": {sid: ["t1"]}, "faults": [], "traits": [{"shape": sid, "model": "t1", "cache_read": 40, "cache_write": 7, "reasoning": 5}]})
    body = {"model": "t1", "messages": [{"role": "user", "content": "hi"}], "contents": [{"parts": [{"text": "hi"}]}], "max_tokens": 5}
    got = post(f"http://{os.environ["LO"]}:{os.environ["MPORT"]}/{sid}" + e["request"]["path"].replace("{model}", "t1"), body)
    u = cost.usage_of(e, got)
    ex = e["response"].get("usage_extra") or {}
    want = {"input": 1, "output": 1, **{k: (v if k in ex else 0) for k, v in (("cache_write", 7), ("cache_read", 40), ("reasoning", 5))}}
    assert u == want, (sid, u, want)
    for k in seen:
        seen[k] += bool(u[k])
assert seen["cache_read"] >= 3 and seen["reasoning"] >= 2 and seen["cache_write"] >= 1, seen
E' "C1 usage_of returns the five token numbers for every shape: the mock answers with cached and reasoning tokens at each shape's own keys; counts a shape includes in input or output are taken out (the five are disjoint)"
ok 'PY <<"E"
import cost
chat = {"response": {"usage": "/usage", "usage_keys": ["a", "b"]}}
assert cost.usage_of(chat, {"usage": {"a": 3, "b": 4}}) == {"input": 3, "output": 4, "cache_write": 0, "cache_read": 0, "reasoning": 0}
assert cost.usage_of(chat, {}) == {"input": 0, "output": 0, "cache_write": 0, "cache_read": 0, "reasoning": 0}
E' "C2 a shape with no extra keys, or an answer with no usage block, gives zeros for what it cannot show (never an error)"
ok 'jq -e "[.entries[].response | has(\"usage_extra\")] | any" "$R/.stella/protocols.json" && python3 -I -B "$R/bin/stella_data.py" check >/dev/null' "C3 the protocols schema takes the optional usage_extra and the shipped file with it passes check"
ok 'jq -e ".entries[] | select(.id == \"otlp-export\") | .status == \"off\"" "$ROOT/.stella/features.json"' "C4 the shipped otlp-export feature is off"

echo "# cost-selftest: $fails failed"; [ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
