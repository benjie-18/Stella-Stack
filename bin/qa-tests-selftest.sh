#!/usr/bin/env bash
# Hermetic self-test for bin/qa_tests.py (phase Q1 item C1: tests first, baseline, flaky, mutants) and bin/test-map.py select
# honouring the quarantine. Written test-first.
# Cases (tests.json ids): AC7-tf-pass-refused, AC7-tf-import-refused, DG-6 (a test that hangs past tests.timeout_s is refused as
#   timeout), AC7-mutant, AC7-flaky, DG-9, RTF-07 (flaky judged on the base hash too), the quarantine unreadable or expired (select skips nothing), AC7-base-not-charged, T-WORKER.
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
ok '(cd "$P" && bash tests/real.sh) && cp -r "$P" "$T/mut" && rm -rf "$T/mut/__pycache__" && sed -i "s/==/!=/" "$T/mut/impl.py" && ! (cd "$T/mut" && bash tests/real.sh) && (cd "$P" && bash tests/importerr.sh >"$T/ie.out" 2>&1; grep -q FAILED "$T/ie.out" && grep -q ModuleNotFoundError "$T/ie.out")' \
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

# ---- fix round 1 (red team RT1 and pass 1): each card freezes round 1 on H1, which adds is_odd (impl.py lines 3-4) and touches tests/flaky.sh ----
printf 'def is_odd(n):\n    return n %% 2 != 0\n' >>"$P/impl.py"; echo '# touched by the card' >>"$P/tests/flaky.sh"
G "$P" commit -qam "the card's change"; H1=$(G "$P" rev-parse HEAD)
frz() { opencard "$1"; python3 -I "$QL" freeze --card "$1" --repo "$P" --hash "$H1" >/dev/null 2>&1; echo "$R/$(python3 -I "$QL" status --card "$1" --json 2>/dev/null | jq -r .copy)"; }
same() { [ -z "$(G "$1" status --porcelain --untracked-files=all)" ] && [ "$(G "$1" rev-parse 'HEAD^{tree}')" = "$(G "$P" rev-parse "$H1^{tree}")" ] && cmp -s "$1/impl.py" <(G "$P" show "$H1:impl.py"); }
# RT1-01: no run ever writes the round copy; a round copy changed after its freeze is refused before any use (qa_tests runs and repro)
C01=t_0a0f2008; RC01=$(frz "$C01"); jq -nc '{id: "qa-t-rewrite", argv: ["sh", "-c", "echo \"exit 0\" >impl.py; echo x >new.txt; exit 0"]}' >"$T/rw.json"; jq -sc . "$T/rw.json" >"$T/rws.json"
ok 'same "$RC01"' "precondition: card $C01 froze round 1 on H1 and its round copy holds H1's tree"
run r1 python3 -I "$QT" flaky --card "$C01" --copy "$RC01" --test "$T/rw.json"; a=$RC
run r2 python3 -I "$QT" tests-first --card "$C01" --copy "$RC01" --tests "$T/rws.json"; b=$RC
run r3 python3 -I "$QT" baseline --card "$C01" --copy "$RC01" --tests "$T/rws.json"; c=$RC
ok '[ "$a$b$c" = 000 ] && same "$RC01"' "RT1-01 a test that rewrites its working folder, run by flaky, tests-first and baseline on the round copy, leaves the round copy as frozen (each run works in a throwaway copy)"
QF=$R/bin/qa_findings.py; QE=$(ix .qa_evidence); E01=$R/$QE/$C01/1/e.txt; mkdir -p "$(dirname "$E01")"; echo evidence >"$E01"
python3 -I "$QF" evidence --card "$C01" --round 1 --file "$E01" >/dev/null 2>&1
TESTER=$(jq -r '[.roles | to_entries[] | select(.value.kind == "evidence") | .key][0]' "$QJ")
SEV=$(jq -r --arg t "$TIER" '[.severities[] | select(.blocks_on == "all" or (.blocks_on | index($t)))][0].id' "$QJ")
jq -n --arg s "$SEV" --arg e "$E01" '[{check: "rt1-01", file: "impl.py", lines: [1, 1], test: "qa-t-real", severity: $s, repro: ["sh", "-c", "exit 1"], evidence: [$e], static: false}]' >"$T/f01.json"
FP=$(python3 -I "$QF" submit --card "$C01" --round 1 --role "$TESTER" --file "$T/f01.json" 2>/dev/null | jq -r '.findings[0] | select(.status == "pending") | .fingerprint')
echo "# changed on the host after the freeze" >>"$RC01/impl.py"
run r4 python3 -I "$QT" flaky --card "$C01" --copy "$RC01" --test "$T/rw.json"
ok '[ $RC = 1 ] && grep -q STL-QA-186 "$T/o/r4.err"' "RT1-01 a round copy changed after its freeze is refused before use (STL-QA-186): its files no longer make the frozen tree"
run r5 python3 -I "$QF" repro --card "$C01" --fingerprint "$FP"
ok '[ -n "$FP" ] && [ $RC = 1 ] && coded r5 150 179 && [ "$(cnt qa.finding-confirmed "$C01")$(cnt qa.finding-unconfirmed "$C01")" = 00 ]' "RT1-01 the repro of a pending finding refuses that changed round copy too (the same check, in qa_tests.fresh): no repro line"
# RT1-04 (DG-9): a test whose file the card changed is never quarantined for it, and never excused for it by another card's row
C04=t_0a0f2009; RC04=$(frz "$C04"); rm -f "$CNT"; run d1 python3 -I "$QT" flaky --card "$C04" --copy "$RC04" --test "$T/fl.json"
ok '[ $RC = 0 ] && jq -e ".flaky == true and .quarantined == false" "$T/o/d1.out" && ! quar "$TGT" "$C04"' "RT1-04 a flaky test whose file the card changed (tests/flaky.sh, base to frozen hash) gets no quarantine row for that card"
EX() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import qa_findings as f; print("\n".join(sorted(f.exempt(sys.argv[2]))))' "$R/bin" "$1" 2>/dev/null; }
ok 'quar "$TGT" "$CA" && EX "$CA" | grep -qx -- "$TGT" && ! EX "$C04" | grep -qx -- "$TGT"' "RT1-04 the row card $CA wrote for $TGT excuses it for $CA, never for $C04, which changed its file (qa_findings exempt)"
TF0=$(jq -r .test_file "$R/.stella/test-map.json"); TF0=${TF0/'{name}'/$TGT}
ok 'quar "$TGT" "" && [ -f "$R/$TF0" ] && o=$(SEL "$TF0") && [ "$o" != full ] && grep -qx -- "$TGT" <<<"$o"' "RT1-04 test-map.py select still names the quarantined $TGT for a change of its own test file $TF0"
A0=${ALW[0]}; jq --arg t "$A0" '.rows += [{test: $t, card: "t_0a0f20ff", expires: "2999-01-01T00:00:00Z"}]' "$R/$QQ" >"$R/$QQ.n" && mv "$R/$QQ.n" "$R/$QQ"
ok 'quar "$A0" "" && o=$(SEL "$FILE0") && [ "$o" != full ] && grep -qx -- "$A0" <<<"$o"' "QT-M4 an always gate ($A0) with a quarantine row is still selected for $FILE0"
# RT1-09: mutants go to the lines the card changed, never into a string or a comment, spread over lines
C09=t_0a0f200a; RC09=$(frz "$C09"); run m9 python3 -I "$QT" mutants --card "$C09" --copy "$RC09" --file impl.py --test "$T/real.json"
ok '[ $RC = 0 ] && jq -e "(.applied | length) >= 1 and all(.applied[]; .line == 3 or .line == 4) and (.findings | length) >= 1" "$T/o/m9.out"' "RT1-09 mutants hit only impl.py lines 3-4, the ones the card changed; the real test never calls is_odd, so a mutant survives"
CX=t_0a0f200b; DX=$R/$QC/$CX/plain; mkdir -p "$DX"; jq -nc '{id: "qa-t-weak", argv: ["python3", "-c", "import mod"]}' >"$T/weak.json"
printf '_G = "== != <= >= and or True False"\nassert _G == "== != <= >= and or True False"\ndef f(x):\n    if x >= 0 and x != 5:\n        return True\n    return False\n' >"$DX/mod.py"
run mx python3 -I "$QT" mutants --card "$CX" --copy "$DX" --file mod.py --test "$T/weak.json"
ok '[ $RC = 0 ] && jq -e "(.findings | length) >= 1" "$T/o/mx.out"' "RT1-09 a decoy line holding every operator in a string (checked by an assert) does not absorb the mutants: the weak test leaves survivors"
# RT1-11: an error class anywhere in a long output refuses a tests-first test; pass 1: the refusal reads plainly
CL=t_0a0f200c; DL=$R/$QC/$CL/plain; mkdir -p "$DL"
printf 'import sys\nn = int(sys.argv[1])\nprint("AssertionError: x")\nprint("." * n)\nprint("ModuleNotFoundError: No module named feature")\nprint("." * n)\nsys.exit(1)\n' >"$DL/t.py"
{ tst qa-t-long python3 t.py 1200000; tst qa-t-short python3 t.py 10; } | jq -sc . >"$T/long.json"
run tl python3 -I "$QT" tests-first --card "$CL" --copy "$DL" --tests "$T/long.json"
ok 'jq -e "([.refused[].id] | index(\"qa-t-long\")) != null and ([.refused[].id] | index(\"qa-t-short\")) != null" "$T/o/tl.out"' "RT1-11 ModuleNotFoundError in the middle of a 2.4 MB output refuses the tests-first test, as it does in a short one"
ok '[ -s "$T/o/tf.out" ] && ! grep -qE "a (error|unclassified|assertion)" "$T/o/tf.out" "$T/o/tl.out"' "pass 1 a tests-first refusal names its class kind plainly (never 'a error class')"

