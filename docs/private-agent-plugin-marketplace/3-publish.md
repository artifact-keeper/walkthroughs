# Step 3: Publish

--8<-- "includes/preview-1.12.md"

A published plugin version is one zip at a fixed path:

```text
/agentplugins/{repo}/{name}/{version}/{name}-{version}.zip
```

The path is authoritative. The registry takes the name and version from the URL, checks that
any manifest inside agrees, and from then on that version is immutable. [`make publish`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/flows/publish.sh)
publishes the three plugins as CI would, with `ci.token`, two ways.

## With `ak agent plugins publish`

`ak` (the Artifact Keeper CLI) finds the manifests the same way the server does, refuses a bad
slug or version locally, zips the directory with the plugin at the root (sorted entries, the
same bytes for the same files, no `.git`, no symbolic links), and uploads it with an
`X-Checksum-Sha256` header. `--dry-run` shows what would go up:

```console
$ ak agent plugins publish /plugins/acme-review --repo agent-plugins --dry-run
acme-review 1.0.0 (claude), 2652 bytes, sha256 da14438c...
.claude-plugin/plugin.json
README.md
agents/reviewer.md
commands/checklist.md
hooks/hooks.json
skills/review/SKILL.md
Nothing was sent.

$ ak agent plugins publish /plugins/acme-review --repo agent-plugins
Published acme-review 1.0.0 to agent-plugins.
  sha256: da14438c33667c4169c215c1d9b35aee8e602bc4034654b84a2deb42b9ff3d33
  harnesses: claude
  download: https://ak.internal/agentplugins/agent-plugins/acme-review/1.0.0/acme-review-1.0.0.zip

Add the repository to Claude Code:
  claude plugin marketplace add https://ak.internal/agentplugins/agent-plugins/claude-marketplace.json
  claude plugin install acme-review@agent-plugins

Install it for another agent:
  ak agent plugins install acme-review --repo agent-plugins --harness cursor
```

