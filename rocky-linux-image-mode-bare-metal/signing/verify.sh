#!/usr/bin/env bash
# End-to-end check of the signature chain, from this host (gates 6-8 minus the VM):
#   1. public keys are served anonymously by raw-edge-keys and match signing/keys/pub
#   2. cosign verify (edge key) for the base and every rocky-edge release tag + :10;
#      the negative-test tags (rocky-bootc-base:unsigned, rocky-edge:unsigned-test)
#      must NOT verify
#   3. the build-host policy (image/setup-host.sh) admits the signed base and
#      rejects the unsigned one (skopeo copy, which enforces policy.json)
#   4. rpm-edge-site repomd.xml.asc verifies against repomd.xml.key (AK-signed);
#      Rocky / RKE2 proxied repomd.xml.asc verify against the vendor keys
#   5. our RPMs in rpms/out carry a signature by the edge key (rpm -K in a container)
# Env: AK (default localhost:30080), RELEASES (default "3 4")
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
RELEASES="${RELEASES:-3 4}"
PUB="$SIGNING_DIR/keys/pub"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail=0
ok()  { echo "verify: OK   $*"; }
bad() { echo "verify: FAIL $*"; fail=1; }

# 1. keys
for f in edge-cosign.pub RPM-GPG-KEY-edge RPM-GPG-KEY-Rancher RPM-GPG-KEY-EPEL-10; do
  if curl -fsS "http://$AK/api/v1/repositories/raw-edge-keys/download/$f" | cmp -s - "$PUB/$f"; then
    ok "raw-edge-keys/$f served anonymously, matches"; else bad "raw-edge-keys/$f"; fi
done

# 2. cosign
cv() { cosign verify "${COSIGN_VERIFY_FLAGS[@]}" "$1" >/dev/null 2>&1; }
osver=$(skopeo inspect --no-creds --tls-verify=false "docker://$AK/oci-bootc/rocky-edge:10" | jq -r '.Labels["org.opencontainers.image.version"]' | cut -d- -f1)
for ref in "oci-bootc/rocky-bootc-base:10" "oci-bootc/rocky-edge:10" $(for r in $RELEASES; do echo "oci-bootc/rocky-edge:$osver-$r"; done); do
  d=$(digest_of "$AK/$ref")
  if cv "$AK/${ref%:*}@$d"; then ok "cosign: $ref ($d) signed by edge key"; else bad "cosign: $ref ($d) not signed"; fi
done
for ref in "oci-bootc/rocky-bootc-base:unsigned" "oci-bootc/rocky-edge:unsigned-test"; do
  d=$(digest_of "$AK/$ref" 2>/dev/null) || { echo "verify: skip $ref (not pushed)"; continue; }
  if cv "$AK/${ref%:*}@$d"; then bad "cosign: $ref ($d) is signed but should not be"; else ok "cosign: $ref ($d) unsigned, as intended"; fi
done

# 3. build-host policy
if skopeo copy -q "docker://$AK/oci-bootc/rocky-bootc-base:10" "dir:$WORK/base" >/dev/null 2>&1; then
  ok "policy.json admits rocky-bootc-base:10"; else bad "policy.json rejected rocky-bootc-base:10"; fi
rm -rf "$WORK/base"
if err=$(skopeo copy -q "docker://$AK/oci-bootc/rocky-bootc-base:unsigned" "dir:$WORK/u" 2>&1); then
  bad "policy.json admitted rocky-bootc-base:unsigned"
else ok "policy.json rejects rocky-bootc-base:unsigned: $(sed -n 's/.*msg="\(.*\)"/\1/p' <<<"$err")"; fi
rm -rf "$WORK/u"

# 4. repodata signatures
export GNUPGHOME="$WORK/gnupg"; mkdir -m 700 "$GNUPGHOME"
gv() { # gv REPO KEYFILE
  curl -fsS -o "$WORK/r.xml" "http://$AK/rpm/$1/repodata/repomd.xml"
  curl -fsS -o "$WORK/r.asc" "http://$AK/rpm/$1/repodata/repomd.xml.asc" || { bad "$1: no repomd.xml.asc"; return; }
  rm -f "$WORK/k.gpg"; gpg --batch -q --no-default-keyring --keyring "$WORK/k.gpg" --import "$2" 2>/dev/null || true
  if gpgv --keyring "$WORK/k.gpg" "$WORK/r.asc" "$WORK/r.xml" >/dev/null 2>&1; then ok "$1: repomd.xml.asc verifies ($(basename "$2"))"
  else bad "$1: repomd.xml.asc does not verify with $(basename "$2")"; fi
}
curl -fsS -o "$WORK/ak-edge-site.key" "http://$AK/rpm/rpm-edge-site/repodata/repomd.xml.key"
gv rpm-edge-site "$WORK/ak-edge-site.key"
gv rpm-rke2-common "$PUB/RPM-GPG-KEY-Rancher"
gv rpm-rke2-1.36 "$PUB/RPM-GPG-KEY-Rancher"
# GnuPG 2.4 cannot parse the v6 key in Rocky's key file; use only the first (v4) block.
rocky="$PUB/RPM-GPG-KEY-Rocky-10"
[[ -s "$rocky" ]] || { podman run --rm "$AK/oci-bootc/rocky-bootc-base:10" cat /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10 > "$WORK/rocky.asc"; rocky="$WORK/rocky.asc"; }
awk '/BEGIN PGP/{n++} n==1' "$rocky" > "$WORK/rocky-v4.asc"
for r in rpm-rocky10-baseos rpm-rocky10-appstream rpm-rocky10-extras; do gv "$r" "$WORK/rocky-v4.asc"; done

# 5. RPM signatures
shopt -s nullglob
rpms=("$REPO_ROOT"/rpms/out/edge-site-config-*.rpm)
if (( ${#rpms[@]} )); then
  out=$(podman run --rm --security-opt label=disable -v "$REPO_ROOT/rpms/out:/out:ro" -v "$PUB/RPM-GPG-KEY-edge:/k:ro" \
        "$AK/oci-quay-proxy/rockylinux/rockylinux:10" sh -c 'rpm --import /k; rpm -K /out/*.rpm')
  while read -r line; do
    case "$line" in
      *"digests signatures OK"*) ok "rpm -K ${line#/out/}" ;;
      *-1.el10*|*-2.el10*) echo "verify: info rpm -K ${line#/out/} (iteration-1 release, unsigned)" ;;
      *) bad "rpm -K ${line#/out/}" ;;
    esac
  done <<<"$out"
fi

(( fail == 0 )) && echo "verify: all checks passed" || { echo "verify: FAILURES above" >&2; exit 1; }
