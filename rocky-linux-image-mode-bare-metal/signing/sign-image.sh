#!/usr/bin/env bash
# Sign one or more pushed images BY DIGEST with the edge cosign key, then verify.
#   signing/sign-image.sh localhost:30080/oci-bootc/rocky-edge:10.2-3 [...]
# The signature is stored by Artifact Keeper as the tag sha256-<digest>.sig in the
# same repository; it covers every tag that points at that digest (promotion = tag copy).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
(( $# )) || { echo "usage: $0 IMAGE:TAG..." >&2; exit 2; }
for ref in "$@"; do
  d="$(cosign_sign_ref "$ref")"
  echo "sign: $ref -> ${ref%:*}@$d signed and verified"
done
