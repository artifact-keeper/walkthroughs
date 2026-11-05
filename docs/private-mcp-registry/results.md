# Results

--8<-- "includes/preview-mcp.md"

The reference run was on `grace` (Ubuntu 26.04, 40 cores, rootless podman 5.7) on 2026-11-04,
from an empty registry: `make clean`, `make all` (2 min 46 s), `make gates` (13 s), `make
screens`. Backend `localhost/ak-backend:mcp-c89f9cea` (artifact-keeper#5257, since merged as
`4542321b`), web `localhost/ak-web:mcp-89313d4` (artifact-keeper-web#1077, since merged as
`896a79db`), Claude Code 2.1.318, mcp-publisher
1.8.7, `@anthropic-ai/mcpb` 2.1.2. The stack images and the two locally built images were
already in the image store, so the times do not include pulling or building them. Two earlier
full runs on the same day found the problems recorded in the [lab notes](findings.md).

## The gates

**63 PASS, 0 FAIL, 3 BLOCKED** of 66 checks.

| Gate | Result | Time |
|---|---|---|
| G1 Access | 6 PASS | 1 s |
| G2 Publish rules | 10 PASS | under 1 s |
| G3 Client contract | 8 PASS | 5 s |
| G4 GUI clients | 2 BLOCKED(gui) | 1 s |
| G5 Curation | 11 PASS, 1 BLOCKED(ak-fix) | under 1 s |
| G6 Supply chain | 9 PASS | 4 s |
| G7 CI OIDC | 7 PASS | 1 s |
| G8 Virtual | 6 PASS | 1 s |
| G9 Bundles | 6 PASS | under 1 s |

The full list is on [Prove it fails safely](8-prove-it-fails-safely.md#the-reference-run).

## Against the requirements

| | Requirement | Result |
|---|---|---|
| R1 | One private registry over TLS; reading needs a token, publishing needs write | Met (G1) |
| R2 | Internal servers published with the official tooling, packages in the same registry | Met: `npm publish`, skopeo, `mcp-publisher publish` (Step 2) |
| R3 | VS Code, Copilot and Claude Code use it; clients install the pinned package | Claude Code and a scripted MCP client: met (G3). VS Code and Copilot: the requests they send are checked (G3); the GUIs are not machine-verified (G4) |
| R4 | Public servers deny by default; approval by name, glob or pin; deny wins | Met (G5) |
| R5 | A changed upstream version is held until re-approved | Met (G5) |
| R6 | External packages refused; image tags pinned to digests | Met (G2, G6) |
| R7 | A held package or a flagged tool description hides the server | Met (G6) |
| R8 | Lookalike names flagged before approval | Met (G5) |
| R9 | CI publishes with no stored secret, only into its namespace | Met against a lab issuer that Artifact Keeper trusts as GitHub's (G7); a real GitHub Actions run is not machine-verified |
| R10 | One URL; an upstream server cannot take over an internal name | Met (G8) |
| R11 | Bundles only from trusted signers; tool lists recorded and diffed | Met (G9) |
| R12 | Every refusal gated, every decision audited | Met |

One requirement the walkthrough set out to show is not met in this build: an approved
**npm-packaged** upstream server is never served, because the Remote cannot pin packages pulled
through `npm-remote` ([F1](findings.md#f1-a-remote-never-pins-npm-packages-pulled-through-npm-remote)).
Image-packaged and remote-only upstream servers work.

## Artifact Keeper issues found

| | Kind | Summary |
|---|---|---|
| [F1](findings.md#f1-a-remote-never-pins-npm-packages-pulled-through-npm-remote) | bug | A Remote `mcp` repository never pins npm, PyPI, NuGet or Cargo packages pulled through a Remote backing repository |
| [D1](findings.md#d1-the-namespace-grant-example-uses-a-principal-type-that-is-refused) | docs | The namespace-grant example's `principal_type: service_account` is refused for a CI mapping's account; `user` works |
| [D2](findings.md#d2-a-bundle-only-server-cannot-rely-on-the-automatic-package-entry) | docs | A bundle-only server.json is refused before the bundle's package entry is added |
| [D3](findings.md#d3-read-responses-carry-access-control-allow-credentials-true) | docs | Read responses carry `Access-Control-Allow-Credentials: true` next to `*` |
| [O1](findings.md#o1-a-virtual-npm-mapping-fills-missing-internal-packages-from-upstream) | behaviour | A Virtual npm mapping fills a missing internal package from npmjs.org, and a failed fill uses up the version |
