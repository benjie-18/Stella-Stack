# Loopback API: read scope, owner-write scope, Host, Origin and CSRF

The local HTTP API (built in E1) is defined now so every loopback surface checks requests the same way (F1c body B5/A5,
design D6 incl. DG-4). A web page in the owner's browser must not be able to drive it, DNS rebinding included, and an owner
write needs an owner proof: the API token alone is never enough.

## The contract (data)

`.stella/loopback-api.json` (index row `loopback-api`, owner-only, schema `.stella/schemas/loopback-api.schema.json`;
check it with `python3 bin/stella_data.py check loopback-api`):

- `endpoints[]`: `id`, `method` (matched exactly), `path` (matched exactly: a trailing slash or a query string is another
  path), `scope` `read` or `owner-write`, `global_id`, `install_id`. A new endpoint is a new row: no code change, the
  server reads the contract when it starts.
- `hosts`: the loopback names a Host header may carry (`127.0.0.1`, `localhost`, `::1` / `[::1]`), each with `:<port>`.
- `port_source`: `bound`, the port is the one the server is bound to (`session.port`); no port is fixed anywhere.
- `origins`: the Origin values accepted, `{port}` standing for the bound port; no wildcard, no `null`.
- `token_header`, `csrf_header`, `proof_header`: the three header names (distinct).
- `owner_class`: the owner-auth policy action class an owner-write proof must meet (`.stella/owner-auth.json`).

## The checks, in order (the first failure is the answer)

| code | refused when |
|---|---|
| STL-OWN-850 | Host is missing, or is not an allowed host name with `:<bound port>` (a rebinding name, another port, no port) |
| STL-OWN-851 | an Origin is present and not allowed (`null` included), on every method and scope (DG-4) |
| STL-OWN-857 | the method + exact path is not an endpoint (unknown fails closed) |
| STL-OWN-854 | the API token is missing or wrong, on every scope (read included) |
| STL-OWN-852 | a state-changing request (any method but GET, HEAD, OPTIONS) carries no Origin |
| STL-OWN-853 | a state-changing request's CSRF token is missing or wrong |
| STL-OWN-855 | an owner-write endpoint and no owner proof |
| STL-OWN-856 | the owner proof is not JSON, or `owner_auth.require` refuses it; the answer's `cause` is the owner_auth code (805 another action or body, 804 replay, 803 expired, 802 invalid, 801 provider not allowed) |
| STL-OWN-858 | the guard cannot judge: the contract is missing or invalid, the session is incomplete, or the request cannot be read (everything is refused) |
| STL-OWN-859 | the test double cannot bind its port |

A header sent twice matches nothing. Header names are matched case-insensitively, tokens in constant time. The owner proof
is verified, and its nonce spent, only for a request that passed every other check: a refused request never spends a proof.

## The owner proof

The `proof_header` value is the compact JSON of a proof (or a list of proofs) made on the host:
`bin/owner_auth.py prove --class <owner_class> --action <file>`, over the action

    {"op": "http", "target": "<METHOD> <path>", "old_digest": "<64 x 0>", "new_digest": "<sha256 of the raw body bytes>"}

so a proof counts once, for one method, path and body. The header is outside the body, so the body digest does not cover it.

## The pieces

- `bin/loopback_guard.py`: the guard the real API calls. Library `check(method, path, headers, body, session)` ->
  `(True, None)` or `(False, "STL-OWN-85x")`; `judge()` also gives the cause and the problem text; `report()` writes the
  one alert line and returns the plain message. CLI `loopback_guard.py check <request.json>` (`{method, path, headers, body,
  session}`): stdout `{"ok", "code"[, "cause", "message"]}`, exit 0 allowed, 1 refused.
- `bin/loopback-api-double.py --port 0 --session <file>`: the test double. Binds the IPv4 loopback address only, prints the
  bound port on its first line, answers an allowed request HTTP 200 `{"ok": true, "endpoint": id}` with no side effect and a
  refused one HTTP 403 (404 for 857) `{"ok": false, "code"[, "cause"], "message"}` plus one alert line. No CORS header.
- `bin/loopback-selftest.sh`: the contract against the double over real HTTP (the tester's T5a cases).

No answer, output or alert line holds the API token or the CSRF token.
