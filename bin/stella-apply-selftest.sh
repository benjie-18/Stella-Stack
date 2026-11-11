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
jq '(.files[] | select(.id == "connections" or .id == "extensions" or .id == "limits") | .owner_only) = false' "$R/.stella/data-files.json" >"$T/nx" && cp "$T/nx" "$R/.stella/data-files.json"   # the cases need these rows not owner-only, whatever the shipped flags say
jq '. + {worker_markers: ["STUB_WORKER_MARK"]}' "$H/docs/hermes-local/roles.json" >"$R/docs/hermes-local/roles.json"
jq '.entries += [(.entries[2] | .key = "PLANTED_SETTING" | .sensitivity = "secret" | .type = "string" | .validation = {} | .default = null | .store.key = "PLANTED_SETTING")]' \
  "$R/.stella/settings.json" >"$T/s" && mv "$T/s" "$R/.stella/settings.json"
printf "WORKER_GIT_NAME='Fake One'\nWORKER_GIT_EMAIL='fake@example.invalid'\nAPI_TOKEN='sekrit-token-111'\n" >"$R/config/owner.env"
printf "CALL_TIMEOUT=600\nPLANTED_SETTING='sekrit-setting-333'\n" >"$R/.supervisor/limits.env"
chmod 600 "$R/config/owner.env"; chmod 640 "$R/.supervisor/limits.env"
cp "$R/.stella/connections.json" "$T/conn.orig"
git -C "$R" init -q 2>/dev/null; printf '.supervisor/\n' >"$R/.gitignore"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm base
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"   # a fake owner file: no failure message makes the alert code read the real one
export STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env
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
# ---- round 2 (fix round 1). Each group starts from a fresh scratch root (mkr). ----
ROLES=$R/docs/hermes-local/roles.json; SET0=$R/.stella/settings.json
mkr() {  # <name>: a fresh scratch root with fake files and a git baseline; R, LOG and STELLA_ROOT point at it
  R=$T/$1; LOG=$R/.supervisor/logs/events.jsonl; mkdir -p "$R/docs/hermes-local" "$R/config" "$R/.supervisor/logs"
  cp -r "$H/.stella" "$R/"; jq '(.files[] | select(.id == "connections" or .id == "extensions" or .id == "limits") | .owner_only) = false' "$R/.stella/data-files.json" >"$T/nx" && cp "$T/nx" "$R/.stella/data-files.json"   # the cases need these rows not owner-only, whatever the shipped flags say
  cp "$ROLES" "$R/docs/hermes-local/roles.json"; cp "$SET0" "$R/.stella/settings.json"
  printf "WORKER_GIT_NAME='Fake One'\nWORKER_GIT_EMAIL='fake@example.invalid'\nAPI_TOKEN='sekrit-token-111'\n" >"$R/config/owner.env"
  printf "CALL_TIMEOUT=600\nPLANTED_SETTING='sekrit-setting-333'\n" >"$R/.supervisor/limits.env"; chmod 600 "$R/config/owner.env"; chmod 640 "$R/.supervisor/limits.env"
  printf '.supervisor/\n' >"$R/.gitignore"; git -C "$R" init -q 2>/dev/null; git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm base
  export STELLA_ROOT=$R
}
kill_at() {  # <applied|event> <args...>: stella-apply's main in-process, SIGKILL at set_applied or at the event line (a crash between steps)
  python3 -I -c '
import importlib.util, os, signal, sys
sys.dont_write_bytecode = True; spec = importlib.util.spec_from_file_location("sa", sys.argv[1]); sa = importlib.util.module_from_spec(spec); spec.loader.exec_module(sa)
die = lambda *a, **k: os.kill(os.getpid(), signal.SIGKILL)
if sys.argv[2] == "applied": sa.set_applied = die
else: sa.el.append = die
sys.exit(sa.main(sys.argv[3:]))' "$H/bin/stella-apply.py" "$@"
}
BK() { echo "$R/.supervisor/state/backups"; }
echo '{"schema_version":1,"id":"fake-ext2","kind":"mcp_server","summary":"fake extension two","hosts":["gizmo.example.invalid:443"],"secrets":["GIZMO_KEY"],"tools":["gizmo_get"],"allowed_roles":["reviewer"],"risk_class":"read","enabled":false,"status":"proposed","source":"fake"}' >"$C/fake-ext2.json"

