# PLAN.md

One section per task. Copy the template below for each new task. Rules for working tasks are in `AGENTS.md`.

Status values: `todo` · `in-progress` · `blocked` · `review` · `done`

| ID    | Task         | Builder                              | Status |
| ----- | ------------ | ------------------------------------ | ------ |
| T-001 | _short name_ | _claude / opencode / hermes / human_ | todo   |

---

## T-001: _short name_

- **Builder:** _claude / opencode / hermes / human_
- **Status:** todo
- **Branch:** `task/T-001-<short-name>`

### Goal

_One or two sentences on what this task delivers and why._

### Acceptance criteria

- [ ] _Observable behavior 1, stated so a test can check it_
- [ ] _Observable behavior 2_

### Test commands

Run exactly these; all must exit 0.

```sh
# e.g. npm run test -- path/to/spec
# e.g. npm run lint
```

### Evidence

_Filled in when closing: commands run, exit codes, trimmed output, screenshot paths._

```text
$ <command>
<output>
exit 0
```

### Notes

_Blockers, decisions, questions for a human._

---

## Post-go-live list

- [ ] Re-enable background skill review for the dispatcher role, safely (Stella app smart skills). Off today
      (`background_review: false` in `docs/hermes-local/roles.json`, D46): in Phase 4 the review fork ran with the dispatcher's
      tools and tried to write a skill about the dispatcher, wrote a memory entry, created two cards and completed one. Turn it
      back on only when its skill and memory changes go through a card for a worker (or an owner-approved path), with the
      role guard and the protected-path rule still in force; one field in roles.json, then `bin/apply-hermes-local.sh`.
- [ ] Decide the STL-RCV-502/503 opening ("noticed at HH:MM that Stella was down and restarted: ..."). It overstates a run
      that only re-applied the firewall, but `bin/alert-selftest.sh` line 104 pins the exact phrase, and a pinned assertion is
      not edited by an agent (AGENTS.md rule 4). If you agree, change the phrase in the catalog and that one regex together
      (D47, wording audit).
- [ ] Add `WORKER_GIT_NAME` and `WORKER_GIT_EMAIL` to `config/owner.env`, and a commented example of both to
      `config/owner.example.env` (protected paths: an agent cannot), then run `bin/apply-hermes-local.sh`. Until then apply says
      "git identity NOT SET" for each worker profile and leaves its home as it is (D48).
- [ ] Prove a worker completes a card live (Stage 6 T7): the commands are in SUPERVISOR.md ("Live proof that a worker completes"); D48 lists what is unproven.
- [ ] Review the replaced assertions in `bin/role-guard-selftest.sh` (D48): the ones that pinned the environment-variable
      mechanism (message text, "a run for another card", "a stale run id", "allowed from environment variables alone")
      were replaced by process-tree equivalents because they contradict the batch 9 brief; they were not weakened to pass.

## Readiness run: selftest assertions replaced (owner authorization, 2026-10-29) or changed by owner decision

