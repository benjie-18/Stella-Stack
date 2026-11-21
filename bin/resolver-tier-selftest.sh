#!/usr/bin/env bash
# Hermetic self-test for the tier dimension of role assignments (phase P1, item B: bin/resolve.py, bin/stella_data.py,
# .stella/role-assignments.json), written tests-first by the tester. Checks (P1 tests.json ids): AC8-preset-row, T-TIER-ROWS.
# In scratch roots (STELLA_ROOT = a temp folder with a copy of .stella/, the role table and its hooks) the shipped role
# assignments are edited with jq and judged by bin/stella_data.py check and bin/resolve.py resolve, the resolver's file unchanged.
# No role, preset, tier, provider or model is named here: the tier ids are routing task_tiers, the built-in presets the
# effort_modes with builtin true, the role the one whose assignment rows carry a tier (design.md item B).
# ASSUMPTIONS (what design.md leaves open):
#  B1 a tier row is a role-assignments row with a "tier" key; the seed rows are global scope, one per built-in preset and tier.
#  B2 "a row wins" is read from the answer: the first chain entry whose source is pin:<scope> is that row's chain[0].
#  B3 a project row with no tier beats a global tier row (scope precedence first, then tier, as the design says).
#  B4 a refusal of check is exit 1 with a problem on the role-assignments row (code not asserted: the design names none).
#  B5 the role with tier rows is no card role (resolve is called with no --card).
set -u
jq() { env -u HOME jq "$@"; }   # jq always loads ~/.jq; every script under bin/ runs it without HOME
BIN=$(dirname "$(readlink -f "$0")"); ROOT=$(dirname "$BIN"); RS="$BIN/resolve.py"; SD="$BIN/stella_data.py"
T=$(mktemp -d -t resolver-tier-selftest.XXXXXX); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
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

RT=$ROOT/$(p routing); RA=$ROOT/$(p role-assignments); RAID=$(rid role-assignments); IID=$(j .install_id "$ROOT/$(p install)")
TIERS=$(jq -c '[.task_tiers[].id]' "$RT"); BUILTIN=$(jq -c '[.effort_modes | to_entries[] | select(.value.builtin == true) | .key]' "$RA")
S=$(j .selection.global "$RA")
R=$(jq -r '[.assignments[] | select(.tier != null) | .role] | unique | .[0] // empty' "$RA")   # the role with tier rows (none on the base)
link() { jq -r --arg r "$R" --arg p "$2" --arg t "$3" '[.assignments[] | select(.role == $r and .effort_mode == $p and .tier == $t and .scope.level == "global")][0].chain[0] // empty | "\(.connection)/\(.model)"' "$1"; }   # <file> <preset> <tier>
rs() {  # <root> <name> <args>...: resolve; stdout o/<name>.json, stderr .err, exit code .rc
  STELLA_ROOT=$T/$1 python3 -I -B "$RS" resolve "${@:3}" --json >"$T/o/$2.json" 2>"$T/o/$2.err"; echo $? >"$T/o/$2.rc"
}
fp() { jq -r '[.chain[] | select(.source | startswith("pin:"))][0] // empty | "\(.connection)/\(.model)"' "$T/o/$1.json" 2>/dev/null; }   # <name>: the first pinned link of the answer
answered() { case "$(rc "$1")" in 0|1) [ -s "$T/o/$1.json" ];; *) false;; esac; }   # a JSON answer (usable or not), never fail closed
sel() { ed "$1" role-assignments --arg p "$2" '.selection.global = $p'; }   # <root> <preset>: select it globally
# two tiers whose rows under the selected preset name different links (E8: they differ in every built-in preset but Local only)
TA= TB=; for a in $(jq -r '.[]' <<<"$TIERS"); do for b in $(jq -r '.[]' <<<"$TIERS"); do
  la=$(link "$RA" "$S" "$a"); lb=$(link "$RA" "$S" "$b")
  [ -z "$TA" ] && [ -n "$la" ] && [ -n "$lb" ] && [ "$la" != "$lb" ] && { TA=$a; TB=$b; }; done; done
LA=$(link "$RA" "$S" "$TA"); LB=$(link "$RA" "$S" "$TB")
RSH=$(sha256sum "$RS" | cut -d' ' -f1)
have() { [ -n "$R" ] || { echo "     (no role-assignments row carries a tier)" >&2; return 1; }; }

