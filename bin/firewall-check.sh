#!/usr/bin/env bash
# Read-only egress check of the container firewall (T11; the ruleset is .devcontainer/init-firewall.sh). Run as root
# from the host, because node cannot read iptables:   docker exec -u root <container> /workspace/bin/firewall-check.sh
# One PASS/FAIL line per probe; exit 1 if any probe fails. Changes nothing: TCP connects, one DNS query, `iptables -S`.
set -u
fails=0
result() { if [ "$1" = 0 ]; then echo "PASS $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
tcp() { timeout 8 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" >/dev/null 2>&1; }   # TCP connect only
reach() { tcp "$1" "$2"; result $? "reachable $1:$2 ($3)"; }
refused() { tcp "$1" "$2"; [ $? != 0 ]; result $? "refused   $1:$2 ($3)"; }

reach api.github.com 443 "GitHub API"
reach api.anthropic.com 443 "model provider"
reach discord.com 443 "Discord REST"
reach gateway.discord.gg 443 "Discord gateway"
reach host.docker.internal 11434 "Ollama"
reach github.com 22 "git over SSH, GitHub's git ranges only"
refused example.com 443 "a host not on the allowlist"
refused gitlab.com 22 "tcp/22 outside GitHub; example.com does not listen on 22"
refused api.anthropic.com 80 "allowlisted host, not tcp/443"
refused 2606:4700:4700::1111 443 "IPv6 egress"
timeout 8 dig @1.1.1.1 +time=3 +tries=1 example.com >/dev/null 2>&1; [ $? != 0 ]
result $? "refused   udp/53 to 1.1.1.1 (DNS only to the resolv.conf resolver)"

rules=$(iptables -S 2>&1); result $? "iptables -S readable (needs root)"
grep -qx -- '-P OUTPUT DROP' <<<"$rules"; result $? "IPv4 OUTPUT policy DROP"
grep -q -- '--dport 443 -m set --match-set allowed-domains dst -j ACCEPT' <<<"$rules"; result $? "allowlist rule, tcp/443 only"
if command -v ip6tables >/dev/null; then
  ip6tables -S OUTPUT 2>/dev/null | grep -qx -- '-P OUTPUT DROP'; result $? "IPv6 OUTPUT policy DROP"
else
  echo "INFO ip6tables not installed: IPv6 policy not checked (the IPv6 egress probe above still ran)"
fi
[ "$fails" = 0 ] && echo "firewall-check PASS" || { echo "firewall-check FAIL ($fails)"; exit 1; }
