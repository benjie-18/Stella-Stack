#!/usr/bin/env bash
# Self-test for the policy gateway core (X1 item G1; body B4, AC4, AC5; design section G1 with rulings X1-DC-07 and X1-DC-09).
# Written test-first (X1 wave 1): every case fails on build/X1 (no bin/gateway.py yet) with a FAIL line carrying its check id.
# One scratch root (bin, .stella, docs copied), its own HOME, temp, alert folder and event log; no network, no fixed port.
# Check ids -> cases (the label of each case starts with its id):
#   AC4-enforce-refuse  library check() refuses a kind its policy does not allow; the stand-in action is never called; CLI decide too
#   AC4-evaluator-crash crash, garbage, timeout, missing script, unknown evaluator id; a kind with no policy; an unknown kind
#   AC4-log-before      the decision line is in the trusted log when the action runs (allow and refuse), masked inputs, chain verifies;
#                       an unwritable log refuses in enforce, allows with an alert in audit
#   AC4-audit           the same refused actions run, logged would-refuse   | AC4-off  no line, no evaluator spawn, the action runs
#   T-cedar             real cedar-wasm through the default evaluator entry (needs node and node_modules: the one shared case)
#   T-project-mode      a project's mode overrides the global one for that project only | DC-09 no project -> strictest mode present
#   DC-07               policy_version = sha256 of the policies plus the evaluator entry; gateway.json is a boundary path
#   AC5-lint            planted kinds in a scratch gateway.json fail the lint; the shipped data passes it (needs G2's hooks)
#   AC5-fake-evaluator  a scratch script plus a data entry decides, no code change
#   AC5-owner-only      protected-path rule, owner-only row, identity-critical settings, stella-apply refusals, the owner path
#   (fix round G, pass 3) T-cedar null and float inputs; AC4-evaluator-crash 737 vs 735 each on its own path; AC4-log-before a long
#                       input logged as digest and length while the evaluator gets it whole
# ASSUMPTIONS (names the design leaves open; the builder matches them or tells the tester):
#  G-A1 `gateway.py decide --kind K --inputs JSON [--project P] [--role R] --json`: stdout one JSON object holding verdict, mode,
#       code, reason, policy_version; exit 0 when the action may run (allow, or audit's would-refuse), exit 1 when refused.
#  G-A2 `import gateway; gateway.check(kind, inputs, ctx)` returns the Decision as a dict or an object with those attributes;
#       the caller runs its action unless verdict == "refuse". The stack root is STELLA_ROOT, as for every data tool.
#  G-A3 gateway.json and gateway-policy.json are found through their data-files.json rows (by file name); decision_event names
#       the line type; the decision line carries kind, inputs, policy_version, evaluator, mode, verdict, reason, code at any depth.
#  G-A4 an evaluator entry's argv and request are templates filled the house way (policy.fill: "{name}" -> the value); the fake
#       entry clones the default entry's fields (so its verdict / reason pointers) and emits the Cedar runner's output shape
#       {decision: allow|deny, reasons, errors}; "allow" is the only allowing decision.
#  G-A5 gateway-policy.json: {mode: {global, projects}, evaluator, policies: [{id, kinds, text}]}; the test writes it in the scratch
#       root directly as setup (the owner path itself is tested in AC5-owner-only).
#  G-A6 `gateway.py lint` exit 0 clean, non-zero with the offending kind named; it scans bin/*.py for gateway.check calls.
#  G-A7 codes: every G1 refusal carries a code in STL-GRD-730..744.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=gateway-selftest
T=$(mktemp -d "${TMPDIR:-/tmp}/$ME.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'kill $(jobs -p) 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "# KEPT $T"; else chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; fi' EXIT
R=$T/root
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$R/.claude" "$R/qa" "$T/home" "$T/tmp" "$T/sup/logs" "$T/pb" "$T/o"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"
for f in opencode.json .mcp.json .claude/settings.json package.json package-lock.json; do [ -e "$ROOT/$f" ] && cp -r "$ROOT/$f" "$R/$f"; done
[ -d "$ROOT/node_modules" ] && ln -s "$ROOT/node_modules" "$R/node_modules"   # T-cedar only: read, never written
cd "$T" || exit 1
jq() { env -u HOME jq "$@"; }
IX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IX"; }
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$ROOT/$(ix .role_table)" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
POL=$R/$(ix '.files[] | select(.id == "owner-auth") | .path')
for v in $(jq -r '.worker_signals.token_env[]?' "$POL" 2>/dev/null); do unset "$v"; done
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH   # the board: no worker run
AL=$T/sup/logs/alerts.log; : >"$AL"
EV=$R/$(ix .event_log)
IID=$(jq -r .install_id "$R/.stella/install.json")
fails=0; n=0
# ok <test> <label>: a FAIL line (never a crash) with the last output of the case under it
ok() { n=$((n+1)); if ( set -o pipefail; eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/o/last" ] && tail -n 3 "$T/o/last" | cut -c1-240 | sed 's/^/     | /'; fi; : >"$T/o/last"; }
# run <tag> <cmd...>: stdout to $T/o/<tag>.out, stderr to $T/o/<tag>.err, exit code in RC; every call is bounded
run() { local t=$1; shift; timeout 30 "$@" >"$T/o/$t.out" 2>"$T/o/$t.err"; RC=$?; cat "$T/o/$t.out" "$T/o/$t.err" >"$T/o/last" 2>/dev/null; }
jv() { jq -r "$2" "$T/o/$1.out" 2>/dev/null; }
uuid() { cat /proc/sys/kernel/random/uuid; }
nev() { [ -f "$EV" ] && wc -l <"$EV" || echo 0; }
CODE='^STL-GRD-7(3[0-9]|4[0-4])$'

# ---- data the design names: the two rows, the decision type, the default evaluator, a role from the role table ----
GWREL=$(ix '[.files[] | select(.path | endswith("/gateway.json")) | .path][0] // ".stella/gateway.json"')
GPID=$(ix '[.files[] | select(.path | endswith("/gateway-policy.json")) | .id][0] // empty')
GPREL=$(ix '[.files[] | select(.path | endswith("/gateway-policy.json")) | .path][0] // ".stella/gateway-policy.json"')
GW=$R/$GWREL; GP=$R/$GPREL
[ -f "$GW" ] || echo '{"schema_version": 1, "action_kinds": [], "evaluators": []}' >"$GW"   # base: the cases still run and FAIL
DEV=$(jq -r '.decision_event // empty' "$GW")
DEFEV=$(jq -r '.evaluator // empty' "$GP" 2>/dev/null); [ -n "$DEFEV" ] || DEFEV=$(jq -r '.evaluators[0].id // "cedar"' "$GW")
OP=$(jq -r '.roles | keys[0]' "$RJ")
cp "$GW" "$T/gw.orig"; [ -f "$GP" ] && cp "$GP" "$T/gp.orig" || echo '{"schema_version": 1}' >"$T/gp.orig"

# ---- helpers (python, stdlib): the fake evaluator (scratch script), the library driver, the decision-line matcher ----
cat >"$R/qa/fake_eval.py" <<'PY'
import json, sys, time
mode, mark = sys.argv[1], sys.argv[2]
with open(mark, "a") as f:
    f.write("spawn\n")
raw = sys.stdin.read()
if mode == "crash":
    sys.exit(3)
if mode == "sleep":
    time.sleep(60)
if mode == "garbage":
    print("this is no verdict {"); sys.exit(0)
kind = json.loads(raw)["kind"]
allow = f"QA-PERMIT {kind};" in raw   # the policy text is in the request whatever form {policies} takes
print(json.dumps({"decision": "allow" if allow else "deny", "reasons": ["qa-fake " + ("permit" if allow else "no permit")], "errors": []}))
PY
cat >"$T/qa.py" <<'PY'
import json, os, sys
def flat(x, out):
    if isinstance(x, dict):
        for k, v in x.items():
            out.setdefault(k, []).append(v); flat(v, out)
    elif isinstance(x, list):
        for v in x: flat(v, out)
    return out
def match(log, typ, want):
    n = 0
    try:
        lines = open(log).read().splitlines()
    except OSError:
        return 0
    for l in lines:
        try:
            d = json.loads(l)
        except ValueError:
            continue
        f = flat(d, {})
        if typ and d.get("type") == typ and all(v in f.get(k, []) for k, v in want.items()):
            n += 1
    return n
cmd = sys.argv[1]
if cmd == "lines":     # <log> <type> <want JSON>: how many lines of that type hold every key: value (at any depth)
    print(match(sys.argv[2], sys.argv[3], json.loads(sys.argv[4])))
elif cmd == "line":    # <log> <type> <want JSON>: the last such line
    m = [l for l in open(sys.argv[2]).read().splitlines() if l.strip() and json.loads(l).get("type") == sys.argv[3]
         and all(v in flat(json.loads(l), {}).get(k, []) for k, v in json.loads(sys.argv[4]).items())]
    print(m[-1] if m else "")
elif cmd == "drive":   # <root> <log> <type> <kind> <inputs JSON> <project|-> <role> <side-effect file>: check(), then the stand-in action
    root, log, typ, kind, inputs, project, role, side = sys.argv[2:10]
    sys.path.insert(0, os.path.join(root, "bin"))
    import gateway
    want = {"kind": kind}
    before = match(log, typ, want)
    d = gateway.check(kind, json.loads(inputs), {"role": role, "run": "qa-run-1", "card": None,
                                                  "project": None if project == "-" else project, "adapter": None})
    g = (lambda k: d.get(k)) if isinstance(d, dict) else (lambda k: getattr(d, k, None))
    acted, at_action = False, None
    if g("verdict") != "refuse":
        at_action = match(log, typ, want)   # what the log holds at the moment the action runs
        with open(side, "a") as f:
            f.write("acted\n")
        acted = True
    print(json.dumps({"verdict": g("verdict"), "mode": g("mode"), "code": g("code"), "reason": g("reason"),
                      "policy_version": g("policy_version"), "acted": acted, "before": before, "at_action": at_action,
                      "after": match(log, typ, want)}))
PY
QA() { python3 -I "$T/qa.py" "$@"; }
GWY() { python3 -I "$R/bin/gateway.py" "$@"; }
dec() { local t=$1; shift; run "$t" python3 -I "$R/bin/gateway.py" decide --role "$OP" "$@" --json; }
SIDE=$T/side-effect
drive() { rm -f "$SIDE"; run "$1" python3 -I "$T/qa.py" drive "$R" "$EV" "$DEV" "$2" "$3" "${4:--}" "$OP" "$SIDE"; }
lines() { QA lines "$EV" "$DEV" "$1"; }
SPAWN=$R/qa/spawned

# the evaluator entries (data only): each clones the default entry's fields, then its own argv / request / timeout
ev() {   # <id> <fake mode> <timeout_s> [script]
  jq -c --arg id "$1" --arg m "$2" --argjson t "$3" --arg s "${4:-fake_eval.py}" --arg dflt "$DEFEV" --arg g "$(uuid)" --arg i "$IID" '
    (([.evaluators[]? | select(.id == $dflt)][0]) // {verdict: "/decision", reason: "/reasons/0", status: "approved"})
    + {id: $id, kind: "subprocess", argv: ["python3", "-I", "{stack}/qa/\($s)", $m, "{stack}/qa/spawned"],
       request: {kind: "{kind}", role: "{role}", project: "{project}", inputs: "{inputs}", policies: "{policies}"},
       timeout_s: $t, global_id: $g, install_id: $i}' "$T/gw.orig"; }
jq --argjson a "$(ev qa-fake decide 10)" --argjson b "$(ev qa-crash crash 10)" --argjson c "$(ev qa-garbage garbage 10)" \
   --argjson d "$(ev qa-slow sleep 1)" --argjson e "$(ev qa-missing decide 10 absent_eval.py)" \
   '.evaluators = ((.evaluators // []) + [$a, $b, $c, $d, $e])' "$T/gw.orig" >"$T/gw.qa"
cp "$T/gw.qa" "$GW"
# setpol <global mode> <projects JSON> <evaluator> <policies JSON: [[kinds], text]...>: the owner file as the owner would hold it
setpol() {
  python3 -I - "$T/gp.orig" "$GP" "$1" "$2" "$3" "$4" "$IID" <<'PY'
import json, sys, uuid
src, dst, g, projects, ev, pols, iid = sys.argv[1:8]
d = json.load(open(src))
ids = not d.get("policies") or "global_id" in d["policies"][0]
d["mode"] = {"global": g, "projects": json.loads(projects)}
d["evaluator"] = ev
d["policies"] = [dict({"id": f"qa-pol-{n}", "kinds": k, "text": t}, **({"global_id": str(uuid.uuid4()), "install_id": iid} if ids else {}))
                 for n, (k, t) in enumerate(json.loads(pols))]
json.dump(d, open(dst, "w"), indent=2)
PY
}
PERMIT_READ='[[["file_read", "shell", "file_write"], "QA-PERMIT file_read;"]]'   # covers three kinds, allows file_read only
IN='{"path": "qa-notes.txt"}'

echo "# $ME: scratch root $R; decision type '${DEV:-<none in data>}'; default evaluator '$DEFEV'; role from the table"

# ======== AC5-owner-only first (fresh root: the shipped owner file, no event line yet) ========
ok '[ -n "$GPID" ] && jq -e --arg i "$GPID" ".files[] | select(.id == \$i) | .owner_only == true" "$IX"' "AC5-owner-only the gateway policy file has a data-files row marked owner-only"
ok '[ -n "$GPID" ] && [ "$(jq --arg i "$GPID" "[.entries[] | select(.store.data == \$i)] | length" "$R/.stella/settings.json")" -ge 2 ] && jq -e --arg i "$GPID" "[.entries[] | select(.store.data == \$i) | .sensitivity == \"identity_critical\"] | all" "$R/.stella/settings.json"' "AC5-owner-only settings registry rows (global mode, evaluator) store into the policy file and are identity_critical"
ok '[ -f "$GP" ] && [ "$(jq -r .mode.global "$T/gp.orig")" = off ]' "AC5-owner-only/AC4-off the shipped owner file holds the default mode off"
run hits sh -c 'printf "%s\0" "$1" | python3 -I "$2/bin/roles.py" hits "$2" refused | tr "\0" "\n"' _ "$GPREL" "$R"
ok '[ $RC = 0 ] && grep -qxF "$GPREL" "$T/o/hits.out"' "AC5-owner-only the protected-path rule (roles.py hits <root> refused, every guard's one test) refuses an agent write of $GPREL"
run ownerdata python3 -I "$R/bin/roles.py" owner-data "$R"
ok '[ $RC = 0 ] && jq -e --arg p "$GPREL" "index(\$p) != null" "$T/o/ownerdata.out"' "AC5-owner-only $GPREL is owner data (roles.py owner-data)"
run boundary python3 -I "$R/bin/roles.py" boundary
ok '[ $RC = 0 ] && jq -e --arg p "$GWREL" "index(\$p) != null" "$T/o/boundary.out"' "DC-07 $GWREL is a boundary path (roles.py boundary)"
# stella-apply: a candidate that turns enforce on; first with no owner key, then as a worker, then the owner path
jq '.mode.global = "enforce"' "$T/gp.orig" >"$T/gp.cand"
git -C "$R" init -q 2>/dev/null; printf '.supervisor/\nnode_modules\n' >"$R/.gitignore"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" -c user.name=qa -c user.email=qa@example.invalid commit -qm base >/dev/null 2>&1
AP() { python3 -I "$R/bin/stella-apply.py" "$@"; }
e0=$(nev)
run apnokey python3 -I "$R/bin/stella-apply.py" apply "${GPID:-no-gateway-policy-row}" --from "$T/gp.cand"
ok '[ -n "$GPID" ] && [ $RC = 1 ] && grep -q STL-OWN-806 "$T/o/last" && cmp -s "$GP" "$T/gp.orig" && [ "$(nev)" = "$e0" ]' "AC5-owner-only stella-apply with no owner proof (no owner key): STL-OWN-806, the file unchanged, no event line"
run apworker env STUB_WORKER_MARK=1 python3 -I "$R/bin/stella-apply.py" apply "${GPID:-no-gateway-policy-row}" --from "$T/gp.cand"
ok '[ -n "$GPID" ] && [ $RC = 1 ] && grep -q STL-CFG-312 "$T/o/last" && cmp -s "$GP" "$T/gp.orig" && [ "$(nev)" = "$e0" ]' "AC5-owner-only stella-apply from a worker environment: STL-CFG-312, the file unchanged, no event line"
# the owner path: this root's owner key; identity_critical takes the key alone here, as in stella-apply-selftest (no terminal in a test)
python3 -I "$R/bin/owner_auth.py" init-key >/dev/null 2>&1
jq '.actions.identity_critical = .actions.owner_write' "$POL" >"$T/oa" && cp "$T/oa" "$POL"
nb() { find "$R/$(ix .backup_dir)" -name meta.json 2>/dev/null | wc -l; }
b0=$(nb); e0=$(nev)
run apowner python3 -I "$R/bin/stella-apply.py" apply "${GPID:-no-gateway-policy-row}" --from "$T/gp.cand"
ok '[ -n "$GPID" ] && [ $RC = 0 ] && cmp -s "$GP" "$T/gp.cand" && [ "$(nb)" = $((b0+1)) ] && [ "$(nev)" = $((e0+1)) ] && tail -n1 "$EV" | jq -e --arg i "$GPID" ".type == \"apply\" and .what == \$i"' "AC5-owner-only the owner path: applied, one backup, one apply event line"

# ======== AC4-off ========
cp "$T/gp.orig" "$GP"; : >"$SPAWN"; e0=$(nev)
dec off0 --kind shell --inputs '{"command": "true"}'
ok '[ $RC = 0 ] && [ "$(jv off0 .verdict)" = allow ] && [ "$(jv off0 .mode)" = off ] && [ "$(nev)" = "$e0" ]' "AC4-off the shipped owner file (default off): decide allows, mode off, no event line"
setpol off '{}' qa-fake "$PERMIT_READ"; : >"$SPAWN"; e0=$(nev)
drive off1 shell '{"command": "true"}'
ok '[ $RC = 0 ] && [ "$(jv off1 .verdict)" = allow ] && [ "$(jv off1 .acted)" = true ] && [ "$(nev)" = "$e0" ] && [ ! -s "$SPAWN" ]' "AC4-off mode off with a denying policy: check() allows, the action runs, no event line, no evaluator spawned"

# ======== AC4-enforce-refuse ========
setpol enforce '{}' qa-fake "$PERMIT_READ"; : >"$SPAWN"
drive enf1 shell '{"command": "touch /tmp/qa"}'
ok '[ $RC = 0 ] && [ "$(jv enf1 .verdict)" = refuse ] && [ "$(jv enf1 .acted)" = false ] && [ ! -e "$SIDE" ] && [[ $(jv enf1 .code) =~ $CODE ]]' "AC4-enforce-refuse check() refuses a kind its policy does not allow (coded); the stand-in action never ran"
ok '[ -s "$SPAWN" ]' "AC4-enforce-refuse the refusal came from the evaluator (it was spawned)"
dec enf2 --kind shell --inputs '{"command": "true"}'
ok '[ $RC = 1 ] && [ "$(jv enf2 .verdict)" = refuse ] && [ "$(jv enf2 .mode)" = enforce ] && [[ $(jv enf2 .code) =~ $CODE ]] && [ -n "$(jv enf2 .reason)" ]' "AC4-enforce-refuse decide: exit 1, verdict refuse, mode enforce, a code and a reason"
drive enf3 file_read "$IN"
ok '[ $RC = 0 ] && [ "$(jv enf3 .verdict)" = allow ] && [ "$(jv enf3 .acted)" = true ]' "AC4-enforce-refuse control: the allowed kind passes and its action runs"

# ======== AC4-log-before ========
CAN1=qa-canary-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n'); CAN2=qatok-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
jq '(.entries[0].redaction_patterns) = ((.entries[0].redaction_patterns // []) + ["qatok-[0-9a-f]{32}"])' "$R/.stella/connections.json" >"$T/c" && cp "$T/c" "$R/.stella/connections.json"
drive lb1 file_read "{\"path\": \"qa-notes.txt\", \"api_key\": \"$CAN1\", \"note\": \"see $CAN2\"}"
ok '[ $RC = 0 ] && [ "$(jv lb1 .acted)" = true ] && [ "$(jv lb1 .at_action)" = $(( $(jv lb1 .before) + 1 )) ]' "AC4-log-before allow: the decision line is in the trusted log when the action runs"
L=$(QA line "$EV" "$DEV" '{"kind": "file_read", "verdict": "allow"}' 2>/dev/null); echo "$L" >"$T/o/lb.line"
ok '[ -n "$L" ] && echo "$L" | jq -e "[.. | objects | to_entries[]] as \$e | ([\$e[] | select(.key == \"policy_version\") | .value | strings | test(\"^[0-9a-f]{64}$\")] | any) and ([\$e[] | select(.key == \"evaluator\") | .value] | index(\"qa-fake\") != null) and ([\$e[] | select(.key == \"mode\") | .value] | index(\"enforce\") != null) and ([\$e[] | select(.key == \"reason\")] | length > 0) and ([\$e[] | select(.key == \"inputs\")] | length > 0)"' "AC4-log-before the line holds kind, verdict, mode, evaluator, reason, inputs and a sha256 policy_version"
ok '! grep -qF "$CAN1" "$EV" "$AL" && ! grep -qF "$CAN2" "$EV" "$AL" && grep -qF "\"***\"" "$T/o/lb.line"' "AC4-log-before inputs masked: neither canary (key-named, value pattern) in the event log or the alerts; *** in the line"
ok '[ -n "$L" ] && echo "$L" | jq -e "has(\"mac\") and has(\"seq\")" && python3 -I "$R/bin/event_log.py" verify' "AC4-log-before the line is a chained trusted line (event_log.py writer) and the chain verifies"
drive lb2 shell '{"command": "true"}'
ok '[ $RC = 0 ] && [ "$(jv lb2 .verdict)" = refuse ] && [ "$(jv lb2 .after)" = $(( $(jv lb2 .before) + 1 )) ] && [ "$(QA lines "$EV" "$DEV" "{\"kind\": \"shell\", \"verdict\": \"refuse\"}")" -ge 1 ]' "AC4-log-before a refusal is logged too (verdict refuse) before check() returns"
# the log cannot be written (a symbolic link: event_log refuses it): enforce refuses even an allowed action; audit allows and alerts
mv "$EV" "$T/ev.keep"; : >"$T/elsewhere.jsonl"; ln -s "$T/elsewhere.jsonl" "$EV"
drive lb3 file_read "$IN"
ok '[ $RC = 0 ] && [ "$(jv lb3 .verdict)" = refuse ] && [ "$(jv lb3 .acted)" = false ] && [[ $(jv lb3 .code) =~ $CODE ]]' "AC4-log-before enforce with an unwritable log: an allowed action is refused, coded, not run"
setpol audit '{}' qa-fake "$PERMIT_READ"; a0=$(wc -l <"$AL")
drive lb4 file_read "$IN"
ok '[ $RC = 0 ] && [ "$(jv lb4 .acted)" = true ] && [ "$(wc -l <"$AL")" -gt "$a0" ]' "AC4-log-before audit with an unwritable log: the action runs and an alert line is written"
rm -f "$EV"; mv "$T/ev.keep" "$EV"

# ======== AC4-audit ========
setpol audit '{}' qa-fake "$PERMIT_READ"; e0=$(lines '{"kind": "shell", "verdict": "would-refuse"}')
drive au1 shell '{"command": "true"}'
ok '[ $RC = 0 ] && [ "$(jv au1 .verdict)" != refuse ] && [ "$(jv au1 .mode)" = audit ] && [ "$(jv au1 .acted)" = true ] && [ "$(lines "{\"kind\": \"shell\", \"verdict\": \"would-refuse\"}")" = $((e0+1)) ]' "AC4-audit the action enforce refuses runs, logged would-refuse (one line)"
dec au2 --kind network_request --inputs '{"url": "http://127.0.0.1:9/"}'
ok '[ $RC = 0 ] && [ "$(jv au2 .verdict)" != refuse ] && [ "$(lines "{\"kind\": \"network_request\", \"verdict\": \"would-refuse\"}")" -ge 1 ]' "AC4-audit a kind with no policy: allowed, logged would-refuse"
setpol audit '{}' qa-crash "$PERMIT_READ"
dec au3 --kind file_read --inputs "$IN"
ok '[ $RC = 0 ] && [ "$(jv au3 .verdict)" != refuse ] && [ "$(jv au3 .mode)" = audit ]' "AC4-audit an evaluator crash: allowed (would-refuse), not refused"

# ======== AC4-evaluator-crash (enforce; the policy permits file_read, so only the evaluator's failure can refuse) ========
for e in qa-crash qa-garbage qa-missing qa-no-such-evaluator; do
  setpol enforce '{}' "$e" "$PERMIT_READ"
  dec cr-$e --kind file_read --inputs "$IN"
  ok '[ $RC = 1 ] && [ "$(jv cr-$e .verdict)" = refuse ] && [[ $(jv cr-$e .code) =~ $CODE ]]' "AC4-evaluator-crash evaluator $e: refused with a code"
done
setpol enforce '{}' qa-slow "$PERMIT_READ"; s=$SECONDS
dec cr-slow --kind file_read --inputs "$IN"
ok '[ $RC = 1 ] && [ "$(jv cr-slow .verdict)" = refuse ] && [[ $(jv cr-slow .code) =~ $CODE ]] && [ $((SECONDS - s)) -lt 15 ]' "AC4-evaluator-crash an evaluator past its timeout_s (1 s): refused with a code, within 15 s"
setpol enforce '{}' qa-fake "$PERMIT_READ"
dec cr-nopol --kind network_request --inputs '{"url": "http://127.0.0.1:9/"}'
ok '[ $RC = 1 ] && [ "$(jv cr-nopol .verdict)" = refuse ] && [[ $(jv cr-nopol .code) =~ $CODE ]]' "AC4-evaluator-crash a kind no policy covers: refused with a code"
dec cr-unk --kind qa-no-such-kind --inputs '{}'
ok '[ $RC = 1 ] && [ "$(jv cr-unk .verdict)" = refuse ] && [[ $(jv cr-unk .code) =~ $CODE ]]' "AC4-evaluator-crash a kind not in gateway.json: refused with a code"

# ======== T-project-mode and DC-09 ========
setpol audit '{"qa-p1": "enforce", "qa-p2": "off"}' qa-fake "$PERMIT_READ"; e0=$(nev)
dec pm1 --kind shell --inputs '{"command": "true"}' --project qa-p1
ok '[ $RC = 1 ] && [ "$(jv pm1 .mode)" = enforce ] && [ "$(jv pm1 .verdict)" = refuse ]' "T-project-mode global audit, project enforce: that project is refused"
e1=$(nev); dec pm2 --kind shell --inputs '{"command": "true"}' --project qa-p2
ok '[ $RC = 0 ] && [ "$(jv pm2 .mode)" = off ] && [ "$(jv pm2 .verdict)" = allow ] && [ "$(nev)" = "$e1" ]' "T-project-mode global audit, project off: allowed, no line"
dec pm3 --kind shell --inputs '{"command": "true"}' --project qa-p9
ok '[ $RC = 0 ] && [ "$(jv pm3 .mode)" = audit ] && [ "$(jv pm3 .verdict)" != refuse ]' "T-project-mode a project with no mode of its own takes the global one (audit)"
setpol enforce '{"qa-p2": "off"}' qa-fake "$PERMIT_READ"; e1=$(nev)
dec pm4 --kind shell --inputs '{"command": "true"}' --project qa-p2
ok '[ $RC = 0 ] && [ "$(jv pm4 .mode)" = off ] && [ "$(nev)" = "$e1" ]' "T-project-mode global enforce, project off: that project is off (no line)"
setpol off '{"qa-p1": "audit", "qa-p2": "enforce"}' qa-fake "$PERMIT_READ"
dec dc9a --kind shell --inputs '{"command": "true"}'
ok '[ $RC = 1 ] && [ "$(jv dc9a .mode)" = enforce ] && [ "$(jv dc9a .verdict)" = refuse ]' "DC-09 no project, global off, projects audit and enforce: the strictest (enforce) refuses"
drive dc9b shell '{"command": "true"}'
ok '[ "$(jv dc9b .verdict)" = refuse ] && [ "$(jv dc9b .acted)" = false ]' "DC-09 check() with ctx project None: refused the same way"
setpol off '{"qa-p1": "audit"}' qa-fake "$PERMIT_READ"
dec dc9c --kind shell --inputs '{"command": "true"}'
ok '[ $RC = 0 ] && [ "$(jv dc9c .mode)" = audit ] && [ "$(jv dc9c .verdict)" != refuse ]' "DC-09 no project, global off, one project audit: audit (would-refuse), not off"
dec dc9d --kind shell --inputs '{"command": "true"}' --project qa-p9
ok '[ $RC = 0 ] && [ "$(jv dc9d .mode)" = off ]' "DC-09 control: a named project with no mode of its own stays on the global mode (off)"

# ======== DC-07 policy_version ========
setpol enforce '{}' qa-fake "$PERMIT_READ"
dec pv1 --kind file_read --inputs "$IN"; dec pv2 --kind file_read --inputs "$IN"
ok '[[ $(jv pv1 .policy_version) =~ ^[0-9a-f]{64}$ ]] && [ "$(jv pv1 .policy_version)" = "$(jv pv2 .policy_version)" ]' "DC-07 policy_version is a sha256, the same for the same data"
setpol enforce '{}' qa-fake '[[["file_read", "shell", "file_write"], "QA-PERMIT file_read; qa second text"]]'
dec pv3 --kind file_read --inputs "$IN"
ok '[[ $(jv pv3 .policy_version) =~ ^[0-9a-f]{64}$ ]] && [ "$(jv pv3 .policy_version)" != "$(jv pv1 .policy_version)" ]' "DC-07 a changed policy text changes policy_version"
setpol enforce '{}' qa-fake "$PERMIT_READ"; jq '(.evaluators[] | select(.id == "qa-fake") | .timeout_s) = 11' "$T/gw.qa" >"$GW"
dec pv4 --kind file_read --inputs "$IN"
ok '[[ $(jv pv4 .policy_version) =~ ^[0-9a-f]{64}$ ]] && [ "$(jv pv4 .policy_version)" != "$(jv pv1 .policy_version)" ]' "DC-07 the same policies with a changed evaluator entry: policy_version changes"
cp "$T/gw.qa" "$GW"

# ======== AC5-fake-evaluator ========
setpol enforce '{}' qa-fake "$PERMIT_READ"; : >"$SPAWN"
dec fe1 --kind file_read --inputs "$IN"; dec fe2 --kind file_write --inputs '{"path": "x"}'
ok '[ "$(jv fe1 .verdict)" = allow ] && [ "$(jv fe2 .verdict)" = refuse ] && [ "$(grep -c spawn "$SPAWN")" -ge 2 ]' "AC5-fake-evaluator a scratch script added as a data entry decides both ways (allow, refuse) with no code change"
run fe3 python3 -I "$R/bin/gateway.py" check
ok '[ $RC = 0 ]' "AC5-fake-evaluator gateway.py check accepts the data with the fake entries and the owner file"

# ======== AC5-lint ========
kindrow() { jq -c --arg id "$1" --argjson h "$2" --arg g "$(uuid)" --arg i "$IID" '(.action_kinds[0] // {}) + {id: $id, summary: "qa planted kind", hooks: $h, global_id: $g, install_id: $i}' "$T/gw.orig"; }
plant() { jq --argjson k "$(kindrow "$1" "$2")" '.action_kinds = ((.action_kinds // []) + [$k])' "$T/gw.qa" >"$GW"; }
run li0 python3 -I "$R/bin/gateway.py" lint
ok '[ $RC = 0 ]' "AC5-lint the shipped data passes the lint (every kind has its hook: holds once G2 fills the hooks)"
ok 'jq -e "[.action_kinds[].id] as \$k | ([\"file_read\",\"file_write\",\"shell\",\"tool_call\",\"mcp_call\",\"network_request\",\"broker_call\",\"host_session\"] - \$k) == [] and (\$k | index(\"browser_action\") == null and index(\"vm_guest\") == null)" "$T/gw.orig"' "AC5-lint gateway.json registers the eight X1 kinds and not browser_action / vm_guest (no hook yet)"
plant qa-planted-kind '[]'
run li1 python3 -I "$R/bin/gateway.py" lint
ok '[ $RC != 0 ] && grep -q qa-planted-kind "$T/o/last"' "AC5-lint a planted kind with no hook fails, naming the kind"
printf 'def qa_hook(x):\n    return x\n' >"$R/bin/qa_planted_hook.py"
plant qa-planted-kind '[{"file": "bin/qa_planted_hook.py", "function": "qa_hook"}]'
run li2 python3 -I "$R/bin/gateway.py" lint
ok '[ $RC != 0 ] && grep -q qa-planted-kind "$T/o/last"' "AC5-lint a planted kind whose hook function does not call gateway.check fails"
plant qa-planted-kind '[{"file": "bin/qa_no_such_file.py", "function": "qa_hook"}]'
run li3 python3 -I "$R/bin/gateway.py" lint
ok '[ $RC != 0 ] && grep -q qa-planted-kind "$T/o/last"' "AC5-lint a planted kind whose hook file is missing fails"
printf 'import gateway\n\n\ndef qa_hook(x):\n    if gateway.check("qa-planted-kind", {"x": x}, {})["verdict"] == "refuse":\n        return None\n    return x\n' >"$R/bin/qa_planted_hook.py"
plant qa-planted-kind '[{"file": "bin/qa_planted_hook.py", "function": "qa_hook"}]'
run li4 python3 -I "$R/bin/gateway.py" lint
ok '[ $RC = 0 ]' "AC5-lint control: the planted kind with a hook that calls gateway.check with it passes"
cp "$T/gw.qa" "$GW"; rm -f "$R/bin/qa_planted_hook.py"
printf 'import gateway\n\n\ndef qa_ghost(x):\n    return gateway.check("qa-ghost-kind", {"x": x}, {})\n' >"$R/bin/qa_ghost.py"
run li5 python3 -I "$R/bin/gateway.py" lint
ok '[ $RC != 0 ] && grep -q qa-ghost-kind "$T/o/last"' "AC5-lint code calling gateway.check with a kind not in data fails, naming the kind"
rm -f "$R/bin/qa_ghost.py"

# ======== T-cedar (shared: the real @cedar-policy/cedar-wasm from the source tree's node_modules, read only) ========
[ -d "$R/node_modules/@cedar-policy/cedar-wasm" ] && command -v node >/dev/null || echo "# T-cedar: node or node_modules/@cedar-policy/cedar-wasm is missing here, so the T-cedar cases fail"
setpol enforce '{}' "$DEFEV" '[[["file_read"], "permit(principal, action, resource) when { context has qa_gate && context.qa_gate == \"open\" };"]]'
dec ce1 --kind file_read --inputs '{"path": "qa-notes.txt", "qa_gate": "open"}'
ok '[ $RC = 0 ] && [ "$(jv ce1 .verdict)" = allow ]' "T-cedar the default evaluator ($DEFEV, real cedar-wasm) allows an action its policy permits"
dec ce2 --kind file_read --inputs '{"path": "qa-notes.txt", "qa_gate": "shut"}'
ok '[ $RC = 1 ] && [ "$(jv ce2 .verdict)" = refuse ] && [[ $(jv ce2 .code) =~ $CODE ]]' "T-cedar the default evaluator refuses an action no policy permits, with a code"
setpol enforce '{}' "$DEFEV" '[[["file_read"], "this is not cedar ((("]]'
dec ce3 --kind file_read --inputs '{"path": "qa-notes.txt", "qa_gate": "open"}'
ok '[ $RC = 1 ] && [ "$(jv ce3 .verdict)" = refuse ]' "T-cedar a policy Cedar cannot parse refuses (evaluator error)"

# ======== X1 fix round G (pass 3, new cases; the cases above are unchanged) ========
# T-cedar: Cedar has no null and no float; the runner drops null keys and passes a non-integer number as its JSON text (a string)
setpol enforce '{}' "$DEFEV" '[[["file_write"], "permit(principal, action, resource);"]]'
dec cf1 --kind file_write --inputs '{"path": "/x", "n": null}'
ok '[ $RC = 0 ] && [ "$(jv cf1 .verdict)" = allow ]' "T-cedar a null tool input under a permit-all policy is allowed (not an evaluator failure)"
dec cf2 --kind file_write --inputs '{"path": "/x", "n": 1.5, "deep": [{"m": null, "f": -0.25}]}'
ok '[ $RC = 0 ] && [ "$(jv cf2 .verdict)" = allow ]' "T-cedar a float tool input (top level and nested) under a permit-all policy is allowed"
setpol enforce '{}' "$DEFEV" '[[["file_write"], "permit(principal, action, resource) when { !(context has n) && context.f == \"1.5\" };"]]'
dec cf3 --kind file_write --inputs '{"path": "/x", "n": null, "f": 1.5}'
ok '[ $RC = 0 ] && [ "$(jv cf3 .verdict)" = allow ]' "T-cedar the mapping as documented: a null key is absent from the context, a float is the string of its JSON text"
# AC4-evaluator-crash: each error path keeps its own code (an answer with no allow/deny 737, a non-zero exit after an allow 735)
printf 'import sys\nsys.stdin.read()\nprint(\x27{"decision": "maybe", "reasons": [], "errors": []}\x27)\n' >"$R/qa/maybe_eval.py"
printf 'import sys\nsys.stdin.read()\nprint(\x27{"decision": "allow", "reasons": ["x"], "errors": []}\x27)\nsys.stdout.flush()\nsys.exit(3)\n' >"$R/qa/allowcrash_eval.py"
cat >"$R/qa/len_eval.py" <<'PY'
import json, sys
q = json.loads(sys.stdin.read())   # allows only when the evaluator got the whole text (800 characters): the cap is the logged copy's alone
print(json.dumps({"decision": "allow" if len(q["inputs"].get("text", "")) == 800 else "deny", "reasons": ["qa-len"], "errors": []}))
PY
jq --argjson a "$(ev qa-maybe decide 10 maybe_eval.py)" --argjson b "$(ev qa-allowcrash decide 10 allowcrash_eval.py)" --argjson c "$(ev qa-len decide 10 len_eval.py)" \
   '.evaluators += [$a, $b, $c]' "$T/gw.qa" >"$T/gw.fix"; cp "$T/gw.fix" "$GW"
setpol enforce '{}' qa-maybe "$PERMIT_READ"; dec fx1 --kind file_read --inputs "$IN"
ok '[ $RC = 1 ] && [ "$(jv fx1 .verdict)" = refuse ] && [ "$(jv fx1 .code)" = STL-GRD-737 ]' "AC4-evaluator-crash valid JSON with no allow or deny: refused STL-GRD-737"
setpol enforce '{}' qa-allowcrash "$PERMIT_READ"; dec fx2 --kind file_read --inputs "$IN"
ok '[ $RC = 1 ] && [ "$(jv fx2 .verdict)" = refuse ] && [ "$(jv fx2 .code)" = STL-GRD-735 ]' "AC4-evaluator-crash an allow printed by an evaluator that then exits 3: refused STL-GRD-735"
# AC4-log-before: a long string input is logged as its digest and length; the evaluator still gets the whole value
LONG=$(printf 'qa text %.0s' $(seq 100)); LSHA=$(printf '%s' "$LONG" | sha256sum | awk '{print $1}')
setpol enforce '{}' qa-len '[[["file_write"], "qa len"]]'; e0=$(nev)
dec fx3 --kind file_write --inputs "$(jq -nc --arg t "$LONG" '{path: "/x", text: $t}')"
ok '[ $RC = 0 ] && [ "$(jv fx3 .verdict)" = allow ] && tail -n +$((e0 + 1)) "$EV" | grep -q "$LSHA" && ! tail -n +$((e0 + 1)) "$EV" | grep -qF "${LONG:0:600}"' \
  "AC4-log-before an 800-character input (over logged_string_max, under the mask limit): the evaluator got it whole (allow), the decision line holds its sha256 and not the text"
ok '[ "$(QA lines "$EV" "$DEV" "{\"length\": 800}")" -ge 1 ]' "AC4-log-before the capped input's line also holds its length"
cp "$T/gw.qa" "$GW"

echo "# $ME: $n cases, $fails failed"
[ "$fails" = 0 ] && echo "$ME PASS" || echo "$ME FAIL ($fails)"
[ "$fails" = 0 ]
