#!/usr/bin/env bash
# G8 Attestations:
#   - the registry serves CEP-50 sidecars (<url>.sigs) and attestations_sha256 in repodata;
#   - the image build's attestation gate (image/verify-attestations.sh) passes for
#     signed packages and fails for tampered, wrong-key and unsigned ones. The gate
#     logic is exercised against a local static channel (so it is tested even
#     while the registry cannot store key-based attestations), then against the
#     registry in a real image build.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G8
CORE=noarch/$(cd "$ROOT/packages/out" && ls noarch | grep -m1 '^acme-core-1.0.0-.*\.conda$')
URL="$U/conda/conda-internal/$CORE"
c=$(http GET "$URL.sigs" consumer); echo "GET conda-internal/$CORE.sigs -> $c $(head -c 100 "$SP_TMP/body")"
[[ $c == 200 ]] && pass $G "CEP-50 sidecar <file>.sigs served" || blocked F5 $G "CEP-50 sidecar <file>.sigs served" "HTTP $c"
http GET "$U/conda/conda-internal/noarch/repodata.json" consumer >/dev/null
a=$(body | jq -r --arg f "${CORE#noarch/}" '.["packages.conda"][$f].attestations_sha256 // empty')
[[ -n "$a" ]] && pass $G "repodata carries attestations_sha256" || blocked F5 $G "repodata carries attestations_sha256" "field absent"

# --- gate logic on a local static channel -----------------------------------
L="$ROOT/out/g8"; rm -rf "$L"; mkdir -p "$L/chan/noarch" "$L/locks"
K="$ROOT/signing/keys"; src="$ROOT/packages/out/$CORE"; f=$(basename "$src")
mk() { # case-name file-bytes-source key-dir(or "none") lock-sha(source|actual)
  local n=$1 d="$L/chan/$1/noarch"; mkdir -p "$d"; cp "$2" "$d/$f"
  if [[ $3 != none ]]; then UPLOAD=0 KEY_DIR="$3" "$ROOT/packages/attest.sh" "$2" >/dev/null 2>&1
     cp "$ROOT/packages/out/attest/$f.sigstore.json" "$d/$f.sigs"; fi
  local sha; [[ $4 == source ]] && sha=$(sha256sum "$src" | cut -d' ' -f1) || sha=$(sha256sum "$d/$f" | cut -d' ' -f1)
  printf 'version: 7\npackages:\n- conda: http://gate-sigs:8000/%s/noarch/%s\n  sha256: %s\n' "$n" "$f" "$sha" > "$L/locks/$n.lock"
}
python3 - "$src" "$L/tampered.conda" <<'PY'
import sys; b=bytearray(open(sys.argv[1],'rb').read()); b[len(b)//2]^=0x01; open(sys.argv[2],'wb').write(b)
PY
mk signed "$src" "$K" source                       # good
mk tampered "$L/tampered.conda" "$K" source        # bytes flipped after signing, lock has the original sha
mk tampered-relocked "$L/tampered.conda" none actual  # attacker re-locks the tampered file and has no signature...
cp "$L/chan/signed/noarch/$f.sigs" "$L/chan/tampered-relocked/noarch/$f.sigs"  # ...so reuses the original one
mk wrongkey "$src" "$K/wrong" source               # signed by an untrusted key
mk unsigned "$src" none source                     # no attestation at all
podman rm -f ak-conda-gate-sigs >/dev/null 2>&1
podman run -d --name ak-conda-gate-sigs --network "$NET" --network-alias gate-sigs -v ak-conda-pixi-cache:/cache \
  -v "$L/chan:/chan:ro,z" -v "$TOKENS/consumer-auth.json:/run/secrets/a.json:ro,z" -e RATTLER_AUTH_FILE=/run/secrets/a.json \
  -w /chan "$CLIENT" pixi exec -s python -- python -m http.server 8000 >/dev/null
sleep 6
run_gate() { podman run --rm --network "$NET" -v ak-conda-pixi-cache:/cache -v "$L/locks:/locks:ro,z" \
  -v "$K/cosign.pub:/etc/acme/conda-ci-cosign.pub:ro,z" -v "$ROOT/image/verify-attestations.sh:/v.sh:ro,z" \
  -v "$TOKENS/consumer-auth.json:/run/secrets/a.json:ro,z" -e RATTLER_AUTH_FILE=/run/secrets/a.json \
  -e INTERNAL_PREFIX="http://gate-sigs:8000/$1/" -e SIDECAR_ONLY=1 "$CLIENT" \
  pixi exec -s cosign -s jq -s curl -s bash -- bash /v.sh "/locks/$1.lock" 2>&1 | grep -E '^(PASS|FAIL|verify)'; return "${PIPESTATUS[0]}"; }
for n in signed tampered tampered-relocked wrongkey unsigned; do
  out=$(run_gate $n); rc=$?; echo "[$n] rc=$rc"; sed 's/^/    /' <<<"$out"
  case $n in
    signed) [[ $rc == 0 ]] && pass $G "gate passes a package signed by the trusted key" || fail $G "gate passes a signed package" "rc=$rc";;
    tampered) [[ $rc != 0 ]] && grep -q 'sha256 .* != pixi.lock' <<<"$out" && pass $G "gate fails a flipped byte (sha256 differs from pixi.lock)" || fail $G "gate fails tampered" "rc=$rc";;
    tampered-relocked) [[ $rc != 0 ]] && grep -q 'does not bind\|cosign' <<<"$out" && pass $G "gate fails a re-locked tampered file (attestation digest does not match)" || fail $G "gate fails re-locked tampered" "rc=$rc";;
    wrongkey) [[ $rc != 0 ]] && grep -q 'cosign' <<<"$out" && pass $G "gate fails a package signed by an untrusted key" || fail $G "gate fails wrong key" "rc=$rc";;
    unsigned) [[ $rc != 0 ]] && grep -q 'no CEP-50 sidecar' <<<"$out" && pass $G "gate fails a package with no attestation" || fail $G "gate fails unsigned" "rc=$rc";;
  esac
done
podman rm -f ak-conda-gate-sigs >/dev/null 2>&1

# --- against the registry, in a real image build ------------------------------
log="$GOUT/g08-image-build.log"
if PROJECT="${PROJECT:-project-direct}" ATTESTATION_GATE=enforce TAG=g8 "$ROOT/image/build.sh" > "$log" 2>&1; then
  grep -E '^(PASS|FAIL|verify)' "$log"
  pass $G "image build: attestation gate passes for every internal package in pixi.lock"
else
  grep -E '^(PASS|FAIL|verify)' "$log" | head -5
  if grep -q 'attestation gate FAILED' "$log"; then
    pass $G "image build fails when internal packages carry no verifiable attestation (enforce mode)"
    blocked F5,F6 $G "image build: attestation gate passes for signed packages from the registry" "the registry refuses key-based bundles, so nothing is signed"
  else fail $G "image build with the attestation gate" "$(tail -2 "$log")"; fi
fi
