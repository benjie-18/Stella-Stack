#!/usr/bin/env bash
# Hermetic self-test for the planner rubric (phase P1 item C: bin/planner_rubric.py score and split), written tests-first.
# Checks (tests.json ids): AC2-deterministic, AC2-single-file (rubric part: the lowest tier; the direct route is planner-selftest's),
# AC2-multi-system, AC2-unsure-up, AC9-split. Fake entries: a rubric feature added as data only is scored and counted unsure;
# a stats change, a min_samples change and a default_limits change alone move the split answer.
# No feature, tier, role or model is named here: every id, point, threshold and limit is read from the copy's data. Answers are
# data-only fixtures written here (no model call, no route.py). Exit codes, JSON fields and trusted lines are asserted, never wording.
# ASSUMPTIONS (what design.md leaves open):
#  R1 score --features FILE|- [--request-id R] --json prints {features, unsure: [ids], score, tier, reason}, exit 0 for any answer
#     (an unusable answer makes features unsure, it is no error).
#  R2 one trusted planner.rubric line per score call; its payload (the line merged with .detail/.new) has request, score, tier, unsure.
#  R3 routing stats: data-files.json[<planner card_size.stats_index_key>] is the stats file's path under the root, the mock until D1:
#     {schema_version: 1, first_pass: [{kind, connection, model, n, passed}], size_buckets: [{kind, connection, model,
#     size: {files, changed_lines, estimate_hours}, n, failed}]}; a bucket's failure rate is failed / n.
#  R4 split --card FILE: FILE is one roadmap card (design item D: {id, title, kind, files, size, builder}); --link is
#     <connection>/<model>; the answer is {split, limit, size, parts}, parts = max over the size fields of ceil(size / limit).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=planner-rubric-selftest
# ---- harness: a scratch root of its own (bin, .stella, docs copied), its own HOME, temp and alert folder ----
T=$(mktemp -d "${TMPDIR:-/tmp}/$ME.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'if [ -n "${KEEP:-}" ]; then echo "# KEPT $T"; else chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; fi' EXIT
R=$T/root
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$R/.claude" "$T/home" "$T/tmp" "$T/sup/logs" "$T/pb" "$T/o"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"
[ -e "$ROOT/.supervisor/limits.env" ] && cp "$ROOT/.supervisor/limits.env" "$R/.supervisor/"
for f in opencode.json .mcp.json .claude/settings.json .claude/skills; do [ -e "$ROOT/$f" ] && cp -r "$ROOT/$f" "$R/$f"; done
cd "$T" || exit 1
jq() { env -u HOME jq "$@"; }
IX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IX"; }
p() { jq -r --arg s "$1" '[.files[] | select(.schema == $s and .format == "json") | .path][0] // empty' "$IX"; }   # <schema>: its file
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$ROOT/$(ix .role_table)" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ BOX_HERMES_ROOT=$T/hermes \
  GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=qa GIT_AUTHOR_EMAIL=qa@scratch.invalid GIT_COMMITTER_NAME=qa GIT_COMMITTER_EMAIL=qa@scratch.invalid
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB HERMES_HOME \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
POL=$R/$(ix '.files[] | select(.id == "owner-auth") | .path')
for v in $(jq -r '.worker_signals.token_env[]?' "$POL" 2>/dev/null); do unset "$v"; done
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH   # a stub board
: >"$T/sup/logs/alerts.log"
fails=0; n=0
# ok <test> <label>: a FAIL line (never a crash) with the case's saved output and expectation under it
ok() { n=$((n+1)); if ( set -o pipefail; eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/o/last" ] && tail -n 3 "$T/o/last" | cut -c1-240 | sed "s/^/${QA_DEBUG:+FAIL}     | /"; fi; : >"$T/o/last"; }
finish() { echo "# $ME: $n cases, $fails failed"; [ "$fails" = 0 ] && echo "selftest PASS" || echo "selftest FAIL"; [ "$fails" = 0 ]; exit $?; }
# run <tag> <cmd...>: stdout to o/<tag>.out, stderr to o/<tag>.err, exit code in o/<tag>.rc
run() { local t=$1; shift; "$@" >"$T/o/$t.out" 2>"$T/o/$t.err"; echo $? >"$T/o/$t.rc"; }
rc() { cat "$T/o/$1.rc" 2>/dev/null; }
got() { echo "got exit $(rc "$1"): $(cat "$T/o/$1.out" "$T/o/$1.err" 2>/dev/null | head -c 200 | tr '\n' ' ')"; }
say() { echo "$*" >>"$T/o/last"; return 1; }
# okj <tag> [jq args] <filter>: exit 0 and a JSON answer the filter holds on
okj() { local t=$1; shift; [ "$(rc "$t")" = 0 ] && [ -s "$T/o/$t.out" ] && jq -e "$@" "$T/o/$t.out" >/dev/null 2>&1 || say "expected exit 0 and JSON with ${*: -1}; $(got "$t")"; }
# refused <tag>: exit 1 and a catalog code in the answer
refused() { [ "$(rc "$1")" = 1 ] && grep -qE 'STL-[A-Z]+-[0-9]{3}' "$T/o/$1.out" "$T/o/$1.err" 2>/dev/null || say "expected a refusal (exit 1 and a STL code); $(got "$1")"; }
same() { cmp -s "$T/o/$1.out" "$T/o/$2.out" || say "expected $1 and $2 byte for byte equal; $(got "$1") / $(got "$2")"; }
PAY='def pay: [., .detail, .new] | map(select(type == "object")) | add;'
proof() { python3 -I -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import event_log as e; print(json.dumps(e.proof_lines()))' "$R/bin" 2>/dev/null || echo '[]'; }
lines() { proof | jq -c --arg t "$1" "$PAY"' [.[] | select(.type == $t) | pay]'; }   # <type>: payloads of its trusted lines
# ---- the planner data (the design's path while the index has no row) ----
PJ=$R/$(p planner); [ "$PJ" = "$R/" ] && PJ=$R/.stella/planner.json
pq() { jq "$@" "$PJ" 2>/dev/null; }
ped() { jq "$@" "$PJ" >"$PJ.n" 2>/dev/null && mv "$PJ.n" "$PJ"; }   # <jq args and filter>: edit the planner data
RT=$R/$(p routing); RA=$R/$(p role-assignments)
LOW=$(jq -r '.task_tiers[0].id' "$RT"); TOP=$(jq -r '.task_tiers[-1].id' "$RT"); BR=$(jq -r '.builder_roles[0]' "$RT")
PR() { python3 -I "$R/bin/planner_rubric.py" "$@"; }
FEATS=$(pq -c '[.rubric.features[].id]'); NF=$(pq '.rubric.features | length'); NF=${NF:-0}
ans() { pq -c --argjson t "$1" '[.rubric.features[].id] | map({key: ., value: (. as $i | $t | index($i) != null)}) | from_entries'; }   # <true ids>: an answer
pts() { pq --argjson t "$1" '[.rubric.features[] | select(.id as $i | $t | index($i)) | .points] | add // 0'; }               # <true ids>: their points
want() { pq -r --argjson s "$1" --argjson u "$2" '.rubric as $r | ($r.thresholds | map(.max_score == null or $s <= .max_score) | index(true)) as $b
  | ($r.thresholds | length) as $l | $r.thresholds[[if $u > 0 then $b + ($r.unsure.raise_tiers // 1) else $b end, $l - 1] | min].tier'; }   # <score> <unsure count>: the tier

ok 'pq -e "(.rubric.features | length) >= 2 and (.rubric.thresholds | length) >= 2 and (.rubric.thresholds[-1].max_score == null)
  and .rubric.unsure.raise_tiers >= 1 and .rubric.thresholds[0].tier == \"$LOW\" and .rubric.thresholds[-1].tier == \"$TOP\"" || say "expected planner data with rubric features, thresholds from $LOW to $TOP and unsure.raise_tiers in $PJ"' \
  "pre (AC2-*) the planner data gives rubric features, ordered thresholds from the lowest to the top task tier and the unsure raise"

# ---- AC2-single-file / AC2-deterministic ----
A0=$T/a-none.json; ans '[]' >"$A0"   # a single-file change of a known pattern: no feature holds
F1=$(pq -r '.rubric.features[0].id // empty'); A1=$T/a-one.json; ans "[\"$F1\"]" >"$A1"
run s0 PR score --features "$A0" --request-id qa-req-0 --json
ok 'okj s0 --arg t "$LOW" ".score == 0 and .unsure == [] and .tier == \$t"' "AC2-single-file a single-file answer (no feature true) scores 0 and the lowest tier ($LOW)"
run d1 PR score --features "$A1" --request-id qa-req-1 --json; run d2 PR score --features "$A1" --request-id qa-req-1 --json
run d3 PR score --features - --request-id qa-req-1 --json <"$A1"
S1=$(pts "[\"$F1\"]"); W1=$(want "${S1:-0}" 0)
ok 'okj d1 --argjson s "${S1:-0}" --arg t "$W1" ".score == \$s and .tier == \$t and .unsure == []" && same d1 d2 && same d1 d3' \
  "AC2-deterministic the same answer scored three times (file twice, stdin once) gives the same output byte for byte (score = its points)"
ok 'L=$(lines planner.rubric | jq -c "[.[] | select(.request == \"qa-req-1\")]"); [ "$(jq length <<<"$L")" = 3 ] && jq -e --argjson s "${S1:-0}" --arg t "$W1" "all(.score == \$s and .tier == \$t)" <<<"$L" >/dev/null || say "expected 3 trusted planner.rubric lines for qa-req-1 with score $S1 and tier $W1, got: $L"' \
  "AC2-deterministic each score call writes one trusted planner.rubric line carrying the request, the score and the tier"

# ---- AC2-multi-system: the top-points feature (touches more than one system) and the next ones until past the second-last threshold ----
MULTI=$(pq -c '.rubric as $r | $r.thresholds[-2].max_score as $m | reduce ($r.features | sort_by(-.points))[] as $x ({ids: [], s: 0};
  if .s > $m then . else {ids: (.ids + [$x.id]), s: (.s + $x.points)} end) | .ids'); MULTI=${MULTI:-[]}
AM=$T/a-multi.json; ans "$MULTI" >"$AM"; SM=$(pts "$MULTI")
run m1 PR score --features "$AM" --request-id qa-req-m --json
ok 'okj m1 --argjson s "${SM:-0}" --arg t "$TOP" --argjson f "$MULTI" ".score == \$s and .tier == \$t and .unsure == [] and ([.features | to_entries[] | select(.value == true) | .key] | sort) == (\$f | sort)"' \
  "AC2-multi-system a multi-system installer answer ($MULTI) scores the sum of its points and the top tier ($TOP)"

# ---- AC2-unsure-up: non-JSON, junk after the object, a missing feature, a non-bool; one tier up, capped at the top ----
U1=$(want 0 1)
printf 'It touches the UI, the backend and the installer.\n' >"$T/a-prose.txt"; { cat "$A0"; echo ' and some trailing text'; } >"$T/a-junk.txt"
pq -c '[.rubric.features[].id] as $f | [$f[] | {key: ., value: false}] | from_entries | del(.[$f[-1]])' >"$T/a-missing.json"
pq -c '[.rubric.features[].id] as $f | [$f[] | {key: ., value: false}] | from_entries | .[$f[0]] = "yes"' >"$T/a-nonbool.json"
FL=$(pq -r '.rubric.features[-1].id // empty')
run u1 PR score --features "$T/a-prose.txt" --json; run u2 PR score --features "$T/a-junk.txt" --json
run u3 PR score --features "$T/a-missing.json" --json; run u4 PR score --features "$T/a-nonbool.json" --json
ok 'okj u1 --argjson f "${FEATS:-[]}" --arg t "$U1" "(.unsure | sort) == (\$f | sort) and .score == 0 and .tier == \$t" && okj u2 --argjson f "${FEATS:-[]}" --arg t "$U1" "(.unsure | sort) == (\$f | sort) and .tier == \$t"' \
  "AC2-unsure-up a non-JSON answer, and a JSON object with junk after it, make every feature unsure and move the tier one up ($U1)"
ok 'okj u3 --arg l "$FL" --arg t "$U1" ".unsure == [\$l] and .score == 0 and .tier == \$t" && [ "$U1" != "$LOW" ]' \
  "AC2-unsure-up a missing feature counts unsure and moves the lowest tier up to $U1"
ok 'okj u4 --arg f "$F1" --arg t "$U1" ".unsure == [\$f] and .score == 0 and .tier == \$t"' "AC2-unsure-up a feature answered with a non-bool counts unsure (its points not added) and moves the tier up"
FO=$(pq -r --argjson m "$MULTI" '[.rubric.features[].id | select(. as $i | $m | index($i) | not)][0] // empty')
ans "$MULTI" | jq -c --arg o "$FO" 'del(.[$o])' >"$T/a-multi-missing.json" 2>/dev/null; run u5 PR score --features "$T/a-multi-missing.json" --json
ok '{ [ -n "$FO" ] || say "expected a rubric feature outside the top-tier answer $MULTI"; } && okj u5 --arg o "$FO" --arg t "$TOP" ".unsure == [\$o] and .tier == \$t"' "AC2-unsure-up the raise is capped: a top-tier answer with a missing feature stays at the top tier ($TOP)"

# ---- AC9-split: reliable size of (kind, link) from the routing stats; data alone changes the answer ----
SK=$(pq -r '.card_size.stats_index_key // empty'); SREL=$(jq -r --arg k "$SK" '.[$k] // empty' "$IX" 2>/dev/null)
SF=$R/${SREL:-.qa-no-stats-key.json}; mkdir -p "$(dirname "$SF")"
CONN=$(jq -r --arg r "$BR" '[.assignments[] | select(.role == $r and .scope.level == "global")][0].chain[0].connection // empty' "$RA")
MODEL=$(jq -r --arg r "$BR" '[.assignments[] | select(.role == $r and .scope.level == "global")][0].chain[0].model // empty' "$RA")
K=qa-kind; LINK="$CONN/$MODEL"
SMALL='{"files": 2, "changed_lines": 100, "estimate_hours": 2}'; BIG='{"files": 10, "changed_lines": 800, "estimate_hours": 8}'
stats() {   # <failed of the big bucket> <n of the big bucket> [connection]: the stats file with a small bucket that holds and a big one
  jq -n --arg k "$K" --arg c "${3:-$CONN}" --arg m "$MODEL" --argjson s "$SMALL" --argjson b "$BIG" --argjson f "$1" --argjson n "$2" \
    '{schema_version: 1, first_pass: [], size_buckets: [{kind: $k, connection: $c, model: $m, size: $s, n: 20, failed: 1},
      {kind: $k, connection: $c, model: $m, size: $b, n: $n, failed: $f}]}' >"$SF"; }
CARD=$T/card.json
jq -n --arg k "$K" --arg c "$CONN" --arg m "$MODEL" '{id: "qa-card-1", title: "qa card", kind: $k, files: ["src/*"],
  size: {files: 4, changed_lines: 300, estimate_hours: 3}, builder: {connection: $c, model: $m, rung: 0, reason: "qa"}}' >"$CARD"
ped '.card_size.min_samples = 10 | .card_size.max_fail_rate = 0.2 | .card_size.default_limits = {files: 1000, changed_lines: 100000, estimate_hours: 1000}'
ok '[ -n "$SK" ] && [ -n "$SREL" ] && [ -n "$CONN" ] && [ -n "$MODEL" ] || say "expected planner card_size.stats_index_key naming a data-files key ($SK -> $SREL) and a $BR link"' \
  "pre (AC9-split) the planner data names the routing stats index key and the index gives its path"
stats 15 20; run p1 PR split --card "$CARD" --kind "$K" --link "$LINK" --json
ok 'okj p1 --argjson s "$SMALL" ".split == true and .limit == \$s and .parts == 3 and .size == {files: 4, changed_lines: 300, estimate_hours: 3}"' \
  "AC9-split stats where the link fails 15/20 above a size: a larger card is split to the reliable size (3 parts)"
stats 1 20; run p2 PR split --card "$CARD" --kind "$K" --link "$LINK" --json
ok 'okj p2 ".split == false"' "AC9-split the same card with stats where the big bucket holds (1/20 failed): no split (a stats change alone)"
stats 0 5; run p3 PR split --card "$CARD" --kind "$K" --link "$LINK" --json
ok 'okj p3 --argjson s "$SMALL" ".split == true and .limit == \$s and .parts == 3"' "AC9-split a bucket with fewer than min_samples cards does not count as reliable: still split"
stats 15 20 qa-other-connection; run p4 PR split --card "$CARD" --kind "$K" --link "$LINK" --json
ped '.card_size.default_limits = {files: 1, changed_lines: 50, estimate_hours: 1}'; run p5 PR split --card "$CARD" --kind "$K" --link "$LINK" --json
ok 'okj p4 ".split == false" && okj p5 ".split == true and .limit == {files: 1, changed_lines: 50, estimate_hours: 1} and .parts == 6"' \
  "AC9-split no stats for the link: default_limits decide, and changing them in data alone splits the card (6 parts)"
ped '.card_size.default_limits = {files: 1000, changed_lines: 100000, estimate_hours: 1000} | .card_size.min_samples = 30'; stats 15 20; run p6 PR split --card "$CARD" --kind "$K" --link "$LINK" --json
ok 'okj p6 ".split == false"' "AC9-split min_samples raised in data above every bucket's count: the default limits decide (no split)"

# ---- fake entry: a rubric feature added as data only ----
ped --argjson m "$(pq '.rubric.thresholds[-2].max_score + 1')" '.rubric.features += [{id: "qa_fake_feature", points: $m, question: "Does the request need the qa fake thing?"}]'
jq -c '. + {qa_fake_feature: true}' "$A0" >"$T/a-fake.json" 2>/dev/null; run k1 PR score --features "$T/a-fake.json" --json; run k2 PR score --features "$A0" --json
ok 'okj k1 --arg t "$TOP" ".tier == \$t and .unsure == [] and .features.qa_fake_feature == true"' "AC2-multi-system fake entry: a feature added as data only scores its points (top tier)"
ok 'okj k2 --arg t "$U1" ".unsure == [\"qa_fake_feature\"] and .tier == \$t"' "AC2-unsure-up fake entry: an answer that lacks the data-only feature counts it unsure and moves the tier up"
finish
