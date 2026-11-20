#!/usr/bin/env bash
# Hermetic self-test for the adapter core (F3 item A; body B1, B2 evidence, AC1; design sections 3, 3b with rulings DC-01, DC-03,
# DC-04, DC-06, DC-10). Every section runs in its own scratch root (bash adapter-selftest.sh <section>); no argument runs them all.
# Sections -> checks: callers = AC1-callers (list, start, run record with unattended/background, events.jsonl, logs, stop) |
#   apikey = T-API-NO-KEY, DC-03 | evidence = T-EVIDENCE | stubs = T-STUBS-CLI | terms = T-TERMS | versions = T-VERSIONS |
#   gates = DC-01, DC-06 | builder sections (Gate B fix cycle 1): safegit = V2-02, V2-11 | frozen = V2-08, RT3-01 | stopfirst = RT3-06 |
#   pins = RT3-07 | stream = RT3-04, V2-06 | boxdefault = V2-10
# The fake CLI is bin/mock_agent.py (contract: design 3b) behind a wrapper on PATH; its adapter is a NEW .stella/adapters.json entry
# added as DATA in the scratch root only (no code change). The model upstream is bin/mock_provider.py; the api connection's real key
# is a canary in a folder credentials backend (as bin/model-proxy-selftest.sh plants it); bin/model_proxy.py serves on port 0.
# Written test-first (F3 wave 2): exit codes, --json keys and the code ranges STL-GRD-640..659 (A), STL-CFG-312 (worker) are
# asserted, never wording.
# ASSUMPTIONS (names the design leaves open; a builder who picks otherwise changes the test with a note, not the contract):
#  A1 the fake entry is the first shipped entry with status "active" (fallback: the first entry; this keeps the P-owned token_env,
#     model_flags and policy shapes), overridden with: id, label, binary, version_cmd (full argv), tested_versions, status, conn_types,
#     protocols, start {argv: full argv with {prompt_file} {settings_file} {model} {mcp_config} {worktree}, env {base_url_env,
#     token_env}}, cli_login {credential_paths, home_env}, stream {format, type, tool_name, tool_input, tool_result, error, usage,
#     final_text} (pointers into the 3b jsonl), supports (all false), tools (DC-12 map over the 3b op names), global_id, install_id.
#  A2 a cli-login connection names its CLI by the adapter id (connections.json field cli, as the shipped cli-login entry does).
#  A3 start ... --json prints JSON naming the run id; a run with no --card runs in the background or to its end, either way
#     adapter.py evidence --run R --json answers exit_code as a number once the CLI has exited.
#  A4 the conformance scratch root is the index key whose name holds "conformance" and not "record" (a path, relative to the root
#     unless absolute); a card-less run's worktree lies under it (DC-06).
#  A5 the run record is <adapter_runs>/<run>.json (index key adapter_runs, layout settled by the orchestrator 19:1x); it holds booleans
#     unattended and background (DC-10, as bin/host-access-selftest.sh plants them).
#  A6 the per-run events.jsonl is a file named events.jsonl under a path that holds the run id, somewhere in the scratch root.
#  A7 the fake CLI's op "shell" runs its command through a shell in the worktree with the CLI's own environment.
#  A8 bin/false-close-guard.py takes today's payload (tool_name kanban_complete, tool_input.task_id = the card) and finds the
#     card's run by the card field of the run record (DC-01); the test sets that field on a stopped run's record.
#  A9 a refused start spawns nothing: the action list of every refused start writes a marker file that must stay absent.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=adapter-selftest
SECTIONS="callers apikey evidence stubs terms versions gates safegit frozen stopfirst pins stream boxdefault"
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
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG="$T/owner-fake.env" ROLES_FILE=$RJ
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
evq() { local f; f=$(evfile "$1"); [ -s "$f" ] && jq -c "$2" "$f" 2>/dev/null; }   # builder (fix cycle 1): the run's events.jsonl lines the filter selects
WT=$CRD/qa-wt; mkwt "$WT" >/dev/null 2>&1
ok '[ -n "$PORT" ] && [ -n "$PPORT" ] && [ -n "$VER" ] && [ -n "$TE" ] && [ -n "$CRK" ] && [ -n "$AR" ] && jq -e ".entries[] | select(.id == \"qa-fake\")" "$AF" && python3 -I "$R/bin/stella_data.py" check' \
  "precondition: mock upstream, proxy and fake CLI run; the index names a conformance root and adapter_runs; the scratch data with the new adapter entry passes check"

