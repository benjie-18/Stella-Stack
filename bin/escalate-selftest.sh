#!/usr/bin/env bash
# Hermetic self-test for bin/escalate.sh: stub claude/hermes, scratch state dir, no spend, no board writes.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sup"
sed -e 's/^HAIKU_MAX_PER_DAY=.*/HAIKU_MAX_PER_DAY=2/' /workspace/.supervisor/limits.env >"$T/sup/limits.env"
cat >"$T/bin/claude" <<'S'
#!/usr/bin/env bash
ok='{"type":"result","is_error":false,"total_cost_usd":0.001,"modelUsage":{"claude-haiku-5-5":{}}}'
echo $(( $(cat "$ESCALATE_SUP_DIR/claude_n" 2>/dev/null || echo 0) + 1 )) > "$ESCALATE_SUP_DIR/claude_n"
cat >/dev/null; sleep "${FAKE_SLEEP:-0}"; printf '%s\n' "${FAKE_OUT:-$ok}"; exit "${FAKE_RC:-0}"
S
cat >"$T/bin/hermes" <<'S'
#!/usr/bin/env bash
[ "$1 $2" = "kanban --board" ] && set -- "$1" "${@:4}"   # scripts name the board (F4)
case "$1 $2" in
  "kanban show") { [ "$3" = t_00000000 ] || [ -n "${FAKE_SHOW_FAIL:-}" ]; } && exit 1; [ -z "${FAKE_SHOW_RAW:-}" ] || { printf '%s\n' "$FAKE_SHOW_RAW"; exit 0; }; printf '{"task":{"body":"%s","status":"%s","assignee":"%s","project":"%s"}}\n' "${FAKE_BODY:-}" "${FAKE_STATUS:-running}" "$FAKE_ASSIGNEE" "$FAKE_PROJECT";;
  "kanban list") jq -nc --arg c "${FAKE_RUNNING:-}" '[$c | select(. != "") | {id: .}]';;   # the running cards: none, or FAKE_RUNNING
  "kanban comment") echo "$*" >>"$ESCALATE_SUP_DIR/comments";;
  send*) echo "$*" >>"$ESCALATE_SUP_DIR/sends"
    # FAKE_SEND_HOLD=<path>: a slow alert. Says it arrived (<path>.in), then waits for <path>.go, at most 30 s.
    [ -z "${FAKE_SEND_HOLD:-}" ] || { touch "$FAKE_SEND_HOLD.in"; for _ in $(seq 300); do [ -e "$FAKE_SEND_HOLD.go" ] && break; sleep 0.1; done; }
    exit 1;;
esac
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" ESCALATE_SUP_DIR="$T/sup" FALLBACK_CONFIG="$T/no-such-fallback-config.json"   # no reroute unless a test writes one
# F2 W7b: escalate.sh asks the resolver, which refuses the CLI-login connection on the shipped data (no terms recorded). The whole
# run uses a fixture root (STELLA_ROOT): the shipped data with what the owner records on the host: that connection usable for the
# caller's role (terms, the role; its models' probe records) and a selected preset of every link class; the board stub answers the
# caller (the first profile of the first card role) and a project, and every card id this file uses has a clean facts record.
# The model ids and their limits are the shipped catalog's (limits.env keys named in each model's `limits`).
FX=$T/fx; mkdir -p "$FX/docs"; cp -r /workspace/.stella "$FX/"; cp -r /workspace/docs/hermes-local "$FX/docs/"
SH=$T/shipped; cp -r "$FX" "$SH"   # the shipped data as it is (no terms, no chains of these roles): its card facts are added below
CR=$(jq -r '.card_roles[0]' "$FX/.stella/routing.json"); export FAKE_PROJECT=qa-proj
export FAKE_ASSIGNEE=$(jq -r --arg r "$CR" '[.profiles | to_entries[] | select(.value.role == $r) | .key][0]' "/workspace/$(jq -r .role_table /workspace/.stella/data-files.json)")
fxed() { jq "${@:2}" "$FX/.stella/$1" >"$FX/.stella/$1.n" && mv "$FX/.stella/$1.n" "$FX/.stella/$1"; }   # fxed <data file> <jq args and filter>
# F2b item E: the caller names a purpose; the purpose picks the role (routing escalation.purposes) and the card's rung of that role
# (state/rungs.json, 1 when absent) picks the link of the role's escalation chain. Three roles of the role table, each a chain of
# the shipped CLI-login models, keep the old cases' models: judge -> RA [haiku], review -> CR [sonnet, opus], plan and rescue ->
# RB [opus]. RA and RB are roles no card, exemption or workflow rule binds, whose data classes may go to a hosted link (as
# qa/wave2/T-ESC-RUNG.sh picks them); every name is read from the data.
RJ=$FX/$(jq -r .role_table "$FX/.stella/data-files.json")
read -r RA RB < <(jq -r --slurpfile rt "$FX/.stella/routing.json" --slurpfile pol "$FX/.stella/data-policy.json" '.fallback_role as $fb | $rt[0] as $r
  | ($r.card_roles + [$r.exempt_roles[].role] + [$r.workflow.required_roles[].role]) as $bound | [.roles | to_entries[] | select(.key != $fb and (.key as $k | $bound | index($k) | not))
  | select([.value.requirements.allowed_data_classes[]? | $pol[0].class_rules[.].hosted] | all(. == "allowed")) | .key][:2] | join(" ")' "$RJ")
CLIC=$(jq -r '[.entries[] | select(.type == "cli-login") | .id][0]' "$FX/.stella/connections.json")
lk() { jq -c --arg c "$CLIC" '[.[] | {connection: $c, model: ., parameters: {}}]' <<<"$1"; }   # lk '["m1", ...]': a chain of that connection's models
fxed connections.json --argjson r "$(jq -nc --arg a "$CR" --arg b "${RA:-}" --arg c "${RB:-}" '[$a, $b, $c]')" --argjson dc "$(jq -c .data_classes "$FX/.stella/data-policy.json")" '(.entries[] | select(.type == "cli-login")) |= (.terms_ok = true | .allowed_roles += $r
  | .data_policy.data_classes_allowed = $dc | .models[] |= (.capabilities = {tool_calling: true, json_mode: true, context_tokens: 1048576, vision: true, streaming: true} | .probe_source = "advertised"))'
PRX=$FX/$(jq -r .probe_records "$FX/.stella/data-files.json"); mkdir -p "$(dirname "$PRX")"   # F2b item C: routing reads what a link can do from its probe record only
jq --arg c "$CLIC" --arg i "$(jq -r .install_id "$FX/$(jq -r '.files[] | select(.schema == "install") | .path' "$FX/.stella/data-files.json")")" --arg o "$(jq -r '.probe.output_shapes[-1]' "$FX/.stella/routing.json")" \
  '{schema_version: 1, records: [.entries[] | select(.id == $c) | .models[] | {global_id: "00000000-0000-4000-8000-000000000000", install_id: $i, connection: $c, model: .id,
    version: "qa", probed_at: "2026-01-01T00:00:00Z", family: null, tool_calling: true, parallel_tool_calls: null, json: true, vision: true, output_shape: $o,
    context: {advertised: null, effective: 1048576, short_score: 1, points: []}, code: null}]}' "$FX/.stella/connections.json" >"$PRX"
mkdir -p "$(dirname "$SH/${PRX#"$FX"/}")"
# the shipped root as a host that probed its local models (as the catalog advertises them), so the W7b case below meets the shipped rungs
jq --arg i "$(jq -r '.records[0].install_id // empty' "$PRX")" --arg o "$(jq -r '.probe.output_shapes[-1]' "$SH/.stella/routing.json")" \
  '{schema_version: 1, records: [.entries[] | select(.kind == "provider" and .locality == "local") | .id as $c | .models[] | {global_id: "00000000-0000-4000-8000-000000000000",
    install_id: $i, connection: $c, model: .id, version: "qa", probed_at: "2026-01-01T00:00:00Z", family: null, tool_calling: .capabilities.tool_calling, parallel_tool_calls: null,
    json: .capabilities.json_mode, vision: .capabilities.vision, output_shape: $o, context: {advertised: .capabilities.context_tokens, effective: (.capabilities.context_tokens // 0),
    short_score: 1, points: []}, code: null}]}' "$SH/.stella/connections.json" >"$SH/${PRX#"$FX"/}"
fxed role-assignments.json --argjson k "$(jq -c '[.link_classes[].id]' "$FX/.stella/routing.json")" --arg cr "$CR" --arg a "${RA:-}" --arg b "${RB:-}" \
  --argjson ca "$(lk '["haiku"]')" --argjson cc "$(lk '["sonnet", "opus"]')" --argjson cb "$(lk '["opus"]')" '.effort_modes["qa-all"] = {allowed_localities: ["local", "cloud"], no_silent_fallback: false, class_order: $k,
    roles: {($a): {active: true, escalation_chain: $ca}, ($cr): {active: true, escalation_chain: $cc}, ($b): {active: true, escalation_chain: $cb}}} | .selection.global = "qa-all"'
