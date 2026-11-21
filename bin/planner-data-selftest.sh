#!/usr/bin/env bash
# Hermetic self-test for the planner data (phase P1, item W0: .stella/planner.json, .stella/planner-settings.json, their
# schemas, data-files rows, stella_data.py check rules, features.json entries), written tests-first by the tester.
# Check (P1 tests.json id): AC-DATA. In scratch roots (a copy of .stella/, the role table and its hooks) the data is edited
# with jq and judged by bin/stella_data.py check / get. Ids are read from the data (routing task_tiers, role table, presets);
# the seed values asserted are the ones design.md "Data (W0)" fixes from spec E2/E3/E8.
# ASSUMPTIONS (what design.md leaves open):
#  W1 the two files are found by the index rows whose schema is "planner" and "planner-settings" (format json).
#  W2 a fail-closed refusal is check exit 1 with a problem whose data is one of those two rows (code not asserted).
#  W3 model_pick.exploration holds the feature flag id as a string value (key name not fixed by the design).
#  W4 planner-settings projects/cards maps take any project/card id; only their mode word is judged.
set -u
jq() { env -u HOME jq "$@"; }   # jq always loads ~/.jq; every script under bin/ runs it without HOME
BIN=$(dirname "$(readlink -f "$0")"); ROOT=$(dirname "$BIN"); RS="$BIN/resolve.py"; SD="$BIN/stella_data.py"
T=$(mktemp -d -t planner-data-selftest.XXXXXX); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/tmp" "$T/o" "$T/sup/logs"; export TMPDIR=$T/tmp ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env; unset STELLA_ROOT
printf "OWNER_TIMEZONE='UTC'\n" >"$OWNER_CONFIG"; : >"$T/sup/logs/alerts.log"
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
j() { jq -r "$1" "$2"; }
IX=$ROOT/.stella/data-files.json
p() { jq -r --arg s "$1" '[.files[] | select(.schema == $s and .format == "json") | .path][0] // empty' "$IX"; }   # <schema>: its file ("" when the index has none)
rid() { jq -r --arg s "$1" '[.files[] | select(.schema == $s and .format == "json") | .id][0] // empty' "$IX"; }  # <schema>: its index row id
RJREL=$(j .role_table "$IX"); RJ=$ROOT/$RJREL
mk() {  # <name> [<from name>]: a scratch root with a copy of the data, the role table and its hooks (or of another scratch root)
  rm -rf "${T:?}/$1"
  if [ -n "${2:-}" ]; then cp -r "$T/$2" "$T/$1"; return; fi
  mkdir -p "$T/$1/$(dirname "$RJREL")" "$T/$1/.supervisor"; cp "$ROOT/.supervisor/limits.env" "$T/$1/.supervisor/"; cp -r "$ROOT/.stella" "$T/$1/.stella"
  cp "$RJ" "$T/$1/$RJREL"; cp -r "$(dirname "$RJ")/hooks" "$T/$1/$(dirname "$RJREL")/hooks"
}
ed() { local r f; r=$(p "$2"); [ -n "$r" ] || return 1; f="$T/$1/$r"; [ -f "$f" ] || return 1; jq "${@:3}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <root> <schema> <jq args and filter>
chk() { STELLA_ROOT=$T/$1 python3 -I -B "$SD" check --json >"$T/o/$2.json" 2>"$T/o/$2.err"; echo $? >"$T/o/$2.rc"; }   # <root> <name>: the data check
rc() { cat "$T/o/$1.rc" 2>/dev/null; }
passed() { [ "$(rc "$1")" = 0 ] && jq -e '.ok == true' "$T/o/$1.json" >/dev/null 2>&1; }
refused() { [ "$(rc "$1")" = 1 ] && jq -e --argjson d "$2" 'any(.problems[]; .data as $x | $d | index($x) != null)' "$T/o/$1.json" >/dev/null 2>&1; }   # <name> <json list of data ids>: exit 1, a problem on one of them
uuid() { cat /proc/sys/kernel/random/uuid; }

RT=$ROOT/$(p routing); RA=$ROOT/$(p role-assignments); FT=$ROOT/$(p features)
PLID=$(rid planner); PSID=$(rid planner-settings); PL=$(p planner); PS=$(p planner-settings)
TIERS=$(jq -c '[.task_tiers[].id]' "$RT"); PRESETS=$(jq -c '.effort_modes | keys' "$RA"); ROLES=$(jq -c '.roles | keys' "$RJ")
IDS="[\"$PLID\",\"$PSID\"]"
have() { [ -n "$PLID" ] && [ -n "$PSID" ] && [ -f "$ROOT/$PL" ] && [ -f "$ROOT/$PS" ] || { echo "     (no planner / planner-settings index row or file)" >&2; return 1; }; }
pj() { have && jq -e --argjson tiers "$TIERS" --argjson presets "$PRESETS" --argjson roles "$ROLES" "$1" "$ROOT/$PL" >/dev/null; }   # <filter>: holds on planner.json
ok '[ "$(jq length <<<"$TIERS")" -ge 2 ] && [ "$(jq length <<<"$PRESETS")" -ge 1 ] && [ "$(jq length <<<"$ROLES")" -ge 1 ]' "0a the shipped data gives task tiers, presets and roles"
mk base; chk base base0
ok 'passed base0' "0b the shipped data passes check in a scratch root"

# ---- AC-DATA: files, rows, schemas, check ----
ok 'have && [ -f "$ROOT/.stella/schemas/planner.schema.json" ] && [ -f "$ROOT/.stella/schemas/planner-settings.schema.json" ] && jq -e --arg i "$PSID" "[.files[] | select(.id == \$i)][0].owner_only == true" "$IX" >/dev/null' \
  "AC-DATA 1 index rows of schema planner and planner-settings name existing files and schemas; planner-settings is owner_only"
STELLA_ROOT=$T/base python3 -I -B "$SD" get --json "$PLID" >"$T/o/get.json" 2>"$T/o/get.err"; echo $? >"$T/o/get.rc"
ok 'have && passed base0 && [ "$(rc get)" = 0 ] && jq -e ".rubric.features | length >= 1" "$T/o/get.json" >/dev/null' "AC-DATA 2 the shipped planner data passes check and stella_data.py get serves it"

# ---- AC-DATA: seed values (design Data (W0) 1, spec E2/E3/E8) ----
ok 'pj '"'"'.rubric | (.features | length == 6) and ([.features[].points] | sort == [1,1,1,1,1,2])
  and ([.features[].id] | sort == (["multi_system","new_dependency","ambiguous","large_work","human_gate","new_project"] | sort))
  and ([.features[] | select(.id == "multi_system")][0].points == 2) and all(.features[]; (.question | type) == "string" and (.question | length) > 0)
  and ([.thresholds[].tier] == $tiers) and ([.thresholds[] | .max_score] == [1,3,null]) and (.thresholds[-1] | has("max_score") | not)
  and .unsure.raise_tiers == 1 and (.extract_role as $x | any($roles[]; . == $x))'"'"'' \
  "AC-DATA 3 rubric seed: six features (multi_system 2 points, the rest 1), thresholds over the task tiers in order (<=1, <=3, last open), unsure raises one tier, extract_role is a role"
ok 'pj '"'"'(.tiers | keys | sort) == ($tiers | sort) and ([$tiers[] as $t | .tiers[$t].behavior] == ["direct","card_roadmap","roadmap_card"])
  and ([$tiers[] as $t | .tiers[$t].gate] == [false,false,true]) and all(.tiers[]; .question_tier as $q | any($tiers[]; . == $q))'"'"'' \
  "AC-DATA 4 tiers seed: one entry per task tier, behaviour direct / card_roadmap / roadmap_card, gate on the last only, question_tier a task tier"
ok 'pj '"'"'(.modes.ids | to_entries | map(.value) | sort == ["auto","no","yes"]) and .modes.default == "auto"
  and (.local_only_warn.presets | length >= 1 and all(.[]; . as $x | any($presets[]; . == $x)))
  and (.local_only_warn.tiers | length >= 1 and all(.[]; . as $x | any($tiers[]; . == $x)))'"'"'' \
  "AC-DATA 5 modes yes/auto/no with default auto; local_only_warn names known presets and task tiers"
ok 'pj '"'"'.replan.block_limit == 2 and .report.interval_days == 7 and .scope_guard.min_shared_terms == 1
  and all(.card_size.default_limits | (.files, .changed_lines, .estimate_hours); type == "number")
  and (.card_size.min_samples | type == "number") and (.card_size.max_fail_rate | type == "number")
  and (.lint.feel_words | length >= 1) and (.lint.comparators | length >= 1) and (.model_pick.min_samples | type == "number")'"'"'' \
  "AC-DATA 6 replan block_limit 2, weekly report, scope guard min 1 shared term, card_size / lint / model_pick sections present"
ok 'have && jq -e --slurpfile pl "$ROOT/$PL" "(\$pl[0].modes.ids | to_entries | map(.value)) as \$m | .defaults.question_first == false and (.defaults.mode as \$d | any(\$m[]; . == \$d)) and (.projects | type == \"object\") and (.cards | type == \"object\")" "$ROOT/$PS" >/dev/null' \
  "AC-DATA 7 planner-settings defaults: question_first false, mode a planner mode word; projects and cards maps"
ok 'jq -e --slurpfile pl "$ROOT/$PL" '"'"'(.phase_order) as $po | (.entries | map({key: .id, value: .}) | from_entries) as $e
  | $e.planner.status == "on" and $e["planner-question-first"].status == "on" and $e["planner-exploration"].status == "off"
  and all("planner-routing-stats-mock","planner-benchmark-priors-mock","planner-probe-sketch-stub","planner-scope-guard-stub","planner-failure-history"; . as $s | any($po[]; . == $e[$s].due_phase))
  and ($e["planner-vm-field"] != null)
  and ([$pl[0].model_pick.exploration | .. | strings] | any(. as $s | $e[$s].status == "off"))'"'"' "$FT" >/dev/null 2>&1' \
  "AC-DATA 8 features: planner and planner-question-first on, planner-exploration off and named by model_pick.exploration, stubs due at a phase of phase_order, planner-vm-field present"

# ---- AC-DATA: unknown ids fail closed ----
U=qa-no-such-id
bad() {  # <name> <schema> <jq filter>: a copy with that edit is refused by check on the planner rows
  mk "$1" base; ed "$1" "$2" --arg u "$U" "$3" || { echo "     ($1: nothing to edit)" >&2; return 1; }; chk "$1" "$1"; refused "$1" "$IDS"; }
ok 'bad u-role planner ".rubric.extract_role = \$u"' "AC-DATA 9a an unknown rubric.extract_role (role id) fails closed"
ok 'bad u-thr planner ".rubric.thresholds[0].tier = \$u"' "AC-DATA 9b an unknown thresholds tier fails closed"
ok 'bad u-tkey planner ".tiers[\$u] = (.tiers | to_entries[0].value)"' "AC-DATA 9c an unknown key of tiers fails closed"
ok 'bad u-qt planner ".tiers |= map_values(.question_tier = \$u)"' "AC-DATA 9d an unknown question_tier fails closed"
ok 'bad u-wp planner ".local_only_warn.presets += [\$u]"' "AC-DATA 9e an unknown local_only_warn preset fails closed"
ok 'bad u-wt planner ".local_only_warn.tiers += [\$u]"' "AC-DATA 9f an unknown local_only_warn tier fails closed"
ok 'bad u-md planner ".modes.default = \$u"' "AC-DATA 9g a modes.default that is no mode word fails closed"
ok 'bad u-flag planner ".model_pick.exploration |= with_entries(if (.value | type) == \"string\" then .value = \$u else . end)"' "AC-DATA 9h an unknown exploration feature flag fails closed"
ok 'bad u-sd planner-settings ".defaults.mode = \$u"' "AC-DATA 9i planner-settings: an unknown default mode word fails closed"
ok 'bad u-sp planner-settings ".projects[\"qa-proj\"] = {mode: \$u}"' "AC-DATA 9j planner-settings: an unknown project mode word fails closed"
ok 'bad u-sc planner-settings ".cards[\"qa-card\"] = {mode: \$u}"' "AC-DATA 9k planner-settings: an unknown card mode word fails closed"

# ---- AC-DATA: fake entries (data only, no code change) ----
SDH=$(sha256sum "$SD" | cut -d' ' -f1)
mk fk base; ed fk planner '.rubric.features += [{id: "qa_fake_feature", points: 1, question: "Does the request name a fake QA feature?"}]'; chk fk fk
STELLA_ROOT=$T/fk python3 -I -B "$SD" get --json "$PLID" >"$T/o/fkget.json" 2>/dev/null
ok 'have && passed fk && jq -e "any(.rubric.features[]; .id == \"qa_fake_feature\")" "$T/o/fkget.json" >/dev/null && [ "$(sha256sum "$SD" | cut -d" " -f1)" = "$SDH" ]' \
  "AC-DATA 10a fake entry: a rubric feature added as data passes check and is served, the data tool unchanged"
S=$(j .selection.global "$RA")
mk fp base; ed fp role-assignments --arg s "$S" '.effort_modes["qa-preset"] = (.effort_modes[$s] | .builtin = false | .based_on = $s | .label = "QA preset")'
ed fp planner '.local_only_warn.presets += ["qa-preset"]'; chk fp fp
ok 'have && passed fp' "AC-DATA 10b fake entry: a custom preset added as data can be named in local_only_warn and passes check"

[ $fails -eq 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
