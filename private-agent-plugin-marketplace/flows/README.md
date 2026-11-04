# flows

One script per make target, each re-runnable. They source `lib.sh` (helpers on top of
`../registry/lib.sh`) and run client commands through `../client/run.sh`.

| Script | make target | Home under `out/homes/` |
|---|---|---|
| `validate.sh` | `validate` | scratch |
| `publish.sh` | `publish` (skips versions already published) | scratch |
| `indexes.sh` | `indexes` (writes `out/indexes/`) | none |
| `consume-claude.sh` | `consume-claude` | `claude-settings`, `claude-token`, `claude-public` (recreated) |
| `consume-cli.sh` | `consume-cli` | `workstation` (recreated) |
| `update.sh` | `update` (needs the homes above) | `claude-settings`, `workstation` |
| `scan.sh` | `scan` (creates `agent-plugins-staging`) | scratch |
| `audit.sh` | `audit` | none |
