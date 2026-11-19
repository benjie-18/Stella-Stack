#!/usr/bin/env bash
# Hermetic self-test for bin/route.py (F2 W4: model call and failover, design D3 with design-check DC-06, DC-07, DC-10, DC-11).
# A scratch root (STELLA_ROOT, a copy of the tree's bin, data and docs) with fake connections made with jq from a shipped catalog
# entry, bin/mock_provider.py on a free port, a stand-in bin/resolve.py that returns a fixture chain (the resolver's contract:
# resolve(ctx), link_key(link)), a stub consent module where a case needs one, a stub `hermes` that records every send, and a
# folder key backend. Every id (triggers, link classes, wire shapes, alert codes of the routing data) is read from the data.
# Cases: each failover trigger of the routing data moves the call on with one switch line; a trigger of scope connection leaves the
# connection; the same connection's next model goes first; cooldown doubles up to its cap and one success clears it; the loop guard
# and the switch limit; the mid-task checks (context window, a link that may not be switched to mid-task, a link with no wire shape,
# a pending tool call on another wire shape); a retry on the same link; an error no row maps; the less-private notice; a link that
# needs a grant (no card, the consent gate's answers, no consent module); attempt and result; the state file as a link; a worker
# environment; no resolver; the pick line; a prompt that holds placeholder text; the key in no output, log, event or state.
# Gate B cases (a second small server that answers what a file holds): a proxy in the environment; an answer that repeats the key;
# answers, tool-call arguments and a state file nested too deeply; an unexpected error; a consent module outside the tool's folder
# and a run without -I; one event line per cooldown set or cleared; a switch from the link a task last used when another task
# cooled it, and the switch limit; the notice's bar; an answer that drips in; a prompt that is not UTF-8; history entries of
# another shape; an empty answer; a task id that is too long; the bound on task entries.
set -u
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/failover-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'kill $(jobs -p) 2>/dev/null; chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
R=$T/root; MR=$T/mockroot
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$MR" "$T/home" "$T/tmp" "$T/sup/logs" "$T/o" "$T/pb"
cp -r "$H/bin" "$H/.stella" "$H/docs" "$R/"; cp -r "$H/.stella" "$H/docs" "$MR/"   # the mock keeps the wire shapes as shipped
IDX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IDX"; }
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$H/$(ix .role_table)" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
for v in $(jq -r '.worker_signals.token_env[]?' "$R/$(ix '.files[] | select(.id == "owner-auth") | .path')" 2>/dev/null); do unset "$v"; done
# the board stub: `roles.py prove` sees no worker run; every send is one recorded line
cat >"$T/pb/hermes" <<'S'
#!/usr/bin/env bash
case " $* " in *" send "*) printf '%s\n' "$*" | tr '\n' ' ' >>"$ESCALATE_SUP_DIR/sends"; echo >>"$ESCALATE_SUP_DIR/sends"; exit 0;; esac
echo "[]"
S
chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH
fails=0
ok() { if ( eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
ed() { local f=$R/.stella/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <data file> <jq args and filter>

# ---- the mock, the fake catalog, the keys, the stand-in resolver ----
STELLA_ROOT=$MR python3 -I "$H/bin/mock_provider.py" >"$T/mock.out" 2>"$T/mock.err" &
for i in $(seq 100); do [ -s "$T/mock.out" ] && break; sleep 0.1; done
PORT=$(jq -r '.port' "$T/mock.out" 2>/dev/null); CTL=$(jq -r '.control' "$T/mock.out" 2>/dev/null); LO=$(jq -r '.control | capture("//(?<h>[^:/]+):").h' "$T/mock.out" 2>/dev/null)
export NO_PROXY=$LO no_proxy=$LO
cat >"$T/http.py" <<'P'
import sys, urllib.request
o = urllib.request.build_opener(urllib.request.ProxyHandler({}))
rq = urllib.request.Request(sys.argv[2], data=open(sys.argv[3], "rb").read(), method="POST") if sys.argv[1] == "post" else sys.argv[2]
sys.stdout.write(o.open(rq, timeout=10).read().decode())
P
SHAPE0=$(jq -r '.entries[0].id' "$R/.stella/protocols.json"); SHAPE1=$(jq -r '.entries[1].id' "$R/.stella/protocols.json")
KN=ST_FAKE_KEY; KEY="stkey$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
TPL='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "cloud" and (.aggregator | not))][0]'
mdl() { echo "{\"id\":\"$1\",\"capabilities\":{\"tool_calling\":true,\"json_mode\":true,\"context_tokens\":$2,\"vision\":true,\"streaming\":true},\"probed_at\":null,\"probe_source\":\"advertised\",\"cost\":null,\"limits\":null}"; }
prov() {  # <id> <wire shape id or empty> <context tokens>: a fake connection (two models) on the mock, made from a shipped entry
  ed connections.json --arg id "$1" --arg s "$2" --argjson m "[$(mdl "$1-m1" "$3"),$(mdl "$1-m2" "$3")]" --arg g "$(cat /proc/sys/kernel/random/uuid)" \
    --arg h "$LO" --argjson p "$PORT" --arg k "$KN" \
    ".entries += [$TPL + {id: \$id, label: \$id, enabled: true, global_id: \$g, models: \$m, secrets: [\$k], hosts: [{host: \$h, port: \$p, purpose: \"selftest mock\"}]}
       | if \$s == \"\" then del(.protocol) else .protocol = \$s end]"
}
prov st-a "$SHAPE0" 100000; prov st-b "$SHAPE0" 100000; prov st-t "$SHAPE0" 16; prov st-o "$SHAPE1" 100000; prov st-n "" 100000
# the probe records (F2b item C): route.py's context check reads a link's effective context there, never the catalog; each fake model is
# recorded at the context the fixture gives it, family st-fam
PF=$R/$(ix .probe_records); mkdir -p "$(dirname "$PF")"
recs() { jq --arg i "$(jq -r .install_id "$R/$(ix '.files[] | select(.schema == "install") | .path')")" --arg o "$(jq -r '.probe.output_shapes[-1]' "$R/.stella/routing.json")" \
  '{schema_version: 1, records: [.entries[] | select(.id | startswith("st-")) | .id as $c | .models[] | {global_id: "00000000-0000-4000-8000-000000000000", install_id: $i,
    connection: $c, model: .id, version: "st", probed_at: "2026-01-01T00:00:00Z", family: "st-fam", tool_calling: true, parallel_tool_calls: null, json: true, vision: true,
    output_shape: $o, context: {advertised: .capabilities.context_tokens, effective: .capabilities.context_tokens, short_score: 1, points: []}, code: null}]}' \
  "$R/.stella/connections.json" >"$PF"; }
recs
ed protocols.json '.entries |= map(.request.path = "/" + .id + .request.path)'   # the mock serves each shape under its id
cp "$R/.stella/protocols.json" "$T/protocols.keep"
CD=$(ix .backup_dir)/st-keys; mkdir -p "$R/$CD"; chmod 700 "$R/$CD"; (umask 077; printf '%s' "$KEY" >"$R/$CD/$KN")
ed routing.json --arg p "$CD" '.credentials.backend = "st-dir" | .credentials.backends["st-dir"] = {kind: "dir", path: $p}'
cp "$R/.stella/routing.json" "$T/routing.keep"
LIM=$R/$(ix '.files[] | select(.id == "limits") | .path'); mkdir -p "$(dirname "$LIM")"; echo "CALL_TIMEOUT=2" >>"$LIM"
cat >"$R/bin/resolve.py" <<'P'
"""Selftest stand-in for the resolver: the fixture chain document <root>/chain.json; the last ctx is kept in <root>/ctx.json."""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def link_key(link):
    return f"{link['connection']}/{link['model']}"
def resolve(ctx):
    with open(os.path.join(ROOT, "ctx.json"), "w") as f:
        json.dump(ctx, f)
    with open(os.path.join(ROOT, "chain.json")) as f:
        return json.load(f)
P
RT=$R/.stella/routing.json
P0=$(jq -r '.link_classes | sort_by(.privacy_rank) | .[0].id' "$RT"); P1=$(jq -r '.link_classes | sort_by(.privacy_rank) | .[1].id' "$RT"); P2=$(jq -r '.link_classes | sort_by(.privacy_rank) | .[-1].id' "$RT")
NOTICE=$(jq -r '.consent.alert_code_notice' "$RT"); QUEUE=$(jq -r '.consent.alert_code_queue' "$RT")
TRIGGERS=$(jq -r '.failover.triggers | keys[]' "$RT")
LT=$(jq -r '[.failover.triggers | to_entries[] | select(.value.scope == "link" and .value.cooldown_s > 0) | .key][0]' "$RT")   # a trigger that cools one link
CT=$(jq -r '[.failover.triggers | to_entries[] | select(.value.scope == "connection") | .key][0]' "$RT")                       # one that cools the connection
ROLE=$(jq -r '.roles | keys[0]' "$RJ"); STATE=$R/$(ix .routing_state); EV=$R/$(ix .event_log); SENDS=$T/sup/sends
chain() {  # <connection/model[,status[,link class[,nomid]]]>...: the chain document the stand-in returns
  local a='[]' s l st cl mid
  for s; do IFS=, read -r l st cl mid <<<"$s"
    a=$(jq -c --arg c "${l%%/*}" --arg m "${l#*/}" --arg st "${st:-usable}" --arg cl "${cl:-$P1}" --arg mid "${mid:-}" '. + [{connection: $c, model: $m, parameters: {},
      link_class: $cl, source: "preset", status: $st, code: null, reason: (if $st == "usable" then null else "fixture" end), grant: null, mid_task: ($mid != "nomid"), cooldown_until: null}]' <<<"$a")
  done
  jq -n --argjson ch "$a" '{preset: {id: "fixture", source: "global"}, chain: $ch, decision: {rule: "fixture", reason: "fixture reason 7c1"}, failure_history: [], stubs: ["st-resolver-stub"]}' >"$R/chain.json"
}
shape_of() { jq -r --arg c "${1%%/*}" '.entries[] | select(.id == $c) | .protocol' "$R/.stella/connections.json"; }
fault() { echo "{\"shape\":\"$(shape_of "$1")\",\"model\":\"${1#*/}\",\"fault\":\"$2\"${3:+,$3}}"; }   # <connection/model> <fault> [extra]
fresh() {  # <faults JSON array>: no failover state, every fake model served with these faults, the call counts remembered
  rm -f "$STATE"
  jq -c --argjson f "${1:-[]}" '{models: ([.entries[] | select((.id | startswith("st-")) and .protocol != null)] | group_by(.protocol) | map({(.[0].protocol): [.[].models[].id]}) | add), faults: $f}' \
    "$R/.stella/connections.json" >"$T/ctl.json"
  python3 -I "$T/http.py" post "$CTL" "$T/ctl.json" >/dev/null 2>&1; python3 -I "$T/http.py" get "http://$LO:$PORT/_calls" >"$T/c0" 2>/dev/null
}
cnt() {  # <connection/model>: the calls the mock counted on that link since fresh
  python3 -I "$T/http.py" get "http://$LO:$PORT/_calls" >"$T/c1" 2>/dev/null
  echo $(( $(jq --arg k "$(shape_of "$1")/${1#*/}" '.counts[$k] // 0' "$T/c1") - $(jq --arg k "$(shape_of "$1")/${1#*/}" '.counts[$k] // 0' "$T/c0") ))
}
rt() {  # <name> <route.py arguments>...: stdout $T/o/<name>.json, stderr $T/o/<name>.err, the exit code in RC
  printf '%s' "${PROMPT:-say ok}" | timeout 60 python3 -I "$R/bin/route.py" "${@:2}" >"$T/o/$1.json" 2>"$T/o/$1.err"; RC=$?
}
call() { rt "$1" call --role "$ROLE" --project st-project --task "$1" --json "${@:2}"; }   # <task, also the output name> [more arguments]
J() { [ -s "$T/o/$1.json" ] && jq -e "${@:2}" "$T/o/$1.json"; }                               # <name> <jq args and filter>: holds on the JSON (jq -e passes empty input)
ev() { jq -c --arg w "task $1" "select(.what == \$w and ($2))" "$EV" 2>/dev/null | grep -c .; }   # <task> <jq condition>: its trusted event lines that match
sends() { grep -F -- "$1" "$SENDS" 2>/dev/null | grep -cF -- "task $2"; }                       # <code> <task>: inbox alerts sent
SW='.type == "routing.switch" and .code == "STL-MDL-721"'

