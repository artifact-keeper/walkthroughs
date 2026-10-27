# An AI coding agent that can only install what the registry allows

Code for the walkthrough
[AI coding agents through one registry](https://artifact-keeper.github.io/walkthroughs/ai-agent-dependency-guardrails/).
The narrative lives in [`docs/ai-agent-dependency-guardrails/`](../docs/ai-agent-dependency-guardrails/);
everything it runs lives here. Run every command below from this directory.

> **An example, not a complete defense.** This shows one way to put Artifact Keeper in the path
> between an AI coding agent and public package indexes. The configuration is an example, built
> and tested in a lab. It does not cover every edge case or attack, and it is not a hardened
> production setup; known gaps are in the
> [findings](../docs/ai-agent-dependency-guardrails/findings.md). Review and adapt it for your
> environment, and use it alongside your other controls, not instead of them.

A coding agent runs `uv add`, `npm install` and `npx` on its own. Here it runs in a sandbox whose
only reachable host is [Artifact Keeper](https://github.com/artifact-keeper/artifact-keeper) 1.11.7,
with a read-only token for two virtual repositories. The registry decides what reaches disk:

| The agent asks for | The registry answers |
|---|---|
| a reviewed package | served |
| a name nobody reviewed (invented, look-alike, an MCP server via `npx -y`) | `403 curation_blocked`, before anything is fetched upstream |
| a release published minutes ago | left out of the index; pinned, `451 age_gate_blocked` with a review id |
| a public package reusing an internal name | never offered; the internal version resolves |
| a version with a high or critical advisory | `403 scan_blocked`, fail closed |
| `--default-index https://pypi.org/simple/` | no route: DNS does not even resolve |

```
pypi.org ─────────┐                                   ┌─ pypi-virtual ─┐
registry.npmjs.org┼─> Artifact Keeper (ak.internal) ──┤                ├─> agent sandbox (agent-net,
ghcr.io, Docker Hub┘   age gate · approved names ·    └─ npm-virtual ──┘    internal: no route out)
                       scan-on-proxy · name ownership
```

## Layout

| Path | What |
|---|---|
| `registry/` | Artifact Keeper 1.11.7 (upstream compose + override, rootless podman), Caddy as `https://ak.internal` with an internal CA, `up.sh`, idempotent `bootstrap.sh` (repositories, upstream filter, users, tokens, CA) |
| `lab-upstream/` | A stdlib-only PyPI index and npm registry with publish times we control, for the deterministic cooldown and name-squat tests |
| `policies/` | `apply.sh` (age gate, scan-on-proxy), `exceptions.txt` + `exceptions.sh` (reviewed early approvals), `curation.sh` (approved list from the lockfiles), `approve.sh` |
| `sandbox/` | The agent image: uv + npm, system-wide `uv.toml` and `npmrc` pointing at the registry, the CA; `run.sh` runs a command on `agent-net` with the agent token |
| `internal/` | `acme-agent-tools` (Python) and `@acme/tickets-mcp` (an MCP server), built and published as CI would |
| `app/` | `acme-agent`: a Python service that starts the internal MCP server; the reviewed lockfiles |
| `agent/` | `plan.toml`: a scripted agent session of 12 installs; `agent.py` replays it in the sandbox and records transcripts in `agent/out/` |
| `gates/` | G1-G10 as runnable checks (PASS / FAIL / BLOCKED(Fn)); `reproduce.sh` runs everything twice from an empty registry |

## Requirements

Linux with rootless podman 5.x and `podman compose` (with the docker-compose plugin), curl, jq,
openssl, GNU make and Python 3.11+. About 8 GB of RAM and 10 GB of disk. No sudo, no GPU, no
model API key: nothing calls a model.

## Run it

```bash
make all          # registry, lab upstream, repositories, policies, sandbox, internal packages,
                  #   approved list, install and run the app, replay the agent session
make gates        # G1-G10, evidence in out/gates/
make reproduce    # make clean all gates, twice, from an empty registry (out/reproduce.txt)
make screens-ready
```

Admin UI: https://127.0.0.1:30445 (user `admin`, password generated into `registry/.env`; the
certificate is from the stack's own CA, `registry/out/ak-internal-ca.crt`).
Generated secrets, tokens and state are gitignored.

## License

MIT, see the repository's [LICENSE](../LICENSE).