# RTF-07: a test flaky on the frozen hash but stable on the base hash is the card's regression, never quarantined (an unchanged
# reg.sh made flaky through lib.sh); flaky on the base too (control: the base is the flaky lib, the card changes a.txt only): quarantined
P7=$T/proj7; mkdir -p "$P7"; printf '. ./lib.sh\ncheck_it || { echo "AssertionError: expected check_it"; exit 1; }\necho "1 passed"\n' >"$P7/reg.sh"
printf 'check_it() { return 0; }\n' >"$P7/lib.sh"; G "$P7" init -q -b main; G "$P7" add -A; G "$P7" commit -qm base; B7=$(G "$P7" rev-parse HEAD)
printf 'check_it() { if [ -e .n ]; then rm .n; return 0; else touch .n; return 1; fi; }\n' >"$P7/lib.sh"; G "$P7" commit -qam "lib made flaky"; H7=$(G "$P7" rev-parse HEAD)
echo x >"$P7/a.txt"; G "$P7" add -A; G "$P7" commit -qm "a.txt only"; H7B=$(G "$P7" rev-parse HEAD)
fz7() { python3 -I "$QL" open --card "$1" --project qa-proj --tier "$TIER" --base "$2" --builder-role "$BR" >/dev/null 2>&1
  python3 -I "$QL" freeze --card "$1" --repo "$P7" --hash "$3" >/dev/null 2>&1; echo "$R/$(python3 -I "$QL" status --card "$1" --json 2>/dev/null | jq -r .copy)"; }
