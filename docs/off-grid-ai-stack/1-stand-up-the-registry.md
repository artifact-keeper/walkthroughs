# Step 1: Stand up the registry

--8<-- "includes/preview-offgrid.md"

This step starts Artifact Keeper with TLS under one name, `https://ak.internal`, starts the
egress ledger, creates every repository the AI stack will be served from with its offline
settings already in place, and mints the tokens the later steps use.

```bash
cd walkthroughs/off-grid-ai-stack
make registry-up   # registry/up.sh, then ledger/up.sh
make bootstrap     # registry/bootstrap.sh
```

## Images

The backend and the scanner adapter must be a build of Artifact Keeper `main` at or after
`f0d9b638` (or 1.12.0 once released). When this walkthrough was built, the CI `:dev` images were
older than that (the amd64 builds on CI were failing), so the defaults in
[`registry/.env.example`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/registry/.env.example)
are local builds. In a checkout of `artifact-keeper` at the commit you want:

```bash
podman build -f docker/Dockerfile.backend -t localhost/ak-backend:offgrid-0bffa44c .
podman build -f docker/Dockerfile.scanner-adapter -t localhost/ak-scanner-adapter:offgrid-0bffa44c .
```

Once a `:dev` image built from `f0d9b638` or later exists, set `BACKEND_IMAGE` and
`SCANNER_ADAPTER_IMAGE` in `registry/.env` to it, pinned by digest, or pass
`AK_BACKEND_IMAGE=...` and `AK_SCANNER_ADAPTER_IMAGE=...` for one run. `registry/up.sh` refuses
to start if a `localhost/...` image is not in podman's image store.

<!-- REFRESH: the final run's images (registry/compose/VERSIONS) and the tag names above if the final run uses a different build. -->

## The stack

[`registry/compose/docker-compose.yml`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/registry/compose/docker-compose.yml)
is Artifact Keeper's own compose file, copied unmodified
([`VERSIONS`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/registry/compose/VERSIONS)
records where from). Every change lives in
[`compose.override.yml`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/registry/compose/compose.override.yml):
the images from `registry/.env`, an `ak-offgrid-` prefix on every container, Caddy answering as
`ak.internal` with a certificate from its internal CA on `127.0.0.1:30450`, Trivy (the server)
and openscap turned off, and the scanner adapter in offline mode. Two networks:

| Network | Subnet | When |
|---|---|---|
| `ak-offgrid-seed` | `172.31.84.0/24` | Steps 1 to 3: the stack has a route out, through the ledger |
| `ak-offgrid-site` | `172.31.85.0/24`, `internal: true` | From [Step 4](4-disconnect.md) on: no gateway, no route out ([`compose.site.yml`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/registry/compose/compose.site.yml)) |

On either network the backend has the fixed address `.250` and the egress ledger `.200`.
`registry/out/phase` says which network the stack is on (`seed` or `site`), and every script
reads it. Backend settings that matter here:

