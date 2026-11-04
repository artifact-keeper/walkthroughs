# Reference: Artifact Keeper API used

Base `https://ak.internal`. Verified on the backend build `sha-c3a650e` (Artifact Keeper
main at commit `c3a650e`; the format ships in 1.12.0). `Authorization: Bearer <token>` unless
noted. The protocol reference upstream is
[`docs/agent-plugins.md`](https://github.com/artifact-keeper/artifact-keeper/blob/main/docs/agent-plugins.md).

## Agent Plugins routes

| Call | Notes |
|---|---|
| `PUT /agentplugins/{repo}/{name}/{version}/{name}-{version}.zip` | Raw zip body. `write:artifacts`. Optional `X-Checksum-Sha256`. `201` with `name`, `version`, `sha256`, `size_bytes`, `harnesses`, `marketplace_name`, `download_url`, `marketplaces`; `409` if the version exists or was deleted and the bytes differ; `400` for each publish rule ([Step 3](../3-publish.md)) |
| `GET`, `HEAD /agentplugins/{repo}/{name}/{version}/{name}-{version}.zip` | The zip, streamed by Artifact Keeper (never a redirect). `X-Checksum-Sha256`, `ETag: "<sha256>"`. `403` while the scan policy holds the version, `404` after a delete |
| `GET /agentplugins/{repo}/marketplace.json` | Every plugin at its newest servable version; Artifact Keeper's data under each entry's `metadata` |
| `GET /agentplugins/{repo}/claude-marketplace.json` | Plugins tagged `claude` or `standard`; what Claude Code reads |
| `GET /agentplugins/{repo}/cursor-marketplace.json` | `cursor` or `standard` |
| `GET /agentplugins/{repo}/codex-marketplace.json` | `codex` or `standard` |
| `GET /agentplugins/{repo}/vscode-marketplace.json` | `standard` |
| `GET /agentplugins/{repo}/{name}/index.json` | Every servable version, newest first, with `latest`; what `ak` reads. `404` when there is none |
| `GET /agentplugins/t/{token}/{repo}/...` | All the read routes with the token in the path. `Cache-Control: private, no-store`, `Referrer-Policy: no-referrer`; generated URLs keep the prefix |

Documents carry an `ETag` and answer `If-None-Match` with `304`; plain routes send
`Cache-Control: no-cache`.

## Repositories, users and tokens

| Call | Body |
|---|---|
| `POST /api/v1/repositories` | `{"key","name","description","format":"agentplugins","repo_type":"local","visibility":"private\|public"}`; `remote` and `virtual` are refused (`400`) |
| `PUT /api/v1/repositories/{key}/security` | `{"scan_enabled":true,"scan_on_upload":true}` |
| `POST /api/v1/security/policies` | `{"name","repository_id","max_severity":"high","block_unscanned":true,"block_on_fail":true}` |
| `POST /api/v1/security/scan` | `{"artifact_id"}`: scan one version now |
| `GET /api/v1/security/artifacts/{id}/scans` | the scans of one version, with status and finding counts |
| `POST /api/v1/users` | `{"username","email","password","display_name","is_admin":false}` |
| `POST /api/v1/permissions` | `{"principal_type":"user","principal_id","target_type":"repository","target_id","actions":["read"]}` |
| `POST /api/v1/repositories/{key}/tokens` | `{"name","scopes":["read:artifacts"(,"write:artifacts")],"expires_in_days"}`: a token for that one repository. A non-admin can mint only what it holds itself |
| `POST /api/v1/auth/login`, `POST /api/v1/auth/tokens` | the admin's API token for the scripts |
| `GET /api/v1/repositories/{key}/artifacts?per_page=N` | rows with `id` and `path` (the version's artifact id) |
| `DELETE /api/v1/repositories/{key}/artifacts/{name}/{version}/{name}-{version}.zip` | remove a version; every document drops it on the next request |
| `PUT /api/v1/repositories/{key}/artifacts/{path}` | generic upload: stored, but never indexed or served by `/agentplugins` (gate G9) |

## Audit

| Call | Notes |
|---|---|
| `GET /api/v1/admin/audit?resource_id={artifact_id}` | audit events for one version (also `user_id`, `action`, `from`, `to`) |
| `GET /api/v1/admin/downloads?artifact_id={id}` | download records: user, client address, user agent, time (also `repository_id`, `user_id`) |