jq -nc '{id: "qa-t-reg", argv: ["sh", "reg.sh"]}' >"$T/reg.json"
C07=t_0a0f200d; RC07=$(fz7 "$C07" "$B7" "$H7"); run g1 python3 -I "$QT" flaky --card "$C07" --copy "$RC07" --test "$T/reg.json"
ok '[ $RC = 0 ] && jq -e ".flaky == true and .quarantined == false" "$T/o/g1.out" && ! quar qa-t-reg ""' \
  "RTF-07 a test the card made flaky through code only (reg.sh unchanged, green on the base hash) gets no quarantine row: it stays the card's"
C07B=t_0a0f200e; RC07B=$(fz7 "$C07B" "$H7" "$H7B"); run g2 python3 -I "$QT" flaky --card "$C07B" --copy "$RC07B" --test "$T/reg.json"
ok '[ $RC = 0 ] && jq -e ".flaky == true and .quarantined == true" "$T/o/g2.out" && quar qa-t-reg "$C07B"' \
  "RTF-07 (control) a test flaky on the card's base hash too is quarantined"

# ---- T-WORKER: every command refuses in a worker environment, the trusted log untouched ----
D=$(mkcopy t_0a0f2007); S0=$(logsum)
for c in "baseline --tests $T/bl.json" "tests-first --tests $T/tf.json" "flaky --test $T/fl.json" "mutants --file impl.py --test $T/vac.json"; do
  set -- $c
  run w env STUB_WORKER_MARK=1 python3 -I "$QT" "$1" --card t_0a0f2007 --copy "$D" "${@:2}"
  ok '[ $RC != 0 ] && c312 w && [ "$(logsum)" = "$S0" ]' "T-WORKER qa_tests.py $1 refuses in a worker environment (STL-CFG-312), the trusted log unchanged"
