#!/usr/bin/env bash
# Hermetic self-test for bin/devices.py, the device-signature provider of bin/owner_auth.py, the remote alert and rate limit,
# and bin/lease_double.py with .stella/schemas/primary-lease.schema.json (F1c W2b, B6, A8, design D5). Everything runs in a
# scratch root (STELLA_ROOT: a copy of bin/, .stella/ and docs/; own HOME, TMPDIR, alert log; fake owner settings and limits;
# stub `hermes` boards on PATH); the test device keys are made with openssl in the scratch only. Never the live tree, key or store.
# A paired device signs canonical {digest, nonce, expires_at, device_id[, phrase]} (raw Ed25519, base64): it passes owner_write
# alone; replay 804, another key 802, unknown 811, revoked 812, expired 803, another action 805, a field changed after signing 802;
# identity_critical needs the signed phrase (808 else); each accepted remote change writes one remote.alert_code alert and the
# policy rate limit refuses the next (813). settings.py set --proof takes a device proof; pairing and revoking are owner writes of
# the devices row through stella-apply.py. An account session is never a provider (801; an account kind is no policy kind, 310).
# Lease double: one holder per account (814), release by the holder, expiry frees it. Cases from the F1c tester's T8a, T8b, T8c,
# unchanged.
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/devices-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
R=$T/root; mkdir -p "$R/docs/hermes-local" "$R/.supervisor/logs" "$R/.supervisor/state" "$T/home" "$T/tmp" "$T/sup/logs"
cp -r "$H/bin" "$H/.stella" "$R/"
(cd "$H/docs" && tar --exclude=./hermes-local/roles.json -cf - .) | (cd "$R/docs" && tar xf -)
jq '.worker_markers = ["STUB_WORKER_MARK"]' "$H/docs/hermes-local/roles.json" >"$R/docs/hermes-local/roles.json"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup ROLES_FILE=$R/docs/hermes-local/roles.json OWNER_CONFIG=$T/owner-fake.env
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT
IDX=$R/.stella/data-files.json
ix() { jq -r "$1" "$IDX"; }
POL=$R/$(ix '.files[] | select(.id == "owner-auth") | .path')
for v in $(jq -r '.worker_signals.token_env[]?' "$POL"); do unset "$v"; done
PY="python3 -I"; B=$R/bin
# stub boards: ok = no running card; down = unreadable; worker = a running card bound to this shell
fp() { echo "$(cat /proc/sys/kernel/random/boot_id):$(sed 's/.*) //' /proc/1/stat | awk '{print $20}')|$(sed 's/.*) //' /proc/$1/stat | awk '{print $20}')"; }
for s in ok down worker; do mkdir -p "$T/pb-$s"; done
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb-ok/hermes"
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/pb-down/hermes"
cat >"$T/pb-worker/hermes" <<S
#!/usr/bin/env bash
case " \$* " in
  *" list "*) echo '[{"id":"c1"}]';;
  *" show "*) echo '{"task":{"id":"c1","assignee":"w"},"runs":[{"id":7,"ended_at":null}],"events":[{"kind":"claimed","run_id":7,"payload":{"lock":"h:1"}},{"kind":"worker_bound","run_id":7,"payload":{"pid":$$,"claim_lock":"h:1","started_at":"$(fp $$)"}}]}';;
  *) exit 1;;
