# Step 8: Prove it fails safely

--8<-- "includes/preview-offgrid.md"

!!! tip "If something goes wrong"
    See [Troubleshooting](reference/troubleshooting.md): every failure we hit while building
    this walkthrough, with its cause and fix.

Every claim the earlier steps make is a check in
[`gates/`](https://github.com/artifact-keeper/walkthroughs/tree/main/off-grid-ai-stack/gates).
This page has gate G6, which checks that what was not seeded fails fast and clearly, and then
every gate line of the reference run.

```bash
make gates                    # all seven
gates/run-all.sh g06 g07      # some of them
```

Each check prints one line, `PASS`, `FAIL` or `BLOCKED(<reason>)`, and appends it to
`out/gates/results.tsv`; each gate's full output goes to `out/gates/<gate>.log` and its duration
to `out/gates/timings.tsv`. Checks assert on status codes, documents, digests, hashes, counters
and audit rows, never on message text. `make gates` exits non-zero on any `FAIL`. A `BLOCKED`
check says nothing about the walkthrough itself:

| Reason | Meaning |
|---|---|
| `BLOCKED(network)` | an upstream (huggingface.co, ...) was not reachable while seeding |
| `BLOCKED(ak-fix)` | an Artifact Keeper bug, reported and not fixed yet ([findings](findings.md)) |
| `BLOCKED(ak-gap)` | a capability Artifact Keeper does not have yet ([findings](findings.md)) |
| `BLOCKED(best-effort)` | the Claude Code model session ([Step 6](6-claude-code-best-effort.md)), shown, not promised |

G1 and G2 read what `make seed` and `make vet` left; G3 to G7 run on the site network and need
`make disconnect` (and G4, G5 need `make agent` and `make claude`). The gates can run again and
again on the same site: G7's control records its window so that later runs leave it out.

## The gates

| Gate | What it proves |
|---|---|
| [G1 Seed](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/gates/g01-seed.sh) | Every kind of manifest item is in the inventory with a digest; the `hf-hub` cache-seed job completed with every path cached; the GGUF `hf-models` serves has the SHA-256 the seed job fetched; every Remote's egress proxy is the ledger; the ledger's hosts are all expected upstreams, every Remote has `UPSTREAM_FETCHED` rows, and the rows name the same set of hosts as the ledger |
| [G2 Vet](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/gates/g02-vet.sh) | The model-file scanner scanned the GGUF with no finding and it is served; the truncated GGUF and the `os.system` pickle are flagged and refused, the pickle as `model.pickle.dangerous-global`; the adapter imported a DB, is offline and reports its age, and scans the llama.cpp image; the export has every repository, no credential, and plans clean |
| [G3 Disconnect](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/gates/g03-disconnect.sh) | Every Remote is cache-only; the jobs are paused; `ak-offgrid-site` is internal; every container is on it only; the export records every Remote as cache-only ([#5407](https://github.com/artifact-keeper/artifact-keeper/issues/5407)) |
| [G4 Agent](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/gates/g04-agent.sh) | On the site: both images pulled again at the seed's digests; the model at the seed's SHA-256; llama-server serves it; a clean hash-checked install works; the plugin is verified; both MCP servers are listed in `mcp-all` and started; the public server answers offline; the model called `stock_level` right and the answer has 42 (and, with the default model, the tool's ref) |
| [G5 Claude Code](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/gates/g05-claude.sh) | A clean npm install of Claude Code works on the site; Claude Code installs `offgrid-ops@plugins` offline; best-effort: the local model answers as asked |
| [G6 Fails safely](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/gates/g06-fails-safely.sh) | Below |
| [G7 Zero egress](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/gates/g07-zero-egress.sh) | G7a to G7e and the control ([Step 7](7-prove-nothing-leaves.md)) |

## G6: what was not seeded

### A fast, clean 404

Five things nobody seeded, one per kind of Remote, asked for as the developer. Each must be a
`404` in under 2 s: no upstream attempt for a client to wait on, and a status a client does not
retry. (The [private model hub](../private-model-hub/7-freeze-and-go-offline.md#why-hf_hub_offline)
showed what the alternative looks like: a 502 after a failed upstream attempt, retried for
minutes.)

```console
a model file nobody seeded (hf-hub): GET /huggingface/hf-hub/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf -> HTTP 404 in 42 ms
a PyPI project nobody seeded (pypi Virtual): GET /pypi/pypi/simple/rich-click/ -> HTTP 404 in 62 ms
an image tag nobody seeded (oci-ghcr): GET /v2/oci-ghcr/ggml-org/llama.cpp/manifests/server-b5000 -> HTTP 404 in 348 ms
an npm package nobody seeded (npm-remote): GET /npm/npm-remote/left-pad -> HTTP 404 in 40 ms
a plugin version nobody published (plugins Remote): GET /agentplugins/plugins/offgrid-ops/9.9.9/offgrid-ops-9.9.9.zip -> HTTP 404 in 38 ms
```

The model path is `Qwen2.5-0.5B-Instruct-GGUF` at `main`. With `SMALL_MODEL=1` that model is the
seeded one, but only at its commit, so the `main` path is still unseeded; G6 passed in the
small-model run too.

### Cold HEADs open no connection and write no row

A `HEAD` for something the cache does not hold is, on an online Remote, answered from an
upstream `HEAD`. That probe was the one upstream request the `UPSTREAM_FETCHED` event did not
record ([artifact-keeper#5347](https://github.com/artifact-keeper/artifact-keeper/issues/5347));
since [#5414](https://github.com/artifact-keeper/artifact-keeper/pull/5414) (`main` at
`a2f53502`) it does. On a cache-only Remote it must not happen at all. Three cold `HEAD`s, on
`hf-hub`, `oci-ghcr` and `pypi-remote`, must be fast `404`s that add no ledger line and no
audit row:

```console
cold HEAD hf-hub /huggingface/hf-hub/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/README.md: HTTP 404 in 37 ms
cold HEAD oci-ghcr /v2/oci-ghcr/ggml-org/llama.cpp/manifests/server-b5001: HTTP 404 in 344 ms
cold HEAD pypi-remote /pypi/pypi-remote/simple/rich-click/: HTTP 404 in 40 ms
ak_proxy_cache_lookups_total{result="cache_only_miss"}: 1 -> 8
PASS              G6   the cold HEADs opened no connection and wrote no UPSTREAM_FETCHED row
PASS              G6   the misses are counted as cache_only_miss (they never tried an upstream)
```

### MCP: not approved, not seeded, not synced

An MCP server nobody approved (`io.github.tonydzi/sqlite-graph-memory`) is not served by
`mcp-all`:

```console
HTTP 404
{"detail":"Server not found","status":404,"title":"Not Found","type":"about:blank"}
```

Then, on the site, an admin tries to bring in another public server with a targeted seed, and
then to run a manual sync:

```bash
POST /api/v1/repositories/mcp-official/mcp/seed {"servers":[{"name":"io.github.daedalus/mcp-sympy","version":"0.1.0"}],"reason":"G6: must be refused offline"}
POST /api/v1/repositories/mcp-official/mcp/sync
```

Both must be refused with `409` while the upstream jobs are paused, and neither may add a
ledger line or an `UPSTREAM_FETCHED` row:

```console
POST .../mcp/seed (on the site): HTTP 409 {"code":"CONFLICT","message":"scheduled upstream jobs are paused on this instance (upstream_jobs_paused); a seed contacts the upstream and waits for the switch too"}
POST .../mcp/sync (on the site): HTTP 409 {"code":"CONFLICT","message":"scheduled upstream jobs are paused on this instance (upstream_jobs_paused); no sync starts until the switch is off"}
  sync state: {"running":false,"lastStartedAt":null,"lastFinishedAt":null}
refused seed and sync: ledger 24 -> 24; UPSTREAM_FETCHED since the disconnect 0 -> 0
PASS              G6   a targeted MCP seed on the site is refused (409: upstream jobs paused, the Remote cache-only; #5408)
PASS              G6   a manual MCP sync on the site is refused (409: upstream jobs are paused)
PASS              G6   the refused seed and sync sent nothing upstream
```

The refusals say why, and no sync state changes (`running` false, never started). Before
[#5405](https://github.com/artifact-keeper/artifact-keeper/pull/5405) a manual sync ran inside
the request and was answered `503 Server overloaded` when it outlasted the request timeout
([findings F2](findings.md#f2-a-manual-mcp-sync-was-cut-off-by-the-request-timeout)); now it is
`202` with the run in the background when it is allowed, and `409` when it is not.

### The agent refuses an unlisted server

The agent is run against `mcp-internal` alone (`MCP_REPO=mcp-internal`), a registry that does
not list `mcp-sqlite3`. It must refuse to start the `sqlite` server its plugin names:

```console
[{"step":"mcp-started","server":"acme-inventory","registry_name":"com.acme/inventory"},{"step":"mcp-refused","server":"sqlite","registry_name":null}]
```

### No route out from the agent

```console
1.1.1.1 unreachable: OSError
8.8.8.8 unreachable: OSError
huggingface.co unreachable: gaierror
pypi.org unreachable: gaierror
registry.modelcontextprotocol.io unreachable: gaierror
```

## The reference run

On `grace`, 2026-11-06 05:16-05:18 UTC, from a fresh `git clone` of the walkthrough at `de0597c`, with the
CI images of `main` at `88f23c51` ([Step 1](1-stand-up-the-registry.md#images)), after `make all`
(11 min 12 s): **73 PASS, 0 FAIL, 0 BLOCKED** of 73 checks. `make gates` took 2 min 6 s; G7
takes 109 s of it, G6 12 s, the others 2 s or less each.

```text
PASS              G1   the inventory of record exists (make vet writes it)
PASS              G1   inventory: every image of the manifest is served, with a digest (4)
PASS              G1   inventory: every model of the manifest is served, with a digest (4)
PASS              G1   inventory: every python of the manifest is served, with a digest (72)
PASS              G1   inventory: every npm of the manifest is served, with a digest (2)
PASS              G1   inventory: every mcp of the manifest is served, with a digest (2)
PASS              G1   inventory: every plugin of the manifest is served, with a digest (1)
PASS              G1   the hf-hub cache-seed job completed with every path cached (#5333)
PASS              G1   the GGUF hf-models serves is the file the seed job cached from huggingface.co (same SHA-256)
PASS              G1   every Remote sends its upstream traffic through the egress ledger (explicit egress proxy)
PASS              G1   the ledger recorded the seed's traffic, to the expected upstreams only
PASS              G1   every Remote's upstream requests are UPSTREAM_FETCHED audit rows (AUDIT_UPSTREAM_FETCHES=all, #5316)
PASS              G1   the audit rows and the ledger name the same upstream hosts
PASS              G2   the model-file scanner scanned the GGUF in hf-models (scan_type model, completed, #5337)
PASS              G2   the GGUF has no model-scanner finding
PASS              G2   hf-models serves the scanned GGUF (policy hf-models-vetted: block_unscanned, max_severity medium)
PASS              G2   truncated: the model-file scanner reports it
PASS              G2   truncated: hf-models refuses to serve it
PASS              G2   pickle: the model-file scanner reports it
PASS              G2   pickle: hf-models refuses to serve it
PASS              G2   pickle: the finding is model.pickle.dangerous-global (os.system)
PASS              G2   scanner adapter: the trivy DB import was accepted (PUT /api/v1/vulndb, #5314)
PASS              G2   scanner adapter: offline, with the imported DB's age reported
PASS              G2   scanner adapter: a scan of the llama.cpp image from the registry completes offline
PASS              G2   config export: one document with every repository (13 of 13, #5335)
PASS              G2   config export: no credential in it (the plugins Remote's token is a secret_ref)
PASS              G2   config plan: the export planned against this instance changes nothing
PASS              G3   every Remote is cache-only (effective_upstream_mode, #5315)
PASS              G3   the scheduled upstream jobs are paused (upstream_jobs_paused, #5317)
PASS              G3   ak-offgrid-site is internal (no gateway, no route out)
PASS              G3   every running container of the stack is on ak-offgrid-site only
PASS              G3   the exported configuration records every Remote as cache-only
PASS              G4   the llama image was pulled again on the site, through oci-ghcr, at the seed's digest
PASS              G4   the python image was pulled again on the site, through oci-dockerhub, at the seed's digest
PASS              G4   the model was downloaded on the site from hf-models with hf download, at the seed's SHA-256
PASS              G4   llama-server runs on the site network and serves the model
PASS              G4   a clean, hash-checked install of every agent package from the pypi Virtual works on the site
PASS              G4   the agent installed offgrid-ops from the plugins Remote and verified its SHA-256 against the index
PASS              G4   both MCP servers of the plugin are listed in mcp-all at their installed versions, and started
PASS              G4   the public server (mcp-sqlite3, from the official registry) answers a tool call offline
PASS              G4   the local model called stock_level for OG-1138 in north
PASS              G4   the answer gives the tool's number (42 units)
PASS              G4   the answer quotes the tool's ref (inv-7f3a9c), as the plugin's skill asks
PASS              G5   a clean npm install of Claude Code (and its native package) from npm-remote works on the site
PASS              G5   Claude Code installs offgrid-ops from the plugins Remote, offline
PASS              G5   best-effort: Claude Code gets the asked-for answer from the local model (ANTHROPIC_BASE_URL -> llama-server; minimal system prompt, no tools)
PASS              G6   a model file nobody seeded (hf-hub): 404 in under 2 s
PASS              G6   a PyPI project nobody seeded (pypi Virtual): 404 in under 2 s
PASS              G6   an image tag nobody seeded (oci-ghcr): 404 in under 2 s
PASS              G6   an npm package nobody seeded (npm-remote): 404 in under 2 s
PASS              G6   a plugin version nobody published (plugins Remote): 404 in under 2 s
PASS              G6   a cold HEAD on hf-hub for something nobody seeded: 404, fast
PASS              G6   a cold HEAD on oci-ghcr for something nobody seeded: 404, fast
PASS              G6   a cold HEAD on pypi-remote for something nobody seeded: 404, fast
PASS              G6   the cold HEADs opened no connection and wrote no UPSTREAM_FETCHED row
PASS              G6   the misses are counted as cache_only_miss (they never tried an upstream)
PASS              G6   an MCP server the curator did not approve is not served by mcp-all
PASS              G6   a targeted MCP seed on the site is refused (409: upstream jobs paused, the Remote cache-only; #5408)
PASS              G6   a manual MCP sync on the site is refused (409: upstream jobs are paused)
PASS              G6   the refused seed and sync sent nothing upstream
PASS              G6   the agent does not start an MCP server its registry does not list (registry mcp-internal only: sqlite refused)
PASS              G6   the agent's container has no route out (1.1.1.1, 8.8.8.8, huggingface.co, pypi.org, the MCP registry)
PASS              G7a  no route out from any of the 8 running containers (stack, ledger, llama-server)
PASS              G7b  the egress ledger saw no connection opened since the disconnect (outside the control windows)
PASS              G7c  the Remotes the site used answered from the cache (hit > 0: oci-ghcr oci-dockerhub pypi-remote npm-remote plugins)
PASS              G7c  every cache miss on a cache-only Remote ended at the cache-only gate (miss <= cache_only_miss)
PASS              G7c  nothing was served stale (ak_proxy_stale_if_error_responses_total is 0)
PASS              G7d  no UPSTREAM_FETCHED audit row since the disconnect
PASS              G7d  no scheduled MCP sync since the disconnect: no MCP_MIRROR_SYNCED row outside the recorded windows
PASS              G7e  the site serves exactly the seeded inventory (85 items, same SHA-256 each)
PASS              G7   control: with the hole poked, the attempt to leave is in the ledger
PASS              G7   control: with the hole poked, the attempt is an UPSTREAM_FETCHED row
PASS              G7   control: sealed again, the same request adds no ledger line and no audit row, and is a 404
```

The `SMALL_MODEL=1` run (Qwen2.5-0.5B) ended at 71 PASS, 0 FAIL, 1 BLOCKED of 72 checks: G4 does
not gate on the ref there, and the one `BLOCKED` is G5's best-effort session
([Step 6](6-claude-code-best-effort.md#the-local-model-through-the-anthropic-api)).
[Results](results.md) has both runs side by side.
