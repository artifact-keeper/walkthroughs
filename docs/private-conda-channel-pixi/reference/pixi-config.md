# Reference: pixi and rattler configuration used

Verified with pixi 0.81.0 and rattler-build 0.76.1.

## Machine configuration (`/etc/pixi/config.toml`)

```toml
tls-root-certs = "system"          # webpki | system; the internal CA is in the system store

[mirrors]
# key: the channel URL written in manifests and pixi.lock; value: where bytes come from
"https://conda.anaconda.org/conda-forge" = ["https://ak.internal/conda/conda-forge"]

[pypi-config]
index-url = "https://ak.internal/pypi/pypi-remote/simple"   # used by `pixi init` only
```

- Lookup order (lowest first): `/etc/rattler/config.toml`, `/etc/pixi/config.toml`, user files,
  `$PIXI_HOME/config.toml`, `<workspace>/.pixi/config.toml`, command line.
- `/etc/rattler/config.toml` is shared with rattler-build; `pypi-config` there is ignored with a
  warning (`not a key of the shared configuration`).
- `SSL_CERT_FILE` / `SSL_CERT_DIR` take precedence over `tls-root-certs`.
- Per-channel repodata options, e.g. turning off CEP-16 shards:
  ```toml
  [repodata-config."https://ak.internal/conda/conda-internal"]
  disable-sharded = true
  ```
- A mirror for a hosted channel (lock portability, G12) is one more `[mirrors]` entry:
  `"https://ak.internal/conda/conda-internal" = ["https://other-mirror/conda-internal"]`.

## Credentials

Looked up by host name, **without the port** (store credentials for `ak.internal`, and serve the
registry on 443).

| Who | How |
|---|---|
| people | `pixi auth login ak.internal --token <token>` (keyring, or `~/.rattler/credentials.json` without one) |
| CI, containers | `RATTLER_AUTH_FILE=/run/secrets/rattler-auth.json` with `{"ak.internal": {"BearerToken": "<token>"}}` |
| image builds | the same file as a build secret: `RUN --mount=type=secret,id=rattler-auth,target=/run/secrets/rattler-auth.json` |

The same credentials are used for the PyPI index on that host. Other entry types:
`{"BasicHTTP": {"username": ..., "password": ...}}`, `{"CondaToken": ...}`.

## Workspace (`pixi.toml`)

```toml
[workspace]
channels = ["https://ak.internal/conda/conda-virtual", "https://ak.internal/conda/conda-internal"]
platforms = ["linux-64"]
channel-priority = "strict"
exclude-newer = "14d"

[dependencies]
acme-core = { version = ">=1.0,<2", channel = "https://ak.internal/conda/conda-internal" }

[exclude-newer]
acme-core = "0d"            # per-package exemption from the cooldown

[pypi-options]
index-url = "https://ak.internal/pypi/pypi-remote/simple"
```

- A dependency's `channel` must also be in `channels`
  (`requested unavailable channel` otherwise).
- `exclude-newer` filters on each record's `timestamp` (set by the build machine), not on a
  server-set time.

## Commands

| Command | Use |
|---|---|
| `pixi lock` | solve and write `pixi.lock` |
| `pixi install --locked` | install exactly the lock; fail if the manifest changed |
| `pixi install --frozen --offline` | install from the lock using only the cache |
| `pixi shell-hook --locked -s bash` | activation script for a container entrypoint |
| `pixi exec --spec rattler-build==0.76.1 -- rattler-build build --recipe-dir R -c conda-forge` | build |
| `rattler-build upload artifactory --url https://ak.internal/conda --channel conda-staging f.conda` | publish (credentials from `RATTLER_AUTH_FILE`) |
| `pixi search -p linux-64 -c <channel> <name>` | query (pass `-p`; see C7 in findings) |
