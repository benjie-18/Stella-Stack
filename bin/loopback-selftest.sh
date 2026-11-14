#!/usr/bin/env bash
# Hermetic self-test for the loopback API contract (F1c W5, body B5/A5, design D6 incl. DG-4): .stella/loopback-api.json, the
# guard bin/loopback_guard.py (library check() and CLI) and its test double bin/loopback-api-double.py, over real HTTP on
# 127.0.0.1 and a free port (--port 0; curl --noproxy, no other network). Scratch root (STELLA_ROOT: a copy of bin/, .stella/
# and docs/; own HOME, TMPDIR, alert log, owner key and store; stub `hermes` boards on PATH); never the live tree, key or store.
# Codes: 850 Host, 851 foreign Origin (any method, DG-4), 852 no Origin on a state-changing request, 853 CSRF, 854 API token,
# 855 owner-write without an owner proof, 856 owner proof refused (cause = the owner_auth code), 857 unknown endpoint.
# W5's own cases (a repeated header, an unlisted method, an unusable contract or session), then the F1c tester's wave-3 T5a
# cases, unchanged.
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TREE=$H
# ---- harness (the tester's qa/wave1/lib.sh, the parts T5a uses) ----
T=$(mktemp -d "${TMPDIR:-/tmp}/loopback-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
R=$T/root; mkdir -p "$R/docs/hermes-local" "$R/.supervisor/logs" "$R/.supervisor/state" "$T/home" "$T/tmp" "$T/sup/logs" "$T/sup/state"
cp -r "$H/bin" "$H/.stella" "$R/"
(cd "$H/docs" && tar --exclude=./hermes-local/roles.json -cf - .) | (cd "$R/docs" && tar xf -)
jq '.worker_markers = ["STUB_WORKER_MARK"]' "$H/docs/hermes-local/roles.json" >"$R/docs/hermes-local/roles.json"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup ROLES_FILE=$R/docs/hermes-local/roles.json OWNER_CONFIG=$T/owner-fake.env
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT
IDX=$R/.stella/data-files.json
ix() { jq -r "$1" "$IDX"; }
POL=$R/$(ix '.files[] | select(.id == "owner-auth") | .path')
for v in $(jq -r '.worker_signals.token_env[]?' "$POL" 2>/dev/null); do unset "$v"; done
PY="python3 -I"; B=$R/bin
mkdir -p "$T/pb-ok"; printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb-ok/hermes"; chmod +x "$T/pb-ok/hermes"
BASEPATH=$PATH; export PATH=$T/pb-ok:$BASEPATH
cd "$T" || exit 1
fails=0; n=0
ok() { n=$((n+1)); if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); cat "$T/o" "$T/ve" 2>/dev/null | sed 's/^/     | /' | tail -n 3; fi; rm -f "$T/o" "$T/ve"; }
finish() { echo "# loopback-selftest: $n cases, $fails failed"; [ "$fails" = 0 ] && echo "selftest PASS" || echo "selftest FAIL"; [ "$fails" = 0 ]; exit $?; }
has() { [ -f "$B/$1" ] || { echo "     (precondition: bin/$1 does not exist in TREE)"; return 1; }; }
# ---- W5's own cases (beyond T5a): a repeated header, an unlisted method over HTTP, an unusable contract or session ----
LC0=$R/.stella/loopback-api.json
$PY -c '
import json, sys
sys.path.insert(0, sys.argv[1]); import loopback_guard as g
d = json.load(open(sys.argv[2])); tk = d["token_header"]; s = {"api_token": "t1", "csrf_token": "c1", "port": 54321}
rp = next(e["path"] for e in d["endpoints"] if e["method"] == "GET" and e["scope"] == "read")
base = [("Host", "127.0.0.1:54321"), (tk, "t1")]
o = d["origins"][0].replace("{port}", "54321")
r = [g.check("GET", rp, base, b"", s), g.check("GET", rp, base + [("Origin", o), ("origin", o)], b"", s),
     g.check("GET", rp, base + [("HOST", "127.0.0.1:54321")], b"", s), g.check("GET", rp, base + [(tk.upper(), "t1")], b"", s),
     g.check("GET", rp, base, b"", {"api_token": "t1", "port": 54321}), g.check("GET", rp, base, b"", dict(s, port="54321"))]
