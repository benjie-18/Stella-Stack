#!/usr/bin/env python3
"""The one interface for keys (F2 B8, design D3 with design-check DC-05), stdlib only, until the secrets broker (phase B1) replaces
it. The backend is data: `credentials` of the routing data. A backend that is not a folder (the shipped one) holds no key: every read
is refused. A folder backend (a test backend) keeps one file per secret name in a folder inside a protected state path (`check` of
bin/stella_data.py refuses any other place): this user's, mode 0600, one hard link, no symbolic link on its way, holding the value as
one line of printable ASCII with no line break.
Importers: get(name) -> the value, in-process only (bin/route.py puts it into the request header and nowhere else);
check(names) -> True only when the backend holds keys and every name, False for anything else (the resolver asks it for an
aggregator's broker entries; a plain yes or no that raises no refusal); state(names) -> {backend, kind, ok, missing}; never a value.
Nothing is read in a worker environment (bin/worker_env.py): get and state refuse, check says no. A key never reaches a worker,
and no value is in any message, log or error.
CLI: credentials.py check [--json] [<name>...]   the state; exit 0 when the backend holds keys and every name asked for, else 1; 2 usage.
There is no command that prints a value.
Refusals (class Refused: code, problem): STL-MDL-728 the key was not read (why, never the value); STL-CFG-312 a worker environment;
STL-CFG-310 the routing data is refused by check."""
import functools, json, os, re, stat, sys

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)   # python3 -I does not add the script folder
import event_log as el
import stella_data as sd
import worker_env

NOT_READ = "STL-MDL-728"
FOLDER = "dir"   # the backend kind that holds keys: one file per name
NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}")   # a secret's name is one file name: no folder part, no leading dot
MAX = 1 << 16   # bytes of a key file; a longer one is no key


class Refused(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


@functools.lru_cache(maxsize=None)
def backend():
    """(id, entry) of the backend in use; Refused in a worker environment, or while check refuses the routing data."""
    try:
        w = worker_env.reason()
    except Exception:
        w = "it cannot be told that this is not a worker"
    if w:
        raise Refused(sd.Refused.code, f"the key store is the owner's ({w}); nothing was read")
    try:
        cr = sd.routing()["credentials"]
    except sd.DataError as e:
        raise Refused("STL-CFG-310", str(e)[:180])
    return cr["backend"], cr["backends"][cr["backend"]]


def get(name):
    """The value of the secret `name`, or Refused; the caller never prints or logs it."""
    bid, b = backend()
    if b["kind"] != FOLDER:
        raise Refused(NOT_READ, f"key store backend {sd.idn(bid, True)} holds no key (nothing is read until the secrets broker)")
    if not (isinstance(name, str) and NAME.fullmatch(name)):
        raise Refused(NOT_READ, "the name asked for is not a secret's name")
    what = f"the key file of {name}"
    try:
        fd = el.open_file(el.path(os.path.join(b["path"], name)), os.O_RDONLY)
    except FileNotFoundError:
        raise Refused(NOT_READ, f"{what} is not in the key store") from None
    except (OSError, ValueError) as e:   # a symbolic link (the file or a folder on the way), a path outside the root, not a regular file
        raise Refused(NOT_READ, f"{what} cannot be opened ({el.why(e)[:120]})") from None
    with os.fdopen(fd, "rb") as f:
        st = os.fstat(f.fileno())
        if stat.S_IMODE(st.st_mode) != 0o600 or st.st_nlink != 1 or st.st_uid != os.geteuid():
            raise Refused(NOT_READ, f"{what} is not a private file (mode 0600, one link, this user's)")
        raw = f.read(MAX + 1)
    try:
        v = raw.decode("ascii")
    except UnicodeDecodeError:
        v = ""
    if not v or len(raw) > MAX or not v.isprintable():   # a line break in a header value would start another header
        raise Refused(NOT_READ, f"{what} does not hold one line of printable text with no line break")
    return v


def state(names=()):
    """{backend, kind, ok, missing}: the backend in use and which of `names` it cannot serve (never a value)."""
    bid, b = backend()
    missing = []
    for n in names:
        try:
            get(n)
        except Refused as e:
            if e.code != NOT_READ:
                raise
            missing.append(n)
    return {"backend": bid, "kind": b["kind"], "ok": b["kind"] == FOLDER and not missing, "missing": missing}


def check(names=()):
    """A plain yes or no for the resolver: True only when the backend holds keys and every one of `names`. Any refusal is a no,
    a worker environment included (nothing is read there)."""
    try:
        return state(names)["ok"]
    except Refused:
        return False


def main(argv):
    if argv[:1] != ["check"] or any(a.startswith("-") and a != "--json" for a in argv[1:]):
        print("usage: " + __doc__.split("CLI: ")[1].split("\n")[0], file=sys.stderr)
        return 2
    try:
        s = state([a for a in argv[1:] if a != "--json"])
    except Refused as e:
        return el.fail(e.code, e.problem)
    print(json.dumps(s) if "--json" in argv else f"backend {s['backend']} (kind {s['kind']}): {'ok' if s['ok'] else 'not usable'}")
    if not s["ok"]:
        el.say(NOT_READ, f"key store backend {sd.idn(s['backend'], True)} " + (f"lacks {len(s['missing'])} of the names asked for" if s["kind"] == FOLDER else "holds no key"))
    return 0 if s["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
