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

`.stella/data-files.json` lists every data file: `id`, `path` (a file, or a folder of `*.json`), `schema` (a plain name
such as `settings`, lower case letters, digits and `-`, read as `.stella/schemas/<schema>.schema.json`; null for an env file), `format` (`json` or `env`), `owner_only` (only the
owner's path writes it), `redact_keys` (key names whose values are masked in logs), `list_key` (the array or map that
holds the entries) and `id_field` (several fields, comma separated, make an id joined with `:`; approved hosts use `host,port`).
It also names the event log, the backup folder, the applied-state file and the role table. Every path in the index is
relative, has no `..` part and must resolve (symlinks followed) inside the stack root; `check` refuses one that does not,
and `get`, `list` and `search` never read it. The index row of the index is `owner_only`: it decides which files are.
Two rows that resolve to one file (`./x` and `x`, a folder row and a row on one of its files) are refused, and neither is
opened. A row whose file is one of the role table's `owner_settings` must be format `env` and `owner_only`; `check` and the
read commands never open that file, whatever the row says. When the role table cannot be read, `check` says so, only the
files of env rows stay closed, and the rules that read the table do not run: the rows they judge (role assignments,
capabilities, extensions, connections) are refused, the others are still judged and served.

**Every file a row names is judged by every rule of its schema.** All the files of all the rows of one schema form one merged
view: the cross-file rules read every entry of it, and one entry id in two files (or twice in one) is refused. A schema that
is one document by nature says so with `"x-one-document": true` (the index, the data policy, the role assignments); a second
file of such a schema, in another row or in the same folder, is refused. That merged view is what `check` judges and what the
read commands serve.

Schemas use a small JSON Schema subset (the list is in the docstring of `bin/stella_data.py`). A schema that uses any
other keyword is an error, never ignored; so is a keyword with a wrong value (`required` as a string, an external `$ref`).
`const` and `enum` compare by JSON type (`true` is not 1); `pattern` is read as ECMA-262 does, so `$` is the very end of the
value. Data files are strict JSON: a repeated key, NaN and Infinity are errors. **What a problem line may print** (schema or
cross-file, in `check`, `validate` and every read command): a value taken from the file under check only when it is an id that
exists in the data (an entry id, a role, a provider); any other value is named by its field, its JSON type and, for a string, its
length. A key name taken from the file (an unknown key, a repeated key, a key of a free-form map in a path) is printed only when
no value pattern of the connections catalog (`redaction_patterns`) matches it; else it is "a masked key" at its path. File paths
from the index are printed: they locate the file. Lines that bin/roles.py writes about the role table are passed through as it
writes them (item W2). Numbers must fit a float (a number too large, or a non-zero number so small it would read as 0, is refused), strings must be valid Unicode text, and nesting is limited to 64 levels
(one limit for `check` and the read commands). Every data file needs `schema_version`. `check` also runs the
cross-file rules: role assignments against the connections catalog, the effort modes and the data policy (a project scope
needs `project`, a card scope needs `project` and `card`, a global scope has neither; project ids are lower case; one
assignment per scope, role and effort mode; no chain entry names a provider that is switched off, and its provider allows every data class of the role (`requirements.allowed_data_classes`; an empty `data_classes_allowed` allows none) and lists the assignment's role in its `allowed_roles` (`[]` allows no role); one card id belongs to one project; the role table's
`fallback_role` is not a role to assign or allow); `depends_on` in features (no missing target, no cycle, an `on` feature
depends only on `on` features); `allowed_roles` against the role table; a setting's store, default and `code` (it must
exist in the alert catalog) against the index and the registry itself; an extension is `enabled` only when `approved`; data
class names against data-policy `data_classes`; a provider with locality `local` lists at least one host and only hosts in data-policy `local_hosts`;
a provider or channel states `allowed_roles` and `risk_class`; approved hosts have real dates and expire after approval; a setting
that is not `secret` is not stored under a key its store row redacts. The rules find a file by the row's `schema`, so a renamed row
switches none off; when a file a rule needs has no JSON row, `check` says the rule could not run and exits 1. The index row that
describes the index must be `owner_only`, and `check data-files` reports everything a full `check` reports. The role table (the index's `role_table`, `.stella/schemas/roles.schema.json`) is valid only when both its schema and the validation in `bin/roles.py` pass (the rules the schema subset cannot say live there; a key that is not part of the table, of a role or of a profile row is refused by both, from the key lists in `bin/roles.py`); `check` and `validate roles <file>` run both, and `validate roles` also applies the data-class rule to a candidate file. `check <id>` prints that file's problems plus every cross-file problem and
every "could not run" problem, so a candidate file can be judged on its own; it exits 1 when any exists. `check` also says
which env-format rows it did not open (their keys are read by the apply tool, never here).

**Fields no rule reads (descriptive only).** Every other required field is checked for its shape by its schema and compared
with nothing else by this tool; a later phase (the resolver, the approval service, the firewall) or another tool reads it:
connections `subkind`, `label`, `auth_types`, `secrets` (names), `actions[]` and their `approval_class`, `models[].capabilities`,
`probed_at`, `probe_source`, `hosts[].port` and `purpose`, `data_policy` `retention`, `training_use`, `region` and
`zero_retention_available`, `tos`, and the value of `risk_class`; capabilities `kind`, `inputs`, `outputs`, `risk_class`,
`hosts`, `secrets`, `source`, `triage` (`summary`, `keywords` and `status` are what `search` reads and sorts by); extensions
`kind`, `hosts`, `secrets`, `tools`, `risk_class`, `source`; features `owner_phase`, `flag`; role assignments
`no_silent_fallback` and `chain[].parameters`; settings `label`, `scope` and `apply` (`settings get` shows them); every field
of a versions pin; approved hosts `scope` and `approved_by`; the index's `event_log`, `backup_dir` and `applied_state` (only
their paths are checked here; the apply and event-log tools use them).