print(json.dumps([list(x) for x in r]))' "$R/bin" "$LC0" >"$T/o" 2>&1
ok '[ "$(jq -c . "$T/o" 2>/dev/null)" = "[[true,null],[false,\"STL-OWN-851\"],[false,\"STL-OWN-850\"],[false,\"STL-OWN-854\"],[false,\"STL-OWN-858\"],[false,\"STL-OWN-858\"]]" ]' \
  "W5: a header sent twice matches nothing (Origin 851, Host 850, token 854, names in any case); a session without its CSRF token or with a text port refuses everything (858)"
printf '{"api_token":"t1","csrf_token":"c1"}' >"$T/s0.json"
$PY "$R/bin/loopback-api-double.py" --port 0 --session "$T/s0.json" >"$T/d0.out" 2>"$T/d0.err" & D0=$!
for _ in $(seq 50); do P0=$(head -n 1 "$T/d0.out" 2>/dev/null); [[ $P0 =~ ^[0-9]+$ ]] && break; P0=; sleep 0.2; done
curl -sS --noproxy '*' --max-time 10 -X PROPFIND -o "$T/o" -w '%{http_code}' -H "Host: 127.0.0.1:${P0:-1}" "http://127.0.0.1:${P0:-1}/" >"$T/st0" 2>"$T/ve"
ok '[ "$(cat "$T/st0")" = 404 ] && jq -e ".ok == false and .code == \"STL-OWN-857\"" "$T/o" >/dev/null' "W5: a method the server has no handler for (PROPFIND) reaches the guard: 404 STL-OWN-857, never a 501"
kill "$D0" 2>/dev/null; wait "$D0" 2>/dev/null
cp "$LC0" "$T/lc0.keep"; jq '.endpoints += [.endpoints[0] | .id = "zz-dup"]' "$T/lc0.keep" >"$LC0"
$PY "$R/bin/loopback-api-double.py" --port 0 --session "$T/s0.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-OWN-858 "$T/o"' "W5: a contract with one method + path twice is refused at start (858; a read and an owner-write row could disagree)"
jq '.token_header = .csrf_header' "$T/lc0.keep" >"$LC0"
jq -n --arg p "$(jq -r '.endpoints[0].path' "$T/lc0.keep")" '{method: "GET", path: $p, headers: {Host: "127.0.0.1:54321"}, body: "", session: {api_token: "t1", csrf_token: "c1", port: 54321}}' >"$T/rq0.json"
$PY "$R/bin/loopback_guard.py" check "$T/rq0.json" >"$T/o" 2>"$T/ve"; rc=$?
ok '[ $rc = 1 ] && jq -e ".ok == false and .code == \"STL-OWN-858\"" "$T/o" >/dev/null' "W5: a contract whose token and CSRF headers share a name refuses every request (858)"
cp "$T/lc0.keep" "$LC0"
# ---- T5a (qa/wave3/T5a.sh from its line 11, unchanged) ----
DPID=
stopd() { if [ -n "$DPID" ]; then kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=; fi; }
trap 'stopd; chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
OA="$PY $B/owner_auth.py"
IID=$(jq -r .install_id "$R/$(ix '.files[] | select(.id == "install") | .path')")
uuid() { python3 -I -c 'import uuid; print(uuid.uuid4())'; }
rnd() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
LREL=$(ix '.files[] | select(.id == "loopback-api") | .path'); [ -n "$LREL" ] && [ "$LREL" != null ] || LREL=.stella/loopback-api.json
LC=$R/$LREL
cj() { jq -r "$1 // empty" "$LC" 2>/dev/null; }
# header names from the contract (data); placeholders when the contract is missing so every later case still runs and fails
CSRFH=$(cj .csrf_header); CSRFH=${CSRFH:-X-zz-no-csrf-header}
TOKH=$(cj .token_header); TOKH=${TOKH:-X-zz-no-token-header}
PRH=$(cj .proof_header); PRH=${PRH:-X-zz-no-proof-header}
RPATH=$(cj '[.endpoints[]? | select(.method == "GET" and .scope == "read") | .path][0]'); RPATH=${RPATH:-/zz-no-read-endpoint}
WM=$(cj '[.endpoints[]? | select(.scope == "owner-write" and (.method | IN("POST", "PUT", "PATCH", "DELETE")))][0].method'); WM=${WM:-POST}
WPATH=$(cj '[.endpoints[]? | select(.scope == "owner-write" and (.method | IN("POST", "PUT", "PATCH", "DELETE")))][0].path'); WPATH=${WPATH:-/zz-no-write-endpoint}
TOK=$(rnd); CSRF=$(rnd)
jq -n --arg a "$TOK" --arg c "$CSRF" '{api_token: $a, csrf_token: $c}' >"$T/session.json"

