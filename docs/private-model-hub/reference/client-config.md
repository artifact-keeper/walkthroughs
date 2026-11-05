# Client configuration

--8<-- "includes/preview-hf.md"

Everything a workstation needs to use the hub, and where `huggingface_hub` keeps what it
downloads.

## Variables

| Variable | Value | Notes |
|---|---|---|
| `HF_ENDPOINT` | `https://ak.internal/huggingface/<repo>` | The repository key is part of the endpoint. No trailing slash. One endpoint per repository: there is no single URL for every repository (a Virtual comes closest, with the limits in [Step 5](../5-host-your-own-models.md)). |
| `HF_TOKEN` | an Artifact Keeper API token | `read:artifacts` to download. Never a Hugging Face token: Artifact Keeper refuses it (401) and does not forward it. |
| `SSL_CERT_FILE` | the system bundle with the internal CA | `huggingface_hub` 2.x uses `httpx2`, which honours it. |
| `HF_HUB_OFFLINE` | `1` | Load from the local cache only, no requests. The workaround for loading a model on a disconnected network ([Step 7](../7-freeze-and-go-offline.md)). |
| `HF_HUB_DISABLE_TELEMETRY` | `1` | Set in the workstation image. |
| `HF_HUB_DISABLE_XET` | `1` | Not needed here: Artifact Keeper strips the Xet metadata, so clients never try Xet ([Step 8](../8-prove-it-fails-safely.md)). Set it if a client still asks for `xet-read-token`. |

Two things to remove from a workstation before pointing it at the hub: a token in
`~/.cache/huggingface/token` (from an earlier `hf auth login`), which `huggingface_hub` sends
when `HF_TOKEN` is unset and which Artifact Keeper refuses with 401; and `HF_HUB_ENABLE_HF_TRANSFER`
(each of its parallel ranges is served by re-reading the cached file from byte 0; not
machine-verified here).

## Examples

```bash
export HF_ENDPOINT=https://ak.internal/huggingface/hf-hub
export HF_TOKEN=$(cat developer.token)          # an Artifact Keeper token, read:artifacts
hf download sentence-transformers/all-MiniLM-L6-v2 config.json modules.json
python -c 'from sentence_transformers import SentenceTransformer as S; print(S("sentence-transformers/all-MiniLM-L6-v2").encode(["hi"]).shape)'
```

Publishing to a Local repository is Artifact Keeper's own route, one file per request (the
Hub's commit API, which `upload_file` and `upload_folder` use, is not implemented):

```bash
curl -X POST -H "Authorization: Bearer $PUBLISHER_TOKEN" -H "X-Filename: 1_Pooling/config.json" \
  --data-binary @1_Pooling/config.json \
  https://ak.internal/huggingface/hf-local/api/models/acme/embedder/upload/main
```

## The cache on disk

`~/.cache/huggingface/hub/models--<org>--<name>/`:

| Path | What |
|---|---|
| `refs/main` | the commit `main` resolved to: the `sha` of model info, which is `X-Repo-Commit` |
| `snapshots/<commit>/<file>` | symlinks into `blobs/` |
| `blobs/<etag>` | the file, named after its ETag (the git blob sha1 for small files, the sha256 for large ones) |
| `.no_exist/<commit>/<file>` | a file the server answered 404 for |

Through a Remote, `<commit>` is the upstream commit (`1110a243...` for all-MiniLM-L6-v2 on
2026-11-04). Through a Local repository it is a value derived from the model id and revision.
