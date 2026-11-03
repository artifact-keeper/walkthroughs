# Step 6: Prove it fails safely

!!! danger "Draft, run against `main`"
    Output on this page is from the run of 2026-11-03 against the Artifact Keeper `main`
    image (revision `12808b8`), pending a re-run on the 1.12.0 candidate. See [Results](results.md).

A gate is judged by its failures. The checks on this page are the last gate, G9, in
[`gates/run-all.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/one-gate-every-package-manager/gates/run-all.sh);
each one asks the registry something a careful attacker, a tired on-call engineer or a
retrying CI job would.

**Make target:** `make gates` (runs G1 to G9; this page is G9).

## The side door is shut

The web UI's download button and `GET /api/v1/repositories/{key}/download/*path` serve any
repository's files, and that route has no per-format identity to run the gate against. For
a Remote that scans, it refuses instead of serving unscanned:

```text
GET /api/v1/repositories/go-proxy/download/golang.org/x/text/@v/v0.21.0.zip
HTTP 403 {"error":"scan_on_proxy_route_required","file":"v0.21.0.zip","handler":"go","reason":"scan-on-proxy is enabled for this repository; proxied go files are served only through the go format route, which scans them"}
```

Under every action, `record_only` included, and for every path including metadata.

## Inconclusive is refused

Two cases where the scanner cannot determine the release an operating-system package
should be graded against, and so cannot grade it at all. Under `fail_closed` that is a
`423`, never the bytes.

An Alpine branch that names no fixed release:

```text
GET /alpine/alpine-proxy/latest-stable/main/x86_64/curl-8.23.0-r0.apk
HTTP 423 {"error":"scan_pending","file":"curl-8.23.0-r0.apk","reason":"artifact is being scanned; retry shortly"}
```

`latest-stable` is whatever Alpine's newest release is this month; the gate grades against
the release the branch names, and `latest-stable` names none. Pin the branch (`v3.22`) in
`/etc/apk/repositories`, which is good practice anyway.

A Debian Remote that has never served its `Release`:

```text
GET /debian/debian-proxy-fresh/pool/main/h/hello/hello_2.10-3_amd64.deb
HTTP 423 {"error":"scan_pending","file":"hello_2.10-3_amd64.deb","reason":"artifact is being scanned; retry shortly"}
```

The gate finds the Debian release in the Remote's cached `InRelease`, which any
`apt update` through it caches; a package pulled before that, whose version carries no
`+deb12uN` or `~bpo` marker, names no release and is withheld. The gate creates
`debian-proxy-fresh` for this check. The `reason` text ("being scanned; retry shortly") is
the generic one for a 423 and is wrong for both of these cases: nothing is being scanned
and a retry changes nothing. A small finding for the message.

## The lock holds

`repoadmin` is a user with the `admin` action on `go-proxy` and nothing else
(`POST /api/v1/permissions` with `target_type: repository`). After the instance
administrator's lock from [Step 4](4-enforce.md):

```text
repoadmin: PUT /api/v1/repositories/go-proxy/security {"proxy_scan_action":"record_only"}
HTTP 403 {"code":"FORBIDDEN","message":"This repository's proxy scan policy was set by an instance administrator. A repository administrator can tighten it, but only an instance administrator can turn proxy scanning off, move the proxy scan action towards record_only, or loosen its severity threshold."}
repoadmin: PUT /api/v1/repositories/go-proxy/security {"severity_threshold":"medium"}
HTTP 200
```

Tightening (a lower threshold) is accepted; weakening is refused with a message that says
who can. The lock is per repository, visible at `config.instance_locked` on
`GET /api/v1/repositories/{key}/security` and in `GET /api/v1/security/configs`.

## A retry loop cannot flood the audit

Twelve pulls of the refused `lodash 4.17.15` within a few seconds, counted 65 seconds later:

```text
attempts=1 aggregated=false at 2026-11-03T03:30:43.305402Z
attempts=11 aggregated=true at 2026-11-03T03:31:43.306957Z
```

Two rows: the first refusal at once, the eleven repeats as one summary row when the
60-second window closed. A CI job retrying a blocked download writes at most two rows a
minute per replica, and the `attempts` counter still says how hard it tried.

## The refused file stays where the operator can see it

```text
GET /api/v1/repositories/npm-proxy/artifacts  →  … lodash/-/lodash-4.17.15.tgz …
GET /npm/npm-proxy/lodash/-/lodash-4.17.15.tgz
HTTP 403 {"error":"scan_blocked","file":"lodash-4.17.15.tgz","reason":"blocked by inline vulnerability scan policy"}
```

A refused file is committed to the proxy cache with its verdict (1.12.0, #4514), so it stays
in the cache listing, the blocked list and the queue, and every later read through a
scanning Remote is refused from the stored verdict without an upstream request. An
inconclusive file, by contrast, is not cached and is fetched again next time.

## What this walkthrough did not prove

- **A scanner outage.** The engine is in-process; there was no way to take it away without
  stopping the registry. The documented behaviour (`423` under `fail_closed`, served
  `pending` otherwise) was exercised only through the inconclusive cases above.
- **A file over the 200 MiB cap**, which is `423` under `fail_closed` and streams unscanned
  under the other two actions. None of the five package managers' ordinary files approach it.
- **A non-scanning member of a scanning Virtual, addressed directly** (a documented gap):
  no Virtual repositories here.

**Gate:** G9, five checks.

**Next:** [Results](results.md), then [Findings](findings.md) and [Next steps](next-steps.md).