case $S in
callers)   # AC1-callers: a new data entry starts a run with no code change; run record, events.jsonl, logs, stop
  run l1 A list --json
  ok '[ $RC = 0 ] && [ -s "$T/o/l1.out" ] && jq -e "[.. | objects | select(.id == \"qa-fake\")] | length > 0" "$T/o/l1.out"' "AC1-callers list --json shows the new data entry qa-fake"
  go s1 qa-run-a1 "$WT" qa-api/qa-m1 '[{"op":"say","text":"QA-SAY-A1"},{"op":"write","path":"qaout.txt","text":"QA-OUT"},{"op":"usage","input":7,"output":3}]'
  ok '[ $RC = 0 ] && grep -q qa-run-a1 "$T/o/s1.out"' "AC1-callers start (card-less, worktree under the conformance root): exit 0, JSON naming the run"
  done_ qa-run-a1; d=$?
  ok '[ $d = 0 ] && [ "$(cat "$WT/qaout.txt" 2>/dev/null)" = QA-OUT ]' "AC1-callers the fake CLI ran the brief's actions in the worktree and exited"
  ok 'rec qa-run-a1 >"$T/o/rec" && jq -e "(.unattended | type == \"boolean\") and (.background | type == \"boolean\")" "$T/o/rec"' "AC1-callers the run record (adapter_runs) holds booleans unattended and background (item H reads them)"
  EVJ=$(evfile qa-run-a1)
  ok '[ -s "$EVJ" ] && jq -e . "$EVJ" >/dev/null && grep -q QA-SAY-A1 "$EVJ" && grep -q qaout.txt "$EVJ"' "AC1-callers runs/<id>/events.jsonl: JSON lines parsed from the stream (the said text, the write and its path)"
  run g1 A logs --run qa-run-a1
  ok '[ $RC = 0 ] && grep -q QA-SAY-A1 "$T/o/g1.out"' "AC1-callers logs --run shows the run's output"
  SL=qasleep$RANDOM$RANDOM
  go s2 qa-run-a2 "$WT" qa-api/qa-m1 "$(jq -nc --arg c "bash -c 'exec -a $SL sleep 60'" '[{op: "shell", cmd: "env > qaenv-a2.txt"}, {op: "shell", cmd: $c}]')"
  for i in $(seq 40); do pgrep -f "$SL" >/dev/null && [ -s "$WT/qaenv-a2.txt" ] && break; sleep 0.5; done
  TOK=$(sed -n "s/^$TE=//p" "$WT/qaenv-a2.txt" 2>/dev/null | head -n1)
  vfy() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import run_token; print("none" if run_token.verify(sys.argv[2]) is None else "rec")' "$R/bin" "$1" 2>/dev/null; }
  ok '[ $RC = 0 ] && pgrep -f "$SL" >/dev/null && [ -n "$TOK" ] && [ "$(vfy "$TOK")" = rec ]' "AC1-callers a long run is running with a live run token (control)"
  e0=$(nl "$EV"); run p1 A stop --run qa-run-a2 --reason qa-stop
  for i in $(seq 20); do pgrep -f "$SL" >/dev/null || break; sleep 0.5; done
  ok '[ $RC = 0 ] && ! pgrep -f "$SL" >/dev/null' "AC1-callers stop --run: exit 0 and the CLI's process group is gone"
  ok '[ "$(vfy "$TOK")" = none ]' "AC1-callers stop revoked the run token"
  ok 'tail -n +$((e0 + 1)) "$EV" | grep >/dev/null qa-run-a2' "AC1-callers stop wrote an event line naming the run"
  # builder case (item A, moved from K): the card's attached skills and tools are listed in the prompt the CLI is given
  printf '{"skills": ["qa-skill-zz"], "tools": ["qa-tool-zz"]}' >"$T/card-a3.json"
  go s3 qa-run-a3 "$WT" qa-api/qa-m1 '[]' --card-file "$T/card-a3.json"
  done_ qa-run-a3; d=$?
  PF=$(find "$R/$AR/qa-run-a3" -name prompt.md 2>/dev/null | head -n1)
  ok '[ $d = 0 ] && [ -s "$PF" ] && grep -q qa-skill-zz "$PF" && grep -q qa-tool-zz "$PF"' "A-ATTACHED the prompt the CLI is given lists the card's attached skills and tools"
  ;;
apikey)   # T-API-NO-KEY and DC-03: the child env holds the run token and the proxy URL, never the key; a worker marker is set
  c0=$(calls)
  go s1 qa-run-k1 "$WT" qa-api/qa-m1 '[{"op":"env"},{"op":"shell","cmd":"env > qaenv.txt"},{"op":"model_call","prompt":"say ok"}]'
  done_ qa-run-k1; d=$?; E=$WT/qaenv.txt
  ok '[ $d = 0 ] && [ -s "$E" ]' "T-API-NO-KEY an api run of the fake CLI ran and dumped its environment"
  tv=$(sed -n "s/^$TE=//p" "$E" 2>/dev/null | head -n1); bu=$(sed -n 's/^QA_AGENT_BASE_URL=//p' "$E" 2>/dev/null | head -n1)
  ok '[ ${#tv} -ge 43 ] && [ "$tv" != "$KEY" ]' "T-API-NO-KEY the child env holds the run token in the adapter's token_env ($TE)"
  ok 'grep -qE "^https?://(127\.0\.0\.1|localhost|\[::1\]):$PPORT(/|$)" <<<"$bu"' "T-API-NO-KEY the child env's base URL is the loopback proxy (port $PPORT)"
  ok '[ -s "$E" ] && ! grep -qF -- "$KEY" "$E" && ! grep -q "^$KN=" "$E"' "T-API-NO-KEY the key is in no env variable (by value or by its secret name)"
  ok '[ "$(calls)" = $((c0 + 1)) ]' "T-API-NO-KEY the CLI's model call went through the proxy to the upstream (one call)"
  ok '[ $d = 0 ] && [ -z "$(grep -rlF --exclude-dir=qa-keys -- "$KEY" "$T" 2>/dev/null)" ]' "T-API-NO-KEY the key is in no config, run dir, log, event line or worktree file (key store excepted)"
  mk=$(jq -r '.worker_markers[]' "$RJ")
  ok 'for m in $mk; do grep -q "^$m=." "$E" && exit 0; done; exit 1' "DC-03 the child env has a roles.json worker marker set ($mk)"
  ;;
