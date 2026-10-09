# Scenarios spike: an enterprise artifact manager in front of Artifact Keeper

Spike notes, 2026-10-08. The question: can Sonatype Nexus Repository (the free edition) and
Inedo ProGet Free sit in front of the Artifact Keeper conda virtual channel as "the enterprise
artifact manager", with current pixi as the client? These are facts from one afternoon on the
walkthrough stack, not polished docs. They decide how the scenario compose profiles get built.

Short answer: both can. Nexus with caveats. ProGet Free (licensed 2026-10-08 with a Free key
registered with Inedo) works for `install --locked` and fresh solves, but rebuilds and re-downloads
the whole channel index every ~10 minutes of use, regenerates `.bz2` per request (a solve takes
about 210 s), drops `noarch` from every record, cannot solve while Artifact Keeper is down once
its index is 10 minutes old, and lets the connector whose name sorts first win a merge.


## The scenario suite (S1-S7)

Built on the spike below. Each scenario is one script that prints `PASS`, `FAIL` or
`BLOCKED(<issue>)` per check in the gates' format, an evidence block (status codes, timings,
bytes, the client's exact messages), and restores everything it changed on `ak-conda` before
it exits, also on failure (an `EXIT` trap). Logs: `~/.cache/ak-scenarios/<id>-<name>.log`;
verdicts accumulate in `~/.cache/ak-scenarios/results.tsv`.

```console
make scenarios-up        # up.sh: fake-forge files, compose overlay, AK scn-* repos, Nexus config
make scenarios           # run-all.sh: S1..S7, summary table
make scenario-S4         # one scenario
make scenarios-down      # down.sh: stop scn-nexus and scn-fake-forge (volume kept)

make scenarios-up-proget # proget/up.sh: compose, fake-forge, AK scn-* repos, proget/bootstrap.sh
make scenarios AM=proget # run-all.sh: S1 S2 S3 S4 S6 through ProGet (the s<N>-*-proget.sh variants)
make scenario-S3 AM=proget
make scenarios-down-proget
make scenarios-restore   # restore-pending.sh: replay the restore of a killed run
```

`AM` (artifact manager) picks the product: `nexus` (default) or `proget`. S5 and S7 are about
Artifact Keeper alone and run only with `AM=nexus`. ProGet checks carry the prefix `[proget]` in
the verdict lines and in `results.tsv`.

| Id | Script | What it proves |
|---|---|---|
| S1 | `s1-behind-nexus.sh` | pixi through Nexus: cold and warm installs, lock unchanged, name guard, allowlist propagation delay |
| S2 | `s2-public-source-down.sh` | conda-forge unreachable from AK: Nexus and AK keep serving what they cached, inside and after AK's cache TTL |
| S3 | `s3-curated-channel-down.sh` | AK stopped for 90 s: Nexus serves cached metadata and packages; never-fetched files fail |
| S4 | `s4-merged-in-the-artifact-manager.sh` | the counter-example: a Nexus group undoes the allowlist, takes a squatted name, breaks on a file name clash; the fix |
| S5 | `s5-cve-on-proxy.sh` | scan-on-proxy on `conda-forge` with a known-CVE package (certifi 2022.12.7) |
| S6 | `s6-allowlist-from-a-pull-request.sh` + `allowlist-ci.sh` | the allowlist CI loop for two pull requests, direct and through Nexus |
| S7 | `s7-big-and-malformed-index.sh` | merged index size per solve, no shards through the virtual, a list-shaped `track_features` |
| S1 `[proget]` | `s1-behind-proget.sh` | pixi through ProGet: never-built index, cold and warm installs, lock unchanged, name guard, a fresh solve and the rewritten records, allowlist propagation untouched, a feed that cached a removed package |
| S2 `[proget]` | `s2-public-source-down-proget.sh` | conda-forge unreachable from AK: ProGet installs, rebuilds its index from AK's cache, solves |
| S3 `[proget]` | `s3-curated-channel-down-proget.sh` | AK stopped: installs work; solves work only while ProGet's index is younger than ~10 min; a forced update; recovery |
| S4 `[proget]` | `s4-merged-in-the-artifact-manager-proget.sh` | the counter-example with a ProGet feed of two connectors: allowlist undone, squatted name, clash decided by connector name; the fix |
| S6 `[proget]` | `s6-allowlist-from-a-pull-request-proget.sh` | the allowlist CI loop for two pull requests, through ProGet |

