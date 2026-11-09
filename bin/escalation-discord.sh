# Shared by escalation-thread.sh and escalation-reply-poll.sh (sourced, not run): environment, log(), discord_action.
jq() { env -u HOME jq "$@"; }  # RT-RTA-02: ~/.jq is worker-writable and jq has no flag to skip it
export PATH="$PATH:/home/node/.local/bin:/home/node/.hermes/hermes-agent/.hermes/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C.UTF-8   # F19: the inherited en_US.UTF-8 is not installed, so bash falls back to C and ${s:0:N} cuts bytes
# The Discord bot (token and config) belongs to the default profile, which runs Stella's gateway. A worker calls
# the hook with HERMES_HOME set to its own profile, whose secrets have no bot token, so pin the default root (D27).
export HERMES_HOME=/home/node/.hermes
. /workspace/bin/kanban-board.sh   # kanban(): every kanban call names its board (F4)
SUP="${ESCALATE_SUP_DIR:-/workspace/.supervisor}"
LOG="$SUP/escalations.log"
MAP="$SUP/state/escalation-threads.tsv"     # thread_id <TAB> card_id <TAB> opened_at
SEEN="$SUP/state/escalation-replies.tsv"    # message_id <TAB> card_id <TAB> thread_id <TAB> recorded_at
DEL="$SUP/state/escalation-delete.tsv"      # card_id <TAB> thread_id <TAB> prompt_message_id <TAB> state <TAB> at <TAB> version (D32, D33)
# The card's latest thread-map row whose thread has not been deleted (D32); empty when none.
map_row() {
  local del
  del=$(awk -F'\t' '$4 == "deleted" || $4 == "archived" { printf "%s ", $2 }' "$DEL" 2>/dev/null)
  awk -F'\t' -v c="$1" -v del=" $del" '$2 == c && index(del, " " $1 " ") == 0 { r = $0 } END { print r }' "$MAP" 2>/dev/null
}
# Whether the log has <event> for <card> (D33). jq 1.6's `-e` reports only the LAST input's result, so a plain
# `jq -e 'select(...)'` over a multi-line log misses earlier matches; slurp and ask once instead.
log_has() { jq -s -e --arg c "$1" --arg e "$2" 'any(.[]; .card == $c and .event == $e)' "$LOG" >/dev/null 2>&1; }
# A thread closed by the completion prompt (deleted or archived, D33), or found gone: never reused, never polled.
thread_closed() { awk -F'\t' -v t="$1" '$2 == t && ($4 == "deleted" || $4 == "archived") { f = 1 } END { exit !f }' "$DEL" 2>/dev/null; }
# Completion prompt choices (D37, supersedes D33's prompt): Archive (renamed with 🔒, read-only) or Delete; no reaction
# keeps the thread. 📌 Keep is gone: on an older v2 prompt it does nothing.
CHOICE_ARCHIVE="🔒" CHOICE_DELETE="🗑️" LEGACY_KEEP="📌"
PROMPT_TEXT="What should happen to this thread? React ${CHOICE_ARCHIVE} Archive (renamed with ${CHOICE_ARCHIVE}, read-only) or ${CHOICE_DELETE} Delete. No reaction keeps it open."
# Thread names: cut to Discord's 100-character limit, counted in UTF-16 units (the stricter count; 🔒 is 2). jq counts
# characters correctly whatever the shell locale. Archived name (D37): "🔒 <original title>".
name100() { jq -rn --arg s "$1" '$s | until(([explode[] | if . > 65535 then 2 else 1 end] | add) <= 100; .[:-1])'; }
lock_name() { name100 "$CHOICE_ARCHIVE $1"; }
# Whether a block reason offers lettered options ("(A)", "Option B", "A:"), so a bare "A" reply can mean something.
has_options() { grep -qE '\([A-D]\)|\b[Oo]ption [A-D]\b|(^|[[:space:]])[A-D][:)]' <<<"$1"; }
# Answers recorded for a card: the per-card escalation cap counts these, not reason fingerprints (F2).
answers() { awk -F'\t' -v c="$1" '$2 == c' "$SEEN" 2>/dev/null | wc -l; }
# One #alerts message, through the same target as watchdog.sh: alert <CODE> [key=value ...], worded by the alert catalog
# (alert_text, sourced with owner-config.sh below; D44). "First seen" is now unless the caller passes since=.
alert() {
  local m; m=$(alert_text "$1" since="$(date -u +%FT%TZ)" "${@:2}")
  hermes send --to "${ALERT_TARGET:-discord:#alerts}" --quiet "$m" && return 0
  log ALERT_FAIL "hermes send to ${ALERT_TARGET:-discord:#alerts} failed: ${m:0:300}"; return 1   # K10: callers can tell it was not sent
}
HERMES_PY="${HERMES_PY:-/home/node/.hermes/tools/python-3.14.9+20261021-linux-x64/bin/python3}"   # overridable for the self-test
mkdir -p "$SUP/state"
# shellcheck source=/dev/null
. "$SUP/limits.env"
card="${card:-}"
# The Discord ids and the owner come from config/owner.env (D39); a missing or incomplete file is logged and alerted
# by owner_config_load, and stops the caller (the fail-open kanban guard reads a non-2 exit as allow).
. /workspace/bin/owner-config.sh
owner_config_load || exit 3
log() { jq -nc --arg time "$(date -u +%FT%TZ)" --arg card "$card" --arg event "$1" --arg detail "$2" \
  '{time: $time, card: $card, event: $event, detail: $detail}' >>"$LOG"; }

