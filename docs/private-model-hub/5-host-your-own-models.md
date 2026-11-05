# Step 5: Host your own models

--8<-- "includes/preview-hf.md"

A Local (hosted) `huggingface` repository holds models your own teams produce. A training job
publishes the files; developers download them with the same libraries and the same
`HF_ENDPOINT` pattern as anything proxied.

```bash
make host    # flows/host.sh
```

## Two repositories

```json
{"key": "hf-local",  "format": "huggingface", "repo_type": "local",   "visibility": "private"}
{"key": "hf-models", "format": "huggingface", "repo_type": "virtual", "visibility": "private",
 "member_repos": [{"repo_key": "hf-local", "priority": 1}, {"repo_key": "hf-lab", "priority": 2}]}
```

The publisher gets read and write on `hf-local`; the developer gets read on both.

## Publish

The "training job" here loads `acme-lab/tiny-st` and saves it as `acme/embedder` with
`sentence-transformers`, which writes the usual nine files, one in a subdirectory. `huggingface_hub`'s
`upload_file` and `upload_folder` speak the Hub's commit API, which Artifact Keeper does not
implement ([#5291](https://github.com/artifact-keeper/artifact-keeper/issues/5291)), so each
file goes up with Artifact Keeper's own route, its path in `X-Filename`:

```bash
curl -X POST -H "Authorization: Bearer $PUBLISHER_TOKEN" -H "X-Filename: 1_Pooling/config.json" \
  --data-binary @out/models/embedder/1_Pooling/config.json \
  https://ak.internal/huggingface/hf-local/api/models/acme/embedder/upload/main
```

```console
== publish it file by file (publisher token, write:artifacts)
  1_Pooling/config.json            HTTP 200 {"path":"acme/embedder/main/1_Pooling/config.json","size":89}
  config.json                      HTTP 200 {"path":"acme/embedder/main/config.json","size":663}
  config_sentence_transformers.json HTTP 200 {"path":"acme/embedder/main/config_sentence_transformers.json","size":282}
  model.safetensors                HTTP 200 {"path":"acme/embedder/main/model.safetensors","size":64648}
  modules.json                     HTTP 200 {"path":"acme/embedder/main/modules.json","size":277}
  README.md                        HTTP 200 {"path":"acme/embedder/main/README.md","size":196}
  sentence_bert_config.json        HTTP 200 {"path":"acme/embedder/main/sentence_bert_config.json","size":241}
  tokenizer_config.json            HTTP 200 {"path":"acme/embedder/main/tokenizer_config.json","size":350}
  tokenizer.json                   HTTP 200 {"path":"acme/embedder/main/tokenizer.json","size":4702}
```

A file, once published at a revision, cannot be replaced (409); publish a new revision instead.
Publishing needs write permission on the repository **and** the `write:artifacts` scope on the
token; a Remote refuses with 405 and a Virtual with 400 (gate G5). The upload is read into memory
whole before it is stored, which matters for multi-gigabyte weights
([#5291](https://github.com/artifact-keeper/artifact-keeper/issues/5291)).

## Use it

```console
== the developer uses it
{"ok":true,"commit":"1e18c1cf4ada0b55fdae41dc4eb9071a1dd51732","sha256":"d4ad5cc7ad6994408eb23c27b499ab6024f54ed4d10260ac8f02142a0fa923fd"}
{"ok": true, "cmd": "automodel", "endpoint": "https://ak.internal/huggingface/hf-local", "tokenizer": "BertTokenizer", "model": "BertModel", "hidden": [1, 4, 32], ...}
{"ok": true, "cmd": "encode", "endpoint": "https://ak.internal/huggingface/hf-local", "shape": [2, 32], "first": [-0.457369, 0.287261, -0.22734, -0.365521], ...}
```

`hf_hub_download`, `AutoModel.from_pretrained` and `SentenceTransformer` all work: they ask
for each file by name at `main`. The encoding is identical to the one from `hf-lab` in
[Step 2](2-proxy-the-hub.md), as it should be: same weights. A Local repository has no git
history, so the commit (`1e18c1cf...`) is derived from the model id and revision.

## snapshot_download (needs artifact-keeper#5300)

```console
-- snapshot_download (needs the hosted snapshot fix; see the findings):
{"ok":true,"commit":"1e18c1cf4ada0b55fdae41dc4eb9071a1dd51732","files":["1_Pooling/config.json","README.md","config.json","config_sentence_transformers.json","model.safetensors","modules.json","sentence_bert_config.json","tokenizer.json","tokenizer_config.json"],"error":null,"msg":null}
{"sha":"1e18c1cf4ada0b55fdae41dc4eb9071a1dd51732","siblings":["1_Pooling/config.json","README.md","config.json"]}
```

All nine files, including the one in `1_Pooling/`, and `siblings` are paths inside the
repository. This needs the backend from
[artifact-keeper#5300](https://github.com/artifact-keeper/artifact-keeper/pull/5300). On `:dev`
as it is today, the same call fails:

```text
{"ok":false,"commit":null,"files":null,"error":"KeyError","msg":"'id'"}
{"sha":"1e18c1cf4ada0b55fdae41dc4eb9071a1dd51732","siblings":["acme/embedder/main/1_Pooling/config.json","acme/embedder/main/README.md","acme/embedder/main/config.json"]}
```

The hosted model info there has no `id`, which `huggingface_hub` 2.x requires, its
`siblings` are stored paths, and the commit it reports cannot be used to list or download
files ([findings F1](findings.md#f1-snapshot_download-fails-against-a-local-repository),
[#5280](https://github.com/artifact-keeper/artifact-keeper/issues/5280)). Gate G5 reports the
check `BLOCKED(ak-fix)` on such an image. `hf download acme/embedder` behaves the same way.

## Through the Virtual

```console
== through the Virtual: hf_hub_download works, snapshot_download does not (documented)
{"ok":true,"commit":"1e18c1cf4ada0b55fdae41dc4eb9071a1dd51732"}
{"ok":true,"commit":"099a800f5a0de0c030245fa4c02996957602a81e"}
{"ok":false,"error":"LocalEntryNotFoundError","msg":"Got: HfHubHTTPError: Client error '404 Not Found' for url 'https://ak.internal/huggingface/hf-models/api/models/acme-lab/tiny-st/revision/main'"}
```

A Virtual routes `/resolve/` to the first member that has the file (`acme/embedder` from
`hf-local`, `acme-lab/tiny-st` from `hf-lab`), but answers model info and tree with 404, so
`snapshot_download` and `hf download` fail against it, as documented. Point those at a Local or
Remote repository. One trap: if the workstation's cache already holds a file of the model,
`huggingface_hub` falls back to the cache on the 404 and returns a "snapshot" of just that
file, without an error ([findings O3](findings.md#behaviour-worth-knowing)).
