# Step 4: Approve names, not just versions

A language model asked for a package will sometimes name one that does not exist, or one a
letter away from the one it meant. If an attacker has registered that name, an install fetches
their code. This page makes the registry refuse every name nobody has reviewed, before any package file is
downloaded (on npm, the registry still fetches the package's metadata to resolve it).

**Make target:** `make curation`, which runs
[`policies/curation.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/ai-agent-dependency-guardrails/policies/curation.sh).
Approve one more name with `policies/approve.sh pypi|npm NAME`.

## The approved list

Artifact Keeper's curation rules are evaluated, by priority, on every remote and virtual
repository before a proxy fetch. In 1.11.7 a `block` pattern rule is what refuses a download, so
the walkthrough runs curation as an approved list:

- one `allow` rule (priority 100) for each name in the reviewed lockfiles, plus the internal
  names and the two lab test packages;
- one catch-all `block` rule (priority 1000), with the reason the client will see.

The PyPI list also holds the build backends (`hatchling` and its dependencies) that
`internal/build-constraints.txt` pins for building the internal package.

```text
policies: curation pypi-virtual: 42 approved names, catch-all block (43 rules added)
policies: curation npm-virtual: 93 approved names, catch-all block (94 rules added)
policies: npm-remote fetches only the exact spellings of 93 approved names (3 include patterns)
```

The rules go on every remote and virtual of each format. The refusal the client sees comes from
the virtual's own rules; on a PyPI virtual, a member whose rules block the name is also skipped.
Curation here is a plain approved list: allow rules for the reviewed names, then a catch-all
block. Approving a name approves every version of it that is old enough and has no known advisory. Versions of an approved name still pass through the cooldown and
the scan; this list is about names only.

## What the agent gets

An invented name ([agent session](8-replay-an-agent-session.md), step 2):

```console
$ uv add huggingface-cli
hint: An index (https://ak.internal/pypi/pypi-virtual/simple/) returned a 403 Forbidden error.
```

```text
GET https://ak.internal/pypi/pypi-virtual/simple/huggingface-cli/
403 Forbidden
{"error":"curation_blocked","package":"huggingface-cli","reason":"not on the approved list; ask the platform team to review it"}
```

`huggingface-cli` is the name Lasso Security reported models inventing, in March 2024; a placeholder
registered under it was downloaded more than 30,000 times in three months. A look-alike, `anthorpic`, gets the same
answer, and so does an MCP server started with `npx -y` that nobody reviewed:

```text
GET https://ak.internal/npm/npm-virtual/@modelcontextprotocol/server-filesystem/-/server-filesystem-0.6.2.tgz
403 Forbidden
{"error":"curation_blocked","package":"@modelcontextprotocol/server-filesystem","reason":"not on the approved list; ask the platform team to review it"}
```

The server in that example is a legitimate one; it is refused because nobody approved it here,
which is the point.

uv reports a refusal as "403 Forbidden" and npm as `E403`; the reason is in the response body,
which the agent transcripts show for every step.

## Approving a name

After a review, one command adds an allow rule ahead of the catch-all on every repository of that
format:

```console
$ policies/approve.sh pypi humanize "reviewed: pure Python, 10 years of releases"
approved pypi package humanize on pypi-remote pypi-lab pypi-virtual pypi-lab-virtual
```

and the next install succeeds. Gate G3 does exactly this.

## What 1.11.7 does not do here

Curation also has typosquat and popularity rules (edit distance to popular names, homoglyphs,
minimum downloads, block unknown). In 1.11.7 they only run on a staging sync path that the API
cannot configure, not on proxy downloads ([F7](findings.md)). So `anthorpic` is refused here
because it is unknown, not because it was recognised as a look-alike. With F7, a team could run
"allow unless suspicious" instead of an approved list. npm curation also checks only the tarball,
so npm resolves a version before the download is refused ([F8](findings.md)).

Curation rules also fold npm names the way PyPI does (`-`, `_` and `.` are the same), so
approving `side-channel-list` would also approve the different npm package `side_channel_list`
([F12](findings.md)), and a block rule for one spelling blocks all of them. The walkthrough works
around it at the npm remotes: `policies/curation.sh` sets their upstream filter to the exact,
case-sensitive spellings on the approved list, so a remote never fetches another spelling. That
refusal is a `404`, not a `403 curation_blocked`:

```text
other spellings of approved npm names: side_channel_list 404, lab_mcp_weather (served by the lab upstream) 404; side-channel-list 200
```

**Gate:** G3.

**Next:** [Step 5: Hold fresh releases](5-hold-fresh-releases.md).
