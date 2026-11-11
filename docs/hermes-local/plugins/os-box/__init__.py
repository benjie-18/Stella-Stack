"""Hermes terminal backend: every command of a boxed profile runs in its own bubblewrap box (option A).
The mount list is bin/box.py's; which profiles are boxed, and every path, come from the `sandbox` block of roles.json.
Hermes's provider defaults are wrong for this box (is_container / is_remote True would switch its dangerous-command
approvals off), so they are set explicitly. The environment is NOT a LocalEnvironment (the file tools would then read
the files natively, outside the box); it reuses Hermes's env scrub and process-group kill by call. Any doubt refuses
the terminal (RuntimeError with STL-GRD-603): there is no unboxed fallback.
"""
import contextlib, contextvars, glob, os, pwd, subprocess, sys, time

sys.path.insert(0, "/workspace/bin")   # the stack's role table reader and mount planner (stdlib only), as the hooks do
import box, roles

_COMMAND = contextvars.ContextVar("os_box_command", default=None)
from agent.terminal_env_provider import TerminalEnvironmentProvider
from tools.environments.base import BaseEnvironment
from tools.environments.base_output import _pipe_stdin
from tools.environments.local import _find_bash, _kill_process_group_posix, _make_run_env


# Seams the selftest overrides; production values below.
def _stack_root():
    return roles.ROOT


def _hermes_home():
    return os.environ.get("HERMES_HOME") or ""


def _home():
    return pwd.getpwuid(os.getuid()).pw_dir   # not $HOME: inside a Hermes worker $HOME is the profile home


def _roots(d):   # the board's project roots, like the write guard (the card proof carries none)
    return [p["repo"] for p in roles.board_projects(roles.board()) if p["repo"]]


def _prove(profile):
    return roles.prove_card(profile)


def _ctx():
    """(table, profile name, hermes root) of the calling profile. Raises when the table or block is unusable."""
    d = roles.load()
    if not roles.sandbox(d):
        raise RuntimeError("STL-GRD-603: roles.json has no sandbox block")
    hh = os.path.realpath(_hermes_home())
    root = os.path.dirname(os.path.dirname(hh)) if os.path.basename(os.path.dirname(hh)) == "profiles" else hh
    for n, folder, _, listed in roles.profiles(d, root):
        if listed and os.path.realpath(folder) == hh:
            return d, n, root
    raise RuntimeError(f"STL-GRD-603: {hh} is not a profile folder with a row in roles.json")


def _proof(d, profile, j):
    """The card facts the box needs: id, folder, branch, body, and the owner's recorded answers (the escalation poller's comments only: their author is a profile
    whose role has `may_answer_for_owner`; the prefix comes from the profile's row in the role table)."""
    t = j["task"]
    prefix = roles.sandbox(d)["profile_overrides"].get(profile, {}).get("review_answer_prefix") or ""
    return {"card": t["id"], "workspace": t.get("workspace_path") or "", "branch": t.get("branch_name") or "", "body": t.get("body") or "",
            "answers": box.trusted_answers(d, j.get("comments"), prefix)}


