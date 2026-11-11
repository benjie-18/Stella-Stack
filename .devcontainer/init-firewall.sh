#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting
# Runs as root via sudo: a fixed PATH and HOME, so the caller's PATH, ~/.curlrc or ~/.digrc never reach root (S37)
export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root

# Fail closed (S3): any exit before the ruleset is complete leaves INPUT, OUTPUT and FORWARD at DROP (IPv4 and IPv6).
# A run that starts from DROP stays closed throughout, because -F keeps the policies.
fw_complete=0
fail_closed() {
    local rc=$?
    [ "$fw_complete" = 1 ] && return
    for chain in INPUT OUTPUT FORWARD; do
        /usr/sbin/iptables -P "$chain" DROP || true
        [ ! -x /usr/sbin/ip6tables ] || /usr/sbin/ip6tables -P "$chain" DROP || true
    done
    echo "ERROR: firewall setup did not complete (exit $rc); every policy set to DROP" >&2 || true
    [ "$rc" != 0 ] || rc=1
    exit "$rc"
}
trap fail_closed EXIT

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(/usr/sbin/iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
/usr/sbin/iptables -F
/usr/sbin/iptables -X
/usr/sbin/iptables -t nat -F
/usr/sbin/iptables -t nat -X
/usr/sbin/iptables -t mangle -F
/usr/sbin/iptables -t mangle -X
/usr/sbin/ipset destroy allowed-domains 2>/dev/null || true
/usr/sbin/ipset destroy github-ssh 2>/dev/null || true

# IPv6 (F32): nothing here needs it, so drop everything but loopback. Missing or failing ip6tables: logged, not fatal.
if [ -x /usr/sbin/ip6tables ]; then
    /usr/sbin/ip6tables -F && /usr/sbin/ip6tables -X \
        && /usr/sbin/ip6tables -A INPUT -i lo -j ACCEPT && /usr/sbin/ip6tables -A OUTPUT -o lo -j ACCEPT \
        && /usr/sbin/ip6tables -P INPUT DROP && /usr/sbin/ip6tables -P FORWARD DROP && /usr/sbin/ip6tables -P OUTPUT DROP \
        || echo "WARNING: ip6tables failed: IPv6 is not filtered" >&2
else
    echo "WARNING: ip6tables not found: IPv6 is not filtered" >&2
fi

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    /usr/sbin/iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    /usr/sbin/iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 /usr/sbin/iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# First allow DNS and localhost before any restrictions
# DNS only to the resolvers in /etc/resolv.conf (S12); Docker's embedded 127.0.0.11 is loopback, allowed below
RESOLVERS=$(awk '$1 == "nameserver" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $2}' /etc/resolv.conf)
if [ -z "$RESOLVERS" ]; then
    echo "ERROR: No IPv4 nameserver in /etc/resolv.conf"
    exit 1
fi
for ns in $RESOLVERS; do
    for proto in udp tcp; do
        /usr/sbin/iptables -A OUTPUT -p "$proto" -d "$ns" --dport 53 -j ACCEPT
        /usr/sbin/iptables -A INPUT -p "$proto" -s "$ns" --sport 53 -j ACCEPT
    done
done
# Allow localhost
/usr/sbin/iptables -A INPUT -i lo -j ACCEPT
/usr/sbin/iptables -A OUTPUT -o lo -j ACCEPT

# CORRECTED: Allow return traffic early. On a reconnect, INPUT/OUTPUT
# policies are already DROP, and the ESTABLISHED rule was only added at
# the end, so the GitHub fetch's responses were dropped even when
# outbound was allowed. The later ESTABLISHED rules are now duplicates,
# which iptables allows and is harmless.
/usr/sbin/iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
/usr/sbin/iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Create ipset with CIDR support
/usr/sbin/ipset create allowed-domains hash:net
# GitHub's git ranges, the only destinations for tcp/22 (S1)
/usr/sbin/ipset create github-ssh hash:net
# CORRECTED Reconnect fix v2: single-IP dig is stale, TTL 26s, IP rotates
# (140.82.113.6 vs 140.82.112.5 observed). Temporarily allow GitHub's
# 140.82.112.0/20, deleted after the fetch below, so the final state is
# only the ipset ranges from GitHub meta.
/usr/sbin/iptables -A OUTPUT -p tcp -d 140.82.112.0/20 --dport 443 -j ACCEPT


# Fetch GitHub meta information and aggregate + add their IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(/usr/bin/curl -q -sS --max-time 30 https://api.github.com/meta) || gh_ranges=""
# CORRECTED: remove the temporary subnet rule now that the fetch is done (also after a failed fetch, S29).
/usr/sbin/iptables -D OUTPUT -p tcp -d 140.82.112.0/20 --dport 443 -j ACCEPT || true
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
add_github_ranges() {  # <set name> <jq filter>: the meta's IPv4 ranges, aggregated and validated
    while read -r cidr; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
            exit 1
        fi
        echo "Adding GitHub range $cidr to $1"
        /usr/sbin/ipset add -exist "$1" "$cidr"
    done < <(echo "$gh_ranges" | jq -r "$2" | aggregate -q)
}
add_github_ranges allowed-domains '(.web + .api + .git)[]'
add_github_ranges github-ssh '.git[]'

# Resolve and add other allowed domains
# Stage 5 additions (exact hosts, no wildcards; resolved once at start, so a Cloudflare/Google IP rotation needs a restart):
#   api.osv.dev        - `hermes security audit` and SkillSpector OSV lookups (failed: "[Errno 113] No route to host")
#   discord.com        - Discord REST, discord.py Route.BASE https://discord.com/api (failed: connect to discord.com:443)
#   gateway.discord.gg - Discord websocket, discord.py DEFAULT_GATEWAY wss://gateway.discord.gg/
# Stage 6 closeout (T14/T15): the OmniRoute gateway's one connected key-based provider, the owner's choice in its dashboard:
#   openrouter.ai      - OmniRoute -> OpenRouter API (live: `curl https://openrouter.ai` fails with no route to host)
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "sentry.io" \
    "statsig.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com" \
    "pypi.org" \
    "files.pythonhosted.org" \
    "nodejs.org" \
    "hermes-agent.nousresearch.com" \
    "api.osv.dev" \
    "discord.com" \
    "gateway.discord.gg" \
    "openrouter.ai"; do
    echo "Resolving $domain..."
    ips=$(/usr/bin/dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}' | sort -u)
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        /usr/sbin/ipset add -exist allowed-domains "$ip"
    done < <(echo "$ips")
done

# The host gets no blanket rule (S2, was the gateway's /24, all ports): its consumers are DNS above and Ollama below.

# Resolve host.docker.internal at run time (its IP can change across restarts)
# and allow only the Ollama API port on it
OLLAMA_HOST_IP=$(/usr/bin/getent hosts host.docker.internal | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}' || true)
if [ -z "$OLLAMA_HOST_IP" ]; then
    OLLAMA_HOST_IP=$(/usr/bin/dig +noall +answer A host.docker.internal | awk '$4 == "A" {print $5; exit}' || true)
fi
if [[ ! "$OLLAMA_HOST_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "ERROR: Failed to resolve host.docker.internal"
    exit 1
fi
echo "Allowing Ollama at $OLLAMA_HOST_IP:11434"
/usr/sbin/iptables -A OUTPUT -p tcp -d "$OLLAMA_HOST_IP" --dport 11434 -j ACCEPT

# Set default policies to DROP first
/usr/sbin/iptables -P INPUT DROP
/usr/sbin/iptables -P FORWARD DROP
/usr/sbin/iptables -P OUTPUT DROP

# First allow established connections for already approved traffic
/usr/sbin/iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
/usr/sbin/iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains: HTTPS only (S13; no consumer needs port 80)
/usr/sbin/iptables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-domains dst -j ACCEPT
# git over SSH: GitHub's git ranges only (S1, was any host)
/usr/sbin/iptables -A OUTPUT -p tcp --dport 22 -m set --match-set github-ssh dst -j ACCEPT

# Explicitly REJECT all other outbound traffic for immediate feedback
/usr/sbin/iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if /usr/bin/curl -q --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Verify GitHub API access
if ! /usr/bin/curl -q --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi
fw_complete=1
