#!/usr/bin/env bash
# Rows for bin/roles-selftest.sh (S3A-03, S3A-04), kept apart so the live selftest file stays untouched: roles.py validate
# checks complete_metadata (a non-empty object of non-empty text pairs) and complete_needs_review (true or false) on every role.
# Same invocation as the K8 validation rows of roles-selftest.sh: ROLES_FILE=<modified table copy> roles.py reviewers, exit 1 and
# "roles: INVALID ... role <r>: <field> must be ..." for a bad table, exit 0 for a good one.
# Overrides: STAGE=<dir holding roles.py> (default /workspace/bin), ROLES_FILE=<table> (default the live roles.json; a staged run
# needs a table whose hook paths exist, e.g. roles.staged.json).
set -u
T=$(mktemp -d); trap 'rm -r "$T"' EXIT
S=${STAGE:-/workspace/bin}
RF=${ROLES_FILE:-/workspace/docs/hermes-local/roles.json}
fails=0; nok=0
ok() { if eval "$1"; then echo "ok   $2"; nok=$((nok+1)); else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/out" ] && sed 's/^/     /' "$T/out" | head -3; fi; }
mkdir -p "$T/sup/logs"; cp /workspace/config/owner.example.env "$T/owner.env"
export ESCALATE_SUP_DIR="$T/sup" OWNER_CONFIG="$T/owner.env" PYTHONPATH=/workspace/bin
rv() { ROLES_FILE=$1 python3 "$S/roles.py" reviewers >"$T/out" 2>&1; echo $?; }   # exit code of the validator on that table
ok '[ "$(rv "$RF")" = 0 ]' "control: the table under test is valid"
CMSG="must be a non-empty object of text pairs"; NMSG="must be true or false"
for r in $(jq -r '.roles | keys[]' "$RF"); do   # every role, the fallback included
  for v in '{}' '"x"' '["a"]' '{"k":1}' '{"":"v"}' '{"k":""}' '{"k":true}' '{"k":["v"]}' '{"k":null}' '{"k":"v","j":2}' 7 true null; do
    jq --arg r "$r" --argjson v "$v" '.roles[$r].complete_metadata = $v' "$RF" >"$T/b.json"
    ok '[ "$(rv "$T/b.json")" = 1 ] && grep -q "roles: INVALID" "$T/out" && grep -qF "role $r: complete_metadata $CMSG" "$T/out"' "role $r: complete_metadata = $v: INVALID, named"
  done
  for v in '{"k":"v"}' '{"review":"approved"}' '{"a":"b","c":"d"}'; do
    jq --arg r "$r" --argjson v "$v" '.roles[$r].complete_metadata = $v' "$RF" >"$T/b.json"
    ok '[ "$(rv "$T/b.json")" = 0 ]' "role $r: complete_metadata = $v: valid"
  done
  for v in '"yes"' '"true"' 1 0 '[]' '{}' null; do
    jq --arg r "$r" --argjson v "$v" '.roles[$r].complete_needs_review = $v' "$RF" >"$T/b.json"
    ok '[ "$(rv "$T/b.json")" = 1 ] && grep -q "roles: INVALID" "$T/out" && grep -qF "role $r: complete_needs_review $NMSG" "$T/out"' "role $r: complete_needs_review = $v: INVALID, named"
  done
  for v in true false; do
    jq --arg r "$r" --argjson v "$v" '.roles[$r].complete_needs_review = $v' "$RF" >"$T/b.json"
    ok '[ "$(rv "$T/b.json")" = 0 ]' "role $r: complete_needs_review = $v: valid"
  done
  jq --arg r "$r" 'del(.roles[$r].complete_needs_review, .roles[$r].complete_metadata)' "$RF" >"$T/b.json"
  ok '[ "$(rv "$T/b.json")" = 0 ]' "role $r: neither field: valid (both are optional)"
done
# the field is read through roles.py field like any other permission
RR=$(jq -r '[.roles | to_entries[] | select(.value.complete_metadata != null) | .key][0]' "$RF")
RP=$(jq -r --arg r "$RR" '[.profiles | to_entries[] | select(.value.role == $r) | .key][0]' "$RF")
BR=$(jq -r '[.roles | to_entries[] | select(.value.complete_needs_review == true) | .key][0]' "$RF")
BP=$(jq -r --arg r "$BR" '[.profiles | to_entries[] | select(.value.role == $r) | .key][0]' "$RF")
ok '[ -n "$RP" ] && [ "$RP" != null ] && [ "$(ROLES_FILE=$RF python3 "$S/roles.py" field "$RP" complete_metadata | jq -c .)" = "$(jq -c --arg r "$RR" ".roles[\$r].complete_metadata" "$RF")" ]' "roles.py field <reviewing profile> complete_metadata reads the pairs"
ok '[ -n "$BP" ] && [ "$BP" != null ] && [ "$(ROLES_FILE=$RF python3 "$S/roles.py" field "$BP" complete_needs_review)" = true ]' "roles.py field <builder profile> complete_needs_review reads true"
ok '[ "$(ROLES_FILE=$RF python3 "$S/roles.py" field some-unknown-profile complete_needs_review)" = null ] && [ "$(ROLES_FILE=$RF python3 "$S/roles.py" field some-unknown-profile complete_metadata)" = null ]' "an unknown profile (fallback role) has neither field"
echo "roles-3b-rows: $nok ok, $fails FAIL"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
