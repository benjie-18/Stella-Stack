#!/usr/bin/env python3
"""The owner-authenticator (F1c B1/B3, design D2), stdlib only. Which proofs an owner action needs is data: the owner-auth policy
(index row owner-auth) lists providers {id, kind, params, enabled} and, per action class, alternatives (lists of provider ids that
must all pass; one passing alternative is enough). The kinds are code: local-key, channel-identity, command, typed-phrase,
device-phrase, device-signature (a paired device of bin/devices.py signed the request). No provider, class or path is named in this
file. Every accepted device-signed request is a remote owner change: it counts toward the policy's remote.rate_limit (the next one
past it is STL-OWN-813) and writes one alert with remote.alert_code.
An action is {op, target, old_digest, new_digest | new}; its digest is the sha256 of its canonical JSON. A proof is {provider, digest,
nonce, expires_at, ...its kind's fields}; it counts once: its nonce is recorded under the index approval_store (<store>/nonces).
Library: require(action_class, action, proofs, bound=None, show=None) -> the provider ids used, or raises Refusal(code, problem);
         digest(action); phrase(action); prove(action_class, action, provider=None, ttl=None) -> a proof.
         bound: what the CALLER knows about a channel answer (never taken from the proof): {channel_kind, message_ref} of the
         message the request was delivered as. show: the text the typed-phrase provider shows above the phrase (target, old -> new,
         secrets masked).
CLI: owner_auth.py check                    the policy is valid (schema, ids, params of each kind)
     owner_auth.py providers [--json]       the providers (id, kind, enabled)
     owner_auth.py init-key                 create the owner key at the index owner_key, 0600; never overwrites (setup, on the host)
     owner_auth.py prove --class C --action F [--provider ID] [--ttl S]
                                            a proof for the action in file F: by the first enabled local-key provider, or by
                                            ID (local-key, or a command provider's envelope: no key read); S seconds, at most the
                                            policy's proof_ttl_s
     owner_auth.py verify --class C --action F --proof P
                                            the proof (or list of proofs) in P meets an alternative of class C: prints the
                                            provider ids used, and the nonces are spent
Refused (exit 1, the code and its plain message, one alert line): init-key, prove and verify in a worker environment
(bin/worker_env.py), STL-CFG-312; an invalid policy, STL-CFG-310; STL-OWN-801..809, 811..813 (docs/alert-codes.md). Exit 2: usage, or an
action file that is not an action. The key never appears in any output."""
import datetime, fcntl, hashlib, hmac, json, os, re, secrets, signal, stat, subprocess, sys, time
BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import alert_catalog
import devices
import owner_config as oc
import stella_data as sd
import worker_env

POLICY = worker_env.POLICY
HEX64, NONCE = re.compile(r"[0-9a-f]{64}"), re.compile(r"[0-9a-f]{32}")
TIME = "%Y-%m-%dT%H:%M:%SZ"
ENVELOPE = ("provider", "digest", "nonce", "expires_at")
PARAMS = {"local-key": set(), "channel-identity": {"channel_kind", "owner_config_key"}, "command": {"argv", "timeout_s"},
          "typed-phrase": set(), "device-phrase": set(), "device-signature": {"timeout_s"}}
PROVED = {"local-key", "channel-identity", "command", "device-signature"}   # kinds whose pass is a proof object; the others decide at verify time
SIGNED = {"device-signature"}   # kinds whose proof is signed by the owner's device and may carry the phrase


