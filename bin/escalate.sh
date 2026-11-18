#!/usr/bin/env bash
# The only sanctioned way to run an escalation model on the coding CLI this script drives: card-scoped, logged, rate-limited.
# usage: escalate.sh <card-id> <purpose> <reason...> [--]
#   prompt on stdin. Anything after -- is refused (exit 2): no caller passes an extra arg. A reason over 8192 characters is refused (exit 2; not on a replay).
#   The caller names neither a model nor a rung (F2b item E). The purpose picks the role (routing data escalation.purposes
#   {purpose: role}; no row: STL-MDL-747, exit 2); the rung is the card's current rung for that role (state/rungs.json
#   {card: {role: rung}}, 1 when absent; nothing here raises it). The resolver (bin/resolve.py resolve --rung, the CLI: it logs the
#   skipped rungs) answers the rung for that role, the card and its project; the call runs only on its exit 0 with a usable served
#   rung, and only when that link's connection has this script's CLI (else STL-MDL-746) and its model's limits.purposes holds the
#   purpose; no other rung is ever asked. One trusted event line per served rung (event_log.py); if it cannot be written, nothing runs.
#   Only the supervisor runs this script: a call from a worker run is refused (STL-GRD-604, exit 3, not queued).
#   The model's limits are its catalog `limits` object: `purposes` (the only purposes it runs for), `max_concurrent` (slots),
#   `per_day` (calls per UTC day), each a value or the name of the limits.env key that holds it, and `purpose_models`
#   {purpose: the model name the CLI gets for that purpose instead of the id}.
# Exit: 0 ok, 2 usage or a refusal (a setting's registry default, the catalog or the routing data unreadable: STL-CFG-310; no
# purpose row or bad rung state: STL-MDL-747; the resolver refused the environment or its data, gave no answer it can read, or the
# event line failed; the log or a state file of the call is a link; nothing run), 3 over a limit or a rung the resolver does not
# serve usable (its code), not on this CLI (STL-MDL-746) or not for this purpose (never retried), 4 no rung left (STL-MDL-731:
# escalate to the owner), 75 pool exhausted, else the CLI's exit code.
# Queue (F15, F28, F29): a call refused by a zeroed or exceeded limit (slots, per day) or a rung in cooldown (STL-MDL-724), and every
# pool-exhausted call is recorded in state/queue.jsonl (card, purpose, role, rung asked) with its prompt file, and raises one #alerts
# line; the caller still gets 3 or 75. No rung left: recorded in state `owner` (never replayed or staled; only --drop removes it)
# with one owner line instead. Every other refusal is not queued and its prompt file is removed.
# A queue file that cannot be read, parsed or written is never read as empty and never reported as written: the call is not queued,
# the caller still gets 3 or 75, the stderr line, the card note and a NOT_QUEUED log line say it was lost, and STL-LIM-405 tells the
# owner (one alert an hour: the file stays broken until it is fixed). An unreadable settings registry is checked after the
# usage checks and refuses the call (STL-CFG-310, one alert an hour). Nothing retries a call: bin/escalate-drain.sh (manual)
# replays a queued one. Beyond QUEUE_MAX queued entries the call is refused unqueued (NOT_QUEUED, one #alerts line an hour).
# ESCALATE_REPLAY=<id> (set by the drain) never queues or alerts again.
# Test hook (Stage 6 T15): ESCALATE_FORCE_POOL_EXHAUSTED=1 skips claude and takes the pool-exhausted path. An escalation rung is
# never rerouted to the pool-exhausted fallback runner (E-DC-07: it is not judged by the resolver): it queues.
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
set -uo pipefail
# cron/hook callers start with a minimal PATH; append so test stubs earlier in PATH still win.
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C.UTF-8   # F19: the inherited en_US.UTF-8 is not installed, so bash falls back to C and ${s:0:N} cuts bytes

