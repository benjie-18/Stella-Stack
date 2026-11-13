#!/usr/bin/env bash
# Hermetic self-test for K11, paging a guard alert to #alerts (roles.log_alert -> alert_catalog.page_due / mark_paged, by the
# catalog's "page" policy): a stub `hermes` whose `send` is recorded and fails on demand, a scratch ESCALATE_SUP_DIR, no network.
# Overrides: AS = the bin dir with roles.py and alert_catalog.py (default /workspace/bin, the live files); RG = role-guard.py;
# WG = write-guard.py (its hard sys.path is its own problem: pass a copy whose import points at AS); ACAT = the catalog;
# SWF = the selftests.sh that holds the send-refusing wrapper.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# a colon in the temp path would split the PATH entry of the stub below: every page would reach the caller's hermes
case $T in *:*) echo "FAIL the temp path $T holds a colon, so the stub hermes would be on no PATH entry: nothing run, no hermes called"; echo "selftest FAIL (1)"; exit 1 ;; esac
AS=${AS:-/workspace/bin}; RG=${RG:-$AS/role-guard.py}; WG=${WG:-/workspace/docs/hermes-local/hooks/builder/write-guard.py}
ACAT=${ACAT:-/workspace/docs/hermes-local/alert-catalog.json}; SWF=${SWF:-/workspace/bin/selftests.sh}
ORIG_PATH=$PATH; fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
mkdir -p "$T/bin" "$T/cards" "$T/sup/logs"
export PYTHONDONTWRITEBYTECODE=1 ESCALATE_SUP_DIR=$T/sup ALERT_CATALOG=$ACAT FAKE_CARDS=$T/cards SENDS=$T/sends.log FAKE_FAIL=$T/fail PATH="$T/bin:$PATH"
sleep 600 & STR=$!   # a live process that is no ancestor of any hook: a card bound to it has a failed proof
trap 'kill $STR 2>/dev/null; rm -rf "$T"' EXIT
cat >"$T/bin/hermes" <<'SH'
#!/usr/bin/env bash
# stub: `send` is recorded in $SENDS and fails while $FAKE_FAIL exists; `kanban --board <b> show|list` read $FAKE_CARDS
if [ "$1" = send ]; then printf '%s\n' "$(echo "$*" | tr '\n' ' ')" >>"$SENDS"; [ -e "$FAKE_FAIL" ] && exit 1; exit 0; fi
[ "$1" = kanban ] || exit 1
shift 3
case "$1" in
  show) exec cat "$FAKE_CARDS/$(printf '%s' "$2" | tr -c 'A-Za-z0-9_' '_').json" ;;
  list) a=; [ "$2" = --assignee ] && a=$3
        cat "$FAKE_CARDS"/*.json 2>/dev/null | jq -sc --arg a "$a" '[.[] | select(.task.status == "running" and ($a == "" or .task.assignee == $a)) | {id: .task.id, assignee: .task.assignee}]' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/hermes"
fp() { echo "$(cat /proc/sys/kernel/random/boot_id):$(sed 's/.*) //' /proc/1/stat | awk '{print $20}')|$(sed 's/.*) //' /proc/$1/stat | awk '{print $20}')"; }
sends() { [ -f "$SENDS" ] && wc -l <"$SENDS" | tr -d ' ' || echo 0; }
la() {  # la <code> <card> <streak>: roles.log_alert as a guard calls it (through AS)
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import roles; roles.log_alert(sys.argv[2], streak=sys.argv[3], card=sys.argv[4], missing="m", profile="p")' "$AS" "$1" "$3" "$2" >/dev/null 2>&1; }
card_stranger() {  # card_stranger <card> <assignee> [last unblock, epoch]: a running card whose open run is bound to STR
  jq -nc --arg id "$1" --arg a "$2" --arg w "/workspace/.worktrees/$1" --arg sig "$(fp "$STR")" --argjson pid "$STR" --argjson u "${3:-null}" \
    '{task: {id: $id, assignee: $a, status: "running", workspace_path: $w, branch_name: ("stella/" + $id + "-x")}, runs: [{id: 7, ended_at: null}],
      events: ([{kind: "claimed", run_id: 7, payload: {lock: "host:1"}}, {kind: "worker_bound", run_id: 7, payload: {pid: $pid, claim_lock: "host:1", started_at: $sig}}]
               + (if $u == null then [] else [{kind: "unblocked", created_at: $u}] end))}' >"$FAKE_CARDS/$1.json"; }
rg() {  # rg <card>: role-guard refuses this kanban_complete (exit code printed; output in $T/rout)
  jq -nc --arg c "$1" '{hook_event_name: "pre_tool_call", tool_name: "kanban_complete", tool_input: {task_id: $c, summary: "x"}, profile: "builder-local", extra: {}}' \
    | python3 "$RG" >"$T/rout" 2>&1; echo $?; }
wg() {  # wg <card>: write-guard refuses a write into the card's worktree (exit code printed; output in $T/wout)
  local c=/workspace/.worktrees/$1
  jq -nc --arg c "$c" '{tool_name: "write_file", tool_input: {path: ($c + "/a.md"), content: "x"}, session_id: "s", cwd: $c, profile: "builder-local", extra: {}}' \
    | python3 "$WG" >"$T/wout" 2>&1; echo $?; }

echo "## card_streak (GRD-601): once per card per streak"
: >"$SENDS"
la STL-GRD-601 t_a0000001 100
ok '[ "$(sends)" = 1 ]' "card_streak: the first GRD-601 for a card sends to #alerts"
la STL-GRD-601 t_a0000001 100
ok '[ "$(sends)" = 1 ] && [ "$(grep -c "^STL-GRD-601 " "$T/sup/logs/alerts.log")" = 2 ]' "card_streak: a repeat for the same card and streak only logs (2 lines, 1 send)"
la STL-GRD-601 t_a0000001 200
ok '[ "$(sends)" = 2 ]' "card_streak: a new streak (the card was unblocked since) sends again"
la STL-GRD-601 t_a0000002 200
ok '[ "$(sends)" = 3 ]' "card_streak: another card sends"

echo "## hourly (GRD-602): once an hour per card"
: >"$SENDS"
la STL-GRD-602 t_b0000001 ""
ok '[ "$(sends)" = 1 ]' "hourly: the first GRD-602 sends"
la STL-GRD-602 t_b0000001 ""
ok '[ "$(sends)" = 1 ]' "hourly: a repeat within the hour only logs"
touch -d "@$(( $(date +%s) - 7200 ))" "$T/sup/state/page/STL-GRD-602-t_b0000001"
la STL-GRD-602 t_b0000001 ""
ok '[ "$(sends)" = 2 ]' "hourly: the state file aged two hours (an hour has passed): it sends again"

echo "## log policy (STL-ESC-210 has no page field)"
: >"$SENDS"
la STL-ESC-210 t_c0000001 ""; la STL-ESC-210 t_c0000001 ""
ok '[ "$(sends)" = 0 ] && [ "$(grep -c "^STL-ESC-210 " "$T/sup/logs/alerts.log")" = 2 ]' "log policy: a code with no page policy is logged, never sent"

echo "## a failed send"
: >"$SENDS"; touch "$FAKE_FAIL"
la STL-GRD-601 t_d0000001 300
ok '[ "$(sends)" = 1 ] && [ ! -e "$T/sup/state/page/STL-GRD-601-t_d0000001" ]' "a failed send is attempted and writes no state"
rm -f "$FAKE_FAIL"
la STL-GRD-601 t_d0000001 300
ok '[ "$(sends)" = 2 ] && [ -e "$T/sup/state/page/STL-GRD-601-t_d0000001" ]' "the next alert retries the send, which now works, and records the streak"

echo "## GRD-601 through role-guard, GRD-603 through write-guard"
: >"$SENDS"; card_stranger t_e0000001 builder-local
ok '[ "$(rg t_e0000001)" = 2 ] && grep -qF "STL-GRD-601" "$T/rout" && [ "$(sends)" = 1 ]' "role-guard GRD-601: refused, and the first one pages"
ok '[ "$(rg t_e0000001)" = 2 ] && [ "$(sends)" = 1 ]' "role-guard GRD-601: a second refusal in the same streak only logs"
card_stranger t_e0000001 builder-local 5000
ok '[ "$(rg t_e0000001)" = 2 ] && [ "$(sends)" = 2 ]' "role-guard GRD-601: after the card's unblock (a new streak) it pages once more"
: >"$SENDS"; card_stranger t_f0000001 builder-local
ok '[ "$(wg t_f0000001)" = 2 ] && grep -qF "[STL-GRD-603]" "$T/wout" && [ "$(sends)" = 1 ]' "write-guard GRD-603: refused, and the first one pages"
ok '[ "$(wg t_f0000001)" = 2 ] && [ "$(sends)" = 1 ]' "write-guard GRD-603: a second refusal in the same streak only logs"
card_stranger t_f0000001 builder-local 5000
ok '[ "$(wg t_f0000001)" = 2 ] && [ "$(sends)" = 2 ]' "write-guard GRD-603: after the card's unblock it pages once more"

echo "## catalog policy"
jq '(.alerts[] | select(.code == "STL-GRD-601") | .page) = "sometimes"' "$ACAT" >"$T/bad-catalog.json"
ok '[ "$(ALERT_CATALOG=$T/bad-catalog.json python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import alert_catalog; print(alert_catalog.validate())" "$AS" 2>/dev/null)" != "[]" ] && ALERT_CATALOG=$T/bad-catalog.json python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import alert_catalog; print(alert_catalog.validate())" "$AS" 2>/dev/null | grep -qF "page sometimes"' "validate() rejects page \"sometimes\""
ok '[ "$(python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import alert_catalog; print(alert_catalog.validate())" "$AS" 2>/dev/null)" = "[]" ]' "the staged catalog validates (every page value is log, hourly or card_streak)"

echo "## the selftests.sh wrapper: no selftest posts to Discord"
# The runner's own wrapper line (its printf), built with the runner's variable names. Not found: both rows fail and no hermes
# is called. The send runs only when the wrapper is the first hermes on PATH, and the wrapper's "real" one is a stop that
# never passes a send on, so a broken wrapper fails the row instead of posting.
WL=$(grep -m1 '^ *printf .*hermes send refused in a selftest.*>"\$q/\.bin/hermes"$' "$SWF")
[ "$(grep -c '>"\$q/\.bin/hermes"' "$SWF")" = 1 ] || WL=   # the line found must be the only one that writes the wrapper, so it is the one the runner runs
cat >"$T/wrap.sh" <<WRAP
set -u
q=$(printf %q "$T/g"); mkdir -p "\$q/.bin"; real_hermes=\$q/real
printf '#!/usr/bin/env bash\nfor a; do [ "\$a" != send ] || exit 7; done\nexec %q "\$@"\n' "\$(command -v hermes || echo /bin/false)" >"\$real_hermes"
$WL
chmod +x "\$real_hermes" "\$q/.bin/hermes"; export PATH="\$q/.bin:\$PATH"
[ "\$(command -v hermes)" = "\$q/.bin/hermes" ] || exit 9
hermes send --to discord:#alerts --quiet body; echo "send_rc=\$?"
echo "where=\$(command -v hermes)"
echo "version=\$(hermes --version 2>/dev/null | head -1)"
WRAP
W=; : >"$T/wrap.err"; [ -z "$WL" ] || W=$(env PATH="$ORIG_PATH" bash "$T/wrap.sh" 2>"$T/wrap.err")
REAL_VERSION=; [ -z "$WL" ] || REAL_VERSION=$(env PATH="$ORIG_PATH" hermes --version 2>/dev/null | head -1)
ok 'printf "%s\n" "$W" | grep -qx "send_rc=1" && printf "%s\n" "$W" | grep -q "^where=.*/hermes$" && grep -qF "hermes send refused in a selftest" "$T/wrap.err"' "the wrapper refuses hermes send (exit 1, names the refusal) and comes first on PATH"
ok '[ "$(printf "%s\n" "$W" | sed -n "s/^version=//p")" = "$REAL_VERSION" ] && [ -n "$REAL_VERSION" ]' "the wrapper passes every other call through (hermes --version is the real one)"
ok 'grep -q "alert-page" "$SWF"' "the selftests.sh list runs alert-page"

[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
