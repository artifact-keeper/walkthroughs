# Step 6: Ship an update

`acme-review` 1.1.0 adds one item to the checklist. [`make update`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/flows/update.sh)
publishes it and brings both kinds of install up to date.

## Publish 1.1.0

The plugin directory still says `"version": "1.0.0"`. Publishing with `--version` writes the
new version into every manifest **inside the upload**, so the registry's rule (manifest version
equals path version) holds without anyone editing the file:

```console
$ ak agent plugins publish /out/work/acme-review-1.1.0 --repo agent-plugins --version 1.1.0
Published acme-review 1.1.0 to agent-plugins.
  sha256: f248747d0f02e9575bdc1b1f9b0af7c612f7d8b354df8ce8fd2658131f5d40e2
  harnesses: claude
  ...
  acme-review 1.1.0 servable in agent-plugins after 0 s
```

This rule exists because of how Claude Code updates: it takes an installed plugin's version from
`plugin.json` first and the marketplace entry second, and downloads again only when that string
changes. A 1.1.0 zip whose manifest still said 1.0.0 would never reach anyone who has 1.0.0.

## Claude Code

Third-party marketplaces do not auto-update by default. Refresh the marketplace, then update the
plugin:

```console
$ claude plugin marketplace update agent-plugins
Updating marketplace: agent-plugins...Downloading marketplace from https://ak.internal/agentplugins/agent-plugins/claude-marketplace.json
✔ Successfully updated marketplace: agent-plugins
$ claude plugin update acme-review@agent-plugins --json
{"command":"update","outcome":"ok","plugin":"acme-review@agent-plugins", ... ,"updateOutcome":"updated","oldVersion":"1.0.0","newVersion":"1.1.0"}
$ tail -1 ~/.claude/plugins/cache/agent-plugins/acme-review/1.1.0/commands/checklist.md
- [ ] New endpoints log the request ID and the caller, and nothing secret
```

On a fleet, set `"autoUpdate": true` on the marketplace in managed settings and Claude Code does
this at startup.

## The `ak` installs

```console
$ ak agent plugins list --check-updates
HARNESS  SLUG                VERSION  REPO           LATEST  STATUS   PATH
cursor   acme-release-notes  1.0.0    agent-plugins  1.0.0   current  ...
 ...
vscode   acme-review         1.0.0    agent-plugins  1.1.0   behind   /home/dev/.copilot/installed-plugins/ak-agent-plugins/acme-review
vscode   acme-standards      1.0.0    agent-plugins  1.0.0   current  ...
$ ak agent plugins update --all
 ...
vscode   acme-review         1.0.0  1.1.0  updated  /home/dev/.copilot/installed-plugins/ak-agent-plugins/acme-review
$ ak agent plugins list --check-updates
vscode   acme-review         1.1.0    agent-plugins  1.1.0   current  ...
```

`--check-updates` asks each install's own instance for `<name>/index.json` and compares by
SemVer: `current`, `behind`, `ahead` (the server's newest is older than what is installed,
for example after a version was deleted) or `unknown`. `update` re-downloads, re-verifies and
swaps the directory in only after the new one unpacked, so a failed update leaves the old
install as it was. Gate G8 drives an install through all three states.

Next: [Step 7, govern](7-govern.md).