Supporting files:

| File | What |
|---|---|
| `lib.sh` | shared helpers: verdicts, evidence, restore stack, Nexus and AK calls, `px` (pixi in the client image), allowlist save/restore, fake-upstream patching |
| `up.sh`, `down.sh` | `make scenarios-up` / `scenarios-down` |
| `compose.nexus.yml` | the overlay (compose project `ak-scn-nexus`): `scn-nexus` and `scn-fake-forge` |
| `ak-setup.sh` | Artifact Keeper side: `scn-virtual` (conda-internal, conda-fake-upstream, conda-forge), `scn-virtual-ci` (the unfiltered twin for CI solves), token `scn-reader` (`.tokens/`, gitignored) |
| `allowlist-ci.sh` | the CI job: lock against the twin, check, apply the allowlist, verify |
| `restore-pending.sh` | `make scenarios-restore`: replays `.work/pending/` (see "Restores survive a killed run") |
| `compose.proget.yml` | compose project `ak-scn-proget`: `scn-proget` with volumes `scn-proget-{packages,database,backups,localstorage}` |
| `proget/up.sh` | `make scenarios-up-proget`: CA bundle, compose up, fake-forge, `ak-setup.sh`, `proget/bootstrap.sh` |
| `proget/bootstrap.sh` | licence check, API key (anonymously while that is still possible), lock-down (`secure.py`), five connectors and seven feeds by API. Idempotent |
| `proget/secure.py`, `proget/ui.py` | Playwright (headless Chromium; `PROGET_PY` = a python with playwright): Admin password and "Remove Anonymous Access"; connector ids, Local Index delete and status. Free has no API for either |
| `proget/pixi-config.toml` | pixi config with ProGet feeds as the only conda source (mirrors) |

Decisions made while building it:

- **Nexus metadata TTL 2 minutes** (`NEXUS_METADATA_MAX_AGE`, also the negative cache). The
  spike's 24 hours delays an allowlist change by up to a day for every client behind Nexus; the
  TTL is the propagation delay, so S1 measures it. A revalidation is a conditional GET that AK
  answers 304 when nothing changed. Package files keep 24 hours (immutable by name).