class Refusal(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def canon(x):
    return json.dumps(x, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def digest(action):
    """sha256 of the action's canonical JSON; a ValueError for anything that is not an action."""
    a = action
    ok = (isinstance(a, dict) and set(a) <= {"op", "target", "old_digest", "new_digest", "new"} and ("new" in a) != ("new_digest" in a)
          and all(isinstance(a.get(k), str) and a[k] for k in ("op", "target"))
          and all(isinstance(a.get(k), str) and HEX64.fullmatch(a[k]) for k in ("old_digest", "new_digest") if k in a or k == "old_digest"))
    if not ok:
        raise ValueError("an action is {op, target, old_digest, new_digest | new} (digests: 64 lower-case hex characters)")
    return hashlib.sha256(canon(a).encode()).hexdigest()


def problems(doc):
    """What the schema cannot say: each provider id once, the params of its kind, every id of an alternative a provider, a
    device-phrase only beside a device-signed provider. No value of the data is quoted but the policy's own ids."""
    ids = [p["id"] for p in doc["providers"]]
    kinds = {p["id"]: p["kind"] for p in doc["providers"]}
    out = [f"provider {i} is listed twice" for i in sorted({i for i in ids if ids.count(i) > 1})]
    for p in doc["providers"]:
        if set(p["params"]) != PARAMS[p["kind"]]:
            out.append(f"provider {p['id']}: a {p['kind']} provider takes params {', '.join(sorted(PARAMS[p['kind']])) or 'none'}")
        elif p["kind"] == "command" and not p["params"]["argv"][0].startswith("/"):
            out.append(f"provider {p['id']}: argv[0] is an absolute path")
    for c, alts in doc["actions"].items():
        for n, alt in enumerate(alts):
            out += [f"actions.{c}[{n}]: {sd.desc(i)} is not a provider" for i in alt if i not in kinds]
            if not any(kinds.get(i) in PROVED | SIGNED for i in alt):
                out.append(f"actions.{c}[{n}]: an alternative holds at least one provider whose pass is a proof (a phrase alone proves no owner)")
            if any(kinds.get(i) == "device-phrase" for i in alt) and not any(kinds.get(i) in SIGNED for i in alt):
                out.append(f"actions.{c}[{n}]: a device-phrase provider stands only beside a device-signature provider (it checks the phrase that device signed)")
    if any(k in SIGNED for k in kinds.values()):
        if "remote" not in doc:
            out.append("a device-signature provider needs remote (the rate limit and alert of remote owner changes)")
        elif doc["remote"]["alert_code"] not in alert_catalog.catalog():
            out.append("remote.alert_code is not a code of the alert catalog")
    return out


def policy():
    """The policy, valid; else Refusal STL-CFG-310 (unknown or broken data fails closed)."""
    try:
        rel = next(r["path"] for r in sd.rows() if r["id"] == POLICY)
        doc = sd.checked(sd.load(rel), rel, POLICY)
    except (sd.DataError, StopIteration) as e:
        raise Refusal("STL-CFG-310", str(e) or f"the index has no {POLICY} row") from None
    bad = problems(doc)
    if bad:
        raise Refusal("STL-CFG-310", f"{rel}: {bad[0]}" + (f" (and {len(bad) - 1} more)" if len(bad) > 1 else ""))
    return doc


def phrase(action, pol=None):
    """The confirmation phrase of an action: the policy's template with {what} = the action's target."""
    return (pol or policy())["phrase"]["template"].replace("{what}", action["target"])


def need_host(what):
    why = worker_env.reason()
    if why:
        raise Refusal("STL-CFG-312", f"{what} is the owner's: {why}")


def state(key, code):
    """Absolute path of an index state path (owner_key, approval_store): no symbolic link in any folder on the way below the
    root; else Refusal(code)."""
    try:
        rel = sd.spelled(sd.checked(sd.load(sd.INDEX), sd.INDEX, "data-files")[key])
        head, tail = os.path.split(os.path.normpath(rel))
        return os.path.join(sd.plain(head) if head else sd.ROOT, tail)
    except sd.DataError as e:
        raise Refusal(code, f"the index {key} path cannot be used: {e}") from None


def key_path():
    return state("owner_key", "STL-OWN-806")


def read_key():
    try:   # O_NOFOLLOW: a link is refused, never followed; O_NONBLOCK: a fifo planted there does not hang
        fd = os.open(key_path(), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise Refusal("STL-OWN-806", "there is no owner key yet (owner_auth.py init-key, on the host, as the owner)") from None
    except OSError as e:
        raise Refusal("STL-OWN-806", f"the owner key cannot be opened safely ({type(e).__name__}); it must be a plain file, not a link") from None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o600 or st.st_uid != os.geteuid() or st.st_nlink != 1:
            raise Refusal("STL-OWN-806", "the owner key is unsafe: it must be a plain file of this user, mode 0600, with one link")
        raw = os.read(fd, 256).strip()
    finally:
        os.close(fd)
    if not HEX64.fullmatch(raw.decode("ascii", "replace")):
        raise Refusal("STL-OWN-806", "the owner key file does not hold a key")
    return bytes.fromhex(raw.decode())


def init_key():
    need_host("creating the owner key")
    p = key_path()
    if os.path.islink(p):   # a dangling link too: never written through
        raise Refusal("STL-OWN-806", "the owner key path is a symbolic link; remove it, then run init-key again")
    os.makedirs(os.path.dirname(p), mode=0o700, exist_ok=True)
    try:   # O_EXCL: never over an existing file nor through a link that appears meanwhile
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        raise Refusal("STL-OWN-807", "an owner key already exists; init-key never overwrites it") from None
    try:
        os.fchmod(fd, 0o600)   # whatever the umask
        os.write(fd, (secrets.token_hex(32) + "\n").encode())
        os.fsync(fd)
    except BaseException:
        os.unlink(p)
        raise
    finally:
        os.close(fd)


def mac(key, proof):
    return hmac.new(key, canon({k: proof[k] for k in ENVELOPE}).encode(), hashlib.sha256).hexdigest()


def prove(cls, action, provider=None, ttl=None):
    """A proof for the action: a local-key provider's (the key is read), or a command provider's envelope for its command to judge."""
    need_host("an owner proof")
    pol, dg = policy(), digest(action)
    if cls not in pol["actions"]:
        raise Refusal("STL-OWN-801", f"there is no action class {sd.shown(cls)} in the owner-auth policy")
    ps = pol["providers"]
    p = next((x for x in ps if x["id"] == provider), None) if provider else next((x for x in ps if x["kind"] == "local-key" and x["enabled"]), None)
    if p is None or not p["enabled"] or p["kind"] not in ("local-key", "command"):
        raise Refusal("STL-OWN-801", f"{'provider ' + sd.shown(provider) if provider else 'no local-key provider'} is unknown, switched off, or does not make proofs on the host")
    ttl = pol["proof_ttl_s"] if ttl is None else ttl
    if not 1 <= ttl <= pol["proof_ttl_s"]:
        raise ValueError(f"--ttl is 1 to {pol['proof_ttl_s']} seconds (the policy's proof_ttl_s)")
    out = {"provider": p["id"], "digest": dg, "nonce": secrets.token_hex(16),
           "expires_at": time.strftime(TIME, time.gmtime(int(time.time()) + ttl))}
    if p["kind"] == "local-key":
        out["mac"] = mac(read_key(), out)
    return out


# ---- verifying: one function per kind (prov, proof or None, ctx) -> None, or raises Refusal ----
def v_local_key(prov, proof, ctx):
    if set(proof) != {*ENVELOPE, "mac"} or not isinstance(proof["mac"], str) or not hmac.compare_digest(proof["mac"].encode(), mac(read_key(), proof).encode()):
        raise Refusal("STL-OWN-802", f"the {prov['id']} proof does not match its fields")


def v_channel_identity(prov, proof, ctx):
    b, want = ctx["bound"], oc.get(prov["params"]["owner_config_key"])
    if not (isinstance(b, dict) and b.get("channel_kind") == prov["params"]["channel_kind"] and isinstance(b.get("message_ref"), str) and b["message_ref"]):
        raise Refusal("STL-OWN-802", f"a {prov['id']} answer counts only bound to the message its request was delivered as on a {prov['params']['channel_kind']} channel, and none was bound")
    if not (want and isinstance(proof.get("user"), str) and hmac.compare_digest(proof["user"].encode(), want.encode())):
        raise Refusal("STL-OWN-802", f"the {prov['id']} answer is not from the owner's user id")
    if not (isinstance(proof.get("message_ref"), str) and hmac.compare_digest(proof["message_ref"].encode(), b["message_ref"].encode())):
        raise Refusal("STL-OWN-802", f"the {prov['id']} answer is not on the message the request was delivered as")


def v_command(prov, proof, ctx):
    argv, limit = prov["params"]["argv"], prov["params"]["timeout_s"]
    try:   # its own session: a timeout kills the command and everything it started
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        raise Refusal("STL-OWN-809", f"the {prov['id']} command cannot start ({type(e).__name__})") from None
    try:
        p.communicate(canon({"class": ctx["cls"], "proof": proof}).encode(), timeout=limit)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
        raise Refusal("STL-OWN-809", f"the {prov['id']} command ran past its timeout_s ({limit} s)") from None
    if p.returncode != 0:
        raise Refusal("STL-OWN-809", f"the {prov['id']} command did not accept the proof (exit {p.returncode})")


def v_typed_phrase(prov, proof, ctx):
    want = phrase(ctx["action"], ctx["pol"])
    try:
        out, inp = open("/dev/tty", "w", encoding="utf-8"), open("/dev/tty", "r", encoding="utf-8")   # a terminal is not seekable: no "r+"
    except OSError:
        raise Refusal("STL-OWN-808", "there is no terminal to type the confirmation phrase on") from None
    with out, inp:
        out.write(f"{ctx['show'] or ctx['action']['target']}\nType \"{want}\" to confirm: ")
        out.flush()
        got = inp.readline().rstrip("\r\n")
    if got != want:
        raise Refusal("STL-OWN-808", "the typed confirmation phrase is not the one shown")


def v_device_phrase(prov, proof, ctx):
    want, signed = phrase(ctx["action"], ctx["pol"]), [x for k, x in ctx["used"] if k in SIGNED]
    if not signed or any(x.get("phrase") != want for x in signed):
        raise Refusal("STL-OWN-808", "no device-signed confirmation phrase equal to the one for this change")


def v_device_signature(prov, proof, ctx):
    if not (set(proof) - {"phrase"} == {*ENVELOPE, "device_id", "signature"} and all(isinstance(proof[k], str) for k in proof)):
        raise Refusal("STL-OWN-802", f"the {prov['id']} proof is not a device-signed request (device_id, signature[, phrase])")
    try:
        dev = devices.entry(proof["device_id"])
    except sd.DataError as e:
        raise Refusal("STL-CFG-310", str(e)) from None
    if dev is None:
        raise Refusal("STL-OWN-811", f"device {sd.shown(proof['device_id'])} is not in the device registry")
    if dev["revoked_at"] is not None:
        raise Refusal("STL-OWN-812", f"device {dev['id']} was revoked at {dev['revoked_at']}")
    signed = canon({k: proof[k] for k in ("digest", "nonce", "expires_at", "device_id", "phrase") if k in proof}).encode()
    try:
        good = devices.verify(dev["public_key"], signed, proof["signature"], prov["params"]["timeout_s"])
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Refusal("STL-OWN-809", f"the {prov['id']} signature check (openssl) could not run ({type(e).__name__})") from None
    if not good:
        raise Refusal("STL-OWN-802", f"the {prov['id']} proof is not signed by the key of device {dev['id']}")
    ctx["devices"].append(dev["id"])


VERIFY = {"local-key": v_local_key, "channel-identity": v_channel_identity, "command": v_command,
          "typed-phrase": v_typed_phrase, "device-phrase": v_device_phrase, "device-signature": v_device_signature}


def when(s):
    try:
        return datetime.datetime.strptime(s, TIME).replace(tzinfo=datetime.timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def require(cls, action, proofs, bound=None, show=None):
    """The provider ids of the first alternative of class cls the proofs meet, every check passed and every nonce spent; else
    Refusal. Order per proof: provider allowed (801), valid (802/806/809), for this action (805), not expired (803), unused (804);
    then the phrase providers (808), the typed phrase last; then the nonces are spent (804 if one was spent meanwhile), and a
    device-signed request is a remote owner change: within remote.rate_limit (813), then one remote.alert_code alert."""
    need_host("an owner proof")
    pol, dg = policy(), digest(action)
    proofs = [proofs] if isinstance(proofs, dict) else proofs
    provs = {p["id"]: p for p in pol["providers"]}
    alts = pol["actions"].get(cls)
    if alts is None:
        raise Refusal("STL-OWN-801", f"there is no action class {sd.shown(str(cls))} in the owner-auth policy")
    given = {}
    for x in proofs if isinstance(proofs, list) else [None]:
        if not (isinstance(x, dict) and isinstance(x.get("provider"), str)):
            raise Refusal("STL-OWN-802", "a proof is not an object naming its provider")
        p = provs.get(x["provider"])
        if p is None or not p["enabled"] or p["kind"] not in PROVED or not any(p["id"] in a for a in alts):
            raise Refusal("STL-OWN-801", f"provider {sd.shown(x['provider'])} is unknown, switched off, or not allowed for {cls}")
        given.setdefault(p["id"], x)
    alt = next((a for a in alts if all(provs[i]["enabled"] and (provs[i]["kind"] not in PROVED or i in given) for i in a)), None)
    if alt is None:
        raise Refusal("STL-OWN-801", f"the proofs given meet no alternative of {cls}")
    ctx = {"cls": cls, "action": action, "pol": pol, "bound": bound, "show": show, "used": [], "devices": []}
    nonces = os.path.join(store_dir(), "nonces")
    for i in [i for i in alt if i in given]:
        x, p = given[i], provs[i]
        if not (isinstance(x.get("digest"), str) and HEX64.fullmatch(x["digest"]) and isinstance(x.get("nonce"), str) and NONCE.fullmatch(x["nonce"])
                and when(x.get("expires_at")) is not None and when(x["expires_at"]) <= time.time() + pol["proof_ttl_s"]):
            raise Refusal("STL-OWN-802", f"the {i} proof is not well formed (digest, nonce, expires_at within proof_ttl_s)")
        VERIFY[p["kind"]](p, x, ctx)
        if x["digest"] != dg:
            raise Refusal("STL-OWN-805", f"the {i} proof is for another action")
        if when(x["expires_at"]) <= time.time():
            raise Refusal("STL-OWN-803", f"the {i} proof expired")
        if os.path.lexists(os.path.join(nonces, x["nonce"])):
            raise Refusal("STL-OWN-804", f"the {i} proof was already used")
        ctx["used"].append((p["kind"], x))
    for i in sorted((i for i in alt if i not in given), key=lambda i: provs[i]["kind"] == "typed-phrase"):   # the owner types last
        VERIFY[provs[i]["kind"]](provs[i], None, ctx)
    os.makedirs(nonces, mode=0o700, exist_ok=True)
    if ctx["devices"]:
        remote_change(pol, ctx, nonces)
    else:
        spend(ctx["used"], nonces)
    return list(alt)


def spend(used, nonces):
    for _, x in used:
        try:   # O_EXCL: two verifications racing for one proof, one wins
            os.close(os.open(os.path.join(nonces, x["nonce"]), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600))
        except FileExistsError:
            raise Refusal("STL-OWN-804", f"the {x['provider']} proof was already used") from None
    # shortcut: spent nonces stay forever (one empty file each); prune those past their expiry when the store grows large


def remote_change(pol, ctx, nonces):
    """An accepted device-signed request: one more remote owner change in <store>/remote (one file per change, named
    <epoch>-<nonce>; a name that is not that counts as recent), refused STL-OWN-813 at remote.rate_limit within its window; else
    the nonces are spent and one alert with remote.alert_code is written."""
    lim, d = pol["remote"]["rate_limit"], os.path.join(store_dir(), "remote")
    os.makedirs(d, mode=0o700, exist_ok=True)
    fd = os.open(d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)   # two racing requests never both take the last place
        now, recent = int(time.time()), []
        for n in os.listdir(d):
            t = n.split("-", 1)[0]
            if t.isdigit() and int(t) <= now - lim["window_s"]:
                os.unlink(os.path.join(d, n))
            else:
                recent.append(n)
        if len(recent) >= lim["count"]:
            raise Refusal("STL-OWN-813", f"{len(recent)} remote owner changes in the last {lim['window_s']} s, the limit is {lim['count']}")
        spend(ctx["used"], nonces)
        os.close(os.open(os.path.join(d, f"{now}-{ctx['used'][0][1]['nonce']}"), os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600))
    finally:
        os.close(fd)
    sd.say(pol["remote"]["alert_code"], f"{ctx['action']['op']} {ctx['action']['target']} ({ctx['cls']}), signed by device {', '.join(ctx['devices'])}", alert=True)


def store_dir():
    return state("approval_store", "STL-CFG-310")


# ---- CLI ----
def opts(args, allowed, needed):
    o, it = {}, iter(args)
    for a in it:
        v = next(it, None)
        if a not in allowed or a in o or v is None:
            raise ValueError(f"unknown, repeated or empty option {sd.shown(a)}")
        o[a] = v
    if not needed <= set(o):
        raise ValueError(f"needs {', '.join(sorted(needed))}")
    return o


def action_file(f):
    try:
        a = sd.jload(f)
    except sd.DataError as e:
        raise ValueError(str(e)) from None
    digest(a)
    return a


def main(argv):
    cmd, args = (argv[0] if argv else ""), argv[1:]
    try:
        if cmd == "check" and not args:
            policy()
            print("owner-auth policy OK")
            return 0
        if cmd == "providers" and args in ([], ["--json"]):
            out = [{"id": p["id"], "kind": p["kind"], "enabled": p["enabled"]} for p in policy()["providers"]]
            print(json.dumps(out, indent=2) if args else "\n".join(f"{p['id']}\t{p['kind']}\t{'on' if p['enabled'] else 'off'}" for p in out))
            return 0
        if cmd == "init-key" and not args:
            init_key()
            print("owner key created (index owner_key), mode 0600")
            return 0
        if cmd == "prove":
            o = opts(args, {"--class", "--action", "--provider", "--ttl"}, {"--class", "--action"})
            ttl = o.get("--ttl")
            if ttl is not None and not re.fullmatch(r"[0-9]{1,6}", ttl):
                raise ValueError("--ttl is a whole number of seconds")
            print(json.dumps(prove(o["--class"], action_file(o["--action"]), o.get("--provider"), ttl and int(ttl)), indent=2))
            return 0
        if cmd == "verify":
            o = opts(args, {"--class", "--action", "--proof"}, {"--class", "--action", "--proof"})
            a = action_file(o["--action"])
            try:
                proofs = sd.jload(o["--proof"])
            except sd.DataError:
                raise Refusal("STL-OWN-802", "the proof file cannot be read as JSON") from None
            print("verified by: " + ", ".join(require(o["--class"], a, proofs)))
            return 0
    except Refusal as r:
        sd.say(r.code, r.problem, alert=True)
        return 1
    except ValueError as e:   # an option, the ttl or the action file: usage
        print(f"owner_auth.py {cmd}: {e}", file=sys.stderr)
        return 2
    print(__doc__.split("CLI: ", 1)[1].split("Refused")[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:   # never a traceback, never a value: the type only
        sd.say("STL-CFG-310", f"owner_auth: {type(e).__name__}, an unexpected failure")
        sys.exit(1)
