# Step 7: Freeze and go offline

--8<-- "includes/preview-hf.md"

The end state of a private model hub: a site cut off from the internet, where every model it
needs comes from Artifact Keeper. This step makes the cache authoritative, seeds it while still
connected, disconnects, and loads the models from a workstation that has no route out.

```bash
make freeze    # flows/freeze.sh
```

## Freeze, at creation

By default a Remote revalidates mutable paths after 300 s (`cache-ttl`), and for Hugging Face
every path counts as mutable, including `resolve/<commit>/...`
([#5283](https://github.com/artifact-keeper/artifact-keeper/issues/5283)). After the upstream
disappears, an expired entry is served stale (with `Warning: 110` and `X-AK-Stale-Since`) for
the stale-if-error grace window, one hour by default, and then not at all. A frozen Remote
never revalidates and never evicts:

```console
== the freeze, set at creation
hf-lab: {"repository_key":"hf-lab","cache_ttl_seconds":315360000} {"repository_key":"hf-lab","on_upstream_not_found":"keep"}
hf-hub: {"repository_key":"hf-hub","cache_ttl_seconds":315360000} {"repository_key":"hf-hub","on_upstream_not_found":"keep"}
```

[`registry/bootstrap.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/registry/bootstrap.sh) sets both when it creates the Remotes,
not here, because **a raised cache-ttl applies to an entry only from its next revalidation**:
an entry cached under the 300 s default keeps that freshness. In a first build of this
walkthrough the TTL was raised in this step, after step 2 had cached the lab model, and the
offline workstation got those files back marked stale (`X-AK-Stale-Since`), on borrowed time.
If the cache is already warm, invalidate what you need and pull it again.

## Seed

Pull every model the site needs, the way it will be used, while still connected:

```console
== seed: pull every model the site needs, the way it will be used
{"ok":true,"commit":"099a800f5a0de0c030245fa4c02996957602a81e","files":9}
{"ok":true,"shape":[2,32]}
{"ok":true,"model":"BertModel","hidden":[1,4,32]}
{"ok":true,"commit":"1110a243fdf4706b3f48f1d95db1a4f5529b4d41","files":10}
{"ok":true,"shape":[2,384]}
{"ok":true,"model":"BertModel","hidden":[1,4,384]}
```

The cache key is the path as requested, revision included: a file pulled at `main` and the same
file at its commit are two entries ([findings F6](findings.md#f6-the-cache-key-is-the-revision-as-spelled-and-every-hugging-face-path-is-mutable)).
`snapshot_download` requests files at the commit, and so does a library loading a model whose
`refs/main` is known, so seeding with `snapshot_download` and a load covers what a workstation
will ask for. Seeding from a manifest is
[artifact-keeper#5284](https://github.com/artifact-keeper/artifact-keeper/issues/5284).

## Disconnect

[`disconnect`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/flows/lib.sh) stops the lab Hub and points `hf-hub`'s egress at a proxy
address nothing listens on, so every fetch from huggingface.co fails as it would on a cut
link. The workstation runs on `ak-hf-offline`, an internal network whose only other member is
Caddy:

```console
== disconnect
disconnected: lab Hub stopped; hf-hub egress -> http://172.31.80.200:9 (HTTP 200)
huggingface.co unreachable: gaierror [Errno -2] Name or service not known
pypi.org unreachable: gaierror [Errno -2] Name or service not known
1.1.1.1 unreachable: OSError [Errno 101] Network is unreachable
```

## Load the models offline

A fresh workstation fills its cache from Artifact Keeper, then loads with
`HF_HUB_OFFLINE=1`:

```console
== a workstation on the disconnected network fills its cache from Artifact Keeper and loads the models
{"ok":true,"commit":"099a800f5a0de0c030245fa4c02996957602a81e","files":9,"seconds":0.5}
hf-lab HEAD resolve/099a800f5a0d.../config.json: HTTP 200, X-AK-Stale-Since: absent
{"ok":true,"seconds":0.3}
{"ok":true,"shape":[2,32],"first":[-0.457369,0.287261,-0.22734,-0.365521],"seconds":7.7}
{"ok":true,"model":"BertModel","hidden":[1,4,32],"seconds":6.4}
{"ok":true,"commit":"1110a243fdf4706b3f48f1d95db1a4f5529b4d41","files":10,"seconds":1.1}
hf-hub HEAD resolve/1110a243fdf4.../config.json: HTTP 200, X-AK-Stale-Since: absent
{"ok":true,"seconds":0.3}
{"ok":true,"shape":[2,384],"first":[-0.003146,-0.047963,0.010903,-0.01194],"seconds":7.8}
{"ok":true,"model":"BertModel","hidden":[1,4,384],"seconds":6.3}
```

The second line of each block is `hf_hub_download(..., "1_Pooling/config.json",
revision=<commit>)`: `snapshot_download` leaves files in subdirectories out
([findings F2](findings.md#f2-the-tree-listing-drops-recursivetrue-so-snapshot_download-misses-files-in-subdirectories)),
and `HF_HUB_OFFLINE=1` cannot fetch what the snapshot missed. The encodings are the same as
online, to the sixth decimal.

## Why HF_HUB_OFFLINE

The same load straight from Artifact Keeper, without `HF_HUB_OFFLINE`, given 60 s:

```console
== the same load without HF_HUB_OFFLINE, straight from Artifact Keeper (given 60 s)
{"ok":false,"error":"Timeout","seconds":60.0}
     66 resolve/<commit>/config_sentence_transformers.json
      3 resolve/<commit>/modules.json
```

`sentence-transformers` asks for files the model does not have (here
`config_sentence_transformers.json`). Online the Hub answers 404 and the library moves on.
Offline, Artifact Keeper has no cached answer, tries the upstream, and returns 502;
`huggingface_hub` retries 5xx with backoff, and the library asks again. That request was made 66
times in 60 s. A cache-only mode that answers a clean 404 is
[artifact-keeper#5282](https://github.com/artifact-keeper/artifact-keeper/issues/5282)
([findings F3](findings.md#f3-offline-every-uncached-path-is-a-502-after-an-upstream-attempt-and-clients-retry-it)).

## A model nobody seeded

```console
== a model nobody seeded
GET acme-lab/never-seeded/resolve/main/config.json: HTTP 502 Failed to fetch from upstream
```

Not served, and the answer comes in about 3 s, but as a 502 a client will retry rather than a
404.

!!! note "One instance, disconnected"
    The lab takes the upstreams away from Artifact Keeper (the lab Hub is stopped, huggingface.co
    goes through a dead proxy) rather than taking Artifact Keeper off the network: the backend
    container keeps its route out. The workstation has none. Moving the whole stack onto an isolated network is the subject of a
    later walkthrough.
