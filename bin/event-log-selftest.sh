#!/usr/bin/env bash
# Hermetic self-test for bin/event_log.py (F1 W3): the one writer of the event log. Runs in a scratch root (STELLA_ROOT: a copy of
# .stella/ and the role table); never the live log. Proves: a valid line is appended, masked (index redact_keys, registry
# `secret` settings) before it is written or printed; an invalid line is refused and nothing is written; the log is only ever
# appended to; tail --json; an unwritable log refuses with STL-CFG-318; concurrent appends do not interleave; (F1b W6, T7d) every
# new line has global_id and install_id, a repeated global_id or an unreadable install id is refused, old lines still read.
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d -t event-log-selftest.XXXXXX); trap 'rm -rf "$T"' EXIT
R=$T/root; mkdir -p "$R/docs/hermes-local" "$R/config" "$R/.supervisor/logs"
cp -r "$H/.stella" "$R/"; jq '.worker_markers = ["STUB_WORKER_MARK"]' "$H/docs/hermes-local/roles.json" >"$R/docs/hermes-local/roles.json"
cp -r "$H/docs/hermes-local/hooks" "$R/docs/hermes-local/hooks"   # the table check looks hook files up under the root
# a registry setting marked secret, in a data file that has no redact_keys of its own
jq --arg g "$(python3 -I -c "import uuid; print(uuid.uuid4())")" '.entries += [(.entries[2] | .global_id = $g | .key = "PLANTED_SETTING" | .sensitivity = "secret" | .type = "string" | .validation = {} | .default = null | .store.key = "PLANTED_SETTING")]' \
  "$R/.stella/settings.json" > "$T/s" && mv "$T/s" "$R/.stella/settings.json"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"   # a fake owner file: no failure message makes the alert code read the real one
export STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env
# F1c W1: the CLI asks bin/worker_env.py, which asks `roles.py prove` the board: a stub board (no running card), never the real one
mkdir -p "$T/pb"; printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; BASEPATH=$PATH; export PATH=$T/pb:$PATH
unset STUB_WORKER_MARK; for v in $(jq -r ".worker_signals.token_env[]" "$R/.stella/owner-auth.json"); do unset "$v"; done
EL="python3 -I $H/bin/event_log.py"
LOG=$R/.supervisor/logs/events.jsonl
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }

