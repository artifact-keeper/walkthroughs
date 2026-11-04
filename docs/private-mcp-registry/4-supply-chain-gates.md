# Step 4: Supply-chain gates

--8<-- "includes/preview-mcp.md"

A registry entry is a recipe: run this package, with these arguments, at this address. This
step shows the checks Artifact Keeper puts between a recipe and a client: where the packages
may come from, what exactly they are, whether they are still trusted, and what the entry
itself says.

```bash
make supply-chain
```

Every call is in
[`flows/supply-chain.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/flows/supply-chain.sh),
made with the `ci` token against `mcp-internal` unless noted.

## Packages must come from this registry

With the `own-repos` package policy, a package from anywhere else is refused, with a reason
that names the fix:

```console
-- npm package from registry.npmjs.org:
HTTP 422
{"detail":"packages[0]: registryBaseUrl must be omitted or be this registry's npm repository (https://ak.internal/npm/npm-internal); publish the package to it first","error":"mcp_external_registry",...}
-- image on Docker Hub:
HTTP 422
{"detail":"packages[0]: image host 'docker.io' is not this registry; name the image as ak.internal/oci-internal/<image>:<tag>","error":"mcp_external_registry",...}
-- image with a floating tag:
HTTP 422
{"detail":"packages[0].identifier: name a specific tag or digest; `latest` and tagless image references are not accepted (AK pins the digest at publish)","error":"mcp_oci_floating_tag",...}
-- image tag that was never pushed:
HTTP 422
{"detail":"packages[0]: image ak.internal/oci-internal/acme/tickets-mcp:9.9.9 is not in repository 'oci-internal'","error":"mcp_package_not_found",...}
```

The publish never contacts the package's registry: it looks the package up in Artifact
Keeper's database. An npm package without a `version` is refused too
(`mcp_package_version_unpinned`, gate G2).

## An image tag is pinned to its digest

At publish, `ak.internal/oci-internal/acme/tickets-mcp:1.0.0` was resolved to its digest, and
that is what every client is handed. Re-push the tag with other content and nothing served
changes; the move is recorded:

```console
served before: ak.internal/oci-internal/acme/tickets-mcp:1.0.0@sha256:25f85fd5e77bab8a3e5b72ba1f25d3d907060608fd9b7ddb077beb1cccaa752d
$ skopeo copy ... oci-archive:/out/images/tickets-mcp-1.0.0-moved.tar docker://ak.internal/oci-internal/acme/tickets-mcp:1.0.0
the tag now names: sha256:067d46462fd7cad601df6b0943699a20ad106e3cbedf87821becf80e221b07a7
served after:  ak.internal/oci-internal/acme/tickets-mcp:1.0.0@sha256:25f85fd5e77bab8a3e5b72ba1f25d3d907060608fd9b7ddb077beb1cccaa752d
{"action":"MCP_PIN_DRIFT_DETECTED","details":{"mcp_server":"com.acme/tickets","mcp_version":"1.0.0","name":"acme/tickets-mcp","tag":"1.0.0",
 "observed_digest":"sha256:067d4646...","pinned_digest":"sha256:25f85fd5...",...}}
```

To ship the new image, publish a new server version. The pinned manifest cannot be deleted by
digest while a server version pins it, not even by an admin, so the reviewed bytes stay
available:

```console
$ DELETE /v2/oci-internal/acme/tickets-mcp/manifests/sha256:25f85fd5...     (admin token)
HTTP 405
{"errors":[{"code":"UNSUPPORTED","message":"this manifest is pinned by a published MCP server version and cannot be deleted by digest; delete the tag instead, or remove the server version first"}]}
```

## A held package hides the server that runs it

Every read evaluates the gates of the packages a version pins: quarantine, scan policy, the age
gate of a Remote. Quarantine the npm tarball of `@acme/tickets-mcp@1.0.0` (say, during an
incident) and `com.acme/tickets` 1.0.0 leaves the listing and its exact read is `404`:

```console
$ POST /api/v1/quarantine/<artifact id of tickets-mcp-1.0.0.tgz>/quarantine {"reason":"incident 4711: suspected tampering"}
{"new_status":"quarantined","message":"Artifact quarantined"}
$ GET /mcp/mcp-internal/v0.1/servers?search=tickets       (developer)
[]
$ GET /mcp/mcp-internal/v0.1/servers/com.acme%2Ftickets/versions/1.0.0
HTTP 404
{"detail":"A package this server version runs is held pending review","error":"mcp_backing_artifact_blocked",
 "gate":"quarantine","hold":"backing","package":"npm:@acme/tickets-mcp@1.0.0",...}
$ npm pack --registry https://ak.internal/npm/npm/ @acme/tickets-mcp@1.0.0
npm error code E409
```

The npm client is refused the tarball as well, so a developer who already has the install
command cannot fetch it either. Releasing the quarantine restores the version on the next read.
A package refused by a scan policy holds the server the same way (`gate: scan_policy`).

## The lint

Every server version is linted: offline, deterministic, no model. Rules with action `block`
refuse the publish; rules with action `review` are stored as findings that a scan policy can
hold on.

**A hardcoded secret is refused.** The script generates a fake GitHub token for the run (none
is committed) and puts it in a remote's header:

```console
HTTP 422
{"error":"mcp_lint_blocked","findings":[{"action":"block","rule":"secret_literal","path":"remotes[0].headers[0].value",
 "message":"contains what looks like a GitHub token; reference a secret input (`isSecret: true`) instead of publishing the value"}]}
```

The refusal never repeats the value (gate G2 checks).

**A tool description that reads as a prompt injection is held.** Version 1.0.2 declares a tool
whose description tells the model to read `~/.ssh/id_rsa` and not tell the user. The lint
rule `injection_phrase` has action `review`, never `block`: the publish is accepted, the
finding is stored with severity `high`, and the `mcp-internal-review` scan policy
(`max_severity: high`, [Step 1](1-stand-up-the-registry.md)) holds the version:

```console
publish: HTTP 200
$ GET /mcp/mcp-internal/v0.1/servers/com.acme%2Ftickets/versions/1.0.2     (developer)
HTTP 404
{"detail":"This server version is refused by the repository's security policy","error":"mcp_rejected","hold":"scan_policy",...}
latest is still 1.0.0
$ GET /api/v1/repositories/mcp-internal/mcp/servers/com.acme/tickets/versions/1.0.2/health
{"status":"warning","lint":{"block":0,"review":1,"findings":[{"rule":"injection_phrase","action":"review","severity":"high",
 "path":"_meta.io.modelcontextprotocol.registry/publisher-provided.com.artifactkeeper/capabilities.tools[0].description"}]}}
$ GET /mcp/mcp-internal/v0.1/x/com.artifactkeeper/holds
{"name":"com.acme/tickets","version":"1.0.2","hold":"scan_policy","error":"mcp_rejected"}
```

Acknowledging the finding (`POST /api/v1/security/findings/{id}/acknowledge`) would release
it; here nobody does. The server page's Security tab shows the hold and the finding:

![The Security tab of com.acme/tickets 1.0.2: held, refused by security policy, with the injection_phrase lint finding on the tool description](images/u04-held-version-security.png)

Other rules: `hidden_text` (invisible or bidirectional characters, `block`), `dangerous_args`
(`--registry` in runtime arguments, `--privileged`, the Docker socket), `remote_url_shape`,
`destructive_tool`, `shell_like_tool_name`, `secret_unmarked`, and checks of the image label
against the server name. The list is in Artifact Keeper's `docs/mcp-registry.md`.

## Lookalike names

Typosquats are caught where they come from, the public registry: the sync in
[Step 3](3-curate-the-public-registry.md) put `io.github.examp1e/weather` and the genuine
`io.github.example/weather` in `review`, flagged as lookalikes of each other, before anyone
could approve either. On the hosted registry, `mcp_namespace_allow: ["com.acme"]` keeps every
name in Acme's namespace, and [Step 6](6-one-url-for-clients.md) shows that an upstream server
can never take an internal name.

Next: [Step 5, publish from CI](5-publish-from-ci.md).
