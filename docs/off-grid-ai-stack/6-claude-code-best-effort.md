# Step 6: Claude Code (best-effort)

--8<-- "includes/preview-offgrid.md"

!!! note "Best-effort, and labelled so"
    This step shows Claude Code wired to the off-grid stack: it installs from `npm-remote` on
    the disconnected network, its plugin comes from Artifact Keeper's marketplace, and its model
    is the local one behind llama-server's Anthropic-compatible API. The install and the plugin
    are checked by gate G5. The model session is not a promise: a 1.5B model on a CPU is not a
    coding assistant, and with Claude Code's full system prompt and tools it does not follow
    instructions. The gate reports that part `BLOCKED(best-effort)` when it does not answer as
    asked.

```bash
make claude    # flows/claude.sh
```

The Claude Code image was built while seeding ([Step 2](2-seed-the-stack.md#6-npm-claude-code)):
Node from `oci-dockerhub`, `@anthropic-ai/claude-code` and its native `linux-x64` package from
`npm-remote`. Nothing about it needs an account here.

## A clean install, on the site

First, in a fresh `node` container on `ak-offgrid-site`, Claude Code is installed again with
`npm install -g` from `npm-remote` alone, now cache-only. Gate G5 checks that it runs:

```console
$ make claude
flows/claude.sh

== 0. a clean install of Claude Code from npm-remote, on the site
npm notice
claude --version: 2.1.318 (Claude Code) (6 s)
```

The script keeps only the last line of npm's output, here the end of an `npm notice` block
(at seed time that block said a newer npm was available), and then `claude --version`.

## The plugin, from the marketplace, offline

Claude Code adds the `plugins` Remote as a marketplace by its token-in-path URL (the
developer's read token in the path, so no settings file is needed) and installs `offgrid-ops`
from it. The script prints the token as `<token>`:

```console
== 1. the marketplace and the plugin, from the plugins Remote
$ claude plugin marketplace add https://ak.internal/agentplugins/t/<token>/plugins/claude-marketplace.json --json
{"command":"marketplace-add","outcome":"ok","marketplace":"plugins","message":"Downloading marketplace from https://ak.internal/agentplugins/t/<token>/plugins/claude-marketplace.json\nValidating marketplace data\nSaving marketplace to cache\nCleaning up old marketplace cache…\nSuccessfully added marketplace: plugins (declared in user settings)"}
$ claude plugin install offgrid-ops@plugins --json
{"command":"install","outcome":"ok","plugin":"offgrid-ops@plugins","pluginId":"offgrid-ops@plugins","scope":"user","message":"Successfully installed plugin: offgrid-ops@plugins (scope: user)"}
$ claude plugin list --json
[
  {
    "id": "offgrid-ops@plugins",
    "version": "1.0.0",
    "scope": "user",
    "enabled": true,
    "installPath": "/home/dev/.claude/plugins/cache/plugins/offgrid-ops/1.0.0",
    "installedAt": "2026-11-06T05:16:09.775Z",
    "lastUpdated": "2026-11-06T05:16:09.775Z",
    "projectEnabled": false
  }
]
```

The marketplace's name is the Remote's key, `plugins`; the archive's SHA-256 is the one the
central repository published, which Claude Code checks. The plugin's skill loads. Its MCP
servers do not start in this image: they are Python, and the Claude Code image has Node only.
The [agent](5-run-the-agent-offline.md) is the one that runs them.

## The local model, through the Anthropic API

llama.cpp's server answers the Anthropic Messages API (`/v1/messages`) next to the OpenAI one,
so `ANTHROPIC_BASE_URL=http://ak-offgrid-llama:8080` points Claude Code at it, with any
non-empty `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_MODEL=local` (the alias `flows/agent.sh` gives
the model). The prompt is `Reply with exactly the word OFFGRID and nothing else.`, with a
one-line system prompt (`--system-prompt`) and no tools (`--tools ''`):

```console
== 2. best-effort: one prompt through the local model (Anthropic Messages API on llama-server)
  minimal prompt, no tools, 3 s: {"is_error":false,"result":"OFFGRID","duration_ms":2008}
```

`out/claude/session.json` has the rest: 262 input tokens, 3 output tokens, `"stop_reason":
"end_turn"`. Claude Code prints `[claude-code:unrecognized_model] {"model":"local","query_source":"sdk"}`
to stderr (`out/claude/session.err`) because it does not know the alias `local`; the session
works regardless. Its `total_cost_usd` is Claude Code's own estimate from a price table; no one
is billed.

With `SMALL_MODEL=1` the same prompt does not get the answer. Qwen2.5-0.5B echoes the
environment section Claude Code adds to every prompt, and G5 reports the session
`BLOCKED(best-effort)`:

```console
  minimal prompt, no tools, 8 s: {"is_error":false,"result":"# Environment\nYou have been invoked in the following environment: \n - Primary working directory: /\n - Is a git repository: false\n - Platform: linux\n - Shell: bash\n - OS Version: Linux 7.0.0-34-generic","duration_ms":6832}
```

With Claude Code's own system prompt and tool definitions (tens of thousands of tokens), the
1.5B model took about 300 s on this host to read the prompt in a debug session, and then echoed
part of the system prompt instead of answering. `CLAUDE_FULL=1 make claude` runs that session
too; it is not part of the reference run. A bigger model, or a GPU, is what turns this into
something useful; the registry side does not change.

Claude Code also tries to reach Anthropic's services for things other than the model
(telemetry, updates). The image sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`,
`DISABLE_AUTOUPDATER` and `DISABLE_TELEMETRY`; on the site there is no route for them in any
case ([Step 7](7-prove-nothing-leaves.md), G7a).
