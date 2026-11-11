# Extension manifests

One JSON file per extension in this folder (a skill, MCP server, connector, channel, worker adapter or provider).
Each file is validated against `.stella/schemas/extension.schema.json` by `python3 bin/stella_data.py check`.
Fields: `schema_version`, `id`, `kind`, `summary`, `hosts` (host:port), `secrets` (variable names, never values),
`tools`, `allowed_roles` (names from the role table), `risk_class`, `enabled` (the disable switch), `status`
(proposed, approved, disabled), `source`.

Installing needs the owner's approval: a new manifest starts as `proposed` and `enabled: false`. Finding an
extension with `stella_data.py search` grants nothing. See docs/contract/README.md.