- **The hostile member inside AK is the gate's fake upstream**, not `scn-fake-forge`. Artifact
  Keeper refuses remote upstreams on private addresses except `AK_SSRF_ALLOW_PRIVATE_CIDRS`,
  which this stack sets to `172.31.40.200/32` (the gate's fake upstream):
  `HTTP 400 Upstream URL IP '172.31.40.151' is not allowed (private/internal network)`. Widening
  it needs a backend recreate with a changed `.env`. Scenarios that need different content on
  that host patch its `repodata.json`/`.zst` for the run and restore them (`fu_patch`).
  `scn-fake-forge` serves the same content to Nexus.
- **The CI solve uses an unfiltered twin** (`scn-virtual-ci`) through a pixi mirror, not "turn the
  allowlist off, lock, turn it on": `conda-virtual` is shared. Because AK's `info.base_url` is
  host-relative (#4580), the twin's name lands in `pixi.lock`; `allowlist-ci.sh` rewrites it to
  `conda-virtual` (same files, same sha256) and its check step refuses any other URL.
- **Restores survive a killed run.** Every restore runs from the `EXIT` trap, which also fires on
  INT, TERM and HUP. A SIGKILL (a killed session) cannot be trapped, so the changes that must not
  outlive a run (the `conda-virtual` allowlist, the `conda-forge` upstream URL and scan config, a
  stopped backend) are journalled in `.work/pending/` before they are made (`guard` in `lib.sh`).
  The next scenario replays a leftover entry before it starts; `make scenarios-restore` does it
  by hand.
- **ProGet: a cold package cache is a fresh feed** over the same connector (`pg_feed`, removed at
  exit), not deleted packages: ProGet Free allows 10 API deletes an hour. The connector's index is
  shared by all its feeds.
- **ProGet: index state is set with the UI's Local Index > delete** (`pg_reindex`, through
  `proget/ui.py`) where a scenario needs a known starting point; S1 5 and S6 measure the
  propagation with nobody touching ProGet. ProGet keeps the index it built while the allowlist
  was on until its next update, so scenarios after S4 start by rebuilding it.
- **ProGet: `channeldata.json` workarounds.** `scn-fake-forge` now publishes one (ProGet's conda
  connector fails without it, and a feed fails as a whole). `scn-virtual` answers
  `channeldata.json` with 502 because the gate's fake upstream has none (C38); for ProGet runs
  over `scn-virtual` the fake upstream gets one for the length of the run (`fu_channeldata`).
- **ProGet: LocalStorage is a volume** (`scn-proget-localstorage`): the connector indexes live
  there, outside Inedo's documented volumes. A deleted connector leaves its index directory
  (1.5 GB); `pg_connector_rm` removes it.
- **Nexus group caches are invalidated and warmed** before S4 uses them: during this work the
  group `merged` answered `linux-64/repodata.json.bz2` with `{"packages":{}}` (54 bytes) from a
  stale group cache, and pixi said `No candidates were found for python 3.12.*`. An
  `invalidate-cache` on the group rebuilt it (75 s, 790,808 records).

The spike notes follow.

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
| `proget/bootstrap.sh`, `proget/secure.py`, `proget/ui.py`, `proget/pixi-config.toml` | API key, lock-down, connectors and feeds; run against the licensed instance (see the ProGet section) |
| `pixi-through.sh` | Runs pixi in the walkthrough's client image with a product's config as `/etc/pixi/config.toml` |
| `measure.sh` | Runs a command, then counts what the product served and what `ak.internal` served (Caddy log), by status and bytes |
| `fake-forge.sh` | `scn-fake-forge`: a static conda channel we control, for the merge precedence test |
| `outage.sh` | The two outage drills (`backend`, `forge`); restores everything, also on error (trap) |

Secrets: the scenario admin passwords (`SCN_NEXUS_ADMIN_PASSWORD`, `PROGET_ADMIN_PASSWORD`) and
`PROGET_API_KEY` are generated into `scenarios/.env` (gitignored). The
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
as the upstream. The third column is what the walkthrough does without an artifact manager:
pixi talks to Artifact Keeper directly.

| | Nexus CE 3.96.4 | ProGet Free 26.0.12 | No artifact manager (pixi -> AK) |
|---|---|---|---|
| Runs rootless with podman compose | yes, 1 container, embedded H2; 23-27 s to writable | yes, 1 container, embedded PostgreSQL 17; 7 s to the UI; 2 s to healthy on a recreate | (the walkthrough stack) |
| Licence key for the free edition | no; accept the EULA (API) | **yes**, from Inedo against a name and e-mail address (UI, once) | none |
| Default security | anonymous read only after `bootstrap.sh`; admin password generated | **Anonymous holds Administer** until "Remove Anonymous Access" (UI only on Free); `Admin`/`Admin` | token per consumer |
| Configuration by API | everything (repositories, truststore, SSRF list, EULA) | feeds, connectors, API keys (the first one anonymously); users and privileges UI only | `make` targets |
| Conda proxy (remote) | yes | yes (a feed with a connector), also to a private authenticated AK: the "public repositories only" rule is not enforced | AK's `conda-forge` remote |
| Conda hosted | yes since 3.92 | yes (`PUT` of a `.conda` with `api:<key>`) | `conda-internal` |
| Conda group / merge | yes since 3.92 | yes (a feed with several connectors) | the virtual channel, with the name guard and allowlist |
| What it asks AK for | `repodata.json`, `.bz2`, `channeldata.json`, on client demand | its own index build: `channeldata.json` + `.bz2` of all 12 subdirs (~322 MB) | (pixi: `.zst` or shards, per solve) |
| `repodata.json` to clients | yes (passed through) | yes, regenerated per request (8-11 s noarch) | yes |
| `repodata.json.zst` | **no** (404 from Nexus) | **no** (404 from ProGet) | yes |
| `repodata.json.bz2` | yes (proxy passes AK's; a group compresses itself, 52 s) | yes, compressed per request (60-95 s linux-64) | yes |
| CEP-16 shards | **no** | **no** | hosted members only (#4577) |
| `channeldata.json` | yes | yes (its own); **required upstream** (a member without one fails the feed) | yes; a virtual with a member without one answers 502 (C38) |
| `current_repodata.json` | no | no | 200, empty (C26) |
| Records as AK sent them | yes | **no**: `noarch`, `track_features`, `license_family` dropped; 5 records with unparsed versions gone | yes |
| `info.base_url` | passed through (#4580 bites groups) | removed | host-relative (#4580) |
| Upstream auth | basic; 401 challenge first (2 requests per fetch); bearer stored but never sent | basic, pre-emptive; no bearer field | bearer token |
| Conditional GET upstream | `If-None-Match` + `If-Modified-Since`; AK 304 for repodata | `If-Modified-Since` only; AK always 200 (no `Last-Modified`, C39) | pixi: `If-None-Match`, 304 |
| Conditional GET from clients | yes (ETag, `Last-Modified`) | `If-Modified-Since` -> 304; no ETag | yes |
| Metadata freshness | `metadataMaxAge` (set: 2 min) | index update on request once ~10 min old, plus a 4-8 min rebuild; no setting | immediate |
| Allowlist propagation | `metadataMaxAge` (S1: 120 s) | S1: 462 s untouched (index 176 s old when the allowlist went on); S6: about 620 s per pull request (CI job to ProGet clients) | immediate (G14) |
| Cached package after the allowlist removes it | still served, not listed | **still listed and served** by the feed that cached it | 404 at once |
| `install --locked` on a fresh instance | works (fetches on demand) | **404** until a metadata request built the index | works |
| Fresh solve time (conda-only manifest, cold client) | 10-26 s | 140-210 s | 29 s |
| Name guard | holds through a plain proxy | holds through a plain feed (S1) | holds |
| Merge precedence on a file name clash | record from the last member, bytes from the first: hash mismatch | record and bytes from the connector whose name sorts first: a squatter named to sort first installs silently | name guard: hosted wins |
| Serves from cache when AK is down | metadata and packages, also stale | packages yes; metadata only while its index is younger than ~10 min, then HTTP 500 (S3) | nothing (502) |
| Serves when AK's conda-forge egress is blocked | yes (AK itself keeps serving its cache) | yes: installs (4.0 s), an index rebuild (218 s) and a fresh solve (149 s) work, AK serves its cache; never-cached packages 404 (S2) | yes, AK's cache (S2) |
| Free-edition limits that matter | 40,000 components or 100,000 requests a day | 10 API deletes an hour; no metadata-cache setting; connector filters ignored; UI-only security | none |

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

Licensed with a ProGet Free key (entered once in the UI; the key lives in the
`scn-proget-database` volume). Headers: `X-ProGet-Version: 26.0.12.24`, `X-ProGet-Edition: free`.
Everything below was run; the scenario numbers are from `make scenarios AM=proget` (see the
suite section above and `docs/private-conda-channel-pixi/scenarios.md`).

### 1. Running it

- `compose.proget.yml`: one container, **embedded PostgreSQL 17** inside it
  (`/usr/lib/postgresql/17/bin/postgres -D /var/proget/database`, port 5728, md5 auth for user
  `proget`). Runs as root inside the user namespace; rootless podman needs nothing else.
- Volumes: `scn-proget-{packages,database,backups}` as Inedo documents, **plus
  `scn-proget-localstorage` for `/usr/share/ProGet/LocalStorage`**. Conda connectors keep their
  index there (`Connectors/C<id>/index.sqlite3`, 1.6 GB for `conda-virtual`, 1.6 GB for
  conda-forge). Without that volume a recreate loses the index while the database still knows
  the connector: the feed then answered `noarch/repodata.json` with 200 and
  `{"info":{"subdir":"noarch"},"packages":{},"packages.conda":{},"repodata_version":1}` until a
  rebuild finished.
- TLS to `ak.internal`: ProGet (.NET on Ubuntu 24.04) uses the OpenSSL bundle; `proget/up.sh`
  mounts the image's bundle plus our CA over `/etc/ssl/certs/ca-certificates.crt`. It worked
  first time (`SSL_CERT_FILE` is taken: it configures ProGet's own HTTPS listener).
- Time to healthy: first start 7 s to the UI (then 500 on `/health` until licensed); a recreate
  with the licensed database: `/health` 200 after 2 s. Memory: about 200 MB idle unlicensed,
  663 MB with two 1.6 GB indexes built (`podman stats`), under the 4 GB `mem_limit`.
- **Licence**: required for Free too (`/health` 500 `ERROR: Product license is not valid`,
  everything else `302 -> /administration/licensing`). The key is issued by Inedo against a name
  and an e-mail address; done once in the UI.
- **Security out of the box**: the Anonymous user holds the Administer task. The Tasks page says
  so: "The Anonymous user has been granted Administer access. While this is the default, "out of
  the box" configuration for on-premise installations of ProGet, this is intended for
  demonstration purposes only". Anonymously, `POST /api/api-keys/create` made a system key (201)
  and `GET /api/api-keys/list` returned key values in clear. The built-in user is `Admin` /
  `Admin`.
- **What needs the UI on Free**: the users and privileges APIs answer `ProGet Free Edition does not
  support this API` ("limited to UI-based security configuration"). `proget/secure.py`
  (Playwright, headless Chromium) does the two clicks: change the Admin password (stored as
  `PROGET_ADMIN_PASSWORD` in `scenarios/.env`) and "Remove Anonymous Access", which removes
  Anonymous from Administer and keeps "View & Download Packages". After it: anonymous
  `api-keys/list` 403, `connectors/create` 403, `feeds/create` with a wrong `X-ApiKey` 403 (`The
  specified API key does not have the proper permissions to perform this action.`). Before, a
  wrong key got 200, because anonymous was admin. `feeds/list` stays readable anonymously.
- **The API key needs no UI** on a fresh instance: `proget/bootstrap.sh` creates it anonymously
  (type System, API `feeds`) before the lock-down. Fallback when the instance is already locked
  down, by hand: log in as Admin > Administration > Security > API Keys > Create API Key >
  System, tick "Feeds API" > Save, then `PROGET_API_KEY=...` in `scenarios/.env`.
- Everything else by API (`X-ApiKey`): `/api/management/connectors/{create,update,get,list,delete}`,
  `/api/management/feeds/{create,update,get,list,delete}`. The connectors API returns no id; the
  id (which names the index directory) comes from the UI (`proget/ui.py ids`).
- Free-edition rule "can only connect to public repositories": **not enforced** for a private,
  authenticated Artifact Keeper channel. The connector with Basic credentials was created (201),
  shows "Authentication: Username: consumer" and serves. The licence page itself only forbids
  connecting to other ProGet instances; whether the "public repositories" sentence is a licence
  term is for Inedo to say, not something the product checks.
- "Limited to 10 deletes per hour when using the API": the scenarios avoid package deletes. A
  cold package cache is a fresh feed over the same connector (feed delete/create is not limited
  in practice: dozens per run, all 200).

### 2. Conda support

- **Proxy**: a conda feed with a connector (`url`, `username`, `password`, `timeout`; no bearer
  field). Works for `conda-virtual`, `conda-internal`, `scn-virtual`, conda.anaconda.org and our
  static `scn-fake-forge` (after it got a `channeldata.json`, see 3).
- **Hosted**: yes. `curl --user api:<key> --upload-file acme-core-99.0.0-pyh4616a5c_0.conda
  http://127.0.0.1:30482/conda/tmp-hosted` gives 200 (anonymous: 401); `noarch/repodata.json`
  and `channeldata.json` are generated; the download is byte-identical (sha256 `9ac9a20f...`).
  The test feed was deleted.
- **Group / merge**: a feed with several connectors (`merged` = [ak-virtual, cf-direct],
  `merged-fake` = [ak-virtual, scn-fake]). See 5.

### 3. Proxy of `https://ak.internal/conda/conda-virtual`

What ProGet asks Artifact Keeper for: **its own index build**, not the client's request. The
first metadata request for a feed starts it: `channeldata.json` (23.7 MB), then
`repodata.json.bz2` of every subdir AK lists (12: linux-64 61.5 MB, osx-64 52.8 MB, win-64
39.6 MB, noarch 29.2 MB, ... about 322 MB). Never `.zst`, never shards, never plain
`repodata.json`, never `current_repodata.json`. The connector index is per connector and shared
by every feed that uses it.

```text
cold noarch/repodata.json                 200 180228342 265.7s   (the index build)
     linux-64/repodata.json               200 445131777  18.1s
     linux-64/repodata.json.zst           404        23   0.02s   (from ProGet; never asked upstream)
     linux-64/repodata.json.bz2           200  60876415  62.9s   (compressed by ProGet per request)
     linux-64/repodata_shards.msgpack.zst 404        23   0.003s
     channeldata.json                     200  29970918   0.6s   (ProGet's own, not AK's 23.7 MB)
     noarch/current_repodata.json         404        23   0.002s
warm noarch/repodata.json                 200 180228342  11.3s   (no request to AK)
     linux-64/repodata.json.bz2           200  60876415  74.2s   (no request to AK)
     channeldata.json                     200  29970918   0.4s
```

- Auth: Basic `consumer:<token>`, sent **pre-emptively** (no 401 round trip; Nexus does two
  requests per fetch).
- **The index is rebuilt, not cached with a TTL you set.** The connector page says: "Conda
  connectors use a locally-stored index file ... periodically updated when browsing packages in the
  ProGet UI or making certain API calls from the client." Measured: an update starts on a client
  request once the last one is about 10 minutes old (builds finished 23:20:41 and 23:35:52;
  the next started 23:32:14 and 23:47:23; a request at 9.6 minutes started nothing). There is no
  setting for it. The connector API accepts `metadataCacheEnabled: true, metadataCacheMinutes: 2`
  on Free and echoes them back; the UI shows "Metadata Cache: disabled" and nothing changes.
- During an update the old index is served (the new file replaces it when done). An index built
  from nothing (first use, or after the UI's Local Index > delete) is served **empty with HTTP
  200** until done.
- **Every update downloads everything again.** ProGet revalidates with `If-Modified-Since` only;
  AK's virtual repodata has an `ETag` and no `Last-Modified`, so AK answers 200 with the full body
  (`If-None-Match` with the same ETag gets 304). About 322 MB per update, every ~15 minutes while
  clients are active, for one connector. Overlapping client requests also started a second full
  build (653 MB from AK for one index in S1), and each request during an update restarts the
  `channeldata.json` download (aborted, logged by Caddy with no status).
- **Package requests do not build the index.** Against a never-built index every package is 404
  (`A 404 error occurred in ak-virtual: Package linux-64/libgfortran-16.2.0-h69a702a_5.conda not
  found`) and the update a package request starts is aborted when the request ends. So `pixi
  install --locked`, which asks for no metadata, fails against a fresh ProGet (S1 0).
- **ProGet regenerates the JSON per request** from its index: 8-11 s for `noarch/repodata.json`,
  60-95 s for `linux-64/repodata.json.bz2`, every time (no response cache). `.bz2` goes out as
  `Content-Type: application/x-tar`. With `Accept-Encoding: br` the JSON is sent brotli-compressed
  (33.8 MB for noarch).
- **ProGet rewrites the records** (S1 4): `noarch` dropped from all 382,473 noarch records,
  `license_family` from 361,777, `track_features` from 525, also `app_*`, `extra_depends`;
  `constrains: []` added. Five records are dropped, all with versions ProGet does not parse:
  `ps2ff-v1.4-py_0`, `pysbol3-v1.0.1-pyhd8ed1ab_0`, `universal_pathlib-v0.0.2-pyhf1ccde4_0`,
  `vounwarp-v1.0-py_0`, `rubin-scheduler-3.0.0rc0-pyhd8ed1ab_0`. `info` becomes `{"subdir": ...}`
  (AK's host-relative `base_url` is gone, so #4580 does not bite through ProGet). Packages it has
  cached in a feed are merged into that feed's index (the served size grows by a few hundred
  bytes per cached file).
- Conditional GET from clients: `If-Modified-Since` gets 304 in 7 ms; no `ETag` is sent;
  `Last-Modified` is the time of the feed's last change (a cached package moves it), not the
  index time.
- A conda connector needs `channeldata.json` upstream. Our static `scn-fake-forge` had none:
  `The remote server returned an error: (404) Not Found.`, HTTP 500 for the feed. **Artifact
  Keeper's `scn-virtual` answers `channeldata.json` with 502** (`member 'conda-fake-upstream'
  failed: no candidate document available upstream (last status 404 Not Found)`) because one
  member has none, while its repodata is 200; so ProGet cannot proxy `scn-virtual` as it is. The
  scenarios give `scn-fake-forge` a `channeldata.json`, and give the gate's fake upstream one for
  the length of a run (`fu_channeldata`, removed at exit).

### 4. pixi through ProGet

Client: the walkthrough image with `proget/pixi-config.toml` (mirrors for `conda-virtual`,
`conda-internal`, `scn-virtual` and conda-forge to ProGet feeds; anonymous read, no credential
for ProGet; PyPI still to `ak.internal`).

| Run | Result |
|---|---|
| `install --locked`, connector index never built | **fails**, 0.8 s: `HTTP status client error (404 Not Found) for url (http://scn-proget/conda/s1-cold/linux-64/openssl-3.6.4-h781a0a9_0.conda)` |
| index build by metadata requests | 448 s, 653 MB from AK (built twice, see 3) |
| `install --locked`, fresh feed (package cache empty), index warm | ok, 3.2-16.6 s, 43 packages, 101.2 MB from AK |
| `install --locked`, warm | ok, 4.0-11.6 s, nothing from AK |
| `lock` (fresh solve), conda-only manifest | ok, **210 s** (`linux-64/repodata.json.bz2` 95.5 s and `noarch/...bz2` 52.4 s to generate); a lock solved through ProGet has `noarch: false` on 12 entries that are `noarch: python`; they install and import (rattler reads `info/index.json`) |
| same solve straight to AK / through Nexus | 29 s / 10-26 s |

The allowlist through ProGet: see S1 5 and S6 in the suite. The ProGet index changes only when
ProGet updates it (about 10 minutes plus the rebuild); a feed that cached a package keeps listing
and serving it after the allowlist removes it.

### 5. Merged in the artifact manager

Yes: a feed with two connectors merges them (S4). Union of records; highest version wins in an
unpinned solve (`acme-core 99.0.0` from `scn-fake-forge` locked, as with Nexus); the allowlist is
undone (colorama: 0 records through ak-virtual, 8 through the merged feed, download 200).

**File name clash**: unlike Nexus, record and bytes come from the same connector, so there is no
hash mismatch. The connector is chosen by **name, alphabetically**, not by the feed's order:

- `merged-fake` = [ak-virtual, scn-fake]: ours (`eb370de6...`) for both, installs.
- the same feed stored as [scn-fake, ak-virtual]: still ours.
- [ak-virtual, aaa-fake] (`aaa-fake` = the same fake channel under a name that sorts first): the
  fake (`9ac9a20f...`) for record and bytes; pixi locks and installs it **without any error**.

A merged feed fails as a whole when one connector fails: with `scn-fake-forge` lacking
`channeldata.json`, `merged-fake/noarch/repodata.json` was 500 although `ak-virtual` was fine.
Merging conda-forge costs a second 1.6 GB index (built in about 13 minutes).

### 6. Outage

`s3-curated-channel-down-proget.sh` and `s2-public-source-down-proget.sh` (logs in
`~/.cache/ak-scenarios/`).

AK stopped (S3, 278 s down; the stop is timed when ProGet's index is 7 minutes old):

| Check, backend stopped | Result |
|---|---|
| `install --locked`, conda-only copy of `project/` | **ok**, 1.1 s: 43 packages from the feed's cache |
| `install --locked`, `project/` as is | conda part ok; fails on the PyPI wheel from AK directly (`502 Bad Gateway`) |
| fresh solve, index 442 s old | **ok**, 140 s, from ProGet's index |
| any metadata request, index 642 s old | **HTTP 500** `The remote server returned an error: (502) Bad Gateway.`; each request retries the update (`channeldata.json` 502 x32 in two minutes); the solve fails |
| Local Index > delete while AK is down | 500 again; UI: `The local index does not yet exist; try browsing to a connector.` |
| a package ProGet never fetched | 404 `Package noarch/... not found.` |
| backend back | index rebuilt in 229 s; a fresh pull works 260 s after the start |

So ProGet Free serves packages it has cached for as long as AK is down, but metadata only until
its index is about 10 minutes old; it does not fall back to the old index when the update fails.
That is the practical meaning of "metadata caching is only available in paid editions" for conda.
(The first S3 run stopped AK at 9 minutes of index age; the solve's first request arrived at 605 s
and already got 500, which is how the ~600 s edge was pinned down.)

conda-forge unreachable from AK (S2): no failure reaches ProGet. AK keeps serving the virtual's
repodata from its own conda-forge cache, so an index rebuild during the block worked (218 s, all
382,480 noarch records), a fresh solve worked (149 s), installs worked (4.0 s); a package nobody
had cached was 404 (`Package file noarch/... was not found in storage.`) and pulled once the
upstream URL was restored.

### 7. Other things a reader would trip on

- The licence key (a name and an e-mail address with Inedo), then the anonymous-admin default.
- The index location outside the documented volumes.
- `install --locked` against a fresh ProGet is 404 until something asks for metadata.
- Every solve pays for ProGet's per-request `.bz2` (60-95 s for linux-64). pixi's
  `[repodata-config] disable-bzip2 = true` makes it fetch the JSON instead (brotli); one try under
  load took 301 s, not measured idle.
- About 322 MB from AK per index update, every ~15 minutes while clients are busy (C39, C44).
- `noarch` missing from every record; five records with unusual versions missing.
- A merged feed's clash winner depends on connector names.
- The 404 body is ProGet's text (`Package linux-64/... not found.`), not Artifact Keeper's message.

## Recommendation

| Scenario | Product | Why |
|---|---|---|
| Behind the artifact manager (AK is the upstream of the company's manager) | **Nexus CE** | Works end to end with pixi `install --locked` and fresh solves, keeps the lockfile's `ak.internal` URLs (pixi mirrors), the allowlist shows through as "No candidates were found" once Nexus revalidates. Show `metadataMaxAge` and the cached-package caveat honestly. |
| Merged in the artifact manager (AK virtual + conda-forge merged by the manager) | **Nexus CE**, as the counter-example | It merges, but with no ownership rule: the squatted `acme-core 99.0.0` wins an unpinned solve, a same-name file breaks the install with a hash mismatch, and the group re-opens everything the AK allowlist closed. That is the case for doing the merge in AK. Needs an 8 GB heap. |
| Outage | **Nexus CE** | Serves cached metadata and packages with AK stopped, including stale metadata; clear errors for never-cached files. |
| Behind the artifact manager, second product | **ProGet Free**, with its caveats shown | It works (`install --locked`, solves, name guard, allowlist after ~10 minutes plus a rebuild). Show the costs: the index re-download every ~10 minutes of use, 140-210 s solves, `noarch` dropped, `install --locked` 404 on a fresh instance, no solves during an outage once the index is 10 minutes old. |
| Merged in the artifact manager, second product | **ProGet Free** | Same failure as Nexus (allowlist undone, squatted name wins) plus a sharper one: the clash winner is the connector whose name sorts first, and the install succeeds with the squatter's bytes. |

What the free editions cannot show:

- Nexus CE: bearer-token upstream auth for conda, `.zst` and CEP-16 shards through the manager,
  anything above 40,000 components or 100,000 requests a day (new components stop being added),
  HA and replication (Pro).
- ProGet Free: anything without registering a licence; security configuration by API (UI only:
  `proget/secure.py`); a metadata cache setting (the connector fields are accepted and ignored;
  the conda index is updated on its own ~10 minute rule); connector filters (ignored on Free,
  per the docs); more than 10 API deletes an hour. The "public repositories only" sentence did
  not stop a connector to the private Artifact Keeper channel.

For the "least change" shape without a merging manager, the client lists two channels
(the manager's proxy of AK first, conda-forge second) and pixi's `channel-priority = "strict"`
decides: a name found in the first channel is never taken from the second. That rule is pixi's,
not the manager's, and it is the one the walkthrough already relies on.
