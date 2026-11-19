#!/usr/bin/env python3
"""Per-run tokens (F3 item T; body B1 api; design section 2 with ruling DC-04), stdlib only. A CLI on an api link never holds the real
key: it holds a short-lived token minted for its run, and bin/model_proxy.py swaps it for the key on loopback. A token is minted for
EVERY run (api and cli-login); its record holds the link's connection type, and the proxy refuses a token whose link is no api link.
Token: the data prefix (.stella/run-gateway.json token.prefix, so a leak scanner can find one) + token.random_bytes random bytes,
urlsafe. Only sha256(token) is stored (index key run_tokens, a state path under the protected repo paths), with
{run, role, card, connection, model, type, minted, expires, revoked}; the value is printed once, by mint, and nowhere else.
CLI (host only: refuses in a worker environment, STL-CFG-312, before reading anything):
  run_token.py mint --run R --role ROLE --card C --link CONN/MODEL [--ttl S]   the token alone on stdout (ttl default token.ttl_s, at most token.max_ttl_s)
  run_token.py revoke --run R                                                 every token of the run is revoked; {run, revoked} on stdout
Importers: lookup(token) -> (record, None) or (None or record, code); verify(token) -> the record or None; tid(token) the id
events carry (a prefix of the hash, never the value).
Exit: 0 ok; 1 refused (the catalog code and its plain message on stderr); 2 usage."""
import os, sys

if __name__ == "__main__" and not sys.flags.isolated:   # run directly: PYTHONPATH and the current folder must not decide what is imported
    try:
        os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
    except OSError:
        sys.exit("STL-CFG-310 run_token.py could not restart itself isolated (python3 -I); nothing was minted")

import argparse, contextlib, datetime, hashlib, json, secrets

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import event_log as el
import stella_data as sd
import worker_env

UNKNOWN, EXPIRED, REVOKED, STORE = "STL-MDL-790", "STL-MDL-791", "STL-MDL-792", "STL-MDL-797"
BADLINK = "STL-MDL-799"   # mint: a link the catalog does not hold, or a ttl the data does not allow
ROW, KEY = "run-gateway", "run_tokens"   # the data row id and the index key of the token state
TIME = "%Y-%m-%dT%H:%M:%SZ"
ID_CHARS = 12   # hex characters of the hash an event line carries


class Stop(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def gateway():
    """The run-gateway data, schema-checked; Stop when it cannot be used."""
    try:
        row = next(r for r in sd.rows() if r["id"] == ROW)
        return sd.checked(sd.load(row["path"]), row["path"], row["schema"])
    except (sd.DataError, StopIteration, KeyError) as e:
        raise Stop(STORE, f"the run gateway data cannot be used: {str(e)[:160] or 'no index row'}") from None


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


def tid(token):
    return digest(token)[:ID_CHARS]


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)


@contextlib.contextmanager
def store(write=False):
    """The token state {schema_version, tokens {sha256: record}} under its lock; written whole when write and the block ended without error."""
    import route   # its write_whole: temp file, fsync, rename
    try:
        p = el.path(sd.load(sd.INDEX)[KEY])
        with el.locked(p + ".lock"):
            try:
                with os.fdopen(el.open_file(p, os.O_RDONLY), "rb") as f:
                    if os.fstat(f.fileno()).st_nlink != 1:
                        raise ValueError("has more than one hard link")
                    st = json.loads(f.read(el.MAX_FILE + 1))
            except FileNotFoundError:
                st = {"schema_version": 1, "tokens": {}}
            if not (isinstance(st, dict) and isinstance(st.get("tokens"), dict) and all(isinstance(v, dict) for v in st["tokens"].values())):
                raise ValueError("does not hold tokens")
            yield st
            if write:
                route.write_whole(p, st)
    except (OSError, ValueError, KeyError, RecursionError, sd.DataError) as e:
        raise Stop(STORE, f"the run token state cannot be used ({el.why(e)[:120] if isinstance(e, (OSError, ValueError)) else type(e).__name__})") from None


def lookup(token):
    """(record, None) for a token in force; (None, UNKNOWN) for one the state does not hold; (record, EXPIRED or REVOKED) otherwise."""
    if not isinstance(token, str) or not token:
        return None, UNKNOWN
    with store() as st:
        rec = st["tokens"].get(digest(token))
    if rec is None:
        return None, UNKNOWN
    if rec.get("revoked"):
        return rec, REVOKED
    exp = sd.when(rec, "expires")
    if not exp or exp <= now():   # an expiry that is no date counts as past (fail closed)
        return rec, EXPIRED
    return rec, None


def verify(token):
    rec, code = lookup(token)
    return None if code else rec


def cmd_mint(a):
    import route   # the catalog as a read serves it
    g = gateway()["token"]
    ttl = g["ttl_s"] if a.ttl is None else a.ttl
    if not 0 < ttl <= g["max_ttl_s"]:
        raise Stop(BADLINK, f"ttl {ttl} s is outside 1..{g['max_ttl_s']} s (run-gateway token.max_ttl_s)")
    conn, _, model = a.link.partition("/")
    try:
        prov, _ = route.model_of(route.data()[1], {"connection": conn, "model": model})
    except route.Stop as x:
        raise Stop(BADLINK, x.problem) from None
    token = g["prefix"] + secrets.token_urlsafe(g["random_bytes"])
    t = now()
    rec = {"run": a.run, "role": a.role, "card": a.card, "connection": prov["id"], "model": model, "type": prov.get("type"),
           "minted": t.strftime(TIME), "expires": (t + datetime.timedelta(seconds=ttl)).strftime(TIME), "revoked": None}
    with store(write=True) as st:
        for k in [k for k, v in st["tokens"].items() if (sd.when(v, "expires") or t) <= t]:   # expired records go: the file stays bounded
            del st["tokens"][k]
        st["tokens"][digest(token)] = rec
    el.append(el.build("run-token.minted", f"run {a.run}", new={"token_id": tid(token), **{k: rec[k] for k in ("card", "connection", "model", "type", "expires")}},
                       who={"role": a.role}))
    print(token)
    return 0


def cmd_revoke(a):
    t = now().strftime(TIME)
    with store(write=True) as st:
        hit = [k for k, v in st["tokens"].items() if v.get("run") == a.run and not v.get("revoked")]
        for k in hit:
            st["tokens"][k]["revoked"] = t
    if hit:
        el.append(el.build("run-token.revoked", f"run {a.run}", new={"token_ids": [k[:ID_CHARS] for k in hit]}))
    print(json.dumps({"run": a.run, "revoked": len(hit)}))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="run_token.py", description="Per-run tokens for the model proxy (host only).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("mint")
    for k in ("run", "role", "card", "link"):
        p.add_argument("--" + k, required=True)
    p.add_argument("--ttl", type=int)
    sub.add_parser("revoke").add_argument("--run", required=True)
    a = ap.parse_args(argv)
    try:
        w = worker_env.reason()
        if w:
            raise Stop(sd.Refused.code, f"run_token.py {a.cmd} runs on the host only ({w}); nothing was read")
        return {"mint": cmd_mint, "revoke": cmd_revoke}[a.cmd](a)
    except Stop as x:
        return el.fail(x.code, x.problem)
    except el.EventError as e:
        return el.fail(e.code, e.problem, e.extra)
    except sd.DataError as e:
        return el.fail(getattr(e, "code", "STL-CFG-310"), str(e)[:180])
    except Exception as e:   # never a traceback: the type only
        return el.fail("STL-CFG-310", f"{type(e).__name__}, an unexpected failure of run_token.py {a.cmd}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
