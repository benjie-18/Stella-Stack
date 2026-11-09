#!/usr/bin/env bash
# Hermetic self-test for bin/model_watch.py (K4): a running card whose worker's model calls keep failing. Everything is
# scratch: a stub hermes first on PATH (kanban list/show, config get model; `send` is refused and recorded), a scratch HOME
# holding two profiles' logs/agent.log, a tiny HTTP server on 127.0.0.1 per model server answering /api/ps, the real
# roles.py and the real settings (model_watch section: window, min_errors, line patterns). Log lines are written the way
# Hermes writes them (millisecond timestamps, "[session]" after the level), in the owner's zone (TZ).
set -u
T=$(mktemp -d); H="$T/home"; B=/workspace/bin MW=$B/model_watch.py
trap 'kill $(cat "$T"/srv-*.pid 2>/dev/null) 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$H/.hermes"
cat > "$T/bin/hermes" <<'S'
#!/usr/bin/env bash
# kanban --board B list|show ..., config get model (reads $HERMES_HOME/stub-model.txt, the profile's own home), send (refused)
case "$1" in
  send)   echo "$*" >> "$FAKE_DIR/refused-sends"; exit 1;;
  kanban) [ "$2" = --board ] || exit 2
          case "$4" in
            list) [ -z "${FAKE_LIST_FAIL:-}" ] || exit 1; cat "$FAKE_DIR/running.json";;
            show) cat "$FAKE_DIR/show-$5.json" 2>/dev/null || exit 1;;
            *)    exit 2;;
          esac;;
  config) [ "$2 $3" = "get model" ] || exit 2
          echo "$HERMES_HOME" >> "$FAKE_DIR/config-homes"
          cat "$HERMES_HOME/stub-model.txt" 2>/dev/null || exit 1;;
  *)      exit 0;;
esac
S
cat > "$T/srv.py" <<'S'
import http.server, sys
ps, portfile = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/api/ps":
            self.send_response(404); self.end_headers(); return
        body = open(ps, "rb").read()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_address[1]))
s.serve_forever()
S
chmod +x "$T/bin/hermes"
export PATH="$T/bin:$PATH" HOME="$H" FAKE_DIR="$T" TZ=America/Toronto OWNER_CONFIG="$T/no-owner.env" LC_ALL=C.UTF-8
unset HERMES_HOME WATCHDOG_SETTINGS ROLES_FILE
[ "$(command -v hermes)" = "$T/bin/hermes" ] || { echo "FAIL hermes is not the stub; refusing to run"; echo "selftest FAIL"; exit 1; }
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }

# Two profiles from the real role table (rows without their own dir), their homes under the scratch HOME.
read -r PA PB < <(jq -r '.profiles | to_entries | map(select(.value.dir == null) | .key) | .[0:2] | join(" ")' /workspace/docs/hermes-local/roles.json)
for p in $PA $PB; do mkdir -p "$H/.hermes/profiles/$p/logs"; : > "$H/.hermes/profiles/$p/config.yaml"; done
SET=/workspace/docs/hermes-local/watchdog-settings.json
WIN=$(jq -r '.model_watch.window_minutes // 30' $SET) MINE=$(jq -r '.model_watch.min_errors // 3' $SET)
IN=$(( WIN / 6 )) OUT=$(( WIN * 3 ))   # minutes ago: well inside the window, well outside it

# One model server per profile; answers /api/ps with the file given. port <name> prints its port.
serve() { : > "$T/ps-$1.json"; echo '{"models":[]}' > "$T/ps-$1.json"; rm -f "$T/srv-$1.port"
  python3 -I "$T/srv.py" "$T/ps-$1.json" "$T/srv-$1.port" & echo $! > "$T/srv-$1.pid"
  for _ in $(seq 1 100); do [ -s "$T/srv-$1.port" ] && return 0; sleep 0.1; done; return 1; }
port() { cat "$T/srv-$1.port"; }
closed_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
serve a; serve b
psf() { printf '{"models":[%s]}\n' "$([ $# -gt 1 ] && printf '{"name":"%s"},' "${@:2}" | sed 's/,$//')" > "$T/ps-$1.json"; }   # psf <server> <model>...
model() { printf 'default: %s\nbase_url: http://127.0.0.1:%s/v1\n' "$2" "$3" > "$H/.hermes/profiles/$1/stub-model.txt"; }   # model <profile> <name> <port>

