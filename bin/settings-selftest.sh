#!/usr/bin/env bash
# Hermetic self-test for bin/settings.py (F1 W4, the owner's settings commands). Everything runs in a scratch root (STELLA_ROOT: a
# copy of .stella/, the role table, a FAKE env-format owner file and a fake limits file); never the real owner settings.
# A6 the owner path: one setting set through the apply contract leaves exactly one event line (who / what / old / new) and rollback
# restores the file byte-identical; a second identical set is a no-op; an invalid value (STL-CFG-315) and a secret entry are refused
# and change nothing (a secret's value appears nowhere); an identity-critical entry needs the phrase from the owner-auth policy
# typed on a real terminal (a pseudo-terminal here; none, a wrong phrase or the key name typed back = STL-OWN-808, F1c W4b); a
# simulated worker (marker variable, a running card on the board, an unreadable board) is refused (STL-CFG-312); an unknown key is
# STL-CFG-311 with one alert line; values with quotes, spaces and $ are written in the canonical form and read back unchanged.
# F1c W4b (the owner proof, cases of qa T3b/T4a/T8a): every worker signal of bin/worker_env.py refuses first, even with a valid proof,
# which stays unspent; no owner key = STL-OWN-806; --dry-run prints the action; --proof replaces the host key (replay 804, another
# action 805); the event line names the providers used; the phrase is data; an identity_critical alternative met by a --proof alone
# (a command provider standing in for a paired device) needs no terminal.
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d -t settings-selftest.XXXXXX); trap 'rm -rf "$T"' EXIT
R=$T/root; mkdir -p "$R/docs/hermes-local" "$R/config" "$R/.supervisor/logs" "$T/sup/logs"
cp -r "$H/.stella" "$R/"
jq '.worker_markers = ["STUB_WORKER_MARK"]' "$H/docs/hermes-local/roles.json" >"$R/docs/hermes-local/roles.json"
cp -r "$H/docs/hermes-local/hooks" "$R/docs/hermes-local/hooks"   # the table check looks hook files up under the root
# a planted secret entry whose value lives in the fake owner file; the test greps for it everywhere
jq --arg g "$(python3 -I -c "import uuid; print(uuid.uuid4())")" '.entries += [(.entries[2] | .global_id = $g | .key = "PLANTED_SECRET" | .sensitivity = "secret" | .type = "string" | .validation = {} | .default = null | .store = {data: "owner-settings", key: "PLANTED_SECRET"})]' \
  "$R/.stella/settings.json" >"$T/s" && mv "$T/s" "$R/.stella/settings.json"
printf "# fake owner file\nWORKER_GIT_NAME='Fake One'\nWORKER_GIT_EMAIL='fake@example.invalid'\nPLANTED_SECRET='sekrit-owner-111'\n" >"$R/config/owner.env"
printf "CALL_TIMEOUT=600\n" >"$R/.supervisor/limits.env"
chmod 600 "$R/config/owner.env"; chmod 640 "$R/.supervisor/limits.env"
export STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup
export OWNER_CONFIG="$T/unused-owner.env"   # a consumer never falls back to the real owner file
unset STUB_WORKER_MARK
for v in $(jq -r '.worker_signals.token_env[]' "$R/.stella/owner-auth.json"); do unset "$v"; done   # an agent token of the caller is a worker signal
ALERTS=$T/sup/logs/alerts.log; LOG=$R/.supervisor/logs/events.jsonl
ST="python3 -I $H/bin/settings.py"; AP="python3 -I $H/bin/stella-apply.py"
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/o" ] && sed 's/^/     /' "$T/o" | tail -3; fi; }
nev() { [ -f "$LOG" ] && wc -l <"$LOG" || echo 0; }
nal() { [ -f "$ALERTS" ] && wc -l <"$ALERTS" || echo 0; }
snap() { (cd "$R" && sha256sum config/owner.env .supervisor/limits.env .stella/settings.json; stat -c '%a' config/owner.env .supervisor/limits.env); }
# stub boards: ok = no running card (not a worker); down = unreadable; worker = a running card bound to this script's own process
fp() { echo "$(cat /proc/sys/kernel/random/boot_id):$(sed 's/.*) //' /proc/1/stat | awk '{print $20}')|$(sed 's/.*) //' /proc/$1/stat | awk '{print $20}')"; }
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
OWNER=$PATH; PB=$T/pb-ok
# st: the owner, with no terminal at all (setsid, stdin closed); pt: the owner on a pseudo-terminal that types $PHRASE
st() { PATH=$PB:$OWNER setsid -w $ST "$@" </dev/null; }
cat >"$T/pty.py" <<'PY'
import os, pty, select, sys
phrase, cmd = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
buf, sent = b"", False
while True:
    r, _, _ = select.select([fd], [], [], 20)
    if not r:
        break
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    buf += d
    if not sent and b"confirm" in buf:
        os.write(fd, phrase.encode() + b"\n"); sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(buf.decode(errors="replace"))
