#!/usr/bin/env bash
# Hermetic self-test for .devcontainer/init-firewall.sh (S1, S2, S3, S12, S13, S29, S37, F32): runs a copy whose
# absolute tool paths (and /etc/resolv.conf) point at recording stubs, so nothing touches the real firewall or network.
# Checks: every failure path ends with INPUT, OUTPUT and FORWARD at DROP (IPv4 and IPv6) and a non-zero exit; no
# policy is ever ACCEPT; tcp/22 only to GitHub's git ranges; no gateway /24 rule; DNS only to the resolver; the
# allowlist accepts tcp/443 only; IPv6 dropped (a missing ip6tables is logged, not fatal); a second run is identical.
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
SRC=/workspace/.devcontainer/init-firewall.sh
sed -E -e "s#/usr/s?bin/(iptables-save|iptables|ip6tables|ipset|curl|dig|getent)\b#$T/bin/\1#g" \
  -e "s#/etc/resolv.conf#$T/resolv.conf#g" "$SRC" > "$T/fw.sh"
for t in iptables ip6tables ipset; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> %s/calls\n' "$t" "$T" > "$T/bin/$t"
done
echo '[[ -n "${KILL_IPT:-}" && "$*" == *"$KILL_IPT"* ]] && { kill -TERM $PPID; sleep 1; }' >> "$T/bin/iptables"
echo '[[ -n "${FAIL_IPT:-}" && "$*" == *"$FAIL_IPT"* ]] && exit 1; exit 0' >> "$T/bin/iptables"
echo '[ -z "${FAIL_IP6:-}" ]' >> "$T/bin/ip6tables"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/iptables-save"
cat > "$T/bin/curl" <<S
#!/usr/bin/env bash
echo "curl \$*" >> $T/calls
case "\$*" in
  *api.github.com/meta*) [ -z "\${FAKE_META_RC:-}" ] || exit "\$FAKE_META_RC"
    if [ "\${FAKE_META+set}" = set ]; then printf '%s' "\$FAKE_META"; else cat $T/meta.json; fi ;;
  *example.com*) [ -n "\${FAKE_EXAMPLE_OK:-}" ] || exit 7 ;;
esac
exit 0
S
cat > "$T/bin/dig" <<S
#!/usr/bin/env bash
d="\${@: -1}"; echo "dig \$*" >> $T/calls
[ "\$d" != "\${FAKE_DIG_EMPTY:-}" ] || exit 0
[ "\$d" != "\${FAKE_DIG_BAD:-}" ] || { echo "\$d. 60 IN A 1.2.3"; exit 0; }
echo "\$d. 60 IN A 192.0.2.10"
S
cat > "$T/bin/getent" <<'S'
#!/usr/bin/env bash
[ -z "${FAKE_GETENT_FAIL:-}" ] || exit 2
echo "192.168.65.254  host.docker.internal"
S
cat > "$T/bin/ip" <<'S'
#!/usr/bin/env bash
[ -z "${FAKE_IP_FAIL:-}" ] || exit 1
echo "default via 172.17.0.1 dev eth0"
S
chmod +x "$T/bin/"*
echo '{"web":["140.82.112.0/20","192.30.252.0/22"],"api":["143.55.64.0/20"],"git":["140.82.112.0/20","192.30.252.0/22","2606:50c0::/32"]}' > "$T/meta.json"
RESOLV='nameserver 192.168.65.7'
echo "$RESOLV" > "$T/resolv.conf"
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
run() { : > "$T/calls"; env PATH="$T/bin:$PATH" "$@" bash "$T/fw.sh" > "$T/out" 2>&1; rc=$?; }   # PATH: the old script's bare names
pol() { grep "^$1 -P $2 " "$T/calls" | tail -1 | cut -d' ' -f4; }   # last policy set on <tool> <chain>
closed() { [ "$(pol "$1" INPUT)" = DROP ] && [ "$(pol "$1" OUTPUT)" = DROP ] && [ "$(pol "$1" FORWARD)" = DROP ]; }
fails_closed() { local label=$1; shift; run "$@"
  ok '[ "$rc" != 0 ] && closed iptables && closed ip6tables' "S3: $label: exit $rc, every policy ends at DROP (IPv4 and IPv6)"; }