ok '[ -n "$PORT" ] && python3 -I "$R/bin/stella_data.py" check' "S0 the mock runs on a free port and the scratch data (fake connections, folder key backend) passes check"

# ---- every trigger of the routing data moves the call on ----
for t in $TRIGGERS; do
  x=; [ "$t" = timeout ] && x='"seconds":6'; [ "$t" = context_too_small ] && x='"tokens":0'
  chain st-a/st-a-m1 st-b/st-b-m1; fresh "[$(fault st-a/st-a-m1 "$t" "$x")]"; call "tr-$t"
  ok '[ $RC = 0 ] && [ "$(cnt st-a/st-a-m1)" = 1 ] && [ "$(cnt st-b/st-b-m1)" = 1 ] && J "tr-$t" ".link.connection == \"st-b\" and .text == \"ok\" and .switches == 1" && [ "$(ev "tr-$t" "$SW")" = 1 ] \
    && J "tr-$t" --arg t "$t" ".failure_history == [{link: \"st-a/st-a-m1\", trigger: \$t, at: .failure_history[0].at}]"' "trigger $t: one call on the failing link, the next link answers, one switch line, the failure in the history"
done

# ---- scope, order, cooldown ----
chain st-a/st-a-m1 st-a/st-a-m2 st-b/st-b-m1; fresh "[$(fault st-a/st-a-m1 "$CT")]"; call conn
ok '[ $RC = 0 ] && [ "$(cnt st-a/st-a-m2)" = 0 ] && [ "$(cnt st-b/st-b-m1)" = 1 ] && jq -e --arg t "$CT" ".links[\"st-a\"].trigger == \$t" "$STATE"' "a trigger of scope connection ($CT) cools the whole connection: its next model is not called"
chain st-a/st-a-m1 st-b/st-b-m1 st-a/st-a-m2; fresh "[$(fault st-a/st-a-m1 "$LT")]"; call same
ok '[ $RC = 0 ] && [ "$(cnt st-a/st-a-m2)" = 1 ] && [ "$(cnt st-b/st-b-m1)" = 0 ]' "a trigger of scope link ($LT): the same connection's next model goes before the next connection"
ed routing.json --arg t "$LT" '.failover.triggers[$t].cooldown_s = 100 | .failover.triggers[$t].max_cooldown_s = 150'; fresh
rt cd1 result --task cd-1 --link st-a/st-a-m1 --outcome "$LT"
ok '[ $RC = 0 ] && jq -e ".links[\"st-a/st-a-m1\"] | .failures == 1 and ((.until | fromdateiso8601) - now | . > 90 and . <= 100)" "$STATE"' "a first failure: cooldown_s ahead"
rt cd2 result --task cd-2 --link st-a/st-a-m1 --outcome "$LT"
ok '[ $RC = 0 ] && jq -e ".links[\"st-a/st-a-m1\"] | .failures == 2 and ((.until | fromdateiso8601) - now | . > 140 and . <= 150) and .since <= .until" "$STATE"' "a repeated failure doubles the cooldown, up to max_cooldown_s"
chain st-a/st-a-m1 st-b/st-b-m1; call cd3
ok '[ $RC = 0 ] && [ "$(cnt st-a/st-a-m1)" = 0 ] && [ "$(cnt st-b/st-b-m1)" = 1 ] && [ "$(ev cd3 "$SW")" = 0 ]' "a link in cooldown is skipped by another task, with no switch line (nothing failed in that task)"
rt cd4 result --task cd-4 --link st-a/st-a-m1 --outcome ok
ok '[ $RC = 0 ] && jq -e ".links | has(\"st-a/st-a-m1\") | not" "$STATE"' "one success clears the cooldown"
rt cd5 result --task cd-5 --link st-a/st-a-m1 --outcome st-no-trigger; a=$RC; rt cd6 result --task cd-6 --link st-a/st-none --outcome ok
ok '[ $a = 1 ] && [ $RC = 1 ] && grep -q STL-MDL-711 "$T/o/cd5.err" && grep -q STL-MDL-711 "$T/o/cd6.err" && jq -e ".links == {}" "$STATE"' "result refuses an unknown trigger and a link the catalog does not have (STL-MDL-711), the state unchanged"
cp "$T/routing.keep" "$RT"

