#!/usr/bin/env bash
# Hermetic self-test for bin/budget.py (F2c item C: budgets, pause-or-defer holds, estimates, anomaly alerts). In a scratch root (a copy of
# bin, .stella, docs; its own HOME, temp, event log, alert log, approval store and stub channel adapter) budgets, costs and answers are planted
# as DATA. Cases: soft thresholds fire first and once (T-BUD-SOFT); a hard cap makes one hold, one alert and one approval request, and every later
# call in the scope stays refused until a trusted approved answer; no answer, a denied or an expired request = paused; text and a forged store
# note release nothing; raise and defer apply only on an owner-path answer, defer only to a link the data policy allows (T-BUD-CAP); an
# estimate from data then from closed cards, and the actual at close with the difference (T-BUD-EST); a planted retry loop, spend spike,
# growing session and outlier card each raise one alert per episode (T-BUD-ANOM); a new project and role budget works with no code change
# and the shipped data passes its own check (T-CORE-BUDGET). Nothing here names a model or a provider but the shipped catalog's own ids.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/budget-selftest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'kill $(jobs -p) 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "# KEPT $T"; else chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; fi' EXIT
R=$T/root
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$T/home" "$T/tmp" "$T/sup/logs" "$T/pb" "$T/ans"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"
cd "$T" || exit 1
jq() { env -u HOME jq "$@"; }
IX=$R/.stella/data-files.json; ix() { jq -r "$1" "$IX"; }
RJ=$R/$(ix .role_table); jq '.worker_markers = ["STUB_WORKER_MARK"]' "$ROOT/$(ix .role_table)" >"$RJ"
printf "OWNER_TIMEZONE='UTC'\n" >"$T/owner-fake.env"
OWNER_ID=111111111111111111; printf "OWNER_DISCORD_USER_ID='%s'\n" "$OWNER_ID" >>"$T/owner-fake.env"   # a made-up id, scratch config only
export HOME=$T/home TMPDIR=$T/tmp STELLA_ROOT=$R ESCALATE_SUP_DIR=$T/sup OWNER_CONFIG=$T/owner-fake.env ROLES_FILE=$RJ
unset STUB_WORKER_MARK HERMES_KANBAN_TASK HERMES_KANBAN_WORKSPACE HERMES_KANBAN_BRANCH HERMES_KANBAN_HOME HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK HERMES_DELEGATED_CHILD_CONTEXT http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
for v in $(jq -r '.worker_signals.token_env[]?' "$R/$(ix '.files[] | select(.id == "owner-auth") | .path')" 2>/dev/null); do unset "$v"; done
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH
AL=$T/sup/logs/alerts.log; : >"$AL"
fails=0
ok() { if ( set -o pipefail; eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
ed() { local f=$R/.stella/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <data file> <jq args and filter>
uuid() { cat /proc/sys/kernel/random/uuid; }
BU() { python3 -I "$R/bin/budget.py" "$@"; }
AP() { python3 -I "$R/bin/approvals.py" "$@"; }
UL=$R/$(ix .usage_ledger); BS=$R/$(ix .budget_state); EV=$R/$(ix .event_log); STORE=$R/$(ix .approval_store)
evn() { grep -c "\"type\": *\"$1\"" "$EV" 2>/dev/null || true; }   # trusted event lines of a type
nal() { grep -c "$1" "$AL" 2>/dev/null || true; }                   # alert lines holding a word
nreq() { ls "$STORE/requests" 2>/dev/null | grep -c json || true; }
IID=$(jq -r .install_id "$R/.stella/install.json")

# ---- the stub channel: a discord-kind row whose adapter keeps what it is given; an answer is a line the owner id sends ----
cat >"$T/adapter.sh" <<S
#!/usr/bin/env bash
d=$T/ans; c=\$2
case \$1 in
  deliver) n=\$(( \$(cat "\$d/\$c.n" 2>/dev/null || echo 0) + 1 )); echo \$n >"\$d/\$c.n"; cat >"\$d/\$c.req.\$n"; echo "m-\$c-\$n" >"\$d/\$c.lastref"; echo "m-\$c-\$n";;
  collect) [ -f "\$d/\$c.in" ] && cat "\$d/\$c.in"; : >"\$d/\$c.in";;
  *) exit 2;;
