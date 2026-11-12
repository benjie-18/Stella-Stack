#!/usr/bin/env bash
# Dispatcher role (D35, D46): a dispatcher never blocks a card; the worker blocks its own (pre_tool_call, exit 2 = block).
payload=$(cat)
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
refuse() {   # B.1 (r5) refuse <problem> <message>: the one way a hook refuses (bin/roles.py hook-refusal: the catalog code, one alert line per call naming the role)
  local m; m=$(printf '%s' "$payload" | python3 -I /workspace/bin/roles.py hook-refusal STL-GRD-604 "$1" 2>/dev/null) || m=
  jq -nc --arg m "${m:-[STL-GRD-604]} $2" '{action: "block", message: $m}'; exit 2; }
refuse "the coordinator role blocks no card" 'Dispatchers do not block cards: the worker blocks its own card, and the #escalations thread follows automatically.'
