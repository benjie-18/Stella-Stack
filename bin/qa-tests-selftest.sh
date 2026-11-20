#!/usr/bin/env bash
# Hermetic self-test for bin/qa_tests.py (phase Q1 item C1: tests first, baseline, flaky, mutants) and bin/test-map.py select
# honouring the quarantine. Written test-first.
# Cases (tests.json ids): AC7-tf-pass-refused, AC7-tf-import-refused, DG-6 (a test that hangs past tests.timeout_s is refused as
#   timeout), AC7-mutant, AC7-flaky, DG-9, the quarantine unreadable or expired (select skips nothing), AC7-base-not-charged, T-WORKER.
# The tests run are scripts of a scratch project; each card gets a disposable clone of its base hash under qa_copies (made here).
# ASSUMPTIONS (what design.md leaves open; the builder aligns with them or raises them):
#  C1 --tests J / --test J name a JSON file: a list of {id, argv} / one {id, argv}; argv runs with the copy as its working folder.
#  C2 --copy DIR is a standalone clone under qa_copies/<card>/ checked out at the base hash (the caller makes it); flaky reruns
#     run in DIR; mutants never change DIR (each mutant in a fresh copy).
#  C3 a trusted qa.* line has type qa.<name> and what = the card id; ids are read by value: qa.tests-first holds the refused ids
#     under a key "refused" and the accepted ids under "accepted"; qa.base-failures and qa.flaky name the test id; a surviving
#     mutant is a qa.finding line of the card naming the test id.
#  C4 a quarantine row is an object {test, card, expires} anywhere in the qa_quarantine file; expires is ISO-8601 UTC or epoch
#     seconds. A quarantined test id is a selftest name test-map.py select can answer; the flaky test here is given such a name.
#  C5 "no round used": no qa.frozen line for the card. A worker environment: STL-CFG-312 (event_log.owner_only).
ME=qa-tests-selftest
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

QT=$R/bin/qa_tests.py
QC=$(ix .qa_copies); QQ=$(ix .qa_quarantine)
TO=8; ed .stella/qa-loop.json --argjson t $TO '.tests.timeout_s = $t'   # a short runner kill for the hanging test
BR=$(jq -r '.builder_roles[0]' "$RT"); TIER=$(jq -r '.task_tiers[-1].id' "$RT")
ok 'python3 -I "$R/bin/stella_data.py" check && jq -e "any(.mutants.operators[]; .find == \"==\") and .tests.reruns >= 2" "$QJ"' \
  "precondition: the copy's data checks (timeout_s $TO), a mutant operator replaces ==, tests.reruns >= 2"

# ---- the scratch project: impl.py (one == the mutant data can flip) and its tests ----
P=$T/proj; mkdir -p "$P/tests"; CNT=$T/flaky-n
printf 'def is_even(n):\n    return n %% 2 == 0\n' >"$P/impl.py"
printf 'echo "1 passed"\nexit 0\n' >"$P/tests/green.sh"
printf '# vacuous: asserts nothing\nexit 0\n' >"$P/tests/vacuous.sh"
printf 'echo "AssertionError: expected 4, got 5"\nexit 1\n' >"$P/tests/assertfail.sh"
printf 'python3 -c %s\n' "'print(\"FAILED tests/test_x.py::test_y\"); import qa_no_such_module_zz'" >"$P/tests/importerr.sh"
printf 'sleep 120\n' >"$P/tests/hang.sh"
printf 'python3 -c %s\n' "'import impl; assert impl.is_even(2) and not impl.is_even(3), \"expected is_even(2) and not is_even(3)\"'" >"$P/tests/real.sh"
# flaky: passes on odd calls, fails on even ones; the count lives in the copy's .git and (when writable) in the scratch folder
cat >"$P/tests/flaky.sh" <<SH
n=0; for f in .git/qa-flaky-n "$CNT"; do v=\$(cat "\$f" 2>/dev/null) && [ "\$v" -gt "\$n" ] 2>/dev/null && n=\$v; done
for f in .git/qa-flaky-n "$CNT"; do echo \$((n + 1)) >"\$f" 2>/dev/null; done
[ \$((n % 2)) = 0 ] && { echo "1 passed"; exit 0; }
echo "AssertionError: expected the call to pass"; exit 1
SH
G "$P" init -q -b main; G "$P" add -A; G "$P" commit -qm base; HB=$(G "$P" rev-parse HEAD)
ok '(cd "$P" && bash tests/real.sh) && cp -r "$P" "$T/mut" && sed -i "s/==/!=/" "$T/mut/impl.py" && ! (cd "$T/mut" && bash tests/real.sh) && (cd "$P" && bash tests/importerr.sh >"$T/ie.out" 2>&1; grep -q FAILED "$T/ie.out" && grep -q ModuleNotFoundError "$T/ie.out")' \
  "precondition: the real test passes on impl.py and fails once == is flipped; the import-error test prints FAILED and ModuleNotFoundError"
