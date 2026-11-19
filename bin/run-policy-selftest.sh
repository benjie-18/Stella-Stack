#!/usr/bin/env bash
# Hermetic self-test for the run policy (F3 item X1; body B7, B8, AC9, AC11; design section 7, 3c and "Re-plan 19:08").
# Every section runs in its own scratch root (bash run-policy-selftest.sh <section>); no argument runs them all.
# Sections -> checks: output = AC9-output-budget | filter = AC9-filter | lean = AC11-lean (data and translate part) | supports = T-SUPPORTS
# CLI contract (Re-plan 19:08): bin/run_policy.py check | translate --adapter A --role R | prefill --role R --tokens N |
# output-check --role R --events F; bin/log_filter.py [--role R] < log. Events files follow the pinned 3c stream format.
# Written test-first (F3 wave 2): exit codes, the code range STL-LIM-450..459 and the trusted event log are asserted, never wording.
# ASSUMPTIONS (names the design leaves open):
#  A1 .stella/run-policy.json holds one object per role (an object whose key is the role id) with output_budget_tokens and
#     core_tools (design section 7); the test role is the first role id of the role table that has such an object.
#  A2 output-check counts the output tokens of the usage lines (tokens.output); over the budget its output holds STL-LIM-45x and it
#     writes one trusted event line naming the run; under the budget: exit 0, no code, no line.
#  A3 log_filter keeps a line holding FAIL or an AssertionError/Traceback as a failing line, with the context the data's
#     trim_to_failing filter names (when that context is 1 or more, the line just before a failing line is kept).
#  A4 translate --json reads entries[].supports; its output names every capability id the role starts with (its core_tools), and
#     lists the features the adapter does not support under a key whose name holds "unsupported".
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=run-policy-selftest
SECTIONS="output filter lean supports"
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

RP=$R/.stella/run-policy.json
RPP() { python3 -I "$R/bin/run_policy.py" "$@"; }
# the first role of the role table with a per-role object in the run policy (A1), and that object's path
ROLE=$(jq -r --slurpfile rj "$RJ" '[paths(objects and has("output_budget_tokens")) | .[-1] | strings | select(. as $r | $rj[0].roles | has($r))][0] // empty' "$RP" 2>/dev/null)
RPATH=$(jq -c --arg r "$ROLE" '[paths(objects and has("output_budget_tokens")) | select(.[-1] == $r)][0] // empty' "$RP" 2>/dev/null)
ok '[ -n "$ROLE" ] && [ -n "$RPATH" ] && python3 -I "$R/bin/stella_data.py" check && RPP check' "precondition: the run policy has a per-role object (role ${ROLE:-none}) and passes the data check and run_policy.py check"
# ev <file> <run> <json list of [input, output]>: a 3c events file of usage lines
ev() { jq -c --arg r "$2" 'to_entries[] | {seq: (.key + 1), at: "2026-11-19T00:00:00Z", run: $r, type: "usage", name: null, tokens: {input: .value[0], output: .value[1]}}' <<<"$3" >"$1"; }

case $S in
output)   # AC9-output-budget: output over the role's budget is flagged (a code and one event line), not under it
  [ -n "$RPATH" ] && ed .stella/run-policy.json --argjson p "$RPATH" 'setpath($p + ["output_budget_tokens"]; 1000)'
  ev "$T/under.jsonl" qa-run-under '[[50, 300], [50, 300]]'; ev "$T/over.jsonl" qa-run-over '[[50, 600], [50, 600]]'
  e0=$(nl "$EV"); run u1 RPP output-check --role "$ROLE" --events "$T/under.jsonl"
  ok '[ $RC = 0 ] && ! out u1 | grep >/dev/null -E "STL-LIM-45[0-9]" && [ "$(nl "$EV")" = "$e0" ]' "AC9-output-budget 600 output tokens under a budget of 1000: exit 0, no code, no event line"
  run o1 RPP output-check --role "$ROLE" --events "$T/over.jsonl"
  ok '[ $RC != 2 ] && out o1 | grep >/dev/null -E "STL-LIM-45[0-9]"' "AC9-output-budget 1200 output tokens over 1000: flagged with STL-LIM-45x"
  ok '[ "$(nl "$EV")" = $((e0 + 1)) ] && tail -n1 "$EV" | grep >/dev/null qa-run-over' "AC9-output-budget ... and exactly one trusted event line naming the run"
  ;;