| Setting | Why |
|---|---|
| `AUDIT_UPSTREAM_FETCHES=all` | Every request a Remote sends upstream is an `UPSTREAM_FETCHED` audit row ([#5316](https://github.com/artifact-keeper/artifact-keeper/pull/5316)). This is the per-request record of the seed window, and the record that must stay empty after the cut. |
| `AK_SSRF_ALLOW_PRIVATE_CIDRS=172.31.84.250/32,172.31.85.250/32` | The `plugins` Remote's upstream is this instance's own hosted marketplace (see below), a private address the SSRF guard refuses by default. Only the backend's own address is let through, on each network. |
| `SCANNER_OFFLINE=true` (scanner adapter) | The adapter never downloads a vulnerability database; it gets one imported ([Step 3](3-vet-what-you-seeded.md), [#5314](https://github.com/artifact-keeper/artifact-keeper/pull/5314)). |

The [Caddyfile](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/registry/caddy/Caddyfile)
routes the API and the format routes the stack uses (`/v2`, `/pypi`, `/npm`, `/huggingface`,
`/mcp`, `/agentplugins`) to the backend, and everything else to the web UI.

```console
$ make registry-up
...
up.sh: waiting for Caddy's internal CA  /.../off-grid-ai-stack/registry/out/ak-internal-ca.crt (subject=CN=Caddy Local Authority - 2026 ECC Root)
up.sh: waiting for https://ak.internal:30450/readyz . ready
{"status":"healthy","version":"1.11.3"}
backend image 403e088c9006642e462c417927b37607d23c93ef72d772091bba2ab462e24b17
```

<!-- REFRESH: these four lines are from the debug run's restart of the stack inside make disconnect (the same up.sh); no make registry-up output was kept. Paste the final run's full output (the "up.sh: phase=seed network=ak-offgrid-seed backend=..." line and the "ledger: http://172.31.84.200:3128 (alias egress-ledger) on ak-offgrid-seed; ..." line). -->

`main` still reports `1.11.3`; the next release is 1.12.0. From the host, reach the registry by
its real name through the loopback port:

```console
$ curl -fsS --resolve ak.internal:30450:127.0.0.1 --cacert registry/out/ak-internal-ca.crt \
    https://ak.internal:30450/health | jq -c '{status, version}'
{"status":"healthy","version":"1.11.3"}
```

## The egress ledger

[`ledger/server.py`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/ledger/server.py)
is a logging forward proxy in about 170 lines of Python standard library. Every Remote's egress
proxy is set to it (`http://egress-ledger:3128`, mode `explicit`), so every connection Artifact
Keeper opens to an upstream passes through it and is written to `out/ledger/ledger.jsonl`, one
JSON line per event. It does not filter and it does not decrypt TLS:

- for `CONNECT host:443` (an https upstream) it writes an `open` line when the request arrives,
  **before** it tries to connect, and a `close` line when the tunnel ends, with the bytes each
  way;
- for a plain `GET http://host/path` (the `plugins` Remote) it writes the path too, and the
  status.

Because the `open` line comes first, an attempt that cannot get out (the site network has no
route) is still a line, with `"result": "connect_failed"` on its `close` line. An early version
wrote only the `close` line, so a tunnel showed up only when it ended; it now writes both.

The ledger counts **connections, not requests**. Artifact Keeper keeps connections to an
upstream open and sends many requests over one tunnel; in the debug run, from the start of the seed to the gates, `pypi-remote`
made 218 requests to pypi.org and files.pythonhosted.org (218 audit rows) over 8 ledger
connections. The `UPSTREAM_FETCHED`
audit rows are the per-request record; the ledger is the independent one, outside the process
being audited.

The ledger's image is `python:3.12-alpine`, pulled from Docker Hub directly and pinned in
[`ledger/VERSIONS`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/ledger/VERSIONS):
it is lab equipment that watches Artifact Keeper, not something Artifact Keeper serves.

## Repositories

[`registry/bootstrap.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/registry/bootstrap.sh)
creates thirteen repositories. Seven Remotes:

| Key | Format | Upstream | Serves |
|---|---|---|---|
| `oci-dockerhub` | docker | `https://registry-1.docker.io` | the `python` and `node` base images |
| `oci-ghcr` | docker | `https://ghcr.io` | the llama.cpp server image, the trivy database |
| `pypi-remote` | pypi | `https://pypi.org` | `openai`, `mcp`, `huggingface_hub`, `mcp-sqlite3` and their dependencies |
| `npm-remote` | npm | `https://registry.npmjs.org` | Claude Code ([Step 6](6-claude-code-best-effort.md)) |
| `hf-hub` | huggingface | `https://huggingface.co` | the model, pinned to a commit |
| `mcp-official` | mcp | `https://registry.modelcontextprotocol.io` | approved public MCP servers; packages resolve through `pypi-remote` |
| `plugins` | agentplugins | `http://ak-central:8080/agentplugins/plugins-central` | the agent's plugin, proxied from the "central" marketplace ([#5334](https://github.com/artifact-keeper/artifact-keeper/pull/5334)) |

and six hosted and virtual repositories:

| Key | Format, type | Role |
|---|---|---|
| `pypi-local` | pypi, Local | Acme's own MCP server package, `acme-inventory-mcp` |
| `pypi` | pypi, Virtual | `pypi-local` first, then `pypi-remote`: what pip uses |
| `hf-models` | huggingface, Local | the vetted model: scanned on upload, served only once scanned ([Step 3](3-vet-what-you-seeded.md)) |
| `mcp-internal` | mcp, Local | Acme's MCP entry `com.acme/inventory`; package policy `own-repos` (`pypi-local`), namespace `com.acme` only |
| `mcp-all` | mcp, Virtual | `mcp-internal` first, then `mcp-official`: what the agent reads |
| `plugins-central` | agentplugins, Local | the marketplace the `plugins` Remote proxies |

### The plugins Remote proxies this instance

The lab has one Artifact Keeper. The `plugins` Remote stands in for a site that reads a central
instance's marketplace: its upstream is this instance's own `plugins-central`, over the
backend's port on the compose network, with the token of a user `site-sync` who can read
`plugins-central` and nothing else. The upstream host is `ak-central`, a network alias of the
backend container. The obvious name, `backend`, is refused: it is on the backend's upstream
hostname blocklist (`backend/src/api/validation.rs`). On [Next steps](next-steps.md) the same
Remote points at a real central instance.

### Offline settings, set at creation

Every Remote gets four settings in the same run that creates it, before anything is cached:

```bash
PUT /api/v1/repositories/<remote>/cache-ttl             {"cache_ttl_seconds": 315360000}
PUT /api/v1/repositories/<remote>/on-upstream-not-found {"on_upstream_not_found": "keep"}
PUT /api/v1/repositories/<remote>/stale-if-error-grace  {"stale_if_error_grace_seconds": 2592000}
PUT /api/v1/repositories/<remote>/egress-proxy          {"mode": "explicit", "proxy_url": "http://egress-ledger:3128"}
```

A raised cache-ttl applies to an entry only from its next revalidation
([the private model hub](../private-model-hub/7-freeze-and-go-offline.md#freeze-at-creation)
found this the hard way), so it is set before the first fetch. Cache-only mode is not set here:
the Remotes must fetch while seeding. That is [Step 4](4-disconnect.md).

### The jobs are paused while the Remotes are created

An MCP Remote starts syncing the upstream registry the moment it is created, before
`PUT .../egress-proxy` can run, so the first pages of that sync would go out directly and the
ledger would not see them
([artifact-keeper#5402](https://github.com/artifact-keeper/artifact-keeper/issues/5402)). The
current workaround: `bootstrap.sh` pauses the scheduled upstream jobs for the whole instance
([#5317](https://github.com/artifact-keeper/artifact-keeper/pull/5317)) before it creates any
repository, and resumes them at the end:

```bash
PATCH /api/v1/admin/settings/system {"upstream_jobs_paused": true}
...  every repository, the offline settings, users and tokens
PATCH /api/v1/admin/settings/system {"upstream_jobs_paused": false}
```

The fix, [#5406](https://github.com/artifact-keeper/artifact-keeper/pull/5406), lets a Remote be
created with its settings so that no sync starts before them; the pause can go once it lands.

### The vetting policy

`hf-models` scans every upload (`PUT .../security {"scan_enabled": true, "scan_on_upload":
true}`) and has a scan policy:

```json
{"name": "hf-models-vetted", "repository_id": "<hf-models>",
 "max_severity": "medium", "block_unscanned": true, "block_on_fail": true}
```

A file no scan has completed is not served, and neither is one with a finding of medium or
above.

## Users and tokens

| User | Token scopes | Grants | Used for |
|---|---|---|---|
| `admin` | `*` | admin | the scripts (`admin.token`, so they do not log in on every run: the login route is rate limited) |
| `developer` | `read:artifacts` | read on every repository | everything on the site: podman pulls, pip, `hf download`, the agent, Claude Code |
| `publisher` | `read:artifacts`, `write:artifacts` | read and write on `pypi-local`, `hf-models`, `mcp-internal`, `plugins-central`; read on `pypi`, `hf-hub` | publishing what Acme makes and the vetted model |
| `site-sync` | `read:artifacts` | read on `plugins-central` | the `plugins` Remote's upstream credential |

Tokens last 30 days and go to `registry/.tokens/` (gitignored, mode 700), with
`developer-podman.json`, a podman auth file for image pulls from the host. The host cannot
resolve `ak.internal`, so podman uses `localhost:30450`, for which Caddy issues a certificate
from the same CA (copied to `registry/out/certs.d/localhost:30450/ca.crt`).

```console
$ make bootstrap
```

<!-- REFRESH: no bootstrap output was kept from the debug run. Paste the final run's make bootstrap output (it prints "bootstrap: ..." lines: the jobs paused, each repository created with its format and upstream, the offline settings and egress proxy per Remote, each user and token, the podman auth file, the jobs resumed). Check that it prints no token. -->

`bootstrap.sh` is idempotent: run again, it reuses what exists and mints only tokens that no
longer work. It refuses to run once the stack is on the site network.
