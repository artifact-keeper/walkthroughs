# Results

Run from an empty registry with `make all`, then `make gates`, on Artifact Keeper 1.11.0 (the fix
branch built for this walkthrough) and the pixi 0.81.0 client image.

## The gates

| Gate | Checks | Result |
|---|---|---|
| G1 Auth | header auth from file and from `pixi auth login`; 401 without; no credentials in manifest or lock; token-in-URL in both layouts | all pass |
| G2 Publish | PUT 201; re-upload 409; subdir validated against `index.json` | all pass |
| G3 Resolve | isolated network reaches only `ak.internal`; the virtual-channel project locks and installs cold; downloads via the registry | pass; proxy downloads not in the audit (known gap) |
| G4 Confusion | virtual channel offers only the hosted name; unpinned and pinned solves keep 1.0.0 | all pass |
| G5 Formats | json, zst, bz2 agree; `.conda` and `.tar.bz2`; hosted shards consumed; proxy falls back to zst | all pass |
| G6 Freshness | new upstream package visible within the TTL; broken member returns 502; virtual merges 790,178 conda-forge records | all pass |
| G7 Promotion | vulnerable, GPL and un-attested packages refused with reasons; attested clean package promotes with metadata and attestation intact | all pass |
| G8 Attestations | sidecars served; `attestations_sha256` in repodata; build gate passes signed, fails flipped byte, re-locked tamper, wrong key, unsigned | all pass |
| G9 Trust policy | trusted key 201; wrong key 400 | all pass |
| G10 Cooldown | `indexed_timestamp` present; `exclude-newer` excludes a fresh package | pass; backdated package slips through (pixi limitation) |
| G11 SBOM | 44 components from the lock; Syft and Grype on the image; PURL lookup with inclusion path | all pass |
| G12 Offline | frozen offline install; second mirror; flipped byte caught | all pass |
| G13 Image | cold build on the isolated network; signed; verified; runs with no network | all pass |
| G14 Allowlist | repodata (three encodings) and channeldata carry only the lock's conda-forge packages plus hosted ones; a package outside the lock is 404 and not found by pixi; the project installs; off restores the merge | all pass |

## Timings

| Step | Time |
|---|---|
| Registry cold start, pulls included | about 90 s |
| First `pixi exec rattler-build --version` through the registry | 9 s |
| Build three internal packages, warm cache | 23 s |
| `pixi install --locked`, 44 packages, cold cache, isolated network | 1 to 4 s |
| Container build, cold builder, isolated network | 190 to 230 s |
| Hosted scan of one conda package | under 30 s |
| `conda-virtual` linux-64 repodata, 790,178 records, zstd | about 4 s |
| Full gate run | about 10 min |
| `make all` from an empty registry | 14 min 6 s |

## What changed in Artifact Keeper for this

The walkthrough was built against `main` first, and every blocked check became a fix. All of them
ship in 1.11.0:

- Virtual conda channels: hosted members own their package names; members fetched compressed and
  capped, hosted first; a failed member fails the request (with an opt-in degraded mode).
- CEP-16 shard index and shards served with correct encoding, consumable by rattler.
- CEP-50 attestation sidecars and `attestations_sha256` in repodata; attestation reads follow
  repository read access.
- A configurable attestation trust policy: OIDC issuers and identities, and key-based Sigstore
  bundles with no transparency log, with `GET /api/v1/attestations/policy`.
- A verified attestation satisfies `min_attestation_state` and the promotion signature gate;
  promotion responses list every evaluated rule as `gate_results`, for single and bulk promotion.
- Upload validates the subdir against `index.json`; promotion copies the package metadata and
  the attestation; a staging upload's origin is recorded as hosted.
- `indexed_timestamp` on every hosted record (CEP-47).
- rattler's `/t/<token>/conda/<repo>/` URL layout accepted; the `unknown` subdir returns an empty
  index; authenticated responses are `Cache-Control: private`; `/v2/token` has its own rate-limit
  bucket; duplicate scan-policy names are refused.

And in the web UI: subdir and build columns, an attestation panel on the package, per-rule
promotion results, withdrawn state with the channel notice, an Environments tab with PURL lookup,
the trust-policy card, hosted-versus-remote member types with the ownership rule, and a download
audit deep link.

The [lab notes](findings.md) have the before-and-after table, every command, and the exact error
messages.
