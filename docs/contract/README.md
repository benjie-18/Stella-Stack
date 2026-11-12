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

`.stella/data-files.json` lists every data file: `id`, `path` (a file, or a folder of `*.json`: **a row is a folder of entries
when its format is `json` and its path does not end in `.json`; every other row is one file**, and nothing else decides it, not
the list key and not the disk; `stella_data.folder_row(row)` is that rule for this tool and the apply tool), `schema` (a plain name
such as `settings`, lower case letters, digits and `-`, read as `.stella/schemas/<schema>.schema.json`; null for an env file), `format` (`json` or `env`), `owner_only` (only the
owner's path writes it), `redact_keys` (key names whose values are masked in logs), `list_key` (the array or map that
holds the entries) and `id_field` (several fields, comma separated, make an id joined with `:`; approved hosts use `host,port`).
It also names the event log, the backup folder, the applied-state file and the role table. Every path in the index is
relative, has no `..` part and must resolve (symlinks followed) inside the stack root; `check` refuses one that does not,
and `get`, `list` and `search` never read it. The index row of the index is `owner_only`: it decides which files are.
**A row is charged for its own fault only**, also for where its path points. A JSON row whose path, a folder in that path below
the stack root, or an entry file of its folder is a symbolic link is refused, that row alone ("must not be a symbolic link",
naming the row and the path): it is compared with no other row, so the row whose file the link points to (the settings
registry, the index, the catalog) gets no line and stays served. A link that leaves the stack root is refused as leaving it.
Two rows that spell the same file (`./x` and `x`, a folder row and a row on one of its files) are refused, and neither is
opened; each of them is refused with that reason, naming every row. A JSON row whose disk disagrees with its kind is a problem
of that row and is not opened: a path ending in `.json` that is a folder, a path not ending in `.json` that is a file (the line
says to rename the path in the index so it does not, or does, end in `.json`), or a folder row whose folder does not exist. A
row id that is a name this tool uses for something that is no row (`role-table`, the index's `data-files` on a row that is not
the index, anything starting with `schema:`) is refused. A row whose file is one of the role table's
`owner_settings` must be format `env` and `owner_only`; `check`, `validate` and the read commands never open an owner settings
file of the stack root they run on (`STELLA_ROOT`, else the tool's own parent folder), whatever the row or the path says:
before a byte is read, the identity of the file (device and inode, from `stat` and again from the opened file) is compared
with that root's owner settings files and every env row's file, so a hard link, a symlink or a link swapped during the run is
refused unread; when the index of that root cannot be read or is not valid, `validate` opens no file at all and says so
(`STL-CFG-310`). Limit: the list of closed files comes from the root the tool runs on, so a caller who points `STELLA_ROOT` at
another root can have `validate` open a file that is an owner setting of the first root (the secret guard, not this tool, is
the control for a command that names such a path). Env rows and owner settings keep the identity rule only (no link rule here;
the apply tool has its own), so an env row that resolves to a JSON row's file still closes both rows. A folder row lists the
`*.json` names of its folder (by name: `[`, `*`, `?` in
the row path or the stack root are plain characters, never a glob). When the role table cannot be read, `check` says so, only
the files of env rows stay closed, and the rules that read the table do not run: the rows they judge (role assignments,
capabilities, extensions, connections) are refused, the others are still judged and served.

**Every file a row names is judged by every rule of its schema.** All the files of all the rows of one schema form one merged
view: the cross-file rules read every entry of it, and one entry id in two files (or twice in one) is refused. A schema that
is one document by nature says so with `"x-one-document": true` (the index, the data policy, the role assignments, the
settings registry, the features, the versions); a second file of such a schema, in another row or in the same folder, makes
every file of that schema refused (each with a line naming them all), so neither is "the" document and row order decides
nothing. **A file that fails its schema feeds no rule**: its entries are not in the merged view, and every rule that reads its
schema does not run; the rows those rules judge get one line "not judged by the cross-file rules: <the refused row> is
refused". A rule that fails anyway is one line naming every row it read (never the index). That merged view is what `check`
judges and what the read commands serve.

Schemas use a small JSON Schema subset (the list is in the docstring of `bin/stella_data.py`). A schema's identity is its name:
the file `<name>.schema.json` in `.stella/schemas/`. A schema file that is a symbolic link is refused; a byte copy under
another name is another schema, which the cross-file rules do not read (the schemas folder is owner data). A schema that uses any
other keyword is an error, never ignored; so is a keyword with a wrong value (`required` as a string, an external `$ref`).
`const` and `enum` compare by JSON type (`true` is not 1); `pattern` is read as ECMA-262 does, so `$` is the very end of the
value. Data files are strict JSON: a repeated key, NaN and Infinity are errors. **What a problem line may print** (schema or
cross-file, in `check`, `validate` and every read command): a value taken from the file under check only when it is an id that
exists in the data (an entry id, a role, a provider); any other value is named by its field, its JSON type and, for a string, its
length. A key name taken from the file (an unknown key, a repeated key, a key of a free-form map in a path) is printed only when
no value pattern of the connections catalog (`redaction_patterns`) matches it; else it is "a masked key" at its path. An entry
id (an assignment, a provider, a feature, a host, a setting key; a role name only when the role table holds it) is printed the
same way: "a masked id" when a value pattern matches it. A key name or id longer than 1024 characters, or any of them while
the catalog's patterns cannot be read, counts as matched; the lines about the catalog's own fault then still say where: a
pattern that does not compile names its entry by position ("entry 4 of its file"), a repeated key by position ("key 3 of its
object"), a wrong `redaction_patterns` by its path (`$.entries[3]`). File paths
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
describes the index must be `owner_only`, and `check data-files` reports everything a full `check` reports. The role table (the index's `role_table`, `.stella/schemas/roles.schema.json`) is valid only when both its schema and the validation in `bin/roles.py` pass (the rules the schema subset cannot say live there; a key that is not part of the table, of a role or of a profile row is refused by both, from the key lists in `bin/roles.py` and the property lists in the schema, which hold the same keys; a selftest keeps them equal); `check` and `validate roles <file>` run both, and `validate roles` also applies the data-class rule to a candidate file. `check <id>` prints that file's problems plus every cross-file problem and
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

**A read is judged by exactly the files its rules use.** Read commands fail closed and never serve what `check` refuses: a read
of a row depends on that row, on every row of every schema read by a rule that judges the row's schema (the list `RULES` in
`bin/stella_data.py` says which schemas each rule judges and reads; the dependencies are derived from it, never written per
command), on the role table when such a rule reads it, and on the index. It is served only when none of them has a problem
(schema or cross-file); else exit 1 and one `STL-CFG-310` line naming the first problem and the row it belongs to ("<row>, which
this read depends on: ...") and how many more, never a traceback, never an empty result and no data. A file outside that set
never refuses the read. What each read depends on today:

| read of | depends on (besides the index) |
|---|---|
| settings | settings |
| versions | versions |
| features | features |
| approved-hosts | approved-hosts |
| capabilities | capabilities, the role table |
| extensions | extensions, the role table |
| connections | connections, data-policy, the role table |
| data-policy | data-policy, connections |
| role-assignments | role-assignments, connections, data-policy, the role table |
| the index (`data-files`) | nothing else |

A read runs only the rules that read one of those files, and opens only the files those rules read (a rule that raises is a
problem of every row it read, so it runs for a read of any of them). `list` with no id and `search` serve every row, so a
problem anywhere refuses them. `get` on an env-format row says the id is known and not readable through this tool
(`STL-CFG-319`, no alert line). `get`, `list` and `search` mask the value of any key matching the row's `redact_keys` (at any depth, so a key pasted into
a free-form object such as `parameters`, `cost` or `limits` is masked), the default of a `secret` setting, and every string a
value pattern of the connections catalog (`redaction_patterns`, from every entry) matches, inside lists too; a key name the
schema does not fix (a key of a free-form object such as `parameters`, a project name, an entry id used as a key) and an entry
id in `list` and `search` are masked (`***`, then `***2`, ...) the same way. No pattern runs on a string longer than 1024
characters: it is masked whole (`MASK_LIMIT`), so a read takes bounded time per string. The two entry lists a card branch may
write are bounded by their schemas (`maxItems`: 128 capability entries, 16 version pins; data, the owner may change them), so a
read of them is bounded too; the number of files in a folder row and the size of owner-only files are not bounded. The catalog is a dependency of every
read through its patterns only: when they cannot be read (no JSON row of the connections schema, a row of it that is not
opened, a file of it that does not load, a `redaction_patterns` that is not a list of strings (null, false, 0, "" and {} included: never "no patterns"), a pattern that does not
compile; a file check refuses for another field still gives its patterns, since one more pattern never prints a value), every read that is otherwise
served masks every string, id and free-form key name instead of refusing (numbers, booleans and the key names the schema fixes
stay), so the settings read keeps its numbers and nothing unmasked is printed; `check` names what is wrong with the catalog.
`search` matches the masked text, so it never answers for a masked value. `check` refuses a `redact_keys` pattern that is not a regular
expression. The patterns are the owner's picks: a name pattern also hides a non-secret field whose name it matches (the
shipped one ends in `token`, so `usd_per_input_token` would be shown as `***`), and a value no pattern matches is shown;
change the pattern, not the code. `validate <schema> <file>` prints each problem as a `STL-CFG-310` line, for every schema;
it refuses, unread, a file that is an owner setting of the root it runs on (the identity test above), and opens no file when
that root's index cannot be read; `validate roles` finds the data policy through
the rows whose schema is `data-policy`. `validate` answers about any other JSON file the caller names, against a schema of the
stack root it runs on. A command that fails in a way not listed here ends in exit 1 and one
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
A card branch may change this file, so its text is bounded by the schema: `id` 128 characters, `summary`, `inputs`, `outputs`
and `source` 1024, each keyword and allowed role 128, each host 256, at most 64 keywords, allowed roles, hosts and secrets.

### `.stella/features.json`
`entries[]`: `id`, `owner_phase`, `status` (planned, off, preview, on), `depends_on[]`, `flag`.

### `.stella/extensions/`
One manifest per file (see its README); `enabled` is the disable switch; install needs approval, so a new manifest is
`proposed`. *To add one:* drop a `<id>.json` in the folder.

### `.stella/versions.json`
`pins[]`: `id`, `kind`, `version`, `source`, optional `integrity`, and `tested_with` (`stack_commit`, `date`, `with[]`).
A card branch may change this file, so its text is bounded by the schema: `id`, `kind`, `version`, `stack_commit` and `date`
128 characters, `source`, `integrity` and each `with` item 1024, at most 64 `with` items.

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

`stella-apply.py apply <id> --from <file> [--dry-run]`, `check [<id>] [--json]` (`--check` is accepted for `check`), `rollback <id>`,
`history <id> [--json]`.
A single-file row is addressed by its id only; a folder row by `<id>/<name>`, where the name is letters, digits, dot, dash and
underscore, starts with a letter, digit or underscore, and ends in `.json`. Exit 0 ok, 1 refused or failed (or drift), 2 usage.
Every failure is one catalog code and its plain message: 310 data unreadable, 311 unknown id, 312 owner-only, 313 a change
refused before it wrote anything (invalid candidate, a link, a path clash, a read-only folder, a restore that no longer
validates), 314 drift or a hand edit rollback would overwrite, a setting's own code (today 315) for an env candidate that breaks
the registry, 316 no, damaged or unrecorded backup, 318 event log not writable or a line not readable, 321 a change that stopped
after it had started, 322 a read command (`check`, `history`, `tail`) that could not read something, 323 an unfinished step that
`check` sees. An unexpected exception or an interrupt (Ctrl-C, SIGTERM) is exit 1 and one coded line (the exception type, never
a value). The problem text of every message fits the catalog's 200-character cut, with the way out first (the selftest walks
every message in the code and takes a key as at most 52 characters: an entry name longer than 40 is refused at apply before any
write; where a path is longer, the message takes a shorter form that still prints the command whole, never a cut command).

