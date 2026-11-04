# acme-standards

Acme's engineering standards as agent skills, in the Agent Plugins Standard layout (a root
`plugin.json` with the agent-plugins.org schema), so every agent that reads the standard gets
the same rules.

- **Skill `acme-style`**: the code style rules for Python, TypeScript and shell.
- **Skill `acme-secure-defaults`**: the secure defaults every service starts from.
- **MCP server `acme-docs`** (`mcp.json`): a local stdio server, `acme-docs-mcp`, with one tool,
  `standard`, that returns the rule for a topic. The command ships in the developer image.
  Claude Code reads `.mcp.json`, not the Standard's `mcp.json`, so in Claude Code only the
  skills load.

Owner: Acme Platform Team.
