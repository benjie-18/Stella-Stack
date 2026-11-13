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
   It scans only the files git tracks (a walk of the root where there is no git).
   The lint does not scan the instruction documents at the top of the repository (the `*.md` skip row of
   `docs/hermes-local/hardcode-allow.json`): decided by the owner on 2026-11-12, as data the owner may change.
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
write are bounded by their schemas (`maxItems`: 128 capability entries, 32 version pins: set by the owner on 2026-11-12, the shipped files hold 9 and 10; data, the owner may change them), so a
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
a value). The problem text of a message fits the catalog's 200-character cut, with the way out first, for an id and a name of
ordinary length (the selftest walks every message in the code and takes a key as 52 characters; where a cause is longer, the
message takes a shorter form through the one fitting function). **Names have no limit of this tool's** (the owner's decision of
2026-11-12): an entry name or a folder path may be as long as the file system allows and works end to end; a name the file
system refuses (a component or a path too long, asked of the file system itself) is refused before anything is written, with
one coded line. No printed path or command is ever cut by this tool: when a name makes a problem text longer than the catalog's
cut, the coded line is followed by one more line, `whole text: ` and the whole text (on stderr; after the row's line in
`check`, and as `problem` in `check --json`). The alert log line keeps the catalog's cut. The row's lock file is named by the
key, or by the key's hash when that name would be longer than a file name may be.

- **One change at a time.** An apply or a rollback holds one lock (the apply lock for every id, the row's own lock file, and the
  lock of the applied state) from before its first read of the row until its one line is printed and flushed: validation, every
  step, and on a failure every undo, the disk read that makes the failure line and the line itself all happen inside it, so the
  cross-file rules always judge a set with every earlier change in it and a second run of the same row or of another row waits
  until the first has printed. The applied state is read and written only inside that lock (nothing is decided from an earlier
  read), and an undo takes no lock, so it never waits. A lock that was taken is released on every path, also when an interrupt
  lands right after it is taken. The lock folder, the lock files and the applied state's folder are made before the first step
  and stay: a refused or undone command leaves them (they are not counted as a change). Once the lock is held the index, the
  gate and the target path are read again, so a run that waited acts on the state of that moment; after flock the locked file
  must still be the file at the lock path (else the run locks again, then refuses). `--dry-run` takes no lock and leaves the root as it was: no folder or file is made, changed
  or removed under it. The whole-set check stages a copy of the set in the temp folder (`TMPDIR`), outside the root, in a 0700
  folder named `stella-apply-stage-<process id>-<process start time>-<random>` with 0600 files, removed when the check ends; a
  copy a killed run left is removed by the next command of this tool (any command), once no process has that id and start time
  (a reused process id has another start time). A temp folder inside the stack root (Python's last fallback is the current
  folder) is refused with "set TMPDIR"; `check` and the read commands need no temp folder. Boxed roles have their own temp
  folder. A dry run makes the refusals an apply makes before its first write (a read-only folder, the event log, a committed
  baseline that cannot be read, a setuid, setgid or sticky mode, a full counter), still changing nothing. **What is written
  under the root all the same:** every coded failure and every `check` finding appends one line to the alert log
  (`.supervisor/logs/alerts.log` under the root, or under `ESCALATE_SUP_DIR` when that is set, as in every test), also for a
  dry run or a `check`; that write is the alert catalog's, not a step of this tool. If the masked text is unchanged but the
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
  document nests at most 64 levels. **A candidate may not add a problem to the set.** Each problem line of the data tool's
  whole-set check is judged, never a whole row: a line (row and text) that was not there before the change refuses, in any row;
  a line of the candidate's own row refuses also when it was there before. So one old problem of a row never hides a new one
  there. The price is a false refusal: three line shapes of the data tool name or count what blocks them, and a line that only
  reworded itself counts as new; the message then names the other row, says the set already had a problem there and gives the
  way out (fix that row first, then run the command again). The same rule judges the saved copy a rollback restores and a dry
  run. **A rollback restores saved bytes the row's reader cannot parse as they are** (they were in use so; the apply replaced
  them without asking them to parse); saved bytes that parse are checked like a candidate (registry, whole set), and a refusal
  says the reason and the one way out.
