# Step 3: Gated and private models

--8<-- "includes/preview-hf.md"

Gated models (Llama, Gemma and many others) need a Hugging Face token whose owner accepted the
model's terms; private ones need a token with access. The token a client sends to Artifact
Keeper is an Artifact Keeper token and is never forwarded to the Hub, so the Hub credential
belongs to the Remote. Whoever can read that Remote can download what its token can see, so
the Remote is restricted to one group.

```bash
make gated    # flows/gated.sh
```

In the lab, `acme-lab/gated-llm` on the lab Hub plays the gated model: 401 without a token,
403 with a token that is not the lab's.

## Without a Hub credential

`hf-lab` has no upstream credential. The Hub answers 401 (`X-Error-Code: GatedRepo`), and the
client sees a 502:

```console
== without upstream auth: hf-lab cannot fetch the gated model
HTTP 502
Failed to fetch from upstream
```

A client therefore gets a generic upstream error rather than `GatedRepoError`; the gated
status is not passed on.

## A Remote that holds the Hub token

[`flows/gated.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/flows/gated.sh) creates `hf-lab-gated`, a second Remote of the same
Hub, gives it the Hub token, and lets only the group `ml-team` read it:

```bash
POST /api/v1/repositories     {"key": "hf-lab-gated", "format": "huggingface", "repo_type": "remote",
                               "upstream_url": "http://172.31.80.200:8080", "visibility": "private"}
PUT  /api/v1/repositories/hf-lab-gated/upstream-auth   {"auth_type": "bearer", "password": "<Hub token>"}
POST /api/v1/groups           {"name": "ml-team"}
POST /api/v1/groups/<id>/members   {"user_ids": ["<alice>"]}
POST /api/v1/permissions      {"principal_type": "group", "principal_id": "<ml-team>",
                               "target_type": "repository", "target_id": "<hf-lab-gated>", "actions": ["read"]}
```

The script reads the token from `registry/.tokens/lab-hub.token` and never prints it; the
repository API only reports that one is set:

```console
PUT /api/v1/repositories/hf-lab-gated/upstream-auth: HTTP 200
{"key":"hf-lab-gated","upstream_auth_type":"bearer","upstream_auth_configured":true,"visibility":"private"}
group ml-team: HTTP 200
alice added to ml-team: HTTP 200
granted group ml-team ["read"] on hf-lab-gated
```

## Who gets the model

```console
== alice (ml-team) downloads the gated model
{"ok":true,"commit":"f1268f90abad60dc0d7cbc6806b9f11792b66e10","files":[".gitattributes","README.md","config.json","model.safetensors",...]}
{"ok": true, "cmd": "encode", "endpoint": "https://ak.internal/huggingface/hf-lab-gated", "shape": [2, 32], ...}

== bob (not in ml-team) is refused
{"ok": false, "cmd": "download", "error": "LocalEntryNotFoundError", "status": null, "msg": "An error happened while trying to locate the file on the Hub and we cannot find the requested files in the local cache. ..."}
HTTP 404
Repository not found
```

Bob gets 404, not 403: a private repository a user cannot read is not disclosed to them. The
same holds for the developer, who can read `hf-lab` but not `hf-lab-gated` (gate G3).

## Which token reached the Hub

The lab Hub logs a fingerprint of the bearer token on each request. Grouped:

```console
fingerprints: hub token 26d7a93845b5bcc4, alice 87f278211b07215d, bob 105d0dbb28cda035
     28 /acme-lab/gated-llm/resolve/<rev>/<file>  auth=26d7a93845b5bcc4
      1 /api/models/acme-lab/gated-llm  auth=26d7a93845b5bcc4
      2 /api/models/acme-lab/gated-llm/revision/<rev>  auth=26d7a93845b5bcc4
      1 /api/models/acme-lab/gated-llm/revision/<rev>  auth=none
      2 /api/models/acme-lab/gated-llm/tree/<rev>  auth=26d7a93845b5bcc4
      2 /cdn/<sha256> (the redirect target)  auth=none
```

Every request through `hf-lab-gated` carried the repository's token; none carried Alice's or
Bob's. The one `revision/<rev>` request with no token is `hf-lab`'s attempt from the first
section, logged in the same second. The
large file's redirect to the CDN was followed without any token, as it should be: on the Hub,
the signed CDN URL is the credential.

!!! note "Not machine-verified: a real gated model"
    The lab Hub reproduces the Hub's 401 and 403 answers for a gated model. Using a real
    gated model (accepting its terms on huggingface.co and setting that account's token on
    `hf-hub`) was not done here.
