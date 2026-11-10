#!/usr/bin/env bash
# Hermetic self-test for the Claude-backed reviewer (Stage 6 follow-up 2, D92): profile "reviewer-claude" is a second reviewer, worker
# kind claude-code. Its terminal may run the reviewer's own test/read-only-git commands plus ONE exact Claude Code call that can only
# read (Read, Grep, Glob; model sonnet). The 9B "reviewer" keeps its old hook. No Claude call, no login, no board.
set -u
R=/workspace; H=$R/docs/hermes-local/hooks/reviewer/claude-review-terminal.sh; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
jq() { env -u HOME jq "$@"; }
run() { jq -nc --arg c "$1" --arg t "${2:-terminal}" '{hook_event_name: "pre_tool_call", tool_name: $t, tool_input: {command: $c}}' | bash "$H" >"$T/out" 2>&1; echo $?; }
P="claude -p 'Check that docs/colour.txt holds the colour the owner chose' --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob"

ok '[ -f "$H" ] && bash -n "$H"' "the hook exists and parses"
ok '[ "$(run "$P")" = 0 ]' "the exact read-only Claude review call is allowed"
ok '[ "$(run "claude -p '"'"'x'"'"' --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob")" = 0 ]' "a one-letter prompt is allowed"
for c in "git diff --name-only main...HEAD" "git show --stat HEAD" "git log --oneline -n 5"; do
  ok '[ "$(run "$c")" = 0 ]' "the reviewer's own command still passes: $c"
done
# refusals: any other shape of claude, any other tool, any extra flag, any shell trick
for c in \
  "claude -p 'x' --model sonnet --allowedTools Bash" \
  "claude -p 'x' --model sonnet --allowedTools Read,Edit" \
  "claude -p 'x' --model sonnet --allowedTools Read,Grep,Glob,Bash" \
  "claude -p 'x' --model opus --allowedTools Read,Grep,Glob" \
  "claude -p 'x' --model sonnet --allowedTools Read,Grep,Glob --dangerously-skip-permissions" \
  "claude -p 'x' --model sonnet --allowedTools Read,Grep,Glob --add-dir /" \
  "claude -p 'x' --model sonnet --allowedTools Read,Grep,Glob --permission-mode bypassPermissions" \
  "claude -p 'x' --model sonnet --allowedTools Read,Grep,Glob --settings /tmp/s.json" \
  "claude -p 'x' --model sonnet --allowedTools Read,Grep,Glob --mcp-config /tmp/m.json" \
  "claude --model sonnet -p 'x' --allowedTools Read,Grep,Glob" \
  "claude -p x --model sonnet --allowedTools Read,Grep,Glob" \
  "claude -p 'x' --model sonnet --allowedTools Read,Grep,Glob; rm -rf /tmp/x" \
  "claude -p 'x' --model sonnet --allowedTools Read,Grep,Glob && id" \
  "claude -p 'x' --model sonnet --allowedTools Read,Grep,Glob | tee /tmp/o" \
  "claude -p 'x' --model sonnet --allowedTools Read,Grep,Glob > /tmp/o" \
  "claude -p 'x'; id' --model sonnet --allowedTools Read,Grep,Glob" \
  "claude -p \$(cat /etc/passwd) --model sonnet --allowedTools Read,Grep,Glob" \
  "claude -p '' --model sonnet --allowedTools Read,Grep,Glob" \
  "env FOO=1 claude -p 'x' --model sonnet --allowedTools Read,Grep,Glob" \
  "/usr/local/share/npm-global/bin/claude -p 'x' --model sonnet --allowedTools Read,Grep,Glob" \
  "claude auth login" "claude setup-token" "rm -rf /tmp/x" "cat /etc/passwd" "curl http://example.com"; do
  ok '[ "$(run "$c")" = 2 ]' "refused: ${c:0:70}"
