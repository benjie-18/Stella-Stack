#!/usr/bin/env bash
# Hermetic self-test for bin/approvals.py, the approval service (F1c W3, body B2, design D3 incl. DG-2), its channel rows
# (.stella/channels.json) and adapters (bin/adapters/). Stub adapters and resume, stub boards, scratch roots, no network.
# Every section runs in its own fresh scratch root (bash approvals-selftest.sh <section>); no argument runs them all.
# Cases from the F1c tester's wave-2 T1a, T1b, T2a, T2b, T7b and T6b (consumer part), unchanged; plus the shipped adapters:
# the Discord adapter over the stack's Discord helper (a fake Hermes interpreter), the host-cli adapter and the resume script.
# Gate B cycle 1: the tester's R10 and the attack scripts CRT-1, RT-4, RT-5 (GB-4), CRT-7, RT-7 (GB-5), unchanged; gb4 and gb5
# cover every site of those rules (intake and collect; the payload, Discord and host-cli).
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SECTIONS="t1a t1b t2a t2b t7b t6b adapters expiry r10 crt1 rt4 rt5 crt7 rt7 gb4 gb5"
if [ $# = 0 ]; then
  fails=0
  for s in $SECTIONS; do bash "${BASH_SOURCE[0]}" "$s" || fails=$((fails+1)); done
  [ "$fails" = 0 ] && echo "approvals-selftest PASS" || echo "approvals-selftest FAIL ($fails sections)"
  [ "$fails" = 0 ]; exit
fi
case " $SECTIONS " in *" $1 "*) ;; *) echo "usage: approvals-selftest.sh [$(tr ' ' '|' <<<"$SECTIONS")]" >&2; exit 2;; esac
SECTION=$1
# ---- harness (the tester's qa/wave1/lib.sh and qa/wave2/lib2.sh, the parts the approval cases use) ----
TREE=$H
T=$(mktemp -d "${TMPDIR:-/tmp}/approvals-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
R=$T/root; mkdir -p "$R/docs/hermes-local" "$R/.supervisor/logs" "$R/.supervisor/state" "$T/home" "$T/tmp" "$T/sup/logs" "$T/sup/state"
cp -r "$H/bin" "$H/.stella" "$R/"
# The scratch code folder is read-only: no tool writes there, and python3 -I would otherwise leave __pycache__ files in it,
# which the T7b "bin/ equals the tree's" case would count as a code change.
chmod -R a-w "$R/bin"
(cd "$H/docs" && tar --exclude=./hermes-local/roles.json -cf - .) | (cd "$R/docs" && tar xf -)
jq '.worker_markers = ["STUB_WORKER_MARK"]' "$H/docs/hermes-local/roles.json" >"$R/docs/hermes-local/roles.json"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup ROLES_FILE=$R/docs/hermes-local/roles.json OWNER_CONFIG="$T/owner-fake.env"
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT
IDX=$R/.stella/data-files.json
ix() { jq -r "$1" "$IDX"; }
POL=$R/$(ix '.files[] | select(.id == "owner-auth") | .path')
for v in $(jq -r '.worker_signals.token_env[]?' "$POL" 2>/dev/null); do unset "$v"; done
PY="python3 -I"; B=$R/bin
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
finish() { echo "# approvals-selftest $SECTION: $n cases, $fails failed"; [ "$fails" = 0 ]; exit $?; }
codes() { grep -oE 'STL-[A-Z]+-[0-9]{3}' "$@" | sort -u | tr '\n' ' '; }   # the codes in output files
has() { [ -f "$B/$1" ] || { echo "     (precondition: bin/$1 does not exist in TREE)"; return 1; }; }
SIGNALS="marker user sandbox worktree board-worker board-down policy-unreadable $(jq -r '.worker_signals.token_env[]? | "token:" + .' "$POL" 2>/dev/null | tr '\n' ' ')"
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
LOG=$R/$(ix .event_log); STORE=$R/$(ix .approval_store); KEY=$R/$(ix .owner_key)
ALERTS=$T/sup/logs/alerts.log
OA="$PY $B/owner_auth.py"; AP="$PY $B/approvals.py"
OWNER_ID=111111111111111111; OTHER_ID=222222222222222222   # made-up Discord ids, only in the scratch owner config
printf "OWNER_DISCORD_USER_ID='%s'\n" "$OWNER_ID" >>"$OWNER_CONFIG"
uuid() { python3 -I -c 'import uuid; print(uuid.uuid4())'; }
d64() { printf %s "$1" | sha256sum | cut -c1-64; }
act() { jq -nc --arg t "$1" --arg o "$(d64 "old-$1")" --arg n "$(d64 "new-$2")" '{op: "set", target: $t, old_digest: $o, new_digest: $n}' >"$T/act-$2.json"; echo "$T/act-$2.json"; }
adig() { python3 -I -c 'import hashlib, json, sys; print(hashlib.sha256(json.dumps(json.load(open(sys.argv[1])), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest())' "$1"; }
c() { grep -qE "$1" "$T/o"; }
polset() { local f=$1; shift; jq --arg g "$(uuid)" --arg i "$IID" "$@" "$f" "$POL" >"$T/pol.new" && cat "$T/pol.new" >"$POL"; }
PL() { $PY -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import event_log as e; print(json.dumps(e.proof_lines()))' "$B" >"$T/pl" 2>/dev/null || : >"$T/pl"; }
CHREL=$(ix '.files[] | select(.id == "channels") | .path'); [ -n "$CHREL" ] && [ "$CHREL" != null ] || CHREL=.stella/channels.json
CH=$R/$CHREL; CHLK=$(ix '.files[] | select(.id == "channels") | .list_key // "entries"'); [ -n "$CHLK" ] && [ "$CHLK" != null ] || CHLK=entries
[ -f "$CH" ] || echo "{\"schema_version\": 1, \"$CHLK\": []}" >"$CH"
mkdir -p "$T/ans"
cat >"$T/adapter.sh" <<S
#!/usr/bin/env bash
# stub delivery adapter: deliver <chan> = keep the request from stdin, print a message ref; collect <chan> = print the queued answer lines once
d=$T/ans; c=\$2
case \$1 in
  deliver) n=\$(( \$(cat "\$d/\$c.n" 2>/dev/null || echo 0) + 1 )); echo \$n >"\$d/\$c.n"; cat >"\$d/\$c.req.\$n"; echo "m-\$c-\$n" >"\$d/\$c.lastref"; echo "m-\$c-\$n";;
  collect) [ -f "\$d/\$c.in" ] && cat "\$d/\$c.in"; : >"\$d/\$c.in";;
  *) exit 2;;
esac
S
cat >"$T/resume.sh" <<S
#!/usr/bin/env bash
# stub resume (board unblock): one line per run with its arguments and stdin
{ printf 'args:%s ' "\$*"; tr '\n' ' '; echo; } >>"$T/resume.log"
S
chmod +x "$T/adapter.sh" "$T/resume.sh"
addchan() { jq --arg id "$1" --arg k "$2" --argjson en "${3:-true}" --arg a "$T/adapter.sh" --arg g "$(uuid)" --arg i "$IID" --arg lk "$CHLK" \
  '.[$lk] = ([.[$lk][]? | select(.id != $id)] + [{id: $id, kind: $k, deliver: [$a, "deliver", $id], collect: [$a, "collect", $id], enabled: $en, global_id: $g, install_id: $i}])' "$CH" >"$T/ch.new" && cat "$T/ch.new" >"$CH"; }
stubkind() { local id; for id in $(jq -r --arg k "$1" --arg lk "$CHLK" '.[$lk][]? | select(.kind == $k) | .id' "$CH"); do addchan "$id" "$1"; done; }
setresume() { jq --arg r "$T/resume.sh" '.resume = {argv: [$r], timeout_s: 10}' "$CH" >"$T/ch.new" && cat "$T/ch.new" >"$CH"; }
answer() { jq -nc --arg r "$2" --arg n "$3" --arg d "$4" --arg u "$5" --arg m "$6" --arg g "${7:-}" \
  '{request_id: $r, nonce: $n, decision: $d, user: $u, message_ref: $m} + (if $g == "" then {} else {digest: $g} end)' >>"$T/ans/$1.in"; }
lastref() { cat "$T/ans/$1.lastref" 2>/dev/null; }
mkreq() { $AP request --class "$2" --action "$3" --summary "zz summary $1" --card "$4" --ttl "$5" ${6:+--requester "$6"} --json >"$T/req-$1.json" 2>"$T/req-$1.err"; jq -r '.id // empty' "$T/req-$1.json" 2>/dev/null; }
rf() { jq -r ".$2 // empty" "$T/req-$1.json" 2>/dev/null; }
stat_of() { $AP status "$1" --json 2>/dev/null | jq -r '.status // empty' 2>/dev/null; }
collect() { $AP collect --channel "$1" >"$T/o" 2>&1; }
ndec() { grep -F "\"$1\"" "$LOG" 2>/dev/null | grep -c '"approval-decision"'; }
pl_dec() { PL; [ -s "$T/pl" ] && jq -e --arg id "$1" --arg dg "$2" --arg d "$3" '[.[] | select(.type == "approval-decision" and (tostring | contains($id)) and (tostring | contains($dg)) and (tostring | contains($d)))] | length == 1' "$T/pl" >/dev/null; }
st() { setsid -w "$@" </dev/null; }
nev() { [ -f "$LOG" ] && wc -l <"$LOG" || echo 0; }
ndeca() { grep -F "\"$1\"" "$LOG" 2>/dev/null | grep '"approval-decision"' | grep -c approved; }

