# Plan: one gate for every package manager

Status: design for review, 2026-11-02, written before the first run and kept as the record of
what was intended. The pages were then written from a run against Artifact Keeper `main`
(see [Results](results.md) for the exact image) and are pending a re-run on the 1.12.0
candidate. Fourth walkthrough, after Rocky Linux image mode, the private conda channel and
the AI coding agent one; it reuses their registry pattern (upstream compose plus an override,
Caddy with an internal CA, a bare hostname, rootless podman).

## Who this is for

A platform or security team that owns the artifact registry for a company with more than one
language. Builds pull Go modules, crates, npm packages, Debian and Alpine packages through
it, each with its own client, and the team has been asked to stop known-vulnerable packages
at the registry. Their worry is not the policy, it is the rollout: a gate that is turned on
in one step breaks builds in every language at once, and the first thing the on-call engineer
hears is "the registry is down".

## The one promise

One policy, one place to look, and no surprise: before anything is refused, the team can see
exactly which files would be, by package manager, with the advisory that would refuse them.

## Why this shape

Artifact Keeper 1.12.0 brings the proxy scan gate to the archive and operating-system
formats (Go, RubyGems, Composer, Pub, Conan, CocoaPods, Swift, Debian, RPM and Alpine join
npm, PyPI, Maven, NuGet, Cargo, conda, OCI and VS Code), and gives the gate a
`record_only` mode, a cross-repository blocked list, a `proxy_blocked` dashboard counter,
an audit row per refusal, admin hold queues, a grade status instead of F floors, and an
instance-admin lock on weakening the policy. That is enough to tell a rollout story rather
than a feature story: record, review, enforce, handle the exception, prove the failure mode.

### Formats chosen

Five, with the real client of each. Not every gated format: the point is that the story is
the same for each one, and five is enough to show it.

