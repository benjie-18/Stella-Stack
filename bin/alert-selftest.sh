#!/usr/bin/env bash
# Hermetic self-test for the alert catalog and bin/alert.sh (D44): scratch HOME, HERMES_HOME, state and owner config,
# a stub hermes. Catalog valid with unique codes; every code used under bin/ and docs/ is catalogued, and every catalogued
# code is used or reserved; templates and recovery forms render; the three reference messages; no forbidden term in any
# rendered message; time zone fallbacks; unknown code and render failure still post; generated docs up to date.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sup" "$T/home" "$T/hermes"
cat > "$T/bin/hermes" <<'S'
#!/usr/bin/env bash
[ "$1" = send ] || exit 0
shift; printf '%s\n' "$*" >> "$ESCALATE_SUP_DIR/sends"
S
chmod +x "$T/bin/hermes"
export PATH="$T/bin:$PATH" HOME="$T/home" HERMES_HOME="$T/hermes" ESCALATE_SUP_DIR="$T/sup" OWNER_CONFIG="$T/owner.env" \
  TZ=America/Toronto ALERT_TARGET="stub:#alerts" LC_ALL=C.UTF-8
[ "$(command -v hermes)" = "$T/bin/hermes" ] || { echo "FAIL hermes is not the stub; refusing to run"; echo "selftest FAIL"; exit 1; }
B=/workspace/bin C="python3 -I $B/alert_catalog.py" fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
FORBIDDEN='exit [0-9]|exit code|rc=|urlopen|Traceback|\.sh\b|[Hh]ermes|ai-stack|[0-9]{15,}|poller|flock|ipset|hook'
codes=$($C codes | cut -f1)

ok '$C validate >/dev/null' "catalog: valid JSON, every field present, codes STL-<area>-<nnn> and unique, titles under 60"
ok '[ "$(jq -r ".alerts[].code" /workspace/docs/hermes-local/alert-catalog.json | sort | uniq -d)" = "" ]' "catalog: no duplicate code"
used=$(grep -rhoE 'STL-[A-Z]+-[0-9]{3}' "$B" /workspace/docs --include='*.sh' --include='*.py' --include='*.ps1' --include='*.md' \
  --exclude=alert-codes.md --exclude=alert-selftest.sh | sort -u)
missing=$(comm -23 <(printf '%s\n' "$used") <(printf '%s\n' "$codes" | sort -u))
ok '[ -z "$missing" ]' "every code used under bin/ and docs/ is in the catalog${missing:+ (missing: $(echo $missing))}"
unused=""
for c in $codes; do
  [ "$($C codes | awk -F'\t' -v c="$c" '$1 == c { print $2 }')" = reserved ] && continue
  grep -rqF --include='*.sh' --include='*.py' --include='*.ps1' --exclude='*selftest*' --exclude=alert_catalog.py \
    -- "$c" "$B" /workspace/docs/hermes-local/hooks /workspace/docs/stella-recover.ps1 || unused="$unused $c"
done
ok '[ -z "$unused" ]' "every catalog code is used by a sender or marked reserved${unused:+ (unused:$unused)}"

# Every entry, normal and recovery form, with sample values: placeholders filled, nothing forbidden.
bad="" bad_resolved=""
for c in $codes; do
  out=$($C sample "$c")
  { [ -n "$out" ] && ! grep -qE '[{}]|unknown' <<<"$out" && grep -qF "[$c]**" <<<"$out" && grep -q "(sample)" <<<"$out" \
    && ! grep -qE "$FORBIDDEN" <<<"$out" && [ "$(wc -l <<<"$out")" -le 4 ]; } || bad="$bad $c"
  r=$($C render "$c" resolved=1 commit=abc1234 since=2026-10-28T13:00:00Z now=2026-10-28T13:20:00Z)
  if [ "$(jq -r --arg c "$c" '.alerts[] | select(.code == $c) | .resolvable' /workspace/docs/hermes-local/alert-catalog.json)" = true ]; then
    { head -1 <<<"$r" | grep -q "^✅ Stella: .*\*\*\[$c resolved\]\*\*$" && grep -q "from 09:00 to 09:20" <<<"$r" \
      && ! grep -qE "$FORBIDDEN|[{}]" <<<"$r"; } || bad_resolved="$bad_resolved $c"
  else
    grep -q "resolved\]" <<<"$r" && bad_resolved="$bad_resolved $c"
  fi
