#!/usr/bin/env bash
# Hermetic self-test for the prompt profiles (F3 item PP; body B9, B4 line, AC9 profile switch; design section 6).
# Every section runs in its own scratch root (bash prompt-selftest.sh <section>); no argument runs them all.
# Sections -> checks: switch = AC9-profile-switch | order = T-PROMPT-ORDER | line = T-PROMPT-LINE
# A fake connection with two models of two fake families and two fake profiles (one tag style with a parallel-tools line, one
# heading style without) are added as DATA; nothing in bin/ changes during the test.
# Written test-first (F3 wave 1): exit codes, the code range STL-CFG-330..339 and the rendered text are asserted, never wording.
# ASSUMPTIONS (names the design leaves open):
#  A1 .stella/prompt-profiles.json: profiles[] objects with id, section_template ({name}, {body} placeholders), order[] (section
#     names), parallel_tools_line (text|null) and the other fields of section 6; family_map {family: profile id}; role_overrides
#     {role: profile id}; default. New profiles are made by copying the default one and changing these fields.
#  A2 a model's family is the "family" field of its catalog model entry (connections.json models[]).
#  A3 render --json output: the chosen profile id is a string value of the output; the rendered prompt is its longest string value.
#  A4 the capability prompt line is the value of a key capability_prompt_line in one of the .stella data files.
#  A5 every section is rendered, the question section included (it may be empty), so the last section marker is the question's.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ME=prompt-selftest
SECTIONS="switch order line"
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

PR() { python3 -I "$R/bin/prompt.py" "$@"; }
PF=$R/.stella/prompt-profiles.json
mdl() { echo "{\"id\":\"$1\",\"family\":\"$2\",\"capabilities\":{\"tool_calling\":true,\"json_mode\":true,\"context_tokens\":100000,\"vision\":false,\"streaming\":true},\"probed_at\":null,\"probe_source\":\"advertised\",\"cost\":null,\"limits\":null}"; }
TPL='[.entries[] | select(.kind == "provider" and .type == "api" and .locality == "cloud" and (.aggregator | not))][0]'
ed .stella/connections.json --argjson m "[$(mdl qa-pm1 qa-fam-a),$(mdl qa-pm2 qa-fam-b)]" --arg g "$(uuid)" ".entries += [$TPL + {id: \"qa-pp\", label: \"qa-pp\", enabled: true, global_id: \$g, models: \$m, secrets: []}]"
ed .stella/prompt-profiles.json --arg g1 "$(uuid)" --arg g2 "$(uuid)" --arg i "$IID" \
  '(.default) as $d | ([.profiles[] | select(.id == $d)][0] // .profiles[0]) as $p
   | .profiles += [$p + {id: "qa-tags", section_template: "@@{name}@@\n{body}\n@@/{name}@@", parallel_tools_line: "QA-PARALLEL-LINE", global_id: $g1, install_id: $i},
                   $p + {id: "qa-md", section_template: "##QA {name}\n\n{body}", parallel_tools_line: null, global_id: $g2, install_id: $i}]
   | .family_map["qa-fam-a"] = "qa-tags" | .family_map["qa-fam-b"] = "qa-md"'
ok '[ -f "$PF" ] && python3 -I "$R/bin/stella_data.py" check' "precondition: prompt-profiles.json exists and the scratch data (fake families and profiles) passes check"
printf 'QA-BRIEF-CANARY: make the zebra test pass.\n' >"$T/brief.md"
ROLE=$(jq -r '.roles | keys[0]' "$RJ")
# rend <tag> <role> <link> [more args]: render; the prompt text (longest string of the JSON) in $T/o/<tag>.txt
rend() { local t=$1; run "$t" PR render --role "$2" --link "$3" --brief "$T/brief.md" "${@:4}" --json
  jq -r '[.. | strings] | max_by(length) // ""' "$T/o/$t.out" >"$T/o/$t.txt" 2>/dev/null; }
prof() { [ -s "$T/o/$1.out" ] && jq -e --arg p "$2" '[.. | strings] | index($p) != null' "$T/o/$1.out" >/dev/null 2>&1; }

case $S in
switch)   # AC9-profile-switch: a data change only
  BIN0=$(cd "$R/bin" && find . -type f ! -name '*.pyc' -exec sha256sum {} + | sort | sha256sum)
  rend s1 "$ROLE" qa-pp/qa-pm1
  ok '[ $RC = 0 ] && prof s1 qa-tags && grep -q "^@@" "$T/o/s1.txt"' "AC9-profile-switch the family map picks qa-tags for family qa-fam-a: output records it and the text is in its form"
  ed .stella/prompt-profiles.json --arg r "$ROLE" '.role_overrides[$r] = "qa-md"'
  rend s2 "$ROLE" qa-pp/qa-pm1
  ok '[ $RC = 0 ] && prof s2 qa-md && ! prof s2 qa-tags && grep -q "^##QA " "$T/o/s2.txt" && ! grep -q "^@@" "$T/o/s2.txt"' "AC9-profile-switch a role override in the data switches the role to qa-md, same model"
  ed .stella/prompt-profiles.json --arg r "$ROLE" 'del(.role_overrides[$r]) | .family_map["qa-fam-a"] = "qa-md"'
  rend s3 "$ROLE" qa-pp/qa-pm1
  ok '[ $RC = 0 ] && prof s3 qa-md && grep -q "^##QA " "$T/o/s3.txt"' "AC9-profile-switch a family map change in the data switches every role of that family"
  rend s4 "$ROLE" qa-pp/qa-pm1 --profile qa-tags
  ok '[ $RC = 0 ] && prof s4 qa-tags' "AC9-profile-switch --profile names a profile explicitly"
  ed .stella/prompt-profiles.json --arg r "$ROLE" '.role_overrides[$r] = "qa-no-such-profile"'
  rend s5 "$ROLE" qa-pp/qa-pm1
  ok '[ $RC = 1 ] && out s5 | grep >/dev/null -E "STL-CFG-33[0-9]"' "AC9-profile-switch a role override naming no profile fails closed with STL-CFG-33x"
  ok '[ "$(cd "$R/bin" && find . -type f ! -name "*.pyc" -exec sha256sum {} + | sort | sha256sum)" = "$BIN0" ]' "AC9-profile-switch no code changed: bin/ is byte-identical"
  ;;