class BoxEnvironment(BaseEnvironment):
    def __init__(self, cwd="", timeout=60, env=None):
        self._d, self._profile, self._root = _ctx()
        sb = roles.sandbox(self._d)
        if self._profile not in sb["boxed_profiles"]:
            raise RuntimeError(f"STL-GRD-603: profile {self._profile} is not in sandbox.boxed_profiles")
        j, why = _prove(self._profile)
        if why:
            raise RuntimeError(f"STL-GRD-603: the card cannot be proven, terminal refused: {why}")
        self._proof = _proof(self._d, self._profile, j)
        pdir = roles.pdir(self._root, self._profile, self._d["profiles"][self._profile])
        self._tmp = sb["tmp_dir"].replace("{profile_dir}", pdir)
        os.makedirs(self._tmp, exist_ok=True)
        for old in glob.glob(os.path.join(self._tmp, "hermes-snap-*")):   # session snapshots keep exported variables: none outlives the day (delta red-team S6O-06)
            with contextlib.suppress(OSError):
                if time.time() - os.lstat(old).st_mtime > roles.sandbox(self._d)["snapshot_keep_hours"] * 3600:
                    os.unlink(old)
        self._wt = os.path.realpath(self._proof["workspace"])
        self._argv()   # a plan that cannot be built (hidden path in a bind, bad branch, hard link) refuses now, not at the first command
        start = cwd if cwd and os.path.realpath(cwd).startswith(self._wt) else self._wt
        super().__init__(cwd=start, timeout=timeout, env=env, persist_env=True)
        self.init_session()

    def _argv(self):
        try:
            return box.box_argv(self._d, self._profile, self._proof, hermes_root=self._root, home=_home(),
                                roots=_roots(self._d), stack_root=_stack_root(), command=_COMMAND.get())
        except (box.BoxError, roles.RolesError, OSError, RuntimeError) as e:
            raise RuntimeError(f"STL-GRD-603: the box refused, terminal refused: {e}")

    def _snapshot_excluded_passthrough_names(self):
        """Names Hermes must not write into the session snapshot file in the box tmp dir: the broker's secret variables (they stay in each call's own environment)."""
        own = roles.sandbox(self._d)["profile_overrides"].get(self._profile, {}).get("broker_env", {})
        return tuple(sorted({*super()._snapshot_excluded_passthrough_names(), *own}))

    def get_temp_dir(self):
        return self._tmp

    def _run_bash(self, cmd_string, *, login=False, timeout=120, stdin_data=None):
        argv, over = self._argv()
        run_env = _make_run_env(self.env)   # Hermes's secret scrub and delegated-child scrub, then the box's own values
        for n in roles.sandbox(self._d).get("env_unset", []):   # variables of the parent environment that Hermes keeps and no box may see (rule T3)
            run_env.pop(n, None)
        run_env.update(over)
        run_env.pop("HERMES_SCRATCH_DIR", None)   # Hermes points it at a hidden path; the box's scratch is the private /tmp
        proc = subprocess.Popen(
            argv + ["--chdir", self._wt, _find_bash(), *(["-l"] if login else []), "-c", cmd_string],
            text=True, env=run_env, encoding="utf-8", errors="replace", stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL, start_new_session=True)
        with contextlib.suppress(ProcessLookupError):
            proc._hermes_pgid = os.getpgid(proc.pid)
            from gateway.status import get_process_start_time
            proc._hermes_pgid_start = get_process_start_time(proc.pid)
        if stdin_data is not None:
            _pipe_stdin(proc, stdin_data)
        return proc

    def execute(self, command, cwd="", **kwargs):
        # Hermes passes the backend's default_cwd ("/") per call when no workspace is pinned; "/" is not in the card's
        # worktree, so it means "no cwd given": start where the environment is (the worktree, then wherever `cd` went).
        tok = _COMMAND.set(command)   # the raw command, for the box's per-command variables (box.plan broker_when); per call, not per environment (a poller thread shares the environment)
        try:
            return super().execute(command, cwd="" if cwd in ("", "/") else cwd, **kwargs)
        finally:
            _COMMAND.reset(tok)

    def _kill_process(self, proc):
        _kill_process_group_posix(proc)

    def _force_kill_process(self, proc):
        _kill_process_group_posix(proc)

    def cleanup(self):
        """Remove this session's files only: concurrent sessions of the profile share tmp_dir."""
        mine = [self._snapshot_path, self._cwd_file, *glob.glob(f"{self._snapshot_path}.tmp.*")]
        for f in mine:
            with contextlib.suppress(OSError):
                os.unlink(f)


class BoxProvider(TerminalEnvironmentProvider):
    is_remote = False      # Hermes defaults are True: they would drop host hints and file-path handling
    is_container = False   # ... and, through skip_container_guards, the dangerous-command approvals
    supports_streams = False

    def __init__(self, name):
        self._name = name

    @property
    def name(self):
        return self._name

    @property
    def skip_container_guards(self):
        return False

    @property
    def cache_path_base(self):
        return None

    @property
    def default_cwd(self):
        return "/"

    def is_available(self):
        import shutil
        return shutil.which("bwrap") is not None

    def create_environment(self, *, cwd, timeout, task_id="default", image=None, container_config=None, **kwargs):
        if not self.is_available():
            raise RuntimeError("STL-GRD-603: bwrap is not installed, terminal refused")
        return BoxEnvironment(cwd=cwd, timeout=timeout, env=kwargs.get("env"))


def register(ctx):
    sb = roles.sandbox(roles.load())   # an unreadable table raises: no plugin, so Hermes refuses the backend
    if not sb:
        raise RuntimeError("roles.json has no sandbox block")
    ctx.register_terminal_environment_provider(BoxProvider(sb["backend"]))
