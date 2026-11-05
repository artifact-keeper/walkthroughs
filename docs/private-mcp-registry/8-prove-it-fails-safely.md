# Step 8: Prove it fails safely

--8<-- "includes/preview-mcp.md"

The steps so far showed each control once. The gates check them all again, from a finished
`make all`, and print one verdict per check: `PASS`, `FAIL` with the reason, or
`BLOCKED(<reason>)` when a check cannot run here and says nothing about the setup. Checks
assert on status codes, error codes and documents, never on message text.

```bash
make gates     # gates/run-all.sh; verdicts in out/gates/results.tsv, logs in out/gates/gNN.log
```

| Gate | What it proves | Script |
|---|---|---|
| G1 Access | anonymous reads and `/validate` of the private registry are `401`; a read token cannot publish; nobody publishes to a Virtual or a Remote | [`g01-access.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/gates/g01-access.sh) |
| G2 Publish rules | write-once versions, the namespace allowlist, the reserved namespace, external, floating, missing and unpinned packages, a hardcoded secret (not echoed back) | [`g02-publish-rules.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/gates/g02-publish-rules.sh) |
| G3 Client contract | the API envelope, `latest`, the served npm and OCI coordinates, `/v0` equals `/v0.1`, CORS, Claude Code connects, a tool call works | [`g03-client-contract.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/gates/g03-client-contract.sh) |
| G4 GUI clients | VS Code's gallery and Copilot's policy: blocked, with the steps to do by hand | [`g04-gui-clients.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/gates/g04-gui-clients.sh) |
| G5 Curation | deny by default, glob approval, lookalikes, deny wins, pins, drift, upstream package pins | [`g05-curation.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/gates/g05-curation.sh) |
| G6 Supply chain | digest pins survive a tag move and cannot be deleted, quarantine hides and releasing restores, the injection hold | [`g06-supply-chain.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/gates/g06-supply-chain.sh) |
| G7 CI OIDC | the exchange, the namespace grant, other organizations and audiences refused, `mcp_require_namespace_grant` | [`g07-ci-oidc.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/gates/g07-ci-oidc.sh) |
| G8 Virtual | hosted shadows remote, the merged listing, cursors, read-only | [`g08-virtual.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/gates/g08-virtual.sh) |
| G9 Bundles | unsigned, untrusted and tampered bundles refused, single-use tickets, the capabilities diff | [`g09-bundles.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/gates/g09-bundles.sh) |

Gates G2, G7 and G9 publish their own versions (`0.<run id>.0` and similar), so they can be
run again.

## The reference run

From a clean `make all` on 2026-11-04, `make gates` took 13 seconds:

```text
Summary (2026-11-04T17:41:15Z .. 2026-11-04T17:41:28Z, 13 s):
PASS              G1   anonymous read of the private registry is 401 mcp_unauthorized
PASS              G1   anonymous /validate of the private registry is 401 (mcp-publisher validate sends no token)
PASS              G1   the developer token reads the registry (200)
PASS              G1   the developer token cannot publish (403 mcp_forbidden)
PASS              G1   the ci token cannot publish to the Virtual (403)
PASS              G1   nobody publishes to a Remote, not even an admin (405 mcp_read_only)
PASS              G2   republishing com.acme/tickets 1.0.0 is 409 mcp_version_exists
PASS              G2   a name outside com.acme is 403 mcp_namespace_not_allowed
PASS              G2   the reserved io.modelcontextprotocol namespace is 403
PASS              G2   an npm package from registry.npmjs.org is 422 mcp_external_registry
PASS              G2   an image on Docker Hub is 422 mcp_external_registry
PASS              G2   a floating image tag is 422 mcp_oci_floating_tag
PASS              G2   an image tag that was never pushed is 422 mcp_package_not_found
PASS              G2   an npm package without a version is 422 mcp_package_version_unpinned
PASS              G2   a hardcoded GitHub token is 422 mcp_lint_blocked (rule secret_literal)
PASS              G2   the refusal does not echo the secret
PASS              G3   GET /v0.1/servers answers the upstream envelope {servers[{server,_meta}], metadata.count}
PASS              G3   versions/latest of com.acme/tickets is 1.0.0 (1.0.2 is held)
PASS              G3   the npm package is served with registryBaseUrl https://ak.internal/npm/npm-internal
PASS              G3   the OCI package is served as ak.internal/oci-internal/...:1.0.0@sha256:<digest>
PASS              G3   /v0 answers the same document as /v0.1
PASS              G3   CORS preflight allows any origin, GET and the Authorization header
PASS              G3   Claude Code: claude mcp list starts the server installed from ak.internal and reports it Connected
PASS              G3   an MCP client calls list_tickets on the installed server and gets the two open tickets
BLOCKED(gui)      G4   VS Code lists and installs com.acme/tickets from the gallery: set chat.mcp.gallery.serviceUrl to https://ak.internal/mcp/mcp (out/clients/vscode-settings.json), trust the CA, open Extensions > MCP Servers, install Acme tickets
BLOCKED(gui)      G4   Copilot accepts the registry and, under 'Registry only', refuses a server that is not in it: organization settings > Copilot > Policies > MCP: registry URL https://ak.internal/mcp/mcp (reachable by the clients), access Registry only
PASS              G5   an unapproved version (notes 1.1.0) is the plain unknown-name 404
PASS              G5   the listing has no unapproved, blocked or denied name
PASS              G5   io.github.modelcontextprotocol/* was approved by the auto-approve glob
PASS              G5   the lookalike io.github.examp1e/weather was flagged (typosquat of io.github.example/weather) and is blocked
PASS              G5   deny wins: io.github.evil-corp/exfil is approved and denied, and not served
PASS              G5   a bulk approval of io.github.evil-corp/* approves nothing
PASS              G5   a bare namespace pattern is 422
PASS              G5   the pinned name serves only the pinned version (notes: [1.0.0])
PASS              G5   after drift and re-approval, clock 1.0.0 serves the stored document, not the new upstream bytes
PASS              G5   the drift was audited (MCP_SERVER_CONTENT_DRIFT, MCP_SERVER_REOPENED)
PASS              G5   an OCI-backed upstream server is served pinned to the digest pulled through oci-ghcr
BLOCKED(ak-fix)   G5   an npm-backed upstream server is served once its package was pulled through npm-remote: Remote sync pins npm packages from artifacts only, not the proxy cache (findings F1)
PASS              G6   the served digest is the one pinned at publish, not what the moved tag names now
PASS              G6   the tag move was audited (MCP_PIN_DRIFT_DETECTED)
PASS              G6   deleting the pinned manifest by digest is refused, even for an admin (405)
PASS              G6   the pinned digest still pulls
PASS              G6   quarantining the npm tarball hides com.acme/tickets 1.0.0 (404 mcp_backing_artifact_blocked)
PASS              G6   ... and drops it from the listing
PASS              G6   releasing it serves the version again
PASS              G6   the version whose tool description reads as an injection is held (404 mcp_rejected, scan_policy)
PASS              G6   its health names the finding (injection_phrase, action review)
PASS              G7   an acme main-branch ID token is exchanged for a registry token (200)
PASS              G7   the exchanged token publishes com.acme/status (inside com.{repository_owner}/*)
PASS              G7   it cannot publish com.acme.payments/ledger (403 mcp_namespace_not_granted)
PASS              G7   another organization's ID token is refused (401 mcp_unauthorized)
PASS              G7   an ID token for another audience is refused (401)
PASS              G7   with mcp_require_namespace_grant, repository write alone (the ci user) is refused (403 mcp_namespace_not_granted)
PASS              G7   ... while the namespace-granted CI account still publishes
PASS              G8   the squatter com.acme/tickets 9.9.9 is approved and served by mcp-upstream itself
PASS              G8   through the Virtual, com.acme/tickets has only the hosted versions
PASS              G8   ... and 9.9.9 is the plain 404
PASS              G8   the merged listing has hosted and approved upstream servers, each from its member
PASS              G8   a malformed cursor is 400 mcp_invalid_query
PASS              G8   a publish to the Virtual is 405 mcp_read_only
PASS              G9   an unsigned bundle is 422 mcp_bundle_unsigned
PASS              G9   a bundle signed by an unknown certificate is 422 mcp_bundle_signer_untrusted
PASS              G9   a signed bundle changed after signing is refused (422 or 400)
PASS              G9   an exact read of the bundle version carries a ticket
PASS              G9   the ticket downloads the signed bytes once without a credential, then not again
PASS              G9   the capabilities diff of the CI reports shows the added destructive tool
BLOCKED(ak-fix) 1
BLOCKED(gui) 2
PASS 63
```

## The blocked checks

- **BLOCKED(gui), G4, twice.** VS Code's gallery install and Copilot's "Registry only" policy
  need a person and, for Copilot, a GitHub organization. G3 checks the requests they send. To
  check them by hand: set `chat.mcp.gallery.serviceUrl` to `https://ak.internal/mcp/mcp` in a
  VS Code that trusts the CA, open the MCP servers view, install Acme tickets; and set the
  organization's MCP registry URL in Copilot's policies, with access "Registry only".
- **BLOCKED(ak-fix), G5.** An upstream server whose package is on npm is never served, even
  after the package is pulled through `npm-remote`: an Artifact Keeper bug
  ([lab notes, F1](findings.md#f1-a-remote-never-pins-npm-packages-pulled-through-npm-remote)).
  The fix (`f09481c6`) is on `main` as part of `4542321b`, so on `main` the check should turn
  into a `PASS`; nothing in the walkthrough needs to change. Not re-verified here.

Next: [Results](results.md).
