# Reference: make targets

--8<-- "includes/preview-1.12.md"

Run every target from `private-agent-plugin-marketplace/`. Each one can be re-run; `make help`
prints this list. The scripts behind them are linked so you can read what each one does.

| Target | What it does | Script |
|---|---|---|
| `registry-up` | Starts the `ak-agents` compose project, generates `registry/.env` and its secrets on the first run, exports Caddy's root CA to `registry/out/ak-internal-ca.crt`, waits for `/readyz` | [`registry/up.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/registry/up.sh) |
| `registry-down` | Stops the stack and keeps the volumes (`registry/down.sh --volumes` wipes them) | [`registry/down.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/registry/down.sh) |
| `bootstrap` | Repositories `agent-plugins`, `agent-plugins-public`, `trust`; scan on upload and the `agent-plugins-release` scan policy; the `developer` user and its read permission; the tokens in `registry/.tokens/`; the CA certificate in `trust` | [`registry/bootstrap.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/registry/bootstrap.sh) |
| `client` | Builds `localhost/ak-agents/workstation:latest` (and keeps the `ak` build stage as `localhost/ak-agents/ak-cli:<rev>`) | [`client/build.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/client/build.sh) |
| `validate` | `claude plugin validate` on the three plugins, and the Agent Plugins Standard rules on `acme-standards/plugin.json` | [`flows/validate.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/flows/validate.sh) |
| `publish` | `ak agent plugins publish` for `acme-review` and `acme-release-notes`, `curl -T` for `acme-standards`, `acme-release-notes` to the public repository; waits for the scans | [`flows/publish.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/flows/publish.sh) |
| `indexes` | Saves the five marketplace documents and `acme-review/index.json` to `out/indexes/` and prints them | [`flows/indexes.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/flows/indexes.sh) |
| `consume-claude` | Claude Code three ways: settings route, token-in-path route, public repository | [`flows/consume-claude.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/flows/consume-claude.sh) |
| `consume-cli` | `ak agent plugins install` for Cursor, Codex and Copilot, then each agent's own listing | [`flows/consume-cli.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/flows/consume-cli.sh) |
| `update` | Publishes `acme-review` 1.1.0; Claude Code and the `ak` installs pick it up | [`flows/update.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/flows/update.sh) |
| `scan` | Scan results of a published zip, the policy, and the hold in `agent-plugins-staging` | [`flows/scan.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/flows/scan.sh) |
| `audit` | Audit events and download records for `acme-review` | [`flows/audit.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/flows/audit.sh) |
| `gates` | G1 to G10; verdicts in `out/gates/results.tsv`, logs in `out/gates/gNN.log`, durations in `out/gates/timings.tsv` | [`gates/run-all.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/gates/run-all.sh) |
| `screens-ready` | Prints the UI address and where the credentials are | [`Makefile`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/Makefile) |
| `all` | `registry-up` through `audit`, in order; then run `make gates` | [`Makefile`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/Makefile) |
| `clean` | Removes the containers, volumes, network, workstation image, `registry/.env`, tokens and `out/`. Keeps the pulled images and the `ak` build stage | [`registry/clean.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/registry/clean.sh) |

`gates/run-all.sh g03 g07` runs only the gates you name.

## Running one command in the workstation

[`client/run.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/client/run.sh)
is how every flow runs a client command:

```bash
client/run.sh [-h HOME_NAME] [-t TOKEN_NAME] [-i INSTANCE_URL] [-v HOST:CTR] -- command [args...]
```

- `-h` names a home under `out/homes/<name>`, mounted at `/home/dev`. Without it the home is
  `scratch`, wiped on every run.
- `-t` passes `registry/.tokens/<name>.token` as `AK_TOKEN`, through the environment only.
- `-i` points `ak` at another instance (gate G5 uses `https://mirror.internal`).

For example, to see what Claude Code thinks of the developer's installs after `make
consume-claude`:

```bash
client/run.sh -h claude-settings -- claude plugin list --json
```
