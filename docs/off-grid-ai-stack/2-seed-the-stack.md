# Step 2: Seed the stack

--8<-- "includes/preview-offgrid.md"

Everything the site will need is listed in one file,
[`seed/manifest.toml`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/seed/manifest.toml).
This step pulls all of it through Artifact Keeper while the seed network still has a route
out, publishes what Acme makes itself, and lists what went out. Anything not in the manifest is
not on the site afterwards.

```bash
make seed    # seed/seed.sh
```

[`seed/seed.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/seed/seed.sh)
runs six parts in order. Each one is idempotent: what is already published or cached is skipped
or served from the cache. The format of the manifest is on
[Seed manifest and inventory](reference/seed-manifest.md).

## 1. Images

Images are pulled with podman from the host, through `localhost:30450/<repo>/<ref>`, with the
developer's auth file. The trivy database is an OCI artifact, not an image (podman does not
pull it), so the script fetches its manifest and layers with `GET`:

```console
== 1. images (podman pull through the registry, from the host)
  oci-ghcr       ggml-org/llama.cpp:server-b12124                             sha256:c77881bba21e863bc56391995511f361040952f7ed6033cf1589da7f77a04eff
  oci-dockerhub  library/python:3.12-slim-trixie@sha256:b18b261e1b4974b4f3214 sha256:b18b261e1b4974b4f321451ad5251ded85abb22c2b8b262da527dda1d031ab30
  oci-dockerhub  library/node:22-bookworm-slim@sha256:5ec23b7c622b00547753bc6 sha256:5ec23b7c622b00547753bc6ffd78085dd868a68aeb41c8e0a1418f033e13d96d
  oci-ghcr       aquasecurity/trivy-db:2                                      sha256:681e7ce3da1709dc4e0a57f22879b996a7681305ac00db4d0cb3a4835bb6dcaa (artifact, layers HTTP 200)
```

The digests podman reports go to `out/seed-images.tsv`; [Step 5](5-run-the-agent-offline.md)
pulls the same references again on the site and gate G4 compares the two. The base images are
pinned by digest. The llama.cpp image is a tag (`server-b12124`), and the trivy database is
`:2`, which upstream moves daily: the site gets the one seeded today.

## 2. The model, with the cache-seed API

The model is Qwen2.5-1.5B-Instruct as a Q4_K_M GGUF, pinned to a commit. Instead of a client
download, the script asks `hf-hub` to fill its own cache from a path list
([#5333](https://github.com/artifact-keeper/artifact-keeper/pull/5333)): the commit-pinned
`resolve` paths of the files, and the model's revision document. Commit-pinned Hugging Face
paths never revalidate ([#5313](https://github.com/artifact-keeper/artifact-keeper/pull/5313)):

```bash
POST /api/v1/repositories/hf-hub/cache/seed
{"kind": "paths", "options": {"concurrency": 2}, "content": [
  "Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad511.../qwen2.5-1.5b-instruct-q4_k_m.gguf",
  "Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad511.../README.md",
  "api/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/revision/91cad511..."]}
GET  /api/v1/repositories/hf-hub/cache/seed/<job_id>     (until completed or failed)
```

```console
== 2. the model: a cache-seed job on hf-hub, commit-pinned paths (Qwen/Qwen2.5-1.5B-Instruct-GGUF@91cad51170dc)
  Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf
  Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/README.md
  api/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/revision/91cad51170dc346986eccefdc2dd33a9da36ead9
  POST /api/v1/repositories/hf-hub/cache/seed: HTTP 202 {"job_id":"b60f3bfe-739a-4254-bc50-304708c463bc","status":"pending","total_items":3}
{"status":"completed","summary":{"pending":0,"cached":3,"already_cached":0,"refused":0,"failed":0,"cached_bytes":1117332630}}
  cached	1117320736	6a1a2eb6d15622bf	Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf
  cached	4856	57c72d4010fb11a9	Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/README.md
  cached	7038	7f41c58b8aea1525	api/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/revision/91cad51170dc346986eccefdc2dd33a9da36ead9
```

The job ran 65 s (`started_at` 17:12:12, `finished_at` 17:13:17) for 1.1 GB. The SHA-256 the
job records for each file is what gate G1 compares the vetted copy against.
`SMALL_MODEL=1 make seed` seeds Qwen2.5-0.5B-Instruct (491 MB) instead. The choice is written to
`out/small-model`, and every later step and gate uses the same model without `SMALL_MODEL` being
set again; `make seed` prints it on its first line (`seed: model <repo_id> (<file>)`).

## 3. Python packages

Acme's MCP server, `acme-inventory-mcp`, is built by
[`tools/acme-inventory/build_wheel.py`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/tools/acme-inventory/build_wheel.py)
with the standard library only, and published to `pypi-local`. The wheel is deterministic
(sorted entries, fixed timestamps and modes, entries stored uncompressed), so its SHA-256 is
the one pinned in `agent/requirements-internal.txt`; the script stops if it is not:

```console
== 3a. Acme's MCP server package: acme-inventory-mcp 1.0.0 to pypi-local
  built acme_inventory_mcp-1.0.0-py3-none-any.whl sha256 8d5dc07b943ffa736c2c022b9ff823f3f91bf141f81601d9d99a05b5416175a3
  POST /pypi/pypi-local/ (publisher): HTTP 200 OK
```

Then the agent image is built
([`agent/Containerfile`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/agent/Containerfile)):
the base image through `oci-dockerhub`, and every package of
[`agent/requirements.lock`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/agent/requirements.lock)
through the `pypi` Virtual with `pip install --require-hashes`. The lock has 71 packages, each
with the SHA-256 of every file. Rootless podman cannot attach a build to a named network, so the
build uses the host network and reaches Caddy as `ak.internal:30450` (`--add-host`); the
developer token is a build secret and stays out of the image:

```console
== 3b. the agent image: every package of agent/requirements.lock through the pypi Virtual
Installing collected packages: acme-inventory-mcp
Successfully installed acme-inventory-mcp-1.0.0
No broken requirements found.
COMMIT localhost/ak-offgrid/agent:latest
Successfully tagged localhost/ak-offgrid/agent:latest
73e3d925a5a872ebafb6a4f6ec36ad180e63bb4d6230a6854fed553f16ec1526
openai               3.46.0
mcp                  2.3.0
huggingface_hub      2.4.0
mcp-sqlite3          0.1.3
fastmcp              4.1.6
acme-inventory-mcp   1.0.0
```

`make lock` ([`agent/lock.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/agent/lock.sh))
re-resolves the lock from
[`agent/requirements.in`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/agent/requirements.in)
through the registry with `uv pip compile --generate-hashes`. The committed lock is the one of
the reference run; you only need `make lock` to move to newer versions.

