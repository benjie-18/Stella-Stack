#!/usr/bin/env bash
# Hermetic self-test for the firewall probe in docs/stella-recover.ps1 (QB2-4, step 3 of the Windows recovery script).
# The probe is extracted from between its marker comments and run with `sh -c` against stub iptables, ip6tables and ipset.
# The passing ruleset is not hand-written: it is what .devcontainer/init-firewall.sh records when run under the stubs of
# init-firewall-selftest.sh (reused, not copied), so the two cannot drift. Each broken ruleset must fail with its own token.
set -u
B=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PS1=$B/../docs/stella-recover.ps1
FWT=$B/init-firewall-selftest.sh
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
done_() { [ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }; }

# The stub environment of init-firewall-selftest.sh: everything before its `fails=0` line (sets $T, the stubs, fw.sh).
setup=$(sed -n '1,/^fails=0$/p' "$FWT")
if ! grep -qx 'fails=0' <<<"$setup"; then echo "FAIL init-firewall-selftest.sh has no 'fails=0' line to reuse its stubs from"; fails=1; done_; fi
eval "$setup"
: > "$T/calls"
PATH="$T/bin:$PATH" bash "$T/fw.sh" > "$T/out" 2>&1
ok 'grep -q "Firewall configuration complete" "$T/out"' "init-firewall.sh completes under the stubs (the source of the passing ruleset)"

