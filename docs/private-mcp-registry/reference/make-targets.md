# Reference: make targets

--8<-- "includes/preview-mcp.md"

Run every target from `private-mcp-registry/`; `make help` prints this list. `make all` runs
them in order from an empty registry. The flows are written to run once after `make clean`;
most of them skip what is already done, but [Step 3](../3-curate-the-public-registry.md)'s drift
edit and the CI jobs are meant for a fresh run.

| Target | What it does | Script |
|---|---|---|
| `registry-up` | Starts the `ak-mcp` compose project (generates `registry/.env`, the lab bundle signer and its fingerprint on the first run), exports Caddy's root CA, waits for `/readyz`; starts the lab registry | [`registry/up.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/registry/up.sh), [`lab-registry/up.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/lab-registry/up.sh) |
| `registry-down` | Stops the lab registry and the stack; keeps the volumes | [`registry/down.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/registry/down.sh) |
| `bootstrap` | Repositories `npm-internal`, `npm-remote`, `npm`, `oci-internal`, `mcp-internal`; the scan policy; users `ci` and `developer` with their permissions and tokens | [`registry/bootstrap.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/registry/bootstrap.sh) |
| `client` | Builds `localhost/ak-mcp/workstation:latest` | [`client/build.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/client/build.sh) |
| `publish` | npm package, image, `/validate`, `mcp-publisher publish` of `com.acme/tickets` 1.0.0 | [`flows/publish.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/flows/publish.sh) |
| `clients` | The requests VS Code and Copilot send; client configuration in `out/clients/`; Claude Code `mcp add` and `mcp list`; a tool call with `mcp-call` | [`flows/clients.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/flows/clients.sh) |
| `curate` | `oci-ghcr`, `mcp-upstream`; sync, queue, request, approve, block, deny, pin, pull-through, drift, holds, audit | [`flows/curate.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/flows/curate.sh) |
| `supply-chain` | own-repos refusals, the digest pin and a tag move, quarantine, the lint | [`flows/supply-chain.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/flows/supply-chain.sh) |
| `ci` | CI OIDC provider and mapping, the namespace grant, four CI jobs with `mcp-publisher login github-oidc` | [`flows/ci.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/flows/ci.sh), [`ci/lab-issuer.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/ci/lab-issuer.sh) |
| `virtual` | The Virtual `mcp`, hosted shadows remote, a cursor walk, the clients on one URL | [`flows/virtual.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/flows/virtual.sh) |
| `bundles` | Signed MCPB bundles, download tickets, capability snapshots and a diff | [`flows/bundles.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/flows/bundles.sh) |
| `gates` | G1 to G9; verdicts in `out/gates/results.tsv`, logs in `out/gates/gNN.log` | [`gates/run-all.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/gates/run-all.sh) |
| `screens` | Web UI screenshots into `out/screens/` | [`screens/shoot.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/screens/shoot.sh) |
| `screens-ready` | Prints the UI address and where the credentials are | [`Makefile`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/Makefile) |
| `all` | `registry-up` through `bundles` | [`Makefile`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/Makefile) |
| `clean` | Removes the containers (stack and lab registry), volumes, network, the images built here, `registry/.env`, tokens, the signer and `out/`. Keeps pulled images and the backend and web builds | [`registry/clean.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/registry/clean.sh) |