esac
S
chmod +x "$T"/pb-*/hermes
BASEPATH=$PATH; export PATH=$T/pb-ok:$BASEPATH
cd "$T" || exit 1
fails=0; n=0
ok() { n=$((n+1)); if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); cat "$T/o" "$T/ve" 2>/dev/null | sed 's/^/     | /' | tail -n 3; fi; rm -f "$T/o" "$T/ve"; }
finish() { echo "# devices-selftest: $n cases, $fails failed"; [ "$fails" = 0 ]; exit $?; }
has() { [ -f "$B/$1" ] || { echo "     (precondition: bin/$1 does not exist)"; return 1; }; }
# worker signals (D0): one at a time. Tokens are named from the policy's token_env (data), one case each.
SIGNALS="marker user sandbox worktree board-worker board-down policy-unreadable $(jq -r '.worker_signals.token_env[]? | "token:" + .' "$POL" 2>/dev/null | tr '\n' ' ')"
# as_worker <signal> <cmd...>: runs cmd with exactly that signal present (cwd $T unless the signal is the run worktree); the policy is restored after
as_worker() {
  local s=$1 pb=$T/pb-ok cwd=$T rc envs=(STUB_NOTHING=1); shift
  cp -p "$POL" "$T/pol.keep"
  case $s in
    marker) envs=(STUB_WORKER_MARK=1);;
    token:*) envs=("${s#token:}=t0k-planted");;
    user) jq --arg u "$(id -un)" '.worker_signals.users += [$u]' "$T/pol.keep" >"$POL";;
    sandbox) : >"$T/sandbox-flag"; jq --arg f "$T/sandbox-flag" '.worker_signals.sandbox_files += [$f]' "$T/pol.keep" >"$POL";;
    worktree) cwd=$R/$(jq -r '.worker_signals.worktree_dirs[0]' "$T/pol.keep")/card-1; mkdir -p "$cwd";;
    board-worker) pb=$T/pb-worker;;
    board-down) pb=$T/pb-down;;
    policy-unreadable) printf '{not json' >"$POL";;
    *) echo "unknown signal $s" >&2; return 99;;
  esac
  (cd "$cwd" && env "${envs[@]}" PATH="$pb:$BASEPATH" "$@"); rc=$?
  cp -p "$T/pol.keep" "$POL"; rm -f "$T/sandbox-flag"
  return $rc
}
IID=$(jq -r .install_id "$R/$(ix '.files[] | select(.id == "install") | .path')")
LOG=$R/$(ix .event_log); KEY=$R/$(ix .owner_key)
ALERTS=$T/sup/logs/alerts.log
OA="$PY $B/owner_auth.py"; ST="$PY $B/settings.py"; SA="$PY $B/stella-apply.py"
uuid() { python3 -I -c 'import uuid; print(uuid.uuid4())'; }
d64() { printf %s "$1" | sha256sum | cut -c1-64; }
act() { jq -nc --arg t "$1" --arg o "$(d64 "old-$1")" --arg n "$(d64 "new-$2")" '{op: "set", target: $t, old_digest: $o, new_digest: $n}' >"$T/act-$2.json"; echo "$T/act-$2.json"; }
adig() { python3 -I -c 'import hashlib, json, sys; print(hashlib.sha256(json.dumps(json.load(open(sys.argv[1])), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest())' "$1"; }
c() { grep -qE "$1" "$T/o"; }
nal() { grep -c "${1:-.}" "$ALERTS" 2>/dev/null || true; }
polset() { local f=$1; shift; jq --arg g "$(uuid)" --arg i "$IID" "$@" "$f" "$POL" >"$T/pol.new" && cat "$T/pol.new" >"$POL"; }
st() { setsid -w "$@" </dev/null; }
cat >"$T/pty.py" <<'PY'
import os, pty, re, select, sys
phrase, cmd = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
buf, sent = b"", False
while True:
    r, _, _ = select.select([fd], [], [], 15)
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
        if phrase == "AUTO":
            m = re.findall(rb'"([^"\r\n]+)"[^"\r\n]*confirm', buf)
            os.write(fd, (m[-1] if m else b"zz-no-quoted-phrase-shown") + b"\n")
        else:
            os.write(fd, phrase.encode() + b"\n")
        sent = True
import time
for _ in range(50):   # a child still waiting 5 s after the output stopped is killed, never waited for forever
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        break
    time.sleep(0.1)
else:
    os.kill(pid, 9)
    _, status = os.waitpid(pid, 0)
