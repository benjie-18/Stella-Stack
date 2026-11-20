#!/usr/bin/env bash
# Hermetic self-test for the QA loop (phase Q1, items A1 and A2: bin/qa_loop.py), written tests-first by the tester (T1).
# Every section runs in its own scratch root (bash qa-loop-selftest.sh <section>); no argument runs them all.
# Sections -> checks (tests.json ids):
#   climb  AC1-climb4, T-CLIMB-LINE, T-RUNGS      stop3  AC1-stop3          depth  T-DEPTH-BUMP, DG-5 (fix_grew at freeze)
#   bind   AC2-bind, DG-1, DG-2                   trust  AC3-untrusted, T-STATE-TRUSTED, DG-5 (owner trigger)
#   plan   AC4-eco-security, AC6-data-only, T-LOCAL1, T-TIER-FLOOR       data   AC4-preset-refused, T-COUNT0 (DG-3)
#   worker T-WORKER   copy DG-7   merge DG-8 (bin/merge-card.sh's QA check on a scratch repo, run here: merge-card-selftest is shared)
#   rt1    fix round 1: RT1-06 (rename, case), RT1-07 (card id case), RT1-08 (open once), QL-M2, RT1-12 (reopen at cap), DG-1 evidence, close --json
#   rtf    fix cycle 2: RTF-01 (a verdict per slot), RTF-02 (.gitattributes), RTF-04 (blocking judged at close), RTF-05 (one lock per card)
#   limits owner fixes: RTF-08 (copy size limit per project), RTF-09 (rungs.json key), Q1-CVER-04 (an added "++ " line is scanned)
# A mock builder: each round is a new commit of a scratch git repo; findings, evidence and verdicts go through bin/qa_findings.py
# (item B) as design.md specifies. Exit codes, catalog codes, JSON fields and trusted event lines are asserted, never wording.
# ASSUMPTIONS (what design.md leaves open; nothing else is assumed):
#  A1 qa.* lines are read with event_log.proof_lines(); what = the card id; a line's payload is its own fields merged with .detail
#     and .new where those are objects (so {round, hash, rung, ...} may sit at the top of the line or in new).
#  A2 plan --json: {roles: {<role>: {count, depth, forced}} or [{role, count, depth, forced}], parallel: bool, ...}.
#  A3 qa_findings.py submit --file J: J is a JSON list of findings; repro is an argv list run in the frozen copy and "fails as
#     stated" is a non-zero exit; the fingerprint is qa_findings.fingerprint(finding); evidence --file takes the file's path.
#  A4 a round passes when every plan role with count >= 1 and depth other than off gave a verdict pass (counts are 1 in the flows).
#  A5 qa_loop.py open takes --builder-role (design facts); the rounds before a climb are frozen at a rung below rounds.climb_rung.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=qa-loop-selftest
SECTIONS="climb stop3 depth bind trust plan data worker copy merge rt1 rtf limits"
if [ $# = 0 ]; then
  f=0; for s in $SECTIONS; do bash "${BASH_SOURCE[0]}" "$s" || f=$((f+1)); done
  [ $f = 0 ] && echo "$ME PASS" || echo "$ME FAIL ($f sections)"; [ $f = 0 ]; exit
fi
case " $SECTIONS " in *" $1 "*) ;; *) echo "usage: $ME.sh [$(tr ' ' '|' <<<"$SECTIONS")]" >&2; exit 2;; esac
S=$1
# ---- harness: a scratch root of its own (bin, .stella, docs copied), its own HOME, temp, alert folder, box homes ----
T=$(mktemp -d "${TMPDIR:-/tmp}/$ME.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'kill $(jobs -p) 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "# KEPT $T"; else chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; fi' EXIT
R=$T/root
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$R/.claude" "$T/home" "$T/tmp" "$T/sup/logs" "$T/pb" "$T/o"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"
[ -e "$ROOT/.supervisor/limits.env" ] && cp "$ROOT/.supervisor/limits.env" "$R/.supervisor/"
for f in opencode.json .mcp.json .claude/settings.json .claude/skills; do [ -e "$ROOT/$f" ] && cp -r "$ROOT/$f" "$R/$f"; done
cd "$T" || exit 1
jq() { env -u HOME jq "$@"; }
IX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IX"; }
p() { jq -r --arg s "$1" '[.files[] | select(.schema == $s and .format == "json") | .path][0]' "$IX"; }   # <schema>: its file
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$ROOT/$(ix .role_table)" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ BOX_HERMES_ROOT=$T/hermes \
  GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=qa GIT_AUTHOR_EMAIL=qa@scratch.invalid GIT_COMMITTER_NAME=qa GIT_COMMITTER_EMAIL=qa@scratch.invalid
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB HERMES_HOME \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
POL=$R/$(ix '.files[] | select(.id == "owner-auth") | .path')
for v in $(jq -r '.worker_signals.token_env[]?' "$POL" 2>/dev/null); do unset "$v"; done
jq -r '.sandbox.boxed_profiles[]? as $p | .profiles[$p].dir // ("profiles/" + $p)' "$RJ" | while read -r d; do mkdir -p "$T/hermes/$d/home"; done   # the OS box's profile homes are scratch
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH   # a stub board: no running card
AL=$T/sup/logs/alerts.log; : >"$AL"
EVLOG=$R/$(ix .event_log)
fails=0; n=0
# ok <test> <label>: a FAIL line (never a crash) with the last saved output of the case under it (QA_DEBUG=1: those lines start with FAIL too, so the runner shows them)
ok() { n=$((n+1)); if ( set -o pipefail; eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/o/last" ] && tail -n 3 "$T/o/last" | cut -c1-240 | sed "s/^/${QA_DEBUG:+FAIL}     | /"; fi; : >"$T/o/last"; }
finish() { echo "# $ME $S: $n cases, $fails failed"; [ "$fails" = 0 ]; exit $?; }
# run <tag> <cmd...>: stdout to o/<tag>.out, stderr to o/<tag>.err, exit code in o/<tag>.rc
run() { local t=$1; shift; "$@" >"$T/o/$t.out" 2>"$T/o/$t.err"; echo $? >"$T/o/$t.rc"; cat "$T/o/$t.out" "$T/o/$t.err" >>"$T/o/last" 2>/dev/null; }
rc() { cat "$T/o/$1.rc" 2>/dev/null; }
coded() { grep -qE 'STL-[A-Z]+-[0-9]{3}' "$T/o/$1.out" "$T/o/$1.err" 2>/dev/null; }   # <tag>: the answer carries a catalog code
ed() { local f=$R/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <file under the root> <jq args and filter>

# ---- ids, all read from the copy's data ----
QJ=$R/.stella/qa-loop.json; RT=$R/$(p routing); RA=$R/$(p role-assignments); DP=$R/$(p data-policy)
q() { jq -r "$@" "$QJ" 2>/dev/null; }
LIGHT=$(q .depth_bump.from); MEDIUM=$(q .depth_bump.to); COMPLEX=$(jq -r '.task_tiers[-1].id' "$RT")
BR=$(jq -r '.builder_roles[0]' "$RT"); SEL=$(jq -r .selection.global "$RA")
TESTER=$(q '[.roles | to_entries[] | select(.value.kind == "evidence") | .key][0]')
ATTACKER=$(q '[.roles | to_entries[] | select(.value.kind == "attack") | .key][0]')
REV=$(q '[.roles | to_entries[] | select(.value.kind == "review") | .key][-1]')
BLOCK=$(q --arg l "$LIGHT" '[.severities[] | select(.blocks_on == "all" or (.blocks_on | index($l)))][-1].id')     # blocks on a light card
MEDSEV=$(q --arg l "$LIGHT" --arg m "$MEDIUM" '[.severities[] | select(.blocks_on != "all" and (.blocks_on | index($m)) and (.blocks_on | index($l) | not))][0].id')
NORMAL=$(q .rounds.normal); CLIMB=$(q .rounds.climb_rung); CAPC=$(q .rounds.cap_climb); CAPN=$(q .rounds.cap_no_climb)
ECO=$(q '[.presets | to_entries[] | select(.value.max_tier != null) | .key][0]'); LOCALP=$(q '.when_local_only.presets[0]'); LCOUNT=$(q .when_local_only.count)
SEC=$(q '[.triggers | to_entries[] | select(.value.match != null) | .key][0]')
OWNT=owner_full FIXT=fix_grew   # trigger ids (design DG-5); the precondition checks both are in the data
QEV=$(ix .qa_evidence); QCP=$(ix .qa_copies); QRG=$(ix .qa_rungs)
P=qa-proj   # a project id the data policy does not list: it follows the default

# ---- the mock builder: a scratch git repo; our own git calls never run a hook ----
G() { git -C "$1" -c core.hooksPath=/dev/null -c commit.gpgsign=false "${@:2}"; }
mkrepo() {   # <dir>: main with check.sh (exits 1: the check never passes), ok.sh (exits 0) and a.txt; prints the base commit
  git init -q -b main "$1" && printf 'exit 1\n' >"$1/check.sh" && printf 'exit 0\n' >"$1/ok.sh" && echo base >"$1/a.txt" &&
  G "$1" add -A && G "$1" commit -qm base && G "$1" rev-parse HEAD; }
step() { echo "$3" >>"$1/$2" && G "$1" add -A && G "$1" commit -qm "$3" && G "$1" rev-parse HEAD; }   # <repo> <file> <text>: one commit

# ---- the QA tools and the trusted log ----
QL() { python3 -I "$R/bin/qa_loop.py" "$@"; }
QF() { python3 -I "$R/bin/qa_findings.py" "$@"; }
proof() { python3 -I -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import event_log as e; print(json.dumps(e.proof_lines()))' "$R/bin" 2>/dev/null || echo '[]'; }
PAY='def pay: [., .detail, .new] | map(select(type == "object")) | add;'
lines() { proof | jq -c --arg t "$1" --arg c "$2" "$PAY"' [.[] | select(.type == $t and .what == $c) | pay]'; }   # <type> <card>: payloads
cnt() { lines "$1" "$2" | jq length; }
st() { QL status --card "$1" ${2:+--head "$2"} --json 2>>"$T/o/last"; }   # <card> [head]: the status JSON (empty on failure)
stq() { local s; s=$(st "$1" "${3:-}") && [ -n "$s" ] && jq -e "$2" <<<"$s" >/dev/null 2>&1; }   # <card> <jq> [head]: holds on the status
plan() { QL plan --card "$1" --json 2>>"$T/o/last"; }
RM='def rm: (.roles // {}) | if type == "array" then map({key: (.role // .id), value: .}) | from_entries else . end;'
role() { plan "$1" | jq -c --arg r "$2" "$RM"' rm | .[$r] // {count: 0, depth: "off"}'; }   # <card> <role>: its plan entry
active() { plan "$1" | jq -r "$RM"' rm | to_entries[] | select((.value.count // 0) >= 1 and (.value.depth // "off") != "off") | .key'; }
fp() { python3 -I -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import qa_findings as f; print(f.fingerprint(json.load(open(sys.argv[2]))[0]))' "$R/bin" "$1" 2>/dev/null; }
isdone() { QL done --card "$1" --hash "$2" >>"$T/o/last" 2>&1; }
open_() { QL open --card "$1" --project "$P" --tier "$2" --base "$3" --builder-role "$BR" "${@:4}" >>"$T/o/last" 2>&1; }
frz() { QL freeze --card "$1" --repo "$2" --hash "$3" >>"$T/o/last" 2>&1; }
ev() {   # <card> <round> <name>: a file in the round's evidence folder, registered by a trusted qa.evidence line; prints its path
  local d=$R/$QEV/$1/$2; mkdir -p "$d"; echo "qa evidence $3" >"$d/$3.txt"; QF evidence --card "$1" --round "$2" --file "$d/$3.txt" >>"$T/o/last" 2>&1; echo "$d/$3.txt"; }
finding() {   # <card> <round> <severity> <repro script> <check id> [static]: the tester submits one finding with evidence; prints its file
  local f=$T/f-$1-$2-$5.json e; e=$(ev "$1" "$2" "f-$5")
  jq -n --arg c "$5" --arg s "$3" --arg r "$4" --arg e "$e" --argjson st "${6:-false}" \
    '[{check: $c, file: "a.txt", lines: [1, 1], test: "check.sh", severity: $s, repro: ["sh", $r], evidence: [$e], static: $st}]' >"$f"
  QF submit --card "$1" --round "$2" --role "$TESTER" --file "$f" >>"$T/o/last" 2>&1; echo "$f"; }
repro() { QF repro --card "$1" --fingerprint "$(fp "$2")" >>"$T/o/last" 2>&1; }
verdicts() {   # <card> <round> [role left out]: a verdict pass with registered evidence from every active plan role
  local r; for r in $(active "$1"); do [ "$r" = "${3:-}" ] && continue
    QF verdict --card "$1" --round "$2" --role "$r" --result pass --evidence "$(ev "$1" "$2" "v-$r")" >>"$T/o/last" 2>&1; done; }
fail_round() {   # <card> <round> <severity>: one finding its repro confirms (check.sh exits 1 on every commit), the tester's verdict fail, close
  local f; f=$(finding "$1" "$2" "$3" check.sh qa-check-1); repro "$1" "$f"
  QF verdict --card "$1" --round "$2" --role "$TESTER" --result fail --evidence "$(ev "$1" "$2" v-fail)" >>"$T/o/last" 2>&1
  QL close --card "$1" >>"$T/o/last" 2>&1; }
pass_round() { verdicts "$1" "$2"; QL close --card "$1" >>"$T/o/last" 2>&1; }
alerts() { grep -cE 'STL-QA-[0-9]{3}' "$AL"; }
preset_copy() {   # <new id> <chain jq>: a non-built-in copy of the selected preset whose builder escalation chain is <chain jq>, selected globally
  ed "$(p role-assignments)" --arg s "$SEL" --arg n "$1" --arg b "$BR" ".effort_modes[\$n] = (.effort_modes[\$s] | .builtin = false | .based_on = \$s | .label = \$n
    | .roles[\$b].escalation_chain |= ($2)) | .selection.global = \$n"; }
data_ok() { python3 -I "$R/bin/stella_data.py" check >>"$T/o/last" 2>&1; }
resolve2() { python3 -I "$R/bin/resolve.py" resolve --role "$BR" --project "$P" --card t_0a0000ff --rung "$CLIMB" --json >"$T/o/rs.json" 2>"$T/o/rs.err"; }   # the builder works a card

ok '[ -n "$LIGHT" ] && [ -n "$MEDIUM" ] && [ "$LIGHT" != "$MEDIUM" ] && [ -n "$BR" ] && [ -n "$TESTER" ] && [ -n "$ATTACKER" ] && [ -n "$REV" ] && [ -n "$BLOCK" ] && [ -n "$MEDSEV" ] &&
  [ "$NORMAL" -ge 1 ] && [ "$CLIMB" -ge 2 ] && [ -n "$ECO" ] && [ -n "$LOCALP" ] && [ -n "$SEC" ] && q -e ".triggers[\"$OWNT\"] and .triggers[\"$FIXT\"]" && data_ok' \
  "precondition: the copy's data gives every id this test reads (tiers, roles by kind, severities, rounds, presets, triggers) and passes check"

case $S in
climb)   # AC1-climb4, T-CLIMB-LINE, T-RUNGS
  preset_copy qa-rungs '.[0:2]'
  ok 'data_ok && [ "$(jq -r --arg b "$BR" ".effort_modes[\"qa-rungs\"].roles[\$b].escalation_chain | length" "$RA")" = 2 ] && resolve2 && jq -e ".rung.served != null" "$T/o/rs.json"' \
    "precondition: the builder's escalation chain has 2 rungs and resolve --rung $CLIMB serves one"
  C=t_0a000001; REPO=$T/b1; B=$(mkrepo "$REPO"); open_ $C "$MEDIUM" "$B"
  for r in $(seq 1 "$CAPC"); do
    H=$(step "$REPO" a.txt "round $r"); frz $C "$REPO" "$H"; fail_round $C "$r" "$BLOCK"
    lines qa.climbed $C >"$T/o/climbed-$r"
  done
  FR=$(lines qa.frozen $C)
  ok '[ "$(jq length "$T/o/climbed-1")" = 0 ] && [ "$(jq length "$T/o/climbed-$NORMAL")" = 1 ] && jq -e "map(.round) == [range(1; $CAPC + 1)]" <<<"$FR" &&
    jq -e "(.[0:$NORMAL] | map(.rung) | unique | length == 1) and (.[0].rung < $CLIMB)" <<<"$FR"' \
    "AC1-climb4 rounds 1-$NORMAL run on the planned rung (no climb after round 1), the climb comes after round $NORMAL"
  ok 'jq -e "(.[$NORMAL:] | length) == $(( CAPC - NORMAL )) and (.[$NORMAL:] | all(.rung == $CLIMB))" <<<"$FR"' "AC1-climb4 rounds $((NORMAL + 1))-$CAPC are frozen on rung $CLIMB (the next rung)"
  H5=$(step "$REPO" a.txt "round 5"); frz $C "$REPO" "$H5"; FRZ5=$?
  ok '[ "$(cnt qa.escalated $C)" = 1 ] && [ "$(alerts)" -ge 1 ] && stq $C ".cap == $CAPC and .round == $CAPC and .done != true" && [ "$(cnt qa.passed $C)" = 0 ] &&
    [ $FRZ5 != 0 ] && [ "$(cnt qa.frozen $C)" = $CAPC ]' \
    "AC1-climb4 it stops at $CAPC: one trusted qa.escalated line, an owner alert (STL-QA code), cap $CAPC, no pass, a round $((CAPC + 1)) freeze refused"
  F1=$(fp "$T/f-$C-1-qa-check-1.json")
  ok 'jq -e --arg f "$F1" "length == 1 and (.[0] | (.from_rung < .to_rung) and .to_rung == $CLIMB and .from_link != null and .to_link != null and (.open | index(\$f) != null)
    and (.reason | type == \"string\" and length > 0))" "$T/o/climbed-$CAPC" && [ -n "$F1" ]' \
    "T-CLIMB-LINE the climb is one trusted qa.climbed line for the card: from_rung, to_rung $CLIMB, from_link, to_link, the open finding's fingerprint, a reason"
  ok 'jq -e --arg c $C --arg b "$BR" ".[\$c][\$b] == $CLIMB" "$R/$QRG"' "T-RUNGS the climb writes the rungs.json projection ($QRG): {card: {$BR: $CLIMB}}"
  ;;
stop3)   # AC1-stop3: no higher rung (resolve answers STL-MDL-731)
  preset_copy qa-onerung '.[0:1]'
  resolve2; ok 'data_ok && [ "$(jq -r --arg b "$BR" ".effort_modes[\"qa-onerung\"].roles[\$b].escalation_chain | length" "$RA")" = 1 ] && jq -e ".code == \"STL-MDL-731\"" "$T/o/rs.json"' \
    "precondition: the builder's escalation chain has 1 rung and resolve --rung $CLIMB answers STL-MDL-731"
  C=t_0a000002; REPO=$T/b2; B=$(mkrepo "$REPO"); open_ $C "$MEDIUM" "$B"
  for r in $(seq 1 "$CAPN"); do H=$(step "$REPO" a.txt "round $r"); frz $C "$REPO" "$H"; fail_round $C "$r" "$BLOCK"; [ "$r" = "$NORMAL" ] && lines qa.no-climb $C >"$T/o/noclimb"; done
  FR=$(lines qa.frozen $C)
  ok '[ "$(jq length "$T/o/noclimb")" = 1 ] && [ "$(cnt qa.climbed $C)" = 0 ] && jq -e "map(.round) == [range(1; $CAPN + 1)] and (map(.rung) | unique | length == 1)" <<<"$FR"' \
    "AC1-stop3 after round $NORMAL a trusted qa.no-climb line, no climb: every round on the planned rung"
  H4=$(step "$REPO" a.txt "round 4"); frz $C "$REPO" "$H4"; FRZ4=$?
  ok '[ "$(cnt qa.escalated $C)" = 1 ] && [ "$(alerts)" -ge 1 ] && stq $C ".cap == $CAPN and .round == $CAPN" && [ $FRZ4 != 0 ] && [ "$(cnt qa.frozen $C)" = $CAPN ] && [ "$(cnt qa.passed $C)" = 0 ]' \
    "AC1-stop3 it stops at $CAPN: qa.escalated, an owner alert, cap $CAPN, a round $((CAPN + 1)) freeze refused"
  ;;
depth)   # T-DEPTH-BUMP, DG-5 fix_grew
  C=t_0a000003; REPO=$T/b3; B=$(mkrepo "$REPO"); open_ $C "$LIGHT" "$B"
  M=t_0a000004; RM_=$T/b4; BM=$(mkrepo "$RM_"); open_ $M "$LIGHT" "$BM"   # control: a light card whose only finding is $MEDSEV
  HM=$(step "$RM_" a.txt "m round 1"); frz $M "$RM_" "$HM"; f=$(finding $M 1 "$MEDSEV" check.sh qa-med-1); repro $M "$f"; pass_round $M 1
  for r in $(seq 1 "$NORMAL"); do H=$(step "$REPO" a.txt "round $r"); frz $C "$REPO" "$H"; fail_round $C "$r" "$BLOCK"; done
  H3=$(step "$REPO" a.txt "round 3"); frz $C "$REPO" "$H3"; f=$(finding $C 3 "$MEDSEV" check.sh qa-med-3); repro $C "$f"; verdicts $C 3; QL close --card $C >>"$T/o/last" 2>&1
  ok '[ "$(cnt qa.passed $M)" = 1 ] && [ "$(cnt qa.depth-raised $C)" = 1 ] && jq -e ".[-1].round == 3" <<<"$(lines qa.frozen $C)" && stq $C ".depth == \"$MEDIUM\" and .tier == \"$LIGHT\"" &&
    [ "$(cnt qa.passed $C)" = 0 ] && stq $C ".open_blocking >= 1 or (.open_blocking | type == \"array\" and length >= 1)"' \
    "T-DEPTH-BUMP a light card failing round $NORMAL moves to $MEDIUM depth (qa.depth-raised; round count goes on at 3); then a $MEDSEV finding blocks (it did not on the light control card)"
  # DG-5 fix_grew: round 1 changed one file; the round-2 fix changes three
  C=t_0a000005; REPO=$T/b5; B=$(mkrepo "$REPO"); open_ $C "$LIGHT" "$B"
  H=$(step "$REPO" a.txt "round 1"); frz $C "$REPO" "$H"; n1=$(lines qa.triggered $C | jq --arg t "$FIXT" '[.[] | select(.id == $t or .trigger == $t)] | length'); fail_round $C 1 "$BLOCK"
  echo b >"$REPO/b.txt"; echo c >"$REPO/c.txt"; H=$(step "$REPO" d.txt "round 2"); frz $C "$REPO" "$H"
  ok '[ "$n1" = 0 ] && lines qa.triggered $C | jq -e --arg t "$FIXT" "[.[] | select(.id == \$t or .trigger == \$t)] | length == 1" && jq -e ".depth == \"full\"" <<<"$(role $C "$TESTER")"' \
    "DG-5 a fix that changes more files than the original change: a trusted qa.triggered $FIXT line at freeze (none at round 1), the tester runs full"
  ;;
bind)   # AC2-bind, DG-1, DG-2
  C=t_0a000006; REPO=$T/b6; B=$(mkrepo "$REPO"); open_ $C "$MEDIUM" "$B"
  H1=$(step "$REPO" a.txt "round 1"); frz $C "$REPO" "$H1"; QL close --card $C >>"$T/o/last" 2>&1
  ok '[ "$(cnt qa.frozen $C)" = 1 ] && [ "$(cnt qa.passed $C)" = 0 ] && ! isdone $C "$H1" && stq $C ".done == false and .round == 1"' \
    "DG-1 no verdicts: close does not pass the round (no qa.passed, done refuses, the round stays 1)"
  LAST=$(active $C | tail -n 1); verdicts $C 1 "$LAST"; QL close --card $C >>"$T/o/last" 2>&1
  frz $C "$REPO" "$H1"; FZ=$?
  ok '[ -n "$LAST" ] && [ "$(cnt qa.passed $C)" = 0 ] && ! isdone $C "$H1" && [ $FZ != 0 ] && [ "$(cnt qa.frozen $C)" = 1 ]' \
    "DG-1 every slot but one ($LAST) gave a pass: still no pass, and a new freeze is refused while the round is open"
  verdicts $C 1; QL close --card $C >>"$T/o/last" 2>&1
  ok 'lines qa.passed $C | jq -e --arg h "$H1" "length == 1 and .[0].round == 1 and .[0].hash == \$h" && isdone $C "$H1" && stq $C ".done == true and .frozen_hash == \"$H1\""' \
    "AC2-bind every slot passed on round 1: one qa.passed {round 1, hash}, done --hash H1 exits 0"
  H2=$(step "$REPO" a.txt "a commit after the last round")
  ok '! isdone $C "$H2" && stq $C ".done == false" "$H2"' "AC2-bind a commit after the last round: done --hash <new head> refuses and status --head <new head> says done false"
  frz $C "$REPO" "$H2"
  ok '! isdone $C "$H1" && ! isdone $C "$H2"' "AC2-bind once the new hash is frozen, done is false for the old hash too"
  pass_round $C 2
  ok 'isdone $C "$H2" && ! isdone $C "$H1" && lines qa.passed $C | jq -e --arg h "$H2" ".[-1].hash == \$h and .[-1].round == 2"' "AC2-bind a new round passes on the new hash: done for it, not for the old one"
  # QL-M4 (pass 3 and final tester): round 1 passes on H, then H itself is frozen again as round 2: done waits for round 2
  E=t_0a0000e6; RE=$T/b6e; BE=$(mkrepo "$RE"); open_ $E "$MEDIUM" "$BE"; HE=$(step "$RE" a.txt "round 1"); frz $E "$RE" "$HE"; pass_round $E 1
  isdone $E "$HE"; D1=$?; frz $E "$RE" "$HE"; FZ=$?
  ok '[ $D1 = 0 ] && [ $FZ = 0 ] && ! isdone $E "$HE" && stq $E ".done == false and .round == 2"' \
    "AC2-bind round 1 passed on H, then H frozen again as round 2: done --hash H is refused until round 2 passes"
  pass_round $E 2
  ok 'isdone $E "$HE"' "AC2-bind the re-frozen round 2 passes on H: done --hash H again"
  # DG-2: a pending finding (blocking, not static, repro not run yet)
  D=t_0a000007; RD=$T/b7; BD=$(mkrepo "$RD"); open_ $D "$MEDIUM" "$BD"; HD=$(step "$RD" a.txt "round 1"); frz $D "$RD" "$HD"
  f=$(finding $D 1 "$BLOCK" ok.sh qa-pending); verdicts $D 1; n0=$(proof | jq length)
  run c2 QL close --card $D
  ok '[ "$(rc c2)" != 0 ] && [ "$(rc c2)" != 2 ] && grep -qE "STL-QA-[0-9]{3}" "$T/o/c2.out" "$T/o/c2.err" && [ "$(cnt qa.passed $D)" = 0 ] && [ "$(proof | jq length)" = "$n0" ]' \
    "DG-2 close refuses (an STL-QA code, no new trusted line) while a finding of the round is pending its repro"
  repro $D "$f"; QL close --card $D >>"$T/o/last" 2>&1
  ok '[ "$(cnt qa.finding-unconfirmed $D)" = 1 ] && [ "$(cnt qa.passed $D)" = 1 ] && isdone $D "$HD"' "DG-2 the repro passes on the frozen copy: qa.finding-unconfirmed, then close passes"
  ;;
trust)   # AC3-untrusted, T-STATE-TRUSTED, DG-5 owner trigger
  C=t_0a000008; REPO=$T/b8; B=$(mkrepo "$REPO"); open_ $C "$LIGHT" "$B"; H1=$(step "$REPO" a.txt "round 1"); frz $C "$REPO" "$H1"
  S0=$(st $C | jq -cS .)
  UT() { python3 -I "$R/bin/event_untrusted.py" append "$@" >>"$T/o/last" 2>&1; }
  UT --type qa.passed --what $C --detail "QA passed"; UT --type note --what $C --detail "QA passed round 1 $H1"
  for r in $(active $C); do UT --type qa.verdict --what $C --detail "$r pass round 1"; done
  UT --type qa.triggered --what $C --detail "$OWNT"
  QL close --card $C >>"$T/o/last" 2>&1
  ok '[ -n "$S0" ] && [ -s "$R/$(ix .untrusted_events)" ] && [ "$(cnt qa.passed $C)" = 0 ] && ! isdone $C "$H1" && jq -e ".depth == \"off\" or (.count // 0) == 0" <<<"$(role $C "$ATTACKER")"' \
    "AC3-untrusted qa.passed, \"QA passed\", verdict and trigger lines in the untrusted stream count for nothing: no pass, done refuses, no forced role"
  S1=$(st $C | jq -cS .)
  # forged lines in the trusted log itself: unchained, and a real qa line copied with its payload changed (its mac no longer verifies)
  jq -nc --arg c $C --arg h "$H1" '{schema_version: 3, time: "2026-11-19T00:00:00Z", type: "qa.passed", who: {role: null, channel: null, user: null}, what: $c, new: {round: 1, hash: $h}}' >>"$EVLOG"
  jq -nc --arg c $C --arg t "$COMPLEX" '{schema_version: 3, time: "2026-11-19T00:00:00Z", type: "qa.tier-raised", who: {role: null, channel: null, user: null}, what: $c, new: {tier: $t}}' >>"$EVLOG"
  grep '"qa.frozen"' "$EVLOG" | grep -F "$C" | tail -n 1 | jq -c '.type = "qa.passed" | .seq = (.seq + 1000)' >>"$EVLOG"
  ok '[ -n "$S1" ] && [ "$(st $C | jq -cS .)" = "$S1" ] && ! isdone $C "$H1" && [ "$(cnt qa.passed $C)" = 0 ]' \
    "AC3-untrusted forged qa.* lines in the trusted log (unchained, or a copied line whose mac fails) change nothing in status or done"
  pass_round $C 1
  ok 'isdone $C "$H1" && stq $C ".tier == \"$LIGHT\" and .done == true"' "T-STATE-TRUSTED the state is the fold of trusted lines only: after the forged lines the genuine round still passes, the tier is still $LIGHT"
  # DG-5: the owner trigger only through qa_loop.py trigger
  D=t_0a000009; RD=$T/b9; BD=$(mkrepo "$RD"); open_ $D "$LIGHT" "$BD"; HD=$(step "$RD" a.txt "round 1"); frz $D "$RD" "$HD"
  A0=$(role $D "$ATTACKER"); run tr QL trigger --card $D --id "$OWNT"
  ok 'jq -e ".depth == \"off\" or (.count // 0) == 0" <<<"$A0" && [ "$(rc tr)" = 0 ] && lines qa.triggered $D | jq -e --arg t "$OWNT" "[.[] | select(.id == \$t or .trigger == \$t)] | length == 1" &&
    jq -e "(.count // 0) >= 1 and .depth != \"off\" and .forced" <<<"$(role $D "$ATTACKER")" && jq -e ".depth == \"full\"" <<<"$(role $D "$TESTER")"' \
    "DG-5 trigger --id $OWNT (owner command): a trusted qa.triggered line; $ATTACKER is forced on (it was off on this light card) and the tester runs full"
  ;;
plan)   # AC4-eco-security, AC6-data-only, T-LOCAL1, T-TIER-FLOOR
  cp "$RA" "$T/ra.orig"; cp "$QJ" "$T/qj.orig"; cp "$DP" "$T/dp.orig"
  ed "$(p role-assignments)" --arg e "$ECO" '.selection.global = $e'
  C=t_0a00000a; REPO=$T/ba; B=$(mkrepo "$REPO"); open_ $C "$LIGHT" "$B"
  mkdir -p "$REPO/src"; printf 'PASSWORD = "x"\ndef login(password):\n    return password == PASSWORD\n' >"$REPO/src/auth_check.py"; H=$(step "$REPO" a.txt "round 1"); frz $C "$REPO" "$H"
  K=t_0a00000b; RK=$T/bb; BK=$(mkrepo "$RK"); open_ $K "$LIGHT" "$BK"; HK=$(step "$RK" a.txt "round 1"); frz $K "$RK" "$HK"   # control: nothing a security rule matches
  ok 'lines qa.triggered $C | jq -e --arg t "$SEC" "[.[] | select(.id == \$t or .trigger == \$t)] | length == 1" && [ "$(lines qa.triggered $K | jq --arg t "$SEC" "[.[] | select(.id == \$t or .trigger == \$t)] | length")" = 0 ] &&
    jq -e ".depth == \"full\"" <<<"$(role $C "$TESTER")" && jq -e "(.count // 0) >= 1 and .depth != \"off\"" <<<"$(role $C "$ATTACKER")" &&
    jq -e --arg d "$(q --arg l "$LIGHT" ".roles[\"$TESTER\"].depth[\$l]")" ".depth == \$d" <<<"$(role $K "$TESTER")" && jq -e ".depth == \"off\" or (.count // 0) == 0" <<<"$(role $K "$ATTACKER")"' \
    "AC4-eco-security a light card under $ECO whose frozen diff fires $SEC: a trusted qa.triggered line, the tester full and $ATTACKER on (the control card: light depth, $ATTACKER off)"
  cp "$T/ra.orig" "$RA"
  M=t_0a00000c; RM_=$T/bc; BM=$(mkrepo "$RM_"); open_ $M "$MEDIUM" "$BM"; c0=$(role $M "$REV" | jq '.count // empty')
  sum0=$(cd "$R/bin" && find . -type f -exec sha256sum {} + | sort | sha256sum)
  ed .stella/qa-loop.json --arg r "$REV" --arg t "$MEDIUM" '.roles[$r].count[$t] = 3'
  ok '[ "$c0" = 1 ] && data_ok && [ "$(role $M "$REV" | jq ".count")" = 3 ] && [ "$(cd "$R/bin" && find . -type f -exec sha256sum {} + | sort | sha256sum)" = "$sum0" ]' \
    "AC6-data-only $REV count 1 -> 3 for $MEDIUM in the copy's qa-loop.json: plan says 3, no file under bin/ changed"
  ed "$(p role-assignments)" --arg l "$LOCALP" '.selection.global = $l'
  L=t_0a00000d; RL=$T/bd; BL=$(mkrepo "$RL"); open_ $L "$MEDIUM" "$BL"
  ALL1='def rm: (.roles // {}) | if type == "array" then map({key: (.role // .id), value: .}) | from_entries else . end; (rm | length) >= 1 and (rm | to_entries | all((.value.count // 0) == $n or .value.depth == "off")) and ([.. | objects | select(has("parallel")) | .parallel] | length >= 1 and all(. == false))'
  ok 'plan $L | jq -e --argjson n "$LCOUNT" "$ALL1" && [ "$(role $L "$REV" | jq .count)" = "$LCOUNT" ]' "T-LOCAL1 the card's preset is listed in when_local_only: every count is $LCOUNT ($REV too, set to 3), parallel false"
  cp "$T/ra.orig" "$RA"; ed "$(p data-policy)" '.default.mode = "local_only"'
  L2=t_0a00000e; RL2=$T/be; BL2=$(mkrepo "$RL2"); open_ $L2 "$MEDIUM" "$BL2"
  ok 'resolve2; jq -e ".local_only == true" "$T/o/rs.json" && plan $L2 | jq -e --argjson n "$LCOUNT" "$ALL1"' "T-LOCAL1 resolve answers local_only true (data policy): every count is $LCOUNT, parallel false"
  cp "$T/dp.orig" "$DP"; cp "$T/qj.orig" "$QJ"
  F=t_0a00000f; RF=$T/bf; BF=$(mkrepo "$RF"); open_ $F "$MEDIUM" "$BF"
  run o2 open_ $F "$LIGHT" "$BF"; run r1 QL raise --card $F --tier "$LIGHT" --reason lower
  ok '[ "$(rc o2)" != 0 ] && [ "$(rc r1)" != 0 ] && [ "$(rc r1)" != 2 ] && coded r1 && stq $F ".tier == \"$MEDIUM\"" && [ "$(cnt qa.tier-raised $F)" = 0 ]' \
    "T-TIER-FLOOR re-open at $LIGHT and raise to $LIGHT are refused (coded): the tier stays $MEDIUM"
  run r2 QL raise --card $F --tier "$COMPLEX" --reason owner-asked; run o3 open_ $F "$MEDIUM" "$BF"
  ok '[ "$(rc r2)" = 0 ] && [ "$(cnt qa.tier-raised $F)" = 1 ] && stq $F ".tier == \"$COMPLEX\"" && [ "$(rc o3)" != 0 ] && stq $F ".tier == \"$COMPLEX\""' \
    "T-TIER-FLOOR raise to $COMPLEX: one trusted qa.tier-raised line; a later open at $MEDIUM is refused"
  ;;
data)   # AC4-preset-refused, T-COUNT0 (DG-3)
  read -r C_OFF < <(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import stella_data as s; print(s.OFF_REQUIRED)' "$R/bin")
  TRIGQ='.workflow as $w | [$w.required_roles[] | select(.when != "always" and ($w.triggers[.when].can_fire == true))][0]'
  TRIGROLE=$(jq -r "$TRIGQ | .role" "$RT"); TRIGID=$(jq -r "$TRIGQ | .when" "$RT")
  cp "$RA" "$T/ra.orig"; cp "$QJ" "$T/qj.orig"
  # bin/presets-selftest.sh case 3a proves this on its own fixture; here the same validator on the copy's data
  ed "$(p role-assignments)" --arg s "$SEL" --arg r "$TRIGROLE" '.effort_modes["qa-off"] = (.effort_modes[$s] | .builtin = false | .based_on = $s | .label = "qa-off" | .roles[$r] = {active: false})'
  ok '! python3 -I "$R/bin/stella_data.py" check >"$T/o/off" 2>&1 && grep -q "^$C_OFF " "$T/o/off"' "AC4-preset-refused (presets-selftest 3a on the copy's data) a preset turning $TRIGROLE off ($TRIGID can fire) is refused with $C_OFF"
  cp "$T/ra.orig" "$RA"
  ed .stella/qa-loop.json --arg p "$ECO" --arg r "$ATTACKER" --arg t "$MEDIUM" '.presets[$p].counts[$r] = {($t): 0}'
  ok '! data_ok' "AC4-preset-refused a qa-loop preset ($ECO) giving $ATTACKER (required when $TRIGID) count 0 is refused by check"
  cp "$T/qj.orig" "$QJ"
  C=t_0a000010; REPO=$T/b10; B=$(mkrepo "$REPO"); open_ $C "$MEDIUM" "$B"
  ok 'data_ok && plan $C | jq -e "(.roles | length) >= 1"' "T-COUNT0 control: the shipped qa-loop data passes check and plan answers"
  ALW=$(jq -r '[.workflow.required_roles[] | select(.when == "always") | .role][0]' "$RT")
  count0() {   # <label> <jq filter on qa-loop.json>: check refuses it and plan fails closed (non-zero, no roles)
    local lab=$1; cp "$T/qj.orig" "$QJ"; ed .stella/qa-loop.json --arg a "$ALW" --arg r "$ATTACKER" --arg l "$LIGHT" --arg e "$ECO" --arg s "$SEC" "$2"
    run "c0-$1" python3 -I "$R/bin/stella_data.py" check; run "p0-$1" QL plan --card $C --json
    ok '[ "$(rc "c0-$lab")" != 0 ] && coded "c0-$lab" && [ "$(rc "p0-$lab")" != 0 ] && [ "$(rc "p0-$lab")" != 2 ] && coded "p0-$lab" && ! jq -e ".roles" "$T/o/p0-$lab.out"' \
      "T-COUNT0 $1: check refuses (coded) and plan fails closed (coded, no plan)"
  }
  count0 "roles.$ALW.count.$LIGHT=0" '.roles[$a].count[$l] = 0'
  count0 "presets.$ECO.counts.$ALW=0" '.presets[$e].counts[$a] = {($l): 0}'
  count0 "when_local_only.count=0" '.when_local_only.count = 0'
  count0 "role-$ALW-missing" 'del(.roles[$a])'
  count0 "triggers.$SEC.force_roles-without-$ATTACKER" '.triggers[$s].force_roles -= [$r]'
  cp "$T/qj.orig" "$QJ"
  ;;
worker)   # T-WORKER
  C=t_0a000011; REPO=$T/b11; B=$(mkrepo "$REPO"); H=$(step "$REPO" a.txt "round 1"); open_ $C "$MEDIUM" "$B"
  run nw QL status --card $C --json
  n0=$(wc -l <"$EVLOG" 2>/dev/null || echo 0); bad=
  for c in "open --card $C --project $P --tier $COMPLEX --base $B --builder-role $BR" "raise --card $C --tier $COMPLEX --reason r" "freeze --card $C --repo $REPO --hash $H" \
           "plan --card $C --json" "status --card $C --json" "done --card $C --hash $H" "close --card $C" "trigger --card $C --id $OWNT"; do
    STUB_WORKER_MARK=1 python3 -I "$R/bin/qa_loop.py" $c >"$T/o/w" 2>&1; w=$?
    { [ $w != 0 ] && [ $w != 2 ] && grep -q "STL-CFG-312" "$T/o/w"; } || bad="$bad ${c%% *}($w)"
  done
  ok '[ "$(rc nw)" = 0 ] && [ -z "$bad" ] && [ "$(wc -l <"$EVLOG")" = "$n0" ]' "T-WORKER every qa_loop.py subcommand refuses in a worker environment (STL-CFG-312, nothing written; refused wrongly:${bad:- none}); status outside one answers"
  ;;
