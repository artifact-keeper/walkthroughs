# Step 1: Stand up the registry

--8<-- "includes/preview-1.12.md"

The registry runs as its own compose project, `ak-agents`, on a podman network of the same
name. Two decisions shape everything after this page.

**The registry has a bare hostname and TLS.** Clients reach it as `https://ak.internal`, on
port 443 inside the network, with a certificate from Caddy's internal CA (Caddy is the reverse
proxy in front of Artifact Keeper). This is not decoration: Claude Code downloads plugin
archives only over `https` and refuses loopback addresses, and no security team accepts
tokens sent over plain HTTP. The backend is told its public name with
`AK_EXTERNAL_URL=https://ak.internal`, so every URL it writes into a marketplace document is
`https://ak.internal/...` whichever port a request came in on.

**Every client is a container on that network.** The "developer workstation" in
[Step 4](4-install-in-claude-code.md) and [Step 5](5-install-in-cursor-codex-copilot.md) is a
container attached to `ak-agents-net`, where `ak.internal` resolves because the Caddy
container carries that network alias. The only host port is `127.0.0.1:30447`, for you, the
web UI and the host-side scripts.

```console
$ make registry-up
up.sh: generating .../registry/.env
up.sh: backend=ghcr.io/artifact-keeper/artifact-keeper-backend:sha-c3a650e web=ghcr.io/artifact-keeper/artifact-keeper-web:dev
 ...
 Container ak-agents-caddy Started
up.sh: waiting for Caddy's internal CA  .../registry/out/ak-internal-ca.crt (subject=CN=Caddy Local Authority - 2026 ECC Root)
up.sh: waiting for https://ak.internal:30447/readyz . ready
backend image 7934e69f5fda... rev=c3a650e10235c723f9432ac381633449acaddda1
```

