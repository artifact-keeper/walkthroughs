# The off-grid AI stack on Artifact Keeper

> **An example, not a complete defense.** This shows one way to run an AI stack from one
> Artifact Keeper instance and keep it working with no route out. The configuration is an
> example, built and tested in a lab. It does not cover every edge case or attack, and it is
> not a hardened production setup. Known gaps are in the
> [findings](../docs/off-grid-ai-stack/findings.md). Review and adapt it for your environment,
> and use it alongside your other controls, not instead of them.

Code for the walkthrough at [`docs/off-grid-ai-stack/`](../docs/off-grid-ai-stack/index.md)
(lab notes in [`findings.md`](../docs/off-grid-ai-stack/findings.md)).

**Needs Artifact Keeper `main`** (coming in 1.12.0), at or after `f0d9b638`: cache-only Remotes,
the `UPSTREAM_FETCHED` audit event, the upstream-jobs switch, cache seeding, the agentplugins
Remote, config export, the model-file scanner, commit-pinned Hugging Face paths, and the
scanner adapter's offline mode. See [Images](#images).

Artifact Keeper runs as compose project `ak-offgrid` and answers as `https://ak.internal` (TLS
from Caddy's internal CA). It starts on `ak-offgrid-seed` (172.31.84.0/24, a route out) and
`make disconnect` recreates every container on `ak-offgrid-site` (172.31.85.0/24,
`internal: true`: no gateway). The egress ledger, a logging forward proxy at `.200`, is every
Remote's egress proxy, on whichever network the stack is on. llama-server, the agent, Claude
Code and every check run in containers on the same network. Nothing here needs sudo or an
account anywhere.

| Directory | What |
|---|---|
| `registry/` | the stack (upstream compose + `compose.override.yml` + `compose.site.yml`), Caddy, `up.sh`, `bootstrap.sh` (every repository, the offline settings, users, tokens), `clean.sh` |
| `ledger/` | the egress ledger (`server.py`, standard library only) |
| `seed/` | `manifest.toml` (everything the site needs), `seed.sh`, `inventory.sh` |
| `tools/acme-inventory/` | Acme's internal MCP server, its deterministic wheel builder and its `server.json` |
| `plugins/offgrid-ops/` | the agent's plugin: which MCP servers to start, and its skill |
| `agent/` | the agent (`agent.py`), its image (`Containerfile`, hash-pinned `requirements.lock`), `run.sh` |
| `claude/` | the Claude Code image for the best-effort step |
| `flows/` | `vet`, `disconnect`, `agent`, `claude`, `reconnect` |
| `gates/` | G1-G7 as runnable checks: PASS / FAIL / BLOCKED |

## Run it

```console
make all             # registry, bootstrap, seed, vet, disconnect, agent, claude
make gates           # the seven gates; results in out/gates/
make reconnect       # back to the seed network (to seed something new)
make clean           # remove everything it created (keeps pulled images)
SMALL_MODEL=1 make all   # Qwen2.5-0.5B (491 MB) instead of Qwen2.5-1.5B (1.1 GB)
```

Requirements: rootless podman 5.x with `podman compose`, curl, jq, openssl, python3 (3.11 or
later, for `tomllib`), GNU make, about 8 GB of free RAM and 20 GB of disk, and internet access
while seeding (docker.io, ghcr.io, pypi.org, registry.npmjs.org, huggingface.co and
registry.modelcontextprotocol.io, all through the registry; the stack's own images directly).
The only host port is `127.0.0.1:30450` (Caddy 443). From the host, reach the registry by its
real name with `curl --resolve ak.internal:30450:127.0.0.1 --cacert registry/out/ak-internal-ca.crt`.

## Images

`registry/.env.example` names `:dev` of the backend, web and scanner-adapter images. Pin them
by digest to a build of `main` at or after `f0d9b638` (check the
`org.opencontainers.image.revision` label), or use 1.12.0 once it is released. Pass
`AK_BACKEND_IMAGE` / `AK_WEB_IMAGE` / `AK_SCANNER_ADAPTER_IMAGE` for one run (the nightly
runner does). The images of the reference run are in `registry/compose/VERSIONS`; the
client pins are in `agent/VERSIONS`, `agent/requirements.lock`, `ledger/VERSIONS` and
`seed/manifest.toml`.

Secrets (never committed): `registry/.env`, `registry/.tokens/`. Outputs: `out/`,
`registry/out/` (the CA certificate and the phase), `agent/.work/`, `claude/.work/`.
