#!/usr/bin/env bash
# Hermetic self-test for review routing (Stage 6 follow-up 3, D101). A profile row in roles.json may carry review_callers: the roles that
# may name that profile as the reviewer of a card (kanban_request_review) or assign a card to it (kanban_create). Absent = anyone, as
# before. The Claude reviewer's row lists the orchestrator's role only, so a builder cannot spend Pro pool by naming it. The list is an
# owner-edited setting in the role table (protected from every agent write); the guard enforces whatever it says.
# Fixture role tables (jq copies of the real one), the real role-guard.py and write-guard.py as processes; no board, no Discord.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
RJ=/workspace/docs/hermes-local/roles.json
CP=$(jq -r '[.profiles | to_entries[] | select(.value.role == "reviewer" and .value.worker == "claude-code") | .key][0]' "$RJ")
NP=$(jq -r '[.profiles | to_entries[] | select(.value.role == "reviewer" and .value.worker == "opencode") | .key][0]' "$RJ")
BP=$(jq -r '[.profiles | to_entries[] | select(.value.role == "builder") | .key][0]' "$RJ")
DP=$(jq -r '[.profiles | to_entries[] | select(.value.role == "dispatcher") | .key][0]' "$RJ")
export ESCALATE_SUP_DIR=$T/sup PYTHONPATH=/workspace/bin; mkdir -p "$T/sup/logs"; cp /workspace/config/owner.example.env "$T/owner.env"; export OWNER_CONFIG=$T/owner.env
unset HERMES_KANBAN_TASK HERMES_KANBAN_RUN_ID HERMES_KANBAN_BOARD HERMES_HOME
tbl() { jq "$1" "$RJ" >"$T/$2.json"; }
tbl ".profiles[\"$CP\"].review_callers = [\"dispatcher\"]" owner_default          # the shipped intent
tbl ".profiles[\"$CP\"].review_callers = [\"dispatcher\", \"builder\"]" owner_widened   # the owner widens it
tbl "del(.profiles[\"$CP\"].review_callers)" open                                   # no setting: anyone, as before
# rg <table> <profile> <tool> <args json>: role-guard's exit code (message in $T/out)
rg() { jq -nc --arg p "$2" --arg t "$3" --argjson a "$4" '{hook_event_name:"pre_tool_call", tool_name:$t, tool_input:$a, session_id:"s1", cwd:"/tmp", profile:$p}' \
  | ROLES_FILE=$T/$1.json python3 -I /workspace/bin/role-guard.py >"$T/out" 2>"$T/err"; echo $?; }
RV() { jq -nc --arg r "$1" '{task_id:"t_aaaaaaaa", reviewer:$r}'; }

