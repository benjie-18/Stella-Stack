#!/usr/bin/env bash
# Rows for bin/roles-selftest.sh (S3A-03, S3A-04), kept apart so the live selftest file stays untouched: roles.py validate
# checks complete_metadata (a non-empty object of non-empty text pairs) and complete_needs_review (true or false) on every role.
# Same invocation as the K8 validation rows of roles-selftest.sh: ROLES_FILE=<modified table copy> roles.py reviewers, exit 1 and
# "roles: INVALID ... role <r>: <field> must be ..." for a bad table, exit 0 for a good one.
# Overrides: STAGE=<dir holding roles.py> (default /workspace/bin), ROLES_FILE=<table> (default the live roles.json; a staged run
# needs a table whose hook paths exist, e.g. roles.staged.json).
set -u
T=$(mktemp -d); trap 'rm -r "$T"' EXIT
S=${STAGE:-/workspace/bin}
RF=${ROLES_FILE:-/workspace/docs/hermes-local/roles.json}
fails=0; nok=0
ok() { if eval "$1"; then echo "ok   $2"; nok=$((nok+1)); else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/out" ] && sed 's/^/     /' "$T/out" | head -3; fi; }
mkdir -p "$T/sup/logs"; cp /workspace/config/owner.example.env "$T/owner.env"
export ESCALATE_SUP_DIR="$T/sup" OWNER_CONFIG="$T/owner.env" PYTHONPATH=/workspace/bin
# T1 (F1 W4 r5): the table verdicts are judged in ONE driver process that runs roles.py's whole script (argv, the table in ROLES_FILE, stdout and
# stderr as one stream, its exit code), as a process run does. The first case of each (role, exit code) class also runs as a real roles.py
# process and both must agree (lines compared as sets: a process may order its two streams differently). An agreement case with a control below.
cat >"$T/cli.py" <<'PY'
import base64, io, json, os, sys, traceback
codes, keep = {}, (sys.stdout, sys.stderr, sys.stdin, sys.argv)
for line in keep[2]:
    r = json.loads(base64.b64decode(line))
    if r["script"] not in codes:
        codes[r["script"]] = compile(open(r["script"], encoding="utf-8").read(), r["script"], "exec")
    old = {k: os.environ.get(k) for k in r["env"]}; os.environ.update(r["env"])
    out = io.StringIO(); sys.stdout = sys.stderr = out; sys.stdin = io.StringIO(""); sys.argv = [r["script"], *r["argv"]]
    try:
        exec(codes[r["script"]], {"__name__": "__main__", "__file__": r["script"]}); rc = 0
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else 0 if e.code is None else 1
        if isinstance(e.code, str):
            print(e.code, file=out)
    except BaseException:
        traceback.print_exc(file=out); rc = 1
    finally:
        sys.stdout, sys.stderr, sys.stdin, sys.argv = keep
        for k, v in old.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
    keep[0].write(f"{rc}\t{base64.b64encode(out.getvalue().encode()).decode()}\n"); keep[0].flush()
PY
mkfifo "$T/cin" "$T/cout"; python3 -I "$T/cli.py" <"$T/cin" >"$T/cout" 2>"$T/cerr" & CPID=$!; exec {CW}>"$T/cin" {CR}<"$T/cout"
: >"$T/seen"; : >"$T/rows"
cli() {   # cli <table> <args...>: roles.py run in the driver; exit code echoed, output in $T/out
  local rc b req; req=$(jq -nc --arg s "$S/roles.py" --arg t "$1" '{script: $s, argv: $ARGS.positional, env: {ROLES_FILE: $t}}' --args "${@:2}" | base64 -w0)
  printf '%s\n' "$req" >&"$CW"; IFS=$'\t' read -r rc b <&"$CR"; printf '%s' "$b" | base64 -d >"$T/out"; echo "$rc"; }
rv() {   # exit code of the validator on that table (in the driver; the first of each (role, exit code) class also as a real process, which must agree)
  local rc rrc k; rc=$(cli "$1" reviewers); k="${CLS:-?}|$rc"; cp "$1" "$T/rows.$(wc -l <"$T/rows").json"; echo "$1" >>"$T/rows"
  if ! grep -qxF -- "$k" "$T/seen"; then
    echo "$k" >>"$T/seen"; ROLES_FILE=$1 python3 "$S/roles.py" reviewers >"$T/out.real" 2>&1; rrc=$?
    if [ "$rrc" != "$rc" ] || [ "$(sort "$T/out")" != "$(sort "$T/out.real")" ]; then echo "     route agreement: class $k differs (driver $rc, process $rrc)" >&2; echo 99; return; fi
  fi
  echo "$rc"; }
ok '[ "$(rv "$RF")" = 0 ]' "control: the table under test is valid"
CMSG="must be a non-empty object of text pairs"; NMSG="must be true or false"
for r in $(jq -r '.roles | keys[]' "$RF"); do   # every role, the fallback included
  CLS=$r
  for v in '{}' '"x"' '["a"]' '{"k":1}' '{"":"v"}' '{"k":""}' '{"k":true}' '{"k":["v"]}' '{"k":null}' '{"k":"v","j":2}' 7 true null; do
    jq --arg r "$r" --argjson v "$v" '.roles[$r].complete_metadata = $v' "$RF" >"$T/b.json"
    ok '[ "$(rv "$T/b.json")" = 1 ] && grep -q "roles: INVALID" "$T/out" && grep -qF "role $r: complete_metadata $CMSG" "$T/out"' "role $r: complete_metadata = $v: INVALID, named"
  done
  for v in '{"k":"v"}' '{"review":"approved"}' '{"a":"b","c":"d"}'; do
    jq --arg r "$r" --argjson v "$v" '.roles[$r].complete_metadata = $v' "$RF" >"$T/b.json"
    ok '[ "$(rv "$T/b.json")" = 0 ]' "role $r: complete_metadata = $v: valid"
  done
  for v in '"yes"' '"true"' 1 0 '[]' '{}' null; do
    jq --arg r "$r" --argjson v "$v" '.roles[$r].complete_needs_review = $v' "$RF" >"$T/b.json"
    ok '[ "$(rv "$T/b.json")" = 1 ] && grep -q "roles: INVALID" "$T/out" && grep -qF "role $r: complete_needs_review $NMSG" "$T/out"' "role $r: complete_needs_review = $v: INVALID, named"
  done
  for v in true false; do
    jq --arg r "$r" --argjson v "$v" '.roles[$r].complete_needs_review = $v' "$RF" >"$T/b.json"
    ok '[ "$(rv "$T/b.json")" = 0 ]' "role $r: complete_needs_review = $v: valid"
  done
  jq --arg r "$r" 'del(.roles[$r].complete_needs_review, .roles[$r].complete_metadata)' "$RF" >"$T/b.json"
  ok '[ "$(rv "$T/b.json")" = 0 ]' "role $r: neither field: valid (both are optional)"
done
# T1: the two routes agree on a sample of the tables above (every 10th), and a planted difference (a copy of roles.py whose INVALID line reads
# otherwise, given to the driver only) is caught
agree() { local n=0 i=0 f rc rrc; while read -r f; do i=$((i+1)); [ $((i % 10)) = 1 ] || continue; cp "$T/rows.$((i-1)).json" "$T/ag.json"
    rc=$(S=$1 cli "$T/ag.json" reviewers); ROLES_FILE=$T/ag.json python3 "$S/roles.py" reviewers >"$T/ag.real" 2>&1; rrc=$?
    { [ "$rc" = "$rrc" ] && [ "$(sort "$T/out")" = "$(sort "$T/ag.real")" ]; } || n=$((n+1)); done <"$T/rows"; echo "$n"; }
mkdir -p "$T/px"; sed 's/roles: INVALID/roles: NOT VALID/' "$S/roles.py" >"$T/px/roles.py"; cp "$S"/alert_catalog.py "$T/px/" 2>/dev/null
NR=$(wc -l <"$T/rows"); ND=$(agree "$S"); NX=$(agree "$T/px")
ok '[ "$NR" -ge 100 ] && [ "$ND" = 0 ]' "T1 route agreement: every 10th of $NR tables gives the same exit code and output in the driver as a real roles.py process ($ND differ)"
ok '[ "$NX" -gt 0 ]' "T1 route agreement, negative control: a planted difference in the driver's roles.py is caught ($NX differ)"
# the field is read through roles.py field like any other permission
RR=$(jq -r '[.roles | to_entries[] | select(.value.complete_metadata != null) | .key][0]' "$RF")
RP=$(jq -r --arg r "$RR" '[.profiles | to_entries[] | select(.value.role == $r) | .key][0]' "$RF")
BR=$(jq -r '[.roles | to_entries[] | select(.value.complete_needs_review == true) | .key][0]' "$RF")
BP=$(jq -r --arg r "$BR" '[.profiles | to_entries[] | select(.value.role == $r) | .key][0]' "$RF")
ok '[ -n "$RP" ] && [ "$RP" != null ] && [ "$(ROLES_FILE=$RF python3 "$S/roles.py" field "$RP" complete_metadata | jq -c .)" = "$(jq -c --arg r "$RR" ".roles[\$r].complete_metadata" "$RF")" ]' "roles.py field <reviewing profile> complete_metadata reads the pairs"
ok '[ -n "$BP" ] && [ "$BP" != null ] && [ "$(ROLES_FILE=$RF python3 "$S/roles.py" field "$BP" complete_needs_review)" = true ]' "roles.py field <builder profile> complete_needs_review reads true"
ok '[ "$(ROLES_FILE=$RF python3 "$S/roles.py" field some-unknown-profile complete_needs_review)" = null ] && [ "$(ROLES_FILE=$RF python3 "$S/roles.py" field some-unknown-profile complete_metadata)" = null ]' "an unknown profile (fallback role) has neither field"
exec {CW}>&- {CR}<&-; wait "$CPID"
echo "roles-3b-rows: $nok ok, $fails FAIL"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