fxed routing.json --arg cr "$CR" --arg a "${RA:-}" --arg b "${RB:-}" '.escalation.purposes = {judge: $a, review: $cr, plan: $b, rescue: $b}'
rungs() { mkdir -p "$T/sup/state"; jq -n --arg c "$1" --arg r "$2" --argjson n "$3" '{($c): {($r): $n}}' >"$T/sup/state/rungs.json"; }   # rungs <card> <role> <rung>: the card's current rung
CF=$FX/$(jq -r .card_facts "$FX/.stella/data-files.json"); mkdir -p "$CF" "$SH/${CF#"$FX"/}"
for c in $(grep -o 't_[0-9a-f]\{8\}' "$0" | sort -u) t_dddd000{1..9} t_eeee000{1..9}; do echo '{"project":"qa-proj","carries_secrets":false,"vault_content":false,"apps":[]}' >"$CF/$c.json"; cp "$CF/$c.json" "$SH/${CF#"$FX"/}/"; done
export STELLA_ROOT=$FX
python3 -I /workspace/bin/stella_data.py check >"$T/fxcheck" 2>&1 && [ -n "$FAKE_ASSIGNEE" ] && [ -n "$RB" ] || { echo "FAIL the fixture root does not pass the data check, no profile has role $CR, or the role table has no two free roles: $(head -3 "$T/fxcheck")"; echo "selftest FAIL (fixture)"; exit 1; }
E=${ESCALATE:-/workspace/bin/escalate.sh} fails=0   # ESCALATE=<copy>: a staged copy while it is being replaced
check() { local want=$1 desc=$2; shift 2; "$@" >/dev/null 2>"$T/err"; local rc=$?
  if [ "$rc" = "$want" ]; then echo "ok   $desc (exit $rc)"; else echo "FAIL $desc: want $want got $rc: $(cat "$T/err")"; fails=$((fails+1)); fi; }
last() { tail -1 "$T/sup/escalations.log" | jq -r "$1"; }
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
Q="$T/sup/state/queue.jsonl" D=/workspace/bin/escalate-drain.sh
q() { jq -r --arg c "$1" 'select(.card == $c) | .state' "$Q" 2>/dev/null | tr '\n' ,; }
qid() { jq -r --arg c "$1" 'select(.card == $c) | .id' "$Q" | head -1; }
nalerts() { grep -c -- "$1" "$T/sup/sends" 2>/dev/null || true; }
runs() { cat "$T/sup/claude_n" 2>/dev/null || echo 0; }
setlimit() { sed -i "s/^$1=.*/$1=$2/" "$T/sup/limits.env"; }

check 2 "no card id"            sh -c "echo hi | $E"
check 2 "unknown card"          sh -c "echo hi | $E t_00000000 judge why"
check 2 "no reason"             sh -c "echo hi | $E t_12345678 judge"
check 2 "empty prompt"          sh -c "$E t_12345678 judge why </dev/null"
rungs t_aaaa0010 "$CR" 2   # review's role at rung 2: opus, whose limits.purposes holds no review
n=$(runs); check 3 "opus for review (rung 2 of review's role)" sh -c "echo hi | $E t_aaaa0010 review why"
ok 'grep -q "opus (rung 2 of role $CR) is allowed only for" "$T/err" && [ "$(runs)" = "$n" ] && [ -z "$(q t_aaaa0010)" ] && ! ls "$T/sup/state"/prompt-*-t_aaaa0010-* >/dev/null 2>&1' "E: ... not run, not queued, no prompt file left, no other rung tried"
rm -f "$T/sup/state/rungs.json"
check 0 "haiku 1"               sh -c "echo hi | $E t_12345678 judge why"
[ "$(last .event)/$(last .model_used)/$(last .fallback)" = "OK/claude-haiku-5-5/false" ] || { echo "FAIL ok log: $(tail -1 "$T/sup/escalations.log")"; fails=$((fails+1)); }
check 0 "haiku 2"               sh -c "echo hi | $E t_12345678 judge why"
check 3 "haiku 3 over limit"    sh -c "echo hi | $E t_12345678 judge why"
[ "$(last .event)" = LIMIT ] || { echo "FAIL limit not logged"; fails=$((fails+1)); }
FAKE_SLEEP=2 sh -c "echo hi | $E t_12345678 rescue first" >/dev/null 2>&1 & sleep 0.5
check 3 "second concurrent opus" sh -c "echo hi | $E t_12345678 plan second"
wait
check 75 "forced pool, low risk" env ESCALATE_FORCE_POOL_EXHAUSTED=1 sh -c "echo hi | $E t_12345678 review why"
[ "$(last .event)/$(last .fallback)/$(last .model_used)" = "QUEUED/true/none" ] || { echo "FAIL low-risk pool log: $(tail -1 "$T/sup/escalations.log")"; fails=$((fails+1)); }
check 75 "real pool string, high risk" env FAKE_OUT="Claude AI usage limit reached|resets 3am" FAKE_RC=1 FAKE_BODY="risk: high" sh -c "echo hi | $E t_12345678 review why"
[ "$(last .event)" = QUEUED ] && [ -s "$T/sup/state/queue.jsonl" ] || { echo "FAIL high-risk not queued"; fails=$((fails+1)); }
check 1 "non-JSON exit 0"      env FAKE_OUT='garbage' sh -c "echo hi | $E t_12345678 review why"
check 1 "is_error result"       env FAKE_OUT='{"is_error":true,"modelUsage":{}}' sh -c "echo hi | $E t_12345678 review why"
grep -q "fallback: false. No next rung ran" "$T/sup/comments" || { echo "FAIL no next rung ran not noted on card"; fails=$((fails+1)); }   # D83 via the resolver: the walk found none

# Queue (F15, F28, F29, T13, T15): a LIMIT refusal and every POOL_EXHAUSTED write one queue entry and one #alerts line;
# the caller keeps its exit code. bin/escalate-drain.sh replays an entry once, with limits and pool checked again.
# F2 W7b, F2b item E: the purpose is data and the resolver serves the rung (the phase cases: qa/wave2/T-ESC-RUNG.sh)
n=$(runs); check 2 "E: a model named where the purpose goes (no escalation.purposes row): refused" sh -c "echo hi | $E t_aaaa0901 haiku judge why"
ok 'grep -q "STL-MDL-747 purpose haiku has no row" "$T/err" && [ "$(runs)" = "$n" ] && [ -z "$(q t_aaaa0901)" ] && ! ls "$T/sup/state"/prompt-*-t_aaaa0901-* >/dev/null 2>&1' "E: ... with STL-MDL-747, no model call, nothing queued, no prompt file"
check 0 "E: control: the same purpose with a row runs" sh -c "echo hi | $E t_aaaa0901 review why"
# Owner decision 2026-11-18 (D-CVER-01, D83): any served rung runs (a CLI-login link on this script's CLI, any other link through
# bin/route.py), and a rung whose pool or limit is exhausted is left for the next rung the resolver judges. Shipped-like data: the
# shipped data plus what the owner records on the host (local models probed; the free-cloud connection enabled for the role and
# its data classes; a wire shape on both; the mock's address) and the built-in chain of the judge purpose's role (the building
# role's local rungs, then the free-cloud link). The mock rate-limits the local model: rung 1 fails over, rung 2 (the same link)
# is cooling, rung 3 (free cloud) answers. Its own state folder (the haiku daily count of the cases above stays theirs).
SG=$T/sup-g; mkdir -p "$SG"; cp "$T/sup/limits.env" "$SG/"; runsg() { cat "$SG/claude_n" 2>/dev/null || echo 0; }
SW=$T/shipped-walk; cp -r "$SH" "$SW"; SX=$SW/.stella
STELLA_ROOT=$SH python3 -I /workspace/bin/mock_provider.py >"$T/mock.out" 2>"$T/mock.err" & MP=$!
for _ in $(seq 100); do [ -s "$T/mock.out" ] && break; sleep 0.1; done
PORT=$(jq -r .port "$T/mock.out" 2>/dev/null); CTL=$(jq -r .control "$T/mock.out" 2>/dev/null); LO=$(jq -r '.control | capture("//(?<h>[^:/]+):").h' "$T/mock.out" 2>/dev/null)
PS=$(jq -r '.entries[0].id' "$SX/protocols.json"); VR=$(jq -r '.escalation.purposes.judge' "$SX/routing.json"); BR=$(jq -r '.builder_roles[0]' "$SX/routing.json")
FCL=$(jq -r '[.link_classes[] | select(.hosted)] | max_by(.privacy_rank) | .id' "$SX/routing.json")   # the least private hosted class: free cloud
read -r LC LM < <(jq -r '[.entries[] | select(.kind == "provider" and .locality == "local")][0] | "\(.id) \(.models[0].id)"' "$SX/connections.json")
read -r FC FM < <(jq -r --arg f "$FCL" '[.entries[] | select(.kind == "provider" and .link_class == $f)][0] | "\(.id) \(.models[0].id)"' "$SX/connections.json")
sxed() { jq "${@:2}" "$SX/$1" >"$SX/$1.n" && mv "$SX/$1.n" "$SX/$1"; }
sxed protocols.json '.entries |= map(.request.path = "/" + .id + .request.path | .models_path = "/" + .id + .models_path)'   # the mock serves each shape under its id
sxed connections.json --arg l "$LC" --arg f "$FC" --arg h "$LO" --argjson p "${PORT:-0}" --arg s "$PS" --arg r "$VR" \
  '[.entries[] | select(.id == $l)][0].data_policy.data_classes_allowed as $dc   # the free-cloud connection takes the data classes of the local one
   | (.entries[] | select(.id == $l or .id == $f)) |= (.hosts[0] = {host: $h, port: $p, purpose: "qa mock"} | .protocol //= $s)
   | (.entries[] | select(.id == $f)) |= (.allowed_roles += [$r] | .data_policy.data_classes_allowed = $dc | .auth_types = ["none"] | .secrets = [])'   # no key: the mock asks none
sxed data-policy.json --arg h "$LO" '.local_hosts += [$h]'   # the mock's address stands for the local model server's
sxed role-assignments.json --arg r "$VR" --arg b "$BR" --arg f "$FC" --arg m "$FM" '.selection.global as $g | .effort_modes[$g].roles[$r] = ((.effort_modes[$g].roles[$r] // {active: true})
  + {escalation_chain: ([.effort_modes[$g].roles[$b].escalation_chain[] | select(.connection != $f)] + [{connection: $f, model: $m, parameters: {}}])})'
