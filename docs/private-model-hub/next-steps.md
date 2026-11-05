# Next steps

--8<-- "includes/preview-hf.md"

What to change before you use this beyond a lab, and where to go from here.

## Before production

- **Use real names and a real CA.** Replace `ak.internal` and Caddy's internal CA with your
  hostname and certificate; distribute the CA (or use a public one) instead of baking it into
  an image.
- **Freeze when you create a Remote, not later.** A raised `cache-ttl` only applies to an entry
  from its next revalidation ([Step 7](7-freeze-and-go-offline.md)). If you decide to go
  offline after the cache is warm, invalidate what you need (`POST
  /api/v1/repositories/<key>/cache/invalidate?path=...`) and pull it again.
- **Seed with the revision spelling clients use.** The cache key includes the revision as it
  was requested: a file pulled at `main` is not the same entry as the same file at its commit.
  `snapshot_download` requests files at the commit; seed with it, and pull any files in
  subdirectories explicitly at the same commit until the tree listing is recursive.
- **Set `HF_HUB_OFFLINE=1` on disconnected workstations** once their cache is filled. Without
  it, every optional file a library probes for becomes a 502 and a retry loop
  ([#5282](https://github.com/artifact-keeper/artifact-keeper/issues/5282)).
- **Do not rely on the scan for model files.** Nothing in Artifact Keeper reads pickle,
  safetensors or GGUF yet ([#5285](https://github.com/artifact-keeper/artifact-keeper/issues/5285)).
  Accept safetensors only, load with `weights_only=True`, and keep the reviewer's hold
  ([Step 6](6-scan-and-hold.md)) for anything else.
- **Rotate the Hub token** with `PUT /api/v1/repositories/<key>/upstream-auth`; nothing on a
  workstation changes.
- **Keep tokens short-lived.** The lab mints 30-day tokens; use your identity provider and
  per-team tokens with only `read:artifacts`.
- **Watch the double download.** A cold `HEAD` fetches the whole file upstream and keeps
  nothing ([findings F5](findings.md#f5-a-cold-head-fetches-the-file-upstream-and-caches-nothing)).
  On multi-gigabyte weights that doubles egress on first use.

## Where to go next

- [AI coding agents through one registry](../ai-agent-dependency-guardrails/index.md): the
  Python and npm packages agents install, through the same kind of Remotes.
- [A private marketplace for agent plugins](../private-agent-plugin-marketplace/index.md).
- Artifact Keeper's own [Hugging Face documentation](https://github.com/artifact-keeper/artifact-keeper/blob/main/docs/huggingface.md).
- The issues this walkthrough leans on: hosted `snapshot_download`
  ([#5280](https://github.com/artifact-keeper/artifact-keeper/issues/5280)), a cache-only mode
  ([#5282](https://github.com/artifact-keeper/artifact-keeper/issues/5282)), commit-pinned
  paths as immutable ([#5283](https://github.com/artifact-keeper/artifact-keeper/issues/5283)),
  seeding from a manifest ([#5284](https://github.com/artifact-keeper/artifact-keeper/issues/5284)),
  a model-file scanner ([#5285](https://github.com/artifact-keeper/artifact-keeper/issues/5285)),
  the Hub commit API ([#5291](https://github.com/artifact-keeper/artifact-keeper/issues/5291)),
  documentation ([#5290](https://github.com/artifact-keeper/artifact-keeper/issues/5290)).
