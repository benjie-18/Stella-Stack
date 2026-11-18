#!/usr/bin/env bash
# Hermetic self-test for bin/probe.py and the structured-output helper (route.py call --schema), F2b item B. In a scratch root (a copy
# of bin, .stella, docs; its own HOME, temp, mock-provider port, folder key backend and a stand-in resolver for route.py's chain) one
# fake connection runs on the mock under one of the shipped wire shapes. Cases: a record is made from what the link does (version and
# family from the model list, JSON, tool calls the mock makes on request, the output shape it proves, the effective context under a
# recall limit); one trusted event line per record; a version is probed once (--again replaces); due; a model added as data only;
# unknown connection and model fail closed; a worker environment is refused; the records file is judged by `check`, a bad or foreign
# record is ignored by readers; the helper repairs once and then fails with a code. Nothing here names a model or a shape.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/probe-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
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
case " $* " in *" send "*) printf '%s\n' "$*" | tr '\n' ' ' >>"$ESCALATE_SUP_DIR/sends"; echo >>"$ESCALATE_SUP_DIR/sends"; exit 0;; esac
echo "[]"
S
chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH
AL=$T/sup/logs/alerts.log; : >"$AL"
fails=0
ok() { if ( eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
fixture() { echo "FIXTURE $1"; exit 3; }
ed() { local f=$R/.stella/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <data file> <jq args and filter>

# ---- the mock ----
STELLA_ROOT=$MR python3 -I "$R/bin/mock_provider.py" >"$T/mock.out" 2>"$T/mock.err" &
for _ in $(seq 100); do [ -s "$T/mock.out" ] && break; sleep 0.1; done
PORT=$(jq -r '.port' "$T/mock.out" 2>/dev/null); CTL=$(jq -r '.control' "$T/mock.out" 2>/dev/null); LO=$(jq -r '.control | capture("//(?<h>[^:/]+):").h' "$T/mock.out" 2>/dev/null)
[ -n "$PORT" ] && [ "$PORT" != null ] || fixture "the mock did not start: $(head -c 300 "$T/mock.err")"
export NO_PROXY=$LO no_proxy=$LO
cat >"$T/http.py" <<'P'
import sys, urllib.request
o = urllib.request.build_opener(urllib.request.ProxyHandler({}))
rq = urllib.request.Request(sys.argv[2], data=open(sys.argv[3], "rb").read(), method="POST") if sys.argv[1] == "post" else sys.argv[2]
sys.stdout.write(o.open(rq, timeout=10).read().decode())
P
PR=$R/.stella/protocols.json
SG=$(jq -r '([.entries[] | select((.request.output_shape // {}) | has("grammar"))] + [.entries[] | select((.request.output_shape // {}) | length > 0)])[0].id // empty' "$PR")
[ -n "$SG" ] || fixture "no wire shape names a request.output_shape pointer (item A's data)"
OS=$(jq -c --arg s "$SG" '.entries[] | select(.id == $s) | .request.output_shape' "$PR")   # {enforcement id: body pointer} of SG
ed protocols.json '.entries |= map(.request.path = "/" + .id + .request.path | .models_path = "/" + .id + .models_path)'   # the mock serves each shape under its id

# ---- keys, catalog, stand-in resolver ----
KN=ST_FAKE_KEY; KEY="stkey$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
CD=$(ix .backup_dir)/st-keys; mkdir -p "$R/$CD"; chmod 700 "$R/$CD"; (umask 077; printf '%s' "$KEY" >"$R/$CD/$KN")
ed routing.json --arg p "$CD" '.credentials.backend = "st-dir" | .credentials.backends["st-dir"] = {kind: "dir", path: $p}'
LIM=$R/$(ix '.files[] | select(.id == "limits") | .path'); mkdir -p "$(dirname "$LIM")"; echo "CALL_TIMEOUT=5" >"$LIM"
TPL='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "cloud" and (.aggregator | not))][0]'
ADV=32768   # the advertised window of every fake model
mdl() { echo "{\"id\":\"$1\",\"capabilities\":{\"tool_calling\":true,\"json_mode\":true,\"context_tokens\":$ADV,\"vision\":true,\"streaming\":true},\"probed_at\":null,\"probe_source\":\"advertised\",\"cost\":null,\"limits\":null}"; }
MODELS="qa-ctx qa-full qa-g qa-plain qa-j qa-due qa-tc"
addmodel() { ed connections.json --arg c qa-p --argjson m "$(mdl "$1")" '(.entries[] | select(.id == $c) | .models) += [$m]'; }   # <model id>: data only
ed connections.json --arg s "$SG" --arg g "$(cat /proc/sys/kernel/random/uuid)" --arg h "$LO" --argjson p "$PORT" --arg k "$KN" \
  ".entries += [$TPL + {id: \"qa-p\", label: \"qa-p\", enabled: true, global_id: \$g, models: [], secrets: [\$k], hosts: [{host: \$h, port: \$p, purpose: \"qa mock\"}], protocol: \$s}]"
for m in $MODELS; do addmodel "$m"; done
cp "$R/bin/resolve.py" "$T/resolve.real"
cat >"$R/bin/resolve.py" <<'P'
"""QA stand-in for the resolver (route.py's chain only): the fixture chain document <root>/chain.json."""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def link_key(link):
    return f"{link['connection']}/{link['model']}"
def resolve(ctx):
    with open(os.path.join(ROOT, "chain.json")) as f:
        return json.load(f)
P
LC=$(jq -r '.link_classes | sort_by(.privacy_rank) | .[1].id' "$R/.stella/routing.json")
ROLE=$(jq -r '.roles | keys[0]' "$RJ")
chain() {  # <model>: the stand-in's chain is the one link qa-p/<model>
  jq -n --arg m "$1" --arg cl "$LC" '{preset: {id: "qa"}, chain: [{connection: "qa-p", model: $m, parameters: {}, link_class: $cl, source: "preset", status: "usable",
    code: null, reason: null, grant: null, mid_task: true, cooldown_until: null}], decision: {rule: "qa", reason: "qa"}, failure_history: [], stubs: []}' >"$R/chain.json"
}
python3 -I -B "$R/bin/stella_data.py" check >"$T/o/fxcheck" 2>&1 || fixture "the scratch data does not pass check: $(head -c 300 "$T/o/fxcheck")"

