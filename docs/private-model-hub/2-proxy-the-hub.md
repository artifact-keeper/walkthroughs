# Step 2: Proxy the Hub

--8<-- "includes/preview-hf.md"

A developer's workstation points `HF_ENDPOINT` at a Remote and uses `huggingface_hub`,
`hf`, `transformers` and `sentence-transformers` unchanged. Artifact Keeper fetches each file
from the Hub on the first request and serves every later request from its cache.

```bash
make proxy    # flows/proxy.sh
```

## Point the client at the registry

```bash
export HF_ENDPOINT=https://ak.internal/huggingface/hf-lab   # the repository key is part of it
export HF_TOKEN=$(cat registry/.tokens/developer.token)     # an Artifact Keeper token
```

`HF_TOKEN` is an Artifact Keeper API token with `read:artifacts`, sent by `huggingface_hub` as
`Authorization: Bearer`. A Hugging Face token (`hf_...`) is refused with 401 and never passed on
(gate G1). [Client configuration](reference/client-config.md) has the full list, including a
stale `~/.cache/huggingface/token` to remove.

## A first pull

[`flows/proxy.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/flows/proxy.sh) runs `snapshot_download`, then loads the model with
`SentenceTransformer` and encodes two sentences on CPU, in a workstation with an empty cache:

```console
== hf-lab: the developer pulls acme-lab/tiny-st (empty cache)
{"ok":true,"commit":"099a800f5a0de0c030245fa4c02996957602a81e","files":[".gitattributes","README.md","config.json","model.safetensors","modules.json","sentence_bert_config.json","special_tokens_map.json","tokenizer_config.json","vocab.txt"]}
{"ok": true, "cmd": "encode", "endpoint": "https://ak.internal/huggingface/hf-lab", "shape": [2, 32], "first": [-0.457369, 0.287261, -0.22734, -0.365521], "seconds": 8.4}
cache: 099a800f5a0de0c030245fa4c02996957602a81e <- refs/main
  snapshots/099a800f5a0de0c030245fa4c02996957602a81e
  snapshots/099a800f5a0de0c030245fa4c02996957602a81e/1_Pooling
  snapshots/099a800f5a0de0c030245fa4c02996957602a81e/1_Pooling/config.json
  snapshots/099a800f5a0de0c030245fa4c02996957602a81e/config.json
  ...
upstream: the lab Hub logged 35 requests for this pull
model info sha via hf-lab: 099a800f5a0de0c030245fa4c02996957602a81e
```

The client's cache is the normal `~/.cache/huggingface/hub` layout: `refs/main` holds the
commit the Hub reported, and the snapshot directory is named after it, because Artifact Keeper
passes the Hub's `X-Repo-Commit` through. Two things in that output are worth a second look:

- **`snapshot_download` listed 9 files, not 10.** `1_Pooling/config.json` is in the cache
  because `sentence-transformers` fetched it while loading, not because the snapshot did.
  `huggingface_hub` 2.x lists the tree with `?recursive=true`, and Artifact Keeper does not
  pass the query on, so files in subdirectories are left out without an error
  ([findings F2](findings.md#f2-the-tree-listing-drops-recursivetrue-so-snapshot_download-misses-files-in-subdirectories)).
  Online it does not matter; offline it does ([Step 7](7-freeze-and-go-offline.md)).
- **35 upstream requests for 10 files.** Part of it is the library probing for optional files
  (adapter and processor configurations, which the Hub answers 404); part is that a cold
  `HEAD` makes Artifact Keeper fetch the whole file and keep none of it, so `hf_hub_download`
  (`HEAD`, then `GET`) pulls every new file twice
  ([findings F5](findings.md#f5-a-cold-head-fetches-the-file-upstream-and-caches-nothing)).

The CLI works the same way:

```console
$ hf download acme-lab/tiny-st
  path: /home/dev/.cache/huggingface/hub/models--acme-lab--tiny-st/snapshots/099a800f5a0de0c030245fa4c02996957602a81e
```

## The second workstation

A second workstation with an empty cache pulls the same model. Nothing goes upstream:

```console
== hf-lab: a second workstation pulls the same model; Artifact Keeper serves it from its cache
{"ok":true,"commit":"099a800f5a0de0c030245fa4c02996957602a81e","files":[...9 files...]}
{"ok": true, "cmd": "encode", ..., "shape": [2, 32], "first": [-0.457369, 0.287261, -0.22734, -0.365521], "seconds": 8.3}
ak_proxy_cache_lookups_total{repository="hf-lab",result="hit"}: 6 -> 12
upstream: the lab Hub logged 0 requests for the second pull
```

The metric (`GET /api/v1/admin/metrics`) counts model info, the tree and large files served
from the cache, but not `HEAD`s or small files, so it rises by 6 for a pull that served about 30
requests from the cache. The lab Hub's own log is the exact answer: zero.

## huggingface.co

The same, against the real Hub, for `sentence-transformers/all-MiniLM-L6-v2`. The walkthrough
downloads only `*.json`, `*.txt` and `model.safetensors` (about 90 MB) of a repository that
also holds ONNX, OpenVINO, TensorFlow and Rust exports:

```console
== hf-hub: huggingface.co through Artifact Keeper
{"ok":true,"commit":"1110a243fdf4706b3f48f1d95db1a4f5529b4d41","files":["config.json","config_sentence_transformers.json","data_config.json","model.safetensors","modules.json","sentence_bert_config.json","special_tokens_map.json","tokenizer.json","tokenizer_config.json","vocab.txt"]}
{"ok": true, "cmd": "encode", "endpoint": "https://ak.internal/huggingface/hf-hub", "shape": [2, 384], "first": [-0.003146, -0.047963, 0.010903, -0.01194], "seconds": 9.3}
cache: 1110a243fdf4706b3f48f1d95db1a4f5529b4d41 <- refs/main
model info sha via hf-hub: 1110a243fdf4706b3f48f1d95db1a4f5529b4d41
  path: /home/dev/.cache/huggingface/hub/models--sentence-transformers--all-MiniLM-L6-v2/snapshots/1110a243fdf4706b3f48f1d95db1a4f5529b4d41
ak_proxy_cache_lookups_total{repository="hf-hub",result="hit"}: 4 -> 10
```

The model's files are stored with Xet on the Hub. Artifact Keeper strips the Xet fields from the
metadata, so the client downloads through `/resolve/` (and through the cache) instead of asking
for a Xet token and fetching chunks from the Hub's storage directly (gate G8).

Without huggingface.co (no network), `flows/proxy.sh` skips this half and gate G2 reports its
checks `BLOCKED(network)`; the lab Hub half always runs.
