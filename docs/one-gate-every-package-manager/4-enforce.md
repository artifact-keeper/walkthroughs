# Step 4: Enforce

!!! danger "Draft, run against `main`"
    Output on this page is from the run of 2026-11-03 against the Artifact Keeper `main`
    image (revision `12808b8`), pending a re-run on the 1.12.0 candidate. See [Results](results.md).

Fix what the preview flagged, switch the five proxies to `fail_closed`, lock the policy, and
run the builds again: the ordinary ones must pass, the known-bad ones must fail, and every
failure must be the intended one.

**Make targets:** `make baseline PHASE=record BASELINE=fixed`, `make enforce lock`,
`make baseline PHASE=enforce BASELINE=fixed`, `make known-bad PHASE=enforce`.

## Fix what the preview flagged

The preview in [Step 2](2-record-first.md) starred two ordinary pulls and three Debian
packages next to the deliberate fixtures. A team does this part by hand, with the preview as
the work list; here the answers are in
[`clients/baseline-fixed/`](https://github.com/artifact-keeper/walkthroughs/tree/main/one-gate-every-package-manager/clients/baseline-fixed):

| Flagged | Decision | Why |
|---|---|---|
| Go: `golang.org/x/text v0.21.0` (high, fixed in 0.39 and 0.41) | upgrade to `v0.43.0`, `cobra` to `v1.10.2` | the fix exists; `x/text 0.43` needs Go 1.26, so the client image moves to `golang:1.26-alpine` |
| npm: `express 4.21.2` pulls `path-to-regexp 0.1.12` (high, fixed in 0.1.13) | upgrade to `express 5.1.0` | the fix exists |
| apt: `curl` (critical, 38 findings, no fixed version), `jq` (high, fix in the security suite), `libxml2` (critical) | drop them from the ordinary list; keep `ca-certificates`, `bash`, `git` | nothing to upgrade to inside `bookworm main`; see [Step 5](5-handle-an-exception.md) for what an exception would need |
| apk: `curl` (critical, 41 findings, no fixed version) | drop it; keep `jq`, `libxml2`, `git` | as above |
| cargo: nothing above `high` (`syn` and `anyhow` carry `medium` findings and are served) | nothing | |

The Debian and Alpine rows are the uncomfortable ones, and the walkthrough does not pretend
otherwise: on this day the scanner refuses `curl` on both distributions, with the same
2026 CVE ids and no fixed version on either, and a team that needs `curl` in its base image
has no upgrade to make. Whether those verdicts are right is finding F3 in
[Findings](findings.md); what a team can do about a proxied verdict it disagrees with is the
second half of [Step 5](5-handle-an-exception.md).

Run the fixed baselines once more under record-only, and check the preview again, before
enforcing. (In `make all` this is the `PHASE=record-fixed` run.)

## Enforce and lock

```console
$ make enforce lock
THRESHOLD=high policy/mode.sh fail_closed
policy: go-proxy {"scan_on_proxy":true,"proxy_scan_action":"fail_closed","block_on_policy_violation":true,"severity_threshold":"high","instance_locked":false}
policy: cargo-proxy {"scan_on_proxy":true,"proxy_scan_action":"fail_closed","block_on_policy_violation":true,"severity_threshold":"high","instance_locked":false}
policy: npm-proxy {"scan_on_proxy":true,"proxy_scan_action":"fail_closed","block_on_policy_violation":true,"severity_threshold":"high","instance_locked":false}
policy: debian-proxy {"scan_on_proxy":true,"proxy_scan_action":"fail_closed","block_on_policy_violation":true,"severity_threshold":"high","instance_locked":false}
policy: alpine-proxy {"scan_on_proxy":true,"proxy_scan_action":"fail_closed","block_on_policy_violation":true,"severity_threshold":"high","instance_locked":false}
policy/lock.sh on
policy: go-proxy {"proxy_scan_action":"fail_closed","severity_threshold":"high","instance_locked":true}
policy: cargo-proxy {"proxy_scan_action":"fail_closed","severity_threshold":"high","instance_locked":true}
policy: npm-proxy {"proxy_scan_action":"fail_closed","severity_threshold":"high","instance_locked":true}
policy: debian-proxy {"proxy_scan_action":"fail_closed","severity_threshold":"high","instance_locked":true}
policy: alpine-proxy {"proxy_scan_action":"fail_closed","severity_threshold":"high","instance_locked":true}
```

The same `PUT …/security` as in [Step 2](2-record-first.md), with `proxy_scan_action` changed
to `fail_closed`. The verdicts recorded during record-only are reused: nothing is scanned
again, and every file that was starred in the preview is refused from now on. Then the lock
(#4363): `{"instance_locked": true}` from an instance administrator. From here a repository
administrator can tighten any of these five policies and gets `403` for anything that weakens
one: turning `scan_on_proxy` off, moving towards `record_only`, raising the threshold.
[Step 6](6-prove-it-fails-safely.md) proves it.

Why `fail_closed` and not `fail_open`: `fail_open` serves a first pull while the scan runs and
refuses known-vulnerable bytes afterwards, so the first build to ask for a new bad version
gets it. The team that asked for the gate asked for "never unscanned bytes". The price is on
the next line.

## The ordinary builds, again

```console
$ make baseline PHASE=enforce BASELINE=fixed
baseline go: exit 0 in 3s
baseline cargo: exit 0 in 1s
npm error code E423
npm error 423 Locked - GET https://ak.internal/npm/npm-proxy/mime-types/-/mime-types-3.0.2.tgz - scan_pending
baseline npm: exit 1 in 38s
baseline apt: exit 0 in 4s
baseline apk: exit 0 in 2s
```

Four of five pass. Go, Cargo, apt and apk behave exactly as under record-only, with the
verdicts already stored. npm does not, for a reason that has nothing to do with
vulnerabilities: `express 5.1.0` is a new dependency tree, most of its tarballs had never
been pulled, and under `fail_closed` each one is scanned inline before it is served. npm
fetches about ten tarballs at a time, the scans contend, and some exceed the 30-second
budget the gate gives an inline scan. An over-budget scan is inconclusive, and inconclusive
under `fail_closed` is `423 scan_pending`. npm does not retry a 423; the install fails.

Run it again, and the picture changes:

```console
$ make baseline PHASE=enforce-warm BASELINE=fixed
baseline go: exit 0 in 4s
baseline cargo: exit 0 in 1s
npm error code E423
npm error 423 Locked - GET https://ak.internal/npm/npm-proxy/@types/node/-/node-22.15.3.tgz - scan_pending
baseline npm: exit 1 in 4s
baseline apt: exit 0 in 4s
baseline apk: exit 0 in 2s
```

The second run finds every tarball's verdict stored and serves them at once, except one:
`@types/node`. DefinitelyTyped publishes its tarballs with the package's own directory name
instead of `package/`, the npm gate reads the claimed identity only from
`package/package.json`, and so no `@types/*` tarball ever establishes its identity. Without an
identity the scan is inconclusive, and under `fail_closed` that is a permanent `423`. This is
open issue #5149, planned for 1.12.0; until it is merged a TypeScript project cannot be
installed through a `fail_closed` npm proxy, and the gate G5 reports `BLOCKED(#5149)` for
npm rather than PASS.

Two findings, then, from one `npm install`: F1, the cold-cache `423`s from inline scans over
budget (what a team sees on the first day after enforcing, on every new dependency tree),
and #5149, the permanent one. Both are in [Findings](findings.md), with what the run measured.

!!! note "`fail_open` for the first week"
    `make fail-open` is the middle setting. Under it the cold `npm install` is served
    `pending` and scanned in the background, the known-vulnerable fixtures are still refused
    (their verdicts are stored), and `@types/node` is served because inconclusive is not
    withheld. A team could enforce `fail_open` first and move to `fail_closed` once its
    dependency trees are warm. The walkthrough does not take that path because it would
    hide F1 and #5149; the numbers above are what `fail_closed` costs today.

## The known-bad pulls, again

```console
$ make known-bad PHASE=enforce
# get https://ak.internal/go/go-proxy/golang.org/x/text/@v/v0.3.0.zip: 403 Forbidden (0.144s)
go: golang.org/x/text@v0.3.0: reading https://ak.internal/go/go-proxy/golang.org/x/text/@v/v0.3.0.zip: 403 Forbidden
known-bad go: exit 1 in 1s
error: failed to download from `https://ak.internal/cargo/cargo-proxy/api/v1/crates/smallvec/1.6.0/download`
  {"error":"scan_blocked","file":"smallvec-1.6.0.crate","reason":"blocked by inline vulnerability scan policy"}
known-bad cargo: exit 101 in 1s
npm error 403 403 Forbidden - GET https://ak.internal/npm/npm-proxy/lodash/-/lodash-4.17.15.tgz - scan_blocked
known-bad npm: exit 1 in 2s
E: Failed to fetch https://ak.internal/debian/debian-proxy/pool/main/libx/libxml2/libxml2_2.9.14%2bdfsg-1.3%7edeb12u6_amd64.deb  403  Forbidden [IP: 172.31.60.8 443]
known-bad apt: exit 100 in 3s
ERROR: curl-8.14.1-r4: Permission denied
known-bad apk: exit 1 in 2s
```

Five formats, one answer. Only `cargo` and a direct request show the body; `go` reports the
status, `npm` the status and the reason word, `apt` the status, and `apk` says
"Permission denied" for a 403. [`clients/probe.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/clients/probe.sh)
asks the registry directly and shows what each client was told:

```console
$ clients/probe.sh go-proxy golang.org/x/text/@v/v0.3.0.zip
HTTP 403 X-AK-Scan=- {"error":"scan_blocked","file":"v0.3.0.zip","reason":"blocked by inline vulnerability scan policy"}
$ clients/probe.sh alpine-proxy v3.22/main/x86_64/curl-8.14.1-r4.apk
HTTP 403 X-AK-Scan=- {"error":"scan_blocked","file":"curl-8.14.1-r4.apk","reason":"blocked by inline vulnerability scan policy"}
```

The refusal names the file, never the policy or the findings; those are for the operator,
in [Step 3](3-review-the-queues.md).

**Gates:** G4 (every format's known-bad pull is refused with `403 scan_blocked` and the
client fails), G5 (the fixed baselines pass, cold and warm; npm is `BLOCKED(#5149)`).

**Next:** [Step 5: Handle a legitimate exception](5-handle-an-exception.md).