done
ok '[ -z "$bad" ]' "every template renders with its placeholders, code in bold, no forbidden term, at most 4 lines${bad:+ (bad:$bad)}"
ok '[ -z "$bad_resolved" ]' "the recovery form renders for resolvable codes only${bad_resolved:+ (bad:$bad_resolved)}"

# The three reference messages (target shape), from the raw inputs the scripts have.
w=$($C render STL-WDG-101 check="test run" commit=bcbcb92b8ef9aa51 failed="test (exit 1)" since=2026-10-28T13:15:01Z)
ok '[ "$(head -1 <<<"$w")" = "⚠️ Stella: self-check is failing  **[STL-WDG-101]**" ] && grep -q "test run failed on the latest version of the stack (commit bcbcb92)\." <<<"$w" && grep -q "^What to do: ask Claude Code to run the tests" <<<"$w" && [ "$(tail -1 <<<"$w")" = "First seen 09:15" ] && ! grep -qE "$FORBIDDEN" <<<"$w"' "reference: watchdog failure (commit cut to 7, local time without seconds, no exit code)"
e=$($C render STL-ESC-210 card=t_fbfdaf63 count=3 thread=1200000000000000529 since=2026-10-28T15:35:40Z \
  error="Unexpected error: <urlopen error [SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol (_ssl.c:1006)>")
ok '[ "$(head -1 <<<"$e")" = "⚠️ Stella: can'"'"'t read replies in an escalation thread  **[STL-ESC-210]**" ] && grep -q "tried 3 times in a row and could not read the thread for card t_fbfdaf63 (a network problem" <<<"$e" && grep -q "STL-ESC-210 in docs/alert-codes.md" <<<"$e" && [ "$(tail -1 <<<"$e")" = "First seen 11:35" ] && ! grep -qE "$FORBIDDEN|SSL" <<<"$e"' "reference: thread read failure (plain error phrase, no thread id, no SSL text)"
r=$($C render STL-WDG-101 resolved=1 commit=bcbcb92 since=2026-10-28T13:17:09Z now=2026-10-28T13:32:00Z)
ok '[ "$r" = "✅ Stella: self-check is passing again  **[STL-WDG-101 resolved]**
The automatic checks pass again on commit bcbcb92. They were failing from 09:17 to 09:32." ]' "reference: recovery message (two lines, from and to in local time)"
n=$(wc -l <"$T/sup/logs/alerts.log"); pv=$($C preview STL-WDG-101 check="test run" since=2026-10-28T13:15:01Z)
ok '[ "$(wc -l <"$T/sup/logs/alerts.log")" = "$n" ] && [ "$pv" = "$($C render STL-WDG-101 check="test run" since=2026-10-28T13:15:01Z)" ]' "preview: the same body as render, and nothing reaches alerts.log"
ok 'grep -q "^STL-ESC-210 20[0-9-]*T[0-9:]*Z .*thread=.1200000000000000529.*UNEXPECTED_EOF_WHILE_READING" "$T/sup/logs/alerts.log"' "the raw detail (thread id, SSL error) is in alerts.log, code first: grep STL-ESC-210 finds it"

