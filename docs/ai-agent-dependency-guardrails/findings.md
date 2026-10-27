# Findings

The lab record behind this walkthrough: what Artifact Keeper 1.11.7 does not do yet (each one
an issue and a fix proposal, listed for approval before anything is filed), and what surprised
us while building it. Every behaviour here was reproduced on the test host (Ubuntu 26.04,
rootless podman 5.7, Artifact Keeper 1.11.7, web 1.11.1).

## Artifact Keeper gaps

| # | Gap | Effect here | Gate |
|---|---|---|---|
| F1 | No refusal writes an audit row. Curation blocks, scan-on-proxy blocks and age-gate holds are absent from `GET /api/v1/admin/audit`; `AGE_GATE_QUEUED` is defined in `audit_service.rs` but never emitted. Scan blocks are visible in `GET /repositories/{key}/security/proxy-scans`, held versions in the age-gate review list; curation blocks are visible nowhere. | "What did the agent try?" can only be answered in part | G9 |
| F2 | npm provenance attestations cannot be verified (`NPM_UNSUPPORTED_REASON` in `attestation_verify.rs`); publisher trust for npm falls back to review. | not used | stretch |
| F3 | PEP 740 attestations are checked only by curation on proxied packages, never when an internal package is published or promoted. | not used | stretch |
| F4 | No age gate for OCI images. The sandbox's base images are pulled through the registry but not held. | noted | |
| F5 | Proxied bytes are cached before the scan verdict (#4514): a refused file still sits in the proxy cache. | noted | |
| F6 | No site docs for uv, uvx, npx or MCP servers through Artifact Keeper (`uv.toml`, `index-strategy`, `.npmrc`, credentials). This walkthrough's `sandbox/` is a starting point. | docs | |
| F7 | Curation `popularity` rules (typosquat distance, homoglyphs, minimum downloads, `block_unknown`) run only on the staging sync path, and `curation_source_repo_id` is never set by any API handler. On a remote or virtual, only `block` pattern rules refuse a download, and a `review` default action does not stop a pull. The walkthrough therefore runs curation as an approved list; automatic look-alike detection on downloads would let teams run "allow unless suspicious" instead. | look-alikes are refused because they are unknown, not because they are detected | G3 |
| F8 | npm curation checks only the tarball, without the version: a version-limited rule is skipped, and the packument is served unfiltered, so a client sees versions it cannot download. | the npm error is a 403 on the tarball, after resolution | G3 |
| F9 | Curation fails open when rule evaluation errors (`proxy_helpers.rs`, the evaluation error branch serves the request). | noted | |
| F10 | **A virtual with two age-gated remotes refuses a package that only the second one serves.** For a download, the virtual runs each remote member's age gate before checking that the member has the file; the first gated member that does not list the package has no publish time, treats the version as too young, and the 451 ends the request. Both PyPI (`pypi.rs`, the member loop calling `enforce_pypi_download_age_gate`) and npm are affected. | the lab upstream lives in its own virtuals (`pypi-lab-virtual`, `npm-lab-virtual`) | G4, G5 |

### F10 in detail

With `pypi-virtual` = internal (1), `pypi-remote` (2), `pypi-lab` (3), all remotes gated at 7 days:

```text
GET /pypi/pypi-lab/simple/lab-agent-sdk/lab_agent_sdk-1.0.0-py3-none-any.whl       200   (60 days old, served by the lab)
GET /pypi/pypi-virtual/simple/lab-agent-sdk/lab_agent_sdk-1.0.0-py3-none-any.whl   451   age_gate_blocked
```

`idna` (on pypi.org, not on the lab) resolves through the same virtual, because the first gated
member has it. The npm virtual behaves the same way, and there even a package that both members
could be asked about is refused when one of them returns 404: with `npm-lab`'s gate on,
`ms@2.1.3` (published 2020) answered 451 through `npm-virtual`; with it off, 200.

Real setups hit this with any second upstream: PyPI plus the PyTorch index, npmjs plus GitHub
Packages. Proposed fix: in the virtual's member loop, skip a remote member whose upstream metadata
does not list the requested version (it does not serve the file) instead of applying its gate;
keep fail-closed for a member that does list the version but has no usable publish time.

## What we learned building it

- **The cooldown is visible on a real package the day you run it.** On 2026-10-27 every
  `anthropic` 2.x release was less than 7 days old (2.0.0 on 2026-10-21 to 2.3.0 on
  2026-10-23), so `anthropic>=2` was unsatisfiable through the registry and `anthropic>=1.12`
  resolved to 1.16.0. That is the policy working, not a failure; the app pins `>=1.12`.
- **The scan and the cooldown met on a real advisory.** The MCP TypeScript SDK 1.32.1 depends on
  express, which pulls `body-parser@^2.3.0`. On the day of the run, `body-parser` 2.3.0 matched
  GHSA-27r3-jxmh-p828 / CVE-2026-111181 (high; published 2026-10-23, fixed in 2.4.0), found via
  OSV, so scan-on-proxy refused it. The fix, 2.4.0, was published on 2026-10-22: five days old,
  so the cooldown held it. The way out is the review queue: `policies/exceptions.txt` records the
  early approval and its reason, and `policies/exceptions.sh` applies it. Without the exception,
  `npm ci` fails with `403 … body-parser-2.3.0.tgz - scan_blocked`.
- **Grype missed what OSV found.** The proxy scan log for body-parser shows Grype with
  0 vulnerabilities and the registry's dependency scan (OSV) with one high finding. Run both.
- **`private` repositories read as "not found" to a non-admin token.** With `visibility: private`,
  the builder user's token (with a repo selector naming the image proxies) got
  `repository not found` from `podman pull`. `internal` visibility plus a repo selector on every
  token gives the intended result: any signed-in user may read, each token only its repositories.
- **The agent's mistakes were ours first.** Two plan steps failed on the first replay because our
  test assumptions were wrong, not the registry: `anthropic` 1.16 depends on `httpx2`, not
  `httpx`, so `httpx` was correctly not approved; and `uv pip install --dry-run` never downloads,
  so nothing was scanned. The plan now adds `pydantic` and installs into a scratch target.
- **`uv` images moved to Debian trixie.** `ghcr.io/astral-sh/uv:*-bookworm-slim` tags are gone for
  0.13.x; the sandbox uses `0.13.6-python3.12-trixie-slim`.
- **uv and npm do not show why.** A refusal reaches uv as "403 Forbidden" and npm as
  `E403 … - scan_blocked`; the JSON body with the reason is only visible to a direct request. The
  agent transcripts include that request (`# what the registry said`) for every refusal.