# Normalize a block reason (D28, D29): drop a leading "Decision needed:" label, and drop text a looping worker carries
# over from an earlier escalation ("External escalation resolved …", "requires human/orchestrator to acknowledge …",
# "task protocol prohibits …", "block loop …"), so reasons replace instead of accumulating. Whitespace collapsed.
# D35: a reason that carries the decision-card template (t_baa588dd) loses everything from "If no comment on this card
# starts with" onward and every sentence with worker instructions, so none of it reaches Discord; then it is cut at a
# word boundary near 300 characters. The kanban guard fingerprints the same normalized text.
normalize_reason() {
  local r
  r=$(sed -E 's/^[[:space:]]*[Dd]ecision needed[[:space:]]*:[[:space:]]*//' <<<"$1" | tr '\n' ' ' \
    | sed -E 's/[Ii]f no comment on this card starts with.*//; s/[^.]*(UNBLOCK: escalation reply|kanban_complete|kanban_block|metadata \{)[^.]*\.?//g; s/[^.]*([Ee]xternal escalation|[Ee]scalation) resolved[^.]*\.?//g; s/[^.]*(task protocol prohibits|acknowledge the external decision|block loop|[Rr]equires human\/orchestrator)[^.]*\.?//g; s/[[:space:]]+/ /g; s/^ //; s/ $//')
  # jq slices by character, not byte, so a cut never splits a multi-byte character
  [ "$(jq -rn --arg r "$r" '$r | length')" -le 300 ] || r="$(jq -rn --arg r "$r" '$r[:300] | sub(" [^ ]*$"; "")')…"
  printf '%s\n' "$r"
}

