# Step 8: Prove it fails safely

--8<-- "includes/preview-hf.md"

Every claim the earlier steps make is a check in [`gates/`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/gates). Each check prints one
line, `PASS`, `FAIL` or `BLOCKED(<reason>)`, and appends it to `out/gates/results.tsv`. Checks
assert on status codes, headers, documents, file hashes and the lab Hub's request log, never on
message text. `make gates` exits non-zero on any `FAIL`; a `BLOCKED` check says nothing about
the walkthrough itself:

| Reason | Meaning |
|---|---|
| `BLOCKED(network)` | the backend cannot reach huggingface.co, so the real-Hub checks cannot run |
| `BLOCKED(ak-fix)` | an Artifact Keeper bug, reported and not fixed yet ([findings](findings.md)) |
| `BLOCKED(ak-gap)` | a capability Artifact Keeper does not have yet ([findings](findings.md)) |

```bash
make gates                 # all eight
gates/run-all.sh g05 g07   # some of them
```

The gates publish their own models (`acme/g5-<time>`, `acme/g6-<time>`) and use fresh client
caches, so they can run again and again on the same stack. G7 disconnects the upstreams and
reconnects them when it ends, even on failure.

## The gates

| Gate | What it proves |
|---|---|
| [G1 Access](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/gates/g01-access.sh) | Anonymous reads of a private repository are 401; a Hugging Face `hf_...` token is 401, not passed on; a `read:artifacts` token downloads, and the resolve `HEAD` carries `ETag` and `X-Repo-Commit`; a user without a grant gets 404 |
| [G2 Proxy](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/gates/g02-proxy.sh) | For the lab Hub and huggingface.co: `snapshot_download` completes, the snapshot directory and `refs/main` are the upstream commit, `SentenceTransformer.encode` works on CPU, a second workstation is served from the cache with no file fetched upstream; whether files in subdirectories are in the snapshot |
| [G3 Gated](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/gates/g03-gated.sh) | Without upstream auth the gated model is refused; `ml-team` downloads and loads it; others get 404; every upstream request carries the repository's Hub token and none a client token; the API never returns the Hub token |
| [G4 Allowlist](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/gates/g04-allowlist.sh) | An approved organization resolves; `evil-org/backdoor`, the lookalike and `acme-lab-evil/...` are refused on both path shapes without an upstream request; the same names pass without the filter |
| [G5 Hosted](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/gates/g05-hosted.sh) | Publishing file by file; 409 on re-publish; 403 without write permission or without `write:artifacts`; 401 anonymous; 405 to a Remote, 400 to a Virtual; downloads return the published bytes; `from_pretrained` and `SentenceTransformer` load it; `snapshot_download` (needs #5300) |
| [G6 Hold](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/gates/g06-hold.sh) | Scan on upload runs and a clean scan releases a file; a pickle that runs a command on load is flagged (it is not); a reviewer's hold is 409 on `GET` and `HEAD`; a rejection is 403; with no scan, an upload is held, and after release `block_unscanned` refuses it until its scan completes |
| [G7 Offline](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/gates/g07-offline.sh) | Both Hub Remotes are frozen; the offline workstation has no route out; for each seeded model: `snapshot_download` completes, files are served fresh (no `X-AK-Stale-Since`), the model loads with `HF_HUB_OFFLINE=1`, and whether it loads straight from Artifact Keeper within 60 s; an unseeded file is not served, quickly, and whether as a clean 404 |
| [G8 Fails safely](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/gates/g08-fails-safely.sh) | Xet metadata and headers never reach the client and `xet-read-token` is 404; a Virtual's `snapshot_download` fails as documented while `hf_hub_download` works; Range resumes (206), `If-Range` with another ETag (200), a suffix range, 416 past the end; `..%2f` in the file name or model id and `../` in `X-Filename` are 400; datasets and `whoami` are 404 |

## The reference run

On `grace`, 2026-11-05 02:07-02:11 UTC, with the backend built from artifact-keeper#5300, after
`make clean`, `make all` and a first `make gates` ([Results](results.md)): **76 PASS, 0 FAIL,
6 BLOCKED** of 82 checks, in 239 s (G7 takes 169 s of it, mostly the 60 s limits it puts on the
two direct offline loads).

```text
PASS              G1   anonymous model info on a private repository is 401
PASS              G1   anonymous download from a private repository is 401
PASS              G1   a Hugging Face token (hf_...) is refused with 401, not passed on
PASS              G1   a read:artifacts token reads model info (200)
PASS              G1   hf_hub_download with HF_TOKEN = an Artifact Keeper read:artifacts token works
PASS              G1   a resolve HEAD carries the ETag and X-Repo-Commit huggingface_hub needs
PASS              G1   a user with no grant on a private repository gets 404 (its existence is not disclosed)
PASS              G2   lab Hub: snapshot_download completes
PASS              G2   lab Hub: the snapshot directory and refs/main are the upstream commit (099a800f5a0de0c030245fa4c02996957602a81e)
PASS              G2   lab Hub: SentenceTransformer.encode on CPU gives 32-dimension vectors
PASS              G2   lab Hub: a second workstation's pull is served from the cache (ak_proxy_cache_lookups_total hits rise)
BLOCKED(ak-fix)   G2   lab Hub: snapshot_download fetches files in subdirectories (1_Pooling/config.json): the tree listing drops ?recursive=true, so 1_Pooling/config.json is not listed (findings F2)
PASS              G2   lab Hub: pulls of a model already in the cache fetch none of its files upstream
PASS              G2   huggingface.co: snapshot_download completes
PASS              G2   huggingface.co: the snapshot directory and refs/main are the upstream commit (1110a243fdf4706b3f48f1d95db1a4f5529b4d41)
PASS              G2   huggingface.co: SentenceTransformer.encode on CPU gives 384-dimension vectors
PASS              G2   huggingface.co: a second workstation's pull is served from the cache (ak_proxy_cache_lookups_total hits rise)
BLOCKED(ak-fix)   G2   huggingface.co: snapshot_download fetches files in subdirectories (1_Pooling/config.json): the tree listing drops ?recursive=true, so 1_Pooling/config.json is not listed (findings F2)
PASS              G3   without upstream auth the gated model is refused (hf-lab answers 502, the Hub said 401)
PASS              G3   alice (group ml-team) downloads the gated model through hf-lab-gated
PASS              G3   alice loads it with sentence-transformers
PASS              G3   bob (not in ml-team) is refused with 404
PASS              G3   the developer (read on hf-lab, not on hf-lab-gated) is refused with 404
PASS              G3   upstream requests for the gated model carry the repository's Hub token
PASS              G3   no client token (alice, bob, developer) ever reaches the lab Hub
PASS              G3   the repository API reports upstream auth as configured and never returns the Hub token
PASS              G4   an approved organization (acme-lab) resolves through hf-curated
PASS              G4   model info for evil-org/backdoor is refused (404)
PASS              G4   a file of evil-org/backdoor is refused (404)
PASS              G4   model info for sentence-transformer/all-MiniLM-L6-v2 is refused (404)
PASS              G4   a file of sentence-transformer/all-MiniLM-L6-v2 is refused (404)
PASS              G4   a name that only starts with an approved organization (acme-lab-evil/...) is refused
PASS              G4   the refused names never reached the lab Hub
PASS              G4   control: the same name through hf-lab (no filter) is 200, so the filter is what refused it
PASS              G5   the publisher uploads all 9 files with X-Filename (200 each)
PASS              G5   re-publishing a file at the same revision is 409
PASS              G5   a user without write permission cannot publish (403)
PASS              G5   a token without the write:artifacts scope cannot publish, even with write permission (403)
PASS              G5   anonymous publish is 401
PASS              G5   publishing to a Remote is 405, even for an admin
PASS              G5   publishing to a Virtual is 400, even for an admin
PASS              G5   hf_hub_download returns the published bytes (sha256 of 3 files, one in a subdirectory)
PASS              G5   AutoModel.from_pretrained loads the hosted model
PASS              G5   SentenceTransformer loads the hosted model
PASS              G5   snapshot_download of a hosted model returns every file
PASS              G6   scan on upload runs: grype completes on a model file
PASS              G6   a model file with a clean scan is released and downloads (status clean, 200)
BLOCKED(ak-gap)   G6   a pickle checkpoint whose load runs a shell command is flagged by a scan: no scanner reads pickle, safetensors or GGUF; it is released as clean (#3013, #2382; findings F4)
PASS              G6   a reviewer's hold refuses the download (409)
PASS              G6   a held file's HEAD is refused too (409)
PASS              G6   a rejected file is refused (403)
PASS              G6   with no scan yet, a new upload is held (409)
PASS              G6   released but unscanned, block_unscanned refuses it (403)
PASS              G6   after its scan completes it downloads (200)
PASS              G7   hf-lab is frozen: cache-ttl 315360000, on-upstream-not-found keep
PASS              G7   hf-hub is frozen: cache-ttl 315360000, on-upstream-not-found keep
PASS              G7   the offline workstation has no route out (huggingface.co, its CDN, pypi.org, 1.1.1.1)
PASS              G7   hf-lab: snapshot_download of the seeded model completes offline (9 files, commit 099a800f5a0d)
PASS              G7   hf-lab: a seeded file is served fresh, not stale (200, no X-AK-Stale-Since)
PASS              G7   hf-lab: the workstation loads it offline (SentenceTransformer and AutoModel, HF_HUB_OFFLINE=1)
BLOCKED(ak-fix)   G7   hf-lab: a fresh offline workstation loads the model straight from Artifact Keeper within 60 s: each optional file the library probes is a 502 after a failed upstream attempt, and huggingface_hub retries 5xx (findings F3, artifact-keeper#5282)
PASS              G7   hf-hub: snapshot_download of the seeded model completes offline (10 files, commit 1110a243fdf4)
PASS              G7   hf-hub: a seeded file is served fresh, not stale (200, no X-AK-Stale-Since)
PASS              G7   hf-hub: the workstation loads it offline (SentenceTransformer and AutoModel, HF_HUB_OFFLINE=1)
BLOCKED(ak-fix)   G7   hf-hub: a fresh offline workstation loads the model straight from Artifact Keeper within 60 s: each optional file the library probes is a 502 after a failed upstream attempt, and huggingface_hub retries 5xx (findings F3, artifact-keeper#5282)
PASS              G7   an unseeded file is not served offline, and the answer comes in under 10 s
BLOCKED(ak-fix)   G7   an unseeded file answers 404 (a clean miss), so clients do not retry: it answers 502 after trying the upstream; there is no cache-only mode (artifact-keeper#5282)
PASS              G8   model info: xetHash and xetEnabled, present upstream, are stripped
PASS              G8   tree: no xetHash reaches the client
PASS              G8   a large-file HEAD carries no X-Xet-Hash or xet-auth link
PASS              G8   xet-read-token is not proxied (404)
PASS              G8   a Virtual's snapshot_download fails as documented (model info 404)
PASS              G8   a Virtual's hf_hub_download of a named file works
PASS              G8   Remote: a resume (Range: bytes=1000-) is 206 with the right bytes
PASS              G8   Remote: a resume whose If-Range names another ETag gets the whole file (200)
PASS              G8   Local: a suffix range (bytes=-100) is 206 with 100 bytes
PASS              G8   Local: a range past the end is 416
PASS              G8   a ..%2f traversal in the file name is refused (400)
PASS              G8   a ..%2f traversal in the model id is refused (400)
PASS              G8   an upload whose X-Filename climbs out of the model (../../) is refused (400)
PASS              G8   datasets are not served (404): models only
PASS              G8   account calls (whoami) are not served (404)
```

The six `BLOCKED` lines are findings, not gaps in the walkthrough:

| Check | Why | Tracked in |
|---|---|---|
| G2 x2: files in subdirectories are in the snapshot | the tree listing of a Remote drops `?recursive=true` | [F2](findings.md#f2-the-tree-listing-drops-recursivetrue-so-snapshot_download-misses-files-in-subdirectories) (not filed yet) |
| G6: a malicious pickle is flagged | no scanner reads model files | [F4](findings.md#f4-a-clean-scan-releases-a-malicious-pickle-from-the-upload-hold), [#5285](https://github.com/artifact-keeper/artifact-keeper/issues/5285) |
| G7 x2: a fresh offline workstation loads straight from Artifact Keeper in 60 s | uncached optional files are 502s that clients retry | [F3](findings.md#f3-offline-every-uncached-path-is-a-502-after-an-upstream-attempt-and-clients-retry-it), [#5282](https://github.com/artifact-keeper/artifact-keeper/issues/5282) |
| G7: an unseeded file is a clean 404 | no cache-only mode | [#5282](https://github.com/artifact-keeper/artifact-keeper/issues/5282) |

With the `:dev` image (`main` without #5300), G5's hosted `snapshot_download` check is a seventh,
`BLOCKED(ak-fix)` ([F1](findings.md#f1-snapshot_download-fails-against-a-local-repository)):
75 PASS, 0 FAIL, 7 BLOCKED in the run of 2026-11-04 22:08 UTC.
