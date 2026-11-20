#!/usr/bin/env bash
# Hermetic self-test for the policy layer (F3 item P; body B3, AC2, AC3; design section 1 with rulings DC-03, DC-11, DC-12).
# Every section runs in its own scratch root (bash policy-selftest.sh <section>); no argument runs them all.
# Sections -> checks: regen = AC3-regen | drift = AC3-drift | render = AC2-policy-render | secret = T-SECRET-DATA |
#                     sandbox = T-SANDBOX-STUB | tokenenv = DC-03 | shape = DC-12 | hook = builder's cases (policy.py hook, DC-13, model flags)
#                     shellhook = Gate B fix V1-01/RT1-01/V1-03 (shell class, dirs, run tmp) | ocrender = Gate B fix V1-02/V1-03/V1-11
# Written test-first (F3 wave 1): the CLI contract is design section 1 (policy.py check|generate|drift [--json]); exit codes and the
# code range STL-GRD-610..619 are asserted, never wording.
# ASSUMPTIONS (names the design leaves open; a builder who picks otherwise changes the test with a note, not the contract):
#  A1 .stella/policy.json: rules[] each {id, kind, ...}; the secret rule is kind "secret_read" with deny[] and allow[] globs; a "sandbox"
#     object with writable, network and credential_dirs_hidden (design section 1 names these).
#  A2 .stella/adapters.json: entries[] with id; the policy part at entries[].policy with target.owned_pointers (design section 1);
#     an adapter's token_env is a key named token_env somewhere in its entry (DC-02/DC-03); a rule kind an adapter covers (by a
#     config shape or a hook) appears in its entry as an object key or a list item equal to the kind name (DC-12).
#  A3 committed generated files live in docs/hermes-local/generated/*.json plus the repo opencode.json (design section 1).
#  A4 a rule an adapter enforces through its hook instead of a config shape shows in its rendered config as a hook command naming
#     policy.py (DC-12); the rendered text then need not hold the rule's values.
#  A5 the one policy loader (DC-11, in bin/roles.py) reads the scratch root's .stella/policy.json under STELLA_ROOT, as the data tool does;
#     the hooks are run as copies whose /workspace/bin import points at the scratch root's bin (as secret-read-selftest does).
#  A6 a rendered value may be rewritten into the CLI's own form, so a glob is matched by its text without a leading ~/ and leading *.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=policy-selftest
SECTIONS="regen drift render secret sandbox tokenenv shape hook shellhook ocrender"
if [ $# = 0 ]; then
  f=0; for s in $SECTIONS; do bash "${BASH_SOURCE[0]}" "$s" || f=$((f+1)); done
  [ $f = 0 ] && echo "$ME PASS" || echo "$ME FAIL ($f sections)"; [ $f = 0 ]; exit
fi
case " $SECTIONS " in *" $1 "*) ;; *) echo "usage: $ME.sh [$(tr ' ' '|' <<<"$SECTIONS")]" >&2; exit 2;; esac
S=$1
# ---- harness: a scratch root of its own (bin, .stella, docs and the root config files copied), its own HOME, temp, alert folder ----
T=$(mktemp -d "${TMPDIR:-/tmp}/$ME.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'kill $(jobs -p) 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "# KEPT $T"; else chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; fi' EXIT
R=$T/root
mkdir -p "$R/.supervisor/logs" "$R/.supervisor/state" "$R/.claude" "$T/home" "$T/tmp" "$T/sup/logs" "$T/pb" "$T/o"
cp -r "$ROOT/bin" "$ROOT/.stella" "$ROOT/docs" "$R/"
for f in opencode.json .mcp.json .claude/settings.json .claude/skills; do [ -e "$ROOT/$f" ] && cp -r "$ROOT/$f" "$R/$f"; done
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
printf '#!/usr/bin/env bash\necho "[]"\n' >"$T/pb/hermes"; chmod +x "$T/pb/hermes"; export PATH=$T/pb:$PATH
AL=$T/sup/logs/alerts.log; : >"$AL"
EV=$R/$(ix .event_log)
IID=$(jq -r .install_id "$R/.stella/install.json")
fails=0; n=0
# ok <test> <label>: a FAIL line (never a crash) with the last output of the case under it
ok() { n=$((n+1)); if ( set -o pipefail; eval "$1" ) >/dev/null 2>&1; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/o/last" ] && tail -n 3 "$T/o/last" | cut -c1-240 | sed 's/^/     | /'; fi; : >"$T/o/last"; }
finish() { echo "# $ME $S: $n cases, $fails failed"; [ "$fails" = 0 ]; exit $?; }
# run <tag> <cmd...>: stdout to $T/o/<tag>.out, stderr to $T/o/<tag>.err, exit code in RC
run() { local t=$1; shift; "$@" >"$T/o/$t.out" 2>"$T/o/$t.err"; RC=$?; cat "$T/o/$t.out" "$T/o/$t.err" >"$T/o/last" 2>/dev/null; }
out() { cat "$T/o/$1.out" "$T/o/$1.err" 2>/dev/null; }
ed() { local f=$R/$1; jq "${@:2}" "$f" >"$f.n" && mv "$f.n" "$f"; }   # <file under the root> <jq args and filter>
uuid() { cat /proc/sys/kernel/random/uuid; }
WORKER() { env STUB_WORKER_MARK=1 "$@"; }   # a worker environment (a roles.json worker marker)

P() { python3 -I "$R/bin/policy.py" "$@"; }
PJ=$R/.stella/policy.json; AD=$R/.stella/adapters.json; GEN=$R/docs/hermes-local/generated
code() { out "$1" | grep >/dev/null -E 'STL-GRD-61[0-9]'; }
adapters() { jq -r '.entries[]? | select(.policy) | .id' "$AD" 2>/dev/null; }
mkdir -p "$T/wt"

case $S in
regen)   # AC3-regen: one rule change regenerates every CLI's config
  CS=$(sha256sum <"$R/.claude/settings.json")
  run g0 P generate --all --write; ok '[ $RC = 0 ]' "AC3-regen generate --all --write renders the shipped policy (exit 0)"
  ok 'ls "$GEN"/*.json >/dev/null' "AC3-regen the committed generated configs exist under docs/hermes-local/generated"
  run d0 P drift --json; ok '[ $RC = 0 ] && [ -s "$T/o/d0.out" ] && jq -e . "$T/o/d0.out"' "AC3-regen drift is clean (exit 0, JSON) right after a regeneration"
  ADS=$(adapters); ok '[ -n "$ADS" ]' "AC3-regen adapters.json has at least one adapter with a policy part"
  ed .stella/policy.json '(.rules[] | select(.kind == "secret_read") | .deny) += ["*.qa-regen-canary"]'
  ok '[ -s "$PJ" ] && jq -e "[.rules[] | select(.kind == \"secret_read\") | .deny[] | select(. == \"*.qa-regen-canary\")] | length == 1" "$PJ"' "AC3-regen precondition: one secret rule glob added in the data"
  run d1 P drift --json; ok '[ $RC = 1 ] && code d1' "AC3-regen the changed rule makes the committed configs stale: drift exit 1 with STL-GRD-61x"
  run g1 P generate --all --write; ok '[ $RC = 0 ]' "AC3-regen regenerate after the rule change (exit 0)"
  run d2 P drift --json; ok '[ $RC = 0 ]' "AC3-regen drift clean again after the regeneration"
  for f in "$GEN"/*.json; do [ -f "$f" ] || continue
    ok 'grep -qF qa-regen-canary "$f" || grep >/dev/null -F policy.py "$f"' "AC3-regen committed config ${f#$R/} carries the new rule (or the policy hook)"
  done
  for a in $ADS; do
    run "a-$a" P generate --adapter "$a" --worktree "$T/wt" --out "$T/o/gen-$a" --json
    ok '[ $RC = 0 ] && { grep -qF qa-regen-canary "$T/o/gen-$a" || grep >/dev/null -F policy.py "$T/o/gen-$a"; }' "AC3-regen adapter $a: its fresh config carries the changed rule"
  done
  ok 'ls "$GEN"/*.json >/dev/null && [ "$(sha256sum <"$R/.claude/settings.json")" = "$CS" ]' "AC3-regen the repo .claude/settings.json is never generated or touched"
  ;;
drift)   # AC3-drift: a hand edit of a generated config is caught
  run g0 P generate --all --write; ok '[ $RC = 0 ]' "AC3-drift generate --all --write (exit 0)"
  run d0 P drift --json; ok '[ $RC = 0 ]' "AC3-drift drift clean after generation"
  GF=$(ls "$GEN"/*.json 2>/dev/null | head -n1); ok '[ -n "$GF" ]' "AC3-drift precondition: a committed generated config exists"
  A=$(basename "${GF:-x}" .json); A=${A%.settings}
  PTR=$(jq -r --arg a "$A" '.entries[]? | select(.id == $a) | .policy.target.owned_pointers[0] // empty' "$AD" 2>/dev/null)
  ok '[ -n "$PTR" ]' "AC3-drift adapter $A names its owned pointers (policy.target.owned_pointers)"
  if [ -n "$GF" ] && [ -n "$PTR" ]; then
    cp "$GF" "$T/gf.keep"
    jq '. + {"qa_unowned_key": 1}' "$T/gf.keep" >"$GF"
    run d1 P drift --json; ok '[ $RC = 0 ]' "AC3-drift an edit outside the owned pointers is not drift (exit 0)"
    jq --arg p "$PTR" 'setpath($p | ltrimstr("/") | split("/") | map(gsub("~1"; "/") | gsub("~0"; "~")); "qa-hand-edit")' "$T/gf.keep" >"$GF"
    run d2 P drift --json; ok '[ $RC = 1 ] && code d2 && out d2 | grep >/dev/null -F "$(basename "$GF")"' "AC3-drift a hand edit at an owned pointer: exit 1, STL-GRD-61x, the file named"
    cp "$T/gf.keep" "$GF"; run d3 P drift --json; ok '[ $RC = 0 ]' "AC3-drift the restored file is clean again"
  fi
  cp "$R/opencode.json" "$T/oc.keep"
  jq '.permission.read["qa-hand-edit/**"] = "allow"' "$T/oc.keep" >"$R/opencode.json"
  run d4 P drift --json; ok '[ $RC = 1 ] && code d4 && out d4 | grep >/dev/null -F opencode.json' "AC3-drift a hand edit of the repo opencode.json permission block: exit 1, STL-GRD-61x, named"
  cp "$T/oc.keep" "$R/opencode.json"
  ;;
render)   # AC2-policy-render: every active adapter's generated config holds the write boundary, protected and secret denies
  ADS=$(adapters); ok '[ -n "$ADS" ]' "AC2-policy-render precondition: adapters.json has adapters with a policy part"
  run c0 P check --json; ok '[ $RC = 0 ]' "AC2-policy-render policy.py check passes on the shipped data"
  PROT=$(jq -r '.protected.repo[], .protected.home[]' "$RJ")
  SEC=$(jq -r '.rules[]? | select(.kind == "secret_read") | .deny[]' "$PJ" 2>/dev/null | sed -e 's#^~/##' -e 's#^\*\**##')
  ok '[ -n "$SEC" ]' "AC2-policy-render precondition: the secret rule has deny globs"
  for a in $ADS; do
    G=$T/o/gen-$a; run "g-$a" P generate --adapter "$a" --worktree "$T/wt" --out "$G" --json
    ok '[ $RC = 0 ] && [ -s "$G" ] && [ -s "$T/o/g-$a.out" ] && jq -e . "$T/o/g-$a.out"' "AC2-policy-render adapter $a: generate --adapter --worktree --out --json renders (exit 0, JSON)"
    hook() { grep -qF policy.py "$G"; }
    ok '{ grep -qF "$T/wt" "$G" || hook; } && ! grep -qF "{worktree}" "$G"' "AC2-policy-render adapter $a: the write boundary is the given worktree (no template left)"
    miss=; for p in $PROT; do grep -qF -- "$p" "$G" 2>/dev/null || miss="$miss $p"; done
    ok '[ -z "$miss" ] || hook' "AC2-policy-render adapter $a: every protected path of roles.json is denied (missing:$miss)"
    miss=; for p in $SEC; do grep -qF -- "$p" "$G" 2>/dev/null || miss="$miss $p"; done
    ok '[ -z "$miss" ] || hook' "AC2-policy-render adapter $a: every secret deny of the policy rule is in its config (missing:$miss)"
  done
  ;;
secret)   # T-SECRET-DATA: the secret list lives only in policy data; secret-guard, read-only-terminal and box read it; unreadable -> refuse
  HK=$R/docs/hermes-local/hooks; SG=$T/secret-guard.py; RO=$T/read-only-terminal.py
  for h in "$HK/builder/secret-guard.py:$SG" "$HK/default/read-only-terminal.py:$RO"; do
    sed "s#/workspace/bin#$R/bin#g" "${h%%:*}" >"${h##*:}"; chmod +x "${h##*:}"; done
  term() { jq -nc --arg c "$2" --arg d "$R" '{tool_name: "terminal", tool_input: {command: $c}, cwd: $d}' | python3 -I "$1" >"$T/o/h.out" 2>&1; echo $?; }
  box_classes() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import box; print(box.secret_classes())' "$R/bin"; }
  ok '[ -s "$PJ" ] && jq -e "[.rules[] | select(.kind == \"secret_read\")] | length == 1 and (.[0].deny | length > 0) and (.[0].allow | type == \"array\")" "$PJ"' \
    "T-SECRET-DATA policy.json holds exactly one secret_read rule with deny and allow globs"
  ok '! grep -qE "^[[:space:]]*SECRETS(_OK)?[[:space:]]*=[[:space:]]*[\(\[]" "$HK/builder/secret-guard.py" "$HK/default/read-only-terminal.py" "$R/bin/box.py"' \
    "T-SECRET-DATA no hook and not box.py keeps its own literal SECRETS / SECRET_OK list"
  ok '[ "$(term "$SG" "cat notes.qacanary")" = 0 ] && [ "$(term "$RO" "cat notes.qacanary")" = 0 ]' "T-SECRET-DATA control: a file of an unlisted kind is read by both hooks before the rule names it"
  ed .stella/policy.json '(.rules[] | select(.kind == "secret_read") | .deny) += ["*.qacanary"]'
  ok '[ "$(term "$SG" "cat notes.qacanary")" = 2 ]' "T-SECRET-DATA a glob added to the policy rule is refused by secret-guard (exit 2)"
  ok '[ "$(term "$RO" "cat notes.qacanary")" = 2 ]' "T-SECRET-DATA ... and by read-only-terminal (exit 2)"
  ok 'box_classes | grep >/dev/null -F "*.qacanary"' "T-SECRET-DATA ... and box.py secret_classes() returns it"
  ok '[ "$(term "$SG" "cat .env.qaok")" = 2 ]' "T-SECRET-DATA control: .env.qaok is a secret before the allow list names it"
  ed .stella/policy.json '(.rules[] | select(.kind == "secret_read") | .allow) += [".env.qaok"]'
  ok '[ "$(term "$SG" "cat .env.qaok")" = 0 ] && [ "$(term "$SG" "cat .env.qabad")" = 2 ]' "T-SECRET-DATA an allow glob in the rule lets that one name through secret-guard, its neighbour stays refused"
  ok 'box_classes | grep >/dev/null -F ".env.qaok"' "T-SECRET-DATA box.py secret_classes() returns the allow glob from the rule"
  cp "$PJ" "$T/pj.keep"; printf '{not json' >"$PJ"
  ok '[ "$(term "$SG" "cat qa-notes.txt")" = 2 ]' "T-SECRET-DATA unreadable policy file: secret-guard refuses every read (exit 2)"
  ok '[ "$(term "$RO" "cat qa-notes.txt")" = 2 ]' "T-SECRET-DATA unreadable policy file: read-only-terminal refuses every read (exit 2)"
  ok '! box_classes' "T-SECRET-DATA unreadable policy file: box.py secret_classes() fails closed"
  jq 'del(.rules[] | select(.kind == "secret_read"))' "$T/pj.keep" >"$PJ"
  ok '[ "$(term "$SG" "cat qa-notes.txt")" = 2 ] && [ "$(term "$RO" "cat qa-notes.txt")" = 2 ] && ! box_classes' "T-SECRET-DATA policy without a secret rule: both hooks refuse every read and box fails closed"
  cp "$T/pj.keep" "$PJ"
  ok '[ "$(term "$SG" "cat qa-notes.txt")" = 0 ]' "T-SECRET-DATA control: the restored rule lets an ordinary read through"
  ;;
sandbox)   # T-SANDBOX-STUB: the sandbox policy is data and a features stub due at E1
  ok '[ -s "$PJ" ] && jq -e ".sandbox.writable == [\"{worktree}\"] and (.sandbox.network | type == \"string\" and length > 0) and (.sandbox | has(\"credential_dirs_hidden\"))" "$PJ"' \
    "T-SANDBOX-STUB policy.json sandbox: writable is the worktree only, a network rule, credential_dirs_hidden"
  ok '[ -s "$R/.stella/features.json" ] && jq -e "[.entries[] | select(.id == \"adapter-sandbox\")] | length == 1 and .[0].due_phase == \"E1\" and (.[0].replaced_by | type == \"string\" and length > 0) and .[0].status != \"on\"" "$R/.stella/features.json"' \
    "T-SANDBOX-STUB features.json stub adapter-sandbox: due_phase E1, replaced_by set, not on"
  ok '[ -s "$IX" ] && jq -e "[.files[] | select(.path == \".stella/policy.json\")] | length == 1" "$IX" && [ -f "$R/.stella/schemas/policy.schema.json" ]' "T-SANDBOX-STUB policy.json has an index row and a schema"
  run c0 python3 -I "$R/bin/stella_data.py" check; ok '[ $RC = 0 ]' "T-SANDBOX-STUB stella_data.py check passes with the policy data"
  run c1 P check --json; ok '[ $RC = 0 ]' "T-SANDBOX-STUB policy.py check passes"
  ed .stella/policy.json '.sandbox.writable = ["{worktree}", "/"]'
  run c2 P check --json; ok '[ $RC = 1 ] && code c2' "T-SANDBOX-STUB a writable path beyond the worktree in the sandbox data fails check (STL-GRD-61x)"
  ;;
tokenenv)   # DC-03: check fails when an adapter's token_env is not an owner-auth worker signal
  run c0 P check --json; ok '[ $RC = 0 ]' "DC-03 policy.py check passes on the shipped data"
  TP=$(jq -c '[paths | select(.[-1] == "token_env")][0] // empty' "$AD" 2>/dev/null); ok '[ -n "$TP" ]' "DC-03 precondition: an adapter entry carries token_env"
  if [ -n "$TP" ]; then
    ed .stella/adapters.json --argjson p "$TP" 'setpath($p; (getpath($p) | if type == "array" then ["QA_NOT_A_SIGNAL"] else "QA_NOT_A_SIGNAL" end))'
    run c1 P check --json; ok '[ $RC = 1 ] && code c1' "DC-03 an adapter token_env that is not in worker_signals.token_env: check exit 1, STL-GRD-61x"
    ed "${POL#$R/}" '.worker_signals.token_env += ["QA_NOT_A_SIGNAL"]'
    run c2 P check --json; ok '[ $RC = 0 ]' "DC-03 the same name added to owner-auth worker_signals.token_env (data only): check passes"
  fi
  ;;
shape)   # DC-12: a rule kind with neither a config shape nor a hook for an adapter fails check
  run c0 P check --json; ok '[ $RC = 0 ]' "DC-12 policy.py check passes on the shipped data"
  A=$(adapters | head -n1); ok '[ -n "$A" ]' "DC-12 precondition: an adapter with a policy part"
  for k in secret_read write_boundary; do
    cp "$AD" "$T/ad.keep" 2>/dev/null
    ed .stella/adapters.json --arg a "$A" --arg k "$k" '(.entries[] | select(.id == $a)) |= walk(if type == "object" then del(.[$k]) elif type == "array" then map(select(. != $k)) else . end)'
    run "c-$k" P check --json; ok '[ $RC = 1 ] && code "c-$k" && out "c-$k" | grep >/dev/null -F -- "$A"' "DC-12 adapter $A with no shape and no hook for rule kind $k: check exit 1, STL-GRD-61x, the adapter named"
    cp "$T/ad.keep" "$AD" 2>/dev/null
  done
  ;;
hook)   # builder cases (F3 item P): policy.py hook judges one tool call by the same rules; data-driven guards (DC-13, model flags)
  A=$(jq -r '[.entries[] | select(.policy.hook) | .id][0] // empty' "$AD"); ok '[ -n "$A" ]' "hook precondition: an adapter with a policy hook"
  TL() { jq -r --arg a "$A" --arg c "$1" '[.entries[] | select(.id == $a) | .tools | to_entries[] | select(.value.class == $c)][0] | "\(.key) \(.value.path // .value.command)"' "$AD"; }
  read -r WT_ WP <<<"$(TL write)"; read -r RT_ RP <<<"$(TL read)"; read -r ST_ SPP <<<"$(TL shell)"
  hk() { jq -nc --arg t "$1" --arg p "$2" --arg v "$3" --arg d "$T/wt" '{tool_name: $t, tool_input: ({} | setpath($p | ltrimstr("/") | split("/"); $v)), cwd: $d}' \
    | P hook --adapter "$A" --worktree "$T/wt" >"$T/o/hk.out" 2>&1; echo $?; }
  denied() { grep -qE "$1" "$T/o/hk.out"; }
  ok '[ "$(hk "$WT_" "$WP" "$T/wt/a.txt")" = 0 ] && [ ! -s "$T/o/hk.out" ]' "hook a write inside the worktree: no objection"
  hk "$WT_" "$WP" "$T/elsewhere/a.txt" >/dev/null; ok 'denied STL-GRD-615' "hook a write outside the worktree: refused with STL-GRD-615"
  hk "$WT_" "$WP" "../a.txt" >/dev/null; ok 'denied STL-GRD-615' "hook a relative write that climbs out of the worktree: refused"
  hk "$RT_" "$RP" "$HOME/.ssh/id_x" >/dev/null; ok 'denied STL-GRD-616' "hook a read under a home secret folder of the rule: refused with STL-GRD-616"
  ok '[ "$(hk "$RT_" "$RP" "$T/wt/.env.example")" = 0 ] && [ ! -s "$T/o/hk.out" ]' "hook an allowed name of the rule is read"
  hk "$RT_" "$RP" "$T/wt/x.pem" >/dev/null; ok 'denied STL-GRD-616' "hook a file name glob of the rule: refused"
  PR0=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import roles; print(roles.protected(roles.load())[0][0])' "$R/bin")
  hk "$RT_" "$RP" "$PR0/x" >/dev/null; ok '[ -n "$PR0" ] && denied STL-GRD-616' "hook a read under a protected repo path of the stack (as the role module anchors it): refused"
  hk "$ST_" "$SPP" "cat ~/.hermes/auth.json" >/dev/null; ok 'denied STL-GRD-616' "hook a shell command that names a secret path: refused"
  ok '[ "$(hk "$ST_" "$SPP" "cat .env.example")" = 0 ] && [ ! -s "$T/o/hk.out" ]' "hook a shell command naming only an allowed name: no objection"
  ok '[ "$(hk qa-unmapped-tool /path "$T/elsewhere/x")" = 0 ] && [ ! -s "$T/o/hk.out" ]' "hook a tool the adapter's tool map does not name: no decision"
  printf '{not json' | P hook --adapter "$A" --worktree "$T/wt" >"$T/o/hk.out" 2>&1; ok 'denied STL-GRD-617' "hook an unreadable payload: refused (fail closed)"
  ed .stella/policy.json '(.rules[] | select(.kind == "secret_read") | .deny) += ["*.qahook"]'
  hk "$RT_" "$RP" "$T/wt/n.qahook" >/dev/null; ok 'denied STL-GRD-616' "hook a glob added to the policy data is refused with no code change"
  HK=$R/docs/hermes-local/hooks/builder; GG=$T/git-guard.py; MG=$T/model-guard.py
  for h in "$HK/git-guard.py:$GG" "$HK/model-guard.py:$MG"; do sed "s#/workspace/bin#$R/bin#g" "${h%%:*}" >"${h##*:}"; done
  term() { jq -nc --arg c "$2" '{tool_name: "terminal", tool_input: {command: $c}}' | python3 -I "$1" >"$T/o/h.out" 2>&1; echo $?; }
  ok '[ "$(term "$GG" "git gc --prune=now")" = 0 ]' "DC-13 control: git gc passes the git guard before the commit rule names it"
  ed .stella/policy.json '(.rules[] | select(.kind == "commit_rule") | .deny_git) += [{"sub": "gc", "why": "qa: gc named by the policy"}]'
  ok '[ "$(term "$GG" "git gc --prune=now")" = 2 ] && grep -qF "qa: gc named by the policy" "$T/o/h.out"' "DC-13 a subcommand added to the policy commit rule is refused by the git guard (its why shown)"
  ok '[ "$(term "$GG" "git config user.name x")" = 2 ] && [ "$(term "$GG" "git commit -an -m x")" = 2 ] && [ "$(term "$GG" "git add -A")" = 2 ] && [ "$(term "$GG" "git status")" = 0 ]' "DC-13 the shipped commit rule still refuses config, commit -n (grouped), add -A; git status passes"
  ok '[ "$(term "$MG" "qa-fake-cli -p hi")" = 0 ]' "model flags control: an unknown command name passes the model guard"
  ed .stella/adapters.json '(.entries[] | select(.model_flags) | .model_flags.names) += ["qa-fake-cli"]'
  ok '[ "$(term "$MG" "qa-fake-cli -p hi")" = 2 ]' "model flags: a command name added to an adapter's model_flags is judged by the model guard (no model: refused)"
  # X1 last fix cycle (crt-final X1-CRT-01, X1-CRT-04; new cases)
  mkdir -p "$T/wt/.git"; hk "$WT_" "$WP" "$T/wt/.git/config" >/dev/null; ok 'denied STL-GRD-615' "X1-CRT-01 hook a write to the worktree's .git/config: refused with STL-GRD-615"
  hk "$WT_" "$WP" "sub/.GiT/hooks/x" >/dev/null; ok 'denied STL-GRD-615' "X1-CRT-01 hook a write under a nested .git folder (any case): refused"
  hk "$WT_" "$WP" ".git" >/dev/null; ok 'denied STL-GRD-615' "X1-CRT-01 hook a write of the worktree's .git itself (a linked worktree's pointer file): refused"
  hk "$ST_" "$SPP" "echo x >> .git/config" >/dev/null; ok 'denied STL-GRD-615' "X1-CRT-01 hook a shell command writing into .git: refused"
  ok '[ "$(hk "$WT_" "$WP" "$T/wt/.gitignore")" = 0 ] && [ ! -s "$T/o/hk.out" ]' "X1-CRT-01 control: .gitignore (a file, not the .git folder) is written"
  ln -sfn /proc/self/cwd "$T/wt/pl"
  pl() { python3 -I -c 'import sys, json; sys.path.insert(0, sys.argv[1]); import policy; print(json.dumps(policy.placed(json.loads(sys.argv[2]))))' "$R/bin" "$1"; }
  ok 'for p in /proc/self/cwd/x /proc/thread-self/root/etc /proc/1/cwd/x /proc/$$/fd/0 /dev/fd/3 /dev/stdin /dev/stderr /proc/self pl/x; do [ "$(pl "$(jq -nc --arg p "$p" --arg c "$T/wt" "{path: \$p, cwd: \$c}")")" = null ] || exit 1; done' \
    "X1-CRT-04 policy.placed refuses per-process path aliases (/proc/self, /proc/thread-self, /proc/<n>, /dev/fd, /dev/std*, and a worktree link to one): no path"
  ok '[ "$(pl "{\"path\": \"./a//b/../c\", \"cwd\": \"/qa-none\"}" | jq -r .path)" = /qa-none/a/c ] && [ "$(pl "{\"path\": \"/dev/null\"}" | jq -r .path)" = /dev/null ]' "X1-CRT-04 control: a plain path is placed canonical; /dev/null stays a path"
  ;;
shellhook)   # Gate B fix cycle 1 (V1-01 High, RT1-01; V1-03 run tmp): the hook's shell class enforces the file tools' rules (protected,
  # secret, write boundary = worktree + run tmp; ~, $HOME, .., cd, relative paths resolved; unparseable fails closed); file tools honour secret dirs
  A=$(jq -r '[.entries[] | select(.policy.hook) | .id][0] // empty' "$AD"); ok '[ -n "$A" ]' "shellhook precondition: an adapter with a policy hook"
  TL() { jq -r --arg a "$A" --arg c "$1" --arg p "$2" '[.entries[] | select(.id == $a) | .tools | to_entries[] | select(.value.class == $c and ($p == "" or (.value.path // .value.command) == $p))][0] | "\(.key) \(.value.path // .value.command)"' "$AD"; }
  read -r ST_ SPP <<<"$(TL shell "")"; read -r WT_ WP <<<"$(TL write "")"; read -r GT_ GP <<<"$(TL read /path)"; read -r RT0 RP0 <<<"$(TL read "")"
  # hc <command> [cwd]: a shell call judged by the hook; hf <tool> <pointer> <path>: a file tool call
  hc() { jq -nc --arg t "$ST_" --arg p "$SPP" --arg v "$1" --arg d "${2:-$T/wt}" '{tool_name: $t, tool_input: ({} | setpath($p | ltrimstr("/") | split("/"); $v)), cwd: $d}' \
    | P hook --adapter "$A" --worktree "$T/wt" >"$T/o/hk.out" 2>&1; echo $?; }
  hf() { jq -nc --arg t "$1" --arg p "$2" --arg v "$3" --arg d "$T/wt" '{tool_name: $t, tool_input: ({} | setpath($p | ltrimstr("/") | split("/"); $v)), cwd: $d}' \
    | P hook --adapter "$A" --worktree "$T/wt" >"$T/o/hk.out" 2>&1; echo $?; }
  refused() { grep -qE "$1" "$T/o/hk.out"; }
  clean() { [ "$1" = 0 ] && [ ! -s "$T/o/hk.out" ]; }
  STK=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import roles; print(roles.ROOT)' "$R/bin")
  PR0=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import roles; print(roles.protected(roles.load())[0][0])' "$R/bin")
  OWN=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import roles; print(roles.owner_settings(roles.load())[0])' "$R/bin")
  PH=$(jq -r '.protected.home[0]' "$RJ")
  ok '[ -n "$ST_" ] && [ -n "$WT_" ] && [ -n "$GT_" ] && [ -n "$PR0" ] && [ -n "$OWN" ] && [ -n "$PH" ]' "shellhook precondition: shell, write and search tools in the tool map; a protected path, an owner file, a protected home folder"
  mkdir -p "$T/elsewhere" "$T/wt/sub"; : >"$T/elsewhere/in.txt"; : >"$T/wt/app.env"
  # reads through the shell (RT1-01 payloads first: the stack's protected path and owner file named from the stack folder)
  for c in "cat $PR0/x" "cat $OWN" "cd $(dirname "$OWN") && cat $(basename "$OWN")" "head ~/$PH/x" 'cat $HOME/'"$PH"'/x' "less ../../..$PR0/x"; do
    hc "$c" "$STK" >/dev/null; ok 'refused STL-GRD-616' "shellhook V1-01 a shell read of a protected or owner path is refused (616): $c"
  done
  hc "cat app.env" >/dev/null; ok 'refused STL-GRD-616' "shellhook V1-01 a shell read of a file the secret name globs name is refused (616)"
  : >"$T/wt/app.example.env"; : >"$T/wt/app.env.sample"   # fix cycle 2: example env files stay readable, by the shell and the file tools
  ok 'clean "$(hc "cat app.example.env app.env.sample")" && clean "$(hf "$RT0" "$RP0" "$T/wt/app.example.env")"' "shellhook fix 2: an example/sample env file (app.example.env, app.env.sample) is readable"
  # writes through the shell: every target outside the worktree and the run tmp is refused (615)
  for c in "echo x > $T/elsewhere/f" "echo x >> ../f" "echo x 2>$T/elsewhere/e" "tee $T/elsewhere/f" "cp a $T/elsewhere/" "mv a ../b" "install -m 644 a $T/elsewhere/b" \
           "ln -s a $T/elsewhere/l" "rsync -a a $T/elsewhere/" "dd if=a of=$T/elsewhere/b" "sed -i s/a/b/ $T/elsewhere/f" "truncate -s 0 $T/elsewhere/f" \
           "mkdir $T/elsewhere/d" "touch ~/f" 'rm -rf $HOME/x' "git -C $T/elsewhere commit -m x" "cd $T/elsewhere && touch f" "cp -t $T/elsewhere a" \
           "sudo tee $T/elsewhere/f" 'echo x > $QA_UNSET_VAR/f' "X=$T/elsewhere; touch \$X/f" "bash -c 'echo x > $T/elsewhere/f'" "echo x > $STK/bin/evil.sh"; do
    hc "$c" >/dev/null; ok 'refused STL-GRD-615' "shellhook V1-01 a shell write outside the worktree and the run tmp is refused (615): $c"
  done
  hc "echo 'unterminated" >/dev/null; ok 'refused "STL-GRD-61[57]"' "shellhook V1-01 a command the hook cannot parse is refused (fail closed)"
  # no objection: writes inside the worktree or the run tmp, reads of ordinary paths, words that are no path
  for c in "echo x > out.txt" "echo x > $T/wt/sub/f" "cp $T/elsewhere/in.txt ./copy" 'echo x > $TMPDIR/f' "touch $TMPDIR/t" "ls -la 2>&1 >/dev/null" \
           "git status" "mkdir -p build && cd build && touch x" "cat .env.example" 'node -e "console.log(process.env.HOME)"' "sed -i s/a/b/ sub/f" "dd if=/dev/zero of=sub/z count=1"; do
    ok 'clean "$(hc "$c")"' "shellhook no objection: $c"
  done
  # RT3-07: a CLI's own project config inside the worktree (any adapter's config_files, at any depth) is never written: it would override the generated policy
  CF=$(jq -r '[.entries[] | .config_files // [] | .[]] | .[]' "$AD"); ok '[ -n "$CF" ]' "shellhook RT3-07 precondition: the adapters name their own config files (config_files)"
  for cfn in $CF; do q=${cfn//\*/x}
    hf "$WT_" "$WP" "$T/wt/$q" >/dev/null; ok 'refused STL-GRD-615' "shellhook RT3-07 a file tool write of a CLI config in the worktree is refused (615): $q"
    hf "$WT_" "$WP" "$T/wt/sub/$q/inner" >/dev/null; ok 'refused STL-GRD-615' "shellhook RT3-07 ... in a subfolder, or under it (615): sub/$q/inner"
    hc "echo {} > $q" >/dev/null; ok 'refused STL-GRD-615' "shellhook RT3-07 a shell write of a CLI config in the worktree is refused (615): echo {} > $q"
    hc "mkdir -p sub && cp a sub/$q" >/dev/null; ok 'refused STL-GRD-615' "shellhook RT3-07 a shell copy onto a CLI config in a subfolder is refused (615): cp a sub/$q"
  done
  ok 'clean "$(hf "$WT_" "$WP" "$T/wt/docs/config-notes.md")"' "shellhook RT3-07 control: an ordinary file in the worktree is written"
  # V1-03: the run tmp is writable through the file tools too
  ok 'clean "$(hf "$WT_" "$WP" "$TMPDIR/x.txt")"' "shellhook V1-03 a file tool write into the run tmp: no objection"
  # V1-01: the file tools honour the secret rule's dirs (a search over a folder that holds one)
  hf "$GT_" "$GP" "$HOME" >/dev/null; ok 'refused STL-GRD-616' "shellhook V1-01 a search over the home folder (it holds secret folders) is refused (616)"
  hf "$GT_" "$GP" /proc >/dev/null; ok 'refused STL-GRD-616' "shellhook V1-01 a search over /proc is refused (616)"
  ok 'clean "$(hf "$GT_" "$GP" "$T/wt")"' "shellhook a search over the worktree: no objection"
  ;;
