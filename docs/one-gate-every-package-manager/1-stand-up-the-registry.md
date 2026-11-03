# Step 1: Stand up the registry and the five clients

!!! danger "Draft, run against `main`"
    Output on this page is from the run of 2026-11-03 against the Artifact Keeper `main`
    image (revision `12808b8`), pending a re-run on the 1.12.0 candidate. See [Results](results.md).

One registry on a private network, five Remote repositories (one per package manager), and
five client containers that know only `https://ak.internal`. Nothing on this page is specific
to the gate; it is the plumbing every later step runs on.

**Make targets:** `make registry-up bootstrap images`.

## The stack

The stack is the upstream `docker-compose.yml` from artifact-keeper `main` plus an override
([`registry/compose/compose.override.yml`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/registry/compose/compose.override.yml)),
the same pattern as the conda and AI-agent walkthroughs: compose project `ak-gate`, every
container prefixed `ak-gate-`, one network (`ak-gate-net`, `172.31.60.0/24`), Caddy answering
as `ak.internal` with its internal CA, and one host port, `127.0.0.1:30446`, for humans and
the host-side scripts. Three things are switched off because this walkthrough does not use
them: Trivy and OpenSCAP (profile `scanners`) and Dependency-Track (profile `dtrack`). The
proxy gate grades packages with the engine bundled in the backend (Grype).

```console
$ make registry-up
registry/up.sh
up.sh: generating …/registry/.env
up.sh: backend=ghcr.io/artifact-keeper/artifact-keeper-backend:main web=ghcr.io/artifact-keeper/artifact-keeper-web:main
 Network ak-gate-net Creating
 …
up.sh: waiting for Caddy's internal CA  …/registry/out/ak-internal-ca.crt (subject=CN=Caddy Local Authority - 2026 ECC Root)
up.sh: waiting for https://ak.internal:30446/readyz . ready
{"status":"ready","checks":{"database":{"status":"healthy"},"migrations":{"status":"healthy"},"setup_complete":{"status":"complete"}},"dependencies":{"opensearch":{"status":"healthy","required":false},"storage":{"status":"healthy","required":false},"scanner":{"status":"not_configured","required":false},"ldap":{"status":"not_configured","required":false}}}
backend c21b0c989bf0… rev=12808b8694e4a529f2d3739bc2df759ee46d2ed9 digest=ghcr.io/artifact-keeper/artifact-keeper-backend@sha256:302343442240cfd1b19d942690d7db34845e5962e13fe372667e4de936b4dc88
web     73fbdc1be329… rev=0f89b1c5e474e92f9b9800fd76d8d6329fd84823 digest=ghcr.io/artifact-keeper/artifact-keeper-web@sha256:579cbc711f4bbeb9ac59c0acdd5c11741da96923c2e673e73a57d7ec25fe61b8
```

35 seconds from nothing to `/readyz` with the images already on the host. `scanner:
not_configured` in the readiness report means Trivy; the bundled engine does not appear there.
[`registry/up.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/registry/up.sh)
generates `.env` (JWT secret, webhook key, admin password) on the first run and exports the
CA to `registry/out/ak-internal-ca.crt`; every client container mounts that file.

## The repositories

[`registry/bootstrap.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/registry/bootstrap.sh)
is idempotent: it mints an admin API token once, creates what is missing, and leaves what
exists alone.

```console
$ make bootstrap
bootstrap: logged in as admin
bootstrap: minted admin.token (scopes *, 90 days) for the other scripts
bootstrap: repo go-proxy created: {"format":"go","repo_type":"remote","visibility":"public","upstream_url":"https://proxy.golang.org"}
bootstrap: repo cargo-proxy created: {"format":"cargo","repo_type":"remote","visibility":"public","upstream_url":"https://index.crates.io"}
bootstrap: repo npm-proxy created: {"format":"npm","repo_type":"remote","visibility":"public","upstream_url":"https://registry.npmjs.org"}
bootstrap: repo debian-proxy created: {"format":"debian","repo_type":"remote","visibility":"public","upstream_url":"https://deb.debian.org/debian"}
bootstrap: repo alpine-proxy created: {"format":"alpine","repo_type":"remote","visibility":"public","upstream_url":"https://dl-cdn.alpinelinux.org/alpine"}
bootstrap: repo npm-internal created: {"format":"npm","repo_type":"local","visibility":"internal","upstream_url":null}
bootstrap: npm-internal: scan_on_upload {"scan_enabled":true,"scan_on_upload":true}
bootstrap: policy npm-internal-gate created on npm-internal: {"max_severity":"high","block_unscanned":true,"block_on_fail":true}
bootstrap: minted ci-npm.token (repo token on npm-internal: read+write, 90 days)
bootstrap: done. Tokens in …/registry/.tokens (never commit). CA: …/registry/out/ak-internal-ca.crt
```

