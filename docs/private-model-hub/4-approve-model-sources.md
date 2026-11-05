# Step 4: Approve model sources

--8<-- "includes/preview-hf.md"

Anyone can publish a model on the Hub under any organization name they can register. A model id
in a notebook or a pull request is a supply-chain decision, the same as a package name. This
step makes the Remote fetch only from approved organizations, and refuses everything else before
the Hub is ever asked.

```bash
make allowlist    # flows/allowlist.sh
```

## An upstream filter for both path shapes

An upstream filter is a list of regular expressions matched against the path Artifact Keeper is
about to request upstream, relative to the upstream URL. The Hub API has two shapes, and a
filter has to cover both, or model info is refused while files are not (or the reverse):

| Request | Subject the filter sees |
|---|---|
| model info, tree | `api/models/acme-lab/tiny-st/revision/main`, `api/models/acme-lab/tiny-st/tree/<commit>` |
| a file | `acme-lab/tiny-st/resolve/<commit>/config.json` |

[`flows/allowlist.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/flows/allowlist.sh) creates `hf-curated`, a Remote of the lab Hub,
and admits two organizations:

```console
$ PUT /api/v1/repositories/hf-curated/upstream-filter
{
  "repository_key": "hf-curated",
  "include_patterns": [
    "^api/models/(acme-lab|sentence-transformers)/[^/]+(/(revision|tree)/[^/]+)?$",
    "^(acme-lab|sentence-transformers)/[^/]+/resolve/"
  ],
  "exclude_patterns": [],
  "active": true
}
```

The organization is followed by `/` in both patterns, so `acme-lab-evil/...` does not match
`acme-lab`. Two more things to know: the subject never includes the CDN host a large file
redirects to (the redirect is followed after the filter has admitted the `resolve/` path), and
the query string is part of the subject. Today the tree request reaches the filter without one
([findings F2](findings.md#f2-the-tree-listing-drops-recursivetrue-so-snapshot_download-misses-files-in-subdirectories));
once `?recursive=true` is passed on, the first pattern's `$` will refuse it, so widen it to
`(\?.*)?$` then. Artifact Keeper's Hugging Face documentation does not describe either
shape yet; [artifact-keeper#5290](https://github.com/artifact-keeper/artifact-keeper/issues/5290)
asks for this pair of patterns to be documented ([findings D2](findings.md#documentation-gaps)).

## What it admits and what it refuses

```console
== an approved organization resolves
{"ok":true,"commit":"099a800f5a0de0c030245fa4c02996957602a81e","files":9}

== everything else is refused before Artifact Keeper contacts the Hub
-- evil-org/backdoor
HTTP 404
Artifact not found upstream
{"ok": false, "cmd": "download", "error": "LocalEntryNotFoundError", ...}
-- sentence-transformer/all-MiniLM-L6-v2
HTTP 404
Artifact not found upstream
{"ok": false, "cmd": "download", "error": "LocalEntryNotFoundError", ...}
lab Hub requests for the refused names: 0
-- the same two names through hf-lab, which has no filter:
hf-lab evil-org/backdoor: HTTP 200
hf-lab sentence-transformer/all-MiniLM-L6-v2: HTTP 200
```

`sentence-transformer/all-MiniLM-L6-v2` (no "s") is the lookalike of the real
`sentence-transformers/all-MiniLM-L6-v2`. A refused path answers 404 without an upstream
request (the lab Hub's log has none), and a Virtual skips this member for it.

A filter only governs what is fetched. A path cached before the filter was set is still served
while its cache entry is fresh, and with the frozen TTL of [Step 7](7-freeze-and-go-offline.md)
that is forever: set the filter when you create the Remote, or purge with
`POST /api/v1/repositories/<key>/cache/invalidate?path=...`.
