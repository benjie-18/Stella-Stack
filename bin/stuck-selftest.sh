#!/usr/bin/env bash
# Hermetic self-test for stuck detection (F3 item S; body B10, AC9; design section 8, 3c and "Re-plan 19:08").
# Every section runs in its own scratch root (bash stuck-selftest.sh <section>); no argument runs them all.
# Sections -> checks: patterns = T-STUCK-PATTERNS (each kind at its per-role threshold, and not one under) | loop = AC9-stuck
#   (detection of a planted edit-revert loop with its evidence; the stop, block and lease part is proven once item A merges)
#   fix = Gate B fix cycle 1: RT3-03 (revert to any earlier digest; notes file not in the digest), RT3-05 (repeat_error needs the same action),
#   V2-06 (watcher ends on the run record, not on a result event), V2-07 (block argv through the board wrapper, a kind board.md documents)
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
SECTIONS="patterns loop fix"
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
    for i in range(n): call("shell", {"cmd": "pytest -k qa"}, ok=False, output="Error: QA same failure")
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
# gen2.py <run> digests d0 d1 ...: one edit tool result per digest name | errors <n> <same>: n failing shell results with empty output, the same action or n different ones
cat >"$T/gen2.py" <<'PYG'
import hashlib, json, sys
run, mode, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
out = []
def h(x): return hashlib.sha256(x.encode()).hexdigest()
def add(i, name, inp, ok, diff=None):
    s = h(name + json.dumps(inp, sort_keys=True))
    out.append({"seq": 2 * i + 1, "run": run, "type": "tool_use", "name": name, "input": inp, "signature": s})
    out.append({"seq": 2 * i + 2, "run": run, "type": "tool_result", "name": name, "input": inp, "ok": ok, "output": "", "signature": s, **({"diff": h(diff)} if diff else {})})
if mode == "digests":
    for i, d in enumerate(rest): add(i, "edit", {"path": "f", "step": i}, True, d)
else:
    n, same = int(rest[0]), rest[1] == "same"
    for i in range(n): add(i, "shell", {"cmd": "test -f x" if same else "test -f x%d" % i}, False)
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
fix)   # Gate B fix cycle 1
  # RT3-03: a three-state cycle (d0 d1 d2 d0 ...) is a revert to an earlier digest, not only two steps back; one pass over it is not yet a loop; steady progress never is
  python3 -I "$T/gen2.py" qa-rt303 digests d0 d1 d2 d0 d1 d2 d0 d1 d2 d0 d1 d2 d0 >"$T/cyc.jsonl"; run c1 SC "$T/cyc.jsonl"
  ok '[ $RC != 2 ] && matched c1 edit_revert' "RT3-03 a three-state cycle repeated four times is a match of kind edit_revert"
  python3 -I "$T/gen2.py" qa-rt303 digests d0 d1 d2 d0 >"$T/cyc1.jsonl"; run c2 SC "$T/cyc1.jsonl"
  ok '[ $RC != 2 ] && [ -s "$T/o/c2.out" ] && ! matched c2 edit_revert' "RT3-03 one return to the first digest after two other states is one revert: no match"
  python3 -I "$T/gen2.py" qa-rt303 digests d0 d1 d2 d3 d4 d5 d6 d7 d8 d9 d10 >"$T/prog.jsonl"; run c3 SC "$T/prog.jsonl"
  ok '[ $RC != 2 ] && [ -s "$T/o/c3.out" ] && ! matched c3 edit_revert' "RT3-03 steady progress (every digest new) is no match"
  # RT3-03: the working-notes file is not part of the progress digest (adapter.py Stream.diff), so notes written between edits cannot hide a revert
  python3 -I - "$R/bin" "$T/nwt" >"$T/o/notes" 2>&1 <<'PYN'
