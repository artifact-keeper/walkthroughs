# Results

--8<-- "includes/preview-offgrid.md"

<!-- REFRESH: this whole page is written from the debug run. Replace the run description, the gate table and the requirement results with the final run (main with #5406, #5407 and #5408, full model and SMALL_MODEL=1), including the measured make all time and disk use. -->

The debug run was on `grace` (rootless podman 5.7, 40 cores) on 2026-11-05 (UTC), from an empty
registry: `make clean`, `make all`, then `make gates` twice. Backend
`localhost/ak-backend:offgrid-0bffa44c`, a local build of `main` at `0bffa44c` (it reports
1.11.3; the CI `:dev` image was older, see [findings](findings.md#environment)), scanner adapter
from the same commit, web `:dev`. Model Qwen2.5-1.5B-Instruct Q4_K_M at
`91cad51170dc`, llama.cpp `server-b12124`, `openai` 3.46.0, `mcp` 2.3.0, `huggingface_hub`
2.4.0, Claude Code 2.1.318. Some scripts were older than the ones in the repository now; the
[reference run](8-prove-it-fails-safely.md#the-reference-run) says which failures that explains.

Measured in that run:

| What | Time |
|---|---|
| Seeding the model with the cache-seed API (1.1 GB from huggingface.co) | 65 s |
| `make seed`, with full MCP catalog syncs instead of a targeted seed | about 25 min |
| Pulling the llama.cpp image again on the site, cache-only | 21 s |
| A clean, hash-checked install of the agent's 73 distributions on the site | 66 s |
| The agent: plugin, registry check, MCP servers, two model turns | 7.6 s |
| Claude Code, minimal prompt, no tools, through the local model | 3 s |
| Claude Code with its full system prompt and tools (an earlier debug session) | about 300 s, and no usable answer |
| `make gates` | 123 s (G7 106 s) |

## The gates

**59 PASS, 10 FAIL, 1 BLOCKED** of 70 checks in the debug run.

| Gate | Result | Time |
|---|---|---|
| G1 Seed | 12 PASS, 1 FAIL | 2 s |
| G2 Vet | 13 PASS, 1 FAIL | 1 s |
| G3 Disconnect | 4 PASS, 1 BLOCKED(ak-gap) | 1 s |
| G4 Agent | 7 PASS, 3 FAIL | 1 s |
| G5 Claude Code | 2 PASS | 0 s |
| G6 Fails safely | 14 PASS, 1 FAIL | 12 s |
| G7 Zero egress | 7 PASS, 4 FAIL | 106 s |

The full list, and what each `FAIL` was, is on
[Prove it fails safely](8-prove-it-fails-safely.md#the-reference-run). Every check that bears on
"nothing leaves" passed: no route out from any container (G7a), no ledger connection (G7b), no
cache miss that went upstream (G7c), cold `HEAD`s that open nothing (G6), and the control
(G7). The two G7d failures were a control row of the first gates run and a sync that was
running at the cut, both explained by older scripts.

## Against the requirements

| | Requirement | Result |
|---|---|---|
| R1 | One registry over TLS serves every layer of the stack: images, the model, Python and npm packages, MCP servers, plugins | Met (G1, G4, G5), except the public MCP server, which the debug run could not seed (F3) |
| R2 | What the site needs is one manifest; seeding it is one command and leaves an inventory with a hash for every item | Met for 84 of 85 items; the public MCP entry needs the targeted seed (#5408) |
| R3 | Every upstream request during seeding is on record twice: the egress ledger and the audit log | Met (G1), once the jobs are paused while Remotes are created (F1, #5402); the cold-HEAD probe is not audited (F5, #5347) |
| R4 | The model is vetted before use; a malformed GGUF and a code-executing pickle are flagged and not served | Met (G2). The scanner reads file structure; it does not judge model behaviour |
| R5 | Scanners keep working offline, with their database carried in through the registry | Met for the import and offline status (G2); the scan check failed on a report the script could not parse |
| R6 | The cut is a handful of documented settings plus a network with no gateway | Met (G3); the export does not record the cache-only mode (F4, #5407) |
| R7 | On the disconnected site an agent installs its plugin, starts only registry-listed MCP servers, and answers through a local model's tool call | Met for Acme's server and the tool call (G4); the public server was refused because it was not listed, which is the check working |
| R8 | Nothing leaves after the cut: no route, no ledger line, no upstream audit row, cache hits only, the same inventory | Met for this lab's containers and network (G7a, G7b, G7c misses, G6 cold HEADs, the control); G7d and G7e failed for reasons outside egress (see above) |
| R9 | What was not seeded fails fast and clearly; nothing waits on an upstream that is not there | Met (G6): every unseeded item is a 404 in under 350 ms |

## Artifact Keeper issues found

| | Kind | Summary |
|---|---|---|
| [F1](findings.md#f1-an-mcp-remote-syncs-before-its-settings-apply) | bug | An MCP Remote syncs the moment it is created, before its egress proxy and upstream mode can be set ([#5402](https://github.com/artifact-keeper/artifact-keeper/issues/5402); fix in [#5406](https://github.com/artifact-keeper/artifact-keeper/pull/5406)) |
| [F2](findings.md#f2-a-manual-mcp-sync-is-cut-off-by-the-request-timeout) | bug | A manual MCP sync runs inline and is cut off by the 120 s request timeout, as a 503 "Server overloaded" ([#5404](https://github.com/artifact-keeper/artifact-keeper/issues/5404)) |
| [F3](findings.md#f3-a-remote-learns-a-name-only-by-syncing-the-whole-catalog) | gap | An MCP Remote cannot pin or seed a named server version without a full catalog sync ([#5408](https://github.com/artifact-keeper/artifact-keeper/issues/5408)) |
| [F4](findings.md#f4-config-export-does-not-carry-the-upstream-mode) | gap | Config export does not carry a Remote's upstream mode ([#5407](https://github.com/artifact-keeper/artifact-keeper/issues/5407)) |
| [F5](findings.md#f5-the-cold-head-probe-is-not-audited) | bug | The cold-HEAD upstream probe is not an `UPSTREAM_FETCHED` row ([#5347](https://github.com/artifact-keeper/artifact-keeper/issues/5347)) |
