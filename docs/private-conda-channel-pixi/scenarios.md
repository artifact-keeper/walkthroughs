# Scenarios: behind Nexus or ProGet, outages, merges

The nine steps and the allowlist have pixi talking to Artifact Keeper directly. That is the
cleanest shape, and it is not the shape most of the companies this walkthrough is for can
choose. They already pay for an artifact manager (Artifactory, Nexus, ProGet: the server every
build goes through and every audit asks about), it is mandated, and the question they ask is
whether any of this survives being put behind it. We did not want to answer that with a diagram.

So these scenarios put a real artifact manager between pixi and Artifact Keeper and check what
still holds: the lock, the name guard, the allowlist, and installs when something is down. We
used Sonatype Nexus Repository Community Edition and Inedo ProGet Free because both are free and
both support conda, so anyone can rerun this. Artifactory's conda support is a paid feature, so
it is named here as the category and not tested. One scenario does the opposite of what we
recommend on purpose: it merges the channels in the artifact manager instead of in Artifact
Keeper, to show what that costs. Two more take things away, first conda-forge, then Artifact
Keeper itself, and watch what the developer sees. The point of all of it is that "does it hold
up" is answered by a script that prints pass or fail, not by us.

Each scenario is one script under
[`scenarios/`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-conda-channel-pixi/scenarios/).
It prints one `PASS`, `FAIL` or `BLOCKED(<issue>)` line per check, in the same format as the
[gates](results.md), then an evidence block with the status codes, timings and client messages
behind each line. Every change it makes to the registry is written to a journal first and put
back before it exits, also when a check fails or the run is killed (`make scenarios-restore`
replays a journal by hand). Logs go to `~/.cache/ak-scenarios/`.

The short version of what we learned, before the detail:

- **Merge in Artifact Keeper, not in the artifact manager.** Through a plain proxy everything
  holds. Through a merge in Nexus or ProGet, the allowlist and the name guard are gone, a
  squatted package name wins, and a file name clash either breaks the install or installs the
  wrong bytes silently, depending on the product.
- **Behind a cache, policy is as fresh as the cache.** An allowlist change reaches Nexus clients
  after its metadata TTL (120 seconds at the two minutes we set) and ProGet clients after about
  ten minutes, with no setting to change. Files the cache already holds are never revoked.
- **Outages are survivable on cached content.** With Artifact Keeper stopped, locked installs
  through either product still work. With conda-forge unreachable, Artifact Keeper keeps serving
  its own cache for an hour past its TTL, so nobody behind it notices.
- **The real client refuses a vulnerable package.** With scan-on-proxy on, pixi gets a 403 on a
  package with a known CVE, the registry's dashboard and per-repository view show why, and a clean
  package next to it still installs.

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
| S5 CVE on proxy (1.11.0 backend, 2026-10-09) | 5 | 0 | 0 | 71 s |
| S6 allowlist from a pull request | 6 | 0 | 0 | 257 s |
| S7 big and malformed index | 7 | 0 | 0 | 305 s |
| **Total** | **48** | **0** | **0** | **1802 s** |

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

What it proves: what a developer sees when a package with a known CVE is pulled through the
governed channel with scan-on-proxy blocking turned on for `conda-forge` (`scan_on_proxy`,
`fail_closed`, block at `high` and above). The package is `certifi 2022.12.7` (CVE-2023-37920,
high; CVE-2024-39689, low): 150 KB, and it depends only on Python, so the refusal cannot be
blamed on anything else. This scenario is also the one that found two backend bugs while we
wrote it, which is the reason scenarios exist; both are fixed in 1.11.0 and the notes say what
they were.

```console
$ make scenario-S5
```

