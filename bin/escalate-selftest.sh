#!/usr/bin/env bash
# Hermetic self-test for bin/escalate.sh: stub claude/hermes, scratch state dir, no spend, no board writes.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sup"
sed -e 's/^HAIKU_MAX_PER_DAY=.*/HAIKU_MAX_PER_DAY=2/' /workspace/.supervisor/limits.env >"$T/sup/limits.env"
cat >"$T/bin/claude" <<'S'
#!/usr/bin/env bash
ok='{"type":"result","is_error":false,"total_cost_usd":0.001,"modelUsage":{"claude-haiku-5-5":{}}}'
echo $(( $(cat "$ESCALATE_SUP_DIR/claude_n" 2>/dev/null || echo 0) + 1 )) > "$ESCALATE_SUP_DIR/claude_n"
cat >/dev/null; sleep "${FAKE_SLEEP:-0}"; printf '%s\n' "${FAKE_OUT:-$ok}"; exit "${FAKE_RC:-0}"
S
cat >"$T/bin/hermes" <<'S'
#!/usr/bin/env bash
[ "$1 $2" = "kanban --board" ] && set -- "$1" "${@:4}"   # scripts name the board (F4)
case "$1 $2" in
  "kanban show") { [ "$3" = t_00000000 ] || [ -n "${FAKE_SHOW_FAIL:-}" ]; } && exit 1; [ -z "${FAKE_SHOW_RAW:-}" ] || { printf '%s\n' "$FAKE_SHOW_RAW"; exit 0; }; printf '{"task":{"body":"%s","status":"%s"}}\n' "${FAKE_BODY:-}" "${FAKE_STATUS:-running}";;
  "kanban comment") echo "$*" >>"$ESCALATE_SUP_DIR/comments";;
  send*) echo "$*" >>"$ESCALATE_SUP_DIR/sends"
    # FAKE_SEND_HOLD=<path>: a slow alert. Says it arrived (<path>.in), then waits for <path>.go, at most 30 s.
    [ -z "${FAKE_SEND_HOLD:-}" ] || { touch "$FAKE_SEND_HOLD.in"; for _ in $(seq 300); do [ -e "$FAKE_SEND_HOLD.go" ] && break; sleep 0.1; done; }
    exit 1;;
esac
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" ESCALATE_SUP_DIR="$T/sup" FALLBACK_CONFIG="$T/no-such-fallback-config.json"   # no reroute unless a test writes one
E=${ESCALATE:-/workspace/bin/escalate.sh} fails=0   # ESCALATE=<copy>: a staged copy while it is being replaced
check() { local want=$1 desc=$2; shift 2; "$@" >/dev/null 2>"$T/err"; local rc=$?
  if [ "$rc" = "$want" ]; then echo "ok   $desc (exit $rc)"; else echo "FAIL $desc: want $want got $rc: $(cat "$T/err")"; fails=$((fails+1)); fi; }
last() { tail -1 "$T/sup/escalations.log" | jq -r "$1"; }