sys.exit(os.waitstatus_to_exitcode(status))
PY
pt() { PATH=$PB:$OWNER python3 -I "$T/pty.py" "$PHRASE" python3 -I "$H/bin/settings.py" "$@"; }
ptap() { PATH=$PB:$OWNER python3 -I "$T/pty.py" "$PHRASE" python3 -I "$H/bin/stella-apply.py" "$@"; }   # the apply tool on a terminal
OA="python3 -I $H/bin/owner_auth.py"; POL=$R/.stella/owner-auth.json; KEY=$R/$(jq -r .owner_key "$R/.stella/data-files.json")
phr() { jq -r --arg w "$1" '.phrase.template | gsub("\\{what\\}"; $w)' "$POL"; }   # the confirmation phrase of a change of row $1 (data)
PATH=$PB:$OWNER $OA init-key >/dev/null 2>&1   # the owner key of the scratch root: an owner-only change needs an owner proof (F1c W4b)
PHR=$(phr owner-settings)

ok '[ -x "$H/bin/settings.py" ]' "bin/settings.py exists and is executable"
ok 'o=$(python3 -I $H/bin/stella_data.py check) && [ "$(echo "$o" | head -1)" = "data OK" ]' "the scratch root validates (role table with the owner lists, settings registry)"
B=$(snap)

# the owner path: identity-critical, typed phrase on a terminal, one event, rollback byte-identical
cp -p "$R/config/owner.env" "$T/owner.orig"; e0=$(nev)
PHRASE=$PHR pt set WORKER_GIT_NAME "New Name" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "^WORKER_GIT_NAME='"'"'New Name'"'"'$" "$R/config/owner.env" && grep -q "^PLANTED_SECRET=" "$R/config/owner.env"' "A6 owner on a terminal with the right phrase: the setting is applied, the other lines are kept"
ok '[ "$(nev)" = $((e0+1)) ] && tail -1 "$LOG" | jq -e ".type == \"apply\" and .what == \"owner-settings\" and (.who.user | type == \"string\") and .old.WORKER_GIT_NAME == \"Fake One\" and .new.WORKER_GIT_NAME == \"New Name\"" >/dev/null' "A6 exactly one event line: who / what / old / new"
ok '! grep -rq sekrit-owner-111 "$LOG" "$T/sup" "$T/o"' "A6 the planted secret is in no event line, alert line or output"
PHRASE=$PHR ptap rollback owner-settings >"$T/o" 2>&1
ok 'cmp -s "$R/config/owner.env" "$T/owner.orig" && [ "$(stat -c %a "$R/config/owner.env")" = 600 ] && [ "$(snap)" = "$B" ]' "A6 rollback restores the file byte-identical (content and mode)"
ok '[ "$(nev)" = $((e0+2)) ] && tail -1 "$LOG" | jq -e ".type == \"rollback\"" >/dev/null' "A6 the rollback leaves one more event line"

# a second identical set is a no-op
PHRASE=$PHR pt set WORKER_GIT_NAME "New Name" >"$T/o" 2>&1; e1=$(nev); b1=$(snap)
PHRASE=$PHR pt set WORKER_GIT_NAME "New Name" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "no change" "$T/o" && [ "$(nev)" = "$e1" ] && [ "$(snap)" = "$b1" ]' "A6 a second identical set: exit 0, no change, no new event line"
PHRASE=$PHR ptap rollback owner-settings >/dev/null 2>&1; B=$(snap)

