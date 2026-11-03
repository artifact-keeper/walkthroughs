# Findings

!!! danger "Draft, run against `main` (revision `12808b8`), pending a re-run on the 1.12.0 candidate"
    The lab record behind this walkthrough: what the run against Artifact Keeper `main` of
    2026-11-02 showed that the pages should not gloss over, and what surprised us building
    it. Everything here was reproduced on the lab host (Ubuntu 26.04, rootless podman 5.7,
    backend `main` revision `12808b8`, web `0f89b1c`). Issues have not been filed; the
    maintainer reviews this list first. Items marked **new** are not covered by an open issue
    we know of.

## Artifact Keeper: what the run showed

| # | Finding | Effect here | Gate |
|---|---|---|---|
| F1 | **A cold `npm install` fails under `fail_closed`** (new). Under `fail_closed` each never-seen tarball is scanned inline with a 30 s budget (`PROXY_SCAN_INLINE_BUDGET`). npm fetches about ten tarballs at a time, the scans contend for the host, and some exceed the budget; an over-budget scan is inconclusive and answers `423 scan_pending`, which npm does not retry. The install of `express 5.1.0` (about 70 new tarballs) failed on the first run with one 423 (`mime-types-3.0.2.tgz`) and passed the tarballs on the second run. The same contention under `record_only` left 71 of 103 npm files with no verdict after one install (the backend logged "inline proxy scan exceeded the budget; treating as inconclusive" 69 times in twelve minutes), so the preview of [Step 2](2-record-first.md) was two thirds blind until the files were pulled again. A lone cold tarball scans in 2.5 to 3.5 s on this host. Proposed: bound the number of concurrent proxy scans and queue the rest instead of letting them all run into one budget; under `record_only`, re-queue an inconclusive digest in the background rather than waiting for the next pull. | G5 npm cold: FAIL; the preview needs a second pass | G2, G5 |
| F2 | **Record-only has no view of its own** (new). `GET /security/proxy-blocked`, the `proxy_blocked` dashboard counter and `admin/holds/policy-blocks` list only what a repository's own settings refuse, so under `record_only` all three are empty. The only preview of "what would be refused" is the per-repository `proxy-scans` listing, filtered by state and severity by hand ([`policy/preview.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/policy/preview.sh)). Proposed: a `would_block` filter or counter that applies the repository's threshold to recorded verdicts regardless of the action, so a record-only rollout has the same list to review as an enforcing one. | the preview is a script, not an API or UI view | G3 |
| F3 | **`curl` is refused on Debian 12 and Alpine 3.22 for the same 38 to 41 CVE ids, none with a fixed version** (open question). `curl 7.88.1-10+deb12u15` (Debian) and `curl 8.14.1-r4` (Alpine) were both graded `critical`, and the finding lists are near-identical sets of 2026 CVE ids against `curl` with `fixed_version: null`, for example CVE-2026-10536, CVE-2026-11856, CVE-2026-18924. A finding that does come from a distribution tracker looks different: `jq` on Debian carries CVE-2026-32316 with `fixed_version: 1.6-2.1+deb12u3`. Either the bundled engine matches operating-system packages against the upstream product (by CPE) in addition to the distribution feed, so a distribution's backported fixes do not count, or both trackers list these CVEs as open with no fix. The walkthrough reports the verdict as given and leaves the cause to the maintainer. Also refused on bookworm at threshold `high`: `libxml2` (critical, 9), `openssl` (critical), `zlib1g` (high), `tzdata`. | the ordinary apt and apk lists had to drop `curl`; a team cannot upgrade past the distribution's version | G4, G5 |
| F4 | **`PROXY_SCAN_BLOCKED` audit rows carry no client IP** (new). Every row written in this run has `ip_address: null` and `anonymous: true`, although the backend's request log for the same pull records an `ip=` and the audit documentation says the row carries the verified client IP. Every other row in the audit log of this stack (logins, repository updates) also shows no IP in the web UI, so this may be the stack's reverse-proxy setup (`RATE_LIMIT_TRUSTED_PROXY_CIDRS` is the compose subnet, Caddy forwards `X-Forwarded-For`) rather than the refusal path. Either way, with anonymous reads the row answers "what, where, how often" and not "who". | the audit answers "what", not "who" | G6 |
| F5 | **Acknowledging every finding does not release the artifact** (new, next to #5153). The upload scan of the vendored `lodash 4.17.15` quarantined it with the reason `Policy 'npm-internal-gate': 3 findings at or above high severity` and no recorded `quarantine_source` (the scanner "does not record its source yet", per the holds documentation). After all 18 findings (Grype and the registry's own dependency scan, twice) were acknowledged with a reason, the download answered `409`: the policy no longer refused it, so the source-less hold fell back to the quarantine answer, and an administrator had to `POST /quarantine/{id}/release` before the download answered `200`. Proposed: when a scan-policy hold's findings are all acknowledged, release the hold (or record `quarantine_source: scan_policy` so the gate re-evaluates it), and say so in the acknowledge response. | [Step 5](5-handle-an-exception.md) has a release step | G7 |
| F6 | **Two scanners, two sets of rows to acknowledge** (observation). The upload scan wrote six Grype findings and six identical findings from the registry's dependency scan (`source: osv.dev`), and the gate counts both. Acknowledging is per row, so the same six CVEs are acknowledged twelve times, and a rescan writes twelve more. #5153's proposed decision model (per CVE and component, not per row) would fold this. | eighteen acknowledgements for six CVEs | G7 |
| F7 | **An instance administrator's ordinary `PUT …/security` locks the policy** (documented, surprising). The first run of `make record` locked all five repositories because the body did not say `instance_locked: false`; the lock state is reported at `config.instance_locked` on `GET /repositories/{key}/security` and in `GET /security/configs` (where `repository_key` is `null`, so rows must be matched by id). The web UI's repository settings page has no control for the lock. Proposed: a PUT that does not mention `instance_locked` should leave it as it is. | [`policy/mode.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/policy/mode.sh) reads the lock first and sends it back | G9 |
| F8 | **The Cargo sparse index does not serve `config.json` under `index/`** (minor). `sparse+https://ak.internal/cargo/<key>/index/` fails with "no matching package" because `…/index/config.json` is `404`; the index files are served under both `index/` and the root, `config.json` only at the root. A one-line doc note, or the file at both paths, would save a run. | the client config uses the repository root | G1 |
| F9 | **`GET /security/scores` is hosted-only** (observation). Remotes have no score and no grade status; `repos_rated` and friends on the dashboard count hosted repositories. The proxy-side coverage question ("how much of what we serve has a verdict?") is answered only by the per-repository `proxy-scans` summary (`clean`, `vulnerable`, `not_scanned`). | the review page says where to look | G6 |

### Status of the open issues this walkthrough was designed around

| Issue | Reproduced here | Gate |
|---|---|---|
| #5149 npm `@types/*` never establish identity, permanent 423 under `fail_closed` | yes: `@types/node 22.15.3` answers `423 scan_pending` on every pull, alone or in an install | G5 `BLOCKED(#5149)` |
| #5153 acknowledged findings come back on rescan | yes: after `POST /security/scan {bypass_dedup: true}` the new Grype and dependency scans carry the same six CVEs unacknowledged and the download is refused again; plus F5 and F6 above | G7 `BLOCKED(#5153)` |
| #5143 a crate refused for its bundled `Cargo.lock` | yes: `async-ctrlc 1.2.0` is `critical` with 11 findings against `crossbeam-deque`, `crossbeam-utils`, `futures-task`, `nix`, `bumpalo` and others, none against `async-ctrlc`; `components_cataloged: 66` shows the whole bundled lockfile was graded | G8 `BLOCKED(#5143)` |
| #5170 Debian release inference, signed `.apk` `.PKGINFO` | not exercised directly: bookworm packages were graded after `apt update` had cached `InRelease`, which is the documented path; the version-marker fallback and the hosted `.PKGINFO` reader were not reached | none |
| #5150, #5151, #5146 | not exercised: no virtual repositories, no age gate, no OCI | none |

## What we learned building it

- **The preview is the product.** On the day of the run the ordinary Go pin (`x/text v0.21.0`)
  and the ordinary Debian base-image packages were above the threshold. A team that had
  enforced first would have broken its Go builds and every `apt-get install curl`, and
  reported the registry as down.
- **`fail_closed` has a first-day cost that is not about vulnerabilities** (F1). The second
  run is fine; the first run of every new dependency tree is not.
- **Distributions and scanners disagree** (F3). An operating-system package has one version
  per release, so there is no upgrade to make; the only levers are the threshold, an
  exception, or `record_only` for that repository, and the proxied side has no exception
  today (#5152).
- **Yanked crates vanish.** `smallvec 0.6.9`, the first choice for the Cargo fixture, is
  yanked on crates.io and cargo refuses to resolve it; `smallvec 1.6.0` (CVE-2021-25900,
  critical) took its place.
- **`npm pack` of a refused package is a 403 too**, which makes the vendoring story honest:
  the tarball in [Step 5](5-handle-an-exception.md) was fetched during the record-only pass,
  because afterwards the proxy refuses it.
- **A Remote does not re-sign Debian and Alpine indexes.** `InRelease` and `APKINDEX.tar.gz`
  pass through with the upstream signature, and `gpg-key.asc` answers `404 No signing key
  configured`; the clients use the keys their images ship. The first draft of the bootstrap
  tried to fetch registry keys and failed.
- **apk says "Permission denied" for a 403**, apt says "403 Forbidden", go reports the
  status, npm the status and the reason word, cargo prints the JSON body. Only a direct
  request shows the body for the others ([`clients/probe.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/clients/probe.sh)).
- **The backend reports itself as 1.11.3** in the web UI header ("Server 1.11.3") although the
  image is `main` after the 1.11.11 release; the version string on `main` is stale. Cosmetic,
  but worth a line in the results.
