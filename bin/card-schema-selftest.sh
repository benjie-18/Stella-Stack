#!/usr/bin/env bash
# Hermetic self-test for the card and vault-entry schemas (F1b W4): fake files in a scratch root, no code change to add a case.
set -u
BIN=$(dirname "$(readlink -f "$0")"); ROOT=${STELLA_ROOT:-$(dirname "$BIN")}; SD="$BIN/stella_data.py"
T=$(mktemp -d -t card-schema-selftest.XXXXXX); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/r/docs/hermes-local"; cp -r "$ROOT/.stella" "$T/r/.stella"; cp -r "$ROOT/docs/hermes-local/roles.json" "$ROOT/docs/hermes-local/hooks" "$T/r/docs/hermes-local/"; export STELLA_ROOT=$T/r ESCALATE_SUP_DIR=$T/sup
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
sd() { python3 -I "$SD" "$@"; }
IID=$(jq -r .install_id "$ROOT/.stella/install.json"); GID=$(cat /proc/sys/kernel/random/uuid)
U() { cat /proc/sys/kernel/random/uuid; }
ed() { jq "$2" "$T/r/.stella/$1" >"$T/x" && mv "$T/x" "$T/r/.stella/$1"; }   # <data file> <jq filter>, in the scratch root
# a fake app (a copy of the first api provider) and fake skills and tools (copies of the first capability): matched by kind (x-ref-where)
ed connections.json "[.entries[] | select(.kind == \"provider\" and .type == \"api\")][0] as \$p | .entries += [\$p | .id = \"qa-app\" | .kind = \"app\" | .global_id = \"$(U)\"]"
ed capabilities.json ".entries[0] as \$c | .entries += [(\$c | .id = \"qa-skill\" | .kind = \"skill\" | .global_id = \"$(U)\"), (\$c | .id = \"qa-tool\" | .kind = \"tool\" | .global_id = \"$(U)\"), (\$c | .id = \"qa-tool2\" | .kind = \"tool\" | .global_id = \"$(U)\")]"
# switched-off app, unapproved skill and tool, and enough valid ids to pass each list bound (every refusal below is for the rule it names, not for an unknown id)
ed connections.json "[.entries[] | select(.id == \"qa-app\")][0] as \$a | .entries += [\$a | .id = \"qa-app-off\" | .enabled = false | .global_id = \"$(U)\"]"
ed capabilities.json ".entries[0] as \$c | .entries += [(\$c | .id = \"qa-skill-proposed\" | .kind = \"skill\" | .status = \"proposed\" | .global_id = \"$(U)\"), (\$c | .id = \"qa-tool-disabled\" | .kind = \"tool\" | .status = \"disabled\" | .global_id = \"$(U)\")]"
UU=$(for _ in $(seq 170); do U; done | jq -R . | jq -sc .)
many() { jq --argjson u "$UU" --arg k "$2" --argjson n "$3" --argjson o "$4" "(.entries[] | select(.id == \"$5\")) as \$c | .entries += [range(\$n) as \$i | \$c | .id = \"qa-\(\$k)-\(\$i)\" | .kind = \$k | .global_id = \$u[\$o + \$i]]" "$T/r/.stella/$1" >"$T/x" && mv "$T/x" "$T/r/.stella/$1"; }
jq ".properties.entries.maxItems = 512" "$T/r/.stella/schemas/capabilities.schema.json" >"$T/x" && mv "$T/x" "$T/r/.stella/schemas/capabilities.schema.json"   # the registry caps its own entries at 128; 130 fake ids need room (the card schema is what is under test)
many connections.json app 33 0 qa-app; many capabilities.json skill 65 33 qa-skill; many capabilities.json tool 65 98 qa-skill
APP=qa-app; CAP=qa-skill; TOOL=qa-tool; CAP2=$(jq -r '.entries[] | select(.id == "qa-tool2") | .global_id' "$T/r/.stella/capabilities.json")   # a global_id is as good as an id
PROV=$(jq -r '[.entries[] | select(.kind == "provider")][0].id' "$ROOT/.stella/connections.json"); CMD=$(jq -r '[.entries[] | select(.kind == "command")][0].id' "$ROOT/.stella/capabilities.json")
jq -n --arg g "$GID" --arg i "$IID" --arg a "$APP" --arg c "$CAP" --arg t "$TOOL" --arg c2 "$CAP2" \
  '{schema_version:1,global_id:$g,install_id:$i,apps:[$a],skills:[$c],tools:[$t,$c2]}' >"$T/card.json"
