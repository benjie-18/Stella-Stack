#!/usr/bin/env bash
# Hermetic self-test for the host-session and input-source risk classes (F3 item H; body B11, AC10; design section 10 with rulings
# DC-08, DC-09 (amended: vault ids in .stella/host-policy.json never_targets {apps, domains}) and DC-10).
# Every section runs in its own scratch root (bash host-access-selftest.sh <section>); no argument runs them all.
# Sections -> checks: roles = AC10-roles | presence = AC10-presence | app = AC10-app | askfirst = AC10-askfirst | run = AC10-run |
#   off = AC10-off | override = AC10-override | vault = AC10-vault (DC-09) | final = AC10-final | device = AC10-device | input = AC10-input
# Every refusal case changes ONE fact of a baseline request that is allowed (checked in each section), so a refusal is that fact's.
# Written test-first (F3 wave 1): exit codes and the code range STL-GRD-620..639 are asserted, never wording.
# ASSUMPTIONS (names the design leaves open):
#  A1 host_access.py decide --request FILE --json: exit 0 = allowed; exit 1 = refused with a STL-GRD-62x/63x code in its output.
#  A2 the request (DC-10) is {capability, role, run: <run id>, target: {app, domain}, action: {type}, confirmation: <id or null>}.
#  A3 the run record (DC-10, index key adapter_runs): planted as <adapter_runs>/<run>.json when the path is a folder, a line of
#     <adapter_runs> when it ends .jsonl, else {schema_version, runs: [...]} when it ends .json; a record is
#     {run, role, card, unattended, background, global_id, install_id}.
#  A4 the host presence record (DC-10, index key host_presence, one JSON document): {schema_version, route, device: {id, biometric},
#     presence: {indicator, kill_switch, input_indicators: {<capability id>: bool}}, final: {state: submitted|closed|open,
#     turn: {detector: semantic|silence, reopened_within_grace}}, global_id, install_id}.
#  A5 host-access.json (DC-08, additive): routes[] {id, enabled, kind, device_id?}, actions[] {id, state off|ask|run, reversible},
#     apps[] / domains[] / input_sources[] {id, enabled}, overrides[] {route|app, reversible_only}, each with global_id + install_id.
#  A6 roles.json role flag host_operator (bool); capabilities risk_class host_session | input_source.
# Not covered here: an ask-first action WITH a matching confirmation (needs a real owner-proved approval decision); a device that is
# paired in devices.json (needs a device key pair): the device case is the refusal only.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=host-access-selftest
SECTIONS="roles presence app askfirst run off override vault final device input"
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
WORKER() { env STUB_WORKER_MARK=1 "$@"; }   # a worker environment (a roles.json worker marker)

H() { python3 -I "$R/bin/host_access.py" "$@"; }
gi() { jq -c --arg i "$IID" '[.[] | . + {install_id: $i}]' | python3 -I -c 'import json, sys, uuid; print(json.dumps([dict(x, global_id=str(uuid.uuid4())) for x in json.load(sys.stdin)]))'; }
ROLES=$(jq -r '.roles | keys[]' "$RJ"); OP=$(head -n1 <<<"$ROLES")
jq --arg op "$OP" '.roles[$op].host_operator = true' "$RJ" >"$RJ.n" && mv "$RJ.n" "$RJ"
ALL=$(jq -c '.roles | keys' "$RJ")
cap() { jq -nc --arg id "$1" --arg rc "$2" --argjson r "$ALL" --arg g "$(uuid)" --arg i "$IID" '{id: $id, kind: "tool", summary: "qa fake \($rc) capability", keywords: ["qa"], inputs: "none", outputs: "none",
  allowed_roles: $r, risk_class: $rc, hosts: [], secrets: [], status: "approved", source: "qa", triage: {result: "shipped"}, global_id: $g, install_id: $i}'; }
