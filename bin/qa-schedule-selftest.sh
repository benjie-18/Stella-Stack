#!/usr/bin/env bash
# Hermetic self-test for bin/qa_schedule.py (phase Q1 item C2: the scheduled full-suite run). Written test-first.
# Case (tests.json id): T-SCHED-REOPEN: a scratch repo with three cards done in order (trusted qa.passed lines on their hashes), the
#   second card seeds a failure; a tick before the interval does nothing; a tick after it runs the full suite on the head copy,
#   bisects over the done hashes and writes qa.reopened for the second card only: its done goes false, the others stay done.
#   With it: bin/crontab.txt carries the tick line; T-WORKER.
# The full suite of the scratch repo is the runner the test map names (its "runner" path), a fixture here.
# ASSUMPTIONS (what design.md leaves open; the builder aligns with them or raises them):
#  S1 tick runs when no qa.full-run line exists yet (the first run), and writes one qa.full-run line per run (pass or fail).
#  S2 the done hashes of a repo are the hashes of the trusted qa.passed lines ({round, hash}, what = the card) that are ancestors
#     of the repo's head; done is qa_loop.py done --card C --hash H (exit 0 = done).
#  S3 the full suite is the test map's runner at the head copy's root; a failing test is a "FAIL <name>-selftest" line, and the
#     runner takes those names (with or without -selftest) to run only them.
#  S4 qa.reopened names the card (what or a card field), the culprit hash and the failing tests, read by value.
#  S5 the interval is measured on the wall clock (full_suite.interval_s set to the schema minimum here; no --now is used).
ME=qa-schedule-selftest
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

QS=$R/bin/qa_schedule.py
ed .stella/qa-loop.json '.full_suite.interval_s = 60'
IV=$(jq .full_suite.interval_s "$QJ"); RUNNER=$(jq -r .runner "$R/.stella/test-map.json")
ok 'python3 -I "$R/bin/stella_data.py" check && [ "$IV" = 60 ] && [ -n "$RUNNER" ]' "precondition: the copy's data checks with full_suite.interval_s $IV; the test map names a runner ($RUNNER)"
ok 'grep -q "qa_schedule.py tick" "$R/bin/crontab.txt"' "T-SCHED-REOPEN bin/crontab.txt carries the qa_schedule.py tick line"

