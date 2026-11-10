#!/usr/bin/env bash
# Hermetic self-test for bin/omniroute-run.sh (T14/T15 runner). A stub gateway on a random loopback port and a scratch config
# (the same format as docs/hermes-local/fallback-routing.json). Every model and provider name below is a FIXTURE the stub makes
# up: no assertion names a real model, so the test passes whatever the live config says. No real OmniRoute, no network.
set -u
R=/workspace/bin/omniroute-run.sh; T=$(mktemp -d); trap 'kill $srv 2>/dev/null; rm -rf "$T"' EXIT; fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
cat >"$T/srv.py" <<'P'
# Stub gateway. Model "fixture-limited" answers 429, "fixture-down" 503; any other model is served as "<fixture-provider>/<model>".
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(json.dumps(obj).encode())
    def do_GET(self):
        open(sys.argv[2], "a").write(json.dumps({"auth": self.headers.get("Authorization"), "path": self.path}) + "\n")
        self.reply(200, {"data": [{"id": "fixture-provider/fixture-listed"}]})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        open(sys.argv[2], "a").write(json.dumps({"auth": self.headers.get("Authorization"), "path": self.path, "model": body["model"]}) + "\n")
        if body["model"] == "fixture-limited": return self.reply(429, {"error": "rate limited"})
        if body["model"] == "fixture-down": return self.reply(503, {"error": "down"})
        if body["model"] == "fixture-slow": import time; time.sleep(4)
        if body["model"] == "fixture-bare": return self.reply(200, {"model": "bare", "choices": [{"message": {"content": "pong"}}]})
        if body["model"] == "fixture-evil": return self.reply(200, {"model": "x\n<@123456789012345678> @everyone", "choices": [{"message": {"content": "pong"}}]})
        if body["model"] == "fixture-big": return self.reply(200, {"model": "fixture-provider/big", "choices": [{"message": {"content": "A" * 300000}}], "_prompt_len": len(body["messages"][0]["content"])})
        self.reply(200, {"model": "fixture-provider/" + body["model"], "choices": [{"message": {"role": "assistant", "content": "pong"}}]})
s = HTTPServer(("127.0.0.1", 0), H); open(sys.argv[1], "w").write(str(s.server_port)); s.serve_forever()
P
(cd "$T" && exec python3 "$T/srv.py" "$T/port" "$T/seen") & srv=$!   # its cwd is $T: what gateway.install_dir must match
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
printf 'fixture-endpoint-key\n' >"$T/key"; chmod 600 "$T/key"
DEFAULT_ALLOW='["fixture-provider"]'   # enabled configs need an explicit allow list
# cfg <chain-json> [avoid-json] [allow-json] [base-url]: writes $T/cfg.json
cfg() { jq -n --argjson chain "$1" --argjson avoid "${2:-[]}" --argjson allow "${3:-$DEFAULT_ALLOW}" --arg inst "${INST:-$T}" --arg base "${4:-http://127.0.0.1:$(cat "$T/port")}" --arg key "$T/key" --arg ev "$T/evidence.jsonl" \
  '{schema_version: 1, enabled: true, runner: "bin/omniroute-run.sh", gateway: {base_url: $base, key_file: $key, install_dir: $inst, timeout_s: 10}, evidence_log: $ev,
    providers: {allow: $allow, avoid: $avoid}, roles: {default: {chain: $chain}, review: {chain: [{model: "fixture-review"}]}}}' >"$T/cfg.json"; : >"$T/seen"; : >"$T/evidence.jsonl"; }
run() { FALLBACK_CONFIG=$T/cfg.json "$R" "$@"; }

cfg '[{"model":"fixture-a"}]'
ok 'run --check >/dev/null 2>&1' "--check accepts a valid config"
out=$(echo ping | run 2>"$T/err"); rc=$?
ok '[ $rc = 0 ] && [ "$(jq -r .model_used <<<"$out")" = fixture-provider/fixture-a ] && [ "$(jq -r .text <<<"$out")" = pong ]' "prints the serving model and the text (rc $rc)"
ok '[ "$(jq -r .model "$T/seen")" = "$(jq -r .roles.default.chain[0].model "$T/cfg.json")" ]' "asks the gateway for whatever model the config's chain names"
ok '[ "$(jq -r .path "$T/seen")" = /v1/chat/completions ] && [ "$(jq -r .auth "$T/seen")" = "Bearer fixture-endpoint-key" ]' "uses /v1/chat/completions with the key from the key file"
ok '! grep -q fixture-endpoint-key "$T/err" "$T/evidence.jsonl"' "the key reaches neither stderr nor the evidence log"
ev=$(tail -1 "$T/evidence.jsonl")
ok 'jq -e ".ok == true and .requested_model == \"fixture-a\" and .routed_model == \"fixture-provider/fixture-a\" and .provider == \"fixture-provider\" and .http_status == 200 and (.latency_ms | type == \"number\") and .rate_limited == false and (.time | test(\"^20[0-9][0-9]-\")) and .role == \"default\"" <<<"$ev" >/dev/null' "evidence line: routed model, provider, ok, status, latency, rate-limit flag, time, role"

