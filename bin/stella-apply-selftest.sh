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
T=$(mktemp -d -t stella-apply-selftest.XXXXXX); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/tmp"; export TMPDIR=$T/tmp   # the tool stages its whole-set check in the temp folder: keep it inside the scratch folder
R=$T/root; C=$T/cand; mkdir -p "$R/docs/hermes-local" "$R/config" "$R/.supervisor/logs" "$C" "$T/sup/logs"
cp -r "$H/.stella" "$R/"
jq '(.files[] | select(.id == "connections" or .id == "extensions" or .id == "limits") | .owner_only) = false' "$R/.stella/data-files.json" >"$T/nx" && cp "$T/nx" "$R/.stella/data-files.json"   # the cases need these rows not owner-only, whatever the shipped flags say
jq '. + {worker_markers: ["STUB_WORKER_MARK"]}' "$H/docs/hermes-local/roles.json" >"$R/docs/hermes-local/roles.json"
cp -r "$H/docs/hermes-local/hooks" "$R/docs/hermes-local/hooks"   # the table check looks hook files up under the root
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
AP="python3 -I $H/bin/stella-apply.py"; EL="python3 -I $H/bin/event_log.py"
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
tree() { (cd "$R" && find . \( -path ./.git -o -path ./.supervisor/state -o -path ./.supervisor/logs \) -prune -o -printf '%y %m %p\n' | sort; \
  find . \( -path ./.git -o -path ./.supervisor/state -o -path ./.supervisor/logs \) -prune -o -type f -print0 | sort -z | xargs -0 sha256sum); }
# whole: every folder and file under the root, the state and log folders included (type, mode, name; the bytes of each file)
stages() { ls -A "$TMPDIR" | grep '^stella-apply-stage-'; }   # the tool's staging folders only (other cases leave temp folders of their own)
whole() { (cd "$R" && find . -path ./.git -prune -o -printf '%y %m %p\n' | sort; find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum); }
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
B=$(tree); W0=$(whole)
ap apply connections --from "$C/conn.json" --dry-run >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "Changed label" "$T/o" && [ "$(tree)" = "$B" ] && [ ! -e "$LOG" ]' "A5a dry run (json): diff shown, exit 0, no file changed, no event"
ok '[ "$(whole)" = "$W0" ] && [ -z "$(ls -A "$TMPDIR")" ]' "A5a dry run (json) on a root where nothing was applied: every folder and file under the root as it was, the state folders included; no staging copy left"
ap apply owner-settings --from "$C/owner.env" --dry-run >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "API_TOKEN=.\*\*\*" "$T/o" && ! grep -q sekrit- "$T/o" && grep -q "Fake Two" "$T/o" && [ "$(tree)" = "$B" ]' "A5a dry run (env): masked diff, nothing changed"
ap apply limits --from "$C/limits.env" --dry-run >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "PLANTED_SETTING=.\*\*\*" "$T/o" && ! grep -q sekrit- "$T/o" && [ "$(tree)" = "$B" ]' "A5a dry run (secret setting): masked, nothing changed"
ap apply connections --from "$C/bad.json" --dry-run >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && [ "$(tree)" = "$B" ]' "A5a a dry run of an invalid candidate is refused"
ok '[ "$(whole)" = "$W0" ]' "A5a every dry run (json, env, secret setting, refused) left the whole root as it was"

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
ok '[ $rc = 1 ] && grep -q STL-CFG-318 "$T/o" && [ "$(tree)" = "$B" ] && [ "$(nbk)" = 0 ] && [ "$(ap check connections --json | jq -r .files[0].baseline)" = git ]' "an event log that is a link (to /dev/full): refused before anything is touched (the link is refused by the path check), STL-CFG-318"
rm "$LOG"; mkdir "$LOG"
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-318 "$T/o" && [ "$(tree)" = "$B" ] && [ "$(nbk)" = 0 ]' "an event log that is a folder: refused before anything is touched"
rmdir "$LOG"; mv "$T/log.keep" "$LOG"
ap apply connections --from "$C/conn.json" >/dev/null 2>&1
cp "$LOG" "$T/log.keep"; rm "$LOG"; ln -s /dev/full "$LOG"; B2=$(tree)
ap rollback connections >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-318 "$T/o" && [ "$(tree)" = "$B2" ] && [ "$(nbk)" = 1 ]' "a rollback whose event line fails changes nothing and keeps its backup"
rm "$LOG"; mv "$T/log.keep" "$LOG"

# an interrupted apply: the backup is still pending
# (round 6, R5: pending is what the applied state says: no `done` in the backup's record; the meta's status word decides nothing)
n=$(nev); jq 'del(.backups.connections[].done)' "$R/.supervisor/state/applied.json" >"$T/m" && cp "$T/m" "$R/.supervisor/state/applied.json"
ap check connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-323 "$T/o"' "a pending backup is reported by check as an unfinished step (STL-CFG-323)"
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
  cp "$ROLES" "$R/docs/hermes-local/roles.json"; cp "$SET0" "$R/.stella/settings.json"; cp -r "$H/docs/hermes-local/hooks" "$R/docs/hermes-local/hooks"
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
ap history connections/../owner-settings --json >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-322 "$T/o" && ! grep -q backups "$T/o"' "G1 history sends its id through the same target() as apply (a read command's refusal: 322)"
ok '! grep -qE "^ *assert " "$H/bin/stella-apply.py"' "G1 no assert is used as a check"

# G2 one row, one real file
mkr g2; rm "$R/.supervisor/limits.env"; ln -s ../config/owner.env "$R/.supervisor/limits.env"; B=$(tree)
ap apply limits --from "$C/limits.env" --dry-run >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-313 "$T/o" && ! grep -q "API_TOKEN\|sekrit" "$T/o"' "G2 a row path that is a symbolic link to another file: a dry run is refused, nothing of the file is printed"
ap apply limits --from "$C/limits.env" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && [ "$(tree)" = "$B" ] && [ "$(nbk)" = 0 ] && [ ! -e "$LOG" ]' "G2 the apply is refused: the linked file, the backups and the log are untouched"
ap check limits >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-322 "$T/o" && ! grep -q "API_TOKEN\|sekrit" "$T/o"' "G2 check reports the linked row (322) and prints nothing from the file"
mkr g2b; mkdir "$R/elsewhere" "$R/.supervisor/state"; mkdir -p "$R/.supervisor/state/backups"; ln -s ../../../elsewhere "$R/.supervisor/state/backups/connections"
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && [ -z "$(ls -A "$R/elsewhere")" ] && cmp -s "$T/conn.orig" "$R/.stella/connections.json"' "G2 a backup folder that is a symbolic link is refused, nothing written through it"
mkr g2c; jq '(.files[] | select(.id == "capabilities") | .path) = ".stella/features.json"' "$R/.stella/data-files.json" >"$T/x" && cp "$T/x" "$R/.stella/data-files.json"
ap check capabilities >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-322 "$T/o" && grep -qi "same file" "$T/o"' "G2 two index rows that name the same file are refused (each of the two rows)"
ap check connections >"$T/o" 2>&1; ok '[ $? = 0 ]' "G2 a row that is not one of the two still works"
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
# (round 6, W3-RT5-03: the tool's temp name has one shape, the prefix and 16 hex digits; a file that only starts like it is the owner's)
printf 'planted-bytes' >"$R/.stella/.stella-apply.0123456789abcdef"; printf keep >"$R/.stella/.stella-apply-keep"; printf notes >"$R/.stella/.stella-apply.dead"
ap apply connections --from "$C/conn2.json" >/dev/null 2>&1
ok '[ ! -e "$R/.stella/.stella-apply.0123456789abcdef" ] && [ -e "$R/.stella/.stella-apply-keep" ] && [ "$(cat "$R/.stella/.stella-apply.dead")" = notes ]' "G3 the next run sweeps the tool's own stray temp file, only that name (its exact shape: a file that only starts like it is kept)"
rm "$R/.stella/.stella-apply.dead"
mkdir "$(BK)/connections/00000001-unfinished"; printf 'copy' >"$(BK)/connections/00000001-unfinished/file"
# (round 5, Q4: a folder the applied state does not record is never deleted by a command; the owner removes it by hand)
ap check connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "STL-CFG-316.*00000001-unfinished.*remove it by hand" "$T/o"' "G3 check reports a backup folder the applied state does not record, without a meta file (316, named, the way out)"
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "STL-CFG-316.*00000001-unfinished.*remove it by hand" "$T/o"' "G3 apply refuses while such a folder is there, naming it and the way out"
ap rollback connections >"$T/o" 2>&1; rc=$?; kept=$([ -f "$(BK)/connections/00000001-unfinished/file" ] && echo yes)
rm -r "$(BK)/connections/00000001-unfinished"; ap apply connections --from "$C/conn.json" >"$T/o2" 2>&1; ra=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-316 "$T/o" && [ "$kept" = yes ] && [ $ra = 0 ] && ap check connections >/dev/null 2>&1' "G3 rollback deletes no folder it did not record (316); the printed way out (remove it by hand) ends the block: the next apply works, check is clean"

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
# (since W1 round 5 a broken file gives "not judged" lines, not "could not run"; a missing schema row still gives "could not run")
mkr g8; cp "$R/.stella/data-files.json" "$C/idx-whole.json"; jq '.files |= map(select(.id != "data-policy"))' "$C/idx-whole.json" >"$T/x" && cp "$T/x" "$R/.stella/data-files.json"
python3 -I "$H/bin/stella_data.py" check 2>&1 | grep -q "could not run" && base_broken=1 || base_broken=0
jq '.pins[0].version = "9.9.9"' "$R/.stella/versions.json" >"$C/v.json"
ap apply versions --from "$C/v.json" >"$T/o" 2>&1; rc=$?
ok '[ $base_broken = 1 ] && [ $rc = 1 ] && grep -q STL-CFG-313 "$T/o" && grep -q "could not run" "$T/o"' "G8 a candidate is refused while the staged set still holds a could-not-run problem, also when the tree already had it (premise broken tree: $base_broken)"
ap apply data-files --from "$C/idx-whole.json" >"$T/o" 2>&1; ok '[ $? = 0 ]' "G8 a candidate that removes the cause is the way out"
mkr g8n; jq 'del(.entries[0].data_policy)' "$R/.stella/connections.json" >"$T/x" && cp "$T/x" "$R/.stella/connections.json"
python3 -I "$H/bin/stella_data.py" check 2>&1 | grep -q "not judged.*connections" && nj=1 || nj=0
ap apply versions --from "$C/v.json" >"$T/o1" 2>&1; r1=$?
cp "$R/.stella/data-policy.json" "$C/dp.json"; printf '\n' >>"$C/dp.json"   # other bytes, the same document
ap apply data-policy --from "$C/dp.json" >"$T/o2" 2>&1; r2=$?
ok '[ $nj = 1 ] && [ $r1 = 0 ] && [ $r2 = 1 ] && grep -q "STL-CFG-313.*not judged" "$T/o2"' "G8 a 'not judged' line decides by what it means: an unrelated row left unjudged by a broken file does not block a row that was judged (versions applies); the candidate's own row left unjudged is refused (premise: $nj)"
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

# ---- round 3 (fix round 2). Each group starts from a fresh scratch root (mkr). ----
fail_event() {  # <args...>: stella-apply's main in-process; the event line fails (318) when it is written, after the file was replaced
  python3 -I -c '
import importlib.util, sys
sys.dont_write_bytecode = True; spec = importlib.util.spec_from_file_location("sa", sys.argv[1]); sa = importlib.util.module_from_spec(spec); spec.loader.exec_module(sa)
def boom(*a, **k): raise sa.EventError("STL-CFG-318", "simulated")
sa.el.append = boom
sys.exit(sa.main(sys.argv[2:]))' "$H/bin/stella-apply.py" "$@"
}
ST() { echo "$R/.supervisor/state/applied.json"; }
deep() { python3 -I -c 'import sys; n=int(sys.argv[1]); print("{\"a\":"*n + "1" + "}"*n)' "$1"; }
LAST() { tail -n 1 "$LOG"; }

