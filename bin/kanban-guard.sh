#!/usr/bin/env bash
# Hermes pre_tool_call hook on kanban_* tools, every profile (D31). Exit 2 + block JSON refuses the call; anything else
# allows it. Fail-open by design (registered without fail_closed): this prevents mistakes, it is not a security gate.
#  1. Wrong board: a call naming a board other than KANBAN_BOARD (bin/kanban-board.sh) is refused (t_13ed94d5 blocked "default" and failed).
#  2. Forged answer (F26): "UNBLOCK: escalation reply" text in any argument is refused. Only the poller writes the owner's
#     answer, as a CLI comment (`hermes kanban unblock --reason`), which is not a tool call and never reaches this hook.
#     The one exception is the clause the dispatcher's SOUL puts in every decision card ("starts with 'UNBLOCK: escalation reply'").
#  3. Re-block of an answered decision: kanban_block on a card whose thread reply is already recorded, for a reason whose
#     normalized fingerprint was already escalated, is refused, so the worker uses the answer instead of looping (D29).
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
acct_home=$(getent passwd "$(id -u)" | cut -d: -f6)
[ -n "$acct_home" ] && export HOME=$acct_home  # RT-RTA-01: hermes reads pip.conf, ~/.hermes and git config under HOME, a folder the worker writes; run as cron does
set -uo pipefail
export LC_ALL=C.UTF-8   # F19: the inherited en_US.UTF-8 is not installed, so bash falls back to C and ${s:0:N} cuts bytes
p=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$p" 2>/dev/null)
. /workspace/bin/kanban-board.sh   # KANBAN_BOARD (F4)
refuse() { printf '%s\n' "$(jq -nc --arg m "$1" '{action: "block", message: $m}')"; exit 2; }

board=$(jq -r '.tool_input.board // empty' <<<"$p" 2>/dev/null)
if [ -n "$board" ] && [ "$board" != "$KANBAN_BOARD" ]; then
  refuse "kanban guard: board \"$board\" refused; every kanban call uses board $KANBAN_BOARD (SUPERVISOR.md)."
fi
# Invisible format characters (soft hyphen, zero-width, word joiner, BOM) are dropped and Unicode spaces count as spaces,
# so neither can split the phrase (review rounds 2 and 3).
text=$(jq -r '[.tool_input | .. | strings] | join("\n") | gsub("[\u00ad\u180e\u200b-\u200f\u2060-\u2064\ufeff]"; "")
  | gsub("[\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]"; " ")' <<<"$p" 2>/dev/null | sed -E "s/starts with ['\"\`]UNBLOCK: escalation reply['\"\`]//g")
if tr -d '[:space:]' <<<"$text" | grep -qi 'UNBLOCK:escalationreply'; then   # no whitespace at all: nothing can split the phrase
  refuse "kanban guard: only the escalation poller writes \"UNBLOCK: escalation reply\" text, when the owner answers in Discord (D39). An agent never writes or quotes it. Remove it and retry; to ask the owner, kanban_block with kind needs_input."
fi

