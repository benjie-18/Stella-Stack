#!/usr/bin/env bash
# Catch-all of a role that runs outside the OS box (roles.json runs_unboxed, D46): blocks any tool name no other matcher of the role names (exit 2 = block).
payload=$(cat)
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
refuse() {   # B.1 (r5) refuse <problem> <message>: the one way a hook refuses (bin/roles.py hook-refusal: the catalog code, one alert line per call naming the role)
  local m; m=$(printf '%s' "$payload" | python3 -I /workspace/bin/roles.py hook-refusal STL-GRD-604 "$1" 2>/dev/null) || m=
  jq -nc --arg m "${m:-[STL-GRD-604]} $2" '{action: "block", message: $m}'; exit 2; }
refuse "a tool the role does not name" 'This tool is not one this profile may use: its role names the tools it has, and a tool that is added later is refused until the role table names it (docs/hermes-local/roles.json).'
