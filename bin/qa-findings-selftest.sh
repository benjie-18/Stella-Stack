#!/usr/bin/env bash
# Hermetic self-test for bin/qa_findings.py (phase Q1 item B: evidence, findings, the mechanical merge). Written test-first.
# Cases (tests.json ids): AC3-noevidence, AC6-dedupe, AC7-unconfirmed, AC7-medium-light, AC7-base-not-charged, T-MERGE-ORDER,
#   T-WORKER, RTF-03 (a confirmed finding survives its evidence), RTF-06 (repro order and cap); with them: evidence whose digest changed after registration is void, an evidence path outside
#   qa_evidence/<card>/<round>/ is refused, a findings file over the size cap or with a shell-string repro is refused.
# Tier, severity, role and builder ids are read from the copy's data; a card is set up through bin/qa_loop.py open and freeze.
# ASSUMPTIONS (what design.md leaves open; the builder aligns with them or raises them):
#  F1 submit --file J: J is {"findings": [<finding>...]}; a finding may carry a reviewer "id" and a free "detail" text, both outside
#     the fingerprint (the "wording").
#  F2 a finding's evidence paths are relative to the stack root (as the index key qa_evidence is); evidence --file takes the
#     absolute path of the file.
#  F3 merge --card C --json answers {"fix_list": [...]} (or that list itself); an entry carries fingerprint, severity, roles (a
#     list), blocking (a boolean) and the finding's check and file. A finding that is not charged is absent or has blocking false.
#  F4 a trusted qa.* line has type qa.<name> and what = the card id; its payload (status, fingerprint, path, sha256, tests) is read
#     by value anywhere in the line. Planted lines go through event_log.py append --new <payload>.
#  F5 a repro "fails as stated" when its argv exits non-zero in the frozen copy.
#  F6 a refusal: exit != 0 and an STL-QA code of item B's range (150-179); a worker environment: STL-CFG-312 (event_log.owner_only).
ME=qa-findings-selftest
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# ---- harness: a scratch root of its own (bin, .stella, docs and the root config files copied), its own HOME, temp, alert folder,
# box homes (BOX_HERMES_ROOT) and git config; the trusted event log is the scratch root's own (event_log.py makes its writer state) ----
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
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ BOX_HERMES_ROOT=$T/hermes
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
POL=$R/$(ix '.files[] | select(.id == "owner-auth") | .path')
for v in $(jq -r '.worker_signals.token_env[]?' "$POL" 2>/dev/null); do unset "$v"; done
jq -r '.sandbox.boxed_profiles[]? as $p | .profiles[$p].dir // ("profiles/" + $p)' "$RJ" 2>/dev/null | while IFS= read -r d; do mkdir -p "$T/hermes/$d/home"; done
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH
EV=$R/$(ix .event_log)
QJ=$R/.stella/qa-loop.json; RT=$R/.stella/routing.json
QL=$R/bin/qa_loop.py
fails=0; n=0
# ok <test> <label>: a FAIL line (never a crash) with the last output of the case under it
ok() { n=$((n+1)); if ( set -o pipefail; eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/o/last" ] && tail -n 3 "$T/o/last" | cut -c1-240 | sed 's/^/     | /'; fi; : >"$T/o/last"; }
finish() { echo "# $ME: $n cases, $fails failed"; [ "$fails" = 0 ] && echo "$ME PASS" || echo "$ME FAIL ($fails)"; [ "$fails" = 0 ]; exit $?; }
# run <tag> <cmd...>: stdout to $T/o/<tag>.out, stderr to $T/o/<tag>.err, exit code in RC; a command (not a function) is stopped after 300 s
run() { local t=$1; shift; if declare -F "$1" >/dev/null; then "$@"; else timeout -k 5 300 "$@"; fi >"$T/o/$t.out" 2>"$T/o/$t.err"; RC=$?; cat "$T/o/$t.out" "$T/o/$t.err" >"$T/o/last" 2>/dev/null; }
ed() { local f=$R/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <file under the root> <jq args and filter>
# coded <tag> <lo> <hi>: the output of that run holds an STL-QA code in [lo, hi] (the module's range in design.md)
coded() { cat "$T/o/$1.out" "$T/o/$1.err" 2>/dev/null | grep -oE 'STL-QA-[0-9]{3}' | awk -v lo="$2" -v hi="$3" '{ c = substr($0, 8) + 0; if (c >= lo && c <= hi) f = 1 } END { exit !f }'; }
c312() { grep -qs STL-CFG-312 "$T/o/$1.out" "$T/o/$1.err"; }   # a worker environment refused (event_log.owner_only)
# the trusted log, read only through its own tool; lines <type> <card>: the lines of that type whose what is the card
EVJ() { python3 -I "$R/bin/event_log.py" tail --json -n 1000000 2>/dev/null || echo '[]'; }
lines() { EVJ | jq -c --arg t "$1" --arg c "$2" '[.[] | select(.type == $t and .what == $c)]'; }
cnt() { lines "$1" "$2" | jq length; }
ntype() { EVJ | jq --arg t "$1" '[.[] | select(.type == $t)] | length'; }
logsum() { cat "$EV" 2>/dev/null | sha256sum; }
plant() { python3 -I "$R/bin/event_log.py" append --type "$1" --what "$2" --new "$3" >/dev/null; }   # a trusted line, as the owner's tools write it
G() { git -C "$1" -c user.name=qa -c user.email=qa@scratch.invalid -c commit.gpgsign=false "${@:2}"; }
rnd() { local r; r=$(python3 -I "$QL" status --card "$1" --json 2>/dev/null | jq -r '.round // empty' 2>/dev/null); echo "${r:-1}"; }

QF=$R/bin/qa_findings.py
L=$(jq -r .depth_bump.from "$QJ"); M=$(jq -r .depth_bump.to "$QJ")
mapfile -t SEVS < <(jq -r '.severities[].id' "$QJ")
SEVJ=$(jq -c '[.severities[].id]' "$QJ")
S_HI=$(jq -r --arg l "$L" '[.severities[] | select(.blocks_on == "all" or ((.blocks_on | type) == "array" and (.blocks_on | index($l)) != null))][0].id // empty' "$QJ")
S_MED=$(jq -r --arg l "$L" --arg m "$M" '[.severities[] | select((.blocks_on | type) == "array" and (.blocks_on | index($m)) != null and (.blocks_on | index($l)) == null)][0].id // empty' "$QJ")
mapfile -t REV < <(jq -r '.roles | to_entries[] | select(.value.kind == "review") | .key' "$QJ")
R1=${REV[0]:-}; R2=${REV[1]:-${REV[0]:-}}
BR=$(jq -r '.builder_roles[0]' "$RT")
EVD=$(ix .qa_evidence)
ok '[ -n "$S_HI" ] && [ -n "$S_MED" ] && [ "${#SEVS[@]}" -ge 4 ] && [ -n "$R1" ] && [ -n "$BR" ] && [ -n "$EVD" ] && python3 -I "$R/bin/stella_data.py" check' \
  "precondition: the data names a severity blocking on $L, one blocking on $M only, a reviewer role, a builder role, qa_evidence; data checks"

# ---- a card repo (base H0, card commit H1) and two cards frozen on H1: CM on tier $M, CL on tier $L ----
REPO=$T/repo; mkdir -p "$REPO/src"; echo base >"$REPO/src/a.txt"; G "$REPO" init -q -b main; G "$REPO" add -A; G "$REPO" commit -qm base
H0=$(G "$REPO" rev-parse HEAD); echo change >>"$REPO/src/a.txt"; G "$REPO" commit -qam card; H1=$(G "$REPO" rev-parse HEAD)
CM=t_0a0f1001 CL=t_0a0f1002
card() { python3 -I "$QL" open --card "$1" --project qa-proj --tier "$2" --base "$H0" --builder-role "$BR" && python3 -I "$QL" freeze --card "$1" --repo "$REPO" --hash "$H1"; }
run oc1 card "$CM" "$M"; r1=$RC; run oc2 card "$CL" "$L"; r2=$RC
ok '[ $r1 = 0 ] && [ $r2 = 0 ]' "precondition: card $CM (tier $M) and card $CL (tier $L) opened and frozen on the card hash (qa_loop.py open, freeze)"
# evf <card> <name>: an evidence file under qa_evidence/<card>/<round>/; prints its root-relative path. reg <card> <path>: registers it
evf() { local p; p=$EVD/$1/$(rnd "$1")/$2; mkdir -p "$R/$(dirname "$p")"; printf 'qa evidence %s %s\n' "$1" "$2" >"$R/$p"; echo "$p"; }
reg() { python3 -I "$QF" evidence --card "$1" --round "$(rnd "$1")" --file "$R/$2"; }
arr() { jq -nc '$ARGS.positional' --args "$@"; }
# fnd <marker> <severity> <test> <static> <repro JSON> <evidence JSON>: one finding (check qa-chk-<marker>, file src/<marker>.py)
fnd() { jq -nc --arg m "$1" --arg s "$2" --arg t "$3" --argjson st "$4" --argjson r "$5" --argjson e "$6" \
  '{check: ("qa-chk-" + $m), file: ("src/" + $m + ".py"), lines: [3, 9], test: $t, severity: $s, repro: $r, evidence: $e, static: $st}'; }
mkset() { jq -sc '{findings: .}' >"$T/$1"; }   # stdin: findings, one per line -> a findings file
SUB() { python3 -I "$QF" submit --card "$1" --round "$(rnd "$1")" --role "$2" --file "$T/$3"; }
FIX() { python3 -I "$QF" merge --card "$1" --json 2>/dev/null | jq -c '(if type == "object" then .fix_list else . end) // []' 2>/dev/null; }
ent() { FIX "$1" | jq -c --arg f "src/$2.py" '[.[] | select(tostring | contains($f))]'; }   # the fix-list entries of one finding
blocking() { ent "$1" "$2" | jq -e 'length == 1 and .[0].blocking == true'; }
uncharged() { ent "$1" "$2" | jq -e 'all(.[]; .blocking != true)'; }   # absent, or listed and not blocking
fline() { lines qa.finding "$1" | jq -c --arg f "src/$2.py" '[.[] | select(tostring | contains($f))]'; }
fpr() { fline "$1" "$2" | jq -r '[.[] | .. | objects | .fingerprint? | strings][0] // empty'; }
status_is() { fline "$1" "$2" | jq -e --arg s "$3" 'length >= 1 and all(.[]; [.. | strings] | any(. == $s))'; }

# ---- evidence: registered with its digest; a path outside qa_evidence/<card>/<round>/ refused ----
E1=$(evf "$CM" run.log); run e1 reg "$CM" "$E1"; EJ1=$(arr "$E1")
ok '[ $RC = 0 ] && lines qa.evidence "$CM" | jq -e --arg h "$(sha256sum <"$R/$E1" | cut -d" " -f1)" "any(.[]; [.. | strings] | any(. == \$h))"' \
  "AC3-noevidence (control) evidence --file registers the file: a trusted qa.evidence line holding its sha256"
RN=$(rnd "$CM"); mkdir -p "$R/$EVD/$CM/99" "$R/$EVD/other"
echo x >"$T/outside.log"; echo x >"$R/$EVD/$CM/99/other.log"; echo x >"$R/$EVD/other/x.log"; ln -sf "$T/outside.log" "$R/$EVD/$CM/$RN/link.log"
for p in "$T/outside.log" "$R/$EVD/$CM/99/other.log" "$R/$EVD/$CM/$RN/../../other/x.log" "$R/$EVD/$CM/$RN/link.log"; do
  b=$(cnt qa.evidence "$CM"); run eo python3 -I "$QF" evidence --card "$CM" --round "$RN" --file "$p"
  ok '[ $RC != 0 ] && coded eo 150 179 && [ "$(cnt qa.evidence "$CM")" = "$b" ]' "AC3-noevidence evidence outside qa_evidence/<card>/<round>/ refused, coded, no qa.evidence line: ${p#"$T"/}"
done

# ---- AC3-noevidence: no evidence, unregistered evidence, evidence changed after registration -> void, never in the fix list ----
E2=$(evf "$CM" changed.log); reg "$CM" "$E2" >/dev/null 2>&1; echo tampered >>"$R/$E2"
E3=$(evf "$CM" unregistered.log)
{ fnd noev "$S_HI" qa-t-noev true null null; fnd unreg "$S_HI" qa-t-unreg true null "$(arr "$E3")"; fnd chg "$S_HI" qa-t-chg true null "$(arr "$E2")"
  fnd ok1 "$S_HI" qa-t-ok1 true null "$EJ1"; } | mkset ev.json
run s1 SUB "$CM" "$R1" ev.json
ok 'status_is "$CM" noev void && uncharged "$CM" noev && [ "$(ent "$CM" noev | jq length)" = 0 ] && blocking "$CM" ok1' \
  "AC3-noevidence a $S_HI finding with no evidence is a qa.finding with status void and is not in the fix list (a registered one is, blocking)"
ok 'status_is "$CM" unreg void && [ "$(ent "$CM" unreg | jq length)" = 0 ] && blocking "$CM" ok1' "AC3-noevidence evidence no trusted qa.evidence line names: void, not in the fix list"
ok 'status_is "$CM" chg void && [ "$(ent "$CM" chg | jq length)" = 0 ] && blocking "$CM" ok1' "AC3-noevidence evidence whose sha256 changed after registration: void, not in the fix list"

# ---- refused inputs: a findings file over the size cap, a repro given as a shell string ----
python3 -I -c 'import json, sys; f = json.loads(sys.argv[1]); f["detail"] = "x" * (4 << 20); json.dump({"findings": [f]}, open(sys.argv[2], "w"))' \
  "$(fnd big "$S_HI" qa-t-big true null "$EJ1")" "$T/big.json"
b=$(ntype qa.finding); run sb SUB "$CM" "$R1" big.json
ok '[ $RC != 0 ] && coded sb 150 179 && [ "$(ntype qa.finding)" = "$b" ]' "AC3-noevidence a findings file of 4 MiB is refused (coded), no qa.finding line"
fnd shell "$S_HI" qa-t-shell false "$(jq -nc --arg c "touch $T/pwned; false" '$c')" "$EJ1" | mkset shell.json
b=$(ntype qa.finding); run ss SUB "$CM" "$R1" shell.json
ok '[ $RC != 0 ] && coded ss 150 179 && [ "$(ntype qa.finding)" = "$b" ] && [ ! -e "$T/pwned" ]' "AC3-noevidence a repro given as a shell string is refused (coded), no qa.finding line, nothing ran"

# ---- AC6-dedupe: one finding in three files of one role (other reviewer ids and wording, three severities) and once from a second role ----
i=0; for s in "${SEVS[1]}" "${SEVS[0]}" "${SEVS[2]}"; do i=$((i+1))
  fnd dup "$s" qa-t-dup true null "$EJ1" | jq -c --arg id "rv$i-0$i" --arg d "wording number $i of the same problem" '. + {id: $id, detail: $d}' | mkset "dup$i.json"
  run "sd$i" SUB "$CM" "$R1" "dup$i.json"; done
fnd dup "${SEVS[3]}" qa-t-dup true null "$EJ1" | jq -c '. + {id: "other-1", detail: "said another way"}' | mkset dup4.json; run sd4 SUB "$CM" "$R2" dup4.json
ok 'ent "$CM" dup | jq -e --arg s "${SEVS[0]}" --arg a "$R1" --arg b "$R2" "length == 1 and .[0].severity == \$s and (.[0].roles | index(\$a) != null and index(\$b) != null)"' \
  "AC6-dedupe the same finding from three $R1 files and one $R2 file: one fix-list entry, severity ${SEVS[0]} (the highest), roles $R1 and $R2"

# ---- T-MERGE-ORDER: severity order of the data, then fingerprint ----
for k in 1 2 3 4 5 6 7 8; do fnd "ord$k" "${SEVS[$(( (k * 3) % 4 ))]}" "qa-t-ord$k" true null "$EJ1"; done | mkset ord.json
run so SUB "$CM" "$R1" ord.json
ok 'FIX "$CM" | jq -e --argjson sev "$SEVJ" "map([(.severity as \$s | \$sev | index(\$s)), .fingerprint]) as \$k | (\$k | length) > 8 and \$k == (\$k | sort) and all(\$k[]; .[0] != null and (.[1] | type) == \"string\") and ([.[] | select(tostring | test(\"src/ord[0-9][.]py\"))] | length) == 8"' \
  "T-MERGE-ORDER the fix list is sorted by the data's severity order ($(echo "${SEVS[*]}" | tr ' ' ,)), then by fingerprint; all eight findings listed"

# ---- AC7-medium-light: a $S_MED finding is reported but does not block on a $L card; it blocks on a $M card ----
EL1=$(evf "$CL" run.log); reg "$CL" "$EL1" >/dev/null 2>&1
{ fnd medl "$S_MED" qa-t-medl true null "$(arr "$EL1")"; fnd hil "$S_HI" qa-t-hil true null "$(arr "$EL1")"; } | mkset ml.json; run sl SUB "$CL" "$R1" ml.json
fnd medm "$S_MED" qa-t-medm true null "$EJ1" | mkset mm.json; run sm SUB "$CM" "$R1" mm.json
ok 'ent "$CL" medl | jq -e "length == 1 and .[0].blocking == false" && blocking "$CL" hil' "AC7-medium-light a $S_MED finding on a $L card is in the fix list with blocking false (a $S_HI one blocks)"
ok 'blocking "$CM" medm' "AC7-medium-light the same $S_MED finding on a $M card blocks"

# ---- AC7-base-not-charged: a finding whose failing test is in the trusted qa.base-failures line is not blocking ----
plant qa.base-failures "$CM" '{"tests": ["qa-t-basefail"]}'
{ fnd bnc "$S_HI" qa-t-basefail true null "$EJ1"; fnd bnn "$S_HI" qa-t-newfail true null "$EJ1"; } | mkset bnc.json; run sn SUB "$CM" "$R1" bnc.json
ok 'uncharged "$CM" bnc && [ -n "$(FIX "$CM")" ] && blocking "$CM" bnn' "AC7-base-not-charged a $S_HI finding on a test of the trusted qa.base-failures line is not blocking (one on another test is)"

# ---- AC7-unconfirmed: a blocking non-static finding is pending until its repro runs; no reproduction -> unconfirmed, not blocking ----
{ fnd unc "$S_HI" qa-t-unc false '["true"]' "$EJ1"; fnd cnf "$S_HI" qa-t-cnf false '["false"]' "$EJ1"; } | mkset unc.json; run su SUB "$CM" "$R1" unc.json
ok 'status_is "$CM" unc pending && status_is "$CM" cnf pending' "AC7-unconfirmed a blocking finding that is not static is recorded pending until its repro runs"
FU=$(fpr "$CM" unc); FC=$(fpr "$CM" cnf)
run ru python3 -I "$QF" repro --card "$CM" --fingerprint "${FU:-none}"
run rc python3 -I "$QF" repro --card "$CM" --fingerprint "${FC:-none}"
ok '[ -n "$FU" ] && lines qa.finding-unconfirmed "$CM" | jq -e --arg f "$FU" "any(.[]; [.. | strings] | any(. == \$f))" && uncharged "$CM" unc && [ -n "$(FIX "$CM")" ]' \
  "AC7-unconfirmed a repro that does not fail on the frozen copy: qa.finding-unconfirmed, not blocking"
ok '[ -n "$FC" ] && lines qa.finding-confirmed "$CM" | jq -e --arg f "$FC" "any(.[]; [.. | strings] | any(. == \$f))" && blocking "$CM" cnf' \
  "AC7-unconfirmed (control) a repro that fails on the frozen copy: qa.finding-confirmed, blocking"

# ---- RT1-02: a same-fingerprint copy from another role adds its repro and evidence, never replaces the first role's ----
E4=$(evf "$CM" rt1-first.log); reg "$CM" "$E4" >/dev/null 2>&1; E5=$(evf "$CM" rt1-second.log); reg "$CM" "$E5" >/dev/null 2>&1
fnd ovr "$S_HI" qa-t-ovr false '["false"]' "$(arr "$E4")" | mkset ovr1.json; run so1 SUB "$CM" "$R1" ovr1.json
fnd ovr "$S_HI" qa-t-ovr false '["true"]' "$(arr "$E5")" | mkset ovr2.json; run so2 SUB "$CM" "$R2" ovr2.json
FO=$(fpr "$CM" ovr); run ro python3 -I "$QF" repro --card "$CM" --fingerprint "${FO:-none}"
ok '[ -n "$FO" ] && lines qa.finding-confirmed "$CM" | jq -e --arg f "$FO" "any(.[]; [.. | strings] | any(. == \$f))" && blocking "$CM" ovr' \
  "RT1-02 a second copy ($R2) whose repro passes does not replace the first ($R1) whose repro fails: qa.finding-confirmed, blocking"
echo rewritten >>"$R/$E5"
ok 'blocking "$CM" ovr' "RT1-02 the second copy's evidence changes after the confirmation: the first copy's evidence still holds, the finding still blocks"

# ---- RT1-03: the card's own tests-first test is charged even when it is a base failure (it fails on the base by definition) ----
plant qa.base-failures "$CM" '{"tests": ["qa-t-basefail", "qa-t-acc"]}'
plant qa.tests-first "$CM" "$(jq -nc --arg k "$(jq -r '.tests.classes[0].id' "$QJ")" '{accepted: [{id: "qa-t-acc", class: $k}], refused: []}')"
fnd acc "$S_HI" qa-t-acc true null "$EJ1" | mkset acc.json; run sa SUB "$CM" "$R1" acc.json
ok 'blocking "$CM" acc && uncharged "$CM" bnc' "RT1-03 a $S_HI finding on the card's own tests-first test blocks though the test is on the qa.base-failures line (another base failure stays not charged)"

# ---- pass 2 F3/F4: merge() itself dedupes by fingerprint, keeps the highest severity and lists every role ----
cat >"$T/dedupe.py" <<'PY'
import json, sys
top = sys.argv[1]; sys.path.insert(0, top + "/bin")
import qa_findings as qf
qa = json.load(open(top + "/.stella/qa-loop.json"))
sev, roles = [x["id"] for x in qa["severities"]], list(qa["roles"])
base = {"check": "c", "file": "f.py", "lines": [1, 2], "test": "t1", "static": True, "status": "static"}
fs = [dict(base, severity=sev[-1], role=roles[0]), dict(base, severity=sev[0], role=roles[1]), dict(base, severity=sev[len(sev) // 2], role=roles[0])]
out = qf.merge(fs, qa["depth_bump"]["to"], qa)
sys.exit(0 if len(out) == 1 and out[0]["severity"] == sev[0] and sorted(out[0]["roles"]) == sorted({roles[0], roles[1]}) else 1)
PY
ok 'python3 -I "$T/dedupe.py" "$R"' "merge() of three copies of one finding (severities ${SEVS[-1]}, ${SEVS[0]}, a middle one; two roles): one entry, severity ${SEVS[0]}, both roles"

# ---- RTF-03: evidence decides admission, not survival: a confirmed (or static) blocking finding stays blocking whatever its evidence file does later ----
for how in append unreadable delete; do
  E=$(evf "$CM" "rtf03-$how.log"); reg "$CM" "$E" >/dev/null 2>&1
  { fnd "cf$how" "$S_HI" "qa-t-cf$how" false '["false"]' "$(arr "$E")"; fnd "st$how" "$S_HI" "qa-t-st$how" true null "$(arr "$E")"; } | mkset "rtf03-$how.json"
  run "s3$how" SUB "$CM" "$R1" "rtf03-$how.json"; F3=$(fpr "$CM" "cf$how"); run "r3$how" python3 -I "$QF" repro --card "$CM" --fingerprint "${F3:-none}"
  b3=$(blocking "$CM" "cf$how" >/dev/null && blocking "$CM" "st$how" >/dev/null && echo yes)
  case $how in append) echo "more" >>"$R/$E" ;; unreadable) chmod 000 "$R/$E" ;; delete) rm -f "$R/$E" ;; esac
  ok '[ "$b3" = yes ] && lines qa.finding-confirmed "$CM" | jq -e --arg f "$F3" "any(.[]; [.. | strings] | any(. == \$f))" && blocking "$CM" "cf$how" && blocking "$CM" "st$how"' \
    "RTF-03 evidence file $how after admission: the $S_HI finding its repro confirmed and the static one still block"
done

# ---- RTF-06: the evidence role's repros run first; more distinct repros than tests.max_repros: the finding stays pending (fail closed) ----
TS=$(jq -r '[.roles | to_entries[] | select(.value.kind == "evidence") | .key][0] // empty' "$QJ"); AT=$(jq -r '[.roles | to_entries[] | select(.value.kind == "attack") | .key][0] // empty' "$QJ")
CAPR=$(jq -r '.tests.max_repros // 20' "$QJ")
crowd() { local i; for i in $(seq 1 "$2"); do fnd "$1" "$S_HI" "qa-t-$1" false "$(arr true "n$i")" "$EJ1"; done | mkset "$1-crowd.json"; }
crowd crowd "$CAPR"; run sc1 SUB "$CM" "$AT" crowd-crowd.json
fnd crowd "$S_HI" qa-t-crowd false '["false"]' "$EJ1" | mkset crowd-t.json; run sc2 SUB "$CM" "$TS" crowd-t.json
F6=$(fpr "$CM" crowd); run rc6 python3 -I "$QF" repro --card "$CM" --fingerprint "${F6:-none}"
ok '[ -n "$TS" ] && [ -n "$AT" ] && [ -n "$F6" ] && lines qa.finding-confirmed "$CM" | jq -e --arg f "$F6" "any(.[]; [.. | strings] | any(. == \$f))" && blocking "$CM" crowd' \
  "RTF-06 $CAPR passing repros of $AT submitted first do not crowd out the $TS's failing repro: it runs, qa.finding-confirmed, blocking"
ed .stella/qa-loop.json '.tests.max_repros = 3'
crowd over 4; run sc3 SUB "$CM" "$AT" over-crowd.json; F7=$(fpr "$CM" over); u0=$(cnt qa.finding-unconfirmed "$CM")
run rc7 python3 -I "$QF" repro --card "$CM" --fingerprint "${F7:-none}"
ok '[ $RC != 0 ] && grep -qs STL-QA-156 "$T/o/rc7.err" && [ "$(cnt qa.finding-unconfirmed "$CM")" = "$u0" ] && status_is "$CM" over pending' \
  "RTF-06 with tests.max_repros 3 in the data, a finding with 4 distinct passing repros stays pending (STL-QA-156), never unconfirmed"
ed .stella/qa-loop.json --argjson c "$CAPR" '.tests.max_repros = $c'

# ---- T-WORKER: every command refuses in a worker environment, the trusted log untouched ----
S0=$(logsum)
for c in "evidence --card $CM --round 1 --file $R/$E1" "submit --card $CM --round 1 --role $R1 --file $T/ev.json" "repro --card $CM --fingerprint ${FC:-none}" \
  "verdict --card $CM --round 1 --role $R1 --result pass --evidence $E1" "merge --card $CM --json"; do
  # shellcheck disable=SC2086
  run w env STUB_WORKER_MARK=1 python3 -I "$QF" $c
  ok '[ $RC != 0 ] && c312 w && [ "$(logsum)" = "$S0" ]' "T-WORKER qa_findings.py ${c%% *} refuses in a worker environment (STL-CFG-312), the trusted log unchanged"
done
ok 'python3 -I "$R/bin/event_log.py" verify' "precondition: the trusted log of the scratch root verifies after the run"
finish