- **What a row is.** Whether a row is one file or a folder of entries is the data tool's one rule, `stella_data.folder_row`
  (a json row whose path does not end in `.json` is a folder of entries; every other row is one file): not the list key, not the
  disk, not the applied record. The disk and the record are compared with it: a folder row whose folder is missing or is a file,
  a one-file row whose path is a folder, or an applied record of the other kind (the index path changed after an apply) refuses
  that row first, with the way out, and is one 310 line in `check` (the data tool refuses the same row and does not open it); a
  committed or applied entry that became a folder is drift (314). A row whose file's folder does not exist is refused before any
  write, naming the `mkdir` to run, and is one 310 line in `check` with the same `mkdir`.
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
  existing file keeps its mode. Temp files are 0600 and the next apply or rollback of that row sweeps this tool's own while it
  holds the lock, by their one shape (`.stella-apply.` and 16 hex digits; a set-aside folder is `.gone-` and a backup's own
  name, directly in the key's backup folder): a file or folder that only starts like one is the owner's and is left.
  **Provenance.** The tool writes, in the applied state (only this tool writes it), which backup (name and token) belongs to each
  apply, before it touches the file; the same token is in the backup's meta file and in the event line's detail. Rollback
  restores or deletes only from a folder the applied state records for that key, whose meta holds that token and a well-formed
  record (every field is checked, `seq` included). **The state of a backup is computed from its record in the applied state
  alone:** set aside (an adopt marked it), rollback-pending (a rollback marked it, with its token, whether the file already held
  the saved bytes, whether the apply was logged), done (written there as a step of its own, after the apply's event line), else
  pending; a record without a word is pending. The status word in the meta file is a copy for someone who reads the folder: no
  command reads it, `history` prints the applied state's word, and a meta rewritten to any status changes no answer of `check`,
  `apply`, `rollback` or an adopt. A record of an older form (a bare token, or a token without what the saved copy is) is
  refused with 310: no applied state of that form exists, because this phase was never merged before. A folder the state does
  not know (with a meta file or without), or whose token differs, is never restored
  from and never makes the tool delete or overwrite a file: `check`, `apply` and `rollback` stop with 316, give the folder's
  path and say that it may be the tool's own saved copy when the applied state was lost or put back from an older copy;
  the owner looks at it and removes it by hand. This is not a defence against someone who can write the applied state; that is the hooks'
  job (W4). Beyond that: the saved copy must match its recorded sha256 (else 316, never a delete), the file must hold the bytes
  the apply wrote or the bytes it replaced (anything else is a hand edit: 314, untouched), and restored content that parses goes
  through the same validation as a candidate (else 313: apply the content you want instead; content the reader cannot parse is
  restored as it is, see Validation). A restored file that git does not
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
  bookkeeping and event line are written); otherwise `rollback` restores the file. **When the event log is read.** That an
  apply's line is written is a fact of the applied state (`done`, written after the line). The log is read: for its lines about
  the key, at the start of every apply and rollback and once more when one fails (the failure line says whether an event line
  was written); for one line, by the finish of a killed apply or adopt, by a rollback of a backup that is not marked done or
  that resumes a marked one, and by the undo of an event-line step (did its write land?). A line counts only in the tool's own
  shape, `backup <name> token <token>` (`token <token>` for an adopt), not for a token as a loose word: the apply's token is in
  the backup's meta file before its line exists (W4 keeps roles out of that folder), the rollback's own token is in no line
  before its own; a line that only names the backup, or only carries the token, cannot suppress the tool's line. The "nothing to restore" branch writes an event line too, saying so. A rollback that finds its own earlier
  run complete (its backup removed, only the record left) says so and stops: it does not go on to undo the change before it.
  **After the first write.** Every write of a command (the applied state, each file of the backup folder, the file, the event
  line, a meta status, a removal, each clean-up) is entered as a step BEFORE it starts, with an undo that looks at the disk (safe
  whether the write landed or not, safe twice; a write that lands and then fails is still undone). No signal is held. A failure
  or an interrupt undoes the steps newest first, inside the lock, up to an event line that is in the log or a removed folder
  (they stay) or an undo that fails. **The undo of a replace asks one question: does the file hold the bytes this run wrote?**
  Yes: the bytes it replaced are put back (asked once more at that rename). No is never a failure of the undo: when this run
  never replaced the file (its compare refused, or the rename never landed) the undo goes on, everything the run entered is
  undone, the saved copy included, and the line is 314 with the edit kept; when it did replace the file and someone wrote over
  that, the undo stops there, the saved copy and its record are kept, and the line is 321. The saved copy is removed unless the
  file holds the bytes this run wrote. The line printed is made inside the lock: with no step begun it is the cause, and it or
  its frame says nothing was changed (the disk is not read for it); else the disk is read and compared with the start (the
  file by hash and mode, the backups with their state, the applied record, the event lines of the key): "it was undone" when
  all is as before after the undo (318 or 314 keep their code then; after a hand edit the line says that the file holds the
  edit and the rest was undone), else STL-CFG-321 with what is on disk now. **One source for the way out:** the command a 321
  line names is taken from the same function that makes `check`'s line for the key as the disk is then, so it is the command
  `check` names; with nothing unfinished it says that there is nothing to run. A log file that the first event line of a root
  creates and cannot finish is removed again, so "event log as before" is true there too. The first SIGINT or SIGTERM puts the
  run in one state, stopping: further ones change nothing, the run ends through the same path, never a traceback, also when the
  signal lands between the catch of a failure and its handling; a run waiting for a lock is ended at once (the locks of the
  command are taken before its first step, the undo takes none). Once a command's line of success is printed an interrupt
  changes nothing, and a line that cannot be printed (a closed pipe) does not turn the finished change into a failure exit.
  The lock files and empty folders made on the way are not counted as a change. The event line is built and judged
  (shape, schema, size) before the file is replaced, and it is synced like the state. An interrupted apply followed by a hand
  edit: `apply <id> --from <file holding the current bytes>` records them (an `adopt` line) and sets the interrupted backup
  aside. A pending apply whose saved copy does not pass the checks has one way out, printed by apply and rollback alike:
  apply a copy of the file as it is (that finishes it), then apply what you want. **The file is read at one point and judged at the
  moment it is replaced:** an apply and a rollback validate first (the candidate, the saved copy) and then read the file and
  take the state a failure is compared with, at one point; the file is compared with those bytes once before the first step
  and again in the replace itself, after the temp file is written, synced and closed and right before the rename. A difference
  is 314, nothing replaced, the edit kept, everything the command began undone, and the line names the way out first (record
  the edit by applying a copy of the file as it is, or revert it). **The window left**, in system calls: the compare opens the
  file, reads it and closes it, then the one `rename` follows; an edit saved after that open and before the rename is replaced
  and lost. No write, sync or mode change of this tool lies in that window. **The mode:** a mode change alone is not a hand
  edit for that compare (bytes only); `check` reports a changed mode of an applied file as drift, an apply keeps the mode the
  file has when it is read, and a rollback puts back the mode the backup saved. Whether a changed mode should refuse like an
  edit is the owner's decision.
- **Check.** Drift is a sha256 or mode that differs from the last applied record, or (never applied) from the committed blob,
  or a row whose disk differs from what the row is (see above). An unfinished step is 323, not drift; something check cannot read
  is one 322 line naming it. **"No committed baseline" is said only for a proven fact:** the root has no `.git` entry at all
  (the tool's own lstat); or the repository has no commit yet (HEAD is a symbolic ref, git exit 0, that resolves to nothing,
  git exit 1 exactly: nothing can have been committed, so nothing was edited away from a commit); or HEAD resolves to a commit
  object and git lists the path with exit 0 and no entry. Git's exit status decides, never its wording (its locale is pinned
  all the same). Every other answer (git cannot be run, any other exit status, a `.git` git cannot use such as a worktree
  link whose folder is gone, an empty HEAD or an unreadable folder, a missing object) is a refusal: that row's line in `check`
  is 322 and says to run `git status` in the stack root, with the exit status; a dry run, an apply (every apply of a row that
  was never applied asks for the baseline) and a rollback that needs it refuse the same way before any write.
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
  for a private row (owner-only alone does not suppress it). A new file's event has `old: null`: null on a side means there was
  no file; a side whose file exists and does not parse is `{"unparsed": true}` and the detail says so. `append --code` must be in the
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
3. **The merge** (`bin/merge-card.sh`): whatever reaches a card branch, however it was made (plumbing, another agent CLI's git, a patch), meets one check, and the check judges what the merge will do. `git merge-tree` computes the tree the merge would produce (every merge base, so a branch that reaches main by two routes and rolls an owner file back is seen; a main-side rename into owner data cannot carry a branch edit of the old name in), the paths that tree changes in main (`-z`, no rename detection in the compare) must hold no path a role may not write (owner data, the owner settings files and the apply tool's state paths: `roles.py owner_paths`, one list, tracked or force-added past an ignore rule), and the merge, made in the index first, must produce that same tree. If the merged tree cannot be computed the merge is refused, never guessed (STL-CFG-303); an offending path is refused with every flag (STL-CFG-312) and nothing is merged. Paths are compared with the lists **by identity, not spelling** (`roles.py hits`: the device and inode of each existing component, so an 8.3 short name, a case variant or a link is the protected folder; a name that names nothing on disk is compared by its casefolded names below the deepest folder it shares with a protected path, never by what it looks like, so a git revision such as `HEAD~1` is no protected path). Paths that define the boundary itself (`bin/roles.py boundary`: the table's `boundary_paths` list, which holds every file the boundary's own code loads, the data files it opens by a fixed path included (the alert catalog and its code page, the board text, the SOUL rules), and a selftest recomputes from the import and source graph and from the paths named on the code lines of those files so it cannot rot, every hook file or command of the table, and, in a folder the boundary's python imports from (`bin/` is one), every folder, any name without a suffix (a link to a package folder elsewhere is loaded as a package) and every file python loads (`.py`, `.pyc`, `.so`) whatever its name, since a module looked up late is on no list (round 10), plus any other file named like a module the boundary imports) are listed and refused unless the owner passes `--i-have-read-the-boundary-changes`. **The card's test command runs in the OS box** (`bin/box.py exec`), in a throw-away worktree of the branch tip that the merge makes itself and removes after (never the card's own worktree, whose `.git` file and git dir entry a worker can rewrite; a repository whose worktrees read a config of their own, `extensions.worktreeConfig`, gets no box and no merge): that worktree writable, the rest read-only, the owner settings and state paths not mounted, the worker markers set; where the box cannot start the merge is refused with a coded line and the tests do not run outside it (there is no flag for that); with `--push` the merged main's tests run in the box too. What the box does not stop here: the test code still decides its own exit code (the review reads the diff), and it reads whatever the box shows read-only.

**Owner data** is one definition (`bin/roles.py owner_paths`, `roles.py owner-data`): the data index itself, every path of an index row with `owner_only: true` (so a new owner-only row is protected with no other edit; `.supervisor/limits.env` is owner data through its row), the role table's own `owner_data` list (what the index cannot name: the schemas folder) and `owner_settings`. Rows that are not owner-only (the capability registry, the versions file) stay writable on a card branch; `.stella/test-map.json` is writable too but is a boundary path since round 6 (it selects a stack card's merge test), so a card that changes it merges only with the owner's flag. The write guard, the commit guard (`-z --no-renames`: a non-ASCII name, a rename out of an owner folder and a deletion count) and the merge check all use it; an index that cannot be read makes every guard refuse, the write guard included.

**What the write guard reads.** Commands are split at unquoted newlines; every redirect operator (`>`, `>>`, `>|`, `&>`, `&>>`, `>&word`, `<>`) is judged; every word it judges (a redirect target, an argument of a write verb, a git path, the command word, each argument of an interpreter) is expanded first (`$'..'`, quotes, braces, `~`, variables it can know, globs; the code `roles.expand_word`/`ansi`/`braces` is shared with the read guard) and compared as a real path without regard to case. Owner commands (`owner_commands`, including `bin/event_log.py`) are matched by the file a word resolves to (the stack's own file or its copy in a card worktree of the stack, since a copy runs on whatever tree `STELLA_ROOT` names), not by a name in the text; a wrapper's other words (`env -u NAME`, `timeout 5`, `sudo -u`) count too; `owner_commands_by_name` (the merge command) is also refused by its name anywhere in a command. A judged word that still holds an expansion only the shell can compute (an unknown variable, `$(..)`), `xargs` or `find -exec` feeding an interpreter, and `git --pathspec-from-file`, `--git-dir`, `--work-tree` are refused. git commands that write (git's own classes: `GIT_WRITERS`) are judged like any write: every named path against the protected set and owner data, and the tree they run in must be the caller's card worktree; inside the worktree a tree-wide form (`.`, `:/`) is allowed. Any exception in the guard is a refusal with a coded line.
**The rule is turned around for the paths a role may not write** (owner data, the owner settings, the apply tool's state): a command that *names* one, as a word, inside interpreter code or a quoted command line, inside a here-document body, or as a folder that holds one, runs only when its verb is a known reader (the table's `read_verbs`: `cat`, `grep`, `jq`, `diff`, `git show|diff|log` ...; a reader that writes by an option, `git diff --output`, `find -fprint`, is not one). An unknown writer (`sort -o`, `perl -pi`, `touch`, `gzip`, `curl -o`, `tar -C`, `cp x <folder>/`) needs no list entry to be refused. Here-document bodies are judged by the text checks (an owner command by name, the worker markers) and by this rule; the tree-wide form in the card's own worktree (`.`, `:/`) is not a naming. The names are compared by identity (`roles.overlap`), in the main checkout and in every card worktree of the stack.

**What it cannot see**, and the layer that covers it (each limit complete as of this round): (a) a path the shell builds at run time, an unknown variable or `$(..)`, in a command whose verb is not a reader and not a write verb the guard lists: the box (layer 1) and the merge (layer 3); the allow-list roles refuse such a word outright (layer 2); (b) an interpreter that loads its code from a file the guard does not name, by import, `-m` or stdin from a pipe: the box and the merge; (c) code run inside another agent CLI and that CLI's own git and file tools: the box and the merge; (d) a name that is the same path only on the other side of a mount or a bind the hook does not see: the box mounts none of the protected paths; (e) the contents of a file the command reads and then writes through a reader pipeline (`cat owner-file | tee other`): `tee` is a write verb, its target is judged; the content of owner data is readable by every role by design, and the commit guard and the merge stop it reaching a branch; (f) the git routes the guard does not classify (plumbing built in a script, a patch applied from stdin): the commit guard and the merge; (g) a hook that times out or crashes: Hermes's policy, outside this repo (the stack registers every guard `fail_closed` and bounds the work of every expansion). The tools' own owner gate proves an owner by the absence of a worker proof (`roles.py prove`); no positive proof of the caller exists in F1 (an owner decision), so layers 1 and 2 keep roles away from the tools. (h) round 5: the selftest that keeps the boundary list complete (K3) does not see a file loaded by `importlib.import_module`, `__import__`, or a subprocess whose path is joined at run time; a reviewer of a boundary change reads for those. (i) K5: a command that names thousands of paths is refused at the guard's deadline, not judged (measured on 8e878d1 by the tester: 3.3 s for the write guard, 4.2 s for the read guards with 3000 paths; the hook timeouts are 10 to 20 s). (j) the table memo of one process (`roles.load`) is keyed on the file's device, inode, size, modification time and change time (putting an old modification time back changes the change time, so that edit is seen too); a table read anew drops the hook-file lookups the process kept; nothing is cached on disk. (k) the once-per-call alert marker keys on Hermes's `extra.tool_call_id`; a payload without one is keyed on its bytes and the parent process for 2 s, so a retry of the same payload sooner than that writes no second line.

A refusal on the owner boundary (an owner-data write, an owner command, a read or write of an owner state path, the merge and commit-guard refusals) prints `STL-CFG-312` and the catalog's plain message and writes one alert line (the catalog's page policy decides paging), with no value from any owner file; a guard that cannot read the role table or the data index prints `STL-CFG-303` the same way. Where two hooks of one role refuse the same call (a read guard and the allow-list terminal), one alert line is written in total: the first to refuse makes a marker (the code, the call's payload and the parent process) in the alert folder, the other prints the same message and writes nothing. The alert line names the role and, where the hook knows it, the card; worker-written text (a branch name) is cleaned before it is written. An older rule that catches a call first (a mention of the owner settings file) still says so with the code. Every refusal by a role's own rules (round 5, W4-VER3-04/W4-VAL3-03): the coordinator's writes and the unknown-tool and unlisted catch-alls, the git and model guards, a builder's write outside its worktree or push to main, a reviewer's write, a read of a secret path — carries `STL-GRD-604` and one alert line naming the role (and the card the write guard proved); nothing reads their old sentence. Roles do not read the event log in F1 (it holds old and new values of owner settings in clear); this may change later.

The canonical env writer refuses a value that holds both a single quote and any of `$`, a backtick, a backslash or a double quote (the strict parser has no escapes, so it could not be read back as itself); the settings tool also refuses a store file that holds a key twice (STL-CFG-313) before it compares or writes anything.

**Round 6 (2026-11-12).**
- *Owner decision 4 of 2026-11-12 (W4-CV3-02, stack cards), decided by the owner:* a stack card may merge with a reduced test set: the test map's selected selftests for the card's diff plus the quick tier, run boxed. The full suite still runs on the final hash. As built: a card is a stack card when the repository merged is the tree `bin/merge-card.sh` lies in (no name in code); the diff is the card's against the merge base; `bin/test-map.py select` and `quick`, the map and the runner `bin/selftests.sh` are read from and run in the tree under test (the throw-away worktree of the branch tip, never the main checkout's files), inside the merge's box. `full` from select, a map tool that fails or an empty answer runs the whole suite; a quick list that cannot be read, or a runner that cannot isolate a selftest, fails the tests. A card that changes the map, the map tool, the runner or `package.json` is a boundary change (the owner's flag). The boundary list is applied by name to a project repository too, so a project card that edits its own `package.json` needs the boundary flag (stricter by design; the owner may change it). The runner makes a namespace per selftest, so the box of a stack card's merge test, and only that box, starts without the no-nested-namespaces switch; every mount and hidden path is as in any box, and worker boxes and a project card's merge box are unchanged. What that costs: test code of a stack card can make user and mount namespaces of its own inside its box (by the kernel's rule a mount inherited from the outer namespace stays locked there, so a hidden path stays hidden and a read-only one read-only; that rule is relied on; the round-6 C4 case of `bin/merge-card-selftest.sh` shows it for the read-only main checkout, the hidden owner settings path and a broker file, from code that makes its own user and mount namespace in that box and tries to unmount and remount every mount it sees), which is more kernel surface than a worker's box offers.
- *Owner decision 5 of 2026-11-12 (W4-VAL3-04, ignored files), decided by the owner:* the merge test running without the card's ignored files is acceptable. The throw-away test tree holds the tracked files of the branch tip only; a project whose test command needs ignored files (installed packages, a build folder) must make them in its test command. No code change.
- A box fault is told from a test failure by something the test cannot produce. `bin/box.py exec` states its verdict as one line (`ran <exit code>`) on a descriptor the box never holds, the box's start is a line on a pipe that is closed before the test is started, and a box ended by a signal is told on a pipe only the launcher holds. An exit code, a line on the test's own output or a file in the worktree's git folder decides nothing: every exit code of a test (also 70, 124 from the time limit, 125, 126, 128+n after a signal) is "tests failed" with that code. Each of these refusals has its own catalog row and one alert line: the tests could not be run in their box (STL-GRD-605: the box could not start or was ended, the throw-away worktree could not be made), the tests did not pass (STL-GRD-606; for a stack card also a quick list that cannot be read and a runner that cannot isolate, which end the run as a failure inside the box), and a main checkout that is not clean or holds an untracked file the merge would replace (STL-GRD-607).
- The shell hooks follow the fail-closed rule of every guard: with a role table that cannot be read or is invalid (a hook file it names is missing), each of them refuses every call with STL-CFG-303, from one place (`bin/roles.py` `hook_refusal` and `hook-allow`); the two reviewer terminals ask before they allow, which costs each allowed call one start of the role tool.
- A copy of an owner command is judged wherever a command line names it, by its bytes: as a bare name (the working folder, PATH), an interpreter's script, an argument of a wrapper or of xargs, a name inside quoted code, a function or alias body, a `python -m` name. Only a known reader or `rm` may name a copy, and then nothing later in that line runs an interpreter. A command line that names an owner command (its path as text, or a word that is one) may not also run an interpreter, feed xargs or run a file that does not exist yet, so a copy made and run in one line (`cat`, `dd`, `sed -n p` with a redirect, `git show <rev>:<path>`) is refused when it is run through an interpreter, through xargs or by a path with a slash. Not seen by this guard (round 7, W4-CV4-04; no rule change): a copy made and run in one line under a bare name, found through PATH or after `hash`; every role that carries this guard is boxed, and there the box and the file modes hold. Made in one call and run in the next it is refused by its bytes. The cost: a line that stages or reads an owner command and runs anything through an interpreter is refused too (for example `git add bin/settings.py && bash bin/settings-selftest.sh`), because a file that exists now can still be overwritten earlier in the same line; the way out is two calls (the first names the owner command, the second runs the selftest). No line of the everyday lists is of that shape. What does not hold at this guard, and is held by the box and the file modes instead: a copy with one byte changed is no longer the owner command and is not known; a name built at run time; a file changed between the guard's look and the run. In the box the main checkout is read-only and the apply tool's state is not mounted, so a changed copy of `bin/event_log.py` cannot reach the stack's event log.
- The merge refusal for a path the main checkout holds untracked names the path and the untracked folder above it. After the merge commit the committed tree is compared with the checked tree once more and a difference is said loudly (exit 1, not pushed): `--no-verify` skips the pre-commit and commit-msg hooks, the prepare-commit-msg and post-commit hooks of the owner's repository still run.
- In a long-lived reader of the role table (the box plugin) the hook-file proof is made anew after one second; a hook process never lives that long.
- What the read guards refuse besides a named secret, owner or state path: a jq command that can load a module at all (its program text, also from a program file, names `import`, `include` or `modulemeta`; a library path option in any spelling; a `JQ_` variable), because jq resolves a module name against its search folders (`../` included) and the file it opens is no word of the command; no everyday call uses jq's module system, and a filter that only needs the word (`select(.kind == "include")`) is written with `test("inclu" + "de")` or run by a worker. What that costs (round 7, W4-VER4-07): the rule reads the words of the jq command, so a filter that only holds one of the three words and a FILE NAME that holds one (`jq . include.json`) are both refused; the way out for the file is a pipe (`cat include.json | jq .`). With a program file (`-f`, `--from-file`) the guard must read the program: a word that is a standard-stream name (`/dev/stdin`, `/dev/fd/0`), holds a glob, a brace or `$`, or names something that is no regular file counts as a program that imports and is refused (round 7, W4-CV4-02). Since round 8 (W4-CV5-03; W4-VER6-01) the guard reads every word of such a command that names a regular file, so with a program-file option a regular file over 1 MiB, a data file too, is refused (the way out: pipe the large data file in, `cat big.json | jq -f prog.jq`), as is a word that starts with a tilde not followed by a slash; a word with `=` is looked up whole and after the `=`. A short option with its value attached (`grep -f/<path>`) is judged as that path (W4-CV4-09). `--files0-from` in any prefix spelling is refused for every command (the names come from a file or a pipe). What that costs (round 7, W4-CV4-06; no rule change): the guard does not know which tools have that option, so every long option that is a prefix of it (`--f`, `--fi`, `--file`, `--files`, with or without `=value`) is refused for every command and every role that carries a read guard, boxed builders included: `rg --files`, `tar --file=x`, `sed --file=x`, `git commit --file=m`, `grep --file=p`. The refusal says so and names the way out: a form that is not a prefix (`rg --files-with-matches`, the short `-f` or `-F`); `rg --files` itself has no other spelling, a file list comes from `git ls-files` or `find`. Limit: a file name built at run time and fed by xargs (`echo -e '<escaped name>' | xargs cat`) is not seen by the secret guard; what holds there is the box (it does not mount those paths) and, for the unboxed coordinator, the read-only terminal, which refuses xargs.

**Round 7 (2026-11-13), as built.**
- The merge answers a card that changes an owner or state path with STL-CFG-312 before it looks at untracked files (STL-GRD-607), so such a card never reads as a checkout that is not ready. STL-GRD-607 also refuses a card that turns a tracked folder of main into a file or a link while a file below it is not tracked (git would remove it with the folder), and a merge that did not produce the checked tree (it is undone). The files a 607 names are the main checkout's own local files: the card goes back or the owner moves them aside; an ignored file is never added to the repository.
- STL-GRD-605 no longer says nothing was merged: with `--push` it can be raised after the local merge, and the merge output says which it is (nothing merged, or merged locally and not pushed, with the undo). A `merge-check/<card>` branch left by an interrupted merge is reused.
- The write guard refuses every call with STL-CFG-303 while an owner command file cannot be read: its by-bytes rule for copies cannot be proven then.

## Alert codes
`STL-CFG-310` (a data file is invalid), `STL-CFG-311` (a name is not in the data) and `STL-CFG-319` (an env-format row is
not readable through this tool) are used by `stella_data.py`.
`STL-CFG-312` to `318` and `321` to `323` are used by the apply and event-log tools (see above).

## How the suite runs (decided by the owner 2026-11-12)
Two tiers. The full suite (`npm test`, `bin/selftests.sh`) runs at merge and on the final hash. The quick tier (`npm run test:quick`, `bin/selftests.sh --quick`) is what the 15-minute watchdog runs; its list is the `quick` key of `.stella/test-map.json` (data: `bin/test-map.py quick` prints it, `check` refuses a name outside the suite list). Either way each selftest runs isolated in its own copy of the tree and a bubblewrap mount namespace (own tree, alert log and temp folder), at most `test_rerun.parallel` at once (watchdog settings); a selftest whose file holds the line `# selftest: serial` runs alone after the batch. Inside a box that forbids nested namespaces the suite fails, by design. Output is in list order; `SELFTESTS_TIMES=<file>` records the seconds per selftest.
