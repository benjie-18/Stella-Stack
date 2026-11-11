# The core contract

Every core card ships all fourteen items below. The contract data lives in `.stella/`; `bin/stella_data.py` reads and
checks it. Check everything with `python3 bin/stella_data.py check` (exit 0 = valid; exit 1 = one `STL-CFG-310` line per
problem). Read with `list`, `get <id> [<entry>]` and `search <words>`; every read command takes `--json`.

## The 14 items

1. **Data first.** Behavior comes from versioned data files, each with a schema and a validator: the role table,
   the alert catalog, the connections catalog, the approved hosts, extension manifests, features and versions. No names in code.
2. **Headless core, JSON out.** Every core has a CLI with `--json` read commands. Write commands go through the same
   gate path as approvals in any connected channel.
3. **One approval service, channel-neutral.** Approvals and escalations go through one interface
   ([approval-service.md](approval-service.md)). Gate rules live once.
4. **One event log.** Append-only JSONL with a schema version (`.stella/schemas/event.schema.json`). No secret values.
5. **Codes from the catalog.** Every failure has a catalog code and a plain message (`docs/alert-codes.md`).
6. **Selftest, a fake entry, and a hard-code lint.** Each core ships a selftest and a test that adds a fake entry in a
   scratch root and proves it works with no code change. A lint fails on a new literal name in code.
7. **Unknown fails closed.** An unknown role, provider, app or extension gets the most restrictive treatment plus one
   alert (`STL-CFG-311`), never open access.
8. **Apply contract.** Anything the app writes is applied by an idempotent script with check (drift), dry run, backup
   and rollback. The app never edits live config directly.
9. **Versioned and portable.** `schema_version` in every data file; migrations are scripts; export and import never
   contain secret values; pins live in `.stella/versions.json` with tested-with fields.
10. **Adapter boundary.** The engine and each worker CLI sit behind one adapter module each.
11. **Extension manifest.** Skills, MCP servers, connectors, channels, worker adapters and providers each declare hosts,
    secrets, tools, allowed roles and risk class. Install needs approval; each has a disable switch.
12. **Feature registry.** `.stella/features.json` lists every feature: id, owner phase, status, depends_on, flag.
13. **Host-OS interface.** No new hard-coded paths, users or hosts in Windows scripts.
14. **Supportable.** Logs redact secrets; `docs/alert-codes.md` is generated from the catalog
    (`bin/alert-catalog.sh --docs`).

## The index and the schemas

`.stella/data-files.json` lists every data file: `id`, `path` (a file, or a folder of `*.json`), `schema`
(`.stella/schemas/<schema>.schema.json`, or null for an env file), `format` (`json` or `env`), `owner_only` (only the
owner's path writes it), `redact_keys` (key names whose values are masked in logs), `list_key` (the array or map that
holds the entries) and `id_field` (several fields, comma separated, make an id joined with `:`; approved hosts use `host,port`).
It also names the event log, the backup folder, the applied-state file and the role table. Every path in the index is
relative, has no `..` part and must resolve (symlinks followed) inside the stack root; `check` refuses one that does not,
and `get`, `list` and `search` never read it. The index row of the index is `owner_only`: it decides which files are.

Schemas use a small JSON Schema subset (the list is in the docstring of `bin/stella_data.py`). A schema that uses any
other keyword is an error, never ignored; so is a keyword with a wrong value (`required` as a string, an external `$ref`).
`const` and `enum` compare by JSON type (`true` is not 1); `pattern` is read as ECMA-262 does, so `$` is the very end of the
value. Data files are strict JSON: a repeated key, NaN and Infinity are errors. A problem message never prints the rejected
value, only its JSON type and, for a string, its length. Every data file needs `schema_version`. `check` also runs the
cross-file rules: role assignments against the connections catalog, the effort modes and the data policy (a project scope
needs `project`, a card scope needs `project` and `card`, a global scope has neither; project ids are lower case; one
assignment per scope, role and effort mode; no chain entry names a provider that is switched off; the role table's
`fallback_role` is not a role to assign or allow); `depends_on` in features (no missing target, no cycle, an `on` feature
depends only on `on` features); `allowed_roles` against the role table; a setting's store, default and `code` (it must
exist in the alert catalog) against the index and the registry itself; an extension is `enabled` only when `approved`; data
class names against data-policy `data_classes`. `check <id>` prints that file's problems plus every cross-file problem and
every "could not run" problem, so a candidate file can be judged on its own; it exits 1 when any exists. `check` also says
which env-format rows it did not open (their keys are read by the apply tool, never here).

Read commands fail closed: a file that is malformed, nested too deeply, not an object or fails its schema gives exit 1 and one
`STL-CFG-310` line naming it, never a traceback and never an empty result. `get` on an env-format row says the id is known and
not readable through this tool (no alert line). `get` and `search` mask the value of any key matching the row's `redact_keys`
and the default of a `secret` setting. `search` matches values, not key names, ignoring case (also non-ASCII text).