# identity-critical: no terminal, wrong phrase
e0=$(nev); a0=$(nal)
st set WORKER_GIT_NAME "Nobody" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-OWN-808 "$T/o" && [ "$(snap)" = "$B" ] && [ "$(nev)" = "$e0" ]' "an identity-critical entry with no terminal: STL-OWN-808, nothing changed"
PHRASE=nope pt set WORKER_GIT_NAME "Nobody" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-OWN-808 "$T/o" && [ "$(snap)" = "$B" ] && [ "$(nev)" = "$e0" ]' "an identity-critical entry with the wrong phrase on a terminal: STL-OWN-808, nothing changed"
PHRASE=WORKER_GIT_NAME pt set WORKER_GIT_NAME "Nobody" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-OWN-808 "$T/o" && [ "$(snap)" = "$B" ] && [ "$(nev)" = "$e0" ]' "W4b the old confirmation (the key name typed back) no longer passes: STL-OWN-808, nothing changed"
st set WORKER_GIT_NAME "Nobody" --dry-run >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "^[-+]" "$T/o" && [ "$(snap)" = "$B" ] && [ "$(nev)" = "$e0" ]' "--dry-run prints a diff, needs no terminal, changes nothing"

# a plain setting: no terminal needed; a canonical value with quotes, $ and non-ASCII reads back unchanged
st set CALL_TIMEOUT 900 >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "^CALL_TIMEOUT='"'"'900'"'"'$" "$R/.supervisor/limits.env" && [ "$(nev)" = $((e0+1)) ]' "a plain integer setting is applied with no terminal, one event line"
st set CALL_TIMEOUT 900 >"$T/o" 2>&1
ok '[ $? = 0 ] && grep -q "no change" "$T/o" && [ "$(nev)" = $((e0+1))  ]' "setting the same plain value again: no change"
PATH=$PB:$OWNER $AP rollback limits >/dev/null 2>&1
ok 'grep -qx "CALL_TIMEOUT=600" "$R/.supervisor/limits.env"' "rollback of the plain setting restores the original line"
B=$(snap); e0=$(nev); a0=$(nal)
for v in abc -1 100001 "" 1.5 "0x10"; do
  st set CALL_TIMEOUT "$v" >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && grep -q STL-CFG-315 "$T/o" && [ "$(snap)" = "$B" ] && [ "$(nev)" = "$e0" ]' "an invalid value for an integer setting ($v) is refused with STL-CFG-315, nothing changed"