case $SECTION in
t1a) # A1: non-owner id, card/comment/tool/model text, wrong nonce, unknown id, other message, other digest, expiry, replay; owner answer once
ok 'has approvals.py' "precondition: bin/approvals.py exists"
ok '[ "$(ix ".files[] | select(.id == \"channels\") | .owner_only")" = true ]' "index row channels exists, owner_only true"
ok 'jq -e --arg lk "$CHLK" "[.[\$lk][]? | .kind] | (index(\"discord\") != null) and (index(\"host-cli\") != null)" "$CH" >/dev/null' "the shipped channels hold a discord row and a host-cli row"
ok 'jq -e ".channel_kinds | .discord == true and .[\"host-cli\"] == true and .app == true and .voice == false and .card == false and .comment == false and .[\"tool-output\"] == false and .[\"model-output\"] == false" "$POL" >/dev/null' "policy channel_kinds as designed (discord, host-cli, app answer; voice, card, comment, tool-output, model-output do not)"
stubkind discord; setresume
DC=$(jq -r --arg lk "$CHLK" '[.[$lk][]? | select(.kind == "discord") | .id][0] // "zz-discord"' "$CH"); [ "$DC" = zz-discord ] && addchan zz-discord discord
for k in card comment tool-output model-output; do addchan "zz-$k" "$k"; done
A1=$(act settings:CALL_TIMEOUT a1); A9=$(act settings:CALL_TIMEOUT a9)
ID=$(mkreq r1 write "$A1" card-1 120)
ok '[ -n "$ID" ] && [ "$(rf r1 digest)" = "$(adig "$A1")" ] && [[ $(rf r1 nonce) =~ ^[0-9a-f]{32,}$ ]] && [ -n "$(rf r1 expires_at)" ]' "request --json: id, digest = sha256 of the action's canonical JSON, a nonce, expires_at"
ok '[ -n "$ID" ] && [ -f "$STORE/requests/$ID.json" ] && jq -e ".status == \"pending\"" "$STORE/requests/$ID.json" >/dev/null' "the request is stored at approval_store/requests/<id>.json, status pending"
NONCE=$(rf r1 nonce); DG=$(rf r1 digest)
$AP deliver "$ID" --channel "$DC" >"$T/o" 2>&1; rc=$?; REF=$(lastref "$DC")
ok '[ $rc = 0 ] && [ -n "$REF" ] && jq -e --arg id "$ID" --arg n "$NONCE" ".id == \$id and .nonce == \$n and (.summary | length > 0)" "$T/ans/$DC.req.1" >/dev/null' "deliver: the discord adapter gets the request (id, nonce, summary) on stdin and returns a message ref"
ok 'jq -e --arg c "$DC" --arg r "$REF" ".deliveries[\$c] == \$r" "$STORE/requests/$ID.json" >/dev/null 2>&1' "the store records the delivery ref under the channel id"
try() { answer "$1" "$2" "$3" "$4" "$5" "$6" "${7:-}"; collect "$1"; rc=$?; }
try "$DC" "$ID" "$NONCE" approved "$OTHER_ID" "$REF" "$DG"
ok '[ $rc = 1 ] && c STL-OWN-828 && [ "$(stat_of "$ID")" = pending ]' "a non-owner Discord id answers: refused STL-OWN-828 (owner proof refused), still pending"
for k in card comment tool-output model-output; do
  try "zz-$k" "$ID" "$NONCE" approved "$OWNER_ID" "$REF" "$DG"
  ok '[ $rc = 1 ] && c STL-OWN-826 && [ "$(stat_of "$ID")" = pending ]' "a perfect owner answer offered as $k text: refused STL-OWN-826 (kind may not answer), still pending"
done
try "$DC" "$ID" "$(d64 wrong | cut -c1-32)" approved "$OWNER_ID" "$REF" "$DG"
ok '[ $rc = 1 ] && c STL-OWN-823 && [ "$(stat_of "$ID")" = pending ]' "owner answer with a wrong nonce: refused STL-OWN-823, still pending"
try "$DC" "zz-no-such-request" "$NONCE" approved "$OWNER_ID" "$REF" "$DG"
ok '[ $rc = 1 ] && c STL-OWN-820' "owner answer for an unknown request id: refused STL-OWN-820"
try "$DC" "$ID" "$NONCE" approved "$OWNER_ID" "m-elsewhere-9" "$DG"
ok '[ $rc = 1 ] && c STL-OWN-825 && [ "$(stat_of "$ID")" = pending ]' "owner answer on another message (not the delivery ref): refused STL-OWN-825, still pending"
try "$DC" "$ID" "$NONCE" approved "$OWNER_ID" "$REF" "$(adig "$A9")"
ok '[ $rc = 1 ] && c STL-OWN-824 && [ "$(stat_of "$ID")" = pending ]' "owner answer carrying another action's digest: refused STL-OWN-824, still pending"
ok '[ -f "$B/approvals.py" ] && [ "$(ndec "$ID")" = 0 ]' "no refused answer wrote a decision line"
try "$DC" "$ID" "$NONCE" approved "$OWNER_ID" "$REF" "$DG"
ok '[ $rc = 0 ] && [ "$(stat_of "$ID")" = approved ]' "the matching owner answer (owner id, nonce, delivered message, digest): accepted, status approved"
ok '[ "$(ndec "$ID")" = 1 ]' "exactly one decision line for the request in the trusted log"
ok 'pl_dec "$ID" "$DG" approved' "the approval counts as one trusted decision line in proof_lines() with the action's digest (needs W1 proof_lines)"
try "$DC" "$ID" "$NONCE" approved "$OWNER_ID" "$REF" "$DG"
ok '[ $rc = 1 ] && c STL-OWN-821 && [ "$(ndec "$ID")" = 1 ] && [ "$(stat_of "$ID")" = approved ]' "the same owner answer again: replay refused STL-OWN-821, still one decision line"
try "$DC" "$ID" "$NONCE" denied "$OWNER_ID" "$REF" "$DG"
ok '[ $rc = 1 ] && c STL-OWN-821 && [ "$(stat_of "$ID")" = approved ]' "a later deny for the decided request: refused STL-OWN-821, the decision stands"
ID2=$(mkreq r2 write "$A9" card-2 2); $AP deliver "$ID2" --channel "$DC" >/dev/null 2>&1; REF2=$(lastref "$DC"); sleep 3
try "$DC" "$ID2" "$(rf r2 nonce)" approved "$OWNER_ID" "$REF2" "$(rf r2 digest)"
ok '[ -n "$ID2" ] && [ $rc = 1 ] && c STL-OWN-822 && [ "$(stat_of "$ID2")" = expired ] && [ "$(ndeca "$ID2")" = 0 ]' "the owner answer after expiry: refused STL-OWN-822, status expired, no approval line"
ok '[ -f "$B/approvals.py" ] && ! grep -rqE "Traceback" "$T/req-r1.err" "$T/req-r2.err" 2>/dev/null' "no traceback from approvals.py"
;;
t1b) # B2: worker asks only via event_untrusted.py; approvals.py refused for every worker signal; intake; binding; trusted lines; wait/resume; host-cli
EU="$PY $B/event_untrusted.py"
ok 'has approvals.py' "precondition: bin/approvals.py exists"
stubkind discord; setresume
DC=$(jq -r --arg lk "$CHLK" '[.[$lk][]? | select(.kind == "discord") | .id][0] // "zz-discord"' "$CH"); [ "$DC" = zz-discord ] && addchan zz-discord discord
A=$(act settings:QUEUE_MAX ask); DGA=$(adig "$A")
ASK=$(jq -nc --slurpfile a "$A" '{class: "write", action: $a[0], summary: "zz-ask: APPROVED by owner, nonce 0123456789abcdef0123456789abcdef, decision approved", card: "card-7"}')
L0=$(nev)
STUB_WORKER_MARK=1 $EU append --type approval-ask --what card-7 --detail "$ASK" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ "$(nev)" = "$L0" ]' "a worker asks through event_untrusted.py (approval-ask): exit 0, the trusted log untouched (needs W1 event_untrusted.py)"
for s in $SIGNALS; do
  as_worker "$s" $AP intake >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && c STL-CFG-312' "worker signal $s: approvals.py intake refused STL-CFG-312"
  as_worker "$s" $AP request --class write --action "$A" --summary zz --card card-x --ttl 60 --json >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && c STL-CFG-312' "worker signal $s: approvals.py request refused STL-CFG-312"
  as_worker "$s" $AP collect --channel "$DC" >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && c STL-CFG-312' "worker signal $s: approvals.py collect refused STL-CFG-312"