# ---- the loop guard, the switch limit, a retry, an error no row maps ----
chain st-a/st-a-m1 st-b/st-b-m1 st-a/st-a-m1; fresh "[$(fault st-a/st-a-m1 "$LT"),$(fault st-b/st-b-m1 "$LT")]"; call loop
ok '[ $RC = 1 ] && [ "$(cnt st-a/st-a-m1)" = 1 ] && [ "$(cnt st-b/st-b-m1)" = 1 ] && J loop ".code == \"STL-MDL-723\"" && grep -q STL-MDL-723 "$T/o/loop.err"' "the loop guard: a link that failed in the task is never called again (STL-MDL-723)"
ed routing.json '.failover.max_switches_per_task = 1'; chain st-a/st-a-m1 st-b/st-b-m1 st-b/st-b-m2; fresh "[$(fault st-a/st-a-m1 "$LT"),$(fault st-b/st-b-m1 "$LT")]"; call limit
ok '[ $RC = 1 ] && [ "$(cnt st-b/st-b-m2)" = 0 ] && J limit ".code == \"STL-MDL-723\"" && [ "$(ev limit "$SW")" = 1 ]' "at most max_switches_per_task switches: the third link is not called (STL-MDL-723)"
cp "$T/routing.keep" "$RT"; ed routing.json '.failover.retry_count = 1'
chain st-a/st-a-m1 st-b/st-b-m1; fresh "[$(fault st-a/st-a-m1 "$LT" '"calls":1')]"; call retry
ok '[ $RC = 0 ] && [ "$(cnt st-a/st-a-m1)" = 2 ] && [ "$(cnt st-b/st-b-m1)" = 0 ] && J retry ".link.connection == \"st-a\" and .switches == 0"' "retry_count 1: the same link is tried once more and answers, no switch"
cp "$T/routing.keep" "$RT"
NR=$(jq -c --arg s "$SHAPE0" '[.entries[] | select(.id == $s) | .errors[] | select((has("body_pattern") | not) and (.status | type == "number"))][0]' "$R/.stella/protocols.json")   # an error row of one plain status
ed protocols.json --argjson r "$NR" '.entries |= map(.errors |= map(select(.status != $r.status)))'   # the scratch root no longer maps that status; the mock still sends it
chain st-a/st-a-m1 st-b/st-b-m1; fresh "[$(fault st-a/st-a-m1 "$(jq -r .trigger <<<"$NR")")]"; call norow
ok '[ $RC = 1 ] && [ "$(cnt st-a/st-a-m1)" = 1 ] && [ "$(cnt st-b/st-b-m1)" = 0 ] && J norow ".code == \"STL-MDL-710\"" && jq -e ".links == {}" "$STATE"' "an error answer no row of the wire shape maps is no failover trigger: the task stops, nothing cools, no next link"
cp "$T/protocols.keep" "$R/.stella/protocols.json"

