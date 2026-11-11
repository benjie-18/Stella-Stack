#!/usr/bin/env bash
# Hermetic self-test for bin/stella-apply.py (F1 W3, the generic apply contract). Everything runs in a scratch root (STELLA_ROOT:
# a copy of .stella/, the role table, a FAKE env-format owner file and a fake limits file, a tiny git repo); never the real owner
# settings. A5a a dry run changes no file; A5b apply then rollback leaves every file byte-identical (content and mode), json and
# env; A5c a second apply is a no-op; A5d check: drift, no drift after an apply, git blob when nothing was applied; A5e one event
# line per apply and per rollback, no planted secret anywhere (the data files and their byte-copy backups excepted). Also: invalid
# candidate, unknown id, owner-only rows refused for a simulated worker (stub board, marker variable, no markers), failure paths
# (unwritable event log, an interrupted apply), two applies at once, a folder row, paths that leave the root.
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d -t stella-apply-selftest.XXXXXX); trap 'rm -rf "$T"' EXIT
R=$T/root; C=$T/cand; mkdir -p "$R/docs/hermes-local" "$R/config" "$R/.supervisor/logs" "$C" "$T/sup/logs"
cp -r "$H/.stella" "$R/"
jq '. + {worker_markers: ["STUB_WORKER_MARK"]}' "$H/docs/hermes-local/roles.json" >"$R/docs/hermes-local/roles.json"
jq '.entries += [(.entries[2] | .key = "PLANTED_SETTING" | .sensitivity = "secret" | .type = "string" | .validation = {} | .default = null | .store.key = "PLANTED_SETTING")]' \
  "$R/.stella/settings.json" >"$T/s" && mv "$T/s" "$R/.stella/settings.json"
printf "WORKER_GIT_NAME='Fake One'\nWORKER_GIT_EMAIL='fake@example.invalid'\nAPI_TOKEN='sekrit-token-111'\n" >"$R/config/owner.env"
printf "CALL_TIMEOUT=600\nPLANTED_SETTING='sekrit-setting-333'\n" >"$R/.supervisor/limits.env"
chmod 600 "$R/config/owner.env"; chmod 640 "$R/.supervisor/limits.env"
cp "$R/.stella/connections.json" "$T/conn.orig"
git -C "$R" init -q 2>/dev/null; printf '.supervisor/\n' >"$R/.gitignore"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm base
export STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup
unset STUB_WORKER_MARK
ALERTS=$T/sup/logs/alerts.log; LOG=$R/.supervisor/logs/events.jsonl
AP="python3 -I $H/bin/stella-apply.py"
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
tree() { (cd "$R" && find . \( -path ./.git -o -path ./.supervisor/state -o -path ./.supervisor/logs \) -prune -o -printf '%y %m %p\n' | sort; \
  find . \( -path ./.git -o -path ./.supervisor/state -o -path ./.supervisor/logs \) -prune -o -type f -print0 | sort -z | xargs -0 sha256sum); }
nev() { [ -f "$LOG" ] && wc -l <"$LOG" || echo 0; }
nbk() { find "$R/.supervisor/state/backups" -name meta.json 2>/dev/null | wc -l; }
fp() { echo "$(cat /proc/sys/kernel/random/boot_id):$(sed 's/.*) //' /proc/1/stat | awk '{print $20}')|$(sed 's/.*) //' /proc/$1/stat | awk '{print $20}')"; }
# stub boards: ok = no running card (not a worker); down = unreadable; worker = a running card bound to this script's own process
for s in ok down worker; do mkdir -p "$T/pb-$s"; done
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb-ok/hermes"
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/pb-down/hermes"
cat >"$T/pb-worker/hermes" <<S
#!/usr/bin/env bash
case " \$* " in
  *" list "*) echo '[{"id":"c1"}]';;
  *" show "*) echo '{"task":{"id":"c1","assignee":"w"},"runs":[{"id":7,"ended_at":null}],"events":[{"kind":"claimed","run_id":7,"payload":{"lock":"h:1"}},{"kind":"worker_bound","run_id":7,"payload":{"pid":$$,"claim_lock":"h:1","started_at":"$(fp $$)"}}]}';;
