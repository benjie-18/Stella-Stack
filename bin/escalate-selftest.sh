#!/usr/bin/env bash
# Hermetic self-test for bin/escalate.sh: stub claude/hermes, scratch state dir, no spend, no board writes.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sup"
sed -e 's/^HAIKU_MAX_PER_DAY=.*/HAIKU_MAX_PER_DAY=2/' /workspace/.supervisor/limits.env >"$T/sup/limits.env"
cat >"$T/bin/claude" <<'S'
#!/usr/bin/env bash
ok='{"type":"result","is_error":false,"total_cost_usd":0.001,"modelUsage":{"claude-haiku-5-5":{}}}'
cat >/dev/null; sleep "${FAKE_SLEEP:-0}"; printf '%s\n' "${FAKE_OUT:-$ok}"; exit "${FAKE_RC:-0}"
S
cat >"$T/bin/hermes" <<'S'
#!/usr/bin/env bash
case "$1 $2" in
  "kanban show") [ "$3" = t_00000000 ] && exit 1; printf '{"task":{"body":"%s"}}\n' "${FAKE_BODY:-}";;
  "kanban comment") echo "$*" >>"$ESCALATE_SUP_DIR/comments";;
  send*) exit 1;;
esac
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" ESCALATE_SUP_DIR="$T/sup"
E=/workspace/bin/escalate.sh fails=0
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
echo "events: $(jq -r .event "$T/sup/escalations.log" | sort | uniq -c | tr -s ' \n' ' ')"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
