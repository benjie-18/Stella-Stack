#!/usr/bin/env bash
# Hermetic self-test for the role table (D46): bin/roles.py validation and coverage, and a role nobody wrote code for.
# A scratch roles.json adds a new role and profile; bin/apply-hermes-local.sh against a scratch HOME (stub hermes,
# scratch projects.db, scratch alerts.log) must register its hooks, copy its hook files and render the SOUL list, and the
# role guard must apply its permissions, with no code change. Also: a profile with no row gets the fallback role and one
# STL-CFG-303 line; a row for a missing profile and a malformed table fail the check; apply refuses a malformed table.
# K8 (may_review, roles.py reviewers, {{REVIEWERS}}): ROLES_FILE=<table> and STAGE=<dir> point the K8 cases at a staged table and roles.py.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RF=${ROLES_FILE:-/workspace/docs/hermes-local/roles.json}   # the table under test (a staged copy while it is being replaced)
S=${STAGE:-/workspace/bin}   # roles.py under test, for the K8 cases
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/out" ] && sed 's/^/     /' "$T/out" | tail -4; fi; }
A="$T/home"; H="$A/.hermes"; SUP="$T/sup"; mkdir -p "$A/bin" "$SUP/logs" "$H/kanban/boards/ai-stack"
cp /workspace/config/owner.example.env "$T/owner.env"
export ESCALATE_SUP_DIR="$SUP" OWNER_CONFIG="$T/owner.env"   # scratch owner config (D39)
BOARD=$(. /workspace/bin/kanban-board.sh; echo "$KANBAN_BOARD")
python3 -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("create table projects (id, slug, name, board_slug, primary_path, archived)"); c.execute("insert into projects values (?, ?, ?, ?, ?, 0)", ("p_0000aaaa", "proj-a", "A", sys.argv[2], "/workspace")); c.commit()' "$H/projects.db" "$BOARD"
echo '{}' >"$H/kanban/boards/$BOARD/board.json"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls"\ncase "$*" in *"config get"*) echo unset;; esac\nexit 0\n' "$A" >"$A/bin/hermes"; chmod +x "$A/bin/hermes"
mk() { mkdir -p "$1"; printf 'model: x\n' >"$1/config.yaml"; echo '{"approvals": []}' >"$1/shell-hooks-allowlist.json"; }
# The scratch table: the real one plus role "planner" (assignable, delegates, creates cards, one hook) and profile planner-x.
jq '.roles.planner = {assignable: true, may_answer_for_owner: false, workspace: "git-worktree", may_complete: true, may_unblock: false, may_claim: true,
      may_delegate: true, may_create_cards: true, may_review: false, allowed_overrides: [], background_review: false,
      requirements: {tool_calling: true, min_context_tokens: 8000, vision: false, allowed_data_classes: ["public"]},
      platform_toolsets: {cli: ["file", "terminal"]},
      hooks: [{matcher: "^(write_file|patch|skill_manage)$", file: "docs/hermes-local/hooks/reviewer/deny-write.sh"}]}
    | .profiles["planner-x"] = {role: "planner", soul: "reviewer.md"}
    | .roles.planner.git_identity = {name: "FAKE_GIT_NAME", email: "FAKE_GIT_EMAIL"}' "$RF" >"$T/roles.json"
export ROLES_FILE="$T/roles.json"
for d in $(python3 -c 'import sys; sys.path.insert(0, "/workspace/bin"); import roles; [print(f) for _, f, _, l in roles.profiles(roles.load(), sys.argv[1]) if l]' "$H"); do mk "$d"; done
ap() { HOME="$A" PATH="$A/bin:$PATH" PROJECTS_DB="$H/projects.db" "${APPLY:-/workspace/bin/apply-hermes-local.sh}" "$@" >"$T/out" 2>&1; echo $?; }

