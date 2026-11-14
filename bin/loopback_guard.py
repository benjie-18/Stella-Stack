#!/usr/bin/env python3
"""The loopback API guard (F1c B5/A5, design D6 incl. DG-4), stdlib only. The contract is data:
the index row loopback-api (endpoints {id, method, path, scope read|owner-write}, hosts, origins, the token, CSRF and owner-proof
header names, the owner-auth action class). No host, port, origin or header name is named in this file; the port is the one the
server is bound to (session.port).
Checks, in this order, the first failure is the answer: Host is an allowed host name with :<session port> (850); an Origin, when
present, is an allowed origin, on every method and scope (851); method + exact path is an endpoint (857); the API token (854); a
state-changing method (not GET, HEAD or OPTIONS) carries an Origin (852) and the CSRF token (853); an owner-write endpoint carries
an owner proof (855) that owner_auth.require accepts for the action {op: http, target: "<METHOD> <path>", old_digest: 64 zeros,
new_digest: sha256 of the raw body} (856, cause = the owner_auth code). The proof is verified, and its nonce spent, only when
every other check passed. A contract or session the guard cannot use refuses everything (858). A header sent twice matches
nothing. Header names are matched case-insensitively.
Library: check(method, path, headers, body, session, doc=None) -> (True, None) | (False, code); headers a dict (or name, value
         pairs), body bytes, session {api_token, csrf_token, port}, doc the contract (read from the index when None).
         judge(...) -> (code, cause, problem), all None when allowed; contract() -> the valid contract, else Refusal 858;
         report(code, problem) -> the catalog's plain message, after one alert line (no token, no header value).
CLI: loopback_guard.py check <request.json>   {method, path, headers, body (its UTF-8 bytes), session}: stdout
         {"ok": bool, "code": str|null[, "cause", "message"]}; exit 0 allowed, 1 refused (one alert line), 2 usage."""
import hashlib, hmac, json, os, sys
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import alert_catalog
import owner_auth
import stella_data as sd

CONTRACT = "loopback-api"   # the index row of the contract
SAFE = {"GET", "HEAD", "OPTIONS"}   # the methods that change no state (RFC 9110 9.2.1); every other one is state-changing
HEADERS = ("token_header", "csrf_header", "proof_header")
Refusal = owner_auth.Refusal


def contract():
    """The contract, valid (its schema, three distinct header names, each method + path once); else Refusal STL-OWN-858."""
    try:
        row = next(r for r in sd.rows() if r["id"] == CONTRACT)
        doc = sd.checked(sd.load(row["path"]), row["path"], row["schema"])
    except (sd.DataError, StopIteration) as e:
        raise Refusal("STL-OWN-858", str(e) or f"the index has no {CONTRACT} row") from None
    keys = [(e["method"], e["path"]) for e in doc["endpoints"]]
    if len({doc[k].lower() for k in HEADERS}) != len(HEADERS) or len(set(keys)) != len(keys):
        raise Refusal("STL-OWN-858", f"{row['path']}: the token, CSRF and proof headers need three distinct names, and each method + path one endpoint")
    return doc


def same(given, want):
    """A header value equals a session token (constant time; a missing or repeated header equals nothing)."""
    return isinstance(given, str) and hmac.compare_digest(given.encode("utf-8", "surrogatepass"), want.encode("utf-8", "surrogatepass"))


def judge(method, path, headers, body, session, doc=None):
    try:
        doc = doc or contract()
        tok, csrf, port = session["api_token"], session["csrf_token"], session["port"]
        if not (isinstance(tok, str) and tok and isinstance(csrf, str) and csrf and type(port) is int and 0 < port < 65536):
            raise TypeError
    except Refusal as r:
        return r.code, None, r.problem
    except (TypeError, KeyError):
        return "STL-OWN-858", None, "the session is not {api_token, csrf_token, port} (two non-empty strings and the bound port)"
    h = {}
    for k, v in headers.items() if isinstance(headers, dict) else headers:
        h[k.lower()] = None if k.lower() in h else v   # a repeated header matches nothing
    hosts = {(f"[{x}]" if ":" in x and not x.startswith("[") else x) + f":{port}" for x in doc["hosts"]}
    origins = {o.replace("{port}", str(port)).lower() for o in doc["origins"]}
    tok_h, csrf_h, proof_h = (doc[k].lower() for k in HEADERS)
    if not (isinstance(h.get("host"), str) and h["host"].lower() in hosts):
        return "STL-OWN-850", None, "the Host header is missing or is not an allowed loopback name with the server's port"
    if "origin" in h and not (isinstance(h["origin"], str) and h["origin"].lower() in origins):
        return "STL-OWN-851", None, "the Origin header names a page the contract does not allow"
    ep = next((e for e in doc["endpoints"] if e["method"] == method and e["path"] == path), None)
    if ep is None:
        return "STL-OWN-857", None, f"no endpoint of the contract is {sd.shown(f'{method} {path}'[:120])}"
    if not same(h.get(tok_h), tok):
        return "STL-OWN-854", None, "the API token is missing or wrong"
    if method not in SAFE and "origin" not in h:
        return "STL-OWN-852", None, f"a {sd.shown(method)} request changes state and carries no Origin"
    if method not in SAFE and not same(h.get(csrf_h), csrf):
        return "STL-OWN-853", None, f"a {sd.shown(method)} request changes state and its CSRF token is missing or wrong"
    if ep["scope"] != "owner-write":
        return None, None, None
    if proof_h not in h:
        return "STL-OWN-855", None, f"endpoint {ep['id']} is owner-write and the request carries no owner proof"
    action = {"op": "http", "target": f"{method} {path}", "old_digest": "0" * 64, "new_digest": hashlib.sha256(body).hexdigest()}
    try:
        owner_auth.require(doc["owner_class"], action, json.loads(h[proof_h]))
    except (TypeError, ValueError, RecursionError):
        return "STL-OWN-856", "STL-OWN-802", f"the owner proof of endpoint {ep['id']} is not JSON"
    except Refusal as r:
        return "STL-OWN-856", r.code, f"owner_auth refused the owner proof of endpoint {ep['id']}: {r.code} {r.problem}"
    return None, None, None


def check(method, path, headers, body, session, doc=None):
    code = judge(method, path, headers, body, session, doc)[0]
    return code is None, code


def report(code, problem):
    body, tag, kv = alert_catalog.render(code, {"problem": problem})
    alert_catalog.log(tag, kv)
    return body.split("\n")[1]


def main(argv):
    if len(argv) != 2 or argv[0] != "check":
        print(__doc__.split("CLI: ", 1)[1], file=sys.stderr)
        return 2
    try:
        q = sd.jload(argv[1])
        args = (q["method"], q["path"], q["headers"], q["body"].encode("utf-8", "surrogatepass"), q["session"])
        if not (isinstance(args[0], str) and isinstance(args[1], str) and isinstance(args[2], dict) and isinstance(args[4], dict)):
            raise TypeError
    except (sd.DataError, KeyError, TypeError, AttributeError) as e:
        print(f"loopback_guard.py check: the request file is not {{method, path, headers, body, session}} ({type(e).__name__})", file=sys.stderr)
        return 2
    code, cause, problem = judge(*args)
    out = {"ok": code is None, "code": code}
    if code:
        out.update({"cause": cause} if cause else {}, message=report(code, problem))
    print(json.dumps(out))
    return 0 if code is None else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
