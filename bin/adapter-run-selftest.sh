#!/usr/bin/env bash
# Hermetic self-test for the adapter integration of run policy and stuck watch (F3 item X2; body B6, B7, B8, B10, AC6, AC9, AC11; design
# sections 3, 3b, 3c, 7, 8, 9 with rulings DC-06, DC-07). Every section runs in its own scratch root (bash adapter-run-selftest.sh <section>);
# no argument runs them all.
# Sections -> checks: lean = AC11-lean | resume = AC11-resume | budget = AC9-output-budget | filter = AC9-filter | stuck = AC9-stuck (full:
#   stop, block, lease) | attached = AC6-brief, AC6-load-log (end to end through a card run)
# Every run is a real bin/adapter.py start of the fake adapter (a data entry over bin/mock_agent.py, the harness of
# bin/adapter-selftest.sh): the mock upstream, the model proxy and the capabilities MCP server (bin/capabilities_mcp.py) run on free ports.
# Written test-first (F3 wave 4): exit codes, files, the trusted event log, events.jsonl and code ranges (STL-LIM-450..459 X) are asserted,
# never wording.
# ASSUMPTIONS (names the design leaves open; a builder who picks otherwise changes the test with a note, not the contract):
#  A1 a card run needs a passing conformance record (DC-06/07): the test plants one in the file at index key conformance_records
#     ({records: [{adapter, version, role, passed, digests: adapter.digests(adapter, role), ...}]}, the shape adapter.py gate() reads);
#     until item Q ships that index key, the scratch index gets it (and the scratch index schema the property).
#  A2 the adapter merges bin/run_policy.py translate's settings for (adapter, role) into the run's generated settings file in
#     <adapter_runs>/<run>/cfg/; the fake entry declares supports.deferred_tools true and run_policy.deferred_tools {"qa_tools": {"core": "{value}"}},
#     so the run's tool list is /qa_tools/core; the MCP config (the capabilities server) lies in the same cfg folder.
#  A3 the working-notes path is run-policy working_notes.path with {card} filled, relative to the run's worktree; the adapter renders it
#     (path and content) into the prompt (bin/prompt.py render --notes) at <adapter_runs>/<run>/cfg/prompt.md.
#  A4 scripted skip (bin/mock_agent.py, an addition to the 3b contract): an action may carry "step": ID; after a read_notes the fake CLI
#     does not perform (emits nothing for) an action whose step ID is a list item ("- ID") under the notes heading "done" (any level,
#     any case). Without a done list every action runs.
#  A5 the adapter checks the output budget of a run (bin/run_policy.py output-check or the same function) by the time its run record has
#     ended: over budget is one trusted event line naming the run with a code STL-LIM-45x; the run itself is not stopped.
#  A6 for a card run the adapter starts the stuck watch (bin/stuck.py watch --run R --card C --role ROLE) itself; on a match the run
#     record gets ended/exit and stopped (reason holding "stuck"), the trusted event log a run-block line whose evidence lists events of
#     the run, the block argv (.stella/stuck.json block.argv, a hermes stub on PATH records its argv) runs with the card id.
#  A7 the ledger slot of a run is visible as ledger.py status --connection qa-api --model qa-m1 concurrency.in_use (qa-api's model gets a
#     max_concurrent limit as data).
#  A8 a run of an adapter with supports.hook true carries the output filter hook in its generated config (a hook naming log_filter.py),
#     and the tool_result output in events.jsonl passes the role's filters (trim to failing lines with context); ok stays false.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=adapter-run-selftest
SECTIONS="lean resume budget filter stuck attached"
if [ $# = 0 ]; then
  f=0; for s in $SECTIONS; do bash "${BASH_SOURCE[0]}" "$s" || f=$((f+1)); done
  [ $f = 0 ] && echo "$ME PASS" || echo "$ME FAIL ($f sections)"; [ $f = 0 ]; exit
fi
case " $SECTIONS " in *" $1 "*) ;; *) echo "usage: $ME.sh [$(tr ' ' '|' <<<"$SECTIONS")]" >&2; exit 2;; esac
S=$1
# ---- harness: a scratch root of its own (bin, .stella, docs and the root config files copied), its own HOME, temp, alert folder ----
T=$(mktemp -d "${TMPDIR:-/tmp}/$ME.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'kill $(jobs -p) 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "# KEPT $T"; else chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; fi' EXIT
R=$T/root
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$R/.claude" "$T/home" "$T/tmp" "$T/sup/logs" "$T/pb" "$T/o"
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
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH
AL=$T/sup/logs/alerts.log; : >"$AL"
EV=$R/$(ix .event_log)
IID=$(jq -r .install_id "$R/.stella/install.json")
fails=0; n=0
# ok <test> <label>: a FAIL line (never a crash) with the last output of the case under it
ok() { n=$((n+1)); if ( set -o pipefail; eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/o/last" ] && tail -n 3 "$T/o/last" | cut -c1-240 | sed 's/^/     | /'; fi; : >"$T/o/last"; }
finish() { echo "# $ME $S: $n cases, $fails failed"; [ "$fails" = 0 ]; exit $?; }
# run <tag> <cmd...>: stdout to $T/o/<tag>.out, stderr to $T/o/<tag>.err, exit code in RC
run() { local t=$1; shift; "$@" >"$T/o/$t.out" 2>"$T/o/$t.err"; RC=$?; cat "$T/o/$t.out" "$T/o/$t.err" >"$T/o/last" 2>/dev/null; }
out() { cat "$T/o/$1.out" "$T/o/$1.err" 2>/dev/null; }
ed() { local f=$R/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <file under the root> <jq args and filter>
uuid() { cat /proc/sys/kernel/random/uuid; }
nl() { if [ -f "$1" ]; then wc -l <"$1"; else echo 0; fi; }   # line count of a file that may not exist yet
WORKER() { env STUB_WORKER_MARK=1 "$@"; }   # a worker environment (a roles.json worker marker)

A() { python3 -I "$R/bin/adapter.py" "$@"; }
range='STL-GRD-6([45][0-9])'
ROLE=$(jq -r '.roles | keys[0]' "$RJ")
TE=; AR=$(ix '.adapter_runs // empty')
CRK=$(jq -r '[to_entries[] | select((.key | test("conformance")) and (.key | test("record") | not)) | .value | strings][0] // empty' "$IX")
case $CRK in "") CRD=$T/no-conformance-root;; /*) CRD=$CRK;; *) CRD=$R/$CRK;; esac
mkdir -p "$CRD"
# ---- the mock upstream in its own root (it serves each shape under /<shape id>), the key in a folder backend ----
MR=$T/mockroot; mkdir -p "$MR"; cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$MR/"
STELLA_ROOT=$MR ESCALATE_SUP_DIR=$T/sup python3 -I "$R/bin/mock_provider.py" >"$T/mock.out" 2>"$T/mock.err" &
for i in $(seq 100); do [ -s "$T/mock.out" ] && break; sleep 0.1; done
PORT=$(jq -r '.port' "$T/mock.out" 2>/dev/null); CTL=$(jq -r '.control' "$T/mock.out" 2>/dev/null); LO=$(jq -r '.control | capture("//(?<h>[^:/]+):").h' "$T/mock.out" 2>/dev/null)
export NO_PROXY=$LO,127.0.0.1 no_proxy=$LO,127.0.0.1
cat >"$T/cli.py" <<'PYC'
import http.client, json, sys
# <host> <port> <method> <path> <body>: one request, the answer as JSON
c = http.client.HTTPConnection(sys.argv[1], int(sys.argv[2]), timeout=20)
c.request(sys.argv[3], sys.argv[4], body=sys.argv[5].encode(), headers={"Content-Type": "application/json"})
r = c.getresponse(); print(json.dumps({"status": r.status, "body": r.read().decode("utf-8", "replace")}))
PYC
calls() { python3 -I "$T/cli.py" "$LO" "$PORT" GET /_calls '' | jq -r '.body | fromjson | [.counts[]] | add // 0' 2>/dev/null || echo -1; }
SHAPE=$(jq -r '.entries[0].id' "$R/.stella/protocols.json")
ed .stella/protocols.json '.entries |= map(.request.path = "/" + .id + .request.path)'
python3 -I "$T/cli.py" "$LO" "$PORT" POST "/${CTL#*://*/}" "$(jq -nc --arg s "$SHAPE" '{models: {($s): ["qa-m1"]}, faults: []}')" >/dev/null 2>&1
KN=QA_ADAPTER_KEY; KEY="qacanary$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
CD=$(ix .backup_dir)/qa-keys; mkdir -p "$R/$CD"; chmod 700 "$R/$CD"; (umask 077; printf '%s' "$KEY" >"$R/$CD/$KN")
ed .stella/routing.json --arg p "$CD" '.credentials.backend = "qa-dir" | .credentials.backends["qa-dir"] = {kind: "dir", path: $p}'
# ---- the fake connections (data only): qa-api on the mock (a copy of the role's local api link), qa-cli a cli-login link of the fake CLI ----
mdl() { echo "{\"id\":\"$1\",\"capabilities\":{\"tool_calling\":true,\"json_mode\":true,\"context_tokens\":100000,\"vision\":false,\"streaming\":true},\"probed_at\":null,\"probe_source\":\"advertised\",\"cost\":null,\"limits\":null}"; }
LTPL='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "local")][0]'
CTPL='[.entries[] | select(.kind == "provider" and .type == "cli-login")][0]'
DP=$(jq -c "$LTPL | {data_policy, allowed_roles}" "$R/.stella/connections.json")
ed .stella/data-policy.json --arg h "$LO" '(.. | objects | select(has("local_hosts")) | .local_hosts) += [$h]'
ed .stella/connections.json --arg s "$SHAPE" --arg g "$(uuid)" --arg g2 "$(uuid)" --arg h "$LO" --argjson p "${PORT:-9}" --arg k "$KN" --argjson dp "$DP" \
  ".entries += [$LTPL + {id: \"qa-api\", label: \"qa-api\", enabled: true, global_id: \$g, models: [$(mdl qa-m1)], secrets: [\$k], auth_types: [\"api_key\"], protocol: \$s, hosts: [{host: \$h, port: \$p, purpose: \"selftest mock\"}]},
    $CTPL + {id: \"qa-cli\", label: \"qa-cli\", enabled: true, terms_ok: true, cli: \"qa-fake\", models: [$(mdl qa-c1)], locality: \"local\", link_class: \"local\", hosts: [{host: \$h, port: 9, purpose: \"selftest\"}], global_id: \$g2} + \$dp]"
ed .stella/role-assignments.json --arg r "$ROLE" '.effort_modes |= map_values(.roles[$r] = {active: true, escalation_chain: [{connection: "qa-api", model: "qa-m1", parameters: {}}, {connection: "qa-cli", model: "qa-c1", parameters: {}}]})'
# ---- the fake CLI: bin/mock_agent.py behind a wrapper on PATH; its entries are data ----
printf '#!/bin/sh\nexec python3 -I "%s/bin/mock_agent.py" "$@"\n' "$R" >"$T/pb/qa-agent"; chmod +x "$T/pb/qa-agent"
VER=$(qa-agent --version 2>/dev/null | awk '{print $2}')
AF=$R/.stella/adapters.json
BASE=$(jq -c '([.entries[] | select(.status == "active")] + .entries)[0] // {}' "$AF" 2>/dev/null)
TE=$(jq -r '.token_env // empty' <<<"${BASE:-{\}}")
mkdir -p "$HOME/.qa-agent"; CANARY2="qacredcanary$RANDOM$RANDOM"; printf '{"token": "%s"}' "$CANARY2" >"$HOME/.qa-agent/creds.json"
FAKE=$(jq -c --arg v "${VER:-none}" --arg s "$SHAPE" --arg te "$TE" --arg g "$(uuid)" --arg i "$IID" '. + {id: "qa-fake", label: "QA fake agent", binary: "qa-agent",
  version_cmd: ["qa-agent", "--version"], tested_versions: [$v], status: "active", conn_types: ["api", "cli-login"], protocols: [$s],
  start: {argv: ["qa-agent", "--prompt-file", "{prompt_file}", "--config", "{settings_file}", "--model", "{model}", "--mcp-config", "{mcp_config}", "--cwd", "{worktree}"],
          env: {base_url_env: "QA_AGENT_BASE_URL", token_env: $te}},
  cli_login: {credential_paths: ["{home}/.qa-agent/creds.json"], home_env: "HOME"},
  stream: {format: "jsonl", type: "/type", tool_name: "/name", tool_input: "/input", tool_result: "/output", error: "/error",
           usage: {input: "/input_tokens", output: "/output_tokens"}, final_text: "/text"},
  supports: {hook: false, deferred_tools: false, compaction: false, clear_tool_results: false, subagent: false, script_tools: false,
             working_notes: false, skill_use_observable: false, tool_use_observable: true},
  tools: {write: {class: "write", path: "/path"}, edit: {class: "write", path: "/path"}, read: {class: "read", path: "/path"},
          read_notes: {class: "read", path: "/path"}, shell: {class: "shell", command: "/cmd"}, mcp: {class: "other"},
          model_call: {class: "other"}, env: {class: "other"}, say: {class: "other"}},
  global_id: $g, install_id: $i}' <<<"${BASE:-{\}}")
[ -f "$AF" ] && ed .stella/adapters.json --argjson f "$FAKE" '.entries += [$f]'
# addent <id> <jq patch of the fake entry>: one more adapter entry, data only
addent() { ed .stella/adapters.json --argjson f "$FAKE" --arg id "$1" --arg g "$(uuid)" ".entries += [\$f + {id: \$id, global_id: \$g} | $2]"; }
# rec <run> [card]: the run record <adapter_runs>/<run>.json (settled layout); with a card, its card field is set to it first
rec() { local f=$R/$AR/$1.json; [ -n "$AR" ] && [ -s "$f" ] || return 1; [ -z "${2:-}" ] || ed "$AR/$1.json" --arg c "$2" '.card = $c'; cat "$f"; }
# ---- the proxy on an ephemeral port (it writes its own state; the adapter finds it there) ----
python3 -I "$R/bin/model_proxy.py" serve --port 0 >"$T/proxy.out" 2>"$T/proxy.err" &
for i in $(seq 50); do [ -s "$T/proxy.out" ] && break; sleep 0.1; done; PPORT=$(jq -r '.port // empty' "$T/proxy.out" 2>/dev/null)
# mkwt <dir>: a git worktree with one commit (its own identity, so a commit through the fake CLI needs no -c)
mkwt() { mkdir -p "$1" && git -C "$1" init -q && git -C "$1" config user.name qa && git -C "$1" config user.email qa@qa.invalid && echo base >"$1/README" && git -C "$1" add README && git -C "$1" commit -qm base; }
# brief <run> <json action list>: a brief file whose action block the fake CLI runs; every brief first writes the marker qamark-<run>
brief() { local a; a=$(jq -c --arg m "qamark-$1.txt" '[{op: "write", path: $m, text: "x"}] + .' <<<"$2"); printf 'QA brief for %s.\nBEGIN-ACTIONS\n%s\nEND-ACTIONS\n' "$1" "$a" >"$T/brief-$1.md"; }
# go <tag> <run> <worktree> <link> <json actions> [more start args]: start one run of the fake adapter, card-less unless the args say
go() { brief "$2" "$5"; run "$1" A start --adapter qa-fake --role "$ROLE" --worktree "$3" --brief-file "$T/brief-$2.md" --link "$4" --run-id "$2" "${@:6}" --json; }
# done_ <run>: wait (at most 40 s) until evidence answers a numeric exit_code
# (jq 1.6 -e passes on empty input: every jq -e here reads an answer that is known to be non-empty)
done_() { local i o; [ -f "$R/bin/adapter.py" ] || return 1; for i in $(seq 80); do o=$(A evidence --run "$1" --json 2>/dev/null) && [ -n "$o" ] && jq -e '.exit_code | type == "number"' <<<"$o" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }
# spawned <worktree> <run>: the run's marker file appears within 15 s; none_ <worktree> <run>: after 2 s it is still absent
spawned() { local i; for i in $(seq 30); do [ -f "$1/qamark-$2.txt" ] && return 0; sleep 0.5; done; return 1; }
none_() { sleep 2; [ ! -f "$1/qamark-$2.txt" ]; }
evfile() { find "$T" -name events.jsonl -path "*$1*" 2>/dev/null | head -n1; }
WT=$CRD/qa-wt; mkwt "$WT" >/dev/null 2>&1
# ---- shared by the run sections: an argv-recording hermes, a ledger limit, the capabilities server, conformance records ----
cat >"$T/pb/hermes" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$T/hermes.argv"; echo "[]"
EOF
chmod +x "$T/pb/hermes"; : >"$T/hermes.argv"
ed .stella/connections.json '(.entries[] | select(.id == "qa-api") | .models[0].limits) = {max_concurrent: 3}'
inuse() { python3 -I "$R/bin/ledger.py" status --connection qa-api --model qa-m1 2>/dev/null | jq -r '.concurrency.in_use // empty'; }
MP=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I "$R/bin/capabilities_mcp.py" serve --port "$MP" >"$T/mcp.out" 2>"$T/mcp.err" &
for i in $(seq 50); do python3 -I -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2)' "$MP" 2>/dev/null && break; sleep 0.1; done
UEV=$R/$(ix .untrusted_events)
newev() { tail -n +$(($1 + 1)) "$EV" 2>/dev/null | jq -c "select(.type == \"$2\")" 2>/dev/null; }   # <line count before> <type>
CRF=$(ix '.conformance_records // empty')
if [ -z "$CRF" ]; then   # A1: until item Q ships the key, the scratch index gets it (and its schema the property)
  CRF=.supervisor/state/conformance-records.json
  ed .stella/data-files.json --arg p "$CRF" '.conformance_records = $p'
  ed .stella/schemas/data-files.schema.json '.properties.conformance_records = {type: "string"}'
fi
# plant <adapter>: a passing conformance record whose digests match the data as it is now (adapter.digests); call it after the last data edit
plant() { python3 -I - "$R/bin" "$1" "$ROLE" "$VER" "$R/$CRF" "$(uuid)" "$IID" <<'PY'
import datetime, json, os, sys
sys.path.insert(0, sys.argv[1]); import adapter
p = sys.argv[5]
doc = json.load(open(p)) if os.path.exists(p) else {"schema_version": 1, "records": []}
doc["records"].append({"adapter": sys.argv[2], "version": sys.argv[4], "role": sys.argv[3], "passed": True, "result": "pass", "cases": {},
                       "digests": adapter.digests(sys.argv[2], sys.argv[3]), "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                       "global_id": sys.argv[6], "install_id": sys.argv[7]})
os.makedirs(os.path.dirname(p), exist_ok=True); json.dump(doc, open(p, "w"))
PY
}
WC=$T/wt-card; mkwt "$WC" >/dev/null 2>&1   # a card run's worktree (outside the conformance root: the record is its gate)
cfgdir() { echo "$R/$AR/$1/cfg"; }
# evq <run> <jq filter>: the run's events.jsonl lines the filter selects, compact
evq() { local f; f=$(evfile "$1"); [ -s "$f" ] && jq -c "$2" "$f" 2>/dev/null; }
ok '[ -n "$PORT" ] && [ -n "$PPORT" ] && [ -n "$VER" ] && [ -n "$TE" ] && [ -n "$CRK" ] && [ -n "$AR" ] && jq -e ".entries[] | select(.id == \"qa-fake\")" "$AF" && python3 -I "$R/bin/stella_data.py" check && [ -n "$(inuse)" ] && python3 -I -c "import socket, sys; socket.create_connection((\"127.0.0.1\", int(sys.argv[1])), 1)" "$MP"' \
  "precondition: mock upstream, proxy, capabilities server and fake CLI run; the scratch data (new adapter entry, a slot limit on qa-api) passes check; ledger status answers in_use"

case $S in
lean)   # AC11-lean: 30 registered tools for the role; the run starts with its core set only, finds a non-core tool by search and loads it
  CORE='["capabilities.search","capabilities.load","qa-lean-01"]'
  ed .stella/capabilities.json --arg r "$ROLE" --arg i "$IID" --arg g "$(for k in $(seq 30); do uuid; done | paste -sd,)" \
    '($g | split(",")) as $gs | .entries += [range(1; 31) as $k | ($k | tostring | if length == 1 then "0" + . else . end) as $n |
      {id: ("qa-lean-" + $n), kind: "tool", summary: ("qa lean planted tool " + $n), keywords: ["qalean" + $n], inputs: "none", outputs: "text",
       allowed_roles: [$r], risk_class: "read", hosts: [], secrets: [], status: "approved", source: ("qa-planted-tool-" + $n),
       triage: {result: "shipped"}, definition: {text: ("QA-LEAN-DEF-" + $n)}, global_id: $gs[$k - 1], install_id: $i}
      + (if $k == 1 then {core_for_roles: [$r]} else {} end)]'
  ed .stella/run-policy.json --arg r "$ROLE" --argjson c "$CORE" '.roles[$r].core_tools = $c'
  ed .stella/adapters.json '(.entries[] | select(.id == "qa-fake")) |= (.supports.deferred_tools = true | .run_policy = {deferred_tools: {qa_tools: {core: "{value}"}}})'
  ok 'python3 -I "$R/bin/stella_data.py" check && jq -e --arg r "$ROLE" "[.entries[] | select((.id | startswith(\"qa-lean-\")) and (.allowed_roles | index(\$r)))] | length == 30" "$R/.stella/capabilities.json"' \
    "AC11-lean precondition: 30 tools registered for $ROLE (data), core_tools $CORE, the fake entry supports deferred tools"
  e0=$(nl "$EV")
  go s1 qa-run-l1 "$WT" qa-api/qa-m1 '[{"op":"mcp","tool":"search","args":{"query":"qalean17"}},{"op":"mcp","tool":"load","args":{"id":"qa-lean-17"}}]'
  done_ qa-run-l1; d=$?; CF=$(cfgdir qa-run-l1)
  ok '[ $RC = 0 ] && [ $d = 0 ]' "AC11-lean the run started and ended"
  ok 'for f in "$CF"/*; do jq -e --argjson c "$CORE" "(.qa_tools.core | sort) == (\$c | sort)" "$f" && exit 0; done; exit 1' "AC11-lean the run's generated settings list exactly the role's core tools (/qa_tools/core)"
  ok '[ -d "$CF" ] && ! grep -rqE "qa-lean-(0[2-9]|1[0-689]|2[0-9]|30)" "$CF"' "AC11-lean no other of the 30 tools is in any generated file of the run (settings, MCP config, prompt; qa-lean-17 is named by the brief's own action)"
  ok 'grep -rqF "127.0.0.1:$MP" "$CF"' "AC11-lean the run's MCP config names the capabilities server (port $MP)"
  ok 'evq qa-run-l1 "select(.type == \"tool_result\" and .name == \"mcp\" and .ok == true)" | head -n1 | grep -q "qa-lean-17"' "AC11-lean in the run the agent's capability search found qa-lean-17 (events.jsonl)"
  ok 'evq qa-run-l1 "select(.type == \"tool_result\" and .name == \"mcp\" and .ok == true)" | grep -q "QA-LEAN-DEF-17"' "AC11-lean ... and its load returned the tool's definition"
  L=$(newev "$e0" capability-load | grep qa-lean-17)
  ok '[ "$(grep -c . <<<"$L")" = 1 ] && jq -e "[.. | strings] as \$s | all((\"qa-run-l1\", \"$ROLE\", \"qa-lean-17\"); . as \$v | \$s | index(\$v) != null)" <<<"$L"' \
    "AC11-lean the load is one trusted capability-load line naming the run, the role and the tool"
  ;;
resume)   # AC11-resume: a fresh run of a card reads the card's working notes and does not repeat its finished steps
  NP=$(jq -r --arg r "$ROLE" '(.roles[$r].working_notes // .default.working_notes).path' "$R/.stella/run-policy.json")
  steps() { jq -nc --arg p "$1" '[{op: "read_notes", path: $p}] + [range(1; 4) | tostring | {op: "write", path: ("qa-step-" + . + ".txt"), text: ., step: ("qa-step-" + .)}]'; }
  N1=${NP//\{card\}/qa-card-r1}; mkdir -p "$(dirname "$WC/$N1")"
  printf '# working notes qa-card-r1\n## done\n- qa-step-1\n- qa-step-2\n## next\n- qa-step-3\n## decisions\n- QA-DECISION-R1 keep the zebra\n' >"$WC/$N1"
  plant qa-fake
  go s1 qa-run-r1 "$WC" qa-api/qa-m1 "$(steps "$N1")" --card qa-card-r1
  done_ qa-run-r1; d=$?; PF=$(cfgdir qa-run-r1)/prompt.md
  ok '[ $RC = 0 ] && [ $d = 0 ]' "AC11-resume a card run (planted passing conformance record) started and ended"
  ok 'grep -qF -- "$N1" "$PF" && grep -q QA-DECISION-R1 "$PF" && grep -q qa-step-2 "$PF"' "AC11-resume the fresh run's brief holds the working-notes path ($NP) and its content"
  ok 'evq qa-run-r1 "select(.type == \"tool_use\" and .name == \"read_notes\")" | grep -q .' "AC11-resume the agent read its notes"
  ok '[ -s "$(evfile qa-run-r1)" ] && ! evq qa-run-r1 "select(.type == \"tool_use\" and .name == \"write\")" | grep -qE "qa-step-[12]\.txt" && [ ! -e "$WC/qa-step-1.txt" ] && [ ! -e "$WC/qa-step-2.txt" ]' \
    "AC11-resume no write of a finished step (qa-step-1, qa-step-2) in the run's events, and no such file"
  ok 'evq qa-run-r1 "select(.type == \"tool_use\" and .name == \"write\")" | grep -q "qa-step-3.txt" && [ -f "$WC/qa-step-3.txt" ]' "AC11-resume the next step (qa-step-3) was done"
  W2=$T/wt-r2; mkwt "$W2" >/dev/null 2>&1; N2=${NP//\{card\}/qa-card-r2}
  go s2 qa-run-r2 "$W2" qa-api/qa-m1 "$(steps "$N2")" --card qa-card-r2
  done_ qa-run-r2
  ok '[ -f "$W2/qa-step-1.txt" ] && [ -f "$W2/qa-step-2.txt" ] && [ -f "$W2/qa-step-3.txt" ]' "AC11-resume control: a card with no notes file does every step"
  ;;
budget)   # AC9-output-budget: a run whose usage is over the role's output budget is flagged (event line + STL-LIM-45x), not stopped
  OB=$(python3 -I "$R/bin/run_policy.py" show --role "$ROLE" 2>/dev/null | jq -r '.output_budget_tokens // empty')
  ok '[ -n "$OB" ]' "AC9-output-budget precondition: the role's output budget is $OB tokens (run-policy data)"
  e0=$(nl "$EV")
  go s1 qa-run-b1 "$WT" qa-api/qa-m1 '[{"op":"usage","input":10,"output":1}]'
  done_ qa-run-b1
  go s2 qa-run-b2 "$WT" qa-api/qa-m1 "$(jq -nc --argjson o "$((${OB:-0} + 500))" '[{op: "usage", input: 10, output: $o}, {op: "say", text: "QA-AFTER-USAGE"}, {op: "write", path: "qa-after-usage.txt", text: "x"}]')"
  done_ qa-run-b2; d=$?
  for i in $(seq 20); do tail -n +$((e0 + 1)) "$EV" | grep qa-run-b2 | grep -qE 'STL-LIM-45[0-9]' && break; sleep 0.5; done
  ok '[ $d = 0 ] && tail -n +$((e0 + 1)) "$EV" | grep qa-run-b2 | grep -qE "STL-LIM-45[0-9]"' "AC9-output-budget a run over its output budget: a trusted event line naming the run with STL-LIM-45x"
  ok 'rec qa-run-b2 >"$T/o/rec" && jq -e ".exit == 0 and (.stopped == null)" "$T/o/rec" && [ -f "$WT/qa-after-usage.txt" ]' "AC9-output-budget ... flagged, not stopped: the actions after the usage ran, exit 0, no stop"
  ok '[ -n "$(rec qa-run-b1)" ] && ! tail -n +$((e0 + 1)) "$EV" | grep qa-run-b1 | grep -qE "STL-LIM-45[0-9]"' "AC9-output-budget control: a run under its budget is not flagged"
  ;;
filter)   # AC9-filter: a hook-capable fake CLI runs a command that prints a long failing log; events.jsonl holds the failing lines (+ context) only
  addent qa-hook '.supports.hook = true'
  LOGCMD='for i in $(seq 400); do if [ $i = 200 ]; then echo "QA-FAIL-LINE: assertion failed in qa_mod"; else printf "qa-noise-%04d step passed\n" $i; fi; done; exit 1'
  brief qa-run-f1 "$(jq -nc --arg c "$LOGCMD" '[{op: "shell", cmd: $c}]')"
  run s1 A start --adapter qa-hook --role "$ROLE" --worktree "$WT" --brief-file "$T/brief-qa-run-f1.md" --link qa-api/qa-m1 --run-id qa-run-f1 --json
  done_ qa-run-f1; d=$?
  R1=$(evq qa-run-f1 'select(.type == "tool_result" and .name == "shell")' | head -n1)
  ok '[ $RC = 0 ] && [ $d = 0 ] && [ -n "$R1" ] && jq -e ".ok == false" <<<"$R1"' "AC9-filter the hook-capable run ran the failing command; its tool_result keeps ok false (exit code kept)"
  ok 'jq -r .output <<<"$R1" | grep -q QA-FAIL-LINE && jq -r .output <<<"$R1" | grep -q qa-noise-0199 && jq -r .output <<<"$R1" | grep -q qa-noise-0201' "AC9-filter the output holds the failing line and its context lines"
  ok '[ -n "$R1" ] && ! jq -r .output <<<"$R1" | grep -qE "qa-noise-0(100|300|390)" && [ "$(jq -r .output <<<"$R1" | wc -l)" -lt 40 ]' "AC9-filter ... and not the rest of the 400-line log (under 40 lines)"
  ok 'grep -rq log_filter "$(cfgdir qa-run-f1)"' "AC9-filter the run's generated config carries the output filter hook (names log_filter.py)"
  ;;
stuck)   # AC9-stuck full: a planted edit-revert loop stops the card run as a block with evidence and frees its lease
  ed .stella/stuck.json '.poll_s = 1'
  plant qa-fake
  SL=qasleep$RANDOM$RANDOM
  u0=$(inuse); e0=$(nl "$EV")
  go s1 qa-run-s1 "$WC" qa-api/qa-m1 "$(jq -nc --arg c "bash -c 'exec -a $SL sleep 45'" '[{op: "write", path: "qa-loop.txt", text: "A\n"},
     {op: "repeat", times: 20, actions: [{op: "edit", path: "qa-loop.txt", old: "A", new: "B"}, {op: "edit", path: "qa-loop.txt", old: "B", new: "A"}]},
     {op: "shell", cmd: $c}, {op: "write", path: "qa-after-loop.txt", text: "x"}]')" --card qa-card-s1
  mx=0; for i in $(seq 80); do u=$(inuse); [ -n "$u" ] && [ "$u" -gt "$mx" ] && mx=$u; rec qa-run-s1 2>/dev/null | jq -e '.exit != null' >/dev/null 2>&1 && break; sleep 0.5; done
  ok '[ $RC = 0 ] && [ -n "$u0" ] && [ "$mx" -gt "$u0" ]' "AC9-stuck control: the card run started and held a ledger slot (in_use $u0 -> $mx)"
  ok 'rec qa-run-s1 >"$T/o/rec" && jq -e "(.exit != null) and (.ended != null) and ((.stopped // \"\") | test(\"stuck\"))" "$T/o/rec" && ! pgrep -f "$SL" >/dev/null && [ ! -e "$WC/qa-after-loop.txt" ]' \
    "AC9-stuck the loop stopped the run: record ended, stopped for stuck, its process gone, the actions after the loop never ran"
  B=$(newev "$e0" run-block | grep qa-run-s1 | head -n1)
  ok '[ -n "$B" ] && grep -q edit_revert <<<"$B" && jq -e "[.. | objects | select(.seq != null and .run == \"qa-run-s1\")] | length >= 2" <<<"$B"' "AC9-stuck one trusted run-block line: pattern edit_revert, the matching events of the run as evidence"
  ok 'grep -q "block" "$T/hermes.argv" && grep -q qa-card-s1 "$T/hermes.argv"' "AC9-stuck the block command (data argv) ran for the card (hermes stub argv: $(tr '\n' ' ' <"$T/hermes.argv" | cut -c1-80))"
  for i in $(seq 20); do [ "$(inuse)" = "$u0" ] && break; sleep 0.5; done
  ok '[ -n "$u0" ] && [ "$(inuse)" = "$u0" ]' "AC9-stuck the lease is freed: ledger status in_use back to $u0"
  A stop --run qa-run-s1 --reason qa-cleanup >/dev/null 2>&1   # a build that did not stop it: end the run before the scratch root goes
  ;;
