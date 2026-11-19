#!/usr/bin/env bash
# Hermetic self-test for the capabilities core (F3 item C; body B4, AC4; design section 4 with ruling DC-05).
# Every section runs in its own scratch root (bash capabilities-selftest.sh <section>); no argument runs them all.
# Sections -> checks: found = AC4-found | requestable = AC4-requestable | invisible = AC4-invisible | request = AC4-request-approval |
#                     unknown = AC4-unknown | sources = T-SOURCES-UNKNOWN | gaps = item C round 2 (B4 role toolsets, outside install
#                     escalation, host_session through bin/host_access.py decide; the builder's own cases) |
#                     registry = T-REGISTRY-COMPLETE (F3 item R, tests first) |
#                     cfix = Gate B fix cycle 2 (builder's own cases: V1-07 V1-13 RT2-01 03 04 05 07 09; each fails on the tree before the fix)
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
#  A5 (item R) the registry lint is `capabilities.py lint [--json]`: exit 0 when complete, exit 1 naming each unregistered one with
#     STL-CFG-340..344. A command is registered when an entry's source is its path (bin/x, bin/adapters/x; the registry's convention);
#     a skill or MCP server when an entry's id is its name (as search finds them). "Executable" = the file's user x bit; a selftest is a
#     file whose name holds "selftest" (the suite runner included).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=capabilities-selftest
SECTIONS="found requestable invisible request unknown sources gaps registry cfix"
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
  ok '[ $RC != 0 ] && ! grep -q qa-fake-skill "$T/o/w1.out" && out w1 | grep >/dev/null -E "STL-(CFG-312|GRD-6(6[0-9]|7[0-4]))"' "AC4-found DC-05: in a worker environment --role is refused (no local answer)"
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
  ok '[ $RC = 1 ] && out q1 | grep >/dev/null -E "$range"' "AC4-invisible request of the hidden id fails closed like an unknown id"
  ;;
request)   # AC4-request-approval
  e0=$(nl "$EV")
  run q1 C request qa-fake-skill --reason "qa needs the zebra" --role "$RQ" --card qa-card-7 --json
  ok '[ $RC = 0 ]' "AC4-request-approval role $RQ requests the fake skill (exit 0)"
  ok 'tail -n +$((e0 + 1)) "$EV" | jq -c "select(.type == \"approval-request\")" | grep >/dev/null qa-card-7' "AC4-request-approval a trusted approval-request line naming the card is in the event log"
  e1=$(nl "$EV")
  run q2 C request qa-fake-skill --reason "already mine" --role "$RA" --card qa-card-8 --json
  run q3 C request qa-fake-skill --reason "never mine" --role "$RH" --card qa-card-9 --json
  ok '[ $RC = 1 ] && ! tail -n +$((e1 + 1)) "$EV" | grep >/dev/null qa-card-9' "AC4-request-approval a role that may never use it opens no approval"
  ;;
unknown)   # AC4-unknown
  for v in describe load request; do
    case $v in describe) a=();; load) a=(--run qa-run-1);; request) a=(--reason x --card qa-card-u);; esac
    run "u-$v" C "$v" qa-no-such-capability --role "$RA" "${a[@]}" --json
    ok '[ $RC = 1 ] && out "u-$v" | grep >/dev/null -E "$range"' "AC4-unknown $v of an unknown id: exit 1 with STL-GRD-66x"
  done
  run u-s C search qa-no-such-capability-words --role "$RA" --json
  ok '[ $RC = 0 ] && ! grep -q qa-no-such "$T/o/u-s.out"' "AC4-unknown a search with no match is an empty answer, not an error"
  run u-r C search qazebra --role qa-no-such-role --json
  ok '[ $RC != 0 ] && ! grep -q qa-fake-skill "$T/o/u-r.out" && out u-r | grep >/dev/null -E "STL-[A-Z]+-[0-9]{3}"' "AC4-unknown an unknown role sees nothing (fails closed with a code)"
  ;;