**Secrets are names only.** A `secrets` field holds variable names such as `SOME_API_KEY`, never a value. The schema enforces
a shape: upper case letters, digits and underscores, starting with a letter, with at least one underscore, at most 64
characters. That stops text that does not look like a name and most pasted keys (they rarely contain an underscore); it is
not a guarantee that a value cannot be written in that shape, so never put a credential there.

**How to add any entry:** edit the file, run `python3 bin/stella_data.py check`, then `get <id> <entry id>`. No code changes.
Unknown means `null` or `"unverified"`: never write a capability, cost or term you have not checked.

## One section per data file

### `.stella/connections.json` (connections catalog)
Providers, apps and channels as one list (`entries[]`, `kind` is provider, app or channel). Fields: `id`, `kind`, `subkind`
(for example `openai-compatible-aggregator`), `label`, `enabled`, `locality` (local or cloud), `hosts[]` (host, port,
purpose), `auth_types[]`, `secrets[]` (names), `actions[]` (id and approval class: read is automatic; write, post, send,
pay, delete need approval first; sign_in is an escalation), `models[]` (id, probed `capabilities`: `tool_calling`,
`json_mode`, `context_tokens`, `vision`, `streaming`, each a value or null for not probed; `probed_at`, `probe_source`),
`data_policy` (retention, training use, region, zero retention, `data_classes_allowed`; an empty list allows no class)
`tos` (`status`, `unverified` is a legal value; `subscription_login_by_agent` is the declared automated-agent terms flag:
`unverified`, `allowed`, `forbidden` or `not_applicable`), `scopes[]` (the access scopes it asks for), `redaction_patterns[]`
(regular expressions masked in its logs) and, optionally, `allowed_roles[]` and `risk_class`. *To add one:* append an entry; an aggregator proxy is a provider with
`subkind: openai-compatible-aggregator`, disabled until the owner turns it on, with its own outbound hosts in `hosts`.

### `.stella/data-policy.json`
`data_classes[]`, a `default` and `projects{}`; each has `mode` (`open`, `local_only`, `allowed_providers`) and
`allowed_providers[]`. *To add a project rule:* add a key under `projects`.

### `.stella/role-assignments.json`
`effort_modes{}` (allowed localities and `no_silent_fallback` for standard, eco, max, local_only) and `assignments[]`:
`scope` (`level` global, project or card, with `project` or `card`), `role`, `effort_mode`, and an ordered `chain[]` of
`{provider, model, parameters}`. **Precedence:** the data policy first, then the card, then the project, then the global
assignment. An override never widens the data policy: `check` refuses a chain entry the policy forbids for its project.
It also refuses an unknown provider, model, role or mode, an empty chain, and a provider whose locality the mode forbids.
The resolver that applies the precedence is built in a later phase; this file is the data and the validator.
*To add one:* append an assignment with a new `id`.

### `.stella/approved-hosts.json`
`hosts[]`: host (a host name; `*` alone is refused), port, scope and approved_by (not empty), approved_at and expires_at
(`YYYY-MM-DDTHH:MM:SSZ`, UTC; expires_at may be null). One entry per host and port. Ships empty. The live firewall does not read it yet.

### `.stella/capabilities.json` (capability registry)
One schema for tools, skills, MCP servers, commands and extensions: `id`, `kind`, `summary`, `keywords`, `inputs`,
`outputs`, `allowed_roles`, `risk_class`, `hosts`, `secrets`, `status` (proposed, approved, disabled), `source`, `triage`.
`search` lists approved entries first. **Finding a capability grants nothing:** using it still goes through the role
table and the gates. *To add one:* append an entry for everything you add (a tool, skill, command, MCP server, extension).

### `.stella/features.json`
`entries[]`: `id`, `owner_phase`, `status` (planned, off, preview, on), `depends_on[]`, `flag`.

### `.stella/extensions/`
One manifest per file (see its README); `enabled` is the disable switch; install needs approval, so a new manifest is
`proposed`. *To add one:* drop a `<id>.json` in the folder.

### `.stella/versions.json`
`pins[]`: `id`, `kind`, `version`, `source`, optional `integrity`, and `tested_with` (`stack_commit`, `date`, `with[]`).

### `.stella/settings.json` (settings registry)
Every owner-editable setting: `key`, `label`, `type`, `validation`, `scope`, `sensitivity` (plain, identity_critical,
secret), `default`, `store` (`data`: an index id, `key`), `apply` (script, needs_restart) and the catalog `code` shown on
failure. Secrets are never stored or shown here: a `secret` setting has no default, and `get` and `search` mask it. A default
must satisfy the setting's own `type` and `validation`; `validation` must be coherent (minimum not above maximum, a pattern
that compiles, an enum with values). Patterns are read with `$` as the very end of the value.

### Event and approval schemas
`.stella/schemas/event.schema.json`, `approval-request.schema.json` and `approval-decision.schema.json` are schemas for
lines and messages, not data files. Check a sample with `stella_data.py validate <schema> <file>`.

## Alert codes
`STL-CFG-310` (a data file is invalid) and `STL-CFG-311` (a name is not in the data) are used by `stella_data.py`.
`STL-CFG-312` to `318` are reserved for the apply and settings tools.
