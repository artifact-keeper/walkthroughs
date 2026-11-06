# Lab notes: the off-grid AI stack

--8<-- "includes/preview-offgrid.md"

The record of building and running this walkthrough on 2026-11-05 and 06 (UTC): what we ran it
on, the Artifact Keeper bugs and gaps we hit, the behaviour worth knowing, what the
[plan](plan.md) got wrong, and what is not machine-verified. The step pages are written from
these notes and from the reference run in [Results](results.md). The bugs were found in debug
runs on `main` at `0bffa44c` (a local build, because the CI `:dev` image was stale at the time);
all five are fixed on `main`, and the reference run, on the CI images of `main` at `88f23c51`,
verifies each fix.

## Environment

| | |
|---|---|
| Host | `grace`: Ubuntu 26.04 LTS, kernel 7.0.0-34-generic, x86_64, 40 cores, 108 GB RAM, rootless podman 5.7.0 with docker-compose v5.5.0 as the compose provider, no sudo |
| Backend | `ghcr.io/artifact-keeper/artifact-keeper-backend:dev@sha256:1314a083...`, `main` at `88f23c51` (reports 1.11.3), image ID `c3c71ef94e71...`. It includes the fixes below and the tree and access fixes [#5412](https://github.com/artifact-keeper/artifact-keeper/pull/5412) (`6a6064f5`) and [#5427](https://github.com/artifact-keeper/artifact-keeper/pull/5427) (`7a5914a2`) |
| Scanner adapter | `ghcr.io/artifact-keeper/artifact-keeper-scanner-adapter:dev@sha256:d44dacfa...`, same commit; Trivy 0.76.0 inside |
| Web | `ghcr.io/artifact-keeper/artifact-keeper-web:dev@sha256:e05124d4...`, `artifact-keeper-web` at `b65f9614` |
| Debug runs | `localhost/ak-backend:offgrid-0bffa44c`, built locally from `main` at `0bffa44c`: the CI amd64 builds were failing and `:dev` was older than the features this walkthrough needs |
| Model | `Qwen/Qwen2.5-1.5B-Instruct-GGUF` at `91cad51170dc346986eccefdc2dd33a9da36ead9`, `qwen2.5-1.5b-instruct-q4_k_m.gguf` (1,117,320,736 bytes); `SMALL_MODEL=1`: `Qwen/Qwen2.5-0.5B-Instruct-GGUF` at `9217f5db79a2`, 491,400,032 bytes |
| Model server | `ghcr.io/ggml-org/llama.cpp:server-b12124@sha256:c0a11067...`, CPU, 16 threads, context 32768 |
| Agent | Python 3.12 (`python:3.12-slim-trixie`), `openai` 3.46.0, `mcp` 2.3.0, `huggingface_hub` 2.4.0, `mcp-sqlite3` 0.1.3, `fastmcp` 4.1.6; 71 packages in the lock |
| Claude Code | 2.1.318 on `node:22-bookworm-slim` |

## Artifact Keeper bugs and gaps

### F1. An MCP Remote synced before its settings applied

Filed as [artifact-keeper#5402](https://github.com/artifact-keeper/artifact-keeper/issues/5402);
fixed by [#5406](https://github.com/artifact-keeper/artifact-keeper/pull/5406) (`main` at `c2816e4c`). On `main` at `0bffa44c`, the settings
that make a Remote safe to run offline or under an egress audit (`PUT .../egress-proxy`,
`.../upstream-mode`, `.../cache-ttl`) were separate routes that could be called only once the
repository existed. A new MCP Remote was due for a sync at once, so the scheduler's next tick
synced it: in the lab the backend log showed `Fetching artifact from upstream:
https://registry.modelcontextprotocol.io/v0.1/servers` within the same second as the create,
and the ledger saw none of those first pages. The per-repository egress client was also cached
for 60 s, and a sync already in flight kept the client it started with.

The debug runs worked around it by pausing every scheduled upstream job (`upstream_jobs_paused`,
#5317) for the whole instance while the repositories were created. Since #5406 the create body
accepts the Remote's settings, so it is born configured. **Verified in the reference run:**
`bootstrap.sh` creates every Remote with `egress_proxy` in the create body and `mcp-official`
with `"mcp_remote_sync_paused": true`, with no pause around it; the egress proxy reads back as
`{"mode":"explicit","proxy_url":"http://egress-ledger:3128/"}` on every Remote, the seed's single
connection to `registry.modelcontextprotocol.io` is in the ledger, and the marks at the cut
count `"mcp_mirror_synced": 0`: no sync ever ran.

### F2. A manual MCP sync was cut off by the request timeout

Filed as [artifact-keeper#5404](https://github.com/artifact-keeper/artifact-keeper/issues/5404);
fixed by [#5405](https://github.com/artifact-keeper/artifact-keeper/pull/5405) (`main` at `c09e5d7e`).
On `main` at `0bffa44c`, `POST /api/v1/repositories/{key}/mcp/sync` ran the sync pass inside the
request, under the global request timeout of 120 s. Against the official registry a pass of up
to 200 pages often took longer. The debug run's seed, which still tried to sync the catalog, shows it:

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
request timed out"}`, which says nothing about the sync. The handler was dropped mid-pass, so
no `MCP_MIRROR_SYNCED` summary was written. The pass that answered 200 (59 s) was one whose
pages were already in the proxy cache.

Since #5405 a manual sync runs in the background and the route answers `202`. The reference run
no longer syncs at all (F3), so the `202` itself is not in its logs. **What it does show:** on
the site, a manual sync is refused at once with a status and a message that say why:

```text
POST .../mcp/sync (on the site): HTTP 409 {"code":"CONFLICT","message":"scheduled upstream jobs are paused on this instance (upstream_jobs_paused); no sync starts until the switch is off"}
  sync state: {"running":false,"lastStartedAt":null,"lastFinishedAt":null}
```

### F3. A Remote learned a name only by syncing the whole catalog

Filed as [artifact-keeper#5408](https://github.com/artifact-keeper/artifact-keeper/issues/5408);
fixed by [#5409](https://github.com/artifact-keeper/artifact-keeper/pull/5409) (`main` at `88f23c51`), a targeted seed. `POST .../mcp/catalog/pins` answers
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
is refused with `409` while the jobs are paused or the Remote is cache-only. **Verified in the
reference run** ([Step 2](2-seed-the-stack.md#4-mcp-servers),
[Step 8](8-prove-it-fails-safely.md#mcp-not-approved-not-seeded-not-synced)):

```text
  POST /api/v1/repositories/mcp-official/mcp/seed io.github.daedalus/mcp-sqlite3@0.1.3: HTTP 202 {"jobId":"70d9dc70-3b56-48b7-a9c0-306a65013bb1","status":"pending","total":1}
{"status":"completed","items":[{"name":"io.github.daedalus/mcp-sqlite3","version":"0.1.3","state":"pinned","reason":null}]}
POST .../mcp/seed (on the site): HTTP 409 {"code":"CONFLICT","message":"scheduled upstream jobs are paused on this instance (upstream_jobs_paused); a seed contacts the upstream and waits for the switch too"}
```

Two requests to the official registry over one connection, instead of ten 200-page passes. The
agent starts the public server, and G1, G4 and G7e pass on it.

### F4. Config export did not carry the upstream mode

Filed as [artifact-keeper#5407](https://github.com/artifact-keeper/artifact-keeper/issues/5407);
fixed by [#5415](https://github.com/artifact-keeper/artifact-keeper/pull/5415) (`main` at `d9a417c8`).
In the debug run, `GET /api/v1/admin/config/export` (#5335) had no `upstream_mode` for a Remote.
After the cut, every Remote read back `cache_only`:

```text
pypi-remote: {"repository_key":"pypi-remote","upstream_mode":"cache_only","effective_upstream_mode":"cache_only"}
```

and the export of the same instance says:

```text
{"key":"pypi-remote","upstream_mode":null,"cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
```

So the site's offline posture was not in its configuration of record, and a plan and apply of
that document on another instance would have left its Remotes online; gate G3 reported the check
`BLOCKED(ak-gap)`. **Verified in the reference run:** the export says
`{"key":"pypi-remote","upstream_mode":"cache_only",...}` for every Remote
([Step 4](4-disconnect.md#3-the-export-with-the-offline-posture)), and G3's check passes.

### F5. The cold-HEAD probe was not audited

Filed as [artifact-keeper#5347](https://github.com/artifact-keeper/artifact-keeper/issues/5347);
fixed by [#5414](https://github.com/artifact-keeper/artifact-keeper/pull/5414) (`main` at
`a2f53502`). The cold-`HEAD` fix (#5331) had added an upstream `HEAD` probe
(`ProxyService::head_headers`, `backend/src/services/proxy_service.rs`) that called the plain
sender instead of the audited `UpstreamClient::send`, so a cold `HEAD` that reached upstream was
not an `UPSTREAM_FETCHED` row, and an operator auditing egress from the audit log alone would
have missed it. The debug run's G6 could only check the ledger:

```text
cold HEAD hf-hub /huggingface/hf-hub/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/README.md: HTTP 404 in 32 ms
PASS              G6   the cold HEADs opened no connection (the probe #5347 leaves out of the audit log never ran)
```

**Verified in the reference run:** the probe now goes through the audited path, and on a
cache-only Remote it does not run at all. G6 checks both records:

```text
cold HEAD hf-hub /huggingface/hf-hub/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/README.md: HTTP 404 in 37 ms
cold HEAD oci-ghcr /v2/oci-ghcr/ggml-org/llama.cpp/manifests/server-b5001: HTTP 404 in 344 ms
cold HEAD pypi-remote /pypi/pypi-remote/simple/rich-click/: HTTP 404 in 40 ms
PASS              G6   the cold HEADs opened no connection and wrote no UPSTREAM_FETCHED row
```

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
  a `close` line after. In the reference run 25 `open` lines have 22 `close` lines: tunnels
  still open when the stack moved have no `close` line.
- **B13. Connections are not requests.** In the reference run, 283 upstream requests went over
  24 connections up to the cut; `pypi-remote`'s 215 requests used 5, and the 1.1 GB model came
  over one `us.aws.cdn.hf.co` tunnel that stayed open 121 s (`"ms": 121240` on its `close` line). The `UPSTREAM_FETCHED` rows are the
  per-request record.
- **B14. Pause before cache-only.** The debug run's disconnect made the Remotes cache-only first.
  An MCP sync running at that moment ended with an error on its next page and wrote its
  `MCP_MIRROR_SYNCED` row (`"errors":["GET v0.1/servers?...: upstream answered 404 Not Found"]`)
  in the second of the cut, which G7d counted. The jobs are now paused first, and the script
  waits for the running sync to finish.
- **B15. The image digest depends on how you ask.** In a debug run the llama.cpp image was
  pulled by tag; podman reported `sha256:c77881bb...` while a `HEAD` of the tag answered
  `Docker-Content-Digest: sha256:c0a11067...`, the multi-arch index. The manifest now pins the
  index digest (`server-b12124@sha256:c0a11067...`), and podman, the inventory and gate G4 all
  see `c0a11067...`.
- **B16. G7's window filter passed on an empty result.** The first version of G7 read the
  control windows of earlier runs with `jq -Rsc ... file 2>/dev/null || echo '[]'`. With no
  `out/gates/control-windows.tsv` yet (a first gate run), jq printed `[]` and then failed
  (reproduced with jq 1.8.2), so `|| echo '[]'` added a second `[]`. The result was not valid
  JSON, the G7b and G7d filters stopped with `jq: invalid JSON text passed to --argjson`, and
  their counts came out empty, so both checks passed without counting. The counts that did not
  go through the filter showed the same zero in those runs ("22 connections at the disconnect,
  22 now"; G6's `UPSTREAM_FETCHED since the disconnect 0 -> 0`), but the checks themselves had
  not measured anything. G7 now reads the windows only if the file has content, checks that
  they parse, prints the raw count next to the filtered one, and fails closed: a window list or
  filter it cannot read makes the check fail (`ERR`), not pass. In the reference run:
  `opened since then: 0, of them outside control windows: 0` and
  `UPSTREAM_FETCHED since 2026-11-06T05:13:07Z: 0 rows, 0 outside the control windows`
  ([Step 7](7-prove-nothing-leaves.md#g7b-the-egress-ledger-gained-no-connection)).
- **B17. The web UI does not show cache-only mode.** The repository list and page show a Remote
  as `remote`, with no sign that it is `cache_only`; the API and the export do. Filed as
  [artifact-keeper-web#1094](https://github.com/artifact-keeper/artifact-keeper-web/issues/1094)
  ([Results](results.md#the-web-ui)).
- **B18. The storage panel reads 0 B for repositories that hold data.** `hf-models` shows
  "1.04 GB used" in its header next to "Logical size 0 B", "Physical (stored) 0 B" and
  "Blobs 0" in its storage panel; `mcp-internal` and `plugins-central` show the same zeros. We
  did not investigate it.

## What the plan got wrong

See the table at the end of the [plan](plan.md#what-the-build-changed). One change came from the
last full run before the reference run (72 PASS, 1 FAIL): G6 expected a manual MCP sync on the
site to be accepted (`202`) and to send nothing. Artifact Keeper refused it instead, with `409`,
because the upstream jobs are paused:

```text
FAIL              G6   a manual MCP sync on the site is accepted (202) and runs: HTTP 409
```

That is the safer answer, and the expectation was wrong, not Artifact Keeper: G6 now asserts the
`409`. A second change came from the same runs: G7's window filter passed on an empty result on
a first gate run ([B16](#behaviour-worth-knowing)); G7 now prints raw and filtered counts and
fails closed.

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
  what goes through the backend's audited client (since #5414, the cold-HEAD probe too); G7a tries TCP to
  five destinations from each running container. A process that bypassed all three on a
  network with a route would not be seen; here there is no route.
- **The ledger counts connections, not requests** (B13).
- **Two instances, the mesh push and bundles** are described on [Next steps](next-steps.md), not
  run.
- **Claude Code as an assistant.** Only the npm install, the plugin install and one minimal
  prompt are checked. The 300 s full-harness session (B9) is from a debug session, not the
  reference run.