CLI=claude-code   # the catalog id (a connection's `cli`) of the coding CLI this script drives: the `claude` command below
SUP="${ESCALATE_SUP_DIR:-/workspace/.supervisor}"
LOG="$SUP/escalations.log"
STATE="$SUP/state"
mkdir -p "$STATE"
# shellcheck source=/dev/null
. "$SUP/limits.env" || { echo "escalate.sh: cannot read $SUP/limits.env" >&2; exit 2; }
. /workspace/bin/kanban-board.sh   # kanban(): every kanban call names its board (F4)
. /workspace/bin/owner-config.sh   # once_per_hour, and alert_text (D44) through it

# Rate-limit / pool-exhausted output, verified in claude 2.1.310 (bin/claude.exe strings).
POOL_PATTERNS=("You've hit your" "You've reached your" "You're out of usage credits" "You're out of extra usage"
  "Your org is out of usage" "usage limit reached" "rate_limit_error" "Rate limit exceeded")

card="${1:-}" purpose="${2:-}" model="" role="" rung=""   # model, role, rung: set once the data and the resolver answer them
shift $(( $# < 2 ? $# : 2 ))
reason=""
while [ $# -gt 0 ] && [ "$1" != "--" ]; do reason="${reason:+$reason }$1"; shift; done
[ "${1:-}" = "--" ] && shift

log() {  # log <event> <exit_code|null> [model_used] [fallback] [cost] [detail]
  jq -nc --arg time "$(date -u +%FT%TZ)" --arg card "$card" --arg model "$model" --arg purpose "$purpose" --arg role "$role" \
    --arg rung "$rung" --arg reason "$reason" --arg event "$1" --argjson exit_code "${2:-null}" --arg model_used "${3:-}" \
    --argjson fallback "${4:-false}" --argjson cost_usd "${5:-null}" --arg detail "${6:-}" \
    '{time: $time, card: $card, model: $model, purpose: $purpose, role: $role, rung: ($rung | tonumber? // null), reason: $reason,
      event: $event, exit_code: $exit_code, model_used: $model_used, fallback: $fallback, cost_usd: $cost_usd, detail: $detail}' >>"$LOG"
}
refuse() { log "$1" "$2" "" false null "$3"; echo "escalate.sh: $1: $3" >&2; exit "$2"; }
registry() {  # registry <KEY>: sets reg_def reg_min reg_max from the settings registry; unreadable = refuse (exit 2, STL-CFG-310)
  local v
  v=$(python3 -I /workspace/bin/stella_data.py get --json settings "$1" 2>/dev/null | jq -er '[.default, .validation.minimum, .validation.maximum]
    | select(all(type == "number" and . == floor) and .[1] <= .[0] and .[0] <= .[2]) | @tsv') && read -r reg_def reg_min reg_max <<<"$v" && [ -n "$reg_max" ] && return
  unreadable "the default and range of setting $1 cannot be read" "no call without a timeout, no unbounded queue"
}
unreadable() {  # unreadable <problem> <what that rules out>: data this call rests on (the settings registry, the catalog) cannot be read: refuse (exit 2, STL-CFG-310)
  local p=$1
  python3 -I /workspace/bin/alert_catalog.py preview STL-CFG-310 problem="$p" >&2 2>/dev/null || echo "STL-CFG-310 $p" >&2   # fallback: no catalog, still a code
  # Nothing is queued (the queue bound is what could not be read) and the prompt is not read: the caller keeps it. The owner is told
  # on the alerts channel once an hour (a standing condition), never for a replay; each refused call has its own log line.
  if [ -z "${ESCALATE_REPLAY:-}" ] && once_per_hour registry-unreadable; then
    hermes send --to "$ALERT_TARGET" --quiet "$(alert_text STL-CFG-310 problem="$p; escalate.sh refused the call for card $card ($purpose): it was not run and not queued, the caller still holds the prompt; later calls are refused the same way until it is fixed (each in escalations.log, SETTING_UNREADABLE)")" >/dev/null 2>&1
  fi
  refuse SETTING_UNREADABLE 2 "$p; $2"
}
# lim <name>: L = the model's limit of that name, from its catalog `limits` object: a number or a list as it stands; a string names
# the limits.env key that holds it (a key that file does not define gives an empty L, which every check below refuses). False when
# the model has no such limit.
lim() {
  local t
  IFS=$'\t' read -r t L < <(jq -r --arg k "$1" '.limits[$k] | select(. != null) | [type, (if type == "array" then join(" ") else tostring end)] | @tsv' <<<"$link") || return 1
  [ "$t" = string ] || return 0
  if [[ $L =~ ^[A-Z][A-Z0-9_]*$ ]] && grep -q "^$L=" "$SUP/limits.env"; then L=${!L-}; else L=""; fi
}
note() { kanban comment --author escalate.sh "$card" "$1" >/dev/null 2>&1; }
QUEUE="$STATE/queue.jsonl"
# nolink <file>: false, with a warning, when a file of the state folder (or the log) is a symbolic link or has a second hard link;
# no write there opens one (W5-RT4-01).
# shortcut: whoever can write the state folder can put a link in between this test and the open; upgrade to an O_NOFOLLOW open if a less trusted user can write it
nolink() { { [ ! -L "$1" ] && { [ ! -f "$1" ] || [ "$(stat -c %h "$1")" = 1 ]; }; } || { echo "escalate.sh: warning: ${1#"$SUP"/} is a link: not written through it" >&2; return 1; }; }
nolink "$LOG" || exit 2   # every call logs: checked once, before the first line is appended
nolink "$STATE" || refuse STATE_LINK 2 "the state folder is a link: nothing is made in it"
queue_failed() {  # queue_failed <what>: the call is not in the queue, and every message says so (the prompt goes: nothing points at it)
  flock -u 6 2>/dev/null; rm -f "$prompt"; qid=""   # fd 6 is not open when the lock file was refused
  qnote="NOT queued: $1; fix the file (the call is lost, run it again)"
  echo "escalate.sh: warning: $1" >&2
  log NOT_QUEUED null none false null "$1; the call is lost"   # every lost call has its own line; the alert below is once an hour
  once_per_hour queue-unusable && hermes send --to "$ALERT_TARGET" --quiet "$(alert_text STL-LIM-405 card="$card" model="${model^}" problem="$1" since="$(date -u +%FT%TZ)")" >/dev/null 2>&1
}
queue() {  # queue <LIMIT|POOL_EXHAUSTED|OWNER> <what happened>: one entry and one #alerts line (OWNER: state owner, the caller sends
  # the owner line); sets qid ("" if not queued), qnote
  qid="" qnote="not queued"
  [ -z "${ESCALATE_REPLAY:-}" ] || { qnote="left in the queue as $ESCALATE_REPLAY"; [ "$1" != OWNER ] || qnote="the drain keeps $ESCALATE_REPLAY for the owner (state owner)"; rm -f "$prompt"; return 0; }
  nolink "$STATE/queue.lock" || { queue_failed "the queue lock state/queue.lock is a link"; return 0; }
  exec 6>>"$STATE/queue.lock"; flock 6
  nolink "$QUEUE" || { queue_failed "the queue file state/queue.jsonl is a link"; return 0; }
  nq=0   # a missing file is an empty queue; a file that cannot be read or parsed is not (the count is unknown, so nothing is queued past the limit)
  if [ -e "$QUEUE" ] && ! nq=$(jq -s '[.[] | select(.state == "queued")] | length' "$QUEUE" 2>/dev/null); then
    queue_failed "the queue file state/queue.jsonl cannot be read or parsed"; return 0
  fi
  if [ "$nq" -ge "$QUEUE_MAX" ]; then
    flock -u 6; rm -f "$prompt"
    qnote="not queued: the queue is full (QUEUE_MAX=$QUEUE_MAX)"
    log NOT_QUEUED null none false null "the queue is full (QUEUE_MAX=$QUEUE_MAX); the call is lost"
    once_per_hour queue-full && hermes send --to "$ALERT_TARGET" --quiet "$(alert_text STL-LIM-403 max="$QUEUE_MAX" why="$1" card="$card" since="$(date -u +%FT%TZ)")" >/dev/null 2>&1
    return 0
  fi
  qid="q_$(date -u +%Y%m%dT%H%M%SZ)_${card}_$$"
  entry=$(jq -nc --arg id "$qid" --arg card "$card" --arg purpose "$purpose" --arg role "$role" --argjson rung "$rung" --arg call_reason "$reason" \
    --argjson claude_args "$(if [ ${#extra_args[@]} -gt 0 ]; then printf '%s\n' "${extra_args[@]}" | jq -Rsc 'split("\n")[:-1]'; else echo '[]'; fi)" \
    --arg why "$1" --arg detail "$2" --arg created "$(date -u +%FT%TZ)" --arg prompt_file "$prompt" \
    --arg state "$([ "$1" = OWNER ] && echo owner || echo queued)" \
    '{id: $id, card: $card, purpose: $purpose, role: $role, rung: $rung, call_reason: $call_reason, claude_args: $claude_args,
      reason: $why, detail: $detail, created: $created, state: $state, prompt_file: $prompt_file}')   # what was asked, never a model
  # a cut last line (no newline) would swallow this entry: end it first; a write that fails is not a queued call
  { [ ! -s "$QUEUE" ] || [ -z "$(tail -c1 "$QUEUE")" ] || echo >>"$QUEUE"; } && printf '%s\n' "$entry" >>"$QUEUE" \
    || { queue_failed "the queue file state/queue.jsonl cannot be written"; return 0; }
  flock -u 6
  qnote="recorded in the queue as $qid; run bin/escalate-drain.sh"
  [ "$1" != OWNER ] || { qnote="recorded for the owner as $qid (state owner: never replayed; bin/escalate-drain.sh --drop $qid removes it)"; log QUEUED null none false null "$1; $qid"; return 0; }
  log QUEUED null none "$([ "$1" = POOL_EXHAUSTED ] && echo true || echo false)" null "$1; $qid"
  [ "$1" = POOL_EXHAUSTED ] && acode=STL-LIM-402 || acode=STL-LIM-401
  hermes send --to "$ALERT_TARGET" --quiet "$(alert_text "$acode" card="$card" model="${model^}" purpose="$purpose" queue_id="$qid" detail="$2" since="$(date -u +%FT%TZ)")" >/dev/null 2>&1
  alert_rc=$?
}
limit() { queue LIMIT "$1"; note "escalate.sh LIMIT: $model ($purpose) for '$reason': $1. No result; $qnote."; refuse LIMIT 3 "$1; $qnote"; }
# shortcut: the limit is a number here (limits.env and the settings registry hold none), move it to the registry when a caller needs another; in characters, so 32 KiB at most, far under the 128 KiB the kernel gives one argument (W5-RT6-03: a longer one cannot be replayed)
# Not on a replay (W5-RT7-02): the drain's read can give a queued reason back with more characters, and a reason accepted when it was
# queued is never refused for its length; one over the kernel's limit cannot be handed over by the drain at all (exit 126, left queued).
[ -n "${ESCALATE_REPLAY:-}" ] || [ ${#reason} -le 8192 ] || { m="reason of ${#reason} characters is longer than 8192: put the detail in the prompt"; reason="${reason:0:80}..."; refuse USAGE 2 "$m"; }
# W5-RT6-01: an extra arg is passed on only if a caller of the stack uses it. None does (the drain replays the empty list every
# caller queues), so every one is refused, here, where a direct call and a replay both pass. To allow one, name it in this test.
extra_args=("$@")   # always empty past the next line; kept with a queue entry
[ $# -eq 0 ] || refuse USAGE 2 "extra claude arg $(printf %q "$1") is refused: no caller of the stack passes one (it could override escalate.sh's model, budget or permissions, or make the model command read a file or start a command)"

[[ "$card" =~ ^t_[0-9a-f]{8}$ ]] || refuse USAGE 2 "card id required (t_xxxxxxxx), got '${card}'"
[ -n "$reason" ] || refuse USAGE 2 "reason required"
card_json=$(kanban show "$card" --json 2>/dev/null) || refuse USAGE 2 "card $card not found on the board"
# Only the supervisor runs this script (E-DC-04, owner decision 2026-11-17): a worker run is refused before any resolver call, its
# own card or not. own = the card the guards' proof names for this call (roles.prove_card: the board and the kernel, never the
# caller's word); "?" when a worker marker of the role table is set but no card is proven, or when it cannot be told (the board or
# the table unreadable); empty when the call belongs to no worker run. Not queued: the drain would replay the call as the supervisor.
own=$(python3 -I -c 'import os, sys; sys.path.insert(0, "/workspace/bin"); import roles
j, why = roles.prove_card()
if not why: print(j["task"]["id"])
elif why.startswith("the board cannot be read") or any(os.environ.get(m) for m in roles.worker_markers(roles.load())): print("?")' 2>/dev/null) || own="?"
[ -z "$own" ] || refuse WORKER_RUN 3 "STL-GRD-604 this call comes from a worker run (proven on ${own/#\?/no card}): only the supervisor runs bin/escalate.sh"
# The purpose picks the role (routing data escalation.purposes, owner decision 2026-11-18); the card's current rung for that role is
# host-side state (state/rungs.json {card: {role: rung}}, 1 when absent; the QA loop raises it, never this script).
routing=$(python3 -I /workspace/bin/stella_data.py get --json routing 2>/dev/null) || unreadable "the routing data cannot be read" "no purpose is known"
role=$(jq -r --arg p "$purpose" '.escalation.purposes[$p]? | strings' <<<"$routing" 2>/dev/null)
[ -n "$role" ] || refuse USAGE 2 "STL-MDL-747 purpose $(printf %q "${purpose:0:64}") has no row in the routing data's escalation.purposes (usage: escalate.sh <card-id> <purpose> <reason...>; the caller names no model)"
driver=$(jq -r '[.drivers[]? | select(.mid_task == false) | .id][0] // empty' <<<"$routing" 2>/dev/null)   # the worker-CLI driver: the one that never switches mid-task
RUNGS="$STATE/rungs.json"
nolink "$RUNGS" || refuse RUNG_STATE 2 "STL-MDL-747 state/rungs.json is a link: not read"
rung=1; if [ -e "$RUNGS" ]; then   # a file that is there but unreadable, or a value that is no whole number from 1, is never read as rung 1
  rung=$(jq -er --arg c "$card" --arg r "$role" 'if type == "object" and ((.[$c] // {}) | type == "object") then .[$c][$r] // 1 else error end
    | select(type == "number" and . == floor and . >= 1 and . <= 999)' "$RUNGS" 2>/dev/null) \
    || { rung=""; refuse RUNG_STATE 2 "STL-MDL-747 state/rungs.json cannot be read or holds no whole number from 1 to 999 for card $card, role $role"; }
fi
# The project is the card's (the board's field, else the folder part of its branch). A card that names no project is refused: an
# empty project would be judged by the default policy only.
project=$(jq -r '.task | (.project | strings) // ((.branch_name // .branch // "") | strings | select(contains("/")) | split("/")[0])' <<<"$card_json" 2>/dev/null)
[ -n "$project" ] || refuse NO_PROJECT 3 "STL-MDL-711 card $card names no project on the board: no rung is asked, nothing is queued"
catalog=$(python3 -I /workspace/bin/stella_data.py get --json connections 2>/dev/null) || unreadable "the connections catalog cannot be read" "no model is known"
# The settings registry is read after the usage checks: a bad call is refused for what it is, before any alert.
# A limit that is set but outside the registry's type and range is treated like a bad timeout: one warning, then the registry
# default (`timeout 0` means no timeout; a non-number makes `[ -ge ]` fail, which would queue without bound).
registry CALL_TIMEOUT; ct_def=$reg_def ct_min=$reg_min ct_max=$reg_max
registry QUEUE_MAX; qm_def=$reg_def qm_min=$reg_min qm_max=$reg_max
# shortcut: nine digits at most (a number of days still fits in 64 bits); longer is out of range anyway
secs=; if [[ "${CALL_TIMEOUT:-}" =~ ^([1-9][0-9]{0,8})([smhd]?)$ ]]; then
  case "${BASH_REMATCH[2]}" in m) mul=60;; h) mul=3600;; d) mul=86400;; *) mul=1;; esac; secs=$(( ${BASH_REMATCH[1]} * mul )); fi
if [ -z "$secs" ] || [ "$secs" -lt "$ct_min" ] || [ "$secs" -gt "$ct_max" ]; then bad_timeout="${CALL_TIMEOUT:-}"; CALL_TIMEOUT=$ct_def
  log WARN null "" false null "CALL_TIMEOUT='$bad_timeout' is not a positive duration of $ct_min to $ct_max seconds (0 would disable the timeout); using $CALL_TIMEOUT"
  echo "escalate.sh: warning: CALL_TIMEOUT='$bad_timeout' is not a positive duration of $ct_min to $ct_max seconds; using $CALL_TIMEOUT" >&2; fi
if [ -z "${QUEUE_MAX:-}" ]; then QUEUE_MAX=$qm_def   # unset or empty: the default, silently
elif ! [[ "$QUEUE_MAX" =~ ^[0-9]{1,9}$ ]] || [ "$((10#$QUEUE_MAX))" -lt "$qm_min" ] || [ "$((10#$QUEUE_MAX))" -gt "$qm_max" ]; then
  log WARN null "" false null "QUEUE_MAX='$QUEUE_MAX' is not a whole number from $qm_min to $qm_max; using $qm_def"
  echo "escalate.sh: warning: QUEUE_MAX='$QUEUE_MAX' is not a whole number from $qm_min to $qm_max; using $qm_def" >&2; QUEUE_MAX=$qm_def
else QUEUE_MAX=$((10#$QUEUE_MAX)); fi

prompt="$STATE/prompt-$(date -u +%Y%m%dT%H%M%SZ)-$card-$$.txt"
{ nolink "$prompt" && nolink "$prompt.err"; } || refuse STATE_LINK 2 "the prompt file of this call in the state folder is a link"
cat >"$prompt"
[ -s "$prompt" ] || { rm -f "$prompt"; refuse USAGE 2 "prompt required on stdin"; }

# The resolver serves the rung (F2b item D; the CLI logs the skipped rungs). It runs only on exit 0 with a usable served rung and no
# code (E-DC-06); no other rung is ever asked (E-DC-02). A cooldown queues; no rung left goes to the owner; a refusal of the
# environment or the data, an answer this script cannot read, or an event-log code is exit 2; every other refusal is exit 3. Only the
# cooldown and the owner keep the prompt.
gone() { rm -f "$prompt"; refuse "$@"; }
res=$(python3 -I /workspace/bin/resolve.py resolve --role "$role" --project "$project" --card "$card" ${driver:+--driver "$driver"} --rung "$rung" --json 2>"$prompt.err"); rrc=$?
rerr=$(head -c 4000 "$prompt.err"); rm -f "$prompt.err"
IFS=$'\t' read -r rcode served status conn model rwhy < <(jq -r 'select(type == "object") | [.code // "-", (.rung.served // "-" | tostring),
  (.rung.link.status // "-"), (.rung.link.connection // "-"), (.rung.link.model // "-"), ((.reason // "-") | tostring | gsub("[\t\n]"; " ") | .[:300])] | @tsv' <<<"$res" 2>/dev/null)
skipped=$(jq -r '[.rung.skipped[]? | "rung \(.rung) \(.connection)/\(.model) \(.status) \(.code // "-")"] | join("; ")' <<<"$res" 2>/dev/null)
[ "$conn" != - ] || conn=""; [ "$model" != - ] || model=""
case "${rcode:-}" in
  "") c=$(grep -om1 'STL-[A-Z]*-[0-9]*' <<<"$rerr"); gone RESOLVER 2 "${c:-STL-MDL-710} the resolver gave no answer this script can read (exit $rrc): $(grep -m1 -- "${c:-STL-}" <<<"$rerr" | head -c 300)" ;;
  -) [ "$rrc" = 0 ] && [ "$served" != - ] && [ "$status" = usable ] && [ -n "$conn" ] && [ -n "$model" ] \
       || gone RESOLVER 2 "STL-MDL-710 the resolver's answer (exit $rrc) serves no usable rung $rung of role $role and names no code" ;;
  STL-MDL-731)
    queue OWNER "STL-MDL-731 rung $rung of role $role: $rwhy"
    why="STL-MDL-731 no rung left for card $card ($purpose, role $role, rung $rung): $rwhy${skipped:+; skipped: $skipped}${qnote:+; $qnote}"
    log OWNER 4 none false null "$why"
    hermes send --to "$ALERT_TARGET" --quiet "$(alert_text STL-MDL-731 problem="card $card, purpose $purpose, role $role, rung $rung: $rwhy; $qnote")" >/dev/null 2>&1
    note "escalate.sh OWNER: $why. Escalate to the owner: nothing was run."
    echo "escalate.sh: OWNER: $why" >&2
    exit 4 ;;
  STL-MDL-724) limit "STL-MDL-724 rung $served of role $role ($conn/$model) is in cooldown: $rwhy (no other rung is tried)" ;;
  STL-CFG-*|STL-EVT-*) gone RESOLVER 2 "$rcode the resolver refused rung $rung of role $role: $rwhy" ;;
  *) gone NO_RUNG 3 "$rcode the resolver serves no usable rung $rung of role $role for card $card: $rwhy${skipped:+; skipped: $skipped} (not queued, no other rung is tried)" ;;
esac
log RUNG null "" false null "rung asked $rung, served $served: $conn/$model${skipped:+; skipped: $skipped}"
# The served link is data: its connection must have this script's CLI (E-DC-02, its own code); its model's limits are the catalog's.
link=$(jq -c --arg c "$conn" --arg m "$model" '[.entries[] | select(.kind == "provider" and .id == $c) | {cli, limits: ([.models[]? | select(.id == $m) | .limits][0] // {})}][0] // empty' <<<"$catalog" 2>/dev/null)
cli=$(jq -r '.cli | strings' <<<"$link" 2>/dev/null)
[ "$cli" = "$CLI" ] || gone NOT_THIS_CLI 3 "STL-MDL-746 rung $served of role $role is $conn/$model, whose connection runs on ${cli:-no CLI}, not on this script's ($CLI): not run, not queued, no other rung is tried"
if lim purposes; then [[ " $L " == *" $purpose "* ]] || gone LIMIT 3 "$model (rung $served of role $role) is allowed only for: $L (not queued, no other rung is tried)"; fi
cli_model=$(jq -r --arg p "$purpose" --arg m "$model" '(.limits.purpose_models[$p]? | strings) // $m' <<<"$link")
# One trusted event line per served rung (E-DC-05): card, purpose, role, rung, from (the role's rung-0 head, asked through the
# import, which writes no log) and to; finding ids are the QA loop's (3c). A line that cannot be written: nothing runs.
evcode=$(python3 -I -c 'import sys; sys.path.insert(0, "/workspace/bin"); import resolve, event_log as el
card, purpose, role, rung, served, conn, model, project, driver, reason, skipped = sys.argv[1:]
try:
    ch = resolve.resolve({"role": role, "project": project, "card": card, "driver": driver or None})["chain"]
    head = "%s/%s" % (ch[0]["connection"], ch[0]["model"]) if ch else "none"
except Exception:
    head = "unknown"
try:
    el.append(el.build("escalate.rung-served", f"card {card} rung {served} of role {role}", who={"role": role}, detail=el.scrub(
        f"card {card}, purpose {purpose}, role {role}, rung asked {rung}, rung served {served}, from {head}, to {conn}/{model}, skipped [{skipped}], reason {reason}")))
except Exception as e:
    print(getattr(e, "code", "STL-CFG-318"), type(e).__name__)
    sys.exit(1)' "$card" "$purpose" "$role" "$rung" "$served" "$conn" "$model" "$project" "$driver" "${reason:0:300}" "$skipped" 2>/dev/null) \
  || gone EVENT_LOG 2 "${evcode:-STL-CFG-318} the trusted event line of rung $served of role $role could not be written: the model is not run, nothing is queued"

mkey=${model//[^A-Za-z0-9._-]/_}   # the model id as a file name of the state folder
if lim max_concurrent; then
  got=""
  for i in $(seq 1 "$L" 2>/dev/null); do
    lk="$STATE/$mkey.$i.lock"; nolink "$lk" || continue
    exec 8>>"$lk"
    flock -n 8 && { got=1; break; }
  done
  [ -n "$got" ] || limit "no $model slot free (max_concurrent=$L)"
fi
if lim per_day; then
  counter="$STATE/$mkey-$(date -u +%F).count"
  lk="$STATE/$mkey.lock"; { nolink "$lk" && nolink "$counter"; } || limit "the lock or counter of the daily limit in the state folder is a link"
  exec 7>>"$lk"
  flock 7
  n=$(cat "$counter" 2>/dev/null || echo 0)
  [ "$n" -lt "$L" ] 2>/dev/null || { flock -u 7; limit "$model daily limit reached ($n/$L for $(date -u +%F))"; }
  echo $((n + 1)) >"$counter"
  flock -u 7
fi

log START null
if [ "${ESCALATE_FORCE_POOL_EXHAUSTED:-}" = 1 ]; then
  out="" err="You've hit your session limit (forced by ESCALATE_FORCE_POOL_EXHAUSTED)" rc=1
else
  out=$(timeout "$CALL_TIMEOUT" claude -p --model "$cli_model" --output-format json \
    --max-budget-usd "$MAX_BUDGET_USD" "$@" <"$prompt" 2>"$prompt.err")
  rc=$?
  err=$(cat "$prompt.err"); rm -f "$prompt.err"
fi

for p in "${POOL_PATTERNS[@]}"; do
  [[ "$out$err" == *"$p"* ]] || continue
  alert_rc=none
  log POOL_EXHAUSTED "$rc" none false null "matched '$p'; not rerouted (an escalation rung never goes to the fallback runner)"
  queue POOL_EXHAUSTED "pool exhausted at $(date -u +%FT%TZ) (matched '$p')"   # the one #alerts line for this call
  note "escalate.sh POOL_EXHAUSTED: $model ($purpose) for '$reason'. No result. model_used: none, fallback: false. Not rerouted (an escalation rung never is); $qnote. Alert to $ALERT_TARGET exit $alert_rc."
  echo "escalate.sh: POOL_EXHAUSTED ($p); not rerouted; $qnote" >&2
  exit 75
done

model_used=$(jq -r '.modelUsage // {} | keys | join(",")' <<<"$out" 2>/dev/null)
cost=$(jq -r '.total_cost_usd // "null"' <<<"$out" 2>/dev/null) || cost=null
# exit 0 counts only with a parseable, non-error result
[ "$rc" -eq 0 ] && ! jq -e '.is_error == false' <<<"$out" >/dev/null 2>&1 && rc=1
if [ "$rc" -ne 0 ]; then
  # W5-VER7-01: on a replay the drain leaves these two exit codes queued; the note, the log line and stderr say the same
  ns=FAIL; [ -z "${ESCALATE_REPLAY:-}" ] || [[ $rc != 12[67] ]] || { ns="the model command did not start (exit $rc); left in the queue as $ESCALATE_REPLAY"; err="$ns: $err"; }
  log FAIL "$rc" "${model_used:-unknown}" false "${cost:-null}" "$(head -c 300 <<<"$out$err")"
  note "escalate.sh $ns: $model ($purpose) exit $rc for '$reason'. model_used: ${model_used:-unknown}, fallback: false."
  rm -f "$prompt"   # F16: kept only while a queue entry points at it
  printf '%s\n' "$out"; printf '%s\n' "$err" >&2
  exit "$rc"
fi
log OK 0 "$model_used" false "$cost"
note "escalate.sh OK: $model ($purpose) for '$reason'. model_used: $model_used, fallback: false, cost_usd: $cost."
rm -f "$prompt"
printf '%s\n' "$out"