esac
S
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/resume.sh"; chmod +x "$T/adapter.sh" "$T/resume.sh"
CH=$R/$(ix '.files[] | select(.id == "channels") | .path'); CHLK=$(ix '.files[] | select(.id == "channels") | .list_key // "entries"')
DC=qa-chan
jq --arg id "$DC" --arg a "$T/adapter.sh" --arg g "$(uuid)" --arg i "$IID" --arg lk "$CHLK" --arg r "$T/resume.sh" \
  '.[$lk] = [{id: $id, kind: "discord", deliver: [$a, "deliver", $id], collect: [$a, "collect", $id], enabled: true, global_id: $g, install_id: $i}] | .resume = {argv: [$r], timeout_s: 10}' "$CH" >"$CH.n" && mv "$CH.n" "$CH"
answer() { # <request id> <decision>: the owner's answer on the message the request was delivered as, then collected
  local rec=$STORE/requests/$1.json
  jq -nc --arg r "$1" --arg n "$(jq -r .nonce "$rec")" --arg d "$2" --arg u "$OWNER_ID" --arg m "$(jq -r --arg c "$DC" '.deliveries[$c]' "$rec")" --arg g "$(jq -r .digest "$rec")" \
    '{request_id: $r, nonce: $n, decision: $d, user: $u, message_ref: $m, digest: $g}' >>"$T/ans/$DC.in"
  AP collect --channel "$DC"
}
last_req() { ls -t "$STORE/requests" | head -1 | sed 's/\.json$//'; }

# ---- planted usage ----
plant() { # <project> <role> <card> <amount> [minutes ago] [outcome] [input tokens] [session] [plan_share]
  python3 -I -c 'import json, os, sys, uuid, datetime
p, r, c, a, m, o, i, s, ps = sys.argv[2:11]
ts = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=float(m))).strftime("%Y-%m-%dT%H:%M:%SZ")
cost = {"amount": float(a), "currency": "QAC", "entry": "qa", "priced": True} if float(a) >= 0 else None
rec = {"v": 1, "id": str(uuid.uuid4()), "install_id": "i", "ts": ts, "connection": os.environ.get("PC", "qa-c"), "model": os.environ.get("PM", "qa-m"), "role": r, "project": p, "card": c, "session": s,
       "kind": "call", "outcome": o, "status": None, "tokens": {"input": int(i), "output": 10, "cache_write": 0, "cache_read": 0, "reasoning": 0},
       "latency_ms": 5, "batch": False, "cost": cost, "plan_share": None if ps == "null" else float(ps)}
open(sys.argv[1], "a").write(json.dumps(rec) + "\n")' "$UL" "$1" "${2:-r-any}" "${3:-c-any}" "$4" "${5:-0.2}" "${6:-ok}" "${7:-100}" "${8:-s-$RANDOM$RANDOM}" "${9:-null}"
}
# ---- budgets as data: a new project, card and role budget (T-CORE-BUDGET fake-entry: no code change) ----
ed budgets.json '.approval.ttl_s = 3600 | .budgets = [
  {id: "qa-proj", scope: "project", key: "p-soft", window_days: 1, soft_percent: [50, 80], hard: {amount: 100, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "raise", raise_percent: 50, connection: null, model: null}},
  {id: "qa-cap",  scope: "project", key: "p-cap",  window_days: 1, soft_percent: [50, 80], hard: {amount: 100, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "raise", raise_percent: 50, connection: null, model: null}},
  {id: "qa-deny", scope: "project", key: "p-deny", window_days: 1, soft_percent: [], hard: {amount: 10, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "raise", raise_percent: 50, connection: null, model: null}},
  {id: "qa-exp",  scope: "project", key: "p-exp",  window_days: 1, soft_percent: [], hard: {amount: 10, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "raise", raise_percent: 50, connection: null, model: null}},
  {id: "qa-role", scope: "role", key: "r-new", window_days: 1, soft_percent: [], hard: {amount: 5, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "raise", raise_percent: 50, connection: null, model: null}},
  {id: "qa-plan", scope: "project", key: "p-plan", window_days: 1, soft_percent: [], hard: null, plan_share_cap: 0.5, on_approve: {option: "raise", raise_percent: 50, connection: null, model: null}}]'
