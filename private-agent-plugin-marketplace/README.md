# A private marketplace for AI coding-agent plugins

> **An example, not a complete defense.** This shows one way to run a private marketplace of agent
> plugins on Artifact Keeper. The configuration is an example, built and tested in a lab. It does
> not cover every edge case or attack, and it is not a hardened production setup; known gaps are
> in the [findings](../docs/private-agent-plugin-marketplace/findings.md). Review and adapt it for
> your environment, and use it alongside your other controls, not instead of them.

Code for the walkthrough at
[`docs/private-agent-plugin-marketplace/`](../docs/private-agent-plugin-marketplace/index.md)
([plan](../docs/private-agent-plugin-marketplace/plan.md), lab notes in
[`findings.md`](../docs/private-agent-plugin-marketplace/findings.md)).

Artifact Keeper runs as compose project `ak-agents` on the podman network `ak-agents-net` and
answers as `https://ak.internal` (TLS from Caddy's internal CA). Every client (Claude Code,
Codex, Copilot, the Cursor CLI, `ak`) runs in the workstation container on that network with a
throwaway home under `out/homes/`. Nothing here needs sudo or an agent account.

| Directory | What |
|---|---|
| `registry/` | the stack (upstream compose + override), Caddy, `up.sh`, `bootstrap.sh` (repositories, scan policy, users, tokens), `clean.sh` |
| `client/` | the workstation image (`Containerfile`, pins in `VERSIONS`), `run.sh` to run one command in it, `acme-docs-mcp.js` |
| `plugins/` | `acme-review` (Claude Code layout), `acme-standards` (Agent Plugins Standard), `acme-release-notes` (multi-harness) |
| `flows/` | one script per make target from `validate` to `audit` |
| `gates/` | G1-G10 as runnable checks: PASS / FAIL / BLOCKED |

## Run it

```console
make all             # registry, bootstrap, client, validate, publish, indexes, consume-claude,
                     # consume-cli, update, scan, audit
make gates           # the ten gates; results in out/gates/
make screens-ready   # UI URL and credentials
make clean           # remove everything it created (keeps pulled images and the ak build stage)
```

Requirements: rootless podman with `podman compose`, curl, jq, openssl, python3, unzip, GNU
make. The only host port is `127.0.0.1:30447` (Caddy 443). From the host, reach the registry
by its real name with
`curl --resolve ak.internal:30447:127.0.0.1 --cacert registry/out/ak-internal-ca.crt`.

Images: `BACKEND_IMAGE` / `WEB_IMAGE` in `registry/.env` (defaults in `registry/.env.example`,
digests in `registry/compose/VERSIONS`); client pins in `client/VERSIONS`.

Secrets (never committed): `registry/.env`, `registry/.tokens/`. Outputs: `out/`,
`registry/out/` (the CA certificate and the G5 mirror), `client/.work/`.
