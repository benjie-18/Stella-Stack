#!/usr/bin/env bash
# Hermetic self-test for the capabilities core (F3 item C; body B4, AC4; design section 4 with ruling DC-05).
# Every section runs in its own scratch root (bash capabilities-selftest.sh <section>); no argument runs them all.
# Sections -> checks: found = AC4-found | requestable = AC4-requestable | invisible = AC4-invisible | request = AC4-request-approval |
#                     unknown = AC4-unknown | sources = T-SOURCES-UNKNOWN
# A fake skill is added to the scratch registry as DATA (a SKILL.md in a skill folder and a registry entry); three roles are taken
# from the role table: one in allowed_roles, one in requestable_roles, one in neither.
# Written test-first (F3 wave 1): exit codes, the code range STL-GRD-660..674 and the trusted event log are asserted, never wording.
# ASSUMPTIONS (names the design leaves open):
#  A1 search/describe/request/load --json print JSON; an entry shown to a role is a JSON object with id = the capability id, and its
#     visibility is a value "available" or "requestable" somewhere in that object; a requestable one also holds its approval class.
#  A2 the skill folders and MCP manifests are the strings under the data index key capability_sources (any shape); the skill folder
#     is the first of them that is not a .json file and not under .stella/extensions (fallback .claude/skills); the MCP manifest is
#     the first that ends .mcp.json (fallback the repo .mcp.json).
#  A3 request opens an approval through bin/approvals.py: a trusted event line of type approval-request (event_log) naming the card.
#  A4 the alert for an unregistered skill names it in the alert line (alerts.log under ESCALATE_SUP_DIR).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=capabilities-selftest
SECTIONS="found requestable invisible request unknown sources"
if [ $# = 0 ]; then
  f=0; for s in $SECTIONS; do bash "${BASH_SOURCE[0]}" "$s" || f=$((f+1)); done
  [ $f = 0 ] && echo "$ME PASS" || echo "$ME FAIL ($f sections)"; [ $f = 0 ]; exit
fi
case " $SECTIONS " in *" $1 "*) ;; *) echo "usage: $ME.sh [$(tr ' ' '|' <<<"$SECTIONS")]" >&2; exit 2;; esac
S=$1
# ---- harness: a scratch root of its own (bin, .stella, docs and the root config files copied), its own HOME, temp, alert folder ----
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
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
POL=$R/$(ix '.files[] | select(.id == "owner-auth") | .path')
for v in $(jq -r '.worker_signals.token_env[]?' "$POL" 2>/dev/null); do unset "$v"; done
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH
AL=$T/sup/logs/alerts.log; : >"$AL"
EV=$R/$(ix .event_log)
IID=$(jq -r .install_id "$R/.stella/install.json")
fails=0; n=0
# ok <test> <label>: a FAIL line (never a crash) with the last output of the case under it
ok() { n=$((n+1)); if ( set -o pipefail; eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/o/last" ] && tail -n 3 "$T/o/last" | cut -c1-240 | sed 's/^/     | /'; fi; : >"$T/o/last"; }
finish() { echo "# $ME $S: $n cases, $fails failed"; [ "$fails" = 0 ]; exit $?; }
# run <tag> <cmd...>: stdout to $T/o/<tag>.out, stderr to $T/o/<tag>.err, exit code in RC
run() { local t=$1; shift; "$@" >"$T/o/$t.out" 2>"$T/o/$t.err"; RC=$?; cat "$T/o/$t.out" "$T/o/$t.err" >"$T/o/last" 2>/dev/null; }
out() { cat "$T/o/$1.out" "$T/o/$1.err" 2>/dev/null; }
ed() { local f=$R/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <file under the root> <jq args and filter>
uuid() { cat /proc/sys/kernel/random/uuid; }
nl() { if [ -f "$1" ]; then wc -l <"$1"; else echo 0; fi; }   # line count of a file that may not exist yet
WORKER() { env STUB_WORKER_MARK=1 "$@"; }   # a worker environment (a roles.json worker marker)

C() { python3 -I "$R/bin/capabilities.py" "$@"; }
range='STL-GRD-6(6[0-9]|7[0-4])'
mapfile -t RL < <(jq -r '.roles | keys[]' "$RJ"); RA=${RL[0]}; RQ=${RL[1]}; RH=${RL[2]}   # allowed, requestable, hidden
ACLASS=$(jq -r '[.. | objects | select(has("approval_class")) | .approval_class.enum[]?] | map(select(. != "read"))[0] // empty' "$R/.stella/schemas/approval-request.schema.json")   # an approval class (the approval-request schema's enum), not the skill's own risk class
SRC=$(ix '[.capability_sources // empty | .. | strings]')
SK=$(jq -r '[.[] | select((endswith(".json") or startswith(".stella/extensions")) | not)][0] // ".claude/skills"' <<<"${SRC:-[]}")
MCPF=$(jq -r '[.[] | select(endswith(".mcp.json"))][0] // ".mcp.json"' <<<"${SRC:-[]}")
mkdir -p "$R/$SK/qa-fake-skill"
printf -- '---\nname: qa-fake-skill\ndescription: qazebra fake skill for the capabilities selftest\n---\nQA-SKILL-BODY use the zebra.\n' >"$R/$SK/qa-fake-skill/SKILL.md"
ed .stella/capabilities.json --arg s "$SK/qa-fake-skill/SKILL.md" --arg a "$RA" --arg q "$RQ" --arg c "$ACLASS" --arg g "$(uuid)" --arg i "$IID" \
  '.entries += [{id: "qa-fake-skill", kind: "skill", summary: "qazebra fake skill for the capabilities selftest", keywords: ["qazebra"], inputs: "none", outputs: "text",
    allowed_roles: [$a], requestable_roles: [$q], request_approval: $c, risk_class: "read", hosts: [], secrets: [], status: "approved", source: $s,
    triage: {result: "shipped"}, definition: {text: "QA-SKILL-DEF"}, global_id: $g, install_id: $i}]'
ok 'python3 -I "$R/bin/stella_data.py" check' "precondition: the scratch registry with the fake skill (requestable_roles, request_approval, definition) passes check"
# shown <tag> <id>: the object with that id in the JSON output, compact (empty when absent)
shown() { jq -c --arg id "$2" '[.. | objects | select(.id == $id)][0] // empty' "$T/o/$1.out" 2>/dev/null; }
vis() { local s; s=$(shown "$1" "$2"); [ -n "$s" ] && jq -e --arg v "$3" '[.. | strings] | index($v) != null' <<<"$s" >/dev/null; }

case $S in
found)   # AC4-found
  run s1 C search qazebra --role "$RA" --json
  ok '[ $RC = 0 ] && vis s1 qa-fake-skill available' "AC4-found search by keyword: role $RA (in allowed_roles) sees the fake skill as available"
  run s2 C search "fake skill" --role "$RA" --json
  ok '[ $RC = 0 ] && [ -n "$(shown s2 qa-fake-skill)" ]' "AC4-found search by summary words finds it too"
  run d1 C describe qa-fake-skill --role "$RA" --json
  ok '[ $RC = 0 ] && grep -q qazebra "$T/o/d1.out"' "AC4-found describe returns the entry to the allowed role"
  run w1 WORKER python3 -I "$R/bin/capabilities.py" search qazebra --role "$RA" --json
  ok '[ $RC != 0 ] && ! grep -q qa-fake-skill "$T/o/w1.out" && out w1 | grep -qE "STL-(CFG-312|GRD-6(6[0-9]|7[0-4]))"' "AC4-found DC-05: in a worker environment --role is refused (no local answer)"
  ;;
