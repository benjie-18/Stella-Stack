#!/usr/bin/env bash
# Dispatcher role (D35, D46): block every file-writing tool call (write_file, patch, execute_code, skill_manage, cronjob_manage (D42); exit 2 = block).
payload=$(cat)
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
refuse() {   # B.1 (r5) refuse <problem> <message>: the one way a hook refuses (bin/roles.py hook-refusal: the catalog code, one alert line per call naming the role)
  local m; m=$(printf '%s' "$payload" | python3 -I /workspace/bin/roles.py hook-refusal STL-GRD-604 "$1" 2>/dev/null) || m=
  jq -nc --arg m "${m:-[STL-GRD-604]} $2" '{action: "block", message: $m}'; exit 2; }
refuse "the coordinator role writes no files" 'Dispatchers do not write files: create a card for a worker instead.'
