#!/usr/bin/env bash
# Manual drain of the bin/escalate.sh queue (F15, F28, F29); never run by cron. Entries: .supervisor/state/queue.jsonl.
# usage: escalate-drain.sh --list               every entry: id, state, reason, card, model (purpose), created
#        escalate-drain.sh --replay <id>|--all  run queued entries again through bin/escalate.sh, which checks limits.env
#                                               and the pool again. An entry is claimed under the queue lock before the run,
#                                               so a second replay of the same id does nothing. Still blocked (exit 3 or
#                                               75): left queued, no alert. Older than QUEUE_MAX_AGE_HOURS, or its card
#                                               done or archived: marked stale and skipped.
#        escalate-drain.sh --drop <id>          mark it dropped
# A prompt file is removed when its entry leaves the queued state. Exit 0, or 2 on a usage error or an unknown id.
set -uo pipefail
export LC_ALL=C.UTF-8
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
SUP="${ESCALATE_SUP_DIR:-/workspace/.supervisor}" STATE="${ESCALATE_SUP_DIR:-/workspace/.supervisor}/state"
Q="$STATE/queue.jsonl"
. "$SUP/limits.env"
. /workspace/bin/kanban-board.sh
usage() { echo "usage: escalate-drain.sh --list | --replay <id> | --all | --drop <id>" >&2; exit 2; }
mkdir -p "$STATE"; exec 6>"$STATE/queue.lock"
entry() { jq -c --arg id "$1" 'select(.id == $id)' "$Q" 2>/dev/null | tail -1; }
setstate() {  # setstate <id> <state>; the caller holds the lock
  jq -c --arg id "$1" --arg s "$2" --arg t "$(date -u +%FT%TZ)" 'if .id == $id then .state = $s | .updated = $t else . end' \
    "$Q" >"$Q.tmp" && mv "$Q.tmp" "$Q"
}

replay() {
  local id=$1 e card pf age cs rc args
  flock 6
  e=$(entry "$id")
  [ -n "$e" ] || { flock -u 6; echo "$id: no such entry" >&2; return 2; }
  [ "$(jq -r .state <<<"$e")" = queued ] || { flock -u 6; echo "$id: $(jq -r .state <<<"$e"), nothing to do"; return 0; }
  card=$(jq -r .card <<<"$e"); pf=$(jq -r .prompt_file <<<"$e")
  age=$(( ($(date +%s) - $(date -d "$(jq -r .created <<<"$e")" +%s)) / 3600 ))
  cs=$(kanban show "$card" --json 2>/dev/null | jq -r '.task.status // empty')
  if [ "$age" -ge "${QUEUE_MAX_AGE_HOURS:-24}" ] || [ "$cs" = done ] || [ "$cs" = archived ] || [ ! -s "$pf" ]; then
    setstate "$id" stale; flock -u 6; rm -f "$pf"
    echo "$id: stale (${age} h old, card ${cs:-unknown}, prompt $([ -s "$pf" ] && echo kept || echo gone)), skipped"; return 0
  fi
  setstate "$id" replayed; flock -u 6   # claimed: a second replay of this id finds it replayed and does nothing
  mapfile -t args < <(jq -r '.claude_args[]?' <<<"$e")
  ESCALATE_REPLAY="$id" /workspace/bin/escalate.sh "$card" "$(jq -r .model <<<"$e")" "$(jq -r .purpose <<<"$e")" \
    "$(jq -r .call_reason <<<"$e")" -- "${args[@]}" <"$pf"
  rc=$?
  flock 6
  case "$rc" in
    0)    setstate "$id" replayed; rm -f "$pf"; echo "$id: replayed" ;;
    2|3|75) setstate "$id" queued; echo "$id: still blocked or not runnable now (exit $rc), left in the queue" ;;   # 2: e.g. kanban show failed (review M2)
    *)    setstate "$id" failed; rm -f "$pf"; echo "$id: failed (exit $rc)" ;;
  esac
  flock -u 6
}

case "${1:-}" in
  --list)
    [ -s "$Q" ] || { echo "queue empty"; exit 0; }
    jq -r '[.id, .state, .reason, .card, (.model + " (" + .purpose + ")"), .created] | @tsv' "$Q" ;;
  --replay) [ -n "${2:-}" ] || usage; replay "$2" ;;
  --all)
    rc=0
    for id in $(jq -r 'select(.state == "queued") | .id' "$Q" 2>/dev/null); do replay "$id" || rc=$?; done
    exit "$rc" ;;
  --drop)
    [ -n "${2:-}" ] || usage
    flock 6; e=$(entry "$2")
    [ -n "$e" ] || { echo "$2: no such entry" >&2; exit 2; }
    if [ "$(jq -r .state <<<"$e")" = queued ]; then setstate "$2" dropped; rm -f "$(jq -r .prompt_file <<<"$e")"; echo "$2: dropped"
    else echo "$2: $(jq -r .state <<<"$e"), nothing to do"; fi ;;
  *) usage ;;
esac
