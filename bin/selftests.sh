#!/usr/bin/env bash
# Run every hermetic self-test (stubs, scratch state, no network, no secrets). Part of `npm test`, so the 15-minute
# watchdog (bin/watchdog.sh) also catches escalation-script regressions and alerts #alerts (D31).
set -u
unset STELLA_ROOT   # an inherited scratch root must not re-target the data tools and the gates that run them
unset HARDCODE_ALLOW HARDCODE_HOME   # likewise the hard-code lint's own switches (another list or home would turn its gate green)
fails=0
# K11: no selftest posts to Discord. A `hermes` first on PATH refuses `send` and passes every other call to the real one;
# a selftest's own stub, put before it, still wins.
G=$(mktemp -d); trap 'rm -r "$G"' EXIT
printf '#!/usr/bin/env bash\n[ "${1:-}" = send ] && { echo "selftests: hermes send refused in a selftest" >&2; exit 1; }\nexec %q "$@"\n' \
  "$(command -v hermes || echo /bin/false)" >"$G/hermes" && chmod +x "$G/hermes" && export PATH="$G:$PATH"
for t in alert alert-page delegation escalate escalation-thread escalation-reply-poll escalation-reply-hook escalation-complete kanban-guard false-close-guard check-guard complete-gate roles-complete profile-hooks commit-guard owner-config owner-leak write-guard roles role-guard secret-read matcher-audit kanban-board merge-card owner-settings watchdog model-watch hardcode-lint init-firewall firewall-probe container-start post-edit-check box bench approval-sim omniroute-run reviewer-claude approval-evidence routing broker-put test-map stella-data event-log stella-apply; do
  out=$(/workspace/bin/$t-selftest.sh 2>&1 | grep -v setlocale)
  if printf '%s\n' "$out" | tail -1 | grep -q "selftest PASS"; then
    echo "ok   $t-selftest"
  elif printf '%s\n' "$out" | tail -1 | grep -q "selftest SKIP"; then
    echo "skip $t-selftest: $(printf '%s\n' "$out" | grep -m1 '^SKIP' | cut -c6-)"
  else
    echo "FAIL $t-selftest"; printf '%s\n' "$out" | grep -E "^FAIL" | sed 's/^/     /'; fails=$((fails+1))
  fi
done
[ "$fails" = 0 ] && echo "selftests PASS" || { echo "selftests FAIL ($fails)"; exit 1; }
