# Step 2: Author the plugins

A plugin for an AI coding agent is a directory: instructions the agent reads (skills,
commands, agents), configuration it acts on (hooks, MCP servers), and a manifest that names
it. Every agent has its own manifest location, so the first decision is which layout to ship.
Artifact Keeper recognises five markers and tags each version with every one it finds; the
tags decide which marketplace documents list the version ([Step 3](3-publish.md)).

| Marker, relative to the plugin root | Tag | Read by |
|---|---|---|
| `.claude-plugin/plugin.json` | `claude` | Claude Code (and VS Code / Copilot detect it too) |
| `plugin.json` whose `$schema` starts with `https://agent-plugins.org/schemas/` | `standard` | the [Agent Plugins Standard](https://agent-plugins.org): Copilot, Codex, Cursor; Claude Code loads its skills |
| `.cursor-plugin/plugin.json` | `cursor` | Cursor |
| `.codex-plugin/plugin.json` | `codex` | Codex |
| `gemini-extension.json` | `gemini` | recorded only; no document or installer |

The three plugins in
[`plugins/`](https://github.com/artifact-keeper/walkthroughs/tree/main/private-agent-plugin-marketplace/plugins)
cover the three layouts you are likely to need.

## acme-review: the Claude Code layout

```text
acme-review/
├── .claude-plugin/plugin.json
├── README.md
├── skills/review/SKILL.md
├── commands/checklist.md
├── agents/reviewer.md
└── hooks/hooks.json
```

```json title="plugins/acme-review/.claude-plugin/plugin.json"
{
  "name": "acme-review",
  "version": "1.0.0",
  "description": "Acme code review: a review skill, a checklist command, a reviewer agent and a session reminder",
  "author": { "name": "Acme Platform Team", "email": "platform@acme.example" },
  "homepage": "https://wiki.acme.example/engineering/code-review",
  "license": "MIT",
  "keywords": ["review", "quality", "acme"]
}
```

The skill is a Markdown file with YAML frontmatter (a header block between `---` lines);
the `description` is what the agent matches a request against, so it says when to use the skill,
not only what it is:

```markdown title="plugins/acme-review/skills/review/SKILL.md (abridged)"
---
name: review
description: Review a change the way Acme reviewers do. Use when the user asks for a code review, a second opinion on a diff, or whether a change is ready to merge.
---

# Acme code review

Review the change in this order and stop at the first section that fails:
...
```

The command becomes `/acme-review:checklist`, the agent becomes a read-only subagent
(`tools: Read, Grep, Glob`), and the hook is deliberately harmless: at session start it prints
one line. Hooks run commands on the developer's machine, which is exactly why a plugin with one
should come from a registry you control rather than a link. The full files are in
[`plugins/acme-review/`](https://github.com/artifact-keeper/walkthroughs/tree/main/private-agent-plugin-marketplace/plugins/acme-review).

## acme-standards: the Agent Plugins Standard

```text
acme-standards/
├── plugin.json
├── README.md
├── mcp.json
└── skills/
    ├── acme-style/SKILL.md
    └── acme-secure-defaults/SKILL.md
```

```json title="plugins/acme-standards/plugin.json"
{
  "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
  "name": "acme-standards",
  "version": "1.0.0",
  "description": "Acme engineering standards as agent skills, plus an MCP server that answers questions about them",
  "author": { "name": "Acme Platform Team", "email": "platform@acme.example" },
  "license": "MIT",
  "keywords": ["standards", "style", "security", "mcp"]
}
```

The `$schema` is what makes this a Standard manifest; a root `plugin.json` without it is just a
file. The 1.0.0 schema allows no other top-level keys than the ones above plus `homepage`,
`repository` and `extensions`. `mcp.json` starts an MCP (Model Context Protocol) server, a
process the agent talks to over stdio:

```json title="plugins/acme-standards/mcp.json"
{
  "mcpServers": {
    "acme-docs": {
      "command": "acme-docs-mcp",
      "args": []
    }
  }
}
```

`acme-docs-mcp` is a 60-line Node script in the workstation image
([`client/acme-docs-mcp.js`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/client/acme-docs-mcp.js))
with one tool, `standard`, that returns the rule for a topic. Shipping the command in the image
and only the configuration in the plugin is the pattern to copy: the plugin stays text, and
the binary goes through whatever process already governs software on developer machines.

Claude Code lists Standard plugins and loads their skills, but it reads `.mcp.json`, not the
Standard's `mcp.json`. If you need the MCP server in Claude Code too, ship both files.

## acme-release-notes: one skill, three manifests

```text
acme-release-notes/
├── .claude-plugin/plugin.json
├── .cursor-plugin/plugin.json
├── .codex-plugin/plugin.json
├── README.md
└── skills/release-notes/SKILL.md
```

The three manifests carry the same name, version and description; the Codex one also says
where the skills are (`"skills": "./skills/"`). The registry tags the version `claude`,
`cursor` and `codex`, so it appears in all three agents' documents.

## Validate before you publish

`make validate` runs Claude Code's own checker on each directory. It needs no account:

```console
$ make validate
$ claude plugin validate /plugins/acme-review
Validating plugin manifest: /plugins/acme-review/.claude-plugin/plugin.json
 ...
⚠ Found 1 plugin directory warning:
  ❯ .claude-plugin/plugin.json icon: No icon (ICON_MISSING). ...
✔ Validation passed

$ claude plugin validate /plugins/acme-standards
Validating components in: /plugins/acme-standards
✔ Validation passed
 ...
$ (Agent Plugins Standard 1.0.0 rules) /plugins/acme-standards/plugin.json
ok: schema, name, keys
```

The validator also runs the checks of Anthropic's public plugin directory. The first run
refused a submission for a missing `README.md`, which is why every plugin has one now; the icon
warning only matters for the public directory. For the Standard layout the validator checks the
skills, so [`flows/validate.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/flows/validate.sh)
adds the Standard's own rules for `plugin.json` with `jq`.

Two rules the registry will enforce at publish are worth following here already:

- **The name is a slug**: lowercase letters, digits and hyphens, starting with a letter or
  digit, at most 64 characters. It is the one set of names every agent accepts.
- **A manifest `version`, if present, must equal the version you publish.** Claude Code takes
  an installed plugin's version from `plugin.json` before the marketplace entry and downloads
  again only when that string changes, so a stale `version` would freeze every install. Either
  leave `version` out, or let `ak agent plugins publish --version` write it into the upload
  ([Step 6](6-ship-an-update.md) does that).

Next: [Step 3, publish](3-publish.md).
