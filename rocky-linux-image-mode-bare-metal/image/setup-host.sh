#!/usr/bin/env bash
# Build-host container configuration, user level only (no sudo). Idempotent.
#
# 1. registries.conf.d: mark the local Artifact Keeper (plain HTTP on localhost:30080)
#    insecure, so FROM/pull/push work without --tls-verify=false.
# 2. policy.json: images under localhost:30080/oci-bootc must carry a valid cosign
#    signature by the edge key (sigstoreSigned). Everything else keeps whatever the
#    system policy says. A user-level ~/.config/containers/policy.json REPLACES
#    /etc/containers/policy.json for this user, so we start from the system file
#    (or from an insecureAcceptAnything default if there is none) and add one scope.
#    signedIdentity is matchRepository: cosign records a tag-less identity
#    ("localhost:30080/oci-bootc/rocky-edge"), which the default
#    matchRepoDigestOrExact always rejects ("Signature for identity ... is not accepted").
# 3. registries.d: use-sigstore-attachments for localhost:30080/oci-bootc, so
#    containers-image looks for cosign's sha256-<digest>.sig tags. A user-level
#    registries.d also REPLACES /etc/containers/registries.d, so the system files are
#    symlinked in alongside ours.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AK="${AK:-localhost:30080}"
SCOPE="$AK/oci-bootc"
PUBKEY="${PUBKEY:-$ROOT/signing/keys/pub/edge-cosign.pub}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/containers"
SYS_POLICY="${SYS_POLICY:-/etc/containers/policy.json}"

write_if_changed() { # write_if_changed FILE  (content on stdin)
  local f=$1 tmp; tmp="$(mktemp)"; cat > "$tmp"
  if [[ -f "$f" ]] && cmp -s "$tmp" "$f"; then
    rm -f "$tmp"; echo "setup-host: $f already in place"
  else
    mv "$tmp" "$f"; chmod 0644 "$f"; echo "setup-host: wrote $f"
  fi
}

# 1. insecure registry
mkdir -p "$CONF/registries.conf.d"
write_if_changed "$CONF/registries.conf.d/50-artifact-keeper-local.conf" <<CONF
# Artifact Keeper on this workstation serves plain HTTP on :30080.
# Installed by artifact-keeper/walkthroughs rocky-linux-image-mode-bare-metal/image/setup-host.sh
[[registry]]
location = "$AK"
insecure = true
CONF

# 2. signature policy
[[ -s "$PUBKEY" ]] || { echo "setup-host.sh: $PUBKEY missing; run signing/gen-keys.sh (make keys)" >&2; exit 1; }
if [[ -r "$SYS_POLICY" ]]; then base="$(cat "$SYS_POLICY")"
else base='{"default":[{"type":"insecureAcceptAnything"}],"transports":{}}'; fi
jq --arg scope "$SCOPE" --arg key "$PUBKEY" '
  .transports.docker[$scope] = [{type:"sigstoreSigned", keyPath:$key,
                                 signedIdentity:{type:"matchRepository"}}]' <<<"$base" \
  | write_if_changed "$CONF/policy.json"

# 3. sigstore attachments lookaside
mkdir -p "$CONF/registries.d"
for f in /etc/containers/registries.d/*.yaml; do
  [[ -e "$f" ]] || continue
  [[ -e "$CONF/registries.d/$(basename "$f")" ]] || ln -s "$f" "$CONF/registries.d/$(basename "$f")"
done
write_if_changed "$CONF/registries.d/ak-oci-bootc.yaml" <<YAML
# cosign signatures for images in the Artifact Keeper oci-bootc repo are stored as
# sha256-<digest>.sig tags next to the image; tell containers-image to fetch them.
docker:
  $SCOPE:
    use-sigstore-attachments: true
YAML
