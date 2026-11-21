#!/usr/bin/env bash
# Shared harness of bin/planner-selftest.sh (P1 item E) and bin/replan-selftest.sh (P1 item F), written tests-first by the tester.
# Sourced after the caller sets ME and S (its section). It builds one scratch root per section and gives helpers; it runs nothing
# of the planner itself. Pieces, each copied from the selftest that owns the pattern:
#  - scratch root, own HOME/TMPDIR/alert folder, worker signals cleared            (bin/qa-loop-selftest.sh)
#  - bin/mock_provider.py on a free port, a fake connection on it, a folder key backend, probe records (bin/failover-selftest.sh)
#  - bin/resolve.py wrapped: the planner and rubric roles get a fixture chain on the mock (chains/<role>.json); every other role,
#    the CLI and the rung walk stay the real resolver's
#  - the test approver: a stub owner channel, approvals.py deliver / owner answer / collect (bin/approvals-selftest.sh t1a)
#  - a stub board (hermes kanban show <card> answers cards/<card>.json), a scratch projects.db binding the project to a scratch repo
# ASSUMPTIONS on the CLIs under test (design.md and its Design check rulings leave these open; the tester's report lists them):
#  P1 planner.py route --project P [--card C] --request FILE --json runs the rubric itself (route.py call --role <rubric.extract_role>),
#     so the rubric answer comes from the mock; its JSON carries run, mode, mode_source, tier, behavior, question_first.
#  P2 planner.py plan --run R --json -> {version, ...}; submit --run R --json (no --file, no --repo: the repo is the project's binding)
#     -> {version, commit, digest, request?, body?}; questions --run R --file Q --json -> {request}; gate status --run R --json ->
#     {status}; gate edit --run R --file F --json -> {version, request}; may-start --run R --card C --json (exit 0 = may start).
#  P3 planner.py bind --run R --card <board card> --roadmap-card <roadmap card id> --json writes planner.card-bound (DG-1 names the
#     line, not the command).
#  P4 trusted planner.* lines are found by type and by the run id (or card id) anywhere in the line.
#  P5 roadmap.md follows bin/roadmap-selftest.sh (item D's tests, its D1-D4 and D8): threshold {comparator: <planner
#     lint.comparators[0]>, value}, vm "TBD", request.digest = sha256 hex of request.text, a card builder link at rung 0, estimate under
#     the project's budget cap; plus DG-5's cards checks: [acceptance ids]. The replay fixture (bin/fixtures/planner/replay-2026-11-06)
#     is not reused: these flows need two cards in phase 1 with their own files.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/$ME.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'kill $(jobs -p) 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "# KEPT $T"; else chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; fi' EXIT
R=$T/root; MR=$T/mockroot
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$R/.claude" "$R/chains" "$MR" "$T/home" "$T/tmp" "$T/sup/logs" "$T/pb" "$T/o" "$T/cards" "$T/ans"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"; cp -r "$ROOT/.stella" "$ROOT/docs" "$MR/"
[ -e "$ROOT/.supervisor/limits.env" ] && cp "$ROOT/.supervisor/limits.env" "$R/.supervisor/"
for f in opencode.json .mcp.json .claude/settings.json .claude/skills; do [ -e "$ROOT/$f" ] && cp -r "$ROOT/$f" "$R/$f"; done
cd "$T" || exit 1
jq() { env -u HOME jq "$@"; }
IX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IX"; }
p() { jq -r --arg s "$1" '[.files[] | select(.schema == $s and .format == "json") | .path][0] // empty' "$IX"; }   # <schema>: its file
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$ROOT/$(ix .role_table)" >"$RJ"
OWNER_ID=111111111111111111   # a made-up Discord id, only in the scratch owner config
printf "OWNER_TIMEZONE='UTC'\nOWNER_DISCORD_USER_ID='%s'\n" "$OWNER_ID" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ BOX_HERMES_ROOT=$T/hermes \
  PROJECTS_DB=$T/projects.db GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=qa GIT_AUTHOR_EMAIL=qa@scratch.invalid GIT_COMMITTER_NAME=qa GIT_COMMITTER_EMAIL=qa@scratch.invalid
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB HERMES_HOME \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
POL=$R/$(ix '.files[] | select(.id == "owner-auth") | .path')
for v in $(jq -r '.worker_signals.token_env[]?' "$POL" 2>/dev/null); do unset "$v"; done
jq -r '.sandbox.boxed_profiles[]? as $p | .profiles[$p].dir // ("profiles/" + $p)' "$RJ" | while read -r d; do mkdir -p "$T/hermes/$d/home"; done
# the stub board: "kanban --board <the stack's board> show <card> --json" prints cards/<card>.json; a send is recorded; anything else "[]"
BOARD=$(sed -n 's/^KANBAN_BOARD=\([A-Za-z0-9_-]*\).*/\1/p' "$ROOT/bin/kanban-board.sh")
cat >"$T/pb/hermes" <<S
#!/usr/bin/env bash
case " \$* " in *" send "*) echo "\$*" >>"$T/sends"; exit 0;; esac
if [ "\$1 \$2 \$3 \$4" = "kanban --board $BOARD show" ]; then [ -f "$T/cards/\$5.json" ] && exec cat "$T/cards/\$5.json"; exit 1; fi
echo "[]"
S
chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH
AL=$T/sup/logs/alerts.log; : >"$AL"
fails=0; n=0
# ok <test> <label>: a FAIL line (never a crash) with the last saved output of the case under it
ok() { n=$((n+1)); if ( set -o pipefail; eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/o/last" ] && tail -n 3 "$T/o/last" | cut -c1-240 | sed "s/^/${QA_DEBUG:+FAIL}     | /"; fi; : >"$T/o/last"; }
finish() { echo "# $ME $S: $n cases, $fails failed"; [ "$fails" = 0 ]; exit $?; }
# run <tag> <cmd...>: stdout to o/<tag>.out, stderr to o/<tag>.err, exit code in o/<tag>.rc
run() { local t=$1; shift; "$@" >"$T/o/$t.out" 2>"$T/o/$t.err"; echo $? >"$T/o/$t.rc"; { echo "[$t rc $(cat "$T/o/$t.rc")]"; cat "$T/o/$t.out" "$T/o/$t.err"; } >>"$T/o/last" 2>/dev/null; }
rc() { cat "$T/o/$1.rc" 2>/dev/null; }
J() { [ -s "$T/o/$1.out" ] && jq -e "${@:2}" "$T/o/$1.out" >/dev/null 2>&1; }   # <tag> <jq args and filter>: holds on the tag's JSON
jv() { jq -r "$2" "$T/o/$1.out" 2>/dev/null; }                                     # <tag> <filter>: a value of the tag's JSON
coded() { grep -qE "STL-${2:-[A-Z]+}-[0-9]{3}" "$T/o/$1.out" "$T/o/$1.err" 2>/dev/null; }   # <tag> [area]: the answer carries a catalog code
refused() { [ "$(rc "$1")" != 0 ] && [ "$(rc "$1")" != 2 ] && coded "$1" "${2:-}"; }        # <tag> [area]: a coded refusal, not a usage error
ed() { local f=$R/$1; [ -f "$f" ] || return 1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <file under the root> <jq args and filter>
G() { git -C "$1" -c core.hooksPath=/dev/null -c commit.gpgsign=false "${@:2}"; }
sha() { sha256sum "$1" | cut -c1-64; }

# ---- the data this harness reads (ids from data; empty when the data is not there yet: the precondition says so) ----
RT=$R/$(p routing); RA=$R/$(p role-assignments); PJ=$(p planner); PS=$(p planner-settings)
pj() { [ -n "$PJ" ] && jq -r "$@" "$R/$PJ" 2>/dev/null; }
PR=planner   # the planner role's id (design item A names it; no data row points at it from outside the role table)
RUBR=$(pj .rubric.extract_role)
LIGHT=$(pj '.rubric.thresholds[0].tier'); COMPLEX=$(pj '.rubric.thresholds[-1].tier')
BEH() { pj --arg t "$1" '.tiers[$t].behavior'; }
BR=$(jq -r '.builder_roles[0]' "$RT"); MEDIUM=$(jq -r '.task_tiers[1].id' "$RT"); SEL=$(jq -r .selection.global "$RA")
BPROF=$(jq -r --arg b "$BR" '[.profiles | to_entries[] | select(.value.role == $b) | .key][0]' "$RJ")   # a builder profile
P=pl-proj; Q=pl-other   # a project bound to the scratch repo, and one that never used the planner
CDIR=$R/$(ix .approval_store)

# ---- the scratch project repo, bound to the board in a scratch projects.db ----
MAINB=$(jq -r .main_branch "$RJ")
REPO=$T/repo; git init -q -b "$MAINB" "$REPO" && echo base >"$REPO/notes.txt" && G "$REPO" add -A && G "$REPO" commit -qm base
printf '#!/bin/sh\necho ran >>%s/hook-ran\n' "$T" >"$REPO/.git/hooks/pre-commit"; chmod +x "$REPO/.git/hooks/pre-commit"   # the engine commits with hooks off
git init -q -b "$MAINB" "$T/repo-q" && echo q >"$T/repo-q/notes.txt" && G "$T/repo-q" add -A && G "$T/repo-q" commit -qm base
python3 -I - "$PROJECTS_DB" "$BOARD" "$REPO" "$T/repo-q" "$P" "$Q" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("create table projects (id text, slug text, name text, board_slug text, primary_path text, archived int)")
c.execute("insert into projects values ('p_0000aaaa', ?, 'Planner project', ?, ?, 0)", (sys.argv[5], sys.argv[2], sys.argv[3]))
c.execute("insert into projects values ('p_0000bbbb', ?, 'Other project', ?, ?, 0)", (sys.argv[6], sys.argv[2], sys.argv[4]))
c.commit()
PY
card() {  # <card> <project> [assignee profile]: a ready board card of the project, assigned to a builder profile
  jq -nc --arg id "$1" --arg p "$2" --arg a "${3:-$BPROF}" '{task: {id: $id, assignee: $a, status: "ready", project: $p}, runs: [], events: []}' >"$T/cards/$1.json"; }
claim() {  # <tag> <card>: role-guard.py on the builder profile's kanban_claim of the card (exit 0 allowed, 2 refused)
  jq -nc --arg p "$BPROF" --arg c "$2" '{hook_event_name: "pre_tool_call", tool_name: "kanban_claim", tool_input: {task_id: $c}, profile: $p, extra: {}}' >"$T/o/$1.in"
  run "$1" python3 -I "$R/bin/role-guard.py" <"$T/o/$1.in"; }

# ---- the mock provider, a fake connection on it, the key, the probe records, the resolver wrapper ----
STELLA_ROOT=$MR python3 -I "$ROOT/bin/mock_provider.py" >"$T/mock.out" 2>"$T/mock.err" &
for i in $(seq 100); do [ -s "$T/mock.out" ] && break; sleep 0.1; done
PORT=$(jq -r '.port' "$T/mock.out" 2>/dev/null); CTL=$(jq -r '.control' "$T/mock.out" 2>/dev/null); LO=$(jq -r '.control | capture("//(?<h>[^:/]+):").h' "$T/mock.out" 2>/dev/null)
export NO_PROXY=$LO no_proxy=$LO
SHAPE0=$(jq -r '.entries[0].id' "$R/.stella/protocols.json")
KN=ST_FAKE_KEY; KEY="stkey$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
TPL='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "cloud" and (.aggregator | not))][0]'
mdl() { echo "{\"id\":\"$1\",\"capabilities\":{\"tool_calling\":true,\"json_mode\":true,\"context_tokens\":200000,\"vision\":true,\"streaming\":true},\"probed_at\":null,\"probe_source\":\"advertised\",\"cost\":null,\"limits\":null}"; }
ed .stella/connections.json --argjson m "[$(mdl st-a-plan),$(mdl st-a-rub)]" --arg g "$(cat /proc/sys/kernel/random/uuid)" --arg h "$LO" --argjson p "${PORT:-1}" --arg k "$KN" --arg s "$SHAPE0" \
  ".entries += [$TPL + {id: \"st-a\", label: \"st-a\", enabled: true, global_id: \$g, models: \$m, secrets: [\$k], hosts: [{host: \$h, port: \$p, purpose: \"selftest mock\"}], protocol: \$s}]"
IID=$(jq -r .install_id "$R/$(ix '.files[] | select(.schema == "install") | .path')")
PF=$R/$(ix .probe_records); mkdir -p "$(dirname "$PF")"
jq --arg i "$IID" --arg o "$(jq -r '.probe.output_shapes[-1]' "$RT")" \
  '{schema_version: 1, records: [.entries[] | select(.id | startswith("st-")) | .id as $c | .models[] | {global_id: "00000000-0000-4000-8000-000000000000", install_id: $i,
    connection: $c, model: .id, version: "st", probed_at: "2026-01-01T00:00:00Z", family: "st-fam", tool_calling: true, parallel_tool_calls: null, json: true, vision: true,
    output_shape: $o, context: {advertised: .capabilities.context_tokens, effective: .capabilities.context_tokens, short_score: 1, points: []}, code: null}]}' \
  "$R/.stella/connections.json" >"$PF"