# 1. Coverage: every row has a profile and every profile a row.
ok '[ "$(python3 /workspace/bin/roles.py check "$H" >"$T/out" 2>&1; echo $?)" = 0 ] && grep -q "every profile has a row" "$T/out"' "scratch root matching the scratch table: check passes"
ok '[ "$(ROLES_FILE=$RF python3 /workspace/bin/roles.py check "$H" >"$T/out" 2>&1; echo $?)" = 1 ] && grep -q "profile planner-x has no row" "$T/out"' "a profile with no row in the table: check fails"
mv "$H/profiles/planner-x" "$T/px"
ok '[ "$(python3 /workspace/bin/roles.py check "$H" >"$T/out" 2>&1; echo $?)" = 1 ] && grep -q "row planner-x names a profile that does not exist" "$T/out"' "a row naming a profile that does not exist: check fails"
mv "$T/px" "$H/profiles/planner-x"

# 2. The new role, with no code change: apply registers its hooks and copies its files.
rc=$(ap)
P="$H/profiles/planner-x"
ok 'grep -qF "command: \"$P/hooks/deny-write.sh\"" "$P/config.yaml" && grep -qF "/workspace/bin/role-guard.py" "$P/config.yaml" && grep -qF "/workspace/bin/kanban-guard.sh" "$P/config.yaml" && [ -x "$P/hooks/deny-write.sh" ] && jq -e --arg c "$P/hooks/deny-write.sh" ".approvals | index({event: \"pre_tool_call\", command: \$c})" "$P/shell-hooks-allowlist.json" >/dev/null' "new role: its hook, the role guard and the common hooks registered and approved, its hook file copied (apply exit $rc)"
ok 'grep -q -- "-p planner-x config set auxiliary.background_review.enabled false" "$A/calls"' "new role: background_review false written to its profile"
ok 'grep -q "^- You never complete a card, claim a card, unblock a card or delegate to a subagent: " "$H/SOUL.md" && grep -q "Cards go only to these workers: .*\`planner-x\`" "$H/SOUL.md" && grep -q "one of: \`proj-a\`" "$H/SOUL.md"' "dispatcher SOUL renders the assignable workers (new role included), the board's projects and its denied tools"
ok 'ap --check >/dev/null; ! grep -q "SOUL DRIFT\|MISSING\|NOT APPROVED\|not rendered" "$T/out" && [ "$(grep -c ": SOUL in sync$" "$T/out")" -ge 2 ]' "after apply, --check reports no SOUL or hook drift (each listed SOUL said in sync)"
# Apply's own SOUL rendering (verifier note; K12): every rendered placeholder filled, the board named from the data.
ok '(for s in "$H/SOUL.md" "$H"/profiles/*/SOUL.md; do [ ! -e "$s" ] || { grep -q "stella-rules:begin" "$s" && ! grep -q "{{" "$s"; } || exit 1; done) && grep -qF "uses board \`$(python3 -c "import sys; sys.path.insert(0, \"/workspace/bin\"); import roles; print(roles.board())")\`" "$H/SOUL.md"' "apply renders every SOUL with no placeholder left, and the dispatcher SOUL names the board from bin/kanban-board.sh"
jq '.profiles["planner-y"] = {role: "planner", soul: "reviewer.md"}' "$T/roles.json" >"$T/r2.json"; mk "$H/profiles/planner-y"
ok '[ "$(ROLES_FILE=$T/r2.json ap --check)" = 1 ] && grep -q "SOUL DRIFT" "$T/out"' "a new assignable profile in the table: --check reports the dispatcher SOUL's worker list as drift"
rm -rf "$H/profiles/planner-y"
# The role guard applies the new role's permissions from the table.
g() { jq -nc --arg p "$1" --arg t "$2" --argjson i "$3" '{tool_name: $t, tool_input: $i, profile: $p, extra: {}}' | PROJECTS_DB="$H/projects.db" python3 /workspace/bin/role-guard.py >"$T/out" 2>&1; echo $?; }
ok '[ "$(g planner-x delegate_task "{}")" = 0 ] && [ "$(g planner-x kanban_unblock "{\"task_id\":\"t_0000c001\"}")" = 2 ]' "new role: delegate allowed, unblock refused, as its row says"
ok '[ "$(g planner-x kanban_create "{\"title\":\"x\",\"assignee\":\"planner-x\",\"project\":\"proj-a\",\"workspace_kind\":\"worktree\",\"body\":\"x\"}")" = 0 ]' "new role: creates a valid card and is itself an assignable worker"
ok '[ "$(g planner-x kanban_complete "{\"task_id\":\"t_0000c001\"}")" = 2 ] && grep -q STL-GRD-601 "$T/out"' "new role: completion still needs the card's own run"

