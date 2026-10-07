#!/usr/bin/env bash
# Create the demo CI signing key (cosign, ECDSA P-256) and a second "wrong" key
# used only by the negative tests. Idempotent. Keys live in signing/keys/
# (gitignored); the public key is also published to the registry's `trust` repo
# by signing/publish-keys.sh.
#
#   signing/keys/cosign.key, cosign.pub, cosign.password   the CI publish key
#   signing/keys/wrong/cosign.key, cosign.pub, ...         an untrusted key
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
umask 077
gen() { # dir
  local d=$1
  mkdir -p "$d"
  if [[ -s "$d/cosign.key" && -s "$d/cosign.pub" ]]; then echo "keys: $d exists"; return; fi
  [[ -s "$d/cosign.password" ]] || openssl rand -hex 24 > "$d/cosign.password"
  (cd "$d" && COSIGN_PASSWORD="$(cat cosign.password)" cosign generate-key-pair >/dev/null 2>&1)
  chmod 644 "$d/cosign.pub"
  echo "keys: created $d/cosign.{key,pub}"
}
gen "$HERE/keys"
gen "$HERE/keys/wrong"
openssl pkey -pubin -in "$HERE/keys/cosign.pub" -noout -text | head -1