ok 'o=$(python3 -I $H/bin/stella_data.py check) && [ "$(echo "$o" | head -1)" = "data OK" ]' "the scratch root validates"
ok '$EL append --type note --what first >/dev/null && [ "$(wc -l <"$LOG")" = 1 ] && jq -e ".schema_version == 3 and .type == \"note\" and (.time | test(\"Z$\"))" "$LOG" >/dev/null' "a valid line is appended as one JSON line"
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
# ---- round 2 (fix round 1): whole lines, honest readers, escaped text, masking, symbolic links ----
rm -rf "$LOG"; : >"$LOG"; chmod 600 "$LOG"
$EL append --type seed --what s1 >/dev/null
printf '{"schema_version":1,"time":"2026-01-01T00:00:00Z","type":"apply"' >>"$LOG"   # a fragment: no newline (a killed writer)
$EL append --type after --what s2 >/dev/null
ok '[ "$(tail -c 1 "$LOG" | od -An -tx1 | tr -d " ")" = 0a ] && [ "$($EL tail --json -n 9 2>/dev/null | jq "map(.what) | join(\",\")" -r)" = "s1,s2" ]' "G6 a log that ends in a fragment: the next line starts on its own line and is readable"
$EL tail -n 9 >"$T/o" 2>"$T/e"; rc=$?
ok '[ $rc = 0 ] && grep -q "STL-CFG-318.*1 line" "$T/e" && ! grep -q Traceback "$T/e"' "G6 tail reports the one line that is not an event: one coded line on stderr, exit 0"
printf '[]\n"x"\n5\n' >>"$LOG"
ok '$EL tail --json -n 99 >"$T/o" 2>"$T/e"; [ $? = 0 ] && ! grep -q Traceback "$T/e" && grep -q "STL-CFG-318.*4 line" "$T/e"' "G6 a line that is JSON but not an object is counted, never a traceback (4 bad lines)"
$EL append --type lsep --what s3 --detail "a$(printf '\xe2\x80\xa8')b$(printf '\xc2\x85')c" >/dev/null
ok '[ -z "$(tail -n 1 "$LOG" | LC_ALL=C tr -d "\000-\177")" ] && [ "$(tail -n 1 "$LOG" | wc -l)" = 1 ] && $EL tail --json -n 1 2>/dev/null | jq -e ".[0].what == \"s3\"" >/dev/null' "G6 a written line holds only ASCII: U+2028 and NEL cannot split it for a reader"
cp "$LOG" "$T/before"; mv "$LOG" "$T/log.real"; cp "$T/before" "$R/.supervisor/logs/real.jsonl"; ln -s real.jsonl "$LOG"
$EL append --type t --what x >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-318 "$T/o" && cmp -s "$T/before" "$R/.supervisor/logs/real.jsonl"' "G2 a log that is a symbolic link (inside the root) is refused (318), its target untouched"
rm "$LOG" "$R/.supervisor/logs/real.jsonl"; mv "$T/log.real" "$LOG"
ok '$EL append --type t --what x --code STL-CFG-""399 >"$T/o" 2>&1; [ $? = 1 ] && grep -q STL-CFG-313 "$T/o"' "G6 a code that is not in the alert catalog is refused"
ok '$EL append --type t --what x --code STL-CFG-313 >/dev/null 2>&1' "G6 a code in the catalog is accepted"
$EL append --type t --what x --old not-json >"$T/o" 2>&1
ok '! grep -q "not-json" "$T/o"' "G7 a usage error does not echo the argument"
$EL append --type change --what owner-settings --old '"plant-scalar-1"' --new '{"WORKER_GIT_NAME":"plant-id-2"}' >"$T/o" 2>&1
ok '! grep -rq "plant-scalar-1" "$R" && ! grep -q "plant-scalar" "$T/o" && tail -n 1 "$LOG" | jq -e ".old == \"***\" and .new.WORKER_GIT_NAME == \"plant-id-2\"" >/dev/null' "G6 a scalar old of a row with redact keys is masked whole; an identity_critical setting shows its value"
python3 -I -c "
import sys; sys.path.insert(0, '$H/bin'); import event_log as e
e.SECRETS.add('plant-detail-9'); e.append(e.build('note', 'x', detail='see plant-detail-9 here'))" >/dev/null 2>&1
ok '! grep -q "plant-detail-9" "$LOG" && tail -n 1 "$LOG" | jq -e ".detail == \"see *** here\"" >/dev/null' "G6 the detail passes through the same scrub as an error message"
S=$(stat -c %s "$LOG"); LIM=$( (ulimit -f 64; trap '' XFSZ; head -c 200000 /dev/zero >"$T/probe" 2>/dev/null; stat -c %s "$T/probe") )
$EL append --type fill --what f --detail "$(head -c $((LIM - S - 400)) /dev/zero | tr '\0' x)" >/dev/null 2>&1; S=$(stat -c %s "$LOG")
( ulimit -f 64; trap '' XFSZ; $EL append --type big --what g --detail "$(head -c 600 /dev/zero | tr '\0' y)" ) >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-318 "$T/o" && [ "$(stat -c %s "$LOG")" = $S ] && [ "$(tail -c 1 "$LOG" | od -An -tx1 | tr -d " ")" = 0a ]' "G6 a short write: refused (318), the file is cut back to the size it had (no partial line)"
# ---- round 3 (fix round 2) ----
$EL append --type t --what x --new '{"API_TOKEN":"plant-cli-77"}' --detail "see plant-cli-77 here" >/dev/null 2>&1
ok '! grep -q "plant-cli-77" "$LOG" && tail -n 1 "$LOG" | jq -e ".detail == \"see *** here\"" >/dev/null' "H7 --detail is scrubbed with the values masked in the same call, through the command line"
$EL append --type "$(printf 'x\ny')" --what w >/dev/null 2>&1
ok '[ "$($EL tail -n 1 2>/dev/null | wc -l)" = 1 ]' "H7 tail escapes the type it prints (a newline in it makes no second line)"
deep() { python3 -I -c 'import sys; n=int(sys.argv[1]); print("{\"a\":"*n + "1" + "}"*n)' "$1"; }
printf '{"schema_version":1,"time":"2026-01-01T00:00:00Z","type":"note","who":{"role":null,"channel":null,"user":"x"},"what":"deep","old":%s}\n' "$(deep 600)" >>"$LOG"
$EL tail -n 3 >"$T/o" 2>"$T/e"; rc=$?
ok '[ $rc = 0 ] && ! grep -q Traceback "$T/e" && grep -q "STL-CFG-318" "$T/e"' "H8 a deeply nested line is counted as unreadable, tail goes on"
S=$(stat -c %s "$LOG"); $EL append --type t --what x --old "$(deep 100)" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-313 "$T/o" && [ "$(stat -c %s "$LOG")" = $S ]' "H8 the writer refuses a line the reader would not read back"
rm -f "$LOG"; mkfifo "$LOG"; timeout 20 $EL append --type t --what x >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-318 "$T/o"' "H8 an event log that is a FIFO is refused (318), no hang (exit $rc)"
rm -f "$LOG"; : >"$LOG"; chmod 600 "$LOG"
rm -rf "$R/.supervisor/logs"
$EL append --type fresh --what f >/dev/null 2>&1
ok '[ "$(wc -l <"$LOG")" = 1 ] && [ "$(stat -c %a "$R/.supervisor/logs")" != "" ]' "G7 a missing log folder is created"
rm "$LOG"; mkdir "$LOG"
$EL append --type t --what x >"$T/o" 2>&1; rc=$?
ok '[ $rc != 0 ] && grep -q "STL-CFG-318" "$T/o"' "an unwritable log: non-zero, STL-CFG-318 and its plain message"
$EL append --type t --what x >"$T/o" 2>&1; ok 'grep -qi "event log" "$T/o"' "the message is the catalog's plain text"
# ---- round 4 (rung 2, fix round 1) ----
rmdir "$LOG"; $EL append --type r4 --what x >/dev/null 2>&1; printf 'not an event line\n' >>"$LOG"
$EL tail >"$T/o" 2>"$T/e"; rc=$?
ok '[ $rc = 0 ] && grep -q STL-CFG-318 "$T/e" && ! grep -q "A change was not made" "$T/e"' "R4 a reader's 318 line does not say a change was not made (P2)"
cp "$LOG" "$T/before"; ln "$LOG" "$T/second-link"; $EL append --type t --what x >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-318 "$T/o" && cmp -s "$LOG" "$T/before"' "R4 a log with a second hard link is not appended to (318), unchanged (W3-CV3-05 d)"
rm "$T/second-link"
mkdir -p "$T/cs/x/logs"; ln -s x "$T/cs/X"
python3 -I -c "
import os, sys; sys.path.insert(0, sys.argv[1]); import event_log as e
os.close(e.open_dir(sys.argv[2] + '/x/logs'))
try:
    os.close(e.open_dir(sys.argv[2] + '/X/logs')); sys.exit(1)
