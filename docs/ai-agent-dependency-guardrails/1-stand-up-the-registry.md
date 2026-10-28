# Step 1: Stand up the registry

This page starts Artifact Keeper 1.11.7 behind a bare hostname with TLS, creates the
repositories the agent will use, and mints one token per role.

**Make targets:** `make registry-up lab-up bootstrap`, which run
[`registry/up.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/registry/up.sh),
[`lab-upstream/up.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/lab-upstream/up.sh) and
[`registry/bootstrap.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/registry/bootstrap.sh).

## The stack

The upstream `docker-compose.yml` from the v1.11.7 tag is vendored unchanged; every change lives
in [`registry/compose/compose.override.yml`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/registry/compose/compose.override.yml):

- the images are pinned to the releases, `artifact-keeper-backend:1.11.7` and
  `artifact-keeper-web:1.11.1` (digests in `registry/compose/VERSIONS`);
- every container name is prefixed `ak-agent-`, so the stack runs next to other Artifact Keeper
  stacks on the same host;
- two networks: `ak-agent-net`, where the backend lives and which reaches the internet (it has to,
  to proxy PyPI and npm), and `agent-net`, which is `internal: true` and has no route out;
- Caddy answers as `ak.internal` on both, with TLS from its own internal CA. It is the only
  container on `agent-net` besides the agent. The only host port is `127.0.0.1:30445`. Nothing
  listens on port 80, and of npm's `/-/` endpoints only the ones the clients use are exposed (G11);
- every image, including the sandbox's base images, is pinned by digest.

`up.sh` generates the secrets into `registry/.env` on the first run, waits for `/readyz`, and
exports Caddy's root certificate to `registry/out/ak-internal-ca.crt`.

```text
up.sh: waiting for https://ak.internal:30445/readyz . ready
{"status":"ready","checks":{"database":{"status":"healthy"},"migrations":{"status":"healthy"},...}}
backend f41fdd75... rev=65c16c4534d835a40118527b842e87a9edaaf2d9
```

## Repositories

| Repository | Type | What it is |
|---|---|---|
| `pypi-internal` | hosted | internal Python packages; CI publishes here |
| `pypi-remote` | remote | `https://pypi.org` |
| `pypi-virtual` | virtual | `pypi-internal` (priority 1), then `pypi-remote` (2): **the only index the agent knows** |
| `npm-internal` | hosted | internal npm packages, scope `@acme` |
| `npm-remote` | remote | `https://registry.npmjs.org`, with an upstream filter that refuses `@acme/*` |
| `npm-virtual` | virtual | `npm-internal` (1), then `npm-remote` (2), hosted names isolated: **the only npm registry the agent knows** |
| `pypi-lab`, `npm-lab` | remote | the lab upstream (below) |
| `pypi-lab-virtual`, `npm-lab-virtual` | virtual | internal (1), then the lab (2): used by the cooldown and name-squat tests |
| `oci-dockerhub`, `oci-ghcr` | remote | the base images of the agent sandbox |
| `trust` | generic, public | the internal CA certificate |

Every repository except `trust` (public, so clients can fetch the CA) has visibility `internal`
(any signed-in user may read) and every token narrows
that to the repositories it needs. With `private`, a non-admin token is told the repository does
not exist ([findings](findings.md#what-we-learned-building-it)).

The member priorities are explicit on purpose: a hosted member hides a remote's versions of the
same name only when its priority number is lower ([Step 6](6-own-your-names.md)).

## The lab upstream

Two tests need a public index whose contents we control: a release published minutes ago, and a
public package that reuses an internal name.
[`lab-upstream/server.py`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/lab-upstream/server.py)
is a standard-library Python server, about 200 lines, that serves a PyPI simple index (HTML and
JSON, with upload times), the PyPI JSON API and npm packuments and tarballs. Every package it
serves is generated on start and only prints a line. Publish times are relative to server start:

| Package | Versions | Published |
|---|---|---|
| `lab-agent-sdk` (PyPI) | 1.0.0, **1.1.0** | 60 days ago, **10 minutes ago** |
| `lab-mcp-weather` (npm) | 2.0.0, **2.1.0** | 60 days ago, **10 minutes ago** |
| `acme-agent-tools` (PyPI) | 99.0.0 | 400 days ago: reuses the internal name |
| `@acme/tickets-mcp` (npm) | 99.0.0 | 400 days ago: reuses the internal name |

It runs at `172.31.50.200:8080` on `ak-agent-net`. Artifact Keeper refuses upstreams on private
addresses by default; `AK_SSRF_ALLOW_PRIVATE_CIDRS=172.31.50.200/32` allows exactly this one.

The lab remotes sit in their own virtuals rather than as a third member of the main ones,
because in 1.11.7 a virtual with two age-gated remotes refuses a package that only the second
one serves ([F10](findings.md#f10-in-detail)).

## Tokens

| Token | Who | Can |
|---|---|---|
| `agent.token` | user `agent` | `read:artifacts` on the four virtuals, nothing else |
| `ci-pypi.token`, `ci-npm.token` | CI | read and write on `pypi-internal` or `npm-internal` only |
| `builder.token` | user `builder` | `read:artifacts` on the two image proxies (sandbox base images) |
| `admin.token` | admin | everything, 90 days; used by the setup scripts only (on a 401 they say `run make bootstrap`) |

They are written to `registry/.tokens/` (mode 600, gitignored). The agent's token is minted by the
`agent` user itself with a repository selector:

```console
$ curl … -X POST https://ak.internal/api/v1/auth/tokens \
    -d '{"name":"agent-read","scopes":["read:artifacts"],"expires_in_days":90,
         "repo_selector":{"match_repos":["<pypi-virtual id>","<npm-virtual id>", …]}}'
```

`bootstrap.sh` is idempotent: run it again and it reports what exists and mints only what is
missing or expired.

**Next:** [Step 2: Put the agent in a sandbox](2-sandbox-the-agent.md).