check 2 "no card id"            sh -c "echo hi | $E"
check 2 "unknown card"          sh -c "echo hi | $E t_00000000 haiku judge why"
check 2 "no reason"             sh -c "echo hi | $E t_12345678 haiku judge"
check 2 "empty prompt"          sh -c "$E t_12345678 haiku judge why </dev/null"
check 3 "opus for review"       sh -c "echo hi | $E t_12345678 opus review why"
check 0 "haiku 1"               sh -c "echo hi | $E t_12345678 haiku judge why"
[ "$(last .event)/$(last .model_used)/$(last .fallback)" = "OK/claude-haiku-5-5/false" ] || { echo "FAIL ok log: $(tail -1 "$T/sup/escalations.log")"; fails=$((fails+1)); }
check 0 "haiku 2"               sh -c "echo hi | $E t_12345678 haiku judge why"
check 3 "haiku 3 over limit"    sh -c "echo hi | $E t_12345678 haiku judge why"
[ "$(last .event)" = LIMIT ] || { echo "FAIL limit not logged"; fails=$((fails+1)); }
FAKE_SLEEP=2 sh -c "echo hi | $E t_12345678 opus rescue first" >/dev/null 2>&1 & sleep 0.5
check 3 "second concurrent opus" sh -c "echo hi | $E t_12345678 opus plan second"
wait
check 75 "forced pool, low risk" env ESCALATE_FORCE_POOL_EXHAUSTED=1 sh -c "echo hi | $E t_12345678 sonnet review why"
[ "$(last .event)/$(last .fallback)/$(last .model_used)" = "NO_REROUTE/true/none" ] || { echo "FAIL low-risk fallback log"; fails=$((fails+1)); }
check 75 "real pool string, high risk" env FAKE_OUT="Claude AI usage limit reached|resets 3am" FAKE_RC=1 FAKE_BODY="risk: high" sh -c "echo hi | $E t_12345678 sonnet review why"
[ "$(last .event)" = QUEUED ] && [ -s "$T/sup/state/queue.jsonl" ] || { echo "FAIL high-risk not queued"; fails=$((fails+1)); }
check 1 "non-JSON exit 0"      env FAKE_OUT='garbage' sh -c "echo hi | $E t_12345678 sonnet review why"
check 1 "is_error result"       env FAKE_OUT='{"is_error":true,"modelUsage":{}}' sh -c "echo hi | $E t_12345678 sonnet review why"
grep -q "fallback: true" "$T/sup/comments" || { echo "FAIL fallback not noted on card"; fails=$((fails+1)); }