# STL-RCV-504 {parts} (QB2-4): each failure token has a phrase; an unknown token renders safely; no forbidden term.
cat504=$(jq -r '.alerts[] | select(.code == "STL-RCV-504") | .parts | keys[] | select(. != "_other")' /workspace/docs/hermes-local/alert-catalog.json)
bad_parts=""
for t in $cat504; do
  r=$($C render STL-RCV-504 parts="$t"); ph=$(jq -r --arg t "$t" '.alerts[] | select(.code == "STL-RCV-504") | .parts[$t]' /workspace/docs/hermes-local/alert-catalog.json)
  { grep -qF -- "Found: $ph." <<<"$r" && ! grep -qE "$FORBIDDEN|[{}]" <<<"$r"; } || bad_parts="$bad_parts $t"
done
ok '[ -n "$cat504" ] && [ -z "$bad_parts" ]' "STL-RCV-504: every token maps to its own phrase, with no forbidden term${bad_parts:+ (bad:$bad_parts)}"
u=$($C render STL-RCV-504 'parts=zzz,ssh;rm -rf,ssh')
ok 'grep -q "Found: secure remote connections are open to servers other than GitHub; another problem that this message does not describe yet\\." <<<"$u" && ! grep -qE "zzz|rm -rf" <<<"$u"' "STL-RCV-504: an unknown token renders as a plain phrase and is never echoed"
a=$($C render STL-RCV-504 "parts=$(echo $cat504 | tr ' ' ,)")
ok '! grep -qE "$FORBIDDEN|[{}]" <<<"$a" && [ "$(wc -c <<<"$a")" -lt 1800 ]' "STL-RCV-504: all tokens at once: no forbidden term, under the length cut"
ok 'grep -q "Found: unknown\\." <<<"$($C render STL-RCV-504)"' "STL-RCV-504: no parts= given still renders"

# Error classification: the plain phrase, never the raw text.
cl() { $C classify "$1"; }
ok '[ "$(cl "<urlopen error [Errno -3] Temporary failure in name resolution>")" = "a network or DNS problem reaching Discord" ] && [ "$(cl "Discord API error 429: You are being rate limited")" = "Discord is rate-limiting Stella" ] && [ "$(cl "Discord API error 403: Missing Access")" = "Discord refused the request: missing permission or a missing channel" ] && [ "$(cl "Discord API error 502: Bad Gateway")" = "Discord had a server error" ] && [ "$(cl "[Errno 28] No space left on device")" = "a disk or permissions problem" ] && [ "$(cl "hermes send to thread 5 failed")" = "a local command failed" ] && [ "$(cl "something odd")" = "an unknown problem" ]' "classifier: network, rate limit, refused, server error, disk, local command, unknown"

# Time zone: OWNER_TIMEZONE, then TZ, then UTC with the label; a missing or broken owner config never breaks rendering.
printf "OWNER_NAME='owner'\nOWNER_TIMEZONE='Asia/Tokyo'\n" > "$T/owner.env"
ok '[ "$($C render STL-WDG-101 since=2026-10-28T13:15:00Z | tail -1)" = "First seen 22:15" ]' "time zone: OWNER_TIMEZONE wins (even in an otherwise incomplete owner config)"
rm -f "$T/owner.env"
ok '[ "$(TZ= $C render STL-CFG-301 since=2026-10-28T13:15:00Z | tail -1)" = "First seen 13:15 UTC" ] && [ "$(TZ=Not/AZone $C render STL-CFG-301 since=1793193300 | tail -1)" = "First seen 13:15 UTC" ]' "time zone: no owner config and no or a bad TZ: UTC, labelled (epoch input too)"
printf 'garbage line\n' > "$T/owner.env"
ok '[ "$($C render STL-CFG-301 since=2026-10-28T13:15:00Z error="x" | tail -1)" = "First seen 09:15" ]' "time zone: an unreadable owner config falls back to the container TZ"
rm -f "$T/owner.env"

