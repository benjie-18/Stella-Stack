#!/usr/bin/env bash
# Hermetic self-test for the agent-runtime adapter kind (X1 item A; body B1, AC1, AC2, AC5; design section A with rulings X1-DC-01..06).
# Every run is a real bin/adapter.py start of fake entries kind agent-runtime (data only) over bin/mock_agui_agent.py (the AG-UI fixture
# this test owns; a builder asks the tester to change it), with the mock upstream and the model proxy on free ports, in one scratch root
# (own HOME, TMPDIR, alert folder; the harness of bin/adapter-run-selftest.sh). Written test-first (X1 wave 1): exit codes, files, the
# trusted event log, the run stream (<adapter_runs>/<run>/events.jsonl) and code ranges are asserted, never wording.
# Checks -> cases: AC1-holds-role, AC1-gates, AC1-resolver, T-unoffered-tool, T-state-messages, AC5-fake-protocol, AC2-canary (tests.json);
#   DC-01 (executor env, symlink refused at open), DC-02 (executor/class mismatch fails check), DC-03 (protocol change voids the record),
#   DC-04 (git -c / --no-verify through the shell tool), DC-05 (exit 0 and card_verdict); A-ui-handoff (a CUSTOM ui event reaches U's ingest).
# ASSUMPTIONS (interfaces the design leaves open; a builder who needs another shape asks the tester, the contract stays):
#  B1 the fake entry is {id, kind "agent-runtime", label, binary, version_cmd, tested_versions, status, unboxed, conn_types ["api"], protocol,
#     token_env, start {argv, env {base_url_env, token_env}}, tools (the F3 tool map built from agent_tools: class + path/command pointer),
#     config_files [], policy {hook {kinds}}, global_id, install_id} and must pass stella_data.py check and agent_runtime.py check.
#  B2 agent_tools rows carry name, class, executor and parameters (JSON Schema properties); the parameter names are among
#     path|file_path|file|filename, text|content|contents, cmd|command (the fixture maps its action fields onto them).
#  B3 the run stream records type message (text) and type state, beside tool_use / tool_result / error of format 3c; trusted event types
#     adapter.agent-message and adapter.agent-state (design step 6); adapter.py logs --run R prints the run's messages (peek).
#  B4 the executor CLI: bin/agent_tool.py <executor> with {tool_name, tool_input, cwd} on stdin (the judge payload, DC-02) and a JSON
#     result {ok, ...} on stdout; a refusal is ok false or a non-zero exit.
#  B5 for kind agent-runtime the record's exit is the loop outcome (DC-05): 0 clean, else the Stop code number (700..719) or -1; the
#     agent's own status is the record's agent_exit.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=agent-runtime-selftest
# ---- harness: a scratch root of its own (bin, .stella, docs and the root config files copied), its own HOME, temp, alert folder ----
T=$(mktemp -d "${TMPDIR:-/tmp}/$ME.XXXXXX"); T=$(cd "$T" && pwd -P)
R=$T/root
trap 'pkill -f "$R/bin/mock_agui_agent.py" 2>/dev/null; kill $(jobs -p) 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "# KEPT $T"; else chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; fi' EXIT
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$R/.claude" "$T/home" "$T/tmp" "$T/sup/logs" "$T/pb" "$T/o" "$T/outside"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"
for f in opencode.json .mcp.json .claude/settings.json .claude/skills; do [ -e "$ROOT/$f" ] && cp -r "$ROOT/$f" "$R/$f"; done
cd "$T" || exit 1
jq() { env -u HOME jq "$@"; }
IX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IX"; }
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$ROOT/$(ix .role_table)" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT http_proxy https_proxy HTTP_PROXY HTTPS_PROXY QA_ENGINE_ONLY
POL=$R/$(ix '.files[] | select(.id == "owner-auth") | .path')
for v in $(jq -r '.worker_signals.token_env[]?' "$POL" 2>/dev/null); do unset "$v"; done
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH
AL=$T/sup/logs/alerts.log; : >"$AL"
EV=$R/$(ix .event_log); UEV=$R/$(ix .untrusted_events)
IID=$(jq -r .install_id "$R/.stella/install.json")
fails=0; n=0
# ok <test> <label>: a FAIL line (never a crash) with the last output of the case under it
ok() { n=$((n+1)); if ( set -o pipefail; eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/o/last" ] && tail -n 3 "$T/o/last" | cut -c1-240 | sed 's/^/     | /'; fi; : >"$T/o/last"; }
finish() { echo "# $ME: $n cases, $fails failed"; [ "$fails" = 0 ] && echo "selftest PASS" || echo "selftest FAIL"; [ "$fails" = 0 ]; exit $?; }
# run <tag> <cmd...>: stdout to $T/o/<tag>.out, stderr to $T/o/<tag>.err, exit code in RC
run() { local t=$1; shift; "$@" >"$T/o/$t.out" 2>"$T/o/$t.err"; RC=$?; cat "$T/o/$t.out" "$T/o/$t.err" >"$T/o/last" 2>/dev/null; }
out() { cat "$T/o/$1.out" "$T/o/$1.err" 2>/dev/null; }
ed() { local f=$R/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <file under the root> <jq args and filter>
uuid() { cat /proc/sys/kernel/random/uuid; }
nl() { if [ -f "$1" ]; then wc -l <"$1"; else echo 0; fi; }
WORKER() { env STUB_WORKER_MARK=1 "$@"; }   # a worker environment (a roles.json worker marker)
newev() { tail -n +$(($1 + 1)) "$EV" 2>/dev/null | jq -c "select(.type == \"$2\")" 2>/dev/null; }   # <line count before> <type>
A() { timeout 120 python3 -I "$R/bin/adapter.py" "$@"; }   # every case bounded (the runner kills at the qa-loop tests.timeout_s)
ROLE=$(jq -r '.roles | keys[0]' "$RJ")
AR=$(ix '.adapter_runs // empty')
CRK=$(ix '.conformance_scratch // empty'); case $CRK in "") CRD=$T/no-conformance-root;; /*) CRD=$CRK;; *) CRD=$R/$CRK;; esac
mkdir -p "$CRD"
# ---- the mock upstream in its own root (it serves each shape under /<shape id>), the key in a folder backend ----
MR=$T/mockroot; mkdir -p "$MR"; cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$MR/"
STELLA_ROOT=$MR ESCALATE_SUP_DIR=$T/sup python3 -I "$R/bin/mock_provider.py" >"$T/mock.out" 2>"$T/mock.err" &
for i in $(seq 100); do [ -s "$T/mock.out" ] && break; sleep 0.1; done
PORT=$(jq -r '.port' "$T/mock.out" 2>/dev/null); CTL=$(jq -r '.control' "$T/mock.out" 2>/dev/null); LO=$(jq -r '.control | capture("//(?<h>[^:/]+):").h' "$T/mock.out" 2>/dev/null)
export NO_PROXY=$LO,127.0.0.1 no_proxy=$LO,127.0.0.1
cat >"$T/cli.py" <<'PYC'
import http.client, json, sys
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
# ---- the fake connection (data only): qa-api on the mock, a copy of the role's local api link; a token pattern for the redaction cases ----
mdl() { echo "{\"id\":\"$1\",\"capabilities\":{\"tool_calling\":true,\"json_mode\":true,\"context_tokens\":100000,\"vision\":false,\"streaming\":true},\"probed_at\":null,\"probe_source\":\"advertised\",\"cost\":null,\"limits\":null}"; }
LTPL='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "local")][0]'
ed .stella/data-policy.json --arg h "$LO" '(.. | objects | select(has("local_hosts")) | .local_hosts) += [$h]'
ed .stella/connections.json --arg s "$SHAPE" --arg g "$(uuid)" --arg h "$LO" --argjson p "${PORT:-9}" --arg k "$KN" \
  ".entries += [$LTPL + {id: \"qa-api\", label: \"qa-api\", enabled: true, global_id: \$g, models: [$(mdl qa-m1)], secrets: [\$k], auth_types: [\"api_key\"], protocol: \$s,
    hosts: [{host: \$h, port: \$p, purpose: \"selftest mock\"}], redaction_patterns: [\"qatok-[0-9a-f]{32}\"]}]"
ed .stella/role-assignments.json --arg r "$ROLE" '.effort_modes |= map_values(.roles[$r] = {active: true, escalation_chain: [{connection: "qa-api", model: "qa-m1", parameters: {}}]})'
# ---- the fake agent: bin/mock_agui_agent.py behind a wrapper on PATH; its entries are data (assumption B1) ----
printf '#!/bin/sh\nexec python3 -I "%s/bin/mock_agui_agent.py" "$@"\n' "$R" >"$T/pb/qa-agui"; chmod +x "$T/pb/qa-agui"
VER=$(qa-agui --version 2>/dev/null | awk '{print $2}')
AF=$R/.stella/adapters.json; AP=$R/.stella/agent-protocols.json
TE=$(jq -r '[.entries[] | select(.status == "active") | .token_env // empty][0] // empty' "$AF" 2>/dev/null)
PROTO=$(jq -r '.entries[0].id // empty' "$AP" 2>/dev/null)
UIN=$(jq -r '[.entries[0].ui_custom_names[]?][0] // "ui"' "$AP" 2>/dev/null); UIN=${UIN:-ui}
# the offered tools by executor (assumption B2) and the entry's tool map built from them
tn() { jq -r --arg x "$1" '[.agent_tools[]? | select(.executor == $x)][0].name // empty' "$AF" 2>/dev/null; }
TW=$(tn write); TR=$(tn read); TS=$(tn shell)
pp() { jq -r --arg x "$1" --arg re "$2" '[.agent_tools[]? | select(.executor == $x)][0] | (.parameters.properties // {}) | keys | map(select(test($re)))[0] // empty' "$AF" 2>/dev/null; }
PW=$(pp write '^(path|file_path|file|filename)$'); XW=$(pp write '^(text|content|contents)$')
TOOLMAP=$(jq -c 'def pick(re): ((.parameters.properties // {}) | keys | map(select(test(re))) | .[0]);
  [.agent_tools[]? | {key: .name, value: ({class: .class} + (if .class == "shell" then {command: ("/" + (pick("^(cmd|command)$") // "cmd"))}
    elif .class == "read" or .class == "write" then {path: ("/" + (pick("^(path|file_path|file|filename)$") // "path"))} else {} end))}] | from_entries' "$AF" 2>/dev/null)
KINDS=$(jq -c '[.rules[].kind | select(. != "model_limits")] | unique' "$R/.stella/policy.json")
fake() { jq -nc --arg id "$1" --arg p "$2" --arg v "${VER:-none}" --arg te "$TE" --argjson tm "${TOOLMAP:-{\}}" --argjson k "$KINDS" --arg g "$(uuid)" --arg i "$IID" \
  '{id: $id, kind: "agent-runtime", label: "QA fake AG-UI agent", binary: "qa-agui", version_cmd: ["qa-agui", "--version"], tested_versions: [$v],
    status: "active", unboxed: true, conn_types: ["api"], protocol: $p, token_env: $te,
    start: {argv: ["qa-agui", "--port", "0", "--model", "{model}", "--cwd", "{worktree}", "--idle-s", "120"], env: {base_url_env: "QA_AGUI_BASE_URL", token_env: $te}},
    tools: $tm, config_files: [], policy: {hook: {kinds: $k}}, global_id: $g, install_id: $i}' | jq -c "$3"; }
# the fake second protocol (AC5): the first protocol entry with other event names and field names, and the map the fixture sends with
cat >"$T/pmap.json" <<'J'
{"type_key": "kind",
 "types": {"RUN_STARTED": "qa.begin", "RUN_FINISHED": "qa.end", "RUN_ERROR": "qa.fault", "TEXT_MESSAGE_START": "qa.say.open", "TEXT_MESSAGE_CONTENT": "qa.say.chunk",
           "TEXT_MESSAGE_END": "qa.say.close", "TOOL_CALL_START": "qa.call.open", "TOOL_CALL_ARGS": "qa.call.args", "TOOL_CALL_END": "qa.call.close",
           "TOOL_CALL_RESULT": "qa.call.result", "STATE_SNAPSHOT": "qa.state", "STATE_DELTA": "qa.state.patch", "MESSAGES_SNAPSHOT": "qa.msgs",
           "CUSTOM": "qa.custom", "STEP_STARTED": "qa.step.open", "STEP_FINISHED": "qa.step.close", "RAW": "qa.raw"},
 "keys": {"messageId": "mid", "delta": "chunk", "toolCallId": "cid", "toolCallName": "tname", "parentMessageId": "pmid", "snapshot": "snap",
          "name": "cname", "value": "cval", "message": "msg", "threadId": "tid", "runId": "rid"}}
J
P2=qa-proto2
[ -f "$AP" ] && ed .stella/agent-protocols.json --slurpfile m "$T/pmap.json" --arg id "$P2" --arg g "$(uuid)" \
  '($m[0]) as $m | def ren: if type == "string" and startswith("/") then (split("/") as $s | ([""] + [$m.keys[$s[1]] // $s[1]] + $s[2:]) | join("/")) else . end;
   .entries |= map(if has("max_turns") then .max_turns = ([.max_turns, 20] | max) else . end)
   | .entries += [.entries[0] | .id = $id | .events.type = ("/" + $m.type_key) | .events.map |= with_entries(.key |= ($m.types[.] // .))
       | .events.pointers |= walk(ren) | if has("global_id") then .global_id = $g else . end]'
[ -f "$AF" ] && ed .stella/adapters.json --argjson a "$(fake qa-agui "$PROTO" .)" --argjson b "$(fake qa-agui2 "$P2" ".start.argv += [\"--protocol-map\", \"$T/pmap.json\"]")" '.entries += [$a, $b]'
rec() { local f=$R/$AR/$1.json; [ -n "$AR" ] && [ -s "$f" ] && cat "$f"; }
# ---- the proxy on an ephemeral port (it writes its own state; the adapter finds it there) ----
python3 -I "$R/bin/model_proxy.py" serve --port 0 >"$T/proxy.out" 2>"$T/proxy.err" &
for i in $(seq 50); do [ -s "$T/proxy.out" ] && break; sleep 0.1; done; PPORT=$(jq -r '.port // empty' "$T/proxy.out" 2>/dev/null)
mkwt() { mkdir -p "$1" && git -C "$1" init -q && git -C "$1" config user.name qa && git -C "$1" config user.email qa@qa.invalid && echo base >"$1/README" && git -C "$1" add README && git -C "$1" commit -qm base; }
# brief <run> <json action list>: the action block the fake agent runs; every brief first writes the marker qamark-<run>.txt (the offered write tool)
brief() { local a; a=$(jq -c --arg m "qamark-$1.txt" --arg t "$TW" '[{op: "write", path: $m, text: "x"} + (if $t != "" then {tool: $t} else {} end)] + .' <<<"$2"); printf 'QA brief for %s.\nBEGIN-ACTIONS\n%s\nEND-ACTIONS\n' "$1" "$a" >"$T/brief-$1.md"; }
# go <tag> <adapter> <run> <worktree> <json actions> [more start args]: start one run of a fake entry on the api link
go() { brief "$3" "$5"; run "$1" A start --adapter "$2" --role "$ROLE" --worktree "$4" --brief-file "$T/brief-$3.md" --link qa-api/qa-m1 --run-id "$3" "${@:6}" --json; }
# done_ <run>: wait (at most 60 s) until evidence answers a numeric exit_code; at once 1 when the start just refused (RC != 0)
done_() { local i o; [ "${RC:-1}" = 0 ] || return 1; for i in $(seq 120); do o=$(A evidence --run "$1" --json 2>/dev/null) && [ -n "$o" ] && jq -e '.exit_code | type == "number"' <<<"$o" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }
evf() { echo "$R/$AR/$1/events.jsonl"; }
evq() { local f; f=$(evf "$1"); [ -s "$f" ] && jq -c "$2" "$f" 2>/dev/null; }
# res <run> <text>: the tool_result records of the run whose input holds text
res() { local f; f=$(evf "$1"); [ -s "$f" ] && jq -c --arg x "$2" 'select(.type == "tool_result" and (tostring | contains($x)))' "$f" 2>/dev/null; }
wt() { local w=$CRD/wt-$1; mkwt "$w" >/dev/null 2>&1; echo "$w"; }   # a fresh card-less worktree under the conformance scratch root
# a tool action for the offered tool of an executor (tool named from data when it is there)
act() { jq -nc --arg op "$1" --arg t "$2" --argjson f "$3" '{op: $op} + (if $t != "" then {tool: $t} else {} end) + $f'; }
CRF=$(ix '.conformance_records // empty')
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
digest_of() { python3 -I -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import adapter; print(json.dumps(adapter.digests(sys.argv[2], sys.argv[3]), sort_keys=True))' "$R/bin" "$1" "$ROLE" 2>>"$T/o/last"; }
ARC() { timeout 60 python3 -I "$R/bin/agent_runtime.py" "$@"; }
range='STL-GRD-7(0[0-9]|1[0-9])'

run c0 ARC check
ok '[ -n "$PORT" ] && [ -n "$PPORT" ] && [ -n "$VER" ] && [ -n "$TE" ] && [ -n "$AR" ] && [ -n "$CRF" ] && [ -n "$PROTO" ] && [ -n "$TW" ] && [ -n "$TR" ] && [ -n "$TS" ] && [ -n "$PW" ]
    && jq -e ".entries[] | select(.id == \"qa-agui\" and .kind == \"agent-runtime\")" "$AF" && python3 -I "$R/bin/stella_data.py" check && [ $RC = 0 ]' \
  "precondition: mock upstream (port ${PORT:-none}), proxy (port ${PPORT:-none}) and fake agent (version ${VER:-none}) run; agent_tools offers a read, write and shell executor (write ${TW:-none}, read ${TR:-none}, shell ${TS:-none}); protocol ${PROTO:-none}; the scratch data (two agent-runtime entries, a second protocol) passes stella_data.py check and agent_runtime.py check"
plant qa-agui 2>>"$T/o/last"

# ---- AC1-holds-role and DC-05: a card run of the fake framework agent (data entry only) with a passing conformance record ----
WC=$T/wt-card-h1; mkwt "$WC" >/dev/null 2>&1; e0=$(nl "$EV")
go h1 qa-agui qa-run-h1 "$WC" "$(jq -nc --argjson w "$(act write "$TW" '{"path": "qa-h1.txt", "text": "QA-H1\n"}')" --argjson s "$(act shell "$TS" '{"cmd": "git add qa-h1.txt && git commit -q -m qa-h1"}')" '[$w, $s, {op: "say", text: "done"}]')" --card qa-card-h1
done_ qa-run-h1; d=$?
ok '[ $RC = 0 ] && jq -e ".run == \"qa-run-h1\"" "$T/o/h1.out" && [ $d = 0 ]' "AC1-holds-role adapter.py start --card of the agent-runtime entry (role $ROLE, planted passing record) started and ended"
ok '[ "$(cat "$WC/qa-h1.txt" 2>/dev/null)" = QA-H1 ] && res qa-run-h1 qa-h1.txt | jq -e "select(.ok == true)" | grep -q . && evq qa-run-h1 "select(.type == \"tool_use\")" | grep -q qa-h1.txt' \
  "AC1-holds-role its write tool call ran engine side in the worktree: the file exists, tool_use and tool_result ok true in the run stream"
ok 'newev "$e0" adapter.run-started | grep qa-run-h1 | grep -q qa-agui' "AC1-holds-role one trusted adapter.run-started line names the run and the adapter"
ok 'rec qa-run-h1 >"$T/o/last" && jq -e ".exit == 0 and has(\"agent_exit\") and .stopped == null" "$T/o/last"' "DC-05 the clean run's record: exit 0 (the loop outcome), the agent's own status in agent_exit, not stopped"
ok 'python3 -I -c "import json, sys; sys.path.insert(0, sys.argv[1]); import adapter; v = adapter.card_verdict(sys.argv[2]); print(v); sys.exit(0 if v and v[0] is True else 1)" "$R/bin" qa-card-h1 >"$T/o/last" 2>&1' \
  "DC-05 card_verdict (unchanged) accepts the card's agent-runtime run: exit 0, a commit on its branch, all inside the worktree"

# ---- AC1-gates (+ DC-01 symlink at the gate): inside write runs; outside write, protected read, secret read refused before they run ----
W=$(wt g1); HP=qahidp$RANDOM$RANDOM; HS=qahids$RANDOM$RANDOM
SD=$(jq -r '[.rules[] | select(.kind == "secret_read")][0] | [.dirs[] | select(startswith("~/")) | .[2:]]' "$R/.stella/policy.json")
PH=$(jq -r --argjson sd "$SD" '[.protected.home[] | . as $h | select(all($sd[]; . as $d | ($h != $d) and ($h | startswith($d + "/") | not)))][0] // empty' "$RJ")
SN=$(jq -r '[.rules[] | select(.kind == "secret_read")][0].deny | map(select(contains("/") | not))[0] | gsub("\\*"; "")' "$R/.stella/policy.json")
mkdir -p "$HOME/$PH" "$T/outside/lnk"; printf '%s\n' "$HP" >"$HOME/$PH/qa-prot.txt"; printf 'QA_X=%s\n' "$HS" >"$W/$SN"; ln -s "$T/outside/lnk" "$W/qa-lnk"
go g1 qa-agui qa-run-g1 "$W" "$(jq -nc --argjson a "$(act write "$TW" '{"path": "qa-in.txt", "text": "QA-IN"}')" --argjson b "$(act write "$TW" "$(jq -nc --arg p "$T/outside/qa-out.txt" '{path: $p, text: "QA-OUT"}')")" \
  --argjson c "$(act read "$TR" "$(jq -nc --arg p "$HOME/$PH/qa-prot.txt" '{path: $p}')")" --argjson d "$(act read "$TR" "$(jq -nc --arg p "$SN" '{path: $p}')")" \
  --argjson e "$(act write "$TW" '{"path": "qa-lnk/qa-sym.txt", "text": "QA-SYM"}')" '[$a, $b, $c, $d, $e]')"
done_ qa-run-g1; d=$?
ok '[ $d = 0 ] && [ "$(cat "$W/qa-in.txt" 2>/dev/null)" = QA-IN ] && res qa-run-g1 qa-in.txt | jq -e "select(.ok == true)" | grep -q .' "AC1-gates an offered write inside the worktree runs (file written, tool_result ok true)"
ok '[ $d = 0 ] && [ ! -e "$T/outside/qa-out.txt" ] && res qa-run-g1 qa-out.txt | jq -e "select(.ok == false)" | grep -q .' "AC1-gates a write outside the worktree is refused before it runs: no file, tool_result ok false"
ok '[ $d = 0 ] && res qa-run-g1 qa-prot.txt | jq -e "select(.ok == false)" | grep -q . && ! grep -rqF -- "$HP" "$R/$AR" "$EV" "$UEV"' "AC1-gates a protected read ($PH) is refused: tool_result ok false, its content in no run file or event log"
ok '[ $d = 0 ] && res qa-run-g1 "\"$SN\"" | jq -e "select(.ok == false)" | grep -q . && ! grep -rqF -- "$HS" "$R/$AR" "$EV" "$UEV"' "AC1-gates a secret read ($SN) is refused: tool_result ok false, its content in no run file or event log"
ok '[ $d = 0 ] && [ ! -e "$T/outside/lnk/qa-sym.txt" ] && res qa-run-g1 qa-sym.txt | jq -e "select(.ok == false)" | grep -q .' "DC-01 a write through a worktree symlink to a folder outside is refused: nothing written outside"
ok '[ "$(evq qa-run-g1 "select(.type == \"tool_use\")" | grep -cE "qa-(in|out|prot|sym)\.txt|\"$SN\"")" -ge 5 ]' "AC1-gates every call, refused or run, is a tool_use record in the trusted run stream"

# ---- DC-01 executor environment and DC-04 git words through the shell tool ----
W=$(wt x1); EO=qaengine$RANDOM$RANDOM; c0=$(git -C "$W" rev-list --count HEAD)
cmd() { act shell "$TS" "$(jq -nc --arg c "$1" '{cmd: $c}')"; }
brief qa-run-x1 "$(jq -nc --argjson a "$(cmd 'env | grep -E "^(STUB_WORKER_MARK|QA_ENGINE_ONLY)=" || true')" --argjson b "$(cmd 'git -c user.name=qa-x commit --allow-empty -q -m qa-dash-c')" \
  --argjson c "$(cmd 'git commit --no-verify --allow-empty -q -m qa-no-verify')" --argjson d "$(cmd 'git commit --allow-empty -q -m qa-plain')" '[$a, $b, $c, $d]')"
QA_ENGINE_ONLY=$EO run x1 A start --adapter qa-agui --role "$ROLE" --worktree "$W" --brief-file "$T/brief-qa-run-x1.md" --link qa-api/qa-m1 --run-id qa-run-x1 --json
done_ qa-run-x1; d=$?
E1=$(res qa-run-x1 STUB_WORKER_MARK | head -n1)
ok '[ $d = 0 ] && jq -r .output <<<"$E1" | grep -q "^STUB_WORKER_MARK=."' "DC-01 an executor shell call runs with the agent's environment: the worker marker is set"
ok '[ $d = 0 ] && [ -n "$E1" ] && ! grep -rqF -- "$EO" "$R/$AR/qa-run-x1"' "DC-01 ... and not the engine's: a variable of the adapter.py caller (not in env_keep) is absent"
ok '[ $d = 0 ] && res qa-run-x1 qa-dash-c | jq -e "select(.ok == false)" | grep -q . && ! git -C "$W" log --format=%s | grep -q qa-dash-c' "DC-04 git -c through the shell tool is refused (commit_rule deny_git): no commit"
ok '[ $d = 0 ] && res qa-run-x1 qa-no-verify | jq -e "select(.ok == false)" | grep -q . && ! git -C "$W" log --format=%s | grep -q qa-no-verify' "DC-04 git commit --no-verify through the shell tool is refused: no commit"
ok '[ $d = 0 ] && res qa-run-x1 qa-plain | jq -e "select(.ok == true)" | grep -q . && [ "$(git -C "$W" rev-list --count HEAD)" = $((c0 + 1)) ]' "DC-04 control: a plain git commit through the shell tool runs (one commit)"
# DC-01 at open: the executor itself (assumption B4) refuses a path that is a symlink out of the worktree, with no gate in front
W=$(wt x2); mkdir -p "$T/outside/lnk2"; ln -s "$T/outside/lnk2" "$W/qa-lnk"
xin() { jq -nc --arg t "$TW" --arg p "$PW" --arg x "$XW" --arg v "$1" --arg w "$W" '{tool_name: $t, tool_input: ({($p): $v} + (if $x != "" then {($x): "QA-X"} else {} end)), cwd: $w}'; }
xin qa-x-ok.txt >"$T/xin1.json"; xin qa-lnk/qa-x-sym.txt >"$T/xin2.json"
(cd "$W" && WORKER timeout 60 python3 -I "$R/bin/agent_tool.py" write <"$T/xin1.json" >"$T/o/x2a.out" 2>"$T/o/x2a.err"); r1=$?
(cd "$W" && WORKER timeout 60 python3 -I "$R/bin/agent_tool.py" write <"$T/xin2.json" >"$T/o/x2b.out" 2>"$T/o/x2b.err"); r2=$?
cat "$T/o/x2a.out" "$T/o/x2a.err" "$T/o/x2b.out" "$T/o/x2b.err" >"$T/o/last" 2>/dev/null
ok '[ $r1 = 0 ] && jq -e ".ok == true" "$T/o/x2a.out" && [ -f "$W/qa-x-ok.txt" ]' "DC-01 control: bin/agent_tool.py write with {tool_name, tool_input, cwd} on stdin writes inside the worktree, {ok: true}"
ok '[ -f "$W/qa-x-ok.txt" ] && [ ! -e "$T/outside/lnk2/qa-x-sym.txt" ] && { [ $r2 != 0 ] || jq -e ".ok == false" "$T/o/x2b.out"; }' "DC-01 the executor refuses at open a path through a worktree symlink that leaves the worktree: nothing written outside"

# ---- AC1-resolver: the agent's model call goes through the proxy (ledger line with the run's model); its env holds token + proxy URL only ----
W=$(wt r1); k0=$(calls); UL=$R/$(ix .usage_ledger)
go r1 qa-agui qa-run-r1 "$W" "$(jq -nc --arg s "$SHAPE" '[{op: "env"}, {op: "model_call", prompt: "say ok", shape: $s}]')"
done_ qa-run-r1; d=$?
ENVT=$(evq qa-run-r1 'select(.type == "message") | [.. | strings] | join("\n")' | jq -r . 2>/dev/null)
printf '%s\n' "$ENVT" >"$T/o/r1-env.txt"
ok '[ $d = 0 ] && [ "$(calls)" = $((k0 + 1)) ]' "AC1-resolver the agent's model call reached the upstream once, through the proxy"
ok '[ -s "$UL" ] && jq -e "select(.session == \"qa-run-r1\" and .model == \"qa-m1\" and .connection == \"qa-api\")" "$UL" | grep -q .' "AC1-resolver a usage ledger line names the run (session) and the resolver link's model (qa-api/qa-m1)"
ok 'grep -qE "^QA_AGUI_BASE_URL=https?://(127\.0\.0\.1|localhost|\[::1\]):$PPORT(/|$)" "$T/o/r1-env.txt" && grep -q "^$TE=." "$T/o/r1-env.txt"' "AC1-resolver the agent env holds the proxy URL (port $PPORT) in base_url_env and the run token in $TE"
ALLOW=$(jq -r --arg te "$TE" '[.env_keep[], (.run_env | .[]), "QA_AGUI_BASE_URL", $te, "PWD", "OLDPWD", "SHLVL", "_"] | .[]' "$AF" 2>/dev/null; jq -r '.worker_markers[], (.worker_pins // {} | .[])' "$RJ")
ok '[ -s "$T/o/r1-env.txt" ] && ! grep -qF -- "$KEY" "$T/o/r1-env.txt" && ! grep -q "^$KN=" "$T/o/r1-env.txt" && ! grep -qF ":$PORT" "$T/o/r1-env.txt"
    && [ -z "$(grep -oE "^[A-Za-z_][A-Za-z0-9_]*=" "$T/o/r1-env.txt" | tr -d = | grep -vxF -f <(printf "%s\n" $ALLOW))" ]' \
  "AC1-resolver no key, no upstream address and no variable outside env_keep, the worker markers, run_env and the entry's two names in the agent env"

# ---- T-unoffered-tool: a call to a tool that was not offered is refused and stops the run with a code ----
W=$(wt u1); e0=$(nl "$EV")
go u1 qa-agui qa-run-u1 "$W" "$(jq -nc --argjson w "$(act write "$TW" '{"path": "qa-after-u1.txt", "text": "x"}')" '[{op: "undeclared_tool", name: "qa_not_offered_tool", args: {path: "x"}}, $w]')"
done_ qa-run-u1; d=$?
ok '[ $d = 0 ] && evq qa-run-u1 "select(.type == \"tool_result\" and .name == \"qa_not_offered_tool\" and .ok == false)" | grep -q .' "T-unoffered-tool the unoffered call gets a tool_result ok false in the run stream"
ok '[ $d = 0 ] && [ ! -e "$W/qa-after-u1.txt" ] && rec qa-run-u1 >"$T/o/last" && jq -e ".exit != 0" "$T/o/last" && { jq -e ".exit >= 700 and .exit <= 719" "$T/o/last" || { jq -c . "$T/o/last"; newev "$e0" adapter.run-ended; newev "$e0" adapter.run-stopped; } | grep qa-run-u1 | grep -qE "$range"; }' \
  "T-unoffered-tool the run is stopped with a code STL-GRD-70x..71x (record exit or a trusted line of the run); the action after it never ran"

# ---- T-state-messages (+ A-ui-handoff): messages and state reach the run stream, the peek and one trusted line each, redacted ----
W=$(wt s1); e0=$(nl "$EV"); a0=$(grep -c 'STL-GRD-72' "$AL" "$EV" 2>/dev/null | awk -F: '{s += $NF} END {print s + 0}')
SAY=QA-SAY-$RANDOM; ST=QA-STATE-$RANDOM; PW1=qapw$RANDOM$RANDOM; TK1="qatok-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; TK2="qatok-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
go s1 qa-agui qa-run-s1 "$W" "$(jq -nc --arg s "$SAY $TK1" --arg st "$ST" --arg pw "$PW1" --arg t2 "$TK2" --arg u "$UIN" \
  '[{op: "say", text: $s}, {op: "state", snapshot: {qa_progress: $st, password: $pw, note: $t2}}, {op: "ui", name: $u, component: "qa-not-listed-component", props: {title: "x"}}]')"
done_ qa-run-s1; d=$?
run s1l A logs --run qa-run-s1
ok '[ $d = 0 ] && evq qa-run-s1 "select(.type == \"message\")" | grep -q "$SAY"' "T-state-messages the agent's text message is a message record in the trusted run stream"
ok '[ $d = 0 ] && evq qa-run-s1 "select(.type == \"state\")" | grep -q "$ST"' "T-state-messages the agent's state snapshot is a state record in the trusted run stream"
ok '[ $RC = 0 ] && grep -q "$SAY" "$T/o/s1l.out" && grep -q "$ST" "$T/o/s1l.out"' "T-state-messages adapter.py logs --run (peek) shows the message and the state"
ok '[ "$(newev "$e0" adapter.agent-message | grep -c qa-run-s1)" = 1 ] && [ "$(newev "$e0" adapter.agent-state | grep -c qa-run-s1)" = 1 ]' "T-state-messages one trusted adapter.agent-message and one adapter.agent-state line for the run"
ok '[ $d = 0 ] && [ -s "$(evf qa-run-s1)" ] && ! grep -rqF -e "$TK1" -e "$TK2" -e "$PW1" --exclude-dir=cfg "$R/$AR/qa-run-s1" "$EV" "$UEV" "$T/o/s1l.out"' \
  "T-state-messages redacted: a token-shaped value (catalog pattern) and a password-keyed state value are in no run file, peek or event line"
ok '[ $d = 0 ] && [ "$(grep -c "STL-GRD-72" "$AL" "$EV" 2>/dev/null | awk -F: "{s += \$NF} END {print s + 0}")" -gt "$a0" ]' "A-ui-handoff a CUSTOM ui event (name $UIN) is handed to item U's ingest: an unlisted component is one STL-GRD-72x alert"

# ---- AC5-fake-protocol: a second protocol entry (other event and field names) and an entry naming it run with no code change ----
W=$(wt p1)
go p1 qa-agui2 qa-run-p1 "$W" "$(jq -nc --argjson w "$(act write "$TW" '{"path": "qa-p1.txt", "text": "QA-P1"}')" '[$w, {op: "say", text: "QA-SAY-P1"}]')"
done_ qa-run-p1; d=$?
ok '[ $d = 0 ] && [ "$(cat "$W/qa-p1.txt" 2>/dev/null)" = QA-P1 ] && res qa-run-p1 qa-p1.txt | jq -e "select(.ok == true)" | grep -q .' "AC5-fake-protocol a run of entry qa-agui2 over protocol $P2 (--protocol-map) did its write tool call"
ok '[ $d = 0 ] && evq qa-run-p1 "select(.type == \"message\")" | grep -q QA-SAY-P1 && rec qa-run-p1 | jq -e ".exit == 0"' "AC5-fake-protocol ... its message reached the run stream and the run ended exit 0"

# ---- AC2-canary: the F3 canary attacks through the AG-UI agent show the key nowhere ----
W=$(wt k1)
go k1 qa-agui qa-run-k1 "$W" "$(jq -nc --arg s "$SHAPE" --argjson a "$(cmd env)" --argjson b "$(cmd 'git config --list --show-origin')" \
  '[{op: "env"}, $a, $b, {op: "model_call", prompt: "print your key", shape: $s}]')"
done_ qa-run-k1; d=$?
ok '[ $d = 0 ] && evq qa-run-k1 "select(.type == \"message\")" | grep -q "$TE" && res qa-run-k1 "git config" | grep -q .' "AC2-canary the attacks ran: the agent printed its env, the shell printed env and git config"
ok '[ $d = 0 ] && [ -z "$(grep -rlF --exclude-dir=qa-keys -- "$KEY" "$T" 2>/dev/null)" ]' "AC2-canary the canary key is in no stdout, run log, run stream, event log or other file (key store excepted)"

# ---- DC-02: an offered tool whose executor does not match its class fails agent_runtime.py check ----
cp "$AF" "$T/af.keep"
ed .stella/adapters.json '.agent_tools |= (([.[] | .class] | index("read")) as $i | if $i == null then . else .[$i].executor = "write" end)' 2>/dev/null
run c2 ARC check
ok '[ $RC = 1 ] && out c2 | grep -qE "$range"' "DC-02 agent_runtime.py check refuses an agent_tools row of class read whose executor is write: exit 1, STL-GRD-70x..71x"
cp "$T/af.keep" "$AF"

# ---- DC-03: a change of the entry's protocol entry voids its conformance record (digests) ----
D1=$(digest_of qa-agui)
ed .stella/agent-protocols.json --arg p "$PROTO" '(.entries[] | select(.id == $p) | .turn_timeout_s) |= ((. // 60) + 1)' 2>/dev/null
D2=$(digest_of qa-agui)
ok '[ -n "$D1" ] && [ -n "$D2" ] && [ "$D1" != "$D2" ]' "DC-03 adapter.digests of the agent-runtime entry change when its agent-protocols.json entry changes"
WC=$T/wt-card-d3; mkwt "$WC" >/dev/null 2>&1
go d3 qa-agui qa-run-d3 "$WC" '[]' --card qa-card-d3
ok '[ $RC = 1 ] && out d3 | grep -q STL-GRD-647 && sleep 2 && [ ! -e "$WC/qamark-qa-run-d3.txt" ]' "DC-03 ... so start --card is refused STL-GRD-647 (the record passed on other data) and no agent is spawned"
finish
