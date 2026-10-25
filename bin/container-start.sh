#!/usr/bin/env bash
# Container-start (postStart) user-space restore: ~/.config and the crontab do not survive a rebuild.
# Sources of truth: /workspace (bind mount) and the ~/.hermes volume.
set -euo pipefail
crontab /workspace/bin/crontab.txt
mkdir -p ~/.config/opencode/skills
# OpenCode user config: local model only (never a cloud fallback) + the Claude-account skill denies.
# brainstorming is dropped: superpowers is a project-scope OpenCode plugin, so its deny stays in the repo config.
jq '{"$schema", model, providers, permission: {skill: (.permission.skill | del(.brainstorming))}}' \
  /workspace/opencode.json > ~/.config/opencode/opencode.json
# Vetted anti-ai-slop-writing (jalaalrd/anti-ai-slop-writing@63255f9), kept in the ~/.hermes volume.
cp -r ~/.hermes/skills/writing/anti-ai-slop-writing ~/.config/opencode/skills/
