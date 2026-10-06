# registry/ — Artifact Keeper as the single source of truth

This directory runs [Artifact Keeper](https://github.com/artifact-keeper/artifact-keeper)
(release **v1.10.2**) locally with **rootless podman** and bootstraps the
repositories the rest of the PoC consumes: RPM proxies for Rocky Linux 10 /
EPEL 10 / k3s / RKE2, a hosted RPM repo for our own packages (with Artifact Keeper
signing its repodata), a hosted OCI repo for bootc images (and their cosign
signatures), quay.io + Docker Hub pull-through proxies, and a generic repo that
serves the public keys every consumer verifies with.

## Layout

| Path | What |
|---|---|
| `compose/docker-compose.yml` | Upstream stock compose file, **unmodified**, from tag v1.10.2 |
| `compose/docker/` | Upstream support files (`Caddyfile`, `init-db.sql`, `init-pg-ssl.sh`, `init-dtrack.sh`), unmodified |
| `compose/compose.override.yml` | Every local change (see *Deviations*) |
| `compose/VERSIONS` | Upstream tag/commit and the image digests actually run |
| `.env.example` | Template; `up.sh` copies it to `.env` and fills in secrets |
| `up.sh` / `down.sh` | Start (and wait for `/readyz`) / stop the stack |
| `bootstrap.sh` | Idempotent: creates repos, enables repodata signing on `rpm-edge-site`, mints CI token, writes `out/` |
| `test/edge-hello.spec` | Trivial noarch RPM used to prove the hosted RPM repo |
| `VERIFICATION.md` | Exact commands and outputs of the end-to-end checks |
| `.env`, `.ak-token`, `out/` | Generated, **gitignored** |

## Ports

Only Caddy is published on the host:

| Port | Use |
|---|---|
| `30080` | HTTP: web UI, `/api/v1`, `/rpm/<key>`, OCI `/v2` — everything in this PoC uses this |
| `30443` | HTTPS with Caddy's internal CA for `localhost` (not used here) |

Override with `HTTP_PORT` / `HTTPS_PORT` in `.env`. Postgres, OpenSearch, the
backend (8080) and web (3000) are only reachable on the compose network.

The host, podman builds and the VM reach it under three different names; see
[Two views of the same registry](https://artifact-keeper.github.io/walkthroughs/rocky-linux-image-mode-bare-metal/architecture/#two-views-of-the-same-registry).

## Usage

```bash
cd registry
./up.sh                       # first run generates .env, pulls images, waits for /readyz (~60 s cold)
./bootstrap.sh                # creates repos + token + out/edge.repo (safe to re-run)
HOST=10.0.2.2 ./bootstrap.sh  # same, but out/edge.repo points at the VM's view of the host
./down.sh                     # stop (data kept in named volumes)
./down.sh -v                  # stop and DELETE all volumes (repos, artifacts, DB)
```

Optional: `COMPOSE_PROFILES=scanners ./up.sh` brings Trivy and OpenSCAP back.

Web UI: http://localhost:30080/ (user `admin`, password in `.env`).

### Repositories created by `bootstrap.sh`

Twelve repositories, all created with `is_public: true` (anonymous reads; writes need
auth). The list with upstreams: [Architecture](https://artifact-keeper.github.io/walkthroughs/rocky-linux-image-mode-bare-metal/architecture/#artifact-keeper-repositories).

### Signing

- **`rpm-edge-site` repodata is signed by Artifact Keeper.** `bootstrap.sh` creates a
  server-side OpenPGP key through the signing API and turns on `sign_metadata`:
  ```
  POST /api/v1/signing/keys  {"name":"rpm-edge-site repodata","key_type":"gpg","algorithm":"rsa4096",
                              "repository_id":"<id of rpm-edge-site>","uid_name":"Artifact Keeper rpm-edge-site",
                              "uid_email":"rpm-edge-site@example.invalid"}
  POST /api/v1/signing/repositories/<repo id>/config  {"signing_key_id":"<key id>","sign_metadata":true}
  ```
  AK then serves `/rpm/rpm-edge-site/repodata/repomd.xml.asc` (detached OpenPGP
  signature, 7-day expiry, re-signed on demand) and `repomd.xml.key`. `key_type` must be
  `gpg` for rpm repos. Re-runs detect the existing config and do nothing.
- **Proxy repos pass the upstream `repomd.xml.asc` through unchanged** (Rocky x3, RKE2 x2
  verified byte for byte and with the vendor keys). EPEL 10 and Rancher's k3s el9 tree
  publish none (404 upstream and in AK).
- **`raw-edge-keys`** (format `generic`) holds `edge-cosign.pub`, `RPM-GPG-KEY-edge`,
  `RPM-GPG-KEY-Rancher`, `RPM-GPG-KEY-EPEL-10`, downloadable anonymously at
  `http://<host>:30080/api/v1/repositories/raw-edge-keys/download/<file>`. The backend's
  native `/general/<key>/<file>` route is not routed by the stock Caddyfile (you get the
  web UI's 404 page). Paths are write-once (409); deleting needs `delete:artifacts`,
  which the CI token does not have.
- **cosign signatures** are stored by the OCI registry as `sha256-<digest>.sig` tags next
  to the image (classic sigstore attachment). AK's referrers API also works (cosign 3's
  default bundle format lands there), but podman/bootc cannot read that format.
  AK itself neither signs nor verifies images.

Notes on upstreams:

- **RKE2**: Rancher publishes real EL10 RPMs. Every minor 1.32-1.37 under
  `rke2/stable/<minor>/centos/10/x86_64/` had `repodata/` on 2026-10-05; the
  `stable` channel (`https://update.rke2.io/v1-release/channels`) was
  `v1.36.5+rke2r1` (`latest` = 1.37.1), so the minor repo is `rpm-rke2-1.36`.
  Bump by adding a new `rpm-rke2-<minor>` line; the old one stays for rollback.
- **Docker Hub proxy**: images are addressed as
  `localhost:30080/oci-dockerhub-proxy/<hub path>`; both `library/nginx:alpine`
  and the short `nginx:alpine` resolve (same digest as docker.io). The token
  realm in `Www-Authenticate` follows the request's `Host` header
  (`http://10.0.2.2:30080/v2/token` when asked as 10.0.2.2), so in-VM clients work.

- **EPEL 10** is versioned by minor (`10.0` ... `10.4`, `10z`, `10s`) but
  `/pub/epel/10/Everything/x86_64/` exists and carries `repodata/` (it tracks
  the current minor; `10.2` also has repodata, `10.0`/`10.1` return 404 now).
- **k3s**: Rancher's RPM repo has no el10 path (`.../centos/10/noarch/` is 404
  for both `stable` and `latest`). `centos/9/noarch` contains only
  `k3s-selinux` (1.3–1.6, `.el9`), not k3s itself; k3s is a static binary
  normally installed by `get.k3s.io`. The repo is created anyway so the image
  build can `dnf install k3s-selinux`; the k3s binary must come from elsewhere
  (e.g. a generic/hosted artifact or an RPM we build into `rpm-edge-site`).

### Credentials

| What | Where |
|---|---|
| Admin password (user `admin`), JWT secret, webhook key | `registry/.env` (mode 600, gitignored) |
| CI API token (`read:artifacts`,`write:artifacts`, 30 days, owned by admin) | `registry/.ak-token` (mode 600, gitignored). `bootstrap.sh` reuses it while `GET /api/v1/auth/me` accepts it, otherwise mints a new one |

Using the token:

```bash
curl -u "admin:$(cat registry/.ak-token)" -T foo.rpm \
  http://localhost:30080/rpm/rpm-edge-site/packages/foo.rpm
podman login --tls-verify=false -u admin --password-stdin localhost:30080 < registry/.ak-token
podman push  --tls-verify=false localhost:30080/oci-bootc/edge:latest
```

### Generated client config (`out/`)

- `out/edge.repo` — dnf repo file for all `rpm-*` repos,
  `baseurl=http://$HOST:30080/rpm/<key>`, `gpgcheck=1` everywhere, `repo_gpgcheck=1` for
  Rocky, RKE2 and `rpm-edge-site` (EPEL and k3s do not sign repomd.xml), `gpgkey=` the
  in-image Rocky key (`file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10`) or the
  `raw-edge-keys` URLs, plus AK's `repomd.xml.key` for `rpm-edge-site`.
  `HOST` defaults to `localhost`.
- `out/edge.repo.in` — same with `@HOST@` placeholders (in `baseurl=` and `gpgkey=`), for
  `sed 's/@HOST@/10.0.2.2/g'` etc.
- `out/README-urls.md` — every endpoint/URL for the chosen host.

## Deviations from upstream (and docs-vs-reality notes)

All compose changes live in `compose/compose.override.yml`; the stock file is
byte-identical to upstream v1.10.2.

1. **Pinned images.** Stock compose uses `:latest` for backend (via
   `ARTIFACT_KEEPER_VERSION`), and hardcodes `:latest` for web and openscap
   (they ignore `ARTIFACT_KEEPER_VERSION`). Override pins backend/openscap to
   `1.10.2`. **There is no `1.10.2` tag for `artifact-keeper-web`** on ghcr.io
   (newest 1.10.x is `1.10.1`), so web runs `1.10.1`.
2. **Scanners disabled.** Trivy and OpenSCAP are moved to a `scanners` profile.
   Not needed for the edge demo and saves pulls/RAM. The backend tolerates their
   absence: `/readyz` does not check them; it logs
   `WARN ... Service 'trivy' is unavailable` / `'openscap' is unavailable`
   once a minute. Dependency-Track is already behind a profile upstream.
3. **Internal ports unpublished.** Stock compose publishes Postgres on
   `0.0.0.0:30432` (user/password `registry`/`registry`), OpenSearch on `9200`,
   Trivy `8090`, OpenSCAP `8091`. Override uses `ports: !reset []` so only Caddy
   is exposed.
4. **Fully-qualified image names.** Stock compose uses short names
   (`postgres:18-alpine`, `alpine:3.24`, `caddy:2-alpine`). On rootless podman
   (`short-name-mode = "enforcing"`), short names are matched against *local*
   storage first by trailing path; on this host `postgres:18-alpine` silently
   resolved to a previously cached `ghcr.io/artifact-keeper/ci-mirror/postgres:18-alpine`.
   Override qualifies them as `docker.io/library/...`.
5. **Secrets are mandatory, not optional.** The compose defaults are fatal:
   `JWT_SECRET=change-me-in-production-please` is on the backend's placeholder
   denylist (rejected regardless of `ENVIRONMENT`), and
   `AK_WEBHOOK_SECRET_KEY=REPLACE_ME_WITH_OUTPUT_OF_openssl_rand_base64_32` is
   "set but invalid" so the backend does `exit(1)` (it must base64-decode to
   exactly 32 bytes). The quickstart/installation docs show only `JWT_SECRET`
   in `.env` and never mention `AK_WEBHOOK_SECRET_KEY`. `up.sh` generates both
   (`openssl rand -base64 48` / `-base64 32`) plus a random alphanumeric
   `ADMIN_PASSWORD`, which skips the first-boot setup lock (otherwise the API
   is locked until the random password in `/data/storage/admin.password` is
   changed).
6. **podman-compose vs `podman compose`.** Docs say "replace `docker compose`
   with `podman-compose`". We use `podman compose`, which here delegates to
   docker-compose v5.5.1 talking to the rootless podman socket; it handled the
   compose file (incl. `depends_on.required: false`,
   `service_completed_successfully`, the fixed `172.30.0.0/24` network, and
   `!reset` in the override) with no changes. Nothing needed sudo;
   `vm.max_map_count` was already high enough for OpenSearch.
7. **`.env` location.** Compose files live in `compose/` but `.env` lives in
   `registry/`, so the scripts pass `--env-file` and `-p artifact-keeper`
   explicitly (project name keeps container/volume names stable).
8. **Repository visibility field.** The create-repository API takes
   `is_public` (or its alias `allow_anonymous_access`); there is no
   `visibility` field in v1.10.2 (`CreateRepositoryRequest` in
   `backend/src/api/handlers/repositories.rs`). Repos default to private.
9. **RPM upload path in docs is wrong.** `guides/system-packages.mdx` shows
   `curl -F file=@pkg.rpm http://localhost:8080/api/artifacts/rpm/<repo>`; on
   v1.10.2 that returns `HTTP 404 Repository not found`. The working routes
   (from `backend/src/api/handlers/rpm.rs`) are
   `PUT /rpm/<key>/packages/<file>.rpm` (used here) and `POST /rpm/<key>/upload`.
   Basic auth with an API token as the password works. Repodata is generated
   by the server; no `createrepo_c` step. The docs also use port `8080`
   throughout the format guides, while the compose stack serves on `30080`.
10. **RPM remote upstream must be a concrete baseurl** (no mirrorlist/metalink),
    per the docs; the Rocky `dl.rockylinux.org` and Fedora `dl.fedoraproject.org`
    baseurls above work. Private-IP upstreams would additionally need
    `AK_SSRF_ALLOW_PRIVATE_CIDRS` (not needed here).
11. **OCI auth flow.** Anonymous pulls from public repos work with real OCI
    clients (`skopeo --no-creds`), but a raw anonymous `curl` of `/v2/...`
    returns `401` with `Www-Authenticate: Bearer realm="http://localhost:30080/v2/token"`;
    clients must do the token dance. Plain HTTP requires `--tls-verify=false`
    (or a `registries.conf` `insecure = true` entry for the edge node).