# 3. A profile with no row: the fallback role, nothing opens, one STL-CFG-303 line.
mk "$H/profiles/x-new"; : >"$SUP/logs/alerts.log"
rc=$(ap)
X="$H/profiles/x-new"
ok '[ "$rc" = 1 ] && grep -q "x-new: no row in roles.json, registering role unlisted" "$T/out" && [ "$(grep -c "^STL-CFG-303" "$SUP/logs/alerts.log")" = 1 ]' "unlisted profile: apply exits 1, says so, one STL-CFG-303 alerts.log line"
ok 'grep -qF "/workspace/bin/role-guard.py" "$X/config.yaml" && grep -qF "$X/hooks/write-guard.py" "$X/config.yaml" && grep -qF "$X/hooks/secret-guard.py" "$X/config.yaml" && [ -s "$X/hooks/write-guard.py" ]' "unlisted profile: role guard, write and secret guards registered (never left unguarded)"
ok '[ "$(g x-new kanban_create "{}")" = 2 ] && [ "$(g x-new delegate_task "{}")" = 2 ] && [ "$(g x-new kanban_complete "{}")" = 2 ]' "unlisted profile: create, delegate and complete refused"
rm -rf "$X"

# 4. A malformed table: check fails loudly, apply refuses and writes nothing.
echo '{"profiles": {"a": {"role": "nope"}}, "roles": {}}' >"$T/bad.json"
cp "$H/config.yaml" "$T/cfg.before"
ok '[ "$(ROLES_FILE=$T/bad.json python3 /workspace/bin/roles.py check "$H" >"$T/out" 2>&1; echo $?)" = 1 ] && grep -q "roles: INVALID" "$T/out"' "malformed table: check fails with INVALID"
ok '[ "$(ROLES_FILE=$T/bad.json ap)" != 0 ] && grep -q "roles: INVALID" "$T/out" && cmp -s "$H/config.yaml" "$T/cfg.before"' "malformed table: apply refuses and changes no config.yaml"
for bad in '.roles.builder.git_identity = {name: "lower", email: "X_MAIL"}' '.roles.builder.git_identity = {name: "X_NAME"}' '.roles.unlisted.may_delegate = true' '.roles.builder.workspace = "anywhere"' '.profiles["builder-x"] = {role: "builder", worker: "nope"}' '.roles.builder.hooks += [{matcher: "^x$", file: "docs/none.sh"}]' '.roles.builder.allowed_overrides = ["temperature"]'; do
  jq "$bad" "$RF" >"$T/b.json"
  ok '[ "$(ROLES_FILE=$T/b.json python3 /workspace/bin/roles.py field x may_complete >"$T/out" 2>&1; echo $?)" = 1 ]' "invalid table refused: $bad"
done
ok '[ "$(ROLES_FILE=$RF python3 /workspace/bin/roles.py field some-unknown-profile may_create_cards)" = false ]' "an unknown profile reads as the fallback role"