import os, subprocess, sys
sys.path.insert(0, sys.argv[1]); import adapter
wt = sys.argv[2]; os.makedirs(wt)
g = lambda *a: subprocess.run(["git", "-C", wt, "-c", "user.name=q", "-c", "user.email=q@q", *a], check=True, capture_output=True)
g("init", "-q"); open(wt + "/README", "w").write("base\n"); g("add", "."); g("commit", "-qm", "b")
base = subprocess.run(["git", "-C", wt, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
s = adapter.Stream.__new__(adapter.Stream); s.rec = {"worktree": wt, "base": base, "notes": ".stella/notes/qa-run.md"}
d0 = s.diff()
os.makedirs(wt + "/.stella/notes"); open(wt + "/.stella/notes/qa-run.md", "w").write("## done\n- 1\n"); d1 = s.diff()
open(wt + "/.stella/notes/qa-run.md", "w").write("## done\n- 1\n- 2\n"); d2 = s.diff()
open(wt + "/README", "w").write("base1\n"); d3 = s.diff()
open(wt + "/README", "w").write("base\n"); d4 = s.diff()
open(wt + "/other.txt", "w").write("x"); d5 = s.diff()
print(d0 == d1 == d2 == d4, d3 != d0, d5 != d0)
PYN
  ok 'grep -qx "True True True" "$T/o/notes"' "RT3-03 the notes file (rec.notes) is left out of the diff digest: notes edits keep it, a README edit and an untracked file change it, a revert restores it"
  # RT3-05: repeat_error is the same action with the same error, not the same (here empty) output of different actions
  python3 -I "$T/gen2.py" qa-rt305 errors 3 diff >"$T/e1.jsonl"; run e1 SC "$T/e1.jsonl"
  ok '[ $RC != 2 ] && [ -s "$T/o/e1.out" ] && ! matched e1 repeat_error' "RT3-05 three different actions that fail with the same empty output are no match of repeat_error"
  python3 -I "$T/gen2.py" qa-rt305 errors 3 same >"$T/e2.jsonl"; run e2 SC "$T/e2.jsonl"
  ok '[ $RC != 2 ] && matched e2 repeat_error' "RT3-05 the same action failing with the same output three times is still a match of repeat_error"
  # the watcher and the block (V2-06, V2-07): stop argv replaced by a no-op, hermes a stub that records its argv one word per line
  RUNS=$R/$(ix .adapter_runs); mkdir -p "$RUNS"
  ed .stella/stuck.json '.poll_s = 0.2 | .stop.argv = ["true"]'
  printf '#!/usr/bin/env bash\ncase " $* " in *" block "*) printf "%%s\\n" "$@" >>"%s";; esac\necho "[]"\n' "$T/hermes.argv" >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; : >"$T/hermes.argv"
  WA() { python3 -I "$R/bin/stuck.py" watch --run "$1" --card t_00000001 --role "$ROLE" --events "$2"; }
  # V2-06: a result event in mid-run (a CLI's text part) does not end the watch; the loop after it is still found
  echo '{"run":"qa-w1","ended":null}' >"$RUNS/qa-w1.json"
  python3 -I "$T/gen2.py" qa-w1 digests d0 >"$T/w1.jsonl"; echo '{"seq":9,"run":"qa-w1","type":"result","name":null,"output":"text part"}' >>"$T/w1.jsonl"
  ( WA qa-w1 "$T/w1.jsonl" >"$T/o/w1.out" 2>"$T/o/w1.err"; echo $? >"$T/o/w1.rc" ) &
  sleep 1.5
  ok '[ ! -e "$T/o/w1.rc" ]' "V2-06 the watcher is still running after a result event while the run record says the run has not ended"
  python3 -I "$T/gen2.py" qa-w1 digests d0 d1 d0 d1 d0 d1 d0 d1 d0 | tail -n +3 >>"$T/w1.jsonl"
  for i in $(seq 40); do [ -e "$T/o/w1.rc" ] && break; sleep 0.25; done
  ok '[ "$(cat "$T/o/w1.rc")" = 0 ] && grep -q "^block$" "$T/hermes.argv" && grep -q edit_revert "$T/o/w1.out"' "V2-06 the loop that came after the result event is found: the card is blocked"
  # the block argv, exactly: the board wrapper adds the board; the kind is one board.md documents; the reason is the last word
  BOARD=$(. "$R/bin/kanban-board.sh"; echo "$KANBAN_BOARD"); KINDS_DOC=$(sed -n 's/.*kanban_block kind \([a-z_|]*\).*/\1/p' "$R/docs/hermes-local/board.md" | head -n1)
  ok '[ -n "$BOARD" ] && [ "$(sed -n 1,7p "$T/hermes.argv" | tr "\n" " ")" = "kanban --board $BOARD block t_00000001 --kind needs_input " ] && [ "$(sed -n 8p "$T/hermes.argv" | cut -c1-20)" = "stuck: edit_revert (" ] && [ "$(wc -l <"$T/hermes.argv")" = 8 ]' \
    "V2-07 the block argv is: hermes kanban --board <board> block <card> --kind needs_input <reason> (got: $(tr '\n' ' ' <"$T/hermes.argv" | cut -c1-110))"
  ok '[ -n "$KINDS_DOC" ] && case "|$KINDS_DOC|" in *"|$(jq -r .block.kind "$SJ")|"*) true;; *) false;; esac' "V2-07 the block kind in stuck.json is one of the kinds board.md documents ($KINDS_DOC)"
  # V2-06: once the run record says the run ended, the watcher ends (exit 0, no block) even with no result event in the stream
  python3 -I "$T/gen2.py" qa-w2 digests d0 d1 >"$T/w2.jsonl"; echo '{"run":"qa-w2","ended":null}' >"$RUNS/qa-w2.json"; : >"$T/hermes.argv"
  ( WA qa-w2 "$T/w2.jsonl" >"$T/o/w2.out" 2>"$T/o/w2.err"; echo $? >"$T/o/w2.rc" ) &
  sleep 1; echo '{"run":"qa-w2","ended":"2026-11-19T00:00:00Z","exit":0}' >"$RUNS/qa-w2.json"
  for i in $(seq 20); do [ -e "$T/o/w2.rc" ] && break; sleep 0.25; done
  ok '[ "$(cat "$T/o/w2.rc")" = 0 ] && [ ! -s "$T/hermes.argv" ]' "V2-06 the watcher ends with exit 0 and no block once the run record has an end time"
  ;;
esac
finish