except ValueError:
    sys.exit(0)" "$H/bin" "$T/cs"
ok '[ $? = 0 ]' "R4 a folder on the way that is a link to a sibling differing only by case is refused at the open (W3-CV3-05 c)"
cp "$LOG" "$T/before"
python3 -I -c "
import sys; sys.path.insert(0, sys.argv[1]); import event_log as e
e.prepare(e.build('note', 'x'))
try:
    e.prepare(e.build('note', 'x', detail='y' * (e.WRITE_MAX + 1))); sys.exit(1)
except e.EventError as x:
    sys.exit(0 if x.code == 'STL-CFG-313' else 1)" "$H/bin"
ok '[ $? = 0 ] && cmp -s "$LOG" "$T/before"' "R4 a line is judged (shape, size) without being written: prepare() writes nothing and refuses a line too large (W3-CV3-07)"
# ---- round 5 ----
python3 -I -c "
import sys; sys.path.insert(0, sys.argv[1]); import event_log as e
e.SECRETS.update({'1', 'sekrit-q'})
t = e.scrub('look at backup folder 00000051-20260101T101010000000Z: 1 and sekrit-q, (+1 more)')
sys.exit(0 if t == 'look at backup folder 00000051-20260101T101010000000Z: *** and ***, (+*** more)' else 1)" "$H/bin"
ok '[ $? = 0 ]' "R5 a short masked value is masked where it stands whole, never inside the tool's own text (a folder name) (W3-CRT4-09)"
# ---- round 6 ----
# R1: every system call locked() makes is found by a counting run; an interrupt before it or right after it leaves no held lock
python3 -I -c "
import fcntl, os, sys, tempfile
sys.path.insert(0, sys.argv[1]); import event_log as el
class Stop(BaseException): pass
p = os.path.join(tempfile.mkdtemp(dir=sys.argv[2]), 'lk')
names = [(os, 'open'), (os, 'fstat'), (os, 'lstat'), (os, 'readlink'), (os, 'close'), (fcntl, 'flock')]
real = {x: getattr(*x) for x in names}
bad = []
def run(n, after):
    cnt = [0]
    def wrap(x):
        def w(*a, **k):
            cnt[0] += 1
            if cnt[0] == n and not after: raise Stop
            r = real[x](*a, **k)
            if cnt[0] == n and after: raise Stop
            return r
        return w
    for x in names: setattr(*x, wrap(x))
    try:
        with el.locked(p): pass
    except Stop: pass
    finally:
        for x in names: setattr(*x, real[x])
    fd = os.open(p, os.O_RDWR | os.O_CREAT)
    try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError: print('a held lock is left after an interrupt at call', n, 'after' if after else 'before'); sys.exit(1)   # the next try would wait for it for ever
    finally: os.close(fd)
    return cnt[0]
N = run(0, False)
for n in range(1, N + 1):
    for after in (False, True): run(n, after)
print(N, bad); sys.exit(1 if bad or N < 6 else 0)" "$H/bin" "$T" >"$T/lk" 2>&1; rc=$?
ok '[ $rc = 0 ]' "R6 an interrupt at each system call of locked() (before it and right after it; the calls are counted, not listed) leaves no held lock (W3-CV5-01): $(tail -n 1 "$T/lk")"
# W3-CRT5-06: a log this append creates and then cannot finish (an interrupt or a failure at any call after the create) is removed again
rm -f "$LOG"; python3 -I -c "
import os, sys
sys.path.insert(0, sys.argv[1]); import event_log as el
class Stop(BaseException): pass
names, bad = ['fstat', 'pread', 'write', 'fsync'], []
real = {n: getattr(os, n) for n in names}
p = el.log_path()
for n in names:
    for after in (False, True):
        hit = []
        def w(*a, **k):
            if os.readlink(f'/proc/self/fd/{a[0]}') != p: return real[n](*a, **k)
            hit.append(1)
            if not after: raise Stop
            real[n](*a, **k); raise Stop
        setattr(os, n, w)
        try: el.append(el.build('note', 'x'))
        except Stop: pass
        finally: setattr(os, n, real[n])
        if hit and os.path.lexists(p): bad.append((n, after))
        if os.path.lexists(p): os.unlink(p)
