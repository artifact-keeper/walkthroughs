# client

`localhost/ak-agents/workstation:latest`, a developer workstation in a container, built by
`build.sh` from `Containerfile` with the pins in `VERSIONS`:

- Node 22, Claude Code, Codex and the GitHub Copilot CLI from npm (exact versions), the Cursor
  CLI from its installer;
- `ak`: by default the release `AK_CLI_RELEASE` (`ak-linux-<arch>`, checked against its
  `.sha256` and its cosign keyless signature); `AK_CLI_RELEASE=source` builds it with cargo at
  `AK_CLI_REV`. The `ak` stage is kept as `localhost/ak-agents/ak-cli:<release or rev>`;
- `acme-docs-mcp` (`acme-docs-mcp.js`), the stdio MCP server the `acme-standards` plugin starts;
- the internal CA in the system store, `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `AK_CA_CERT`.

No credentials are baked in. `run.sh [-h HOME] [-t TOKEN] [-i INSTANCE] -- cmd...` runs one
command on `ak-agents-net` with a home under `../out/homes/HOME` (default `scratch`, wiped each
time) and a token from `../registry/.tokens/TOKEN.token` passed as `AK_TOKEN` through the
environment.
