# decisions.md (project stella)

Append-only. Each entry: decision, date, reason, and `supersedes:` when it replaces an earlier entry.
Never edit or delete an old entry; mark it superseded by adding a new one.

## D1. Card branches are `stella/<card-id>-<title-slug>`
- Date: 2026-10-25
- Reason: Hermes deletes auto `wt/<card-id>` branches together with clean, pushed worktrees on completion; project branches survive.
- Supersedes: AGENTS.md rule 1 `task/<card-id>-<slug>` convention.

## D2. OmniRoute deferred; no `builder-omniroute` profile
- Date: 2026-10-25
- Reason: OmniRoute is not installed; T14 is conditional. Pool-exhausted low-risk reroute stays unbuilt until it is.

## D3. Build watchdog runs from container cron, not hermes cron
- Date: 2026-10-25
- Reason: the hermes cron ticker lives in the gateway and cannot report the gateway's own death.

## D4. Escalation decisions are threads-only
- Date: 2026-10-25
- Reason: the Hermes gateway cannot map custom Discord buttons to a card id; clarify taps are non-deterministic. A reply in the card's #escalations thread is the decision, recorded on the card and in escalations.log. Dangerous-command approval buttons (ExecApprovalView) are unaffected.

## D5. builder-local runs only in stella worktrees, with a local-only OpenCode default and a false-close guard
- Date: 2026-10-25
- Reason: a scratch workspace outside /workspace made OpenCode fall back to its cloud model `exo-free` (t_b9a689ec), and a 9B worker faked a delegate result with `echo` (t_658f24da). Cards use `--project stella --workspace worktree`; `~/.config/opencode/opencode.json` pins `ollama/qwen3.5:9b-64k`; `bin/false-close-guard.py` gates `kanban_complete`.

## D6. ~/.claude/skills reaches all three harnesses; installs are recorded per harness
- Date: 2026-10-25
- Reason: verified that Claude Code reads ~/.claude/skills natively, Hermes reads it through `skills.external_dirs`, and OpenCode reads it recursively (subfolders included). Anything placed there reaches all three unless it is turned off in the others: Hermes `skills.disabled`, OpenCode `permission.skill.<name>: deny`, Claude `permissions.deny: Skill(<name>)` (plugin skills ignore project `skillOverrides`). Harness-specific sources go in each harness's own path instead. Every install is recorded per harness:

| Source @ commit | Claude Code | OpenCode | Hermes |
|---|---|---|---|
| anti-ai-slop-writing `jalaalrd/anti-ai-slop-writing@63255f9` | not installed (Claude gets the-antislop, pending triage) | `~/.config/opencode/skills/anti-ai-slop-writing` | `~/.hermes/skills/writing/anti-ai-slop-writing` |
| superpowers `obra/superpowers@2ce8aa1` (7.0.1) | plugin `superpowers@superpowers-dev`, project scope; `Skill(superpowers:brainstorming)` denied | `plugins` in /workspace/opencode.json pinned to 2ce8aa1; `brainstorming` denied | not installed: Hermes install scanner BLOCKED (community source + caution, 170 findings); not forced |
| find-skills `vercel-labs/skills@a80e4c9` | not installed (per card only, D7) | not installed | not installed |

## D7. find-skills is approved per card only, with a fixed network scope
- Date: 2026-10-25
- Reason: it tells the agent to run `npx skills find/add`, which needs skills.sh and the npm registry. It is never preloaded in any harness; the supervisor attaches the vetted copy (`vercel-labs/skills@a80e4c9`, SkillSpector SAFE) to one card only, and only on an explicit discovery request. Allowed network: skills.sh and registry.npmjs.org only. skills.sh is not in the firewall allowlist yet, so the first real use needs a firewall diff and approval. Discovery results never authorize an install by themselves.

## D8. superpowers is installed without its brainstorm skill
- Date: 2026-10-25
- Reason: the brainstorm companion's web server binds 127.0.0.1 by default but `--host`/`BRAINSTORM_HOST` override it (its docs recommend 0.0.0.0 in containers), so loopback-only is not guaranteed; and its page loads a remote logo from primeradiant.com unless DISABLE_TELEMETRY is set. The brainstorming skill is denied per harness (D6 table).

## D9. superpowers is Hermes-deferred
- Date: 2026-10-25
- Reason: Hermes's own plugin install scanner refused it (`BLOCKED — community source + caution verdict, 170 findings`), and Hermes delegates code work to builders that already have superpowers without brainstorm (Claude Code, OpenCode; D8). Revisit only if a specific Hermes card needs it, with a Hermes-specific triage; never by overriding the scanner (`--force`).