# Queue (F15, F28, F29, T13, T15): a LIMIT refusal and every POOL_EXHAUSTED write one queue entry and one #alerts line;
# the caller keeps its exit code. bin/escalate-drain.sh replays an entry once, with limits and pool checked again.
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
Q="$T/sup/state/queue.jsonl" D=/workspace/bin/escalate-drain.sh
q() { jq -r --arg c "$1" 'select(.card == $c) | .state' "$Q" 2>/dev/null | tr '\n' ,; }
qid() { jq -r --arg c "$1" 'select(.card == $c) | .id' "$Q" | head -1; }
nalerts() { grep -c -- "$1" "$T/sup/sends" 2>/dev/null || true; }
runs() { cat "$T/sup/claude_n" 2>/dev/null || echo 0; }
setlimit() { sed -i "s/^$1=.*/$1=$2/" "$T/sup/limits.env"; }
setlimit HAIKU_MAX_PER_DAY 0
check 3 "T13: zeroed HAIKU_MAX_PER_DAY refused" sh -c "echo hi | $E t_aaaa0001 haiku judge zeroed"
pf=$(jq -r 'select(.card == "t_aaaa0001") | .prompt_file' "$Q" 2>/dev/null)
ok '[ "$(q t_aaaa0001)" = "queued," ] && [ "$(nalerts t_aaaa0001)" = 1 ] && grep -B1 "Claude Haiku for card t_aaaa0001" "$T/sup/sends" | grep -q "\[STL-LIM-401\]\*\*$" && grep -q "t_aaaa0001 escalate.sh LIMIT.*recorded in the queue as q_.*; run bin/escalate-drain.sh" "$T/sup/comments"' "F28: zeroed limit: one queue entry, one #alerts line, the card comment names the drain"
ok '[ -s "$pf" ] && jq -s -e "any(.[]; .card == \"t_aaaa0001\" and .reason == \"LIMIT\" and .model == \"haiku\" and .purpose == \"judge\" and .call_reason == \"zeroed\" and (.created | length > 0))" "$Q" >/dev/null' "F28: the entry records card, role, arguments, reason LIMIT, created; its prompt file is kept"
id=$(qid t_aaaa0001); n=$(runs)
$D --replay "$id" >/dev/null 2>&1
ok '[ "$(q t_aaaa0001)" = "queued," ] && [ "$(nalerts t_aaaa0001)" = 1 ] && [ "$(runs)" = "$n" ] && [ -s "$pf" ]' "drain while the limit is still zero: left queued, no run, no new entry, no new alert"
setlimit HAIKU_MAX_PER_DAY 40
FAKE_SLEEP=1 $D --replay "$id" >/dev/null 2>&1 & sleep 0.3; $D --replay "$id" >/dev/null 2>&1; wait
$D --replay "$id" >/dev/null 2>&1
ok '[ "$(runs)" = $((n + 1)) ] && [ "$(q t_aaaa0001)" = "replayed," ] && [ ! -e "$pf" ] && [ "$(nalerts t_aaaa0001)" = 1 ]' "double replay (two at once, then a third): one run, state replayed, prompt removed, still one alert"
check 75 "T15: forced pool, low-risk card" env ESCALATE_FORCE_POOL_EXHAUSTED=1 sh -c "echo hi | $E t_aaaa0002 sonnet review lowrisk"
ok '[ "$(q t_aaaa0002)" = "queued," ] && [ "$(nalerts t_aaaa0002)" = 1 ] && grep -B1 "a Sonnet request for card t_aaaa0002" "$T/sup/sends" | grep -q "\[STL-LIM-402\]\*\*$" && jq -s -e "any(.[]; .card == \"t_aaaa0002\" and .event == \"QUEUED\") and any(.[]; .card == \"t_aaaa0002\" and .event == \"NO_REROUTE\")" "$T/sup/escalations.log" >/dev/null' "F29: forced pool exhaustion on a low-risk card: QUEUED (NO_REROUTE kept), one #alerts line"
jq -c 'if .card == "t_aaaa0002" then .created = "2026-10-01T00:00:00Z" else . end' "$Q" > "$Q.tmp" && mv "$Q.tmp" "$Q"
check 75 "forced pool, card that is done before the drain" env ESCALATE_FORCE_POOL_EXHAUSTED=1 sh -c "echo hi | $E t_aaaa0003 sonnet review done-later"
n=$(runs); pf2=$(jq -r 'select(.card == "t_aaaa0002") | .prompt_file' "$Q")
$D --replay "$(qid t_aaaa0002)" >/dev/null 2>&1; FAKE_STATUS=done $D --replay "$(qid t_aaaa0003)" >/dev/null 2>&1
ok '[ "$(q t_aaaa0002)" = "stale," ] && [ "$(q t_aaaa0003)" = "stale," ] && [ "$(runs)" = "$n" ] && [ ! -e "$pf2" ]' "stale: older than QUEUE_MAX_AGE_HOURS, or the card is done: marked stale, skipped, prompt removed"
setlimit HAIKU_MAX_PER_DAY 0; setlimit QUEUE_MAX "$(jq -s '[.[] | select(.state == "queued")] | length' "$Q")"
check 3 "queue full: refused" sh -c "echo hi | $E t_aaaa0004 haiku judge full"
check 3 "queue full: refused again" sh -c "echo hi | $E t_aaaa0005 haiku judge full"
ok '[ -z "$(q t_aaaa0004)$(q t_aaaa0005)" ] && [ "$(nalerts "\[STL-LIM-403\]\*\*$")" = 1 ] && ! ls "$T/sup/state"/prompt-*-t_aaaa000[45]-* >/dev/null 2>&1' "queue cap: beyond QUEUE_MAX refused unqueued, one alert, no prompt file left"
setlimit QUEUE_MAX 50
check 3 "for the drop" sh -c "echo hi | $E t_aaaa0006 haiku judge drop"
pf3=$(jq -r 'select(.card == "t_aaaa0006") | .prompt_file' "$Q")
ok '$D --list | grep -q "$(qid t_aaaa0006).*queued.*LIMIT.*t_aaaa0006"' "--list shows id, state, reason and card"
$D --drop "$(qid t_aaaa0006)" >/dev/null 2>&1
ok '[ "$(q t_aaaa0006)" = "dropped," ] && [ ! -e "$pf3" ]' "--drop: dropped, prompt removed"
ok '( for f in "$T/sup/state"/prompt-*.txt; do [ -e "$f" ] || continue; jq -s -e --arg f "$f" "any(.[]; .prompt_file == \$f and .state == \"queued\")" "$Q" >/dev/null || exit 1; done )' "F16: no prompt file outlives its call (FAIL and OK paths) except a queued entry's"
ok '[ "$(ESCALATE_SUP_DIR=$T/sup bash -c "$D --replay nosuch; echo \$?" 2>/dev/null | tail -1)" = 2 ] && [ "$($D 2>/dev/null; echo $?)" = 2 ]' "drain: unknown id or no arguments is a usage error"
# Review M2: a replay that fails for a transient reason (kanban show fails: exit 2) keeps the entry and its prompt.
setlimit HAIKU_MAX_PER_DAY 0
check 3 "for the transient replay" sh -c "echo hi | $E t_aaaa0007 haiku judge transient"
setlimit HAIKU_MAX_PER_DAY 40; pf7=$(jq -r 'select(.card == "t_aaaa0007") | .prompt_file' "$Q")
FAKE_SHOW_FAIL=1 $D --replay "$(qid t_aaaa0007)" >/dev/null 2>&1
ok '[ "$(q t_aaaa0007)" = "queued," ] && [ -s "$pf7" ]' "M2: exit 2 on replay: left queued with its prompt"
# Review H2: extra claude args can never override escalate.sh's model, budget or permissions.
n=$(runs)
for a in "--model opus" "--model=opus" "--fallback-model haiku" "--max-budget-usd 100" "--permission-mode bypassPermissions" "--dangerously-skip-permissions" "--settings {}" "--add-dir /" "--allowedTools Bash"; do
  check 2 "extra arg refused: $a" sh -c "echo hi | $E t_12345678 sonnet review why -- $a"
