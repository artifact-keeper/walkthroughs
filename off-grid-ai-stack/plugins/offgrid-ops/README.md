# offgrid-ops

The plugin the off-grid agent installs from Artifact Keeper's marketplace. It is the
Standard layout (`plugin.json` with the agent-plugins.org `$schema`):

- `mcp.json` names the two MCP servers to start: `acme-inventory` (Acme's internal server,
  package `acme-inventory-mcp` from `pypi-local`, registry entry `com.acme/inventory` in
  `mcp-internal`) and `sqlite` (`mcp-sqlite3` from pypi.org, registry entry
  `io.github.daedalus/mcp-sqlite3` approved in `mcp-official`).
- `skills/inventory-answers/SKILL.md` is the instruction the agent gives the model.

`flows/seed.sh` zips it (fixed timestamps, sorted entries) and publishes
`offgrid-ops-1.0.0.zip` to `plugins-central`.
