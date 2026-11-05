# Troubleshooting

--8<-- "includes/preview-offgrid.md"

One section per error or symptom we hit while building and running this walkthrough, with the
cause, the fix and a link to the full record in the [lab notes](../findings.md).

## Setup

### up.sh: ... is not in podman's image store; build it first

```text
up.sh: localhost/ak-backend:offgrid-0bffa44c is not in podman's image store; build it first (README.md, "Images")
```

**Cause.** `registry/.env` names a local build of the backend or scanner adapter that does not
exist on this host. The defaults are local builds because the CI `:dev` images were older than
the features this walkthrough needs (the CI amd64 builds were failing).

**Fix.** Build them from an `artifact-keeper` checkout
([Step 1](../1-stand-up-the-registry.md#images)), or set `BACKEND_IMAGE` and
`SCANNER_ADAPTER_IMAGE` (or `AK_BACKEND_IMAGE`, `AK_SCANNER_ADAPTER_IMAGE` for one run) to a
`:dev` image built from `main` at or after `f0d9b638`, pinned by digest. Check its
`org.opencontainers.image.revision` label.

### Creating the plugins Remote fails on the upstream host

**Cause.** The upstream was `http://backend:8080/...`. The backend refuses `backend` as an
upstream hostname (a blocklist in `backend/src/api/validation.rs`).

**Fix.** Use another name for the same container. `compose.override.yml` gives the backend the
alias `ak-central`, and `bootstrap.sh` uses `http://ak-central:8080/agentplugins/plugins-central`.
The SSRF guard must also admit the backend's address (`AK_SSRF_ALLOW_PRIVATE_CIDRS`).
[Findings B1](../findings.md#behaviour-worth-knowing).

### The backend's fixed address is already taken

**Cause.** An early version gave the backend `.10`, which collided with the addresses podman
allocates dynamically to the stack's other containers.

**Fix.** The backend is `.250` and the ledger `.200` on either network (`registry/lib.sh`). If
you change the subnets in `registry/.env`, keep those two addresses free.
[Findings B3](../findings.md#behaviour-worth-knowing).

### The ledger saw none of an MCP Remote's first sync

**Cause.** An MCP Remote starts syncing as soon as it is created, before `PUT .../egress-proxy`
applies ([artifact-keeper#5402](https://github.com/artifact-keeper/artifact-keeper/issues/5402)).

**Fix.** Pause the scheduled upstream jobs while creating Remotes, as `bootstrap.sh` does
(`PATCH /api/v1/admin/settings/system {"upstream_jobs_paused": true}`, then `false` at the end).
Once [#5406](https://github.com/artifact-keeper/artifact-keeper/pull/5406) is in your backend, the
Remote can be created with its settings. [Findings F1](../findings.md#f1-an-mcp-remote-syncs-before-its-settings-apply).

## Seeding

### seed.sh: the wheel's hash is not the one agent/requirements-internal.txt pins

```text
seed.sh: the wheel's hash is not the one agent/requirements-internal.txt pins
```

**Cause.** `build_wheel.py` produced different bytes. The first version compressed the entries,
and deflate output differs between zlib builds; it now stores them uncompressed. A change to
`tools/acme-inventory/acme_inventory_mcp/*.py` also changes the hash, on purpose.

**Fix.** If you changed the server, bump its version and pin the new hash in
`agent/requirements-internal.txt` and in the `--hash` there. [Findings B6](../findings.md#behaviour-worth-knowing).

### POST /pypi/pypi-local/: HTTP 409 after deleting the wheel

**Cause.** A PyPI file name, once used, cannot be uploaded again, even after the file is deleted:
file names are immutable, as on pypi.org.

**Fix.** Publish the changed package under a new version. [Findings B5](../findings.md#behaviour-worth-knowing).

### POST .../mcp/sync: HTTP 503 Server overloaded, please retry: request timed out

```text
  sync: HTTP 503 {"entries":null,"ingested":null,"unresolved":null,"reResolved":null,"pages":null,"complete":null}
```

**Cause.** A manual MCP sync runs inside the request and is cut off by the 120 s request timeout
([artifact-keeper#5404](https://github.com/artifact-keeper/artifact-keeper/issues/5404)). The
instance is not overloaded.

**Fix.** Do not seed the public MCP server by syncing; use the targeted seed
(`POST .../mcp/seed`, [Step 2](../2-seed-the-stack.md#4-mcp-servers)).
[Findings F2](../findings.md#f2-a-manual-mcp-sync-is-cut-off-by-the-request-timeout).

### Pinning a public MCP server: 404 MCP server not found in this catalog

**Cause.** A pin needs the name in the Remote's catalog, which only a sync fills, in name order,
200 pages a pass. `io.github.daedalus/mcp-sqlite3` is on page 1,093 of 2,218.

**Fix.** The targeted seed fetches one name and version without a catalog sync
([#5408](https://github.com/artifact-keeper/artifact-keeper/issues/5408)).
[Findings F3](../findings.md#f3-a-remote-learns-a-name-only-by-syncing-the-whole-catalog).

### POST .../mcp/seed: HTTP 404 Repository not found

```text
HTTP 404
Repository not found
```

**Cause.** The backend predates [#5408](https://github.com/artifact-keeper/artifact-keeper/issues/5408):
the route does not exist (the debug run on `main` at `0bffa44c`). Then `mcp-sqlite3` is not
served, the inventory has it as missing, and the agent refuses to start it: G1, G4 and G7e fail
on it, and G6's 409 check fails.

`make seed` says so:

```text
  no seed job: this backend has no POST .../mcp/seed (artifact-keeper#5408, main at <SHA> or later); gates G1 and G4 will report io.github.daedalus/mcp-sqlite3 missing
```

**Fix.** Use a backend with #5408. <!-- REFRESH: name the main commit or release that includes #5408 once merged. -->

### The adapter is not ready (HTTP 503) before the import

```text
  ready before the import: HTTP 503
  GET /api/v1/vulndb before: HTTP 404
```

**Cause.** Expected: in offline mode the scanner adapter has no database until one is imported.

**Fix.** None needed; `make vet` imports it ([Step 3](../3-vet-what-you-seeded.md#the-scanner-adapter-offline)).

### G2: the adapter's scan fails with jq: parse error: Unfinished JSON term

```text
jq: parse error: Unfinished JSON term at EOF at line 2, column 0
FAIL              G2   scanner adapter: a scan of the llama.cpp image from the registry completes offline: rameter of negative size ...
```

**Cause.** In the debug run the saved report `out/flows/adapter-report.txt` was not complete
JSON, although the adapter answered 200 with a Trivy report. The scan itself completed.

**Fix.** Run `make vet` with the current `flows/vet.sh`, which saves the whole response.
<!-- REFRESH: confirm in the final run that G2's adapter check passes; if not, record the cause here. -->

## Disconnecting

### After the move, the backend cannot reach postgres: Device or resource busy (os error 16)

**Cause.** With podman, containers that compose recreates on a new network lose their
service-name DNS aliases (`postgres`, `opensearch`, ...).

**Fix.** Take the stack down (volumes kept) and bring it up on the other network, as
`flows/disconnect.sh` and `flows/reconnect.sh` do. If you got here by hand:
`registry/down.sh`, set `registry/out/phase`, `registry/up.sh`, `ledger/up.sh`.
[Findings B2](../findings.md#behaviour-worth-knowing).

### G3: BLOCKED(ak-gap) the exported configuration records every Remote as cache-only

**Cause.** Config export does not carry `upstream_mode`
([artifact-keeper#5407](https://github.com/artifact-keeper/artifact-keeper/issues/5407)).

**Fix.** None on the site; it is a gap, not a fault. On a second instance built from the export,
set each Remote's upstream mode with `PUT .../upstream-mode`.
[Findings F4](../findings.md#f4-config-export-does-not-carry-the-upstream-mode).

### G7d: an MCP_MIRROR_SYNCED row in the second of the cut

**Cause.** A sync was running when the Remotes went cache-only; it ended with an error after the
marks were written. The debug run's disconnect went cache-only before pausing the jobs.

**Fix.** The current `flows/disconnect.sh` pauses first and waits for the sync to finish. If it
happened anyway, `make reconnect`, then `make disconnect` again: the marks are new.
[Findings B14](../findings.md#behaviour-worth-knowing).

### clean: rootless netns: kill network process: permission denied

**Cause.** Where the pasta AppArmor profile refuses podman's signal (seen on Ubuntu 26.04), the
last container cannot tear down podman's rootless network namespace.

**Fix.** `registry/clean.sh` handles exactly that error: it stops pasta itself and retries once.

## The agent and the model

### G4: the llama.cpp image is not at the seed's digest

```text
FAIL              G4   the llama.cpp image was pulled again on the site, through oci-ghcr, at the seed's digest: seed c0a11067... site c77881bb...
```

**Cause.** The debug run's seed took the digest from a `HEAD` of the tag; podman reports a
different one for the same tag. The two were never comparable.

**Fix.** The current `seed/seed.sh` writes podman's digest to `out/seed-images.tsv`, and G4
compares it with podman's digest on the site. Re-run `make seed` (it is idempotent).
[Findings B15](../findings.md#behaviour-worth-knowing).

### G7c: no hits on oci-dockerhub

**Cause.** Nothing on the site was pulled through `oci-dockerhub` (the debug run's
`flows/agent.sh` pulled only the llama.cpp image).

**Fix.** The current `flows/agent.sh` also pulls the python base image again. Re-run
`make agent`.

### ImportError for FastMCP, or AttributeError: inputSchema

**Cause.** `mcp` 2.x renamed `FastMCP` to `MCPServer` (`mcp.server.mcpserver`) and `Tool.inputSchema`
to `input_schema`.

**Fix.** Use the 2.x names, as `acme_inventory_mcp/server.py` and `agent.py` do.
[Findings B7](../findings.md#behaviour-worth-knowing).

### mcp-sqlite3 tries to reach pypi.org

**Cause.** `fastmcp`, under `mcp-sqlite3`, checks pypi.org for a newer release when it shows its
banner.

**Fix.** `FASTMCP_CHECK_FOR_UPDATES=off` and `FASTMCP_SHOW_SERVER_BANNER=false` (set in the agent
image). On the site the attempt fails anyway. [Findings B8](../findings.md#behaviour-worth-knowing).

### The model answers with a number, but made no tool call

```text
So there are 1000 units of SKU OG-1138 in the north warehouse
```

**Cause.** The model cannot call tools with this chat template. SmolLM2-360M-Instruct did this.

**Fix.** Use a model that calls tools: Qwen2.5-1.5B (default) or Qwen2.5-0.5B (`SMALL_MODEL=1`),
and keep `--jinja` on llama-server. G4 fails when there is no `stock_level` call.
[Findings B10](../findings.md#behaviour-worth-knowing).

### G4 with SMALL_MODEL=1: the answer has no ref

**Cause.** Qwen2.5-0.5B does not quote the tool's `ref` (`inv-7f3a9c`), even when the skill
asks.

**Fix.** None needed: with `SMALL_MODEL=1`, G4 reports `answer quotes the tool's ref:
true/false` in its log and does not gate on it; the tool call and the number are the evidence.

## Claude Code

### The session takes about 300 s and echoes the prompt

**Cause.** Claude Code's own system prompt and tool definitions are tens of thousands of tokens;
a 1.5B model on a CPU takes minutes to read them and then does not follow them.

**Fix.** `make claude` uses `--system-prompt` and `--tools ''`, which answers in seconds.
`CLAUDE_FULL=1 make claude` runs the full session too, for comparison.
[Findings B9](../findings.md#behaviour-worth-knowing).

### [claude-code:unrecognized_model] {"model":"local",...}

**Cause.** Claude Code does not know the model alias `local` that llama-server serves.

**Fix.** None needed; it is a warning on stderr and the session works.

## Reading the gates

### The ledger has fewer close lines than open lines

**Cause.** Tunnels still open when the stack moved, or still open now: connections are kept
alive and carry many requests. The ledger counts connections, not requests.

**Fix.** None. Count `open` lines, as the gates do; use the `UPSTREAM_FETCHED` rows for
requests. [Findings B12, B13](../findings.md#behaviour-worth-knowing).

### miss and cache_only_miss both rise for one request

**Cause.** A cache-only miss is counted twice: as a lookup `miss`, then as `cache_only_miss` where
it stops.

**Fix.** None. G7c checks `miss <= cache_only_miss` per Remote.
[Findings B11](../findings.md#behaviour-worth-knowing).