- **One change at a time.** One lock covers a whole apply or rollback, validation included, so the cross-file rules always judge
  a set with every earlier change in it. Once the lock is held the index, the gate and the target path are read again, so a run
  that waited acts on the state of that moment; after flock the locked file must still be the file at the lock path (else the
  run locks again, then refuses). `--dry-run` takes no lock and leaves the root as it was: no folder or file is made, changed
  or removed under it. The whole-set check stages a copy of the set in the temp folder (`TMPDIR`), outside the root, in a 0700
  folder named `stella-apply-stage-<process id>-<process start time>-<random>` with 0600 files, removed when the check ends; a
  copy a killed run left is removed by the next command of this tool (any command), once no process has that id and start time
  (a reused process id has another start time). A temp folder inside the stack root (Python's last fallback is the current
  folder) is refused with "set TMPDIR"; `check` and the read commands need no temp folder. Boxed roles have their own temp
  folder. A dry run makes the refusals an apply makes before its first write (a read-only folder, the event log), still
  changing nothing. If the masked text is unchanged but the
  bytes differ it says so in one line and names the changed keys (`-KEY (masked)` / `+KEY (masked)`). It says what an apply would
  do about an unfinished step (finish it, or record a hand edit); when an apply would be refused, the dry run prints that same
  coded refusal and exits 1.
