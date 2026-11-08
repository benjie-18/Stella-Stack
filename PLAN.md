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