evidence)   # T-EVIDENCE: evidence --json keys; bin/false-close-guard.py consults the run found by card id
  go s1 qa-run-e1 "$WT" qa-api/qa-m1 '[{"op":"write","path":"qaev.txt","text":"QA-EV"},{"op":"shell","cmd":"git add qaev.txt && git commit -q -m qamsg"}]'
  done_ qa-run-e1
  run v1 A evidence --run qa-run-e1 --json
  ok '[ $RC = 0 ] && [ -s "$T/o/v1.out" ] && jq -e "has(\"exit_code\") and has(\"commits\") and has(\"files_changed\") and has(\"all_inside_worktree\")" "$T/o/v1.out"' "T-EVIDENCE evidence --json has exit_code, commits, files_changed, all_inside_worktree"
  ok '[ -s "$T/o/v1.out" ] && jq -e ".exit_code == 0 and ((.commits | if type == \"array\" then length else . end) >= 1) and ([.files_changed | .. | strings] | any(test(\"qaev.txt\"))) and .all_inside_worktree == true" "$T/o/v1.out"' \
    "T-EVIDENCE ... with the run's real outcome: exit 0, the commit, the changed file, all inside the worktree"
  SL=qasleep$RANDOM$RANDOM
  go s2 qa-run-e2 "$WT" qa-api/qa-m1 "$(jq -nc --arg c "bash -c 'exec -a $SL sleep 60'" '[{op: "shell", cmd: $c}]')"
  for i in $(seq 40); do pgrep -f "$SL" >/dev/null && break; sleep 0.5; done
  run p1 A stop --run qa-run-e2 --reason qa-stop; done_ qa-run-e2
  run v2 A evidence --run qa-run-e2 --json
  ok '[ -s "$T/o/v2.out" ] && jq -e ".exit_code != 0 and ((.commits | if type == \"array\" then length else . end) == 0)" "$T/o/v2.out"' "T-EVIDENCE a stopped run's evidence: non-zero exit, no commit"
  rec qa-run-e2 qa-card-bad >/dev/null
  # the guard: a session store in which today's path (an OpenCode write of the file) would pass
  GW=$T/gw; mkdir -p "$GW"; echo ok >"$GW/qadone.md"
  python3 -I - "$T/state.db" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1]); con.execute("create table messages (session_id, role, tool_call_id, tool_calls, content)")
tc = [{"id": "c0", "function": {"name": "terminal", "arguments": json.dumps({"command": "opencode run --standalone --auto 'write qadone.md'"})}}]
con.execute("insert into messages values ('s1', 'assistant', null, ?, '')", (json.dumps(tc),))
con.execute("insert into messages values ('s1', 'tool', 'c0', null, ?)", (json.dumps({"exit_code": 0, "output": "Write qadone.md\nWrote file successfully"}),))
con.commit()
PY
  PRF=$(jq -r '.sandbox.boxed_profiles[0]' "$RJ")
  guard() { jq -nc --arg c "$1" --arg cwd "$GW" --arg p "$PRF" '{tool_name: "kanban_complete", tool_input: {task_id: $c, summary: "Created qadone.md", metadata: {delegate_exit_code: 0, delegate_output: "Wrote file successfully", files_created: ["qadone.md"]}}, session_id: "s1", cwd: $cwd, profile: $p}' \
    | GUARD_STATE_DB=$T/state.db python3 -I "$R/bin/false-close-guard.py" >"$T/o/$2.out" 2>"$T/o/$2.err"; RC=$?; cat "$T/o/$2.out" "$T/o/$2.err" >"$T/o/last"; }
  guard qa-card-none f0
  ok '[ $RC = 0 ]' "T-EVIDENCE control: a card with no adapter run keeps today's Hermes-session path (the passing session completes)"
  guard qa-card-bad f1
  ok '[ $RC = 2 ]' "T-EVIDENCE the guard finds the card's adapter run by card id and its evidence (stopped, no commit) blocks the close, the passing session notwithstanding"
  ;;
