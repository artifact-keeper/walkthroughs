# Step 3: Publish internal packages and lock the app

This page publishes the two internal packages the way CI would, applies the version policies,
and resolves the application's dependencies once, through the registry, into two lockfiles that
a person reviews. Those lockfiles are the baseline everything else is measured against.

**Make targets:** `make policies exceptions internal`, and `make lock` when you deliberately
re-resolve. The committed lockfiles are `app/uv.lock` and `app/package-lock.json`; `make install`
installs from them.

## Internal packages

| Package | Where | What |
|---|---|---|
| `acme-agent-tools` 1.0.0 | `pypi-internal` | a small helper library ([source](https://github.com/artifact-keeper/walkthroughs/tree/main/ai-agent-dependency-guardrails/internal/acme-agent-tools)) |
| `@acme/tickets-mcp` 1.0.0 | `npm-internal` | an MCP server exposing a ticket queue over stdio, built on `@modelcontextprotocol/sdk` 1.32.1 ([source](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/internal/tickets-mcp/index.js)) |

[`internal/publish.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/internal/publish.sh)
builds and publishes them from the sandbox image, with CI tokens that can write to one hosted
repository each:

```console
$ uv build && uv publish --publish-url https://ak.internal/pypi/pypi-internal/ --username ci --password "$CI_TOKEN" dist/*
$ npm publish --userconfig ci.npmrc          # registry=https://ak.internal/npm/npm-internal/
+ @acme/tickets-mcp@1.0.0
```

A second run is refused, and the script treats that as done: published versions are immutable.

```text
Server returned status code 409 Conflict. Server says: CONFLICT
npm error 409 Conflict - PUT https://ak.internal/npm/npm-internal/@acme%2ftickets-mcp
```

The MCP server pins its SDK to 1.32.1 rather than the newest 1.32.2: on the day of the run 1.32.2
was four days old, and the cooldown in [Step 5](5-hold-fresh-releases.md) would have held it.

## Version policies first, then the lock

[`policies/apply.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/policies/apply.sh)
turns on the age gate and scan-on-proxy before anything is resolved, so the lockfiles can never
contain a version the policies would refuse:

```text
policies: age gate pypi-remote: {"enabled":true,"min_age_days":7,"mode":"upstream_publish_time"}
policies: scan-on-proxy pypi-remote: {"scan_on_proxy":true,"proxy_scan_action":"fail_closed","severity_threshold":"high"}
```

The app's requirements are deliberately loose (`anthropic>=1.12`, `mcp>=1.20`,
`acme-agent-tools==1.0.0`; `@acme/tickets-mcp` 1.0.0), so the resolver chooses. On 2026-10-27 it
chose `anthropic` 1.16.0: every 2.x release was less than a week old.

## Install and run

```console
$ make install       # in the sandbox: uv sync --locked && npm ci --ignore-scripts && .venv/bin/python main.py
Resolved 36 packages in 3ms
Checked 33 packages in 0.90ms
added 96 packages in 3s
anthropic 1.16.0 | mcp 2.3.0 | acme-agent-tools 1.0.0
MCP tools: list_tickets
  #101 [open] Rotate the CI publishing token
  #102 [open] Review held package versions
```

The Python service starts the internal MCP server from `node_modules`, lists its tools and calls
one. Every download in both lockfiles comes from one host:

```text
download hosts in lockfiles: https://ak.internal
files with credentials: none
```

!!! warning "The first install failed, for a good reason"
    The first `npm ci` stopped at `403 … body-parser-2.3.0.tgz - scan_blocked`. The MCP SDK pulls
    express, express pulls `body-parser@^2.3.0`, and 2.3.0 had a high-severity advisory published
    four days earlier. The fixed release was too new for the cooldown. How that was resolved, with
    one reviewed exception, is in [Step 5](5-hold-fresh-releases.md#when-the-fix-is-too-fresh).

**Gate:** G2 (install and run in the sandbox; lockfiles name only the registry).

**Next:** [Step 4: Approve names, not just versions](4-approve-names.md).
