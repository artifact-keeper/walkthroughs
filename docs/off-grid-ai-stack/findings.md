# Lab notes: the off-grid AI stack

--8<-- "includes/preview-offgrid.md"

The record of building and running this walkthrough on 2026-11-05 (UTC): what we ran it on, the
Artifact Keeper bugs and gaps we hit, the behaviour worth knowing, what the [plan](plan.md) got
wrong, and what is not machine-verified. The step pages are written from these notes and from
the runs in [Results](results.md). Code references are to `artifact-keeper` `main` at `0bffa44c`.

<!-- REFRESH: the environment table and every "debug run" figure, from the final run. -->

## Environment

| | |
|---|---|
| Host | `grace`: x86_64, 40 cores, rootless podman 5.7 with `podman compose` (docker-compose as the external provider), no sudo |
| Backend | `localhost/ak-backend:offgrid-0bffa44c`, built locally from `main` at `0bffa44c` (reports 1.11.3), image ID `403e088c...`. The CI `:dev` image was older than the features this walkthrough needs because the CI amd64 builds were failing, so we built it ourselves |
| Scanner adapter | `localhost/ak-scanner-adapter:offgrid-0bffa44c`, same commit; Trivy 0.76.0 inside |
| Web | `ghcr.io/artifact-keeper/artifact-keeper-web:dev@sha256:7a0ec1f4...` |
| Model | `Qwen/Qwen2.5-1.5B-Instruct-GGUF` at `91cad51170dc346986eccefdc2dd33a9da36ead9`, `qwen2.5-1.5b-instruct-q4_k_m.gguf` (1,117,320,736 bytes); `SMALL_MODEL=1`: `Qwen/Qwen2.5-0.5B-Instruct-GGUF` at `9217f5db79a2`, 491,400,032 bytes |
| Model server | `ghcr.io/ggml-org/llama.cpp:server-b12124`, CPU, 16 threads, context 32768 |
| Agent | Python 3.12 (`python:3.12-slim-trixie`), `openai` 3.46.0, `mcp` 2.3.0, `huggingface_hub` 2.4.0, `mcp-sqlite3` 0.1.3, `fastmcp` 4.1.6; 71 packages in the lock |
| Claude Code | 2.1.318 on `node:22-bookworm-slim` |

## Artifact Keeper bugs and gaps

### F1. An MCP Remote syncs before its settings apply

