#!/usr/bin/env bash
# Reviewer role (D46) may run tests, nothing else: allow an exact test command on `terminal`, block everything else (exit 2).
payload=$(cat)
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
refuse() {   # B.1 (r5) refuse <problem> <message>: the one way a hook refuses (bin/roles.py hook-refusal: the catalog code, one alert line per call naming the role)
  local m; m=$(printf '%s' "$payload" | python3 -I /workspace/bin/roles.py hook-refusal STL-GRD-604 "$1" 2>/dev/null) || m=
  jq -nc --arg m "${m:-[STL-GRD-604]} $2" '{action: "block", message: $m}'; exit 2; }
cmd=$(jq -r 'if .tool_name == "terminal" then .tool_input.command // "" else "" end' <<<"$payload")
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
refuse "a command the role's terminal does not run" 'the reviewer role: terminal is limited to npm test, npm run test, npm run lint, node --test, and read-only git diff --name-only/--stat, git show --stat/--name-only, git log --oneline [-n N]'
