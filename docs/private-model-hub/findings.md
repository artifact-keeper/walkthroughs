# Lab notes: a private Hugging Face model hub

--8<-- "includes/preview-hf.md"

The record of building and running this walkthrough on 2026-11-04 (UTC): what we ran it on,
the Artifact Keeper bugs and documentation gaps we hit, the behaviour worth knowing, what the
[plan](plan.md) got wrong, and what was not machine-verified. The step pages are written from
these notes and from the reference run in [Results](results.md). Line numbers are for
`artifact-keeper` `main` at `46070a04`.

## Environment

| | |
|---|---|
| Host | `grace`: Ubuntu 26.04, x86_64, 40 cores, 108 GB RAM, rootless podman 5.7.0, `podman compose`, no sudo |
| Neighbours | other Artifact Keeper stacks (`ak-agent-*` on 30445, `ak-gate-*` on 30446, `ak-mcp-*` on 30448, `ak-mcpreg-*`) and docker containers kept running, untouched |
| Backend | `ghcr.io/artifact-keeper/artifact-keeper-backend:dev@sha256:f60236fb...` = `main` at `46070a04` (reports version 1.11.3) |
| Web | `ghcr.io/artifact-keeper/artifact-keeper-web:dev@sha256:ddc8125b...` (reports 1.11.2 dev) |
| Clients | Python 3.12.16, `huggingface_hub` 2.4.0, `transformers` 5.22.1, `sentence-transformers` 6.2.0, torch 2.15.0+cpu, all through the registry |
| Real Hub model | `sentence-transformers/all-MiniLM-L6-v2` at `1110a243fdf4706b3f48f1d95db1a4f5529b4d41` (only `*.json`, `*.txt` and `model.safetensors`, about 90 MB) |

## Artifact Keeper bugs

### F1. snapshot_download fails against a Local repository