order)   # T-PROMPT-ORDER: evidence first, question last, the family's parallel-tools line
  ok '[ -s "$PF" ] && jq -e "[.profiles[] | (.order[0] | test(\"evidence|context\")) and (.order[-1] | test(\"question\"))] | all and length > 0" "$PF"' "T-PROMPT-ORDER every profile's order starts with evidence/context and ends with the question"
  rend o1 "$ROLE" qa-pp/qa-pm1
  grep -oE '^@@[^/@][^@]*@@$' "$T/o/o1.txt" | sed 's/@@//g' >"$T/o/o1.seq"
  jq -r '.profiles[] | select(.id == "qa-tags") | .order[]' "$PF" >"$T/o/order" 2>/dev/null
  subseq() { awk 'NR == FNR { o[NR] = $0; n = NR; next } { while (i < n && o[++i] != $0) {} if (o[i] != $0) bad = 1 } END { exit bad || FNR == 0 }' "$T/o/order" "$T/o/o1.seq"; }
  ok '[ $RC = 0 ] && [ -s "$T/o/o1.seq" ] && subseq' "T-PROMPT-ORDER the rendered sections follow the profile's order"
  ok '[ "$(tail -n1 "$T/o/o1.seq")" = "$(tail -n1 "$T/o/order")" ] && [ "$(tail -n1 "$T/o/o1.seq")" != "" ]' "T-PROMPT-ORDER the question section is the last one rendered"
  bl=$(grep -n QA-BRIEF-CANARY "$T/o/o1.txt" | head -n1 | cut -d: -f1); ql=$(grep -n "^@@$(tail -n1 "$T/o/order")@@$" "$T/o/o1.txt" | head -n1 | cut -d: -f1)
  ok '[ -n "$bl" ] && [ -n "$ql" ] && [ "$bl" -lt "$ql" ]' "T-PROMPT-ORDER the card brief comes before the question"
  ok 'grep -qF QA-PARALLEL-LINE "$T/o/o1.txt"' "T-PROMPT-ORDER a family whose profile has a parallel-tools line gets it"
  rend o2 "$ROLE" qa-pp/qa-pm2
  ok '[ $RC = 0 ] && prof o2 qa-md && ! grep -qF QA-PARALLEL-LINE "$T/o/o2.txt"' "T-PROMPT-ORDER a family whose profile has none (null) gets no such line"
  ;;
line)   # T-PROMPT-LINE: every role prompt carries the capability-search line from data
  LF=$(cd "$R/.stella" && grep -l '"capability_prompt_line"' *.json 2>/dev/null | head -n1)
  LINE=$(jq -r '[.. | objects | .capability_prompt_line? // empty | strings][0] // empty' "$R/.stella/${LF:-none}" 2>/dev/null)
  ok '[ -n "$LINE" ]' "T-PROMPT-LINE the capability prompt line is data (capability_prompt_line in ${LF:-no .stella file})"
  miss=; for r in $(jq -r '.roles | keys[]' "$RJ"); do rend "l-$r" "$r" qa-pp/qa-pm1; [ $RC = 0 ] && grep -qF -- "$LINE" "$T/o/l-$r.txt" || miss="$miss $r"; done
  ok '[ -n "$LINE" ] && [ -z "$miss" ]' "T-PROMPT-LINE every role's rendered prompt carries it (missing:$miss)"
  NEW="QA-CAP-LINE-$RANDOM: search capabilities first."
  [ -n "$LF" ] && ed ".stella/$LF" --arg n "$NEW" '(.. | objects | select(has("capability_prompt_line")) | .capability_prompt_line) |= $n'
  miss=; for r in $(jq -r '.roles | keys[]' "$RJ"); do rend "m-$r" "$r" qa-pp/qa-pm2; [ $RC = 0 ] && grep -qF -- "$NEW" "$T/o/m-$r.txt" && ! grep -qF -- "$LINE" "$T/o/m-$r.txt" || miss="$miss $r"; done
  ok '[ -n "$LF" ] && [ -z "$miss" ]' "T-PROMPT-LINE a data change of the line reaches every role's prompt, in every profile (missing:$miss)"
  ;;
esac
finish