esac
S
chmod +x "$T"/pb-*/hermes
OWNER=$PATH; PB=$T/pb-ok   # as the owner: the stub board says no worker run
ap() { PATH=$PB:$OWNER $AP "$@"; }
jq '.entries[0].label = "Changed label"' "$T/conn.orig" >"$C/conn.json"
jq '.entries[0].label = "Second label"' "$T/conn.orig" >"$C/conn2.json"
printf "WORKER_GIT_NAME='Fake Two'\nWORKER_GIT_EMAIL='fake@example.invalid'\nAPI_TOKEN='sekrit-token-222'\n" >"$C/owner.env"
printf "CALL_TIMEOUT=900\nPLANTED_SETTING='sekrit-setting-444'\n" >"$C/limits.env"
jq '.entries[0].label = 5' "$T/conn.orig" >"$C/bad.json"

ok 'o=$(python3 -I $H/bin/stella_data.py check) && [ "$(echo "$o" | head -1)" = "data OK" ]' "the scratch root validates"

# A5d first: nothing applied yet, so the committed blob is the baseline
ok 'ap check connections >"$T/o" 2>&1' "A5d no drift on an untouched tracked file (baseline: the committed blob)"
ok 'ap check --json | jq -e ".files[] | select(.id == \"connections\") | .baseline == \"git\"" >/dev/null' "A5d check --json names the baseline"
ok 'ap check limits --json | jq -e ".ok and .files[0].state == \"no_baseline\"" >/dev/null' "A5d an untracked file with no applied record: no baseline, not drift"
cp "$C/conn.json" "$R/.stella/connections.json"
ap check connections >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-314 "$T/o"' "A5d a hand edit is drift: exit 1, STL-CFG-314"
git -C "$R" checkout -q -- .stella/connections.json

# A5a dry runs
B=$(tree)
ap apply connections --from "$C/conn.json" --dry-run >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "Changed label" "$T/o" && [ "$(tree)" = "$B" ] && [ ! -e "$LOG" ]' "A5a dry run (json): diff shown, exit 0, no file changed, no event"
ap apply owner-settings --from "$C/owner.env" --dry-run >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "API_TOKEN=.\*\*\*" "$T/o" && ! grep -q sekrit- "$T/o" && grep -q "Fake Two" "$T/o" && [ "$(tree)" = "$B" ]' "A5a dry run (env): masked diff, nothing changed"
ap apply limits --from "$C/limits.env" --dry-run >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "PLANTED_SETTING=.\*\*\*" "$T/o" && ! grep -q sekrit- "$T/o" && [ "$(tree)" = "$B" ]' "A5a dry run (secret setting): masked, nothing changed"
ap apply connections --from "$C/bad.json" --dry-run >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && [ "$(tree)" = "$B" ]' "A5a a dry run of an invalid candidate is refused"

# A5b/c/e for json, env, env with a secret setting
for spec in connections:conn.json:.stella/connections.json owner-settings:owner.env:config/owner.env limits:limits.env:.supervisor/limits.env; do
  id=${spec%%:*}; rest=${spec#*:}; cand=$C/${rest%%:*}; file=$R/${rest#*:}
  B=$(tree); e0=$(nev)
  ap apply "$id" --from "$cand" >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 0 ] && cmp -s "$cand" "$file" && [ "$(nev)" = $((e0+1)) ] && [ "$(nbk)" -ge 1 ]' "$id: apply replaces the file, one event line, one backup"
  b1=$(nbk); mode=$(stat -c %a "$file")
  ap apply "$id" --from "$cand" >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 0 ] && grep -q "no change" "$T/o" && [ "$(nev)" = $((e0+1)) ] && [ "$(nbk)" = "$b1" ]' "A5c $id: the same candidate again: exit 0, no new event, no new backup"
  ok 'ap check "$id" >/dev/null 2>&1 && ap check "$id" --json | jq -e ".files[0].baseline == \"applied\"" >/dev/null' "A5d $id: no drift right after an apply (baseline: applied)"
  printf '# hand edit\n' >>"$file"
  ap check "$id" >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && grep -q STL-CFG-314 "$T/o"' "A5d $id: a hand edit after the apply is drift"
  head -c -"$(printf '# hand edit\n' | wc -c)" "$file" >"$C/x" && cat "$C/x" >"$file"
  ap rollback "$id" >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 0 ] && [ "$(tree)" = "$B" ] && [ "$(stat -c %a "$file")" = "$mode" ] && [ "$(nev)" = $((e0+2)) ]' "A5b $id: rollback leaves every file byte-identical (content, mode); A5e two event lines in all"
  ok '[ "$(ap history "$id" --json | jq ".events | map(.type) | join(\",\")" -r)" = "apply,rollback" ]' "A5e $id: history --json shows apply, rollback"
