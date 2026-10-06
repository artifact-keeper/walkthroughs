#!/usr/bin/env bash
# Build the edge image for one edge-site-config release, verify it, smoke-test it.
#   SITE_RELEASE=3 image/build.sh   -> localhost/rocky-edge:<osver>-3
#   SITE_RELEASE=4 image/build.sh   -> localhost/rocky-edge:<osver>-4
#   SITE_RELEASE=4 LOCAL_TAG=unsigned-test EXTRA_LABEL=edge.test=unsigned image/build.sh
#                                   -> localhost/rocky-edge:unsigned-test (negative tests)
# <osver> is VERSION_ID of the base image (10.2 today). Pushing+signing is image/push.sh.
# The base is pulled through the build-host policy (image/setup-host.sh), so an
# unsigned or wrongly signed base fails here. dnf runs with gpgcheck=1/repo_gpgcheck=1.
# The node-side signature policy (rootfs/etc/containers/{policy.json,registries.d})
# needs the cosign public key, copied in from signing/keys/pub.
# Env: SITE_RELEASE (default 3), LOCAL_TAG, EXTRA_LABEL, AK (default localhost:30080),
#      CTR_HOST (registry host seen from podman build, default host.containers.internal),
#      VM_HOST (registry host seen from the edge node, default 10.0.2.2)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AK="${AK:-localhost:30080}"
CTR_HOST="${CTR_HOST:-host.containers.internal}"
VM_HOST="${VM_HOST:-10.0.2.2}"
SITE_RELEASE="${SITE_RELEASE:-3}"
BASE="$AK/oci-bootc/rocky-bootc-base:10"
REPO_IN="$ROOT/registry/out/edge.repo.in"
WORK="$HERE/.work"
log() { echo "image: $*"; }
[[ -f "$REPO_IN" ]] || { echo "image/build.sh: $REPO_IN missing; run registry/bootstrap.sh" >&2; exit 1; }

"$HERE/setup-host.sh" >/dev/null
mkdir -p "$WORK"
sed "s/@HOST@/$CTR_HOST/g" "$REPO_IN" > "$WORK/build.repo"
sed "s/@HOST@/$VM_HOST/g"  "$REPO_IN" > "$WORK/edge.repo"
cp "$HERE/Containerfile" "$WORK/Containerfile"
rm -rf "$WORK/rootfs"; cp -r "$HERE/rootfs" "$WORK/rootfs"
PUBKEY="$ROOT/signing/keys/pub/edge-cosign.pub"
[[ -s "$PUBKEY" ]] || { echo "image/build.sh: $PUBKEY missing; run signing/gen-keys.sh (make keys)" >&2; exit 1; }
install -D -m 0644 "$PUBKEY" "$WORK/rootfs/etc/pki/containers/edge-cosign.pub"

# Pull (and thereby signature-check) the base. No --tls-verify=false needed or wanted:
# setup-host.sh marks the registry insecure, and the policy demands a cosign signature.
podman pull -q "$BASE" >/dev/null
OSVER="${OSVER:-$(podman run --rm "$BASE" sh -c '. /usr/lib/os-release; echo "$VERSION_ID"')}"
LOCAL="localhost/rocky-edge:${LOCAL_TAG:-$OSVER-$SITE_RELEASE}"
label=(); [[ -n "${EXTRA_LABEL:-}" ]] && label=(--label "$EXTRA_LABEL")

log "building $LOCAL from $BASE (edge-site-config release $SITE_RELEASE)"
start=$(date +%s)
podman build --pull=never "${label[@]}" \
  --build-arg BASE_IMAGE="$BASE" --build-arg SITE_RELEASE="$SITE_RELEASE" --build-arg OSVER="$OSVER" \
  -t "$LOCAL" -f "$WORK/Containerfile" "$WORK"
log "build took $(( $(date +%s) - start ))s"

# Only-Artifact-Keeper property, checked again from outside the build.
# gpgkey= URLs count too: every key is fetched from Artifact Keeper or is a local file://.
bad=$(podman run --rm "$LOCAL" sh -c "grep -rhE '^[[:space:]]*(baseurl|mirrorlist|metalink|gpgkey)[[:space:]]*=' /etc/yum.repos.d/ \
        | sed 's/^[^=]*=//' | tr ' ,' '\n\n' | grep -E '^[a-z]+://' | grep -v -e ':30080/' -e '^file:///etc/pki/rpm-gpg/' || true")
[[ -z "$bad" ]] || { echo "image/build.sh: non-Artifact-Keeper repo URLs in $LOCAL: $bad" >&2; exit 1; }
nogpg=$(podman run --rm "$LOCAL" sh -c "grep -rhE '^gpgcheck[[:space:]]*=[[:space:]]*0' /etc/yum.repos.d/ || true")
[[ -z "$nogpg" ]] || { echo "image/build.sh: gpgcheck=0 in $LOCAL" >&2; exit 1; }
log "repo check OK: /etc/yum.repos.d contains only :30080 / file:// URLs and no gpgcheck=0"

# Smoke test as a plain container.
podman run --rm "$LOCAL" bash -euo pipefail -c '
  rpm -q rke2-server rke2-selinux edge-site-config kernel kernel-modules-extra NetworkManager openssh-server bubblewrap
  test -x /usr/bin/bwrap
  grep -q "^d /var/log/journal " /usr/lib/tmpfiles.d/50-edge-image.conf
  bootc --version
  ls -l /usr/lib/systemd/system/rke2-server.service
  for u in rke2-server NetworkManager sshd edge-site-manifests; do printf "%s: " "$u"; systemctl is-enabled "$u"; done
  cat /etc/motd.d/edge
  cat /usr/lib/bootc/kargs.d/*.toml | grep ^kargs
  test ! -e /run/k3s
  test "$(readlink /opt)" = var/opt && test "$(readlink /usr/local)" = /var/usrlocal
  grep -h -E "^d /var/(opt|usrlocal)" /usr/lib/tmpfiles.d/*.conf
  # signature policy for bootc upgrade (node side)
  test -s /etc/pki/containers/edge-cosign.pub
  grep -q "\"type\": \"reject\"" /etc/containers/policy.json
  grep -q "/etc/pki/containers/edge-cosign.pub" /etc/containers/policy.json
  grep -q "use-sigstore-attachments: true" /etc/containers/registries.d/ak-oci-bootc.yaml
  rpm -q gpg-pubkey --qf "%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n"
  bootc container lint --fatal-warnings'
podman image inspect "$LOCAL" --format 'image: {{.Id}} size={{.Size}} layers={{len .RootFS.Layers}}'
log "built and verified $LOCAL"
