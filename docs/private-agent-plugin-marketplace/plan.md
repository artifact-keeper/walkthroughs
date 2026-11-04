# Plan: a private marketplace for AI coding-agent plugins

Status: design for review, 2026-11-03. Implementation starts against this plan; the gates below
define done. Code lands in `private-agent-plugin-marketplace/` of this repository. This page is
kept as written before the build; the [lab notes](findings.md) record what changed.

## Who this is for

Platform teams that let developers use AI coding agents (Claude Code, Cursor, Codex, GitHub
Copilot) and want to hand them internal plugins: review skills, house coding standards, MCP
servers that talk to internal systems, release tooling. Today those plugins travel as git
repositories, copied directories or links in a chat. A security team asks the same questions it
asks of any other package: who published this version, can it change after review, who can read
it, was it scanned, who installed it. The answer this walkthrough builds is one registry,
Artifact Keeper, with an Agent Plugins repository (format `agentplugins`, new in 1.12.0).

## Requirements the walkthrough must demonstrate

| # | Requirement | Where it is demonstrated |
|---|---|---|
| R1 | One private registry over TLS with a bare hostname; every client in a container that trusts the internal CA | `https://ak.internal`, Caddy `tls internal`, the client image |
| R2 | Plugins authored once in the layouts the agents read: Claude Code, the Agent Plugins Standard, multi-harness | `plugins/acme-review`, `acme-standards`, `acme-release-notes`; `claude plugin validate` |
| R3 | Publishing needs a write token scoped to one repository; reads need a token; a read token cannot publish | `ci` and `developer` repository tokens, 401 / 403 matrix |
| R4 | Publish rules close the ambiguous cases: no overwrite, no manifest, name or version mismatch, build metadata, traversal entries, bad slugs and file names | `ak agent plugins publish`, plain `curl -T`, negative publishes |
| R5 | Claude Code installs from the registry with no extra tooling, for a private repository (settings route and token-in-path route) and a public one | `claude plugin marketplace add`, `claude plugin install` |
| R6 | Cursor, Codex and Copilot get the same bytes through `ak agent plugins install`, verified by SHA-256 | harness directories, `.ak/plugin-info.json`, each agent's own listing |
| R7 | Updates flow: a new version reaches Claude Code and the CLI installs, and the CLI says what is behind | `claude plugin marketplace update`, `claude plugin update`, `ak agent plugins list --check-updates`, `update --all` |
| R8 | The index documents are a stable contract: Claude naming rules, `archive` sources with a correct `sha256`, per-harness membership and latest, ETag, cache headers | the five marketplace documents and `<name>/index.json` |
| R9 | Versions are immutable, even across a delete; tampered bytes are refused by the client | 409 after delete, identical-bytes restore, a tampered mirror |
| R10 | Scanning gates what is served: an unscanned version is hidden and not downloadable until its scan completes | `block_unscanned` scan policy |
| R11 | An audit trail: who published, what was downloaded | download statistics and audit events through the REST API |
| R12 | Tokens do not leak: redacted in logs; the exposure of the token-in-path route is stated | Caddy and backend logs, `known_marketplaces.json` |

## Environment

- **Host**: one Linux host with rootless podman and `podman compose`. No sudo. The reference run
  is on a 40-core Ubuntu 26.04 host.
- **Registry**: Artifact Keeper backend with the `agentplugins` format (first shipped in 1.12.0;
  the walkthrough pins the `main` build `sha-c3a650e` until the release exists), web UI `:dev`
  (the Agent Plugins setup tab), upstream `docker-compose.yml` unmodified plus an override.
  Compose project `ak-agents`, containers `ak-agents-*`, network `ak-agents-net`. Caddy answers
  as `https://ak.internal` with `tls internal`; the only host port is `127.0.0.1:30447`.
  `AK_EXTERNAL_URL=https://ak.internal`, because Claude Code downloads archives only over https.
