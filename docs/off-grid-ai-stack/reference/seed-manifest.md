# Seed manifest and inventory

--8<-- "includes/preview-offgrid.md"

[`seed/manifest.toml`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/seed/manifest.toml)
is the list of everything the site needs. [`seed/seed.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/seed/seed.sh)
pulls it through Artifact Keeper while the seed network has a route out, and
[`seed/inventory.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/seed/inventory.sh)
(run at the end of `make vet`, once the model is in `hf-models`) lists each item as the registry serves it, with its SHA-256. Anything not in the manifest is not on the
site afterwards: list exact versions and commits, never "latest".

## What the manifest lists

| Table | Fields | Seeded by | Served from on the site |
|---|---|---|---|
| `[[image]]` | `name`, `repo` (`oci-ghcr` or `oci-dockerhub`), `ref` (tag or digest), `artifact`, `why` | `podman pull localhost:30450/<repo>/<ref>` from the host; an OCI artifact (`artifact = true`, the trivy database) by `GET` of its manifest and layers | the same Remote, cache-only |
| `[[model]]` | `repo_id`, `revision` (a commit), `files`, `gguf`, `size_bytes`, `default` or `small` | a cache-seed job on `hf-hub` with the commit-pinned `resolve` paths; then `flows/vet.sh` publishes the files to `hf-models` | `hf-models` (Local) |
| `[python]` | `lock` (hash-pinned), `internal` (Acme's own, hash-pinned) | building the agent image, which installs both through the `pypi` Virtual | the `pypi` Virtual: `pypi-local`, then `pypi-remote` (cache-only) |
| `[[npm]]` | `name`, `version` | building the Claude Code image through `npm-remote` | `npm-remote` (cache-only) |
| `[[mcp]]` | `name`, `version`, `repo`, `source` | `mcp-internal`: published from `source`; `mcp-official`: a targeted seed of that name and version from the official registry (`POST .../mcp/seed`, [#5408](https://github.com/artifact-keeper/artifact-keeper/issues/5408)), which pins it | `mcp-all` (Virtual) |
| `[[plugin]]` | `name`, `version`, `source` | published to `plugins-central`, then read through the `plugins` Remote | the `plugins` Remote (cache-only) |

`SMALL_MODEL=1` selects the `[[model]]` entry marked `small` instead of the one marked
`default`, in every script.

## The inventory

`out/inventory/<label>.tsv`, sorted, one line per item:

| Column | For an image | For the model | For a Python package | For npm | For an MCP entry | For a plugin |
|---|---|---|---|---|---|---|
| kind | `image` | `model` | `python` | `npm` | `mcp` | `plugin` |
| name | `<repo>/<ref>` | `<repo_id>/<file>` | the wheel's file name | `<name>@<version>` | `<name>@<version>` | `<name>@<version>` |
| sha256 | the manifest digest the registry answers (`Docker-Content-Digest`) | the file | the file | the tarball | the `server` object of the entry, canonical JSON | the zip |
| bytes | `Content-Length` | the file | the file | the tarball | the canonical JSON | the zip |
| source | the repository and the HTTP status | | | | | |

The Python rows come from `pip download --require-hashes --no-deps` of the lock in a fresh
container on the stack's network, so they are exactly the wheels a clean install would get.
Claude Code's npm rows are the package and its `linux-x64` native package, the one an x86_64
install pulls.

Gate G1 checks that `seed.tsv` has every item with a digest; gate G7e runs the same script on
the site and diffs the first three columns: kind, name, SHA-256. An item the site cannot serve
has `-` in its sha256 column.