# 5. Worker git identity and safe.directory (D48), from data only: the fake role planner names two owner config keys.
PH="$H/profiles/planner-x/home"; GC="$PH/.gitconfig"
rc=$(ap); rc=$(ap --check)
ok '[ ! -e "$GC" ] && grep -q "^planner-x: git identity NOT SET (FAKE_GIT_NAME and FAKE_GIT_EMAIL" "$T/out" && ! grep -q "git config DRIFT" "$T/out"' "git identity keys unset in the owner config: reported, nothing written, not drift"
printf "FAKE_GIT_NAME='Fake Person'\nFAKE_GIT_EMAIL='fake@example.invalid'\nWORKER_GIT_NAME='Worker Fake'\nWORKER_GIT_EMAIL='worker@example.invalid'\n" >>"$T/owner.env"
python3 -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("insert into projects values (?, ?, ?, ?, ?, 0)", ("p_0000bbbb", "proj-b", "B", sys.argv[2], "/srv/other-repo")); c.commit()' "$H/projects.db" "$BOARD"
ok '[ "$(ap --check)" = 1 ] && grep -q "^planner-x: git config DRIFT" "$T/out"' "keys set, home has no .gitconfig: --check reports drift"
rc=$(ap)
ok 'grep -q "^planner-x: git config updated" "$T/out" && [ "$(git config --file "$GC" user.name)" = "Fake Person" ] && [ "$(git config --file "$GC" user.email)" = "fake@example.invalid" ]' "apply writes the identity from the owner config into the profile's home"
ok '[ "$(git config --file "$GC" --get-all safe.directory | paste -sd,)" = "/srv/other-repo,/workspace" ]' "safe.directory: the stack path and the board's project repos, none typed in the script"
ok '[ -s "$H/profiles/builder-claude/home/.gitconfig" ] && [ "$(git config --file "$H/profiles/builder-claude/home/.gitconfig" user.name)" = "Worker Fake" ]' "the real builder role's profiles get the identity of the keys roles.json names"
ok '[ ! -e "$H/home/.gitconfig" ] && [ ! -e "$H/profiles/reviewer/home/.gitconfig" -o -s "$H/profiles/reviewer/home/.gitconfig" ]' "a role without git_identity (the dispatcher) gets no .gitconfig"
sum=$(sha256sum "$GC"); rc=$(ap)
ok 'grep -q "^planner-x: git config in sync" "$T/out" && [ "$(sha256sum "$GC")" = "$sum" ] && rc=$(ap --check) && ! grep -q "git config DRIFT" "$T/out"' "apply is idempotent: in sync, file unchanged, --check reports no git drift"
git config --file "$GC" core.editor nano; git config --file "$GC" alias.st status
sed -i "s/^FAKE_GIT_NAME=.*/FAKE_GIT_NAME='Other Person'/" "$T/owner.env"
ok '[ "$(ap --check)" = 1 ] && grep -q "planner-x: git config DRIFT (user.name" "$T/out"' "the owner changes the name: --check reports drift"
rc=$(ap)
ok '[ "$(git config --file "$GC" user.name)" = "Other Person" ] && [ "$(git config --file "$GC" core.editor)" = nano ] && [ "$(git config --file "$GC" alias.st)" = status ] && grep -q "Fake Person" "$H"/backups/apply-*/planner-x.gitconfig' "a changed identity replaces only its keys: other lines stay, the old file is backed up"
ok '! grep -Eq "@|Fake|FAKE_GIT|WORKER_GIT" /workspace/bin/apply-hermes-local.sh /workspace/bin/roles.py' "no identity value or key name in the scripts (the key names live in roles.json)"
# 6. K8: a card is reviewed by a reviewing role. may_review is a boolean on every role (the fallback role false), and
# roles.py reviewers lists exactly the profiles whose role has it true, from the table alone.
exp=$(jq -c '. as $d | [.profiles | to_entries[] | select($d.roles[.value.role].may_review == true) | .key] | sort' "$RF")
ok '[ "$exp" != "[]" ] && [ "$(ROLES_FILE=$RF python3 $S/roles.py reviewers | jq -c .)" = "$exp" ]' "K8: roles.py reviewers lists exactly the may_review profiles of the real table ($exp)"
ok '[ "$(python3 $S/roles.py reviewers | jq -c .)" = "$exp" ]' "K8: the scratch table (the real one plus the planner role, may_review false) lists the same reviewers"
jq '.roles.planner.may_review = true' "$T/roles.json" >"$T/rv.json"
exp2=$(jq -c '. + ["planner-x"] | sort' <<<"$exp")
ok '[ "$(ROLES_FILE=$T/rv.json python3 $S/roles.py reviewers | jq -c .)" = "$exp2" ]' "K8: a new role with may_review true: its profile is listed, no code change"
jq '.roles[].may_review = false' "$RF" >"$T/rv0.json"
ok '[ "$(ROLES_FILE=$T/rv0.json python3 $S/roles.py reviewers | jq -c .)" = "[]" ]' "K8: no role may review: the list is empty"
ok '[ "$(ROLES_FILE=$RF python3 $S/roles.py field some-unknown-profile may_review)" = false ] && [ "$(python3 $S/roles.py field planner-x may_review)" = false ]' "K8: an unknown profile reads as the fallback role: may_review false"
# Validation: may_review missing, or not true/false, on any role (the fallback included) invalidates the table; the fallback
# role may not review.
for r in $(jq -r '.roles | keys[]' "$RF"); do
  jq --arg r "$r" 'del(.roles[$r].may_review)' "$RF" >"$T/b.json"
  ok '[ "$(ROLES_FILE=$T/b.json python3 $S/roles.py reviewers >"$T/out" 2>&1; echo $?)" = 1 ] && grep -q "role $r: may_review must be true or false" "$T/out" && [ "$(ROLES_FILE=$T/b.json python3 $S/roles.py field x may_complete >/dev/null 2>&1; echo $?)" = 1 ]' "K8: role $r without may_review: table invalid (reviewers and field exit 1)"
  for v in '"yes"' null 1 '[]'; do
    jq --arg r "$r" --argjson v "$v" '.roles[$r].may_review = $v' "$RF" >"$T/b.json"
    ok '[ "$(ROLES_FILE=$T/b.json python3 $S/roles.py reviewers >"$T/out" 2>&1; echo $?)" = 1 ] && grep -q "role $r: may_review must be true or false" "$T/out"' "K8: role $r with may_review=$v: table invalid"
  done
