!!! warning "Preview: needs the hosted snapshot_download fix (artifact-keeper#5300)"
    The Hugging Face format is in released Artifact Keeper, but this walkthrough needs two fixes
    that are not in a release: the HTTP Range fix that lets interrupted downloads resume
    ([#5145](https://github.com/artifact-keeper/artifact-keeper/issues/5145), on `main`), and
    `snapshot_download` from a hosted (Local) repository, pull request
    [artifact-keeper#5300](https://github.com/artifact-keeper/artifact-keeper/pull/5300)
    (issue [#5280](https://github.com/artifact-keeper/artifact-keeper/issues/5280)), not merged
    yet. Until it is, the walkthrough runs a backend built from that branch (`709e3f15`, `main`
    at `46070a04` plus the fix). With the `:dev` image everything else runs, and gate G5 reports
    the hosted `snapshot_download` check `BLOCKED(ak-fix)`. Details may still change before
    1.12.0.