# Recorded calls -> `<tool> -S` output: policies, then the -A rules still standing after the -D lines.
ruleset() { awk -v tool="$1" '
  $1 == tool && ($2 == "-P" || $2 == "-A" || $2 == "-D") {
    line = $0; sub("^" tool " ", "", line)
    if ($2 == "-P") pol[$3] = $4
    else if ($2 == "-A") rules[++n] = line
    else { want = "-A" substr(line, 3); for (i = 1; i <= n; i++) if (rules[i] == want) { rules[i] = ""; break } }
  }
  END { split("INPUT FORWARD OUTPUT", chains, " "); for (i = 1; i <= 3; i++) if (chains[i] in pol) print "-P " chains[i] " " pol[chains[i]]
        for (i = 1; i <= n; i++) if (rules[i] != "") print rules[i] }' "$T/calls"; }
P=$T/p; mkdir -p "$P/bin"
ruleset iptables > "$P/ipt.base"; ruleset ip6tables > "$P/ip6t.base"
awk '$1 == "ipset" && $2 == "create" {print $3}' "$T/calls" > "$P/sets.base"
for t in grep tail; do ln -s "$(command -v $t)" "$P/bin/$t"; done
for pair in iptables:ipt ip6tables:ip6t ipset:sets; do   # the stubs print the canned file whatever their arguments
  printf '#!/bin/sh\n/bin/cat %s/%s\n' "$P" "${pair#*:}" > "$P/bin/${pair%%:*}"; chmod +x "$P/bin/${pair%%:*}"
done
ok '[ "$(grep -c "" "$P/ipt.base")" -ge 8 ] && grep -qx -- "-P OUTPUT DROP" "$P/ipt.base" && grep -q "allowed-domains dst -j ACCEPT" "$P/ipt.base" && ! grep -q "140.82.112.0/20" "$P/ipt.base" && [ "$(grep -c "" "$P/sets.base")" = 2 ]' "the canned ruleset comes from the recorded calls (temporary GitHub rule deleted, both sets created)"

# The probe: the lines of the here-string between the marker comments, joined with spaces exactly as the script does.
probe=$(sed -n '/^# FIREWALL-PROBE-BEGIN/,/^# FIREWALL-PROBE-END/p' "$PS1" | sed -n "/@'\$/,/^'@/p" | sed '1d;$d' | sed 's/^[[:space:]]*//' | grep -v '^$' | tr '\n' ' ')
ok '[ "$(grep -c "^# FIREWALL-PROBE-BEGIN" "$PS1")" = 1 ] && [ "$(grep -c "^# FIREWALL-PROBE-END" "$PS1")" = 1 ] && [ -n "$probe" ]' "the probe sits once between FIREWALL-PROBE-BEGIN and FIREWALL-PROBE-END"

use() { cp "$P/ipt.base" "$P/ipt"; cp "$P/ip6t.base" "$P/ip6t"; cp "$P/sets.base" "$P/sets"; }
ins() { awk -v r="$1" '/^-A OUTPUT/ && !d {print r; d=1} {print}' "$P/ipt" > "$P/x" && mv "$P/x" "$P/ipt"; }   # like iptables -I OUTPUT 1
runp() { out=$(env -i PATH="$P/bin" /bin/sh -c "$probe" 2>&1); rc=$?; }
expect() {   # expect <exact output, "" = pass> <label>
  want=$1; runp
  ok '[ "$out" = "$want" ] && { [ -z "$want" ] && [ "$rc" = 0 ] || { [ -n "$want" ] && [ "$rc" != 0 ]; }; }' "$2 -> ${1:-pass} (exit $rc${out:+, got '$out'})"
}

use; expect "" "the exact ruleset init-firewall.sh produces"
use; sed -i -E 's# -p (tcp|udp) # -p \1 -m \1 #; s# -d ([0-9.]+) # -d \1/32 #' "$P/ipt"; expect "" "iptables -S spelling (-m tcp, -d <ip>/32) passes too"
use; sed -i -E 's# -p (tcp|udp) # -p \1 -m \1 #; s# -d ([0-9.]+) # -d \1/32 #' "$P/ipt"; ins "-A OUTPUT -p tcp -m tcp --dport 22 -j ACCEPT"; expect ssh,extra "iptables -S spelling: the open tcp/22 is still caught"
use; sed -i 's/^-P OUTPUT DROP/-P OUTPUT ACCEPT/' "$P/ipt"; expect policy "OUTPUT policy ACCEPT"
use; sed -i 's/^-P FORWARD DROP/-P FORWARD ACCEPT/' "$P/ipt"; expect policy "FORWARD policy ACCEPT"
use; sed -i 's/^-P INPUT DROP/-P INPUT ACCEPT/' "$P/ipt"; expect policy "INPUT policy ACCEPT"
use; sed -i 's/ -p tcp --dport 443 -m set/ -m set/' "$P/ipt"; expect web443,extra "allowlist rule without the tcp/443 restriction (pre-B2)"
use; sed -i 's/ -p tcp --dport 443 -m set/ -p tcp --dport 80 -m set/' "$P/ipt"; expect web443,extra "allowlist rule on the wrong port"
use; ins "-A OUTPUT -p tcp -m tcp --dport 443 -m set --match-set allowed-domains dst -j ACCEPT"; sed -i '0,/--dport 443/s// /' "$P/ipt"; expect web443,extra "a second, unrestricted allowlist rule next to the good one"
use; ins "-A OUTPUT -p tcp --dport 22 -j ACCEPT"; expect ssh,extra "tcp/22 open to anywhere (the drill rule)"
use; ins "-A OUTPUT -p tcp -m tcp --dport 22 -j ACCEPT"; expect ssh,extra "tcp/22 open to anywhere, iptables -S spelling"
use; ins "-A OUTPUT -d 172.17.0.0/24 -j ACCEPT"; expect lan,extra "a /24 accept"
use; ins "-A INPUT -s 192.168.0.0/16 -j ACCEPT"; expect lan,extra "a /16 accept"
use; ins "-A OUTPUT -p udp -d 0.0.0.0/0 --dport 53 -j ACCEPT"; expect dns,extra "DNS to 0.0.0.0/0"
use; ins "-A OUTPUT -p udp -m udp --dport 53 -j ACCEPT"; expect dns "DNS accepted with no destination"
use; grep -v REJECT "$P/ipt" > "$P/x"; mv "$P/x" "$P/ipt"; expect reject "final REJECT missing"
use; echo "-A OUTPUT -j LOG" >> "$P/ipt"; expect reject "REJECT is not the last OUTPUT rule"
use; grep -v 11434 "$P/ipt" > "$P/x"; mv "$P/x" "$P/ipt"; expect ollama "Ollama rule missing"
use; sed -i 's/^-P OUTPUT DROP/-P OUTPUT ACCEPT/' "$P/ip6t"; expect ipv6 "IPv6 policy ACCEPT"
use; grep -vx github-ssh "$P/sets" > "$P/x"; mv "$P/x" "$P/sets"; expect sets "an ipset missing"
use; ins "-A OUTPUT -p tcp --dport 22 -j ACCEPT"; sed -i 's/^-P OUTPUT DROP/-P OUTPUT ACCEPT/' "$P/ipt"; expect "policy,ssh,extra" "several failures: every token, comma separated, no spaces"
# D46 (QB2-4 follow-up): any INPUT/OUTPUT accept rule that is not a shape init-firewall.sh creates is "extra".
use; ins "-A OUTPUT -j ACCEPT"; expect extra "an unrestricted -A OUTPUT -j ACCEPT"
use; ins "-A OUTPUT -p tcp --dport 80 -j ACCEPT"; expect extra "plain tcp/80 open to anywhere"
use; ins "-A OUTPUT -p tcp -m tcp --dport 80 -j ACCEPT"; expect extra "plain tcp/80 open, iptables -S spelling"
use; ins "-A INPUT -j ACCEPT"; expect extra "an unrestricted -A INPUT -j ACCEPT"
use; ins "-A OUTPUT -p udp -m udp -d 1.2.3.4/32 --dport 123 -j ACCEPT"; expect extra "one host on an unexpected port"
# Real `iptables -S` spelling: -d/-s before -p, -m tcp/-m udp, /32, RELATED,ESTABLISHED; conntrack spelling too.
real() { sed -i -E 's#^-A (INPUT|OUTPUT) -p (tcp|udp) -([ds]) ([0-9.]+) #-A \1 -\3 \4/32 -p \2 -m \2 #; s#^-A OUTPUT -p tcp --dport#-A OUTPUT -p tcp -m tcp --dport#; s#ESTABLISHED,RELATED#RELATED,ESTABLISHED#' "$P/ipt"; }
use; real; expect "" "the real ruleset in real iptables -S spelling (-d before -p, -m tcp, /32, RELATED,ESTABLISHED)"
use; real; sed -i 's#-m state --state#-m conntrack --ctstate#' "$P/ipt"; expect "" "established/related in conntrack spelling"
use; real; ins "-A OUTPUT -j ACCEPT"; expect extra "real spelling plus an unrestricted OUTPUT accept"
use; rm "$P/bin/ip6tables"; expect "" "no ip6tables installed: IPv6 is not checked"
use; printf '#!/bin/sh\nexit 1\n' > "$P/bin/iptables"; runp
ok '[ "$rc" != 0 ] && grep -q policy <<<"$out"' "iptables unusable: the probe fails (exit $rc, got '$out')"

# What the script does with it.
ok '! grep -q "/workspace" <<<"$probe"' "the probe runs no file from the repo (root never executes a node-writable file here)"
ok '! grep -qE "[.](com|io|net|org|ai|dev)|anthropic|openai|claude|gemini|discord|github[.]|hermes|[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+" <<<"$probe"' "provider-neutral: the probe names no host, provider or address, only rule shapes and set names"
ok '! grep -q "\"" <<<"$probe"' "no double quote in the probe (Windows PowerShell 5.1 mangles them in native arguments)"
ok '! grep -qP "[^\x00-\x7F]" "$PS1" && ! grep -q "$(printf "\r")" "$PS1" && [ "$(head -c3 "$PS1" | od -An -tx1 | tr -d " ")" != efbbbf ]' "stella-recover.ps1 stays ASCII only, LF line endings, no BOM"
ok 'grep -q "firewall probe failed: " "$PS1" && grep -q "firewall still failing after re-apply: " "$PS1" && grep -q "STL-RCV-504" "$PS1" && ! grep -q "iptables -S OUTPUT | grep -q" "$PS1"' "the script logs both failure lines, raises STL-RCV-504, and the old two-grep probe is gone"
tokens=$(grep -o "bad [a-z0-9]*" <<<"$probe" | cut -d' ' -f2 | sort -u; echo unchecked)
catalog=$(python3 -I -c 'import json,sys; print("\n".join(sorted(k for k in next(a for a in json.load(open(sys.argv[1]))["alerts"] if a["code"]=="STL-RCV-504")["parts"] if k != "_other")))' "$B/../docs/hermes-local/alert-catalog.json" 2>&1)
ok '[ "$(sort -u <<<"$tokens")" = "$catalog" ]' "every token the probe can print (and unchecked) has a phrase in the STL-RCV-504 table, and no phrase is unused"
done_
