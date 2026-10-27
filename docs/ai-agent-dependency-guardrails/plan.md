# Plan: an AI coding agent that can only install what the registry allows

Status: design for review, 2026-10-27. Implementation starts against this plan; the gates below
define done. Code lands in `ai-agent-dependency-guardrails/` of this repo. Third walkthrough, after
Rocky Linux image mode and the private conda channel; it reuses the conda walkthrough's registry
pattern (compose project, Caddy with an internal CA, a bare hostname, an internal-only network).

## Who this is for

Platform and security teams at companies rolling out AI coding agents (Claude Code, Codex, Cursor,
Copilot agent mode, Gemini CLI) and MCP servers to their developers. The agents run `uv add`,
`pip install`, `npm install` and `npx` on their own. The team's question is not "can we stop the
agent" but "can we make sure that whatever the agent decides, nothing reaches disk that we would not
have allowed a human to install?"

## The one promise

The agent keeps its autonomy; the registry, not the agent's judgment, decides what reaches disk.
The agent runs on a network whose only reachable host is the registry, so there is no client
setting it can change to get around it.

Everything in the walkthrough serves that promise. Out of scope, and noted as their own future
walkthroughs: model files and datasets from Hugging Face (model supply chain), SBOM and blast
radius after the fact, and signing your own releases end to end.

## Why now (public record, sources checked before publishing)

| Pain | Source |
|---|---|
| LLMs invent package names; 5.2 % of suggested packages from commercial models and 21.7 % from open models did not exist (576k samples, 16 models) | Spracklen et al., USENIX Security 2025, arXiv:2406.10279 |
| An attacker-free placeholder for a hallucinated name, `huggingface-cli`, got about 30k downloads and was copied into a public README | Lasso Security research, 2024 |
| A compromised release of a popular AI library on PyPI was live for hours and ran on every interpreter start | LiteLLM 1.82.7/1.82.8 incident write-ups, 2026 |
| Self-replicating npm worms (Shai-Hulud, September and November 2025) and the chalk/debug compromise hit packages that MCP SDKs depend on transitively | Semgrep, Sysdig, Snyk, Stacklok write-ups |
| Malware that drives the developer's own AI agent with permission checks off to hunt for secrets | Nx `s1ngularity` incident, Snyk write-up |
| Malicious and typosquatted MCP servers and agent SDK look-alikes | `postmark-mcp` (2025); OSV MAL entries for `openai-mcp`, `anthropic-toolkit` |
| Package managers now ship release cooldowns, each with its own setting | pnpm `minimumReleaseAge`, npm `min-release-age`, uv `exclude-newer`, yarn, bun |

Every number above is re-checked against its primary source before it appears in the walkthrough,
the blog or a video. The walkthrough itself uses no real malware (see Decisions).

## Requirements the walkthrough must demonstrate

| # | Requirement | Where it is demonstrated |
|---|---|---|
| R1 | The agent's sandbox can reach the registry and nothing else | `agent-net` with `internal: true`; `curl https://pypi.org` fails from the agent |
| R2 | Python and Node clients use the registry with no per-project configuration the agent could edit away | `uv.toml` and `.npmrc` baked into the agent image; `index-strategy = "first-index"` for uv |
| R3 | Read-only, repository-scoped tokens for the agent; publishing tokens only in CI | Artifact Keeper repo tokens |
| R4 | Package names an LLM invented, and look-alikes of popular names, are refused before any bytes are fetched | curation in approved-list mode: one allow rule per reviewed name (generated from the committed lockfiles) and a catch-all block |
| R5 | Brand-new releases are held for review, for every client at once | age gate on the PyPI and npm remotes, review queue, last-known-good fallback for npm and PyPI |
| R6 | Internal package names cannot be shadowed by a public package | virtual repositories with name ownership (PyPI and npm), npm scope allow-list on the remote |
| R7 | Versions with known vulnerabilities are refused, fail closed | scan-on-proxy with a severity threshold |
| R8 | MCP servers are installed pinned, from the registry, never `npx -y <name>@latest` from the internet | internal `@acme/tickets-mcp` resolved through the npm virtual, run in the sandbox |
| R9 | Security can answer "what did the agent try to install, and what was refused?" | audit events and the proxy-blocked list |
| R10 | Everything runs in containers, TLS from an internal CA, a bare hostname, rootless podman, no sudo | `ak.internal` via Caddy, as in the conda walkthrough |

## Environment

- **Registry**: Artifact Keeper **1.11.7** (latest release), compose project `ak-agent` from the
  upstream quickstart plus an override, rootless podman. Caddy answers `https://ak.internal` on the
  compose network with its internal CA; the only host port is `127.0.0.1:30445`. The only container
  with internet access is Artifact Keeper.
- **Networks**: `ak-agent-net` (registry and Caddy) and `agent-net` (`internal: true`, no route out),
  which the agent sandbox and the test runner join. Caddy is on both.
