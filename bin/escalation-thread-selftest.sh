#!/usr/bin/env bash
# Hermetic self-test for bin/escalation-thread.sh (D29): stub Discord helper and hermes, scratch state, no network.
# Replays the t_0c9348f7 sequence: first block, same re-block, re-block after a recorded reply with an accumulated
# "External escalation resolved …" reason and a mutated title, then a genuinely new decision.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sup/state"
printf 'ALERT_TARGET="discord:#alerts"\n' > "$T/sup/limits.env"
{ cat /workspace/config/owner.example.env; printf "ESCALATIONS_CHANNEL_ID='100'\\nDISCORD_GUILD_ID='200'\\nSUPERVISOR_CHANNEL_ID='300'\\n"; } > "$T/owner.env"; export OWNER_CONFIG="$T/owner.env"   # scratch owner config (D39)
cat > "$T/bin/hermes" <<'S'
#!/usr/bin/env bash
[ "$1 $2" = "kanban --board" ] && set -- "$1" "${@:4}"   # scripts name the board (F4)
case "$1 $2" in
  "send "*)       shift; printf '%s\n---\n' "$*" >> "$ESCALATE_SUP_DIR/sends";;
  "kanban comment") echo "$*" >> "$ESCALATE_SUP_DIR/comments";;
  "kanban show")  jq -nc --arg k "${FAKE_KIND:-needs_input}" --argjson n "${FAKE_NBLOCKS:-1}" --arg a "${FAKE_ASSIGNEE:-builder-claude}" \
                    --arg t "${FAKE_TITLE:-}" '{task: {status: "blocked", assignee: $a, title: $t}, events: [range($n) | {kind: "blocked", payload: {kind: $k}}]}';;
esac
exit 0
S
cat > "$T/bin/fakepy" <<'S'
#!/usr/bin/env bash
cat >/dev/null   # args: -I - <action> <channel> [<name or content>]
echo "$*" >> "$ESCALATE_SUP_DIR/discord_calls"
case "$3" in
  send_message) printf 'send_message %s %s\n---\n' "$4" "$5" >> "$ESCALATE_SUP_DIR/sends"
                [ -z "${FAKE_LINK_FAIL:-}" ] || { echo '{"error": "Discord API error 403: Missing Permissions"}'; exit 0; }
                echo '{"success": true, "message_id": "m1"}';;
  create_thread) sleep "${FAKE_CREATE_SLEEP:-0}"; [ -z "${FAKE_CREATE_FAIL:-}" ] || { echo '{"error": "Discord API error 503: Service Unavailable", "stage": "create_thread"}'; exit 0; }
                jq -nc --arg n "$5" --arg t "${FAKE_THREAD_ID:-555}" '{success: true, thread_id: $t, name: $n}';;
  *)            jq -nc --arg n "$5" '{success: true, thread_id: "555", name: $n}';;
esac
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" ESCALATE_SUP_DIR="$T/sup" HERMES_PY="$T/bin/fakepy"
E=/workspace/bin/escalation-thread.sh C=t_aaaaaaaa
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
events() { jq -r '.event' "$T/sup/escalations.log" | tr '\n' ,; }
nsends() { grep -c '^---$' "$T/sup/sends" 2>/dev/null || echo 0; }
amsg() { awk -v RS='\n---\n' -v c="[$1]" -v k="$2" 'index($0, "--to discord:#alerts ") == 1 && index($0, c) && index($0, k) { n++ } END { print n + 0 }' "$T/sup/sends"; }   # #alerts messages with code $1 naming $2 (D44)

$E $C "T16 escalation test: pick a colour" "Decision needed: Option A: blue, or Option B: green." >/dev/null 2>&1
ok '[ "$(events)" = "THREAD_OPENED,LINK_POSTED," ]' "first block: one thread, one #supervisor link"
ok '[ "$(nsends)" = 2 ]' "first block: exactly two posts (thread message + #supervisor)"
ok '[ "$(grep -c "Decision needed:" "$T/sup/sends")" = 2 ] && ! grep -q "Decision needed: Decision needed" "$T/sup/sends"' "decision label once per message, never doubled"
ok '[ "$(grep -o "<#555>" "$T/sup/sends" | wc -l)" = 1 ] && ! grep -q "discord.com/channels" "$T/sup/sends"' "one link, one format, in #supervisor only"
ok '[ "$(cut -f4 "$T/sup/state/escalation-threads.tsv")" = "T16 escalation test: pick a colour" ]' "original title saved in the thread map"
ok 'grep -q "^-I - create_thread 100 t_aaaaaaaa · T16 escalation test: pick a colour$" "$T/sup/discord_calls"' "thread name is <card id> · <title> (F6)"
ok 'head -1 "$T/sup/sends" | grep -qx -- "--to discord:100:555 --quiet Card t_aaaaaaaa: T16 escalation test: pick a colour"' "first line of the thread post is Card <id>: <title> (F6)"
ok 'grep -q "for example: Option A" "$T/sup/sends"' "a reason with options keeps the option prompt"
ok '! grep -q -- "--to discord:300" "$T/sup/sends" && grep -q "^send_message 300 Escalation t_aaaaaaaa" "$T/sup/sends"' "#supervisor link goes by REST, never hermes send (no mirror into Stella's session, F1)"