done
ap rollback connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-316 "$T/o"' "rollback with no backup: STL-CFG-316"
ok '! grep -rq "sekrit-" "$T" --exclude-dir=cand --exclude-dir=.git --exclude-dir=backups --exclude=owner.env --exclude=limits.env' "A5e no planted secret value in a log, an event, a state file or an output (data files and their byte-copy backups excepted)"
ok 'jq -es "map(select(.type == \"apply\")) | length > 0 and all(.old != null and .new != null)" "$LOG" >/dev/null' "event lines carry old and new"

# refusals
B=$(tree); a0=$(wc -l <"$ALERTS" 2>/dev/null || echo 0)
ap apply nosuch --from "$C/conn.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-311 "$T/o" && [ "$(wc -l <"$ALERTS")" = $((a0+1)) ] && [ "$(tree)" = "$B" ]' "an unknown id: exit 1, STL-CFG-311, exactly one alert line, nothing changed"
for c in "bad.json" "nosuch-file"; do
  e0=$(nev); ap apply connections --from "$C/$c" >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && grep -q STL-CFG-313 "$T/o" && [ "$(tree)" = "$B" ] && [ "$(nev)" = "$e0" ]' "refused with STL-CFG-313, nothing changed: $c"
done
printf 'not a settings line\n' >"$C/badenv"; printf '{"schema_version":1,"schema_version":1}' >"$C/dup.json"; printf '{"a":' >"$C/trunc.json"
for spec in owner-settings:badenv limits:badenv connections:dup.json connections:trunc.json; do
  ap apply "${spec%%:*}" --from "$C/${spec#*:}" >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && grep -q STL-CFG-313 "$T/o" && [ "$(tree)" = "$B" ]' "invalid candidate refused: ${spec}"
done
jq 'del(.entries[0].id)' "$T/conn.orig" >"$C/noid.json"
ap apply connections --from "$C/noid.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && [ "$(tree)" = "$B" ]' "a candidate that breaks the schema (missing id) is refused"
for a in extensions extensions/../x.json extensions/.hid.json connections/x.json; do
  ap apply "$a" --from "$C/conn.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-31 "$T/o" && [ "$(tree)" = "$B" ]' "bad target refused: $a"
done

# owner-only rows and a simulated worker
for who in marker board-worker board-down; do
  case $who in marker) pb=$T/pb-ok; export STUB_WORKER_MARK=1;; board-worker) pb=$T/pb-worker;; board-down) pb=$T/pb-down;; esac
  for cmd in "apply owner-settings --from $C/owner.env" "apply owner-settings --from $C/owner.env --dry-run" "rollback owner-settings" "history owner-settings --json"; do
    PB=$pb; ap $cmd >"$T/o" 2>&1; rc=$?
    ok '[ $rc = 1 ] && grep -q STL-CFG-312 "$T/o" && [ "$(tree)" = "$B" ]' "owner-only refused for a simulated worker ($who): $cmd"
  done
  unset STUB_WORKER_MARK
done
PB=$T/pb-worker; ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; ok '[ $? = 0 ]' "a row that is not owner-only still applies for a worker (the gate is the index flag, not a name)"
ap rollback connections >/dev/null 2>&1; PB=$T/pb-ok
jq 'del(.worker_markers)' "$R/docs/hermes-local/roles.json" >"$T/r" && cp "$R/docs/hermes-local/roles.json" "$T/roles.keep" && cp "$T/r" "$R/docs/hermes-local/roles.json"
ap apply owner-settings --from "$C/owner.env" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-312 "$T/o"' "no worker_markers in the role table: owner-only rows fail closed"
cp "$T/roles.keep" "$R/docs/hermes-local/roles.json"
ap apply owner-settings --from "$C/owner.env" >"$T/o" 2>&1; ok '[ $? = 0 ]' "the owner (no marker, stub board has no run) can apply an owner-only row"
ap rollback owner-settings >/dev/null 2>&1
B=$(tree)

