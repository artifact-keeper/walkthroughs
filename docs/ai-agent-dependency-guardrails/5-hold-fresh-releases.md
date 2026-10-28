# Step 5: Hold fresh releases

Compromised releases of popular packages are usually found and pulled within hours or days. A
cooldown keeps every version younger than a few days out until then. Package managers now have
their own cooldown settings (pnpm `minimumReleaseAge`, npm `min-release-age`, uv `exclude-newer`),
but each client has to be configured and an agent can turn it off. This page sets the cooldown
once, at the registry, for every client.

**Make targets:** `make policies` (the age gate) and `make exceptions` (reviewed early approvals).

## The age gate

```console
$ curl … -X PUT https://ak.internal/api/v1/repositories/pypi-remote/age-gate \
    -d '{"enabled":true,"min_age_days":7,"mode":"upstream_publish_time"}'
```

It is set on the remotes; a virtual applies each member's gate. `upstream_publish_time` reads the
upload time from upstream: for the PyPI index it uses PEP 700 `upload-time` and falls back to the
JSON API, for a PyPI download the JSON API, and for npm the packument's `time` map. A version with no publish time is treated as too young.

The gate does two things:

1. **The index leaves young versions out.** An unpinned install resolves the newest version that
   is old enough, without an error.
2. **A request for a young version is held.** The answer is a 451 with a review id, and the
   version waits in the review queue. (For a request that does not name a file, such as an npm
   `latest` lookup, the registry may answer with the newest stored version that is approved or
   not yet reviewed.)

Two limits worth knowing. The cooldown only helps if someone notices a compromise within seven
days: a malicious release of an approved name that stays undetected for a week is served. And on
PyPI the age is the release's, taken from its earliest file, so a file added later to an old
release is not held ([findings](findings.md)). Lockfiles, and reviewing lockfile changes, cover
what the cooldown does not.

## What the agent gets

Pinned to a release published 10 minutes ago, on the lab upstream (agent steps 5 and 6). These
steps point uv at the lab virtual with `--config-file /etc/uv/lab.toml` and resolve with
`--dry-run`; the 451 below is the registry's answer when the file itself is requested:

```console
$ uv --config-file /etc/uv/lab.toml pip install --system --dry-run lab-agent-sdk==1.1.0
  cause: Because there is no version of lab-agent-sdk==1.1.0 and you require lab-agent-sdk==1.1.0, we can conclude that your requirements are unsatisfiable.

$ uv --config-file /etc/uv/lab.toml pip install --system --dry-run lab-agent-sdk
 + lab-agent-sdk==1.0.0
```

```text
GET https://ak.internal/pypi/pypi-lab-virtual/simple/lab-agent-sdk/lab_agent_sdk-1.1.0-py3-none-any.whl
451 Unavailable For Legal Reasons
{"error":"age_gate_blocked","message":"Package version is younger than the configured age threshold and is pending review",
 "min_age_days":7,"package":"lab-agent-sdk","requested_age_days":0,"review_id":"17835d31-…","version":"1.1.0"}
```

npm behaves the same way:
`npm install --registry https://ak.internal/npm/npm-lab-virtual/ lab-mcp-weather` installs 2.0.0, because 2.1.0, the
`latest` upstream, is ten minutes old (agent step 7).

There is no client-side cooldown anywhere in the sandbox. The registry does this alone.

On a real package, the same day: every `anthropic` 2.x release was less than seven days old on
2026-10-27, so `anthropic>=2` could not be satisfied and the app resolved 1.16.0.

## When the fix is too fresh

A cooldown and a vulnerability scan will eventually meet, and on the day of this run
(2026-10-27) they did.
`npm ci` of the app failed:

```text
npm error 403 403 Forbidden - GET https://ak.internal/npm/npm-virtual/body-parser/-/body-parser-2.3.0.tgz - scan_blocked
```

- `body-parser` 2.3.0 reaches the app through the MCP SDK and express (`^2.3.0`).
- GHSA-27r3-jxmh-p828 (CVE-2026-111181, high), published 2026-10-23, affects 2.0.0 up to 2.4.0, so
  scan-on-proxy refused 2.3.0 ([Step 7](7-refuse-known-vulnerable.md)).
- The fix, 2.4.0, was published on 2026-10-22: five days old that day, held by the cooldown.

Each control did its job; together they left no installable version. The way out is the age
gate's review queue, where a person approves one version early and says why.
[`policies/exceptions.txt`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/policies/exceptions.txt)
records that decision:

```text
npm body-parser 2.4.0 security fix for GHSA-27r3-jxmh-p828 / CVE-2026-111181 (body-parser >=2.0.0 <2.4.0, high); …
```

and [`policies/exceptions.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/policies/exceptions.sh)
applies it: request the version, take the `review_id` from the 451, approve it with the reason.

```console
$ curl … https://ak.internal/npm/npm-remote/body-parser/-/body-parser-2.4.0.tgz
{"error":"age_gate_blocked",…,"package":"body-parser","requested_age_days":5,"review_id":"3d2c97b9-…","version":"2.4.0"}
$ curl … -X POST https://ak.internal/api/v1/admin/age-gate/reviews/3d2c97b9-…/approve \
    -d '{"reason":"security fix for GHSA-27r3-jxmh-p828 (body-parser < 2.4.0, high)"}'
{"status":"approved","package_name":"body-parser","package_version":"2.4.0",…}
```

After that, `npm-virtual` lists 2.4.0 as `latest`, `make lock` resolves it, and the install in
[Step 3](3-publish-and-lock.md) goes through. The approval stays for that version (unless
the gate's mode or upstream changes, which sends reviews back to pending) and is recorded in the
audit log. Anyone can create a pending review by requesting a version, including one that does
not exist, so check a review against upstream before approving it. Once 2.4.0 is seven days old the script finds nothing to approve.

**Gate:** G4.

**Next:** [Step 6: Own your internal names](6-own-your-names.md).
