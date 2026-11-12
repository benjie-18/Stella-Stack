#!/usr/bin/env bash
# Hermetic self-test for bin/stella_data.py (E1 items 1, 6, 7): the contract data, its schemas and the cross-file rules.
# Case 1-2 read this tree; every other case works in a scratch root (STELLA_ROOT = a temp folder with a copy of .stella/)
# and proves a fake entry works with no code change. The alert log goes to a temp folder (ESCALATE_SUP_DIR).
set -u
BIN=$(dirname "$(readlink -f "$0")"); ROOT=$(dirname "$BIN"); SD="$BIN/stella_data.py"
T=$(mktemp -d -t stella-data-selftest.XXXXXX); SW=; trap '[ -n "$SW" ] && kill $SW 2>/dev/null; rm -rf "$T"' EXIT   # SW: case 177's link swapper
export ESCALATE_SUP_DIR=$T/sup
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
mk() {  # <name>: a scratch root with a copy of the data and the role table
  mkdir -p "$T/$1/docs/hermes-local"; cp -r "$ROOT/.stella" "$T/$1/.stella"; cp "$ROOT/docs/hermes-local/roles.json" "$T/$1/docs/hermes-local/"
  cp -r "$ROOT/docs/hermes-local/hooks" "$T/$1/docs/hermes-local/hooks"   # R5: the table's hook files are looked up under the root it belongs to
}
ed() { local f="$T/$1/.stella/$2"; jq "$3" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <root name> <file> <jq filter>
sd() { STELLA_ROOT=$T/$1 python3 -I "$SD" "${@:2}"; }                          # <root name> <args...>
AR=$(jq -c '.fallback_role as $fb | [.roles | keys[] | select(. != $fb)]' "$ROOT/docs/hermes-local/roles.json")   # every assignable role
conn() {  # <id> <kind> <subkind> <locality>: a complete connections entry as jq text; it allows every assignable role, so a case fails for its own cause
  echo "{id:\"$1\",kind:\"$2\",subkind:\"$3\",label:\"Fake $1\",enabled:true,locality:\"$4\",hosts:[{host:\"$1.example.invalid\",port:443,purpose:\"api\"}],auth_types:[\"api_key\"],secrets:[\"FAKE_KEY\"],actions:[{id:\"go\",approval_class:\"write\"}],models:[{id:\"$1-model\",capabilities:{tool_calling:null,json_mode:null,context_tokens:null,vision:null,streaming:null},probed_at:null,probe_source:null}],data_policy:{retention:null,training_use:null,region:null,zero_retention_available:null,data_classes_allowed:[\"public\",\"internal\",\"client\"]},tos:{status:\"unverified\",subscription_login_by_agent:\"unverified\"},allowed_roles:$AR,risk_class:\"read\"}"
}
refuses() { local r=$1; shift; ! sd "$r" "$@" >"$T/o" 2>&1; }                 # <root name> <args...>: exits non-zero, output in $T/o
alerts() { cat "$T/sup/logs/alerts.log" 2>/dev/null | wc -l; }

ok 'python3 -I "$SD" check >"$T/live" 2>&1' "1 every shipped data file and schema of this tree validates$(sed 's/^/\n     /' "$T/live" 2>/dev/null | head -5)"
ok 'python3 -I "$SD" check --json | jq -e ".ok == true and (.problems | length) == 0" >/dev/null' "2 check --json says ok with no problems"
ok 'python3 -I "$SD" list --json | jq -e "map(.id) | contains([\"connections\",\"role-assignments\",\"data-policy\",\"capabilities\",\"features\",\"versions\",\"settings\",\"extensions\",\"approved-hosts\"])" >/dev/null' "3 list names every data file"

# The shipped event and approval schemas accept a good line and refuse a bad one.
echo '{"schema_version":1,"time":"2026-11-10T12:00:00Z","type":"apply","who":{"role":null,"channel":null,"user":"owner"},"what":"x","old":1,"new":2}' >"$T/ev.json"
ok 'python3 -I "$SD" validate event "$T/ev.json"' "4 a good event line validates"
ok '! python3 -I "$SD" validate event <(jq "del(.time)" "$T/ev.json")' "5 an event line without a time is refused"
ok '! python3 -I "$SD" validate event <(jq ".time = \"yesterday\"" "$T/ev.json")' "6 an event line with a bad time is refused"
echo '{"schema_version":1,"id":"r1","requested_at":"2026-11-10T12:00:00Z","requester":{"role":"builder","channel":null,"user":null},"approval_class":"post","action":"post a message","summary":"s","target":null,"card":null,"expires_at":null}' >"$T/rq.json"
echo '{"schema_version":1,"request_id":"r1","decided_at":"2026-11-10T12:01:00Z","decision":"approved","decided_by":{"channel":"app","user":"owner"},"note":null}' >"$T/dc.json"
ok 'python3 -I "$SD" validate approval-request "$T/rq.json" && python3 -I "$SD" validate approval-decision "$T/dc.json"' "7 a good approval request and decision validate"
ok '! python3 -I "$SD" validate approval-decision <(jq ".decision = \"maybe\"" "$T/dc.json")' "8 a decision outside approved, denied, expired is refused"

# Fake entries: each validates and is returned by get, list and search, with no code change.
mk fake
ed fake connections.json ".entries += [$(conn fake-prov provider openai-compatible-aggregator cloud), $(conn fake-app app mail cloud), $(conn fake-chan channel chat cloud)]"
ed fake capabilities.json '.entries += [{id:"fake-cap",kind:"command",summary:"frobnicate the widgets",keywords:["frob"],inputs:"a widget",outputs:"a frobbed widget",allowed_roles:["builder"],risk_class:"read",hosts:[],secrets:[],status:"proposed",source:"fake",triage:{result:"pending"}}]'
echo '{"schema_version":1,"id":"fake-ext","kind":"mcp_server","summary":"fake extension for gizmos","hosts":["gizmo.example.invalid:443"],"secrets":["GIZMO_KEY"],"tools":["gizmo_get"],"allowed_roles":["reviewer"],"risk_class":"read","enabled":false,"status":"proposed","source":"fake"}' >"$T/fake/.stella/extensions/fake-ext.json"
ok 'sd fake check' "9 a scratch root with a fake provider, app, channel, capability and extension passes check"
for e in fake-prov:connections fake-app:connections fake-chan:connections fake-cap:capabilities fake-ext:extensions; do
  id=${e%%:*}; d=${e##*:}
  ok "[ \"\$(sd fake get $d $id --json | jq -r .id)\" = $id ]" "10 get $d $id returns the fake entry"
  ok "sd fake list $d --json | jq -e 'map(.id) | index(\"$id\")' >/dev/null" "11 list $d includes $id"
  ok "sd fake search $id --json | jq -e 'map(.id) | index(\"$id\")' >/dev/null" "12 search finds $id"
done
ok '[ "$(sd fake search frobnicate --json | jq -r ".[0].id")" = fake-cap ]' "13 search matches the words of a summary"
mk rank; ed rank capabilities.json '.entries += [{id:"aaa-pending",kind:"command",summary:"stella-data helper",keywords:[],inputs:"x",outputs:"y",allowed_roles:[],risk_class:"read",hosts:[],secrets:[],status:"proposed",source:"fake",triage:{result:"pending"}}]'
ok '[ "$(sd rank search stella-data --json | jq -r ".[0].status")" = approved ]' "14 search lists approved entries before proposed ones"
mk agg; ed agg connections.json ".entries += [$(conn agg-one provider openai-compatible-aggregator cloud), $(conn agg-two provider openai-compatible-aggregator cloud)]"
ok 'sd agg check && [ "$(sd agg list connections --json | jq "[.[] | select(.subkind == \"openai-compatible-aggregator\")] | length")" -ge 3 ]' "15 a second, different aggregator of the same subkind needs no code change"

# Fail closed.
n=$(alerts)
ok 'sd fake get connections nope-nothing >"$T/o" 2>"$T/e"; rc=$?; [ $rc -ne 0 ] && grep -q STL-CFG-311 "$T/e" && [ "$(alerts)" -eq $((n+1)) ] && tail -1 "$T/sup/logs/alerts.log" | grep -q "^STL-CFG-311 "' "16 an unknown entry id fails closed with code STL-CFG-311 and exactly one alert line"
n=$(alerts)
ok '! sd fake get nodata >/dev/null 2>"$T/e"; grep -q STL-CFG-311 "$T/e" && [ "$(alerts)" -eq $((n+1)) ]' "17 an unknown data id fails closed with one alert line"
ok '! sd fake search --json 2>/dev/null' "18 search with no words is refused"

# check refuses.
mk bad1; ed bad1 connections.json '.entries[0].kind = "bogus"'
ok 'refuses bad1 check && grep -q "STL-CFG-310" "$T/o" && grep -q "kind" "$T/o"' "19 a schema violation makes check exit 1 with STL-CFG-310"
mk bad2; ed bad2 connections.json 'del(.schema_version)'
ok 'refuses bad2 check && grep -q "schema_version" "$T/o"' "20 a data file without schema_version makes check exit 1"
mk bad3; jq '.properties.entries.contains = {}' "$T/bad3/.stella/schemas/connections.schema.json" >"$T/bad3/s" && mv "$T/bad3/s" "$T/bad3/.stella/schemas/connections.schema.json"
ok 'refuses bad3 check && grep -q "contains" "$T/o"' "21 a schema keyword the validator does not know is an error, never ignored"
mk bad4; ed bad4 role-assignments.json '.assignments[0].chain[0].provider = "no-such-provider"'
ok 'refuses bad4 check && grep -q "chain\[0\].provider" "$T/o" && ! grep -q "no-such-provider" "$T/o"' "22 a dangling provider reference in a role assignment is refused, and the line names the field, not the value"
mk bad5; ed bad5 role-assignments.json '.assignments[0].chain[0].model = "no-such-model"'
ok '! sd bad5 check >/dev/null 2>&1' "23 an unknown model in a chain is refused"
mk bad6; ed bad6 role-assignments.json '.assignments[0].role = "no-such-role"'
ok '! sd bad6 check >/dev/null 2>&1' "24 an unknown role in an assignment is refused"
mk bad7; ed bad7 role-assignments.json '.assignments[0].chain = []'
ok '! sd bad7 check >/dev/null 2>&1' "25 an empty chain is refused"
mk bad8; ed bad8 role-assignments.json '.assignments[0].effort_mode = "no-such-mode"'
ok '! sd bad8 check >/dev/null 2>&1' "26 an unknown effort mode is refused"
mk bad9; ed bad9 connections.json ".entries += [$(conn cloud-one provider hosted cloud)]"
ed bad9 role-assignments.json '.assignments[0].effort_mode = "local_only" | .assignments[0].chain = [{provider:"cloud-one",model:"cloud-one-model",parameters:{}}]'
ok '! sd bad9 check >/dev/null 2>&1' "27 a chain entry whose locality the effort mode forbids is refused"
# A project assignment that widens the data policy: the project allows only the local rows, the override names a cloud provider.
mk wide; ed wide connections.json ".entries += [$(conn cloud-one provider hosted cloud)]"
ed wide data-policy.json '.projects.proj1 = {mode:"local_only",allowed_providers:[]}'
ed wide role-assignments.json '.assignments += [{id:"proj1-builder",scope:{level:"project",project:"proj1"},role:"builder",effort_mode:"standard",chain:[{provider:"cloud-one",model:"cloud-one-model",parameters:{}}]}]'
ok 'refuses wide check && grep -q "cloud-one" "$T/o" && grep -q STL-CFG-310 "$T/o"' "28 a project assignment that widens the data policy makes check exit 1"
ed wide data-policy.json '.projects.proj1 = {mode:"allowed_providers",allowed_providers:["cloud-one"]}'
ok 'sd wide check' "29 the same assignment passes when the project policy names that provider (control)"
mk bad10; ed bad10 features.json '.entries += [{id:"zz-a",owner_phase:"x",status:"planned",depends_on:["zz-b"],flag:null},{id:"zz-b",owner_phase:"x",status:"planned",depends_on:["zz-a"],flag:null}]'
ok 'refuses bad10 check && grep -q "zz-" "$T/o"' "30 a feature dependency cycle is refused"
mk bad11; ed bad11 features.json '.entries[0].depends_on += ["no-such-feature"]'
ok '! sd bad11 check >/dev/null 2>&1' "31 a feature that depends on a missing feature is refused"
mk bad12; ed bad12 capabilities.json '.entries[0].allowed_roles += ["no-such-role"]'
ok '! sd bad12 check >/dev/null 2>&1' "32 a capability naming a role that is not in the role table is refused"
mk bad13; ed bad13 settings.json '.entries[0].store.data = "no-such-data"'
ok '! sd bad13 check >/dev/null 2>&1' "33 a setting stored in a data file that is not in the index is refused"
mk bad14; ed bad14 connections.json '.entries[0].secrets += ["not a name"]'
ok '! sd bad14 check >/dev/null 2>&1' "34 a secret with characters a variable name cannot have is refused (63 and 64 cover the shape rule)"
mk bad15; ed bad15 connections.json '.entries += [.entries[0]]'
ok 'refuses bad15 check && grep -qi "duplicate" "$T/o"' "35 a duplicate entry id is refused"
mk bad16; echo '{' >"$T/bad16/.stella/features.json"
ok '! sd bad16 check >/dev/null 2>&1' "36 an unreadable data file is refused, not skipped"
mk bad17; rm "$T/bad17/.stella/schemas/features.schema.json"
ok '! sd bad17 check >/dev/null 2>&1' "37 a missing schema file is refused"

# Secrets: names only. No value-like string in any data file or schema (integrity digests are not secrets).
ok '! cat "$ROOT"/.stella/*.json "$ROOT"/.stella/extensions/*.json "$ROOT"/.stella/schemas/*.json 2>/dev/null | jq -r "del(..|.integrity?) | .. | strings" 2>/dev/null | grep -Eq "sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|xox[bap]-|AKIA[0-9A-Z]{12,}|BEGIN [A-Z ]*PRIVATE KEY|[A-Za-z0-9+/]{60,}={0,2}"' "38 no data file or schema holds a secret-looking value"
ok '[ "$(jq -r "[.entries[].secrets[]?] | map(select(test(\"^[A-Z][A-Z0-9_]*$\") | not)) | length" "$ROOT/.stella/connections.json")" = 0 ]' "39 every secret in the connections catalog is a variable name"
ok '! grep -rnE "/workspace|/home/" "$SD"' "40 the tool names no stack path and no home folder"

# ---- fix round 1 (G1 to G6) ----
# G1 the validator
mk g1a; ed g1a versions.json '.schema_version = true'
ok 'refuses g1a check && grep -q STL-CFG-310 "$T/o"' "41 schema_version true is not the number 1 (const compares by type)"
mk g1b; ed g1b connections.json '.entries += [.entries[0] | .id += "\n"]'
ok 'refuses g1b check' "42 a pattern ending in a dollar sign does not accept a value with a final newline"
mk g1c; echo '{"type":"object","required":"id"}' >"$T/g1c/.stella/schemas/zz1.schema.json"; echo '{"type":"string","enum":"approved"}' >"$T/g1c/.stella/schemas/zz2.schema.json"
echo '{"$defs":{"s":{"type":"string"}},"type":"object","properties":{"a":{"$ref":"https://other.invalid/x#/$defs/s"}}}' >"$T/g1c/.stella/schemas/zz3.schema.json"
echo '{"$defs":{"s":{"type":"string"}},"type":"object","properties":{"a":{"$ref":"#/$defs/s","maxLength":3}}}' >"$T/g1c/.stella/schemas/zz4.schema.json"
echo '{"i":1,"d":2}' >"$T/d1"; echo '"prove"' >"$T/d2"; echo '{"a":"x"}' >"$T/d3"; echo '{"a":"toolong"}' >"$T/d4"
ok '! sd g1c validate zz1 "$T/d1" 2>&1 | grep -qx valid && ! sd g1c validate zz2 "$T/d2" 2>&1 | grep -qx valid && ! sd g1c validate zz3 "$T/d3" 2>&1 | grep -qx valid && ! sd g1c validate zz4 "$T/d4" 2>&1 | grep -qx valid' "43 schema keyword values are linted: a string for a list, an external ref, a ref sibling are not ignored"
mk g1d
printf '{"schema_version":1,"data_classes":["public"],"default":{"mode":"open","allowed_providers":[]},"projects":{"cx":{"mode":"local_only","allowed_providers":[]},"cx":{"mode":"open","allowed_providers":[]}}}' >"$T/g1d/.stella/data-policy.json"
ok 'refuses g1d check && grep -qi "repeated" "$T/o"' "44 a repeated JSON key is refused"
mk g1e; sed -i '0,/"cost": null/s//"cost": {"per_call": NaN, "cap": Infinity}/' "$T/g1e/.stella/connections.json"
ok 'grep -q NaN "$T/g1e/.stella/connections.json" && refuses g1e check' "45 NaN in a data file is refused"
mk g1f; ed g1f connections.json '.entries[0].secrets = ["sk-live-abcdef0123456789xyz"]'
ok 'refuses g1f check && ! grep -q abcdef0123 "$T/o"' "46 a problem message never prints the rejected value"
# G2 paths
mk g2a; ed g2a data-files.json '.files += [{id:"zz-out",path:"../outside.json",schema:"approved-hosts",format:"json",owner_only:false,redact_keys:[],list_key:"hosts",id_field:"host"}]'
echo '{"schema_version":1,"hosts":[],"MARK":"OUTSIDE-MARKER"}' >"$T/outside.json";
ok 'refuses g2a check && ! sd g2a get zz-out 2>&1 | grep -q OUTSIDE-MARKER && refuses g2a get zz-out' "47 an index path with .. is refused by check, and get prints nothing from it"
mk g2b; ed g2b data-files.json '.backup_dir = "/var/backups"'
ok 'refuses g2b check' "48 an absolute backup_dir is refused"
mk g2c; ln -s "$T/outside.json" "$T/g2c/.stella/extensions/zz-ext.json"
ok 'refuses g2c check && refuses g2c list extensions && ! sd g2c get extensions zz-ext 2>&1 | grep -q OUTSIDE-MARKER' "49 a manifest symlinked out of the root is refused"
ok '[ "$(jq -r ".files[] | select(.id == \"data-files\") | .owner_only" "$ROOT/.stella/data-files.json")" = true ]' "50 the index row of the index is owner-only"
# G3 cross-file rules
mk g3a; ed g3a role-assignments.json '.assignments[0].role = "ghost"'
ok 'refuses g3a check connections && grep -q "role-assignments" "$T/o" && grep -q "assignable role" "$T/o" && ! grep -q ghost "$T/o"' "51 check <id> also prints the cross-file problems"
OPEN="(.entries[] | select(.id == \"claude-subscription\")) |= (.allowed_roles = $AR | .data_policy.data_classes_allowed = [\"public\",\"internal\",\"client\"])"   # the subscription provider allowing every role and class
mk g3b; ed g3b connections.json "$OPEN"; ed g3b data-policy.json '.projects["cx"] = {mode:"local_only",allowed_providers:[]}'
ed g3b role-assignments.json '.assignments += [{id:"zz",scope:{level:"card",card:"c1"},role:"builder",effort_mode:"standard",chain:[{provider:"claude-subscription",model:"haiku",parameters:{}}]}]'
ok 'refuses g3b check' "52 a card assignment with no project is refused, not judged by the open default"
ed g3b role-assignments.json '.assignments[-1].scope = {level:"project",project:"CX"}'
ok 'refuses g3b check' "53 a project name in upper case is refused"
mk g3c; ed g3c role-assignments.json '.assignments += [.assignments[0] | .id = "dup"]'
ok 'refuses g3c check' "54 two assignments for one scope, role and effort mode are refused"
mk g3d; ed g3d role-assignments.json '.assignments += [.assignments[0] | .id = "zz" | .role = "unlisted"]'
ok 'refuses g3d check' "55 the fallback role of the role table cannot be assigned"
mk g3e; ed g3e connections.json "$OPEN"; ed g3e connections.json '(.entries[] | select(.id == "claude-subscription")).enabled = false'
ed g3e role-assignments.json '.assignments += [.assignments[0] | .id = "zz" | .role = "reviewer" | .chain = [{provider:"claude-subscription",model:"haiku",parameters:{}}]]'
ok 'refuses g3e check' "56 a chain naming a disabled provider is refused"
mk g3f; echo '{"schema_version":1,"id":"zz-ext","kind":"skill","summary":"s","hosts":[],"secrets":[],"tools":[],"allowed_roles":[],"risk_class":"read","enabled":true,"status":"proposed","source":"x"}' >"$T/g3f/.stella/extensions/zz-ext.json"
ok 'refuses g3f check && grep -q zz-ext "$T/o"' "57 an extension that is switched on without being approved is refused"
mk g3g; ed g3g features.json '(.entries[] | select(.id == "generated-team-files")).status = "on"'
ok 'refuses g3g check' "58 an on feature that depends on a planned feature is refused"
mk g3h; ed g3h settings.json ".entries[0].code = \"STL-ZZZ-$((999))\""   # built at run time: the alert selftest greps every STL code written in bin/
ok 'refuses g3h check' "59 a setting code that is not in the alert catalog is refused"
mk g3i; ed g3i connections.json '.entries[0].data_policy.data_classes_allowed += ["no-such-class"]'
ok 'refuses g3i check' "60 a data class that data-policy does not define is refused"
# G4 schemas and entries
mk g4a; ed g4a connections.json '.entries[0] += {scopes:["read"],redaction_patterns:["sk-[A-Za-z0-9]+"],allowed_roles:'"$AR"',risk_class:"read"} | .entries[1].tos.subscription_login_by_agent = "allowed"'
ok 'sd g4a check' "61 connections accept scopes, redaction_patterns, allowed_roles, risk_class and the declared agent ToS flag"
ed g4a connections.json '.entries[1].tos.subscription_login_by_agent = "maybe"'
ok 'refuses g4a check' "62 the agent ToS flag takes only its declared values"
mk g4b; ed g4b connections.json '.entries[0].secrets += ["AKIAIOSFODNN7EXAMPLE"]'
ok 'refuses g4b check' "63 a pasted key without an underscore is not a secret name"
mk g4c; ed g4c connections.json '.entries[0].secrets += ["A_" + ("X" * 70)]'
ok 'refuses g4c check' "64 a secret name over 64 characters is refused"
mk g4d; ed g4d settings.json '.entries += [{key:"QA_API_TOKEN",label:"x",type:"string",validation:{},scope:"global",sensitivity:"secret",default:"qa-fake-value-7f3a",store:{data:"owner-settings",key:"QA_API_TOKEN"},apply:{script:"bin/stella-apply.py",needs_restart:false},code:"STL-CFG-315"}]'
ok 'refuses g4d check && ! sd g4d get settings QA_API_TOKEN 2>&1 | grep -q qa-fake-value && ! sd g4d search fake-value 2>/dev/null | grep -q QA_API_TOKEN' "65 a secret setting with a default is refused, and get and search never print it"
mk g4e; ed g4e settings.json '(.entries[] | select(.key == "CALL_TIMEOUT")).default = 0'
ok 'refuses g4e check' "66 a setting default outside its own validation is refused"
mk g4g; ed g4g settings.json '(.entries[] | select(.key == "CALL_TIMEOUT")) |= (.default = 5 | .validation = {minimum:9,maximum:1})'
ok 'refuses g4g check' "67 a validation with minimum above maximum is refused"
mk g4h; ed g4h settings.json '(.entries[] | select(.key == "QUEUE_MAX")) |= (.type = "enum" | .default = null | .validation = {})'
ok 'refuses g4h check' "68 an enum setting with no values is refused"
mk g4f; H=$T/g4f/.stella/approved-hosts.json
row() { echo "{\"host\":\"$1\",\"port\":$2,\"scope\":\"$3\",\"approved_by\":\"$4\",\"approved_at\":\"$5\",\"expires_at\":$6}"; }
echo "{\"schema_version\":1,\"hosts\":[$(row a.example.com 443 g o 2026-11-10T00:00:00Z null),$(row a.example.com 8443 g o 2026-11-10T00:00:00Z null)]}" >"$H"
ok 'sd g4f check' "69 the same host on two ports is two entries"
echo "{\"schema_version\":1,\"hosts\":[$(row '*' 443 '' '' never '"never"')]}" >"$H"
ok 'refuses g4f check' "70 a bare wildcard host, empty scope and approver and free-text dates are refused"
# G5 read commands
mk g5a; echo '[]' >"$T/g5a/.stella/extensions/zz-array.json"
ok 'refuses g5a list && grep -q STL-CFG-310 "$T/o" && ! grep -q Traceback "$T/o" && refuses g5a search stella && grep -q STL-CFG-310 "$T/o" && ! grep -q Traceback "$T/o"' "71 a malformed manifest gives exit 1 and a STL-CFG-310 line from list and search, no traceback"
mk g5b; echo '{' >"$T/g5b/.stella/connections.json"
ok 'refuses g5b get connections discord && grep -q STL-CFG-310 "$T/o" && ! grep -q STL-CFG-311 "$T/o" && ! grep -q Traceback "$T/o"' "72 a known entry in a broken file is STL-CFG-310, not 311"
n=$(alerts)
ok 'refuses fake get owner-settings && grep -qi "not readable" "$T/o" && [ "$(alerts)" -eq $n ]' "73 get on an env row says it is known and not readable here, with no alert line"
ok 'sd fake check | grep -qi "not opened" && sd fake check --json | jq -e ".not_opened | index(\"owner-settings\")" >/dev/null' "74 check says which env rows it did not open"
mk g5c; ed g5c capabilities.json '.entries += [.entries[0] | .id = "zz-translate" | .summary = "Übersetzung von Texten"]'
ok 'sd g5c search übersetzung --json | jq -e "map(.id) | index(\"zz-translate\")" >/dev/null && [ "$(sd g5c search locality)" = "" ]' "75 search matches values (not key names), also non-ASCII text"
mk g5d; rm -rf "$T/g5d/.supervisor"
ok '(unset ESCALATE_SUP_DIR; STELLA_ROOT=$T/g5d python3 -I "$SD" get nodata >/dev/null 2>&1; [ -s "$T/g5d/.supervisor/logs/alerts.log" ])' "76 with STELLA_ROOT set, the alert line goes under that root"
# G6 data true to the stack
ok '[ "$(jq "[.entries[] | select(.status == \"on\")] | length" "$ROOT/.stella/features.json")" -ge 10 ] && jq -e "[.entries[].id] | index(\"escalation\") and index(\"watchdog\")" "$ROOT/.stella/features.json" >/dev/null' "77 the feature registry lists the features the stack already runs"
ok 'jq -e ".entries[] | select(.id == \"fallback-gateway\") | .enabled and (.models | length) > 0 and (.secrets | length) > 0" "$ROOT/.stella/connections.json" >/dev/null' "78 the fallback gateway entry is enabled, has its model and the name of its key variable"

# F1 W2 round 2 (F3, F4): one answer for the role table: the schema and roles.py's own validation, in check and in validate roles
RT="$ROOT/docs/hermes-local/roles.json"
FB=$(jq -r .fallback_role "$RT"); R1=$(jq -r --arg fb "$FB" '[.roles | keys[] | select(. != $fb)][0]' "$RT")
ok 'python3 -I "$SD" validate roles "$RT" >/dev/null 2>&1' "79 control: validate roles accepts the shipped table"
n=0
for f in '.profiles["qa-p"] = {"role": "qa-no-such-role"}' '.fallback_role = "qa-no-such-role"' ".roles[\"$FB\"].may_complete = true" \
         ".roles[\"$R1\"].hooks += [{\"matcher\": \"x\", \"file\": \"bin/roles.py\", \"command\": \"/workspace/bin/roles.py\"}]" \
         ".roles[\"$R1\"].hooks += [{\"matcher\": \"(\", \"command\": \"/workspace/bin/roles.py\"}]" ".roles[\"qa bad name\"] = .roles[\"$R1\"]" \
         ".roles[\"$R1\"].requirements.allowed_data_classes = [\"public\n\"]" ".roles[\"$R1\"].git_identity = {\"name\": \"WORKER_GIT_NAME\"}" \
         ".roles[\"$R1\"].allowed_overrides = [\"model\", \"model\"]" '.protected.repo += [.protected.repo[0]]' \
         ".roles[\"$R1\"].requirements.allowed_data_classes = [\"bogus\"]" '.schema_version = true' '.schema_version = "1"' \
         ".roles[\"$R1\"].requirements.min_context_tokens = 9007199254740992" ".roles[\"$R1\"].may_answer_for_owner = 1" \
         ".roles[\"$FB\"].requirements.allowed_data_classes += [\"zz-extra\"]" '.profiles["qa bad"] = {"role": .fallback_role}' \
         ".roles[\"$R1\"].qa_unknown_key = 1" ".roles[\"$R1\"].complete_needs_reveiw = true" ".profiles[.profiles | keys[0]].qa_unknown_key = 1" '.qa_unknown_key = 1'; do
  n=$((n+1)); mk rt$n; jq "$f" "$RT" >"$T/rtc$n.json"; cp "$T/rtc$n.json" "$T/rt$n/docs/hermes-local/roles.json"
  ok 'refuses rt'$n' validate roles "$T/rtc'$n'.json" && grep -q "^STL-CFG-310 " "$T/o"' "80.$n validate roles refuses a broken table: $f"
  ok 'refuses rt'$n' check && grep -q "^STL-CFG-310 " "$T/o"' "81.$n check refuses the same table in the index's role_table, as STL-CFG-310 lines"
done
mk rtd; jq '.roles["qa-x"] = .roles.'"$FB"' | .roles["qa-x"].requirements.allowed_data_classes = ["public","bogus"]' "$RT" >"$T/rtd.json"
ok 'refuses rtd validate roles "$T/rtd.json" && [ "$(grep -c "^STL-CFG-310 " "$T/o")" = 1 ] && grep -q "qa-x" "$T/o" && grep -q "allowed_data_classes\[1\]" "$T/o" && ! grep -q bogus "$T/o"' "82 a data class the data policy does not define: validate roles refuses it, one STL-CFG-310 line naming it"
# R5: a role table under STELLA_ROOT is judged against that root's hook files, not the fixed stack root's
mk r5a; mkdir -p "$T/r5a/docs/hermes-local/hooks/qa"; cp "$ROOT/docs/hermes-local/hooks/default/deny-write.sh" "$T/r5a/docs/hermes-local/hooks/qa/only-here.sh"
ed r5a ../docs/hermes-local/roles.json ".roles[\"$R1\"].hooks += [{\"matcher\": \"^x\$\", \"file\": \"docs/hermes-local/hooks/qa/only-here.sh\"}]"
ok 'sd r5a validate roles "$T/r5a/docs/hermes-local/roles.json" >"$T/o" 2>&1 && sd r5a check >"$T/o" 2>&1' "83a a hook file that exists only under STELLA_ROOT is found there"
mk r5b; rm "$T/r5b/docs/hermes-local/hooks/default/deny-write.sh"
ok 'refuses r5b check && grep -q "deny-write.sh does not exist" "$T/o"' "83b a hook file missing under STELLA_ROOT is refused even when the stack root has it"
ok '! grep -q "stella_data" "$BIN/roles.py"' "83 bin/roles.py does not import stella_data (it runs inside guards)"
# ---- F1 W1 fix round 2 (QA round 2): P policy, M no leaks, L loader, I index, S schemas ----
V=sk-ant-api03-qafake0123456789abcdef   # lower case on purpose: it fits the id pattern
CM=$(jq -r '.entries[] | select(.id == "claude-subscription") | .models[0].id' "$ROOT/.stella/connections.json")
CHAIN="[{provider:\"claude-subscription\",model:\"$CM\",parameters:{}}]"
# P1 a chain entry's provider must allow every data class the role handles
mk p1a; ed p1a connections.json "(.entries[] | select(.id == \"claude-subscription\")).allowed_roles = $AR"; ed p1a role-assignments.json ".assignments[0].chain = $CHAIN"
ok 'refuses p1a check && grep -q "data class" "$T/o"' "84 a chain to a provider that allows none of the role's data classes is refused"
ed p1a connections.json '(.entries[] | select(.id == "claude-subscription")).data_policy.data_classes_allowed = ["public"]'
ok 'refuses p1a check' "85 a provider that allows only some of the role's data classes is refused"
ed p1a connections.json '(.entries[] | select(.id == "claude-subscription")).data_policy.data_classes_allowed = ["public","internal","client"]'
ok 'sd p1a check' "86 control: the provider allowing every class of the role passes"
# P2 locality is checked against data
mk p2a; ed p2a connections.json '(.entries[] | select(.id == "fallback-gateway")).locality = "local"'
ok 'refuses p2a check' "87 a provider declared local whose hosts include a host outside the local host list is refused"
mk p2b; ed p2b connections.json '(.entries[] | select(.id == "local-model-server")).hosts = []'
ok 'refuses p2b check' "88 a local provider with no host is refused"
mk p2c; ed p2c connections.json '(.entries[] | select(.id == "local-model-server")).hosts[0].host = "qa-box.example.invalid"'
ok 'refuses p2c check' "89 a local provider on a host outside the local host list is refused"
ed p2c data-policy.json '.local_hosts += ["qa-box.example.invalid"]'
ok 'sd p2c check' "90 the same host passes once the data policy lists it (the list is data)"
mk p2d; ed p2d data-policy.json 'del(.local_hosts)'
ok 'refuses p2d check' "91 a data policy with no local host list is refused"
# P3 effort-mode ids, P4 one card, one project
mk p3a; ed p3a role-assignments.json '.effort_modes["ｌocal_only"] = {allowed_localities:["local","cloud"],no_silent_fallback:false}'
ok 'refuses p3a check' "92 an effort-mode id outside the lower-case ASCII pattern is refused"
mk p4a; ed p4a data-policy.json '.projects["pa"] = {mode:"open",allowed_providers:[]} | .projects["pb"] = {mode:"open",allowed_providers:[]}'
ed p4a role-assignments.json '.assignments += [(.assignments[0] | .id = "ca" | .scope = {level:"card",project:"pa",card:"t1"}), (.assignments[0] | .id = "cb" | .scope = {level:"card",project:"pb",card:"t1"})]'
ok 'refuses p4a check' "93 one card id under two projects is refused"
ed p4a role-assignments.json '.assignments[-1].scope.card = "t2"'
ok 'sd p4a check' "94 control: two different cards under two projects pass"
# M1 a problem line never prints a value taken from the file under check (unless it is an id that exists in the data)
mk m1a; ed m1a role-assignments.json ".assignments[0].chain[0].model = \"$V\""
ok 'refuses m1a check && ! grep -q qafake "$T/o" && grep -q "chain" "$T/o"' "95 a pasted key in chain.model is not printed; the line names the field"
mk m1b; ed m1b role-assignments.json ".assignments[0].role = \"$V\""
ok 'refuses m1b check && ! grep -q qafake "$T/o"' "96 a pasted key in role is not printed"
mk m1c; ed m1c data-policy.json ".default.allowed_providers = [\"$V\"]"
ok 'refuses m1c check && ! grep -q qafake "$T/o"' "97 a pasted key in an allowed_providers entry is not printed"
mk m1d; ed m1d connections.json ".entries[0].data_policy.data_classes_allowed += [\"$V\"]"
ok 'refuses m1d check && ! grep -q qafake "$T/o"' "98 a pasted key in a data class list is not printed"
mk m1e; ed m1e capabilities.json ".entries[0].allowed_roles += [\"$V\"]"
ok 'refuses m1e check && ! grep -q qafake "$T/o"' "99 a pasted key in an allowed_roles entry is not printed"
mk m1f; ed m1f features.json ".entries[0].depends_on += [\"$V\"]"
ok 'refuses m1f check && ! grep -q qafake "$T/o"' "100 a pasted key in depends_on is not printed"
mk m1g; ed m1g role-assignments.json ".assignments[0].effort_mode = \"$V\""
ok 'refuses m1g check && ! grep -q qafake "$T/o"' "101 a pasted key as an effort mode is not printed"
mk m1h; ed m1h settings.json ".entries[0].store.data = \"$V\" | .entries[1].code = \"$V\""
ok 'refuses m1h check && ! grep -q qafake "$T/o"' "102 a pasted key as a settings store or code is not printed"
# M2 a key pasted into a free-form object is masked by every read (the row's redact_keys)
mk m2a; ed m2a role-assignments.json ".assignments[0].chain[0].parameters = {api_key:\"$V\"}"
ed m2a connections.json ".entries[0].cost = {token:\"$V\"} | .entries[0].limits = {secret:\"$V\"} | .entries[0].models[0].cost = {password:\"$V\"}"
ok 'sd m2a check >/dev/null 2>&1 && for c in "get role-assignments" "get role-assignments global-dispatcher" "get connections" "get connections local-model-server" "search qafake" "list connections" "list role-assignments"; do sd m2a $c >>"$T/m2" 2>&1 || exit 1; done; ! grep -q qafake "$T/m2"' "103 a key value in parameters, cost or limits (data check accepts) is masked by get, list and search"
mk m2b; ed m2b connections.json ".entries[0].tos.auth_key = \"$V\""   # tos is closed: refused, never masked (W1-VER4-06: its own root)
ok 'refuses m2b check && for c in "get connections" "get connections local-model-server" "search qafake" "list connections"; do sd m2b $c >>"$T/m2bo" 2>&1; done; ! grep -q qafake "$T/m2bo" "$T/o"' "103b a key pasted into the closed tos object is refused, and no read prints it"
ok '! { for d in $(jq -r ".files[] | select(.format == \"json\") | .id" "$ROOT/.stella/data-files.json"); do python3 -I "$SD" get $d; done 2>&1 | grep -q "\*\*\*"; }' "104 no field of the shipped data is masked by mistake"
# M3 redact_keys patterns compile; list and search mask like get
mk m3a; ed m3a data-files.json '(.files[] | select(.id == "capabilities")).redact_keys = ["("]'
ok 'refuses m3a check && grep -q "^STL-CFG-310 " "$T/o"' "105 a redact_keys pattern that does not compile is refused by check"
ok '(for c in "get capabilities" "list capabilities" "search a"; do refuses m3a $c && grep -q "^STL-CFG-310 " "$T/o" && ! grep -q Traceback "$T/o" || exit 1; done)' "106 get, list and search end in a catalog line on a bad redact_keys pattern"
mk m3b; ed m3b data-files.json '(.files[] | select(.id == "capabilities")).redact_keys = ["^summary$"]'
CID=$(jq -r '.entries[0].id' "$ROOT/.stella/capabilities.json"); ed m3b capabilities.json '.entries[0].summary = "qafake-summary"'
ok '! sd m3b get capabilities "$CID" | grep -q qafake && ! sd m3b list capabilities | grep -q qafake && ! sd m3b search "$CID" | grep -q qafake && ! sd m3b search "$CID" --json | grep -q qafake && ! sd m3b list capabilities --json | grep -q qafake' "107 get, list and search all mask a value under a redact_keys pattern"
# M4 a plain setting under a redacted store key
mk m4a; ed m4a settings.json '.entries += [{key:"QA_API_TOKEN",label:"x",type:"string",validation:{},scope:"global",sensitivity:"identity_critical",default:"qa-plain-value",store:{data:"owner-settings",key:"QA_API_TOKEN"},apply:{script:"bin/stella-apply.py",needs_restart:false},code:"STL-CFG-315"}]'
ok 'refuses m4a check && refuses m4a get settings QA_API_TOKEN && ! grep -q qa-plain-value "$T/o"' "108 a non-secret setting stored under a redacted key is refused, and get does not show its default"
# L loader and linter
mk l1a; sed -i '0,/"cost": null/s//"cost": {"a": 1e400}/' "$T/l1a/.stella/connections.json"
ok 'grep -q 1e400 "$T/l1a/.stella/connections.json" && refuses l1a check && grep -q "^STL-CFG-310 " "$T/o"' "109 a number that does not fit a float is refused at load"
mk l2a; sed -i '0,/"label": "[^"]*"/s//"label": "x\\ud800"/' "$T/l2a/.stella/connections.json"
ok 'grep -q ud800 "$T/l2a/.stella/connections.json" && refuses l2a check && refuses l2a get connections && grep -q "^STL-CFG-310 " "$T/o" && refuses l2a list connections && refuses l2a search a && ! grep -q Traceback "$T/o"' "110 a lone surrogate is refused at load; no command ends in a traceback"
mkdir -p "$T/l2b/bin" "$T/l2b/docs/hermes-local"; cp "$BIN/alert_catalog.py" "$T/l2b/bin/"; cp "$ROOT/docs/hermes-local/alert-catalog.json" "$T/l2b/docs/hermes-local/"
sed 's/^def rows():/def rows():\n    raise KeyError("qafake")/' "$SD" >"$T/l2b/bin/stella_data.py"; mk l2c
ok '! STELLA_ROOT=$T/l2c python3 -I "$T/l2b/bin/stella_data.py" list >"$T/o" 2>&1; grep -q "^STL-CFG-310 .*KeyError" "$T/o" && ! grep -q "Traceback\|qafake" "$T/o"' "111 an unexpected exception becomes exit 1 and one STL-CFG-310 line naming the type, never the value"
mk l4a; python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); x={}
for i in range(300): x={'a':x}
d['entries'][0]['cost']=x; json.dump(d,open(sys.argv[1],'w'))" "$T/l4a/.stella/connections.json"
sd l4a check >/dev/null 2>&1; c1=$?; sd l4a get connections >/dev/null 2>&1; c2=$?
ok '[ $c1 = 1 ] && [ $c2 = 1 ]' "112 check and get both refuse a deeply nested object"
mk l5a; echo '{"schema_version":1,"entries":[{"id":"z1"}]}' >"$T/l5a/.stella/zz.json"
ed l5a data-files.json '.files += [{id:"zz-ns",path:".stella/zz.json",schema:null,format:"json",owner_only:true,redact_keys:[],list_key:"entries",id_field:"id"}]'
ok 'refuses l5a check && refuses l5a get zz-ns && refuses l5a list zz-ns && refuses l5a search z1 && refuses l5a list' "113 a JSON row with no schema is refused by check and served by no read command"
mk l6a; echo '{"$defs":{"a/b":{"type":"string"}},"$ref":"#/$defs/a/b"}' >"$T/l6a/.stella/schemas/zz.schema.json"; echo '"x"' >"$T/d5"
echo '{"$defs":{"a":{"$ref":"#/$defs/a"}},"$ref":"#/$defs/a"}' >"$T/l6a/.stella/schemas/zz2.schema.json"
ok 'refuses l6a validate zz "$T/d5" && ! grep -q Traceback "$T/o" && refuses l6a validate zz2 "$T/d5" && grep -qi schema "$T/o" && ! grep -qi "nested too deeply" "$T/o"' "114 a \$defs name with a slash and a \$ref loop are schema errors, not data errors or a traceback"
# I the index
mk i1a; ed i1a data-files.json '(.files[] | select(.id == "connections")).schema = "extension"'
ok 'refuses i1a check data-files' "115 check <the index id> reports the problems a full check reports"
mk i2a; ed i2a data-files.json '(.files[] | select(.id == "role-assignments")).id = "ra-renamed"'
ed i2a role-assignments.json '.assignments[0].chain[0].model = "no-such-model"'
ok 'refuses i2a check' "116 a renamed index row does not switch the role-assignment rules off"
mk i2b; ed i2b data-files.json '(.files[] | select(.id == "role-assignments")).format = "env"'
ok 'refuses i2b check && grep -qi "could not run" "$T/o"' "117 a file a rule needs that has no JSON row: check says the rule could not run"
mk i2c; ed i2c data-files.json '.files |= map(select(.id != "connections"))'
ok 'refuses i2c check && grep -qi "could not run" "$T/o"' "118 the same when the row is missing"
mk i3a; ed i3a data-files.json '(.files[] | select(.id == "data-files")).owner_only = false'
ok 'refuses i3a check' "119 the index row of the index must be owner-only"
mk i4a; cp "$T/fake/.stella/extensions/fake-ext.json" "$T/i4a/.stella/extensions/"; ln -s "$T/i4a" "$T/i4link"
ok 'STELLA_ROOT=$T/i4link python3 -I "$SD" check >/dev/null 2>&1 && STELLA_ROOT=$T/i4link python3 -I "$SD" list extensions >/dev/null 2>&1' "120 a root reached through a symlink works"
ok '[ "$(STELLA_ROOT=/ python3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); import stella_data as s; print(s.safe(\"etc/hostname\"))" "$BIN")" = /etc/hostname ]' "121 a root of / works"
# S schemas and entries
mk s1a; ed s1a connections.json '(.entries[] | select(.id == "claude-subscription")).tos.zz_extra = "x"'
ok 'refuses s1a check' "122 tos accepts no unknown key"
mk s1b; ed s1b connections.json 'del((.entries[] | select(.id == "claude-subscription")).tos.subscription_login_by_agent)'
ok 'refuses s1b check' "123 tos.subscription_login_by_agent is required"
mk s1c; ed s1c connections.json 'del((.entries[] | select(.id == "claude-subscription")).allowed_roles)'
ok 'refuses s1c check' "124 allowed_roles is required on a provider"
mk s1d; ed s1d connections.json 'del((.entries[] | select(.id == "discord")).risk_class)'
ok 'refuses s1d check' "125 risk_class is required on a channel"
ok 'jq -e "[.entries[] | select(.kind == \"channel\") | (.scopes | length > 0) and (.redaction_patterns | length > 0)] | all" "$ROOT/.stella/connections.json" >/dev/null' "126 the shipped channel states its scopes and redaction patterns"
mk s2a; echo "{\"schema_version\":1,\"hosts\":[$(row '*.com' 443 g o 2026-11-10T00:00:00Z null)]}" >"$T/s2a/.stella/approved-hosts.json"
ok 'refuses s2a check' "127 a wildcard host with one label after it is refused"
echo "{\"schema_version\":1,\"hosts\":[$(row '*.example.com' 443 g o 2026-11-10T00:00:00Z null)]}" >"$T/s2a/.stella/approved-hosts.json"
ok 'sd s2a check' "128 a wildcard host with two labels after it passes"
echo "{\"schema_version\":1,\"hosts\":[$(row a.example.com 443 g o 2026-13-45T00:00:00Z null)]}" >"$T/s2a/.stella/approved-hosts.json"
ok 'refuses s2a check' "129 an approved_at that is not a real date is refused"
echo "{\"schema_version\":1,\"hosts\":[$(row a.example.com 443 g o 2026-11-10T00:00:00Z '"2026-02-30T00:00:00Z"')]}" >"$T/s2a/.stella/approved-hosts.json"
ok 'refuses s2a check' "130 an expires_at that is not a real date is refused"
echo "{\"schema_version\":1,\"hosts\":[$(row a.example.com 443 g o 2026-11-10T00:00:00Z '"2026-11-09T00:00:00Z"')]}" >"$T/s2a/.stella/approved-hosts.json"
ok 'refuses s2a check' "131 an expiry before the approval is refused"
# S3 a known env row gets its own code and text
ok 'refuses fake get owner-settings && ! grep -qi "not in Stella.s data files" "$T/o" && grep -q "^STL-CFG-319 " "$T/o"' "132 get on an env row answers with its own catalog code, not the unknown-name text"
# ---- F1 W1 fix round 4 (QA round 3): A every required field is enforced, B every file a row names is judged, C a read never
# serves what check refuses, D the small ones ----
LMS='(.entries[] | select(.id == "local-model-server"))'
# A a provider's allowed_roles against the assignments that name it
mk a1; ed a1 connections.json "$LMS.allowed_roles = [\"dispatcher\"]"
ok 'refuses a1 check && grep -q "^STL-CFG-310 .*global-builder: chain\[0\].*allowed_roles" "$T/o" && ! grep -q "global-dispatcher" "$T/o"' "133 a chain to a provider whose allowed_roles leaves the role out is refused; the role it lists passes"
ed a1 connections.json "$LMS.allowed_roles = []"
ok 'refuses a1 check && grep -q "global-dispatcher: chain\[0\].*allowed_roles" "$T/o"' "134 a provider with allowed_roles [] allows no role"
# B every file of every row of a schema gets every rule of that schema
mk b1; jq '.assignments |= map(.id += "-2")' "$T/b1/.stella/role-assignments.json" >"$T/b1/.stella/ra2.json"
ed b1 data-files.json '.files += [{id:"ra2",path:".stella/ra2.json",schema:"role-assignments",format:"json",owner_only:true,redact_keys:[],list_key:"assignments",id_field:"id"}]'
ok 'refuses b1 check && grep -q "ra2: .*one document" "$T/o" && refuses b1 get ra2' "135 a schema the data marks one document (x-one-document) refuses a second file in another row"
mk b2; mkdir "$T/b2/.stella/dp"; mv "$T/b2/.stella/data-policy.json" "$T/b2/.stella/dp/a.json"; cp "$T/b2/.stella/dp/a.json" "$T/b2/.stella/dp/b.json"
ed b2 data-files.json '(.files[] | select(.id == "data-policy")).path = ".stella/dp"'
ok 'refuses b2 check && grep -q "dp/b.json: .*one document" "$T/o"' "136 the same for the second file of a folder row"
mk b2c; jq '."x-one-document" = "yes"' "$T/b2c/.stella/schemas/features.schema.json" >"$T/b2c/s" && mv "$T/b2c/s" "$T/b2c/.stella/schemas/features.schema.json"
ok 'refuses b2c check && grep -q "x-one-document" "$T/o"' "137 x-one-document takes only true or false"
mk b3; jq -n "{schema_version:1,entries:[$(conn two-prov provider hosted cloud)]}" >"$T/b3/.stella/conn2.json"
ed b3 data-files.json '.files += [{id:"conn2",path:".stella/conn2.json",schema:"connections",format:"json",owner_only:true,redact_keys:[],list_key:"entries",id_field:"id"}]'
ed b3 role-assignments.json '.assignments[0].chain = [{provider:"two-prov",model:"two-prov-model",parameters:{}}]'
ok 'sd b3 check >"$T/o" 2>&1 && [ "$(sd b3 get conn2 two-prov --json | jq -r .id)" = two-prov ]' "138 control: a second connections row is one catalog with the first; an assignment may name its provider"
ed b3 conn2.json '.entries[0].data_policy.data_classes_allowed += ["no-such-class"]'
ok 'refuses b3 check && grep -q "conn2: two-prov: data_classes_allowed" "$T/o" && refuses b3 get conn2 two-prov && grep -q "^STL-CFG-310 " "$T/o"' "139 the cross-file rules judge the entries of the second row, and get refuses them"
ed b3 conn2.json '.entries[0].data_policy.data_classes_allowed -= ["no-such-class"] | .entries += [.entries[0] | .id = "local-model-server"]'
ok 'refuses b3 check && grep -q "conn2: .*duplicate entry id .local-model-server., also in .stella/connections.json" "$T/o" && refuses b3 get conn2' "140 one entry id in two rows of one schema is refused, and the later row is not served"
mk b4; ed b4 data-files.json '(.files[] | select(.id == "settings")).schema = "./settings"'
ok 'refuses b4 check && grep -q "^STL-CFG-310 .*schema" "$T/o" && refuses b4 get settings' "141 the index schema field is a plain name: ./settings is refused"
mk b5; ed b5 data-files.json '.files += [(.files[] | select(.id == "data-policy") | .id = "dp-alias" | .path = "./.stella/data-policy.json" | .owner_only = false)]'
ok 'refuses b5 check && grep -q "more than one index row" "$T/o" && refuses b5 get dp-alias && refuses b5 get data-policy' "142 two rows that resolve to one file are refused, and neither is served"
mk b6; mkdir -p "$T/b6/.supervisor"; printf 'QA_FAKE=qafake-env\n' >"$T/b6/.supervisor/limits.env"; chmod 000 "$T/b6/.supervisor/limits.env"
ed b6 data-files.json '.files += [{id:"lim-json",path:"./.supervisor/limits.env",schema:"versions",format:"json",owner_only:true,redact_keys:[],list_key:"pins",id_field:"id"}]'
ok 'refuses b6 check && grep -q "more than one index row" "$T/o" && ! grep -qi "expecting\|cannot be read\|qafake" "$T/o"' "143 a JSON row on an env row's file is refused and the file is never opened"
OS=$(jq -r '.owner_settings[0]' "$ROOT/docs/hermes-local/roles.json")
mk b7; mkdir -p "$T/b7/$(dirname "$OS")"; printf 'QA_FAKE=qafake-owner\n' >"$T/b7/$OS"; chmod 000 "$T/b7/$OS"
ed b7 data-files.json "(.files[] | select(.path == \"$OS\")) |= (.format = \"json\" | .schema = \"versions\" | .list_key = \"pins\" | .id_field = \"id\")"
ok 'refuses b7 check && grep -q "owner setting of the role table" "$T/o" && ! grep -qi "expecting\|cannot be read\|qafake" "$T/o"' "144 a row on an owner setting of the role table that is not an env row is refused, and the file is never opened"
ed b7 data-files.json "(.files[] | select(.path == \"$OS\")) |= (.format = \"env\" | .schema = null | .list_key = null | .id_field = \"key\" | .owner_only = false)"
ok 'refuses b7 check && grep -q "owner setting of the role table" "$T/o"' "145 the same for an env row that is not owner_only"
# C a read runs the rules check runs on the files it serves
mk c1; ed c1 role-assignments.json ".assignments[0].chain[0].model = \"$V\""
ok '(for c in "get role-assignments" "get role-assignments global-dispatcher" "get --json role-assignments" "list role-assignments" "search qafake" "list"; do refuses c1 $c && grep -q "^STL-CFG-310 " "$T/o" && ! grep -q qafake "$T/o" || exit 1; done)' "146 get, list and search refuse a file check refuses on a cross-file rule, printing no data"
ok 'sd c1 get versions >/dev/null 2>&1 && sd c1 list capabilities >/dev/null 2>&1' "147 control: a file with no problem of its own is still served while another file has one"
# D value patterns (the catalog's redaction_patterns) mask every read and every key name a problem line would print
VP='(.entries[] | select(.kind == "channel")).redaction_patterns += ["qafake0[a-z0-9]+"]'
mk vp1; ed vp1 connections.json "$VP | $LMS.limits = {bearer:\"qafake0limit\"}"
ed vp1 role-assignments.json '.assignments[0].chain[0].parameters = {auth:"qafake0auth", headers:["X-Auth qafake0header"], deep:[{a:["qafake0deep"]}]}'
ok 'sd vp1 check >/dev/null 2>&1 && { for c in "get role-assignments" "get role-assignments global-dispatcher" "get --json connections" "get connections local-model-server" "list role-assignments" "search qafake0auth" "search --json qafake0"; do sd vp1 $c; done >"$T/o" 2>&1; ! grep -Eq "qafake0(limit|auth|header|deep)" "$T/o"; } && sd vp1 get role-assignments global-dispatcher | grep -q "\*\*\*" && [ "$(sd vp1 search qafake0auth)" = "" ]' "148 a value a catalog redaction pattern matches is masked by every read, inside lists too, and search does not answer for it"
mk vp2; ed vp2 connections.json "$VP | $LMS.tos.qafake0key = true | $LMS.tos.zz_plain = true"; ed vp2 role-assignments.json '.effort_modes.qafake0mode = 1'
ok 'refuses vp2 check && ! grep -q "qafake0" "$T/o" && grep -q "a masked key" "$T/o" && grep -q "zz_plain" "$T/o"' "149 a key name a value pattern matches is not printed (a masked key at its path); other key names are"
mk vp3; ed vp3 connections.json "$VP"; printf '{"schema_version":1,"entries":[],"qafake0dup":1,"qafake0dup":2}' >"$T/vp3/.stella/capabilities.json"
ok 'refuses vp3 check && grep -q "repeated key" "$T/o" && ! grep -q qafake0 "$T/o" && refuses vp3 get capabilities && ! grep -q qafake0 "$T/o"' "150 a repeated key a value pattern matches is not printed by check or get"
mk vp4; sed -i '0,/"parameters": {}/s//"parameters": {"t": 1e-400}/' "$T/vp4/.stella/role-assignments.json"
ok 'grep -q 1e-400 "$T/vp4/.stella/role-assignments.json" && refuses vp4 check && grep -q "^STL-CFG-310 " "$T/o" && refuses vp4 get role-assignments' "151 a non-zero number that reads as zero is refused"
mk vp5; sed -i '0,/"parameters": {}/s//"parameters": {"t": 0.0, "u": 0e5, "v": -0.0, "w": 5e-324}/' "$T/vp5/.stella/role-assignments.json"
ok 'grep -q 0e5 "$T/vp5/.stella/role-assignments.json" && sd vp5 check >/dev/null' "152 control: zero written as zero, and the smallest double, load"
mk vp6; ed vp6 connections.json "$LMS |= (.cost = {token:\"qafake-c\"} | .limits = {secret:\"qafake-l\"} | .models[0].cost = {password:\"qafake-m\"})"
ok 'sd vp6 check >/dev/null 2>&1 && sd vp6 get --json connections local-model-server >"$T/o" && ! grep -q qafake "$T/o" && [ "$(jq "[.cost.token, .limits.secret, .models[0].cost.password] | map(select(. == \"***\")) | length" "$T/o")" = 3 ]' "153 a connections entry that passes check shows *** for a secret-named key in cost, limits and a model's cost"
ok 'refuses fake validate event <(jq "del(.time)" "$T/ev.json") && grep -q "^STL-CFG-310 " "$T/o" && ! grep -qv "^STL-CFG-310 " "$T/o"' "154 validate prints every problem as a STL-CFG-310 line, for any schema"
# ---- F1 W1 fix round 5 (QA round 4): S1 a read is judged by exactly the files its rules use, S2 bounded time, S3 the small ones ----
ms() { local t0=$(date +%s%N); timeout 20 env STELLA_ROOT="$T/$1" python3 -I "$SD" "${@:2}" >"$T/o" 2>&1; rc=$?; el=$(( ($(date +%s%N) - t0) / 1000000 )); }
# S1 one-document conflict: every row of the schema is refused, whatever the row order (red team d1, c2)
QCB='.assignments += [{id:"qa-cloud-builder",scope:{level:"global"},role:"builder",effort_mode:"max",chain:[{provider:"claude-subscription",model:"sonnet",parameters:{}}]}]'
mk pd1; ed pd1 connections.json "$OPEN"; ed pd1 role-assignments.json "$QCB"
ok 'sd pd1 check >"$T/o" 2>&1 && sd pd1 get role-assignments qa-cloud-builder >/dev/null 2>&1' "155 control: a max-mode cloud assignment under the open shipped policy passes check and is served"
ed pd1 data-policy.json '.default.mode = "local_only"'
ok 'refuses pd1 get role-assignments qa-cloud-builder' "156 control: the same assignment under a local_only policy is refused"
jq '.default.mode = "open"' "$T/pd1/.stella/data-policy.json" >"$T/pd1/.stella/dp0.json"
for at in 0 1; do
  cp -r "$T/pd1" "$T/pd1-$at"; ed pd1-$at data-files.json "(.files | map(.id) | index(\"data-policy\")) as \$i | .files |= .[:\$i+$at] + [(.[\$i] | .id = \"dp0\" | .path = \".stella/dp0.json\")] + .[\$i+$at:]"
  ok 'refuses pd1-'$at' check && grep -q "^STL-CFG-310 .*dp0: .*one document" "$T/o" && grep -q "^STL-CFG-310 .*data-policy: .*one document" "$T/o" && refuses pd1-'$at' get role-assignments qa-cloud-builder && grep -q "data-policy\|dp0" "$T/o" && ! grep -q "data-files" "$T/o" && refuses pd1-'$at' get role-assignments && refuses pd1-'$at' get data-policy && refuses pd1-'$at' get dp0' "157.$at a second data-policy row (placed $([ $at = 0 ] && echo before || echo after) the shipped one): both rows are refused, and the assignments judged against the policy are not served"
done
# S1 a file that fails its schema never feeds a rule (red team d2)
mk pd2; ed pd2 connections.json "$LMS.enabled = \"false\""
ok 'refuses pd2 check && grep -q "connections: .*enabled" "$T/o" && refuses pd2 get role-assignments global-builder && grep -q "connections" "$T/o" && ! grep -q "data-files" "$T/o"' "158 a provider whose enabled is the string \"false\" (schema-invalid) feeds no rule: the chain to it is not served, the refusal names connections"
ok 'sd pd2 get --json settings CALL_TIMEOUT | jq -e ".default | type == \"number\"" >/dev/null && sd pd2 get versions >/dev/null 2>&1 && sd pd2 get capabilities >/dev/null 2>&1' "159 control: reads whose rules do not read the connections catalog are still served"
# S1 the validator's three variants: a bad field in one file stops only the reads that depend on it
mk v1; ed v1 capabilities.json '.entries[0].allowed_roles = null'
ok 'refuses v1 check && grep -q "^STL-CFG-310 .*capabilities: " "$T/o" && ! grep -q "data-files" "$T/o"' "160 a null allowed_roles in the capability registry: check names capabilities, not the index"
ok 'sd v1 get --json settings CALL_TIMEOUT | jq -e ".default == 600 and .validation.minimum == 1" >/dev/null && sd v1 get versions >/dev/null 2>&1 && sd v1 get --json connections >/dev/null 2>&1 && sd v1 get role-assignments >/dev/null 2>&1' "161 the same broken capability registry (a file a card branch may change): get --json settings, versions, connections and role-assignments are served"
ok 'refuses v1 get capabilities && grep -q "^STL-CFG-310 .*capabilities: " "$T/o" && refuses v1 search stella && refuses v1 list' "162 control: the broken registry itself, search and list (which serve it) are refused, naming capabilities"
mk v2; ed v2 features.json 'del(.entries[0].depends_on)'
ok 'refuses v2 check && grep -q "features: .*missing depends_on" "$T/o" && ! grep -q "data-files" "$T/o" && sd v2 get --json settings CALL_TIMEOUT >/dev/null 2>&1 && sd v2 get versions >/dev/null 2>&1 && sd v2 get --json connections >/dev/null 2>&1 && refuses v2 get features' "163 a feature without depends_on: features is refused, settings, versions and connections are served"
mk v3; head -c 200 "$ROOT/.stella/connections.json" >"$T/v3/.stella/connections.json"
ok 'refuses v3 check && grep -q "connections" "$T/o" && sd v3 get --json settings CALL_TIMEOUT >"$T/o" 2>&1 && jq -e ".default == 600 and .validation.maximum > 0 and .key == \"***\"" "$T/o" >/dev/null && sd v3 get versions | jq -e "[.. | strings] - [\"***\"] == []" >/dev/null' "164 a truncated connections catalog: the settings read is served with every string masked (the patterns cannot be read), numbers intact"
ok 'refuses v3 get role-assignments && grep -q "connections" "$T/o" && sd fake get --json settings CALL_TIMEOUT | jq -e ".key == \"CALL_TIMEOUT\"" >/dev/null' "165 control: reads that depend on the catalog are refused; with a readable catalog the same string is shown"
# S1 a rule that raises is a problem of the rows it read, never of the index
mkdir -p "$T/l3/bin"; cp "$BIN/alert_catalog.py" "$BIN/roles.py" "$T/l3/bin/"; cp -r "$T/l2b/docs" "$T/l3/"
sed 's/^def rule_features(\(.*\)):$/def rule_features(\1):\n    raise KeyError("qafake")/' "$SD" >"$T/l3/bin/stella_data.py"; mk l3r
ok 'grep -q "raise KeyError(\"qafake\")" "$T/l3/bin/stella_data.py" && ! STELLA_ROOT=$T/l3r python3 -I "$T/l3/bin/stella_data.py" check >"$T/o" 2>&1 && grep -q "^STL-CFG-310 .*features: .*KeyError" "$T/o" && ! grep -q "data-files\|qafake" "$T/o" && STELLA_ROOT=$T/l3r python3 -I "$T/l3/bin/stella_data.py" get --json settings CALL_TIMEOUT >/dev/null 2>&1 && ! STELLA_ROOT=$T/l3r python3 -I "$T/l3/bin/stella_data.py" get features >/dev/null 2>&1' "166 a cross-file rule that raises is one line naming the rows it read; reads outside them are served"
# S2 bounded time on data a card branch may write; owner data longer than the limit is masked whole
mk q1; ed q1 capabilities.json '.entries += [.entries[0] | .id = "qa-long" | .summary = ("a" * 200000)]'
ms q1 check; ok '[ $rc = 1 ] && [ $el -lt 1000 ] && grep -q "summary: length 200000" "$T/o"' "167 a 200000-character summary in the capability registry is refused by its schema ($el ms)"
for c in "get capabilities qa-long" "search qa-long" "list capabilities"; do ms q1 $c; ok '[ $rc = 1 ] && grep -q "^STL-CFG-310 " "$T/o" && [ $el -lt 1000 ]' "168 $c answers within a second (refused, coded; $el ms)"; done
mk q2; ed q2 capabilities.json '.entries += [.entries[0] | .id = "qa-long" | .keywords = [range(10) | ("b" * 60000) + tostring]]'
ms q2 search qa-long; ok '[ $rc = 1 ] && [ $el -lt 1000 ]' "169 search over ten keywords of 60000 characters answers within a second ($el ms)"
mk q3; ed q3 role-assignments.json '(.assignments[] | select(.id == "global-builder")).chain[0].parameters = {long: ("c" * 200000), near: ("d" * 1000)}'
ms q3 get --json role-assignments global-builder; ok '[ $rc = 0 ] && [ $el -lt 1000 ] && jq -e ".chain[0].parameters.long == \"***\" and (.chain[0].parameters.near | length) == 1000" "$T/o" >/dev/null' "170 owner data: a string over the masking limit is masked whole without a pattern run, a shorter one is matched and shown ($el ms)"
# S3 RT4-03 folder rows are listed by name, never as a glob
BADEXT='{"schema_version":1,"qa_not_an_extension":true}'
mk g9; mkdir "$T/g9/.stella/ext[1]"; echo "$BADEXT" >"$T/g9/.stella/ext[1]/bad.json"; mkdir "$T/g9/.stella/ext1"; cp "$T/fake/.stella/extensions/fake-ext.json" "$T/g9/.stella/ext1/"
ed g9 data-files.json '.files += [(.files[] | select(.id == "extensions") | .id = "qa-ext" | .path = ".stella/ext[1]")]'
ok 'refuses g9 check && grep -q "ext\[1\]/bad.json" "$T/o" && refuses g9 get qa-ext && ! grep -q fake-ext "$T/o"' "171 a folder row named with [ ] is read by its name: its own bad file is refused, a folder it would match as a glob is never read"
mk "h[1]"; echo "$BADEXT" >"$T/h[1]/.stella/extensions/bad.json"
ok 'refuses "h[1]" check && grep -q "extensions/bad.json" "$T/o"' "172 a stack root whose path holds [1]: a bad file in a folder row is still judged"
# S3 RT4-04, RT4-05 the owner settings file is never opened: hard link, swapped link, validate by path, validate roles
mk o1; mkdir -p "$T/o1/$(dirname "$OS")"; printf '{"QA_FAKE_OWNER_KEY": 1}\n' >"$T/o1/$OS"; chmod 000 "$T/o1/$OS"
ln "$T/o1/$OS" "$T/o1/.stella/extensions/qa.json"
ok 'refuses o1 check && grep -q "qa.json: .*owner setting" "$T/o" && ! grep -qi "PermissionError\|QA_FAKE_OWNER_KEY" "$T/o"' "173 a hard link to the owner settings file is refused by its identity and never opened"
rm "$T/o1/.stella/extensions/qa.json"
ok 'refuses o1 validate settings "$T/o1/$OS" && grep -q "owner setting" "$T/o" && ! grep -qi "PermissionError\|QA_FAKE" "$T/o"' "174 validate refuses a path that is the owner settings file, without opening it"
mk o2; mkdir -p "$T/o2/$(dirname "$OS")"; printf '{"QA_FAKE_OWNER_KEY": 1}\n' >"$T/o2/$OS"; chmod 000 "$T/o2/$OS"; ed o2 data-files.json "(.files[] | select(.id == \"data-policy\")).path = \"$OS\""
ok 'refuses o2 validate roles "$RT" && ! grep -qi "PermissionError\|QA_FAKE" "$T/o"' "175 validate roles never opens the owner file the data-policy row was pointed at"
mk o3; ed o3 data-files.json '(.files[] | select(.id == "data-policy")).id = "qa-dp"'
ok 'sd o3 validate roles "$RT" >"$T/o" 2>&1 && grep -qx valid "$T/o" && refuses o3 validate roles "$T/rtd.json" && grep -q "allowed_data_classes\[1\]" "$T/o"' "176 validate roles finds the data policy by its schema, not by a row id"
chmod 644 "$T/o1/$OS"; echo '{"schema_version":1,"qa_plain":true}' >"$T/o1/docs/qa-plain.json"; ln -s "../../$OS" "$T/o1/.stella/extensions/qa.json"
python3 -I -c "
import os,sys
l, t = sys.argv[1], sys.argv[1] + '.tmp'
while True:
    for a in sys.argv[2:]:
        try: os.remove(t)
        except FileNotFoundError: pass
        os.symlink(a, t); os.replace(t, l)" "$T/o1/.stella/extensions/qa.json" ../../docs/qa-plain.json "../../$OS" & SW=$!
hits=0; for i in $(seq 60); do sd o1 check 2>&1 | grep -q QA_FAKE_OWNER_KEY && hits=$((hits+1)); done; kill $SW; wait $SW 2>/dev/null; SW=
ok '[ $hits = 0 ]' "177 a link swapped between a plain file and the owner settings file while check runs: the owner file is never read (0 of 60 runs; $hits)"
# S3 RT4-02 a schema file that is a symbolic link is refused
mk sa; ln -s role-assignments.schema.json "$T/sa/.stella/schemas/ra2.schema.json"; jq '.assignments |= map(.id += "-2")' "$T/sa/.stella/role-assignments.json" >"$T/sa/.stella/ra2.json"
ed sa data-files.json '.files += [(.files[] | select(.id == "role-assignments") | .id = "ra2" | .path = ".stella/ra2.json" | .schema = "ra2")]'
ok 'refuses sa check && grep -q "ra2.schema.json: .*symbolic link" "$T/o" && refuses sa get ra2' "178 a schema file that is a symbolic link is refused, and its rows are not served"
# S3 RT4-07, VER4-04 ids and free-form key names a value pattern matches are masked by every read and every check line
QID=qafake0rt5aaaaaaaaaaaaaaaa.bbbbbb.ccccccccccccccccccccccccccccc; QTOK=qafakeTOKEN0rt5notreal9x
mk k1; ed k1 role-assignments.json "(.assignments[] | select(.id == \"global-builder\")).chain[0].parameters = {\"Bearer $QTOK\": \"qa\", plain_key: 1}"
ed k1 capabilities.json ".entries += [.entries[0] | .id = \"$QID\"]"
ok 'sd k1 check >/dev/null 2>&1 && sd k1 get --json role-assignments global-builder >"$T/o" 2>&1 && ! grep -q "$QTOK" "$T/o" && grep -q plain_key "$T/o" && jq -e ".chain[0].parameters[\"***\"] == \"qa\"" "$T/o" >/dev/null' "179 a free-form key name a value pattern matches is masked by get --json; other key names are shown"
ok '{ sd k1 list capabilities; sd k1 list capabilities --json; sd k1 search qafake0rt5; sd k1 search --json qafake0rt5; sd k1 get --json role-assignments; } >"$T/o" 2>&1; ! grep -q "$QID\|$QTOK" "$T/o" && sd k1 get --json capabilities "$QID" | jq -e ".id == \"***\"" >/dev/null' "180 an entry id a value pattern matches is masked by list, search and get"
mk k2; ext() { echo "{\"schema_version\":1,\"id\":\"$1\",\"kind\":\"skill\",\"summary\":\"qa\",\"hosts\":[],\"secrets\":[],\"tools\":[],\"allowed_roles\":[],\"risk_class\":\"read\",\"enabled\":$2,\"status\":\"proposed\",\"source\":\"qa\"}"; }
ext "$QID" true >"$T/k2/.stella/extensions/a.json"; ext "$QID" false >"$T/k2/.stella/extensions/b.json"
ok 'refuses k2 check && grep -q "duplicate entry id" "$T/o" && grep -q "switched on" "$T/o" && ! grep -q "$QID" "$T/o"' "181 check lines print no entry id a value pattern matches (duplicate id, switched on)"
# S3 VAL4-03 settings, features and versions are one document each
for s in settings features versions; do
  mk od-$s; cp "$T/od-$s/.stella/$s.json" "$T/od-$s/.stella/$s-2.json"
  ed od-$s data-files.json "(.files[] | select(.schema == \"$s\")) as \$r | .files += [\$r | .id = \"qa-$s-2\" | .path = \".stella/$s-2.json\"]"
  ok 'refuses od-'$s' check && grep -q "qa-'$s'-2: .*one document" "$T/o" && refuses od-'$s' get qa-'$s'-2' "182 $s is one document: a second $s row is refused"
done
# S3 VAL4-04, VER4-03 two rows on one file: each is refused with the reason, naming both
ok 'refuses b5 get data-policy && grep -q "data-policy: .*more than one index row (.*data-policy.*dp-alias" "$T/o"' "183 the first of two rows on one file is refused with the reason, naming both rows"
# S3 VER4-09 a load error prints the file path once
ok 'refuses g1d check && [ "$(grep "repeated" "$T/o" | grep -o "\.stella/data-policy\.json" | wc -l)" = 1 ]' "184 a load error prints the file path once"
# ---- F1 W1 fix round 6 (QA round 5): K1 a linked row is charged alone, K2 one rule for what a row is, K3 the small ones ----
OS=$(jq -r '.owner_settings[0]' "$ROOT/docs/hermes-local/roles.json")
setting() { [ "$(sd "$1" get --json settings CALL_TIMEOUT 2>/dev/null | jq -r '.default | type')" = number ]; }   # the read bin/escalate.sh makes
alone() { refuses "$1" check && grep -q "^STL-CFG-310 .*$2: .*$3" "$T/o" && [ "$(grep -c "^STL-CFG-310 " "$T/o")" = 1 ]; }   # <root> <row> <text>: check has that one line, charged to that row
# K1 a JSON row that is, or goes through, a symbolic link is refused alone: no other row gets a line or is closed (W1-RT5-01)
mk k1a; ln -sf settings.json "$T/k1a/.stella/capabilities.json"
ok 'alone k1a capabilities "\.stella/capabilities\.json.*must not be a symbolic link" && setting k1a && sd k1a get settings >/dev/null 2>&1 && refuses k1a get capabilities' "185 a row linked to another row's file: only the linking row is refused; the settings read is served"
mk k1b; ln -sf data-files.json "$T/k1b/.stella/capabilities.json"
ok 'alone k1b capabilities "must not be a symbolic link" && setting k1b && sd k1b get --json connections >/dev/null 2>&1 && sd k1b get data-files >/dev/null 2>&1' "186 a row linked to the index: only the linking row is refused; the settings read, the catalog and the index are served"
mk k1c; rm "$T/k1c/.stella/capabilities.json"; ln -s . "$T/k1c/.stella/capabilities.json"
ok 'alone k1c capabilities "must not be a symbolic link" && setting k1c && sd k1c get versions >/dev/null 2>&1' "187 a row linked to a folder: only the linking row is refused"
mk k1d; ln -s ../capabilities.json "$T/k1d/.stella/extensions/x.json"
ok 'alone k1d extensions "\.stella/extensions/x\.json.*must not be a symbolic link" && setting k1d && sd k1d get capabilities >/dev/null 2>&1 && refuses k1d get extensions' "188 a link inside a folder row: the folder row is refused, the row whose file it points to is served"
mk k1e; mkdir "$T/k1e/.stella/real"; mv "$T/k1e/.stella/versions.json" "$T/k1e/.stella/real/"; ln -s real "$T/k1e/.stella/vl"; ed k1e data-files.json '(.files[] | select(.id == "versions")).path = ".stella/vl/versions.json"'
ok 'alone k1e versions "\.stella/vl .*must not be a symbolic link" && setting k1e && refuses k1e get versions' "189 a link in a parent folder below the root: the row is refused, the line names the linked folder"
mk k1f; mkdir -p "$T/k1f/$(dirname "$OS")"; printf '{"QA_FAKE_OWNER_KEY": 1}\n' >"$T/k1f/$OS"; chmod 000 "$T/k1f/$OS"; ln -s "../../$OS" "$T/k1f/.stella/extensions/qa.json"
ok 'alone k1f extensions "owner setting" && grep -q "must not be a symbolic link" "$T/o" && ! grep -qi "PermissionError\|QA_FAKE" "$T/o" && setting k1f' "190 a link to the owner settings file: the linking row is refused, the line says both, the file is never opened"
mk k1g; ed k1g data-files.json '.files += [(.files[] | select(.id == "versions") | .id = "v-alias" | .path = "./.stella/versions.json")]'
ok 'refuses k1g check && [ "$(grep -c "more than one index row (versions, v-alias)" "$T/o")" = 2 ] && ! grep -q "symbolic link" "$T/o" && setting k1g' "191 control: two rows that spell one file are each refused as named twice, never as a link"
# K2 what a row is: a JSON row whose path does not end in .json is a folder of entries, every other row is one file (W3-RT4-05)
FR='(.files[] | select(.id == "versions"))'   # a schema no cross-file rule reads: the row's own line is the only one (a read of another row of the same schema depends on it, as for any refused row)
mk k2a; cp "$T/k2a/.stella/versions.json" "$T/k2a/.stella/qa-single"; ed k2a data-files.json ".files += [$FR | .id = \"qa-single\" | .path = \".stella/qa-single\"]"
ok 'alone k2a qa-single "\.stella/qa-single is one file.*folder of entries.*rename" && setting k2a && sd k2a get capabilities >/dev/null 2>&1 && refuses k2a get qa-single' "192 a single file whose path has no .json suffix is a named problem of its row (the rule calls it a folder)"
mk k2b; mkdir "$T/k2b/.stella/qa-folder.json"; cp "$T/k2b/.stella/versions.json" "$T/k2b/.stella/qa-folder.json/a.json"; ed k2b data-files.json ".files += [$FR | .id = \"qa-folder\" | .path = \".stella/qa-folder.json\"]"
ok 'alone k2b qa-folder "\.stella/qa-folder\.json is a folder.*one file.*rename" && setting k2b && sd k2b get capabilities >/dev/null 2>&1 && refuses k2b get qa-folder' "193 a folder whose path ends in .json is a named problem of its row (the rule calls it one file)"
mk k2c; ed k2c data-files.json ".files += [$FR | .id = \"qa-none\" | .path = \".stella/qa-none\"]"
ok 'alone k2c qa-none "\.stella/qa-none.*folder.*does not exist" && setting k2c && sd k2c get capabilities >/dev/null 2>&1' "194 a folder row whose folder is missing is a named problem of that row"
mk k2d; mkdir "$T/k2d/.stella/qa-caps"; jq '.entries = [.entries[0] | .id = "qa-cap-one"]' "$T/k2d/.stella/capabilities.json" >"$T/k2d/.stella/qa-caps/a.json"
ed k2d data-files.json '.files += [(.files[] | select(.id == "capabilities") | .id = "qa-caps" | .path = ".stella/qa-caps")]'
ok 'sd k2d check >"$T/o" 2>&1 && [ "$(sd k2d get qa-caps qa-cap-one | jq -r .id)" = qa-cap-one ] && sd k2d list qa-caps --json | jq -e "map(.id) == [\"qa-cap-one\"]" >/dev/null' "195 control: a folder row with a list key is a folder of entries (the list key decides nothing)"
ok 'python3 -I -c "
import os, sys
sys.path.insert(0, sys.argv[1]); import stella_data as s
rs = s.rows(); js = [r for r in rs if r[\"format\"] == \"json\"]
assert all(s.folder_row(r) == os.path.isdir(os.path.join(s.ROOT, r[\"path\"])) for r in js) and any(s.folder_row(r) for r in js)
assert not any(s.folder_row(r) for r in rs if r[\"format\"] != \"json\")" "$BIN"' "196 control: on the shipped tree folder_row() agrees with the disk for every JSON row, and no env row is a folder"
# K3 W1-RT5-02 a redaction_patterns that is not a list of strings is "cannot be read": every string is masked
K3TOK=qafake0rt6aaaaaaaaaaaaaaaa.bbbbbb.ccccccccccccccccccccccccccccc   # the shape of a shipped value pattern; not a real value
for v in null false 0 '""' '{}'; do
  mk np; ed np capabilities.json ".entries[0].summary = \"qa pasted $K3TOK\""; ed np connections.json "(.entries[] | select(.kind == \"channel\")).redaction_patterns = $v"
  ok 'refuses np check && grep -q "redaction_patterns" "$T/o" && { sd np get --json capabilities; sd np list capabilities; sd np search qa pasted; true; } >"$T/o" 2>&1 && ! grep -q "$K3TOK" "$T/o"' "197 redaction_patterns $v: check refuses the catalog, and get, list and search print no value a shipped pattern masks"
  rm -rf "$T/np"
done
# K3 W1-RT5-03 with no readable index validate opens no file
for u in 'printf x >>' 'jq "{schema_version, files: {}}" "$ROOT/.stella/data-files.json" >'; do
  mk nx; mkdir -p "$T/nx/$(dirname "$OS")"; printf '{"QA_FAKE_OWNER_KEY": 1}\n' >"$T/nx/$OS"; chmod 000 "$T/nx/$OS"; eval "$u \"\$T/nx/.stella/data-files.json\""
  ok 'refuses nx validate settings "$T/nx/$OS" && grep -q "^STL-CFG-310 .*data-files\.json.*opens no file" "$T/o" && ! grep -qi "PermissionError\|QA_FAKE" "$T/o" && refuses nx validate event "$T/ev.json" && grep -q "opens no file" "$T/o"' "198 the index cannot be read (${u%% *}): validate opens no file and says so, coded"
  chmod 644 "$T/nx/$OS"; rm -rf "$T/nx"
done
# K3 W1-RT5-04 the catalog's own fault is locatable by position while its patterns cannot be read
mk cp1; N=$(jq '[.entries[].kind] | index("channel") + 1' "$T/cp1/.stella/connections.json"); ed cp1 connections.json '(.entries[] | select(.kind == "channel")).redaction_patterns += ["("]'
ok 'refuses cp1 check && grep -q "^STL-CFG-310 .*connections: a masked id (entry '"$N"' of its file): a redaction pattern is not a regular expression" "$T/o"' "199 a pattern that does not compile: the line says which entry by its position (entry $N)"
mk cp2; printf '{"schema_version":1,"entries":[],"entries":[]}' >"$T/cp2/.stella/connections.json"
ok 'refuses cp2 check && grep -q "connections\.json: repeated key a masked key (key 3 of its object)" "$T/o"' "200 a repeated key in the catalog: the line says which key by its position"
# K3 W1-VER5-04 a row id that is a name the tool uses for something that is no row is refused
jq '.entries |= map(.id += "-2")' "$ROOT/.stella/capabilities.json" >"$T/c2.json"
for id in role-table schema:capabilities; do
  mk pm; cp "$T/c2.json" "$T/pm/.stella/c2.json"; ed pm data-files.json ".files += [(.files[] | select(.id == \"capabilities\") | .id = \"$id\" | .path = \".stella/c2.json\")]"
  ok 'refuses pm check && grep -q "^STL-CFG-310 .*data-files: .*row id '"$id"' .*keeps for" "$T/o" && ! setting pm' "201 an index row named $id is refused by check, and no read is served"
  rm -rf "$T/pm"
done
mk pm2; cp "$T/c2.json" "$T/pm2/.stella/c2.json"; ed pm2 data-files.json '(.files[] | select(.id == "data-files")).id = "qa-idx"'
ok 'sd pm2 check >"$T/o" 2>&1' "202 control: the index row of the index may have another id"
ed pm2 data-files.json '.files += [(.files[] | select(.id == "capabilities") | .id = "data-files" | .path = ".stella/c2.json")]'
ok 'refuses pm2 check && grep -q "row id data-files .*keeps for" "$T/o"' "203 the id the tool uses for the index is refused on a row that is not the index"
# K3 W1-RT5-06 the entry lists a card branch may write are bounded (maxItems, data)
for f in capabilities:entries versions:pins; do
  s=${f%%:*}; k=${f##*:}; M=$(jq ".properties.$k.maxItems" "$ROOT/.stella/schemas/$s.schema.json")
  mk mx; ed mx $s.json ".$k = [range($M) as \$i | (.$k[0] | .id = \"qa-\(\$i)\")]"
  ok '[ "$M" -gt 0 ] && sd mx check >"$T/o" 2>&1' "204 control: $s with $M $k (the schema's maxItems) passes check"
  ed mx $s.json ".$k += [.$k[0] | .id = \"qa-over\"]"
  ok 'refuses mx check && grep -q "^STL-CFG-310 .*'"$s"': .*'"$k"': .* items is out of range" "$T/o" && refuses mx get '"$s"' && grep -q "^STL-CFG-310 " "$T/o"' "205 $s with one more entry is refused by its schema, and get is refused, coded"
  rm -rf "$T/mx"
done
[ $fails -eq 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