ed .stella/protocols.json '.entries |= map(.request.path = "/" + .id + .request.path)'   # the mock serves each shape under its id
CD=$(ix .backup_dir)/st-keys; mkdir -p "$R/$CD"; chmod 700 "$R/$CD"; (umask 077; printf '%s' "$KEY" >"$R/$CD/$KN")
ed .stella/routing.json --arg p "$CD" '.credentials.backend = "st-dir" | .credentials.backends["st-dir"] = {kind: "dir", path: $p}'
mv "$R/bin/resolve.py" "$R/bin/resolve_real.py"
cat >"$R/bin/resolve.py" <<'P'
"""Selftest wrapper of the resolver: a role with a fixture <root>/chains/<role>.json gets that chain; every other call is the real one."""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import resolve_real as _r
from resolve_real import *  # noqa: F401,F403
_real = _r.resolve
def resolve(ctx, d=None):
    f = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "chains", f"{ctx.get('role')}.json")
    return json.load(open(f)) if os.path.isfile(f) else _real(ctx, d)
_r.resolve = resolve
def __getattr__(name):
    return getattr(_r, name)
if __name__ == "__main__":   # the real CLI's own ending: a refusal is one catalog line and exit 1
    try:
        sys.exit(_r.main(sys.argv[1:]))
    except _r.sd.DataError as e:
        _r.sd.say(getattr(e, "code", "STL-CFG-310"), str(e), alert=True); sys.exit(1)
    except Exception as e:
        _r.sd.say("STL-CFG-310", f"{type(e).__name__}, an unexpected failure of the resolver", alert=True); sys.exit(1)
