# Step 1: Stand up the registry

--8<-- "includes/preview-hf.md"

This step starts Artifact Keeper with TLS under one name, `https://ak.internal`, starts the lab
Hub that stands in for huggingface.co, creates the package proxies and the two Hub Remotes,
mints tokens for a developer, a publisher and two members of the ML team, and builds the
workstation image through the registry itself.

```bash
make registry-up   # the stack, the CA, the lab Hub
make bootstrap     # repositories, users, tokens
make client        # the workstation image, built through the registry
```

## The stack

`registry/compose/docker-compose.yml` is Artifact Keeper's own compose file, copied unmodified
([`VERSIONS`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/registry/compose/VERSIONS) records where from). Every change lives in
[`compose.override.yml`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/registry/compose/compose.override.yml): the images (`:dev` of
`main`, pinned by digest), an `ak-hf-` prefix on every container, Caddy answering as
`ak.internal` with a certificate from its internal CA on `127.0.0.1:30449`, and two networks:

| Network | Subnet | Who is on it |
|---|---|---|
| `ak-hf-net` | `172.31.80.0/24` | the stack, the lab Hub at `.200`, workstations |
| `ak-hf-offline` | `172.31.81.0/24`, `internal: true` | Caddy (as `ak.internal`) and the [Step 7](7-freeze-and-go-offline.md) workstation, nothing else: no route out |

Two backend settings matter here:

| Setting | Why |
|---|---|
| `AK_SSRF_ALLOW_PRIVATE_CIDRS=172.31.80.200/32` | The lab Hub is a private address, which the SSRF guard refuses by default. Only that one address is let through; it also covers the lab's CDN name `cdn.lab`, which resolves to it. Against huggingface.co you need nothing here. |
| `AK_EXTERNAL_URL` unset | The other walkthroughs set it to `https://ak.internal`. Here the workstation image is built on the host, which cannot resolve `ak.internal`, and the OCI token realm is built from this setting; unset, it follows the Host header. |

The [Caddyfile](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/registry/caddy/Caddyfile) routes `/huggingface/*` to the backend. The
trimmed Caddyfiles of the other walkthroughs leave it out, and without it every Hub request
falls through to the web UI and gets an HTML 404.

```console
$ make registry-up
up.sh: backend=ghcr.io/artifact-keeper/artifact-keeper-backend:dev@sha256:f60236fb... web=ghcr.io/artifact-keeper/artifact-keeper-web:dev@sha256:ddc8125b...
...
up.sh: waiting for https://ak.internal:30449/readyz . ready
{"status":"healthy","version":"1.11.3"}
{"lab-hub on": 8080, "models": {"acme-lab/tiny-st": "099a800f5a0de0c030245fa4c02996957602a81e", "acme-lab/gated-llm": "f1268f90abad60dc0d7cbc6806b9f11792b66e10", "sentence-transformer/all-MiniLM-L6-v2": "8321380665c9e74a7a302e3e85959feb9da1ba96", "acme-lab/never-seeded": "e1c55712dc206f5dde354afa763282ca10ea6442", "evil-org/backdoor": "65752434a79fecb5c70c7c7c144ea24f6ea712bd"}, "gated_token_set": true}
lab-hub: http://172.31.80.200:8080 (alias cdn.lab)
```

`main` still reports `1.11.3`; the next release is 1.12.0.

## The lab Hub

[`lab-hub/server.py`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/lab-hub/server.py) is about 400 lines of Python standard library. It
serves the parts of the Hub API that `huggingface_hub` uses to download, in the Hub's shapes:
model info with `siblings` and a commit `sha`, a tree with `?recursive` and cursor
pagination, and `/resolve/` with `X-Repo-Commit` and `ETag`. Small files are served inline;
large ones are a 302 to `http://cdn.lab:8080/cdn/<sha256>` with `X-Linked-Etag`,
`X-Linked-Size` and Xet headers, as the Hub does. Its metadata carries `xetHash` and
`xetEnabled`. It generates five models from fixed seeds, so every run serves the same bytes and
commits:

