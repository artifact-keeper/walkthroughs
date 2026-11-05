# A private MCP registry on Artifact Keeper

> **An example, not a complete defense.** This shows one way to run a private MCP registry on
> Artifact Keeper. The configuration is an example, built and tested in a lab. It does not cover
> every edge case or attack, and it is not a hardened production setup; known gaps are in the
> [findings](../docs/private-mcp-registry/findings.md). Review and adapt it for your
> environment, and use it alongside your other controls, not instead of them.

Code for the walkthrough at
[`docs/private-mcp-registry/`](../docs/private-mcp-registry/index.md) (lab notes in
[`findings.md`](../docs/private-mcp-registry/findings.md)).

**Needs Artifact Keeper `main`** (coming in 1.12.0) for the MCP Registry repository type:
[artifact-keeper#5257](https://github.com/artifact-keeper/artifact-keeper/pull/5257) (backend,
`main` at `4542321b`) and
[artifact-keeper-web#1077](https://github.com/artifact-keeper/artifact-keeper-web/pull/1077)
(web UI, `main` at `896a79db`). See [Images](#images).

Artifact Keeper runs as compose project `ak-mcp` on the podman network `ak-mcp-net` and answers
as `https://ak.internal` (TLS from Caddy's internal CA). A lab registry at `.200` of that
network stands in for `registry.modelcontextprotocol.io`. Every client (Claude Code,
`mcp-publisher`, npm, skopeo, the `mcpb` CLI) runs in the workstation container on that network
with a throwaway home under `out/homes/`. Nothing here needs sudo or an account.

| Directory | What |
|---|---|
| `registry/` | the stack (upstream compose + override), Caddy, `up.sh`, `bootstrap.sh` (repositories, scan policy, users, tokens), `clean.sh` |
| `lab-registry/` | a read-only MCP registry API v0.1 (`server.py`, standard library only) and its fixture entries |
| `servers/acme-tickets/` | the internal MCP server: npm package, `Containerfile`, `server.json`, MCPB `bundle/manifest.json` |
| `client/` | the workstation image (`Containerfile`, pins in `VERSIONS`), `run.sh`, `mcp-call.js` (a minimal MCP client) |
| `ci/` | `lab-issuer.sh`: a stand-in for GitHub's OIDC issuer; `publish-mcp.yml`, the workflow it stands in for |
| `flows/` | one script per make target from `publish` to `bundles` |
| `gates/` | G1-G9 as runnable checks: PASS / FAIL / BLOCKED |
| `screens/` | the web UI screenshots (Playwright) |

## Run it

```console
make all             # registry, bootstrap, client, publish, clients, curate, supply-chain, ci,
                     # virtual, bundles
make gates           # the nine gates; results in out/gates/
make screens         # web UI screenshots into out/screens/ (optional)
make screens-ready   # UI URL and credentials
make clean           # remove everything it created (keeps pulled and locally built images)
```

Requirements: rootless podman 5.x with `podman compose`, curl, jq, openssl, python3, GNU make,
and internet access (images, npmjs.org through the registry, ghcr.io through the registry). The
only host port is `127.0.0.1:30448` (Caddy 443). From the host, reach the registry by its real
name with `curl --resolve ak.internal:30448:127.0.0.1 --cacert registry/out/ak-internal-ca.crt`.

## Images

`registry/.env.example` names `localhost/ak-backend:mcp-c89f9cea` and
`localhost/ak-web:mcp-89313d4`, the builds of the pull request branches the reference run used,
because no backend `:dev` image built from `4542321b` or later existed yet. The branch gained
fixes before it merged (some for the [findings](../docs/private-mcp-registry/findings.md)), so
`main` is not the same code as `c89f9cea`, and the walkthrough has not been rerun on it. Use
one of these:

- **`:dev` from `main`** (preferred, once it exists): set `BACKEND_IMAGE` and `WEB_IMAGE` in
  `registry/.env` to `ghcr.io/artifact-keeper/artifact-keeper-backend:dev@sha256:...` and
  `ghcr.io/artifact-keeper/artifact-keeper-web:dev@sha256:...`, or pass `AK_BACKEND_IMAGE` /
  `AK_WEB_IMAGE` for one run. Check that each image's `org.opencontainers.image.revision`
  label is `4542321b` (backend) or `896a79db` (web), or a later `main` commit.
- **1.12.0 or later**, once released.
- **Local builds of `main`**, with the tags the file names:

  ```console
  git clone https://github.com/artifact-keeper/artifact-keeper
  podman build -f artifact-keeper/docker/Dockerfile.backend -t localhost/ak-backend:mcp-c89f9cea artifact-keeper
  git clone https://github.com/artifact-keeper/artifact-keeper-web
  podman build -t localhost/ak-web:mcp-89313d4 artifact-keeper-web
  ```

  The backend is a Rust build: give it a machine with plenty of memory.

The commits of the reference run are in `registry/compose/VERSIONS`; client pins are in
`client/VERSIONS`.

Secrets (never committed): `registry/.env`, `registry/.tokens/`, `registry/.signer/` (the lab
bundle signer), `out/ci/issuer.key` (the lab OIDC issuer). Outputs: `out/`, `registry/out/`
(the CA certificate), `client/.work/`.
