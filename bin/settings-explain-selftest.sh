#!/usr/bin/env bash
# Hermetic self-test for `settings.py explain` (F2 W6, B9/A11). Scratch root (STELLA_ROOT): a copy of .stella/, the role table, a FAKE
# env-format owner file and a fake limits file; never the real owner settings. Cases: inherited vs overridden values; the preset and
# its source; Local only from the project row; per-role activity and class-order source; an unknown project is the default policy
# (said so); an unknown preset fails closed with a coded line; the command changes nothing; and a new setting, preset and project
# added as data show up with no code change. (Grants, DC-04 and the three order sources: qa/wave2/T-EXPLAIN.sh.)
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d -t settings-explain-selftest.XXXXXX); trap 'rm -rf "$T"' EXIT
R=$T/root; mkdir -p "$R/docs/hermes-local" "$R/config" "$R/.supervisor/logs" "$T/sup/logs" "$T/pb"
cp -r "$H/.stella" "$R/"
jq '.worker_markers = ["STUB_WORKER_MARK"]' "$H/docs/hermes-local/roles.json" >"$R/docs/hermes-local/roles.json"
cp -r "$H/docs/hermes-local/hooks" "$R/docs/hermes-local/hooks"
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"
export STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG="$T/unused-owner.env" PATH=$T/pb:$PATH
unset STUB_WORKER_MARK
for v in $(jq -r '.worker_signals.token_env[]' "$R/.stella/owner-auth.json"); do unset "$v"; done
ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid); IID=$(jq -r '.entries[0].install_id' "$R/.stella/settings.json")
LIM=$(jq -r '.entries[] | select(.type == "integer" and .store.data == "limits") | .key' "$R/.stella/settings.json" | head -2)
K1=$(sed -n 1p <<<"$LIM"); K2=$(sed -n 2p <<<"$LIM")
printf "# fake owner file\nWORKER_GIT_NAME='Fake One'\n" >"$R/config/owner.env"; printf "%s=7\n" "$K1" >"$R/.supervisor/limits.env"
chmod 600 "$R/config/owner.env"; chmod 640 "$R/.supervisor/limits.env"
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
ed() { jq "${@:2}" "$R/.stella/$1" >"$T/x" && mv "$T/x" "$R/.stella/$1"; }   # <file> <jq args, filter>
ex() { python3 -I "$H/bin/settings.py" explain --project "$1" --json >"$T/o" 2>"$T/e"; }
Q() { jq -e "$1" "$T/o" >/dev/null 2>&1; }
PRE=$(jq -r '.selection.global' "$R/.stella/role-assignments.json")
ROLE=$(jq -r '.assignments[0].role' "$R/.stella/role-assignments.json")
ok 'ex nobody && Q ".project_known == false and (.note | test(\"default\")) and .preset.id == \"'$PRE'\" and .preset.source == \"global\" and .local_only.value == false"' "unknown project: exit 0, default policy said, global preset"
ok 'Q "[.settings[] | select(.key == \"'$K1'\")][0] | .source == \"global\" and .value == 7" && Q "[.settings[] | select(.key == \"'$K2'\")][0].source == \"default\""' "a stored setting is global, an unstored one default"
ok 'Q "[.roles[]] | length > 0 and all(.class_order_source != null)"' "every assignable role has a class order and a source"
ok 'python3 -I "$H/bin/settings.py" explain --project p >"$T/p"; [ -s "$T/p" ] && grep -q "^preset " "$T/p"' "the plain table prints"
# new data, no code change: a setting, a preset, a project (local only), a privacy grant and a revoked crossing grant
ed settings.json --arg g "$ID" '.entries += [(.entries[] | select(.key == "'$K1'") | .global_id = $g | .key = "QA_NEW_SETTING" | .store.key = "QA_NEW_SETTING" | .default = 3)]'
printf "QA_NEW_SETTING=9\n" >>"$R/.supervisor/limits.env"
ed role-assignments.json --arg r "$ROLE" '.effort_modes["qa-new"] = (.effort_modes[.selection.global] + {label: "QA new", builtin: false, based_on: .selection.global} | del(.changelog)) | .selection.projects["qa-p"] = "qa-new"
  | .effort_modes["qa-new"].roles[$r] = {active: false}'
ed data-policy.json --arg g "$(cat /proc/sys/kernel/random/uuid)" --arg i "$IID" '.projects["qa-p"] = {mode: "local_only", allowed_providers: [], global_id: $g, install_id: $i}'
ok 'ex qa-p && Q ".preset == {id: \"qa-new\", source: \"project\"} and .local_only == {value: true, source: \"project\"} and .roles[\"'$ROLE'\"].active == false and ([.settings[] | select(.key == \"QA_NEW_SETTING\")][0] | .value == 9 and .source == \"global\")"' "a new preset, project and setting show up"
ok 'ex qa-p && Q ".roles[\"'$ROLE'\"].class_order_source != null"' "an inactive role is still explained"
S=$(sha256sum "$R/.stella/"*.json "$R/.supervisor/limits.env" "$R/config/owner.env" | sha256sum)
ex qa-p; ok '[ "$(sha256sum "$R/.stella/"*.json "$R/.supervisor/limits.env" "$R/config/owner.env" | sha256sum)" = "$S" ]' "explain changes nothing"
mkdir "$R/bin"; cp "$H"/bin/*.py "$R/bin/"; rm "$R/bin/resolve.py"   # a copy of bin/ without the resolver, inside the scratch root (event_log wants the tool under the root)
ok '! ALERT_CATALOG="$H/docs/hermes-local/alert-catalog.json" python3 -I "$R/bin/settings.py" explain --project qa-p --json >"$T/o" 2>"$T/e" && [ ! -s "$T/o" ] && grep -q "STL-CFG-311" "$T/e" && ! grep -q Traceback "$T/e"' "no resolver installed: a coded refusal, not a traceback"
ed role-assignments.json '.selection.projects["qa-p"] = "qa-gone"'
ok '! ex qa-p && [ ! -s "$T/o" ] && [ "$(wc -l <"$T/e")" = 1 ] && grep -q "STL-CFG-31" "$T/e"' "an unknown preset in selection fails closed with one coded line"
[ "$fails" = 0 ] && { echo "selftest PASS"; exit 0; }
echo "selftest FAIL ($fails)"; exit 1