# ---- preconditions (the fixture machinery, on the shipped data) ----
ok '[ "$(jq length <<<"$TIERS")" -ge 2 ] && [ "$(jq length <<<"$BUILTIN")" -ge 1 ] && [ -n "$S" ] && [ -n "$RAID" ]' "0a the shipped data gives two task tiers or more, a built-in preset, a selected preset and the role-assignments row"
mk base; chk base base0
ok 'passed base0' "0b the shipped data passes check in a scratch root"
mk cust base; ed cust role-assignments --arg s "$S" --arg c qa-custom '.effort_modes[$c] = (.effort_modes[$s] | .builtin = false | .based_on = $s | .label = "QA custom") | .selection.global = $c'; chk cust cust0
ok 'passed cust0' "0c a copy of the selected preset as a custom preset based on it, selected globally, passes check"

# ---- T-TIER-ROWS ----
ok 'have && jq -e --arg r "$R" --argjson ps "$BUILTIN" --argjson ts "$TIERS" '"'"'. as $d | all($ps[] as $p | $ts[] as $t | [$d.assignments[] | select(.role == $r and .effort_mode == $p and .tier == $t and .scope.level == "global")]; length == 1 and (.[0].chain | length) >= 1)'"'"' "$RA" >/dev/null && passed base0' \
  "T-TIER-ROWS 1 the shipped data has exactly one global tier row of the role per built-in preset and task tier, and passes check"
t2() { local P t; for P in $(jq -r '.[]' <<<"$BUILTIN"); do mk "p-$P" base; sel "p-$P" "$P" || return 1
    for t in $(jq -r '.[]' <<<"$TIERS"); do rs "p-$P" "p-$P-$t" --role "$R" --project qa-proj --tier "$t"
      answered "p-$P-$t" && [ "$(fp "p-$P-$t")" = "$(link "$RA" "$P" "$t")" ] || { echo "     (preset $P tier $t: exit $(rc "p-$P-$t"), first pin $(fp "p-$P-$t"))" >&2; return 1; }; done; done; }
ok 'have && t2' "T-TIER-ROWS 2 under each built-in preset selected globally, resolve --tier T answers with the (role, preset, T) row's link as its first pin"
mk inh cust; rs inh inh-a --role "$R" --project qa-proj --tier "$TA"; rs inh inh-b --role "$R" --project qa-proj --tier "$TB"
ok 'have && [ -n "$TA" ] && passed cust0 && answered inh-a && answered inh-b && [ "$(fp inh-a)" = "$LA" ] && [ "$(fp inh-b)" = "$LB" ]' \
  "T-TIER-ROWS 3 a custom preset with no tier rows for the role inherits the rows of its based_on preset (tier $TA -> $LA, tier $TB -> $LB)"
mk orphan cust; ed orphan role-assignments '.effort_modes["qa-custom"].based_on = null'; chk orphan orphan
ok 'have && passed cust0 && refused orphan "[\"$RAID\"]"' "T-TIER-ROWS 4 the same custom preset with based_on null and no tier rows for the role is refused by check (with based_on set it passes)"
addrows() {  # <root> <preset> <tier>...: copies of the selected preset's tier rows for those tiers, under <preset>
  local x t; for t in "${@:3}"; do x=$(uuid)
    ed "$1" role-assignments --arg r "$R" --arg s "$S" --arg p "$2" --arg t "$t" --arg g "$x" --arg i "$IID" \
      '.assignments += [(.assignments[] | select(.role == $r and .effort_mode == $s and .tier == $t and .scope.level == "global")) | .id = "qa-\($p)-\($t)" | .effort_mode = $p | .global_id = $g | .install_id = $i]' || return 1; done; }
mk part cust; addrows part qa-custom "$TA"; chk part part
mk full cust; addrows full qa-custom $(jq -r '.[]' <<<"$TIERS"); chk full full
ok 'have && [ -n "$TA" ] && refused part "[\"$RAID\"]" && passed full' "T-TIER-ROWS 5 a custom preset with tier rows of the role for one tier only is refused by check; rows for every tier pass"
TL=$(jq -r '.[-1]' <<<"$TIERS")
mk hole base; ed hole role-assignments --arg r "$R" --arg s "$S" --arg t "$TL" 'del(.assignments[] | select(.role == $r and .effort_mode == $s and .tier == $t))'; chk hole hole
ok 'have && refused hole "[\"$RAID\"]"' "T-TIER-ROWS 6 a built-in preset missing the role's row for one tier ($TL) is refused by check (partial coverage)"
mk ft base; ed ft routing '.task_tiers += [(.task_tiers[0] | .id = "qa-tier")]'; chk ft ft1
mk ft2 ft; for P in $(jq -r '.[]' <<<"$BUILTIN"); do x=$(uuid); ed ft2 role-assignments --arg r "$R" --arg p "$P" --arg t "$TB" --arg g "$x" \
  '.assignments += [(.assignments[] | select(.role == $r and .effort_mode == $p and .tier == $t and .scope.level == "global")) | .id = "qa-tier-\($p)" | .tier = "qa-tier" | .global_id = $g]'; done