- **Repositories**:
  - `pypi-remote` (upstream `https://pypi.org`), `pypi-internal` (hosted), `pypi-virtual`
    (internal first, then remote): the only PyPI index the agent knows
  - `npm-remote` (upstream `https://registry.npmjs.org`), `npm-internal` (hosted, scope `@acme`),
    `npm-virtual`: the only npm registry the agent knows
  - `oci-dockerhub` (remote) for the `python` and `node` base images of the agent sandbox
  - `trust` (generic): the CA certificate the sandbox trusts
- **Policies**: age gate `min_age_days: 7` on the remotes (`mode: upstream_publish_time`);
  curation on the virtuals in approved-list mode (allow rules for the names in the reviewed
  lockfiles `app/uv.lock` and `app/package-lock.json`, then a catch-all `block`); scan-on-proxy
  `fail_closed` at severity `high` (Grype); an upstream filter on `npm-remote` that excludes
  `@acme/*`; explicit member priorities on the virtuals (internal 1, public 2, lab 3) and
  `npm_virtual_isolate_hosted_names` on `npm-virtual`.
- **Demo application** `acme-agent`:
  - a Python service (uv project) using the `anthropic` and `mcp` SDKs and an internal library
    `acme-agent-tools` from `pypi-internal`
  - a TypeScript MCP server `@acme/tickets-mcp` built on `@modelcontextprotocol/sdk`, published to
    `npm-internal`
  No model API key is needed: nothing calls a model. The application only has to install and start.
- **The coding agent** is simulated by `agent/agent.sh`, which replays a scripted plan
  (`agent/plan.yaml`): the installs a real agent session might attempt, including the ones drawn
  from the incidents above. Each step records the command, the registry's answer, and the exit code.
  A note in the docs shows the same sandbox used with a real agent CLI.
- **The public upstream for negative tests**: a local static PyPI index and npm registry
  (`gates/fake-upstream/`) serving packages we build, with publish times we control, so
  the cooldown and name-squat tests are deterministic. The backend allows that one private address
  through `AK_SSRF_ALLOW_PRIVATE_CIDRS`, as in the conda walkthrough.

## Decisions

1. **No real malware, ever.** Refusals are demonstrated with (a) names that do not exist or that
   imitate a popular name (refused by curation before any fetch), (b) packages we build and serve
   from the fake upstream with controlled publish times (cooldown, name squat), and (c) real, old
   releases with published CVEs (scan-on-proxy). Malicious incidents are cited, not reproduced.
2. **The registry is the control, the client settings are the second layer.** The agent image also
   sets uv `exclude-newer` and npm `min-release-age`, but the gates prove the refusal happens at the
   registry with those client settings removed.
3. **Approved list for names, cooldown for versions.** In 1.11.7 a curation `block` rule is what
   refuses a download (before any upstream fetch); typosquat and popularity rules do not run on the
   proxy path, and a `review` default does not stop a pull. So the walkthrough runs curation as an
   approved list: the names in the reviewed lockfiles are allowed, everything else is blocked with
   a reason, and approving a new name is one allow rule (`policies/approve.sh`). Versions of
   approved names still pass the age gate and the scan. Automatic look-alike detection on the
   proxy path is filed as F7.
4. **MCP servers are packages.** They get the same treatment as any dependency: hosted for internal
   ones, pinned versions, installed from the virtual, never `@latest` from the internet.
5. **Every refusal is quoted verbatim** from the run on the test host, in the docs, blog and videos.
6. **Reproducible on a clean host**: `make all && make gates` from an empty registry on the lab host
   (Ubuntu 26.04, rootless podman installed for this walkthrough), then a second run to prove the
   targets are idempotent. Timings are recorded from those runs.

## Artifact Keeper capabilities used (verified in the 1.11.7 source)

| Capability | Where |
|---|---|
| Curation refusal `403 {"error":"curation_blocked","package":…,"reason":…}` | `backend/src/api/handlers/proxy_helpers.rs` (`curation_blocked_response`); applied in `npm.rs` and `pypi.rs` |
| Curation rules and review API `/api/v1/curation/{rules,packages,…}`, typosquat and popularity evaluators | `api/handlers/curation.rs`, `services/curation/` |
| Age gate `451 {"error":"age_gate_blocked","review_id",…,"message":"Package version is younger than the configured age threshold and is pending review"}`, per-repo `PUT …/{key}/age-gate`, review queue `/age-gate/reviews/{id}/approve` | `proxy_helpers.rs` (`age_gate_blocked_body`), `api/handlers/age_gate.rs` |
| Scan-on-proxy `scan_blocked` / `scan_pending` | `proxy_helpers.rs` |
| PyPI virtual name ownership (`PypiOwnershipGuard`); npm virtual name ownership | `pypi.rs`, `proxy_helpers.rs` |
| npm scope allow-list `PUT …/{key}/npm-scope-policy` (`npm_allowed_scopes`, `npm_allow_unscoped`) | `npm.rs`, `repositories.rs` |
| Repo-scoped tokens | `api/handlers/repo_tokens.rs` |

