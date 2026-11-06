# Next steps

--8<-- "includes/preview-offgrid.md"

What to change before you use this beyond a lab, the two layouts this walkthrough describes
but does not run, and where the series goes from here.

## Before production

- **Use real names, a real CA and real isolation.** Replace `ak.internal` and Caddy's internal
  CA with your hostname and certificate. The site network here is a podman network with
  `internal: true`; in production the isolation is your network design (no default route,
  egress firewall rules that deny by default, DNS that does not resolve outside names), and
  the gates of [Step 7](7-prove-nothing-leaves.md) are how you check it.
- **Keep the ledger.** A logging forward proxy as every Remote's egress proxy costs nothing on a
  connected instance and gives you the list of every upstream host it ever talked to. On the
  disconnected side, leave `AUDIT_UPSTREAM_FETCHES=all` on: a sealed instance writes no
  `UPSTREAM_FETCHED` rows, so the setting is free, and a row that does appear is the alarm.
- **Set the offline settings when you create a Remote**, not when you disconnect: a raised
  cache-ttl applies to an entry only from its next revalidation
  ([Step 1](1-stand-up-the-registry.md#offline-settings-set-at-creation)). Put the egress proxy
  in the create body, and create an MCP Remote with `mcp_remote_sync_paused` unless you want it
  to mirror the public catalog.
- **Seed by commit and by hash.** The model is pinned to a commit, the Python packages to
  hashes, the images to digests. A tag or a branch name that moves upstream after the seed is a
  second, different seed.
- **Do not treat a clean model scan as a verdict.** The model-file scanner reads headers and
  pickle opcodes; it catches a GGUF that does not hold together and a pickle that imports
  `os.system`. It does not judge what a model does. Load GGUF and safetensors only, sandbox
  inference, and keep the vetted repository's hold for anything else.
- **Refresh the scanners' databases on a schedule.** The adapter's DB was imported once; its
  `age_seconds` grows from there. Carry a new one in the same way, and watch the age.
- **Keep tokens short-lived and narrow.** The lab mints 30-day tokens; the agent's token only
  needs `read:artifacts`.

## Two instances: the low side and the high side

This walkthrough seeds and disconnects one instance. With two, the connected one (the low
side) keeps proxying the public registries and the disconnected one (the high side) never
opens a connection out. Two ways to move content across, both in
[the air-gapped guide](https://github.com/artifact-keeper/artifact-keeper/blob/main/docs/air-gapped.md):

1. **Clone the configuration, then push content over the peer mesh.** Export the low side's
   repositories with `GET /api/v1/admin/config/export` (what [Step 3](3-vet-what-you-seeded.md)
   saves to `out/config/seed.json`), plan it on the high side with
   `POST /api/v1/admin/config/import?mode=plan`, and apply it with `mode=apply`. Credentials
   are `secret_ref` placeholders; supply them in the import's `secrets` map. Then register the
   high side as a peer on the low side and subscribe the vetted Local repositories with
   `replication_mode: push`: every artifact that lands on the low side is sent to the high
   side, and the high side only receives. `pull` is refused; the side that has the content
   always initiates.
2. **The plugins Remote is already this pattern.** Here `plugins` proxies this instance's own
   `plugins-central`. Point its upstream at the central instance's marketplace instead
   (`https://central.example.com/agentplugins/plugins`) and the site serves the central
   plugins with the same SHA-256, without republishing them.

The export carries each Remote's upstream mode, so a high side built from it comes up
cache-only ([Findings F4](findings.md#f4-config-export-did-not-carry-the-upstream-mode)). What it
does not carry yet: scan policies, permissions and groups, curation rules. Set those on the high
side by their own routes.

## Bundles across a physical gap

When there is no network path at all, the answer is a signed bundle: export a set of
repositories to a file on the low side, carry it across, import it on the high side. That is
[artifact-keeper#2464](https://github.com/artifact-keeper/artifact-keeper/issues/2464) (epic
#2463); the routes exist but answer 501 on the current release. When it ships, it replaces
[Step 2](2-seed-the-stack.md) of this walkthrough on the high side: the manifest becomes the
bundle's contents, and the inventory check of [Step 7](7-prove-nothing-leaves.md) becomes a
check of the imported bundle against the exported one.

## Where to go from here

- Swap the model: add a `[[model]]` entry to `seed/manifest.toml` (a GGUF repository, a
  commit, the file), run `make reconnect seed vet disconnect agent`. Larger models need more
  RAM and are slower on a CPU; tool calling needs a model and chat template that support it.
- Add MCP servers: publish your own to `mcp-internal` (its package in `pypi-local` first, the
  registry refuses a package it does not hold), or pin another public one in `mcp-official`,
  and list it in the plugin's `mcp.json`. The agent starts only what `mcp-all` lists.
- Run the real Claude Code with a bigger local model, or with a model endpoint you host inside
  the enclave; the plugin wiring of [Step 6](6-claude-code-best-effort.md) stays the same.
- The series: [Rocky Linux image mode](../rocky-linux-image-mode-bare-metal/index.md) for the
  host itself, then [dependencies](../ai-agent-dependency-guardrails/index.md),
  [plugins](../private-agent-plugin-marketplace/index.md),
  [MCP servers](../private-mcp-registry/index.md) and [models](../private-model-hub/index.md)
  one layer at a time.