sources)   # T-SOURCES-UNKNOWN
  mkdir -p "$R/$SK/qa-unreg-skill"
  printf -- '---\nname: qa-unreg-skill\ndescription: qazebra unregistered skill\n---\nbody\n' >"$R/$SK/qa-unreg-skill/SKILL.md"
  run s1 C search qa-unreg-skill --role "$RA" --json
  ok '[ $RC = 0 ] && ! grep -q qa-unreg-skill "$T/o/s1.out"' "T-SOURCES-UNKNOWN a SKILL.md with no registry entry is hidden from search"
  bad=; for r in "${RL[@]}"; do run "s-$r" C search qazebra --role "$r" --json; { [ $RC = 0 ] && ! grep -q qa-unreg-skill "$T/o/s-$r.out"; } || bad="$bad $r"; done
  ok '[ -z "$bad" ]' "T-SOURCES-UNKNOWN ... from every role (search answers, never shows it; failed:$bad)"
  run d1 C describe qa-unreg-skill --role "$RA" --json
  ok '[ $RC = 1 ] && out d1 | grep >/dev/null -E "$range"' "T-SOURCES-UNKNOWN describe of it fails closed like an unknown id"
  : >"$AL"; run s2 C search qazebra --role "$RA" --json
  ok '[ "$(grep -c qa-unreg-skill "$AL")" = 1 ] && grep qa-unreg-skill "$AL" | grep >/dev/null -E "$range"' "T-SOURCES-UNKNOWN one search raises exactly one alert naming it, with STL-GRD-66x"
  [ -f "$R/$MCPF" ] || echo '{"mcpServers": {}}' >"$R/$MCPF"
  ed "$MCPF" '.mcpServers["qa-unreg-server"] = {command: "true", args: []}'
  run s3 C search qa-unreg-server --role "$RA" --json
  ok '[ $RC = 0 ] && ! grep -q qa-unreg-server "$T/o/s3.out"' "T-SOURCES-UNKNOWN an MCP server in a manifest with no registry entry is hidden"
  ok 'grep -q qa-unreg-server "$AL"' "T-SOURCES-UNKNOWN ... and raises an alert naming it"
  ;;