# ---- the mid-task checks ----
chain st-a/st-a-m1 st-t/st-t-m1 "st-b/st-b-m1,usable,$P1,nomid" st-n/st-n-m1 st-o/st-o-m1 st-b/st-b-m2; fresh "[$(fault st-a/st-a-m1 "$LT")]"
PROMPT=$(head -c 400 /dev/zero | tr '\0' 'w') call mid --pending-tool-call
ok '[ $RC = 0 ] && J mid ".link.model == \"st-b-m2\" and ([.refused[] | select(.code == \"STL-MDL-722\") | .link] == [\"st-t/st-t-m1\", \"st-b/st-b-m1\", \"st-n/st-n-m1\", \"st-o/st-o-m1\"])"' \
  "a mid-task switch is refused to: a too-small context window, a link not allowed mid-task, a link with no wire shape, another wire shape under a pending tool call"
ok '[ "$(cnt st-t/st-t-m1)" = 0 ] && [ "$(cnt st-b/st-b-m1)" = 0 ] && [ "$(cnt st-o/st-o-m1)" = 0 ] && [ "$(ev mid ".type == \"routing.switch-refused\" and .code == \"STL-MDL-722\"")" = 4 ] && [ "$(ev mid "$SW")" = 1 ]' \
  "no refused link is called; one event line per refused switch, one for the switch made"
ok 'J mid ".stubs == [\"st-resolver-stub\"]"' "the output names the stubs the resolver's answer rests on, and no context stub of its own (C-DC-06: the context check reads probe data)"
cp "$PF" "$T/pf.keep"; jq '.records |= map(select(.model != "st-a-m1"))' "$T/pf.keep" >"$PF"
AL=$T/sup/logs/alerts.log; a0=$(grep -c "^STL-MDL-738 " "$AL" 2>/dev/null)
chain st-a/st-a-m1 st-b/st-b-m1; fresh; call norec; a1=$(grep -c "^STL-MDL-738 " "$AL" 2>/dev/null)
ok '[ $RC = 0 ] && J norec ".link.model == \"st-a-m1\" and .refused == []" && [ "$(cnt st-a/st-a-m1)" = 1 ] && jq -e ".tokens > 0" "$R/ctx.json" && [ $((a1 - ${a0:-0})) = 1 ] && grep "^STL-MDL-738 " "$AL" | tail -1 | grep -qF "st-a/st-a-m1"' \
  "owner ruling 2026-11-18: a link with no probe record may serve (picked and called), flagged by one STL-MDL-738 warning alert naming it; the resolver was asked with the prompt's size (ctx tokens)"
mv "$AL" "$AL.keep"; mkdir "$AL"; chain st-a/st-a-m1; fresh; call noflag; rmdir "$AL"; mv "$AL.keep" "$AL"
ok '[ $RC = 1 ] && [ "$(cnt st-a/st-a-m1)" = 0 ] && grep -q "STL-CFG-318" "$T/o/noflag.err"' "CRT-04 an unprobed pick whose STL-MDL-738 alert line cannot be written is not called (STL-CFG-318)"
chain st-t/st-t-m1 st-b/st-b-m1; fresh; PROMPT=$(head -c 400 /dev/zero | tr '\0' 'w') call small
ok '[ $RC = 0 ] && J small ".link.model == \"st-b-m1\" and ([.refused[] | .code + \" \" + .link] == [\"STL-MDL-710 st-t/st-t-m1\"])" && [ "$(cnt st-t/st-t-m1)" = 0 ]' \
  "C-DC-04 a link whose probed effective context (16) does not hold the conversation is refused on the first pick too, never called"
cp "$T/pf.keep" "$PF"
chain st-a/st-a-m1; jq '. + {cross_family: {builder_family: "st-fam", served_family: "st-fam", status: "waived", reason: "st: no other family", logged: false}}' "$R/chain.json" >"$R/chain.n" && mv "$R/chain.n" "$R/chain.json"
fresh; call wv; rt wva attempt --role "$ROLE" --project st-project --task wva --tokens 7 --json
ok '[ $RC = 0 ] && [ "$(ev wv ".type == \"routing.cross-family-waiver\" and .code == \"STL-MDL-737\"")" = 1 ] && [ "$(ev wva ".type == \"routing.cross-family-waiver\"")" = 1 ] && jq -e ".tokens == 7" "$R/ctx.json"' \
  "C-DC-05 a waived reviewer answer: call and attempt each write one routing.cross-family-waiver line (STL-MDL-737) beside the pick; attempt passes --tokens to the resolver"
chain st-a/st-a-m1 st-o/st-o-m1; fresh "[$(fault st-a/st-a-m1 "$LT")]"; call shape
ok '[ $RC = 0 ] && [ "$(cnt st-o/st-o-m1)" = 1 ] && J shape ".refused == []"' "with no tool call pending a switch to another wire shape is made"
chain st-n/st-n-m1 "st-b/st-b-m1,usable,$P1,nomid"; fresh; call first
ok '[ $RC = 0 ] && [ "$(cnt st-b/st-b-m1)" = 1 ] && J first ".refused | length == 1 and .[0].link == \"st-n/st-n-m1\"" && [ "$(ev first ".type == \"routing.switch-refused\"")" = 0 ]' \
  "a task's first link is no switch: one not allowed mid-task is used; one with no wire shape cannot be called and is passed over"

# ---- the pick line, placeholder text in a prompt, the key ----
chain st-a/st-a-m1; fresh; PROMPT='say {model} {key} {max_tokens}' call pick
python3 -I "$T/http.py" get "http://$LO:$PORT/_calls" >"$T/calls" 2>/dev/null
ok '[ $RC = 0 ] && [ "$(ev pick ".type == \"routing.pick\" and .detail == \"fixture reason 7c1\" and .new.link == \"st-a/st-a-m1\"")" = 1 ]' "a call's first link is one trusted event line with the resolver's reason"
ok 'jq -e --arg k "$KEY" ".requests[-1] | (.body | tostring | contains(\"say {model} {key} {max_tokens}\")) and (.headers | tostring | contains(\$k)) and (.body | tostring | contains(\$k) | not)" "$T/calls"' \
  "placeholder text inside a prompt reaches the model unchanged; the key is in the request's header only"
