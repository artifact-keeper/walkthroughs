# Step 3: Vet what you seeded

--8<-- "includes/preview-offgrid.md"

Still connected, the seeded content is checked before the site relies on it: the model goes
through a door that scans it, the vulnerability scanner gets a database it can use offline, and
the configuration and the inventory are written down as the records the site is compared
against later.

```bash
make vet    # flows/vet.sh
```

## The model, through the model-file scanner

[`flows/vet.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/flows/vet.sh)
downloads the model's files from `hf-hub`'s cache at the seeded commit, and publishes them to
`hf-models`, the vetted Local. There every upload is scanned, including by the model-file
scanner ([#5337](https://github.com/artifact-keeper/artifact-keeper/pull/5337)), and the policy
`hf-models-vetted` ([Step 1](1-stand-up-the-registry.md#the-vetting-policy)) serves a file only
once a scan has completed with nothing at or above medium:

```bash
POST /huggingface/hf-models/api/models/<repo_id>/upload/main     X-Filename: <file>   (publisher)
GET  /api/v1/security/artifacts/<id>/scans
```

```console
== 1a. the model from hf-hub's cache, at the seeded commit
  qwen2.5-1.5b-instruct-q4_k_m.gguf: 1117320736 bytes, sha256 6a1a2eb6d15622bf
  README.md: 4856 bytes, sha256 57c72d4010fb11a9

== 1b. publish it to hf-models (scan on upload, policy hf-models-vetted)
  upload Qwen/Qwen2.5-1.5B-Instruct-GGUF/qwen2.5-1.5b-instruct-q4_k_m.gguf: HTTP 200 {"path":"Qwen/Qwen2.5-1.5B-Instruct-GGUF/main/qwen2.5-1.5b-instruct-q4_k_m.gguf","size":1117320736}
  upload Qwen/Qwen2.5-1.5B-Instruct-GGUF/README.md: HTTP 200 {"path":"Qwen/Qwen2.5-1.5B-Instruct-GGUF/main/README.md","size":4856}
  qwen2.5-1.5b-instruct-q4_k_m.gguf scans: [{"scan_type":"grype","status":"running","findings_count":0},{"scan_type":"not_applicable","status":"not_applicable","findings_count":0},{"scan_type":"model","status":"completed","findings_count":0},{"scan_type":"dependency","status":"completed","findings_count":0}]
  findings: []
  HEAD hf-models .../resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf: HTTP 200, X-Repo-Commit a71c397e3525cbdb7147522bdd3561b918479c21
```

The `model` scan completed with no finding, and `hf-models` serves the file. Its commit in
`hf-models` (`a71c397e...`) is the Local repository's own, not the upstream one: the file is the
same (gate G1 compares the SHA-256 with the one the seed job recorded), its history is not.

### Two files that must not get through

Two counter-examples go through the same door, written by the script and never run:

- `acme-lab/truncated-gguf/model.gguf`: the first 4 MiB of the real GGUF. The header still
  claims every tensor; their data is gone.
- `acme-lab/backdoored/pytorch_model.bin`: a 31-byte protocol-2 pickle that imports
  `os.system` and calls it with `id`.

```console
== 1c. two files that must not get through
  acme-lab/truncated-gguf/model.gguf scans: [{"scan_type":"not_applicable","status":"not_applicable","findings_count":0},{"scan_type":"grype","status":"completed","findings_count":0},{"scan_type":"model","status":"completed","findings_count":1},{"scan_type":"dependency","status":"completed","findings_count":0}]
    findings: [{"severity":"medium","rule":"model.gguf.malformed","title":"GGUF header is malformed: file"}]
    GET .../resolve/main/model.gguf: HTTP 403
  acme-lab/backdoored/pytorch_model.bin scans: [{"scan_type":"not_applicable","status":"not_applicable","findings_count":0},{"scan_type":"grype","status":"completed","findings_count":0},{"scan_type":"model","status":"completed","findings_count":1},{"scan_type":"dependency","status":"completed","findings_count":0}]
    findings: [{"severity":"critical","rule":"model.pickle.dangerous-global","title":"Pickle imports a code-execution primitive: os.system"}]
    GET .../resolve/main/pytorch_model.bin: HTTP 403
```

<!-- REFRESH: this block is from a second make vet of the debug run (vet2.log), where the files were already uploaded. On the debug run's first make vet the two findings lines printed [] although findings_count was already 1; check that the final run's first make vet prints the findings. -->

grype and the dependency scanner find nothing in either file: they look for packages, and a
model file has none. The model-file scanner flags both, and the policy refuses both with `403`.

!!! warning "What the model-file scanner does not do"
    It reads structure: GGUF and safetensors headers, and the opcodes of a pickle, looking for
    imports of code-execution primitives. It caught a GGUF that does not hold together
    (`model.gguf.malformed`, medium) and a pickle that imports `os.system`
    (`model.pickle.dangerous-global`, critical). It does not judge what a model does: a
    well-formed GGUF with poisoned weights, a backdoor trigger or a bad chat template scans
    clean. A clean scan means "nothing known-bad in the file's structure", not "safe".

## The scanner adapter, offline

The scanner adapter runs Trivy for image scans. With `SCANNER_OFFLINE=true`
([#5314](https://github.com/artifact-keeper/artifact-keeper/pull/5314)) it never downloads a
database; it is not ready until one is imported. The trivy database was seeded through
`oci-ghcr` as an OCI artifact ([Step 2](2-seed-the-stack.md#1-images)); the script fetches its
layer through the registry and imports it with `PUT /api/v1/vulndb` on the adapter (from a
container on the stack's network, with the adapter's shared token):

```console
== 2. the scanner adapter, offline: import the trivy database through oci-ghcr
  oci-ghcr/aquasecurity/trivy-db:2: manifest HTTP 200, layer sha256:b9da5af18037c8a16530a9cd480a644fbef3335e5a4e7c52e1ead7d459f649dc (application/vnd.aquasec.trivy.db.layer.v1.tar+gzip)
  blob: HTTP 200, 138653337 bytes
  ready before the import: HTTP 503
  GET /api/v1/vulndb before: HTTP 404
...
  ready after the import: HTTP 200
```

<!-- REFRESH: from the debug run's first make vet, where the import output lines came out empty; the import line and the GET /api/v1/vulndb line below are from its second make vet (vet2.log). Paste the final run's block. -->

`GET /api/v1/vulndb` after the import:

```json
{"version":2,"updated_at":"2026-11-05T13:09:41.435406326Z","next_update":"2026-11-06T13:09:41.435405905Z","downloaded_at":"2026-11-05T17:42:13.193693971Z","age_seconds":16359,"stale":false,"offline":true}
```

`age_seconds` counts from the database's own `updated_at`, and it keeps growing on the site.
That is the number to watch: an offline scanner is only as current as the last database
carried in ([Next steps](next-steps.md#before-production)).

Then the adapter scans the llama.cpp image from the registry, the linux/amd64 manifest of the
seeded tag, reading it from the backend with the developer's token. No network beyond the
stack is involved:

```console
== 2b. the adapter scans the llama.cpp image from the registry (no network involved)
{"id":"0595b5af1351765c8293168541294856"}

  report: HTTP 200, ...
```

<!-- REFRESH: the debug run's report line printed raw text instead of {scanner, vulnerabilities}: the saved report (out/flows/adapter-report.txt) did not parse as JSON (gate G2 failed on it). The report itself was {"scanner":{"name":"Trivy","version":"0.76.0"},"vulnerabilities":[{"id":"CVE-2026-109518","package":"apt",...},...]}. Paste the final run's line. -->

The image has known vulnerabilities (the report starts with one in `apt`); listing them is the
point. The site decides what to do with them; this step shows that it can know, offline.

## The configuration of record

The whole configuration is exported as one document
([#5335](https://github.com/artifact-keeper/artifact-keeper/pull/5335)) to
`out/config/seed.json`, and planned against this same instance, which must change nothing:

```console
== 3. the configuration of record: export, then plan it against this instance
  GET /api/v1/admin/config/export: HTTP 200, 14 repositories
{"key":"hf-hub","repo_type":"remote","format":"huggingface","cache_ttl_seconds":315360000,"egress":"explicit"}
{"key":"hf-models","repo_type":"local","format":"huggingface","cache_ttl_seconds":null,"egress":null}
{"key":"ledger-control","repo_type":"remote","format":"pypi","cache_ttl_seconds":315360000,"egress":"explicit"}
{"key":"mcp-all","repo_type":"virtual","format":"mcp","cache_ttl_seconds":null,"egress":null}
{"key":"mcp-internal","repo_type":"local","format":"mcp","cache_ttl_seconds":null,"egress":null}
{"key":"mcp-official","repo_type":"remote","format":"mcp","cache_ttl_seconds":315360000,"egress":"explicit"}
{"key":"npm-remote","repo_type":"remote","format":"npm","cache_ttl_seconds":315360000,"egress":"explicit"}
{"key":"oci-dockerhub","repo_type":"remote","format":"docker","cache_ttl_seconds":315360000,"egress":"explicit"}
{"key":"oci-ghcr","repo_type":"remote","format":"docker","cache_ttl_seconds":315360000,"egress":"explicit"}
{"key":"plugins","repo_type":"remote","format":"agentplugins","cache_ttl_seconds":315360000,"egress":"explicit"}
{"key":"plugins-central","repo_type":"local","format":"agentplugins","cache_ttl_seconds":null,"egress":null}
{"key":"pypi","repo_type":"virtual","format":"pypi","cache_ttl_seconds":null,"egress":null}
{"key":"pypi-local","repo_type":"local","format":"pypi","cache_ttl_seconds":null,"egress":null}
{"key":"pypi-remote","repo_type":"remote","format":"pypi","cache_ttl_seconds":315360000,"egress":"explicit"}
  plan: HTTP 200 {"create":0,"update":[],"unchanged":14,"missing_secrets":[],"errors":[],"applicable":true}
```

<!-- REFRESH: the debug run had a fourteenth repository, ledger-control, from an earlier version of bootstrap.sh; the current code creates thirteen. Paste the final run's block. -->

The `plugins` Remote's upstream token is not in the document: it is exported as
`{"secret_ref": "upstream_auth/plugins"}`, to be supplied when the document is applied
elsewhere. This document is what a second instance would be built from
([Next steps](next-steps.md#two-instances-the-low-side-and-the-high-side)). One setting it does
not carry yet is the upstream mode ([Step 4](4-disconnect.md#3-the-export-and-what-it-leaves-out)).

## The inventory of record

Last, [`seed/inventory.sh seed`](https://github.com/artifact-keeper/walkthroughs/blob/main/off-grid-ai-stack/seed/inventory.sh)
fetches every manifest item as the developer, the way a client gets it, and writes its SHA-256
to `out/inventory/seed.tsv`. The Python rows come from `pip download --require-hashes --no-deps`
of the lock in a fresh container, so they are the exact wheels a clean install gets. The columns
are on [Seed manifest and inventory](reference/seed-manifest.md#the-inventory).

```console
== 4. the inventory of record: every manifest item as the registry serves it now
inventory: 85 items in out/inventory/seed.tsv
  image   4
  mcp     2
  MISSING 1
  model   4
  npm     2
  plugin  1
  python  72
```

<!-- REFRESH: debug run. MISSING 1 is io.github.daedalus/mcp-sqlite3@0.1.3, which the debug run never seeded (no #5408); the final run should have no MISSING line. -->

An excerpt (the 72 Python rows left out):

```text
image   oci-dockerhub/library/node:22-bookworm-slim@sha256:5ec23b7c...    5ec23b7c622b0054...   5218        oci-dockerhub HTTP 200
image   oci-dockerhub/library/python:3.12-slim-trixie@sha256:b18b261e...  b18b261e1b4974b4...   10373       oci-dockerhub HTTP 200
image   oci-ghcr/aquasecurity/trivy-db:2                                   681e7ce3da1709dc...   616         oci-ghcr HTTP 200
image   oci-ghcr/ggml-org/llama.cpp:server-b12124                          c0a11067c72bb1eb...   1419        oci-ghcr HTTP 200
mcp     com.acme/inventory@1.0.0                                           65c3134dc32b8a60...   516         mcp-all HTTP 200
mcp     io.github.daedalus/mcp-sqlite3@0.1.3                               -                     84          mcp-all HTTP 404
model   hf-hub:Qwen/Qwen2.5-1.5B-Instruct-GGUF/qwen2.5-1.5b-instruct-q4_k_m.gguf     6a1a2eb6d15622bf...  1117320736  hf-hub@91cad51170dc HTTP 200
model   hf-hub:Qwen/Qwen2.5-1.5B-Instruct-GGUF/README.md                             57c72d4010fb11a9...  4856        hf-hub@91cad51170dc HTTP 200
model   hf-models:Qwen/Qwen2.5-1.5B-Instruct-GGUF/qwen2.5-1.5b-instruct-q4_k_m.gguf  6a1a2eb6d15622bf...  1117320736  hf-models@main HTTP 200
model   hf-models:Qwen/Qwen2.5-1.5B-Instruct-GGUF/README.md                          57c72d4010fb11a9...  4856        hf-models@main HTTP 200
npm     @anthropic-ai/claude-code@2.1.318                                  d86c0189406af48b...   29472       npm-remote HTTP 200
npm     @anthropic-ai/claude-code-linux-x64@2.1.318                        2a4d5e3bd0f5bd29...   157335063   npm-remote HTTP 200
plugin  offgrid-ops@1.0.0                                                  6dbf8b77dcd390c8...   2503        plugins HTTP 200
```

<!-- REFRESH: debug run (tabs shown as spaces, hashes cut to 16 characters). The mcp-sqlite3 row should carry a hash in the final run. -->

The model appears twice on purpose: the copy in `hf-hub`'s cache at the upstream commit, and
the vetted copy in `hf-models`, with the same SHA-256.