[ "$tool" = kanban_block ] || exit 0
card=$(jq -r '.tool_input.task_id // empty' <<<"$p" 2>/dev/null | python3 -I -c 'import sys; print(sys.stdin.read().strip())')   # RT4-09/RT5-03: as Hermes's strip()
# K1: no task_id = the worker's own card, proven from the board and the kernel (bin/roles.py prove), never HERMES_KANBAN_*
own=$(python3 -I "${BASH_SOURCE[0]%/*}/roles.py" prove --profile "$(jq -r '.profile // empty' <<<"$p")" 2>/dev/null | jq -r '.card // empty')
tid=$card; [ -n "$card" ] || card=$own
# K3: a run-away respawn (t_4d38aea8: 14 runs in 25 minutes, each refused by the same guard, blocked as capability and
# re-promoted by Hermes's triage). When the card's newest runs since its last unblock were each refused by a guard with the
# same STL code (alerts.log, bin/alert_catalog.py streak) GUARD_REFUSAL_LOOP_N times or more (.supervisor/limits.env), a
# worker's block of any other kind is made a needs_input block by the stack itself while the card still runs (Hermes
# blocks only running or ready cards), so the existing #escalations thread opens with the code and its catalog action.
# The CLI runs outside Hermes's worker fence (the stack acting, not the worker), as roles.kanban() does.
kind=$(jq -r '.tool_input.kind // empty' <<<"$p" 2>/dev/null)
loop_n=$(sed -n 's/^GUARD_REFUSAL_LOOP_N=\([0-9][0-9]*\)[[:space:]]*$/\1/p' "${ESCALATE_SUP_DIR:-/workspace/.supervisor}/limits.env" 2>/dev/null)
k3own=$own   # RT5-01: a refused run is one whose proof failed, so K3 (only) also takes the profile's one running card
[ -n "$k3own" ] || k3own=$(kanban list --assignee "$(jq -r '.profile // empty' <<<"$p")" --status running --json 2>/dev/null | jq -r 'if length == 1 then .[0].id else empty end')
k3card=${tid:-$k3own}
if [ "$kind" != needs_input ] && [ -n "$loop_n" ] && [[ "$k3own" =~ ^t_[0-9a-f]{8}$ ]] && [ "$k3card" = "$k3own" ]; then   # RT4-12: own card only
  card=$k3own
  K3B="${BASH_SOURCE[0]%/*}"
  stack_kanban() { ( unset $(compgen -v HERMES_KANBAN) HERMES_DELEGATED_CHILD_CONTEXT
    export HERMES_HOME="$(getent passwd "$(id -u)" | cut -d: -f6)/.hermes"; kanban "$@" ); }   # F4: through kanban-board.sh
  read -r code runs < <(stack_kanban show "$card" --json 2>/dev/null | python3 -I "$K3B/alert_catalog.py" streak 2>/dev/null)
  if [[ "${code:-}" =~ ^STL- ]] && [ "${runs:-0}" -ge "$loop_n" ]; then
    action=$(python3 -I "$K3B/alert_catalog.py" field "$code" action 2>/dev/null)
    reason="Decision needed: card $card was stopped after $runs runs in a row refused by a guard with $code. What to do: ${action:-see $code in docs/alert-codes.md}"
    if stack_kanban block "$card" --kind needs_input "$reason" >/dev/null 2>&1; then
      jq -nc --arg time "$(date -u +%FT%TZ)" --arg card "$card" --arg d "$runs runs refused with $code; blocked needs_input" \
        '{time: $time, card: $card, event: "K3_REBLOCK", detail: $d}' >>"${ESCALATE_SUP_DIR:-/workspace/.supervisor}/escalations.log"
      refuse "kanban guard: [$code] this card had $runs runs in a row refused with $code, so the stack has blocked it for the owner (needs_input) and opened its escalation thread. Stop work on this card now."
    fi
  fi
fi
card=${tid:-$own}
[[ "$card" =~ ^t_[0-9a-f]{8}$ ]] || exit 0
. /workspace/bin/escalation-discord.sh
POSTED="$SUP/state/escalation-posted.tsv"
reply_row=$(awk -F'\t' -v c="$card" '$2 == c { r = $0 } END { print r }' "$SEEN" 2>/dev/null)
[ -n "$reply_row" ] || exit 0                                    # no answer recorded yet: a first block is fine
q=$(normalize_reason "$(jq -r '.tool_input.reason // empty' <<<"$p" 2>/dev/null)")
qsha=$(printf '%s' "${q:-see the card for the decision needed}" | sha256sum | cut -c1-16)
grep -q "^${card}"$'\t'"[^"$'\t'"]*"$'\t'"${qsha}"$'\t' "$POSTED" 2>/dev/null || exit 0   # a new, different decision: allow
thread=$(cut -f3 <<<"$reply_row")
answer=$(jq -r --arg c "$card" 'select(.card == $c and .event == "REPLY") | .reply' "$LOG" 2>/dev/null | tail -1)
log REBLOCK_REFUSED "kanban_block for the same decision refused; the answer in thread $thread is recorded"
refuse "kanban guard: this decision was already answered in the #escalations thread ${thread}: \"${answer}\". Use that answer and finish the card (kanban_complete with summary 'Decision: ${answer}'). Block again only for a new, different decision."