ok '[ -z "$(grep -rlF -- "$KEY" "$R" "$T/sup" "$T/o" 2>/dev/null | grep -vF -- "$R/$CD/")" ]' "the key is in no output, log, event, alert or state file"

# ---- the less-private notice ----
chain "st-a/st-a-m1,usable,$P1" "st-b/st-b-m1,usable,$P2"; fresh "[$(fault st-a/st-a-m1 "$LT")]"; call nt1
ok '[ $RC = 0 ] && [ "$(sends "$NOTICE" nt1)" = 1 ] && [ "$(ev nt1 ".code == \"$NOTICE\"")" = 1 ]' "a switch to a less private class than the chain's first: one inbox alert and one event line ($NOTICE)"
chain "st-a/st-a-m1,excluded,$P0" "st-b/st-b-m1,usable,$P1"; fresh; call nt2
ok '[ $RC = 0 ] && [ "$(cnt st-a/st-a-m1)" = 0 ] && [ "$(cnt st-b/st-b-m1)" = 1 ] && [ "$(sends "$NOTICE" nt2)" = 0 ] && [ "$(ev nt2 ".code == \"$NOTICE\"")" = 0 ]' \
  "a task's first pick is compared with the chain's first link that is usable or needs a grant, never with an excluded head: no notice; the excluded link is not called"
chain "st-a/st-a-m1,usable,$P2" "st-b/st-b-m1,usable,$P0"; fresh "[$(fault st-a/st-a-m1 "$LT")]"; call nt3
ok '[ $RC = 0 ] && [ "$(sends "$NOTICE" nt3)" = 0 ] && [ "$(ev nt3 ".code == \"$NOTICE\"")" = 0 ]' "a switch to a more private class: no notice"

# ---- a link that needs a grant ----
cat >"$R/bin/consent.py" <<'P'
"""Selftest stand-in for the consent module: gate() answers <root>/gate.json and notes each call in <root>/gate.jsonl."""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def gate(ctx, link):
    with open(os.path.join(ROOT, "gate.jsonl"), "a") as f:
        f.write(json.dumps({"ctx": ctx, "link": link}) + "\n")
    with open(os.path.join(ROOT, "gate.json")) as f:
        return json.load(f)
P
APR=$R/$(ix .approval_store)
chain st-a/st-a-m1 st-b/st-b-m1,needs_grant st-b/st-b-m2; fresh "[$(fault st-a/st-a-m1 "$LT")]"; echo '{"status":"granted"}' >"$R/gate.json"; call ng1
ok '[ $RC = 3 ] && J ng1 ".code == \"STL-MDL-719\"" && [ "$(cnt st-b/st-b-m1)" = 0 ] && [ "$(cnt st-b/st-b-m2)" = 0 ] && [ "$(sends STL-MDL-719 ng1)" = 1 ] && [ ! -e "$R/gate.jsonl" ] && [ -z "$(find "$APR" -type f 2>/dev/null)" ]' \
  "the next link needs a grant and the task has no card: it waits (exit 3, STL-MDL-719, one inbox alert); the gate is not asked, no request is raised, the link after it is not called"
fresh "[$(fault st-a/st-a-m1 "$LT")]"; call ng2 --card st-card
ok '[ $RC = 0 ] && [ "$(cnt st-b/st-b-m1)" = 1 ] && jq -se "length == 1 and .[0].ctx.card == \"st-card\" and .[0].ctx.task == \"ng2\" and .[0].link.model == \"st-b-m1\"" "$R/gate.jsonl"' \
  "with a card the consent gate is asked once (ctx, link); granted: the link is called"
fresh "[$(fault st-a/st-a-m1 "$LT")]"; echo "{\"status\":\"queued\",\"code\":\"$QUEUE\",\"request_id\":\"apr-st\"}" >"$R/gate.json"; call ng3 --card st-card
ok '[ $RC = 3 ] && J ng3 --arg c "$QUEUE" ".code == \$c" && [ "$(cnt st-b/st-b-m1)" = 0 ] && [ "$(cnt st-b/st-b-m2)" = 0 ] && [ "$(sends STL- ng3)" = 0 ]' \
  "the gate does not grant: the task waits with the gate's code (exit 3), nothing more is called, and the alert is the gate's own to send"
rm -f "$R/bin/consent.py"; fresh "[$(fault st-a/st-a-m1 "$LT")]"; call ng4 --card st-card
ok '[ $RC = 3 ] && J ng4 ".code == \"STL-MDL-719\"" && [ "$(cnt st-b/st-b-m1)" = 0 ] && [ "$(sends STL-MDL-719 ng4)" = 1 ]' "with no consent module a link that needs a grant stops the task the same way, card or not"

# ---- attempt and result (a worker CLI's launcher) ----
chain st-a/st-a-m1 st-b/st-b-m1; fresh
att() { rt "$1" attempt --role "$ROLE" --project st-project --task at --json; }
att at1; a=$RC; att at1b
ok '[ $a = 0 ] && [ $RC = 0 ] && J at1 ".link == {connection: \"st-a\", model: \"st-a-m1\"} and .failure_history == []" && J at1b ".link.model == \"st-a-m1\"" && [ "$(cnt st-a/st-a-m1)" = 0 ]' \
  "attempt names one link and calls no model; asked again before a result, it names the same link"
rt at2 result --task at --link st-a/st-a-m1 --outcome "$LT"; att at3
ok '[ $RC = 0 ] && J at3 --arg t "$LT" ".link.connection == \"st-b\" and (.failure_history | length == 1 and .[0].link == \"st-a/st-a-m1\" and .[0].trigger == \$t)" && [ "$(ev at "$SW")" = 1 ] && [ "$(cnt st-b/st-b-m1)" = 0 ]' \
  "after a failed result the next attempt starts on the next link with the failure history, and the switch is one event line"
jq -e --arg d "$(jq -r '[.drivers[] | select(.mid_task | not) | .id][0]' "$RT")" '.driver == $d' "$R/ctx.json" >/dev/null 2>&1; a=$?
ok '[ $a = 0 ]' "attempt asks the resolver as the routing data's driver that never switches mid-task"

