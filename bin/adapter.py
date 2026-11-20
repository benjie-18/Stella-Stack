#!/usr/bin/env python3
"""Worker adapters (F3 item A; body B1, B2 completion evidence, AC1; design section 3 with rulings DC-01..DC-07), stdlib only.
Every CLI-specific name is data (.stella/adapters.json); a new CLI is a new entry, never code. Commands:
  list --json                                  the entries: id, label, status, binary, installed, conn_types, supports
  version --adapter A --json                   runs version_cmd; a version outside tested_versions is flagged (STL-GRD-644)
  start --adapter A --role R --worktree W --brief-file F [--card C] [--card-file J] [--link CONN/MODEL] [--project P] [--run-id R]
        [--wait] --json
      1 the entry is active, its binary is on PATH, its version is known; 2 a run with no card: the worktree must lie under the
      conformance scratch root (index key conformance_scratch) and the run is never evidence for a card (DC-06);
      3 the link: --link (it must be in the role's chain) or the resolver's first usable one; its connection type must be one of the
      entry's conn_types; cli-login only with the connection's terms_ok true and its cli naming this adapter (the CLI runs on its own
      login, credential_paths are never read); with --card a passing conformance record for (adapter, version, role, link, connection
      type) whose digests match the current data (index key conformance_records, DC-06/07, V2-03); 4 a run token for every run (bin/run_token.py, DC-04); api: the CLI's base URL is the
      model proxy (index key model_proxy_state) and its token variable holds the run token; 5 the per-run folder (index key
      adapter_runs, outside the worktree and every box-writable mount): the generated policy config (bin/policy.py) with the entry's
      settings template, the MCP config (the capability server's URL and the token header, from the entry's mcp template), the prompt
      (bin/prompt.py render, with the card's attached skills and tools from --card-file); 6 the CLI holds the link's ledger slots (bin/ledger.py acquire, as `ledger.py hold` does), runs in
      the OS box (bin/box.py box_argv) when the role's profile for this adapter is boxed (DC-02), with an environment of env_keep
      names only, sandbox.env_unset removed (the entry's own token variable exempt), every worker marker set (DC-03); its output goes
      to the run log (redacted, run tokens masked, each masked hit counted by pattern class into the record's masked) and, parsed by
      the entry's stream pointers, to <run>/events.jsonl (design 3c). At its exit the record keeps the git evidence (final).
      The run goes on in the background (--wait: in the foreground); the run record is <adapter_runs>/<run>.json.
  stop --run R [--reason TEXT]                 revokes the run token, then ends the CLI's process group, one event line
  logs --run R [--follow]                      the run log
  evidence --run R --json                      {exit_code, base, head, branch, on_branch, commits, files_changed, all_inside_worktree,
                                               tool_calls, errors, tokens}, git as it was at the run's exit (commits: base..the branch the
                                               run started on); bin/false-close-guard.py calls card_verdict() (DC-01)
Every git call on a worktree runs with GIT_SAFE in a clean env (git()); untracked files are read without following links, capped
(read_cap_bytes).
start, stop, logs and evidence are engine side: they refuse in a worker environment (STL-CFG-312) before reading anything.
Exit: 0 ok; 1 refused (catalog code STL-GRD-640..654 and its plain message on stderr, {code, problem} on stdout with --json); 2 usage.
Importers: card_verdict(card), evidence(record), digests(adapter_id, role) (what a conformance record must match)."""
import os, sys

if __name__ == "__main__" and not sys.flags.isolated:   # run directly: PYTHONPATH and the current folder must not decide what is imported
    try:
        os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
    except OSError:
        sys.exit("STL-CFG-310 adapter.py could not restart itself isolated (python3 -I); nothing was started")

import argparse, contextlib, datetime, glob, hashlib, json, pwd, re, select, shutil, signal, stat, subprocess, time, uuid

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import event_log as el
import stella_data as sd
import worker_env

C = {"data": "STL-GRD-640", "stub": "STL-GRD-641", "binary": "STL-GRD-642", "version": "STL-GRD-643", "untested": "STL-GRD-644", 
     "link": "STL-GRD-645", "terms": "STL-GRD-646", "conformance": "STL-GRD-647", "scratch": "STL-GRD-648", "box": "STL-GRD-649", 
     "prepare": "STL-GRD-650", "run": "STL-GRD-651", "spawn": "STL-GRD-652", "worktree": "STL-GRD-653", "stop": "STL-GRD-654",
     "cfgcred": "STL-GRD-754", "cfghost": "STL-GRD-755", "cfgscan": "STL-GRD-757"}   # literal: the alert lint finds each sender by its code
SCAN_FILES, SCAN_BYTES = 400, 1 << 20
ROW, RUNS, RECORDS, SCRATCH = "adapters", "adapter_runs", "conformance_records", "conformance_scratch"
AGENT = "agent-runtime"   # the adapter kind of X1 item A (bin/agent_runtime.py); an entry with no kind is a coding CLI
ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}")
VERSION = re.compile(r"\d+(?:\.\d+)+[0-9A-Za-z.+-]*")
EVENTS, LOG, CFG = "events.jsonl", "run.log", "cfg"
TIME = "%Y-%m-%dT%H:%M:%SZ"
# git on a worktree an agent wrote runs none of its programs (V2-02): no fsmonitor, hook or external diff, no optional locks;
# a diff also no textconv and no submodule (a nested repo's own config would run on the host)
GIT_SAFE = ["--no-optional-locks", "-c", "core.fsmonitor=", "-c", "core.hooksPath=/dev/null", "-c", "diff.external="]
DIFF_SAFE = ["--no-ext-diff", "--no-textconv", "--ignore-submodules=all"]


class Stop(Exception):
    def __init__(self, code, problem):
        super().__init__(problem)
        self.code, self.problem = code, problem


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime(TIME)


def doc():
    """The adapters data, schema-checked."""
    try:
        row = next(r for r in sd.rows() if r["id"] == ROW)
        return sd.checked(sd.load(row["path"]), row["path"], row["schema"])
    except (sd.DataError, StopIteration, KeyError) as e:
        raise Stop(C["data"], f"the adapters data cannot be used: {str(e)[:160] or 'no index row'}") from None


def entry(aid, d=None):
    e = next((x for x in (d or doc())["entries"] if x["id"] == aid), None)
    if e is None:
        raise Stop(C["data"], f"there is no adapter {sd.idn(aid)}")
    return e


