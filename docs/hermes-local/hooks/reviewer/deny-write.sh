#!/usr/bin/env bash
# Reviewer role (D46) is read-only: block every file-writing tool call: write_file, patch, skill_manage (F9) (pre_tool_call, exit 2 = block).
cat >/dev/null
printf '{"action": "block", "message": "the reviewer role is read-only: write_file/patch/skill_manage are blocked"}\n'
exit 2
