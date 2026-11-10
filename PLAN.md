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

## Stage 6 closeout (2026-11-09; D77-D81; branch `readiness/stage6-closeout`)

Evidence files are in `.scratch/stage6/` (not tracked). Master plan header read first (read-only, `/plan/AI_Dev_Stack_Revised_Plan.md`): "Version update 2026-10-27, after the Stage 5 audit", 691 lines; it is not at `/workspace`, so the path in the brief was wrong, and no expected header was given to compare against; nothing mismatched in the repo's own references (D34-D37), so work went on.

| Test | Result | Evidence |
| ---- | ------ | -------- |
| T10 benchmark | suite built (5 of the 30-50 tasks R1.4 asks for; the missing categories are named in `bench/suite.json`); 5-task subset run live on builder-local, metrics recorded; **4 of 5 autonomous success** | `bin/bench-selftest.sh` (red `t10-red.log`, green `t10-green.log`); results `t10-results-all.jsonl` |
| T7 end to end | **pipeline PASS, acceptance gap open** (below) | `evidence-t7.txt`, `t7-screenshot-main.png`, `t7-merge.log` |
| T14 OmniRoute smoke | **PARTIAL**: install, loopback, key required, compression off, `/v1/models` PASS; the auto-routed call FAILS (503): firewall (open, human) | `t14-evidence.jsonl`, `omni-install.log`, `firewall-openrouter.diff` |
| T15 pool-exhaustion fallback | **hermetic PASS + live fail-closed PASS; live reroute not proven** (same firewall cause) | `t15-green.log`, `t15-live-escalations.log` |
| T12 approval fallback | **redefined** (D79): no terminal approval path exists; live probe done | `t12-*` section below |
| S6 guard-refusal loop | **PASS as a faithful simulation** (real card, hooks, K3 and thread; the fault is a stand-in, logged as such) | `evidence-s6.txt` |
| T6b approval button | **simulated PASS** (real Hermes approval gate, stub adapter); Discord render and click not exercised | `bin/approval-sim-selftest.sh`, `t6b-green.log` |
| T6c reviewer write refusal | **PASS live, by actual attempt** | `evidence-t6c.txt` |
| T16 thread re-proof | **stack mechanics PASS (exactly once); the worker did not complete it**: owner CLI completion | `evidence-t16.txt`, below |
| T5 +5% attribution | **UNPROVEN** | below |
| S7 GPU cause / Windows restart | restart **attributed to the Stella Watchdog task by the host log**; cause classes proven live for `unreachable` and `other_loaded`; "another model really fills the GPU" not exercised | `s7-gpu-probe.txt`, below |

### T10: the suite (R1.4)

`bench/tasks/<id>/` (task.json with the Check line, the protected test files and a subset flag; `repo/` = red start; `solution/` = reference overlay), `bench/suite.json` (what is missing and why), `bin/bench.sh` (`list`, `check`, `metrics <card>`, `run <id|--subset> --worker <profile> --project <slug>`). `bench.sh check` proves every task is red at its start and green with its reference solution; `run` resets the project's repo to the task start, creates the card, waits, then checks the card branch with the task's original test files over the tip. Success = the branch passes AND the card reached review or done (a card the worker had to block needed a human).

| Task | Card | Success | Status at measurement | Wall | Retries | Escalations | Cost |
| ---- | ---- | ------- | ------------ | ---- | ------- | ----------- | ---- |
| bugfix-range | t_92d7047e | yes | review | 55 s | 0 | 0 | $0 |
| bugfix-nullguard | t_d8bb9902 | yes | review | 147 s | 0 | 0 | $0 |
| feature-multifile | t_34600873 | **no** (put the code in `lib/slug/index.js`, not `lib/slug.js`; blocked) | blocked | 184 s | 0 | 0 | $0 |
| migration-rename | t_337b23fe | yes (second round) | review | 198 s | 0 | 0 | $0 |
| deploy-recovery | t_d46c538f | yes (third round) | review | 213 s | 0 | 0 | $0 |

Round history, so the 4/5 is not flattered. Round 1: migration-rename and deploy-recovery had a correct branch but the card blocked; two defects in the tasks (the Check line `node test.js && ! grep ...` that the check guard cannot track; a `test.sh` that printed nothing, which the guard refuses as no evidence). Round 2: migration-rename fixed (grep moved into the protected test.js) and passed; deploy-recovery re-run (card t_340935a2) **still with the silent `test.sh`**, blocked for the same reason and opened a real owner thread (not a pass). Round 3: `test.sh` fixed (echoes ok), deploy-recovery passed (t_d46c538f). All seven rows are in `t10-results-all.jsonl`; the round-1 rows were written by an earlier `bench.sh` whose success rule did not need the card to reach review, so their `success` field is not comparable. The status column is the status when measured: the reviewer later blocked t_d8bb9902 (bugfix-nullguard) with a wrong claim that its workspace was empty, so that row is a builder success the review lane did not confirm. `success` also means only that the check exited 0 on the branch and the card reached review: a branch that exits 0 early would pass, and review is not approval (S6C-06, open). Not covered: interrupted session, escalation-required (spends Pro pool), discovery. Retries are the assignee's runs beyond the first; cost is the sum of `cost_usd` for the card in escalations.log (all zero: no Claude call).

### T7: end to end (scratch repo `.scratch/s6-scratch`, project `s6-scratch`, never a real project)

Card t_0f87fb99 (builder-local, tests first in its body, `Check: node test.js`): run 143 `review_requested`, run 144 reviewer `completed` metadata `{"review":"approved"}`, status done, 2 `worker_bound` events, 0 STL-GRD-601 lines for the card. `bash bin/merge-card.sh t_0f87fb99 --repo /workspace/.scratch/s6-scratch` printed "merged ... into main: 271c4ec" (the file is not executable on this mount, so it is run through bash). Screenshot `.scratch/stage6/t7-screenshot-main.png` (page renders: button and 0).
**Gap found by me, not by the stack:** the page does not work. `app.js` has no click handler (the card asked for one, but my test text only checked structure); Playwright clicked `#go` twice and `#count` stayed `0` (`t7-click-proof.txt`: `{"before":"0","after_two_clicks":"0"}`). The 9B builder skipped step 2 and the 9B reviewer approved it. T7 as the test words it (a card completes via dispatch, evidence, merge) holds; "a tiny page with a working button" does not, and I did not run a second card to fix it.
Browser tooling note: the repo's Playwright MCP (`.mcp.json`, headless, `--no-sandbox`) hangs on every screenshot and click in this container (even a `data:` page). Working launch flags, found by trying: `--disable-dev-shm-usage --disable-gpu --disable-renderer-backgrounding --disable-background-timer-throttling --run-all-compositor-stages-before-draw` (`shot.cjs`, through `@playwright/mcp@0.0.83`'s playwright-core). `.mcp.json` is not changed (open).

### T14 / T15: OmniRoute (D77)

