#!/usr/bin/env bash
# Catch-all of a role that runs outside the OS box (roles.json runs_unboxed, D46): blocks any tool name no other matcher of the role names (exit 2 = block).
cat >/dev/null
printf '{"action": "block", "message": "This tool is not one this profile may use: its role names the tools it has, and a tool that is added later is refused until the role table names it (docs/hermes-local/roles.json)."}\n'
exit 2
