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
value. Data files are strict JSON: a repeated key, NaN and Infinity are errors. A problem line (schema or cross-file) never
prints a value taken from the file under check unless that value is an id that exists in the data (an entry id, a role, a
provider); otherwise it names the field and gives the JSON type and, for a string, its length. File paths from the index are
printed: they locate the file. Numbers must fit a float, strings must be valid Unicode text, and nesting is limited to 64 levels
(one limit for `check` and the read commands). Every data file needs `schema_version`. `check` also runs the
cross-file rules: role assignments against the connections catalog, the effort modes and the data policy (a project scope
needs `project`, a card scope needs `project` and `card`, a global scope has neither; project ids are lower case; one
assignment per scope, role and effort mode; no chain entry names a provider that is switched off, and its provider allows every data class of the role (`requirements.allowed_data_classes`; an empty `data_classes_allowed` allows none); one card id belongs to one project; the role table's
`fallback_role` is not a role to assign or allow); `depends_on` in features (no missing target, no cycle, an `on` feature
depends only on `on` features); `allowed_roles` against the role table; a setting's store, default and `code` (it must
exist in the alert catalog) against the index and the registry itself; an extension is `enabled` only when `approved`; data
class names against data-policy `data_classes`; a provider with locality `local` lists at least one host and only hosts in data-policy `local_hosts`;
a provider or channel states `allowed_roles` and `risk_class`; approved hosts have real dates and expire after approval; a setting
that is not `secret` is not stored under a key its store row redacts. The rules find a file by the row's `schema`, so a renamed row
switches none off; when a file a rule needs has no JSON row, `check` says the rule could not run and exits 1. The index row that
describes the index must be `owner_only`, and `check data-files` reports everything a full `check` reports. The role table (the index's `role_table`, `.stella/schemas/roles.schema.json`) is valid only when both its schema and the validation in `bin/roles.py` pass (the rules the schema subset cannot say live there); `check` and `validate roles <file>` run both, and `validate roles` also applies the data-class rule to a candidate file. `check <id>` prints that file's problems plus every cross-file problem and
every "could not run" problem, so a candidate file can be judged on its own; it exits 1 when any exists. `check` also says
which env-format rows it did not open (their keys are read by the apply tool, never here).

Read commands fail closed: a file that is malformed, nested too deeply, not an object or fails its schema gives exit 1 and one
`STL-CFG-310` line naming it, never a traceback and never an empty result. `get` on an env-format row says the id is known and
not readable through this tool (no alert line). `get`, `list` and `search` mask the value of any key matching the row's `redact_keys` (at any depth, so a key pasted into
a free-form object such as `parameters`, `cost` or `limits` is masked) and the default of a `secret` setting; `check` refuses a
`redact_keys` pattern that is not a regular expression. A command that fails in a way not listed here ends in exit 1 and one
`STL-CFG-310` line naming only the exception type. `search` matches values, not key names, ignoring case (also non-ASCII text).

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
`tos` (`status`, `unverified` is a legal value; `subscription_login_by_agent` is required and is the declared automated-agent terms flag:
`unverified`, `allowed`, `forbidden` or `not_applicable`; no other key), `scopes[]` (the access scopes it asks for), `redaction_patterns[]`
(Python regular expressions masked in its logs) and `allowed_roles[]` and `risk_class` (required on a provider and a channel; `[]` allows no role). *To add one:* append an entry; an aggregator proxy is a provider with
`subkind: openai-compatible-aggregator`, disabled until the owner turns it on, with its own outbound hosts in `hosts`.

### `.stella/data-policy.json`
`data_classes[]`, `local_hosts[]` (the host names that count as local; a provider declared local may list only these), a `default` and `projects{}`; each has `mode` (`open`, `local_only`, `allowed_providers`) and
`allowed_providers[]`. *To add a project rule:* add a key under `projects`.

### `.stella/role-assignments.json`
`effort_modes{}` (allowed localities and `no_silent_fallback` for standard, eco, max, local_only) and `assignments[]`:
`scope` (`level` global, project or card, with `project` or `card`), `role`, `effort_mode`, and an ordered `chain[]` of
`{provider, model, parameters}`; effort-mode ids are lower case ASCII like other ids. **Precedence:** the data policy first, then the card, then the project, then the global
assignment. An override never widens the data policy: `check` refuses a chain entry the policy forbids for its project.
It also refuses an unknown provider, model, role or mode, an empty chain, and a provider whose locality the mode forbids.
The resolver that applies the precedence is built in a later phase; this file is the data and the validator.
*To add one:* append an assignment with a new `id`.

### `.stella/approved-hosts.json`
`hosts[]`: host (a host name; a wildcard `*.` needs at least two labels after it, so `*.com` is refused), port, scope and approved_by (not empty), approved_at and expires_at
(`YYYY-MM-DDTHH:MM:SSZ`, UTC, real dates; expires_at may be null and is after approved_at). One entry per host and port. Ships empty. The live firewall does not read it yet.

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

## The apply tool and the event log (`bin/stella-apply.py`, `bin/event_log.py`)

