#!/usr/bin/env bash
# Hermetic self-test for bin/event_log.py (F1 W3): the one writer of the event log. Runs in a scratch root (STELLA_ROOT: a copy of
# .stella/ and the role table); never the live log. Proves: a valid line is appended, masked (index redact_keys, registry
# `secret` settings) before it is written or printed; an invalid line is refused and nothing is written; the log is only ever
# appended to; tail --json; an unwritable log refuses with STL-CFG-318; concurrent appends do not interleave.
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d -t event-log-selftest.XXXXXX); trap 'rm -rf "$T"' EXIT
R=$T/root; mkdir -p "$R/docs/hermes-local" "$R/config" "$R/.supervisor/logs"
cp -r "$H/.stella" "$R/"; cp "$H/docs/hermes-local/roles.json" "$R/docs/hermes-local/"
# a registry setting marked secret, in a data file that has no redact_keys of its own
jq '.entries += [(.entries[2] | .key = "PLANTED_SETTING" | .sensitivity = "secret" | .type = "string" | .validation = {} | .default = null | .store.key = "PLANTED_SETTING")]' \
  "$R/.stella/settings.json" > "$T/s" && mv "$T/s" "$R/.stella/settings.json"
export STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup
EL="python3 -I $H/bin/event_log.py"
LOG=$R/.supervisor/logs/events.jsonl
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }

ok 'o=$(python3 -I $H/bin/stella_data.py check) && [ "$(echo "$o" | head -1)" = "data OK" ]' "the scratch root validates"
ok '$EL append --type note --what first >/dev/null && [ "$(wc -l <"$LOG")" = 1 ] && jq -e ".schema_version == 1 and .type == \"note\" and (.time | test(\"Z$\"))" "$LOG" >/dev/null' "a valid line is appended as one JSON line"
cp "$LOG" "$T/before"
out=$($EL append --type change --what x --old '{"API_TOKEN":"plant-aaa","name":"n1"}' --new '{"PLANTED_SETTING":"plant-bbb","/a/b/PASSWORD":"plant-ccc","name":"n2"}' 2>&1); rc=$?
ok '[ $rc = 0 ] && [ "$(wc -l <"$LOG")" = 2 ]' "a second line is appended"
ok '! grep -rq "plant-" "$R" && ! printf %s "$out" | grep -q "plant-"' "no planted secret value in the root or the output (redact_keys, secret setting, pointer path)"
ok 'tail -n 2 "$LOG" | tail -n 1 | jq -e ".new.name == \"n2\" and .old.API_TOKEN == \"***\" and .new.PLANTED_SETTING == \"***\"" >/dev/null' "masked values are ***, others kept"
ok 'head -c "$(wc -c <"$T/before")" "$LOG" | cmp -s - "$T/before"' "append-only: the earlier bytes are unchanged"
cp "$LOG" "$T/before"   # (again: the refusals below must not touch the log)
for bad in "--type '' --what x" "--type t --what x --code bad" "--what x" "--type t --what x --old not-json"; do
  eval "$EL append $bad" >"$T/o" 2>&1; rc=$?
  ok '[ $rc != 0 ] && cmp -s "$LOG" "$T/before"' "refused, nothing written: append $bad"
done
ok '$EL tail --json -n 1 | jq -e "length == 1 and .[0].what == \"x\"" >/dev/null' "tail --json -n 1 gives the last line"
ok '[ "$($EL tail --json | jq length)" = 2 ]' "tail --json gives all lines (fewer than the default)"
ok '$EL tail -n 1 | grep -q change' "tail prints a plain line"
for i in $(seq 20); do $EL append --type par --what "p$i" >/dev/null 2>&1 & done; wait
ok '[ "$(wc -l <"$LOG")" = 22 ] && [ "$(jq -c . "$LOG" | wc -l)" = 22 ]' "20 concurrent appends: 20 whole lines"
rm "$LOG"; mkdir "$LOG"
$EL append --type t --what x >"$T/o" 2>&1; rc=$?
ok '[ $rc != 0 ] && grep -q "STL-CFG-318" "$T/o"' "an unwritable log: non-zero, STL-CFG-318 and its plain message"
$EL append --type t --what x >"$T/o" 2>&1; ok 'grep -qi "event log" "$T/o"' "the message is the catalog's plain text"
$EL bogus >/dev/null 2>&1; ok '[ $? = 2 ]' "usage error exits 2"
[ $fails = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
