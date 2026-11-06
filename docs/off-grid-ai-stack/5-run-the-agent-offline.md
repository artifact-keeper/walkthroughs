# Step 5: Run the agent offline

--8<-- "includes/preview-offgrid.md"

On the site network, with no route out, the whole AI stack comes up from Artifact Keeper
alone: the model server's image, the model, every Python package of the agent, its plugin and
its MCP servers. Then a small Python agent answers a question through a tool call to the local
model.

```bash
make agent                                   # flows/agent.sh
QUESTION="How many units of OG-2187 are in the south warehouse?" make agent
```

[`flows/agent.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/flows/agent.sh)
refuses to run before `make disconnect`. Its results go to `out/agent/`. Gate G4 checks the stock question's
answer, so run the gates after a `make agent` without `QUESTION`.

## 1. The images, pulled again

The llama.cpp server image and the python base image are removed from the host's image store
and pulled again through `oci-ghcr` and `oci-dockerhub`, now cache-only. Gate G4 compares the
digests with the ones podman reported while seeding (`out/seed-images.tsv`).

```console
$ make agent
flows/agent.sh

== 1. the llama.cpp server image and the python base image, pulled again through the registry
  localhost:30450/oci-ghcr/ggml-org/llama.cpp:server-b12124@sha256:c0a11067c72bb1eb330b8bddbf9869274c195e596bf4fae55fd527102e644b85: sha256:c0a11067c72bb1eb330b8bddbf9869274c195e596bf4fae55fd527102e644b85 (22 s); pulled while seeding: sha256:c0a11067c72bb1eb330b8bddbf9869274c195e596bf4fae55fd527102e644b85
  localhost:30450/oci-dockerhub/library/python:3.12-slim-trixie@sha256:b...: sha256:b18b261e1b4974b4f321451ad5251ded85abb22c2b8b262da527dda1d031ab30 (1 s)
```

## 2. The model, with hf download

The agent container has `HF_ENDPOINT=https://ak.internal/huggingface/hf-models` and the
developer token as `HF_TOKEN`, so the stock Hugging Face CLI downloads the vetted copy:

```bash
hf download Qwen/Qwen2.5-1.5B-Instruct-GGUF qwen2.5-1.5b-instruct-q4_k_m.gguf --local-dir /out/models/site
```

```console
== 2. the model from hf-models (Qwen/Qwen2.5-1.5B-Instruct-GGUF, qwen2.5-1.5b-instruct-q4_k_m.gguf)
  path: /out/models/site/qwen2.5-1.5b-instruct-q4_k_m.gguf
  sha256 6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e
```

The SHA-256 is the one the seed job recorded when it fetched the file from huggingface.co.

## 3. llama-server

`flows/agent.sh` starts it like this (from `off-grid-ai-stack/`):

```bash
podman run -d --name ak-offgrid-llama --network ak-offgrid-site \
  -v ./out/models/site:/models:ro,z localhost:30450/oci-ghcr/ggml-org/llama.cpp:server-b12124@sha256:c0a11067c72bb1eb330b8bddbf9869274c195e596bf4fae55fd527102e644b85 \
  -m /models/qwen2.5-1.5b-instruct-q4_k_m.gguf --alias local --jinja -c 32768 -t 16 --host 0.0.0.0 --port 8080
```

CPU only. `--jinja` uses the model's own chat template, which is what turns the `tools` of an
OpenAI request into a prompt the model was trained on, and its output back into `tool_calls`.
`LLAMA_CTX` and `LLAMA_THREADS` change `-c` and `-t`.

```console
== 3. llama-server on ak-offgrid-site
  /health {"status":"ok"}
  /v1/models ['local']
```

## 4. A clean install, from the registry alone

In a fresh python container on the site network, every package of the lock is installed again
from the `pypi` Virtual, hash-checked:

```bash
pip install --require-hashes --index-url https://developer:<token>@ak.internal/pypi/pypi/simple/ -r agent/requirements.lock
pip install --require-hashes --no-deps --index-url ... -r agent/requirements-internal.txt
pip check
```

```console
== 4. a clean install of the agent's packages, from the registry alone
No broken requirements found.
installed 73 distributions in 73 s
```

73 distributions: the 71 of the lock, Acme's package, and pip itself. `pip` found every file it
asked for in `pypi-remote`'s cache or in `pypi-local`, at the hash the lock pins.

## 5. The agent

[`agent/agent.py`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/agent/agent.py)
is about 200 lines on the `openai` and `mcp` packages. It talks to two hosts, `ak.internal` and
`ak-offgrid-llama`, and does this, recording each step:

1. **Installs its plugin** from the marketplace: `GET /agentplugins/plugins/offgrid-ops/index.json`,
   downloads the newest version and refuses it unless its SHA-256 equals the index's.
2. **Reads the plugin**: `mcp.json` (the MCP servers to start) and the skill (the instruction
   for the model).
3. **Checks every server against the MCP registry** `mcp-all`. For each command in `mcp.json`
   it finds the installed Python distribution that provides it (a console script, or the module
   of `python -m`), and starts the server only if `mcp-all` lists that distribution as a `pypi`
   package **at the installed version**. A server the registry does not list is not started.
4. **Starts the allowed servers** over stdio and lists their tools.
5. **Asks the local model** the question, with the tools of `acme-inventory`, and runs the tool
   calls it makes. The public server gets one direct call (`get_sqlite_version`), with no model
   involved, to show it works offline.

```console
== 5. the agent
  [   0.1s] plugin: {"name": "offgrid-ops", "version": "1.0.0", "url": "https://ak.internal/agentplugins/plugins/offgrid-ops/1.0.0/offgrid-ops-1.0.0.zip", "sha256": "334b543db38221feea0e74695b25a3623ddbef5b51062e5b7f56868caab00ebb", "index_sha256": "334b543db38221feea0e74695b25a3623ddbef5b51062e5b7f56868caab00ebb", "ve
  [   0.2s] registry: {"repo": "mcp-all", "packages": 2}
  [   1.5s] mcp-started: {"server": "acme-inventory", "command": "acme-inventory-mcp", "args": [], "distribution": "acme-inventory-mcp", "version": "1.0.0", "registry_name": "com.acme/inventory", "tools": ["list_warehouses", "stock_level"]}
  [11/06/26 05:15:52] INFO     Starting MCP server 'mcp-sqlite3'  transport.py:241
                               with transport 'stdio'
  [   4.0s] mcp-started: {"server": "sqlite", "command": "python", "args": ["-m", "mcp_sqlite3"], "distribution": "mcp-sqlite3", "version": "0.1.3", "registry_name": "io.github.daedalus/mcp-sqlite3", "tools": ["get_sqlite_version", "get_sqlite3_version", "complete_sql_statement", "connect_database", "close_connection", "com
  [   4.1s] sqlite-check: {"result": "3.46.1"}
  [   4.2s] llm: {"url": "http://ak-offgrid-llama:8080/v1", "models": ["local"], "tools": ["list_warehouses", "stock_level"]}
  [   8.4s] llm-turn: {"turn": 0, "seconds": 4.2, "tool_calls": ["stock_level"], "content": ""}
  [   8.4s] tool-call: {"tool": "stock_level", "arguments": {"sku": "OG-1138", "warehouse": "north"}, "result": "{\n  \"sku\": \"OG-1138\",\n  \"warehouse\": \"north\",\n  \"units\": 42,\n  \"ref\": \"inv-7f3a9c\"\n}"}
  [  10.3s] llm-turn: {"turn": 1, "seconds": 1.9, "tool_calls": [], "content": "There are 42 units of SKU OG-1138 in the north warehouse. (ref: inv-7f3a9c)"}
{"ok":true,"error":null,"plugin":{"name":"offgrid-ops","version":"1.0.0","sha256":"334b543db38221feea0e74695b25a3623ddbef5b51062e5b7f56868caab00ebb"},"servers":{"acme-inventory":["list_warehouses","stock_level"],"sqlite":["get_sqlite_version","get_sqlite3_version","complete_sql_statement","connect_database","close_connection","commit","rollback","execute_query","execute_many","execute_script","fetch_results","list_ta...
```

The final document (`out/agent/run.json`) ends with
`"answer":"There are 42 units of SKU OG-1138 in the north warehouse. (ref: inv-7f3a9c)","model":"local","seconds":10.6`.
The `INFO Starting MCP server 'mcp-sqlite3'` line is `fastmcp` logging to stderr as it starts.

The agent ran 10.6 s, the two MCP servers started in about 4 s, and the model's first turn
(reading the skill and the tool definitions, and choosing the call) took 4.2 s, the answer
1.9 s, on 16 CPU threads. The public server answered its direct call with SQLite 3.46.1.

### How we know the answer came from the tool

The inventory server's data is made up, and every reply carries a `ref`, `inv-7f3a9c`, that the
model cannot guess. Gate G4 checks that the model called `stock_level` with `OG-1138` and
`north`, and that the answer gives the tool's number, 42. The plugin's skill also asks the
model to end with `(ref: <ref>)`. Qwen2.5-1.5B does, and with the default model G4 gates on it.
With `SMALL_MODEL=1`, Qwen2.5-0.5B makes the right call and gives 42 but does not quote the ref,
even when told to:

```console
  [   6.1s] llm-turn: {"turn": 0, "seconds": 2.4, "tool_calls": ["stock_level"], "content": ""}
  [   6.1s] tool-call: {"tool": "stock_level", "arguments": {"sku": "OG-1138", "warehouse": "north"}, "result": "{\n  \"sku\": \"OG-1138\",\n  \"warehouse\": \"north\",\n  \"units\": 42,\n  \"ref\": \"inv-7f3a9c\"\n}"}
  [   7.0s] llm-turn: {"turn": 1, "seconds": 0.9, "tool_calls": [], "content": "There are 42 units of SKU OG-1138 in the north warehouse."}
```

and G4 reports it in its log without gating on it:

```text
SMALL_MODEL=1: answer quotes the tool's ref: false (not gated)
```

!!! note "A model that cannot call tools makes the number up"
    The first choice for `SMALL_MODEL=1` was SmolLM2-360M-Instruct. With the same llama.cpp
    image and the same skill, it made no tool call at all and answered "So there are 1000 units
    of SKU OG-1138 in the north warehouse": a number it invented, in a confident sentence.
    Qwen2.5-0.5B called `stock_level` correctly 3 times out of 3 and answered 42. On a
    disconnected site the model is the part least checked by a registry: test that the one you
    seed actually calls its tools, and check answers against tool results, as G4 does.

### What the registry check is, and is not

The check in point 3 ties a running server to an approved registry entry by package name and
version: a plugin cannot start a server the curator never approved, or another version of an
approved one. It is not a behavioural check. Approving a public MCP server, here
`io.github.daedalus/mcp-sqlite3`, means trusting its code and the operator behind its package on
pypi.org. Artifact Keeper does no behavioural analysis of MCP servers, and a malicious server
could detect that it is being probed and behave until it is not. On the site, the network is
what limits what an approved server can do.

`fastmcp`, which `mcp-sqlite3` uses, checks pypi.org for a newer release when it prints its
banner; the agent image sets `FASTMCP_CHECK_FOR_UPDATES=off` and `FASTMCP_SHOW_SERVER_BANNER=false`,
and `huggingface_hub`'s telemetry and Xet are off too. On the site there is no route for any of
them ([Step 7](7-prove-nothing-leaves.md)); off, they do not try.