print(bad); sys.exit(1 if bad else 0)" "$H/bin" >"$T/mk" 2>&1; rc=$?
ok '[ $rc = 0 ] && [ ! -e "$LOG" ]' "R6 a log that an append creates and cannot write its line to is removed again, whatever call stops it: the event log is as before (W3-CRT5-06): $(tail -n 1 "$T/mk")"
$EL append --type note --what x >/dev/null 2>&1; ok '[ $? = 0 ] && [ "$(wc -l <"$LOG")" = 1 ]' "R6 and the next append creates the log and writes its line"
# ---- F1b W6 (T7d): every new line carries global_id and install_id; lines from before stay as they are and still read ----
IID=$(jq -r .install_id "$R/.stella/install.json"); SD="python3 -I $H/bin/stella_data.py"
U4='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
rm -f "$LOG"; printf '%s\n' '{"schema_version":1,"time":"2026-01-01T00:00:00Z","type":"apply","who":{"role":null,"channel":null,"user":"owner"},"what":"features","detail":"backup b1 token t1"}' >"$LOG"; chmod 600 "$LOG"
cp "$LOG" "$T/before"; $EL append --type note --what w6a >/dev/null 2>&1; $EL append --type note --what w6b >/dev/null 2>&1
ok 'tail -n 2 "$LOG" | jq -se --arg i "$IID" --arg u "$U4" "length == 2 and all(.schema_version == 3 and .install_id == \$i and (.global_id | test(\$u))) and .[0].global_id != .[1].global_id" >/dev/null' "T7d each new line has schema_version 3 (F1c W1; was 2), its own global_id (UUID4) and this install's install_id"
ok 'head -c "$(wc -c <"$T/before")" "$LOG" | cmp -s - "$T/before"' "T7d a line written before the ids is never rewritten"
ok '$EL tail --json -n 3 2>"$T/e" | jq -e ".[0].what == \"features\" and .[0].schema_version == 1 and (.[0] | has(\"global_id\") | not)" >/dev/null && [ ! -s "$T/e" ]' "T7d tail reads an old line (version 1, no ids) by its position and fields, not as unreadable"
python3 -I $H/bin/stella-apply.py history features --json >"$T/o" 2>"$T/e"; rc=$?
ok '[ $rc = 0 ] && jq -e ".unreadable_lines == 0 and (.events | map(.detail) | index(\"backup b1 token t1\") != null)" "$T/o" >/dev/null' "T7d stella-apply history still finds an old line by its what (exit $rc)"
sed -n 1p "$LOG" >"$T/ev1.json"; sed -n 2p "$LOG" >"$T/ev2.json"
ok '$SD validate event "$T/ev1.json" >/dev/null && $SD validate event "$T/ev2.json" >/dev/null' "T7d the event schema accepts an old line (version 1) and a new one (version 3 since F1c W1)"
ok '! $SD validate event <(jq -c ".global_id = \"x\"" "$T/ev2.json") >/dev/null 2>&1 && ! $SD validate event <(jq -c ".install_id = \"x\"" "$T/ev2.json") >/dev/null 2>&1' "T7d a global_id or install_id that is not a UUID is refused by the schema"
G=$(tail -n 1 "$LOG" | jq -r .global_id); cp "$LOG" "$T/before"
python3 -I -c "
import sys, uuid; sys.path.insert(0, sys.argv[1]); import event_log as e
g = str(uuid.uuid4())
assert e.append({**e.build('note', 'own'), 'global_id': g})['global_id'] == g   # a caller's own new id is kept
for d in (g, sys.argv[2]):
    try:
        e.append({**e.build('note', 'dup'), 'global_id': d}); sys.exit(1)
    except e.EventError as x:
        assert x.code == 'STL-CFG-313', x.code" "$H/bin" "$G" 2>/dev/null
