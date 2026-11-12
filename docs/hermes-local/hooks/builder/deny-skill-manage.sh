#!/usr/bin/env bash
# Builders do not write skills (batch 6): block skill_manage in every profile whose role installs this hook (roles.json, D46) (pre_tool_call, exit 2 = block).
cat >/dev/null
printf '{"action": "block", "message": "builders do not edit skills, schedule jobs or run code inside the agent: skill_manage, execute_code and cronjob_manage are blocked (write files in your worktree with the file tools or the terminal)"}\n'
exit 2
