# Troubleshooting

--8<-- "includes/preview-offgrid.md"

One section per error or symptom we hit while building and running this walkthrough, with the
cause, the fix and a link to the full record in the [lab notes](../findings.md).

## Setup

### The :dev image is too old

**Cause.** While this walkthrough was built, the CI amd64 builds of Artifact Keeper were failing,
so `:dev` was older than the features it needs (cache-only Remotes, `UPSTREAM_FETCHED`, the
targeted MCP seed, ...). Symptoms are the ones further down: `POST .../mcp/seed` is a `404`, the
export has no `upstream_mode`, G3, G4 or G6 fail. The debug runs used local builds instead.

**Fix.** Use the images `registry/.env.example` pins (the CI images of `main` at `88f23c51`, by
digest), or a later build: check the image's `org.opencontainers.image.revision` label, pin its
digest in `registry/.env`, or pass `AK_BACKEND_IMAGE` and `AK_SCANNER_ADAPTER_IMAGE` for one run
([Step 1](../1-stand-up-the-registry.md#images)).

### up.sh: ... is not in podman's image store; build it first

**Cause.** `registry/.env` names a local image (`localhost/...`) that does not exist on this
host; `registry/up.sh` refuses to start rather than try to pull it.

**Fix.** Build it, or point `registry/.env` back at the pinned CI images.

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

**Cause.** On `main` before [#5406](https://github.com/artifact-keeper/artifact-keeper/pull/5406)
(`c2816e4c`), an MCP Remote started syncing as soon as it was created, before `PUT .../egress-proxy`
could apply ([artifact-keeper#5402](https://github.com/artifact-keeper/artifact-keeper/issues/5402)).

**Fix.** Use a backend with #5406 and create the Remote with `egress_proxy` (and, for an MCP
Remote, `mcp_remote_sync_paused`) in the create body, as `bootstrap.sh` does. On an older
backend, pause the scheduled upstream jobs while creating Remotes
(`PATCH /api/v1/admin/settings/system {"upstream_jobs_paused": true}`, then `false`).
[Findings F1](../findings.md#f1-an-mcp-remote-synced-before-its-settings-applied).

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

**Cause.** On `main` before [#5405](https://github.com/artifact-keeper/artifact-keeper/pull/5405)
(`c09e5d7e`), a manual MCP sync ran inside the request and was cut off by the 120 s request
timeout ([artifact-keeper#5404](https://github.com/artifact-keeper/artifact-keeper/issues/5404)).
The message is misleading: the instance was not overloaded, and the sync was stopped mid-pass.

**Fix.** Use a backend with #5405, where the sync runs in the background and the route answers
`202`. To seed one public MCP server, do not sync at all; use the targeted seed
(`POST .../mcp/seed`, [Step 2](../2-seed-the-stack.md#4-mcp-servers)).
[Findings F2](../findings.md#f2-a-manual-mcp-sync-was-cut-off-by-the-request-timeout).

### POST .../mcp/seed or .../mcp/sync: HTTP 409 CONFLICT

```text
POST .../mcp/seed (on the site): HTTP 409 {"code":"CONFLICT","message":"scheduled upstream jobs are paused on this instance (upstream_jobs_paused); a seed contacts the upstream and waits for the switch too"}
POST .../mcp/sync (on the site): HTTP 409 {"code":"CONFLICT","message":"scheduled upstream jobs are paused on this instance (upstream_jobs_paused); no sync starts until the switch is off"}
```

**Cause.** The scheduled upstream jobs are paused (`upstream_jobs_paused`), or the Remote is
cache-only. On the site that is the point: G6 asserts both `409`s. While seeding it means the
switch was left on, for example after `make disconnect` without `make reconnect`.

**Fix.** On the seed network, `make reconnect` (it resumes the jobs and puts every Remote back
online), then seed again. Check with `GET /api/v1/admin/settings/system`.

### Pinning a public MCP server: 404 MCP server not found in this catalog

**Cause.** A pin needs the name in the Remote's catalog, which only a sync fills, in name order,
200 pages a pass. `io.github.daedalus/mcp-sqlite3` is on page 1,093 of 2,218.

**Fix.** The targeted seed fetches one name and version without a catalog sync
([#5408](https://github.com/artifact-keeper/artifact-keeper/issues/5408), fixed by
[#5409](https://github.com/artifact-keeper/artifact-keeper/pull/5409), `main` at `88f23c51`).
[Findings F3](../findings.md#f3-a-remote-learned-a-name-only-by-syncing-the-whole-catalog).

### POST .../mcp/seed: HTTP 404 Repository not found

```text
HTTP 404
Repository not found
```

**Cause.** The backend predates [#5409](https://github.com/artifact-keeper/artifact-keeper/pull/5409):
the route does not exist (seen on `main` at `0bffa44c`). Then `mcp-sqlite3` is not served, the
inventory has it as missing, and the agent refuses to start it: G1, G4 and G7e fail on it.
`make seed` says so:

```text
  no seed job: this backend has no POST .../mcp/seed (artifact-keeper#5408, main at 88f23c51 or later); gates G1 and G4 will report io.github.daedalus/mcp-sqlite3 missing
```

**Fix.** Use a backend from `main` at `88f23c51` or later.

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
```

**Cause.** In a debug run the saved report `out/flows/adapter-report.txt` was not complete
JSON, although the adapter answered 200 with a Trivy report. The scan itself completed.

**Fix.** Run `make vet` again. In the reference run the report parsed:
`report: HTTP 200, {"scanner":{"name":"Trivy","version":"0.76.0"},"vulnerabilities":689}`.

## Disconnecting

### After the move, the backend cannot reach postgres: Device or resource busy (os error 16)

**Cause.** With podman, containers that compose recreates on a new network lose their
service-name DNS aliases (`postgres`, `opensearch`, ...).

**Fix.** Take the stack down (volumes kept) and bring it up on the other network, as
`flows/disconnect.sh` and `flows/reconnect.sh` do. If you got here by hand:
`registry/down.sh`, set `registry/out/phase`, `registry/up.sh`, `ledger/up.sh`.
[Findings B2](../findings.md#behaviour-worth-knowing).

### G3: BLOCKED(ak-gap) the exported configuration records every Remote as cache-only

**Cause.** On `main` before [#5415](https://github.com/artifact-keeper/artifact-keeper/pull/5415)
(`d9a417c8`), config export did not carry `upstream_mode`
([artifact-keeper#5407](https://github.com/artifact-keeper/artifact-keeper/issues/5407)).

**Fix.** Use a backend with #5415. On an older one, set each Remote's upstream mode on a cloned
instance with `PUT .../upstream-mode`.
[Findings F4](../findings.md#f4-config-export-did-not-carry-the-upstream-mode).

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

**Cause.** In a debug run the image was pulled by tag, and the seed took the digest from a `HEAD`
of the tag (the multi-arch index) while podman reported another one for the same tag.

**Fix.** The manifest pins the index digest (`server-b12124@sha256:c0a11067...`), and
`seed/seed.sh` writes podman's digest to `out/seed-images.tsv` for G4 to compare with podman's
on the site. Re-run `make seed` (it is idempotent).
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

**Cause.** Claude Code's full harness, its own system prompt and tool definitions, is tens of
thousands of tokens; a 1.5B model on a CPU took about 300 s to read them in a debug session and
then echoed part of the prompt instead of answering.

**Fix.** `make claude` uses `--system-prompt` and `--tools ''`, which answered in 3 s in the
reference run. `CLAUDE_FULL=1 make claude` runs the full session too, for comparison.
[Findings B9](../findings.md#behaviour-worth-knowing).

### With SMALL_MODEL=1, G5's session is BLOCKED(best-effort): the answer is "# Environment ..."

```text
BLOCKED(best-effort) G5   best-effort: Claude Code gets the asked-for answer from the local model (...): {"is_error":false,"result":"# Environment\nYou have been invoked in the following environment: \n - Primary working directory: /\n "}
```

**Cause.** Even with the minimal system prompt, Claude Code adds an environment section, and
Qwen2.5-0.5B echoes it instead of answering.

**Fix.** None in the registry: it is the model. Use the default model for this step.

### [claude-code:unrecognized_model] {"model":"local",...}

**Cause.** Claude Code does not know the model alias `local` that llama-server serves.

**Fix.** None needed; it is a warning on stderr and the session works.

## Reading the gates

### G7: jq: invalid JSON text passed to --argjson, and G7b or G7d still pass

```text
jq: invalid JSON text passed to --argjson
ledger: 22 connections at the disconnect, 22 now; opened since then, outside control windows: 0
```

**Cause.** A first version of `gates/g07-zero-egress.sh`. On the first gate run there was no
`out/gates/control-windows.tsv`; the command that read it printed `[]` and failed, so
`|| echo '[]'` appended a second `[]`, the result was not valid JSON, and the G7b and G7d
filters produced nothing, so those checks passed without counting.

**Fix.** Use the current gate (`de0597c` or later). It prints `control windows of earlier runs:
N`, the raw and the filtered counts (`opened since then: 0, of them outside control windows: 0`),
and fails closed with `ERR` when it cannot read them.
[Findings B16](../findings.md#behaviour-worth-knowing).

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

## The web UI

### A Remote does not look cache-only in the UI

**Cause.** The web UI does not show a Remote's upstream mode yet
([artifact-keeper-web#1094](https://github.com/artifact-keeper/artifact-keeper-web/issues/1094)).

**Fix.** Read it from the API: `GET /api/v1/repositories/<key>/upstream-mode`, or the export.
[Findings B17](../findings.md#behaviour-worth-knowing).

### The storage panel says Logical size 0 B for a repository with data

**Cause.** Unknown; we did not investigate it. `hf-models` shows "1.04 GB used" in its header and
0 B in the storage panel.

**Fix.** None known. Use the size in the header and the artifact list.
[Findings B18](../findings.md#behaviour-worth-knowing).