done
ok '[ "$(runs)" = "$n" ]' "H2: no claude run for any of them"
check 0 "an ordinary extra arg is passed on" sh -c "echo hi | $E t_12345678 sonnet review why -- --verbose"
echo "events: $(jq -r .event "$T/sup/escalations.log" | sort | uniq -c | tr -s ' \n' ' ')"
# D42: `timeout 0` disables the timeout, so CALL_TIMEOUT 0, empty or non-numeric must fall back to 600 with a warning.
mkdir -p "$T/tbin"; printf '#!/bin/sh\necho "$1" >> "%s/timeout_args"\nshift\nexec "$@"\n' "$T" > "$T/tbin/timeout"; chmod +x "$T/tbin/timeout"
for v in 0 "" abc -5 5x; do
  setlimit CALL_TIMEOUT "$v"; : > "$T/timeout_args"
  ok '[ "$(PATH="$T/tbin:$PATH" sh -c "echo hi | $E t_12345678 haiku judge to 2>$T/err1" >/dev/null; echo $?)" = 0 ] && [ "$(cat "$T/timeout_args")" = 600 ] && grep -q "warning: CALL_TIMEOUT=.$v. is not a positive duration" "$T/err1" && [ "$(last .event)" = OK ] && jq -s -e "any(.[]; .event == \"WARN\" and (.detail | test(\"CALL_TIMEOUT\")))" "$T/sup/escalations.log" >/dev/null' "D42: CALL_TIMEOUT='$v' uses 600 and warns on stderr and in the log"
done
for v in 30 10m; do
  setlimit CALL_TIMEOUT "$v"; : > "$T/timeout_args"; : > "$T/err1"
  ok '[ "$(PATH="$T/tbin:$PATH" sh -c "echo hi | $E t_12345678 haiku judge to 2>$T/err1" >/dev/null; echo $?)" = 0 ] && [ "$(cat "$T/timeout_args")" = "$v" ] && ! grep -q CALL_TIMEOUT "$T/err1"' "D42: CALL_TIMEOUT=$v is passed to timeout unchanged, no warning"
