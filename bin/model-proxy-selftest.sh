#!/usr/bin/env bash
# Hermetic self-test for the run tokens and the model proxy (F3 item T; body B1 api; design section 2 with rulings DC-04).
# Every section runs in its own scratch root (bash model-proxy-selftest.sh <section>); no argument runs them all.
# Sections -> checks: key = T-PROXY-KEY | token = T-PROXY-TOKEN | ledger = T-PROXY-LEDGER
# Upstream: bin/mock_provider.py on a free port (its own scratch root); a fake api connection on it added as DATA; the real key is a
# canary in a folder credentials backend inside a protected state path (bin/credentials.py); a decoy listener catches any forward
# to a host that is not the connection's catalog host. Written test-first (F3 wave 1): exit codes, HTTP status and the code ranges
# STL-MDL-790..799 (T), STL-LIM-43x (budget gate) and STL-CFG-312 (worker) are asserted, never wording.
# ASSUMPTIONS (names the design leaves open):
#  A1 run_token.py mint --run R --role ROLE --card C --link CONN/MODEL [--ttl S] prints the token alone on stdout (design section 2);
#     revoke --run R; both exit non-zero with a code in a worker environment.
#  A2 model_proxy.py serve --port P listens on 127.0.0.1 (the loopback bind address the data names is 127.0.0.1 in a scratch root).
#  A3 a client calls the proxy on a protocol's own request path (protocols.json request.path, here prefixed by shape id for the mock)
#     and the proxy forwards that path unchanged to the connection's catalog host (connections.json hosts[]).
#  A4 a refusal answers an HTTP status >= 400 whose body holds the catalog code; an unknown/expired/revoked token or a cli-login
#     link's token is 401 (design section 2, DC-04).
#  A5 the proxy's usage record goes to the index usage_ledger with the usage schema keys (connection, model, role, card).
#  A6 a budget hard cap of scope card (budgets.json, as budget-selftest plants it) refuses the call before any upstream request.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=model-proxy-selftest
SECTIONS="key token ledger"
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

PX=$R/bin/model_proxy.py; RT=$R/bin/run_token.py
# ---- the mock upstream in its own root (its protocol paths stay unprefixed: it serves each shape under /<shape id>) ----
MR=$T/mockroot; mkdir -p "$MR"; cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$MR/"
STELLA_ROOT=$MR ESCALATE_SUP_DIR=$T/sup python3 -I "$R/bin/mock_provider.py" >"$T/mock.out" 2>"$T/mock.err" &
for i in $(seq 100); do [ -s "$T/mock.out" ] && break; sleep 0.1; done
PORT=$(jq -r '.port' "$T/mock.out" 2>/dev/null); CTL=$(jq -r '.control' "$T/mock.out" 2>/dev/null); LO=$(jq -r '.control | capture("//(?<h>[^:/]+):").h' "$T/mock.out" 2>/dev/null)
export NO_PROXY=$LO,127.0.0.1 no_proxy=$LO,127.0.0.1
cat >"$T/cli.py" <<'PYC'
import http.client, json, sys
# <host> <port> <method> <target> <headers json> <body>: one raw request (an absolute-form target and a Host header are sent as given)
h, p, m, tg, hd, b = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], json.loads(sys.argv[5]), sys.argv[6].encode()
c = http.client.HTTPConnection(h, p, timeout=20)
c.putrequest(m, tg, skip_host="Host" in hd, skip_accept_encoding=True)
for k, v in hd.items():
    c.putheader(k, v)