Reported as [artifact-keeper#5280](https://github.com/artifact-keeper/artifact-keeper/issues/5280);
a fix is in progress. `hf_hub_download` of a named file, `AutoModel.from_pretrained` and
`SentenceTransformer(...)` all work against `hf-local`; `snapshot_download` does not:

```text
{"ok": false, "cmd": "snapshot", "error": "KeyError", "msg": "'id'"}
```

The hosted model-info document (`backend/src/api/handlers/huggingface.rs:458-465`) has no `id`
key, which `huggingface_hub` 2.x's `ModelInfo` requires; its `lastModified` is the revision name
(`"main"`); its `siblings[].rfilename` is the stored path (`acme/embedder/main/config.json`,
line 431) and covers every revision. Past that, the `sha` it reports
(`local_repo_commit_sha`, line 190) is not something the tree or resolve routes accept: in the
lab, `GET .../tree/<sha>` answered `[]` and `GET .../resolve/<sha>/config.json` 404 while the
same file at `main` was 200. Gate G5 reports the check `BLOCKED(ak-fix)`.

### F2. The tree listing drops `?recursive=true`, so snapshot_download misses files in subdirectories

`huggingface_hub` 2.x no longer builds a snapshot from model info `siblings`: it lists
`api/models/<id>/tree/<commit>?recursive=true` and downloads every file entry. A Remote
proxies the tree without its query string (`proxy_model_tree`, `huggingface.rs:539-550`; the
handler takes no query at all), so the Hub answers with the top level only, `1_Pooling` comes
back as a directory, and `1_Pooling/config.json` is silently left out:

```text
lab Hub log:  GET /api/models/acme-lab/tiny-st/tree/099a800f...   (no ?recursive=true)
snapshot:     {"ok":true, "files":[".gitattributes","README.md","config.json","model.safetensors", ...]}   9 of 10 files
```

`snapshot_download` reports success. Loading still works online, because
`sentence-transformers` fetches `1_Pooling/config.json` on its own; with `HF_HUB_OFFLINE=1` the
model does not load (`Pooling.__init__() missing 1 required positional argument`). The G2
checks for it report `BLOCKED(ak-fix)`. `docs/huggingface.md:160-163` says "Downloads are
unaffected: `snapshot_download` takes its file list from the model-info `siblings`", which is
no longer true. Not filed yet; proposed: forward `recursive`, `expand` and `cursor`, and follow
`Link: rel="next"`.

### F3. Offline, every uncached path is a 502 after an upstream attempt, and clients retry it

With the upstreams gone (step 7), a path that is not in the cache is tried upstream and
answered 502 (about 3 s here, the time to give up on the address). Upstream 404s are
negative-cached for only 45 s (`NEGATIVE_CACHE_TTL_SECS`, `cache_classifier.rs:44`).
`huggingface_hub` retries 5xx five times with backoff, and `transformers` and
`sentence-transformers` probe several optional files on every load (`adapter_config.json`,
`processor_config.json`, `preprocessor_config.json`, ...). The result: loading a seeded model on
a fresh offline workstation did not finish in 60 s (G7); in an unbounded trial it was still
retrying after 12 minutes, with each optional file requested 55 times. Gated models show the
same shape online: the Hub's 401 `GatedRepo` reaches the client as a 502.

A cache-only mode that answers a clean 404 for anything not cached is
[artifact-keeper#5282](https://github.com/artifact-keeper/artifact-keeper/issues/5282). Until
then, fill the workstation's cache from the registry and load with `HF_HUB_OFFLINE=1`
([Step 7](7-freeze-and-go-offline.md)). G7 reports the direct load and the 404 check
`BLOCKED(ak-fix)`.

### F4. A clean scan releases a malicious pickle from the upload hold

Nothing scans model files: grype and the dependency scanner complete with 0 findings on a
`pytorch_model.bin` whose load runs `os.system`, and because the upload hold ends when a scan
comes back clean, the file is downloadable within a second of its upload:

```text
scans: [{"scan_type":"grype","status":"completed","findings_count":0},{"scan_type":"dependency","status":"completed","findings_count":0}, ...]
quarantine: {"quarantine_status":"clean","quarantine_until":null,"is_blocked":false}
GET pytorch_model.bin: HTTP 200
```

A model-file scanner is [artifact-keeper#5285](https://github.com/artifact-keeper/artifact-keeper/issues/5285)
(and #3013, #2382). The hold is still useful as a reviewer's hold; see
[Step 6](6-scan-and-hold.md). G6 reports the check `BLOCKED(ak-gap)`.

### F5. A cold HEAD fetches the file upstream and caches nothing

`hf_hub_download` sends `HEAD` and then `GET`. On a cache miss, the `HEAD` makes Artifact
Keeper `GET` the file from upstream (following the CDN redirect) and drop the body, so nothing
is cached and the `GET` that follows fetches it again. (`proxy_helpers.rs`, around line 1680,
relies on "a HEAD response's body is dropped unpolled"; that holds for a cached entry, not for
a miss.) The lab Hub log for one cold `hf_hub_download` of `model.safetensors`:

```text
GET /acme-lab/tiny-st/resolve/main/model.safetensors 302
GET /cdn/ba316f07...  200
GET /acme-lab/tiny-st/resolve/main/model.safetensors 302
GET /cdn/ba316f07...  200
```

A cold `Range` request does fill the cache. For multi-gigabyte weights this doubles the first
pull's egress. Not filed yet.

### F6. The cache key is the revision as spelled, and every Hugging Face path is mutable

`cache_classifier.rs:327` has no Hugging Face arm, so every path, including
`resolve/<40-hex commit>/...` that can never change, gets the 300 s mutable TTL
([#5283](https://github.com/artifact-keeper/artifact-keeper/issues/5283)). And the cache key is
the path as requested: `resolve/main/1_Pooling/config.json` and
`resolve/099a800f.../1_Pooling/config.json` are two entries. In the lab, a file seeded at the
commit was not served offline at `main` (51.9 s of retries, then a failure). Seed with the
spelling clients will use; `snapshot_download` uses the commit.

## Documentation gaps

- **D1. snapshot_download and `siblings`.** `docs/huggingface.md:160-163` (F2).
- **D2. Upstream filters for Hugging Face.** Nothing says that the filter subject has two
  shapes, `api/models/<org>/<name>/...` and `<org>/<name>/resolve/...`, or that the CDN
  redirect target is not filtered. [Step 4](4-approve-model-sources.md) has a working pair
  ([#5290](https://github.com/artifact-keeper/artifact-keeper/issues/5290)).
- **D3. Datasets.** `README.md:163` ("Models, datasets") and `backend/src/formats/mod.rs:429`
  ("Hugging Face models and datasets") claim datasets; `api/datasets/...` is 404 (G8)
  ([#5290](https://github.com/artifact-keeper/artifact-keeper/issues/5290)).
- **D4. The web install hint.** The package page says `huggingface-cli download <id>` with no
  `HF_ENDPOINT` (and shows the version as `vmain`), so a developer who copies it downloads from
  huggingface.co ([#5290](https://github.com/artifact-keeper/artifact-keeper/issues/5290)).
- **D5. `quarantine_enabled` at creation is ignored.** `POST /api/v1/repositories` accepts
  `quarantine_enabled` and `quarantine_duration_minutes` without an error and stores neither
  (they are fields of `UpdateRepositoryRequest`, `repositories.rs:1326`, not of the create
  request); `PATCH` sets them.
- **D6. Out-of-group users get 404.** `docs/huggingface.md:58` says to "restrict the
  repository accordingly"; with a group grant, everyone else gets 404, not 403 (G3).
- **D7. A raised cache-ttl applies from the next revalidation.** The API reference says so;
  the Hugging Face page should say to set it when the Remote is created if the cache is meant
  to outlive the upstream (F6, [Step 7](7-freeze-and-go-offline.md)).

## Behaviour worth knowing

- **O1. The hit metric.** `ak_proxy_cache_lookups_total{result="hit"}` counts model info, tree
  and large-file serves; `HEAD`s and small files served from the cache are not counted. G2
  uses the lab Hub's own log as the strict check.
- **O2. The Hub token is never echoed and client tokens never travel.** The lab Hub logged the
  repository's token fingerprint on every gated request and no client token fingerprint at
  all; the CDN redirect is followed without the token (G3).
- **O3. A Virtual's snapshot_download "succeeds" with a partial cache.** On a fresh cache it
  fails as documented (model info 404). On a cache that already holds one file of the model,
  `huggingface_hub` falls back to that cache and returns a snapshot with that one file, and no
  error.
- **O4. The web UI badges a rejected file "Quarantined"** ([Results](results.md)).
- **O5. A held file is 409; a rejected or policy-refused file is 403**, on `HEAD` and `GET`
  alike.

## What the plan got wrong

See the table at the end of the [plan](plan.md#what-the-build-changed).

## Not machine-verified

- **Real gated models** (Llama, Gemma): the lab Hub's `acme-lab/gated-llm` stands in, with the
  Hub's 401 and 403 answers. Accepting a model's terms on huggingface.co and using a real Hub
  token was not done.
- **`hf_transfer`** parallel ranges: each range is served by re-reading the cached file from
  byte 0 (`repositories.rs`, around line 11460); not measured.
- **Large models.** The largest file here is about 90 MB. Upload buffering
  (`huggingface.rs:1193, 1224`: the whole body in memory;
  [#5291](https://github.com/artifact-keeper/artifact-keeper/issues/5291)) and the double cold
  download (F5) matter most for multi-gigabyte weights, which were not tried.
- **The web UI.** The screenshots on [Results](results.md) are from the same stack, taken by
  Playwright; nothing in the walkthrough depends on the UI.
