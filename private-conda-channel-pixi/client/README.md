# client

`localhost/ak-conda/pixi-client:0.81.0`: `ghcr.io/prefix-dev/pixi:0.81.0` pulled through the
registry's `oci-ghcr` proxy, plus the internal CA in the system trust store and:

- `pixi-config.toml` -> `/etc/pixi/config.toml`: `tls-root-certs = "system"`, conda-forge mirrored
  to `https://ak.internal/conda/conda-forge`, PyPI index for `pixi init`.
- `rattler-config.toml` -> `/etc/rattler/config.toml`: the shared subset (rattler-build reads it).

No credentials: containers get `RATTLER_AUTH_FILE` as a mounted file. The block marked
`WORKAROUND` disables CEP-16 shards for the hosted channels on Artifact Keeper main (F4);
`CLIENT_SHARDS=on client/build.sh` builds without it. `CLIENT_TAG` sets the tag.