```text
PASS         S5   pixi refuses to install certifi 2022.12.7: "HTTP status client error (403 Forbidden) for url (https://ak.internal/conda/conda-virtual/noarch/certifi-2022.12.7-pyhd8ed1ab_0.conda)"
PASS         S5   the conda-forge proxy-scans view lists noarch/certifi-2022.12.7-pyhd8ed1ab_0.conda as vulnerable with its CVEs (CVE-2023-37920 CVE-2024-39689)
PASS         S5   the security dashboard's policy_violations_blocked goes up (0 -> 1; #4380 counts proxied content with a blocking verdict)
PASS         S5   with the verdict stored, the next pull is refused: HTTP 403 ; pixi: "HTTP status client error (403 Forbidden) for url (https://ak.internal/conda/conda-virtual/noarch/certifi-2022.12.7-pyhd8ed1ab_0.conda)"
PASS         S5   a clean package that shares nothing with it (tzdata) installs through the same channel
```

Evidence (trimmed; 1.11.0 backend with the allowlist, the conda scan-on-proxy gate and the
contents-only grading, 2026-10-09):

```text
GET /api/v1/formats: conda scan_on_proxy = enforced
PUT conda-forge security (scan_on_proxy, fail_closed, block >= high): HTTP 200 {"scan_on_proxy":true,"proxy_scan_action":"fail_closed","block_on_policy_violation":true,"severity_threshold":"high"}
pixi install (certifi ==2022.12.7, cold cache, conda-virtual): exit 1, 30.1 s: HTTP status client error (403 Forbidden) for url (https://ak.internal/conda/conda-virtual/noarch/certifi-2022.12.7-pyhd8ed1ab_0.conda)
POST proxy-scans/rescan noarch/certifi-2022.12.7-pyhd8ed1ab_0.conda: HTTP 200 {"state":"vulnerable","findings_count":2,"critical_count":0,"high_count":1,"max_severity":"high","package_count":1}
    high	CVE-2023-37920	certifi	2022.12.7	2023.7.22
    low	CVE-2024-39689	certifi	2022.12.7	2024.7.4
dashboard policy_violations_blocked: 0 -> 1
after the verdict: GET certifi-2022.12.7-pyhd8ed1ab_0.conda: conda-virtual: HTTP 403 ; conda-forge: HTTP 403 
pixi install tzdata (no dependencies, cold cache): exit 0: The default environment has been installed.
```

Notes:

- With the scan-on-proxy gate for conda (`scan_on_proxy: enforced`), the vulnerable package is
  refused on download: 403 through `conda-virtual` and through `conda-forge`, and pixi stops with
  `HTTP status client error (403 Forbidden)`. The verdict is stored per digest, so the next pull
  is refused at once.
- The scanner's verdict and CVEs are in the per-repository proxy-scans view; the dashboard's
  `policy_violations_blocked` goes up.
