# Step 4: Disconnect

--8<-- "includes/preview-offgrid.md"

!!! tip "If something goes wrong"
    See [Troubleshooting](reference/troubleshooting.md): every failure we hit while building
    this walkthrough, with its cause and fix.

The cut is a handful of documented settings plus a network with no route out. In this order:
the scheduled upstream jobs pause, every Remote goes cache-only, the configuration is exported
again, the counters the zero-egress gates start from are written down, and every container of
the stack is recreated on `ak-offgrid-site`.

```bash
make disconnect    # flows/disconnect.sh
```

[`flows/disconnect.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/flows/disconnect.sh)
does nothing if the stack is already on the site network. [`make reconnect`](reference/make-targets.md)
undoes it.

## 1. Pause the scheduled upstream jobs

```bash
PATCH /api/v1/admin/settings/system {"upstream_jobs_paused": true}
```

The switch ([#5317](https://github.com/artifact-keeper/artifact-keeper/pull/5317)) stops the
jobs that reach upstream on a schedule: the MCP Remote sync, curation sync, the advisory
re-evaluation, peer sync and the npm feed. While it is on, a manual MCP sync and a targeted MCP
seed are refused with `409` too ([Step 8](8-prove-it-fails-safely.md#mcp-not-approved-not-seeded-not-synced)).
A pass already running finishes, so the script then waits until `mcp-official`'s last sync has
finished (`GET .../mcp/sync`, `lastFinishedAt` at or after `lastStartedAt`, up to 10 min). Here
it never ran one: `mcp-official` was created with its sync paused.

```console
$ make disconnect
flows/disconnect.sh

== 1. pause the scheduled upstream jobs, and let a running MCP sync finish
  PATCH /api/v1/admin/settings/system: HTTP 200
{"upstream_jobs_paused":true,"upstream_jobs_paused_source":"database"}
  mcp-official sync: {"lastStartedAt":null,"lastFinishedAt":null}
```

Pausing comes before cache-only for a reason found in a debug run: there a sync that was
running at the cut ended with an error and wrote its `MCP_MIRROR_SYNCED` row in the same second
as the marks of part 4, and gate G7d counted it as activity after the disconnect
([findings](findings.md#what-the-plan-got-wrong)).

The backend logs the pause when it starts on the site; gate G3 reads it back:

```text
2026-11-06T05:13:35.618838Z  WARN artifact_keeper: Scheduled upstream jobs are PAUSED (source: Database); skipped until the switch is off: curation_sync, environment_reeval, npm_upstream_feed, peer_sync, mcp_remote_sync ...
```

## 2. Every Remote cache-only

```bash
PUT /api/v1/repositories/<remote>/upstream-mode {"upstream_mode": "cache_only"}
```

A cache-only Remote ([#5315](https://github.com/artifact-keeper/artifact-keeper/pull/5315))
serves what it has cached and never asks upstream. A miss is a clean `404` straight away, with
no upstream attempt for a client to wait on or retry
([Step 8](8-prove-it-fails-safely.md)).

```console
== 2. every Remote to cache-only
  oci-dockerhub  HTTP 200 {"upstream_mode":"cache_only","effective_upstream_mode":"cache_only"}
  oci-ghcr       HTTP 200 {"upstream_mode":"cache_only","effective_upstream_mode":"cache_only"}
  pypi-remote    HTTP 200 {"upstream_mode":"cache_only","effective_upstream_mode":"cache_only"}
  npm-remote     HTTP 200 {"upstream_mode":"cache_only","effective_upstream_mode":"cache_only"}
  hf-hub         HTTP 200 {"upstream_mode":"cache_only","effective_upstream_mode":"cache_only"}
  mcp-official   HTTP 200 {"upstream_mode":"cache_only","effective_upstream_mode":"cache_only"}
  plugins        HTTP 200 {"upstream_mode":"cache_only","effective_upstream_mode":"cache_only"}
```

The Remotes keep their egress proxy, the ledger. Cache-only is the first barrier and the
network the second; the ledger is how both are watched.

## 3. The export, with the offline posture

The configuration is exported again to `out/config/site.json`, the site's configuration as it
leaves the network:

```console
== 3. the configuration as it leaves the network
  13 repositories; the Remotes as exported:
{"key":"hf-hub","upstream_mode":"cache_only","cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
{"key":"mcp-official","upstream_mode":"cache_only","cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
{"key":"npm-remote","upstream_mode":"cache_only","cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
{"key":"oci-dockerhub","upstream_mode":"cache_only","cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
{"key":"oci-ghcr","upstream_mode":"cache_only","cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
{"key":"plugins","upstream_mode":"cache_only","cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
{"key":"pypi-remote","upstream_mode":"cache_only","cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
```

Every Remote is exported as `cache_only`, so an instance built from this document comes up
offline too. Before [#5415](https://github.com/artifact-keeper/artifact-keeper/pull/5415)
(`main` at `d9a417c8`) the export left `upstream_mode` out
([#5407](https://github.com/artifact-keeper/artifact-keeper/issues/5407),
[findings F4](findings.md#f4-config-export-did-not-carry-the-upstream-mode)); gate G3 checks
that it is there.

## 4. The marks

The zero-egress gates count from here. `out/disconnect.json` holds the time, the ledger's
count of `open` lines, and the number of `UPSTREAM_FETCHED` and `MCP_MIRROR_SYNCED` audit rows:

```console
== 4. the marks
{
  "at": "2026-11-06T05:13:07Z",
  "ledger_lines": 24,
  "upstream_fetched": 283,
  "mcp_mirror_synced": 0
}
```

Everything the site will ever have came over 24 connections and 283 upstream requests, and no
MCP sync ran at all. The request count is stable between runs; the connection count is not
(21 to 24 in our runs: connections are reused depending on timing), which is why the gates
compare connections only before and after the cut, never against a fixed number.

## 5. Move the stack to the site network

`registry/out/phase` becomes `site`, and from then on every compose command adds
[`compose.site.yml`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/registry/compose/compose.site.yml),
which replaces the default network with `ak-offgrid-site` (`internal: true`: no default route and no NAT; `podman network inspect` still lists the
subnet's `.1` as its gateway, but on an internal network that address is aardvark-dns only). The stack is taken down with its volumes kept and brought up again; the
ledger first, because it is not a compose service and compose cannot remove the seed network
while it is attached. The same database, artifact store and Caddy CA come back, so the
instance that seeded its caches is the one that serves them. Nothing is pulled
(`--pull never`): there is no route to pull from.

Why down and up, not a recreate in place: with podman, containers that compose recreates on a
new network lose their service-name DNS aliases, and the backend could not find `postgres`
(`Device or resource busy (os error 16)`). Created fresh, they keep them.

```console
== 5. move the stack to ak-offgrid-site (internal: no default route, no NAT (.1 is DNS only))
 Container ak-offgrid-caddy Stopping
 ...
 Network ak-offgrid-seed Removing
 Network ak-offgrid-seed Removed
up.sh: phase=site network=ak-offgrid-site backend=ghcr.io/artifact-keeper/artifact-keeper-backend:dev@sha256:1314a083... web=ghcr.io/artifact-keeper/artifact-keeper-web:dev@sha256:e05124d4... scanner-adapter=ghcr.io/artifact-keeper/artifact-keeper-scanner-adapter:dev@sha256:d44dacfa...
 Network ak-offgrid-site Creating
 ...
 Container ak-offgrid-caddy Started
up.sh: waiting for Caddy's internal CA  /.../off-grid-ai-stack/registry/out/ak-internal-ca.crt (subject=CN=Caddy Local Authority - 2026 ECC Root)
up.sh: waiting for https://ak.internal:30450/readyz . ready
{"status":"healthy","version":"1.11.3"}
backend image c3c71ef94e712b2b47f2609601485b7ef21c22cd41d9c8fc7c8e86c44c2cf6c1
ledger: http://172.31.85.200:3128 (alias egress-ledger) on ak-offgrid-site; 45 lines in out/ledger/ledger.jsonl
  ak-offgrid-scanner-adapter   ak-offgrid-site
  ak-offgrid-opensearch        ak-offgrid-site
  ak-offgrid-db                ak-offgrid-site
  ak-offgrid-backend           ak-offgrid-site
  ak-offgrid-web               ak-offgrid-site
  ak-offgrid-caddy             ak-offgrid-site
  ak-offgrid-ledger            ak-offgrid-site
```

The marks were written at 05:13:07 and the backend logged the pause from the site network at
05:13:35, so the move took about 30 s. The ledger's own line count (45) counts both `open` and
`close` lines; the marks count `open` lines only (24). Every container is on `ak-offgrid-site`
and nothing else. The host port `127.0.0.1:30450` still reaches Caddy: it is the site's LAN,
inbound only.

After this step the only way in is that port, and the only way out would be through a route the
site network does not have. [Step 7](7-prove-nothing-leaves.md) checks both.
