# registry

- `compose/docker-compose.yml`, `compose/docker/*`: upstream Artifact Keeper files, unmodified
  (see `compose/VERSIONS`).
- `compose/compose.override.yml`: every local change (images from `BACKEND_IMAGE`/`WEB_IMAGE`,
  `ak-conda-*` container names, networks `ak-conda-net` and `build-isolated`, Caddy alias
  `ak.internal`, only `127.0.0.1:30444` published, lab settings). Comments explain each.
- `caddy/Caddyfile`: one site, `ak.internal` (+ `localhost`, `127.0.0.1`), `tls internal`.
- `up.sh`: generates `.env` with secrets on first run, starts the stack, exports the CA to
  `out/ak-internal-ca.crt`, waits for `/readyz`. `AK_BACKEND_IMAGE` / `AK_WEB_IMAGE` override the
  images for one run.
- `bootstrap.sh`: idempotent. Repositories, scan-on-upload, the `conda-release-gate` policy,
  tokens (`.tokens/`), podman auth files, the CA in the `trust` repository.
- `down.sh [--volumes]`.
- `lib.sh`: shared helpers (`akcurl`, `compose`, `admin_token`).

Tokens in `.tokens/`: `admin.token` (scripts), `ci.token` (repo token, write on
`conda-staging`), `ci-oci.token` (repo token, write on `oci-apps`), `consumer.token` (user
`consumer`, `read:artifacts`, repository selector over the consumer repositories),
`consumer-repo.token` (repo token on `conda-virtual`, kept to show it cannot read through a
virtual repository), and `*-auth.json` (the `RATTLER_AUTH_FILE` format) / `*-podman.json`.