chk ft2 ft2; rs ft2 ft2r --role "$R" --project qa-proj --tier qa-tier
ok 'have && [ -n "$TB" ] && refused ft1 "[\"$RAID\"]" && ! refused ft2 "[\"$RAID\"]" && answered ft2r && [ "$(fp ft2r)" = "$LB" ]' \
  "T-TIER-ROWS 7 fake entry: a task tier added as data is refused until the role has a row for it in every built-in preset; with the rows, resolve --tier of it answers their link, no code change"

# ---- AC8-preset-row ----
mk sw base; rs sw sw0 --role "$R" --project qa-proj --tier "$TA"
ed sw role-assignments --arg r "$R" --arg s "$S" --arg a "$TA" --arg b "$TB" \
  '([.assignments[] | select(.role == $r and .effort_mode == $s and .tier == $b and .scope.level == "global")][0].chain) as $c | .assignments |= map(if .role == $r and .effort_mode == $s and .tier == $a and .scope.level == "global" then .chain = $c else . end)'
chk sw sw; rs sw sw1 --role "$R" --project qa-proj --tier "$TA"
ok 'have && [ -n "$TA" ] && answered sw0 && [ "$(fp sw0)" = "$LA" ] && passed sw && answered sw1 && [ "$(fp sw1)" = "$LB" ] && [ "$(sha256sum "$RS" | cut -d" " -f1)" = "$RSH" ]' \
  "AC8-preset-row 1 changing the (role, selected preset, tier $TA) row's chain in data changes the resolved model from $LA to $LB, with the resolver's file unchanged"
mk nt base; x=$(uuid); ed nt role-assignments --arg r "$R" --arg s "$S" --arg b "$TB" --arg g "$x" \
  '.assignments += [(.assignments[] | select(.role == $r and .effort_mode == $s and .tier == $b and .scope.level == "global")) | del(.tier) | .id = "qa-notier" | .global_id = $g]'
chk nt nt; rs nt nt1 --role "$R" --project qa-proj --tier "$TA"
ok 'have && [ -n "$TA" ] && passed nt && answered nt1 && [ "$(fp nt1)" = "$LA" ]' "AC8-preset-row 2 at the same scope a (role, preset, tier) row wins over a (role, preset) row with no tier"
# the row with no tier carries its own chain and class order: at the scope of a tier row neither may reach the answer (pass 2 mutant B1)
LOC=$(j .class_defaults.local "$RT"); sig() { jq -c '[.chain[] | {connection, model, source, status}]' "$T/o/$1.json" 2>/dev/null; }
mk nt2 base; x=$(uuid); ed nt2 role-assignments --arg r "$R" --arg s "$S" --arg b "$TB" --arg g "$x" --arg l "$LOC" \
  '.assignments += [(.assignments[] | select(.role == $r and .effort_mode == $s and .tier == $b and .scope.level == "global")) | del(.tier) | .id = "qa-notier2" | .global_id = $g | .class_order = [$l]]'
chk nt2 nt2; rs nt2 nt2r --role "$R" --project qa-proj --tier "$TA"; rs nt2 nt2n --role "$R" --project qa-proj
ok 'have && [ -n "$TA" ] && passed nt2 && answered nt2r && answered sw0 && [ "$(sig nt2r)" = "$(sig sw0)" ] && answered nt2n && [ "$(fp nt2n)" = "$LB" ]' \
  "AC8-preset-row 2b a row with no tier (its own chain and class_order) at the scope of a tier row leaves the --tier answer's chain exactly as without it; without --tier it is the pin"
mk pj base; x=$(uuid); ed pj role-assignments --arg r "$R" --arg s "$S" --arg b "$TB" --arg g "$x" \
  '.assignments += [(.assignments[] | select(.role == $r and .effort_mode == $s and .tier == $b and .scope.level == "global")) | del(.tier) | .id = "qa-proj-row" | .scope = {level: "project", project: "qa-proj"} | .global_id = $g]'
chk pj pj; rs pj pj1 --role "$R" --project qa-proj --tier "$TA"; rs pj pj2 --role "$R" --project qa-other --tier "$TA"
ok 'have && [ -n "$TA" ] && passed pj && answered pj1 && [ "$(fp pj1)" = "$LB" ] && answered pj2 && [ "$(fp pj2)" = "$LA" ]' \
  "AC8-preset-row 3 scope precedence is unchanged: a project row with no tier beats the global tier row in its project, not in another"

[ $fails -eq 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
