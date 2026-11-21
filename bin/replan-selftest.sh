#!/usr/bin/env bash
# Hermetic self-test for bin/replan.py (phase P1, item F: escalate, then re-plan), written tests-first by the tester.
# Every section runs in its own scratch root (bash replan-selftest.sh <section>); no argument runs them all.
# Sections -> checks (tests.json ids):
#   brief  AC6-brief-history     spec  AC6-spec-replan     block  AC6-block-twice     diff  AC6-phase-gate     split  AC6-split-nogate
# Each section has a planner run whose roadmap the test approver approved (bin/planner-test-lib.sh: harness and CLI assumptions),
# board cards bound to its roadmap cards, and a QA loop per card driven as bin/qa-loop-selftest.sh drives it (a scratch builder
# repo, findings, repros, verdicts through bin/qa_findings.py, qa.* lines planted only through bin/qa_loop.py / qa_findings.py).
# ASSUMPTIONS (beyond the harness's):
#  F1 replan.py dispatch --card C --run R --json -> {action, reason, history, brief}: action "climb" | "replan" | "owner" (the design's
#     words); history = the path of the engine-written history file whose sha256 is the digest of the trusted planner.history line.
#  F2 a finding's kind (DG-9) is a field "kind" of the finding object given to qa_findings.py submit.
#  F3 replan.py record-block --card C --kind K writes one planner.block line (DG-8).
#  F4 replan.py replan-diff --run R --old V --new V2 --json says gate or split as {action: "gate"|"split"} or {gate: bool, split: bool};
#     the new version comes from planner.py plan after the trusted planner.replan line; a gated version opens its gate on submit.
set -u
ME=replan-selftest
SECTIONS="brief spec block diff split"
if [ $# = 0 ]; then
  f=0; for s in $SECTIONS; do bash "${BASH_SOURCE[0]}" "$s" || f=$((f+1)); done
  [ $f = 0 ] && echo "$ME PASS" || echo "$ME FAIL ($f sections)"; [ $f = 0 ]; exit
fi
case " $SECTIONS " in *" $1 "*) ;; *) echo "usage: $ME.sh [$(tr ' ' '|' <<<"$SECTIONS")]" >&2; exit 2;; esac
S=$1
. "$(dirname "${BASH_SOURCE[0]}")/planner-test-lib.sh"

