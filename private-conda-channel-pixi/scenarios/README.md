# Scenarios spike: an enterprise artifact manager in front of Artifact Keeper

Spike notes, 2026-10-08. The question: can Sonatype Nexus Repository (the free edition) and
Inedo ProGet Free sit in front of the Artifact Keeper conda virtual channel as "the enterprise
artifact manager", with current pixi as the client? These are facts from one afternoon on the
walkthrough stack, not polished docs. They decide how the scenario compose profiles get built.

Short answer: Nexus can, with caveats. ProGet could not be tested at all: it refuses to serve
anything until a licence key is entered, and getting a Free key means registering a name and an
e-mail address with Inedo.

## What ran

| Piece | Version |
|---|---|
| Nexus | `docker.io/sonatype/nexus3:3.96.4`, server header `Nexus/3.96.4-01 (COMMUNITY)` (Community Edition, the free successor of Nexus OSS) |
| ProGet | `proget.inedo.com/productimages/inedo/proget:26.0.12` (ProGet 26.0.12.24) |
| Artifact Keeper | `localhost/ak-backend:allowlist-1.11` (compose project `ak-conda`) |
| pixi | 0.81.0 (`localhost/ak-conda/pixi-client:0.81.0`) |

Files in this directory:

| File | What |
|---|---|
| `compose.nexus.yml`, `nexus/up.sh` | Nexus on `ak-conda-net` as `scn-nexus` (host port 127.0.0.1:30481), compose project `ak-scn-nexus` |
| `nexus/bootstrap.sh` | Configures everything through the REST API: admin password, EULA, anonymous read, truststore, SSRF allow list, seven conda repositories. Idempotent. Upstream auth is basic `consumer:<token>`; `UPSTREAM_AUTH=bearer` shows the bearer failure (see 3). |
| `nexus/pixi-config.toml` | pixi config with Nexus as the only conda source (mirrors) |
| `nexus/pixi-config-merged.toml` | pixi config for a client that uses a Nexus group as its channel (base_url workaround, see 5) |
| `compose.proget.yml`, `proget/up.sh` | ProGet on `ak-conda-net` as `scn-proget` (host port 127.0.0.1:30482), compose project `ak-scn-proget` |
| `proget/bootstrap.sh`, `proget/pixi-config.toml` | Written from the docs and the pgutil source. **Not run past the licence check.** |
| `pixi-through.sh` | Runs pixi in the walkthrough's client image with a product's config as `/etc/pixi/config.toml` |
| `measure.sh` | Runs a command, then counts what the product served and what `ak.internal` served (Caddy log), by status and bytes |
| `fake-forge.sh` | `scn-fake-forge`: a static conda channel we control, for the merge precedence test |
| `outage.sh` | The two outage drills (`backend`, `forge`); restores everything, also on error (trap) |

Secrets: the scenario admin password is generated into `scenarios/.env` (gitignored). The
upstream credential is the walkthrough's consumer token (`registry/.tokens/consumer.token`).
`registry/.env` is only read.

Run it:

```console
scenarios/nexus/up.sh
scenarios/nexus/bootstrap.sh
scenarios/pixi-through.sh nexus <project-dir> install --locked
scenarios/outage.sh backend nexus     # stops ak-conda-backend for 60 s
scenarios/outage.sh forge nexus       # points AK's conda-forge remote at conda-forge.invalid, restores it
```

## Capability table

"AK" below means the Artifact Keeper virtual channel `https://ak.internal/conda/conda-virtual`
as the upstream.

