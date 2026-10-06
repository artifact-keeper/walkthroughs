#!/usr/bin/env bash
# Build edge-site-config-1.0-{3,4} with rpmbuild inside a rootless Rocky 10
# container, sign each RPM with the edge RPM GPG key (rpmsign --addsign) and
# require `rpm -K` to report "digests signatures OK". The container image comes
# through the Artifact Keeper quay.io proxy and its dnf uses only the Artifact
# Keeper Rocky proxies (gpgcheck=1, repo_gpgcheck=1).
# The signing keyring (signing/keys/gnupg, from signing/gen-keys.sh) is mounted
# read-only and copied into a throwaway GNUPGHOME inside the container, because
# gpg needs a writable homedir for its agent socket.
# Output: rpms/out/*.rpm
# Env: RELEASES (default "3 4"), AK (default localhost:30080),
#      CTR_HOST (default host.containers.internal)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AK="${AK:-localhost:30080}"
CTR_HOST="${CTR_HOST:-host.containers.internal}"
RELEASES="${RELEASES:-3 4}"
BUILDER="$AK/oci-quay-proxy/rockylinux/rockylinux:10"
REPO_IN="$ROOT/registry/out/edge.repo.in"
OUT="$HERE/out"
WORK="$HERE/.work"
KEYS="$ROOT/signing/keys"
[[ -f "$REPO_IN" ]] || { echo "rpms/build.sh: $REPO_IN missing; run registry/bootstrap.sh" >&2; exit 1; }
[[ -d "$KEYS/gnupg" && -s "$KEYS/pub/RPM-GPG-KEY-edge" ]] || { echo "rpms/build.sh: no RPM signing key; run signing/gen-keys.sh (make keys)" >&2; exit 1; }
GPG_NAME="${GPG_NAME:-$(cat "$KEYS/pub/RPM-GPG-KEY-edge.fingerprint")}"

mkdir -p "$OUT" "$WORK"
sed "s/@HOST@/$CTR_HOST/g" "$REPO_IN" > "$WORK/edge.repo"

podman pull -q --tls-verify=false "$BUILDER" >/dev/null
start=$(date +%s)
podman run --rm --security-opt label=disable \
  -v "$HERE/edge-site-config:/src:ro" -v "$OUT:/out" -v "$WORK/edge.repo:/tmp/edge.repo:ro" \
  -v "$KEYS/gnupg:/keys/gnupg:ro" -v "$KEYS/pub/RPM-GPG-KEY-edge:/keys/RPM-GPG-KEY-edge:ro" \
  -e RELEASES="$RELEASES" -e GPG_NAME="$GPG_NAME" "$BUILDER" bash -euo pipefail -c '
    rm -f /etc/yum.repos.d/*.repo
    cp /tmp/edge.repo /etc/yum.repos.d/edge.repo
    dnf -q -y --disablerepo="*" --enablerepo="rpm-rocky10-*" install rpm-build rpm-sign gnupg2 systemd-rpm-macros
    export GNUPGHOME=$(mktemp -d); cp -a /keys/gnupg/. "$GNUPGHOME/"; chmod 700 "$GNUPGHOME"
    rpm --import /keys/RPM-GPG-KEY-edge
    for r in $RELEASES; do
      rpmbuild -bb --define "_sourcedir /src" --define "_rpmdir /out" \
               --define "_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
               --define "rel $r" /src/edge-site-config.spec
      f=$(ls /out/edge-site-config-1.0-$r.*.noarch.rpm)
      rpmsign --addsign --define "_gpg_name $GPG_NAME" "$f" >/dev/null
      res=$(rpm -K "$f"); echo "$res"
      case "$res" in *"digests signatures OK"*) ;; *) echo "rpm -K did not verify $f" >&2; exit 1;; esac
      rpm -qp --qf "  %{NEVRA} signature: %{RSAHEADER:pgpsig}\n" "$f"
    done
    gpgconf --kill gpg-agent || true
    chown -R "$(stat -c %u:%g /out)" /out'
echo "rpms: built in $(( $(date +%s) - start ))s:"
ls -1 "$OUT"/*.rpm