# ---- refusals ----
fresh; echo '{"links":{},"tasks":{}}' >"$R/elsewhere"; ln -s "$R/elsewhere" "$T/elsewhere"; ln -s "$R/elsewhere" "$STATE"; chain st-a/st-a-m1; call link   # the target is inside the scratch root ($T/elsewhere is a second name for it): route.py's own state check answers
ok '[ $RC = 1 ] && J link ".code == \"STL-MDL-710\"" && [ "$(cnt st-a/st-a-m1)" = 0 ] && [ "$(cat "$T/elsewhere")" = "{\"links\":{},\"tasks\":{}}" ]' "a state file that is a symbolic link is refused: nothing is called, the link's target is not written"
rm -f "$STATE"; fresh; echo '{"links":{},"tasks":{}}' >"$T/outside"; ln -s "$T/outside" "$STATE"; call linkout
ok '[ $RC = 1 ] && J linkout ".task == \"linkout\" and .code == \"STL-CFG-310\" and (.problem | type == \"string\") and .refused == []" && grep -q "^STL-CFG-310 " "$T/o/linkout.err" && [ "$(cnt st-a/st-a-m1)" = 0 ] && [ "$(cat "$T/outside")" = "{\"links\":{},\"tasks\":{}}" ]' \
  "a state file that is a link to a file outside the root is refused by the data check (STL-CFG-310, in the JSON output too): nothing is called, the target is not written"
rm -f "$STATE"; fresh; cp "$LIM" "$T/lim.keep"; echo "CALL_TIMEOUT=3" >>"$LIM"; call setref; cp "$T/lim.keep" "$LIM"
ok '[ $RC = 1 ] && J setref ".task == \"setref\" and (.code | startswith(\"STL-CFG-\")) and .refused == []" && grep -q "^$(jq -r .code "$T/o/setref.json") " "$T/o/setref.err" && [ "$(cnt st-a/st-a-m1)" = 0 ]' \
  "a settings store the settings tool refuses (the call timeout set twice): the code is in the JSON output and on stderr, nothing is called"
mv "$EV" "$T/ev.keep"; mkdir "$EV"; call evref; rmdir "$EV"; mv "$T/ev.keep" "$EV"
ok '[ $RC = 1 ] && J evref ".task == \"evref\" and (.code | startswith(\"STL-CFG-\")) and .refused == []" && grep -q "^$(jq -r .code "$T/o/evref.json") " "$T/o/evref.err" && [ "$(cnt st-a/st-a-m1)" = 0 ]' \
  "an event log that cannot be written: no call without its event line, and the code is in the JSON output and on stderr"
fresh
export STUB_WORKER_MARK=1
call w1; a=$RC; rt w2 attempt --role "$ROLE" --project st-project --task w2 --json; b=$RC; rt w3 result --task w3 --link st-a/st-a-m1 --outcome ok
unset STUB_WORKER_MARK
ok '[ $a = 1 ] && [ $b = 1 ] && [ $RC = 1 ] && [ "$(cat "$T/o/w1.err" "$T/o/w2.err" "$T/o/w3.err" | grep -c STL-CFG-312)" = 3 ] && [ "$(cnt st-a/st-a-m1)" = 0 ] && [ ! -e "$STATE" ]' \
  "call, attempt and result refuse in a worker environment (STL-CFG-312): nothing is called, no state is written"
chain st-a/st-a-m1; fresh; jq '.apps = [{app: "st-app", status: "excluded", code: "STL-MDL-714", reason: "fixture"}]' "$R/chain.json" >"$T/chain.n" && mv "$T/chain.n" "$R/chain.json"; call app
ok '[ $RC = 1 ] && J app ".code == \"STL-MDL-714\"" && [ "$(cnt st-a/st-a-m1)" = 0 ]' "a card app the resolver refuses stops the task with the app's code: no link is called"

# ---- gate B: a hostile server, the environment, the trace of a cooldown ----
cat >"$T/srv.py" <<'P'
"""Selftest server: answers every POST with 200 and the bytes of <body file>; while <body file>.drip exists it promises more and
sends one byte every half second instead; while <body file>.head exists it sends the status line at once, then one header byte
every half second for 15 s, then the answer. One line per request in <log file>. First stdout line: its port."""
import http.server, os, sys, time
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with open(sys.argv[3], "a") as f:
            f.write(self.requestline + "\n")
        drip = os.path.exists(sys.argv[2] + ".drip")
        with open(sys.argv[2], "rb") as f:
            b = f.read()
        if os.path.exists(sys.argv[2] + ".head"):
            try:
                self.wfile.write(b"HTTP/1.0 200 OK\r\nX-Slow: ")
                for _ in range(30):
                    self.wfile.write(b"x")
                    self.wfile.flush()
                    time.sleep(0.5)
                self.wfile.write(b"\r\nContent-Length: %d\r\n\r\n" % len(b) + b)
            except OSError:
                pass
            return
        self.send_response(200)
        self.send_header("Content-Length", str(100000 if drip else len(b)))
        self.end_headers()
        try:
            for _ in range(30 if drip else 0):
                self.wfile.write(b" ")
                self.wfile.flush()
                time.sleep(0.5)
            self.wfile.write(b"" if drip else b)
        except OSError:
            pass
