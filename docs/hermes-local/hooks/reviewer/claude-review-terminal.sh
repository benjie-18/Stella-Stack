#!/usr/bin/env bash
# Reviewer role, claude-code worker kind (Stage 6 follow-up 2, D92, D97; follow-up 4, item 5). The terminal may run the 9B reviewer's read-only git
# (via test-only-terminal.sh, which this hook hands every other command to; its npm/node test commands are refused here) plus ONE command:
# the stack's own review script, with no arguments. The script (bin/claude-review.sh) asks Claude the question the owner's fixed template
# builds from the card (see box.py _review_prompt), so the driver model never writes the prompt and cannot frame it. Every other `claude`
# command is refused with the exact command to use. Fail closed: unreadable input, a missing partner hook or any other shape is refused (exit 2).
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
payload=$(cat)
cmd=$(jq -r 'if .tool_name == "terminal" then .tool_input.command // "" else "" end' <<<"$payload" 2>/dev/null) || cmd=""
allowed="bash /workspace/bin/claude-review.sh"
bg=$(jq -r 'if (.tool_input.background == true or .tool_input.pty == true) then "yes" else "" end' <<<"$payload" 2>/dev/null) || bg=""
if [[ -n $cmd && $cmd == "$allowed" ]]; then
  [[ -z $bg ]] && exit 0
  printf '%s\n' '{"action": "block", "message": "run the review command in the foreground (no background, no pty): its answer is read from the command output and a background run can never be read"}'; exit 2
fi
# builder code never runs next to the Claude login: the 9B reviewer's npm test / lint / node --test are not offered here
case "$cmd" in "npm test"|"npm run test"|"npm run lint"|"node --test") printf '%s\n' '{"action": "block", "message": "this profile reads the work with its one review command and read-only git; it never runs the builder code"}'; exit 2;; esac
# any other claude call: say what the one allowed command is (live T7e: told only about npm test, the driver gave up)
if [[ $cmd =~ (^|[^[:alnum:]_/.-])claude([^[:alnum:]_-]|$)|claude-review ]]; then printf '%s\n' '{"action": "block", "message": "your one Claude call is the command '"$allowed"' with nothing before or after it (no cd, no arguments, no redirect; set the terminal workdir to your workspace_path). The stack builds the question from the card; you do not write it."}'; exit 2; fi
partner=/workspace/docs/hermes-local/hooks/reviewer/test-only-terminal.sh
[ -f "$partner" ] || { printf '%s\n' '{"action": "block", "message": "this terminal hook cannot find its partner hook"}'; exit 2; }
printf '%s' "$payload" | bash "$partner"
exit $?
