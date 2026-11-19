#!/usr/bin/env bash
# Hermetic self-test for the capabilities MCP server (F3 item M; body B4, B6, AC4, AC6; design section 5 with rulings DC-04, DC-05).
# Every section runs in its own scratch root (bash capabilities-mcp-selftest.sh <section>); no argument runs them all.
# Sections -> checks: auth = T-MCP-AUTH | visibility = AC4-mcp | loadlog = AC6-load-log
# The server (bin/capabilities_mcp.py serve --port P, a free port) is spoken to as an MCP client does: JSON-RPC 2.0 over HTTP POST /mcp
# (initialize, notifications/initialized, then tools/list or tools/call), a run token as Bearer. Run tokens are minted with
# bin/run_token.py mint --run R --role ROLE --card C --link CONN/MODEL [--ttl S], as bin/model-proxy-selftest.sh mints them.
# A fake skill is added to the scratch registry as DATA, as bin/capabilities-selftest.sh adds it: three roles from the role table,
# one in allowed_roles, one in requestable_roles, one in neither.
# Written test-first (F3 wave 2): HTTP status, JSON-RPC shape, the code ranges STL-GRD-660..682 (C and M) and the trusted event
# log are asserted, never wording.
# ASSUMPTIONS (names the design leaves open):
#  A1 the server binds 127.0.0.1 (the loopback bind address in the data); a request with no, an unknown or an expired token is
#     answered HTTP 401 whatever its method or body.
#  A2 a tools/call answer carries the tool's JSON output as text content (result.content[].text, which may itself be JSON) or as
#     structuredContent; a refused call is a JSON-RPC error or a result with isError true, holding the catalog code.
#  A3 search output shows an entry as an object with id = the capability id and its visibility as a value "available" or
#     "requestable" (the requestable one with its approval class), as capabilities.py search --json does (capabilities-selftest A1).
#  A4 load writes one event line of type capability-load holding the card, run, role and capability id as values; request writes
#     a line of type approval-request naming the card (capabilities-selftest A3); both in the trusted event log.
#  A5 a token is minted on the first catalog provider link that has a model (the link does not matter to the MCP server).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=capabilities-mcp-selftest
SECTIONS="auth visibility loadlog"
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
C() { python3 -I "$R/bin/capabilities.py" "$@"; }
range='STL-GRD-6(6[0-9]|7[0-4])'
mapfile -t RL < <(jq -r '.roles | keys[]' "$RJ"); RA=${RL[0]}; RQ=${RL[1]}; RH=${RL[2]}   # allowed, requestable, hidden
ACLASS=$(jq -r '[.. | objects | select(has("approval_class")) | .approval_class.enum[]?] | map(select(. != "read"))[0] // empty' "$R/.stella/schemas/approval-request.schema.json")   # an approval class (the approval-request schema's enum), not the skill's own risk class
SRC=$(ix '[.capability_sources // empty | .. | strings]')
SK=$(jq -r '[.[] | select((endswith(".json") or startswith(".stella/extensions")) | not)][0] // ".claude/skills"' <<<"${SRC:-[]}")
MCPF=$(jq -r '[.[] | select(endswith(".mcp.json"))][0] // ".mcp.json"' <<<"${SRC:-[]}")
mkdir -p "$R/$SK/qa-fake-skill"
printf -- '---\nname: qa-fake-skill\ndescription: qazebra fake skill for the capabilities selftest\n---\nQA-SKILL-BODY use the zebra.\n' >"$R/$SK/qa-fake-skill/SKILL.md"
ed .stella/capabilities.json --arg s "$SK/qa-fake-skill/SKILL.md" --arg a "$RA" --arg q "$RQ" --arg c "$ACLASS" --arg g "$(uuid)" --arg i "$IID" \
  '.entries += [{id: "qa-fake-skill", kind: "skill", summary: "qazebra fake skill for the capabilities selftest", keywords: ["qazebra"], inputs: "none", outputs: "text",
    allowed_roles: [$a], requestable_roles: [$q], request_approval: $c, risk_class: "read", hosts: [], secrets: [], status: "approved", source: $s,
    triage: {result: "shipped"}, definition: {text: "QA-SKILL-DEF"}, global_id: $g, install_id: $i}]'