done
FB=$(jq -r '.fallback_role' "$RF")
jq --arg f "$FB" '.roles[$f].may_review = true' "$RF" >"$T/b.json"
ok '[ "$(ROLES_FILE=$T/b.json python3 $S/roles.py reviewers >"$T/out" 2>&1; echo $?)" = 1 ] && grep -q "fallback_role must open nothing" "$T/out"' "K8: the fallback role with may_review true: table invalid (nothing opens for an unlisted profile)"
# B2V-08: capability_fallback (escalation-thread's reassignment suggestion) must name another profile of the same role.
FBP=$(jq -r '[.profiles | to_entries[] | select(.value.capability_fallback) | .key] | first // empty' "$RF")
ok '[ -n "$FBP" ] && [ "$(ROLES_FILE=$RF python3 $S/roles.py reviewers >/dev/null 2>&1; echo $?)" = 0 ]' "B2V-08: the real table's capability_fallback ($FBP) is valid"
OTHER=$(jq -r --arg p "$FBP" '.profiles[$p].role as $r | [.profiles | to_entries[] | select(.value.role != $r) | .key] | first' "$RF")
for v in '"zz-no-such-profile"' "\"$FBP\"" "\"$OTHER\"" 1 '["builder-claude"]' '{"p": 1}'; do   # RT10-01: list, object
  jq --arg p "$FBP" --argjson v "$v" '.profiles[$p].capability_fallback = $v' "$RF" >"$T/b.json"
  ok '[ "$(ROLES_FILE=$T/b.json python3 $S/roles.py reviewers >"$T/out" 2>&1; echo $?)" = 1 ] && grep -q "capability_fallback must name another profile of the same role" "$T/out"' "B2V-08: capability_fallback = $v (no such profile, itself, another role, not a name): table invalid"