## D10. New skills in ~/.claude/skills/synced/ default to denied in Hermes and OpenCode
- Date: 2026-10-25
- Reason: synced/ is auto-synced by the Claude account, so skills appear there without review (5 new ones appeared on 2026-10-25: computer-use, docx, google-workspace, pdf, xlsx). Any new synced skill is denied in Hermes (`skills.disabled`) and OpenCode (`permission.skill.<name>: deny`, repo and user config) until triaged; Claude Code keeps them.

## D11. Skill triage queue and method for partial scans
- Date: 2026-10-25
- the-antislop (`aplaceforallmystuff/the-antislop@f123fdc`, Claude Code only): NOT installed. SkillSpector HIGH 76 DO_NOT_INSTALL, 100% coverage. Real finding: `skills/antislop/SKILL.md:409-439` "Pattern Refresh Protocol" runs automatically when `last-refreshed` is over 30 days old (2026-08-18, so on every first use), curls the Wikipedia API (`:419`, `:426`) into python3, then edits its own SKILL.md from that web content. The fetch is blocked by the firewall; the self-edit from untrusted content is not mitigated. Waiting for a decision (for example, a reviewed local copy without the refresh section, installed read-only).
- Pending triage, in this order: impeccable, promptfoo, agent-skills, taste-skill (last; Claude builders only).
- graphify and ui-ux-pro-max: no further SkillSpector splitting. Method: manual serious-findings triage on install files only, plus a bounded smoke test in a scratch worktree (never in the repo). SkillSpector coverage is recorded as partial, never as PASS.

## D12. the-antislop rejected (self-modifying design)
- Date: 2026-10-25
- Supersedes: the the-antislop entry in D11.
- Reason: `aplaceforallmystuff/the-antislop@f123fdc` `skills/antislop/SKILL.md:409-439` "Pattern Refresh Protocol" refreshes from Wikipedia when `last-refreshed` (2026-08-18) is over 30 days old, then has the agent rewrite its own SKILL.md from that untrusted web content. R2.6 forbids that; the firewall blocking the curl does not mitigate the rewrite instruction. Not installed in any form. Claude Code gets anti-ai-slop-writing instead (D6 table). A reviewed copy without the refresh section is a deferred card, only if Benji asks for its Horoscope and tiered features: excise the section, grep finds zero `refresh|Wikipedia|curl|rewrite`, read-only file, hash recorded, watchdog hash check.

## D13. A skill deny is a loading control, not isolation
- Date: 2026-10-25
- Reason: OpenCode `permission.skill` deny (and Hermes `skills.disabled`) stop the skill tool from loading a skill; they do not stop a direct file read of its SKILL.md (seen: after `Permission denied: skill` the 9B model searched for the file with read/glob/ls).

## D14. Hermes has no pdf skill for now
- Date: 2026-10-25
- Reason: the synced Claude-account `pdf` overrides Hermes's builtin `pdf` (`hermes-agent/skills/productivity/pdf`), and disable-by-name (D10) removes both. Accepted; `pdf` stays disabled in Hermes. PDF work goes to builder-claude, which still lists `anthropic-skills:pdf`. Revisit only if a supervisor card actually needs PDF parsing.

## D15. Stage 4 close-out
- Date: 2026-10-25
- Supersedes: the Claude Code cell of the anti-ai-slop-writing row in the D6 table ("not installed (Claude gets the-antislop, pending triage)"); the-antislop is rejected (D12).
- Outside-/workspace OpenCode deny (user config `~/.config/opencode/opencode.json`): accepted for normal operation on combined evidence. `google-workspace` and `pdf` returned `Permission denied: skill` outside /workspace; for `computer-use`, `docx` and `xlsx` the model made no skill call, and its list of available skills contained none of the 14 denied skills. It is a loading control, not isolation (D13): a deny stops the skill tool from loading a skill, not a direct file read.
- anti-ai-slop-writing for Claude Code: PASS. Installed byte-for-byte from `jalaalrd/anti-ai-slop-writing@63255f9` at `~/.claude/skills/anti-ai-slop-writing`; the Skill call was verified; on a slop sample it flagged banned openers, banned vocabulary, the rule of three and lack of specifics, and correctly cleared a single em dash.
- superpowers context cost: about +1.3k tokens (about 8%) at session start, under the 25% threshold; the SessionStart hook stays unchanged. The denied brainstorming skill is still listed (about 80 tokens): the deny blocks calling, not listing.
- Stage 5 bundle: amended, proposal only, not applied (`.scratch/proposed/stage5-bundle.diff`). postStart will call `bin/container-start.sh`, which stays in `.scratch/proposed/` until Stage 5; it reinstalls the crontab, regenerates the OpenCode user config from repo `opencode.json` (model, provider, all 14 skill denies), and restores anti-ai-slop-writing from the ~/.hermes volume.