ok 'python3 -I "$R/bin/stella_data.py" check' "precondition: the scratch registry with the fake skill (requestable_roles, request_approval, definition) passes check"
# shown <tag> <id>: the object with that id in the JSON output, compact (empty when absent)
shown() { jq -c --arg id "$2" '[.. | objects | select(.id == $id)][0] // empty' "$T/o/$1.out" 2>/dev/null; }
vis() { local s; s=$(shown "$1" "$2"); [ -n "$s" ] && jq -e --arg v "$3" '[.. | strings] | index($v) != null' <<<"$s" >/dev/null; }


range='STL-GRD-6([67][0-9]|8[0-2])'
UEV=$R/$(ix .untrusted_events)
LINK=$(jq -r '[.entries[] | select(.kind == "provider" and ((.models // []) | length > 0))][0] | .id + "/" + .models[0].id' "$R/.stella/connections.json")
mint() { python3 -I "$R/bin/run_token.py" mint "$@" 2>>"$T/o/mint.err" | tr -d '\n'; }
MP=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I "$R/bin/capabilities_mcp.py" serve --port "$MP" >"$T/mcp.out" 2>"$T/mcp.err" &
for i in $(seq 50); do python3 -I -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2)' "$MP" 2>/dev/null && break; sleep 0.1; done
cat >"$T/mcp.py" <<'PYM'
import http.client, json, sys
# mcp.py <port> <token or ""> <method> <params json> [raw body]: initialize + initialized + the call in one session (with a token),
# or the raw body alone; prints {status, body, expanded}: expanded = the body with every string that holds JSON parsed in place
port, tok, method, params = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
raw = sys.argv[5] if len(sys.argv) > 5 else None
sid = None
def post(body):
    global sid
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if tok: h["Authorization"] = "Bearer " + tok
    if sid: h["Mcp-Session-Id"] = sid
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    c.request("POST", "/mcp", body=body.encode(), headers=h)
    r = c.getresponse(); txt = r.read().decode("utf-8", "replace")
    sid = r.getheader("Mcp-Session-Id") or sid
    if txt.lstrip().startswith(("event:", "data:")):   # a stream answer: its data lines
        txt = "\n".join(l[5:].strip() for l in txt.splitlines() if l.startswith("data:"))
    return r.status, txt
def expand(x):
    if isinstance(x, str):
        try:
            y = json.loads(x)
        except ValueError:
            return x
        return expand(y) if isinstance(y, (dict, list)) else x
    if isinstance(x, dict): return {k: expand(v) for k, v in x.items()}
    if isinstance(x, list): return [expand(v) for v in x]
    return x
if raw is not None or method == "-":
    st, txt = post(raw if raw is not None else "{}")
else:
    st, txt = post(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "qa", "version": "0"}}}))
    if st == 200:
        post(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}))
        st, txt = post(json.dumps({"jsonrpc": "2.0", "id": 2, "method": method, "params": json.loads(params)}))
try:
    body = json.loads(txt)
except ValueError:
    body = txt