# ---- the probe's data and settings (item B); on a root without them these stay empty and the cases fail ----
RT=$R/.stella/routing.json
PF=$R/$(ix .probe_records)
EV=$R/$(ix .event_log)
SHAPES=$(jq -c '.probe.output_shapes // []' "$RT")             # enforcement ids, strongest first
LENS='[1000, 4000, 16000]'                                      # token lengths this test probes at (data: routing probe.lengths)
jq -e '.probe | type == "object"' "$RT" >/dev/null 2>&1 && ed routing.json --argjson l "$LENS" '.probe.lengths = $l'
DROP=8000                                                       # qa-ctx finds needles only below this many tokens

# ---- the mock's world: models, faults and traits of the fake links ----
GOOD='{"reasoning":"short","verdict":"a"}'                      # an answer valid against $T/schema.json (with the reasoning field)
trt() { jq -nc --arg s "$SG" --arg m "$1" --argjson x "$2" '{shape: $s, model: $m} + $x'; }   # <model> <extra trait fields JSON>
TRAITS="[$(trt qa-ctx "{\"recall_tokens\":$DROP,\"family\":\"qa-fam\",\"version\":\"v1\"}"), $(trt qa-full '{"recall_tokens":1000000000,"version":"v1"}'),
  $(trt qa-g "{\"grammar\":true,\"answers\":[$(jq -Rn --arg a "$GOOD" '$a')],\"version\":\"v1\"}"), $(trt qa-plain '{"version":"v1"}'),
  $(trt qa-j '{"answers":["{\"ok\": true}"],"version":"v1"}'), $(trt qa-due '{"version":"v1"}'), $(trt qa-tc '{"tool_calls":2,"answers":["{\"ok\": true}"]}')]"
