#!/usr/bin/env bash
# Hermetic self-test for bin/owner_auth.py (F1c W2a, B1/B3, A7, design D2) and `stella_data.py stubs` (rule 13). Everything runs
# in a scratch root (STELLA_ROOT: a copy of bin/, .stella/ and docs/; own HOME, TMPDIR, alert log; a fake owner file; stub `hermes`
# boards on PATH); never the live tree, key or store.
# Key: init-key makes the index owner_key 0600 (umask 000 too), owner uid, one link; never overwrites (807), never writes through a
# link (dangling too); every key read (init-key, prove, verify) is refused in a worker environment, each signal (312); missing or
# unsafe key (mode, extra link, symlink) 806; a local-key proof verifies once for its own action: replay 804, another action 805,
# expired 803, tampered nonce or expiry 802, a class that does not allow the provider 801; the key appears in no output.
# A7: a fake third provider (kind command) added as data only is listed and decides (stdin JSON holds the digest; exit 0 = valid,
# non-zero 809/802, timeout 809), replay 804 and digest 805 stay with the generic layer, disabled / not in the class 801.
# Also: channel-identity counts only the owner config's user id on the message the caller bound (802 else, and always from the
# CLI); typed-phrase needs the phrase typed on a terminal (808 with none or a wrong one); device-phrase never passes without a
# device-signed payload (808); check refuses a policy naming an unknown provider. Stubs: due_phase needs replaced_by (schema), the
# owner-key stub is due E1/E2/E3, `stubs --phase P` lists stubs due at or before P (exit 1, STL-OWN-810) and exits 2 on an
# unknown phase. Cases from the F1c tester's T1-KEY, T7a and T-STUB, unchanged.
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/owner-auth-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
R=$T/root; mkdir -p "$R/docs/hermes-local" "$R/.supervisor/logs" "$R/.supervisor/state" "$T/home" "$T/tmp" "$T/sup/logs"
cp -r "$H/bin" "$H/.stella" "$R/"
(cd "$H/docs" && tar --exclude=./hermes-local/roles.json -cf - .) | (cd "$R/docs" && tar xf -)
jq '.worker_markers = ["STUB_WORKER_MARK"]' "$H/docs/hermes-local/roles.json" >"$R/docs/hermes-local/roles.json"
printf "OWNER_TIMEZONE='UTC'\nOWNER_DISCORD_USER_ID='100200300'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup ROLES_FILE=$R/docs/hermes-local/roles.json OWNER_CONFIG=$T/owner-fake.env
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT
IDX=$R/.stella/data-files.json
ix() { jq -r "$1" "$IDX"; }
POL=$R/$(ix '.files[] | select(.id == "owner-auth") | .path')
for v in $(jq -r '.worker_signals.token_env[]?' "$POL"); do unset "$v"; done
PY="python3 -I"; B=$R/bin; OA="$PY $B/owner_auth.py"; SD="$PY $B/stella_data.py"
IID=$(jq -r .install_id "$R/$(ix '.files[] | select(.schema == "install") | .path')")
uuid() { python3 -I -c "import uuid; print(uuid.uuid4())"; }
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
c() { grep -q "$1" "$T/o"; }
SIGNALS="marker user sandbox worktree board-worker board-down policy-unreadable $(jq -r '.worker_signals.token_env[]? | "token:" + .' "$POL" | tr '\n' ' ')"
as_worker() {   # as_worker <signal> <cmd...>: cmd with exactly that worker signal present; the policy is restored after
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
d64() { printf %s "$1" | sha256sum | cut -c1-64; }
act() { jq -nc --arg t "$1" --arg o "$(d64 old-$1)" --arg n "$(d64 new-$2)" '{op: "set", target: $t, old_digest: $o, new_digest: $n}' >"$T/act-$1-$2.json"; echo "$T/act-$1-$2.json"; }
A=$(act settings:CALL_TIMEOUT 900); A2=$(act settings:CALL_TIMEOUT 901)
KREL=$(ix .owner_key); KEY=$R/$KREL
outs() { cat "$T/o" >>"$T/allout" 2>/dev/null; }

# ---- T1-KEY: the local owner key ----
ok '[ -f "$B/owner_auth.py" ]' "precondition: bin/owner_auth.py exists"
$OA check >"$T/o" 2>&1; rc=$?; outs; ok '[ $rc = 0 ]' "owner_auth.py check: the shipped policy is valid"
$OA providers --json >"$T/o" 2>&1; rc=$?; outs
ok '[ $rc = 0 ] && jq -e "type == \"array\" and any(.id == \"owner-key\" and .kind == \"local-key\")" "$T/o" >/dev/null' "providers --json: owner-key (kind local-key) is listed"
$OA prove --class owner_write --action "$A" >"$T/o" 2>&1; rc=$?; outs
ok '[ $rc = 1 ] && c STL-OWN-806' "no key yet: prove refused, STL-OWN-806"
for s in $SIGNALS; do
  as_worker "$s" $OA init-key >"$T/o" 2>&1; rc=$?; outs
  ok '[ $rc = 1 ] && c STL-CFG-312 && [ ! -e "$KEY" ] && [ ! -L "$KEY" ]' "worker signal $s: init-key refused (STL-CFG-312), no key created"
done
(umask 000; $OA init-key) >"$T/o" 2>&1; rc=$?; outs
ok '[ $rc = 0 ] && [ -f "$KEY" ] && [ ! -L "$KEY" ]' "init-key (owner, host, umask 000): exit 0, a regular file at the index owner_key ($KREL)"
ok '[ -f "$KEY" ] && [ "$(stat -c %a "$KEY")" = 600 ] && [ "$(stat -c %u "$KEY")" = "$(id -u)" ] && [ "$(stat -c %h "$KEY")" = 1 ] && [ -s "$KEY" ]' "the key: mode 0600, owner uid, one link, not empty"
K0=$( (sha256sum <"$KEY") 2>/dev/null)
$OA init-key >"$T/o" 2>&1; rc=$?; outs
ok '[ $rc = 1 ] && c STL-OWN-807 && [ "$( (sha256sum <"$KEY") 2>/dev/null)" = "$K0" ]' "a second init-key: refused (STL-OWN-807), the key unchanged"
$OA prove --class owner_write --action "$A" >"$T/good-proof" 2>"$T/o"; cat "$T/good-proof" >>"$T/allout" 2>/dev/null
for s in $SIGNALS; do
  as_worker "$s" $OA prove --class owner_write --action "$A" >"$T/o" 2>&1; rc=$?; outs
  ok '[ $rc = 1 ] && c STL-CFG-312' "worker signal $s: prove (reads the key) refused, STL-CFG-312"
  as_worker "$s" $OA verify --class owner_write --action "$A" --proof "$T/good-proof" >"$T/o" 2>&1; rc=$?; outs
  ok '[ $rc = 1 ] && c STL-CFG-312' "worker signal $s: verify (reads the key) refused, STL-CFG-312"
done
P() { $OA prove --class owner_write --action "${2:-$A}" ${3:+--ttl $3} >"$1" 2>"$T/o"; local r=$?; cat "$1" >>"$T/allout" 2>/dev/null; outs; return $r; }
Vf() { $OA verify --class "${3:-owner_write}" --action "${2:-$A}" --proof "$1" >"$T/o" 2>&1; local r=$?; outs; return $r; }
P "$T/p1"; rc=$?; ok '[ $rc = 0 ] && jq -e . "$T/p1" >/dev/null' "prove --class owner_write --action <file>: exit 0, a JSON proof"
Vf "$T/p1"; rc=$?; ok '[ $rc = 0 ] && c owner-key' "verify of that proof for its own action: exit 0, names the provider used (owner-key)"
Vf "$T/p1"; rc=$?; ok '[ $rc = 1 ] && c STL-OWN-804' "the same proof again: refused, STL-OWN-804 (replay)"
P "$T/p2"; Vf "$T/p2" "$A2"; rc=$?; ok '[ $rc = 1 ] && c STL-OWN-805' "a proof for another action (other new value): refused, STL-OWN-805"
P "$T/p3" "$A" 1; sleep 3; Vf "$T/p3"; rc=$?; ok '[ $rc = 1 ] && c STL-OWN-803' "prove --ttl 1, verified after 3 s: refused, STL-OWN-803 (expired)"
P "$T/p4"; jq 'walk(if type == "object" and has("nonce") then .nonce = ("zz" + (.nonce | tostring)) else . end)' "$T/p4" >"$T/p4t" 2>/dev/null
Vf "$T/p4t"; rc=$?; ok '[ $rc = 1 ] && c STL-OWN-802' "a proof whose nonce was changed: refused, STL-OWN-802"
P "$T/p5"; jq 'walk(if type == "object" and has("expires_at") then .expires_at = (if (.expires_at | type) == "number" then .expires_at + 86400 else "2099-01-01T00:00:00Z" end) else . end)' "$T/p5" >"$T/p5t" 2>/dev/null
Vf "$T/p5t"; rc=$?; ok '[ $rc = 1 ] && c STL-OWN-802' "a proof whose expires_at was extended: refused, STL-OWN-802"
P "$T/p6"; Vf "$T/p6" "$A" channel_answer; rc=$?; ok '[ $rc = 1 ] && c STL-OWN-801' "a local-key proof for class channel_answer (policy allows only discord-owner): refused, STL-OWN-801"
P "$T/p7"; chmod 640 "$KEY" 2>/dev/null; Vf "$T/p7"; rc=$?; chmod 600 "$KEY" 2>/dev/null
ok '[ $rc = 1 ] && c STL-OWN-806' "key mode 0640: verify refused, STL-OWN-806"
P "$T/p8"; ln "$KEY" "$T/key-extra-link" 2>/dev/null; Vf "$T/p8"; rc=$?; rm -f "$T/key-extra-link"
ok '[ $rc = 1 ] && c STL-OWN-806' "key with a second hard link: verify refused, STL-OWN-806"
P "$T/p9"; mv "$KEY" "$T/key.real" 2>/dev/null; ln -s "$T/key.real" "$KEY"; Vf "$T/p9"; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-806' "key is a symbolic link: verify refused, STL-OWN-806"
$OA init-key >"$T/o" 2>&1; rc=$?; outs
ok '[ $rc = 1 ] && [ -L "$KEY" ] && [ "$( (sha256sum <"$T/key.real") 2>/dev/null)" = "$K0" ]' "init-key over a symbolic link: refused, the link target untouched"
rm -f "$KEY"; ln -s "$T/zz-dangling-target" "$KEY"
$OA init-key >"$T/o" 2>&1; rc=$?; outs
ok '[ $rc = 1 ] && [ ! -e "$T/zz-dangling-target" ]' "init-key over a dangling symbolic link: refused, nothing written through it"
rm -f "$KEY"; mv "$T/key.real" "$KEY" 2>/dev/null

# ---- typed-phrase and device-phrase (identity_critical) ----
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
PHRASE=$(jq -r '.phrase.template' "$POL"); PHRASE=${PHRASE//\{what\}/settings:CALL_TIMEOUT}
P "$T/q1"; setsid -w $OA verify --class identity_critical --action "$A" --proof "$T/q1" </dev/null >"$T/o" 2>&1; rc=$?; outs
ok '[ $rc = 1 ] && c STL-OWN-808' "identity_critical with the key proof but no terminal for the phrase: refused, STL-OWN-808"
P "$T/q2"; python3 -I "$T/pty.py" "not the phrase" $OA verify --class identity_critical --action "$A" --proof "$T/q2" >"$T/o" 2>&1; rc=$?; outs
ok '[ $rc = 1 ] && c STL-OWN-808 && ! c "no terminal"' "identity_critical with a wrong phrase typed on a terminal: refused, STL-OWN-808 (a terminal was found)"
P "$T/q3"; python3 -I "$T/pty.py" "$PHRASE" $OA verify --class identity_critical --action "$A" --proof "$T/q3" >"$T/o" 2>&1; rc=$?; outs
ok '[ $rc = 0 ] && c owner-key && c typed-phrase && c "settings:CALL_TIMEOUT"' "identity_critical with the key proof and the phrase typed on a terminal: exit 0, names owner-key and typed-phrase, showed the target"
cp -p "$POL" "$T/pol.orig"
jq '.actions.zz_dev = [["owner-key", "device-phrase"]]' "$T/pol.orig" >"$POL"
$OA check >"$T/o" 2>&1; rc=$?; ok '[ $rc = 1 ] && c STL-CFG-310' "check: device-phrase in an alternative with no device-signature provider is refused (no stub that accepts anything)"
jq '.actions.zz_ph = [["typed-phrase"]]' "$T/pol.orig" >"$POL"
$OA check >"$T/o" 2>&1; rc=$?; ok '[ $rc = 1 ] && c STL-CFG-310' "check: an alternative of phrase providers only (no proof) is refused"
cp -p "$T/pol.orig" "$POL"
P "$T/q4"; $PY -c 'import sys, json; sys.path.insert(0, sys.argv[1]); import owner_auth as oa
a, p = json.load(open(sys.argv[3])), json.load(open(sys.argv[2]))
p["phrase"] = oa.phrase(a); pol = oa.policy()
prov = next(x for x in pol["providers"] if x["kind"] == "device-phrase")
try:
    oa.VERIFY["device-phrase"](prov, None, {"action": a, "pol": pol, "used": [("local-key", p)]}); print("accepted")
except oa.Refusal as r:
    print(r.code)' "$B" "$T/q4" "$A" >"$T/o" 2>&1
ok 'c STL-OWN-808 && ! c accepted' "device-phrase without a device-signed payload: refused (STL-OWN-808), even with the right phrase on another proof"
cp -p "$T/pol.orig" "$POL"

# ---- channel-identity (discord-owner): the owner config's user id, on the message the caller bound ----
CI=$(jq -r '.providers[] | select(.kind == "channel-identity") | .id' "$POL" | head -1)
CK=$(jq -r --arg i "$CI" '.providers[] | select(.id == $i) | .params.channel_kind' "$POL")
chan() {   # chan <user> <message ref in the answer> <bound ref|-> <bound kind>: require("channel_answer") through the library
  $PY -c 'import sys, json, secrets, time; sys.path.insert(0, sys.argv[1]); import owner_auth as oa
a = json.load(open(sys.argv[2]))
p = {"provider": sys.argv[3], "digest": oa.digest(a), "nonce": secrets.token_hex(16), "expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 60)), "user": sys.argv[4], "message_ref": sys.argv[5]}
bound = None if sys.argv[6] == "-" else {"message_ref": sys.argv[6], "channel_kind": sys.argv[7]}
try:
    print(" ".join(oa.require("channel_answer", a, [p], bound=bound)))
    print(" ".join(oa.require("channel_answer", a, [p], bound=bound)))
except oa.Refusal as r:
    print(r.code)' "$B" "$A" "$CI" "$1" "$2" "$3" "$4" >"$T/o" 2>&1; }
chan 100200300 m-1 m-1 "$CK"; ok '[ "$(head -1 "$T/o")" = "$CI" ] && grep -qx STL-OWN-804 "$T/o"' "channel answer from the owner's id on the bound message: accepted once, the second is STL-OWN-804"
chan 999 m-1 m-1 "$CK"; ok 'grep -qx STL-OWN-802 "$T/o"' "channel answer from another user id: refused, STL-OWN-802"
chan 100200300 m-2 m-1 "$CK"; ok 'grep -qx STL-OWN-802 "$T/o"' "channel answer on another message than the one delivered: refused, STL-OWN-802"
chan 100200300 m-1 - "$CK"; ok 'grep -qx STL-OWN-802 "$T/o"' "channel answer with no binding from the caller: refused, STL-OWN-802"
chan 100200300 m-1 m-1 zz-other-kind; ok 'grep -qx STL-OWN-802 "$T/o"' "channel answer from a channel of another kind: refused, STL-OWN-802"
jq -n --arg p "$CI" --arg d "$($PY -c 'import sys, json; sys.path.insert(0, sys.argv[1]); import owner_auth as oa; print(oa.digest(json.load(open(sys.argv[2]))))' "$B" "$A")" \
  '{provider: $p, digest: $d, nonce: "0123456789abcdef0123456789abcdef", expires_at: "2099-01-01T00:00:00Z", user: "100200300", message_ref: "m-1"}' >"$T/ci.json"
$OA verify --class channel_answer --action "$A" --proof "$T/ci.json" >"$T/o" 2>&1; rc=$?; outs
ok '[ $rc = 1 ] && c STL-OWN-802' "a channel-identity proof from a file (CLI verify): refused, STL-OWN-802 (no caller binding)"

# ---- policy check ----
jq '.actions.owner_write += [["zz-no-such-provider"]]' "$T/pol.orig" >"$POL"
$OA check >"$T/o" 2>&1; rc=$?; ok '[ $rc = 1 ] && c STL-CFG-310' "check: an alternative naming no provider is refused (STL-CFG-310)"
P "$T/q5"; Vf "$T/q5"; rc=$?; ok '[ $rc = 1 ] && ! c "verified"' "verify with that policy: refused (fails closed)"
cp -p "$T/pol.orig" "$POL"
$PY -c 'import sys; sys.path.insert(0, sys.argv[1]); import owner_auth as oa
a = {"op": "set", "target": "t", "old_digest": "0" * 64, "new_digest": "1" * 64}
assert oa.digest(a) == oa.digest(dict(reversed(list(a.items())))) and len(oa.digest(a)) == 64
assert oa.digest(a) != oa.digest(dict(a, new_digest="2" * 64))
for bad in ({}, dict(a, extra=1), dict(a, new=1), {k: v for k, v in a.items() if k != "new_digest"}, dict(a, old_digest="x")):
    try:
        oa.digest(bad); raise SystemExit("accepted a bad action")
    except ValueError:
        pass
print("ok")' "$B" >"$T/o" 2>&1
ok 'grep -qx ok "$T/o"' "digest(): canonical (key order free), changes with the new value, refuses a malformed action"
KV=$(cat "$KEY" 2>/dev/null)
ok '[ -n "$KV" ] && ! grep -qF -- "$KV" "$T/allout"' "the key's content appears in no output (stdout or stderr of check, providers, init-key, prove, verify)"

# ---- T7a: a fake third provider, kind command, data only ----
mkdir -p "$T/fake"; echo ok >"$T/fake/mode"
cat >"$T/fake/zz-fake-auth.sh" <<S
#!/usr/bin/env bash
cat >"$T/fake/stdin.json"
case \$(cat "$T/fake/mode") in ok) exit 0;; slow) sleep 30; exit 0;; *) exit 1;; esac
S
chmod +x "$T/fake/zz-fake-auth.sh"
cp -r "$B" "$T/bin.before"
setpol() { jq --arg c "$T/fake/zz-fake-auth.sh" --arg g "$(uuid)" --arg i "$IID" --argjson en "$1" --argjson cls "$2" '
  .providers += [{id: "zz-fake", kind: "command", params: {argv: [$c], timeout_s: 2}, enabled: $en, global_id: $g, install_id: $i}]
  | reduce $cls[] as $k (.; .actions[$k] += [["zz-fake"]])' "$T/pol.orig" >"$POL"; }
setpol true '["owner_write"]'
$OA check >"$T/o" 2>&1; rc=$?; ok '[ $rc = 0 ]' "the policy with the fake command provider (data only) passes owner_auth.py check"
$OA providers --json >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && jq -e "any(.id == \"zz-fake\" and .kind == \"command\") and any(.id == \"owner-key\")" "$T/o" >/dev/null' "providers --json lists zz-fake (kind command) next to owner-key"
pr() { $OA prove --class owner_write --action "${2:-$A}" --provider zz-fake >"$1" 2>"$T/o"; }
vf() { $OA verify --class "${3:-owner_write}" --action "${2:-$A}" --proof "$1" >"$T/o" 2>&1; }
pr "$T/f1"; rc=$?; ok '[ $rc = 0 ] && jq -e . "$T/f1" >/dev/null' "prove --provider zz-fake: exit 0, a JSON proof (no key needed for a command provider)"
rm -f "$T/fake/stdin.json"; vf "$T/f1"; rc=$?
ok '[ $rc = 0 ] && c zz-fake' "verify: the fake provider decides (command exit 0), exit 0, names zz-fake as the provider used"
DG=$(jq -r '[.. | objects | .digest? | select(type == "string")][0] // empty' "$T/f1" 2>/dev/null)
ok '[ -n "$DG" ] && jq -e --arg d "$DG" "[.. | strings] | index([\$d]) != null" "$T/fake/stdin.json" >/dev/null 2>&1' "the command got the request as JSON on stdin, holding the action digest of the proof"
vf "$T/f1"; rc=$?; ok '[ $rc = 1 ] && c STL-OWN-804' "the same fake-provider proof again: refused, STL-OWN-804 (replay, generic layer)"
pr "$T/f2"; vf "$T/f2" "$A2"; rc=$?; ok '[ $rc = 1 ] && c STL-OWN-805' "a fake-provider proof for another action: refused, STL-OWN-805"
echo no >"$T/fake/mode"; pr "$T/f3"; vf "$T/f3"; rc=$?
ok '[ $rc = 1 ] && (c STL-OWN-809 || c STL-OWN-802)' "the command exits 1: refused (STL-OWN-809 or 802)"
echo slow >"$T/fake/mode"; pr "$T/f4"; s0=$(date +%s); vf "$T/f4"; rc=$?; el=$(( $(date +%s) - s0 ))
ok '[ $rc = 1 ] && c STL-OWN-809 && [ $el -lt 15 ]' "the command runs past timeout_s 2: refused, STL-OWN-809, within 15 s (took ${el}s)"
echo ok >"$T/fake/mode"
pr "$T/f5"; vf "$T/f5" "$A" channel_answer; rc=$?; ok '[ $rc = 1 ] && c STL-OWN-801' "zz-fake is not an alternative of channel_answer: refused, STL-OWN-801"
pr "$T/f6"; setpol false '["owner_write"]'; vf "$T/f6"; rc=$?; ok '[ $rc = 1 ] && c STL-OWN-801' "zz-fake disabled (enabled false): refused, STL-OWN-801"
setpol true '[]'; pr "$T/f7"; vf "$T/f7"; rc=$?; ok '[ $rc = 1 ] && c STL-OWN-801' "zz-fake present but in no alternative of owner_write: refused, STL-OWN-801"
setpol true '["owner_write", "channel_answer"]'; pr "$T/f8"; vf "$T/f8" "$A" channel_answer; rc=$?
ok '[ $rc = 0 ] && c zz-fake' "the same row added to channel_answer's alternatives (data only): selectable there too"
cp -p "$T/pol.orig" "$POL"
ok 'diff -rq "$T/bin.before" "$B" >/dev/null' "no code change: bin/ of the scratch root is unchanged by the fake provider"

# ---- T-STUB: features stubs and `stella_data.py stubs` ----
FROW=$(ix '.files[] | select(.schema == "features") | .path'); F=$R/$FROW; FS=$R/.stella/schemas/features.schema.json
ok 'jq -e ".properties.entries.items.properties | has(\"due_phase\") and has(\"replaced_by\")" "$FS" >/dev/null' "features schema: entries may carry due_phase and replaced_by"
ok 'jq -e "[.entries[] | select(.id | startswith(\"owner-key\"))] as \$s | (\$s | length > 0) and (\$s | all(.replaced_by | type == \"string\" and length > 0)) and ([\$s[].due_phase | if type == \"array\" then .[] else . end] as \$d | [\"E1\", \"E2\", \"E3\"] | all(. as \$p | \$d | index([\$p]) != null))" "$F" >/dev/null' "features.json: the owner-key stub is due E1/E2/E3 (Linux, Windows, macOS) with replaced_by"
$SD stubs --phase F1c --json >"$T/o" 2>"$T/ve"; rc=$?
ok '[ $rc = 0 ] && jq -e "type == \"array\" and length == 0" "$T/o" >/dev/null' "stubs --phase F1c on the shipped data: none due, exit 0, []"
$SD stubs --phase E1 --json >"$T/o" 2>"$T/ve"; rc=$?; cat "$T/o" "$T/ve" >"$T/all"; cp "$T/o" "$T/e1"
ok '[ $rc = 1 ] && jq -e "type == \"array\" and any(.id | startswith(\"owner-key\")) and all(has(\"id\") and has(\"due_phase\") and has(\"replaced_by\"))" "$T/o" >/dev/null && grep -q STL-OWN-810 "$T/all"' "stubs --phase E1 --json: exit 1, STL-OWN-810, lists the owner-key stub as {id, due_phase, replaced_by}"
ok '[ -s "$T/e1" ] && jq -e "all(.due_phase | if type == \"array\" then any(. == \"E1\") else . != \"E2\" and . != \"E3\" end)" "$T/e1" >/dev/null' "stubs --phase E1 lists nothing due only at E2 or E3"
$SD stubs --phase E3 --json >"$T/o" 2>"$T/ve"; rc=$?
ok '[ $rc = 1 ] && jq -e "[.[].due_phase | if type == \"array\" then .[] else . end] as \$d | [\"E1\", \"E2\", \"E3\"] | all(. as \$p | \$d | index([\$p]) != null)" "$T/o" >/dev/null' "stubs --phase E3: everything due at or before E3 (E1, E2, E3) is listed, exit 1"
$SD stubs --phase E1 >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q owner-key "$T/o"' "stubs --phase E1 (plain): exit 1, names the owner-key stub"
$SD stubs --phase ZZ9 >"$T/o" 2>&1; rc=$?
ok '[ $rc = 2 ]' "stubs --phase with a phase not in the data's phase order: exit 2 (usage)"
$SD stubs >"$T/o" 2>&1; rc=$?
ok '[ $rc = 2 ]' "stubs without --phase: exit 2 (usage)"
cp "$F" "$T/f.keep"
jq --arg g "$(uuid)" --arg i "$IID" '.entries += [(.entries[0] | .id = "zz-planted-stub" | .global_id = $g | .install_id = $i | .due_phase = "F1c" | .replaced_by = "zz-real-thing")]' "$T/f.keep" >"$F"
$SD validate features "$F" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ]' "(fixture) a stub entry with due_phase and replaced_by validates"
$SD stubs --phase F1c --json >"$T/o" 2>"$T/ve"; rc=$?; cat "$T/o" "$T/ve" >"$T/all"
ok '[ $rc = 1 ] && jq -e "any(.id == \"zz-planted-stub\") and (any(.id | startswith(\"owner-key\")) | not)" "$T/o" >/dev/null && grep -q STL-OWN-810 "$T/all"' "a stub due at F1c: stubs --phase F1c fails (exit 1, 810), lists it and not the E1 stub"
jq --arg g "$(uuid)" --arg i "$IID" '.entries += [(.entries[0] | .id = "zz-bad-stub" | .global_id = $g | .install_id = $i | .due_phase = "E1")]' "$T/f.keep" >"$F"
$SD validate features "$F" >"$T/o" 2>&1; rc=$?
ok '[ $rc != 0 ]' "a stub with due_phase but no replaced_by fails the features schema"
jq --arg g "$(uuid)" --arg i "$IID" '.entries += [(.entries[0] | .id = "zz-odd-stub" | .global_id = $g | .install_id = $i | .due_phase = "ZZ9" | .replaced_by = "x")]' "$T/f.keep" >"$F"
$SD check >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-CFG-310' "a stub due at a phase not in the phase order fails check"
cp "$T/f.keep" "$F"
$SD check >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ "$(head -1 "$T/o")" = "data OK" ]' "stella_data.py check passes on the shipped data"
echo "# owner-auth-selftest: $n cases, $fails failed"
[ "$fails" = 0 ] || { echo "selftest FAIL"; exit 1; }
echo "selftest PASS"
