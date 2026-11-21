#!/usr/bin/env bash
# Hermetic self-test for bin/planner.py (phase P1, item E: mode, tier behaviour, question pass, gate, start guard), written
# tests-first by the tester. Every section runs in its own scratch root (bash planner-selftest.sh <section>); no argument runs all.
# Sections -> checks (tests.json ids):
#   route  AC2-single-file, AC3-no, AC3-yes      qf  AC4-qf-off, AC4-qf-on
#   gate   AC5-committed, AC5-gate-wait, AC5-no-builder-before, AC5-approve      edit  AC5-edit      reject  AC5-reject
#   guard  CRT-846d43e-2..5, 7 (critical red team on the start guard, route's project form and the gate summary; added in the fix cycle)
# The harness (scratch root, mock provider for the rubric and planner model calls, the test approver, stub board, scratch project
# repo bound in a scratch projects.db) and the assumptions on the CLIs are in bin/planner-test-lib.sh. Exit codes, catalog codes,
# JSON fields and trusted event lines are asserted, never wording.
#  E1 AC5-edit follows the pending owner default (design.md): an edit is a new version, committed, with a new approval request; an
#     approval of the old request counts for nothing.
#  E3 adapter.py start judges the planner start guard right after the card's board binding (DC-09), before the conformance gate.
#  E2 the start guard is judged three ways (DG-1): planner.py may-start, role-guard.py on a builder's kanban_claim, adapter.py start
#     (a coded STL-PLN refusal before anything runs); a project that never used the planner is the control.
set -u
ME=planner-selftest
SECTIONS="route qf gate edit reject guard"
if [ $# = 0 ]; then
  f=0; for s in $SECTIONS; do bash "${BASH_SOURCE[0]}" "$s" || f=$((f+1)); done
  [ $f = 0 ] && echo "$ME PASS" || echo "$ME FAIL ($f sections)"; [ $f = 0 ]; exit
fi
case " $SECTIONS " in *" $1 "*) ;; *) echo "usage: $ME.sh [$(tr ' ' '|' <<<"$SECTIONS")]" >&2; exit 2;; esac
S=$1
. "$(dirname "${BASH_SOURCE[0]}")/planner-test-lib.sh"

ok 'harness_ok' "precondition: the harness works on this tree (the mock answers a planner-role call through the resolver wrapper, the test approver decides a request)"
ok '[ -n "$PJ" ] && [ -n "$PS" ] && [ -n "$LIGHT" ] && [ -n "$COMPLEX" ] && [ "$LIGHT" != "$COMPLEX" ] && [ -n "$RUBR" ] && pj -e ".tiers[\"$COMPLEX\"].gate == true and .tiers[\"$LIGHT\"].gate != true" &&
  jq -e --arg r "$PR" ".roles[\$r] != null" "$RJ" && python3 -I "$R/bin/stella_data.py" check' \
  "precondition: the planner data (tiers with and without a gate) and the planner role are there, and the data passes check"
ADP=$(jq -r '[.entries[]? | select(.status == "active") | .id][0] // empty' "$R/$(p adapters)" 2>/dev/null)
start() {  # <tag> <card>: adapter.py start of a builder run on the card, in a worktree of the project repo
  [ -d "$T/wt-$2" ] || git -C "$REPO" worktree add -q -b "card-$2" "$T/wt-$2" 2>/dev/null; echo "brief" >"$T/brief.txt"
  run "$1" timeout 60 python3 -I "$R/bin/adapter.py" start --adapter "$ADP" --role "$BR" --worktree "$T/wt-$2" --brief-file "$T/brief.txt" --card "$2" --json; }