# One Discord action through Hermes's runtime. Always prints exactly one JSON line: the helper's result, or
# {"error": ..., "stage": ..., "traceback": ...}. Never empty (D26). Errors carry Discord's status and body, never the
# token or headers. Usage: discord_action create_thread <channel> <name> | channel_info <channel> | member_info <guild> <user>
#                         | archive_thread <thread> <parent channel> [<new name>]
#                         | fetch_messages <channel> [after_message_id]
discord_action() {
  local errf out
  errf=$(mktemp)
  out=$(cd /tmp && "$HERMES_PY" -I - "$@" 2>"$errf" <<'PY'
import json, sys
stage = "import"
try:
    # Hermes's runtime prelude, as `hermes --print-runtime-command` prints it: hermes_bootstrap puts Hermes's own
    # environment (python-dotenv, discord.py, ...) on sys.path. The bare interpreter alone lacks them (D26).
    import os
    for k in ("PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV"):
        os.environ.pop(k, None)
    sys.path.insert(0, "/home/node/.hermes/hermes-agent")
    sys._hermes_pin_default_home = True
    stage = "hermes bootstrap"
    import hermes_bootstrap
    os.environ["HERMES_HOME"] = str(__import__("hermes_constants").get_default_hermes_root())
    stage = "import"
    from hermes_cli.env_loader import load_hermes_dotenv
    # Option A (D25): Hermes's own token loader, the same call hermes_cli/main.py makes for every command,
    # including `hermes send`. The token stays inside this short-lived process: never printed, logged or passed on.
    stage = "token loader"
    load_hermes_dotenv(hermes_home=os.environ["HERMES_HOME"])
    stage = "discord helper import"
    from tools.discord_tool import _run_discord_action, _CORE_ACTIONS, _ADMIN_ACTIONS
    action, channel = sys.argv[1], sys.argv[2]
    stage = action
    if action in ("send_message", "edit_message", "react_add", "react_remove", "reaction_users", "delete_thread",
                  "archive_thread"):
        # Narrow escalation-only REST calls (D32), through Hermes's own request helper and token.
        from urllib.parse import quote
        from tools.discord_tool import _discord_request, _get_bot_token
        tok = _get_bot_token()
        if not tok:
            raise RuntimeError("DISCORD_BOT_TOKEN not configured")
        if action == "send_message":          # send_message <channel> <content>
            # Titles, reasons and summaries are model-written: no <@id>, <@&role> or @everyone in them pings anyone (F20).
            m = _discord_request("POST", f"/channels/{channel}/messages", tok,
                                 body={"content": sys.argv[3], "allowed_mentions": {"parse": []}})
            print(json.dumps({"success": True, "message_id": m["id"]}))
        elif action in ("react_add", "react_remove"):   # react_* <channel> <message_id> <emoji>
            path = f"/channels/{channel}/messages/{sys.argv[3]}/reactions/{quote(sys.argv[4])}/@me"
            _discord_request("PUT" if action == "react_add" else "DELETE", path, tok)
            print(json.dumps({"success": True}))
        elif action == "reaction_users":      # reaction_users <channel> <message_id> <emoji>
            users = _discord_request("GET", f"/channels/{channel}/messages/{sys.argv[3]}/reactions/{quote(sys.argv[4])}",
                                     tok, params={"limit": "100"}) or []
            print(json.dumps({"users": [{"id": u.get("id"), "username": u.get("username"), "bot": u.get("bot", False)}
                                        for u in users]}))
        elif action == "edit_message":        # edit_message <channel> <message_id> <content> (Stella's own message)
            _discord_request("PATCH", f"/channels/{channel}/messages/{sys.argv[3]}", tok, body={"content": sys.argv[4]})
            print(json.dumps({"success": True}))
        else:                                 # delete_thread | archive_thread <thread_id> <required parent channel id>
            ch = _discord_request("GET", f"/channels/{channel}", tok)
            if ch.get("type") not in (10, 11, 12) or str(ch.get("parent_id")) != sys.argv[3]:
                raise RuntimeError(f"refused: {channel} is not a thread of channel {sys.argv[3]} "
                                   f"(type {ch.get('type')}, parent {ch.get('parent_id')})")
            if action == "delete_thread":
                _discord_request("DELETE", f"/channels/{channel}", tok)
                print(json.dumps({"success": True, "deleted": channel}))
            else:                             # archive_thread <thread> <parent> [<new name>] (D37)
                # Rename first, while the thread is still active, then archived + locked = read-only (only Manage
                # Threads can reopen it). Both are confirmed from Discord's reply, never assumed.
                name = sys.argv[4] if len(sys.argv) > 4 else ""
                if name:
                    r = _discord_request("PATCH", f"/channels/{channel}", tok, body={"name": name}) or {}
                    if r.get("name") != name:
                        raise RuntimeError(f"rename not confirmed by Discord: name {r.get('name')!r}, wanted {name!r}")
                r = _discord_request("PATCH", f"/channels/{channel}", tok, body={"archived": True, "locked": True}) or {}
                md = r.get("thread_metadata") or {}
                if not (md.get("archived") and md.get("locked")):
                    raise RuntimeError(f"archive not confirmed by Discord: thread_metadata {md}")
                print(json.dumps({"success": True, "archived": channel, "locked": True, "name": r.get("name")}))
        raise SystemExit(0)
    kw = {"channel_id": channel}
    if action == "member_info":               # member_info <guild> <user> (owner-config.sh --verify, D39)
        kw = {"guild_id": channel, "user_id": sys.argv[3]}
    elif action == "create_thread":
        kw["name"] = sys.argv[3]
    elif action == "fetch_messages":
        kw["limit"] = 50
        if len(sys.argv) > 3 and sys.argv[3]:
            kw["after"] = sys.argv[3]
    print(_run_discord_action(action, _CORE_ACTIONS if action in _CORE_ACTIONS else _ADMIN_ACTIONS, "discord", **kw))
except SystemExit:
    raise
except BaseException as e:
    import traceback   # source lines and messages only; no local variable values, so no token
    print(json.dumps({"error": f"{type(e).__name__}: {e}", "stage": stage, "traceback": traceback.format_exc()[-1500:]}))
PY
  )
  if [ -z "$out" ]; then
    out=$(jq -nc --arg e "$(grep -v setlocale "$errf" | tail -c 800)" '{error: ("helper printed nothing; stderr: " + (if $e == "" then "(empty)" else $e end)), stage: "process"}')
  fi
  rm -f "$errf"
  printf '%s\n' "$out"
}

