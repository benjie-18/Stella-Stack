#!/usr/bin/env bash
# Manual drain of the bin/escalate.sh queue (F15, F28, F29); never run by cron. Entries: .supervisor/state/queue.jsonl.
# usage: escalate-drain.sh --list               every entry: id, state, reason, card, model (purpose), created
#        escalate-drain.sh --replay <id>|--all  run queued entries again through bin/escalate.sh, which checks limits.env
#                                               and the pool again. An entry is claimed under the queue lock before the run,
#                                               so a second replay of the same id does nothing. Still blocked (exit 3 or
#                                               75): left queued, no alert. Older than QUEUE_MAX_AGE_HOURS, or its card
#                                               done or archived: marked stale and skipped.
#        escalate-drain.sh --drop <id>          mark it dropped
# A prompt file is removed when its entry leaves the queued state. Exit 0, or 2 on a usage error, an unknown id or a link in the state folder (nothing written).
# A line of the queue file that is not JSON (a cut write) is skipped by every read and kept as it is by every rewrite; --list warns about it.
set -uo pipefail
export LC_ALL=C.UTF-8
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
SUP="${ESCALATE_SUP_DIR:-/workspace/.supervisor}" STATE="${ESCALATE_SUP_DIR:-/workspace/.supervisor}/state"
Q="$STATE/queue.jsonl"
. "$SUP/limits.env"
. /workspace/bin/kanban-board.sh
usage() { echo "usage: escalate-drain.sh --list | --replay <id> | --all | --drop <id>" >&2; exit 2; }
# nolink <file>: false, with a warning, when a file of the state folder is a symbolic link or has a second hard link; no write of
# the drain goes through one (the rule and the shortcut of bin/escalate.sh's nolink)
nolink() { { [ ! -L "$1" ] && { [ ! -f "$1" ] || [ "$(stat -c %h "$1")" = 1 ]; }; } || { echo "escalate-drain.sh: warning: ${1#"$SUP"/} is a link: not written through it" >&2; return 1; }; }
mkdir -p "$STATE"; nolink "$STATE/queue.lock" || exit 2; exec 6>>"$STATE/queue.lock"   # append: a lock is never emptied
# A line that is not JSON (a cut write) is skipped by every read here and kept as it is by every rewrite; --list reports it. The
# entries after it are read and replayed like any other. escalate.sh refuses to queue while the file has such a line (RT2-03).
rows() { jq -cR 'fromjson? | select(type == "object")' "$Q" 2>/dev/null; }
entry() { rows | jq -c --arg id "$1" 'select(.id == $id)' | tail -1; }
setstate() {  # setstate <id> <state>; the caller holds the lock
  jq -rR --arg id "$1" --arg s "$2" --arg t "$(date -u +%FT%TZ)" '. as $l | (try (fromjson | if type == "object" and .id == $id then .state = $s | .updated = $t else . end | tojson) catch $l)' \
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
    2|3|75) setstate "$id" queued; echo "$id: still blocked or not runnable now (exit $rc), left in the queue" ;;   # 2: kanban show failed (review M2), or escalate.sh refused because a setting's registry default is unreadable (STL-CFG-310)
    *)    setstate "$id" failed; rm -f "$pf"; echo "$id: failed (exit $rc)" ;;
  esac
  flock -u 6
}

case "${1:-}" in
  --list)
    [ -s "$Q" ] || { echo "queue empty"; exit 0; }
    rows | jq -r '[.id, .state, .reason, .card, (.model + " (" + .purpose + ")"), .created] | @tsv'
    bad=$(jq -cR 'select(try (fromjson | type == "object") catch false | not)' "$Q" 2>/dev/null | wc -l)   # the lines no read can use
    [ "$bad" = 0 ] || echo "warning: $bad line(s) of $Q are not queue entries and are skipped (the entries after them are listed); fix or remove them" >&2 ;;
  --replay) [ -n "${2:-}" ] || usage; replay "$2" ;;
  --all)
    rc=0
    for id in $(rows | jq -r 'select(.state == "queued") | .id'); do replay "$id" || rc=$?; done
    exit "$rc" ;;
  --drop)
    [ -n "${2:-}" ] || usage
    flock 6; e=$(entry "$2")
    [ -n "$e" ] || { echo "$2: no such entry" >&2; exit 2; }
    if [ "$(jq -r .state <<<"$e")" = queued ]; then setstate "$2" dropped; rm -f "$(jq -r .prompt_file <<<"$e")"; echo "$2: dropped"
    else echo "$2: $(jq -r .state <<<"$e"), nothing to do"; fi ;;
  *) usage ;;
esac
