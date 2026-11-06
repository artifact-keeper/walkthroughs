# Highlights: the off-grid AI stack

The numbers below are from the reference run on `grace` (Ubuntu 26.04 LTS, 40 cores, 108 GB
RAM, rootless podman 5.7.0), 2026-11-06, from a fresh `git clone` of the walkthrough at
`de0597c` and an empty registry. The details and logs are in
[Results](../../docs/off-grid-ai-stack/results.md) and
[Prove it fails safely](../../docs/off-grid-ai-stack/8-prove-it-fails-safely.md#the-reference-run).
The casts and screenshots in [`casts/`](casts/) and
[`../../docs/off-grid-ai-stack/images/`](../../docs/off-grid-ai-stack/images/) come from a third
full-size run from the same clone, left up and disconnected on `grace` for live capture; their
figures differ slightly (see [SCRIPT.md](SCRIPT.md)).

## Headline numbers

| | |
|---|---|
| From empty registry to an agent answering offline | `make all`: 11 min 12 s (Qwen2.5-1.5B); 9 min 16 s with `SMALL_MODEL=1` (Qwen2.5-0.5B) |
| Proving it | `make gates`: 2 min 6 s, **73 PASS, 0 FAIL, 0 BLOCKED** of 73 checks. `SMALL_MODEL=1`: 71 PASS, 0 FAIL, 1 BLOCKED(best-effort) of 72 (the Claude Code session) |
| Disk | the filesystem grew by 9.94 GB with the stack images already in podman's store, 18.95 GB from an empty store; `out/` is 2.5 GB, mostly the model copies |
| Model | `Qwen/Qwen2.5-1.5B-Instruct-GGUF` at commit `91cad51170dc`, `qwen2.5-1.5b-instruct-q4_k_m.gguf`, 1,117,320,736 bytes, SHA-256 `6a1a2eb6d15622bf...`, on llama.cpp `server-b12124`, CPU only, 16 threads |
| Seeding the model | one cache-seed request; 63 s for 1.1 GB |
| What went out while seeding, up to the cut | 283 upstream requests (`UPSTREAM_FETCHED` rows) over 24 connections (the egress ledger), to 12 hosts; the two records name the same hosts |
| The public MCP server | `io.github.daedalus/mcp-sqlite3` 0.1.3, seeded by name and version: 2 requests to the official registry, instead of paging its 221,769 entries |
| The tool call, offline | `stock_level` with `{"sku": "OG-1138", "warehouse": "north"}`, returning `"units": 42, "ref": "inv-7f3a9c"` |
| The answer | "There are 42 units of SKU OG-1138 in the north warehouse. (ref: inv-7f3a9c)" (first model turn 4.2 s, answer 1.9 s; the agent, end to end, 10.6 s) |
| Egress after the cut | **0** ledger connections, **0** `UPSTREAM_FETCHED` rows, **0** `MCP_MIRROR_SYNCED` rows; no route out from any of the 8 running containers |
| The control | one hole opened on purpose: 1 ledger connection and 1 audit row; sealed: 0 and 0, and a 404 in 37 ms |
| Fails fast | everything not seeded is a 404 in 37 to 348 ms; an MCP seed or sync on the site is a 409 |
| Vetting | a truncated GGUF flagged `model.gguf.malformed` (medium), a pickle that calls `os.system` flagged `model.pickle.dangerous-global` (critical); both refused with 403 |
| Inventory | 85 items (4 images, the 2 model files in `hf-hub` and in `hf-models`, 72 wheels, 2 npm packages, 2 MCP entries, 1 plugin), the same SHA-256 on the site as at the seed |

## Images and versions

| | |
|---|---|
| Artifact Keeper | `main` at `88f23c51` (reports 1.11.3); the fixes it needed went in as #5406, #5405, #5409, #5414 and #5415 |
| Backend | `ghcr.io/artifact-keeper/artifact-keeper-backend:dev@sha256:1314a083cfecc388e6f4107248817eff50b7c103913849e225c32c781dcd2427` |
| Scanner adapter | `ghcr.io/artifact-keeper/artifact-keeper-scanner-adapter:dev@sha256:d44dacfa01a846b27e247e021eb58df78c3b5c55ccd03a3c1872e25233699cb1` |
| Web | `ghcr.io/artifact-keeper/artifact-keeper-web:dev@sha256:e05124d427420f81fbc2656bbad1cd50a5e3333a5cfae27859a61c6f1812e5ff` (`artifact-keeper-web` at `b65f9614`) |
| Model server | `ghcr.io/ggml-org/llama.cpp:server-b12124@sha256:c0a11067c72bb1eb330b8bddbf9869274c195e596bf4fae55fd527102e644b85` |
| Agent | Python 3.12, `openai` 3.46.0, `mcp` 2.3.0, `huggingface_hub` 2.4.0, `mcp-sqlite3` 0.1.3; 71 packages, every file hash-pinned |
| Claude Code | 2.1.318, installed from the registry on the site in 6 s |

## Pull quotes

1. "Seed it while connected, cut the cable, and the agent still answers: a local model, two MCP
   servers and a plugin, all from one Artifact Keeper, with zero connections out."
2. "We do not just say nothing leaves. A logging proxy, the audit log and the network itself all
   check it, and a control opens one hole on purpose to show they would have seen it."
3. "Everything the site has came over 24 connections, logged twice, before the cut. After it:
   none."
4. "A truncated model file and a booby-trapped pickle go in. Neither comes out."
5. "73 checks, 73 passes, from an empty registry in eleven minutes, with the model on CPU only."

Keep the claims as narrow as the walkthrough: "nothing leaves" is shown for this lab's
containers on this lab's network, the model scanner reads file structure and does not judge a
model's behaviour, and approving a public MCP server means trusting it.