def git(wt, *a, binary=False, inp=None, cfg=()):
    """git as the engine runs it on any worktree (GIT_SAFE), in a clean env: no caller GIT_* variable, no global, system or XDG config
    (as the test map tool runs git)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, HOME=os.devnull, XDG_CONFIG_HOME=os.devnull)
    r = subprocess.run(["git", *GIT_SAFE, *cfg, "-C", wt, *a], capture_output=True, timeout=120, env=env, input=inp,
                       **({} if inp is not None else {"stdin": subprocess.DEVNULL}))
    if r.returncode:
        raise Stop(C["worktree"], f"git {a[0]} failed in {wt}: {r.stderr.decode('utf-8', 'replace').strip()[-160:]}")
    return r.stdout if binary else r.stdout.decode("utf-8", "replace").strip()


def version(e):
    """(version, tested) of an entry's installed CLI; Stop when its binary is missing or prints no version."""
    if not shutil.which(e["binary"]):
        raise Stop(C["binary"], f"adapter {e['id']}: its binary {sd.idn(e['binary'])} is not installed (not on PATH)")
    try:
        r = subprocess.run(e.get("version_cmd") or [e["binary"], "--version"], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        v = VERSION.search(r.stdout + "\n" + r.stderr) if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        v = None
    if not v:
        raise Stop(C["version"], f"adapter {e['id']}: its version command printed no version")
    return v.group(), v.group() in (e.get("tested_versions") or [])


# ---- run state: <adapter_runs>/<run>.json and the folder <adapter_runs>/<run>/ ----
def runs_dir():
    try:
        return el.path(sd.load(sd.INDEX)[RUNS])
    except (KeyError, OSError, sd.DataError):
        raise Stop(C["run"], f"the index has no usable {RUNS}") from None


def rec_path(run):
    if not isinstance(run, str) or not ID.fullmatch(run):
        raise Stop(C["run"], "the run id is not well formed")
    return os.path.join(runs_dir(), run + ".json")


def read_rec(run):
    try:
        with open(rec_path(run), encoding="utf-8") as f:
            r = json.load(f)
        assert isinstance(r, dict)
        return r
    except (OSError, ValueError, AssertionError):
        raise Stop(C["run"], f"there is no readable record of run {sd.idn(run)}") from None


def update(rid, **kw):
    """The run record with kw set, written whole under its lock; the new record."""
    import route   # its write_whole: temp file, fsync, rename
    p = rec_path(rid)
    with el.locked(p + ".lock"):
        try:
            with open(p, encoding="utf-8") as f:
                r = json.load(f)
        except FileNotFoundError:
            r = {}
        r.update(kw)
        route.write_whole(p, r)
    return r


def records():
    d = runs_dir()
    out = []
    for n in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if n.endswith(".json"):
            with contextlib.suppress(OSError, ValueError):
                with open(os.path.join(d, n), encoding="utf-8") as f:
                    r = json.load(f)
                if isinstance(r, dict):
                    out.append(r)
    return out


def event(kind, run, role=None, **new):
    el.append(el.build(kind, f"run {run}", new=new, who={"role": role} if role else None))


# ---- the conformance gate (DC-06, DC-07) ----
def canon(x):
    return hashlib.sha256(json.dumps(x, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def row_doc(rid):
    return sd.load(next(r["path"] for r in sd.rows() if r["id"] == rid))


def digests(aid, role):
    """sha256 of what a conformance record must match: the adapter entry, its rendered policy, the role's effective run policy (every
    part but the other roles' sections: default, filters, the role's own), the stuck patterns and the conformance cases (DC-07, V2-05)."""
    import policy, run_policy
    try:
        t = run_policy.load()
        rp = {**{k: v for k, v in t.items() if k != "roles"}, "roles": {role: t["roles"].get(role)}}
        import roles
        e = entry(aid)
        top = {k: v for k, v in row_doc(ROW).items() if k != "entries" and (k != "agent_tools" or e.get("kind") == AGENT)}   # env_keep, run_env, caps: what every run of every adapter gets (RTF-03); agent_tools only an agent runtime's
        out = {"adapter": canon(e), "policy": canon(policy.render(aid)), "run_policy": canon(rp),
               "stuck": canon(row_doc("stuck")), "conformance": canon(row_doc("conformance")),
               "adapters": canon(top), "sandbox": canon(roles.sandbox(roles.load()))}
        if e.get("kind") == AGENT:   # X1-DC-03: a change of its protocol entry voids the record
            import agent_runtime
            out["protocol"] = canon(agent_runtime.protocol(e))
        return out
    except Stop:
        raise
    except Exception as e:
        raise Stop(C["conformance"], f"the digests of adapter {aid} for role {role} cannot be computed ({type(e).__name__})") from None


def gate(e, ver, role, link, ctype):
    """A passing record of this adapter, version, role, link and connection type whose digests match current data (DC-06/07, V2-03)."""
    rel = sd.load(sd.INDEX).get(RECORDS)
    if not rel:
        raise Stop(C["conformance"], f"no conformance record is kept (index key {RECORDS}), so adapter {e['id']} holds no role yet")
    try:
        recs = sd.load(rel)["records"]
    except (sd.DataError, KeyError, TypeError):
        raise Stop(C["conformance"], "the conformance records cannot be read") from None
    mine = [r for r in recs if isinstance(r, dict) and r.get("adapter") == e["id"] and r.get("version") == ver and r.get("role") == role
            and r.get("link") == link and r.get("conn_type") == ctype and r.get("passed") is True]
    if not mine:
        raise Stop(C["conformance"], f"adapter {e['id']} {ver} has no passing conformance record for role {role} on link {link} ({ctype})")
    if not any(r.get("digests") == digests(e["id"], role) for r in mine):
        raise Stop(C["conformance"], f"adapter {e['id']} {ver} passed conformance for role {role} on other data (entry, policy or run policy changed since)")


def scratch_root():
    rel = sd.load(sd.INDEX).get(SCRATCH)
    if not isinstance(rel, str) or not rel:
        raise Stop(C["scratch"], f"the index names no conformance scratch root ({SCRATCH})")
    return os.path.realpath(rel if os.path.isabs(rel) else os.path.join(sd.ROOT, rel))


def inside(p, d):
    return p == d or p.startswith(d.rstrip("/") + "/")


# ---- the link (resolver), the box ----
def links_in(x):
    if isinstance(x, dict):
        here = [(x["connection"], x["model"])] if isinstance(x.get("connection"), str) and isinstance(x.get("model"), str) else []
        return here + [l for v in x.values() for l in links_in(v)]
    return [l for v in x for l in links_in(v)] if isinstance(x, list) else []


def pick_link(role, link, project, card):
    import resolve, route
    try:
        if link:
            conn, _, model = link.partition("/")
            view = resolve.role_view(role, project, card)
            if (conn, model) not in links_in(view):
                raise Stop(C["link"], f"link {sd.idn(link)} is not in the chain of role {role}")
        else:
            r = resolve.resolve({"role": role, "project": project, "card": card})
            u = next((x for x in r["chain"] if x["status"] == "usable"), None)
            if u is None:
                raise Stop(C["link"], f"role {role} has no usable link: {r.get('reason') or 'none'}")
            conn, model = u["connection"], u["model"]
        prov, _ = route.model_of(route.data()[1], {"connection": conn, "model": model})
    except (sd.DataError, route.Stop) as x:
        raise Stop(C["link"], f"the link of role {role} cannot be resolved: {getattr(x, 'problem', str(x))[:160]}") from None
    if prov.get("enabled") is False:
        raise Stop(C["link"], f"connection {conn} is switched off")
    return conn, model, prov


def box_prefix(role, aid, wt, label, cfg):
    """(argv prefix, env) when the role's profile for this adapter is boxed (DC-02), else (None, {}) only for an entry that says unboxed in its
    data (the fake and test adapters); Stop when the plan fails or no boxed profile exists (boxing is the default, never fail-open)."""
    import box, roles
    try:
        d = roles.load()
        sb = roles.sandbox(d) or {}
        profs = [p for p, row in d["profiles"].items() if row.get("role") == role and row.get("worker") == aid and p in sb.get("boxed_profiles", [])]
        if not profs:
            if entry(aid).get("unboxed") is True:
                return None, {}
            raise Stop(C["box"], f"role {role} has no boxed profile for adapter {aid}, and the adapter's data does not say unboxed: the run is not started")
        home = pwd.getpwuid(os.getuid()).pw_dir
        root = os.environ.get("BOX_HERMES_ROOT") or f"{home}/.hermes"   # as box.merge_exec finds it
        try:   # the board's project roots, as the os-box plugin passes them; the stack's own worktrees come from stack_root
            proj = [p["repo"] for p in roles.board_projects(roles.board()) if p["repo"]]
        except Exception:
            proj = []   # no readable board: only the stack's own linked worktrees can be boxed (fail closed for the rest)
        top = os.path.realpath(os.path.dirname(os.path.realpath(os.path.join(wt, git(wt, "rev-parse", "--git-common-dir")))))
        if top != os.path.realpath(sd.ROOT) and top not in {os.path.realpath(p) for p in proj}:
            # the box hides the stack root's protected paths but walks the worktree's repo: they must be one tree (live finding B)
            raise Stop(C["box"], f"the worktree's repository is neither the stack root nor a project of the board: the run is not started")
        argv, over = box.box_argv(d, profs[0], {"card": label, "workspace": wt, "branch": git(wt, "rev-parse", "--abbrev-ref", "HEAD")},
                                  hermes_root=root, home=home, roots=proj, stack_root=sd.ROOT)
        # the run config goes in just before the read-only remount of its deepest tmpfs ancestor: its parents can still be made there, and no
        # later tmpfs of the walk covers it (live findings A and F); with no tmpfs ancestor it goes last, where its parents already exist
        anc = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--tmpfs" and (cfg == argv[i + 1] or cfg.startswith(argv[i + 1].rstrip("/") + "/"))]
        at = len(argv)
        if anc:
            deep = max(anc, key=len)
            at = max((i for i in range(len(argv) - 1) if argv[i] == "--remount-ro" and argv[i + 1] == deep), default=len(argv))
        return argv[:at] + ["--ro-bind", cfg, cfg] + argv[at:] + ["--chdir", wt], over   # the run's config folder, read-only, nothing else of the state
    except Stop:
        raise
    except Exception as e:   # BoxError, RolesError, OSError: fail closed
        raise Stop(C["box"], f"the box for role {role} cannot be planned: {str(e)[:160]}") from None


def endpoint(key):
    """http://bind:port[path] of a server's state file (index key key), or None when it is not running."""
    try:
        st = sd.load(sd.load(sd.INDEX)[key])
        host = f"[{st['bind']}]" if ":" in st["bind"] else st["bind"]
        assert type(st["port"]) is int and st["port"] > 0
        return f"http://{host}:{st['port']}{st.get('path') or ''}"
    except (sd.DataError, KeyError, TypeError, AssertionError):
        return None


def merge(a, b):
    for k, v in b.items():
        a[k] = merge(a[k], v) if isinstance(a.get(k), dict) and isinstance(v, dict) else a[k] + v if isinstance(a.get(k), list) and isinstance(v, list) else v
    return a


def write_json(p, x):
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(x if isinstance(x, str) else json.dumps(x, indent=1))
    return p


def tool(argv, code, what):
    r = subprocess.run([sys.executable, "-I", *argv], capture_output=True, text=True, timeout=180, stdin=subprocess.DEVNULL)
    if r.returncode:
        got = re.findall(r"STL-[A-Z]{3}-\d{3}", r.stdout + r.stderr)
        raise Stop(code, f"{what} failed ({got[0] if got else 'exit ' + str(r.returncode)})")
    return r.stdout


# ---- the stream: run log and events.jsonl (design 3c) ----
def get(d, ptr):
    if not isinstance(ptr, str):
        return None
    for p in ptr.split("/")[1:]:
        p = p.replace("~1", "/").replace("~0", "~")
        if isinstance(d, dict) and p in d:
            d = d[p]
        elif isinstance(d, list) and p.isdigit() and int(p) < len(d):
            d = d[int(p)]
        else:
            return None
    return d


def fingerprint(p, cap):
    """sha256 of an untracked file as the engine reads it (V2-11): a link's target text (never followed), a non-regular file's type,
    the size and at most cap bytes of a regular one; b"" when it cannot be read."""
    try:
        st = os.lstat(p)
        if stat.S_ISLNK(st.st_mode):
            return hashlib.sha256(b"link\0" + os.fsencode(os.readlink(p))).digest()
        fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK) if stat.S_ISREG(st.st_mode) else None
        if fd is None:
            return hashlib.sha256(b"type\0%d" % stat.S_IFMT(st.st_mode)).digest()
        with os.fdopen(fd, "rb") as f:
            st = os.fstat(f.fileno())
            return hashlib.sha256(b"%d\0" % st.st_size + (f.read(cap) if stat.S_ISREG(st.st_mode) else b"")).digest()
    except OSError:
        return b""


class Stream:
    hits = calls = useen = None   # made on first use: masked hits per pattern class, tool calls by id, usage seen per message
    rcap = 1 << 20   # bytes read of one untracked file; a run's own from adapters.json read_cap_bytes

    def __init__(self, run, rec, e, a, token_rx):
        self.run, self.rec, self.s, self.tools = run, rec, e.get("stream") or {}, e.get("tools") or {}
        self.cap, self.rx, self.seq, self.last, self.rcap = a["output_cap"], token_rx, 0, None, a.get("read_cap_bytes", Stream.rcap)
        self.role = rec["role"]
        self.pats = sd.value_pats()   # the catalog's value patterns; None (unreadable): every line is masked whole (fail closed)
        try:
            self.redk = el.redactor()
        except (sd.DataError, OSError, KeyError, TypeError):
            self.redk = lambda k: True
        d = os.path.join(runs_dir(), run)
        self.log = open(os.path.join(d, LOG), "a", encoding="utf-8")
        self.ev = open(os.path.join(d, EVENTS), "a", encoding="utf-8")

    def count(self, k, n):
        if n:
            self.hits = self.hits or {}
            self.hits[k] = self.hits.get(k, 0) + n

    def red(self, x):
        """event_log's rules (values under redact keys, the catalog's value patterns, values seen under masked keys) and run tokens; each
        pattern hit is counted by class (run_token, token), so a judge sees a token the masking hid (V2-04)."""
        if isinstance(x, str):
            if self.pats is None:
                return el.MASK
            x, n = self.rx.subn(el.MASK, x)
            self.count("run_token", n)
            for p in self.pats:
                x, n = p.subn(el.MASK, x)
                self.count("token", n)
            return el.scrub(x)
        if isinstance(x, dict):
            return {k: el.MASK if self.redk(str(k)) else self.red(v) for k, v in x.items()}
        return [self.red(v) for v in x] if isinstance(x, list) else x

    def filt(self, text):
        try:
            import log_filter, run_policy
            text = log_filter.apply(run_policy.load(), self.role, text)
        except Exception:   # an unusable run policy leaves the text unfiltered, still capped
            pass
        return text[-self.cap:]

    def diff(self):
        wt, h = self.rec["worktree"], hashlib.sha256()
        try:
            notes = self.rec.get("notes")   # the working-notes file changes every turn and says nothing about progress
            h.update(git(wt, "diff", "--binary", *DIFF_SAFE, self.rec["base"], "--", ".", *([f":(exclude,literal){notes}"] if notes else []), binary=True))
            for f in sorted(x for x in git(wt, "ls-files", "-z", "--others", "--exclude-standard", binary=True).split(b"\0") if x and x.decode("utf-8", "surrogateescape") != notes):
                h.update(f + b"\0" + fingerprint(os.path.join(wt, f.decode("utf-8", "surrogateescape")), self.rcap))
        except Stop:
            return None
        return h.hexdigest()

    def put(self, ev):
        self.seq += 1
        self.ev.write(json.dumps({"seq": self.seq, "at": now(), "run": self.run, **ev}) + "\n")
        self.ev.flush()

    def line(self, raw):
        text = self.red(raw.decode("utf-8", "replace"))
        self.log.write(text if text.endswith("\n") else text + "\n")
        self.log.flush()
        try:
            obj = json.loads(raw)
        except ValueError:
            return
        s = self.s
        items = get(obj, s.get("items")) if s.get("items") else None
        for c in [obj] + (items if isinstance(items, list) else []):
            if not isinstance(c, dict):
                continue
            raw_t = get(c, s.get("type"))
            ts = (s.get("types") or {}).get(raw_t, raw_t) if isinstance(raw_t, str) else None
            for t in ts if isinstance(ts, list) else [ts]:   # one CLI line may be both a tool use and its result
                self.one(c, t)

    def tokens(self, c, k):
        """A usage count: the sum of the ints its pointer (or list of pointers, e.g. input plus cache tokens) finds; None when none is."""
        ptr = (self.s.get("usage") or {}).get(k)
        got = [v for v in (get(c, p) for p in (ptr if isinstance(ptr, list) else [ptr])) if type(v) is int]
        return sum(got) if got else None

    def one(self, c, t):
        s = self.s
        if t == "tool_use":
            name, inp = get(c, s.get("tool_name")), get(c, s.get("tool_input"))
            inp = self.red(inp if isinstance(inp, dict) else {"value": inp})
            self.last = (name, inp)
            tid = get(c, s.get("tool_id"))
            if isinstance(tid, str):
                self.calls = self.calls or {}
                self.calls[tid] = (name, inp)
            self.put({"type": t, "name": name, "input": inp, "signature": canon([name, inp])})
        elif t == "tool_result":
            rid = get(c, s.get("result_id"))
            known = (self.calls or {}).get(rid) if isinstance(rid, str) else None   # parallel calls: the result names its call
            last = known or self.last or (None, {})
            name = get(c, s.get("tool_name")) or last[0]
            inp = last[1] if last[0] == name else {}
            ok = get(c, s["ok"]) if s.get("ok") else not get(c, s.get("error"))
            out = get(c, s.get("tool_result"))
            self.put({"type": t, "name": name, "input": inp, "ok": ok is True, "output": self.filt(self.red(out if isinstance(out, str) else json.dumps(out))),
                      "diff": self.diff(), "signature": canon([name, inp])})
        elif t in ("result", "error"):
            out = get(c, s.get("final_text" if t == "result" else "error"))
            self.put({"type": t, "name": None, "input": {}, "output": self.filt(self.red(out if isinstance(out, str) else json.dumps(out)))})
        elif t == "usage":
            tok = {k: self.tokens(c, k) for k in ("input", "output")}
            if not all(type(v) is int for v in tok.values()):
                return
            key = get(c, s.get("usage_key"))
            if isinstance(key, str):   # one message may come on several lines, each with its usage: only what is new counts
                self.useen = self.useen or {}
                prev = self.useen.get(key, {})
                self.useen[key] = {k: max(v, prev.get(k, 0)) for k, v in tok.items()}
                tok = {k: max(0, v - prev.get(k, 0)) for k, v in tok.items()}
                if not any(tok.values()):
                    return
            m = get(c, s["model"]) if s.get("model") else None   # the model the CLI says served (F3-CVER-03)
            self.put({"type": "usage", "name": None, "input": {}, "tokens": tok, **({"model": m} if isinstance(m, str) else {})})


def read_events(run):
    try:
        with open(os.path.join(runs_dir(), run, EVENTS), encoding="utf-8") as f:
            return [x for x in (json.loads(l) for l in f if l.strip()) if isinstance(x, dict)]
    except (OSError, ValueError):
        return []


def snapshot(rec):
    """The run's git evidence at its exit, kept in its record (V2-08, RT3-01): HEAD, the branch HEAD is on, the commits from the base to
    the tip of the branch the run started on, the files changed against the base. Nothing done after the exit counts."""
    wt, base, br = rec["worktree"], rec.get("base"), rec.get("branch")
    try:
        head, on = git(wt, "rev-parse", "HEAD"), git(wt, "rev-parse", "--abbrev-ref", "HEAD")
        tip = git(wt, "for-each-ref", "--format=%(objectname)", "refs/heads/" + br) if br else ""
        commits = [c for c in git(wt, "rev-list", f"{base}..{tip}").split("\n") if c] if tip else []
        files = sorted(set(x for x in git(wt, "diff", "--name-only", *DIFF_SAFE, base).split("\n") if x)
                       | set(x for x in git(wt, "ls-files", "--others", "--exclude-standard").split("\n") if x))
    except Stop:
        head, on, commits, files = None, "HEAD", [], []
    return {"head": head, "branch": None if on == "HEAD" else on, "commits": commits, "files": files, "at": now()}


def evidence(rec):
    """The run's completion evidence: what git showed at the run's exit (snapshot) and the trusted stream, never what the agent says.
    A run with no snapshot (not ended, or its supervisor died) shows no head, commit or file."""
    wt, base, fin = rec["worktree"], rec.get("base"), rec.get("final") or {}
    head, commits, files = fin.get("head"), fin.get("commits") or [], fin.get("files") or []
    on_branch = bool(rec.get("branch")) and fin.get("branch") == rec.get("branch")
    try:
        tools = entry(rec["adapter"]).get("tools") or {}
    except Stop:
        tools = {}
    evs = read_events(rec["run"])
    real = os.path.realpath(wt)
    paths = [get(e.get("input") or {}, tools[e["name"]].get("path")) for e in evs
             if e.get("type") == "tool_use" and isinstance(tools.get(e.get("name")), dict) and tools[e["name"]].get("class") == "write"]
    outside = [p for p in paths if not isinstance(p, str) or not inside(os.path.realpath(os.path.join(real, os.path.expanduser(p))), real)]
    tok = [e.get("tokens") or {} for e in evs if e.get("type") == "usage"]
    return {"run": rec["run"], "card": rec.get("card"), "adapter": rec.get("adapter"), "conformance": rec.get("conformance") is not False,
            "exit_code": rec.get("exit"), "base": base, "head": head, "branch": rec.get("branch"), "on_branch": on_branch, "commits": commits, "files_changed": files,
            "all_inside_worktree": not outside, "tool_calls": sum(e.get("type") == "tool_use" for e in evs),
            "errors": sum(e.get("type") == "error" or (e.get("type") == "tool_result" and e.get("ok") is False) for e in evs),
            "tokens": {k: sum(t.get(k) or 0 for t in tok) for k in ("input", "output")}}


def card_verdict(card):
    """None when the card has no adapter run (the Hermes-session path stands); else (ok, why) of its newest run (DC-01). A card-less
    (conformance) run's evidence is never accepted for a card."""
    mine = sorted((r for r in records() if r.get("card") == card), key=lambda r: str(r.get("started")))
    if not mine:
        return None
    ev = evidence(mine[-1])
    why = ("it was a conformance run with no card" if ev["conformance"] else
           "it has not ended" if ev["exit_code"] is None else
           f"it exited {ev['exit_code']}" if ev["exit_code"] != 0 else
           "it did not end on the branch it started on" if not ev["on_branch"] else
           "it made no commit on its branch" if not ev["commits"] else
           "it wrote outside its worktree" if not ev["all_inside_worktree"] else None)
    return (why is None, f"adapter run {ev['run']}: " + (why or "exit 0, commits inside the worktree"))


# ---- commands ----
def cmd_list(a):
    print(json.dumps({"adapters": [{"id": e["id"], "label": e.get("label"), "status": e.get("status"), "binary": e["binary"],
                                    "installed": bool(shutil.which(e["binary"])), "conn_types": e.get("conn_types", []),
                                    "supports": e.get("supports", {})} for e in doc()["entries"]]}))
    return 0


def cmd_version(a):
    e = entry(a.adapter)
    v, tested = version(e)
    out = {"adapter": e["id"], "version": v, "tested": tested, "tested_versions": e.get("tested_versions", [])}
    if not tested:
        out["code"] = C["untested"]
        el.say(C["untested"], f"adapter {e['id']} runs version {v}, which is not in its tested_versions", alert=True)
    print(json.dumps(out))
    return 0


def scan_data(e):
    """(value patterns, cloud provider hosts) of the connections catalog for the config scan; Stop when the catalog cannot be read."""
    import route
    pats = sd.value_pats()
    try:
        d = route.data()
        hosts = sorted({h["host"].lower() for c in d[1].values() if c.get("kind") == "provider" and c.get("locality") != "local"
                        for h in c.get("hosts") or [] if h["host"] not in d[3]})
    except (sd.DataError, route.Stop, KeyError, TypeError):
        pats = None
    if pats is None:
        raise Stop(C["cfgscan"], f"adapter {e['id']}: the connections catalog cannot be read, so its config files cannot be scanned")
    return pats, hosts


def scan_config(e, wt):
    """X1 item C preflight (both kinds): the entry's own config files (config_files globs relative to the worktree, or {home}/...) and its
    start template must hold no catalog value pattern (a credential) and no host of a cloud provider connection (a direct route around
    the proxy). Stop with a code before anything is spawned; the refusal names the file, never the value.
    Limits (a larger entry is refused, never skipped): SCAN_FILES files, SCAN_BYTES per file."""
    pats, hosts = scan_data(e)
    home = os.environ.get((e.get("cli_login") or {}).get("home_env") or "HOME", "")
    todo = []
    for g in e.get("config_files") or []:
        for m in sorted(glob.glob(home + g[6:] if g.startswith("{home}") else os.path.join(glob.escape(wt), g))):
            todo += [os.path.join(t, f) for t, _, fs in os.walk(m) for f in fs] if os.path.isdir(m) and not os.path.islink(m) else [m]
    # fail closed: whatever cannot be read whole as a plain file (a link, a FIFO, a file over the cap, more files than the cap) refuses the start
    if len(todo) > SCAN_FILES:
        raise Stop(C["cfgscan"], f"adapter {e['id']}: its config files match more than {SCAN_FILES} files, so they cannot all be scanned")
    for p in todo:
        name = os.path.relpath(p, wt) if inside(p, wt) else "{home}/" + os.path.relpath(p, home)
        try:
            fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as f:
                raw = f.read(SCAN_BYTES + 1) if stat.S_ISREG(os.fstat(fd).st_mode) else None
        except OSError:
            raw = None
        if raw is None or len(raw) > SCAN_BYTES:
            raise Stop(C["cfgscan"], f"adapter {e['id']}: its config file {sd.idn(name)} is not a plain file of at most {SCAN_BYTES} bytes, so it cannot be scanned")
        hit(e, pats, hosts, raw.decode("utf-8", "replace"), f"its config file {sd.idn(name)}")
    hit(e, pats, hosts, json.dumps(e.get("start") or {}), "its start template")


def hit(e, pats, hosts, text, where):
    if any(x.search(text) for x in pats):
        raise Stop(C["cfgcred"], f"adapter {e['id']}: {where} holds a credential (a value the connections catalog masks); keys reach an agent through the proxy only")
    if any(h in text.lower() for h in hosts):
        raise Stop(C["cfghost"], f"adapter {e['id']}: {where} names a provider host of the connections catalog; the agent must reach models through the proxy only")


def cmd_start(a):
    d = doc()
    e = entry(a.adapter, d)
    if e.get("status") != "active":
        raise Stop(C["stub"], f"adapter {e['id']} is a stub (status {e.get('status')!r}): it cannot start a run")
    st = e.get("start") or {}
    if not (st.get("argv") and (e.get("stream") or e.get("kind") == AGENT) and e.get("conn_types")):
        raise Stop(C["prepare"], f"adapter {e['id']} has no start argv, stream or conn_types")
    ver, tested = version(e)
    wt = os.path.realpath(a.worktree)
    if not os.path.isdir(wt) or os.path.realpath(git(wt, "rev-parse", "--show-toplevel")) != wt:
        raise Stop(C["worktree"], f"{sd.idn(a.worktree)} is not the top of a git worktree")
    for k in ("card", "run_id"):
        if getattr(a, k) is not None and not ID.fullmatch(getattr(a, k)):
            raise Stop(C["run"], f"the {k.replace('_', ' ')} is not well formed")
    if not a.card and (not inside(wt, scratch_root()) or wt == scratch_root()):
        raise Stop(C["scratch"], "a run with no card runs only in a worktree under the conformance scratch root")
    conn, model, prov = pick_link(a.role, a.link, a.project, a.card)
    ctype = prov.get("type")
    if ctype not in e["conn_types"]:
        raise Stop(C["link"], f"adapter {e['id']} does not run on a {ctype} connection")
    if ctype == "cli-login":
        if prov.get("cli") != e["id"]:
            raise Stop(C["link"], f"connection {conn} is the login of another CLI")
        if prov.get("terms_ok") is not True:
            raise Stop(C["terms"], f"connection {conn}: the owner has not set terms_ok, so no agent runs on this login")
    if a.card:
        gate(e, ver, a.role, f"{conn}/{model}", ctype)
    scan_config(e, wt)
    run = a.run_id or "run-" + uuid.uuid4().hex[:12]
    rdir = os.path.join(runs_dir(), run)
    if os.path.lexists(rec_path(run)) or os.path.lexists(rdir):
        raise Stop(C["run"], f"run {run} exists already")
    cfg = os.path.join(rdir, CFG)
    pre, box_env = box_prefix(a.role, e["id"], wt, a.card or run, cfg)
    proxy = endpoint("model_proxy_state") if ctype == "api" else None
    if ctype == "api" and not proxy:
        raise Stop(C["prepare"], "the model proxy is not running (no address at index key model_proxy_state)")
    el.mkdirs(cfg)
    os.chmod(rdir, 0o700)
    link = f"{conn}/{model}"
    mint = ["--run", run, "--role", a.role, "--card", a.card or "", "--link", link] + (["--project", a.project] if a.project else [])
    token = tool([os.path.join(BIN, "run_token.py"), "mint", *mint], C["prepare"], "minting the run token").strip()
    try:
        return launch(a, d, e, ver, tested, wt, run, rdir, cfg, conn, model, link, ctype, proxy, pre, box_env, token)
    except BaseException:
        with contextlib.suppress(Exception):
            tool([os.path.join(BIN, "run_token.py"), "revoke", "--run", run], C["prepare"], "revoking the run token")
        raise


def launch(a, d, e, ver, tested, wt, run, rdir, cfg, conn, model, link, ctype, proxy, pre, box_env, token):
    import policy, roles
    st, env_names = e["start"], st_env(e)
    probs = policy.problems()
    if probs or not e.get("policy"):
        raise Stop(C["prepare"], f"the policy of adapter {e['id']} cannot be generated: {probs[0][1][:140] if probs else 'no policy part'}")
    tr = json.loads(tool([os.path.join(BIN, "run_policy.py"), "translate", "--adapter", e["id"], "--role", a.role], C["prepare"], "translating the run policy"))
    v = {"base_url": proxy or "", "model": model, "token_env": e.get("token_env") or "", "token": token, "worktree": wt}
    url = endpoint("capabilities_mcp_state")
    settings, sfile, mfile = {}, "", ""
    if e.get("kind") != AGENT:   # an agent runtime has no CLI config: its tool calls are gated and run engine side (bin/agent_runtime.py)
        rend = policy.render(e["id"], wt, stack=sd.ROOT)   # the run's own stack: its hook and its paths exist in the box (live finding I)
        hk = e["policy"].get("hook")
        if tr["hook"] and hk:   # the log filter joins the policy hook's list in the generated config (the entry's own hook template and pointer)
            rend[hk["pointer"]].append(policy.fill(hk["template"], tr["hook"]))
        settings = policy.merged({}, rend)
        if ctype == "api" and st.get("settings"):
            merge(settings, policy.fill(st["settings"], v))
        mc = e.get("mcp") or {}
        gw = sd.load(next(r["path"] for r in sd.rows() if r["id"] == "run-gateway"))["mcp"]
        mcp_doc = policy.fill(mc["template"], {**v, "url": url, "auth_header": gw["auth_header"], "auth_value": f"{gw['auth_scheme']} {token}"}) \
            if url and mc.get("template") else {}
        sfile = os.path.join(cfg, os.path.basename(e["policy"]["target"]["file"]))
        if mc.get("into") == "settings":
            merge(settings, mcp_doc)
            mfile = sfile
        else:
            mfile = write_json(os.path.join(cfg, "mcp.json"), mcp_doc)
        merge(settings, tr["settings"])   # core tools only, compaction, clearing, the log filter hook: each where the entry says the CLI supports it
        merge(settings, e.get("run_settings") or {})   # the entry's fixed settings for every adapter run, e.g. its own skill loader off (skills come through capability load; F3-CVER-01)
        write_json(sfile, settings)
    write_json(os.path.join(cfg, "run-policy.json"), tr)
    attached = None
    if a.card_file:
        try:
            card = json.load(open(a.card_file, encoding="utf-8"))
            lines = [f"- {k[:-1]}: {i}" for k in ("skills", "tools") for i in card.get(k) or [] if isinstance(i, str)]
        except (OSError, ValueError, AttributeError):
            raise Stop(C["prepare"], "the card file is not readable JSON") from None
        attached = write_json(os.path.join(cfg, "attached.md"), "\n".join(lines) + "\n") if lines else None
    text, notes = brief_text(a, tr, wt, run)
    brief = write_json(os.path.join(cfg, "brief.md"), text)
    r = json.loads(tool([os.path.join(BIN, "prompt.py"), "render", "--role", a.role, "--link", link, "--brief", brief, "--json"]
                        + (["--attached", attached] if attached else []) + (["--notes", notes] if notes else []), C["prepare"], "rendering the prompt"))
    pfile = write_json(os.path.join(cfg, "prompt.md"), r["text"])
    argv = policy.fill(st["argv"], {"prompt_file": pfile, "prompt": r["text"], "model": model, "settings_file": sfile, "mcp_config": mfile, "worktree": wt})
    # the environment: env_keep names only, sandbox.env_unset gone (the entry's own token variable exempt), then the run's values
    env = {k: v for k, v in os.environ.items() if k in d.get("env_keep", [])}
    table = roles.load()
    for n in (roles.sandbox(table) or {}).get("env_unset", []):
        if n not in env_names:
            env.pop(n, None)
    env.update({m: a.card or run for m in roles.worker_markers(table)})
    if table.get("worker_pins", {}).get("workspace") in env:
        env[table["worker_pins"]["workspace"]] = wt
    env.update({x: token for x in [e.get("token_env")] + ([env_names[1]] if ctype == "api" else []) if x})
    if ctype == "api" and env_names[0]:
        env[env_names[0]] = proxy
    # settings_json: the generated config itself, for a CLI whose inline config outranks a config planted in the worktree (RT3-07)
    env.update(policy.fill((st.get("env") or {}).get("set") or {}, {**v, "settings_file": sfile, "settings_json": json.dumps(settings), "mcp_config": mfile, "prompt_file": pfile}))
    re_ = d.get("run_env") or {}
    env.update({k: val for k, val in ((re_.get("adapter"), e["id"]), (re_.get("capabilities_url"), url)) if k and val})
    env.update(box_env)
    cmd = (pre or []) + argv
    base, branch = git(wt, "rev-parse", "HEAD"), git(wt, "rev-parse", "--abbrev-ref", "HEAD")
    import run_token
    rx = re.compile(re.escape(run_token.gateway()["token"]["prefix"]) + r"[A-Za-z0-9_-]+")
    rec = {"schema_version": 1, "run": run, "role": a.role, "card": a.card, "conformance": not a.card, "project": a.project, "adapter": e["id"],
           "version": ver, "tested": tested, "link": link, "conn_type": ctype, "unattended": True, "background": not a.wait,
           "boxed": pre is not None, "worktree": wt, "base": base, "branch": None if branch == "HEAD" else branch, "run_dir": rdir, "pid": None, "pgid": None, "started": now(),
           "ended": None, "exit": None, "stopped": None, "notes": tr["notes"]["path"].replace("{card}", a.card or run),   # the notes file stays out of the progress digest (stuck.py)
           "run_policy": {"applied": tr["applied"], "unsupported": tr["unsupported"], "hook": bool(tr["hook"] and e["policy"].get("hook"))}, "global_id": str(uuid.uuid4()), "install_id": sd.install_id()}
    out = {"run": run, "adapter": e["id"], "version": ver, "tested": tested, "link": link, "conn_type": ctype, "background": not a.wait}
    agent = {"pre": pre, "prompt": r["text"], "model": model, "core": tr["core_tools"]} if e.get("kind") == AGENT else None
    import ledger   # the run's lease: the link's slots, taken here and held by the CLI's process (as ledger.py hold does: it cannot run with a worker's env)
    try:
        fds = ledger.acquire(conn, model, f"adapter run {run}")
        rec["leased"] = True   # the run holds its link's slots: the model proxy takes none again per call (RTF-02)
    except ledger.Refusal as r:
        raise Stop(ledger.LIMITED, r.problem) from None
    except ledger.Stop as r:
        raise Stop(r.code, r.problem) from None
    if a.wait:
        rc = supervise(cmd, wt, env, rec, e, d, rx, fds, agent=agent)
        print(json.dumps({**out, "exit": rc}) if a.json else run)
        return 0
    r_, w_ = os.pipe()
    if os.fork() == 0:   # the supervisor: its own session, the only writer of the run's stream
        os.close(r_)
        try:
            os.setsid()
            nul = os.open(os.devnull, os.O_RDWR)
            for fd in (0, 1, 2):
                os.dup2(nul, fd)
            supervise(cmd, wt, env, rec, e, d, rx, fds, w_, agent=agent)
        except BaseException as x:   # the parent learns it, when the start was not reported yet (a closed pipe: it was)
            with contextlib.suppress(OSError):
                os.write(w_, json.dumps({"code": C["spawn"], "problem": f"{type(x).__name__} in the supervisor of run {run}"}).encode())
        finally:
            os._exit(0)
    os.close(w_)
    for fd in fds:
        os.close(fd)
    got = b""
    while select.select([r_], [], [], 60)[0]:
        b = os.read(r_, 4096)
        if not b:
            break
        got += b
    os.close(r_)
    try:
        msg = json.loads(got)
    except ValueError:
        raise Stop(C["spawn"], f"the run {run} supervisor did not report its start") from None
    if "code" in msg:
        raise Stop(msg["code"], msg["problem"])
    print(json.dumps({**out, "pid": msg["pid"]}) if a.json else run)
    return 0


def brief_text(a, tr, wt, run):
    """(brief text with the run policy's output style and notes instruction, the card's working-notes file or None). The notes path is run-policy
    data with {card} filled, relative to the worktree; a link out of the worktree is not read. prompt.py renders the notes (path and content)."""
    try:
        text = open(a.brief_file, encoding="utf-8").read()
    except OSError:
        raise Stop(C["prepare"], "the brief file cannot be read") from None
    n = tr["notes"]
    rel = n["path"].replace("{card}", a.card or run)
    p = os.path.realpath(os.path.join(wt, rel))
    return (text.rstrip("\n") + f"\n\n## Run policy\nOutput style: {tr['output_style']}\n"
            f"Working notes: keep {rel} in the worktree with the sections {', '.join(n['sections'])}; read it first when it exists.\n",
            p if inside(p, wt) and os.path.isfile(p) else None)


def st_env(e):
    env = (e.get("start") or {}).get("env") or {}
    return [env.get("base_url_env"), env.get("token_env")]


def supervise(cmd, wt, env, rec, e, d, rx, fds, w=None, agent=None):
    run = rec["run"]
    try:
        p = subprocess.Popen(cmd, cwd=wt, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
                             pass_fds=fds)
    except OSError as x:
        update(run, **{**rec, "ended": now(), "exit": -1})
        msg = {"code": C["spawn"], "problem": f"the CLI of run {run} could not start ({type(x).__name__})"}
        if w is None:
            raise Stop(msg["code"], msg["problem"])
        os.write(w, json.dumps(msg).encode()); os.close(w)
        return -1
    finally:
        for fd in fds:   # the CLI holds the slots now: they end with its last process
            os.close(fd)
    update(run, **{**rec, "pid": p.pid, "pgid": p.pid})
    event("adapter.run-started", run, rec["role"], adapter=rec["adapter"], version=rec["version"], card=rec["card"], link=rec["link"],
          conn_type=rec["conn_type"], boxed=rec["boxed"], pid=p.pid)
    if w is not None:
        os.write(w, json.dumps({"pid": p.pid}).encode()); os.close(w)
    s = Stream(run, rec, e, {"output_cap": d.get("output_cap", 4000), "read_cap_bytes": d.get("read_cap_bytes", Stream.rcap)}, rx)
    # the stuck watcher (engine side, outside the CLI's process group so a stuck stop does not kill it); a card-less run gets no card block
    watch = subprocess.Popen([sys.executable, "-I", os.path.join(BIN, "stuck.py"), "watch", "--run", run, "--role", rec["role"]] + (["--card", rec["card"]] if rec["card"] else []),
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    rc = ax = None
    try:
        if agent is not None:   # X1 item A: the run loop speaks the entry's protocol; the record's exit is its outcome (DC-05)
            import agent_runtime
            rc = agent_runtime.loop(p, s, rec, e, env, d, agent)
        else:
            for raw in p.stdout:
                try:
                    s.line(raw)
                except Exception as x:   # one bad line never ends the supervisor (RTF-01): the run is still ended, snapshotted and revoked
                    with contextlib.suppress(Exception):
                        event("adapter.stream-error", run, rec["role"], adapter=rec["adapter"], card=rec["card"], error=type(x).__name__)
            rc = p.wait()
    finally:
        if agent is not None:   # an agent is a server that never ends by itself: its group ends after the loop; its own status is agent_exit
            for sig in (signal.SIGTERM, signal.SIGKILL):
                with contextlib.suppress(Exception):
                    os.killpg(p.pid, sig)
                    ax = p.wait(timeout=d.get("stop_grace_s", 10))
                    break
        if rc is None:   # the loop itself failed: end the CLI's group so the run cannot outlive its supervisor
            with contextlib.suppress(Exception):
                os.killpg(p.pid, signal.SIGKILL)
            with contextlib.suppress(Exception):
                rc = p.wait(timeout=30)
        try:
            final = snapshot(rec)
        except Exception:
            final = None
        try:
            update(run, ended=now(), exit=rc, final=final, masked=s.hits or {}, **({"agent_exit": ax} if agent is not None else {}))
        finally:
            try:
                tool([os.path.join(BIN, "run_token.py"), "revoke", "--run", run], C["stop"], "revoking the run token")
            except Exception as x:   # a token left valid is an event, never silent
                with contextlib.suppress(Exception):
                    event("adapter.revoke-failed", run, rec["role"], adapter=rec["adapter"], card=rec["card"], code=C["stop"], error=type(x).__name__)
    try:   # the watcher ends on the result line or after its own stop and block; a stream with no result gets the stop grace, then the end
        watch.wait(3 * d.get("stop_grace_s", 10))
    except subprocess.TimeoutExpired:
        watch.terminate()
    with contextlib.suppress(Exception):   # over the output budget is flagged (event line, catalog code), never a stop
        r = subprocess.run([sys.executable, "-I", os.path.join(BIN, "run_policy.py"), "output-check", "--role", rec["role"], "--events",
                            os.path.join(runs_dir(), run, EVENTS)], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        update(run, output_check=json.loads(r.stdout.strip().splitlines()[-1]))
    with contextlib.suppress(Exception):
        event("adapter.run-ended", run, rec["role"], adapter=rec["adapter"], card=rec["card"], exit=rc)
    return rc


def cmd_stop(a):
    rec = read_rec(a.run)
    pg = rec.get("pgid")
    update(a.run, stopped=(a.reason or "stopped")[:200])   # before the kill: whoever sees the run ended also sees why
    try:   # the token first (RT3-06): a process group that does not end must not keep a live token
        tool([os.path.join(BIN, "run_token.py"), "revoke", "--run", a.run], C["stop"], "revoking the run token")
        err = None
    except Stop as x:
        err = x
    if rec.get("exit") is None and type(pg) is int:
        grace = doc().get("stop_grace_s", 10)
        for sig, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, grace)):
            with contextlib.suppress(ProcessLookupError):
                os.killpg(pg, sig)
            for _ in range(wait * 10):
                try:
                    os.killpg(pg, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                continue
            break
        else:
            raise Stop(C["stop"], f"the process group of run {a.run} did not end")
    if err:
        raise err
    event("adapter.run-stopped", a.run, rec.get("role"), reason=(a.reason or "stopped")[:200], card=rec.get("card"))
    print(json.dumps({"run": a.run, "stopped": True}))
    return 0


def cmd_logs(a):
    rec = read_rec(a.run)
    p, pos = os.path.join(runs_dir(), a.run, LOG), 0
    while True:
        with contextlib.suppress(FileNotFoundError), open(p, encoding="utf-8", errors="replace") as f:
            f.seek(pos)
            chunk = f.read()
            pos = f.tell()
            sys.stdout.write(chunk)
            sys.stdout.flush()
        if not a.follow or (rec.get("exit") is not None and not chunk):
            return 0
        time.sleep(0.5)
        rec = read_rec(a.run)


def cmd_evidence(a):
    print(json.dumps(evidence(read_rec(a.run))))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="adapter.py", description="Worker adapters: start, stop and judge a coding CLI's run.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list").add_argument("--json", action="store_true")
    v = sub.add_parser("version"); v.add_argument("--adapter", required=True); v.add_argument("--json", action="store_true")
    s = sub.add_parser("start")
    for k in ("adapter", "role", "worktree", "brief-file"):
        s.add_argument("--" + k, required=True)
    for k in ("card", "card-file", "link", "project", "run-id"):
        s.add_argument("--" + k)
    s.add_argument("--wait", action="store_true"); s.add_argument("--json", action="store_true")
    p = sub.add_parser("stop"); p.add_argument("--run", required=True); p.add_argument("--reason")
    g = sub.add_parser("logs"); g.add_argument("--run", required=True); g.add_argument("--follow", action="store_true")
    x = sub.add_parser("evidence"); x.add_argument("--run", required=True); x.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    try:
        if a.cmd in ("start", "stop", "logs", "evidence"):
            w = worker_env.reason()
            if w:
                raise Stop(sd.Refused.code, f"adapter.py {a.cmd} runs on the engine side only ({w}); nothing was read")
        return globals()["cmd_" + a.cmd](a)
    except Stop as s_:
        x = s_
    except el.EventError as e:
        x = Stop(e.code, e.problem)
    except sd.DataError as e:
        x = Stop(getattr(e, "code", "STL-CFG-310"), str(e)[:180])
    except Exception as e:   # never a traceback: the type only
        x = Stop(C["prepare"], f"{type(e).__name__}, an unexpected failure of adapter.py {a.cmd}")
    if getattr(a, "json", False):
        print(json.dumps({"ok": False, "code": x.code, "problem": el.scrub(x.problem)}))
    return el.fail(x.code, x.problem)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