# Fixtures: cards (running list, show with an open run and an owner_admitted event), log lines.
now_stamp() { date -d "-$1 min" "+%F %T,123"; }
logl() { printf '%s %s [%s] %s\n' "$(now_stamp "$2")" "$3" "$4" "$5" >> "$H/.hermes/profiles/$1/logs/agent.log"; }   # logl <profile> <min ago> <level> <session> <text>
errs() { local i; for i in $(seq 1 "$4"); do logl "$1" "$2" WARNING "$3" "agent.conversation_loop: API call failed (attempt $i/3) error_type=APIConnectionError provider=custom"; done; }   # errs <profile> <min ago> <session> <n>
tool() { logl "$1" "$2" INFO "$3" "agent.tool_executor: tool terminal completed (0.14s, 171 chars)"; }
cards=""
card() { cards="$cards{\"id\":\"$1\",\"status\":\"running\"},"; ended=${4:-null}   # card <id> <profile> <session> [ended_at] [run_id]
  printf '{"task":{"status":"running"},"runs":[{"id":3,"profile":"%s","ended_at":%s}],"events":[{"kind":"owner_admitted","run_id":%s,"payload":{"session_id":"%s"}}]}\n' "$2" "$ended" "${5:-3}" "$3" > "$T/show-$1.json"
  printf '[%s]\n' "${cards%,}" > "$T/running.json"; }
fresh() { cards=""; echo '[]' > "$T/running.json"; rm -f "$T"/show-*.json "$T/config-homes"; for p in $PA $PB; do : > "$H/.hermes/profiles/$p/logs/agent.log"; done
  psf a; psf b; model "$PA" m1 "$(port a)"; model "$PB" m2 "$(port b)"; }
run() { python3 -I "$MW" 2>"$T/stderr"; }
cause() { jq -r --arg c "$1" '.[] | select(.card == $c) | .cause' <<<"$res"; }
listed() { jq -r '[.[].card] | sort | join(",")' <<<"$res"; }

fresh; res=$(run)
ok '[ "$res" = "[]" ]' "no running card: an empty list"
fresh; res=$(FAKE_LIST_FAIL=1 run); rc=$?
ok '[ -z "$res" ] && [ "$rc" = 1 ] && [ -s "$T/stderr" ] && ! grep -q Traceback "$T/stderr"' "the board cannot be read: exit 1, nothing on stdout, one reason line (could not check, never an all-clear list; B2V-04)"

# 3 errors and no tool line: listed, and the cause comes from what the profile's own model server says.
fresh; card t_a0000001 $PA sess-A1; errs $PA $IN sess-A1 $MINE; psf a m2; res=$(run)
ok '[ "$(listed)" = t_a0000001 ] && [ "$(cause t_a0000001)" = other_loaded ] && jq -e ".[0] | .profile == \"$PA\" and .errors == $MINE and .minutes == $WIN" <<<"$res" >/dev/null && jq -r ".[0].detail" <<<"$res" | grep -q "m1 not loaded at http://127.0.0.1:$(port a); loaded: m2"' "$MINE errors, no tool line, the server lists only another model: listed with cause other_loaded (profile, error count, window minutes, detail naming both models)"
psf a m1; res=$(run)
ok '[ "$(cause t_a0000001)" = loaded ] && jq -r ".[0].detail" <<<"$res" | grep -q "^m1 loaded at "' "the server lists the profile's model: cause loaded"
psf a; res=$(run)
ok '[ "$(cause t_a0000001)" = not_loaded ] && jq -r ".[0].detail" <<<"$res" | grep -q "loaded: none"' "the server lists no model: cause not_loaded"
psf a m3 m1 m4; res=$(run)
ok '[ "$(cause t_a0000001)" = loaded ]' "the profile's model among several loaded: cause loaded"
printf '{"models":[{"model":"m1"}]}\n' > "$T/ps-a.json"; res=$(run)
ok '[ "$(cause t_a0000001)" = loaded ]' "a model entry that names itself by \"model\" instead of \"name\" counts"
model $PA m1 "$(closed_port)"; res=$(run)
ok '[ "$(listed)" = t_a0000001 ] && [ "$(cause t_a0000001)" = unreachable ] && jq -r ".[0].detail" <<<"$res" | grep -q "^http://127.0.0.1:[0-9]*: "' "no server listens at the profile's base_url: cause unreachable"
printf 'default: m1\n' > "$H/.hermes/profiles/$PA/stub-model.txt"; res=$(run)
ok '[ "$(listed)" = t_a0000001 ] && [ "$(cause t_a0000001)" = unknown ]' "no base_url configured for the profile: still listed, cause unknown"
rm -f "$H/.hermes/profiles/$PA/stub-model.txt"; res=$(run)
ok '[ "$(listed)" = t_a0000001 ] && [ "$(cause t_a0000001)" = unknown ]' "the profile's model config cannot be read: still listed, cause unknown"