done
setlimit CALL_TIMEOUT 600

# Ultrareview finding 3: an over-limit Haiku call releases haiku.lock before its alert and card comment.
setlimit HAIKU_MAX_PER_DAY 0; setlimit QUEUE_MAX 50
H="$T/hold"
FAKE_SEND_HOLD="$H" sh -c "echo hi | $E t_bbbb0001 haiku judge slow-alert" >/dev/null 2>&1 & a=$!
for _ in $(seq 100); do [ -e "$H.in" ] && break; sleep 0.1; done
ok '[ -e "$H.in" ]' "control: the over-limit call reached its alert"
ok 'flock -n "$T/sup/state/haiku.lock" true' "the Haiku lock is free while the alert is being sent"
timeout 10 sh -c "echo hi | $E t_bbbb0002 haiku judge second" >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 3 ]' "a second over-limit Haiku call is refused at once, not held behind the slow alert (exit $rc)"
touch "$H.go"; wait "$a"; rc=$?
ok '[ "$rc" = 3 ]' "control: the slow call still ends refused once its alert returns (exit $rc)"
# T15 reroute (OmniRoute): with the fallback config enabled (docs/hermes-local/fallback-routing.json format, FALLBACK_CONFIG) a
# low-risk pool-exhausted call is served by the config's runner and labelled as a fallback; a high-risk one still queues; a
# runner that fails, or reports a Claude or same-family model, changes nothing. The model name is a fixture the stub invents.
FIX=fixture-free-model
cat >"$T/bin/fbrun" <<'S'
#!/usr/bin/env bash
cat >/dev/null; echo "$*" >>"$ESCALATE_SUP_DIR/fb_calls"
[ -z "${FAKE_FB_RAW:-}" ] || { printf '%b\n' "$FAKE_FB_RAW"; exit 0; }
printf '{"model_used":"%s","text":"fallback answer"}\n' "${FAKE_FB_MODEL:-fixture-free-model}"; exit "${FAKE_FB_RC:-0}"
S
chmod +x "$T/bin/fbrun"
fbcfg() { jq -n --argjson en "$1" --arg r "$T/bin/fbrun" '{schema_version: 1, enabled: $en, runner: $r}' >"$T/fbcfg.json"; export FALLBACK_CONFIG="$T/fbcfg.json"; }
fbn() { cat "$T/sup/fb_calls" 2>/dev/null | wc -l; }
ev() { jq -r --arg c "$1" 'select(.card == $c) | .event' "$T/sup/escalations.log" | tr '\n' ' '; }
fbcfg false; n=$(fbn); echo hi | ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_cccc0000 sonnet review disabled >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 75 ] && [ "$(fbn)" = "$n" ] && ev t_cccc0000 | grep -q NO_REROUTE' "T15: enabled false in the config: the runner is never called, NO_REROUTE and queued (exit $rc)"
fbcfg true
out=$(echo hi | ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_cccc0001 sonnet review lowrisk-fb 2>/dev/null); rc=$?
ok '[ "$rc" = 0 ] && [ "$(fbn)" = 1 ] && [ "$(jq -r .fallback <<<"$out")" = true ] && [ "$(jq -r .model_used <<<"$out")" = "$FIX" ] && [ "$(jq -r .text <<<"$out")" = "fallback answer" ]' "T15: low-risk pool-exhausted call is rerouted: result labelled fallback with the serving model (exit $rc)"
ok 'grep -q -- "--role review" "$T/sup/fb_calls"' "T15: the runner is asked for the call's purpose as its role (per-role chain)"
ok '[ "$(ev t_cccc0001)" = "START POOL_EXHAUSTED FALLBACK " ] && jq -s -e --arg m "$FIX" "any(.[]; .card == \"t_cccc0001\" and .event == \"FALLBACK\" and .fallback == true and .model_used == \$m)" "$T/sup/escalations.log" >/dev/null && [ "$(q t_cccc0001)" = "" ]' "T15: escalations.log has POOL_EXHAUSTED then FALLBACK (fallback true, serving model), and nothing is queued"
ok 'grep -q "t_cccc0001" "$T/sup/comments" && grep -q "fallback: true" "$T/sup/comments" && grep -q "$FIX" "$T/sup/comments" && grep -q "STL-LIM-404" "$T/sup/sends"' "T15: the card comment says fallback with the serving model, and #alerts got STL-LIM-404"
ok 'grep "t_cccc0001" "$T/sup/comments" | grep -q "Alert to .* exit 1"' "T15: the card comment records the alert's exit code (the stub's send fails with 1), so a lost alert is visible on the card"
ok '! jq -e ".modelUsage // .total_cost_usd" <<<"$out" >/dev/null 2>&1' "T15: the rerouted result carries no Claude fields (modelUsage, cost), so it cannot pass for a Claude result"
n=$(fbn); out=$(echo hi | FAKE_BODY='risk: high' ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_cccc0002 sonnet review highrisk-fb 2>/dev/null); rc=$?
ok '[ "$rc" = 75 ] && [ "$(fbn)" = "$n" ] && [ "$(q t_cccc0002)" = "queued," ] && [ "$(ev t_cccc0002)" = "START POOL_EXHAUSTED QUEUED " ]' "T15: a high-risk card queues, the runner is never called (exit $rc)"
n=$(fbn); out=$(echo hi | FAKE_FB_RC=1 ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_cccc0003 sonnet review runner-fails 2>/dev/null); rc=$?
ok '[ "$rc" = 75 ] && [ "$(fbn)" = $((n + 1)) ] && [ "$(q t_cccc0003)" = "queued," ] && ev t_cccc0003 | grep -q NO_REROUTE' "T15: a failing runner leaves the old behaviour: NO_REROUTE and queued (exit $rc)"
for bad in claude-fixture fixture-sonnet-x; do
  n=$(fbn); out=$(echo hi | FAKE_FB_MODEL=$bad ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_cccc0004 sonnet review masquerade 2>/dev/null); rc=$?
  ok '[ "$rc" = 75 ] && ! ev t_cccc0004 | grep -qw FALLBACK && [ -z "$out" ]' "T15: a runner reporting '$bad' (Claude or the requested family) is refused, no result printed (exit $rc)"