done
ok '[ "$(run "$(printf "claude -p '"'"'x\ny'"'"' --model sonnet --allowedTools Read,Grep,Glob")")" = 2 ]' "refused: a newline inside the prompt"
ok '[ "$(run "claude -p '"'"'$(id) \`id\` $HOME'"'"' --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob")" = 0 ]' "single-quoted text is literal: \$(...) and backticks inside the quotes are data, not a command"
long=$(head -c 4001 /dev/zero | tr '\0' 'a'); ok '[ "$(run "claude -p '"'"'$long'"'"' --model sonnet --allowedTools Read,Grep,Glob")" = 2 ]' "refused: a prompt over 4000 characters"

# follow-up 2: the 9B driver wrote the prompt in double quotes on the live run and was refused; a double-quoted prompt is allowed when
# nothing in it can be expanded by the shell (no $, backtick, backslash, double quote, !, newline)
ok '[ "$(run "claude -p \"Check that docs/colour.txt holds blue\" --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob")" = 0 ]' "a double-quoted prompt with plain words is allowed"
ok '[ "$(run "claude -p \"Check the file '"'"'colour.txt'"'"' (it should say blue)\" --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob")" = 0 ]' "single quotes and brackets inside a double-quoted prompt are allowed"
for c in \
  'claude -p "run $(id)" --model sonnet --allowedTools Read,Grep,Glob' \
  'claude -p "echo $HOME" --model sonnet --allowedTools Read,Grep,Glob' \
  'claude -p "a `id` b" --model sonnet --allowedTools Read,Grep,Glob' \
  'claude -p "a \" b" --model sonnet --allowedTools Read,Grep,Glob' \
  'claude -p "hist !!" --model sonnet --allowedTools Read,Grep,Glob' \
  'claude -p "x"; id --model sonnet --allowedTools Read,Grep,Glob' \
  'claude -p "x" --model sonnet --allowedTools Read,Grep,Glob; id' \
  "claude -p \"'Verify (echo \$cat /workspace/x | od -c)'\" --model sonnet --allowedTools Read,Grep,Glob" \
  'claude -p "" --model sonnet --allowedTools Read,Grep,Glob'; do
  ok '[ "$(run "$c")" = 2 ]' "refused: ${c:0:70}"
done
# --- follow-up 2, fix round 1 (red-team S6E-02, S6E-03, S6E-05): the call is pinned to --restricted, builder code never runs here ---
N=" --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob"
ok '[ "$(run "claude -p x2 --model sonnet --allowedTools Read,Grep,Glob")" = 2 ]' "refused: the old shape without --restricted (a builder's project settings would apply)"
ok '[ "$(run "claude -p '"'"'x'"'"' --model sonnet --allowedTools Read,Grep,Glob")" = 2 ]' "refused: the old shape with a quoted prompt and no --restricted"
for flagless in "--restricted" "--strict-mcp-config" "--tools Read,Grep,Glob"; do
  ok '[ "$(run "claude -p '"'"'x'"'"' --model sonnet --allowedTools Read,Grep,Glob $flagless")" = 2 ]' "refused: the old shape with only ${flagless} appended (the order and the full set are fixed)"
done
for c in "npm test" "npm run test" "npm run lint" "node --test"; do
  ok '[ "$(run "$c")" = 2 ]' "refused for the Claude reviewer: $c (it would run the builder's code next to the login)"
done
for c in \
  "claude -p '--allowedTools=Bash,Write,Edit'$N" \
  "claude -p '--settings={}'$N" \
  "claude -p '--'$N" \
  "claude -p '-d'$N" \
  "claude -p \"--permission-mode=bypassPermissions\"$N" \
  "claude -p \"--add-dir=/\"$N" \
  "claude -p ' --tools=Bash'$N" \
  "claude -p \" -x\"$N" \
  "claude -p 'x'$N --add-dir /" \
  "claude -p 'x'$N --settings /tmp/s.json" \
  "claude -p 'x' --model sonnet --restricted --strict-mcp-config --tools Bash --allowedTools Read,Grep,Glob" \
  "claude -p 'x' --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob,Bash --allowedTools Read,Grep,Glob"; do
  ok '[ "$(run "$c")" = 2 ]' "refused: ${c:0:72}"
