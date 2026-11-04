# Next steps

--8<-- "includes/preview-1.12.md"

## Adapting this to your organization

- **One DNS name and a real CA.** `ak.internal` with Caddy's internal CA stands in for your
  internal DNS and PKI. Swap the hostname and the certificate and set `AK_EXTERNAL_URL` to the
  name developers use: every archive URL in the marketplace documents is built from it, and
  Claude Code downloads archives only over `https`.
- **Managed settings for Claude Code.** The settings route in
  [Step 4](4-install-in-claude-code.md) is the one to roll out: put `extraKnownMarketplaces`
  in Claude Code's managed settings, with a `headersHelper` command that prints a short-lived
  token from your secret store instead of a literal `headers` value, and `"autoUpdate": true`
  so new versions arrive without anyone running `claude plugin update`.
- **CI publishes, nobody else.** Give the CI system the only write token, scoped to the one
  repository, with an expiry, and rotate it with `POST /api/v1/repositories/{key}/tokens`.
  Developers get read-only tokens, ideally minted by themselves so the token is theirs in the
  audit log.
- **A staging repository.** Publish to a repository with the same scan policy and promote to
  the one developers read from, if you want a human review between "scanned" and "available".
- **Ship binaries separately.** Keep plugins as text (skills, configuration) and put the
  commands that hooks and MCP servers start into the image or package your fleet already
  manages, as `acme-docs-mcp` is here.
- **`ak` on every workstation.** For Cursor, Codex and Copilot, `ak agent plugins update --all`
  on a schedule (a login hook, a cron job, your device management) keeps installs current;
  `ak agent plugins list --check-updates` is the report.

## Watch for in the agents

- A hosted marketplace URL in Cursor, Codex or Copilot. Today each takes git repositories or
  local directories, which is why `ak` exists; a URL source would let them read the registry
  directly, as Claude Code does.
- Copilot's local-path installs: `copilot plugin install <dir>` prints a deprecation warning in
  1.0.105 ("only plugin@marketplace installs will be supported"). When it goes, `ak` needs to
  register a local marketplace for Copilot as it does for Codex.

## In Artifact Keeper

Follow-ups named in the design ([artifact-keeper#5251](https://github.com/artifact-keeper/artifact-keeper/issues/5251)):

- Remote repositories that proxy a marketplace hosted on GitHub, and virtual repositories that
  merge several Agent Plugins repositories.
- A content policy per repository: refuse plugins that ship hooks, a `bin/` directory or MCP
  servers. The component inventory is already recorded on every version.
- Signature or attestation verification in `ak agent plugins install`, beyond the SHA-256 from
  the index.
- Skills repositories and installers for more agents.

The [lab notes](findings.md) have the full record of this run.