# mkcopy <card>: a standalone clone of the base hash under qa_copies/<card>/ (no hooks); prints its path
mkcopy() { local d=$R/$QC/$1/base; mkdir -p "$(dirname "$d")"; git clone -q --no-local --no-checkout -c core.hooksPath=/dev/null "$P" "$d" && G "$d" checkout -q -b qa-base "$HB" && echo "$d"; }
opencard() { python3 -I "$QL" open --card "$1" --project qa-proj --tier "$TIER" --base "$HB" --builder-role "$BR" >/dev/null 2>&1 || true; }   # best effort: these cases do not judge qa_loop.py
tst() { jq -nc --arg i "$1" '{id: $i, argv: $ARGS.positional}' --args "${@:2}"; }
# inkey <lines JSON> <key> <id>: the last line holds the id under a key of that name
inkey() { jq -e --arg k "$2" --arg i "$3" '.[-1] | [.. | objects | .[$k]? // empty | .. | strings] | any(. == $i)' <<<"$1" >/dev/null 2>&1; }
names() { jq -e --arg i "$2" 'length >= 1 and any(.[]; [.. | strings] | any(. == $i))' <<<"$1" >/dev/null 2>&1; }   # names <lines JSON> <id>

# ---- tests first: refused when it passes on the base, when an error class matches (also with FAILED printed), on a timeout ----
CT=t_0a0f2001; opencard "$CT"; D=$(mkcopy "$CT")
{ tst qa-t-green bash tests/green.sh; tst qa-t-importerr bash tests/importerr.sh; tst qa-t-hang bash tests/hang.sh; tst qa-t-assertfail bash tests/assertfail.sh; } | jq -sc . >"$T/tf.json"
s=$SECONDS; run tf python3 -I "$QT" tests-first --card "$CT" --copy "$D" --tests "$T/tf.json"; el=$((SECONDS - s)); TF=$(lines qa.tests-first "$CT")
ok 'inkey "$TF" refused qa-t-green && ! inkey "$TF" accepted qa-t-green && inkey "$TF" accepted qa-t-assertfail && ! inkey "$TF" refused qa-t-assertfail' \
  "AC7-tf-pass-refused a tests-first test that passes on the base copy is refused; one failing with an assertion is accepted"
ok 'inkey "$TF" refused qa-t-importerr && ! inkey "$TF" accepted qa-t-importerr' "AC7-tf-import-refused a test failing only with ModuleNotFoundError (it also prints FAILED) is refused: an error class wins (DG-6)"
ok 'inkey "$TF" refused qa-t-hang && ! inkey "$TF" accepted qa-t-hang && [ $el -lt 100 ] && { jq -e ".[-1] | [.. | objects | .refused? // empty] | tostring | test(\"timeout\")" <<<"$TF" || grep -qi timeout "$T/o/tf.out" "$T/o/tf.err"; }' \
  "DG-6 a test that hangs past tests.timeout_s ($TO s) is killed by the runner and refused as timeout (the run took $el s)"