done
ok '[ "$(run "claude -p '"'"'a-b --c'"'"'$N")" = 0 ]' "a dash inside the prompt (not first) is allowed"
ok '[ "$(run "$P" process_manage)" = 2 ]' "process_manage is never allowed"
ok '[ "$(echo "not json" | bash "$H" >/dev/null 2>&1; echo $?)" = 2 ]' "unreadable hook input is refused (fail closed)"
ok 'grep -q "\"action\": \"block\"" "$T/out"' "a refusal answers with the block message"

# the role table: the 9B reviewer keeps test-only-terminal, reviewer-claude gets only the Claude hook, both are boxed reviewers
RJ=$R/docs/hermes-local/roles.json
ok 'jq -e ".profiles[\"reviewer-claude\"] | .role == \"reviewer\" and .worker == \"claude-code\" and (.soul | length > 0)" "$RJ" >/dev/null' "roles.json: reviewer-claude is a reviewer running the claude-code worker kind"
ok 'jq -e ".profiles.reviewer.worker == \"opencode\" and (.roles.reviewer.workers == [\"opencode\", \"claude-code\"])" "$RJ" >/dev/null' "roles.json: the reviewer role lists both worker kinds and the 9B reviewer is opencode"
ok 'jq -e "[.roles.reviewer.hooks[] | select(.file != null and (.file | endswith(\"test-only-terminal.sh\")))] | length == 1 and .[0].workers == [\"opencode\"]" "$RJ" >/dev/null' "roles.json: test-only-terminal is for the opencode reviewer only"
ok 'jq -e "[.roles.reviewer.hooks[] | select(.file != null and (.file | endswith(\"claude-review-terminal.sh\")))] | length == 1 and .[0].workers == [\"claude-code\"] and .[0].matcher == \"^(terminal|process_manage)\$\"" "$RJ" >/dev/null' "roles.json: claude-review-terminal is for the claude-code reviewer only, on terminal and process_manage"
ok 'jq -e ".sandbox.boxed_profiles | index(\"reviewer-claude\")" "$RJ" >/dev/null' "roles.json: reviewer-claude is a boxed profile"
ok 'jq -e ".sandbox.profile_overrides[\"reviewer-claude\"] == .sandbox.profile_overrides[\"builder-claude\"]" "$RJ" >/dev/null' "roles.json: the Claude config dir and read-only overlays of reviewer-claude equal builder-claude's (its login lives in its own home)"
mkdir -p "$T/root/profiles/builder-local" "$T/root/profiles/builder-claude" "$T/root/profiles/reviewer" "$T/root/profiles/reviewer-claude"
sp=$(python3 -I "$R/bin/roles.py" spec "$T/root" 2>&1)
ok 'jq -e ".\"reviewer-claude\".hook_files | tostring | test(\"claude-review-terminal.sh\") and (test(\"test-only-terminal.sh\") | not)" <<<"$sp" >/dev/null' "roles.py spec: reviewer-claude gets the Claude hook and not test-only-terminal"
ok 'jq -e ".reviewer.hook_files | tostring | test(\"test-only-terminal.sh\") and (test(\"claude-review-terminal.sh\") | not)" <<<"$sp" >/dev/null' "roles.py spec: the 9B reviewer keeps test-only-terminal and gets no Claude hook"
ok 'jq -e ".\"reviewer-claude\".hook_files | tostring | test(\"deny-write.sh\") and test(\"secret-guard.py\")" <<<"$sp" >/dev/null' "roles.py spec: reviewer-claude keeps the write refusal and the secret guard"
ok '[ -s "$R/docs/hermes-local/soul/reviewer-claude.md" ] && grep -q "claude -p" "$R/docs/hermes-local/soul/reviewer-claude.md" && grep -q "allowedTools Read,Grep,Glob" "$R/docs/hermes-local/soul/reviewer-claude.md"' "the SOUL names the one allowed call"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
