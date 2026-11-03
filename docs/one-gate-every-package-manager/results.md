# Results

!!! danger "Draft, run against `main`, pending a re-run on the 1.12.0 candidate"
    These are the numbers of one clean run (`make clean && make all && make gates && make
    screens`) on 2026-11-03 against the Artifact Keeper `main` image of 2026-11-02. 1.12.0 is
    not released; the same run on a release candidate replaces this page before the draft
    is published.

## What was tested

| | |
|---|---|
| Backend | `ghcr.io/artifact-keeper/artifact-keeper-backend:main`, digest `sha256:302343442240cfd1b19d942690d7db34845e5962e13fe372667e4de936b4dc88`, revision `12808b8694e4a529f2d3739bc2df759ee46d2ed9`, built 2026-11-02 (one docs-only commit behind `main`'s head of that day). The web UI header reports it as "Server 1.11.3", a stale version string on `main`. |
| Web UI | `ghcr.io/artifact-keeper/artifact-keeper-web:main`, digest `sha256:579cbc711f4bbeb9ac59c0acdd5c11741da96923c2e673e73a57d7ec25fe61b8`, revision `0f89b1c5e474e92f9b9800fd76d8d6329fd84823` |
| Scanner | the bundled engine (Grype), `vuln_db_version: grype-db-v6.1.10`; Trivy, OpenSCAP and Dependency-Track off |
| Clients | `golang:1.26-alpine` (`a2012b4a…`), `rust:1-slim-bookworm` (`24707e70…`), `node:22-alpine` (`025b8e97…`), `debian:12-slim` (`99c0b25c…`), `alpine:3.22` (`2e0b81d6…`); full digests in [`registry/compose/VERSIONS`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/registry/compose/VERSIONS) |
| Host | a Linux lab host, Ubuntu 26.04, 40 cores, 108 GB RAM, rootless podman 5.7 with docker-compose 5.5 as the compose provider |
| Upstreams | proxy.golang.org, index.crates.io, registry.npmjs.org, deb.debian.org (bookworm), dl-cdn.alpinelinux.org (v3.22), live on the day |

## The gates

```text
PASS            G1  five formats enforced; metadata of all five proxies served
PASS            G2  record-only served every pull and recorded the verdicts
PASS            G3  every file the preview marked is in the blocked list after enforcing
PASS            G4  go:    known-bad refused (403 scan_blocked), client failed
PASS            G4  cargo: known-bad refused (403 scan_blocked), client failed
PASS            G4  npm:   known-bad refused (403 scan_blocked), client failed
PASS            G4  apt:   known-bad refused (403 scan_blocked), client failed
PASS            G4  apk:   known-bad refused (403 scan_blocked), client failed
PASS            G5  go:    baseline passes under fail_closed (cold and warm)
PASS            G5  cargo: baseline passes under fail_closed (cold and warm)
BLOCKED(#5149)  G5  npm:   warm baseline passes under fail_closed: @types/* tarballs never establish identity, 423 under fail_closed
FAIL            G5  npm:   cold baseline passes under fail_closed: exit 1: 1 423 answer(s) on the cold install (inline scans over the 30 s budget, see findings F1)
PASS            G5  apt:   baseline passes under fail_closed (cold and warm)
PASS            G5  apk:   baseline passes under fail_closed (cold and warm)
PASS            G6  refusals are listed (blocked list, dashboard, queue) and audited
BLOCKED(#5153)  G7  acknowledged findings survive a rescan: the rescan wrote unacknowledged rows and the download is refused again
BLOCKED(#5143)  G8  a crate is graded on its own coordinate, not its bundled Cargo.lock: refused for bumpalo,crossbeam-channel,crossbeam-deque,crossbeam-queue,crossbeam-utils,futures-task,futures-util,memoffset,nix,socket2
PASS            G9  generic download route refuses a scanning Remote (403 scan_on_proxy_route_required)
PASS            G9  fail_closed withholds a package whose release cannot be determined (alpine latest-stable: 423)
PASS            G9  a Debian Remote with no cached Release withholds a base-release package (423)
PASS            G9  instance lock: a repository admin can tighten the policy but not weaken it
PASS            G9  refusal audit is aggregated: a retry loop writes at most two rows a minute
PASS            G9  a refused file stays listed in the cache and is refused from its stored verdict

gates: 19 PASS, 3 BLOCKED, 1 FAIL
```

The three `BLOCKED` checks are the three open issues the walkthrough was designed around
(#5149, #5153, #5143), each reproduced on `main`; they turn into `PASS` when the fixes land,
with no change to the walkthrough. The one `FAIL` is finding F1 in [Findings](findings.md):
a cold `npm install` of a new dependency tree under `fail_closed` runs into the inline scan
budget. It is reported as a failure because it is one: the walkthrough does not warm the
cache first to make it pass.

## Timings

With the stack's images and the five client images already on the host (a first run also
pulls about 4 GB):

| Step | Time |
|---|---|
| `make all` from an empty registry (`registry-up` to the end of `exception`) | 3 min 10 s |
| `make gates` | 2 min 12 s, of which 2 min 6 s is waiting for the audit window in G9 |
| registry cold start to `/readyz` | 35 s |
| scanner database ready | at once on this run (`wait-scanner` passed on the first probe) |
| `go mod download` (7 modules), `cargo fetch` (7 crates), `apt-get download` (3), `apk fetch` (3) | 1 to 4 s each, with or without the gate |
| `npm install` of the ordinary project (72 packages), record-only | 9 s |
| `npm install` of the fixed project, `fail_closed`, cold (every tarball scanned inline) | 41 s, then `423` |
| the same, warm | 5 s, then `423` on `@types/node` (#5149) |
| one cold npm tarball through `fail_closed`, alone | 2.5 to 3.5 s |
| upload scan of the vendored `lodash` (Grype plus the dependency scan) | about 5 s |

## What the run showed, in numbers

| | |
|---|---|
| Files pulled through the five proxies during the record-only pass | 115 distinct digests (15 Go, 17 Cargo, 73 npm, 5 Debian, 5 Alpine); the Go `.mod`/`.info` and Cargo index files among them are not gated and count as `not scanned` |
| Of the gated files, left without a verdict by the record-only pass | 57 of 73 npm tarballs (F1); none of the others |
| Files the preview marked "would be refused" at threshold `high` | 7: `x/text v0.21.0` and `v0.3.0`, `smallvec 1.6.0`, Debian `curl`, `jq`, `libxml2`, Alpine `curl` |
| Files refused after enforcing | 8: the 7 above plus `lodash 4.17.15` (not in the preview: no verdict until its next pull); 9 after [Step 5](5-handle-an-exception.md) added `async-ctrlc 1.2.0` |
| Ordinary pulls among them | 4: `x/text v0.21.0` (Go), Debian `curl`, `jq`, `libxml2` |
| Audit rows for the five known-bad pulls | 5, one per pull, `attempts=1`; a 12-pull retry loop wrote 2 (`attempts=1`, then `attempts=11 aggregated=true` 60 s later) |
| Findings acknowledged for the hosted exception | 12 rows for 6 CVEs; the rescan wrote 12 more |

## What it adds up to

- **The record-only pass found four ordinary pulls that enforcing would have refused**, in
  two of the five package managers, before anything was refused. That is the rollout story
  working.
- **The preview is only as complete as the scans behind it.** On this host a 72-file
  `npm install` left most of its files without a verdict, including one of the deliberate
  fixtures (F1). The counts at the top of the preview say how much is in; run the install
  twice before trusting it.
- **One policy shape, one refusal shape, five clients.** The same four fields on every
  repository, `403 scan_blocked` naming the file on every format, one blocked list, one
  queue, one audit.
- **The exception path works on the hosted side with one extra step** (release after
  acknowledge, F5) **and does not survive a rescan** (#5153). The proxied side has no
  exception (#5143, #5152).
- **`fail_closed` costs the first cold install of every new dependency tree** (F1) and, for
  TypeScript projects, works only once #5149 is merged.

## Screenshots

Taken headlessly with Playwright in a container on the registry's network
([`screens/`](https://github.com/artifact-keeper/walkthroughs/tree/main/one-gate-every-package-manager/screens)),
light theme, 1440 px wide, after the gates had run. They are what this build of the web UI
(`0f89b1c`) shows; it has the proxy-scan panel and the dashboard counter, and not yet the
blocked list, the hold queues or the instance lock.

**Next:** [Findings](findings.md), then [Next steps](next-steps.md).
