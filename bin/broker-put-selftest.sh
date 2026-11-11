#!/usr/bin/env bash
# Hermetic self-test for bin/broker-put.sh (follow-up 4): a scratch Hermes root, stdin as the secret source, no real broker folder touched.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
B=/workspace/bin/broker-put.sh; TOK=canary-broker-put-token-AAAAAAAAAAAAAAAA
put() { printf '%s\n' "$2" | HERMES_ROOT=$T/root bash "$B" "$1" >"$T/out" 2>&1; }
ok 'put claude-reviewer "$TOK" && [ "$(cat "$T/root/broker/claude-reviewer")" = "$TOK" ]' "a token is stored as the named secret, without the newline"
ok '[ "$(stat -c %a "$T/root/broker/claude-reviewer")" = 600 ] && [ "$(stat -c %a "$T/root/broker")" = 700 ]' "the file is 0600 in a 0700 folder"
ok '! grep -q "$TOK" "$T/out"' "the token is never echoed"
ok '! put claude-reviewer "short" && [ "$(cat "$T/root/broker/claude-reviewer")" = "$TOK" ]' "a value that is not a token is refused and the stored one is kept"
ok '! put "../x" "$TOK" && ! put "Bad Name" "$TOK" && ! put "" "$TOK" && ! put "a..b" "$TOK" && [ ! -e "$T/root/x" ] && [ ! -e "$T/root/broker/a..b" ]' "bad names are refused"
ok '! put second "has spaces in the token xxxxxxxxxxxxxxxx" && [ ! -e "$T/root/broker/second" ]' "a value with spaces is refused"
ok 'ls "$T/root/broker" | grep -qv "^claude-reviewer$"; [ "$(ls -A "$T/root/broker" | wc -l)" = 1 ]' "no temp file is left behind"
# a failed run leaves no temp file with the token in it (a broker folder that cannot be renamed into: make the final name a directory)
mkdir -p "$T/root/broker/blocked"
ok '! put blocked "$TOK" && [ "$(ls -A "$T/root/broker" | grep -c "^\.put\.")" = 0 ]' "when the final move fails the temp file is removed"
# the box accepts exactly what this script writes
ok 'python3 -I -c "import sys; sys.path.insert(0, \"/workspace/bin\"); import box; assert box._broker(sys.argv[1], \"claude-reviewer\") == sys.argv[2]" "$T/root" "$TOK"' "bin/box.py _broker reads back what broker-put.sh wrote"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
