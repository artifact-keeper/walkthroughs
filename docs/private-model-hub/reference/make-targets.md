# Make targets

--8<-- "includes/preview-hf.md"

Run from `private-model-hub/`. `make all` runs every target from `registry-up` to `freeze` in
order; each one is also safe to run on its own once the ones before it have run.

| Target | Script | What it does | Page |
|---|---|---|---|
| `registry-up` | `registry/up.sh`, `lab-hub/up.sh` | Starts the `ak-hf` stack (generates `registry/.env`, exports the CA) and the lab Hub at `.200` | [Step 1](../1-stand-up-the-registry.md) |
| `bootstrap` | `registry/bootstrap.sh` | Package proxies, `hf-hub` and `hf-lab` (frozen), users and tokens, the podman auth file | [Step 1](../1-stand-up-the-registry.md) |
| `client` | `client/build.sh` | Builds `localhost/ak-hf/workstation:latest` through the registry | [Step 1](../1-stand-up-the-registry.md) |
| `proxy` | `flows/proxy.sh` | `snapshot_download`, `hf download`, `encode` through `hf-lab` and `hf-hub`; a second pull | [Step 2](../2-proxy-the-hub.md) |
| `gated` | `flows/gated.sh` | `hf-lab-gated` with the Hub token, group `ml-team`, alice and bob | [Step 3](../3-gated-and-private-models.md) |
| `allowlist` | `flows/allowlist.sh` | `hf-curated` with an upstream filter | [Step 4](../4-approve-model-sources.md) |
| `host` | `flows/host.sh` | `hf-local`, `hf-models`; publishes `acme/embedder` and uses it | [Step 5](../5-host-your-own-models.md) |
| `hold` | `flows/hold.sh` | `hf-staging`: hold, scan on upload, `block_unscanned`, reviewer actions | [Step 6](../6-scan-and-hold.md) |
| `freeze` | `flows/freeze.sh` | Seeds, disconnects, loads from a workstation with no route out, reconnects | [Step 7](../7-freeze-and-go-offline.md) |
| `gates` | `gates/run-all.sh` | G1-G8; one line per check, `out/gates/results.tsv`, per-gate logs | [Step 8](../8-prove-it-fails-safely.md) |
| `screens` | `screens/shoot.sh` | Web UI screenshots into `out/screens/` (Playwright) | [Results](../results.md) |
| `screens-ready` | | Prints the UI URL and where the admin password is | |
| `registry-down` | `lab-hub/down.sh`, `registry/down.sh` | Stops everything, keeps the volumes | |
| `clean` | `lab-hub/down.sh`, `registry/clean.sh` | Removes the `ak-hf-*` containers, `ak-hf_*` volumes, both networks, the workstation image and all local state | |

Environment variables read by the scripts:

| Variable | Default | Effect |
|---|---|---|
| `AK_BACKEND_IMAGE`, `AK_WEB_IMAGE` | `BACKEND_IMAGE`, `WEB_IMAGE` in `registry/.env` | Images for one run (the nightly runner sets them) |
| `READY_TIMEOUT` | 300 | Seconds `registry/up.sh` waits for `/readyz` |
| `RUST_LOG` | `info,artifact_keeper=debug,tower_http=info` | Backend log level |

Ports, names and subnets (all in `registry/.env` and `registry/lib.sh`): host port
`127.0.0.1:30449`; containers `ak-hf-*`; volumes `ak-hf_*`; networks `ak-hf-net`
(`172.31.80.0/24`) and `ak-hf-offline` (`172.31.81.0/24`, internal).