# roles and chains
cfg '[{"model":"fixture-limited"},{"model":"fixture-down"},{"model":"fixture-b"}]'
out=$(echo ping | run 2>/dev/null); rc=$?
ok '[ $rc = 0 ] && [ "$(jq -r .model_used <<<"$out")" = fixture-provider/fixture-b ] && [ "$(wc -l <"$T/evidence.jsonl")" = 3 ]' "falls down the chain in order; one evidence line per attempt (rc $rc)"
ok 'jq -s -e "(.[0].rate_limited == true) and (.[0].ok == false) and (.[1].http_status == 503) and (.[2].ok == true)" "$T/evidence.jsonl" >/dev/null' "evidence records the 429 and the 503 before the success"
echo ping | run --role review >/dev/null 2>&1
ok '[ "$(jq -r .model "$T/seen" | tail -1)" = fixture-review ]' "--role picks that role's chain"
cfg '[{"model":"fixture-dflt"}]'; echo ping | run --role not-in-config >/dev/null 2>&1
ok '[ "$(jq -r .model "$T/seen" | tail -1)" = fixture-dflt ]' "an unknown role uses the default chain"
cfg '[{"model":"fixture-limited"},{"model":"fixture-down"}]'
ok '! echo ping | run >/dev/null 2>&1' "every entry failing: exits non-zero, no result"

# provider allow and avoid lists
cfg '[{"model":"fixture-a"}]' '["fixture-provider"]'
ok '! echo ping | run >/dev/null 2>&1 && jq -s -e "all(.[]; .ok == false and (.error | test(\"avoid\")))" "$T/evidence.jsonl" >/dev/null' "a served provider on the avoid list is refused and recorded as such"
cfg '[{"model":"fixture-a"}]' '[]' '["some-other-provider"]'
ok '! echo ping | run >/dev/null 2>&1' "a served provider outside a non-empty allow list is refused"
cfg '[{"model":"fixture-a"}]' '[]' '["fixture-provider"]'
ok 'echo ping | run >/dev/null 2>&1' "a served provider inside the allow list is accepted"

# gateway and config problems
cfg '[{"model":"fixture-a"}]' '[]' "$DEFAULT_ALLOW" 'http://example.com:20128'
ok '! echo ping | run >/dev/null 2>&1 && echo ping | run 2>&1 | grep -q loopback' "refuses a gateway that is not on loopback"
cfg '[{"model":"fixture-a"}]' '[]' "$DEFAULT_ALLOW" 'http://127.0.0.1:9'
ok '! echo ping | run >/dev/null 2>&1' "gateway down: exits non-zero"
cfg '[{"model":"fixture-a"}]'; jq '.gateway.key_file = "'"$T"'/none"' "$T/cfg.json" >"$T/c2" && mv "$T/c2" "$T/cfg.json"
ok '! echo ping | run >/dev/null 2>&1' "no key file: exits non-zero"
cfg '[{"model":"fixture-a"}]'; ok '! "$R" </dev/null >/dev/null 2>&1 || ! FALLBACK_CONFIG=$T/cfg.json "$R" </dev/null >/dev/null 2>&1' "empty prompt: exits non-zero"
cfg '[]';                        ok '! run --check >/dev/null 2>&1' "--check refuses an empty default chain"
cfg '[{"model":"fixture-a"}]'; jq 'del(.schema_version)' "$T/cfg.json" >"$T/c2" && mv "$T/c2" "$T/cfg.json"
ok '! run --check >/dev/null 2>&1' "--check refuses a config with no schema_version"
ok '! FALLBACK_CONFIG=$T/missing.json "$R" --check >/dev/null 2>&1' "--check refuses a missing config"
ok 'jq -e ".schema_version == 1 and (.roles.default.chain | length > 0)" /workspace/docs/hermes-local/fallback-routing.json >/dev/null && "$R" --check >/dev/null 2>&1' "the shipped config is valid"
ok '! grep -qE "(gpt|claude|llama|gemini|qwen|mistral|deepseek|glm|kimi)-?[0-9a-z.]" /workspace/docs/hermes-local/fallback-routing.json /workspace/bin/omniroute-run.sh' "no real model id in the shipped config or the runner"


