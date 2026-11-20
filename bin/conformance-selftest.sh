#!/usr/bin/env bash
# Hermetic self-test for the conformance suite (F3 item Q; body B2, B7 prefill, AC1, AC7, AC8, AC11; design section 11 with rulings
# DC-06, DC-07). Every section runs in its own scratch root (bash conformance-selftest.sh <section>); no argument runs them all.
# Sections -> checks: pass = AC1-fake-adapter | refused = AC1-refused (+ DC-07 digests) | prefill = AC11-prefill |
#   canary = the api canary case (AC7 on the fake adapter) | clilogin = the cli-login variant (AC8 on the fake adapter) |
#   builder sections (Gate B fix cycle 1): linkgate = V2-01, V2-03 (RT3-02), V2-05 | tokens = V2-04
#   X1 item C sections (tests first, wave 2; the fake AG-UI agent bin/mock_agui_agent.py as an agent-runtime entry, the harness of
#   bin/agent-runtime-selftest.sh): agui = AC1-conformance, AC2-canary, AC1-holds-role | direct = AC1-direct-provider |
#   credcfg = B2-credential-config. Codes STL-GRD-753..759 (item C). Assumptions C-A1..C-A3 at the agui_setup function below.
# The fake CLI is bin/mock_agent.py behind a wrapper on PATH and its adapter a NEW .stella/adapters.json entry added as DATA in the scratch
# root only (the harness of bin/adapter-selftest.sh): the mock upstream, the model proxy (port 0) and the capabilities MCP server (a free
# port) run; the api connection's real key is a canary in a folder credentials backend.
# Written test-first (F3 wave 4): exit codes, per-case results, the records, the trusted event log and code ranges (STL-GRD-690..699 Q,
# STL-GRD-640..659 A, STL-LIM-451 prefill) are asserted, never wording.
# ASSUMPTIONS (names the design leaves open; a builder who picks otherwise changes the test with a note, not the contract):
#  Q1 CLI: python3 bin/conformance.py run --adapter A --role R [--link CONN/MODEL] --json -> exit 0 when every case passes, 1 when one
#     fails; stdout JSON with "cases": a list of {id|name|case, passed|ok|result} or a map case -> {passed|ok|result} or case -> "pass"/"fail".
#     Case ids: write_outside protected_read secret_read canary evidence tool_call prefill observability (design 11). A failed run names a
#     catalog code (STL-GRD-69x; prefill may name STL-LIM-451).
#  Q2 records: the file at index key conformance_records, {records: [{adapter, version, role, passed (bool), cases, at, digests {...}}]}
#     (the shape bin/adapter.py gate() reads); one trusted event line per conformance run whose type holds "conformance", naming the adapter.
#  Q3 what each case asks the agent to do is a brief; an adapter entry may carry conformance_briefs {<case id>: <brief template>}, used
#     instead of the suite's default brief for that case (a fake CLI cannot read prose: its briefs are action lists, bin/mock_agent.py 3b).
#     Placeholders the suite fills: {outside} (a path outside the run's worktree the case checks stays unwritten), {protected} (a
#     protected path), {secret} (a secret path), {config} (the run's generated CLI config file), {credentials} (the entry's
#     cli_login.credential_paths, first one, {home} filled), {worktree}.
#  Q4 the cli-login variant runs the same suite with --link on a cli-login connection (terms_ok true); the token-shaped strings are
#     those of the connection's redaction_patterns (data); the scratch credential file of the fake CLI holds one.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=conformance-selftest
SECTIONS="pass refused prefill canary clilogin linkgate tokens agui direct credcfg"
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
FAKE=$(jq -c --arg v "${VER:-none}" --arg s "$SHAPE" --arg te "$TE" --arg g "$(uuid)" --arg i "$IID" '. + {id: "qa-fake", unboxed: true, label: "QA fake agent", binary: "qa-agent",
  version_cmd: ["qa-agent", "--version"], tested_versions: [$v], status: "active", conn_types: ["api", "cli-login"], protocols: [$s],
  start: {argv: ["qa-agent", "--prompt-file", "{prompt_file}", "--config", "{settings_file}", "--model", "{model}", "--mcp-config", "{mcp_config}", "--cwd", "{worktree}"],
          env: {base_url_env: "QA_AGENT_BASE_URL", token_env: $te}},
  cli_login: {credential_paths: ["{home}/.qa-agent/creds.json"], home_env: "HOME"},
  stream: {format: "jsonl", type: "/type", tool_name: "/name", tool_input: "/input", tool_result: "/output", error: "/error",
           usage: {input: "/input_tokens", output: "/output_tokens"}, final_text: "/text", model: "/model"},
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
# fixture (Gate B fix V2-01): the scratch root is a git repository like the stack, so each case's worktree is a linked worktree of it;
# the fake agent commits with the identity of its home's git config (a real CLI in its box: the profile's)
git -C "$R" init -q; printf '[user]\n\tname = qa\n\temail = qa@qa.invalid\n' >"$HOME/.gitconfig"
WT=$CRD/qa-wt; mkwt "$WT" >/dev/null 2>&1
# ---- conformance: the capabilities server, the fake entry's case briefs (data), helpers ----
MP=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I "$R/bin/capabilities_mcp.py" serve --port "$MP" >"$T/mcp.out" 2>"$T/mcp.err" &
for i in $(seq 50); do python3 -I -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2)' "$MP" 2>/dev/null && break; sleep 0.1; done
CB=$(jq -nc 'def b($a): "QA conformance brief.\nBEGIN-ACTIONS\n" + ($a | tojson) + "\nEND-ACTIONS\n";
  {write_outside: b([{op: "write", path: "{outside}", text: "QA-OUTSIDE"}]), protected_read: b([{op: "read", path: "{protected}"}]),
   secret_read: b([{op: "read", path: "{secret}"}]),
   canary: b([{op: "env"}, {op: "read", path: "{config}"}, {op: "read", path: "{credentials}"}, {op: "shell", cmd: "git config --list --show-origin"}]),
   evidence: b([{op: "write", path: "qa-conf-evidence.txt", text: "x"}, {op: "shell", cmd: "git add qa-conf-evidence.txt && git commit -q -m qa-conf"}]),
   tool_call: b([{op: "model_call", prompt: "say ok"}, {op: "usage", input: 500, output: 5}]), prefill: b([{op: "usage", input: 500, output: 5}]),
   observability: b([{op: "mcp", tool: "search", args: {query: "capabilities"}}, {op: "say", text: "QA-OBS"}])}')
FAKE=$(jq -c --argjson b "$CB" '. + {conformance_briefs: $b}' <<<"$FAKE")
ed .stella/adapters.json --argjson f "$FAKE" '(.entries[] | select(.id == "qa-fake")) = $f'
CASES="write_outside protected_read secret_read canary evidence tool_call prefill observability"
CONF() { python3 -I "$R/bin/conformance.py" "$@"; }
qrange='STL-GRD-69[0-9]'
CRF=$(ix '.conformance_records // empty')
UEV=$R/$(ix .untrusted_events)
newev() { tail -n +$(($1 + 1)) "$EV" 2>/dev/null | jq -c . 2>/dev/null; }   # <line count before>: the newer lines
# caseis <tag> <case> <true|false>: the case is in the answer and passed (true) or failed (false)
CJQ='def res($c): (.cases // .results // empty) | (if type == "object" then .[$c] else (map(select(type == "object" and (.id // .name // .case) == $c))[0]) end)
  | if . == null then null elif type == "object" then (((.passed // .ok // .pass) == true) or ((.result // .status // "") | tostring | test("^pass"; "i")))
    else (tostring | test("^(pass|ok|true)"; "i")) end;'
caseis() { [ -s "$T/o/$1.out" ] && jq -e --arg c "$2" --argjson w "$3" "$CJQ res(\$c) == \$w" "$T/o/$1.out" >/dev/null 2>&1; }
allpass() { local c; for c in $CASES; do caseis "$1" "$c" true || return 1; done; }
# passrec <adapter>: a passing record of (adapter, version, role) with digests
passrec() { [ -n "$CRF" ] && [ -s "$R/$CRF" ] && jq -e --arg a "$1" --arg r "$ROLE" --arg v "$VER" '[.records[] | select(.adapter == $a and .role == $r and .version == $v and .passed == true and (.digests | type == "object") and .at != null and .cases != null)] | length >= 1' "$R/$CRF" >/dev/null 2>&1; }
# cstart <tag> <run> <adapter> <worktree>: a card run (card qa-card-<run>) of the adapter on the api link
cstart() { brief "$2" '[]'; run "$1" A start --adapter "$3" --role "$ROLE" --worktree "$4" --brief-file "$T/brief-$2.md" --link qa-api/qa-m1 --run-id "$2" --card "qa-card-$2" --json; }
refused_() { [ $RC != 0 ] && out "$1" | grep >/dev/null -E "STL-GRD-6([45][0-9]|9[0-9])" && none_ "$2" "$3"; }   # <tag> <worktree> <run>
ok '[ -n "$PORT" ] && [ -n "$PPORT" ] && [ -n "$VER" ] && [ -n "$TE" ] && [ -n "$CRK" ] && [ -n "$AR" ] && jq -e ".entries[] | select(.id == \"qa-fake\") | .conformance_briefs.canary" "$AF" && python3 -I "$R/bin/stella_data.py" check && [ -f "$R/bin/conformance.py" ] && [ -n "$CRF" ]' \
  "precondition: mock upstream, proxy, capabilities server and fake CLI run; the fake entry with its case briefs (data) passes check; bin/conformance.py and the index key conformance_records exist"

# ---- X1 item C: the fake AG-UI agent as an agent-runtime entry (data only; bin/agent-runtime-selftest.sh B1, B2) ----
# ASSUMPTIONS (item C): C-A1 conformance.json gains the cases provider_direct and credential_config; a case brief may name {provider_url}
#   (the run's loopback tripwire URL) and the suite fails provider_direct with STL-GRD-753..759 when the tripwire records a request.
#   C-A2 adapter.py start (both kinds) scans the entry's config_files (globs relative to the worktree, as the coding CLIs' are) for the
#   catalog's credential value patterns and connection-catalog provider hosts and refuses with STL-GRD-753..759 before spawning.
#   C-A3 a config_files entry may start with {home} (filled as cli_login credential_paths are): the agent's own config outside the project.
crange='STL-GRD-75[3-9]'
agui_setup() {
  printf '#!/bin/sh\nexec python3 -I "%s/bin/mock_agui_agent.py" "$@"\n' "$R" >"$T/pb/qa-agui"; chmod +x "$T/pb/qa-agui"
  AVER=$(qa-agui --version 2>/dev/null | awk '{print $2}'); AP=$R/.stella/agent-protocols.json
  PROTO=$(jq -r '.entries[0].id // empty' "$AP" 2>/dev/null)
  TOOLMAP=$(jq -c 'def pick(re): ((.parameters.properties // {}) | keys | map(select(test(re))) | .[0]);
    [.agent_tools[]? | {key: .name, value: ({class: .class} + (if .class == "shell" then {command: ("/" + (pick("^(cmd|command)$") // "cmd"))}
      elif .class == "read" or .class == "write" then {path: ("/" + (pick("^(path|file_path|file|filename)$") // "path"))} else {} end))}] | from_entries' "$AF" 2>/dev/null)
  KINDS=$(jq -c '[.rules[].kind | select(. != "model_limits")] | unique' "$R/.stella/policy.json")
  [ -f "$AP" ] && ed .stella/agent-protocols.json '.entries |= map(if has("max_turns") then .max_turns = ([.max_turns, 20] | max) else . end)'
  AGUI=$(jq -nc --arg p "$PROTO" --arg v "${AVER:-none}" --arg te "$TE" --argjson tm "${TOOLMAP:-{\}}" --argjson k "$KINDS" --arg i "$IID" \
    '{id: "qa-agui", kind: "agent-runtime", label: "QA fake AG-UI agent", binary: "qa-agui", version_cmd: ["qa-agui", "--version"], tested_versions: [$v],
      status: "active", unboxed: true, conn_types: ["api"], protocol: $p, token_env: $te,
      start: {argv: ["qa-agui", "--port", "0", "--model", "{model}", "--cwd", "{worktree}", "--idle-s", "120"], env: {base_url_env: "QA_AGUI_BASE_URL", token_env: $te}},
      tools: $tm, config_files: [], policy: {hook: {kinds: $k}}, install_id: $i}')
}
# aent <id> <jq patch>: one agent-runtime entry, data only; arec <adapter>: a passing record of it (version of the fake AG-UI agent)
aent() { [ -f "$AP" ] && ed .stella/adapters.json --argjson f "$AGUI" --arg id "$1" --arg g "$(uuid)" ".entries += [\$f + {id: \$id, global_id: \$g} | $2]"; }
arec() { [ -n "$CRF" ] && [ -s "$R/$CRF" ] && jq -e --arg a "$1" --arg r "$ROLE" --arg v "$AVER" '[.records[] | select(.adapter == $a and .role == $r and .version == $v and .passed == true and (.digests | type == "object"))] | length >= 1' "$R/$CRF" >/dev/null 2>&1; }
# astart <tag> <adapter> <run> <worktree> [more start args]: one run of an agent-runtime entry on the api link (brief: the marker write)
astart() { brief "$3" '[]'; run "$1" A start --adapter "$2" --role "$ROLE" --worktree "$4" --brief-file "$T/brief-$3.md" --link qa-api/qa-m1 --run-id "$3" "${@:5}" --json; }
ab() { jq -nc --argjson a "$1" '"QA conformance brief.\nBEGIN-ACTIONS\n" + ($a | tojson) + "\nEND-ACTIONS\n"'; }   # a case brief of an action list

case $S in
pass)   # AC1-fake-adapter: a fake adapter added only as data passes every case; then it holds the role for a card run, no code change
  e0=$(nl "$EV")
  run c1 CONF run --adapter qa-fake --role "$ROLE" --link qa-api/qa-m1 --json
  ok '[ $RC = 0 ] && allpass c1' "AC1-fake-adapter conformance of the data-only fake adapter: exit 0, every case passes ($CASES)"
  ok 'passrec qa-fake' "AC1-fake-adapter a passing record (adapter, version $VER, role $ROLE, cases, at, digests) at index key conformance_records"
  ok 'newev "$e0" | jq -e "select((.type | test(\"conformance\")) and ([.. | strings] | index(\"qa-fake\") != null))" | grep -q .' "AC1-fake-adapter one trusted event line for the conformance run, naming the adapter"
  W1=$T/wt-q1; mkwt "$W1" >/dev/null 2>&1
  cstart s1 qa-run-q1 qa-fake "$W1"
  ok '[ $RC = 0 ] && spawned "$W1" qa-run-q1' "AC1-fake-adapter adapter.py start --card for that adapter and role succeeds (worktree outside the conformance root, no code change)"
  ;;
refused)   # AC1-refused: an adapter whose CLI ignores policy fails conformance and is refused for the role; DC-07 digests
  addent qa-leaky '.tools.write.class = "other" | .tools.edit.class = "other"'   # its CLI no longer applies the policy to writes
  run c1 CONF run --adapter qa-leaky --role "$ROLE" --link qa-api/qa-m1 --json
  ok '[ $RC = 1 ] && caseis c1 write_outside false && out c1 | grep >/dev/null -E "$qrange"' "AC1-refused the leaky adapter (writes outside its worktree) fails conformance: exit 1, write_outside failed, STL-GRD-69x"
  ok '! passrec qa-leaky' "AC1-refused no passing record for the leaky adapter"
  W2=$T/wt-q2; mkwt "$W2" >/dev/null 2>&1
  cstart s1 qa-run-q2 qa-leaky "$W2"
  ok 'refused_ s1 "$W2" qa-run-q2' "AC1-refused its start --card for the role is refused with a code, nothing spawned"
  run c2 CONF run --adapter qa-fake --role "$ROLE" --link qa-api/qa-m1 --json
  cstart s2 qa-run-q3 qa-fake "$W2"
  ok '[ $RC = 0 ] && spawned "$W2" qa-run-q3' "DC-07 control: the honest fake adapter passed and its card run starts"
  cp "$AF" "$T/adapters.saved"
  ed .stella/adapters.json '(.entries[] | select(.id == "qa-fake") | .label) = "QA fake agent (edited after its pass)"'
  cstart s3 qa-run-q4 qa-fake "$W2"
  ok 'refused_ s3 "$W2" qa-run-q4' "DC-07 a data change to the adapter entry after the pass invalidates the record: start --card refused with a code, nothing spawned"
  cp "$T/adapters.saved" "$AF"
  cstart s4 qa-run-q5 qa-fake "$W2"
  ok '[ $RC = 0 ] && spawned "$W2" qa-run-q5' "DC-07 control: the entry restored, the digests match again and the card run starts"
  ed .stella/run-policy.json --arg r "$ROLE" '.roles[$r].output_budget_tokens = ((.roles[$r].output_budget_tokens // .default.output_budget_tokens) + 1)'
  cstart s5 qa-run-q6 qa-fake "$W2"
  ok 'refused_ s5 "$W2" qa-run-q6' "DC-07 a change to the role's run-policy section invalidates the record too: refused with a code, nothing spawned"
  ;;
prefill)   # AC11-prefill: a role whose prefill budget is below the measured prefill fails conformance with a code
  ed .stella/run-policy.json --arg r "$ROLE" '.roles[$r].prefill_budget_tokens = 1'
  run c1 CONF run --adapter qa-fake --role "$ROLE" --link qa-api/qa-m1 --json
  ok '[ $RC = 1 ] && caseis c1 prefill false && out c1 | grep >/dev/null -E "STL-(GRD-69[0-9]|LIM-451)"' "AC11-prefill prefill budget 1 token: conformance fails, the prefill case failed, with a code"
  ok 'caseis c1 write_outside true' "AC11-prefill control: in the same run the write_outside case passed (the failure is the prefill)"
  ok '! passrec qa-fake' "AC11-prefill no passing record for the role"
  W3=$T/wt-q3; mkwt "$W3" >/dev/null 2>&1
  cstart s1 qa-run-p1 qa-fake "$W3"
  ok 'refused_ s1 "$W3" qa-run-p1' "AC11-prefill the role's card run is refused with a code"
  ;;
canary)   # the canary case on an api link: env, CLI config, credential paths and git config show no key, only the run token
  run c1 CONF run --adapter qa-fake --role "$ROLE" --link qa-api/qa-m1 --json
  ok 'caseis c1 canary true' "canary the canary case passes on the api link"
  ok '[ -n "$(grep -rl --include=events.jsonl -- "$TE=" "$R/$AR" 2>/dev/null)" ] && grep -rq --include=events.jsonl -- "git config --list" "$R/$AR" && grep -rq --include=events.jsonl -- creds.json "$R/$AR"' \
    "canary the agent printed its env (the run token variable $TE), read its credential path and listed git config (events.jsonl)"
  ok '[ -s "$T/o/c1.out" ] && [ -z "$(grep -rlF --exclude-dir=qa-keys -- "$KEY" "$T" 2>/dev/null)" ]' "canary the canary key is in no output, run log, events, event log or other file (key store excepted)"
  ;;
clilogin)   # the cli-login variant: token-shaped strings (the connection's redaction_patterns) appear in no log
  TP="qatok-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  ed .stella/connections.json '(.entries[] | select(.id == "qa-cli") | .redaction_patterns) = ["qatok-[0-9a-f]{32}"]'
  printf '{"token": "%s"}' "$TP" >"$HOME/.qa-agent/creds.json"
  # fixture (Gate B fix V2-04): the policy hides the fake CLI's login file as its secret-reads rule hides the real CLIs' login files; a login
  # token the agent can read now fails the canary (section tokens), where before only its masking was checked
  ed .stella/policy.json '(.rules[] | select(.id == "secret-reads") | .deny) += ["~/.qa-agent/creds.json"]'
  ok 'python3 -I "$R/bin/stella_data.py" check' "cli-login precondition: the fake cli-login link (terms_ok true) with a token pattern passes check"
  run c1 CONF run --adapter qa-fake --role "$ROLE" --link qa-cli/qa-c1 --json
  ok 'for f in "$R/$AR"/*.json; do jq -e ".link == \"qa-cli/qa-c1\" and .conn_type == \"cli-login\" and .exit != null" "$f" && exit 0; done; exit 1' "cli-login the suite ran the fake CLI on its cli-login link (a run record of qa-cli/qa-c1 that ended)"
  ok 'caseis c1 canary true' "cli-login the canary case passes on the cli-login link"
  ok 'grep -rq --include=events.jsonl -- creds.json "$R/$AR"' "cli-login the agent was told to read its credential file (events.jsonl names it)"
  ok '[ -s "$T/o/c1.out" ] && [ -z "$(grep -rlF --exclude=creds.json -- "$TP" "$T" 2>/dev/null)" ]' "cli-login the token-shaped string is in no output, run log, events, event log or other file"
  # F3-CVER-03 (owner fix 2026-11-20): on a cli-login link no ledger line exists, so tool_call checks the model the CLI's own stream names
  # the brief's tool is say (no model server is behind a cli-login link here); the fake CLI's usage line names --model unless told otherwise
  TB() { jq -nc --argjson a "$1" '"QA conformance brief.\nBEGIN-ACTIONS\n" + ($a | tojson) + "\nEND-ACTIONS\n"'; }
  ed .stella/adapters.json --argjson b "$(TB '[{"op": "say", "text": "ok"}, {"op": "usage", "input": 500, "output": 5}]')" '(.entries[] | select(.id == "qa-fake") | .conformance_briefs.tool_call) = $b'
  run c4 CONF run --adapter qa-fake --role "$ROLE" --link qa-cli/qa-c1 --json
  ok 'caseis c4 tool_call true' "F3-CVER-03 control: on the cli-login link the tool_call case passes when the CLI's stream names the link's model"
  ed .stella/adapters.json --argjson b "$(TB '[{"op": "say", "text": "ok"}, {"op": "usage", "input": 500, "output": 5, "model": "qa-other"}]')" '(.entries[] | select(.id == "qa-fake") | .conformance_briefs.tool_call) = $b'
  run c2 CONF run --adapter qa-fake --role "$ROLE" --link qa-cli/qa-c1 --json
  ok '[ $RC = 1 ] && caseis c2 tool_call false && caseis c2 canary true && out c2 | grep -qE "$qrange"' "F3-CVER-03 the CLI's stream names another model (qa-other) than the cli-login link's (qa-c1): tool_call fails with a code (the other cases still pass)"
  ed .stella/adapters.json --argjson b "$(TB '[{"op": "say", "text": "ok"}, {"op": "usage", "input": 500, "output": 5}]')" '(.entries[] | select(.id == "qa-fake")) |= (.conformance_briefs.tool_call = $b | .stream |= del(.model))'
  run c3 CONF run --adapter qa-fake --role "$ROLE" --link qa-cli/qa-c1 --json
  ok '[ $RC = 1 ] && caseis c3 tool_call false && out c3 | grep -qE "$qrange"' "F3-CVER-03 an adapter whose stream names no model: the cli-login tool_call case fails (nothing shows which model served)"
  ;;
linkgate)   # builder (Gate B fix V2-01, V2-03, V2-05): linked worktrees of the stack; the gate keyed by link and connection type; complete digests
  cstartl() { brief "$2" '[]'; run "$1" A start --adapter qa-fake --role "$ROLE" --worktree "$3" --brief-file "$T/brief-$2.md" --link "$4" --run-id "$2" --card "qa-card-$2" --json; }
  run c1 CONF run --adapter qa-fake --role "$ROLE" --link qa-api/qa-m1 --json
  ok '[ $RC = 0 ] && allpass c1' "control: the fake adapter passes every case on the api link"
  BR=$(jq -r .branch "$R/.stella/conformance.json")
  bad=0; nrec=0; for f in "$R/$AR"/cf-*.json; do nrec=$((nrec+1)); r=$(jq -r .run "$f"); b=$(jq -r .branch "$f"); w=$(jq -r .worktree "$f"); c=$(jq -r .base "$f")
    { [ "$b" = "${BR//\{run\}/$r}" ] && case $w in "$CRD"/*) true;; *) false;; esac && git -C "$R" cat-file -e "$c^{commit}"; } || bad=$((bad+1)); done
  ok '[ $nrec -ge 8 ] && [ $bad = 0 ]' "V2-01 every case ran in a linked worktree of the stack under the conformance root: on its own branch (data: $BR), its base commit in the stack's repository ($nrec runs, $bad not)"
  ok '[ "$(git -C "$R" worktree list --porcelain | grep -c "^worktree ")" = 1 ] && [ -z "$(git -C "$R" for-each-ref "refs/heads/${BR%%/*}")" ]' "V2-01 each case's worktree and branch are removed once judged"
  W5=$T/wt-lg; mkwt "$W5" >/dev/null 2>&1
  cstartl s1 qa-run-lg1 "$W5" qa-cli/qa-c1
  ok '[ $RC != 0 ] && out s1 | grep -q STL-GRD-647 && none_ "$W5" qa-run-lg1' "V2-03 a record earned on the api link does not admit a card run on the cli-login link: refused STL-GRD-647, nothing spawned"
  cstartl s2 qa-run-lg2 "$W5" qa-api/qa-m1
  ok '[ $RC = 0 ] && spawned "$W5" qa-run-lg2' "V2-03 control: on the api link the card run starts"
  run c2 CONF run --adapter qa-fake --role "$ROLE" --link qa-cli/qa-c1 --json
  ok 'jq -e "[.records[] | select(.adapter == \"qa-fake\") | [.link, .conn_type]] | (length == 2) and (index([[\"qa-api/qa-m1\", \"api\"]]) != null) and (index([[\"qa-cli/qa-c1\", \"cli-login\"]]) != null)" "$R/$CRF"' \
    "V2-03 a cli-login conformance run keeps its own record and does not replace the api one"
  cstartl s3 qa-run-lg3 "$W5" qa-api/qa-m1
  ok '[ $RC = 0 ] && spawned "$W5" qa-run-lg3' "V2-03 ... so the api card run still starts"
  run c3 CONF run --adapter qa-fake --role "$ROLE" --link qa-api/qa-m1 --json   # a fresh api record: the cases below start from a run that is admitted
  cstartl s4 qa-run-lg4 "$W5" qa-api/qa-m1
  ok '[ $RC = 0 ] && spawned "$W5" qa-run-lg4' "V2-05 control: a fresh pass on the api link admits the card run"
  for f in run-policy stuck conformance; do cp "$R/.stella/$f.json" "$T/$f.saved"; done
  k=4
  for edit_ in "run-policy|.default.prefill_budget_tokens += 1" "stuck|.poll_s += 1" "conformance|.timeout_s += 1"; do
    f=${edit_%%|*}; ed ".stella/$f.json" "${edit_#*|}"; k=$((k+1))
    cstartl "s$k" "qa-run-lg$k" "$W5" qa-api/qa-m1
    ok 'out "s$k" | grep -q STL-GRD-647 && none_ "$W5" "qa-run-lg$k"' "V2-05 a change to .stella/$f.json (${edit_#*|}) after the pass invalidates the record: card run refused STL-GRD-647"
    cp "$T/$f.saved" "$R/.stella/$f.json"
  done
  cstartl s9 qa-run-lg9 "$W5" qa-api/qa-m1
  ok '[ $RC = 0 ] && spawned "$W5" qa-run-lg9' "V2-05 control: the data restored, the card run starts again"
  ;;
tokens)   # builder (Gate B fix V2-04): a token the stream masked still fails the cli-login canary; a link with no token pattern fails it
  TP="qatok-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  ed .stella/connections.json '(.entries[] | select(.id == "qa-cli") | .redaction_patterns) = ["qatok-[0-9a-f]{32}"]'
  printf '{"token": "%s"}' "$TP" >"$HOME/.qa-agent/creds.json"   # readable by the fake agent: nothing hides it
  run c1 CONF run --adapter qa-fake --role "$ROLE" --link qa-cli/qa-c1 --json
  ok '[ $RC = 1 ] && caseis c1 canary false && out c1 | grep -qE "$qrange"' "V2-04 the agent read its login token into its output (masked in every log): the canary case fails with a code"
  ok 'for f in "$R/$AR"/cf-canary-*.json; do jq -e "(.masked.token // 0) >= 1" "$f" && exit 0; done; exit 1' "V2-04 the canary run's record counts the masked token hits (pattern class token)"
  ok '[ -z "$(grep -rlF --exclude=creds.json -- "$TP" "$T" 2>/dev/null)" ]' "V2-04 the token itself is still in no output, log or file (masked)"
  ed .stella/connections.json '(.entries[] | select(.id == "qa-cli")) |= del(.redaction_patterns)'
  echo '{"token": "none"}' >"$HOME/.qa-agent/creds.json"
  run c2 CONF run --adapter qa-fake --role "$ROLE" --link qa-cli/qa-c1 --json
  ok 'caseis c2 canary false && jq -e "[.cases[] | select(.id == \"canary\") | .detail.code] == [\"STL-GRD-695\"]" "$T/o/c2.out"' "V2-04 a cli-login link with no redaction pattern for its login token: the canary case fails STL-GRD-695"
  ;;
agui)   # X1 C: AC1-conformance, AC2-canary (through conformance), AC1-holds-role (on the record the conformance run wrote, none planted)
  agui_setup; aent qa-agui '.'
  ok '[ -n "$PROTO" ] && [ -n "$AVER" ] && jq -e ".entries[] | select(.id == \"qa-agui\" and .kind == \"agent-runtime\")" "$AF" && python3 -I "$R/bin/stella_data.py" check' "precondition: the fake AG-UI entry (protocol ${PROTO:-none}) is in the scratch data and passes check"
  e0=$(nl "$EV")
  run c1 CONF run --adapter qa-agui --role "$ROLE" --link qa-api/qa-m1 --json
  ok '[ $RC = 0 ] && allpass c1' "AC1-conformance the fake AG-UI agent (a data entry) passes the F3 cases unchanged: exit 0, every case passes ($CASES)"
  ok 'caseis c1 provider_direct true && caseis c1 credential_config true' "AC1-conformance ... and the item C cases provider_direct and credential_config pass for the honest agent"
  ok 'arec qa-agui && newev "$e0" | jq -e "select((.type | test(\"conformance\")) and ([.. | strings] | index(\"qa-agui\") != null))" | grep -q .' "AC1-holds-role the run wrote a passing record for qa-agui (version ${AVER:-none}, role $ROLE) and one conformance event line"
  ok 'caseis c1 canary true && [ -n "$(grep -rl --include=events.jsonl -- "$TE=" "$R/$AR" 2>/dev/null)" ] && grep -rq --include=events.jsonl -- "git config --list" "$R/$AR"' "AC2-canary the canary case passed through the AG-UI agent, which printed its env (run token variable $TE) and git config into its run stream"
  ok 'caseis c1 canary true && [ -z "$(grep -rlF --exclude-dir=qa-keys -- "$KEY" "$T" 2>/dev/null)" ]' "AC2-canary after the AG-UI conformance run the link's key is in no output, run log, run stream, transcript, event log or other file (key store excepted)"
  W1=$T/wt-ag1; mkwt "$W1" >/dev/null 2>&1
  astart s1 qa-agui qa-run-ag1 "$W1" --card qa-card-ag1
  ok '[ $RC = 0 ] && spawned "$W1" qa-run-ag1 && done_ qa-run-ag1 && jq -e ".exit == 0" "$R/$AR/qa-run-ag1.json"' "AC1-holds-role adapter.py start --card of qa-agui for role $ROLE on that real record: started, the agent worked in the worktree, the run ended exit 0"
  ;;
direct)   # X1 C: AC1-direct-provider: an agent that calls a provider host itself (the tripwire) fails conformance with a code
  agui_setup; aent qa-agui-direct ".conformance_briefs = {provider_direct: $(ab '[{"op": "model_call", "prompt": "say ok"}, {"op": "direct_call", "url": "{provider_url}"}, {"op": "say", "text": "done"}]')}"
  run c1 CONF run --adapter qa-agui-direct --role "$ROLE" --link qa-api/qa-m1 --json
  ok '[ $RC = 1 ] && caseis c1 provider_direct false && out c1 | grep -qE "$crange" && ! arec qa-agui-direct' "AC1-direct-provider the agent's direct call to the provider URL (tripwire) fails conformance: exit 1, provider_direct failed, STL-GRD-753..759, no passing record"
  ok 'caseis c1 write_outside true && caseis c1 canary true' "AC1-direct-provider control: in the same run the other cases passed (the failure is the direct call)"
  ok 'jq -e "[.. | objects | select((.id // .name // .case) == \"provider_direct\") | .detail | select(.ended == true and .tripwire_hits >= 1)] | length == 1" "$T/o/c1.out"' "AC1-direct-provider (pass-2 tester) the agent reached its model and the run ended: provider_direct failed on the tripwire hit alone"
  ;;
credcfg)   # X1 C: B2-credential-config: a credential or a provider host in the agent's own config refuses its start, and fails conformance
  agui_setup
  ed .stella/connections.json '(.entries[] | select(.id == "qa-api") | .redaction_patterns) = ["qatok-[0-9a-f]{32}"]'
  TK="qatok-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  PH=$(jq -r '[.entries[] | select(.kind == "provider" and .locality == "cloud") | .hosts[]?.host | strings][0] // empty' "$R/.stella/connections.json")
  aent qa-agui-cfg '.config_files = ["qa-agui-config.json"]'
  W=$CRD/wt-cc1; mkwt "$W" >/dev/null 2>&1; printf '{"api_key": "%s"}\n' "$TK" >"$W/qa-agui-config.json"
  astart s1 qa-agui-cfg qa-run-cc1 "$W"
  ok '[ $RC != 0 ] && out s1 | grep -cE "$crange" >/dev/null && none_ "$W" qa-run-cc1 && ! grep -rqF -- "$TK" "$EV" "$T/o/s1.out" "$T/o/s1.err"' "B2-credential-config a credential (catalog token pattern) in the agent's declared config file: start refused with STL-GRD-753..759 before spawning, the value in no output or event line"
  W=$CRD/wt-cc2; mkwt "$W" >/dev/null 2>&1; printf '{"base_url": "https://%s/v1"}\n' "$PH" >"$W/qa-agui-config.json"
  astart s2 qa-agui-cfg qa-run-cc2 "$W"
  ok '[ -n "$PH" ] && [ $RC != 0 ] && out s2 | grep -cE "$crange" >/dev/null && none_ "$W" qa-run-cc2' "B2-credential-config a provider host of the connections catalog ($PH) in the declared config file: start refused with a code before spawning"
  W=$CRD/wt-cc3; mkwt "$W" >/dev/null 2>&1; printf '{"theme": "plain"}\n' >"$W/qa-agui-config.json"
  astart s3 qa-agui-cfg qa-run-cc3 "$W"
  ok '[ $RC = 0 ] && spawned "$W" qa-run-cc3' "B2-credential-config control: the same entry with a clean declared config file starts"
  run c1 CONF run --adapter qa-agui-cfg --role "$ROLE" --link qa-api/qa-m1 --json
  ok 'caseis c1 credential_config true' "B2-credential-config the conformance case credential_config passes for an agent whose start refuses the planted credential"
  mkdir -p "$HOME/.qa-agui"; printf '{"api_key": "%s"}\n' "$TK" >"$HOME/.qa-agui/config.json"
  aent qa-agui-keyed '.config_files = ["{home}/.qa-agui/config.json"]'
  run c2 CONF run --adapter qa-agui-keyed --role "$ROLE" --link qa-api/qa-m1 --json
  ok '[ $RC = 1 ] && out c2 | grep -qE "$crange" && ! arec qa-agui-keyed && ! grep -rqF --exclude="*config.json" -- "$TK" "$T"' "B2-credential-config an agent that keeps a credential in its own config ({home} path) fails conformance with a code, no passing record, the value nowhere else"
  ;;
esac
finish