requestable)   # AC4-requestable
  run s1 C search qazebra --role "$RQ" --json
  ok '[ $RC = 0 ] && vis s1 qa-fake-skill requestable' "AC4-requestable role $RQ (in requestable_roles) sees the fake skill as requestable"
  ok 'vis s1 qa-fake-skill "$ACLASS"' "AC4-requestable ... with the approval class it needs ($ACLASS)"
  ok '! vis s1 qa-fake-skill available' "AC4-requestable ... and not as available"
  ;;
invisible)   # AC4-invisible
  run s1 C search qazebra --role "$RH" --json
  ok '[ $RC = 0 ] && ! grep -q qa-fake-skill "$T/o/s1.out"' "AC4-invisible role $RH (neither list): search does not show it"
  run s2 C search qa-fake-skill --role "$RH" --json
  ok '[ $RC = 0 ] && ! grep -q qa-fake-skill "$T/o/s2.out"' "AC4-invisible ... not even searched by its exact id"
  run d1 C describe qa-fake-skill --role "$RH" --json; r1=$RC
  run d2 C describe qa-no-such-capability --role "$RH" --json; r2=$RC
  ok '[ $r1 = 1 ] && [ $r2 = 1 ] && [ "$(out d1 | sed s/qa-fake-skill/ID/g)" = "$(out d2 | sed s/qa-no-such-capability/ID/g)" ]' "AC4-invisible describe of the hidden id answers exactly like an unknown id (exit 1, same output)"
  run q1 C request qa-fake-skill --reason "qa wants it" --role "$RH" --card qa-card-h --json
  ok '[ $RC = 1 ] && out q1 | grep -qE "$range"' "AC4-invisible request of the hidden id fails closed like an unknown id"
  ;;