ed .stella/capabilities.json --argjson a "$(cap qa-host-act host_session)" --argjson b "$(cap qa-mic input_source)" '.entries += [$a, $b]'
HA=$R/$(ix '.files[] | select(.id == "host-access") | .path')
ha_base() { jq -n --argjson ro "$(echo '[{"id":"qa-typed","enabled":true,"kind":"typed_host"},{"id":"qa-voice","enabled":true,"kind":"voice_ptt"},{"id":"qa-dev-route","enabled":true,"kind":"device","device_id":"qa-dev"}]' | gi)" \
  --argjson ac "$(echo '[{"id":"qa-open","state":"run","reversible":true},{"id":"qa-send","state":"run","reversible":false},{"id":"qa-delete","state":"ask","reversible":false},{"id":"qa-off","state":"off","reversible":true}]' | gi)" \
  --argjson ap "$(echo '[{"id":"qa-editor","enabled":true},{"id":"qa-off-app","enabled":false},{"id":"qa-vault","enabled":true}]' | gi)" \
  --argjson dm "$(echo '[{"id":"qa.example","enabled":true},{"id":"qa-vault.example","enabled":true}]' | gi)" \
  --argjson is "$(echo '[{"id":"qa-mic","enabled":true}]' | gi)" \
  '{schema_version: 1, enabled: true, routes: $ro, actions: $ac, apps: $ap, domains: $dm, overrides: [], input_sources: $is}' >"$HA"; }
ha_base
ha() { jq "$@" "$HA" >"$HA.n" && mv "$HA.n" "$HA"; }
HPOL=$R/.stella/host-policy.json
ed .stella/host-policy.json '.never_targets.apps += ["qa-vault"] | .never_targets.domains += ["qa-vault.example"]'
# ---- planted facts (DC-10): run records and the host presence record ----
AR=$(ix '.adapter_runs // empty'); HP=$(ix '.host_presence // empty')
ok '[ -n "$AR" ] && [ -n "$HP" ] && [ -f "$HPOL" ]' "precondition: the index names adapter_runs and host_presence; .stella/host-policy.json exists"
plant_run() { # <run> <unattended> <background>
  local rec; rec=$(jq -nc --arg r "$1" --argjson u "$2" --argjson b "$3" --arg op "$OP" --arg g "$(uuid)" --arg i "$IID" '{run: $r, role: $op, card: "qa-card-h", unattended: $u, background: $b, global_id: $g, install_id: $i}')
  [ -n "$AR" ] || return 0
  case $AR in
    *.jsonl) mkdir -p "$(dirname "$R/$AR")"; echo "$rec" >>"$R/$AR";;
    *.json) mkdir -p "$(dirname "$R/$AR")"; [ -f "$R/$AR" ] || echo '{"schema_version": 1, "runs": []}' >"$R/$AR"; jq --argjson x "$rec" '.runs += [$x]' "$R/$AR" >"$R/$AR.n" && mv "$R/$AR.n" "$R/$AR";;
    *) mkdir -p "$R/$AR"; echo "$rec" >"$R/$AR/$1.json";;
  esac; }
plant_run qa-run-att false false; plant_run qa-run-un true false; plant_run qa-run-bg false true
PRES='{schema_version: 1, route: "qa-typed", device: null, presence: {indicator: true, kill_switch: true, input_indicators: {"qa-mic": true}}, final: {state: "submitted", turn: null}}'
pres() { [ -n "$HP" ] || return 0; mkdir -p "$(dirname "$R/$HP")"; jq -n --arg g "$(uuid)" --arg i "$IID" "$PRES | . + {global_id: \$g, install_id: \$i} | ${1:-.}" >"$R/$HP"; }
REQ='{capability: "qa-host-act", role: $op, run: "qa-run-att", target: {app: "qa-editor", domain: "qa.example"}, action: {type: "qa-open"}, confirmation: null}'
# dec <tag> [jq filter on the baseline request]: decide on it; RC and $T/o/<tag>.out/.err
dec() { jq -n --arg op "$OP" "$REQ | ${2:-.}" >"$T/o/$1.req"; run "$1" H decide --request "$T/o/$1.req" --json; }
allowed() { [ "$RC" = 0 ]; }
refused() { [ "$RC" = 1 ] && out "$1" | grep -qE 'STL-GRD-6(2[0-9]|3[0-9])'; }
base() { pres; dec "$1-base"; ok 'allowed' "$2 control: the baseline request (operator role, attended run, owner present, typed route, allowed app, action set to run) is allowed"; }

