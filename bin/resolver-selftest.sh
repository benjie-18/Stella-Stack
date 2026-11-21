#!/usr/bin/env bash
# Hermetic self-test for the resolver (F2 W3; bin/resolve.py). In scratch roots (STELLA_ROOT = a temp folder with a copy of
# .stella/, the role table and its hooks) a fake catalog is made from the shipped entries with jq: a local link, a link of each
# hosted class, an aggregator, two CLI logins (terms_ok true, terms_ok null; both serve), and a preset of every class. Each rule of the
# resolver is shown with its code; the fake-entry test adds a provider, a link class, a preset, a role, a driver and a task
# tier as data only and resolves them with the resolver's file unchanged. No class, tier, role, driver or shipped preset is
# named here: every id is read from the shipped data, and the codes from the resolver. The alert log goes to a temp folder
# (ESCALATE_SUP_DIR); nothing reaches the network (the resolver opens no socket).
set -u
jq() { env -u HOME jq "$@"; }   # jq always loads ~/.jq; every script under bin/ runs it without HOME
BIN=$(dirname "$(readlink -f "$0")"); ROOT=$(dirname "$BIN"); RS="$BIN/resolve.py"; SD="$BIN/stella_data.py"
T=$(mktemp -d -t resolver-selftest.XXXXXX); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/tmp" "$T/o" "$T/sup/logs"; export TMPDIR=$T/tmp ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env; unset STELLA_ROOT
printf "OWNER_TIMEZONE='UTC'\n" >"$OWNER_CONFIG"; AL=$T/sup/logs/alerts.log; : >"$AL"
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
j() { jq -r "$1" "$2"; }
IX=$ROOT/.stella/data-files.json
p() { jq -r --arg s "$1" '[.files[] | select(.schema == $s and .format == "json") | .path][0]' "$IX"; }   # <schema>: its file
RJREL=$(j .role_table "$IX"); RJ=$ROOT/$RJREL; RT=$ROOT/$(p routing); POL=$ROOT/$(p data-policy); FACTS=$(j .card_facts "$IX"); STATE=$(j .routing_state "$IX")
PF=$(j .probe_records "$IX"); SHIPPED=$(jq -c '[.entries[].id]' "$ROOT/$(p connections)"); OSN=$(j '.probe.output_shapes[-1]' "$RT")
mk() {  # <name> [<from name>]: a scratch root with a copy of the data, the role table and its hooks (or of another scratch root)
  rm -rf "${T:?}/$1"
  if [ -n "${2:-}" ]; then cp -r "$T/$2" "$T/$1"; return; fi
  mkdir -p "$T/$1/$(dirname "$RJREL")" "$T/$1/.supervisor"; cp "$ROOT/.supervisor/limits.env" "$T/$1/.supervisor/"; cp -r "$ROOT/.stella" "$T/$1/.stella";   # the limits store: a limit that names a key it lacks is 0 (the ledger)
  cp "$RJ" "$T/$1/$RJREL"; cp -r "$(dirname "$RJ")/hooks" "$T/$1/$(dirname "$RJREL")/hooks"
}
ed() { local f; f="$T/$1/$(p "$2")"; jq "${@:3}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <root> <schema> <jq args and filter>
edt() { local f="$T/$1/$RJREL"; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }        # <root> <jq args and filter>: the role table
probes() {  # <root>: one probe record per model of the root's own fake connections (ids the shipped catalog lacks), mirroring the capabilities the
  # fixture gives the model: what a link can do is read from its record, never from the catalog (F2b item C). A root holding .qa-own-probes keeps its own.
  local f="$T/$1/$PF"; [ -e "$T/$1/.qa-own-probes" ] && return; mkdir -p "$(dirname "$f")"
  jq --arg i "$IID" --arg o "$OSN" --argjson s "$SHIPPED" '{schema_version: 1, records: [.entries[] | select(.kind == "provider") | .id as $c | select($s | index($c) | not)
    | .models[] | (.capabilities // {}) as $k | {global_id: "00000000-0000-4000-8000-000000000000", install_id: $i, connection: $c, model: .id, version: "qa",
      probed_at: "2026-01-01T00:00:00Z", family: null, tool_calling: $k.tool_calling, parallel_tool_calls: null, json: $k.json_mode, vision: $k.vision,
      output_shape: $o, context: {advertised: $k.context_tokens, effective: ($k.context_tokens // 0), short_score: 1, points: []}, code: null}]}' \
    "$T/$1/$(p connections)" >"$f.n" 2>/dev/null && { cmp -s "$f.n" "$f" && rm -f "$f.n" || mv "$f.n" "$f"; } || rm -f "$f.n"
}
passes() {  # <root>: the fixture is valid data (else the first problems are shown)
  probes "$1"; STELLA_ROOT=$T/$1 python3 -I -B "$SD" check >"$T/o/check" 2>&1 || { head -n 3 "$T/o/check" | cut -c1-300 >&2; return 1; }
}
rs() {  # <root> <name> <args>...: resolve; stdout o/<name>.json, stderr .err, exit code .rc (RSX: another copy of the resolver)
  probes "$1"; STELLA_ROOT=$T/$1 python3 -I -B "${RSX:-$RS}" resolve "${@:3}" --json >"$T/o/$2.json" 2>"$T/o/$2.err"; echo $? >"$T/o/$2.rc"
}
rc() { cat "$T/o/$1.rc"; }
J() { [ -s "$T/o/$1.json" ] && jq -e "${@:2}" "$T/o/$1.json" >/dev/null 2>&1; }      # <name> <jq args, filter>: holds on the answer
ent() { echo "[.chain[] | select(.connection == \"$1\"${2:+ and .model == \"$2\"})]"; }   # <connection> [<model>]: a jq of those links
closed() {  # <name> <code>: failed closed: exit 1, no answer, exactly one line with a code, and it is that code
  [ "$(rc "$1")" = 1 ] && [ ! -s "$T/o/$1.json" ] && [ "$(grep -cE 'STL-[A-Z]+-[0-9]{3}' "$T/o/$1.err")" = 1 ] && grep -q "^$2 " "$T/o/$1.err"
}
alerts() { grep -c "^$1 " "$AL"; }   # <code>: its lines in the alert log
uuid() { cat /proc/sys/kernel/random/uuid; }
PAST=$(date -u -d '-30 days' +%FT%TZ); RECENT=$(date -u -d '-1 hour' +%FT%TZ); SOON=$(date -u -d '+1 day' +%FT%TZ)

# ---- ids and codes, read from the data and the resolver ----
LOCAL=$(j .class_defaults.local "$RT"); FREE=$(j .class_defaults.aggregator "$RT")
FRONT=$(jq -r --arg f "$FREE" '[.link_classes[] | select(.hosted and .id != $f) | .id][0] // empty' "$RT")
FB=$(j .fallback_role "$RJ"); CARDR=$(jq -c .card_roles "$RT"); EXR=$(jq -c '[.exempt_roles[].role]' "$RT"); REQR=$(jq -c '[.workflow.required_roles[].role]' "$RT")
AR=$(jq -c --arg fb "$FB" '[.roles | keys[] | select(. != $fb)]' "$RJ"); CLASSES=$(jq -c .data_classes "$POL")
# the roles whose data classes all reach a hosted link with no grant; NR, NR2: two that work no card, are not exempt and not required; CR: a card role
FREEROLES=$(jq -c --arg fb "$FB" --slurpfile pol "$POL" '[.roles | to_entries[] | select(.key != $fb)
  | select([.value.requirements.allowed_data_classes[]? | $pol[0].class_rules[.].hosted] | all(. == "allowed")) | .key]' "$RJ")
NRS=$(jq -c --argjson c "$CARDR" --argjson e "$EXR" --argjson q "$REQR" '[.[] | select(. as $k | [$c, $e, $q] | all(index($k) == null))]' <<<"$FREEROLES")
NR=$(jq -r '.[0] // empty' <<<"$NRS"); NR2=$(jq -r '.[1] // empty' <<<"$NRS"); CR=$(jq -r --argjson c "$CARDR" '[.[] | select(. as $k | $c | index($k) != null)][0] // empty' <<<"$FREEROLES")
ER=$(jq -r '.[0] // empty' <<<"$EXR"); EXO=$(jq -c '.exempt_roles[0].class_order' "$RT")
ENGINE=$(j '[.drivers[] | select(.mid_task) | .id][0] // empty' "$RT"); WORKER=$(j '[.drivers[] | select(.mid_task | not) | .id][0] // empty' "$RT")
TIER=$(j '.task_tiers[0].id' "$RT"); FACT=$(j '[.card_facts.when_missing | to_entries[] | select(.value) | .key][0] // empty' "$RT")
GCLASS=$(j '[.class_rules | to_entries[] | select(.value.hosted == "grant") | .key][0] // empty' "$POL")
NCLASS=$(j '[.class_rules | to_entries[] | select(.value.hosted == "never") | .key][0] // empty' "$POL")
IID=$(j .install_id "$ROOT/$(p install)")
read -r C_NOLINK C_UNKNOWN C_AGG C_HARD C_UNMET C_POLICY C_PRIV C_CROSS C_COOL < <(python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import resolve as r
print(r.NO_LINK, r.UNKNOWN, r.AGGREGATOR, r.HARD, r.UNMET, r.POLICY, r.PRIVACY, r.CROSSING, r.COOLDOWN)' "$BIN")
ok '[ -n "$LOCAL" ] && [ -n "$FREE" ] && [ -n "$FRONT" ] && [ -n "$NR" ] && [ -n "$NR2" ] && [ -n "$CR" ] && [ -n "$ER" ] && [ -n "$ENGINE" ] && [ -n "$WORKER" ] && [ -n "$FACT" ] && [ -n "$GCLASS" ] && [ -n "$NCLASS" ]' \
  "0a the shipped data gives the ids this test needs (three link classes, roles of each kind, both kinds of driver, a card fact, a grant class, a never class)"
ok 'for c in "$C_NOLINK" "$C_UNKNOWN" "$C_AGG" "$C_HARD" "$C_UNMET" "$C_POLICY" "$C_PRIV" "$C_CROSS" "$C_COOL"; do jq -e --arg c "$c" ".alerts[] | select(.code == \$c and (.message | contains(\"{problem}\")))" "$ROOT/docs/hermes-local/alert-catalog.json" >/dev/null || exit 1; done' \
  "0b every code of the resolver is a row of the alert catalog"
RA=$ROOT/$(p role-assignments)   # the shipped presets whose last resort is the local class, and a class that leaves the machine (read from the data, not named)
P_LASTLOCAL=$(jq -r --arg l "$LOCAL" '[.effort_modes | to_entries[] | select(.value.last_resort == $l) | .key][0] // empty' "$RA")
P_LASTAWAY=$(jq -r --arg l "$LOCAL" '[.effort_modes | to_entries[] | select(.value.last_resort != null and .value.last_resort != $l) | .key][0] // empty' "$RA")
ok '[ -n "$P_LASTLOCAL" ] && [ -n "$P_LASTAWAY" ]' "0c the shipped presets include one whose last resort is the local class and one whose last resort leaves the machine"

# ---- the fake catalog ----
model() { echo "{\"id\":\"$1\",\"capabilities\":{\"tool_calling\":true,\"json_mode\":true,\"context_tokens\":1048576,\"vision\":true,\"streaming\":true},\"probed_at\":null,\"probe_source\":\"advertised\"}"; }
TPL_LOCAL='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "local")][0]'
TPL_CLOUD='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "cloud" and (.aggregator | not))][0]'
TPL_CLI='[.entries[] | select(.kind == "provider" and .type == "cli-login")][0]'
prov() {  # <root> <template filter> <id> <overrides JSON>: a provider made from a shipped entry, two models, every role and class allowed
  ed "$1" connections --arg id "$3" --arg g "$(uuid)" --argjson m "[$(model "$3-m1"),$(model "$3-m2")]" --argjson o "$4" --argjson ar "$AR" --argjson dc "$CLASSES" \
    ".entries += [($2 | del(.link_class, .protocol)) + {id: \$id, label: (\"QA \" + \$id), enabled: true, global_id: \$g, allowed_roles: \$ar, models: \$m} | .data_policy.data_classes_allowed = \$dc | . + \$o]"
}
facts() { mkdir -p "$T/$1/$FACTS"; echo "$3" >"$T/$1/$FACTS/$2.json"; }                        # <root> <card> <record JSON>
state() { mkdir -p "$(dirname "$T/$1/$STATE")"; echo "$2" >"$T/$1/$STATE"; }                    # <root> <state JSON>
preset() {  # <root> <id> <jq object of the optional keys>: a custom preset, selected globally
  ed "$1" role-assignments --arg id "$2" --arg l "$LOCAL" --arg f "$FREE" --arg x "$FRONT" --arg t "$TIER" --arg r "$NR" \
    ".effort_modes[\$id] = ({allowed_localities: [\"local\", \"cloud\"], no_silent_fallback: false, builtin: false} + $3) | .selection = {global: \$id}"
}
CLEAN=$(jq -c '.card_facts.when_missing | map_values(false) + {project: "qa-proj", apps: []}' "$RT")
mk base
ed base connections '.entries |= map(if .kind == "provider" then .allowed_roles = [] else . end)'
prov base "$TPL_LOCAL" qa-local '{}'
prov base "$TPL_CLOUD" qa-front "{\"link_class\":\"$FRONT\"}"
prov base "$TPL_CLOUD" qa-free "{\"link_class\":\"$FREE\"}"
prov base "$TPL_CLOUD" qa-agg '{"aggregator":true,"secrets":[],"broker_entries":{"unified":"QA_AGG_UNIFIED","admin":"QA_AGG_ADMIN","upstream":["QA_AGG_UP1"]}}'
prov base "$TPL_CLI" qa-cli "{\"terms_ok\":true,\"link_class\":\"$FRONT\"}"
prov base "$TPL_CLI" qa-cli-no "{\"terms_ok\":null,\"link_class\":\"$FRONT\"}"
ed base role-assignments '.assignments = []'; preset base qa-all '{class_order: [$x, $f, $l], last_resort: null}'
facts base qa-card "$CLEAN"
AWAY="[.chain[] | select(.link_class != \"$LOCAL\")]"   # the links that leave the machine (a class that is not hosted never labels one)

SCORESTUB=routing-advertised-scores   # the id of the removed stub (cases 1d, 18f)
# ---- 1: the answer ----
rs base b --role "$NR" --project qa-proj --tier "$TIER" --driver "$ENGINE" --task qa-t
ok 'passes base' "1 the fake catalog with a preset of every class is valid data"
ok '[ "$(rc b)" = 0 ] && J b --arg r "$NR" --arg t "$TIER" --arg d "$ENGINE" ".role == \$r and .project == \"qa-proj\" and .card == null and .preset == {id: \"qa-all\", source: \"global\"}
  and .policy == \"default\" and .local_only == false and .tier == \$t and .driver == \$d and .code == null and .reason == null and .apps == [] and .failure_history == []
  and .decision.rule == \"class_order\" and (.decision.reason | length > 0) and (.chain | length > 0)"' "1a exit 0 and the answer's keys; a project the policy does not list follows the default"
ok 'J b "all(.chain[]; (.status == \"usable\" and .code == null and .reason == null) or ((.code | test(\"^STL-[A-Z]+-[0-9]{3}$\")) and (.reason | length > 0)))"' \
  "1b every link that is not usable carries a catalog code and a plain reason"
ok 'J b "([.chain[] | .link_class] | unique | length == 3) and .chain[0].link_class == \"$FRONT\" and .chain[-1].link_class == \"$LOCAL\" and ([.chain[] | .connection + \"/\" + .model] | length == (unique | length))"' \
  "1c the catalog's links follow the preset's class order, and no link is listed twice"
ok 'J b --slurpfile f "$ROOT/$(p features)" ".stubs | (index(\"$SCORESTUB\") == null) and all(. as \$s | \$f[0].entries | any(.id == \$s and .due_phase != null))"' \
  "1d stubs[] names features entries that are stubs (the scores stub only when a group was ranked)"
python3 -I -B "$RS" resolve --project qa-proj --json >/dev/null 2>"$T/o/us.err"; us=$?
ok '[ "$us" = 2 ] && grep -qi usage "$T/o/us.err"' "1e a request with no --role is a usage error (exit 2)"
ok '[ "$(python3 -I -B -c "import sys; sys.path.insert(0, sys.argv[1]); import resolve; print(resolve.link_key({\"connection\": \"qa-c\", \"model\": \"a/b:1\"}))" "$BIN")" = qa-c/a/b:1 ]' \
  "1f link_key(link) is <connection>/<model>"

# ---- 2: the fake-entry test: a provider, a link class, a preset, a role, a driver and a task tier as data only ----
mk fk base; sum0=$(sha256sum "$RS")
ed fk routing '.link_classes += [{id: "qa-class", privacy_rank: 9, hosted: true}] | .drivers += [{id: "qa-driver", mid_task: true}] | .task_tiers += [{id: "qa-tier"}]'
# the new role is a copy of NR's row, served by a copy of NR's profile (in the box when that one is)
edt fk --arg r "$NR" --arg g "$(uuid)" --arg g2 "$(uuid)" '([.profiles | to_entries[] | select(.value.role == $r)][0]) as $p
  | .roles["qa-role"] = (.roles[$r] + {global_id: $g}) | .profiles["qa-profile"] = ($p.value + {role: "qa-role", global_id: $g2} | del(.capability_fallback))
  | if ((.sandbox.boxed_profiles // []) | index($p.key)) != null then .sandbox.boxed_profiles += ["qa-profile"] else . end'
prov fk "$TPL_CLOUD" qa-new '{"link_class":"qa-class","allowed_roles":["qa-role"]}'
ed fk role-assignments '.effort_modes["qa-new-preset"] = {allowed_localities: ["cloud"], no_silent_fallback: false, builtin: false, class_order: ["qa-class"]} | .selection.projects = {"qa-new-proj": "qa-new-preset"}'
rs fk fk --role qa-role --project qa-new-proj --driver qa-driver --tier qa-tier
ok 'passes fk' "2 a new provider, link class, preset, role, driver and task tier added as data only are valid data"
ok '[ "$(rc fk)" = 0 ] && J fk ".role == \"qa-role\" and .preset == {id: \"qa-new-preset\", source: \"project\"} and .tier == \"qa-tier\" and .driver == \"qa-driver\" and (.chain | length == 2)
  and all(.chain[]; .connection == \"qa-new\" and .link_class == \"qa-class\" and .source == \"preset\" and .status == \"usable\" and .mid_task == true)"' \
  "2a the new role resolves to the new provider through the new class, preset, driver and tier"
ok '[ "$(sha256sum "$RS")" = "$sum0" ] && ! grep -q "qa-" "$RS"' "2b the resolver's file is unchanged and names no fake id"

# ---- 3: unknown ids fail closed with one alert line ----
n0=$(alerts "$C_UNKNOWN")
rs base u1 --role qa-zz --project qa-proj; rs base u2 --role "$NR" --project qa-proj --tier qa-zz; rs base u3 --role "$NR" --project qa-proj --driver qa-zz
rs base u4 --role "$CR" --project qa-proj; rs base u5 --role "$CR" --project qa-proj --card ../qa-card
ok 'closed u1 "$C_UNKNOWN" && closed u2 "$C_UNKNOWN" && closed u3 "$C_UNKNOWN"' "3 an unknown role, task tier or driver fails closed: exit 1, no answer, one line with $C_UNKNOWN"
ok 'closed u4 "$C_UNKNOWN" && closed u5 "$C_UNKNOWN"' "3a a role that works a card called with no card, and a card id that is no plain id, fail closed with $C_UNKNOWN"
ok '[ $(( $(alerts "$C_UNKNOWN") - n0 )) = 5 ]' "3b each of the five wrote exactly one alert line"
mk bad base; ed bad role-assignments '.selection.global = "qa-zz"'; rs bad u6 --role "$NR" --project qa-proj
ok 'closed u6 STL-CFG-310' "3c data that check refuses (an unknown preset is selected) fails closed with one line"

# ---- 4: the connection rules ----
ok 'J b "$(ent qa-cli-no) | length == 2 and all(.status == \"usable\")" && J b "$(ent qa-cli) | length == 2 and all(.status == \"usable\")"' \
  "4 a CLI login whose terms are not recorded is usable like the one with terms_ok true (terms_ok is never enforced)"
ok 'J b "$(ent qa-agg) | length == 2 and all(.status == \"excluded\" and .code == \"$C_AGG\" and .link_class == \"$FREE\")"' \
  "4a an aggregator is excluded with $C_AGG while the shipped credentials do not resolve its broker entries"
mk cb base; cp -r "$BIN" "$T/cb/bin"; cp "$ROOT/docs/hermes-local/alert-catalog.json" "$T/cb/$(dirname "$RJREL")/"
stub() { printf 'def check(names):\n    return %s\n' "$1" >"$T/cb/bin/credentials.py"; }
stub 'sorted(names) == ["QA_AGG_ADMIN", "QA_AGG_UNIFIED", "QA_AGG_UP1"]'; RSX=$T/cb/bin/resolve.py rs cb cb1 --role "$NR" --project qa-proj
stub '[]'; RSX=$T/cb/bin/resolve.py rs cb cb2 --role "$NR" --project qa-proj
stub '1 / 0'; RSX=$T/cb/bin/resolve.py rs cb cb3 --role "$NR" --project qa-proj
ok 'J cb1 "$(ent qa-agg) | length == 2 and all(.status == \"usable\")"' "4b it is usable once credentials.check answers True for exactly its broker entry names (a stand-in module)"
ok 'J cb2 "$(ent qa-agg) | all(.code == \"$C_AGG\")" && J cb3 "$(ent qa-agg) | all(.code == \"$C_AGG\")" && [ "$(rc cb3)" = 0 ]' "4c any other answer, or a failing credentials module, is not resolved"
mk cx base; ed cx connections --arg r "$NR" '.entries |= map(if .id == "qa-front" then .enabled = false elif .id == "qa-free" then .allowed_roles -= [$r] elif .id == "qa-cli" then .data_policy.data_classes_allowed = [] else . end)'
rs cx cx --role "$NR" --project qa-proj
ok 'passes cx && J cx "[.chain[] | select(.connection == \"qa-front\" or .connection == \"qa-free\" or .connection == \"qa-cli\")] | length == 6 and all(.status == \"excluded\" and .code == \"$C_POLICY\")"' \
  "4d a connection switched off, one that does not list the role, and one that allows none of its data classes are excluded with $C_POLICY"
mk rq base; edt rq --arg r "$NR" '.roles[$r].requirements.min_context_tokens = 4096'
ed rq connections '.entries |= map(if .id == "qa-free" then .models[].capabilities.context_tokens = 4095 else . end)'; rs rq rq --role "$NR" --project qa-proj
ok 'passes rq && J rq "$(ent qa-free) | length == 2 and all(.status == \"excluded\" and .code == \"$C_UNMET\")" && J rq "$(ent qa-front) | all(.status == \"usable\")"' \
  "4e a model one token short of the role's context requirement is excluded with $C_UNMET"

# ---- 5: hard exclusions and Local only ----
mk h base
facts h qa-held "$(jq -c --arg k "$FACT" '.[$k] = true' <<<"$CLEAN")"; facts h qa-nofield "$(jq -c --arg k "$FACT" 'del(.[$k])' <<<"$CLEAN")"
facts h qa-other "$(jq -c '.project = "qa-other"' <<<"$CLEAN")"; facts h qa-string "$(jq -c --arg k "$FACT" '.[$k] = "false"' <<<"$CLEAN")"
ed h data-policy --arg g "$(uuid)" --arg i "$IID" '.projects["qa-private"] = {mode: "open", allowed_providers: [], private: true, global_id: $g, install_id: $i}'
for c in qa-card qa-held qa-nofield qa-string qa-norecord qa-other; do rs h "h-$c" --role "$CR" --project qa-proj --card "$c"; done
rs h h-private --role "$NR" --project qa-private
HARD="$AWAY | length > 0 and all(.status == \"excluded\" and .code == \"$C_HARD\" and .grant == null)"
ok 'passes h && [ "$(rc h-qa-card)" = 0 ] && J h-qa-card "$AWAY | any(.status == \"usable\")" && J h-qa-card ".card == \"qa-card\""' "5 control: a card whose facts are all recorded as not holding reaches a hosted link"
for c in "qa-held:whose fact $FACT holds" "qa-nofield:whose record lacks the fact $FACT" "qa-string:whose record states the fact $FACT as a string, not a boolean" "qa-norecord:with no facts record"; do
  ok "[ \"\$(rc h-${c%%:*})\" = 0 ] && J h-${c%%:*} \"\$HARD\" && J h-${c%%:*} \"\$(ent qa-local) | any(.status == \\\"usable\\\")\"" \
    "5-${c%%:*} a card ${c#*:}: every link that leaves the machine is excluded with $C_HARD, no grant offered, the local link usable"
done
ok 'closed h-qa-other "$C_NOLINK"' "5a a card whose facts record names another project fails closed with $C_NOLINK and no chain"
ok '[ "$(rc h-private)" = 0 ] && J h-private "$HARD" && J h-private "$(ent qa-local) | any(.status == \"usable\")" && J h-private ".policy == \"project\""' \
  "5b a project marked private: every link that leaves the machine is excluded with $C_HARD"
# W3-CVER-01: routing data that says a missing fact does not hold, or names no fact, switches no hard exclusion off: the answer is
# the same exclusion, or no answer at all once `check` refuses that data (never a link that leaves the machine)
mk hf h; ed hf routing '.card_facts.when_missing |= map_values(false)'; mk he h; ed he routing '.card_facts.when_missing = {}'
rs hf hf-held --role "$CR" --project qa-proj --card qa-held; rs hf hf-nofield --role "$CR" --project qa-proj --card qa-nofield; rs he he-held --role "$CR" --project qa-proj --card qa-held
shut() { closed "$1" STL-CFG-310 || { [ "$(rc "$1")" = 0 ] && J "$1" "$HARD"; }; }   # <name>: every link that leaves the machine excluded, or failed closed
ok 'shut hf-held && shut hf-nofield' "5d routing data that says a missing fact counts as not holding: a card whose fact holds, and one whose record lacks it, still reach no link that leaves the machine"
ok 'shut he-held' "5e routing data that names no card fact: a card whose record says the fact holds still reaches no link that leaves the machine"
# W3-CRT-01: a project id that is a listed one but for case or outer spaces is refused, so a misspelling never drops a marking
PGID=$(jq -r '.projects["qa-private"].global_id' "$T/h/$(p data-policy)"); n0=$(alerts "$C_UNKNOWN")
rs h pj1 --role "$NR" --project QA-Private; rs h pj2 --role "$NR" --project "qa-private "; rs h pj3 --role "$NR" --project " ${PGID^^}"
rs h pj4 --role "$NR" --project "$PGID"; rs h pj5 --role "$NR" --project qa-privat
ok 'closed pj1 "$C_UNKNOWN" && closed pj2 "$C_UNKNOWN" && closed pj3 "$C_UNKNOWN" && [ $(( $(alerts "$C_UNKNOWN") - n0 )) = 3 ]' \
  "5f a private project asked for in another case, with a trailing space, or by its global id so misspelled fails closed with $C_UNKNOWN (one alert line each)"
ok '[ "$(rc pj4)" = 0 ] && J pj4 "$HARD" && J pj4 ".policy == \"project\"" && [ "$(rc pj5)" = 0 ] && J pj5 ".policy == \"default\"" && J pj5 "$AWAY | any(.status == \"usable\")"' \
  "5g its exact global id is the project (the same exclusion); an id that matches no listed project follows the default policy"
# W3-CRT-01 reopened: an id that is no project key by the data policy schema's own key pattern is refused: an invisible character
# (zero-width space, BOM), a full-width letter, a look-alike letter, a combining mark (bytes spelled out, so no locale is needed),
# another case, a blank id. The pattern is the schema's: a root whose schema allows upper case resolves that id (default policy).
# An empty id is no project at all (what a caller with no card gives, the model guard for one): the default policy.
n0=$(alerts "$C_UNKNOWN"); i=0
for v in $'qa-private\xe2\x80\x8b' $'\xef\xbb\xbfqa-private' $'\xef\xbd\x91a-private' $'qa-privat\xd0\xb5' $'qa-private\xcc\x81' Qa-New " "; do i=$((i+1)); rs h "pk$i" --role "$NR" --project "$v"; done
allclosed() { local k; for k; do closed "$k" "$C_UNKNOWN" || return 1; done; }
ok 'allclosed pk1 pk2 pk3 pk4 pk5 pk6 pk7 && [ $(( $(alerts "$C_UNKNOWN") - n0 )) = 7 ]' \
  "5h a project id that does not match the schema's project key pattern fails closed with $C_UNKNOWN: invisible, full-width, look-alike and combining variants of the private id, another case, a blank id"
rs h pk0 --role "$NR" --project ""
ok '[ "$(rc pk0)" = 0 ] && J pk0 ".policy == \"default\" and .project == \"\""' "5j an empty project id is no project: the default policy"
mk hp h; SCH=$T/hp/.stella/schemas/data-policy.schema.json
jq '.properties.projects.propertyNames.pattern = "^[A-Za-z0-9][A-Za-z0-9._:-]*$"' "$SCH" >"$SCH.n" && mv "$SCH.n" "$SCH"
rs hp pk8 --role "$NR" --project Qa-New; rs hp pk9 --role "$NR" --project QA-Private
ok '[ "$(rc pk8)" = 0 ] && J pk8 ".policy == \"default\"" && closed pk9 "$C_UNKNOWN"' \
  "5i the pattern is read from the schema: where it allows upper case such an id follows the default policy, and the near-miss of a listed id is still refused"
cgrant() {  # <root> <id> <preset> <to class> <scope JSON>: a crossing grant
  ed "$1" grants --arg id "$2" --arg p "$3" --arg k "$4" --arg g "$(uuid)" --arg i "$IID" --arg a "$PAST" --argjson s "$5" \
    '.crossing_grants = ((.crossing_grants // []) + [{id: $id, global_id: $g, install_id: $i, preset: $p, to_class: $k, scope: $s, granted_at: $a}])'
}
mk lo base; ed lo data-policy --arg g "$(uuid)" --arg i "$IID" '.default.mode = "local_only" | .projects["qa-proj"] = {mode: "open", allowed_providers: [], global_id: $g, install_id: $i}'
# under Local only the class order is the local class, so the one link that leaves the machine in this chain is the preset's fallback for the role
ed lo role-assignments --arg r "$NR" '.effort_modes["qa-all"].roles = {($r): {active: true, fallbacks: [{connection: "qa-front", model: "qa-front-m1", parameters: {}}]}}'
cgrant lo qa-cg qa-all "$FRONT" '{"level":"global"}'; rs lo lo --role "$NR" --project qa-proj
ok 'passes lo && [ "$(rc lo)" = 0 ] && J lo ".local_only == true" && J lo "$AWAY | length > 0 and all(.status == \"excluded\" and .code == \"$C_POLICY\" and .grant == null)" && J lo "$(ent qa-local) | any(.status == \"usable\")" &&
  J lo "[.chain[] | select(.source != \"fallback\")] | length > 0 and all(.link_class == \"$LOCAL\")"' \
  "5c Local only as the default beats a project row that says open (DC-04): local links only (the preset's fallback that leaves the machine is excluded with $C_POLICY), no grant offered, a Stella-wide grant present"
# W3-CVER-02 / W3-VAL-01: Local only overrides any preset, for every role, with no grant of any kind in the data
mk lp lo; ed lp grants '.crossing_grants = []'
mk lp-a lp; ed lp-a role-assignments --arg p "$P_LASTLOCAL" '.selection = {global: $p}'; mk lp-b lp; ed lp-b role-assignments --arg p "$P_LASTAWAY" '.selection = {global: $p}'
mk lp-c lp; preset lp-c qa-nolocal '{allowed_localities: ["cloud"], class_order: [$x, $f], last_resort: null}'
LO="(.local_only == true) and any(.chain[]; .status == \"usable\") and all(.chain[]; .link_class == \"$LOCAL\" and .grant == null and .source != \"last_resort\")"
for r in "lp-a:the shipped preset whose last resort is the local class" "lp-b:the shipped preset whose last resort leaves the machine" "lp-c:a custom preset with no local class and no last resort"; do
  bad=""
  for role in $(jq -r '.[]' <<<"$AR"); do
    # shellcheck disable=SC2046
    rs "${r%%:*}" "${r%%:*}-$role" --role "$role" --project qa-proj $(jq -e --arg k "$role" 'index($k) != null' <<<"$CARDR" >/dev/null && echo "--card qa-card")
    { [ "$(rc "${r%%:*}-$role")" = 0 ] && J "${r%%:*}-$role" "$LO"; } || bad="$bad $role"
  done
  ok "passes ${r%%:*} && [ -z \"$bad\" ]" "5c-${r%%:*} Local only under ${r#*:}, no grants: every role has a usable local link, local links only, no grant asked, no last resort${bad:+ (not:$bad)}"
done
ok 'J "lp-a-$ER" --argjson o "$EXO" "all(.chain[]; .link_class as \$c | \$o | index(\$c) != null)"' "5c-exempt an exempt role keeps its own class order under Local only"

# ---- 6: privacy grants and classes that never reach a hosted link ----
pgrant() {  # <root> <id> <data class> <connection> <extra JSON>
  ed "$1" data-policy --arg id "$2" --arg k "$3" --arg c "$4" --arg g "$(uuid)" --arg i "$IID" --arg a "$PAST" --argjson o "$5" \
    '.privacy_grants += [{id: $id, global_id: $g, install_id: $i, data_class: $k, connection: $c, granted_at: $a} + $o]'
}
INPROJ='{"level":"project","project":"qa-proj"}'
mk g base; edt g --arg r "$NR" --arg k "$GCLASS" '.roles[$r].requirements.allowed_data_classes += [$k]'
mk gp g; pgrant gp qa-pg "$GCLASS" qa-front "{\"scope\":$INPROJ}"
mk gr g; pgrant gr qa-pg "$GCLASS" qa-front "{\"scope\":$INPROJ,\"revoked_at\":\"$RECENT\"}"
rs g g0 --role "$NR" --project qa-proj; rs gp g1 --role "$NR" --project qa-proj; rs gp g2 --role "$NR" --project qa-other; rs gr g3 --role "$NR" --project qa-proj
NG="$(ent qa-front) | length == 2 and all(.status == \"needs_grant\" and .code == \"$C_PRIV\" and .grant == {kind: \"privacy\", data_class: \"$GCLASS\"})"
ok 'passes g && J g0 "$NG" && J g0 "$(ent qa-local) | all(.status == \"usable\")"' "6 a role that handles a grant class: a hosted link is needs_grant privacy with $C_PRIV, the local link usable"
ok 'passes gp && J g1 "$(ent qa-front) | all(.status == \"usable\")" && J g2 "$NG"' "6a a grant scoped to the project holds there and not in another project"
ok 'passes gr && J g3 "$NG"' "6b a revoked grant grants nothing"
mk nv base; edt nv --arg r "$NR" --arg k "$NCLASS" '.roles[$r].requirements.allowed_data_classes += [$k]'; rs nv nv --role "$NR" --project qa-proj
ok 'passes nv && J nv "$AWAY | length > 0 and all(.status == \"excluded\" and .grant == null)" && J nv "$(ent qa-front) | all(.code == \"$C_POLICY\")" && J nv "$(ent qa-local) | all(.status == \"usable\")"' \
  "6c a role that handles a never class: every hosted link is excluded with no grant offered (DC-08)"

mk nx nv; preset nx qa-nx '{class_order: [$l], last_resort: $x}'; rs nx nx --role "$NR" --project qa-proj
ok 'passes nx && J nx "$AWAY | length > 0 and all(.status == \"excluded\" and .grant == null)" && J nx "$(ent qa-front) | length == 2 and all(.source == \"last_resort\" and .code == \"$C_POLICY\")"' \
  "6d a never class refuses before a crossing grant is offered (W3-CVER-04): the links of a last-resort class that leaves the machine are excluded, no grant asked"

# ---- 7: the last-resort class and exempt roles ----
mk x base; preset x qa-x '{allowed_localities: ["cloud"], class_order: [$x], last_resort: $l}'
mk xp x; cgrant xp qa-cg qa-x "$LOCAL" "$INPROJ"; mk xg x; cgrant xg qa-cg qa-x "$LOCAL" '{"level":"global"}'
rs x x0 --role "$NR" --project qa-proj; rs xp x1 --role "$NR" --project qa-proj; rs xp x2 --role "$NR" --project qa-other; rs xg x3 --role "$NR" --project qa-other
rs x x4 --role "$ER" --project qa-proj
W="$(ent qa-local) | length == 2 and all(.status == \"needs_grant\" and .code == \"$C_CROSS\" and .source == \"last_resort\" and .grant == {kind: \"crossing\", to_class: \"$LOCAL\"})"
ok 'passes x && [ "$(rc x0)" = 0 ] && J x0 "$W" && J x0 "[.chain[].source] | index(\"last_resort\") > ([to_entries[] | select(.value == \"preset\") | .key] | max)"' \
  "7 a link of the preset's last-resort class is needs_grant crossing with $C_CROSS, after every class candidate, though the preset's localities leave it out"
ok 'passes xp && J x1 "$(ent qa-local) | all(.status == \"usable\")" && J x2 "$W"' "7a a crossing grant scoped to the project holds there and not in another project"
ok 'passes xg && J x3 "$(ent qa-local) | all(.status == \"usable\")"' "7b a Stella-wide crossing grant holds in every project"
ok '[ "$(rc x4)" = 0 ] && J x4 --argjson o "$EXO" "(.chain | length > 0) and all(.chain[]; .grant == null and (.link_class as \$c | \$o | index(\$c) != null)) and any(.chain[]; .status == \"usable\")"' \
  "7c an exempt role follows its own class order under that preset: usable, never a crossing, the preset's localities not applied"
mk off base; ed off role-assignments --arg r "$NR2" '.effort_modes["qa-all"].roles = {($r): {active: false}}'; rs off off --role "$NR2" --project qa-proj
ok 'passes off && [ "$(rc off)" = 1 ] && J off ".code == \"$C_NOLINK\" and .chain == [] and (.reason | length > 0)" && grep -q "^$C_NOLINK " "$T/o/off.err"' \
  "7d a role the preset turns off does not resolve: exit 1 with $C_NOLINK and the reason"

# ---- 8: pins, fallbacks, the order of the chain, mid-task ----
mk pn base
pin() {  # <root> <id> <scope JSON> <connection> <model>: an owner's pin for NR under the preset qa-pin
  ed "$1" role-assignments --arg id "$2" --arg r "$NR" --arg c "$4" --arg m "$5" --arg g "$(uuid)" --arg i "$IID" --argjson s "$3" \
    '.assignments += [{id: $id, scope: $s, role: $r, effort_mode: "qa-pin", chain: [{connection: $c, model: $m, parameters: {temperature: 0}}], global_id: $g, install_id: $i}]'
}
L() { echo "{connection: \"$1\", model: \"$1-$2\", parameters: {}}"; }
preset pn qa-pin "{class_order: [\$x, \$f, \$l], roles: {(\$r): {active: true, class_order: [\$l], last_resort: \$x, pins: [$(L qa-front m2)], fallbacks: [$(L qa-free m1), $(L qa-front m1), $(L qa-local m2)]}}}"
pin pn qa-p-g '{"level":"global"}' qa-free qa-free-m2; pin pn qa-p-p "$INPROJ" qa-agg qa-agg-m1
pin pn qa-p-c '{"level":"card","project":"qa-proj","card":"qa-card"}' qa-local qa-local-m2
rs pn pn1 --role "$NR" --project qa-proj --card qa-card --driver "$ENGINE"; rs pn pn2 --role "$NR" --project qa-other --driver "$WORKER"
ok 'passes pn && [ "$(rc pn1)" = 0 ] && J pn1 "[.chain[:4][] | [.connection + \"/\" + .model, .source]] == [[\"qa-local/qa-local-m2\", \"pin:card\"], [\"qa-agg/qa-agg-m1\", \"pin:project\"], [\"qa-free/qa-free-m2\", \"pin:global\"], [\"qa-front/qa-front-m2\", \"preset\"]]"' \
  "8 the chain starts with the owner's pins (card, project, global), then the preset's pin for the role"
ok 'J pn1 ".chain[0] | .status == \"usable\" and .parameters == {temperature: 0}" && J pn1 "$(ent qa-free qa-free-m2) | all(.status == \"excluded\" and .code == \"$C_POLICY\")" && J pn1 "$(ent qa-front qa-front-m2) | all(.status == \"needs_grant\" and .grant.kind == \"crossing\")"' \
  "8a a pin is judged like any link: usable in the role's own class order, excluded outside it, a crossing in its last-resort class"
ok 'J pn1 "[.chain[] | select(.source == \"fallback\") | [.connection + \"/\" + .model, .status]] == [[\"qa-free/qa-free-m1\", \"excluded\"], [\"qa-front/qa-front-m1\", \"needs_grant\"]]" &&
  J pn1 "[.chain[].source] | (index(\"fallback\") > ([to_entries[] | select(.value == \"preset\") | .key] | max)) and (index(\"last_resort\") > ([to_entries[] | select(.value == \"fallback\") | .key] | max))"' \
  "8b the preset's fallbacks come after the class candidates and before the last-resort class, judged like pins; a link listed twice keeps its first place"
ok 'J pn2 "[.chain[] | select(.source | startswith(\"pin:\")) | .source] == [\"pin:global\"]" && J pn2 "all(.chain[]; .mid_task == false)"' \
  "8c another project gets the global pin only; under a driver that never switches mid-task no link is mid-task"
ok 'J pn1 "$(ent qa-agg qa-agg-m1) | all(.mid_task == true)" && J b "$(ent qa-agg) | all(.mid_task == false)" && J b "$(ent qa-local) | all(.mid_task == true)" && J b "$(ent qa-cli) | all(.mid_task == false)"' \
  "8d mid-task under a driver that allows it: on an aggregator only for the role pinned to that link, never on a CLI login"

# ---- 9: a best-of group, the needs class ----
score() { ed "$1" connections --arg c "$2" --argjson s "$3" '.entries |= map(if .id == $c then .models[].score = $s else . end)'; }
first() { echo "[.chain[] | select(.status == \"usable\")][0].connection == \"$1\""; }
mk bs base; preset bs qa-best '{class_order: [[$f, $l]], needs_class: $x, frontier_when: {tiers: [$t]}, last_resort: null}'
mk bs1 bs; score bs1 qa-free 0.9; score bs1 qa-local 0.1
mk bs2 bs; score bs2 qa-free 0.5; score bs2 qa-local 0.5
mk bs3 bs1; state bs3 "{\"links\":{\"qa-free\":{\"until\":\"$SOON\"}},\"tasks\":{}}"
mk bs4 bs1; edt bs4 --arg r "$NR" '.roles[$r].requirements.min_context_tokens = 4096'
ed bs4 connections '.entries |= map(if .id == "qa-free" or .id == "qa-agg" or .id == "qa-local" then .models[].capabilities.context_tokens = 4095 else . end)'
for r in bs1 bs2 bs3 bs4; do rs "$r" "$r" --role "$NR" --project qa-proj; done; rs bs1 bs5 --role "$NR" --project qa-proj --tier "$TIER"
ok 'passes bs1 && J bs1 "$(first qa-free)" && J bs1 ".decision.rule == \"best_suited\" and (.decision.reason | test(\"qa-free/qa-free-m1\"))" && J bs1 "all(.chain[]; .link_class != \"$FRONT\")"' \
  "9 a best-of group: the higher advertised score (the prior) ranks first, with the reason; the needs class is not used for an unlisted tier"
ok 'J bs1 "[.chain[].connection] as \$c | ([\$c[0]] + [range(1; \$c | length) | select(\$c[.] != \$c[. - 1]) | \$c[.]]) | length == (unique | length)"' "9a the links of one connection stay adjacent in the ranked group"
ok 'passes bs2 && J bs2 "$(first qa-local)"' "9b equal scores: the more private class ranks first"
ok 'J bs3 "$(first qa-local)" && J bs3 "$(ent qa-free) | length == 2 and all(.status == \"cooldown\")"' "9c health ranks before score: links in cooldown fall behind"
ok 'passes bs4 && J bs4 ".chain[0].link_class == \"$FRONT\" and [.chain[] | select(.status == \"usable\")][0].link_class == \"$FRONT\""' "9d the needs class goes first when no link of the group meets the role's requirements"
ok 'J bs5 ".chain[0].link_class == \"$FRONT\" and (.decision.reason | length > 0)" && J bs5 "$(ent qa-free) | length == 2"' "9e the needs class goes first for a listed task tier, the group after it"

# ---- 10: health and the task's history from the state file ----
mk cd base
state cd "{\"links\":{\"qa-local/qa-local-m1\":{\"until\":\"$SOON\"},\"qa-local/qa-local-m2\":{\"until\":\"$RECENT\"},\"qa-free\":{\"until\":\"$SOON\"},\"qa-front/qa-front-m1\":\"junk\",\"qa-front/qa-front-m2\":{\"until\":7}},
  \"tasks\":{\"qa-t\":{\"switches\":1,\"visited\":[\"qa-free/qa-free-m1\"],\"history\":[{\"link\":\"qa-free/qa-free-m1\",\"trigger\":\"qa-trigger\",\"at\":\"$RECENT\"}]}}}"
rs cd cd1 --role "$NR" --project qa-proj --task qa-t; rs cd cd2 --role "$NR" --project qa-proj --task qa-other
ok '[ "$(rc cd1)" = 0 ] && J cd1 "$(ent qa-local qa-local-m1) | length == 1 and all(.status == \"cooldown\" and .code == \"$C_COOL\" and .cooldown_until == \"$SOON\")" && J cd1 "$(ent qa-local qa-local-m2) | length == 1 and all(.status == \"usable\" and .cooldown_until == null)"' \
  "10 a link in cooldown stays in the chain with $C_COOL and cooldown_until; a cooldown that ended is over"
ok 'J cd1 "$(ent qa-free) | length == 2 and all(.status == \"cooldown\")" && J cd1 "$(ent qa-front) | length == 2 and all(.status == \"usable\")"' \
  "10a a cooldown under a connection's id cools each of its links; a state entry that is no cooldown record cools nothing"
ok 'J cd1 ".failure_history == [{link: \"qa-free/qa-free-m1\", trigger: \"qa-trigger\", at: \"$RECENT\"}]" && J cd2 ".failure_history == []"' "10b failure_history is the task's own history"
mk cdx base; state cdx '{"links":{"qa-local/qa-local-m1":{"until":"tomorrow"},"qa-free":{"until":""}},"tasks":{}}'; rs cdx cdx --role "$NR" --project qa-proj
ok '[ "$(rc cdx)" = 0 ] && J cdx "$(ent qa-local qa-local-m1) | length == 1 and all(.status == \"cooldown\" and .code == \"$C_COOL\" and .cooldown_until == null and (.reason | length > 0))" &&
  J cdx "$(ent qa-local qa-local-m2) | length == 1 and all(.status == \"usable\")" && J cdx "$(ent qa-free) | length == 2 and all(.status == \"cooldown\" and .cooldown_until == null)"' \
  "10c an until that is text but no date counts as still cooling (fail closed, as the call side reads it), under a link's key and under a connection's id; no time is echoed"

# ---- 11: card apps ----
mk ap base
TPL_APP='[.entries[] | select(.kind == "provider" and .type == "cli-login")][0] | del(.allowed_roles, .risk_class, .link_class) | .kind = "app" | .models = []'
TPL_INT='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "cloud" and (.aggregator | not))][0] | del(.allowed_roles, .risk_class, .link_class, .protocol)
  | .kind = "app" | .models = [] | .integration_aggregator = true | .data_policy.hosted = true | .data_policy.data_classes_allowed = []'
app() { ed ap connections --arg id "$1" --arg g "$(uuid)" --argjson o "$3" ".entries += [($2) + {id: \$id, label: \"QA app\", enabled: true, global_id: \$g} + \$o]"; }
app qa-app-ok "$TPL_APP" '{"terms_ok":true}'; app qa-app-no "$TPL_APP" '{"terms_ok":null}'; app qa-app-int "$TPL_INT" '{}'
facts ap qa-a1 "$(jq -c '.apps = ["qa-app-ok", "qa-app-int"]' <<<"$CLEAN")"; facts ap qa-a2 "$(jq -c '.apps = ["qa-app-ok", "qa-app-no"]' <<<"$CLEAN")"
facts ap qa-a3 "$(jq -c --arg k "$FACT" '.apps = ["qa-app-int"] | .[$k] = true' <<<"$CLEAN")"; facts ap qa-a4 "$(jq -c '.apps = ["qa-zz", "qa-local"]' <<<"$CLEAN")"
for c in a1 a2 a3 a4; do rs ap "ap-$c" --role "$CR" --project qa-proj --card "qa-$c"; done
ok 'passes ap && [ "$(rc ap-a1)" = 0 ] && J ap-a1 ".apps == [{app: \"qa-app-ok\", status: \"usable\", code: null, reason: null}, {app: \"qa-app-int\", status: \"usable\", code: null, reason: null}]"' \
  "11 a clean card: a CLI login app with terms_ok and a hosted integration aggregator app are both usable, exit 0"
ok '[ "$(rc ap-a2)" = 0 ] && J ap-a2 "[.apps[] | [.app, .code]] == [[\"qa-app-ok\", null], [\"qa-app-no\", null]] and any(.chain[]; .status == \"usable\")"' \
  "11a a CLI login app without terms_ok is usable like the one with terms_ok (terms_ok is never enforced): exit 0"
ok '[ "$(rc ap-a3)" = 1 ] && J ap-a3 ".apps == [{app: \"qa-app-int\", status: \"excluded\", code: \"$C_HARD\", reason: .apps[0].reason}] and (.apps[0].reason | length > 0)"' \
  "11b a hosted integration aggregator app on a card whose fact holds is refused with $C_HARD"
ok '[ "$(rc ap-a4)" = 1 ] && J ap-a4 "[.apps[] | .code] == [\"$C_UNKNOWN\", \"$C_UNKNOWN\"]"' "11c an app id the catalog does not hold, or that is no app, is refused with $C_UNKNOWN"

# ---- 12: read-only ----
listing() { (cd "$T/$1" && find . | sort && find . -type f -print0 | sort -z | xargs -0 sha256sum); }
mk ro cd; listing ro >"$T/ro.before"
rs ro ro1 --role "$NR" --project qa-proj --task qa-t; rs ro ro2 --role "$CR" --project qa-proj --card qa-card; rs ro ro3 --role "$CR" --project qa-proj --card qa-norecord
rs ro ro4 --role qa-zz --project qa-proj; listing ro >"$T/ro.after"
ok '[ "$(rc ro1)" = 0 ] && [ -s "$T/ro.before" ] && cmp -s "$T/ro.before" "$T/ro.after"' "12 four resolves (a task, a card, a card with no record, an unknown role) change no file or folder of the root"
mk ro0 base; rm -rf "$T/ro0/$FACTS"; rs ro0 ro5 --role "$CR" --project qa-proj --card qa-card --task qa-t
ok '[ "$(rc ro5)" = 0 ] && J ro5 "$HARD" && [ ! -e "$T/ro0/$FACTS" ] && [ ! -e "$T/ro0/$STATE" ]' "12a with no state file and no card facts store the resolver answers (the card's facts count as missing) and creates neither"

# ---- 13: role_view(role, project, card): the one copy of the rule resolve() reads ----
rv() {  # <root> <name> <role> <project> [<card>]: o/<name>.json = {view, differs: what resolve() says otherwise ([] = they agree; null: resolve() refuses)}
  probes "$1"; STELLA_ROOT=$T/$1 python3 -I -B - "$BIN" "${@:3}" >"$T/o/$2.json" 2>"$T/o/$2.err" <<'P'
import json, sys
sys.path.insert(0, sys.argv[1])
import resolve as r
role, project, card = (sys.argv[2:] + [None])[:3]
v = r.role_view(role, project, card)
try:
    o = r.resolve({"role": role, "project": project, "card": card})
except r.sd.DataError:
    o = None
bad = None
if o is not None:
    ch, key = o["chain"], lambda l: (l["connection"], l["model"])
    flat = [k for it in v["class_order"] for k in (it if isinstance(it, list) else [it])]
    own = [e for e in ch if e["source"] == "preset" and key(e) not in {key(l) for l in v["preset_pins"]}]
    tests = {
        "preset": o["preset"] == v["preset"], "local_only": o["local_only"] == v["local_only"],
        "active": (o["decision"]["rule"] == "inactive") == (not v["active"]) and (v["active"] or ch == []),
        "pins": not v["active"] or [key(e) for e in ch if e["source"].startswith("pin:")] == list(dict.fromkeys(key(l) for p in v["pins"] for l in p["chain"])),
        "pin scopes": not v["active"] or [e["source"] for e in ch if e["source"].startswith("pin:")] == ["pin:" + p["scope"] for p in v["pins"] for _ in p["chain"]],
        "class order": {e["link_class"] for e in own} <= set(flat) | {v["needs_class"]},
        "last resort": {e["link_class"] for e in ch if e["source"] == "last_resort"} <= {v["last_resort"]},
        "fallbacks": {key(e) for e in ch if e["source"] == "fallback"} <= {key(l) for l in v["fallbacks"]}}
    bad = [k for k, held in tests.items() if not held]
print(json.dumps({"view": v, "differs": bad}))
P
}
mk ov base; ed ov role-assignments --arg r "$NR" --arg l "$LOCAL" --arg g "$(uuid)" --arg i "$IID" '.assignments += [{id: "qa-ov", scope: {level: "project", project: "qa-proj"}, role: $r,
  effort_mode: "qa-all", chain: [{connection: "qa-local", model: "qa-local-m2", parameters: {}}], class_order: [$l], global_id: $g, install_id: $i}]'
rv pn v-pn "$NR" qa-proj qa-card; rv x v-x "$NR" qa-proj; rv x v-ex "$ER" qa-proj; rv off v-off "$NR2" qa-proj; rv lp-a v-lo "$NR" qa-proj
rv bs1 v-bs "$NR" qa-proj; rv ov v-ov "$NR" qa-proj; rv base v-b "$NR" qa-proj; rv base v-nocard "$CR" qa-proj
agree() { local n; for n; do J "$n" ".differs == []" || { echo "role_view ($n): $(jq -c .differs "$T/o/$n.json" 2>&1; tail -n 1 "$T/o/$n.err")" >&2; return 1; }; done; }
ok 'agree v-pn v-x v-ex v-off v-lo v-bs v-ov v-b' \
  "13 resolve() and role_view() agree on the preset, Local only, the role's activity, the owner's pins and their scopes, the class order, the last resort and the fallbacks (eight requests)"
ok 'J v-pn ".view | .active == true and .preset == {id: \"qa-pin\", source: \"global\"} and .class_order == [\"$LOCAL\"] and .order_source == \"preset\" and .last_resort == \"$FRONT\" and .needs_class == null
  and ([.pins[] | [.scope, .chain[0].connection]] == [[\"card\", \"qa-local\"], [\"project\", \"qa-agg\"], [\"global\", \"qa-free\"]])"' \
  "13a the role's own class order and last resort under the preset, and the owner's pins with their scope (card, project, global)"
ok 'passes ov && J v-ov ".view | .order_source == \"assignment:project\" and .class_order == [\"$LOCAL\"]" && J v-b ".view | .order_source == \"preset\" and .class_order == [\"$FRONT\", \"$FREE\", \"$LOCAL\"] and .pins == []"' \
  "13b an assignment's class order overrides the preset's, and the view names its scope"
ok 'J v-ex --argjson o "$EXO" ".view | .exempt == true and .order_source == \"exempt\" and .class_order == \$o and .last_resort == null and .needs_class == null" &&
  J v-lo ".view | .local_only == true and .order_source == \"local_only\" and .class_order == [\"$LOCAL\"] and .last_resort == null and .needs_class == null"' \
  "13c an exempt role keeps its own order, and Local only makes the local class the order: no last resort either way"
ok 'J v-bs ".view | .class_order == [[\"$FREE\", \"$LOCAL\"]] and .needs_class == \"$FRONT\"" && J v-x ".view | .class_order == [\"$FRONT\"] and .last_resort == \"$LOCAL\""' \
  "13d the class order is the one before any class is put first; the class that may be put first is told apart (needs_class)"
ok 'J v-off ".view | .active == false and (.class_order | length > 0)" && J v-nocard ".differs == null and (.view | .active == true and .card == null and (.class_order | length > 0))"' \
  "13e it answers for a role the preset turns off, and for a role that works a card asked with no card"


# ---- 14: the escalation chain walk (F2b item D, design-D.md): --rung N, effort as data ----
# the trusted event writer must see no worker run: a stub marker, a board stub for `roles.py prove`, no agent token
unset HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_DELEGATED_CHILD_CONTEXT STUB_WORKER_MARK
for v in $(jq -r '.worker_signals.token_env[]?' "$ROOT/$(j '.files[] | select(.id == "owner-auth") | .path' "$IX")" 2>/dev/null); do unset "$v"; done
mkdir -p "$T/pb"; printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH
read -r C_EXH C_SKIP < <(python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import resolve as r; print(r.EXHAUSTED, r.RUNG_SKIPPED)' "$BIN")
EVREL=$(j .event_log "$IX"); evn() { local f="$T/$1/$EVREL"; if [ -f "$f" ]; then jq -c "select($2)" "$f" | grep -c .; else echo 0; fi; }   # <root> <jq condition>
L() { echo "{\"connection\":\"$1\",\"model\":\"$1-$2\",\"parameters\":${3:-{\}}}"; }   # <connection> <m1|m2> [<parameters JSON>]
mk rg base; mkdir -p "$T/rg/.supervisor/logs" "$T/rg/.supervisor/state"; edt rg '.worker_markers = ["STUB_WORKER_MARK"]'
# fake effort levels and a per-role/tier table (data only); an Eco-shaped preset: local and the aggregator class in order, the frontier class last resort
ed rg routing --arg r "$NR" --arg r2 "$NR2" --arg t "$TIER" '.effort.levels += ["qa-lo", "qa-mid", "qa-hi"] | .effort.by_role[$r] = {default: "qa-lo", tiers: {($t): "qa-mid"}} | del(.effort.by_role[$r2])'
preset rg qa-rung '{class_order: [$l, $f], last_resort: $x}'
ed rg role-assignments --arg r "$NR" --arg e "$ER" --argjson ch "[$(L qa-local m1 '{"effort":"qa-hi"}'), $(L qa-free m2), $(L qa-front m1), $(L qa-local m2)]" \
  --argjson ex "[$(L qa-free m1), $(L qa-local m2)]" '.effort_modes["qa-rung"].roles = {($r): {active: true, escalation_chain: $ch}, ($e): {active: true, escalation_chain: $ex}}'
rs rg h0 --role "$NR" --project qa-proj; rs rg ht --role "$NR" --project qa-proj --tier "$TIER"; rs rg hz --role "$NR" --project qa-proj --rung 0
rs rg h2 --role "$NR2" --project qa-proj; rs rg r1 --role "$NR" --project qa-proj --rung 1 --tier "$TIER"
ok 'passes rg && [ "$(rc h0)" = 0 ] && J h0 "all(.chain[]; .effort == \"qa-lo\") and (has(\"rung\") | not)" && J ht "all(.chain[]; .effort == \"qa-mid\")" && J h2 "all(.chain[]; .effort == null)" && cmp -s "$T/o/h0.json" "$T/o/hz.json"' \
  "14 effort is data: the role's tier entry, else its default, else null, on every chain entry; --rung 0 is the answer without --rung, byte for byte, with no rung key"
ok '[ "$(rc r1)" = 0 ] && J r1 --slurpfile h "$T/o/ht.json" "([\$h[0].chain[] | select(.status == \"usable\")][0]) as \$u | .rung.requested == 1 and .rung.served == 1 and .rung.last == 4 and .rung.skipped == [] and .code == null and .chain == [.rung.link]
  and .rung.link.connection == \$u.connection and .rung.link.model == \$u.model and \$u.effort == \"qa-mid\" and .rung.link.effort == \"qa-hi\" and .rung.link.status == \"usable\""' \
  "14a rung 1 keeps the first usable link's model and raises its effort (the link's parameters beat the role's tier entry)"
mk rgs rg; ed rgs routing --arg r2 "$NR2" '.effort.by_role[$r2] = "qa-hi"'; rs rgs hs --role "$NR2" --project qa-proj
ok 'passes rgs && J hs "(.chain | length > 0) and all(.chain[]; .effort == \"qa-hi\")"' "14a2 a role's effort given as an id alone is its default"
n0=$(evn rg "true"); rs rg r3 --role "$NR" --project qa-proj --rung 3; n1=$(evn rg "true")
ok '[ "$(rc r3)" = 0 ] && J r3 ".rung.served == 4 and [.rung.skipped[] | [.rung, .connection, .status, .code]] == [[3, \"qa-front\", \"needs_grant\", \"$C_CROSS\"]]" &&
  [ $((n1 - n0)) = 1 ] && [ "$(evn rg ".type == \"routing.rung-skipped\" and .code == \"$C_SKIP\"")" = 1 ]' \
  "14b a last-resort rung with no crossing grant is skipped (needs_grant $C_CROSS) and the next rung served; one trusted $C_SKIP line"
mk rgg rg; cgrant rgg qa-cg qa-rung "$FRONT" '{"level":"global"}'; rs rgg g3 --role "$NR" --project qa-proj --rung 3
ok 'passes rgg && [ "$(rc g3)" = 0 ] && J g3 ".rung.served == 3 and .rung.skipped == [] and .rung.link.connection == \"qa-front\""' "14c with a crossing grant in force the same rung is served"
mk rgl rg; ed rgl data-policy '.default.mode = "local_only"'; n0=$(evn rgl ".type == \"routing.rung-skipped\""); rs rgl l2 --role "$NR" --project qa-proj --rung 2
ok 'passes rgl && [ "$(rc l2)" = 0 ] && J l2 ".local_only and .rung.served == 4 and [.rung.skipped[] | [.rung, .status, .code]] == [[2, \"excluded\", \"$C_POLICY\"], [3, \"excluded\", \"$C_POLICY\"]]" &&
  [ $(( $(evn rgl ".type == \"routing.rung-skipped\"") - n0 )) = 2 ]' \
  "14d Local only: both cloud rungs are skipped (excluded $C_POLICY, in rung order, one line each), the local rung served"
m0=$(evn rg ".type == \"routing.rung-exhausted\""); rs rg x5 --role "$NR" --project qa-proj --rung 5; rs rg nc --role "$NR2" --project qa-proj --rung 1
ok '[ "$(rc x5)" = 1 ] && J x5 ".code == \"$C_EXH\" and .rung.served == null and .rung.link == null and .chain == []" && grep -q "^$C_EXH " "$T/o/x5.err" &&
  [ "$(rc nc)" = 1 ] && J nc ".code == \"$C_EXH\" and .rung.last == 0" && [ $(( $(evn rg ".type == \"routing.rung-exhausted\" and .code == \"$C_EXH\"") - m0 )) = 2 ]' \
  "14e past the last rung, and for a role with no chain: $C_EXH (escalate to the owner), exit 1, one routing.rung-exhausted line each"
rs rg ex1 --role "$ER" --project qa-proj --rung 1
ok '[ "$(rc ex1)" = 0 ] && J ex1 ".rung.served == 2 and [.rung.skipped[] | [.rung, .status, .code]] == [[1, \"excluded\", \"$C_POLICY\"]]"' \
  "14f an exempt role keeps its own class order for its rungs: a hosted rung is excluded ($C_POLICY), its local rung served"
mk rgc rg; state rgc "{\"links\":{\"qa-local/qa-local-m1\":{\"until\":\"$SOON\"}},\"tasks\":{}}"; n0=$(evn rgc "true"); rs rgc c1 --role "$NR" --project qa-proj --rung 1
ok '[ "$(rc c1)" = 1 ] && J c1 ".rung.served == 1 and .rung.link.status == \"cooldown\" and .code == \"$C_COOL\"" && [ "$(evn rgc "true")" = "$n0" ]' \
  "14g a rung in cooldown is answered as itself ($C_COOL, exit 1): no climb, no event line"
n0=$(evn rgl "true"); STUB_WORKER_MARK=1 rs rgl wk --role "$NR" --project qa-proj --rung 2
STELLA_ROOT=$T/rgl python3 -I -B -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import resolve as r
print(json.dumps(r.resolve({"role": sys.argv[2], "project": "qa-proj", "rung": 2})))' "$BIN" "$NR" >"$T/o/imp.json" 2>"$T/o/imp.err"
ok 'closed wk STL-CFG-312 && J imp ".rung.served == 4 and (.rung.skipped | length) == 2" && [ "$(evn rgl "true")" = "$n0" ]' \
  "14h --rung in a worker environment fails closed (STL-CFG-312, no answer); resolve(ctx) with a rung answers the same walk and writes no event line"
mk rgf rgl; rm -f "$T/rgf/$EVREL"; mkdir -p "$T/rgf/$EVREL"; rs rgf f2 --role "$NR" --project qa-proj --rung 2; rs rgf f5 --role "$NR" --project qa-proj --rung 5
ok '[ "$(rc f2)" = 1 ] && J f2 ".chain == [] and .rung.served == null and (.code | test(\"^STL-[A-Z]+-[0-9]{3}$\")) and .code != \"$C_EXH\"" &&
  [ "$(rc f5)" = 1 ] && J f5 ".code == \"$C_EXH\" and (.rung.log_code | test(\"^STL-[A-Z]+-[0-9]{3}$\"))"' \
  "14i an event log that cannot be written: a served rung after skips is withdrawn (the log's code); an exhausted walk keeps $C_EXH and names the log's code"
# W1P-04: the widening is the rung's only: with no --rung a preset pin of the needs class outside the class order stays excluded
mk rgn base; preset rgn qa-nc "{class_order: [\$l], needs_class: \$x, last_resort: null, roles: {(\$r): {active: true, pins: [$(L qa-front m1)]}}}"; rs rgn nn --role "$NR" --project qa-proj
ok 'passes rgn && [ "$(rc nn)" = 0 ] && J nn "[.chain[] | select(.connection == \"qa-front\" and .model == \"qa-front-m1\")][0] | .status == \"excluded\" and .code == \"$C_POLICY\""' \
  "14i2 no --rung: a preset pin of the needs class outside the class order is excluded $C_POLICY (the rung's wider classes are the rung's only)"
# a rung whose connection is no provider (data check refuses it, so the loaded data is edited after it): skipped as excluded $C_UNKNOWN, rung numbers kept
STELLA_ROOT=$T/rg python3 -I -B -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import resolve as r
orig = r._data
def patched(*a, **k):
    d = orig(*a, **k)
    d.ra["effort_modes"]["qa-rung"]["roles"][sys.argv[2]]["escalation_chain"][0]["connection"] = "qa-nope"
    return d
r._data = patched
print(json.dumps(r.resolve({"role": sys.argv[2], "project": "qa-proj", "rung": 1})))' "$BIN" "$NR" >"$T/o/np.json" 2>"$T/o/np.err"
ok 'J np ".rung.last == 4 and .rung.served == 2 and [.rung.skipped[] | [.rung, .connection, .link_class, .status, .code]] == [[1, \"qa-nope\", null, \"excluded\", \"$C_UNKNOWN\"]]"' \
  "14i3 a rung whose connection is no provider is skipped (excluded $C_UNKNOWN), never dropped: the next rung keeps its number"
for v in -1 x 1.5; do rs rg "u$v" --role "$NR" --project qa-proj --rung "$v"; done
ok '[ "$(rc u-1)" = 2 ] && [ "$(rc ux)" = 2 ] && [ "$(rc u1.5)" = 2 ]' "14j --rung that is not a non-negative integer is a usage error (exit 2)"
ok '[ "$(sha256sum "$RS")" = "$sum0" ] && ! grep -q "qa-" "$RS"' "14k the walk and the fake effort levels needed no change to the resolver's file, which names no fake id"

# ---- 15: probe data (F2b item C): rule 4, --tokens, the needs-class trigger and cross-family review read the probe records only ----
own() {  # <root> <JSON array of [connection, model, overrides]>: the root's probe records, each meeting every requirement unless overridden
  touch "$T/$1/.qa-own-probes"; mkdir -p "$(dirname "$T/$1/$PF")"
  jq -n --arg i "$IID" --arg o "$OSN" --argjson l "$2" '{schema_version: 1, records: [$l[] | {global_id: "00000000-0000-4000-8000-000000000000", install_id: $i,
    connection: .[0], model: .[1], version: "qa", probed_at: "2026-01-01T00:00:00Z", family: null, tool_calling: true, parallel_tool_calls: null, json: true,
    vision: true, output_shape: $o, context: {advertised: null, effective: 1048576, short_score: 1, points: []}, code: null} + .[2]]}' >"$T/$1/$PF"
}
mk pr base; own pr '[]'; a0=$(alerts STL-MDL-738); rs pr p0 --role "$NR" --project qa-proj; a1=$(alerts STL-MDL-738)
STELLA_ROOT=$T/pr python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import resolve as r; r.resolve({"role": sys.argv[2], "project": "qa-proj"})' "$BIN" "$NR" 2>/dev/null; a2=$(alerts STL-MDL-738)
ok '[ "$(rc p0)" = 0 ] && J p0 ".code == null and ([.chain[] | select(.connection == (\"qa-local\", \"qa-front\", \"qa-free\")) | select(.status != \"usable\" or .probed != false)] | length == 0)" &&
  [ $((a1 - a0)) = 1 ] && grep "^STL-MDL-738 " "$AL" | tail -1 | grep -qF "$(jq -r "[.chain[] | select(.status == \"usable\")][0] | .connection + \"/\" + .model" "$T/o/p0.json")" && [ "$a2" = "$a1" ]' \
  "15a owner ruling 2026-11-18: a link with no probe record may serve a role with requirements (usable, probed false); the CLI writes one STL-MDL-738 warning alert naming the link it serves; resolve(ctx) writes none"
mk pr2 pr; ed pr2 connections '(.entries[] | select(.id == "qa-local") | .models[0].capabilities) += {tool_calling: false, context_tokens: 1}'
own pr2 '[["qa-local", "qa-local-m1", {}], ["qa-local", "qa-local-m2", {"tool_calling": false}]]'; rs pr2 p1 --role "$NR" --project qa-proj
ok 'passes pr2 && J p1 "$(ent qa-local qa-local-m1) | .[0].status == \"usable\"" && J p1 "$(ent qa-local qa-local-m2) | .[0].code == \"$C_UNMET\" and (.[0].reason | test(\"probe record\"))"' \
  "15b the record decides, never the catalog: a model advertised with no tool calling and a 1-token window is usable by its record, one advertised able is excluded by its record"
own pr2 '[["qa-local", "qa-local-m1", {"context": {"advertised": null, "effective": 50000, "short_score": 1, "points": []}}], ["qa-front", "qa-front-m1", {"context": {"advertised": null, "effective": 0, "short_score": 1, "points": []}}]]'
ed pr2 role-assignments '.effort_modes["qa-all"].class_order |= .'; rs pr2 t0 --role "$NR" --project qa-proj; rs pr2 t1 --role "$NR" --project qa-proj --tokens 60000; rs pr2 tu --role "$NR" --project qa-proj --tokens -3
ok 'J t0 "$(ent qa-local qa-local-m1) | .[0].status == \"usable\"" && J t1 "$(ent qa-local qa-local-m1) | .[0].code == \"$C_UNMET\" and (.[0].reason | test(\"50000\") and test(\"60000\"))" && [ "$(rc tu)" = 2 ] &&
  J t1 "$(ent qa-front qa-front-m1) | .[0].code == \"$C_UNMET\"" && J t1 "$(ent qa-local qa-local-m2) | .[0].status == \"usable\" and .[0].probed == false"' \
  "15c --tokens N excludes a link whose probed effective context is below N ($C_UNMET, both sizes named; 0 too), not a link with no record (it may serve); without it nothing changes; a negative N is a usage error"
mk pn pr; preset pn qa-need '{class_order: [$l], needs_class: $x, last_resort: null}'; own pn '[["qa-front", "qa-front-m1", {}], ["qa-front", "qa-front-m2", {}]]'; rs pn n0 --role "$NR" --project qa-proj; rs pn n0t --role "$NR" --project qa-proj --tokens 99999999
own pn '[["qa-front", "qa-front-m1", {}], ["qa-front", "qa-front-m2", {}], ["qa-local", "qa-local-m1", {"tool_calling": false}], ["qa-local", "qa-local-m2", {"tool_calling": false}]]'
rs pn n1 --role "$NR" --project qa-proj; rs pn n2 --role "$NR" --project qa-proj --tokens 99999999
ok 'J n0 ".chain[0].link_class == \"$LOCAL\"" && J n0t ".chain[0].link_class == \"$LOCAL\"" && J n1 ".chain[0].link_class == \"$FRONT\" and ([.chain[] | select(.status == \"usable\")][0].link_class == \"$FRONT\")" && J n2 ".chain[0].link_class == \"$FRONT\""' \
  "15d C-DC-02 the needs-class trigger counts an unprobed link as possibly serving (the order stays) and a failing record as not serving (the needs class first); --tokens never moves it"
VR=$(jq -r --arg c "$CR" '[.[] | select(. != $c)][0]' <<<"$CARDR")
U='[.chain[] | select(.status == "usable") | .model]'   # the usable links, in chain order
mk cf pr; edt cf '.worker_markers = ["STUB_WORKER_MARK"]'; ed cf routing --arg b "$CR" --arg v "$VR" '.cross_family = {builder_role: $b, reviewer_roles: [$v]}'; ed cf role-assignments '.effort_modes["qa-all"].cross_family_review = true'
own cf '[["qa-front", "qa-front-m1", {"family": "qa-fa"}], ["qa-front", "qa-front-m2", {"family": "qa-fb"}], ["qa-free", "qa-free-m1", {"family": "qa-fb"}]]'
n0=$(evn cf true); rs cf c1 --role "$VR" --project qa-proj --card qa-card; rs cf cb --role "$CR" --project qa-proj --card qa-card; n1=$(evn cf true)
ok 'passes cf && [ "$(rc c1)" = 0 ] && J c1 ".cross_family.status == \"met\" and .cross_family.builder_family == \"qa-fa\" and .cross_family.served_family == \"qa-fb\" and $U[0:2] == [\"qa-front-m2\", \"qa-front-m1\"] and ($U | index(\"qa-free-m1\")) > ($U | index(\"qa-front-m1\"))" &&
  J cb "has(\"cross_family\") | not" && [ "$n1" = "$n0" ]' \
  "15e cross-family: the reviewer's other-family link moves first inside its class (never across classes: qa-free stays later), met, no event line; the builder's answer has no cross_family"
ed cf role-assignments '.effort_modes["qa-all"].cross_family_review = false'; rs cf c2 --role "$VR" --project qa-proj --card qa-card; n2=$(evn cf true)
STUB_WORKER_MARK=1 rs cf c3 --role "$VR" --project qa-proj --card qa-card; n3=$(evn cf true)
ok 'J c2 ".cross_family.status == \"waived\" and .cross_family.logged == true and $U[0:2] == [\"qa-front-m1\", \"qa-front-m2\"]" && [ $((n2 - n1)) = 1 ] && [ "$(evn cf ".type == \"routing.cross-family-waiver\" and .code == \"STL-MDL-737\"")" = 1 ] &&
  J c3 ".cross_family.status == \"waived\" and .cross_family.logged == false" && [ "$n3" = "$n2" ]' \
  "15f a preset without cross_family_review: waived, one trusted routing.cross-family-waiver line (STL-MDL-737), the order kept; in a worker environment logged false and no line"
# ruling (2): no lift across class-order items, none past a link of a lower privacy rank inside a best-of group; a waiver that cannot be written withdraws the answer
mk cx cf; preset cx qa-xb '{class_order: [$x, $l], last_resort: null, cross_family_review: true}'
own cx '[["qa-front", "qa-front-m1", {"family": "qa-fa"}], ["qa-front", "qa-front-m2", {"family": "qa-fa"}], ["qa-local", "qa-local-m1", {"family": "qa-fb"}], ["qa-local", "qa-local-m2", {"family": "qa-fa"}]]'
rs cx x1 --role "$VR" --project qa-proj --card qa-card
preset cx qa-xa '{class_order: [[$l, $x]], last_resort: null, cross_family_review: true}'
own cx '[["qa-local", "qa-local-m1", {"family": "qa-fa"}], ["qa-local", "qa-local-m2", {"family": "qa-fa"}], ["qa-front", "qa-front-m1", {"family": "qa-fb"}], ["qa-front", "qa-front-m2", {"family": "qa-fa"}]]'
rs cx x2 --role "$VR" --project qa-proj --card qa-card
ok 'J x1 ".cross_family.status == \"waived\" and .cross_family.builder_family == \"qa-fa\" and $U[0] == \"qa-front-m1\" and ($U | index(\"qa-local-m1\")) > ($U | index(\"qa-front-m2\"))" &&
  J x2 ".cross_family.status == \"waived\" and .cross_family.builder_family == \"qa-fa\" and $U[0:2] == [\"qa-local-m1\", \"qa-local-m2\"]"' \
  "15h cross-family never lifts a link of another family across class-order items (class order [$FRONT, $LOCAL]) nor past a more private link inside a best-of group ([[$LOCAL, $FRONT]]): waived, order kept"
preset cx qa-xc '{class_order: [$x], last_resort: null, cross_family_review: false}'; rm -f "$T/cx/$EVREL"; mkdir -p "$T/cx/$EVREL"; rs cx x3 --role "$VR" --project qa-proj --card qa-card; rmdir "$T/cx/$EVREL"
ok '[ "$(rc x3)" = 1 ] && J x3 ".chain == [] and (.code | test(\"^STL-[A-Z]+-[0-9]{3}$\")) and .cross_family.status == \"waived\" and .cross_family.logged == false"' \
  "15i a waiver line that cannot be written (the event log is a folder) withdraws the answer: exit 1, chain [], the event log's code"
ok '! J p0 ".stubs | index(\"routing-advertised-capabilities\") or index(\"routing-advertised-context\")" && ! grep -q "advertised-capabilities\|advertised-context" "$RS"' \
  "15g C-DC-06 no answer and no resolver code rests on the advertised-capability or advertised-context stubs"

# ---- 16: F2b fix round (CRT-01, CRT-02, CRT-04, CRT-05) ----
mk pb pr; own pb '[["qa-local", "qa-local-m1", {"tool_calling": false}], ["qa-local", "qa-local-m2", {"tool_calling": false}]]'
jq '.records += [.records[0] | .global_id = "11111111-1111-4111-8111-111111111111"]' "$T/pb/$PF" >"$T/pb/$PF.n" && mv "$T/pb/$PF.n" "$T/pb/$PF"
rs pb b1 --role "$NR" --project qa-proj; STELLA_ROOT=$T/pb python3 -I -B "$SD" check >"$T/o/pbcheck" 2>&1; kb=$?
ok '[ "$(rc b1)" = 1 ] && J b1 "([.chain[] | select(.status == \"usable\")] | length) == 0 and ([.chain[] | select(.connection == \"qa-front\")][0] | .code == \"$C_UNMET\" and (.reason | test(\"probe records\")))" &&
  [ "$kb" != 0 ] && grep -q "^STL-MDL-739 " "$T/o/pbcheck"' \
  "16a CRT-01 a probe records file that is present but unusable (a duplicate record) lifts no refusal: every link with no usable record is unmet ($C_UNMET, the file named), check fails with STL-MDL-739"
mk cr base; preset cr qa-x "{class_order: [\$l], needs_class: \$x, last_resort: \$x, frontier_when: {tiers: [\$t]}, roles: {(\$r): {active: true, escalation_chain: [$(L qa-front m1)]}}}"
rs cr x1 --role "$NR" --project qa-proj --rung 1 --tier "$TIER"
ok 'passes cr && J x1 ".rung.served == null and [.rung.skipped[] | [.rung, .status, .code]] == [[1, \"needs_grant\", \"$C_CROSS\"]]"' \
  "16b CRT-02 DC-05 a needs class that is also the last resort, put first by a listed tier, still needs a crossing grant on its rung ($C_CROSS)"
rm -f "$AL"; mkdir "$AL"; rs pr f1 --role "$NR" --project qa-proj; rmdir "$AL"; : >"$AL"
ok '[ "$(rc f1)" = 1 ] && J f1 ".chain == [] and .code == \"STL-CFG-318\""' "16c CRT-04 an unprobed pick whose STL-MDL-738 alert line cannot be written is withdrawn (chain [], STL-CFG-318)"
mk cr5 cf; ed cr5 role-assignments --arg v "$VR" --argjson ch "[$(L qa-front m1)]" '.effort_modes["qa-all"] |= (.cross_family_review = true | .roles[$v] = ((.roles[$v] // {active: true}) + {escalation_chain: $ch}))'
n0=$(evn cr5 '.type == "routing.cross-family-waiver"'); rs cr5 v1 --role "$VR" --project qa-proj --card qa-card --rung 1; n1=$(evn cr5 '.type == "routing.cross-family-waiver"')
ok 'passes cr5 && [ "$(rc v1)" = 0 ] && J v1 ".rung.served == 1 and .cross_family.status == \"waived\" and .cross_family.builder_family == \"qa-fa\" and .cross_family.logged == true" && [ $((n1 - n0)) = 1 ]' \
  "16d CRT-05 a review role served on a rung of the builder's family is judged too: waived, one routing.cross-family-waiver line"

# ---- 17: F2c A2 the usage ledger's quota (daily cap, observed limit, plan share, free slot) and the stub that is gone ----
LGR() { STELLA_ROOT=$T/$LGROOT python3 -I -B "$BIN/ledger.py" "$@"; }   # the ledger CLI on the scratch root named in LGROOT
lgrec() { jq -nc --arg c "$1" --arg m "$2" --argjson pl "${3:-null}" '{connection: $c, model: $m, outcome: "ok", plan_share: $pl}' | LGR record --json >/dev/null; }   # <connection> <model> [plan share]
mk lg base; mkdir -p "$T/lg/.supervisor/logs" "$T/lg/.supervisor/state"; LGROOT=lg
ed lg connections '(.entries[] | select(.id == "qa-front") | .models[0].limits) = {per_day: 1} | (.entries[] | select(.id == "qa-front") | .models[1].limits) = {max_concurrent: 1}'
lgrec qa-front qa-front-m1
rs lg q1 --role "$NR" --project qa-proj
TOM=$(date -u -d tomorrow +%FT00:00:00Z)
ok '[ "$(rc q1)" = 0 ] && J q1 --arg c "$C_COOL" --arg t "$TOM" "$(ent qa-front qa-front-m1) | length == 1 and all(.[]; .status == \"cooldown\" and .code == \$c and .cooldown_until == \$t and (.reason | test(\"daily limit\")))" &&
  J q1 "$(ent qa-front qa-front-m2) | all(.[]; .status == \"usable\")"' "17a a link whose daily cap is used is cooldown ($C_COOL), cooldown_until the ledger's reset (next UTC midnight); the model beside it stays usable"
ok '[ ! -e "$T/lg/.supervisor/state/ledger-state.json.slots" ] && [ ! -e "$T/lg/.supervisor/state/ledger-state.json" ]' "17b the resolver made no slot folder and no ledger state file (read-only)"
( exec env STELLA_ROOT=$T/$LGROOT python3 -I -B "$BIN/ledger.py" hold --connection qa-front --model qa-front-m2 -- sleep 30 ) & HP=$!
for _ in $(seq 100); do [ "$(LGR status --connection qa-front --model qa-front-m2 --json | jq .concurrency.in_use)" = 1 ] && break; sleep 0.1; done
rs lg q2 --role "$NR" --project qa-proj; kill $HP 2>/dev/null; wait $HP 2>/dev/null
ok 'J q2 --arg c "$C_COOL" "$(ent qa-front qa-front-m2) | length == 1 and all(.[]; .status == \"cooldown\" and .code == \$c and .reason == \"no free slot\" and .cooldown_until == null)"' "17c a link with no free slot is cooldown ($C_COOL), reason \"no free slot\", cooldown_until null"
echo "You've hit your usage limit" | LGR observe --connection qa-cli --json >"$T/o/obs.json"; OU=$(jq -r .until "$T/o/obs.json")
rs lg q3 --role "$NR" --project qa-proj
ok '[ -n "$OU" ] && [ "$OU" != null ] && J q3 --arg c "$C_COOL" --arg u "$OU" "$(ent qa-cli) | length > 0 and all(.[]; .status == \"cooldown\" and .code == \$c and .cooldown_until == \$u)"' "17d a cli-login link with an observed limit (its CLI's limit text) is cooldown until the observed end"
mk lg2 base; mkdir -p "$T/lg2/.supervisor/logs" "$T/lg2/.supervisor/state"; LGROOT=lg2; lgrec qa-cli qa-cli-m1 1
rs lg2 q4 --role "$NR" --project qa-proj
ok 'J q4 --arg c "$C_COOL" "$(ent qa-cli) | length > 0 and all(.[]; .status == \"cooldown\" and .code == \$c and (.reason | test(\"plan\")))"' "17e a cli-login link whose plan share is at the limit of the data (limit-signals plan_share_limit) is cooldown"
mk lg3 base; mkdir -p "$T/lg3/.supervisor/logs" "$T/lg3/.supervisor/state"; LGROOT=lg3
printf '{not json' >"$T/lg3/$(p limit-signals)"   # the ledger's signals data cannot be read: any error of the ledger read, not only its Stop
rs lg3 q5 --role "$NR" --project qa-proj
ok 'J q5 --arg c "$C_COOL" "$(ent qa-cli) | length > 0 and all(.[]; .status == \"cooldown\" and .code == \$c and (.reason | test(\"usage ledger cannot be used\")) and .cooldown_until == null)"' "17g A-RT-07 an error of the ledger read that is no Stop (its data unreadable) answers that link as cooldown ($C_COOL), reason \"the usage ledger cannot be used\", never an exception"
ok '! jq -e ".entries[] | select(.id == \"routing-observed-quota\")" "$ROOT/$(p features)" >/dev/null && ! grep -q routing-observed-quota "$RS" && J b ".stubs == []"' "17f the routing-observed-quota stub is gone from features.json and from the resolver's answers (T-STUB-QUOTA)"

# ---- 18: the ranking reads benchmark results (F2c item G), the advertised score is only the prior ----
# bench <root> <connection> <model> <tasks> <score>: benchmark records of the role NR (the compare writer: a trusted event line each)
bench() {
  mkdir -p "$T/$1/.supervisor/logs" "$T/$1/.supervisor/state" "$T/$1/home"
  HOME=$T/$1/home STELLA_ROOT=$T/$1 python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import compare
r, c, m, n, s = sys.argv[2:7]
compare.record_results([{"role": r, "connection": c, "model": m, "task": f"t{i}", "trial": 0, "passed": float(s) >= 0.5, "score": float(s), "ts": "2026-11-01T00:00:00Z", "suite_version": "s1"} for i in range(int(n))])' "$BIN" "$NR" "$2" "$3" "$4" "$5" || echo "bench failed: $*" >&2
}
sbf() { echo "$T/$1/$(jq -r .benchmark_results "$T/$1/.stella/data-files.json")"; }
last() { echo "[.chain[] | select(.status == \"usable\")][-1].connection == \"$1\""; }
MINT=$(jq -r .routing_min_tasks "$ROOT/.stella/model-check.json")
mk rk bs1                      # free 0.9, local 0.1 advertised
mk rk1 rk; bench rk1 qa-local qa-local-m1 "$MINT" 0.95; bench rk1 qa-free qa-free-m1 "$MINT" 0.2
mk rk2 rk; bench rk2 qa-local qa-local-m1 $((MINT - 1)) 0.95
mk rk3 rk; mk rk4 rk; bench rk3 qa-local qa-local-m1 "$MINT" 0.95; bench rk4 qa-local qa-local-m1 "$MINT" 0.95
jq '.records |= map(.score = 0.0)' "$(sbf rk3)" >"$T/rk3.n" && mv "$T/rk3.n" "$(sbf rk3)"    # edited by hand: its trusted line no longer matches
jq '.records |= map(.install_id = "00000000-0000-4000-8000-000000000000")' "$(sbf rk4)" >"$T/rk4.n" && mv "$T/rk4.n" "$(sbf rk4)"   # another install
mk rk5 rk; mkdir -p "$T/rk5/.supervisor/state"; echo '{not json' >"$(sbf rk5)"
mk rk6 rk; ed rk6 connections '.entries |= map(if .id == "qa-free" then .models |= map(del(.score)) else . end)'; bench rk6 qa-local qa-local-m1 "$MINT" 0.5
for r in rk1 rk2 rk3 rk4 rk5 rk6; do : >"$AL"; rs "$r" "$r" --role "$NR" --project qa-proj; cp "$AL" "$T/o/$r.alerts"; done
al() { grep -c "^$2 " "$T/o/$1.alerts"; }
ok 'passes rk1 && J rk1 "$(first qa-local)" && J rk1 ".decision.reason | test(\"benchmark\") and test(\"n=$MINT\")"' "18a a link with benchmark results over the minimum sample ranks above a higher advertised score; the reason names the score, its source and n"
ok 'J rk2 "$(first qa-free)" && J rk2 ".decision.reason | test(\"prior\")" && [ "$(al rk2 STL-MDL-781)" = 1 ] && [ "$(al rk2 STL-MDL-780)" = 0 ]' "18b a sample below the minimum keeps the advertised order, with one STL-MDL-781 line (the smaller sample would have changed the first pick)"
ok 'J rk3 "$(first qa-free)" && J rk4 "$(first qa-free)" && [ "$(al rk3 STL-MDL-780)" = 0 ] && [ "$(al rk4 STL-MDL-781)" = 0 ]' "18c a record whose trusted line does not match, and a record of another install, are ignored (advertised order)"
ok '[ "$(rc rk5)" = 0 ] && J rk5 "$(first qa-free)" && [ "$(al rk5 STL-MDL-780)" = 1 ]' "18d an unreadable benchmark file falls back to the advertised order with exactly one STL-MDL-780 line, no refusal"
ok 'J rk6 "$(first qa-local)" && J rk6 "$(last qa-free)" && J rk6 ".decision.reason | test(\"none\")"' "18e a link with no benchmark and no advertised score ranks last"
ok '! jq -e ".entries[] | select(.id == \"$SCORESTUB\")" "$ROOT/$(p features)" >/dev/null && ! grep -q "$SCORESTUB" "$RS" && J rk1 ".stubs == []"' "18f the routing-advertised-scores stub is gone from features.json and from the resolver"
mk rk7 rk1; H0=$(cd "$T/rk7" && find .supervisor -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum); rs rk7 rk7 --role "$NR" --project qa-proj
ok '[ "$H0" = "$(cd "$T/rk7" && find .supervisor -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)" ] && J rk7 "$(first qa-local)"' "18g the resolver writes nothing under the root's state folder (read-only)"
mk rk8 rk; ed rk8 connections --arg g "$(uuid)" '.entries += [(.entries[] | select(.id == "qa-local") | .id = "qa-fake" | .global_id = $g | .models = [(.models[0] | .id = "qa-fake-m1" | del(.score))])]'
bench rk8 qa-fake qa-fake-m1 "$MINT" 0.99; rs rk8 rk8 --role "$NR" --project qa-proj
ok 'passes rk8 && J rk8 "[.chain[] | select(.status == \"usable\")][0] | .connection == \"qa-fake\" and .model == \"qa-fake-m1\"" && J rk8 ".decision.reason | test(\"qa-fake/qa-fake-m1\")"' "18h fake entry: a provider and model added to the catalog and the benchmark file only are ranked first, with no code change"

[ $fails -eq 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
