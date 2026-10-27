# Step 8: Replay an agent session

This page runs a scripted coding-agent session of twelve installs in the sandbox and records, for
each one, the command, what the package manager printed and what the registry said. Then it asks
the question a security team asks afterwards: what did the agent try?

**Make target:** `make agent`, which runs
[`agent/agent.py`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/agent/agent.py)
over [`agent/plan.toml`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/agent/plan.toml).
Transcripts land in `agent/out/`.

## Why scripted

A real agent decides differently on every run. The walkthrough has to be reproducible, so the
session is a fixed list of what an agent might do while working on `acme-agent`, including steps
modelled on public incidents. Each step runs in a fresh copy of the app, in the sandbox, with the
agent's token. For every refusal the script also requests the same URL directly, because uv and
npm print "403 Forbidden" or `E403` but not the registry's reason.

## The session

| # | The agent | Answer | Step |
|---|---|---|---|
| 1 | `uv add pydantic` (already reviewed) | installed | [3](3-publish-and-lock.md) |
| 2 | `uv add huggingface-cli` (an invented name) | `403 curation_blocked` | [4](4-approve-names.md) |
| 3 | `uv add anthorpic` (a look-alike) | `403 curation_blocked` | [4](4-approve-names.md) |
| 4 | `npx -y @modelcontextprotocol/server-filesystem` (unreviewed MCP server) | `403 curation_blocked` | [4](4-approve-names.md) |
| 5 | `uv pip install lab-agent-sdk==1.1.0` (published 10 minutes ago) | not in the index; `451 age_gate_blocked` | [5](5-hold-fresh-releases.md) |
| 6 | `uv pip install lab-agent-sdk` | 1.0.0, the newest old enough | [5](5-hold-fresh-releases.md) |
| 7 | `npm install lab-mcp-weather` (latest is 10 minutes old) | 2.0.0 | [5](5-hold-fresh-releases.md) |
| 8 | `uv pip install acme-agent-tools` (public 99.0.0 exists) | internal 1.0.0 | [6](6-own-your-names.md) |
| 9 | `npm install @acme/tickets-mcp` (public 99.0.0 exists) | internal 1.0.0 | [6](6-own-your-names.md) |
| 10 | `uv pip install langchain==0.0.141` (old tutorial pin) | `403 scan_blocked` | [7](7-refuse-known-vulnerable.md) |
| 11 | `--default-index https://pypi.org/simple/` | blocked (DNS does not resolve) | [2](2-sandbox-the-agent.md) |
| 12 | `npm publish` to `npm-internal` | `E403` | below |

```text
PASS   1 approved           Add an approved package
PASS   2 invented-name      A package name the model invented
…
PASS  12 publish            The agent tries to publish
agent: 12/12 steps behaved as expected; transcripts in agent/out
```

Each transcript is self-contained; for example `agent/out/04-unreviewed-mcp.txt`:

```text
# npx -y an MCP server nobody reviewed
# `npx -y <server>` downloads and runs whatever is newest, every time.

$ npx -y @modelcontextprotocol/server-filesystem /tmp
npm error code E403
npm error 403 403 Forbidden - GET https://ak.internal/npm/npm-virtual/lru-cache/-/lru-cache-11.5.3.tgz - curation_blocked
npm error 403 In most cases, you or one of your dependencies are requesting
…
# what the registry said
GET https://ak.internal/npm/npm-virtual/@modelcontextprotocol/server-filesystem/-/server-filesystem-0.6.2.tgz
403 Forbidden
{"error":"curation_blocked","package":"@modelcontextprotocol/server-filesystem","reason":"not on the approved list; ask the platform team to review it"}

PASS (expected refused, exit 1, 'curation_blocked' found)
```

npm fetches the server and its dependencies in parallel; the first refusal it reported was for
`lru-cache`, one of the server's dependencies that nobody approved either. The direct request
shows the server's own tarball is refused for the same reason.

## The agent's token

The token reads two virtual repositories (four, with the lab ones) and nothing else:

| Request with the agent token | Answer |
|---|---|
| `pypi-remote` directly | 404 |
| the admin audit API | 403 |
| `npm publish` to `npm-internal` | `E403` |

## What did the agent try?

Two of the three kinds of refusal can be listed from the registry today.

Scan refusals, per repository (`GET /api/v1/repositories/{key}/security/proxy-scans`, the
entries with `state: vulnerable`), from a run on 2026-10-27:

```text
pypi-remote  simple/langchain/langchain-0.0.141-py3-none-any.whl  critical
npm-remote   body-parser/-/body-parser-2.3.0.tgz                  high
```

Held versions (`GET /api/v1/admin/age-gate/reviews`), with how often they were asked for. One
clean run held 30 young versions of 21 packages that the resolvers came across, among them:

```text
pypi-lab    lab-agent-sdk                            1.1.0    pending   x4
npm-remote  @modelcontextprotocol/sdk                1.32.2   pending   x1
npm-remote  @modelcontextprotocol/server-filesystem  2.0.1    pending   x1
pypi-remote anthropic                                2.3.0    pending   x1
pypi-remote starlette                                1.10.0   pending   x1
npm-remote  qs                                       6.17.0   pending   x1
npm-remote  body-parser                              2.4.0    approved  x2
```

Only the approval is in the audit log (`AGE_GATE_APPROVED`).

Curation refusals are listed nowhere, and none of the three writes a row to the audit log
([F1](findings.md)). Until that is fixed, Caddy's JSON access log on the registry (status 403 or
451, path, client address) is the complete record.

**Gates:** G8 (token) and G9 (audit, BLOCKED by F1).

**Next:** [Results](results.md).
