# image

- `Containerfile`: pixi builder -> attestation gate -> UBI micro runtime with a
  `pixi shell-hook` entrypoint. Base images from the registry, pinned by digest.
- `build.sh`: rootless `podman build` cannot join a named network, so the build runs in
  `quay.io/podman/stable` (through the registry) as a container on `NETWORK`
  (`ak-conda-net` or `build-isolated`) with `podman build --network host` inside. Env: `PROJECT`,
  `NETWORK`, `TAG`, `ATTESTATION_GATE` (`enforce`|`warn`), `BUILDER_VOLUME`, `NO_CACHE`.
- `verify-attestations.sh`: for every package in `pixi.lock` from the internal channel: download,
  compare sha256 with the lock, fetch the CEP-50 sidecar (`<url>.sigs`, falling back to
  `<url>/attestation`), check the in-toto statement binds this file, `cosign verify-blob --key`.
- `push.sh`: push to `oci-apps`, cosign-sign by digest, verify.