P
LC=$(jq -r '.link_classes | sort_by(.privacy_rank) | .[1].id' "$RT")
fixchain() {  # <role> <model>: the role's chain is st-a/<model>, usable
  jq -n --arg m "$2" --arg cl "$LC" '{preset: {id: "fixture", source: "global"}, chain: [{connection: "st-a", model: $m, parameters: {}, link_class: $cl, source: "preset",
    status: "usable", code: null, reason: null, grant: null, mid_task: true, cooldown_until: null}], decision: {rule: "fixture", reason: "fixture"}, failure_history: [], stubs: []}' >"$R/chains/$1.json"; }
fixchain "$PR" st-a-plan; [ -n "$RUBR" ] && fixchain "$RUBR" st-a-rub
cat >"$T/http.py" <<'P'
import sys, urllib.request
o = urllib.request.build_opener(urllib.request.ProxyHandler({}))
sys.stdout.write(o.open(urllib.request.Request(sys.argv[1], data=open(sys.argv[2], "rb").read(), method="POST"), timeout=10).read().decode())
P
RUB_ANS='{}'; PLAN_ANS='x'
mock() {  # the mock serves both fixture models; the rubric model answers $RUB_ANS, the planner model $PLAN_ANS
  jq -n --arg s "$SHAPE0" --arg r "$RUB_ANS" --arg p "$PLAN_ANS" '{models: {($s): ["st-a-plan", "st-a-rub"]}, faults: [],
    traits: [{shape: $s, model: "st-a-rub", answers: [$r]}, {shape: $s, model: "st-a-plan", answers: [$p]}]}' >"$T/ctl.json"
  python3 -I "$T/http.py" "$CTL" "$T/ctl.json" >/dev/null 2>&1; }