- **One row, one real file.** The target, each folder on the way, the backup folder, the applied-state file, the event log
  and their locks must not be symbolic links and must resolve to the path the index names. No two paths of the index (rows,
  `event_log`, `backup_dir`, `applied_state`) may be one file: the same device and inode, or the same name up to upper and lower
  case (the stack's own disk is case-insensitive); a path inside a folder row's folder or inside the backup folder is another
  path's file; a file with more than one hard link, or a mount point, is not read (the message says how to find the other link
  or what to unmount). Such a problem on a row's file refuses that row only: `check` shows it as one line (322) and the other
  rows work. A problem of the index file, the event log, the backup folder or the applied state stops every command. Paths are
  compared by identity (the index's own guards too: `./.stella/data-files.json` is the index). Folder entries that differ only by case from an
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
  `check` reports it by name; it does not refuse an unrelated apply). An env candidate is read the way its file is read, which is
  data: a row whose path the role table lists under `owner_settings` is read by the stack's own parser (`owner_config.py`, which
  drops a byte-order mark and a carriage return at a line end), every other env row is sourced by a shell, so a carriage return,
  a byte-order mark or a NUL byte is refused there. Then every setting the registry stores in that data file is checked with the registry's own
  type and validation (`stella_data.setting_problems`), and a setting with no default must be present; a failure is refused with
  that registry entry's own `code`. An integer setting that is not plain decimal digits (a sign, a leading zero) is refused. Keys
  the registry does not list stay allowed. The registry is found through the index row whose schema is `settings`. A json
  document nests at most 64 levels. A problem line of another row that has a problem before and after the candidate never
  refuses it (rows are compared, not the text of their lines). **A rollback restores saved bytes the row's reader cannot parse
  as they are** (they were in use so; the apply replaced them without asking them to parse); saved bytes that parse are checked
  like a candidate (registry, whole set), and a refusal says the reason and the one way out.
