#!/usr/bin/env bash
# Owner config (D39): the owner's name, Discord ids, Windows stack path and GitHub owner, from
# ${OWNER_CONFIG:-/workspace/config/owner.env} (local, gitignored; config/ 555, the file 444 (D40); config/owner.example.env lists the keys).
# bin/owner_config.py is the only parser, so shell and Python read the file identically. Absolute paths throughout:
# hooks and cron run with other HOME/HERMES_HOME values.
# Sourced: owner_config_read   set the keys, or set OWNER_CONFIG_ERROR and return 1 (changes nothing)
#          owner_config_load   the same, but a missing or incomplete file also logs OWNER_CONFIG_MISSING to
#                              escalations.log and sends one #alerts message, STL-CFG-301 (at most one an hour)
# Run:     owner-config.sh --check    offline: keys present, ids are 17-20 digits, path non-empty (exit 1 if not)
#          owner-config.sh --verify   --check, then read-only Discord GETs through Hermes's own token loader: both
#                                     channels exist in the guild and the owner is a member of it
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
[ -n "${OWNER_CONFIG_SH:-}" ] && return 0; OWNER_CONFIG_SH=1
OWNER_ID_RE='^[0-9]{17,20}$'
. /workspace/bin/alert.sh   # alert_text (D44): for the missing-config alert here and alert() in escalation-discord.sh

owner_config_read() {
  local out
  if out=$(python3 -I /workspace/bin/owner_config.py --shell 2>/dev/null); then eval "$out"; return 0; fi
  OWNER_CONFIG_ERROR=$(python3 -I /workspace/bin/owner_config.py --shell 2>&1 >/dev/null)
  return 1
}

# once_per_hour <key>: true at most once an hour per key (a stamp in state/), so a cron loop cannot flood #alerts.
once_per_hour() {
  local f="${ESCALATE_SUP_DIR:-/workspace/.supervisor}/state/alert-$1.stamp"
  [ -n "$(find "$f" -mmin -60 2>/dev/null)" ] && return 1
  mkdir -p "${f%/*}" && touch "$f"
}

owner_config_load() {
  owner_config_read && return 0
  echo "owner config: $OWNER_CONFIG_ERROR" >&2
  jq -nc --arg time "$(date -u +%FT%TZ)" --arg card "${card:-}" --arg detail "$OWNER_CONFIG_ERROR" \
    '{time: $time, card: $card, event: "OWNER_CONFIG_MISSING", detail: $detail}' \
    >>"${ESCALATE_SUP_DIR:-/workspace/.supervisor}/escalations.log"
  local fix=""   # K5: a malformed line is named with the accepted forms (the parser's own text, never a value)
  [[ $OWNER_CONFIG_ERROR =~ \ line\ ([0-9]+):\ not\ (.*)$ ]] && fix=" The problem is line ${BASH_REMATCH[1]}: it is not in an accepted form, which are ${BASH_REMATCH[2]}."
  if once_per_hour owner-config-missing; then
    hermes send --to "${ALERT_TARGET:-discord:#alerts}" --quiet "$(alert_text STL-CFG-301 since="$(date -u +%FT%TZ)" card="${card:-}" error="$OWNER_CONFIG_ERROR" fix="$fix")" >/dev/null 2>&1 || true
  fi
  return 1
}

owner_config_check() {
  local f="${OWNER_CONFIG:-/workspace/config/owner.env}" k rc=0
  owner_config_read || { echo "FAIL $OWNER_CONFIG_ERROR"; return 1; }
  for k in DISCORD_GUILD_ID ESCALATIONS_CHANNEL_ID SUPERVISOR_CHANNEL_ID OWNER_DISCORD_USER_ID; do
    [[ ${!k} =~ $OWNER_ID_RE ]] && continue
    if [ "$k" = OWNER_DISCORD_USER_ID ] && [ -z "${!k}" ]; then
      echo "WARN OWNER_DISCORD_USER_ID is empty: no reply or reaction is applied until it is set (D72)"; continue
    fi
    echo "FAIL $k is not a 17-20 digit Discord id"; rc=1
  done
  [ ! -w "$f" ] || echo "WARN $f is writable: chmod 444 $f"
  [ ! -w "${f%/*}" ] || echo "WARN ${f%/*} is writable, so $f can be replaced: chmod 555 ${f%/*}"   # D40
  [ "$rc" = 0 ] && echo "owner config: OK ($f)"
  return $rc
}

owner_config_verify() {
  local k id res err rc=0
  card=""
  . /workspace/bin/escalation-discord.sh
  for k in ESCALATIONS_CHANNEL_ID SUPERVISOR_CHANNEL_ID; do
    res=$(discord_action channel_info "${!k}"); err=$(jq -r '.error // empty' <<<"$res" 2>/dev/null)
    if grep -qi 'token\|bootstrap' <<<"$err"; then echo "SKIP Hermes's Discord token loader is not usable here: ${err:0:200}"; return 0; fi
    if [ -n "$err" ]; then echo "FAIL $k ${!k}: ${err:0:300}"; rc=1
    elif [ "$(jq -r '.guild_id' <<<"$res")" != "$DISCORD_GUILD_ID" ]; then echo "FAIL $k ${!k} is in guild $(jq -r '.guild_id' <<<"$res"), not $DISCORD_GUILD_ID"; rc=1
    else echo "ok   $k ${!k} is #$(jq -r '.name' <<<"$res") in guild $DISCORD_GUILD_ID"; fi
  done
  id="$OWNER_DISCORD_USER_ID"
  if [ -z "$id" ]; then echo "SKIP owner membership: OWNER_DISCORD_USER_ID is empty"
  else
    res=$(discord_action member_info "$DISCORD_GUILD_ID" "$id"); err=$(jq -r '.error // empty' <<<"$res" 2>/dev/null)
    if [ -n "$err" ]; then echo "FAIL owner $id is not a visible member of guild $DISCORD_GUILD_ID: ${err:0:300}"; rc=1
    else echo "ok   owner $id is a member of guild $DISCORD_GUILD_ID ($(jq -r '.username // .user.username // .display_name // "?"' <<<"$res"))"; fi
  fi
  return $rc
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --check)  owner_config_check ;;
    --verify) owner_config_check && owner_config_verify ;;
    *)        echo "usage: owner-config.sh --check | --verify" >&2; exit 2 ;;
  esac
  exit $?
fi
