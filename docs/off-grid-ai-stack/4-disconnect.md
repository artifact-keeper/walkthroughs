# Step 4: Disconnect

--8<-- "includes/preview-offgrid.md"

The cut is a handful of documented settings plus a network with no gateway. In this order:
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
re-evaluation, peer sync and the npm feed. A pass already running finishes, so the script then
waits until `mcp-official`'s last sync has finished (`GET .../mcp/sync`, `lastFinishedAt` at or
after `lastStartedAt`, up to 10 min).

Pausing comes first for a reason found in the debug run, which went cache-only first: a sync
that was running at the cut ended with an error (the Remote had just become cache-only, so the
next page was a cache miss) and wrote its `MCP_MIRROR_SYNCED` row in the same second as the
marks of step 4 below. Gate G7d then counted it as activity after the disconnect
([findings](findings.md#behaviour-worth-knowing)).

<!-- REFRESH: no output yet in the current order. The debug run printed, as its step 2:
  PATCH /api/v1/admin/settings/system: HTTP 200
{"upstream_jobs_paused":true,"upstream_jobs_paused_source":"database"}
Paste the final run's block, which adds the line "  mcp-official sync: {lastStartedAt, lastFinishedAt}". -->

```console
== 1. pause the scheduled upstream jobs, and let a running MCP sync finish
  PATCH /api/v1/admin/settings/system: HTTP 200
{"upstream_jobs_paused":true,"upstream_jobs_paused_source":"database"}
...
```

The backend logs the pause; gate G3 reads it back after the restart:

```text
2026-11-05T17:44:53.360810Z  WARN artifact_keeper: Scheduled upstream jobs are PAUSED (source: Database); skipped until the switch is off: curation_sync, environment_reeval, npm_upstream_feed, peer_sync, mcp_remote_sync ...
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

<!-- REFRESH: debug run, where this was step 1; same lines expected. -->

The Remotes keep their egress proxy, the ledger. Cache-only is the first barrier and the
network the second; the ledger is how both are watched.

## 3. The export, and what it leaves out

The configuration is exported again to `out/config/site.json`, the site's configuration as it
leaves the network:

```console
== 3. the configuration as it leaves the network
  14 repositories; the Remotes as exported:
{"key":"hf-hub","upstream_mode":null,"cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
{"key":"ledger-control","upstream_mode":null,"cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
{"key":"mcp-official","upstream_mode":null,"cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
{"key":"npm-remote","upstream_mode":null,"cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
{"key":"oci-dockerhub","upstream_mode":null,"cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
{"key":"oci-ghcr","upstream_mode":null,"cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
{"key":"plugins","upstream_mode":null,"cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
{"key":"pypi-remote","upstream_mode":null,"cache_ttl_seconds":315360000,"on_upstream_not_found":"keep","egress":"explicit"}
```

<!-- REFRESH: debug run (14 repositories including ledger-control from older code; 13 now). If the #5407 fix is in the final run's backend, upstream_mode reads "cache_only" here and the text below changes. -->

`upstream_mode` is `null` for every Remote: the export does not carry it
([artifact-keeper#5407](https://github.com/artifact-keeper/artifact-keeper/issues/5407)), so the
site's offline posture is not in its configuration of record, and an instance built from this
document would come up online. Gate G3 reports that check `BLOCKED(ak-gap)`. Until it is fixed,
set the upstream mode on a cloned instance by its own route, as this step does.

## 4. The marks

The zero-egress gates count from here. `out/disconnect.json` holds the time, the ledger's
count of `open` lines, and the number of `UPSTREAM_FETCHED` and `MCP_MIRROR_SYNCED` audit rows:

```console
== 4. the marks
{
  "at": "2026-11-05T17:44:23Z",
  "ledger_lines": 47,
  "upstream_fetched": 1024,
  "mcp_mirror_synced": 4
}
```

<!-- REFRESH: debug run; the counts drop once the seed uses #5408 instead of full syncs. -->

## 5. Move the stack to the site network

`registry/out/phase` becomes `site`, and from then on every compose command adds
[`compose.site.yml`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/registry/compose/compose.site.yml),
which replaces the default network with `ak-offgrid-site` (`internal: true`: podman gives it no
gateway and no NAT). The stack is taken down with its volumes kept and brought up again; the
ledger first, because it is not a compose service and compose cannot remove the seed network
while it is attached. The same database, artifact store and Caddy CA come back, so the
instance that seeded its caches is the one that serves them. Nothing is pulled
(`--pull never`): there is no route to pull from.

Why down and up, not a recreate in place: with podman, containers that compose recreates on a
new network lose their service-name DNS aliases, and the backend could not find `postgres`
(`Device or resource busy (os error 16)`). Created fresh, they keep them.

```console
== 5. move the stack to ak-offgrid-site (internal: no gateway)
 Container ak-offgrid-caddy Stopping
 ...
 Network ak-offgrid-seed Removing
 Network ak-offgrid-seed Removed
up.sh: phase=site network=ak-offgrid-site backend=localhost/ak-backend:offgrid-0bffa44c web=ghcr.io/artifact-keeper/artifact-keeper-web:dev@sha256:7a0ec1f45d4eb59ff617a69e80e7622c85cc3b36679a594b8c2a33fb4fe79146 scanner-adapter=localhost/ak-scanner-adapter:offgrid-0bffa44c
 Network ak-offgrid-site Creating
 ...
 Container ak-offgrid-caddy Started
up.sh: waiting for Caddy's internal CA  /.../off-grid-ai-stack/registry/out/ak-internal-ca.crt (subject=CN=Caddy Local Authority - 2026 ECC Root)
up.sh: waiting for https://ak.internal:30450/readyz . ready
{"status":"healthy","version":"1.11.3"}
backend image 403e088c9006642e462c417927b37607d23c93ef72d772091bba2ab462e24b17
ledger: http://172.31.85.200:3128 (alias egress-ledger) on ak-offgrid-site; 90 lines in out/ledger/ledger.jsonl
  ak-offgrid-scanner-adapter   ak-offgrid-site
  ak-offgrid-opensearch        ak-offgrid-site
  ak-offgrid-db                ak-offgrid-site
  ak-offgrid-backend           ak-offgrid-site
  ak-offgrid-web               ak-offgrid-site
  ak-offgrid-caddy             ak-offgrid-site
  ak-offgrid-ledger            ak-offgrid-site
```

<!-- REFRESH: debug run; same shape expected. Timing: the debug run's marks were at 17:44:23 and the backend's restart log line at 17:44:53, so the move took about 30 s; measure make disconnect end to end in the final run. -->

The ledger's own line count (90) counts both `open` and `close` lines; the marks count `open`
lines only (47). Every container is on `ak-offgrid-site` and nothing else. The host port
`127.0.0.1:30450` still reaches Caddy: it is the site's LAN, inbound only.

After this step the only way in is that port, and the only way out would be through a route the
site network does not have. [Step 7](7-prove-nothing-leaves.md) checks both.