# ---- data: the contract row, its shape, its codes ----
ok 'has loopback_guard.py' "precondition: bin/loopback_guard.py exists"
ok 'has loopback-api-double.py' "precondition: bin/loopback-api-double.py exists"
ok 'jq -e ".files[] | select(.id == \"loopback-api\") | .owner_only == true and .path == \".stella/loopback-api.json\" and .list_key == \"endpoints\" and .id_field == \"id\"" "$IDX" >/dev/null' \
  "index row loopback-api: path .stella/loopback-api.json, owner_only true, list_key endpoints, id_field id"
ok 'jq -e "(.endpoints | type == \"array\" and length > 0 and all(.[]; (.id | type == \"string\") and (.method | type == \"string\") and (.path | startswith(\"/\")) and (.scope | IN(\"read\", \"owner-write\")) and (.global_id | type == \"string\") and (.install_id | type == \"string\")))
  and ([.csrf_header, .token_header, .proof_header] | all(type == \"string\" and length > 0) and (map(ascii_downcase) | unique | length == 3))
  and (.port_source | type == \"string\" and length > 0)" "$LC" >/dev/null' \
  "contract shape: endpoints {id, method, path, scope read|owner-write, global_id, install_id}; csrf_header, token_header, proof_header (three distinct names); port_source"
ok 'jq -e "(.hosts | type == \"array\" and length > 0 and all(.[]; IN(\"127.0.0.1\", \"localhost\", \"::1\", \"[::1]\")) and any(.[]; . == \"127.0.0.1\"))
  and (.origins | type == \"array\" and length > 0 and all(.[]; type == \"string\" and . != \"*\" and . != \"null\" and (contains(\"*\") | not)))" "$LC" >/dev/null' \
  "contract: allowed hosts are loopback names only (127.0.0.1 among them); allowed origins listed, none is * or null"
ok '[ "$RPATH" != /zz-no-read-endpoint ] && [ "$WPATH" != /zz-no-write-endpoint ]' "contract ships a read GET endpoint ($RPATH) and an owner-write endpoint with a state-changing method ($WM $WPATH)"
$PY "$B/stella_data.py" check loopback-api >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ]' "stella_data.py check loopback-api: the shipped contract validates (exit 0)"
ok 'jq -e "[.alerts[].code] as \$c | all(range(850; 858); (\"STL-OWN-\(.)\") as \$x | \$c | any(.[]; . == \$x))" "$R/docs/hermes-local/alert-catalog.json" >/dev/null' \
  "alert catalog holds STL-OWN-850..857"
ok '[ -f "$R/docs/contract/loopback-api.md" ] && for i in 0 1 2 3 4 5 6 7; do grep -q "STL-OWN-85$i" "$R/docs/contract/loopback-api.md" || exit 1; done' \
  "docs/contract/loopback-api.md exists and names STL-OWN-850..857"

# ---- the double: --port 0, prints its port, listens on 127.0.0.1 only ----
P=
startd() {
  stopd; : >"$T/dbl.out"; P=
  if [ -f "$B/loopback-api-double.py" ]; then
    $PY "$B/loopback-api-double.py" --port 0 --session "$T/session.json" >"$T/dbl.out" 2>>"$T/dbl.err" & DPID=$!
    for _ in $(seq 50); do P=$(head -n 1 "$T/dbl.out" 2>/dev/null | tr -d '\r '); [[ $P =~ ^[0-9]+$ ]] && [ "$P" -gt 0 ] && break; P=; sleep 0.2; done
  fi
  [ -n "$P" ]
}
startd; rc=$?
ok '[ $rc = 0 ]' "loopback-api-double.py --port 0 --session F: prints its port on the first stdout line within 10 s (got ${P:-none})"
GOODP=${P:-1}; P=$GOODP   # port 1: nothing listens, every request below fails (negative control)
PH=$(printf '%04X' "$P"); OTHERP=$(( P == 65535 ? 65534 : P + 1 ))
ok '[ "$(awk -v p=":$PH" "\$4 == \"0A\" && \$2 ~ p\"\$\"" /proc/net/tcp /proc/net/tcp6 | wc -l)" = 1 ] && awk -v p=":$PH" "\$4 == \"0A\" && \$2 ~ p\"\$\"" /proc/net/tcp | grep -q " 0100007F:$PH "' \
  "the double listens on 127.0.0.1:$P only (no 0.0.0.0, no IPv6 wildcard)"
ORIG=$(cj '.origins[0]'); ORIG=${ORIG//\{port\}/$P}; ORIG=${ORIG:-http://127.0.0.1:$P}

# ---- request helpers (status in $T/st, body in $T/o, headers in $T/hd; every body also in $T/bodies) ----
rq() { local m=$1 p=$2; shift 2
  curl -sS --noproxy '*' --max-time 10 --path-as-is -X "$m" -o "$T/o" -D "$T/hd" -w '%{http_code}' "$@" "http://127.0.0.1:$P$p" >"$T/st" 2>"$T/ve"
  { cat "$T/o"; echo; } >>"$T/bodies" 2>/dev/null; }
passed() { [ "$(cat "$T/st")" = 200 ] && jq -e '.ok == true' "$T/o" >/dev/null 2>&1; }
refused() { [[ $(cat "$T/st") =~ ^4[0-9][0-9]$ ]] && jq -e --arg c "$1" '.ok == false and .code == $c' "$T/o" >/dev/null 2>&1; }
refused_any() { [[ $(cat "$T/st") =~ ^4[0-9][0-9]$ ]] && jq -e '.ok == false and (.code | test("^STL-OWN-85[0-7]$"))' "$T/o" >/dev/null 2>&1; }
cause() { [ "$(jq -r '.cause // empty' "$T/o" 2>/dev/null)" = "$1" ]; }
# body <name> <json>: a body file; mkproof <method> <path> <body file> <out>: an owner_write proof over the http action
body() { printf '%s' "$2" >"$T/body-$1"; echo "$T/body-$1"; }
mkproof() {
  jq -n --arg t "$1 $2" --arg z "$(printf '0%.0s' $(seq 64))" --arg d "$(sha256sum <"$3" | cut -c1-64)" \
    '{op: "http", target: $t, old_digest: $z, new_digest: $d}' >"$4.act"
  $OA prove --class owner_write --action "$4.act" 2>>"$T/prove.err" | jq -c . >"$4" 2>/dev/null; }
RH=(-H "$TOKH: $TOK")
WH=(-H "$TOKH: $TOK" -H "Origin: $ORIG" -H "$CSRFH: $CSRF" -H "Content-Type: application/json")

# ---- read scope ----
rq GET "$RPATH" "${RH[@]}"; ok 'passed' "read GET $RPATH: good Host, API token, no Origin -> 200 ok"
rq GET "$RPATH" "${RH[@]}" -H "Origin: $ORIG"; ok 'passed && ! grep -qi "^access-control-allow-origin: *\*" "$T/hd"' "read GET with the allowed Origin ($ORIG) -> 200 ok, and no Access-Control-Allow-Origin: *"
rq GET "$RPATH"; ok 'refused STL-OWN-854' "read GET without the API token -> STL-OWN-854"
rq GET "$RPATH" -H "$TOKH: $(rnd)"; ok 'refused STL-OWN-854' "read GET with a wrong API token -> STL-OWN-854"
rq GET "$RPATH" "${RH[@]}" -H "Origin: http://attacker.example"; ok 'refused STL-OWN-851' "read GET with a foreign Origin (http://attacker.example) -> STL-OWN-851 (DG-4: Origin on every request)"
rq GET "$RPATH" "${RH[@]}" -H "Origin: null"; ok 'refused STL-OWN-851' "read GET with Origin: null -> STL-OWN-851"
rq GET "$RPATH" "${RH[@]}" -H "Origin: http://127.0.0.1:$OTHERP"; ok 'refused STL-OWN-851' "read GET with Origin http://127.0.0.1:<another port> -> STL-OWN-851"
rq GET "$RPATH" "${RH[@]}" -H "Host: attacker.example:$P"; ok 'refused STL-OWN-850' "read GET with a rebinding Host (attacker.example:$P) -> STL-OWN-850"
rq GET "$RPATH" "${RH[@]}" -H "Host: 127.0.0.1:$OTHERP"; ok 'refused STL-OWN-850' "read GET with Host 127.0.0.1:<another port> -> STL-OWN-850"
rq GET "$RPATH" "${RH[@]}" -H "Host: 127.0.0.1"; ok 'refused STL-OWN-850' "read GET with Host 127.0.0.1 and no port -> STL-OWN-850"
rq GET "$RPATH" "${RH[@]}" -H "Host:"; ok 'refused STL-OWN-850' "read GET with no Host header -> STL-OWN-850"

# ---- owner-write scope: refusals first (none may spend the proof), then the good request once, then its replay ----
$OA init-key >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ]' "owner key created on the scratch host (owner_auth.py init-key), for the owner proofs below"
BW=$(body w1 '{"zz":"one"}'); mkproof "$WM" "$WPATH" "$BW" "$T/p1"; PR1=$(cat "$T/p1" 2>/dev/null)
ok 'jq -e ".nonce and .digest" "$T/p1" >/dev/null' "owner proof made on the host (owner_auth.py prove --class owner_write) for $WM $WPATH"
rq "$WM" "$WPATH" -H "$TOKH: $TOK" --data-binary "@$BW"
ok 'refused_any' "A5: owner-write with only the API token (no Origin, CSRF or proof) -> refused, a W5 code (got $(jq -r .code "$T/o" 2>/dev/null))"
rq "$WM" "$WPATH" "${WH[@]}" --data-binary "@$BW"; ok 'refused STL-OWN-855' "owner-write with API token + allowed Origin + CSRF and no owner proof -> STL-OWN-855 (the token is never enough)"
rq "$WM" "$WPATH" "${WH[@]}" -H "Host: attacker.example:$P" -H "$PRH: $PR1" --data-binary "@$BW"; ok 'refused STL-OWN-850' "owner-write, all valid but Host attacker.example:$P -> STL-OWN-850"
rq "$WM" "$WPATH" "${WH[@]}" -H "Host: 127.0.0.1:$OTHERP" -H "$PRH: $PR1" --data-binary "@$BW"; ok 'refused STL-OWN-850' "owner-write, all valid but Host 127.0.0.1:<another port> -> STL-OWN-850"
rq "$WM" "$WPATH" -H "$TOKH: $TOK" -H "Origin: http://attacker.example" -H "$CSRFH: $CSRF" -H "$PRH: $PR1" --data-binary "@$BW"; ok 'refused STL-OWN-851' "owner-write, all valid but a foreign Origin -> STL-OWN-851"
rq "$WM" "$WPATH" -H "$TOKH: $TOK" -H "Origin: null" -H "$CSRFH: $CSRF" -H "$PRH: $PR1" --data-binary "@$BW"; ok 'refused STL-OWN-851' "owner-write, all valid but Origin: null -> STL-OWN-851"
rq "$WM" "$WPATH" -H "$TOKH: $TOK" -H "$CSRFH: $CSRF" -H "$PRH: $PR1" --data-binary "@$BW"; ok 'refused STL-OWN-852' "owner-write, all valid but no Origin -> STL-OWN-852"
rq "$WM" "$WPATH" -H "$TOKH: $TOK" -H "Origin: $ORIG" -H "$PRH: $PR1" --data-binary "@$BW"; ok 'refused STL-OWN-853' "owner-write, all valid but no CSRF token -> STL-OWN-853"
rq "$WM" "$WPATH" -H "$TOKH: $TOK" -H "Origin: $ORIG" -H "$CSRFH: $(rnd)" -H "$PRH: $PR1" --data-binary "@$BW"; ok 'refused STL-OWN-853' "owner-write, all valid but a wrong CSRF token -> STL-OWN-853"
rq "$WM" "$WPATH" -H "$TOKH: $(rnd)" -H "Origin: $ORIG" -H "$CSRFH: $CSRF" -H "$PRH: $PR1" --data-binary "@$BW"; ok 'refused STL-OWN-854' "owner-write, all valid but a wrong API token -> STL-OWN-854"
rq "$WM" "$WPATH" "${WH[@]}" -H "$PRH: not json" --data-binary "@$BW"; ok 'refused STL-OWN-856' "owner-write with a proof header that is not a proof -> STL-OWN-856"
BW2=$(body w2 '{"zz":"two"}')
rq "$WM" "$WPATH" "${WH[@]}" -H "$PRH: $PR1" --data-binary "@$BW2"; ok 'refused STL-OWN-856 && cause STL-OWN-805' "owner-write with a proof made for another body -> STL-OWN-856, cause STL-OWN-805"
rq "$WM" "$WPATH" "${WH[@]}" -H "$PRH: $PR1" --data-binary "@$BW"; ok 'passed' "owner-write with token + CSRF + allowed Origin + a valid owner proof -> 200 ok (no refusal above spent the proof)"
rq "$WM" "$WPATH" "${WH[@]}" -H "$PRH: $PR1" --data-binary "@$BW"; ok 'refused STL-OWN-856 && cause STL-OWN-804' "the same owner-write again (replay) -> STL-OWN-856, cause STL-OWN-804"

# ---- unknown endpoints fail closed ----
rq GET /zz-no-such-endpoint "${WH[@]}"; ok 'refused STL-OWN-857' "unknown endpoint GET /zz-no-such-endpoint with good headers -> STL-OWN-857"
rq DELETE "$RPATH" "${WH[@]}"; ok 'refused STL-OWN-857' "a known path with a method the contract does not list (DELETE $RPATH) -> STL-OWN-857"
rq POST /zz-no-such-endpoint --data-binary '{}'; ok 'refused_any' "unknown endpoint POST with no token, Origin or CSRF -> refused with a W5 code"
rq GET "$RPATH/" "${RH[@]}"; ok 'refused STL-OWN-857' "the read path with a trailing slash ($RPATH/) is another, unknown endpoint -> STL-OWN-857"

# ---- library and CLI (the same guard, no server) ----
jq -n --arg a "$TOK" --arg c "$CSRF" '{api_token: $a, csrf_token: $c, port: 54321}' >"$T/libsess.json"
$PY -c '
import json, sys
sys.path.insert(0, sys.argv[1]); import loopback_guard as g
s, rp, wm, wp, tk, ch, o = json.load(open(sys.argv[2])), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8]
hd = lambda **k: dict({"host": "127.0.0.1:54321", tk.lower(): s["api_token"]}, **k)
r = [g.check("GET", rp, hd(), b"", s), g.check("GET", rp, hd(host="127.0.0.1:54322"), b"", s), g.check("GET", rp, hd(origin="http://attacker.example"), b"", s),
     g.check(wm, wp, hd(origin=o.replace("{port}", "54321"), **{ch.lower(): s["csrf_token"]}), b"{}", s)]
print(json.dumps([list(x) for x in r]))' "$B" "$T/libsess.json" "$RPATH" "$WM" "$WPATH" "$TOKH" "$CSRFH" "$(cj '.origins[0]')" >"$T/o" 2>&1
ok '[ "$(jq -c . "$T/o" 2>/dev/null)" = "[[true,null],[false,\"STL-OWN-850\"],[false,\"STL-OWN-851\"],[false,\"STL-OWN-855\"]]" ]' \
  "library check(method, path, headers (lower-case names), body bytes, session {api_token, csrf_token, port}): read ok; other port 850; foreign Origin 851; owner-write without proof 855"
jq -n --arg p "$RPATH" --arg t "$TOKH" --arg v "$TOK" --slurpfile s "$T/libsess.json" \
  '{method: "GET", path: $p, headers: ({"Host": "127.0.0.1:54321", "Origin": "http://attacker.example"} + {($t): $v}), body: "", session: $s[0]}' >"$T/req-bad.json"
jq '.headers |= del(.Origin)' "$T/req-bad.json" >"$T/req-good.json"
$PY "$B/loopback_guard.py" check "$T/req-bad.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && jq -e ".ok == false and .code == \"STL-OWN-851\"" "$T/o" >/dev/null' "CLI loopback_guard.py check <request.json>: foreign Origin on a read -> exit 1, {ok: false, code: STL-OWN-851}"
$PY "$B/loopback_guard.py" check "$T/req-good.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && jq -e ".ok == true" "$T/o" >/dev/null' "CLI loopback_guard.py check <request.json>: the same read with no Origin -> exit 0, {ok: true}"

# ---- a fake new endpoint added as data works with no code change ----
rq GET /qa/zz-fake-read "${RH[@]}"; ok 'refused STL-OWN-857' "before the data change: GET /qa/zz-fake-read is unknown -> STL-OWN-857"
BINSUM=$(cd "$B" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
jq --arg g1 "$(uuid)" --arg g2 "$(uuid)" --arg i "$IID" '.endpoints += [
  {id: "zz-fake-read", method: "GET", path: "/qa/zz-fake-read", scope: "read", global_id: $g1, install_id: $i},
  {id: "zz-fake-write", method: "POST", path: "/qa/zz-fake-write", scope: "owner-write", global_id: $g2, install_id: $i}]' "$LC" >"$T/lc.new" 2>/dev/null && cat "$T/lc.new" >"$LC"
$PY "$B/stella_data.py" check loopback-api >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ]' "the contract with two fake endpoint rows still validates (stella_data.py check loopback-api)"
startd; P=${P:-1}; ORIG=$(cj '.origins[0]'); ORIG=${ORIG//\{port\}/$P}; ORIG=${ORIG:-http://127.0.0.1:$P}
WH=(-H "$TOKH: $TOK" -H "Origin: $ORIG" -H "$CSRFH: $CSRF" -H "Content-Type: application/json")
rq GET /qa/zz-fake-read "${RH[@]}"; ok 'passed' "fake read endpoint added as data: GET /qa/zz-fake-read -> 200 ok after a restart (port $P)"
rq GET /qa/zz-fake-read "${RH[@]}" -H "Origin: http://attacker.example"; ok 'refused STL-OWN-851' "fake read endpoint: foreign Origin -> STL-OWN-851"
BF=$(body f1 '{"zz":"fake"}')
rq POST /qa/zz-fake-write "${WH[@]}" --data-binary "@$BF"; ok 'refused STL-OWN-855' "fake owner-write endpoint: no owner proof -> STL-OWN-855"
mkproof "$WM" "$WPATH" "$BF" "$T/p2"
rq POST /qa/zz-fake-write "${WH[@]}" -H "$PRH: $(cat "$T/p2" 2>/dev/null)" --data-binary "@$BF"; ok 'refused STL-OWN-856 && cause STL-OWN-805' "fake owner-write endpoint: a proof made for the shipped endpoint with the same body -> STL-OWN-856, cause STL-OWN-805"
mkproof POST /qa/zz-fake-write "$BF" "$T/p3"
rq POST /qa/zz-fake-write "${WH[@]}" -H "$PRH: $(cat "$T/p3" 2>/dev/null)" --data-binary "@$BF"; ok 'passed' "fake owner-write endpoint: token + CSRF + allowed Origin + its own owner proof -> 200 ok"
ok '[ "$BINSUM" = "$(cd "$B" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)" ]' "no file under bin/ changed (the new endpoints are data only)"
stopd

# ---- nothing secret in any answer or log ----
ok '[ -s "$T/bodies" ] && grep -q STL-OWN-85 "$T/bodies" && ! grep -qF -e "$TOK" -e "$CSRF" "$T/bodies" "$T/dbl.out" "$T/dbl.err" "$T/sup/logs/alerts.log" "$R/.supervisor/logs/alerts.log" 2>/dev/null' \
  "no response body, double output or alert log holds the API token or the CSRF token"
finish
