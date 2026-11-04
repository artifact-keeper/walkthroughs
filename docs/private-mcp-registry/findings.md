# Lab notes: a private MCP registry

--8<-- "includes/preview-mcp.md"

The record of building and running this walkthrough on 2026-11-04 (UTC): what we ran it on,
the Artifact Keeper bugs and documentation gaps we hit, the behaviour worth knowing, and what
was not machine-verified. The step pages are written from these notes and from the reference
run in [Results](results.md).

## Environment

| | |
|---|---|
| Host | `grace`: Ubuntu 26.04, x86_64, 40 cores, 108 GB RAM, rootless podman 5.7.0, `podman compose`, no sudo |
| Neighbours | other Artifact Keeper stacks (`ak-agent-*` on 30445, `ak-gate-*` on 30446, a docker stack on 18580) kept running, untouched |
| Backend | `localhost/ak-backend:mcp-c89f9cea`, built from artifact-keeper#5257 at `c89f9cea` with `docker/Dockerfile.backend` (reports version 1.11.3) |
| Web | `localhost/ak-web:mcp-89313d4`, built from artifact-keeper-web#1077 at `89313d4` |
| Clients | Claude Code 2.1.318, mcp-publisher 1.8.7, `@anthropic-ai/mcpb` 2.1.2 (through the registry), skopeo 1.9.3, Node 22.23.4, npm 10.9.9 |

## Artifact Keeper bugs

### F1. A Remote never pins npm packages pulled through npm-remote

**What happens.** `mcp-upstream` maps `npm` to `npm-remote`, a Remote of npmjs.org. The upstream
entries `io.github.modelcontextprotocol/server-everything@2.1.0` and `server-memory@2.0.1` name
npm packages. The auto-approve glob approves both, and the first sync ingests them as
unresolved, as documented:

```text
{"name":"io.github.modelcontextprotocol/server-everything","status":"approved","ingested":[{"version":"2.1.0","unresolved":["mcp_package_not_found"]}]}
detail: packages[0]: npm @modelcontextprotocol/server-everything@2.1.0 is not in repository 'npm-remote'; pull it through this repository first
```

Following that advice changes nothing. After `npm pack` of both packages through
`https://ak.internal/npm/npm-remote/` (the proxy cache then holds
`@modelcontextprotocol/server-everything/-/server-everything-2.1.0.tgz` with its sha256), the
next sync reports `"reResolved":0` and both versions stay `unresolvable`, so neither is ever
served.

**Why.** In the code at `3a73f81e`, the Remote sync pins packages with
`services/mcp_remote.rs::pin_packages`, used at ingest and by `re_resolve`. It calls
`mcp_packages::resolve_package`, which looks only at `artifacts` rows. A package pulled through
a Remote npm, PyPI, NuGet or Cargo repository is a `proxy_cache_artifacts` row. Only the
hosted publish path (`mcp_resolver::resolve_document` with `cached_pin`) looks there. Images
work, because an OCI pull-through writes manifest rows to `artifacts`:
`io.github.github/github-mcp-server@2.1.0` is served pinned to its digest through `oci-ghcr`.

**Effect.** A Remote MCP repository serves no npm- or PyPI-packaged upstream server. On the
public registry, that is most stdio servers. The gate reports this check as
`BLOCKED(ak-fix)`.

## Documentation gaps

### D1. The namespace-grant example uses a principal type that is refused

`docs/mcp-registry.md` ("Namespace grants") shows `"principal_type": "service_account"` for the
account `mcp-publisher login github-oidc` becomes. For a CI OIDC mapping's account,
`POST /api/v1/permissions` answers:

```text
400 {"code":"VALIDATION_ERROR","message":"principal_id ... does not exist as a service_account"}
```

The mapping creates its account as a `users` row with `is_service_account = false`, and the
permission check tells the two types apart by that flag. `"principal_type": "user"` works, as
the backend's own test (`tests/mcp_auth_namespaces_tests.rs`) uses. The CI OIDC docs call it a
service account throughout. [Step 5](5-publish-from-ci.md) uses `user`.

### D2. A bundle-only server cannot rely on the automatic package entry

