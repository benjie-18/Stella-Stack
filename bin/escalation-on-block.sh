#!/usr/bin/env bash
# Hermes kanban_task_blocked shell hook: every card that ends up `blocked` gets its #escalations thread, whoever
# blocked it (worker, Stella in chat, or the CLI). Runs detached so the block call never waits on Discord;
# escalation-thread.sh logs the outcome (THREAD_OPENED / THREAD_FAIL) to .supervisor/escalations.log.
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
acct_home=$(getent passwd "$(id -u)" | cut -d: -f6)
[ -n "$acct_home" ] && export HOME=$acct_home  # RT-RTA-01: hermes reads pip.conf, ~/.hermes and git config under HOME, a folder the worker writes; run as cron does
set -uo pipefail
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C.UTF-8   # F19: the inherited en_US.UTF-8 is not installed, so bash falls back to C and ${s:0:N} cuts bytes
. /workspace/bin/kanban-board.sh   # kanban(): every kanban call names its board (F4)
LOG="${ESCALATE_SUP_DIR:-/workspace/.supervisor}/escalations.log"
log() { jq -nc --arg time "$(date -u +%FT%TZ)" --arg card "$1" --arg event "$2" --arg detail "$3" \
  '{time: $time, card: $card, event: $event, detail: $detail}' >>"$LOG"; }
p=$(cat)
card=$(jq -r '.extra.task_id // .task_id // empty' <<<"$p" 2>/dev/null)
[[ "$card" =~ ^t_[0-9a-f]{8}$ ]] || { log "" HOOK_SKIP "kanban_task_blocked payload without a card id"; exit 0; }
reason=$(jq -r '.extra.reason // empty' <<<"$p" 2>/dev/null)
log "$card" HOOK_FIRED "kanban_task_blocked (profile $(jq -r '.profile // "?"' <<<"$p" 2>/dev/null))"
(
  json=$(kanban show "$card" --json 2>/dev/null) || { log "$card" HOOK_SKIP "hermes kanban show failed"; exit 0; }
  # dependency blocks wait in todo for their parents, with no human decision: no thread for those.
  status=$(jq -r '.task.status' <<<"$json")
  if [ "$status" = triage ]; then
    # Hermes routes a card to triage when it blocks again for the same kind after an unblock (block_loop_detected,
    # BLOCK_RECURRENCE_LIMIT 2): an escalation loop, not a fresh decision. Log it as one, post nothing (D29).
    loop=$(jq -c '[.events[]? | select(.kind == "block_loop_detected")] | last | .payload // empty' <<<"$json")
    if [ -n "$loop" ]; then
      log "$card" LOOP_TRIAGE "Hermes block-loop detection routed the card to triage (kind $(jq -r '.kind' <<<"$loop"), recurrences $(jq -r '.recurrences' <<<"$loop")); nothing posted; cause: $(jq -r '.reason' <<<"$loop" | tr '\n' ' ' | cut -c1-300)"
    else
      log "$card" HOOK_SKIP "status is triage (no block_loop_detected event), not blocked"
    fi
    exit 0
  fi
  [ "$status" = blocked ] || { log "$card" HOOK_SKIP "status is $status, not blocked"; exit 0; }
  title=$(jq -r '.task.title' <<<"$json")
  errf=$(mktemp)
  /workspace/bin/escalation-thread.sh "$card" "${title:0:100}" "${reason:-see the card for the decision needed}" >/dev/null 2>"$errf"
  rc=$?
  # escalation-thread.sh logs its own THREAD_OPENED/THREAD_FAIL; this catches a death before it could log (D26).
  [ "$rc" -eq 0 ] || log "$card" HOOK_RESULT "escalation-thread.sh exit $rc; stderr: $(grep -v setlocale "$errf" | tail -c 600)"
  rm -f "$errf"
) </dev/null >/dev/null 2>&1 &
disown
exit 0
