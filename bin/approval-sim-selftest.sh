#!/usr/bin/env bash
# T6b (simulated, not live): Hermes's real dangerous-command approval gate in a gateway context. bin/approval-sim.py puts a stub
# where the Discord adapter would send the button message and calls the same resolve function the adapter's button and
# /approve|/deny use. Proves: the gate parks the agent, hands the adapter the button data, and approve lets it run, deny
# refuses it. Does NOT prove the Discord render or a human click (those stay a live, human step). Scratch HERMES_HOME.
set -u
fails=0
ok() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails+1)); fi; }
py=$(ls /home/node/.hermes/installs/*/environments/*/venv/bin/python 2>/dev/null | while read -r p; do
  "$p" -I -c 'import sys; sys.path.insert(0, "/home/node/.hermes/hermes-agent"); import tools.approval' >/dev/null 2>&1 && { echo "$p"; break; }; done)
[ -n "$py" ] || { echo "SKIP no Hermes python can import tools.approval"; echo "selftest SKIP"; exit 0; }
out=$(timeout 90 "$py" -I /workspace/bin/approval-sim.py 2>&1); rc=$?
ok '[ $rc = 0 ]' "the simulation exits 0 (rc $rc)"
ok 'grep -q "^once: button_data_sent=True agent_blocked_before_answer=True resolved=1 approved=True" <<<"$out"' "approve: button data sent, agent parked, then allowed"
ok 'grep -q "^deny: button_data_sent=True agent_blocked_before_answer=True resolved=1 approved=False" <<<"$out"' "deny: button data sent, agent parked, then refused"
ok 'grep -q "request_id" <<<"$out"' "the button data carries a request id (what the Discord buttons answer)"
[ "$fails" = 0 ] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; exit 1; }
