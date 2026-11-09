#!/usr/bin/env bash
# Claude Code PostToolUse hook: run the project's lint script after a file edit.
# Not the test script: the suite takes 11-13 min against this hook's 120 s timeout, so every edit would stall and lint
# would never run. The 15-minute watchdog (bin/watchdog.sh) runs the suite.
# Exit 2 sends the failure output back to the agent as a blocking error.
set -uo pipefail
cd "${CLAUDE_PROJECT_DIR:-/workspace}" || exit 1
cat >/dev/null  # hook input JSON is not needed

if ! out=$(npm run --silent lint 2>&1); then
  printf 'npm run lint failed:\n%s\n' "$out" | tail -n 40 >&2
  exit 2
fi
exit 0