- `fail_closed` is the design: a package whose scan could not run is refused (423) rather than
  served. The first time we ran this, scan-on-proxy for conda was stored but never enforced
  (certifi installed, and the dashboard counted it as blocked anyway); that is
  [artifact-keeper#4585](https://github.com/artifact-keeper/artifact-keeper/issues/4585), fixed
  in 1.11.0. The second run refused certifi and also locked `tzdata`, because a completed scan
  that catalogs nothing (tzdata ships data files only) counted as inconclusive, and for conda
  that describes most of the channel; that is
  [artifact-keeper#4594](https://github.com/artifact-keeper/artifact-keeper/issues/4594), also
  fixed in 1.11.0: a scan that ran to completion with no findings is `clean`, with a
  `components_cataloged` count in the proxy-scans view so you can see what the grade rests on.
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

## Through ProGet Free (AM=proget)

Run details: S1, S2 and S4 on 2026-10-09 (01:00 to 02:20 UTC) against the allowlist build of
the 1.11.0 backend; S3 and S6 re-run the same day (13:38 to 15:00 UTC) against the build with the
conda scan-on-proxy gate. ProGet 26.0.12.24, Free edition, licensed; pixi 0.81.0.

The same scenarios with Inedo ProGet Free in front instead of Nexus. ProGet's free edition needs
a licence key (requested from Inedo with a name and an e-mail address, entered once in the UI);
everything else is set up by `make scenarios-up-proget`.

```console
$ make scenarios-up-proget     # ProGet beside the stack, configured by API (plus two UI clicks by Playwright)
$ make scenarios AM=proget     # S1 S2 S3 S4 S6 through ProGet
$ make scenario-S4 AM=proget
$ make scenarios-down-proget
```

What `scenarios-up-proget` sets up:

| Piece | What |
|---|---|
| `scn-proget` | ProGet 26.0.12 (Free), one container with an embedded PostgreSQL, on `ak-conda-net`. Connectors `ak-virtual` (of `conda-virtual`), `ak-internal`, `ak-scn-virtual` (of `scn-virtual`), `cf-direct` (conda.anaconda.org), `scn-fake` (of `scn-fake-forge`); one feed per connector, and feeds `merged` = [ak-virtual, cf-direct] and `merged-fake` = [ak-virtual, scn-fake]. Upstream credential: basic auth, `consumer` and the consumer token as password. |
| Lock-down | Out of the box the Anonymous user is an administrator. `proget/bootstrap.sh` creates the API key while that is still true, then `proget/secure.py` changes the Admin password and clicks "Remove Anonymous Access" (Free has no API for either). Anonymous keeps read access, so pixi needs no credential for ProGet. |
| pixi config | [`proget/pixi-config.toml`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-conda-channel-pixi/scenarios/proget/pixi-config.toml): mirrors send every `https://ak.internal/conda/...` request to a ProGet feed; the lockfile keeps the `ak.internal` URLs |

**ProGet does not proxy repodata; it keeps its own index of the channel.** The first metadata
request for a feed makes ProGet download `channeldata.json` and the `repodata.json.bz2` of every
subdirectory (12 for `conda-virtual`, about 322 MB) into a local index (1.6 GB). It updates that
index on a client request once the index is about 10 minutes old, and each update downloads
everything again. There is no setting for this in the free edition. Every `repodata.json` and
`.bz2` a client gets is generated from that index for that request.

### Results, ProGet

| Scenario | PASS | FAIL | Time |
|---|---|---|---|
| S1 behind ProGet | 13 | 0 | 2116 s |
| S2 public source down | 5 | 0 | 376 s |
| S3 curated channel down | 7 | 0 | 1173 s |
| S4 merged in the artifact manager | 6 | 0 | 1112 s |
| S6 allowlist from a pull request | 6 | 0 | 1261 s |
| **Total** | **37** | **0** | **6038 s** |

"(bad)" marks a check that passes when the bad behaviour is seen, as in S4 above.

### S1 through ProGet

```text
PASS         S1   [proget] (bad) 0: install --locked through a connector whose index was never built fails with 404 ("HTTP status client error (404 Not Found) for url (http://scn-proget/ conda/s1-cold/linux-64/openssl-3.6.4-h781a0a9_0.conda)"); package requests do not build it
PASS         S1   [proget] 0: after one metadata request built the index (448 s), the same install --locked works
PASS         S1   [proget] 1 cold: pixi install --locked through ProGet (16.6 s; AK -> ProGet 101.2 MB, ProGet -> pixi 101.2 MB)
PASS         S1   [proget] 1 warm: pixi install --locked through ProGet (11.6 s; AK -> ProGet 0 MB, ProGet -> pixi 101.2 MB)
PASS         S1   [proget] 2: pixi.lock unchanged by install --locked through ProGet (keeps the https://ak.internal URLs)
PASS         S1   [proget] 3: scn-virtual through ProGet offers only the hosted acme-core ["1.0.0","1.0.1","1.0.1791387539","1.0.1791387567","1.0.1791483478"] (99.0.0 dropped by AK's name guard)
PASS         S1   [proget] 3: unpinned 'acme-core = "*"' solved through ProGet locks the hosted 1.0.1791483478, not 99.0.0
PASS         S1   [proget] 4: a fresh solve through ProGet works (144.6 s) and installs, though ProGet drops 'noarch' from every record (12 lock entries say noarch: false; rattler links them as noarch from the package itself)
PASS         S1   [proget] 5: the allowlist reaches ProGet clients 462 s after it is set, with nobody touching ProGet (index refreshed on a request once ~10 min old, then rebuilt)
PASS         S1   [proget] 5: inside the window, pixi add colorama through ProGet still succeeds from the old index ("Added colorama >=0.4.6,<0.5")
PASS         S1   [proget] 5: after propagation, pixi add colorama through ProGet fails: "No candidates were found for colorama *"
PASS         S1   [proget] 5: download of colorama through a feed that never cached it is 404
PASS         S1   [proget] 5 caveat: a feed that cached colorama before the allowlist keeps listing it (1 records) and serving it, so pixi add still works there ("Added colorama >=0.4.6,<0.5"): ProGet merges cached packages into the feed's index
```

Evidence (trimmed):

```text
0. index built by metadata requests: 448 s, 382470 noarch records, index 1597 MB; ProGet -> AK: ProGet  x68 0.0MB; ProGet 200 x102 653.0MB; total 170 req 653.0 MB
cold install --locked: ak.internal -> clients: pixi 200 x1 0.1MB; ProGet 200 x43 101.2MB; total 44 req 101.4 MB
warm install --locked: ak.internal -> clients: pixi 200 x1 0.1MB; total 1 req 0.1 MB
4. noarch/repodata.json AK vs ProGet: 382485 records from AK, 5 missing through ProGet (ps2ff-v1.4-py_0.tar.bz2, pysbol3-v1.0.1-pyhd8ed1ab_0.tar.bz2, universal_pathlib-v0.0.2-pyhf1ccde4_0.tar.bz2, vounwarp-v1.0-py_0.tar.bz2, rubin-scheduler-3.0.0rc0-pyhd8ed1ab_0.conda); fields dropped: noarch x382473, license_family x361777, track_features x525
4. fresh solve (conda-only copy, cold client): exit 0, 144.6 s; ProGet served: linux-64/repodata_shards.msgpack.zst 404 0.0 MB 0.0 s; noarch/repodata_shards.msgpack.zst 404 0.0 MB 0.0 s; noarch/repodata.json.bz2 200 28.9 MB 31.0 s; linux-64/repodata.json.bz2 200 60.9 MB 73.6 s; 
4. the ProGet-solved lock: 12 records say 'noarch: false' (an AK-solved lock has none); install exit 0; import typing_extensions (noarch: python): ok
5. t=0- fresh feed: colorama records 8; index age 176 s
5. t=+145s pixi add colorama through ProGet: exit 0: Added colorama >=0.4.6,<0.5
5. t=+462s the fresh feed lists colorama x0 (polled every 30 s with a plain GET of noarch/repodata.json); index written 01:38:23
```

Notes:

- **A fresh ProGet cannot serve `install --locked`.** Package requests do not build the index, so
  every package is 404 until something asks for metadata; then the build takes minutes (448 s
  here, and two overlapping builds fetched 653 MB from Artifact Keeper).
- **Propagation: 462 s with nobody touching ProGet.** The index was 176 s old when the allowlist
  went on; ProGet updated it on a request at about 10 minutes and the rebuild took a few more.
  The worst case is about 10 minutes plus the rebuild. There is no TTL to set.
- **A feed that cached a package keeps it, listed.** Unlike Nexus (which keeps serving the file
  but drops it from the index), ProGet merges cached packages into the feed's index, so `pixi
  add colorama` still works through that feed after the allowlist removed it.
- **ProGet rewrites the records.** `noarch` is gone from every record, so a lock solved through
  ProGet says `noarch: false` for `noarch: python` packages; they still install and import
  (rattler reads the package's own `info/index.json`), but the lock differs from one solved
  against Artifact Keeper. `track_features` (525 records) and `license_family` are dropped too,
  and five records with versions like `v1.4` or `3.0.0rc0` are missing.
- A fresh solve took 140-210 s through ProGet: it compresses `linux-64/repodata.json.bz2` for each
  request (74-96 s). Through Nexus: 10-26 s; straight to Artifact Keeper: 29 s.
- ProGet cannot proxy `scn-virtual` as it is: its connector needs `channeldata.json`, and
  Artifact Keeper answers that with 502 for a virtual channel whose member has none (here the
  gate's fake upstream). The scenario gives the fake upstream one for the length of the run.

### S2 through ProGet

```text
PASS         S2   [proget] 1: install --locked through ProGet succeeds with conda-forge unreachable from AK (4.0 s)
PASS         S2   [proget] 2: ProGet rebuilds its index from AK during the block (218 s, 382480 noarch records): AK serves the virtual's repodata from its own conda-forge cache
PASS         S2   [proget] 3: a fresh solve through ProGet succeeds during the block (148.6 s)
PASS         S2   [proget] 4: a package nobody has cached fails through ProGet (HTTP 404: Package file noarch/parsl-with-visualization-2025.10.20-pyhd8ed1ab_0.conda was not found in storage.)
PASS         S2   [proget] 5: restored: upstream_url is https://conda.anaconda.org/conda-forge again and the never-cached package pulls through ProGet (HTTP 200, 0 s)
```

Notes:

- Artifact Keeper keeps serving the virtual channel's repodata from its own conda-forge cache, so
  ProGet sees no failure: even a full index rebuild during the block worked (218 s).
- The never-cached package: ProGet `404 Package file noarch/parsl-with-visualization-2025.10.20-pyhd8ed1ab_0.conda was not found in storage.`, Artifact Keeper `404 {"code":"NOT_FOUND","message":"Artifact not found in any member repository"}`.

### S3 through ProGet

```text
PASS         S3   [proget] 1: install --locked through ProGet succeeds while Artifact Keeper is down (1.1 s, packages from the feed's cache)
PASS         S3   [proget] 1: project/ as is fails only on its PyPI wheel, which is fetched from ak.internal, not through ProGet: "HTTP status server error (502 Bad Gateway) for url (https://ak.internal/pypi/pypi-remote/simple/humanize/humanize-4.16.0-py3-none-any.whl)"
PASS         S3   [proget] 2a: a fresh solve through ProGet succeeds while AK is down and ProGet's index is younger than ~10 min (started at 442 s, 140.2 s)
PASS         S3   [proget] 2b (bad): once its index is ~10 min old, ProGet answers metadata with HTTP 500 ("The remote server returned an error: (502) Bad Gateway.") while AK is down instead of serving the old index; the solve fails: "HTTP status server error (500 Internal Server Error) for url (http://scn-proget/conda/ak-virtual/noarch/repodata.json)"
PASS         S3   [proget] 3: a package ProGet never fetched is refused while AK is down (HTTP 404: Package noarch/types-click-default-group-1.2.0.20250322-pyh29332c3_0.conda not found.)
PASS         S3   [proget] 4 (bad): after a forced index update while AK is down, ProGet answers metadata with HTTP 500 until AK is back and the solve fails: "HTTP status server error (500 Internal Server Error) for url (http://scn-proget/conda/ak-virtual/noarch/repodata.json)"
PASS         S3   [proget] 5: after restart: backend healthy, ProGet's index rebuilt (229 s) and a fresh pull through ProGet works again
```

Evidence (trimmed):

```text
ak-conda-backend stopped at 14:48:41 (exited); ProGet's ak-virtual index is 421 s old
AK direct during the outage: GET conda-virtual/noarch/repodata.json: HTTP 502 0 2.509438
2a. ProGet: fresh solve (cold client, AK down) started at index age 442 s: exit 0, 140.2 s
2b. index 642 s old; GET ak-virtual noarch/repodata.json: HTTP 500 55 2.518786: The remote server returned an error: (502) Bad Gateway.
2b. ProGet: fresh solve (cold client, AK down): exit 1, 20.2 s: HTTP status server error (500 Internal Server Error) for url (http://scn-proget/conda/ak-virtual/noarch/repodata.json)
2b. ProGet's update attempts while AK is down (Caddy): conda-virtual/channeldata.json 502 IMS x32; 
3. ProGet: GET noarch/types-click-default-group-1.2.0.20250322-pyh29332c3_0.conda: HTTP 404 85 1.139258: Package noarch/types-click-default-group-1.2.0.20250322-pyh29332c3_0.conda not found.
4. after Local Index > delete, AK down: GET ak-virtual noarch/repodata.json: HTTP 500 55 2.529506: The remote server returned an error: (502) Bad Gateway.; UI: The local index does not yet exist; try browsing to a connector.
4. fresh solve after the forced update: exit 1, 19.7 s: HTTP status server error (500 Internal Server Error) for url (http://scn-proget/conda/ak-virtual/noarch/repodata.json)
5. backend started after 278 s down; healthy after 31 s (healthy)
5. ProGet ak-virtual index back: 229 s, 382671 noarch records, index 1598 MB
5. ProGet: GET noarch/types-click-default-group-1.2.0.20250322-pyh29332c3_0.conda: HTTP 200 (260 s after the backend was started)
```

Notes:

- **Packages yes, metadata for at most about 10 minutes.** ProGet serves what it has cached, and
  solves from its index while the index is younger than ~10 minutes. After that each metadata
  request tries to update the index, fails, and the client gets HTTP 500, not the old index. Nexus
  in the same position served stale metadata.
- The outage is timed on purpose: Artifact Keeper is stopped when ProGet's index is 7 minutes old,
  so both sides of the edge fall inside one outage. A first run that stopped it at 9 minutes saw
  the solve's first request arrive at about 605 s and get 500.
- After the backend is back, ProGet needs a full index rebuild (229 s here) before the forced-update
  feed serves again.

### S4 through ProGet

```text
PASS         S4   [proget] (bad) the allowlist is undone by the merge: with it ON, colorama has 0 records through ak-virtual and 8 through the merged feed, downloads (HTTP 200) and "Added colorama >=0.4.6,<0.5"
PASS         S4   [proget] (bad) dependency confusion: an unpinned acme-core through the merged feed locks fake-forge's 99.0.0 (no name ownership in the merge)
PASS         S4   [proget] 3a: the clash resolves to one connector for record and bytes (ours, eb370de69a76...; ak-virtual sorts before scn-fake), the install works
PASS         S4   [proget] (bad) 3b: a squatter connector whose name sorts first wins the clash although listed second: the fake acme-core-1.0.0-pyh4616a5c_0.conda (9ac9a20fc882...) locks and installs without any error
PASS         S4   [proget] (good) as a member of AK's virtual the hostile source is dropped by the name guard: acme-core ["1.0.0","1.0.1","1.0.1791387539","1.0.1791387567","1.0.1791483478"], unpinned lock 1.0.1791483478
PASS         S4   [proget] (good) the clash file name installs: record and bytes are both conda-internal's
```

Evidence (trimmed):

```text
colorama records: through a feed on ak-virtual alone 0 (HTTP 200), through the merged feed 8 (HTTP 200)
download noarch/colorama-0.4.6-pyhd8ed1ab_1.conda: through ak-virtual alone HTTP 404, through merged HTTP 200
pixi add colorama, channel = the merged feed: exit 0, 259.1 s: Added colorama >=0.4.6,<0.5
merged-fake offers acme-core ["1.0.0","1.0.1","1.0.1791387539","1.0.1791387567","1.0.1791483478","99.0.0"] (noarch/repodata.json HTTP 200); unpinned lock: exit 0, 0.4 s, acme-core 99.0.0
acme-core-1.0.0-pyh4616a5c_0.conda: conda-internal sha256 eb370de69a7640c3, fake-forge 9ac9a20fc882a5e2
3a merged-fake [ak-virtual, scn-fake]: record eb370de69a7640c3, bytes eb370de69a7640c3, lock eb370de69a7640c3; install --locked exit 0: The default environment has been installed. 
feed s4-clash connectors (as stored): ["ak-virtual","aaa-fake"]
3b s4-clash [ak-virtual, aaa-fake]: record 9ac9a20fc882a5e2, bytes 9ac9a20fc882a5e2, lock 9ac9a20fc882a5e2; install --locked exit 0: The default environment has been installed. 
scn-virtual through ProGet: acme-core ["1.0.0","1.0.1","1.0.1791387539","1.0.1791387567","1.0.1791483478"]; record for acme-core-1.0.0-pyh4616a5c_0.conda sha256 eb370de69a7640c3 (ours eb370de69a7640c3)
```

Notes:

- The merge undoes the allowlist and takes the squatted name, as with Nexus.
- On a file name clash ProGet takes record and bytes from the same connector, so the install does
  not fail the way it does through a Nexus group. **Which connector wins is decided by the
  connectors' names, alphabetically, not by their order in the feed**: `[ak-virtual, scn-fake]`
  installs ours; `[ak-virtual, aaa-fake]` (the same fake channel under a name that sorts first)
  installs the squatter's bytes, and pixi has nothing to complain about because the record matches.
- One failing connector fails the whole feed: before `scn-fake-forge` had a `channeldata.json`,
  `merged-fake` answered every metadata request with 500.
- Steps 2 and 3 ran while ProGet still held the `ak-virtual` index it built with the allowlist on
  in step 1 (13 noarch records), so those solves were small (0.4 s); the squatted name won anyway.

### S6 through ProGet

```text
PASS         S6   [proget] PR 1: allowlist-ci.sh locks colorama against the unfiltered twin, sets the allowlist, and install --locked through conda-virtual passes
PASS         S6   [proget] PR 1: through ProGet, once ProGet updated its index (623 s after the job started), the new lock installs including colorama
PASS         S6   [proget] PR 2: allowlist-ci.sh drops colorama from the lock and the allowlist, adds toolz, and the project installs through conda-virtual
PASS         S6   [proget] PR 2: through ProGet, after its update (621 s), colorama is "No candidates were found for colorama *"
PASS         S6   [proget] PR 2: the new lock (toolz) installs through ProGet
PASS         S6   [proget] PR 2 caveat: the feed that cached colorama in PR 1 still lists (1) and serves it (HTTP 200): ProGet does not revoke cached packages, and lists them
```

Evidence (trimmed):

```text
ProGet lists colorama 581 s after the wait began (618 s after allowlist-ci.sh started); ProGet's index 0 s old
ProGet (fresh feed) drops colorama 585 s after the wait began (620 s after allowlist-ci.sh started)
through ProGet after its update: pixi add colorama: exit 1: No candidates were found for colorama *
the PR 1 feed (cached colorama): lists it x1, GET noarch/colorama-0.4.6-pyhd8ed1ab_1.conda HTTP 200
```

Notes:

- **About 620 s from the CI job to ProGet's clients**, for each pull request, with nobody touching
  ProGet: the job itself takes about 35 s, then ProGet updates its index on the next request once
  it is about 10 minutes old. There is no setting to shorten it in the free edition; the UI's
  Local Index > delete forces it.
- As with Nexus, a file already cached stays served. ProGet also keeps listing it in the feed that
  cached it, so `pixi add colorama` keeps working through that feed.

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

## Nexus, ProGet, or no artifact manager

The two free editions side by side, and what the walkthrough does without an artifact manager
(pixi talks to Artifact Keeper directly). From the
[spike notes](https://github.com/artifact-keeper/walkthroughs/blob/main/private-conda-channel-pixi/scenarios/README.md)
and the scenarios above.

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

## What this does not show

- **ProGet's paid editions.** Metadata caching settings, connector filters and feed-level
  security are paid features; only ProGet Free was run.
- **Artifactory and Nexus Pro.** Not tested: no licence. The `track_features` case that broke
  Artifactory is checked only for Artifact Keeper, Nexus CE and pixi.
- **Shards through the virtual channel** (artifact-keeper#4577) and **shards or `.zst` through
  Nexus**: neither exists today, so the cost of a solve through the merged channel is the full index.
- **A compiled conda package the scanner catalogs under its upstream name** (for example a
  `libzlib` package cataloged as `zlib`) is still inconclusive under `fail_closed`
  (artifact-keeper#4600). S5 uses a Python package and a data package; neither hits this.
- **Scale.** One client, one host; nothing near Nexus CE's daily limits.
- **Revoking a cached file in Nexus** is a manual delete; no scenario automates it.
