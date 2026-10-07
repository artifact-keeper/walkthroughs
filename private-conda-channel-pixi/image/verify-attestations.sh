#!/usr/bin/env bash
# Attestation gate: for every conda package in pixi.lock that comes from the
# internal channel, prove that
#   1. the bytes at the locked URL hash to the sha256 recorded in pixi.lock,
#   2. a CEP-27 publish attestation exists for it (CEP-50 sidecar <url>.sigs,
#      falling back to the Artifact Keeper endpoint <url>/attestation),
#   3. the attestation is an in-toto Statement v1 whose subject is this file
#      name and this sha256, with the CEP-27 predicate type, and
#   4. `cosign verify-blob --key <trusted key> --bundle <attestation>` passes
#      against the downloaded bytes.
# Any failure fails the script (and therefore the image build).
#
# Usage: verify-attestations.sh pixi.lock
# Env:   TRUSTED_KEY        PEM public key (default /etc/acme/conda-ci-cosign.pub)
#        INTERNAL_PREFIX    URL prefix of the internal channel
#                           (default https://ak.internal/conda/conda-internal/)
#        RATTLER_AUTH_FILE  {"host": {"BearerToken": "..."}} for authenticated reads
#        SIDECAR_ONLY=1     do not fall back to <url>/attestation
#        ATTESTATION_GATE=warn  report failures but exit 0 (only for registries
#                           that cannot store attestations yet; the image is
#                           labelled acme.attestation-gate=warn by the build)
# Needs: bash, curl, jq, cosign, sha256sum (the image build runs it under
#        `pixi exec -s cosign -s jq -s curl`, so those come from the registry too)
set -euo pipefail
LOCK="${1:-pixi.lock}"
KEY="${TRUSTED_KEY:-/etc/acme/conda-ci-cosign.pub}"
PREFIX="${INTERNAL_PREFIX:-https://ak.internal/conda/conda-internal/}"
PRED=https://schemas.conda.org/attestations-publish-1.schema.json
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

auth=()
if [[ -n "${RATTLER_AUTH_FILE:-}" && -s "$RATTLER_AUTH_FILE" ]]; then
  host="${PREFIX#https://}"; host="${host%%/*}"
  tok=$(jq -r --arg h "$host" '.[$h].BearerToken // empty' "$RATTLER_AUTH_FILE")
  [[ -n "$tok" ]] && auth=(-H "Authorization: Bearer $tok")
fi

# pixi.lock (v6): package entries are "- conda: <url>" followed by fields
# including "sha256: <hex>". Collect url<TAB>sha256 for the internal channel.
awk -v p="$PREFIX" '
  /^- conda: / { url=$3; next }
  /^  sha256: / && url != "" { if (index(url, p) == 1) print url "\t" $2; url="" }
' "$LOCK" | sort -u > "$WORK/pkgs.tsv"
n=$(wc -l < "$WORK/pkgs.tsv")
(( n > 0 )) || { echo "verify: no packages from $PREFIX in $LOCK" >&2; exit 1; }
echo "verify: $n package(s) from $PREFIX; trusted key $(sha256sum "$KEY" | cut -c1-16)"

fail=0
while IFS=$'\t' read -r url want; do
  f="${url##*/}"
  if ! curl -fsS "${auth[@]}" -o "$WORK/$f" "$url"; then
    echo "FAIL $f: download failed"; fail=1; continue; fi
  got=$(sha256sum "$WORK/$f" | cut -d' ' -f1)
  if [[ "$got" != "$want" ]]; then
    echo "FAIL $f: sha256 $got != pixi.lock $want"; fail=1; continue; fi
  src=sidecar
  if ! curl -fsS "${auth[@]}" -o "$WORK/$f.sigs" "$url.sigs" 2>/dev/null; then
    if [[ "${SIDECAR_ONLY:-0}" == 1 ]]; then echo "FAIL $f: no CEP-50 sidecar at $url.sigs"; fail=1; continue; fi
    src=endpoint
    if ! curl -fsS "${auth[@]}" -o "$WORK/$f.sigs" "$url/attestation" 2>/dev/null; then
      echo "FAIL $f: no attestation (neither $url.sigs nor $url/attestation)"; fail=1; continue; fi
  fi
  # A sidecar may hold one bundle, a JSON array of bundles, or one bundle per line.
  jq -c 'if type=="array" then .[] else . end' "$WORK/$f.sigs" > "$WORK/$f.bundles" 2>/dev/null \
    || { echo "FAIL $f: attestation is not JSON"; fail=1; continue; }
  ok=0; why="no bundle verified"
  while IFS= read -r b; do
    printf '%s' "$b" > "$WORK/b.json"
    stmt=$(jq -r '.dsseEnvelope.payload // empty' "$WORK/b.json" | base64 -d 2>/dev/null || true)
    [[ -n "$stmt" ]] || { why="bundle has no DSSE payload"; continue; }
    jq -e --arg n "$f" --arg d "$got" --arg p "$PRED" '
        ._type == "https://in-toto.io/Statement/v1" and .predicateType == $p
        and (.subject | length) == 1 and .subject[0].name == $n
        and .subject[0].digest.sha256 == $d' <<<"$stmt" >/dev/null \
      || { why="statement does not bind this file: $(jq -c '{_type,predicateType,subject}' <<<"$stmt")"; continue; }
    if out=$(cosign verify-blob --key "$KEY" --bundle "$WORK/b.json" --insecure-ignore-tlog "$WORK/$f" 2>&1); then
      ok=1; break
    else why="cosign: $(grep -v WARNING <<<"$out" | tail -1)"; fi
  done < "$WORK/$f.bundles"
  if (( ok )); then echo "PASS $f ($src, sha256 ${got:0:12}..., channel $(jq -r '.predicate.targetChannel // "-"' <<<"$stmt"))"
  else echo "FAIL $f: $why"; fail=1; fi
done < "$WORK/pkgs.tsv"

if (( fail )); then
  if [[ "${ATTESTATION_GATE:-enforce}" == warn ]]; then echo "verify: attestation gate FAILED (ATTESTATION_GATE=warn: continuing)"; exit 0; fi
  echo "verify: attestation gate FAILED"; exit 1
fi
echo "verify: attestation gate passed for $n package(s)"
