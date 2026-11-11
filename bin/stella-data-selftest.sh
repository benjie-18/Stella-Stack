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
ok 'refuses bad1 check && grep -q "STL-CFG-310" "$T/o" && grep -q bogus "$T/o"' "19 a schema violation makes check exit 1 with STL-CFG-310"
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
ok '! sd bad14 check >/dev/null 2>&1' "34 a secret that is not a variable name (a value pasted in) is refused"
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

[ $fails -eq 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
