# Private conda channel for pixi, with supply-chain controls

Code for the walkthrough planned in
[`docs/private-conda-channel-pixi/plan.md`](../docs/private-conda-channel-pixi/plan.md); lab notes
and gate results in [`findings.md`](../docs/private-conda-channel-pixi/findings.md).

Artifact Keeper runs as compose project `ak-conda` on a private podman network and answers as
`https://ak.internal` (TLS from Caddy's internal CA). Every client (pixi, rattler-build, the image
build) is a container on that network. Nothing in this directory needs sudo.

| Directory | What |
|---|---|
| `registry/` | the stack (upstream compose + override), Caddy, `up.sh`, `bootstrap.sh` (repositories, tokens, release gate) |
| `client/` | the pixi client image: pixi 0.81.0 through the registry, the CA, `/etc/pixi/config.toml` |
| `signing/` | cosign keys for the CI signer (and a wrong key for negative tests) |
| `packages/` | rattler-build recipes and build / publish / attest / scan / promote scripts |
| `project/`, `project-direct/` | the consumer: one virtual channel (target), or internal + conda-forge mirror (works on main) |
| `image/` | pixi on UBI micro, built on the registry network with an attestation gate; push and sign |
| `scan/` | Syft + Grype, registry SBOM, PURL blast radius |
| `allowlist/` | the lockfile as the allowlist of `conda-virtual`: `from-lock.sh`, `show.sh`, `off.sh` |
| `gates/` | G1-G14 as runnable checks: PASS / FAIL / BLOCKED(Fn) |

## Run it

```console
make all-main        # on Artifact Keeper main (BACKEND_IMAGE default)
make all             # on the fixed backend: no workarounds, attestation gate enforced
make gates           # re-run the gates any time
make allowlist       # admit only project/pixi.lock's packages on conda-virtual; make allowlist-off undoes it
make screens-ready   # UI URL and credentials
```

Requirements: rootless podman with `podman compose`, cosign 3, skopeo, jq, zstd, curl, openssl
on the host. About 6 GB of images.

The only host port is `127.0.0.1:30444` (Caddy 443). Browse `https://127.0.0.1:30444` (the
certificate is from the stack's own CA, `registry/out/ak-internal-ca.crt`); log in as `admin` with
`ADMIN_PASSWORD` from `registry/.env`. From scripts on the host, reach the registry by its real
name with `curl --resolve ak.internal:30444:127.0.0.1 --cacert registry/out/ak-internal-ca.crt`.

Switch backend or web image: set `BACKEND_IMAGE` / `WEB_IMAGE` in `registry/.env` and run
`registry/up.sh`.

Secrets (never committed): `registry/.env`, `registry/.tokens/`, `signing/keys/`; outputs in
`out/`, `packages/out/`.