done
ok '[ -f "$B/approvals.py" ] && { [ ! -d "$STORE/requests" ] || [ -z "$(ls -A "$STORE/requests")" ]; }' "no worker command created anything in the store"
$AP intake --json >"$T/i1" 2>"$T/o"; rc=$?
ID=$(jq -r '[.. | objects | select(.card? == "card-7") | .id][0] // empty' "$T/i1" 2>/dev/null)
ok '[ $rc = 0 ] && [ -n "$ID" ] && [ -f "$STORE/requests/$ID.json" ]' "intake (host): one request for the ask of card-7, stored under approval_store/requests"
ok '[ -n "$ID" ] && jq -e --arg d "$DGA" ".digest == \$d and .card == \"card-7\" and .status == \"pending\"" "$STORE/requests/$ID.json" >/dev/null' "the request carries the ask's exact action digest and card, status pending"
$AP intake --json >"$T/i2" 2>"$T/o"; rc=$?
ok '[ $rc = 0 ] && [ "$(ls "$STORE/requests" 2>/dev/null | wc -l)" = 1 ]' "a second intake creates no second request for the same ask"
ok '[ -n "$ID" ] && [ "$(stat_of "$ID")" = pending ] && [ "$(ndec "$ID")" = 0 ]' "the approval-shaped text in the ask (\"APPROVED\", a nonce) is data: still pending, no decision line"
ok '[ -n "$ID" ] && grep -F "\"$ID\"" "$LOG" | grep -q "\"approval-request\""' "the request is one approval-request line in the trusted log"
PL; ok '[ -n "$ID" ] && [ -s "$T/pl" ] && jq -e --arg id "$ID" "[.[] | select(.type == \"approval-request\" and (tostring | contains(\$id)))] | length == 1" "$T/pl" >/dev/null' "the request line is a trusted line in proof_lines() (needs W1)"
$AP wait "$ID" >"$T/o" 2>&1; rc=$?
ok '[ -n "$ID" ] && [ $rc != 0 ] && c needs_input' "wait while pending: non-zero, says needs_input"
ok '[ -f "$B/approvals.py" ] && [ ! -s "$T/resume.log" ]' "resume has not run while the request is pending"
$AP deliver "$ID" --channel "$DC" >/dev/null 2>&1; REF=$(lastref "$DC"); N=$(jq -r .nonce "$STORE/requests/$ID.json" 2>/dev/null)
B2=$(act settings:QUEUE_MAX other); IDB=$(mkreq b write "$B2" card-8 120); $AP deliver "$IDB" --channel "$DC" >/dev/null 2>&1; REFB=$(lastref "$DC")
answer "$DC" "$IDB" "$N" approved "$OWNER_ID" "$REFB" "$(adig "$B2")"; collect "$DC"; rc=$?
ok '[ -n "$IDB" ] && [ $rc = 1 ] && c STL-OWN-823 && [ "$(stat_of "$IDB")" = pending ]' "an answer carrying request A's nonce sent for request B: refused STL-OWN-823"
answer "$DC" "$ID" "$N" approved "$OWNER_ID" "$REF" "$(adig "$B2")"; collect "$DC"; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-824 && [ "$(stat_of "$ID")" = pending ]' "an answer whose action digest is not the request's: refused STL-OWN-824"
answer "$DC" "$ID" "$N" approved "$OWNER_ID" "$REF" "$DGA"; collect "$DC"; rc=$?
ok '[ $rc = 0 ] && [ "$(stat_of "$ID")" = approved ]' "the owner's bound answer: accepted, status approved"
$AP wait "$ID" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && c approved' "wait after the approval: exit 0, approved"
ok '[ "$(grep -c card-7 "$T/resume.log" 2>/dev/null)" = 1 ]' "resume ran once for card-7 on the decision"
ok '[ "$(ndec "$ID")" = 1 ] && grep -F "\"$ID\"" "$LOG" | grep "\"approval-decision\"" | grep -qF "$DGA"' "the decision is one approval-decision line naming the request and its digest"
ok 'pl_dec "$ID" "$DGA" approved' "the decision line is trusted: in proof_lines() with the digest (needs W1)"
answer "$DC" "$IDB" "$(rf b nonce)" denied "$OWNER_ID" "$REFB" "$(rf b digest)"; collect "$DC"; rc=$?
ok '[ $rc = 0 ] && [ "$(stat_of "$IDB")" = denied ]' "an owner deny: accepted, status denied"
$AP wait "$IDB" >"$T/o" 2>&1; rc=$?
ok '[ $rc != 0 ] && c denied && [ "$(grep -c card-8 "$T/resume.log" 2>/dev/null)" = 1 ]' "wait after a deny: non-zero, denied; resume ran once for card-8"
C3=$(act settings:QUEUE_MAX hc); IDC=$(mkreq hc write "$C3" card-9 120)
st $AP answer "$IDC" --decision approved >"$T/o" 2>&1; rc=$?
ok '[ -n "$IDC" ] && [ $rc = 1 ] && c STL-OWN-806 && [ "$(stat_of "$IDC")" = pending ]' "host-cli answer with no owner key: refused STL-OWN-806, still pending"
$OA init-key >/dev/null 2>&1
as_worker marker $AP answer "$IDC" --decision approved >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-CFG-312 && [ "$(stat_of "$IDC")" = pending ]' "host-cli answer in a worker environment: refused STL-CFG-312"
st $AP answer "$IDC" --decision approved >"$T/o" 2>&1; rc=$?
ok '[ -n "$IDC" ] && [ $rc = 0 ] && [ "$(stat_of "$IDC")" = approved ] && [ "$(ndec "$IDC")" = 1 ]' "host-cli answer on the host with the owner key: accepted once, one decision line"
st $AP answer "$IDC" --decision approved >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-821 && [ "$(ndec "$IDC")" = 1 ]' "host-cli answer again: replay refused STL-OWN-821"
;;
t2a) # A2: voice refused (entry off, and channel_kinds.voice=true); entry validates, malformed entry 310
ok 'has approvals.py' "precondition: bin/approvals.py exists"
ok 'jq -e ".voice_host_confirmation | type == \"object\" and .enabled == false and (.profile | type == \"string\" and length > 0) and (.max_ttl_s | type == \"number\" and . > 0) and (.action_class | type == \"string\" and length > 0)" "$POL" >/dev/null' "shipped policy: voice_host_confirmation {enabled: false, profile, max_ttl_s, action_class}"
ok 'jq -e ".channel_kinds.voice == false" "$POL" >/dev/null' "shipped policy: channel_kinds.voice is false"
$OA check >"$T/o" 2>&1; rc=$?; ok 'jq -e .voice_host_confirmation "$POL" >/dev/null && [ $rc = 0 ]' "owner_auth.py check: the shipped policy with the entry validates"
$PY $B/stella_data.py validate owner-auth "$POL" >"$T/o" 2>&1; rc=$?; ok '[ $rc = 0 ]' "stella_data.py validate owner-auth: the shipped policy validates against its schema"
cp -p "$POL" "$T/pol.ship"
for f in '.voice_host_confirmation.enabled = "yes"' 'del(.voice_host_confirmation.max_ttl_s)' '.voice_host_confirmation.max_ttl_s = -5' '.voice_host_confirmation.zz_extra = 1' '.channel_kinds.voice = "maybe"'; do
  polset "$f"; $OA check >"$T/o" 2>&1; rc=$?; cp -p "$T/pol.ship" "$POL"
  ok 'jq -e ".voice_host_confirmation" "$T/pol.ship" >/dev/null && [ $rc = 1 ] && c STL-CFG-310' "a malformed entry ($f): owner_auth.py check refuses, STL-CFG-310"
done
PROF=$(jq -r '.voice_host_confirmation.profile // "zz-voice"' "$POL"); AC=$(jq -r '.voice_host_confirmation.action_class // "zz-host-ask"' "$POL")
addchan zz-voice voice; setresume
vtry() {
  local a id; a=$(act host:zz-$1 "$1"); id=$(mkreq "$1" "$2" "$a" "card-$1" 20 "$3"); V=$id
  $AP deliver "$id" --channel zz-voice >/dev/null 2>&1
  answer zz-voice "$id" "$(rf "$1" nonce)" approved "$OWNER_ID" "$(lastref zz-voice)" "$(rf "$1" digest)"; collect zz-voice; rc=$?; }
vtry v1 write "$PROF"
ok '[ -n "$V" ] && [ $rc = 1 ] && c STL-OWN-827 && [ "$(stat_of "$V")" = pending ]' "entry off: a voice answer to an ordinary approval: refused STL-OWN-827, still pending"
vtry v2 "$AC" "$PROF"
ok '[ -n "$V" ] && [ $rc = 1 ] && c STL-OWN-827 && [ "$(stat_of "$V")" = pending ]' "entry off: a voice answer to the entry's own class and profile: refused STL-OWN-827"
polset '.channel_kinds.voice = true'
vtry v3 write "$PROF"
ok '[ $rc = 1 ] && (c STL-OWN-827 || c STL-OWN-826 || c STL-CFG-310) && { [ -z "$V" ] || [ "$(stat_of "$V")" != approved ]; }' "policy edited to channel_kinds.voice = true: a voice answer is still refused (827, 826, or the policy check 310)"
cp -p "$T/pol.ship" "$POL"
ok '[ "$(grep -c "\"approval-decision\"" "$LOG" 2>/dev/null)" = 0 ]' "no voice answer wrote a decision line"
;;
t2b) # A2: entry on: one own voice confirmation accepted; other class/profile/target/no digest/ttl>max/other user/expired refused
ok 'has approvals.py' "precondition: bin/approvals.py exists"
ok 'jq -e ".voice_host_confirmation | type == \"object\"" "$POL" >/dev/null' "precondition: the policy has voice_host_confirmation"
PROF=$(jq -r '.voice_host_confirmation.profile // "zz-voice"' "$POL"); AC=$(jq -r '.voice_host_confirmation.action_class // "zz-host-ask"' "$POL")
VOICE_ID=333333333333333333; printf "ZZ_VOICE_OWNER_ID='%s'\n" "$VOICE_ID" >>"$OWNER_CONFIG"
polset '.voice_host_confirmation.enabled = true | .voice_host_confirmation.max_ttl_s = 30
  | .providers += [{id: "zz-voice-owner", kind: "channel-identity", params: {channel_kind: "voice", owner_config_key: "ZZ_VOICE_OWNER_ID"}, enabled: true, global_id: $g, install_id: $i}]
  | .actions.channel_answer += [["zz-voice-owner"]]
  | if (.actions[$ac] == null) and ($ac | test("^[a-z][a-z0-9_]*$")) then .actions[$ac] = [["zz-voice-owner"]] else . end' --arg ac "$AC"