# Not a problem: below the threshold, progress, old errors, someone else's session.
fresh; card t_a0000002 $PA sess-A2; errs $PA $IN sess-A2 $((MINE - 1)); res=$(run)
ok '[ "$res" = "[]" ]' "one error fewer than the threshold: not listed"
# B2V-07: a stalled call logs "Stream stale" and then "API call failed" (agent.log, 2026-10-29): one failed call, counted once
stalls() { local i; for i in $(seq 1 "$4"); do logl "$1" "$2" WARNING "$3" "agent.chat_completion_helpers: Stream stale for 900s (threshold 900s) — no chunks received."
  logl "$1" "$2" WARNING "$3" "agent.conversation_loop: API call failed (attempt $i/3) error_type=APIConnectionError provider=custom"; done; }
fresh; card t_a0000012 $PA sess-A12; stalls $PA $IN sess-A12 $((MINE - 1)); res=$(run)
ok '[ "$res" = "[]" ]' "B2V-07: one stall fewer than the threshold (each a Stream stale plus an API call failed line): not listed"
fresh; card t_a0000013 $PA sess-A13; stalls $PA $IN sess-A13 "$MINE"; res=$(run)
ok '[ "$(listed)" = t_a0000013 ] && jq -e ".[0].errors == $MINE" <<<"$res" >/dev/null' "B2V-07: $MINE stalls: listed with errors = $MINE (calls, not lines)"
fresh; card t_a0000002 $PA sess-A2; errs $PA $IN sess-A2 $MINE; tool $PA $((IN - 1)) sess-A2; res=$(run)
ok '[ "$res" = "[]" ]' "errors and a completed tool line inside the window: not listed (the worker still makes progress)"
fresh; card t_a0000002 $PA sess-A2; errs $PA $IN sess-A2 $MINE; tool $PA $OUT sess-A2; res=$(run)
ok '[ "$(listed)" = t_a0000002 ]' "a tool line older than the window does not count as progress: listed"
fresh; card t_a0000002 $PA sess-A2; errs $PA $IN sess-A2 $MINE; tool $PA $IN sess-OTHER; res=$(run)
ok '[ "$(listed)" = t_a0000002 ]' "another session's tool line is not this card's progress: listed"
fresh; card t_a0000002 $PA sess-A2; errs $PA $OUT sess-A2 $((MINE + 3)); res=$(run)
ok '[ "$res" = "[]" ]' "errors older than the window: not listed"
fresh; card t_a0000002 $PA sess-A2; errs $PA $IN sess-OTHER $((MINE + 3)); res=$(run)
ok '[ "$res" = "[]" ]' "another session's errors: not listed"
fresh; card t_a0000002 $PA sess-A2; errs $PA $IN sess-A20 $((MINE + 3)); res=$(run)
ok '[ "$res" = "[]" ]' "a session id that merely starts with this card's: not listed (the [session] marker is matched whole)"
fresh; card t_a0000002 $PA sess-A2; errs $PA $IN sess-A2 $((MINE - 1)); errs $PA $IN sess-OTHER 5; res=$(run)
ok '[ "$res" = "[]" ]' "own errors below the threshold plus another session's errors are not added up: not listed"
fresh; card t_a0000002 $PA sess-A2; errs $PB $IN sess-A2 $MINE; res=$(run)
ok '[ "$res" = "[]" ]' "the same session id in another profile's log: not read (the card's own profile log only)"
fresh; card t_a0000002 $PA sess-A2; rm -f "$H/.hermes/profiles/$PA/logs/agent.log"; res=$(run)
ok '[ "$res" = "[]" ]' "no agent log at all: not listed"
fresh; card t_a0000002 $PA sess-A2; errs $PA $IN sess-A2 $MINE; res=$(TZ=UTC run)
ok '[ "$res" = "[]" ]' "log times are read in the owner's zone: the same lines read as UTC are hours old, not listed"
fresh; card t_a0000002 $PA sess-A2 "1790000000" ; errs $PA $IN sess-A2 $MINE; res=$(run)
ok '[ "$res" = "[]" ]' "the card's run has ended: not listed"
fresh; card t_a0000002 $PA sess-A2 null 9; errs $PA $IN sess-A2 $MINE; res=$(run)
ok '[ "$res" = "[]" ]' "the owner_admitted event belongs to another run: no session to watch, not listed"
fresh; card t_a0000002 $PA sess-A2; errs $PA $IN sess-A2 $MINE; jq 'del(.events)' "$T/show-t_a0000002.json" > "$T/x" && mv "$T/x" "$T/show-t_a0000002.json"; res=$(run)
ok '[ "$res" = "[]" ]' "no owner_admitted event yet: not listed"
fresh; card t_a0000002 ghost-profile sess-A2; errs $PA $IN sess-A2 $MINE; res=$(run)
ok '[ "$res" = "[]" ]' "a run whose profile is not in the role table or Hermes root: no log to read, not listed"

