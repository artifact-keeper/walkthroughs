# Step 6: Scan and hold

--8<-- "includes/preview-hf.md"

New model files should not be usable the moment they are uploaded. `hf-staging` is a Local
repository where every new file is held until a scan clears it or a reviewer releases it, and a
scan policy refuses anything no scanner has finished. This step also shows the limit of that:
nothing in Artifact Keeper reads a model file, so a malicious pickle passes.

```bash
make hold    # flows/hold.sh
```

## The repository

```bash
POST  /api/v1/repositories              {"key": "hf-staging", "format": "huggingface", "repo_type": "local", "visibility": "private"}
PATCH /api/v1/repositories/hf-staging   {"quarantine_enabled": true, "quarantine_duration_minutes": 1440}
PUT   /api/v1/repositories/hf-staging/security   {"scan_enabled": true, "scan_on_upload": true}
POST  /api/v1/security/policies         {"name": "hf-staging-scanned", "repository_id": "<hf-staging>",
                                         "max_severity": "high", "block_unscanned": true, "block_on_fail": true}
```

The quarantine settings go in a `PATCH`: the create request accepts them without an error and
ignores them ([findings D5](findings.md#documentation-gaps)).

| Control | What it does to a download |
|---|---|
| Upload hold (quarantine, 24 h) | 409 until the file's scan comes back clean, a reviewer releases it, or 24 h pass |
| Scan on upload | grype and the dependency scanner run on every new file; a clean result ends the hold, findings reject the file |
| Scan policy `block_unscanned` | 403 while no scan of the file has completed |
| Scan policy `max_severity: high` | 403 for a file with a high or critical finding |
| Reviewer: hold, release, reject | 409 / served / 403, through `POST /api/v1/quarantine/<artifact>/{quarantine,release,reject}` |

## A model file

```console
== a model file: held on upload until its scan completes (here: well under a second)
upload model.safetensors: HTTP 200
  GET model.safetensors: HTTP 200
  scans: [{"scan_type":"openscap","status":"not_applicable","findings_count":0},{"scan_type":"grype","status":"completed","findings_count":0},{"scan_type":"dependency","status":"completed","findings_count":0}]
  quarantine: {"quarantine_status":"clean","quarantine_until":null,"is_blocked":false}
  GET model.safetensors: HTTP 200
```

The scan of a 64 KB file finished before the first download asked, so the hold was already
over. On a large file the hold lasts as long as its scan.

## A malicious pickle

`pytorch_model.bin` here is a pickle whose load (`torch.load(..., weights_only=False)`) runs a
shell command, the classic malicious-checkpoint shape. It is built as bytes and never unpickled:

```console
== a pickle checkpoint whose load runs a shell command: held, scanned, found clean, released
upload pytorch_model.bin: HTTP 200
  GET pytorch_model.bin: HTTP 200
  scans: [{"scan_type":"openscap","status":"not_applicable","findings_count":0},{"scan_type":"grype","status":"completed","findings_count":0},{"scan_type":"dependency","status":"completed","findings_count":0}]
  quarantine: {"quarantine_status":"clean","quarantine_until":null,"is_blocked":false}
  GET pytorch_model.bin: HTTP 200
```

Both scanners "complete" with no findings, because neither reads pickle, safetensors or GGUF, and
the clean result ends the hold. **The scan does not protect you from a model file.** A model-file
scanner is [artifact-keeper#5285](https://github.com/artifact-keeper/artifact-keeper/issues/5285)
(and #3013, #2382); gate G6 reports this check `BLOCKED(ak-gap)`. Until then: accept
safetensors only, load with `weights_only=True` (the torch default since 2.6), and use the
reviewer's controls below for anything else.

## A reviewer holds and rejects

```console
== a reviewer holds it, then rejects it
{"new_status":"quarantined"}
  GET pytorch_model.bin: HTTP 409 CONFLICT
{"new_status":"rejected"}
  GET pytorch_model.bin: HTTP 403 FORBIDDEN
```

A rejection is only allowed from the held state, hence the hold first. A held file is refused
on `HEAD` too, so `hf_hub_download` fails before it downloads anything.

## block_unscanned

With scan on upload switched off, the hold lasts until a person releases the file, and the
policy still refuses it until a scan has run:

```console
== scan on upload off: the hold lasts until a reviewer releases the file; block_unscanned then refuses it until a scan completes
{"scan_on_upload":false}
upload config.json: HTTP 200
  GET config.json: HTTP 409 CONFLICT
{"new_status":"released"}
  GET config.json: HTTP 403 FORBIDDEN
{"message":"Scan queued for artifact c3d78502-6e5f-47b4-a090-3a4abe9385ec"}
  scans: [...,{"scan_type":"grype","status":"completed","findings_count":0},...]
  GET config.json: HTTP 200
{"scan_on_upload":true}
```

Held is 409, refused by a decision (rejection or policy) is 403. In the web UI, the staging
repository lists both held and rejected files with a "Quarantined" badge
([Results](results.md#the-web-ui)).
