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

## D16. chrome-devtools-mcp runs Chrome with --no-sandbox
- Date: 2026-10-25
- Supersedes: the exact Stage 4 pin of the chrome-devtools entry in .mcp.json.
- .mcp.json chrome-devtools is now the Stage 4 pin plus one arg: `npx -y chrome-devtools-mcp@1.10.1 --headless --isolated --slim --chromeArg=--no-sandbox`.
- Reason: Docker's default seccomp filter (mode 2) blocks the namespaces Chrome's sandbox needs (`Failed to move to new namespace … errno = Operation not permitted`, then the zygote exits). The setuid fallback (`/opt/google/chrome/chrome-sandbox`, setuid root, plus `--disable-namespace-sandbox`) fails the same way. As a diagnostic, `google-chrome --no-sandbox` renders the local test page. Option B (loosening seccomp or adding capabilities) was rejected.
- The container and the egress firewall remain the security boundary. chrome-devtools is for local test pages and trusted automation only, never for logging into personal accounts.

## D17. Stella's Discord toolsets: only what works here, plus kanban
- Date: 2026-10-25
- Discord (`platform_toolsets.discord`, default profile) is now: clarify, code_execution, cronjob, delegation, discord, discord_admin, file, kanban, memory, session_search, skills, terminal, todo, vision.
- Removed, because they cannot work in this container: browser, computer_use, image_gen (Hermes's own `check_fn … returned False` after the Stage 5 rebuild); web (keyless Keenable search, api.keenable.ai blocked by the firewall); tts (provider edge, speech.platform.bing.com blocked); connections (hosted connectors, "The Nous service couldn't be reached").
- Added: kanban. The default profile is the board orchestrator (`kanban.orchestrator_profile: ""` = default), so Stella gets the board tools (kanban_create, kanban_list, kanban_unblock, …) as well as the lifecycle tools.
- Kept: discord_admin (discord.com is allowed now) and code_execution (not shown broken on the gateway; it is off on the CLI because the 9B misroutes shell commands to it in one-shot mode). The CLI platform is unchanged.

## D18. Supervisor reply path: in-channel replies use no tools
- Date: 2026-10-25
- Rule (SUPERVISOR.md "Supervisor reply path"): when Stella is asked to say, repeat, or post something in the channel she is already in, she replies directly there with no tool call; her reply IS the Discord message. No tool_search, discord MCP tools, terminal curl to discord.com/api, or manage_connections for an in-channel reply. search_members, fetch_messages and create_thread are only for acting elsewhere when explicitly asked.
- Reason: on 2026-10-25 a "send back" request went through tool_search, tool_describe, a terminal curl to the Discord API that tried to read `~/.cache/discord/oauth2.json`, and manage_connections. After the rule was added to Stella's SOUL, the live #supervisor tests ("repeat this back: hello", "say Hey, stargazer!") replied with the text, 1 API call and 0 tool turns each.
- Enforcement lives outside the repo: `/home/node/.hermes/SOUL.md` (default profile, the "Supervisor (Stella) rules" block). It is in the `~/.hermes` Docker volume, so it survives a rebuild but not a volume reset, and it is not committed.

## D19. Reviewer browser: read only
- Date: 2026-10-25
- Rule (SUPERVISOR.md R1.5, amended in place): the reviewer gets browser-read only (navigate, snapshot, screenshot, read-only evaluate, search/fetch for research) to test features live, compare live against the worktree, and research fixes. No browser-write: no click to submit, no form fill, no delete, and no file edit, push, or deploy. Same read access as builders, different write access, to keep the reviewer independent under R1.5.
- Status: policy only, not applied. The reviewer toolset (`/home/node/.hermes/profiles/reviewer/config.yaml`, `platform_toolsets.cli`, line 1415: clarify, file, terminal, session_search, skills, todo; hooks `deny-write.sh` and `test-only-terminal.sh` under `profiles/reviewer/hooks/`) has no browser. The Hermes browser toolset does not work in this container (D17) and bundles write actions (browser_click, browser_type), and web search/fetch is blocked by the firewall (D17). Enabling it first needs a fail-closed pre_tool_call deny hook for the write actions, verified by a write attempt, and that change would be local-only in the `~/.hermes` volume.

## D20. Secrets and sign-ins only through a secrets broker
- Date: 2026-10-25
- Rule (SUPERVISOR.md "Secrets and sign-ins"): agents never see password, token, or API key values. The broker is host-side, loopback only, never in the devcontainer. Reads from already-connected services may be automatic; writes, posts, payments, deletes, and sign-ins to a new service need a per-action Discord approval in #escalations, never blanket.
- Status: the broker is a post-go-live prerequisite and must exist before any agent gets secret access. Not built.

## D21. Global vs per-card tools
- Date: 2026-10-25
- Rule (SUPERVISOR.md "Global vs per-card tools"): infrastructure tools, hooks, and MCP servers registered at project scope (Chisle, Ponytail, Playwright, chrome-devtools) are global to that project. Content skills are enabled per card, not preloaded globally, to save context. The reviewer gets the same read tools as builders, not the same write tools (D19).
- Generalizes D7, which applied the per-card rule to find-skills; D7 is not superseded.

## D22. Reuse of skills and tools created in a worktree
- Date: 2026-10-25
- Rule (SUPERVISOR.md "Reuse of created skills and tools"): other agents in other worktrees can reuse such a skill or tool only after it is committed (worktrees see committed config only) and after triage (SkillSpector scan, show-me, supervisor review, recorded in decisions.md). Automatic reuse without Benji's approval only for low-risk, read-only, no-network, no-secret tools; network, write, or secret tools need Benji's approval in #escalations first.

## D23. Account creation (post-go-live only; rules recorded now)
- Date: 2026-10-25
- Rule (SUPERVISOR.md "Account creation"): a per-project vault in the broker, host-side only, never in a card or repo file; Benji provides one project email once per project. The broker generates a unique password per service and stores it in the vault (no single reused password per project). Agents never see password values; the broker performs create and login actions and returns only a result or a short-lived session. A host-side ledger records project, service, account email, creation date, card id, purpose, and last used, with no passwords; Benji can ask the supervisor to list accounts per project from it.
- Auto-create without Benji is allowed only for free, low-risk services with no payment method, no phone verification, and no ID verification; every creation is logged immediately. If an account already exists for that service in that project, the agent stops and opens an #escalations thread comparing the existing and proposed accounts; Benji replies Use existing, Create new, or Deny. Paid, phone, ID, or high-risk services also escalate, even when no account exists.
- Never: agent-led signup from credentials Benji supplies in chat, a paid tier, personal email reused for a business account, or terms acceptance without approval for that specific service. iCloud Keychain is not a direct write target from the Windows broker; the broker vault is the source of truth, with 1Password or Vaultwarden as a sync backend if Benji wants the credentials on his iPhone.
- Status: not built; depends on D20.