sys.stdout.write(buf.decode(errors="replace"))
sys.exit(os.waitstatus_to_exitcode(status))
PY
pt() { local p=$1; shift; python3 -I "$T/pty.py" "$p" "$@"; }
# ---- devices (D5): a test double device key (openssl, in the scratch only), signed proofs ----
DVREL=$(ix '.files[] | select(.id == "devices") | .path'); [ -n "$DVREL" ] && [ "$DVREL" != null ] || DVREL=.stella/devices.json
DV=$R/$DVREL; DVLK=$(ix '.files[] | select(.id == "devices") | .list_key // "entries"'); [ -n "$DVLK" ] && [ "$DVLK" != null ] || DVLK=entries
mkdir -p "$T/dev"; chmod 700 "$T/dev"
devkey() { openssl genpkey -algorithm ed25519 -out "$T/dev/$1.key" 2>/dev/null && openssl pkey -in "$T/dev/$1.key" -pubout -out "$T/dev/$1.pub" 2>/dev/null; }
# pairdev <id> <key name> <kind> <role> [revoked_at]: a registry row written straight into the scratch file (test setup)
pairdev() { [ -f "$DV" ] || echo "{\"schema_version\": 1, \"$DVLK\": []}" >"$DV"
  jq --arg id "$1" --rawfile pk "$T/dev/$2.pub" --arg k "$3" --arg r "$4" --arg rv "${5:-}" --arg g "$(uuid)" --arg i "$IID" --arg lk "$DVLK" \
  '.[$lk] = ([.[$lk][]? | select(.id != $id)] + [{id: $id, global_id: $g, install_id: $i, kind: $k, public_key: $pk, role: $r, paired_at: "2026-11-14T00:00:00Z", revoked_at: (if $rv == "" then null else $rv end)}])' "$DV" >"$T/dv.new" && cat "$T/dv.new" >"$DV"; }