ok '[ $? = 0 ] && [ "$(wc -l <"$LOG")" = $(( $(wc -l <"$T/before") + 1 )) ] && head -c "$(wc -c <"$T/before")" "$LOG" | cmp -s - "$T/before" && ! grep -q "\"dup\"" "$LOG"' "T7d a caller's own new global_id is kept; a line whose global_id repeats one already in the log is refused (313), nothing written"
python3 -I -c "
import sys; sys.path.insert(0, sys.argv[1]); import event_log as e
e.append({**e.build('note', 'v1shape'), 'schema_version': 1, 'install_id': '00000000-0000-4000-8000-000000000000'})" "$H/bin" 2>/dev/null
ok 'tail -n 1 "$LOG" | jq -e --arg i "$IID" --arg u "$U4" ".what == \"v1shape\" and .schema_version == 3 and .install_id == \$i and (.global_id | test(\$u))" >/dev/null' "T7d a caller's line in the old shape, or naming another install, is written as version 3 (F1c W1; was 2) with this install's ids"
cp "$R/.stella/install.json" "$T/install.keep"
for how in 'jq "del(.install_id)" "$T/install.keep" >"$R/.stella/install.json"' 'rm "$R/.stella/install.json"'; do
  eval "$how"; cp "$LOG" "$T/before"; $EL append --type note --what noid >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && grep -q STL-CFG-310 "$T/o" && cmp -s "$LOG" "$T/before" && ! grep -q Traceback "$T/o"' "T7d the install id cannot be read ($how): refused with STL-CFG-310, no line written"
done
cp "$T/install.keep" "$R/.stella/install.json"
cp "$R/.stella/data-files.json" "$T/index.keep"
for plant in '(.files[] | select(.schema == "versions")) |= del(.global_id)' '(.files[] | select(.schema == "data-files")).owner_only = false'; do
  jq "$plant" "$T/index.keep" >"$R/.stella/data-files.json"
  cp "$LOG" "$T/before"; $EL append --type note --what idxbad >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 0 ] && ! $SD check >/dev/null 2>&1 && [ "$(wc -l <"$LOG")" = $(( $(wc -l <"$T/before") + 1 )) ] && tail -n 1 "$LOG" | jq -e --arg i "$IID" ".what == \"idxbad\" and .install_id == \$i" >/dev/null' "T7d an index problem outside the install row does not stop a line: the install id is read by the install row's own check (W6-CVER-01; $plant; exit $rc)"
done
cp "$T/index.keep" "$R/.stella/data-files.json"
echo '{"schema_version":1,"id":"r1","requested_at":"2026-11-10T12:00:00Z","requester":{"role":"builder","channel":null,"user":null},"approval_class":"post","action":"a","summary":"s","target":null,"card":null,"expires_at":null}' >"$T/rq.json"
echo '{"schema_version":1,"request_id":"r1","decided_at":"2026-11-10T12:01:00Z","decision":"approved","decided_by":{"channel":"app","user":"owner"},"note":null}' >"$T/dc.json"
ids() { jq --arg g "$(python3 -I -c 'import uuid; print(uuid.uuid4())')" --arg i "$IID" ".schema_version = 2 | .global_id = \$g | .install_id = \$i" "$1"; }
for k in rq:approval-request dc:approval-decision; do
  ok '$SD validate ${k#*:} "$T/${k%%:*}.json" >/dev/null && $SD validate ${k#*:} <(ids "$T/${k%%:*}.json") >/dev/null' "T7d ${k#*:}: an old record (version 1) and one with global_id and install_id (version 2) validate"
  ok '! $SD validate ${k#*:} <(ids "$T/${k%%:*}.json" | jq ".global_id = \"r1\"") >/dev/null 2>&1 && ! $SD validate ${k#*:} <(ids "$T/${k%%:*}.json" | jq ".install_id = 5") >/dev/null 2>&1' "T7d ${k#*:}: a global_id or install_id that is not a UUID is refused"