stubs)   # T-STUBS-CLI: a stub entry and an active entry with a missing binary fail closed with a code
  mapfile -t ST < <(jq -r '.entries[] | select(.status == "stub") | .id' "$AF" 2>/dev/null)
  ok '[ ${#ST[@]} -ge 1 ]' "T-STUBS-CLI at least one shipped stub entry (a CLI that is not installed)"
  bad=; for s in "${ST[@]}"; do brief "qa-run-st-$s" '[]'
    run "st-$s" A start --adapter "$s" --role "$ROLE" --worktree "$WT" --brief-file "$T/brief-qa-run-st-$s.md" --link qa-api/qa-m1 --run-id "qa-run-st-$s" --json
    { [ $RC != 0 ] && out "st-$s" | grep >/dev/null -E "$range"; } || bad="$bad $s"; done
  ok '[ ${#ST[@]} -ge 1 ] && [ -z "$bad" ]' "T-STUBS-CLI start of every shipped stub fails closed with STL-GRD-64x/65x (failed:$bad)"
  addent qa-stub '{id: .id, label: .label, binary: "qa-stub-cli", version_cmd: ["qa-stub-cli", "--version"], status: "stub", global_id: .global_id, install_id: .install_id}'
  run l1 A list --json
  ok '[ $RC = 0 ] && [ -s "$T/o/l1.out" ] && jq -e "[.. | objects | select(.id == \"qa-stub\")][0] | [.. | strings] | index(\"stub\") != null" "$T/o/l1.out"' "T-STUBS-CLI a stub added as data is listed as a stub"
  brief qa-run-st1 '[]'
  run t1 A start --adapter qa-stub --role "$ROLE" --worktree "$WT" --brief-file "$T/brief-qa-run-st1.md" --link qa-api/qa-m1 --run-id qa-run-st1 --json
  ok '[ $RC != 0 ] && out t1 | grep >/dev/null -E "$range"' "T-STUBS-CLI start of the data-added stub fails closed with STL-GRD-64x/65x"
  addent qa-nobin '.binary = "qa-missing-cli-zz" | .version_cmd = ["qa-missing-cli-zz", "--version"] | .start.argv[0] = "qa-missing-cli-zz"'
  ed .stella/connections.json '(.entries[] | select(.id == "qa-cli") | .cli) = "qa-nobin"'
  brief qa-run-st2 '[]'
  run t2 A start --adapter qa-nobin --role "$ROLE" --worktree "$WT" --brief-file "$T/brief-qa-run-st2.md" --link qa-api/qa-m1 --run-id qa-run-st2 --json
  ok '[ $RC != 0 ] && out t2 | grep >/dev/null -E "$range"' "T-STUBS-CLI an active entry whose binary is missing fails closed with STL-GRD-64x/65x"
  run t3 A version --adapter qa-nobin --json
  ok '[ $RC != 0 ] && out t3 | grep >/dev/null -E "$range"' "T-STUBS-CLI version of the missing binary fails closed with a code"
  ;;
terms)   # T-TERMS: a cli-login link runs only when the connection's terms_ok is true; the CLI's credential file is never read
  go s1 qa-run-c1 "$WT" qa-cli/qa-c1 '[{"op":"say","text":"QA-SAY-C1"}]'
  ok '[ $RC = 0 ] && spawned "$WT" qa-run-c1' "T-TERMS control: terms_ok true, the cli-login run of the fake CLI starts"
  done_ qa-run-c1; d=$?
  ok '[ $d = 0 ] && [ -z "$(grep -rlF --exclude=creds.json -- "$CANARY2" "$T" 2>/dev/null)" ]' "T-TERMS the CLI's credential file content is in no run file, log, event line or worktree file"
  for v in false null; do
    ed .stella/connections.json --argjson v "$v" '(.entries[] | select(.id == "qa-cli") | .terms_ok) = $v'
    go "s-$v" "qa-run-c-$v" "$WT" qa-cli/qa-c1 '[]'
    ok '[ $RC != 0 ] && out "s-$v" | grep >/dev/null -E "STL-(GRD-6[45][0-9]|CFG-310|MDL-7[0-9][0-9])" && none_ "$WT" "qa-run-c-$v"' "T-TERMS terms_ok $v: the cli-login run is refused with a code and nothing is spawned"
  done
  ;;
versions)   # T-VERSIONS: the adapter reports its version; outside tested_versions is flagged with a code
  run v1 A version --adapter qa-fake --json
  ok '[ $RC = 0 ] && grep -qF -- "$VER" "$T/o/v1.out" && ! out v1 | grep >/dev/null -E "$range"' "T-VERSIONS version --json reports the CLI's version ($VER), within tested_versions: no code"
  addent qa-old '.tested_versions = ["0.0.0-qa-untested"]'
  run v2 A version --adapter qa-old --json
  ok 'grep -qF -- "$VER" "$T/o/v2.out" && out v2 | grep >/dev/null -E "$range"' "T-VERSIONS a version outside tested_versions is flagged with STL-GRD-64x/65x"
  ;;