ok '! grep -qE "/usr/s?bin/(iptables|ip6tables|ipset|curl|dig|getent)\b" "$T/fw.sh"' "the copy calls stubs only"
run
ok '[ "$rc" = 0 ] && grep -q "Firewall configuration complete" "$T/out"' "a clean run completes (exit $rc)"
ok '! grep -qE -- "-P (INPUT|OUTPUT|FORWARD) ACCEPT" "$T/calls"' "S3: no policy is ever set to ACCEPT"
ok '[ -z "$(grep -- "--dport 22 " "$T/calls" | grep -v -- "^iptables -A OUTPUT -p tcp --dport 22 -m set --match-set github-ssh dst -j ACCEPT$")" ] && grep -q -- "--match-set github-ssh dst" "$T/calls"' "S1: tcp/22 is accepted only to the github-ssh set"
ok '[ "$(grep "^ipset add -exist github-ssh " "$T/calls" | cut -d" " -f5 | sort | tr "\n" " ")" = "140.82.112.0/20 192.30.252.0/22 " ]' "S1: github-ssh holds only the meta .git ranges (IPv4, aggregated)"
ok '! grep -qE -- "-(s|d) [0-9.]+/24 " "$T/calls"' "S2: no accept rule for the gateway /24"
ok '[ -z "$(grep -E -- "^iptables -A OUTPUT .*-d " "$T/calls" | grep -vE -- " -d (192\.168\.65\.7|192\.168\.65\.254|140\.82\.112\.0/20) ")" ] && [ -z "$(grep -E -- "^iptables -A INPUT .*-s " "$T/calls" | grep -v -- " -s 192\.168\.65\.7 ")" ]' "S2: destination/source rules name only the resolver, the Ollama host and the temporary GitHub fetch range"
ok 'grep -qx -- "iptables -A OUTPUT -p tcp -d 192.168.65.254 --dport 11434 -j ACCEPT" "$T/calls"' "S2: the host is reachable on the Ollama port only"
ok '[ "$(grep -cE -- "--(d|s)port 53 " "$T/calls")" = 4 ] && [ -z "$(grep -E -- "--(d|s)port 53 " "$T/calls" | grep -vE -- " -(d|s) 192\.168\.65\.7 ")" ]' "S12: DNS (udp and tcp, out and in) only to the resolv.conf nameserver"
ok '[ "$(grep -c -- "allowed-domains dst -j ACCEPT" "$T/calls")" = 1 ] && grep -qx -- "iptables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-domains dst -j ACCEPT" "$T/calls"' "S13: the allowlist accept is tcp/443 only"
ok 'closed ip6tables && grep -qx "ip6tables -A INPUT -i lo -j ACCEPT" "$T/calls" && grep -qx "ip6tables -A OUTPUT -o lo -j ACCEPT" "$T/calls"' "F32: IPv6 policies DROP, loopback allowed"
ok 'grep -qx "export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root" "$SRC"' "S37: fixed PATH and HOME=/root for the root run"
ok '[ -z "$(grep "^curl " "$T/calls" | grep -v "^curl -q ")" ] && grep -q "^curl -q " "$T/calls"' "S37: every curl call starts with -q (no .curlrc)"
ok '[ -z "$(grep -vE "^\s*(#|(\|\| )?echo \"[^\"]*\"( >&2)?$)" "$SRC" | sed -E "s#/usr/s?bin/(iptables-save|iptables|ip6tables|ipset|curl|dig|getent)\b##g" | grep -nwE "iptables-save|iptables|ip6tables|ipset|curl|dig|getent")" ]' "S37: firewall tools are called by absolute path only"
cp "$T/calls" "$T/calls1"; run
ok '[ "$rc" = 0 ] && diff -q "$T/calls1" "$T/calls" >/dev/null' "idempotent: a second run (from the DROP state) issues the same calls"
run FAKE_IP_FAIL=1
ok '[ "$rc" = 0 ]' "S2, S30: no dependency on the default route (ip route failing: exit $rc)"
mv "$T/bin/ip6tables" "$T/ip6tables.off"; run; mv "$T/ip6tables.off" "$T/bin/ip6tables"
ok '[ "$rc" = 0 ] && grep -q "ip6tables not found" "$T/out"' "F32: ip6tables missing: logged, the IPv4 firewall still completes (exit $rc)"
run FAIL_IP6=1
ok '[ "$rc" = 0 ] && grep -q "IPv6 is not filtered" "$T/out"' "F32: ip6tables failing: logged, not fatal (exit $rc)"
run FAKE_META_RC=7
ok 'grep -qx -- "iptables -D OUTPUT -p tcp -d 140.82.112.0/20 --dport 443 -j ACCEPT" "$T/calls" && grep -q "Failed to fetch GitHub IP ranges" "$T/out"' "S29: a failed meta fetch deletes the temporary GitHub rule and logs the error"

