# Make targets

--8<-- "includes/preview-offgrid.md"

Run from `off-grid-ai-stack/`. `make all` runs every target from `registry-up` to `claude` in
order; each one is also safe to run on its own once the ones before it have run. `seed` and
`vet` need the seed network; `agent`, `claude` and the gates G3 to G7 need the site network
(`make disconnect`). `registry/out/phase` says which one the stack is on.

| Target | Script | What it does | Page |
|---|---|---|---|
| `registry-up` | `registry/up.sh`, `ledger/up.sh` | Starts the `ak-offgrid` stack on the current network (generates `registry/.env`, exports the CA) and the egress ledger at `.200` | [Step 1](../1-stand-up-the-registry.md) |
| `bootstrap` | `registry/bootstrap.sh` | Every repository, the offline settings and the ledger on every Remote, the vetting policy, users and tokens | [Step 1](../1-stand-up-the-registry.md) |
| `lock` | `agent/lock.sh` | Re-resolves `agent/requirements.lock` (hash-pinned) through the registry | [Step 2](../2-seed-the-stack.md) |
| `seed` | `seed/seed.sh` | Pulls everything in `seed/manifest.toml` through the registry, publishes Acme's package, MCP entry and plugin, builds the agent and Claude Code images, writes `out/inventory/seed.tsv` | [Step 2](../2-seed-the-stack.md) |
| `vet` | `flows/vet.sh` | The model into `hf-models` (model-file scanner), two files that must not get through, the offline scanner adapter, the config export and plan | [Step 3](../3-vet-what-you-seeded.md) |
| `disconnect` | `flows/disconnect.sh` | Every Remote cache-only, the upstream jobs paused, the marks, the stack and the ledger moved to `ak-offgrid-site` | [Step 4](../4-disconnect.md) |
| `agent` | `flows/agent.sh` | The image and the model pulled again on the site, llama-server, a clean package install, the agent | [Step 5](../5-run-the-agent-offline.md) |
| `claude` | `flows/claude.sh` | Best-effort: Claude Code installs the plugin offline and asks the local model one thing | [Step 6](../6-claude-code-best-effort.md) |
| `gates` | `gates/run-all.sh` | G1-G7; one line per check, `out/gates/results.tsv`, per-gate logs | [Step 7](../7-prove-nothing-leaves.md), [Step 8](../8-prove-it-fails-safely.md) |
| `reconnect` | `flows/reconnect.sh` | Back to the seed network, every Remote online, the jobs resumed | [Next steps](../next-steps.md) |
| `registry-down` | `ledger/down.sh`, `registry/down.sh` | Stops everything, keeps the volumes | |
| `clean` | `ledger/down.sh`, `registry/clean.sh` | Removes the `ak-offgrid-*` containers, `ak-offgrid_*` volumes, both networks, the images it built or pulled through the registry, and all local state | |

Environment variables read by the scripts:

| Variable | Default | Effect |
|---|---|---|
| `SMALL_MODEL` | `0` | `1` uses SmolLM2-360M-Instruct (386 MB) instead of Qwen2.5-1.5B-Instruct (1.1 GB) everywhere: seed, vet, agent, gates |
| `AK_BACKEND_IMAGE`, `AK_WEB_IMAGE`, `AK_SCANNER_ADAPTER_IMAGE` | `BACKEND_IMAGE`, `WEB_IMAGE`, `SCANNER_ADAPTER_IMAGE` in `registry/.env` | Images for one run (the nightly runner sets them) |
| `READY_TIMEOUT` | 300 | Seconds `registry/up.sh` waits for `/readyz` |
| `LLAMA_THREADS`, `LLAMA_CTX` | 16, 32768 | llama-server's `-t` and `-c` |
| `QUESTION` | the stock question | What `make agent` asks the agent |
