#!/usr/bin/env bash
# Hermetic self-test for bin/ledger.py (F2c item A1: usage ledger and limits). In a scratch root (a copy of bin, .stella, docs; its own HOME,
# temp, event log, alert log, limits.env) fake connections are added as DATA only. Cases: a record is appended, scrubbed, schema-checked and
# keyed by connection, model, role, project, card; an unknown connection or model fails closed with a code and one alert; a NEW connection
# added in the scratch catalog is counted and limited with no code change (T-LIM-FAKE); more real worker processes than the limit start and
# at most `limit` hold at once, a killed holder frees its slot, a link in the slot folder is refused (T-LIM-CONC); a limit that names a
# limits.env key (defined, undefined); the daily cap counts the records of the UTC day; observed limits (429 Retry-After, a CLI's limit
# text) expire by themselves and write one trusted event line each (T-LIM-OBS); plan share; status and report; records survive a killed
# writer; a worker environment is refused (T-CORE-LEDGER). Nothing here names a model: the models are fakes made below.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/ledger-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'kill $(jobs -p) 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "# KEPT $T"; else chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; fi' EXIT
R=$T/root
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$T/home" "$T/tmp" "$T/sup/logs" "$T/pb" "$T/run"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"
cd "$T" || exit 1
jq() { env -u HOME jq "$@"; }
IX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IX"; }
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$ROOT/$(ix .role_table)" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
for v in $(jq -r '.worker_signals.token_env[]?' "$R/$(ix '.files[] | select(.id == "owner-auth") | .path')" 2>/dev/null); do unset "$v"; done
cat >"$T/pb/hermes" <<'S'
#!/usr/bin/env bash
echo "[]"
S
chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH
AL=$T/sup/logs/alerts.log; : >"$AL"
fails=0
ok() { if ( set -o pipefail; eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
ed() { local f=$R/.stella/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <data file> <jq args and filter>
L() { python3 -I "$R/bin/ledger.py" "$@"; }
UL=$R/$(ix .usage_ledger); LS=$R/$(ix .ledger_state); EV=$R/$(ix .event_log)
evn() { grep -c "\"type\": *\"$1\"" "$EV" 2>/dev/null || true; }   # trusted event lines of a type
today=$(date -u +%F)

# ---- fake entries: data only ----
TPL='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "cloud" and (.aggregator | not))][0]'
mdl() { echo "{\"id\":\"$1\",\"capabilities\":{\"tool_calling\":null,\"json_mode\":null,\"context_tokens\":null,\"vision\":null,\"streaming\":null},\"probed_at\":null,\"probe_source\":null,\"cost\":null,\"limits\":$2}"; }
MODELS=$(jq -nc --argjson a "$(mdl qa-m1 '{"max_concurrent":3,"per_day":5}')" --argjson b "$(mdl qa-m2 '{"max_concurrent":"QA_CONC"}')" \
  --argjson c "$(mdl qa-m3 '{"per_day":2}')" --argjson d "$(mdl qa-m4 '{"max_concurrent":"QA_UNDEF"}')" --argjson e "$(mdl qa-m5 null)" \
  --argjson f "$(mdl qa-m6 '{"per_day":"QA_DAY"}')" '[$a,$b,$c,$d,$e,$f]')
ed connections.json --argjson ms "$MODELS" --arg g1 "$(cat /proc/sys/kernel/random/uuid)" --arg g2 "$(cat /proc/sys/kernel/random/uuid)" \
  --argjson x "$(mdl qa-x null)" --argjson y "$(mdl qa-y null)" \
  ".entries += [$TPL + {id: \"qa-new\", label: \"qa-new\", enabled: true, global_id: \$g1, models: \$ms, secrets: []},
                $TPL + {id: \"qa-two\", label: \"qa-two\", enabled: true, global_id: \$g2, models: [\$x, \$y], secrets: [], limits: {max_concurrent: 1}}]"
LIM=$R/$(ix '.files[] | select(.id == "limits") | .path'); mkdir -p "$(dirname "$LIM")"
printf 'QA_CONC=1\nQA_DAY=2 # a comment\nHAIKU_MAX_PER_DAY=100\n' >"$LIM"
CLI=$(jq -r '.entries[] | select(.type == "cli-login") | .id' "$R/.stella/connections.json" | head -1)   # the shipped cli-login connection
CM=$(jq -r --arg c "$CLI" '.entries[] | select(.id == $c) | .models[0].id' "$R/.stella/connections.json")
call() { jq -nc --arg c "$1" --arg m "$2" --arg o "${3:-ok}" --arg role "${4:-builder}" --arg card "${5:-card-1}" --argjson pl "${6:-null}" \
  '{connection: $c, model: $m, role: $role, project: "proj-a", card: $card, session: "s-1", outcome: $o, status: null,
    tokens: {input: 100, output: 20, cache_write: 0, cache_read: 50, reasoning: 0}, latency_ms: 123, batch: false, plan_share: $pl}'; }
rec() { call "$@" | L record --json; }   # <connection> <model> [outcome role card plan_share]

# ---- the record: schema, keys, scrub, fail closed ----
OUT=$(rec qa-new qa-m5 ok builder card-1); RC=$?
ok "[ $RC = 0 ] && [ \$(wc -l <'$UL') = 1 ]" "T-CORE-LEDGER a record is appended as one line of the usage file"
ok "jq -e '.v == 1 and .kind == \"call\" and .connection == \"qa-new\" and .model == \"qa-m5\" and .role == \"builder\" and .project == \"proj-a\" and .card == \"card-1\" and (.id | length > 10) and .cost == null and (.ts | test(\"^[0-9]{4}-..-..T..:..:..Z\$\"))' '$UL'" "the record is keyed by connection, model, role, project, card and carries id, UTC ts, cost null"
ok "L check --json | jq -e '.ok == true and .records == 1'" "check judges the usage file against its schema"
OUT=$(rec nowhere qa-m5 2>$T/err); RC=$?
ok "[ $RC = 1 ] && grep -q STL-LIM-410 $T/err && echo '$OUT' | jq -e '.code == \"STL-LIM-410\"' && [ \$(wc -l <'$UL') = 1 ] && [ \$(grep -c STL-LIM-410 '$AL') = 1 ]" "an unknown connection fails closed: code, plain message, one alert, nothing recorded"
OUT=$(rec qa-new nomodel 2>$T/err); RC=$?
ok "[ $RC = 1 ] && grep -q STL-LIM-410 $T/err && [ \$(wc -l <'$UL') = 1 ] && [ \$(grep -c STL-LIM-410 '$AL') = 2 ]" "an unknown model of a known connection fails closed the same way"
OUT=$(call qa-new qa-m5 | jq '.tokens.input = -1' | L record --json 2>$T/err); RC=$?
ok "[ $RC = 1 ] && grep -q STL-LIM-411 $T/err && [ \$(wc -l <'$UL') = 1 ]" "a record that breaks the schema (negative tokens) is refused, STL-LIM-411"
OUT=$(echo 'not json' | L record --json 2>$T/err); RC=$?
ok "[ $RC = 1 ] && grep -q STL-LIM-411 $T/err" "input that is no JSON is refused with a code, never a traceback"
SEC=sekretvalue$RANDOM$RANDOM
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import event_log as el, ledger
el.SECRETS.add(sys.argv[2])
ledger.record({"connection": "qa-new", "model": "qa-m5", "role": "builder", "project": "proj-a", "card": "card-" + sys.argv[2], "session": None, "outcome": "ok"})' "$R/bin" "$SEC" 2>/dev/null
ok "! grep -q '$SEC' '$UL' && grep -q 'card-\*\*\*' '$UL'" "a secret value is scrubbed from a record (event_log scrub) before it is written"
ok "python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import ledger; r = ledger.record({\"connection\": \"qa-new\", \"model\": \"qa-m5\", \"outcome\": \"ok\"}, cost={\"amount\": 0.5, \"currency\": \"USD\", \"entry\": \"e1\", \"priced\": True}); sys.exit(0 if r[\"cost\"][\"amount\"] == 0.5 and r[\"tokens\"][\"input\"] == 0 else 1)' '$R/bin'" "record() takes a cost already computed (cost null otherwise), tokens default to 0"

# ---- a NEW connection is counted and limited with no code change (T-LIM-FAKE) ----
for i in 1 2; do rec qa-new qa-m1 >/dev/null; done
ok "L status --connection qa-new --model qa-m1 --json | jq -e '.concurrency.limit == 3 and .concurrency.in_use == 0 and .concurrency.free == 3 and .daily.cap == 5 and .daily.used == 2 and (.daily.resets_at | test(\"^[0-9-]+T00:00:00Z\$\")) and .observed == null and .plan_share == null'" "T-LIM-FAKE status of a fake model: limits read from the catalog, usage counted from its records, no code change"
for i in 1 2 3; do rec qa-new qa-m1 >/dev/null; done
L hold --connection qa-new --model qa-m1 -- true 2>$T/err; RC=$?
ok "[ $RC = 76 ] && grep -q STL-LIM-412 $T/err && grep -qi 'daily' $T/err" "T-LIM-FAKE the daily cap used (5 of 5 records of the UTC day) refuses a hold, exit 76"
ok "L status --connection qa-new --model qa-m1 --json | jq -e '.daily.used == 5 and .daily.cap == 5'" "the daily count is the records of the UTC day"
python3 -I - "$UL" <<'P'
import json, sys   # yesterday's records are not counted: age every record of qa-m1 by one day
p = sys.argv[1]; out = []
for l in open(p):
    r = json.loads(l)
    if r["model"] == "qa-m1":
        r["ts"] = "2000-01-01T00:00:00Z"
    out.append(json.dumps(r))
open(p, "w").write("\n".join(out) + "\n")
P
ok "L status --connection qa-new --model qa-m1 --json | jq -e '.daily.used == 0' && L hold --connection qa-new --model qa-m1 -- true" "records of an earlier UTC day are not counted: the link is free again"
L hold --connection qa-new --model qa-m1 -- sh -c 'exit 7'; RC=$?
ok "[ $RC = 7 ]" "hold runs the command and its exit code is the command's"
rec qa-new qa-m3 >/dev/null; rec qa-new qa-m3 refused >/dev/null
ok "L status --connection qa-new --model qa-m3 --json | jq -e '.daily.used == 1 and .daily.cap == 2 and .concurrency.limit == null'" "a refused call is not counted against the daily cap; a model with no slot limit shows none"
ok "L status --connection qa-new --model qa-m6 --json | jq -e '.daily.cap == 2'" "a per_day naming a limits.env key (a comment after the value) reads its value"
ok "L status --connection qa-new --model qa-m2 --json | jq -e '.concurrency.limit == 1'" "a max_concurrent naming a limits.env key reads its value"
L hold --connection qa-new --model qa-m4 -- true 2>$T/err; RC=$?
ok "[ $RC = 75 ] && grep -q STL-LIM-412 $T/err" "a limit naming a key limits.env does not define is zero: no slot (as escalate.sh), exit 75"
ok "L status --connection qa-new --model qa-m4 --json | jq -e '.concurrency.limit == 0 and .concurrency.free == 0 and (.problems | length) == 1'" "the unreadable limit is named in status problems"

# ---- slots hold across processes (T-LIM-CONC) ----
cat >"$T/work.sh" <<'W'
#!/bin/sh
touch "$RUNDIR/$$"; sleep "$HOLD"; rm -f "$RUNDIR/$$"
W
printf '#!/bin/sh\ntouch "$RUNDIR/$$"; exec sleep 60\n' >"$T/hang.sh"   # the process itself holds the slot (no child keeps the lock after a kill)
chmod +x "$T/work.sh" "$T/hang.sh"
export RUNDIR=$T/run HOLD=6
( mx=0; for _ in $(seq 140); do n=$(ls "$RUNDIR" | wc -l); [ "$n" -gt "$mx" ] && mx=$n; sleep 0.1; done; echo $mx >"$T/max" ) &
SAMP=$!
for i in $(seq 8); do ( L hold --connection qa-new --model qa-m1 --holder w$i -- "$T/work.sh" 2>/dev/null; echo $? >"$T/rc.$i" ) & done
wait $SAMP
for i in $(seq 8); do wait; break; done
ok "[ \$(cat $T/max) = 3 ]" "T-LIM-CONC 8 real worker processes against a limit of 3: at most 3 hold at once, and 3 did"
ok "[ \$(cat $T/rc.* | grep -c '^0\$') = 3 ] && [ \$(cat $T/rc.* | grep -c '^75\$') = 5 ]" "T-LIM-CONC three ran, five got exit 75 (no free slot)"
ok "[ \$(evn limit.hit) -ge 5 ]" "each refused hold wrote a trusted limit.hit event line"
ok "L status --connection qa-new --model qa-m1 --json | jq -e '.concurrency.in_use == 0 and .concurrency.free == 3'" "all slots are free once the commands ended"
L hold --connection qa-new --model qa-m2 -- "$T/hang.sh" &
for _ in $(seq 100); do [ -n "$(ls "$RUNDIR")" ] && break; sleep 0.1; done
ok "L status --connection qa-new --model qa-m2 --json | jq -e '.concurrency.in_use == 1 and .concurrency.free == 0'" "status shows the slot in use while a holder runs"
L hold --connection qa-new --model qa-m2 -- true 2>/dev/null; RC=$?
ok "[ $RC = 75 ]" "T-LIM-CONC a second hold on a limit of 1 is refused"
kill -9 $(ls "$RUNDIR"); sleep 0.3; rm -f "$RUNDIR"/*
ok "L hold --connection qa-new --model qa-m2 -- true" "T-LIM-CONC a killed holder frees its slot"
L hold --connection qa-two --model qa-x -- "$T/hang.sh" &
for _ in $(seq 100); do [ -n "$(ls "$RUNDIR")" ] && break; sleep 0.1; done
L hold --connection qa-two --model qa-y -- true 2>/dev/null; RC=$?
ok "[ $RC = 75 ]" "T-LIM-FAKE a connection's own limit holds across its models (qa-x busy, qa-y refused)"
kill -9 $(ls "$RUNDIR"); sleep 0.3; rm -f "$RUNDIR"/*
SD=$LS.slots; mkdir -p "$SD"; for f in "$SD"/qa-new@qa-m2.*; do [ -e "$f" ] && { rm -f "$f"; ln -s "$T/home" "$f"; }; done
L hold --connection qa-new --model qa-m2 -- true 2>$T/err; RC=$?
ok "[ $RC = 1 ] && grep -q STL-LIM-413 $T/err" "a slot file that is a symbolic link is refused (no write through it), STL-LIM-413"
rm -f "$SD"/qa-new@qa-m2.*

# ---- observed limits and their expiry (T-LIM-OBS) ----
ed limit-signals.json '.default_wait_seconds = 2'   # the wait of a limit that names no time: short, so expiry is seen here
RH=$(jq -r '.headers.reset[0]' "$R/.stella/limit-signals.json")
E0=$(evn limit.observed)
printf '{"error": {"message": "too many requests"}}' | L observe --connection qa-new --model qa-m5 --status 429 --header 'Retry-After: 3' --json >"$T/obs" 2>"$T/err"; RC=$?
ok "[ $RC = 0 ] && jq -e '.connection == \"qa-new\" and .model == \"qa-m5\" and .source == \"retry_after\"' $T/obs" "T-LIM-OBS a 429 with Retry-After is observed (source retry_after)"
ok "L status --connection qa-new --model qa-m5 --json | jq -e '.observed.source == \"retry_after\" and (.observed.until | test(\"Z\$\"))'" "status shows the observed limit"
L hold --connection qa-new --model qa-m5 -- true 2>$T/err; RC=$?
ok "[ $RC = 77 ] && grep -q STL-LIM-412 $T/err" "an active observed limit refuses a hold, exit 77"
ok "[ \$(evn limit.observed) = $((E0 + 1)) ]" "T-LIM-OBS one trusted limit.observed event line for the observation"
ok "L status --connection qa-new --model qa-m1 --json | jq -e '.observed == null'" "an observed limit of one model does not limit another"
sleep 4
ok "L status --connection qa-new --model qa-m5 --json | jq -e '.observed == null' && L hold --connection qa-new --model qa-m5 -- true" "T-LIM-OBS the observed limit expires by itself (3 s): the link serves again"
printf '{"error": {"message": "internal error"}}' | L observe --connection qa-new --model qa-m5 --status 500 --json >"$T/obs"; RC=$?
ok "[ $RC = 0 ] && jq -e '. == null' $T/obs && L status --connection qa-new --model qa-m5 --json | jq -e '.observed == null'" "an answer that is no limit (a 5xx) observes nothing"
printf '{"error": {"message": "per minute"}}' | L observe --connection qa-new --model qa-m5 --status 429 --header "$RH: 2s" --json >"$T/obs"; RC=$?
ok "[ $RC = 0 ] && jq -e '.source == \"reset_header\"' $T/obs" "a rate-limit reset header (name from the signals data) sets the time"
sleep 3
printf '{"error": {"message": "daily quota exhausted"}}' | L observe --connection qa-new --model qa-m6 --status 429 --json >"$T/obs"; RC=$?
ok "[ $RC = 0 ] && jq -e '.source == \"daily_cap\" and (.until | test(\"T00:00:00Z\$\"))' $T/obs" "a daily cap with no time lasts to the next UTC midnight"
printf '{"error": {"message": "slow down"}}' | L observe --connection qa-two --status 429 --json >"$T/obs"
L hold --connection qa-two --model qa-y -- true 2>/dev/null; RC=$?
ok "[ $RC = 77 ]" "an observation on a connection (no model) limits every model of it"
sleep 3
printf 'usage limit reached for this plan; try again later' | L observe --connection "$CLI" --json >"$T/obs" 2>"$T/err"; RC=$?
ok "[ $RC = 0 ] && jq -e '.source == \"cli_limit_error\" and .model == null' $T/obs" "T-LIM-OBS a cli-login CLI's limit text (patterns from the signals data) is observed"
ok "L status --connection '$CLI' --model '$CM' --json | jq -e '.plan_share == 1 and .observed.source == \"cli_limit_error\"'" "an observed CLI limit puts plan_share at 1"
printf 'all fine here' | L observe --connection "$CLI" --json >"$T/obs"
ok "jq -e '. == null' $T/obs" "CLI text that is no limit error observes nothing"
sleep 3
ok "L status --connection '$CLI' --model '$CM' --json | jq -e '.observed == null and .plan_share == null'" "the CLI limit expires too; plan_share is null when the CLI gave none"
rec "$CLI" "$CM" ok builder card-2 0.4 >/dev/null
ok "L status --connection '$CLI' --model '$CM' --json | jq -e '.plan_share == 0.4'" "plan_share of a cli-login connection is the newest record's share"
ed limit-signals.json --arg c "$(jq -r --arg c "$CLI" '.entries[] | select(.id == $c) | .cli' "$R/.stella/connections.json")" '.cli_usage[$c] = ["(?P<pct>[0-9.]+)% of your limit"]'
ok "[ \"\$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import ledger; print(ledger.plan_share_from(sys.argv[2], \"you used 42% of your limit\"), ledger.plan_share_from(sys.argv[2], \"nothing\"))' '$R/bin' '$CLI')\" = '0.42 None' ]" "plan_share_from reads the CLI's usage text by data patterns (null when none matches)"
ok "jq -e '.schema_version == 1 and (.observed | type == \"array\")' '$LS'" "the observed limits are kept in the ledger state file"
ok "L check --json | jq -e '.ok == true'" "check judges the usage file and the state file"
ok "python3 -I $R/bin/stella_data.py check >/dev/null 2>&1" "the data check passes with the new signals file and index keys"
ed limit-signals.json '.default_wait_seconds = -1'
ok "! python3 -I $R/bin/stella_data.py check >/dev/null 2>&1" "a signals file that breaks its schema fails the data check"
ed limit-signals.json '.default_wait_seconds = 2'

# ---- report ----
ok "L report --by card --json | jq -e '.groups[\"card-2\"].calls == 1 and .groups[\"card-2\"].tokens.input == 100 and .groups[\"card-2\"].tokens.cache_read == 50'" "report by card sums calls and tokens"
ok "L report --by connection --json | jq -e '.groups[\"qa-new\"].calls > 3 and .groups[\"$CLI\"].calls == 1'" "report by connection"
for by in project role model; do ok "L report --by $by --json | jq -e '.by == \"$by\" and (.groups | length) > 0'" "report by $by"; done
L report --by nonsense --json 2>/dev/null; RC=$?
ok "[ $RC = 2 ]" "an unknown report key is a usage error (exit 2)"

# ---- a killed writer loses nothing ----
N0=$(grep -c '' "$UL")
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import ledger
while True: ledger.record({"connection": "qa-new", "model": "qa-m5", "outcome": "ok", "card": "kw"})' "$R/bin" >/dev/null 2>&1 & KW=$!
sleep 2; kill -9 $KW; wait $KW 2>/dev/null
NK=$(grep -c '"card":"kw"' "$UL")
ok "[ $NK -gt 0 ] && L check --json | jq -e '.ok == true'" "records survive a killed writer: every complete line reads back and check is ok"
printf '{"v":1,"id":"torn' >>"$UL"
rec qa-new qa-m5 ok builder after-kill >/dev/null
ok "grep -c 'after-kill' '$UL' | grep -qx 1 && L check --json | jq -e '.ok == true and .torn == 1' && L report --by card --json | jq -e '.groups[\"kw\"].calls == $NK'" "a torn last line is skipped and counted; the next record starts on a new line"

# ---- core contract ----
ok "(STUB_WORKER_MARK=1 L status --connection qa-new --json 2>&1 || true) | grep -q STL-CFG-312" "T-CORE-LEDGER a worker environment is refused (STL-CFG-312)"
L bogus 2>/dev/null; RC=$?
ok "[ $RC = 2 ]" "a usage error exits 2"
ok "(L status --connection nowhere --json 2>&1 || true) | grep -q STL-LIM-410" "status of an unknown connection fails closed with a code"
ok "jq -e '.entries[] | select(.id == \"ledger\") | .status == \"approved\"' '$ROOT/.stella/capabilities.json'" "the ledger command is in the capability registry"
if [ "$fails" -eq 0 ]; then echo "ledger selftest OK"; else echo "ledger selftest FAIL ($fails)"; exit 1; fi
