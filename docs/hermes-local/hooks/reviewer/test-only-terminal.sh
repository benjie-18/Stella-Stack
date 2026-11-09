#!/usr/bin/env bash
# Reviewer role (D46) may run tests, nothing else: allow an exact test command on `terminal`, block everything else (exit 2).
cmd=$(jq -r 'if .tool_name == "terminal" then .tool_input.command // "" else "" end')
case "$cmd" in
  "npm test"|"npm run test"|"npm run lint"|"node --test") exit 0 ;;
  *$'\n'*|*$'\r'*) ;;
  *) # K9: read-only git to check a commit's scope. A revision never starts with "-" (no --output), no shell metacharacter.
     rev='[A-Za-z0-9_][A-Za-z0-9_./^~-]*'
     [[ $cmd =~ (^|[ /])\.\.(/|\ |$) ]] && cmd=refused   # RT6-02: no .. path segment (A..B ranges stay allowed)
     [[ $cmd =~ ^git(\ -C\ /[A-Za-z0-9_./-]*)?\ (show\ --(stat|name-only)|log\ --oneline(\ -n\ [0-9]+)?)(\ $rev(\.\.\.?$rev)?)*$ ]] && exit 0
     # RT6-02: diff takes exactly one revision range, so it never compares two files outside a repo
     [[ $cmd =~ ^git(\ -C\ /[A-Za-z0-9_./-]*)?\ diff\ --(name-only|stat)\ $rev\.\.\.?$rev$ ]] && exit 0 ;;
esac
printf '{"action": "block", "message": "the reviewer role: terminal is limited to npm test, npm run test, npm run lint, node --test, and read-only git diff --name-only/--stat, git show --stat/--name-only, git log --oneline [-n N]"}\n'
exit 2