ocrender)   # Gate B fix cycle 1 (V1-02, V1-03, V1-11): the hook-less CLI's rendered rules
  OC=$(jq -r '[.entries[] | select(.policy and (.policy.hook | not)) | .id][0] // empty' "$AD"); ok '[ -n "$OC" ]' "ocrender precondition: an adapter with a policy part and no hook"
  run g P generate --adapter "$OC" --worktree "$T/wt" --json; ok '[ $RC = 0 ]' "ocrender generate (exit 0)"
  jq '.config.permission' "$T/o/g.out" >"$T/perm.json" 2>/dev/null
  # V1-02: every deny of the hand-written config before F3 (6a3b54b opencode.json) is still denied by the render, probed at word borders
  cat >"$T/old.json" <<'JSON'
{"bash": ["claude *--model *", "claude *--model=*", "claude *opusplan*", "claude *--dangerously-skip-permissions*", "claude *--allow-dangerously-skip-permissions*",
  "claude setup-token*", "claude -p*", "claude *-p *", "claude *--print*", "*owner.env*", "*/.env*", "* .env*", "*.pem*", "*/*.key*", "*.hermes/auth.json*",
  "*.claude/.credentials*", "*opencode/auth.json*", "*/.ssh/*", "*~/.ssh*", "*/.aws/*", "*~/.aws*", "*.config/gh*"],
 "edit": ["*owner.env*"],
 "read": ["*.env", "*.env.*", "*.pem", "*.key", "*/.hermes/auth.json", "*/.claude/.credentials*", "*/.local/share/opencode/auth.json", "*/.ssh/*", "*/.aws/*", "*/.config/gh/*"]}