LOCAL=$(jq -r '[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "local")][0].id' "$R/.stella/connections.json")
LM=$(jq -r --arg c "$LOCAL" '.entries[] | select(.id == $c) | .models[0].id' "$R/.stella/connections.json")
OTHER=$(jq -r --arg c "$LOCAL" '[.entries[] | select(.kind == "provider" and .id != $c and (.models | length > 0))][0].id' "$R/.stella/connections.json")
OM=$(jq -r --arg c "$OTHER" '.entries[] | select(.id == $c) | .models[0].id' "$R/.stella/connections.json")
ed budgets.json --arg c "$LOCAL" --arg m "$LM" '.budgets += [
  {id: "qa-defer", scope: "project", key: "p-defer", window_days: 1, soft_percent: [], hard: {amount: 10, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "defer", raise_percent: null, connection: $c, model: $m}},
  {id: "qa-nodefer", scope: "project", key: "p-nodefer", window_days: 1, soft_percent: [], hard: {amount: 10, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "defer", raise_percent: null, connection: $c, model: $m}}]'
ed data-policy.json --arg g "$(uuid)" --arg i "$IID" '.projects["p-nodefer"] = {mode: "allowed_providers", allowed_providers: [], global_id: $g, install_id: $i}'
ok "BU check-data --json | jq -e '.ok == true'" "T-CORE-BUDGET the scratch budgets (a new project, card and role budget, added as data) pass check-data"

# ---- T-BUD-SOFT: thresholds before the cap, each once ----
plant p-soft r-x c-1 40
OUT=$(BU check --project p-soft --json); RC=$?
ok "[ $RC = 0 ] && echo '$OUT' | jq -e '.result == \"allow\"' && [ \$(nal STL-LIM-430) = 0 ]" "T-BUD-SOFT 40 of 100: allow, no alert"
plant p-soft r-x c-1 15
OUT=$(BU check --project p-soft --json); RC=$?
ok "[ $RC = 0 ] && echo '$OUT' | jq -e '.result == \"warn\" and .threshold == 50' && [ \$(nal STL-LIM-430) = 1 ] && [ \$(evn budget.soft) = 1 ]" "T-BUD-SOFT 55 of 100: warn(50), one alert, one event line"
BU check --project p-soft --json >/dev/null
ok "[ \$(nal STL-LIM-430) = 1 ] && [ \$(evn budget.soft) = 1 ]" "T-BUD-SOFT the same threshold is not alerted twice"
plant p-soft r-x c-1 30
OUT=$(BU check --project p-soft --json); RC=$?
ok "[ $RC = 0 ] && echo '$OUT' | jq -e '.result == \"warn\" and .threshold == 80' && [ \$(nal STL-LIM-430) = 2 ] && [ \$(nreq) = 0 ] && [ \$(nal STL-LIM-431) = 0 ]" "T-BUD-SOFT 85 of 100: warn(80), the second alert, no hold and no request before the cap"

