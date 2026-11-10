# T6b faithful simulation: Hermes's real approval gate (tools.approval), a stub in place of the Discord adapter's
# send (the notify callback gets the data the button message is built from) and the /approve | /deny handler call.
import os, sys, tempfile, threading, time
os.environ["HERMES_HOME"] = tempfile.mkdtemp(); os.environ["HERMES_GATEWAY_SESSION"] = "1"; os.environ["HERMES_EXEC_ASK"] = "1"
sys.path.insert(0, "/home/node/.hermes/hermes-agent")
from tools import approval as A, approval_context as C


def attempt(choice, reason=None):
    sk = f"sim-{choice}"; sent = []; out = {}
    A.register_gateway_notify(sk, sent.append)

    def agent():
        C._approval_session_key.set(sk)
        out["r"] = A.check_all_command_guards("rm -rf /tmp/stage6-sim-nonexistent/*", "local")

    t = threading.Thread(target=agent); t.start()
    for _ in range(100):
        if sent: break
        time.sleep(0.05)
    shown = bool(sent) and A.has_blocking_approval(sk)
    blocked = t.is_alive()
    n = A.resolve_gateway_approval(sk, choice, reason=reason)
    t.join(10)
    r = out.get("r", {})
    print(f"{choice}: button_data_sent={shown} agent_blocked_before_answer={blocked} resolved={n} approved={r.get('approved')}")
    if sent: print("   data keys:", sorted(sent[0]), "| description:", sent[0].get("description"))
    return shown, blocked, n, bool(r.get("approved"))


a = attempt("once"); d = attempt("deny")
ok = a == (True, True, 1, True) and d == (True, True, 1, False)
print("SIM", "PASS" if ok else "FAIL"); sys.exit(0 if ok else 1)
