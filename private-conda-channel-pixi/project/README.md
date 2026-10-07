# project (one virtual channel)

The consumer as designed: `https://ak.internal/conda/conda-virtual` is the channel, internal
packages are pinned to `conda-internal`, strict priority, a 14-day cooldown for public packages,
one PyPI dependency through `pypi-remote`. Needs the 1.11.0 virtual-channel fixes (F1-F3); on
Artifact Keeper main use `../project-direct/`.

`pixi-run.sh <pixi args>` runs pixi for this directory in the client container (env: `NETWORK`,
`CACHE_VOLUME`, `AUTH_FILE`, `EXTRA_PODMAN_ARGS`). Example: `./pixi-run.sh lock`,
`NETWORK=build-isolated ./pixi-run.sh install --locked`.
