#!/usr/bin/env bash
# Hermetic self-test for bin/consent.py (F2 W5: the accept popup, grants and unattended run mode; design D4 with design-check
# DC-02, DC-10, DC-11 and the wave-3 rulings). A scratch root (STELLA_ROOT, a copy of the tree's bin, data and docs) with the REAL
# resolver, route.py, approval service, owner-auth and apply tool; one fake cloud connection made with jq from a shipped catalog
# entry (never called: `route.py attempt` calls no model), two fake presets, card facts for fake projects, every channel adapter
# and the resume command stubbed (each delivery is kept, nothing leaves), a stub `hermes` that records every send, an owner key of
# the scratch root. Every id (link classes, the card role, approval class, alert codes, index rows) is read from the data.
# Cases: one request per grant with the apply tool's own action and digests, class and ttl of the routing data, delivered and
# logged once, reused while pending; another project asks again; an approved request made for another state of the grant file,
# or whose row was changed in the state file, grants nothing and is asked again; the shipped data's typed-phrase path (waiting,
# the owner told `consent.py complete <id>` once in the inbox, no terminal 808, the phrase on a terminal applies one row with the
# request id); pending; revoke (candidate only, never over a file, unknown id) and the next call after the owner applied it;
# denied and expired requests; unattended run mode (the settings reader first, then the owner file; queued once, one alert);
# fake entries as data only (a new approval class, a new queue alert code, another ttl, a new project); a policy under which
# the grant rows need no phrase (the gate applies alone, the queue is cleared); a privacy grant; under that policy still: a
# pending request applies nothing, an approved request consent did not make (another approval class, or the consent class with
# a row for another scope) applies nothing, and an applied request is spent (the grant file and the state entry put back: asked
# again, for both grant files); a worker environment.
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/consent-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
R=$T/root
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$T/home" "$T/tmp" "$T/sup/logs" "$T/o" "$T/pb" "$T/deliv"
cp -r "$H/bin" "$H/.stella" "$H/docs" "$R/"
IDX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IDX"; }
rel() { ix "[.files[] | select(.schema == \"$1\")][0].path"; }   # <schema>: the path of its first index row
RJREL=$(ix .role_table); RJ=$R/$RJREL; jq '.worker_markers = ["STUB_WORKER_MARK"]' "$H/$RJREL" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
POLREL=$(rel owner-auth); POL=$R/$POLREL
for v in $(jq -r '.worker_signals.token_env[]?' "$POL" 2>/dev/null); do unset "$v"; done
# the board stub: `roles.py prove` sees no worker run; every send is one recorded line
cat >"$T/pb/hermes" <<'S'
#!/usr/bin/env bash
case " $* " in *" send "*) printf '%s\n' "$*" | tr '\n' ' ' >>"$ESCALATE_SUP_DIR/sends"; echo >>"$ESCALATE_SUP_DIR/sends"; exit 0;; esac
echo "[]"
S
cat >"$T/adapter.sh" <<S
#!/usr/bin/env bash
# stub channel adapter: deliver <channel> keeps the request from stdin and prints a message ref; collect prints nothing
case \$1 in
  deliver) n=\$(ls "$T/deliv" | grep -c "^\$2\\."); cat >"$T/deliv/\$2.\$n"; echo "m-\$2-\$n";;
  collect) :;;
  *) exit 2;;
esac
S
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "$*" >>"%s"\n' "$T/resume.log" >"$T/resume.sh"
cat >"$T/pty.py" <<'PY'
import os, pty, select, sys
phrase, cmd = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
buf, sent = b"", False
while True:
    r, _, _ = select.select([fd], [], [], 30)
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
cat >"$T/gate.py" <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["STELLA_ROOT"], "bin"))
import consent
try:
    print(json.dumps(consent.gate(json.loads(sys.argv[1]), json.loads(sys.argv[2]))))
except consent.Refused as r:
    print(r.code)
