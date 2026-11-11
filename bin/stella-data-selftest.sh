#!/usr/bin/env bash
# Hermetic self-test for bin/stella_data.py (E1 items 1, 6, 7): the contract data, its schemas and the cross-file rules.
# Case 1-2 read this tree; every other case works in a scratch root (STELLA_ROOT = a temp folder with a copy of .stella/)
# and proves a fake entry works with no code change. The alert log goes to a temp folder (ESCALATE_SUP_DIR).
set -u
BIN=$(dirname "$(readlink -f "$0")"); ROOT=$(dirname "$BIN"); SD="$BIN/stella_data.py"
T=$(mktemp -d -t stella-data-selftest.XXXXXX); trap 'rm -rf "$T"' EXIT
export ESCALATE_SUP_DIR=$T/sup
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
mk() {  # <name>: a scratch root with a copy of the data and the role table
  mkdir -p "$T/$1/docs/hermes-local"; cp -r "$ROOT/.stella" "$T/$1/.stella"; cp "$ROOT/docs/hermes-local/roles.json" "$T/$1/docs/hermes-local/"
}
ed() { local f="$T/$1/.stella/$2"; jq "$3" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <root name> <file> <jq filter>
sd() { STELLA_ROOT=$T/$1 python3 -I "$SD" "${@:2}"; }                          # <root name> <args...>
conn() {  # <id> <kind> <subkind> <locality>: a complete connections entry as jq text
  echo "{id:\"$1\",kind:\"$2\",subkind:\"$3\",label:\"Fake $1\",enabled:true,locality:\"$4\",hosts:[{host:\"$1.example.invalid\",port:443,purpose:\"api\"}],auth_types:[\"api_key\"],secrets:[\"FAKE_KEY\"],actions:[{id:\"go\",approval_class:\"write\"}],models:[{id:\"$1-model\",capabilities:{tool_calling:null,json_mode:null,context_tokens:null,vision:null,streaming:null},probed_at:null,probe_source:null}],data_policy:{retention:null,training_use:null,region:null,zero_retention_available:null,data_classes_allowed:[]},tos:{status:\"unverified\"}}"
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
ok 'refuses bad4 check && grep -q "no-such-provider" "$T/o"' "22 a dangling provider reference in a role assignment is refused"
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
ok 'refuses g3a check connections && grep -q ghost "$T/o"' "51 check <id> also prints the cross-file problems"
mk g3b; ed g3b data-policy.json '.projects["cx"] = {mode:"local_only",allowed_providers:[]}'
ed g3b role-assignments.json '.assignments += [{id:"zz",scope:{level:"card",card:"c1"},role:"builder",effort_mode:"standard",chain:[{provider:"claude-subscription",model:"haiku",parameters:{}}]}]'
ok 'refuses g3b check' "52 a card assignment with no project is refused, not judged by the open default"
ed g3b role-assignments.json '.assignments[-1].scope = {level:"project",project:"CX"}'
ok 'refuses g3b check' "53 a project name in upper case is refused"
mk g3c; ed g3c role-assignments.json '.assignments += [.assignments[0] | .id = "dup"]'
ok 'refuses g3c check' "54 two assignments for one scope, role and effort mode are refused"
mk g3d; ed g3d role-assignments.json '.assignments += [.assignments[0] | .id = "zz" | .role = "unlisted"]'
ok 'refuses g3d check' "55 the fallback role of the role table cannot be assigned"
mk g3e; ed g3e connections.json '(.entries[] | select(.id == "claude-subscription")).enabled = false'
ed g3e role-assignments.json '.assignments += [.assignments[0] | .id = "zz" | .role = "reviewer" | .chain = [{provider:"claude-subscription",model:"haiku",parameters:{}}]]'
ok 'refuses g3e check' "56 a chain naming a disabled provider is refused"
mk g3f; echo '{"schema_version":1,"id":"zz-ext","kind":"skill","summary":"s","hosts":[],"secrets":[],"tools":[],"allowed_roles":[],"risk_class":"read","enabled":true,"status":"proposed","source":"x"}' >"$T/g3f/.stella/extensions/zz-ext.json"
ok 'refuses g3f check && grep -q zz-ext "$T/o"' "57 an extension that is switched on without being approved is refused"
mk g3g; ed g3g features.json '(.entries[] | select(.id == "generated-team-files")).status = "on"'
ok 'refuses g3g check' "58 an on feature that depends on a planned feature is refused"
mk g3h; ed g3h settings.json '.entries[0].code = "STL-ZZZ-999"'
ok 'refuses g3h check' "59 a setting code that is not in the alert catalog is refused"
mk g3i; ed g3i connections.json '.entries[0].data_policy.data_classes_allowed += ["no-such-class"]'
ok 'refuses g3i check' "60 a data class that data-policy does not define is refused"
# G4 schemas and entries
mk g4a; ed g4a connections.json '.entries[0] += {scopes:["read"],redaction_patterns:["sk-[A-Za-z0-9]+"],allowed_roles:["builder"],risk_class:"read"} | .entries[1].tos.subscription_login_by_agent = "allowed"'
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

[ $fails -eq 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
