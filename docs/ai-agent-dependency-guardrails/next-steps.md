# Next steps

## Take it to your own setup

- **Start with the network.** Point the sandbox at the registry, and block everything else. Without that, every
  other control is a client setting the agent can change. Developer laptops get the same effect
  from an egress proxy or firewall rule that allows the registry and the model API, and nothing
  else, for the agent's process or container.
- **One index per package manager**, system-wide: `/etc/uv/uv.toml` with `index-strategy =
  "first-index"`, the global `npmrc`, `pip.conf` if pip is in use. Credentials from the
  environment, never in project files.
- **Build the approved list from lockfiles you already review**, then let new names arrive
  through a request and one command (`policies/approve.sh`). Keep the list in Git so its history
  shows who approved what.
- **A seven-day cooldown on every remote**, and a written exceptions file for security fixes.
  Expect to use it: the first run of this walkthrough did.
- **Scan-on-proxy, fail closed**, with both Grype and the OSV-based dependency scan enabled, and
  a way to notice when one of them is not running (only a Grype failure refuses a file in 1.11.7).
- **Turn off install-time code in the sandbox**: `ignore-scripts=true` for npm, wheels only
  (`no-build`) for uv. Approved packages still run code when imported; that is the sandbox's job.
- **Own your internal names**: hosted members first with explicit priorities, isolated hosted
  names on npm virtuals, an upstream filter for your scopes.
- **MCP servers are dependencies**: hosted when internal, pinned, installed from the lockfile,
  started from `node_modules` or the virtualenv, never `npx -y <name>@latest`.

## What Artifact Keeper should do next

From the [findings](findings.md), in the order that would change this walkthrough most:

1. **F10**: a virtual with more than one age-gated remote, so a second public index can live in
   the main virtual.
2. **F1**: an audit row for every refusal, so "what did the agent try?" is one query.
3. **F7**: typosquat and popularity rules on proxy downloads, for teams that prefer
   "allow unless suspicious" to an approved list.
4. **F8**: npm curation that filters the packument and honours version-limited rules.
5. **F2, F3**: verified provenance for npm and PEP 740 attestations on publish.

## Related walkthroughs

- [A private conda channel for pixi](../private-conda-channel-pixi/index.md): the same registry
  pattern for conda, with promotion gates and attestations.
- [Rocky Linux image mode on bare metal](../rocky-linux-image-mode-bare-metal/index.md): one
  registry as the source of truth for an operating system.