The docs say a document with no `mcpb` entry gets one `packages[]` entry per uploaded bundle.
A server whose only installation is a bundle has no `packages`, `remotes` or `websiteUrl`, and
is refused before that step:

```text
400 mcp_invalid_server_json: a server needs `packages`, `remotes` or a `websiteUrl` describing its installation
```

[Step 7](7-bundles-and-capabilities.md) publishes the upload response's `packageEntry` as
`packages[0]` instead, which works.

### D3. Read responses carry `Access-Control-Allow-Credentials: true`

The docs say the read routes answer CORS "without credentials". The `OPTIONS` preflight is as
documented. A `GET` with a token answers both `access-control-allow-origin: *` and
`access-control-allow-credentials: true`; the global CORS layer adds the second header when
`CORS_ORIGINS` is set. Browsers ignore the pair for requests without cookies, so VS Code and
Copilot are not affected, but the answer differs from the docs.

## Behaviour worth knowing

### O1. A Virtual npm mapping fills missing internal packages from upstream

The first clean run mapped `npm` on `mcp-internal` to the Virtual `npm` (`npm-internal` and
`npm-remote`). The npm publish of `@acme/tickets-mcp@1.0.0` had failed (an `.npmrc` mistake in
the walkthrough: npm matches a token to a registry by its exact path). `/validate` answered
`outcome: fill, fillRepository: npm-remote`, the publish answered `202 resolving`, and the
resolver asked npmjs.org for `@acme/tickets-mcp@1.0.0`, got a 404 and failed the version:

```text
MCP resolver: version failed to resolve ... code="mcp_package_not_found" detail=npm @acme/tickets-mcp@1.0.0 does not exist upstream
```

Two consequences. With a Virtual mapping, a missing internal package is looked for on the
public registry, which is a dependency-confusion path if your scope is not reserved there. And
one early publish uses up `name@version` for good (the tombstone). The walkthrough now maps
`npm` to the Local `npm-internal`, and `flows/publish.sh` refuses to publish unless `/validate`
says every package is `pinned`. `mcp-publisher publish` also reports the `202` as an error
(`Error: publish failed: server returned status 202`), as the pull request notes.

### O2. In a private registry every reader sees why a version is held

A reader with `read` granted on the repository is a "holder": an exact read of a held version
answers `404` with the reason (`mcp_backing_artifact_blocked`, `mcp_rejected`,
`mcp_pending_review`), not the plain unknown-name body. Clients only look at the status, so
`404` still means "not in the registry". Only anonymous readers of a public registry, or users
without a grant, get the plain body. A name nobody approved was never ingested, so it is the
plain `404` for everyone, the admin included.

### O3. The reference servers are not in the public registry

On 2026-11-04, `registry.modelcontextprotocol.io` had about 40,000 server versions and none
under `io.github.modelcontextprotocol`, so the glob `io.github.modelcontextprotocol/*` would
approve nothing there. The lab registry's fixtures include two such names, with their real npm
packages.

### O4. The web gallery lists a server once per repository

`/mcp-servers` shows "Servers from every MCP registry you can read": `com.acme/tickets` appears
from `mcp-internal` and again from the Virtual `mcp`. Each card names its repository.

## What was not machine-verified

| Check | Why | What was verified instead |
|---|---|---|
| VS Code installs `com.acme/tickets` from its gallery | needs a person in VS Code | the requests the gallery sends (`/v0.1/servers`, `/versions/latest`), and the install command run by Claude Code and `mcp-call` (G3) |
| Copilot accepts the registry under "Registry only" | needs a GitHub organization and a person | the CORS preflight Copilot checks, and the listing (G3) |
| A real GitHub Actions job publishes | the lab has no runner that can reach `ak.internal` | the same `mcp-publisher login github-oidc` and `publish`, with the Actions token environment and an ID token from a lab key that Artifact Keeper trusts as `https://token.actions.githubusercontent.com` (G7) |
| Claude Code uses the server in a session | needs an Anthropic login | `claude mcp list` starts the server and reports it connected; `mcp-call` calls a tool |
| The sandboxed `tools/list` probe | needs gVisor or a microVM runtime | not attempted |