- **What a row is.** Whether a row is one file or a folder of entries is the data tool's one rule, `stella_data.folder_row`
  (a json row whose path does not end in `.json` is a folder of entries; every other row is one file): not the list key, not the
  disk, not the applied record. The disk and the record are compared with it: a folder row whose folder is missing or is a file,
  a one-file row whose path is a folder, or an applied record of the other kind (the index path changed after an apply) refuses
  that row first, with the way out, and is one 310 line in `check` (the data tool refuses the same row and does not open it); a
  committed or applied entry that became a folder is drift (314). A row whose file's folder does not exist is refused before any
  write, naming the `mkdir` to run.
- **Folders the tool may not write.** Before any write the folders an apply or rollback writes in (the file's, the applied
  state's, the backups') must be writable for the user; a read-only one is refused (313) with the folder named and the two
  commands (`chmod u+w <folder>`, then back to its mode); a folder whose mode allows the write and that still cannot be written
  is read-only where it is mounted (or not this user's): the message says so, with no chmod. The tool never changes the mode of a folder or file it did not make, so
  an owner setting on the documented read-only layout (`config/` 0555, the file 0444, docs/recovery.md) is applied by lifting
  the folder's mode first and putting it back after; the file keeps its own mode through apply and rollback.
- **Backup and rollback.** Before a file is replaced its bytes, mode, previous applied record, both hashes and a random token are
  saved in `backup_dir/<key>/<counter>-<time>/` (`file`, `file.applied`, `meta.json`; folders 0700, files 0600); the applied
  state records, before the folder is made, its token and what the saved copy is (sha256, whether the file existed, its mode, the
  new sha256, the previous applied record), and rollback refuses (316) a meta file that differs from that record. A file whose
  mode has a setuid, setgid or sticky bit is refused at apply before any write, with the chmod that fixes it: one mask (0777)
  for a data file's mode in apply, meta, state and rollback. **The backup
  folder holds full copies of owner files until a rollback removes them; nothing in this tool keeps a role out of it. W4's path
  rules (read and write refusals for every role) are what does.** Backups are ordered by a counter kept in the applied state,
  never by the clock; the name carries it in eight digits, so the counter stops at 99999999 (an apply then says how to repair; a
  counter in the state beyond that is read as 0). A new file of an owner-only row or a row with `redact_keys` is created 0600; an
  existing file keeps its mode. Temp files are 0600 and the next run for that row sweeps this tool's own (`.stella-apply.*`)
  while it holds the lock.
  **Provenance.** The tool writes, in the applied state (only this tool writes it), which backup (name and token) belongs to each
  apply, before it touches the file; the same token is in the backup's meta file and in the event line's detail. Rollback
  restores or deletes only from a folder the applied state records for that key, whose meta holds that token and a well-formed
  record (every field is checked, `seq` included). What a rollback marked (its token, whether the file already held the saved
  bytes, whether the apply was logged) and which backups an adopt set aside live in the applied state; the meta file's status is
  for `history` only. A folder the state does not know (with a meta file or without), or whose token differs, is never restored
  from and never makes the tool delete or overwrite a file: `check`, `apply` and `rollback` stop with 316 and name the folder,
  and the owner removes it by hand. This is not a defence against someone who can write the applied state; that is the hooks'
  job (W4). Beyond that: the saved copy must match its recorded sha256 (else 316, never a delete), the file must hold the bytes
  the apply wrote or the bytes it replaced (anything else is a hand edit: 314, untouched), and the restored content goes
  through the same validation as a candidate (else 313: apply the content you want instead). A restored file that git does not
  track keeps the restored hash as its applied baseline, so a later hand edit is drift.
  **Unfinished and damaged folders.** A folder whose `meta.json` is missing while the file still holds the bytes it saved (a
  kill before the meta was written) is unfinished: `check` reports it (323), `apply` refuses, and `rollback` removes it, says so,
  and stops there with exit 0 (nothing is restored in that run; run it again to undo the last change). A missing meta while the
  file moved on (the change went through; the meta was removed by hand), or a meta file that is present but unreadable or wrong,
  is damage: 316, nothing deleted. A folder is removed by one rename to `.gone-<name>` first, then its content: after the rename
  the backup no longer exists for any command, and a kill leaves a `.gone-` folder the next apply or rollback sweeps.
- **Interrupted runs.** A rollback marks its backup in the applied state first, with a fresh token and what it found (whether
  the file already held the saved bytes, whether the apply was logged); a kill at any step is finished by the next `rollback`,
  which writes the lines the killed one did not, with the real old and new values (the saved copy and the bytes the apply
  wrote). The lines a rollback owes do not depend on how far a killed run got: the apply line first when the apply replaced the
  file and never logged it, then its own line when there was a logged change or the file changes; an apply that never took
  effect and never logged is removed with no line. An apply killed after the replace is finished by repeating it (the missing
  bookkeeping and event line are written); otherwise `rollback` restores the file. The event log is consulted only to resume such
  a step, and only for a token as a word: the apply's token is in the backup's meta file before its line exists (W4 keeps roles
  out of that folder), the rollback's own token is in no line before its own; a line that only names the backup cannot suppress
  the tool's line. The "nothing to restore" branch writes an event line too, saying so. A rollback that finds its own earlier
  run complete (its backup removed, only the record left) says so and stops: it does not go on to undo the change before it.
  **After the first write.** Every write of a command (the applied state, each file of the backup folder, the file, the event
  line, a meta status, a removal, each clean-up) is entered as a step BEFORE it starts, with an undo that looks at the disk (safe
  whether the write landed or not, safe twice; a write that lands and then fails is still undone). No signal is held. A failure
  or an interrupt undoes the steps newest first, up to an event line that is in the log or a removed folder (they stay) or an
  undo that fails; the saved copy is removed only while the file is proven to hold the bytes it saved. The line printed is then
  read from the disk and compared with the start (the file by hash, the backups, the applied record, the event lines): "nothing
  was changed" (in the frame or the problem) when nothing was begun and all is as before, "it was undone" when all is as before
  after the undo (318 or 314 keep their code then), else STL-CFG-321 with the one command that finishes or undoes the change
  first and what is on disk now. The first SIGINT or SIGTERM puts the run in one state, stopping: further ones change nothing,
  the run ends through the same path, never a traceback; a run waiting for a lock is ended at once, and an undo that has nothing
  to put back takes no lock. The lock files and empty folders made on the way are not counted as a change. The event line is built and judged
  (shape, schema, size) before the file is replaced, and it is synced like the state. An interrupted apply followed by a hand
  edit: `apply <id> --from <file holding the current bytes>` records them (an `adopt` line) and sets the interrupted backup
  aside. A pending apply whose saved copy does not pass the checks has one way out, printed by apply and rollback alike:
  apply a copy of the file as it is (that finishes it), then apply what you want. **The file is judged at the moment it is
  replaced:** a rollback validates the saved copy first and reads the file after, and every replace of a data file (apply,
  rollback, an undo) compares the file once more with what was judged; a difference is 314, nothing replaced, the edit kept. The
  window left is the compare and the replace being two system calls.
- **Check.** Drift is a sha256 or mode that differs from the last applied record, or (never applied) from the committed blob,
  or a row whose disk differs from what the row is (see above). An unfinished step is 323, not drift; something check cannot read
  is one 322 line naming it. A git that cannot answer (it fails, a damaged object, a repository it refuses) is not "no baseline":
  that row's line is 322 saying the committed baseline cannot be read and why, and an apply or rollback that needs it refuses
  before any write; only "the path is not in HEAD" and a root that is no git repository mean no committed baseline.
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
  of a row that has redact keys or stores a secret setting is `***` whole. `event_log.py append --detail` and every coded message
  are scrubbed of the values masked in the same call, where such a value stands whole (not inside a longer run of letters and
  digits, so a short value never garbles a folder name or a command; the apply tool's own detail holds only its own text, hashes, names and the
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
  the next apply) leaves that adopt without its line. The staging copy in the temp folder (the json rows and the candidate) can
  be read and written, while a check runs or after a kill until the next command, by an unboxed process of the same user (boxed
  roles have their own /tmp; unboxed roles write nothing); before round 4 it lived in the backup folder W4 hides. How an env row
  is read is inferred from the role table's `owner_settings` (the files the stack's own parser reads), not from a field of the row.

