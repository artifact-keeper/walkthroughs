#!/usr/bin/env bash
# G9 Trust policy: with the CI public key configured as the registry's conda
# attestation trust policy, an attestation signed by that key is accepted on
# upload and one signed by any other key (or a disallowed identity) is refused
# with 400. Uses acme-core 1.0.1 in conda-staging (published by G7).
# The trust policy itself is configured by registry/trust-policy.sh when the
# backend supports it (F6).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G9
[[ -x "$ROOT/registry/trust-policy.sh" ]] && "$ROOT/registry/trust-policy.sh" 2>&1 | sed 's/^/  /'
PKG=$(ls "$ROOT"/out/g7/noarch/acme-core-*.conda 2>/dev/null | head -1)
[[ -n "$PKG" ]] || { fail $G "setup" "run G7 first (acme-core 1.0.1 in conda-staging)"; exit 0; }
f=$(basename "$PKG")
up() { # key-dir -> HTTP code + body
  UPLOAD=0 KEY_DIR="$1" "$ROOT/packages/attest.sh" "$PKG" >/dev/null 2>&1
  http PUT "$U/conda/conda-staging/noarch/$f/attestation" ci -H 'Content-Type: application/json' \
    --data-binary "@$ROOT/packages/out/attest/$f.sigstore.json"; }
cw=$(up "$ROOT/signing/keys/wrong"); bw=$(body); echo "wrong key  -> HTTP $cw $bw"
cr=$(up "$ROOT/signing/keys"); br=$(body); echo "trusted key -> HTTP $cr $br"
if [[ $cr =~ ^20 && $cw == 400 ]]; then
  pass $G "attestation signed by the trusted key accepted ($cr); wrong key refused ($cw: $bw)"
elif [[ $cr == 400 && $cw == 400 ]]; then
  blocked F6 $G "trusted key accepted, wrong key refused" "both refused: key-based bundles are not supported ($br)"
else fail $G "trust policy" "trusted=$cr wrong=$cw"; fi
