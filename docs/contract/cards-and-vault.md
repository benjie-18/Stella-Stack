# Cards and vault entries (schemas)

Two schemas in `.stella/schemas/`, checked with `python3 bin/stella_data.py validate card <file>` and `validate vault-entry <file>`. Exit 0 and `valid`, or exit 1 with a coded line. They have no index row yet: they judge a file handed to `validate`. Self-test: `bin/card-schema-selftest.sh`.

## card.schema.json

The fields Stella adds to a board card. All required; no other field is allowed.

- `schema_version` (1), `global_id` (lower-case v4 UUID), `install_id` (UUID of the install that made it). The record kind `card` and its sync class are in `.stella/data-policy.json`.
- `apps`: ids of connections of kind `app` (x-ref `connections`, `x-ref-where` `{"kind": "app"}`). `skills` and `tools`: ids of the capabilities registry of kind `skill` and `tool` (x-ref `capabilities`, `x-ref-where` on `kind`). An entry is an id, alias or global_id of a catalog record; a record of another kind is refused like an unknown id.
- Each list holds unique strings (at most 128 characters each); at most 32 apps, 64 skills, 64 tools.
- An id that is in no catalog fails closed: `STL-CFG-311`, exit 1, one alert line. Adding an app or capability to a card needs no code change, only a catalog entry.

## vault-entry.schema.json

Metadata of one rotating credential (a leased CLI login or a browser session). There is no field for the secret: `additionalProperties` is false, so `value`, `secret`, `token` are refused. The secret stays in the broker.

- `kind` (a lower-case name), `version` (integer from 1), `last_refreshed` (UTC time or null), `custody` (`engine_store` or `vm_run`).
- `lease`: null, or `{holder, acquired_at, expires_at}`. `holder` is one string, `engine` or `vm_run:<run id>`, so there is never a second live holder.
- `write_back`: `{rule: "compare_and_swap", expected_version}`. A write carries the version it read and is refused when the stored version moved on.
- `sync_class`: a sync class of the data policy with `cloud: false` (x-ref `data-policy/sync_classes`, `x-ref-where` `{"cloud": false}`: the list stays in the data policy only). A cloud class is refused. Vault entries never reach a cloud store (except inside a move-primary transfer to the owner's own paired device, end-to-end encrypted).
- `global_id`, `install_id`: as for a card.

Not said by the schema (each needs a keyword the subset lacks; the store that writes entries enforces them):

- `expires_at` after `acquired_at`, `custody: vm_run` only with a `vm_run:` holder, and `expected_version` equal to the stored version (the compare in compare-and-swap) are checks of the store, not of one file.