| Repository | Format | Upstream | Role |
|---|---|---|---|
| `go-proxy` | `go` | `https://proxy.golang.org` | `GOPROXY` for every Go build |
| `cargo-proxy` | `cargo` | `https://index.crates.io` | the sparse index and crate downloads; crates.io is replaced in the client config |
| `npm-proxy` | `npm` | `https://registry.npmjs.org` | the one npm registry |
| `debian-proxy` | `debian` | `https://deb.debian.org/debian` | the one apt source (bookworm, main) |
| `alpine-proxy` | `alpine` | `https://dl-cdn.alpinelinux.org/alpine` | the one apk repository (v3.22, main and community) |
| `npm-internal` | `npm`, hosted | | where a vendored package goes in [Step 5](5-handle-an-exception.md); scanned on upload, with a scan policy (`max_severity: high`, block unscanned, block on a failed scan) |

The five proxies are `public`: the clients read them anonymously, so each client needs only
its ordinary registry setting and the CA. The conda and AI-agent walkthroughs show per-client
tokens; the point here is the gate, and anonymous reads keep the client side to one file per
package manager. The consequence shows up in [Step 3](3-review-the-queues.md): the audit row of
a refused pull names the client's IP address, not a user.

Two things the bootstrap does **not** do, because the run showed they are not needed: a
Debian or Alpine Remote passes the upstream `InRelease` and `APKINDEX.tar.gz` through with
the upstream signature intact (its own `gpg-key.asc` and `<branch>/keys/` answer
`404 No signing key configured for this repository`), so apt and apk verify the indexes with
the keys their images already ship.

## The clients

Each package manager runs in its official image, started by
[`clients/run.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/clients/run.sh)
on `ak-gate-net`, with the CA at `/run/ak/ca.crt` and one configuration file from
[`clients/config/`](https://github.com/artifact-keeper/walkthroughs/tree/main/one-gate-every-package-manager/clients/config):

| Client | Image | Configuration | How the CA is trusted |
|---|---|---|---|
| `go` | `golang:1.26-alpine` | `GOPROXY=https://ak.internal/go/go-proxy`, `GOSUMDB=sum.golang.org` (reached through the proxy's `/sumdb/` route), `GOTOOLCHAIN=local` | `SSL_CERT_FILE` |
| `cargo` | `rust:1-slim-bookworm` | `[source.crates-io] replace-with = "ak"`, `[source.ak] registry = "sparse+https://ak.internal/cargo/cargo-proxy/"` | `[http] cainfo` |
| `npm` | `node:22-alpine` | `registry=https://ak.internal/npm/npm-proxy/`, `ignore-scripts=true`, `audit=false`, `fund=false` | `cafile` |
| `apt` | `debian:12-slim` | one `.sources` file: `URIs: https://ak.internal/debian/debian-proxy`, `Suites: bookworm`, `Components: main`, `Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg` | `Acquire::https::CAInfo` |
| `apk` | `alpine:3.22` | `/etc/apk/repositories`: `https://ak.internal/alpine/alpine-proxy/v3.22/main` and `/community` | `SSL_CERT_FILE` |

Two details that cost a run each: the Cargo sparse registry URL is the repository root, not
`…/cargo-proxy/index/` (the index files are served under both, `config.json` only at the
root), and `apk fetch` reads only its cache unless told `--no-cache`, in which case it fetches
the index through the registry.

```console
$ make images
clients/pull-images.sh
docker.io/library/golang@sha256:a2012b4a1d1f9f7e9f44e0d39b805a901e856b1dd80b4e6ee4338db547050308
docker.io/library/rust@sha256:24707e70a4f1e23d9a7b25202ec43126d28a52294b96aad5c670df1fd1f1d400
docker.io/library/node@sha256:025b8e975a61d94e33abeafaad1255ef44e4898cf1a1b6446860009c72e6d284
docker.io/library/debian@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
docker.io/library/alpine@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f
```

The images are pulled straight from Docker Hub by the host's podman. This walkthrough is
about the package managers inside the containers, not the images; the Rocky and conda
walkthroughs show base images pulled through the registry.

Every command the clients run is download-only: `go mod download`, `cargo fetch`,
`npm install --ignore-scripts`, `npm pack`, `apt-get download`, `apk fetch`. Nothing from a
fetched package is installed into an image or executed, including the known-bad packages of
the next step.

**Gate:** G1 (the five formats report `enforced` in `GET /api/v1/formats`; the metadata of
all five proxies is served).

**Next:** [Step 2: Record first](2-record-first.md).
