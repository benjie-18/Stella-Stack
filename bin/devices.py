#!/usr/bin/env python3
"""The device registry (F1c B6, design D5), stdlib only. Paired devices are the entries of the index row `devices` (owner_only);
each is an owner-authenticator through the device-signature provider of the owner-auth policy (bin/owner_auth.py): it signs
canonical {digest, nonce, expires_at, device_id[, phrase]} with its Ed25519 key, checked here with `<openssl> pkeyutl -verify -rawin`
(openssl: the provider's params.openssl, an absolute path; never looked up on PATH).
Pairing and revoking are owner writes of that row through `stella-apply.py apply devices --from <file>` (identity-critical: the
owner key and the typed phrase, or a paired device with its signed phrase); this tool never writes.
Library: registry() -> (path, entries), valid; entry(device_id) -> the entry (id or global_id) or None;
         verify(pem, msg, sig_b64, timeout, openssl).
CLI: devices.py list [--json]     the entries (--json: a JSON array of the entries)
     devices.py check [--json]    the registry is valid: its schema, each id once, every public key an Ed25519 key
Exit 1 with STL-CFG-310 and the problem when the registry is invalid (check --json also prints {ok, problems}); exit 2: usage."""
import base64, json, os, re, subprocess, sys, tempfile
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import stella_data as sd

ROW = "devices"
SPKI = bytes.fromhex("302a300506032b6570032100")   # the DER head of an Ed25519 SubjectPublicKeyInfo; the 32 key bytes follow
PEM = re.compile(r"-----BEGIN PUBLIC KEY-----\n([A-Za-z0-9+/=\n]+)-----END PUBLIC KEY-----\n?")


def ed25519(pem):
    """Whether pem is one Ed25519 public key (PEM SubjectPublicKeyInfo)."""
    m = PEM.fullmatch(pem) if isinstance(pem, str) else None
    try:
        der = base64.b64decode(m.group(1).replace("\n", ""), validate=True) if m else b""
    except ValueError:
        return False
    return len(der) == len(SPKI) + 32 and der.startswith(SPKI)


def problems(ents):
    ids = [e["id"] for e in ents]
    out = [f"device {sd.shown(i)} is listed twice" for i in sorted({i for i in ids if ids.count(i) > 1})]
    return out + [f"device {sd.shown(e['id'])}: public_key is not an Ed25519 public key" for e in ents if not ed25519(e["public_key"])]


def registry():
    """(path, entries) of the registry: schema-valid, each id once, Ed25519 keys only; else sd.DataError (fails closed)."""
    row = next((r for r in sd.rows() if r["id"] == ROW), None)
    if row is None or row["list_key"] is None:
        raise sd.DataError(f"the index has no {ROW} row with a list key")
    ents = sd.checked(sd.load(row["path"]), row["path"], row["schema"])[row["list_key"]]
    bad = problems(ents)
    if bad:
        raise sd.DataError(f"{row['path']}: {bad[0]}" + (f" (and {len(bad) - 1} more)" if len(bad) > 1 else ""))
    return row["path"], ents


def entry(device_id):
    return sd.entry({e["id"]: e for e in registry()[1]}, device_id)


def verify(pem, msg, sig_b64, timeout, openssl):
    """Whether sig_b64 (standard base64 of a raw 64-byte Ed25519 signature) signs the bytes msg under the public key pem, by the
    openssl at the absolute path openssl (a relative one is refused: no PATH lookup). OSError or subprocess.TimeoutExpired when it
    cannot run."""
    if not openssl.startswith("/"):
        raise OSError("the openssl path is not absolute")
    try:
        sig = base64.b64decode(sig_b64, validate=True) if isinstance(sig_b64, str) else b""
    except ValueError:
        return False
    if len(sig) != 64 or not ed25519(pem):
        return False
    with tempfile.TemporaryDirectory() as d:
        files = {"key": pem.encode(), "msg": msg, "sig": sig}
        for n, b in files.items():
            with open(os.path.join(d, n), "wb") as f:
                f.write(b)
        k, m, s = (os.path.join(d, n) for n in files)
        r = subprocess.run([openssl, "pkeyutl", "-verify", "-pubin", "-inkey", k, "-rawin", "-in", m, "-sigfile", s],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)
    return r.returncode == 0


def main(argv):
    cmd, args = (argv[0] if argv else ""), argv[1:]
    if cmd not in ("list", "check") or args not in ([], ["--json"]):
        print(__doc__.split("CLI: ", 1)[1].split("Exit 1")[0], file=sys.stderr)
        return 2
    try:
        path, ents = registry()
    except sd.DataError as e:
        if cmd == "check" and args:
            print(json.dumps({"ok": False, "problems": [str(e)]}, indent=2, ensure_ascii=False))
        sd.say("STL-CFG-310", str(e))
        return 1
    if cmd == "check":
        print(json.dumps({"ok": True, "problems": [], "devices": len(ents)}, indent=2) if args else f"{path}: {len(ents)} devices, OK")
    else:
        sd.emit(ents, bool(args), lambda e: f"{e['id']}\t{e['kind']}\t{e['role']}\tpaired {e['paired_at']}\t"
                + (f"revoked {e['revoked_at']}" if e["revoked_at"] else "active"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:   # never a traceback, never a value: the type only
        sd.say("STL-CFG-310", f"devices: {type(e).__name__}, an unexpected failure")
        sys.exit(1)
