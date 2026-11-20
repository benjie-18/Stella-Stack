#!/usr/bin/env bash
# Hermetic self-test for bin/qa_roles.py and bin/qa_stub_role.py (phase Q1 item D: the stub QA role set, parallel reviewers, the
# optional round-2 diagnosis). Written test-first.
# Cases (tests.json ids): AC6-three-parallel (a reviewer role's count 3 in the copy's data: three slots run at once, their duplicate
#   finding merges into one fix-list entry), T-LOCAL1 (under when_local_only every count is its count and slots run one after
#   another), T-DIAG-OFF (diagnose refuses while the flag is off; on, one call writes a brief file and uses no round),
#   AC5-stub-feature (the stub set is a features.json stub due at D1, listed by stella_data.py stubs), T-WORKER.
# Slot times are seen through a wrapper put in place of bin/qa_stub_role.py in the scratch root: it notes its start and end, waits
# 1.5 s, and runs the real double (moved beside it) with the same arguments, input and output.
# ASSUMPTIONS (what design.md leaves open; the builder aligns with them or raises them):
#  D1 each slot runs bin/qa_stub_role.py as a process of its own, with the card id and the slot's role id among its arguments.
#  D2 the stub doubles' fixtures make every slot of a role report the same finding (with evidence), so the role's slots give one
#     fix-list entry (qa_findings.py merge --card C --json: {"fix_list": [...]} or the list; an entry lists its roles).
#  D3 the card's preset (the routing selection) listed in when_local_only.presets puts the card under when_local_only.
#  D4 the diagnosis flag is on when the features.json entry it names has status "on"; the brief file is a new non-empty file
#     under the root (outside the logs, the state folder, the copies and bytecode caches); "no round" = status .round and the
#     qa.frozen lines unchanged. Refusals carry an STL-QA code of item D's range (230-249); a worker environment STL-CFG-312.
ME=qa-roles-selftest
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

QR=$R/bin/qa_roles.py; QF=$R/bin/qa_findings.py
M=$(jq -r .depth_bump.to "$QJ"); BR=$(jq -r '.builder_roles[0]' "$RT")
VR=$(jq -r '[.roles | to_entries[] | select(.value.kind == "review") | .key][-1] // empty' "$QJ")
ed .stella/qa-loop.json --arg r "$VR" --arg m "$M" '.roles[$r].count[$m] = 3'
FLAG=$(jq -r .diagnosis.flag "$QJ"); STUBF=$(jq -r .stub_roles.feature "$QJ"); FJ=$R/.stella/features.json
ok '[ -n "$VR" ] && python3 -I "$R/bin/stella_data.py" check' "precondition: the copy's data checks with $VR count 3 on tier $M"

# ---- the slot-time wrapper in place of the stub double ----
SL=$T/o/slots.log; : >"$SL"
[ -f "$R/bin/qa_stub_role.py" ] && mv "$R/bin/qa_stub_role.py" "$R/bin/qa_stub_role_inner.py"
cat >"$R/bin/qa_stub_role.py" <<PY
import os, subprocess, sys, time
def mark(w):
    with open("$SL", "a") as f:
        f.write("%s %.6f %d %s\n" % (w, time.time(), os.getpid(), " ".join(sys.argv[1:])))
if __name__ != "__main__":
    from qa_stub_role_inner import *   # imported as a module: the double itself (no slot times then)
else:
    mark("start"); time.sleep(1.5)
    rc = subprocess.call([sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "qa_stub_role_inner.py")] + sys.argv[1:])
    mark("end"); sys.exit(rc)
PY
# slots <card> [role]: {n, parallel, sequential} of the slots whose arguments name the card (and the role)
cat >"$T/slots.py" <<'PY'
import json, re, sys
want = [re.compile(r"(^|[\s=,:/])" + re.escape(w) + r"($|[\s=,:/])") for w in sys.argv[2:]]
st, en = {}, {}
for l in open(sys.argv[1]):
    p = l.rstrip("\n").split(" ", 3) + [""]
    if all(w.search(p[3]) for w in want):
        (st if p[0] == "start" else en)[p[2]] = float(p[1])
iv = sorted((st[k], en[k]) for k in st if k in en)
print(json.dumps({"n": len(iv), "parallel": len(iv) > 1 and max(a for a, b in iv) < min(b for a, b in iv),
                  "sequential": len(iv) > 1 and all(iv[i][0] >= iv[i - 1][1] for i in range(1, len(iv)))}))
PY
slots() { python3 -I "$T/slots.py" "$SL" "$@"; }

REPO=$T/repo; mkdir -p "$REPO/src"; echo base >"$REPO/src/a.txt"; G "$REPO" init -q -b main; G "$REPO" add -A; G "$REPO" commit -qm base
H0=$(G "$REPO" rev-parse HEAD); echo change >>"$REPO/src/a.txt"; G "$REPO" commit -qam card; H1=$(G "$REPO" rev-parse HEAD)
card() { python3 -I "$QL" open --card "$1" --project qa-proj --tier "$M" --base "$H0" --builder-role "$BR" && python3 -I "$QL" freeze --card "$1" --repo "$REPO" --hash "$H1"; }
FIX() { python3 -I "$QF" merge --card "$1" --json 2>/dev/null | jq -c '(if type == "object" then .fix_list else . end) // []' 2>/dev/null; }

