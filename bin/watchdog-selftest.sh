#!/usr/bin/env bash
# Hermetic self-test for bin/watchdog.sh's alert path (S36): stub npm and hermes, scratch root and state, a scratch
# gateway log, pause sentinel and settings file (WATCHDOG_SETTINGS); WATCHDOG_ALERT_TARGET points it at the stub. Checks
# streak dedupe and the recovery line (S11), the send retry (S11), a hung step (S10), a stale poller heartbeat, a gone or
# disconnected gateway (S5), and D47: a quiet log is no alert, the unknown case, the rerun of a failed check, nothing hard-coded.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/root" "$T/sup/state"
printf '{"scripts": {"test": "x", "lint": "x"}}\n' > "$T/root/package.json"
cat > "$T/bin/npm" <<'S'
#!/usr/bin/env bash
step="${@: -1}"
[ "$step" != "${FAKE_HANG_STEP:-}" ] || sleep 5
[ "$step" != "${FAKE_FAIL_STEP:-}" ] || { [ -z "${FAKE_FAIL_OUT:-}" ] || printf 'FAIL fake-selftest\n     FAIL fake line\n'; exit 1; }
exit 0
S
cat > "$T/bin/hermes" <<'S'
#!/usr/bin/env bash
[ "$1" = send ] || exit 0
n=$(( $(cat "$ESCALATE_SUP_DIR/send_n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$ESCALATE_SUP_DIR/send_n"
[ "$n" -gt "${FAKE_SEND_FAILS:-0}" ] || exit 1
shift; printf '%s\n' "$*" >> "$ESCALATE_SUP_DIR/sends"
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" ESCALATE_SUP_DIR="$T/sup" WATCHDOG_ROOT="$T/root" WATCHDOG_ALERT_TARGET="stub:#alerts" \
  WATCHDOG_SETTINGS="$T/settings.json" WATCHDOG_STEP_TIMEOUT=2 \
  TZ=America/Toronto OWNER_CONFIG="$T/no-owner.env"   # D44: alert times in a fixed zone, no real owner config
W=/workspace/bin/watchdog.sh fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
n() { grep -c -- "$1" "$T/sup/sends" 2>/dev/null || true; }
# The settings are the real file with this test's log, pause file and process name; gw edits them for one scenario.
fresh() { date +%s > "$T/sup/state/reply-poll.heartbeat"; : > "$T/gateway.log"
  jq --arg l "$T/gateway.log" --arg e "$T/ESTOP" '.gateway.activity_logs = [$l] | .gateway.pause_file = $e | .gateway.process_match = "watchdog-selftest" | .test_step.npm_script = "test"' \
    /workspace/docs/hermes-local/watchdog-settings.json > "$T/settings.json"; }
gw() { jq "$@" "$T/settings.json" > "$T/settings.tmp" && mv "$T/settings.tmp" "$T/settings.json"; }

fresh; $W >/dev/null 2>&1
ok '[ ! -s "$T/sup/sends" ] && jq -e ".ok == true" "$T/sup/status.json" >/dev/null' "all healthy: no alert, status ok"
fresh; FAKE_FAIL_STEP=test $W >/dev/null 2>&1; fresh; FAKE_FAIL_STEP=test $W >/dev/null 2>&1
ok '[ "$(n "\[STL-WDG-101\]\*\*$")" = 1 ] && [ "$(n "automatic test run failed")" = 1 ]' "S11: a failing test step alerts once per streak, not every run"
fresh; $W >/dev/null 2>&1; fresh; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-WDG-101 resolved\]")" = 1 ]' "S11: one recovery line when the streak ends, and only one"
fresh; FAKE_SEND_FAILS=$(( $(cat "$T/sup/send_n") + 1 )) FAKE_FAIL_STEP=lint $W >/dev/null 2>&1
ok '[ "$(n "automatic code style check failed")" = 1 ]' "S11: a failed send is retried once and the alert arrives"
fresh; $W >/dev/null 2>&1
fresh; FAKE_HANG_STEP=test $W >/dev/null 2>&1
ok 'jq -e "[.steps[] | select(.step == \"test\")][0] | .exit_code == 124 and .hung == true" "$T/sup/status.json" >/dev/null && [ "$(n "\[STL-WDG-102\]\*\*$")" = 1 ] && [ "$(n "automatic test run did not finish in time")" = 1 ]' "S10: a step over WATCHDOG_STEP_TIMEOUT is killed, recorded as hung and alerted"
fresh; $W >/dev/null 2>&1
echo $(( $(date +%s) - 600 )) > "$T/sup/state/reply-poll.heartbeat"; touch "$T/gateway.log"; $W >/dev/null 2>&1
echo $(( $(date +%s) - 900 )) > "$T/sup/state/reply-poll.heartbeat"; touch "$T/gateway.log"; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-ESC-201\]\*\*$")" = 1 ] && [ "$(n "has not run for 10 minutes")" = 1 ]' "poller liveness: a heartbeat older than 5 minutes alerts once per streak"
fresh; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-ESC-201 resolved\]")" = 1 ]' "poller liveness: one line when the heartbeat is fresh again"
fresh; touch -d "-30 min" "$T/gateway.log"; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-102\]")" = 0 ]' "D42: a gateway.log quiet for 30 minutes is not an alert (threshold 60)"
DOWN='2026-10-29 08:00:00,000 INFO hermes_plugins.platforms__discord.adapter: [Discord] Disconnected'
fresh; echo "$DOWN" > "$T/gateway.log"; touch -d "-70 min" "$T/gateway.log"; $W >/dev/null 2>&1; touch -d "-75 min" "$T/gateway.log"; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-102\]\*\*$")" = 1 ]' "S5/D47: a disconnect as the newest connection line, log silent over 60 minutes while not paused: one alert per outage"
fresh; gw '.gateway.process_match = "no-such-gateway-process"'; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-101\]")" = 0 ]' "S5: the outage stays one streak when its cause changes (disconnected, then process gone)"
fresh; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-102 resolved\]")" = 1 ]' "S5: one recovery line, for the code that opened the outage"
: > "$T/ESTOP"; fresh; gw '.gateway.process_match = "no-such-gateway-process"'; $W >/dev/null 2>&1; echo "$DOWN" > "$T/gateway.log"; touch -d "-90 min" "$T/gateway.log"; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-101\]")" = 0 ] && [ "$(n "\[STL-GW-102\]\*\*$")" = 1 ]' "S5: no gateway alert while Hermes is paused (ESTOP present)"
rm -f "$T/ESTOP"; fresh; gw '.gateway.process_match = "no-such-gateway-process"'; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-101\]\*\*$")" = 1 ]' "S5: gateway process gone while not paused: alerted"
ok '! grep -qE "exit [0-9]|\.sh|[Hh]ermes|gateway\.log|heartbeat" "$T/sup/sends" && [ "$(n "^First seen [0-9][0-9]:[0-9][0-9]$")" -ge 5 ]' "D44: plain wording (no exit code, script, Hermes or log file name), a local First seen time"
ok 'grep -q "^STL-WDG-101 .*failed=.test (exit 1)" "$T/sup/logs/alerts.log" && grep -q "^STL-WDG-102 .*failed=.test (hung" "$T/sup/logs/alerts.log"' "D44: the raw failure (step, exit code) is in alerts.log, code first"
r=$(n "\[STL-WDG-101 resolved\]"); printf '2026-10-28T13:00:00Z\n' > "$T/sup/state/watchdog-open/build"; fresh; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-WDG-101 resolved\]")" = $((r + 1)) ] && [ "$(n "failing from 09:00 to")" = 1 ] && [ ! -e "$T/sup/state/watchdog-open/build" ]' "D44: a problem opened before D44 (time only in its open file) still clears, as STL-WDG-101"
ok 'grep -q "^export PATH=\"\$PATH:/home/node/.local/bin" "$W"' "S11: watchdog.sh sets a PATH that holds hermes itself (cron's PATH lacked it)"
# D47: an alert claims only what its evidence proves. reset clears the sends and the open problems between scenarios.
reset() { rm -f "$T"/sup/state/watchdog-open/* "$T/sup/state/model-watch.fails"; : > "$T/sup/sends"; fresh; }
hg() { jq -r .health.gateway "$T/sup/status.json"; }
logw() { printf '%s\n' "$2" > "$T/$1"; touch -d "-${3:-120} min" "$T/$1"; }
UP='2026-10-29 07:00:00,000 INFO gateway.run: ✓ discord connected'
PLAIN='exit [0-9]|\.sh|[Hh]ermes|gateway\.log|heartbeat'
WLOG="$T/sup/logs/watchdog.log"
reset; logw gateway.log "$UP"; $W >/dev/null 2>&1
ok '[ ! -s "$T/sup/sends" ] && [ "$(hg)" = quiet ] && grep -q "gateway quiet (quiet): process up; the newest connection line is a connect" "$WLOG"' "D47: process up, log quiet for 2 hours, newest connection line is a connect: no alert, one evidence line in the watchdog log"
reset; logw gateway.log ""; : > "$T/second.log"; gw --arg s "$T/second.log" '.gateway.activity_logs += [$s]'; $W >/dev/null 2>&1
ok '[ ! -s "$T/sup/sends" ] && [ "$(hg)" = active ]' "D47: activity only in the second log: no alert"
reset; gw '.gateway.process_match = "no-such-gateway-process"'; $W >/dev/null 2>&1; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-101\]\*\*$")" = 1 ] && grep -q "No running program for Stella.s Discord connection was found" "$T/sup/sends" && ! grep -qiE "gone quiet|silent|no activity|$PLAIN" "$T/sup/sends"' "D47: process missing: one alert that names the process, not a quiet log"
fresh; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-101 resolved\]")" = 1 ] && grep -q "the check saw: her log was written recently" "$T/sup/sends" && ! grep -q "quiet or down" "$T/sup/sends"' "D47: recovery after a missing process says what was observed"
reset; printf '%s\n%s\n' "$UP" "$DOWN" > "$T/gateway.log"; $W >/dev/null 2>&1; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-102\]\*\*$")" = 1 ] && grep -q "dropped at 08:00 and has not come back" "$T/sup/sends" && ! grep -qiE "gone quiet|$PLAIN" "$T/sup/sends"' "D47: a disconnect as the newest connection line, even with a fresh log: one alert with the owner's time"
printf '%s\n' '2026-10-29 08:05:00,000 INFO gateway.run: ✓ discord reconnected successfully' >> "$T/gateway.log"; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-102 resolved\]")" = 1 ] && grep -q "the check saw: her log was written recently" "$T/sup/sends" && ! grep -q "quiet or down" "$T/sup/sends"' "D47: recovery after a disconnect says what was observed"
reset; WATCHDOG_SETTINGS="$T/no-such.json" $W >/dev/null 2>&1; WATCHDOG_SETTINGS="$T/no-such.json" $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-103\]\*\*$")" = 1 ] && [ "$(n "\[STL-GW-10[12]\]")" = 0 ] && grep -q "the settings for this check are missing or invalid" "$T/sup/sends" && ! grep -qE "$PLAIN" "$T/sup/sends"' "D47: unreadable settings: one unknown alert, not a down alert"
fresh; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-103 resolved\]")" = 1 ] && grep -q "it saw: her log was written recently" "$T/sup/sends"' "D47: recovery after unknown says what the check saw"
reset; rm -f "$T/gateway.log"; $W >/dev/null 2>&1; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-103\]\*\*$")" = 1 ] && [ "$(n "\[STL-GW-10[12]\]")" = 0 ] && grep -q "her log files cannot be read" "$T/sup/sends"' "D47: no readable log: one unknown alert"
# A failed test is run again by the name the settings give; only a second failure alerts, naming the check and its first line.
mkdir -p "$T/root/bin"; printf '#!/usr/bin/env bash\n[ "$1" = fake-selftest ] && [ -e "%s/rerun_ok" ]\n' "$T" > "$T/root/bin/selftests.sh"; chmod +x "$T/root/bin/selftests.sh"   # the rerun goes through the suite runner (bin/selftests.sh {check}): isolated like the first run
reset; touch "$T/rerun_ok"; FAKE_FAIL_STEP=test FAKE_FAIL_OUT=1 $W >/dev/null 2>&1
ok '[ ! -s "$T/sup/sends" ] && grep -q "flaky: fake-selftest failed once and passed on the rerun (fake line)" "$WLOG" && jq -e "[.steps[] | select(.step == \"test\")][0] | .exit_code == 0 and .rerun_passed == \"fake-selftest\"" "$T/sup/status.json" >/dev/null' "D47: a failed check that passes on the rerun raises no alert and is logged as flaky"
reset; rm -f "$T/rerun_ok"; FAKE_FAIL_STEP=test FAKE_FAIL_OUT=1 $W >/dev/null 2>&1; FAKE_FAIL_STEP=test FAKE_FAIL_OUT=1 $W >/dev/null 2>&1
ok '[ "$(n "\[STL-WDG-101\]\*\*$")" = 1 ] && grep -q "automatic test run (fake-selftest) failed" "$T/sup/sends" && grep -qF "First failing line: \"fake line\"." "$T/sup/sends" && grep -q "^STL-WDG-101 .*failed=.test (exit 1): fake-selftest: fake line" "$T/sup/logs/alerts.log"' "D47: a check that fails again alerts once, naming the check and its first failing line"
fresh; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-WDG-101 resolved\]")" = 1 ]' "D47: the failed-check streak ends with one recovery line"
# Nothing is hard-coded: a fake log name, fake markers and a fake process name in the settings change the verdict.
reset; gw --arg l "$T/zz-custom.log" '.gateway.activity_logs = [$l] | .gateway.connected_marker = "ZZ-UP-MARKER" | .gateway.disconnected_marker = "ZZ-DOWN-MARKER"'
logw zz-custom.log "2026-10-29 07:00:00 ZZ-UP-MARKER"; $W >/dev/null 2>&1
ok '[ ! -s "$T/sup/sends" ] && [ "$(hg)" = quiet ]' "D47: a fake log name and fake connect marker in the settings: quiet, no alert"
printf '%s\n' "2026-10-29 07:30:00 ZZ-DOWN-MARKER" >> "$T/zz-custom.log"; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-102\]\*\*$")" = 1 ] && grep -q "dropped at 07:30 " "$T/sup/sends"' "D47: a fake disconnect marker in the settings: down, alert with its time"
reset; gw '.gateway.process_match = "zz-no-such-process"'; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-101\]\*\*$")" = 1 ]' "D47: a fake process name in the settings: down"
SET=/workspace/docs/hermes-local/watchdog-settings.json
ok 'WATCHDOG_SETTINGS=$SET python3 -I /workspace/bin/watchdog_settings.py --check >/dev/null' "D47: the shipped settings file passes --check"
jq 'del(.gateway.process_match)' $SET > "$T/bad1.json"; jq '.schema_version = 2' $SET > "$T/bad2.json"; jq '.gateway.connected_marker = "("' $SET > "$T/bad3.json"; jq '.test_rerun.rerun_command = "x"' $SET > "$T/bad4.json"
ok '( for f in bad1 bad2 bad3 bad4; do WATCHDOG_SETTINGS="$T/$f.json" python3 -I /workspace/bin/watchdog_settings.py --check >/dev/null 2>&1 && exit 1; done; exit 0 )' "D47: --check refuses a missing key, a wrong schema_version, a bad regex and a rerun command without {check}"
# K10: a quiet gateway must still refresh its own status file (state_file, every ~60 s); a stale one is "can't tell", not "down".
WS=/workspace/bin/watchdog_settings.py
st() { printf '{"gateway_state":"running","updated_at":"%s"}\n' "$(date -u -d "-$1 min" +%FT%T.000000+00:00)" > "$T/gateway_state.json"; }   # updated_at as Hermes writes it
gws() { gw --arg s "${1:-$T/gateway_state.json}" '.gateway.state_file = $s | .gateway.state_max_age_minutes = 10'; }
gcause() { WATCHDOG_SETTINGS="$T/settings.json" python3 -I $WS gateway | jq -r .cause; }
reset; logw gateway.log "$UP"; gws; st 2; $W >/dev/null 2>&1
ok '[ ! -s "$T/sup/sends" ] && [ "$(hg)" = quiet ] && [ "$(gcause)" = quiet ]' "K10: quiet gateway, status file refreshed 2 minutes ago: quiet, no alert"
reset; logw gateway.log "$UP"; gws; st 30; $W >/dev/null 2>&1; $W >/dev/null 2>&1
ok '[ "$(gcause)" = state_stale ] && [ "$(hg)" = unknown ] && [ "$(n "\[STL-GW-103\]\*\*$")" = 1 ] && [ "$(n "\[STL-GW-10[12]\]")" = 0 ] && grep -q "stopped updating her own status, so she may be stuck" "$T/sup/sends" && ! grep -qE "$PLAIN" "$T/sup/sends" && grep -q "gateway unknown (state_stale)" "$WLOG"' "K10: quiet gateway, status file 30 minutes old: one STL-GW-103 (cause state_stale) in plain words, not a down alert"
st 1; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-103 resolved\]")" = 1 ] && grep -q "it saw: her program is running and the newest connection line" "$T/sup/sends" && [ "$(hg)" = quiet ]' "K10: the status file refreshed again: one recovery line, back to quiet"
reset; logw gateway.log "$UP"; gws; rm -f "$T/gateway_state.json"; $W >/dev/null 2>&1
ok '[ ! -s "$T/sup/sends" ] && [ "$(hg)" = quiet ] && [ "$(gcause)" = quiet ]' "K10: status file missing: quiet, as before"
bad=""
for body in 'not json {' '{"gateway_state":"running"}' '{"updated_at":"yesterday-ish"}' '{"updated_at":null}' '[]'; do
  reset; logw gateway.log "$UP"; gws; printf '%s\n' "$body" > "$T/gateway_state.json"; $W >/dev/null 2>&1
  { [ ! -s "$T/sup/sends" ] && [ "$(hg)" = quiet ]; } || bad="$bad [$body]"
done
ok '[ -z "$bad" ]' "K10: status file unreadable (bad JSON, no updated_at, bad time, null, wrong shape): quiet, as before${bad:+ (alerted for:$bad)}"
reset; gws; st 30; touch "$T/gateway.log"; $W >/dev/null 2>&1
ok '[ ! -s "$T/sup/sends" ] && [ "$(hg)" = active ]' "K10: stale status file but the log was written just now: active, no alert (the file is only checked when the log is quiet)"
reset; logw gateway.log "$DOWN"; gws; st 30; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-102\]\*\*$")" = 1 ] && [ "$(n "\[STL-GW-103\]")" = 0 ] && [ "$(gcause)" = disconnect ]' "K10: a disconnect as the newest connection line stays STL-GW-102 even with a stale status file"
reset; logw gateway.log "not a connection line"; gws; st 30; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-103\]\*\*$")" = 1 ] && [ "$(gcause)" = no_marker ] && ! grep -q "stopped updating her own status" "$T/sup/sends"' "K10: no connection line at all and a stale status file: the no-marker cause, not state_stale"
reset; gws; : > "$T/ESTOP"; gw '.gateway.process_match = "no-such-gateway-process"'; st 30; $W >/dev/null 2>&1; rm -f "$T/ESTOP"
ok '[ ! -s "$T/sup/sends" ] && [ "$(hg)" = paused ]' "K10: paused (ESTOP) with a stale status file: not checked, no alert"
# "~" in the settings is expanded with $HOME (a scratch HOME here): the settings hold no user's path.
H="$T/home"; mkdir -p "$H/.hermes/logs"
tilde() { reset; gw '.gateway.pause_file = "~/.hermes/ESTOP" | .gateway.activity_logs = ["~/.hermes/logs/gateway.log"] | .gateway.state_file = "~/.hermes/gateway_state.json" | .gateway.state_max_age_minutes = 10'
  printf '%s\n' "$UP" > "$H/.hermes/logs/gateway.log"; touch -d "-120 min" "$H/.hermes/logs/gateway.log"; rm -f "$H/.hermes/ESTOP"; }
tilde; st 2; cp "$T/gateway_state.json" "$H/.hermes/gateway_state.json"; HOME=$H $W >/dev/null 2>&1
ok '[ ! -s "$T/sup/sends" ] && [ "$(hg)" = quiet ] && [ "$(HOME=$H gcause)" = quiet ]' "K10: ~/ in activity_logs and state_file is expanded: the log under the scratch HOME is read (quiet, fresh status file)"
tilde; st 30; cp "$T/gateway_state.json" "$H/.hermes/gateway_state.json"; HOME=$H $W >/dev/null 2>&1
ok '[ "$(HOME=$H gcause)" = state_stale ] && [ "$(n "\[STL-GW-103\]\*\*$")" = 1 ]' "K10: ~/ in state_file is expanded: the stale file under the scratch HOME raises STL-GW-103"
tilde; gw '.gateway.process_match = "no-such-gateway-process"'; : > "$H/.hermes/ESTOP"; HOME=$H $W >/dev/null 2>&1
ok '[ ! -s "$T/sup/sends" ] && [ "$(hg)" = paused ] && [ "$(HOME=$H gcause)" = paused ]' "K10: ~/ in pause_file is expanded: the sentinel under the scratch HOME pauses the check"
tilde; gw '.gateway.process_match = "no-such-gateway-process"'; HOME=$H $W >/dev/null 2>&1
ok '[ "$(n "\[STL-GW-101\]\*\*$")" = 1 ]' "K10: the same scratch HOME without the sentinel: process gone is alerted (the pause above was the expanded ~)"
ok 'jq -e "[.gateway.pause_file, .gateway.activity_logs[], .gateway.state_file] | all(startswith(\"~/\"))" $SET >/dev/null && ! grep -q "/home/" $SET' "K10: the shipped settings use ~/ for every gateway path (no user path)"
ok 'jq -e ".gateway.state_file == \"~/.hermes/gateway_state.json\" and .gateway.state_max_age_minutes == 10" $SET >/dev/null' "K10: the shipped settings name the status file and a 10 minute age"
# No heartbeat file yet is "an unknown number of minutes", never a count from the epoch.
reset; rm -f "$T/sup/state/reply-poll.heartbeat"; $W >/dev/null 2>&1; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-ESC-201\]\*\*$")" = 1 ] && grep -q "has not run for an unknown number of minutes\." "$T/sup/sends" && ! grep -qE "[0-9]{4,} minutes" "$T/sup/sends" && ! grep -qE "heartbeat_age_s=.?[0-9]{5,}" "$T/sup/logs/alerts.log"' "K10: no heartbeat file: STL-ESC-201 says an unknown number of minutes, no huge count"
fresh; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-ESC-201 resolved\]")" = 1 ]' "K10: the heartbeat appears: one recovery line"
reset; echo $(( $(date +%s) - 1500 )) > "$T/sup/state/reply-poll.heartbeat"; $W >/dev/null 2>&1
ok '[ "$(n "\[STL-ESC-201\]\*\*$")" = 1 ] && grep -q "has not run for 25 minutes\." "$T/sup/sends" && ! grep -q "unknown number" "$T/sup/sends"' "K10: a stale heartbeat file still gives the real count of minutes"
# state_file needs a positive whole state_max_age_minutes; --check refuses the rest.
bad=""
for j in '.gateway.state_max_age_minutes = 0' '.gateway.state_max_age_minutes = -5' '.gateway.state_max_age_minutes = "10"' '.gateway.state_max_age_minutes = 1.5' \
         '.gateway.state_max_age_minutes = null' 'del(.gateway.state_max_age_minutes)' '.gateway.state_file = ""' '.gateway.state_file = 7' '.gateway.state_file = null'; do
  jq "$j" $SET > "$T/badk.json"; WATCHDOG_SETTINGS="$T/badk.json" python3 -I $WS --check >/dev/null 2>&1 && bad="$bad [$j]"
done
ok '[ -z "$bad" ]' "K10: --check fails for state_file with a zero, negative, string, fractional, null or missing state_max_age_minutes, and for an empty, numeric or null state_file${bad:+ (accepted:$bad)}"
jq '.gateway.state_max_age_minutes = true' $SET > "$T/badk.json"
ok '! WATCHDOG_SETTINGS="$T/badk.json" python3 -I $WS --check >/dev/null 2>&1' "K10: --check fails for state_max_age_minutes = true (a JSON boolean is not a number of minutes)"
jq '.gateway.state_max_age_minutes = 3' $SET > "$T/okk.json"; jq 'del(.gateway.state_file, .gateway.state_max_age_minutes)' $SET > "$T/okk2.json"
ok 'WATCHDOG_SETTINGS="$T/okk.json" python3 -I $WS --check >/dev/null 2>&1 && WATCHDOG_SETTINGS="$T/okk2.json" python3 -I $WS --check >/dev/null 2>&1' "K10: --check passes for a valid age and for settings with no state_file at all (the check is optional)"
reset; jq '.gateway.state_max_age_minutes = 0' $SET | jq --arg l "$T/gateway.log" --arg s "$T/gateway_state.json" '.gateway.activity_logs = [$l] | .gateway.state_file = $s | .gateway.process_match = "watchdog-selftest"' > "$T/settings.json"
logw gateway.log "$UP"; st 30; $W >/dev/null 2>&1
ok '[ "$(gcause)" = settings ] && [ "$(n "\[STL-GW-103\]\*\*$")" = 1 ] && grep -q "the settings for this check are missing or invalid" "$T/sup/sends"' "K10: invalid state_max_age_minutes at run time: STL-GW-103 (settings), not a silent skip"
# K4 wiring: watchdog.sh runs python3 -I "$BIN/model_watch.py" from its own directory and opens one STL-MDL-701 streak per
# card it lists (key model-<card>), resolved when the card is no longer listed. No override variable exists, so $T/wbin is a
# copy of bin/ made of symlinks, with a stub model_watch.py (prints the file MW_OUT names) in place of the real one.
WB="$T/wbin"; mkdir -p "$WB"
for f in /workspace/bin/*; do [ "${f##*/}" = model_watch.py ] || ln -sf "$f" "$WB/"; done
printf '%s\n' 'import os, sys' 'sys.stdout.write(open(os.environ["MW_OUT"]).read())' 'sys.exit(int(os.environ.get("MW_RC", "0")))' > "$WB/model_watch.py"
W2="$WB/watchdog.sh"; export ALERT_CATALOG=/workspace/docs/hermes-local/alert-catalog.json
mwrun() { MW_OUT="$T/mw.json" $W2 >/dev/null 2>&1; }
mwcard() { printf '{"card":"%s","profile":"worker","errors":7,"minutes":30,"cause":"%s","detail":"m1 not loaded at http://127.0.0.1:9; loaded: m2"}' "$1" "${2:-other_loaded}"; }
reset; echo "[$(mwcard t_14f8f08b)]" > "$T/mw.json"; mwrun; mwrun
ok '[ "$(n "\[STL-MDL-701\]\*\*$")" = 1 ] && grep -q "Card t_14f8f08b.s worker has had 7 failed model calls in the last 30 minutes and has done no work in that time: another model is loaded" "$T/sup/sends" && ! grep -qE "$PLAIN|127\.0\.0\.1|loaded: m2" "$T/sup/sends" && grep "^STL-MDL-701 " "$T/sup/logs/alerts.log" | grep -q "loaded: m2" && [ -e "$T/sup/state/watchdog-open/model-t_14f8f08b" ]' "K4: a card listed by the model watch: one STL-MDL-701 send (card, count, minutes, cause phrase), opened as model-<card>, not repeated on the next run, the raw detail in alerts.log only"
echo "[$(mwcard t_14f8f08b loaded)]" > "$T/mw.json"; mwrun
ok '[ "$(n "\[STL-MDL-701\]\*\*$")" = 1 ] && [ "$(n "\[STL-MDL-701 resolved\]")" = 0 ]' "K4: the cause changing while the card stays listed is the same streak: no second alert"
echo "[]" > "$T/mw.json"; mwrun
ok '[ "$(n "\[STL-MDL-701 resolved\]\*\*$")" = 1 ] && grep -q "Card t_14f8f08b.s worker gets model answers again, or the card stopped running" "$T/sup/sends" && [ ! -e "$T/sup/state/watchdog-open/model-t_14f8f08b" ]' "K4: an empty list: one resolved STL-MDL-701 for the card, the open file removed"
mwrun; mwrun
ok '[ "$(n "\[STL-MDL-701 resolved\]")" = 1 ] && [ "$(n "\[STL-MDL-701\]\*\*$")" = 1 ]' "K4: further empty lists send nothing"
reset; echo "[$(mwcard t_14f8f08b), $(mwcard t_aabbccdd unreachable)]" > "$T/mw.json"; mwrun
ok '[ "$(n "\[STL-MDL-701\]\*\*$")" = 2 ] && grep -q "Card t_aabbccdd.s worker has had" "$T/sup/sends" && grep -q "the model server its profile uses does not answer" "$T/sup/sends"' "K4: two listed cards: one streak and one send each"
echo "[$(mwcard t_aabbccdd unreachable)]" > "$T/mw.json"; mwrun
ok '[ "$(n "\[STL-MDL-701 resolved\]")" = 1 ] && [ -e "$T/sup/state/watchdog-open/model-t_aabbccdd" ] && [ ! -e "$T/sup/state/watchdog-open/model-t_14f8f08b" ] && rmsg=$(awk "/resolved\\]/{p=1} p" "$T/sup/sends") && grep -q "t_14f8f08b" <<<"$rmsg" && ! grep -q "t_aabbccdd" <<<"$rmsg"' "K4: one card no longer listed: only its streak is resolved, the other stays open"
echo "[]" > "$T/mw.json"; mwrun
ok '[ "$(n "\[STL-MDL-701 resolved\]")" = 2 ] && ! ls "$T"/sup/state/watchdog-open/model-* >/dev/null 2>&1' "K4: the last card no longer listed: resolved, nothing left open"
reset; printf 'not json at all\n' > "$T/mw.json"; mwrun
ok '[ ! -s "$T/sup/sends" ] && jq -e ".ok == true" "$T/sup/status.json" >/dev/null' "K4: model_watch output that is not a list: no alert, the watchdog run still completes"
reset; echo "[]" > "$T/mw.json"; mwrun
ok '[ ! -s "$T/sup/sends" ]' "K4: an empty list with nothing open: no alert and no resolved line"
# B2V-03/04: a check that did not run neither pages nor resolves (an open streak stays open until a real check clears it).
reset; echo "[$(mwcard t_14f8f08b)]" > "$T/mw.json"; mwrun; printf 'not json at all\n' > "$T/mw.json"; mwrun
ok '[ "$(n "\[STL-MDL-701 resolved\]")" = 0 ] && [ -e "$T/sup/state/watchdog-open/model-t_14f8f08b" ]' "K4: output that is not a list while a streak is open: not resolved, the open file kept"
echo "[]" > "$T/mw.json"; MW_RC=1 mwrun
ok '[ "$(n "\[STL-MDL-701 resolved\]")" = 0 ] && [ -e "$T/sup/state/watchdog-open/model-t_14f8f08b" ]' "K4: model_watch exits 1 (could not check) while a streak is open: not resolved, even with a list on stdout"
echo '[{"card":"t_14f8f08b","profile":"","errors":0,"minutes":30,"cause":"unknown","unchecked":true,"detail":"x"},{"card":"t_00c0ffee","profile":"","errors":0,"minutes":30,"cause":"unknown","unchecked":true,"detail":"x"}]' > "$T/mw.json"; mwrun
ok '[ "$(n "\[STL-MDL-701 resolved\]")" = 0 ] && [ "$(n "\[STL-MDL-701\]\*\*$")" = 1 ] && ! grep -q "t_00c0ffee" "$T/sup/sends" && [ ! -e "$T/sup/state/watchdog-open/model-t_00c0ffee" ] && [ -e "$T/sup/state/watchdog-open/model-t_14f8f08b" ]' "K4: unchecked cards: no page for a new one (no \"0 failed model calls\" text), an open one not resolved"
# B2V-12: a model watch that stays broken pages STL-MDL-702 on the 2nd failed run in a row, once, resolved when it runs again
reset; MW_RC=1 mwrun
ok '[ "$(n "\[STL-MDL-702\]\*\*$")" = 0 ] && grep -q "model watch could not check" "$WLOG"' "B2V-12: one failed model-watch run: logged, no page"
MW_RC=1 mwrun; MW_RC=1 mwrun
ok '[ "$(n "\[STL-MDL-702\]\*\*$")" = 1 ] && grep -q "could not run 2 times in a row" "$T/sup/sends" && [ -e "$T/sup/state/watchdog-open/model-watch" ]' "B2V-12: the 2nd failed run in a row pages STL-MDL-702 once (not again on the 3rd)"
echo "[]" > "$T/mw.json"; mwrun
ok '[ "$(n "\[STL-MDL-702 resolved\]")" = 1 ] && [ ! -e "$T/sup/state/watchdog-open/model-watch" ] && [ ! -e "$T/sup/state/model-watch.fails" ]' "B2V-12: the next run that checks resolves STL-MDL-702 and resets the count"
unset ALERT_CATALOG
# Hard-code review: no value from the settings (log, process, markers, pause file) and no profile or display name in the scripts.
vals=$(jq -r '.gateway | (.activity_logs[], .process_match, .connected_marker, .disconnected_marker, .pause_file)' $SET)
ok '! grep -qF -f <(printf "%s\n" "$vals") /workspace/bin/watchdog.sh /workspace/bin/watchdog_settings.py' "D47: watchdog.sh and watchdog_settings.py hold no log path, marker, process name or pause file (they come from the settings)"
# RU-07 (D69): the cron job gives a step more time than the suite needs (11-13 min), else every run is killed and reported hung.
ok '[ "$(sed -n "s/^[^#].*WATCHDOG_STEP_TIMEOUT=\([0-9][0-9]*\) .*bin\/watchdog.sh.*/\1/p" ${CRONTAB_TXT:-/workspace/bin/crontab.txt})" -ge 900 ]' "RU-07: the watchdog cron job sets WATCHDOG_STEP_TIMEOUT to at least 900 s"
# S4 (owner decision 2026-11-12): the test step runs the npm script the settings name (the quick tier); its name in the state stays "test".
printf '{"scripts": {"test": "x", "test:quick": "x", "lint": "x"}}\n' > "$T/root/package.json"
reset; gw '.test_step.npm_script = "test:quick"'; FAKE_FAIL_STEP=test $W >/dev/null 2>&1
ok '[ ! -s "$T/sup/sends" ] && jq -e "[.steps[] | select(.step == \"test\")][0].exit_code == 0" "$T/sup/status.json" >/dev/null' "S4: with test_step.npm_script = test:quick, the full test script is not run (a failing test script raises nothing)"
reset; gw '.test_step.npm_script = "test:quick"'; FAKE_FAIL_STEP=test:quick $W >/dev/null 2>&1
ok '[ "$(n "automatic test run failed")" = 1 ] && jq -e "[.steps[] | select(.step == \"test\")][0].exit_code == 1" "$T/sup/status.json" >/dev/null' "S4: a failing quick script is a failed step named test, one alert"
reset; gw '.test_step.npm_script = "test:nope"'; $W >/dev/null 2>&1
ok '[ "$(n "automatic test run failed")" = 1 ] && grep -q "nothing was tested" "$T/sup/sends" && jq -e "[.steps[] | select(.step == \"test\")][0] | .exit_code == 1 and (has(\"skipped\") | not)" "$T/sup/status.json" >/dev/null' "S4: a test script that package.json lacks is a failed test step with a plain line, not a skip"
reset; gw 'del(.test_step)'; $W >/dev/null 2>&1
ok '[ "$(n "automatic test run failed")" = 1 ] && grep -q "nothing was tested" "$T/sup/sends"' "S4: a settings file with no test_step is a failed test step, not a silent pass"
jq "del(.test_step)" $SET > "$T/nots.json"
ok '! WATCHDOG_SETTINGS="$T/nots.json" python3 -I $WS --check >/dev/null 2>&1' "S4: --check refuses settings without test_step.npm_script"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