done
# ---- RTF-08 (owner fix 2026-11-20): a test's output past tests.max_output_bytes stops the run at the cap (no unbounded host temp file) ----
ed .stella/qa-loop.json '.tests.max_output_bytes = 1048576'
CO=t_0a0f20f1; opencard "$CO"; D=$(mkcopy "$CO")
run oc python3 -I -c 'import json, sys, time; sys.path.insert(0, sys.argv[1]); import qa_tests as q; t = time.time(); rc, out = q.run(sys.argv[2], json.loads(sys.argv[3]), 60); print(rc, len(out.encode()), int(time.time() - t), "max_output_bytes" in out)' \
  "$R/bin" "$D" '["python3", "-c", "import sys\nfor _ in range(300): sys.stdout.write(\"x\" * 1048576)\nprint(\"1 passed\")"]'
read -r OC_RC OC_LEN OC_S OC_NAMED <"$T/o/oc.out" 2>/dev/null
ok '[ $RC = 0 ] && python3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); import qa_tests" "$R/bin" && [ "$OC_RC" = None ] && [ "$OC_LEN" -le 1100000 ] && [ "$OC_NAMED" = True ] && [ "$OC_S" -lt 30 ]' \
  "RTF-08 a test printing 300 MiB under a 1 MiB tests.max_output_bytes is stopped at the cap: the runner's kill (no exit code), the output kept within the cap and naming max_output_bytes (rc $OC_RC, $OC_LEN bytes, $OC_S s)"
ok 'python3 -I "$R/bin/stella_data.py" check' "RTF-08 the copy's data with tests.max_output_bytes passes check"
# Q1-OF-CVER-02: what a test writes into its throwaway copy (host disk) is bounded by tests.max_write_bytes
ed .stella/qa-loop.json '.tests.max_write_bytes = 8388608'
CW=t_0a0f20f2; opencard "$CW"; D=$(mkcopy "$CW")
QR() { python3 -I -c 'import json, sys, time; sys.path.insert(0, sys.argv[1]); import qa_tests as q; t = time.time(); rc, out = q.run(sys.argv[2], json.loads(sys.argv[3]), 60); print(rc, int(time.time() - t), "max_write_bytes" in out)' "$R/bin" "$D" "$1"; }
run ow QR '["bash", "-c", "for i in 1 2 3 4 5 6 7 8 9; do head -c 6291456 /dev/zero >junk$i.bin; done; sleep 20; echo 1 passed"]'
read -r OW_RC OW_S OW_NAMED <"$T/o/ow.out" 2>/dev/null
run ow2 QR '["bash", "-c", "head -c 1048576 /dev/zero >small.bin; echo 1 passed"]'
read -r OW2_RC _ _ <"$T/o/ow2.out" 2>/dev/null
ok '[ "$OW_RC" = None ] && [ "$OW_NAMED" = True ] && [ "$OW_S" -lt 15 ] && [ "$OW2_RC" = 0 ] && python3 -I "$R/bin/stella_data.py" check' \
  "Q1-OF-CVER-02 a test writing 54 MiB (9 files of 6 MiB) into its copy under an 8 MiB tests.max_write_bytes is killed while it runs (rc $OW_RC, $OW_S s, named: $OW_NAMED); one writing 1 MiB passes (rc $OW2_RC)"