- Install: `npm install --prefix ~/.hermes/omniroute --save-exact --ignore-scripts omniroute@3.8.53`, rc 0, 1329 packages (`omni-install.log`). Pin: version 3.8.53, integrity `sha512-vHne9/aKN1ULaZijd1pnYnYCp6taAVW6/ERn0CoGv/8fLMw+Hjq/hWy4aHWYT48RWLZZ8ykBAcKGjlZbBCtVZg==` (package-lock; equals `npm view` dist.integrity). Its postinstall script was not run (it only rebuilds native modules); the server started without it.
- `bin/omniroute-ctl.sh start|status|stop`; `status` exit 0 with 4 ok: pinned version and integrity, every listener of the process on 127.0.0.1 (20128, 20131, 20132), compression off (`enabled=false`, `defaultMode="off"`), `/v1/models` without a key = 401 (`REQUIRE_API_KEY=true`; the shipped default is 0.0.0.0 and no key, so both are set on purpose). No other dashboard login was made by me; the owner changed the password and added the keys (human step a). I never read the key file or the data `.env`.
- T14 live (`t14-evidence.jsonl`, one JSON line per attempt): `/v1/models` 200, 156 ms, ok (22:20:10Z). Chat `auto`: HTTP 503 at 22:20:18Z (2710 ms) and 22:21:03Z (2160 ms), routed model and provider empty. Gateway body: the keyless providers it tried first fail (`cloudflare-playground` needs a Chromium runtime OmniRoute lacks; `uncloseai` `connect EHOSTUNREACH` = the container firewall), and the owner's one key-based connection (`openrouter`, `is_active` 0 in its store) cannot be reached either: `curl https://openrouter.ai` fails with rc 7 (`t14-providers.txt`). So no routed model, provider, quota or 429 was observed.
- Firewall (not applied): `.scratch/stage6/firewall-openrouter.diff` is the whole diff: one host, `openrouter.ai`, and a comment. Verified it adds nothing else. Not applied: the session rule forbids editing `init-firewall.sh`, and there is no root to add the address at run time. Human step: apply the diff, rebuild or re-run the firewall, activate the connection in the dashboard, then `bin/omniroute-run.sh` and the evidence log decide what is served.
- Subscription path untouched: no `ANTHROPIC_BASE_URL` in the environment, and a Haiku call through `escalate.sh` succeeded with the gateway running (T5 below: `model_used claude-haiku-5-5`).
- T15 hermetic: `bin/escalate-selftest.sh` (red `t15-red.log`, green `t15-green.log`): low-risk forced pool exhaustion is rerouted and labelled `fallback: true` with the serving model and no Claude fields; `escalations.log` has `POOL_EXHAUSTED` then `FALLBACK`; card comment and `STL-LIM-404` alert; a high-risk card queues and never calls the runner; a failing runner, a runner naming Claude or the requested family, and a disabled config leave `NO_REROUTE` and the queue; a drain replay never calls the runner. T15 live (`t15-live-escalations.log`, temp supervisor dir, gateway enabled in a temp copy of the config): `START, POOL_EXHAUSTED, FALLBACK_FAILED, QUEUED, NO_REROUTE`, exit 75: fails closed. The live reroute itself needs the provider reachable. Side effect of the live probe: `escalate.sh` posted one real comment on card t_422f02d7 and one `STL-LIM-402` message to #alerts (the supervisor dir was a temp copy, the board and Discord were not).
- One config for provider, model, routing, fallback chain and lists: `docs/hermes-local/fallback-routing.json` (shipped `enabled: false`; flip it after a live probe shows a served model). No fallback model or provider is named outside that file; the tests use invented fixture names and `bin/omniroute-run-selftest.sh` fails if a real model-id pattern appears in the config or the runner (a pattern check; the Claude tier names in `escalate.sh` and `claude-haiku-5-5` in this evidence are the Claude lane, not the fallback).

### T12: approval fallback (D79)

Read: `SUPERVISOR.md`/D-F30 (no terminal answer for a tool approval), `bin/escalate.sh` (no approval path), Hermes `gateway/run_inbound.py`, `plugins/platforms/discord/adapter.py`, `gateway/pairing.py`, `gateway/control_socket.py`. Findings: `hermes pairing` can only list, approve, revoke and clear access codes; the gateway control socket has no verb that answers an approval (its verbs are for identity, status, profiles, plugins and update handling); a pending tool approval lives in the gateway process and is answered by `/approve` or the Discord button, and Hermes's pause gate lets those replies through (`_hm_estop_turn_allowed`, `has_blocking_approval`) while it holds new turns, but `hermes pause` also holds the CLI chat, so there is no terminal answer.
Live (all commands by me): `hermes pause` 23:08:43Z (status PAUSED, gateway running); `hermes pairing list` before: "No pairing data found"; the owner sent a DM from the second account; `hermes pairing list` after: still none; `gateway.log` since the pause: only "kanban dispatch paused by global emergency stop"; no "Unauthorized user" line (every unauthorized-DM path in `run_inbound.py` logs one). Cause, from source: the Discord adapter drops a DM from a user outside its allow-list before the gateway can offer a code (`adapter.py:1703-1716` with `_is_allowed_user` `:4106-4150`), so under an allow-list nobody new can get a pairing code. `hermes resume` 23:11:08Z (status not paused). I could not tell a DM that was dropped from one that was never delivered: neither leaves a log line. Nothing was approved, so the pairing list is unchanged.

### T16 re-proof (card t_422f02d7, project s6-scratch)

Worker (builder-local) blocked needs_input at 21:28:51Z; `THREAD_OPENED` 21:28:54Z, link in #supervisor 21:28:56Z; the owner replied "blue": `REPLY` 21:30:20Z, `UNBLOCKED` 21:30:21Z, reactions; the card resumed (run 151). Then: builder-local blocked it again as a capability (workspace confusion; Hermes's auto-decomposer split it into three child cards, which the owner allowed me to unlink and archive), so I reassigned it to builder-claude, which committed `docs/colour.txt` = `blue` (e50fd83). The 9B reviewer then blocked the review twice. The classifier refused my owner comment telling the builder to complete itself (instruction poisoning); I did not work around it. At the owner's choice I ran the documented owner CLI completion, 23:03:57Z. Exactly once: `COMPLETED` x1 and `DELETE_PROMPT` x1 in escalations.log; thread messages read back through the Discord helper: one "Resolved: done" message; #supervisor: one "Done t_422f02d7" and one "Escalation t_422f02d7" link; no card-body text in either (the thread holds the stack's own "Decision needed" posts and the reviewer's own needs_input post). Not met: "card completes from the worker summary" (the summary is the owner's), and the card was not merged (scratch repo).

### S6 (faithful simulation, `evidence-s6.txt`)

Card t_21478fee (builder-local, body: block capability at once). `hermes kanban promote` stands in for Hermes's triage re-promotion (it records `promoted_manual`, not `unblocked`, so K3's window is not reset). A test driver wrote the one `STL-GRD-601` line a guard refusal writes, through the stack's own writer (`alert_catalog.log`), during each of runs 147, 148, 149 (the stack fault itself is the stand-in; this was not a live refusal). Result: `LOOP_TRIAGE` x2 from Hermes, then `K3_REBLOCK` 21:25:46Z "3 runs refused with STL-GRD-601; blocked needs_input", the block reason carries the code and its action text, `THREAD_OPENED` 21:27:18Z, link posted. The card was archived afterwards (owner allowed).

### T6b (simulation) and T6c (live)

`bin/approval-sim.py` runs Hermes's real `tools.approval` gate in a gateway context with a stub where the Discord adapter would send the button message, and calls the same `resolve_gateway_approval` the button and `/approve` use: approve: button data sent (has `request_id`, description "delete in root path"), agent parked until answered, then allowed; deny: parked, then refused. Not exercised: the Discord render and a human click.
T6c: card t_eba65c69 (reviewer): `write_file` and `patch` each returned "the reviewer role is read-only: write_file/patch/skill_manage are blocked"; the terminal write returned the allow-list refusal; no `docs/` folder was created in its worktree.

### T5 and S7

