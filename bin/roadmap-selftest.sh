#!/usr/bin/env bash
# Hermetic self-test for the roadmap format and tool (phase P1 item D: bin/roadmap.py check, lint, pick), written tests-first.
# Checks (tests.json ids): AC5-valid (with refusal controls), AC9-feel-refused, AC9-numeric-ok, AC9-pick-stats, AC9-pick-prior.
# Fake entries: a comparator added to the lint data is accepted; min_samples changed in data hands the pick to the stats.
# The roadmaps are written here with jq from the copy's data (install id, preset, tiers, the builder role and its resolved link,
# the project's budget cap); the pick fixture adds a second local model as the builder's escalation rung, priced 3x the first.
# Exit codes, JSON fields and catalog codes are asserted, never wording. No model call.
# ASSUMPTIONS (what design.md leaves open):
#  D1 roadmap.md: prose, then exactly one fence opened by a line "```json roadmap" and closed by "```"; its body is the document.
#  D2 request.digest = the sha256 hex of request.text (UTF-8, as written). D3 vm, while the VM feature is off, is the string "TBD".
#  D4 threshold = {comparator: <one of planner lint.comparators>, value: <number>} or null.
#  D5 check/lint/pick print JSON on stdout; exit 0 = passes; a refusal is exit 1 with a STL code on stdout or stderr.
#  D6 lint --json: {owner_confirm: <count>, checks: [{id, ok, probe}]}, a probe sketch is non-null for a check with a threshold.
#  D7 pick: the cost of a round on a rung comes from the price list (pricing.json; a link priced 3x another costs 3x per round);
#     p from the routing stats file (data-files.json[<planner card_size.stats_index_key>], first_pass rows {kind, connection, model,
#     n, passed}); the prior from data-files.json[<planner model_pick.prior_index_key>]: {schema_version: 1, entries: [{kind,
#     connection, model, first_pass}]}; the answer {rung, link: {connection, model}}. The pick resolves a card role with no card.
#  D8 the project's budget cap: the hard amount of the budgets row of scope project keyed by the project, else by "*".
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=roadmap-selftest
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
RM() { python3 -I "$R/bin/roadmap.py" "$@"; }
uuid() { cat /proc/sys/kernel/random/uuid; }
PROJ=qa-proj; IID=$(jq -r .install_id "$R/$(p install)"); PRESET=$(jq -r .selection.global "$RA")
CAP=$(jq -r --arg p "$PROJ" '[.budgets[] | select(.scope == "project" and (.key == $p or .key == "*"))] | sort_by(.key == "*") | .[0].hard.amount // empty' "$R/$(p budgets)")
C0=$(pq -r '.lint.comparators[0] // empty')
link() { STELLA_ROOT=$R python3 -I "$R/bin/resolve.py" resolve --role "$BR" --project "$PROJ" --card qa-card --json 2>/dev/null | jq -c '[.chain[] | select(.status == "usable")][0] | {connection, model}'; }
LK=$(link); LK=${LK:-null}
REQ="Build a desktop app with a web UI, a backend service and an installer for Windows and Linux."
acc() { jq -nc --arg i "$1" --arg a "$2" --arg o "$3" --arg c "$C0" --argjson v "${4:-null}" '{id: $i, action: $a, observe: $o, threshold: (if $v == null then null else {comparator: $c, value: $v} end), owner_confirm: false, probe: null}'; }
card() { jq -nc --arg i "$1" --arg t "$2" --argjson l "$LK" --argjson k "$3" '{id: $i, title: $t, kind: "qa-kind", files: ["src/\($i)/*"], size: {files: 2, changed_lines: 120, estimate_hours: 2},
  builder: ($l + {rung: 0, reason: "the cheapest link with an accepted first pass"}), checks: $k}'; }   # <id> <title> <checks of its phase it covers (DG-5)>
