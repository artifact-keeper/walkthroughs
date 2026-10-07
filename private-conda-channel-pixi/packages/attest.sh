#!/usr/bin/env bash
# CEP-27 publish attestations for built packages, signed with the CI cosign key
# (no public transparency log), uploaded to the registry beside each package.
#
# For each package:
#   1. write an in-toto Statement v1: subject = file name + sha256, predicateType
#      https://schemas.conda.org/attestations-publish-1.schema.json, predicate
#      {"targetChannel": TARGET_CHANNEL}
#      (cosign's --predicate/--type path emits Statement v0.1; CEP-27 needs v1,
#       so the statement is built here and passed with --statement)
#   2. cosign attest-blob --key ... --statement ... --bundle <file>.sigstore.json
#      (Sigstore bundle v0.3, DSSE envelope, public-key verification material)
#   3. PUT the bundle to https://ak.internal/conda/<REPO>/<subdir>/<file>/attestation
#      with the CI token
#
# Usage: packages/attest.sh [subdir/file.conda...]   (default: all in packages/out)
# Env:   REPO (conda-staging), KEY_DIR (signing/keys), TARGET_CHANNEL
#        (https://ak.internal/conda/conda-internal), UPLOAD=0 to only sign
# Exit:  non-zero if any upload is refused (the HTTP status and body are printed)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"; load_env
REPO="${REPO:-conda-staging}"
KEY_DIR="${KEY_DIR:-$HERE/../signing/keys}"
TARGET_CHANNEL="${TARGET_CHANNEL:-$AK_URL/conda/conda-internal}"
PRED_TYPE=https://schemas.conda.org/attestations-publish-1.schema.json
ATT="$HERE/out/attest"; mkdir -p "$ATT"
U=$(AK_HOST_URL)
files=("$@")
if ((${#files[@]} == 0)); then mapfile -t files < <(cd "$HERE/out" && ls -1 */*.conda); fi
rc=0
for rel in "${files[@]}"; do
  # accepts subdir/file.conda (under packages/out) or a path to any package file
  if [[ -f "$rel" ]]; then pkg="$(cd "$(dirname "$rel")" && pwd)/$(basename "$rel")"; else pkg="$HERE/out/$rel"; fi
  f="${pkg##*/}"; subdir="$(basename "$(dirname "$pkg")")"
  stmt="$ATT/$f.statement.json"; bundle="$ATT/$f.sigstore.json"
  jq -n --arg n "$f" --arg d "$(sha256sum "$pkg" | cut -d' ' -f1)" --arg t "$PRED_TYPE" --arg c "$TARGET_CHANNEL" \
    '{_type:"https://in-toto.io/Statement/v1",subject:[{name:$n,digest:{sha256:$d}}],predicateType:$t,predicate:{targetChannel:$c}}' > "$stmt"
  COSIGN_PASSWORD="$(<"$KEY_DIR/cosign.password")" cosign attest-blob --key "$KEY_DIR/cosign.key" \
    --statement "$stmt" --use-signing-config=false --tlog-upload=false --bundle "$bundle" --yes >/dev/null 2>&1
  # local self-check before upload
  cosign verify-blob --key "$KEY_DIR/cosign.pub" --bundle "$bundle" --insecure-ignore-tlog "$pkg" >/dev/null 2>&1 \
    || { echo "attest: $f: local verification FAILED" >&2; rc=1; continue; }
  if [[ "${UPLOAD:-1}" == 0 ]]; then echo "attest: $f signed (not uploaded)"; continue; fi
  resp=$(akcurl -sS -X PUT -H "Authorization: Bearer $(<"$TOKENS/ci.token")" -H 'Content-Type: application/json' \
         --data-binary "@$bundle" -w '\n%{http_code}' "$U/conda/$REPO/$subdir/$f/attestation")
  code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  if [[ "$code" =~ ^20 ]]; then echo "attest: $REPO/$subdir/$f -> HTTP $code $body"
  else echo "attest: $REPO/$subdir/$f -> HTTP $code REFUSED: $body"; rc=1; fi
done
exit $rc