$OA check >"$T/o" 2>&1; rc=$?; ok '[ $rc = 0 ]' "owner_auth.py check: the policy with the entry on and the voice provider (data) validates"
addchan zz-voice voice; setresume
vreq() { local a; a=$(act "${5:-host:zz-own-action}" "$1"); V=$(mkreq "$1" "$2" "$a" "card-$1" "$4" "$3"); [ -n "$V" ] && $AP deliver "$V" --channel zz-voice >/dev/null 2>&1; }
vans() { answer zz-voice "$V" "$(rf "$1" nonce)" approved "${3:-$VOICE_ID}" "$(lastref zz-voice)" "${2-$(rf "$1" digest)}"; collect zz-voice; rc=$?; }
vreq own "$AC" "$PROF" 20; VOWN=$V; vans own
ok '[ -n "$VOWN" ] && [ $rc = 0 ] && [ "$(stat_of "$VOWN")" = approved ]' "a voice confirmation for its own bound action (class, profile, ttl 20 <= 30, digest shown): accepted, approved"
ok '[ -n "$VOWN" ] && [ "$(ndec "$VOWN")" = 1 ]' "one decision line for it"
ok 'pl_dec "$VOWN" "$(rf own digest)" approved' "the voice confirmation counts as a trusted decision line in proof_lines() (needs W1)"
ok '[ "$(grep -c card-own "$T/resume.log" 2>/dev/null)" = 1 ]' "resume ran once for its card"
vans own; ok '[ $rc = 1 ] && c STL-OWN-821 && [ "$(ndec "$VOWN")" = 1 ]' "the same voice confirmation again: replay refused STL-OWN-821"
vreq oth write "$PROF" 20; vans oth
ok '[ -n "$V" ] && [ $rc = 1 ] && c STL-OWN-827 && [ "$(stat_of "$V")" = pending ]' "a voice answer to an approval of another class: refused STL-OWN-827"
vreq prf "$AC" zz-other-profile 20; vans prf
ok '[ -n "$V" ] && [ $rc = 1 ] && c STL-OWN-827 && [ "$(stat_of "$V")" = pending ]' "a voice answer to the host class asked by another profile: refused STL-OWN-827"
vreq tgt "$AC" "$PROF" 20; vans tgt "$(adig "$(act host:zz-changed-target tgt2)")"
ok '[ -n "$V" ] && [ $rc = 1 ] && c STL-OWN-827 && [ "$(stat_of "$V")" = pending ]' "a voice confirmation for a changed target (digest of another action): refused STL-OWN-827"
vreq nod "$AC" "$PROF" 20; vans nod ""
ok '[ -n "$V" ] && [ $rc = 1 ] && c STL-OWN-827 && [ "$(stat_of "$V")" = pending ]' "a voice confirmation without the digest of the details shown: refused STL-OWN-827"
vreq ttl "$AC" "$PROF" 120
if [ -n "$V" ]; then vans ttl; else rc=1; cp "$T/req-ttl.err" "$T/o"; fi
ok '[ $rc = 1 ] && c STL-OWN-827 && { [ -z "$V" ] || [ "$(stat_of "$V")" != approved ]; }' "a host-class request with ttl 120 > max_ttl_s 30: the voice confirmation is refused STL-OWN-827 (at request or at answer)"
vreq usr "$AC" "$PROF" 20; vans usr "$(rf usr digest)" "$OTHER_ID"
ok '[ -n "$V" ] && [ $rc = 1 ] && c STL-OWN-828 && [ "$(stat_of "$V")" = pending ]' "a voice confirmation from a user who is not the voice owner: refused STL-OWN-828"
vreq exp "$AC" "$PROF" 2; sleep 3; vans exp
ok '[ -n "$V" ] && [ $rc = 1 ] && c STL-OWN-822 && [ "$(stat_of "$V")" = expired ]' "an expired voice confirmation: refused STL-OWN-822, status expired"
ok '[ "$(grep "\"approval-decision\"" "$LOG" 2>/dev/null | grep -c approved)" = 1 ]' "in all, exactly one approval decision line (the own action's)"
;;
t7b) # A7: fake adapter row (existing kind) and a brand-new kind, all data, receive and answer; unlisted kind 826; bin/ unchanged
ok 'has approvals.py' "precondition: bin/approvals.py exists"
setresume
addchan zz-fake-discord discord
$PY $B/stella_data.py validate channels "$CH" >"$T/o" 2>&1; rc=$?; ok '[ $rc = 0 ]' "the channels file with the fake discord row validates (schema channels)"
A=$(act settings:QUEUE_MAX fk1); ID=$(mkreq fk1 write "$A" card-f1 120)
$AP deliver "$ID" --channel zz-fake-discord >"$T/o" 2>&1; rc=$?
ok '[ -n "$ID" ] && [ $rc = 0 ] && jq -e --arg id "$ID" ".id == \$id and (.nonce | length >= 32) and (.summary | length > 0)" "$T/ans/zz-fake-discord.req.1" >/dev/null 2>&1' "(a) the fake discord-kind row receives the request (id, nonce, summary on stdin)"
answer zz-fake-discord "$ID" "$(rf fk1 nonce)" approved "$OWNER_ID" "$(lastref zz-fake-discord)" "$(rf fk1 digest)"; collect zz-fake-discord; rc=$?
ok '[ $rc = 0 ] && [ "$(stat_of "$ID")" = approved ] && [ "$(ndec "$ID")" = 1 ]' "(a) the owner's answer collected from it: accepted, approved, one decision line"
ZZ_ID=444444444444444444; printf "ZZ_CHAT_OWNER_ID='%s'\n" "$ZZ_ID" >>"$OWNER_CONFIG"
polset '.channel_kinds["zz-chat"] = true
  | .providers += [{id: "zz-chat-owner", kind: "channel-identity", params: {channel_kind: "zz-chat", owner_config_key: "ZZ_CHAT_OWNER_ID"}, enabled: true, global_id: $g, install_id: $i}]
  | .actions.channel_answer += [["zz-chat-owner"]]'
