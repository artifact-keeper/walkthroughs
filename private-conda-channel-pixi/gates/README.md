# gates

`run-all.sh [g01 ...]` runs the gates of the plan and prints one line per check:
`PASS`, `FAIL`, or `BLOCKED(Fn)` when the check needs an Artifact Keeper fix that the running
backend does not have. Results accumulate in `../out/gates/results.tsv`, logs in
`../out/gates/gNN.log`.

| Gate | Script |
|---|---|
| G1 auth, no credentials in manifests | `g01-auth.sh` |
| G2 publish, 409, subdir handling | `g02-publish.sh` |
| G3 registry-only resolve on `build-isolated`, download records | `g03-resolve.sh` |
| G4 dependency confusion | `g04-confusion.sh` (+ `fake-upstream.sh`) |
| G5 repodata formats, shards, `.tar.bz2` | `g05-formats.sh` |
| G6 proxy TTL, loud member failure | `g06-freshness.sh` |
| G7 promotion gate | `g07-promotion.sh` |
| G8 attestations, the image build's gate | `g08-attestations.sh` |
| G9 trust policy | `g09-trust-policy.sh` |
| G10 cooldown, `indexed_timestamp` | `g10-cooldown.sh` (+ `backdate-conda.sh`) |
| G11 SBOM and blast radius | `g11-sbom.sh` |
| G12 offline, second mirror, flipped byte | `g12-offline.sh` |
| G13 image from the registry only, signed, runs | `g13-image.sh` |

`token-matrix.sh` prints which credential can read which repository.
Gates create scratch repositories (`conda-gate-*`, `conda-fake-upstream`, ...) and leave the demo
channels alone, except G7 which publishes negative-test packages to `conda-staging`.
