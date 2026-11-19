#!/usr/bin/env bash
# Hermetic self-test for stuck detection (F3 item S; body B10, AC9; design section 8, 3c and "Re-plan 19:08").
# Every section runs in its own scratch root (bash stuck-selftest.sh <section>); no argument runs them all.
# Sections -> checks: patterns = T-STUCK-PATTERNS (each kind at its per-role threshold, and not one under) | loop = AC9-stuck
#   (detection of a planted edit-revert loop with its evidence; the stop, block and lease part is proven once item A merges)
# CLI contract: bin/stuck.py scan FILE --role R --json. Events files are planted in the pinned 3c stream format.
# Written test-first (F3 wave 2): the JSON answer and exit codes are asserted, never wording.
# ASSUMPTIONS (names the design leaves open):
#  A1 .stella/stuck.json: the kinds repeat_action, repeat_error, alternate, edit_revert, tokens_no_diff; the threshold of kind K for
#     role R is the one number at a path that holds both K and R, else the one number at a path that holds K and "default".
#  A2 what a threshold N counts: repeat_action N identical tool calls in a row (same signature); repeat_error N failing tool results
#     in a row with the same output; alternate N tool calls in a row alternating between two signatures (A B A B ...); edit_revert N
#     edit-revert cycles (an edit, then a call whose diff is back to the diff before that edit); tokens_no_diff N tokens (input + output of the usage
#     lines) since the diff last changed.
#  A3 scan --json answers with its matches; a match is a JSON object that holds its kind id as a value (and no other object of the
#     answer holds a kind id); the match carries the matching events (their seq numbers) as evidence. Exit: 0 or 1, never 2.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=stuck-selftest
SECTIONS="patterns loop"
if [ $# = 0 ]; then
  f=0; for s in $SECTIONS; do bash "${BASH_SOURCE[0]}" "$s" || f=$((f+1)); done
  [ $f = 0 ] && echo "$ME PASS" || echo "$ME FAIL ($f sections)"; [ $f = 0 ]; exit
fi
case " $SECTIONS " in *" $1 "*) ;; *) echo "usage: $ME.sh [$(tr ' ' '|' <<<"$SECTIONS")]" >&2; exit 2;; esac
S=$1
# ---- harness: a scratch root of its own (bin, .stella, docs and the root config files copied), its own HOME, temp, alert folder ----
T=$(mktemp -d "${TMPDIR:-/tmp}/$ME.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'kill $(jobs -p) 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "# KEPT $T"; else chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; fi' EXIT
R=$T/root
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$R/.claude" "$T/home" "$T/tmp" "$T/sup/logs" "$T/pb" "$T/o"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"
for f in opencode.json .mcp.json .claude/settings.json .claude/skills; do [ -e "$ROOT/$f" ] && cp -r "$ROOT/$f" "$R/$f"; done
cd "$T" || exit 1
jq() { env -u HOME jq "$@"; }
IX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IX"; }
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$ROOT/$(ix .role_table)" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
POL=$R/$(ix '.files[] | select(.id == "owner-auth") | .path')
for v in $(jq -r '.worker_signals.token_env[]?' "$POL" 2>/dev/null); do unset "$v"; done
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH
AL=$T/sup/logs/alerts.log; : >"$AL"
EV=$R/$(ix .event_log)
IID=$(jq -r .install_id "$R/.stella/install.json")
fails=0; n=0
# ok <test> <label>: a FAIL line (never a crash) with the last output of the case under it
ok() { n=$((n+1)); if ( set -o pipefail; eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/o/last" ] && tail -n 3 "$T/o/last" | cut -c1-240 | sed 's/^/     | /'; fi; : >"$T/o/last"; }
finish() { echo "# $ME $S: $n cases, $fails failed"; [ "$fails" = 0 ]; exit $?; }
# run <tag> <cmd...>: stdout to $T/o/<tag>.out, stderr to $T/o/<tag>.err, exit code in RC
run() { local t=$1; shift; "$@" >"$T/o/$t.out" 2>"$T/o/$t.err"; RC=$?; cat "$T/o/$t.out" "$T/o/$t.err" >"$T/o/last" 2>/dev/null; }
out() { cat "$T/o/$1.out" "$T/o/$1.err" 2>/dev/null; }
ed() { local f=$R/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <file under the root> <jq args and filter>
uuid() { cat /proc/sys/kernel/random/uuid; }
nl() { if [ -f "$1" ]; then wc -l <"$1"; else echo 0; fi; }   # line count of a file that may not exist yet
WORKER() { env STUB_WORKER_MARK=1 "$@"; }   # a worker environment (a roles.json worker marker)

SJ=$R/.stella/stuck.json
ROLE=$(jq -r '.roles | keys[0]' "$RJ")
KINDS="repeat_action repeat_error alternate edit_revert tokens_no_diff"
th() { jq -r --arg k "$1" --arg r "$ROLE" '[paths(type == "number") as $p | {p: ($p | map(tostring)), v: getpath($p)} | select(.p | index($k))] as $c
  | (($c | map(select(.p | index($r)))) + ($c | map(select(.p | index("default")))))[0].v // empty' "$SJ" 2>/dev/null; }
cat >"$T/gen.py" <<'PYG'
import hashlib, json, sys
# gen.py <kind> <n> <run>: a 3c events file on stdout holding n of that kind's pattern (A2), every other line inert
kind, n, run = sys.argv[1], int(sys.argv[2]), sys.argv[3]
out, seq = [], [0]
def sig(name, inp): return hashlib.sha256((name + json.dumps(inp, sort_keys=True, separators=(",", ":"))).encode()).hexdigest()
def add(**e):
    seq[0] += 1; out.append(dict({"seq": seq[0], "at": "2026-11-19T00:00:%02dZ" % (seq[0] % 60), "run": run, "name": None}, **e))
def call(name, inp, ok=True, output="ok", diff="d0"):
    s = sig(name, inp)
    add(type="tool_use", name=name, input=inp, signature=s)
    add(type="tool_result", name=name, ok=ok, output=output, diff=hashlib.sha256(diff.encode()).hexdigest(), signature=s)
if kind == "repeat_action":
    for i in range(n): call("shell", {"cmd": "ls qa"})
elif kind == "repeat_error":
    for i in range(n): call("shell", {"cmd": "pytest -k qa_%d" % i}, ok=False, output="Error: QA same failure")
elif kind == "alternate":
    for i in range(n): call("read", {"path": "qa_a.txt" if i % 2 == 0 else "qa_b.txt"})
elif kind == "edit_revert":
    call("read", {"path": "qa.txt"}, diff="d0")
    for i in range(n):   # one cycle: an edit, then its revert (the diff back to the one before the edit)
        call("edit", {"path": "qa.txt", "old": "a", "new": "b"}, diff="d1")
        call("edit", {"path": "qa.txt", "old": "b", "new": "a"}, diff="d0")
elif kind == "tokens_no_diff":
    call("read", {"path": "qa.txt"})
    add(type="usage", tokens={"input": n - n // 2, "output": n // 2})
add(type="result", name=None, output="done")
print("\n".join(json.dumps(e) for e in out))
PYG
SC() { python3 -I "$R/bin/stuck.py" scan "$1" --role "$ROLE" --json; }
# matched <tag> <kind>: the answer has an object holding the kind id as a value (a match of that kind)
matched() { [ -s "$T/o/$1.out" ] && jq -e --arg k "$2" '[.. | objects | select([.[]] | index($k) != null)] | length > 0' "$T/o/$1.out" >/dev/null 2>&1; }
missing=; for k in $KINDS; do [ -n "$(th "$k")" ] || missing="$missing $k"; done
ok '[ -f "$SJ" ] && [ -z "$missing" ] && python3 -I "$R/bin/stella_data.py" check' "precondition: stuck.json gives each kind a threshold for role $ROLE (missing:$missing) and the data checks"

case $S in
patterns)   # T-STUCK-PATTERNS: each kind detected at its per-role threshold, no false stop one under it
  for k in $KINDS; do
    N=$(th "$k"); N=${N:-0}; N=${N%.*}
    python3 -I "$T/gen.py" "$k" "$N" "qa-run-$k" >"$T/at-$k.jsonl"; python3 -I "$T/gen.py" "$k" $((N - 1)) "qa-run-$k-u" >"$T/under-$k.jsonl"
    run "at-$k" SC "$T/at-$k.jsonl"
    ok '[ "$N" -ge 2 ] && [ $RC != 2 ] && matched "at-$k" "$k"' "T-STUCK-PATTERNS $k at its threshold ($N) for $ROLE: a match of that kind"
    run "un-$k" SC "$T/under-$k.jsonl"
    ok '[ "$N" -ge 2 ] && [ $RC != 2 ] && [ -s "$T/o/un-$k.out" ] && ! matched "un-$k" "$k"' "T-STUCK-PATTERNS $k one under its threshold ($((N - 1))): no match of that kind"
  done
  ;;
loop)   # AC9-stuck (detection part): a planted edit-revert loop is detected with the matching events as evidence
  N=$(th edit_revert); N=${N:-0}; N=${N%.*}
  python3 -I "$T/gen.py" edit_revert $((N + 1)) qa-run-loop >"$T/loop.jsonl"
  run l1 SC "$T/loop.jsonl"
  ok '[ $RC != 2 ] && matched l1 edit_revert' "AC9-stuck the planted edit-revert loop ($((N + 1)) cycles) is a match of kind edit_revert"
  SEQS=$(jq -c -s '[.[] | select(.name == "edit") | .seq]' "$T/loop.jsonl")
  ok '[ -s "$T/o/l1.out" ] && jq -e --argjson s "$SEQS" "[.. | objects | select([.[]] | index(\"edit_revert\") != null) | .. | numbers] | map(select(. as \$x | \$s | index(\$x) != null)) | unique | length >= 2" "$T/o/l1.out"' \
    "AC9-stuck the match carries the loop's events (their seq numbers) as evidence"
  ;;
esac
finish