FAULTS="[{\"shape\":\"$SG\",\"model\":\"qa-g\",\"fault\":\"non_json\"},{\"shape\":\"$SG\",\"model\":\"qa-plain\",\"fault\":\"non_json\"}]"
world() {  # [<models JSON>] [<faults JSON>] [<traits JSON>]: post the control document (defaults: the fake links above)
  jq -nc --arg s "$SG" --argjson m "${1:-$(printf '%s\n' $MODELS | jq -Rsc 'split("\n")[:-1]')}" --argjson f "${2:-$FAULTS}" --argjson t "${3:-$TRAITS}" \
    '{models: {($s): $m}, faults: $f, traits: $t}' >"$T/ctl.json"
  python3 -I "$T/http.py" post "$CTL" "$T/ctl.json" >/dev/null 2>&1
}
world
calls() { python3 -I "$T/http.py" get "http://$LO:$PORT/_calls" 2>/dev/null; }
cnt() { calls | jq --arg k "$SG/$1" '.counts[$k] // 0'; }      # <model>: calls the mock counted on it
reqs() { calls | jq -c --arg m "$1" '[.requests[] | select(.model == $m) | .body]'; }   # <model>: the bodies it got
jq -n '{"type": "object", "properties": {"verdict": {"enum": ["a", "b"]}}, "required": ["verdict"], "additionalProperties": false}' >"$T/schema.json"

# ---- runners ----
pr() { python3 -I "$R/bin/probe.py" "${@:2}" >"$T/o/$1.json" 2>"$T/o/$1.err"; echo $? >"$T/o/$1.rc"; }   # <name> <probe.py args>
hp() {  # <name> <model> [prompt]: the structured-output helper, route.py call --schema, on the one link qa-p/<model>
  chain "$2"; printf '%s' "${3:-route this: hello}" | timeout 60 python3 -I "$R/bin/route.py" call --role "$ROLE" --project qa-proj --task "$1" --schema "$T/schema.json" --json \
    >"$T/o/$1.json" 2>"$T/o/$1.err"; echo $? >"$T/o/$1.rc"
}
rc() { cat "$T/o/$1.rc"; }
J() { [ -s "$T/o/$1.json" ] && jq -e "${@:2}" "$T/o/$1.json" >/dev/null 2>&1; }
rec() { jq -c --arg m "$1" '[.records[]? | select(.connection == "qa-p" and .model == $m)]' "$PF" 2>/dev/null || echo '[]'; }   # <model>: its records
R1() { rec "$1" | jq -e "length == 1 and (.[0] | $2)" >/dev/null 2>&1; }                                              # <model> <jq on the one record>
evn() { if [ -f "$EV" ]; then jq -c "select($1)" "$EV" 2>/dev/null | grep -c .; else echo 0; fi; }
passes() { python3 -I -B "$R/bin/stella_data.py" check >"$T/o/check" 2>&1; }

