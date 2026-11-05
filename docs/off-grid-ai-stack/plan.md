# Plan: the off-grid AI stack

--8<-- "includes/preview-offgrid.md"

Status: the design this walkthrough was built from, 2026-11-04 and 05, written from the series
plan and from reading Artifact Keeper's code and docs before anything ran. It is kept as
written. Where the build found it wrong, the correction is in the table at the end and in the
[lab notes](findings.md).

## Decisions taken before the build

1. **Seed, then disconnect, on one instance.** The same Artifact Keeper fills its caches on a
   network with a route out, then every container is recreated on an `internal: true`
   network. The two-instance clone (config export, plan, apply) and the low-side/high-side
   mesh push are described on the [Next steps](next-steps.md) page, not run. Step 2 (seeding)
   is the one that `.akbundle` exports
   ([artifact-keeper#2464](https://github.com/artifact-keeper/artifact-keeper/issues/2464))
   could replace once they ship.
2. **The gated agent is a small Python agent**: the `openai` client against llama-server's
   OpenAI-compatible API, the `mcp` stdio client. Claude Code against llama-server's
   Anthropic-compatible endpoint is a labelled best-effort step.
3. **The model** is Qwen2.5-1.5B-Instruct Q4_K_M GGUF, pinned to a commit; `SMALL_MODEL=1`
   switches to SmolLM2-360M-Instruct GGUF.

## Pages

index, 1 stand up the registry, 2 seed the stack, 3 vet what you seeded, 4 disconnect, 5 run
the agent offline, 6 Claude Code (best-effort), 7 prove nothing leaves, 8 prove it fails
safely, results, next steps, reference (seed manifest, make targets), findings, plan.

## Lab

- The stock compose file byte for byte, plus `compose.override.yml` (prefix `ak-offgrid`,
  subnet `172.31.84.0/24`, Caddy `tls internal` on `127.0.0.1:30450`, the `ak.internal`
  alias) and `compose.site.yml`, which replaces the default network with `ak-offgrid-site`
  (`172.31.85.0/24`, `internal: true`).
- The egress ledger: a logging forward proxy, set as every Remote's egress proxy
  (`backend/src/services/egress_proxy.rs`, `PUT .../egress-proxy`, mode `explicit`).
- `seed/manifest.toml` and `seed/seed.sh` produce `out/inventory/seed.tsv`; the same script on
  the site produces `site.tsv`.
- llama-server comes from an Artifact Keeper-proxied ghcr.io image; the model from a
  Hugging Face Remote, published to a vetted Local where the model-file scanner reads it.
- `agent/agent.py` uses the `openai` and `mcp` packages; its MCP coordinates come from
  `/mcp/mcp-all/v0.1/servers`; its plugin from the agentplugins Remote.
- Claude Code installs the same plugin from Artifact Keeper.
- e2e registration: prefix `ak-offgrid`, port 30450, networks `172.31.84.0/24` (seed) and
  `172.31.85.0/24` (site, internal), `disk_gb` 60, `timeout_all` 7200.

## Artifact Keeper features to use

| Feature | Pull request | Used for |
|---|---|---|
| Cache-only mode for Remotes | #5315 | every Remote at the disconnect; a clean 404 on a miss |
| `UPSTREAM_FETCHED` audit event | #5316 | the record of the seed window, and its silence after (G7d) |
| Pause scheduled upstream jobs | #5317 | MCP Remote sync and the rest, at the disconnect |
| Scanner adapter offline mode, vulnerability-DB import | #5314 | the adapter on the site, with a DB carried through the registry |
| Seed a Remote's cache from a path list | #5333 | the model, at its commit |
| agentplugins Remote of another Artifact Keeper | #5334 | the site's plugin marketplace |
| Config export, plan, apply | #5335 | the site's configuration of record; the two-instance clone |
| Model-file scanner | #5337 | the GGUF, and two files that must not get through |
| Commit-pinned Hugging Face paths immutable | #5313 | the seeded model never revalidates |
| The air-gapped guide | #5312 | the checklist the gates follow |
| MCP registry, Hugging Face hosting | #5257, #5300 | the MCP servers, the vetted model |

## Gates

| Gate | What it checks |
|---|---|
| G1 seed | Every manifest item served with a digest; the cache-seed job completed; every Remote's egress is the ledger; the ledger and the `UPSTREAM_FETCHED` rows list the same upstreams. |
| G2 vet | The model-file scanner scanned the GGUF clean and it is served; a truncated GGUF and an `os.system` pickle are flagged and refused; the scanner adapter imports a DB offline and scans an image; the config export plans clean. |
| G3 disconnect | Every Remote cache-only; jobs paused; every container on the internal network only; the export records the offline posture. |
| G4 agent | On the site: the image, the model and every package come from Artifact Keeper at their seeded digests; the plugin is verified; the MCP servers are registry-listed; the model answers through a tool call. |
| G5 Claude Code | Best-effort: the plugin installs offline; one prompt through the local model. |
| G6 fails safely | Unseeded content is a fast 404 counted as `cache_only_miss`; an unapproved MCP server is not served; a manual MCP sync sends nothing; the agent refuses an unlisted server; no route out from the agent. |
| G7 zero egress | G7a no route out from every container; G7b the ledger is unchanged; G7c cache-hit metrics; G7d no `UPSTREAM_FETCHED` / MCP sync rows after the disconnect; G7e the inventory diff; plus a control. |

## What the build changed

| Plan | What running it showed |
|---|---|
| `bootstrap.sh` creates the Remotes, then sets their egress proxy and offline settings | An MCP Remote starts syncing the moment it is created, before its egress proxy applies ([#5402](https://github.com/artifact-keeper/artifact-keeper/issues/5402)). For now the scheduled upstream jobs are paused while the repositories are created; [#5406](https://github.com/artifact-keeper/artifact-keeper/pull/5406) removes the need ([F1](findings.md#f1-an-mcp-remote-syncs-before-its-settings-apply)). |
| `mcp-official` is synced from the official registry, then the public server is pinned | The registry is 2,218 pages and 221,769 entries, `io.github.daedalus/mcp-sqlite3` is on page 1,093, a pass reads 200 pages, and a manual pass is cut off at 120 s ([#5404](https://github.com/artifact-keeper/artifact-keeper/issues/5404)). Ten passes never reached the name. The seed uses a targeted seed of one name and version instead ([#5408](https://github.com/artifact-keeper/artifact-keeper/issues/5408), [F2](findings.md#f2-a-manual-mcp-sync-is-cut-off-by-the-request-timeout), [F3](findings.md#f3-a-remote-learns-a-name-only-by-syncing-the-whole-catalog)). |
| The plugins Remote proxies this instance as `http://backend:8080` | `backend` is on the backend's upstream hostname blocklist; the Remote uses the alias `ak-central` ([B1](findings.md#behaviour-worth-knowing)). |
| The backend at a low fixed address | `.10` collided with podman's dynamic allocation; the backend is `.250` ([B3](findings.md#behaviour-worth-knowing)). |
| The disconnect recreates the running containers on `ak-offgrid-site` | With podman they lose their service DNS aliases and the backend cannot find `postgres`; the stack is taken down and brought up again ([B2](findings.md#behaviour-worth-knowing)). |
| The disconnect: cache-only, then pause the jobs | A sync running at the cut wrote its `MCP_MIRROR_SYNCED` row after the marks. Pause first and wait for the running sync ([B14](findings.md#behaviour-worth-knowing)). |
| G3: the export records the offline posture | Config export has no `upstream_mode` ([#5407](https://github.com/artifact-keeper/artifact-keeper/issues/5407)); G3 reports it `BLOCKED(ak-gap)` ([F4](findings.md#f4-config-export-does-not-carry-the-upstream-mode)). |
| G6: a manual MCP sync sends nothing | Kept, plus a targeted MCP seed on the site, which must be refused with `409`; and cold `HEAD`s, which must open no ledger connection because the audit log does not record that probe ([#5347](https://github.com/artifact-keeper/artifact-keeper/issues/5347), [F5](findings.md#f5-the-cold-head-probe-is-not-audited)). |
| G7c: cache hits only | A cache-only miss is counted both as `miss` and as `cache_only_miss`; the check is `miss <= cache_only_miss` per Remote ([B11](findings.md#behaviour-worth-knowing)). |
| The ledger logs each tunnel | It logged a tunnel only when it closed; it now writes an `open` line before connecting and a `close` line after ([B12](findings.md#behaviour-worth-knowing)). |
| `seed/seed.sh` writes `out/inventory/seed.tsv` | `flows/vet.sh` writes it, once the vetted model is in `hf-models`. |
| Acme's wheel is deterministic | Only stored uncompressed: deflate output differed between zlib builds ([B6](findings.md#behaviour-worth-knowing)). |
| Acme's server on `mcp`'s `FastMCP` | `mcp` 2.x calls it `MCPServer` (`mcp.server.mcpserver`) and a tool's schema `input_schema` ([B7](findings.md#behaviour-worth-knowing)). |
| The agent's packages make no outside calls of their own | `fastmcp` checks pypi.org for updates when it shows its banner; the agent image turns that off ([B8](findings.md#behaviour-worth-knowing)). |
| G5: one prompt through Claude Code's normal session | With its full harness the 1.5B model echoed its prompt after about 300 s; the gated session uses a minimal system prompt and no tools, and answers in 3 s ([B9](findings.md#behaviour-worth-knowing)). |
| `SMALL_MODEL=1` is SmolLM2-360M-Instruct | It made no tool call and invented a number (1000 units). `SMALL_MODEL=1` is Qwen2.5-0.5B-Instruct (491 MB), which calls the tool and answers 42 but does not quote the tool's ref, so G4 gates on the ref only for the default model ([B10](findings.md#behaviour-worth-knowing)). |
| The `:dev` images of `main` | The CI `:dev` image was stale (the CI amd64 builds were failing); the run used local builds of `main` at `0bffa44c`. |