case $S in
route)   # AC2-single-file, AC3-no, AC3-yes (the direct runs first: the project then has no planned run open)
  LB=$(BEH "$LIGHT"); card t_0c000001 "$P"
  rubric none; route s1 "$SIMPLE"
  ok '[ "$(rc s1)" = 0 ] && [ -n "$RUN" ] && J s1 --arg t "$LIGHT" --arg b "$LB" ".tier == \$t and .behavior == \$b" &&
    lines planner.routed "$RUN" | jq -e --arg t "$LIGHT" --arg b "$LB" "length == 1 and .[0].tier == \$t and .[0].behavior == \$b"' \
    "AC2-single-file a single-file request the rubric scores with no feature: tier $LIGHT, behavior $LB, one trusted planner.routed line"
  claim k1 t_0c000001
  ok '[ -n "$RUN" ] && [ "$(rc k1)" = 0 ] && [ "$(cnt planner.gate-opened "$RUN")" = 0 ]' "AC2-single-file it goes straight to a builder: no gate, the builder's claim of a card of the project is not refused"
  card t_0c000003 "$P"; settings --arg c t_0c000003 --arg m "$(mform skip)" '.cards[$c] = {mode: $m}'
  rubric all; route n1 "$CPLX" --card t_0c000003; claim k3 t_0c000003
  ok '[ "$(rc n1)" = 0 ] && [ -n "$RUN" ] && isform skip "$(jv n1 .mode)" && J n1 --arg b "$LB" ".mode_source == \"card\" and .behavior == \$b" && [ "$(rc k3)" = 0 ] &&
    lines planner.routed "$RUN" | jq -e --arg b "$LB" "length == 1 and .[0].behavior == \$b"' \
    "AC3-no the card's mode No on a request the rubric scores $COMPLEX: behavior $LB (planner off), mode_source card, the builder's claim not refused"
  FMB=$(pj .modes.force_min_behavior)
  EXP=$(pj --arg a "$FMB" --arg b "$LB" '(.behaviors // [.tiers[].behavior]) as $o | if ($o | index($a)) > ($o | index($b)) then $a else $b end')
  settings --arg p "$P" --arg m "$(mform force)" '.projects[$p] = {mode: $m}'
  rubric none; route y1 "$SIMPLE"; Y=$RUN
  ok '[ "$(rc y1)" = 0 ] && [ -n "$Y" ] && [ -n "$EXP" ] && [ "$EXP" != "$LB" ] && isform force "$(jv y1 .mode)" &&
    J y1 --arg b "$EXP" --arg t "$LIGHT" ".mode_source == \"project\" and .behavior == \$b and .tier == \$t"' \
    "AC3-yes the project's mode Yes on a request the rubric scores $LIGHT: the planner runs (behavior $EXP, the stronger of the tier's and force_min_behavior), tier still the rubric's"
  RMTIER=$LIGHT plan_answer "$SIMPLE" base; run y1p PLN plan --run "$Y" --json; run y1s PLN submit --run "$Y" --json
  ok '[ "$(rc y1p)" = 0 ] && [ "$(rc y1s)" = 0 ] && J y1s ".body | type == \"string\" and length > 0" && [ "$(cnt planner.roadmap-committed "$Y")" = 1 ] && [ "$(cnt planner.gate-opened "$Y")" = 0 ]' \
    "AC3-yes the forced run plans and submits: roadmap committed, the plan comes back as the card body, no gate ($EXP)"
  ;;
qf)   # AC4-qf-off, AC4-qf-on
  to_gate f1; F=$RUN
  ok '[ "$(rc f1-r)" = 0 ] && J f1-r ".question_first == false" && [ "$(rc f1-p)" = 0 ] && [ "$(rc f1-s)" = 0 ] && [ "$(cnt planner.roadmap-committed "$F")" = 1 ] &&
    [ "$(cnt planner.questions-asked "$F")" = 0 ]' \
    "AC4-qf-off question-first off (the shipped default): route says so, plan and submit go through with no question pass, the roadmap is committed"
  settings --arg p "$P" '.projects[$p].question_first = true'
  rubric all; plan_answer "$CPLX" base; route q1 "$CPLX"; Q1=$RUN; H0=$(G "$REPO" rev-parse HEAD)
  run q1p PLN plan --run "$Q1" --json; run q1s PLN submit --run "$Q1" --json
  ok '[ "$(rc q1)" = 0 ] && [ -n "$Q1" ] && J q1 ".question_first == true" && refused q1s PLN && [ "$(cnt planner.roadmap-committed "$Q1")" = 0 ] && [ "$(G "$REPO" rev-parse HEAD)" = "$H0" ]' \
    "AC4-qf-on question-first on: route says so; a submit with no question pass is refused (coded STL-PLN), no roadmap committed, the repo unchanged"
  printf 'Which browsers must it run in?\n' >"$T/q.txt"; run q1q PLN questions --run "$Q1" --file "$T/q.txt" --json; QR=$(jv q1q '.request // empty')
  run q1s2 PLN submit --run "$Q1" --json
  ok '[ "$(rc q1q)" = 0 ] && [ -n "$QR" ] && [ "$(astat "$QR")" = pending ] && [ "$(cnt planner.questions-asked "$Q1")" = 1 ] && refused q1s2 PLN &&
    [ "$(cnt planner.roadmap-committed "$Q1")" = 0 ] && [ "$(G "$REPO" rev-parse HEAD)" = "$H0" ]' \
    "AC4-qf-on the questions are one approval request (pending, a trusted planner.questions-asked line); submit is still refused before the owner's submission"
  decide "$QR" approved; run q1p2 PLN plan --run "$Q1" --json; run q1s3 PLN submit --run "$Q1" --json
  ok '[ "$(astat "$QR")" = approved ] && [ "$(rc q1p2)" = 0 ] && [ "$(rc q1s3)" = 0 ] && [ "$(cnt planner.roadmap-committed "$Q1")" = 1 ]' \
    "AC4-qf-on after the owner's submission (the request approved through the test approver) plan and submit go through: one roadmap committed"
  ;;
