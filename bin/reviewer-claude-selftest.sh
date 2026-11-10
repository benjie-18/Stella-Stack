#!/usr/bin/env bash
# Hermetic self-test for the Claude-backed reviewer (Stage 6 follow-up 2, D92): profile "reviewer-claude" is a second reviewer, worker
# kind claude-code. Its terminal may run the reviewer's own test/read-only-git commands plus ONE exact Claude Code call that can only
# read (Read, Grep, Glob; model sonnet). The 9B "reviewer" keeps its old hook. No Claude call, no login, no board.
set -u
R=/workspace; H=$R/docs/hermes-local/hooks/reviewer/claude-review-terminal.sh; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
jq() { env -u HOME jq "$@"; }
run() { jq -nc --arg c "$1" --arg t "${2:-terminal}" '{hook_event_name: "pre_tool_call", tool_name: $t, tool_input: {command: $c}}' | bash "$H" >"$T/out" 2>&1; echo $?; }
OLD="claude -p 'Check that docs/colour.txt holds the colour the owner chose' --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob"
P="bash /workspace/bin/claude-review.sh"

ok '[ -f "$H" ] && bash -n "$H"' "the hook exists and parses"
ok '[ "$(run "$P")" = 0 ]' "the stack's review command (no arguments) is allowed"
ok '[ "$(run "claude -p '"'"'x'"'"' --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob")" = 2 ]' "refused (follow-up 4): the old direct claude -p call with a one-letter prompt"
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
ok '[ "$(run "claude -p '"'"'$(id) \`id\` $HOME'"'"' --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob")" = 2 ]' "refused (follow-up 4): the old direct claude -p call with shell syntax in single quotes"
long=$(head -c 4001 /dev/zero | tr '\0' 'a'); ok '[ "$(run "claude -p '"'"'$long'"'"' --model sonnet --allowedTools Read,Grep,Glob")" = 2 ]' "refused: a prompt over 4000 characters"

# follow-up 2: the 9B driver wrote the prompt in double quotes on the live run and was refused; a double-quoted prompt is allowed when
# nothing in it can be expanded by the shell (no $, backtick, backslash, double quote, !, newline)
ok '[ "$(run "claude -p \"Check that docs/colour.txt holds blue\" --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob")" = 2 ]' "refused (follow-up 4): the old direct claude -p call with a double-quoted prompt"
ok '[ "$(run "claude -p \"Check the file '"'"'colour.txt'"'"' (it should say blue)\" --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob")" = 2 ]' "refused (follow-up 4): the old direct claude -p call, double quotes with single quotes inside"
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
ok '[ "$(run "claude -p '"'"'a-b --c'"'"'$N")" = 2 ]' "refused (follow-up 4): the old direct claude -p call with a dash inside the prompt"
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
ok 'jq -e "(.sandbox.profile_overrides[\"reviewer-claude\"] | del(.hide_files, .broker_env, .broker_when, .review_prompt, .review_model, .review_max_files, .review_max_mb)) == .sandbox.profile_overrides[\"builder-claude\"]" "$RJ" >/dev/null' "roles.json: the Claude config dir and read-only overlays of reviewer-claude equal builder-claude's apart from hide_files, broker_env, broker_when, review_prompt and review_model (follow-up 4, its login lives in its own home)"
mkdir -p "$T/root/profiles/builder-local" "$T/root/profiles/builder-claude" "$T/root/profiles/reviewer" "$T/root/profiles/reviewer-claude"
sp=$(python3 -I "$R/bin/roles.py" spec "$T/root" 2>&1)
ok 'jq -e ".\"reviewer-claude\".hook_files | tostring | test(\"claude-review-terminal.sh\") and (test(\"test-only-terminal.sh\") | not)" <<<"$sp" >/dev/null' "roles.py spec: reviewer-claude gets the Claude hook and not test-only-terminal"
ok 'jq -e ".reviewer.hook_files | tostring | test(\"test-only-terminal.sh\") and (test(\"claude-review-terminal.sh\") | not)" <<<"$sp" >/dev/null' "roles.py spec: the 9B reviewer keeps test-only-terminal and gets no Claude hook"
ok 'jq -e ".\"reviewer-claude\".hook_files | tostring | test(\"deny-write.sh\") and test(\"secret-guard.py\")" <<<"$sp" >/dev/null' "roles.py spec: reviewer-claude keeps the write refusal and the secret guard"
ok '[ -s "$R/docs/hermes-local/soul/reviewer-claude.md" ] && grep -q "claude-review.sh" "$R/docs/hermes-local/soul/reviewer-claude.md"' "the SOUL names the one allowed call"
# follow-up 4, item 5: the driver never writes the question. Anything but the exact review command is refused, and a refused claude call is told the command.
ok '[ "$(run "$OLD")" = 2 ] && grep -q "bash /workspace/bin/claude-review.sh" "$T/out" && grep -q "nothing before or after it" "$T/out"' "a refused claude call says which command to run, with nothing around it"
ok '[ "$(run "git status")" = 2 ] && ! grep -q "claude-review" "$T/out"' "a refused non-claude command keeps its own message"
for c in "$P " " $P" "$P --help" "$P x" "$P; id" "$P && id" "$P | cat" "$P > /tmp/o" "cd /tmp && $P" "sh /workspace/bin/claude-review.sh" "bash bin/claude-review.sh" "bash /workspace/bin/claude-review.sh/" "bash /workspace/bin/../bin/claude-review.sh" "bash /tmp/claude-review.sh" "REVIEW_PROMPT_FILE=/tmp/p $P" "env REVIEW_PROMPT_FILE=/tmp/p $P" "claude -p 'x'" "claude" "bash /workspace/bin/claude-review.sh
id"; do
  ok '[ "$(run "$c")" = 2 ]' "refused: the review command with anything around it or changed: ${c:0:50}"
