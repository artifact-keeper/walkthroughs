# packages

| Script | What |
|---|---|
| `build.sh [recipe...]` | rattler-build in the client container on `ak-conda-net`; every dependency through the registry. Env: `ACME_CORE_VERSION`, `OUT_DIR`, `RECIPES_DIR`, `EXTRA_ARGS`, `SOURCE_DATE_EPOCH`, `NETWORK` |
| `publish.sh [subdir/file...]` | `rattler-build upload artifactory` to `conda-staging` with the CI token |
| `attest.sh [file...]` | CEP-27 Statement v1, `cosign attest-blob --statement`, PUT to `<file>/attestation`. Env: `REPO`, `KEY_DIR`, `UPLOAD=0` |
| `scan.sh [repo]` | trigger the registry's scans and wait for them |
| `promote.sh [filter...]` | promote staging -> `conda-internal` through the release gate, printing every violation |
| `seed-internal-main.sh` | WORKAROUND for Artifact Keeper main only (promotion loses metadata, attestations cannot be stored) |

`recipes/`: `acme-core` (noarch python), `acme-fastmath` (linux-64, C), `acme-report` (noarch,
depends on acme-core, pandas, rich). `recipes-negative/`: packages the release gate must refuse.
