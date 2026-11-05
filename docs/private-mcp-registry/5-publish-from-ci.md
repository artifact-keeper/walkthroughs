# Step 5: Publish from CI

--8<-- "includes/preview-mcp.md"

The `ci` token from [Step 1](1-stand-up-the-registry.md) is a stored secret with write access
to the whole registry. This step replaces it with what GitHub Actions already gives every job:
a short-lived OIDC ID token. `mcp-publisher login github-oidc` exchanges it for a registry
token, and a **namespace grant** limits what that token may publish to the job's own
namespace.

```bash
make ci
```

!!! note "What is real and what stands in"
    Everything on the Artifact Keeper side is real: the CI OIDC provider, the mapping, the
    exchange, the namespace gate, `mcp-publisher` 1.8.7. GitHub is not: the lab has no runner
    that can reach `ak.internal`. The workstation gets the environment a job with
    `permissions: id-token: write` gets (`ACTIONS_ID_TOKEN_REQUEST_URL` and
    `ACTIONS_ID_TOKEN_REQUEST_TOKEN`), served by a stand-in endpoint, and the ID token is
    signed by a lab key ([`ci/lab-issuer.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/ci/lab-issuer.sh))
    with GitHub's issuer, audience and claims. Artifact Keeper trusts that key because the
    provider stores its public key (`key_source: static`). The workflow it stands in for is
    [`ci/publish-mcp.yml`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/ci/publish-mcp.yml),
    **not machine-verified**.

## Trust GitHub Actions

An administrator registers the issuer once
([`flows/ci.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/flows/ci.sh)):

```json
POST /api/v1/admin/ci-oidc
{"name": "github-actions", "provider_type": "github",
 "issuer_url": "https://token.actions.githubusercontent.com",
 "audience": "https://ak.internal",
 "key_source": "static", "static_jwks": {"keys": [...]}, "token_ttl_secs": 900}
```

The audience is the registry URL's scheme and host: that is what `mcp-publisher` asks GitHub
for. Against real GitHub, leave out `key_source` and `static_jwks`: Artifact Keeper finds the
keys through the issuer's discovery document.

A **mapping** says which jobs are accepted: here, any workflow of the `acme` organization on
`refs/heads/main`. Each mapping has one account, created with it:

```console
$ POST /api/v1/admin/ci-oidc/<provider>/mappings {"name":"acme-mcp-publish","claim_filters":{"repository_owner":"acme","ref":"refs/heads/main"}}
{"name":"acme-mcp-publish","claim_filters":{"ref":"refs/heads/main","repository_owner":"acme"},
 "service_account_id":"ff96fc43-d168-4f2d-bfee-c27c1844665e","service_account_username":"ci-aa34b433f4a0"}
```

## A grant for one namespace

The mapping's account gets `write` on `mcp-internal`, but only for names that match
`com.{repository_owner}/*`, where `{repository_owner}` is the claim from the job's ID token. A
pattern with a claim must name the issuer the claim may come from, so a GitLab group with the
same name can never satisfy it:

```console
-- without the issuer binding:
HTTP 400
{"code":"VALIDATION_ERROR","message":"conditions.mcp_namespaces interpolates CI claims: name the issuer they must come from in conditions.mcp_namespace_issuer (e.g. https://token.actions.githubusercontent.com)"}
-- with it:
HTTP 200
{"principal_type":"user","principal_name":"ci-aa34b433f4a0","target_name":"Acme internal MCP servers","actions":["write"],
 "conditions":{"mcp_namespace_issuer":"https://token.actions.githubusercontent.com","mcp_namespaces":["com.{repository_owner}/*"]}}
```

`principal_type` is `user`: the mapping's account is not a service account in the permission
model, and Artifact Keeper's docs say otherwise
([lab notes, D1](findings.md#d1-the-namespace-grant-example-uses-a-principal-type-that-is-refused)).
The grant counts only for MCP writes; it gives the account nothing on the generic API.

## Four job runs

Each run writes a `server.json` for `com.acme/status` (a remote-only server, so the job needs
no package), logs in and publishes:

```console
== Job 1: acme/tickets-mcp on main publishes com.acme/status 2.0.0
$ mcp-publisher login github-oidc --registry https://ak.internal/mcp/mcp-internal
Logging in with github-oidc...
token endpoint: GET /token?api-version=2.0&audience=https%3A%2F%2Fak.internal
✓ Successfully logged in
$ mcp-publisher publish   # com.acme/status@2.0.0
Publishing com.acme/status@2.0.0 to https://ak.internal/mcp/mcp-internal...
✓ Successfully published
✓ Server com.acme/status version 2.0.0

== Job 2: the same job tries com.acme.payments/ledger 1.0.0 (outside com.acme/*)
✓ Successfully logged in
Error: publish failed: server returned status 403: {"detail":"this credential holds no grant for namespace 'com.acme.payments' in this repository","error":"mcp_namespace_not_granted",...}

== Job 3: a workflow in another organization (repository_owner=evil)
Error: failed to get token: failed to exchange OIDC token: token exchange failed with status 401: {"detail":"Token exchange failed: the OIDC token was not accepted by this instance's CI OIDC configuration","error":"mcp_unauthorized",...}

== Job 4: acme's workflow on a feature branch (ref=refs/heads/feature)
Error: failed to get token: failed to exchange OIDC token: token exchange failed with status 401: ...
```

The publish is recorded as the mapping's account, which names the provider and mapping:

```text
MCP_SERVER_PUBLISHED   actor ci-aa34b433f4a0   com.acme/status 2.0.0
MCP_NAMESPACE_GRANTED  actor admin             patterns ["com.{repository_owner}/*"]
```

## Make the grant required

Until now, repository `write` alone (the `ci` user) still publishes anything under `com.acme`.
Setting `mcp_require_namespace_grant: true` on `mcp-internal` makes a namespace grant the only
way in, apart from instance administrators. Gate G7 turns it on, shows the `ci` user refused
(`403 mcp_namespace_not_granted`) while the OIDC account still publishes, and turns it off
again so the rest of the walkthrough can run. In production, turn it on once every publisher
has a grant.

A job that also publishes packages needs `write` on `npm-internal` and `oci-internal`: give the
mapping a group (`group_binding_ids`) with those permissions, and use the same exchanged token
for `npm publish` and the image push.

Next: [Step 6, one URL for clients](6-one-url-for-clients.md).
