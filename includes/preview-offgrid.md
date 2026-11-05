!!! warning "Preview: needs Artifact Keeper `main` (coming in 1.12.0)"
    This walkthrough uses features that are on Artifact Keeper `main` and not in a release yet:
    cache-only Remotes ([#5315](https://github.com/artifact-keeper/artifact-keeper/pull/5315)),
    the `UPSTREAM_FETCHED` audit event ([#5316](https://github.com/artifact-keeper/artifact-keeper/pull/5316)),
    the switch that pauses scheduled upstream jobs ([#5317](https://github.com/artifact-keeper/artifact-keeper/pull/5317)),
    the scanner adapter's offline mode ([#5314](https://github.com/artifact-keeper/artifact-keeper/pull/5314)),
    cache seeding ([#5333](https://github.com/artifact-keeper/artifact-keeper/pull/5333)),
    the agentplugins Remote ([#5334](https://github.com/artifact-keeper/artifact-keeper/pull/5334)),
    config export ([#5335](https://github.com/artifact-keeper/artifact-keeper/pull/5335)),
    the model-file scanner ([#5337](https://github.com/artifact-keeper/artifact-keeper/pull/5337))
    and commit-pinned Hugging Face paths ([#5313](https://github.com/artifact-keeper/artifact-keeper/pull/5313)).
    They ship in 1.12.0. The reference run used a build of `main` at `f0d9b638`. Details may
    still change before the release.
