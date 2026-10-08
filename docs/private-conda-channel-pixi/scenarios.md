# Scenarios: behind Nexus, outages, merges

<!-- DRAFT: commands and outputs are exact (make scenarios, 2026-10-08T20:51Z-21:21Z, backend
localhost/ak-backend:allowlist-1.11, Nexus Community Edition 3.96.4, pixi 0.81.0); the prose is
plain on purpose and will be rewritten. -->

The steps so far have pixi talk to Artifact Keeper directly. Most companies that would run this
already have an artifact manager that every build goes through. These scenarios put Sonatype
Nexus Repository Community Edition (the free edition) between pixi and Artifact Keeper and
check what still holds: the lock, the name guard, the allowlist, and installs when something is
down. One scenario does the opposite on purpose: it merges the channels in Nexus instead of in
Artifact Keeper, to show what breaks.

Each scenario is one script under
[`scenarios/`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-conda-channel-pixi/scenarios/).
It prints one `PASS`, `FAIL` or `BLOCKED(<issue>)` line per check, the same format as the
[gates](results.md), then an evidence block. It puts back everything it changed on the registry
before it exits, also when a check fails. Logs go to `~/.cache/ak-scenarios/`.

```console
$ make scenarios-up      # Nexus and a fake public channel beside the stack, configured by API
$ make scenarios         # S1..S7, about 30 minutes
$ make scenario-S4       # one of them
$ make scenarios-down
```

What `scenarios-up` sets up:

| Piece | What |
|---|---|
| `scn-nexus` | Nexus CE 3.96.4, 8 GB heap, on `ak-conda-net`. Proxies `ak-virtual` (of `conda-virtual`), `ak-internal`, `ak-scn-virtual` (of `scn-virtual`), `cf-direct` (conda.anaconda.org), `scn-fake` (of `scn-fake-forge`); groups `merged` = [ak-virtual, cf-direct] and `merged-fake` = [ak-virtual, scn-fake]. Upstream credential: basic auth, `consumer` and the consumer token as password. |
| `scn-fake-forge` | a static conda channel we control: `acme-core 99.0.0` (our internal name, higher version) and a different file under the exact name of our `acme-core-1.0.0-pyh4616a5c_0.conda` |
| `scn-virtual` | in Artifact Keeper: `conda-virtual` plus a hostile public member (G4's fake upstream, which publishes `acme-core 99.0.0`) |
| `scn-virtual-ci` | in Artifact Keeper: an unfiltered twin of `conda-virtual` for CI solves (S6) |
| pixi config | [`nexus/pixi-config.toml`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-conda-channel-pixi/scenarios/nexus/pixi-config.toml): mirrors send every `https://ak.internal/conda/...` request to Nexus; the lockfile keeps the `ak.internal` URLs |

**The Nexus metadata TTL is 2 minutes.** Nexus serves its copy of `repodata.json` and
`channeldata.json` for `metadataMaxAge` before it asks Artifact Keeper again. Any change to the
allowlist reaches clients behind Nexus only after that, so the TTL is the policy propagation
delay. The REST API has no default; a day (1440 minutes) is common. The scenarios use 2 minutes
(`NEXUS_METADATA_MAX_AGE`) so that S1 can measure the delay in one run. Each revalidation is a
conditional GET that Artifact Keeper answers with 304 when nothing changed, so a short TTL is
cheap. The negative cache (remembered 404s) uses 2 minutes too; package files keep a day.

## Results

| Scenario | PASS | BLOCKED | FAIL | Time |
|---|---|---|---|---|
| S1 behind Nexus | 9 | 0 | 0 | 194 s |
| S2 public source down | 11 | 0 | 0 | 450 s |
| S3 curated channel down | 5 | 0 | 0 | 138 s |
| S4 merged in the artifact manager | 5 | 0 | 0 | 387 s |
| S5 CVE on proxy | 3 | 2 (#4097) | 0 | 68 s |
| S6 allowlist from a pull request | 6 | 0 | 0 | 257 s |
| S7 big and malformed index | 7 | 0 | 0 | 305 s |
| **Total** | **46** | **2** | **0** | **1799 s** |

## S1: behind Nexus

What it proves: with Nexus as pixi's only conda source, `install --locked` works cold and warm and
leaves the lock alone, the name guard still holds, and an allowlist change reaches Nexus clients
after the metadata TTL.

```console
$ make scenario-S1
```

```text
PASS         S1   cold: pixi install --locked through Nexus (2.2 s; AK -> Nexus 101.2 MB, Nexus -> pixi 101.2 MB)
PASS         S1   warm: pixi install --locked through Nexus (1.5 s; AK -> Nexus 0 MB, Nexus -> pixi 101.2 MB)
PASS         S1   pixi.lock unchanged by install --locked through Nexus (keeps the https://ak.internal URLs)
PASS         S1   scn-virtual through Nexus offers only the hosted acme-core ["1.0.0","1.0.1","1.0.1791387539","1.0.1791387567","1.0.1791483478"] (the fake upstream's 99.0.0 dropped by AK's name guard)
PASS         S1   unpinned 'acme-core = "*"' solved through Nexus locks the hosted 1.0.1791483478, not 99.0.0
PASS         S1   allowlist reaches Nexus clients 120 s after it is set (bound: metadataMaxAge 2 min)
PASS         S1   inside the window, pixi add colorama through Nexus still succeeds from Nexus's cached index ("Added colorama >=0.4.6,<0.5")
PASS         S1   after propagation, pixi add colorama through Nexus fails: "No candidates were found for colorama *"
PASS         S1   download of colorama through Nexus is 404
```

Evidence (trimmed):

```text
cold install --locked: ak.internal -> clients: pixi 200 x1 0.1MB; Nexus 401 x43 0.0MB; Nexus 200 x43 101.2MB; total 87 req 101.4 MB
warm install --locked: ak.internal -> clients: pixi 200 x1 0.1MB; total 1 req 0.1 MB
t=0- Nexus noarch/repodata.json.bz2 just revalidated: 29225962 bytes, colorama records 8
allowlist ON: PUT /api/v1/repositories/conda-virtual/allowlist -> HTTP 200 {"enabled":true,"entry_count":43}
t=+0s download colorama through Nexus: HTTP 404 (downloads are not cached metadata: AK answers at once)
t=+4s pixi add colorama through Nexus: exit 0: Added colorama >=0.4.6,<0.5
PROPAGATION: Nexus served the filtered noarch index 120 s after allowlist ON (3054 bytes, colorama records 0; metadataMaxAge 2 min, polled every 5 s with If-None-Match)
download noarch/colorama-0.4.6-pyhd8ed1ab_1.conda through Nexus: HTTP 404 1357; body: <title>404 - Sonatype Nexus Repository
```

```console
$ pixi add --no-install colorama      # through Nexus, after propagation
Error:   × failed to solve requirements of environment 'default' for platform 'linux-
  │ 64'
  ├─▶   × failed to solve the environment
  │   
  ╰─▶ Cannot solve the request because of: No candidates were found for
      colorama *.
```

Notes:

- **Propagation delay: 120 s with `metadataMaxAge` 2 minutes.** The scenario makes Nexus revalidate
  right before it turns the allowlist on, so this is the worst case for that TTL. With a day as
  the TTL, it is up to a day.
- During that window the index and the download disagree: the solve still finds `colorama` (Nexus's
  cached index), but the file is 404 at once (Nexus has no copy and Artifact Keeper refuses it).
- Each package costs Nexus two requests to Artifact Keeper (a 401 challenge, then the
  credentials): `Nexus 401 x43`, `Nexus 200 x43`.
- The PyPI wheel (`humanize`) still comes from `ak.internal` directly: Nexus is the conda source only.

## S2: public source down

What it proves: when conda-forge is unreachable from Artifact Keeper, clients behind Nexus and
clients of Artifact Keeper keep installing and solving from what was cached. The scenario points
the `conda-forge` remote at `https://conda-forge.invalid/conda-forge` for 315 s, longer than the
remote's cache TTL (300 s), and restores it.

```console
$ make scenario-S2
```

```text
PASS         S2   install --locked through Nexus succeeds with conda-forge unreachable (1.6 s, served from Nexus's cache)
PASS         S2   AK direct, inside AK's cache TTL: install --locked succeeds (packages from AK's own proxy cache)
PASS         S2   AK direct, inside AK's cache TTL: a package AK has cached is served by URL (noarch/ca-certificates-2026.7.22-hbd8a1cb_0.conda: HTTP 200)
PASS         S2   AK direct, inside AK's cache TTL: a package nobody has cached fails (noarch/formulas-plot-1.3.3-he70b927_0.conda: HTTP 404)
PASS         S2   AK direct, inside AK's cache TTL: virtual repodata is served from AK's cached conda-forge index (HTTP 200; fresh solve exit 0)
PASS         S2   AK direct, after AK's cache TTL: install --locked succeeds (packages from AK's own proxy cache)
PASS         S2   AK direct, after AK's cache TTL: a package AK has cached is served by URL (noarch/ca-certificates-2026.7.22-hbd8a1cb_0.conda: HTTP 200)
PASS         S2   AK direct, after AK's cache TTL: a package nobody has cached fails (noarch/formulas-plot-1.3.3-he70b927_0.conda: HTTP 404)
PASS         S2   AK direct, after AK's cache TTL: virtual repodata is served from AK's cached conda-forge index (HTTP 200; fresh solve exit 0)
PASS         S2   fresh solve through Nexus succeeds during the block (32.7 s)
PASS         S2   restored: upstream_url is https://conda.anaconda.org/conda-forge again and a never-cached package pulls (HTTP 200)
```

Evidence (trimmed):

```text
AK conda-forge cache TTL: 300 s
block has lasted 315 s (TTL 300 s)
2b. AK direct GET conda-virtual/noarch/repodata.json: HTTP 200 192543870 2.199883
2b. AK direct GET conda-virtual/noarch/formulas-plot-1.3.3-he70b927_0.conda: HTTP 404 {"code":"NOT_FOUND","message":"Artifact not found in any member repository"}
2b. response headers, conda-virtual/channeldata.json: cache-control: private, max-age=60 etag: "d0865438..."
2b. AK direct: fresh solve (cold client): exit 0, 29.9 s
3. Nexus: never-cached noarch/formulas-plot-1.3.3-he70b927_0.conda: HTTP 404 1357
4. AK direct GET conda-virtual/noarch/formulas-plot-1.3.3-he70b927_0.conda after restore: HTTP 200
```

Notes:

- The virtual channel did not answer 502 after the TTL. Artifact Keeper tried conda-forge, failed,
  and served its cached index under a stale-if-error grace (backend log: `revalidation failed;
  serving stale within stale-if-error grace`). The grace is 3600 s past the TTL
  (`STALE_IF_ERROR_GRACE_SECS`), so a client sees a 502 for the index only when conda-forge has
  been unreachable for TTL + 1 hour. The responses carry nothing that says they are stale (no
  `Age`, no `Warning`; the same ETag); only the backend log does.
- A package nobody has cached is 404, not 502. pixi reports it as a missing file.

## S3: curated channel down

What it proves: with Artifact Keeper itself stopped for 90 s, clients behind Nexus still install
and solve from Nexus's cache; only files Nexus never fetched fail.

```console
$ make scenario-S3
```

```text
PASS         S3   install --locked through Nexus succeeds while Artifact Keeper is down (1.2 s, 43 packages from Nexus's cache)
PASS         S3   project/ as is fails only on its PyPI wheel, which is fetched from ak.internal, not through Nexus: "HTTP status server error (502 Bad Gateway) for url (https://ak.internal/pypi/pypi-remote/simple/humanize/humanize-4.16.0-py3-none-any.whl)"
PASS         S3   fresh solve through Nexus succeeds from Nexus's stale metadata while AK is down (11.5 s)
PASS         S3   a package Nexus never fetched is refused while AK is down (HTTP 404: Remote Auto Blocked until 2026-10-08T21:03:16.310Z )
PASS         S3   after restart: backend healthy, a fresh pull through Nexus works again (0 s after healthy)
```

Evidence (trimmed):

```text
AK direct during the outage: GET conda-virtual/noarch/repodata.json: HTTP 502
2. Nexus: fresh solve (cold client, Nexus metadata invalidated, AK down): exit 0, 11.5 s
4. backend started after 92 s down; healthy after 31 s (healthy)
```

Notes:

- The fresh solve ran after Nexus's metadata cache was invalidated: Nexus tried Artifact Keeper,
  got 502, and served its stale copy.
- Nexus auto-blocks the remote for about 40 s after failures and answers `404 Remote Auto
  Blocked until ...` for files it does not have. Once Artifact Keeper was healthy, the next pull
  worked at once.
- The outage scenarios use a copy of `project/` without its PyPI dependency for the conda checks,
  because pixi fetches PyPI from `ak.internal` directly.

## S4: merged in the artifact manager

What it proves: the counter-example. When Nexus merges `conda-virtual` with a public source in a
group and clients use the group, the allowlist and the name guard are gone, and a file name clash
breaks installs. Then the fix: the public source as a member of Artifact Keeper's virtual
channel, behind a plain Nexus proxy. Each check passes when the expected behaviour is seen;
"(bad)" marks what the merge in Nexus causes, "(good)" the fix.

```console
$ make scenario-S4
```

```text
PASS         S4   (bad) the allowlist is undone by the merge: with it ON, colorama has 0 records through ak-virtual and 8 through the group, downloads (HTTP 200) and "Added colorama >=0.4.6,<0.5"
PASS         S4   (bad) dependency confusion: an unpinned acme-core through the group locks fake-forge's 99.0.0 (no name ownership in the merge)
PASS         S4   (bad) file name clash: the group's record and its bytes come from different members, pixi refuses: "hash mismatch when extracting http://scn-nexus:8081/conda/ c... expected 9ac9a20fc882..., got eb370de69a76..."
PASS         S4   (good) as a member of AK's virtual the hostile source is dropped by the name guard: acme-core ["1.0.0","1.0.1","1.0.1791387539","1.0.1791387567","1.0.1791483478"], unpinned lock 1.0.1791483478
PASS         S4   (good) the clash file name installs: record and bytes are both conda-internal's
```

Evidence (trimmed):

```text
group merged linux-64/repodata.json.bz2 built: HTTP 200, 61.2 MB in 64 s, 790845 records
merged-fake offers acme-core ["1.0.0","1.0.1","1.0.1791387539","1.0.1791387567","1.0.1791483478","99.0.0"]; unpinned lock: exit 0, 10.3 s, acme-core 99.0.0
acme-core-1.0.0-pyh4616a5c_0.conda: conda-internal sha256 eb370de69a7640c3, fake-forge 9ac9a20fc882a5e2; merged-fake record 9ac9a20fc882a5e2, merged-fake bytes eb370de69a7640c3
scn-virtual through Nexus: acme-core ["1.0.0","1.0.1","1.0.1791387539","1.0.1791387567","1.0.1791483478"]; record for acme-core-1.0.0-pyh4616a5c_0.conda sha256 eb370de69a7640c3 (ours eb370de69a7640c3)
```

```console
$ pixi install --locked      # channel: the Nexus group merged-fake
Error:   × failed to fetch acme-core-1.0.0-pyh4616a5c_0.conda
  ├─▶ failed to interact with the package cache layer.
  ╰─▶ hash mismatch when extracting http://scn-nexus:8081/conda/
      conda-virtual/noarch/acme-core-1.0.0-pyh4616a5c_0.conda to /
      cache/rattler/pkgs/.acme-core-1.0.0-pyh4616a5c_0lTdWzS: expected
      9ac9a20fc882a5e2aba658c90b42d9626cb4713cb18ffef1c5534dcb7272ebda, got
      eb370de69a7640c3c722884801b5ee9a997ce8d39133d23b4807a74ddec13edc, total
      size 8563 bytes
```

Notes:

- The group's merge is a union: the highest version wins, whichever member it comes from. On a
  file name clash the repodata record comes from the last member and the bytes from the first.
- A client whose channel is the group needs a mirror back into the group, because Artifact
  Keeper's `info.base_url` is host-relative (#4580) and Nexus passes it through.
- Groups cache their merge. During this work the group `merged` once answered
  `linux-64/repodata.json.bz2` with `{"packages":{}}` (54 bytes), and pixi said `No candidates
  were found for python 3.12.*`; `invalidate-cache` on the group rebuilt it. The scenario now
  invalidates and warms each group first and records an empty merge if it sees one.
- A merge of conda-forge-sized indexes takes about a minute per subdir and an 8 GB heap.

## S5: CVE on proxy

What it proves: what happens today when a package with a known CVE is pulled through the
governed channel with scan-on-proxy blocking turned on for `conda-forge` (`scan_on_proxy`,
`fail_closed`, block at `high` and above). The package is `certifi 2022.12.7` (CVE-2023-37920,
high; CVE-2024-39689, low): 150 KB, and it depends only on Python.

```console
$ make scenario-S5
```

```text
BLOCKED(#4097) S5   pixi install of certifi 2022.12.7 is refused on download: installed; conda scan_on_proxy is "accepted" (setting stored, proxied downloads served unscanned), no X-AK-Scan header
PASS         S5   the conda-forge proxy-scans view lists noarch/certifi-2022.12.7-pyhd8ed1ab_0.conda as vulnerable with its CVEs (CVE-2023-37920 CVE-2024-39689)
PASS         S5   the security dashboard's policy_violations_blocked goes up (0 -> 1; #4380 counts proxied content with a blocking verdict)
BLOCKED(#4097) S5   with a stored vulnerable verdict the next pull is refused: HTTP 200  and pixi installs: the conda download path does not consult the verdict, while the dashboard counts it as blocked
PASS         S5   a clean package that shares nothing with it (tzdata) installs through the same channel
```

Evidence (trimmed):

```text
GET /api/v1/formats: conda scan_on_proxy = accepted
PUT conda-forge security (scan_on_proxy, fail_closed, block >= high): HTTP 200 {"scan_on_proxy":true,"proxy_scan_action":"fail_closed","block_on_policy_violation":true,"severity_threshold":"high"}
pixi install (certifi ==2022.12.7, cold cache, conda-virtual): exit 0, 30.3 s: The default environment has been installed.
POST proxy-scans/rescan noarch/certifi-2022.12.7-pyhd8ed1ab_0.conda: HTTP 200 {"state":"vulnerable","findings_count":2,"critical_count":0,"high_count":1,"max_severity":"high","package_count":1}
    high	CVE-2023-37920	certifi	2022.12.7	2023.7.22
    low	CVE-2024-39689	certifi	2022.12.7	2024.7.4
dashboard policy_violations_blocked: 0 -> 1
after the verdict: GET certifi-2022.12.7-pyhd8ed1ab_0.conda: conda-virtual: HTTP 200 ; conda-forge: HTTP 200
```

Notes:

- On this backend scan-on-proxy is `accepted` for conda, not `enforced`: the setting is stored, and
  proxied conda downloads are served without the gate (artifact-keeper#4097, out of scope for this
  walkthrough). There is no pixi error to show yet.
- The scanner does flag the package: a rescan of the cached bytes
  (`POST /api/v1/repositories/conda-forge/security/proxy-scans/rescan`) records the verdict and the
  CVEs, and the per-repository proxy-scans view lists them.
- The dashboard then counts the package in `policy_violations_blocked`, although the next pull is
  still served. For conda, that number says what the policy would block, not what was blocked.
- Hosted packages are scanned on upload and gated at promotion ([Step 4](4-promote-with-gates.md)); that is unaffected.

## S6: allowlist from a pull request

What it proves: the CI loop. A pull request changes a dependency;
[`scenarios/allowlist-ci.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-conda-channel-pixi/scenarios/allowlist-ci.sh)
locks, checks, applies the allowlist and verifies. The new package installs through
`conda-virtual` at once and through Nexus after the TTL; a package the pull request removes is
"not found".

The job, for one project directory:

```console
$ scenarios/allowlist-ci.sh all path/to/project      # or: lock | check | apply | verify
```

- **lock** solves against `scn-virtual-ci`, an unfiltered twin of `conda-virtual` (same members,
  no allowlist), through a pixi mirror. The alternative, turning the allowlist off for the solve,
  opens all of conda-forge to every consumer of the shared channel for that time. Because Artifact
  Keeper's `info.base_url` is host-relative (#4580), pixi writes the twin's name into the lock; the
  job rewrites those URLs to `conda-virtual` (same files, same sha256).
- **check** refuses a lock with any URL outside `conda-virtual`, `conda-internal` and the PyPI
  proxy, and prints what the change adds and removes.
- **apply** `PUT`s the allowlist from the lock. The list is one per virtual channel, so a real job
  passes every consumer's lock (`EXTRA_LOCKS`) and applies their union, on merge.
- **verify** runs `pixi install --locked` through `conda-virtual` with a cold cache.

```console
$ make scenario-S6
```

```text
PASS         S6   PR 1: allowlist-ci.sh locks colorama against the unfiltered twin (lock URL conda-virtual/noarch/colorama-0.4.6-pyhd8ed1ab_1.conda), sets the allowlist, and pixi install --locked through conda-virtual passes
PASS         S6   PR 1: through Nexus, after Nexus revalidated (91 s), the new lock installs including colorama
PASS         S6   PR 2: allowlist-ci.sh drops colorama from the lock and the allowlist, adds toolz, and the project installs through conda-virtual
PASS         S6   PR 2: through conda-virtual, colorama is at once "No candidates were found for colorama *" and its file 404
PASS         S6   PR 2: through Nexus, after the TTL, colorama is "No candidates were found for colorama *"
PASS         S6   PR 2 caveat: Nexus still serves the colorama file it cached in PR 1 (HTTP 200): Nexus does not revoke cached files, only the index is filtered
```

The job's output for PR 2:

```text
allowlist-ci: lock: pixi lock against https://ak.internal/conda/scn-virtual-ci (as conda-virtual)
  - (conda) colorama  0.4.6 pyhd8ed1ab_1
  + (conda) toolz     1.1.0 pyhd8ed1ab_1
allowlist-ci: lock: rewrote 2 URLs https://ak.internal/conda/scn-virtual-ci/ -> https://ak.internal/conda/conda-virtual/ (#4580 workaround)
allowlist-ci: check: lock ok (44 conda packages, all on conda-virtual or conda-internal)
allowlist-ci:   + toolz 1.1.0
allowlist-ci:   - colorama 0.4.6
allowlist-ci: apply: PUT /api/v1/repositories/conda-virtual/allowlist -> HTTP 200 {"enabled":true,"entry_count":44}
allowlist-ci: verify: pixi install --locked through conda-virtual (cold cache)
```

Notes:

- Through Nexus, both changes took about two minutes to show (123 s and 126 s after the job
  started), the 2-minute TTL plus the time of the job itself.
- Nexus keeps package files it already cached. A package removed from the allowlist disappears
  from the index through Nexus, so no new solve picks it, but a lock that already names it still
  installs through Nexus. Revoking a file there means deleting it in Nexus too.

## S7: big and malformed index

What it proves: how much index each solve reads through the merged virtual channel; that the
virtual serves no CEP-16 shards (artifact-keeper#4577); and that a public record with
`track_features` as a list (the shape that broke Artifactory) does not break the merged index.

```console
$ make scenario-S7
```

```text
PASS         S7   monolithic: the merged index per linux-64 solve is 109.2 MB of repodata.json.zst (see evidence for every encoding)
PASS         S7   pixi: one cold-cache solve through conda-virtual reads 194.5 MB of index in 29.5 s
PASS         S7   shards: the hosted member serves CEP-16 shards (200), the virtual does not (404, artifact-keeper#4577): every pixi solve through the virtual downloads the full index
PASS         S7   malformed public record: scn-virtual still serves a valid merged linux-64 index in json, zst and bz2 (track_features served as ["mkl","debug"])
PASS         S7   pixi still solves through scn-virtual with the malformed record in the merge
PASS         S7   pixi (rattler) accepts the list-shaped track_features and locks scn-trackfeat
PASS         S7   Nexus passes the list-shaped track_features through too: the group merged-fake answers HTTP 200 and keeps it (["mkl","debug"])
```

The merged index (allowlist off), per subdir and encoding:

| File | Size | Time | Records |
|---|---|---|---|
| `noarch/repodata.json` | 192.6 MB | 2.0 s | 382,430 |
| `noarch/repodata.json.zst` | 35.0 MB | 1.3 s | |
| `noarch/repodata.json.bz2` | 29.2 MB | 10.3 s | |
| `linux-64/repodata.json` | 458.6 MB | 4.4 s | 790,845 |
| `linux-64/repodata.json.zst` | 74.3 MB | 2.7 s | |
| `linux-64/repodata.json.bz2` | 61.5 MB | 24.8 s | |
| `channeldata.json` | 23.7 MB | 0.7 s | |

What pixi fetched for one cold-cache solve (Caddy log; the 0.0 MB lines are `HEAD` requests):

```text
200 x1 0.0 MB /conda/conda-virtual/linux-64/repodata.json.bz2
200 x1 0.0 MB /conda/conda-virtual/linux-64/repodata.json.zst
200 x1 0.0 MB /conda/conda-virtual/noarch/repodata.json.bz2
200 x1 0.0 MB /conda/conda-virtual/noarch/repodata.json.zst
200 x1 0.0 MB /conda/conda-internal/linux-64/repodata_shards.msgpack.zst
200 x1 0.0 MB /conda/conda-internal/noarch/repodata_shards.msgpack.zst
200 x1 0.0 MB /conda/conda-virtual/linux-64/current_repodata.json
200 x1 23.7 MB /conda/conda-virtual/channeldata.json
200 x1 35.0 MB /conda/conda-virtual/noarch/repodata.json.zst
200 x1 61.5 MB /conda/conda-virtual/linux-64/repodata.json.bz2
200 x1 74.3 MB /conda/conda-virtual/linux-64/repodata.json.zst
404 x1 0.0 MB /conda/conda-virtual/linux-64/repodata_shards.msgpack.zst
404 x1 0.0 MB /conda/conda-virtual/noarch/repodata_shards.msgpack.zst
```

Evidence (trimmed):

```text
GET conda-virtual/noarch/repodata_shards.msgpack.zst: HTTP 404 Sharded repodata (CEP-16) is only available for local/hosted conda repositories; use repodata.json
GET conda-internal/noarch/repodata_shards.msgpack.zst: HTTP 200 176
fake upstream linux-64 record: {"name":"scn-trackfeat","version":"1.0.0","track_features":["mkl","debug"]}
scn-virtual linux-64/repodata.json: HTTP 200, valid JSON, 790846 records, scn-trackfeat track_features: ["mkl","debug"]
pixi lock that selects scn-trackfeat (rattler must parse the record): exit 0: locked scn-trackfeat-1.0.0-0.conda
Nexus group merged-fake linux-64/repodata.json.bz2: HTTP 200 61161195 52.361092; scn-trackfeat track_features: ["mkl","debug"]
```

Notes:

- A conda or mamba client without shards reads about 109 MB compressed (651 MB of JSON) per
  linux-64 solve through the virtual channel. pixi read 133 MB in one run and 194.5 MB in the
  other: in the second it fetched `linux-64` both as `.zst` and as `.bz2`. It also reads
  `channeldata.json` (23.7 MB). With the allowlist on, the same index is a few kilobytes (Step 10).
- Shards come only from the hosted member (`conda-internal`); for the merged channel pixi falls
  back to `repodata.json.zst`. Through Nexus there are no shards and no `.zst` at all (pixi uses `.bz2`).
- Artifact Keeper passes the list-shaped `track_features` through unchanged; it neither rejects
  nor normalises it. pixi 0.81 accepts it. Clients that expect a string (the Artifactory case) are
  not tested here.
- The malformed record reaches Artifact Keeper from the gate's fake upstream, not from
  `scn-fake-forge`: Artifact Keeper refuses remote upstreams on private addresses except
  `AK_SSRF_ALLOW_PRIVATE_CIDRS` (here the gate's host only). `scn-fake-forge` serves it to Nexus.

## Nexus Community Edition in front of Artifact Keeper

From the [spike](https://github.com/artifact-keeper/walkthroughs/blob/main/private-conda-channel-pixi/scenarios/README.md)
and the scenarios above.

| | Nexus CE 3.96.4 | Caveat |
|---|---|---|
| Licence | none; accept the EULA by API | 40,000 components or 100,000 requests per day, then no new components |
| Conda proxy, hosted, group | yes (group and hosted since 3.92) | a group over conda-forge-sized indexes needs an 8 GB heap; an OOM also closes the embedded H2 database |
| `repodata.json`, `.bz2`, `channeldata.json` | yes | |
| `repodata.json.zst`, CEP-16 shards, `current_repodata.json` | no: 404 from Nexus, never asked upstream | pixi falls back to `.bz2`; the bz2 decode is part of every solve |
| Upstream auth | basic (`consumer:<token>`) | bearer is accepted by the API and never sent; every fetch is a 401 then a 200 |
| Conditional GET upstream and to clients | yes | Artifact Keeper answers 304 for repodata, 200 with the full body for packages (#4579) |
| Policy propagation (allowlist) | after `metadataMaxAge` (S1: 120 s at 2 minutes) | cached package files are never revoked (S6) |
| Name guard | holds through a plain proxy (S1) | gone in a group (S4) |
| Serves from cache when Artifact Keeper is down | metadata and packages, also stale (S3) | never-fetched files: `404 Remote Auto Blocked` |
| Serves from cache when conda-forge is down | yes, and so does Artifact Keeper (S2) | |
| Group merge | union, highest version wins | no name ownership; file name clash: record from the last member, bytes from the first; the merge is cached and was once served empty |
| `info.base_url` | passed through | a client using a group needs a mirror back into it (#4580) |
| 404 body | Nexus's HTML page | not Artifact Keeper's message |
| First proxy to a private host | blocked until the SSRF allow list, the truststore and the EULA are set | all three by API in `nexus/bootstrap.sh` |

## What this does not show

- **ProGet.** ProGet Free needs a licence key registered against a person's name and e-mail
  address before it serves anything; the spike stopped there. Its documentation also says Free
  caches no metadata (no fresh solves when Artifact Keeper is down) and connects only to public
  repositories.
- **Artifactory and Nexus Pro.** Not tested: no licence. The `track_features` case that broke
  Artifactory is checked only for Artifact Keeper, Nexus CE and pixi.
- **Shards through the virtual channel** (artifact-keeper#4577) and **shards or `.zst` through
  Nexus**: neither exists today, so the cost of a solve through the merged channel is the full index.
- **Scan-on-proxy enforcement for conda** (artifact-keeper#4097): S5 shows the setting, the
  scanner's verdict and the dashboard, not a refused download.
- **Scale.** One client, one host; nothing near Nexus CE's daily limits.
- **Revoking a cached file in Nexus** is a manual delete; no scenario automates it.