c.putheader("Content-Length", str(len(b))); c.endheaders(b)
r = c.getresponse()
print(json.dumps({"status": r.status, "headers": dict(r.getheaders()), "body": r.read().decode("utf-8", "replace")}))
PYC
get() { python3 -I "$T/cli.py" "$LO" "$PORT" GET "$1" '{}' ''; }
post_ctl() { python3 -I "$T/cli.py" "$LO" "$PORT" POST "/${CTL#*://*/}" '{"Content-Type": "application/json"}' "$1" >/dev/null; }   # the control URL's path: the mock matches the path only
calls() { get /_calls | jq -r '.body | fromjson | [.counts[]] | add // 0' 2>/dev/null || echo -1; }
# ---- the fake api connection on the mock, its key in a folder backend ----
SHAPE=$(jq -r '.entries[0].id' "$R/.stella/protocols.json"); HDR=$(jq -r '.entries[0].request.headers | keys[0]' "$R/.stella/protocols.json")
HTPL=$(jq -r --arg h "$HDR" '.entries[0].request.headers[$h]' "$R/.stella/protocols.json")
ed .stella/protocols.json '.entries |= map(.request.path = "/" + .id + .request.path)'
PPATH=$(jq -r '.entries[0].request.path' "$R/.stella/protocols.json")
KN=QA_PROXY_KEY; KEY="qacanary$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
CD=$(ix .backup_dir)/qa-keys; mkdir -p "$R/$CD"; chmod 700 "$R/$CD"; (umask 077; printf '%s' "$KEY" >"$R/$CD/$KN")
ed .stella/routing.json --arg p "$CD" '.credentials.backend = "qa-dir" | .credentials.backends["qa-dir"] = {kind: "dir", path: $p}'
TPL='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "cloud" and (.aggregator | not))][0]'
mdl() { echo "{\"id\":\"$1\",\"capabilities\":{\"tool_calling\":true,\"json_mode\":true,\"context_tokens\":100000,\"vision\":false,\"streaming\":true},\"probed_at\":null,\"probe_source\":\"advertised\",\"cost\":null,\"limits\":null}"; }
ed .stella/connections.json --arg s "$SHAPE" --argjson m "[$(mdl qa-m1),$(mdl qa-m2)]" --arg g "$(uuid)" --arg h "$LO" --argjson p "${PORT:-9}" --arg k "$KN" \
  ".entries += [$TPL + {id: \"qa-api\", label: \"qa-api\", enabled: true, global_id: \$g, models: \$m, secrets: [\$k], protocol: \$s, hosts: [{host: \$h, port: \$p, purpose: \"selftest mock\"}]}]"
post_ctl "$(jq -nc --arg s "$SHAPE" '{models: {($s): ["qa-m1", "qa-m2"]}, faults: []}')"
CLI=$(jq -r '.entries[] | select(.type == "cli-login") | .id' "$R/.stella/connections.json" | head -n1)
CM=$(jq -r --arg c "$CLI" '.entries[] | select(.id == $c) | .models[0].id' "$R/.stella/connections.json")
# ---- a decoy listener: any request it gets went to a host outside the catalog ----
cat >"$T/decoy.py" <<'PYD'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def any(self):
        open(sys.argv[1], "a").write(self.command + " " + self.path + "\n"); self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    do_GET = do_POST = do_CONNECT = any
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H); print(s.server_address[1], flush=True); s.serve_forever()
PYD
: >"$T/decoy.log"; python3 -I "$T/decoy.py" "$T/decoy.log" >"$T/decoy.port" &
for i in $(seq 50); do [ -s "$T/decoy.port" ] && break; sleep 0.1; done; DP=$(head -n1 "$T/decoy.port")
# ---- the proxy on a free port ----
PP=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I "$PX" serve --port "$PP" >"$T/proxy.out" 2>"$T/proxy.err" &
for i in $(seq 50); do python3 -I -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2)' "$PP" 2>/dev/null && break; sleep 0.1; done
mint() { python3 -I "$RT" mint "$@" 2>>"$T/o/mint.err" | tr -d '\n'; }   # prints the token
# call <tag> <token or empty> [model] [extra headers json] [target] [host header]: one request to the proxy; result JSON in $T/o/<tag>.json
call() {
  local hd x=${4:-}; [ -n "$x" ] || x='{}'
  hd=$(jq -nc --arg h "$HDR" --arg v "${2:+${HTPL/\{key\}/$2}}" --argjson x "$x" '{"Content-Type": "application/json"} + (if $v == "" then {} else {($h): $v} end) + $x')
  [ -n "${6:-}" ] && hd=$(jq -c --arg v "$6" '. + {Host: $v}' <<<"$hd")
  python3 -I "$T/cli.py" 127.0.0.1 "$PP" POST "${5:-$PPATH}" "$hd" "$(jq -nc --arg m "${3:-qa-m2}" '{model: $m, messages: [{role: "user", content: "say ok"}], max_tokens: 5}')" >"$T/o/$1.json" 2>"$T/o/$1.err"
  cp "$T/o/$1.json" "$T/o/last" 2>/dev/null
}
st() { jq -r .status "$T/o/$1.json" 2>/dev/null; }
refused() { local s; s=$(st "$1"); [ -n "$s" ] && [ "$s" != null ] && [ "$s" -ge 400 ] && grep -qE "$2" "$T/o/$1.json"; }
last_up() { get /_calls | jq -c '.body | fromjson | .requests[-1] | .body |= (if type == "string" then (fromjson? // .) else . end)'; }   # the last request the mock got: {shape, model, headers, body}
nolog() { ! grep -rqF --exclude-dir=qa-keys -- "$1" "$R/.supervisor" "$T/sup" "$T/proxy.out" "$T/proxy.err" "$HOME" 2>/dev/null; }
ok '[ -n "$PORT" ] && [ -n "$DP" ] && python3 -I "$R/bin/stella_data.py" check' "precondition: the mock and the decoy run, the scratch data (fake connection, folder key backend) passes check"
TOK=$(mint --run qa-run-1 --role builder --card qa-card-1 --link qa-api/qa-m1)

