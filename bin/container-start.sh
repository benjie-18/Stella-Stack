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
# The model is the resolver's (F2 W7b, W7b-VAL-02): the first link bin/resolve.py lists usable, on a local connection, for the role
# that runs this CLI (the role table's first profile of its worker kind), with what the link's probe record proves (tool calling,
# vision, effective context: stella_data.probed, F2b item C; none without a record) and the catalog model's `limits.output_tokens`;
# the tracked opencode.json holds the provider frame and names no model. That role works a card and none
# exists here, so the resolver is asked about a card with no facts record (a random id) and no project: it then lists no link that
# leaves the machine. No usable local link, or no answer: the config names no model (fail closed) and the step fails with the code.
# shortcut: that file has one provider frame, taken as the local one; name the catalog entry in it when a second comes.
# shortcut: one model for every card, read once at container start; a pin or preset changed later, or one of a card or project, is not followed: upgrade when the box launcher hands each run its model
# brainstorming is dropped: superpowers is a project-scope OpenCode plugin, so its deny stays in the repo config.
# Through a temp file, so a jq failure keeps the previous config instead of truncating it (S23).
cfg=~/.config/opencode/opencode.json
WORKER=opencode   # the role table's worker kind of the CLI this config is for
role=$(python3 -I -c 'import sys; sys.path.insert(0, "/workspace/bin"); import roles; print(next(p["role"] for p in roles.load()["profiles"].values() if p.get("worker") == sys.argv[1]))' "$WORKER" 2>/dev/null)
res=$(python3 -I /workspace/bin/resolve.py resolve --role "$role" --project "" --card "$(cat /proc/sys/kernel/random/uuid)" --json 2>"$cfg.err")
lm=$(jq -c --slurpfile c <(python3 -I /workspace/bin/stella_data.py get --json connections 2>/dev/null) '[.chain[] | select(.status == "usable") | . as $l
  | $c[0].entries[] | select(.id == $l.connection and .locality == "local") | .models[] | select(.id == $l.model) | . + {connection: $l.connection}][0] // empty' <<<"$res" 2>/dev/null)
rec=$([ -n "$lm" ] && python3 -I -c 'import sys, json; sys.path.insert(0, "/workspace/bin"); import stella_data as sd; print(json.dumps(sd.probed(sd.probe_records(), *sys.argv[1:3])))' \
  "$(jq -r .connection <<<"$lm")" "$(jq -r .id <<<"$lm")" 2>/dev/null)
why=$(jq -r '"\(.code // "STL-MDL-710") \(.reason // "the chain the resolver answers holds no usable local link")"' <<<"$res" 2>/dev/null)
why=${why:-$(grep -m1 'STL-[A-Z]*-[0-9]' "$cfg.err" | head -c 300)}; why=${why:-STL-MDL-710 the resolver gave no answer}   # no JSON = it failed closed: its coded line
rm -f "$cfg.err"
# no probe record: the catalog's values (an unprobed link may serve, owner ruling 2026-11-18); a record, even a failing one: the probed values
if jq --argjson m "${lm:-null}" --argjson r "${rec:-null}" '($r // {tool_calling: $m.capabilities.tool_calling, vision: $m.capabilities.vision, context: {effective: $m.capabilities.context_tokens}}) as $r
  | (.providers | keys[0]) as $p | {"$schema"} + (if $m then {model: "\($p)/\($m.id)"} else {} end) + {
    providers: (.providers | .[$p].models = (if $m then {($m.id): {name: $m.id, capabilities: {tools: ($r.tool_calling == true),
      input: (["text"] + (if $r.vision == true then ["image"] else [] end)), output: ["text"]},
      limit: ({context: $r.context.effective, output: $m.limits.output_tokens} | with_entries(select((.value // 0) > 0)))}} else {} end)),
    permission: {skill: (.permission.skill | del(.brainstorming)), execute: .permission.execute}}' \
  /workspace/opencode.json > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
then [ -n "$lm" ] || [ "$(python3 -I /workspace/bin/stella_data.py get --json connections 2>/dev/null | jq '[.entries[] | select(.enabled == true and .locality == "local")] | length' 2>/dev/null)" = 0 ] || fail "opencode.json names no model: $why (role ${role:-unknown})"
else rm -f "$cfg.tmp"; fail "opencode.json not written (jq or mv failed); the previous config is kept"; fi
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