# failure paths: the event log cannot be written
mv "$LOG" "$T/log.keep"; ln -s /dev/full "$LOG"
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-318 "$T/o" && [ "$(tree)" = "$B" ] && [ "$(nbk)" = 0 ] && [ "$(ap check connections --json | jq -r .files[0].baseline)" = git ]' "event log fails on write (/dev/full): file restored, backup and applied state gone, STL-CFG-318"
rm "$LOG"; mkdir "$LOG"
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-318 "$T/o" && [ "$(tree)" = "$B" ] && [ "$(nbk)" = 0 ]' "event log is not a file: refused before anything is touched"
rmdir "$LOG"; mv "$T/log.keep" "$LOG"
ap apply connections --from "$C/conn.json" >/dev/null 2>&1
cp "$LOG" "$T/log.keep"; rm "$LOG"; ln -s /dev/full "$LOG"; B2=$(tree)
ap rollback connections >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-318 "$T/o" && [ "$(tree)" = "$B2" ] && [ "$(nbk)" = 1 ]' "a rollback whose event line fails changes nothing and keeps its backup"
rm "$LOG"; mv "$T/log.keep" "$LOG"

# an interrupted apply: the backup is still pending
n=$(nev); bm=$(find "$R/.supervisor/state/backups" -name meta.json); jq '.status = "pending"' "$bm" >"$T/m" && cp "$T/m" "$bm"
ap check connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-314 "$T/o"' "a pending backup is reported by check (STL-CFG-314)"
ap apply connections --from "$C/conn2.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && grep -q "rollback" "$T/o"' "apply refuses while a backup is pending and says what to do"
ap rollback connections >"$T/o" 2>&1; ok '[ $? = 0 ] && [ "$(tree)" = "$B" ] && [ "$(nev)" = $((n+1)) ]' "rollback recovers an interrupted apply: file restored, one event line"

# two applies at once
B=$(tree); e0=$(nev)
ap apply connections --from "$C/conn.json" >"$T/o1" 2>&1 & ap apply connections --from "$C/conn2.json" >"$T/o2" 2>&1 & wait
ok '[ "$(nev)" = $((e0+2)) ] && [ "$(jq -c . "$LOG" | wc -l)" = "$(nev)" ] && [ "$(nbk)" = 2 ] && ap check connections >/dev/null 2>&1' "two applies at once: both whole, two events, two backups, no drift"
ap rollback connections >/dev/null 2>&1; ap rollback connections >/dev/null 2>&1
ok '[ "$(tree)" = "$B" ]' "two rollbacks return the file to its first state"

# a folder row
echo '{"schema_version":1,"id":"fake-ext","kind":"mcp_server","summary":"fake extension for gizmos","hosts":["gizmo.example.invalid:443"],"secrets":["GIZMO_KEY"],"tools":["gizmo_get"],"allowed_roles":["reviewer"],"risk_class":"read","enabled":false,"status":"proposed","source":"fake"}' >"$C/fake-ext.json"
B=$(tree); e0=$(nev)
ap apply extensions/fake-ext.json --from "$C/fake-ext.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && cmp -s "$C/fake-ext.json" "$R/.stella/extensions/fake-ext.json" && [ "$(nev)" = $((e0+1)) ] && ap check extensions >/dev/null 2>&1 && o=$(python3 -I $H/bin/stella_data.py check) && [ "$(echo "$o" | head -1)" = "data OK" ]' "a folder row: extensions/<file> applies, checks, still validates as a whole"
ap rollback extensions/fake-ext.json >"$T/o" 2>&1
ok '[ $? = 0 ] && [ "$(tree)" = "$B" ]' "a folder row: rollback of a new file removes it, tree identical"

# paths that leave the root
mkdir "$T/outside"; echo '{}' >"$T/outside/t.json"; mv "$R/.stella/approved-hosts.json" "$T/ah.keep"; ln -s "$T/outside/t.json" "$R/.stella/approved-hosts.json"
ap apply approved-hosts --from "$C/conn.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && [ "$(cat "$T/outside/t.json")" = "{}" ]' "a data file that is a symlink out of the root is refused, the target untouched"
rm "$R/.stella/approved-hosts.json"; mv "$T/ah.keep" "$R/.stella/approved-hosts.json"
ok 'STELLA_ROOT=$(dirname "$H") python3 -I -c "import sys; sys.path.insert(0, \"$H/bin\"); import event_log as e; e.path(\"$(basename "$H")/bin/x\")" 2>&1 | grep -q "another stack tree"' "a root that is a parent of this tool refuses paths inside the tool's own tree"
$AP bogus >/dev/null 2>&1; ok '[ $? = 2 ]' "usage error exits 2"
[ $fails = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
