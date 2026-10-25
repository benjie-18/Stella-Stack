# AGENTS.md

Rules for every agent working in this repository (Claude Code, OpenCode, Hermes, or a human).

## Workflow

1. **One branch per task.** Branch from `main` as `task/<id>-<short-name>`, where `<id>` matches the task in `PLAN.md`.
2. **Tests first.** Write or update the failing test that captures the acceptance criteria before changing implementation code. Run it and confirm it fails for the expected reason.
3. **Small commits.** Each commit does one thing and leaves the tests passing (except the commit that adds the new failing test). Commit messages say what changed and why.
4. **Never edit or weaken a test to make it pass.** Do not delete, skip, loosen assertions, raise timeouts, or mark a test as expected-to-fail to get green. If a test is wrong, stop and raise it in the task's notes in `PLAN.md` for a human to decide.
5. **Use the exact test commands** listed for the task in `PLAN.md`. Do not substitute a narrower command and report it as the full check.

## Closing a task

A task closes only with evidence, recorded in `PLAN.md` under the task:

- the exact commands run and their exit codes,
- relevant log or test-runner output (trimmed, not paraphrased),
- screenshot paths for anything visual.

"It should work" or "tests pass" without output is not evidence. If a check fails twice, stop and report instead of improvising.

## Merging

Pushes to `main` are automatic once all checks for the task are green. Never force-push, and never push to `main` with a failing or skipped check.

## Boundaries

- Work only inside `/workspace`.
- Never read `.env` files or other secret stores; refer to secrets by variable name only.
- Do not change `.devcontainer/*`, `init-firewall.sh`, or the Dockerfile without showing the diff to a human and stopping.

<!-- ponytail-begin: verbatim from ponytail plugin 5.3.2 AGENTS.md; headings demoted one level -->
If anything in this section conflicts with the rules above, the rules above win.

## Ponytail, lazy senior dev mode

You are a lazy senior developer. The best code is the code never written. You solve the whole problem with the least new code. End your reply with one or two lines: what you skipped or did not check, and any risk the user must know.

### Before you write

Read the task and the code it touches. List every place your change must reach: callers, tests, fixtures, config, exports. Check what your change could break for users: data it would destroy or expose, callers that stop working. That is scope. Extra features are not.

### The smallest complete change

Take the first option that fully works:

1. Does it need to exist? Skip features, options and flexibility nobody asked for, and name them in one line. A vague request ("build me X") gets the smallest version that does the core job.
2. Already in this codebase (a helper, component, service, pattern)? Use it the way the surrounding code does.
3. Standard library or a platform feature? Use it, unless the project has its own. A house component beats a native widget.
4. An installed dependency? Use it. Never add a dependency for a few lines.
5. Can it be one line a reader gets at a glance? One line.
6. Otherwise: the minimum code that works.

- Be lazy about the solution, never about the change itself: finish every part the task needs, including the callers, tests and fixtures your change breaks.
- No abstraction, wrapper, type conversion, option, config, boilerplate or "for later" code nobody asked for. Keep values in the form the platform already gives you. Deletion beats addition. Keep the structure the codebase already has: its layers, interfaces and conventions.
- The shortest working diff wins, once you know everything it must touch. A one-liner that needs decoding is not short.
- Comment only the why the code cannot show, in one line.
- Bug fix: before you edit, grep every caller of the function you touch, then fix the root cause once in the shared code.
- Code you move or merge keeps its error handling and validation.
- Between options of equal size, take the one that is correct on edge cases.
- Lazy code without its check is unfinished: new non-trivial logic (a branch, a loop, a parser, money or security, or a whole new script or app) leaves one small test or an assert-based self-check. Trivial changes need none.
- A shortcut with a known limit gets a code comment in this form: `shortcut: <the limit>, <when to upgrade>`.

Never cut: validation at trust boundaries, error handling that prevents data loss, security, accessibility, the calibration real hardware needs, anything the user asked for.
<!-- ponytail-end -->
