#!/usr/bin/env bash
# Reviewer role, claude-code worker kind (Stage 6 follow-up 2, D92, D97). The terminal may run the 9B reviewer's read-only git (via
# test-only-terminal.sh, which this hook hands every other command to; its npm/node test commands are refused here) plus ONE Claude
# Code call that can only read: claude -p '<prompt>' --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob
# --allowedTools Read,Grep,Glob. The prompt is one quoted piece of text, 1-4000 characters, not starting with "-" or a blank:
# single-quoted (no quote, no newline; nothing inside is expanded) or double-quoted when it holds no $, backtick, backslash,
# double quote or ! (nothing the shell would expand). Nothing may follow the closing quote but the fixed flags. Fail closed:
# unreadable input, a missing partner hook or any other shape is refused (exit 2).
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
payload=$(cat)
cmd=$(jq -r 'if .tool_name == "terminal" then .tool_input.command // "" else "" end' <<<"$payload" 2>/dev/null) || cmd=""
tail=" --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob"; nl=$'\n\r'
# the prompt may not start with "-" or a blank (Claude would read it as an option); --restricted makes Claude ignore the project's own
# settings and hooks (the builder writes them) and confine its file tools to the working folder
re1="^claude -p '[^'${nl}[:space:]-][^'${nl}]{0,3999}'${tail}\$"   # single quotes: nothing inside is expanded
re2="^claude -p \"[^\"\$\`\\\\!${nl}[:space:]-][^\"\$\`\\\\!${nl}]{0,3999}\"${tail}\$"   # double quotes: only when nothing in it can be expanded
[[ -n $cmd && ( $cmd =~ $re1 || $cmd =~ $re2 ) ]] && exit 0
# builder code never runs next to the Claude login: the 9B reviewer's npm test / lint / node --test are not offered here
case "$cmd" in "npm test"|"npm run test"|"npm run lint"|"node --test") printf '%s\n' '{"action": "block", "message": "the Claude reviewer reads the work with its one Claude call and read-only git; it never runs the builder code"}'; exit 2;; esac
partner=/workspace/docs/hermes-local/hooks/reviewer/test-only-terminal.sh
[ -f "$partner" ] || { printf '%s\n' '{"action": "block", "message": "the Claude reviewer terminal hook cannot find its partner hook"}'; exit 2; }
printf '%s' "$payload" | bash "$partner"
exit $?