Read commands fail closed and never serve what `check` refuses: `get`, `list` and `search` run the same rules as `check` (the
schema and the cross-file rules) on the files they serve, and a problem of one of those files, or of the index, gives exit 1
and one `STL-CFG-310` line naming it (the first problem, and how many more), never a traceback, never an empty result and no
data. A file with no problem of its own is still served while another file has one. A read leaves out what it does not need:
it does not validate the role table itself, and it opens only the rows whose schema the cross-file rules read or the served
rows' schema. `list` with no id and `search` serve every row, so a problem anywhere refuses them. `get` on an env-format row
says the id is known and not readable through this tool (`STL-CFG-319`, no alert line). `get`, `list` and `search` mask the value of any key matching the row's `redact_keys` (at any depth, so a key pasted into
a free-form object such as `parameters`, `cost` or `limits` is masked), the default of a `secret` setting, and every string a
value pattern of the connections catalog (`redaction_patterns`, from every entry) matches, inside lists too; `search` matches
the masked text, so it never answers for a masked value. `check` refuses a `redact_keys` pattern that is not a regular
expression. The patterns are the owner's picks: a name pattern also hides a non-secret field whose name it matches (the
shipped one ends in `token`, so `usd_per_input_token` would be shown as `***`), and a value no pattern matches is shown;
change the pattern, not the code. `validate <schema> <file>` prints each problem as a `STL-CFG-310` line, for every schema. A command that fails in a way not listed here ends in exit 1 and one
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
Every failure is one catalog code and its plain message: 310 data unreadable (the read commands) or a change that stopped half-way (the message says what was left), 311 unknown id, 312 owner-only,
313 refused (invalid candidate, a link, a path clash, a restore that no longer validates), 314 drift or a hand edit rollback would
overwrite, a setting's own code (today 315) for an env candidate that breaks the registry, 316 no, damaged or unrecorded backup, 318 event log.
An unexpected exception is exit 1 and one coded line (the exception type, never a value).

- **One change at a time.** One lock covers a whole apply or rollback, validation included, so the cross-file rules always judge
  a set with every earlier change in it. Once the lock is held the index, the gate and the target path are read again, so a run
  that waited acts on the state of that moment; after flock the locked file must still be the file at the lock path (else the
  run locks again, then refuses). `--dry-run` takes no lock and changes no data file, backup, applied state or event line; it
  stages a temporary copy of the set under `<backup_dir>/.stage/<pid>-...` and removes it when it ends (a copy a killed run
  left is swept by the next apply or rollback once its process is gone). If the masked text is unchanged but the bytes differ it
  says so in one line and names the changed keys (`-KEY (masked)` / `+KEY (masked)`). It also says what an apply would do about
  an unfinished step (refuse, finish it, or record a hand edit).