mock() { python3 -I -c 'import sys, urllib.request as u; o = u.build_opener(u.ProxyHandler({}))
print(o.open(u.Request(sys.argv[1], data=sys.argv[2].encode(), method="POST") if len(sys.argv) > 2 else sys.argv[1], timeout=10).read().decode())' "$@"; }
mock "$CTL" "$(jq -nc --arg s "$PS" --arg l "$LM" --arg f "$FM" '{models: {($s): [$l, $f]}, faults: [{shape: $s, model: $l, fault: "rate_limit"}]}')" >/dev/null
FBC=/workspace/docs/hermes-local/fallback-routing.json   # the shipped prompt_block_patterns (D83 gates on a free-cloud rung)
n=$(runsg); echo hi | env STELLA_ROOT=$SW ESCALATE_SUP_DIR=$SG NO_PROXY="$LO" FALLBACK_CONFIG=$FBC "$E" t_aaaa0902 judge why >"$T/walk.out" 2>"$T/walk.err"; wrc=$?
calls=$(mock "${CTL%/*}/_calls" 2>/dev/null); [ "$wrc" = 0 ] || grep -v setlocale "$T/walk.err" | head -5 | sed 's/^/  why (walk): /'; [ "$wrc" = 0 ] || STELLA_ROOT=$SW python3 -I /workspace/bin/stella_data.py get --json connections 2>&1 >/dev/null | head -5 | sed 's/^/  why (catalog): /'
ok '[ "$wrc" = 0 ] && jq -e --arg c "$FC" ".link.connection == \$c and .fallback == true and (.text | length > 0)" "$T/walk.out" >/dev/null && [ "$(runsg)" = "$n" ] &&
  jq -e --arg l "$PS/$LM" --arg f "$PS/$FM" ".counts[\$l] >= 1 and .counts[\$f] == 1" <<<"$calls" >/dev/null &&
  [ "$(jq -s "[.[] | select(.card == \"t_aaaa0902\" and .event == \"WALK\")] | length" "$SG/escalations.log")" = 2 ]' \
  "D83 via the resolver, shipped-like data: judge ($VR) rung 1 local is rate-limited, rung 2 (same link) cooling, rung 3 $FC answers through route.py: exit 0 (exit $wrc)"
# D83 gate kept: a prompt that matches a prompt_block_patterns regex is never sent to the free-cloud rung (skipped; the local
# rungs still cool, so the walk ends with no rung run and the call queues); the log names the pattern, never the prompt
sk="sk-qa$(printf 'A%.0s' $(seq 24))"; f0=$(jq -r --arg f "$PS/$FM" '.counts[$f] // 0' <<<"$calls")
echo "key $sk" | env STELLA_ROOT=$SW ESCALATE_SUP_DIR=$SG NO_PROXY="$LO" FALLBACK_CONFIG=$FBC "$E" t_aaaa0908 judge why >/dev/null 2>"$T/blk.err"; brc=$?
calls=$(mock "${CTL%/*}/_calls" 2>/dev/null)
ok '[ "$brc" != 0 ] && [ "$(jq -r --arg f "$PS/$FM" ".counts[\$f] // 0" <<<"$calls")" = "$f0" ] && ! grep -q "$sk" "$SG/escalations.log" &&
  jq -se "any(.[]; .card == \"t_aaaa0908\" and .event == \"SKIP\" and (.detail | contains(\"prompt_block_patterns\")))" "$SG/escalations.log" >/dev/null' \
  "D83 gate: a prompt matching a blocked pattern is not sent to the free-cloud rung (exit $brc, a SKIP line names the pattern, not the prompt)"
kill "$MP" 2>/dev/null
# Approval: a rung of the preset's last-resort class (outside its class order) needs the owner's crossing grant: without one it is
# skipped (needs_grant) and no rung is left (STL-MDL-731, exit 4); with one in force the same call runs it.
GR=$T/fx-gr; cp -r "$FX" "$GR"; CC=$(jq -r --arg c "$CLIC" '.entries[] | select(.id == $c) | .link_class' "$FX/.stella/connections.json")
jq --arg c "$CC" '.effort_modes["qa-all"] |= (.class_order -= [$c] | .last_resort = $c)' "$FX/.stella/role-assignments.json" >"$GR/.stella/role-assignments.json"
n=$(runsg); check 4 "approval: the judge rung's class is the last resort and no crossing grant is in force: no rung left" env STELLA_ROOT=$GR ESCALATE_SUP_DIR=$SG sh -c "echo hi | $E t_aaaa0906 judge why"
ok 'grep -q "STL-MDL-731" "$T/err" && grep -q "STL-MDL-718" "$T/err" && [ "$(runsg)" = "$n" ]' "approval: ... STL-MDL-731 with the skipped rung's STL-MDL-718, no model call"
jq --arg c "$CC" --arg g "$(cat /proc/sys/kernel/random/uuid)" --arg i "$(jq -r .install_id "$FX/.stella/install.json")" \
  '.crossing_grants += [{id: "qa-cross", global_id: $g, install_id: $i, preset: "qa-all", to_class: $c, scope: {level: "global"}, granted_at: "2026-01-01T00:00:00Z"}]' "$FX/.stella/grants.json" >"$GR/.stella/grants.json"
check 0 "approval: with the owner's crossing grant in force the same rung runs" env STELLA_ROOT=$GR ESCALATE_SUP_DIR=$SG sh -c "echo hi | $E t_aaaa0907 judge why"
ok '[ "$(runsg)" = $((n + 1)) ]' "approval: ... one model call"
# rung state: a file that cannot be read, or no whole number from 1, is never read as rung 1 (fail closed), and asks no resolver
printf '{"t_aaaa0905": {"%s": 0}}\n' "$CR" >"$T/sup/state/rungs.json"; n=$(runs)
check 2 "E: rungs.json names rung 0 for the card and role: refused" sh -c "echo hi | $E t_aaaa0905 review why"
ok 'grep -q "STL-MDL-747 state/rungs.json" "$T/err" && [ "$(runs)" = "$n" ] && [ -z "$(q t_aaaa0905)" ]' "E: ... with STL-MDL-747, no model call, nothing queued"
echo '{' >"$T/sup/state/rungs.json"; check 2 "E: rungs.json is not JSON: refused" sh -c "echo hi | $E t_aaaa0905 review why"
rm -f "$T/sup/state/rungs.json"
# the purpose's role is data: a row naming no role of the role table fails the data check
BR=$T/fx-br; cp -r "$FX" "$BR"; jq '.escalation.purposes["qa-bad"] = "qa-no-such-role"' "$FX/.stella/routing.json" >"$BR/.stella/routing.json"
ok '! STELLA_ROOT=$BR python3 -I /workspace/bin/stella_data.py check >"$T/brcheck" 2>&1 && grep -q "escalation.purposes" "$T/brcheck"' "E: stella_data check refuses an escalation.purposes row whose role is not in the role table"
rm -rf "$BR"
# W3P-F-3: under a Local only project the hosted rung is skipped (716): no rung is left, so the call goes to the owner
LO=$T/fx-lo; cp -r "$FX" "$LO"; jq --arg g "$(cat /proc/sys/kernel/random/uuid)" --arg i "$(jq -r .install_id "$FX/.stella/install.json")" '.projects["qa-proj"] = {mode: "local_only", allowed_providers: [], global_id: $g, install_id: $i}' "$FX/.stella/data-policy.json" >"$LO/.stella/data-policy.json"
n=$(runs); check 4 "W3P-F-3: a Local only project: the hosted rung is skipped, no rung left" env STELLA_ROOT=$LO sh -c "echo hi | $E t_aaaa0903 review why"
ok 'STELLA_ROOT=$LO python3 -I /workspace/bin/stella_data.py check >/dev/null 2>&1 && grep -q "STL-MDL-731" "$T/err" && grep -q "STL-MDL-716" "$T/err" && [ "$(runs)" = "$n" ] && [ "$(q t_aaaa0903)" = "owner," ]' "W3P-F-3: ... STL-MDL-731 with the skipped rung's STL-MDL-716, no model call, kept for the owner (the fixture passes the data check)"
# D-F-1: a link the resolver lists cooling is not usable either (the cases above meet an excluded link or none)
CD=$T/fx-cd; cp -r "$FX" "$CD"; RS=$CD/$(jq -r .routing_state "$FX/.stella/data-files.json"); mkdir -p "$(dirname "$RS")"
jq -n --arg l "$(jq -r '[.entries[] | select(.type == "cli-login") | .id][0]' "$FX/.stella/connections.json")/sonnet" --arg s "$(date -u +%FT%TZ)" --arg u "$(date -u -d '+30 days' +%FT%TZ)" \
  '{links: {($l): {trigger: "rate_limit", since: $s, until: $u, failures: 1, observed_limit: null}}, tasks: {}}' >"$RS"
n=$(runs); check 3 "D-F-1: the served rung is in cooldown: refused" env STELLA_ROOT=$CD sh -c "echo hi | $E t_aaaa0904 review why"
ok 'STELLA_ROOT=$CD python3 -I /workspace/bin/resolve.py resolve --role "$CR" --project qa-proj --card t_aaaa0904 --json 2>/dev/null | jq -e "any(.chain[]; .model == \"sonnet\" and .status == \"cooldown\")" >/dev/null && grep -q "STL-MDL-724 rung 1 of role $CR" "$T/err" && [ "$(runs)" = "$n" ] && [ "$(q t_aaaa0904)" = "queued," ]' "D-F-1: ... with the cooldown code STL-MDL-724 (the resolver lists the link cooling in this fixture), no model call, queued"
# W7b-VAL-01, E-DC-04: only the supervisor runs escalate.sh: every worker run is refused, its own card too. A worker is what every owner command takes for one (bin/worker_env.py: here
# a marker of the role table, or a card's open run bound to an ancestor of the call, this script's own process); its card is the one
# the guards' proof names (roles.py prove). The board stub lists FAKE_RUNNING as the running card.
WM=$(jq -r '.worker_markers[0]' "$FX/docs/hermes-local/roles.json")
bound() {  # bound <card>: the board record of a card whose open run is bound to this script's process
  jq -nc --arg c "$1" --arg a "$FAKE_ASSIGNEE" --argjson pid $$ --arg fp "$(python3 -I -c 'import sys; sys.path.insert(0, "/workspace/bin"); import roles; print(roles.fingerprint(int(sys.argv[1])))' $$)" \
    '{task: {id: $c, assignee: $a, project: "qa-proj", status: "running", body: ""}, runs: [{id: 7, ended_at: null}],
      events: [{kind: "claimed", run_id: 7, payload: {lock: "h:1"}}, {kind: "worker_bound", run_id: 7, payload: {pid: $pid, claim_lock: "h:1", started_at: $fp}}]}'; }
n=$(runs); check 3 "W7b-VAL-01: a worker marker is set and the board proves no card for the caller: refused" env "$WM=t_aaaa0911" sh -c "echo hi | $E t_aaaa0911 review why"
ok 'grep -q "STL-GRD-604" "$T/err" && [ "$(runs)" = "$n" ] && [ -z "$(q t_aaaa0911)" ]' "W7b-VAL-01: ... with STL-GRD-604, no model call, nothing queued"
check 3 "W7b-VAL-01: a worker proven on one card names another card: refused" env FAKE_RUNNING=t_aaaa0912 FAKE_SHOW_RAW="$(bound t_aaaa0912)" sh -c "echo hi | $E t_aaaa0913 review why"
ok 'grep -q "STL-GRD-604.*t_aaaa0912" "$T/err" && [ "$(runs)" = "$n" ] && [ -z "$(q t_aaaa0913)" ]' "W7b-VAL-01: ... with STL-GRD-604 naming the card it is proven on, no model call, nothing queued (a drain would replay it as the supervisor)"
check 3 "E-DC-04: a worker (marker set) proven on a card names that card: refused too" env "$WM=t_aaaa0912" FAKE_RUNNING=t_aaaa0912 FAKE_SHOW_RAW="$(bound t_aaaa0912)" sh -c "echo hi | $E t_aaaa0912 review why"
ok 'grep -q "STL-GRD-604.*only the supervisor" "$T/err" && [ "$(runs)" = "$n" ] && [ -z "$(q t_aaaa0912)" ]' "E-DC-04: ... with STL-GRD-604, no model call, nothing queued"
setlimit HAIKU_MAX_PER_DAY 0
check 3 "T13: zeroed HAIKU_MAX_PER_DAY refused" sh -c "echo hi | $E t_aaaa0001 judge zeroed"
pf=$(jq -r 'select(.card == "t_aaaa0001") | .prompt_file' "$Q" 2>/dev/null)
ok '[ "$(q t_aaaa0001)" = "queued," ] && [ "$(nalerts t_aaaa0001)" = 1 ] && grep -B1 "Claude Haiku for card t_aaaa0001" "$T/sup/sends" | grep -q "\[STL-LIM-401\]\*\*$" && grep -q "t_aaaa0001 escalate.sh LIMIT.*recorded in the queue as q_.*; run bin/escalate-drain.sh" "$T/sup/comments"' "F28: zeroed limit: one queue entry, one #alerts line, the card comment names the drain"
ok '[ -s "$pf" ] && jq -s -e --arg r "$RA" "any(.[]; .card == \"t_aaaa0001\" and .reason == \"LIMIT\" and .purpose == \"judge\" and .role == \$r and .rung == 1 and (has(\"model\") | not) and .call_reason == \"zeroed\" and (.created | length > 0))" "$Q" >/dev/null' "F28, E: the entry records card, purpose, role, rung, arguments, reason LIMIT, created, and no model; its prompt file is kept"
id=$(qid t_aaaa0001); n=$(runs)
$D --replay "$id" >/dev/null 2>&1
ok '[ "$(q t_aaaa0001)" = "queued," ] && [ "$(nalerts t_aaaa0001)" = 1 ] && [ "$(runs)" = "$n" ] && [ -s "$pf" ]' "drain while the limit is still zero: left queued, no run, no new entry, no new alert"
setlimit HAIKU_MAX_PER_DAY 40
FAKE_SLEEP=1 $D --replay "$id" >/dev/null 2>&1 & sleep 0.3; $D --replay "$id" >/dev/null 2>&1; wait
$D --replay "$id" >/dev/null 2>&1
ok '[ "$(runs)" = $((n + 1)) ] && [ "$(q t_aaaa0001)" = "replayed," ] && [ ! -e "$pf" ] && [ "$(nalerts t_aaaa0001)" = 1 ]' "double replay (two at once, then a third): one run, state replayed, prompt removed, still one alert"
check 75 "T15: forced pool, low-risk card" env ESCALATE_FORCE_POOL_EXHAUSTED=1 sh -c "echo hi | $E t_aaaa0002 review lowrisk"
ok '[ "$(q t_aaaa0002)" = "queued," ] && [ "$(nalerts t_aaaa0002)" = 1 ] && grep -B1 "a Sonnet request for card t_aaaa0002" "$T/sup/sends" | grep -q "\[STL-LIM-402\]\*\*$" && jq -s -e "any(.[]; .card == \"t_aaaa0002\" and .event == \"QUEUED\") and any(.[]; .card == \"t_aaaa0002\" and .event == \"POOL_EXHAUSTED\") and any(.[]; .card == \"t_aaaa0002\" and .event == \"WALK\")" "$T/sup/escalations.log" >/dev/null' "F29, D83 via the resolver: forced pool exhaustion on a low-risk card: the next rung is asked (WALK), none runs, QUEUED, one #alerts line"
jq -c 'if .card == "t_aaaa0002" then .created = "2026-10-01T00:00:00Z" else . end' "$Q" > "$Q.tmp" && mv "$Q.tmp" "$Q"
check 75 "forced pool, card that is done before the drain" env ESCALATE_FORCE_POOL_EXHAUSTED=1 sh -c "echo hi | $E t_aaaa0003 review done-later"
n=$(runs); pf2=$(jq -r 'select(.card == "t_aaaa0002") | .prompt_file' "$Q")
$D --replay "$(qid t_aaaa0002)" >/dev/null 2>&1; FAKE_STATUS=done $D --replay "$(qid t_aaaa0003)" >/dev/null 2>&1
ok '[ "$(q t_aaaa0002)" = "stale," ] && [ "$(q t_aaaa0003)" = "stale," ] && [ "$(runs)" = "$n" ] && [ ! -e "$pf2" ]' "stale: older than QUEUE_MAX_AGE_HOURS, or the card is done: marked stale, skipped, prompt removed"
setlimit HAIKU_MAX_PER_DAY 0; setlimit QUEUE_MAX "$(jq -s '[.[] | select(.state == "queued")] | length' "$Q")"
check 3 "queue full: refused" sh -c "echo hi | $E t_aaaa0004 judge full"
check 3 "queue full: refused again" sh -c "echo hi | $E t_aaaa0005 judge full"
ok '[ -z "$(q t_aaaa0004)$(q t_aaaa0005)" ] && [ "$(nalerts "\[STL-LIM-403\]\*\*$")" = 1 ] && ! ls "$T/sup/state"/prompt-*-t_aaaa000[45]-* >/dev/null 2>&1' "queue cap: beyond QUEUE_MAX refused unqueued, one alert, no prompt file left"
setlimit QUEUE_MAX 50
check 3 "for the drop" sh -c "echo hi | $E t_aaaa0006 judge drop"
pf3=$(jq -r 'select(.card == "t_aaaa0006") | .prompt_file' "$Q")
ok '$D --list | grep -q "$(qid t_aaaa0006).*queued.*LIMIT.*t_aaaa0006"' "--list shows id, state, reason and card"
$D --drop "$(qid t_aaaa0006)" >/dev/null 2>&1
ok '[ "$(q t_aaaa0006)" = "dropped," ] && [ ! -e "$pf3" ]' "--drop: dropped, prompt removed"
ok '( for f in "$T/sup/state"/prompt-*.txt; do [ -e "$f" ] || continue; jq -s -e --arg f "$f" "any(.[]; .prompt_file == \$f and (.state == \"queued\" or .state == \"owner\"))" "$Q" >/dev/null || exit 1; done )' "F16: no prompt file outlives its call (FAIL and OK paths) except a queued or owner entry's"
ok '[ "$(ESCALATE_SUP_DIR=$T/sup bash -c "$D --replay nosuch; echo \$?" 2>/dev/null | tail -1)" = 2 ] && [ "$($D 2>/dev/null; echo $?)" = 2 ]' "drain: unknown id or no arguments is a usage error"
# Review M2: a replay that fails for a transient reason (kanban show fails: exit 2) keeps the entry and its prompt.
setlimit HAIKU_MAX_PER_DAY 0
check 3 "for the transient replay" sh -c "echo hi | $E t_aaaa0007 judge transient"
setlimit HAIKU_MAX_PER_DAY 40; pf7=$(jq -r 'select(.card == "t_aaaa0007") | .prompt_file' "$Q")
FAKE_SHOW_FAIL=1 $D --replay "$(qid t_aaaa0007)" >/dev/null 2>&1
ok '[ "$(q t_aaaa0007)" = "queued," ] && [ -s "$pf7" ]' "M2: exit 2 on replay: left queued with its prompt"
# Review H2: extra claude args can never override escalate.sh's model, budget or permissions.
n=$(runs)
for a in "--model opus" "--model=opus" "--fallback-model haiku" "--max-budget-usd 100" "--permission-mode bypassPermissions" "--dangerously-skip-permissions" "--settings {}" "--add-dir /" "--allowedTools Bash"; do
  check 2 "extra arg refused: $a" sh -c "echo hi | $E t_12345678 review why -- $a"
done
ok '[ "$(runs)" = "$n" ]' "H2: no claude run for any of them"
check 2 "an extra arg outside that list is refused too: no caller of the stack passes one (W5-RT6-01)" sh -c "echo hi | $E t_12345678 review why -- --verbose"
echo "events: $(jq -r .event "$T/sup/escalations.log" | sort | uniq -c | tr -s ' \n' ' ')"
# D42: `timeout 0` disables the timeout, so CALL_TIMEOUT 0, empty or non-numeric must fall back to 600 with a warning.
mkdir -p "$T/tbin"; printf '#!/bin/sh\necho "$1" >> "%s/timeout_args"\nshift\nexec "$@"\n' "$T" > "$T/tbin/timeout"; chmod +x "$T/tbin/timeout"
for v in 0 "" abc -5 5x; do
  setlimit CALL_TIMEOUT "$v"; : > "$T/timeout_args"
  ok '[ "$(PATH="$T/tbin:$PATH" sh -c "echo hi | $E t_12345678 judge to 2>$T/err1" >/dev/null; echo $?)" = 0 ] && [ "$(cat "$T/timeout_args")" = 600 ] && grep -q "warning: CALL_TIMEOUT=.$v. is not a positive duration" "$T/err1" && [ "$(last .event)" = OK ] && jq -s -e "any(.[]; .event == \"WARN\" and (.detail | test(\"CALL_TIMEOUT\")))" "$T/sup/escalations.log" >/dev/null' "D42: CALL_TIMEOUT='$v' uses 600 and warns on stderr and in the log"
done
for v in 30 10m; do
  setlimit CALL_TIMEOUT "$v"; : > "$T/timeout_args"; : > "$T/err1"
  ok '[ "$(PATH="$T/tbin:$PATH" sh -c "echo hi | $E t_12345678 judge to 2>$T/err1" >/dev/null; echo $?)" = 0 ] && [ "$(cat "$T/timeout_args")" = "$v" ] && ! grep -q CALL_TIMEOUT "$T/err1"' "D42: CALL_TIMEOUT=$v is passed to timeout unchanged, no warning"
done
setlimit CALL_TIMEOUT 600

# Ultrareview finding 3: an over-limit Haiku call releases haiku.lock before its alert and card comment.
setlimit HAIKU_MAX_PER_DAY 0; setlimit QUEUE_MAX 50
H="$T/hold"
FAKE_SEND_HOLD="$H" sh -c "echo hi | $E t_bbbb0001 judge slow-alert" >/dev/null 2>&1 & a=$!
for _ in $(seq 100); do [ -e "$H.in" ] && break; sleep 0.1; done
ok '[ -e "$H.in" ]' "control: the over-limit call reached its alert"
ok 'flock -n "$T/sup/state/haiku.lock" true' "the Haiku lock is free while the alert is being sent"
timeout 10 sh -c "echo hi | $E t_bbbb0002 judge second" >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 3 ]' "a second over-limit Haiku call is refused at once, not held behind the slow alert (exit $rc)"
touch "$H.go"; wait "$a"; rc=$?
ok '[ "$rc" = 3 ]' "control: the slow call still ends refused once its alert returns (exit $rc)"
# E-DC-07 (was T15 reroute): an escalation rung is never sent to the pool-exhausted fallback runner, whatever the fallback config,
# the card's risk or the prompt: the call queues (the runner is not judged by the resolver).
cat >"$T/bin/fbrun" <<'S'
#!/usr/bin/env bash
cat >/dev/null; echo "$*" >>"$ESCALATE_SUP_DIR/fb_calls"; printf '{"model_used":"fixture-free-model","text":"fallback answer"}\n'
S
chmod +x "$T/bin/fbrun"
jq -n --arg r "$T/bin/fbrun" '{schema_version: 1, enabled: true, runner: $r}' >"$T/fbcfg.json"
out=$(echo hi | FALLBACK_CONFIG="$T/fbcfg.json" FAKE_BODY='Rename a variable in the docs.' ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_cccc0001 review lowrisk-fb 2>/dev/null); rc=$?
ok '[ "$rc" = 75 ] && [ ! -s "$T/sup/fb_calls" ] && [ "$(q t_cccc0001)" = "queued," ] && [ -z "$out" ]' "E-DC-07: a low-risk card, the pool exhausted, the fallback runner enabled: exit 75, the runner is never called, queued (exit $rc)"
# F2 W7b: the card must name its project before any model call: a card whose body is not text still names one; a card that is not
# JSON at all is refused before the resolver (the case after it)
echo hi | FAKE_SHOW_RAW="{\"task\":{\"assignee\":\"$FAKE_ASSIGNEE\",\"project\":\"$FAKE_PROJECT\",\"body\":{\"not\":\"text\"}}}" ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_eeee0009 review "unparsable-card" >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 75 ] && [ ! -s "$T/sup/fb_calls" ] && [ "$(q t_eeee0009)" = "queued," ]' "S6D-04: a card whose body is not text still queues on an exhausted pool, never rerouted (exit $rc)"
r0=$(runs); echo hi | FAKE_SHOW_RAW='not json at all' ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_eeee0014 review "not-json-card" >/dev/null 2>"$T/err1"; rc=$?
ok '[ "$rc" = 3 ] && [ ! -s "$T/sup/fb_calls" ] && [ "$(runs)" = "$r0" ] && [ -z "$(q t_eeee0014)" ] && grep -q "STL-MDL-711" "$T/err1" && ! jq -e "select(.card == \"t_eeee0014\" and .event == \"START\")" "$T/sup/escalations.log" >/dev/null' "W7b: a card that is not JSON names no caller and no project: refused with STL-MDL-711 before any model call or fallback (exit $rc)"

# W5: the two fallback numbers (call timeout, queue maximum) are the settings registry defaults, read through bin/stella_data.py.
# A scratch root (STELLA_ROOT) holds a registry whose defaults differ from the shipped ones, so the source is proven.
cp "$T/sup/limits.env" "$T/limits.keep"; R="$T/reg"; mkdir -p "$R"; cp -r "$FX/." "$R/"
REG=$(jq -r '.files[] | select(.id == "settings") | .path' /workspace/.stella/data-files.json)   # the registry's path comes from the data index
setdef() { jq --arg k "$1" --argjson v "$2" '(.entries[] | select(.key == $k) | .default) = $v' "/workspace/$REG" >"$R/$REG"; }
setdef CALL_TIMEOUT 123; setlimit CALL_TIMEOUT abc; setlimit HAIKU_MAX_PER_DAY 40; : > "$T/timeout_args"
ok '[ "$(STELLA_ROOT=$R PATH="$T/tbin:$PATH" sh -c "echo hi | $E t_12345678 judge to 2>$T/err1" >/dev/null; echo $?)" = 0 ] && [ "$(cat "$T/timeout_args")" = 123 ] && grep -q "using 123" "$T/err1"' "W5: a bad CALL_TIMEOUT falls back to the registry default (123 in the scratch registry), not a literal"
setlimit CALL_TIMEOUT 600; setdef QUEUE_MAX 0; sed -i '/^QUEUE_MAX=/d' "$T/sup/limits.env"; setlimit HAIKU_MAX_PER_DAY 0; nq=$(jq -s '[.[] | select(.state == "queued")] | length' "$Q")
check 3 "W5: QUEUE_MAX unset uses the registry default (0 in the scratch registry): over limit, exit 3" env STELLA_ROOT=$R sh -c "echo hi | $E t_aaaa0101 judge why"
ok '[ "$(jq -s "[.[] | select(.state == \"queued\")] | length" "$Q")" = "$nq" ]' "W5: ... and nothing was queued"
n=$(runs); echo '{' >"$R/$REG"
check 2 "W5: unreadable registry, QUEUE_MAX unset: refused" env STELLA_ROOT=$R sh -c "echo hi | $E t_aaaa0102 judge why"
ok 'grep -q STL-CFG-310 "$T/err" && [ "$(runs)" = "$n" ]' "W5: ... with STL-CFG-310 and no claude run"
cp "$T/limits.keep" "$T/sup/limits.env"; setlimit CALL_TIMEOUT abc
check 2 "W5: unreadable registry, bad CALL_TIMEOUT: refused, no call without a timeout" env STELLA_ROOT=$R sh -c "echo hi | $E t_aaaa0103 judge why"
ok 'grep -q STL-CFG-310 "$T/err" && [ "$(runs)" = "$n" ]' "W5: ... with STL-CFG-310 and no claude run"
# W5 r2 (E1, E2): a limit that is set but outside the registry's range is handled like a bad timeout; the queue count is one number
cp "$T/limits.keep" "$T/sup/limits.env"; cp "$Q" "$T/queue.keep"; setlimit HAIKU_MAX_PER_DAY 0; setlimit QUEUE_MAX abc
for i in $(seq 50); do printf '{"id":"q_full_%s","card":"t_aaaa0000","state":"queued","prompt_file":"/nonexistent"}\n' "$i"; done >"$Q"
check 3 "E1: QUEUE_MAX=abc with 50 queued (the registry default): refused over the limit" sh -c "echo hi | $E t_aaaa0201 judge why 2>$T/err1"
ok '[ "$(jq -s "[.[] | select(.state == \"queued\")] | length" "$Q")" = 50 ] && grep -q "QUEUE_MAX=.abc" "$T/err1" && ! grep -q "expression" "$T/err1" "$T/err"' "E1: ... nothing queued beyond 50, a warning names the bad QUEUE_MAX, no shell error"
setlimit QUEUE_MAX 0; rm -f "$Q"
check 3 "E1: QUEUE_MAX=0 and no queue file yet: refused over the limit" sh -c "echo hi | $E t_aaaa0202 judge why"
ok '[ ! -s "$Q" ] && ! grep -q "expression" "$T/err"' "E1: ... nothing queued, no shell error (the count is one number)"
cp "$T/queue.keep" "$Q"; setlimit HAIKU_MAX_PER_DAY 40; setlimit QUEUE_MAX 50; setlimit CALL_TIMEOUT 99999999d; : >"$T/timeout_args"
ok '[ "$(PATH="$T/tbin:$PATH" sh -c "echo hi | $E t_aaaa0203 judge why 2>$T/err1" >/dev/null; echo $?)" = 0 ] && [ "$(cat "$T/timeout_args")" -le 86400 ] && grep -q "using 600" "$T/err1"' "E1: CALL_TIMEOUT above the registry maximum gets the registry default (600) and a warning"
# E2: the refusal prints the catalog code itself when the catalog tool fails
cp "$T/limits.keep" "$T/sup/limits.env"; mkdir -p "$T/pbin"; py=$(command -v python3)
printf '#!/bin/sh\ncase "$*" in *alert_catalog*) exit 1;; esac\nexec %s "$@"\n' "$py" >"$T/pbin/python3"; chmod +x "$T/pbin/python3"
R="$T/reg"; mkdir -p "$R"; cp -r "$FX/." "$R/"; echo '{' >"$R/$REG"
check 2 "E2: unreadable registry and a failing catalog tool: still refused" env STELLA_ROOT=$R PATH="$T/pbin:$PATH" sh -c "echo hi | $E t_aaaa0204 judge why"
ok 'grep -q "^STL-CFG-310 " "$T/err"' "E2: ... and the refusal prints STL-CFG-310 and the problem itself"
cp "$T/limits.keep" "$T/sup/limits.env"; rm -rf "$R"

# W5 r3 (F4, F5, F6): a refusal or a lost call is never silent; a queue file is never trusted blindly and never lied about
cp "$T/limits.keep" "$T/sup/limits.env"; : >"$T/sup/sends"; rm -f "$T/sup/state/alert-"*.stamp; R="$T/reg2"; mkdir -p "$R"; cp -r "$FX/." "$R/"; echo '{' >"$R/$REG"
check 2 "F4: unreadable registry: refused" env STELLA_ROOT=$R sh -c "echo hi | $E t_aaaa0301 judge why"
ok '[ "$(nalerts "\\[STL-CFG-310\\]\\*\\*\$")" = 1 ] && grep -q "t_aaaa0301" "$T/sup/sends" && grep -q "^STL-CFG-310\|STL-CFG-310" "$T/err"' "F4: ... the refusal raises one #alerts line (STL-CFG-310, the card named) beside the coded stderr line; nothing is queued (the queue bound is what could not be read)"
rm -rf "$R"; cp "$T/limits.keep" "$T/sup/limits.env"; setlimit HAIKU_MAX_PER_DAY 0; setlimit QUEUE_MAX 2
qline() { printf '{"id":"q_%s","card":"t_aaaa0000","model":"haiku","purpose":"judge","reason":"LIMIT","created":"2026-01-01T00:00:00Z","state":"queued","prompt_file":"/nonexistent"}\n' "$1"; }
{ qline c1; qline c2; printf '{"id":"q_cut","card":"t_aaaa0000","sta\n'; } >"$Q"; : >"$T/sup/sends"; rm -f "$T/sup/state/alert-"*.stamp; : >"$T/sup/comments"
check 3 "F5: one cut line in the queue file, two entries, QUEUE_MAX=2: refused" sh -c "echo hi | $E t_aaaa0302 judge why 2>$T/err1"
ok '[ "$(wc -l <"$Q")" = 3 ] && grep -q "queue.jsonl" "$T/err1" && grep -q "NOT queued" "$T/err1" && ! grep -q "recorded in the queue" "$T/err1" "$T/sup/comments" && [ "$(nalerts "\\[STL-LIM-405\\]\\*\\*\$")" = 1 ] && grep -q "NOT queued" "$T/sup/comments"' "F5/RT2-03: ... the file is not read as empty: nothing is added, one warning names the file, the card note and the #alerts line say it was not queued"
qline c1 >"$Q"; printf '{"id":"q_cut' >>"$Q"; chmod 444 "$Q"; : >"$T/sup/sends"
check 3 "F5/RT2-04: queue file that cannot be written (read-only): refused" sh -c "echo hi | $E t_aaaa0303 judge why 2>$T/err1"
ok '! grep -q "recorded in the queue" "$T/err1" && grep -q "NOT queued" "$T/err1"' "F5/RT2-04: ... no 'recorded in the queue' claim"
rm -f "$Q"; touch "$Q"; chmod 000 "$Q"; : >"$T/sup/sends"; rm -f "$T/sup/state/alert-"*.stamp
check 3 "F5/RT2-04: queue file that cannot be read or written (mode 000): refused" sh -c "echo hi | $E t_aaaa0304 judge why 2>$T/err1"
chmod 600 "$Q"; ok '! grep -q "recorded in the queue" "$T/err1" && grep -q "NOT queued" "$T/err1" && [ "$(nalerts "\\[STL-LIM-405\\]\\*\\*\$")" = 1 ]' "F5/RT2-04: ... no 'recorded' claim, one #alerts line"
{ qline d1 | tr -d '\n'; } >"$Q"; setlimit QUEUE_MAX 5
check 3 "F5: a valid last line without a newline, then a new entry" sh -c "echo hi | $E t_aaaa0305 judge why"
ok '[ "$(wc -l <"$Q")" = 2 ] && [ "$(jq -sc "length" "$Q")" = 2 ]' "F5: ... the new entry is not swallowed by the line before it (two whole JSON lines)"
rm -f "$Q"
check 3 "F5/VER2-04: no queue file yet, room in the queue: the first call is queued (the product creates the file itself)" sh -c "echo hi | $E t_aaaa0306 judge why"
ok '[ "$(jq -sc "length" "$Q")" = 1 ]' "F5/VER2-04: ... exactly one entry"
# the drain reads past a line it cannot parse, and keeps it
{ qline e1; printf 'not json at all\n'; qline e2; } >"$Q"
ok '[ "$($D --list 2>"$T/err1" | cut -f1 | tr "\n" ,)" = "q_e1,q_e2," ] && grep -q "1 line(s)" "$T/err1"' "F6/RT2-03: --list shows the entries before and after an unparsable line, and warns once"
ok '$D --drop q_e2 | grep -q dropped && [ "$(sed -n 2p "$Q")" = "not json at all" ] && [ "$(sed -n 3p "$Q" | jq -r .state)" = dropped ]' "F6/RT2-03: --drop of an entry after the line works and leaves the line as it was"
rm -f "$Q"

# W5 r4 (V4): a standing condition (bad registry, bad queue file) alerts once an hour; every lost or refused call keeps its own log line;
# the registry is read after the usage checks and never alerts for a replay. Written before the fix.
nlog() { jq -r --arg e "$1" 'select(.event == $e) | .card' "$T/sup/escalations.log" | grep -c -- "$2" || true; }
stamps() { rm -f "$T/sup/state/alert-"*.stamp; : >"$T/sup/sends"; }
cp "$T/limits.keep" "$T/sup/limits.env"; R="$T/reg4"; mkdir -p "$R"; cp -r "$FX/." "$R/"; echo '{' >"$R/$REG"; stamps
check 2 "V4: unreadable registry, a replayed call: refused" env STELLA_ROOT=$R ESCALATE_REPLAY=q_zz sh -c "echo hi | $E t_aaaa0401 judge why"
ok '[ "$(nalerts t_aaaa0401)" = 0 ]' "V4: ... no #alerts line for a replay"
check 2 "V4: unreadable registry, a call with an unknown card: refused as a usage error" env STELLA_ROOT=$R sh -c "echo hi | $E t_00000000 judge why"
ok 'grep -q "not found" "$T/err" && ! grep -q STL-CFG-310 "$T/err" && [ ! -s "$T/sup/sends" ]' "V4: ... the usage check comes first: no registry refusal, no alert"
check 2 "V4: unreadable registry, first call" env STELLA_ROOT=$R sh -c "echo hi | $E t_aaaa0402 judge why"
check 2 "V4: unreadable registry, second call" env STELLA_ROOT=$R sh -c "echo hi | $E t_aaaa0403 judge why"
ok '[ "$(nalerts "\\[STL-CFG-310\\]\\*\\*\$")" = 1 ] && [ "$(nlog SETTING_UNREADABLE t_aaaa040[23])" = 2 ]' "V4: ... two refusals, one #alerts line (once an hour), one log line each"
rm -rf "$R"; cp "$T/limits.keep" "$T/sup/limits.env"; setlimit HAIKU_MAX_PER_DAY 0; setlimit QUEUE_MAX 5
{ qline f1; printf '{"id":"q_cut","card":"t_aaaa0000","sta\n'; } >"$Q"; stamps; : >"$T/sup/comments"
check 3 "V4: a bad queue line, first call" sh -c "echo hi | $E t_aaaa0404 judge why"
check 3 "V4: a bad queue line, second call" sh -c "echo hi | $E t_aaaa0405 judge why"
ok '[ "$(nalerts "\\[STL-LIM-405\\]\\*\\*\$")" = 1 ] && [ "$(nalerts "\\[STL-CFG-310\\]")" = 0 ] && [ "$(nlog NOT_QUEUED t_aaaa040[45])" = 2 ] && [ "$(grep -c "NOT queued" "$T/sup/comments")" = 2 ]' "V4: ... two lost calls, one STL-LIM-405 #alerts line (once an hour), a NOT_QUEUED log line and a card note each"
ok 'python3 -I /workspace/bin/alert_catalog.py explain STL-LIM-405 | grep -qi "lost"' "V4: STL-LIM-405 is in the catalog and says the call was lost"
for i in 1 2 3 4 5; do qline "g$i"; done >"$Q"; stamps
check 3 "V4: the queue is full" sh -c "echo hi | $E t_aaaa0406 judge why"
ok '[ "$(nlog NOT_QUEUED t_aaaa0406)" = 1 ]' "V4: ... the lost call has its own NOT_QUEUED log line"
rm -f "$Q"; cp "$T/limits.keep" "$T/sup/limits.env"

# W5 r5 (RT4-01): no file of the state folder is opened for writing through a link; the link is refused before the open
V="$T/victim"; echo keep >"$V"; setlimit HAIKU_MAX_PER_DAY 0; setlimit QUEUE_MAX 5; stamps; ln -s "$V" "$Q"
check 3 "P1: the queue file is a link" sh -c "echo hi | $E t_aaaa0501 judge why"
ok '[ "$(cat "$V")" = keep ] && [ "$(nlog NOT_QUEUED t_aaaa0501)" = 1 ] && [ "$(nalerts "\\[STL-LIM-405\\]\\*\\*\$")" = 1 ]' "P1: ... nothing written through it, NOT_QUEUED, one STL-LIM-405 line"
rm -f "$Q" "$T/sup/state/queue.lock"; ln -s "$V" "$T/sup/state/queue.lock"; stamps
check 3 "P1: the queue lock is a link" sh -c "echo hi | $E t_aaaa0502 judge why"
ok '[ "$(cat "$V")" = keep ] && [ ! -e "$Q" ] && [ "$(nlog NOT_QUEUED t_aaaa0502)" = 1 ] && [ "$(nalerts "\\[STL-LIM-405\\]\\*\\*\$")" = 1 ]' "P1: ... not truncated, nothing queued, NOT_QUEUED, one STL-LIM-405 line"
rm -f "$T/sup/state/queue.lock"; cp "$T/limits.keep" "$T/sup/limits.env"; setlimit OPUS_MAX_CONCURRENT 1; rm -f "$T/sup/state/opus.1.lock"; ln -s "$V" "$T/sup/state/opus.1.lock"
check 3 "P1: the only slot lock is a link: no slot" sh -c "echo hi | $E t_aaaa0503 plan why"
ok '[ "$(cat "$V")" = keep ]' "P1: ... the slot lock's target is not truncated"
rm -f "$T/sup/state/opus.1.lock" "$T/sup/state/haiku.lock"; ln -s "$V" "$T/sup/state/haiku.lock"
check 3 "P1: the Haiku lock is a link" sh -c "echo hi | $E t_aaaa0504 judge why"
rm -f "$T/sup/state/haiku.lock"; C1="$T/sup/state/haiku-$(date -u +%F).count"; rm -f "$C1"; ln -s "$V" "$C1"
check 3 "P1: the Haiku counter is a link" sh -c "echo hi | $E t_aaaa0505 judge why"
ok '[ "$(cat "$V")" = keep ]' "P1: ... neither the Haiku lock's nor the counter's target is written"
rm -f "$C1" "$Q"; cp "$T/limits.keep" "$T/sup/limits.env"

# W5 r6 (VER5-02): the prompt_file of a queue line is used only when it is a regular, unlinked prompt-*.txt directly in the state folder
pline() { printf '{"id":"q_%s","card":"t_aaaa0000","role":"'"$RA"'","rung":1,"purpose":"judge","call_reason":"why","claude_args":[],"reason":"LIMIT","created":"%s","state":"queued","prompt_file":"%s"}\n' "$1" "$(date -u +%FT%TZ)" "$2"; }
ln -s "$V" "$T/sup/state/prompt-link.txt"; { pline p1 "$V"; pline p2 "$V"; pline p3 "$T/sup/state/prompt-link.txt"; pline p4 "$V"; } >"$Q"; n=$(runs)
$D --replay q_p1 >/dev/null 2>&1; $D --drop q_p2 >/dev/null 2>&1; $D --all >/dev/null 2>&1
ok '[ "$(cat "$V")" = keep ] && [ "$(runs)" = "$n" ] && [ "$(jq -r .state "$Q" | tr "\n" ,)" = "stale,dropped,stale,stale," ]' "Q3: a prompt_file outside the state folder, or a link in it (--replay, --drop, --all): not read, not removed, no model call, the entries stale or dropped"
rm -f "$T/sup/state/prompt-link.txt" "$Q"
# E: the drain and the two new states. A queued entry whose replay finds no rung left (exit 4) is kept for the owner (state owner, its
# prompt kept), never replayed again; a legacy entry (a model and no role, written before item E) is never replayed with that model;
# --drop removes either.
echo hi >"$T/sup/state/prompt-q_own.txt"; echo hi >"$T/sup/state/prompt-q_leg.txt"
{ pline own "$T/sup/state/prompt-q_own.txt" | jq -c '.card = "t_aaaa0951"'
  printf '{"id":"q_leg","card":"t_aaaa0952","model":"opus","purpose":"rescue","call_reason":"why","claude_args":[],"reason":"LIMIT","created":"%s","state":"queued","prompt_file":"%s"}\n' "$(date -u +%FT%TZ)" "$T/sup/state/prompt-q_leg.txt"; } >"$Q"
rungs t_aaaa0951 "$RA" 2; n=$(runs); $D --all >"$T/dr1" 2>&1; $D --replay q_own >>"$T/dr1" 2>&1; $D --replay q_leg >>"$T/dr1" 2>&1; rm -f "$T/sup/state/rungs.json"
ok '[ "$(runs)" = "$n" ] && [ "$(jq -r .state "$Q" | tr "\n" ,)" = "owner,legacy," ] && [ -s "$T/sup/state/prompt-q_own.txt" ] && [ -s "$T/sup/state/prompt-q_leg.txt" ] && grep -q "q_own: no rung left (STL-MDL-731)" "$T/dr1" && grep -q "q_leg: legacy" "$T/dr1"' "E: drain: a replay past the last rung (exit 4) keeps the entry for the owner, a legacy entry is marked legacy; no run, both prompts kept, a second replay does nothing"
ok '$D --list | grep -q "q_own	owner.*$RA rung 1 (judge)" && $D --list | grep -q "q_leg	legacy.*opus (rescue)"' "E: --list shows the owner entry with its role and rung, the legacy one with its model"
$D --drop q_own >/dev/null 2>&1; $D --drop q_leg >/dev/null 2>&1
ok '[ "$(jq -r .state "$Q" | tr "\n" ,)" = "dropped,dropped," ] && [ ! -e "$T/sup/state/prompt-q_own.txt" ] && [ ! -e "$T/sup/state/prompt-q_leg.txt" ]' "E: --drop removes an owner and a legacy entry and their prompts"
rm -f "$Q"

# W5 r6 (VER5-05): a state folder that is itself a link is refused by both scripts before anything is made in it
mkdir "$T/outside"; mv "$T/sup/state" "$T/state.keep"; ln -s "$T/outside" "$T/sup/state"
check 2 "Q6: the state folder is a link: the call is refused" sh -c "echo hi | $E t_aaaa0601 judge why"
check 2 "Q6: ... and so is the drain" $D --list
ok '[ -z "$(ls -A "$T/outside")" ]' "Q6: ... nothing is made in the folder it points at"
rm -f "$T/sup/state"; mv "$T/state.keep" "$T/sup/state"

# Round 7 (W5-RT6-01, W5-RT6-03), in a state folder of its own: no extra argument reaches the model command, direct or from a
# queue line, and no queued call is lost because a field is long.
S7="$T/sup7"; mkdir -p "$S7/state"; cp /workspace/.supervisor/limits.env "$S7/"; echo canary >"$T/canary"; Q7="$S7/state/queue.jsonl"
runs7() { cat "$S7/claude_n" 2>/dev/null || echo 0; }
st7() { jq -r --arg id "$1" 'select(.id == $id) | .state' "$Q7" | tail -1; }
plant7() {  # plant7 <id> <jq update of a good entry> [file for $r]
  echo hi >"$S7/state/prompt-$1.txt"
  jq -nc --arg id "$1" --arg pf "$S7/state/prompt-$1.txt" --arg c "$(date -u +%FT%TZ)" --arg f "$T/canary" --rawfile r "${3:-/dev/null}" --arg role "$CR" '{id: $id, card: "t_aaaa0701",
    role: $role, rung: 1, purpose: "review", call_reason: "why", claude_args: [], reason: "LIMIT", detail: "x", created: $c, state: "queued", prompt_file: $pf} | '"$2" >>"$Q7"; }
export ESCALATE_SUP_DIR="$S7"
for a in "--system-prompt-file $T/canary" "--mcp-config {}" "--verbose" "why2"; do
  check 2 "S1: a direct call with the extra argument '${a%% *}' is refused" sh -c "echo hi | $E t_12345678 review why -- $a"
done
ok '[ "$(runs7)" = 0 ]' "S1: ... and the model command is not started for any of them"
plant7 q_s1 '.claude_args = ["--system-prompt-file", $f]'; $D --replay q_s1 >/dev/null 2>&1
ok '[ "$(runs7)" = 0 ] && [ "$(st7 q_s1)" = queued ] && [ -s "$S7/state/prompt-q_s1.txt" ]' "S1: a queue line's extra argument is refused on a replay: no run, left queued with its prompt"
plant7 q_s1ok .; $D --replay q_s1ok >/dev/null 2>&1
ok '[ "$(runs7)" = 1 ] && [ "$(st7 q_s1ok)" = replayed ]' "S1: a queue line without extra arguments (the form every caller queues) is replayed"
check 0 "S1: a direct call that ends in a bare -- still runs" sh -c "echo hi | $E t_12345678 review why --"
head -c 8192 /dev/zero | tr '\0' r >"$T/r8192"; n=$(runs7)
check 0 "S2: a reason of 8192 characters runs" sh -c "echo hi | $E t_12345678 review $(cat "$T/r8192")"
check 2 "S2: a longer reason is refused, also where the call would be queued" env ESCALATE_FORCE_POOL_EXHAUSTED=1 sh -c "echo hi | $E t_aaaa0702 review $(cat "$T/r8192")r"
ok '[ "$(runs7)" = $((n + 1)) ] && ! grep -q t_aaaa0702 "$Q7" && [ -z "$(ls "$S7/state" | grep -- "-t_aaaa0702-")" ] && [ "$(tail -1 "$S7/escalations.log" | jq -r "[.event, (.reason | length < 200)] | join(\" \")")" = "USAGE true" ]' "S2: ... nothing queued, no prompt file left, one short log line"
head -c 200000 /dev/zero | tr '\0' r >"$T/r200k"; plant7 q_s2 '.call_reason = $r' "$T/r200k"; n=$(runs7); out=$($D --replay q_s2 2>&1)
ok '[ "$(runs7)" = "$n" ] && [ "$(st7 q_s2)" = queued ] && [ -s "$S7/state/prompt-q_s2.txt" ] && grep -q "left in the queue" <<<"$out"' "S2: a replay that cannot start (a field over the argument limit) is left queued with its prompt, and says so"
# Round 8 (W5-RT7-02, W5-VER7-01). A two-byte letter 8192 times: the drain's read of that line gives back more characters.
n=$(runs7); check 75 "T1: a reason of 8192 two-byte letters is queued" env ESCALATE_FORCE_POOL_EXHAUSTED=1 sh -c "echo hi | $E t_aaaa0801 review $(sed "s/r/$(printf '\xd0\x96')/g" "$T/r8192")"
id=$(jq -r 'select(.card == "t_aaaa0801") | .id' "$Q7" | tail -1); $D --replay "$id" >/dev/null 2>&1
ok '[ -n "$id" ] && [ "$(runs7)" = $((n + 1)) ] && [ "$(st7 "$id")" = replayed ]' "T1: ... and replayed (a reason accepted when queued is not refused for its length on the replay)"
# the stub stands in for a model command that did not start: escalate.sh sees only the exit code
plant7 q_t3 .; FAKE_OUT=' ' FAKE_RC=127 $D --replay q_t3 >/dev/null 2>&1; w="the model command did not start (exit 127); left in the queue as q_t3"
ok '[ "$(st7 q_t3)" = queued ] && [ "$(tail -1 "$S7/escalations.log" | jq -r --arg w "$w" ".detail | contains(\$w)")" = true ] && tail -1 "$S7/comments" | grep -qF "$w"' "T3: a replay whose model command did not start: the log line and the card note say it is left in the queue"
export ESCALATE_SUP_DIR="$T/sup"

[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