done
# ---- F1c W1 (T6a, T6b, T6c event-log cases; design D1, codes STL-EVT-901..906): the chained trusted log, verify, proof_lines(),
# the agents' untrusted stream. The guard cases of T6c (state_paths, hooks) belong to W4a's selftests. ----
ixr() { jq -r "$1" "$R/.stella/data-files.json"; }
STATE=$R/$(ixr .event_writer_state); UNT=$R/$(ixr .untrusted_events); WID=$(ixr .event_writer_id); POL=$R/.stella/owner-auth.json
EU="python3 -I $H/bin/event_untrusted.py"
uuid() { python3 -I -c "import uuid; print(uuid.uuid4())"; }
hex64() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
V() { $EL verify --json >"$T/v" 2>"$T/e"; echo $?; }
prob() { jq -e --arg c "$1" --argjson l "$2" '.problems | any(.code == $c and .line == $l)' "$T/v" >/dev/null 2>&1; }
probc() { jq -e --arg c "$1" '.problems | any(.code == $c)' "$T/v" >/dev/null 2>&1; }
snap() { cat "$LOG" "$STATE" 2>/dev/null | sha256sum; }
rm -f "$LOG" "$STATE"
( umask 000; for w in a1 a2 a3 a4; do $EL append --type note --what $w >/dev/null 2>&1; done )
ok '[ "$(wc -l <"$LOG")" = 4 ] && jq -s -e --arg w "$WID" --arg i "$IID" "all(.schema_version == 3 and .writer == {id: \$w, install_id: \$i} and (.mac | test(\"^[0-9a-f]{64}$\"))) and ([.[].seq] == [1, 2, 3, 4]) and ([range(1; 4) as \$k | .[\$k].prev == .[\$k - 1].mac] | all) and (.[0].prev as \$g | (\$g | type == \"string\" and length > 0) and ([.[].mac] | index([\$g]) == null))" "$LOG" >/dev/null' "W1 each line: schema_version 3, writer {index event_writer_id, this install}, seq +1, prev = the previous mac (a genesis value first), mac 64 hex"
L4=$(tail -n 1 "$LOG")
ok '[ -f "$STATE" ] && [ ! -L "$STATE" ] && [ "$(stat -c %a "$STATE")" = 600 ] && [ "$(stat -c %h "$STATE")" = 1 ] && jq -e --argjson s 4 --arg m "$(jq -r .mac <<<"$L4")" "([.. | numbers] | index([\$s]) != null) and ([.. | strings] | index([\$m]) != null)" "$STATE" >/dev/null' "W1 the writer state: 0600 even under umask 000, one link, holds the last seq and mac"
r=$(V); ok '[ $r = 0 ] && jq -e ".problems == [] and (.legacy | if type == \"array\" then length else . end) == 0" "$T/v" >/dev/null' "W1 verify --json: an untouched log passes"
$EL verify >"$T/o" 2>&1; ok '[ $? = 0 ]' "W1 verify (plain): an untouched log passes"
cp "$LOG" "$T/good"; cp -p "$STATE" "$T/sgood"
rs() { cp "$T/good" "$LOG"; rm -f "$STATE"; cp -p "$T/sgood" "$STATE"; }
unch() { jq -c --arg g "$(uuid)" '.schema_version = 2 | .global_id = $g | .what = "inserted" | del(.writer, .seq, .prev, .mac)' <<<"$L4"; }
forge() { jq -c --arg g "$(uuid)" --arg m "$(hex64)" "$1"' | .global_id = $g | .seq = (.seq + 1) | .prev = .mac | .mac = $m | .what = "forged"' <<<"$L4"; }
tamper() {   # tamper <shell that changes $LOG> <code> <line, or - for any> <name>
  local r c=$2 l=$3; rs; eval "$1"; r=$(V)
  ok '[ $r = 1 ] && if [ $l = - ]; then probc $c; else prob $c $l; fi' "W1 verify: $4: exit 1, $c"; }
tamper 'sed -i "2s/\"what\":\"a2\"/\"what\":\"a2x\"/" "$LOG"' STL-EVT-901 2 "an edited line (line 2)"
tamper 'sed -i "2s/\"what\":\"a2\"/\"what\":\"evil\",\"what\":\"a2\"/" "$LOG"' STL-EVT-901 2 "a duplicate key added to a line (parses to the same object; line 2)"
tamper 'sed -i 2d "$LOG"' STL-EVT-902 - "a deleted middle line"
tamper 'sed -i "\$d" "$LOG"' STL-EVT-902 - "a deleted last line (tail behind the writer state)"
tamper 'awk "NR == 2 { k = \$0; next } NR == 3 { print; print k; next } { print }" "$T/good" >"$LOG"' STL-EVT-903 - "lines 2 and 3 swapped"
tamper 'awk -v x="$(unch)" "NR == 3 { print x } { print }" "$T/good" >"$LOG"' STL-EVT-904 3 "an unchained line inserted after the chain started (line 3)"
tamper 'unch >>"$LOG"' STL-EVT-904 5 "an unchained line appended (line 5)"
tamper 'forge . >>"$LOG"' STL-EVT-901 5 "a next-seq line with a made-up mac (line 5)"
tamper 'forge ".writer.id = \"zz-other\"" >>"$LOG"' STL-EVT-906 5 "a forged writer id (line 5)"
tamper 'forge ".writer.install_id = \"$(uuid)\"" >>"$LOG"' STL-EVT-906 5 "a forged install id (line 5)"
tamper 'tail -n 1 "$T/good" >>"$LOG"' STL-EVT-903 5 "a genuine line replayed at the end (line 5)"
$EL verify >"$T/o" 2>&1; ok '[ $? = 1 ] && grep -q STL-EVT-903 "$T/o"' "W1 verify (plain): a problem exits 1 and prints its code"
for how in 'rm -f "$STATE"' 'chmod 644 "$STATE"' 'mv "$STATE" "$T/sreal"; ln -s "$T/sreal" "$STATE"' 'ln "$STATE" "$T/slink2"'; do
  rs; eval "$how"; r=$(V); ok '[ $r = 1 ] && probc STL-EVT-905' "W1 writer state unsafe ($how): verify exit 1, STL-EVT-905"
  $EL append --type note --what after >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && grep -q STL-EVT-905 "$T/o" && cmp -s "$LOG" "$T/good"' "W1 writer state unsafe ($how): append refused (905), nothing written (no new genesis)"
  rm -f "$STATE" "$T/sreal" "$T/slink2"