# ---- the QA loop, as bin/qa-loop-selftest.sh drives it ----
QJ=$R/.stella/qa-loop.json; q() { jq -r "$@" "$QJ" 2>/dev/null; }
LIGHTQ=$(q .depth_bump.from); NORMAL=$(q .rounds.normal); CLIMB=$(q .rounds.climb_rung)
TESTER=$(q '[.roles | to_entries[] | select(.value.kind == "evidence") | .key][0]')
BLOCK=$(q --arg l "$LIGHTQ" '[.severities[] | select(.blocks_on == "all" or (.blocks_on | index($l)))][-1].id')
QEV=$(ix .qa_evidence)
QL() { python3 -I "$R/bin/qa_loop.py" "$@"; }
QF() { python3 -I "$R/bin/qa_findings.py" "$@"; }
mkrepo() { git init -q -b main "$1" && printf 'exit 1\n' >"$1/check.sh" && echo base >"$1/a.txt" && G "$1" add -A && G "$1" commit -qm base && G "$1" rev-parse HEAD; }
step() { echo "$3" >>"$1/$2" && G "$1" add -A && G "$1" commit -qm "$3" && G "$1" rev-parse HEAD; }
RM='def rm: (.roles // {}) | if type == "array" then map({key: (.role // .id), value: .}) | from_entries else . end;'
active() { QL plan --card "$1" --json 2>>"$T/o/last" | jq -r "$RM"' rm | to_entries[] | select((.value.count // 0) >= 1 and (.value.depth // "off") != "off") | .key'; }
fp() { python3 -I -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import qa_findings as f; print(f.fingerprint(json.load(open(sys.argv[2]))[0]))' "$R/bin" "$1" 2>/dev/null; }
open_() { QL open --card "$1" --project "$P" --tier "$MEDIUM" --base "$2" --builder-role "$BR" >>"$T/o/last" 2>&1; }
frz() { QL freeze --card "$1" --repo "$2" --hash "$3" >>"$T/o/last" 2>&1; }
ev() { local d=$R/$QEV/$1/$2; mkdir -p "$d"; echo "qa evidence $3" >"$d/$3.txt"; QF evidence --card "$1" --round "$2" --file "$d/$3.txt" >>"$T/o/last" 2>&1; echo "$d/$3.txt"; }
finding() {   # <card> <round> <severity> <check id> [kind]: the tester submits one finding (repro: check.sh, which fails), with evidence; prints its file
  local f=$T/f-$1-$2-$4.json e; e=$(ev "$1" "$2" "f-$4")
  jq -n --arg c "$4" --arg s "$3" --arg e "$e" --arg k "${5:-}" \
    '[{check: $c, file: "a.txt", lines: [1, 1], test: "check.sh", severity: $s, repro: ["sh", "check.sh"], evidence: [$e], static: false} + (if $k == "" then {} else {kind: $k} end)]' >"$f"
  QF submit --card "$1" --round "$2" --role "$TESTER" --file "$f" >>"$T/o/last" 2>&1; echo "$f"; }
fail_round() {   # <card> <round> [kind]: one finding its repro confirms, the tester's verdict fail, close
  local f; f=$(finding "$1" "$2" "$BLOCK" qa-check-1 "${3:-}"); QF repro --card "$1" --fingerprint "$(fp "$f")" >>"$T/o/last" 2>&1
  QF verdict --card "$1" --round "$2" --role "$TESTER" --result fail --evidence "$(ev "$1" "$2" v-fail)" >>"$T/o/last" 2>&1
  QL close --card "$1" >>"$T/o/last" 2>&1; }
qlines() { proof | jq -c --arg t "$1" --arg c "$2" "$PAY"' [.[] | select(.type == $t and .what == $c) | pay]'; }   # <qa.* type> <card>
preset_copy() {   # <new id> <chain jq>: a copy of the selected preset whose builder escalation chain is <chain jq>, selected globally
  ed "$(p role-assignments)" --arg s "$SEL" --arg n "$1" --arg b "$BR" ".effort_modes[\$n] = (.effort_modes[\$s] | .builtin = false | .based_on = \$s | .label = \$n
    | .roles[\$b].escalation_chain |= ($2)) | .selection.global = \$n" && SEL=$1; }
approved() {  # <tag> [variant]: a complex run whose roadmap the test approver approved (RUN, V1, GREQ)
  to_gate "$1" "${2:-}"; decide "$GREQ" approved; }
dispatch() { run "$1" RP dispatch --card "$2" --run "$RUN" --json; }   # <tag> <card>
act() { jv "$1" '.action // empty'; }
blocks() { local i; for i in $(seq 1 "${3:-0}"); do run "blk-$1-$i" RP record-block --card "$1" --kind "$2"; done; }   # <card> <kind> <times>
LIM=$(pj .replan.block_limit); BK=$(pj '.replan.block_kinds[0]')
gated() { J "$1" '.action == "gate" or .gate == true'; }
splitd() { J "$1" '(.action == "split" or .split == true) and (.gate != true)'; }

ok 'harness_ok' "precondition: the harness works on this tree (the mock answers a planner-role call through the resolver wrapper, the test approver decides a request)"
ok '[ -n "$PJ" ] && [ -n "$COMPLEX" ] && [ "$LIM" -ge 2 ] && [ -n "$BK" ] && pj -e ".replan.block_kinds | index(\"needs_input\") | not" && pj -e ".replan.problem_kinds.spec != null" &&
  [ -n "$TESTER" ] && [ -n "$BLOCK" ] && [ "$NORMAL" -ge 1 ] && python3 -I "$R/bin/stella_data.py" check' \
  "precondition: the planner data gives replan.block_limit (>= 2), block_kinds (needs_input not counted), problem_kinds.spec; the QA data gives a tester and a blocking severity"

case $S in
brief)   # AC6-brief-history
  preset_copy rp-rungs '.[0:2]'   # two rungs: the QA loop climbs after round $NORMAL
  approved b1; C=t_0d000001; card $C "$P"; bind "$RUN" $C c1
  BREPO=$T/b1; B=$(mkrepo "$BREPO"); open_ $C "$B"; HS=""
  for r in $(seq 1 "$NORMAL"); do H=$(step "$BREPO" a.txt "round $r"); HS="$HS $H"; frz $C "$BREPO" "$H"; fail_round $C "$r"; done
  ok '[ "$(gstat "$RUN")" = approved ] && [ "$(rc bind-$C)" = 0 ] && [ "$(qlines qa.climbed $C | jq length)" = 1 ]' "precondition: the run is approved, the card bound, and its QA loop climbed after round $NORMAL (qa.climbed)"
  dispatch d1 $C; F1=$(fp "$T/f-$C-1-qa-check-1.json"); HF=$(jv d1 '.history // empty'); E1=$R/$QEV/$C/1/f-qa-check-1.txt
  ok '[ "$(rc d1)" = 0 ] && [ "$(act d1)" = climb ] && [ -n "$F1" ] && J d1 --arg f "$F1" ".brief | type == \"string\" and contains(\$f) and test(\"untrusted\"; \"i\")" &&
    for h in $HS; do J d1 --arg h "$h" ".brief | contains(\$h)" || exit 1; done' \
    "AC6-brief-history dispatch says climb; the climbing builder's brief carries the failure history (the open finding $F1, each attempt's frozen hash) as a block marked untrusted"
  ok '[ -n "$HF" ] && [ -f "$HF" ] && grep -qF "$F1" "$HF" && grep -qF "$E1" "$HF" && lines planner.history $C | jq -e --arg d "$(sha "$HF")" "length >= 1 and .[-1].digest == \$d"' \
    "AC6-brief-history the history file (findings, verdicts, tester evidence paths) is engine-written and its sha256 is the digest of a trusted planner.history line"
  ;;
spec)   # AC6-spec-replan
  approved s1; C1=t_0d000011; C2=t_0d000012; card $C1 "$P"; card $C2 "$P"; bind "$RUN" $C1 c1; bind "$RUN" $C2 c2
  for x in "$C1 a.txt" "$C2 b.txt"; do read -r c f <<<"$x"; BREPO=$T/r-$c; B=$(mkrepo "$BREPO"); open_ $c "$B"; H=$(step "$BREPO" "$f" r1); frz $c "$BREPO" "$H"; done   # each change stays inside its roadmap card's files (c1 a.txt, c2 b.txt): no scope growth
  fail_round $C1 1 spec; fail_round $C2 1 code
  dispatch d1 $C1; dispatch d2 $C2; mays m1 "$RUN" $C1
  ok 'qlines qa.finding $C1 | jq -e "any(.[]; .kind == \"spec\")" && [ "$(rc d1)" = 0 ] && [ "$(act d1)" = replan ] && [ "$(cnt planner.replan $C1)" = 1 ] && refused m1 PLN' \
    "AC6-spec-replan a standing finding of kind spec (recorded in the trusted qa.finding line): dispatch says replan, not climb; a trusted planner.replan line; the card may not start (DG-7)"
  ok '[ "$(rc d2)" = 0 ] && [ -n "$(act d2)" ] && [ "$(act d2)" != replan ] && [ "$(cnt planner.replan $C2)" = 0 ]' \
    "AC6-spec-replan (control) the same failure with a finding of kind code is no re-plan"
  ;;