copy)   # DG-7: the disposable copy is a standalone clone; the builder repo, its branch and hooks are untouched
  C=t_0a000012; REPO=$T/b12; B=$(mkrepo "$REPO")
  printf '#!/bin/sh\ntouch "%s"\n' "$T/hook-ran" >"$REPO/.git/hooks/post-checkout"; chmod +x "$REPO/.git/hooks/post-checkout"
  cp "$REPO/.git/hooks/post-checkout" "$REPO/.git/hooks/post-merge"
  git -C "$REPO" config filter.qa.smudge "sh -c 'touch $T/filter-ran; cat'"; git -C "$REPO" config filter.qa.clean cat; echo '*.txt filter=qa' >"$REPO/.gitattributes"
  G "$REPO" checkout -q -b "$P/$C-x"; H=$(step "$REPO" a.txt "round 1"); rm -f "$T/hook-ran" "$T/filter-ran"
  snap() { { G "$REPO" symbolic-ref HEAD; G "$REPO" rev-parse HEAD; G "$REPO" for-each-ref; G "$REPO" worktree list --porcelain; G "$REPO" status --porcelain; G "$REPO" config --list --local; } 2>&1; }
  S0=$(snap); open_ $C "$MEDIUM" "$B"
  run short QL freeze --card $C --repo "$REPO" --hash "${H:0:12}"
  ok '[ "$(rc short)" != 0 ] && [ "$(rc short)" != 2 ] && coded short && [ "$(cnt qa.opened $C)" = 1 ] && [ "$(cnt qa.frozen $C)" = 0 ]' "DG-7 freeze with an abbreviated hash is refused (coded): the hash must be a full commit id"
  frz $C "$REPO" "$H"
  CP=$(lines qa.frozen $C | jq -r '.[0].copy // empty'); case "$CP" in /*) ;; ?*) CP=$R/$CP;; esac
  ok '[ ! -e "$T/hook-ran" ] && [ ! -e "$T/filter-ran" ] && [ "$(snap)" = "$S0" ] && [ "$(cnt qa.frozen $C)" = 1 ]' \
    "DG-7 freeze runs no hook (post-checkout, post-merge) and no filter of the builder repo; its branch, HEAD, refs, worktrees and config are unchanged"
  ok '[ -n "$CP" ] && case "$(realpath "$CP")" in "$(realpath "$R/$QCP")"/*) true;; *) false;; esac && [ "$(git -C "$CP" rev-parse HEAD)" = "$H" ] &&
    [ "$(cd "$CP" && realpath "$(git rev-parse --git-common-dir)")" = "$(realpath "$CP/.git")" ] && [ ! -e "$CP/.git/objects/info/alternates" ] &&
    [ -z "$(git -C "$CP" config --get filter.qa.smudge)" ] && [ -z "$(ls -A "$CP/.git/hooks" 2>/dev/null | grep -v "\.sample$")" ] &&
    [ "$(lines qa.frozen $C | jq -r ".[0].tree")" = "$(G "$REPO" rev-parse "$H^{tree}")" ] && [ "$(git -C "$CP" symbolic-ref -q --short HEAD)" != "$P/$C-x" ]' \
    "DG-7 the copy is a standalone clone under $QCP at H (own git dir, no alternates, no hook and no repo config of the builder's copied), its tree id is the one recorded, on a branch of its own"
  ;;
merge)   # DG-8: merge-card.sh refuses a card with a trusted qa.opened line unless qa_loop.py done exits 0 on the branch tip
  M=$T/mrepo; git init -q -b main "$M"; printf '.worktrees/\n' >"$M/.gitignore"; printf '{"scripts": {"test": "sh test.sh"}}\n' >"$M/package.json"; printf 'exit 0\n' >"$M/test.sh"
  echo base >"$M/a.txt"; G "$M" add -A; G "$M" commit -qm base; MB=$(G "$M" rev-parse HEAD)
  card() { G "$M" worktree add -q -b "$P/$1-x" "$M/.worktrees/$1" main && echo "$2" >"$M/.worktrees/$1/$1.txt" && G "$M/.worktrees/$1" add -A && G "$M/.worktrees/$1" commit -qm "card $1" && G "$M/.worktrees/$1" rev-parse HEAD; }
  MC() { (cd "$T" && bash "$R/bin/merge-card.sh" "$1" --repo "$M" --owner-approved); }
  A=t_0a000013; TA=$(card $A "a1"); open_ $A "$MEDIUM" "$MB"; frz $A "$M" "$TA"; pass_round $A 1
  A1ok=$(isdone $A "$TA" && echo yes); TA2=$(step "$M/.worktrees/$A" "$A.txt" "a2")   # a commit after the passed round: done is not on the tip
  run ma MC $A
  ok '[ "$A1ok" = yes ] && [ "$(rc ma)" = 3 ] && coded ma && [ "$(G "$M" rev-parse main)" = "$MB" ] && [ "$(cnt qa.opened $A)" = 1 ]' \
    "DG-8 merge-card.sh refuses (exit 3, coded) a card with a trusted qa.opened line whose passed hash is not the branch tip; main unchanged"
  K=t_0a000014; TK=$(card $K "k1"); run mk MC $K   # control: no qa.opened line, merged as before
  Cc=t_0a000015; TC=$(card $Cc "c1"); open_ $Cc "$MEDIUM" "$MB"; frz $Cc "$M" "$TC"; pass_round $Cc 1; run mc MC $Cc
  ok '[ "$(rc mk)" = 0 ] && [ "$(rc mc)" = 0 ] && [ "$(cnt qa.passed $Cc)" = 1 ] && G "$M" merge-base --is-ancestor "$TC" main && G "$M" merge-base --is-ancestor "$TK" main' \
    "DG-8 a card with no qa.opened line merges as before, and a card whose round passed on its tip merges"
  ;;
rt1)   # fix round 1 of Q1: RT1-06, RT1-07, RT1-08, QL-M2 (the fold keeps the highest tier), RT1-12, DG-1 evidence re-hash (pass 2 L4), close --json
  plant() { python3 -I "$R/bin/event_log.py" append --type "$1" --what "$2" --new "$3" >>"$T/o/last" 2>&1; }   # a trusted line, as the owner's tools write it
  fired() { lines qa.triggered "$1" | jq -e --arg t "$SEC" '[.[] | select(.id == $t)] | length == 1' >/dev/null; }
  sbase() {   # <dir>: main with src/auth.py (an admin check and helpers) and a.txt; prints the base commit
    git init -q -b main "$1" && mkdir -p "$1/src" && { printf 'def allowed(user):\n    if user.role != "admin":\n        return False\n    return True\n'
    for i in $(seq 1 12); do printf 'def helper%s(x):\n    return x + %s\n' "$i" "$i"; done; } >"$1/src/auth.py" && echo x >"$1/a.txt" &&
    G "$1" add -A && G "$1" commit -qm base && G "$1" rev-parse HEAD; }
  C=t_0a000020; R6=$T/b20; B6=$(sbase "$R6"); open_ $C "$LIGHT" "$B6"
  G "$R6" mv src/auth.py src/helpers.py; sed -i '2,3d' "$R6/src/helpers.py"; G "$R6" commit -qam "move helpers"; frz $C "$R6" "$(G "$R6" rev-parse HEAD)"
  K=t_0a000021; R7=$T/b21; B7=$(sbase "$R7"); open_ $K "$LIGHT" "$B7"
  mkdir -p "$R7/lib/Auth"; printf 'def ok(u):\n    return True\n' >"$R7/lib/Auth/Login.py"; printf 'STORE = {}\n' >"$R7/src/Session.py"
  G "$R7" add -A; G "$R7" commit -qm login; frz $K "$R7" "$(G "$R7" rev-parse HEAD)"
  ok '[ "$(cnt qa.frozen $C)" = 1 ] && fired $C' "RT1-06 src/auth.py renamed to src/helpers.py with its admin check deleted fires $SEC (the diff has rename detection off: the old path is matched)"
  ok '[ "$(cnt qa.frozen $K)" = 1 ] && fired $K' "RT1-06 new files lib/Auth/Login.py and src/Session.py fire $SEC (path globs match whatever the letter case)"
  # RT1-07: one card id whatever its letter case
  V=T_0A000022; v=t_0a000022; RV=$T/b22; BV=$(mkrepo "$RV"); HV=$(step "$RV" a.txt r1); open_ $V "$MEDIUM" "$BV"; frz $V "$RV" "$HV"
  DG8=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import qa_loop; print("open" if qa_loop.state(sys.argv[2])["opened"] else "none")' "$R/bin" "$v" 2>>"$T/o/last")   # merge-card.sh's DG-8 query
  run o7 QL open --card "$v" --project "$P" --tier "$MEDIUM" --base "$BV" --builder-role "$BR"; run o8 QL open --card t_0A000022 --project "$P" --tier "$MEDIUM" --base "$BV" --builder-role "$BR"
  ok '[ "$DG8" = open ] && stq "$v" ".round == 1 and .done == false" && [ "$(rc o7)" != 0 ] && [ "$(rc o7)" != 2 ] && coded o7 && [ "$(rc o8)" != 0 ] && [ "$(rc o8)" != 2 ] &&
    [ "$(cnt qa.opened "$v")" = 0 ] && [ "$(cnt qa.opened t_0A000022)" = 0 ] && [ "$(cnt qa.opened $V)" = 1 ]' \
    "RT1-07 a loop opened as $V is the loop of $v: merge-card's DG-8 query sees it, status answers round 1, and open of a case variant is refused (coded, no line)"
  # RT1-08: open once; a re-open (same tier, other project) is refused, and a later trusted qa.opened line changes nothing of record
  C=t_0a000023; R8=$T/b23; B8=$(mkrepo "$R8"); H8=$(step "$R8" a.txt r1); open_ $C "$MEDIUM" "$B8"; frz $C "$R8" "$H8"
  PL='{preset, local_only, parallel, counts: [.roles[] | .count]}'; P0=$(plan $C | jq -cS "$PL")
  run o9 QL open --card $C --project qa-other --tier "$MEDIUM" --base "$H8" --builder-role "$BR"
  ok '[ -n "$P0" ] && [ "$(rc o9)" != 0 ] && [ "$(rc o9)" != 2 ] && coded o9 && [ "$(cnt qa.opened $C)" = 1 ] && [ "$(plan $C | jq -cS "$PL")" = "$P0" ]' \
    "RT1-08 a re-open at the same tier with another project inside an open round is refused (coded, no line); the plan is unchanged"
  plant qa.opened $C "$(jq -nc --arg t "$LIGHT" --arg b "$BR" --arg p "$LOCALP" --arg h "$H8" '{project: "qa-other", tier: $t, base: $h, builder_role: $b, preset: $p, local_only: true}')"
  plant qa.tier-raised $C "$(jq -nc --arg t "$LIGHT" '{tier: $t, reason: "lower"}')"; plant qa.depth-raised $C "$(jq -nc --arg t "$LIGHT" '{depth: $t}')"
  ok '[ "$(cnt qa.opened $C)" = 2 ] && [ "$(plan $C | jq -cS "$PL")" = "$P0" ] && stq $C ".local_only == false"' \
    "RT1-08 a second trusted qa.opened line (another project, preset $LOCALP, local_only) changes neither the plan nor local_only: the first open is of record"
  ok 'stq $C ".tier == \"$MEDIUM\" and .depth == \"$MEDIUM\""' "QL-M2 trusted qa.opened, qa.tier-raised and qa.depth-raised lines at $LIGHT after $MEDIUM: tier and depth stay $MEDIUM (the highest, not the last)"
  # RT1-12: a card that passed at round $NORMAL and was reopened gets rounds again, and is escalated at the end of them
  C=t_0a000024; R9=$T/b24; B9=$(mkrepo "$R9"); open_ $C "$MEDIUM" "$B9"
  for r in $(seq 1 "$NORMAL"); do H=$(step "$R9" a.txt "round $r"); frz $C "$R9" "$H"; if [ "$r" -lt "$NORMAL" ]; then fail_round $C "$r" "$BLOCK"; else pass_round $C "$r"; fi; done
  P9=$(isdone $C "$H" && echo yes); plant qa.reopened $C "$(jq -nc --arg c $C --arg h "$H" '{card: $c, hash: $h, tests: ["qa-t-x"]}')"
  H=$(step "$R9" a.txt fix); run f9 QL freeze --card $C --repo "$R9" --hash "$H"
  ok '[ "$P9" = yes ] && [ "$(rc f9)" = 0 ] && stq $C ".round == $((NORMAL + 1)) and .cap == $((2 * NORMAL)) and .done == false"' \
    "RT1-12 a card reopened after passing in round $NORMAL can be frozen again: round $((NORMAL + 1)), cap $((2 * NORMAL)) ($NORMAL more rounds)"
  a0=$(alerts); fail_round $C $((NORMAL + 1)) "$BLOCK"
  for r in $(seq $((NORMAL + 2)) $((2 * NORMAL))); do H=$(step "$R9" a.txt "round $r"); frz $C "$R9" "$H"; fail_round $C "$r" "$BLOCK"; done
  ok '[ "$(cnt qa.escalated $C)" = 1 ] && [ "$(alerts)" -gt "$a0" ] && [ "$(cnt qa.climbed $C)" = 0 ]' "RT1-12 the reopened card failing to its new cap is escalated (qa.escalated, an owner alert), never stuck"
  # pass 2 L4 (DG-1): a pass verdict whose evidence changed after the verdict does not count; close --json answers JSON
  C=t_0a000025; R5=$T/b25; B5=$(mkrepo "$R5"); H5=$(step "$R5" a.txt r1); open_ $C "$MEDIUM" "$B5"; frz $C "$R5" "$H5"; verdicts $C 1
  VE=$(ls "$R/$QEV/$C/1/"v-*.txt 2>/dev/null | head -n 1); echo tampered >>"$VE"
  run c5 QL close --card $C
  ok '[ -n "$VE" ] && [ "$(rc c5)" != 0 ] && [ "$(rc c5)" != 2 ] && coded c5 && [ "$(cnt qa.passed $C)" = 0 ] && ! isdone $C "$H5"' \
    "DG-1 a pass verdict whose evidence ($(basename "$VE")) changed after the verdict: close does not pass (coded), done refuses"
  run c6 QL close --card $C --json
  ok '[ "$(rc c6)" != 0 ] && [ "$(rc c6)" != 2 ] && jq -e --arg c $C ".card == \$c and (.code | test(\"^STL-QA-[0-9]{3}$\"))" "$T/o/c6.out"' "close --json: a refusal answers {card, code, problem} on stdout"
  ;;
rtf)   # fix cycle 2 of Q1: RTF-01 (a verdict per slot), RTF-02 (engine diffs ignore the copy's .gitattributes), RTF-04 (blocking judged at close), RTF-05 (one lock per card)
  fired() { lines qa.triggered "$1" | jq -e --arg t "$SEC" '[.[] | select(.id == $t)] | length == 1' >/dev/null; }
  vds() { QF verdict --card "$1" --round 1 --role "$2" --result "$3" --evidence "$(ev "$1" 1 "$4")" "${@:5}" >>"$T/o/last" 2>&1; }   # <card> <role> <result> <name> [--slot N]
  others() { local r; for r in $(active "$1"); do [ "$r" = "$REV" ] || vds "$1" "$r" pass "v-$r"; done; }
  cp "$QJ" "$T/qj.orig"; ed .stella/qa-loop.json --arg r "$REV" --arg t "$MEDIUM" '.roles[$r].count[$t] = 3'   # owner data: 3 slots of $REV
  C=t_0a000030; RA_=$T/b30; B=$(mkrepo "$RA_"); open_ $C "$MEDIUM" "$B"; H=$(step "$RA_" a.txt r1); frz $C "$RA_" "$H"
  vds $C "$REV" fail v-s1; vds $C "$REV" pass v-s1b; others $C; QL close --card $C >>"$T/o/last" 2>&1
  ok 'data_ok && [ "$(role $C "$REV" | jq .count)" = 3 ] && [ "$(cnt qa.passed $C)" = 0 ] && [ "$(cnt qa.round-failed $C)" = 1 ] && ! isdone $C "$H"' \
    "RTF-01 $REV has 3 slots; its fail verdict then a later pass (no slot named: slot 1): the fail stands, the round fails, no qa.passed"
  C=t_0a000031; RB_=$T/b31; B=$(mkrepo "$RB_"); open_ $C "$MEDIUM" "$B"; H=$(step "$RB_" a.txt r1); frz $C "$RB_" "$H"
  vds $C "$REV" pass v-s1; others $C; run c31 QL close --card $C
  run s4 QF verdict --card $C --round 1 --role "$REV" --result pass --evidence "$(ev $C 1 v-s4)" --slot 4
  ok '[ "$(rc c31)" != 0 ] && [ "$(rc c31)" != 2 ] && coded c31 && [ "$(cnt qa.passed $C)" = 0 ] && ! isdone $C "$H" && [ "$(rc s4)" != 0 ] && [ "$(rc s4)" != 2 ] && coded s4' \
    "RTF-01 one pass of $REV for its 3 slots: close refuses (coded), the round stays open; a verdict for slot 4 of 3 is refused (coded)"
  vds $C "$REV" pass v-s2 --slot 2; vds $C "$REV" pass v-s3 --slot 3; QL close --card $C >>"$T/o/last" 2>&1
  ok 'isdone $C "$H" && [ "$(cnt qa.passed $C)" = 1 ]' "RTF-01 (control) passes from $REV slots 2 and 3 too: the round passes on H"
  cp "$T/qj.orig" "$QJ"
  # RTF-02: one line '*.py -diff' in the card's .gitattributes must not hide added lines from the trigger words or from the mutants
  util() { mkdir -p "$1/src"; printf 'import subprocess\n\ndef run(cmd):\n    return subprocess.run(cmd, shell=True)\n' >"$1/src/util.py"; }
  C=t_0a000032; RC_=$T/b32; B=$(mkrepo "$RC_"); open_ $C "$LIGHT" "$B"; util "$RC_"; H=$(step "$RC_" a.txt r1); frz $C "$RC_" "$H"   # control: no attribute
  K=t_0a000033; RK_=$T/b33; B=$(mkrepo "$RK_"); open_ $K "$LIGHT" "$B"; util "$RK_"; printf '*.py -diff\n' >"$RK_/.gitattributes"; H=$(step "$RK_" a.txt r1); frz $K "$RK_" "$H"
  CLN=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import qa_tests; print(sorted(qa_tests.changed_lines(sys.argv[2], "src/util.py") or []))' "$R/bin" $K 2>>"$T/o/last")
  ok 'fired $C && fired $K && [ "$CLN" = "[1, 2, 3, 4]" ]' \
    "RTF-02 with '*.py -diff' in the card's .gitattributes, 'subprocess' on an added line still fires $SEC (as on the control card), and qa_tests.changed_lines gives every added line of src/util.py ($CLN)"
  # RTF-04: blocking is judged from the current depth and the highest severity, not fixed at submit
  C=t_0a000034; RD_=$T/b34; B=$(mkrepo "$RD_"); open_ $C "$LIGHT" "$B"; H=$(step "$RD_" a.txt r1); frz $C "$RD_" "$H"
  f=$(finding $C 1 "$MEDSEV" check.sh qa-rtf04a); p0=$(st $C | jq .pending)
  run r34 QL raise --card $C --tier "$MEDIUM" --reason "owner: medium after all"; verdicts $C 1; run c34 QL close --card $C
  ok '[ "$p0" = 0 ] && [ "$(rc r34)" = 0 ] && stq $C ".pending == 1" && [ "$(rc c34)" != 0 ] && [ "$(rc c34)" != 2 ] && coded c34 && [ "$(cnt qa.passed $C)" = 0 ]' \
    "RTF-04 a $MEDSEV finding reported on the $LIGHT card is pending its repro after a raise to $MEDIUM in the same round: close refuses (coded)"
  repro $C "$f"; QL close --card $C >>"$T/o/last" 2>&1
  ok '[ "$(cnt qa.finding-confirmed $C)" = 1 ] && [ "$(cnt qa.round-failed $C)" = 1 ] && [ "$(cnt qa.passed $C)" = 0 ] && ! isdone $C "$H"' \
    "RTF-04 its repro (check.sh exits 1) then runs and confirms it: the round fails"
  C=t_0a000035; RE_=$T/b35; B=$(mkrepo "$RE_"); open_ $C "$LIGHT" "$B"; H=$(step "$RE_" a.txt r1); frz $C "$RE_" "$H"
  f=$(finding $C 1 "$MEDSEV" check.sh qa-rtf04b); e=$(ev $C 1 rev-copy)
  jq --arg s "$BLOCK" --arg e "$e" '.[0].severity = $s | .[0].repro = null | .[0].evidence = [$e]' "$f" >"$T/f35.json"
  QF submit --card $C --round 1 --role "$REV" --file "$T/f35.json" >>"$T/o/last" 2>&1; p1=$(st $C | jq .pending)
  repro $C "$f"; verdicts $C 1; QL close --card $C >>"$T/o/last" 2>&1
  ok '[ "$p1" = 1 ] && [ "$(cnt qa.finding-confirmed $C)" = 1 ] && [ "$(cnt qa.passed $C)" = 0 ] && ! isdone $C "$H"' \
    "RTF-04 the tester's $MEDSEV copy (with a repro) and $REV's $BLOCK copy (none) of one finding: pending, the tester's repro confirms it, no pass"
  # RTF-05: every qa command that writes a card's state takes the card's one lock (whatever the id's spelling): close and submit wait for it
  cat >"$T/lock.py" <<'PY'
import json, subprocess, sys, time
top, card, spelled, argv = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.argv[4]); sys.path.insert(0, top + "/bin")
import qa_loop as ql
d = ql.data()
mine = lambda: len([l for l in ql.el.proof_lines() if ql.same(l.get("what"), card)])
n0 = mine()
with ql.card_lock(spelled, d):
    p = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(3)
    waited = p.poll() is None and mine() == n0
sys.exit(0 if waited and p.wait(120) == 0 else 1)
PY
  C=t_0a000036; RF_=$T/b36; B=$(mkrepo "$RF_"); open_ $C "$MEDIUM" "$B"; H=$(step "$RF_" a.txt r1); frz $C "$RF_" "$H"; verdicts $C 1
  run l36 python3 -I "$T/lock.py" "$R" $C T_0A000036 "$(jq -nc --arg r "$R" --arg c $C '["python3", "-I", ($r + "/bin/qa_loop.py"), "close", "--card", $c]')"
  K=t_0a000037; RG_=$T/b37; B=$(mkrepo "$RG_"); open_ $K "$MEDIUM" "$B"; H7=$(step "$RG_" a.txt r1); frz $K "$RG_" "$H7"
  e=$(ev $K 1 f-lock); jq -n --arg e "$e" --arg s "$MEDSEV" '[{check: "lock", file: "a.txt", lines: [1, 1], test: "check.sh", severity: $s, repro: null, evidence: [$e], static: true}]' >"$T/f37.json"
  run l37 python3 -I "$T/lock.py" "$R" $K $K "$(jq -nc --arg r "$R" --arg c $K --arg f "$T/f37.json" --arg t "$TESTER" '["python3", "-I", ($r + "/bin/qa_findings.py"), "submit", "--card", $c, "--round", "1", "--role", $t, "--file", $f]')"
  ok '[ "$(rc l36)" = 0 ] && isdone $C "$H" && [ "$(rc l37)" = 0 ] && [ "$(cnt qa.finding $K)" = 1 ]' \
    "RTF-05 close and submit wait while the card's lock is held (taken under another spelling of the id): nothing written, then each runs once it is free"
  ;;
limits)   # owner fixes after Q1 (2026-11-20): RTF-08 (a size limit per project, in data, before checkout), RTF-09 (rungs.json keyed by the board's id), Q1-CVER-04 ("++ " lines)
  fired() { lines qa.triggered "$1" | jq -e --arg t "$SEC" '[.[] | select(.id == $t)] | length == 1' >/dev/null; }
  cp "$QJ" "$T/qj.orig"; ed .stella/qa-loop.json '.tests.max_copy_bytes = {default: 4096, projects: {}}'
  C=t_0a000040; RA_=$T/b40; B=$(mkrepo "$RA_"); open_ $C "$MEDIUM" "$B"; head -c 8192 /dev/zero | tr '\0' x >"$RA_/big.txt"; H=$(step "$RA_" a.txt r1)
  run f40 QL freeze --card $C --repo "$RA_" --hash "$H"
  ok 'data_ok && [ "$(rc f40)" != 0 ] && [ "$(rc f40)" != 2 ] && coded f40 && grep -q max_copy_bytes "$T/o/f40.out" "$T/o/f40.err" && [ "$(cnt qa.frozen $C)" = 0 ] && [ -z "$(ls -A "$R/$QCP/$C" 2>/dev/null)" ]' \
    "RTF-08 a frozen tree over the default limit (8 KiB of 4 KiB): freeze is refused (coded, names max_copy_bytes) before any checkout: no qa.frozen line, no copy left"
  ed .stella/qa-loop.json --arg p "$P" '.tests.max_copy_bytes.projects[$p] = 65536'
  frz $C "$RA_" "$H"
  ok 'data_ok && [ "$(cnt qa.frozen $C)" = 1 ]' "RTF-08 the card's project has its own limit in the data (64 KiB): the same freeze goes through"
  cp "$T/qj.orig" "$QJ"
  C=T_0A000041; RB_=$T/b41; B=$(mkrepo "$RB_"); open_ $C "$MEDIUM" "$B"
  python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import qa_loop as q; d = q.data(); s = q.state(sys.argv[2], d); q.project_rung(s["card"], s["builder_role"], 2, d)' "$R/bin" t_0a000041 2>>"$T/o/last"
  ER=$(jq -er --arg c t_0a000041 --arg r "$BR" 'if type == "object" and ((.[$c] // {}) | type == "object") then .[$c][$r] // 1 else error end | select(type == "number" and . == floor and . >= 1 and . <= 999)' "$R/$QRG" 2>/dev/null)
  ok '[ "$ER" = 2 ] && jq -e "has(\"T_0A000041\") | not" "$R/$QRG"' "RTF-09 a loop opened as T_0A000041 climbs to rung 2: rungs.json holds it under the board's id t_0a000041, read the way bin/escalate.sh reads it ($ER)"
  C=t_0a000042; RC_=$T/b42; B=$(mkrepo "$RC_"); open_ $C "$LIGHT" "$B"; printf '++ token = 1\n' >"$RC_/notes.txt"; H=$(step "$RC_" a.txt r1); frz $C "$RC_" "$H"
  K=t_0a000043; RK_=$T/b43; B=$(mkrepo "$RK_"); open_ $K "$LIGHT" "$B"; printf '++ nothing to see\n' >"$RK_/notes.txt"; H=$(step "$RK_" a.txt r1); frz $K "$RK_" "$H"
  ok 'fired $C && ! fired $K && [ "$(cnt qa.frozen $C)" = 1 ]' "Q1-CVER-04 an added line whose text starts with '++ ' is scanned: 'token' on it fires $SEC (the control line with no trigger word does not)"
  # Q1-OF-CVER-01: a carriage return or another line-break character inside an added line must not hide the rest of the line from the scan
  C=t_0a000044; RD_=$T/b44; B=$(mkrepo "$RD_"); open_ $C "$LIGHT" "$B"; printf 'x=1\rpassword=2\n' >"$RD_/notes.txt"; H=$(step "$RD_" a.txt r1); frz $C "$RD_" "$H"
  K=t_0a000045; RE_=$T/b45; B=$(mkrepo "$RE_"); open_ $K "$LIGHT" "$B"; printf 'x=1\fpassword=2\n' >"$RE_/notes.txt"; H=$(step "$RE_" a.txt r1); frz $K "$RE_" "$H"
  ok 'fired $C && fired $K' "Q1-OF-CVER-01 'password' after a carriage return (and after a form feed) in an added line still fires $SEC"
  # Q1-OF-CVER-03: the limit counts the history the copy clones too, checked in the builder's repo before anything is cloned
  cp "$QJ" "$T/qj.orig"; ed .stella/qa-loop.json '.tests.max_copy_bytes = {default: 8192, projects: {}}'
  C=t_0a000046; RF_=$T/b46; B=$(mkrepo "$RF_"); open_ $C "$MEDIUM" "$B"; head -c 65536 /dev/urandom >"$RF_/blob.bin"; step "$RF_" a.txt big >/dev/null; rm "$RF_/blob.bin"; H=$(step "$RF_" a.txt r1)
  run f46 QL freeze --card $C --repo "$RF_" --hash "$H"
  ok '[ "$(rc f46)" != 0 ] && [ "$(rc f46)" != 2 ] && coded f46 && grep -q max_copy_bytes "$T/o/f46.out" "$T/o/f46.err" && [ "$(cnt qa.frozen $C)" = 0 ] && [ -z "$(ls -A "$R/$QCP/$C" 2>/dev/null)" ]' \
    "Q1-OF-CVER-03 a small tip whose history holds 64 KiB of random data, under an 8 KiB limit: freeze is refused before anything is cloned (no copy left)"
  cp "$T/qj.orig" "$QJ"
  ;;
esac
finish