# H1 the tool acts only on records it can tie to its own run
mkr h1a; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; name=$(basename "$(ls -d "$(BK)"/connections/*)")
$EL append --type rollback --what connections --detail "restored backup $name" --user forger >/dev/null 2>&1
ap rollback connections >"$T/o" 2>&1
ok '[ $? = 0 ] && [ "$(jq -s "map(select(.type == \"rollback\")) | length" "$LOG")" = 2 ] && [ "$(LAST | jq -r .who.user)" != forger ]' "H1 a forged rollback line that names the backup does not suppress the tool's own line"
mkr h1b; kill_at event apply connections --from "$C/conn.json" >/dev/null 2>&1; name=$(basename "$(ls -d "$(BK)"/connections/*)")
$EL append --type apply --what connections --detail "backup $name" --user forger >/dev/null 2>&1
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1
ok '[ $? = 0 ] && [ "$(jq -s "map(select(.type == \"apply\")) | length" "$LOG")" = 2 ] && [ "$(LAST | jq -r .who.user)" != forger ]' "H1 a forged apply line does not suppress the line of an apply finished after a kill"
mkr h1c; B=$(tree)
mkdir -p "$(BK)/capabilities/00000005-20260101T000000000000Z"
printf '{"path":".stella/capabilities.json","existed":false,"mode":420,"sha256":null,"new_sha256":"%s","prev_applied":null,"seq":5,"status":"done","token":"aa"}' "$(sha256sum <"$R/.stella/capabilities.json" | cut -d' ' -f1)" >"$(BK)/capabilities/00000005-20260101T000000000000Z/meta.json"
B=$(tree); ap rollback capabilities >"$T/o" 2>&1
ok '[ $? = 1 ] && grep -q STL-CFG-316 "$T/o" && grep -q 00000005-20260101T000000000000Z "$T/o" && [ "$(tree)" = "$B" ]' "H1 a planted backup folder (existed false) is never restored from: 316, names the folder, the file stays"
mkr h1d; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; d=$(ls -d "$(BK)"/connections/*)
mkdir "$d-9"; cp "$d/file" "$d-9/file"; jq '.status = "done"' "$d/meta.json" >"$d-9/meta.json"; mv "$d-9" "$(dirname "$d")/99999999-20260101T000000000000Z"
B=$(tree); ap rollback connections >"$T/o" 2>&1
ok '[ $? = 1 ] && grep -q STL-CFG-316 "$T/o" && [ "$(tree)" = "$B" ]' "H1 a planted copy of a real backup under another name is not restored from"
ap apply connections --from "$C/conn2.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-316 "$T/o"' "H1 an apply refuses while an unrecorded backup folder is there"
mkr h1e; kill_at applied apply connections --from "$C/conn.json" >/dev/null 2>&1; m=$(find "$(BK)" -name meta.json); jq '.seq = 2.5' "$m" >"$T/m" && cat "$T/m" >"$m"
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; ap check >"$T/o2" 2>&1
ok '! grep -q STL-CFG-310 "$T/o2" && jq -e ".counter | type == \"number\" and . == floor" "$(ST)" >/dev/null' "H1 a wrong-typed seq in a record never reaches the applied state"
mkr h1f; mkdir -p "$(dirname "$(ST)")"; printf '{"schema_version":1,"applied":{},"counter":1%0300d}\n' 0 >"$(ST)"
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; ok '[ $? = 0 ]' "H1 a counter the folder name cannot carry does not block every apply"

# H2 an unfinished or damaged backup folder
mkr h2a; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; d=$(ls -d "$(BK)"/connections/*); head -c 40 "$d/meta.json" >"$T/m" && cat "$T/m" >"$d/meta.json"
ap rollback connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-316 "$T/o" && [ -f "$d/file" ]' "H2 a meta file that is present but unreadable is damage: 316, nothing deleted"
mkr h2b; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; ap apply connections --from "$C/conn2.json" >/dev/null 2>&1; mkdir "$(BK)/connections/00000009-stray"
ap rollback connections >"$T/o" 2>&1   # (round 5, Q4: an unrecorded folder is named and kept, 316; nothing else is restored)
ok '[ $? = 1 ] && grep -q "STL-CFG-316.*00000009-stray.*remove it by hand" "$T/o" && [ -d "$(BK)/connections/00000009-stray" ] && cmp -s "$C/conn2.json" "$R/.stella/connections.json" && [ "$(nbk)" = 2 ] && [ "$(nev)" = 2 ]' "H2 a stray folder stops the rollback on its own: named with the way out, nothing restored, nothing deleted"
rmdir "$(BK)/connections/00000009-stray"; ap rollback connections >/dev/null 2>&1; ok 'cmp -s "$C/conn.json" "$R/.stella/connections.json"' "H2 after the printed way out (the stray folder removed by hand) the next rollback undoes the last apply"
mkr h2c; kill_at applied apply connections --from "$C/conn.json" >/dev/null 2>&1; d=$(ls -d "$(BK)"/connections/*); rm "$d/meta.json"; git -C "$R" checkout -q -- .stella/connections.json
ap check connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "removes it" "$T/o"' "H2 the advice for an unfinished folder (no meta, the file holds the saved bytes) says what the command will do"
# (round 6, B2) the README's rule for a RECORDED unfinished folder, asserted again: check 323, apply refuses, rollback removes it
# (exit 0, nothing restored, no line), and running it again finds nothing more to undo
u=$(basename "$d"); n=$(nev)
ok 'grep -q "STL-CFG-323.*rollback connections.*$u.*unfinished" "$T/o"' "G3 check reports a recorded unfinished backup folder as an unfinished step (323), naming it and the command"
ap apply connections --from "$C/conn2.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "STL-CFG-313.*rollback connections.*unfinished" "$T/o" && [ -d "$d" ]' "G3 apply refuses while a recorded unfinished folder is there and names the command; the folder is kept"
ap rollback connections >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "removed the unfinished backup folder.*nothing was restored" "$T/o" && [ ! -e "$d" ] && cmp -s "$T/conn.orig" "$R/.stella/connections.json"' "G3 rollback removes a recorded unfinished folder: exit 0, nothing restored, the file untouched"
ok '[ "$(nev)" = "$n" ] && [ "$(jq -c ".backups.connections // {}" "$(ST)")" = "{}" ] && ap check connections >/dev/null 2>&1' "H2 removing an unfinished folder writes no event line, removes its record, and check is clean"
ap rollback connections >"$T/o" 2>&1; r1=$?; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; r2=$?
ok '[ $r1 = 1 ] && grep -q STL-CFG-316 "$T/o" && [ $r2 = 0 ]' "H2 run again, the rollback has nothing more to undo (316, no backup); the next apply works"
mkr h2d; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; d=$(ls -d "$(BK)"/connections/*); rm "$d/meta.json"
ap check connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-316 "$T/o" && grep -q missing "$T/o"' "H2 a completed backup whose meta was removed by hand is damage (316), not unfinished"

# H3 one row, one real file
mkr h3a; B=$(tree); ln -f "$R/.stella/connections.json" "$R/.stella/capabilities.json"
ap apply capabilities --from "$C/conn.json" --dry-run >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && grep -qi "link" "$T/o"' "H3 a target with more than one hard link is refused before it is read"
mkr h3b; jq '(.files[] | select(.id == "owner-settings") | .path) = ".supervisor/limits.env"' "$R/.stella/data-files.json" >"$C/idx.json"; B=$(tree)
ap apply data-files --from "$C/idx.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && [ "$(tree)" = "$B" ]' "H3 a candidate index with two rows on one file is refused (env rows too)"
jq '(.files[] | select(.id == "versions") | .path) = ".stella/Connections.json"' "$R/.stella/data-files.json" >"$C/idx.json"
ap apply data-files --from "$C/idx.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && [ "$(tree)" = "$B" ]' "H3 two index paths that differ only by case are one file (refused)"
mkr h3c; jq '(.files[] | select(.id == "versions") | .path) = ".stella/extensions/x.json"' "$R/.stella/data-files.json" >"$T/x" && cp "$T/x" "$R/.stella/data-files.json"
ap check versions >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-322 "$T/o"' "H3 a folder row whose folder holds another row's file is refused (that row)"
mkr h3d; ap apply extensions/fake-ext.json --from "$C/fake-ext.json" >/dev/null 2>&1; ap apply extensions/FAKE-EXT.json --from "$C/fake-ext.json" >"$T/o" 2>&1
ok '[ $? = 1 ] && grep -q STL-CFG-313 "$T/o" && grep -qi "case" "$T/o"' "H3 folder entries that differ only by case are one name"

# H4 the lock
python3 -I -c '
import sys, os, threading, time, tempfile
sys.path.insert(0, sys.argv[1]); import event_log as el
d = tempfile.mkdtemp(); p = os.path.join(d, "lk"); hold, go, got = threading.Event(), threading.Event(), []
def a():
    with el.locked(p): hold.set(); go.wait()
def b():
    with el.locked(p): got.append(os.path.exists(p))
ta = threading.Thread(target=a); ta.start(); hold.wait(); tb = threading.Thread(target=b); tb.start(); time.sleep(0.5)
os.unlink(p); go.set(); ta.join(); tb.join(10)
sys.exit(0 if got == [True] else 1)' "$H/bin"
ok '[ $? = 0 ]' "H4 a lock file replaced while a run waits: the waiter locks the file at the path, not the one it opened"

# H5 the proof that was lost: the event line fails after the file was replaced
mkr h5a; mode=$(stat -c %a "$R/.stella/connections.json"); B=$(tree)
fail_event apply connections --from "$C/conn.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-318 "$T/o" && [ "$(tree)" = "$B" ] && [ "$(stat -c %a "$R/.stella/connections.json")" = "$mode" ] && [ "$(nbk)" = 0 ] && [ ! -e "$(ST)" ]' "H5 apply: the event line fails after the replace: bytes and mode back, no applied record (on this fresh root the one true form: no state file), no backup"
ap apply connections --from "$C/conn.json" >/dev/null 2>&1; chmod 600 "$R/.stella/connections.json"; rec0=$(jq -c .applied "$(ST)"); B=$(tree); m=$(find "$(BK)" -name meta.json)
fail_event rollback connections >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-318 "$T/o" && [ "$(tree)" = "$B" ] && [ "$(stat -c %a "$R/.stella/connections.json")" = 600 ] && [ "$(nbk)" = 1 ] && [ "$(jq -r .status "$m")" = done ] && [ "$(jq -c .applied "$(ST)")" = "$rec0" ]' "H5 rollback: the event line fails after the restore: bytes and mode back, applied state and backup as before, meta status done"

# H6 true messages and whole lines
mkr h6a; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; kill_at applied rollback connections >/dev/null 2>&1; ap rollback connections >/dev/null 2>&1
ok 'LAST | jq -e "select(.type == \"rollback\") | .old[\"/entries/0/label\"] == \"Changed label\" and .new[\"/entries/0/label\"] == \"Local model server\"" >/dev/null' "H6 a rollback finished after a kill writes its line with the real old and new values"
mkr h6b; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; cp "$T/conn.orig" "$R/.stella/connections.json"; ap rollback connections >/dev/null 2>&1
ok 'LAST | jq -e ".detail | startswith(\"nothing to restore\")" >/dev/null' "H6 a rollback that finds nothing to restore says so in its line"
mkr h6c; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; printf 'CALL_TIMEOUT=650\nPLANTED_SETTING=1\n' >"$R/.supervisor/limits.env"; cp "$R/.supervisor/limits.env" "$C/hand.env"; n=$(nev)
kill_at event apply limits --from "$C/hand.env" >/dev/null 2>&1; ap apply limits --from "$C/hand.env" >"$T/o" 2>&1
ok '[ $? = 0 ] && [ "$(nev)" = $((n+1)) ] && [ "$(LAST | jq -r .type)" = adopt ] && ap check limits >/dev/null 2>&1' "H6 an adopt killed before its line: the next run writes the one adopt line"
ok 'LAST | jq -e ".detail | length > 0" >/dev/null && ! LAST | grep -q sekrit' "H6 the adopt line says what was recorded (no secret)"
mkr h6d; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; printf '\n' >>"$R/.stella/connections.json"; cp "$R/.stella/connections.json" "$C/hand.json"
ap apply connections --from "$C/hand.json" >/dev/null 2>&1; ap rollback connections >"$T/o" 2>&1
ok '! grep -q "changed outside the apply command" "$T/o"' "H6 after an adopt the older backups no longer make rollback say the file was changed outside the command"
ap apply connections --from "$C/conn2.json" >"$T/o" 2>&1; ok '[ $? = 0 ]' "H6 after an adopt the older backups do not block an apply"
mkr h6e; kill_at applied apply connections --from "$C/conn.json" >/dev/null 2>&1; cp "$C/conn2.json" "$R/.stella/connections.json"
ap apply connections --from "$C/conn2.json" >"$T/o" 2>&1; ok '[ $? = 0 ] && ap check connections >/dev/null 2>&1' "H6 an interrupted apply followed by a hand edit: applying the edited bytes is the way out"

# H7 cheap ones
mkr h7a; kill_at event apply connections --from "$C/conn.json" >/dev/null 2>&1
ap apply connections --from "$C/conn.json" --dry-run >"$T/o" 2>&1; ok '[ $? = 0 ] && grep -q "would finish" "$T/o"' "H7 a dry run reports that an apply would finish an interrupted apply"
ap apply connections --from "$C/conn2.json" --dry-run >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "interrupted" "$T/o"' "H7 a dry run reports that an apply would be refused"
mkr h7b; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; ap rollback limits >/dev/null 2>&1; printf 'HAND=1\n' >>"$R/.supervisor/limits.env"
ap check limits >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-314 "$T/o"' "H7 a hand edit of an untracked file after apply then rollback is drift"
ap check connections/x >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-322 "$T/o"' "H7 check <id>/<anything> on a single-file row is refused (322)"
ok 'python3 -I -c "
import importlib.util, sys
sys.dont_write_bytecode = True; spec = importlib.util.spec_from_file_location(\"sa\", sys.argv[1]); sa = importlib.util.module_from_spec(spec); spec.loader.exec_module(sa)
sys.exit(1 if [p for p in sa.problems(\".stella/connections.json\", None) if \"hook\" in p[1] or \"role\" in p[1]] else 0)" "$H/bin/stella-apply.py"' "H7 a staged check of an untouched tree reports no role-table problem"
mkr h7c; ap apply connections --from "$C/conn.json" --dry-run >/dev/null 2>&1
ok '[ -z "$(stages)" ]' "H7 a dry run removes its staging folder (in the temp folder)"
mkdir -p "$TMPDIR/stella-apply-stage-99999999-1-dead"; printf x >"$TMPDIR/stella-apply-stage-99999999-1-dead/f"; ap apply connections --from "$C/conn.json" >/dev/null 2>&1
ok '[ ! -e "$TMPDIR/stella-apply-stage-99999999-1-dead" ]' "H7 the next apply sweeps a staging folder a killed run left"

# H8 the red team's list
mkr h8a; ap apply connections --from "$C/conn.json" >/dev/null 2>&1
printf '{"schema_version":1,"time":"2026-01-01T00:00:00Z","type":"note","who":{"role":null,"channel":null,"user":"x"},"what":"other","old":%s}\n' "$(deep 600)" >>"$LOG"
ap history connections >"$T/o" 2>&1; r1=$?; $EL tail >/dev/null 2>&1; r2=$?; ap rollback connections >"$T/o" 2>&1; r3=$?
ok '[ $r1 = 0 ] && [ $r2 = 0 ] && [ $r3 = 0 ]' "H8 one deeply nested line in the log stops no history, tail or rollback ($r1 $r2 $r3)"
mkr h8b; ln -f "$R/.stella/connections.json" "$R/.stella/capabilities.json"; ap check capabilities >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -qi "link" "$T/o"' "H8 check refuses a hard-linked row too"
mkr h8c; rm -f "$LOG"; mkfifo "$LOG"; timeout 20 $AP apply connections --from "$C/conn.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-318 "$T/o"' "H8 an event log that is a FIFO is refused (318), no hang (exit $rc)"
mkr h8d; mkfifo "$R/.stella/extensions/stray.json"; timeout 60 $AP apply connections --from "$C/conn.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] || grep -q stray "$T/o"' "H8 a FIFO in a folder row does not refuse an unrelated apply without naming it (exit $rc)"
timeout 20 $AP check extensions >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "stray.json" "$T/o"' "H8 check names the stray entry in one problem line"
for spec in 'CALL_TIMEOUT=900\r\nPLANTED_SETTING=1\r\n' '\xef\xbb\xbfCALL_TIMEOUT=900\nPLANTED_SETTING=1\n' 'CALL_TIMEOUT=0900\nPLANTED_SETTING=1\n'; do
  mkr h8e$RANDOM; B=$(tree); printf "$spec" >"$C/h8.env"; ap apply limits --from "$C/h8.env" >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && grep -q "^STL-CFG-31" "$T/o" && [ "$(tree)" = "$B" ]' "H8 an env value the shell would read differently is refused: $(printf %q "$spec")"
done

# ---- round 4 (rung 2, fix round 1): P1 to P6 of the brief. Each group starts from a fresh scratch root (mkr). ----
# the documented exceptions: folders made on the way, lock files, and the tool's own leftovers by their ONE shape each (the
# tool's TMP_RE and GONE + BACKUP_RE): a temp file, and what lies in a set-aside folder directly in a key's backup folder
quiet() { grep -v -e '^d ' -e '\.lock$' -e '/\.stella-apply\.[0-9a-f]\{16\}$' -e '/state/backups/.*/\.gone-[0-9]\{8\}-[0-9]\{8\}T[0-9]\{12\}Z/[^/]*$'; }
heavy() { find "$R" -path "$R/.git" -prune -o \( -name '.stella-apply.*' -o -path '*/.gone-*/*' \) -type f -size +0c -print; }   # a leftover that holds bytes
fresh() { comm -13 <(sort <<<"$h0") <(heavy | sort); }   # one this run left (a leftover the base planted, swept or not, is not this run's)
nlines() { grep -c '^STL-CFG-' "$1"; }
cat >"$T/step.py" <<'PY'
# <tool> <before|after|term|int|count> <n> <args...>: the tool's main in-process. Every write it makes under the root is counted
# at the system call (a replace or rename, an unlink, a folder made, a tree removed, a write to a file), found by running the
# command, not from a list; the n-th fails BEFORE its effect (before), fails AFTER it (after: the call is done, then raises, as a
# failed folder fsync would), or is followed by SIGTERM / SIGINT (term / int). count: no fault, the number goes to $COUNT_FILE.
# sync: the other calls a write is made of are counted on their own (a file created or truncated by open, fsync, fchmod,
# ftruncate) and the n-th fails AFTER it; count writes their number second.
import errno, importlib.util, os, shutil, signal, sys
spec = importlib.util.spec_from_file_location("sa", sys.argv[1]); sa = importlib.util.module_from_spec(spec); spec.loader.exec_module(sa)
mode, n, cnt, busy, root, xcnt = sys.argv[2], int(sys.argv[3]), [0], [], sa.el.ROOT + os.sep, [0]
def extra(f, path_of, want=lambda a, k: True):
    def w(*a, **k):
        if busy or not want(a, k) or not path_of(a, k).startswith(root):
            return f(*a, **k)
        xcnt[0] += 1
        busy.append(1)
        try:
            r = f(*a, **k)
        finally:
            busy.pop()
        if xcnt[0] == n and mode == "sync":
            raise OSError(errno.EIO, "qa: failed after the call")
        return r
    return w
def where(p, fd):
    try:
        return os.path.join(os.readlink(f"/proc/self/fd/{fd}") if fd is not None else os.getcwd(), os.fsdecode(p))
    except (OSError, TypeError):
        return ""
def hit(f, path_of):
    def w(*a, **k):
        if busy or not path_of(a, k).startswith(root):
            return f(*a, **k)
        cnt[0] += 1
        if cnt[0] == n and mode == "before":
            raise OSError(errno.EIO, "qa: the write failed")
        busy.append(1)
        try:
            r = f(*a, **k)
        finally:
            busy.pop()
        if cnt[0] == n and mode == "after":
            raise OSError(errno.EIO, "qa: failed after the write")
        if cnt[0] == n and mode in ("term", "int"):
            os.kill(os.getpid(), signal.SIGTERM if mode == "term" else signal.SIGINT)
        return r
    return w
first = lambda a, k: where(a[0], k.get("dir_fd", k.get("src_dir_fd")))
os.replace, os.rename = hit(os.replace, lambda a, k: where(a[1], k.get("dst_dir_fd"))), hit(os.rename, lambda a, k: where(a[1], k.get("dst_dir_fd")))
os.unlink, os.mkdir = hit(os.unlink, first), hit(os.mkdir, first)
os.write = hit(os.write, lambda a, k: where("", a[0]))
shutil.rmtree = hit(shutil.rmtree, lambda a, k: os.path.abspath(a[0]))
byfd = lambda a, k: where("", a[0])
os.fsync, os.fchmod, os.ftruncate = extra(os.fsync, byfd), extra(os.fchmod, byfd), extra(os.ftruncate, byfd)
os.open = extra(os.open, lambda a, k: where(a[0], k.get("dir_fd")), lambda a, k: len(a) > 1 and a[1] & (os.O_CREAT | os.O_TRUNC))
try:
    rc = sa.main(sys.argv[4:])
finally:
    if mode == "count":
        print(cnt[0], xcnt[0], file=open(os.environ["COUNT_FILE"], "w"))
sys.exit(rc)
PY
step() { PATH=$PB:$OWNER python3 -I "$T/step.py" "$H/bin/stella-apply.py" "$@"; }

# P1 / Q1: every write of every writing command, found by a counting run, fails before its effect, fails after it, or is
# interrupted: one coded line; "nothing was changed" and "it was undone" only when the whole root is as it was; else what is
# there and the one command, which settles it (check clean) with no event line twice
printf "CALL_TIMEOUT=650\nPLANTED_SETTING='sekrit-hand-1'\n" >"$C/p1hand.env"
mkr p1a; BASE_A=$R
mkr p1f; kill_at event apply limits --from "$C/limits.env" >/dev/null 2>&1; BASE_F=$R
mkr p1d; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; cp "$C/p1hand.env" "$R/.supervisor/limits.env"; BASE_D=$R
mkr p1b; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; printf 'x' >"$R/.supervisor/state/.stella-apply.00000000000000aa"; BASE_B=$R   # (round 6) a leftover of the tool's one temp shape
mkr p1j; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; kill_at applied apply limits --from "$C/g5ok.env" >/dev/null 2>&1
  d=$(ls -d "$(BK)"/limits/* | tail -1); rm "$d/meta.json"; cp "$C/limits.env" "$R/.supervisor/limits.env"; BASE_J=$R   # an unfinished folder
mkr p1c; BASE_CA=$R
mkr p1cb; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; BASE_CB=$R
mkr p1ea; BASE_EA=$R
mkr p1eb; ap apply extensions/fake-ext.json --from "$C/fake-ext.json" >/dev/null 2>&1; BASE_EB=$R
p1bad=""; p1runs=0; p1t0=$(date +%s)
p1() {  # <base> <key> <file> <modes> <command...>
  local base=$1 key=$2 file=$3 modes=$4 n N X mode w0 rc what; shift 4
  R=$T/p1run; rm -rf "$R"; cp -a "$base" "$R"; export STELLA_ROOT=$R; COUNT_FILE=$T/count step count 0 "$@" >/dev/null 2>&1; read -r N X <"$T/count"
  [ "$N" -ge 3 ] && [ "$X" -ge 3 ] || p1bad="$p1bad [$key $1: only $N writes and $X other calls counted]"
  for mode in $modes; do
    for n in $(seq 1 "$([ $mode = sync ] && echo "$X" || echo "$N")"); do
      R=$T/p1run; rm -rf "$R"; cp -a "$base" "$R"; export STELLA_ROOT=$R; LOG=$R/.supervisor/logs/events.jsonl; p1runs=$((p1runs+1))
      w0=$(whole | quiet); h0=$(heavy); step $mode $n "$@" >"$T/o" 2>&1; rc=$?
      what="$key $1 $mode $n (exit $rc: $(grep -o 'STL-CFG-.*' "$T/o" | head -c 150))"
      if grep -q Traceback "$T/o" || { [ $rc != 0 ] && [ "$(nlines "$T/o")" != 1 ]; }; then p1bad="$p1bad [not one coded line: $what]"; continue; fi
      # (round 6, B1) every run that leaves a log: each line is whole JSON, by jq's exit status, before anything reads the log
      if [ -e "$LOG" ] && ! jq -e . "$LOG" >/dev/null 2>&1; then p1bad="$p1bad [an event line that is not whole JSON: $what]"; continue; fi
      if grep -qiE "nothing was changed|was undone" "$T/o"; then   # the whole root as it was (not a re-run that hides it)
        [ "$(whole | quiet)" = "$w0" ] && [ -z "$(fresh)" ] || p1bad="$p1bad [said nothing was changed or undone but the root differs, or a leftover holds bytes: $what]"; continue
      fi
      if [ $rc != 0 ]; then
        grep -qE 'STL-CFG-3(21|18|14)' "$T/o" && grep -qE 'run `|nothing to run' "$T/o" || { p1bad="$p1bad [no state or way out: $what]"; continue; }
        if grep -q 'run `rollback' "$T/o"; then ap rollback "$key" >/dev/null 2>&1
        elif grep -q 'with the same file' "$T/o"; then ap "$@" >/dev/null 2>&1
        elif grep -q 'with a copy of the file as it is' "$T/o"; then cp "$R/$file" "$T/cur.json"; ap apply "$key" --from "$T/cur.json" >/dev/null 2>&1
        fi
      elif [ -n "$(fresh)" ]; then p1bad="$p1bad [exit 0 and a leftover that holds bytes: $what]"
      fi
      # a faulted run that exits 0 is judged like a way out that was followed: check clean, the log whole, no line twice
      ap check "$key" >"$T/o2" 2>&1 || p1bad="$p1bad [check is not clean after exit $rc and the way out: $what; then: $(head -c 120 "$T/o2")]"
      [ ! -e "$LOG" ] || d=$(jq -r 'select(.detail? | type == "string") | .type + " " + ((.detail | capture("token (?<t>[0-9a-f]+)").t) // "")' "$LOG" 2>/dev/null) \
        || { p1bad="$p1bad [the log cannot be parsed: $what]"; continue; }
      [ ! -e "$LOG" ] || [ -z "$(sort <<<"$d" | uniq -d)" ] || p1bad="$p1bad [an event line twice: $what]"
    done
  done
}
# (round 6, B1) every spec walks before, after and term again; sync (the other calls of a write, failing after them) for the env apply and rollback
for spec in "A:apply limits --from $C/limits.env" "F:apply limits --from $C/limits.env" "D:apply limits --from $C/p1hand.env" "B:rollback limits" "J:rollback limits"; do
  p=${spec%%:*}; eval "base=\$BASE_$p"; modes="before after term"; case $p in A|B) modes="before after term sync";; esac
  p1 "$base" limits .supervisor/limits.env "$modes" ${spec#*:}
done
p1 "$BASE_CA" connections .stella/connections.json after apply connections --from "$C/conn.json"
p1 "$BASE_CB" connections .stella/connections.json after rollback connections
p1 "$BASE_EA" extensions/fake-ext.json .stella/extensions/fake-ext.json after apply extensions/fake-ext.json --from "$C/fake-ext.json"
p1 "$BASE_EB" extensions/fake-ext.json .stella/extensions/fake-ext.json after rollback extensions/fake-ext.json
ok '[ -z "$p1bad" ]' "P1/Q1 every write found by a counting run (env row: apply, finish, adopt, rollback, clean-up; json row and folder entry: apply and rollback), failed before or after its effect or interrupted: one coded line, a claim of nothing changed or undone matches the whole root, else the one command settles it ($p1runs runs, $(( $(date +%s) - p1t0 )) s):$p1bad"
R=$T/p1run; rm -rf "$R"; cp -a "$BASE_B" "$R"; export STELLA_ROOT=$R; w0=$(whole | quiet)
COUNT_FILE=$T/count step count 0 rollback limits >/dev/null 2>&1; half=$(( $(cut -d' ' -f1 "$T/count") / 2 ))
R=$T/p1run; rm -rf "$R"; cp -a "$BASE_B" "$R"; export STELLA_ROOT=$R; step int "$half" rollback limits >"$T/o" 2>&1; rc=$?   # mid-way: a write the undo puts back
ok '[ $rc = 1 ] && [ "$(nlines "$T/o")" = 1 ] && ! grep -q Traceback "$T/o" && { ! grep -q "was undone" "$T/o" || [ "$(whole | quiet)" = "$w0" ]; }' "P1 Ctrl-C (SIGINT) half-way through a rollback: one coded line, no traceback, an undone claim is true (exit $rc)"
mkr p1e; head -c 1100000 /dev/zero | tr '\0' x >"$T/huge"; jq --rawfile l "$T/huge" '.entries[0].label = $l' "$T/conn.orig" >"$C/huge.json"; w0=$(whole | quiet)
ap apply connections --from "$C/huge.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q "STL-CFG-313.*event line" "$T/o" && [ "$(whole | quiet)" = "$w0" ] && [ ! -e "$(ST)" ]' "P1 an event line too large is judged before the first write: 313, nothing written, no applied state (W3-CV3-07)"

# P2: every message the tool can print fits the catalog's cut, with a way out (walked from the code); the frames are true
cat >"$T/walk.py" <<'PY'
import ast, json, sys
# Every text the apply and log tools can put in a coded line, found in the code (not a hand list): each string expression outside
# a docstring, a print(), an event line's detail or an argparse/regex call must fit the catalog's 200-character cut, a
# placeholder taken as 52 characters and a slice [:n] as n; a message given to a code whose catalog action defers to the message
# must name a way out.
LIM, NAME = 200, 52   # a key taken as an id and an ordinary entry name; a longer name's text follows its coded line whole (the C cases)
cat = {a["code"]: a for a in json.load(open(sys.argv[1]))["alerts"]}
WAY = ("`", "by hand", "where it is mounted")   # a way out is a command to run, a thing to do by hand, or a mount to change
SKIP = {"print", "event", "build", "add_argument", "add_parser", "ArgumentParser", "compile", "fullmatch", "match", "search", "sub",
        "ArgumentTypeError", "join", "startswith", "endswith", "open", "replace", "split", "partition", "strftime", "encode", "decode"}
bad = []
for f in sys.argv[2:]:
    tree = ast.parse(open(f).read())
    funcs = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
    def est(n, depth=0):
        if isinstance(n, ast.Constant):
            return len(n.value) if isinstance(n.value, str) else NAME
        if isinstance(n, ast.JoinedStr):
            return sum(len(v.value) if isinstance(v, ast.Constant) else est(v.value, depth) for v in n.values)
        if isinstance(n, ast.BinOp) and isinstance(n.op, ast.Add):
            return est(n.left, depth) + est(n.right, depth)
        if isinstance(n, ast.IfExp):
            return max(est(n.body, depth), est(n.orelse, depth))
        if isinstance(n, ast.Subscript) and isinstance(n.slice, ast.Slice) and n.slice.lower is None and isinstance(n.slice.upper, ast.Constant):
            return n.slice.upper.value   # a cut text is taken at its cut
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == "fit":   # fit() prints the first form that fits
            return min(est(x, depth) for x in n.args)
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id in funcs and depth < 5:
            rets = [r.value for r in ast.walk(funcs[n.func.id]) if isinstance(r, ast.Return) and r.value is not None]
            return max([est(r, depth + 1) for r in rets if isinstance(r, (ast.JoinedStr, ast.BinOp, ast.Constant))] or [NAME])
        return NAME
    def consts(n):
        return " ".join(c.value for c in ast.walk(n) if isinstance(c, ast.Constant) and isinstance(c.value, str))
    skip = set()
    for n in ast.walk(tree):
        if isinstance(n, (ast.FunctionDef, ast.Module)) and n.body and isinstance(n.body[0], ast.Expr) and isinstance(n.body[0].value, ast.Constant):
            skip.add(id(n.body[0].value))
        if isinstance(n, ast.Call):
            name = n.func.id if isinstance(n.func, ast.Name) else n.func.attr if isinstance(n.func, ast.Attribute) else ""
            if name in SKIP:
                skip |= {id(x) for a in n.args + [k.value for k in n.keywords] for x in ast.walk(a)}
            if name == "fit":   # the first form that fits is printed: the shortest must fit, the others are judged with it
                skip |= {id(a) for a in n.args}
                if est(n) > LIM:
                    bad.append(f"{f}:{n.lineno} no form of fit() fits: {est(n)} characters")
            code = None
            if name == "bad":
                code = n.args[1].value if len(n.args) > 1 and isinstance(n.args[1], ast.Constant) else "STL-CFG-313"
                msg = n.args[0] if n.args else None
            elif name in ("EventError", "fail", "say") and len(n.args) > 1:
                code, msg = (n.args[0].value if isinstance(n.args[0], ast.Constant) else None), n.args[1]
            if code and msg is not None and any(m in cat.get(code, {}).get("action", "") for m in ("message says", "command the message names", "row the message names")) \
                    and isinstance(msg, (ast.JoinedStr, ast.BinOp, ast.Constant)) and not any(w in consts(msg) for w in WAY):
                bad.append(f"{f}:{n.lineno} {code}: no way out in the message")
    tops = set()
    for n in ast.walk(tree):   # the outermost string expressions
        for c in ast.iter_child_nodes(n):
            if isinstance(c, (ast.JoinedStr, ast.BinOp, ast.IfExp, ast.Constant)) and not isinstance(n, (ast.JoinedStr, ast.BinOp, ast.IfExp, ast.FormattedValue)):
                tops.add(c)
    for t in tops:
        if id(t) in skip or not any(isinstance(x, ast.JoinedStr) or (isinstance(x, ast.Constant) and isinstance(x.value, str)) for x in ast.walk(t)):
            continue
        if est(t) > LIM:
            bad.append(f"{f}:{t.lineno} {est(t)} characters: {ast.unparse(t)[:90]}")
print("\n".join(bad) or "every message fits")
sys.exit(1 if bad else 0)
PY
python3 -I "$T/walk.py" "$H/docs/hermes-local/alert-catalog.json" "$H/bin/stella-apply.py" "$H/bin/event_log.py" >"$T/o" 2>&1
ok '[ $? = 0 ]' "P2 every message the apply and log tools can print fits the catalog's 200-character cut and names a way out where its code defers to it: $(tr '\n' '|' <"$T/o" | head -c 300)"
ok 'for c in STL-CFG-321 STL-CFG-322 STL-CFG-323; do python3 -I $H/bin/alert_catalog.py preview $c problem=x detail=y | grep -q "$c" || exit 1; done; ! python3 -I $H/bin/alert_catalog.py preview STL-CFG-316 problem=x | grep -q "rollback was asked" && ! python3 -I $H/bin/alert_catalog.py preview STL-CFG-318 problem=x | grep -q "A change was not made"' "P2 the half-way, read-refusal and unfinished frames are their own catalog rows; 316 and 318 say nothing untrue for apply, check or a reader"
mkr p2a; ln -f "$R/.stella/connections.json" "$T/p2-second-link"; ap check >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && [ "$(grep -c "^STL-CFG-322.*connections.*hard link.*samefile" "$T/o")" = 1 ] && grep -q "^ok  *capabilities" "$T/o"' "P2 a hard link on one row: one 322 line naming where to look, the other rows are checked (W3-CV3-09)"
ap apply versions --from "$R/.stella/versions.json" >"$T/o" 2>&1; ok '[ $? = 0 ]' "P2 another row still applies while one row is refused"
rm -f "$T/p2-second-link"
mkr p2b; mkdir -p "$(dirname "$(ST)")"; printf '{"schema_version":1,"applied":{},"counter":"7"}\n' >"$(ST)"
ap check connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "STL-CFG-310.*counter.*applied.json" "$T/o"' "P2 a counter of the wrong type names the field and the file"
mkr p2c; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; jq 'del(.backups.limits[].done)' "$(ST)" >"$T/m" && cat "$T/m" >"$(ST)"   # (round 6, R5: pending is the applied state's word)
jq '(.entries[] | select(.key == "CALL_TIMEOUT") | .validation.minimum) = 700' "$R/.stella/settings.json" >"$T/x" && cp "$T/x" "$R/.stella/settings.json"   # the saved 600 fails, the current 900 passes
ap rollback limits >"$T/o1" 2>&1; ap apply limits --from "$C/g5ok.env" >"$T/o2" 2>&1
ok 'grep -qF "apply limits --from <file>\` with a copy of the file as it is" "$T/o1" && grep -qF "apply limits --from <file>\` with a copy of the file as it is" "$T/o2"' "P2 a pending backup whose saved copy no longer validates: apply and rollback print the same one way out (W3-CV3-08)"
cp "$R/.supervisor/limits.env" "$C/p2cur.env"; ap apply limits --from "$C/p2cur.env" >/dev/null 2>&1; ok 'ap check limits >/dev/null 2>&1' "P2 and that way out works (no rule relaxed)"

# P3: what a row is comes from the record or the index row; the disk is compared with it
mkr p3a; ok 'ap check >/dev/null 2>&1' "P3 control: an untouched root is clean"
rm "$R/.stella/connections.json"; mkdir "$R/.stella/connections.json"
ap check connections >"$T/o1" 2>&1; r1=$?; ap check >"$T/o2" 2>&1; r2=$?; ap apply connections --from "$C/conn.json" >"$T/o3" 2>&1; r3=$?
ok '[ $r1 = 1 ] && [ $r2 = 1 ] && grep -q "STL-CFG-310.*put the file back.*folder" "$T/o1" && [ $r3 = 1 ] && grep -q STL-CFG-313 "$T/o3"' "P3 a single-file row whose file became a folder: one line in check (310, the row is not opened, exit 1), apply refused (D2)"
mkr p3b; rm "$R/config/owner.env"; mkdir "$R/config/owner.env"; ap check owner-settings >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-310 "$T/o"' "P3 an env row whose file became a folder is one line in check (310) (W3-VAL3-05)"
mkr p3c; rm -rf "$R/.stella/extensions"; printf '{}\n' >"$R/.stella/extensions"
ap check extensions >"$T/o1" 2>&1; r1=$?; ap apply extensions/fake-ext.json --from "$C/fake-ext.json" >"$T/o2" 2>&1; r2=$?
ok '[ $r1 = 1 ] && grep -q STL-CFG-310 "$T/o1" && [ $r2 = 1 ] && grep -q STL-CFG-313 "$T/o2" && [ "$(cat "$R/.stella/extensions")" = "{}" ]' "P3 a folder row whose folder became a file: one line in check (310), and apply refuses (never a new kind of target)"
mkr p3d; rm -rf "$R/.stella/extensions"; ap check extensions >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "STL-CFG-310.*mkdir -p .stella/extensions.*does not exist" "$T/o"' "P3 a missing folder of a folder row is one line in check (310) with the way out"
mkr p3e; cp "$C/fake-ext.json" "$R/.stella/extensions/fake-ext.json"; git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm ext
rm "$R/.stella/extensions/fake-ext.json"; mkdir "$R/.stella/extensions/fake-ext.json"; ap check extensions >"$T/o" 2>&1
ok '[ $? = 1 ] && grep -q "STL-CFG-314.*fake-ext.json" "$T/o"' "P3 a committed entry that became a folder is drift (314)"
mkr p3f; printf "\xef\xbb\xbfWORKER_GIT_NAME='Fake One'\r\nWORKER_GIT_EMAIL='fake@example.invalid'\r\nAPI_TOKEN='sekrit-token-111'\r\n" >"$R/config/owner.env"; cp "$R/config/owner.env" "$T/crlf"
ap apply owner-settings --from "$C/owner.env" >"$T/o1" 2>&1; r1=$?; ap rollback owner-settings >"$T/o2" 2>&1; r2=$?
ok '[ $r1 = 0 ] && [ $r2 = 0 ] && cmp -s "$T/crlf" "$R/config/owner.env"' "P3 a row read by the stack's own parser (role table owner_settings): apply over a CRLF and BOM file, then rollback, byte-identical (W3-VAL3-01)"
cp "$T/crlf" "$C/crlf.env"; ap apply owner-settings --from "$C/crlf.env" >"$T/o" 2>&1; ok '[ $? = 0 ]' "P3 such a row takes a candidate with CR line ends and a BOM; a shell-sourced row still refuses them (H8 above)"
mkr p3g; jq '(.files[] | select(.id == "data-files") | .path) = "./.stella/data-files.json"' "$R/.stella/data-files.json" >"$T/x" && cp "$T/x" "$R/.stella/data-files.json"
git -C "$R" commit -qam dot; jq '.backup_dir = ".supervisor/state/other"' "$R/.stella/data-files.json" >"$C/idx.json"; w0=$(whole | quiet)
ap apply data-files --from "$C/idx.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "STL-CFG-313.*backup_dir" "$T/o" && [ "$(whole | quiet)" = "$w0" ]' "P3 the index row spelled ./ is still the index: its guards hold (W3-CV3-04)"

# P4: a dry run changes nothing, a killed one leaves nothing past the next command
mkr p4a; w0=$(whole); ap apply extensions/fake-ext.json --from "$C/fake-ext.json" --dry-run >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ "$(whole)" = "$w0" ]' "P4 a dry run of a folder row on a root where nothing was applied leaves the whole root as it was"
ap apply connections --from "$C/conn.json" >/dev/null 2>&1; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; w0=$(whole)
for spec in "connections:conn2.json" "limits:g5ok.env" "extensions/fake-ext.json:fake-ext.json" "owner-settings:owner.env"; do ap apply "${spec%%:*}" --from "$C/${spec#*:}" --dry-run >/dev/null 2>&1; done
ok '[ "$(whole)" = "$w0" ]' "P4 dry runs of every kind of row on a used root leave the whole root as it was (folders, files, modes, bytes)"
python3 -I -c '
import importlib.util, os, signal, sys
spec = importlib.util.spec_from_file_location("sa", sys.argv[1]); sa = importlib.util.module_from_spec(spec); spec.loader.exec_module(sa)
sa.subprocess.run = lambda *a, **k: os.kill(os.getpid(), signal.SIGKILL)
sys.exit(sa.main(sys.argv[2:]))' "$H/bin/stella-apply.py" apply connections --from "$C/conn2.json" --dry-run >/dev/null 2>&1
left=$(stages); lm=$(stat -c %a "$TMPDIR/$left" 2>/dev/null)
ap check connections >/dev/null 2>&1
ok '[ -n "$left" ] && [ "$lm" = 700 ] && [ -z "$(stages)" ] && [ "$(whole)" = "$w0" ]' "P4 a killed dry run leaves its staging copy in a 0700 folder outside the root, and the next command (here check) removes it"
st=$(sed 's/.*) //' /proc/$$/stat | awk '{print $20}'); mkdir "$TMPDIR/stella-apply-stage-$$-1-reused" "$TMPDIR/stella-apply-stage-$$-$st-live" "$TMPDIR/stella-apply-stage-99999999999999999999-1-x" "$TMPDIR/stella-apply-stage-zz"
ap check connections >/dev/null 2>&1
ok '[ ! -e "$TMPDIR/stella-apply-stage-$$-1-reused" ] && [ -d "$TMPDIR/stella-apply-stage-$$-$st-live" ] && [ ! -e "$TMPDIR/stella-apply-stage-99999999999999999999-1-x" ] && [ -d "$TMPDIR/stella-apply-stage-zz" ]' "P4 a staging name is tied to its process id and start time: a reused id does not keep a leftover, a live run keeps its own, a name of any size or shape is no error (W3-CV3-03)"
rm -rf "$TMPDIR"/stella-apply-stage-*

# P5: the owner folder as it really is (folder 0555, file 0444)
for spec in "owner-settings:config:owner.env:owner.env" "connections:.stella:connections.json:conn.json"; do
  IFS=: read -r id dir f cand <<<"$spec"
  mkr p5-$id; chmod 444 "$R/$dir/$f"; chmod 555 "$R/$dir"; w0=$(whole)
  ap apply "$id" --from "$C/$cand" >"$T/o1" 2>&1; r1=$?; ap rollback "$id" >"$T/o2" 2>&1; r2=$?
  ok '[ $r1 = 1 ] && grep -q "^STL-CFG-313.*chmod u+w $dir\`.*chmod 555 $dir\`.*read-only" "$T/o1" && [ $r2 = 1 ] && [ "$(whole)" = "$w0" ]' "P5 $id on a read-only folder: refused before any write, the folder named, read-only, the two commands; nothing left behind"
  chmod 755 "$R/$dir"; ap apply "$id" --from "$C/$cand" >"$T/o" 2>&1; r1=$?; m1=$(stat -c %a "$R/$dir/$f"); ap rollback "$id" >/dev/null 2>&1; r2=$?
  ok '[ $r1 = 0 ] && [ $m1 = 444 ] && [ $r2 = 0 ] && [ "$(stat -c %a "$R/$dir/$f")" = 444 ]' "P5 $id with the folder writable: applied and rolled back, the file keeps mode 0444 through both"
done

# P6: the Low ones
mkr p6a; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; tok=$(ap history connections --json | jq -r '.events[-1].detail' | grep -o 'token [0-9a-f]*')
$EL append --type rollback --what connections --detail "restored backup x $tok" --user forger >/dev/null 2>&1
kill_at applied rollback connections >/dev/null 2>&1; ap rollback connections >/dev/null 2>&1
ok '[ "$(LAST | jq -r .type)" = rollback ] && [ "$(LAST | jq -r .who.user)" != forger ]' "P6 a forged rollback line carrying the apply's token does not suppress a resumed rollback's own line (W3-CV3-01)"
for t in '.mode = 2541' '.existed = false | .sha256 = null'; do
  mkr p6b$RANDOM; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; m=$(find "$(BK)" -name meta.json); jq "$t" "$m" >"$T/m" && cat "$T/m" >"$m"; B=$(tree)
  ap rollback connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-316 "$T/o" && [ "$(tree)" = "$B" ]' "P6 a recorded backup rewritten in place is refused against the applied state's record, the file kept: $t (W3-CV3-02)"
done
mkr p6c; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; ap apply connections --from "$C/conn2.json" >/dev/null 2>&1
python3 -I -c '
import importlib.util, os, signal, sys
spec = importlib.util.spec_from_file_location("sa", sys.argv[1]); sa = importlib.util.module_from_spec(spec); spec.loader.exec_module(sa)
real = sa.shutil.rmtree
sa.shutil.rmtree = lambda p, *a, **k: os.kill(os.getpid(), signal.SIGKILL) if sa.GONE in p and k.get("ignore_errors") else real(p, *a, **k)
sys.exit(sa.main(sys.argv[2:]))' "$H/bin/stella-apply.py" rollback connections >/dev/null 2>&1
ap check connections >"$T/o" 2>&1; rc=$?; ap rollback connections >"$T/o2" 2>&1; cmp -s "$C/conn.json" "$R/.stella/connections.json"; still=$?
ap rollback connections >"$T/o3" 2>&1
ok '[ $rc = 0 ] && [ $still = 0 ] && grep -q "already complete" "$T/o2" && ! grep -q "unfinished" "$T/o2" && cmp -s "$T/conn.orig" "$R/.stella/connections.json" && [ "$(jq -r .type "$LOG" | tr "\n" " ")" = "apply apply rollback rollback " ]' "P6 a rollback killed inside its final removal: check is clean, the rerun says the rollback was already complete and undoes nothing more (W3-CV4-04), no 'unfinished' text; the rollback after it undoes the change before (W3-VER3-03)"
ok 'ap --check connections >/dev/null 2>&1' "P6 --check is accepted for check (W3-VAL3-09)"
mkr p6d; python3 -I "$T/step.py" "$H/bin/stella-apply.py" count 0 apply connections --from "$C/conn.json" >/dev/null 2>&1
python3 -I -c '
import importlib.util, os, signal, sys
spec = importlib.util.spec_from_file_location("sa", sys.argv[1]); sa = importlib.util.module_from_spec(spec); spec.loader.exec_module(sa)
real, tgt = sa.atomic_write, os.path.join(sa.el.ROOT, ".stella/connections.json")
sa.atomic_write = lambda p, *a: os.kill(os.getpid(), signal.SIGKILL) if p == tgt else real(p, *a)
sys.exit(sa.main(sys.argv[2:]))' "$H/bin/stella-apply.py" apply connections --from "$C/conn2.json" >/dev/null 2>&1
n0=$(nev); ap rollback connections >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ "$(nev)" = "$n0" ] && ap check connections >/dev/null 2>&1' "P6 an apply killed before its replace, then rollback: no event line for a change that never took effect (L1)"
mkr p6e; kill_at applied apply connections --from "$C/conn.json" >/dev/null 2>&1; ap rollback connections >/dev/null 2>&1
ok '[ "$(jq -r .type "$LOG" | tr "\n" " ")" = "apply rollback " ] && cmp -s "$T/conn.orig" "$R/.stella/connections.json"' "P6 an apply killed after its replace, then rollback: the apply line first, then the rollback line (L2)"

# ---- round 5 (rung 2, fix round 2): Q3 to Q7 of the brief ----
inproc() {  # <python body> <args...>: the tool's main in-process, sa loaded, the body run first
  PATH=$PB:$OWNER python3 -I -c "import importlib.util, os, signal, sys
spec = importlib.util.spec_from_file_location('sa', sys.argv[1]); sa = importlib.util.module_from_spec(spec); spec.loader.exec_module(sa)
$1
sys.exit(sa.main(sys.argv[2:]))" "$H/bin/stella-apply.py" "${@:2}"
}
# Q3 an interrupt while waiting for a lock ends the run at once, one coded line; two signals are one stop
for spec in "state:.supervisor/state/applied.json.lock:TERM" "log:.supervisor/logs/events.jsonl.lock:TERM INT"; do
  IFS=: read -r what lk sigs <<<"$spec"
  mkr q3$what; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; w0=$(whole | quiet)
  flock -x "$R/$lk" sleep 12 & h=$!; sleep 0.5
  PATH=$PB:$OWNER $AP apply limits --from "$C/g5ok.env" >"$T/o" 2>&1 & p=$!; sleep 2; t0=$(date +%s)   # $! is the tool itself
  for s in $sigs; do kill -$s $p 2>/dev/null; sleep 0.3; done
  wait $p; rc=$?; t=$(( $(date +%s) - t0 )); kill $h 2>/dev/null; wait $h 2>/dev/null
  ok '[ $rc = 1 ] && [ $t -le 3 ] && [ "$(nlines "$T/o")" = 1 ] && ! grep -q Traceback "$T/o" && { ! grep -qiE "was undone|nothing was changed" "$T/o" || [ "$(whole | quiet)" = "$w0" ]; }' "Q3 $what lock held, $sigs: the run ends in $t s (no wait for the holder), exit $rc, one coded line, a claim of undone true"
done
mkr q3c; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; w0=$(whole | quiet)
inproc 'real = sa.cause_of
def c(*a):
    os.kill(os.getpid(), signal.SIGINT); os.kill(os.getpid(), signal.SIGTERM)
    return real(*a)
sa.cause_of = c
r0 = sa.set_applied
def s(*a, **k):
    r0(*a, **k); os.kill(os.getpid(), signal.SIGTERM)
sa.set_applied = s' rollback limits >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && [ "$(nlines "$T/o")" = 1 ] && ! grep -q Traceback "$T/o" && { ! grep -q "was undone" "$T/o" || [ "$(whole | quiet)" = "$w0" ]; }' "Q3 a second and third interrupt inside the failure handler change nothing: one undo, one coded line (exit $rc)"

# Q4 a saved state is believed only as far as the applied state binds it
mkr q4a; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; m=$(find "$(BK)" -name meta.json)
jq '.status = "rollback-pending" | .rb_token = "x" | .rb_same = true | .rb_logged = false' "$m" >"$T/m" && cat "$T/m" >"$m"
ap rollback limits >"$T/o" 2>&1
ok '[ $? = 0 ] && [ "$(jq -r .type "$LOG" | tr "\n" " ")" = "apply rollback " ] && ap check limits >/dev/null 2>&1' "Q4 a meta forged as rollback-pending is not believed: the rollback writes its own line (W3-CRT4-04 A)"
mkr q4b; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; m=$(find "$(BK)" -name meta.json)
jq '.prev_applied = {"sha256": "ab", "mode": 420, "time": "x"}' "$m" >"$T/m" && cat "$T/m" >"$m"; w0=$(whole | quiet)
ap rollback limits >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-316 "$T/o" && [ "$(whole | quiet)" = "$w0" ]' "Q4 a forged prev_applied disagrees with the applied state: 316, nothing restored or deleted (W3-CRT4-04 B)"
mkr q4c; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; mkdir "$(BK)/limits/00000009-planted"
ap rollback limits >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "STL-CFG-316.*00000009-planted" "$T/o" && [ -d "$(BK)/limits/00000009-planted" ]' "Q4 a folder the applied state does not record, with no meta, is named (316) and never deleted (W3-CRT4-05)"

# Q5 "git could not say" is not "not in HEAD"
mkr q5; cp "$C/conn2.json" "$R/.stella/connections.json"
ap check connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-314 "$T/o"' "Q5 control: a hand edit of a committed, never-applied file is drift"
mkdir -p "$T/nogit"; printf '#!/bin/sh\nexit 128\n' >"$T/nogit/git"; chmod +x "$T/nogit/git"
PATH=$T/nogit:$PB:$OWNER $AP check connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "STL-CFG-322.*baseline cannot be read" "$T/o"' "Q5 a git that exits 128: check exits 1 and says the baseline cannot be read (W3-CRT4-06)"
obj=$(git -C "$R" rev-parse HEAD:.stella/connections.json); o=$R/.git/objects/${obj:0:2}/${obj:2}; chmod u+w "$o"; : >"$o"
ap check connections >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "baseline cannot be read" "$T/o"' "Q5 a damaged committed blob: check exits 1, baseline cannot be read"
cp "$R/.stella/connections.json" "$C/q5cur.json"; w0=$(whole | quiet); ap apply connections --from "$C/q5cur.json" >"$T/o" 2>&1
ok '[ $? = 1 ] && grep -q "baseline cannot be read" "$T/o" && [ "$(whole | quiet)" = "$w0" ]' "Q5 an apply that needs the baseline refuses before any write"

# Q6 the file is judged at the moment it is replaced
mkr q6a; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; jq '.entries[0].label = "Q6-HAND-EDIT"' "$T/conn.orig" >"$C/q6edit.json"
edit_at() { printf '%s' "real, done = getattr(sa, '$1'), []
def h(*a, **k):
    if not done:
        done.append(1); open(os.path.join(sa.el.ROOT, '$2'), 'wb').write(open('$3', 'rb').read())
    return real(*a, **k)
setattr(sa, '$1', h)"; }
inproc "$(edit_at validate .stella/connections.json "$C/q6edit.json")" rollback connections >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-314 "$T/o" && grep -q Q6-HAND-EDIT "$R/.stella/connections.json" && [ "$(nbk)" = 1 ]' "Q6 a hand edit saved while the rollback validates: 314, nothing replaced, the edit and the backup kept (W3-CRT4-07 A)"
mkr q6b; printf 'CALL_TIMEOUT=777\nPLANTED_SETTING=1\n' >"$C/q6edit.env"
inproc "$(edit_at register .supervisor/limits.env "$C/q6edit.env")" apply limits --from "$C/limits.env" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q "CALL_TIMEOUT=777" "$R/.supervisor/limits.env" && [ "$(nlines "$T/o")" = 1 ]' "Q6 a hand edit saved between the apply's read and its replace is kept, the apply refused (W3-CRT4-07 B)"

# Q7 the Low ones
mkr q7a; chmod 2644 "$R/.stella/connections.json"; w0=$(whole | quiet)
ap apply connections --from "$C/conn.json" >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "STL-CFG-313.*chmod 644" "$T/o" && [ "$(whole | quiet)" = "$w0" ]' "Q7 a file with a setgid bit is refused before any write, with the chmod that fixes it (W3-CRT4-08)"
mkr q7b; printf 'export CALL_TIMEOUT=600\n' >"$R/.supervisor/limits.env"; cp "$R/.supervisor/limits.env" "$T/q7b.orig"
ap apply limits --from "$C/limits.env" >/dev/null 2>&1; ap rollback limits >"$T/o" 2>&1
ok '[ $? = 0 ] && cmp -s "$T/q7b.orig" "$R/.supervisor/limits.env"' "Q7 saved bytes the reader cannot parse (a shell form) were in use as they are: rollback restores them (W3-CRT4-10)"
mkr q7c; printf "WORKER_GIT_NAME='Fake One'\nWORKER_GIT_EMAIL='fake@example.invalid'\nAPI_TOKEN='1'\n" >"$R/config/owner.env"
mkdir -p "$(BK)/owner-settings/00000051-20260101T101010000000Z"; echo '{"token":"x"}' >"$(BK)/owner-settings/00000051-20260101T101010000000Z/meta.json"
ap apply owner-settings --from "$C/owner.env" >"$T/o" 2>&1; ok 'grep -qF 00000051-20260101T101010000000Z "$T/o" && grep -q "remove it by hand" "$T/o"' "Q7 a short masked value garbles no folder name or command in the coded line (W3-CRT4-09)"
mkr q7d; D=.supervisor/qa-a-folder-with-a-rather-long-name-for-this-test; mkdir -p "$R/$D"; git -C "$R" mv -f .supervisor/limits.env "$D/limits.env" 2>/dev/null || mv "$R/.supervisor/limits.env" "$R/$D/limits.env"
jq --arg p "$D/limits.env" '(.files[] | select(.id == "limits") | .path) = $p' "$R/.stella/data-files.json" >"$T/x" && cp "$T/x" "$R/.stella/data-files.json"; chmod 555 "$R/$D"
ap apply limits --from "$C/limits.env" >"$T/o" 2>&1; rc=$?; chmod 755 "$R/$D"; ok '[ $rc = 1 ] && grep -qF "chmod u+w $D\`" "$T/o"' "Q7 a read-only folder with a long path: the chmod command names it whole (W3-CV4-06)"
n41=$(head -c 36 /dev/zero | tr '\0' a).json
ap apply "extensions/$n41" --from "$C/fake-ext.json" >"$T/o" 2>&1; rc=$?; ap check "extensions/$n41" >"$T/o2" 2>&1
ok '[ $rc = 0 ] && [ $? = 0 ] && cmp -s "$C/fake-ext.json" "$R/.stella/extensions/$n41"' "Q7 an entry name of 41 characters is applied: the tool has no name limit of its own (owner decision of 2026-11-12): $(head -c 200 "$T/o")"
mkr q7e; printf 'CALL_TIMEOUT=600\nQA_FREE=a\000b\n' >"$C/nul.env"; ap apply limits --from "$C/nul.env" >"$T/o" 2>&1
ok '[ $? = 1 ] && grep -q "STL-CFG-313.*NUL" "$T/o"' "Q7 a NUL byte in a candidate a shell reads is refused (W3-RT4-10)"
mkr q7f; w0=$(whole); inproc 'import tempfile; tempfile.tempdir = sa.el.ROOT' apply connections --from "$C/conn.json" --dry-run >"$T/o" 2>&1
ok '[ $? = 1 ] && grep -q "set TMPDIR" "$T/o" && [ "$(whole)" = "$w0" ]' "Q7 a temp folder inside the stack root is refused, nothing staged there (W3-RT4-09)"
PATH=$PB:$OWNER TMPDIR=/nonexistent-q7 python3 -I -c 'import tempfile; tempfile.tempdir = "/nonexistent-q7"; import runpy, sys; sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name="__main__")' "$H/bin/stella-apply.py" check connections >"$T/o" 2>&1
ok '[ $? = 0 ]' "Q7 check needs no temp folder (W3-VER4-06)"
mkr q7g; chmod 555 "$R/.stella"; ap apply connections --from "$C/conn.json" --dry-run >"$T/o" 2>&1; rc=$?; chmod 755 "$R/.stella"
ok '[ $rc = 1 ] && grep -q "chmod u+w .stella" "$T/o"' "Q7 a dry run makes the refusals the apply makes before its first write (W3-CV4-09)"
mkr q7h; ap apply connections --from "$C/conn.json" --dry-run >/dev/null 2>&1; w0=$(whole)
inproc 'sa.text = lambda *a, **k: os.kill(os.getpid(), signal.SIGKILL)' apply connections --from "$C/conn2.json" --dry-run >/dev/null 2>&1
ap check connections >/dev/null 2>&1; ok '[ "$(whole)" = "$w0" ] && [ -z "$(stages)" ]' "Q7 a dry run killed at its diff leaves the root as it was and no staging copy past the next command (W3-VAL4-07)"

# Q2 what a row IS: the data tool's one rule (stella_data.folder_row); the disk and the applied record are compared with it
mkr q2; mkdir -p "$R/.stella/qa-folder.json" "$R/.stella/qa-caps"; cp "$C/fake-ext.json" "$R/.stella/qa-single"; cp "$C/fake-ext.json" "$R/.stella/qa-folder.json/a.json"
jq '.entries = [.entries[0] | .id = "qa-cap-one"]' "$R/.stella/capabilities.json" >"$R/.stella/qa-caps/a.json"
q2row() { printf '{"id":"%s","path":"%s","schema":"%s","format":"json","owner_only":false,"redact_keys":[],"list_key":%s,"id_field":"%s"}' "$@"; }
jq --argjson a "$(q2row qa-single .stella/qa-single extension null id)" --argjson b "$(q2row qa-folder .stella/qa-folder.json extension null id)" \
   --argjson c "$(q2row qa-caps .stella/qa-caps capabilities '"entries"' id)" \
   --argjson d "$(jq -c '.files[]|select(.id=="limits")|.id="qa-env"|.path="qa-newdir/qa.env"|.owner_only=false' "$R/.stella/data-files.json")" \
   '.files += [$a, $b, $c, $d]' "$R/.stella/data-files.json" >"$T/x" && cp "$T/x" "$R/.stella/data-files.json"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm kinds
jq '.entries[0].summary = "Q2 caps"' "$R/.stella/qa-caps/a.json" >"$C/q2c.json"; printf 'QA_X=1\n' >"$C/q2d.env"; w0=$(whole | quiet)
ap apply qa-single --from "$C/fake-ext2.json" >"$T/oa" 2>&1; ra=$?; ap apply qa-folder/a.json --from "$C/fake-ext2.json" >"$T/ob" 2>&1; rb=$?
ap apply qa-env --from "$C/q2d.env" >"$T/od" 2>&1; rd=$?
ok '[ $ra = 1 ] && grep -q "STL-CFG-313.*ends in .json" "$T/oa" && [ $rb = 1 ] && grep -q "STL-CFG-313.*rename the path of qa-folder" "$T/ob" && [ $rd = 1 ] && grep -q "STL-CFG-313.*mkdir -p qa-newdir" "$T/od" && [ "$(whole | quiet)" = "$w0" ]' "Q2 a one-file json row with no suffix and a folder named *.json are refused with the way out (the data tool refuses them too); an env row whose folder is missing is refused before any write, naming the folder (W3-RT4-05 a, b, d)"
ap check >"$T/o" 2>&1; ok '[ "$(grep -c "STL-CFG-310.*qa-single" "$T/o")" = 1 ] && [ "$(grep -c "STL-CFG-310.*qa-folder" "$T/o")" = 1 ]' "Q2 check shows one line for each row whose disk disagrees with the rule"
ap apply qa-caps/a.json --from "$C/q2c.json" >"$T/oc" 2>&1; ok '[ $? = 0 ]' "Q2 a folder row with a list key is a folder of entries and applies (W3-RT4-05 c)"
mkr q2r; ap apply connections --from "$C/conn.json" >/dev/null 2>&1; mkdir "$R/.stella/conns"; cp "$C/conn.json" "$R/.stella/conns/a.json"
jq '(.files[] | select(.id == "connections") | .path) = ".stella/conns"' "$R/.stella/data-files.json" >"$T/x" && cp "$T/x" "$R/.stella/data-files.json"
ap check connections >"$T/o1" 2>&1; r1=$?; ap rollback connections/a.json >"$T/o2" 2>&1; r2=$?
ok '[ $r1 = 1 ] && grep -q "put the index path of connections back" "$T/o1" && [ $r2 = 1 ] && grep -q "put the index path of connections back" "$T/o2"' "Q2 an applied record that disagrees with the rule (the index path changed after an apply) refuses that row with its way out, one line in check"

# ---- round 6 (rung 3, fix round 1): R1 to R6 of the brief ----
waitf() { for _ in $(seq 300); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
# R1 one lock from the first read of the row to the printed line: a failing run is held inside its failure handler (before its
# undo, then after its line); a run of the same row and one of another row wait until it has printed
cat >"$T/hold.py" <<'PY'
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("sa", sys.argv[1]); sa = importlib.util.module_from_spec(spec); spec.loader.exec_module(sa)
flag, real_failed, real_set, once = sys.argv[2], sa.failed, sa.set_applied, []
def wait(a, g):
    open(os.path.join(flag, a), "w").close()
    for _ in range(300):
        if os.path.exists(os.path.join(flag, g)): break
        time.sleep(0.1)
def set_applied(*a, **k):
    real_set(*a, **k)
    if not once:   # the first state write lands and then fails; the undo's own write works
        once.append(1); raise OSError(5, "qa: failed after the state write")
def failed(e, read_cmd):
    wait("at1", "go1"); rc = real_failed(e, read_cmd); sys.stderr.flush(); wait("at2", "go2"); return rc
sa.set_applied, sa.failed = set_applied, failed
sys.exit(sa.main(sys.argv[3:]))
PY
mkr r1; mkdir "$T/r1f"; w0=$(whole | quiet); printf "CALL_TIMEOUT=700\nPLANTED_SETTING='x'\n" >"$C/r1b.env"
PATH=$PB:$OWNER python3 -I "$T/hold.py" "$H/bin/stella-apply.py" "$T/r1f" apply limits --from "$C/limits.env" >"$T/oa" 2>&1 & pa=$!
waitf "$T/r1f/at1"
ap apply limits --from "$C/r1b.env" >"$T/ob" 2>&1 & pb=$!
ap apply connections --from "$C/conn.json" >"$T/oc" 2>&1 & pc=$!
sleep 2; held1=$(kill -0 $pb 2>/dev/null && kill -0 $pc 2>/dev/null && [ ! -s "$T/ob" ] && [ ! -s "$T/oc" ] && echo yes)
touch "$T/r1f/go1"; waitf "$T/r1f/at2"; said=$(cat "$T/oa"); w1=$(whole | quiet)
sleep 1; held2=$(kill -0 $pb 2>/dev/null && kill -0 $pc 2>/dev/null && [ ! -s "$T/ob" ] && [ ! -s "$T/oc" ] && echo yes)
touch "$T/r1f/go2"; wait $pa; ra=$?; wait $pb; rb=$?; wait $pc; rc=$?
ok '[ "$held1" = yes ] && [ "$held2" = yes ]' "R1 while a failing run undoes and prints, a run of the same row and a run of another row wait (during the undo: ${held1:-no}; after its line, lock still held: ${held2:-no})"
ok '[ $ra = 1 ] && [ "$(grep -c "^STL-CFG-" <<<"$said")" = 1 ] && grep -q "was undone" <<<"$said" && [ "$w1" = "$w0" ]' "R1 the failing run's line was made under the lock and is true of the whole root at that moment (exit $ra: $(head -c 160 <<<"$said"))"
ok '[ $rb = 0 ] && [ $rc = 0 ] && ap check limits >/dev/null 2>&1 && ap check connections >/dev/null 2>&1 && [ "$(nev)" = 2 ] && jq -e . "$LOG" >/dev/null 2>&1 && [ "$(nbk)" = 2 ]' "R1 the two runs that waited then apply on the undone state: both exit 0 ($rb $rc: $(head -c 120 "$T/ob")), check clean for both, two whole event lines, two backups"

# R4 an undo asks one question. A hand edit is saved right before EVERY counted system call (each open, write, sync, mode change,
# rename, removal, folder made: found by a counting run) between the command's one read of the file and its replace, for apply,
# rollback and `settings.py set`. Each run ends in exactly one of: the change made and the edit lost, only inside the stated
# window (after the last compare's open of the file); 314, the edit kept, the root otherwise as before; a line whose way out,
# run as printed, ends with check clean
cat >"$T/edit.py" <<'PY'
# <tool> <n|count> <edit file> <root-relative target> <args...>: the tool's main in-process; right before its n-th counted call
# the target gets the edit's bytes. count: "<first open of the target> <its last open before the replace> <the replace>" to $COUNT_FILE
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("sa", sys.argv[1]); sa = importlib.util.module_from_spec(spec); spec.loader.exec_module(sa)
n, hand, tgt = sys.argv[2], open(sys.argv[3], "rb").read(), os.path.join(sa.el.ROOT, sys.argv[4])
cnt, busy, opens, repl = [0], [], [], []
def where(p, fd):
    try:
        return os.path.join(os.readlink(f"/proc/self/fd/{fd}") if fd is not None else os.getcwd(), os.fsdecode(p))
    except (OSError, TypeError):
        return ""
def hit(name, f, path_of):
    def w(*a, **k):
        if busy:
            return f(*a, **k)
        cnt[0] += 1
        if path_of(a, k) == tgt and not repl:
            (opens if name == "open" else repl if name == "replace" else []).append(cnt[0])
        if str(cnt[0]) == n:
            busy.append(1)
            with open(tgt, "wb") as h:
                h.write(hand)
            busy.pop()
        return f(*a, **k)
    return w
first, none = (lambda a, k: where(a[0], k.get("dir_fd"))), (lambda a, k: "")
os.open, os.replace = hit("open", os.open, first), hit("replace", os.replace, lambda a, k: where(a[1], k.get("dst_dir_fd")))
for x in ("rename", "unlink", "mkdir", "write", "fsync", "fchmod"):
    setattr(os, x, hit(x, getattr(os, x), none))
try:
    rc = sa.main(sys.argv[5:])
finally:
    if n == "count":
        print(opens[0], opens[-1], repl[0], file=open(os.environ["COUNT_FILE"], "w"))
sys.exit(rc)
PY
mkdir -p "$T/r4bin"; cp -r "$H/bin" "$T/r4bin/bin"
printf '#!/usr/bin/env python3\nimport os, runpy, sys\nsys.argv = ["%s", "%s", os.environ.get("R4_N", "0"), os.environ["R4_EDIT"], os.environ["R4_REL"], *sys.argv[1:]]\nrunpy.run_path(sys.argv[0], run_name="__main__")\n' "$T/edit.py" "$H/bin/stella-apply.py" >"$T/r4bin/bin/stella-apply.py"
printf 'CALL_TIMEOUT=777\nPLANTED_SETTING=1\n' >"$C/r4edit.env"; export R4_EDIT=$C/r4edit.env R4_REL=.supervisor/limits.env
r4run() {  # <n> <command...>: apply and rollback in-process, `set` through a copy of bin/ whose apply tool is the same wrapper
  case $2 in set) R4_N=$1 PATH=$PB:$OWNER python3 -I "$T/r4bin/bin/settings.py" "${@:2}";;
    *) PATH=$PB:$OWNER python3 -I "$T/edit.py" "$H/bin/stella-apply.py" "$1" "$R4_EDIT" "$R4_REL" "${@:2}";; esac
}
mkr r4a; R4A=$R; mkr r4b; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; R4B=$R
r4bad=""; r4runs=0; r4t0=$(date +%s)
r4() {  # <base> <every k-th site> <command...>
  local base=$1 every=$2 n n1 nl nr rc w1 what; shift 2
  R=$T/r4run; rm -rf "$R"; cp -a "$base" "$R"; export STELLA_ROOT=$R; COUNT_FILE=$T/count r4run count "$@" >/dev/null 2>&1; read -r n1 nl nr <"$T/count"
  [ "${nr:-0}" -gt "${n1:-0}" ] || { r4bad="$r4bad [$1: no read and replace of the file counted]"; return; }
  rm -rf "$R"; cp -a "$base" "$R"; cat "$R4_EDIT" >"$R/$R4_REL"; w1=$(whole | quiet)   # the root as before, with the edit
  for n in $(seq $((n1 + 1)) "$nr"); do
    [ $(( (n - n1) % every )) = 0 ] || [ "$n" -ge "$nl" ] || continue
    R=$T/r4run; rm -rf "$R"; cp -a "$base" "$R"; export STELLA_ROOT=$R; LOG=$R/.supervisor/logs/events.jsonl; r4runs=$((r4runs+1))
    r4run "$n" "$@" >"$T/o" 2>&1; rc=$?; what="$1 edit before call $n of $n1..$nl..$nr (exit $rc: $(grep -o 'STL-CFG-.*' "$T/o" | head -c 160))"
    if [ $rc = 0 ]; then [ "$n" -gt "$nl" ] && ! cmp -s "$R4_EDIT" "$R/$R4_REL" || r4bad="$r4bad [exit 0 outside the window, or over an edit: $what]"; continue; fi
    [ "$(nlines "$T/o")" = 1 ] && ! grep -q Traceback "$T/o" && cmp -s "$R4_EDIT" "$R/$R4_REL" || { r4bad="$r4bad [not one coded line with the edit kept: $what]"; continue; }
    if grep -q "^STL-CFG-314" "$T/o" && [ "$(whole | quiet)" = "$w1" ]; then [ "$n" != "$nl" ] && continue; fi   # at the last compare the way out is followed too
    cp "$R/$R4_REL" "$T/cur.env"; way=$(grep -o '`[^`]*`' "$T/o" | head -n 1 | tr -d '`'); way=${way//<file>/$T/cur.env}
    case $way in apply\ *|rollback\ *) ap $way >/dev/null 2>&1;; esac
    ap check limits >"$T/o2" 2>&1 && cmp -s "$R4_EDIT" "$R/$R4_REL" || r4bad="$r4bad [neither 314 with the root as before, nor a way out ($way) that ends clean with the edit kept: $what]"
  done
}
r4 "$R4A" 1 apply limits --from "$C/limits.env"
r4 "$R4B" 1 rollback limits
r4 "$R4A" 3 set CALL_TIMEOUT 901
ok '[ -z "$r4bad" ] && [ $r4runs -ge 30 ]' "R4 a hand edit before every counted system call between the one read of the file and its replace (apply, rollback; through settings.py set every third site and each one of the window): the change made and the edit lost only inside the stated window, else 314 with the edit kept and the root otherwise as before, or a way out that ends with check clean ($r4runs runs, $(( $(date +%s) - r4t0 )) s):$r4bad"

# R5 a backup's state is computed from the applied state alone. Every state the applied state can say (made by the tool: pending =
# an apply killed at its line, done, rollback-pending = a rollback killed between its mark and its replace, set aside = an
# adopt) x every value the meta's status can hold (STATUSES, read from the tool, and no status at all): the forged meta changes
# no answer of check, apply, rollback or adopt (output, exit, the file, the number of event lines, check afterwards)
mkr r5pending; kill_at event apply limits --from "$C/limits.env" >/dev/null 2>&1; R5_pending=$R
mkr r5done; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; R5_done=$R
mkr r5rb; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; inproc 'sa.swap = lambda *a, **k: os.kill(os.getpid(), signal.SIGKILL)' rollback limits >/dev/null 2>&1; R5_rb=$R
ap check limits >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "STL-CFG-323.*rollback limits.*interrupted" "$T/o"' "R5 a rollback killed between its mark and its replace is reported by check (323, the command that finishes it)"
mkr r5aside; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; printf "CALL_TIMEOUT=650\nPLANTED_SETTING='h'\n" >"$R/.supervisor/limits.env"; cp "$R/.supervisor/limits.env" "$C/r5hand.env"
ap apply limits --from "$C/r5hand.env" >/dev/null 2>&1; R5_aside=$R
printf "CALL_TIMEOUT=710\nPLANTED_SETTING='c'\n" >"$C/r5c.env"
r5answers() {  # <base> <jq filter for every meta file, or nothing>: what check, apply, rollback and adopt answer, each on a copy
  local cmd m
  for cmd in "apply limits --from $C/r5c.env" "rollback limits" adopt; do
    R=$T/r5run; rm -rf "$R"; cp -a "$1" "$R"; export STELLA_ROOT=$R; LOG=$R/.supervisor/logs/events.jsonl
    [ -z "${2:-}" ] || for m in $(find "$(BK)" -name meta.json); do jq -c "$2" "$m" >"$T/m" && cat "$T/m" >"$m"; done
    ap check limits 2>&1; echo "check=$?"
    if [ "$cmd" = adopt ]; then cp "$R/.supervisor/limits.env" "$T/r5cur.env"; ap apply limits --from "$T/r5cur.env" 2>&1; else ap $cmd 2>&1; fi
    echo "$cmd=$? file=$(sha256sum <"$R/.supervisor/limits.env") lines=$(nev)"; ap check limits >/dev/null 2>&1; echo "after=$?"
  done | sed -E 's/-[0-9]{8}T[0-9]{12}Z/-TIME/g; s/[0-9a-f]{32}/TOKEN/g'
}
r5vals=$(python3 -I -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("sa", sys.argv[1]); sa = importlib.util.module_from_spec(spec); spec.loader.exec_module(sa)
print(" ".join(sa.STATUSES))' "$H/bin/stella-apply.py")
r5bad=""; r5n=0; r5t0=$(date +%s)
for st in pending done rb aside; do
  eval "base=\$R5_$st"; a0=$(r5answers "$base")
  for v in $r5vals -; do
    r5n=$((r5n+1)); f=".status = \"$v\""; [ "$v" = - ] && f='del(.status)'
    [ "$(r5answers "$base" "$f")" = "$a0" ] || r5bad="$r5bad [applied state says $st, meta forged to ${v}]"
  done
done
ok '[ -z "$r5bad" ] && [ $r5n -ge 20 ] && grep -q "check=1" <<<"$a0$(r5answers "$R5_pending")"' "R5 a forged meta status changes no answer of check, apply, rollback or adopt, for every state of the applied state and every status value ($r5n forged metas, $(( $(date +%s) - r5t0 )) s):$r5bad"
R=$T/r5run; rm -rf "$R"; cp -a "$R5_done" "$R"; export STELLA_ROOT=$R; cp "$(ST)" "$T/st.keep"
for f in '.backups.limits |= map_values(.token)' '.backups.limits |= map_values({token})'; do
  jq "$f" "$T/st.keep" >"$(ST)"; ap check limits >"$T/o1" 2>&1; r1=$?; ap rollback limits >"$T/o2" 2>&1; r2=$?
  ok '[ $r1 = 1 ] && grep -q STL-CFG-310 "$T/o1" && [ $r2 = 1 ] && grep -q STL-CFG-310 "$T/o2" && [ "$(nbk)" = 1 ]' "R5 an older record form is refused with the data-file code (310), the backup kept: $f (W3-CV5-10)"
done

# R2 "no committed baseline" only for a proven fact. A git that answers each exit status with a foreign text (a stub first on
# PATH), and a real git on a repository it cannot use: check, a dry run, apply and rollback each refuse, naming the baseline
mkr r2; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; printf '# hand\n' >>"$R/config/owner.env"; R2=$R   # a committed, never-applied file edited by hand
r2bad=""; r2n=0
r2() {  # <name> <what breaks git, run in a copy of the root>...
  local name=$1 cmd w0; shift
  R=$T/r2run; chmod -R u+rwx "$R" 2>/dev/null; rm -rf "$R" "$T/r2away"; cp -a "$R2" "$R"; export STELLA_ROOT=$R; G=$OWNER; "$@"; w0=$(whole | quiet)
  for cmd in "check owner-settings" "apply owner-settings --from $C/owner.env --dry-run" "apply owner-settings --from $C/owner.env" "rollback limits"; do
    r2n=$((r2n+1)); PATH=$PB:$G $AP $cmd >"$T/o" 2>&1
    [ $? = 1 ] && [ "$(grep -c '^STL-CFG-3[12][23].*git status.*baseline cannot be read' "$T/o")" = 1 ] && ! grep -q Traceback "$T/o" || r2bad="$r2bad [$name: $cmd: $(head -c 140 "$T/o")]"
  done
  [ "$(whole | quiet)" = "$w0" ] || r2bad="$r2bad [$name: the root changed]"
}
stub() { mkdir -p "$T/g$1"; printf '#!/bin/sh\necho "fatale: kein Git-Repository, objet introuvable" >&2\nexit %s\n' "$1" >"$T/g$1/git"; chmod +x "$T/g$1/git"; G=$T/g$1:$OWNER; }
obj() { local o; o=$(git -C "$R" rev-parse "$1"); rm -f "$R/.git/objects/${o:0:2}/${o:2}"; }
for s in 1 2 127 128 129 255; do r2 "a git that exits $s" stub $s; done
r2link() { mv "$R/.git" "$T/r2away"; echo "gitdir: $T/r2-no-such/.git/worktrees/x" >"$R/.git"; }
r2head() { : >"$R/.git/HEAD"; }; r2mode() { chmod 000 "$R/.git"; }; r2ref() { echo garbage >"$R/.git/$(git -C "$R" symbolic-ref HEAD)"; }
r2 "a worktree link to a missing folder" r2link; r2 "an empty HEAD" r2head; r2 "a .git with mode 000" r2mode; r2 "a branch ref that is not a commit id" r2ref
r2 "a missing commit object" obj HEAD; r2 "a missing tree object" obj 'HEAD^{tree}'
ok '[ -z "$r2bad" ] && [ $r2n = 48 ]' "R2 a git that cannot answer is never 'no baseline': check, a dry run, apply and rollback refuse with one line naming the baseline, the root as it was, for 6 exit statuses of a foreign-language git and 6 damaged layouts ($r2n runs):$r2bad"
chmod -R u+rwx "$T/r2run"; rm -rf "$T/r2run"; cp -a "$R2" "$T/r2run"; R=$T/r2run; export STELLA_ROOT=$R; obj HEAD:config/owner.env
ap check owner-settings >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q "baseline cannot be read" "$T/o"' "R2 a missing blob of a path HEAD lists: refused (the path is committed, its bytes cannot be read)"
ap check limits --json >"$T/o" 2>&1; ok 'jq -e ".ok" "$T/o" >/dev/null' "R2 control: with HEAD a commit and git's exit 0 listing no entry, an applied untracked file needs no baseline"
rm -rf "$R/.git"; ap check owner-settings --json >"$T/o" 2>&1; ok 'jq -e ".ok and .files[0].state == \"no_baseline\"" "$T/o" >/dev/null' "R2 the first proven fact: a root with no .git entry at all has nothing committed (no baseline, exit 0)"
git -C "$R" init -q 2>/dev/null; ap check owner-settings --json >"$T/o" 2>&1; r1=$?; ap apply owner-settings --from "$C/owner.env" >"$T/o2" 2>&1; r2=$?
ok '[ $r1 = 0 ] && jq -e ".files[0].state == \"no_baseline\"" "$T/o" >/dev/null && [ $r2 = 0 ]' "R2 a repository with no commit yet (HEAD a symbolic ref that resolves to nothing, by exit status) has nothing committed: no baseline, and apply works"

# R3 a candidate may not add a problem to the set. For each pair of shipped json rows (A changed, B already holding one
# problem), with the whole-set check's two answers given: a new line in B refuses and names B; no new line applies; a line of B
# that only reworded itself refuses with the same way out (the accepted false refusal); B without an old problem: plainly invalid
python3 -I -c '
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("sa", sys.argv[1]); sa = importlib.util.module_from_spec(spec); spec.loader.exec_module(sa)
sa.context(); rows, bad, n = [r for r in sa.sd.rows() if r["format"] == "json"], [], 0
def run(a, base, after):
    sa.problems = lambda rel, data: set(after if data is not None else base)
    rel, data = (a["path"] + "/qa.json", b"{}") if sa.folder_row(a) else (a["path"], open(os.path.join(sa.el.ROOT, a["path"]), "rb").read())
    try:
        sa.validate(a, rel, data); return None
    except sa.EventError as e:
        return e.problem
for a in rows:
    for b in rows:
        if a["id"] == b["id"]: continue
        n += 1; old, new = (b["id"], "an old problem line"), (b["id"], "a new problem line")
        r = [run(a, {old}, {old, new}), run(a, {old}, {old}), run(a, {old}, {(b["id"], "an old problem line, reworded")}), run(a, set(), {new})]
        way = "fix " + b["id"] + " first"
        if not (r[0] and r[0].startswith(way) and "already had a problem" in r[0] and r[1] is None and r[2] and r[2].startswith(way)
                and r[3] and r[3].startswith("the candidate is invalid: " + b["id"]) and all(len(x) <= 200 for x in r if x)):
            bad.append((a["id"], b["id"], r))
print(n, "pairs", bad[:2]); sys.exit(1 if bad or n < 20 else 0)' "$H/bin/stella-apply.py" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ]' "R3 for every pair of shipped json rows: a candidate that adds a problem line to a row that already had one is refused naming that row and the way out, one that adds none passes, a reworded line is refused the same way: $(tail -n 1 "$T/o" | head -c 300)"
mkr r3; jq '.assignments += [.assignments[0] | .id = "r3-twin"]' "$R/.stella/role-assignments.json" >"$T/x" && cp "$T/x" "$R/.stella/role-assignments.json"; git -C "$R" commit -qam old-problem
jq '.entries[0].enabled = false' "$R/.stella/connections.json" >"$C/r3off.json"; p0=$(python3 -I "$H/bin/stella_data.py" check --json 2>/dev/null | jq '.problems | length')
ap apply connections --from "$C/r3off.json" >"$T/o" 2>&1; rc=$?; ap apply connections --from "$C/r3off.json" --dry-run >"$T/o2" 2>&1; r2=$?
ok '[ "$p0" = 1 ] && [ $rc = 1 ] && [ $r2 = 1 ] && grep -q "STL-CFG-313.*fix role-assignments first.*already had a problem" "$T/o" && grep -q "fix role-assignments first" "$T/o2" && cmp -s "$T/conn.orig" "$R/.stella/connections.json"' "R3 by use: one old problem in the role assignments does not hide the new ones a catalog candidate adds there (apply and its dry run refuse, naming that row; W3-CRT5-03; exit $rc $r2, $p0 problem before: $(head -c 220 "$T/o"))"
jq '.pins[0].version = "9.9.9"' "$R/.stella/versions.json" >"$C/r3v.json"
ap apply versions --from "$C/r3v.json" >"$T/o" 2>&1; ok '[ $? = 0 ]' "R3 and a candidate that adds no problem line is still applied on that set"

# R6 the Low ones
mkr r6a; chmod 2640 "$R/.supervisor/limits.env"; ap apply limits --from "$C/limits.env" --dry-run >"$T/o" 2>&1; r1=$?; ap apply limits --from "$C/limits.env" >"$T/o2" 2>&1; r2=$?
ok '[ $r1 = 1 ] && [ $r2 = 1 ] && grep -q "STL-CFG-313.*chmod 640" "$T/o" && [ "$(grep -o "STL-CFG.*" "$T/o")" = "$(grep -o "STL-CFG.*" "$T/o2")" ]' "R6 the dry run makes the mode refusal the apply makes, word for word (W3-CV5-06)"
chmod 640 "$R/.supervisor/limits.env"; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; jq '.counter = 99999999' "$(ST)" >"$T/x" && cp "$T/x" "$(ST)"
ap apply limits --from "$C/r5c.env" --dry-run >"$T/o" 2>&1; r1=$?; ap apply limits --from "$C/r5c.env" >"$T/o2" 2>&1; r2=$?
ok '[ $r1 = 1 ] && [ $r2 = 1 ] && grep -q "STL-CFG-313.*it is full" "$T/o" && [ "$(grep -o "STL-CFG.*" "$T/o")" = "$(grep -o "STL-CFG.*" "$T/o2")" ]' "R6 and the full-counter refusal"
mkr r6b; n41=$(head -c 41 /dev/zero | tr '\0' a); jq --arg i "$n41" '.id = $i' "$C/fake-ext.json" >"$R/.stella/extensions/$n41.json"; git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm long
ap check >"$T/o" 2>&1; r1=$?; ap history "extensions/$n41.json" >"$T/o2" 2>&1; r2=$?; jq '.summary = "changed"' "$R/.stella/extensions/$n41.json" >"$C/r6b.json"; ap apply "extensions/$n41.json" --from "$C/r6b.json" >"$T/o3" 2>&1; r3=$?
ok '[ $r1 = 0 ] && [ $r2 = 0 ] && [ $r3 = 0 ]' "R6 check and history read a committed entry with a name of 46 characters, as the data tool does (W3-CRT5-04), and since the owner dropped the limit an apply changes it too ($r1 $r2 $r3: $(head -c 200 "$T/o3"))"
mkr r6c; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; long=$(head -c 200 /dev/zero | tr '\0' n); mkdir "$(BK)/limits/zzz"
ap check limits >"$T/o" 2>&1; mv "$(BK)/limits/zzz" "$(BK)/limits/$long"; ap rollback limits >"$T/o2" 2>&1
ok 'grep -q "STL-CFG-316.*\.supervisor/state/backups/limits/zzz.*remove it by hand.*own saved copy" "$T/o" && grep -q "^STL-CFG-316" "$T/o2" && grep "^whole text: " "$T/o2" | grep -qF ".supervisor/state/backups/limits/$long, then remove it by hand" && [ -d "$(BK)/limits/$long" ]' "R6 the 316 line for an unrecorded folder gives its path whole and keeps its way out whatever the name's length (a long one on the whole-text line), and says it may be the tool's own saved copy (W3-CRT5-05)"
mkr r6d; printf 'CALL_TIMEOUT=600\nnot a settings line\n' >"$R/.supervisor/limits.env"; ap apply limits --from "$C/limits.env" >/dev/null 2>&1; ap rollback limits >/dev/null 2>&1
ok 'jq -es ".[0].old == {\"unparsed\": true} and .[1].new == {\"unparsed\": true} and (.[1].detail | test(\"does not parse\"))" "$LOG" >/dev/null && [ -f "$R/.supervisor/limits.env" ]' "R6 a side of an event line whose file exists and does not parse says so; null is only: no file (W3-RT5-05)"
mkr r6e; python3 -c 'import os, subprocess, sys
r, w = os.pipe(); os.close(r)
p = subprocess.run(sys.argv[1:], stdout=w, stderr=subprocess.PIPE, text=True); print(p.returncode); print(p.stderr.strip()[:200])' env PATH="$PB:$OWNER" $AP apply limits --from "$C/limits.env" >"$T/o" 2>&1
ok '[ "$(head -n 1 "$T/o")" = 0 ] && ap check limits >/dev/null 2>&1 && [ "$(nev)" = 1 ]' "R6 a line that cannot be printed (a closed stdout) does not turn a finished change into exit 120: $(head -c 120 "$T/o") (W3-CRT5-08)"
mkr r6f; inproc 'r0, hit, once = sa.set_applied, [], []
def s(*a, **k):
    r0(*a, **k)
    if not once:
        once.append(1); raise OSError(5, "qa")
sa.set_applied = s
real = sa.failed
def f(*a):
    if not hit:
        hit.append(1); os.kill(os.getpid(), signal.SIGTERM)
        for _ in range(1000): pass
    return real(*a)
sa.failed = f' apply limits --from "$C/limits.env" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && [ "$(nlines "$T/o")" = 1 ] && ! grep -q Traceback "$T/o" && grep -q "was undone" "$T/o" && ap check limits >/dev/null 2>&1' "R6 SIGTERM between the catch of a failure and the failure handler: one coded line, the undo done, no traceback (W3-CRT5-07)"
mkr r6g; mkdir -p "$(BK)/limits/.gone-keep"; echo precious >"$(BK)/limits/.gone-keep/data"; ap apply limits --from "$C/limits.env" >/dev/null 2>&1
ok '[ "$(cat "$(BK)/limits/.gone-keep/data")" = precious ]' "R6 a folder that only starts like a set-aside backup is not the tool's and is kept (the one shape; W3-RT5-03)"
mkr r6h; jq --argjson d "$(jq -c '.files[]|select(.id=="limits")|.id="qa-env"|.path="qa-gone/qa.env"|.owner_only=false' "$R/.stella/data-files.json")" '.files += [$d]' "$R/.stella/data-files.json" >"$T/x" && cp "$T/x" "$R/.stella/data-files.json"
ap check qa-env >"$T/o" 2>&1; ok '[ $? = 1 ] && [ "$(grep -c "STL-CFG-310.*mkdir -p qa-gone" "$T/o")" = 1 ]' "R6 check gives one coded line for a one-file row whose folder is missing, with the mkdir, as apply does (B6)"

# Part C (owner decision of 2026-11-12): no name limit of the tool's; the file system's own limit refuses, coded, before any write;
# no printed path or command is cut (a text the catalog would cut follows its coded line whole)
mkr c1; n200=$(head -c 195 /dev/zero | tr '\0' n).json; k=extensions/$n200; f=$R/.stella/$k
jq '.summary = "one"' "$C/fake-ext.json" >"$C/c1a.json"; jq '.summary = "two"' "$C/fake-ext.json" >"$C/c1b.json"; jq '.summary = "by hand"' "$C/fake-ext.json" >"$C/c1c.json"
ap apply "$k" --from "$C/c1a.json" >"$T/o" 2>&1; r1=$?; ap apply "$k" --from "$C/c1b.json" >"$T/o" 2>&1; r2=$?; ap check "$k" >"$T/o2" 2>&1; r3=$?
ok '[ $r1 = 0 ] && [ $r2 = 0 ] && [ $r3 = 0 ] && grep -qF "$n200" "$T/o" && cmp -s "$C/c1b.json" "$f"' "C an entry name of 200 characters is applied twice and checks clean, its key printed whole ($r1 $r2 $r3: $(head -c 120 "$T/o2"))"
cp "$C/c1c.json" "$f"; ap check "$k" >"$T/o" 2>&1; r1=$?; ap rollback "$k" >"$T/o2" 2>&1; r2=$?
ok '[ $r1 = 1 ] && [ $r2 = 1 ] && grep -q "^STL-CFG-314" "$T/o" && grep -q "^STL-CFG-314" "$T/o2" && grep -qF "whole text: " "$T/o" && grep -F "whole text: " "$T/o2" | grep -qF "\`apply $k --from <file>\`" && cmp -s "$C/c1c.json" "$f"' "C a hand edit of it: check and rollback give the coded line and, after it, the whole way out with the whole key on one line ($r1 $r2, $(grep -c . "$T/o2") lines)"
cp "$C/c1b.json" "$f"; ap rollback "$k" >"$T/o" 2>&1; r1=$?; ap check "$k" >"$T/o2" 2>&1
ok '[ $r1 = 0 ] && [ $? = 0 ] && cmp -s "$C/c1a.json" "$f" && grep -qF "$n200" "$T/o"' "C and rollback restores it, check clean ($r1: $(head -c 80 "$T/o"))"
mkdir "$(BK)/$k/qa-planted"; ap apply "$k" --from "$C/c1b.json" >"$T/o" 2>&1
ok '[ $? = 1 ] && grep -q "^STL-CFG-316" "$T/o" && grep -F "whole text: " "$T/o" | grep -qF "$(BK | sed "s|$R/||")/$k/qa-planted"' "C the line for an unrecorded folder under a long name gives its whole path on the line after the coded one"
rmdir "$(BK)/$k/qa-planted"
for n in "$(head -c 250 /dev/zero | tr '\0' m).json" "$(head -c 249 /dev/zero | tr '\0' m).json"; do   # 255 bytes: the longest name the file system takes
  jq --arg i "c-${#n}" '.id = $i' "$C/c1a.json" >"$C/c1n.json"; ap apply "extensions/$n" --from "$C/c1n.json" >"$T/o" 2>&1; r1=$?; ap rollback "extensions/$n" >"$T/o2" 2>&1
  ok '[ $r1 = 0 ] && [ $? = 0 ] && [ ! -e "$R/.stella/extensions/$n" ]' "C a name of ${#n} bytes, which the file system allows, is applied and rolled back (its lock file has a name that fits): $(head -c 150 "$T/o")"
done
n300=$(head -c 295 /dev/zero | tr '\0' x).json; w0=$(whole)
for c in "apply extensions/$n300 --from $C/c1a.json" "apply extensions/$n300 --from $C/c1a.json --dry-run" "rollback extensions/$n300" "check extensions/$n300" "history extensions/$n300"; do
  ap $c >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && [ "$(grep -c "^STL-CFG-3" "$T/o")" = 1 ] && [ "$(grep -vc "^STL-CFG-3\|^whole text: " "$T/o")" = 0 ] && grep -q "shorter name.*255 bytes" "$T/o" && ! grep -q Traceback "$T/o" && [ "$(whole)" = "$w0" ]' "C a name of 300 characters, which the file system refuses, is refused before any write with one coded line (and its whole text where the name makes it longer than the catalog's cut), the root byte-identical: ${c%% *} ($rc: $(head -c 160 "$T/o"))"
done

$AP bogus >/dev/null 2>&1; ok '[ $? = 2 ]' "usage error exits 2"
[ $fails = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