addchan zz-chat-1 zz-chat
$OA check >"$T/o" 2>&1; rc=$?; ok '[ $rc = 0 ]' "(b) owner_auth.py check: the policy with the zz-chat kind and its owner provider (data) validates"
$PY $B/stella_data.py validate channels "$CH" >"$T/o" 2>&1; rc=$?; ok '[ $rc = 0 ]' "(b) the channels file with a row of the new kind validates (kind is not a code enum)"
A2=$(act settings:QUEUE_MAX fk2); ID2=$(mkreq fk2 write "$A2" card-f2 120)
$AP deliver "$ID2" --channel zz-chat-1 >"$T/o" 2>&1; rc=$?
ok '[ -n "$ID2" ] && [ $rc = 0 ] && jq -e --arg id "$ID2" ".id == \$id" "$T/ans/zz-chat-1.req.1" >/dev/null 2>&1 && jq -e --arg r "$(lastref zz-chat-1)" ".deliveries[\"zz-chat-1\"] == \$r" "$STORE/requests/$ID2.json" >/dev/null 2>&1' "(b) the zz-chat row receives the request; the store keeps its message ref"
answer zz-chat-1 "$ID2" "$(rf fk2 nonce)" approved "$OWNER_ID" "$(lastref zz-chat-1)" "$(rf fk2 digest)"; collect zz-chat-1; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-828 && [ "$(stat_of "$ID2")" = pending ]' "(b) on zz-chat the Discord owner id is not the zz-chat owner: refused STL-OWN-828"
answer zz-chat-1 "$ID2" "$(rf fk2 nonce)" approved "$ZZ_ID" "$(lastref zz-chat-1)" "$(rf fk2 digest)"; collect zz-chat-1; rc=$?
ok '[ $rc = 0 ] && [ "$(stat_of "$ID2")" = approved ] && [ "$(ndec "$ID2")" = 1 ]' "(b) the zz-chat owner's bound answer: accepted, approved, one decision line"
ok 'pl_dec "$ID2" "$(rf fk2 digest)" approved' "(b) it counts as a trusted decision line in proof_lines() (needs W1)"
ok '[ "$(grep -c card-f2 "$T/resume.log" 2>/dev/null)" = 1 ]' "(b) resume ran once for its card"
addchan zz-unlisted-1 zz-unlisted
A3=$(act settings:QUEUE_MAX fk3); ID3=$(mkreq fk3 write "$A3" card-f3 120); $AP deliver "$ID3" --channel zz-unlisted-1 >/dev/null 2>&1
answer zz-unlisted-1 "$ID3" "$(rf fk3 nonce)" approved "$OWNER_ID" "$(lastref zz-unlisted-1)" "$(rf fk3 digest)"; collect zz-unlisted-1; rc=$?
ok '[ -n "$ID3" ] && [ $rc = 1 ] && c STL-OWN-826 && [ "$(stat_of "$ID3")" = pending ]' "(c) an answer from a row whose kind is not in channel_kinds: refused STL-OWN-826 (fail closed)"
ok 'diff -rq "$TREE/bin" "$R/bin" >/dev/null' "no code change: bin/ of the scratch root equals the tree's"
;;
t6b) # A6 consumer part: forged approvals (untrusted stream, raw trusted line, copied genuine line, store edit) count for nothing
EU="$PY $B/event_untrusted.py"; EL="$PY $B/event_log.py"
ok 'has approvals.py' "precondition: bin/approvals.py exists"
stubkind discord; setresume
DC=$(jq -r --arg lk "$CHLK" '[.[$lk][]? | select(.kind == "discord") | .id][0] // "zz-discord"' "$CH"); [ "$DC" = zz-discord ] && addchan zz-discord discord
AA=$(act settings:QUEUE_MAX fa); AB=$(act settings:QUEUE_MAX fb); AC=$(act settings:QUEUE_MAX fc)
IA=$(mkreq a write "$AA" card-a 120); IB=$(mkreq b write "$AB" card-b 120); IC=$(mkreq c write "$AC" card-c 120)
DA=$(rf a digest); DB=$(rf b digest); NA=$(rf a nonce)
ok '[ -n "$IA" ] && [ -n "$IB" ] && [ -n "$IC" ]' "three pending requests A, B, C"
DET=$(jq -nc --arg id "$IA" --arg d "$DA" --arg n "$NA" --arg u "$OWNER_ID" '{request_id: $id, digest: $d, nonce: $n, decision: "approved", user: $u}')
STUB_WORKER_MARK=1 $EU append --type approval-decision --what "$IA" --source "$DC" --detail "$DET" >"$T/o" 2>&1
STUB_WORKER_MARK=1 $EU append --type approval-decision --what "$IA" --source host-cli --detail "$DET" >>"$T/o" 2>&1
ok '[ -n "$IA" ] && [ "$(stat_of "$IA")" = pending ]' "a worker's approval-decision lines for A in the untrusted stream: A stays pending"
$AP wait "$IA" >"$T/o" 2>&1; rc=$?
ok '[ -n "$IA" ] && [ $rc != 0 ] && c needs_input && [ ! -s "$T/resume.log" ]' "wait for A still says needs_input; resume did not run"
FL=$(jq -nc --arg id "$IA" --arg d "$DA" --arg g "$(uuid)" --arg i "$IID" --arg h "$(d64 forged-mac)" '{schema_version: 3, time: "2026-11-14T00:00:00Z", type: "approval-decision", what: $id, new: {decision: "approved", digest: $d, request_id: $id}, global_id: $g, install_id: $i, writer: {id: "engine", install_id: $i}, seq: 999, prev: $h, mac: $h}')
printf '%s\n' "$FL" >>"$LOG"
ok '[ -n "$IA" ] && [ "$(stat_of "$IA")" = pending ]' "a forged approval-decision line appended to the trusted file: A stays pending"
$EL verify --json >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ]' "event_log.py verify fails on the forged line (needs W1 verify)"
[ -n "$IC" ] && [ -f "$STORE/requests/$IC.json" ] && jq '.status = "approved" | .decision = {decision: "approved"}' "$STORE/requests/$IC.json" >"$T/s" && cat "$T/s" >"$STORE/requests/$IC.json"
ok '[ -n "$IC" ] && [ "$(stat_of "$IC")" != approved ]' "C's store record edited to status approved: status does not say approved (the store's status is not proof)"
$AP wait "$IC" >"$T/o" 2>&1; rc=$?
ok '[ -n "$IC" ] && [ $rc != 0 ]' "wait for the hand-edited C: not approved (non-zero)"
$AP deliver "$IB" --channel "$DC" >/dev/null 2>&1; REFB=$(lastref "$DC")
answer "$DC" "$IB" "$(rf b nonce)" approved "$OWNER_ID" "$REFB" "$DB"; collect "$DC"; rc=$?
ok '[ $rc = 0 ] && [ "$(stat_of "$IB")" = approved ] && pl_dec "$IB" "$DB" approved' "B approved by the owner: a trusted decision line in proof_lines() (needs W1)"
GL=$(grep -F "\"$IB\"" "$LOG" 2>/dev/null | grep '"approval-decision"' | tail -n 1)
[ -n "$GL" ] && [ -n "$IA" ] && printf '%s\n' "$GL" | sed "s/$IB/$IA/g; s/$DB/$DA/g" >>"$LOG"
ok '[ -n "$GL" ] && [ "$(stat_of "$IA")" = pending ]' "B's genuine decision line copied with A's id and digest: A stays pending"
ok '[ "$(stat_of "$IB")" = approved ]' "B (decided before the forgeries) stays approved"
ok '[ "$(grep -c card-a "$T/resume.log" 2>/dev/null)" = 0 ]' "no forgery ran resume for A's card"
ok '[ -n "$IA" ] && [ "$(grep -F "\"$IA\"" "$R/$(ix .untrusted_events)" 2>/dev/null | grep -c approval-decision)" -ge 2 ]' "the worker's forged lines did land in the untrusted stream (the forgery was really attempted; needs W1)"
;;
adapters) # the shipped adapters: Discord over the stack's Discord helper (fake Hermes interpreter), host-cli, and the shipped rows' argv
ok 'has approvals.py' "precondition: bin/approvals.py exists"
ok '$PY $B/stella_data.py validate channels "$CH" >/dev/null 2>&1' "the shipped channels file validates (schema channels)"
DC=$(jq -r --arg lk "$CHLK" '[.[$lk][]? | select(.kind == "discord") | .id][0] // empty' "$CH")
HC=$(jq -r --arg lk "$CHLK" '[.[$lk][]? | select(.kind == "host-cli") | .id][0] // empty' "$CH")
ok '[ -n "$DC" ] && [ -n "$HC" ] && jq -e --arg lk "$CHLK" "[.[\$lk][] | .deliver[0], .collect[0]] + [.resume.argv[0]] | all(startswith(\"/\") | not)" "$CH" >/dev/null' "the shipped rows and resume name their scripts relative to the stack root (no path literal)"
# the Discord helper with a fake Hermes interpreter (as bin/escalation-thread-selftest.sh): threads, posts and fetched messages are files
mkdir -p "$T/bin"; printf 'ALERT_TARGET="discord:#alerts"\n' >"$T/sup/limits.env"
{ grep -vE "^(OWNER_TIMEZONE|OWNER_DISCORD_USER_ID|ESCALATIONS_CHANNEL_ID|DISCORD_GUILD_ID|SUPERVISOR_CHANNEL_ID)=" "$H/config/owner.example.env"
  cat "$OWNER_CONFIG"; printf "ESCALATIONS_CHANNEL_ID='100'\nDISCORD_GUILD_ID='200'\nSUPERVISOR_CHANNEL_ID='300'\n"; } >"$T/owner-full.env"
export OWNER_CONFIG=$T/owner-full.env   # the Discord helper loads the whole owner config (the example's keys plus made-up ids)
cat >"$T/bin/fakepy" <<'S'
#!/usr/bin/env bash
cat >/dev/null   # args: -I - <action> <channel> [<name or content>]
echo "$3 $4" >> "$ESCALATE_SUP_DIR/discord_calls"
case "$3" in
  create_thread) printf '%s\n' "$5" >> "$ESCALATE_SUP_DIR/threads"; env -u HOME jq -nc --arg n "$5" '{success: true, thread_id: "555", name: $n}';;
  send_message) printf 'send %s %s\n---\n' "$4" "$5" >> "$ESCALATE_SUP_DIR/sends"; echo '{"success": true, "message_id": "m1"}';;
  fetch_messages) cat "$ESCALATE_SUP_DIR/msgs_$4" 2>/dev/null || echo '{"messages":[]}';;
  *) echo '{"error": "unexpected action"}';;