gates)   # DC-01 engine side only; DC-06 the conformance gate for card runs, the conformance root for card-less runs
  brief qa-run-w1 '[]'
  run w1 WORKER python3 -I "$R/bin/adapter.py" start --adapter qa-fake --role "$ROLE" --worktree "$WT" --brief-file "$T/brief-qa-run-w1.md" --link qa-api/qa-m1 --run-id qa-run-w1 --json
  ok '[ $RC != 0 ] && out w1 | grep >/dev/null STL-CFG-312 && none_ "$WT" qa-run-w1' "DC-01 start in a worker environment: refused STL-CFG-312, nothing spawned"
  run w2 WORKER python3 -I "$R/bin/adapter.py" start --adapter qa-no-such-adapter --role "$ROLE" --worktree "$WT" --brief-file "$T/brief-qa-run-w1.md" --run-id qa-run-w2 --json
  ok '[ $RC != 0 ] && out w2 | grep >/dev/null STL-CFG-312 && ! out w2 | grep >/dev/null -E "$range"' "DC-01 ... before reading anything (an unknown adapter still answers STL-CFG-312)"
  run w3 WORKER python3 -I "$R/bin/adapter.py" stop --run qa-run-w1
  ok '[ $RC != 0 ] && out w3 | grep >/dev/null STL-CFG-312' "DC-01 stop in a worker environment: refused STL-CFG-312"
  go g0 qa-run-g0 "$WT" qa-api/qa-m1 '[]'
  ok '[ $RC = 0 ] && spawned "$WT" qa-run-g0' "DC-06 control: a card-less run under the conformance root starts"
  go g1 qa-run-g1 "$WT" qa-api/qa-m1 '[]' --card qa-card-g1
  ok '[ $RC != 0 ] && out g1 | grep >/dev/null -E "STL-GRD-6([45][0-9]|9[0-9])" && none_ "$WT" qa-run-g1' "DC-06 a --card run with no passing conformance record: refused with a code, nothing spawned"
  OW=$T/outside-wt; mkwt "$OW" >/dev/null 2>&1
  go g2 qa-run-g2 "$OW" qa-api/qa-m1 '[]'
  ok '[ $RC != 0 ] && out g2 | grep >/dev/null -E "STL-GRD-6([45][0-9]|9[0-9])" && none_ "$OW" qa-run-g2' "DC-06 a card-less run outside the conformance scratch root: refused with a code, nothing spawned"
  ;;
safegit)   # builder (Gate B fix V2-02, V2-11): git and file reads the engine makes on an agent's worktree run nothing of it and never block
  ulimit -v 1500000   # an unbounded read of /dev/zero ends in MemoryError, not in a host out of memory
  W5=$CRD/qa-wt-sg; mkwt "$W5" >/dev/null 2>&1; M=$T/qa-hit; mkdir -p "$M"
  G() { git -c user.name=qa -c user.email=qa@qa.invalid "$@"; }
  ( cd "$W5" && mkdir sub && git -C sub init -q && G -C sub commit -q --allow-empty -m sub && git add sub 2>/dev/null && G commit -qm gitlink \
    && printf '* diff=qax\n' >.gitattributes && G add .gitattributes && G commit -qm attrs ) >/dev/null 2>&1
  # planted after the commits: the nested repo's fsmonitor (gitlink), the worktree's external diff and textconv, a global fsmonitor (HOME)
  git -C "$W5/sub" config core.fsmonitor "touch $M/sub-fsmonitor; false"
  git -C "$W5" config diff.external "$M/ext.sh"; git -C "$W5" config diff.qax.textconv "touch $M/textconv; cat"
  printf '#!/bin/sh\ntouch %s/external\n' "$M" >"$M/ext.sh"; chmod +x "$M/ext.sh"
  printf '[core]\n\tfsmonitor = touch %s/global-fsmonitor; false\n' "$M" >"$HOME/.gitconfig"
  mkfifo "$M/fifo"; ln -s /dev/zero "$W5/a-zero"; ln -s "$M/fifo" "$W5/b-fifo"
  ok '[ -d "$W5/sub/.git" ] && [ -L "$W5/a-zero" ] && [ "$(ls "$M" | grep -cv -e "^ext.sh$" -e "^fifo$")" = 0 ]' "V2-02 precondition: nested repo with a gitlink, planted fsmonitor/external diff/textconv/global config, untracked links to /dev/zero and a FIFO; no marker yet"
  go s1 qa-run-sg1 "$W5" qa-api/qa-m1 '[{"op":"edit","path":"README","old":"base","new":"changed"},{"op":"write","path":"qa-sg.txt","text":"x"}]'
  done_ qa-run-sg1; d=$?
  ok '[ $RC = 0 ] && [ $d = 0 ]' "V2-11 the run ended (no read of /dev/zero or the FIFO behind a link blocked or exhausted the supervisor)"
  ok '[ $d = 0 ] && [ "$(ls "$M" | grep -cv -e "^ext.sh$" -e "^fifo$")" = 0 ]' "V2-02 nothing of the worktree ran on the host: no fsmonitor (nested repo, global), external diff or textconv marker ($(ls "$M" | tr '\n' ' '))"
  ok '[ "$(evq qa-run-sg1 "select(.type == \"tool_result\") | .diff" | grep -cE "^\"[0-9a-f]{64}\"$")" -ge 2 ]' "V2-02 the per-result worktree digests were still computed (safe git, links read as links)"
  ok 'A evidence --run qa-run-sg1 --json | jq -e "(.files_changed | index(\"README\")) and (.files_changed | index(\"qa-sg.txt\"))"' "V2-02 the frozen evidence still lists the changed and the new file"
  rm -f "$HOME/.gitconfig"
  ;;
