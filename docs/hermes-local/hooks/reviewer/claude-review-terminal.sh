#!/usr/bin/env bash
# Reviewer role, claude-code worker kind (Stage 6 follow-up 2, D92, D97; follow-up 4, item 5). The terminal may run the 9B reviewer's read-only git
# (via test-only-terminal.sh, which this hook hands every other command to; its npm/node test commands are refused here) plus ONE command:
# the stack's own review script, with no arguments. The script (bin/claude-review.sh) asks Claude the question the owner's fixed template
# builds from the card (see box.py _review_prompt), so the driver model never writes the prompt and cannot frame it. Every other `claude`
# command is refused with the exact command to use. Fail closed: unreadable input, a missing partner hook or any other shape is refused (exit 2).
payload=$(cat)
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
refuse() {   # B.1 (r5) refuse <problem> <message>: the one way a hook refuses (bin/roles.py hook-refusal: the catalog code, one alert line per call naming the role)
  local m t=$2; [[ $t == '{'* ]] && t=$(jq -r .message <<<"$t")   # this hook's messages are written as their JSON line
  m=$(printf '%s' "$payload" | python3 -I /workspace/bin/roles.py hook-refusal STL-GRD-604 "$1" 2>/dev/null) || m=
  jq -nc --arg m "${m:-[STL-GRD-604]} $t" '{action: "block", message: $m}'; exit 2; }
allow() {   # r6: an allow needs a valid role table, as every guard (bin/roles.py hook-allow); a broken table or a role tool that cannot start refuses
  local m; m=$(printf '%s' "$payload" | python3 -I /workspace/bin/roles.py hook-allow 2>/dev/null) && exit 0
  jq -nc --arg m "${m:-[STL-CFG-303] the role table could not be checked by this hook}" '{action: "block", message: $m}'; exit 2; }
cmd=$(jq -r 'if .tool_name == "terminal" then .tool_input.command // "" else "" end' <<<"$payload" 2>/dev/null) || cmd=""
allowed="bash /workspace/bin/claude-review.sh"
bg=$(jq -r 'if (.tool_input.background == true or .tool_input.pty == true) then "yes" else "" end' <<<"$payload" 2>/dev/null) || bg=""
if [[ -n $cmd && $cmd == "$allowed" ]] && jq -e --arg a "$allowed" '.tool_input.command == $a' <<<"$payload" >/dev/null 2>&1; then
  [[ -z $bg ]] && allow
  refuse "a command the role's review terminal does not run" '{"action": "block", "message": "run the review command in the foreground (no background, no pty): its answer is read from the command output and a background run can never be read"}'
fi
# builder code never runs next to the Claude login: the 9B reviewer's npm test / lint / node --test are not offered here
case "$cmd" in "npm test"|"npm run test"|"npm run lint"|"node --test") refuse "a command the role's review terminal does not run" '{"action": "block", "message": "this profile reads the work with its one review command and read-only git; it never runs the builder code"}';; esac
# any other claude call: say what the one allowed command is (live T7e: told only about npm test, the driver gave up)
if [[ $cmd =~ (^|[^[:alnum:]_/.-])claude([^[:alnum:]_-]|$)|claude-review ]]; then refuse "a command the role's review terminal does not run" '{"action": "block", "message": "your one Claude call is the command '"$allowed"' with nothing before or after it (no cd, no arguments, no redirect; set the terminal workdir to your workspace_path). The stack builds the question from the card; you do not write it."}'; fi
case "$cmd" in "cd "*) refuse "a command the role's review terminal does not run" '{"action": "block", "message": "no cd: the terminal already starts in your workspace. Run your command without cd, and run your one review command first: '"$allowed"' (nothing before or after it)."}';; esac
partner=/workspace/docs/hermes-local/hooks/reviewer/test-only-terminal.sh
[ -f "$partner" ] || { refuse "a command the role's review terminal does not run" '{"action": "block", "message": "this terminal hook cannot find its partner hook"}'; }
printf '%s' "$payload" | bash "$partner"
exit $?
