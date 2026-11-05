!!! warning "Preview: needs Artifact Keeper `main` (coming in 1.12.0)"
    The Hugging Face format is in released Artifact Keeper, but this walkthrough needs two fixes
    that are on `main` and not in a release yet: the HTTP Range fix that lets interrupted
    downloads resume ([#5145](https://github.com/artifact-keeper/artifact-keeper/issues/5145)),
    and `snapshot_download` from a hosted (Local) repository
    ([#5280](https://github.com/artifact-keeper/artifact-keeper/issues/5280), fixed by
    [#5300](https://github.com/artifact-keeper/artifact-keeper/pull/5300), `main` at
    `6c701cd4`). Both will ship in the next release, 1.12.0. The reference run used a backend
    built from the #5300 branch (`709e3f15`), the same code as `main` at `6c701cd4` for this
    format. On a release without them, gate G5 reports the hosted `snapshot_download` check
    `BLOCKED(ak-fix)`. Details may still change before 1.12.0.