# Several cards: each judged on its own; each profile asks its own model server.
fresh; card t_a0000003 $PA sess-A3; card t_a0000004 $PB sess-B4; card t_a0000005 $PA sess-A5
errs $PA $IN sess-A3 $MINE; errs $PB $IN sess-B4 $MINE; tool $PA $IN sess-A5; errs $PA $IN sess-A5 $MINE; psf a m1; psf b m9
res=$(run)
ok '[ "$(listed)" = t_a0000003,t_a0000004 ] && [ "$(cause t_a0000003)" = loaded ] && [ "$(cause t_a0000004)" = other_loaded ]' "three running cards on two profiles: the one with progress is not listed, the others get the cause from their own profile's model server"
ok '[ "$(sort -u "$T/config-homes")" = "$(printf "%s\n" "$H/.hermes/profiles/$PA" "$H/.hermes/profiles/$PB" | sort)" ]' "the model config is read in each worker profile's own Hermes home"
fresh; card t_a0000006 $PA sess-A6; card t_a0000007 $PA sess-A7; errs $PA $IN sess-A7 $MINE; rm -f "$T/show-t_a0000006.json"; res=$(run)
ok '[ "$(cause t_a0000006)" = unknown ] && [ "$(cause t_a0000007)" = not_loaded ] && jq -e "map(select(.card == \"t_a0000006\"))[0].detail | length > 0" <<<"$res" >/dev/null' "one card that cannot be read is one unknown entry with a reason; the other card is still checked"
ok 'jq -e "map(select(.card == \"t_a0000006\"))[0].unchecked == true and (map(select(.card == \"t_a0000007\"))[0] | has(\"unchecked\") | not)" <<<"$res" >/dev/null' "the unreadable card is marked unchecked (the watchdog neither pages nor resolves it); the checked one is not (B2V-03)"
fresh; card t_a0000008 $PA sess-A8; errs $PA $IN sess-A8 $MINE; printf 'not json\n' > "$T/show-t_a0000008.json"; res=$(run)
ok '[ "$(cause t_a0000008)" = unknown ] && [ "$(jq length <<<"$res")" = 1 ]' "garbled card data: one unknown entry, no crash"
fresh; printf 'not json\n' > "$T/running.json"; res=$(run); rc=$?
ok '[ -z "$res" ] && [ "$rc" = 1 ]' "the board answers with garbage: exit 1, nothing on stdout (could not check; B2V-04)"
ok '[ ! -e "$T/refused-sends" ]' "the watch never sends anything itself (the stub hermes refused no send)"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