# G1 the gate says what it is
mkr g1; jq '.worker_markers = []' "$ROLES" >"$R/docs/hermes-local/roles.json"
ap apply owner-settings --from "$C/owner.env" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-312 "$T/o"' "G1 an empty worker_markers list is refused like a missing one"
cp "$ROLES" "$R/docs/hermes-local/roles.json"
ap history connections/../owner-settings --json >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && ! grep -q backups "$T/o"' "G1 history sends its id through the same target() as apply"
ok '! grep -qE "^ *assert " "$H/bin/stella-apply.py"' "G1 no assert is used as a check"

# G2 one row, one real file
mkr g2; rm "$R/.supervisor/limits.env"; ln -s ../config/owner.env "$R/.supervisor/limits.env"; B=$(tree)
ap apply limits --from "$C/limits.env" --dry-run >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-313 "$T/o" && ! grep -q "API_TOKEN\|sekrit" "$T/o"' "G2 a row path that is a symbolic link to another file: a dry run is refused, nothing of the file is printed"
ap apply limits --from "$C/limits.env" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && [ "$(tree)" = "$B" ] && [ "$(nbk)" = 0 ] && [ ! -e "$LOG" ]' "G2 the apply is refused: the linked file, the backups and the log are untouched"
ap check limits >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && ! grep -q "API_TOKEN\|sekrit" "$T/o"' "G2 check reports the linked row and prints nothing from the file"
mkr g2b; mkdir "$R/elsewhere" "$R/.supervisor/state"; mkdir -p "$R/.supervisor/state/backups"; ln -s ../../../elsewhere "$R/.supervisor/state/backups/connections"
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && [ -z "$(ls -A "$R/elsewhere")" ] && cmp -s "$T/conn.orig" "$R/.stella/connections.json"' "G2 a backup folder that is a symbolic link is refused, nothing written through it"
mkr g2c; jq '(.files[] | select(.id == "capabilities") | .path) = ".stella/features.json"' "$R/.stella/data-files.json" >"$T/x" && cp "$T/x" "$R/.stella/data-files.json"
ap check connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && grep -qi "same file" "$T/o"' "G2 two index rows that name the same file are refused"
mkr g2d; jq '.event_log = ".stella/connections.json"' "$R/.stella/data-files.json" >"$T/x" && cp "$T/x" "$R/.stella/data-files.json"
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && cmp -s "$T/conn.orig" "$R/.stella/connections.json"' "G2 an index whose event_log is also a row's file is refused"