done
st set WORKER_GIT_NAME "a'b \$HOME" --dry-run >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-315 "$T/o" && [ "$(snap)" = "$B" ]' "a value the strict owner file format cannot hold (single quote together with \$) is refused, nothing changed"
PHRASE=$PHR pt set WORKER_GIT_NAME "O'Brien #1 = Zoë  (x)" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && v=$(OWNER_CONFIG=$R/config/owner.env python3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); import owner_config as o; print(o._parse()[1][\"WORKER_GIT_NAME\"], end=\"\")" "$H/bin") && [ "$v" = "O'"'"'Brien #1 = Zoë  (x)" ]' "a value with a quote, #, =, spaces and non-ASCII text is written canonically and parsed back unchanged"
PHRASE=$PHR ptap rollback owner-settings >/dev/null 2>&1; B=$(snap)

# a secret entry: refused, the value is nowhere
a0=$(nal); e0=$(nev)
st set PLANTED_SECRET sekrit-new-222 >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-315 "$T/o" && [ "$(snap)" = "$B" ] && [ "$(nev)" = "$e0" ] && ! grep -rq "sekrit-new-222\|sekrit-owner-111" "$T/o" "$T/sup" "$LOG"' "a secret entry is refused, nothing changed, neither value appears in any output, alert line or event"
st get PLANTED_SECRET >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ "$(cat "$T/o")" = "***" ]' "get prints *** for a secret"
st get PLANTED_SECRET --json >"$T/o" 2>&1
ok 'jq -e ".value == \"***\"" "$T/o" >/dev/null && ! grep -q sekrit-owner-111 "$T/o"' "get --json shows *** for a secret too"
st list --json >"$T/o" 2>&1
ok 'jq -e "[.[].key] | index(\"PLANTED_SECRET\") != null and index(\"WORKER_GIT_NAME\") != null" "$T/o" >/dev/null && ! grep -q sekrit "$T/o"' "list --json lists every registry entry and holds no secret"

# get, check
st get WORKER_GIT_NAME >"$T/o" 2>&1; ok '[ $? = 0 ] && [ "$(cat "$T/o")" = "Fake One" ]' "get prints the stored value"
st get CALL_TIMEOUT --json >"$T/o" 2>&1; ok 'jq -e ".value == 600 and .key == \"CALL_TIMEOUT\"" "$T/o" >/dev/null' "get --json types an integer"
st check >"$T/o" 2>&1; ok '[ $? = 0 ]' "check passes on the scratch root"
st check --json >"$T/o" 2>&1; ok 'jq -e ".ok == true" "$T/o" >/dev/null' "check --json: ok"
printf "CALL_TIMEOUT=abc\n" >"$R/.supervisor/limits.env"
st check --json >"$T/o" 2>&1; rc=$?; ok '[ $rc = 1 ] && jq -e ".ok == false and (.problems[0].code == \"STL-CFG-315\")" "$T/o" >/dev/null' "check finds a stored value that breaks its entry (STL-CFG-315)"
printf "CALL_TIMEOUT=600\n" >"$R/.supervisor/limits.env"; chmod 640 "$R/.supervisor/limits.env"; B=$(snap)

# unknown key: one alert line
a0=$(nal)
st get NO_SUCH_KEY >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-311 "$T/o" && [ "$(nal)" = $((a0+1)) ]' "get of an unknown key: exit 1, STL-CFG-311, exactly one alert line"
a0=$(nal); st set NO_SUCH_KEY 1 >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-311 "$T/o" && [ "$(nal)" = $((a0+1)) ] && [ "$(snap)" = "$B" ]' "set of an unknown key: exit 1, STL-CFG-311, exactly one alert line, nothing changed"

# a simulated worker: set refused, get of an owner file refused (a marker variable, a running card on the board, an unreadable board)
for who in marker board-worker board-down; do
  case $who in marker) PB=$T/pb-ok; export STUB_WORKER_MARK=1;; board-worker) PB=$T/pb-worker;; board-down) PB=$T/pb-down;; esac
  e0=$(nev)
  st set CALL_TIMEOUT 900 >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && grep -q STL-CFG-312 "$T/o" && [ "$(snap)" = "$B" ] && [ "$(nev)" = "$e0" ]' "a simulated worker ($who): set refused with STL-CFG-312, nothing changed"
  st set WORKER_GIT_NAME x --dry-run >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && grep -q STL-CFG-312 "$T/o"' "a simulated worker ($who): even a dry run of set is refused"
  st get WORKER_GIT_NAME >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && grep -q STL-CFG-312 "$T/o" && ! grep -q "Fake One" "$T/o"' "a simulated worker ($who): get of a value in an owner settings file is refused, the value is not shown"
  unset STUB_WORKER_MARK
done
PB=$T/pb-ok
jq 'del(.worker_markers)' "$R/docs/hermes-local/roles.json" >"$T/r" && cp "$R/docs/hermes-local/roles.json" "$T/roles.keep" && cp "$T/r" "$R/docs/hermes-local/roles.json"
st set CALL_TIMEOUT 900 >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-CFG-312 "$T/o" && [ "$(snap)" = "$B" ]' "no worker_markers in the role table: set fails closed (STL-CFG-312)"
cp "$T/roles.keep" "$R/docs/hermes-local/roles.json"

# G5 (W4-VER-09): a store file that holds a key twice is refused with a coded message before anything is compared or written: "no change" is never
# said for a file the apply tool would refuse
cp "$R/config/owner.env" "$T/owner.keep"; printf "WORKER_GIT_NAME='Second One'\n" >>"$R/config/owner.env"; B2=$(snap); e0=$(nev)
st set WORKER_GIT_NAME 'Second One' >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-313 "$T/o" && grep -q "twice" "$T/o" && ! grep -q "no change" "$T/o" && [ "$(snap)" = "$B2" ] && [ "$(nev)" = "$e0" ]' "G5: set on a store file that holds a key twice: STL-CFG-313, never 'no change', nothing written"
st get WORKER_GIT_NAME >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-313 "$T/o" && ! grep -q "Second One\|Fake One" "$T/o"' "G5: get on it is refused the same way and shows no value"
cp "$T/owner.keep" "$R/config/owner.env"; chmod 600 "$R/config/owner.env"
ok '[ "$(snap)" = "$B" ]' "G5: the fixture is back as it was"