print(json.dumps({"status": st, "body": body, "expanded": expand(body)}))
PYM
# call <tag> <token> <method> <params json> [raw body]: answer JSON in $T/o/<tag>.out
call() { run "$1" python3 -I "$T/mcp.py" "$MP" "$2" "$3" "$4" "${@:5}"; }
tool() { call "$1" "$2" tools/call "$(jq -nc --arg n "$3" --argjson a "$4" '{name: $n, arguments: $a}')"; }   # <tag> <token> <tool> <args json>
st() { jq -r .status "$T/o/$1.out" 2>/dev/null; }
refused() { [ "$(st "$1")" = 200 ] && jq -e '.body.error != null or .body.result.isError == true' "$T/o/$1.out" >/dev/null && grep -qE "$range" "$T/o/$1.out"; }
answered() { [ "$(st "$1")" = 200 ] && jq -e '.body.result != null and (.body.result.isError // false) == false' "$T/o/$1.out" >/dev/null; }
shown() { jq -c --arg id "$2" '[.expanded | .. | objects | select(.id == $id)][0] // empty' "$T/o/$1.out" 2>/dev/null; }
vis() { local s; s=$(shown "$1" "$2"); [ -n "$s" ] && jq -e --arg v "$3" '[.. | strings] | index($v) != null' <<<"$s" >/dev/null; }
newev() { tail -n +$(($1 + 1)) "$EV" 2>/dev/null | jq -c "select(.type == \"$2\")" 2>/dev/null; }   # <line count before> <type>
TA=$(mint --run qa-run-ma --role "$RA" --card qa-card-ma --link "$LINK")
TQ=$(mint --run qa-run-mq --role "$RQ" --card qa-card-mq --link "$LINK")
TH=$(mint --run qa-run-mh --role "$RH" --card qa-card-mh --link "$LINK")
ok '[ -n "$TA" ] && [ -n "$TQ" ] && [ -n "$TH" ] && [ -s "$T/mcp.err" -o -n "$MP" ] && python3 -I -c "import socket, sys; socket.create_connection((\"127.0.0.1\", int(sys.argv[1])), 1)" "$MP"' \
  "precondition: three run tokens minted (roles $RA, $RQ, $RH) and the MCP server listens on its free port"

case $S in
auth)   # T-MCP-AUTH: no, unknown or expired token -> 401, nothing read; the role comes from the token, a role argument is ignored
  e0=$(nl "$EV")
  call a1 "" tools/call '{"name":"search","arguments":{"query":"qazebra"}}' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"qazebra"}}}'
  ok '[ "$(st a1)" = 401 ] && ! grep -q qa-fake-skill "$T/o/a1.out"' "T-MCP-AUTH no token: tools/call answered 401, nothing returned"
  call a2 "" tools/list '{}' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
  ok '[ "$(st a2)" = 401 ]' "T-MCP-AUTH no token: tools/list answered 401"
  call a3 "" - '{}' '{this is not json'
  ok '[ "$(st a3)" = 401 ]' "T-MCP-AUTH no token and a body that is not JSON: 401 (auth before the body is read)"
  call a4 "${TA%????????}QAQAQAQA" - '{}' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"load","arguments":{"id":"qa-fake-skill"}}}'
  ok '[ "$(st a4)" = 401 ] && ! grep -q QA-SKILL "$T/o/a4.out"' "T-MCP-AUTH an unknown token: 401, nothing loaded"
  TX=$(mint --run qa-run-mx --role "$RA" --card qa-card-mx --link "$LINK" --ttl 1); sleep 2
  call a5 "$TX" - '{}' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"load","arguments":{"id":"qa-fake-skill"}}}'
  ok '[ -n "$TX" ] && [ "$(st a5)" = 401 ] && ! grep -q QA-SKILL "$T/o/a5.out"' "T-MCP-AUTH an expired token (ttl 1 s): 401, nothing loaded"
  ok '[ "$(st a1)" = 401 ] && [ -z "$(newev "$e0" capability-load)" ] && [ -z "$(newev "$e0" approval-request)" ]' "T-MCP-AUTH no refused request wrote a load or request line"
  tool r1 "$TH" search "{\"query\":\"qazebra\",\"role\":\"$RA\"}"
  ok 'answered r1 && ! grep -q qa-fake-skill "$T/o/r1.out"' "T-MCP-AUTH token of $RH with role $RA in the arguments: the hidden skill stays hidden"
  tool r2 "$TA" search "{\"query\":\"qazebra\",\"role\":\"$RH\"}"
  ok 'answered r2 && vis r2 qa-fake-skill available' "T-MCP-AUTH token of $RA with role $RH in the arguments: still available (the token's role)"
  e1=$(nl "$EV"); tool r3 "$TH" load "{\"id\":\"qa-fake-skill\",\"role\":\"$RA\"}"
  ok 'refused r3 && ! grep -q QA-SKILL "$T/o/r3.out" && [ -z "$(newev "$e1" capability-load)" ]' "T-MCP-AUTH load with a role argument by the hidden role's token: refused with a code, no load line"
  call l1 "$TA" tools/list '{}'
  ok '[ "$(st l1)" = 200 ] && jq -e "[.body.result.tools[].name] as \$n | all((\"search\", \"describe\", \"request\", \"load\"); . as \$t | \$n | index(\$t) != null)" "$T/o/l1.out"' "T-MCP-AUTH tools/list names search, describe, request, load"
  ok '[ "$(st l1)" = 200 ] && jq -e "[.body.result.tools[] | .inputSchema.properties // {} | has(\"role\")] | any | not" "$T/o/l1.out"' "T-MCP-AUTH no tool takes a role argument"
  ;;
