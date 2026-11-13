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
cp -r "$H/docs/hermes-local/hooks" "$R/docs/hermes-local/hooks"   # the table check looks hook files up under the root
# a registry setting marked secret, in a data file that has no redact_keys of its own
jq --arg g "$(python3 -I -c "import uuid; print(uuid.uuid4())")" '.entries += [(.entries[2] | .global_id = $g | .key = "PLANTED_SETTING" | .sensitivity = "secret" | .type = "string" | .validation = {} | .default = null | .store.key = "PLANTED_SETTING")]' \
  "$R/.stella/settings.json" > "$T/s" && mv "$T/s" "$R/.stella/settings.json"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"   # a fake owner file: no failure message makes the alert code read the real one
export STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env
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
$EL bogus >/dev/null 2>&1; ok '[ $? = 2 ]' "usage error exits 2"
[ $fails = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
