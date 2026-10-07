# Reference: Artifact Keeper API calls used

Base `https://ak.internal`. Verified on backend `main` (5e351fc). `Authorization: Bearer <token>`
unless noted.

## Conda channel

| Call | Notes |
|---|---|
| `GET /conda/{repo}/{subdir}/repodata.json` (`.zst`, `.bz2`) | hosted, remote and virtual |
| `GET /conda/{repo}/{subdir}/repodata_shards.msgpack.zst`, `.../shards/{hash}` | CEP-16, hosted only |
| `GET /conda/{repo}/{subdir}/{file}` | download |
| `PUT /conda/{repo}/{subdir}/{file}` | upload, body = package; 201, 409 if it exists (what `rattler-build upload artifactory` sends) |
| `POST /conda/{repo}/upload` | raw body + `X-Package-Filename`; optional `X-Conda-Subdir` |
| `PUT /conda/{repo}/{subdir}/{file}/attestation` | CEP-27 Sigstore bundle (JSON); `write:artifacts` |
| `GET /conda/{repo}/{subdir}/{file}/attestation` | stored bundle |
| `DELETE /conda/{repo}/{subdir}/{file}` | withdraw (CEP-6) |
| `GET /conda/{repo}/notices.json`, `channeldata.json` | |
| `GET /conda/t/{token}/{repo}/...` | token-in-URL form (Artifact Keeper layout) |

## Repositories and tokens

| Call | Body |
|---|---|
| `POST /api/v1/repositories` | `{"key","name","format":"conda","repo_type":"local\|remote\|virtual\|staging","visibility":"public\|internal\|private","upstream_url","promotion_only","member_repos":[{"repo_key","priority"}]}` |
| `PATCH /api/v1/repositories/{key}` | e.g. `{"promotion_only":false}` |
| `PUT /api/v1/repositories/{key}/cache-ttl` | `{"cache_ttl_seconds": 300}` (remote) |
| `PUT /api/v1/repositories/{key}/security` | `{"scan_enabled":true,"scan_on_upload":true}` |
| `GET /api/v1/repositories/{key}/artifacts?per_page=N` | rows with `id`, `path`, `quarantine_status`, `last_promotion` |
| `DELETE /api/v1/repositories/{key}/artifacts/{path}` | |
| `POST /api/v1/repositories/{key}/tokens` | `{"name","scopes":["read:artifacts","write:artifacts"],"expires_in_days"}`; scoped to that one repository |
| `POST /api/v1/auth/tokens` | the caller's own token; `repo_selector: {"match_repos":[uuid...]}` narrows it to several repositories |
| `POST /api/v1/auth/login` | `{"username","password"}`; 10 per username and IP per 15 min (shared with `/v2/token`) |
| `PUT /api/v1/repositories/{key}/artifacts/{path}` | generic repositories (the `trust` repo); read anonymously at `GET /api/v1/repositories/{key}/download/{path}` |

## Release gate

| Call | Body |
|---|---|
| `POST /api/v1/security/policies` | `{"name","repository_id":<staging repo id>,"max_severity":"high","block_unscanned":true,"block_on_fail":true,"predicates":{"conda":{"min_attestation_state":"verified","denied_licenses":[...],"denied_license_families":[...],"block_install_scripts":true}}}` |
| `PUT /api/v1/promotion/repositories/{staging}/release-target` | `{"release_repository_key":"conda-internal"}` |
| `POST /api/v1/promotion/repositories/{staging}/artifacts/{id}/promote` | `{"target_repository":"conda-internal","skip_policy_check":false,"notes"}` -> `{"promoted", "policy_violations":[{"rule","severity","message"}]}` |
| `POST /api/v1/security/scan` | `{"artifact_id"}` |
| `GET /api/v1/security/artifacts/{id}/scans` | per scanner status and counts |

## SBOM and environments

| Call | Notes |
|---|---|
| `POST /api/v1/sbom/environment?filename=pixi.lock[&format=spdx]` | body = lockfile; CycloneDX per (environment, platform), nothing stored |
| `POST /api/v1/repositories/{key}/environments?filename=pixi.lock&name=N` | store the graph; re-ingest replaces |
| `GET /api/v1/environments/lookup?purl=pkg:conda/openssl@3.6.4` | environments containing it, with inclusion paths |
| `GET /api/v1/admin/downloads` | download records (hosted downloads only on main) |

## OCI

Pull and push at `/v2/{repo}/{image}`, e.g. `ak.internal/oci-ghcr/prefix-dev/pixi:0.81.0` through a
`docker` remote repository with upstream `https://ghcr.io`. Token exchange at `/v2/token`.