PY
chmod +x "$T/pb/hermes" "$T/adapter.sh" "$T/resume.sh"; export PATH=$T/pb:$PATH
fails=0
ok() { if ( eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
ed() { local f=$R/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <path from the root> <jq args and filter>
uuid() { cat /proc/sys/kernel/random/uuid; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

# ---- ids from the data, the fake connection, presets, cards, channels, the owner key ----
RTREL=$(rel routing); RT=$R/$RTREL; GREL=$(rel grants); GF=$R/$GREL; DREL=$(rel data-policy); DF=$R/$DREL; AREL=$(rel role-assignments)
GROW=$(ix '[.files[] | select(.schema == "grants")][0].id'); DROW=$(ix '[.files[] | select(.schema == "data-policy")][0].id')
FAR=$(jq -r '[.link_classes[] | select(.hosted)][0].id' "$RT"); NEAR=$(jq -r '[.link_classes[] | select(.hosted | not)][0].id' "$RT")
CR=$(jq -r '.card_roles[0]' "$RT"); AR=$(jq -c '.fallback_role as $f | [.roles | keys[] | select(. != $f)]' "$RJ")
QUEUE=$(jq -r .consent.alert_code_queue "$RT"); CLS=$(jq -r .consent.approval_class "$RT"); TTL=$(jq -r .consent.ttl_s "$RT")
GCLASS=$(jq -r '[.class_rules | to_entries[] | select(.value.hosted == "grant") | .key][0]' "$DF")
IID=$(jq -r .install_id "$R/$(rel install)")
ST=$R/$(ix .routing_state); EV=$R/$(ix .event_log); REQ=$R/$(ix .approval_store)/requests; SENDS=$T/sup/sends
ed "$(rel connections)" --arg g "$(uuid)" --argjson ar "$AR" --argjson dc "$(jq -c .data_classes "$DF")" --arg k "$FAR" '
  .entries |= map(if .kind == "provider" then .allowed_roles = [] else . end)
  | .entries += [([.entries[] | select(.kind == "provider" and .type == "api" and .locality == "cloud" and (.aggregator | not))][0] | del(.protocol))
      + {id: "st-far", label: "st-far", enabled: true, global_id: $g, allowed_roles: $ar, link_class: $k, hosts: [{host: "127.0.0.1", port: 9, purpose: "selftest, never called"}],
         models: [("st-far-m1", "st-far-m2") | {id: ., capabilities: {tool_calling: true, json_mode: true, context_tokens: 1048576, vision: true, streaming: true},
                  probed_at: null, probe_source: "advertised", cost: null, limits: null}]}
      | .data_policy.data_classes_allowed = $dc]'
PR=$R/$(ix .probe_records); mkdir -p "$(dirname "$PR")"   # F2b item C: routing reads what a link can do from its probe record only
jq --arg i "$IID" --arg o "$(jq -r '.probe.output_shapes[-1]' "$RT")" '{schema_version: 1, records: [.entries[] | select(.id == "st-far") | .models[] | {global_id: "00000000-0000-4000-8000-000000000000",
  install_id: $i, connection: "st-far", model: .id, version: "st", probed_at: "2026-01-01T00:00:00Z", family: null, tool_calling: true, parallel_tool_calls: null, json: true,
  vision: true, output_shape: $o, context: {advertised: null, effective: 1048576, short_score: 1, points: []}, code: null}]}' "$R/$(rel connections)" >"$PR"
ed "$DREL" '.local_hosts += ["127.0.0.1"]'
# st-cross: the fake connection's class is the last resort (a crossing grant); st-all: it is in the order (only a privacy grant can be asked)
ed "$AREL" --arg n "$NEAR" --arg f "$FAR" '.assignments = [] | .selection.global = "st-cross"
  | .effort_modes["st-cross"] = {allowed_localities: ["local", "cloud"], no_silent_fallback: false, label: "selftest crossing", builtin: false, based_on: null,
      class_order: [$n], needs_class: null, last_resort: $f, verification_depth: 1, changelog: []}
  | .effort_modes["st-all"] = (.effort_modes["st-cross"] + {label: "selftest every class", class_order: [$f, $n], last_resort: null})'
CF=$R/$(ix .card_facts); mkdir -p "$CF"
for p in one two three four new; do echo "{\"project\":\"st-$p\",\"carries_secrets\":false,\"vault_content\":false,\"apps\":[]}" >"$CF/st-c-$p.json"; done
ed "$(rel channels)" --arg a "$T/adapter.sh" --arg r "$T/resume.sh" '.entries |= map(.deliver = [$a, "deliver", .id] | .collect = [$a, "collect", .id]) | .resume = {argv: [$r], timeout_s: 10}'
python3 -I "$R/bin/owner_auth.py" init-key >/dev/null 2>&1
cp "$GF" "$T/grants.keep"; cp "$RT" "$T/routing.keep"

CO="python3 -I $R/bin/consent.py"
att() {  # <task, also the output name> <project>: route.py attempt of the card role on that project's card; the exit code in RC
  timeout 100 python3 -I "$R/bin/route.py" attempt --role "$CR" --project "st-$2" --card "st-c-$2" --task "$1" --json >"$T/o/$1.json" 2>"$T/o/$1.err"; RC=$?
}
J() { jq -e "${@:2}" "$T/o/$1.json"; }                                                   # <name> <jq args and filter>
reqid() { jq -r '.problem // ""' "$T/o/$1.json" 2>/dev/null | grep -o 'apr-[0-9a-f]*' | head -n1; }   # <name>: the request the waiting task names
reqs() { find "$REQ" -maxdepth 1 -name '*.json' -type f 2>/dev/null | grep -c .; }
rq() { jq -r "$2" "$REQ/$1.json"; }                                                      # <request id> <jq>
row() { jq -c --arg r "$1" '.consents[] | select(.request_id == $r) | .row' "$ST"; }     # <request id>: the grant row the state keeps for it
gkey() { jq -r --arg r "$1" '.consents | to_entries[] | select(.value.request_id == $r) | .key' "$ST"; }   # <request id>: its key in the state
kept() { KEPT=$(jq -c --arg k "$(gkey "$1")" '{k: $k, v: .consents[$k]}' "$ST"); }       # <request id>: its state entry, kept
back() { jq --argjson e "$KEPT" '.consents[$e.k] = $e.v' "$ST" >"$ST.n" && mv "$ST.n" "$ST"; }   # the kept entry, put back in the state
answer() { setsid -w python3 -I "$R/bin/approvals.py" answer "$1" --decision "${2:-approved}" </dev/null >"$T/o/answer" 2>&1; }   # the owner's answer on the host, by the owner key
typed() {  # <index row> <command>...: the command on a pseudo-terminal, the owner typing the phrase for a change of that row
  timeout 100 python3 -I "$T/pty.py" "$(jq -r --arg w "$1" '.phrase.template | gsub("\\{what\\}"; $w)' "$POL")" "${@:2}" >"$T/o/typed" 2>&1
}
grows() { jq -s --arg r "$1" '[.[] | .. | objects | select(.request_id? == $r)] | length' "$GF" "$DF"; }   # <request id>: grant rows that carry it
grow() { jq -cs --arg r "$1" '[.[] | .. | objects | select(.request_id? == $r)][0]' "$GF" "$DF"; }
evs() { jq -c 'select(.type == "routing.consent")' "$EV" 2>/dev/null | grep -c .; }
sends() { local n; n=$(grep -cF -- "$1" "$SENDS" 2>/dev/null); echo "${n:-0}"; }           # <text>: inbox sends that hold it
deliv() { grep -lF -- "$1" "$T/deliv"/* 2>/dev/null | grep -c .; }                        # <request id>: deliveries of it
check() { python3 -I "$R/bin/stella_data.py" check; }

ok '[ -n "$FAR" ] && [ -n "$NEAR" ] && [ -n "$CR" ] && [ -n "$GROW" ] && [ -n "$DROW" ] && check' "S0 the scratch data (a fake connection, two fake presets, stub channels) passes check"

# ---- a request made for another state of the grant file; a row changed in the state file ----
att m1 two; RM=$(reqid m1); answer "$RM"
ed "$GREL" --arg g "$(uuid)" --arg i "$IID" --arg f "$FAR" --arg a "$(date -u -d '-1 hour' +%FT%TZ)" \
  '.crossing_grants += [{id: "st-other", global_id: $g, install_id: $i, preset: "st-cross", to_class: $f, scope: {level: "project", project: "st-elsewhere"}, granted_at: $a}]'
g0=$(sha "$GF"); cp "$GF" "$T/grants.keep"; typed "$GROW" $CO complete "$RM"; x=$?; att m1 two; R2=$(reqid m1)
ok '[ -n "$RM" ] && [ $x = 1 ] && grep -q STL-MDL-719 "$T/o/typed" && [ "$(sha "$GF")" = "$g0" ] && [ $RC = 3 ] && [ -n "$R2" ] && [ "$R2" != "$RM" ] && [ "$(reqs)" = 2 ] && check' \
  "an approved request made before the grant file changed grants nothing: complete is refused with the phrase typed, and the next call asks again"
answer "$R2"; jq --arg r "$R2" '(.consents[] | select(.request_id == $r) | .row.scope) = {level: "global"}' "$ST" >"$ST.n" && mv "$ST.n" "$ST"
att m1 two; R2C=$(reqid m1)
ok '[ $RC = 3 ] && [ -n "$R2C" ] && [ "$R2C" != "$R2" ] && [ "$(sha "$GF")" = "$g0" ] && [ "$(grows "$R2")" = 0 ]' \
  "the state proves nothing: an approved request whose row was made Stella-wide in the state file grants nothing, and the call asks again"

# ---- one request per grant ----
att g1 one; R1=$(reqid g1); ROW1=$(row "$R1")
ok '[ $RC = 3 ] && J g1 ".code == \"STL-MDL-719\"" && [ -n "$R1" ] && [ "$(reqs)" = 4 ] && [ "$(sha "$GF")" = "$g0" ]' "a link that needs a crossing grant: the task waits (exit 3, STL-MDL-719) with one new approval request; the grant file is untouched"
ok '[ "$(rq "$R1" .action.op)" = apply ] && [ "$(rq "$R1" .action.target)" = "$GROW" ] && [ "$(rq "$R1" .action.old_digest)" = "$g0" ] && [ "$(rq "$R1" .card)" = st-c-one ] \
  && [ "$(rq "$R1" .action.new_digest)" = "$(jq --indent 2 --argjson r "$ROW1" ".crossing_grants += [\$r]" "$GF" | sha256sum | cut -d" " -f1)" ]' \
  "its action is the apply tool's: the grants row, sha256 of the file now, sha256 of the file with the grant row appended"
ok '[ "$(rq "$R1" .approval_class)" = "$CLS" ] && [ "$(rq "$R1" "(.expires_at | fromdateiso8601) - (.requested_at | fromdateiso8601)")" = "$TTL" ] && [ "$(deliv "$R1")" -ge 1 ] \
  && jq -e --arg r "$R1" "select(.type == \"routing.consent\" and .new.request_id == \$r) | .code == \"STL-MDL-719\" and .trusted != false" "$EV" \
  && jq -e ".scope == {level: \"project\", project: \"st-one\"} and .preset == \"st-cross\" and (has(\"request_id\") | not)" <<<"$ROW1"' \
  "class and ttl come from the routing data; it is delivered, logged as one trusted event line, and its candidate row is scoped to the project"
d1=$(deliv "$R1"); e1=$(evs); att g1 one
ok '[ $RC = 3 ] && [ "$(reqid g1)" = "$R1" ] && [ "$(reqs)" = 4 ] && [ "$(deliv "$R1")" = "$d1" ] && [ "$(evs)" = "$e1" ]' "a second call reuses the pending request: no new request, delivery or event line"

# ---- the shipped data: the grant rows are identity-critical, so the apply needs the typed phrase ----
answer "$R1"; att g1 one
ok '[ $RC = 3 ] && J g1 ".code == \"STL-MDL-719\"" && grep -qF "consent.py complete $R1" "$T/o/g1.err" && [ "$(sends "consent.py complete $R1")" = 1 ] && [ "$(sha "$GF")" = "$g0" ]' \
  "approved: the gate cannot type the phrase, so the task stays waiting and the owner is told \`consent.py complete <id>\` (stderr, one inbox alert); nothing is applied"
att g1 one
ok '[ $RC = 3 ] && grep -qF "consent.py complete $R1" "$T/o/g1.err" && [ "$(sends "consent.py complete $R1")" = 1 ]' "asked again: the inbox is told once per request, stderr every time"
setsid -w $CO complete "$R1" </dev/null >"$T/o/c1" 2>&1; x=$?
ok '[ $x = 1 ] && grep -q STL-OWN-808 "$T/o/c1" && [ "$(sha "$GF")" = "$g0" ]' "complete with no terminal: refused STL-OWN-808, nothing applied"
typed "$GROW" $CO complete "$R1"; x=$?; G1=$(grow "$R1"); GID=$(jq -r '.id // empty' <<<"$G1")
ok '[ $x = 0 ] && [ "$(grows "$R1")" = 1 ] && [ "$(sha "$GF")" = "$(jq --indent 2 --argjson r "$ROW1" --arg i "$R1" ".crossing_grants += [\$r + {request_id: \$i}]" "$T/grants.keep" | sha256sum | cut -d" " -f1)" ] && check' \
  "complete on a terminal with the phrase: the file is the hashed candidate with the request id on its row, and passes check"
att g1 one
ok '[ $RC = 0 ] && J g1 ".link.connection == \"st-far\"" && jq -e --arg r "$R1" "[.consents[] | select(.request_id == \$r)] | length == 0" "$ST"' "then the task gets the link, and the settled request leaves the state"

# ---- revoke, pending ----
g1s=$(sha "$GF"); $CO revoke "$GID" --out "$T/rev.json" >"$T/o/rv" 2>"$T/o/rv.err"; x=$?
ok '[ -n "$GID" ] && [ $x = 0 ] && jq -e --arg g "$GID" "[.crossing_grants[] | select(.id == \$g and (.revoked_at | type == \"string\"))] | length == 1" "$T/rev.json" \
  && [ "$(stat -c %a "$T/rev.json")" = 600 ] && jq -e --arg t "$GROW" ".target == \$t" "$T/o/rv" && [ "$(sha "$GF")" = "$g1s" ]' "revoke writes the candidate (0600) with revoked_at on that grant and names the row to apply it to; it applies nothing"
$CO revoke "$GID" --out "$T/rev.json" >"$T/o/rv2" 2>&1; x=$?; $CO revoke st-no-such-grant --out "$T/rev2.json" >"$T/o/rv3" 2>&1; y=$?
ok '[ $x = 1 ] && grep -q STL-CFG-313 "$T/o/rv2" && [ $y = 1 ] && grep -q STL-CFG-311 "$T/o/rv3" && [ ! -e "$T/rev2.json" ]' "revoke never writes over a file (STL-CFG-313); an unknown grant id is STL-CFG-311 and writes no file"
typed "$GROW" python3 -I "$R/bin/stella-apply.py" apply "$GROW" --from "$T/rev.json"; x=$?; att g7 one; R3=$(reqid g7)
ok '[ $x = 0 ] && [ $RC = 3 ] && [ -n "$R3" ] && [ "$R3" != "$R1" ]' "once the owner applied the revoke, the next call of the project waits again, with a new request"
$CO pending --json >"$T/o/pend" 2>"$T/o/pend.err"; x=$?
ok '[ $x = 0 ] && jq -e --arg a "$R2C" --arg b "$R3" "length == 2 and ([.[] | select(.request_id == \$b and .status == \"pending\" and .grant.scope.project == \"st-one\")] | length == 1)
  and ([.[] | select(.request_id == \$a and .status == \"changed\")] | length == 1)" "$T/o/pend"' \
  "pending --json lists the requests not yet settled: the pending one, and as changed the one made before another grant was applied to the file"

# ---- denied, expired ----
answer "$R3" denied; setsid -w $CO complete "$R3" </dev/null >"$T/o/c3" 2>&1; x=$?
ok '[ $x = 1 ] && grep -q STL-OWN-821 "$T/o/c3" && [ "$(grows "$R3")" = 0 ]' "a denied request grants nothing: complete is refused (STL-OWN-821)"
ed "$RTREL" '.consent.ttl_s = 1'; att x1 three; R6=$(reqid x1); sleep 2; setsid -w $CO complete "$R6" </dev/null >"$T/o/c6" 2>&1; x=$?
ok '[ -n "$R6" ] && [ $x = 1 ] && grep -q STL-OWN-822 "$T/o/c6" && [ "$(grows "$R6")" = 0 ]' "an expired request (ttl 1 s) grants nothing: complete is refused (STL-OWN-822)"

# ---- unattended run mode, with fake entries as data only: a new approval class, queue alert code and ttl, a new project ----
FQ="${QUEUE%-*}-$((799))"   # a code the catalog does not hold, built here (the alert selftest reads every code a script spells out)
ed .stella/schemas/approval-request.schema.json '.properties.approval_class.enum += ["st-consent"]'
ed docs/hermes-local/alert-catalog.json --arg q "$QUEUE" --arg c "$FQ" '.alerts += [(.alerts[] | select(.code == $q)) + {code: $c, title: "selftest: a fake queue alert"}]'
cp "$T/routing.keep" "$RT"; ed "$RTREL" --arg c "$FQ" '.consent.approval_class = "st-consent" | .consent.ttl_s = 777 | .consent.alert_code_queue = $c'
SF=$R/$(jq -r --arg d "$(jq -r '.entries[] | select(.key == "UNATTENDED_MODE") | .store.data' "$R/$(rel settings)")" '.files[] | select(.id == $d) | .path' "$IDX")
mkdir -p "$(dirname "$SF")"; [ -f "$SF" ] && cp "$SF" "$T/store.keep"
echo "UNATTENDED_MODE=true" >>"$T/owner-fake.env"; echo "UNATTENDED_MODE='false'" >>"$SF"
att u1 new; R7=$(reqid u1)
ok 'check && [ $RC = 3 ] && J u1 ".code == \"STL-MDL-719\"" && [ "$(sends "$FQ")" = 0 ] && [ "$(rq "$R7" .approval_class)" = st-consent ] \
  && [ "$(rq "$R7" "(.expires_at | fromdateiso8601) - (.requested_at | fromdateiso8601)")" = 777 ] && [ "$(row "$R7" | jq -r .scope.project)" = st-new ]' \
  "the settings store says off (the owner file says on): the settings reader wins, the task waits; the request carries the fake class and ttl, for the new project"
if [ -f "$T/store.keep" ]; then cp "$T/store.keep" "$SF"; else rm -f "$SF"; fi
att u1 new
ok '[ $RC = 3 ] && J u1 --arg c "$FQ" ".code == \$c" && [ "$(reqid u1)" = "$R7" ] && [ "$(sends "$FQ")" = 1 ] && jq -e --arg r "$R7" ".queue.u1.request_id == \$r" "$ST"' \
  "unattended on (the owner file; the settings store holds no value): the task is queued with the data's queue code, named in the state's queue, one inbox alert; the request is reused"
n=$(reqs); att u1 new
ok '[ $RC = 3 ] && [ "$(sends "$FQ")" = 1 ] && [ "$(reqs)" = "$n" ]' "a retry of the queued task: no second alert, no second request"

# ---- a policy under which the grant rows need no phrase: the gate applies alone; a privacy grant ----
ed "$POLREL" --arg g "$GROW" --arg d "$DROW" '.identity_critical -= [$g, ($d + ":/privacy_grants")]'
answer "$R7"; att u1 new
ok '[ $RC = 0 ] && J u1 ".link.connection == \"st-far\"" && [ "$(grows "$R7")" = 1 ] && [ "$(grow "$R7" | jq -r .scope.project)" = st-new ] && jq -e ".queue == {}" "$ST" && check' \
  "approved where the rows are not identity-critical: the gate applies the grant with the owner key, the task gets the link and leaves the queue"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
ed "$AREL" '.selection.global = "st-all"'; ed "$RJREL" --arg r "$CR" --arg k "$GCLASS" '.roles[$r].requirements.allowed_data_classes = ((.roles[$r].requirements.allowed_data_classes // []) + [$k] | unique)'
d0=$(sha "$DF"); att p1 one; R8=$(reqid p1)
ok '[ -n "$GCLASS" ] && [ $RC = 3 ] && [ -n "$R8" ] && [ "$(rq "$R8" .action.target)" = "$DROW" ] && [ "$(rq "$R8" .action.old_digest)" = "$d0" ] && [ "$(sha "$DF")" = "$d0" ]' \
  "a link that needs a privacy grant: one request whose action targets the data policy's row"
answer "$R8"; kept "$R8"; cp "$DF" "$T/policy.old"; att p1 one
ok '[ $RC = 0 ] && grow "$R8" | jq -e --arg k "$GCLASS" ".data_class == \$k and .connection == \"st-far\" and .scope == {level: \"project\", project: \"st-one\"}" && check' \
  "approved: the privacy grant row (data class, connection, project scope, request id) is applied and the task gets the link"
cp "$T/policy.old" "$DF"; back; att p1 one; R8B=$(reqid p1)
ok '[ $RC = 3 ] && [ -n "$R8B" ] && [ "$R8B" != "$R8" ] && [ "$(sha "$DF")" = "$d0" ] && [ "$(rq "$R8B" .action.target)" = "$DROW" ]' \
  "its request is spent: the data policy put back to its old bytes and the state entry put back, the call asks again instead of applying it twice"
answer "$R8B"; att p1 one

# ---- still where the rows need no phrase: only an approved request that consent itself made applies, and only once ----
# (the project that holds the privacy grant: the crossing grant is then the only one its link needs)
ed "$AREL" '.selection.global = "st-cross"'; CC=$(jq -r .consent.approval_class "$RT")
OC=$(jq -r --arg c "$CC" '[.properties.approval_class.enum[] | select(. != $c)][0]' "$R/.stella/schemas/approval-request.schema.json")
word() { python3 -I "$R/bin/approvals.py" status "$1" --json 2>/dev/null | jq -r .status; }                # <request id>: the approval service's word
plant() {  # <consent's request> <jq change of its row> <approval class>: RF = an approved request of that class, not made by consent, for the apply of the changed row; the state entry is pointed at it
  local gk row; gk=$(gkey "$1"); row=$(row "$1" | jq -c "$2")
  jq -n --arg t "$GROW" --arg o "$(sha "$GF")" --arg n "$(jq --indent 2 --argjson r "$row" '.crossing_grants += [$r]' "$GF" | sha256sum | cut -d' ' -f1)" \
    '{op: "apply", target: $t, old_digest: $o, new_digest: $n}' >"$T/act.json"
  RF=$(python3 -I "$R/bin/approvals.py" request --class "$3" --action "$T/act.json" --summary "selftest: not a consent request" --card st-c-one --ttl 600 --json 2>/dev/null | jq -r '.id // empty'); answer "$RF"
  jq --arg k "$gk" --arg r "$RF" --argjson row "$row" '.consents[$k] += {request_id: $r, row: $row}' "$ST" >"$ST.n" && mv "$ST.n" "$ST"
}
att v1 one; R9=$(reqid v1); gv=$(sha "$GF"); att v1 one
ok '[ -n "$R9" ] && [ $RC = 3 ] && [ "$(reqid v1)" = "$R9" ] && [ "$(word "$R9")" = pending ] && J v1 ".link == null" && [ "$(grows "$R9")" = 0 ] && [ "$(sha "$GF")" = "$gv" ]' \
  "a pending request applies nothing here either: the task still waits on it, with no grant row and no link"
plant "$R9" '.scope = {level: "global"}' "$OC"; n=$(reqs); att v1 one; RN=$(reqid v1)
ok '[ -n "$OC" ] && [ "$(word "$RF")" = approved ] && [ $RC = 3 ] && [ -n "$RN" ] && [ "$RN" != "$RF" ] && [ "$(reqs)" = $((n + 1)) ] && [ "$(grows "$RF")" = 0 ] && [ "$(sha "$GF")" = "$gv" ]' \
  "an approved request of another approval class, which the state names with a Stella-wide row, applies nothing: the call asks again"
plant "$RN" '.scope.project = "st-elsewhere"' "$CC"; setsid -w $CO complete "$RF" </dev/null >"$T/o/cf" 2>&1; x=$?; att v1 one; RN2=$(reqid v1)
ok '[ "$(word "$RF")" = approved ] && [ $x = 1 ] && grep -q STL-CFG-311 "$T/o/cf" && [ $RC = 3 ] && [ -n "$RN2" ] && [ "$RN2" != "$RF" ] && [ "$(grows "$RF")" = 0 ] && [ "$(sha "$GF")" = "$gv" ]' \
  "an approved request of the consent class that consent did not make (its row for another project) applies nothing: complete refuses it (STL-CFG-311) and the call asks again"
answer "$RN2"; kept "$RN2"; cp "$GF" "$T/grants.old"; att v1 one; x=$RC; y=$(grows "$RN2")
cp "$T/grants.old" "$GF"; back
setsid -w $CO complete "$RN2" </dev/null >"$T/o/cs" 2>&1; z=$?; att v1 one; RN3=$(reqid v1)
ok '[ $x = 0 ] && [ "$y" = 1 ] && [ $z = 1 ] && grep -q STL-MDL-719 "$T/o/cs" && [ $RC = 3 ] && [ -n "$RN3" ] && [ "$RN3" != "$RN2" ] && [ "$(grows "$RN2")" = 0 ] && [ "$(sha "$GF")" = "$gv" ] && check' \
  "an approved request is spent once applied: the grant file put back to its old bytes and the state entry put back, complete refuses it and the call asks again"
# ---- a worker environment ----
n=$(reqs); bad=""
for c in "pending --json" "complete $R2C" "revoke $GID --out $T/w.json"; do
  # shellcheck disable=SC2086
  STUB_WORKER_MARK=1 $CO $c </dev/null >"$T/o/w" 2>&1; x=$?
  { [ $x = 1 ] && grep -q STL-CFG-312 "$T/o/w"; } || bad="$bad [$c: $x]"
done
w=$(STUB_WORKER_MARK=1 python3 -I "$T/gate.py" "{\"role\":\"$CR\",\"project\":\"st-four\",\"card\":\"st-c-four\",\"tier\":null,\"driver\":null,\"task\":\"w1\"}" '{"connection":"st-far","model":"st-far-m1"}' 2>/dev/null)
ok '[ -z "$bad" ] && [ ! -e "$T/w.json" ] && [ "$w" = STL-CFG-312 ] && [ "$(reqs)" = "$n" ]' "pending, complete, revoke and the gate itself refuse in a worker environment (STL-CFG-312): no file, no request${bad:+ (not:$bad)}"
echo "# consent-selftest: $fails failed"; [ $fails = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