# ---- AC6-three-parallel ----
CP=t_0a0f4001; run oc card "$CP"
ok '[ $RC = 0 ]' "precondition: card $CP (tier $M) opened and frozen (qa_loop.py open, freeze)"
run r1 python3 -I "$QR" run --card "$CP" --round "$(rnd "$CP")"; rr=$RC
ok '[ $rr = 0 ] && slots "$CP" "$VR" | jq -e ".n == 3 and .parallel"' "AC6-three-parallel $VR count 3 in data: three $VR slots ran, their start/end times overlap ($(slots "$CP" "$VR" | tr -d '\n'))"
ok 'FIX "$CP" | jq -e --arg r "$VR" "[.[] | select((.roles // []) | index(\$r) != null)] | length == 1" && [ "$(lines qa.finding "$CP" | jq --arg r "$VR" "[.[] | select([.. | strings] | any(. == \$r))] | length")" -ge 3 ]' \
  "AC6-three-parallel the three $VR doubles each submit their finding (3 qa.finding lines); the merge gives one fix-list entry for it"

# ---- T-DIAG-OFF: refused while the flag is off; on, one brief file, no round ----
newfiles() { find "$R" -newer "$T/mark" -type f -size +0c ! -path "$R/.supervisor/logs/*" ! -path "$R/.supervisor/state/*" ! -path "$R/$(ix .qa_copies)/*" ! -path "*/__pycache__/*" 2>/dev/null; }
ok 'jq -e --arg f "$FLAG" "any(.entries[]; (.id == \$f or .flag == \$f) and .status == \"off\")" "$FJ"' "precondition: the diagnosis flag $FLAG is off in the shipped data"
S0=$(logsum); touch "$T/mark"; sleep 1; run d0 python3 -I "$QR" diagnose --card "$CP"
ok '[ $RC != 0 ] && coded d0 230 249 && [ -z "$(newfiles)" ] && [ "$(logsum)" = "$S0" ]' "T-DIAG-OFF diagnose refuses while $FLAG is off (coded): no file written, the trusted log unchanged"
ed .stella/features.json --arg f "$FLAG" '(.entries[] | select(.id == $f or .flag == $f) | .status) = "on"'
r0=$(rnd "$CP"); f0=$(cnt qa.frozen "$CP"); touch "$T/mark"; sleep 1; run d1 python3 -I "$QR" diagnose --card "$CP"
ok '[ $RC = 0 ] && [ -n "$(newfiles)" ] && [ "$(rnd "$CP")" = "$r0" ] && [ "$(cnt qa.frozen "$CP")" = "$f0" ]' \
  "T-DIAG-OFF with $FLAG on in the copy, one diagnose call writes a brief file ($(newfiles | head -1 | sed "s|^$R/||")) and the round count stays $r0"

# ---- T-LOCAL1: the card's preset listed in when_local_only: every count is that count, slots one after another ----
GP=$(jq -r '.selection.global' "$R/.stella/role-assignments.json"); WC=$(jq -r '.when_local_only.count' "$QJ")
ed .stella/qa-loop.json --arg p "$GP" '.when_local_only.presets |= (. + [$p] | unique)'
CO=t_0a0f4002; run oc2 card "$CO"
run r2 python3 -I "$QR" run --card "$CO" --round "$(rnd "$CO")"
ok '[ $RC = 0 ] && slots "$CO" "$VR" | jq -e --argjson c "$WC" ".n == \$c" && slots "$CO" | jq -e ".n >= 2 and .sequential"' \
  "T-LOCAL1 under when_local_only (preset $GP listed): $VR runs $WC slot(s) though its count is 3, and the slots run one after another ($(slots "$CO" | tr -d '\n'))"

# ---- AC5-stub-feature ----
ok 'jq -e --arg f "$STUBF" "any(.entries[]; .id == \$f and ([.due_phase] | flatten | index(\"D1\") != null))" "$FJ" && { python3 -I "$R/bin/stella_data.py" stubs --phase D1 --json || true; } | grep -q -- "\"$STUBF\""' \
  "AC5-stub-feature features.json $STUBF is a stub with due_phase D1 and stella_data.py stubs --phase D1 lists it"

# ---- T-WORKER ----
S0=$(logsum)
for c in run diagnose; do
  if [ $c = run ]; then run w env STUB_WORKER_MARK=1 python3 -I "$QR" run --card "$CP" --round 1; else run w env STUB_WORKER_MARK=1 python3 -I "$QR" diagnose --card "$CP"; fi
  ok '[ $RC != 0 ] && c312 w && [ "$(logsum)" = "$S0" ]' "T-WORKER qa_roles.py $c refuses in a worker environment (STL-CFG-312), the trusted log unchanged"
done
ok 'python3 -I "$R/bin/event_log.py" verify' "precondition: the trusted log of the scratch root verifies after the run"
finish
