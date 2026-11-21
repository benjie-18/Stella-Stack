#!/usr/bin/env bash
# Hermetic self-test for the planner role (phase P1, item A: the planner and rubric rows of docs/hermes-local/roles.json and their
# hooks), written tests-first by the tester. As bin/owner-settings-selftest.sh drives a role: the hooks the role's matchers cover
# for a tool (roles.hooks_for, a catch-all rendered with the role's tools) run on a synthetic pre_tool_call payload of the planner's
# profile; a tool is refused when one of them exits 2 with a block, allowed when every one exits 0. The card tools are judged by
# bin/role-guard.py (registered for every profile) from the role's may_* flags.
# Checks (P1 tests.json ids): AC1-refused-write, AC1-refused-push, AC1-refused-config, AC1-refused-cards, AC1-read-ok.
# ASSUMPTIONS: the planner role's id is "planner" (design item A); its profile is the roles.json profile whose role it is.
set -u
jq() { env -u HOME jq "$@"; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/planner-role-selftest.XXXXXX"); trap 'rm -rf "$T"' EXIT
RF=${ROLES_FILE:-$ROOT/docs/hermes-local/roles.json}
export ROLES_FILE=$RF ESCALATE_SUP_DIR=$T/sup PROJECTS_DB=$T/none.db; mkdir -p "$T/sup/logs"
unset HERMES_KANBAN_TASK HERMES_KANBAN_RUN_ID HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BOARD HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT
fails=0
ok() { if ( eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/why" ] && head -3 "$T/why" | cut -c1-240 | sed 's/^/     | /'; fi; : >"$T/why"; }
PR=planner
PROF=$(jq -r --arg r "$PR" '[.profiles | to_entries[] | select(.value.role == $r) | .key][0] // empty' "$RF")
hooks() {  # <tool>: the hooks (runnable paths) the planner role's matchers cover for the tool
  python3 -I -c '
import json, re, sys
sys.path.insert(0, sys.argv[1] + "/bin"); import roles
d, r, prof, t = json.load(open(sys.argv[2])), sys.argv[3], sys.argv[4], sys.argv[5]
try:
    tools = roles.role_tools(d, r)
except Exception:
    tools = []   # Hermes toolsets unreadable here: the catch-all is rendered from the other matchers alone
for m, c, _, f in roles.hooks_for(d, "", prof, "", r, tools):
    if re.fullmatch(m, t):
        print(sys.argv[1] + "/" + f if f else c.removeprefix("python3 -I "))' "$ROOT" "$RF" "$PR" "$PROF" "$1" 2>>"$T/why"; }
pay() { jq -nc --arg p "$PROF" --arg t "$1" --argjson i "$2" '{hook_event_name: "pre_tool_call", tool_name: $t, tool_input: $i, profile: $p, session_id: "s1", cwd: "/workspace", extra: {}}'; }
hk() { case $1 in *.py) printf '%s' "$2" | python3 -I "$1";; *) printf '%s' "$2" | "$1";; esac >"$T/out" 2>/dev/null; echo $?; }   # <hook> <payload>: its exit code
refused() {  # <tool> <tool_input json>: a hook of the planner role covering the tool refuses it (exit 2, a block)
  local h by=""; [ -n "$PROF" ] || { echo "no profile has role $PR" >>"$T/why"; return 1; }
  for h in $(hooks "$1"); do [ "$(hk "$h" "$(pay "$1" "$2")")" = 2 ] && jq -e '.action == "block"' "$T/out" >/dev/null 2>&1 && by="$by ${h##*/}"; done
  echo "$1 $2: refused by${by:- (none)}" >>"$T/why"; [ -n "$by" ]; }
allowed() {  # <tool> <tool_input json>: at least one planner hook covers the tool and every one lets it through
  local h hs bad=""; [ -n "$PROF" ] || { echo "no profile has role $PR" >>"$T/why"; return 1; }
  hs=$(hooks "$1"); [ -n "$hs" ] || { echo "no hook covers $1" >>"$T/why"; return 1; }
  for h in $hs; do [ "$(hk "$h" "$(pay "$1" "$2")")" = 0 ] || bad="$bad ${h##*/}"; done
  echo "$1 $2: refused by$bad" >>"$T/why"; [ -z "$bad" ]; }
term() { jq -nc --arg c "$1" '{command: $c}'; }
guard() {  # <tool> <tool_input json>: bin/role-guard.py's exit code on the planner profile's call (output in $T/out)
  pay "$1" "$2" | python3 -I "$ROOT/bin/role-guard.py" >"$T/out" 2>&1; echo $?; }

ok '[ -n "$PROF" ] && jq -e --arg r "$PR" ".roles[\$r] | . != null and .assignable == true and .workspace == \"read-parent-worktree\" and
  ([.may_complete, .may_unblock, .may_claim, .may_delegate, .may_create_cards, .may_review] | all(. == false))" "$RF" &&
  jq -e --arg r "$(jq -r .rubric.extract_role "$ROOT/.stella/planner.json" 2>/dev/null)" ".roles[\$r] | . != null and .assignable == false and .workspace == \"none\"" "$RF"' \
  "precondition: roles.json has the planner role (assignable, read-parent-worktree, every may_* false) with a profile ($PROF), and the rubric role (not assignable, no workspace)"

for t in write_file patch; do
  ok 'refused '$t' "{\"path\": \"/workspace/x-planner-note.txt\", \"content\": \"x\", \"old_string\": \"a\", \"new_string\": \"b\"}"' "AC1-refused-write the planner's $t of a repo file is refused by its hooks"
done
ok 'refused terminal "$(term "echo x > /workspace/notes.md")" && refused terminal "$(term "touch /workspace/x")"' "AC1-refused-write a terminal write (redirect, touch) is refused"
for c in "git push" "git push origin HEAD" "git push origin HEAD:main" "git -C /workspace push --force origin main"; do
  ok 'refused terminal "$(term "'"$c"'")"' "AC1-refused-push terminal '$c' is refused"
done
for c in "git config user.name x" "sed -i s/a/b/ /workspace/.stella/planner.json" "cp /tmp/x /workspace/.stella/routing.json" "echo {} > /workspace/docs/hermes-local/roles.json"; do
  ok 'refused terminal "$(term "'"$c"'")"' "AC1-refused-config terminal '$c' is refused"
done
ok 'refused write_file "{\"path\": \"/workspace/.stella/planner-settings.json\", \"content\": \"{}\"}" && refused patch "{\"path\": \"/workspace/docs/hermes-local/roles.json\", \"old_string\": \"a\", \"new_string\": \"b\"}"' \
  "AC1-refused-config write_file / patch of stack data and config (.stella, roles.json) is refused"
for x in "kanban_create|{\"title\": \"x\", \"assignee\": \"builder-local\", \"project\": \"p\", \"workspace_kind\": \"worktree\", \"body\": \"x\"}|create cards" \
         "kanban_complete|{\"task_id\": \"t_0000c0de\", \"summary\": \"x\"}|complete cards" "delegate_task|{\"tasks\": [{\"goal\": \"x\"}]}|delegate"; do
  IFS='|' read -r t i v <<<"$x"
  ok '[ -n "$PROF" ] && [ "$(guard '$t' '"'$i'"')" = 2 ] && grep -q "the $PR role does not '"$v"'" "$T/out"' "AC1-refused-cards $t is refused by the role guard for the $PR role (may_* false)"
done
ok 'allowed read_file "{\"path\": \"/workspace/AGENTS.md\"}" && allowed search_files "{\"pattern\": \"planner\", \"path\": \"/workspace/bin\"}" && [ "$(guard read_file "{\"path\": \"/workspace/AGENTS.md\"}")" = 0 ]' \
  "AC1-read-ok (control) the planner reads the repo: read_file and search_files pass every hook and the role guard"
for c in "cat /workspace/AGENTS.md" "git -C /workspace log --oneline -3" "grep -n planner /workspace/AGENTS.md"; do
  ok 'allowed terminal "$(term "'"$c"'")"' "AC1-read-ok (control) terminal '$c' is allowed"
done
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