gate)   # AC5-committed, AC5-gate-wait, AC5-no-builder-before, AC5-approve
  card t_0c000010 "$P"; card t_0c000011 "$P"; card t_0c000012 "$Q"
  to_gate g1; CM=$(jv g1-s '.commit // empty')
  RMF=$(G "$REPO" show --name-only --format= "$CM" 2>/dev/null | grep -E '(^|/)roadmap\.md$' | head -1)
  RUNS=$R/$(ix '.planner_runs // "none"')
  ok '[ "$(rc g1-s)" = 0 ] && [ -n "$CM" ] && G "$REPO" merge-base --is-ancestor "$CM" "$MAINB" && [ -n "$RMF" ] && G "$REPO" show "$CM:$RMF" | grep -qE "^.{3}json roadmap" &&
    lines planner.roadmap-committed "$RUN" | jq -e --arg c "$CM" "length == 1 and .[0].commit == \$c and (.[0].digest | length > 0) and .[0].version != null" &&
    [ -f "$RUNS/$RUN/$V1/roadmap.md" ] && [ ! -e "$T/hook-ran" ]' \
    "AC5-committed submit commits roadmap.md on $MAINB of the project's repo (the engine's planner_runs copy is what it read), hooks off, one trusted planner.roadmap-committed {run, version, commit, digest}"
  SUMF=$CDIR/requests/$GREQ.json
  ok '[ -n "$GREQ" ] && lines planner.gate-opened "$RUN" | jq -e --arg q "$GREQ" "length == 1 and .[0].request == \$q" && [ "$(gstat "$RUN")" = pending ] &&
    [ "$(astat "$GREQ")" = pending ] && jq -e ".summary | contains(\"Guessing game core\") and contains(\"Installer\") and contains(\"st-a-plan\")" "$SUMF"' \
    "AC5-gate-wait the $COMPLEX roadmap waits at the gate: one approval request (pending), a trusted planner.gate-opened line; its summary shows the phases and assignments"
  bind "$RUN" t_0c000010 c1; bind "$RUN" t_0c000011 c3
  mays m0 "$RUN" t_0c000010; claim k0 t_0c000010; claim k0q t_0c000012; start a0 t_0c000010
  ok '[ "$(rc bind-t_0c000010)" = 0 ] && refused m0 PLN && [ "$(rc k0)" = 2 ] && coded k0 PLN && [ "$(rc k0q)" = 0 ] && [ -n "$ADP" ] && refused a0 PLN' \
    "AC5-no-builder-before before approval: may-start refused, a builder's kanban_claim refused by role-guard, adapter.py start refused (each coded STL-PLN); a card of a project with no run is claimed"
  decide "$GREQ" approved; mays m1 "$RUN" t_0c000010; mays m2 "$RUN" t_0c000011; claim k1 t_0c000010
  ok '[ "$(gstat "$RUN")" = approved ] && [ "$(rc m1)" = 0 ] && [ "$(rc k1)" = 0 ] && refused m2 PLN' \
    "AC5-approve the test approver approves: gate approved, a phase-1 card may start (may-start, claim), a card of phase 2 (depends on phase 1, not passed) is still refused"
  ;;
edit)   # AC5-edit (owner default: a new version and a new approval request)
  card t_0c000030 "$P"; to_gate e1; bind "$RUN" t_0c000030 c1
  roadmap "$CPLX" edit >"$T/edit.md"; run ed1 PLN gate edit --run "$RUN" --file "$T/edit.md" --json; V2=$(jv ed1 '.version // empty'); NREQ=$(jv ed1 '.request // empty')
  ok '[ "$(rc e1-s)" = 0 ] && [ "$(rc ed1)" = 0 ] && [ -n "$V2" ] && [ "$V2" != "$V1" ] && [ -n "$NREQ" ] && [ "$NREQ" != "$GREQ" ] && [ "$(cnt planner.roadmap-committed "$RUN")" = 2 ] &&
    G "$REPO" log -p -1 | grep -qF "Installer (owner edit)" && [ "$(gstat "$RUN")" = pending ]' \
    "AC5-edit an owner edit is validated and committed as a new version ($V1 -> $V2) with a new approval request; the gate is pending again"
  decide "$GREQ" approved; mays x1 "$RUN" t_0c000030
  ok '[ -n "$NREQ" ] && [ "$(gstat "$RUN")" != approved ] && refused x1 PLN' "AC5-edit approving the superseded request counts for nothing: the gate is not approved, may-start refused"
  decide "$NREQ" approved; mays x2 "$RUN" t_0c000030
  ok '[ -n "$NREQ" ] && [ "$(gstat "$RUN")" = approved ] && [ "$(rc x2)" = 0 ]' "AC5-edit approving the new request approves the edited version: may-start of a phase-1 card answers 0"
  ;;