rubric() {  # all|none: the rubric role's answer, every data feature true (scores the top tier) or false (scores the first)
  RUB_ANS=$(pj -c --arg v "$1" '[.rubric.features[].id | {(.): ($v == "all")}] | add + {reasoning: "fixture"}'); mock; }

# ---- the roadmap the planner model answers (design item D's fenced block; this fixture's ids: phases p1, p2 (p3); cards c1, c2, c3) ----
blink() { python3 -I "$R/bin/resolve.py" resolve --role "$BR" --project "$P" --card t_0b0000ff --json 2>/dev/null | jq -c '[.chain[]? | select(.status == "usable") | {connection, model}][0]' 2>/dev/null | grep . || echo '{"connection": "none", "model": "none"}'; }
C0=$(pj '.lint.comparators[0] // empty')   # threshold comparator and the project's budget cap, as bin/roadmap-selftest.sh reads them
CAP=$(jq -r --arg p "$P" '[.budgets[] | select(.scope == "project" and (.key == $p or .key == "*"))] | sort_by(.key == "*") | .[0].hard.amount // empty' "$R/$(p budgets)" 2>/dev/null)
roadmap() {  # <request file> <variant: base|phase|split|split2 (phases p1 and p2 split)|splitck (c1 split into cards of other checks)|edit> -> prints roadmap.md (its tier: RMTIER, default the top tier)
  local bl; bl=$(blink)
  jq -n --arg id "$(cat /proc/sys/kernel/random/uuid)" --arg iid "$IID" --arg p "$P" --rawfile rq "$1" --arg dg "$(sha "$1")" --arg tier "${RMTIER:-$COMPLEX}" \
    --arg pre "$SEL" --arg br "$BR" --arg qt "$MEDIUM" --argjson bl "$bl" --arg pr "$PR" --arg v "$2" --arg c0 "$C0" --argjson cap "${CAP:-0}" '
    def card(i; f; ch): {id: i, title: ("card " + i), kind: "code", files: f, size: {files: 1, changed_lines: 20, estimate_hours: 1},
      checks: ch, builder: ($bl + {rung: 0, reason: "fixture"})};
    def acc(i): {id: i, action: "run the game page check", observe: "the page answers within the limit, seconds", threshold: {comparator: $c0, value: 2}, owner_confirm: false, probe: null};
    {schema_version: 1, id: $id, install_id: $iid, project: $p, request: {text: $rq, digest: $dg}, tier: $tier, preset: $pre,
     phases: ([
      {id: "p1", title: "Guessing game core", goal: "the game logic", builds: ["guessing", "game"], depends_on: [], builder_role: $br, qa_tier: $qt, vm: "TBD",
       acceptance: [acc("a1"), acc("a2")],
       cards: ((if $v == "split" or $v == "split2" then [card("c1a"; ["a.txt"]; ["a1"]), card("c1b"; ["a.txt"]; ["a1"])]
         elif $v == "splitck" then [card("c1a"; ["a.txt"]; ["a1"]), card("c1b"; ["a.txt"]; ["a2"])] else [card("c1"; ["a.txt"]; ["a1"])] end) + [card("c2"; ["b.txt"]; ["a2"])])},
      {id: "p2", title: (if $v == "edit" then "Installer (owner edit)" else "Installer" end), goal: "install it", builds: ["installer"], depends_on: ["p1"],
       builder_role: $br, qa_tier: $qt, vm: "TBD", acceptance: [acc("a3")],
       cards: (if $v == "split2" then [card("c3a"; ["c.txt"]; ["a3"]), card("c3b"; ["c.txt"]; ["a3"])] else [card("c3"; ["c.txt"]; ["a3"])] end)}]
      + (if $v == "phase" then [{id: "p3", title: "Escalation point", goal: "a new phase", builds: ["escalation"], depends_on: ["p2"], builder_role: $br,
          qa_tier: $qt, vm: "TBD", acceptance: [acc("a4")], cards: [card("c4"; ["d.txt"]; ["a4"])]}] else [] end)),
     out_of_scope: ["other games"], estimate: {tokens: 1000, cost: ($cap / 10), hours: 3, budget_cap: ($cap / 2)},
     assignments: {($pr): {connection: "st-a", model: "st-a-plan"}, ($br): $bl}}' >"$T/rm.json"
  printf '# Roadmap\n\nA fixture roadmap.\n\n```json roadmap\n%s\n```\n' "$(cat "$T/rm.json")"; }
