# Step 6: Own your internal names

If a public index has a package with the same name as an internal one, at a higher version, a
resolver that sees both will usually take the public one. That is dependency confusion, and MCP
servers are packages like any other: an internal `@acme/tickets-mcp` can be squatted on npm. This
page makes the registry own the internal names, so the public version is never offered.

**Configured by:** `make bootstrap` (virtual priorities, `npm_virtual_isolate_hosted_names`, the
npm upstream filter).

## Three settings

1. **Explicit priorities.** In each virtual the hosted member is priority 1 and the remote 2. A
   PyPI virtual hides a remote's files for a name the hosted member holds only when the hosted
   member's number is lower; equal priorities would serve both (members created with the repository default to 0).
2. **Isolated hosted names on npm.** `npm_virtual_isolate_hosted_names: true` on the npm virtuals
   makes a name that a hosted member holds hosted-only: no version of it comes from a remote.
3. **An upstream filter on `npm-remote`.** `^/?@acme(/|%2[Ff])` is excluded, so a request for
   anything in the `@acme` scope never leaves the registry:

```console
$ curl … -X PUT https://ak.internal/api/v1/repositories/npm-remote/upstream-filter \
    -d '{"exclude_patterns":["^/?@acme(/|%2[Ff])"]}'
```

## What the agent gets

The lab upstream publishes `acme-agent-tools` 99.0.0 and `@acme/tickets-mcp` 99.0.0. The lab
virtuals put it behind the internal repositories, exactly as `pypi-remote` and `npm-remote` sit
in the main ones. An unpinned install through the lab virtuals (agent steps 8 and 9; the uv step
resolves with `--dry-run`):

```console
$ uv --config-file /etc/uv/lab.toml pip install --system --dry-run acme-agent-tools
 + acme-agent-tools==1.0.0

$ npm install --registry https://ak.internal/npm/npm-lab-virtual/ @acme/tickets-mcp && npm ls @acme/tickets-mcp
└── @acme/tickets-mcp@1.0.0
```

The lab remote has 99.0.0 (HTTP 200 directly), but the virtual offers only the internal version:

```text
npm-lab-virtual offers: {"versions":["1.0.0"],"latest":"1.0.0"}
npm-remote @acme/* (upstream filter): 404
```

## MCP servers

Treat MCP servers as dependencies: publish internal ones to the hosted repository, pin the
version in `package.json`, install them with the lockfile, and start them from `node_modules`
rather than `npx -y <name>@latest`. The app does exactly this:

```python
SERVER = StdioServerParameters(command="node_modules/.bin/tickets-mcp", args=[])
```

An MCP server nobody reviewed is refused by the approved list ([Step 4](4-approve-names.md)).

**Gates:** G5 and G7.

**Next:** [Step 7: Refuse known-vulnerable versions](7-refuse-known-vulnerable.md).
