# Step 6: Claude Code (best-effort)

--8<-- "includes/preview-offgrid.md"

!!! note "Best-effort, and labelled so"
    This step shows Claude Code wired to the off-grid stack: its plugin comes from Artifact
    Keeper's marketplace on the disconnected network, and its model is the local one behind
    llama-server's Anthropic-compatible API. The install is checked by gate G5. The model
    session is not a promise: a 1.5B model on a CPU is not a coding assistant, and with Claude
    Code's full system prompt and tools it does not follow instructions. The gate reports that
    part `BLOCKED(best-effort)` when it does not answer as asked.

```bash
make claude    # flows/claude.sh
```

The Claude Code image was built while seeding ([Step 2](2-seed-the-stack.md)): Node from
`oci-dockerhub`, `@anthropic-ai/claude-code` and its native `linux-x64` package from
`npm-remote`. Nothing about it needs an account here.

## The plugin, from the marketplace, offline

Claude Code adds the `plugins` Remote as a marketplace by its token-in-path URL (the
developer's read token in the path, so no settings file is needed) and installs `offgrid-ops`
from it, on `ak-offgrid-site`:

```console
--8<-- "docs/off-grid-ai-stack/snippets/claude-plugin.txt"
```

The marketplace's name is the Remote's key, `plugins`; the archive's SHA-256 is the one the
central repository published, which Claude Code checks. The plugin's skill loads. Its MCP
servers do not start in this image: they are Python, and the Claude Code image has Node only.
The [agent](5-run-the-agent-offline.md) is the one that runs them.

## The local model, through the Anthropic API

llama.cpp's server answers the Anthropic Messages API (`/v1/messages`) next to the OpenAI one,
so `ANTHROPIC_BASE_URL=http://ak-offgrid-llama:8080` points Claude Code at it, with any
non-empty `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_MODEL=local` (the alias `flows/agent.sh` gives
the model):

```console
--8<-- "docs/off-grid-ai-stack/snippets/claude-session.txt"
```

With its own system prompt and tool definitions (tens of thousands of tokens), the same
prompt took about 300 s on this host for the model to read, and the 1.5B model then echoed
part of the system prompt instead of answering. `CLAUDE_FULL=1 make claude` runs that session
too. With `--system-prompt` and `--tools ''` the wiring answers in seconds. A bigger model, or
a GPU, is what turns this into something useful; the registry side does not change.

Claude Code also tries to reach Anthropic's services for things other than the model
(telemetry, updates). The image sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`,
`DISABLE_AUTOUPDATER` and `DISABLE_TELEMETRY`; on the site there is no route for them in any
case ([Step 7](7-prove-nothing-leaves.md), G7a).