$E $C "T16 escalation test: pick a colour" "Decision needed: Option A: blue, or Option B: green." >/dev/null 2>&1
ok '[ "$(nsends)" = 2 ] && [ "$(events)" = "THREAD_OPENED,LINK_POSTED,ESCALATION_SKIP," ]' "same re-block: nothing posted"

printf '777\t%s\t555\tnow\n' $C >> "$T/sup/state/escalation-replies.tsv"   # the reply was recorded
$E $C "Block card T16 with escalation decision needed" "Decision needed: Option A: blue, or Option B: green. External escalation resolved via Discord (owner selected option A: blue). However, task protocol prohibits agent from choosing options. Requires human/orchestrator to acknowledge the external decision and either confirm with kanban_block or escalate appropriately. Card is in block loop awaiting this manual resolution." >/dev/null 2>&1
ok '[ "$(nsends)" = 2 ] && [ "$(events)" = "THREAD_OPENED,LINK_POSTED,ESCALATION_SKIP,LOOP_DETECTED," ]' "re-block after a reply with an accumulated reason: LOOP_DETECTED, nothing posted"
ok 'grep -q "Loop detected" "$T/sup/comments"' "loop noted on the card"

$E $C "Block card T16 with escalation decision needed" "Decision needed: Which shade of blue: navy or sky?" >/dev/null 2>&1
ok '[ "$(nsends)" = 3 ] && tail -n 5 "$T/sup/sends" | grep -qx -- "--to discord:100:555 --quiet Card t_aaaaaaaa: T16 escalation test: pick a colour" && ! grep -q "^Task: " "$T/sup/sends"' "new decision: one new thread message, original title, no new link"
ok '[ "$(events)" = "THREAD_OPENED,LINK_POSTED,ESCALATION_SKIP,LOOP_DETECTED,THREAD_REUSED,ESCALATION_POSTED," ]' "new decision reuses the thread"
printf '%s\t555\t900\tarchived\tnow\tv2\n' $C >> "$T/sup/state/escalation-delete.tsv"   # thread 555 archived (D33)
$E $C "T16 escalation test: pick a colour" "Decision needed: A brand-new question?" >/dev/null 2>&1
ok '[ "$(jq -r .event "$T/sup/escalations.log" | tail -2 | tr "\n" ,)" = "THREAD_OPENED,LINK_POSTED," ] && [ "$(grep -c "^555" "$T/sup/state/escalation-threads.tsv")" = 2 ]' "an archived thread is never reused: the card gets a new thread"

# t_baa588dd (D35): Stella blocked with the whole decision-card body as the reason; the worker instructions reached
# the thread and the #supervisor link. The exact reason from the card's blocked event:
BAA="Decision needed: option-a.txt (A) vs option-b.txt (B). If no comment on this card starts with 'UNBLOCK: escalation reply', call kanban_block once with kind needs_input and reason 'Decision needed: option-a.txt (A) vs option-b.txt (B).' and stop. If such a comment exists, it is the human answer: call kanban_complete with summary 'Decision: <the answer>' and metadata {decision, source: 'escalation reply', thread_id, answered_by}."
: > "$T/sup/sends"
$E t_baa588dd "Phase 5 decision card" "$BAA" >/dev/null 2>&1
ok 'grep -qx "Decision needed: option-a.txt (A) vs option-b.txt (B)." "$T/sup/sends"' "t_baa588dd: thread message has only the decision"
ok 'grep -q "^send_message 300 Escalation t_baa588dd: \"Phase 5 decision card\". Decision needed: option-a.txt (A) vs option-b.txt (B). Reply in <#555>$" "$T/sup/sends"' "t_baa588dd: #supervisor link has only the decision"
ok '! grep -q "If no comment\|UNBLOCK\|kanban_\|metadata {\|and stop" "$T/sup/sends"' "t_baa588dd: no worker instruction text reaches Discord"
( card=""; . /workspace/bin/escalation-discord.sh
  long="Decision needed: $(printf 'word%.0s ' $(seq 1 120))"
  n=$(normalize_reason "$long"); [ "${#n}" -le 301 ] && [ "${n: -1}" = "…" ] && [[ "${n:0:-1}" != *" " ]] && [[ "${n:0:-1}" == *word ]]
  [ "$(normalize_reason "Pick A or B. Then call kanban_complete with summary x. Thanks.")" = "Pick A or B. Thanks." ] )