gaps)   # item C round 2: three gaps of B4
  # (1) a role's own platform toolset is searchable by that role only
  ed "$(ix .role_table)" --arg r "$RA" '.roles[$r].platform_toolsets = {cli: ["qa-toolset"]}'
  run t1 C search qa-toolset --role "$RA" --json
  ok '[ $RC = 0 ] && vis t1 qa-toolset available' "gap1 role $RA sees its own toolset as available"
  run t2 C describe qa-toolset --role "$RA" --json
  ok '[ $RC = 0 ] && grep -q qa-toolset "$T/o/t2.out"' "gap1 describe of its own toolset works"
  bad=; for r in "${RL[@]}"; do [ "$r" = "$RA" ] && continue; run "t-$r" C search qa-toolset --role "$r" --json; { [ $RC = 0 ] && ! grep -q qa-toolset "$T/o/t-$r.out"; } || bad="$bad $r"; done
  ok '[ -z "$bad" ]' "gap1 no other role is shown it (failed:$bad)"
  run t3 C describe qa-toolset --role "$RH" --json
  ok '[ $RC = 1 ] && out t3 | grep >/dev/null -E "$range"' "gap1 another role's describe fails closed like an unknown id"
  # (2) an outside install (entry not approved) is requestable and becomes one approval request, never an install
  ed .stella/capabilities.json --arg a "$RA" --arg q "$RQ" --arg c "$ACLASS" --arg g "$(uuid)" --arg i "$IID" \
    '.entries += [{id: "qa-outside-server", kind: "mcp_server", summary: "qaoutside server not installed", keywords: ["qaoutside"], inputs: "none", outputs: "text",
      allowed_roles: [$a], requestable_roles: [$q], request_approval: $c, risk_class: "read", hosts: [], secrets: [], status: "proposed", source: ".mcp.json",
      triage: {result: "pending"}, definition: {text: "QA-OUTSIDE-DEF"}, global_id: $g, install_id: $i}]'
  run o1 C search qaoutside --role "$RQ" --json
  ok '[ $RC = 0 ] && vis o1 qa-outside-server requestable && jq -e ".[0].install == true" "$T/o/o1.out"' "gap2 the requesting role sees the outside server as requestable (an install)"
  run o2 C search qaoutside --role "$RA" --json
  ok '[ $RC = 0 ] && ! grep -q qa-outside-server "$T/o/o2.out"' "gap2 allowed_roles does not make a not-approved entry usable or shown"
  run o3 C load qa-outside-server --role "$RA" --run qa-run-2 --json
  ok '[ $RC = 1 ] && ! grep -q QA-OUTSIDE-DEF "$T/o/o3.out"' "gap2 load of the not-installed entry is refused"
  e0=$(nl "$EV"); run o4 C request qa-outside-server --reason "need it" --role "$RQ" --card qa-card-o --json
  ok '[ $RC = 0 ] && tail -n +$((e0 + 1)) "$EV" | jq -c "select(.type == \"approval-request\")" | grep >/dev/null qa-card-o' "gap2 the install request is one trusted approval-request line naming the card"
  ok '[ "$(tail -n +$((e0 + 1)) "$EV" | grep -c qa-card-o)" = 1 ] && [ ! -e "$R/$SK/qa-outside-server" ] && ! grep -q qa-outside-server "$R/$MCPF"' "gap2 exactly one line, and nothing installed (no skill folder, no manifest entry)"
  e1=$(nl "$EV"); run o5 C request qa-outside-server --reason "no" --role "$RH" --card qa-card-p --json
  ok '[ $RC = 1 ] && [ "$(nl "$EV")" = "$e1" ]' "gap2 a role that may not request it opens nothing"
  # (3) host_session / input_source: available only when bin/host_access.py decide allows (a test double of decide, in the scratch root)
  cat >"$R/bin/host_access.py" <<'PY'
import json, os
def decide(q):
    json.dump(q, open(os.environ["QA_HOST_SEEN"], "w"))
    if not os.path.exists(os.environ["QA_HOST_ALLOW"]):
        raise Exception("refused")
    return {"allowed": True}
