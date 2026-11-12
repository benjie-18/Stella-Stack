#!/usr/bin/env bash
# Fallback role (a profile with no row in roles.json, D46): block every write and every tool no other matcher names; it opens nothing (exit 2 = block).
cat >/dev/null
printf '{"action": "block", "message": "This profile has no row in the role table, so its role opens nothing: it writes no files and runs no tool beyond reading. Ask the owner to add the profile to docs/hermes-local/roles.json."}\n'
exit 2
