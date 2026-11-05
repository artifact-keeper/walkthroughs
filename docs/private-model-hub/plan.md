# Plan: a private Hugging Face model hub

--8<-- "includes/preview-hf.md"

Status: the design this walkthrough was built from, 2026-11-04, written from reading Artifact
Keeper's code before anything ran. It is kept as written. Where the build found it wrong, the
correction is in the table at the end and in the [lab notes](findings.md).

## Pages

index, 1 stand up the registry, 2 proxy the Hub, 3 gated and private models, 4 approve model
sources, 5 host your own models, 6 scan and hold, 7 freeze and go offline, 8 prove it fails
safely, results, next steps, reference (Hub API coverage, client configuration, make targets),
findings, plan.

## Lab

- The stock compose file byte for byte, plus `compose.override.yml`: prefix `ak-hf`, subnet
  `172.31.80.0/24`, Caddy `tls internal` on `127.0.0.1:30449`, the `ak.internal` alias. The
  trimmed Caddyfiles of the other walkthroughs drop `reverse_proxy /huggingface/*`, so add it
  back.
- `client/Containerfile`: a Python base image pulled through Artifact Keeper's OCI Remote, with
  `huggingface_hub`, `transformers`, `sentence-transformers` and CPU torch from its PyPI Remote.
- `lab-hub/server.py` (standard library, like the guardrails walkthrough's lab upstream) at
  `.200`: `api/models/{id}`, `/revision/{rev}`, `/tree/{rev}`, and `/resolve/` (a 302 to a
  `cdn.lab` alias for "LFS" files). It emits `X-Repo-Commit`, `X-Linked-Etag` and `xetHash`,
  and gates one model behind a bearer token. It is admitted through
  `AK_SSRF_ALLOW_PRIVATE_CIDRS`.
- Remotes `hf-hub` (real huggingface.co) and `hf-lab`.

## Gates

| Gate | What it checks |
|---|---|
| G1 access | Anonymous gets 401 on a private repository; a `read:artifacts` token downloads; a real `hf_` token is refused with 401 (`docs/huggingface.md:80-87`). |
| G2 proxy | `HF_ENDPOINT` on `hf-hub`; `hf download sentence-transformers/all-MiniLM-L6-v2`; `snapshot_download`; `SentenceTransformer.encode` on CPU. The cache directories get `X-Repo-Commit` snapshots, and `ak_proxy_cache_lookups_total` hits rise on the second pull. Needs huggingface.co, else `BLOCKED(network)`; the same checks run against `hf-lab` and pass offline. |
| G3 gated | Repository upstream auth (`PUT .../upstream-auth`) for the lab's gated model, with a group restriction. Without upstream auth the request is refused; an in-group user downloads; an out-of-group user gets 403; the client token is never forwarded (the lab Hub's log). |
| G4 allowlist | An upstream include filter covering both path shapes, `api/models/<org>/...` and `<org>/<name>/resolve/...` (`backend/src/services/upstream_filter.rs`; not documented for Hugging Face, a finding). An approved organization resolves; `evil-org/backdoor` and the lookalike `sentence-transformer/...` are refused. |
| G5 hosted | `POST .../upload/{rev}` with `X-Filename`; `hf_hub_download` per file passes; a re-publish gets 409; `write:artifacts` is required. `snapshot_download` on hosted is `BLOCKED(ak-fix)` until the fix lands (`huggingface.rs:190-197, 411-465, 1050`). |
| G6 hold | Scan on upload runs; a quarantined file gets 403/404 through `/resolve/` and is released again; `block_unscanned`. Say honestly that there is no pickle or GGUF scanner (#3013, #2382). |
| G7 offline | cache-ttl 315360000 on both Remotes and `on_upstream_not_found: keep`; stop the lab Hub; put the client on an `internal: true` network. `snapshot_download` and `from_pretrained` of the seeded model succeed; an unseeded id fails fast; `X-AK-Stale-Since` is absent. |
| G8 fails safely | `xetHash` is stripped (`huggingface.rs:556-618`); `xet-read-token` gets 404; a Virtual's `snapshot_download` fails as documented (`docs/huggingface.md:169-175`) while `hf_hub_download` works; a Range resume gets 206; `..%2f` is refused; a read token cannot upload. |

Not machine-verified (labelled as such): UI screenshots, real gated Llama or Gemma models,
`hf_transfer` parallel ranges (each range re-reads from byte 0, `repositories.rs` ~11460-11480).

## Known findings, before the build

Hosted `snapshot_download` is broken; no Hub commit API (`upload_folder`;
`docs/huggingface.md:126-142`); the tree is one page and drops `recursive`/`expand`
(`huggingface.rs:536-548`); no Hugging Face arm in `cache_classifier.rs:238-335`;
`X-Linked-Etag`/`X-Linked-Size` are not emitted; `README.md:163` and
`backend/src/formats/mod.rs:447` wrongly claim datasets; the web install hint omits
`HF_ENDPOINT` (artifact-keeper-web `src/lib/package-utils.ts:128-129`); a hosted upload buffers
the whole body in memory (`huggingface.rs:1194, 1223`); no end-to-end test uses
`huggingface_hub` (artifact-keeper-test `tests/formats/AUDIT.md:83`).

e2e registration: prefix `ak-hf`, port 30449, network `ak-hf-net` `172.31.80.0/24`, requires
`tool:python3`, `min_ak` 1.12.0.

## What the build changed

| Plan | What running it showed |
|---|---|
| One network, `172.31.80.0/24` | A second one is needed for step 7: `ak-hf-offline` (`172.31.81.0/24`, `internal: true`), with Caddy on both. |
| `AK_EXTERNAL_URL=https://ak.internal` (as the other walkthroughs) | Left unset: the OCI token realm is built from it, and the host-side image build cannot resolve `ak.internal`. |
| The client image is built on `ak-hf-net` | Rootless podman cannot attach a build to a named network; the build uses the host network and `--add-host ak.internal:127.0.0.1`. |
| G3: an out-of-group user gets 403 | 404: a private repository the user cannot read is not disclosed. |
| G3: without upstream auth the request is "refused" | 502 "Failed to fetch from upstream": the Hub's 401 (`GatedRepo`) is not passed on. |
| G5: the hosted `snapshot_download` failure is the commit sha | It fails earlier: model info has no `id`, so `huggingface_hub` 2.x raises `KeyError: 'id'` (artifact-keeper#5280 covers both; fixed by #5300, with which G5 passes). |
| G6: a quarantined file gets 403/404 | 409 while held, 403 once rejected or refused by the scan policy. A clean scan releases an upload hold by itself, within a second here. |
| G7: an unseeded id fails fast | Artifact Keeper answers in about 3 s, but with 502, which `huggingface_hub` retries; and every optional file a library probes (`adapter_config.json`, ...) behaves the same, so loading a seeded model on a fresh offline workstation takes minutes (artifact-keeper#5282). |
| G7: set cache-ttl, then go offline | A raised cache-ttl applies to an entry only from its next revalidation, so entries cached before the change still expire on the old 300 s TTL. Freeze when the Remote is created (bootstrap does). |
| `snapshot_download` takes its file list from model info `siblings` (as `docs/huggingface.md` says) | `huggingface_hub` 2.x lists the tree with `recursive=true`, which Artifact Keeper drops, so files in subdirectories are silently left out of the snapshot. |
| Not in the plan | A cold `HEAD` on `/resolve/` fetches the file upstream and caches nothing, so `hf_hub_download` (HEAD, then GET) pulls every uncached file twice. |