DEVP=$(jq -r '[.providers[]? | select(.kind == "device-signature") | .id][0] // empty' "$POL" 2>/dev/null)
# sign <out> <provider> <device id> <key name> <digest> <ttl s, negative = expired> [phrase]: a device-signed proof over canonical {digest, nonce, expires_at, device_id[, phrase]}
sign() { python3 -I - "$@" "$T/dev" <<'PY'
import base64, json, os, secrets, subprocess, sys, tempfile, time
out, prov, dev, key, dg, ttl = sys.argv[1:7]; phrase = sys.argv[7] if len(sys.argv) > 8 else None; d = sys.argv[-1]
p = {"digest": dg, "nonce": secrets.token_hex(16), "expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(time.time()) + int(ttl))), "device_id": dev}
if phrase is not None:
    p["phrase"] = phrase
msg = os.path.join(d, "msg"); sig = os.path.join(d, "sig")
open(msg, "wb").write(json.dumps(p, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode())
subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", os.path.join(d, key + ".key"), "-in", msg, "-out", sig], check=True)
json.dump({"provider": prov, **p, "signature": base64.b64encode(open(sig, "rb").read()).decode()}, open(out, "w"))
PY
}
# the action a dry run of the owner path says the proof must cover: one line `action: <JSON>` (W4b contract)
dryaction() { grep -m1 '^action: ' "$1" 2>/dev/null | sed 's/^action: //' >"$2"; [ -s "$2" ] && jq -e .target "$2" >/dev/null 2>&1; }
phr() { jq -r --arg t "$(jq -r .target "$1")" '.phrase.template | gsub("\\{what\\}"; $t)' "$POL"; }   # the rendered phrase (data)
# fake owner settings and limits in the scratch root (as bin/settings-selftest.sh); the planted secret is grepped for nowhere here
OWNF=$R/$(ix '.files[] | select(.id == "owner-settings") | .path'); LIMF=$R/$(ix '.files[] | select(.id == "limits") | .path')
mkdir -p "$(dirname "$OWNF")" "$(dirname "$LIMF")"
printf "# fake owner file\nWORKER_GIT_NAME='Fake One'\nWORKER_GIT_EMAIL='fake@example.invalid'\nPLANTED_SECRET='sekrit-owner-111'\n" >"$OWNF"
printf "CALL_TIMEOUT=600\n" >"$LIMF"; chmod 600 "$OWNF"; chmod 640 "$LIMF"
nev() { [ -f "$LOG" ] && wc -l <"$LOG" || echo 0; }
lastev() { tail -n 1 "$LOG" 2>/dev/null; }
usedby() { lastev | jq -e --arg p "$1" '[.. | arrays | select(index($p) != null)] | length > 0' >/dev/null 2>&1; }   # the provider id is in an array of the last event line

# ---- T8a: the paired device (owner_auth.py verify), settings.py set --proof, pairing and revoking ----
ok 'has devices.py' "precondition: bin/devices.py exists"
ok '[ "$(ix ".files[] | select(.id == \"devices\") | .owner_only")" = true ]' "index row devices exists, owner_only true"
DPH=$(jq -r '[.providers[]? | select(.kind == "device-phrase") | .id][0] // empty' "$POL")
ok '[ -n "$DEVP" ] && jq -e --arg d "$DEVP" --arg p "$DPH" "(.actions.owner_write | any(. == [\$d])) and (.actions.identity_critical | any(sort == ([\$d, \$p] | sort)))" "$POL" >/dev/null' "policy: a device-signature provider ($DEVP) is an owner_write alternative alone and an identity_critical alternative with device-phrase"
RAC=$(jq -r '.remote.alert_code // empty' "$POL")
ok 'jq -e ".remote.rate_limit | (.count | type == \"number\" and . > 0) and (.window_s | type == \"number\" and . > 0)" "$POL" >/dev/null && [[ $RAC =~ ^STL-OWN-81[5-9]$ ]]' "policy remote {rate_limit {count, window_s}, alert_code in STL-OWN-815..819} (got ${RAC:-none})"
DEVP=${DEVP:-zz-no-device-provider}
devkey phone; devkey other; devkey laptop; devkey tablet
pairdev zz-phone-1 phone phone phone; pairdev zz-laptop-1 laptop computer secondary 2026-11-14T01:00:00Z
$PY $B/devices.py check --json >"$T/o" 2>&1; rc=$?; ok '[ $rc = 0 ]' "devices.py check --json: the registry with a paired phone and a revoked computer is valid"
$PY $B/devices.py list --json >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && jq -e "any(.[]; .id == \"zz-phone-1\" and .revoked_at == null) and any(.[]; .id == \"zz-laptop-1\" and .revoked_at != null)" "$T/o" >/dev/null' "devices.py list --json: the phone (not revoked) and the revoked computer"
cp -p "$DV" "$T/dv.keep"; jq --arg lk "$DVLK" '.[$lk][0].public_key = "-----BEGIN PUBLIC KEY-----\nnot a key\n-----END PUBLIC KEY-----\n"' "$DV" >"$T/dv.bad" && cat "$T/dv.bad" >"$DV"
$PY $B/devices.py check --json >"$T/o" 2>&1; rc=$?; cat "$T/dv.keep" >"$DV"
ok '[ $rc = 1 ]' "devices.py check: a device whose public key is not an Ed25519 key fails (exit 1)"
polset '.remote.rate_limit = {count: 3, window_s: 3600}'
ok '[ ! -e "$KEY" ]' "no owner key on the host for the device part"
vf() { $OA verify --class "${3:-owner_write}" --action "$2" --proof "$1" >"$T/o" 2>&1; rc=$?; }
A=$(act settings:CALL_TIMEOUT d1); A2=$(act settings:CALL_TIMEOUT d2); DA=$(adig "$A")
sign "$T/p1" "$DEVP" zz-phone-1 phone "$DA" 120; vf "$T/p1" "$A"
ok '[ $rc = 0 ] && c "$DEVP"' "a paired device's signed request: verified for owner_write with no owner key, by $DEVP"
ok '[ -n "$RAC" ] && [ "$(nal "$RAC")" = 1 ]' "the accepted remote change raised one alert ($RAC)"
vf "$T/p1" "$A"; ok '[ $rc = 1 ] && c STL-OWN-804' "the same signed request again: refused STL-OWN-804 (replay)"
sign "$T/p2" "$DEVP" zz-phone-1 other "$DA" 120; vf "$T/p2" "$A"; ok '[ $rc = 1 ] && c STL-OWN-802' "signed by another key under the phone's id: refused STL-OWN-802"
sign "$T/p3" "$DEVP" zz-ghost-1 phone "$DA" 120; vf "$T/p3" "$A"; ok '[ $rc = 1 ] && c STL-OWN-811' "an unpaired device id: refused STL-OWN-811"
sign "$T/p4" "$DEVP" zz-laptop-1 laptop "$DA" 120; vf "$T/p4" "$A"; ok '[ $rc = 1 ] && c STL-OWN-812' "a revoked device: refused STL-OWN-812"
sign "$T/p5" "$DEVP" zz-phone-1 phone "$DA" -10; vf "$T/p5" "$A"; ok '[ $rc = 1 ] && c STL-OWN-803' "an expired signed request: refused STL-OWN-803"
sign "$T/p6" "$DEVP" zz-phone-1 phone "$(adig "$A2")" 120; vf "$T/p6" "$A"; ok '[ $rc = 1 ] && c STL-OWN-805' "a request signed for another action: refused STL-OWN-805"
sign "$T/p7" "$DEVP" zz-phone-1 phone "$DA" 120; jq --arg n "$(d64 changed | cut -c1-32)" '.nonce = $n' "$T/p7" >"$T/p7b"; vf "$T/p7b" "$A"
ok '[ $rc = 1 ] && c STL-OWN-802' "a nonce changed after signing: refused STL-OWN-802"
AI=$(act settings:WORKER_GIT_NAME ic1); PH=$(phr "$AI")
sign "$T/p8" "$DEVP" zz-phone-1 phone "$(adig "$AI")" 120 "$PH"; vf "$T/p8" "$AI" identity_critical
ok '[ $rc = 0 ] && c "$DEVP"' "identity_critical from the paired phone with the signed phrase \"$PH\": verified"
sign "$T/p9" "$DEVP" zz-phone-1 phone "$(adig "$AI")" 120; vf "$T/p9" "$AI" identity_critical; ok '[ $rc = 1 ] && c STL-OWN-808' "identity_critical from the phone without a signed phrase: refused STL-OWN-808"
sign "$T/p10" "$DEVP" zz-phone-1 phone "$(adig "$AI")" 120 "change something else"; vf "$T/p10" "$AI" identity_critical; ok '[ $rc = 1 ] && c STL-OWN-808' "identity_critical with a wrong signed phrase: refused STL-OWN-808"
ok '[ -n "$RAC" ] && [ "$(nal "$RAC")" = 2 ]' "two accepted remote changes so far, two $RAC alerts (refusals raise none of that code)"
A3=$(act settings:CALL_TIMEOUT d3); A4=$(act settings:CALL_TIMEOUT d4)
sign "$T/p11" "$DEVP" zz-phone-1 phone "$(adig "$A3")" 120; vf "$T/p11" "$A3"; ok '[ $rc = 0 ]' "the third remote change in the window (rate limit 3): verified"
sign "$T/p12" "$DEVP" zz-phone-1 phone "$(adig "$A4")" 120; vf "$T/p12" "$A4"; ok '[ $rc = 1 ] && c STL-OWN-813' "the fourth remote change in the window: refused STL-OWN-813 (rate limit)"
ok '[ -n "$RAC" ] && [ "$(nal "$RAC")" = 3 ]' "three accepted remote changes, three $RAC alerts"
# ---- settings part (W4b): the device proof through settings.py set --proof ----
polset '.remote.rate_limit = {count: 100, window_s: 3600}'
st $ST set CALL_TIMEOUT 900 --dry-run >"$T/dry" 2>&1
ok 'dryaction "$T/dry" "$T/s.act"' "settings.py set --dry-run prints the action the proof must cover (\"action: {...}\")"
SD=$(adig "$T/s.act" 2>/dev/null); E0=$(nev); N0=$(nal "$RAC")
sign "$T/s-bad" "$DEVP" zz-phone-1 other "$SD" 120; st $ST set CALL_TIMEOUT 900 --proof "$T/s-bad" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-802 && grep -qx CALL_TIMEOUT=600 "$LIMF"' "settings set with a request signed by another key: refused STL-OWN-802, unchanged"
sign "$T/s-rev" "$DEVP" zz-laptop-1 laptop "$SD" 120; st $ST set CALL_TIMEOUT 900 --proof "$T/s-rev" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-812 && grep -qx CALL_TIMEOUT=600 "$LIMF"' "settings set from the revoked device: refused STL-OWN-812"
sign "$T/s-unp" "$DEVP" zz-ghost-1 phone "$SD" 120; st $ST set CALL_TIMEOUT 900 --proof "$T/s-unp" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-811 && grep -qx CALL_TIMEOUT=600 "$LIMF"' "settings set from an unpaired device: refused STL-OWN-811"
sign "$T/s-ok" "$DEVP" zz-phone-1 phone "$SD" 120; st $ST set CALL_TIMEOUT 900 --proof "$T/s-ok" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -qE "^CALL_TIMEOUT=.?900.?$" "$LIMF" && [ "$(nev)" = $((E0+1)) ] && usedby "$DEVP"' "settings set with the paired phone's signed request: applied, one event line naming $DEVP"
ok '[ -n "$RAC" ] && [ "$(nal "$RAC")" = $((N0+1)) ]' "the remote settings change raised one $RAC alert"
$OA init-key >/dev/null 2>&1; st $SA rollback limits >/dev/null 2>&1
st $ST set CALL_TIMEOUT 900 --proof "$T/s-ok" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-804 && grep -qx CALL_TIMEOUT=600 "$LIMF"' "the same signed request replayed after a rollback (the host key present is not used instead): refused STL-OWN-804"
st $ST set WORKER_GIT_NAME "Phone Name" --dry-run >"$T/dry" 2>&1; dryaction "$T/dry" "$T/i.act"; ID_=$(adig "$T/i.act" 2>/dev/null)
sign "$T/i-np" "$DEVP" zz-phone-1 phone "$ID_" 120; st $ST set WORKER_GIT_NAME "Phone Name" --proof "$T/i-np" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-808 && grep -q "^WORKER_GIT_NAME=.Fake One.$" "$OWNF"' "identity-critical setting from the phone without the signed phrase: refused STL-OWN-808"
sign "$T/i-ok" "$DEVP" zz-phone-1 phone "$ID_" 120 "$(phr "$T/i.act" 2>/dev/null)"; st $ST set WORKER_GIT_NAME "Phone Name" --proof "$T/i-ok" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -q "^WORKER_GIT_NAME=.Phone Name.$" "$OWNF" && usedby "$DEVP" && usedby "$DPH"' "identity-critical setting from the phone with the signed phrase (no terminal): applied, both providers named"
# pairing and revoking: owner writes of the devices row through the apply contract
jq --arg lk "$DVLK" --rawfile pk "$T/dev/tablet.pub" --arg g "$(uuid)" --arg i "$IID" '.[$lk] += [{id: "zz-tablet-1", global_id: $g, install_id: $i, kind: "phone", public_key: $pk, role: "secondary", paired_at: "2026-11-14T02:00:00Z", revoked_at: null}]' "$DV" >"$T/dv.pair"
as_worker marker $SA apply devices --from "$T/dv.pair" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-CFG-312' "pairing in a worker environment: refused STL-CFG-312"
pt AUTO $SA apply devices --from "$T/dv.pair" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && jq -e --arg lk "$DVLK" "any(.[\$lk][]; .id == \"zz-tablet-1\")" "$DV" >/dev/null' "pairing on the host (owner key + typed phrase) through stella-apply.py apply devices: paired"
A5=$(act settings:CALL_TIMEOUT d5); sign "$T/t1" "$DEVP" zz-tablet-1 tablet "$(adig "$A5")" 120; vf "$T/t1" "$A5"
ok '[ $rc = 0 ]' "the newly paired tablet's signed request: verified"
jq --arg lk "$DVLK" '(.[$lk][] | select(.id == "zz-tablet-1") | .revoked_at) = "2026-11-14T03:00:00Z"' "$DV" >"$T/dv.rev"
pt AUTO $SA apply devices --from "$T/dv.rev" >"$T/o" 2>&1; rc=$?
A6=$(act settings:CALL_TIMEOUT d6); sign "$T/t2" "$DEVP" zz-tablet-1 tablet "$(adig "$A6")" 120; vf "$T/t2" "$A6"
ok '[ $rc = 1 ] && c STL-OWN-812' "revoked through the apply contract (one place): its next signed request is refused STL-OWN-812"

# ---- T8b: an account session is never an owner proof ----
A=$(act settings:CALL_TIMEOUT s1); DA=$(adig "$A")
EXP=$(date -u -d '+120 sec' +%Y-%m-%dT%H:%M:%SZ); NON=$(d64 sess | cut -c1-32)
jq -nc --arg d "$DA" --arg n "$NON" --arg e "$EXP" '{provider: "account-session", account: "zz-account", session: "zz-session-token", digest: $d, nonce: $n, expires_at: $e}' >"$T/sess"
$OA verify --class owner_write --action "$A" --proof "$T/sess" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-801' "an account-session proof for owner_write: refused STL-OWN-801"
$OA verify --class identity_critical --action "$A" --proof "$T/sess" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-801' "an account-session proof for identity_critical: refused STL-OWN-801"
$OA providers --json >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && jq -e "all(.[]; (.kind | test(\"account|session\")) | not)" "$T/o" >/dev/null' "no shipped provider is of an account or session kind"
cp -p "$POL" "$T/pol.ship"
for k in account-session account; do
  polset '.providers += [{id: "zz-acct", kind: $k, params: {}, enabled: true, global_id: $g, install_id: $i}] | .actions.owner_write += [["zz-acct"]]' --arg k "$k"
  $OA check >"$T/o" 2>&1; rc=$?; cp -p "$T/pol.ship" "$POL"
  ok '[ $rc = 1 ] && c STL-CFG-310' "a policy row of kind $k: owner_auth.py check refuses STL-CFG-310 (an account session is no provider kind)"
done
DEVP=${DEVP:-paired-device}
jq -nc --arg p "$DEVP" --arg d "$DA" --arg n "$NON" --arg e "$EXP" '{provider: $p, account: "zz-account", session: "zz-session-token", digest: $d, nonce: $n, expires_at: $e}' >"$T/sess-dev"
$OA verify --class owner_write --action "$A" --proof "$T/sess-dev" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && (c STL-OWN-802 || c STL-OWN-811) && [ -n "$(jq -r "[.providers[] | select(.kind == \"device-signature\")][0].id // empty" "$POL")" ]' "a session dressed as a device proof (no device id, no signature): refused (802 or 811) by the shipped device provider"
st $ST set CALL_TIMEOUT 900 --dry-run >"$T/dry" 2>&1
if dryaction "$T/dry" "$T/s.act"; then jq --arg d "$(adig "$T/s.act")" '.digest = $d' "$T/sess" >"$T/sess2"; else cp "$T/sess" "$T/sess2"; fi
st $ST set CALL_TIMEOUT 900 --proof "$T/sess2" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-801 && grep -qx CALL_TIMEOUT=600 "$LIMF"' "settings.py set --proof with an account session alone: refused STL-OWN-801, unchanged"
$OA init-key >/dev/null 2>&1
st $ST set CALL_TIMEOUT 900 --proof "$T/sess2" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-801 && grep -qx CALL_TIMEOUT=600 "$LIMF"' "the same with an owner key on the host: still refused STL-OWN-801 (the session is not topped up by the key)"

# ---- T8c: the primary-lease contract and its test double ----
LD="$PY $B/lease_double.py"; S=$T/lease-state.json; SD="$PY $B/stella_data.py"; SCH=$R/.stella/schemas/primary-lease.schema.json
ok '[ -f "$R/.stella/schemas/primary-lease.schema.json" ]' "precondition: .stella/schemas/primary-lease.schema.json exists"
ok 'has lease_double.py' "precondition: bin/lease_double.py exists"
G=$(uuid)
jq -n --arg g "$G" --arg i "$IID" '{account: "zz-acct-1", engine_id: "zz-engine-a", install_id: $i, lease_id: $g, acquired_at: "2026-11-14T00:00:00Z", expires_at: "2026-11-14T01:00:00Z"}' >"$T/lease.ok"
$SD validate primary-lease "$T/lease.ok" >"$T/o" 2>&1; rc=$?; ok '[ $rc = 0 ]' "a lease with the six fields validates"
for k in account engine_id install_id lease_id acquired_at expires_at; do
  jq "del(.$k)" "$T/lease.ok" >"$T/lease.bad"; $SD validate primary-lease "$T/lease.bad" >"$T/o" 2>&1; rc=$?
  ok '[ -f "$SCH" ] && [ $rc = 1 ]' "a lease without $k is rejected"
done
jq '.zz_extra = 1' "$T/lease.ok" >"$T/lease.bad"; $SD validate primary-lease "$T/lease.bad" >"$T/o" 2>&1; rc=$?; ok '[ -f "$SCH" ] && [ $rc = 1 ]' "a lease with an extra field is rejected"
$LD claim --state "$S" --account zz-acct-1 --engine zz-engine-a --ttl 600 >"$T/c1" 2>"$T/o"; rc=$?
ok '[ $rc = 0 ] && $SD validate primary-lease "$T/c1" >/dev/null 2>&1 && jq -e ".account == \"zz-acct-1\" and .engine_id == \"zz-engine-a\"" "$T/c1" >/dev/null' "first claim: exit 0, prints a lease that validates against the contract"
cp -p "$S" "$T/s.keep" 2>/dev/null
$LD claim --state "$S" --account zz-acct-1 --engine zz-engine-b --ttl 600 >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-814 && cmp -s "$S" "$T/s.keep"' "a second claim by another engine: refused STL-OWN-814, the state unchanged"
$LD show --state "$S" --account zz-acct-1 >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && jq -e ".engine_id == \"zz-engine-a\"" "$T/o" >/dev/null' "show: the holder is still engine a"
$LD claim --state "$S" --account zz-acct-2 --engine zz-engine-b --ttl 600 >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ]' "another account: its own lease (one holder per account)"
$LD release --state "$S" --account zz-acct-1 --engine zz-engine-b >"$T/o" 2>&1; rc=$?
ok '[ -f "$B/lease_double.py" ] && [ $rc = 1 ]' "a release by an engine that does not hold the lease: refused"
$LD release --state "$S" --account zz-acct-1 --engine zz-engine-a >"$T/o" 2>&1; rc=$?; ok '[ $rc = 0 ]' "release by the holder: exit 0"
$LD claim --state "$S" --account zz-acct-1 --engine zz-engine-b --ttl 1 >"$T/o" 2>&1; rc=$?; ok '[ $rc = 0 ]' "after the release another engine claims"
sleep 2
$LD claim --state "$S" --account zz-acct-1 --engine zz-engine-c --ttl 600 >"$T/o" 2>&1; rc=$?; ok '[ $rc = 0 ]' "after the lease expired another engine claims"
$LD claim --state "$S" --account zz-acct-1 --engine zz-engine-d --ttl 600 >"$T/o" 2>&1; rc=$?; ok '[ $rc = 1 ] && c STL-OWN-814' "and the next one is refused STL-OWN-814 again"
$LD bogus >"$T/o" 2>&1; rc=$?; ok '[ -f "$B/lease_double.py" ] && [ $rc = 2 ]' "usage error: exit 2"
finish