JSON
  cat >"$T/cmp.py" <<'PY'
import json, re, sys
old, new = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
rx = lambda g: re.compile("".join(".*" if c == "*" else "." if c == "?" else re.escape(c) for c in g), re.S)
def denied(s, m):   # a deny matches and no allow does (whichever wins in the CLI, the probe is then denied)
    return any(rx(k).fullmatch(s) for k, v in m.items() if v == "deny") and not any(rx(k).fullmatch(s) for k, v in m.items() if v == "allow")
FILL = {"bash": (["", "cat /a/b/x"], "x", ["", " -n"]), "read": (["", "/a/b/x"], "x", ["x", "x/y"]), "edit": (["", "/a/b/x"], "x", ["x"])}
bad = []
for kind, pats in old.items():
    lead, mid, trail = FILL[kind]
    for p in pats:
        parts = p.split("*")
        for a in lead:
            for z in trail:
                s = (a if p.startswith("*") else "") + mid.join(parts[1 if p.startswith("*") else 0:len(parts) - (1 if p.endswith("*") and len(parts) > 1 else 0)]) + (z if p.endswith("*") else "")
                if not denied(s, new.get(kind) or {}):
                    bad.append(f"{kind} {p!r}: {s!r} not denied")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  run c python3 -I "$T/cmp.py" "$T/old.json" "$T/perm.json"; ok '[ $RC = 0 ]' "ocrender V1-02 every pre-F3 deny is still denied by the render (or a stricter one is present)"
  cat >"$T/ok.py" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1]))[sys.argv[2]]
