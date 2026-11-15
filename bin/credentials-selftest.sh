#!/usr/bin/env bash
# Hermetic self-test for bin/credentials.py (F2 W4: the one interface for keys, body B8, design D3 with design-check DC-05).
# A scratch root (STELLA_ROOT, a copy of the tree's bin, data and docs); the backend is set with jq in the scratch routing data.
# Cases: the shipped backend holds no key (check says so, get is refused); a folder backend inside a protected state path is read
# (get returns the exact value in-process, check names no value and is true only when every name is held); a key file that is a
# symbolic link, has a second hard link, is readable by others, lies behind a linked folder, is empty or holds a line break, and a
# name that is no file name, are refused; a folder backend outside the protected state paths is refused with the data; a worker
# environment is refused; no command prints a value; no value is in any output of a refusal.
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/credentials-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
R=$T/root; mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$T/home" "$T/tmp" "$T/sup/logs" "$T/o" "$T/pb"
cp -r "$H/bin" "$H/.stella" "$H/docs" "$R/"
IDX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IDX"; }
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$H/$(ix .role_table)" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT
for v in $(jq -r '.worker_signals.token_env[]?' "$R/$(ix '.files[] | select(.id == "owner-auth") | .path')" 2>/dev/null); do unset "$v"; done
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH   # the board stub: no worker run
fails=0
ok() { if ( eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
RT=$R/.stella/routing.json; ed() { jq "$@" "$RT" >"$RT.n" && mv "$RT.n" "$RT"; }
cred() { timeout 60 python3 -I "$R/bin/credentials.py" "${@:2}" >"$T/o/$1.json" 2>"$T/o/$1.err"; RC=$?; }   # <name> <arguments>...
# in-process, one line per name: get() "<name> value <value>", check() "<name> held True|False", or "<name> refused <code> <problem>"
cat >"$T/drive.py" <<'P'
import sys
sys.path.insert(0, sys.argv[1])
import credentials
for n in sys.argv[3:]:
    try:
        print(n, "value", credentials.get(n)) if sys.argv[2] == "get" else print(n, "held", credentials.check([n]))
    except credentials.Refused as e:
        print(n, "refused", e.code, e.problem)
P
drive() { timeout 60 python3 -I "$T/drive.py" "$R/bin" "${@:2}" >"$T/o/$1.out" 2>"$T/o/$1.err"; RC=$?; }   # <name> get|check <secret names>...
KEY="stkey$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
KIND=$(jq -r '.credentials as $c | $c.backends[$c.backend].kind' "$RT")

# ---- the shipped backend ----
cred s1 check --json ST_ONE_KEY; a=$RC; drive s1g get ST_ONE_KEY
ok '[ $KIND != dir ] && [ $a = 1 ] && jq -e --arg k "$KIND" ".kind == \$k and .ok == false and .missing == [\"ST_ONE_KEY\"]" "$T/o/s1.json" && grep -q STL-MDL-728 "$T/o/s1.err" && grep -q "^ST_ONE_KEY refused STL-MDL-728 " "$T/o/s1g.out"' \
  "the shipped backend holds no key: check says its kind and ok false, get is refused (STL-MDL-728)"

# ---- a folder backend inside a protected state path ----
CD=$(ix .backup_dir)/st-keys; D=$R/$CD; mkdir -p "$D"; chmod 700 "$D"
ed --arg p "$CD" '.credentials.backend = "st-dir" | .credentials.backends["st-dir"] = {kind: "dir", path: $p}'
put() { (umask 077; printf "$2" >"$D/$1"); }   # <name> <printf format of the value>
put ST_ONE_KEY "$KEY"; put ST_NEWLINE_KEY "$KEY\n"; put ST_EMPTY_KEY ""; put ST_OPEN_KEY "$KEY"; chmod 644 "$D/ST_OPEN_KEY"
put ST_TWICE_KEY "$KEY"; ln "$D/ST_TWICE_KEY" "$T/second-name"; put elsewhere "$KEY"; mv "$D/elsewhere" "$T/elsewhere"; ln -s "$T/elsewhere" "$D/ST_LINK_KEY"
put .ST_DOT_KEY "$KEY"; mkdir -p "$D/sub"; put sub/ST_SUB_KEY "$KEY"
cred f1 check --json ST_ONE_KEY; a=$RC; drive f1g get ST_ONE_KEY
ok '[ $a = 0 ] && jq -e ".backend == \"st-dir\" and .kind == \"dir\" and .ok == true and .missing == []" "$T/o/f1.json" && [ "$(cat "$T/o/f1g.out")" = "ST_ONE_KEY value $KEY" ] && ! grep -qF -- "$KEY" "$T/o/f1.json" "$T/o/f1.err"' \
  "a folder backend is read: get returns the exact value in-process, check says ok and names no value"
cred f2 check --json ST_ONE_KEY ST_ABSENT_KEY; a=$RC; drive f2c check ST_ONE_KEY ST_ABSENT_KEY
ok '[ $a = 1 ] && jq -e ".ok == false and .missing == [\"ST_ABSENT_KEY\"]" "$T/o/f2.json" && grep -q STL-MDL-728 "$T/o/f2.err" && [ "$(cat "$T/o/f2c.out")" = "ST_ONE_KEY held True
ST_ABSENT_KEY held False" ]' "check lists a name the backend lacks (exit 1) and is true only when every name asked for is held"
drive bad get ST_LINK_KEY ST_TWICE_KEY ST_OPEN_KEY ST_NEWLINE_KEY ST_EMPTY_KEY ST_ABSENT_KEY .ST_DOT_KEY sub/ST_SUB_KEY ../st-keys/ST_ONE_KEY ""
ok '[ "$(grep -c " refused STL-MDL-728 " "$T/o/bad.out")" = 10 ] && ! grep -q " value " "$T/o/bad.out" && ! grep -qF -- "$KEY" "$T/o/bad.out" "$T/o/bad.err"' \
  "refused, with no value in the message: a symbolic link, a second hard link, mode 0644, a line break, an empty file, a missing file, and names that are no plain file name (a leading dot, a folder part, a parent part, empty)"
mv "$D" "$D-moved"; ln -s "$D-moved" "$D"; drive way get ST_ONE_KEY; rm "$D"; mv "$D-moved" "$D"
ok 'grep -q "^ST_ONE_KEY refused STL-MDL-728 " "$T/o/way.out"' "a key folder that is a symbolic link is refused, also when it leads to a folder inside the protected state path"
cred u1 get ST_ONE_KEY; a=$RC; cred u2 check --value ST_ONE_KEY
ok '[ $a = 2 ] && [ $RC = 2 ] && ! grep -qF -- "$KEY" "$T/o/u1.json" "$T/o/u1.err" "$T/o/u2.json" "$T/o/u2.err"' "no command prints a value: anything but check is a usage error (2)"

# ---- a worker environment; a backend outside the protected state paths ----
export STUB_WORKER_MARK=1; cred w1 check --json ST_ONE_KEY; a=$RC; drive w1g get ST_ONE_KEY; unset STUB_WORKER_MARK
ok '[ $a = 1 ] && grep -q STL-CFG-312 "$T/o/w1.err" && [ ! -s "$T/o/w1.json" ] && grep -q "^ST_ONE_KEY refused STL-CFG-312 " "$T/o/w1g.out" && ! grep -qF -- "$KEY" "$T/o/w1g.out" "$T/o/w1.err"' \
  "check and get refuse in a worker environment (STL-CFG-312), no value"
mkdir -p "$R/st-open"; (umask 077; printf '%s' "$KEY" >"$R/st-open/ST_ONE_KEY"); ed '.credentials.backends["st-dir"].path = "st-open"'
drive out get ST_ONE_KEY
ok 'grep -q "^ST_ONE_KEY refused STL-CFG-310 " "$T/o/out.out" && ! grep -qF -- "$KEY" "$T/o/out.out"' "a folder backend outside the protected state paths is refused with the data that names it (STL-CFG-310), nothing read"
echo "# credentials-selftest: $fails failed"; [ $fails = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