## 4. MCP servers

Acme's entry, [`tools/acme-inventory/server.json`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/tools/acme-inventory/server.json),
is published to `mcp-internal`. Its package must already be in `pypi-local`: the repository's
package policy is `own-repos`, and it refuses an entry whose package it does not hold.

```console
== 4a. com.acme/inventory 1.0.0 to mcp-internal (publisher)
HTTP 200
{"_meta":{"com.artifactkeeper.registry/source":{"artifactId":"62de8bdc-a4e6-49e0-8221-5470a002e554","origin":"hosted","packagePolicy":"own-repos","repository":"mcp-internal","sha256":"19b3426828b5e034737c845d76b099136c6006f56e588ebec166b49284955699","upstreamVerified":false},"io.modelcontextprotocol.registry/official":{"isLatest":true,"publishedAt":"2026-11-05T17:15:01.338423219Z",...
```

The public server is `io.github.daedalus/mcp-sqlite3` 0.1.3 from the official registry, a
small SQLite server with no network use of its own. `mcp-official` takes only what an admin
approves. Instead of syncing the whole public catalog and then pinning one entry, the script
asks the Remote to fetch that one name and version
([#5408](https://github.com/artifact-keeper/artifact-keeper/issues/5408)):

```bash
POST /api/v1/repositories/mcp-official/mcp/seed
{"servers": [{"name": "io.github.daedalus/mcp-sqlite3", "version": "0.1.3"}],
 "reason": "reviewed for the off-grid site: local SQLite only, no network"}
```

It answers `202` with a `statusUrl`, which the script polls until the run is `completed` or
`failed`. Each item ends as `pinned`, `already_pinned`, `refused` or `failed`. The fetch goes
through the same outbound path as a sync (the egress proxy, so the ledger, and
`UPSTREAM_FETCHED` rows), records the entry in the catalog as an approved pin (as
`POST .../mcp/catalog/pins` does) and ingests it. The route refuses with `409` while upstream
jobs are paused or the Remote is cache-only; [Step 8](8-prove-it-fails-safely.md) checks that
on the site.

<!-- REFRESH: no output yet. #5408 did not exist in the debug run (main at 0bffa44c); there 4b was a full sync followed by a pin, which never reached the name (see findings). Paste the final run's 4b block: the POST line (HTTP 202 {jobId, status, total}), the final {status, items:[{name, version, state, reason}]} line, and the GET of the entry through mcp-all (HTTP 200). -->

Why not a sync: measured on 2026-11-05, the official registry with `include_deleted` is 2,218
pages and 221,769 entries, plain paging took 442 s, and `io.github.daedalus/mcp-sqlite3` first
appears on page 1,093. A Remote's sync reads at most 200 pages a pass, so the name is reached
only after about six passes, and a manual pass is cut off by the 120 s request timeout
([#5404](https://github.com/artifact-keeper/artifact-keeper/issues/5404)). A full sync is not
needed for this walkthrough; the [findings](findings.md#f3-a-remote-learns-a-name-only-by-syncing-the-whole-catalog)
have what one looked like.

## 5. The plugin

[`plugins/offgrid-ops/`](https://github.com/artifact-keeper/walkthroughs/tree/main/off-grid-ai-stack/plugins/offgrid-ops)
is zipped with fixed timestamps and sorted entries, published to `plugins-central` with its
SHA-256, and then read through the `plugins` Remote, which caches the marketplace documents and
the archive:

```console
== 5. offgrid-ops 1.0.0: publish to plugins-central, read it through the plugins Remote
  PUT plugins-central/offgrid-ops/1.0.0/offgrid-ops-1.0.0.zip: HTTP 201 {"sha256":"6dbf8b77dcd390c8506e27205265d3f76e7208fe3a45bae2eaff2a2a825eded2","marketplace_name":"plugins-central"}
  GET plugins/marketplace.json (through the Remote): HTTP 200
  GET plugins/claude-marketplace.json (through the Remote): HTTP 200
  GET plugins/offgrid-ops/index.json (through the Remote): HTTP 200
  GET plugins/offgrid-ops/1.0.0/offgrid-ops-1.0.0.zip: HTTP 200, sha256 6dbf8b77dcd390c8 (published 6dbf8b77dcd390c8)
```

The plugin names two MCP servers in its `mcp.json` (`acme-inventory`, the command
`acme-inventory-mcp`; `sqlite`, `python -m mcp_sqlite3`) and carries one skill, the instruction
the agent gives the model.

## 6. npm: Claude Code

The Claude Code image for the best-effort step
([`claude/Containerfile`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/claude/Containerfile))
installs `@anthropic-ai/claude-code` 2.1.318 through `npm-remote`, which also pulls its native
`linux-x64` package (157 MB). The build log goes to `out/flows/claude-build.log`; a failed
build is reported and does not stop the seed.

```console
== 6. Claude Code (best-effort step): its image installs through npm-remote
2.1.318 (Claude Code)
```

## What went out

At the end the script counts what went out since it started, from both records:

```console
== what went out while seeding
  ledger: 41 connections opened (out/ledger/ledger.jsonl), by host:
         22 registry.modelcontextprotocol.io
          4 ak-central
          3 pypi.org
          2 registry.npmjs.org
          2 huggingface.co
          2 files.pythonhosted.org
          1 us.aws.cdn.hf.co
          1 registry-1.docker.io
          1 production.cloudfront.docker.com
          1 pkg-containers.githubusercontent.com
          1 ghcr.io
          1 auth.docker.io
  UPSTREAM_FETCHED audit rows since 2026-11-05T17:11:38Z: 987
```

<!-- REFRESH: debug run. 22 registry.modelcontextprotocol.io connections and most of the 987 rows (741 by gate G1's count) are the full MCP catalog syncs the debug run did instead of the #5408 targeted seed; expect far fewer in the final run. -->

Every host is an upstream of one of the Remotes: the registries themselves, their CDNs and
auth services (`auth.docker.io`, `production.cloudfront.docker.com`,
`pkg-containers.githubusercontent.com`, `files.pythonhosted.org`, `us.aws.cdn.hf.co`), and
`ak-central` for the plugins Remote. The 1.1 GB model came over one connection to
`us.aws.cdn.hf.co` (1,119,455,701 bytes down in 63 s, by its `close` line). Gate G1 checks that
both lists contain only expected upstreams.

<!-- REFRESH: the seed's wall time. In the debug run make seed took about 25 min (17:11:38 to about 17:36 UTC), almost all of it the full MCP catalog syncs; measure the final run, and the disk used (podman system df, du -sh of the volumes). -->

Inventory of record: the list of every manifest item with its SHA-256 is written at the end of
[Step 3](3-vet-what-you-seeded.md), once the vetted model is in `hf-models`.
