#!/usr/bin/env bash
# Hermetic self-test for F4: every scripted kanban call names its board (`hermes kanban --board <board> …`), so a
# `hermes kanban boards switch` never points the escalation scripts at another board. The board name lives in one
# place, bin/kanban-board.sh. Stub hermes and Discord helper record every call; scratch state, no network.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sup/state"
printf 'ALERT_TARGET="discord:#alerts"\n' > "$T/sup/limits.env"
{ cat /workspace/config/owner.example.env; printf "ESCALATIONS_CHANNEL_ID='100'\\nDISCORD_GUILD_ID='200'\\nSUPERVISOR_CHANNEL_ID='300'\\n"; } > "$T/owner.env"
cat > "$T/bin/hermes" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$ESCALATE_SUP_DIR/hermes_calls"
[ "$1 $2" = "kanban --board" ] && set -- "$1" "${@:4}"
case "$1 $2" in
  "kanban list") jq -nc '[{id: "t_aaaaaaaa", status: "blocked"}, {id: "t_bbbbbbbb", status: "done"}]';;
  "kanban show") jq -nc --arg s "$([ "$3" = t_bbbbbbbb ] && echo done || echo blocked)" '{task: {status: $s, title: "T", body: ""}, events: [{kind: "blocked", payload: {kind: "needs_input", reason: "Option A or Option B"}}]}';;
esac
exit 0
S
cat > "$T/bin/fakepy" <<'S'
#!/usr/bin/env bash
cat >/dev/null
case "$3" in
  fetch_messages) echo '{"messages":[{"id":"2","content":"Option A","author":{"id":"100000000000000001","username":"owner","bot":false}}]}';;
  send_message) echo '{"success": true, "message_id": "m1"}';;
  create_thread) echo '{"success": true, "thread_id": "555"}';;
  *) echo '{"success": true}';;
esac
S
cat > "$T/bin/claude" <<'S'
#!/usr/bin/env bash
cat >/dev/null; echo '{"type":"result","is_error":false,"total_cost_usd":0,"modelUsage":{"claude-sonnet-5-5":{}}}'
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" ESCALATE_SUP_DIR="$T/sup" HERMES_PY="$T/bin/fakepy" OWNER_CONFIG="$T/owner.env" POLL_PASSES=1
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
B=/workspace/bin

$B/escalation-thread.sh t_aaaaaaaa "T" "Decision needed: Option A or Option B" >/dev/null 2>&1
$B/escalation-reply-poll.sh >/dev/null 2>&1
printf '556\tt_bbbbbbbb\t2026\tDone card\n' >> "$T/sup/state/escalation-threads.tsv"
$B/escalation-complete.sh t_bbbbbbbb >/dev/null 2>&1
echo '{"extra": {"task_id": "t_cccccccc", "reason": "x"}}' | $B/escalation-on-block.sh >/dev/null 2>&1
$B/escalations-status.sh >/dev/null 2>&1
echo hi | $B/escalate.sh t_12345678 sonnet review why >/dev/null 2>&1
for _ in $(seq 1 50); do grep -q "show t_cccccccc" "$T/sup/hermes_calls" 2>/dev/null && break; sleep 0.1; done   # on-block runs detached
k=$(grep -c '^kanban ' "$T/sup/hermes_calls")
ok '[ "$k" -ge 8 ]' "the scripts made kanban calls ($k)"
ok '! grep "^kanban " "$T/sup/hermes_calls" | grep -v "^kanban --board ai-stack "' "every kanban call carries --board ai-stack"
for c in "list" "show t_aaaaaaaa" "unblock" "comment" "show t_bbbbbbbb" "show t_cccccccc" "show t_12345678"; do
  ok 'grep -q "^kanban --board ai-stack $c" "$T/sup/hermes_calls"' "seen: kanban --board ai-stack $c"
done
ok '! grep -nE "(^|[[:space:](])hermes kanban " $B/*.sh | grep -v -- "-selftest.sh:" | grep -v "^$B/kanban-board.sh:" | grep -vE ":[0-9]+:\s*#"' "no script calls hermes kanban directly (only bin/kanban-board.sh)"
ok '[ "$(grep -l "ai-stack" $B/kanban-board.sh $B/escalation-*.sh $B/escalate.sh $B/escalations-status.sh $B/kanban-guard.sh | tr "\n" " ")" = "$B/kanban-board.sh " ]' "the board name appears in one script only"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
