# plugins

Three internal plugins, one per manifest layout the registry recognises:

| Plugin | Layout | Contents |
|---|---|---|
| `acme-review` | Claude Code: `.claude-plugin/plugin.json` | skill `review`, command `checklist`, agent `reviewer`, a `SessionStart` hook that only prints a line |
| `acme-standards` | Agent Plugins Standard: root `plugin.json` with the agent-plugins.org 1.0.0 `$schema` | skills `acme-style`, `acme-secure-defaults`; `mcp.json` starting `acme-docs-mcp` (a stdio MCP server in the client image) |
| `acme-release-notes` | multi-harness: `.claude-plugin/`, `.cursor-plugin/`, `.codex-plugin/` | skill `release-notes` |

`flows/validate.sh` runs `claude plugin validate` on each. `flows/publish.sh` publishes them with
`ak agent plugins publish` (and `acme-standards` with plain `curl -T`). The manifests carry
`version: 1.0.0`; `flows/update.sh` publishes `acme-review` 1.1.0 with `--version`, which writes
the new version into the upload, not into this directory.
