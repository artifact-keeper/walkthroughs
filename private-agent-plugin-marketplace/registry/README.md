# registry

- `compose/docker-compose.yml`, `compose/docker/*`: upstream Artifact Keeper files, unmodified
  (see `compose/VERSIONS`).
- `compose/compose.override.yml`: every local change (images from `BACKEND_IMAGE`/`WEB_IMAGE`,
  `ak-agents-*` container names, network `ak-agents-net`, Caddy aliases `ak.internal` and
  `mirror.internal`, only `127.0.0.1:30447` published, `AK_EXTERNAL_URL`, Trivy and OpenSCAP
  off). Comments explain each.
- `caddy/Caddyfile`: `ak.internal` (+ `localhost`, `127.0.0.1`) with `tls internal`, the token
  redacted from the access log, `Referrer-Policy: no-referrer` restored on the token route;
  `mirror.internal` serves `out/mirror/` (gate G5).
- `up.sh`: generates `.env` with secrets on first run, starts the stack, exports the CA to
  `out/ak-internal-ca.crt`, waits for `/readyz`. `AK_BACKEND_IMAGE` / `AK_WEB_IMAGE` override the
  images for one run.
- `bootstrap.sh`: idempotent. Repositories, scan on upload and the `agent-plugins-release`
  policy, users `ci` and `developer` with their permissions, tokens (`.tokens/`), the CA in the
  `trust` repository.
- `down.sh [--volumes]`, `clean.sh` (what `make clean` runs).
- `lib.sh`: shared helpers (`akcurl`, `compose`, `host_url`, `admin_token`, `tok`).

Tokens in `.tokens/` (mode 600): `admin.token` (the scripts), `ci.token` (user `ci`, read+write
on `agent-plugins`), `developer.token` (user `developer`, read only on `agent-plugins`),
`public-ci.token` (read+write on `agent-plugins-public`), and the two users' passwords.