rx = lambda g: re.compile("".join(".*" if c == "*" else "." if c == "?" else re.escape(c) for c in g), re.S)
d = lambda s: any(rx(k).fullmatch(s) for k, v in m.items() if v == "deny") and not any(rx(k).fullmatch(s) for k, v in m.items() if v == "allow")
want = sys.argv[3] == "deny"
bad = [s for s in sys.argv[4:] if d(s) != want]
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  run k python3 -I "$T/ok.py" "$T/perm.json" bash allow 'python3 -c "print(d.keys())"' 'jq .keywords f.json' 'cat src/x.keyboard.ts' 'node -e "console.log(process.env.HOME)"'
  ok '[ $RC = 0 ]' "ocrender V1-02 ordinary commands are not denied by the key or env rules (.keys(), .keywords, .keyboard, process.env)"
  run k2 python3 -I "$T/ok.py" "$T/perm.json" bash deny 'cat id.key' 'cat /a/server.key | x' 'cat .hermes/auth.json' 'cat x.pem' 'cat .claude/.credentials.json' 'cat share/opencode/auth.json'
  ok '[ $RC = 0 ]' "ocrender V1-02 real key files and relative secret paths are denied in the shell"
  run k3 python3 -I "$T/ok.py" "$T/perm.json" read deny 'app.env' '/w/x.env.local' '/w/id.key'; ok '[ $RC = 0 ]' "ocrender V1-02 *.env and *.env.* reads are denied"
  run k4 python3 -I "$T/ok.py" "$T/perm.json" read allow '/w/.env.example' '/w/.env.sample' '/w/.env.template'; ok '[ $RC = 0 ]' "ocrender V1-02 the example, sample and template names stay readable"
  run k6 python3 -I "$T/ok.py" "$T/perm.json" read allow '/w/cfg/app.example.env' '/w/app.env.example' '/w/x.sample.env'; ok '[ $RC = 0 ]' "ocrender fix 2: example env files of either spelling stay readable (app.example.env, app.env.example)"
  ok 'jq -e "[.rules[] | select(.kind == \"secret_read\") | .deny[] | select(test(\"^\\\\*\\\\.env\"))] | length == 0" "$PJ"' "ocrender fix 2: the file-only env globs are not in the shared deny list (the read guards and the box judge command words and folder binds with it)"
  # RT3-07: the hook-less CLI's own edit rules deny its project config in the worktree (OpenCode reads it above the generated config); the last matching pattern wins
  cat >"$T/rt307.py" <<'PY'