done
n=$(fbn); echo hi | ESCALATE_REPLAY=q_x ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_cccc0005 sonnet review replay >/dev/null 2>&1
ok '[ "$(fbn)" = "$n" ]' "T15: a drain replay never reroutes (it stays a queued Claude call)"
# fix round 1 (red-team S6C-03, S6C-05): a risk line in any common spelling is high risk; the runner's output must be one object
# with a plain model name
i=0; for body in 'risk:\thigh' ' risk: high' '- risk: high' '**risk:** high' 'Risk level: high' 'risk = high' 'risk:\u00a0high' 'x\rrisk: high'; do
  i=$((i+1)); n=$(fbn); echo hi | FAKE_BODY="$body" ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_dddd000$i sonnet review "risk-variant-$i" >/dev/null 2>&1; rc=$?
  ok '[ "$rc" = 75 ] && [ "$(fbn)" = "$n" ] && [ "$(q t_dddd000$i)" = "queued," ]' "T15: risk spelling '$body' is treated as high risk: queued, runner never called (exit $rc)"
done
for bad in 'x <@123456789012345678> @everyone' 'Org/ClAuDe-x' 'a b'; do
  out=$(echo hi | FAKE_FB_MODEL="$bad" ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_dddd0010 sonnet review "name-check" 2>/dev/null); rc=$?
  ok '[ "$rc" = 75 ] && [ -z "$out" ]' "T15: served model name '$bad' is refused, no result (exit $rc)"