done
# SOUL value {{REVIEWERS}}: the reviewing profiles, back-quoted, from the table; none listed says so (no placeholder left).
sv() { PROJECTS_DB="$H/projects.db" ROLES_FILE=$1 python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import roles; print(roles.soul_values(roles.load(), sys.argv[2])["REVIEWERS"])' "$S" "$2" 2>&1; }
BP=$(jq -r '.profiles | keys[]' "$RF" | head -1)
# D101: a profile's SOUL lists the reviewers its role may name (review_callers; absent = anyone), so filter the table's reviewers by BP's role
cw() { jq -c --arg r "$(jq -r --arg p "$BP" '.profiles[$p].role' "$RF")" --slurpfile d "$RF" '[.[] | select((($d[0].profiles[.] // {}).review_callers // null) as $c | ($c == null) or ($c | index($r) != null))]'; }
want=$(jq -r 'map("`" + . + "`") | join(", ")' <<<"$(cw <<<"$exp")"); want2=$(jq -r 'map("`" + . + "`") | join(", ")' <<<"$(cw <<<"$exp2")")
ok '[ "$(sv "$RF" "$BP")" = "$want" ]' "K8: {{REVIEWERS}} renders the reviewing profiles from the table ($want)"
ok '[ "$(sv "$T/rv.json" "$BP")" = "$want2" ]' "K8: {{REVIEWERS}} follows the table when another role may review"
ok '[ "$(sv "$T/rv0.json" "$BP")" = "(no reviewing profile listed)" ]' "K8: {{REVIEWERS}} with no reviewing role: '(no reviewing profile listed)', never empty"
# F1 W2 (E3): role requirements, schema_version, the eight fail-closed roles, a fake role with requirements.
RQ='{"tool_calling": true, "min_context_tokens": 8000, "vision": false, "allowed_data_classes": ["public"]}'
ok '[ "$(jq -r .schema_version "$RF")" = 1 ] && jq -e "[.roles[] | has(\"requirements\")] | all" "$RF" >/dev/null' "W2: the real table has schema_version 1 and requirements on every role"
for r in tester validator verifier red-team router voice look proposer; do
  ok 'jq -e --arg r "$r" ".roles[\$r] as \$x | \$x != null and ([\"assignable\",\"may_complete\",\"may_unblock\",\"may_claim\",\"may_delegate\",\"may_create_cards\",\"may_review\"] | all(\$x[.] == false)) and \$x.workspace == \"none\" and \$x.allowed_overrides == [] and ([.profiles[].role] | index(\$r)) == null and (\$x.hooks == .roles[.fallback_role].hooks) and (\$x.platform_toolsets == null)" "$RF" >/dev/null' "W2: role $r exists, opens nothing, no profile, the fallback role's hooks"
  ok '[ "$(python3 $S/roles.py requirements $r | jq -c "keys")" = "[\"allowed_data_classes\",\"min_context_tokens\",\"tool_calling\",\"vision\"]" ]' "W2: roles.py requirements $r returns its requirements as JSON"
done
ok '[ "$(python3 $S/roles.py requirements look | jq .vision)" = true ] && [ "$(python3 $S/roles.py requirements router | jq .vision)" = false ]' "W2: look needs vision, router does not"
ok '[ "$(python3 $S/roles.py requirements no-such-role >"$T/out" 2>&1; echo $?)" = 1 ]' "W2: roles.py requirements of an unknown role exits 1"
jq --argjson q "$RQ" '.roles["fake-role"] = (.roles.unlisted + {requirements: $q})' "$RF" >"$T/fr.json"
H2="$T/h2"; mkdir -p "$H2"; echo x >"$H2/config.yaml"; for p in $(jq -r '.profiles | keys[] | select(. != "default")' "$RF"); do mkdir -p "$H2/profiles/$p"; echo x >"$H2/profiles/$p/config.yaml"; done
ok '[ "$(ROLES_FILE=$RF python3 $S/roles.py check "$H2" >"$T/out" 2>&1; echo $?)" = 0 ] && [ "$(ROLES_FILE=$T/fr.json python3 $S/roles.py check "$H2" >"$T/out" 2>&1; echo $?)" = 0 ] && [ "$(ROLES_FILE=$T/fr.json python3 $S/roles.py requirements fake-role | jq -S -c .)" = "$(jq -Sc . <<<"$RQ")" ]' "W2: a fake role with requirements passes check and answers, no code change"
chk() { ROLES_FILE=$T/b.json python3 $S/roles.py check "$H2" >"$T/out" 2>&1; echo $?; }
for r in $(jq -r '.roles | keys[]' "$RF"); do
  jq --arg r "$r" 'del(.roles[$r].requirements)' "$RF" >"$T/b.json"
  ok '[ "$(chk)" = 1 ] && grep -q "role $r: requirements" "$T/out"' "W2: role $r without requirements: check fails"
done
bad() { jq "$1" "$RF" >"$T/b.json"; pat=$2; ok '[ "$(chk)" = 1 ] && grep -q "$pat" "$T/out"' "W2: $3: check fails"; }
bad '.roles.builder.requirements.min_context_tokens = -1' 'min_context_tokens' "negative context"
bad '.roles.builder.requirements.min_context_tokens = true' 'min_context_tokens' "boolean context"
bad '.roles.builder.requirements.min_context_tokens = 1.5' 'min_context_tokens' "fractional context"
bad '.roles.builder.requirements.colour = 1' 'colour' "unknown requirements key"
bad '.roles.builder.requirements.vision = "yes"' 'vision' "vision not a boolean"
bad '.roles.builder.requirements.tool_calling = null' 'tool_calling' "tool_calling not a boolean"
bad '.roles.builder.requirements.allowed_data_classes = "public"' 'allowed_data_classes' "data classes not a list"
bad '.roles.builder.requirements.allowed_data_classes = ["public","public"]' 'allowed_data_classes' "duplicate data class"
bad 'del(.roles.builder.requirements.vision)' 'vision' "a requirements key missing"
bad '.schema_version = 2' 'schema_version' "wrong schema_version"
bad 'del(.schema_version)' 'schema_version' "missing schema_version"
# F1 W2 round 2 (QA r1): the coordinator is its own field, strict values, the fallback opens nothing in every field, the read command's failures.
FB=$(jq -r .fallback_role "$RF"); R1=$(jq -r --arg fb "$FB" '[.roles | keys[] | select(. != $fb)][0]' "$RF")
ok '[ "$(jq "[.roles[] | select(.may_answer_for_owner == true)] | length" "$RF")" = 1 ] && [ "$(jq ".roles[\"$FB\"].may_answer_for_owner" "$RF")" = false ]' "W2-RT-01: exactly one role may answer for the owner, the fallback does not"
for r in $(jq -r '.roles | keys[]' "$RF"); do
  jq --arg r "$r" 'del(.roles[$r].may_answer_for_owner)' "$RF" >"$T/b.json"
  ok '[ "$(chk)" = 1 ] && grep -q "role $r: may_answer_for_owner" "$T/out"' "W2-RT-01: role $r without may_answer_for_owner: check fails"
done
bad ".roles[\"$FB\"].may_answer_for_owner = true" 'fallback_role must open nothing' "the fallback may answer for the owner"
bad ".roles[\"$R1\"].may_answer_for_owner = \"yes\"" 'may_answer_for_owner' "may_answer_for_owner not a boolean"
# W2-RT-02: a repeated key at any depth
rep() { python3 -I -c 'import sys; t = open(sys.argv[1]).read(); a, b = sys.argv[2], sys.argv[3]; i = t.index(a); print(t[:i] + b + t[i:], end="")' "$RF" "$1" "$2" >"$T/b.json"; }
rep '"schema_version": 1,' '"schema_version": 1,
  '; ok '[ "$(chk)" = 1 ] && grep -q "repeated" "$T/out" && grep -q "schema_version" "$T/out"' "W2-RT-02: a repeated top-level key: check fails, naming it"
rep '"vision":' '"vision": true, '; ok '[ "$(chk)" = 1 ] && grep -q "repeated" "$T/out" && grep -q "vision" "$T/out"' "W2-RT-02: a repeated key inside requirements: check fails, naming it"
ok '[ "$(ROLES_FILE=$T/b.json python3 $S/roles.py reviewers >"$T/out" 2>&1; echo $?)" = 1 ]' "W2-RT-02: load refuses it too"
# W2-RT-07 / W2-VAL-02 / W2-VAL-03 / W2-VAL-05: exact types
tv() { python3 -I -c 'import sys; t = open(sys.argv[1]).read(); i = t.index(sys.argv[2]); print(t[:i] + t[i:].replace(sys.argv[3], sys.argv[4], 1), end="")' "$RF" "$1" "$2" "$3" >"$T/b.json"; }
for v in 1.0 true '"1"' 1e0; do
  tv '"schema_version"' '"schema_version": 1' "\"schema_version\": $v"; ok '[ "$(chk)" = 1 ] && grep -q "schema_version" "$T/out"' "W2-VAL-03: schema_version $v: check fails"
  tv '"sandbox"' '"schema_version": 1' "\"schema_version\": $v"; ok '[ "$(chk)" = 1 ] && grep -q "sandbox: schema_version" "$T/out"' "W2-VAL-05: sandbox schema_version $v: check fails"
done
big() { jq --argjson v "$1" ".roles[\"$R1\"].requirements.min_context_tokens = \$v" "$RF" >"$T/b.json"; }
big 9007199254740991; ok '[ "$(chk)" = 0 ]' "W2-RT-07: min_context_tokens 2^53-1 passes"
big 9007199254740992; ok '[ "$(chk)" = 1 ] && grep -q min_context_tokens "$T/out"' "W2-RT-07: min_context_tokens 2^53 fails"
python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); d["roles"][sys.argv[2]]["requirements"]["min_context_tokens"] = 10**39; json.dump(d, open(sys.argv[3], "w"))' "$RF" "$R1" "$T/b.json"
ok '[ "$(chk)" = 1 ] && grep -q min_context_tokens "$T/out"' "W2-RT-07: min_context_tokens 10^39 fails"
# W2-RT-04 / W2-RT-08: the fallback opens nothing in every field
bad ".roles[\"$FB\"].requirements.allowed_data_classes += [\"zz-extra\"]" 'allowed_data_classes' "the fallback allows a data class another role lacks"
bad ".roles[\"$FB\"].hooks = []" 'hook' "the fallback with no hooks"
bad ".roles[\"qa-new\"] = (.roles[\"$FB\"] | .hooks = [])" 'qa-new' "a role no profile names, with fewer hooks than the fallback"
bad ".roles[\"qa-new\"] = (.roles[\"$FB\"] | .hooks = [.hooks[0] | .matcher = \"x\"])" 'qa-new' "a role no profile names, without the fallback's hooks (other matcher)"
# W2-RT-03: lists the code treats as sets
bad ".roles[\"$R1\"].allowed_overrides = [\"model\", \"model\"]" 'allowed_overrides' "allowed_overrides with a repeated entry"
bad '.protected.repo += [.protected.repo[0]]' 'protected' "protected.repo with a repeated entry"
bad '.protected.home += [.protected.home[0]]' 'protected' "protected.home with a repeated entry"
bad '.owner_settings += [.owner_settings[0]]' 'owner_settings' "owner_settings with a repeated entry"
bad ".roles[\"$R1\"].workers = [\"a\", \"a\"]" 'workers' "workers with a repeated entry"
# W2-RT-05 / W2-RT-06: failures of the read command carry a code, a plain message and one alert line
mkdir -p "$T/fl" "$T/rs/logs"; printf '#!/usr/bin/env bash\nexit 1\n' >"$T/fl/hermes"; chmod +x "$T/fl/hermes"
rq() { ESCALATE_SUP_DIR="$T/rs" PATH="$T/fl:$PATH" python3 $S/roles.py requirements "$@" >"$T/ro" 2>"$T/re"; echo $?; }
: >"$T/rs/logs/alerts.log"
ok '[ "$(ROLES_FILE=$RF rq no-such-role)" = 1 ] && [ ! -s "$T/ro" ] && grep -q "no-such-role" "$T/re" && grep -q "not in Stella" "$T/re" && [ "$(grep -c "^STL-CFG-311 " "$T/rs/logs/alerts.log")" = 1 ] && grep -q " problem=.*no-such-role" "$T/rs/logs/alerts.log"' "W2-RT-05: unknown role: exit 1, plain catalog message with the name on stderr, exactly one alert line with problem="
jq 'del(.schema_version)' "$RF" >"$T/b.json"; : >"$T/rs/logs/alerts.log"
ok '[ "$(ROLES_FILE=$T/b.json rq "$R1")" = 1 ] && [ ! -s "$T/ro" ] && grep -q "role table" "$T/re" && [ "$(grep -c "^STL-CFG-303 " "$T/rs/logs/alerts.log")" = 1 ]' "W2-RT-06: requirements on an invalid table: nothing on stdout, STL-CFG-303 message on stderr, exit 1, one alert line"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
