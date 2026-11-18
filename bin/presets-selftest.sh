#!/usr/bin/env bash
# Hermetic self-test for the routing presets as data (F2 W1; bin/stella_data.py rule_presets, rule_routing, rule_link_classes,
# rule_grants, grant_in_force, route_problems, link_class, unmet, frozen; bin/stella-apply.py kept). The fake-entry test of
# this core: in scratch roots (STELLA_ROOT = a temp folder with a copy of .stella/ and the role table) a fifth preset, a fake
# link class and a fake task tier added as data only are valid and usable; each refusal fires with its code; the apply tool
# refuses a change to a built-in preset. No class, tier, role, preset or trigger is named here: every id is read from the
# shipped data, and the codes from the data tool. The alert log goes to a temp folder (ESCALATE_SUP_DIR).
set -u
BIN=$(dirname "$(readlink -f "$0")"); ROOT=$(dirname "$BIN"); SD="$BIN/stella_data.py"; AP="$BIN/stella-apply.py"
T=$(mktemp -d -t presets-selftest.XXXXXX); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/tmp" "$T/c" "$T/pb"; export TMPDIR=$T/tmp ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env; unset STELLA_ROOT
printf "OWNER_TIMEZONE='UTC'\n" >"$OWNER_CONFIG"
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
mk() {  # <name> [<from name>]: a scratch root with a copy of the data and the role table (or of another scratch root)
  rm -rf "$T/$1"
  if [ -n "${2:-}" ]; then cp -r "$T/$2" "$T/$1"; return; fi
  mkdir -p "$T/$1/docs/hermes-local"; cp -r "$ROOT/.stella" "$T/$1/.stella"; cp "$ROOT/docs/hermes-local/roles.json" "$T/$1/docs/hermes-local/"
  cp -r "$ROOT/docs/hermes-local/hooks" "$T/$1/docs/hermes-local/hooks"
}
ed() { local f="$T/$1/.stella/$2"; jq "${@:3}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <root> <file> <jq args and filter>
sd() { STELLA_ROOT=$T/$1 python3 -I "$SD" "${@:2}"; }
passes() { sd "$1" check >"$T/o" 2>&1; }      # <root>: check exits 0; the output is kept in $T/o
refuses() { ! sd "$1" check >"$T/o" 2>&1; }   # <root>: check exits non-zero
coded() { grep -q "^$1 " "$T/o"; }            # <code>: a line of the kept output starts with it
unseen() { ! grep -q qa-zz-unknown "$T/o"; }  # the rejected value is never printed

# ---- ids and codes, read from the data and the data tool ----
RA=$ROOT/.stella/role-assignments.json; RT=$ROOT/.stella/routing.json; RJ=$ROOT/docs/hermes-local/roles.json
j() { jq -r "$1" "$2"; }
LOCAL=$(j '.class_defaults.local' "$RT"); HOSTED=$(j '[.link_classes[] | select(.hosted) | .id][0]' "$RT")
FB=$(j .fallback_role "$RJ"); REQS=$(jq -c '[.workflow.required_roles[].role]' "$RT"); EXEMPT=$(jq -c '[.exempt_roles[].role]' "$RT")
ALWAYS=$(j '[.workflow.required_roles[] | select(.when == "always") | .role][0]' "$RT")
TRIGQ='.workflow as $w | [$w.required_roles[] | select(.when != "always" and ($w.triggers[.when].can_fire == true))][0]'
TRIGROLE=$(j "$TRIGQ | .role" "$RT"); TRIGID=$(j "$TRIGQ | .when" "$RT")
# OPT: a role the workflow does not require; PINROLE: another one, which needs tool calling and a context window
OPT=$(jq -r --arg fb "$FB" --argjson r "$REQS" --argjson e "$EXEMPT" '[.roles | keys[] | select(. as $k | $k != $fb and ($r | index($k)) == null and ($e | index($k)) == null)][0]' "$RJ")
PINROLE=$(jq -r --arg fb "$FB" --arg o "$OPT" --argjson e "$EXEMPT" '[.roles | to_entries[] | select(.key as $k | $k != $fb and $k != $o and ($e | index($k)) == null)
  | select(.value.requirements.tool_calling == true and .value.requirements.min_context_tokens >= 2) | .key][0]' "$RJ")
MINCTX=$(jq -r --arg p "$PINROLE" '.roles[$p].requirements.min_context_tokens' "$RJ")
AR=$(jq -c '.fallback_role as $fb | [.roles | keys[] | select(. != $fb)]' "$RJ")
INS=$(j '.files[] | select(.schema == "install") | .path' "$ROOT/.stella/data-files.json"); IID=$(j .install_id "$ROOT/$INS")
GCLASS=$(j '[.class_rules | to_entries[] | select(.value.hosted == "grant") | .key][0]' "$ROOT/.stella/data-policy.json")
NCLASS=$(j '[.class_rules | to_entries[] | select(.value.hosted != "grant") | .key][0]' "$ROOT/.stella/data-policy.json")
CLOUD=$(j '[.entries[] | select(.kind == "provider" and .locality == "cloud")][0].id' "$ROOT/.stella/connections.json")
STATEDIR=$(j .card_facts "$ROOT/.stella/data-files.json")
read -r C_OFF C_CHAIN C_BUILTIN < <(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import stella_data as s; print(s.OFF_REQUIRED, s.CHAIN_FAILS, s.BUILTIN_EDIT)' "$BIN")
uuid() { cat /proc/sys/kernel/random/uuid; }
link() { echo "{\"connection\":\"qa-pin\",\"model\":\"$1\",\"parameters\":{}}"; }
model() { echo "{\"id\":\"$1\",\"capabilities\":{\"tool_calling\":$2,\"json_mode\":null,\"context_tokens\":$3,\"vision\":$4,\"streaming\":null},\"probed_at\":null,\"probe_source\":\"advertised\"}"; }
MODELS="[$(model qa-good true 1048576 true),$(model qa-good2 true 1048576 true),$(model qa-notools false 1048576 true),$(model qa-smallctx true $((MINCTX - 1)) true),$(model qa-null null null null)]"
F='.effort_modes["qa-fifth"]'

ok '[ -n "$LOCAL" ] && [ -n "$HOSTED" ] && [ -n "$ALWAYS" ] && [ -n "$TRIGROLE" ] && [ -n "$OPT" ] && [ -n "$PINROLE" ] && [ -n "$GCLASS" ] && [ -n "$NCLASS" ] && [ -n "$CLOUD" ]' "0a the shipped data gives the ids this test needs (classes, required roles, an optional role, a role with requirements)"
ok 'for c in "$C_OFF" "$C_CHAIN" "$C_BUILTIN"; do jq -e --arg c "$c" ".alerts[] | select(.code == \$c and (.message | contains(\"{problem}\")))" "$ROOT/docs/hermes-local/alert-catalog.json" >/dev/null || exit 1; done' "0b the three codes of the preset rule are rows of the alert catalog"

# ---- a fifth preset as data only ----
mk base
ok 'passes base' "1 the shipped data passes check in a scratch root"
ok 'jq -e "[.effort_modes[] | select(.builtin == true)] | length == 4" "$RA" >/dev/null && jq -e ".selection.global as \$g | .effort_modes[\$g].builtin == true" "$RA" >/dev/null' "1a four built-in presets ship, and the selected one is one of them"
mk five
TEMPLATE='[.entries[] | select(.kind == "provider" and .locality == "local" and (.aggregator | not) and (.data_policy.hosted | not))][0]'
ed five connections.json --argjson m "$MODELS" --argjson ar "$AR" --arg g "$(uuid)" \
  ".entries += [$TEMPLATE + {id: \"qa-pin\", label: \"QA pinned models\", enabled: true, models: \$m, allowed_roles: \$ar, global_id: \$g} | del(.link_class)]"
ed five role-assignments.json --arg l "$LOCAL" --arg h "$HOSTED" --arg o "$OPT" --arg p "$PINROLE" --argjson pin "$(link qa-good)" --argjson fb "$(link qa-good2)" \
  "$F = {allowed_localities: [\"local\", \"cloud\"], no_silent_fallback: false, label: \"QA fifth\", builtin: false, based_on: null, class_order: [\$l, \$h], verification_depth: 2,
     roles: {(\$o): {active: false}, (\$p): {active: true, class_order: [\$l], pins: [\$pin], fallbacks: [\$fb], escalation_chain: [\$fb]}}}"
ok 'passes five' "2 a fifth preset as data only is valid: started blank, one optional role off, its own class order, a pin, a fallback and a stored escalation chain"
mk sel five; ed sel role-assignments.json '.selection.global = "qa-fifth" | .selection.projects["qa-proj"] = "qa-fifth" | .selection.cards["qa-card"] = "qa-fifth"'
ok 'passes sel' "2a it is selectable globally, per project and per card"
mk ovr five; ed ovr role-assignments.json --arg l "$LOCAL" '.assignments[0].class_order = [[$l]]'
ok 'passes ovr' "2b an assignment may carry the owner's class order for its role"

# ---- the refusals of the preset rule, each with its code ----
mk off1 five; ed off1 role-assignments.json --arg r "$ALWAYS" "$F.roles[\$r] = {active: false}"
ok 'refuses off1 && coded "$C_OFF"' "3 a preset that turns off a role the workflow always requires is refused with $C_OFF"
mk off2 five; ed off2 role-assignments.json --arg r "$TRIGROLE" "$F.roles[\$r] = {active: false}"
ok 'refuses off2 && coded "$C_OFF"' "3a a preset that turns off a role whose trigger can fire is refused with $C_OFF"
mk off3 off2; ed off3 routing.json --arg t "$TRIGID" '.workflow.triggers[$t].can_fire = false'
ok 'passes off3' "3b control: the same preset is valid when that trigger cannot fire"
for m in notools smallctx null missing; do
  mk "pin-$m" five; ed "pin-$m" role-assignments.json --arg p "$PINROLE" --argjson l "$(link "qa-$m")" "$F.roles[\$p].pins = [\$l]"
  ok "refuses pin-$m && coded \"\$C_CHAIN\"" "4-$m an active role pinned to a model that fails its requirements ($m) is refused with $C_CHAIN"
done
mk fb-bad five; ed fb-bad role-assignments.json --arg p "$PINROLE" --argjson l "$(link qa-notools)" "$F.roles[\$p].fallbacks = [\$l]"
ok 'refuses fb-bad && coded "$C_CHAIN"' "4a a fallback that fails the role's requirements is refused with $C_CHAIN"
mk off-pin five; ed off-pin role-assignments.json --arg o "$OPT" --argjson l "$(link qa-notools)" "$F.roles[\$o] = {active: false, pins: [\$l]}"
ok 'passes off-pin' "4b control: the links of an inactive role are not judged"

# ---- W1-RT-01: one judge for every listed link (a preset's pins and fallbacks, an assignment's chain) ----
PINDC=$(jq -r --arg p "$PINROLE" '.roles[$p].requirements.allowed_data_classes // [] | length' "$RJ")
for c in "off|.enabled = false|is switched off" "nodc|.data_policy.data_classes_allowed = []|does not allow every data class" "norole|.allowed_roles = []|in its allowed_roles"; do
  IFS='|' read -r n f w <<<"$c"
  mk "lk-$n" five; ed "lk-$n" connections.json "(.entries[] | select(.id == \"qa-pin\")) |= ($f)"
  ok "[ \"\$PINDC\" -gt 0 ] && refuses lk-$n && grep -q \"^\$C_CHAIN .*pins\\[0\\].*$w\" \"\$T/o\" && grep -q \"^\$C_CHAIN .*fallbacks\\[0\\].*$w\" \"\$T/o\"" \
    "4c-$n a pin and a fallback of an active role whose connection $w are each refused with $C_CHAIN"
done
CTPL='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "cloud" and (.aggregator | not))][0]'
mk lk-cloud five
ed lk-cloud connections.json --argjson m "$MODELS" --argjson ar "$AR" --argjson dc "$(jq -c .data_classes "$ROOT/.stella/data-policy.json")" --arg g "$(uuid)" --arg h "$HOSTED" \
  ".entries += [$CTPL + {id: \"qa-cloud\", label: \"QA cloud\", enabled: true, models: \$m, allowed_roles: \$ar, global_id: \$g, link_class: \$h} | .data_policy.data_classes_allowed = \$dc]"
ed lk-cloud role-assignments.json --arg p "$PINROLE" "$F.roles[\$p].fallbacks += [{connection: \"qa-cloud\", model: \"qa-good\", parameters: {}}]"
ok 'passes lk-cloud' "4d control: a cloud fallback is valid under a preset that allows cloud links"
ed lk-cloud role-assignments.json "$F.allowed_localities = [\"local\"]"
ok 'refuses lk-cloud && grep -q "^$C_CHAIN .*fallbacks\[1\].*is cloud for routing" "$T/o"' "4e the same link under a preset whose allowed_localities is local only is refused with $C_CHAIN"
ed lk-cloud role-assignments.json --arg p "$PINROLE" --arg h "$HOSTED" "$F.roles[\$p].last_resort = \$h"
ok 'passes lk-cloud' "4f control: a link of the role's last-resort class is not bound by the preset's localities (the resolver asks a crossing grant for it)"
ASG='.assignments += [{id: "qa-asg", scope: {level: "global"}, role: $p, effort_mode: "qa-fifth", chain: [$l], global_id: $g, install_id: $i}]'
mk as-ok five; ed as-ok role-assignments.json --arg p "$PINROLE" --arg g "$(uuid)" --arg i "$IID" --argjson l "$(link qa-good)" "$ASG"
ok 'passes as-ok' "4g control: an owner's chain to a model that meets the role's requirements is valid"
mk as-bad five; ed as-bad role-assignments.json --arg p "$PINROLE" --arg g "$(uuid)" --arg i "$IID" --argjson l "$(link qa-notools)" "$ASG"
ok 'refuses as-bad && grep -q "qa-asg: chain\[0\]: .*tool_calling" "$T/o"' "4h an owner's chain to a model that fails the role's requirements is refused (the judge of the preset links)"

# ---- W1-RT-02: an active role never ends with an empty chain ----
mk e1 five; ed e1 role-assignments.json --arg p "$PINROLE" "$F.roles[\$p].class_order = []"
ok 'refuses e1' "4i an empty class order of a role in a preset is refused"
mk e2 five; ed e2 role-assignments.json '.assignments[0].class_order = []'
ok 'refuses e2' "4j an empty class order in an assignment is refused"
mk e3 five; ed e3 routing.json '.exempt_roles[0].class_order = []'
ok 'refuses e3' "4k an empty class order of an exempt role is refused"
mk e4 five; ed e4 role-assignments.json '.effort_modes["qa-bare"] = {allowed_localities: ["local"], no_silent_fallback: false}'
ok 'refuses e4 && grep -q "^$C_OFF .*qa-bare.*no link" "$T/o" && grep -q "^$C_CHAIN .*qa-bare.*no link" "$T/o"' \
  "4l a preset that gives its active roles no pin, class order, needs class, fallback or last resort is refused: $C_OFF for the required roles, $C_CHAIN for the others"
ed e4 role-assignments.json --arg l "$LOCAL" '.effort_modes["qa-bare"].last_resort = $l'
ok 'passes e4' "4m control: the same preset with a last-resort class gives every role a chain"

# ---- W1-RT-03 / W3-CVER-01: a missing card fact never counts as false ----
mk wm1 five; ed wm1 routing.json '.card_facts.when_missing = {}'
ok 'refuses wm1' "4n card_facts.when_missing with no fact key is refused"
mk wm2 five; ed wm2 routing.json '.card_facts.when_missing |= del(.[keys[0]])'
ok 'refuses wm2' "4o card_facts.when_missing without one of its fact keys is refused"
mk wm3 five; ed wm3 routing.json '.card_facts.when_missing |= (to_entries | .[0].value = false | from_entries)'
ok 'refuses wm3' "4p a card fact that counts as false when missing is refused"
mk wm4 five; ed wm4 routing.json '.card_facts.when_missing["qa_fact"] = true'
ok 'passes wm4' "4q control: a new card fact added as data, counting as true when missing, is valid"
ed wm4 routing.json '.card_facts.when_missing["qa_fact"] = false'
ok 'refuses wm4' "4r and refused when it counts as false"

# ---- the lows of Gate B: W1-RT-05 to W1-RT-08 ----
mk x5 five; ed x5 role-assignments.json --argjson e "$EXEMPT" "$F.roles[\$e[0]] = {active: false}"
ok 'refuses x5 && grep -q "exempt" "$T/o"' "4s a preset that turns off an exempt role is refused"
mk x6 five; ed x6 routing.json '.exempt_roles += [.exempt_roles[0]]'
ok 'refuses x6 && grep -q "exempt_roles: a role is listed twice" "$T/o"' "4t an exempt role listed twice is refused"
mk x6b five; ed x6b routing.json '.link_classes |= map(if .hosted then .privacy_rank = 0 else . end)'
ok 'refuses x6b && grep -q "link_classes: a hosted class" "$T/o"' "4u a hosted class that is not less private than every class that is not hosted is refused"
mk x7 five; ed x7 routing.json 'del(.failover.triggers[.failover.triggers | keys[0]])'
ok 'refuses x7' "4v a failover trigger set that lacks one of its triggers is refused"
mk x7b five; ed x7b routing.json '.failover.triggers["qa-zz-unknown"] = .failover.triggers[.failover.triggers | keys[0]]'
ok 'refuses x7b && unseen' "4w an unknown failover trigger is refused"

# ---- Gate B wave 3: W1-RT-09 (an exempt role stays off hosted classes) ----
mk x9 five; ed x9 routing.json --arg l "$LOCAL" --arg h "$HOSTED" '.exempt_roles[0].class_order = [$l, $h]'
ok 'refuses x9 && grep -q "exempt_roles\[0\].class_order names a hosted link class" "$T/o"' "4x an exempt role whose class order names a hosted class is refused"
mk x9b five; ed x9b routing.json --arg l "$LOCAL" --arg h "$HOSTED" '.exempt_roles[0].class_order = [[$h, $l]]'
ok 'refuses x9b && grep -q "names a hosted link class" "$T/o"' "4y the same inside a best-of group"
# W1-RT-10 (a class order no link can serve is no chain). qa-void: a class that is not hosted; qa-bare: a preset whose only class it is. The fake connection's models take the class one by one.
BARE='.effort_modes["qa-bare"] = {allowed_localities: ["local"], no_silent_fallback: false, class_order: ["qa-void"]}'
VOID() { echo "(.entries[] | select(.id == \"qa-pin\")).models[$1].link_class = \"qa-void\""; }   # <index in MODELS>
mk v1 five; ed v1 routing.json --arg l "$LOCAL" '.link_classes += [(.link_classes[] | select(.id == $l)) + {id: "qa-void"}]'
ed v1 connections.json --argjson dc "$(jq -c .data_classes "$ROOT/.stella/data-policy.json")" '(.entries[] | select(.id == "qa-pin")).data_policy.data_classes_allowed = $dc'
ed v1 role-assignments.json "$BARE"
ok 'refuses v1 && grep -q "^$C_OFF .*qa-bare.*gives no link" "$T/o" && grep -q "^$C_CHAIN .*qa-bare.*gives no link" "$T/o"' \
  "4z a preset whose only class no link of the catalog has is refused: $C_OFF for the required roles, $C_CHAIN for the others"
mk v2 v1; ed v2 connections.json "$(VOID 2)"
ok 'refuses v2 && grep -q "qa-bare.*gives no link to .*$PINROLE" "$T/o"' "4z-a the class holding only a model that fails a role's requirements gives that role no link"
mk v3 v2; ed v3 connections.json "$(VOID 1)"
ok 'passes v3' "4z-b control: one model of the class that meets every role's requirements, and the preset is valid"
ed v3 connections.json '(.entries[] | select(.id == "qa-pin")).enabled = false'
ok 'refuses v3 && grep -q "qa-bare.*gives no link" "$T/o"' "4z-c a link of the class is judged as a pin is: its connection switched off, and the roles have no link again"
# v3 serves every role but look (vision; no model of the fixture has it), which the shipped table marks optional
f="$T/v3/docs/hermes-local/roles.json"; ok '[ "$(jq -r .roles.look.optional "$f")" = true ]' "4z-d W1-RT-10 setup: look is optional in the shipped table"
mk v4 v3; f="$T/v4/docs/hermes-local/roles.json"; jq 'del(.roles.look.optional)' "$f" >"$f.n" && mv "$f.n" "$f"
ok 'refuses v4 && grep -q "^$C_CHAIN .*qa-bare.*gives no link to .*look" "$T/o"' "4z-d the same data with look required is refused: the optional flag alone lets the preset pass (and it fails when look is asked for)"
mk v5 v3; ed v5 routing.json '.workflow.required_roles += [{role: "look", when: "always"}]'
ok 'refuses v5 && grep -q "^$C_OFF .*qa-bare.*gives no link to .*look" "$T/o"' "4z-e a role the workflow requires keeps its $C_OFF refusal although look is marked optional (optional never overrides workflow.required_roles)"

# ---- unknown ids fail closed, the value never printed ----
u() {  # <root> <file> <jq filter> <text>
  mk "$1" five; ed "$1" "$2" --arg x qa-zz-unknown --arg l "$LOCAL" --arg p "$PINROLE" "$3"
  ok "refuses $1 && coded STL-CFG-310 && unseen" "$4"
}
u u1 role-assignments.json "$F.class_order = [\$l, \$x]" "5a an unknown class in a preset's class order is refused"
u u2 role-assignments.json "$F.class_order = [[\$l, \$x]]" "5b an unknown class in a best-of group is refused"
u u3 role-assignments.json "$F.last_resort = \$x" "5c an unknown last-resort class is refused"
u u4 role-assignments.json "$F.needs_class = \$x" "5d an unknown needs_class is refused"
u u5 role-assignments.json "$F.roles[\$p].class_order = [\$x]" "5e an unknown class in a role's own class order is refused"
u u6 role-assignments.json "$F.roles[\$p].last_resort = \$x" "5f an unknown last-resort class of a role is refused"
u u7 role-assignments.json "$F.based_on = \$x" "5g an unknown preset in based_on is refused"
u u8 role-assignments.json "$F.roles[\$x] = {active: true}" "5h an unknown role in a preset is refused"
u u9 role-assignments.json "$F.frontier_when = {tiers: [\$x]}" "5i an unknown task tier is refused"
u u10 role-assignments.json '.selection.cards["qa-card"] = $x' "5j an unknown preset selected for a card is refused"
u u11 role-assignments.json '.assignments[0].class_order = [$x]' "5k an unknown class in an assignment's class order is refused"
u u12 routing.json '.workflow.required_roles += [{role: $x, when: "always"}]' "5l an unknown required role is refused"
u u13 routing.json '.workflow.required_roles += [{role: $p, when: $x}]' "5m an unknown trigger of a required role is refused"
u u14 routing.json '.exempt_roles += [{role: $x, class_order: [$l], in_fallback_chain: false}]' "5n an unknown exempt role is refused"
u u15 routing.json '.exempt_roles[0].class_order = [$x]' "5o an unknown class in an exempt role's class order is refused"
u u16 routing.json '.card_roles += [$x]' "5p an unknown card role is refused"
u u17 routing.json '.class_defaults.aggregator = $x' "5q an unknown default class is refused"
u u18 routing.json '.consent.approval_class = $x' "5r an unknown approval class for consent is refused"
u u19 routing.json '.credentials.backend = $x' "5s a credentials backend that is not defined is refused"
u u20 connections.json '(.entries[] | select(.id == "qa-pin")).protocol = $x' "5t an unknown protocol on a connection is refused"
mk code five; ed code routing.json --arg c "STL-ZZZ-$((999))" '.consent.alert_code_notice = $c'   # built at run time: the alert selftest greps every STL code written in bin/
ok 'refuses code && grep -q "consent.alert_code_notice" "$T/o"' "5u a consent alert code that is not in the alert catalog is refused"
mk dup five; ed dup routing.json '.link_classes += [.link_classes[0]]'
ok 'refuses dup && grep -q "link_classes: an id is listed twice" "$T/o"' "5v a link class listed twice is refused"
mk cool five; ed cool routing.json '.failover.triggers |= with_entries(.value.cooldown_s = .value.max_cooldown_s + 1)'
ok 'refuses cool && grep -q "cooldown_s is above max_cooldown_s" "$T/o"' "5w a cooldown above its cap is refused"
u u21 routing.json '.effort.by_role[$p] = $x' "5x an unknown effort id in the routing data's effort table is refused (a role's id alone)"
u u21b routing.json '.effort.by_role[$p] = {default: $x}' "5x2 and as a role's default"
u u22 routing.json '.effort.by_role[$x] = {default: .effort.levels[0]}' "5y an unknown role in the effort table is refused"
u u23 routing.json '.effort.by_role[$p] = {tiers: {($x): .effort.levels[0]}}' "5z an unknown task tier in the effort table is refused"
u u24 role-assignments.json "$F.roles[\$p].escalation_chain[0].parameters.effort = \$x" "5za an unknown effort id in a rung's parameters is refused"
u u25 role-assignments.json "$F.roles[\$p].pins[0].parameters.effort = \$x" "5zb an unknown effort id in a pin's parameters is refused"
u u26 role-assignments.json '.assignments[0].chain[0].parameters.effort = $x' "5zc an unknown effort id in an assignment's chain is refused"
u u27 routing.json '.builder_roles += [$x]' "5ze a building role that is not an assignable role is refused"
mk bnc five; ed bnc routing.json '.card_roles -= [.builder_roles[0]]'
ok 'passes bnc' "5zf control: a building role need not be a card role (a role asked with no card)"
mk edup five; ed edup routing.json '.effort.levels += [.effort.levels[0]]'
ok 'refuses edup' "5zd an effort level listed twice is refused"

# ---- the escalation chain (F2b item D): judged like a pin; built-ins ship a chain for each building role; effort levels are data ----
mk ec five; ed ec role-assignments.json --arg p "$PINROLE" --argjson l "$(link qa-notools)" "$F.roles[\$p].escalation_chain = [\$l]"
ok 'refuses ec && grep -q "^$C_CHAIN .*escalation_chain\[0\]" "$T/o"' "6x a rung that fails the role's requirements is refused with $C_CHAIN, naming escalation_chain[0]"
BUILDERS=$(jq -c '.builder_roles // []' "$RT")   # the building roles: routing data, not named
ok '[ "$(jq length <<<"$BUILDERS")" -gt 0 ] && jq -e --argjson b "$BUILDERS" --slurpfile rt "$RT" "[.effort_modes[] | select(.builtin)] as \$m | (\$m | length) > 0 and all(\$m[]; . as \$p | all(\$b[];
  (\$p.roles[.].escalation_chain | length) > 0 and all(\$p.roles[.].escalation_chain[]; (.parameters.effort // null) as \$e | \$e == null or (\$rt[0].effort.levels | index(\$e)) != null)))" "$RA" >/dev/null' \
  "6y every built-in preset ships an escalation chain for each building role, with known effort ids (and check accepts it: case 1)"
mk enew five; ed enew routing.json '.effort.levels += ["qa-new-level"]'; ed enew role-assignments.json --arg p "$PINROLE" "$F.roles[\$p].escalation_chain[0].parameters.effort = \"qa-new-level\""
ok 'passes enew' "6z a new effort level added as data only is valid in a rung's parameters"

# ---- a fake link class and a fake tier, as data only ----
mk cls five
ed cls routing.json '.link_classes += [{id: "qa-class", privacy_rank: 0, hosted: false}] | .task_tiers += [{id: "qa-tier"}]'
ed cls connections.json '(.entries[] | select(.id == "qa-pin")).models[1].link_class = "qa-class"'
ed cls role-assignments.json --arg l "$LOCAL" "$F.class_order = [[\"qa-class\", \$l]] | $F.needs_class = \"qa-class\" | $F.frontier_when = {tiers: [\"qa-tier\"]}"
ok 'passes cls' "6 a fake link class and a fake task tier added as data are valid, and a preset uses both"
cat >"$T/unit.py" <<'PY'
import datetime, sys
sys.path.insert(0, sys.argv[1])
import stella_data as s
local, gclass = sys.argv[2:4]
n, bad = 0, 0
def eq(got, want, text):
    global n, bad
    n += 1
    bad += got != want
    print(("ok   " if got == want else "FAIL ") + f"7.{n} {text}" + ("" if got == want else f": got {got!r}"))
conn = s.served(["connections"])["connections"]
pin = conn["qa-pin"]
eq(s.link_class(pin, pin["models"][1]["id"]), "qa-class", "link_class: a model's own class wins (read through routing(), two arguments)")
eq(s.link_class(pin, pin["models"][0]["id"]), local, "link_class: a local link that names none gets the default local class")
cloud = {"id": "c", "type": "api", "locality": "cloud", "data_policy": {}, "models": [{"id": "m"}]}
eq(s.link_class(cloud, "m"), None, "link_class: a cloud link that names no class has none (not routable)")
eq(s.link_class(dict(cloud, aggregator=True), "m"), s.routing()["class_defaults"]["aggregator"], "link_class: an aggregator that names none gets the default aggregator class")
req = {"tool_calling": True, "vision": False, "min_context_tokens": 100}
eq(s.unmet(req, {"tool_calling": True, "vision": None, "context_tokens": 100}), [], "unmet: capabilities that meet every requirement")
eq(s.unmet(req, {"tool_calling": None, "vision": None, "context_tokens": None}), ["tool_calling", "min_context_tokens"], "unmet: a null capability meets no requirement")
eq(s.unmet(dict(req, vision=True), {"tool_calling": True, "vision": False, "context_tokens": 99}), ["vision", "min_context_tokens"], "unmet: vision false and a window one token short")
now = datetime.datetime(2026, 11, 14, 12, 0, 0)
g = {"data_class": gclass, "connection": "c", "granted_at": "2026-11-01T00:00:00Z", "scope": {"level": "project", "project": "p1"}}
pol = lambda *grants, rule="grant": [("x", {"class_rules": {gclass: {"hosted": rule}}, "privacy_grants": list(grants)})]
kinds = lambda *a, **k: [m["kind"] for m in s.route_problems(*a, **k)]
eq(kinds(pol(g), [gclass], cloud, now, "p1"), [], "route_problems: a project-scoped privacy grant lifts the grant rule in its project")
eq(kinds(pol(g), [gclass], cloud, now, "p2"), ["grant"], "route_problems: it does not in another project")
eq(kinds(pol(g), [gclass], cloud, now), ["grant"], "route_problems: nor for a task with no project")
eq(kinds(pol(dict(g, revoked_at="2026-11-10T00:00:00Z")), [gclass], cloud, now, "p1"), ["grant"], "route_problems: a revoked grant grants nothing")
eq(kinds(pol({k: v for k, v in g.items() if k != "scope"}), [gclass], cloud, now, "p2"), [], "route_problems: a grant with no scope is Stella-wide")
eq(kinds(pol(g, rule="never"), [gclass], cloud, now, "p1"), ["never"], "route_problems: a class whose rule is never is kind never, whatever the grant")
eq(kinds(pol(), [gclass], dict(cloud, type="cli-login", terms_ok=None, locality="local"), now), ["terms"], "route_problems: a cli-login link without terms_ok is kind terms")
eq(s.grant_in_force(dict(g, scope={"level": "global"}, expires_at="2026-11-02T00:00:00Z"), "p1", now), False, "grant_in_force: an expired grant is not in force")
sys.exit(1 if bad else 0)
PY
STELLA_ROOT=$T/cls python3 -I "$T/unit.py" "$BIN" "$LOCAL" "$GCLASS" >"$T/unit.out" 2>&1; urc=$?
cat "$T/unit.out"; fails=$((fails + $(grep -c '^FAIL' "$T/unit.out")))
ok '[ $urc = 0 ] && [ "$(grep -c "^ok" "$T/unit.out")" = 15 ]' "7 the link class, requirement and grant functions answer as the data says (15 cases ran, exit $urc)"

# ---- DC-03: a class that is not hosted never labels a link that leaves the machine ----
mk reach cls; ed reach connections.json --arg c "$CLOUD" '(.entries[] | select(.id == $c)).link_class = "qa-class"'
ok 'refuses reach && grep -q "which is not hosted, but the link leaves the machine" "$T/o"' "8 a class with hosted false on a cloud link is refused"
ed reach routing.json '(.link_classes[] | select(.id == "qa-class")) |= (.hosted = true | .privacy_rank = 9)'
ok 'passes reach' "8a control: the same class marked hosted is valid there"
mk nonprov five; ed nonprov connections.json --arg l "$LOCAL" '(.entries[] | select(.kind != "provider")).link_class = $l'
ok 'refuses nonprov && grep -q "link_class is for a provider" "$T/o"' "8b a link class on an entry that is no provider is refused"

# ---- DC-05: a dir credentials backend lies inside a protected state path ----
mk cred five; ed cred routing.json '.credentials = {backend: "qa-dir", backends: {"qa-dir": {kind: "dir", path: ".stella/qa-keys"}}}'
ok 'refuses cred && grep -q "a dir backend needs a path inside a protected state path" "$T/o"' "9 a dir backend outside every protected state path is refused"
ed cred routing.json '.credentials.backends["qa-dir"] = {kind: "dir"}'
ok 'refuses cred && grep -q "a dir backend needs a path" "$T/o"' "9a a dir backend with no path is refused"
ed cred routing.json --arg p "$STATEDIR/qa-keys" '.credentials.backends["qa-dir"] = {kind: "dir", path: $p}'
ok 'passes cred' "9b control: a dir backend inside a protected state path (the card facts folder) is valid"
ok 'python3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); import roles, stella_data as s; sys.exit(0 if {\"routing_state\", \"card_facts\"} <= set(roles.STATE_KEYS) and set(roles.STATE_KEYS) <= set(s.STATE[:-1]) else 1)" "$BIN"' "9c DC-06 the failover state and the card facts are protected state keys of the role tool, and every such key is a path the data tool confines"

# ---- grants: DC-08 and the scope shape ----
PG="{id: \"qa-pg\", global_id: \"$(uuid)\", install_id: \"$IID\", data_class: \$k, connection: \$c, granted_at: \"2026-11-01T00:00:00Z\", expires_at: null, revoked_at: null, request_id: null}"
mk pg five; ed pg data-policy.json --arg k "$GCLASS" --arg c "$CLOUD" ".privacy_grants = [$PG + {scope: {level: \"project\", project: \"qa-proj\"}}]"
ok 'passes pg' "10 a project-scoped privacy grant for a class whose rule is grant is valid"
ed pg data-policy.json '.privacy_grants[0].scope = {level: "project"}'
ok 'refuses pg && grep -q "privacy_grants\[0\]: scope.level project needs project" "$T/o"' "10a a privacy grant of level project with no project is refused"
ed pg data-policy.json '.privacy_grants[0].scope = {level: "global", project: "qa-proj"}'
ok 'refuses pg && grep -q "privacy_grants\[0\]: scope.level global has no project" "$T/o"' "10b a privacy grant of level global that names a project is refused"
mk pgn five; ed pgn data-policy.json --arg k "$NCLASS" --arg c "$CLOUD" ".privacy_grants = [$PG]"
ok 'refuses pgn && grep -q "privacy_grants\[0\]: the hosted rule of data class .* is not grant" "$T/o"' "10c DC-08 a privacy grant for a class whose hosted rule is not grant is refused"
LAST=$(j '[.effort_modes | to_entries[] | select(.value.last_resort != null)][0] | .key' "$RA"); LASTC=$(jq -r --arg p "$LAST" '.effort_modes[$p].last_resort' "$RA")
CG="{id: \"qa-cg\", global_id: \"$(uuid)\", install_id: \"$IID\", preset: \$p, to_class: \$c, scope: {level: \"global\"}, granted_at: \"2026-11-01T00:00:00Z\", expires_at: null, revoked_at: null, request_id: null}"
mk cg five; ed cg grants.json --arg p "$LAST" --arg c "$LASTC" ".crossing_grants = [$CG]"
ok 'passes cg' "11 a Stella-wide crossing grant (a preset to its last-resort class) is valid"
ed cg grants.json '.crossing_grants[0].scope = {level: "project"}'
ok 'refuses cg && grep -q "crossing_grants\[0\]: scope.level project needs project" "$T/o"' "11a a crossing grant of level project with no project is refused"
ed cg grants.json '.crossing_grants[0].scope = {level: "global"} | .crossing_grants[0].preset = "qa-zz-unknown"'
ok 'refuses cg && coded STL-CFG-310 && unseen' "11b a crossing grant for an unknown preset is refused"
ed cg grants.json --arg p "$LAST" --arg u "$(uuid)" '.crossing_grants[0].preset = $p | .crossing_grants[0].scope = {level: "project", project: $u}'
ok 'refuses cg && grep -q "crossing_grants\[0\]: scope.project is a global_id" "$T/o"' "11c W1-RT-08 a grant scoped to a project by a global_id (it would hold nowhere) is refused"

# ---- the apply tool and built-in presets (the owner in a scratch root: its own key, a stub board, no worker marker) ----
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"
ax() { (cd "$T" && STELLA_ROOT=$A PATH=$T/pb:$PATH timeout 120 python3 -I "$@"); }   # in the root $A
aproot() {  # <dir>: a scratch git root with the shipped data committed and its own owner key; $A from here on
  A=$1; mkdir -p "$A/docs/hermes-local" "$A/.supervisor/logs"
  cp -r "$ROOT/.stella" "$A/"; cp -r "$ROOT/docs/hermes-local/hooks" "$A/docs/hermes-local/hooks"
  jq '. + {worker_markers: ["QA_STUB_WORKER_MARK"]}' "$RJ" >"$A/docs/hermes-local/roles.json"
  printf '.supervisor/\n' >"$A/.gitignore"; git -C "$A" init -q 2>/dev/null; git -C "$A" add -A >/dev/null 2>&1
  git -C "$A" -c user.name=t -c user.email=t@example.invalid commit -qm base >/dev/null 2>&1
  ax "$BIN/owner_auth.py" init-key >/dev/null 2>&1
  RAF=$A/.stella/role-assignments.json
}
aproot "$T/ap"; sha() { sha256sum "$RAF" | cut -d' ' -f1; }
B1=$(j '[.effort_modes | to_entries[] | select(.value.builtin == true) | .key][0]' "$RAF")
jq --arg b "$B1" '.effort_modes["qa-custom"] = (.effort_modes[$b] + {label: "QA custom", builtin: false, based_on: $b} | del(.changelog))' "$RAF" >"$T/c/custom.json"
ax "$AP" apply role-assignments --from "$T/c/custom.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && jq -e --arg b "$B1" ".effort_modes[\"qa-custom\"].based_on == \$b" "$RAF" >/dev/null' "12 a custom preset, a copy of a built-in one under a new id, applies (exit $rc: $(head -c 160 "$T/o" | tr '\n' ' '))"
jq '.effort_modes["qa-custom"].verification_depth = 7' "$RAF" >"$T/c/custom2.json"
ax "$AP" apply role-assignments --from "$T/c/custom2.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && jq -e ".effort_modes[\"qa-custom\"].verification_depth == 7" "$RAF" >/dev/null' "12a the custom preset can be changed afterwards (exit $rc)"
jq --arg b "$B1" '.effort_modes[$b].verification_depth += 1' "$RAF" >"$T/c/b-edit.json"
# B2: a built-in preset nothing else names, so only the built-in rule can refuse its removal
B2=$(j '([.assignments[].effort_mode] + [.selection.global]) as $used | [.effort_modes | to_entries[] | select(.value.builtin == true and (.key as $k | $used | index($k)) == null) | .key][0]' "$RAF")
jq --arg b "$B2" 'del(.effort_modes[$b])' "$RAF" >"$T/c/b-drop.json"
jq --arg b "$B1" '.effort_modes[$b].builtin = false' "$RAF" >"$T/c/b-flag.json"
n=0
for b in edit drop flag; do
  for mode in --dry-run ""; do
    n=$((n+1)); s0=$(sha); ax "$AP" apply role-assignments --from "$T/c/b-$b.json" $mode >"$T/o" 2>&1; rc=$?
    ok '[ $rc = 1 ] && coded "$C_BUILTIN" && [ "$(sha)" = "$s0" ]' "13.$n a candidate that changes a built-in preset ($b${mode:+, dry run}) is refused with $C_BUILTIN and the file is unchanged (exit $rc)"
  done
done
# W1-F-1: an apply never makes a built-in preset either (a new id marked built in, or the custom one turned into one): the owner could not edit or remove it afterwards
jq --arg b "$B1" '.effort_modes["qa-made"] = (.effort_modes[$b] + {label: "QA made", based_on: $b} | del(.changelog))' "$RAF" >"$T/c/b-new.json"
jq '.effort_modes["qa-custom"].builtin = true' "$RAF" >"$T/c/b-turn.json"
n=0
for b in new turn; do
  for mode in --dry-run ""; do
    n=$((n+1)); s0=$(sha); ax "$AP" apply role-assignments --from "$T/c/b-$b.json" $mode >"$T/o" 2>&1; rc=$?
    ok '[ $rc = 1 ] && coded "$C_BUILTIN" && [ "$(sha)" = "$s0" ]' "14.$n a candidate that makes a built-in preset ($b${mode:+, dry run}) is refused with $C_BUILTIN and the file is unchanged (exit $rc)"
  done
done
ok '[ "$(python3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); import stella_data as s; f = lambda o, n: [c for c, _ in s.frozen(\"role-assignments\", {\"effort_modes\": o}, {\"effort_modes\": n})]; B, C = {\"builtin\": True}, {\"builtin\": False}; print(f({\"a\": B}, {\"a\": B, \"b\": B}) == [s.BUILTIN_EDIT], f({\"a\": B, \"c\": C}, {\"a\": B, \"c\": B}) == [s.BUILTIN_EDIT], f({\"a\": B, \"c\": C}, {\"a\": B, \"c\": {}, \"d\": C}), f({\"a\": B}, {\"a\": B, \"b\": 1}))" "$BIN")" = "True True [] []" ]' "14a frozen(): a new id marked built in and a custom preset turned into one are each one refusal; an unchanged built-in beside changed and new custom presets is none"
ok '[ "$(python3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); import stella_data as s; print(len(s.frozen(\"role-assignments\", None, {\"effort_modes\": {}})), len(s.frozen(\"routing\", {\"effort_modes\": {\"a\": {\"builtin\": True}}}, {\"effort_modes\": {}})))" "$BIN")" = "0 0" ]' "13a frozen() keeps nothing of a file that does not parse, and nothing of another schema"

# W1-CVER-01 / W1-RT-04: the built-in rule has a baseline the file cannot move. A file that is not its baseline (edited by
# hand, damaged, missing) is not what the candidate is compared with: the document last applied is, or the committed one.
cp "$RAF" "$T/c/applied.json"
jq --arg b "$B1" '.effort_modes[$b].changelog += [{at: "2026-11-14T12:00:00Z", by: "qa", what: "a hand edit"}]' "$T/c/applied.json" >"$RAF"; cp "$RAF" "$T/c/hand.json"
n=0
for mode in --dry-run ""; do
  n=$((n+1)); s0=$(sha); ax "$AP" apply role-assignments --from "$T/c/hand.json" $mode >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && coded "$C_BUILTIN" && [ "$(sha)" = "$s0" ]' "15.$n a built-in preset edited by hand in the file is not recorded by an apply of that file${mode:+ (dry run)}: refused with $C_BUILTIN (exit $rc)"
done
printf '{"schema_version": 2, "effort_modes": ' >"$RAF"   # the file cut short: it does not parse
for mode in --dry-run ""; do
  n=$((n+1)); s0=$(sha); ax "$AP" apply role-assignments --from "$T/c/b-edit.json" $mode >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && coded "$C_BUILTIN" && [ "$(sha)" = "$s0" ]' "15.$n over a file that does not parse, a candidate that changes a built-in preset${mode:+ (dry run)} is refused with $C_BUILTIN (exit $rc)"
done
ax "$AP" apply role-assignments --from "$T/c/applied.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && cmp -s "$RAF" "$T/c/applied.json"' "15a control: the document last applied goes back over the damaged file (exit $rc: $(head -c 160 "$T/o" | tr '\n' ' '))"
# W1-RT-11: a built-in update that arrives committed (a release merged outside the apply tool) is the baseline while the file
# holds the committed bytes, whatever was applied before: the owner's next apply goes through, and putting the older built-in back does not
jq --arg b "$B1" '.effort_modes[$b].changelog += [{at: "2026-11-16T00:00:00Z", by: "qa", what: "a release"}]' "$T/c/applied.json" >"$RAF"
git -C "$A" -c user.name=t -c user.email=t@example.invalid commit -qam release >/dev/null 2>&1
jq '.effort_modes["qa-after"] = (.effort_modes["qa-custom"] + {label: "QA after"})' "$RAF" >"$T/c/after.json"
jq --slurpfile a "$T/c/applied.json" --arg b "$B1" '.effort_modes[$b] = $a[0].effort_modes[$b]' "$RAF" >"$T/c/undo.json"
ax "$AP" apply role-assignments --from "$T/c/after.json" --dry-run >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ -z "$(git -C "$A" status --porcelain -- .stella/role-assignments.json)" ]' "16.1 after a committed update of a built-in preset, a candidate that adds a custom preset is accepted (dry run; exit $rc: $(head -c 160 "$T/o" | tr '\n' ' '))"
n=1
for mode in --dry-run ""; do
  n=$((n+1)); s0=$(sha); ax "$AP" apply role-assignments --from "$T/c/undo.json" $mode >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && coded "$C_BUILTIN" && [ "$(sha)" = "$s0" ]' "16.$n a candidate that puts the built-in preset of before the update back${mode:+ (dry run)} is refused with $C_BUILTIN (exit $rc)"
done
ax "$AP" apply role-assignments --from "$T/c/after.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && cmp -s "$RAF" "$T/c/after.json"' "16.4 and the custom preset applies (exit $rc: $(head -c 160 "$T/o" | tr '\n' ' '))"
aproot "$T/ap2"; rm -f "$RAF"   # never applied, the file gone: the committed document is the baseline
jq --arg b "$B1" '.effort_modes["qa-made"] = (.effort_modes[$b] + {label: "QA made", based_on: $b} | del(.changelog))' "$RA" >"$T/c/b-new2.json"
ax "$AP" apply role-assignments --from "$T/c/b-new2.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && coded "$C_BUILTIN" && [ ! -e "$RAF" ]' "15b never applied and the file missing: a candidate that makes a built-in preset is refused with $C_BUILTIN (exit $rc)"
ax "$AP" apply role-assignments --from "$RA" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && cmp -s "$RAF" "$RA"' "15c control: the committed document goes back in place of the missing file (exit $rc: $(head -c 160 "$T/o" | tr '\n' ' '))"

[ $fails -eq 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