# Sending: unknown code, broken catalog, failed renderer, sample, length cut, cron PATH.
. "$B/alert.sh"
: > "$T/sup/sends"
stella_alert "STL-ZZZ-""999" card=t_00000001 summary="Plain summary from the caller."
ok 'grep -q "^--to stub:#alerts --quiet ⚠️ Stella: something needs a look  \*\*\[STL-GEN-000\]\*\*$" "$T/sup/sends" && grep -q "Plain summary from the caller" "$T/sup/sends" && grep -q "^STL-GEN-000 .* requested=.STL-ZZZ-999" "$T/sup/logs/alerts.log"' "an unknown code still posts, as STL-GEN-000 with the caller's summary, and is logged"
: > "$T/sup/sends"; ALERT_CATALOG=/nonexistent stella_alert STL-WDG-101 commit=abc
ok 'grep -q "STL-GEN-000" "$T/sup/sends" && grep -q "catalog_error=" "$T/sup/logs/alerts.log"' "an unreadable catalog still posts (STL-GEN-000) and logs why"
: > "$T/sup/sends"; ( ALERT_BIN=/nonexistent; stella_alert STL-WDG-101 commit=abc ); rc=$?
ok '[ "$rc" = 0 ] && grep -q "\[STL-GEN-000\]" "$T/sup/sends" && grep -q "(STL-WDG-101)" "$T/sup/sends"' "a failed renderer never blocks the caller: last-resort text with the code asked for"
: > "$T/sup/sends"; "$B/alert.sh" --sample STL-ESC-210
ok 'grep -q "^--to stub:#alerts --quiet ⚠️ Stella: can.t read replies in an escalation thread (sample)  \*\*\[STL-ESC-210\]\*\*$" "$T/sup/sends"' "alert.sh --sample posts the sample, marked (sample), through hermes send (stub here)"
: > "$T/sup/sends"; "$B/alert.sh" STL-RCV-502 restarted="container started" last_ok=2026-10-29T04:50:00Z now=2026-10-29T04:52:30Z
ok 'grep -q "\[STL-RCV-502\]" "$T/sup/sends" && grep -qE "At [0-9]{2}:52[^ ]* the Windows recovery script found part of Stella not running and started it again: container started. Her last healthy check was at [0-9]{2}:50" "$T/sup/sends" && ! grep -qi "down for" "$T/sup/sends" && ! grep -q "was down and restarted" "$T/sup/sends"' "alert.sh <CODE> key=value (the Windows recovery call) renders and sends; D46: times, not a claimed outage length"
: > "$T/sup/sends"; "$B/alert.sh" STL-RCV-503 restarted="container started" failing="ollama"
ok 'grep -q "Her last healthy check was at an unknown time (none recorded yet). Still not working: ollama" "$T/sup/sends"' "STL-RCV-503 with no healthy check recorded yet: says so in plain words"
# K10 wording: STL-ESC-210 has a recovery form (naming the card, from/to in local time), STL-GW-103 a state_stale phrase,
# and the recovery script's messages no longer claim Stella "was down".
CAT=/workspace/docs/hermes-local/alert-catalog.json
e=$($C render STL-ESC-210 resolved=1 card=t_fbfdaf63 thread=1200000000000000529 since=2026-10-28T15:35:40Z now=2026-10-28T15:50:10Z)
ok '[ "$(head -1 <<<"$e")" = "✅ Stella: replies in an escalation thread are read again  **[STL-ESC-210 resolved]**" ] && grep -q "Stella can read the thread for card t_fbfdaf63 again\. It could not from 11:35 to 11:50" <<<"$e" && ! grep -qE "$FORBIDDEN|[{}]|unknown|1200000" <<<"$e"' "K10: STL-ESC-210 resolved form: names the card, from/to in local time, no leftover placeholder, no thread id, no forbidden term"
ok 'jq -e ".alerts[] | select(.code == \"STL-ESC-210\") | .resolvable == true and (.resolved_title | length > 0) and (.resolved_message | contains(\"{card}\") and contains(\"{since}\") and contains(\"{now}\"))" $CAT >/dev/null' "K10: STL-ESC-210 is resolvable, with a resolved title and message using {card}, {since} and {now}"
ok '$C codes | awk -F"\t" "\$1 == \"STL-ESC-210\"" | grep -vq reserved' "K10: STL-ESC-210 is a live code, not reserved"
g=$($C render STL-GW-103 parts=state_stale since=2026-10-28T13:00:00Z)
ok 'grep -q "her program is running and her log says connected, but she stopped updating her own status, so she may be stuck" <<<"$g" && ! grep -qE "$FORBIDDEN|[{}]|something the check could not name" <<<"$g"' "K10: STL-GW-103 with parts=state_stale says why, in plain words (not the generic phrase)"
ok 'jq -e ".alerts[] | select(.code == \"STL-GW-103\") | .parts | has(\"state_stale\")" $CAT >/dev/null' "K10: STL-GW-103 has the state_stale parts token"
ok '! grep -qi "wrong with the check" <<<"$g" && grep -q "does not prove that Stella is down" <<<"$g"' "B2V-06: STL-GW-103 state_stale does not blame the check while saying she may be stuck"
gr=$($C render STL-GW-103 resolved=1 parts=quiet since=2026-10-28T13:00:00Z now=2026-10-28T13:20:00Z)
ok '[ "$(head -1 <<<"$gr")" = "✅ Stella: the check can tell again  **[STL-GW-103 resolved]**" ] && grep -q "from 09:00 to 09:20" <<<"$gr" && ! grep -qE "$FORBIDDEN|[{}]" <<<"$gr"' "K10: STL-GW-103 resolved form still renders"
r3=$($C render STL-RCV-503 restarted="container started" last_ok=2026-10-29T04:50:00Z now=2026-10-29T04:52:30Z failing="ollama")
ok 'grep -qE "At [0-9]{2}:52[^ ]* the Windows recovery script found part of Stella not running and started it again: container started\. Her last healthy check was at [0-9]{2}:50[^ ]*\. Still not working: ollama" <<<"$r3" && ! grep -qE "was down|noticed at|$FORBIDDEN|[{}]" <<<"$r3"' "K10: STL-RCV-503 new wording: found part of Stella not running and started it again; no \"was down and restarted\""
ok '! jq -e "[.alerts[].message] | any(test(\"was down and restarted|was down for\"))" $CAT >/dev/null' "K10: no catalog message says Stella \"was down and restarted\" / \"was down for\" (D46: times, not a claimed outage)"
# K4: STL-MDL-701 explains each cause the model watch can name, in plain words, and an unnamed token renders safely.
mdl_bad=""
for tok in unreachable not_loaded other_loaded loaded unknown; do
  m=$($C render STL-MDL-701 card=t_14f8f08b count=7 minutes=30 parts=$tok error="http://127.0.0.1:11434: URLError" since=2026-10-28T13:00:00Z)
  { grep -q "Card t_14f8f08b's worker has had 7 failed model calls in the last 30 minutes" <<<"$m" && ! grep -qE "$FORBIDDEN|[{}]|127\.0\.0\.1" <<<"$m"; } || mdl_bad="$mdl_bad $tok"
  case $tok in unreachable) grep -q "does not answer" <<<"$m";; not_loaded) grep -q "no model is loaded" <<<"$m";; other_loaded) grep -q "another model is loaded" <<<"$m";; loaded) grep -q "the worker's model is loaded" <<<"$m";; *) grep -q "could not tell why" <<<"$m";; esac || mdl_bad="$mdl_bad $tok(text)"
