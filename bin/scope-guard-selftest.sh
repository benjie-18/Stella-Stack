#!/usr/bin/env bash
# Hermetic self-test for the scope guard (phase P1 item G: bin/scope_guard.py check) and the 2026-11-06 replay, written tests-first.
# Checks (tests.json ids): AC7-replay, AC7-flag. Fixture: bin/fixtures/planner/replay-2026-11-06/ (request.txt: the request of the
# real-use findings of 2026-11-06; roadmap.md: a mock planner answer for that guessing game with its escalation point;
# flappy-phase.json: the drift of that day as one phase). Its install-specific fields (install id, project, preset, tier, builder
# role and link, budget, comparators) are replaced here from the copy's data, so the planner's content stays as written.
# Fake entry: request terms added to the guard's stopwords as data only flag the phase that shared them.
# Exit codes, JSON fields and finding shapes are asserted, never wording. No model call.
# ASSUMPTIONS (what design.md leaves open; roadmap.md format and digest as in roadmap-selftest.sh D1-D4, D8):
#  G1 check --roadmap FILE [--built FILE] --json prints {findings: [...]}: exit 0 with no finding, exit 1 with at least one.
#  G2 each finding is in qa_findings submit format ({check, file, lines: [a, b], test, severity, repro, evidence, static}) with
#     the planner data's scope_guard.severity, and its text names the flagged phase id or built item.
#  G3 --built FILE: {paths: [...], titles: [...], artifacts: [...]}; terms are lower-case words split on non-alphanumerics; a built
#     item is flagged when it shares a word with an out_of_scope entry or no word with any phase's builds terms.
#  G4 the replay (AC7-replay) is roadmap check + lint + scope guard on the planner answer; the route step is planner-selftest's.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=scope-guard-selftest
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
SG() { python3 -I "$R/bin/scope_guard.py" "$@"; }
RM() { python3 -I "$R/bin/roadmap.py" "$@"; }
FX=$R/bin/fixtures/planner/replay-2026-11-06
PROJ=qa-proj; IID=$(jq -r .install_id "$R/$(p install)"); PRESET=$(jq -r .selection.global "$RA")
CAP=$(jq -r --arg p "$PROJ" '[.budgets[] | select(.scope == "project" and (.key == $p or .key == "*"))] | sort_by(.key == "*") | .[0].hard.amount // empty' "$R/$(p budgets)")
C0=$(pq -r '.lint.comparators[0] // empty'); SEV=$(pq -r '.scope_guard.severity // empty')
LK=$(STELLA_ROOT=$R python3 -I "$R/bin/resolve.py" resolve --role "$BR" --project "$PROJ" --card qa-card --json 2>/dev/null | jq -c '[.chain[] | select(.status == "usable")][0] | {connection, model}'); LK=${LK:-null}
REQ=$(cat "$FX/request.txt" 2>/dev/null); REQ=${REQ%$'\n'}
block() { sed -n '/^```json roadmap$/,/^```$/p' "$1" | sed '1d;$d'; }   # <roadmap.md>: its JSON block
prose() { sed '/^```json roadmap$/,$d' "$1"; }
# the planner answer with this install's fields: the request from request.txt, links/role/preset/tier/budget/comparator from data
fill() { jq --arg iid "$IID" --arg proj "$PROJ" --arg text "$REQ" --arg dg "$(printf %s "$REQ" | sha256sum | cut -d' ' -f1)" --arg tier "$TOP" \
  --arg preset "$PRESET" --arg br "$BR" --argjson l "$LK" --argjson cap "${CAP:-0}" --arg c "$C0" \
  '.install_id = $iid | .project = $proj | .request = {text: $text, digest: $dg} | .tier = $tier | .preset = $preset
   | .estimate.budget_cap = ($cap / 2) | .estimate.cost = ($cap / 10) | .assignments = {($br): $l}
   | .phases |= map(.builder_role = $br | .qa_tier = $tier | .cards |= map(.builder = (.builder + $l))
     | .acceptance |= map(if .threshold == null then . else .threshold.comparator = $c end))'; }
render() { { prose "$FX/roadmap.md"; printf '```json roadmap\n'; cat "$1"; printf '```\n'; } >"$2"; }
block "$FX/roadmap.md" | fill >"$T/replay.json" 2>/dev/null; render "$T/replay.json" "$T/replay.md"
jq --slurpfile f "$FX/flappy-phase.json" '.phases += [$f[0] | .builder_role = $br | .qa_tier = $tier | .cards |= map(.builder = (.builder + $l))]' \
  --arg br "$BR" --arg tier "$TOP" --argjson l "$LK" "$T/replay.json" >"$T/flappy.json" 2>/dev/null; render "$T/flappy.json" "$T/flappy.md"
# fnd <tag> <count> <needle>: exit 1, that many findings, each in submit format with the data severity, the first naming the needle
fnd() { [ "$(rc "$1")" = 1 ] && [ -s "$T/o/$1.out" ] && jq -e --argjson n "$2" --arg s "$SEV" --arg x "$3" '(.findings | length) == $n
  and all(.findings[]; (.check | type) == "string" and (.file | type) == "string" and (.lines | type) == "array" and (.lines | length) == 2
    and (.test | type) == "string" and .severity == $s and (.repro == null or (.repro | type) == "array")
    and (.evidence == null or (.evidence | type) == "array") and (.static | type) == "boolean")
  and (.findings[0] | tostring | contains($x))' "$T/o/$1.out" >/dev/null 2>&1 || say "expected exit 1 and $2 finding(s) in submit format (severity $SEV) naming $3; $(got "$1")"; }
clean() { okj "$1" '.findings == []'; }

ok 'grep -qi "guessing game" "$FX/request.txt" && grep -qi "escalation point" "$FX/request.txt" && ! grep -qi flappy "$FX/request.txt" && [ "$(block "$FX/roadmap.md" | jq -r .request.text)" = "$REQ" ] && [ -s "$T/replay.json" ] || say "expected the replay fixture (request.txt, roadmap.md with one json roadmap block for the same request)"' \
  "pre (AC7-*) the replay fixture holds the 2026-11-06 request (a guessing game with an escalation point) and a planner answer for it"
ok '[ -n "$SEV" ] && [ -n "$C0" ] && [ "$LK" != null ] && pq -e "(.scope_guard.stopwords | length) > 0 and .scope_guard.min_shared_terms >= 1" >/dev/null || say "expected planner scope_guard (stopwords, min_shared_terms, severity $SEV), lint comparators and a resolved $BR link"' \
  "pre (AC7-*) the data gives the scope guard's stopwords, min_shared_terms and severity"

# ---- AC7-replay ----
run r1 RM check "$T/replay.md" --project "$PROJ" --json; run r2 RM lint "$T/replay.md" --json; run r3 SG check --roadmap "$T/replay.md" --json
ok 'okj r1 "type == \"object\"" && okj r2 ".owner_confirm == 1"' "AC7-replay the planner answer for the 2026-11-06 request passes roadmap check and lint (one owner-confirm feel check)"
ok 'clean r3' "AC7-replay the scope guard finds nothing: every phase builds what the request asked for"
jq -n --arg r "$REQ" '{paths: ["guess/index.html", "guess/game.js"], titles: ["guessing game page and hint logic", "escalation point after wrong guesses"], artifacts: ["guess/index.html"]}' >"$T/built-ok.json"
run r4 SG check --roadmap "$T/replay.md" --built "$T/built-ok.json" --json
ok 'clean r4' "AC7-replay the built work of that game (paths, card titles, artifacts) passes the scope guard"

# ---- AC7-flag ----
run f1 SG check --roadmap "$T/flappy.md" --json
ok 'fnd f1 1 p3' "AC7-flag the same roadmap with a phase 'Flappy Bird clone' is flagged: one finding for that phase"
jq '.titles += ["escape room puzzle"]' "$T/built-ok.json" >"$T/built-escape.json"; run f2 SG check --roadmap "$T/replay.md" --built "$T/built-escape.json" --json
jq '.artifacts += ["flappy-bird-clone.html"]' "$T/built-ok.json" >"$T/built-flappy.json"; run f3 SG check --roadmap "$T/replay.md" --built "$T/built-flappy.json" --json
ok 'fnd f2 1 "escape room puzzle" && fnd f3 1 "flappy-bird-clone.html"' \
  "AC7-flag built work nobody asked for is flagged: a card title matching no phase term, an artifact matching out_of_scope"
ped '.scope_guard.stopwords += ["escalation", "point"]'; run f4 SG check --roadmap "$T/replay.md" --json
ok 'fnd f4 1 p2' "AC7-flag fake entry: the request terms the escalation phase shares, added as stopwords in data only, flag that phase"
finish