# ---- baseline: the tests failing on the base hash are recorded (never charged to the builder) ----
CBL=t_0a0f2002; opencard "$CBL"; D=$(mkcopy "$CBL")
{ tst qa-t-assertfail bash tests/assertfail.sh; tst qa-t-green bash tests/green.sh; } | jq -sc . >"$T/bl.json"
run bl python3 -I "$QT" baseline --card "$CBL" --copy "$D" --tests "$T/bl.json"; BL=$(lines qa.base-failures "$CBL")
ok 'names "$BL" qa-t-assertfail && ! jq -e ".[-1] | [.. | strings] | any(. == \"qa-t-green\")" <<<"$BL"' "AC7-base-not-charged baseline writes a trusted qa.base-failures line naming the failing test, not the passing one"

# ---- mutants: a vacuous test survives (a finding against the test); a real test kills it; the copy is never changed ----
CV=t_0a0f2003; opencard "$CV"; D=$(mkcopy "$CV"); tst qa-t-vacuous bash tests/vacuous.sh >"$T/vac.json"
run mv python3 -I "$QT" mutants --card "$CV" --copy "$D" --file impl.py --test "$T/vac.json"
ok 'names "$(lines qa.finding "$CV")" qa-t-vacuous && cmp -s "$D/impl.py" "$P/impl.py"' "AC7-mutant the vacuous test survives a mutant of impl.py: a trusted qa.finding against qa-t-vacuous; the copy unchanged"
CR=t_0a0f2004; opencard "$CR"; D=$(mkcopy "$CR"); tst qa-t-real bash tests/real.sh >"$T/real.json"
run mr python3 -I "$QT" mutants --card "$CR" --copy "$D" --file impl.py --test "$T/real.json"
ok '[ $RC = 0 ] && ! names "$(lines qa.finding "$CR")" qa-t-real && cmp -s "$D/impl.py" "$P/impl.py"' "AC7-mutant (control) the real test kills the mutant: exit 0, no finding against it; the copy unchanged"

# ---- flaky and quarantine: the flaky test is named as a selftest that select answers for some file ----
SEL() { python3 -I "$R/bin/test-map.py" select -- "$1" 2>/dev/null; }
mapfile -t ALW < <(jq -r '.always[]' "$R/.stella/test-map.json"); TGT= FILE0=
while IFS= read -r f; do [ -f "$R/$f" ] || continue; o=$(SEL "$f"); [ "$o" != full ] || continue
  for t in $o; do case " ${ALW[*]} test-map " in *" $t "*) ;; *) TGT=$t FILE0=$f; break 2;; esac; done