s = http.server.ThreadingHTTPServer((sys.argv[1], 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
P
python3 -I "$T/srv.py" "$LO" "$T/body" "$T/srv.log" >"$T/srv.port" 2>"$T/srv.err" &
for i in $(seq 100); do [ -s "$T/srv.port" ] && break; sleep 0.1; done
XP=$(head -n1 "$T/srv.port")
prov st-x "$SHAPE0" 100000; ed connections.json --argjson p "${XP:-9}" '(.entries[] | select(.id == "st-x") | .hosts[0].port) = $p'; recs   # a fake connection on that server
RSP=$(jq -c --arg s "$SHAPE0" '.entries[] | select(.id == $s) | .response' "$R/.stella/protocols.json")
PA='split("/")[1:] | map(tonumber? // .)'   # a pointer of the wire shape as a jq path
answer() { jq -cn --argjson r "$RSP" --arg t "$1" "setpath(\$r.text | $PA; \$t)" >"$T/body"; }   # <text>: the server's next answer
DEEP=$(head -c 50000 /dev/zero | tr '\0' '[')
answer ok; : >"$T/srv.log"; chain st-a/st-a-m1; fresh
http_proxy="http://$LO:$XP" HTTP_PROXY="http://$LO:$XP" no_proxy='' NO_PROXY='' call px
ok '[ -n "$XP" ] && [ $RC = 0 ] && [ "$(cnt st-a/st-a-m1)" = 1 ] && [ ! -s "$T/srv.log" ]' "a proxy named in the environment is never used: the call reaches its link and the proxy gets nothing"
answer "the key is $KEY"; chain st-x/st-x-m1; fresh; call echo
ok '[ $RC = 0 ] && [ -s "$T/srv.log" ] && J echo ".text | startswith(\"the key is \")" && [ -z "$(grep -rlF -- "$KEY" "$R" "$T/sup" "$T/o" 2>/dev/null | grep -vF -- "$R/$CD/")" ]' \
  "an answer that repeats the key: the output holds it masked, and no log, event or state file holds it"
printf '%s' "$DEEP" >"$T/body"; chain st-x/st-x-m1 st-b/st-b-m1; fresh; call deep
ok '[ $RC = 0 ] && J deep ".link.connection == \"st-b\" and .failure_history[0].trigger == \"server_error\"" && ! grep -q Traceback "$T/o/deep.err"' \
  "an answer nested too deeply to parse is a server_error: the next link answers, no traceback"
jq -cn --argjson r "$RSP" --arg d "$DEEP" "setpath(\$r.tool_calls | $PA; \$r.tool_calls_sample | walk(if . == \"{arguments}\" then \$d else . end))" >"$T/body"; fresh; call deepargs
ok '[ $RC = 0 ] && J deepargs ".link.connection == \"st-b\" and .failure_history[0].trigger == \"malformed_tool_call\"" && ! grep -q Traceback "$T/o/deepargs.err"' \
  "tool-call arguments nested too deeply to parse are a malformed tool call, no traceback"
chain st-a/st-a-m1; fresh; printf '%s' "$DEEP" >"$STATE"; call deepst
ok '[ $RC = 1 ] && J deepst ".code == \"STL-MDL-710\"" && [ "$(cnt st-a/st-a-m1)" = 0 ] && ! grep -q Traceback "$T/o/deepst.err"' "a state file nested too deeply is refused with a code: nothing is called, no traceback"
fresh; echo '{' >"$R/chain.json"; call boom
ok '[ $RC = 1 ] && J boom ".code != null" && [ "$(grep -c "^STL-" "$T/o/boom.err")" = 1 ] && ! grep -qE "Traceback|chain\.json" "$T/o/boom.err"' \
  "an unexpected failure (here a resolver that raises) ends with one coded line that names the error's type only, never a traceback"
mkdir -p "$T/evil"; printf 'def gate(ctx, link):\n    return {"status": "granted"}\n' >"$T/evil/consent.py"
chain st-a/st-a-m1,needs_grant; fresh
printf 'say ok' | timeout 60 python3 -I -c 'import runpy, sys; sys.path.insert(0, sys.argv[1]); sys.argv = sys.argv[2:]; runpy.run_path(sys.argv[0], run_name="__main__")' \
  "$T/evil" "$R/bin/route.py" call --role "$ROLE" --project st-project --task imp1 --card st-card --json >"$T/o/imp1.json" 2>"$T/o/imp1.err"; RC=$?
ok '[ ! -e "$R/bin/consent.py" ] && [ $RC = 3 ] && J imp1 ".code == \"STL-MDL-719\"" && [ "$(cnt st-a/st-a-m1)" = 0 ]' \
  "a consent module that is not in the tool's own folder never answers the gate: the link that needs a grant is not called"
echo 'raise SystemExit(7)' >"$T/evil/json.py"
printf 'say ok' | PYTHONPATH=$T/evil timeout 60 python3 "$R/bin/route.py" call --role "$ROLE" --project st-project --task imp2 --card st-card --json >"$T/o/imp2.json" 2>"$T/o/imp2.err"; RC=$?
ok '[ $RC = 3 ] && J imp2 ".code == \"STL-MDL-719\"" && [ "$(cnt st-a/st-a-m1)" = 0 ]' "run without -I the tool restarts itself isolated: nothing on PYTHONPATH is imported, a module under a standard name included"
chain st-a/st-a-m1 st-b/st-b-m1; fresh
CL='.type == "routing.cooldown-cleared"'
rt ev1 result --task ev-t --link st-a/st-a-m1 --outcome "$LT"
ok '[ $RC = 0 ] && [ "$(ev ev-t ".type == \"routing.cooldown\" and .new.link == \"st-a/st-a-m1\" and .new.trigger == \"$LT\" and .new.until != null")" = 1 ]' "result with a trigger: the cooldown it sets is one trusted event line"
rt ev2 result --task ev-t --link st-a/st-a-m1 --outcome ok; a=$(ev ev-t "$CL"); rt ev3 result --task ev-t --link st-a/st-a-m1 --outcome ok
ok '[ "$a" = 1 ] && [ $RC = 0 ] && [ "$(ev ev-t "$CL")" = 1 ] && [ "$(ev ev-t true)" = 2 ]' "result ok: the cooldown it clears is one trusted event line; with nothing to clear it writes none"
fresh; echo "{\"links\":{\"st-a/st-a-m1\":{\"trigger\":\"$LT\",\"since\":\"2020-01-01T00:00:00Z\",\"until\":\"2020-01-01T00:00:00Z\",\"failures\":1,\"observed_limit\":null}},\"tasks\":{}}" >"$STATE"; call rep
ok '[ $RC = 0 ] && J rep ".link.model == \"st-a-m1\"" && [ "$(ev rep "$CL and .old.links == [\"st-a/st-a-m1\"]")" = 1 ] && jq -e ".links == {}" "$STATE"' \
  "a call that answers on a link whose cooldown is over clears it (re-promotion): one trusted event line"

# ---- gate B, the red team: the link a task last used, the notice's bar, one deadline, inputs of another shape ----
chain st-a/st-a-m1 st-t/st-t-m1 st-b/st-b-m1; fresh; call sw8
rt sw8r result --task sw8-other --link st-a/st-a-m1 --outcome "$LT"
PROMPT=$(head -c 400 /dev/zero | tr '\0' 'w') call sw8
ok '[ $RC = 0 ] && J sw8 ".link.model == \"st-b-m1\" and .switches == 1 and ([.refused[] | .code + \" \" + .link] == [\"STL-MDL-722 st-t/st-t-m1\"])" && [ "$(cnt st-t/st-t-m1)" = 0 ] && [ "$(ev sw8 "$SW")" = 1 ] && [ "$(ev sw8 ".type == \"routing.pick\"")" = 1 ]' \
  "the link a task last used cooled down because another task failed on it: the task's next call is a switch (the mid-task checks, one switch line, counted), not a first pick"
ed routing.json '.failover.max_switches_per_task = 1'; rt sw8o result --task sw8-other --link st-a/st-a-m1 --outcome ok; call sw8; a=$RC; b=$(jq -r '.link.model + " " + (.switches | tostring)' "$T/o/sw8.json")
cp "$T/routing.keep" "$RT"; call sw8
ok '[ $a = 0 ] && [ "$b" = "st-b-m1 1" ] && [ $RC = 0 ] && J sw8 ".link.model == \"st-a-m1\" and .switches == 2" && [ "$(ev sw8 "$SW")" = 2 ]' \
  "at the switch limit a task stays on its link though an earlier one is usable again; under the limit, going back to it is a switch too (one line, counted)"
chain "st-a/st-a-m1,excluded,$P2" "st-b/st-b-m1,usable,$P0" "st-o/st-o-m1,usable,$P2"; fresh "[$(fault st-b/st-b-m1 "$LT")]"; call nt4
ok '[ $RC = 0 ] && J nt4 ".link.connection == \"st-o\"" && [ "$(sends "$NOTICE" nt4)" = 1 ] && [ "$(ev nt4 ".code == \"$NOTICE\"")" = 1 ]' \
  "the notice compares with the link the task used before: an excluded head of the least private class hides no move"
chain "st-n/st-n-m1,usable,$P0" "st-b/st-b-m1,usable,$P2"; fresh; call nt5
ok '[ $RC = 0 ] && [ "$(cnt st-b/st-b-m1)" = 1 ] && [ "$(sends "$NOTICE" nt5)" = 1 ] && [ "$(ev nt5 ".code == \"$NOTICE\"")" = 1 ]' \
  "a first pick below the class of the chain's first link that is usable (here one that cannot be called) notifies"
answer ok; : >"$T/body.drip"; chain st-x/st-x-m1 st-b/st-b-m1; fresh; s=$SECONDS; call drip; s=$((SECONDS - s)); rm -f "$T/body.drip"
ok '[ $RC = 0 ] && J drip ".link.connection == \"st-b\" and .failure_history[0].trigger == \"timeout\"" && [ "$s" -le 9 ]' \
  "an answer that drips in (a byte every half second, CALL_TIMEOUT 2) ends at the call's one deadline as a timeout: the next link answers (took $s s)"
: >"$T/body.head"; fresh; s=$SECONDS; call driphead; s=$((SECONDS - s)); rm -f "$T/body.head"
ok '[ $RC = 0 ] && J driphead ".link.connection == \"st-b\" and .failure_history[0].trigger == \"timeout\"" && [ "$s" -le 9 ]' \
  "headers that drip in (a byte every half second) are cut at the same deadline: it covers the whole call, not the body alone (took $s s)"
chain "st-a/st-a-m1,cooldown,$P0" "st-b/st-b-m1,usable,$P1"; fresh; call nt6
ok '[ $RC = 0 ] && [ "$(cnt st-a/st-a-m1)" = 0 ] && [ "$(cnt st-b/st-b-m1)" = 1 ] && [ "$(sends "$NOTICE" nt6)" = 1 ] && [ "$(ev nt6 ".code == \"$NOTICE\"")" = 1 ]' \
  "a task's first pick behind a cooling head of a more private class notifies (only an excluded head is skipped); the cooling link is not called"
answer "x${KEY}x"; chain st-x/st-x-m1; fresh; call glued
ok '[ $RC = 0 ] && J glued ".text | startswith(\"x\") and endswith(\"x\")" && [ -z "$(grep -rlF -- "$KEY" "$R" "$T/sup" "$T/o" 2>/dev/null | grep -vF -- "$R/$CD/")" ]' \
  "an answer that holds the key glued to other characters: the output holds it masked all the same"
chain st-a/st-a-m1; fresh; PROMPT=$'tool output \377\376 end' call utf; a=$RC; LC_ALL=C PROMPT=$'tool output \377\376 end' call utfc
ok '[ $a = 0 ] && [ $RC = 0 ] && [ "$(cnt st-a/st-a-m1)" = 2 ] && ! grep -q Traceback "$T/o/utf.err" "$T/o/utfc.err"' "a prompt with bytes that are not UTF-8 is sent (those bytes replaced), under the C locale too: no traceback"
chain st-a/st-a-m1 st-b/st-b-m1
for h in '{}' '"x"' '{"link":5,"trigger":{"a":1},"at":[]}'; do
  fresh; echo "{\"links\":{\"st-a/st-a-m1\":{\"trigger\":\"$LT\",\"since\":\"2999-01-01T00:00:00Z\",\"until\":\"2999-01-01T00:00:00Z\",\"failures\":1,\"observed_limit\":null}},
    \"tasks\":{\"hist\":{\"switches\":0,\"visited\":[],\"history\":[$h],\"last\":\"st-a/st-a-m1\"}}}" >"$STATE"; call hist
  ok '{ [ $RC = 0 ] || grep -q "^STL-" "$T/o/hist.err"; } && [ "$(cnt st-a/st-a-m1)" = 0 ] && ! grep -q Traceback "$T/o/hist.err"' "a task history entry of another shape ($h) ends with an answer or a code, never a traceback"
done
echo null >"$T/body"; chain st-x/st-x-m1 st-b/st-b-m1; fresh; call empty
ok '[ $RC = 0 ] && J empty ".link.connection == \"st-b\" and .failure_history[0].trigger == \"server_error\""' "an answer with no text and no tool call is no success: server_error, the next link answers"
chain st-a/st-a-m1; fresh; rt long call --role "$ROLE" --project st-project --task "$(head -c 300 /dev/zero | tr '\0' t)" --json
ok '[ $RC = 1 ] && J long ".code == \"STL-MDL-711\" and (.task | length) < 300" && [ "$(cnt st-a/st-a-m1)" = 0 ] && [ ! -e "$STATE" ]' "a task id that is too long is refused (STL-MDL-711): nothing is called, nothing is stored"
jq -n '{links: {}, tasks: ([range(5000) | {key: "old-\(.)", value: {switches: 0, visited: [], history: [], last: null}}] | from_entries)}' >"$STATE"; call prune
ok '[ $RC = 0 ] && jq -e ".tasks | length < 5000 and has(\"prune\") and has(\"old-4999\") and (has(\"old-0\") | not)" "$STATE"' "the state keeps a bounded number of task entries: a write drops the oldest ones"
chain st-a/st-a-m1; fresh

rm -f "$R/bin/resolve.py"; call nores
ok '[ $RC = 1 ] && J nores ".code == \"STL-MDL-710\"" && [ "$(cnt st-a/st-a-m1)" = 0 ]' "with no resolver nothing is routed (STL-MDL-710)"
rt usage call --role "$ROLE"
ok '[ $RC = 2 ]' "a call without its arguments is a usage error (2)"
echo "# failover-selftest: $fails failed"; [ $fails = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
