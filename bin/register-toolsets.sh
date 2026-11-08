#!/usr/bin/env bash
# Re-apply what each profile's role installs (D34, D46), from docs/hermes-local/roles.json (via bin/roles.py spec), to the
# ~/.hermes volume:
#   platform_toolsets  -> `hermes [-p <profile>] tools enable|disable --platform <p>` (only the listed toolsets stay enabled)
#   skills_disabled    -> `hermes config set skills.disabled`
#   config             -> `hermes config set <key> <value>` (the role's config keys, and auxiliary.background_review.enabled
#                         from its background_review field)
#   hook_files         -> byte copies of the repo hook scripts into <profile dir>/hooks/ (registered by
#                         bin/register-escalation-hook.sh)
# Profiles: every row of the table plus every profile found in ~/.hermes (no row = the fallback role). The volume is
# generated output: edit the repo file, never the volume. Idempotent: an in-sync profile is not touched. Before the first
# change to a profile, its config.yaml is backed up to ~/.hermes/backups/toolsets-<UTC time>/ (in the volume, never
# committed). A broken role table changes nothing (exit 1).
# usage: register-toolsets.sh           apply
#        register-toolsets.sh --check   change nothing; report drift (exit 1 if any)
set -euo pipefail
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
mode="${1:-apply}"
H="$HOME/.hermes"   # HOME-relative (production HOME is /home/node), so the self-test runs against a scratch HOME
BK="$H/backups/toolsets-$(date -u +%Y%m%dT%H%M%SZ)"
T=$(mktemp); trap 'rm -f "$T"' EXIT
python3 /workspace/bin/roles.py spec "$H" >"$T" || { echo "toolsets: role table invalid, nothing changed ($(head -1 "$T"))"; exit 1; }
rc=0
pdir() { jq -r --arg p "$prof" '.[$p].dir' "$T"; }
h() { if [ "$(pdir)" = "$H" ]; then hermes "$@"; else hermes -p "$prof" "$@"; fi 2>&1 | { grep -v setlocale || true; }; }
backup() {  # once per profile per run, before its first change
  [ -f "$BK/$prof.config.yaml" ] && return 0
  mkdir -p "$BK"; cp -p "$(pdir)/config.yaml" "$BK/$prof.config.yaml"; echo "$prof: backup $BK/$prof.config.yaml"
}
for prof in $(jq -r 'keys[]' "$T"); do
  [ -f "$(pdir)/config.yaml" ] || { echo "$prof: no config.yaml, skipped"; continue; }
  for plat in $(jq -r --arg p "$prof" '.[$p].platform_toolsets // {} | keys[]' "$T"); do
    want=$(jq -r --arg p "$prof" --arg x "$plat" '.[$p].platform_toolsets[$x][]' "$T" | sort)
    have=$(h tools list --platform "$plat" | awk '/^Plugin toolsets/ {exit} $1 == "✓" && $2 == "enabled" {print $3}' | sort) || have=""   # S4
    [ -n "$have" ] || { echo "$prof/$plat: could not read the enabled toolsets, nothing changed"; rc=1; continue; }
    extra=$(comm -13 <(echo "$want") <(echo "$have") | tr '\n' ' ')
    missing=$(comm -23 <(echo "$want") <(echo "$have") | tr '\n' ' ')
    if [ -z "${extra// }${missing// }" ]; then echo "$prof/$plat: toolsets in sync"; continue; fi
    if [ "$mode" = --check ]; then echo "$prof/$plat: DRIFT extra: ${extra:-none} missing: ${missing:-none}"; rc=1; continue; fi
    backup
    # shellcheck disable=SC2086  # word splitting is the list of toolset names
    [ -z "${extra// }" ] || h tools disable --platform "$plat" $extra >/dev/null || { echo "$prof/$plat: disable failed"; rc=1; }
    # shellcheck disable=SC2086
    [ -z "${missing// }" ] || h tools enable --platform "$plat" $missing >/dev/null || { echo "$prof/$plat: enable failed"; rc=1; }
    echo "$prof/$plat: disabled ${extra:-none}; enabled ${missing:-none}"
  done
  if jq -e --arg p "$prof" '.[$p] | has("skills_disabled")' "$T" >/dev/null; then
    want=$(jq -c --arg p "$prof" '.[$p].skills_disabled | sort' "$T")
    if ! raw=$(h config get skills.disabled); then echo "$prof: could not read skills.disabled (hermes config get failed), nothing changed"; rc=1   # S4
    elif have=$(sed -n 's/^ *- //p' <<<"$raw" | jq -Rsc 'split("\n") | map(select(. != "")) | sort'); [ "$want" = "$have" ]; then echo "$prof: skills.disabled in sync"
    elif [ "$mode" = --check ]; then echo "$prof: skills.disabled DRIFT (repo $want, volume $have)"; rc=1
    else backup
      if h config set skills.disabled "$(jq -c --arg p "$prof" '.[$p].skills_disabled' "$T")" >/dev/null; then echo "$prof: skills.disabled set from repo"
      else echo "$prof: skills.disabled could not be set"; rc=1; fi; fi
  fi
  while IFS=$'\t' read -r key want; do
    [ -n "$key" ] || continue
    have=$(h config get "$key" | head -1 || true)   # S4: a failing read is drift, never a stop
    if [ "$have" = "$want" ]; then echo "$prof: $key $want (in sync)"
    elif [ "$mode" = --check ]; then echo "$prof: $key is ${have:-unset or unreadable}, expected $want"; rc=1
    elif h config set "$key" "$want" >/dev/null; then echo "$prof: $key set to $want"   # as D29's step: no backup, one key
    else echo "$prof: $key could not be set (hermes config set failed)"; rc=1; fi
  done < <(jq -r --arg p "$prof" '.[$p].config // {} | to_entries[] | "\(.key)\t\(.value)"' "$T")
  while IFS=$'\t' read -r dst src; do
    [ -n "$dst" ] || continue
    if cmp -s "/workspace/$src" "$dst"; then echo "$prof: $(basename "$dst") in sync"
    elif [ "$mode" = --check ]; then echo "$prof: $(basename "$dst") DRIFT (differs from repo $src)"; rc=1
    else mkdir -p "$(dirname "$dst")"
      if cp "/workspace/$src" "$dst.tmp" && chmod 755 "$dst.tmp" && mv "$dst.tmp" "$dst"; then echo "$prof: $(basename "$dst") restored from repo"
      else echo "$prof: $(basename "$dst") could not be restored from repo"; rc=1; fi; fi
  done < <(jq -r --arg p "$prof" '.[$p].hook_files // {} | to_entries[] | "\(.key)\t\(.value)"' "$T")
done
exit $rc