| | Nexus CE 3.96.4 | ProGet Free 26.0.12 |
|---|---|---|
| Runs rootless with podman compose | yes, 1 container, embedded H2; 23-27 s to writable | yes, 1 container, embedded PostgreSQL 17; UI up in 7 s, then blocked on the licence |
| Licence key for the free edition | no; you accept the EULA (API) | **yes**, issued by Inedo against a name and e-mail address |
| Conda proxy (remote) | yes (tested) | docs: yes ("connectors"). Not established: unlicensed |
| Conda hosted | yes since 3.92 (tested: `PUT` of a `.conda` file, repodata generated) | docs: yes. Not established |
| Conda group / merge | yes since 3.92 (tested) | docs: a feed can have several connectors. Not established |
| `repodata.json` | yes | not established |
| `repodata.json.zst` | **no**: 404 from Nexus itself, never asked upstream (proxy, hosted and group) | not established |
| `repodata.json.bz2` | yes (proxy passes AK's through; the group compresses its merge itself, 52 s for linux-64) | not established |
| `repodata_shards.msgpack.zst` (CEP-16) | **no**: 404 from Nexus, never asked upstream | not established |
| `channeldata.json` | yes (proxy and group) | not established |
| `current_repodata.json` | no: 404, never asked upstream | not established |
| Conditional GET to upstream | yes: `If-None-Match` + `If-Modified-Since` after `metadataMaxAge`; AK answers 304 for repodata | not established |
| Conditional GET from clients | yes: 304 on `If-None-Match` and `If-Modified-Since` | not established |
| Auth to upstream with bearer token | **no**: `bearerToken` is accepted by the API and stored, but never sent (AK logged no `Authorization` header, 401, then auto-block) | docs: connectors have `Username`/`Password` only; no bearer field |
| Auth to upstream with basic (`consumer:<token>`) | yes; after a 401 challenge on every request (2 upstream requests per fetch) | docs: yes. Not established |
| Merge precedence | union of records; on a file name collision the **repodata record comes from the last member, the file bytes from the first** (hash mismatch at install); otherwise the solver picks the highest version across members | not established |
| Serves from cache when AK is down | yes: metadata and packages, also after a cache invalidation; never-cached files are 404 "Remote Auto Blocked" | docs: package caching in all editions; **metadata caching only in paid editions** |
| Serves from cache when AK's conda-forge egress is blocked | yes (AK itself keeps serving its cached repodata and packages; only never-cached files fail) | not established |

## Nexus Repository Community Edition 3.96.4

### 1. Running it

- `compose.nexus.yml`: one container, named volume `scn-nexus-data`, network `ak-conda-net`
  (external), healthcheck on `/service/rest/v1/status`. Runs as uid 200 inside the container;
  rootless podman needs nothing else.
- No database container: Community Edition uses embedded H2. PostgreSQL is supported in CE as an
  external database (Sonatype's CE onboarding page) but was not tried.
- No licence key. The CE EULA must be accepted before repositories serve anything; `bootstrap.sh`
  does it with `GET` then `POST /service/rest/v1/system/eula` (`accepted: true`).
- First start to `/service/rest/v1/status/writable` = 200: **27 s** (compose up included); a
  restart with data: 23 s.
- Memory: the image default is a 2.7 GB heap. Proxying alone was fine with a 2 GB heap. A conda
  **group** over AK's linux-64 index (458 MB of JSON) with a 2 GB heap died:

  ```text
  ERROR [qtp1314150413-86] *SYSTEM org.sonatype.nexus.internal.web.ErrorPageServlet - Unexpected exception
  java.lang.OutOfMemoryError: Java heap space
      at com.fasterxml.jackson.databind.node.TextNode.valueOf(TextNode.java:44)
  ERROR [nexus_QuartzSchedulerThread] ... The database has been closed [90098-240]
  ```

  The OOM also closed the embedded H2 database; every request was 500 until the container was
  recreated. With `-Xmx8g` (now the fragment default, `NEXUS_HEAP`) the merge worked and the
  container sat at 6-8.4 GB RSS while merging, 3 GB idle.
- Free-edition limits (Sonatype "Usage Center" and CE onboarding pages): 40,000 total components
  or 100,000 requests per day. Above either, "users are not able to add new components until the
  deployment returns to being under both of these limits". Every proxied package is a component
  and every client request counts; one `pixi install --locked` of `project/` is about 45 requests.
  The usage metrics endpoints exist (`/v1/usage-history?metric=requests&period=daily`) and showed
  0 during the spike (Sonatype says they update hourly).
- SSRF protection is on by default in 3.96: creating a proxy for `https://ak.internal/...` failed
  with `Proxy URL blocked: Host resolves to private/local IP address(es): 172.31.40.177 (private
  network address)`. `bootstrap.sh` adds `ak.internal` and `scn-fake-forge` to
  `PUT /v1/security/ssrf-protection` `allowedDomains`; the guard stays on otherwise.
- TLS: the internal CA goes into Nexus's own truststore (`POST /v1/security/ssl/truststore`, PEM
  body) and the proxy sets `useTrustStore: true`. Nexus refuses `useTrustStore` on an `http://`
  remote (`"TrustStore is available only with HTTPS remote URLs"`).

### 2. Conda support

Docs (help.sonatype.com "Conda Repositories"): proxy; hosted and group "available from version
3.92"; `.conda` and `.tar.bz2`; "Supports token-based remote connections through the proxy
repository URL" (conda's `/t/<token>/` URL form). REST API: `/v1/repositories/conda/{proxy,hosted,group}`.

Tried:

- proxy: `ak-virtual`, `ak-internal` (AK), `cf-direct` (conda.anaconda.org/conda-forge),
  `scn-fake` (our static channel). All work for `repodata.json`, `.bz2`, `channeldata.json` and
  package files.
- hosted `nx-hosted`: `curl -X PUT --upload-file acme-core-99.0.0-pyh4616a5c_0.conda
  .../repository/nx-hosted/noarch/acme-core-99.0.0-pyh4616a5c_0.conda` gives 201 and the record
  appears in `noarch/repodata.json` (and `.bz2`, `channeldata.json`). The components API
  (`POST /v1/components?repository=nx-hosted`, `conda.asset`) wants version, build and arch fields
  and returned 400 without them. The test package was deleted again.
- group `merged` = [ak-virtual, cf-direct], `merged-fake` = [ak-virtual, scn-fake]: see 5.

### 3. Proxy of `https://ak.internal/conda/conda-virtual`

Upstream auth:

- `httpClient.authentication = {type: "bearerToken", bearerToken: <consumer token>}`: accepted,
  stored (`authentication={bearerTokenId=**REDACTED**, type=bearerToken}` in the log), **never
  sent**. AK's Caddy log shows the request with no `Authorization` header and a 401, although AK
  offers `WWW-Authenticate: Bearer realm="artifact-keeper"`. Nexus then auto-blocks the remote:
  `Repository status for ak-virtual changed from READY to AUTO_BLOCKED_UNAVAILABLE ... reason
  Unauthorized for https://ak.internal`.
- `{type: "username", username: "consumer", password: <consumer token>}`: works. Nexus is not
  pre-emptive: every upstream fetch is a 401 then a 200 (the Caddy counts below show both).
- Not tried: the token in the remote URL (`https://ak.internal/conda/t/<token>/conda-virtual`,
  which AK accepts: 200). It would put the token in the repository config in clear.

What passes through (`curl` through `http://127.0.0.1:30481/repository/ak-virtual`, cold then
warm, after the basic-auth switch):

```text
cold noarch/repodata.json                 200 192535646   3.00s
cold linux-64/repodata.json               200 458611334   8.16s
cold linux-64/repodata.json.zst           404      1357   0.10s
cold linux-64/repodata.json.bz2           200  61468235  25.98s
cold linux-64/repodata_shards.msgpack.zst 404      1357   0.02s
cold channeldata.json                     200  23658734   0.49s
cold noarch/current_repodata.json         404      1357   0.01s
warm noarch/repodata.json                 200 192535646   0.17s
warm linux-64/repodata.json               200 458611334   0.42s
warm linux-64/repodata.json.bz2           200  61468235   0.06s
warm channeldata.json                     200  23658734   0.03s
```

AK was asked only for `repodata.json`, `repodata.json.bz2` and `channeldata.json`. The `.zst`,
shard and `current_repodata.json` 404s come from Nexus itself; the requests never reach AK. So
the shard index question ("AK answers 404 today, what does the product do") is moot for Nexus: it
never forwards it.

- No compression to clients: `linux-64/repodata.json` goes out as 458,611,334 bytes even with
  `Accept-Encoding: gzip, br, zstd`. pixi does not fetch it: after `.zst` 404 it uses `.bz2`.
- The ETag passes through (`ETag: "6e571bd9..."`, the same as AK's); Nexus adds its own
  `Last-Modified` (fetch time). Client conditional requests get 304.
- Conditional GET upstream: tested with a throwaway proxy (`metadataMaxAge` 1 min). 70 s later
  Nexus revalidated with both headers and AK answered 304:

  ```text
  GET /conda/conda-virtual/noarch/repodata.json 401 "2000e344..." Thu, 08 Oct 2026 19:24:46 GMT
  GET /conda/conda-virtual/noarch/repodata.json 304 "2000e344..." Thu, 08 Oct 2026 19:24:46 GMT
  ```

  For package files Nexus also sends `If-None-Match`, but AK answers 200 with the full body
  even when the ETag matches (seen for all 43 packages after a cache invalidation: 101.2 MB
  again). That is an Artifact Keeper behaviour, to file upstream.
- Caching: the REST API has no defaults (the fields are required). `bootstrap.sh` sets
  `metadataMaxAge` 1440 min (repodata, channeldata), `contentMaxAge` 1440 min (packages) and the
  negative cache 1440 min (404s). Metadata is revalidated after `metadataMaxAge`; content after
  `contentMaxAge`. `POST /v1/repositories/{name}/invalidate-cache` makes both stale at once.
- The 450 MB indexes: no problem with `timeout: 600`. conda-forge's own `linux-64/repodata.json`
  (453,992,678 bytes) through `cf-direct` cold: 12.3 s. Nexus fetches the uncompressed JSON (it
  does not know `.zst`).
- Nexus passes AK's `info.base_url` through unchanged (see 5): harmless with mirrors, breaks
  clients that use the Nexus URL as the channel.

### 4. pixi through Nexus

Client: the walkthrough image with `nexus/pixi-config.toml` (mirrors for `conda-virtual`,
`conda-internal` and conda-forge to Nexus; PyPI still goes to `ak.internal`). The lockfile is
unchanged: it keeps the `https://ak.internal/...` URLs, and the mirrors redirect every conda
request to Nexus. A copy of `project/` lives in `.work/project`.

| Run (`measure.sh`) | Result | Through Nexus | From AK |
|---|---|---|---|
| `install --locked`, cold client cache, Nexus empty | ok, 2 s | 43 packages, 200 | Nexus: 43 x 401 + 43 x 200, 101.2 MB |
| `install --locked`, cold client cache, Nexus warm | ok, 1 s | 43 x 200, 101.2 MB | Nexus: nothing |
| `lock` (fresh solve), cold client cache, Nexus metadata cold | ok, 26 s | 8 x 200 (repodata `.bz2` 61.5 + 29.2 MB), 10 x 404 (`.zst`, shards, `notices.json`) | Nexus: 6 x 200, 29.2 MB |
| `lock`, cold client cache, Nexus warm (conda-only manifest) | ok, 10 s | 8 x 200, 90.7 MB | nothing |
| same solve straight to AK (no Nexus) | ok, 29 s | | pixi: 13 x 200, 109.2 MB |

Each install also fetched the one PyPI wheel (`humanize`) from `ak.internal` directly.

Allowlist (`make allowlist`, 43 entries), then `pixi add --no-install colorama` through Nexus:

- **With Nexus's cached repodata (fetched before the allowlist), it succeeds**: `Added colorama
  >=0.4.6,<0.5`, and the lock gets `colorama-0.4.6-pyhd8ed1ab_1.conda`. Nexus never asked AK
  (metadata younger than `metadataMaxAge`, 24 h). The allowlist reaches Nexus clients only when
  Nexus revalidates.
- After `invalidate-cache` on `ak-virtual` and `ak-internal`: fails the same way as straight
  to AK:

  ```text
  Error:   × failed to solve requirements of environment 'default' for platform 'linux-64'
    ├─▶   × failed to solve the environment
    ╰─▶ Cannot solve the request because of: No candidates were found for colorama *.
  ```

- Download through Nexus of `noarch/colorama-0.4.6-pyhd8ed1ab_1.conda`: **404**, an HTML page
  (1,357 bytes, `<title>404 - Sonatype Nexus Repository</title>`, "Not Found"). AK itself
  answers 404 `{"code":"NOT_FOUND","message":"Artifact not found in any member repository"}`.
  Nexus does not pass AK's body through.
- **A package Nexus already cached is not revoked.** After `make allowlist-off`, one download of
  colorama through Nexus cached it. With the allowlist on again and the cache invalidated, Nexus
  revalidated (`If-None-Match`), AK answered 404, and Nexus kept serving its copy with 200.
- `make allowlist-off` was run after each test; the virtual is back to `enabled=false entries=43`.

### 5. Merged in the artifact manager

Yes, a Nexus conda group merges sources. Group `merged` = [ak-virtual, cf-direct] serves
`noarch/repodata.json` (190,285,884 bytes), `linux-64/repodata.json` (453,993,249 bytes, 9.3 s
from warm members), `linux-64/repodata.json.bz2` (61,178,440 bytes, **51.8 s**: the group
compresses its merge itself) and `channeldata.json`. No `.zst`, no shards.

Precedence, tested with `merged-fake` = [ak-virtual, scn-fake]. `scn-fake-forge` serves
`acme-core-99.0.0-pyh4616a5c_0.conda` (the squatted name, higher version) and a different file
under the same name as our internal package, `acme-core-1.0.0-pyh4616a5c_0.conda` (sha256
`9ac9a20f...`; ours is `eb370de6...`).

- Different file names: the group lists both sides. `acme-core` versions in the merged noarch
  repodata: 1.0.0, 1.0.1, 1.0.1791387539, 1.0.1791387567, 1.0.1791483478 (ours) and 99.0.0
  (scn-fake). An unpinned `pixi lock` with only the group as the channel locked
  `acme-core-99.0.0-pyh4616a5c_0.conda`. The group has no name-ownership guard; the highest
  version wins, whatever the member order.
- Same file name: the merged repodata carries the record of the **last** member (scn-fake's
  sha256), the file download comes from the **first** member (our bytes). Swapping the order
  (temporary group [scn-fake, ak-virtual]) swaps both: the record is then ours and the bytes are
  scn-fake's. Either way, the client fails:

  ```text
  Error:   × failed to fetch acme-core-1.0.0-pyh4616a5c_0.conda
    ├─▶ failed to interact with the package cache layer.
    ╰─▶ hash mismatch when extracting http://scn-nexus:8081/conda/
        conda-virtual/noarch/acme-core-1.0.0-pyh4616a5c_0.conda to /
        cache/rattler/pkgs/.acme-core-1.0.0-pyh4616a5c_05DsI4V: expected
        9ac9a20fc882a5e2aba658c90b42d9626cb4713cb18ffef1c5534dcb7272ebda, got
        eb370de69a7640c3c722884801b5ee9a997ce8d39133d23b4807a74ddec13edc, total
        size 8563 bytes
  ```

- The group defeats the AK allowlist. With the allowlist on (and caches invalidated):
  `ak-virtual` lists 0 colorama records, `merged` lists 8; `noarch/toolz-1.2.0-pyh5ded981_0.conda`
  (never cached) is 404 through `ak-virtual` and 200 through `merged`.
- `info.base_url`: AK's repodata says `"base_url": "/conda/conda-virtual/<subdir>/"`, a
  host-relative path. Nexus passes it through, also in the group's merge (the first member's
  `info` wins). A client whose channel is `http://scn-nexus:8081/repository/merged-fake` resolves
  package URLs to `http://scn-nexus:8081/conda/conda-virtual/...` and gets 404:

  ```text
  ╰─▶ HTTP status client error (404 Not Found) for url (http://scn-nexus:8081/
      conda/conda-virtual/linux-64/libgcc-16.2.0-ha9f2e26_7.conda)
  ```

  `nexus/pixi-config-merged.toml` works around it with a mirror from
  `http://scn-nexus:8081/conda/conda-virtual` back to the group. The proxy-with-mirrors setup in
  4 is not affected: there the channel URL is the canonical `https://ak.internal/conda/conda-virtual`.
  Whether AK should send a relative `base_url` at all is a question for Artifact Keeper.
- Nexus logged `Conda group safety net enabled with 10.0% sampling rate` on the first group
  request; it did not catch the collision above.

So "merged in the artifact manager" works with Nexus, but the merge is a union with
highest-version-wins and no ownership rule, and file-name collisions break installs.

### 6. Outage

`outage.sh backend nexus` (log in `.work/runs/outage-backend.log`). Warm-up first (a solve and
an install through Nexus), then `compose stop backend` with the registry's helper; AK answers
502 to direct requests. All client runs used a cold client cache.

| Check, backend stopped | Result |
|---|---|
| 1. `install --locked`, conda-only copy of `project/` | **ok**, 7 s, 43 packages from Nexus's cache (Nexus tried AK 86 times, 502, and served its copies) |
| 2. `install --locked`, `project/` as is | conda part ok; fails on the PyPI wheel, which comes from AK directly: `Request failed after 3 retries in 20.1s` / `HTTP status server error (502 Bad Gateway) for url (https://ak.internal/pypi/pypi-remote/simple/humanize/humanize-4.16.0-py3-none-any.whl)` |
| 3. fresh solve (`lock`), Nexus metadata fresh | **ok**, 10 s |
| 4. fresh solve after `invalidate-cache` (metadata stale) | **ok**, 12 s: Nexus served its stale repodata after AK 502s |
| 5. a package Nexus never cached | 404 in 3 ms, body `Remote Auto Blocked until 2026-10-08T19:44:33.989Z` |

Nexus auto-blocks the remote for 40 s after failures and unblocks itself when AK answers
(`AUTO_BLOCKED_UNAVAILABLE` to `AVAILABLE` in the log). The backend was stopped for 63 s,
started with `compose start backend`, healthy again, and `repodata.json` through AK was 200.
(A first run of the drill kept it stopped 90 s; the checks then used the full manifest and failed
on PyPI, which is why the solves now use the conda-only manifest.)

`outage.sh forge nexus` (`.work/runs/outage-forge.log`): AK's `conda-forge` remote
`upstream_url` was PATCHed from `https://conda.anaconda.org/conda-forge` to
`https://conda-forge.invalid/conda-forge` and back (trap). During the block AK itself kept
answering 200 for the virtual's repodata from its own cache, so Nexus saw no failure: all four
client checks passed (install 2 s; solves 33 s and 32 s with Nexus revalidating and getting
304s). Only a package nobody had cached failed: AK 404, Nexus 404 (HTML page). The restored
value was read back: `https://conda.anaconda.org/conda-forge`.

### 7. Other things a reader would trip on

- Bearer to upstream is silently ignored for conda (3); use basic with the token as password.
- Every upstream request costs two round trips (401 challenge, then credentials).
- No `.zst`, no shards, no `current_repodata.json`: pixi falls back to `.bz2` cleanly; the
  bz2 decode is part of the solve time.
- The SSRF guard, the truststore and the EULA each block the first proxy creation in a fresh
  instance until handled (all three by API in `bootstrap.sh`).
- Heap: groups over conda-forge-sized indexes need a big heap, and an OOM takes the embedded H2
  down with it.
- Default caching (24 h) delays allowlist changes by up to a day, and cached packages are not
  revoked at all.
- The 404 for a blocked package is Nexus's HTML error page, not AK's message.

## Inedo ProGet Free 26.0.12

### 1. Running it

- `compose.proget.yml`: one container. ProGet 2025 and later ships an **embedded PostgreSQL**
  (confirmed: the container runs `/usr/lib/postgresql/17/bin/postgres -D /var/proget/database`;
  log `Initializing embedded database... Embedded database is online.`). The docs also offer
  external PostgreSQL (`PROGET_POSTGRES_CONNECTION_STRING`) and SQL Server
  (`PROGET_SQL_CONNECTION_STRING`). Volumes: packages, database, backups. The container runs as
  root inside the user namespace; rootless podman is fine.
- The internal CA: ProGet is .NET on Ubuntu 24.04 and uses the OpenSSL bundle. `up.sh` writes
  the image's bundle plus our CA to `.work/proget-ca-bundle.crt` and mounts it over
  `/etc/ssl/certs/ca-certificates.crt`. (`SSL_CERT_FILE` is taken: in this image it configures
  ProGet's own HTTPS listener.) Not exercised, since no connector could be created.
- First run: UI answers 200 after **7 s**, memory about 200 MB. Then nothing works:
  `/health` is HTTP 500 `ERROR: Product license is not valid`, every other page and API call
  (`/conda/...`, `/api/management/feeds/list`) is `302 Location: /administration/licensing`.
- **A licence key is required, also for Free.** The UI offers "Request a License Key" (ProGet
  Free or a 30-day Basic trial), which sends an e-mail address and a full name to Inedo; or
  my.inedo.com. The spike did not register with anyone's identity, so everything after this
  point is from the documentation and is marked not established.

### 2-6. What the documentation says (not tried)

- Conda feeds (docs.inedo.com, Conda): hosted ("A Conda feed in ProGet acts as a private Conda
  package repository"), `.tar.bz2` and `.conda`, feed URL `http://<server>/conda/<feed>`.
  Proxying is done with connectors; a feed can have several connectors plus its own packages,
  which is the merge. Nothing in the docs on `.zst`, shards, `channeldata.json`, conditional
  requests or merge precedence.
- Connector auth: the connector object (pgutil `ProGetConnector.cs`) has `Username` and
  `Password` only, no bearer token field. Basic with `consumer:<token>` would be the way.
- **Metadata caching is only available in paid editions** ("Metadata caching is only available
  in paid ProGet editions"). Package caching is in all editions. So with AK down, ProGet Free
  would serve cached packages but has no cached repodata to solve against; `install --locked`
  might work, a fresh solve would not. Not established.
- Free-edition restrictions that matter here (docs "License Restrictions" and "Connectors"):
  - "ProGet Free can only connect to public repositories (e.g. nuget.org,
    registry.npmjs.org)". A private, authenticated Artifact Keeper is arguably not a public
    repository. The licence page itself only forbids connectors to and from other ProGet
    instances. Ask Inedo before showing ProGet Free in front of AK.
  - "Connector filters can be configured in ProGet Free, but are ignored."
  - No feed-level security, no personal API keys, "limited to UI-based security
    configuration", "limited to 10/deletes per hour when using the API".
- An Inedo forum thread reports a conda-forge connector error ("Can not convert Array to
  String") that staff called not a trivial fix; not checked against 26.0.12.
- Automation: the feed and connector APIs (`/api/management/feeds/create`,
  `/api/management/connectors/create`, `X-ApiKey`) need an API key, and on Free the key can only
  be made in the UI (Administration > API Keys). `proget/bootstrap.sh` does the rest once a key
  and an API key exist; it stops with exit 3 and the reason before that.

## Recommendation

| Scenario | Product | Why |
|---|---|---|
| Behind the artifact manager (AK is the upstream of the company's manager) | **Nexus CE** | Works end to end with pixi `install --locked` and fresh solves, keeps the lockfile's `ak.internal` URLs (pixi mirrors), the allowlist shows through as "No candidates were found" once Nexus revalidates. Show `metadataMaxAge` and the cached-package caveat honestly. |
| Merged in the artifact manager (AK virtual + conda-forge merged by the manager) | **Nexus CE**, as the counter-example | It merges, but with no ownership rule: the squatted `acme-core 99.0.0` wins an unpinned solve, a same-name file breaks the install with a hash mismatch, and the group re-opens everything the AK allowlist closed. That is the case for doing the merge in AK. Needs an 8 GB heap. |
| Outage | **Nexus CE** | Serves cached metadata and packages with AK stopped, including stale metadata; clear errors for never-cached files. |
| Any scenario with ProGet | not now | Needs a licence key tied to a person's e-mail, Free cannot cache metadata, and the docs say Free connects only to public repositories. |

What the free editions cannot show:

- Nexus CE: bearer-token upstream auth for conda, `.zst` and CEP-16 shards through the manager,
  anything above 40,000 components or 100,000 requests a day (new components stop being added),
  HA and replication (Pro).
- ProGet Free: anything without registering a licence; metadata caching (so no outage scenario
  with fresh solves); connector filters; and, per the docs, a connector to a non-public
  repository.

For the "least change" shape without a merging manager, the client lists two channels
(the manager's proxy of AK first, conda-forge second) and pixi's `channel-priority = "strict"`
decides: a name found in the first channel is never taken from the second. That rule is pixi's,
not the manager's, and it is the one the walkthrough already relies on.