ok '[ $? = 0 ]' "long reasons cut at a word boundary near 300 characters; instruction sentences dropped"
# t_fbfdaf63 (F2a, F2c): three differently worded needs_input blocks from builder-local, with an "A" recorded after
# each of the first two. Each reason has no options, so the prompt asks for plain words. The cap counts blocks per card,
# not per fingerprint: the third block posts nothing, is held, and raises one #alerts line plus a card comment.
F=t_fbfdaf63 FT='Create phase4-test.md in worktree: "Phase 4 test OK"'
R1="Task body specifies \"Do not do the work yourself\" but I created phase4-test.md via heredoc terminal command. Guard rejects completion because file was written by worker's own terminal command, not via OpenCode. Cannot proceed without a decision."
R2="Guard keeps refusing completion even though OpenCode wrote the file (exit 0) in this session. Guard may be checking the wrong call."
R3="Task t_fbfdaf63 blocked by the false-close guard claiming no OpenCode run in session. Heredoc created the file and user escalation 'A' approved this approach, but the guard cannot verify the original creation."
: > "$T/sup/sends"; : > "$T/sup/comments"
FAKE_ASSIGNEE=builder-local FAKE_NBLOCKS=1 $E $F "$FT" "$R1" >/dev/null 2>&1
ok 'grep -qx "Reply with your instruction in plain words. Your reply is recorded on t_fbfdaf63 and unblocks it." "$T/sup/sends" && ! grep -q "Option A" "$T/sup/sends"' "t_fbfdaf63 block 1: no options in the reason, so no Option A prompt"
printf '801\t%s\t555\tnow\n' $F >> "$T/sup/state/escalation-replies.tsv"
FAKE_ASSIGNEE=builder-local FAKE_NBLOCKS=2 $E $F "$FT" "$R2" >/dev/null 2>&1
ok '[ "$(grep -c "^--to discord:100:555 --quiet Card t_fbfdaf63:" "$T/sup/sends")" = 2 ]' "t_fbfdaf63 block 2 (one answer): a new, different decision is still posted"
printf '802\t%s\t555\tnow\n' $F >> "$T/sup/state/escalation-replies.tsv"
n=$(nsends)
FAKE_ASSIGNEE=builder-local FAKE_NBLOCKS=3 $E $F "$FT" "$R3" >/dev/null 2>&1
ok '[ "$(grep -c "^--to discord:100:555 --quiet Card t_fbfdaf63:" "$T/sup/sends")" = 2 ] && [ "$(nsends)" = $((n + 1)) ]' "t_fbfdaf63 block 3 (two answers): no thread post, only the alert"
want='Card t_fbfdaf63 ("Create phase4-test.md in worktree: "Phase 4 test OK"") was blocked again after you already answered twice (3 blocks so far).'
ok '[ "$(amsg STL-ESC-230 t_fbfdaf63)" = 1 ] && grep -qF -- "$want" "$T/sup/sends"' "t_fbfdaf63 block 3: one #alerts line in the agreed format"
ok '[ "$(jq -r "select(.card == \"t_fbfdaf63\") | .event" "$T/sup/escalations.log" | tail -1)" = LOOP_HELD ] && grep -q "comment --author escalation-thread.sh t_fbfdaf63 Loop held" "$T/sup/comments"' "t_fbfdaf63 block 3: LOOP_HELD logged and a card comment"

