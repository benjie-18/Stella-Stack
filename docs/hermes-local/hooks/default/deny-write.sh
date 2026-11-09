#!/usr/bin/env bash
# Dispatcher role (D35, D46): block every file-writing tool call (write_file, patch, execute_code, skill_manage, cronjob_manage (D42); exit 2 = block).
cat >/dev/null
printf '{"action": "block", "message": "Dispatchers do not write files: create a card for a worker instead."}\n'
exit 2
