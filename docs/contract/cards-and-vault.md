# Cards and vault entries (schemas)

Two schemas in `.stella/schemas/`, checked with `python3 bin/stella_data.py validate card <file>` and `validate vault-entry <file>`. Exit 0 and `valid`, or exit 1 with a coded line. They have no index row yet: they judge a file handed to `validate`. Self-test: `bin/card-schema-selftest.sh`.

## card.schema.json

The fields Stella adds to a board card. All required; no other field is allowed.

- `schema_version` (1), `global_id` (lower-case v4 UUID), `install_id` (UUID of the install that made it). The record kind `card` and its sync class are in `.stella/data-policy.json`.
- `apps`: ids of connections of kind `app` that are switched on (x-ref `connections`, `x-ref-where` `{"kind": "app", "enabled": true}`). `skills` and `tools`: ids of the capabilities registry of that kind with status `approved` (x-ref `capabilities`, `x-ref-where` on `kind` and `status`). An entry is an id, alias or global_id of a catalog record; a record of another kind, a switched-off app or a skill or tool that is proposed or disabled is refused like an unknown id.
- Each list holds unique strings (at most 128 characters each); at most 32 apps, 64 skills, 64 tools. Unique means unique records: an alias and the global_id of one record in the same list are refused (`STL-CFG-310`). A `global_id` that is already a record's global_id in the data files is refused too (`validate`, rule 14).
- An id that is in no catalog fails closed: `STL-CFG-311`, exit 1, one alert line, also when the card has other problems (those print as `STL-CFG-310` lines). Adding an app or capability to a card needs no code change, only a catalog entry.

## vault-entry.schema.json

Metadata of one rotating credential (a leased CLI login or a browser session). There is no field for the secret: `additionalProperties` is false, so `value`, `secret`, `token` are refused. The secret stays in the broker.

- `kind` (a lower-case name; B1 defines the kinds, and this field becomes an x-ref to them then), `version` (integer from 1), `last_refreshed` (UTC time or null), `custody` (`engine_store` or `vm_run`).
- `lease`: null, or `{holder, acquired_at, expires_at}`. `holder` is one string, `engine` or `vm_run:<run id>`, so there is never a second live holder.
- `write_back`: `{rule: "compare_and_swap", expected_version}`. A write carries the version it read and is refused when the stored version moved on.
- `sync_class`: a sync class of the data policy with `cloud: false` (x-ref `data-policy/sync_classes`, `x-ref-where` `{"cloud": false}`: the list stays in the data policy only). A cloud class is refused. Vault entries never reach a cloud store (except inside a move-primary transfer to the owner's own paired device, end-to-end encrypted).
- `global_id`, `install_id`: as for a card.

Not said by the schema (each needs a keyword the subset lacks; the store that writes entries enforces them):

- `expires_at` after `acquired_at`, `custody: vm_run` only with a `vm_run:` holder, and `expected_version` equal to the stored version (the compare in compare-and-swap) are checks of the store, not of one file.