# Status reaction on the card's recorded reply message (D32): exactly one of 👀 answer recorded, ✨ working,
# 🌟 completed. The previous reaction is removed before the new one is added, and status never goes backwards.
REACT="$SUP/state/escalation-reactions.tsv"     # card_id <TAB> message_id <TAB> emoji <TAB> rank <TAB> set_at
set_status_reaction() {  # set_status_reaction <card> <recorded|working|completed>
  local c="$1" stage="$2" emoji rank row mid thread prev pm pe pr res err
  case "$stage" in
    recorded) emoji="👀" rank=1 ;; working) emoji="✨" rank=2 ;; completed) emoji="🌟" rank=3 ;; *) return 1 ;;
  esac
  row=$(awk -F'\t' -v c="$c" '$2 == c { r = $0 } END { print r }' "$SEEN" 2>/dev/null)
  mid=$(cut -f1 <<<"$row"); thread=$(cut -f3 <<<"$row")
  [ -n "$mid" ] && [ -n "$thread" ] || return 0   # no recorded answer yet: nothing to react to
  exec 7>"$SUP/state/reactions.lock"
  flock 7
  # The card's current reaction, wherever it is: one reaction per card, even if a newer reply became the target.
  prev=$(awk -F'\t' -v c="$c" '$1 == c { m = $2; e = $3; r = $4 } END { print m "\t" e "\t" r }' "$REACT" 2>/dev/null)
  pm=$(cut -f1 <<<"$prev"); pe=$(cut -f2 <<<"$prev"); pr=$(cut -f3 <<<"$prev")
  if [ "$pm" = "$mid" ] && [ -n "$pr" ] && [ "$pr" -ge "$rank" ]; then flock -u 7; return 0; fi   # never backwards
  if [ -n "$pe" ] && [ -n "$pm" ]; then
    res=$(discord_action react_remove "$thread" "$pm" "$pe"); err=$(jq -r '.error // empty' <<<"$res" 2>/dev/null)
    [ -z "$err" ] || card="$c" log REACTION_FAIL "remove $pe from message $pm: ${err:0:300}"
  fi
  if card="$c" react_add_retry "$thread" "$mid" "$emoji"; then   # retries Discord's reaction rate limit; logs a final failure
    printf '%s\t%s\t%s\t%s\t%s\n' "$c" "$mid" "$emoji" "$rank" "$(date -u +%FT%TZ)" >>"$REACT"
    card="$c" log REACTION "$stage $emoji on reply $mid in thread $thread"
  fi
  flock -u 7
}

# Add Stella's reaction with retries (D33): Discord rate-limits reaction bursts per channel (429), so space the calls
# and retry; a final failure is logged instead of being silent. usage: react_add_retry <channel> <message> <emoji>
react_add_retry() {
  local i res err
  for i in 1 2 3; do
    sleep 0.6
    res=$(discord_action react_add "$1" "$2" "$3"); err=$(jq -r '.error // empty' <<<"$res" 2>/dev/null)
    [ -z "$err" ] && return 0
    sleep "$i"
  done
  log REACTION_FAIL "add $3 on message $2 in $1 after 3 tries: ${err:0:300}"
  return 1
}
