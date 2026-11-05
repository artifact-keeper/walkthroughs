# Next steps

--8<-- "includes/preview-mcp.md"

## Adapting this to your organization

- **The real public registry.** Point the Remote at `https://registry.modelcontextprotocol.io`
  and drop `AK_SSRF_ALLOW_PRIVATE_CIDRS`. The real registry has tens of thousands of entries
  (40,000 server versions on 2026-11-04); a sync pass reads at most 200 pages and resumes
  where it stopped, so the first full catalog takes several passes. Nothing is served until
  you approve it, however large the catalog.
- **Backing Remotes for the package types you approve.** Upstream servers ship as npm
  packages, PyPI distributions and images on ghcr.io and Docker Hub. A server is served only
  when its packages are pinned in your registry, so map a Remote for each type you allow
  (`mcp_package_repos` on the Remote). Today only image-backed servers can be pinned this way;
  npm and PyPI wait for a fix ([lab notes, F1](findings.md#f1-a-remote-never-pins-npm-packages-pulled-through-npm-remote)).
- **A real DNS name and CA.** `ak.internal` with Caddy's internal CA stands in for your DNS and
  PKI. `AK_EXTERNAL_URL` must be the name clients can reach: every package coordinate is built
  from it.
- **Lock the clients to the registry.** The registry only says what is allowed. Pair it with
  each client's own policy: Copilot's "Registry only" access, VS Code's
  `chat.mcp.gallery.serviceUrl` through device management, Claude Code's managed settings
  (`allowedMcpServers` with `allowManagedMcpServersOnly`), Cursor's team allowlist.
- **CI publishes, with OIDC.** Replace the stored `ci` token with the
  [Step 5](5-publish-from-ci.md) setup, use the provider's discovery key source against the real
  GitHub issuer, and turn on `mcp_require_namespace_grant` once every publisher has a grant.
  Run `/validate` first and stop unless every package is `pinned`.
- **Servers with dependencies.** The example server has none, so `npm` maps to the Local
  `npm-internal` and clients install from it. A server with npm dependencies needs a client
  registry that can also serve them: give clients the Virtual `npm`, keep the MCP mapping on
  the Local repository, and block your internal scope on the npm Remote.
- **A scan policy that fits.** The policy here holds every `review` lint finding. Decide which
  findings your team triages and acknowledges, and who; an acknowledgement releases the
  version.
- **Introspection.** Artifact Keeper can probe remote servers' `tools/list` and run stdio
  packages in a sandbox (the `ak-mcp-introspector` worker). It is not part of this walkthrough:
  it needs a gVisor or microVM runtime and a network that reaches only the registry.

## Ideas for a follow-up

- Run the [Step 5](5-publish-from-ci.md) workflow on a real GitHub Actions runner that reaches
  the registry, with the discovery key source.
- Drive VS Code with an extension test harness to check the gallery install end to end.
- Mirror mode (`mcp_remote_mode: mirror`) for an offline catalog, with the same curation.
