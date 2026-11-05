# Reference: registry API used

--8<-- "includes/preview-mcp.md"

Every call the walkthrough makes, as it made them. The full contract is Artifact Keeper's
[`docs/mcp-registry.md`](https://github.com/artifact-keeper/artifact-keeper/blob/feat/mcp-registry-phase1/docs/mcp-registry.md)
on the pull request branch. Base URL: `https://ak.internal`. `{name}` is a server name, URL
encoded (`com.acme%2Ftickets`) or with a literal slash.

## The registry surface (`/mcp/<repo>/v0.1`, also `/v0`)

What clients and `mcp-publisher` use. Refusals are `application/problem+json` with an `error`
member and `Cache-Control: no-store`.

| Call | Used for | Answers seen |
|---|---|---|
| `GET /servers?limit=&cursor=&search=&version=latest` | listings (VS Code's gallery) | `200 {servers: [{server, _meta}], metadata: {count, nextCursor?}}`; `401` anonymous on a private registry |
| `GET /servers/{name}/versions` | every servable version | `200`; plain `404` when none |
| `GET /servers/{name}/versions/{version\|latest}` | one version (VS Code, `latest`) | `200`; `404` (plain for an unknown or unapproved name, with a reason for a holder of a held version) |
| `POST /validate` | dry run before a publish | `200 {valid, issues, packages: [{index, registryType, outcome: pinned\|fill\|unchecked}]}`; `401` anonymous on a private registry |
| `POST /publish` | `mcp-publisher publish`, curl | `200`; `202 resolving`; `403 mcp_forbidden`, `mcp_namespace_not_allowed`, `mcp_namespace_not_granted`; `409 mcp_version_exists`; `422 mcp_external_registry`, `mcp_package_not_found`, `mcp_oci_floating_tag`, `mcp_package_version_unpinned`, `mcp_lint_blocked`; `405 mcp_read_only` on a Remote or Virtual |
| `POST /v0/auth/github-oidc` `{oidc_token}` | `mcp-publisher login github-oidc` | `200 {registry_token, expires_at}`; `401 mcp_unauthorized` |
| `PUT /servers/{name}/versions/{v}/bundles/{file}.mcpb` | bundle upload | `201 {file, fileSha256, signature, packageEntry, ...}`; `422 mcp_bundle_unsigned`, `mcp_bundle_signer_untrusted`, `mcp_bundle_signature_invalid` |
| `GET .../bundles/{file}.mcpb?ticket=` | bundle download without a credential | `200 application/zip`, `X-Checksum-Sha256`; `401` for a used ticket |
| `GET\|POST .../versions/{v}/capabilities`, `GET .../capabilities/diff` | tool snapshots and diffs | `200`, `201 {snapshot, previousSnapshotId, drift}` |
| `GET /x/com.artifactkeeper/holds` | why versions are held (holders only) | `200 {holds: [{name, version, hold, error, ...}]}` |
| `OPTIONS /servers` | Copilot's CORS check | `200`, `access-control-allow-origin: *`, methods `GET,OPTIONS`, headers `authorization,content-type` |

## Management API (`/api/v1`)

| Call | Used for |
|---|---|
| `POST /repositories`, `PATCH /repositories/{key}` | repositories with `mcp_*` settings (`mcp_package_policy`, `mcp_package_repos`, `mcp_namespace_allow`, `mcp_auto_approve_namespaces`, `mcp_server_deny`, `mcp_require_namespace_grant`, `mcp_require_bundle_signature`) |
| `PUT /repositories/{key}/members` | Virtual members and priorities |
| `POST /repositories/mcp-upstream/mcp/sync` | one sync pass: `{repository, summary}` |
| `GET /repositories/mcp-upstream/mcp/catalog[?queue=true&status=]`, `GET .../catalog/servers/{name}` | the approval queue |
| `POST .../catalog/{id}/approve\|block`, `POST .../catalog/pins`, `POST .../catalog/bulk-approve` | decisions (repository admin, scope `write:repositories`) |
| `POST .../catalog/{id}/request-approval` | a reader asks for a server |
| `GET /mcp/pending-summary` | the queue across every Remote |
| `GET /repositories/mcp-internal/mcp/servers/{name}/versions/{v}/health` | a version's package gates and lint findings |
| `POST /quarantine/{artifact id}/quarantine\|release` | holding a backing package |
| `POST /admin/ci-oidc`, `POST /admin/ci-oidc/{id}/mappings` | GitHub Actions OIDC trust |
| `POST /permissions` with `conditions.mcp_namespaces` | namespace grants |
| `GET /admin/audit` | `MCP_*` audit events |
| `GET /packages?format=mcp` | one row per server, for the UI |
