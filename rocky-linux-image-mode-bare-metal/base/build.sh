#!/usr/bin/env bash
# Build the Rocky Linux 10 bootc base image from the vendored RESF recipe with
# ROOTLESS podman, dnf pointed only at Artifact Keeper (gpgcheck=1, repo_gpgcheck=1),
# then lint, push and cosign-sign by digest:
#   localhost:30080/oci-bootc/rocky-bootc-base:10
#   localhost:30080/oci-bootc/rocky-bootc-base:10-<YYYYMMDD>   (immutable tag, image build date UTC)
#
# Env: MANIFEST (minimal|standard, default minimal), PUSH (1|0, default 1),
#      REBUILD (1 = rebuild even if localhost/rocky-bootc-base:10 exists, default 0),
#      AK (registry host:port as seen from this host, default localhost:30080),
#      CTR_HOST (registry host as seen from a build container, default host.containers.internal)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AK="${AK:-localhost:30080}"
CTR_HOST="${CTR_HOST:-host.containers.internal}"
MANIFEST="${MANIFEST:-minimal}"
PUSH="${PUSH:-1}"
IMG="$AK/oci-bootc/rocky-bootc-base"
LOCAL="localhost/rocky-bootc-base:10"
REPO_IN="$ROOT/registry/out/edge.repo.in"
CTX="$HERE/.work/ctx"
log() { echo "base: $*"; }

[[ -f "$REPO_IN" ]] || { echo "base/build.sh: $REPO_IN missing; run registry/bootstrap.sh" >&2; exit 1; }

# 1. Staging context: pristine upstream + our Containerfile + AK-only repo file.
mkdir -p "$CTX"
rsync -a --delete --exclude out.ociarchive "$HERE/upstream/rocky-bootc/" "$CTX/"
cp "$HERE/Containerfile" "$CTX/Containerfile"
# Only the Rocky BaseOS/AppStream/extras proxies go into the base build.
awk -v host="$CTR_HOST" '
  /^\[/ { keep = ($0 ~ /^\[rpm-rocky10-/) }
  keep  { gsub(/@HOST@/, host); print }
  keep && /^metadata_expire/ { print "" }' "$REPO_IN" > "$CTX/ak-rocky.repo"
if grep -E '^(baseurl|mirrorlist|metalink)=' "$CTX/ak-rocky.repo" | grep -v ":30080/rpm/" \
   || grep -E '^gpgkey=' "$CTX/ak-rocky.repo" | tr ' ' '\n' | grep -E '^(gpgkey=)?https?://' | grep -v ':30080/' ; then
  echo "base/build.sh: non-Artifact-Keeper URL in ak-rocky.repo" >&2; exit 1
fi
rm -f "$CTX/out.ociarchive"

# 2. Build (rootless). FROM oci-archive:./out.ociarchive is resolved relative to
#    the CWD, so build from inside the context directory. --no-cache is required:
#    the final stage deletes out.ociarchive, so a cached builder stage would leave
#    the second stage with nothing to FROM.
if [[ "${REBUILD:-0}" != 1 ]] && podman image exists "$LOCAL"; then
  log "$LOCAL exists (REBUILD=1 to force), skipping build"
else
log "building $LOCAL (MANIFEST=$MANIFEST)"
start=$(date +%s)
( cd "$CTX" && podman build --no-cache \
    --tls-verify=false \
    --security-opt=label=disable --cap-add=all --device /dev/fuse \
    -v "$CTX:/buildcontext" \
    --build-arg MANIFEST="$MANIFEST" \
    --build-arg BUILDER_IMAGE="$AK/oci-quay-proxy/rockylinux/rockylinux:10" \
    -t "$LOCAL" -f Containerfile . )
log "build took $(( $(date +%s) - start ))s"
fi

# 3. Lint inside the produced image.
podman run --rm "$LOCAL" bootc container lint
podman run --rm "$LOCAL" sh -c 'cat /etc/rocky-release; bootc --version; rpm -q kernel'

# 4. Push (floating + immutable date tag). Uses registry/.ak-token.
if [[ "$PUSH" == 1 ]]; then
  # Immutable tag = build date of the local image (not today's date), so a re-push
  # of an old build never mints a misleading new date tag.
  DATE_TAG="10-$(podman image inspect "$LOCAL" --format '{{.Created.UTC.Format "20060102"}}')"
  podman login --tls-verify=false -u admin --password-stdin "$AK" < "$ROOT/registry/.ak-token" >/dev/null
  # --remove-signatures: once image/build.sh has pulled the base through the signature
  # policy, the local image carries the sigstore signatures it was verified with, and a
  # push from containers-storage (which recompresses layers) refuses with
  # "Would invalidate signatures". The digest is re-signed below anyway.
  podman push --remove-signatures --tls-verify=false "$LOCAL" "docker://$IMG:$DATE_TAG"
  # skopeo reuses podman's auth file from the login above.
  skopeo copy --src-tls-verify=false --dest-tls-verify=false \
    "docker://$IMG:$DATE_TAG" "docker://$IMG:10"
  digest=$(skopeo inspect --no-creds --tls-verify=false "docker://$IMG:10" | jq -r .Digest)
  log "pushed $IMG:10 and $IMG:$DATE_TAG ($digest)"
  # 5. Sign by digest (covers both tags). image/build.sh pulls the base through a
  #    policy.json that requires this signature (image/setup-host.sh).
  "$ROOT/signing/sign-image.sh" "$IMG:10"
fi