T5: owner readings 6% (5 h) / 32% (weekly) before, 7% / 33% after one Haiku call through `escalate.sh` (23:04:55-23:05:03Z, `model_used claude-haiku-5-5`, `cost_usd` 0.0056, day count 1 of 40, no new meter). The owner's own note: this session spends the same pool and the meters are whole percents, so a +1 cannot be attributed. The earlier +5% is therefore explained only as the other cloud work in its window; **attribution UNPROVEN**.
S7: `bin/model_watch.py` `server_cause` run live against the real server (`s7-gpu-probe.txt`): the profile's own model `loaded`; an installed model that is not loaded gives `other_loaded` (server lists only the profile's model, fully in VRAM: 6902660464 of 6902660464 bytes); with Ollama stopped by the owner at ~23:13Z the container saw `http=000` and cause `unreachable` (23:13:58Z; `s7-down-seen` holds the time, the output itself was read in the session and not saved). The Windows `stella-recover.log` the owner pasted shows `18:15:47 ollama silent: launching ...\ollama.exe`, `18:15:55 ollama ok` (8 s): the Stella Watchdog task restarted Ollama, now proven rather than inferred. The "another model fills the GPU" cause was classified live but not caused: not proven end to end.
Same log, a host defect found: the task ran with the script's parent folder as its workspace (one level above the repo's host folder) and reported "no container: devcontainer up --workspace-folder <that folder>", then "Dev container config (<that folder>\.devcontainer\devcontainer.json) not found" while the container was up, plus "another recovery run is active". With that workspace the container is not found if it is down. Open, host side: check where the task's script lives and pass `-WorkspaceFolder` with the repo's real host folder (docs/recovery.md).

### Verifier and red-team (one pass each, then fix round 1)

Verifier (`readiness-verifier`): PASS WITH NOTES, no blocker; five medium wording or tooling defects, all fixed or recorded here. Red-team (`readiness-security-auditor`, findings `.scratch/readiness/findings/redteam-stage6-closeout.json`): 1 high, 4 medium, 5 low. Fixed in round 1, each with a failing test first (`bench-selftest`, `omniroute-run-selftest`, `escalate-selftest`):
- S6C-01 (high) `bench.sh run` ran the worker's branch code on the host, and `cp -a` of a protected test file wrote through a symlink: the check now runs under bwrap (read-only system, no home, no /workspace, no network, writes only in its temp folder), and a branch holding any symlink is refused.
- S6C-02 an impostor on the gateway port got the endpoint key: the runner now sends the key only when the process listening on the port has its cwd under `gateway.install_dir`; the key goes to curl through a process substitution (no file, not in argv; S6C-07).
- S6C-03 only the exact line `risk: high` was high risk: any spelling of "risk ... high" (tab, NBSP, CR, markdown, "level", "=") now queues. A body with no risk line is still low (the documented default).
- S6C-04 avoid list case, bare model names, non-string providers: lists compare case-insensitively, an unknown provider fails when a list is set, and `enabled: true` needs a non-empty `providers.allow` (the shipped file stays `enabled: false`).
- S6C-05 gateway text reached the comment and the alert: a served model must match `^[A-Za-z0-9._:/+@-]{1,128}$`, the runner's output must be one object with string fields, and Claude-named models are refused in the runner too. S6C-08 large prompts and answers (`--rawfile`, 300 KB answer tested). S6C-09 the alert's cause text now names the real switch. S6C-10 the project binding is an exact match. Empty role chains are refused by `--check`.
- Verifier: `bench.sh` now excludes `.worktrees/` from the bench repo itself (`reset_repo`; the earlier runs relied on a hand-made exclude, and the reset had committed one card worktree as a gitlink and then deleted it); wording corrections above.
- `bin/omniroute-ctl.sh stop` first only killed the server, and the gateway's own launcher restarted it; it now stops the launcher first (checked by hand: no listener and no process left). The gateway is left stopped; `bin/omniroute-ctl.sh start` brings it back (not started at container start).
- Not fixed, recorded: S6C-06 (see the T10 note). Residual of S6C-02: the cwd check stops a process on the port that is not the install, not a process that chdirs into the install folder.

### Suite (budget: one full run) and freeze

| Step | Command | Exit | Result |
| ---- | ------- | ---- | ------ |
| Attempt, aborted | `flock test.lock flock watchdog.lock env -i HOME=$HOME PATH=$PATH npm test` 23:47:49Z | 126 | `sh: 1: bin/selftests.sh: Permission denied` after 9 s; no selftest ran (`suite-0-aborted-126.log`). `selftests.sh` (my atomic replace) and three older files (`hardcode-lint-selftest.sh`, `merge-card-selftest.sh`, `merge-card.sh`) had lost their exec bit on this mount (git records 755, so no tracked diff): restored with `chmod 755`. |
| The full suite | same command, 23:48:57Z-00:03:25Z | 1 | **35 ok, 1 FAIL (36 selftests; the "37 ok" written first was a miscount)**: `profile-hooks-selftest`, RT-RTA-02 x3: `bench.sh`, `omniroute-ctl.sh` and `omniroute-run.sh` did not run jq through the no-HOME wrapper (`suite-1.log`). A pinned guard, not edited. |
| Fix, targeted only | the wrapper line added to the three scripts (and the `timeout ... bash -c "$(jq ...)"` lines rewritten with a variable, which the same check reads as a bypass); `profile-hooks-selftest` PASS, then `bench`, `omniroute-run`, `kanban-board`, `hardcode-lint`, `owner-leak` PASS | 0 | `post-suite-targeted.log` |

**The full suite was run once and failed once; it was NOT re-run** (the budget says exactly one). The 35 others passed. The tree is therefore not proven green end to end: the one failing selftest passes after the fix, the other 35 passed before it, and the fix touched only the three new scripts. A re-run is the owner's call before any merge.
Freeze: `sha256sum -c .supervisor/state/stage5-freeze.sha256` was regenerated once, last, over the same 114 paths (`freeze-paths-hh05.txt`), the old manifest kept as `stage5-freeze-114-s6.sha256`; the result is in the next line.
Freeze result: `sha256sum -c .supervisor/state/stage5-freeze.sha256` exit 0, **114 OK, 0 FAILED** (`freeze-check-s6.out`); the old manifest `stage5-freeze-114-s6.sha256` fails on exactly the 10 files this closeout changed (`.gitignore`, `SUPERVISOR.md`, `bin/alert_catalog.py`, `bin/escalate-selftest.sh`, `bin/escalate.sh`, `bin/selftests.sh`, `decisions.md`, `docs/alert-codes.md`, `docs/hermes-local/alert-catalog.json`, `docs/recovery.md`).

### Open after this closeout

- Firewall: apply `firewall-openrouter.diff` (human), activate the OpenRouter connection, then re-run T14/T15 live and set `enabled` in `fallback-routing.json` only if the evidence log shows a served model.
- Follow-up, not built (owner, 2026-11-09): an "Auto (best free)" resolver that chooses the model from the gateway's live catalog and the evidence log, with the choice recorded as data in the same config file.
- T7: the 9B builder skipped the click handler and the 9B reviewer approved a page with a dead button; tests that cover behaviour, and a reviewer that checks it, are open.
- T16: the 9B reviewer wrongly blocks reviews it cannot run (needs the terminal it lacks); Hermes's auto-decomposer split a card into child cards on a capability block.
- `bin/merge-card.sh` is not executable on the Windows mount; Playwright MCP screenshots hang (flags above); `escalate.sh:57` prints "integer expression expected" when the queue file is new (S3A-08, unchanged); the recover script host path above.

## Stage 6 follow-up (2026-11-10; D83-D88; same branch)