# --- fix round 1 (red-team S6C-02, -04, -05, -07, -08; verifier) ---
# the listener on the gateway port must be the pinned install: an impostor never gets the key
cfg '[{"model":"fixture-a"}]'; INST=/nonexistent/install cfg '[{"model":"fixture-a"}]'
ok '! echo ping | run >/dev/null 2>&1 && [ ! -s "$T/seen" ] && echo ping | run 2>&1 | grep -q "not the pinned install"' "a listener whose cwd is not gateway.install_dir is refused before any request (the key is never sent)"
cfg '[{"model":"fixture-a"}]'; ok 'echo ping | run >/dev/null 2>&1' "control: the listener inside gateway.install_dir is accepted"
cfg '[{"model":"fixture-a"}]'; jq 'del(.gateway.install_dir)' "$T/cfg.json" >"$T/c2" && mv "$T/c2" "$T/cfg.json"; ok '! run --check >/dev/null 2>&1' "--check refuses a config with no gateway.install_dir"
# enabled needs an explicit allow list; empty role chains refused
cfg '[{"model":"fixture-a"}]' '[]' '[]'; ok '! run --check >/dev/null 2>&1' "--check refuses enabled true with an empty providers.allow"
cfg '[{"model":"fixture-a"}]'; jq '.enabled = false | .providers.allow = []' "$T/cfg.json" >"$T/c2" && mv "$T/c2" "$T/cfg.json"; ok 'run --check >/dev/null 2>&1' "--check accepts a disabled config with an empty allow list"
cfg '[{"model":"fixture-a"}]'; jq '.roles.review.chain = []' "$T/cfg.json" >"$T/c2" && mv "$T/c2" "$T/cfg.json"; ok '! run --check >/dev/null 2>&1' "--check refuses a role with an empty chain"
# avoid and allow lists: case, bare names, non-string provider
cfg '[{"model":"fixture-a"}]' '["FIXTURE-PROVIDER"]'; ok '! echo ping | run >/dev/null 2>&1' "the avoid list matches case-insensitively"
cfg '[{"model":"fixture-bare"}]' '["somebody"]'; ok '! echo ping | run >/dev/null 2>&1 && jq -s -e "any(.[]; .error | test(\"provider\"))" "$T/evidence.jsonl" >/dev/null' "a served model with no provider is refused when a list is set"
cfg '[{"model":"fixture-a"}]' '[]' '["FIXTURE-Provider"]'; ok 'echo ping | run >/dev/null 2>&1' "the allow list matches case-insensitively"
# a hostile served name never reaches a result; only plain model names pass
cfg '[{"model":"fixture-evil"}]'; ok '! echo ping | run >/dev/null 2>&1 && jq -s -e "any(.[]; .ok == false and (.error | test(\"model name\")))" "$T/evidence.jsonl" >/dev/null' "a served model name with a newline or a mention is refused"
# no key file left behind when the call is killed
cfg '[{"model":"fixture-slow"}]'; rm -f /tmp/omniroute-run.*; echo ping | timeout 1 env FALLBACK_CONFIG="$T/cfg.json" "$R" >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 124 ] && [ -z "$(find /tmp -maxdepth 1 -name "omniroute-run.*" 2>/dev/null)" ]' "killed by timeout (as escalate.sh does): no temp file with the key is left (rc $rc)"
# large prompt and large answer
cfg '[{"model":"fixture-big"}]'; : >"$T/seen"
big=$(head -c 200000 /dev/zero | tr '\0' 'p'); out=$(printf '%s' "$big" | run 2>/dev/null); rc=$?
ok '[ "$rc" = 0 ] && [ "$(jq -r .text <<<"$out" | wc -c)" -ge 300000 ]' "a 300 KB answer comes back whole (rc $rc)"
ok 'printf "%s" "$big" | FALLBACK_CONFIG=$T/cfg.json "$R" 2>/dev/null | jq -e ".model_used" >/dev/null && jq -s -e "all(.[]; .ok == true)" "$T/evidence.jsonl" >/dev/null' "a 200 KB prompt is sent and the evidence line says ok"

# --models: the smoke call for /v1/models, with evidence
cfg '[{"model":"fixture-a"}]'
out=$(run --models 2>/dev/null); rc=$?
ok '[ $rc = 0 ] && jq -e ".models | length >= 1" <<<"$out" >/dev/null && [ "$(jq -r .path "$T/seen" | tail -1)" = /v1/models ] && jq -s -e "any(.[]; .kind == \"models\" and .ok == true and .http_status == 200)" "$T/evidence.jsonl" >/dev/null' "--models lists /v1/models and records evidence (rc $rc)"
ok '[ "$(ls -A /tmp | grep -c omniroute-run)" = 0 ]' "leaves no temp header file behind"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