PY
  export QA_HOST_SEEN=$T/seen.json QA_HOST_ALLOW=$T/allow
  for k in host_session input_source; do
    ed .stella/capabilities.json --arg a "$RA" --arg k "$k" --arg g "$(uuid)" --arg i "$IID" \
      '.entries += [{id: ("qa-" + $k), kind: "tool", summary: "qahost fake host capability", keywords: ["qahost"], inputs: "none", outputs: "text",
        allowed_roles: [$a], risk_class: $k, hosts: [], secrets: [], status: "approved", source: "qa",
        triage: {result: "shipped"}, definition: {text: "QA-HOST-DEF"}, global_id: $g, install_id: $i}]'
  done
  printf '%s\n' '{"target": {"app": "qa-app", "domain": null}, "action": {"type": "qa-open"}, "confirmation": null}' >"$T/hreq.json"
  run h1 C search qahost --role "$RA" --run qa-run-3 --json
  ok '[ $RC = 0 ] && vis h1 qa-host_session gated && vis h1 qa-input_source gated && [ ! -e "$QA_HOST_SEEN" ]' "gap3 with no host request: gated, decide is not called"
  run h2 C search qahost --role "$RA" --run qa-run-3 --host-request "$T/hreq.json" --json
  ok '[ $RC = 0 ] && vis h2 qa-host_session gated && [ -e "$QA_HOST_SEEN" ]' "gap3 decide refuses: still gated"
  run h3 C load qa-host_session --role "$RA" --run qa-run-3 --host-request "$T/hreq.json" --json
  ok '[ $RC = 1 ] && ! grep -q QA-HOST-DEF "$T/o/h3.out"' "gap3 ... and load is refused"
  touch "$QA_HOST_ALLOW"; rm -f "$QA_HOST_SEEN"
  run h4 C search qahost --role "$RA" --run qa-run-3 --host-request "$T/hreq.json" --json
  ok '[ $RC = 0 ] && vis h4 qa-host_session available && vis h4 qa-input_source available' "gap3 decide allows: available"
  ok 'jq -e ".role == \"$RA\" and .run == \"qa-run-3\" and .target.app == \"qa-app\" and .action.type == \"qa-open\" and (keys | length) == 6" "$QA_HOST_SEEN"' "gap3 decide got the caller's own facts only: capability, role, run, target, action, confirmation"
  e0=$(nl "$EV"); run h5 C load qa-host_session --role "$RA" --run qa-run-3 --host-request "$T/hreq.json" --json
  ok '[ $RC = 0 ] && grep -q QA-HOST-DEF "$T/o/h5.out" && tail -n +$((e0 + 1)) "$EV" | grep >/dev/null qa-host_session' "gap3 load works once decide allowed it, with its trusted line"
  run h6 C search qahost --role "$RH" --run qa-run-3 --host-request "$T/hreq.json" --json
  ok '[ $RC = 0 ] && ! grep -q qa-host "$T/o/h6.out"' "gap3 a role outside allowed_roles never sees it, whatever decide says"
  run h7 C search qahost --role "$RA" --run qa-run-3 --host-request "$T/no-such.json" --json
  ok '[ $RC = 1 ] && out h7 | grep >/dev/null -E "$range"' "gap3 an unreadable host request file fails closed with a code"
  # (R) the lint is the tester's (registry section); only the worker refusal is added here
  run c5 WORKER python3 -I "$R/bin/capabilities.py" lint --json
  ok '[ $RC != 0 ] && out c5 | grep >/dev/null -E "STL-(CFG-312|GRD-662)"' "R-lint is refused in a worker environment (host command)"
  ;;
