#!/usr/bin/env bash
# Fallback role (a profile with no row in roles.json, D46): block every write and every tool no other matcher names; it opens nothing (exit 2 = block).
payload=$(cat)
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
refuse() {   # B.1 (r5) refuse <problem> <message>: the one way a hook refuses (bin/roles.py hook-refusal: the catalog code, one alert line per call naming the role)
  local m; m=$(printf '%s' "$payload" | python3 -I /workspace/bin/roles.py hook-refusal STL-GRD-604 "$1" 2>/dev/null) || m=
  jq -nc --arg m "${m:-[STL-GRD-604]} $2" '{action: "block", message: $m}'; exit 2; }
refuse "a profile with no row in the role table" 'This profile has no row in the role table, so its role opens nothing: it writes no files and runs no tool beyond reading. Ask the owner to add the profile to docs/hermes-local/roles.json.'