- **Repositories**:
  - `agent-plugins`: format `agentplugins`, hosted, visibility `private`. Scan-on-upload on.
  - `agent-plugins-public`: same format, visibility `public`, to show the anonymous route.
  - `trust`: generic, public, holds the internal CA certificate.
- **Credentials** (generated, gitignored, in `registry/.env` and `registry/.tokens/`): an admin
  API token for the scripts; `ci.token`, a repository token on `agent-plugins` with read and
  write; a `developer` user and `developer.token`, a read-only repository-scoped token.
- **Client image** ("developer workstation"): Node 22, Claude Code, Codex and Copilot CLIs from
  npm at exact versions recorded in `client/VERSIONS`, the Cursor CLI if its installer works
  without a terminal, the `ak` CLI (built from source at the commit that added
  `ak agent plugins`, because no release carries it yet; `AK_CLI_RELEASE` switches to a release
  binary), the internal CA in the system store and `NODE_EXTRA_CA_CERTS`. Each run gets a
  throwaway `HOME`. No Anthropic, OpenAI or GitHub account is used anywhere.
- **Plugins**:
  - `acme-review` (Claude Code layout): `.claude-plugin/plugin.json`, a `review` skill, a
    command, a reviewer agent, and a harmless `hooks/hooks.json`.
  - `acme-standards` (Agent Plugins Standard): root `plugin.json` with the agent-plugins.org
    1.0.0 `$schema`, skills, and an `mcp.json` that starts a stdio MCP server present in the
    client image.
  - `acme-release-notes` (multi-harness): `.claude-plugin/`, `.cursor-plugin/` and
    `.codex-plugin/` manifests over the same skills.

## Flows (make targets)

`registry-up`, `bootstrap`, `client`, `validate`, `publish`, `indexes`, `consume-claude`,
`consume-cli`, `update`, `scan`, `audit`, `gates`, `screens-ready`, `all`, `clean`. Each one is
re-runnable; `make help` lists them.

## Gates

Each gate prints its evidence and one verdict per check: `PASS`, `FAIL`, or `BLOCKED(account)`
when the check needs a signed-in agent account, in which case the gate prints the command a
reader runs after logging in. Verdicts accumulate in `out/gates/results.tsv`. Assertions are on
status codes and documents, never on message text.

| Gate | What it proves |
|---|---|
| G1 Auth | anonymous 401 on the private repository; read token 200; read token cannot publish (403); a token for another repository is refused; no credential in any committed file; public repository anonymous 200 |
| G2 Publish rules | 409 on overwrite; 400 for no manifest, name mismatch, version mismatch, `1.0.0+build`, a traversal entry, an uppercase slug, a wrong file name; none of them in any index |
| G3 Index contract | Claude Code name rules; `source.source == "archive"`; `sha256` matches the bytes; membership per harness; per-harness latest when the newest version is Cursor-only; ETag and 304; `Cache-Control` values, `private, no-store` on the token route |
| G4 Claude Code end to end | marketplace add and install from the registry; the plugin's skills, commands, agents and hooks present in Claude Code's cache |
| G5 Tampering | a modified zip served under the genuine index: `ak agent plugins install` refuses on SHA-256, and so does Claude Code |
| G6 Immutability after delete | delete through REST; re-publish of different bytes 409, identical bytes 201; the index falls back to the previous version meanwhile |
| G7 Scan gate | `block_unscanned` hides an unscanned version (download 403, index lists the previous version), then the scan completes and it appears |
| G8 CLI harness installs | every harness location written; `.ak/plugin-info.json` correct; update status `current`, `behind`, `ahead`; uninstall removes the marketplace entry |
| G9 Generic upload | a zip written through the generic REST upload is neither indexed nor served by the format |
| G10 Token hygiene | the path token redacted in the Caddy access log and the backend log, for the marketplace and the archive URL; `known_marketplaces.json` holds the token, as documented |

## Done means

`make all` from an empty registry on the test host, then `make gates`, both green apart from
documented `BLOCKED(account)` checks; `make clean` and `make all` again with the same result;
`mkdocs build --strict` passes; no secret in git.
