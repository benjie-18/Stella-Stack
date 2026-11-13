#!/usr/bin/env bash
# Hermetic self-test for bin/escalation-reply-hook.sh (Hermes post_gateway_admission hook): stub hermes, scratch state,
# no network. STAGE=<dir> runs a staged copy while the hook is being replaced.
# Fail closed (D72): only a reply from a well-formed OWNER_DISCORD_USER_ID unblocks a card. Everything else is left to the
# poller, which alerts it (bin/escalation-reply-poll-selftest.sh).
set -u
H=${STAGE:-/workspace/bin}/escalation-reply-hook.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sup/state"
cat >"$T/bin/hermes" <<'S'
#!/usr/bin/env bash
[ "$1 $2" = "kanban --board" ] && set -- "$1" "${@:4}"   # scripts name the board (F4)
case "$1 $2" in
  "kanban show") echo '{"task":{"status":"blocked"}}';;
  "kanban unblock") echo "$*" >>"$ESCALATE_SUP_DIR/unblocked";;
  send*) echo "$*" >>"$ESCALATE_SUP_DIR/sends"; exit 1;;
esac
S
chmod +x "$T/bin/hermes"
{ cat /workspace/config/owner.example.env; printf "ESCALATIONS_CHANNEL_ID='1'\n"; } >"$T/owner.env"
: >"$T/sup/unblocked"
export PATH="$T/bin:$PATH" ESCALATE_SUP_DIR="$T/sup" OWNER_CONFIG="$T/owner.env"
printf '777\tt_abc12345\n' >"$T/sup/state/escalation-threads.tsv"
OWNER=100000000000000001 OTHER=200000000000000002 n=0 fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
setid() { printf "OWNER_DISCORD_USER_ID='%s'\n" "$1" >>"$T/owner.env"; }   # the last key wins
nunb() { wc -l <"$T/sup/unblocked"; }
reply() {  # reply <author id>: one Discord message in the card's thread; sets rc
  n=$((n + 1))
  jq -nc --arg u "$1" --arg m "m$n" '{extra: {platform: "discord", text: "Option A", message_id: $m, source: {thread_id: "777", user_id: $u, user_name: "someone"}}}' | "$H"
  rc=$?
}

setid $OWNER
reply $OWNER
ok '[ "$rc" = 0 ] && [ "$(nunb)" = 1 ] && grep -q t_abc12345 "$T/sup/unblocked" && grep -q "\"event\":\"REPLY\"" "$T/sup/escalations.log"' "control: the recorded owner's reply unblocks the card and is logged"
u=$(nunb)
reply $OTHER
ok '[ "$rc" = 0 ] && [ "$(nunb)" = "$u" ]' "a valid id, someone else's reply: not applied"
setid ""
reply $OTHER
ok '[ "$rc" = 0 ] && [ "$(nunb)" = "$u" ]' "an empty id: a reply is not applied (fail closed)"
reply ""
ok '[ "$rc" = 0 ] && [ "$(nunb)" = "$u" ]' "an empty id and a reply with no author id: not applied"
setid 12345
reply $OTHER
ok '[ "$rc" = 0 ] && [ "$(nunb)" = "$u" ]' "a malformed id: a reply is not applied (fail closed)"
reply 12345
ok '[ "$rc" = 0 ] && [ "$(nunb)" = "$u" ]' "a malformed id: an author matching it is not the owner either"
setid $OWNER
reply $OWNER
ok '[ "$rc" = 0 ] && [ "$(nunb)" = $((u + 1)) ]' "control: once the id is corrected the owner's reply applies again, no restart"
ok '[ ! -e "$T/sup/sends" ]' "the hook itself posts nothing to Discord"
# RT-RTA-02 (source side): the hook runs jq with HOME = a folder the worker writes; a planted ~/.jq (here a syntax error)
# must not stop the owner's reply from applying, nor let anyone else's through.
PJ=$T/plant-jq; mkdir -p "$PJ"; printf 'this is not jq\n' >"$PJ/.jq"
replyh() { n=$((n + 1)); jq -nc --arg u "$1" --arg m "m$n" '{extra: {platform: "discord", text: "Option A", message_id: $m, source: {thread_id: "777", user_id: $u, user_name: "someone"}}}' | env HOME="$PJ" "$H"; rc=$?; }
u=$(nunb)
replyh $OTHER
ok '[ "$rc" = 0 ] && [ "$(nunb)" = "$u" ]' "RT-RTA-02: under a planted ~/.jq, someone else's reply is still not applied"
replyh $OWNER
ok '[ "$rc" = 0 ] && [ "$(nunb)" = $((u + 1)) ]' "RT-RTA-02: under a planted ~/.jq, the recorded owner's reply still unblocks the card"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
