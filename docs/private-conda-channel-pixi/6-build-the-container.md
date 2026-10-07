# Step 6: Build the container on an isolated network

The application image follows the pixi-on-UBI-micro pattern: a builder stage runs
`pixi install --locked`, then only the environment is copied into a UBI micro runtime that has no
package manager and no pixi binary. The walkthrough adds three things: the build pulls everything
through the registry, it verifies every package's attestation before anything is linked, and it
runs on a network with no internet so the first two are provable.

[`image/Containerfile`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-conda-channel-pixi/image/Containerfile),
abridged:

```dockerfile
FROM ak.internal/oci-ghcr/prefix-dev/pixi:0.81.0@sha256:788ae451... AS builder
COPY ca/ak-internal-ca.crt /usr/local/share/ca-certificates/
COPY client/pixi-config.toml /etc/pixi/config.toml
COPY client/rattler-config.toml /etc/rattler/config.toml
COPY signing/keys/pub/cosign.pub /etc/acme/conda-ci-cosign.pub
WORKDIR /app
COPY pixi.toml pixi.lock ./
RUN --mount=type=secret,id=rattler-auth,target=/run/secrets/rattler-auth.json \
    --mount=type=cache,target=/root/.cache/rattler \
    RATTLER_AUTH_FILE=/run/secrets/rattler-auth.json pixi install --locked
RUN --mount=type=secret,id=rattler-auth,target=/run/secrets/rattler-auth.json \
    RATTLER_AUTH_FILE=/run/secrets/rattler-auth.json \
    pixi exec -s cosign -s jq -s curl -s bash -- bash verify-attestations.sh /app/pixi.lock
RUN pixi shell-hook --locked -s bash > /app/activate.sh

FROM ak.internal/oci-redhat/ubi9/ubi-micro:9.8@sha256:7a0454cb...
COPY --from=builder /app /app
USER 1001
ENTRYPOINT ["/bin/bash", "/app/activate.sh"]
CMD ["acme-report"]
```

- Both base images come through the registry's proxies, pinned by the **upstream index digest**.
  The proxy serves the index unchanged, so the digest you pin is the one on ghcr.io or
  registry.access.redhat.com, and `skopeo inspect --raw` through the registry hashes to the same
  value. (podman records the per-platform manifest digest after a pull, which differs; pin the
  index.)
- The token is a build secret mounted only for the steps that need it, never a layer.
- `verify-attestations.sh` is the gate ([Step 7](7-verify-attestations.md)). It fails the build,
  and the build fails if the attestation check cannot run.
- The runtime is the environment plus an activation script; `pixi shell-hook` writes it so the
  final image needs no pixi.

## Rootless podman and named networks

`podman build --network ak-conda-net` is refused in rootless mode ("cannot use networks as
rootless"); it accepts `none`, `host`, `private` and namespace paths, not a user-defined network.
[`image/build.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-conda-channel-pixi/image/build.sh)
therefore runs the build inside a podman container (`quay.io/podman/stable`, pulled through the
registry) that *is* on the target network, with `--network host` inside, so every `RUN` step gets
that container's network. The base images are pulled from `ak.internal` by the nested podman, and
the result is saved as an OCI archive and loaded on the host. On a real CI runner you would attach
the runner to the network and skip the nesting.

On `build-isolated`, from a cold builder with no layer or package cache, the build takes 190 to
230 seconds. Every `FROM`, every conda package, the PyPI wheel, and the cosign, jq and curl tools
used by the gate were fetched from `ak.internal`, because nothing else was reachable.

## Sign and push

[`image/push.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-conda-channel-pixi/image/push.sh)
pushes to `oci-apps/acme-analytics:1.0.0` with the repository token, signs the digest with cosign
(`--use-signing-config=false --tlog-upload=false`, the same key family as the packages), and
verifies. The image is 436 MB uncompressed and runs with `--network none`:

```console
$ podman run --rm --network none localhost/acme-analytics:1.0.0
┏━━━━━━━━┳━━━━━━━━┓
┃ column ┃   mean ┃
┡━━━━━━━━╇━━━━━━━━┩
│ sales  │ 119.33 │
└────────┴────────┘
```

A note for CI: pushing, signing and verifying an image exchanges several tokens at `/v2/token`.
Before 1.11.0 that endpoint shared the login rate limit (10 per 15 minutes per user and source
address), and one push-sign-verify from a runner behind NAT could hit 429. It has its own, higher
bucket now (`RATE_LIMIT_TOKEN_EXCHANGE_PER_WINDOW`).

Next: [Step 7, verify attestations](7-verify-attestations.md).
