#!/usr/bin/env bash
# Container-start (postStart) user-space restore: ~/.config and the crontab do not survive a rebuild.
# Sources of truth: /workspace (bind mount) and the ~/.hermes volume.
# Every step is non-fatal (S7): a failure logs one line to stderr and the next step runs, so the gateway start that
# follows in postStart (and in docs/stella-recover.ps1) is never skipped. Exit 1 at the end names the failed steps.
set -uo pipefail
. /workspace/bin/owner-config.sh   # once_per_hour only
failed=""
fail() { echo "container-start: $1" >&2; failed="$failed ${1%% *}"; }
crontab /workspace/bin/crontab.txt || fail "crontab failed (exit $?)"
mkdir -p ~/.config/opencode/skills || fail "mkdir ~/.config/opencode/skills failed"
# git refuses a repo whose owner it cannot match (bind mount): trust the stack folder, derived from this script's place (D48).
ws=$(cd "$(dirname "$0")/.." && pwd)
git config --global --get-all safe.directory | grep -qxF "$ws" || git config --global --add safe.directory "$ws" \
  || fail "git safe.directory not set for $ws"
# OpenCode user config: local model only (never a cloud fallback) + the Claude-account skill denies.
# The model is data (F2 W7b): the first model of the connections catalog's enabled local provider, with its advertised
# capabilities and its `limits.output_tokens`; the tracked opencode.json holds the provider frame and names no model.
# shortcut: that file has one provider frame, taken as the local one; name the catalog entry in it when a second comes.
# brainstorming is dropped: superpowers is a project-scope OpenCode plugin, so its deny stays in the repo config.
# Through a temp file, so a jq failure keeps the previous config instead of truncating it (S23).
cfg=~/.config/opencode/opencode.json
lm=$(python3 -I /workspace/bin/stella_data.py get --json connections 2>/dev/null \
  | jq -c '[.entries[] | select(.kind == "provider" and .locality == "local" and .enabled) | .models[]][0] // empty')
[ -n "$lm" ] && jq --argjson m "$lm" '(.providers | keys[0]) as $p | {"$schema", model: "\($p)/\($m.id)",
    providers: (.providers | .[$p].models = {($m.id): {name: $m.id, capabilities: {tools: ($m.capabilities.tool_calling == true),
      input: (["text"] + (if $m.capabilities.vision == true then ["image"] else [] end)), output: ["text"]},
      limit: ({context: $m.capabilities.context_tokens, output: $m.limits.output_tokens} | with_entries(select(.value != null)))}}),
    permission: {skill: (.permission.skill | del(.brainstorming))}}' \
  /workspace/opencode.json > "$cfg.tmp" && mv "$cfg.tmp" "$cfg" \
  || { rm -f "$cfg.tmp"; fail "opencode.json not written (the catalog's local model, jq or mv failed); the previous config is kept"; }
# Vetted anti-ai-slop-writing (jalaalrd/anti-ai-slop-writing@63255f9), kept in the ~/.hermes volume.
skill=~/.hermes/skills/writing/anti-ai-slop-writing
[ -d "$skill" ] && cp -r "$skill" ~/.config/opencode/skills/ || fail "skill copy failed: $skill missing or not copied"
# Repo-owned Hermes config (SOULs, hooks, toolsets; D31, D34) re-applied to the ~/.hermes volume. A failure never stops
# the gateway from starting, but guards may then be unregistered: logged, and one #alerts line an hour.
/workspace/bin/apply-hermes-local.sh || {
  rc=$?
  fail "apply-hermes-local.sh failed (exit $rc)"
  once_per_hour container-start-apply && hermes send --to "${ALERT_TARGET:-discord:#alerts}" --quiet \
    "container-start: apply-hermes-local.sh failed (exit $rc) at container start: guards may not be registered (escalation hooks, guard hooks, toolsets) while the gateway runs. Run bin/apply-hermes-local.sh in the container and read its output." \
    >/dev/null 2>&1 || echo "container-start: #alerts send skipped (sent within the hour) or failed" >&2
}
# The fallback gateway (OmniRoute, T14/T15, D93) starts when the fallback is enabled in its config, so a restart does not leave every
# rerouted call queued until someone starts it by hand. Best effort and in the background (its start waits for a health answer):
# a failure is in the log below, never a failed step. It is loopback-only and needs its API key (bin/omniroute-ctl.sh status).
if jq -e '.enabled == true' /workspace/docs/hermes-local/fallback-routing.json >/dev/null 2>&1; then
  mkdir -p "$ws/.scratch" 2>/dev/null
  ( setsid nohup /workspace/bin/omniroute-ctl.sh start >>"$ws/.scratch/omniroute-start.log" 2>&1 & )
fi
[ -z "$failed" ] || { echo "container-start: failed steps:$failed" >&2; exit 1; }