frozen)   # builder (Gate B fix V2-08, RT3-01): card evidence is frozen at the run's exit; only commits on the run's own branch count
  CRF=$(ix '.conformance_records // empty')
  plantrec() { python3 -I - "$R/bin" qa-fake "$ROLE" "$VER" "$R/$CRF" "$(uuid)" "$IID" <<'PY'
import datetime, json, os, sys
sys.path.insert(0, sys.argv[1]); import adapter
p = sys.argv[5]
doc = json.load(open(p)) if os.path.exists(p) else {"schema_version": 1, "records": []}
doc["records"].append({"adapter": sys.argv[2], "version": sys.argv[4], "role": sys.argv[3], "link": "qa-api/qa-m1", "conn_type": "api", "passed": True, "cases": [],
                       "digests": adapter.digests(sys.argv[2], sys.argv[3]), "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                       "global_id": sys.argv[6], "install_id": sys.argv[7]})
os.makedirs(os.path.dirname(p), exist_ok=True); json.dump(doc, open(p, "w"))
PY
}
  verdict() { python3 -I -c 'import sys, json; sys.path.insert(0, sys.argv[1]); import adapter; print(json.dumps(adapter.card_verdict(sys.argv[2])))' "$R/bin" "$1" 2>/dev/null; }
  plantrec
  W7=$T/wt-fz1; mkwt "$W7" >/dev/null 2>&1
  go s1 qa-run-fz1 "$W7" qa-api/qa-m1 '[{"op":"say","text":"no work"}]' --card qa-card-fz1
  done_ qa-run-fz1; d=$?
  ( cd "$W7" && echo late >late.txt && git add late.txt && git commit -qm "after the run" ) >/dev/null 2>&1
  ok '[ $RC = 0 ] && [ $d = 0 ] && [ "$(git -C "$W7" rev-list --count HEAD)" = 2 ] && verdict qa-card-fz1 | jq -e ".[0] == false"' "V2-08 a commit made in the worktree after the run exited 0 with no commit does not count: card_verdict false"
  ok 'A evidence --run qa-run-fz1 --json | jq -e "(.commits | length) == 0 and (.files_changed | index(\"late.txt\") | not)"' "V2-08 the evidence is the one frozen at exit (no later commit, no later file)"
  W8=$T/wt-fz2; mkwt "$W8" >/dev/null 2>&1
  ( cd "$W8" && git checkout -q -b other-card && echo theirs >theirs.txt && git add theirs.txt && git commit -qm "other card's work" && git checkout -q - ) >/dev/null 2>&1
  OTHER=$(git -C "$W8" rev-parse other-card 2>/dev/null)
  go s2 qa-run-fz2 "$W8" qa-api/qa-m1 '[{"op":"shell","cmd":"git checkout -q --detach other-card"}]' --card qa-card-fz2
  done_ qa-run-fz2; d=$?
  ok '[ $RC = 0 ] && [ $d = 0 ] && [ "$(git -C "$W8" rev-parse HEAD)" = "$OTHER" ] && verdict qa-card-fz2 | jq -e ".[0] == false"' "RT3-01 a card run that moved HEAD to another branch's commit is not accepted"
  ok 'A evidence --run qa-run-fz2 --json | jq -e --arg o "$OTHER" "(.commits | index(\$o) | not) and .on_branch == false"' "RT3-01 its evidence credits no commit of the other branch and says it left its branch"
  W9=$T/wt-fz3; mkwt "$W9" >/dev/null 2>&1
  go s3 qa-run-fz3 "$W9" qa-api/qa-m1 '[{"op":"write","path":"qa-own.txt","text":"x"},{"op":"shell","cmd":"git add qa-own.txt && git commit -q -m own"}]' --card qa-card-fz3
  done_ qa-run-fz3; d=$?
  ok '[ $RC = 0 ] && [ $d = 0 ] && verdict qa-card-fz3 | jq -e ".[0] == true" && A evidence --run qa-run-fz3 --json | jq -e "(.commits | length) == 1 and .on_branch == true"' "control: a card run that commits on its own branch is accepted"
  ;;
stopfirst)   # builder (Gate B fix RT3-06): stop revokes the run token before it kills, so a process group that does not end leaves no live token
  ed .stella/adapters.json '.stop_grace_s = 1'
  W10=$CRD/qa-wt-st; mkwt "$W10" >/dev/null 2>&1
  SL=qadaemon$RANDOM$RANDOM
  DAEMON="setsid bash -c \"exec 9>/proc/\$PPID/fd/1; exec -a $SL sleep 120\" </dev/null >/dev/null 2>&1 & echo started"
  go s1 qa-run-st1 "$W10" qa-api/qa-m1 "$(jq -nc --arg d "$DAEMON" '[{op: "shell", cmd: $d}, {op: "shell", cmd: "sleep 30"}]')"
  spawned "$W10" qa-run-st1; sleep 2
  run p1 A stop --run qa-run-st1 --reason qa-stop
  live() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import run_token
with run_token.store() as st: print(sum(1 for v in st["tokens"].values() if v.get("run") == sys.argv[2] and not v.get("revoked")))' "$R/bin" qa-run-st1 2>/dev/null; }
  ok 'pgrep -f "$SL" >/dev/null' "RT3-06 precondition: a tool child in its own session holds the CLI's output open (the group cannot end)"
  ok '[ "$(live)" = 0 ]' "RT3-06 after stop (exit $RC) the run token is revoked"
  pkill -f "$SL" 2>/dev/null
  ;;
pins)   # builder (Gate B fix RT3-07, adapter half): each CLI gets its generated config in a way a config planted in the worktree cannot override
  mapfile -t ACT < <(jq -r '.entries[] | select(.status == "active" and (.id | startswith("qa-") | not)) | .id' "$AF")
  for id in "${ACT[@]}"; do
    b=$(jq -r --arg i "$id" '.entries[] | select(.id == $i) | .binary' "$AF"); v=$(jq -r --arg i "$id" '.entries[] | select(.id == $i) | .tested_versions[0]' "$AF")
    printf '#!/bin/sh\nfor x; do case "$x" in --version|-v|version) echo "%s %s"; exit 0;; esac; done\nprintf "%%s\\n" "$@" >"%s/pin-%s.argv"; env -0 >"%s/pin-%s.env"\n' "$b" "$v" "$T" "$id" "$T" "$id" >"$T/pb/$b"; chmod +x "$T/pb/$b"
  done
  # each shipped entry as a copy named qa-pin-<id> with unboxed true: no profile names it, so no box (the box is not under test here: V2-10, box selftest)
  for id in "${ACT[@]}"; do ed .stella/adapters.json --arg i "$id" --arg g "$(uuid)" '.entries += [(.entries[] | select(.id == $i)) + {id: ("qa-pin-" + $i), unboxed: true, global_id: $g}]'; done
  W11=$CRD/qa-wt-pin; mkwt "$W11" >/dev/null 2>&1
  ALLOW='{"permission": {"bash": "allow", "edit": "allow", "read": "allow", "external_directory": "allow"}, "permissions": {"allow": ["Bash(*)"], "deny": []}, "hooks": {}}'
  # every entry's config_files (data): a file glob gets an allow-everything config, a folder one inside it
  mapfile -t CF < <(jq -r '[.entries[] | select(.status == "active") | .config_files[]?] | unique[]' "$AF")
  for g in "${CF[@]}"; do f=${g//\*/}; case $f in *.json|*.jsonc) p=$W11/$f;; *) p=$W11/$f/config.json;; esac; mkdir -p "$(dirname "$p")"; printf '%s\n' "$ALLOW" >"$p"; done
  ok '[ ${#ACT[@]} -ge 2 ] && [ ${#CF[@]} -ge 2 ]' "RT3-07 precondition: the shipped active entries (${ACT[*]}) run as stubs that record their argv and env, in a worktree with their planted config files (${CF[*]})"
  for id in "${ACT[@]}"; do
    brief "qa-run-pin-$id" '[]'
    run "p-$id" A start --adapter "qa-pin-$id" --role "$ROLE" --worktree "$W11" --brief-file "$T/brief-qa-run-pin-$id.md" --link qa-api/qa-m1 --run-id "qa-run-pin-$id" --wait --json
    SF=$(find "$R/$AR/qa-run-pin-$id/cfg" -maxdepth 1 -type f ! -name 'run-policy.json' ! -name 'mcp.json' ! -name '*.md' | head -n1)
    PIN=$(jq -c --arg i "$id" '.entries[] | select(.id == $i) | {env: ((.start.env.set // {}) | to_entries | map(select(.value == "{settings_json}")) | map(.key))}' "$AF")
    ok '[ $RC = 0 ] && [ -s "$T/pin-$id.argv" ] && [ -s "$SF" ] && {
        { [ "$(jq ".env | length" <<<"$PIN")" -ge 1 ] && for k in $(jq -r ".env[]" <<<"$PIN"); do tr "\0" "\n" <"$T/pin-$id.env" | sed -n "s/^$k=//p" | jq -S . >"$T/pin-$id.got" && jq -S . "$SF" | cmp -s - "$T/pin-$id.got" || exit 1; done; } \
        || { s=$(grep -A1 -x -- "--setting-sources" "$T/pin-$id.argv" | tail -n1); grep -qx -- "--setting-sources" "$T/pin-$id.argv" && ! tr , "\n" <<<"$s" | grep -qx -e project -e local; }; }' \
      "RT3-07 $id: its run carries the generated config at the CLI's highest precedence (inline config env from data, or setting sources without project and local) despite the planted worktree configs"
  done
  ;;