filter)   # AC9-filter: a long failing log reaches the model trimmed to the failing lines (+ context)
  { for i in $(seq 1 1500); do echo "ok $i - test_case_$i passed"; [ $((i % 100)) = 0 ] && echo "Downloading [=====>    ] 45% qa-progress"; done
    echo "not ok 1501 - test_zebra QA-CTX-BEFORE"; echo "FAIL test_zebra QA-FAIL-MARK-1"
    echo "Traceback (most recent call last):"; echo '  File "t.py", line 12, in test_zebra'; echo "AssertionError: QA-FAIL-MARK-2 expected 3 got 4"
    for i in $(seq 1502 3000); do echo "ok $i - test_case_$i passed"; done; } >"$T/long.log"
  CTX=$(jq -r '[.. | objects | select(.kind == "trim_to_failing") | .context | numbers][0] // 0' "$RP" 2>/dev/null)
  run f1 python3 -I "$R/bin/log_filter.py" --role "$ROLE" <"$T/long.log"
  ok '[ $RC = 0 ] && grep >/dev/null QA-FAIL-MARK-1 "$T/o/f1.out" && grep >/dev/null QA-FAIL-MARK-2 "$T/o/f1.out"' "AC9-filter the failing lines reach the output"
  ok '[ -s "$T/o/f1.out" ] && [ "$(wc -l <"$T/o/f1.out")" -lt $(( $(wc -l <"$T/long.log") / 20 )) ]' "AC9-filter the output is under 5% of the log's lines"
  ok '[ -s "$T/o/f1.out" ] && ! grep >/dev/null -E "test_case_(17|2900) passed|qa-progress" "$T/o/f1.out"' "AC9-filter passing lines far from the failure and progress noise are dropped"
  ok '[ -s "$T/o/f1.out" ] && { [ "${CTX:-0}" -lt 1 ] || grep >/dev/null QA-CTX-BEFORE "$T/o/f1.out"; }' "AC9-filter the data's context (${CTX:-0} lines) is kept around the failing line"
  ;;
lean)   # AC11-lean (data and translate part): a role with 30 registered tools starts with only its core set
  TPLC=$(jq -c '[.entries[] | select(.kind == "tool")][0]' "$R/.stella/capabilities.json")
  for i in $(seq -w 1 30); do printf '%s\n' "$(jq -c --arg id "qa-tool-$i" --arg r "$ROLE" --arg g "$(uuid)" --arg i "$IID" '. + {id: $id, summary: ("qa lean tool " + $id), keywords: ["qalean"], allowed_roles: [$r], global_id: $g, install_id: $i}' <<<"$TPLC")"; done >"$T/tools.jsonl"
  ed .stella/capabilities.json --slurpfile t "$T/tools.jsonl" '.entries += $t'
  [ -n "$RPATH" ] && ed .stella/run-policy.json --argjson p "$RPATH" 'setpath($p + ["core_tools"]; ["qa-tool-01", "qa-tool-02"])'
  ed .stella/adapters.json '.entries[0].supports = {hook: true, deferred_tools: true, compaction: true, clear_tool_results: true, subagent: true, script_tools: true, working_notes: true, skill_use_observable: true, tool_use_observable: true}'
  AD=$(jq -r '.entries[0].id // empty' "$R/.stella/adapters.json")
  ok '[ -n "$AD" ] && python3 -I "$R/bin/stella_data.py" check && RPP check' "AC11-lean precondition: 30 tools registered for $ROLE, core_tools set to two of them, the data checks"
  run t1 RPP translate --adapter "$AD" --role "$ROLE" --json
  ok '[ $RC = 0 ] && grep >/dev/null qa-tool-01 "$T/o/t1.out" && grep >/dev/null qa-tool-02 "$T/o/t1.out"' "AC11-lean translate names the role's core tools"
  ok '[ -s "$T/o/t1.out" ] && ! grep >/dev/null -E "qa-tool-(0[3-9]|[12][0-9]|30)" "$T/o/t1.out"' "AC11-lean ... and none of the other 28 registered tools (found later through search)"
  ;;
supports)   # T-SUPPORTS: each adapter reports which context/output features it supports
  ed .stella/adapters.json --arg g "$(uuid)" '.entries += [.entries[0] + {id: "qa-sup", global_id: $g, supports: {hook: true, deferred_tools: false, compaction: true, clear_tool_results: false, subagent: false, script_tools: false, working_notes: true, skill_use_observable: "unverified", tool_use_observable: true}}]'
  run s1 RPP translate --adapter qa-sup --role "$ROLE" --json
  uns() { jq -c '[.. | objects | to_entries[] | select(.key | test("unsupported"; "i")) | .value | .. | strings]' "$T/o/s1.out" 2>/dev/null; }
  ok '[ $RC = 0 ] && [ -s "$T/o/s1.out" ] && uns | jq -e "index(\"deferred_tools\") != null and index(\"clear_tool_results\") != null and index(\"subagent\") != null"' "T-SUPPORTS translate lists the features the adapter does not support"
  ok '[ -s "$T/o/s1.out" ] && uns | jq -e "index(\"compaction\") == null and index(\"working_notes\") == null"' "T-SUPPORTS ... and not the ones it supports"
  ed .stella/adapters.json '(.entries[] | select(.id == "qa-sup") | .supports.compaction) = false'
  run s2 RPP translate --adapter qa-sup --role "$ROLE" --json
  ok '[ $RC = 0 ] && [ -s "$T/o/s2.out" ] && jq -e "[.. | objects | to_entries[] | select(.key | test(\"unsupported\"; \"i\")) | .value | .. | strings] | index(\"compaction\") != null" "$T/o/s2.out"' "T-SUPPORTS a data change of one supports flag changes the report (no code change)"
  ;;
esac
finish