esac
S
chmod +x "$T/bin/fakepy"
export HERMES_PY=$T/bin/fakepy
jq --arg lk "$CHLK" '.resume = {argv: ["'"$T/resume.sh"'"], timeout_s: 10}' "$CH" >"$T/ch.new" && cat "$T/ch.new" >"$CH"
A=$(act settings:QUEUE_MAX dz); ID=$(mkreq dz write "$A" card-dz 120)
$AP deliver "$ID" --channel "$DC" >"$T/o" 2>&1; rc=$?
ok '[ -n "$ID" ] && [ $rc = 0 ] && jq -e --arg c "$DC" ".deliveries[\$c] == \"555\"" "$STORE/requests/$ID.json" >/dev/null 2>&1' "Discord deliver: one thread in the escalations channel, its id is the message ref the store keeps"
ok 'grep -q "^create_thread 100$" "$T/sup/discord_calls" && grep -qF "$ID" "$T/sup/threads" && grep -q "^send 555 " "$T/sup/sends" && grep -qF "zz summary dz" "$T/sup/sends" && ! grep -qF "$(rf dz nonce)" "$T/sup/sends"' "the thread is named for the request; the summary is posted in it; the nonce is never posted"
$AP deliver "$ID" --channel "$DC" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ "$(grep -c "^create_thread" "$T/sup/discord_calls")" = 1 ]' "delivering the same request again shows it once (no second thread)"
ok 'grep -qF "\"op\":\"set\"" "$T/sup/sends" && grep -qF "\"target\":\"settings:QUEUE_MAX\"" "$T/sup/sends" && grep -qF "$(jq -r .new_digest "$A")" "$T/sup/sends" && grep -qF "$(rf dz digest)" "$T/sup/sends"' "GB-5 the Discord message shows the exact action (op, target, new_digest) and the digest the answer binds to"
msg() { jq -nc --arg i "$1" --arg c "$2" --arg u "$3" --argjson b "${4:-false}" '{id: $i, content: $c, author: {id: $u, username: "u", bot: $b}}'; }
jq -nc --argjson a "$(msg 3 "approve" "$OTHER_ID")" --argjson b "$(msg 2 "what is this" "$OWNER_ID")" --argjson s "$(msg 1 "Approve" 999 true)" '{messages: [$a, $b, $s]}' >"$T/sup/msgs_555"
collect "$DC"; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-828 && [ "$(stat_of "$ID")" = pending ]' "Discord collect: another user's \"approve\" in the thread is refused STL-OWN-828; a bot message and other text are no answer"
jq -nc --argjson a "$(msg 4 "Approve, go ahead" "$OWNER_ID")" '{messages: [$a]}' >"$T/sup/msgs_555"
collect "$DC"; rc=$?
ok '[ $rc = 0 ] && [ "$(stat_of "$ID")" = approved ] && [ "$(ndec "$ID")" = 1 ] && [ "$(grep -c card-dz "$T/resume.log" 2>/dev/null)" = 1 ]' "Discord collect: the owner's \"Approve\" in the request's thread is accepted once; resume ran for its card"
collect "$DC"; rc=$?
ok '[ $rc = 0 ] && [ "$(ndec "$ID")" = 1 ]' "a decided request is no longer collected (its thread is not read again)"
A2=$(act settings:QUEUE_MAX hz); ID2=$(mkreq hz write "$A2" card-hz 120)
$AP deliver "$ID2" --channel "$HC" >"$T/o" 2>&1; rc=$?
ok '[ -n "$ID2" ] && [ $rc = 0 ] && c "approvals.py answer $ID2" && jq -e --arg c "$HC" ".deliveries[\$c] | length > 0" "$STORE/requests/$ID2.json" >/dev/null 2>&1' "host-cli deliver: says how to answer on the host, and gives a ref"
A3=$(act settings:QUEUE_MAX hy); ID3=$(mkreq hy write "$A3" card-hy 120)
$AP deliver "$ID3" --channel "$HC" >"$T/o" 2>&1; rc=$?
ok '[ -n "$ID3" ] && [ $rc = 0 ] && c "\"op\":\"set\"" && c "settings:QUEUE_MAX" && c "$(jq -r .new_digest "$A3")" && c "$(rf hy digest)"' "GB-5 host-cli deliver shows the exact action (op, target, new_digest) and the digest"
collect "$HC"; rc=$?
ok '[ $rc = 0 ] && [ "$(stat_of "$ID2")" = pending ]' "host-cli collect: nothing (its answers come through approvals.py answer)"
$AP request --class zz-no-class --action "$A2" --summary s --card card-x --ttl 60 --json >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-829 && ! grep -q Traceback "$T/o"' "a request of a class the request schema does not know: refused STL-OWN-829"
EU="$PY $B/event_untrusted.py"
STUB_WORKER_MARK=1 $EU append --type approval-ask --what card-bad --detail '{"class": "write", "action": "not an action", "summary": "s", "card": "card-bad"}' >/dev/null 2>&1
$AP intake --json >"$T/i" 2>"$T/o"; rc=$?
ok '[ $rc = 0 ] && c STL-OWN-829 && [ "$(jq length "$T/i")" = 0 ]' "intake: an ask that is not well formed makes no request (STL-OWN-829 named), the run goes on"
mkdir -p "$T/kb"; printf '#!/usr/bin/env bash\necho "$*" >>"%s/kb/calls"\n' "$T" >"$T/kb/hermes"; chmod +x "$T/kb/hermes"
RS=$R/$(jq -r '.resume.argv[0]' "$H/$CHREL")
echo '{"decision": "denied"}' | PATH=$T/kb:$BASEPATH "$RS" t_zz000001 denied >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -qE "^kanban --board [^ ]+ unblock --reason .*denied.* t_zz000001$" "$T/kb/calls"' "the shipped resume unblocks the card on the stack's board, the decision in the reason"
;;
expiry) # Gate A correction: the first host command that sees a pending request past expires_at settles it: one trusted "expired" line, resume once
ok 'has approvals.py' "precondition: bin/approvals.py exists"
stubkind discord; setresume
DC=$(jq -r --arg lk "$CHLK" '[.[$lk][]? | select(.kind == "discord") | .id][0] // "zz-discord"' "$CH"); [ "$DC" = zz-discord ] && addchan zz-discord discord
nexp() { grep -F "\"$1\"" "$LOG" 2>/dev/null | grep '"approval-decision"' | grep -c '"expired"'; }
ID=$(mkreq e1 write "$(act settings:QUEUE_MAX e1)" card-e1 2); $AP deliver "$ID" --channel "$DC" >/dev/null 2>&1; REF=$(lastref "$DC")
ok '[ -n "$ID" ] && [ "$(stat_of "$ID")" = pending ] && [ "$(ndec "$ID")" = 0 ] && [ ! -s "$T/resume.log" ]' "before expiry: pending, no decision line, no resume"
sleep 3
$AP status "$ID" --json >"$T/s1" 2>"$T/s1.err" & $AP status "$ID" --json >"$T/s2" 2>"$T/s2.err" & wait
ok 'jq -e ".status == \"expired\"" "$T/s1" >/dev/null && jq -e ".status == \"expired\"" "$T/s2" >/dev/null' "two status calls at once past expires_at: both say expired"
ok '[ "$(ndec "$ID")" = 1 ] && [ "$(nexp "$ID")" = 1 ]' "exactly one trusted decision line, and it says expired"
ok 'pl_dec "$ID" "$(rf e1 digest)" expired' "the expired line is trusted: in proof_lines() with the request's digest"
ok '[ "$(grep -c card-e1 "$T/resume.log" 2>/dev/null)" = 1 ] && grep -q "card-e1 expired" "$T/resume.log"' "resume ran once for the card, with the word expired"
$AP wait "$ID" >"$T/o" 2>&1; rc=$?
ok '[ $rc != 0 ] && c expired && [ "$(ndec "$ID")" = 1 ] && [ "$(grep -c card-e1 "$T/resume.log")" = 1 ]' "wait afterwards: non-zero, expired; no second line, no second resume"
answer "$DC" "$ID" "$(rf e1 nonce)" approved "$OWNER_ID" "$REF" "$(rf e1 digest)"; collect "$DC"; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-822 && [ "$(ndec "$ID")" = 1 ] && [ "$(ndeca "$ID")" = 0 ] && [ "$(stat_of "$ID")" = expired ]' "a late owner answer: refused STL-OWN-822, still one line, never an approval"
ID2=$(mkreq e2 write "$(act settings:QUEUE_MAX e2)" card-e2 2); ID3=$(mkreq e3 write "$(act settings:QUEUE_MAX e3)" card-e3 2); sleep 3
$AP intake --json >/dev/null 2>"$T/o"
ok '[ -n "$ID2" ] && [ "$(nexp "$ID2")" = 1 ] && [ "$(nexp "$ID3")" = 1 ] && [ "$(grep -c "card-e[23] expired" "$T/resume.log")" = 2 ]' "intake settles every overdue request it sees: one expired line and one resume each, with no status call"
st $AP answer "$ID2" --decision approved >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-OWN-822 && [ "$(nexp "$ID2")" = 1 ] && [ "$(ndeca "$ID2")" = 0 ]' "host-cli answer after expiry: refused STL-OWN-822, no second line"
ID4=$(mkreq e4 write "$(act settings:QUEUE_MAX e4)" card-e4 2); sleep 3
collect "$DC"; ok '[ "$(nexp "$ID4")" = 1 ] && [ "$(grep -c "card-e4 expired" "$T/resume.log")" = 1 ]' "collect settles an overdue request too (one line, one resume)"
ID5=$(mkreq e5 write "$(act settings:QUEUE_MAX e5)" card-e5 60)
ok '[ "$(stat_of "$ID5")" = pending ] && [ "$(ndec "$ID5")" = 0 ]' "a request within its ttl is left pending by the same commands"
;;
r10) # the F1c tester's wave-2+3 pass R10 (D3: digest binding, first decision stands, store is no proof, host kind policy), unchanged
ok 'has approvals.py' "precondition: bin/approvals.py exists"
$OA init-key >/dev/null 2>&1; setresume
# host-side trusted line through the one writer (event_log.append), as approvals.py writes its decisions
tl() { $PY - "$B" "$@" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import event_log as el
rid, dec, dg = sys.argv[2:5]
el.append(el.build("approval-decision", rid, new={"request_id": rid, "decision": dec, "digest": dg}, who={"channel": "host-cli"}), scrub_detail=False)
PY
}
A=$(act settings:QUEUE_MAX r10a); IA=$(mkreq r10a write "$A" card-r10a 300)
tl "$IA" approved "$(d64 other-action)" >"$T/o" 2>&1; rc=$?
ok '[ -n "$IA" ] && [ $rc = 0 ] && [ "$(stat_of "$IA")" = pending ]' "(a) a trusted approved decision line with another digest: the request stays pending"
B_=$(act settings:QUEUE_MAX r10b); IB=$(mkreq r10b write "$B_" card-r10b 300)
$AP answer "$IB" --decision approved >"$T/o" 2>&1
tl "$IB" denied "$(rf r10b digest)" >"$T/o" 2>&1; rc=$?
ok '[ -n "$IB" ] && [ $rc = 0 ] && [ "$(stat_of "$IB")" = approved ]' "(b) a later trusted denied line for an approved request: the first decision stands (approved)"
C_=$(act settings:QUEUE_MAX r10c); IC=$(mkreq r10c write "$C_" card-r10c 300); X=$(act settings:CALL_TIMEOUT r10x)
jq --slurpfile x "$X" --arg d "$(adig "$X")" '.action = $x[0] | .target = $x[0].target | .digest = $d' "$STORE/requests/$IC.json" >"$T/s" && cat "$T/s" >"$STORE/requests/$IC.json"
$AP answer "$IC" --decision approved >"$T/o" 2>&1; rc=$?
ok '[ -n "$IC" ] && [ $rc = 1 ] && [ "$(ndec "$IC")" = 0 ]' "(c) a request whose stored action was changed after its trusted line: the host answer is refused, no decision line"
D_=$(act settings:QUEUE_MAX r10d); ID_=$(mkreq r10d write "$D_" card-r10d 300); HK=$(jq -r .host_kind "$CH")
polset '.channel_kinds[$k] = false' --arg k "$HK"
$AP answer "$ID_" --decision approved >"$T/o" 2>&1; rc=$?
ok '[ -n "$ID_" ] && [ $rc = 1 ] && c STL-OWN-826 && [ "$(stat_of "$ID_")" = pending ]' "(d) channel_kinds[$HK] = false: the host answer is refused STL-OWN-826, still pending"
;;
crt1) # Gate B CRT-1 (GB-4 intake): a non-string detail, a line or a detail nested past the recursion limit cost their line only; a FIFO stream is refused, unchanged
ok 'has approvals.py' "precondition: bin/approvals.py exists"
EU="$PY $B/event_untrusted.py"
stubkind discord; stubkind host-cli; setresume
UT=$R/$(ix .untrusted_events); mkdir -p "$(dirname "$UT")"
A=$(act settings:QUEUE_MAX crt1)
ASK=$(jq -nc --slurpfile a "$A" '{class: "write", action: $a[0], summary: "zz crt1", card: "card-crt1"}')
nreq() { ls "$STORE/requests" 2>/dev/null | grep -c '\.json$'; }
# control: a valid ask alone becomes one request
STUB_WORKER_MARK=1 $EU append --type approval-ask --what card-crt1 --detail "$ASK" >/dev/null 2>&1
$AP intake >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ "$(nreq)" = 1 ]' "control: one valid ask, intake exit 0, one request"
# case 1: a worker writes one ask line whose detail is a JSON object (not a string), then a second valid ask
printf '%s\n' '{"type":"approval-ask","trusted":false,"global_id":"zz-crt1-bad","detail":{"class":"write"}}' >>"$UT"
STUB_WORKER_MARK=1 $EU append --type approval-ask --what card-crt1b --detail "$(jq -c '.card = "card-crt1b"' <<<"$ASK")" >/dev/null 2>&1
$AP intake >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ "$(nreq)" = 2 ]' "a non-string detail costs its own line only: the next valid ask still becomes a request (rc=$rc, requests=$(nreq), $(codes "$T/o"))"
# case 2: a line nested 100000 deep (json.loads raises RecursionError, which is no ValueError)
grep -v zz-crt1-bad "$UT" >"$T/ut.keep"; cat "$T/ut.keep" >"$UT"; head -c 100000 /dev/zero | tr '\0' '[' >>"$UT"; echo >>"$UT"
STUB_WORKER_MARK=1 $EU append --type approval-ask --what card-crt1c --detail "$(jq -c '.card = "card-crt1c"' <<<"$ASK")" >/dev/null 2>&1
$AP intake >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ "$(nreq)" -ge 3 ]' "a line nested past the recursion limit costs its own line only (rc=$rc, requests=$(nreq), $(codes "$T/o"))"
# case 2b: the same through the sanctioned command only: event_untrusted.py --detail with a string nested 100000 deep (the line
# itself is depth 2 and under 1 MiB, so the writer takes it; intake's json.loads(detail) raises RecursionError)
grep -v '^\[\[\[' "$UT" >"$T/ut.keep"; cat "$T/ut.keep" >"$UT"
STUB_WORKER_MARK=1 $EU append --type approval-ask --what card-crt1d --detail "$(head -c 100000 /dev/zero | tr '\0' '[')" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ]' "precondition: a worker writes the deep detail through event_untrusted.py (rc=$rc)"
STUB_WORKER_MARK=1 $EU append --type approval-ask --what card-crt1e --detail "$(jq -c '.card = "card-crt1e"' <<<"$ASK")" >/dev/null 2>&1
N0=$(nreq); $AP intake >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && grep -lq "card-crt1e" "$STORE"/requests/*.json 2>/dev/null' "an ask written through event_untrusted.py with a deeply nested detail costs its own line only: the next ask (card-crt1e) becomes a request (rc=$rc, $(codes "$T/o"))"
# case 3: a FIFO at the stream path: intake must refuse within seconds, never hang
rm -f "$UT"; mkfifo "$UT"
timeout 15 $AP intake >"$T/o" 2>&1; rc=$?
ok '[ $rc != 124 ]' "a FIFO planted at the untrusted stream path is refused, not waited on (rc=$rc; 124 = intake hung)"
;;
rt4) # Gate B RT-4 (GB-4 intake): a deeply nested line or detail between asks is skipped, every later intake goes on, unchanged
ok 'has approvals.py' "precondition: bin/approvals.py exists"
stubkind discord; stubkind host-cli; setresume
US=$R/$(ix .untrusted_events); EU="$PY $B/event_untrusted.py"
ask() { $EU append --type approval-ask --what "card-$1" --source worker --detail "$(jq -nc --arg c "card-$1" --arg o "$(d64 o$1)" --arg n "$(d64 n$1)" '{class: "write", action: {op: "set", target: "zz-t", old_digest: $o, new_digest: $n}, summary: "zz ask", card: $c}')" >/dev/null 2>&1; }
nreq() { ls "$STORE/requests" 2>/dev/null | grep -c '\.json$'; }
ask a1
as_worker marker python3 -I -c 'import sys; open(sys.argv[1], "ab").write(b"[" * 200000 + b"\n")' "$US"
ask a2
$AP intake >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ "$(nreq)" = 2 ]' "a nested line between two asks: intake goes on and makes both requests (got exit $rc, $(nreq) request(s): $(grep -oE "[A-Za-z]+Error" "$T/o" | head -1))"
$AP intake >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ "$(nreq)" = 2 ]' "a second intake: no failure, the later ask is taken (got exit $rc, $(nreq) request(s))"
# the same through the ask's own detail (a well-formed approval-ask line whose detail is nested JSON), on a stream without the first line
: >"$US"
as_worker marker python3 -I -c 'import json, sys, uuid; open(sys.argv[1], "ab").write((json.dumps({"schema_version": 3, "trusted": False, "type": "approval-ask", "what": "x", "global_id": str(uuid.uuid4()), "detail": "[" * 200000}) + "\n").encode())' "$US"
ask a3
$AP intake >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ "$(nreq)" -ge 2 ] && [ -n "$(grep -l card-a3 "$STORE"/requests/*.json 2>/dev/null)" ]' "an ask whose detail is nested JSON: refused as data, the next ask is taken (got exit $rc, $(nreq) request(s))"
;;
rt5) # Gate B RT-5 (GB-4 intake): a FIFO at the untrusted stream is refused with a code at once, unchanged
ok 'has approvals.py' "precondition: bin/approvals.py exists"
stubkind discord; stubkind host-cli; setresume
US=$R/$(ix .untrusted_events); mkdir -p "$(dirname "$US")"; rm -f "$US"
as_worker marker mkfifo "$US"
ok '[ -p "$US" ]' "setup: a worker made the untrusted stream a FIFO"
timeout 20 $AP intake >"$T/o" 2>&1; rc=$?
ok '[ $rc != 124 ]' "approvals.py intake does not hang on a FIFO stream (got exit $rc; 124 = killed after 20 s)"
timeout 20 $AP intake >"$T/o" 2>&1; rc=$?   # fold note: ok() removed $T/o after the case above; the same command again for this one
ok '[ $rc = 1 ] && c "STL-"' "approvals.py intake refuses the FIFO stream with a code (got exit $rc)"
$PY $B/event_untrusted.py append --type note --what x >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c STL-CFG-318' "control: event_untrusted.py append refuses the FIFO at once (318)"
;;
crt7) # Gate B CRT-7 (GB-5): the delivered request carries the action's new value, unchanged
ok 'has approvals.py' "precondition: bin/approvals.py exists"
EU="$PY $B/event_untrusted.py"
stubkind discord; stubkind host-cli; setresume
DC=$(jq -r --arg lk "$CHLK" '[.[$lk][]? | select(.kind == "discord") | .id][0]' "$CH")
ACT=$(jq -nc --arg o "$(d64 old-crt7)" '{op: "set", target: "settings:QUEUE_MAX", old_digest: $o, new: "zz-real-value-999"}')
ASK=$(jq -nc --argjson a "$ACT" '{class: "write", action: $a, summary: "set QUEUE_MAX to zz-harmless-1", card: "card-crt7"}')
STUB_WORKER_MARK=1 $EU append --type approval-ask --what card-crt7 --detail "$ASK" >/dev/null 2>&1
$AP intake >"$T/o" 2>&1; rc=$?
REQ=$(ls "$T/ans/$DC.req."* 2>/dev/null | tail -n1)
ok '[ $rc = 0 ] && [ -n "$REQ" ]' "precondition: the ask was delivered on $DC"
ok 'grep -q zz-real-value-999 "$REQ" 2>/dev/null' "the delivered request carries the action's new value, so the owner can see what the digest approves (payload keys: $(jq -c keys "$REQ" 2>/dev/null))"
;;
rt7) # Gate B RT-7 (GB-5): the delivered request carries the action's op and new value, unchanged
ok 'has approvals.py' "precondition: bin/approvals.py exists"
stubkind discord; stubkind host-cli; setresume
DET=$(jq -nc --arg o "$(d64 o7)" '{class: "delete", action: {op: "delete-all-backups", target: "zz-backups", old_digest: $o, new: "nothing left"}, summary: "read the weather forecast (harmless)", card: "card-rt7"}')
$PY $B/event_untrusted.py append --type approval-ask --what card-rt7 --source worker --detail "$DET" >/dev/null 2>&1
$AP intake >"$T/o" 2>&1; rc=$?
REQ=$(ls "$T/ans/"*.req.* 2>/dev/null | head -1)
ok '[ $rc = 0 ] && [ -s "$REQ" ]' "setup: intake made the request and delivered it to a stub adapter (exit $rc)"
ok 'jq -e ".summary" "$REQ" >/dev/null' "info: the adapter got the agent's summary: $(jq -r .summary "$REQ" 2>/dev/null)"
ok 'grep -q "delete-all-backups" "$REQ"' "the delivered request carries the action's op the decision binds to"
ok 'grep -q "nothing left" "$REQ"' "the delivered request carries the action's new value the decision binds to"
;;
gb4) # Gate B GB-4: one rule for every untrusted input approvals.py parses (the agents' stream in intake, adapter output in collect): the writer's size and depth limits, every failure reported with a code and skipped, never the end of the run
ok 'has approvals.py' "precondition: bin/approvals.py exists"
stubkind discord; stubkind host-cli; setresume
DC=$(jq -r --arg lk "$CHLK" '[.[$lk][]? | select(.kind == "discord") | .id][0]' "$CH")
EU="$PY $B/event_untrusted.py"; UT=$R/$(ix .untrusted_events); mkdir -p "$(dirname "$UT")"
nreq() { ls "$STORE/requests" 2>/dev/null | grep -c '\.json$'; }
ASK=$(jq -nc --slurpfile a "$(act settings:QUEUE_MAX g4)" '{class: "write", action: $a[0], summary: "zz g4", card: "card-g4"}')
gl() { jq -nc --arg d "$1" --arg g "$(uuid)" '{schema_version: 3, trusted: false, type: "approval-ask", what: "x", global_id: $g, detail: $d}' >>"$UT"; }
python3 -I -c 'import sys; open(sys.argv[1], "ab").write(b"\"" + b"a" * (1 << 20) + b"\"\n" + b"\xff\xfe{\n")' "$UT"
gl '[1]'; gl "$(printf '%.0s[' $(seq 20))$(printf '%.0s]' $(seq 20))"; gl '{"class": ["write"], "action": {"op": 1}, "summary": 2, "card": 3}'
STUB_WORKER_MARK=1 $EU append --type approval-ask --what card-g4 --detail "$ASK" >/dev/null 2>&1
$AP intake >"$T/o" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ "$(nreq)" = 1 ] && [ "$(grep -c "^STL-CFG-318 " "$T/o")" = 2 ] && [ "$(grep -c "^STL-OWN-829 " "$T/o")" = 3 ] && ! grep -qE "unexpected|Traceback" "$T/o"' "intake: a line over the writer's size limit, a line that is not JSON, a detail that is a list, one nested past the writer's depth and one of wrong shapes: each reported (318 / 829) and skipped, the next ask becomes a request"
mv "$UT" "$T/ut.real"; ln -s "$T/ut.real" "$UT"
$AP intake >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && c "^STL-CFG-318 " && [ "$(nreq)" = 1 ]' "intake: a stream that is a symbolic link is refused STL-CFG-318, nothing read through it"
rm -f "$UT"; mv "$T/ut.real" "$UT"
ID=$(ls "$STORE/requests" | sed -n 's/\.json$//p' | head -1); $AP deliver "$ID" --channel "$DC" >/dev/null 2>&1; REF=$(lastref "$DC")
NONCE=$(jq -r .nonce "$STORE/requests/$ID.json")
{ head -c 100000 /dev/zero | tr '\0' '['; echo; echo 'not json'; echo '[1, 2]'; echo '{"request_id": 5, "nonce": [], "decision": {}, "user": null, "message_ref": 1}'
  python3 -I -c 'print("\"" + "a" * (1 << 20) + "\"")'; } >>"$T/ans/$DC.in"
answer "$DC" "$ID" "$NONCE" approved "$OWNER_ID" "$REF"
collect "$DC"; rc=$?
ok '[ -n "$ID" ] && [ $rc = 1 ] && [ "$(grep -c "^STL-OWN-830 " "$T/o")" = 5 ] && ! grep -qE "unexpected|Traceback" "$T/o" && [ "$(stat_of "$ID")" = approved ]' "collect: a line nested past the recursion limit, one not JSON, one of wrong shapes (twice) and one over the size limit: each refused STL-OWN-830; the owner's answer after them is decided"
;;
gb5) # Gate B GB-5: what a channel gets to show the owner is the exact action (op, target, new or new_digest) and the digest; new is masked when the target names a secret or a value pattern hides it
ok 'has approvals.py' "precondition: bin/approvals.py exists"
stubkind discord; setresume
DC=$(jq -r --arg lk "$CHLK" '[.[$lk][]? | select(.kind == "discord") | .id][0]' "$CH")
# shown <tag> <target> <new JSON>: a request of that action delivered on the stub; its payload in $T/p-<tag>
shown() { jq -nc --arg t "$2" --arg o "$(d64 "o$1")" --argjson n "$3" '{op: "set", target: $t, old_digest: $o, new: $n}' >"$T/act-$1.json"
  local id; id=$(mkreq "$1" write "$T/act-$1.json" "card-$1" 120); $AP deliver "$id" --channel "$DC" >/dev/null 2>&1; cp "$T/ans/$DC.req.$(cat "$T/ans/$DC.n")" "$T/p-$1"; }
pv() { jq -c "$2" "$T/p-$1" 2>/dev/null; }
shown g1 settings:QUEUE_MAX 7
ok '[ "$(pv g1 .action)" = "{\"op\":\"set\",\"target\":\"settings:QUEUE_MAX\",\"new\":7}" ] && [ "$(pv g1 .digest)" = "\"$(rf g1 digest)\"" ] && [ "$(pv g1 .digest)" = "\"$(adig "$T/act-g1.json")\"" ]' "a plain value: the payload shows op, target and new as they are, and the digest of that action"
shown g2 owner-settings:ZZ_API_TOKEN '"plain-zz-secret-1"'
ok '[ "$(pv g2 .action.new)" = "\"***\"" ] && [ "$(pv g2 .action.op)" = "\"set\"" ] && ! grep -rqF plain-zz-secret-1 "$T/p-g2" "$LOG"' "a target whose key is a secret (a redact pattern): new is ***, never in the payload or the log"
shown g3 settings:QUEUE_MAX '"Bearer zzabc123def"'
ok '[ "$(pv g3 .action.new)" = "\"***\"" ] && ! grep -qF zzabc123def "$T/p-g3"' "a value a value pattern of the catalog matches: new is ***"
shown g4 connections '{"api_key": "zzzzzzzz2", "name": "zz-visible"}'
ok '[ "$(pv g4 .action.new)" = "{\"api_key\":\"***\",\"name\":\"zz-visible\"}" ] && ! grep -qF zzzzzzzz2 "$T/p-g4"' "an object value: the keys a redact pattern names are ***, the rest is shown"
shown g5 owner-settings '"PLAIN_ZZ=plain-zz-secret-3"'
ok '[ "$(pv g5 .action.new)" = "\"***\"" ] && ! grep -qF plain-zz-secret-3 "$T/p-g5"' "a scalar for a whole row that has redact keys: masked whole (as the event log masks it)"
ID=$(mkreq g6 write "$(act settings:QUEUE_MAX g6)" card-g6 120); $AP deliver "$ID" --channel "$DC" >/dev/null 2>&1; cp "$T/ans/$DC.req.$(cat "$T/ans/$DC.n")" "$T/p-g6"
ok '[ "$(pv g6 .action.new_digest)" = "\"$(jq -r .new_digest "$T/act-g6.json")\"" ] && [ "$(pv g6 ".action | keys")" = "[\"new_digest\",\"op\",\"target\"]" ]' "an action by digest: op, target and new_digest are shown"
;;
esac
finish