- **One row, one real file.** The target, each folder on the way, the backup folder, the applied-state file, the event log
  and their locks must not be symbolic links and must resolve to the path the index names. No two paths of the index (rows,
  `event_log`, `backup_dir`, `applied_state`) may be one file: the same device and inode, or the same name up to upper and lower
  case (the stack's own disk is case-insensitive); a path inside a folder row's folder or inside the backup folder is another
  path's file; a file with more than one hard link, or a mount point, is not read. Folder entries that differ only by case from an
  existing entry are one name and refused. The same checks run on a candidate index before it is applied. Applying the index
  itself is refused when the candidate is not a valid index, changes the three paths, drops the index's own row or a row that
  still has a backup. The index is read at the start and again once the lock is held. Every file the tool opens (a row, a folder
  entry, the log, the applied state, a meta file, a saved copy, a candidate, a lock) must be a regular file of at most 8 MiB,
  opened without blocking: a FIFO or device is one coded problem (313, 316, 318 or 310), never a wait. Reads and writes work
  relative to the folder as opened, which is checked to be at the path the index names; **the window that remains** is the moment
  between the last path check and that open (microseconds), and a swap of a folder above the opened one cannot redirect a write
  already started.
- **Validation.** A json candidate goes through the whole-set check with the candidate in place; a set whose cross-file rules
  "could not run" is refused even when the current tree already had that problem (the candidate that removes the cause is the
  way out). The staged set holds the index, the schemas, the role table and the hook files it names, and every json row; a folder
  is staged entry by entry, only plain regular files of the entry rule, none larger than 8 MiB (a stray entry is left out and
  `check` reports it by name; it does not refuse an unrelated apply). An env candidate is syntax-checked, then every setting the
  registry stores in that data file is checked with the registry's own type and validation (`stella_data.setting_problems`), and
  a setting with no default must be present; a failure is refused with that registry entry's own `code`. An env candidate with a
  carriage return or a byte-order mark, or an integer setting that is not plain decimal digits (a sign, a leading zero), is
  refused: a shell reading the file with `.` would read it differently. Keys the registry does not list stay allowed. The registry
  is found through the index row whose schema is `settings`. A json document nests at most 64 levels.
- **Backup and rollback.** Before a file is replaced its bytes, mode, previous applied record, both hashes and a random token are
  saved in `backup_dir/<key>/<counter>-<time>/` (`file`, `file.applied`, `meta.json`; folders 0700, files 0600). **The backup
  folder holds full copies of owner files until a rollback removes them; nothing in this tool keeps a role out of it. W4's path
  rules (read and write refusals for every role) are what does.** Backups are ordered by a counter kept in the applied state,
  never by the clock; the name carries it in eight digits, so the counter stops at 99999999 (an apply then says how to repair; a
  counter in the state beyond that is read as 0). A new file of an owner-only row or a row with `redact_keys` is created 0600; an
  existing file keeps its mode. Temp files are 0600 and the next run for that row sweeps this tool's own (`.stella-apply.*`)
  while it holds the lock.
  **Provenance.** The tool writes, in the applied state (only this tool writes it), which backup (name and token) belongs to each
  apply, before it touches the file; the same token is in the backup's meta file and in the event line's detail. Rollback
  restores or deletes only from a folder the applied state records for that key, whose meta holds that token and a well-formed
  record (every field is checked, `seq` included). A folder the state does not know, or whose token differs, is never restored
  from and never makes the tool delete or overwrite a file: `check`, `apply` and `rollback` stop with 316 and name the folder,
  and the owner removes it by hand. This is not a defence against someone who can write the applied state; that is the hooks'
  job (W4). Beyond that: the saved copy must match its recorded sha256 (else 316, never a delete), the file must hold the bytes
  the apply wrote or the bytes it replaced (anything else is a hand edit: 314, untouched), and the restored content goes
  through the same validation as a candidate (else 313: apply the content you want instead). A restored file that git does not
  track keeps the restored hash as its applied baseline, so a later hand edit is drift.
  **Unfinished and damaged folders.** A folder whose `meta.json` is missing (the only thing a kill can leave) is unfinished:
  `check` reports it (314), `apply` refuses, and `rollback` removes it, says so, and stops there with exit 0 (nothing is
  restored in that run; run it again to undo the last change). A meta file that is present but unreadable or wrong is damage:
  316, nothing deleted. A folder is removed meta file first, so a kill during a removal leaves an unfinished folder, never a
  damaged one.
- **Interrupted runs.** A rollback marks its backup `rollback-pending` first; a kill at any step is finished by the next
  `rollback`, which writes the event line the killed one did not, with the real old and new values (the saved copy and the
  bytes the apply wrote). An apply killed after the replace is finished by repeating it (the missing bookkeeping and event line
  are written); otherwise `rollback` restores the file. The event log is consulted only to resume such a step, and only for the
  token, which nobody can know before the line exists: a line already in the log that names the backup cannot suppress the
  tool's own line. The "nothing to restore" branch writes an event line too, saying so. A failure after the replace says what
  state was left (STL-CFG-310) and what the next run will do; "Nothing was changed" is printed only when that is true. An
  interrupted apply followed by a hand edit: `apply <id> --from <file holding the current bytes>` records them (an `adopt`
  line) and sets the interrupted backup aside.
- **Check.** Drift is a sha256 or mode that differs from the last applied record, or (never applied) from the committed blob.
  Folder rows list the entries on disk, the applied ones and the committed ones (a deleted committed entry is drift); an entry
  that cannot be read (a FIFO, a folder, too large) is one problem line naming it and the other rows are still checked.
  `check <id>/<name>` on a single-file row is refused like the other commands. Applying the bytes a hand edit already put there
  records them: the applied state gets a marker token first, then the event line (`adopt`, with the old and new values under the
  same masking as an apply line, and the hashes unless the row is private), then the older backups of the key are set aside
  (status `superseded`: kept as history, no longer used by rollback, no longer holding the row in the index) and the marker is
  cleared; a kill in between is finished by the next apply of the same bytes.
- **Event log.** One JSON line per state change, ASCII only (no value can hold a line separator), written whole or not at all
  under the log's lock: a log that does not end in a newline gets one first, and after a failed or short write the file is cut
  back to its earlier size (318). Readers split on `\n` only; a line that is not a JSON object, is larger than 4 MiB, nests
  deeper than 64 levels, or cannot be parsed, masked or printed for any reason is counted as unreadable and reported
  (`STL-CFG-318` on stderr, `unreadable_lines` in `history --json`), never dropped silently, and never stops a reader or a
  rollback. The writer refuses a line nested deeper than 16 levels or larger than 1 MiB (313): what it writes always reads back.
  Only values of keys that match a row's `redact_keys` and of registry settings whose `sensitivity` is `secret` are `***` (in the
  line, the dry run, `history` and `tail`); identity-critical and plain settings show their old and new values, so the event log
  holds old and new values of non-secret owner settings and who may read the log is item W4's question. A scalar `old` / `new`
  of a row that has redact keys or stores a secret setting is `***` whole. `event_log.py append --detail` is scrubbed of the
  values masked in the same call (by substring; the apply tool's own detail holds only its own text, hashes, names and the
  token, and is not scrubbed, so a short masked value cannot garble the backup name or the token). No file hash is written
  for a private row (owner-only alone does not suppress it). A new file's event has `old: null`. `append --code` must be in the
  alert catalog. `tail` escapes every field it prints.
