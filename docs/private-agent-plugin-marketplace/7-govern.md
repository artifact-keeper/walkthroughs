# Step 7: Govern: scanning, tokens and audit

Everything that applies to other hosted artifacts in Artifact Keeper applies to plugin
versions: scan on upload and scan policies, repository permissions and scoped tokens, download
records. This page shows each on the plugins from the earlier steps.

## Scanning

`agent-plugins` scans every upload, and its policy `agent-plugins-release` has
`block_unscanned: true`. [`make scan`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/flows/scan.sh) shows the scans of
`acme-review` 1.0.0:

```json
[
  { "scan_type": "openscap",   "status": "not_applicable", "findings_count": 0 },
  { "scan_type": "grype",      "status": "completed",      "findings_count": 0,
    "started_at": "2026-11-04T02:56:50.832947Z", "completed_at": "2026-11-04T02:56:55.652372Z" },
  { "scan_type": "dependency", "status": "completed",      "findings_count": 0 }
]
```

Grype (a vulnerability scanner bundled in the backend image) looks at what is in the zip:
lockfiles, package manifests, binaries. A plugin of Markdown and JSON has nothing for it to
match, so zero findings is the expected answer here. It matters for the plugins that ship a
`bin/` directory or vendor an MCP server's dependencies.

**The policy is the part that governs.** The marketplace documents, `<name>/index.json` and the
download route all apply the same gate: a version whose scan has not completed (or failed, or
found something at or above `high`) is left out of every document and its download is
`403`. A plugin whose newest version is held is listed at its newest servable one. On
`agent-plugins` the window is the five seconds a scan takes, too short to look at, so the
scan flow uses a second repository, `agent-plugins-staging`, with the same policy and
scanning only on request:

```console
published acme-standards 1.0.20261104025700 to agent-plugins-staging
index.json:                404
marketplace.json lists:    []
download 1.0.20261104025700:   HTTP 403
{"message":"Scan queued for artifact 91730b41-...","artifacts_queued":1, ...}
  acme-standards 1.0.20261104025700 servable in agent-plugins-staging after 0 s
marketplace.json lists:    ["acme-standards@1.0.20261104025700"]
download 1.0.20261104025700:   HTTP 200
```

Claude Code and `ak` never see a version the registry has not scanned. Gate G7 runs the same
sequence with a second version and checks that the documents keep serving the first one
meanwhile.

The plugin metadata also records a component inventory (skills, commands, agents, hooks, MCP,
LSP, `bin/`). There is no content policy on it yet (for example "no hooks in this
repository"); until there is, the inventory is something to review, and repository permissions
decide who may publish at all.

## Tokens and permissions

The access model from [Step 1](1-stand-up-the-registry.md), as gate G1 measures it:

| Request on `agent-plugins` | Answer |
|---|---|
| anonymous read or download | `401` |
| `developer.token` (read only) read, download | `200` |
| `developer.token` publish | `403` |
| a token for `agent-plugins-public`, read or publish here | refused |
| a bogus token in the path | `401` |
| anonymous read of `agent-plugins-public` | `200` |

Rules worth copying:

- **Only CI can publish**, with a token scoped to the one repository. Developers hold read-only
  tokens.
- **Users mint their own tokens.** The registry attributes a repository token's requests to the
  user who minted it, and a non-admin cannot mint more than it holds.
- **Expiries everywhere.** The walkthrough's tokens last 30 days.
- **Prefer the settings route to the token-in-path route** for Claude Code, and a
  `headersHelper` to a literal header on managed machines ([Step 4](4-install-in-claude-code.md)).

## Audit

[`make audit`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-agent-plugin-marketplace/flows/audit.sh) answers "who published this, and who installed it" from the
REST API:

```console
== acme-review 1.1.0
published:
{"at":"2026-11-04T03:25:40.617090Z","by":"ci","sha256":"f248747d0f02e9575bdc1b1f9b0af7c612f7d8b354df8ce8fd2658131f5d40e2","harnesses":["claude"],"downloads":2}
downloads:
{"at":"2026-11-04T03:25:44.070743Z","user":"developer","ip":"172.31.72.8","agent":"-"}
{"at":"2026-11-04T03:25:42.304776Z","user":"developer","ip":"172.31.72.8","agent":"Claude-Code-Plugin-Manager"}

== downloads from agent-plugins, by user and client
{"user":"developer","agent":"-","downloads":4}
{"user":"developer","agent":"Claude-Code-Plugin-Manager","downloads":4}

== audit events: tokens, users and permissions
{"at":"2026-11-04T03:22:40.644780Z","actor":"admin","action":"REPOSITORY_CREATED","resource_type":"repository"}
 ...
{"at":"2026-11-04T03:22:41.834667Z","actor":"admin","action":"PERMISSION_RULE_CREATED","resource_type":"permission_rule"}
{"at":"2026-11-04T03:22:42.628071Z","actor":"ci","action":"API_TOKEN_CREATED","resource_type":"api_token"}
 ...
{"at":"2026-11-04T03:22:43.840475Z","actor":"developer","action":"API_TOKEN_CREATED","resource_type":"api_token"}
```

- **The publisher** is on the version's artifact record (`uploaded_by`), here `ci`, with the
  time and the SHA-256.
- **Every download** is recorded with the user, the client address and the user agent. Claude
  Code identifies itself as `Claude-Code-Plugin-Manager`; `ak` sends no user agent, which
  is the `-` rows.
- **The audit log** has the administrative events: repositories, permissions, and every token,
  with who minted it.

Two gaps on this build, both recorded in the [lab notes](findings.md): an Agent Plugins publish
writes no `ARTIFACT_UPLOADED` event to the audit log (a generic upload does), so the artifact
record is the place to look; and `ak`'s downloads cannot be told from any other client's by
user agent.

Next: [Step 8, prove it fails safely](8-prove-it-fails-safely.md).