import fnmatch, json, sys
perm, wt = json.load(open(sys.argv[1])), sys.argv[2]
def verdict(table, path):
    v = None
    for pat, x in (table or {}).items():
        if fnmatch.fnmatchcase(path, pat):
            v = x
    return v
bad = [t for t in sys.argv[3:] if verdict(perm.get("edit"), wt + "/" + t) != "deny"]
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  run r307 python3 -I "$T/rt307.py" "$T/perm.json" "$T/wt" opencode.json opencode.jsonc .opencode/plugin/p.js .opencode/agent/a.md sub/opencode.json .claude/settings.local.json
  ok '[ $RC = 0 ]' "ocrender RT3-07 the render denies editing every CLI's project config in the worktree (opencode.json, .jsonc, .opencode/, .claude/settings*.json)"
  run r307b python3 -I "$T/ok.py" "$T/perm.json" bash deny 'echo {} > opencode.json' 'cp x .opencode/plugin/p.js' 'tee .claude/settings.local.json'
  ok '[ $RC = 0 ]' "ocrender RT3-07 the shell is denied commands naming a CLI's project config"
  # V1-03: external_directory allows the worktree and the run tmp, denies the rest
  ok 'jq -e --arg w "$T/wt" --arg t "$TMPDIR" ".external_directory | .[\"*\"] == \"deny\" and .[\$w] == \"allow\" and .[\$w + \"/*\"] == \"allow\" and .[\$t] == \"allow\" and .[\$t + \"/*\"] == \"allow\"" "$T/perm.json"' \
    "ocrender V1-03 external_directory: worktree and run tmp allowed, everything else denied"
  ok 'jq -e "[.rules[] | select(.kind == \"write_boundary\") | .writable[] | select(test(\"worktree\") | not)] | length == 1" "$PJ"' "ocrender V1-03 the write_boundary rule names the run tmp beside the worktree"
  # V1-11: every name of every CLI with model flags (npx and path forms too) is denied its model flags in each CLI's shell
  run k5 python3 -I "$T/ok.py" "$T/perm.json" bash deny 'claude-code --model x' 'npx @anthropic-ai/claude-code --model x' 'cd w && claude --model x' '/usr/bin/claude -p x' 'opencode run --model a/b x'
  ok '[ $RC = 0 ]' "ocrender V1-11 every name and invocation (npx, a path, after cd) of each CLI is denied its model flags"
  CC=$(jq -r '[.entries[] | select(.policy.hook) | .id][0] // empty' "$AD")
  run g2 P generate --adapter "$CC" --worktree "$T/wt" --json
  ok '[ $RC = 0 ] && grep >/dev/null -F "opencode *--model *" "$T/o/g2.out"' "ocrender V1-11 the hook CLI's config denies the other CLI's model flags"
  ok 'jq -e "[.entries[] | select(.policy) | .model_flags.deny_patterns | length > 0] | all" "$AD"' "ocrender V1-11 every adapter with a policy part has model flags"
  cp "$AD" "$T/ad.keep"; ed .stella/adapters.json --arg a "$OC" '(.entries[] | select(.id == $a)) |= del(.model_flags)'
  run c1 P check --json; ok '[ $RC = 1 ] && out c1 | grep >/dev/null "STL-GRD-611" && out c1 | grep >/dev/null -F "$OC"' "ocrender V1-11 an adapter with no model flags: model_limits has nothing to render for it, check fails (611)"
  cp "$T/ad.keep" "$AD"; ed .stella/adapters.json --arg a "$OC" '(.entries[] | select(.id == $a) | .policy.shapes.dispatcher_only[0].templates) = {"qa_no_such_set": ["x {command}"]}'
  run c2 P check --json; ok '[ $RC = 1 ] && out c2 | grep >/dev/null "STL-GRD-611"' "ocrender V1-11 a shape that renders nothing does not count as covering its kind (611)"
  cp "$T/ad.keep" "$AD"
  ;;
esac
finish