block)   # AC6-block-twice
  approved k1; C1=t_0d000021; C2=t_0d000022; C3=t_0d000023
  for c in $C1 $C2 $C3; do card $c "$P"; B=$(mkrepo "$T/r-$c"); open_ $c "$B"; done
  bind "$RUN" $C1 c1; bind "$RUN" $C2 c2; bind "$RUN" $C3 c3
  blocks $C1 "$BK" "$LIM"; blocks $C2 "$BK" $((${LIM:-0} - 1)); blocks $C3 needs_input "$LIM"
  dispatch d1 $C1; dispatch d2 $C2; dispatch d3 $C3
  ok '[ "$(rc blk-$C1-1)" = 0 ] && [ "$(cnt planner.block $C1)" = "$LIM" ] && [ "$(rc d1)" = 0 ] && [ "$(act d1)" = replan ] && [ "$(cnt planner.replan $C1)" = 1 ]' \
    "AC6-block-twice a builder blocked $LIM times (kind $BK, trusted planner.block lines): dispatch says replan, one trusted planner.replan line"
  ok '[ "$(rc d2)" = 0 ] && [ "$(act d2)" != replan ] && [ "$(rc d3)" = 0 ] && [ "$(act d3)" != replan ] && [ "$(cnt planner.replan $C2)" = 0 ] && [ "$(cnt planner.replan $C3)" = 0 ]' \
    "AC6-block-twice (controls) blocked $((${LIM:-0} - 1)) time(s), or $LIM times as needs_input (not counted): no re-plan"
  ;;