done < <(jq -r '.map[] | [.globs[] | select(test("[*?\\[]") | not)][0] // empty' "$R/.stella/test-map.json")
ok '[ -n "$TGT" ]' "precondition: test-map.py select answers selftest ${TGT:-none} for $FILE0 (the flaky test is given that name)"
quar() { [ -f "$R/$QQ" ] && jq -e --arg t "$1" --arg c "$2" '[.. | objects | select(has("expires") and .test == $t and ($c == "" or .card == $c))] | length > 0' "$R/$QQ"; }
future() { jq -e --arg t "$1" '[.. | objects | select(has("expires") and .test == $t) | .expires | if type == "number" then . > now else (try (sub("[.][0-9]+"; "") | sub("[+]00:00$"; "Z") | fromdateiso8601 > now) catch false) end] | any' "$R/$QQ"; }
skips() { local o; o=$(SEL "$FILE0"); [ -n "$o" ] && [ "$o" != full ] && ! grep -qx -- "$TGT" <<<"$o"; }
lists() { local o; o=$(SEL "$FILE0"); [ "$o" = full ] || grep -qx -- "$TGT" <<<"$o"; }
tst "$TGT" bash tests/flaky.sh >"$T/fl.json"
# DG-9: the card's own tests-first test is never quarantined, flaky or not
CB=t_0a0f2005; opencard "$CB"; D=$(mkcopy "$CB"); tst "$TGT" bash tests/assertfail.sh | jq -sc . >"$T/tf9.json"
run t9 python3 -I "$QT" tests-first --card "$CB" --copy "$D" --tests "$T/tf9.json"
rm -f "$D/.git/qa-flaky-n" "$CNT"; run f9 python3 -I "$QT" flaky --card "$CB" --copy "$D" --test "$T/fl.json"
ok 'inkey "$(lines qa.tests-first "$CB")" accepted "$TGT" && [ $RC != 2 ] && ! quar "$TGT" "" && lists' "DG-9 the card's own accepted tests-first test, flaky on rerun, gets no quarantine row; select still names it"
# AC7-flaky: mixed results -> qa.flaky, a quarantine row with an expiry, select skips it, no round used
CA=t_0a0f2006; opencard "$CA"; D=$(mkcopy "$CA"); fr0=$(cnt qa.frozen "$CA")
rm -f "$D/.git/qa-flaky-n" "$CNT"; run fa python3 -I "$QT" flaky --card "$CA" --copy "$D" --test "$T/fl.json"
ok 'names "$(lines qa.flaky "$CA")" "$TGT" && quar "$TGT" "$CA" && future "$TGT"' "AC7-flaky a test failing every other run: a trusted qa.flaky line and a quarantine row {test, card, expires} expiring later"
ok 'skips' "AC7-flaky test-map.py select no longer names the quarantined $TGT for $FILE0 (and is not a full answer)"
ok '[ $RC = 0 ] && [ "$(cnt qa.frozen "$CA")" = "$fr0" ] && [ "$(cnt qa.flaky "$CA")" -ge 1 ]' "AC7-flaky no round used: no qa.frozen line for the card"
# an expired or unreadable quarantine skips nothing
[ -f "$R/$QQ" ] && cp -p "$R/$QQ" "$T/q.keep"
ed "$QQ" 'walk(if type == "object" and has("expires") then .expires |= (if type == "number" then 1 else "2000-01-01T00:00:00Z" end) else . end)' 2>/dev/null
ok '[ -f "$T/q.keep" ] && jq -e "any(.. | objects; has(\"expires\"))" "$R/$QQ" && lists' "AC7-flaky the row expired: select names $TGT again"
q1() { [ -f "$T/q.keep" ] && cp -p "$T/q.keep" "$R/$QQ" && skips; }
ok 'q1 && printf "{not json" >"$R/$QQ" && lists' "AC7-flaky a quarantine file that is not JSON skips nothing (it skipped before)"
ok 'q1 && chmod 000 "$R/$QQ" && { [ -r "$R/$QQ" ] || lists; }' "AC7-flaky a quarantine file that cannot be read skips nothing"
chmod 600 "$R/$QQ" 2>/dev/null

# ---- T-WORKER: every command refuses in a worker environment, the trusted log untouched ----
D=$(mkcopy t_0a0f2007); S0=$(logsum)
for c in "baseline --tests $T/bl.json" "tests-first --tests $T/tf.json" "flaky --test $T/fl.json" "mutants --file impl.py --test $T/vac.json"; do
  set -- $c
  run w env STUB_WORKER_MARK=1 python3 -I "$QT" "$1" --card t_0a0f2007 --copy "$D" "${@:2}"
  ok '[ $RC != 0 ] && c312 w && [ "$(logsum)" = "$S0" ]' "T-WORKER qa_tests.py $1 refuses in a worker environment (STL-CFG-312), the trusted log unchanged"
done
ok 'python3 -I "$R/bin/event_log.py" verify' "precondition: the trusted log of the scratch root verifies after the run"
finish