mkmap() {   # -> the complex request's roadmap document (JSON) on stdout
  jq -n --arg id "$(uuid)" --arg iid "$IID" --arg proj "$PROJ" --arg text "$REQ" --arg dg "$(printf %s "$REQ" | sha256sum | cut -d' ' -f1)" \
    --arg tier "$TOP" --arg preset "$PRESET" --arg br "$BR" --argjson cap "${CAP:-0}" --argjson l "$LK" \
    --argjson a1 "$(acc a1 'GET /health on the backend port' 'HTTP status code' 200)" --argjson a2 "$(acc a2 'load the UI and click Save' 'saved items listed' 1)" \
    --argjson a3 "$(acc a3 'run the installer on a clean VM' 'installer exit code' 0)" \
    --argjson c1 "$(card c1 'backend service' '["a1"]')" --argjson c2 "$(card c2 'web UI' '["a2"]')" --argjson c3 "$(card c3 'installer' '["a3"]')" \
    '{schema_version: 1, id: $id, install_id: $iid, project: $proj, request: {text: $text, digest: $dg}, tier: $tier, preset: $preset,
      phases: [
        {id: "p1", title: "Backend service", goal: "a backend that answers", builds: ["backend", "service"], depends_on: [], builder_role: $br, qa_tier: $tier, vm: "TBD", acceptance: [$a1], cards: [$c1]},
        {id: "p2", title: "Web UI", goal: "a UI on the backend", builds: ["web", "ui"], depends_on: ["p1"], builder_role: $br, qa_tier: $tier, vm: "TBD", acceptance: [$a2], cards: [$c2]},
        {id: "p3", title: "Installer", goal: "installs on both systems", builds: ["installer"], depends_on: ["p1", "p2"], builder_role: $br, qa_tier: $tier, vm: "TBD", acceptance: [$a3], cards: [$c3]}],
      out_of_scope: ["mobile app", "cloud hosting"], estimate: {tokens: 400000, cost: ($cap / 10), hours: 12, budget_cap: ($cap / 2)},
      assignments: {($br): $l}}'; }
render() { { printf '# Roadmap\n\nThe plan for the request, phase by phase. The block below is the source of truth.\n\n```json roadmap\n'; cat "$1"; printf '```\n\nNotes after the block.\n'; } >"$2"; }
mk() { local n=$1; shift; jq "$@" "$T/base.json" >"$T/$n.json" && render "$T/$n.json" "$T/$n.md"; }   # <name> <jq args and filter>: a variant of the base roadmap
mkmap >"$T/base.json"; render "$T/base.json" "$T/base.md"

ok '[ -n "$C0" ] && [ -n "$CAP" ] && [ "$LK" != null ] && pq -e "(.lint.feel_words | length) > 0 and .model_pick.min_samples >= 1 and (.model_pick.prior_index_key | type) == \"string\"" || say "expected planner lint comparators/feel_words, model_pick (min_samples, prior_index_key), a project budget cap ($CAP) and a resolved $BR link ($LK)"' \
  "pre (AC5-valid, AC9-*) the data gives lint comparators and feel words, model_pick, the project's budget cap and a resolvable builder link"

# ---- AC5-valid ----
run v1 RM check "$T/base.md" --project "$PROJ" --json
ok 'okj v1 "type == \"object\""' "AC5-valid the complex request's roadmap.md (3 phases, numeric acceptance, assignments in the preset) passes the validator"
run v2 RM lint "$T/base.md" --json
ok 'okj v2 ".owner_confirm == 0 and (.checks | length) == 3 and all(.checks[]; .probe != null)"' "AC5-valid the same roadmap passes the lint: 3 checks, each with a probe sketch, none owner-confirm"
mk cyc '.phases[0].depends_on = ["p3"]'; run v3 RM check "$T/cyc.md" --project "$PROJ" --json
mk unk '.phases[1].depends_on = ["p9"]'; run v4 RM check "$T/unk.md" --project "$PROJ" --json
ok 'refused v3 && refused v4' "AC5-valid control: a depends_on cycle, and a depends_on naming no phase, are refused with a code"
mk over '.estimate.cost = (.estimate.budget_cap + 1)'; run v5 RM check "$T/over.md" --project "$PROJ" --json
mk capx --argjson c "${CAP:-0}" '.estimate.budget_cap = ($c + 1)'; run v6 RM check "$T/capx.md" --project "$PROJ" --json
ok 'refused v5 && refused v6' "AC5-valid control: estimate.cost over budget_cap, and a budget_cap over the project's cap, are refused"
mk away '.phases[0].cards[0].builder.connection = "qa-nowhere" | .phases[0].cards[0].builder.model = "qa-model"'; run v7 RM check "$T/away.md" --project "$PROJ" --json
mk aaway --arg br "$BR" '.assignments[$br] = {connection: "qa-nowhere", model: "qa-model"}'; run v8 RM check "$T/aaway.md" --project "$PROJ" --json
ok 'refused v7 && refused v8' "AC5-valid control: a card builder link, and an assignment, outside the project's preset are refused"
mk vm '.phases[2].vm = "windows-11"'; run v9 RM check "$T/vm.md" --project "$PROJ" --json
mk dg '.request.digest = ("0" * 64)'; run v10 RM check "$T/dg.md" --project "$PROJ" --json
ok 'refused v9 && refused v10' "AC5-valid control: a vm other than TBD while the VM feature is off, and a request digest that is not the text's, are refused"
{ cat "$T/base.md"; printf '\n```json roadmap\n'; cat "$T/base.json"; printf '```\n'; } >"$T/two.md"; run v11 RM check "$T/two.md" --project "$PROJ" --json
mk nophase 'del(.phases)'; run v12 RM check "$T/nophase.md" --project "$PROJ" --json
ok 'refused v11 && refused v12' "AC5-valid control: two roadmap blocks, and a block the schema refuses (no phases), are refused"
# DG-5: cards carry checks; every acceptance check of a phase is covered by a card of that phase, a card names only its phase's checks
mk uncov --argjson a "$(acc a1b 'GET /version on the backend port' 'HTTP status code' 200)" '.phases[0].acceptance += [$a]'; run v13 RM check "$T/uncov.md" --project "$PROJ" --json
ok 'refused v13' "AC5-valid control (DG-5): an acceptance check no card of its phase covers is refused"
mk foreign '.phases[0].cards[0].checks += ["a2"]'; run v14 RM check "$T/foreign.md" --project "$PROJ" --json
mk nowhere '.phases[0].cards[0].checks += ["a9"]'; run v15 RM check "$T/nowhere.md" --project "$PROJ" --json
ok 'refused v14 && refused v15' "AC5-valid control (DG-5): a card check id that is not an acceptance id of its phase (another phase's, or none) is refused"
ok 'for g in "*" "**" "**/*" "./**"; do mk all --arg g "$g" ".phases[1].cards[0].files = [\$g]" && run v16 RM check "$T/all.md" --project "$PROJ" --json && refused v16 || { say "the files glob $g was not refused"; exit 1; }; done' \
  "AC5-valid control (DG-5): a card files glob that matches everything (*, **, **/*, ./**) is refused"