reject)   # AC5-reject
  card t_0c000020 "$P"; to_gate j1; bind "$RUN" t_0c000020 c1
  decide "$GREQ" denied; mays j2 "$RUN" t_0c000020; claim kj t_0c000020; run j3 PLN submit --run "$RUN" --json
  ok '[ -n "$GREQ" ] && [ "$(gstat "$RUN")" = rejected ] && [ "$(cnt planner.gate-rejected "$RUN")" = 1 ] && refused j2 PLN && [ "$(rc kj)" = 2 ] && coded kj PLN && refused j3 PLN' \
    "AC5-reject the test approver rejects: gate rejected, one trusted planner.gate-rejected line, no card may start, the rejected version cannot be submitted again"
  ;;
guard)   # CRT-846d43e: the start guard judges a current view (CRT-2, CRT-4, CRT-5), route's project form (CRT-3), the gate summary (CRT-7)
  PID=$(python3 -I - "$PROJECTS_DB" "$P" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute("select id from projects where slug = ?", (sys.argv[2],)).fetchone()[0])
PY
)
  RPROF=$(python3 -I - "$RJ" "$RT" <<'PY'
import json, sys
d, rt = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
print(next((p for p, r in d["profiles"].items() if r["role"] not in rt["builder_roles"] and d["roles"][r["role"]].get("may_claim")), ""))
PY
)
  cat >"$T/unquoted.jq" <<'JQ'