From the host, the scripts talk to the registry by its real name with
`curl --resolve ak.internal:30447:127.0.0.1 --cacert registry/out/ak-internal-ca.crt`
(`akcurl` in [`registry/lib.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/registry/lib.sh)), so SNI, the Host header and certificate
verification are what a client on the network sees. No `/etc/hosts` edit.

The stack is the upstream `docker-compose.yml`, unmodified, plus
[`registry/compose/compose.override.yml`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/registry/compose/compose.override.yml): containers
are renamed `ak-agents-*` so the project can share a host, Postgres and OpenSearch publish no
ports, Trivy and OpenSCAP are off (Grype, bundled in the backend image, scans every upload), and
`BACKEND_IMAGE` / `WEB_IMAGE` in `registry/.env` pick the images. The
[`Caddyfile`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/registry/caddy/Caddyfile) routes `/agentplugins/*`, `/api/*`, `/general/*`
and the health endpoints to the backend and everything else to the web UI, and it rewrites the
token out of `/agentplugins/t/<token>/...` in its access log
([Step 8](8-prove-it-fails-safely.md) checks that).

## The repositories

[`registry/bootstrap.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/registry/bootstrap.sh) creates everything through the REST API and
can be re-run; the second run reports each object as existing.

| Repository | Format | Visibility | Purpose |
|---|---|---|---|
| `agent-plugins` | `agentplugins` | private | the internal plugins; scan on upload, and a scan policy that serves nothing unscanned |
| `agent-plugins-public` | `agentplugins` | public | plugins anyone may install, to show the anonymous route |
| `trust` | `generic` | public | the internal CA certificate, so a new machine can fetch the one thing it needs before it trusts anything else |

`agentplugins` repositories are hosted only: there is no upstream marketplace protocol to
proxy, so creating a `remote` or `virtual` one is refused with `400`. `private` means a
request needs a credential with a permission on the repository; anonymous requests get `401`.

```bash title="registry/bootstrap.sh (abridged)"
create_repo agent-plugins '{"key":"agent-plugins","name":"Internal agent plugins",
  "description":"Plugins for AI coding agents, published by the platform team",
  "format":"agentplugins","repo_type":"local","visibility":"private"}'
api PUT /repositories/agent-plugins/security -d '{"scan_enabled":true,"scan_on_upload":true}'
api POST /security/policies -d '{"name":"agent-plugins-release","repository_id":"<id>",
  "max_severity":"high","block_unscanned":true,"block_on_fail":true}'
```

The scan policy is what [Step 7](7-govern.md) is about: `block_unscanned` keeps a version out
of every marketplace document, and refuses its download, until its scan has completed.

## Users and tokens

Three credentials, each doing one job. All three are repository tokens: scoped to
`agent-plugins` alone, with an expiry, stored in `registry/.tokens/` (gitignored, mode 600).

| Token | Minted by | Scopes | Used for |
|---|---|---|---|
| `ci.token` | user `ci` (permission: read, write on `agent-plugins`) | `read:artifacts`, `write:artifacts` | publishing, as CI would |
| `developer.token` | user `developer` (permission: read on `agent-plugins`) | `read:artifacts` | every install on the workstation |
| `public-ci.token` | admin | `read:artifacts`, `write:artifacts` on `agent-plugins-public` | publishing the public plugin; also shows a token cannot cross repositories |

Each user mints its own token, for two reasons. A non-admin can only delegate what it holds
itself, so the token can never exceed the user's permission. And the registry records the
minting user as the actor of every request made with the token: the publish record says `ci`,
the download records say `developer` ([Step 7](7-govern.md)). A token minted by an admin would
put `admin` on every publish.

```console
$ make bootstrap
bootstrap: repo agent-plugins created: {"format":"agentplugins","repo_type":"local","visibility":"private"}
bootstrap: repo agent-plugins-public created: {"format":"agentplugins","repo_type":"local","visibility":"public"}
bootstrap: repo trust created: {"format":"generic","repo_type":"local","visibility":"public"}
bootstrap: agent-plugins: scan_enabled, scan_on_upload
bootstrap: policy agent-plugins-release on agent-plugins: {"max_severity":"high","block_unscanned":true,"block_on_fail":true}
bootstrap: minted public-ci.token (repository token on agent-plugins-public: read+write, 30 days)
bootstrap: created user ci (...)
bootstrap: granted ci ["read","write"] on agent-plugins
bootstrap: minted ci.token (user ci, repository token on agent-plugins: ["read:artifacts","write:artifacts"], 30 days)
bootstrap: created user developer (...)
bootstrap: granted developer ["read"] on agent-plugins
bootstrap: minted developer.token (user developer, repository token on agent-plugins: ["read:artifacts"], 30 days)
bootstrap: uploaded trust/ak-internal-ca.crt
```

What each credential can do on `agent-plugins`, from gate G1:

| Credential | Read the marketplace | Publish |
|---|---|---|
| none | `401` | `401` |
| `developer.token` | `200` | `403` |
| `public-ci.token` (another repository) | refused | refused |
| `ci.token` | `200` | `201` |

## The workstation image

`make client` builds `localhost/ak-agents/workstation:latest` from
[`client/Containerfile`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/client/Containerfile) with the pins in
[`client/VERSIONS`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/client/VERSIONS): Node 22, Claude Code, Codex and the Copilot CLI from
npm, the Cursor CLI from its installer, `ak`, and the CA in the system trust store. Details,
including which certificate settings each agent honours, are on the
[client settings](reference/client-settings.md) page.

## The web UI

`make screens-ready` prints the address, `https://127.0.0.1:30447`, and where the admin
password is. The certificate is from the stack's own CA, so either trust
`registry/out/ak-internal-ca.crt` in your browser or accept the warning. Each
`agentplugins` repository has a setup tab with the Claude Code `marketplace add` URL, the
token-in-path form, and the `ak agent plugins` commands.

Next: [Step 2, author the plugins](2-author-the-plugins.md).