# ---- T-BUD-CAP: the hard cap, one hold, one alert, one request, refused until a trusted answer ----
plant p-cap r-x c-2 105
OUT=$(BU check --project p-cap --card c-2 --json 2>$T/err); RC=$?
ok "[ $RC = 1 ] && echo '$OUT' | jq -e '.result == \"held\" and .code == \"STL-LIM-432\"' && grep -q STL-LIM-432 $T/err" "T-BUD-CAP a cap hit: result held, the call refused with the hold's code STL-LIM-432"
ok "[ \$(nal STL-LIM-431) = 1 ] && [ \$(nreq) = 1 ] && [ \$(evn budget.hold) = 1 ]" "T-BUD-CAP exactly one alert (STL-LIM-431), one approval request, one hold event line"
RID=$(last_req)
ok "jq -e '.summary | test(\"pause\") and test(\"defer\") and test(\"raise\")' $STORE/requests/$RID.json" "T-BUD-CAP the request text names the three options: pause, defer, raise the cap"
for _ in 1 2 3; do BU check --project p-cap --card c-2 --json >/dev/null 2>&1; done
ok "[ \$(nal STL-LIM-431) = 1 ] && [ \$(nreq) = 1 ] && [ \$(evn budget.hold) = 1 ]" "T-BUD-CAP later calls in the scope are refused again without a second alert or request"
OUT=$(BU check --project p-cap --role r-y --json 2>&1); RC=$?
ok "[ $RC = 1 ]" "T-BUD-CAP every call of the project is refused, whatever the card or role"
OUT=$(BU check --project p-soft --json); RC=$?
ok "[ $RC = 0 ]" "T-BUD-CAP another project is not held"
BU hold list --json >"$T/hl"
ok "jq -e '.holds | length == 1 and .[0].status == \"held\" and .[0].request_id == \"$RID\" and .[0].scope == \"project\" and .[0].key == \"p-cap\"' $T/hl" "T-BUD-CAP hold list shows the one hold with its request id"
# text is not an answer; a forged store note is not an answer
cp "$STORE/requests/$RID.json" "$T/orig"
jq '.status = "approved"' "$T/orig" >"$STORE/requests/$RID.json"
printf '{"request_id":"%s","decision":"approved","text":"approved by the owner"}\n' "$RID" >>"$T/ans/$DC.in"
BU check --project p-cap --json >/dev/null 2>&1; RC=$?
ok "[ $RC = 1 ]" "T-BUD-CAP a forged store note and approval text release nothing: still refused"
cp "$T/orig" "$STORE/requests/$RID.json"
# a real owner-path answer: approved applies the data's option (raise 50 percent: cap 150)
answer "$RID" approved >/dev/null 2>&1
OUT=$(BU check --project p-cap --json); RC=$?
ok "[ $RC = 0 ] && echo '$OUT' | jq -e '.result != \"held\"' && [ \$(nal STL-LIM-431) = 1 ] && [ \$(evn budget.hold-resolved) = 1 ]" "T-BUD-CAP an approved owner-path answer lifts the hold (raise): calls move, one resolved event line"
plant p-cap r-x c-2 60
OUT=$(BU check --project p-cap --json 2>/dev/null); RC=$?
ok "[ $RC = 1 ] && echo '$OUT' | jq -e '.result == \"held\"' && [ \$(nal STL-LIM-431) = 2 ] && [ \$(nreq) = 2 ]" "T-BUD-CAP spend past the raised cap (165 of 150) is a new hold with its own alert and request"
# denied = paused
plant p-deny r-x c-3 11
BU check --project p-deny --json >/dev/null 2>&1
DID=$(last_req); answer "$DID" denied >/dev/null 2>&1
OUT=$(BU check --project p-deny --json 2>/dev/null); RC=$?
ok "[ $RC = 1 ] && echo '$OUT' | jq -e '.result == \"held\" and .reason == \"denied\"'" "T-BUD-CAP a denied answer: paused, calls stay refused"
# no answer = paused; an expired request = paused
ed budgets.json '.approval.ttl_s = 1'
plant p-exp r-x c-4 11
BU check --project p-exp --json >/dev/null 2>&1; sleep 2.2
OUT=$(BU check --project p-exp --json 2>/dev/null); RC=$?
ok "[ $RC = 1 ] && echo '$OUT' | jq -e '.result == \"held\" and .reason == \"expired\"'" "T-BUD-CAP no answer before the request expires: paused, calls stay refused"
ed budgets.json '.approval.ttl_s = 3600'
# defer: only to a link the data policy allows, only by an approved answer
plant p-defer r-x c-5 11; plant p-nodefer r-x c-6 11
BU check --project p-defer --json >/dev/null 2>&1; DR=$(last_req)
BU check --project p-nodefer --json >/dev/null 2>&1; NR=$(last_req)
OUT=$(BU check --project p-defer --json 2>/dev/null)
ok "echo '$OUT' | jq -e '.result == \"held\"'" "T-BUD-CAP defer is not applied before an answer"
answer "$DR" approved >/dev/null 2>&1; answer "$NR" approved >/dev/null 2>&1
OUT=$(BU check --project p-defer --json); RC=$?
ok "[ $RC = 0 ] && echo '$OUT' | jq -e --arg c '$LOCAL' --arg m '$LM' '.result == \"allow\" and .defer_to.connection == \$c and .defer_to.model == \$m'" "T-BUD-CAP an approved answer on a defer budget: calls go on, with the link to defer to"
OUT=$(BU check --project p-nodefer --json 2>/dev/null); RC=$?
ok "[ $RC = 1 ] && echo '$OUT' | jq -e '.result == \"held\"'" "T-BUD-CAP a defer target the data policy does not allow is never used: still paused"