stream)   # builder (Gate B fix RT3-04, V2-06 stream half): usage from every assistant message incl. cache tokens, tool results by id, OpenCode text is no result
  # The lines below are written from the CLIs' documented stream formats (Claude Code stream-json SDK messages; OpenCode run --format json), not captured from a real run.
  mkdir -p "$R/$AR"
  python3 -I - "$R/bin" "$WT" "$ROLE" >"$T/o/st.out" 2>"$T/o/st.err" <<'PY'
import json, os, re, subprocess, sys
sys.path.insert(0, sys.argv[1]); import adapter
def feed(aid, run, lines):
    os.makedirs(os.path.join(adapter.runs_dir(), run), exist_ok=True)
    base = subprocess.run(["git", "-C", sys.argv[2], "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    s = adapter.Stream(run, {"run": run, "role": sys.argv[3], "worktree": sys.argv[2], "base": base, "notes": None}, adapter.entry(aid), {"output_cap": 4000}, re.compile("(?!)"))
    for l in lines:
        s.line(json.dumps(l).encode())
    return adapter.read_events(run)
u1 = {"input_tokens": 4, "cache_creation_input_tokens": 41000, "cache_read_input_tokens": 0, "output_tokens": 30}
cc = feed("claude-code", "qa-st-cc", [
    {"type": "system", "subtype": "init", "model": "m", "session_id": "s"},
    {"type": "assistant", "message": {"id": "msg_1", "role": "assistant", "content": [{"type": "tool_use", "id": "tu_1", "name": "Read", "input": {"file_path": "README"}}], "usage": u1}},
    {"type": "assistant", "message": {"id": "msg_1", "role": "assistant", "content": [{"type": "tool_use", "id": "tu_2", "name": "Bash", "input": {"command": "ls"}}], "usage": u1}},
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "tu_2", "content": "README", "is_error": False}]}},
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "tu_1", "content": "base", "is_error": False}]}},
    {"type": "assistant", "message": {"id": "msg_2", "role": "assistant", "content": [{"type": "text", "text": "done"}], "usage": {"input_tokens": 6, "cache_read_input_tokens": 41030, "output_tokens": 5}}},
    {"type": "result", "subtype": "success", "result": "done", "usage": {"input_tokens": 10, "cache_creation_input_tokens": 41000, "cache_read_input_tokens": 41030, "output_tokens": 35}}])
