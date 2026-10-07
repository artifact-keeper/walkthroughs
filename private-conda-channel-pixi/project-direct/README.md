# project-direct (internal channel + conda-forge mirror)

The same project with `channels = [conda-internal, conda-forge]`. conda-forge is written by its
canonical URL; the client's `/etc/pixi/config.toml` mirrors it to the registry, so `pixi.lock`
records `conda.anaconda.org` URLs while every byte comes from `ak.internal`. Works on Artifact
Keeper main. `pixi-run.sh` is the same helper as in `../project/`.
