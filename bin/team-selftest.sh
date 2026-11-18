#!/usr/bin/env bash
# Hermetic self-test for bin/team.py (F2b item G), no model call: in a scratch root (a copy of bin, .stella, docs, the agents folder; its
# own HOME, temp and session folders) the preset's agent files are generated and checked. Cases: generate then check passes; a hand
# edit fails naming the field or the body, with one alert line; fake session folders (a top-level <session>.jsonl, a <session>/subagents
# folder with agent-*.jsonl and their .meta.json agentType) decide the model case: another model fails naming agent, model and count,
# the link, a fallback and a rung agree, an agent with no transcript is "not seen", an older session does not count; a generated file
# of an agent the preset dropped is stale, a file with no marker is unmanaged; a new agent added as data (preset entry and body file)
# is generated with no code change; an unknown preset fails closed with a coded line and writes nothing. Nothing names an agent
# or a model: they are read from the shipped preset. The same ground as the shared test qa/wave3/A2.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/team-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
R=$T/root
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$T/home" "$T/tmp" "$T/sup/logs" "$T/o" "$T/s0"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"
cd "$T" || exit 1
jq() { env -u HOME jq "$@"; }
IX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IX"; }
AD=$(ix .agents_dir); BD=$R/$(ix .team_bodies); PR=$(ix .team_preset); mkdir -p "$R/$AD"; cp -r "$ROOT/$AD/." "$R/$AD/"
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$ROOT/$(ix .role_table)" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT
fails=0
ok() { if ( eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
RA=$R/$(jq -r '[.files[] | select(.schema == "role-assignments")][0].path' "$IX")
P=".effort_modes[\"$PR\"]"
ra() { jq "$@" "$RA" >"$RA.n" && mv "$RA.n" "$RA"; }
tm() { python3 -I -B "$R/bin/team.py" "$@" >"$T/o/out" 2>"$T/o/err"; }   # stdout JSON in $T/o/out, the coded line in $T/o/err
AL=$T/sup/logs/alerts.log; : >"$AL"
# two agents from the data: one with a fallback (F), one with a rung ladder (L)
F=$(jq -r "[$P.agents | to_entries[] | select((.value.fallbacks // []) | length > 0) | .key][0]" "$RA")
FM=$(jq -r --arg a "$F" "$P.agents[\$a].link.model" "$RA"); FB=$(jq -r --arg a "$F" "$P.agents[\$a].fallbacks[0].model" "$RA")
L=$(jq -r "[$P.agents | to_entries[] | select((.value.escalation_chain // []) | length > 0) | .key][0]" "$RA")
LR=$(jq -r --arg a "$L" "$P.agents[\$a].escalation_chain[-1].model" "$RA")
sess() {  # <dir> <session> <minutes old> <agent>:<logged model>:<lines>...
  local d=$1 s=$2 age=$3 sp a m n i; shift 3; mkdir -p "$d/$s/subagents"; echo '{"type":"user"}' >"$d/$s.jsonl"
  for sp in "$@"; do IFS=: read -r a m n <<<"$sp"; i=$RANDOM$RANDOM
    echo "{\"agentType\":\"$a\"}" >"$d/$s/subagents/agent-a$i.meta.json"
    for _ in $(seq "$n"); do echo "{\"type\":\"assistant\",\"message\":{\"model\":\"$m\"}}"; done >"$d/$s/subagents/agent-a$i.jsonl"; done
  touch -d "-$age minutes" "$d/$s.jsonl"
}

tm check --sessions "$T/s0" --json; c1=$?
ok '[ "$c1" = 0 ] && jq -e ".ok and ([.agents[].session] | all(. == \"not seen\"))" "$T/o/out" && [ ! -s "$AL" ]' "S1 the shipped agent files pass check; with no session every agent is not seen; no alert"
sed -i "s/^model: .*/model: hand-edit/" "$R/$AD/$F.md"; tm check --sessions "$T/s0" --json; c2=$?
ok '[ "$c2" != 0 ] && jq -e --arg a "$F" "[.agents[] | select(.agent == \$a) | .problems[].problem] | any(test(\"model\"))" "$T/o/out" && [ "$(grep -c . "$AL")" = 1 ] && grep -q "STL-MDL-744" "$T/o/err"' "S2 a hand-edited model line fails naming the agent and model; one alert line, STL-MDL-744"
tm generate --json; g=$?; echo "a line by hand" >>"$R/$AD/$F.md"; tm check --sessions "$T/s0" --json; c3=$?
ok '[ "$g" = 0 ] && [ "$c3" != 0 ] && jq -c . "$T/o/out" | grep -q body' "S3 generate repairs the file; a line added to the body fails naming body"
tm generate --json
sess "$T/s1" a 1 "$F:claude-qa-zz-9:3"; tm check --sessions "$T/s1" --json; c4=$?
ok '[ "$c4" != 0 ] && jq -c . "$T/o/out" | grep -q "claude-qa-zz-9" && grep -q "STL-MDL-745" "$T/o/err" && grep -q "3 lines" "$T/o/err"' "S4 a session with an agent on another model fails naming agent, model and count, STL-MDL-745"
sess "$T/s2" a 1 "$F:$FM:2" "$F:claude-$FB-5-5:1" "$L:claude-$LR-5-5:1"; tm check --sessions "$T/s2" --json; c5=$?
ok '[ "$c5" = 0 ]' "S5 the link model, a fallback model and a rung model agree"
sess "$T/s3" old 90 "$F:claude-qa-zz-9:3"; sess "$T/s3" new 1 "$F:$FM:1"; tm check --sessions "$T/s3" --json; c6=$?
ok '[ "$c6" = 0 ]' "S6 only the newest session counts"
J=$(jq -c "$P.agents[\"$F\"]" "$RA")
ra --argjson e "$J" "$P.agents[\"fake-agent\"] = (\$e | .description = \"a fake agent\")"; echo "fake body" >"$BD/fake-agent.md"; sum=$(cat "$R"/bin/* 2>/dev/null | md5sum)
tm generate --json; g=$?; tm check --sessions "$T/s0" --json; c7=$?
ok '[ "$g" = 0 ] && [ "$c7" = 0 ] && grep -q "fake body" "$R/$AD/fake-agent.md" && [ "$(cat "$R"/bin/* 2>/dev/null | md5sum)" = "$sum" ]' "S7 an agent added as data (entry and body file) is generated and checked with no code change"
ra "del($P.agents[\"fake-agent\"])"; rm -f "$BD/fake-agent.md"; printf -- '---\nname: by-hand\n---\nx\n' >"$R/$AD/by-hand.md"; tm check --sessions "$T/s0" --json; c8=$?
ok '[ "$c8" != 0 ] && jq -e ".stale == [\"fake-agent\"] and (.unmanaged | index(\"by-hand\") != null)" "$T/o/out"' "S8 a generated file of a dropped agent is stale (fails); a file with no marker is unmanaged (listed)"
rm -f "$R/$AD/fake-agent.md"; before=$(ls -A "$R/$AD" | md5sum)
tm generate --preset no-such-preset --out "$T/nowhere" --json; u1=$?; grep -qE "^STL-MDL-743" "$T/o/err"; e1=$?
tm check --preset no-such-preset --sessions "$T/s0" --json; u2=$?
ok '[ "$u1" != 0 ] && [ "$e1" = 0 ] && [ ! -e "$T/nowhere" ] && [ "$u2" != 0 ] && [ "$(ls -A "$R/$AD" | md5sum)" = "$before" ]' "S9 an unknown preset fails closed with STL-MDL-743 and writes nothing"
ok '[ "$(jq -s "[.[] | select(.type == \"team.generated\")] | length" "$R/$(ix .event_log)")" -ge 3 ]' "S10 each generate wrote one team.generated event line"

echo "# team-selftest: $fails failed"; [ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
