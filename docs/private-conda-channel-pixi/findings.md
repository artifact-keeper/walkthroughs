# Lab notes: private conda channel for pixi

Lab log for the [plan](plan.md). Every command here was run on the host described below,
in the order shown; outputs are trimmed but not edited. Code lives in
[`private-conda-channel-pixi/`](../../private-conda-channel-pixi/). The narrative pages
come later; this file is the record they are written from.

Gate summary: [Gates](#gates). Bugs and doc gaps: [Candidate issues](#candidate-issues).

## Environment

| | |
|---|---|
| Host | Fedora 44, kernel 7.2.4, 24 cores, 125 GiB RAM, no KVM, no sudo |
| Containers | rootless podman 5.8.7 (netavark, pasta), `podman compose` -> docker-compose v5.5.1 |
| Registry | Artifact Keeper backend `ghcr.io/artifact-keeper/artifact-keeper-backend:main` (revision `5e351fc`, digest `sha256:90629d5a...`), web `:main` (revision `55d2dca`, digest `sha256:e06d7e0d...`); compose files from upstream `bb25ef0` |
| Clients | pixi 0.81.0 (`ghcr.io/prefix-dev/pixi:0.81.0`, pulled through the registry), rattler-build 0.76.1 (via `pixi exec`, from the registry), cosign v3.1.3 and skopeo on the host |
| Scanners | `docker.io/anchore/syft`, `docker.io/anchore/grype` |

The existing Rocky walkthrough stack (`artifact-keeper` compose project, host ports 30080/30443)
kept running, untouched, for the whole session.

## 1. The registry on a private network

`registry/up.sh` runs the upstream `docker-compose.yml` (byte-for-byte, from upstream `bb25ef0`)
plus `registry/compose/compose.override.yml` as compose project `ak-conda`:

- every container is renamed `ak-conda-*` (the stock file hardcodes `container_name`, so two
  projects on one host collide without this);
- the default network is `ak-conda-net` (`172.31.40.0/24`, pinned, and
  `RATE_LIMIT_TRUSTED_PROXY_CIDRS` set to match); a second network `build-isolated`
  (`internal: true`, `172.31.41.0/24`) is joined only by Caddy;
- Caddy carries the network alias `ak.internal` on both networks and serves
  `registry/caddy/Caddyfile`: one site `ak.internal` (plus `localhost`, `127.0.0.1` for the host
  port) with `tls internal`; port 80 only redirects;
- the only host port is `127.0.0.1:30444 -> 443`. Postgres, OpenSearch and Trivy publish nothing
  (the stock file publishes Postgres on `0.0.0.0:30432` with `registry/registry`, OpenSearch on
  `9200`, Trivy on `8090`); OpenSCAP is behind a profile.
- `BACKEND_IMAGE` / `WEB_IMAGE` in `registry/.env` pick the images (default `:main`).

```console
$ registry/up.sh
up.sh: generating .../registry/.env
up.sh: backend=ghcr.io/artifact-keeper/artifact-keeper-backend:main web=ghcr.io/artifact-keeper/artifact-keeper-web:main
 ...
 Container ak-conda-caddy Started
up.sh: waiting for Caddy's internal CA  .../registry/out/ak-internal-ca.crt (subject=CN=Caddy Local Authority - 2026 ECC Root)
up.sh: waiting for https://ak.internal:30444/readyz . ready
{"status":"ready","checks":{"database":{"status":"healthy"},"migrations":{"status":"healthy"},"setup_complete":{"status":"complete"}}}
```

Cold start including image pulls: about 90 s. TLS checks:

```console
$ echo | openssl s_client -connect 127.0.0.1:30444 2>/dev/null | openssl x509 -noout -ext subjectAltName -issuer
X509v3 Subject Alternative Name: critical
    DNS:ak.internal
issuer=CN=Caddy Local Authority - ECC Intermediate
$ podman run --rm --network ak-conda-net -v registry/out/ak-internal-ca.crt:/ca.crt:ro,z alpine:3.24 \
    sh -c 'apk add -q curl; curl -sS --cacert /ca.crt https://ak.internal/readyz; getent hosts ak.internal'
{"status":"ready",...}
172.31.40.9       ak.internal  ak.internal
```

Notes:

- A client that connects by IP sends no SNI. Without `default_sni ak.internal` in the Caddyfile the
  TLS handshake from `https://127.0.0.1:30444` fails; with it, the host port serves the
  `ak.internal` certificate. A connection with SNI `localhost` gets a `DNS:localhost` certificate
  from the same CA, which is what the host's podman uses to pull images (section 4).
- From the host, scripts reach the registry by its real name with
  `curl --resolve ak.internal:30444:127.0.0.1 --cacert registry/out/ak-internal-ca.crt` (`akcurl`
  in `registry/lib.sh`), so SNI, the Host header and certificate verification are the same as in
  the network. No `/etc/hosts` edit.

### Bootstrap

`registry/bootstrap.sh` (idempotent; second run reports every object as existing):

```console
$ registry/bootstrap.sh
bootstrap: repo conda-forge created: {"format":"conda","repo_type":"remote","visibility":"internal","upstream_url":"https://conda.anaconda.org/conda-forge"}
bootstrap: repo conda-internal created: {"format":"conda","repo_type":"local","visibility":"internal","upstream_url":null}
bootstrap: repo conda-staging created: {"format":"conda","repo_type":"staging","visibility":"private","upstream_url":null}
bootstrap: repo conda-virtual created: {"format":"conda","repo_type":"virtual","visibility":"internal","upstream_url":null}
bootstrap: repo pypi-remote created: {"format":"pypi","repo_type":"remote","visibility":"internal","upstream_url":"https://pypi.org"}
bootstrap: repo oci-apps created: {"format":"docker","repo_type":"local","visibility":"internal","upstream_url":null}
bootstrap: repo oci-ghcr created: {"format":"docker","repo_type":"remote","visibility":"internal","upstream_url":"https://ghcr.io"}
bootstrap: repo oci-redhat created: {"format":"docker","repo_type":"remote","visibility":"internal","upstream_url":"https://registry.access.redhat.com"}
bootstrap: repo trust created: {"format":"generic","repo_type":"local","visibility":"public","upstream_url":null}
bootstrap: conda-staging release target -> conda-internal: HTTP 200
bootstrap: scan-on-upload conda-staging: HTTP 200
bootstrap: scan-on-upload conda-internal: HTTP 200
bootstrap: policy conda-release-gate created on conda-staging: {"max_severity":"high","block_unscanned":true,"predicates":{"conda":{... "denied_license_families":["gpl","agpl","lgpl"],"block_install_scripts":true,"min_attestation_state":"verified"}, ...}}
bootstrap: minted ci.token (repo token on conda-staging: read+write, 90 days)
bootstrap: minted consumer-repo.token (repo token on conda-virtual: read only)
bootstrap: created user consumer (8beab472-...)
bootstrap: minted consumer.token (user consumer, read:artifacts, selector: conda-virtual conda-internal conda-forge pypi-remote oci-ghcr oci-redhat)
bootstrap: uploaded trust/ak-internal-ca.crt
```

Beyond the plan's list: `oci-ghcr` and `oci-redhat` proxies, so the container base images
(`ghcr.io/prefix-dev/pixi`, UBI) also come through the registry; `conda-staging` is created
with `repo_type: staging` (Artifact Keeper has a staging type with a linked release target) and
visibility `private`; `conda-internal` is `promotion_only: true` (direct uploads refused).

Things that did not work as first written:

- `PUT /api/v1/repositories/conda-staging/release-target` returns `404 Repository not found`.
  The promotion routes are mounted under `/api/v1/promotion/...`; the body field is
  `release_repository_key`, not `target_repository`.
- `POST /api/v1/users/{id}/tokens` (an admin minting a token for another user) rejects
  `repo_selector`: `repo_selector: unknown field 'repo_selector', expected one of 'name',
  'scopes', 'expires_in_days'`. `POST /api/v1/auth/tokens` (the user minting for itself) accepts
  it. The bootstrap therefore logs in as `consumer` once and mints its own token.
- The login endpoint allows 10 logins per (username, source IP) per 15 minutes
  (`RATE_LIMIT_LOGIN_PER_WINDOW`, `RATE_LIMIT_LOGIN_WINDOW_SECS`). Early scripts that logged in on
  every run hit `429`. The bootstrap now mints `admin.token` once and every script uses it.

### Who can read what (R2)

`gates/token-matrix.sh`, HTTP status per credential and URL:

```console
credential     conda-internal conda-staging conda-forge conda-virtual pypi-remote trust
anon           401 401 401 401 401 200
ci             404 200 404 404 404 200
consumer       200 404 200 200 200 200
consumer-repo  404 404 404 404 404 200
```

- `consumer` (a user token with `read:artifacts` and a repository selector) reads exactly the
  consumer repositories; staging is a 404 (not a 403: its existence is not disclosed).
- `ci` (a repository token on `conda-staging`) can only touch staging.
- **A read-only repository token on the virtual repository cannot read through the virtual
  repository**: `GET /conda/conda-virtual/linux-64/<pkg>.conda` with `consumer-repo.token` returns
  `404 {"code":"NOT_FOUND","message":"Virtual repository has no accessible members"}`. Only
  `channeldata.json` (which is computed without members) answers. A repository token is scoped
  to exactly one repository and member reads are authorized against the member, so per-repository
  tokens do not work for virtual channels. The consumer needs a token whose scope covers the
  members (here: a user token with `repo_selector.match_repos`). Candidate issue C3.
- A repository token minted by the admin authenticates as the admin on `/api/v1/auth/me`
  (`"username":"admin","is_admin":true`); its repository scope is what limits it.

## 2. Client image

Every pixi and rattler-build step runs in `localhost/ak-conda/pixi-client:0.81.0`
(`client/Containerfile`): `ghcr.io/prefix-dev/pixi:0.81.0` pulled **through the registry**
(`localhost:30444/oci-ghcr/prefix-dev/pixi:0.81.0`), the internal CA added to the system store,
`/etc/pixi/config.toml` and `/etc/rattler/config.toml` from `client/`. No credentials in the image;
the token arrives as a mounted file named by `RATTLER_AUTH_FILE`.

```console
$ podman pull --cert-dir registry/out/certs.d/localhost:30444 --authfile registry/.tokens/consumer-podman.json \
    localhost:30444/oci-ghcr/prefix-dev/pixi:0.81.0          # 7.4 s
$ podman image inspect ... --format '{{.Digest}}'
sha256:533c28e8d61beef917f45f779ce3f38e89965938223313f56800b2fb0002d822
$ skopeo inspect --no-tags docker://ghcr.io/prefix-dev/pixi:0.81.0 | jq -r .Digest
sha256:788ae451641666e2d1f79d3dbe35392dfc7e9b394b16a3acb75c347f3badb2ab
```

The digests differ: upstream's is the multi-arch index, podman records the linux/amd64 manifest it
resolved through the proxy. Pin by the index digest in the Containerfile; see section 4.

- `tls-root-certs = "system"` plus the CA in `/usr/local/share/ca-certificates` is what makes
  pixi trust `ak.internal`. pixi's `tls-root-certs` takes `webpki` or `system`, not a path.
- The same file as `/etc/rattler/config.toml` warns:
  `WARN Ignoring 'pypi-config' in /etc/rattler/config.toml: not a key of the shared configuration`.
  `client/rattler-config.toml` is the shared subset (mirrors, TLS) without `pypi-config`.
- `pypi-config.index-url` in the config file is only used by `pixi init`; an existing manifest
  needs `[pypi-options] index-url` (section 5).

First `pixi exec rattler-build --version` through the registry (cold cache): 9 s. The access
log shows pixi's probing order on the proxy:

```text
GET  /conda/conda-forge/linux-64/repodata_shards.msgpack.zst   404
GET  /conda/conda-forge/noarch/repodata_shards.msgpack.zst     404
GET  /conda/conda-forge/notices.json                           200
HEAD /conda/conda-forge/noarch/repodata.json.bz2               200
HEAD /conda/conda-forge/noarch/repodata.json.zst               200
GET  /conda/conda-forge/noarch/repodata.json.zst               200  28,750,611 B  2.0 s
GET  /conda/conda-forge/linux-64/repodata.json.zst             200  58,615,856 B  4.5 s
GET  /conda/conda-forge/linux-64/rattler-build-0.76.1-hf01adef_0.conda 200
```

The proxy does not serve CEP-16 shards for conda-forge (404, #4177), pixi falls back to `.zst`
without complaint.
