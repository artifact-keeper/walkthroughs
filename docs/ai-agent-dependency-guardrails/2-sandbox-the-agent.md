# Step 2: Put the agent in a sandbox

This page builds the container the agent works in. The only host it can reach is the registry,
`ak.internal`, and its package managers point at that one index. The registry, not the client configuration, is the
control: the agent can edit any file it likes and still reach nothing else.

**Make target:** `make sandbox`, which runs
[`sandbox/build.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/sandbox/build.sh).
[`sandbox/run.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/sandbox/run.sh)
runs any command in it.

## The image

[`sandbox/Containerfile`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/sandbox/Containerfile)
(abridged):

```dockerfile
FROM ${REG}/oci-dockerhub/library/node:22-trixie-slim AS node
FROM ${REG}/oci-ghcr/astral-sh/uv:0.13.6-python3.12-trixie-slim
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY ak-internal-ca.crt /usr/local/share/ca-certificates/ak-internal-ca.crt
RUN update-ca-certificates
COPY uv.toml /etc/uv/uv.toml
COPY npmrc /usr/local/etc/npmrc
ENV UV_INDEX_AK_USERNAME=agent NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/ak-internal-ca.crt
USER agent
```

Both base images come through the registry's image proxies (`REG` is `localhost:30445`, with the
builder token). The image holds no credentials.

`/etc/uv/uv.toml`, uv's system-wide configuration:

```toml
index-strategy = "first-index"

[[index]]
name = "ak"
url = "https://ak.internal/pypi/pypi-virtual/simple/"
default = true
```

`/usr/local/etc/npmrc`, npm's global configuration:

```ini
registry=https://ak.internal/npm/npm-virtual/
//ak.internal/npm/npm-virtual/:_authToken=${AK_TOKEN}
```

The agent's token arrives at run time, as `AK_TOKEN` for npm and `UV_INDEX_AK_PASSWORD` for uv.
Nothing is written into `pyproject.toml`, `package.json` or either lockfile.

```text
sandbox: uv 0.13.6, node v22.23.4, npm 10.9.9, python 3.12.16
```

## The only host it can reach: ak.internal

`sandbox/run.sh` starts the container on `agent-net` (`internal: true`), as a non-root user,
with the agent's token. From inside:

```text
reached  https://ak.internal/readyz 200
no route https://pypi.org/simple/ URLError
no route https://registry.npmjs.org/ URLError
no route https://github.com/ URLError
```

Not even DNS resolves anything but `ak.internal`. So when the agent decides to go around the
registry, which is exactly what an agent driven by malicious instructions would do, this is all
it gets ([Step 8](8-replay-an-agent-session.md), step 11):

```console
$ uv pip install --default-index https://pypi.org/simple/ requests
error: Request failed after 3 retries in 5.1s
  cause: Failed to fetch: https://pypi.org/simple/requests/
  …
  cause: failed to lookup address information: Name does not resolve
```

The same container works with a real agent CLI inside it: give it the model API endpoint as the
one extra route (through an egress proxy that allows only that host), and keep the package
managers pointed at `ak.internal`.

**Gate:** G1 (the sandbox reaches the registry and nothing else).

**Next:** [Step 3: Publish internal packages and lock the app](3-publish-and-lock.md).