| Package manager | Repository | Upstream | Why this one |
|---|---|---|---|
| `go` (GOPROXY) | `go-proxy` | proxy.golang.org | New in 1.12.0 (#4942), and graded as the requested module since #4952, so an advisory against the module itself is found |
| `cargo` | `cargo-proxy` | index.crates.io | Already gated; the open bug #5143 (a crate refused for its bundled `Cargo.lock`) is the proxied half of the exception step |
| `npm` | `npm-proxy` | registry.npmjs.org | Already gated; the open bug #5149 (`@types/*` never establish identity, 423 under `fail_closed`) is the "does enforcing break the build?" test; npm is also where the hosted exception lives (`npm-internal`) |
| `apt` | `debian-proxy` | deb.debian.org | New in 1.12.0 (#4965); operating-system packages are graded against a release the registry has to determine (#5170 is open against that logic) |
| `apk` | `alpine-proxy` | dl-cdn.alpinelinux.org | New in 1.12.0 (#4966); the second operating-system format, with its own release rule (the branch) |

Not chosen, and why: PyPI, because the AI coding agent walkthrough covers it in depth; conda,
because it has its own walkthrough; OCI, because image scanning is a different gate (the
manifest) with its own open bug (#5146) and deserves its own page; Maven/Gradle, because its
1.12.0 addition is the publish-age gate (#4997), a different control.

### How this differs from the AI coding agent walkthrough

That walkthrough (`ai-agent-dependency-guardrails`) also enables scan-on-proxy, on PyPI and
npm, as one of five controls around a sandboxed agent, and turns it on `fail_closed` from the
start. This one is about the gate itself, across five package managers, and about how a team
gets from "off" to "enforced and locked" without breaking builds: the record-only pass, the
preview of what would be refused, the queues and the audit, the exception, and the failure
modes. The two overlap on one fact (npm packages with a high advisory answer
`403 scan_blocked`) and nowhere else.

## Requirements the walkthrough must demonstrate

| # | Requirement | Where |
|---|---|---|
| R1 | One policy shape for every format: `scan_on_proxy`, `proxy_scan_action`, one severity threshold, through one API | Step 1, Step 2 |
| R2 | Every client talks to the registry alone, with the stack's CA, by its own standard configuration | Step 1 |
| R3 | Record-only scans and records every pull and withholds nothing | Step 2, G2 |
| R4 | The team can see what would be refused before enforcing, per file, with the advisory | Step 2, G3 |
| R5 | Enforcing refuses a known-vulnerable pull in every format with the same answer (`403 scan_blocked`) and the client fails | Step 4, G4 |
| R6 | Ordinary builds still pass after enforcing (or the page says exactly why not) | Step 4, G5 |
| R7 | Every refusal is visible: the blocked list, the dashboard counter, the admin queue, an audit row with who asked | Step 3, Step 4, G6 |
| R8 | A legitimate exception can be recorded with a reason, and survives | Step 5, G7, G8 |
| R9 | The policy cannot be weakened by a repository administrator once locked | Step 4, G9 |
| R10 | The gate fails closed: inconclusive is refused, the generic route refuses, a retry loop cannot flood the audit | Step 6, G9 |

## Environment

- **Registry**: Artifact Keeper built from `main` (1.12.0 is not released), the `:main` image
  from ghcr.io pinned by digest in `registry/.env.example`, compose project `ak-gate`,
  rootless podman. Caddy answers `https://ak.internal` on the compose network with its
  internal CA; the only host port is `127.0.0.1:30446`. Trivy, OpenSCAP and Dependency-Track
  are off: the proxy gate grades with the bundled engine (Grype).
- **Repositories**: the five Remotes above, visibility `public` (the clients read them
  anonymously; tokens per client are shown in the other walkthroughs), and `npm-internal`
  (hosted) with a scan policy (`max_severity: high`, block unscanned, block on failed scan) for
  the exception step.
- **Clients**: the official image of each package manager, run by `clients/run.sh` on the
  compose network with the CA and a configuration that names only `ak.internal`
  (`GOPROXY`, Cargo source replacement, `.npmrc`, an apt `.sources` file, `/etc/apk/repositories`).
  Download only: `go mod download`, `cargo fetch`, `npm install --ignore-scripts` and
  `npm pack`, `apt-get download`, `apk fetch`. Nothing from a package is executed.
- **Baselines**: a small ordinary project per format (`clients/baseline/`), and the pins the
  team moves to after the preview (`clients/baseline-fixed/`).

### Known-bad fixtures

One package with a published advisory per format, chosen so that nothing malicious is ever
downloaded, only old releases with public CVEs:

| Format | Package | Advisory |
|---|---|---|
| go | `golang.org/x/text v0.3.0` | CVE-2020-14040, CVE-2021-38561 (high) |
| cargo | `smallvec 0.6.9` | CVE-2019-15551 (critical) |
| npm | `lodash 4.17.15` | CVE-2020-8203, CVE-2021-23337 (high) |
| apt | `libxml2` from bookworm | whatever the Debian tracker lists on the day of the run |
| apk | `libxml2` from v3.22 | whatever the Alpine secdb lists on the day of the run |

The Debian and Alpine fixtures are honest about one thing: a distribution serves one version
of a package per release, so what the scanner says about it depends on the day.

## Decisions

1. **Record first, and make the preview the product.** The record-only mode exists for this.
   The preview is the per-repository proxy-scan record filtered by state and severity, because
   under record-only nothing is in a blocked list yet. Enforcing comes after the preview is
   clean or understood.
2. **`fail_closed`, not `fail_open`.** The team that asked for the gate wants "never unscanned
   bytes". `fail_open` is shown as the middle setting and the cost of `fail_closed` (an
   inconclusive scan refuses the pull) is shown, not hidden.
3. **One threshold, `high`.** Findings at or above `high` refuse. Lower severities are
   recorded and visible.
4. **Lock it.** Once enforced, an instance administrator locks the policy; the gate proves
   that a repository administrator can tighten but not weaken it.
5. **Exceptions are decisions with a reason.** The hosted side has acknowledgement per
   finding with a reason and an actor; the walkthrough uses it and shows what it does not
   survive (#5153). The proxied side has no acknowledgement (#5152); the walkthrough shows the
   bug (#5143) and the options that exist today rather than inventing a mechanism.
6. **Every refusal is quoted verbatim** from the run on the lab host.

## Open issues this walkthrough depends on

All open on 2026-11-02 and planned for 1.12.0; fixes not merged. Each gate below that depends
on one reports `BLOCKED(#issue)` instead of PASS or FAIL.

| Issue | What it is | Step and gate | Expected on `main` today |
|---|---|---|---|
| #5149 | npm `@types/*` tarballs never establish identity; `fail_closed` withholds them with a permanent 423 | Step 4 (enforce), G5 for npm | the npm baseline fails under `fail_closed` on `@types/node`; the other four pass |
| #5153 | acknowledged findings come back on every rescan, dedup copy and promotion | Step 5 (exception, hosted), G7 | after `make rescan` the vendored package is refused again |
| #5143 | a crate is refused for vulnerabilities in its bundled `Cargo.lock` | Step 5 (exception, proxied), G8 | `async-ctrlc 1.2.0` is refused with findings against other packages |
| #5170 | Debian release inference from version markers; signed `.apk` `.PKGINFO` | Step 4 and Step 6 (Debian and Alpine verdicts) | exercised only incidentally: the verdicts of the run show which release each package was graded against; no gate depends on it |
| #5150 | npm and PyPI virtuals: a gated Remote member that does not host the package answers 451 | not exercised | this walkthrough has no virtual repositories and no age gate |
| #5151 | PyPI age gate with no Warehouse JSON API blocks everything | not exercised | no PyPI, no age gate |
| #5146 | Docker virtual: an empty local member blocks below-threshold remote blobs | not exercised | no OCI repository |

## Gates

| # | Gate | Proof |
|---|---|---|
| G1 | The stack: the five formats report `enforced` in `GET /api/v1/formats`; the five proxies serve their metadata | API, probes |
| G2 | Record-only served every pull (baseline and known-bad, all five clients exit 0) and recorded verdicts | client logs, proxy-scan records |
| G3 | Every file the preview marked "would be refused" is in the blocked list after enforcing | `out/preview.json` against `GET /security/proxy-blocked` |
| G4 | Enforcing refuses the known-bad pull of every format with `403 scan_blocked` and the client fails | probes, client logs |
| G5 | The (fixed) baselines pass under `fail_closed`, or the page names the open issue (npm: #5149) | client logs |
| G6 | Refusals are visible: blocked list, dashboard `proxy_blocked`, `admin/holds/policy-blocks`, `PROXY_SCAN_BLOCKED` audit rows naming the repository | API |
| G7 | Hosted exception: refused, acknowledged with a reason, served; after a rescan, still served (#5153) | API, downloads |
| G8 | Proxied exception: a crate is graded on its own coordinate, not its bundled lockfile (#5143) | probe, findings |
| G9 | Fails safely: the generic download route refuses a scanning Remote; an undeterminable release is 423 under `fail_closed` (Alpine `latest-stable`, a Debian Remote with no cached `Release`); the instance lock refuses a repository admin's weakening PUT and accepts a tightening one; twelve refused pulls in a row write at most two audit rows; a refused file stays listed in the cache and is refused from its stored verdict | probes, API |

Reproducibility (`make clean && make all && make gates` twice) is recorded in
[Results](results.md) when it was run, not as a gate.

## Open questions before the run

Things the source on `main` did not settle, to be answered by the run and recorded in the
findings:

- Under `record_only`, does a bulk install (seventy tarballs in one `npm install`) leave every
  file with a verdict, or does the inline scan budget (30 s) make some inconclusive?
- Which release does the Debian gate grade a bookworm package against on a Remote that has
  served `InRelease` once (expected `debian:12`), and how is that visible in the API?
- Does the Alpine secdb flag any package of a current branch at all, given it lists fixed
  versions and a current branch serves them?
- What does `GET /api/v1/security/scores` say for a Remote: is a proxy cache scored at all?
- Does an instance administrator's ordinary `PUT .../security` lock the policy as a side
  effect (the docs say any admin PUT locks unless `instance_locked: false` is sent)?
- What the web UI shows of the blocked list and the hold queues, for the screenshots.

## Layout

```text
one-gate-every-package-manager/
  Makefile            registry-up, bootstrap, images, record, baseline, known-bad, preview, enforce, lock, review, exception, gates, all, clean
  registry/           compose override, Caddy, up.sh, down.sh, clean.sh, bootstrap.sh (proxies, npm-internal, tokens)
  clients/            run.sh, config/ (one file per package manager), baseline/, baseline-fixed/, known-bad.sh, probe.sh, baseline.sh
  policy/             mode.sh, lock.sh, preview.sh, review.sh, wait-scanner.sh
  exception/          vendor.sh, acknowledge.sh, rescan.sh, proxied.sh
  gates/              lib.sh, run-all.sh
docs/one-gate-every-package-manager/
  index.md, 1-…md to 6-…md, results.md, findings.md, next-steps.md, plan.md, images/
```