# ---- AC9-feel-refused / AC9-numeric-ok ----
FEEL='the game feels good'
mk feel --argjson a "$(acc f1 'play the game for one minute' "$FEEL")" '.phases[2].acceptance = [$a] | .phases[2].cards[0].checks = [$a.id]'
mk feelok --argjson a "$(acc f1 'play the game for one minute' "$FEEL" | jq -c '.owner_confirm = true')" '.phases[2].acceptance = [$a] | .phases[2].cards[0].checks = [$a.id]'
run f1 RM lint "$T/feel.md" --json; run f2 RM lint "$T/feelok.md" --json
ok '{ pq -e --arg t "$FEEL" "any(.lint.feel_words[]; . as \$w | \$t | test(\$w; \"i\"))" >/dev/null || say "expected a planner lint feel word in: $FEEL"; } && refused f1' \
  "AC9-feel-refused an acceptance check 'the game feels good' with no threshold and no owner-confirm is refused by the lint"
ok 'okj f2 ".owner_confirm == 1"' "AC9-feel-refused the same check marked owner_confirm passes the lint and is counted owner-confirm (1)"
mk num --argjson a "$(acc n1 'press space once, then advance 30 frames' 'bird y position change in px' 40)" '.phases[2].acceptance = [$a] | .phases[2].cards[0].checks = [$a.id]'
run n1 RM lint "$T/num.md" --json; run n2 RM lint "$T/num.md" --json
ok 'okj n1 ".owner_confirm == 0 and ([.checks[] | select(.id == \"n1\")][0] | .ok == true and .probe != null)" && same n1 n2' \
  "AC9-numeric-ok a numeric check (action, observe, threshold with a data comparator) passes the lint with a probe sketch, the same answer twice"
mk str --argjson a "$(acc n1 'press space once, then advance 30 frames' 'bird y position change in px' 40 | jq -c '.threshold.value = "40"')" '.phases[2].acceptance = [$a] | .phases[2].cards[0].checks = [$a.id]'
mk qcmp --argjson a "$(acc n1 'press space once, then advance 30 frames' 'bird y position change in px' 40 | jq -c '.threshold.comparator = "qa~"')" '.phases[2].acceptance = [$a] | .phases[2].cards[0].checks = [$a.id]'
run n3 RM lint "$T/str.md" --json; run n4 RM lint "$T/qcmp.md" --json
ped '.lint.comparators += ["qa~"]'; run n5 RM lint "$T/qcmp.md" --json
ok 'refused n3 && refused n4 && okj n5 ".owner_confirm == 0"' \
  "AC9-numeric-ok a threshold that is not a number, or whose comparator the data lacks, is refused; the comparator added as data only passes (fake entry)"

