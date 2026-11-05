# Step 1: Stand up the registry

--8<-- "includes/preview-mcp.md"

This step starts Artifact Keeper with TLS under one name, `https://ak.internal`, creates the
repositories the rest of the walkthrough uses, and mints the tokens for a CI publisher and a
developer. It also starts the lab registry that stands in for the public MCP registry in
[Step 3](3-curate-the-public-registry.md).

```bash
make registry-up   # the stack, the CA, the lab registry
make bootstrap     # repositories, scan policy, users, tokens
make client        # the workstation image
```

## The stack

`registry/compose/docker-compose.yml` is Artifact Keeper's own compose file, copied unmodified
([`VERSIONS`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/registry/compose/VERSIONS)
records where from). Every change lives in
[`compose.override.yml`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/registry/compose/compose.override.yml):
the images, an `ak-mcp-` prefix on every container, one network (`ak-mcp-net`), and Caddy
answering as `ak.internal` with a certificate from its internal CA on `127.0.0.1:30448`. Four
backend settings matter for MCP:

| Setting | Why |
|---|---|
| `AK_EXTERNAL_URL=https://ak.internal` | Every coordinate the registry hands a client (an npm `registryBaseUrl`, an image reference, a bundle URL) is built from it. A client must be able to fetch from that name. |
| `AK_SSRF_ALLOW_PRIVATE_CIDRS=<lab IP>/32` | The Remote repository's upstream is the lab registry at `.200` of the stack network, a private address the SSRF guard refuses by default. Only that one address is let through. Against the real public registry you need nothing here. |
| `MCP_TRUSTED_BUNDLE_SIGNERS` | The SHA-256 fingerprint of the certificate allowed to sign MCPB bundles ([Step 7](7-bundles-and-capabilities.md)). `up.sh` generates a lab signer and writes its fingerprint before the backend starts. |
| `MCP_RESOLVER_INTERVAL_SECS=5` | How often a package missing from a Remote backing repository is filled. The default is 15 s. |

`registry/up.sh` generates `registry/.env` with fresh secrets on the first run, exports
Caddy's root certificate to `registry/out/ak-internal-ca.crt`, and waits for `/readyz`.
`lab-registry/up.sh` then starts
[`lab-registry/server.py`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/lab-registry/server.py),
a read-only implementation of the registry API v0.1 in the Python standard library, serving
ten fixture entries at `http://172.31.76.200:8080`.

```console
$ make registry-up
up.sh: backend=localhost/ak-backend:mcp-c89f9cea web=localhost/ak-web:mcp-89313d4
...
up.sh: waiting for https://ak.internal:30448/readyz .. ready
{"status":"healthy","version":"1.11.3"}
lab-registry on :8080 serving /srv/servers
lab-registry: 10 server versions at http://172.31.76.200:8080
```

The backend reports `1.11.3` because the pull request branch has not bumped the version.

## Repositories

[`registry/bootstrap.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/registry/bootstrap.sh)
creates these, all private:

| Key | Format, type | Role |
|---|---|---|
| `npm-internal` | npm, Local | Acme's own npm packages: the code of internal MCP servers |
| `npm-remote` | npm, Remote of `registry.npmjs.org` | npm packages from outside, pulled through and cached |
| `npm` | npm, Virtual (`npm-internal`, `npm-remote`) | one npm URL for tools such as the `mcpb` CLI |
| `oci-internal` | docker, Local | images of internal MCP servers |
| `mcp-internal` | mcp, Local | the private registry |

`mcp-internal` is created with its MCP settings in the same request:

```json
{"key": "mcp-internal", "format": "mcp", "repo_type": "local", "visibility": "private",
 "mcp_package_policy": "own-repos",
 "mcp_package_repos": {"npm": "npm-internal", "oci": "oci-internal"},
 "mcp_namespace_allow": ["com.acme"]}
```

- **`own-repos`** (the default) means a server is accepted only if every package it runs is
  already in this Artifact Keeper, in the repository mapped for its type. The publish pins the
  package's version (and an image's digest) and every read serves Artifact Keeper's
  coordinates for it. [Step 4](4-supply-chain-gates.md) shows what that refuses.
- **`mcp_package_repos`** maps `npm` to the Local `npm-internal`, not to the Virtual `npm`.
  With a Virtual mapping, a package that is missing from the Local member is looked for in the
  Remote member, on npmjs.org, which is not where an internal package should ever come from
  ([lab notes, O1](findings.md#o1-a-virtual-npm-mapping-fills-missing-internal-packages-from-upstream)).
- **`mcp_namespace_allow`** keeps every name under `com.acme` (`com.acme/x` and
  `com.acme.team/x`, not `com.acmecorp/x`).

A scan policy, `mcp-internal-review`, holds any version with a finding of severity `high` or
worse. The MCP lint writes its `review` findings as `high`, so a tool description that reads
like a prompt injection is held until someone looks at it ([Step 4](4-supply-chain-gates.md)).

```console
bootstrap: repo mcp-internal created: {"format":"mcp","repo_type":"local","visibility":"private"}
bootstrap: mcp-internal settings: {"mcp_package_policy":"own-repos","mcp_package_repos":{"npm":"npm-internal","oci":"oci-internal"},"mcp_namespace_allow":["com.acme"]}
bootstrap: policy mcp-internal-review on mcp-internal: {"max_severity":"high","block_unscanned":false,"block_on_fail":true}
```

## Users and tokens

Two non-admin users, each with an API token in `registry/.tokens/` (mode 600, gitignored):

| User | Permissions | Token scopes | Stands for |
|---|---|---|---|
| `ci` | read and write on `mcp-internal`, `npm-internal`, `oci-internal`; read on `npm`, `npm-remote` | `read:artifacts`, `write:artifacts` | a pipeline that publishes with a stored token |
| `developer` | read on every repository | `read:artifacts`, `read:repositories` | a developer's workstation (and asking for approvals) |

[Step 5](5-publish-from-ci.md) replaces the stored CI token with GitHub Actions OIDC.

There is no separate registry login: any Artifact Keeper credential is the bearer token on
`/mcp/<repo>/...`, and an anonymous read of a private registry is `401`.

## The workstation

`make client` builds `localhost/ak-mcp/workstation:latest` from
[`client/Containerfile`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/client/Containerfile):
Node 22, Claude Code from npm, `mcp-publisher` from its GitHub release (SHA-256 checked),
skopeo, a 60-line MCP client (`mcp-call`) and the internal CA. Every client command in this
walkthrough runs in it, on `ak-mcp-net`, with a throwaway home and a token passed through the
environment.

```console
node           v22.23.4
claude         2.1.318 (Claude Code)
skopeo         skopeo version 1.9.3
mcp-publisher  mcp-publisher 1.8.7 (commit: 741d575fc2ffe774fa51f442ec6fb2987dd03e18, built: 2026-10-30T11:24:40Z)
```

Next: [Step 2, a private registry for internal servers](2-a-private-registry.md).
