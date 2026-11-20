#!/usr/bin/env bash
# Hermetic self-test for the QA loop (phase Q1, items A1 and A2: bin/qa_loop.py), written tests-first by the tester (T1).
# Every section runs in its own scratch root (bash qa-loop-selftest.sh <section>); no argument runs them all.
# Sections -> checks (tests.json ids):
#   climb  AC1-climb4, T-CLIMB-LINE, T-RUNGS      stop3  AC1-stop3          depth  T-DEPTH-BUMP, DG-5 (fix_grew at freeze)
#   bind   AC2-bind, DG-1, DG-2                   trust  AC3-untrusted, T-STATE-TRUSTED, DG-5 (owner trigger)
#   plan   AC4-eco-security, AC6-data-only, T-LOCAL1, T-TIER-FLOOR       data   AC4-preset-refused, T-COUNT0 (DG-3)
#   worker T-WORKER   copy DG-7   merge DG-8 (bin/merge-card.sh's QA check on a scratch repo, run here: merge-card-selftest is shared)
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
SECTIONS="climb stop3 depth bind trust plan data worker copy merge"
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
esac
finish
