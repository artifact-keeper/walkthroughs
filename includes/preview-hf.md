!!! warning "Preview: runs `main`, and needs the hosted snapshot_download fix (artifact-keeper#5280)"
    The Hugging Face format is in released Artifact Keeper, but this walkthrough runs `main`
    (`ghcr.io/artifact-keeper/artifact-keeper-backend:dev`, commit `46070a04`) for the HTTP Range
    fix that lets interrupted downloads resume
    ([#5145](https://github.com/artifact-keeper/artifact-keeper/issues/5145); not in 1.11.11,
    expected in 1.12.0). `snapshot_download` from a hosted (Local) repository also needs
    [artifact-keeper#5280](https://github.com/artifact-keeper/artifact-keeper/issues/5280), which
    is not merged yet: until an image carries it, gate G5 reports that one check as
    `BLOCKED(ak-fix)` and Step 5 shows the failure. Details may still change before 1.12.0.
