#!/usr/bin/env bash
# Hermetic self-test for the policy gateway hooks (X1 item G2; body B4, AC4, AC5; design section G2 with rulings X1-DC-08, X1-DC-09).
# Every section runs in its own scratch root (bash gateway-hooks-selftest.sh <section>); no argument runs them all.
# Per hook site, a scratch root with mode enforce and a policy that allows every X1 kind but the site's one (the fake evaluator of
# bin/gateway-selftest.sh: a scratch script plus a data entry): the action's side effect never happens and a decision line of that kind
# is in the trusted log; mode audit: it happens and a would-refuse line of that kind is there; mode off: no decision line and the same
# result as today (the site's hook registered in gateway.json, so off is a hooked path that stays quiet).
# Sections -> sites (checks T-hooks, AC4-enforce-refuse, AC4-audit, AC4-off):
#   agent = agent-runtime executor (tool_call, file_write, file_read, shell) | mcp = capabilities_mcp tools/call (mcp_call) |
#   proxy = model_proxy upstream forward (network_request) | broker = credentials.get (broker_call) | host = host_access decide
#   (host_session) | pdp = the coding-CLI policy hook through the engine-side PDP route (file_write; unreachable PDP while on refuses) |
#   dc08 = X1-DC-08 (hookless coding CLI refused at start in enforce; an off-mode run stopped by the owner apply to enforce) |
#   dc09 = X1-DC-09 (--project other than the card's board binding refused) | lint = AC5-lint (the shipped data passes, every kind
#   hooked at its site)
# Written test-first (X1 wave 2): every case fails on build/X1 (no gateway, no hooks) with a FAIL line carrying its check id.
# The harness is copied from bin/gateway-selftest.sh (fake evaluator, owner file setpol, decision-line matcher), bin/agent-runtime-selftest.sh
# (the fake AG-UI agent entry), bin/adapter-run-selftest.sh (the fake coding CLI and its hook entry), bin/capabilities-mcp-selftest.sh
# (MCP client, fake skill), bin/model-proxy-selftest.sh (proxy call) and bin/host-access-selftest.sh (the allowed baseline request).
# ASSUMPTIONS (on top of gateway-selftest.sh G-A1..G-A7 and agent-runtime-selftest.sh B1..B5; the builder matches them or asks the tester):
#  H-A1 a refusal at a hook carries a code STL-GRD-730..752 (G1's or G2's range) where the site reports codes.
#  H-A2 agent runtime: an offered tool call is checked as tool_call and as the kind of its class (read -> file_read, write/edit ->
#       file_write, shell -> shell) before its executor runs; a refusal is a tool_result ok false in the run stream.
#  H-A3 capabilities MCP: a refused tools/call is a JSON-RPC error or an isError result with the code; model proxy: HTTP >= 400 with the
#       code and no upstream request; credentials.get: raises credentials.Refused with the code; host_access decide: exit 1 with the code.
#  H-A4 PDP: the coding CLI's policy hook (bin/policy.py hook, worker side) asks the engine-side PDP route only when its run's start
#       mode is not off; the decision line is written engine side; a refusal is the entry's deny template (the write never happens).
#  H-A5 DC-08: the run record keeps its start mode at a key path holding "gateway" (value off|audit|enforce); the stop is adapter.py
#       stop's: record .stopped holds a reason naming the gateway, one adapter.run-stopped line names the run. A hookless adapter is
#       an entry with no policy.hook (supports.hook false): start in enforce refuses with STL-GRD-745..752 before spawning.
#  H-A6 DC-09: a card's board binding is `hermes kanban --board B show C --json` .task.project; a different --project is refused with a
#       code before anything is spawned.
#  H-A7 lint: gateway.json hooks name, per kind: tool_call/file_read/file_write/shell bin/agent_runtime.py, mcp_call
#       bin/capabilities_mcp.py, network_request bin/model_proxy.py, broker_call bin/credentials.py, host_session bin/host_access.py;
#       the PDP route (bin/capabilities_mcp.py) is a registered hook of file_write too (the coding CLIs' writes reach it).
set -u
has() { grep "$@" >/dev/null; }   # grep that reads its whole input: under pipefail an early-exit grep -q kills the writer with SIGPIPE (141), which flips found or not-found (final-pass tester, R1)
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=gateway-hooks-selftest
SECTIONS="agent mcp proxy broker host pdp dc08 dc09 lint"
if [ $# = 0 ]; then
  f=0; for s in $SECTIONS; do bash "${BASH_SOURCE[0]}" "$s" || f=$((f+1)); done
  [ $f = 0 ] && echo "$ME PASS" || echo "$ME FAIL ($f sections)"; [ $f = 0 ]; exit
fi
case " $SECTIONS " in *" $1 "*) ;; *) echo "usage: $ME.sh [$(tr ' ' '|' <<<"$SECTIONS")]" >&2; exit 2;; esac
S=$1
# ---- harness: a scratch root of its own (bin, .stella, docs and the root config files copied), its own HOME, temp, alert folder ----
T=$(mktemp -d "${TMPDIR:-/tmp}/$ME.XXXXXX"); T=$(cd "$T" && pwd -P)
R=$T/root
trap 'pkill -f "$R/bin/mock_agui_agent.py" 2>/dev/null; pkill -f "$R/bin/mock_agent.py" 2>/dev/null; kill $(jobs -p) 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "# KEPT $T"; else chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; fi' EXIT
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$R/.claude" "$R/qa" "$T/home" "$T/tmp" "$T/sup/logs" "$T/pb" "$T/o"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"
for f in opencode.json .mcp.json .claude/settings.json .claude/skills; do [ -e "$ROOT/$f" ] && cp -r "$ROOT/$f" "$R/$f"; done
cd "$T" || exit 1
jq() { env -u HOME jq "$@"; }
IX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IX"; }
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$ROOT/$(ix .role_table)" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
POL=$R/$(ix '.files[] | select(.id == "owner-auth") | .path')
for v in $(jq -r '.worker_signals.token_env[]?' "$POL" 2>/dev/null); do unset "$v"; done
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH   # the board: no worker run
AL=$T/sup/logs/alerts.log; : >"$AL"
EV=$R/$(ix .event_log)
IID=$(jq -r .install_id "$R/.stella/install.json")
fails=0; n=0
# ok <test> <label>: a FAIL line (never a crash) with the last output of the case under it
ok() { n=$((n+1)); if ( set -o pipefail; eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/o/last" ] && tail -n 3 "$T/o/last" | cut -c1-240 | sed 's/^/     | /'; fi; : >"$T/o/last"; }
finish() { echo "# $ME $S: $n cases, $fails failed"; [ "$fails" = 0 ]; exit $?; }
# run <tag> <cmd...>: stdout to $T/o/<tag>.out, stderr to $T/o/<tag>.err, exit code in RC; every call is bounded
run() { local t=$1; shift; if declare -F "$1" >/dev/null; then "$@"; else timeout 150 "$@"; fi >"$T/o/$t.out" 2>"$T/o/$t.err"; RC=$?; cat "$T/o/$t.out" "$T/o/$t.err" >"$T/o/last" 2>/dev/null; }   # a function bounds itself
out() { cat "$T/o/$1.out" "$T/o/$1.err" 2>/dev/null; }
ed() { local f=$R/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <file under the root> <jq args and filter>
uuid() { cat /proc/sys/kernel/random/uuid; }
nl() { if [ -f "$1" ]; then wc -l <"$1"; else echo 0; fi; }
newev() { tail -n +$(($1 + 1)) "$EV" 2>/dev/null | jq -c "select(.type == \"$2\")" 2>/dev/null; }   # <line count before> <type>
GCODE='STL-GRD-7(3[0-9]|4[0-9]|5[0-2])'; G2CODE='STL-GRD-7(4[5-9]|5[0-2])'
ROLE=$(jq -r '.roles | keys[0]' "$RJ")

# ---- the gateway data (as bin/gateway-selftest.sh): the two rows, the decision type, the fake evaluator entry, the owner file ----
GWREL=$(ix '[.files[] | select(.path | endswith("/gateway.json")) | .path][0] // ".stella/gateway.json"')
GPID=$(ix '[.files[] | select(.path | endswith("/gateway-policy.json")) | .id][0] // empty')
GPREL=$(ix '[.files[] | select(.path | endswith("/gateway-policy.json")) | .path][0] // ".stella/gateway-policy.json"')
GW=$R/$GWREL; GP=$R/$GPREL
[ -f "$GW" ] || echo '{"schema_version": 1, "action_kinds": [], "evaluators": []}' >"$GW"   # base: the cases still run and FAIL
DEV=$(jq -r '.decision_event // empty' "$GW")
DEFEV=$(jq -r '.evaluator // empty' "$GP" 2>/dev/null); [ -n "$DEFEV" ] || DEFEV=$(jq -r '.evaluators[0].id // "cedar"' "$GW")
cp "$GW" "$T/gw.orig"; [ -f "$GP" ] && cp "$GP" "$T/gp.orig" || echo '{"schema_version": 1}' >"$T/gp.orig"
ALLK=$(jq -c '[.action_kinds[]?.id] | if length == 0 then ["file_read","file_write","shell","tool_call","mcp_call","network_request","broker_call","host_session"] else . end' "$T/gw.orig")
cat >"$R/qa/fake_eval.py" <<'PY'
import json, sys
mode, mark = sys.argv[1], sys.argv[2]
with open(mark, "a") as f:
    f.write("spawn\n")
raw = sys.stdin.read()
kind = json.loads(raw)["kind"]
allow = f"QA-PERMIT {kind};" in raw   # the policy text is in the request whatever form {policies} takes
print(json.dumps({"decision": "allow" if allow else "deny", "reasons": ["qa-fake " + ("permit" if allow else "no permit")], "errors": []}))
PY
cat >"$T/qa.py" <<'PY'
import json, sys
def flat(x, out):
    if isinstance(x, dict):
        for k, v in x.items():
            out.setdefault(k, []).append(v); flat(v, out)
    elif isinstance(x, list):
        for v in x: flat(v, out)
    return out
def match(log, typ, want):
    n = 0
    try:
        lines = open(log).read().splitlines()
    except OSError:
        return 0
    for l in lines:
        try:
            d = json.loads(l)
        except ValueError:
            continue
        f = flat(d, {})
        if typ and d.get("type") == typ and all(v in f.get(k, []) for k, v in want.items()):
            n += 1
    return n
print(match(sys.argv[1], sys.argv[2], json.loads(sys.argv[3])))   # <log> <type> <want JSON>: lines of that type holding every key: value
PY
# newdec <line count before> <want JSON>: decision lines written since, holding every key: value at any depth (G-A3)
newdec() { tail -n +$(($1 + 1)) "$EV" 2>/dev/null >"$T/o/evtail"; python3 -I "$T/qa.py" "$T/o/evtail" "$DEV" "$2"; }
nodec() { [ "$(newdec "$1" '{}')" = 0 ] && ! tail -n +$(($1 + 1)) "$EV" 2>/dev/null | has '"would-refuse"'; }
# hooked <kind> <file>: gateway.json registers the kind with a hook in that file (so off is a hooked path)
hooked() { jq -e --arg k "$1" --arg f "$2" '[.action_kinds[]? | select(.id == $k) | .hooks[]? | select(.file | endswith($f))] | length > 0' "$GW" >/dev/null 2>&1; }
ev() {   # <id> <fake mode> <timeout_s>: the default entry's fields, then the fake script's argv / request / timeout
  jq -c --arg id "$1" --arg m "$2" --argjson t "$3" --arg dflt "$DEFEV" --arg g "$(uuid)" --arg i "$IID" '
    (([.evaluators[]? | select(.id == $dflt)][0]) // {verdict: "/decision", reason: "/reasons/0", status: "approved"})
    + {id: $id, kind: "subprocess", argv: ["python3", "-I", "{stack}/qa/fake_eval.py", $m, "{stack}/qa/spawned"],
       request: {kind: "{kind}", role: "{role}", project: "{project}", inputs: "{inputs}", policies: "{policies}"},
       timeout_s: $t, global_id: $g, install_id: $i}' "$T/gw.orig"; }
jq --argjson a "$(ev qa-fake decide 10)" '.evaluators = ((.evaluators // []) + [$a])' "$T/gw.orig" >"$GW"
setpol() {   # <global mode> <projects JSON> <evaluator> <policies JSON: [[kinds], text]...>: the owner file as the owner would hold it
  python3 -I - "$T/gp.orig" "$GP" "$1" "$2" "$3" "$4" "$IID" <<'PY'
import json, sys, uuid
src, dst, g, projects, ev, pols, iid = sys.argv[1:8]
d = json.load(open(src))
ids = not d.get("policies") or "global_id" in d["policies"][0]
d["mode"] = {"global": g, "projects": json.loads(projects)}
d["evaluator"] = ev
d["policies"] = [dict({"id": f"qa-pol-{n}", "kinds": k, "text": t}, **({"global_id": str(uuid.uuid4()), "install_id": iid} if ids else {}))
                 for n, (k, t) in enumerate(json.loads(pols))]
json.dump(d, open(dst, "w"), indent=2)
PY
}
# deny <mode> <kind>: one policy covering every X1 kind that permits all but <kind> (so only that kind's check refuses); allowall <mode>
deny() { setpol "$1" '{}' qa-fake "$(jq -nc --argjson k "$ALLK" --arg x "$2" '[[$k, ([$k[] | select(. != $x) | "QA-PERMIT \(.);"] | join(" "))]]')"; }
allowall() { deny "$1" qa-no-such-kind; }

# ---- the mock upstream (its own root), the key in a folder backend, the fake api connection (data), the proxy (bin/agent-runtime-selftest.sh) ----
MR=$T/mockroot; mkdir -p "$MR"; cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$MR/"
STELLA_ROOT=$MR ESCALATE_SUP_DIR=$T/sup python3 -I "$R/bin/mock_provider.py" >"$T/mock.out" 2>"$T/mock.err" &
for i in $(seq 100); do [ -s "$T/mock.out" ] && break; sleep 0.1; done
PORT=$(jq -r '.port' "$T/mock.out" 2>/dev/null); CTL=$(jq -r '.control' "$T/mock.out" 2>/dev/null); LO=$(jq -r '.control | capture("//(?<h>[^:/]+):").h' "$T/mock.out" 2>/dev/null)
export NO_PROXY=$LO,127.0.0.1 no_proxy=$LO,127.0.0.1
cat >"$T/cli.py" <<'PYC'
import http.client, json, sys
# <host> <port> <method> <path> <body> [headers JSON]: one request, the answer as JSON
c = http.client.HTTPConnection(sys.argv[1], int(sys.argv[2]), timeout=20)
h = json.loads(sys.argv[6]) if len(sys.argv) > 6 else {"Content-Type": "application/json"}
c.request(sys.argv[3], sys.argv[4], body=sys.argv[5].encode(), headers=h)
r = c.getresponse(); print(json.dumps({"status": r.status, "body": r.read().decode("utf-8", "replace")}))
PYC
calls() { python3 -I "$T/cli.py" "$LO" "$PORT" GET /_calls '' | jq -r '.body | fromjson | [.counts[]] | add // 0' 2>/dev/null || echo -1; }
SHAPE=$(jq -r '.entries[0].id' "$R/.stella/protocols.json")
ed .stella/protocols.json '.entries |= map(.request.path = "/" + .id + .request.path)'
python3 -I "$T/cli.py" "$LO" "$PORT" POST "/${CTL#*://*/}" "$(jq -nc --arg s "$SHAPE" '{models: {($s): ["qa-m1"]}, faults: []}')" >/dev/null 2>&1
KN=QA_ADAPTER_KEY; KEY="qacanary$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
CD=$(ix .backup_dir)/qa-keys; mkdir -p "$R/$CD"; chmod 700 "$R/$CD"; (umask 077; printf '%s' "$KEY" >"$R/$CD/$KN")
ed .stella/routing.json --arg p "$CD" '.credentials.backend = "qa-dir" | .credentials.backends["qa-dir"] = {kind: "dir", path: $p}'
mdl() { echo "{\"id\":\"$1\",\"capabilities\":{\"tool_calling\":true,\"json_mode\":true,\"context_tokens\":100000,\"vision\":false,\"streaming\":true},\"probed_at\":null,\"probe_source\":\"advertised\",\"cost\":null,\"limits\":null}"; }
LTPL='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "local")][0]'
ed .stella/data-policy.json --arg h "$LO" '(.. | objects | select(has("local_hosts")) | .local_hosts) += [$h]'
ed .stella/connections.json --arg s "$SHAPE" --arg g "$(uuid)" --arg h "$LO" --argjson p "${PORT:-9}" --arg k "$KN" \
  ".entries += [$LTPL + {id: \"qa-api\", label: \"qa-api\", enabled: true, global_id: \$g, models: [$(mdl qa-m1)], secrets: [\$k], auth_types: [\"api_key\"], protocol: \$s,
    hosts: [{host: \$h, port: \$p, purpose: \"selftest mock\"}]}]"
ed .stella/role-assignments.json --arg r "$ROLE" '.effort_modes |= map_values(.roles[$r] = {active: true, escalation_chain: [{connection: "qa-api", model: "qa-m1", parameters: {}}]})'
python3 -I "$R/bin/model_proxy.py" serve --port 0 >"$T/proxy.out" 2>"$T/proxy.err" &
for i in $(seq 50); do [ -s "$T/proxy.out" ] && break; sleep 0.1; done; PPORT=$(jq -r '.port // empty' "$T/proxy.out" 2>/dev/null)
# ---- the capabilities MCP server (the PDP route lives on it) on a free port ----
MP=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I "$R/bin/capabilities_mcp.py" serve --port "$MP" >"$T/mcp.out" 2>"$T/mcp.err" & MPID=$!
for i in $(seq 50); do python3 -I -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2)' "$MP" 2>/dev/null && break; sleep 0.1; done
mint() { python3 -I "$R/bin/run_token.py" mint "$@" 2>>"$T/o/mint.err" | tr -d '\n'; }
# ---- runs: worktrees, briefs, waiting (bin/adapter-run-selftest.sh, bin/agent-runtime-selftest.sh) ----
AF=$R/.stella/adapters.json; AP=$R/.stella/agent-protocols.json
AR=$(ix '.adapter_runs // empty'); CRF=$(ix '.conformance_records // empty')
CRK=$(ix '.conformance_scratch // empty'); case $CRK in "") CRD=$T/no-conformance-root;; /*) CRD=$CRK;; *) CRD=$R/$CRK;; esac
mkdir -p "$CRD"
A() { timeout 120 python3 -I "$R/bin/adapter.py" "$@"; }
mkwt() { mkdir -p "$1" && git -C "$1" init -q && git -C "$1" config user.name qa && git -C "$1" config user.email qa@qa.invalid && echo base >"$1/README" && git -C "$1" add README && git -C "$1" commit -qm base; }
wt() { local w=$CRD/wt-$1; mkwt "$w" >/dev/null 2>&1; echo "$w"; }   # a fresh card-less worktree under the conformance scratch root
done_() { local i o; [ "${RC:-1}" = 0 ] || return 1; for i in $(seq 120); do o=$(A evidence --run "$1" --json 2>/dev/null) && [ -n "$o" ] && jq -e '.exit_code | type == "number"' <<<"$o" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }
spawned() { local i; for i in $(seq 30); do [ -f "$1/qamark-$2.txt" ] && return 0; sleep 0.5; done; return 1; }
none_() { sleep 2; [ ! -f "$1/qamark-$2.txt" ]; }
rec() { local f=$R/$AR/$1.json; [ -n "$AR" ] && [ -s "$f" ] && cat "$f"; }
evf() { echo "$R/$AR/$1/events.jsonl"; }
res() { local f; f=$(evf "$1"); [ -s "$f" ] && jq -c --arg x "$2" 'select(.type == "tool_result" and (tostring | contains($x)))' "$f" 2>/dev/null; }
# ---- the fake coding CLI (bin/mock_agent.py; hookless qa-fake) and its hook-capable twin qa-hook (bin/adapter-run-selftest.sh filterseen) ----
printf '#!/bin/sh\nexec python3 -I "%s/bin/mock_agent.py" "$@"\n' "$R" >"$T/pb/qa-agent"; chmod +x "$T/pb/qa-agent"
VER=$(qa-agent --version 2>/dev/null | awk '{print $2}')
BASE=$(jq -c '([.entries[] | select(.status == "active")] + .entries)[0] // {}' "$AF" 2>/dev/null)
TE=$(jq -r '.token_env // empty' <<<"${BASE:-{\}}")
FAKE=$(jq -c --arg v "${VER:-none}" --arg s "$SHAPE" --arg te "$TE" --arg g "$(uuid)" --arg i "$IID" '. + {id: "qa-fake", unboxed: true, label: "QA fake agent", binary: "qa-agent",
  version_cmd: ["qa-agent", "--version"], tested_versions: [$v], status: "active", conn_types: ["api"], protocols: [$s],
  start: {argv: ["qa-agent", "--prompt-file", "{prompt_file}", "--config", "{settings_file}", "--model", "{model}", "--mcp-config", "{mcp_config}", "--cwd", "{worktree}"],
          env: {base_url_env: "QA_AGENT_BASE_URL", token_env: $te}},
  stream: {format: "jsonl", type: "/type", tool_name: "/name", tool_input: "/input", tool_result: "/output", error: "/error",
           usage: {input: "/input_tokens", output: "/output_tokens"}, final_text: "/text"},
  supports: {hook: false, deferred_tools: false, compaction: false, clear_tool_results: false, subagent: false, script_tools: false,
             working_notes: false, skill_use_observable: false, tool_use_observable: true},
  tools: {write: {class: "write", path: "/path"}, edit: {class: "write", path: "/path"}, read: {class: "read", path: "/path"},
          read_notes: {class: "read", path: "/path"}, shell: {class: "shell", command: "/cmd"}, mcp: {class: "other"},
          model_call: {class: "other"}, env: {class: "other"}, say: {class: "other"}},
  global_id: $g, install_id: $i}' <<<"${BASE:-{\}}")
HK=$(jq -c '[.entries[] | select(.policy.hook)][0].policy.hook // empty' "$AF")
ed .stella/adapters.json --argjson f "$FAKE" --argjson h "${HK:-null}" --arg g "$(uuid)" \
  '.entries += [$f | del(.policy.hook), ($f + {id: "qa-hook", global_id: $g} | .supports.hook = true | .policy.hook = $h | .policy.target.owned_pointers += [$h.pointer])] | .env_keep += ["STELLA_ROOT"]'
brief() { local a; a=$(jq -c --arg m "qamark-$1.txt" '[{op: "write", path: $m, text: "x"}] + .' <<<"$2"); printf 'QA brief for %s.\nBEGIN-ACTIONS\n%s\nEND-ACTIONS\n' "$1" "$a" >"$T/brief-$1.md"; }
# cli <tag> <adapter> <run> <worktree> <json actions> [more start args]: one run of a fake coding CLI on the api link
cli() { brief "$3" "$5"; run "$1" A start --adapter "$2" --role "$ROLE" --worktree "$4" --brief-file "$T/brief-$3.md" --link qa-api/qa-m1 --run-id "$3" "${@:6}" --json; }
# plant <adapter>: a passing conformance record on the data as it is now (bin/adapter-run-selftest.sh A1)
plant() { python3 -I - "$R/bin" "$1" "$ROLE" "$VER" "$R/$CRF" "$(uuid)" "$IID" <<'PY'
import datetime, json, os, sys
sys.path.insert(0, sys.argv[1]); import adapter
p = sys.argv[5]
doc = json.load(open(p)) if os.path.exists(p) else {"schema_version": 1, "records": []}
doc["records"].append({"adapter": sys.argv[2], "version": sys.argv[4], "role": sys.argv[3], "link": "qa-api/qa-m1", "conn_type": "api", "passed": True, "result": "pass", "cases": {},
                       "digests": adapter.digests(sys.argv[2], sys.argv[3]), "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                       "global_id": sys.argv[6], "install_id": sys.argv[7]})
os.makedirs(os.path.dirname(p), exist_ok=True); json.dump(doc, open(p, "w"))
PY
}
echo "# $ME $S: scratch root $R; decision type '${DEV:-<none in data>}'; kinds $ALLK; role from the table"

case $S in
agent)   # the agent-runtime executor (bin/agent-runtime-selftest.sh harness: a fake AG-UI entry over bin/mock_agui_agent.py, data only)
  printf '#!/bin/sh\nexec python3 -I "%s/bin/mock_agui_agent.py" "$@"\n' "$R" >"$T/pb/qa-agui"; chmod +x "$T/pb/qa-agui"
  AVER=$(qa-agui --version 2>/dev/null | awk '{print $2}')
  PROTO=$(jq -r '.entries[0].id // empty' "$AP" 2>/dev/null)
  tn() { jq -r --arg x "$1" '[.agent_tools[]? | select(.executor == $x)][0].name // empty' "$AF" 2>/dev/null; }
  TW=$(tn write); TR=$(tn read); TS=$(tn shell)
  TOOLMAP=$(jq -c 'def pick(re): ((.parameters.properties // {}) | keys | map(select(test(re))) | .[0]);
    [.agent_tools[]? | {key: .name, value: ({class: .class} + (if .class == "shell" then {command: ("/" + (pick("^(cmd|command)$") // "cmd"))}
      elif .class == "read" or .class == "write" then {path: ("/" + (pick("^(path|file_path|file|filename)$") // "path"))} else {} end))}] | from_entries' "$AF" 2>/dev/null)
  KINDS=$(jq -c '[.rules[].kind | select(. != "model_limits")] | unique' "$R/.stella/policy.json")
  [ -f "$AP" ] && ed .stella/agent-protocols.json '.entries |= map(if has("max_turns") then .max_turns = ([.max_turns, 20] | max) else . end)'
  [ -f "$AP" ] && ed .stella/adapters.json --argjson e "$(jq -nc --arg p "$PROTO" --arg v "${AVER:-none}" --arg te "$TE" --argjson tm "${TOOLMAP:-{\}}" --argjson k "$KINDS" --arg g "$(uuid)" --arg i "$IID" \
    '{id: "qa-agui", kind: "agent-runtime", label: "QA fake AG-UI agent", binary: "qa-agui", version_cmd: ["qa-agui", "--version"], tested_versions: [$v],
      status: "active", unboxed: true, conn_types: ["api"], protocol: $p, token_env: $te,
      start: {argv: ["qa-agui", "--port", "0", "--model", "{model}", "--cwd", "{worktree}", "--idle-s", "120"], env: {base_url_env: "QA_AGUI_BASE_URL", token_env: $te}},
      tools: $tm, config_files: [], policy: {hook: {kinds: $k}}, global_id: $g, install_id: $i}')" '.entries += [$e]'
  act() { jq -nc --arg op "$1" --arg t "$2" --argjson f "$3" '{op: $op} + (if $t != "" then {tool: $t} else {} end) + $f'; }
  # ag <tag> <run> <json actions>: a card-less run of qa-agui in a fresh worktree ($W); waits for its end; d = 0 when it ended
  ag() { W=$(wt "$2"); brief "$2" "$3"; run "$1" A start --adapter qa-agui --role "$ROLE" --worktree "$W" --brief-file "$T/brief-$2.md" --link qa-api/qa-m1 --run-id "$2" --json; done_ "$2"; d=$?; }
  wr() { act write "$TW" "$(jq -nc --arg p "$1" '{path: $p, text: "QA"}')"; }
  sh_() { act shell "$TS" "$(jq -nc --arg c "$1" '{cmd: $c}')"; }
  ok '[ -n "$PROTO" ] && [ -n "$TW" ] && [ -n "$TR" ] && [ -n "$TS" ] && jq -e ".entries[] | select(.id == \"qa-agui\")" "$AF"' "precondition: the fake AG-UI entry (protocol ${PROTO:-none}; write ${TW:-none}, read ${TR:-none}, shell ${TS:-none} tools) is in the scratch data"
  deny enforce file_write; e0=$(nl "$EV")
  ag a1 qa-run-a1 "$(jq -nc --argjson a "$(wr qa-a1.txt)" --argjson b "$(sh_ 'touch qa-a1-shell.txt')" '[$a, $b]')"
  ok '[ $d = 0 ] && [ ! -e "$W/qa-a1.txt" ] && res qa-run-a1 qa-a1.txt | jq -e "select(.ok == false)" | has . && [ "$(newdec "$e0" "{\"kind\": \"file_write\", \"verdict\": \"refuse\"}")" -ge 1 ]' \
    "AC4-enforce-refuse/T-hooks agent-runtime write, enforce, no allow for file_write: no file, tool_result ok false, a file_write refuse decision line"
  ok '[ $d = 0 ] && [ -e "$W/qa-a1-shell.txt" ] && [ "$(newdec "$e0" "{\"kind\": \"shell\", \"verdict\": \"allow\"}")" -ge 1 ]' "T-hooks agent-runtime control in the same run: a shell call the policy permits runs, with an allow line (the refusal is the kind's)"
  deny enforce shell; e0=$(nl "$EV")
  ag a2 qa-run-a2 "$(jq -nc --argjson b "$(sh_ 'touch qa-a2-shell.txt')" '[$b]')"
  ok '[ $d = 0 ] && [ ! -e "$W/qa-a2-shell.txt" ] && res qa-run-a2 qa-a2-shell | jq -e "select(.ok == false)" | has . && [ "$(newdec "$e0" "{\"kind\": \"shell\", \"verdict\": \"refuse\"}")" -ge 1 ]' \
    "AC4-enforce-refuse/T-hooks agent-runtime shell, enforce, no allow for shell: the command never ran, tool_result ok false, a shell refuse line"
  deny enforce file_read; e0=$(nl "$EV"); RD=QA-READ-$RANDOM$RANDOM
  W=$(wt qa-run-a3); printf '%s\n' "$RD" >"$W/qa-a3.txt"; brief qa-run-a3 "$(jq -nc --argjson r "$(act read "$TR" '{"path": "qa-a3.txt"}')" '[$r]')"
  run a3 A start --adapter qa-agui --role "$ROLE" --worktree "$W" --brief-file "$T/brief-qa-run-a3.md" --link qa-api/qa-m1 --run-id qa-run-a3 --json; done_ qa-run-a3; d=$?
  ok '[ $d = 0 ] && res qa-run-a3 qa-a3.txt | jq -e "select(.ok == false)" | has . && ! grep -rqF -- "$RD" "$R/$AR/qa-run-a3" "$EV" && [ "$(newdec "$e0" "{\"kind\": \"file_read\", \"verdict\": \"refuse\"}")" -ge 1 ]' \
    "AC4-enforce-refuse/T-hooks agent-runtime read, enforce, no allow for file_read: tool_result ok false, the content in no run file or event line, a file_read refuse line"
  deny enforce tool_call; e0=$(nl "$EV")
  ag a4 qa-run-a4 "$(jq -nc --argjson a "$(wr qa-a4.txt)" '[$a]')"
  ok '[ $d = 0 ] && [ ! -e "$W/qa-a4.txt" ] && [ "$(newdec "$e0" "{\"kind\": \"tool_call\", \"verdict\": \"refuse\"}")" -ge 1 ]' "AC4-enforce-refuse/T-hooks agent-runtime, enforce, no allow for tool_call: the offered write never ran, a tool_call refuse line"
  deny audit file_write; e0=$(nl "$EV")
  ag a5 qa-run-a5 "$(jq -nc --argjson a "$(wr qa-a5.txt)" '[$a]')"
  ok '[ $d = 0 ] && [ -e "$W/qa-a5.txt" ] && res qa-run-a5 qa-a5.txt | jq -e "select(.ok == true)" | has . && [ "$(newdec "$e0" "{\"kind\": \"file_write\", \"verdict\": \"would-refuse\"}")" -ge 1 ]' \
    "AC4-audit agent-runtime write, audit, no allow for file_write: the file is written (ok true), a would-refuse line"
  deny off file_write; e0=$(nl "$EV")
  ag a6 qa-run-a6 "$(jq -nc --argjson a "$(wr qa-a6.txt)" --argjson b "$(sh_ 'touch qa-a6-shell.txt')" '[$a, $b]')"
  ok 'hooked file_write agent_runtime.py && hooked tool_call agent_runtime.py && [ $d = 0 ] && [ -e "$W/qa-a6.txt" ] && [ -e "$W/qa-a6-shell.txt" ] && nodec "$e0"' \
    "AC4-off agent-runtime (its hooks registered), off with a denying policy: write and shell run as today, no decision line"
  # fix round G (pass 3, new cases): the gateway judges the canonical path (resolved against the run's cwd), so a Cedar policy on the
  # worktree holds for every spelling of the same file (real cedar-wasm: node_modules read only from the source tree)
  [ -d "$ROOT/node_modules" ] && ln -s "$ROOT/node_modules" "$R/node_modules"; cp "$ROOT/package.json" "$ROOT/package-lock.json" "$R/" 2>/dev/null
  cedar() { setpol enforce '{}' cedar "$(jq -nc --arg t "$1" --arg u "${2:-}" '[[["tool_call"], "permit(principal, action == Stella::Action::\"tool_call\", resource);"], [["file_write"], $t]] + (if $u != "" then [[["file_write"], $u]] else [] end)')"; }
  agr() { brief "$1" "$2"; run "$1" A start --adapter qa-agui --role "$ROLE" --worktree "$W" --brief-file "$T/brief-$1.md" --link qa-api/qa-m1 --run-id "$1" --json; done_ "$1"; }
  W=$(wt qa-rel-a); cedar "permit(principal, action == Stella::Action::\"file_write\", resource) when { context has path && context.path like \"$W/*\" };"
  agr qa-rel-a "$(jq -nc --argjson a "$(wr "$W/abs.txt")" --argjson b "$(wr rel.txt)" '[$a, $b]')"
  ok '[ -e "$W/abs.txt" ] && [ -e "$W/rel.txt" ]' "T-hooks agent-runtime canonical path: a policy permitting writes inside the worktree allows the absolute and the relative spelling"
  W=$(wt qa-rel-b); mkdir -p "$W/protected"
  cedar "permit(principal, action == Stella::Action::\"file_write\", resource);" "forbid(principal, action == Stella::Action::\"file_write\", resource) when { context has path && context.path like \"$W/protected/*\" };"
  agr qa-rel-b "$(jq -nc --argjson a "$(wr "$W/protected/abs.txt")" --argjson b "$(wr protected/rel.txt)" --argjson c "$(wr ./protected//dot.txt)" '[$a, $b, $c]')"
  ok '[ ! -e "$W/protected/abs.txt" ] && [ ! -e "$W/protected/rel.txt" ] && [ ! -e "$W/protected/dot.txt" ]' "AC4-enforce-refuse agent-runtime canonical path: a forbid on a worktree folder refuses its absolute, relative and ./x//y spellings"
  # (final-pass tester, mutant P2) a link that exists is resolved too (policy.placed: realpath): a worktree link to the forbidden folder
  # is the same place; control: under a permit-all policy the same write through the link lands in the folder
  W=$(wt qa-rel-c); mkdir -p "$W/protected"; ln -s protected "$W/lnk"; WC=$W
  cedar "permit(principal, action == Stella::Action::\"file_write\", resource);"
  agr qa-rel-c "$(jq -nc --argjson a "$(wr lnk/ctl.txt)" '[$a]')"
  W=$(wt qa-rel-d); mkdir -p "$W/protected"; ln -s protected "$W/lnk"
  cedar "permit(principal, action == Stella::Action::\"file_write\", resource);" "forbid(principal, action == Stella::Action::\"file_write\", resource) when { context has path && context.path like \"$W/protected/*\" };"
  agr qa-rel-d "$(jq -nc --argjson a "$(wr lnk/via-link.txt)" '[$a]')"
  ok '[ -e "$WC/protected/ctl.txt" ] && [ ! -e "$W/protected/via-link.txt" ]' "AC4-enforce-refuse agent-runtime canonical path (final-pass tester): a forbid on a worktree folder refuses a write through a worktree link to it (control: the link write lands when permitted)"
  ;;
mcp)   # capabilities_mcp tools/call (bin/capabilities-mcp-selftest.sh harness: a fake skill as data, a minted run token, MCP over HTTP)
  SRC=$(ix '[.capability_sources // empty | .. | strings]')
  SK=$(jq -r '[.[] | select((endswith(".json") or startswith(".stella/extensions")) | not)][0] // ".claude/skills"' <<<"${SRC:-[]}")
  mkdir -p "$R/$SK/qa-fake-skill"
  printf -- '---\nname: qa-fake-skill\ndescription: qazebra fake skill for the gateway hooks selftest\n---\nQA-SKILL-BODY use the zebra.\n' >"$R/$SK/qa-fake-skill/SKILL.md"
  ed .stella/capabilities.json --arg s "$SK/qa-fake-skill/SKILL.md" --arg a "$ROLE" --arg g "$(uuid)" --arg i "$IID" \
    '.entries += [{id: "qa-fake-skill", kind: "skill", summary: "qazebra fake skill for the gateway hooks selftest", keywords: ["qazebra"], inputs: "none", outputs: "text",
      allowed_roles: [$a], risk_class: "read", hosts: [], secrets: [], status: "approved", source: $s, triage: {result: "shipped"}, definition: {text: "QA-SKILL-DEF"}, global_id: $g, install_id: $i}]'
  cat >"$T/mcp.py" <<'PYM'
import http.client, json, sys
# mcp.py <port> <token> <tool> <args json>: initialize + initialized + tools/call in one session; prints {status, body}
port, tok, tool, args = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
sid = None
def post(body):
    global sid
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream", "Authorization": "Bearer " + tok}
    if sid: h["Mcp-Session-Id"] = sid
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    c.request("POST", "/mcp", body=body.encode(), headers=h)
    r = c.getresponse(); txt = r.read().decode("utf-8", "replace")
    sid = r.getheader("Mcp-Session-Id") or sid
    if txt.lstrip().startswith(("event:", "data:")):
        txt = "\n".join(l[5:].strip() for l in txt.splitlines() if l.startswith("data:"))
    return r.status, txt
st, txt = post(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "qa", "version": "0"}}}))
if st == 200:
    post(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}))
    st, txt = post(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": tool, "arguments": json.loads(args)}}))
try:
    body = json.loads(txt)
except ValueError:
    body = txt
print(json.dumps({"status": st, "body": body}))
PYM
  TK=$(mint --run qa-run-m1 --role "$ROLE" --card qa-card-m1 --link qa-api/qa-m1)
  load() { run "$1" python3 -I "$T/mcp.py" "$MP" "$TK" load '{"id": "qa-fake-skill"}'; }
  answered() { [ "$(jq -r .status "$T/o/$1.out")" = 200 ] && jq -e '.body.result != null and (.body.result.isError // false) == false' "$T/o/$1.out" >/dev/null; }
  refused() { jq -e '.body.error != null or .body.result.isError == true' "$T/o/$1.out" >/dev/null && has -E "$GCODE" "$T/o/$1.out"; }
  ok '[ -n "$TK" ] && python3 -I "$R/bin/stella_data.py" check' "precondition: a run token minted, the scratch registry with the fake skill passes check"
  deny enforce mcp_call; e0=$(nl "$EV")
  load m1
  ok 'refused m1 && ! has QA-SKILL "$T/o/m1.out" && [ -z "$(newev "$e0" capability-load)" ] && [ "$(newdec "$e0" "{\"kind\": \"mcp_call\", \"verdict\": \"refuse\"}")" -ge 1 ]' \
    "AC4-enforce-refuse/T-hooks MCP tools/call load, enforce, no allow for mcp_call: refused with a gateway code, no definition, no capability-load line, an mcp_call refuse line"
  deny audit mcp_call; e0=$(nl "$EV")
  load m2
  ok 'answered m2 && [ -n "$(newev "$e0" capability-load)" ] && [ "$(newdec "$e0" "{\"kind\": \"mcp_call\", \"verdict\": \"would-refuse\"}")" -ge 1 ]' "AC4-audit MCP load, audit: answered, its capability-load line, an mcp_call would-refuse line"
  deny off mcp_call; e0=$(nl "$EV")
  load m3
  ok 'hooked mcp_call capabilities_mcp.py && answered m3 && [ -n "$(newev "$e0" capability-load)" ] && nodec "$e0"' "AC4-off MCP load (its hook registered), off: answered and logged as today, no decision line"
  # fix round G (pass 3, new cases): the PDP route canonicalises a worker's path against the cwd it sends, and refuses a relative path with none
  pdp_() { run "$1" python3 -I "$T/mcp.py" "$MP" "$TK" gateway.decide "$2"; }
  allowall enforce; e0=$(nl "$EV"); mkdir -p "$T/pcwd/sub"
  pdp_ m4 "$(jq -nc --arg c "$T/pcwd" '{kind: "file_write", inputs: {path: "sub/../qa-p.txt", cwd: $c}}')"
  ok 'jq -e ".body.result.structuredContent.verdict == \"allow\"" "$T/o/m4.out" && [ "$(newdec "$e0" "{\"kind\": \"file_write\", \"path\": \"$T/pcwd/qa-p.txt\", \"cwd\": \"$T/pcwd\"}")" -ge 1 ]' \
    "T-hooks PDP route: a relative path is decided (and logged) as the absolute path under the cwd the hook sent"
  pdp_ m5 '{"kind": "file_write", "inputs": {"path": "qa-p.txt"}}'
  ok 'jq -e ".body.result.isError == true" "$T/o/m5.out" && has STL-GRD-748 "$T/o/m5.out"' "T-hooks PDP route: a relative path with no absolute cwd is refused STL-GRD-748 (it cannot be placed)"
  ;;
proxy)   # model_proxy upstream forward (bin/model-proxy-selftest.sh call shape)
  HDR=$(jq -r '.entries[0].request.headers | keys[0]' "$R/.stella/protocols.json"); HTPL=$(jq -r --arg h "$HDR" '.entries[0].request.headers[$h]' "$R/.stella/protocols.json")
  PPATH=$(jq -r '.entries[0].request.path' "$R/.stella/protocols.json")
  TK=$(mint --run qa-run-p1 --role "$ROLE" --card qa-card-p1 --link qa-api/qa-m1)
  pcall() { run "$1" python3 -I "$T/cli.py" 127.0.0.1 "$PPORT" POST "$PPATH" "$(jq -nc '{model: "qa-m1", messages: [{role: "user", content: "say ok"}], max_tokens: 5}')" \
    "$(jq -nc --arg h "$HDR" --arg v "${HTPL/\{key\}/$TK}" '{"Content-Type": "application/json", ($h): $v}')"; }
  pst() { jq -r .status "$T/o/$1.out" 2>/dev/null; }
  ok '[ -n "$TK" ] && [ -n "$PPORT" ] && [ -n "$PORT" ]' "precondition: the mock upstream (port ${PORT:-none}) and the proxy (port ${PPORT:-none}) run, a run token is minted"
  deny enforce network_request; e0=$(nl "$EV"); k0=$(calls)
  pcall p1
  ok '[ "$(pst p1)" -ge 400 ] && has -E "$GCODE" "$T/o/p1.out" && [ "$(calls)" = "$k0" ] && [ "$(newdec "$e0" "{\"kind\": \"network_request\", \"verdict\": \"refuse\"}")" -ge 1 ]' \
    "AC4-enforce-refuse/T-hooks proxy call, enforce, no allow for network_request: HTTP >= 400 with a gateway code, no upstream request, a network_request refuse line"
  deny audit network_request; e0=$(nl "$EV"); k0=$(calls)
  pcall p2
  ok '[ "$(pst p2)" = 200 ] && [ "$(calls)" = $((k0 + 1)) ] && [ "$(newdec "$e0" "{\"kind\": \"network_request\", \"verdict\": \"would-refuse\"}")" -ge 1 ]' "AC4-audit proxy call, audit: forwarded once (200), a network_request would-refuse line"
  deny off network_request; e0=$(nl "$EV"); k0=$(calls)
  pcall p3
  ok 'hooked network_request model_proxy.py && [ "$(pst p3)" = 200 ] && [ "$(calls)" = $((k0 + 1)) ] && nodec "$e0"' "AC4-off proxy call (its hook registered), off: forwarded once as today, no decision line"
  ;;
broker)   # credentials.get (in process, as bin/route.py calls it): the value comes back only when the gateway lets it
  cat >"$T/get.py" <<'PY'
import hashlib, json, os, sys
sys.path.insert(0, sys.argv[1]); import credentials
count = lambda p: sum(1 for _ in open(p)) if os.path.exists(p) else 0
before = count(sys.argv[3])
try:
    v = credentials.get(sys.argv[2]); out = {"got": True, "sha": hashlib.sha256(v.encode()).hexdigest()}   # never the value itself
except credentials.Refused as e:
    out = {"got": False, "code": e.code}
out["lines_at_return"] = count(sys.argv[3]) - before
print(json.dumps(out))
PY
  KSHA=$(printf '%s' "$KEY" | sha256sum | awk '{print $1}')
  get() { run "$1" python3 -I "$T/get.py" "$R/bin" "$KN" "$EV"; }
  deny off qa-no-such-kind; get b0
  ok '[ $RC = 0 ] && jq -e --arg s "$KSHA" ".got == true and .sha == \$s" "$T/o/b0.out"' "precondition: credentials.get reads the scratch key (folder backend) with everything allowed"
  deny enforce broker_call; e0=$(nl "$EV")
  get b1
  ok 'jq -e ".got == false" "$T/o/b1.out" && has -E "$GCODE" "$T/o/b1.out" && [ "$(newdec "$e0" "{\"kind\": \"broker_call\", \"verdict\": \"refuse\"}")" -ge 1 ]' \
    "AC4-enforce-refuse/T-hooks credentials.get, enforce, no allow for broker_call: Refused with a gateway code, no value, a broker_call refuse line"
  deny audit broker_call; e0=$(nl "$EV")
  get b2
  ok 'jq -e --arg s "$KSHA" ".got == true and .sha == \$s and .lines_at_return >= 1" "$T/o/b2.out" && [ "$(newdec "$e0" "{\"kind\": \"broker_call\", \"verdict\": \"would-refuse\"}")" -ge 1 ] && ! grep -rqF --exclude-dir=qa-keys -- "$KEY" "$R/.supervisor" "$T/sup"' \
    "AC4-audit credentials.get, audit: the value comes back, the would-refuse line already written when get returns, the key value in no log line"
  deny off broker_call; e0=$(nl "$EV")
  get b3
  ok 'hooked broker_call credentials.py && jq -e --arg s "$KSHA" ".got == true and .sha == \$s" "$T/o/b3.out" && nodec "$e0"' "AC4-off credentials.get (its hook registered), off: the value as today, no decision line"
  ;;
host)   # host_access decide (bin/host-access-selftest.sh baseline: the operator role, attended run, owner present, allowed app and action)
  H() { timeout 60 python3 -I "$R/bin/host_access.py" "$@"; }
  gi() { jq -c --arg i "$IID" '[.[] | . + {install_id: $i}]' | python3 -I -c 'import json, sys, uuid; print(json.dumps([dict(x, global_id=str(uuid.uuid4())) for x in json.load(sys.stdin)]))'; }
  OP=$ROLE; jq --arg op "$OP" '.roles[$op].host_operator = true' "$RJ" >"$RJ.n" && mv "$RJ.n" "$RJ"
  ALL=$(jq -c '.roles | keys' "$RJ")
  ed .stella/capabilities.json --argjson r "$ALL" --arg g "$(uuid)" --arg i "$IID" '.entries += [{id: "qa-host-act", kind: "tool", summary: "qa fake host_session capability", keywords: ["qa"], inputs: "none", outputs: "none",
    allowed_roles: $r, risk_class: "host_session", hosts: [], secrets: [], status: "approved", source: "qa", triage: {result: "shipped"}, global_id: $g, install_id: $i}]'
  HA=$R/$(ix '.files[] | select(.id == "host-access") | .path')
  jq -n --argjson ro "$(echo '[{"id":"qa-typed","enabled":true,"kind":"typed_host"}]' | gi)" --argjson ac "$(echo '[{"id":"qa-open","state":"run","reversible":true}]' | gi)" \
    --argjson ap "$(echo '[{"id":"qa-editor","enabled":true}]' | gi)" --argjson dm "$(echo '[{"id":"qa.example","enabled":true}]' | gi)" --argjson is '[]' \
    '{schema_version: 1, enabled: true, routes: $ro, actions: $ac, apps: $ap, domains: $dm, overrides: [], input_sources: $is}' >"$HA"
  HP=$(ix '.host_presence // empty')
  mkdir -p "$R/$AR"; jq -nc --arg op "$OP" --arg g "$(uuid)" --arg i "$IID" '{run: "qa-run-att", role: $op, card: "qa-card-h", unattended: false, background: false, global_id: $g, install_id: $i}' >"$R/$AR/qa-run-att.json"
  mkdir -p "$(dirname "$R/$HP")"; jq -n --arg g "$(uuid)" --arg i "$IID" '{schema_version: 1, at: (now | todate), run: "qa-run-att", request: "qa-req-h", route: "qa-typed", device: null,
    presence: {indicator: true, kill_switch: true, input_indicators: {}}, final: {state: "submitted", turn: null}, global_id: $g, install_id: $i}' >"$R/$HP"
  jq -n --arg op "$OP" '{capability: "qa-host-act", role: $op, run: "qa-run-att", request: "qa-req-h", target: {app: "qa-editor", domain: "qa.example"}, action: {type: "qa-open"}, confirmation: null}' >"$T/req.json"
  hdec() { run "$1" H decide --request "$T/req.json" --json; }
  deny off host_session; hdec h0
  ok '[ $RC = 0 ]' "precondition: the baseline host-session request is allowed (host access data as bin/host-access-selftest.sh plants it)"
  deny enforce host_session; e0=$(nl "$EV")
  hdec h1
  ok '[ $RC = 1 ] && out h1 | has -E "$GCODE" && [ "$(newdec "$e0" "{\"kind\": \"host_session\", \"verdict\": \"refuse\"}")" -ge 1 ]' "AC4-enforce-refuse/T-hooks host access decide, enforce, no allow for host_session: refused (exit 1) with a gateway code, a host_session refuse line"
  deny audit host_session; e0=$(nl "$EV")
  hdec h2
  ok '[ $RC = 0 ] && [ "$(newdec "$e0" "{\"kind\": \"host_session\", \"verdict\": \"would-refuse\"}")" -ge 1 ]' "AC4-audit host access decide, audit: allowed, a host_session would-refuse line"
  deny off host_session; e0=$(nl "$EV")
  hdec h3
  ok 'hooked host_session host_access.py && [ $RC = 0 ] && nodec "$e0"' "AC4-off host access decide (its hook registered), off: allowed as today, no decision line"
  ;;
pdp)   # the coding CLI's policy hook (worker side) asks the engine-side PDP route; the fake CLI runs its config's hook for each action
  ok '[ -n "$HK" ] && jq -e ".entries[] | select(.id == \"qa-hook\" and .policy.hook != null)" "$AF"' "precondition: the hook-capable fake CLI entry (the first entry's policy hook) is in the scratch data"
  # pw <tag> <run>: a card-less run of qa-hook whose one action writes qa-<run>.txt in a fresh worktree ($W)
  pw() { W=$(wt "$2"); cli "$1" qa-hook "$2" "$W" "$(jq -nc --arg p "qa-$2.txt" '[{op: "write", path: $p, text: "QA"}]')"; done_ "$2"; d=$?; }
  deny enforce file_write; e0=$(nl "$EV")
  pw d1 qa-run-d1
  ok '[ $d = 0 ] && [ ! -e "$W/qa-qa-run-d1.txt" ] && [ "$(newdec "$e0" "{\"kind\": \"file_write\", \"verdict\": \"refuse\"}")" -ge 1 ]' \
    "AC4-enforce-refuse/T-hooks coding-CLI hook via the PDP route, enforce, no allow for file_write: the write never happened, a file_write refuse line (engine side)"
  deny audit file_write; e0=$(nl "$EV")
  pw d2 qa-run-d2
  ok '[ $d = 0 ] && [ -e "$W/qa-qa-run-d2.txt" ] && [ "$(newdec "$e0" "{\"kind\": \"file_write\", \"verdict\": \"would-refuse\"}")" -ge 1 ]' "AC4-audit coding-CLI hook via the PDP route, audit: the write happened, a would-refuse line"
  deny off file_write; e0=$(nl "$EV")
  pw d3 qa-run-d3
  ok 'hooked file_write capabilities_mcp.py && [ $d = 0 ] && [ -e "$W/qa-qa-run-d3.txt" ] && nodec "$e0"' "AC4-off coding-CLI hook (the PDP route registered for file_write), off: the write happened as today, no decision line (the PDP not asked)"
  allowall enforce; pw d4 qa-run-d4; c4=$([ -e "$W/qa-qa-run-d4.txt" ] && echo y)
  kill "$MPID" 2>/dev/null; wait "$MPID" 2>/dev/null
  pw d5 qa-run-d5
  ok '[ "$c4" = y ] && [ $d = 0 ] && [ ! -e "$W/qa-qa-run-d5.txt" ]' "T-hooks enforce, everything allowed: the write happens while the PDP answers, and is refused once the PDP is unreachable (fail closed)"
  ;;
dc08)   # X1-DC-08: a hookless coding CLI is refused at start in enforce; an off-mode run is stopped when the owner apply turns enforce on
  allowall enforce
  W=$(wt dc8-1); cli s1 qa-fake qa-run-k1 "$W" '[]'
  ok '[ $RC != 0 ] && out s1 | has -E "$G2CODE" && none_ "$W" qa-run-k1' "DC-08 enforce, everything allowed: the hookless coding CLI (no policy hook) is refused at start with STL-GRD-745..752, nothing spawned"
  W=$(wt dc8-2); cli s2 qa-hook qa-run-k2 "$W" '[]'
  ok '[ $RC = 0 ] && spawned "$W" qa-run-k2 && [ "$(newdec 0 "{\"verdict\": \"allow\"}")" -ge 1 ]' "DC-08 control: in the same mode the hook-capable CLI starts and its actions are decided (allow lines)"
  # the owner path (bin/gateway-selftest.sh AC5-owner-only): this root's owner key; identity_critical takes the key alone (no terminal in a test)
  deny off qa-no-such-kind; cp "$GP" "$T/gp.off"; jq '.mode.global = "enforce"' "$T/gp.off" >"$T/gp.cand"
  git -C "$R" init -q 2>/dev/null; printf '.supervisor/\n.scratch/\nnode_modules\n' >"$R/.gitignore"
  git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c user.name=qa -c user.email=qa@example.invalid commit -qm base >/dev/null 2>&1
  python3 -I "$R/bin/owner_auth.py" init-key >/dev/null 2>&1
  jq '.actions.identity_critical = .actions.owner_write' "$POL" >"$T/oa" && cp "$T/oa" "$POL"
  W=$(wt dc8-3); cli s3 qa-fake qa-run-k3 "$W" '[{"op": "shell", "cmd": "sleep 45"}, {"op": "write", "path": "qa-after.txt", "text": "x"}]'
  spawned "$W" qa-run-k3; sp=$?
  ok '[ $RC = 0 ] && [ $sp = 0 ] && rec qa-run-k3 | jq -e "[paths(type == \"string\") as \$p | select((\$p | map(tostring) | join(\".\") | test(\"gateway\")) and (getpath(\$p) == \"off\"))] | length > 0"' \
    "DC-08 mode off: the hookless CLI starts, and its run record keeps the start mode off (a gateway key path)"
  e0=$(nl "$EV")
  run ap1 python3 -I "$R/bin/stella-apply.py" apply "${GPID:-no-gateway-policy-row}" --from "$T/gp.cand"
  for i in $(seq 40); do rec qa-run-k3 | jq -e '.stopped != null' >/dev/null 2>&1 && break; sleep 0.5; done
  ok '[ $RC = 0 ] && rec qa-run-k3 | jq -e "(.stopped | tostring | test(\"gateway\"; \"i\"))" && [ "$(newev "$e0" adapter.run-stopped | grep -c qa-run-k3)" = 1 ] && sleep 2 && [ ! -e "$W/qa-after.txt" ]' \
    "DC-08 the owner apply turning the global mode to enforce stops the running off-mode run: stopped (reason names the gateway), one adapter.run-stopped line, its next action never ran"
  # fix round G (pass 3, new cases): a recorded process group is signalled only while it is still the run's (its pid's /proc start
  # fingerprint as recorded at start); else the record is marked ended and nothing is signalled (a recycled pid is someone else's)
  setsid sleep 300 & GH=$!; for i in $(seq 20); do [ -r "/proc/$GH/stat" ] && break; sleep 0.1; done
  ghost() { jq -nc --arg r "$1" --arg role "$ROLE" --arg w "$W" --argjson p "$GH" --arg g "$(uuid)" --arg i "$IID" '{schema_version: 1, run: $r, role: $role, card: null, project: null, adapter: "qa-fake",
    worktree: $w, pid: $p, pgid: $p, pid_start: "qa-not-this-process", started: "2026-01-01T00:00:00Z", ended: null, exit: null, stopped: null, gateway: {mode: "off", hooked: false}, global_id: $g, install_id: $i}' >"$R/$AR/$1.json"; }
  ghost qa-run-g1; jq '.mode.projects = {"qa-proj-z": "enforce"}' "$GP" >"$T/gp.cand2"
  run ap2 python3 -I "$R/bin/stella-apply.py" apply "${GPID:-no-gateway-policy-row}" --from "$T/gp.cand2"
  ok '[ $RC = 0 ] && kill -0 "$GH" && rec qa-run-g1 | jq -e ".ended != null and .stopped != null"' "DC-08 the sweep meets a record whose pgid is no longer its run's process: nothing signalled (the process lives), the record marked ended"
  ghost qa-run-g2; run st2 A stop --run qa-run-g2 --reason "qa ghost"
  ok '[ $RC = 0 ] && kill -0 "$GH" && rec qa-run-g2 | jq -e ".ended != null"' "DC-08 adapter.py stop on such a record: nothing signalled, the record marked ended"
  kill "$GH" 2>/dev/null
  W=$(wt dc8-4); cli s4 qa-hook qa-run-k4 "$W" '[]'; spawned "$W" qa-run-k4
  ok 'rec qa-run-k4 | jq -e ".pid_start | type == \"string\" and length > 0"' "DC-08 a started run's record keeps its process's start fingerprint (pid_start)"
  ;;
dc09)   # X1-DC-09: adapter.py start takes the project from the card's board binding and refuses another --project
  cat >"$T/pb/hermes" <<'SH'
#!/usr/bin/env bash
# the board: `kanban ... show <card> --json` answers the card bound to project qa-proj-a; anything else is an empty list
prev=; for a; do if [ "$prev" = show ]; then printf '{"task": {"id": "%s", "status": "running", "assignee": null, "project": "qa-proj-a"}}\n' "$a"; exit 0; fi; prev=$a; done
echo "[]"
SH
  chmod +x "$T/pb/hermes"; plant qa-hook 2>>"$T/o/last"
  allowall off
  W1=$T/wt-card-9a; mkwt "$W1" >/dev/null 2>&1; W2=$T/wt-card-9b; mkwt "$W2" >/dev/null 2>&1
  cli s1 qa-hook qa-run-n1 "$W1" '[]' --card qa-card-n1 --project qa-proj-b; r1=$RC; cp "$T/o/s1.out" "$T/o/s1.keep"; cat "$T/o/s1.err" >>"$T/o/s1.keep"
  cli s2 qa-hook qa-run-n2 "$W2" '[]' --card qa-card-n2 --project qa-proj-a; r2=$RC
  ok '[ $r1 != 0 ] && has -E "$GCODE" "$T/o/s1.keep" && none_ "$W1" qa-run-n1 && [ $r2 = 0 ] && spawned "$W2" qa-run-n2' \
    "DC-09 start --card with --project other than the card's board binding (qa-proj-b vs qa-proj-a) is refused with a code, nothing spawned; the bound project starts"
  ;;
lint)   # AC5-lint on the shipped data, and every kind's hook at its site (T-hooks)
  run l1 python3 -I "$R/bin/gateway.py" lint
  ok '[ $RC = 0 ]' "AC5-lint the shipped data passes gateway.py lint"
  for kf in tool_call:agent_runtime.py file_read:agent_runtime.py file_write:agent_runtime.py shell:agent_runtime.py mcp_call:capabilities_mcp.py \
            network_request:model_proxy.py broker_call:credentials.py host_session:host_access.py; do
    ok 'hooked "${kf%%:*}" "${kf#*:}"' "T-hooks gateway.json registers kind ${kf%%:*} with its hook in bin/${kf#*:}"
  done
  ;;
esac
finish