Filed as [artifact-keeper#5402](https://github.com/artifact-keeper/artifact-keeper/issues/5402);
the fix is [#5406](https://github.com/artifact-keeper/artifact-keeper/pull/5406). The settings
that make a Remote safe to run offline or under an egress audit (`PUT .../egress-proxy`,
`.../upstream-mode`, `.../cache-ttl`) are separate routes that can be called only once the
repository exists. A new MCP Remote is due for a sync at once, so the scheduler's next tick
syncs it: in the lab the backend log showed `Fetching artifact from upstream:
https://registry.modelcontextprotocol.io/v0.1/servers` within the same second as the create,
and the ledger saw none of those first pages. The per-repository egress client is also cached
for 60 s, and a sync already in flight keeps the client it started with.

The workaround in [`registry/bootstrap.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/registry/bootstrap.sh):
pause every scheduled upstream job (`upstream_jobs_paused`, #5317) before creating any
repository and resume at the end. It pauses the whole instance, and it works only if the
operator knows to do it. #5406 lets the Remote be created with its settings; the pause can go
once it lands.

### F2. A manual MCP sync is cut off by the request timeout

Filed as [artifact-keeper#5404](https://github.com/artifact-keeper/artifact-keeper/issues/5404).
`POST /api/v1/repositories/{key}/mcp/sync` runs the sync pass inside the request, under the
global request timeout of 120 s. Against the official registry a pass of up to 200 pages often
takes longer. The debug run's seed, which still tried to sync the catalog, shows it:

```text
  sync: HTTP 503 {"entries":null,"ingested":null,"unresolved":null,"reResolved":null,"pages":null,"complete":null}
  sync: HTTP 503 {"entries":null,...}
  sync: HTTP 503 {"entries":null,...}
  sync: HTTP 200 {"entries":20000,"ingested":0,"unresolved":0,"reResolved":0,"pages":200,"complete":false}
  sync: HTTP 503 {"entries":null,...}
  ...
  catalog: {"name":null,"status":null} ({"pending":23096,"review":48})
  pin io.github.daedalus/mcp-sqlite3@0.1.3: HTTP 404 {"status":null}
```

The 503's body is `{"code":"SERVICE_UNAVAILABLE","message":"Server overloaded, please retry:
request timed out"}`, which says nothing about the sync. The handler is dropped mid-pass, so no
`MCP_MIRROR_SYNCED` summary is written. The pass that answered 200 (59 s) was one whose pages
were already in the proxy cache.

### F3. A Remote learns a name only by syncing the whole catalog

Filed as [artifact-keeper#5408](https://github.com/artifact-keeper/artifact-keeper/issues/5408);
the walkthrough uses the targeted seed it adds. `POST .../mcp/catalog/pins` answers
`404 MCP server not found in this catalog` for a name the sync has not reached, and a sync pages
the registry in name order, at most 200 pages a pass. Measured on 2026-11-05:
`https://registry.modelcontextprotocol.io/v0.1/servers?include_deleted=true&limit=100` is
2,218 pages and 221,769 entries, plain paging takes 442 s, and
`io.github.daedalus/mcp-sqlite3` first appears on page 1,093: about six passes before a pin is
possible, each running into F2. In the debug run, ten manual passes left about 23,000 names in
the catalog and the pin was still a 404 (above), so the site never had the public server: gates
G1, G4 (twice) and G7e failed on it, and the agent refused to start it.

A full sync of the official registry is not required by this walkthrough; the figures above are
the reference for anyone who wants one. The targeted seed fetches
`GET {upstream}/v0.1/servers/{name}/versions/{version}` under the same rules as a sync (egress
proxy, `UPSTREAM_FETCHED`, the catalog's checks, package pinning), records an approved pin, and
is refused with `409` while the jobs are paused or the Remote is cache-only
([Step 2](2-seed-the-stack.md#4-mcp-servers), [Step 8](8-prove-it-fails-safely.md#mcp-not-approved-not-seeded-not-synced)).

<!-- REFRESH: the final run's targeted seed output (statusUrl, item state pinned) as evidence here. -->

### F4. Config export does not carry the upstream mode

Filed as [artifact-keeper#5407](https://github.com/artifact-keeper/artifact-keeper/issues/5407).
`GET /api/v1/admin/config/export` (#5335) has no `upstream_mode` for a Remote. After the cut,
every Remote reads back `cache_only`:

```text
pypi-remote: {"repository_key":"pypi-remote","upstream_mode":"cache_only","effective_upstream_mode":"cache_only"}
```

and the export of the same instance says:

```text
{"key":"pypi-remote","upstream_mode":null,"cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
```

So the site's offline posture is not in its configuration of record, and a plan and apply of
that document on another instance would leave its Remotes online. Gate G3 reports the check
`BLOCKED(ak-gap)`; it passes once the export carries the field.

<!-- REFRESH: if the #5407 fix is in the final run, say so and move G3's check to PASS. -->

### F5. The cold-HEAD probe is not audited

Filed as [artifact-keeper#5347](https://github.com/artifact-keeper/artifact-keeper/issues/5347).
The cold-`HEAD` fix (#5331) added an upstream `HEAD` probe (`ProxyService::head_headers`,
`backend/src/services/proxy_service.rs`) that calls the plain sender instead of the audited
`UpstreamClient::send`, so a cold `HEAD` that reaches upstream is not an `UPSTREAM_FETCHED` row.
An operator auditing egress from the audit log alone would miss it. On a cache-only Remote the
probe should not run at all; gate G6 checks that three cold `HEAD`s are fast `404`s and that the
ledger does not move:

```text
cold HEAD hf-hub /huggingface/hf-hub/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/README.md: HTTP 404 in 32 ms
cold HEAD oci-ghcr /v2/oci-ghcr/ggml-org/llama.cpp/manifests/server-b5001: HTTP 404 in 334 ms
cold HEAD pypi-remote /pypi/pypi-remote/simple/rich-click/: HTTP 404 in 38 ms
PASS              G6   the cold HEADs opened no connection (the probe #5347 leaves out of the audit log never ran)
```

While seeding, with the Remotes online, a cold `HEAD` that goes upstream is not in the audit log.

## Behaviour worth knowing

- **B1. `backend` cannot be an upstream host.** The backend refuses `backend` as an upstream
  hostname (a blocklist in `backend/src/api/validation.rs`). The `plugins` Remote reaches this
  instance's own marketplace through `ak-central`, a network alias of the backend container.
- **B2. With podman, compose drops DNS aliases on a network move.** Recreating the containers on
  a new network (compose `up` with `compose.site.yml` while the stack runs) left them without
  their service-name aliases; the backend could not find `postgres` and failed with
  `Device or resource busy (os error 16)`. `flows/disconnect.sh` takes the stack down and brings
  it up again instead.
- **B3. A static address collided with dynamic allocation.** The backend first had the fixed
  address `.10`, which collided with an address podman allocates dynamically to the stack's
  other containers. It is `.250` now.
- **B4. curl takes the first `-o`.** The scripts' `call` helper writes the body to a file with
  `-o`; a caller's own `-o` came second and was ignored. `call` now drops its own `-o` when the
  caller gives one (`flows/lib.sh`).
- **B5. A deleted PyPI file name cannot be uploaded again.** After deleting the wheel from
  `pypi-local`, uploading a rebuilt file of the same name was a `409`: file names are
  immutable, as on pypi.org. A changed wheel needs a new version.
- **B6. Deflate output differs between zlib builds.** The wheel's compressed bytes, and so its
  SHA-256, differed between zlib builds. `build_wheel.py` stores the entries uncompressed, so
  the hash pinned in `agent/requirements-internal.txt` holds everywhere.
- **B7. `mcp` 2.x renamed things.** `FastMCP` is `MCPServer` (`mcp.server.mcpserver`), and a
  tool's `inputSchema` is `input_schema`. Acme's server and the agent use the 2.x names; the
  agent accepts both.
- **B8. `fastmcp` calls home.** When it prints its banner, `fastmcp` (under `mcp-sqlite3`)
  checks pypi.org for a newer release. The agent image sets `FASTMCP_CHECK_FOR_UPDATES=off` and
  `FASTMCP_SHOW_SERVER_BANNER=false`. On the site there is no route anyway (G6, G7a).
- **B9. Claude Code's harness overwhelms a small model.** With its own system prompt and tools,
  Qwen2.5-1.5B took about 300 s to read the prompt on this host and then echoed part of it back.
  With `--system-prompt` and `--tools ''` it answered in 3 s
  ([Step 6](6-claude-code-best-effort.md)).
- **B10. A small model that cannot call tools invents the answer.** SmolLM2-360M-Instruct, the
  plan's `SMALL_MODEL=1` model, made no tool call and answered "So there are 1000 units of SKU
  OG-1138 in the north warehouse", measured on `grace` with the same llama.cpp image and skill.
  Qwen2.5-0.5B-Instruct called `stock_level` correctly 3 times out of 3 and answered 42, but
  does not quote the tool's `ref` even when the skill asks; with it, G4 reports the ref in its
  log instead of gating on it.
- **B11. A cache-only miss counts twice.** In `ak_proxy_cache_lookups_total` it is a `miss` (the
  cache lookup) and a `cache_only_miss` (the gate where it stops). G7c checks
  `miss <= cache_only_miss` per Remote rather than "no misses".
- **B12. The ledger first logged tunnels only when they closed.** A long-lived tunnel was then
  not in the ledger until it ended. The ledger now writes an `open` line before it connects and
  a `close` line after. In the debug run 49 `open` lines have 45 `close` lines: four tunnels
  were still open when the stack moved.
- **B13. Connections are not requests.** One huggingface.co tunnel stayed open 180 s; the
  1.1 GB model came over one `us.aws.cdn.hf.co` tunnel; `pypi-remote`'s 218 requests used 8
  connections. The `UPSTREAM_FETCHED` rows are the per-request record.
- **B14. Pause before cache-only.** The debug run's disconnect made the Remotes cache-only first.
  An MCP sync running at that moment ended with an error on its next page and wrote its
  `MCP_MIRROR_SYNCED` row (`"errors":["GET v0.1/servers?...: upstream answered 404 Not Found"]`)
  in the second of the cut, which G7d counted. The jobs are now paused first, and the script
  waits for the running sync to finish.
- **B15. The image digest depends on how you ask.** In the debug run the inventory's `HEAD` of
  `llama.cpp:server-b12124` answered `Docker-Content-Digest: sha256:c0a11067...`, while podman's
  pull of the same tag reported `sha256:c77881bb...`. Both are consistent from seed to site; the
  gates compare like with like (podman with podman in G4, `HEAD` with `HEAD` in G7e).

## What the plan got wrong

See the table at the end of the [plan](plan.md#what-the-build-changed).

## Not machine-verified

- **Behaviour of the model and the MCP servers.** The model-file scanner reads GGUF and
  safetensors headers and pickle opcodes. It caught a truncated GGUF (`model.gguf.malformed`,
  medium) and an `os.system` pickle (`model.pickle.dangerous-global`, critical), but it does not
  judge model behaviour: poisoned weights or a backdoor trigger scan clean. MCP servers get no
  behavioural analysis at all, and a malicious server could detect probing. Approving a public
  MCP server, and the operator behind its package, means trusting it.
- **"Nothing leaves" beyond this lab.** It is proven for this lab's containers on this lab's
  podman network, between the cut and the end of G7. The host has a route out; other networks,
  hosts and your production network design are not tested.
- **Every leak path.** The ledger sees what goes through the egress proxy; the audit log sees
  what goes through the backend's audited client (not the cold-HEAD probe, F5); G7a tries TCP to
  five destinations from each running container. A process that bypassed all three on a
  network with a route would not be seen; here there is no route.
- **The ledger counts connections, not requests** (B13).
- **Two instances, the mesh push and bundles** are described on [Next steps](next-steps.md), not
  run.
- **Claude Code as an assistant.** Only the plugin install and one minimal prompt are checked.
- **Disk use and the time of a full `make all`.**
  <!-- REFRESH: measure disk (podman system df, the ak-offgrid_* volumes, out/) and make all wall time in the final run, and move this out of the list. -->
