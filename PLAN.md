# PLAN.md

One section per task. Copy the template below for each new task. Rules for working tasks are in `AGENTS.md`.

Status values: `todo` · `in-progress` · `blocked` · `review` · `done`

| ID | Task | Builder | Status |
|----|------|---------|--------|
| T-001 | _short name_ | _claude / opencode / hermes / human_ | todo |

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

<!-- stack-build-begin: STACK BUILD ONLY, remove after Stage 5 -->
## Stage 5 checklist

> **STACK BUILD ONLY, remove after Stage 5.**

### Before the Stage 5 rebuild: persist runtime tools

These were installed at runtime in Stage 2 and are lost on every rebuild (image layer, not a volume). Move them into `.devcontainer/Dockerfile` at the same pins, show the diff to a human, and stop before rebuilding.

- [ ] npm globals (as `node`): `@opencode/cli@2.0.26`, `ctx7@0.6.0`, `chrome-devtools-mcp@1.10.1`, `agent-browser@0.39.0`, `codebase-memory-mcp@0.11.0`
- [ ] uv tools (as `node`): `git+https://github.com/NVIDIA/skillspector.git@v2.12.0` (needs Python >=3.12; uv fetches its own)
- [ ] `~/.config/opencode` (Chisle ruleset, skills, plugin): recreate with `npx -y chisle@3.7.0 --only opencode` at build time, or move to a volume
- [ ] After rebuild, verify each survived:

```sh
opencode --version            # v2.0.26
ctx7 --version                # 0.6.0
chrome-devtools-mcp --version # 1.10.1
agent-browser --version       # agent-browser 0.39.0
codebase-memory-mcp --version # codebase-memory-mcp 0.11.0
skillspector --version        # SkillSpector v2.12.0
ls ~/.config/opencode/AGENTS.md ~/.config/opencode/plugins/chisle.js
```

Already persistent (no action): Claude plugins (chisle, ponytail) in the `~/.claude` volume; uv, pre-commit, gitleaks, tmux, Playwright Chromium in the Dockerfile.
<!-- stack-build-end -->