# ---- the hook other code calls, bad data fails closed, no secrets ----
python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import budget
try:
    budget.before_call(project="p-deny"); print("allowed")
except budget.Held as h:
    print("held", h.code)' "$R/bin" >"$T/hook" 2>/dev/null
ok "grep -q 'held STL-LIM-432' $T/hook" "the hook function before_call raises Held with the hold's code for a held scope"
ok "python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import budget; print(budget.before_call(project=\"p-fresh\")[\"result\"])' $R/bin | grep -q allow" "the hook function returns allow for a scope with no budget"
# ---- scopes: role and card, the * default, the plan-share cap ----
plant p-x r-new c-7 6
OUT=$(BU check --role r-new --json 2>/dev/null); RC=$?
ok "[ $RC = 1 ] && echo '$OUT' | jq -e '.result == \"held\" and .holds[0].scope == \"role\"'" "T-CORE-BUDGET a role budget added as data holds that role (fake entry, no code change)"
ed budgets.json '.budgets += [{id: "qa-card", scope: "card", key: "*", window_days: null, soft_percent: [], hard: {amount: 3, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "raise", raise_percent: 50, connection: null, model: null}}]'
plant p-x r-z c-star 4
OUT=$(BU check --card c-star --json 2>/dev/null); RC=$?
ok "[ $RC = 1 ] && echo '$OUT' | jq -e '.holds[0].key == \"c-star\"'" "T-CORE-BUDGET the * default of a scope applies to a card with no budget of its own"
OUT=$(BU check --card c-other --json); RC=$?
ok "[ $RC = 0 ] && echo '$OUT' | jq -e '.result == \"allow\"'" "T-CORE-BUDGET a card under the default is allowed"
plant p-plan r-x c-8 -1 0 ok 100 s1 0.6
OUT=$(BU check --project p-plan --json 2>/dev/null); RC=$?
ok "[ $RC = 1 ] && echo '$OUT' | jq -e '.result == \"held\" and .holds[0].measure == \"plan_share\"'" "T-BUD-CAP a subscription link: the plan-share cap (0.6 of 0.5) holds, no dollars involved"

# ---- T-BUD-EST: estimate before, actual at close ----
ed budgets.json '.estimate = {min_history: 3, kinds: {"qa-kind": {amount: 7, currency: "QAC"}, "qa-h": {amount: 7, currency: "QAC"}}}'
OUT=$(BU estimate --kind qa-kind --card e-0 --json); RC=$?
ok "[ $RC = 0 ] && echo '$OUT' | jq -e '.basis == \"default\" and .estimate.amount == 7 and .samples == 0'" "T-BUD-EST the estimate of a kind with no history is the data's default"
OUT=$(BU estimate --kind nokind --json); RC=$?
ok "[ $RC = 0 ] && echo '$OUT' | jq -e '.basis == \"none\" and .estimate == null'" "T-BUD-EST a kind with no data and no history has no estimate (never a guess)"
for n in 1 2 3; do BU estimate --kind qa-h --card h-$n --json >/dev/null; plant p-e r-x h-$n $((n * 2 + 2)); OUT=$(BU close --card h-$n --json); done
ok "echo '$OUT' | jq -e '.actual.amount == 8 and .estimate.amount == 7 and .difference.amount == 1'" "T-BUD-EST close records the actual from the ledger, the estimate and the difference"
ok "[ \$(evn budget.closed) = 3 ]" "T-BUD-EST every close is one trusted event line"
OUT=$(BU estimate --kind qa-h --card h-4 --json)
ok "echo '$OUT' | jq -e '.basis == \"history\" and .estimate.amount == 6 and .samples == 3'" "T-BUD-EST after 3 closed cards the estimate is the median of their actuals (4, 6, 8: 6)"
OUT=$(BU close --card never-estimated --json); RC=$?
ok "[ $RC = 0 ] && echo '$OUT' | jq -e '.estimate == null and .difference == null'" "T-BUD-EST a card closed with no estimate records only its actual"