# G3 nothing readable is left behind
mkr g3; rm "$R/config/owner.env"; git -C "$R" rm -q --cached config/owner.env
ap apply owner-settings --from "$C/owner.env" >"$T/o" 2>&1
ok '[ "$(stat -c %a "$R/config/owner.env")" = 600 ]' "G3 a new file of an owner-only row is created 0600"
ap apply limits --from "$C/limits.env" >/dev/null 2>&1; ap apply connections --from "$C/conn.json" >/dev/null 2>&1
d=$(ls -d "$(BK)"/connections/*)
ok '[ "$(stat -c %a "$(BK)")" = 700 ] && [ "$(stat -c %a "$(BK)/connections")" = 700 ] && [ "$(stat -c %a "$d")" = 700 ] && [ "$(stat -c %a "$d/file")" = 600 ] && [ "$(stat -c %a "$d/meta.json")" = 600 ] && [ "$(stat -c %a "$R/.stella/connections.json")" = 644 ]' "G3 backup folders 0700, backup files 0600, an existing file keeps its mode"
ok '[ "$(stat -c %a "$R/.supervisor/limits.env")" = 640 ]' "G3 an existing file keeps its mode (640)"
printf 'planted-bytes' >"$R/.stella/.stella-apply.dead"; printf keep >"$R/.stella/.stella-apply-keep"
ap apply connections --from "$C/conn2.json" >/dev/null 2>&1
ok '[ ! -e "$R/.stella/.stella-apply.dead" ] && [ -e "$R/.stella/.stella-apply-keep" ]' "G3 the next run sweeps the tool's own stray temp file, only that name"
mkdir "$(BK)/connections/00000001-unfinished"; printf 'copy' >"$(BK)/connections/00000001-unfinished/file"
ap check connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-314 "$T/o"' "G3 check reports a backup folder without a readable meta file (314)"
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "rollback" "$T/o"' "G3 apply refuses while such a folder is there"
ap rollback connections >"$T/o" 2>&1; ok '[ ! -e "$(BK)/connections/00000001-unfinished" ]' "G3 rollback removes the folder without a meta file"

# G4 rollback restores only what the tool saved
for m in damaged missing badmeta; do
  mkr g4-$m; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; d=$(ls -d "$(BK)"/connections/*)
  case $m in damaged) echo x >>"$d/file";; missing) rm "$d/file";; badmeta) echo '[]' >"$d/meta.json";; esac
  B=$(tree); ap rollback connections >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && grep -q STL-CFG-316 "$T/o" && ! grep -q Traceback "$T/o" && [ "$(tree)" = "$B" ]' "G4 a $m backup: rollback refuses (316), the file is neither written nor deleted"
done
mkr g4h; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; printf 'HAND=1\n' >>"$R/.supervisor/limits.env"; B=$(tree)
ap rollback limits >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-314 "$T/o" && [ "$(tree)" = "$B" ]' "G4 rollback over a hand edit is refused (314), the file untouched"
mkr g4v; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; jq '(.entries[] | select(.key == "CALL_TIMEOUT") | .validation.maximum) = 500' "$R/.stella/settings.json" >"$T/x" && cp "$T/x" "$R/.stella/settings.json"
B=$(tree); ap rollback limits >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && grep -qi "apply" "$T/o" && [ "$(tree)" = "$B" ]' "G4 a restore that no longer validates is refused (313) and says to apply the wanted content"

# G5 env candidates against the registry
mkr g5; B=$(tree)
for spec in "limits:CALL_TIMEOUT=zq7v" "limits:CALL_TIMEOUT=0" "limits:CALL_TIMEOUT=600"$'\n'"PLANTED_SETTING=zq7v"$'\n'"QUEUE_MAX=-1" "owner-settings:API_TOKEN=zq7v" "owner-settings:WORKER_GIT_NAME=Fake"$'\n'"WORKER_GIT_EMAIL=no-at-sign"; do
  printf '%s\n' "${spec#*:}" >"$C/g5.env"; ap apply "${spec%%:*}" --from "$C/g5.env" >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && grep -q STL-CFG-315 "$T/o" && ! grep -q zq7v "$T/o" && [ "$(tree)" = "$B" ]' "G5 refused with the registry entry's own code (315), nothing changed: ${spec%%$'\n'*}"
done
: >"$C/empty.env"; ap apply owner-settings --from "$C/empty.env" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-315 "$T/o" && [ "$(tree)" = "$B" ]' "G5 an empty owner file is refused: a setting with no default must be present"
printf "CALL_TIMEOUT=700\nPLANTED_SETTING='x'\nOTHER_KEY=1\n" >"$C/g5ok.env"; ap apply limits --from "$C/g5ok.env" >"$T/o" 2>&1; ok '[ $? = 0 ]' "G5 a key the registry does not know stays allowed"

# G6 the event log tells the truth
mkr g6
kill_at event apply connections --from "$C/conn.json" >/dev/null 2>&1; krc=$?
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; rc=$?
ok '[ $krc = 137 ] && [ $rc = 0 ] && [ "$(nev)" = 1 ] && [ "$(jq -r .type "$LOG")" = apply ] && ap check connections >/dev/null 2>&1' "G6 a retry after an apply killed before its event line finishes the bookkeeping and writes the missing line"
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; ok 'grep -q "no change" "$T/o" && [ "$(nev)" = 1 ]' "G6 a second retry is a no-change"
kill_at applied rollback connections >/dev/null 2>&1; krc=$?
ap rollback connections >"$T/o" 2>&1; rc=$?
ok '[ $krc = 137 ] && [ $rc = 0 ] && [ "$(jq -r .type "$LOG" | tr "\n" " ")" = "apply rollback " ] && cmp -s "$T/conn.orig" "$R/.stella/connections.json" && ap check connections >/dev/null 2>&1 && [ "$(nbk)" = 0 ]' "G6 a rollback killed after the restore is finished by the next run, with its one event line"
mkr g6b; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; cp "$T/conn.orig" "$R/.stella/connections.json"; n=$(nev)
ap rollback connections >"$T/o" 2>&1; ok '[ $? = 0 ] && grep -q "nothing to restore" "$T/o" && [ "$(nev)" = $((n+1)) ] && [ "$(jq -r .type "$LOG" | tail -1)" = rollback ]' "G6 the nothing-to-restore branch writes an event line"
mkr g6c; ap apply owner-settings --from "$C/owner.env" >/dev/null 2>&1; ap apply limits --from "$C/limits.env" >/dev/null 2>&1
ok 'jq -es "(map(select(.what == \"owner-settings\")) | .[0] | .old.WORKER_GIT_NAME == \"Fake One\" and .new.WORKER_GIT_NAME == \"Fake Two\" and .new.API_TOKEN == \"***\") and (map(select(.what == \"limits\")) | .[0].new.PLANTED_SETTING == \"***\")" "$LOG" >/dev/null && ! jq -r "select(.what == \"owner-settings\" or .what == \"limits\") | .detail" "$LOG" | grep -q "sha256"' "G6 the rule from both sides: redact-key and secret values are ***, an identity_critical setting shows old and new; no file hash for a row with redact keys or a secret setting"
ap apply extensions/fake-ext.json --from "$C/fake-ext.json" >/dev/null 2>&1
ok 'jq -e "select(.what == \"extensions/fake-ext.json\") | .old == null and (.new | type) == \"object\"" "$LOG" >/dev/null' "G6 the event for a new file has old: null"
ap history extensions --json >"$T/o" 2>&1; ok '[ "$(jq ".unreadable_lines" "$T/o")" = 0 ]' "G6 history --json carries a count of unreadable lines"
printf 'garbage' >>"$LOG"; ap history extensions --json >"$T/o" 2>"$T/e"; ok '[ "$(jq ".unreadable_lines" "$T/o")" = 1 ] && grep -q "STL-CFG-318" "$T/e"' "G6 an unreadable line is counted and reported with a code, never dropped silently"
ap apply extensions/fake-ext2.json --from "$C/fake-ext2.json" >/dev/null 2>&1; ok '[ "$(ap history extensions --json 2>/dev/null | jq ".events | length")" = 2 ]' "G6 the next event after a fragment is readable"

# G7 no traceback, right codes, fresh roots
mkr g7; jq '(.files[] | select(.id == "connections") | .redact_keys) = ["("]' "$R/.stella/data-files.json" >"$T/x" && cp "$T/x" "$R/.stella/data-files.json"
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "^STL-CFG-31" "$T/o" && ! grep -q Traceback "$T/o"' "G7 an unexpected failure ends in exit 1 and one coded line, no traceback"
mkr g7b; printf 'garbage line\n' >"$R/.supervisor/limits.env"
ap apply limits --from "$C/limits.env" --dry-run >"$T/o" 2>&1; ok '[ $? = 0 ] && grep -q "does not parse" "$T/o"' "G7 a dry run against a file that does not parse says so in place of the diff"
ap apply limits --from "$C/limits.env" >"$T/o" 2>&1; ok '[ $? = 0 ] && cmp -s "$C/limits.env" "$R/.supervisor/limits.env"' "G7 an apply can repair a file that does not parse"
printf 'garbage line\n' >"$R/.supervisor/limits.env"; B=$(tree); ap rollback limits >"$T/o" 2>&1; ok '[ $? = 0 ] && ! grep -q Traceback "$T/o"' "G7 a rollback finds the unparsable file equal to the bytes the apply replaced: bookkeeping only, no traceback"
printf 'other garbage\n' >"$R/.supervisor/limits.env"; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; printf 'garbage again\n' >"$R/.supervisor/limits.env"; B=$(tree)
ap rollback limits >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-314 "$T/o" && ! grep -q Traceback "$T/o" && [ "$(tree)" = "$B" ]' "G7 a rollback over an unparsable hand edit is refused by the hash rule (314), no traceback"
mkr g7c; chmod a-w "$R/.stella"; ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; rc=$?; chmod u+w "$R/.stella"
ap check connections >/dev/null 2>&1; crc=$?; ok '[ $rc = 1 ] && [ $crc = 0 ] && [ "$(nbk)" = 0 ]' "G7 a write failure reported as nothing changed leaves no pending backup"
ap apply connections --from "$C/conn.json" >/dev/null 2>&1; ok '[ $? = 0 ]' "G7 and the next apply goes through"
mkr g7d; rm -rf "$R/.supervisor/logs"; ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; ok '[ $? = 0 ] && [ "$(nev)" = 1 ]' "G7 a root with no event-log folder: the folder is created, the apply works"
mkr g7e; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; echo '{' >"$R/.supervisor/state/applied.json"
ap check connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-310 "$T/o"' "G7 check on an unreadable applied state: STL-CFG-310"
echo '{' >"$R/.stella/data-files.json"; ap history connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-310 "$T/o"' "G7 history on an unreadable index: STL-CFG-310"
mkr g7f; jq '(.files[] | select(.id == "connections") | .redact_keys) = ["^label$"]' "$R/.stella/data-files.json" >"$T/x" && cp "$T/x" "$R/.stella/data-files.json"; git -C "$R" commit -qam idx
ap apply connections --from "$C/conn.json" --dry-run >"$T/o" 2>&1; ok '[ $? = 0 ] && grep -qE "^[-+][^-+]" "$T/o" && ! grep -q "Changed label" "$T/o"' "G7 a dry run whose masked text is unchanged says so (masked values), never a blank line"
mkr g7g; mv "$R/.stella/settings.json" "$R/.stella/settings2.json"; jq '(.files[] | select(.id == "settings") | .path) = ".stella/settings2.json"' "$R/.stella/data-files.json" >"$T/x" && cp "$T/x" "$R/.stella/data-files.json"
printf 'CALL_TIMEOUT=zq7v\nPLANTED_SETTING=1\n' >"$C/g7.env"; ap apply limits --from "$C/g7.env" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-315 "$T/o"' "G7 the settings registry is found through the index, not a literal path"
if bwrap --dev-bind / / --unshare-user --uid 4242 --gid 4242 -- true 2>/dev/null; then
  mkr g7h; bwrap --dev-bind / / --unshare-user --uid 4242 --gid 4242 -- env PATH="$PB:$OWNER" $AP apply connections --from "$C/conn.json" >"$T/o" 2>&1
  ok '[ $? = 0 ] && jq -e ".who.user == \"4242\"" "$LOG" >/dev/null' "G7 a uid without a passwd entry is recorded as its number"
fi

# G8 the whole set stays valid
mkr g8; jq 'del(.entries[0].data_policy)' "$R/.stella/connections.json" >"$T/x" && cp "$T/x" "$R/.stella/connections.json"
python3 -I "$H/bin/stella_data.py" check 2>&1 | grep -q "could not run" && base_broken=1 || base_broken=0
jq '.pins[0].version = "9.9.9"' "$R/.stella/versions.json" >"$C/v.json"
ap apply versions --from "$C/v.json" >"$T/o" 2>&1; rc=$?
ok '[ $base_broken = 1 ] && [ $rc = 1 ] && grep -q STL-CFG-313 "$T/o" && grep -q "could not run" "$T/o"' "G8 a candidate is refused while the staged set still holds a could-not-run problem, also when the tree already had it (premise broken tree: $base_broken)"
ap apply connections --from "$T/conn.orig" >"$T/o" 2>&1; ok '[ $? = 0 ]' "G8 a candidate that removes the cause is the way out"
mkr g8b; ap apply connections --from "$C/conn.json" >/dev/null 2>&1
for ch in '.backup_dir = ".supervisor/state/other"' '.event_log = ".supervisor/logs/other.jsonl"' '.applied_state = ".supervisor/state/other.json"' '.files |= map(select(.id != "connections"))' '.files |= map(select(.id != "data-files"))'; do
  jq "$ch" "$R/.stella/data-files.json" >"$C/idx.json"; B=$(tree)
  ap apply data-files --from "$C/idx.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && [ "$(tree)" = "$B" ]' "G8 a candidate index that changes a path or drops a row that matters is refused: $ch"
done
jq '(.files[] | select(.id == "connections") | .redact_keys) = ["^zz$"]' "$R/.stella/data-files.json" >"$C/idx.json"; B=$(tree)
ap apply data-files --from "$C/idx.json" >"$T/o" 2>&1; rc=$?; ap rollback data-files >/dev/null 2>&1
ok '[ $rc = 0 ] && [ "$(tree)" = "$B" ]' "G8 the index applies through itself and rolls back"

# G9 check sees every hand change; one name per row
mkr g9; cp "$C/fake-ext.json" "$R/.stella/extensions/fake-ext.json"; git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm ext
ap check extensions >"$T/o" 2>&1; ok '[ $? = 0 ] && grep -q "extensions/fake-ext.json" "$T/o"' "G9 premise: the committed entry is checked"
rm "$R/.stella/extensions/fake-ext.json"; ap check extensions >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "STL-CFG-314.*fake-ext.json" "$T/o"' "G9 a deleted committed folder entry is drift"
git -C "$R" checkout -q -- .stella/extensions; mkdir "$R/.stella/extensions/odd.json"; cp "$C/conn.json" "$R/.stella/connections.json"
ap check >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "STL-CFG-314.*connections differs" "$T/o" && grep -q "odd.json" "$T/o"' "G9 an entry it cannot read is one problem line, the other rows are still checked"
for a in connections/ "extensions/$(printf 'a\nb').json" extensions/A_b-1.json/ "extensions/x y.json"; do
  ap apply "$a" --from "$C/conn.json" >"$T/o" 2>&1; rc=$?; ok '[ $rc = 1 ] && grep -q STL-CFG-31 "$T/o"' "G9 one name per row: refused: $(printf %s "$a" | tr '\n' '~')"
done
mkr g9b; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; chmod 666 "$R/.supervisor/limits.env"
ap check limits >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-314 "$T/o"' "G9 a mode change of an applied file is drift"
chmod 640 "$R/.supervisor/limits.env"; printf 'CALL_TIMEOUT=650\nPLANTED_SETTING=1\n' >"$R/.supervisor/limits.env"; cp "$R/.supervisor/limits.env" "$C/hand.env"; n=$(nev)
ap apply limits --from "$C/hand.env" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && ! grep -q "no change" "$T/o" && [ "$(nev)" = $((n+1)) ] && ap check limits >/dev/null 2>&1' "G9 applying the bytes a hand edit put there records them: one event line, no drift"

# G10 one apply at a time, in order
mkr g10; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; ap apply limits --from "$C/g5ok.env" >/dev/null 2>&1
ok 'ls "$(BK)/limits" | grep -qE "^[0-9]{8}-" && [ "$(ls "$(BK)/limits" | head -1 | cut -c1-8)" -lt "$(ls "$(BK)/limits" | tail -1 | cut -c1-8)" ] && [ "$(jq .counter "$R/.supervisor/state/applied.json")" -ge 2 ]' "G10 backups are named by a counter kept in the applied state"

$AP bogus >/dev/null 2>&1; ok '[ $? = 2 ]' "usage error exits 2"
[ $fails = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
