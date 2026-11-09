#!/usr/bin/env bash
# Hermes kanban_task_claimed shell hook (D32): when a worker picks an escalated card back up after the thread answer was
# recorded, switch the reply's status reaction to ✨ (working). A card with no recorded answer (its first claim) is left
# alone. Runs detached so the claim never waits on Discord.
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
acct_home=$(getent passwd "$(id -u)" | cut -d: -f6)
[ -n "$acct_home" ] && export HOME=$acct_home  # RT-RTA-01: hermes reads pip.conf, ~/.hermes and git config under HOME, a folder the worker writes; run as cron does
set -uo pipefail
export LC_ALL=C.UTF-8   # F19: the inherited en_US.UTF-8 is not installed, so bash falls back to C and ${s:0:N} cuts bytes
p=$(cat)
c=$(jq -r '.extra.task_id // .task_id // empty' <<<"$p" 2>/dev/null)
[[ "$c" =~ ^t_[0-9a-f]{8}$ ]] || exit 0
( card=""; . /workspace/bin/escalation-discord.sh; set_status_reaction "$c" working ) </dev/null >/dev/null 2>&1 &
disown
exit 0