| Model | What it is for |
|---|---|
| `acme-lab/tiny-st` | a tiny BERT sentence-transformers model (32 dimensions, 64 KB of weights), with a file in a subdirectory (`1_Pooling/config.json`) |
| `acme-lab/gated-llm` | gated: 401 without `Authorization: Bearer <lab token>`, 403 with another token ([Step 3](3-gated-and-private-models.md)) |
| `sentence-transformer/all-MiniLM-L6-v2` | a lookalike of the real `sentence-transformers/...` ([Step 4](4-approve-model-sources.md)) |
| `evil-org/backdoor` | a `pytorch_model.bin` pickle whose load would run a shell command (never unpickled) |
| `acme-lab/never-seeded` | a model no step pulls ([Step 7](7-freeze-and-go-offline.md)) |

Every request is logged as one JSON line with a fingerprint of the bearer token it carried
(the first 16 hex characters of its sha256), so the gates can prove which token reached the
Hub without logging any token.

## Repositories

[`registry/bootstrap.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/registry/bootstrap.sh) creates:

| Key | Format, type | Visibility | Role |
|---|---|---|---|
| `oci-dockerhub` | docker, Remote of `registry-1.docker.io` | internal | the workstation's base image |
| `pypi-remote` | pypi, Remote of `pypi.org` | internal | `huggingface_hub`, `transformers`, ... |
| `pypi-torch` | pypi, Remote of `download.pytorch.org/whl/cpu` | internal | CPU-only torch; a flat index, so `"pypi_upstream_index_path": ""` |
| `hf-hub` | huggingface, Remote of `https://huggingface.co` | private | the real Hub |
| `hf-lab` | huggingface, Remote of `http://172.31.80.200:8080` | private | the lab Hub |

The later steps add `hf-lab-gated`, `hf-curated`, `hf-local`, `hf-models` and
`hf-staging`. A Hugging Face Remote takes the bare origin as its upstream; the handler appends
the Hub's paths itself:

```json
{"key": "hf-hub", "format": "huggingface", "repo_type": "remote",
 "upstream_url": "https://huggingface.co", "visibility": "private"}
```

Both Hub Remotes are **frozen at creation**: their cache never expires and an upstream 404 never
evicts a cached file. [Step 7](7-freeze-and-go-offline.md) explains why this has to happen
before the first pull:

```bash
PUT /api/v1/repositories/hf-hub/cache-ttl            {"cache_ttl_seconds": 315360000}
PUT /api/v1/repositories/hf-hub/on-upstream-not-found {"on_upstream_not_found": "keep"}
```

## Users and tokens

| User | Token scopes | Grants | Used for |
|---|---|---|---|
| `developer` | `read:artifacts` | read on every Hugging Face repository except `hf-lab-gated` | what `HF_TOKEN` holds on a workstation |
| `publisher` | `read:artifacts`, `write:artifacts` | read and write on `hf-local`, `hf-staging` | a training pipeline publishing models |
| `publisher` (second token) | `read:artifacts` | the same | proof that the scope, not only the grant, is checked (G5) |
| `alice` | `read:artifacts` | through group `ml-team`: `hf-lab-gated` | gated models ([Step 3](3-gated-and-private-models.md)) |
| `bob` | `read:artifacts` | `hf-lab` only | someone outside the ML team |

Tokens go to `registry/.tokens/` (gitignored, mode 600) and reach containers through the
environment only.

## The workstation

[`client/Containerfile`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/client/Containerfile) is an ML workstation built entirely through
the registry: the base image comes through `oci-dockerhub`, torch through `pypi-torch`, the rest
through `pypi-remote`. Rootless podman cannot attach a build to a named network, so
[`client/build.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/client/build.sh) builds on the host network with
`--add-host ak.internal:127.0.0.1`; the developer token reaches `pip` as a build secret and stays
out of the image.

```console
$ make client
...
Looking in indexes: https://developer:****@ak.internal:30449/pypi/pypi-torch/simple/, https://developer:****@ak.internal:30449/pypi/pypi-remote/simple/
...
No broken requirements found.
client: versions in localhost/ak-hf/workstation:latest
python                 3.12.16
huggingface_hub        2.4.0
transformers           5.22.1
sentence-transformers  6.2.0
torch                  2.15.0+cpu (cuda: False)
```

[`client/run.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/client/run.sh) runs it with `HF_ENDPOINT=https://ak.internal/huggingface/<repo>`
(`-r`), `HF_TOKEN` set to one of the tokens (`-t`), a home under `out/homes/` that holds the
client's cache (`-h`), and, for step 7, on the offline network (`-o`).
[`client/hfcheck.py`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-model-hub/client/hfcheck.py) runs the client calls the steps and gates use
(`download`, `snapshot`, `encode`, `automodel`, `save`) and prints one JSON line each.