jq -n --arg g "$GID" --arg i "$IID" '{schema_version:1,global_id:$g,install_id:$i,kind:"cli-login",version:3,last_refreshed:"2026-11-13T10:00:00Z",
  custody:"engine_store",lease:{holder:"vm_run:run-7",acquired_at:"2026-11-13T10:00:00Z",expires_at:"2026-11-13T11:00:00Z"},
  write_back:{rule:"compare_and_swap",expected_version:3},sync_class:"local-only"}' >"$T/v.json"
fail() { ! sd validate "$1" <(jq "$2" "$T/$3.json") >"$T/out" 2>&1; grep -q "STL-CFG-31[01]" "$T/out"; }   # <schema> <jq edit> <file>: refused with a coded line (exit 1)
why() { sd validate "$1" <(jq "$2" "$T/$3.json") >"$T/out" 2>&1; [ $? = 1 ] && grep -Eq "$4" "$T/out"; }   # <schema> <jq edit> <file> <regex>: exit 1 and the coded line holds the reason
alerts() { cat "$T"/sup/*.log "$T"/sup/*/*.log 2>/dev/null | grep -c STL-CFG-311; }

ok 'sd validate card "$T/card.json" >/dev/null' "1 a fake card with apps, skills and tools validates"
ok 'fail card ".skills=[\"no-such-capability\"]" card && grep -q STL-CFG-311 "$T/out" && [ "$(alerts)" = 1 ]' "2 an unknown skill fails closed: exit 1, the coded line, one alert line"
ok 'fail card ".apps=[\"no-such-app\"]" card && grep -q STL-CFG-311 "$T/out"' "3 an unknown app is refused"
ok 'fail card ".tools=[\"no-such-tool\"]" card && grep -q STL-CFG-311 "$T/out"' "4 an unknown tool is refused"
# 5 and 6 (F1b W4 r2): valid ids, so the list rule itself is what refuses, in apps, skills and tools alike
ok 'why card ".apps=[\"$APP\",\"$APP\"]" card "STL-CFG-310.*apps: items are not unique" && why card ".skills=[\"$CAP\",\"$CAP\"]" card "STL-CFG-310.*skills: items are not unique" && why card ".tools=[\"$TOOL\",\"$TOOL\"]" card "STL-CFG-310.*tools: items are not unique"' "5 a repeated valid id in apps, skills or tools is refused as not unique"
ok 'why card ".apps=[range(33)|\"qa-app-\\(.)\"]" card "STL-CFG-310.*apps: 33 items is out of range" && why card ".skills=[range(65)|\"qa-skill-\\(.)\"]" card "STL-CFG-310.*skills: 65 items is out of range" && why card ".tools=[range(65)|\"qa-tool-\\(.)\"]" card "STL-CFG-310.*tools: 65 items is out of range" && sd validate card <(jq ".apps=[range(32)|\"qa-app-\\(.)\"] | .skills=[range(64)|\"qa-skill-\\(.)\"] | .tools=[range(64)|\"qa-tool-\\(.)\"]" "$T/card.json") >/dev/null' "6 a list over its bound is refused with valid ids, and a full list at the bound validates"
ok 'why card "del(.global_id)" card "STL-CFG-310.*missing global_id" && why card "del(.install_id)" card "STL-CFG-310.*missing install_id"' "7 a card without its ids is refused"
ok 'why card ".secret=\"x\"" card "STL-CFG-310.*.secret. is not allowed"' "8 an unknown card field is refused"
ok 'sd validate vault-entry "$T/v.json" >/dev/null && sd validate vault-entry <(jq ".lease=null" "$T/v.json") >/dev/null' "9 a vault entry validates, leased or not"
ok 'why vault-entry ".lease.holder=[\"engine\",\"vm_run:a\"]" v "STL-CFG-310.*lease.holder: expected string" && why vault-entry ".lease.holders=[\"engine\",\"vm_run:a\"]" v "STL-CFG-310.*holders. is not allowed" && why vault-entry ".lease.holder=\"engine,vm_run:a\"" v "STL-CFG-310.*lease.holder: .* does not match"' "10 a lease with two holders is refused"
ok 'why vault-entry ".sync_class=\"cloud\"" v "STL-CFG-311.*sync_class"' "11 a cloud sync class is refused"
ok 'why vault-entry "del(.write_back)" v "STL-CFG-310.*missing write_back" && why vault-entry "del(.write_back.expected_version)" v "STL-CFG-310.*missing expected_version" && why vault-entry ".write_back.rule=\"overwrite\"" v "STL-CFG-310.*write_back.rule: must be .compare_and_swap."' "12 a missing or wrong compare-and-swap rule is refused"
ok 'why vault-entry ".value=\"s3cret\"" v "STL-CFG-310.*.value. is not allowed" && ! grep -q s3cret "$T/out" && why vault-entry ".secret=\"s3cret\"" v "STL-CFG-310.*.secret. is not allowed" && ! grep -q s3cret "$T/out"' "13 a secret value field is refused"
ok 'why vault-entry ".version=0" v "STL-CFG-310.*version: .* is out of range" && why vault-entry ".custody=\"cloud\"" v "STL-CFG-310.*custody: .* is not one of" && why vault-entry "del(.global_id)" v "STL-CFG-310.*missing global_id"' "14 version 0, a bad custody and a missing id are refused"
# F1b W3: x-ref-where (the record must also carry given values) and an x-ref to a list inside a one-document row
ok 'fail card ".apps=[\"$PROV\"]" card && grep -q "STL-CFG-311.*apps\[0\].*kind" "$T/out" && ! grep -q "$PROV" "$T/out"' "15 a provider id in apps is refused (an app is a connection of kind app), and never printed"
ok 'fail card ".skills=[\"$CMD\"]" card && fail card ".tools=[\"$CAP\"]" card && fail card ".skills=[\"$TOOL\"]" card' "16 a command or a tool in skills and a skill in tools are refused (matched by capability kind)"
ed data-policy.json '.sync_classes += [{id:"qa-cloud-sync",cloud:true,description:"a fake cloud class"},{id:"qa-local-two",cloud:false,description:"a second fake class kept on this install"}]'
ok 'sd validate vault-entry <(jq ".sync_class=\"qa-local-two\"" "$T/v.json") >/dev/null' "17 a second sync class of the data policy with cloud false is accepted (a reference, not a copied list)"
ok 'fail vault-entry ".sync_class=\"qa-cloud-sync\"" v && grep -q "STL-CFG-311.*sync_class.*cloud" "$T/out"' "18 a cloud sync class the data policy defines is refused by reference"
# F1b W4 r2: one record named twice, a global_id that is taken, both problems reported, switched-off and unapproved records
APPG=$(jq -r '.entries[] | select(.id == "qa-app") | .global_id' "$T/r/.stella/connections.json"); SKG=$(jq -r '.entries[] | select(.id == "qa-skill") | .global_id' "$T/r/.stella/capabilities.json"); TLG=$(jq -r '.entries[] | select(.id == "qa-tool") | .global_id' "$T/r/.stella/capabilities.json")
ok 'why card ".apps=[\"$APP\",\"$APPG\"]" card "STL-CFG-310.*apps: .*same record" && why card ".skills=[\"$SKG\",\"$CAP\"]" card "STL-CFG-310.*skills: .*same record" && why card ".tools=[\"$TLG\",\"$TOOL\"]" card "STL-CFG-310.*tools: .*same record" && sd validate card <(jq ".apps=[\"$APP\",\"qa-app-0\"]" "$T/card.json") >/dev/null' "19 an alias and a global_id of one record, in one list, are refused as the same record (apps, skills, tools)"
CONN=$(jq -r '.entries[0].global_id' "$T/r/.stella/connections.json")
ok 'why card ".global_id=\"$CONN\"" card "STL-CFG-310.*global_id.* already" && why card ".global_id=\"$SKG\"" card "STL-CFG-310.*global_id.* already" && why vault-entry ".global_id=\"$CONN\"" v "STL-CFG-310.*global_id.* already" && ! grep -q "$CONN" "$T/out"' "20 a card or vault entry whose global_id is already a record's global_id is refused, and the id is not printed"
before=$(alerts)
ok 'why card ".skills=[\"no-such-capability\"] | .zz=1" card "STL-CFG-310.*zz. is not allowed" && grep -q "STL-CFG-311.*skills\[0\]" "$T/out" && [ "$(( $(alerts) - before ))" = 1 ]' "21 a schema error and an unknown id are both reported: the 310 line, the 311 line and exactly one alert line"
ok 'why card ".apps=[\"qa-app-off\"]" card "STL-CFG-311.*apps\[0\].*enabled" && why card ".skills=[\"qa-skill-proposed\"]" card "STL-CFG-311.*skills\[0\].*status" && why card ".tools=[\"qa-tool-disabled\"]" card "STL-CFG-311.*tools\[0\].*status" && sd validate card <(jq ".apps=[\"$APP\"]" "$T/card.json") >/dev/null' "22 a switched-off app and an unapproved skill or tool are refused like an unknown id (x-ref-where on enabled and status)"
ok 'jq -e ".properties.kind.description | test(\"B1\")" "$ROOT/.stella/schemas/vault-entry.schema.json" >/dev/null' "23 the vault-entry kind field says that B1 defines the kinds"
[ $fails = 0 ] && echo "card-schema selftest OK" || { echo "card-schema selftest FAIL ($fails)"; exit 1; }