# F2b: a capability block is not a human decision: no thread, no "Option A" prompt; #alerts + card comment naming the
# error, and for builder-local a reassignment suggestion (never an automatic reassign). Run 33's reason, kind capability.
: > "$T/sup/sends"; : > "$T/sup/comments"
CR="OpenCode service unavailable (socket closed): Transport error, opencode run exited 124."
FAKE_KIND=capability FAKE_ASSIGNEE=builder-local $E t_cafecafe "Create phase4-test.md" "$CR" >/dev/null 2>&1
ok '! grep -q "discord:100\|send_message 300" "$T/sup/sends" && ! grep -q "t_cafecafe" "$T/sup/state/escalation-threads.tsv"' "capability block: no thread, no #supervisor link"
want='Card t_cafecafe ("Create phase4-test.md") stopped because its builder hit something it cannot do'
ok '[ "$(amsg STL-ESC-231 t_cafecafe)" = 1 ] && grep -qF -- "$want" "$T/sup/sends" && ! grep -qF -- "$CR" "$T/sup/sends" && grep -qF -- "$CR" "$T/sup/logs/alerts.log" && grep -q "^STL-ESC-231 .*Suggestion: reassign to builder-claude" "$T/sup/logs/alerts.log"' "capability block: one #alerts message naming the card (D44: the error and the builder-claude suggestion in alerts.log and the card comment)"
ok 'grep -q "comment --author escalation-thread.sh t_cafecafe Capability block held for triage" "$T/sup/comments" && grep -q "Error: $CR" "$T/sup/comments"' "capability block: card comment names the error"
FAKE_KIND=capability FAKE_ASSIGNEE=builder-claude $E t_cafecaff "Some card" "$CR" >/dev/null 2>&1
ok '[ "$(amsg STL-ESC-231 t_cafecaff)" = 1 ] && grep "^STL-ESC-231 .*t_cafecaff" "$T/sup/logs/alerts.log" | grep -q "suggestion=..$" && ! grep "t_cafecaff" "$T/sup/sends" | grep -q "Suggestion"' "capability block on builder-claude: no reassignment suggestion"

# F6: a long title keeps the thread name within Discord's 100-character limit, card id first.
FAKE_NBLOCKS=1 $E t_0000000a "$(printf 'y%.0s' $(seq 1 120))" "Decision needed: pick (A) or (B)." >/dev/null 2>&1
nm=$(grep "create_thread 100 t_0000000a" "$T/sup/discord_calls" | sed 's/^-I - create_thread 100 //')
ok '[ "$nm" = "t_0000000a · $(printf "y%.0s" $(seq 1 87))" ]' "thread name cut to 100 characters, id kept"

# F19: in the C locale bash cuts ${s:0:N} by byte, so an ä on byte 99 lost its second byte (U+FFFD downstream). The
# scripts set LC_ALL=C.UTF-8 themselves; run here under LC_ALL=C, the fallback the container's missing locale gives.
U="$(printf 'x%.0s' $(seq 1 99))ä tail"
utf8_title() { awk -F'\t' -v c="$1" '$2 == c { print $4 }' "$T/sup/state/escalation-threads.tsv" | python3 -c 'import sys; t = sys.stdin.buffer.read().decode("utf-8").rstrip("\n"); sys.exit(0 if t == "x" * 99 + "ä" else 1)' 2>/dev/null; }
LC_ALL=C $E t_0000000b "$U" "Decision needed: pick (A) or (B)." >/dev/null 2>&1
ok 'utf8_title t_0000000b' "F19: escalation-thread.sh keeps an ä that starts on byte 99 whole (valid UTF-8, 100 characters)"
echo '{"extra": {"task_id": "t_0000000c", "reason": "Decision needed: pick (A) or (B)."}}' | LC_ALL=C FAKE_TITLE="$U" /workspace/bin/escalation-on-block.sh >/dev/null 2>&1
for _ in $(seq 1 50); do grep -q t_0000000c "$T/sup/state/escalation-threads.tsv" && break; sleep 0.1; done
ok 'utf8_title t_0000000c' "F19: escalation-on-block.sh hands the thread script a whole ä too"

# F7: two runs for one card at once (two blocks inside the create window) open one thread, post once and link once.
: > "$T/sup/sends"
FAKE_THREAD_ID=556 FAKE_CREATE_SLEEP=1 $E t_0000000d "Race" "Decision needed: pick (A) or (B)." >/dev/null 2>&1 &
FAKE_THREAD_ID=556 FAKE_CREATE_SLEEP=1 $E t_0000000d "Race" "Decision needed: pick (A) or (B)." >/dev/null 2>&1
wait
ok '[ "$(grep -c "create_thread 100 t_0000000d" "$T/sup/discord_calls")" = 1 ] && [ "$(awk -F"\t" "\$2 == \"t_0000000d\"" "$T/sup/state/escalation-threads.tsv" | wc -l)" = 1 ]' "F7: two concurrent runs, one create_thread and one map row"
ok '[ "$(grep -c "^--to discord:100:556 --quiet Card t_0000000d" "$T/sup/sends")" = 1 ] && [ "$(grep -c "^send_message 300 Escalation t_0000000d" "$T/sup/sends")" = 1 ]' "F7: one thread post and one #supervisor link"

