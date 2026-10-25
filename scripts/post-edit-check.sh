#!/usr/bin/env bash
# Claude Code PostToolUse hook: run the project's test and lint scripts after a file edit.
# Exit 2 sends the failure output back to the agent as a blocking error.
set -uo pipefail
cd "${CLAUDE_PROJECT_DIR:-/workspace}" || exit 1
cat >/dev/null  # hook input JSON is not needed

for script in test lint; do
  if ! out=$(npm run --silent "$script" 2>&1); then
    printf 'npm run %s failed:\n%s\n' "$script" "$out" | tail -n 40 >&2
    exit 2
  fi
done
exit 0