# Q1-OF-CVER-08: the write limit holds when the test hides what it wrote (a folder it cannot be read in, a deleted file it holds open)
run ow3 QR '["bash", "-c", "mkdir d; for i in 1 2 3 4 5 6 7 8 9; do head -c 6291456 /dev/zero >d/junk$i.bin; done; chmod 000 d; sleep 20; echo 1 passed"]'
read -r OW3_RC OW3_S _ <"$T/o/ow3.out" 2>/dev/null
run ow4 python3 -I -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import qa_tests as q; rc, out = q.run(sys.argv[2], json.loads(sys.argv[3]), 60); print(rc, "wrote=153" in out)' "$R/bin" "$D" \
  '["bash", "-c", "exec 3>f; rm f; head -c 52428800 /dev/zero >&3; echo wrote=$?; exit 0"]'
read -r OW4_RC OW4_CUT <"$T/o/ow4.out" 2>/dev/null
run ow5 QR '["bash", "-c", "head -c 52428800 /dev/zero >one.bin; echo 1 passed; exit 0"]'
read -r OW5_RC _ OW5_NAMED <"$T/o/ow5.out" 2>/dev/null
ok '[ "$OW3_RC" = None ] && [ "$OW3_S" -lt 15 ] && [ "$OW4_CUT" = True ] && [ "$OW5_RC" = None ] && [ "$OW5_NAMED" = True ]' \
  "Q1-OF-CVER-08/11 54 MiB written into a folder then made unreadable: killed (rc $OW3_RC, $OW3_S s); 50 MiB into a deleted file held open: cut at the file-size limit (SIGXFSZ: $OW4_CUT); one 50 MiB file, the error ignored and 'passed' printed: the run is the runner's kill naming max_write_bytes (rc $OW5_RC, named: $OW5_NAMED)"
# Q1-OF-CVER-09: mutants count lines as git does (only \n ends a line): a CR inside an earlier line moves no mutant
P9=$T/p9; mkdir -p "$P9"; printf '# a\rb\nx=1\n[ "$x" = 2 ] && exit 1\nexit 0\n' >"$P9/mod.sh"; G "$P9" init -q -b main; G "$P9" add -A; G "$P9" commit -qm base; B9=$(G "$P9" rev-parse HEAD)
printf '# a\rb\nx=1\n[ "$x" == 2 ] && exit 1\nexit 0\n' >"$P9/mod.sh"; G "$P9" commit -qam card; H9=$(G "$P9" rev-parse HEAD)
P7_=$P7; P7=$P9; C9=t_0a0f20f3; RC9=$(fz7 "$C9" "$B9" "$H9"); P7=$P7_
jq -nc '{id: "qa-t-mod", argv: ["bash", "mod.sh"]}' >"$T/mod.json"
run m19 python3 -I "$QT" mutants --card "$C9" --copy "$RC9" --file mod.sh --test "$T/mod.json"
ok '[ $RC = 0 ] && jq -e "(.applied | length) >= 1 and all(.applied[]; .line == 3)" "$T/o/m19.out"' "Q1-OF-CVER-09 with a CR inside line 1, the mutant lands on line 3, the line the card changed (git's count)"
ok 'python3 -I "$R/bin/event_log.py" verify' "precondition: the trusted log of the scratch root verifies after the run"
finish
