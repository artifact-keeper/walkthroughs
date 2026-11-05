# A private Hugging Face model hub on Artifact Keeper

> **An example, not a complete defense.** This shows one way to run a private Hugging Face model
> hub on Artifact Keeper. The configuration is an example, built and tested in a lab. It does
> not cover every edge case or attack, and it is not a hardened production setup; in
> particular, nothing here inspects model files. Known gaps are in the
> [findings](../docs/private-model-hub/findings.md). Review and adapt it for your environment,
> and use it alongside your other controls, not instead of them.

Code for the walkthrough at [`docs/private-model-hub/`](../docs/private-model-hub/index.md)
(lab notes in [`findings.md`](../docs/private-model-hub/findings.md)).

**Runs `main`** (`ghcr.io/artifact-keeper/artifact-keeper-backend:dev`, pinned by digest in
`registry/.env.example`) for the HTTP Range fix (artifact-keeper#5145). `snapshot_download`
from a Local repository also needs
[artifact-keeper#5280](https://github.com/artifact-keeper/artifact-keeper/issues/5280), not
merged yet; until it is in the image, gate G5 reports that check `BLOCKED(ak-fix)`. See
[Images](#images).

Artifact Keeper runs as compose project `ak-hf` on the podman network `ak-hf-net` and answers
as `https://ak.internal` (TLS from Caddy's internal CA). A lab Hub at `.200` of that network
stands in for huggingface.co (also as `cdn.lab`, its CDN). Every client (`hf`,
`huggingface_hub`, `transformers`, `sentence-transformers`) runs in the workstation container,
built through the registry, with a throwaway home under `out/homes/`. Step 7 runs it on
`ak-hf-offline`, an internal network where Caddy is the only other host. Nothing here needs
sudo or a Hugging Face account.

| Directory | What |
|---|---|
| `registry/` | the stack (upstream compose + override), Caddy, `up.sh`, `bootstrap.sh` (package proxies, the Hub Remotes, users, tokens), `clean.sh` |
| `lab-hub/` | the lab Hub (`server.py`, standard library only): model info, tree, resolve with CDN redirects, a gated model, Xet metadata, a request log |
| `client/` | the workstation image (`Containerfile`, pins in `VERSIONS`), `run.sh`, `hfcheck.py` (the client calls, with JSON output) |
| `flows/` | one script per make target from `proxy` to `freeze` |
| `gates/` | G1-G8 as runnable checks: PASS / FAIL / BLOCKED |
| `screens/` | the web UI screenshots (Playwright) |

## Run it

```console
make all             # registry, bootstrap, client, proxy, gated, allowlist, host, hold, freeze
make gates           # the eight gates; results in out/gates/
make screens         # web UI screenshots into out/screens/ (optional)
make screens-ready   # UI URL and credentials
make clean           # remove everything it created (keeps pulled images)
```

Requirements: rootless podman 5.x with `podman compose`, curl, jq, openssl, python3, GNU make,
and internet access (images from docker.io, ghcr.io and mcr.microsoft.com; pypi.org and
download.pytorch.org through the registry; huggingface.co for the real-Hub checks, which
report `BLOCKED(network)` without it). The only host port is `127.0.0.1:30449` (Caddy 443).
From the host, reach the registry by its real name with
`curl --resolve ak.internal:30449:127.0.0.1 --cacert registry/out/ak-internal-ca.crt`.

## Images

`registry/.env.example` pins the `:dev` images of `main` by digest. To run another build for one
run, pass `AK_BACKEND_IMAGE` / `AK_WEB_IMAGE` (the nightly runner does). To try the hosted
`snapshot_download` fix before it is in `:dev`, build the backend from its branch and pass it:

```console
podman build -f artifact-keeper/docker/Dockerfile.backend -t localhost/ak-backend:hf-<sha> artifact-keeper
AK_BACKEND_IMAGE=localhost/ak-backend:hf-<sha> make all gates
```

The commits of the reference run are in `registry/compose/VERSIONS`; client pins are in
`client/VERSIONS`.

Secrets (never committed): `registry/.env`, `registry/.tokens/` (including the lab Hub's token
for its gated model). Outputs: `out/`, `registry/out/` (the CA certificate), `client/.work/`.
