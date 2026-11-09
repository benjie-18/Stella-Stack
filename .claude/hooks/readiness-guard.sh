#!/usr/bin/env bash
# PreToolUse hook for the readiness run (Claude Code, not Hermes).
# 1. Edit/Write/MultiEdit/NotebookEdit on a "live" file (one cron or a hook runs) is refused: write a temp copy
#    in the same directory, check it, then mv it over (atomic replace). The list is data:
#    .scratch/readiness/live-files.txt, one repo-relative path per line, generated in Part 0. No list = no check.
# 2. Read/Edit/Write of an owner settings file is refused (agents never read or write owner settings values).
#    The list is data too: .scratch/readiness/owner-files.txt (repo-relative paths). No list = config/owner.env.
# Exit 2 with a reason on stderr = refuse (Claude Code shows the reason to the model). Any other case: exit 0.
set -uo pipefail
root=${CLAUDE_PROJECT_DIR:-$(pwd)}
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null) || exit 0
[ -n "$path" ] || exit 0
case "$path" in /*) abs=$path ;; *) abs=$root/$path ;; esac
abs=$(realpath -m -- "$abs" 2>/dev/null || printf '%s' "$abs")
rel=${abs#"$root"/}

owner_list="$root/.scratch/readiness/owner-files.txt"
if [ -f "$owner_list" ]; then mapfile -t owners < <(grep -v '^\s*\(#\|$\)' "$owner_list"); else owners=(config/owner.env); fi
for o in "${owners[@]}"; do
  if [ "$rel" = "$o" ]; then
    echo "readiness-guard: $rel holds owner settings. Agents never read or write its values (the owner's rule). Check its shape with a script that prints key names and parse results only, or put the change in a HUMAN CHECKPOINT." >&2
    exit 2
  fi
done

case "$tool" in Edit|Write|MultiEdit|NotebookEdit) ;; *) exit 0 ;; esac
live_list="$root/.scratch/readiness/live-files.txt"
[ -f "$live_list" ] || exit 0
if grep -qxF -- "$rel" <(grep -v '^\s*\(#\|$\)' "$live_list"); then
  echo "readiness-guard: $rel is run by cron or a hook. Do not edit it in place: write the new version to a temp file in the same directory (for example $rel.new), run bash -n or py_compile and its selftest on the copy, then mv it over the original with Bash." >&2
  exit 2
fi
exit 0
