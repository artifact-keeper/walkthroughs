# Results

`make reproduce` on the test host: `make clean && make all && make gates` from an empty registry,
then `make all && make gates` again on the running stack, then once more from empty. Host: Ubuntu 26.04, 40 cores, 108 GB RAM, rootless podman 5.7; Artifact Keeper 1.11.7
(web 1.11.1). Run on 2026-10-27.

## The gates

| Gate | Checks | Result |
|---|---|---|
| G1 Sandbox | from `agent-net`, `ak.internal` answers; pypi.org, registry.npmjs.org, github.com do not even resolve; public IP addresses are unreachable | PASS |
| G2 Happy path | `uv sync --locked` and `npm ci` in the sandbox; the app starts the internal MCP server and calls it; every download host in both lockfiles is `https://ak.internal`; no credentials in project files | PASS |
| G3 Names | invented, look-alike and unreviewed-MCP names refused with `403 curation_blocked` before any package file is downloaded; other npm spellings of approved names never fetched; `policies/approve.sh` makes one installable | PASS |
| G4 Cooldown | a 10-minute-old release is left out of the index and `451 age_gate_blocked` when pinned; unpinned resolves the newest old-enough version on PyPI and npm; the reviewed exception is approved | PASS |
| G5 Name squat | public `acme-agent-tools` and `@acme/tickets-mcp` 99.0.0 never offered; `@acme/*` never fetched from npmjs | PASS |
| G6 Known-vulnerable | `langchain` 0.0.141 (critical) and `body-parser` 2.3.0 (high) refused `403 scan_blocked` | PASS |
| G7 MCP servers | the internal server installs pinned and runs; `npx -y` of an unreviewed server refused | PASS |
| G8 Agent token | no direct remote (404), no admin API (403), no publish (403) | PASS |
| G9 Audit | scan refusals and held versions listable; curation refusals and all refusals in the audit log need F1 | BLOCKED (F1) |
| G10 Reproducible | three runs (from empty, again without cleaning, from empty), same results | PASS |
| G11 Exposed endpoints | npm `/-/` endpoints the clients do not use answer 404; nothing listens on port 80 | PASS |

```text
run 1 (from empty):        PASS in 4 min 51 s
run 2 (without cleaning):  PASS in 1 min 40 s
run 3 (from empty):        PASS in 4 min 52 s
gates: 10 PASS, 1 BLOCKED, 0 FAIL
```

## Timings

With the container images already on the host (a first run also pulls about 3 GB):

| Step | Time |
|---|---|
| `make all` + `make gates` from an empty registry | about 5 min |
| `make all` + `make gates` again on a running stack | under 2 min |
| registry cold start to `/readyz` | about 30 s |
| `uv lock` of the app (36 packages) through the registry | 8 s |
| `npm ci` (96 packages), cold registry: every tarball fetched and scanned | about 1 min |
| `npm ci`, warm registry | 3 s |
| the twelve-step agent session | about 50 s |

## What the agent session showed

| | Count |
|---|---|
| actions in the scripted session | 12 (ten installs, one bypass attempt, one publish) |
| allowed | 5 (one reviewed package installed; an older release and the internal package resolved on PyPI, dry run; the same two installed on npm) |
| refused by the approved list | 3 |
| refused by the cooldown | 1 |
| refused by the scan | 1 |
| blocked by the network | 1 |
| refused by token scope | 1 |

Installing the app from its lockfiles touches no held version: the locked versions are all old
enough, and the only review is the `body-parser` security fix, approved early on purpose. The
agent's first step, `uv add pydantic`, re-resolves the app, and that alone ran into **11 young
versions of 8 of the app's packages** on 2026-10-27, among them every `anthropic` 2.x release,
`starlette` 1.10.0 and `jiter` 0.18.0. The cooldown left them out and uv took older ones.

## What it adds up to

- **For package downloads, the network is the control.** Client configuration is a convenience;
  the sandbox being able to reach only `ak.internal` is what makes the registry's answers final.
- **Names and versions are separate questions.** The approved list answers "should this package
  be here at all?"; the cooldown and the scan answer "is this version safe to take today?"
- **The controls collide, and that is fine.** On the day of the run the vulnerable `body-parser`
  was blocked by the scan and its fix by the cooldown. A one-line, reviewed exception resolved
  it. Plan for that queue.
- **1.11.7 covers what this walkthrough needs, with workarounds.** The gaps that matter most are
  F10 (one age-gated remote per virtual), F1 (refusals in the audit log) and F7 (no automatic
  look-alike detection on downloads); see [Findings](findings.md).

## Costs

- **Reviewing names.** The approved list started at 135 names (42 PyPI, including build backends, and 93 npm), and every
  upgrade that brings a new transitive dependency needs one more approval. An upgrade can fail on
  a name nobody approved yet (npm reported it as `lru-cache` here).
- **Security fixes wait too.** A seven-day cooldown delays every fix by default; the exception
  queue in [Step 5](5-hold-fresh-releases.md) has to be staffed.
- **Scanner coverage is uneven.** Grype missed the body-parser advisory that the OSV scan found,
  and only a Grype failure refuses a file ([Step 7](7-refuse-known-vulnerable.md)).
- **Curation is a plain approved list.** Look-alikes are refused because nobody approved them,
  not because they were detected ([F7](findings.md)).

**Next:** [Next steps](next-steps.md).
