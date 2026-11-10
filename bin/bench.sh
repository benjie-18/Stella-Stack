#!/usr/bin/env bash
# Benchmark suite (R1.4, Stage 6 T10). Tasks live in bench/tasks/<id>/ (task.json, repo/ = red start, solution/ = reference
# overlay). Commands:
#   bench.sh list [--subset]            task ids
#   bench.sh check                      every task is red at its start and green with its solution (hermetic)
#   bench.sh reset <id> <repo> | verify <repo> <branch> <id> | settle <pid> <s> | pid <card>   the two steps of `run`, on their own (hermetic tests)
#   bench.sh metrics <card>             JSON {card,status,wall_s,retries,escalations,cost_usd} from the board + escalations log
#   bench.sh run <id|--subset> --worker <profile> --project <slug> [--timeout <s>]
#                                       reset the project's repo to the task start, create the card, wait, then check the
#                                       card branch with the task's original test files; one JSON line per task appended to
#                                       .scratch/bench/results.jsonl. success = the branch passes the check AND the card reached
#                                       review/done (a card the worker had to block needed a human: check_pass alone is not success).
#                                       The project must be bound to .scratch/bench/repo.
# Worker and project are arguments: no profile or project name lives in this script.
set -u
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
W=/workspace; D=${BENCH_DIR:-$W/bench}; LOG=${ESCALATIONS_LOG:-$W/.supervisor/escalations.log}
OUT=${BENCH_OUT:-$W/.scratch/bench}
. "$W/bin/kanban-board.sh"
die() { echo "bench: $*" >&2; exit 1; }
tasks() { for f in "$D"/tasks/*/task.json; do [ -f "$f" ] && echo "$f"; done; }

nonce() { head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
# passes <dir> <check> <nonce> [boxed]: the check exits 0 AND its last output line is the nonce. The protected test prints the nonce
# (from $BENCH_NONCE) as its last act, so a branch that exits 0 before the test finishes passes nothing (S6C-06). Shortcut: code that
# reads $BENCH_NONCE and prints it on purpose still forges it; closing that needs the test to run outside the worker's process.
passes() {
  local dir=$1 chk=$2 n=$3 box=${4:-} out last
  out=$(mktemp) || return 1
  if [ -n "$box" ]; then
    bwrap --ro-bind / / --tmpfs /home --tmpfs /workspace --tmpfs /tmp --bind "$dir" "$dir" --dev /dev --proc /proc \
      --unshare-net --unshare-pid --unshare-ipc --unshare-uts --die-with-parent --chdir "$dir" --setenv BENCH_NONCE "$n" \
      timeout -k 3 "${BENCH_TIMEOUT:-60}" bash -c "ulimit -f 65536; $chk" >"$out" 2>/dev/null || { rm -f "$out"; return 1; }
  else
    (cd "$dir" && BENCH_NONCE=$n timeout -k 3 "${BENCH_TIMEOUT:-60}" bash -c "ulimit -f 65536; $chk") >"$out" 2>/dev/null || { rm -f "$out"; return 1; }
  fi
  last=$(grep -v '^[[:space:]]*$' "$out" | tail -n 1); rm -f "$out"; [ "$last" = "$n" ]
}
alive() { [ -r "/proc/$1/stat" ] && [ "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" != Z ]; }
settle() {  # settle <pid> <max s>: wait until the worker process has exited (a worker can keep committing after it blocked its card)
  local pid=${1:-} max=${2:-300} i=0
  [ -n "$pid" ] || return 0
  while alive "$pid"; do [ "$i" -lt "$max" ] || return 1; sleep 1; i=$((i+1)); done
  return 0
}

check() {
  local n=0 s=0 f id t rc bad=0
  [ "$(jq -r '.missing|type' "$D/suite.json" 2>/dev/null)" = array ] || die "suite.json: missing must be a list"
  for f in $(tasks); do
    id=$(basename "$(dirname "$f")"); n=$((n+1))
    jq -e --arg id "$id" '.id==$id and (.category|type=="string") and (.title|type=="string") and (.body|type=="string")
      and ((.check|type=="string") and .check!="") and (.protected|type=="array") and (.subset|type=="boolean")' "$f" >/dev/null \
      || { echo "FAIL $id: task.json is missing a field or its id differs from the folder"; bad=1; continue; }
    [ "$(jq -r .subset "$f")" = true ] && s=$((s+1))
    t=$(mktemp -d); cp -a "$(dirname "$f")/repo/." "$t/"
    chk=$(jq -r .check "$f")
    passes "$t" "$chk" chk-nonce-1 && { echo "FAIL $id: the check already passes before any work"; bad=1; }
    cp -a "$(dirname "$f")/solution/." "$t/"
    passes "$t" "$chk" chk-nonce-2 || { echo "FAIL $id: the reference solution does not pass the check (exit 0 and the nonce as its last line)"; bad=1; }
    rm -rf "$t"
  done
  [ "$n" -gt 0 ] || die "no tasks in $D/tasks"
  [ "$bad" = 0 ] || exit 1
  echo "$n tasks, $s in the subset"
}

metrics() {
  local c=${1:-}; [[ $c =~ ^t_[0-9a-f]+$ ]] || die "metrics needs a card id (t_...)"
  local b esc=0 cost=0
  b=$(kanban show "$c" --json) || die "cannot read card $c"
  if [ -r "$LOG" ]; then
    esc=$(jq -rs --arg c "$c" '[.[]|select(.card==$c and .event=="START")]|length' "$LOG") || die "cannot read $LOG"
    cost=$(jq -rs --arg c "$c" '[.[]|select(.card==$c)|.cost_usd//0]|add//0' "$LOG") || die "cannot read $LOG"
  fi
  jq -c --argjson e "$esc" --argjson k "$cost" '.task.assignee as $a | {card:.task.id, status:.task.status,
    wall_s: ((.task.completed_at // ([.runs[].ended_at]|map(select(.))|max) // now|floor) - .task.created_at),
    retries: ([[.runs[]|select(.profile==$a)]|length-1, 0]|max), escalations:$e, cost_usd:$k}' <<<"$b"
}

reset_repo() {  # reset_repo <id> <repo>: main = the task's start commit. Card worktrees stay out of it (.worktrees/ is excluded) and untouched.
  local id=$1 repo=$2
  mkdir -p "$repo" && { [ -d "$repo/.git" ] || git -C "$repo" init -q -b main; }
  grep -qxF '.worktrees/' "$repo/.git/info/exclude" 2>/dev/null || echo '.worktrees/' >>"$repo/.git/info/exclude"
  git -C "$repo" checkout -q main && git -C "$repo" rm -rqf --ignore-unmatch . && git -C "$repo" clean -fdxq \
    && cp -a "$D/tasks/$id/repo/." "$repo/" && git -C "$repo" add -A \
    && git -C "$repo" -c user.name=bench -c user.email=bench@localhost commit -qm "bench: $id start" --allow-empty || die "cannot reset $repo"
}

verify_branch() {  # verify_branch <repo> <branch> <id>: exit 0 if the branch passes the task's check. The worker's code runs boxed:
  # read-only system, no home, no /workspace, no network, writes only in its own temp folder, killed after BENCH_TIMEOUT s (TERM,
  # then KILL), file size capped (shortcut: plain bwrap, not box.py; upgrade if the check ever needs the network or a tool outside
  # /usr). A symlink anywhere in the branch is refused (a copy of a protected test file would write through it), and so is a
  # protected path that is not a plain file in the branch (a folder of that name would run the worker's code in the test's place).
  local repo=$1 br=$2 id=$3 f="$D/tasks/$3/task.json" tmp x rc=1 chk
  chk=$(jq -r .check "$f"); tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' EXIT TERM INT
  if git -C "$repo" archive "$br" 2>/dev/null | tar -x --no-same-owner -C "$tmp" && ! find "$tmp" -type l | grep -q .; then
    rc=0
    for x in $(jq -r '.protected[]' "$f"); do
      if [ -e "$tmp/$x" ] && [ ! -f "$tmp/$x" ]; then echo "bench: protected path $x is not a plain file in the branch: refused" >&2; rc=1; break; fi
      { rm -f "$tmp/$x" && mkdir -p "$(dirname "$tmp/$x")" && cp "$D/tasks/$id/repo/$x" "$tmp/$x"; } || { rc=1; break; }
    done
    if [ "$rc" = 0 ]; then rc=1; passes "$tmp" "$chk" "$(nonce)" boxed && rc=0; fi
  else echo "bench: the branch cannot be unpacked, or holds a symlink: refused" >&2; fi
  rm -rf "$tmp"; trap - EXIT TERM INT; return $rc
}

worker_pid() {  # worker_pid <card>: the newest worker_bound event's pid (Hermes does not fill runs[].worker_pid); empty if none
  kanban show "$1" --json 2>/dev/null | jq -r '[.events[]? | select(.kind == "worker_bound") | .payload.pid | select(. != null)] | last // empty'
}

run_one() {  # run_one <id> <worker> <project> <timeout>
  local id=$1 w=$2 p=$3 to=$4 f="$D/tasks/$1/task.json" repo=$OUT/repo card st t0 m ok=false br tmp
  [ -f "$f" ] || die "no task $id"
  hermes project show "$p" 2>/dev/null | awk -v r="$repo" '$1 == "primary:" && $2 == r { f = 1 } END { exit !f }' || die "project '$p' is not bound to $repo (hermes project create ... --primary $repo --board <board>)"
  reset_repo "$id" "$repo"
  t0=$(date +%s)
  card=$(kanban create "$(jq -r .title "$f")" --assignee "$w" --project "$p" --workspace worktree \
    --body "$(jq -r .body "$f")"$'\n\n'"Check: $(jq -r .check "$f")" --json | jq -r '.id // .task.id') || die "cannot create the card"
  [[ $card =~ ^t_[0-9a-f]+$ ]] || die "no card id from kanban create"
  while :; do
    st=$(kanban show "$card" --json | jq -r .task.status)
    case $st in todo|ready|running|triage|scheduled|queued) ;; *) break;; esac
    [ $(( $(date +%s) - t0 )) -lt "$to" ] || { st=timeout; break; }
    sleep 15
  done
  settle "$(worker_pid "$card")" 300 || echo "bench: the worker of $card was still running after 300 s; measured anyway" >&2   # before anything is read
  st=$(kanban show "$card" --json | jq -r .task.status)
  m=$(metrics "$card") || m="{\"card\":\"$card\"}"
  br=$(kanban show "$card" --json | jq -r '.task.branch_name // empty')
  [ -z "$br" ] || { verify_branch "$repo" "$br" "$id" && ok=true; }   # the task's own test files go over the tip
  jq -nc --arg task "$id" --argjson m "$m" --argjson ok "$ok" --arg st "$st" --argjson w "$(( $(date +%s) - t0 ))" \
    '$m + {task:$task, check_pass:$ok, success:($ok and ($st|IN("review","done","archived"))), final_status:$st, waited_s:$w}' | tee -a "$OUT/results.jsonl"
}

case ${1:-} in
  list) for f in $(tasks); do [ "${2:-}" != --subset ] || [ "$(jq -r .subset "$f")" = true ] && basename "$(dirname "$f")"; done;;
  check) check;;
  reset) reset_repo "${2:-}" "${3:-}";;
  pid) worker_pid "${2:-}";;
  settle) settle "${2:-}" "${3:-300}";;
  verify) verify_branch "${2:-}" "${3:-}" "${4:-}";;
  metrics) metrics "${2:-}";;
  run) shift; sel=${1:-}; shift || true; w= p= to=1800
    while [ $# -gt 0 ]; do case $1 in --worker) w=${2:-}; shift 2;; --project) p=${2:-}; shift 2;; --timeout) to=${2:-}; shift 2;; *) die "unknown option $1";; esac; done
    [ -n "$w" ] && [ -n "$p" ] || die "run needs --worker and --project"
    mkdir -p "$OUT"
    for id in $( [ "$sel" = --subset ] && "$0" list --subset || echo "$sel" ); do run_one "$id" "$w" "$p" "$to"; done;;
  *) sed -n '2,13p' "$0"; exit 2;;
esac
