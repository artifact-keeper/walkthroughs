#!/usr/bin/env bash
# Build localhost/acme-analytics:<tag> from image/Containerfile, with the build
# host itself on the registry network.
#
# Rootless `podman build --network ak-conda-net` is refused ("setup network:
# cannot use networks as rootless"), so the build runs in a podman container
# (quay.io/podman/stable, pulled through the registry's quay.io proxy) that is
# attached to NETWORK. Inside it, `podman build --network host` gives every RUN
# step exactly that container's network: on ak-conda-net the registry and the
# internet; on build-isolated (internal: true) only https://ak.internal.
# Base images are pulled from ak.internal too (REGISTRY=ak.internal), with the
# internal CA in certs.d and the consumer token in an auth file. The token for
# pixi is a build secret. The result is saved as an OCI archive and loaded into
# the host's storage as localhost/acme-analytics:<tag>.
#
# Env: PROJECT (project | project-direct), NETWORK (ak-conda-net), TAG (1.0.0),
#      ATTESTATION_GATE (enforce | warn), NO_CACHE=1, BUILDER_VOLUME (builder storage), EXTRA_BUILD_ARGS, BUILDER_IMAGE
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/registry/lib.sh"; load_env
TAG="${TAG:-1.0.0}"
NETWORK="${NETWORK:-$NET}"
BUILDER_IMAGE="${BUILDER_IMAGE:-localhost:${HTTPS_PORT}/oci-quay/podman/stable:v5.8.7}"
W="$HERE/.work"; mkdir -p "$W/certs.d/$AK_HOST" "$W/out"
cp "$CA" "$W/ak-internal-ca.crt"; cp "$CA" "$W/certs.d/$AK_HOST/ca.crt"
cp "$ROOT/signing/keys/cosign.pub" "$W/conda-ci-cosign.pub"
# registry auth for the nested podman (base image pulls from ak.internal)
(umask 077; jq -n --arg h "$AK_HOST" --arg a "$(printf 'consumer:%s' "$(<"$TOKENS/consumer.token")" | base64 -w0)" \
   '{auths: {($h): {auth: $a}}}' > "$W/registry-auth.json")
[[ -f "$ROOT/client/.work/pixi-config.toml" ]] || "$ROOT/client/build.sh" >/dev/null
podman pull -q --cert-dir "$OUT/certs.d/localhost:${HTTPS_PORT}" --authfile "$TOKENS/consumer-podman.json" "$BUILDER_IMAGE" >/dev/null
args=(--network host --authfile /run/secrets/registry-auth.json
      --secret "id=rattler-auth,src=/run/secrets/rattler-auth.json"
      --build-arg "REGISTRY=$AK_HOST" --build-arg "ATTESTATION_GATE=${ATTESTATION_GATE:-enforce}" --build-arg "PROJECT=${PROJECT:-project}"
      -f /ctx/image/Containerfile -t "localhost/acme-analytics:$TAG")
[[ "${NO_CACHE:-0}" == 1 ]] && args+=(--no-cache)
# shellcheck disable=SC2206
args+=(${EXTRA_BUILD_ARGS:-})
echo "image: building on network $NETWORK: podman build ${args[*]} /ctx"
rm -f "$W/out/acme-analytics.oci.tar"
podman run --rm --privileged --network "$NETWORK" --device /dev/fuse \
  -v "${BUILDER_VOLUME:-ak-conda-builder-storage}:/var/lib/containers" \
  -v "$ROOT:/ctx:ro,z" \
  -v "$W/certs.d:/etc/containers/certs.d:ro,z" \
  -v "$W/registry-auth.json:/run/secrets/registry-auth.json:ro,z" \
  -v "$TOKENS/consumer-auth.json:/run/secrets/rattler-auth.json:ro,z" \
  -v "$W/out:/out:z" \
  "$BUILDER_IMAGE" sh -c "podman build $(printf '%q ' "${args[@]}") /ctx && \
     podman save --format oci-archive -o /out/acme-analytics.oci.tar localhost/acme-analytics:$TAG"
podman load -q -i "$W/out/acme-analytics.oci.tar" >/dev/null
podman tag "$(podman load -q -i "$W/out/acme-analytics.oci.tar" | awk '{print $NF}')" "localhost/acme-analytics:$TAG" 2>/dev/null || true
podman image inspect "localhost/acme-analytics:$TAG" --format 'image: localhost/acme-analytics:{{index .RepoTags 0}} {{.Id}} size={{.Size}}'