# ---- AC9-pick-stats / AC9-pick-prior: rung 0 the cheap link, rung 1 a stronger local model priced 3x ----
CONN=$(jq -r '.connection // empty' <<<"$LK"); CHEAP=$(jq -r '.model // empty' <<<"$LK"); STRONG=qa-strong-model; K=qa-kind
CN=$R/$(p connections); PRJ=$R/$(p pricing)
jq --arg c "$CONN" --arg s "$STRONG" '(.entries[] | select(.id == $c) | .models) |= (. + [.[0] + {id: $s}])' "$CN" >"$CN.n" && mv "$CN.n" "$CN"
jq --arg p "$PRESET" --arg r "$BR" --arg c "$CONN" --arg s "$STRONG" '.effort_modes[$p].roles[$r].escalation_chain = [{connection: $c, model: $s, parameters: {}}]' "$RA" >"$RA.n" && mv "$RA.n" "$RA"
price() { jq -nc --arg c "$CONN" --arg m "$1" --argjson v "$2" --arg g "$(uuid)" --arg i "$IID" '{id: ("qa-" + ($m | gsub("[^a-z0-9.-]"; "-"))), connection: $c, model: $m,
  effective_from: "2026-01-01", source: "qa fixture", currency: "USD", per_million: {input: $v, output: $v, cache_write: $v, cache_read: $v, reasoning: $v},
  batch_discount: 0, global_id: $g, install_id: $i}'; }
jq --argjson a "$(price "$CHEAP" 1)" --argjson b "$(price "$STRONG" 3)" '.entries += [$a, $b]' "$PRJ" >"$PRJ.n" && mv "$PRJ.n" "$PRJ"
ped '.model_pick.min_samples = 10'
SK=$(pq -r '.card_size.stats_index_key // empty'); SREL=$(jq -r --arg k "$SK" '.[$k] // empty' "$IX" 2>/dev/null); SF=$R/${SREL:-.qa-no-stats-key.json}
PK=$(pq -r '.model_pick.prior_index_key // empty'); PREL=$(jq -r --arg k "$PK" '.[$k] // empty' "$IX" 2>/dev/null); PF=$R/${PREL:-.qa-no-prior-key.json}
mkdir -p "$(dirname "$SF")" "$(dirname "$PF")"
stats() { jq -n --arg k "$K" --arg c "$CONN" --arg a "$CHEAP" --arg b "$STRONG" --argjson n "$1" --argjson pa "$2" --argjson pb "$3" \
  '{schema_version: 1, first_pass: [{kind: $k, connection: $c, model: $a, n: $n, passed: $pa}, {kind: $k, connection: $c, model: $b, n: $n, passed: $pb}], size_buckets: []}' >"$SF"; }
prior() { jq -n --arg k "$K" --arg c "$CONN" --arg a "$CHEAP" --arg b "$STRONG" --argjson pa "$1" --argjson pb "$2" \
  '{schema_version: 1, entries: [{kind: $k, connection: $c, model: $a, first_pass: $pa}, {kind: $k, connection: $c, model: $b, first_pass: $pb}]}' >"$PF"; }
ok 'STELLA_ROOT=$R python3 -I "$R/bin/stella_data.py" check >"$T/o/pk0.out" 2>&1 || say "the pick fixture is not valid data: $(head -c 300 "$T/o/pk0.out")"' \
  "pre (AC9-pick-*) the pick fixture (a second local model as the builder's rung 1, both priced) is valid data"
stats 20 1 20; prior 0.95 0.95; run k1 RM pick --project "$PROJ" --role "$BR" --kind "$K" --json
ok 'okj k1 --arg s "$STRONG" ".rung == 1 and .link.model == \$s"' \
  "AC9-pick-stats stats where the cheap model passes 1/20 first tries of a kind (prior says 0.95): the card starts on the stronger allowed model (rung 1)"
stats 3 0 3; prior 0.95 0.95; run k2 RM pick --project "$PROJ" --role "$BR" --kind "$K" --json
prior 0.05 1.0; run k3 RM pick --project "$PROJ" --role "$BR" --kind "$K" --json
ok 'okj k2 --arg c "$CHEAP" ".rung == 0 and .link.model == \$c" && okj k3 --arg s "$STRONG" ".rung == 1 and .link.model == \$s"' \
  "AC9-pick-prior too few samples (3 < min_samples): the benchmark prior decides, either way (prior good: cheap rung 0; prior poor: rung 1)"
prior 0.95 0.95; ped '.model_pick.min_samples = 2'; run k4 RM pick --project "$PROJ" --role "$BR" --kind "$K" --json
ok 'okj k4 --arg s "$STRONG" ".rung == 1 and .link.model == \$s"' "AC9-pick-prior min_samples lowered in data (2 <= 3): the same stats now decide (0/3 for the cheap model: rung 1)"
finish
