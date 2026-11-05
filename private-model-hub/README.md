# A private Hugging Face model hub on Artifact Keeper

> **An example, not a complete defense.** This shows one way to run a private Hugging Face model
> hub on Artifact Keeper. The configuration is an example, built and tested in a lab. It does
> not cover every edge case or attack, and it is not a hardened production setup; in
> particular, nothing here inspects model files. Known gaps are in the
> [findings](../docs/private-model-hub/findings.md). Review and adapt it for your environment,
> and use it alongside your other controls, not instead of them.

Code for the walkthrough at [`docs/private-model-hub/`](../docs/private-model-hub/index.md)
(lab notes in [`findings.md`](../docs/private-model-hub/findings.md)).

**Needs Artifact Keeper `main`** (coming in 1.12.0): the HTTP Range fix (artifact-keeper#5145)
and the hosted `snapshot_download` fix
([artifact-keeper#5300](https://github.com/artifact-keeper/artifact-keeper/pull/5300), issue
[#5280](https://github.com/artifact-keeper/artifact-keeper/issues/5280), `main` at `6c701cd4`).
See [Images](#images).

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

`registry/.env.example` names `localhost/ak-backend:hf-709e3f15`, a build of the #5300 branch
(its Hugging Face code is identical to `main` at `6c701cd4`), because no `:dev` image built from
`6c701cd4` or later existed yet. Use one of these:

- **`:dev` from `6c701cd4` or later** (preferred, once it exists): set `BACKEND_IMAGE` in
  `registry/.env` to `ghcr.io/artifact-keeper/artifact-keeper-backend:dev@sha256:...`, or pass
  `AK_BACKEND_IMAGE` for one run (the nightly runner does). Check that the image's
  `org.opencontainers.image.revision` label is `6c701cd4` or a later `main` commit.
- **1.12.0 or later**, once released.
- **A local build of `main`**, with the tag the file names:

  ```console
  git clone https://github.com/artifact-keeper/artifact-keeper
  podman build -f artifact-keeper/docker/Dockerfile.backend -t localhost/ak-backend:hf-709e3f15 artifact-keeper
  ```

  The backend is a Rust build: give it a machine with plenty of memory.

With an older image everything runs, and gate G5 reports the hosted `snapshot_download` check
`BLOCKED(ak-fix)`. The commits of the reference run are in `registry/compose/VERSIONS`; client
pins are in `client/VERSIONS`.

Secrets (never committed): `registry/.env`, `registry/.tokens/` (including the lab Hub's token
for its gated model). Outputs: `out/`, `registry/out/` (the CA certificate), `client/.work/`.
