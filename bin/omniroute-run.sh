#!/usr/bin/env bash
# Fallback runner (T14/T15). Everything it needs comes from docs/hermes-local/fallback-routing.json (FALLBACK_CONFIG overrides the
# path): gateway URL, key file and install folder, the per-role chain of models to try in order, the provider allow and avoid
# lists, the evidence log. No model or provider is named here.
#   omniroute-run.sh [--role R]   prompt on stdin; tries R's chain (else the default chain) until one entry is served by a permitted
#                                 provider; prints {"model_used","text"} and exits 0, else prints nothing and exits 1
#   omniroute-run.sh --models     GET /v1/models; prints {"models":[...]}
#   omniroute-run.sh --check      validate the config (exit 0 valid)
# Every attempt appends one JSON line to the evidence log: time, role, kind, requested and routed model, provider, ok, http_status,
# latency_ms, rate_limited (HTTP 429), error. Loopback gateway only, and only when the process listening on its port is the
# pinned install (its cwd is under gateway.install_dir): another process on that port never receives the key. The endpoint key
# goes to curl through a process substitution, so no file holds it and it is not in argv.
set -uo pipefail
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
W=/workspace; CFG=${FALLBACK_CONFIG:-$W/docs/hermes-local/fallback-routing.json}
fail() { echo "omniroute-run.sh: $1" >&2; exit 1; }
role=default mode=run
while [ $# -gt 0 ]; do case $1 in --role) role=${2:-}; shift 2;; --models) mode=models; shift;; --check) mode=check; shift;; *) fail "unknown option $1";; esac; done
[ -r "$CFG" ] || fail "cannot read the config $CFG"
jq -e '.schema_version == 1 and (.enabled | type == "boolean") and (.gateway.base_url | type == "string") and (.gateway.key_file | type == "string")
  and (.gateway.install_dir | type == "string" and startswith("/")) and (.evidence_log | type == "string")
  and (.providers.allow | type == "array" and all(type == "string")) and (.providers.avoid | type == "array" and all(type == "string"))
  and (.roles.default.chain | type == "array" and length > 0)
  and ([.roles[].chain] | all(type == "array" and length > 0 and all(.[]; (.model | type == "string") and .model != "")))
  and (if .enabled then (.providers.allow | length > 0) else true end)' "$CFG" >/dev/null 2>&1 \
  || fail "$CFG is not valid: needs schema_version 1, enabled, gateway.base_url, key_file and install_dir (absolute), evidence_log, providers.allow and avoid lists of strings (allow non-empty when enabled), and a non-empty chain of {model} for default and every role"
base=$(jq -r .gateway.base_url "$CFG"); keyf=$(jq -r .gateway.key_file "$CFG"); inst=$(jq -r '.gateway.install_dir | rtrimstr("/")' "$CFG"); to=$(jq -r '.gateway.timeout_s // 120' "$CFG")
ev=$(jq -r .evidence_log "$CFG"); [[ $ev == /* ]] || ev=$W/$ev
[[ $base =~ ^http://(127\.0\.0\.1|localhost|\[::1\])(:([0-9]+))?$ ]] || fail "the gateway must be on loopback, got '$base'"
port=${BASH_REMATCH[3]:-80}
[ "$mode" = check ] && exit 0
[ -s "$keyf" ] || fail "no endpoint key file at $keyf"
key=$(tr -d '\n' <"$keyf"); [[ $key =~ ^[A-Za-z0-9._~+/=-]+$ ]] || fail "the endpoint key file has characters a key does not"
# who listens on that port: the pinned install, or somebody else who must not get the key
lpid=$(ss -ltnp 2>/dev/null | sed -n "s/.*\(127\.0\.0\.1\|\[::1\]\):$port .*pid=\([0-9]*\).*/\2/p" | head -1)
[ -n "$lpid" ] && cwd=$(readlink "/proc/$lpid/cwd" 2>/dev/null) && [[ "$cwd" == "$inst" || "$cwd" == "$inst"/* ]] \
  || fail "the process listening on port $port is not the pinned install (cwd '${cwd:-unknown}', want under $inst): not sending the key"
body=$(mktemp /tmp/omniroute-run.XXXXXX) || fail "no temp file"; req=$(mktemp /tmp/omniroute-run.XXXXXX); trap 'rm -f "$body" "$req"' EXIT; trap 'exit 143' TERM; trap 'exit 130' INT   # EXIT then runs the cleanup
mkdir -p "$(dirname "$ev")"
record() {  # record <kind> <requested> <routed> <provider> <ok> <status> <ms> <error>
  jq -nc --arg time "$(date -u +%FT%TZ)" --arg role "$role" --arg kind "$1" --arg req "$2" --arg routed "$3" --arg prov "$4" \
    --argjson ok "$5" --argjson st "${6:-0}" --argjson ms "$7" --arg err "$8" \
    '{time: $time, role: $role, kind: $kind, requested_model: $req, routed_model: $routed, provider: $prov, ok: $ok, http_status: $st,
      latency_ms: $ms, rate_limited: ($st == 429), error: $err}' >>"$ev"
}
call() {  # call <GET|POST> <path> [request file]: sets $code (HTTP status, 0 on no answer) and $ms; the response is in $body
  local t0=$(date +%s%3N)
  if [ "$1" = GET ]; then code=$(curl -sS --max-time "$to" -K <(printf 'header = "Authorization: Bearer %s"\n' "$key") -o "$body" -w '%{http_code}' "$base$2" 2>/dev/null)
  else code=$(curl -sS --max-time "$to" -K <(printf 'header = "Authorization: Bearer %s"\n' "$key") -H 'Content-Type: application/json' --data-binary "@$3" -o "$body" -w '%{http_code}' "$base$2" 2>/dev/null); fi
  ms=$(( $(date +%s%3N) - t0 )); code=${code:-0}
}
if [ "$mode" = models ]; then
  call GET /v1/models
  m=$(jq -c '{models: [.data[]?.id]}' "$body" 2>/dev/null)
  if [ "$code" = 200 ] && [ -n "$m" ]; then record models "" "" "" true "$code" "$ms" ""; echo "$m"; exit 0; fi
  record models "" "" "" false "$code" "$ms" "the gateway did not list models"; fail "the gateway did not list models (HTTP $code)"
fi
prompt=$(mktemp /tmp/omniroute-run.XXXXXX); trap 'rm -f "$body" "$req" "$prompt"' EXIT
cat >"$prompt"; [ -s "$prompt" ] || fail "prompt required on stdin"
chain=$(jq -c --arg r "$role" '(.roles[$r].chain // .roles.default.chain)[].model' "$CFG")
while IFS= read -r q; do
  rm=$(jq -r . <<<"$q")
  jq -nc --arg m "$rm" --rawfile p "$prompt" '{model: $m, messages: [{role: "user", content: $p}]}' >"$req"
  call POST /v1/chat/completions "$req"
  routed=$(jq -r '(.model | strings) // empty' "$body" 2>/dev/null)
  prov=$(jq -r 'if (.provider | type) == "string" then .provider elif ((.model | type) == "string") and (.model | contains("/")) then .model | split("/")[0] else "" end' "$body" 2>/dev/null)
  has_text=$(jq -r 'if (.choices[0].message.content | type) == "string" and (.choices[0].message.content | length) > 0 then "y" else "" end' "$body" 2>/dev/null)
  err=""
  if [ "$code" != 200 ]; then err="HTTP $code"
  elif [ -z "$routed" ] || [ -z "$has_text" ]; then err="the answer has no model or text"
  elif ! [[ $routed =~ ^[A-Za-z0-9._:/+@-]{1,128}$ ]]; then err="the served model name is not a plain model name"
  elif [[ ${routed,,} == *claude* ]]; then err="the served model is a Claude model"
  elif jq -e '(.providers.avoid | length > 0) or (.providers.allow | length > 0)' "$CFG" >/dev/null && [ -z "$prov" ]; then err="the served provider is unknown and a provider list is set"
  elif jq -e --arg p "$prov" '.providers.avoid | map(ascii_downcase) | index($p | ascii_downcase)' "$CFG" >/dev/null; then err="provider '$prov' is on the avoid list"
  elif jq -e '.providers.allow | length > 0' "$CFG" >/dev/null && ! jq -e --arg p "$prov" '.providers.allow | map(ascii_downcase) | index($p | ascii_downcase)' "$CFG" >/dev/null; then err="provider '${prov:-unknown}' is not on the allow list"; fi
  if [ -z "$err" ]; then record chat "$rm" "$routed" "$prov" true "$code" "$ms" ""; jq -c --arg m "$routed" '{model_used: $m, text: .choices[0].message.content}' "$body"; exit 0; fi
  record chat "$rm" "$routed" "$prov" false "$code" "$ms" "$err"
done <<<"$chain"
fail "no entry of the $role chain was served"