fails_closed "the first flush fails (set -e)" FAIL_IPT=-F
fails_closed "killed by SIGTERM mid-run" "KILL_IPT=-A OUTPUT -o lo"
fails_closed "curl of the GitHub meta fails (old :59, set -e)" FAKE_META_RC=7
fails_closed "empty GitHub meta (old :64)" FAKE_META=
fails_closed "GitHub meta without web/api/git (old :69)" "FAKE_META={}"
fails_closed "a host does not resolve (old :106)" FAKE_DIG_EMPTY=discord.com
fails_closed "a host resolves to an invalid IP (old :112)" FAKE_DIG_BAD=pypi.org
fails_closed "host.docker.internal does not resolve (old :142)" FAKE_GETENT_FAIL=1 FAKE_DIG_EMPTY=host.docker.internal
fails_closed "an iptables rule fails mid-run (set -e)" "FAIL_IPT=allowed-domains dst"
fails_closed "verification reaches example.com" FAKE_EXAMPLE_OK=1
printf 'search example\n' > "$T/resolv.conf"
fails_closed "no IPv4 nameserver in resolv.conf" ; echo "$RESOLV" > "$T/resolv.conf"
# Old :76 (invalid CIDR from the meta) is unreachable: aggregate drops invalid lines before the check.
PAT="allowed-domains dst -j ACCEPT"
ok 'grep -qF -- "$PAT" "$T/calls1" && grep -qF -- "$PAT" /workspace/docs/stella-recover.ps1 && grep -qF -- "$PAT" /workspace/bin/firewall-check.sh' "S34: the Windows probe and firewall-check.sh look for the allowlist rule init-firewall.sh adds"
ok '[ "$(LC_ALL=C grep -cP "[^\x00-\x7F]|\r" /workspace/docs/stella-recover.ps1)" = 0 ]' "stella-recover.ps1 stays ASCII with LF line ends (Windows PowerShell 5.1 reads a BOM-less file as ANSI)"

# bin/firewall-check.sh (T11): every probe goes through `timeout`, stubbed here; the rule listings are stubbed too.
mkdir -p "$T/chk"
cat > "$T/chk/timeout" <<'S'
#!/usr/bin/env bash
shift
case "$*" in *dig\ @*) [ -n "${FAKE_UDP_OPEN:-}" ]; exit ;; esac
[[ " $FAKE_OPEN " == *" ${@: -2:1}:${@: -1} "* ]]
S
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$FAKE_RULES"\n' > "$T/chk/iptables"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$FAKE_RULES6"\n' > "$T/chk/ip6tables"
chmod +x "$T/chk/"*
OPEN="api.github.com:443 api.anthropic.com:443 discord.com:443 gateway.discord.gg:443 host.docker.internal:11434 github.com:22"
RULES=$'-P OUTPUT DROP\n-A OUTPUT -p tcp -m tcp --dport 443 -m set --match-set allowed-domains dst -j ACCEPT'
chk() { env PATH="$T/chk:$PATH" FAKE_OPEN="$OPEN" FAKE_RULES="$RULES" FAKE_RULES6="-P OUTPUT DROP" "$@" \
  /workspace/bin/firewall-check.sh > "$T/out" 2>&1; rc=$?; }
chk
ok '[ "$rc" = 0 ] && ! grep -q "^FAIL" "$T/out" && [ "$(grep -c "^PASS" "$T/out")" -ge 12 ]' "firewall-check: the expected state passes every probe and prints each (exit $rc)"
for c in "FAKE_OPEN=$OPEN example.com:443|example.com:443" "FAKE_OPEN=$OPEN gitlab.com:22|gitlab.com:22" \
         "FAKE_UDP_OPEN=1|udp/53" "FAKE_OPEN=api.github.com:443|host.docker.internal:11434" \
         "FAKE_RULES=-P OUTPUT ACCEPT|policy" "FAKE_RULES6=-P OUTPUT ACCEPT|IPv6"; do
  chk "${c%|*}"
  ok '[ "$rc" = 1 ] && grep "^FAIL" "$T/out" | grep -qF -- "${c#*|}"' "firewall-check: ${c%%=*} broken -> exit $rc, FAIL names ${c#*|}"
done
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
