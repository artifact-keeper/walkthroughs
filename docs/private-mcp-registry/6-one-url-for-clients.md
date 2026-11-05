# Step 6: One URL for clients

--8<-- "includes/preview-mcp.md"

Clients take one registry URL. A Virtual `mcp` repository gives them one that serves both the
internal servers and the approved public ones, and it settles the question a merge raises:
what if both sides have the same name?

```bash
make virtual
```

[`flows/virtual.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-mcp-registry/flows/virtual.sh)
runs every call on this page.

## A name collision, on purpose

The lab registry has `com.acme/tickets` 9.9.9, published upstream by someone outside Acme,
pointing at their own server. The script approves it on `mcp-upstream`, as a curator might by
mistake. The Remote then serves it:

```console
$ POST .../catalog/<id of com.acme/tickets>/approve
{"name":"com.acme/tickets","status":"approved"}
$ GET /mcp/mcp-upstream/v0.1/servers/com.acme%2Ftickets/versions/latest
{"from":"mcp-upstream","version":"9.9.9","url":"https://tickets.squatter.example/mcp"}
```

## The Virtual

```json
POST /api/v1/repositories
{"key": "mcp", "format": "mcp", "repo_type": "virtual", "visibility": "private"}
PUT /api/v1/repositories/mcp/members
{"members": [{"member_key": "mcp-internal", "priority": 1}, {"member_key": "mcp-upstream", "priority": 2}]}
```

A Virtual resolves nothing itself: every version it serves is a member's, decided by that
member's own gates. Hosted members come first, then Remote ones. And **a hosted name always
shadows a Remote one**: when a hosted member has any version of a name, the name is never
served from a Remote member.

```console
$ GET /mcp/mcp/v0.1/servers?version=latest
{"name":"com.acme/status","version":"2.0.0","member":"mcp-internal"}
{"name":"com.acme/tickets","version":"1.0.0","member":"mcp-internal"}
{"name":"io.github.acme-labs/notes","version":"1.0.0","member":"mcp-upstream"}
{"name":"io.github.drifty/clock","version":"1.0.0","member":"mcp-upstream"}
{"name":"io.github.example/weather","version":"1.2.0","member":"mcp-upstream"}
{"name":"io.github.github/github-mcp-server","version":"2.1.0","member":"mcp-upstream"}
$ GET /mcp/mcp/v0.1/servers/com.acme%2Ftickets/versions
["1.0.0"]
$ GET /mcp/mcp/v0.1/servers/com.acme%2Ftickets/versions/9.9.9
HTTP 404
{"detail":"Server not found","status":404,"title":"Not Found","type":"about:blank"}
```

9.9.9 is a higher version than anything internal, which is exactly how dependency confusion
works in package managers. Here it does not matter: the name belongs to the hosted member.
Each entry's `_meta["com.artifactkeeper.registry/source"]` names the member it came from and
adds `virtualRepository: "mcp"`.

The rule has a known cost that Artifact Keeper documents: a reader of the Virtual can tell that
some hosted member holds a name (the Remote's version disappears through the Virtual). Keep
names that must not be inferable out of a Virtual that also merges a Remote carrying them.

Paging works across members (a cursor walk at `limit=3` visited all 6 entries once), and
writes go to a member, not the Virtual:

```console
$ POST /mcp/mcp/v0.1/publish     (admin)
HTTP 405
{"detail":"This repository does not accept writes (virtual repository); publish to one of its hosted members","error":"mcp_read_only",...}
```

## Clients use one URL

Point VS Code, Copilot and the web UI's install instructions at `https://ak.internal/mcp/mcp`.
The same requests as in [Step 2](2-a-private-registry.md), against the Virtual:

```console
$ GET /mcp/mcp/v0.1/servers
{"name":"com.acme/status","version":"2.0.0","isLatest":true}
{"name":"com.acme/tickets","version":"1.0.0","isLatest":true}
{"name":"io.github.acme-labs/notes","version":"1.0.0","isLatest":true}
{"name":"io.github.drifty/clock","version":"1.0.0","isLatest":true}
{"name":"io.github.example/weather","version":"1.2.0","isLatest":true}
{"name":"io.github.github/github-mcp-server","version":"2.1.0","isLatest":true}
```

```json title="settings.json (VS Code)"
{ "chat.mcp.gallery.serviceUrl": "https://ak.internal/mcp/mcp" }
```

Next: [Step 7, bundles and capabilities](7-bundles-and-capabilities.md).