registry)   # T-REGISTRY-COMPLETE
  # the expected set, computed here from the tree (not from the lint): non-selftest executables under bin/ and bin/adapters/, every skill
  # folder and every MCP server the capability sources name; each needs a registry entry (A5)
  CAPF=$R/$(ix '.files[] | select(.id == "capabilities") | .path'); SRCF=$R/$(ix .capability_sources)
  unreg() { local f n m
    ( cd "$R" && find bin bin/adapters -maxdepth 1 -type f -perm -u+x ! -name '*selftest*' 2>/dev/null | sort -u ) | while read -r f; do
      jq -e --arg s "$f" '[.entries[] | select(.source == $s)] | length > 0' "$CAPF" >/dev/null || echo "$f"; done
    for d in $(jq -r '.skill_folders[]' "$SRCF"); do for f in "$R/$d"/*/SKILL.md; do [ -f "$f" ] || continue
      n=$(sed -n '2,/^---/s/^name:[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p' "$f" | head -1); n=${n:-$(basename "$(dirname "$f")")}
      jq -e --arg s "$n" '[.entries[] | select(.id == $s)] | length > 0' "$CAPF" >/dev/null || echo "skill $n"; done; done
    for m in $(jq -r '.mcp_manifests[]' "$SRCF"); do [ -f "$R/$m" ] || continue; for n in $(jq -r '.mcpServers // {} | keys[]' "$R/$m"); do
      jq -e --arg s "$n" '[.entries[] | select(.id == $s)] | length > 0' "$CAPF" >/dev/null || echo "mcp $n"; done; done; }
  ok '[ -s "$CAPF" ] && [ -s "$SRCF" ]' "T-REGISTRY-COMPLETE precondition: the registry and the capability sources are named by the index"
  miss=$(unreg); nmiss=$(grep -c . <<<"$miss"); miss=$(tr '\n' ' ' <<<"$miss")
  ok '[ -s "$CAPF" ] && [ -z "${miss// /}" ]' "T-REGISTRY-COMPLETE every non-selftest bin/ and bin/adapters/ executable, skill folder and MCP server has a registry entry ($nmiss missing: $(cut -c1-300 <<<"$miss"))"
  L() { python3 -I "$R/bin/capabilities.py" lint --json; }
  lint_fails() { [ $RC = 1 ] && out "$1" | grep >/dev/null -F -- "$2" && out "$1" | grep >/dev/null -E 'STL-CFG-34[0-4]'; }
  run l0 L
  ok '[ $RC = 0 ] && ! out l0 | grep >/dev/null -E "STL-CFG-34[0-4]"' "T-REGISTRY-COMPLETE lint on the complete tree: exit 0, no STL-CFG-340..344"
  printf '#!/usr/bin/env bash\ntrue\n' >"$R/bin/qa-unreg-cmd.sh"; chmod +x "$R/bin/qa-unreg-cmd.sh"
  run l1 L
  ok 'lint_fails l1 qa-unreg-cmd' "T-REGISTRY-COMPLETE a planted unregistered command in bin/: lint exit 1 naming it with STL-CFG-340..344"
  ed .stella/capabilities.json --arg g "$(uuid)" --arg i "$IID" --arg a "$RA" '.entries += [{id: "qa-unreg-cmd", kind: "command", summary: "qa planted command", keywords: ["qa"],
    inputs: "none", outputs: "text", allowed_roles: [$a], risk_class: "read", hosts: [], secrets: [], status: "approved", source: "bin/qa-unreg-cmd.sh",
    triage: {result: "shipped"}, definition: {text: "QA"}, global_id: $g, install_id: $i}]'
  run l2 L
  ok '[ $RC = 0 ]' "T-REGISTRY-COMPLETE ... the same command once registered (an entry whose source is its path): lint exit 0"
  mkdir -p "$R/bin/adapters"; printf '#!/usr/bin/env bash\ntrue\n' >"$R/bin/adapters/qa-unreg-adapter.sh"; chmod +x "$R/bin/adapters/qa-unreg-adapter.sh"
  run l3 L
  ok 'lint_fails l3 qa-unreg-adapter' "T-REGISTRY-COMPLETE a planted unregistered command in bin/adapters/: lint exit 1 naming it with STL-CFG-340..344"
  rm -f "$R/bin/adapters/qa-unreg-adapter.sh"
  printf '#!/usr/bin/env bash\ntrue\n' >"$R/bin/qa-lint-selftest.sh"; chmod +x "$R/bin/qa-lint-selftest.sh"
  run l4 L
  ok '[ $RC = 0 ]' "T-REGISTRY-COMPLETE a selftest needs no entry: an unregistered bin/*-selftest.sh leaves the lint at exit 0"
  rm -f "$R/bin/qa-lint-selftest.sh"
  mkdir -p "$R/$SK/qa-unreg-lint-skill"; printf -- '---\nname: qa-unreg-lint-skill\ndescription: qa\n---\nbody\n' >"$R/$SK/qa-unreg-lint-skill/SKILL.md"
  run l5 L
  ok 'lint_fails l5 qa-unreg-lint-skill' "T-REGISTRY-COMPLETE a planted unregistered skill folder: lint exit 1 naming it with STL-CFG-340..344"
  rm -rf "$R/$SK/qa-unreg-lint-skill"
  [ -f "$R/$MCPF" ] || echo '{"mcpServers": {}}' >"$R/$MCPF"
  ed "$MCPF" '.mcpServers["qa-unreg-lint-server"] = {command: "true", args: []}'
  run l6 L
  ok 'lint_fails l6 qa-unreg-lint-server' "T-REGISTRY-COMPLETE a planted unregistered MCP server in a manifest: lint exit 1 naming it with STL-CFG-340..344"
  ;;
cfix)   # Gate B fix cycle 2: the builder's own cases
  L() { python3 -I "$R/bin/capabilities.py" lint --json; }
  lint_fails() { [ $RC = 1 ] && out "$1" | grep >/dev/null -F -- "$2" && out "$1" | grep >/dev/null -E 'STL-CFG-34[0-4]'; }
  # RT2-01: a host-side load writes its trusted line only for a run of the adapter run records, with this role and card
  RUNS=$R/$(jq -r .adapter_runs "$IX"); mkdir -p "$RUNS"
  e0=$(nl "$EV"); run f1 C load qa-fake-skill --role "$RA" --run qa-no-such-run --card qa-card-f --json
  ok '[ $RC = 1 ] && out f1 | grep >/dev/null -E "$range" && ! grep -q QA-SKILL-BODY "$T/o/f1.out" && [ "$(nl "$EV")" = "$e0" ]' "RT2-01 load of a self-declared run (no run record): refused with a code, no definition, no trusted line"
  printf '{"run": "qa-run-f", "role": "%s", "card": "qa-card-f"}\n' "$RA" >"$RUNS/qa-run-f.json"
  run f2 C load qa-fake-skill --role "$RA" --run qa-run-f --card qa-card-other --json; r2=$RC
  run f3 C load qa-fake-skill --role "$RQ" --run qa-run-f --json; r3=$RC
  ok '[ $r2 = 1 ] && [ $r3 = 1 ] && [ "$(nl "$EV")" = "$e0" ] && ! grep -q QA-SKILL-BODY "$T/o/f2.out" "$T/o/f3.out"' "RT2-01 a run record of another card or another role: refused, no line"
  run f4 C load qa-fake-skill --role "$RA" --run qa-run-f --card qa-card-f --json
  ok '[ $RC = 0 ] && grep -q QA-SKILL-BODY "$T/o/f4.out" && tail -n +$((e0 + 1)) "$EV" | grep >/dev/null qa-card-f' "RT2-01 control: the run record's own role and card load, with the trusted line"
  run f5 C load qa-fake-skill --role "$RA" --run qa-run-f --json
  ok '[ $RC = 0 ] && tail -n 1 "$EV" | grep >/dev/null qa-card-f' "RT2-01 no --card: the line carries the run record's card"
  # RT2-03: every executable under the command folders, recursively, any name; excludes are case-insensitive
  i=0; for f in bin/qa-newtool bin/qa-newtool.js bin/qa-sub/deep/qa-newtool.sh bin/QA-UP.SH bin/adapters/qa-newtool; do
    i=$((i+1)); mkdir -p "$(dirname "$R/$f")"; printf '#!/usr/bin/env bash\ntrue\n' >"$R/$f"; chmod +x "$R/$f"
    run x$i L; ok 'lint_fails x'$i' "$(basename "$f")"' "RT2-03 an unregistered executable $f: lint exit 1 naming it"
    rm -f "$R/$f"
  done
  rm -rf "$R/bin/qa-sub"
  printf '#!/usr/bin/env bash\ntrue\n' >"$R/bin/QA-LINT-SELFTEST.SH"; chmod +x "$R/bin/QA-LINT-SELFTEST.SH"
  run x9 L; ok '[ $RC = 0 ]' "RT2-03 a selftest named in capitals needs no entry (excludes are case-insensitive)"
  rm -f "$R/bin/QA-LINT-SELFTEST.SH"
  # RT2-04: an MCP server declared in a CLI config (opencode.json mcp) and a skill folder linked from outside the root
  ed opencode.json '.mcp = {"qa-evil-server": {type: "local", command: ["true"]}}'
  run m1 L; ok 'lint_fails m1 qa-evil-server' "RT2-04 an MCP server declared in opencode.json (key mcp): lint exit 1 naming it"
  mkdir -p "$T/ext/qa-outer"; printf -- '---\nname: qa-outer\n---\nB\n' >"$T/ext/qa-outer/SKILL.md"; ln -s "$T/ext/qa-outer" "$R/$SK/qa-outer"
  : >"$AL"; run m2 C search qa-outer --role "$RA" --json
  ok 'grep >/dev/null -F qa-outer "$AL" && ! grep -q qa-outer "$T/o/m2.out"' "RT2-04 a skill folder linked from outside the root stays skipped (not found) but raises the unregistered-entry alert"
  run m3 L; ok 'lint_fails m3 qa-outer' "RT2-04 ... and the lint names it"
  rm -f "$R/$SK/qa-outer"
  # V1-13 / RT2-07: one alert per unregistered entry, not one per search
  mkdir -p "$R/$SK/qa-unreg-once"; printf -- '---\nname: qa-unreg-once\n---\nB\n' >"$R/$SK/qa-unreg-once/SKILL.md"
  : >"$AL"; for i in 1 2 3 4 5; do C search qa-fake-skill --role "$RA" --json >/dev/null 2>&1; done
  ok '[ "$(grep -c qa-unreg-once "$AL")" = 1 ]' "V1-13 five searches with one unregistered skill: exactly one alert line for it"
  rm -rf "$R/$SK/qa-unreg-once"
  # RT2-05: check-card and the card hook share one rule: a non-list field is refused, a role's own toolset counts as available to it
  printf '{"skills": {"qa-fake-skill": 1}}\n' >"$T/c1.json"; run k1 C check-card --role "$RA" --card "$T/c1.json" --json
  ok '[ $RC = 1 ] && out k1 | grep >/dev/null -E "$range"' "RT2-05 check-card refuses a skills field that is not a list"
  printf '{"skills": [""]}\n' >"$T/c2.json"; run k2 C check-card --role "$RA" --card "$T/c2.json" --json
  ok '[ $RC = 1 ]' "RT2-05 check-card refuses an empty id"
  KT=$(jq -r '[.roles | to_entries[] | select((.value.platform_toolsets // {}) | [.[][]] | length > 0) | {r: .key, t: (.value.platform_toolsets | [.[][]][0])}][0] // empty | "\(.r) \(.t)"' "$RJ")
  printf '{"tools": ["%s"]}\n' "${KT#* }" >"$T/c3.json"; run k3 C check-card --role "${KT% *}" --card "$T/c3.json" --json
  ok '[ -n "$KT" ] && [ $RC = 0 ]' "RT2-05 a role's own platform toolset is available to that role in check-card"
  # V1-07 / RT2-09: host_allows gives decide the caller's own capability, role and run, whatever the request file holds
  cat >"$R/bin/host_access.py" <<'PY'
import json, os
def decide(q):
    json.dump(q, open(os.environ["QA_HOST_SEEN"], "w"))
    return {"allowed": True}
PY
  export QA_HOST_SEEN=$T/seen.json
  ed .stella/capabilities.json --arg a "$RA" --arg g "$(uuid)" --arg i "$IID" \
    '.entries += [{id: "qa-host_session", kind: "tool", summary: "qahost fake host capability", keywords: ["qahost"], inputs: "none", outputs: "text",
      allowed_roles: [$a], risk_class: "host_session", hosts: [], secrets: [], status: "approved", source: "qa", triage: {result: "shipped"},
      definition: {text: "QA-HOST-DEF"}, global_id: $g, install_id: $i}]'
  printf '{"capability": "other-cap", "role": "other-role", "run": "other-run", "target": {"app": "qa-app", "domain": null}, "action": {"type": "qa-open"}, "confirmation": null}\n' >"$T/hreq.json"
  run h1 C describe qa-host_session --role "$RA" --run qa-own-run --host-request "$T/hreq.json" --json
  ok 'jq -e --arg r "$RA" ".capability == \"qa-host_session\" and .role == \$r and .run == \"qa-own-run\"" "$QA_HOST_SEEN"' "V1-07 decide is asked about the caller's own capability, role and run, not the request file's"
  ;;
esac
finish