done
rs; jq 'del(.key)' "$T/sgood" >"$STATE"; chmod 600 "$STATE"; r=$(V); ok '[ $r = 1 ] && probc STL-EVT-905' "W1 a writer state without its key: verify exit 1, STL-EVT-905"
# the crash window: the line is written, the state is not (killed between): the next append continues the chain from that line
rs; $EL append --type note --what a5 >/dev/null 2>&1; cp -p "$T/sgood" "$STATE"
r=$(V); ok '[ $r = 0 ]' "W1 a log one genuine line ahead of the writer state (a writer killed between line and state) verifies"
$EL append --type note --what a6 >/dev/null 2>&1; r=$(V)
ok '[ $r = 0 ] && [ "$(tail -n 1 "$LOG" | jq .seq)" = 6 ] && jq -e ".seq == 6" "$STATE" >/dev/null' "W1 the next append continues from that line (seq 6), the state catches up"
# legacy lines (v1/v2) before the chain: reported as legacy, never a problem, never rewritten
rm -f "$LOG" "$STATE"
for k in 1 2; do jq -c --arg g "$(uuid)" --arg w "legacy$k" '.schema_version = 2 | .global_id = $g | .what = $w | del(.writer, .seq, .prev, .mac)' <<<"$L4" >>"$LOG"; done
cp "$LOG" "$T/before"; $EL append --type note --what c1 >/dev/null 2>&1; $EL append --type note --what c2 >/dev/null 2>&1
r=$(V); ok '[ $r = 0 ] && jq -e ".problems == [] and ((.legacy | if type == \"array\" then length else . end) == 2)" "$T/v" >/dev/null && head -c "$(wc -c <"$T/before")" "$LOG" | cmp -s - "$T/before"' "W1 two legacy v2 lines then a chain: verify exit 0, legacy 2, the old lines unchanged"
# worker environments: the writer (append, verify: it reads the key) refuses for every signal (STL-CFG-312); the untrusted stream takes them
SIGNALS="marker user sandbox worktree board-worker board-down policy-unreadable $(jq -r '.worker_signals.token_env[] | "token:" + .' "$POL" | tr '\n' ' ')"
fp() { echo "$(cat /proc/sys/kernel/random/boot_id):$(sed 's/.*) //' /proc/1/stat | awk '{print $20}')|$(sed 's/.*) //' /proc/$1/stat | awk '{print $20}')"; }
mkdir -p "$T/pb-down" "$T/pb-worker"; printf '#!/usr/bin/env bash\nexit 1\n' >"$T/pb-down/hermes"
cat >"$T/pb-worker/hermes" <<S
#!/usr/bin/env bash
case " \$* " in
  *" list "*) echo '[{"id":"c1"}]';;
  *" show "*) echo '{"task":{"id":"c1","assignee":"w"},"runs":[{"id":7,"ended_at":null}],"events":[{"kind":"claimed","run_id":7,"payload":{"lock":"h:1"}},{"kind":"worker_bound","run_id":7,"payload":{"pid":$$,"claim_lock":"h:1","started_at":"$(fp $$)"}}]}';;
  *) exit 1;;
esac
S
chmod +x "$T"/pb-*/hermes
as_worker() {   # as_worker <signal> <cmd...>: exactly that signal present; the policy is restored after
  local s=$1 pb=$T/pb cwd=$T rc envs=(STUB_NOTHING=1); shift
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
  esac
  (cd "$cwd" && env "${envs[@]}" PATH="$pb:$BASEPATH" "$@"); rc=$?
  cp -p "$T/pol.keep" "$POL"; rm -f "$T/sandbox-flag"
  return $rc; }
$EL append --type note --what owner-seed >/dev/null 2>&1
for s in $SIGNALS; do
  S0=$(snap); as_worker "$s" $EL append --type capability-used --what "zz-forge-$s" >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && grep -q STL-CFG-312 "$T/o" && [ "$(snap)" = "$S0" ]' "W1 worker signal $s: event_log.py append refused (STL-CFG-312), log and state untouched"
  as_worker "$s" $EL verify --json >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 1 ] && grep -q STL-CFG-312 "$T/o" && [ "$(snap)" = "$S0" ]' "W1 worker signal $s: event_log.py verify (it reads the key) refused (STL-CFG-312)"
  as_worker "$s" $EU append --type approval-decision --what "zz-unt-$s" --source "zz-src-$s" >"$T/o" 2>&1; rc=$?
  ok '[ $rc = 0 ] && tail -n 1 "$UNT" | jq -e --arg w "zz-unt-$s" --arg s "zz-src-$s" ".trusted == false and .what == \$w and .source == \$s and .type == \"approval-decision\" and (has(\"seq\") or has(\"mac\") or has(\"prev\") or has(\"writer\") | not)" >/dev/null && [ "$(snap)" = "$S0" ]' "W1 worker signal $s: event_untrusted.py appends a \"trusted\": false line (no chain fields) to the untrusted stream; the trusted log and state untouched"