# F1 W4 round 3 (K9): the read, the candidate and the apply are one critical section; get serves no default the entry refuses; a store read that fails is not "a change failed"
LIM=$R/.supervisor/limits.env; lim() { sed -n "s/^$1=//p" "$LIM" | tr -d "'"; }   # the store writes the quoted form KEY='701' (owner_config.line)
printf "CALL_TIMEOUT=600\nQUEUE_MAX=1\n" >"$LIM"; lost=0
for i in 1 2 3 4 5; do
  e0=$(nev); st set CALL_TIMEOUT $((700+i)) >"$T/c1a" 2>&1 & a=$!; st set QUEUE_MAX $((10+i)) >"$T/c1b" 2>&1 & b=$!; wait $a; ra=$?; wait $b; rb=$?
  { [ "$ra" = 0 ] && [ "$rb" = 0 ] && [ "$(lim CALL_TIMEOUT)" = $((700+i)) ] && [ "$(lim QUEUE_MAX)" = $((10+i)) ] && [ "$(nev)" = $((e0+2)) ]; } || lost=$((lost+1))
done
ok '[ $lost = 0 ]' "K9: two sets of two keys of one store file at once both land, both say applied, one event line each ($lost bad rounds of 5)"
printf "CALL_TIMEOUT=600\nCALL_TIMEOUT=601\n" >"$LIM"
st get CALL_TIMEOUT >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q "STL-CFG-313" "$T/o" && grep -q "twice" "$T/o"' "K9: get on a store that holds a key twice is refused with the code set uses (G5: refused the same way), and says why"
printf "CALL_TIMEOUT=600\nQUEUE_MAX=1\n" >"$LIM"; cp "$R/.stella/settings.json" "$T/settings.keep"
jq '(.entries[] | select(.key == "CALL_TIMEOUT") | .default) = "not a number"' "$T/settings.keep" >"$R/.stella/settings.json"; sed -i '/^CALL_TIMEOUT=/d' "$LIM"
st get CALL_TIMEOUT >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q "STL-CFG-310" "$T/o"' "K9: get serves no default value that the entry's own rules refuse"
cp "$T/settings.keep" "$R/.stella/settings.json"; printf "CALL_TIMEOUT=600\nQUEUE_MAX=1\n" >"$LIM"
# F1c W4b (qa T3b, T4a, T8a settings part): the owner proof of a settings change
OKP=$(jq -r '[.providers[] | select(.kind == "local-key") | .id][0]' "$POL"); TPP=$(jq -r '[.providers[] | select(.kind == "typed-phrase") | .id][0]' "$POL")
printf "CALL_TIMEOUT=600\n" >"$LIM"; chmod 640 "$LIM"; B=$(snap); e0=$(nev)
st set CALL_TIMEOUT 777 --dry-run >"$T/o" 2>&1; rc=$?; sed -n 's/^action: //p' "$T/o" >"$T/act.json"
ok '[ $rc = 0 ] && jq -e ".op == \"apply\" and .target == \"limits\" and (.old_digest | length) == 64 and (.new_digest | length) == 64" "$T/act.json" >/dev/null && [ "$(snap)" = "$B" ] && [ "$(nev)" = "$e0" ]' "W4b set --dry-run prints the action a proof must cover (action: {...}), nothing changed"
PATH=$PB:$OWNER $OA prove --class owner_write --action "$T/act.json" >"$T/p.json" 2>/dev/null
cp "$POL" "$T/pol.keep"; TOK=$(jq -r '.worker_signals.token_env[0]' "$POL"); WT=$R/$(jq -r '.worker_signals.worktree_dirs[0]' "$POL")/card-1; mkdir -p "$WT"
for sig in marker token sandbox worktree policy-unreadable; do
  cwd=$T; envs=(ZZ_NOTHING=1)
  case $sig in
    marker) envs=(STUB_WORKER_MARK=1);;
    token) envs=("$TOK=t0k-planted");;
    sandbox) : >"$T/sbx"; jq --arg f "$T/sbx" '.worker_signals.sandbox_files += [$f]' "$T/pol.keep" >"$POL";;
    worktree) cwd=$WT;;
    policy-unreadable) printf '{not json' >"$POL";;
  esac
  (cd "$cwd" && env "${envs[@]}" PATH=$PB:$OWNER setsid -w $ST set CALL_TIMEOUT 777 --proof "$T/p.json" </dev/null) >"$T/o" 2>&1; rc=$?
  cp "$T/pol.keep" "$POL"; rm -f "$T/sbx"
  ok '[ $rc = 1 ] && grep -q STL-CFG-312 "$T/o" && [ "$(snap)" = "$B" ] && [ "$(nev)" = "$e0" ]' "W4b worker signal $sig with a valid owner proof file: set refused STL-CFG-312, nothing changed"