## Artifact Keeper gaps (become issues and fix branches, as in the conda walkthrough)

Found by the audit of 1.11.7; each is confirmed on the test host first. Fixes are prepared locally,
built into the demo image, and listed for Brandon's approval before any issue or PR is opened.

| # | Gap | Gate |
|---|---|---|
| F1 | No refusal writes an audit row: curation, scan-on-proxy and age-gate blocks are all missing from `/api/v1/admin/audit` (`AGE_GATE_QUEUED` is defined, never emitted); only the proxy-scan list and the age-gate review list record them | G9 |
| F2 | npm provenance attestations cannot be verified (`NPM_UNSUPPORTED_REASON`); publisher trust for npm falls back to review | stretch |
| F3 | PEP 740 attestations are only checked by curation on proxied packages, never on publish or promotion of internal ones | stretch |
| F4 | No age gate for OCI images (the agent's base images) | noted |
| F5 | Proxied bytes are cached before the scan verdict (#4514) | noted |
| F6 | Site docs: uv, uvx, npx and MCP servers through Artifact Keeper (`uv.toml`, `.npmrc`, `index-strategy`) | docs |
| F7 | Curation `popularity` / typosquat rules and `block_unknown` apply only on the staging sync path, which the API cannot configure (`curation_source_repo_id` is never set by a handler); apply them to proxy downloads | G3 (look-alike detection) |
| F8 | npm curation checks only the tarball, without the version; a version-limited rule is skipped and the packument is served unfiltered | G3 |
| F9 | Curation fails open when rule evaluation errors | noted |

## Gates

| # | Gate | Proof |
|---|---|---|
| G1 | Sandbox: from `agent-net`, `https://ak.internal` answers and `https://pypi.org`, `https://registry.npmjs.org` do not | curl output |
| G2 | Happy path: `uv sync` and `npm ci` of `acme-agent` succeed in the sandbox; downloads are served by the registry; no credentials in `uv.lock`, `package-lock.json`, `pyproject.toml` or `package.json` | client output, download records, grep |
| G3 | Invented and look-alike names: the agent's attempts are refused with `403 curation_blocked` and a reason, before any upstream fetch; `policies/approve.sh <name>` makes one installable | HTTP bodies, review API |
| G4 | Cooldown: a version published upstream minutes ago gets `451 age_gate_blocked` with a `review_id`; npm and PyPI resolve the last-known-good version; approval releases it; works with client-side cooldowns removed | client output, review API |
| G5 | Name squat: `@acme/tickets-mcp 99.0.0` and `acme-agent-tools 99.0.0` on the public upstream are never offered by the virtuals; unpinned installs keep the internal versions | metadata diff, lockfiles |
| G6 | Known-vulnerable versions are refused `scan_blocked`, fail closed | HTTP bodies |
| G7 | MCP server: `@acme/tickets-mcp@1.0.0` installs from `npm-virtual` and starts in the sandbox; `npx -y` of an unknown MCP package is refused | output |
| G8 | Tokens: the agent's token reads the virtuals and cannot publish or read admin APIs | 403 transcripts |
| G9 | Audit: every refusal from G3, G4, G6 and G7 can be listed with time, client and reason | proxy-scan list and age-gate reviews today; audit API needs F1 |
| G10 | Reproducible: `make clean && make all && make gates` on the lab host from an empty registry, twice, same results | run logs, timings |

## Media built from the verified run

Made only after G10 passes, from the same run's output:

1. **Blog post** (about 1,200 words): the problem, the one promise, the five refusals with their real
   messages, what to copy into your own setup, the gaps we filed.
2. **Short video** (about 50 s) with the walkthrough video kit (`poc/kit`), Brandon's voice: Sandbox,
   Invented names, Cooldown, Name squat, Known-bad, MCP. Same look as the Rocky and conda videos.
3. **Long video** (8 to 12 minutes): the walkthrough step by step with real terminal recordings
   (VHS) of the run on the lab host, animated diagrams between steps, the same voice.

## Layout

```text
ai-agent-dependency-guardrails/
  Makefile            registry-up, bootstrap, policies, internal, sandbox, agent, gates, all, clean
  registry/           compose override, Caddy, up.sh, down.sh, bootstrap.sh (repos, tokens, CA)
  policies/           age-gate.json, curation-rules.json, scan-policy.json, npm-scope-policy.json, apply.sh
  internal/           acme-agent-tools (Python), @acme/tickets-mcp (TypeScript), build + publish
  sandbox/            Containerfile (uv, node, CA, uv.toml, .npmrc), build.sh
  app/                acme-agent: pyproject.toml, package.json, lockfiles
  agent/              agent.sh, plan.yaml (scripted session), out/ transcripts
  gates/              g01..g10, fake-upstream/, lib.sh, run-all.sh
docs/ai-agent-dependency-guardrails/
  index.md, 1-…md to 7-…md, results.md, findings.md, next-steps.md, plan.md, images/
```