## The owner-only write path (item W4)

Owner settings and owner data change only through the owner's tools (`bin/settings.py`, `bin/stella-apply.py`); no role runs them, writes the files, or reads the apply tool's state. **A text guard cannot decide what a shell will do**, so this is three layers, each holding on its own for the roles it covers; the write guard is the mistake guard in front of them, and no acceptance claim rests on it alone:

1. **Roles that run in the OS box** (`sandbox.boxed_profiles`): the box is the boundary. The main checkout is mounted read-only; the owner settings, the canary and the apply tool's state (the `backup_dir`, `applied_state` and `event_log` the data index names) are not mounted at all, so a one-liner in any interpreter finds neither file nor listing.
2. **Roles that do not run in the box** (`runs_unboxed` true in the role table: the coordinator, and the fallback role of a profile with no row): their hooks refuse every write. The table says so in data and `bin/roles.py` checks it: every profile outside `boxed_profiles` has a role with `runs_unboxed` true; such a role has explicit `platform_toolsets` (the fallback: every Hermes platform, `file` and `terminal` only), on each tool of `write_tools` a hook entry marked `"writes": "refused"` (an allow-list terminal, deny-write) and none marked `"writes": "judged"` (the write guard); every such role also has a hook for any tool name no other matcher names (the catch-all: marked `"catch_all": true` in the table with the template matcher `^(?!(?:{tools})$).+$`; registration fills `{tools}` with the profile's other matchers and the role's `catch_all_tools` (the tools it may use, named in the table as data: default-deny, the repo's rule); a tool Hermes resolves for the role that `catch_all_tools` does not name stays inside the catch-all, refused, and registration and `--check` report it in one coded line so the owner adds a row; the matcher audit proves each catch-all matches none of its role's tools and does match a made-up name). A role a profile serves has explicit `platform_toolsets`. A role that is in the box but served by no profile carries every guard of `judged_hooks` (the full judged set: write guard, git guard, model guard, skill guard, secret guard; defined once, in the table), and `roles.py check` refuses a table where one of them drops one. An allow-list terminal runs `git` only in a repository it can vouch for: the toplevel found by looking for `.git` is the stack folder or the main checkout of a project bound to the board, and its `.git` is a plain folder; a repository a boxed worker left in its profile home, the box tmp folder, `/tmp` or a card worktree is never one (its config can name a program: fsmonitor, external diff, textconv, a clean filter, a pager, `core.hooksPath`, an alias, `gpg.program`). A hook timeout is Hermes's to handle (its policy is outside this repo); the stack registers every guard `fail_closed` (`register-escalation-hook.sh --check` reports an entry that lacks it), and every expansion a guard does is bounded in work (`roles.braces`, the path look-ups), so no input of any length takes a guard past a fraction of its timeout. A profile that is given a role without this must be boxed first.
3. **The merge** (`bin/merge-card.sh`): whatever reaches a card branch, however it was made (plumbing, another agent CLI's git, a patch), meets one check, and the check judges what the merge will do. `git merge-tree` computes the tree the merge would produce (every merge base, so a branch that reaches main by two routes and rolls an owner file back is seen; a main-side rename into owner data cannot carry a branch edit of the old name in), the paths that tree changes in main (`-z`, no rename detection in the compare) must hold no path a role may not write (owner data, the owner settings files and the apply tool's state paths: `roles.py owner_paths`, one list, tracked or force-added past an ignore rule), and the merge, made in the index first, must produce that same tree. If the merged tree cannot be computed the merge is refused, never guessed (STL-CFG-303); an offending path is refused with every flag (STL-CFG-312) and nothing is merged. Paths are compared with the lists **by identity, not spelling** (`roles.py hits`: the device and inode of each existing component, so an 8.3 short name, a case variant or a link is the protected folder; a name that names nothing on disk is compared by its casefolded names below the deepest folder it shares with a protected path, never by what it looks like, so a git revision such as `HEAD~1` is no protected path). Paths that define the boundary itself (`bin/roles.py boundary`: the table's `boundary_paths` list, which holds every file the boundary's own code loads, the data files it opens by a fixed path included (the alert catalog and its code page, the board text, the SOUL rules), and a selftest recomputes from the import and source graph and from the paths named on the code lines of those files so it cannot rot, every hook file or command of the table, and a new file in a code folder named like a standard-library module that a hook imports) are listed and refused unless the owner passes `--i-have-read-the-boundary-changes`. **The card's test command runs in the OS box** (`bin/box.py exec`), in a throw-away worktree of the branch tip that the merge makes itself and removes after (never the card's own worktree, whose `.git` file and git dir entry a worker can rewrite; a repository whose worktrees read a config of their own, `extensions.worktreeConfig`, gets no box and no merge): that worktree writable, the rest read-only, the owner settings and state paths not mounted, the worker markers set; where the box cannot start the merge is refused with a coded line and the tests do not run outside it (there is no flag for that); with `--push` the merged main's tests run in the box too. What the box does not stop here: the test code still decides its own exit code (the review reads the diff), and it reads whatever the box shows read-only.