done
st set CALL_TIMEOUT 777 --proof "$T/p.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -qE "^CALL_TIMEOUT=.?777.?$" "$LIM" && [ "$(nev)" = $((e0+1)) ] && tail -1 "$LOG" | jq -e --arg p "$OKP" ".auth == [\$p]" >/dev/null' "W4b the owner with that proof file (no worker run spent it): applied, one event line naming $OKP"
PATH=$PB:$OWNER setsid -w $AP rollback limits </dev/null >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -qx "CALL_TIMEOUT=600" "$LIM" && tail -1 "$LOG" | jq -e --arg p "$OKP" ".type == \"rollback\" and .auth == [\$p]" >/dev/null' "W4b rollback with the host key: the old value is back, the line names $OKP"
st set CALL_TIMEOUT 777 --proof "$T/p.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-OWN-804 "$T/o" && grep -qx "CALL_TIMEOUT=600" "$LIM"' "W4b the same proof file again (a replay; the host key is not used instead): STL-OWN-804, unchanged"
jq '.op = "rollback"' "$T/act.json" >"$T/act2.json"; PATH=$PB:$OWNER $OA prove --class owner_write --action "$T/act2.json" >"$T/p2.json" 2>/dev/null
st set CALL_TIMEOUT 777 --proof "$T/p2.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-OWN-805 "$T/o" && grep -qx "CALL_TIMEOUT=600" "$LIM"' "W4b a proof made for another action: STL-OWN-805, unchanged"
echo 'not json' >"$T/p3.json"; st set CALL_TIMEOUT 777 --proof "$T/p3.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-OWN-802 "$T/o" && grep -qx "CALL_TIMEOUT=600" "$LIM"' "W4b a proof file that is not JSON: STL-OWN-802, unchanged"
st set CALL_TIMEOUT 777 --proof >"$T/o" 2>&1; r1=$?; st get CALL_TIMEOUT --proof "$T/p.json" >"$T/o" 2>&1; r2=$?
ok '[ $r1 = 2 ] && [ $r2 = 2 ]' "W4b --proof with no file, or on get: usage (exit 2)"
mv "$KEY" "$T/key.away"; e1=$(nev)
st set CALL_TIMEOUT 901 >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-OWN-806 "$T/o" && grep -qx "CALL_TIMEOUT=600" "$LIM" && [ "$(nev)" = "$e1" ]' "W4b no owner key on the host and no proof file: set refused STL-OWN-806, nothing changed"
mv "$T/key.away" "$KEY"
# identity-critical: the phrase from data, shown with the change; both providers on the event line; rollback needs the phrase again
OWN=$R/config/owner.env; cp -p "$OWN" "$T/own.w4b"; e0=$(nev)
PHRASE=$PHR pt set WORKER_GIT_NAME "Shown Name" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "Fake One" "$T/o" && grep -q "Shown Name" "$T/o" && grep -q WORKER_GIT_NAME "$T/o" && grep -qF "\"$PHR\"" "$T/o" && [ "$(nev)" = $((e0+1)) ]' "W4b the terminal shows the target, the exact old and new values and the phrase from data in quotes; applied"
ok 'tail -1 "$LOG" | jq -e --arg a "$OKP" --arg b "$TPP" ".old.WORKER_GIT_NAME == \"Fake One\" and .new.WORKER_GIT_NAME == \"Shown Name\" and (.auth | sort) == ([\$a, \$b] | sort)" >/dev/null' "W4b the event line keeps old and new and names both providers ($OKP, $TPP)"
PATH=$PB:$OWNER setsid -w $AP rollback owner-settings </dev/null >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-OWN-808 "$T/o" && grep -q "Shown Name" "$OWN"' "W4b rollback of an identity-critical change with no terminal: STL-OWN-808"
PHRASE=$PHR ptap rollback owner-settings >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && cmp -s "$OWN" "$T/own.w4b"' "W4b rollback with the phrase typed: the old file is back byte-identical"
sed "s/^WORKER_GIT_NAME=.*/WORKER_GIT_NAME='Masked Case'/; s/^PLANTED_SECRET=.*/PLANTED_SECRET='sekrit-new-222'/" "$OWN" >"$T/own.cand"
PHRASE=$PHR ptap apply owner-settings --from "$T/own.cand" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "Masked Case" "$T/o" && grep -q PLANTED_SECRET "$T/o" && ! grep -rqE "sekrit-owner-111|sekrit-new-222" "$T/o" "$LOG" "$T/sup"' "W4b a change that also changes a secret: the terminal names the secret's key and shows neither value; nor does the event line"
PHRASE=$PHR ptap rollback owner-settings >/dev/null 2>&1
st set UNATTENDED_MODE true >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-OWN-808 "$T/o" && cmp -s "$OWN" "$T/own.w4b"' "W4b UNATTENDED_MODE with no terminal: STL-OWN-808"
jq '.phrase.template = "zz approve {what} now"' "$T/pol.keep" >"$POL"
PHRASE=$PHR pt set UNATTENDED_MODE true >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-OWN-808 "$T/o" && cmp -s "$OWN" "$T/own.w4b"' "W4b the phrase is data: after a template change the old phrase is refused (STL-OWN-808)"
PHRASE="$(phr owner-settings)" pt set UNATTENDED_MODE true >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -qF "\"zz approve owner-settings now\"" "$T/o" && tail -1 "$LOG" | jq -e "(.new.UNATTENDED_MODE | tostring) == \"true\"" >/dev/null' "W4b UNATTENDED_MODE with the new template's phrase: applied, the event line shows its new value"
PHRASE="$(phr owner-settings)" ptap rollback owner-settings >/dev/null 2>&1; cp "$T/pol.keep" "$POL"
ok 'cmp -s "$OWN" "$T/own.w4b"' "W4b the fixture is back as it was"
# an identity_critical alternative a --proof meets alone (a command provider standing in for a paired device, which signs the phrase): no terminal
TRUE=$(type -P true)   # the binary, not the shell builtin
jq --arg a "$TRUE" --arg g "$(python3 -I -c 'import uuid; print(uuid.uuid4())')" '.providers += [{id: "zz-remote", kind: "command", params: {argv: [$a], timeout_s: 5}, enabled: true, global_id: $g, install_id: .providers[0].install_id}] | .actions.identity_critical += [["zz-remote"]]' "$T/pol.keep" >"$POL"
st set WORKER_GIT_NAME "Remote Name" --dry-run >"$T/o" 2>&1; sed -n 's/^action: //p' "$T/o" >"$T/ra.json"
PATH=$PB:$OWNER $OA prove --class identity_critical --action "$T/ra.json" --provider zz-remote >"$T/rp.json" 2>/dev/null
PATH=$PB:$OWNER $OA prove --class owner_write --action "$T/ra.json" >"$T/rk.json" 2>/dev/null
st set WORKER_GIT_NAME "Remote Name" --proof "$T/rk.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-OWN-808 "$T/o" && cmp -s "$OWN" "$T/own.w4b"' "W4b identity-critical with a host-key proof file and no terminal: STL-OWN-808 (the key alone is not enough)"
st set WORKER_GIT_NAME "Remote Name" --proof "$T/rp.json" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "^WORKER_GIT_NAME=.Remote Name.$" "$OWN" && tail -1 "$LOG" | jq -e ".auth == [\"zz-remote\"]" >/dev/null' "W4b identity-critical with a --proof that meets an identity_critical alternative alone: applied with no terminal, the line names it"
cp "$T/pol.keep" "$POL"; PHRASE=$PHR ptap rollback owner-settings >/dev/null 2>&1
ok 'cmp -s "$OWN" "$T/own.w4b"' "W4b rollback of the remote change with the host key and the phrase: the old file is back"

[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