done
# red-team S6L-L1: read-only git on a branch whose NAME contains "claude" is still read-only git, not a refused claude call
for c in "git log --oneline -n 5 proj/t_1-claude-docs" "git show --stat proj/claude-fix" "git diff --name-only main...proj/t_2-claude"; do
  ok '[ "$(run "$c")" = 0 ]' "read-only git on a branch with claude in its name passes: $c"
done
ok '[ "$(run "cd /tmp && claude -p x")" = 2 ] && grep -q "claude-review.sh" "$T/out" && grep -q workdir "$T/out" && [ "$(run "(claude -p x)")" = 2 ] && [ "$(run "echo hi; claude")" = 2 ]' "a claude command anywhere else on the line is still refused with the hint"
bg() { jq -nc --arg c "$1" '{hook_event_name: "pre_tool_call", tool_name: "terminal", tool_input: ({command: $c} + $x)}' --argjson x "$2" | bash "$H" >"$T/out" 2>&1; echo $?; }
ok '[ "$(bg "$P" "{\"background\":true}")" = 2 ] && grep -qi "background" "$T/out" && [ "$(bg "$P" "{\"pty\":true}")" = 2 ] && [ "$(bg "$P" "{\"background\":false}")" = 0 ]' "red-team S6M-RA-01: the review command is refused as a background or pty run (its answer could never be read)"
ok 'jq -e ".sandbox.profile_overrides[\"reviewer-claude\"] | (.review_max_files | type == \"number\" and . > 0) and (.review_max_mb | type == \"number\" and . > 0) and (.review_model | length > 0) and (.review_prompt | length > 0) and (.broker_when | length > 0)" "$RJ" >/dev/null' "the shipped table gives the Claude reviewer every review setting the box needs (live: a missing cap refused the first smoke run)"
ok 'jq -e "[\"ANTHROPIC_API_KEY\", \"ANTHROPIC_AUTH_TOKEN\", \"CLAUDE_CODE_OAUTH_TOKEN\"] - (.sandbox.env_unset // []) | length == 0" "$RJ" >/dev/null' "the shipped table removes the three Claude credential variables from every box environment (rule T3, red-team S6N-03)"
ok '[ -x "$R/bin/claude-review.sh" ] && bash -n "$R/bin/claude-review.sh"' "the review script exists, is executable and parses"
# the script itself, with a fake claude that records its arguments
mkdir -p "$T/fakebin"; printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$FAKE_ARGS"\necho "APPROVE (fake)"\n' >"$T/fakebin/claude"; chmod +x "$T/fakebin/claude"
printf 'FIXED TEMPLATE TEXT\nCARD t_9: body\n' >"$T/review-prompt.txt"
sendit() { ( cd "$T" && PATH="$T/fakebin:$PATH" FAKE_ARGS="$T/args.out" REVIEW_PROMPT_FILE="$1" REVIEW_SENT_FILE="$T/sent.out" REVIEW_MODEL="${MODEL-themodel}" REVIEW_EXPORT_DIR="${EXPORT_DIR-$T/export}" bash "$R/bin/claude-review.sh" "${@:2}" ); }
mkdir -p "$T/export"; echo committed >"$T/export/f.txt"
ok 'out=$(sendit "$T/review-prompt.txt") && [ "$out" = "APPROVE (fake)" ] && [ "$(sed -n 1p "$T/args.out")" = "-p" ] && [ "$(sed -n 2,3p "$T/args.out")" = "$(printf "FIXED TEMPLATE TEXT\nCARD t_9: body")" ]' "the script sends exactly the rendered prompt to claude -p and prints the answer"
ok 'grep -qx -- "--model" "$T/args.out" && grep -qx themodel "$T/args.out" && grep -qx -- "--restricted" "$T/args.out" && grep -qx -- "--strict-mcp-config" "$T/args.out" && [ "$(grep -c "^Read,Grep,Glob$" "$T/args.out")" = 2 ]' "it passes the pinned read-only flags (restricted, strict MCP, Read/Grep/Glob only)"
ok 'cmp -s "$T/review-prompt.txt" "$T/sent.out"' "it leaves a copy of what it sent in the file the box names (REVIEW_SENT_FILE)"
# red-team S6M-RC C-05/C-06 and S6M-RA-01 (stderr): Claude gets no worktree git variables and no project instruction files; only stdout is the answer
printf '#!/bin/sh\nenv > "$FAKE_ENV"\necho STDERR-NOISE >&2\necho "APPROVE (fake)"\n' >"$T/fakebin/claude"; chmod +x "$T/fakebin/claude"
ok 'GIT_DIR=/x GIT_WORK_TREE=/y FAKE_ENV="$T/env.out" sendit "$T/review-prompt.txt" >"$T/ans.out" 2>/dev/null && ! grep -q "^GIT_DIR=\|^GIT_WORK_TREE=" "$T/env.out" && grep -qx "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1" "$T/env.out" && grep -qx "CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1" "$T/env.out"' "Claude runs without GIT_DIR/GIT_WORK_TREE and with project instruction files and git instructions switched off"
ok '[ "$(head -c 7 "$T/ans.out")" = APPROVE ] && ! grep -q STDERR-NOISE "$T/ans.out"' "Claude's stderr is not part of the answer (a stderr line before the answer must not turn APPROVE into something else)"
printf '#!/bin/sh\necho "Failed to authenticate" >&2\nexit 1\n' >"$T/fakebin/claude"; chmod +x "$T/fakebin/claude"
ok '! sendit "$T/review-prompt.txt" >"$T/ans2.out" 2>&1 && grep -q "Failed to authenticate" "$T/ans2.out"' "when Claude fails its stderr is shown and the exit code is kept"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$FAKE_ARGS"\necho "APPROVE (fake)"\n' >"$T/fakebin/claude"; chmod +x "$T/fakebin/claude"
ok '! sendit "$T/review-prompt.txt" extra 2>/dev/null' "it refuses arguments"
ok '! MODEL="" sendit "$T/review-prompt.txt" 2>/dev/null' "it refuses to run without a model from the data"
ok '! sendit "$T/missing.txt" 2>/dev/null && ! sendit "" 2>/dev/null' "it refuses to run without a rendered prompt"
ok '! EXPORT_DIR="" sendit "$T/review-prompt.txt" 2>/dev/null && ! EXPORT_DIR="$T/nodir" sendit "$T/review-prompt.txt" 2>/dev/null' "it refuses to run without an exported committed tree"
printf '#!/bin/sh\npwd > "$FAKE_PWD"\necho "APPROVE (fake)"\n' >"$T/fakebin/claude"; chmod +x "$T/fakebin/claude"
ok 'FAKE_PWD="$T/pwd.out" sendit "$T/review-prompt.txt" >/dev/null && [ "$(cat "$T/pwd.out")" = "$T/export" ]' "Claude runs inside the exported committed tree, whatever folder the terminal started in (red-team S6L-RT-09)"
: >"$T/empty.txt"; ok '! sendit "$T/empty.txt" 2>/dev/null' "it refuses an empty prompt file"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