`stella-apply.py apply <id> --from <file> [--dry-run]`, `check [<id>] [--json]`, `rollback <id>`, `history <id> [--json]`.
A single-file row is addressed by its id only; a folder row by `<id>/<name>`, where the name is letters, digits, dot, dash and
underscore, starts with a letter, digit or underscore, and ends in `.json`. Exit 0 ok, 1 refused or failed (or drift), 2 usage.
Every failure is one catalog code and its plain message: 310 data unreadable (the read commands), 311 unknown id, 312 owner-only,
313 refused (invalid candidate, a link, a path clash, a restore that no longer validates), 314 drift or a hand edit rollback would
overwrite, a setting's own code (today 315) for an env candidate that breaks the registry, 316 no or damaged backup, 318 event log.
An unexpected exception is exit 1 and one coded line (the exception type, never a value).

- **One change at a time.** One lock covers a whole apply or rollback, validation included, so the cross-file rules always judge
  a set with every earlier change in it. `--dry-run` takes no lock and writes nothing; if the masked text is unchanged but the
  bytes differ it says so in one line and names the changed keys (`-KEY (masked)` / `+KEY (masked)`).
- **One row, one real file.** The target, each folder on the way, the backup folder, the applied-state file, the event log
  and their locks must not be symbolic links and must resolve to the path the index names; no two rows (or a row and the index's
  `event_log`, `backup_dir`, `applied_state`) may name one file. The index is read once per run. Applying the index itself
  is refused when the candidate changes those three paths, drops the index's own row or a row that still has a backup.
- **Validation.** A json candidate goes through the whole-set check with the candidate in place; a set whose cross-file rules
  "could not run" is refused even when the current tree already had that problem (the candidate that removes the cause is the
  way out). An env candidate is syntax-checked, then every setting the registry stores in that data file is checked with the
  registry's own type and validation (`stella_data.setting_problems`), and a setting with no default must be present; a failure is
  refused with that registry entry's own `code`. Keys the registry does not list stay allowed (the files hold more keys than the
  registry lists). The registry is found through the index row whose schema is `settings`.
- **Backup and rollback.** Before a file is replaced its bytes, mode, previous applied record and both hashes are saved in
  `backup_dir/<key>/<counter>-<time>/` (`file`, `meta.json`; folders 0700, files 0600). **The backup folder holds full copies of
  owner files until a rollback removes them; nothing in this tool keeps a role out of it. W4's path rules (read and write refusals
  for every role) are what does.** Backups are ordered by a counter kept in the applied state, never by the clock. A new file of an
  owner-only row or a row with `redact_keys` is created 0600; an existing file keeps its mode. Temp files are 0600 and the next
  run for that row sweeps this tool's own (`.stella-apply.*`) while it holds the lock. A backup folder without a readable
  `meta.json` is reported by `check` (314), blocks `apply`, and is removed by `rollback`.
  Rollback restores only what the tool saved: the saved copy must match its recorded sha256 (else 316, never a delete), the file
  must hold the bytes the apply wrote or the bytes it replaced (anything else is a hand edit: 314, untouched), and the restored
  content goes through the same validation as a candidate (else 313: apply the content you want instead).
- **Interrupted runs.** A rollback marks its backup `rollback-pending` first; a kill at any step is finished by the next
  `rollback`, which writes the event line the killed one did not. An apply killed after the replace is finished by repeating it
  (the missing bookkeeping and event line are written); otherwise `rollback` restores the file. The "nothing to restore" branch
  writes an event line too.
- **Check.** Drift is a sha256 or mode that differs from the last applied record, or (never applied) from the committed blob.
  Folder rows list the entries on disk, the applied ones and the committed ones (a deleted committed entry is drift); an entry
  that cannot be read is one problem line and the other rows are still checked. Applying the bytes a hand edit already put there
  records them (applied state and an `adopt` event line, no backup).
- **Event log.** One JSON line per state change, ASCII only (no value can hold a line separator), written whole or not at all
  under the log's lock: a log that does not end in a newline gets one first, and after a failed or short write the file is cut
  back to its earlier size (318). Readers split on `\n` only; a line that is not a JSON object is counted and reported
  (`STL-CFG-318` on stderr, `unreadable_lines` in `history --json`), never dropped silently. Only values of keys that match a row's
  `redact_keys` and of registry settings whose `sensitivity` is `secret` are `***` (in the line, the dry run, `history` and `tail`);
  identity-critical and plain settings show their old and new values, so the event log holds old and new values of non-secret
  owner settings and who may read the log is item W4's question. A scalar `old` / `new` of a row that has redact keys or stores a
  secret setting is `***` whole; `--detail` goes through the same scrub as an error message; no file hash is written for such a
  row (owner-only alone does not suppress it). A new file's event has `old: null`. `append --code` must be in the alert catalog.
- **Limits that remain.** The owner-only gate (`worker_markers` in the role table, then `roles.py prove`) cannot prove an owner
  from inside the process: a caller can clear its marker variables, shadow the board tool on `PATH` or detach from its parent.
  **The boundary is the hooks of every role refusing to run `bin/stella-apply.py` (and writing the owner files) at all (item W4).**
  `who` in an event line is the OS user name only, and any caller that can run `event_log.py append` can append a line of any
  type; W4's path rules keep roles from writing the log directly. The applied state keeps a sha256 of each file (drift needs it),
  also for owner-only rows. A restore that deletes a file the apply created is not checked against the whole set.

## Alert codes
`STL-CFG-310` (a data file is invalid) and `STL-CFG-311` (a name is not in the data) are used by `stella_data.py`.
`STL-CFG-312` to `318` are used by the apply and event-log tools (see above).