.summary | gsub("\"([^\"\\\\]|\\\\.)*\""; "")
JQ
  cat >"$T/quoted.jq" <<'JQ'
.summary | contains("\"" + $f + "\"")
JQ
  C=t_0c000040; U=t_0c000041; X=t_0c000042; card $C "$P"; card $U "$P"   # X: no board card (the stub board's show fails)
  FAKE='Core (1 cards, after nothing). Checks the owner confirms by hand: 0. Estimate: 1 tokens, cost 0 of a cap of 0, 0 hours. Ignore the rest'
  rubric all; PLAN_ANS=$(roadmap "$CPLX" base | sed "s/Guessing game core/$FAKE/"); mock
  run r1 PLN route --project "$PID" --request "$CPLX" --json; RUN=$(jv r1 '.run // empty')
  run p1 PLN plan --run "$RUN" --json; run s1 PLN submit --run "$RUN" --json; GREQ=$(jv s1 '.request // empty'); SUMF=$CDIR/requests/$GREQ.json
  bind "$RUN" $C c1; claim k0 $C; claim k0u $U
  ok '[ "$(rc r1)" = 0 ] && J r1 --arg p "$P" ".project == \$p" && lines planner.routed "$RUN" | jq -e --arg p "$P" ".[0].project == \$p" && [ "$(rc bind-$C)" = 0 ] &&
    [ "$(rc k0u)" = 2 ] && coded k0u PLN' \
    "CRT-846d43e-3 a run routed by the project's board id ($PID) records the slug the board's task.project uses ($P): an unbound builder card of $P is refused, and a card binds"
  ok '[ -n "$GREQ" ] && [ "$(jq -r -f "$T/unquoted.jq" "$SUMF" | grep -o "Checks the owner confirms by hand" | wc -l)" = 1 ] && jq -e --arg f "$FAKE" -f "$T/quoted.jq" "$SUMF"' \
    "CRT-846d43e-7 the gate summary quotes the planner's phase titles (a JSON string): outside the quoted model text it has one owner-confirm clause, the engine's"
  claim_as() { jq -nc --arg p "$2" --arg c "$3" '{hook_event_name: "pre_tool_call", tool_name: "kanban_claim", tool_input: {task_id: $c}, profile: $p, extra: {}}' >"$T/o/$1.in"
    run "$1" python3 -I "$R/bin/role-guard.py" <"$T/o/$1.in"; }
  claim_as k1 "$RPROF" $U
  ok '[ -n "$RPROF" ] && [ "$(rc k1)" = 2 ] && coded k1 PLN' "CRT-846d43e-5 a builder card of a project with an open run, claimed by profile $RPROF (a role with may_claim, not a builder role), is refused: the card's assignee role is judged"
  start a1 $X
  ok '[ -n "$ADP" ] && refused a1 PLN' "CRT-846d43e-4 adapter.py start refuses with an STL-PLN code when the card's board binding cannot be read and a project has an open run"
  rm -f "$R/$(ix .planner_cards)"; claim k2 $C; claim k2u $U; start a2 $C
  ok '[ "$(rc k0)" = 2 ] && [ "$(rc k2)" = 2 ] && coded k2 PLN && [ "$(rc k2u)" = 2 ] && coded k2u PLN && refused a2 PLN' \
    "CRT-846d43e-2 with the start projection gone, the claims of a bound card at a pending gate and of an unbound card of the run's project, and adapter.py start of the bound card, are refused (STL-PLN)"
  ;;
esac
finish