attached)   # AC6-brief + AC6-load-log end to end: a card with an attached skill; the brief lists it; the agent's load is a trusted line
  SRC=$(ix '[.capability_sources // empty | .. | strings]')
  SKD=$(jq -r '[.[] | select((endswith(".json") or startswith(".stella/extensions")) | not)][0] // ".claude/skills"' <<<"${SRC:-[]}")
  mkdir -p "$R/$SKD/qa-att-skill"
  printf -- '---\nname: qa-att-skill\ndescription: qaotter attached skill for the adapter-run selftest\n---\nQA-ATT-BODY use the otter.\n' >"$R/$SKD/qa-att-skill/SKILL.md"
  ed .stella/capabilities.json --arg s "$SKD/qa-att-skill/SKILL.md" --arg a "$ROLE" --arg g "$(uuid)" --arg i "$IID" \
    '.entries += [{id: "qa-att-skill", kind: "skill", summary: "qaotter attached skill", keywords: ["qaotter"], inputs: "none", outputs: "text",
      allowed_roles: [$a], risk_class: "read", hosts: [], secrets: [], status: "approved", source: $s, triage: {result: "shipped"},
      definition: {text: "QA-ATT-DEF"}, global_id: $g, install_id: $i}]'
  plant qa-fake
  printf '{"skills": ["qa-att-skill"], "tools": []}' >"$T/card-k1.json"
  e0=$(nl "$EV"); u0=$(nl "$UEV")
  go s1 qa-run-k1 "$WC" qa-api/qa-m1 '[{"op":"mcp","tool":"load","args":{"id":"qa-att-skill"}}]' --card qa-card-k1 --card-file "$T/card-k1.json"
  done_ qa-run-k1; d=$?
  ok '[ $RC = 0 ] && [ $d = 0 ]' "AC6 the card run with an attached skill started and ended"
  ok 'grep -q qa-att-skill "$(cfgdir qa-run-k1)/prompt.md"' "AC6-brief the run's brief lists the attached skill"
  ok 'evq qa-run-k1 "select(.type == \"tool_result\" and .name == \"mcp\" and .ok == true)" | grep -qE "QA-ATT-(BODY|DEF)"' "AC6-load-log the agent's capabilities.load returned the skill"
  L=$(newev "$e0" capability-load)
  ok '[ "$(grep -c . <<<"$L")" = 1 ] && jq -e "[.. | strings] as \$s | all((\"qa-card-k1\", \"qa-run-k1\", \"$ROLE\", \"qa-att-skill\"); . as \$v | \$s | index(\$v) != null)" <<<"$L"' \
    "AC6-load-log exactly one trusted capability-load line naming card, run, role and capability"
  ok '[ $d = 0 ] && ! tail -n +$((u0 + 1)) "$UEV" 2>/dev/null | grep -q capability-load' "AC6-load-log ... and none in the untrusted log"
  ;;
esac
finish