diff)   # AC6-phase-gate
  approved g1; C1=t_0d000031; card $C1 "$P"; bind "$RUN" $C1 c1; B=$(mkrepo "$T/r-$C1"); open_ $C1 "$B"
  blocks $C1 "$BK" "$LIM"; dispatch d1 $C1
  plan_answer "$CPLX" phase; run p2 PLN plan --run "$RUN" --json; V2=$(jv p2 '.version // empty')
  run df RP replan-diff --run "$RUN" --old "$V1" --new "$V2" --json; run s2 PLN submit --run "$RUN" --json; mays m1 "$RUN" $C1
  ok '[ "$(act d1)" = replan ] && [ "$(rc p2)" = 0 ] && [ -n "$V2" ] && [ "$V2" != "$V1" ] && [ "$(rc df)" = 0 ] && gated df' \
    "AC6-phase-gate a re-plan that adds a phase: replan-diff $V1 -> $V2 says gate"
  ok '[ -n "$V2" ] && lines planner.gate-opened "$RUN" | jq -e --arg v "$V2" "any(.[]; (.version | tostring) == \$v)" && [ "$(gstat "$RUN")" = pending ] && refused m1 PLN && [ "$(cnt planner.split "$RUN")" = 0 ]' \
    "AC6-phase-gate the new version goes back to the gate: a planner.gate-opened line for $V2, gate pending, the bound card may not start, no planner.split line"
  ;;
split)   # AC6-split-nogate
  approved t1; C1=t_0d000041; C2=t_0d000042; card $C1 "$P"; card $C2 "$P"; bind "$RUN" $C1 c1; bind "$RUN" $C2 c2; B=$(mkrepo "$T/r-$C1"); open_ $C1 "$B"
  blocks $C1 "$BK" "$LIM"; dispatch d1 $C1
  plan_answer "$CPLX" split; run p2 PLN plan --run "$RUN" --json; V2=$(jv p2 '.version // empty')
  run df RP replan-diff --run "$RUN" --old "$V1" --new "$V2" --json; mays m2 "$RUN" $C2
  ok '[ "$(act d1)" = replan ] && [ "$(rc p2)" = 0 ] && [ -n "$V2" ] && [ "$(rc df)" = 0 ] && splitd df &&
    lines planner.split "$RUN" | jq -e --arg a "$V1" --arg b "$V2" "length == 1 and (.[0].from | tostring) == \$a and (.[0].to | tostring) == \$b and (.[0].digest | length > 0)"' \
    "AC6-split-nogate c1 split into c1a and c1b inside phase p1 (files and checks inside c1's, the same builder link): replan-diff says split, one trusted planner.split {run, from, to, digest}"
  ok '[ -n "$V2" ] && [ "$(cnt planner.gate-opened "$RUN")" = 1 ] && [ "$(gstat "$RUN")" = approved ] && [ "$(rc m2)" = 0 ]' \
    "AC6-split-nogate no new gate: still one planner.gate-opened line, the gate stays approved, an unchanged card of the phase may start"
  ;;
esac
finish
