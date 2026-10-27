# Step 7: Refuse known-vulnerable versions

Models learned to write code from years of examples, and an agent will happily pin a version
from an old tutorial. This page makes the registry scan every file it fetches from upstream and
refuse it when a high or critical advisory applies, before the agent ever sees it.

**Make target:** `make policies`, which runs
[`policies/apply.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/policies/apply.sh).

## Scan-on-proxy

```console
$ curl … -X PUT https://ak.internal/api/v1/repositories/pypi-remote/security \
    -d '{"scan_enabled":true,"scan_on_proxy":true,"proxy_scan_action":"fail_closed",
         "block_on_policy_violation":true,"severity_threshold":"high"}'
```

On the remotes and the virtuals (a virtual applies the stricter of its own and its member's
setting). Each file fetched from upstream is scanned (Grype, plus the registry's own
OSV-based dependency scan) after it is downloaded and before it is served. `fail_closed` means an
inconclusive scan refuses the file too (`423 scan_pending`) instead of letting it through.

## What the agent gets

A pin from an old tutorial (agent step 10). The name `langchain` is approved for this test, so
that the scan, not the approved list, is what answers:

```console
$ policies/approve.sh pypi langchain "approved name; versions still scanned"
$ uv pip install --no-deps langchain==0.0.141
```

```text
GET https://ak.internal/pypi/pypi-virtual/simple/langchain/langchain-0.0.141-py3-none-any.whl
403 Forbidden
{"error":"scan_blocked","file":"langchain-0.0.141-py3-none-any.whl","reason":"blocked by inline vulnerability scan policy"}
```

And a real transitive dependency of the official MCP TypeScript SDK, on the day of the run:

```text
GET https://ak.internal/npm/npm-virtual/body-parser/-/body-parser-2.3.0.tgz
403 Forbidden
{"error":"scan_blocked","file":"body-parser-2.3.0.tgz",…}
```

The registry keeps a record of every proxy scan, which is how to find out why:

```console
$ curl … https://ak.internal/api/v1/repositories/npm-remote/security/proxy-scans
{"path":"body-parser/-/body-parser-2.3.0.tgz","state":"vulnerable","findings_count":1,"high_count":1,"max_severity":"high",…}
```

In that run Grype reported no vulnerabilities for body-parser and the OSV-based dependency scan
found GHSA-27r3-jxmh-p828. Run both. How the fixed version got in despite the cooldown is in
[Step 5](5-hold-fresh-releases.md#when-the-fix-is-too-fresh).

## Limits

- The file is downloaded and cached before the verdict ([F5](findings.md), #4514). The agent never
  receives it, but the bytes sit in the proxy cache.
- A scan knows only published advisories. A freshly compromised release has none yet, which is why
  the cooldown in Step 5 exists.

**Gate:** G6.

**Next:** [Step 8: Replay an agent session](8-replay-an-agent-session.md).