case $S in
key)   # T-PROXY-KEY: the key never in a response, log or error; client auth stripped; only the catalog host
  ok '[ -n "$TOK" ] && [ "$TOK" != "$KEY" ]' "T-PROXY-KEY a run token is minted for the api link (and it is not the key)"
  c0=$(calls); call k1 "$TOK" qa-m1 '{"x-api-key": "QAJUNK-client", "api-key": "QAJUNK-client2"}'
  ok '[ "$(st k1)" = 200 ] && [ "$(calls)" = $((c0 + 1)) ]' "T-PROXY-KEY a call with a valid token is forwarded once and answered 200"
  UP=$(last_up)
  ok 'jq -e --arg h "$HDR" --arg v "${HTPL/\{key\}/$KEY}" "[.headers | to_entries[] | select((.key | ascii_downcase) == (\$h | ascii_downcase)) | .value] == [\$v]" <<<"$UP"' \
    "T-PROXY-KEY upstream got the real key in the protocol's own header template, once"
  ok '! grep -qF -- "$TOK" <<<"$UP" && ! grep -qF QAJUNK <<<"$UP"' "T-PROXY-KEY every client auth header is stripped (the run token and other key headers never reach upstream)"
  ok '[ -n "$(st k1)" ] && ! grep -qF -- "$KEY" "$T/o/k1.json"' "T-PROXY-KEY the key is in no response body or header"
  post_ctl "$(jq -nc --arg s "$SHAPE" '{models: {($s): ["qa-m1", "qa-m2"]}, faults: [{shape: $s, model: "qa-m1", fault: "server_error", calls: 1}, {shape: $s, model: "qa-m1", fault: "non_json", calls: 1}]}')"
  call k2 "$TOK" qa-m1; call k3 "$TOK" qa-m1
  ok '[ -n "$(st k2)" ] && [ -n "$(st k3)" ] && [ "$(st k2)" != 200 ] && ! grep -qF -- "$KEY" "$T/o/k2.json" "$T/o/k3.json"' "T-PROXY-KEY an upstream error and a non-JSON answer: the key is in no error the client sees"
  post_ctl "$(jq -nc --arg s "$SHAPE" '{models: {($s): ["qa-m1", "qa-m2"]}, faults: []}')"
  c0=$(calls); call k4 "$TOK" qa-m1 '{}' "http://127.0.0.1:$DP$PPATH"
  call k5 "$TOK" qa-m1 '{}' "$PPATH" "127.0.0.1:$DP"
  ok '[ -n "$(st k4)" ] && [ -n "$(st k5)" ] && [ ! -s "$T/decoy.log" ]' "T-PROXY-KEY an absolute-form target or a Host header naming another host never reaches it (only the catalog host)"
  call k6 "$TOK" qa-m1 '{}' "/$SHAPE/v1/qa-not-a-protocol-path"
  ok '[ "$(st k6)" -ge 400 ] && [ "$(calls)" -le $((c0 + 2)) ] && ! grep -q qa-not-a-protocol-path <<<"$(get /_calls)"' "T-PROXY-KEY a path that is not one of the protocol's paths is refused, never forwarded"
  ok 'nolog "$KEY"' "T-PROXY-KEY the key is in no log, state file, event line or proxy output"
  # builder case (item T): the stream masker, a key split at every byte between two chunks of an answer
  ok 'python3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); import model_proxy as mp; k = sys.argv[2]; s = (\"a \" + k + \" b \" + k + \"x\" + k[:5]).encode()