Master plan header read first (read-only, `/plan/`): "Version update 2026-10-27, after the Stage 5 audit", 691 lines: matches. Owner steps verified, not redone: the uncommitted `.devcontainer/init-firewall.sh` diff is exactly the proposed one (one host, `openrouter.ai`; identical to `firewall-openrouter.diff`); `curl https://openrouter.ai` http 200, `https://example.com` rc 7 (blocked); `bin/omniroute-ctl.sh status` 4 ok. Evidence files are in `.scratch/stage6f/` (and `.scratch/stage6/`).

| Item | Result | Evidence |
| ---- | ------ | -------- |
| 1 suite fix | `profile-hooks-selftest` alone: PASS | `.scratch/stage6/f1-profile-hooks.log` |
| 2 T7 dead button | **PASS for the page, not for the test or the review lane**: card t_6af45605 (builder-local) -> reviewer approved -> `bin/merge-card.sh` merged e44914f; Playwright on the branch worktree (before the merge): `{"before":"0","after_two_clicks":"2"}`, screenshot shows 2. The builder's test.js does NOT load app.js (it repeats `increment` in a loop, so it passes with or without the handler and was never red; the brief asked for a vm test), its handler waits for `DOMContentLoaded` against the brief, and the 9B reviewer's approval says the test "uses Node's vm module", which is false. "Tests that cover behaviour, and a reviewer that checks it" stay open; the PASS rests on the Playwright click alone | `evidence-t7b.txt`, `t7b-click-proof.txt`, `t7b-screenshot-after-2-clicks.png`, `t7b-merge.log` |
| 3 T10 feature-multifile | root cause found and fixed; subset re-run **5/5** (feature on its second run) | below |
| 4 S6C-06 | fixed: a branch that exits 0 early no longer passes | `bench-selftest` |
| 5 T16 re-proof | **PASS with a 9B reviewer**; a Claude reviewer cannot be built without breaking T3 (D85) | `evidence-t16b.txt`, below |
| 6 T14/T15 live | **PASS** with a named free model through OmniRoute; Auto unusable on this account (finding) | `t14-*`, `t15-live-events.txt` |
| 7 T6b live | **cannot be exercised with the real adapter by design** (evidence, no substitute) | `t6b-candidates.txt` |
| 8 T5 | 100 Haiku calls moved neither meter: **Haiku is not what moved /usage**; the earlier +5% stays attributed by exclusion only | `t5-*` |
| 9 S7 GPU | another model displaced the worker's model live: `other_loaded` observed; K4 end to end not produced: **accepted inference** | `s7-gpu-attempt.txt` |
| 10 S6 | faithful simulation accepted; limits recorded (D87) | D87 |

