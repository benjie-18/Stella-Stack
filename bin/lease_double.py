#!/usr/bin/env python3
"""Test double of the primary lease (F1c B6, design D5; U1 builds the real lease service), stdlib only. Exactly one engine per
account holds the lease; a lease is the contract .stella/schemas/primary-lease.schema.json {account, engine_id, install_id,
lease_id, acquired_at, expires_at}. The leases live in a JSON state file {account: lease} given with --state.
CLI: lease_double.py claim --state F --account A --engine E --ttl S    the lease for S seconds; prints it. A lease another engine
                                                                       holds and that has not expired: STL-OWN-814, nothing written
     lease_double.py release --state F --account A --engine E          the holder gives it up; anyone else: STL-OWN-814
     lease_double.py show --state F --account A                        the account's lease, or null
Exit 1 with the code and its plain message when refused or the state file is not a lease state (STL-CFG-310); exit 2: usage."""
import calendar, json, os, re, sys, time, uuid
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import stella_data as sd

TIME = "%Y-%m-%dT%H:%M:%SZ"
OPTS = {"claim": {"--state", "--account", "--engine", "--ttl"}, "release": {"--state", "--account", "--engine"}, "show": {"--state", "--account"}}


def load(f):
    """{account: lease}; an absent file is no lease. Every lease must pass the contract."""
    if not os.path.exists(f):
        return {}
    st = sd.jload(f)
    if not isinstance(st, dict):
        raise sd.DataError(f"{f}: not an object of account: lease")
    for v in st.values():
        sd.checked(v, f, "primary-lease")
    return st


def save(f, st):
    # shortcut: no lock between read and write (a single-process test double); the real lease (U1) serialises claims
    with open(f + ".new", "w", encoding="utf-8") as h:
        json.dump(st, h, indent=2, ensure_ascii=False)
    os.replace(f + ".new", f)


def main(argv):
    cmd, it, o = (argv[0] if argv else ""), iter(argv[1:]), {}
    for a in it:
        v = next(it, None)
        if a not in OPTS.get(cmd, ()) or a in o or not v:
            o = None
            break
        o[a] = v
    if o is None or set(o) != OPTS.get(cmd) or ("--ttl" in o and not re.fullmatch(r"0*[1-9][0-9]{0,8}", o["--ttl"])):
        print(__doc__.split("CLI: ", 1)[1].split("Exit 1")[0], file=sys.stderr)
        return 2
    f, acct, now = o["--state"], o["--account"], int(time.time())
    try:
        st = load(f)
    except sd.DataError as e:
        sd.say("STL-CFG-310", str(e))
        return 1
    cur = st.get(acct)
    held = cur is not None and calendar.timegm(time.strptime(cur["expires_at"], TIME)) > now
    if cmd == "show":
        print(json.dumps(cur, indent=2, ensure_ascii=False))
        return 0
    if cmd == "release":
        if not (cur and cur["engine_id"] == o["--engine"]):
            sd.say("STL-OWN-814", f"engine {sd.shown(o['--engine'])} does not hold the lease of account {sd.shown(acct)}")
            return 1
        del st[acct]
        save(f, st)
        print(f"released the lease of account {sd.shown(acct)}")
        return 0
    if held and cur["engine_id"] != o["--engine"]:
        sd.say("STL-OWN-814", f"engine {sd.shown(cur['engine_id'])} holds the lease of account {sd.shown(acct)} until {cur['expires_at']}")
        return 1
    lease = {"account": acct, "engine_id": o["--engine"], "install_id": sd.install_id(), "lease_id": str(uuid.uuid4()),
             "acquired_at": time.strftime(TIME, time.gmtime(now)), "expires_at": time.strftime(TIME, time.gmtime(now + int(o["--ttl"])))}
    sd.checked(lease, "the new lease", "primary-lease")
    st[acct] = lease
    save(f, st)
    print(json.dumps(lease, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:   # never a traceback, never a value: the type only
        sd.say("STL-CFG-310", f"lease_double: {type(e).__name__}, an unexpected failure")
        sys.exit(1)