for c in range(1, len(s)):
    m = mp.Masker([k]); o = m.feed(s[:c]) + m.feed(s[c:]) + m.feed(b\"\", True); assert o == s.replace(k.encode(), b\"***\"), c" "$R/bin" "$KEY"' "T-PROXY-KEY the key is masked in a streamed answer also when it is split across two chunks"
  ;;
token)   # T-PROXY-TOKEN: unknown, expired, revoked and cli-login tokens refused with a code; the model pinned to the run's
  ok '[ ${#TOK} -ge 43 ]' "T-PROXY-TOKEN the token holds at least 32 random bytes (urlsafe: 43 characters or more)"
  ok 'nolog "$TOK"' "T-PROXY-TOKEN the token value is stored nowhere (state holds its hash only), logged nowhere"
  c0=$(calls); e0=$(nl "$EV")
  call t0 ""; ok 'refused t0 "STL-MDL-79[0-9]" && [ "$(st t0)" = 401 ]' "T-PROXY-TOKEN no token: 401 with STL-MDL-79x"
  call t1 "${TOK%????????}QAQAQAQA"; ok 'refused t1 "STL-MDL-79[0-9]" && [ "$(st t1)" = 401 ]' "T-PROXY-TOKEN an unknown token: 401 with STL-MDL-79x"
  TE=$(mint --run qa-run-exp --role builder --card qa-card-1 --link qa-api/qa-m1 --ttl 1); sleep 2
  call t2 "$TE"; ok '[ -n "$TE" ] && refused t2 "STL-MDL-79[0-9]" && [ "$(st t2)" = 401 ]' "T-PROXY-TOKEN an expired token (ttl 1 s): 401 with STL-MDL-79x"
  TR=$(mint --run qa-run-rev --role builder --card qa-card-1 --link qa-api/qa-m1)
  call t3a "$TR"; run rv python3 -I "$RT" revoke --run qa-run-rev; call t3 "$TR"
  ok '[ "$(st t3a)" = 200 ] && [ $RC = 0 ] && refused t3 "STL-MDL-79[0-9]" && [ "$(st t3)" = 401 ]' "T-PROXY-TOKEN a revoked token: works before revoke, 401 with STL-MDL-79x after"
  TC=$(mint --run qa-run-cli --role builder --card qa-card-1 --link "$CLI/$CM")
  call t4 "$TC"; ok '[ -n "$TC" ] && refused t4 "STL-MDL-79[0-9]"' "T-PROXY-TOKEN a token minted for a cli-login run (DC-04) is refused by the proxy with STL-MDL-79x"
  ok '[ "$(calls)" = $((c0 + 1)) ]' "T-PROXY-TOKEN no refused call reached upstream (only the one call before revoke)"
  ok '[ "$(nl "$EV")" -gt "$e0" ] && ! grep -qF -- "$TOK" "$EV" && ! grep -qF -- "$TE" "$EV"' "T-PROXY-TOKEN refusals write event lines, none holding a token value"
  call t5 "$TOK" qa-m2; ok '[ "$(st t5)" = 200 ] && [ "$(last_up | jq -r .model)" = qa-m1 ] && [ "$(last_up | jq -r .body.model)" = qa-m1 ]' "T-PROXY-TOKEN the client asks for qa-m2: upstream gets the run's model qa-m1"
  T2=$(mint --run qa-run-2 --role builder --card qa-card-1 --link qa-api/qa-m2)
  call t6 "$T2" qa-m1; ok '[ "$(st t6)" = 200 ] && [ "$(last_up | jq -r .model)" = qa-m2 ]' "T-PROXY-TOKEN another run's token is pinned to its own model (qa-m2), whatever the client asks"
  run w1 WORKER python3 -I "$RT" mint --run qa-run-w --role builder --card qa-card-1 --link qa-api/qa-m1
  ok '[ $RC != 0 ] && out w1 | grep >/dev/null STL-CFG-312 && ! grep -qE "[A-Za-z0-9_-]{43}" "$T/o/w1.out"' "T-PROXY-TOKEN mint refuses in a worker environment (STL-CFG-312), prints no token"
  ;;
