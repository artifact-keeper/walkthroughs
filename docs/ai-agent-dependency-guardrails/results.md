# Results

`make reproduce` on the test host: `make clean && make all && make gates`, twice, from an empty
registry. Host: Ubuntu 26.04, 40 cores, 108 GB RAM, rootless podman 5.7; Artifact Keeper 1.11.7
(web 1.11.1). Run on 2026-10-27.

## The gates

| Gate | Checks | Result |
|---|---|---|
| G1 Sandbox | from `agent-net`, `ak.internal` answers; pypi.org, registry.npmjs.org, github.com do not even resolve | PASS |
| G2 Happy path | `uv sync --locked` and `npm ci` in the sandbox; the app starts the internal MCP server and calls it; every download host in both lockfiles is `https://ak.internal`; no credentials in project files | PASS |
| G3 Names | invented, look-alike and unreviewed-MCP names refused with `403 curation_blocked` before any fetch; `policies/approve.sh` makes one installable | PASS |
| G4 Cooldown | a 10-minute-old release is left out of the index and `451 age_gate_blocked` when pinned; unpinned resolves the newest old-enough version on PyPI and npm; the reviewed exception is approved | PASS |
| G5 Name squat | public `acme-agent-tools` and `@acme/tickets-mcp` 99.0.0 never offered; `@acme/*` never fetched from npmjs | PASS |
| G6 Known-vulnerable | `langchain` 0.0.141 (critical) and `body-parser` 2.3.0 (high) refused `403 scan_blocked` | PASS |
| G7 MCP servers | the internal server installs pinned and runs; `npx -y` of an unreviewed server refused | PASS |
| G8 Agent token | no direct remote (404), no admin API (403), no publish (403) | PASS |
| G9 Audit | scan refusals and held versions listable; curation refusals and all refusals in the audit log need F1 | BLOCKED (F1) |
| G10 Reproducible | two clean runs, same results | PASS |

```text
run 1: PASS in 4 min 55 s (2026-10-27T20:49:41Z on the lab host)
run 2: PASS in 4 min 49 s (2026-10-27T20:54:30Z on the lab host)
```

## Timings

With the container images already on the host (a first run also pulls about 3 GB):

| Step | Time |
|---|---|
| `make all` + `make gates` from an empty registry | about 5 min |
| registry cold start to `/readyz` | about 30 s |
| `uv lock` of the app (36 packages) through the registry | 8 s |
| `npm ci` (96 packages), cold registry: every tarball fetched and scanned | about 1 min |
| `npm ci`, warm registry | 3 s |
| the twelve-step agent session | about 50 s |

## What the agent session showed

| | Count |
|---|---|
| installs the agent attempted | 12 |
| served | 5 (one reviewed package, two resolved to an older release, two resolved to the internal package) |
| refused by the approved list | 3 |
| refused by the cooldown | 1 |
| refused by the scan | 1 |
| no route | 1 |
| refused by token scope | 1 |

And without any agent involved, in one clean run the cooldown held **30 young versions of 21
packages** that the resolvers came across in the app's own dependency tree, among them
`@modelcontextprotocol/sdk` 1.32.2, every `anthropic` 2.x release, `starlette` 1.10.0 and six `qs`
releases. One release, the `body-parser` security fix, was approved early on purpose.

## What it adds up to

- **The network is the control.** Client configuration is a convenience; the sandbox having one
  route is what makes the registry's answers final.
- **Names and versions are separate questions.** The approved list answers "should this package
  be here at all?"; the cooldown and the scan answer "is this version safe to take today?"
- **The controls collide, and that is fine.** On the day of the run the vulnerable `body-parser`
  was blocked by the scan and its fix by the cooldown. A one-line, reviewed exception resolved
  it. Plan for that queue.
- **1.11.7 covers most of it.** The gaps that matter most are F10 (one age-gated remote per
  virtual) and F1 (refusals in the audit log); see [Findings](findings.md).

**Next:** [Next steps](next-steps.md).