ok '[ "$(rg owner_default "$BP" kanban_request_review "$(RV "$CP")")" = 2 ] && grep -q "$DP\\|dispatcher" "$T/out"' "a builder naming the Claude reviewer in a review request is refused (and told who may)"
ok '[ "$(rg owner_default "$BP" kanban_request_review "$(RV "$NP")")" = 0 ]' "control: the same builder naming the 9B reviewer passes"
ok '[ "$(rg owner_default "$DP" kanban_request_review "$(RV "$CP")")" = 0 ]' "the orchestrator naming the Claude reviewer through the review request passes"
ok '[ "$(rg owner_widened "$BP" kanban_request_review "$(RV "$CP")")" = 0 ]' "the owner widens the setting (builder added): the builder's request now passes (the setting takes effect)"
ok '[ "$(rg open "$BP" kanban_request_review "$(RV "$CP")")" = 0 ]' "with no setting the old behaviour holds: anyone may name any reviewer"
ok '[ "$(rg owner_default "$BP" kanban_request_review "$(RV "$BP")")" = 2 ]' "control: a builder is still never its own reviewer"
ok '[ "$(rg owner_default "$BP" kanban_request_review "$(RV nobody)")" = 2 ]' "control: an unknown reviewer name is still refused"
# direct assignment of a card to the Claude reviewer (a general-agent use) by a role the setting does not list
CREATE=$(jq -nc --arg a "$CP" '{title:"x", assignee:$a, body:"b", workspace_kind:"worktree", parents:["t_bbbbbbbb"], workspace_path:"/workspace/.scratch/x/.worktrees/t_bbbbbbbb"}')
ok '[ "$(rg owner_default "$DP" kanban_create "$CREATE")" = 2 ] && ! grep -q "may only be assigned by" "$T/out"' "the orchestrator assigning a review card to it is not refused by the routing rule (other card rules may refuse)"
tbl ".profiles[\"$CP\"].review_callers = [\"builder\"]" nodisp
ok '[ "$(rg nodisp "$DP" kanban_create "$CREATE")" = 2 ] && grep -q "may only be assigned by" "$T/out"' "an assignee whose setting does not list the caller's role is refused with the routing message"
# the setting itself: validated, and protected from every agent write
ok 'jq -e ".profiles[\"$CP\"].review_callers == [\"dispatcher\", \"card\"]" "$RJ" >/dev/null' "the shipped table gives the Claude reviewer review_callers [dispatcher, card]"
ok '! jq -e ".profiles[\"$NP\"].review_callers" "$RJ" >/dev/null 2>&1' "the 9B reviewer has no restriction"
vbad() { jq "$1" "$RJ" >"$T/vb.json"; ROLES_FILE=$T/vb.json python3 -I /workspace/bin/roles.py check "$HOME/.hermes" >/dev/null 2>&1; }
ok 'jq empty "$T/owner_default.json"; python3 -I -c "import sys; sys.path.insert(0, \"/workspace/bin\"); import json, roles; sys.exit(0 if not roles.validate(json.load(open(\"$T/owner_default.json\"))) else 1)"' "control: the table with the setting validates"
for bad in ".profiles[\"$CP\"].review_callers = \"dispatcher\"" ".profiles[\"$CP\"].review_callers = [\"nosuchrole\"]" ".profiles[\"$CP\"].review_callers = []" ".profiles[\"$CP\"].review_callers = [\"card\", 5]"; do
  ok 'jq "$bad" "$RJ" >"$T/vb.json"; ! python3 -I -c "import sys; sys.path.insert(0, \"/workspace/bin\"); import json, roles; sys.exit(0 if not roles.validate(json.load(open(\"$T/vb.json\"))) else 1)"' "validate refuses: ${bad:0:60}"
done
# a worker cannot change the setting: the write guard refuses a builder's write to the role table, in every form
WG=/workspace/docs/hermes-local/hooks/builder/write-guard.py
wg() { jq -nc --arg t "$1" --argjson i "$2" --arg p "$BP" '{hook_event_name:"pre_tool_call", tool_name:$t, tool_input:$i, session_id:"s1", cwd:"/tmp", profile:$p, extra:{}}' \
  | python3 -I "$WG" >"$T/out" 2>"$T/err"; echo $?; }
ok '[ "$(wg write_file "$(jq -nc --arg p "$RJ" "{path:\$p, content:\"{}\"}")")" = 2 ]' "a builder's write_file on roles.json is refused"
ok '[ "$(wg patch "$(jq -nc --arg p "$RJ" "{mode:\"replace\", path:\$p, old_string:\"a\", new_string:\"b\"}")")" = 2 ]' "a builder's patch on roles.json is refused"
ok '[ "$(wg terminal "$(jq -nc --arg c "sed -i s/dispatcher/builder/ $RJ" "{command:\$c}")")" = 2 ]' "a builder's sed -i on roles.json is refused"
ok '[ "$(wg terminal "$(jq -nc --arg c "echo x >> $RJ" "{command:\$c}")")" = 2 ]' "a builder's shell append to roles.json is refused"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
