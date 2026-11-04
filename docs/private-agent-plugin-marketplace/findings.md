# Lab notes: a private marketplace for agent plugins

The record of building and running the walkthrough planned in [plan.md](plan.md), on
2026-11-03 and 2026-11-04 (UTC). Commands are as run; outputs are trimmed, not edited. The
narrative pages are written from these notes. Gate results are in [section 6](#6-the-reference-runs).

## Environment

| | |
|---|---|
| Host | `grace`: Ubuntu 26.04, x86_64, 40 cores, 108 GB RAM, rootless podman 5.7.0, `podman compose` -> docker-compose v5.5, no sudo |
| Neighbours | two other Artifact Keeper stacks (`ak-agent-*` on 30445, `ak-gate-*` on 30446) kept running, untouched |
| Registry | backend `ghcr.io/artifact-keeper/artifact-keeper-backend:sha-c3a650e` (index digest `sha256:a7556eaf...`, revision `c3a650e1`, built 2026-11-04T02:33Z); web `:dev` (index digest `sha256:ddc8125b...`, revision `895d28d0`); compose files from upstream `c3a650e` |
| Clients | Claude Code 2.1.318, Codex CLI 0.166.0, Copilot CLI 1.0.105 (npm), Cursor CLI 2026.10.22-27dcf5f (installer), ak 1.11.0-rc.2 (release binary) |

## 1. Waiting for the images

The brief named `sha-c3a650e`, the first backend build with the format. At 02:06 UTC the tag did
not exist; the Docker Publish run for the merge commit was in progress (backend builds for both
architectures, then a security scan before the tags are pushed). The tag appeared at about
03:00 UTC. In the meantime the stack was started once on `:dev` (then still the previous
commit, `687900d`) to build and probe the client image against static files.

`ak agent plugins` was in no CLI release. The first client image built `ak` from source at
`10eafa8` with `cargo install --locked --git ... --rev 10eafa8 artifact-keeper-cli`: 11 min 27 s
for the release profile on 40 cores (the crate is `artifact-keeper-cli`, the binary `ak`,
`rust-version` 1.88). The prerelease `v1.11.0-rc.2`, tagged at the same commit, was published
at 03:15 UTC; the Containerfile now downloads it by default
(`ak-linux-<arch>`, `.sha256` checked, `cosign verify-blob` against the release workflow's
identity at that tag) and keeps the cargo build behind `AK_CLI_RELEASE=source`. The download
and verification path was first tried against `v1.2.0`:

```text
ak-linux-amd64: OK
Verified OK
/out/bin/ak: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found
```

`v1.2.0`'s Linux binary was linked against a newer glibc than Debian bookworm's; the CLI README
says Linux binaries are now static (musl). The stage runs `ak --version` so a binary that cannot
run in the image fails the build, not a later step.

## 2. What the agent CLIs do without an account

Probed in a `node:22-bookworm-slim` container with the three npm packages, then in the
workstation image, with an empty home and no credentials.

| Command | Result |
|---|---|
| `claude plugin validate <dir>` | works. Prints the plugin directory's submission checks too: `README missing (README_MISSING)` refused a submission, `ICON_MISSING` a warning. READMEs were added to all three plugins. For a Standard-layout directory it says `Validating components in:` and checks the skills only |
| `claude plugin marketplace add <https url> --json` | works: `{"command":"marketplace-add","outcome":"ok",...}` |
| `claude plugin install <p>@<m> -y --json` | works; installs into `~/.claude/plugins/cache/<m>/<p>/<version>/` |
| `claude plugin list --json`, `details`, `update`, `marketplace update` | work |
| `claude -p hello` | `Not logged in · Please run /login`, exit 1 |
| `codex plugin marketplace add <dir> --json`, `marketplace list`, `plugin list`, `plugin add <p>@<m>` | work |
| `codex exec hello` | `Not inside a trusted directory and --skip-git-repo-check was not specified.`, exit 1 (no login reached) |
| `copilot plugin install <dir>`, `plugin list`, `marketplace list` | work; install prints `Warning: Direct plugin installs (repos, URLs, local paths) are deprecated. Only plugin@marketplace installs will be supported in a future release.` |
| `copilot -p hello` | `Error: No authentication information found.` |
| Cursor installer `curl -fsSL https://cursor.com/install \| bash` | works with no terminal, with `HOME=/opt/cursor`; binary `agent`/`cursor-agent` |
| `cursor-agent plugin --help` | only `marketplace` (`add <gitUrl>`, `list`, `remove`, `update`); no local listing, no install |
| `cursor-agent plugin marketplace list` | `Error: Authentication required. Run 'agent login', ...` |
| `cursor-agent status` | `Not logged in` |

## 3. TLS: what each client trusts

Claude Code 2.1.318 is a native binary (the file `claude` resolves to starts with an ELF header), not
a Node script, so `NODE_EXTRA_CA_CERTS` was not a given. Tested against
`https://mirror.internal/probe/claude-marketplace.json` (a static marketplace on Caddy, same CA):

| Setting | `marketplace add` |
|---|---|
| CA in the system store, plus `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` (the image's default) | ok |
| CA removed from the system store, `NODE_EXTRA_CA_CERTS=<ca file>` only | ok |
| neither | `Failed to download marketplace ...: unable to get local issuer certificate` |
| `SSL_CERT_FILE=<ca file>` only | ok |
| CA in the system store, no variables at all | ok |

`ak` takes `AK_CA_CERT`, which the image sets to the same file.

## 4. The flows

### Registry and bootstrap

First `make registry-up` on the real image: about 60 s with images cached. `/readyz` reports
`"scanner":{"status":"not_configured"}` because `TRIVY_URL` is unset; Grype runs anyway (below).
`/health` reports `"version":"1.11.3"` on this main build.

`make bootstrap` worked first time: three repositories, scan settings, the policy, users and
tokens. Second run: every object reported as existing.

Change made after the first audit run: `ci.token` was first minted by the admin on the
repository. Every publish was then recorded as `uploaded_by_username: "admin"`. The bootstrap now
creates a `ci` user with read and write permission on `agent-plugins`, and the token is minted by
that user, as the developer's is. Publishes are then attributed to `ci`.

### Publish

`make publish` first run: 5.8 s. `ak agent plugins publish` printed the summary and the two
Claude Code commands; `curl -T` returned `201` with `marketplace_name: "agent-plugins"`.
Scans: Grype completed about 5 s after each upload; `wait_listed` saw every version servable by
the time it looked.

### Indexes

As designed: `vscode-marketplace.json` lists only the Standard plugin; `acme-release-notes` is in
`claude`, `cursor` and `codex`; the Standard plugin is in all four per-harness documents.
`metadata.generated_at` is the publish time of the newest listed version.

### Claude Code, settings route

First attempt:

```console
$ claude plugin marketplace update agent-plugins
Updating marketplace: agent-plugins...✘ Failed to update marketplace(s): Marketplace 'agent-plugins' not found. Available marketplaces: anthropic-plugin-directory
$ claude plugin install acme-review@agent-plugins --json
{"command":"install","outcome":"failed", ... "Plugin \"acme-review\" not found in marketplace \"agent-plugins\" ...","failureCode":"not_found"}
```

Caddy's access log showed no request from Claude Code at all. `claude plugin marketplace update`
with no name: `Successfully updated 1 marketplace` (the built-in directory), still not
registered. What registers it is a session start: `claude -p hello` stopped at `Not logged in`,
and afterwards `claude plugin marketplace list --json` listed `agent-plugins`, and the install
worked. The same with the entry in `/etc/claude-code/managed-settings.json` instead. Caddy's log
for the install:

```text
/agentplugins/agent-plugins/claude-marketplace.json                   200  REDACTED  Claude-Code-Plugin-Manager
/agentplugins/agent-plugins/acme-review/1.0.0/acme-review-1.0.0.zip   200  REDACTED  Claude-Code-Plugin-Manager
```

so the configured header goes on the archive download too. The flow and G4 now start a session
(`claude -p hello </dev/null`) after writing settings. Without `</dev/null`, Claude Code waits
3 s for stdin and prints `Warning: no stdin data received in 3s`.

After the settings route, the token is in `~/.claude/settings.json` and in
`~/.claude/plugins/known_marketplaces.json`, where Claude Code copies the source including
`headers`. Not in the cached marketplace document, not in any URL.

### Claude Code, token-in-path route

`marketplace add` with the token URL reports `(declared in user settings)`. Files holding the
token afterwards:

```text
~/.claude/plugins/known_marketplaces.json: 1
~/.claude/plugins/marketplaces/agent-plugins: 6     (the cached document: every archive URL)
~/.claude/settings.json: 1
```

The upstream docs mention `known_marketplaces.json` only; the walkthrough's pages name all three.

### ak installs

`ak agent plugins install ... --harness cursor,codex,vscode` worked first time, including the
post-steps: `codex plugin marketplace add <dir>` (first install only) and `copilot plugin install
<dir>` ran because both CLIs are on `PATH`. Observations:

- `ak` warns and installs when the plugin is not tagged for the harness: the multi-harness
  plugin (`claude, cursor, codex`) warns for `vscode`, because only `standard` maps to vscode.
- Codex lists the plugins from `ak`'s local marketplace but does not install them until
  `codex plugin add <slug>@ak-<repo>`; `ak` does not run that.
- `ak` sends no `User-Agent`: its downloads have `user_agent: null` in the download records.

### Update

`ak agent plugins publish ... --version 1.1.0` on a directory whose manifest says 1.0.0:
accepted, and the installed `plugin.json` says 1.1.0. `claude plugin marketplace update` +
`claude plugin update` moved 1.0.0 to 1.1.0 (`"updateOutcome":"updated"`). `ak agent plugins
list --check-updates` showed the one `behind` install; `update --all` updated it.

### Scan

Scans of a plugin zip: `openscap` `not_applicable`, `grype` `completed` (about 5 s), `dependency`
`completed`, all with zero findings. The hold is visible only in a repository that scans on
request (`agent-plugins-staging`): `index.json` `404`, `marketplace.json` `[]`, download `403`;
after `POST /api/v1/security/scan` the version is listed and downloads `200`.

### Audit

- `GET /api/v1/admin/downloads?artifact_id=...` returns `{"downloads":[...]}` with `username`,
  `ip_address`, `user_agent`, `downloaded_at`.
- `GET /api/v1/admin/audit?resource_id=<artifact id>` for a plugin version: `{"items":[],"total":0}`.
  The audit log has `ARTIFACT_UPLOADED` for the generic upload of the CA certificate to `trust`,
  but no event for any Agent Plugins publish. The publisher is on the artifact record
  (`uploaded_by`, `uploaded_by_username`). Reported in the PR description as an upstream gap.

## 5. Gate development

First full gate run: 92 PASS, 3 FAIL, 2 BLOCKED(account), 35 s.

- **G3 `Referrer-Policy` (F1).** The token route answered `referrer-policy:
  strict-origin-when-cross-origin`, through Caddy and straight from the backend
  (`wget -S http://backend:8080/agentplugins/t/<token>/...`). Cause: the route layer in
  `backend/src/api/handlers/agent_plugins.rs` inserts `Referrer-Policy: no-referrer`, then the
  global `security_headers_middleware` (`backend/src/api/middleware/security_headers.rs`) runs
  `headers.insert("referrer-policy", "strict-origin-when-cross-origin")` over it. The handler's own
  test asserts `no-referrer` on the router without the global layer, so it passes. Fix upstream:
  `entry().or_insert()` as that middleware already does for the CSP. Workaround here: Caddy
  `header_down Referrer-Policy no-referrer` on `/agentplugins/t/*`. The gate now checks both:
  the wire (PASS) and the backend directly (`BLOCKED(F1)`).
- **G7.** A check read `$?` after a helper whose last command was a `jq` with a `?` filter; fixed
  in the gate, not a registry problem.
- **G10.** The check expected the settings-route token in `settings.json` only; Claude Code also
  copies it into `known_marketplaces.json` (above). The check now asserts exactly those two files.

## 6. The reference runs

Both from an empty registry, in a git checkout of the branch at
`~/walkthrough-runs/private-agent-plugin-marketplace` on `grace`. Logs are kept there under
`private-agent-plugin-marketplace/out/runs/` (`run1-all.log`, `run1-gates.log`, `run1-out/`,
`run2-*.log`; run 2's `make all` log has a Unix timestamp on every line).

| | Run 1 | Run 2 |
|---|---|---|
| started | 2026-11-04T03:16:57Z | 2026-11-04T03:22:08Z (after `make clean`, 5 s) |
| `make all` | 232 s, exit 0 | 219 s, exit 0 |
| `make gates` | 36 s, exit 0 | 37 s, exit 0 |
| verdicts | 96 PASS, 2 BLOCKED(account), 1 BLOCKED(F1), 0 FAIL | the same |

Run 1 built the `ak` stage from the release:

```text
client: ak CLI from release v1.11.0-rc.2 (sha256 and cosign signature checked)
+ curl -fsSLO https://github.com/artifact-keeper/artifact-keeper-cli/releases/download/v1.11.0-rc.2/ak-linux-amd64
 ...
ak-linux-amd64: OK
Verified OK
```

`make clean` keeps that stage image (`localhost/ak-agents/ak-cli:v1.11.0-rc.2`), so run 2 reused
it. `ak --version` prints `ak 1.11.0`: the prerelease's crate version has no `-rc.2` suffix.

Run 2, per target (from the timestamps): `registry-up` 31 s, `bootstrap` 5 s, `client` 151 s,
`validate` 2 s, `publish` 6 s, `indexes` 2 s, `consume-claude` 7 s, `consume-cli` 8 s,
`update` 5 s, `scan` 2 s, `audit` under 1 s. Gates: G1 1 s, G2 2 s, G3 3 s, G4 6 s, G5 4 s,
G6 1 s, G7 1 s, G8 15 s, G9 1 s, G10 3 s.

The blocked checks, verbatim:

```text
BLOCKED(F1)       G3   the backend itself sends Referrer-Policy: no-referrer on the token route: it sends 'strict-origin-when-cross-origin' (findings.md F1; Caddy restores no-referrer)
BLOCKED(account)  G4   a signed-in Claude Code session uses the plugin: after 'claude /login' in out/homes/g4, run: claude -p '/acme-review:checklist' (and ask for a review to load the review skill)
BLOCKED(account)  G8   the agents use the installed plugin in a session: after logging in (codex login; copilot login; cursor-agent login, or reload a Cursor window) in out/homes/g8, ask each agent for the fixture skill 'check'
```

Also seen after run 2, in the web UI screenshots: the Packages tab lists `acme-review` 1.1.0,
`acme-standards` 1.0.0 and `acme-release-notes` 1.0.0, each with **0 downloads**, while
`GET /api/v1/admin/downloads` has records for them and the artifact rows have
`download_count` 2 and 3. The storage card showed 0 B until its estimate runs.

## F1: Referrer-Policy overwritten on the token route

Open. `docs/agent-plugins.md` says token-route responses carry `Referrer-Policy: no-referrer`,
and the token router sets it (`backend/src/api/handlers/agent_plugins.rs`, the
`map_response` layer of `token_router()`). The global `security_headers_middleware`
(`backend/src/api/middleware/security_headers.rs`) runs after it and calls
`headers.insert("referrer-policy", "strict-origin-when-cross-origin")`, which replaces the
value. The handler's test (around line 1350) builds the format router alone, without the global
layer, so it passes.

Request, from inside the compose network, straight to the backend (a 200 from the token router:
its `cache-control` is present):

```console
$ podman exec ak-agents-caddy wget -q -S --spider "http://backend:8080/agentplugins/t/<developer token>/agent-plugins/claude-marketplace.json"
  HTTP/1.1 200 OK
  etag: "3396a9e665c2cc08f06d81847462f6152c6f3f46ec80ecf41dd10dda20f8ac65"
  cache-control: private, no-store
  content-type: application/json
  referrer-policy: strict-origin-when-cross-origin
  x-correlation-id: cd57aa5b-37b9-406f-b913-c9b5cafe0397
  vary: origin
  access-control-allow-credentials: true
  x-frame-options: DENY
  x-content-type-options: nosniff
  strict-transport-security: max-age=31536000; includeSubDomains
  permissions-policy: camera=(), microphone=(), geolocation=()
  content-security-policy: default-src 'self'; script-src 'self'; ...
  content-length: 4170
```

Fix: set `referrer-policy` with `entry(...).or_insert(...)` in the global middleware, as it
already does for `content-security-policy`, and test the token route through the full router.
Workaround in this walkthrough: Caddy's `header_down Referrer-Policy no-referrer` on
`/agentplugins/t/*`. Gate G3 checks both: on the wire (PASS) and from the backend directly
(`BLOCKED(F1)`).