request)   # AC4-request-approval
  e0=$(nl "$EV")
  run q1 C request qa-fake-skill --reason "qa needs the zebra" --role "$RQ" --card qa-card-7 --json
  ok '[ $RC = 0 ]' "AC4-request-approval role $RQ requests the fake skill (exit 0)"
  ok 'tail -n +$((e0 + 1)) "$EV" | jq -c "select(.type == \"approval-request\")" | grep -q qa-card-7' "AC4-request-approval a trusted approval-request line naming the card is in the event log"
  e1=$(nl "$EV")
  run q2 C request qa-fake-skill --reason "already mine" --role "$RA" --card qa-card-8 --json
  run q3 C request qa-fake-skill --reason "never mine" --role "$RH" --card qa-card-9 --json
  ok '[ $RC = 1 ] && ! tail -n +$((e1 + 1)) "$EV" | grep -q qa-card-9' "AC4-request-approval a role that may never use it opens no approval"
  ;;
unknown)   # AC4-unknown
  for v in describe load request; do
    case $v in describe) a=();; load) a=(--run qa-run-1);; request) a=(--reason x --card qa-card-u);; esac
    run "u-$v" C "$v" qa-no-such-capability --role "$RA" "${a[@]}" --json
    ok '[ $RC = 1 ] && out "u-$v" | grep -qE "$range"' "AC4-unknown $v of an unknown id: exit 1 with STL-GRD-66x"
  done
  run u-s C search qa-no-such-capability-words --role "$RA" --json
  ok '[ $RC = 0 ] && ! grep -q qa-no-such "$T/o/u-s.out"' "AC4-unknown a search with no match is an empty answer, not an error"
  run u-r C search qazebra --role qa-no-such-role --json
  ok '[ $RC != 0 ] && ! grep -q qa-fake-skill "$T/o/u-r.out" && out u-r | grep -qE "STL-[A-Z]+-[0-9]{3}"' "AC4-unknown an unknown role sees nothing (fails closed with a code)"
  ;;
sources)   # T-SOURCES-UNKNOWN
  mkdir -p "$R/$SK/qa-unreg-skill"
  printf -- '---\nname: qa-unreg-skill\ndescription: qazebra unregistered skill\n---\nbody\n' >"$R/$SK/qa-unreg-skill/SKILL.md"
  run s1 C search qa-unreg-skill --role "$RA" --json
  ok '[ $RC = 0 ] && ! grep -q qa-unreg-skill "$T/o/s1.out"' "T-SOURCES-UNKNOWN a SKILL.md with no registry entry is hidden from search"
  bad=; for r in "${RL[@]}"; do run "s-$r" C search qazebra --role "$r" --json; { [ $RC = 0 ] && ! grep -q qa-unreg-skill "$T/o/s-$r.out"; } || bad="$bad $r"; done
  ok '[ -z "$bad" ]' "T-SOURCES-UNKNOWN ... from every role (search answers, never shows it; failed:$bad)"
  run d1 C describe qa-unreg-skill --role "$RA" --json
  ok '[ $RC = 1 ] && out d1 | grep -qE "$range"' "T-SOURCES-UNKNOWN describe of it fails closed like an unknown id"
  : >"$AL"; run s2 C search qazebra --role "$RA" --json
  ok '[ "$(grep -c qa-unreg-skill "$AL")" = 1 ] && grep qa-unreg-skill "$AL" | grep -qE "$range"' "T-SOURCES-UNKNOWN one search raises exactly one alert naming it, with STL-GRD-66x"
  [ -f "$R/$MCPF" ] || echo '{"mcpServers": {}}' >"$R/$MCPF"
  ed "$MCPF" '.mcpServers["qa-unreg-server"] = {command: "true", args: []}'
  run s3 C search qa-unreg-server --role "$RA" --json
  ok '[ $RC = 0 ] && ! grep -q qa-unreg-server "$T/o/s3.out"' "T-SOURCES-UNKNOWN an MCP server in a manifest with no registry entry is hidden"
  ok 'grep -q qa-unreg-server "$AL"' "T-SOURCES-UNKNOWN ... and raises an alert naming it"
  ;;
esac
finish
