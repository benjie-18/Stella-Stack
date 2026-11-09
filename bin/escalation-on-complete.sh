#!/usr/bin/env bash
# Hermes kanban_task_completed shell hook: report the completion of an escalated card (D30). Runs detached so the
# completion call never waits on Discord; bin/escalation-complete.sh posts once and logs COMPLETED or COMPLETE_FAIL.
set -uo pipefail
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C.UTF-8   # F19: the inherited en_US.UTF-8 is not installed, so bash falls back to C and ${s:0:N} cuts bytes
p=$(cat)
card=$(jq -r '.extra.task_id // .task_id // empty' <<<"$p" 2>/dev/null)
[[ "$card" =~ ^t_[0-9a-f]{8}$ ]] || exit 0
summary=$(jq -r '.extra.summary // empty' <<<"$p" 2>/dev/null)
( /workspace/bin/escalation-complete.sh "$card" "$summary" ) </dev/null >/dev/null 2>&1 &
disown
exit 0