# ---- T-BUD-ANOM: each detector once per episode ----
: >"$UL"; rm -f "$BS"; : >"$AL"; E0=$(evn budget.anomaly)
ed budgets.json '.anomalies = {spend_rate: {window_minutes: 60, trailing_windows: 4, factor: 3, min_amount: 1, lookback_minutes: 1440},
  retry_loop: {min_calls: 3, lookback_minutes: 1440}, growing_session: {min_calls: 5, lookback_minutes: 1440}, outlier_card: {factor: 3, min_cards: 4, lookback_minutes: 1440}}'
for m in 90 150 210 270; do plant p-s r-x c-t$m 2 $m ok 100 s-t$m; done           # a normal hour costs 2
plant p-s r-x c-spike 40 10 ok 100 s-spike                                           # this hour costs 40
for i in 1 2 3 4; do plant p-s r-x c-retry 0.05 $((6 - i)) error $((i * 100)) s-r; done   # 4 failing calls, input rising
for i in 1 2 3 4 5 6; do plant p-s r-x c-grow 0.05 $((8 - i)) ok $((i * 1000)) s-grow; done   # 6 calls of one session, input rising
for k in 1 2 3 4; do BU estimate --kind qa-o --card o$k --json >/dev/null; plant p-o r-x o$k 2 600; done
BU estimate --kind qa-o --card o5 --json >/dev/null; plant p-o r-x o5 40 600
OUT=$(BU anomalies --json); RC=$?
ok "[ $RC = 0 ] && echo '$OUT' | jq -e '[.new[].kind] | sort == [\"growing_session\", \"outlier_card\", \"retry_loop\", \"spend_rate\"]'" "T-BUD-ANOM a planted spend spike, retry loop, growing session and outlier card are each found"
ok "[ \$(nal spend_rate) = 1 ] && [ \$(nal retry_loop) = 1 ] && [ \$(nal growing_session) = 1 ] && [ \$(nal outlier_card) = 1 ] && [ \$(nal STL-LIM-433) = 4 ]" "T-BUD-ANOM one alert (STL-LIM-433) per anomaly"
ok "[ \$(( \$(evn budget.anomaly) - $E0 )) = 4 ]" "T-BUD-ANOM one trusted event line per anomaly"
ok "echo '$OUT' | jq -e '[.new[] | select(.kind == \"retry_loop\")][0].card == \"c-retry\" and ([.new[] | select(.kind == \"outlier_card\")][0].card == \"o5\")'" "T-BUD-ANOM the retry loop names card c-retry and the outlier is card o5, not the normal cards"
OUT=$(BU anomalies --json)
ok "echo '$OUT' | jq -e '.new == [] and (.known | length) == 4' && [ \$(nal STL-LIM-433) = 4 ]" "T-BUD-ANOM the same episodes again: no new alert (deduped by fingerprint)"
: >"$UL"; plant p-q r-x c-q1 2 ok 100 s-q; plant p-q r-x c-q2 2 ok 200 s-q; plant p-q r-x c-q3 2 error 50 s-q2
OUT=$(BU anomalies --json)
ok "echo '$OUT' | jq -e '.new == []'" "T-BUD-ANOM a quiet ledger (short rises, a single failure) raises nothing"

