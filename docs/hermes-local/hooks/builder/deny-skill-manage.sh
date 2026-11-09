#!/usr/bin/env bash
# Builders do not write skills (batch 6): block skill_manage in every profile whose role installs this hook (roles.json, D46) (pre_tool_call, exit 2 = block).
cat >/dev/null
printf '{"action": "block", "message": "builders do not edit skills or agent configuration: skill_manage is blocked"}\n'
exit 2
