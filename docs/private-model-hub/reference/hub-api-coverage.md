# Hub API coverage

--8<-- "includes/preview-hf.md"

What `huggingface_hub` 2.4.0 asks for, and what Artifact Keeper answered in this lab (backend
`main` at `46070a04`). "Remote" is `hf-lab` or `hf-hub`, "Local" is `hf-local`, "Virtual" is
`hf-models`. All routes are under `/huggingface/<repo>`.

| Client call | Request | Remote | Local | Virtual |
|---|---|---|---|---|
| `model_info`, first call of `snapshot_download` and `hf download` | `GET api/models/<id>/revision/<rev>` | Proxied; `xetHash`, `xetEnabled` stripped | 200, but no `id` key: `huggingface_hub` raises `KeyError: 'id'` (#5280) | 404 (documented) |
| `list_repo_tree(recursive=True)`, second call of `snapshot_download` | `GET api/models/<id>/tree/<commit>?recursive=true` | Proxied without the query: top level only, so files in subdirectories are left out | `[]` for the commit `model_info` reported (#5280) | 200 `[]` |
| `hf_hub_download` metadata | `HEAD <id>/resolve/<rev>/<file>` | 200 with `ETag`, `X-Repo-Commit`; no `X-Linked-Etag`/`X-Linked-Size` (redirects are followed) | 200 with `ETag` (sha256) and a derived `X-Repo-Commit` | 200 |
| `hf_hub_download` | `GET <id>/resolve/<rev>/<file>` | 200; cached | 200 at a branch name; 404 at the commit `model_info` reports | 200 (first member that has it) |
| resume | `GET ... Range: bytes=N-` | 206 | 206 | 206 |
| Xet | `GET api/models/<id>/xet-read-token/<rev>` | 404 (never proxied) | 404 | 404 |
| `list_models` | `GET api/models` | `[]` (no search of the Hub) | the models held (`lastModified` is the revision name) | `[]` |
| `upload_file`, `upload_folder`, `create_commit` | `POST api/models/<id>/preupload/...`, `.../commit/...` | 404 | 404 (use `POST api/models/<id>/upload/<rev>` with `X-Filename`) | 404 |
| datasets, spaces | `api/datasets/...`, `api/spaces/...` | 404 | 404 | 404 |
| `whoami` | `GET api/whoami-v2` | 404 | 404 | 404 |

Status codes a client sees:

| Situation | Answer |
|---|---|
| No token, private repository | 401 |
| A Hugging Face `hf_...` token | 401 |
| Signed in, no read permission on the repository | 404 (not 403) |
| Upstream refuses (a gated model without upstream auth) | 502 |
| Refused by the upstream filter | 404 "Artifact not found upstream", no upstream request |
| Upstream unreachable, path not cached | 502 after the connection attempt |
| Held (quarantine) | 409 |
| Rejected, or refused by a scan policy (`block_unscanned`, severity) | 403 |
| `..` in the model id, revision or file | 400 |
| Re-publishing a file at the same revision | 409 |
| Publishing to a Remote / a Virtual | 405 / 400 |
| Publishing without `write:artifacts` or without write permission | 403 |