`acme-release-notes` goes the same way and is tagged `claude, cursor, codex`, one tag per
manifest it carries. The workstation's `ak` reads its instance and token from `AK_INSTANCE`
and `AK_TOKEN`, which [`client/run.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/client/run.sh) sets per run; on your laptop you
would run `ak auth login` once instead.

## With plain curl

The wire protocol is one `PUT` with the zip as the body, which is all a CI system without
`ak` needs. `acme-standards` is zipped with `zip` and sent with `curl -T`:

```console
$ cd plugins/acme-standards && zip -qrX /tmp/acme-standards-1.0.0.zip .
$ curl -T acme-standards-1.0.0.zip -H "Authorization: Bearer $AK_TOKEN" -H "X-Checksum-Sha256: 7d4708a4..." \
    https://ak.internal/agentplugins/agent-plugins/acme-standards/1.0.0/acme-standards-1.0.0.zip
HTTP 201
{
  "download_url": "https://ak.internal/agentplugins/agent-plugins/acme-standards/1.0.0/acme-standards-1.0.0.zip",
  "harnesses": ["standard"],
  "marketplace_name": "agent-plugins",
  "marketplaces": {
    "all": "https://ak.internal/agentplugins/agent-plugins/marketplace.json",
    "claude": "https://ak.internal/agentplugins/agent-plugins/claude-marketplace.json",
    "codex": "https://ak.internal/agentplugins/agent-plugins/codex-marketplace.json",
    "cursor": "https://ak.internal/agentplugins/agent-plugins/cursor-marketplace.json",
    "vscode": "https://ak.internal/agentplugins/agent-plugins/vscode-marketplace.json"
  },
  "name": "acme-standards",
  "sha256": "7d4708a4e59c1b9b7b4b3b005c86893912dc4f5a72fa9f23e14e22dbb713ddbb",
  "size_bytes": 2409,
  "version": "1.0.0"
}
```

`marketplace_name` is the name Claude Code will register the repository under: the repository
key, unless the key collides with a name Claude Code reserves (`npm`, `github`, ...) or starts
with something other than a letter or digit, in which case the registry adjusts it.

`make publish` also puts `acme-release-notes` into `agent-plugins-public`, then waits until
the scan policy lets each version through ([Step 7](7-govern.md)); on this host each scan took
about five seconds.

## What the registry refuses

A publish is refused with `400` when the bundle is ambiguous, and with `409` when the version
exists. Gate G2 ([Step 8](8-prove-it-fails-safely.md)) sends each of these and checks that none
of them shows up in any document afterwards:

| Upload | Answer |
|---|---|
| the same version again, same or different bytes | `409` |
| no manifest marker (`.claude-plugin/plugin.json`, a Standard `plugin.json`, ...) | `400` |
| a manifest `name` other than the path's name | `400` |
| a manifest `version` other than the path's version | `400` |
| `1.0.0+build` (SemVer build metadata has no precedence, so it could never be "latest") | `400` |
| `1.0` (not SemVer) | `400` |
| `Acme-G2` (not a slug) | `400` |
| an entry named `../escape.md`, or a symbolic link | `400` |
| a file name other than `{name}-{version}.zip` | `400` |
| an `X-Checksum-Sha256` that does not match the body | `400` |

## The documents it generates

The registry generates five marketplace documents and one version list per plugin, from the
database on every request, so a delete or a scan decision shows up immediately.
[`make indexes`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/flows/indexes.sh) fetches them with the developer's read token:

```console
$ make indexes
marketplace.json           name=agent-plugins  plugins: acme-release-notes@1.0.0, acme-review@1.0.0, acme-standards@1.0.0
claude-marketplace.json    name=agent-plugins  plugins: acme-release-notes@1.0.0, acme-review@1.0.0, acme-standards@1.0.0
cursor-marketplace.json    name=agent-plugins  plugins: acme-release-notes@1.0.0, acme-standards@1.0.0
codex-marketplace.json     name=agent-plugins  plugins: acme-release-notes@1.0.0, acme-standards@1.0.0
vscode-marketplace.json    name=agent-plugins  plugins: acme-standards@1.0.0
```

Membership follows the harness tags:

| Document | Lists plugins tagged | Read by |
|---|---|---|
| `marketplace.json` | any | the web UI, `ak agent plugins search`; also a valid Claude Code marketplace |
| `claude-marketplace.json` | `claude` or `standard` | Claude Code |
| `cursor-marketplace.json` | `cursor` or `standard` | `ak` |
| `codex-marketplace.json` | `codex` or `standard` | `ak` |
| `vscode-marketplace.json` | `standard` | `ak` |
| `{name}/index.json` | every servable version, newest first | `ak agent plugins install`, `list --check-updates` |

Each document lists one entry per plugin, at the newest version that document may list. Gate
G3 checks the corner this creates: a plugin whose 2.0.0 is Cursor-only and whose 1.0.0 also
supports Claude Code is at 2.0.0 in `cursor-marketplace.json` and at 1.0.0 in
`claude-marketplace.json`.

An entry in `claude-marketplace.json` (abridged; the full documents are in `out/indexes/`
after a run):

```json
{
  "name": "agent-plugins",
  "owner": { "name": "Artifact Keeper", "url": "https://ak.internal" },
  "plugins": [
    {
      "name": "acme-standards",
      "version": "1.0.0",
      "description": "Acme engineering standards as agent skills, plus an MCP server that answers questions about them",
      "author": { "email": "platform@acme.example", "name": "Acme Platform Team" },
      "license": "MIT",
      "keywords": ["standards", "style", "security", "mcp"],
      "source": {
        "source": "archive",
        "url": "https://ak.internal/agentplugins/agent-plugins/acme-standards/1.0.0/acme-standards-1.0.0.zip",
        "sha256": "7d4708a4e59c1b9b7b4b3b005c86893912dc4f5a72fa9f23e14e22dbb713ddbb"
      },
      "metadata": {
        "harnesses": ["standard"],
        "components": { "skills": ["acme-secure-defaults", "acme-style"], "commands": 0, "agents": 0,
                        "hooks": false, "mcp": true, "lsp": false, "bin": false },
        "size_bytes": 2409,
        "published_at": "2026-11-04T02:56:52Z",
        "versions_url": "https://ak.internal/agentplugins/agent-plugins/acme-standards/index.json"
      }
    }
  ]
}
```

Three things in it matter:

- **`source` is an `archive` with a `sha256`.** Claude Code downloads the zip and refuses it
  if the bytes do not hash to that value ([Step 8](8-prove-it-fails-safely.md) proves it with
  a tampered mirror).
- **`metadata` is Artifact Keeper's.** Claude Code documents that field as never read; the
  component inventory in it is what a future content policy (no hooks, no MCP servers) will
  decide on, without re-indexing.
- **Every response carries an `ETag`** and answers `If-None-Match` with `304`, with
  `Cache-Control: no-cache`: clients may cache, but must ask.

Next: [Step 4, install in Claude Code](4-install-in-claude-code.md).
