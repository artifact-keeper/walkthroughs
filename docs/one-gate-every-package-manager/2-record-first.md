# Step 2: Record first

!!! danger "Draft, run against `main`"
    Output on this page is from the run of 2026-11-03 against the Artifact Keeper `main`
    image (revision `12808b8`), pending a re-run on the 1.12.0 candidate. See [Results](results.md).

Turn the gate on in the mode that refuses nothing, let the ordinary builds run, and read
what the registry would have refused. This is the step that makes the rollout boring, which
is the point.

**Make targets:** `make record`, `make baseline known-bad PHASE=record`, `make preview`.

## One policy, five repositories

The scan configuration of a repository has four fields that matter here, and they are the
same for every format:

```console
$ make record
THRESHOLD=high policy/mode.sh record_only
policy: go-proxy {"scan_on_proxy":true,"proxy_scan_action":"record_only","block_on_policy_violation":true,"severity_threshold":"high","instance_locked":false}
policy: cargo-proxy {"scan_on_proxy":true,"proxy_scan_action":"record_only","block_on_policy_violation":true,"severity_threshold":"high","instance_locked":false}
policy: npm-proxy {"scan_on_proxy":true,"proxy_scan_action":"record_only","block_on_policy_violation":true,"severity_threshold":"high","instance_locked":false}
policy: debian-proxy {"scan_on_proxy":true,"proxy_scan_action":"record_only","block_on_policy_violation":true,"severity_threshold":"high","instance_locked":false}
policy: alpine-proxy {"scan_on_proxy":true,"proxy_scan_action":"record_only","block_on_policy_violation":true,"severity_threshold":"high","instance_locked":false}
policy/wait-scanner.sh
policy: waiting for the scanner (golang.org/x/text/@v/v0.21.0.zip) . ready (vulnerable)
```

[`policy/mode.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/policy/mode.sh)
sends one `PUT /api/v1/repositories/{key}/security` per repository:

```json
{"scan_enabled": true, "scan_on_proxy": true, "proxy_scan_action": "record_only",
 "block_on_policy_violation": true, "severity_threshold": "high", "instance_locked": false}
```

- `scan_on_proxy` runs the gate on this repository's proxied downloads.
- `proxy_scan_action` is what the gate does with what it finds: `record_only` here, then
  `fail_closed` in [Step 4](4-enforce.md). Every mode scans and records; they differ only in
  what is withheld.
- `block_on_policy_violation: true` with `severity_threshold: high` means findings at or
  above `high` count. The default, `false`, does not mean "do not block": it means any finding
  counts. The DTO documents this; it is easy to get backwards.
- `instance_locked: false` is sent on purpose. Any `PUT …/security` by an instance
  administrator locks the policy unless the body says otherwise (#4363), so the first run of
  this walkthrough locked all five repositories by accident. [Step 4](4-enforce.md) locks them
  on purpose.

The last line waits for the bundled scanner: the first scans of a fresh stack wait for its
vulnerability database, and until then every pull is served `pending` without a verdict.
[`policy/wait-scanner.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/policy/wait-scanner.sh)
pulls one small module until its proxy-scan record has a verdict. On this run the database
was ready at once; the verdict on that module is itself the first result of the day (below).

## The ordinary day