visibility)   # AC4-mcp: available / requestable / hidden by the token's role; hidden == unknown
  tool v1 "$TA" search '{"query":"qazebra"}'
  ok 'answered v1 && vis v1 qa-fake-skill available' "AC4-mcp token of $RA (allowed_roles): search shows the fake skill as available"
  tool v2 "$TQ" search '{"query":"qazebra"}'
  ok 'answered v2 && vis v2 qa-fake-skill requestable && vis v2 qa-fake-skill "$ACLASS" && ! vis v2 qa-fake-skill available' "AC4-mcp token of $RQ (requestable_roles): requestable, with its approval class ($ACLASS)"
  tool v3 "$TH" search '{"query":"qazebra"}'
  ok 'answered v3 && ! grep -q qa-fake-skill "$T/o/v3.out"' "AC4-mcp token of $RH (neither): search does not show it"
  tool v4 "$TA" describe '{"id":"qa-fake-skill"}'
  ok 'answered v4 && grep -q qazebra "$T/o/v4.out"' "AC4-mcp describe returns the entry to the allowed role's token"
  tool v5 "$TH" describe '{"id":"qa-fake-skill"}'; tool v6 "$TH" describe '{"id":"qa-no-such-capability"}'
  ok 'refused v5 && refused v6 && [ "$(sed s/qa-fake-skill/ID/g "$T/o/v5.out")" = "$(sed s/qa-no-such-capability/ID/g "$T/o/v6.out")" ]' "AC4-mcp describe of the hidden id answers exactly like an unknown id (a code, the same answer)"
  ;;
loadlog)   # AC6-load-log: load -> one trusted capability-load line (card, run, role, capability); request -> an approval-request line
  e0=$(nl "$EV"); u0=$(nl "$UEV")
  tool d1 "$TA" load '{"id":"qa-fake-skill"}'
  ok 'answered d1 && grep -qE "QA-SKILL-(BODY|DEF)" "$T/o/d1.out"' "AC6-load-log load by the allowed role's token returns the skill's definition"
  L=$(newev "$e0" capability-load)
  ok '[ "$(grep -c . <<<"$L")" = 1 ] && jq -e "[.. | strings] as \$s | all((\"qa-card-ma\", \"qa-run-ma\", \"$RA\", \"qa-fake-skill\"); . as \$v | \$s | index(\$v) != null)" <<<"$L"' \
    "AC6-load-log exactly one capability-load line in the trusted event log, naming card, run, role and capability"
  ok 'answered d1 && ! tail -n +$((u0 + 1)) "$UEV" 2>/dev/null | grep >/dev/null capability-load' "AC6-load-log ... and none in the untrusted log"
  e1=$(nl "$EV"); tool q1 "$TQ" request '{"id":"qa-fake-skill","reason":"qa needs the zebra"}'
  ok 'answered q1 && newev "$e1" approval-request | grep >/dev/null qa-card-mq' "AC6-load-log request by the requestable role's token: an approval-request line naming the token's card"
  e2=$(nl "$EV"); tool q2 "$TH" request '{"id":"qa-fake-skill","reason":"never mine"}'
  ok 'refused q2 && [ -z "$(newev "$e2" approval-request)" ]' "AC6-load-log request by the hidden role's token: refused with a code, no approval line"
  ;;
esac
finish