done
ok '[ -z "$mdl_bad" ]' "K4: STL-MDL-701 renders each parts token (unreachable, not_loaded, other_loaded, loaded, unknown) with its own phrase, no forbidden term, no server address${mdl_bad:+ (bad:$mdl_bad)}"
m=$($C render STL-MDL-701 card=t_14f8f08b count=3 minutes=30 parts=zz_new_token since=2026-10-28T13:00:00Z)
ok 'grep -q "could not tell why" <<<"$m" && ! grep -qE "[{}]|zz_new_token" <<<"$m"' "K4: an unknown parts token renders the generic phrase"
mr=$($C render STL-MDL-701 resolved=1 card=t_14f8f08b since=2026-10-28T13:00:00Z now=2026-10-28T13:40:00Z)
ok '[ "$(head -1 <<<"$mr")" = "✅ Stella: a worker'"'"'s model calls work again  **[STL-MDL-701 resolved]**" ] && grep -q "Card t_14f8f08b.s worker gets model answers again, or the card stopped running\. The problem lasted from 09:00 to 09:40" <<<"$mr" && ! grep -qE "$FORBIDDEN|[{}]" <<<"$mr"' "K4: STL-MDL-701 resolved form names the card, from/to in local time"
printf '{"alerts": [{"code": "STL-GEN-000", "area": "GEN", "severity": "info", "title": "t", "message": "%s{summary}", "action": "a", "cause": "c", "check": "k", "related": "r", "resolvable": false}]}' "$(printf 'x%.0s' $(seq 1 1900))" > "$T/cat.json"
ok '[ "$(ALERT_CATALOG="$T/cat.json" alert_text STL-GEN-000 | wc -m)" -le 1801 ]' "the rendered body is cut at 1800 characters (ALERT_CATALOG override)"
ok '[ "$(env -i PATH=/usr/bin:/bin ESCALATE_SUP_DIR="$T/sup" OWNER_CONFIG=/nonexistent bash -c ". $B/alert.sh; alert_text STL-WDG-101 commit=abc1234 check=build" | head -1)" = "⚠️ Stella: self-check is failing  **[STL-WDG-101]**" ]' "renders under cron's minimal PATH and environment (no TZ: UTC)"
ok '[ "$(grep -c "" "$B/alert.sh")" -gt 0 ] && ! grep -q "/workspace" "$B/alert.sh" "$B/alert_catalog.py"' "alert.sh and alert_catalog.py find the catalog from their own location (no hard-coded /workspace)"