oc = feed("opencode", "qa-st-oc", [
    {"type": "step_start", "part": {"type": "step-start"}},
    {"type": "text", "part": {"type": "text", "text": "looking"}},
    {"type": "tool_use", "part": {"type": "tool", "tool": "read", "callID": "c1", "state": {"status": "completed", "input": {"filePath": "README"}, "output": "base"}}},
    {"type": "step_finish", "part": {"type": "step-finish", "tokens": {"input": 900, "output": 20}}}])
print(json.dumps({"cc": cc, "oc": oc}))
PY
  cat "$T/o/st.out" "$T/o/st.err" >"$T/o/last"
  CC=$(jq -c .cc "$T/o/st.out" 2>/dev/null); OC=$(jq -c .oc "$T/o/st.out" 2>/dev/null)
  ok '[ -n "$CC" ] && jq -e "([.[] | select(.type == \"usage\")][0].tokens.input == 41004) and ([.[] | select(.type == \"usage\")][0].seq < [.[] | select(.type == \"tool_result\")][0].seq)" <<<"$CC"' \
    "RT3-04 Claude Code: the first usage comes from the first assistant message, cache tokens included (41004), before the first tool result"
  ok '[ -n "$CC" ] && jq -e "([.[] | select(.type == \"usage\") | .tokens.input] | add) == 82040 and ([.[] | select(.type == \"usage\") | .tokens.output] | add) == 35" <<<"$CC"' \
    "RT3-04 Claude Code: a message repeated on two lines counts once and the result line's totals are not added again (input 82040, output 35)"
  ok '[ -n "$CC" ] && jq -e "[.[] | select(.type == \"tool_result\") | [.name, .input]] == [[\"Bash\", {command: \"ls\"}], [\"Read\", {file_path: \"README\"}]]" <<<"$CC"' \
    "V2-06 Claude Code: parallel tool results are matched to their tool_use by id (Bash then Read), not to the last tool_use"
  ok '[ -n "$OC" ] && jq -e "([.[] | select(.type == \"result\")] | length) == 0 and ([.[] | select(.type == \"tool_result\" and .name == \"read\")] | length) == 1 and ([.[] | select(.type == \"usage\")][0].tokens.input == 900)" <<<"$OC"' \
    "V2-06 OpenCode: an assistant text part is no result event; the tool and its usage are read"
  ;;
boxdefault)   # builder (Gate B fix V2-10): boxing is the default; an entry without unboxed and without a boxed profile for the role is refused
  addent qa-boxed 'del(.unboxed)'
  addent qa-boxed-f '.unboxed = false'
  for id in qa-boxed qa-boxed-f; do
    brief "qa-run-bx-$id" '[]'
    run "b-$id" A start --adapter "$id" --role "$ROLE" --worktree "$WT" --brief-file "$T/brief-qa-run-bx-$id.md" --link qa-api/qa-m1 --run-id "qa-run-bx-$id" --json
    ok '[ $RC != 0 ] && out "b-$id" | grep -q STL-GRD-649 && none_ "$WT" "qa-run-bx-$id"' "V2-10 $id: no boxed profile for the role and no unboxed true in its data, start refused STL-GRD-649, nothing spawned"
  done
  ;;
esac
finish