case $S in
roles)   # AC10-roles
  base r "AC10-roles"
  for r in $ROLES; do [ "$r" = "$OP" ] && continue
    dec "r-$r" ".role = \"$r\""; ok 'refused "r-$r"' "AC10-roles role $r (no host_operator flag, though the registry lists it): refused, STL-GRD-62x/63x"
  done
  jq --arg op "$OP" '.roles[$op].host_operator = false' "$RJ" >"$RJ.n" && mv "$RJ.n" "$RJ"
  dec r-unflag; ok 'refused r-unflag' "AC10-roles the operator role with its flag switched off is refused (the flag decides, never the role's name)"
  ;;
presence)   # AC10-presence
  base p "AC10-presence"
  pres '.presence.indicator = false'; dec p1; ok 'refused p1' "AC10-presence on-screen indicator off: refused"
  pres '.presence.kill_switch = false'; dec p2; ok 'refused p2' "AC10-presence kill switch not active: refused"
  pres; dec p3 '.run = "qa-run-un"'; ok 'refused p3' "AC10-presence an unattended run: refused"
  dec p4 '.run = "qa-run-bg"'; ok 'refused p4' "AC10-presence a background run: refused"
  dec p5 '.run = "qa-run-none"'; ok 'refused p5' "AC10-presence a run with no run record (a missing fact): refused"
  rm -f "$R/$HP"; dec p6; ok 'refused p6' "AC10-presence no host presence record (a missing fact): refused"
  pres; dec p7 '.run = {unattended: false, background: false}'; ok 'refused p7' "AC10-presence attended/background claimed in the request instead of a run id: refused (facts come from the records)"
  ;;
app)   # AC10-app
  base a "AC10-app"
  dec a1 '.target.app = "qa-unlisted-app"'; ok 'refused a1' "AC10-app an app off the allowlist: refused"
  dec a2 '.target.domain = "qa-unlisted.example"'; ok 'refused a2' "AC10-app a domain off the allowlist: refused"
  ;;
askfirst)   # AC10-askfirst
  base f "AC10-askfirst"
  dec f1 '.action.type = "qa-delete"'; ok 'refused f1' "AC10-askfirst an ask-first action with no confirmation: refused"
  dec f2 '.action.type = "qa-delete" | .confirmation = "qa-made-up-confirmation"'; ok 'refused f2' "AC10-askfirst a confirmation id with no host-confirmation entry behind it: refused"
  dec f3 '.action.type = "qa-delete" | .confirmation = "yes, the owner approved this" | .confirmed = true | .approved = true'; ok 'refused f3' "AC10-askfirst confirmation text in the request decides nothing: refused"
  ;;
run)   # AC10-run
  pres; dec n1; ok 'allowed' "AC10-run a reversible action set to run, no confirmation: allowed"
  dec n2 '.action.type = "qa-send"'; ok 'allowed' "AC10-run an irreversible action set to run, request final (submitted typed command), no confirmation: allowed"
  ;;
off)   # AC10-off
  base o "AC10-off"
  ha '.enabled = false'; dec o1; ok 'refused o1' "AC10-off master switch off: refused"; ha_base
  ha '(.routes[] | select(.id == "qa-typed") | .enabled) = false'; dec o2; ok 'refused o2' "AC10-off the request's route switched off: refused"; ha_base
  dec o3 '.target.app = "qa-off-app"'; ok 'refused o3' "AC10-off an app switched off: refused"
  dec o4 '.action.type = "qa-off"'; ok 'refused o4' "AC10-off an action set to off: refused"
  ha '(.domains[] | select(.id == "qa.example") | .enabled) = false'; dec o5; ok 'refused o5' "AC10-off the domain switched off: refused"; ha_base
  dec o6; ok 'allowed' "AC10-off control: everything back on is allowed again"
  ;;