- **Limits that remain.** The owner-only gate (`worker_markers` in the role table, then `roles.py prove`) cannot prove an owner
  from inside the process: a caller can clear its marker variables, shadow the board tool on `PATH` or detach from its parent.
  **The boundary is the hooks of every role refusing to run `bin/stella-apply.py` and `bin/event_log.py` (and writing the owner
  files and the state paths) at all (item W4).** `who` in an event line is the OS user name only, and any caller that can run
  `event_log.py append` can append a line of any type; W4's path rules keep roles from writing the log directly. The applied
  state keeps a sha256 of each file (drift needs it), also for owner-only rows. A restore that deletes a file the apply created
  is not checked against the whole set. `check` reads owner-only rows' metadata without the gate (the hooks keep roles from
  running the tool). A lock file replaced while it is held (needs a write in the 0700 lock folder) gives two holders; one
  replaced while a run waits is detected. Rollback of a key whose adopt line is still missing (a kill, then a rollback before
  the next apply) leaves that adopt without its line.

## The owner-only write path (item W4)

Owner settings and owner data change only through the owner's tools (`bin/settings.py`, `bin/stella-apply.py`); no role runs them, writes the files, or reads the apply tool's state. **A text guard cannot decide what a shell will do**, so this is three layers, each holding on its own for the roles it covers; the write guard is the mistake guard in front of them, and no acceptance claim rests on it alone:

1. **Roles that run in the OS box** (`sandbox.boxed_profiles`): the box is the boundary. The main checkout is mounted read-only; the owner settings, the canary and the apply tool's state (the `backup_dir`, `applied_state` and `event_log` the data index names) are not mounted at all, so a one-liner in any interpreter finds neither file nor listing.
2. **Roles that do not run in the box** (`runs_unboxed` true in the role table: the coordinator, and the fallback role of a profile with no row): their hooks refuse every write. The table says so in data and `bin/roles.py` checks it: every profile outside `boxed_profiles` has a role with `runs_unboxed` true; such a role has explicit `platform_toolsets` (the fallback: every Hermes platform, `file` and `terminal` only), on each tool of `write_tools` a hook entry marked `"writes": "refused"` (an allow-list terminal, deny-write) and none marked `"writes": "judged"` (the write guard); the fallback also has a hook for any tool name no other matcher names. A profile that is given a role without this must be boxed first.
3. **The merge** (`bin/merge-card.sh`): whatever reaches a card branch, however it was made (plumbing, another agent CLI's git, a patch), meets one check. The paths the branch changes against its merge base (`git diff --name-only -z --no-renames`, both sides of a rename) must hold no owner settings or owner data path; nothing is merged otherwise (STL-CFG-312). Paths that define the boundary itself (`bin/roles.py boundary`: the role table's `boundary_paths` and every hook file or command the table names) are listed and refused unless the owner passes `--i-have-read-the-boundary-changes`.

**Owner data** is one definition (`bin/roles.py owner_paths`, `roles.py owner-data`): the data index itself, every path of an index row with `owner_only: true` (so a new owner-only row is protected with no other edit; `.supervisor/limits.env` is owner data through its row), the role table's own `owner_data` list (what the index cannot name: the schemas folder) and `owner_settings`. Rows that are not owner-only (the capability registry, the versions file) and `.stella/test-map.json` stay writable on a card branch. The write guard, the commit guard (`-z --no-renames`: a non-ASCII name, a rename out of an owner folder and a deletion count) and the merge check all use it; an index that cannot be read makes every guard refuse, the write guard included.

**What the write guard reads.** Commands are split at unquoted newlines; every redirect operator (`>`, `>>`, `>|`, `&>`, `&>>`, `>&word`, `<>`) is judged; every word it judges (a redirect target, an argument of a write verb, a git path, the command word, each argument of an interpreter) is expanded first (`$'..'`, quotes, braces, `~`, variables it can know, globs; the code `roles.expand_word`/`ansi`/`braces` is shared with the read guard) and compared as a real path without regard to case. Owner commands (`owner_commands`, including `bin/event_log.py`) are matched by the file a word resolves to (the stack's own file or its copy in a card worktree of the stack, since a copy runs on whatever tree `STELLA_ROOT` names), not by a name in the text; a wrapper's other words (`env -u NAME`, `timeout 5`, `sudo -u`) count too; `owner_commands_by_name` (the merge command) is also refused by its name anywhere in a command. A judged word that still holds an expansion only the shell can compute (an unknown variable, `$(..)`), `xargs` or `find -exec` feeding an interpreter, and `git --pathspec-from-file`, `--git-dir`, `--work-tree` are refused. git commands that write (git's own classes: `GIT_WRITERS`) are judged like any write: every named path against the protected set and owner data, and the tree they run in must be the caller's card worktree; inside the worktree a tree-wide form (`.`, `:/`) is allowed. Any exception in the guard is a refusal with a coded line.
**What it cannot see**, and the layer that covers it: an interpreter that loads a file by import or from stdin (`python3 -m settings`, `-c "import settings"`), code run inside another agent CLI and that CLI's own git and file tools (the box, layer 1, and the merge, layer 3); a word the shell computes after the hook (the allow-list roles refuse it outright, layer 2). The tools' own owner gate proves an owner by the absence of a worker proof (`roles.py prove`); no positive proof of the caller exists in F1, so layers 1 and 2 keep roles away from the tools.

A refusal on the owner boundary (an owner-data write, an owner command, a read or write of an owner state path, the merge refusals) prints `STL-CFG-312` and the catalog's plain message and writes one alert line (the catalog's page policy decides paging), with no value from any owner file. Refusals older than F1 keep their text. Roles do not read the event log in F1 (it holds old and new values of owner settings in clear); this may change later.

The canonical env writer refuses a value that holds both a single quote and any of `$`, a backtick, a backslash or a double quote (the strict parser has no escapes, so it could not be read back as itself); the settings tool also refuses a store file that holds a key twice (STL-CFG-313) before it compares or writes anything.

## Alert codes
`STL-CFG-310` (a data file is invalid), `STL-CFG-311` (a name is not in the data) and `STL-CFG-319` (an env-format row is
not readable through this tool) are used by `stella_data.py`.
`STL-CFG-312` to `318` are used by the apply and event-log tools (see above).