# Transports and mentions unchanged (D44 changes only the message body).
ok 'grep -qF "\"allowed_mentions\": {\"parse\": []}" "$B/escalation-discord.sh" && grep -qF "hermes send --to \"\${ALERT_TARGET:-discord:#alerts}\" --quiet" "$B/escalation-discord.sh" && grep -qF "hermes send --to \"\${ALERT_TARGET:-discord:#alerts}\" --quiet \"\$(alert_text" "$B/alert.sh"' "transports: REST keeps allowed_mentions parse [], alerts still go by hermes send to ALERT_TARGET"
ok 'grep -qF "send() { hermes send --to \"\$ALERT_TARGET\" --quiet \"\$1\" >>\"\$LOG\" 2>&1 || { sleep 3; hermes send --to \"\$ALERT_TARGET\" --quiet \"\$1\" >>\"\$LOG\" 2>&1; }; }" "$B/watchdog.sh" && grep -qF "hermes send --to \"\$ALERT_TARGET\" --quiet \"\$(alert_text STL-LIM-40" "$B/escalate.sh" && grep -qF "hermes send --to \"\${ALERT_TARGET:-discord:#alerts}\" --quiet \"\$(alert_text STL-CFG-301" "$B/owner-config.sh"' "transports: watchdog send() with its retry, escalate.sh and owner-config.sh hermes send lines kept"

# Generated docs and the terminal explainer.
ok '"$B/alert-catalog.sh" --check >/dev/null 2>&1' "docs/alert-codes.md is generated from the catalog and up to date"
ok '"$B/alert-explain.sh" STL-ESC-210 | grep -q "^Means    Stella tried {count} times" && ! "$B/alert-explain.sh" "STL-ZZZ-""999" >/dev/null && ! "$B/alert-explain.sh" "x; ls" >/dev/null 2>&1' "alert-explain.sh prints an entry; an unknown code or other text fails"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
