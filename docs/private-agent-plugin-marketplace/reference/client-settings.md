# Reference: client settings and file locations

--8<-- "includes/preview-1.12.md"

What the workstation image contains, which certificate settings each client honours, and
where each one keeps what it installs. All of it was observed in the image built by
[`client/Containerfile`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/client/Containerfile).

## Versions

From [`client/VERSIONS`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/client/VERSIONS) and `client/build.sh`'s check:

| Client | Version | Source |
|---|---|---|
| Node | 22 (`node:22-bookworm-slim`) | docker.io |
| Claude Code | 2.1.318 | `npm i -g @anthropic-ai/claude-code@2.1.318` |
| Codex CLI | 0.166.0 | `npm i -g @openai/codex@0.166.0` |
| GitHub Copilot CLI | 1.0.105 | `npm i -g @github/copilot@1.0.105` |
| Cursor CLI (`cursor-agent`) | 2026.10.22-27dcf5f | `curl -fsSL https://cursor.com/install \| bash` (worked with no terminal) |
| ak | 1.11.0-rc.2 | release `v1.11.0-rc.2`: `ak-linux-<arch>`, checked against its `.sha256` and its cosign keyless signature |

**ak.** No stable CLI release carries `ak agent plugins` yet; `v1.11.0-rc.2` (tagged at
[artifact-keeper-cli@10eafa8](https://github.com/artifact-keeper/artifact-keeper-cli/commit/10eafa8),
the commit that added the command) is the first prerelease that does. The image downloads that
release's binary by default. Set `AK_CLI_RELEASE=source` in `client/VERSIONS` (or in the
environment of `make client`) to build `ak` from source at `AK_CLI_REV` with cargo instead,
about 12 minutes on a 40-core host. On your own machine, the installer needs the version spelled
out, because it skips prereleases:

```bash
curl -fsSL https://raw.githubusercontent.com/artifact-keeper/artifact-keeper-cli/main/install.sh | sh -s -- --version v1.11.0-rc.2
```

## Trusting the internal CA

The image puts `ak-internal-ca.crt` into the system store (`update-ca-certificates`) and sets
`NODE_EXTRA_CA_CERTS` and `SSL_CERT_FILE`. What each client actually needed, tested by
removing one setting at a time against `https://mirror.internal`:

| Client | Trusts the CA through |
|---|---|
| Claude Code (a native binary, not a Node script) | any one of: `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, or the system store with neither variable set. With none of the three: `unable to get local issuer certificate` |
| ak | `AK_CA_CERT` (added to its built-in roots), set to the same file |
| Codex, Copilot | no network use in this walkthrough: they read local directories |

## Accounts

| Command | Needs an account |
|---|---|
| `claude plugin validate / marketplace add, list, update, remove / install / update / list / details / uninstall` | no |
| `claude -p ...`, an interactive `claude` session | yes (a session start still registers settings-declared marketplaces first) |
| `codex plugin marketplace add, list / plugin add, list, remove` | no |
| `codex exec`, a session | yes |
| `copilot plugin install <dir> / list / marketplace list` | no |
| `copilot -p`, a session | yes |
| `cursor-agent plugin marketplace list, add` | yes (git-backed team marketplaces only) |
| `cursor-agent status` | no (prints "Not logged in") |
| every `ak agent plugins` command | an Artifact Keeper token only |

## Claude Code

| What | Where |
|---|---|
| Declared marketplaces (yours, or the token-in-path URL that `marketplace add` writes) | `~/.claude/settings.json`, `extraKnownMarketplaces` |
| Registered marketplaces, with their source (including `headers`) | `~/.claude/plugins/known_marketplaces.json` |
| The cached marketplace document | `~/.claude/plugins/marketplaces/<name>` |
| Installed plugins | `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` |
| The install list | `~/.claude/plugins/installed_plugins.json` |
| Enabled plugins | `~/.claude/settings.json`, `enabledPlugins` |

Settings-route entry:

```json
{
  "extraKnownMarketplaces": {
    "agent-plugins": {
      "source": {
        "source": "url",
        "url": "https://ak.internal/agentplugins/agent-plugins/claude-marketplace.json",
        "headers": { "Authorization": "Bearer <read token>" }
      },
      "autoUpdate": true
    }
  }
}
```

The walkthrough does not set `autoUpdate`, so [Step 6](../6-ship-an-update.md) can show the
manual update. Claude Code registers a settings-declared marketplace when a session starts,
not on `claude plugin marketplace update`.

## ak

| Setting | Meaning |
|---|---|
| `AK_INSTANCE` | the instance, as a URL (`https://ak.internal`) or a name from `ak instance add` |
| `AK_TOKEN` | the token for that instance (otherwise the keychain or the credential file from `ak auth login`) |
| `AK_CA_CERT` | a PEM file added to the trusted roots |
| `AK_FORMAT` | `table`, `json`, `yaml`, `quiet` |
| `AK_NO_INPUT` | never prompt |

| `--harness` | Plugin directory | Local marketplace file |
|---|---|---|
| `claude` | `~/.claude/plugins/local/ak/<repo>/<slug>` | `~/.claude/plugins/local/ak/<repo>/.claude-plugin/marketplace.json` (name `ak-<repo>`) |
| `cursor` | `~/.cursor/plugins/local/<slug>` | none |
| `codex` | `~/.agents/plugins/local/ak/<repo>/<slug>` | `~/.agents/plugins/local/ak/<repo>/.agents/plugins/marketplace.json` (name `ak-<repo>`) |
| `vscode` | `~/.copilot/installed-plugins/ak-<repo>/<slug>` | none |

Every install has `<plugin dir>/.ak/plugin-info.json` with `instance`, `repo`, `slug`,
`version`, `sha256`, `harness` and `installed_at`.

## Codex and Copilot

| What | Where |
|---|---|
| Codex marketplaces and plugins | `~/.codex/config.toml`; installed plugins in `~/.codex/plugins/cache/<marketplace>/<plugin>/<version>/` |
| Copilot installed plugins | listed by `copilot plugin list`; `copilot --plugin-dir <dir> plugin list` shows an uninstalled directory |