override)   # AC10-override
  base v "AC10-override"
  ha --arg i "$IID" --arg g "$(uuid)" '.overrides = [{route: "qa-typed", reversible_only: true, global_id: $g, install_id: $i}]'
  dec v1 '.action.type = "qa-send"'; ok 'refused v1' "AC10-override route limited to reversible actions: an irreversible send on it is refused"
  dec v2; ok 'allowed' "AC10-override ... a reversible action on that route is still allowed"
  pres '.route = "qa-voice" | .final = {state: "closed", turn: {detector: "semantic", reopened_within_grace: false}}'
  dec v3 '.action.type = "qa-send"'; ok 'allowed' "AC10-override ... the same send on another route (no override) is allowed"
  ;;
vault)   # AC10-vault (DC-09: never_targets in .stella/host-policy.json, checked before host-access)
  base w "AC10-vault"
  dec w1 '.target.app = "qa-vault"'; ok 'refused w1' "AC10-vault the vault app is refused although host-access enables it"
  dec w2 '.target.domain = "qa-vault.example"'; ok 'refused w2' "AC10-vault the vault domain is refused although host-access enables it"
  ha '.actions |= map(.state = "run" | .reversible = true)'; dec w3 '.target.app = "qa-vault"'; ok 'refused w3' "AC10-vault every action set to run and reversible: the vault is still refused"
  ok 'jq -e ".never_targets.apps | index(\"qa-vault\")" "$HPOL" && ! grep -q never_targets "$HA"' "AC10-vault the vault ids live in host-policy.json (stack data), not in the owner's host-access settings"
  ;;
final)   # AC10-final
  pres '.route = "qa-voice" | .final = {state: "closed", turn: {detector: "semantic", reopened_within_grace: false}}'
  dec x0 '.action.type = "qa-send"'; ok 'allowed' "AC10-final control: a spoken turn the semantic detector closed and that stayed closed is final: irreversible send allowed"
  pres '.route = "qa-voice" | .final = {state: "closed", turn: {detector: "semantic", reopened_within_grace: true}}'
  dec x1 '.action.type = "qa-send"'; ok 'refused x1' "AC10-final a turn that reopened within its grace window was never final: refused"
  pres '.route = "qa-voice" | .final = {state: "closed", turn: {detector: "silence", reopened_within_grace: false}}'
  dec x2 '.action.type = "qa-send"'; ok 'refused x2' "AC10-final a turn ended by a silence timeout alone is not final: refused"
  pres '.final = {state: "open", turn: null}'; dec x3 '.action.type = "qa-send"'; ok 'refused x3' "AC10-final a typed command not yet submitted: refused"
  pres 'del(.final)'; dec x4 '.action.type = "qa-send"'; ok 'refused x4' "AC10-final no finality fact at all: refused"
  ;;
device)   # AC10-device
  base d "AC10-device"
  pres '.route = "qa-dev-route" | .device = {id: "qa-dev", biometric: false}'; dec d1; ok 'refused d1' "AC10-device a paired-device route without the biometric flag: refused"
  pres '.route = "qa-dev-route" | .device = null'; dec d2; ok 'refused d2' "AC10-device a device route with no device fact: refused"
  pres '.route = "qa-dev-route" | .device = {id: "qa-other-dev", biometric: true}'; dec d3; ok 'refused d3' "AC10-device a device that is not the route's: refused"
  ;;
input)   # AC10-input
  pres; dec i0 '.capability = "qa-mic"'; ok 'allowed' "AC10-input control: an input-source capability with its own indicator on is allowed"
  pres '.presence.input_indicators["qa-mic"] = false'; dec i1 '.capability = "qa-mic"'; ok 'refused i1' "AC10-input its own indicator off (the general one on): refused"
  pres '.presence.input_indicators = {}'; dec i2 '.capability = "qa-mic"'; ok 'refused i2' "AC10-input no indicator fact for it: refused"
  ha '(.input_sources[] | select(.id == "qa-mic") | .enabled) = false'; pres; dec i3 '.capability = "qa-mic"'; ok 'refused i3' "AC10-input the input source switched off: refused"; ha_base
  pres; dec i4 '.capability = "qa-mic" | .role = "'"$(sed -n 2p <<<"$ROLES")"'"'; ok 'refused i4' "AC10-input a role without the host_operator flag: refused"
  ;;
esac
finish