plan_answer() { PLAN_ANS=$(roadmap "$1" "$2"); mock; }   # <request file> <variant>

# ---- the planner's CLIs, the trusted lines ----
PLN() { python3 -I "$R/bin/planner.py" "$@"; }
RP() { python3 -I "$R/bin/replan.py" "$@"; }
proof() { python3 -I -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import event_log as e; print(json.dumps(e.proof_lines()))' "$R/bin" 2>/dev/null || echo '[]'; }
PAY='def pay: [., .detail, .new] | map(select(type == "object")) | add;'
lines() { proof | jq -c --arg t "$1" --arg k "$2" "$PAY"' [.[] | select(.type == $t and (tostring | contains($k))) | pay]'; }   # <type> <run or card id>: payloads
cnt() { lines "$1" "$2" | jq length; }
mkreq() { printf '%s' "$2" >"$T/$1.txt"; echo "$T/$1.txt"; }   # <name> <text>: a request file (its bytes are request.text, so their sha256 is request.digest)
SIMPLE=$(mkreq simple "Fix the typo in notes.txt: 'teh' should read 'the'.")
CPLX=$(mkreq complex "Build a number guessing game for the browser with a server, a score database and an installer for Windows.")
settings() { ed "$PS" "$@"; }   # <jq args and filter> on the planner owner settings (a scratch copy)
MKEY() { pj --arg k "$1" '.modes.ids[$k]'; }   # <force|rubric|skip>: the mode word the data gives
mform() { if pj -e --arg d "$(jq -r .defaults.mode "$R/$PS" 2>/dev/null)" '.modes.ids | has($d)' >/dev/null; then echo "$1"; else MKEY "$1"; fi; }   # the form the shipped settings use
isform() { [ -n "$2" ] && { [ "$2" = "$1" ] || [ "$2" = "$(MKEY "$1")" ]; }; }   # <mode key> <value>: the value names that mode, as key or word
route() { run "$1" PLN route --project "$P" --request "$2" --json "${@:3}"; RUN=$(jv "$1" '.run // empty'); }   # <tag> <request file> [more]
gstat() { PLN gate status --run "$1" --json 2>>"$T/o/last" | jq -r '.status // empty' 2>/dev/null; }
mays() { run "$1" PLN may-start --run "$2" --card "$3" --json; }   # <tag> <run> <card>

# ---- the test approver (bin/approvals-selftest.sh t1a): a stub owner channel, the owner's answer collected from it ----
CH=$R/$(ix '.files[] | select(.id == "channels") | .path'); CHLK=$(ix '.files[] | select(.id == "channels") | .list_key // "entries"')
cat >"$T/adapter.sh" <<S
#!/usr/bin/env bash
d=$T/ans; c=\$2
case \$1 in
  deliver) n=\$(( \$(cat "\$d/\$c.n" 2>/dev/null || echo 0) + 1 )); echo \$n >"\$d/\$c.n"; cat >"\$d/\$c.req.\$n"; echo "m-\$c-\$n" >"\$d/\$c.lastref"; echo "m-\$c-\$n";;
  collect) [ -f "\$d/\$c.in" ] && cat "\$d/\$c.in"; : >"\$d/\$c.in";;
  *) exit 2;;
