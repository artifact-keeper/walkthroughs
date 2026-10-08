# Lab notes: private conda channel for pixi

Lab log for the [plan](plan.md). Every command here was run on the host described below,
in the order shown; outputs are trimmed but not edited. Code lives in
[`private-conda-channel-pixi/`](../../private-conda-channel-pixi/). The narrative pages
come later; this file is the record they are written from.

Gate results: [section 7](#7-gate-runs). Bugs and doc gaps: [Candidate issues](#candidate-issues).

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

## 3. Internal packages

`packages/recipes/` holds three rattler-build v1 recipes (`recipe.yaml`):

| Package | Kind | Notes |
|---|---|---|
| `acme-core` | `noarch: python` | version from `ACME_CORE_VERSION` (default 1.0.0) so the gates can build 1.0.1, 1.1.0, 99.0.0 |
| `acme-fastmath` | `linux-64`, C | a shared library and a CLI built with `${{ compiler('c') }}`; exercises a real subdir and pulls a C toolchain through the proxy |
| `acme-report` | `noarch: python` | depends on `acme-core >=1.0,<2`, `pandas >=2`, `rich >=13`; entry point `acme-report` |

`packages/build.sh` runs `pixi exec --spec rattler-build==0.76.1 -- rattler-build build --recipe-dir
/recipes -c conda-forge` in the client container on `ak-conda-net` with the consumer token.
`-c conda-forge` is the canonical URL; `/etc/rattler/config.toml` mirrors it to the registry, so
rattler-build itself, python, pip, setuptools and the compiler toolchain all came through
`https://ak.internal/conda/conda-forge`. All three built and passed their recipe tests:

```text
Artifact: /out/noarch/acme-core-1.0.0-pyh4616a5c_0.conda (8.36 KiB)
Artifact: /out/linux-64/acme-fastmath-1.0.0-hb0f4dca_0.conda (8.62 KiB)
Artifact: /out/noarch/acme-report-1.0.0-pyh4616a5c_0.conda (9.02 KiB)
```

23 s for all three with a warm package cache. rattler-build 0.76.1 reads the pixi/rattler config
files by default (`--config-file`, `--no-config`); older versions did not.

### Publish

`packages/publish.sh` runs `rattler-build upload artifactory --url https://ak.internal/conda
--channel conda-staging <file>` with the CI token in `RATTLER_AUTH_FILE` (no `--token` on the
command line: rattler-build reads the auth file when no credential flag is given). Access log:

```text
PUT /conda/conda-staging/linux-64/acme-fastmath-1.0.0-hb0f4dca_0.conda  201  Authorization: REDACTED  rattler_upload/0.10.7
PUT /conda/conda-staging/noarch/acme-core-1.0.0-pyh4616a5c_0.conda      201  ...
PUT /conda/conda-staging/noarch/acme-report-1.0.0-pyh4616a5c_0.conda    201  ...
```

A second upload of the same file:

```text
Error:   × Server responded with error
  ╰─▶ HTTP status client error (409 Conflict) for url (https://ak.internal/conda/conda-staging/noarch/acme-core-1.0.0-pyh4616a5c_0.conda)
```

rattler-build prints nothing on success with `--log-style plain`; check the exit code.

### Attest

`packages/attest.sh` writes a CEP-27 statement per package and signs it with the CI key
(`signing/gen-keys.sh`, cosign ECDSA P-256, password in `signing/keys/cosign.password`):

```console
$ cosign attest-blob --key signing/keys/cosign.key --statement <file>.statement.json \
    --use-signing-config=false --tlog-upload=false --bundle <file>.sigstore.json --yes
```

- cosign 3.1.3's `attest-blob --predicate pred.json --type <uri>` wraps the predicate in an
  in-toto **Statement v0.1** (`"_type":"https://in-toto.io/Statement/v0.1"`). CEP-27 requires
  Statement v1, and Artifact Keeper checks for it. The script therefore builds the v1 statement
  itself (subject name = file name, sha256 = file digest, predicate
  `{"targetChannel": "https://ak.internal/conda/conda-internal"}`) and passes `--statement`.
- `--tlog-upload=false` alone is refused by cosign 3: `--tlog-upload=false is not supported with
  --signing-config or --use-signing-config`. Add `--use-signing-config=false`.
- The bundle is v0.3 (`application/vnd.dev.sigstore.bundle.v0.3+json`) with a DSSE envelope and
  `verificationMaterial.publicKey.hint`; `cosign verify-blob --key cosign.pub --bundle ...
  --insecure-ignore-tlog <file>` verifies it.

Upload to the registry, on main:

```text
attest: conda-staging/noarch/acme-core-1.0.0-pyh4616a5c_0.conda -> HTTP 400 REFUSED:
  CEP-27 attestation verification failed: bundle: bundle must carry exactly one tlog entry, found 0
```

Expected on main: the verifier accepts only Fulcio-certificate bundles with a Rekor entry from an
allow-listed issuer (GitHub Actions). Key-based bundles are F6. Everything downstream that needs a
stored attestation is BLOCKED(F6) on main.

### Hosted scan and the release gate

`bootstrap.sh` turns on scan-on-upload for `conda-staging` and `conda-internal`
(`PUT /api/v1/repositories/{key}/security {"scan_enabled":true,"scan_on_upload":true}`) and creates
the scan policy `conda-release-gate` on `conda-staging` (promotion evaluates the **source**
repository's policy): `max_severity: high`, `block_unscanned: true`, conda predicates
`min_attestation_state: verified`, denied license families GPL/AGPL/LGPL, denied licenses
GPL-3.0-only/-or-later and AGPL-3.0-only, `block_install_scripts: true`.

Conda packages are scanned by Grype and the dependency scanner; Trivy reports
`not_applicable` for them. A clean package:
`[{"scan_type":"grype","status":"completed","findings_count":0}, {"scan_type":"dependency","status":"completed"}, {"scan_type":"not_applicable",...}]`.

The first promotion attempt (`packages/promote.sh`) before scanning:

```text
promote: noarch/acme-core-1.0.0-pyh4616a5c_0.conda -> conda-internal: HTTP 200 promoted=false
    violation [high] block-unscanned: Artifact has no completed security scan
    violation [high] policy-predicate: Policy 'conda-release-gate' [conda.attestation]: attestation is absent, but the policy requires a verified attestation
```

There is no "allowed licenses" predicate for conda, only denials. (`allowed_licenses` exists on
license policies, which work from SBOM license data, not from `about.json`.)

### Promotion loses the conda metadata (F9)

To get something into `conda-internal` on main, the packages were promoted once with
`skip_policy_check: true`. The promoted records in `conda-internal/noarch/repodata.json`:

```json
"acme-core-1.0.0-pyh4616a5c_0.conda": {
  "build": "0", "build_number": 0, "constrains": [], "depends": [],
  "license": "", "md5": "", "name": "acme-core", "sha256": "eb370de6...",
  "size": 8563, "subdir": "noarch", "version": "1.0.0" }
```

`build` is `"0"` instead of `pyh4616a5c_0`, `depends`, `license`, `md5`, `noarch` and `timestamp`
are gone. pixi then fails on the channel: `failed to extract repodata records from sparse
repodata ... failed to parse digest at line 1 column 122` (the empty `md5`). Promotion also
*moves* the artifact: staging lists the files under `removed` afterwards, and the staging rows
show `quarantine_status: quarantined`.

Workaround used for everything downstream on main: `packages/seed-internal-main.sh` lifts
`promotion_only`, deletes the promoted rows, uploads the three files straight to `conda-internal`
with the admin token, and restores `promotion_only`. Records are then complete
(`"build":"pyh4616a5c_0","depends":["python >=3.10","python"],"md5":"6127...","license":"Apache-2.0","noarch":"python","timestamp":...`).
Upload of a file name that was deleted works (201); the 409 applies to live rows only.

## 4. Consumer project

Two variants:

- `project/`: the target design. `channels = ["https://ak.internal/conda/conda-virtual",
  "https://ak.internal/conda/conda-internal"]`, internal packages pinned with
  `channel = "https://ak.internal/conda/conda-internal"`, `channel-priority = "strict"`,
  `exclude-newer = "14d"` with `[exclude-newer] acme-* = "0d"`, `[pypi-options] index-url =
  "https://ak.internal/pypi/pypi-remote/simple"`, `humanize` from PyPI.
- `project-direct/`: the same with `channels = [conda-internal, "conda-forge"]`; conda-forge by its
  canonical URL, mirrored to the registry's proxy by `/etc/pixi/config.toml`. Works on main.

pixi requires a pinned channel to be one of the workspace channels:
`Package 'acme-core' requested unavailable channel 'https://ak.internal/conda/conda-internal/'`.
So `conda-internal` is listed after the virtual channel; the pin, not the order, decides.

`project/` cannot lock on main:

```text
╰─▶ Cannot solve the request because of: No candidates were found for python 3.12.*.
```

The virtual channel's repodata is empty apart from the internal packages. Backend log for that
request:

```text
Upstream metadata body from https://conda.anaconda.org/conda-forge/linux-64/repodata.json exceeded the 8388608-byte ceiling; aborting buffered read
Proxy fetch failed: Bad gateway: Upstream metadata response exceeded the 8388608-byte limit repo_key=conda-forge path=linux-64/repodata.json
virtual metadata proxy fetch failed for member member=conda-forge path=linux-64/repodata.json
Request completed ... status=200
```

The virtual handler asks the member for uncompressed `repodata.json` (conda-forge's linux-64 is
about 300 MB uncompressed, 58 MB as `.zst`), the 8 MiB buffered-read cap trips, the member is
dropped and the client gets `200` with no conda-forge records (F2, F3).

`project-direct/pixi.lock` (lock format v7): 3 conda URLs on `https://ak.internal/conda/conda-internal`,
40 on `https://conda.anaconda.org/conda-forge`, 1 PyPI wheel at
`https://ak.internal/pypi/pypi-remote/simple/humanize/humanize-4.16.0-py3-none-any.whl`. The PyPI
index went through the registry with the same auth file (pixi uses its credential store for PyPI
indexes as well). No credentials anywhere (G1). Lock v7 entries carry no `name`/`version`
fields; tools must parse the file name.

```console
$ project-direct/pixi-run.sh run --locked start
┏━━━━━━━━┳━━━━━━━━┓
┃ column ┃   mean ┃
┡━━━━━━━━╇━━━━━━━━┩
│ sales  │ 119.33 │
└────────┴────────┘
$ project-direct/pixi-run.sh run --locked hypot
5.000000
```

The 14-day cooldown is visible in the lock: `libgcc-16.2.0-ha9f2e26_5` (the build environment,
which has no cooldown, got `_7`), `openssl 3.6.4` (3.6.5, the fixed release, is newer than 14
days). Grype flags four High openssl CVEs fixed in 3.6.5 (section 6). This is the case pixi's
documentation describes: exempt the fix with `[exclude-newer] openssl = "0d"`.

Repodata on hosted channels is sent with `cache-control: public, max-age=60` although the
repositories are `internal` (authenticated); pixi kept serving a stale repodata for up to a minute
after the channel changed (the `failed to parse digest` error above persisted until it expired).

## 5. Image

`image/Containerfile` is the pixi-on-UBI-micro pattern (github.com/brandonrc/pixi-ubi-micro,
`Dockerfile.micro`) adapted for a registry-only build:

- builder `ak.internal/oci-ghcr/prefix-dev/pixi:0.81.0@sha256:788ae451...` and runtime
  `ak.internal/oci-redhat/ubi9/ubi-micro:9.8@sha256:7a0454cb...`, both through the registry's
  proxies and pinned by the upstream index digest (the proxy serves the index unchanged:
  `skopeo inspect --raw docker://localhost:30444/oci-ghcr/prefix-dev/pixi:0.81.0 | sha256sum`
  equals the ghcr.io digest);
- internal CA, `/etc/pixi/config.toml`, `/etc/rattler/config.toml`, the CI public key at
  `/etc/acme/conda-ci-cosign.pub`;
- `RUN --mount=type=secret,id=rattler-auth,... --mount=type=cache,target=/root/.cache/rattler
  pixi install --locked`;
- the attestation gate: `pixi exec -s cosign -s jq -s curl -s bash -- bash
  verify-attestations.sh /app/pixi.lock` (cosign 3.1.3, jq, curl from conda-forge through the
  registry);
- `pixi shell-hook --locked -s bash > /app/activate.sh` plus `exec "$@"`; the runtime stage is
  UBI micro with the environment, `ENTRYPOINT ["/bin/bash", "/app/activate.sh"]`,
  `CMD ["acme-report"]`, `USER 1001`, no pixi binary, no package manager.

### Rootless podman cannot build on a named network

```text
$ podman build --network ak-conda-net ...
STEP 11/15: RUN ... pixi install --locked
error running container: did not get container start message from parent: EOF
Error: building at STEP "RUN ...": setup network: cannot use networks as rootless
```

`podman build --network` accepts `none`, `host`, `private` and namespace paths, not a netavark
network, in rootless mode. `image/build.sh` therefore runs the build inside
`quay.io/podman/stable:v5.8.7` (pulled through a new `oci-quay` proxy) as a container on the
target network (`--privileged --device /dev/fuse`, still inside the user namespace), with
`podman build --network host` inside it: every `RUN` step gets exactly that container's network.
Base images are pulled from `ak.internal` by the nested podman (CA in
`/etc/containers/certs.d/ak.internal/ca.crt`, consumer token as an auth file). The result is
saved as an OCI archive and loaded on the host.

On `build-isolated` from an empty builder volume (no layer or package cache): 200-230 s, every
`FROM`, pixi package, PyPI wheel and the cosign/jq/curl tools fetched from `ak.internal`.

### The attestation gate on main

```text
verify: 3 package(s) from https://ak.internal/conda/conda-internal/; trusted key f3751a577f375056
FAIL acme-fastmath-1.0.0-hb0f4dca_0.conda: no attestation (neither https://ak.internal/conda/conda-internal/linux-64/acme-fastmath-1.0.0-hb0f4dca_0.conda.sigs nor .../attestation)
FAIL acme-core-1.0.0-pyh4616a5c_0.conda: no attestation (...)
FAIL acme-report-1.0.0-pyh4616a5c_0.conda: no attestation (...)
verify: attestation gate FAILED
Error: building at STEP "RUN ... verify-attestations.sh /app/pixi.lock": exit status 1
```

The gate fails the build, as it should. `ATTESTATION_GATE=warn` (build arg) reports and continues;
the image is labelled `acme.attestation-gate=warn`. Used on main only, to exercise the rest.

### Push and sign

`image/push.sh`: `podman push` to `localhost:30444/oci-apps/acme-analytics:1.0.0` with the
`oci-apps` repository token, `cosign sign --key ... --use-signing-config=false --tlog-upload=false`
by digest, `cosign verify` (cosign reads the auth from `DOCKER_CONFIG` and the CA from
`SSL_CERT_FILE`). Image: 436 MB uncompressed; the image runs with `--network none`.

`/v2/token` shares the login rate limiter (#4020: 10 per username and source IP per 15 minutes,
successful exchanges included). One build, push, sign and verify by the same CI user exhausted it:

```text
Error: signing [...]: accessing image: GET https://localhost:30444/v2/token?scope=repository%3Aoci-apps%2Facme-analytics%3Apull&service=artifact-keeper:
unexpected status code 429 Too Many Requests: Rate limit exceeded. Please try again later.
```

All host traffic reaches Caddy from the same address (rootless port forwarding), which makes it
worse here, but a CI runner behind one NAT address is the same situation. The lab override sets
`RATE_LIMIT_LOGIN_PER_WINDOW=200`. Candidate issue C9.

## 6. Scanning

`scan/scan.sh` (outputs in `out/scan/`, summary in `out/scan/summary.txt`):

```text
== image localhost/acme-analytics:1.0.0
  syft packages by type: {"binary":3,"conda":43,"python":12,"rpm":22}
  conda packages without a purl: 43
  grype matches by severity: {"High":16,"Low":23,"Medium":67,"Negligible":2}
  grype matches by package type: {"binary":26,"conda":26,"rpm":56}
  High openssl 3.6.4 CVE-2026-54873 fix=3.4.8,3.5.9,3.6.5,4.0.3
  High openssl 3.6.4 CVE-2026-72897 fix=3.4.8,3.5.9,3.6.5,4.0.3
  High openssl 3.6.4 CVE-2026-84782 fix=...,3.6.5,4.0.3
  High openssl 3.6.4 CVE-2026-84784 fix=3.4.8,3.5.9,3.6.5,4.0.3
  High python 3.12.14 CVE-2026-82049 fix=3.10.22,3.11.17,3.12.15,3.13.16,3.14.0b1
== environment project-direct/.pixi/envs/default
  syft packages by type: {"binary":3,"conda":43,"python":12}
  grype matches by severity: {"High":10,"Low":12,"Medium":30,"Negligible":2}
== registry SBOM from pixi.lock: {"lockfileFormat":"pixi.lock","sbomFormat":"cyclonedx","summary":{"distinctPackages":44,"edges":99,...},"graphs":1,"components":44}
  sample purl: pkg:conda/acme-fastmath@1.0.0?build=hb0f4dca_0&channel=ak.internal%2Fconda%2Fconda-internal&subdir=linux-64
== registered environment: {"name":"acme-analytics","repository":"conda-internal","summary":{"distinctPackages":44,"edges":99}}
  lookup pkg:conda/openssl@3.6.4 (as consumer): [{"repository":"conda-internal","path":["acme-report@1.0.0","python@3.12.14","openssl@3.6.4"]}]
  lookup pkg:conda/acme-core@1.0.0 (as consumer): [{"repository":"conda-internal","path":["acme-report@1.0.0","acme-core@1.0.0"]}]
  lookup pkg:pypi/humanize@4.16.0 (as consumer): [{"repository":"conda-internal","path":["humanize@4.16.0"]}]
```

- Syft needs `--select-catalogers +conda-meta-cataloger` and emits **no purl** for conda packages;
  Grype still matches them (by name and version) and reports each CVE twice, once for the conda
  record and once for the binary it finds in `bin/`. The registry's SBOM from `pixi.lock` does
  carry `pkg:conda/...` purls with build, channel and subdir qualifiers and sha256 hashes.
- The 22 RPM packages and 56 RPM matches are UBI micro's.
- The PURL reverse lookup answers the incident question directly, with the inclusion path.

## 7. Gate runs

`gates/run-all.sh` runs `gates/gNN-*.sh` and prints one verdict line per check:
`PASS`, `FAIL`, or `BLOCKED(Fn)` when the check depends on an Artifact Keeper fix that is not in the
running backend. Results accumulate in `out/gates/results.tsv`; full logs in `out/gates/gNN.log`.
The gates use scratch repositories (`conda-gate-*`, `conda-fake-upstream`,
`conda-broken-upstream`, `conda-virtual-g4`, `conda-virtual-g6`) so the demo channels stay clean.

Supporting pieces: `gates/fake-upstream.sh` (a conda channel built with rattler-build, indexed with
`rattler-index`, served by `python -m http.server` at `172.31.40.200`, the one private address the
backend may use as an upstream: `AK_SSRF_ALLOW_PRIVATE_CIDRS=172.31.40.200/32`; without it,
`Upstream URL IP '172.31.40.56' is not allowed (private/internal network)`),
`gates/backdate-conda.sh` (rewrites `info/index.json` `timestamp` in a `.conda`), negative
packages in `packages/recipes-negative/` (`acme-legacy` vendors `urllib3 1.24.1` dist-info,
`acme-copyleft` declares `GPL-3.0-only`).

### Run 1: Artifact Keeper main (`5e351fc`), web 1.11 UI branch, 2026-10-07

Total 8 min 17 s (G13's cold isolated image build is 4 min of it).

| Gate | Check | Result | Evidence |
|---|---|---|---|
| G1 | `RATTLER_AUTH_FILE` reads the internal channel | PASS | `pixi search -p linux-64 -c .../conda-internal acme-core` |
| G1 | `pixi auth login ak.internal --token`, no auth file | PASS | stored in `~/.rattler/credentials.json` in the container |
| G1 | no credentials: 401 | PASS | |
| G1 | no credentials in `pixi.toml` / `pixi.lock` | PASS | grep for every minted token, `user:pass@`, `/t/<token>/` |
| G1 | `Authorization` header on every request | PASS | Caddy access log (value redacted) |
| G1 | token in URL, `/conda/t/<token>/<repo>/` | PASS | 200 |
| G1 | token in URL, rattler's `/t/<token>/conda/<repo>/` | BLOCKED(F11) | 401 |
| G2 | `rattler-build upload artifactory` with a Bearer token | PASS | `PUT ... 201` |
| G2 | re-upload | PASS | 409 |
| G2 | POST without `X-Conda-Subdir`, linux-64 package | BLOCKED(F8) | 201, stored as `noarch/acme-fastmath-...` |
| G2 | linux-64 package PUT under `noarch/` | BLOCKED(F8) | 201, indexed with `"subdir":"noarch"` |
| G3 | `build-isolated` reaches only `ak.internal` | PASS | no DNS for conda.anaconda.org / pypi.org, no route to 1.1.1.1, `ak.internal:443` open |
| G3 | `project-direct`: `pixi install --locked` on `build-isolated`, cold cache | PASS | 44 package downloads, all from `ak.internal`; lock keeps `conda.anaconda.org` URLs |
| G3 | registry download records for every package | FAIL | +3 records for 44 downloads: hosted downloads are recorded, proxy (conda-forge, PyPI) downloads are not (C8) |
| G3 | `project` (virtual channel) locks | BLOCKED(F2,F3) | `No candidates were found for python 3.12.*` |
| G4 | virtual channel offers only the hosted `acme-core` | BLOCKED(F1) | `conda-virtual-g4` offers `["1.0.0","99.0.0"]` |
| G4 | unpinned solve keeps the internal version | BLOCKED(F1) | solver picked `acme-core 99.0.0` from the fake upstream through the virtual channel |
| G4 | pinned solve keeps 1.0.0 | PASS | the client-side channel pin holds |
| G5 | `.json`, `.zst`, `.bz2` agree | PASS | noarch, linux-64 |
| G5 | `.tar.bz2` and `.conda` both indexed and installed | PASS | |
| G5 | `repodata.json.zst` plain resource | PASS | `content-type: application/zstd` |
| G5 | shard index without `Content-Encoding` | BLOCKED(F4) | `content-encoding: zstd`, `content-type: application/x-msgpack` |
| G5 | pixi consumes hosted shards | BLOCKED(F4) | `failed to decode zstd shard ... Unknown frame descriptor` |
| G5 | shards off: pixi uses `.zst` | PASS | |
| G5 | proxy shards | PASS (documented) | 404 `only available for local/hosted`; pixi falls back to `.zst`, no client config needed |
| G6 | TTL: new upstream package hidden while fresh, visible after | PASS | `acme-core 99.1.0` appeared 30-35 s after publish with TTL 45 s |
| G6 | broken member fails loudly | BLOCKED(F3) | `conda-virtual-g6`: 200, member dropped |
| G6 | `conda-virtual` merges conda-forge or fails | BLOCKED(F2,F3) | 200 with 1 record |
| G7 | vulnerable package refused | PASS | `cve-severity-threshold: Found 7 high severity vulnerabilities (max allowed: 0)` (acme-legacy) |
| G7 | GPL package refused | PASS | `[conda.license]: declared license 'gpl-3.0-only' is denied`, `[conda.license_family]: ... 'gpl' is denied` |
| G7 | un-attested package refused | PASS | `[conda.attestation]: attestation is absent, but the policy requires a verified attestation` |
| G7 | attested clean package promotes | BLOCKED(F6,F7) | attestation upload refused, so nothing can satisfy the rule |
| G7 | promoted package keeps metadata | BLOCKED(F9) | seen with a policy-skipping promotion: `build "0"`, `depends []`, `md5 ""` |
| G8 | `.sigs` sidecar served | BLOCKED(F5) | 404 |
| G8 | `attestations_sha256` in repodata | BLOCKED(F5) | absent |
| G8 | gate passes a signed package | PASS | local static channel with `.sigs` sidecars |
| G8 | gate fails a flipped byte | PASS | `sha256 6248c5a8... != pixi.lock eb370de6...` |
| G8 | gate fails a re-locked tampered file | PASS | `statement does not bind this file` |
| G8 | gate fails a wrong key | PASS | `accepted signatures do not match threshold, Found: 0, Expected 1` |
| G8 | gate fails an unsigned package | PASS | `no CEP-50 sidecar` |
| G8 | image build fails without verifiable attestations | PASS | enforce mode, section 5 |
| G8 | image build passes for signed packages from the registry | BLOCKED(F5,F6) | |
| G9 | trusted key accepted, wrong key refused | BLOCKED(F6) | both 400 `bundle must carry exactly one tlog entry, found 0` |
| G10 | server-set `indexed_timestamp` | BLOCKED(F10) | absent on all records |
| G10 | `exclude-newer 1h` excludes a package built minutes ago | PASS | with `acme-core <1.2`: picks 1.0.0, not 1.1.0 (built minutes ago) |
| G10 | `exclude-newer` excludes a backdated package indexed minutes ago | FAIL (pixi) | pixi picked `acme-core 1.2.0` whose build `timestamp` says 30 days ago; pixi 0.81.0 filters on the publisher-set `timestamp`, not a server field (conda/ceps#154). Not fixed by F10 alone |
| G11 | registry SBOM from `pixi.lock` | PASS | 44 components = 44 locked packages |
| G11 | Syft + Grype on the image | PASS | 43 conda packages, 108 matches (16 High) |
| G11 | PURL lookup | PASS | `pkg:conda/openssl@3.6.4` -> `acme-report -> python -> openssl` in `conda-internal/acme-analytics` |
| G12 | `pixi install --frozen --offline`, `--network none`, pre-filled cache | PASS | |
| G12 | same lock from a second mirror (static HTTP directory) | PASS | only `[mirrors]` changed; 3 requests served by the mirror |
| G12 | flipped byte on the mirror | PASS | `hash mismatch when extracting ... expected eb370de6..., got 6248c5a8...` |
| G13 | image builds on `build-isolated` from a cold builder | PASS | 200-231 s; attestation gate in warn mode on main |
| G13 | pushed to `oci-apps`, cosign-verified | PASS | `localhost:30444/oci-apps/acme-analytics@sha256:8c95b4d8...` |
| G13 | untrusted key does not verify | PASS | |
| G13 | image runs with `--network none` | PASS | |

Gate notes:

- G1: `pixi search` without `-p` queries every known subdir, including `unknown`; Artifact Keeper
  answers `400 Invalid subdir: subdir 'unknown' must be 'noarch' or '<platform>-<arch>'` and pixi
  aborts. `unknown` is a real rattler platform; a 404 (empty) would let pixi continue (C7).
- G2: the POST upload route needs the raw body plus `X-Package-Filename` (or
  `Content-Disposition`); multipart is refused with `400 Missing filename`.
- G3: download records come from `GET /api/v1/admin/downloads`.
- G6: the `conda-forge` proxy's TTL is 300 s (`GET /api/v1/repositories/conda-forge/cache-ttl`).

## Candidate issues

Each has the exact symptom above. Where each one was filed: [Filed upstream](#filed-upstream).

| # | Component | Issue | Plan item |
|---|---|---|---|
| C1 | Artifact Keeper | Virtual conda channel fetches members' uncompressed `repodata.json` under an 8 MiB cap; conda-forge exceeds it, the member is dropped and the client gets 200 | F2, F3 (#4180, #4192) |
| C2 | Artifact Keeper | Virtual conda channel merges a remote member's versions of a name a hosted member owns (dependency confusion) | F1 |
| C3 | Artifact Keeper | A repository token on a virtual repository cannot read through it: `404 Virtual repository has no accessible members`; per-repository consumer tokens do not work for virtual channels | new |
| C4 | Artifact Keeper | Hosted CEP-16 shard index sent with `Content-Encoding: zstd`; HTTP clients strip the frame and rattler fails | F4 (#4173) |
| C5 | Artifact Keeper | Promotion drops conda metadata (`build`, `depends`, `md5`, `license`, `noarch`, `timestamp`) | F9 |
| C6 | Artifact Keeper | Subdir not checked against `index.json` on PUT; POST without `X-Conda-Subdir` files a linux-64 package under noarch | F8 |
| C7 | Artifact Keeper | `GET /conda/<repo>/unknown/repodata.json` is 400; rattler treats it as fatal (`pixi search` without `-p`) | new |
| C8 | Artifact Keeper | Proxy (remote) downloads served from cache are not written to the download records; only hosted downloads are audited | new (R7) |
| C9 | Artifact Keeper | `/v2/token` shares the login limiter and counts successful exchanges: one CI push + cosign sign + verify hits 429 | new (#4020 follow-up) |
| C10 | Artifact Keeper | Key-based Sigstore bundles refused (`bundle must carry exactly one tlog entry, found 0`); no configurable trust policy | F6 |
| C11 | Artifact Keeper | No CEP-50 sidecars, no `attestations_sha256` | F5 |
| C12 | Artifact Keeper | No server-set `indexed_timestamp` | F10 |
| C13 | Artifact Keeper | rattler's `/t/<token>/conda/<repo>/` layout is 401 | F11 |
| C14 | Artifact Keeper | `POST /api/v1/users/{id}/tokens` rejects `repo_selector` while `POST /api/v1/auth/tokens` accepts it | new |
| C15 | Artifact Keeper | Authenticated (internal) repodata sent with `cache-control: public, max-age=60` | new |
| C16 | Artifact Keeper | Duplicate scan policy names accepted (three `conda-release-gate` policies after a buggy bootstrap) | new, minor |
| C17 | Artifact Keeper docs | Promotion routes are under `/api/v1/promotion/repositories/...` and the release-target body is `release_repository_key`; conda upload POST needs `X-Package-Filename` | F12 (site) |
| C18 | Artifact Keeper (compose) | Stock compose hardcodes `container_name`, so two projects cannot share a host; publishes Postgres/OpenSearch/Trivy on all interfaces | new |
| C19 | pixi | `exclude-newer` filters on the publisher-set `timestamp`; a backdated package passes a cooldown | upstream (conda/ceps#154) |
| C20 | cosign | `attest-blob --predicate --type` emits in-toto Statement v0.1; CEP-27 needs v1 (use `--statement`) | doc note |
| C21 | Syft | conda packages get no purl | upstream |
| C22 | podman | rootless `podman build --network <name>` is refused; build inside a container on the network instead | doc note |
| C23 | Artifact Keeper | promotion `gate_results` omits predicates that passed (attestation verified, license allowed); only failures appear, as one `policy-predicate` rule | new (UI U6) |
| C24 | Artifact Keeper | A database migrated by the 1.11.0 fix-branch image cannot start a `main` image: the branch's migration 272 (`artifacts origin staging is hosted`) was merged as 284, and `main` has a different 272. Startup fails with `Migration(VersionMismatch(272))` after applying `main`'s 257, 265, 266, and the branch image then fails with `VersionMissing(257)` | lab only (pre-release images); no released version affected |
| C25 | Artifact Keeper (design) | The virtual channel's allowlist does not bind a consumer who can also read the remote repository: `GET /conda/conda-forge/...` serves anything. The consumer token here can read `conda-forge`, and the client config mirrors `conda-forge` to it | doc note (step 10); narrow the consumer's repositories to the virtual channel |
| C26 | Artifact Keeper | `{subdir}/current_repodata.json` is 200 with no packages on the `conda-forge` proxy and on `conda-virtual`, allowlist on or off (upstream's is not empty). pixi does not read it; conda's classic solver does, then retries with `repodata.json` | new, minor |
| C27 | Artifact Keeper | `PUT .../allowlist` with an unchanged list writes a `REPOSITORY_ALLOWLIST_CHANGED` audit event with `previous` equal to `current` | new, minor |
| C28 | Artifact Keeper | A remote whose upstream is unreachable keeps serving its cached index for TTL + 3600 s (`STALE_IF_ERROR_GRACE_SECS`, not configurable) through the virtual channel, with nothing on the response that marks it stale (no `Age`, no `Warning`, same ETag); only a backend `WARN revalidation failed; serving stale within stale-if-error grace`. Seen in S2 at 315 s with TTL 300 s | new (R6: no silent staleness) |
| C29 | Artifact Keeper | Host-relative `info.base_url` (`/conda/<repo>/<subdir>/`) puts the serving repository's name into `pixi.lock` when a pixi mirror points one channel at another Artifact Keeper repository (`scn-virtual-ci` URLs in a lock for `conda-virtual`); and a client whose channel is a Nexus group resolves package URLs to `http://scn-nexus:8081/conda/conda-virtual/...` (404) | [#4580](https://github.com/artifact-keeper/artifact-keeper/issues/4580) |
| C30 | Artifact Keeper | The security dashboard's `policy_violations_blocked` counts a proxied conda file with a vulnerable verdict as blocked, while conda's proxy path (`scan_on_proxy: accepted`) still serves it 200 (S5: 0 -> 1, certifi 2022.12.7 still downloads) | new (#4380 follow-up) |
| C31 | Artifact Keeper | Scan-on-proxy is `accepted`, not `enforced`, for `conda` and `conda_native`: the setting is stored, proxied downloads are served without the gate, no `X-AK-Scan` header | [#4097](https://github.com/artifact-keeper/artifact-keeper/issues/4097) |
| C32 | Artifact Keeper | No CEP-16 shards through a virtual channel (404 `Sharded repodata (CEP-16) is only available for local/hosted conda repositories`); every solve through `conda-virtual` reads the full index (S7: 109 MB of `.zst` per linux-64 solve) | [#4577](https://github.com/artifact-keeper/artifact-keeper/issues/4577) |
| C33 | Artifact Keeper | Package downloads ignore `If-None-Match`: a matching ETag still gets 200 and the full body (Nexus revalidating 43 packages re-downloaded 101.2 MB) | [#4579](https://github.com/artifact-keeper/artifact-keeper/issues/4579) |
| C34 | Artifact Keeper | Remote upstreams on private addresses are refused (`Upstream URL IP '172.31.40.151' is not allowed (private/internal network)`) unless listed in `AK_SSRF_ALLOW_PRIVATE_CIDRS`, an environment variable (backend recreate to change) | doc note |
| C35 | Artifact Keeper | A remote record with `track_features` as a JSON list is merged and served unchanged in json, zst and bz2 (neither rejected nor normalised to a string) | doc note; pixi 0.81 accepts it |
| C36 | Nexus CE 3.96.4 | A conda group served `linux-64/repodata.json.bz2` as `{"packages":{}}` (54 bytes) from its cached merge; `invalidate-cache` on the group rebuilt it (790,808 records). Group merges also have no name ownership and mix record and bytes on a file name clash (S4) | upstream (Sonatype); doc note |
| C37 | pixi 0.81.0 | In one of two cold-cache solves through `conda-virtual`, pixi downloaded `linux-64` as both `repodata.json.zst` (74.3 MB) and `.bz2` (61.5 MB); it also reads `channeldata.json` (23.7 MB) | not investigated |

## What the fixes changed

### Run 2: Artifact Keeper 1.11.0 fix branch, clean registry, `make all`

Backend `localhost/ak-backend:conda-1.11` (BACKEND_READY v1, image `9774f28a9540`, branch
`conda-walkthrough-1.11` at `8f0d5b13` on main `bb25ef09`: F1-F11 plus unknown-subdir,
`Cache-Control: private`, `/v2/token` bucket). Switch: `BACKEND_IMAGE` in `registry/.env`, the
CI public key mounted into the backend and named in `CONDA_ATTESTATION_PUBLIC_KEYS=ci=...`
(compose override), the login-limit lab setting returned to the default 10. Then
`registry/down.sh --volumes` and `make all` from an empty registry: **exit 0 in 14 min 6 s**, no
workaround anywhere (client with shards on, real promotion, attestation gate enforced, the
virtual-channel project).

```text
GET /api/v1/attestations/policy -> {"require_verified":true,"issuers":["https://token.actions.githubusercontent.com"],"identities":[],
  "keys":[{"id":"53ff3ea8b0f33847","name":"ci","fingerprint":"53ff3ea8...","algorithm":"ecdsa-p256-sha256"}]}
attest: conda-staging/noarch/acme-core-1.0.0-pyh4616a5c_0.conda -> HTTP 201 {"attestation_count":1,"attestations_sha256":"a40c9cfc...",
  "status":"attestation stored","verification":{"checks_passed":771,"identity":"ci","issuer":"key:53ff3ea8b0f33847","method":"sigstore-key",
  "state":"verified","statement_type":"https://in-toto.io/Statement/v1",...}}
promote: noarch/acme-core-1.0.0-pyh4616a5c_0.conda -> conda-internal: HTTP 200 promoted=true      (all three, policy enforced)
verify: 3 package(s) from https://ak.internal/conda/conda-internal/; trusted key f3751a577f375056
PASS acme-fastmath-1.0.0-hb0f4dca_0.conda (sidecar, sha256 365a421b75d1..., channel https://ak.internal/conda/conda-internal)
PASS acme-core-1.0.0-pyh4616a5c_0.conda (sidecar, ...)
PASS acme-report-1.0.0-pyh4616a5c_0.conda (sidecar, ...)
verify: attestation gate passed for 3 package(s)
```

The promoted record in `conda-internal` now keeps everything and gains the new fields:
`{"build":"pyh4616a5c_0","depends":["python >=3.10","acme-core >=1.0,<2","pandas >=2","rich >=13","python"],"md5":"3d3b34db...","license":"Apache-2.0","noarch":"python","attestations_sha256":"b5ba0b8a...","indexed_timestamp":1791381108494}`.
`conda-virtual` merges conda-forge: 790,178 linux-64 records, `repodata.json.zst` 74 MB in 3.9 s.
`project/` (one virtual channel) locks and installs; its image is built with the gate enforced.

Gate verdicts that changed (everything not listed is as in run 1, PASS):

| Gate | Check | Run 1 (main) | Run 2 (fix branch) |
|---|---|---|---|
| G1 | rattler `/t/<token>/conda/<repo>/` | BLOCKED(F11) 401 | PASS |
| G2 | POST without subdir header | BLOCKED(F8) noarch | PASS, filed under linux-64 per `index.json` |
| G2 | linux-64 package under `noarch/` | BLOCKED(F8) 201 | PASS, 400 |
| G3 | `project` (virtual) locks and installs on `build-isolated` | BLOCKED(F2,F3) | PASS, 44 packages, all via `ak.internal` |
| G3 | download records for proxy downloads | FAIL | **FAIL** (+3 records for 44-47 downloads; C8 not in scope of the fixes) |
| G4 | virtual offers only the hosted `acme-core` | BLOCKED(F1) `["1.0.0","99.0.0"]` | PASS `["1.0.0"]` |
| G4 | unpinned solve | BLOCKED(F1) 99.0.0 | PASS 1.0.0 |
| G5 | shard index without `Content-Encoding` | BLOCKED(F4) | PASS (`content-type: application/x-msgpack`) |
| G5 | pixi consumes hosted shards | BLOCKED(F4) | PASS, shard index and shards fetched, no fallback |
| G6 | broken member fails loudly | BLOCKED(F3) 200 | PASS 502 |
| G6 | `conda-virtual` merges conda-forge | BLOCKED(F2,F3) 1 record | PASS 790,178 records |
| G7 | attested, clean package promotes | BLOCKED(F6,F7) | PASS |
| G7 | metadata kept on promotion | BLOCKED(F9) | PASS |
| G7 | attestation follows the package | (not reachable) | PASS |
| G8 | `.sigs` sidecar, `attestations_sha256` | BLOCKED(F5) | PASS |
| G8 | image build gate passes for registry-signed packages | BLOCKED(F5,F6) | PASS (enforce) |
| G9 | trusted key accepted, wrong key refused | BLOCKED(F6) both 400 | PASS: 201 / 400 `bundle is signed by key hint wiEcltjl..., which is not a configured trusted key` |
| G10 | server-set `indexed_timestamp` | BLOCKED(F10) | PASS (the backdated package shows its real index time) |
| G10 | backdated package excluded by `exclude-newer` | FAIL | **FAIL**: pixi 0.81.0 still filters on the build `timestamp` (C19, pixi side) |
| G13 | image from the registry only | PASS (gate warn) | PASS (gate **enforce**, 191 s cold on `build-isolated`) |

Also confirmed on the fix branch: `GET /conda/<repo>/unknown/repodata.json` 200 (C7 fixed), repodata
for authenticated requests `cache-control: private, max-age=60` (C15 fixed), push + sign + verify
with the default login limit and no 429 (C9 fixed). Unchanged: a repository token on
`conda-virtual` still cannot read through it (C3; `consumer-repo` 404 on every URL).

New behavior worth noting: a deleted conda file name cannot be uploaded again
(`409 Artifact version already exists and is immutable`); on main it could. The gates now build
a fresh version per run (G7 `acme-core 1.0.<epoch>`, G10 `1.<epoch>.0`) instead of reusing names.
G10 also uses a fresh client cache: pixi's cached repodata (max-age 60) otherwise hides packages
uploaded seconds earlier.

### Backend version 2 (F17-F19), G7 again

`localhost/ak-backend:conda-1.11` rebuilt (BACKEND_READY version 2, image `e4788989c3d3`, branch at
`38a441dc`: F17 duplicate policy names 409, F18 bulk promotion `gate_results`, F19 origin
`hosted` for staging uploads). Only the backend container was recreated. G7 (with an added check:
a clean, un-attested candidate) and G9:

```text
PASS  G7  vulnerable package (acme-legacy) refused on its scan findings
PASS  G7  GPL-3.0-only package (acme-copyleft) refused on the license rule
PASS  G7  un-attested package (acme-core 1.0.1791387572, clean scan) refused on the attestation rule
PASS  G7  attested, clean acme-core 1.0.1791387567 promotes
PASS  G7  promoted package keeps its metadata in conda-internal repodata
PASS  G7  the attestation follows the package to conda-internal
PASS  G9  attestation signed by the trusted key accepted (201); wrong key refused (400 ...)
```

`gate_results` on a refusal (acme-copyleft):

```text
gate cve-severity-threshold: passed (0 open finding(s), none above the policy threshold)
gate block-unscanned: passed (a security scan has completed)
gate policy-predicate: FAILED (Policy 'conda-release-gate' [conda.license]: declared license 'gpl-3.0-only' is denied; ... [conda.license_family]: declared license family 'gpl' is denied)
```

On a successful promotion `gate_results` lists only `cve-severity-threshold` and `block-unscanned`;
the satisfied predicates (attestation verified, license allowed) are not reported as passed rules,
so a UI cannot show "attestation verified" from the promotion response alone (C23).

### Web UI on the stack

- 2026-10-07T11:22Z: `localhost/ak-web:conda-1.11` (WEB_READY v1, `d61d95c`) via `WEB_IMAGE` in
  `registry/.env` and `registry/up.sh`.
- 2026-10-07T12:25Z: WEB_READY v2, the same tag rebuilt from the UI integration branch (image
  `90ee4ccb1fb6`). Only the web container was recreated
  (`podman compose ... up -d --force-recreate --no-deps web`); backend, data and tokens untouched.
  `https://127.0.0.1:30444/` -> 200, `<title>Artifact Keeper`; `/readyz` 200.
- The UI agent's throwaway repository `ui-test-conda` was deleted
  (`DELETE /api/v1/repositories/ui-test-conda` -> 200, then GET -> 404).
- 2026-10-07T13:50Z: registry data wiped for run 2 (`registry/down.sh --volumes`, then
  `make all`); `.env` (admin password) kept, tokens re-minted into the same files.
- 2026-10-07T14:10Z: WEB_READY v4, image `bbe52fb10974`; web container recreated, UI 200.

### Allowlist backend (#4576), step 10 and G14

2026-10-08. Backend `localhost/ak-backend:allowlist-1.11` (ALLOWLIST_BACKEND_READY, image
`7e72ec12c88a`, branch `feat/4576-conda-virtual-allowlist` at `85a738c4` on main `7e5a3335`, which
has #4561 merged). `BACKEND_IMAGE` in `registry/.env`, then only the backend recreated
(`compose up -d --force-recreate --no-deps backend`).

The switch did not work as a drop-in (C24). The first start applied `main`'s migrations 257, 265
and 266, then stopped on `Error: Migration(VersionMismatch(272))` and restarted in a loop: this
database was migrated by the fix-branch image, whose 272 is `artifacts origin staging is hosted`;
on `main` that migration is 284 and 272 is `proxy cache download holds index`. Going back to
`conda-1.11` failed too (`Migration(VersionMissing(257))`). Checksums of every migration in the
database against `main`'s `backend/migrations/` at `7e5a3335` (sha384, as sqlx stores them): only
272 differed, 273-284 not applied, nothing else. With the backend stopped, a `pg_dump` taken
(kept outside the repository), the branch's 272 row deleted from `_sqlx_migrations`, and the
backend started: `main` applied 272-284 (`migration 284: re-stamped 0 staging-origin artifact
row(s) as hosted`), `/readyz` ready, healthy. Also logged at start, from `main`: `OCI migration
reindex: hollow Docker/OCI tags detected ... repositories=["oci-ghcr", "oci-quay", "oci-redhat"]`;
G13 still pulled its base images and passed.

The API as built matches the issue: `GET`/`PUT`/`DELETE /api/v1/repositories/{key}/allowlist`,
`enabled` required, entries `{name, version?, subdirs?}`, a bare version is exact, builds not
matched, hosted members not filtered. Details in [the API reference](reference/registry-api.md).
Checked by hand with the list on (all as designed):

```text
shard index noarch                    -> 404 Sharded repodata (CEP-16) is only available for local/hosted conda repositories
token-in-URL colorama (/t/<token>/conda/..., /conda/t/<token>/...)  -> 404 not found in any member repository
HEAD colorama                         -> 404
colorama .sigs                        -> 404 Attestation sidecar not found
colorama, other build and .tar.bz2    -> 404
six 1.17.0 (locked)                   -> 200;  six 1.16.0 (not locked) -> 404
consumer token GET allowlist          -> 403 Token does not have required scope: read:repositories
PUT version ">=>2"                    -> 400 entries[0]: version ">=>2" is not a conda version spec: invalid operator '>=>'
PUT without enabled                   -> 400 ... missing field `enabled`
GET on conda-internal or conda-forge  -> 400 The allowlist is only available on virtual conda repositories
audit                                 -> REPOSITORY_ALLOWLIST_CHANGED {"current":{"enabled":true,"entry_count":43},"previous":{"enabled":false,"entry_count":43},"repository":"conda-virtual"}
```

G14 (the lock is project/pixi.lock: 43 conda packages, 31 linux-64 and 12 noarch):

```text
noarch/repodata.json: x-ak-allowlist-dropped: 382366
noarch: 22 records (17 from the remote covering 10 name/version pairs, 5 hosted); lock: 12 files
linux-64/repodata.json: x-ak-allowlist-dropped: 790523
linux-64: 231 records (230 from the remote covering 30 name/version pairs, 1 hosted); lock: 31 files
channeldata.json: x-ak-allowlist-dropped: 34585
channeldata.json: 43 names; colorama listed: 0
GET /conda/conda-forge/noarch/colorama-0.4.6-pyhd8ed1ab_1.conda  200   (the remote itself is not filtered)
GET /conda/conda-virtual/noarch/colorama-0.4.6-pyhd8ed1ab_1.conda  404  {"code":"NOT_FOUND","message":"Artifact not found in any member repository"}
$ pixi add --no-install colorama      # allowlist on
  ╰─▶ Cannot solve the request because of: No candidates were found for
      colorama *.
conda-virtual requests during install: 41 (40 package downloads 200, 0 other than 200/304)
allowlist off: colorama download HTTP 200; linux-64 records 790754; channeldata 34628 names, colorama listed: true
$ pixi add --no-install colorama      # allowlist off
Added colorama >=0.4.6,<0.5
```

Full `make gates` on this backend (2026-10-08T18:15Z-18:25Z): everything PASS except

| Gate | Check | Result |
|---|---|---|
| G3 | download records for proxy downloads | **PASS** now (+44 for 44 downloads; C8 fixed on `main`) |
| G4 | all three checks | FAIL in the run, then PASS after a gate fix: the virtual channel offered `["1.0.0","1.0.1","1.0.1791387539","1.0.1791387567"]`, all hosted (G7 promotes `acme-core 1.0.<epoch>` into `conda-internal` on every run) and never 99.0.0; the gate expected the literal `["1.0.0"]`. G4 now compares with `conda-internal`'s own versions |
| G10 | backdated package excluded by `exclude-newer` | FAIL, unchanged (C19, pixi) |
| G14 | all eight checks | PASS |

The gate leaves the allowlist off (`enabled=false`, 43 entries kept).

`make all` on this populated registry stops at `publish` (409 for the three packages already in
`conda-staging`; a published name is immutable since 1.11.0), as it would on any re-run; it is
meant for an empty registry. The registry was not wiped for this step. The rest of the pipeline,
`make lock image push scan`, exits 0 on the new backend with both lockfiles unchanged, and
`make gates` (G1-G14) is above.

### Scenario suite: Nexus CE in front of Artifact Keeper (S1-S7)

2026-10-08. Same backend (`localhost/ak-backend:allowlist-1.11`), Nexus CE 3.96.4 (`scn-nexus`,
8 GB heap) and `scn-fake-forge` as a compose overlay (`make scenarios-up`), pixi 0.81.0. The
spike notes are in `scenarios/README.md`; the page is [Scenarios](scenarios.md).
`make scenarios`, 2026-10-08T20:51Z-21:21Z (1799 s): 46 PASS, 2 BLOCKED(#4097), 0 FAIL.

| Scenario | Result | What it showed |
|---|---|---|
| S1 behind Nexus | 9 PASS | cold install 2.2 s (AK -> Nexus 101.2 MB), warm 1.5 s (0 bytes from AK), lock unchanged, name guard holds through a proxy; **allowlist propagation 120 s with `metadataMaxAge` 2 minutes** |
| S2 public source down | 11 PASS | Nexus and AK keep serving cached metadata and packages; AK's virtual index stays 200 past the 300 s TTL (C28) |
| S3 curated channel down | 5 PASS | backend stopped 92 s: install 1.2 s and a fresh solve from stale metadata through Nexus; never-fetched files `404 Remote Auto Blocked`; the PyPI wheel (fetched from ak.internal) 502 |
| S4 merged in the artifact manager | 5 PASS | a Nexus group undoes the allowlist, locks `acme-core 99.0.0`, and breaks on a file name clash (hash mismatch); as a member of AK's virtual the same source is dropped by the name guard |
| S5 CVE on proxy | 3 PASS, 2 BLOCKED(#4097) | certifi 2022.12.7 installs with scan-on-proxy blocking on; a rescan records CVE-2023-37920 (high) and CVE-2024-39689 (low); the dashboard counts it as blocked (C30, C31) |
| S6 allowlist from a pull request | 6 PASS | `scenarios/allowlist-ci.sh` (lock against an unfiltered twin, check, apply, verify); through Nexus each change took about 2 minutes; Nexus keeps a removed package's cached file |
| S7 big and malformed index | 7 PASS | 109.2 MB of `.zst` per linux-64 solve for a monolithic client, 133-194.5 MB for pixi, no shards through the virtual (C32); a list-shaped `track_features` is passed through by AK and Nexus and accepted by pixi |

Decisions and deviations:

- Nexus `metadataMaxAge` and negative cache 2 minutes on the proxies of Artifact Keeper (was
  1440 in the spike): the TTL is the propagation delay, and revalidation is a 304.
- The hostile member on the Artifact Keeper side is G4's fake upstream (`conda-fake-upstream`), not
  `scn-fake-forge` (C34). S4 and S7 patch its `repodata.json` and `.zst` for the run and restore
  them.
- CI solves go to an unfiltered twin of `conda-virtual` through a pixi mirror; the twin's URLs in
  the lock are rewritten to `conda-virtual` (C29).
- S5 restores `conda-forge`'s scan configuration by `PUT` (there is no `DELETE`): before the first
  run it had no configuration row; now it has one with every switch off (`scan_enabled`,
  `scan_on_proxy`, `block_on_policy_violation` false, `fail_open`; `severity_threshold` stays
  `high`, unused while `block_on_policy_violation` is false).

## Timings

| Step | Time |
|---|---|
| Stack cold start (pulls included) to `/readyz` ready | ~90 s |
| `pixi exec rattler-build --version`, cold, through the registry | 9 s |
| Build three packages (warm cache) | 23 s |
| `pixi install --locked`, project-direct, cold cache, `build-isolated` | 1-4 s (44 packages from the registry on the same host) |
| Image build on `ak-conda-net`, warm builder | ~3 min 15 s |
| Image build on `build-isolated`, cold builder | 200-231 s |
| Hosted scan of a conda package (Grype) | < 30 s |
| Full gate run | 8 min 17 s (main), ~10 min (fix branch) |
| `make all` from an empty registry, fix branch | 14 min 6 s |

## Filed upstream

The Artifact Keeper items above, filed against the 1.11.0 milestone on 2026-10-07. The fixes are in two pull requests: [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) (conda channels, attestations, promotion) and [#4562](https://github.com/artifact-keeper/artifact-keeper/pull/4562) (`/v2/token` rate limit, scan-policy names).

| # | Finding | Issue | Pull request |
|---|---|---|---|
| C1 | virtual channel drops an oversized member and answers 200 | [#4555](https://github.com/artifact-keeper/artifact-keeper/issues/4555) (with [#4180](https://github.com/artifact-keeper/artifact-keeper/issues/4180), [#4192](https://github.com/artifact-keeper/artifact-keeper/issues/4192)) | [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) |
| C2 | remote member shadows a hosted package name | [#4555](https://github.com/artifact-keeper/artifact-keeper/issues/4555) | [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) |
| C3 | repository token on a virtual repository cannot read through it | [#4559](https://github.com/artifact-keeper/artifact-keeper/issues/4559) (decision; related [#4130](https://github.com/artifact-keeper/artifact-keeper/issues/4130)) | none yet |
| C4 | CEP-16 shard index encoding | [#4555](https://github.com/artifact-keeper/artifact-keeper/issues/4555) (with [#4173](https://github.com/artifact-keeper/artifact-keeper/issues/4173)) | [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) |
| C5 | promotion drops artifact metadata | [#4557](https://github.com/artifact-keeper/artifact-keeper/issues/4557) | [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) |
| C6 | upload subdir not checked against `index.json` | [#4555](https://github.com/artifact-keeper/artifact-keeper/issues/4555) | [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) |
| C7 | `unknown` subdir is 400 | [#4555](https://github.com/artifact-keeper/artifact-keeper/issues/4555) | [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) |
| C8 | proxy downloads missing from the download records | [#4560](https://github.com/artifact-keeper/artifact-keeper/issues/4560) (main has since merged [#4539](https://github.com/artifact-keeper/artifact-keeper/issues/4539); verification left) | none yet |
| C9 | `/v2/token` shares the login rate limit | [#4558](https://github.com/artifact-keeper/artifact-keeper/issues/4558) | [#4562](https://github.com/artifact-keeper/artifact-keeper/pull/4562) |
| C10 | key-based Sigstore bundles refused, no trust policy | [#4556](https://github.com/artifact-keeper/artifact-keeper/issues/4556) | [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) |
| C11 | no CEP-50 sidecars, no `attestations_sha256` | [#4556](https://github.com/artifact-keeper/artifact-keeper/issues/4556) | [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) |
| C12 | no server-set `indexed_timestamp` | [#4555](https://github.com/artifact-keeper/artifact-keeper/issues/4555) | [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) |
| C13 | rattler's `/t/<token>/conda/<repo>/` layout is 401 | [#4555](https://github.com/artifact-keeper/artifact-keeper/issues/4555) | [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) |
| C14 | `POST /api/v1/users/{id}/tokens` rejects `repo_selector` | not filed yet |  |
| C15 | authenticated repodata sent `cache-control: public` | [#4555](https://github.com/artifact-keeper/artifact-keeper/issues/4555) | [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) |
| C16 | duplicate scan policy names accepted | [#4558](https://github.com/artifact-keeper/artifact-keeper/issues/4558) | [#4562](https://github.com/artifact-keeper/artifact-keeper/pull/4562) |
| C17 | promotion route and conda upload docs | not filed yet (site docs) |  |
| C18 | stock compose hardcodes `container_name`, publishes service ports | not filed yet |  |
| C19 | pixi `exclude-newer` filters on the publisher `timestamp` | upstream: [conda/ceps#154](https://github.com/conda/ceps/issues/154) |  |
| C20 | cosign `attest-blob --predicate` emits Statement v0.1 | doc note in this walkthrough |  |
| C21 | Syft emits no purl for conda packages | not filed yet (upstream) |  |
| C22 | rootless `podman build --network <name>` refused | doc note in this walkthrough |  |
| C23 | promotion `gate_results` omit passed predicates | [#4556](https://github.com/artifact-keeper/artifact-keeper/issues/4556) | [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) |
| F18 | bulk promotion returns empty `gate_results` | [#4557](https://github.com/artifact-keeper/artifact-keeper/issues/4557) | [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) |
| F19 | staging uploads recorded with a `virtual` origin | [#4557](https://github.com/artifact-keeper/artifact-keeper/issues/4557) (related [#4152](https://github.com/artifact-keeper/artifact-keeper/issues/4152)) | [#4561](https://github.com/artifact-keeper/artifact-keeper/pull/4561) |
| C29 | host-relative `info.base_url` | [#4580](https://github.com/artifact-keeper/artifact-keeper/issues/4580) |  |
| C31 | scan-on-proxy for conda | [#4097](https://github.com/artifact-keeper/artifact-keeper/issues/4097) |  |
| C32 | no shards through a virtual channel | [#4577](https://github.com/artifact-keeper/artifact-keeper/issues/4577) |  |
| C33 | `If-None-Match` ignored on package downloads | [#4579](https://github.com/artifact-keeper/artifact-keeper/issues/4579) |  |
| C28, C30 | stale-if-error without a client signal; dashboard counts unenforced conda verdicts as blocked | not filed yet |  |
