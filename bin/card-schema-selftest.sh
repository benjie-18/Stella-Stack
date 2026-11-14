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
APP=qa-app; CAP=qa-skill; TOOL=qa-tool; CAP2=$(jq -r '.entries[] | select(.id == "qa-tool2") | .global_id' "$T/r/.stella/capabilities.json")   # a global_id is as good as an id
PROV=$(jq -r '[.entries[] | select(.kind == "provider")][0].id' "$ROOT/.stella/connections.json"); CMD=$(jq -r '[.entries[] | select(.kind == "command")][0].id' "$ROOT/.stella/capabilities.json")
jq -n --arg g "$GID" --arg i "$IID" --arg a "$APP" --arg c "$CAP" --arg t "$TOOL" --arg c2 "$CAP2" \
  '{schema_version:1,global_id:$g,install_id:$i,apps:[$a],skills:[$c],tools:[$t,$c2]}' >"$T/card.json"
jq -n --arg g "$GID" --arg i "$IID" '{schema_version:1,global_id:$g,install_id:$i,kind:"cli-login",version:3,last_refreshed:"2026-11-13T10:00:00Z",
  custody:"engine_store",lease:{holder:"vm_run:run-7",acquired_at:"2026-11-13T10:00:00Z",expires_at:"2026-11-13T11:00:00Z"},
  write_back:{rule:"compare_and_swap",expected_version:3},sync_class:"local-only"}' >"$T/v.json"
fail() { ! sd validate "$1" <(jq "$2" "$T/$3.json") >"$T/out" 2>&1; grep -q "STL-CFG-31[01]" "$T/out"; }   # <schema> <jq edit> <file>: refused with a coded line (exit 1)
alerts() { cat "$T"/sup/*.log "$T"/sup/*/*.log 2>/dev/null | grep -c STL-CFG-311; }

ok 'sd validate card "$T/card.json" >/dev/null' "1 a fake card with apps, skills and tools validates"
ok 'fail card ".skills=[\"no-such-capability\"]" card && grep -q STL-CFG-311 "$T/out" && [ "$(alerts)" = 1 ]' "2 an unknown skill fails closed: exit 1, the coded line, one alert line"
ok 'fail card ".apps=[\"no-such-app\"]" card && grep -q STL-CFG-311 "$T/out"' "3 an unknown app is refused"
ok 'fail card ".tools=[\"no-such-tool\"]" card && grep -q STL-CFG-311 "$T/out"' "4 an unknown tool is refused"
ok 'fail card ".skills=[.tools[0],.tools[0]]" card' "5 a repeated id in a list is refused"
ok 'fail card ".skills=[range(65)|tostring]" card' "6 a list over the bound is refused"
ok 'fail card "del(.global_id)" card && fail card "del(.install_id)" card' "7 a card without its ids is refused"
ok 'fail card ".secret=\"x\"" card' "8 an unknown card field is refused"
ok 'sd validate vault-entry "$T/v.json" >/dev/null && sd validate vault-entry <(jq ".lease=null" "$T/v.json") >/dev/null' "9 a vault entry validates, leased or not"
ok 'fail vault-entry ".lease.holder=[\"engine\",\"vm_run:a\"]" v && fail vault-entry ".lease.holders=[\"engine\",\"vm_run:a\"]" v && fail vault-entry ".lease.holder=\"engine,vm_run:a\"" v' "10 a lease with two holders is refused"
ok 'fail vault-entry ".sync_class=\"cloud\"" v' "11 a cloud sync class is refused"
ok 'fail vault-entry "del(.write_back)" v && fail vault-entry "del(.write_back.expected_version)" v && fail vault-entry ".write_back.rule=\"overwrite\"" v' "12 a missing or wrong compare-and-swap rule is refused"
ok 'fail vault-entry ".value=\"s3cret\"" v && fail vault-entry ".secret=\"s3cret\"" v' "13 a secret value field is refused"
ok 'fail vault-entry ".version=0" v && fail vault-entry ".custody=\"cloud\"" v && fail vault-entry "del(.global_id)" v' "14 version 0, a bad custody and a missing id are refused"
# F1b W3: x-ref-where (the record must also carry given values) and an x-ref to a list inside a one-document row
ok 'fail card ".apps=[\"$PROV\"]" card && grep -q "STL-CFG-311.*apps\[0\].*kind" "$T/out" && ! grep -q "$PROV" "$T/out"' "15 a provider id in apps is refused (an app is a connection of kind app), and never printed"
ok 'fail card ".skills=[\"$CMD\"]" card && fail card ".tools=[\"$CAP\"]" card && fail card ".skills=[\"$TOOL\"]" card' "16 a command or a tool in skills and a skill in tools are refused (matched by capability kind)"
ed data-policy.json '.sync_classes += [{id:"qa-cloud-sync",cloud:true,description:"a fake cloud class"},{id:"qa-local-two",cloud:false,description:"a second fake class kept on this install"}]'
ok 'sd validate vault-entry <(jq ".sync_class=\"qa-local-two\"" "$T/v.json") >/dev/null' "17 a second sync class of the data policy with cloud false is accepted (a reference, not a copied list)"
ok 'fail vault-entry ".sync_class=\"qa-cloud-sync\"" v && grep -q "STL-CFG-311.*sync_class.*cloud" "$T/out"' "18 a cloud sync class the data policy defines is refused by reference"
[ $fails = 0 ] && echo "card-schema selftest OK" || { echo "card-schema selftest FAIL ($fails)"; exit 1; }