**Owner data** is one definition (`bin/roles.py owner_paths`, `roles.py owner-data`): the data index itself, every path of an index row with `owner_only: true` (so a new owner-only row is protected with no other edit; `.supervisor/limits.env` is owner data through its row), the role table's own `owner_data` list (what the index cannot name: the schemas folder) and `owner_settings`. Rows that are not owner-only (the capability registry, the versions file) and `.stella/test-map.json` stay writable on a card branch. The write guard, the commit guard (`-z --no-renames`: a non-ASCII name, a rename out of an owner folder and a deletion count) and the merge check all use it; an index that cannot be read makes every guard refuse, the write guard included.

**What the write guard reads.** Commands are split at unquoted newlines; every redirect operator (`>`, `>>`, `>|`, `&>`, `&>>`, `>&word`, `<>`) is judged; every word it judges (a redirect target, an argument of a write verb, a git path, the command word, each argument of an interpreter) is expanded first (`$'..'`, quotes, braces, `~`, variables it can know, globs; the code `roles.expand_word`/`ansi`/`braces` is shared with the read guard) and compared as a real path without regard to case. Owner commands (`owner_commands`, including `bin/event_log.py`) are matched by the file a word resolves to (the stack's own file or its copy in a card worktree of the stack, since a copy runs on whatever tree `STELLA_ROOT` names), not by a name in the text; a wrapper's other words (`env -u NAME`, `timeout 5`, `sudo -u`) count too; `owner_commands_by_name` (the merge command) is also refused by its name anywhere in a command. A judged word that still holds an expansion only the shell can compute (an unknown variable, `$(..)`), `xargs` or `find -exec` feeding an interpreter, and `git --pathspec-from-file`, `--git-dir`, `--work-tree` are refused. git commands that write (git's own classes: `GIT_WRITERS`) are judged like any write: every named path against the protected set and owner data, and the tree they run in must be the caller's card worktree; inside the worktree a tree-wide form (`.`, `:/`) is allowed. Any exception in the guard is a refusal with a coded line.
**The rule is turned around for the paths a role may not write** (owner data, the owner settings, the apply tool's state): a command that *names* one, as a word, inside interpreter code or a quoted command line, inside a here-document body, or as a folder that holds one, runs only when its verb is a known reader (the table's `read_verbs`: `cat`, `grep`, `jq`, `diff`, `git show|diff|log` ...; a reader that writes by an option, `git diff --output`, `find -fprint`, is not one). An unknown writer (`sort -o`, `perl -pi`, `touch`, `gzip`, `curl -o`, `tar -C`, `cp x <folder>/`) needs no list entry to be refused. Here-document bodies are judged by the text checks (an owner command by name, the worker markers) and by this rule; the tree-wide form in the card's own worktree (`.`, `:/`) is not a naming. The names are compared by identity (`roles.overlap`), in the main checkout and in every card worktree of the stack.

**What it cannot see**, and the layer that covers it (each limit complete as of this round): (a) a path the shell builds at run time, an unknown variable or `$(..)`, in a command whose verb is not a reader and not a write verb the guard lists: the box (layer 1) and the merge (layer 3); the allow-list roles refuse such a word outright (layer 2); (b) an interpreter that loads its code from a file the guard does not name, by import, `-m` or stdin from a pipe: the box and the merge; (c) code run inside another agent CLI and that CLI's own git and file tools: the box and the merge; (d) a name that is the same path only on the other side of a mount or a bind the hook does not see: the box mounts none of the protected paths; (e) the contents of a file the command reads and then writes through a reader pipeline (`cat owner-file | tee other`): `tee` is a write verb, its target is judged; the content of owner data is readable by every role by design, and the commit guard and the merge stop it reaching a branch; (f) the git routes the guard does not classify (plumbing built in a script, a patch applied from stdin): the commit guard and the merge; (g) a hook that times out or crashes: Hermes's policy, outside this repo (the stack registers every guard `fail_closed` and bounds the work of every expansion). The tools' own owner gate proves an owner by the absence of a worker proof (`roles.py prove`); no positive proof of the caller exists in F1 (an owner decision), so layers 1 and 2 keep roles away from the tools. (h) round 5: the selftest that keeps the boundary list complete (K3) does not see a file loaded by `importlib.import_module`, `__import__`, or a subprocess whose path is joined at run time; a reviewer of a boundary change reads for those. (i) K5: a command that names thousands of paths is refused at the guard's deadline, not judged (measured on 8e878d1 by the tester: 3.3 s for the write guard, 4.2 s for the read guards with 3000 paths; the hook timeouts are 10 to 20 s). (j) the table memo of one process (`roles.load`) is keyed on the file's device, inode, size, modification time and change time (putting an old modification time back changes the change time, so that edit is seen too); a table read anew drops the hook-file lookups the process kept; nothing is cached on disk. (k) the once-per-call alert marker keys on Hermes's `extra.tool_call_id`; a payload without one is keyed on its bytes and the parent process for 2 s, so a retry of the same payload sooner than that writes no second line.

A refusal on the owner boundary (an owner-data write, an owner command, a read or write of an owner state path, the merge and commit-guard refusals) prints `STL-CFG-312` and the catalog's plain message and writes one alert line (the catalog's page policy decides paging), with no value from any owner file; a guard that cannot read the role table or the data index prints `STL-CFG-303` the same way. Where two hooks of one role refuse the same call (a read guard and the allow-list terminal), one alert line is written in total: the first to refuse makes a marker (the code, the call's payload and the parent process) in the alert folder, the other prints the same message and writes nothing. The alert line names the role and, where the hook knows it, the card; worker-written text (a branch name) is cleaned before it is written. An older rule that catches a call first (a mention of the owner settings file) still says so with the code. Every refusal by a role's own rules (round 5, W4-VER3-04/W4-VAL3-03): the coordinator's writes and the unknown-tool and unlisted catch-alls, the git and model guards, a builder's write outside its worktree or push to main, a reviewer's write, a read of a secret path — carries `STL-GRD-604` and one alert line naming the role (and the card the write guard proved); nothing reads their old sentence. Roles do not read the event log in F1 (it holds old and new values of owner settings in clear); this may change later.

The canonical env writer refuses a value that holds both a single quote and any of `$`, a backtick, a backslash or a double quote (the strict parser has no escapes, so it could not be read back as itself); the settings tool also refuses a store file that holds a key twice (STL-CFG-313) before it compares or writes anything.

## Alert codes
`STL-CFG-310` (a data file is invalid), `STL-CFG-311` (a name is not in the data) and `STL-CFG-319` (an env-format row is
not readable through this tool) are used by `stella_data.py`.
`STL-CFG-312` to `318` and `321` to `323` are used by the apply and event-log tools (see above).

## How the suite runs (decided by the owner 2026-11-12)
Two tiers. The full suite (`npm test`, `bin/selftests.sh`) runs at merge and on the final hash. The quick tier (`npm run test:quick`, `bin/selftests.sh --quick`) is what the 15-minute watchdog runs; its list is the `quick` key of `.stella/test-map.json` (data: `bin/test-map.py quick` prints it, `check` refuses a name outside the suite list). Either way each selftest runs isolated in its own copy of the tree and a bubblewrap mount namespace (own tree, alert log and temp folder), at most `test_rerun.parallel` at once (watchdog settings); a selftest whose file holds the line `# selftest: serial` runs alone after the batch. Inside a box that forbids nested namespaces the suite fails, by design. Output is in list order; `SELFTESTS_TIMES=<file>` records the seconds per selftest.