# ---- the scratch repo: a runner fixture and two selftests, green at the base ----
S=$T/srepo; mkdir -p "$S/bin" "$S/$(dirname "$RUNNER")"
cat >"$S/$RUNNER" <<'SH'
#!/usr/bin/env bash
# fixture runner: no name = every bin/<name>-selftest.sh; names (with or without -selftest) = those only; one ok/FAIL line each
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
[ $# = 0 ] && set -- $(ls bin | sed -n 's/-selftest[.]sh$//p')
f=0; for t; do t=${t%-selftest}; if bash "bin/$t-selftest.sh" >/dev/null 2>&1; then echo "ok   $t-selftest"; else echo "FAIL $t-selftest"; f=$((f+1)); fi; done
[ $f = 0 ] && { echo "selftests PASS"; exit 0; }; echo "selftests FAIL ($f)"; exit 1
SH
chmod +x "$S/$RUNNER"
for t in alpha beta; do printf 'echo "%s selftest PASS"\n' "$t" >"$S/bin/$t-selftest.sh"; chmod +x "$S/bin/$t-selftest.sh"; done
G "$S" init -q -b main; G "$S" add -A; G "$S" commit -qm base
ok '(cd "$S" && "./$RUNNER")' "precondition: the fixture suite is green at the base"

# tick 1 (no full run yet): runs, green
run t1 python3 -I "$QS" tick --repo "$S"; T1=$SECONDS
ok '[ $RC = 0 ] && [ "$(ntype qa.full-run)" = 1 ]' "T-SCHED-REOPEN the first tick runs the full suite: one trusted qa.full-run line"
# three cards done in order on their hashes; the second seeds a failure in a selftest
C1=t_0a0f3001 C2=t_0a0f3002 C3=t_0a0f3003
echo a >"$S/a.txt"; G "$S" add -A; G "$S" commit -qm "card 1"; HA=$(G "$S" rev-parse HEAD)
printf 'echo "AssertionError: expected beta"\nexit 1\n' >"$S/bin/beta-selftest.sh"; G "$S" commit -qam "card 2"; HB=$(G "$S" rev-parse HEAD)
echo c >"$S/c.txt"; G "$S" add -A; G "$S" commit -qm "card 3"; HC=$(G "$S" rev-parse HEAD)
TIER=$(jq -r '.task_tiers[0].id' "$R/.stella/routing.json"); BROLE=$(jq -r '.builder_roles[0]' "$R/.stella/routing.json")
# a card is done only on a round it froze after opening (qa_loop.py done reads qa.opened and qa.frozen too): plant the whole trail
for k in "$C1:$HA" "$C2:$HB" "$C3:$HC"; do
  plant qa.opened "${k%%:*}" "$(jq -nc --arg t "$TIER" --arg r "$BROLE" '{project: "p", tier: $t, base: null, builder_role: $r}')"
  plant qa.frozen "${k%%:*}" "$(jq -nc --arg h "${k#*:}" '{round: 1, hash: $h}')"
  plant qa.passed "${k%%:*}" "$(jq -nc --arg h "${k#*:}" '{round: 1, hash: $h}')"
done
done_rc() { python3 -I "$QL" done --card "$1" --hash "$2" >/dev/null 2>&1; echo $?; }
d1=$(done_rc "$C1" "$HA"); d2=$(done_rc "$C2" "$HB"); d3=$(done_rc "$C3" "$HC")
# tick 2, before the interval: nothing at all
N0=$(EVJ | jq length); run t2 python3 -I "$QS" tick --repo "$S"
ok '[ $RC = 0 ] && [ "$(ntype qa.full-run)" = 1 ] && [ "$(EVJ | jq length)" = "$N0" ]' "T-SCHED-REOPEN a tick before full_suite.interval_s ($IV s) does nothing: no new trusted line (no run, no reopen)"
# tick 3, after the interval (no wait when the first tick did not run: nothing to measure from)
[ "$(ntype qa.full-run)" = 1 ] && { w=$((IV + 2 - (SECONDS - T1))); [ $w -gt 0 ] && sleep "$w"; }
run t3 python3 -I "$QS" tick --repo "$S"
RO=$(EVJ | jq -c '[.[] | select(.type == "qa.reopened")]')
ok '[ "$(ntype qa.full-run)" = 2 ]' "T-SCHED-REOPEN a tick after the interval runs the full suite again: a second qa.full-run line"
ok 'jq -e --arg c2 "$C2" --arg hb "$HB" --arg c1 "$C1" --arg c3 "$C3" "length == 1 and (.[0] | [.. | strings] as \$s | (\$s | any(. == \$c2)) and (\$s | any(. == \$hb)) and (\$s | any(. == \$c1 or . == \$c3) | not) and (\$s | any(test(\"beta\"))))" <<<"$RO"' \
  "T-SCHED-REOPEN bisection finds the seeding card: one trusted qa.reopened line, for $C2 on its hash, naming the failing test; none for $C1 or $C3"
ok '[ "$d2" = 0 ] && [ "$(done_rc "$C2" "$HB")" != 0 ]' "T-SCHED-REOPEN the reopened card's done goes false (done exit $d2 before)"
ok '[ "$d1" = 0 ] && [ "$d3" = 0 ] && [ "$(done_rc "$C1" "$HA")" = 0 ] && [ "$(done_rc "$C3" "$HC")" = 0 ]' "T-SCHED-REOPEN the other two cards stay done"

# ---- T-WORKER ----
S0=$(logsum); run w env STUB_WORKER_MARK=1 python3 -I "$QS" tick --repo "$S"
ok '[ $RC != 0 ] && c312 w && [ "$(logsum)" = "$S0" ]' "T-WORKER qa_schedule.py tick refuses in a worker environment (STL-CFG-312), the trusted log unchanged"
ok 'python3 -I "$R/bin/event_log.py" verify' "precondition: the trusted log of the scratch root verifies after the run"
finish