done
ok 'tail -n 1 "$UNT" | jq -e --arg i "$IID" "(.global_id | test(\"^[0-9a-f-]{36}$\")) and .install_id == \$i and .schema_version == 3" >/dev/null && python3 -I $H/bin/stella_data.py validate event <(tail -n 1 "$UNT") >/dev/null' "W1 an untrusted line has its own global_id and this install's id, and passes the event schema"
ok '[ -f "$H/bin/event_untrusted.py" ] && ! grep -nE "^\s*(import|from)\s+(event_log|owner_auth|hmac)\b|event_writer_state|owner_key" "$H/bin/event_untrusted.py" >/dev/null' "W1 event_untrusted.py imports no writer, key or chain code"
cp "$UNT" "$T/ubefore"
$EU append --type t --what "$(head -c $((1 << 20)) /dev/zero | tr '\0' x)" >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-313 "$T/o" && ! grep -q Traceback "$T/o" && cmp -s "$UNT" "$T/ubefore"' "W1 an untrusted line beyond the writer's size limit is refused (313), nothing written"
$EU append --type "" --what w >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-313 "$T/o" && cmp -s "$UNT" "$T/ubefore"' "W1 an untrusted line with an empty type is refused (313)"
mv "$UNT" "$T/ureal"; ln -s "$T/ureal" "$UNT"; $EU append --type t --what w >"$T/o" 2>&1; rc=$?
ok '[ $rc = 1 ] && grep -q STL-CFG-318 "$T/o" && cmp -s "$T/ureal" "$T/ubefore"' "W1 an untrusted stream that is a symbolic link is refused (318), its target untouched"
rm "$UNT"; mv "$T/ureal" "$UNT"
$EU bogus >/dev/null 2>&1; ok '[ $? = 2 ]' "W1 event_untrusted.py usage error exits 2"
# proof_lines(): only chained lines whose mac verifies, each once; forged, unchained and untrusted lines count for nothing
PL() { python3 -I -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import event_log as e; print(json.dumps(e.proof_lines()))' "$H/bin" >"$T/pl" 2>"$T/e"; }
rm -f "$LOG" "$STATE"
for w in capability-used:zz-cap-genuine approval-decision:zz-appr-genuine qa-pass:zz-qa-genuine; do $EL append --type ${w%%:*} --what ${w#*:} >/dev/null 2>&1; done
cp "$LOG" "$T/good"; L3=$(tail -n 1 "$T/good")
PL; ok 'jq -e "[.[].what] == [\"zz-cap-genuine\", \"zz-appr-genuine\", \"zz-qa-genuine\"]" "$T/pl" >/dev/null' "W1 proof_lines() on an untouched chain: the three lines, in file order"
for ty in capability-used approval-decision qa-pass; do
  jq -c --arg t "$ty" --arg g "$(uuid)" --arg m "$(hex64)" '.type = $t | .what = "zz-forged-chained-" + $t | .global_id = $g | .seq = (.seq + 1) | .prev = .mac | .mac = $m' <<<"$L3" >>"$LOG"
  jq -c --arg t "$ty" --arg g "$(uuid)" '.type = $t | .what = "zz-forged-plain-" + $t | .global_id = $g | del(.seq, .prev, .mac)' <<<"$L3" >>"$LOG"
done
sed -n 2p "$T/good" >>"$LOG"; grep -m1 zz-unt- "$UNT" >>"$LOG"
r=$(V); PL
ok '[ $r = 1 ] && jq -e "[.[].what] == [\"zz-cap-genuine\", \"zz-appr-genuine\", \"zz-qa-genuine\"] and all(has(\"mac\") and .trusted != false)" "$T/pl" >/dev/null' "W1 forged chained and unchained lines, a replayed approval and an untrusted line copied in: verify fails, proof_lines() keeps the three genuine lines once"
rm -f "$STATE"; PL; ok '[ ! -s "$T/pl" ] && grep -q STL-EVT-905 "$T/e"' "W1 proof_lines() with the chain present and the state missing raises STL-EVT-905 (never an empty proof)"
rm -f "$LOG"; PL; ok '[ -s "$T/pl" ] && jq -e ". == []" "$T/pl" >/dev/null' "W1 proof_lines() with no chain and no state: []"
# the key never leaves the state: not in the log, the untrusted stream, any output or alert line
rm -f "$LOG" "$STATE"; $EL append --type note --what k1 >"$T/out1" 2>&1; $EL verify --json >>"$T/out1" 2>&1; $EL tail --json >>"$T/out1" 2>&1
K=$(jq -r .key "$STATE" 2>/dev/null)
ok '[ ${#K} -ge 32 ] && ! grep -rqF -- "$K" "$LOG" "$UNT" "$T/out1" "$T/sup" 2>/dev/null' "W1 the writer key (in the state only) is in no log line, untrusted line, output or alert"
$EL bogus >/dev/null 2>&1; ok '[ $? = 2 ]' "usage error exits 2"
[ $fails = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