# ---- the red-team fixes (C-RT-01, 02, 08, 09, 10, 13) ----
: >"$UL"; rm -f "$BS"; : >"$AL"
ed data-policy.json --arg g "$(uuid)" --arg i "$IID" '.projects["p-strict2"] = {mode: "allowed_providers", allowed_providers: [], global_id: $g, install_id: $i}'
ed budgets.json --arg c "$LOCAL" --arg m "$LM" '.budgets += [
  {id: "qa-rdef", scope: "role", key: "r-dfr", window_days: 1, soft_percent: [], hard: {amount: 10, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "defer", raise_percent: null, connection: $c, model: $m}},
  {id: "qa-d2", scope: "project", key: "p-d2", window_days: 1, soft_percent: [], hard: {amount: 10, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "defer", raise_percent: null, connection: $c, model: $m}},
  {id: "qa-w", scope: "project", key: "p-w", window_days: 1, soft_percent: [], hard: {amount: 10, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "raise", raise_percent: 50, connection: null, model: null}},
  {id: "qa-r", scope: "project", key: "p-r", window_days: 1, soft_percent: [], hard: {amount: 10, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "raise", raise_percent: 50, connection: null, model: null}}]'
# C-RT-01: a role hold made by an allowed project: a project whose policy allows no provider is not told to defer
plant p-okay r-dfr c-rd 11; BU check --role r-dfr --project p-okay --json >/dev/null 2>&1; XR=$(last_req); answer "$XR" approved >/dev/null 2>&1
OUT=$(BU check --role r-dfr --project p-okay --json 2>/dev/null)
ok "echo '$OUT' | jq -e '.result == \"allow\" and .defer_to.connection == \"$LOCAL\"'" "C-RT-01 the project that made the role hold is told to defer to the allowed link"
OUT=$(BU check --role r-dfr --project p-strict2 --json 2>/dev/null); RC=$?
ok "[ $RC = 1 ] && echo '$OUT' | jq -e '.result == \"held\" and .reason == \"defer-refused\" and .defer_to == null'" "C-RT-01 a caller whose project policy forbids the link gets the hold, not defer_to"
# C-RT-02: after a defer the cap is still measured; calls on the defer link go on, spend on any other link holds again
plant p-d2 r-x c-d2 11; BU check --project p-d2 --json >/dev/null 2>&1; XR=$(last_req); answer "$XR" approved >/dev/null 2>&1
OUT=$(BU check --project p-d2 --json 2>/dev/null)
ok "echo '$OUT' | jq -e '.result == \"allow\" and .defer_to.model == \"$LM\"'" "C-RT-02 an approved defer: calls go on with the link to defer to"
PC=$LOCAL PM=$LM plant p-d2 r-x c-d2 50
OUT=$(BU check --project p-d2 --json 2>/dev/null); RC=$?
ok "[ $RC = 0 ] && echo '$OUT' | jq -e '.result == \"allow\"'" "C-RT-02 spend on the defer link itself is not counted against the cap"
hookl() { python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import budget
try:
    budget.before_call(project="p-d2", link={"connection": sys.argv[2], "model": sys.argv[3]}); print("allowed")
except budget.Held as h:
    print("held", h.code)' "$R/bin" "$1" "$2"; }
ok "[ \"\$(hookl $LOCAL $LM)\" = allowed ] && [ \"\$(hookl $OTHER $OM)\" = 'held STL-LIM-432' ]" "C-RT-02 the hook allows the call on the defer link and holds a call on any other link"
A0=$(nal STL-LIM-431); Q0=$(nreq)
plant p-d2 r-x c-d2 5
OUT=$(BU check --project p-d2 --json 2>/dev/null); RC=$?
ok "[ $RC = 1 ] && echo '$OUT' | jq -e '.result == \"held\"' && [ \$(nal STL-LIM-431) = $((A0+1)) ] && [ \$(nreq) = $((Q0+1)) ]" "C-RT-02 spend past the cap while deferred holds again: one alert, one new request"
BU check --project p-d2 --json >/dev/null 2>&1
ok "[ \$(nal STL-LIM-431) = $((A0+1)) ] && [ \$(nreq) = $((Q0+1)) ]" "C-RT-02 the reopened hold alerts once, not at every call"
# C-RT-09: a worker environment gets the held answer, no exception, no alert of its own; the host's check makes the one hold
plant p-w r-x c-w 12
cat >"$T/w.py" <<PY
import sys; sys.path.insert(0, "$R/bin")
import budget
try:
    print("result:", budget.before_call(project="p-w")["result"])
except budget.Held as e: print("Held", e.code)
except BaseException as e: print("other", type(e).__name__)
PY
A0=$(nal STL-LIM-431)
for _ in 1 2 3; do STUB_WORKER_MARK=1 python3 -I "$T/w.py" >>"$T/wout" 2>&1; done
ok "[ \$(grep -c 'Held STL-LIM-432' $T/wout) = 3 ] && [ \$(nal STL-LIM-431) = $A0 ] && ! grep -q p-w $BS" "C-RT-09 a worker environment: three calls, three held answers, no exception, no alert, no state"
BU check --project p-w --json >/dev/null 2>&1
ok "[ \$(nal STL-LIM-431) = $((A0+1)) ] && [ \"\$(STUB_WORKER_MARK=1 python3 -I $T/w.py)\" = 'Held STL-LIM-432' ] && [ \$(nal STL-LIM-431) = $((A0+1)) ]" "C-RT-09 the host's check makes the one hold and the one alert; the worker call stays held, no second alert"
# C-RT-10: a hold whose request could not be raised is retried at the next check
plant p-r r-x c-r 12
Q0=$(nreq); chmod -R a-w "$STORE"; BU check --project p-r --json >/dev/null 2>&1; chmod -R u+w "$STORE"
ok "BU hold list --json | jq -e '[.holds[] | select(.key == \"p-r\")][0].request_id == null'" "C-RT-10 the store is unwritable: the hold has no request yet"
BU check --project p-r --json >/dev/null 2>&1
ok "BU hold list --json | jq -e '[.holds[] | select(.key == \"p-r\")][0].request_id != null' && [ \$(nreq) = $((Q0+1)) ]" "C-RT-10 the next check raises the missing request (one request)"
# C-RT-08: a call that names no project is its own scope key (from data), so a project budget for it is not skipped
ed budgets.json '.budgets += [{id: "qa-none", scope: "project", key: "unnamed", window_days: 1, soft_percent: [], hard: {amount: 10, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "raise", raise_percent: 50, connection: null, model: null}}]'
plant p-x r-x c-n 12; python3 -I -c 'import json, sys
L = [json.loads(x) for x in open(sys.argv[1])]; L[-1]["project"] = None
open(sys.argv[1], "w").write("".join(json.dumps(x) + "\n" for x in L))' "$UL"
OUT=$(BU check --card c-n --json 2>/dev/null); RC=$?
ok "[ $RC = 1 ] && echo '$OUT' | jq -e '.result == \"held\" and (.holds | map(.key) | index(\"unnamed\") != null)'" "C-RT-08 a call that names no project is held by the budget of the data's unnamed project key"
ed budgets.json '.budgets |= map(select(.id != "qa-none"))'
# C-RT-13: the runtime runs the problems check: a raise with no percent fails closed
ed budgets.json '.budgets += [{id: "qa-bad", scope: "project", key: "p-bad", window_days: 1, soft_percent: [], hard: {amount: 10, currency: "QAC"}, plan_share_cap: null, on_approve: {option: "raise", raise_percent: null, connection: null, model: null}}]'
OUT=$(BU check --project p-soft --json 2>$T/err); RC=$?
ok "[ $RC = 1 ] && grep -q STL-LIM-434 $T/err && echo '$OUT' | jq -e '.code == \"STL-LIM-434\"'" "C-RT-13 a budget the problems check rejects fails closed at run time (STL-LIM-434)"
ed budgets.json '.budgets |= map(select(.id != "qa-bad"))'

# ---- bad data fails closed, no secrets ----
ed budgets.json '.budgets[0].hard = {amount: -1, currency: "QAC"}'
OUT=$(BU check --project p-soft --json 2>$T/err); RC=$?
ok "[ $RC = 1 ] && grep -q STL-LIM-434 $T/err && echo '$OUT' | jq -e '.code == \"STL-LIM-434\"'" "a broken budgets file fails closed: STL-LIM-434, the call is refused"
OUT=$(BU check-data --json 2>/dev/null); RC=$?
ok "[ $RC = 1 ] && echo '$OUT' | jq -e '.ok == false and (.problems[0] | test(\"hard\"))'" "check-data exits 1 and names the broken row"
ok "! grep -rq 'sekret' $AL $EV" "no secret value in the alert or event logs"

[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