[`clients/baseline.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/clients/baseline.sh)
runs the ordinary project of each package manager from
[`clients/baseline/`](https://github.com/artifact-keeper/walkthroughs/tree/main/one-gate-every-package-manager/clients/baseline):
a Go module requiring `cobra v1.9.1` and `x/text v0.21.0`, a crate depending on `serde` and
`anyhow`, a Node project with `express 4.21.2`, `typescript` and `@types/node`, and three
Debian and three Alpine packages (`curl`, `jq`, `libxml2`). Pins a real repository would have
in 2026, not the newest.

```console
$ make baseline PHASE=record
baseline go: exit 0 in 4s
baseline cargo: exit 0 in 1s
added 72 packages in 8s
baseline npm: exit 0 in 9s
Get:1 https://ak.internal/debian/debian-proxy bookworm/main amd64 curl amd64 7.88.1-10+deb12u15 [316 kB]
Get:2 https://ak.internal/debian/debian-proxy bookworm/main amd64 jq amd64 1.6-2.1+deb12u2 [64.0 kB]
Get:3 https://ak.internal/debian/debian-proxy bookworm/main amd64 libxml2 amd64 2.9.14+dfsg-1.3~deb12u6 [689 kB]
baseline apt: exit 0 in 4s
Downloading curl-8.14.1-r4
Downloading jq-1.8.2-r0
Downloading libxml2-2.13.9-r1
baseline apk: exit 0 in 2s
```

Every client succeeds. Record-only never withholds, so the pulls look like any other day:
the only trace is the `X-AK-Scan` header on each file (`clean`, `pending` while the scan
runs, `recorded` for a vulnerable file) and the proxy-scan record behind it.

## The known-bad pulls

[`clients/known-bad.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/clients/known-bad.sh)
pulls one old release with public advisories per package manager, with the real client, the
way a build that pins an old version would. Nothing is installed or executed.

| Format | Package | Why |
|---|---|---|
| go | `golang.org/x/text v0.3.0` | CVE-2020-14040, CVE-2021-38561 and later |
| cargo | `smallvec 1.6.0` | CVE-2021-25900 (0.6.9, the first choice, is yanked on crates.io and cargo refuses to resolve it) |
| npm | `lodash 4.17.15` | CVE-2020-8203, CVE-2021-23337 |
| apt | `libxml2` from bookworm | whatever the Debian tracker says on the day: critical, 9 findings |
| apk | `curl` from v3.22 | whatever the scanner says on the day: critical, 41 findings |

```console
$ make known-bad PHASE=record
# get https://ak.internal/go/go-proxy/golang.org/x/text/@v/v0.3.0.zip: 200 OK
known-bad go: exit 0 in 2s
      Adding smallvec v1.6.0 (available: v1.16.4)
  Downloaded smallvec v1.6.0 (registry `ak`)
known-bad cargo: exit 0 in 1s
npm http fetch GET 200 https://ak.internal/npm/npm-proxy/lodash/-/lodash-4.17.15.tgz (cache miss)
npm notice filename: lodash-4.17.15.tgz
known-bad npm: exit 0 in 2s
Get:1 https://ak.internal/debian/debian-proxy bookworm/main amd64 libxml2 amd64 2.9.14+dfsg-1.3~deb12u6 [689 kB]
known-bad apt: exit 0 in 4s
Downloading curl-8.14.1-r4
known-bad apk: exit 0 in 1s
```

All served. That is the mode working: the registry now knows what it would refuse, and the
team has not broken anything to find out. (`npm pack` keeps `lodash-4.17.15.tgz` on the host
for [Step 5](5-handle-an-exception.md).)

## What would be refused