| Selftest (where)                                                                                                                                                 | Old assertion                                                                               | New assertion                                                                                                                                                                            | Why / who                                                                                                          |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| write-guard-selftest `run()`, `viaparent`, the "worktree from HERMES_KANBAN_TASK" case, the x-unlisted case                                                      | the worker's card from `HERMES_KANBAN_TASK`/`HERMES_KANBAN_WORKSPACE` or a parent's environ | the card bound to an ancestor worker process (real tree)                                                                                                                                 | env mechanism proven wrong live (t_645f48dd, D48/D51); authorization                                               |
| kanban-guard-selftest (old line 23)                                                                                                                              | card id taken from `HERMES_KANBAN_TASK`                                                     | a bound worker's own card; env-only ids not used                                                                                                                                         | same                                                                                                               |
| role-guard-selftest board fixture                                                                                                                                | board chosen by `HERMES_KANBAN_BOARD=board-x`                                               | the stack's data board (`bin/kanban-board.sh`)                                                                                                                                           | K1 round 2: the proof's board is never caller-chosen (D51)                                                         |
| write-guard-selftest failed-proof needle                                                                                                                         | "no card worktree known"                                                                    | also accepts STL-GRD-603                                                                                                                                                                 | K2 changes that wording by design; the old text blamed a file rule (live evidence)                                 |
| write-guard-selftest (K1b) "cd /tmp allowed"                                                                                                                     | allowed                                                                                     | refused (K1c: the terminal stays in the worktree)                                                                                                                                        | K1c design after verifier round 3; written in this run                                                             |
| owner-config-selftest bad-line list                                                                                                                              | `OWNER_NAME="x"` refused                                                                    | accepted (same value as single quotes)                                                                                                                                                   | owner's K5 decision 2026-10-29                                                                                     |
| write-guard-selftest:143 (K6)                                                                                                                                    | builder `read_file` of the owner file passes the write guard                                | kept unchanged: it pins the write guard's scope (its matcher never sends `read_file`); the K6 refusal of reads is asserted against the secret guards in `bin/owner-settings-selftest.sh` | owner's K6 decision 2026-10-29                                                                                     |
| secret-read-selftest "builder allowed: `grep -rn TODO .`" and "`find . -name "*.md"`" (K6)                                                                       | allowed with cwd `/workspace`                                                               | the same commands on `bin`/`docs` allowed; `.` in `/workspace` refused (it recurses into the folder holding the owner settings file)                                                     | owner's K6 decision 2026-10-29 (reads refused)                                                                     |
| profile-hooks-selftest reviewer allowed rows `git diff --name-only`, `git diff --stat`, `git diff --stat HEAD~1 HEAD`, `git -C ./wt log --oneline -n 3` (RT6-02) | allowed                                                                                     | each rewritten with exactly one range / an absolute `-C`; the old forms are refusal rows                                                                                                 | red-team RT6-02: rows written in this run (K9), narrowed after its finding                                         |
| alert-selftest RCV-502 text regex (K10)                                                                                                                          | "restarted" wording that claims more than the trigger proves                                | the K10 wording ("found part of Stella not running and started it again")                                                                                                                | authorized replacement: the old text pinned a claim proven wrong                                                   |
| role-guard-selftest D47 name check                                                                                                                               | no profile name in role-guard.py/roles.py                                                   | Hermes API words listed in `docs/hermes-local/hardcode-allow.json` aside                                                                                                                 | owner decision 2026-11-04 (K8: Hermes's `reviewer` argument)                                                       |
| owner-config-selftest "default SOUL carries the builder-local delegate-command rule"                                                                             | rule present                                                                                | rule absent; "no shell command in card bodies" asserted                                                                                                                                  | owner decision 2026-11-04 (K9)                                                                                     |
| model-watch-selftest "the board cannot be read" and "the board answers with garbage" (K4)                                                                        | an empty list                                                                               | exit 1, nothing on stdout                                                                                                                                                                | verifier B2V-04: an empty list read as "all clear" and resolved open STL-MDL-701 streaks; rows written in this run |
| escalation-reply-poll-selftest "a malformed id behaves as empty"                                                                                                 | the reply is applied; OWNER_ID_INVALID logged and alerted once                              | the reply is not applied and not marked seen; same log and alert; a new control applies it after the id is corrected                                                                     | owner decision 2026-11-08 (ultrareview finding 8, D72: fail closed)                                                |
| escalation-reply-poll-selftest "with the id empty, today's behaviour"                                                                                            | any human's reply and reaction count; one OWNER_ID_EMPTY warning                            | no reply or reaction counts; nothing marked seen; OWNER_ID_EMPTY logged and STL-CFG-302 alerted; new controls for the owner's reaction                                                   | owner decision 2026-11-08 (ultrareview finding 8, D72: fail closed)                                                |

## Ultrareview fixes (2026-11-08): findings 1, 2, 3, 8

Tracking (owner decision 2026-11-08): this section only, uncommitted on `main`. No Kanban cards or branches: the only project slug on the board is the retired `stella`, a worktree lacks the uncommitted Stage 5 files, and no commit is allowed. Each failing test was run from a scratch copy and installed together with its fix, so the 15-minute watchdog never saw a red tree. `$S` is the session scratch directory. Every selftest ran under `flock .scratch/readiness/test.lock` with `hermes send` refused by a PATH shim. Selftests are simulated (stubs), not live.

### Finding 2: post-edit hook stalled every edit and never reached lint

- Confirmed: `jq -c '.hooks.PostToolUse' .claude/settings.json` shows matcher `Edit|Write|MultiEdit`, `"timeout":120`, `scripts/post-edit-check.sh`.
- Fix: `scripts/post-edit-check.sh` runs lint only; the watchdog runs the suite. `.claude/settings.json` not edited. Test: `bin/post-edit-check-selftest.sh` (new).
- Red, old hook: `bash $S/post-edit-check-selftest.sh` exit 1: `FAIL the slow suite is not run after an edit (11-13 min against a 120 s hook timeout)`, `selftest FAIL (1)`.
- Green, installed: `bin/post-edit-check-selftest.sh`: 3 ok, `selftest PASS`. Real hook on this tree: `echo '{}' | CLAUDE_PROJECT_DIR=/workspace scripts/post-edit-check.sh` exit 0 in 0.43 s.

### Finding 1: Windows-path check refused valid cards

- Fix: `bin/false-close-guard.py`: `delegate_output` is not scanned; the deliverable's own paths are removed first, whole and case-insensitively; `WINPATH` needs a left boundary and a first folder of 2+ characters; the refusal says how to recover. Known limit (`shortcut:` comment): a wrong path whose first folder is one letter is not caught.
- Red, old guard: `bash $S/false-close-guard-selftest.sh` exit 1, 22 ok, `selftest FAIL (7)`: delegate_output with escapes or a path, escapes in the summary, lower-case drive, upper-case path, Markdown bold, recovery wording, stack path with a space.
- Green: `GUARD=$S/staged/false-close-guard.py bash $S/false-close-guard-selftest.sh` exit 0, 29 ok; `python3 -m py_compile` exit 0; installed `bin/false-close-guard-selftest.sh` exit 0, `selftest PASS`. Controls still refused: `$WIN.bak`, a wrong path in the summary, a wrong path in another metadata key, a wrong path with a space.

### Finding 3: slow alert blocked every other Haiku call

- Fix: `bin/escalate.sh`: `flock -u 7` before `limit`.
- Red, old script: `bash $S/escalate-selftest.sh` exit 1, 52 ok: `FAIL the Haiku lock is free while the alert is being sent`, `FAIL a second over-limit Haiku call is refused at once, not held behind the slow alert (exit 124)`.
- Green: `ESCALATE=/workspace/bin/.escalate.sh.tmp bash $S/escalate-selftest.sh` exit 0, 54 ok, second call `(exit 3)`; `bash -n` exit 0; installed `bin/escalate-selftest.sh` exit 0, `selftest PASS`.

### Finding 8: empty or malformed owner id let anyone unblock a card (D72)

- Fix: `bin/escalation-reply-hook.sh` and `bin/escalation-reply-poll.sh` fail closed, replies and reactions alike; STL-CFG-302 is alerted for empty as well as malformed. Wording updated: `bin/owner-config.sh`, `docs/hermes-local/alert-catalog.json`, generated `docs/alert-codes.md`, `docs/recovery.md`, `decisions.md` (D39 pointer, D72). Two poller assertions replaced, see the ledger above.
- Red, old hook: `bash $S/escalation-reply-hook-selftest.sh` exit 1, `selftest FAIL (5)`. Red, old poller: `bash $S/escalation-reply-poll-selftest.sh` exit 1, 75 ok, `selftest FAIL (3)`: malformed id, empty id, reaction with an empty id.
- Green: `STAGE=$S/staged bash $S/escalation-reply-hook-selftest.sh` exit 0, `selftest PASS`; `POLL=/workspace/bin/.escalation-reply-poll.sh.tmp bash $S/escalation-reply-poll-selftest.sh` exit 0, 78 ok. `bin/owner-config-selftest.sh` exit 0, `bin/alert-selftest.sh` exit 0, `bin/alert-catalog.sh --check` exit 0, `npm run --silent lint` exit 0.
- Not changed: `config/owner.example.env:10` still says `Empty = any human.` The edit was refused by permission settings (the `config/` directory is denied). Owner to correct: `Empty or malformed = nobody's, until it is fixed (D72).`

### Full suite on the final tree

`flock .scratch/readiness/test.lock npm test` (2026-11-08T20:24:16Z to 20:36:50Z): exit 0, 32 `ok`, no `FAIL`, no `skip`, `selftests PASS`. The cron watchdog's own suite overlapped this run.

### Independent verification (one pass, no red-team round)

`readiness-verifier`, fresh context: PASS WITH NOTES. Findings 2, 3 and 8 PASS. Finding 1 PARTIAL: its named requirements and controls pass, but some valid cards can still be refused (first item below). Selftest evidence only; no fix was exercised live. UNVERIFIED, because the permission system denied the verifier's fixture-writing probes: its own inputs end to end through the real guard, hook and poller; a real-npm lint failure; a parallel Haiku race. It used file-free regex and jq evaluation instead. Also UNVERIFIED by it: "no assertion weakened" for `bin/false-close-guard-selftest.sh` and `bin/escalate-selftest.sh`, whose pre-change copies were not kept (their new rows are appended).

### For Option A (not fixed: this was the only fix round)

- [ ] Medium, `bin/false-close-guard.py` `PATH_END`, `WINPATH`: valid cards can still be refused. `[<right path>]`, `{<right path>}`, `<right path>!`, and a lone letter before an escape with 2+ characters (`"Q:\nAnswer"`, `grep -E 'a:\d+'`). The second kind needs a decision: refusing less there also stops catching a bare `D:\wrong`.
- [ ] Medium, regression from finding 1's fix, `bin/false-close-guard.py` `WINPATH`: a wrong path written with doubled backslashes (`C:\\other\\report.md`) is now accepted; the old regex matched it and refused. `C:/other/report.md` was accepted before too.
- [ ] Medium, `bin/escalation-reply-poll.sh` `owner_id`: the malformed-id marker is written before `alert STL-CFG-302`. If the send fails, the alert is never retried for that value and, now that this path fails closed, the owner is locked out silently. Fix: write the marker only after the alert succeeds. Found by reading, not run.
- [ ] Low, `bin/false-close-guard.py`: `<right path> copy.md` is accepted (prose cannot show where a path with a space ends).
- [ ] Low, `bin/false-close-guard.py`: the same refusal says "final for this attempt" and "then call kanban_complete again".
- [ ] Low, owner-only files: `.claude/settings.json` `statusMessage` still says "Running tests and lint"; `config/owner.example.env:10` still has the old comment (above).


## Option A (OS box): build evidence (2026-11-08; D73)

Task: build option A from `.scratch/readiness/option-A-design.md` rev 4 (human `.devcontainer` step already done). Not committed or pushed. No guard row dropped (open item B1). No suite file changed (`bin/selftests.sh`, `bin/hardcode-lint-selftest.sh`, `package.json` untouched) (later, on the owner's instruction: `bin/box-selftest.sh` joined `bin/selftests.sh` and the lint scans the plugin folder, see the red-team fixes section). **Replaced assertions: none in the suite.** One of my own new checks changed: `bin/box-selftest.sh` 1.5 asserted that a `boxed_profiles` name without a row makes the table invalid; the pinned `merge-card-selftest` (which deletes the reviewing profile from a scratch table) showed that couples unrelated guards to the box block, so 1.5 now asserts the table loads and `roles.coverage` reports the gap (D73). (Design 4.4 expected a new "Replaced assertions" entry for the commit-guard marker path: no pinned selftest row was removed or changed, so there is nothing to replace; the marker path is covered by `bin/box-selftest.sh` 3.2 and 4.5.)

| Step | Command (run from /workspace) | Exit | Key output |
|---|---|---|---|
| P1 | `bwrap --unshare-user --ro-bind / / true` | 0 | |
| P2 | `bwrap --unshare-user --unshare-pid --ro-bind / / --proc /proc --dev /dev true` | 0 | `systempaths=unconfined` works |
| P3 | `unshare -Ur true` unboxed / in the box (`--disable-userns`) | 0 / 1 | boxed: `unshare failed: No space left on device` |
| P4-P6, P12, git routes | see `.scratch/readiness/optionA-probes.md` | | P6 passes only with the tmpfs-root rule; P8: dispatcher stays unboxed; P12: 107/118 GET routes 401, POST not probed |
| TDD red, layer 1 | `flock .scratch/readiness/test.lock bin/box-selftest.sh` before `roles.py` had the validator | 1 | `FAIL 1.3 ... 1.26` (23 FAIL) |
| TDD red, layer 2 | same, before `bin/box.py` existed | 1 | `ModuleNotFoundError: No module named 'box'` |
| TDD red, live bugs | same with 4.13, 4.14, 2.37, 4.15, 4.16 added before their fixes | 1 | each failed alone for the stated reason |
| Final selftest | `flock .scratch/readiness/test.lock bin/box-selftest.sh` | 0 | `134 ok, 0 FAIL`, "box selftest PASS" (`box-selftest-final.log`, rerun after fix round 2) |
| Mutation checks | staged copies of `bin/box.py` / the plugin with one rule removed, same selftest | 1 each | secret drop (2.7, 3.25), owner/canary drop (almost every check, `verify()` refuses), branch folder rw (2.16), gitdir overlay (2.18, 3.9), remount ro (2.20, 2.21, 3.5), symlink out of root (2.9); plugin: provider flags (4.1), env scrub (4.4), card proof (4.9), cleanup (4.8) |
| Existing selftests | `roles`, `roles-complete`, `profile-hooks`, `secret-read`, `write-guard`, `owner-settings`, `hardcode-lint` | 0 each | each ends `selftest PASS` (`optionA-<name>.log`) |
| Checks | `python3 bin/roles.py check ~/.hermes`; `bin/apply-hermes-local.sh --check`; `bin/register-toolsets.sh --check` | 0, 0, 0 | `table valid, every profile has a row`; 0 DRIFT lines |
| Live control (unboxed) | `bin/box-live-probe.sh /workspace/boxcanary/canary.txt` in a throwaway clone | 0 | canary rc=0/0, 7 git routes `REF-WRITTEN` (`box-live-control.txt`) |
| Live boxed builder-local | cards t_0b0a6302, t_f53f7f2d (scratch project; worker ran the probe as one terminal command) | card blocked on purpose | canary rc=1/1, `unshare` rc=1, outside-worktree write rc=1, commit rc=0, home writable, 7 git routes `refs-unchanged`; `read_file` README.md real content, canary `File not found`, `write_file` created a file (`box-live-boxed-card4.txt` for t_0b0a6302; t_f53f7f2d: probe lines in the card comment, file-tool results in its session) |
| Live boxed reviewer | card t_a3607a86 (`box-live-reviewer.txt`) | blocked on purpose | `read_file` canary `File not found`; `read_file` README.md its real two lines |
| Live process tree | `ps --forest` during the probe hold (`box-live-watch3.txt`, card t_700d4b37) | | gateway > `agent.managed_worker` > `bwrap` > `bwrap` > `bash` (snapshot from `box-tmp`) > probe > `sleep 25` |

Live-found defects (each now a red-then-green selftest case): per-call cwd `/` (4.13), `$HOME` of a worker is the profile home (4.14, 2.37), `setlocale` warning corrupting the file tools' probes (4.15, 4.16). Cards t_d353749f and t_cef6aea3 are the failed attempts; t_700d4b37 ran with the home bug. Both profiles were reverted to unboxed for about 20 minutes while the file-tool bug was fixed (no card but my probes ran).

Independent review: verifier `findings/verify-optionA.json` FAIL (V-A-01: fixed test-first, round 1); red-team `findings/RT-optionA.json` FAIL (RT-A-01 blocker open in part, RT-A-02 partly fixed; round 2, the last). Live after round 2: cards t_486dcef0 (builder, `pth_plant` rc=1, `bashrc_write` rc=1, control rc=0) and t_9c5c0bc9 (reviewer). Update 2026-11-09: RT-A-01 and RT-A-02 were worked on afterwards, see the section "Option A red-team fixes" below (D74).

Open or unproven (see D73): builder-claude not flipped (needs the owner's `claude auth login`); dispatcher unboxed (P8); P9, P11, M8 UNVERIFIED; P12 residual (POST routes, `/auth/native/authorize`); `search_files`/`patch`/`npm test` in the box not run live; `stella-recover.ps1` hint line not parse-checked (no PowerShell here); `box-selftest.sh` is not in `bin/selftests.sh` and the hardcode lint does not scan `docs/hermes-local/plugins/` (M6): both are suite changes left to the owner.

## Option A red-team fixes: RT-A-01 and RT-A-02 (2026-11-09; D74)

Task: fix the two open red-team findings of option A (`.scratch/readiness/REPORT.md` section 15). Not committed or pushed. Test first for every change (red against the unfixed files, then green). Suite changes authorised: `bin/box-selftest.sh` added to `bin/selftests.sh`, the hardcode lint scans `docs/hermes-local/plugins/`. No selftest assertion removed or loosened (diff against `.scratch/readiness/pre-rta/`, `pre-rta2/`, `pre-rta3/`). No guard row dropped (B1 still open).

| Step | Command (from /workspace) | Exit | Key output |
|---|---|---|---|
| RT-A-02 red | `flock .scratch/readiness/test.lock env -i HOME=$HOME PATH=$PATH bash .scratch/readiness/stage-rta/merge-card-selftest.sh` (installed script) | 1 | `FAIL` on: rewritten `.git`, rewritten `commondir`, `config.worktree` fsmonitor, `config.worktree` hooksPath, dirty tree behind an overwritten `.git`, unreadable status (6); premise cases `ok` (`stage-rta/red-mc.log`) |
| RT-A-02 green | same, `MC=<staged merge-card.sh>` | 0 | 49 ok, `selftest PASS` |
| RT-A-02 mutations | staged script with one protection removed (no `GIT_COMMON_DIR`, no `--git-dir`, no `-c core.fsmonitor=`, no `-c core.hooksPath=`, no unreadable-status refusal) | 1 each | at least one `FAIL RT-A-02` per mutation |
| RT-A-01 red | `.../profile-hooks-selftest.sh` with the installed registration script | 1 | `FAIL` x5 (`RT-A-01: every registered .py hook command is python3 -I`, allowlist, planted `.pth`, `--check`, apply rewrites in place); control `ok` (a bare hook runs the `.pth`) (`stage-rta/red-ph.log`) |
| RT-A-01 green | same, staged `register-escalation-hook.sh`, `roles.py`, `false-close-guard.py` | 0 | 463 ok, `selftest PASS` |
| Install, round 0 | `bash .scratch/readiness/install-rta.sh` | 0 | `apply rc=0`, `apply --check rc=0`, `bare .py commands left: 0`, `python3 -I commands registered: 21`, `INSTALLED` (`install-rta.log`) |
| Live .pth run | `"$HPY" -I .scratch/readiness/stage-rta/live-spawn.py <scratch home> [bare]` (every live-registered hook through Hermes's `_spawn`, planted user-site `.pth`) | 0 | bare: `hooks=15 pth_fired=15`; as registered: `hooks=15 pth_fired=0 import_or_spawn_errors=0` (`rta-live-spawn.txt`) |
| Suite run 1 | `flock test.lock flock watchdog.lock env -i ... npm test` 01:59:50Z-02:13:06Z | 0 | 33 ok, 0 FAIL, `selftests PASS` (`suite-rta-1.log`) |
| Lint | `bash bin/hardcode-lint-selftest.sh` | 0 | 4 ok incl. "the terminal backend plugin is scanned too"; a literal planted in a scratch copy of the plugin: `FAIL ... x2 (allowed 0)`; with the old file list that check fails instead |
| Verifier (fresh) | `findings/verify-rta.json` | | FAIL on C7: V-RTA-01 (high) a submodule's clean filter ran through the status line; C1-C6, C8-C10 PASS |
| Round 1 | submodule case red on the installed script (`FAIL RT-A-02: a submodule config ...`), then `--ignore-submodules=dirty`; V-RTA-06 case red then fixed; `bash .scratch/readiness/install-rta2.sh` | 0 | merge-card 49 ok; profile-hooks 463 ok; `apply rc=0`, `apply --check rc=0`, `INSTALLED` (`install-rta2.log`) |
| Red-team (fresh) | `findings/RT-rta.json` | | FAIL: RT-RTA-01 (blocker, planted `~/.gitconfig` with `trace2` appends to any owner-writable file from `git-guard.py`'s `git rev-parse`), RT-RTA-02 (high, planted `~/.jq` in `kanban-guard.sh`); RT-A-02's status line held; RT-RTA-03 low |
| Round 2 (last) | `bin/box-selftest.sh` 2.45 red against the unchanged table (`FAIL 2.45`), 3.28/2.46 red with the entries removed from the fixture; `roles.json` `sandbox.home_protect` += `.gitconfig`, `.config/git/`, `.jq`; `bash .scratch/readiness/install-rta3.sh` | 0 | `roles.py check rc=0`, `apply rc=0`, `apply --check rc=0`, `box-selftest rc=0 (138 ok, 0 FAIL)`, `INSTALLED` (`install-rta3.log`) |
| Suite run 2, final tree | `flock test.lock flock watchdog.lock env -i HOME=$HOME PATH=$PATH npm test` 03:14:38Z-03:28:03Z | 0 | 33 ok, 0 FAIL, `selftests PASS` (`suite-rta-2.log`) |
| Freeze | `sha256sum -c .supervisor/state/stage5-freeze.sha256` (regenerated after the docs, last) | 0 | 114 OK, 0 FAILED (`freeze-check-rta.out`); the previous manifest `stage5-freeze-114.sha256` fails on 12 files changed since (the 8 of round 0, plus `box-selftest.sh`, `roles.json`, `decisions.md`, `SUPERVISOR.md`) |

Not proven: a live card through the new read-only binds; the hook environment's contents; the migration write-order race (V-RTA-05). Open and recorded, not fixed: RT-RTA-03, V-RTA-03/04/05 (low); source-side hardening of the hooks' `git` and `jq` (done afterwards, section "Hooks do not depend on HOME" below; it was a guard change, the owner's to approve); builder-claude and the dispatcher are unboxed.

## Hooks do not depend on HOME for git, jq and hermes config (RT-RTA-01/02 source side; 2026-11-09; D75)

Task: make the hooks ignore a planted `~/.gitconfig`, `~/.config/git/config` and `~/.jq` themselves, so the read-only binds of D74 are a second layer, not the only one. Not committed or pushed; nothing posted to Discord; one session; no guard row dropped; the suite untouched except test rows this fix needs. Test first, red against the unfixed files, then green. Evidence directory `.scratch/readiness/` (`red-hh/`, `live-spawn-hh.txt`, `install-hh*.log`, `suite-hh-*.log`, `findings/verify-hh.md`, `RT-hh.md`).

| Step | Command (from /workspace) | Exit | Key output |
|---|---|---|---|
| Red, round 0 | `.scratch/readiness/stage-hh/red-hh.sh 0 .scratch/readiness/red-hh` (new rows against the saved originals) | 1 each | profile-hooks 31 FAIL, kanban-guard 4, escalation-reply-hook 1; every FAIL is an `RT-RTA` row (`red-r0-*.log`); thread selftest row red when written (terminal only) |
| Live control | `python3 .scratch/readiness/stage-hh/live-spawn-cfg.py <scratch> before-orig orig` (saved unfixed hooks through Hermes's `_spawn`) | 0 | `cases=27 planted_file_took_effect_or_wrong_decision=18` |
| Install, round 0 | `bash .scratch/readiness/install-hh.sh` (two earlier attempts rolled back on test bugs of mine: a card id shared with the F1 row, stub `jq` reading the planted file) | 0 | `apply rc=0`, `apply --check rc=0`, profile-hooks 486 ok, kanban-guard 44, reply-hook 10, thread 38, `INSTALLED` (`install-hh.log`) |
| Suite run 1 | `env -i ... flock test.lock flock watchdog.lock npm test`, 05:37:20Z-05:50:24Z | 0 | 33 ok, 0 FAIL (`suite-hh-1.log`; predates rounds 1 and 2) |
| Verifier (fresh) | `findings/verify-hh.md` | | FAIL: HH-01 high (hermes children ran git with the profile HOME), HH-02 medium (dubious ownership fail-open), low items |
| Round 1 | red: `red-hh.sh 1` (profile-hooks 11 FAIL, kanban-guard 1); `bash .scratch/readiness/install-hh2.sh` | 0 | `GIT_CONFIG_GLOBAL` for hermes children, `output_into_main` refuses on dubious ownership, static bypass check; 497 ok profile-hooks, 48 kanban-guard, 10 more selftests green (`install-hh2.log`) |
| Red-team (fresh) | `findings/RT-hh.md` | | git and jq held; HH-01/02 (hermes reads `pip.conf`, `~/.hermes`), HH-03/04 (round 1 regressions: container-start, escalate), HH-05 high and HH-06 medium outside this change |
| Round 2 (last) | red: `red-hh.sh 2` (profile-hooks 11 FAIL, kanban-guard 1); `bash .scratch/readiness/install-hh3.sh` | 0 | five hooks and `roles.py` run hermes with the account HOME; shared scripts export nothing; profile-hooks 498 ok, kanban-guard 48, reply-hook 10, thread 38, roles 71, role-guard 202, check-guard 247, complete-gate 152, alert-page 21, delegation 38, owner-config 54, container-start 12, escalate 54; `apply --check` rc 0 (`install-hh3.log`) |
| Live, final | `python3 .scratch/readiness/stage-hh/live-spawn-cfg.py <scratch> after` and the `orig` control, final driver, both under the test lock | 0 | control 18 of 27; installed `cases=27 ... =0` incl. the `pip.conf` FIFO case (control: hermes times out; installed: finishes); `live-spawn-hh.txt` |
| Suite run 2, final tree | `flock test.lock flock watchdog.lock env -i HOME=$HOME PATH=$PATH npm test`, 07:25:35Z-07:38:41Z | 0 | 33 ok, 0 FAIL, `selftests PASS` (`suite-hh-2.log`) |
| Freeze | `sha256sum -c .supervisor/state/stage5-freeze.sha256` (regenerated last, after the docs; old manifest kept as `stage5-freeze-114-hh.sha256`) | 0 | 114 OK, 0 FAILED (`freeze-check-hh2.out`) |

Not proven: a live card (the runs are scratch HOMEs through `_spawn`); other files the hermes CLI or its python children read from `HOME` (none further found); jq 1.7+ behavior; the `~/.hermes` symlink and `hermes send`/`block`/`comment`/`unblock` start-up opens were not exercised live; round 2 had no third independent pass. Open and recorded, not fixed: HH-05 (high, `bin/box.py:95-104` shares the `refs/heads/<slug>` folder, so a boxed builder can repoint another card's branch; `merge-card.sh` does not check the reviewed commit), HH-06 (medium, `HOME=<dir> git commit` skips commit-guard), HH-07 (low, `bin/escalation-reply-hook-selftest.sh` untracked and outside the freeze), RT-RTA-03 and V-RTA-03/04/05 (low, from D74).

## HH-05 and HH-06: a boxed builder's branch ref, the reviewed commit, and the HOME override (2026-11-09; D76)

Evidence files are under `.scratch/readiness/`. Nothing committed, pushed or posted; no guard row dropped; the `home_protect` binds in `roles.json` untouched. Two fix rounds allowed, two used (round 2 = the closeout step-0 verifier's N1). Tests first, each red against the unfixed files.

| Step | Command (from /workspace) | Exit | Key output |
|---|---|---|---|
| Premise measured | a read-only bind on one branch file inside a writable folder, then a write to its case variant, in a real bwrap box on /workspace (9p) | | `echo X > T_SIB` overwrote the real `t_sib`; `mv T_SIB.lock T_SIB` replaced it. So the two suggested fixes (bind only the own ref file; read-only binds on the other refs) do not hold on this mount |
| Red, box (HH-05, HH-06) | `flock test.lock bin/box-selftest.sh` with section 3c added (`red-hh05-box.log`) | 1 | FAIL 3.32 3.33 3.34 (sibling repointed: loose, packed-only, case variant), 3.38 3.39 (own ref replaced by a symlink / garbage), 3.40, 3.42 3.43 (`HOME=<dir>` and `XDG_CONFIG_HOME=<dir>` skip the commit hook in the box); controls 3.30 3.31 3.41 ok |
| Red, guard (HH-06) | `flock test.lock bin/profile-hooks-selftest.sh` (`red-hh06-guard.log`) | 1 | 6 FAIL: the HOME= / XDG_CONFIG_HOME= rows |
| Red, merge-card (HH-05) | `flock test.lock bin/merge-card-selftest.sh` (`red-hh05-merge.log`) | 1 | 3 FAIL (moved after the review; no start time; no reflog) |
| Green, round 0 | staged copies, then installed (`mv`): `box.py` private ref view + launcher + `GIT_CONFIG_GLOBAL` pin; `merge-card.sh` review-time check and exact-sha merge; `git-guard.py` refuses `HOME=`/`XDG_CONFIG_HOME=` before git | 0 | box-selftest 153 ok, merge-card 54 ok, profile-hooks 506 ok. Two assertions that pinned the shared writable bind replaced by the equivalent for the private view (2.16, 2.32) |
| Live, real bwrap + real roles.json + real `bin/box.py`, scratch repo on /workspace | `flock test.lock .scratch/readiness/hh-live/demo.sh` (`hh-live/after.txt`) | 0 | boxed `update-ref` of a loose sibling, a packed-only sibling and a case variant: refs unchanged (`sib=763bbe1e pak=763bbe1e` before and after; in the box `git rev-parse` showed the new value); the own branch advanced `6b9d0f3e` to `523ec8c5`; unboxed control with a planted `core.hooksPath=/dev/null` under `HOME=<dir>`: bad-author commit rc 0; boxed: `commit-guard stand-in: REFUSED`, `commit-rc=1` |
| Suite run 1 | `flock test.lock flock watchdog.lock env -i HOME=$HOME PATH=$PATH npm test` 14:17:15Z-14:30:57Z (`suite-hh05-1.log`) | 1 | 32 ok, 1 FAIL: `hardcode-lint-selftest`, `bin/merge-card.sh: "reviewer" x6 (allowed 3)`: my new comment and message; reworded (not allow-listed) |
| Suite run 2 | same, 14:32:08Z-14:45:44Z (`suite-hh05-2.log`) | 0 | 33 ok, 0 FAIL |
| Verifier (fresh) | `findings/verify-hh05.md` | | FAIL: VH-01 high (new: a case-variant write to `$WT/.GIT` reaches the real `.git` file, so a two-call chain made the launcher run `git update-ref` on a fake git folder: a sibling moved with no reflog entry; reproduced live), VH-02 high (pre-existing: writable `objects/` changes content under an unmoved sha; an outside merge brought `EVIL sibling` into main), VH-03/04 low, VH-05 docs |
| Fix round 1 | red: `red-vh-box.log` (3.46 3.47 FAIL), `red-vh-merge.log` (VH-02 row FAIL); then green | 0 | `plan()` refuses a git folder that is not `<root>/.git` of the stack or a board project root; `update-ref --no-deref`; early signals held and forwarded; merge-card reads the tip first and runs `git fsck --no-dangling`. Test fixes: plan.py roots now list the nested project repo (2.33), 3.37 used the wrong tree. box-selftest 157 ok (`vh-box-live.log`), merge-card 55 ok |
| Fix round 2 (N1, closeout step-0 verifier) | red: `flock .scratch/readiness/test.lock bin/merge-card-selftest.sh` with the new N1 row on the unfixed `merge-card.sh` (`n1-red.log`); then a second `git fsck` after the tip re-read in `bin/merge-card.sh` (atomic replace), green: same command (`n1-green.log`) | 1, then 0 | red: `FAIL N1` and `FAIL VH-02` (cascade: the unfixed run merged the damaged blob); green: `selftest PASS`, 56 ok. The N1 row's `test.sh` corrupts the card's own blob during `npm test`; it sits before VH-02 and restores the blob after itself. Not run: the full suite. |
| Install | `bin/apply-hermes-local.sh` then `--check` (`apply-hh05.out`, `apply-check-hh05.out`) | 0, 0 | git-guard DRIFT in builder-local and builder-claude before (the intended change), 0 after; `box.py` and `merge-card.sh` are read from /workspace/bin |
| Red-team (fresh) | `findings/RT-hh05.md` | | PASS: ref boundary, VH-01 allow-list, commit-graph forgery, loose-object swap all held; two low accepted items (below) |
| Suite run 3, final tree (after round 1, install and docs) | same command, 15:37:26Z-15:58:10Z (`suite-hh05.log`) | 0 | 33 ok, 0 FAIL, `selftests PASS` |
| Freeze | `sha256sum -c .supervisor/state/stage5-freeze.sha256` (regenerated last, after the docs; old manifest kept as `stage5-freeze-114-hh05.sha256`) | | exit 0: 114 OK, 0 FAILED (`freeze-check-hh05.out`); the old manifest fails on exactly the 8 edited files |

Accepted, not fixed (D76): `env -u GIT_CONFIG_GLOBAL HOME=<planted> git commit` in the box still skips the commit hook (the commit lands on the builder's own card branch; it still needs review and merge-card); the writable shared `objects/` folder lets a box corrupt shared objects (availability; content injection is stopped by the fsck in merge-card); a branch created in the box is dropped; SIGKILL during the write-back can leave a `.lock`.

Not proven: a live card on the board (the box runs are scratch repos driven through `box.box_argv()` and the plugin selftest, not a Hermes worker); builder-claude (not boxed); a private object store (design change, owner's).

## RT-A-04 (`mv .claude`) fix (2026-11-09; D73)

Not committed. Red: `flock .scratch/readiness/test.lock bin/box-selftest.sh` on `bin/box.py` without line 190 (the self-bind; swapped in atomically and restored, sha256 checked) exit 1, `FAIL 3.49` only (new case, real bwrap); log `.scratch/readiness/rta04-red.log`. Probe (`bwrap`, box.py layout, scratch tree): unfixed `mv .claude c.o` rc=0, `rm -rf .claude` rc=0; with `--bind .claude .claude`: `mv: cannot move '.claude' to 'c.o': Device or resource busy`, `rm` EBUSY, `mkdir .claude/projects` and `echo n > .claude/notes` rc=0, `echo x > .claude/settings.json` "Read-only file system", host `settings.json` unchanged. Fix: `bin/box.py` binds `cdir` onto itself before the `ro_over` binds (`ro` for a read-only role). Green: same command on the real `bin/box.py` exit 0, `box selftest PASS`, 159 ok, 3.49 and 3.50 ok; log `.scratch/readiness/rta04-green.log`. Full suite and verifier not run (instruction); closeout step-0 verifier is the independent check.

## Closeout: home_protect second layer (2026-11-09; D76)

`.pip/`, `.config/pip/`, `.hermes/` added to `sandbox.home_protect` (`docs/hermes-local/roles.json`). `flock .scratch/readiness/test.lock bin/box-selftest.sh` exit 0, `box selftest PASS`, 159 ok (`.scratch/readiness/hp2-box.log`); `python3 -I bin/roles.py check` rc 0. Full suite not run (instruction).

## Closeout: builder-claude flip (2026-11-09; D76)

`builder-claude` added to `sandbox.boxed_profiles` in `docs/hermes-local/roles.json`. `python3 -I bin/roles.py check` rc 0; `bin/apply-hermes-local.sh` rc 0, `--check` rc 0 (`.scratch/readiness/flip-apply.out`, `flip-apply-check.out`): `builder-claude: terminal.backend os_box (in sync)`, `plugin os-box enabled`; `default: terminal.backend local` (dispatcher unboxed). `flock .scratch/readiness/test.lock bin/box-selftest.sh` exit 0, 159 ok (`flip-box.log`). Not checked: a live card, `claude` login inside the box (no `home/.claude` yet).