esac
S
printf '#!/usr/bin/env bash\ncat >/dev/null\n' >"$T/resume.sh"; chmod +x "$T/adapter.sh" "$T/resume.sh"
jq --arg a "$T/adapter.sh" --arg r "$T/resume.sh" --arg g "$(cat /proc/sys/kernel/random/uuid)" --arg i "$IID" --arg lk "$CHLK" \
  '.[$lk] = ([.[$lk][]? | select(.kind != "discord")] + [{id: "zz-owner", kind: "discord", deliver: [$a, "deliver", "zz-owner"], collect: [$a, "collect", "zz-owner"],
    enabled: true, global_id: $g, install_id: $i}]) | .resume = {argv: [$r], timeout_s: 10}' "$CH" >"$T/ch.new" && cat "$T/ch.new" >"$CH"
decide() {  # <request id> <approved|denied>: the owner's answer to the request through the test approver
  local q=$CDIR/requests/$1.json ref
  [ -n "$1" ] && [ -f "$q" ] || { echo "no stored approval request '$1'" >>"$T/o/last"; return 1; }
  python3 -I "$R/bin/approvals.py" deliver "$1" --channel zz-owner >>"$T/o/last" 2>&1; ref=$(cat "$T/ans/zz-owner.lastref" 2>/dev/null)
  jq -nc --arg r "$1" --arg n "$(jq -r .nonce "$q")" --arg d "$2" --arg u "$OWNER_ID" --arg m "$ref" --arg g "$(jq -r .digest "$q")" \
    '{request_id: $r, nonce: $n, decision: $d, user: $u, message_ref: $m, digest: $g}' >>"$T/ans/zz-owner.in"
  python3 -I "$R/bin/approvals.py" collect --channel zz-owner >>"$T/o/last" 2>&1; }
