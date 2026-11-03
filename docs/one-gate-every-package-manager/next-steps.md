# Next steps

!!! danger "Draft, run against `main`"
    Written from the run of 2026-11-03 against Artifact Keeper `main` (revision `12808b8`),
    pending a re-run on the 1.12.0 candidate. See [Results](results.md).

What the team would do the week after this walkthrough, and what the walkthrough did not do.

## For the team running it

- **Give each client a token.** The five proxies are public here so that each client needs
  one file; with per-client tokens (repository-scoped, read only, as in the conda and
  AI-agent walkthroughs) the `PROXY_SCAN_BLOCKED` audit row names the principal, and the
  question "who asked for this" has an answer that is not an IP address.
- **Warm the cache before `fail_closed`.** Finding F1 in [Findings](findings.md): the first
  cold install of every new dependency tree runs into the inline scan budget. Run the
  ordinary builds once under `record_only` or `fail_open`, look at the `not_scanned` count
  in the preview, run them again, then switch. Or enforce `fail_open` for the first week and
  `fail_closed` after.
- **Proxy the Debian security suite.** `jq`'s fix (`1.6-2.1+deb12u3`) lives in
  `bookworm-security`, which this walkthrough does not proxy. A second Debian Remote for
  `deb.debian.org/debian-security` with the same policy is the normal shape; the gate will
  then refuse the base suite's `jq` and serve the security suite's, which is what you want.
- **Decide what to do about `curl`.** On the day of the run the scanner refused `curl` on both
  distributions with findings that name no fixed version (F3). Until the proxied side has an
  exception (#5152, #5143), the choices are the threshold (`critical` lets `jq` and the Go
  module through but not `curl`), `record_only` on the operating-system proxies alone (the
  lock keeps a repository administrator from doing that quietly), or vendoring the package
  into a hosted repository with an acknowledgement and a release ([Step 5](5-handle-an-exception.md)).
- **Watch the queue.** `GET /api/v1/security/proxy-blocked` and
  `GET /api/v1/admin/holds/policy-blocks` are the work list; `GET /api/v1/admin/audit`
  filtered to `PROXY_SCAN_BLOCKED` says how often each refused file is still being asked
  for. A refused file that nobody asks for any more can be left alone.
- **Rescan on a schedule and expect acknowledgements to lapse** until #5153 lands: a scanner
  database update rescans hosted artifacts and brings acknowledged findings back as new
  rows. Keep the reasons in a ticket, not only in the registry.

## For Artifact Keeper

In the order a reviewer of [Findings](findings.md) would take them:

1. Bound concurrent proxy scans and re-queue inconclusive digests under `record_only` (F1).
2. A "would block" view for record-only rollouts (F2), so the preview is an API call and a
   UI page rather than a script.
3. Settle whether operating-system packages are matched against the upstream product as
   well as the distribution feed (F3); if they are, make it a per-repository choice.
4. The client IP on `PROXY_SCAN_BLOCKED` rows (F4), and `quarantine_source: scan_policy` from
   the scanner so an acknowledgement releases the hold (F5).
5. The open issues the walkthrough is designed around: #5149 (`@types/*`), #5153
   (acknowledgements that survive), #5143 (a crate graded as itself). When each lands, the
   corresponding gate moves from `BLOCKED` to `PASS` without a change to the walkthrough.
6. Web UI: a card and a list for `proxy_blocked`, the hold queues, and the instance lock on
   the repository settings page (the backend has all three; this build of the UI shows the
   proxy-scan panel and the dashboard counter only).

## What this walkthrough did not do

- Virtual repositories. A Virtual applies the stricter of its own and its members' policies;
  the "non-scanning member addressed directly" gap in the scan-on-proxy documentation is
  worth its own gate.
- OCI images: a different gate (the manifest, then the blobs), with its own open bug (#5146).
- The other five formats gated in 1.12.0 (RubyGems, Composer, Pub, Conan, CocoaPods, Swift)
  and RPM. The story is the same; the clients are not.
- Maven and Gradle's publish-age gate (#4997), a different control (time, not findings).
- A second gate on the same proxies, such as the age gate or curation, which the AI coding
  agent walkthrough covers for PyPI and npm.