n=0; ok() { n=$((n+1)); if ( eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
IID=$(jq -r .install_id "$R/$(jq -r '[.files[] | select(.schema == "install") | .path][0]' "$IX")")
pr c1 run --connection qa-p --model qa-ctx --json; pr t1 run --connection qa-p --model qa-tc --json; pr g1 run --connection qa-p --model qa-g --json; pr p1 run --connection qa-p --model qa-plain --json
ok '[ "$(rc c1)" = 0 ] && R1 qa-ctx ".version == \"v1\" and .family == \"qa-fam\" and .install_id == \"$IID\" and .code == null and .tool_calling == false and .vision == false and .context.effective == 4000 and .context.advertised == $ADV"' \
  "S1 a record from what the link does: version and family of the model list, no tool call from a link that makes none, effective context 4000 where needles are found only below 8000"
ok '[ "$(rc t1)" = 0 ] && R1 qa-tc ".tool_calling == true and .parallel_tool_calls == true and .json == true"' "S2 two well-formed calls in one answer: tool calling and parallel tool calls true, JSON true"
ok '[ "$(rc g1)" = 0 ] && R1 qa-g ".output_shape == \"strict_schema\"" && R1 qa-plain ".output_shape == \"none\""' "S3 the link that enforces the schema is recorded with the strongest shape its wire shape names, the plain one none"
ok '[ "$(evn ".type == \"probe.recorded\"")" = 4 ] && python3 -I -B "$R/bin/event_log.py" verify' "S4 one trusted probe.recorded line per record; the chain verifies"
k0=$(cnt qa-ctx); pr c2 run --connection qa-p --model qa-ctx --json
ok '[ "$(rc c2)" != 0 ] && grep -q "^STL-MDL-735" "$T/o/c2.err" && [ "$(cnt qa-ctx)" = "$k0" ]' "S5 the same version again is refused (STL-MDL-735) with no model call"
pr c3 run --connection qa-p --model qa-ctx --again --json
ok '[ "$(rc c3)" = 0 ] && [ "$(rec qa-ctx | jq length)" = 1 ] && [ "$(evn ".type == \"probe.recorded\"")" = 5 ]' "S6 --again replaces the record of the version and writes one more line"
pr d1 due --json
ok 'jq -e "[.due[].model] | index(\"qa-due\") != null and index(\"qa-ctx\") == null" "$T/o/d1.json"' "S7 due lists the link whose version has no record and not the probed one"
CLIW=$(jq -c '[.entries[] | select(.kind == "provider" and .enabled != false and (.protocol // null) == null) | .id as $c | .models[] | {connection: $c, model: .id}]' "$R/.stella/connections.json")
ok 'jq -e --argjson w "$CLIW" "(\$w | length > 0) and [.due[] | select(.probeable == false) | {connection, model}] == \$w and ([.due[] | select(.probeable == false) | .version] | all(. == null))" "$T/o/d1.json"' \
  "S7a owner ruling 2026-11-18: due also lists every link with no record whose connection has no wire shape (a CLI login), with version null and probeable false"
ok 'R1 qa-plain ".context.short_score == 0 and .context.effective == .context.points[0].tokens and .context.effective > 0"' \
  "S7b W23P-02: a link that fails the multi-hop test even at the shortest length is recorded at that length, never at effective context 0"
NEW=qa-new$RANDOM; addmodel "$NEW"
world "$(printf '%s\n' $MODELS "$NEW" | jq -Rsc 'split("\n")[:-1]')" "" "$(jq -c --argjson t "$(trt "$NEW" '{"version":"v7","family":"qa-fam7"}')" '. + [$t]' <<<"$TRAITS")"
pr f1 run --connection qa-p --model "$NEW" --json
ok '[ "$(rc f1)" = 0 ] && R1 "$NEW" ".version == \"v7\" and .family == \"qa-fam7\""' "S8 fake entry: a model added as data only is probed and recorded"
pr u1 run --connection qa-nope --model qa-ctx --json; pr u2 run --connection qa-p --model qa-zz --json; n1=$(grep -c . "$AL")
ok '[ "$(rc u1)" != 0 ] && [ "$(rc u2)" != 0 ] && grep -q "^STL-MDL-734" "$T/o/u1.err" && grep -q "^STL-MDL-734" "$T/o/u2.err" && [ "$n1" = 2 ]' "S9 an unknown connection or model fails closed: STL-MDL-734, one alert line each"
STUB_WORKER_MARK=1 pr w1 run --connection qa-p --model qa-full --json
ok '[ "$(rc w1)" != 0 ] && grep -q "STL-CFG-312" "$T/o/w1.err" && [ "$(rec qa-full | jq length)" = 0 ]' "S10 a worker environment is refused (STL-CFG-312): no record"
ok '! grep -rqF "$KEY" "$T/o" "$PF" "$EV" "$AL"' "S11 the key is in no output, record, event or alert line"
pr k1 check --json
ok '[ "$(rc k1)" = 0 ] && ! git -C "$ROOT" ls-files --error-unmatch "$(jq -r .probe_records "$IX")" >/dev/null 2>&1 && ! jq -e ".files[] | select(.path == \"$(jq -r .probe_records "$IX")\")" "$IX"' "S12 check passes on the records written; the file is an index key (protected state), no data row"
cp "$PF" "$T/pf.keep"
bad() { jq "$1" "$T/pf.keep" >"$PF"; pr kb check --json; [ "$(rc kb)" != 0 ]; }
ok 'bad ".records[0].output_shape = \"qa-bogus\"" && bad ".records[0] |= del(.version)" && bad ".records += [.records[0]]" && bad ".schema_version = 99"' "S13 check refuses an output_shape outside the routing data, a record without version, a duplicate key and an unknown schema_version"
pr sb show --json
ok '[ "$(rc sb)" = 0 ] && jq -e ".records == [] and (.problem | type == \"string\")" "$T/o/sb.json"' "S14 a reader takes no record from an invalid file"
jq '.records[0].install_id = "00000000-0000-4000-8000-000000000000"' "$T/pf.keep" >"$PF"; pr sf show --json
ok 'jq -e ".records | length == ($(jq ".records | length" "$T/pf.keep") - 1)" "$T/o/sf.json"' "S15 a record of another install is ignored by readers"
cp "$T/pf.keep" "$PF"
SEED=$(python3 -I -c 'import random
print(next(s for s in range(1, 10000) if (lambda r: r.random() < 0.5 <= r.random())(random.Random(s))))')
addmodel qa-rep; addmodel qa-bad
world "$(printf '%s\n' $MODELS qa-rep qa-bad | jq -Rsc 'split("\n")[:-1]')" "" "$(jq -c --argjson a "$(trt qa-rep "{\"answers\":[\"not json at all\",$(jq -Rn --arg a "$GOOD" '$a')],\"seed\":$SEED}")" --argjson b "$(trt qa-bad '{"answers":["{\"ok\": true}"]}')" '. + [$a, $b]' <<<"$TRAITS")"
# route.py call refuses a link whose probed effective context does not hold the prompt (F2b item C): the two links get a record (the newest, so it speaks for them)
jq --arg i "$IID" --arg o "$(jq -r '.probe.output_shapes[-1]' "$RT")" '.records += [("qa-rep", "qa-bad") | {global_id: "00000000-0000-4000-8000-000000000000", install_id: $i,
  connection: "qa-p", model: ., version: "qa-helper", probed_at: "2026-01-01T00:00:00Z", family: null, tool_calling: true, parallel_tool_calls: null, json: true,
  vision: false, output_shape: $o, context: {advertised: null, effective: 1048576, short_score: 1, points: []}, code: null}]' "$PF" >"$PF.n" && mv "$PF.n" "$PF"
hp h1 qa-rep; hp h2 qa-bad
ok '[ "$(rc h1)" = 0 ] && J h1 --argjson g "$GOOD" "(.text | fromjson) == \$g" && [ "$(cnt qa-rep)" = 2 ]' "S16 the helper: an answer that is not JSON gets one repair retry; the valid answer is the result"
ok '[ "$(rc h2)" != 0 ] && [ "$(cnt qa-bad)" = 2 ] && J h2 ".code == \"STL-MDL-736\" and ((.text // null) == null)"' "S17 the helper: JSON that breaks the schema, also after the retry: STL-MDL-736, no text"
echo "# probe-selftest: $fails failed"; [ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