# F1: a failed create_thread (Discord 5xx) is THREAD_FAIL plus one #alerts line naming the card, its title (80
# characters) and the error; at most one line per card an hour.
: > "$T/sup/sends"; LONG="Fail card $(printf 'z%.0s' $(seq 1 100))"
FAKE_CREATE_FAIL=1 $E t_0000000e "$LONG" "Decision needed: pick (A) or (B)." >/dev/null 2>&1; rc=$?
FAKE_CREATE_FAIL=1 $E t_0000000e "$LONG" "Decision needed: pick (A) or (B)." >/dev/null 2>&1
ok '[ "$rc" = 1 ] && [ "$(jq -r "select(.card == \"t_0000000e\") | .event" "$T/sup/escalations.log" | sort | uniq -c | tr -s " ")" = " 2 THREAD_FAIL" ]' "F1: create_thread failure: THREAD_FAIL, exit 1"
ok '[ "$(amsg STL-ESC-220 t_0000000e)" = 1 ] && grep -qF "Card t_0000000e (\"${LONG:0:80}\") needs a decision from you, but Stella could not post it in #escalations (Discord had a server error)" "$T/sup/sends" && grep -q "^STL-ESC-220 .*card=.t_0000000e.*create_thread failed.*503" "$T/sup/logs/alerts.log"' "F1: one #alerts line per card an hour: card, title cut to 80, error"

# F5: the #supervisor link is the only notice outside #escalations; a failed post is LINK_FAIL plus one #alerts line.
: > "$T/sup/sends"
FAKE_THREAD_ID=557 FAKE_LINK_FAIL=1 $E t_0000000f "Link card" "Decision needed: pick (A) or (B)." >/dev/null 2>&1
ok '[ "$(jq -r "select(.card == \"t_0000000f\") | .event" "$T/sup/escalations.log" | tr "\n" ,)" = "THREAD_OPENED,LINK_FAIL," ] && [ "$(amsg STL-ESC-222 t_0000000f)" = 1 ] && grep -q "^STL-ESC-222 .*thread=.557" "$T/sup/logs/alerts.log"' "F5: LINK_FAIL plus one #alerts message naming the card (D44: no Discord id in the message; the thread id in alerts.log)"

# F20: every REST post sends allowed_mentions {"parse": []}, so a title or reason carrying <@id>, <@&role> or @everyone
# pings nobody. The library's own Python runs here against stub Hermes modules that record each request.
M="$T/agent"; mkdir -p "$M/hermes_cli" "$M/tools"; : > "$M/hermes_bootstrap.py"; : > "$M/hermes_cli/__init__.py"; : > "$M/tools/__init__.py"
echo 'def get_default_hermes_root(): return "/nonexistent"' > "$M/hermes_constants.py"
echo 'def load_hermes_dotenv(hermes_home=None): pass' > "$M/hermes_cli/env_loader.py"
cat > "$M/tools/discord_tool.py" <<'S'
import json, os
_CORE_ACTIONS, _ADMIN_ACTIONS = {}, {}
def _run_discord_action(*a, **k): return "{}"
def _get_bot_token(): return "stub"
def _discord_request(method, path, tok, body=None, params=None):
    open(os.environ["REQ_LOG"], "a").write(json.dumps({"method": method, "path": path, "body": body}) + "\n")
    return {"id": "m9"}
S
sed -n "/<<'PY'$/,/^PY$/p" /workspace/bin/escalation-discord.sh | sed '1d;$d' | sed "s#/home/node/.hermes/hermes-agent#$M#" > "$T/helper.py"
REQ_LOG="$T/req.jsonl" python3 -I "$T/helper.py" send_message 300 'Escalation t_1: "<@100000000000000001> @everyone <@&5>". Reply in <#557>' >/dev/null
ok '[ "$(jq -c ".body.allowed_mentions" "$T/req.jsonl")" = "{\"parse\":[]}" ] && jq -e ".method == \"POST\" and (.body.content | contains(\"@everyone\"))" "$T/req.jsonl" >/dev/null' "F20: the POST body carries allowed_mentions {parse: []} and the text unchanged"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
