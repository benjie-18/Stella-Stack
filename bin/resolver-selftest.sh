#!/usr/bin/env bash
# Hermetic self-test for the resolver (F2 W3; bin/resolve.py). In scratch roots (STELLA_ROOT = a temp folder with a copy of
# .stella/, the role table and its hooks) a fake catalog is made from the shipped entries with jq: a local link, a link of each
# hosted class, an aggregator, two CLI logins (terms recorded, terms not), and a preset of every class. Each rule of the
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
mk() {  # <name> [<from name>]: a scratch root with a copy of the data, the role table and its hooks (or of another scratch root)
  rm -rf "${T:?}/$1"
  if [ -n "${2:-}" ]; then cp -r "$T/$2" "$T/$1"; return; fi
  mkdir -p "$T/$1/$(dirname "$RJREL")"; cp -r "$ROOT/.stella" "$T/$1/.stella"; cp "$RJ" "$T/$1/$RJREL"; cp -r "$(dirname "$RJ")/hooks" "$T/$1/$(dirname "$RJREL")/hooks"
}
ed() { local f; f="$T/$1/$(p "$2")"; jq "${@:3}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <root> <schema> <jq args and filter>
edt() { local f="$T/$1/$RJREL"; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }        # <root> <jq args and filter>: the role table
passes() {  # <root>: the fixture is valid data (else the first problems are shown)
  STELLA_ROOT=$T/$1 python3 -I -B "$SD" check >"$T/o/check" 2>&1 || { head -n 3 "$T/o/check" | cut -c1-300 >&2; return 1; }
}
rs() {  # <root> <name> <args>...: resolve; stdout o/<name>.json, stderr .err, exit code .rc (RSX: another copy of the resolver)
  STELLA_ROOT=$T/$1 python3 -I -B "${RSX:-$RS}" resolve "${@:3}" --json >"$T/o/$2.json" 2>"$T/o/$2.err"; echo $? >"$T/o/$2.rc"
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
read -r C_NOLINK C_UNKNOWN C_TERMS C_AGG C_HARD C_UNMET C_POLICY C_PRIV C_CROSS C_COOL SCORESTUB < <(python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import resolve as r
print(r.NO_LINK, r.UNKNOWN, r.TERMS, r.AGGREGATOR, r.HARD, r.UNMET, r.POLICY, r.PRIVACY, r.CROSSING, r.COOLDOWN, r.STUB_SCORES)' "$BIN")
ok '[ -n "$LOCAL" ] && [ -n "$FREE" ] && [ -n "$FRONT" ] && [ -n "$NR" ] && [ -n "$NR2" ] && [ -n "$CR" ] && [ -n "$ER" ] && [ -n "$ENGINE" ] && [ -n "$WORKER" ] && [ -n "$FACT" ] && [ -n "$GCLASS" ] && [ -n "$NCLASS" ]' \
  "0a the shipped data gives the ids this test needs (three link classes, roles of each kind, both kinds of driver, a card fact, a grant class, a never class)"
ok 'for c in "$C_NOLINK" "$C_UNKNOWN" "$C_TERMS" "$C_AGG" "$C_HARD" "$C_UNMET" "$C_POLICY" "$C_PRIV" "$C_CROSS" "$C_COOL"; do jq -e --arg c "$c" ".alerts[] | select(.code == \$c and (.message | contains(\"{problem}\")))" "$ROOT/docs/hermes-local/alert-catalog.json" >/dev/null || exit 1; done' \
  "0b every code of the resolver is a row of the alert catalog"

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
ok 'J b --slurpfile f "$ROOT/$(p features)" ".stubs | length > 0 and (index(\"$SCORESTUB\") == null) and all(. as \$s | \$f[0].entries | any(.id == \$s and .due_phase != null))"' \
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
ok 'J b "$(ent qa-cli-no) | length == 2 and all(.status == \"excluded\" and .code == \"$C_TERMS\")" && J b "$(ent qa-cli) | length == 2 and all(.status == \"usable\")"' \
  "4 a CLI login whose terms are not recorded is excluded with $C_TERMS; the one with terms_ok true is usable"
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
facts h qa-other "$(jq -c '.project = "qa-other"' <<<"$CLEAN")"
ed h data-policy --arg g "$(uuid)" --arg i "$IID" '.projects["qa-private"] = {mode: "open", allowed_providers: [], private: true, global_id: $g, install_id: $i}'
for c in qa-card qa-held qa-nofield qa-norecord qa-other; do rs h "h-$c" --role "$CR" --project qa-proj --card "$c"; done
rs h h-private --role "$NR" --project qa-private
HARD="$AWAY | length > 0 and all(.status == \"excluded\" and .code == \"$C_HARD\" and .grant == null)"
ok 'passes h && [ "$(rc h-qa-card)" = 0 ] && J h-qa-card "$AWAY | any(.status == \"usable\")" && J h-qa-card ".card == \"qa-card\""' "5 control: a card whose facts are all recorded as not holding reaches a hosted link"
for c in "qa-held:whose fact $FACT holds" "qa-nofield:whose record lacks the fact $FACT" "qa-norecord:with no facts record"; do
  ok "[ \"\$(rc h-${c%%:*})\" = 0 ] && J h-${c%%:*} \"\$HARD\" && J h-${c%%:*} \"\$(ent qa-local) | any(.status == \\\"usable\\\")\"" \
    "5-${c%%:*} a card ${c#*:}: every link that leaves the machine is excluded with $C_HARD, no grant offered, the local link usable"
done
ok 'closed h-qa-other "$C_NOLINK"' "5a a card whose facts record names another project fails closed with $C_NOLINK and no chain"
ok '[ "$(rc h-private)" = 0 ] && J h-private "$HARD" && J h-private "$(ent qa-local) | any(.status == \"usable\")" && J h-private ".policy == \"project\""' \
  "5b a project marked private: every link that leaves the machine is excluded with $C_HARD"
cgrant() {  # <root> <id> <preset> <to class> <scope JSON>: a crossing grant
  ed "$1" grants --arg id "$2" --arg p "$3" --arg k "$4" --arg g "$(uuid)" --arg i "$IID" --arg a "$PAST" --argjson s "$5" \
    '.crossing_grants = ((.crossing_grants // []) + [{id: $id, global_id: $g, install_id: $i, preset: $p, to_class: $k, scope: $s, granted_at: $a}])'
}
mk lo base; ed lo data-policy --arg g "$(uuid)" --arg i "$IID" '.default.mode = "local_only" | .projects["qa-proj"] = {mode: "open", allowed_providers: [], global_id: $g, install_id: $i}'
cgrant lo qa-cg qa-all "$FRONT" '{"level":"global"}'; rs lo lo --role "$NR" --project qa-proj
ok 'passes lo && [ "$(rc lo)" = 0 ] && J lo ".local_only == true" && J lo "$AWAY | length > 0 and all(.status == \"excluded\" and .code == \"$C_POLICY\" and .grant == null)" && J lo "$(ent qa-local) | any(.status == \"usable\")"' \
  "5c Local only as the default beats a project row that says open (DC-04): local links only, no grant offered, a Stella-wide grant present"

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
ok 'passes bs1 && J bs1 "$(first qa-free)" && J bs1 ".decision.rule == \"best_suited\" and (.decision.reason | test(\"qa-free/qa-free-m1\")) and (.stubs | index(\"$SCORESTUB\") != null)" && J bs1 "all(.chain[]; .link_class != \"$FRONT\")"' \
  "9 a best-of group: the higher advertised score ranks first, with the reason and the scores stub; the needs class is not used for an unlisted tier"
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
ok '[ "$(rc ap-a2)" = 1 ] && J ap-a2 "[.apps[] | [.app, .code]] == [[\"qa-app-ok\", null], [\"qa-app-no\", \"$C_TERMS\"]] and .code == \"$C_TERMS\" and any(.chain[]; .status == \"usable\")" && grep -q "^$C_TERMS " "$T/o/ap-a2.err"' \
  "11a a CLI login app without terms_ok is refused with $C_TERMS: exit 1 though a link is usable"
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

[ $fails -eq 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