ledger)   # T-PROXY-LEDGER: each call writes a ledger record and respects the budget gate
  UL=$R/$(ix .usage_ledger); u0=$(nl "$UL"); e0=$(nl "$EV")
  call l1 "$TOK" qa-m2
  ok '[ "$(st l1)" = 200 ] && [ "$(nl "$UL")" = $((u0 + 1)) ]' "T-PROXY-LEDGER one call: one usage ledger record"
  ok 'tail -n1 "$UL" | jq -e ".connection == \"qa-api\" and .model == \"qa-m1\" and .role == \"builder\" and .card == \"qa-card-1\" and (.tokens.input > 0)"' "T-PROXY-LEDGER the record names the connection, the pinned model, role and card, with the upstream's token counts"
  ok '[ "$(nl "$EV")" -gt "$e0" ] && tail -n +$((e0 + 1)) "$EV" | grep >/dev/null qa-run-1 && ! grep -qF -- "$TOK" "$EV" && ! grep -qF -- "$KEY" "$EV"' "T-PROXY-LEDGER the call wrote an event line naming the run (no token, no key)"
  u1=$(nl "$UL"); call l2 "${TOK%????????}QAQAQAQA"
  ok 'refused l2 "STL-MDL-79[0-9]" && [ "$(nl "$UL")" = "$u1" ]' "T-PROXY-LEDGER a refused token writes no usage record"
  ed .stella/budgets.json --arg g "$(uuid)" --arg i "$IID" '.budgets += [{id: "qa-card-cap", scope: "card", key: "qa-card-capped", window_days: 1, soft_percent: [], hard: {amount: 10, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "raise", raise_percent: 50, connection: null, model: null}, global_id: $g, install_id: $i}]'
  jq -nc --arg i "$IID" --arg id "$(uuid)" --arg ts "$(date -u +%FT%TZ)" '{v: 1, id: $id, install_id: $i, ts: $ts, connection: "qa-api", model: "qa-m1", role: "builder", project: "qa-p", card: "qa-card-capped", session: "s-qa", kind: "call", outcome: "ok", status: null,
    tokens: {input: 100, output: 10, cache_write: 0, cache_read: 0, reasoning: 0}, latency_ms: 5, batch: false, cost: {amount: 50, currency: "QAC", entry: "qa", priced: true}, plan_share: null}' >>"$UL"
  TB=$(mint --run qa-run-cap --role builder --card qa-card-capped --link qa-api/qa-m1)
  c0=$(calls); call l3 "$TB"
  ok '[ -n "$TB" ] && refused l3 "STL-(LIM-43[0-9]|MDL-79[0-9])" && [ "$(calls)" = "$c0" ]' "T-PROXY-LEDGER a card over its hard budget cap: the call is refused with a code before any upstream request"
  ;;
esac
finish