done
for raw in '{"model_used":["a"],"text":"t"}' '{"model_used":"m1","text":"a"}\n{"model_used":"m2","text":"b"}' '{"model_used":"m1","text":{"x":1}}' 'not json'; do
  out=$(echo hi | FAKE_FB_RAW="$raw" ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_dddd0011 sonnet review "shape-check" 2>/dev/null); rc=$?
  ok '[ "$rc" = 75 ] && [ -z "$out" ]' "T15: runner output '${raw:0:40}' is refused, no result (exit $rc)"
done
export FALLBACK_CONFIG="$T/no-such-fallback-config.json"

# --- follow-up fix round 1 (red-team S6D-04, S6D-05): the high-risk gate fails closed; secrets in a prompt never leave ---
fbcfg true; i=0
for body in 'High risk: migration' 'high-risk card' 'Risk is high' 'Risk tier: high' 'Risk (owner): high' 'risk: h\u200bigh' 'risk:             high' 'a very HIGH level of RISK'; do
  i=$((i+1)); n=$(fbn); echo hi | FAKE_BODY="$body" ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_eeee000$i sonnet review "risk-spelling-$i" >/dev/null 2>&1; rc=$?
  ok '[ "$rc" = 75 ] && [ "$(fbn)" = "$n" ] && [ "$(q t_eeee000$i)" = "queued," ]' "S6D-04: body '$body' counts as high risk: queued, runner never called (exit $rc)"
done
n=$(fbn); echo hi | FAKE_SHOW_RAW='not json at all' ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_eeee0009 sonnet review "unparsable-card" >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 75 ] && [ "$(fbn)" = "$n" ] && [ "$(q t_eeee0009)" = "queued," ]' "S6D-04: a card whose JSON cannot be read is treated as high risk (exit $rc)"
n=$(fbn); echo hi | FAKE_BODY='This is low risk, nobody called it high.' ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_eeee0010 sonnet review "control" >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 75 ] && [ "$(fbn)" = "$n" ] && [ "$(q t_eeee0010)" = "queued," ]' "S6D-04 note: a body that denies high risk in words is queued too (the gate prefers a false alarm)"
n=$(fbn); echo hi | FAKE_BODY='Rename a variable in the docs.' ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_eeee0011 sonnet review "plain-low" >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 0 ] && [ "$(fbn)" = $((n + 1)) ]' "S6D-04 control: a body with no risk wording is still rerouted (exit $rc)"
jq '.prompt_block_patterns = ["fixture-secret-[a-z]{6}", "BEGIN FIXTURE KEY"]' "$T/fbcfg.json" >"$T/fbcfg2.json" && export FALLBACK_CONFIG="$T/fbcfg2.json"
n=$(fbn); out=$(echo "please use fixture-secret-abcdef to log in" | ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_eeee0012 sonnet review "prompt-with-secret" 2>/dev/null); rc=$?
ok '[ "$rc" = 75 ] && [ -z "$out" ] && [ "$(fbn)" = "$n" ] && [ "$(q t_eeee0012)" = "queued," ] && jq -s -e "any(.[]; .card == \"t_eeee0012\" and .event == \"FALLBACK_SKIPPED\")" "$T/sup/escalations.log" >/dev/null' "S6D-05: a prompt matching a blocked pattern is queued, the runner is never called, FALLBACK_SKIPPED is logged (exit $rc)"
ok '! grep -q "fixture-secret-abcdef" "$T/sup/escalations.log" "$T/sup/comments" "$T/sup/sends"' "S6D-05: the matched text is in neither the log, the card comment nor the alert"
n=$(fbn); echo "an ordinary prompt" | ESCALATE_FORCE_POOL_EXHAUSTED=1 $E t_eeee0013 sonnet review "clean-prompt" >/dev/null 2>&1; rc=$?
ok '[ "$rc" = 0 ] && [ "$(fbn)" = $((n + 1)) ]' "S6D-05 control: a prompt that matches nothing is rerouted (exit $rc)"
export FALLBACK_CONFIG="$T/no-such-fallback-config.json"

[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
