#!/usr/bin/env bash
# Hermetic self-test for bin/triage.py (F2b item F), no model call: in a scratch root (a copy of bin, .stella, docs; its own HOME and
# temp) logged verdicts are made with the event writer and the commands that need no model are run. Cases: label takes a logged verdict
# id and refuses an unknown id, a route outside the tiers and a source other than override or reroute; a tier added as data only is a
# route label may take (the fake entry; no code names a tier); fit refuses below triage.min_labels (STL-MDL-742), then writes the
# calibration file (schema triage-calibration) and one triage.calibrated line, and the threshold separates right from wrong verdicts;
# an invalid calibration file and an inconsistent triage block fail closed (route refuses before any call); a worker environment is
# refused; the label-probability and the classifier helpers. The full route path against the mock link is the shared tests T-TRIAGE,
# A1 and A4b-router (qa/wave3). Nothing here names a route, a role or a model beyond what the shipped data holds.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/triage-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
R=$T/root
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$T/home" "$T/tmp" "$T/sup/logs"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"
cd "$T" || exit 1
jq() { env -u HOME jq "$@"; }
IX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IX"; }
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$ROOT/$(ix .role_table)" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT
fails=0
ok() { if ( eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
ed() { local f=$R/.stella/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }
tr_() { python3 -I -B "$R/bin/triage.py" "$@" 2>"$T/err"; }   # the output on stdout, the catalog line in $T/err
ev() { python3 -I -B "$R/bin/event_log.py" append --type "$1" --what selftest --new "$2" | jq -r .global_id; }
CAL=$R/$(ix .triage_calibration)
TI=$(jq -c .triage.tiers "$R/.stella/routing.json"); LO=$(jq -r '.[0]' <<<"$TI"); HI=$(jq -r '.[-1]' <<<"$TI")
ML=$(jq .triage.min_labels "$R/.stella/routing.json")
verdict() { ev triage.verdict "$(jq -nc --arg r "$1" --argjson c "$2" '{route: $r, raw: $r, confidence: $c, unsure: false, tier_moved: false, features: [1, 2]}')"; }   # <route> <confidence>

A=$(verdict "$LO" 0.9)
ok '[ -n "$A" ] && tr_ label --id "$A" --route "$HI" --source override --json | jq -e ".id == \"$A\" and .route == \"$HI\"" && [ "$(jq -sc "[.[] | select(.type == \"triage.label\")] | length" "$R/$(ix .event_log)")" = 1 ]' \
  "S1 label takes a logged verdict id and writes one triage.label line"
tr_ label --id nope --route "$LO" --source override >/dev/null; u1=$?; grep -q STL-MDL-741 "$T/err"; c1=$?
tr_ label --id "$A" --route not-a-route --source override >/dev/null; u2=$?
tr_ label --id "$A" --route "$LO" --source whim >/dev/null; u3=$?
ok '[ "$u1" = 1 ] && [ "$c1" = 0 ] && [ "$u2" = 1 ] && [ "$u3" != 0 ]' "S2 an unknown id, a route outside the tiers and a source other than override or reroute are refused (741 for the first two)"
ed routing.json '.triage.tiers = [.triage.tiers[0], "qa-mid"] + .triage.tiers[1:] | .triage.project.default = .triage.tiers[-1]'
ok 'tr_ label --id "$A" --route qa-mid --source reroute --json | jq -e ".route == \"qa-mid\""' "S3 a tier added to the routing data only is a route a label may take (no code names a tier)"

# fit: below min_labels refused; then the threshold splits wrong (low confidence) from right (high confidence) verdicts
ed routing.json --argjson n 4 '.triage.min_labels = $n'
tr_ fit --json >/dev/null; f1=$?
ok '[ "$f1" = 1 ] && grep -q STL-MDL-742 "$T/err" && [ ! -e "$CAL" ]' "S4 fit refuses below triage.min_labels with STL-MDL-742 and writes nothing"
for c in 0.4 0.5; do i=$(verdict "$LO" "$c"); tr_ label --id "$i" --route "$HI" --source override >/dev/null; done
for c in 0.9 0.95; do i=$(verdict "$LO" "$c"); tr_ label --id "$i" --route "$LO" --source reroute >/dev/null; done
tr_ fit --json >"$T/fit.json"
ok 'jq -e ".labels >= 4 and .threshold > 0.5 and .threshold <= 0.9" "$T/fit.json" && jq -e ".threshold == $(jq .threshold "$T/fit.json")" "$CAL" &&
  [ "$(jq -sc "[.[] | select(.type == \"triage.calibrated\")] | length" "$R/$(ix .event_log)")" = 1 ] && python3 -I -B "$R/bin/event_log.py" verify' \
  "S5 fit writes the calibration file with a threshold between the wrong (0.4, 0.5) and the right (0.9, 0.95) verdicts, one triage.calibrated line, the chain verifies"

# fail closed: route refuses before any call
echo '{"schema_version": 1, "threshold": 7}' >"$CAL"
echo hi | tr_ route --json >/dev/null; r1=$?
ok '[ "$r1" = 1 ] && grep -q STL-MDL-742 "$T/err"' "S6 an invalid calibration file: route refuses with STL-MDL-742 (no call is made)"
rm -f "$CAL"; ed routing.json '.triage.project.default = "no-such-tier"'
echo hi | tr_ route --json >/dev/null; r2=$?
ok '[ "$r2" = 1 ] && grep -q STL-MDL-740 "$T/err"' "S7 a triage block whose project route is no tier: route refuses with STL-MDL-740"
ed routing.json '.triage.project.default = .triage.tiers[-1]'

# a worker environment is refused, nothing written
n0=$(grep -c . "$R/$(ix .event_log)")
STUB_WORKER_MARK=1 tr_ fit --json >/dev/null; w=$?
ok '[ "$w" = 1 ] && grep -q STL-CFG-312 "$T/err" && [ "$(grep -c . "$R/$(ix .event_log)")" = "$n0" ]' "S8 a worker environment is refused (STL-CFG-312), no line written"

# the helpers
ok 'python3 -I -B -c "
import sys, math
sys.path.insert(0, sys.argv[1])
import triage
items = [{\"token\": \"{\", \"logprob\": 0.0}, {\"token\": \"\\\"work\\\"\", \"logprob\": math.log(0.25)}, {\"token\": \"}\", \"logprob\": 0.0}]
assert abs(triage.label_prob(items, \"work\") - 0.25) < 1e-9 and triage.label_prob(items, \"chat\") is None and triage.label_prob(None, \"x\") is None
v = {\"a\": {\"features\": [1, 2, 3]}, \"b\": {\"features\": [7, 8, 9]}}
r, p = triage.classifier([1, 2], v, {\"a\": \"x\", \"b\": \"y\"})
assert r == \"x\" and p > 0.5 and triage.classifier([], v, {\"a\": \"x\"}) is None
" "$R/bin"' "S9 label_prob reads the route label's token probability (none when absent); the classifier leans to the labelled class of the shared words"

echo "# triage-selftest: $fails failed"; [ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