### T10 and S6C-06
- feature-multifile, run 1 of the earlier closeout: the worker blocked its card at 184 s (its own wrong belief that OpenCode had created test.js) and kept committing for 15 more minutes (a blocked card's worker was still running); the bench measured at the block. Fix: `bench.sh settle` waits for the worker's process to exit before anything is read. The first version took the pid from `runs[].worker_pid`, which Hermes never fills (null on all 158 runs): it waited on nothing (verifier HIGH-1); it now takes the pid of the newest `worker_bound` event (`bench.sh pid <card>`, tested with a board fixture whose `worker_pid` is null) and runs before the status and metrics are read. Re-run 1 (card t_fefb528f): the code was written but **never committed** (`cli.js`, `index.js`, `lib/` uncommitted in the worktree) and the 9B reviewer approved it from the working tree; the check reads the committed branch, so it failed, correctly. The task body now spells out the commit command. Re-run 2 (t_30413387): pass.
- S6C-06: the protected tests print `$BENCH_NONCE` as their last line (a random value per verify); `passes` requires exit 0 AND the nonce as the last output line, in `bench.sh check` and `verify` alike. Tests added first (red `bench-selftest` before the change): worker code that calls `exit 0` before the test finishes fails; honest code passes; a test printing a fixed word fails. Residual, wider than first stated (red-team S6D-01): worker code loaded in the test's own process can print the nonce, or replace `assert.*` with no-ops, and the test then prints the nonce honestly. Interim: the shipped tests take their assert functions before any worker code loads (stops that exact patch, tested); deliberate subversion in the test's process stays open until the verdict is produced outside the worker's process.

| Task | Card | Success | Status at measurement | Wall | Retries | Escalations | Cost |
| ---- | ---- | ------- | --------------------- | ---- | ------- | ----------- | ---- |
| bugfix-nullguard | t_f4c4ef62 | yes | review | 88 s | 0 | 0 | $0 |
| bugfix-range | t_74f0fb47 | yes | review | 214 s | 0 | 0 | $0 |
| deploy-recovery | t_3edb4116 | yes | review | 123 s | 0 | 0 | $0 |
| feature-multifile | t_fefb528f (run 1) / t_30413387 (run 2) | no (uncommitted) / yes | review / review | 183 s / 104 s | 0 | 0 | $0 |
| migration-rename | t_e2146c0d | yes | review | 323 s | 0 | 0 | $0 |

All rows: `t10-results-all.jsonl`. Retries and escalations come from the board and escalations.log; cost is the sum of `cost_usd` (no Claude call). The branch check now runs boxed with a per-run nonce.

### T16 re-proof (card t_cc2ae298, worker builder-claude, reviewer the 9B)
Diagnosis of the 9B reviewer's two blocks on t_422f02d7 (from its session in `~/.hermes/profiles/reviewer/state.db`, runs 155 and 156): (1) the card body was the worker's brief (block first, then create the file); the reviewer took it as its own job and tried to create the file with its terminal, which the reviewer role refuses; (2) it built the worktree path from the branch name (`.worktrees/t_..-t16-re-proof-pick-a-colour`) instead of the `workspace_path` kanban_show reports, so `git -C` said no such directory, and it concluded the file "was never created"; (3) it never tried `read_file`. The file was there (e50fd83). Not a stack fault: a weak model plus a worker-addressed brief.
A Claude-backed reviewer cannot be built here: Hermes has no Claude-subscription provider of its own; its `anthropic` provider takes an API key or a `CLAUDE_CODE_OAUTH_TOKEN`, and either one in a Hermes profile is a Claude credential inside Hermes, which T3 forbids; a reviewer that shells out to `claude -p` would be a new role with its own terminal hook, outside this session's brief (D85).
Re-run with a brief that has a REVIEWER paragraph (verify only, use `workspace_path`, `read_file`): builder-claude blocked needs_input (run 165), `THREAD_OPENED` 02:03:26Z, owner reply `REPLY`/`UNBLOCKED` 02:04:20Z, the same profile resumed in a new run and session and committed (run 168 `review_requested`), reviewer run 171 `completed`, `{"review":"approved"}`, status done, `COMPLETED` at 02:09:23Z. Exactly once: 1 `COMPLETED`, 1 `Resolved: done` message in the thread, 1 `Done t_cc2ae298` and 1 `Escalation t_cc2ae298` in #supervisor. No CLI completion was used. Finding: the committed file holds the six bytes `blue\n` (a literal backslash and n): the review lane approved a malformed file.

### Verifier and red-team on the follow-up (one pass each, then fix round 1)
Verifier: FAIL (2 high, 4 medium, several low); red-team: 5 medium, 2 low. Fixed in round 1, tests first where the change is code (`bench-selftest`, `omniroute-run-selftest`, `escalate-selftest`):
- Verifier HIGH-1 settle never waited (see T10 above). HIGH-2 T7b wording (row 2). MEDIUM-1/S6D-01 nonce residual stated honestly, interim: tests take `assert` first. MEDIUM-2 the D85 reason corrected. MEDIUM-3/S6D-06 an unknown or unreadable cost is a failed attempt; exponent form, trailing blanks and header-name case are read. MEDIUM-4 the selftest assertion "no real model id" was narrowed on purpose (the config is where models live; `claude` is back in the regex, `nemotron|lfm` added) and the change is recorded in D83. Low items: counts and wording corrected, raw headers saved (`t14-headers.txt`), T15 exit codes noted (`t15-exit-codes.txt`).
- S6D-02 a protected test path that the branch made a folder is refused; S6D-03 the boxed check is killed (`timeout -k`), its file size capped (`ulimit -f`), temp folders removed on TERM/INT, `BENCH_TIMEOUT` is the limit. S6D-04 the high-risk gate fails closed: "high" within 40 characters of "risk" in either order, zero-width characters removed, an unreadable card counts as high risk; a body with no risk wording is still rerouted, a body that denies high risk in words is queued (false alarms queue). S6D-05 `prompt_block_patterns` in the config: a prompt matching a token or key pattern is never rerouted (`FALLBACK_SKIPPED`, the match is not logged).
- Not fixed, recorded: S6D-01 (in-process subversion of a test), S6D-07 (the nonce is visible in the bench box's own process list, same residual), homoglyph spellings of "risk" (Cyrillic, fullwidth), whether this account's free endpoints log prompts (unknown).

### T14/T15 live (D83)
- Gateway answers `/v1/models` 200 with the endpoint key as Bearer (read through command substitution, never printed): 1377 model ids, 929 ms (`t14-models.json`). No `builder-omniroute` Hermes profile exists; the fallback runner is the "builder-omniroute path" of the plan's design (D83 records why a profile was not built: its endpoint key would sit in a worker-readable profile).
- Probes of three named free models, 2026-11-10 01:56Z (`t14-probes-1.txt`): first model 200, 1245 ms, routed `nvidia/nemotron-3-ultra-550b-a55b:free`; second 200, 5495 ms; third 403 after 21.7 s. The real gateway names its provider in the header `x-omniroute-provider: openrouter` (the model vendor in the name was `nvidia`; the first runner version took the vendor as provider, which was wrong, now fixed with a test) and its cost in `x-omniroute-response-cost: 0.0000000000`; `x-omniroute-compression: off`.
- Finding: **Auto is unusable on a $0-credit account**: `model auto` returned 402 (`t14-auto-probe.txt`: "All credentials for model openrouter/auto are cooling down"). The named free model works.
- Config chosen from that data: `docs/hermes-local/fallback-routing.json`: `enabled: true`, `providers.allow: ["openrouter"]`, default chain = the first model; one call through the config's chain: ok, provider openrouter, cost 0, 1278 ms (`t14-call-default-chain.txt`).
- T15 live on throwaway cards (`t15-live-events.txt`): low-risk: `START, POOL_EXHAUSTED, FALLBACK` (serving model, `fallback: true`), exit 0, result `{"type":"result","fallback":true,"model_used":"nvidia/...","text":"pong"}` with no Claude fields; high-risk (`risk: high` in the body): `START, POOL_EXHAUSTED, QUEUED`, exit 75, nothing on stdout, the runner never called. The probe cards were archived and the high-risk queue entry dropped.
- Subscription path untouched: no `ANTHROPIC_BASE_URL`; 100 Haiku calls through `escalate.sh` (direct `claude -p`) succeeded while the gateway ran (T5).

### T6b live: not reachable with the real adapter (evidence, no substitute)
An approval button is shown only inside a gateway agent turn that proposes a command the approval layer flags. Stella's only terminal is hook-limited to read-only commands, and her write tools are refused by hook: of 15 commands tried against the real `detect_dangerous_command` and her real hook, 12 are flagged dangerous (3 are not) and **all 15 are refused by the read-only hook before the approval layer** (`t6b-candidates.txt`); workers run single-query mode, where Hermes blocks flagged commands with "no user present" (T6a evidence). The adapter's button is created by that gateway's own turn; a second process cannot own the click. So no approval button can be reached through the stack as built, which is the guards doing their job; nothing was substituted and no click from the owner was needed. The simulation (`approval-sim-selftest`) stays the only evidence for the gate itself.

### T5 and S7
T5: owner readings (plan: Max tier, about 5x Pro): 5% 5 h / 34% weekly before, **5% / 34% after 100 Haiku calls** through `escalate.sh` (02:27:18-02:40:05Z, all `claude-haiku-5-5`, total cost $0.047, board idle, `t5-summary.json`). Haiku escalations do not visibly move /usage at whole-percent resolution; the earlier +5% was therefore not the Haiku call. Which other cloud work caused it is still not measured. T5's own criteria hold (completes, cost recorded, no new meter).
S7: with the board idle the owner-approved attempt loaded a second model (24.6 GB, 10.5 GB of it in VRAM; load 70 s) at 02:17Z: `/api/ps` listed only that model, and `server_cause` for builder-local's model returned `other_loaded` live; a request to the displaced model with a 20 s client timeout answered 200 after 14.7 s (Ollama swapped it back), so no model-call failure and no K4 alert were produced. Unloaded at 02:18:41Z, the worker's model was back. "Another model fills the GPU" stays an accepted inference for the end-to-end alert (D86).

### Suite and freeze (follow-up; budget: one full run, a second only if it fails)
| Step | Command | Exit | Result |
| ---- | ------- | ---- | ------ |
| Targeted, before the independent checks | `profile-hooks`, `bench`, `omniroute-run`, `escalate`, `hardcode-lint`, `kanban-board`, `owner-leak` | 0 | all PASS (`targeted-before-checks.log`, `f1-profile-hooks.log`) |
| Targeted, after fix round 1 | the same plus `alert` | 0 | all PASS (`targeted-after-round1.log`) |
| **The full suite** | `flock test.lock flock watchdog.lock env -i HOME=$HOME PATH=$PATH npm test` 03:18:25Z-03:44:41Z | 0 | **36 ok, 0 FAIL, `selftests PASS`** (`.scratch/stage6f/suite-1.log`); one run, no second run needed |
| Freeze | `sha256sum -c .supervisor/state/stage5-freeze.sha256`, regenerated once, last, over the same 114 paths (old manifest kept as `stage5-freeze-114-s6b.sha256`) | 0 | **114 OK, 0 FAILED** (`.scratch/stage6f/freeze-check.out`); the old manifest fails on the 5 covered files this follow-up changed (`.devcontainer/init-firewall.sh`, `SUPERVISOR.md`, `bin/escalate-selftest.sh`, `bin/escalate.sh`, `decisions.md`) |

### Human steps outstanding after the follow-up
1. Open the PR from the compare link and merge after review (not opened here: `gh` is not authenticated).
2. Nothing is needed for T6b (not reachable by design, D84); a Claude reviewer (D85) needs an owner design decision first.
3. Optional: archive or delete the Discord threads the probes left (T16, T16b, S6); decide whether to keep `enabled: true` in `docs/hermes-local/fallback-routing.json` (D83, D90) and whether the gateway should start at container start (it does not).

## Stage 6 follow-up 2 (2026-11-10; D92-D96; same branch)

Pre-check: exec bits on `bin/*.sh` restored after every commit and replace (the mount strips them). Plan header known and matching (read in the first follow-up). Evidence files are in `.scratch/stage6f/`.

| Item | Result | Evidence |
| ---- | ------ | -------- |
| 1 Claude reviewer | **PASS with open findings** (D92, D97; supersedes D85): profile `reviewer-claude` with its own login; T3 re-checked and holds; T16d with the Claude reviewer: Claude answered CHANGES, then APPROVE, exactly-once completion. The call was pinned (`--restricted`, no builder code, no dash-first prompt) after the red-team pass and not yet run live in that form; token refresh, routing/cost and the SOUL-only "must call Claude" rule stay open | `t3-recheck.txt`, `evidence-t16d.txt`, `t16d-reviewer-calls.txt` |
| 2 T7 two open items | (a) **PASS**: test fixed, red without the handler, green with it; (b) approval corrected in the record, no fresh approval | `t7c/tdd.log`, `evidence-t7b.txt`, D96 |
| 3 S6C-06 general | **PASS for node tasks after round 1**: signed guard report, only the protected test's own assertions count, no nonce in the environment (D95); the first version was bypassable (padding, env nonce, async), found by both checks | `bench-selftest` |
| 4 verifier FAIL items | settle pid fix and the T7b wording were done in the first follow-up and are re-checked by the fresh verifier below | verifier report |
| 5 S7 sustained | attempted once: **K4 did not fire**; accepted inference (D94) | `s7-sustained-attempt.txt` |
| 6 gateway autostart | **PASS in selftest** (D93); not tried across a real container restart | `container-start-selftest` |

### 1. Claude reviewer
- T3 literal text re-read from the plan file; builder-claude's login (`profiles/builder-claude/home/.claude`) trips none of its five checks; reviewer-claude gets the same kind (D92). Built: `docs/hermes-local/hooks/reviewer/claude-review-terminal.sh` (the 9B reviewer's commands plus one read-only Claude call), `docs/hermes-local/soul/reviewer-claude.md`, `roles.json` (profile row, `workers` on the reviewer role, per-worker terminal hooks, boxed profile and the same `.claude` overrides as builder-claude), `hardcode-allow.json` baseline for the literals, `bin/reviewer-claude-selftest.sh` (62 assertions, red first: 50 failed before the hook existed, `rc-red.log`). `hermes profile create reviewer-claude --clone-from reviewer`; `bin/apply-hermes-local.sh` rc 0; the three stale cloned reviewer hooks removed from the profile's config.yaml by hand (backup `reviewer-claude-config.before`); `--check` clean apart from the old `default: UNLISTED escalation-reply-hook.sh`.
- Owner step: `CLAUDE_CONFIG_DIR=/home/node/.hermes/profiles/reviewer-claude/home/.claude claude auth login` (done; `claude auth status` loggedIn, authMethod claude.ai). T3 after (`t3-recheck.txt`, 04:33Z): env A/B/C empty, `auth.adopt_external_logins` false, Hermes shows Anthropic "not set" for the root and the profile, `hermes auth list`: external logins not adopted.
- Run 1, T16c (t_4e9406eb): mechanics passed (one COMPLETED), **but no Claude call went through**: the 9B driver wrote a nested-quote prompt with a `$` in it, the hook refused it, and it fell back to `read_file` and approved by itself. Not counted as a Claude review. Changes: the hook also accepts a double-quoted prompt when nothing in it can be shell-expanded (that relaxation was never exercised live: the same command is still refused), and the SOUL gives the exact line (what made both T16d calls work).
- Run 2, T16d (t_de6138e2, worker builder-claude): block needs_input (run 181), owner reply, the worker re-blocked the same question (run 182 says it called `kanban_block` 8 times; Hermes's loop detector sent the card to triage and its auto-decomposer made three child cards; one child ran builder-claude (run 183) in a worktree under `/workspace/.worktrees` on a `wt/` branch, the stack repo and the forbidden fallback, and opened a third escalation thread: no worktree, branch or commit of it remains; the children were archived with the owner's permission after the classifier refused me), retry (run 184 `review_requested`), reviewer-claude run 185: Claude answered CHANGES (`docs/colour.txt` lacked its trailing newline) and the driver called `kanban_request_changes`; worker run 186 fixed it; reviewer-claude run 187: Claude answered APPROVE, the card completed with `{"review": "approved"}`, status done. File bytes `red\n` (`od -c`). Exactly once: 1 `COMPLETED`, 1 `Resolved: done` message in the thread, 1 `Done t_de6138e2` and 1 `Escalation t_de6138e2` in #supervisor. No CLI completion by me (my only board writes were the owner-approved archive of the three children).

### 2. T7
`.scratch/s6-scratch` commit e044571: `test.js` loads `app.js` in a vm and clicks twice. `.scratch/stage6f/t7c/tdd.log`: old test on an app.js with no handler: "All tests passed!" rc 0; new test on that app.js: `AssertionError: app.js must register a click handler on #go` rc 1; new test with the handler: pass rc 0. The 9B reviewer's approval of the earlier test (run 159) claimed a vm test that did not exist: corrected in `evidence-t7b.txt` and D96; the row-2 wording of the first follow-up already said so. No card ran for the new test, so there is no fresh reviewer approval.

### 3. S6C-06 general
`bench/guard.js` + `bin/bench.sh` guard mode (D95). Red first (`bench-selftest`, 3 failed before the guard existed, the negatives passing vacuously because verification failed closed): honest code passes; wrong code, no-op asserts (sloppy and strict), a swapped assert module, `process.exit(0)`, an `uncaughtException` swallow, a forged report, removed exit listeners, a stdin read and too few assertions all fail. The shipped node tasks carry their `guard` minimum (2, 4, 4, 5) and `bench.sh check` passes (5 tasks, under the guard).

### 5. S7, sustained attempt (D94)
04:22:57Z a second model started an 8000-token generation; builder-local card t_4de8f3c6 created at 04:23:56Z. The second model ran at 47 tokens/s and finished in 226 s. Worker runs: 175 `crashed` ("worker exited cleanly (rc=0) without a verdict", 182 s), 176 `review_requested`, 177 `completed`. No "API call failed" line in the builder-local agent log (kept in local time: window 23:2x on 2026-11-09), no `STL-MDL-701` after 2026-11-08: **K4 did not fire**. Run 175's crash was a write_file loop, not the displacement. That a queued call waits and fails only after Hermes's 900 s stall limit is my inference. Accepted inference; not repeated (one attempt).

### 6. Gateway autostart (D93)
`bin/container-start.sh` starts `bin/omniroute-ctl.sh start` in the background when the fallback is enabled. `container-start-selftest` (red first: 1 failed, then PASS): enabled starts it; disabled and missing config do not; a failing start and a failing jq do not stop the other steps. Documented in `docs/recovery.md` and SUPERVISOR.md.


### Verifier and red-team on follow-up 2 (one pass each, then fix round 1)
Verifier: FAIL (a blocker on the guard: padding the assertion count then `exit(0)` passed; the nonce was still in the environment; async assertions counted as passed; correct code using assert failed), plus medium and low wording items. Red-team: 3 high, 5 medium, 2 low. Fixed in round 1, tests first (`bench-selftest`, `reviewer-claude-selftest`): the guard (stdin nonce and protected-file list, only the protected test's own calls count, async counted when settled, no `BENCH_NONCE` for node tasks) and the Claude reviewer's hook (pinned to `--restricted --strict-mcp-config --tools Read,Grep,Glob`, no prompt starting with a dash or blank, no `npm test`/`npm run lint`/`node --test`). Wording corrected in D92-D95 and D97 (the double-quote story, builder-claude's login path, S7's time window and crash cause, D93's silent skips, the T16d child that ran in the stack repo's `wt/` fallback, "reviewer approves without Claude" is a SOUL rule). Opened (D97): symlink and Read of the login file, OAuth refresh with a read-only config folder, reviewer routing and cost, `roles.py check` requiring `worker`.

Pinned-call check, live once (`.scratch/stage6f/pinned-call-live.txt`, 05:49Z): `CLAUDE_CONFIG_DIR=<reviewer-claude folder> claude -p 'Read note.txt in the working folder and reply with exactly its content, nothing else' --model sonnet --restricted --strict-mcp-config --tools Read,Grep,Glob --allowedTools Read,Grep,Glob` in a temp folder answered `hello`: the flags are accepted by claude 2.1.322 and reading works. A second probe (asking Claude to Read the login file to see whether `--restricted` confines it) was refused by the permission layer as a credential probe and was not run, so S6E-04 stays open. The T16 re-proof itself used the earlier, unpinned call shape and was not repeated.

### Suite and freeze (follow-up 2; budget: one run, one more only if it fails)
| Step | Command | Exit | Result |
| ---- | ------- | ---- | ------ |
| Full suite, run 1 | `flock test.lock flock watchdog.lock env -i HOME=$HOME PATH=$PATH npm test` 05:50:07Z-06:05:51Z | 1 | **36 ok, 1 FAIL** (37 selftests): `owner-settings-selftest` (reviewer and reviewer-claude: "an ordinary command passes all of the role's terminal hooks (none does)"); log `.scratch/stage6f/suite-f2.log`. Cause and fix: D98 (the selftest treated a role's two per-worker terminal hooks as one set). |
| Fix, targeted only | `owner-settings-selftest` made worker-aware (staged copy first: 741 ok, 0 FAIL, against 737 ok before; installed) | 0 | `os-selftest-staged.log` |
| Full suite, run 2 | same command, 06:18:46Z-06:46:40Z | 0 | **37 ok, 0 FAIL, `selftests PASS`** (`.scratch/stage6f/suite-f2b.log`); two runs in all, the budget's maximum |
| Freeze | `sha256sum -c .supervisor/state/stage5-freeze.sha256`, regenerated once, last, over the same 114 paths (old manifest kept as `stage5-freeze-114-f2.sha256`) | 0 | **114 OK, 0 FAILED** (`.scratch/stage6f/freeze2-check.out`); the old manifest fails on the 9 covered files this follow-up changed (`SUPERVISOR.md`, `bin/container-start-selftest.sh`, `bin/container-start.sh`, `bin/owner-settings-selftest.sh`, `bin/selftests.sh`, `decisions.md`, `docs/hermes-local/hardcode-allow.json`, `docs/hermes-local/roles.json`, `docs/recovery.md`) |

### Human steps outstanding after follow-up 2
1. Open the PR from the compare link and merge after review (not opened here).
2. Decide: keep `enabled: true` for the reroute (not touched here); who may name `reviewer-claude` (builders choose today, Pro-pool cost; a role-table field plus a role-guard check would route it by data); whether the Claude reviewer's config folder should be writable so an OAuth refresh can be saved (box data field; test a review a day after the login).
3. Optional live checks left open: a full T16 with the pinned Claude call; whether `--restricted` stops Claude reading the login file through a symlink in the worktree (a credential probe the permission layer refused me to run); a real container restart with the gateway autostart.
4. Optional: archive or delete the Discord threads the probes left (T16c, T16d and its decomposed child's thread, S6, T16b); the board has leftover done and archived probe cards.


## Stage 6 follow-up 3 (2026-11-10; D100-D104; same branch)

Pre-check: exec bits on `bin/*.sh` checked before every run and restored after every commit (the mount strips them); `bin/roles.py`, `bin/box.py` stay 644 as in git. Evidence files are in `.scratch/stage6g/`.

| Item | Result | Evidence |
| ---- | ------ | -------- |
| 1 Approval guard | **PASS** (D100): a reviewer-claude approval is refused unless this run's session holds the pinned `claude -p` call, exit 0, answer starting APPROVE; test first (red), live: 8 approvals without a call refused on T7d; the first output rule also refused real `**APPROVE**` answers (T7e, T7f), fixed in round 1 | `ae-red.log`, `bin/approval-evidence-selftest.sh`, `t7f-evidence.txt`, `evidence-t16e.txt` |
| 2a T7 test fix, Claude approval on the true basis | **PASS**: card t_e2dd3ebe (T7f): Claude read `test.js` and `app.js` and answered APPROVE twice (loads app.js in a vm with a fake DOM, asserts the click listener, fires it twice); card completed with `{"review": "approved"}` | `t7f-evidence.txt` |
| 2b Full T16 re-proof with the pinned call | **mechanics PASS, worker deviation**: card t_1e3b2924 (T16e): thread opened (1569719773619822642), link posted in #supervisor, owner reply "blue" unblocked it, builder-claude wrote `docs/colour.txt`, Claude (pinned call, after one refusal of a `cd ... &&` wrapper) answered APPROVE, reviewer-claude completed it, **one** COMPLETED, thread reaction and archive/delete prompt posted; not completed from the CLI. Deviation: the builder left `docs/colour.txt` uncommitted (no `git commit` call) and the reviewer's Claude call read the file only, so the commit rule in the card was not checked by anyone | `evidence-t16e.txt` |
| 3 Token refresh | **narrow fix built and proven in the box; live refresh not observed** (D102): the first run a day after the login failed with 401 (read-only config folder); `rw_files` makes only `.credentials.json` writable (file bind), all else read-only; after the owner's re-login every live Claude call worked, the token never expired inside a run | `box-selftest.sh` 3.51-3.54, `apply-d102.out` |
| 4 Symlink to the login file | **still open** (D104): the permission layer refused the live canary probe (it needs the reviewer-claude login); script for the owner: `.scratch/stage6g/symlink-probe.sh` | `symlink-probe.sh` |
| 5 Routing | **PASS** (D101): `review_callers` owner setting (default dispatcher + `Review-by` card line), guard enforced, tests first, live: a card with the line was reviewed through reviewer-claude | `routing-red.log`, `bin/routing-selftest.sh` |
| 6 Verifier blocker recovery, S6C-06 | the follow-up-2 verifier's first-pass text was not saved as a file; its blocker is in follow-up 2's "Verifier and red-team" and D97 and is covered by `bench-selftest.sh`; S6C-06 now also for the bash task (deploy-recovery: protected test requires a plain `NAME=value` config) (D103) | `bin/bench-selftest.sh` |
| Live runs also taught (D103) | the refusal message of the Claude hook now shows the exact call, the `approval_evidence.hint` spells the call out | `reviewer-claude-selftest.sh` |

### Verifier and red-team on follow-up 3 (one pass each; at most one fix round)
Verifier (readiness-verifier): **FAIL before the fix round**, claims 1, 2, 4, 6 held. Red-team (readiness-security-auditor): 1 blocker, 2 high, 2 medium, 2 low. Round 1 fixed with tests first: B1 (NUL byte hid code from the bash task's config check), H1 (the approval rule refused `**APPROVE**`, which cost a second Claude call on T7f and blocked T7e), S6I-01 (a repo planted in a worktree subfolder ran builder code in the reviewer's box through git; `GIT_DIR`/`GIT_WORK_TREE` pinned in `box.py`), S6I-04 (`Review-by` binds any caller). Recorded as open, not fixed: the rename-style token save (S6I-02/H2, row 3.55 documents it), the symlink to the login (S6I-05, owner probe), the auto-decomposer (M1/S6I-06), free-text prompt (S6I-03), session id change on compression (S6I-07). D105. Targeted selftests after the round: box (3.56, 3.57 and the rest), bench, approval-evidence, routing, role-guard, roles, reviewer-claude: all PASS.

### Suite and freeze (follow-up 3; budget: one run, one more only if it fails)
| Step | Command | Exit | Result |
| ---- | ------- | ---- | ------ |
| Full suite, run 1 | `flock test.lock flock watchdog.lock env -i HOME=$HOME PATH=$PATH npm test` 14:54:47Z | 1 | **34 ok, 3 FAIL**: `owner-config-selftest` (K8 expectation per SOUL), `owner-leak-selftest` (the repository URL in PLAN.md), `hardcode-lint-selftest` (hook wording); log `.scratch/stage6g/suite-f3.log`; D105 |
| Fix, targeted only | the three selftests above, run alone | 0 | all PASS |
| Full suite, run 2 | same command, 15:12:42Z-15:28:41Z | 0 | **39 ok, 0 FAIL, `selftests PASS`** (`.scratch/stage6g/suite-f3b.log`); two runs, the maximum; D106 |
| Freeze | `sha256sum -c .supervisor/state/stage5-freeze.sha256`, regenerated once, last, over the same 114 paths (old manifest kept as `stage5-freeze-114-f3.sha256`) | 0 | **114 OK, 0 FAILED** (`.scratch/stage6g/freeze-check.out`) |

### Human steps outstanding after follow-up 3
1. Open the PR from the GitHub compare link for main...readiness/stage6-closeout (or via Spark with body `.scratch/stage6/pr-body.md`; `gh` is not logged in here); merge after review.
2. Live gateway autostart across a real container restart (`docker restart tender_austin` or Rebuild Container), then `curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $(cat /home/node/.hermes/omniroute/endpoint-key)" http://localhost:20128/v1/models` should print 200.
3. Optional: run `! bash .scratch/stage6g/symlink-probe.sh` and send me the output (item 4); a review run more than a token lifetime after a login (item 3, live refresh).
4. Optional: archive or delete the Discord threads the probes left (T16c, T16d, T16e, S6, T16b).

## Stage 6 follow-up 4 (2026-11-10; D107-D120; same branch)

Owner decisions (2026-11-10): token via the broker; the auto-decomposer bypass is fixed; the symlink case is fixed. Testing approach: no full-suite gate and no run cap; targeted selftests after every change, the whole suite at the end until everything passes. Verifier and red-team pairs ran in parallel on frozen snapshots (`.scratch/snap/`). Evidence is in `.scratch/stage6j/`. Pre-check: exec bits on `bin/*.sh` checked before runs and restored after commits.

| Item | Result | Evidence |
| ---- | ------ | -------- |
| 1 Auto-decomposer | **PASS (disabled by configuration, D107)**: `kanban.auto_decompose: false` on every role; live: off = a triage probe untouched for 14 minutes, on = assigned and started within a minute with no role guard on the path | `evidence-e1.txt` |
| 2 Token via the broker | **wiring PASS, real token MISSING (D109)**: broker folder, per-command injection, snapshot exclusion, hidden login, `bin/broker-put.sh`; live: a canary token made the review command fail `401 Invalid bearer token` (so the broker token is what it uses) and left no file; **a real long-lived token (`claude setup-token` + `bin/broker-put.sh claude-reviewer`) is an owner step; a live review with it is not done; the OAuth refresh stays unproven** | `evidence-e2b.txt` |
| 3 Symlink to the login | **PASS as defence in depth (D110)**; the real-login probe was refused by the permission layer again (not worked around); live with a canary: a committed symlink out of the card made the reviewing box refuse to start (STL-GRD-603) | `evidence-e3.txt`, box-selftest 3.60-3.62, 3.78 |
| 4 Session id / compression | **PASS in selftest, not live (D108)**: this stack compacts in place (no new session id), so the premise did not occur; lineage through compression parents, same-session pairing, sticky CHANGES | `bin/approval-evidence-selftest.sh` |
| 5 Prompt content | **PASS (D111)**: one allowed command, owner template, stack-built evidence, export of the committed tree; live: sent copy identical to the rendered file with the template verbatim | `t16g-prompt-sent.txt` |
| 6 T16 with the commit rule | **PASS (D112)**: T16g, builder blocked, owner replied in Discord, builder committed only `docs/colour.txt`, Claude verified the commit and approved, exactly one COMPLETED, no CLI completion; and Claude answered CHANGES when a probe file was not committed (E7b, run 2) | `evidence-t16g.txt` |
| 7 Planted repo live | **PASS (D113)**, with caveats: the trap was planted from the host by `.scratch/stage6j/plant.sh` (the builder agent could not build it itself) and no control run was done by me (the permission layer refused); trap intact afterwards, the reviewer's `git -C notes log` showed the card's own history, marker never written | `evidence-e7c.txt` |
| 8 QA | verifier + red-team pairs per element (three rounds, D114/D115) and a final whole-tree pass (D116): verifier PASS WITH NOTES; red-team found a host code-execution path in Hermes's own card-completion cleanup (S6N-01, pre-existing): mitigated stack-side after every builder call (restore git files, quarantine nested repos behind gitlinks), **not closed**: the full fix is in Hermes (owner decision) | decisions D114-D116 |
| Live runs vs final code | E1, E2b, E3, T16g and E7c ran on earlier code; the smoke card t_8c76ab9f ran on the code before the last fixes; later fixes are selftest-proven only (D116) | `.scratch/stage6j/` |

### Suite and freeze (follow-up 4; no run cap, no gate: iterate until every test passes)
| Step | Result | Evidence |
| ---- | ------ | -------- |
| Full suite, runs 1-5 | run 1 34 ok + 1 FAIL (`complete-gate-selftest`, a word in a comment); runs 2-4 40 ok; run 5 39 ok + 1 FAIL (`owner-leak-selftest`: owner-added untracked spec files with the owner's name in `docs/spec/`, left untouched, excluded locally via `.git/info/exclude`) | `.scratch/stage6j/suite-*.log`, D120 |
| Full suite, run 6 | **40 ok, 0 FAIL, `selftests PASS`, exit 0** on the final tree | `.scratch/stage6j/suite-6.log` |
| Freeze | `sha256sum -c .supervisor/state/stage5-freeze.sha256`, regenerated once, last, over the same 114 paths (old manifest kept as `stage5-freeze-114-f4.sha256`) | see the closeout report |

### Human steps outstanding after follow-up 4
1. Open the PR (body `.scratch/stage6/pr-body.md`; attempted with `gh pr create` after the last push: `You are not logged into any GitHub hosts`, no GitHub connector is available here, so it is left for you) and merge after review.
2. **Needed now: the Claude reviewer's login has expired (D119), so no live Claude review runs until this is done.** Give the Claude reviewer its long-lived token: in your own terminal run `claude setup-token`, copy the token, then run `bin/broker-put.sh claude-reviewer` and paste it (nothing is echoed). Then I (or you) run one real review to see it succeed; the first review after the token's life would show a refresh problem (none is expected for a long-lived token).
3. Optional: run the symlink probe against the real login yourself (`! bash .scratch/stage6g/symlink-probe.sh`).
4. Live gateway autostart across a real container restart (see follow-up 3, human step 2).
5. Optional: archive or delete the Discord threads the probes left (T16c to T16g).
6. Decide whether a card that Hermes sends to triage after a block loop should page you (open, D107).
7. **Decide how to close S6N-01 for good (D116)**: Hermes runs `git status` / `git log` in a builder's worktree on the host at card completion; patch those two calls so they do not trust `<worktree>/.git` or a nested repo (`--git-dir=<common>` with the card's index, `--ignore-submodules`, a hardened environment) locally or upstream. The stack now restores the git files, quarantines nested repos and fails closed (moves the card's index aside) after every builder call, with a detached helper for a killed launcher (D116, D117, D118); it remains a mitigation.
8. Check the gateway's environment names for the three Claude credential variables (command in D116); the box now removes them anyway.