astat() { python3 -I "$R/bin/approvals.py" status "$1" --json 2>/dev/null | jq -r '.status // empty'; }

# a complex run up to its gate: route (top tier), plan, submit; sets RUN, V1 (its version) and GREQ (the gate's request)
to_gate() {  # <tag> [variant]
  rubric all; plan_answer "$CPLX" "${2:-base}"; route "$1-r" "$CPLX"
  run "$1-p" PLN plan --run "$RUN" --json; run "$1-s" PLN submit --run "$RUN" --json
  V1=$(jv "$1-s" '.version // empty'); GREQ=$(jv "$1-s" '.request // empty'); }
bind() { run "bind-$2" PLN bind --run "$1" --card "$2" --roadmap-card "$3" --json; }   # <run> <board card> <roadmap card>

# the harness itself works on this tree: the mock answers a planner-role call through the wrapper, and the test approver decides a request
harness_ok() {
  PLAN_ANS=fixture-answer-9q; mock; printf 'say ok' | timeout 60 python3 -I "$R/bin/route.py" call --role "$PR" --project "$P" --task pre-1 --json >"$T/o/pre.out" 2>"$T/o/pre.err"
  jq -e '.text | tostring | contains("fixture-answer-9q")' "$T/o/pre.out" >/dev/null || return 1
  jq -nc '{op: "set", target: "settings:CALL_TIMEOUT", old_digest: ("0" * 64), new_digest: ("1" * 64)}' >"$T/act-pre.json"
  local id; id=$(python3 -I "$R/bin/approvals.py" request --class write --action "$T/act-pre.json" --summary "harness check" --card card-pre --ttl 600 --json 2>/dev/null | jq -r '.id // empty')
  decide "$id" approved && [ "$(astat "$id")" = approved ]; }