Under record-only nothing is in a blocked list yet, because nothing is blocked. The preview
is the per-repository proxy-scan record, `GET /api/v1/repositories/{key}/security/proxy-scans`,
which every mode writes, filtered to `state: vulnerable` at or above the threshold.
[`policy/preview.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/policy/preview.sh)
prints it for all five:

```console
$ make preview
THRESHOLD=high policy/preview.sh
go-proxy: 1 clean, 2 vulnerable, 12 not scanned, 15 digests
cargo-proxy: 5 clean, 3 vulnerable, 9 not scanned, 17 digests
npm-proxy: 16 clean, 0 vulnerable, 57 not scanned, 73 digests
debian-proxy: 0 clean, 3 vulnerable, 2 not scanned, 5 digests
alpine-proxy: 2 clean, 1 vulnerable, 2 not scanned, 5 digests
REPOSITORY    STATE     SEVERITY    FINDINGS  CATALOGED  PATH
*alpine-proxy vulnerable critical    41        1          v3.22/main/x86_64/curl-8.14.1-r4.apk
*cargo-proxy  vulnerable critical    1         1          api/v1/crates/smallvec/1.6.0/download
*debian-proxy vulnerable critical    38        1          pool/main/c/curl/curl_7.88.1-10+deb12u15_amd64.deb
*debian-proxy vulnerable high        4         1          pool/main/j/jq/jq_1.6-2.1+deb12u2_amd64.deb
*debian-proxy vulnerable critical    9         1          pool/main/libx/libxml2/libxml2_2.9.14+dfsg-1.3~deb12u6_amd64.deb
*go-proxy     vulnerable high        4         4          golang.org/x/text/@v/v0.21.0.zip
*go-proxy     vulnerable high        5         1          golang.org/x/text/@v/v0.3.0.zip
 …
 npm-proxy    not_scanned -           -         -          lodash/-/lodash-4.17.15.tgz
 … (the clean and not-scanned files follow)
* = would be refused with the gate enforcing at threshold 'high': 7 file(s)
```

(Abridged: the full table lists every cached file; `out/preview.json` keeps it as JSON for
[Step 4](4-enforce.md)'s gate.) Read it as the team would:

- **Four of the five known-bad fixtures are there**, as planned: `x/text v0.3.0`,
  `smallvec 1.6.0`, `libxml2`, `curl` on Alpine. `lodash 4.17.15` is not: its line reads
  `not_scanned`. It was pulled in the middle of the 72-file npm install, its scan ran out of
  budget (below), and the preview has no verdict for it. [Step 4](4-enforce.md) refuses it
  anyway, because `fail_closed` scans it inline on the next pull; the point is that the
  preview did not predict that refusal.
- **So are ordinary pulls.** `golang.org/x/text v0.21.0`, the version the Go project pinned,
  is `high` today: two 2026 CVEs against `x/text` itself (fixed in 0.39 and 0.41) and two
  against the `x/mod` its `go.mod` requires. On Debian 12, `curl`, `jq` and `libxml2`, three
  packages a Dockerfile installs without thinking, are all above the threshold; `jq`'s
  finding names a fixed version (`1.6-2.1+deb12u3`) that the `bookworm` suite does not carry
  (it is in the security suite, which this walkthrough does not proxy). Had the team
  enforced on day one, the Go build and every `apt-get install curl` would have failed, with
  the same `403` as the deliberate fixtures.
- **`CATALOGED` says whether the file was graded as itself.** `1` for a `.deb`, `.apk` or
  tarball means the scanner cataloged the package; `4` for `x/text v0.21.0` means the
  module plus the three requirements in its `go.mod`. A `clean` verdict with `0` would mean
  "nothing to grade"; none of the fixtures scored that.
- **`not scanned` is not "clean".** 57 of 73 npm files have no verdict after the
  `npm install`, `lodash` among them. Under `record_only` a first pull is served while the scan runs; the scans
  of a 72-file install ran at once and most of them exceeded the 30-second budget the gate
  gives each one, which is recorded as inconclusive, not as a verdict (finding F1 in
  [Findings](findings.md)). The next pull of the same file scans it again. The preview is
  therefore only as complete as the scans behind it: the counts in the first line of each
  repository say how much of the picture is in.

The `curl` verdicts on both distributions deserve a closer look before anyone decides they
are true. The same 2026 CVE ids appear against `curl 7.88.1-10+deb12u15` on Debian and
`curl 8.14.1-r4` on Alpine, 38 and 41 findings, every one with no fixed version. That is
what the scanner reported; [Findings](findings.md) (F3) records it as an open question about
how the bundled engine grades operating-system packages, because a distribution that
backports fixes would expect its security tracker, not the upstream product, to decide.

## What record-only costs

Nothing for the clients: the npm install took 8 seconds with and without the gate. For the
registry, one scan per new file, in the background. For the team, one question per starred
line before [Step 4](4-enforce.md): upgrade, drop, or except.

**Gates:** G2 (record-only served every pull, verdicts recorded), G3 (the preview predicts
the blocked list, checked after enforcing).

**Next:** [Step 3: Review the dashboard and the queues](3-review-the-queues.md).
