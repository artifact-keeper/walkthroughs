#!/usr/bin/env bash
# Step 3: vet what was seeded, while still connected.
#   1. The model: download the GGUF from hf-hub's cache (the commit-pinned path the seed job
#      cached), publish it to hf-models, the vetted Local, where it is scanned on upload by the
#      model-file scanner (#5337) and served only once a scan has completed with nothing at
#      or above medium (policy hf-models-vetted). Two counter-examples go through the same
#      door: a truncated GGUF and a pickle that calls os.system.
#   2. The scanner adapter runs offline (SCANNER_OFFLINE, #5314): import the trivy database,
#      fetched as an OCI artifact through oci-ghcr, with PUT /api/v1/vulndb, read its age, and
#      scan the llama.cpp image from the registry with no network.
#   3. The configuration: export every repository as one document (#5335) and plan it against
#      this instance (nothing to change). The export is the site's configuration of record.
#   4. The inventory: seed/inventory.sh seed -> out/inventory/seed.tsv, what gate G7e compares
#      the site against.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $(phase) == seed ]] || { echo "vet.sh: vetting runs while seeding (make reconnect first)" >&2; exit 1; }
MD="$ROOT/out/models"; mkdir -p "$MD"

artifact_id() { # REPO PATH
  api GET "/repositories/$1/artifacts?per_page=200" | jq -r --arg p "$2" '.items[] | select(.path == $p) | .id' | head -1
}
wait_scans() { # ID: until a model scan of it has completed (or 120 s)
  for _ in $(seq 60); do
    api GET "/security/artifacts/$1/scans" | jq -e 'any(.items[]; .scan_type == "model" and (.status == "completed" or .status == "failed"))' >/dev/null && return 0
    sleep 2
  done; return 1
}
scans() { api GET "/security/artifacts/$1/scans" | jq -c '[.items[] | {scan_type, status, findings_count}]'; }
findings() { # ID: the model scanner's findings (GET /security/scans/{scan}/findings)
  local sid; sid=$(api GET "/security/artifacts/$1/scans" | jq -r '[.items[] | select(.scan_type == "model")][0].id // empty')
  [[ -n $sid ]] || { echo '[]'; return; }
  api GET "/security/scans/$sid/findings?per_page=50" | jq -c '[(.items // .)[] | {severity, rule: .affected_component, title: ((.title // "")[0:70])}]' 2>/dev/null || echo '[]'
}
publish() { # MODEL FILE-ON-DISK NAME
  call publisher POST "/huggingface/hf-models/api/models/$1/upload/main" -H "X-Filename: $3" --data-binary "@$2" >/dev/null
  printf '  upload %s/%s: HTTP %s %s\n' "$1" "$3" "$(code)" "$(jq -c '{path, size}' "$FOUT/.body" 2>/dev/null || head -c 120 "$FOUT/.body")"
}

say "1a. the model from hf-hub's cache, at the seeded commit"
for f in $(manifest "$(model_sel) | .files[]"); do
  if [[ -s "$MD/$f" ]]; then echo "  $f: already downloaded"; continue; fi
  call developer GET "/huggingface/hf-hub/$MODEL_REPO/resolve/$MODEL_REV/$f" -o "$MD/$f.part" >/dev/null
  [[ $(code) == 200 ]] || { echo "vet.sh: GET hf-hub $f: HTTP $(code)" >&2; exit 1; }
  mv "$MD/$f.part" "$MD/$f"; echo "  $f: $(stat -c %s "$MD/$f") bytes, sha256 $(sha256sum "$MD/$f" | cut -c1-16)"
done

say "1b. publish it to hf-models (scan on upload, policy hf-models-vetted)"
for f in $(manifest "$(model_sel) | .files[]"); do
  id=$(artifact_id hf-models "$MODEL_REPO/main/$f")
  if [[ -n $id ]]; then echo "  $f: already in hf-models"; else publish "$MODEL_REPO" "$MD/$f" "$f"; fi
done
id=$(artifact_id hf-models "$MODEL_REPO/main/$MODEL_GGUF")
wait_scans "$id" || echo "  (no completed model scan after 120 s)"
echo "  $MODEL_GGUF scans: $(scans "$id")"
echo "  findings: $(findings "$id")"
call developer HEAD "/huggingface/hf-models/$MODEL_REPO/resolve/main/$MODEL_GGUF" >/dev/null
echo "  HEAD hf-models .../resolve/main/$MODEL_GGUF: HTTP $(code), X-Repo-Commit $(hdr X-Repo-Commit)"

say "1c. two files that must not get through"
python3 -I - "$MD" "$MD/$MODEL_GGUF" <<'PY'
import pathlib, sys
out, gguf = pathlib.Path(sys.argv[1]), sys.argv[2]
# A GGUF cut off after 4 MiB: the header still claims every tensor, whose data is gone.
with open(gguf, "rb") as f:
    (out / "truncated.gguf").write_bytes(f.read(4 << 20))
# A protocol-2 pickle that imports os.system and calls it with "id" (written as bytes; never run).
(out / "pytorch_model.bin").write_bytes(b"\x80\x02cos\nsystem\nq\x00X\x02\x00\x00\x00idq\x01\x85q\x02Rq\x03.")
PY
for t in "acme-lab/truncated-gguf truncated.gguf model.gguf" "acme-lab/backdoored pytorch_model.bin pytorch_model.bin"; do
  read -r m src name <<<"$t"
  [[ -n $(artifact_id hf-models "$m/main/$name") ]] || publish "$m" "$MD/$src" "$name"
  aid=$(artifact_id hf-models "$m/main/$name"); wait_scans "$aid" || true
  echo "  $m/$name scans: $(scans "$aid")"
  echo "    findings: $(findings "$aid")"
  call developer GET "/huggingface/hf-models/$m/resolve/main/$name" -o /dev/null >/dev/null
  echo "    GET .../resolve/main/$name: HTTP $(code)"
done

say "2. the scanner adapter, offline: import the trivy database through oci-ghcr"
ref=$(manifest '.image[] | select(.name == "trivy-db") | .ref'); img=${ref%%:*}; tag=${ref#*:}
call developer GET "/v2/oci-ghcr/$img/manifests/$tag" -H 'Accept: application/vnd.oci.image.manifest.v1+json' >/dev/null
layer=$(jq -r '.layers[0].digest' "$FOUT/.body")
echo "  oci-ghcr/$img:$tag: manifest HTTP $(code), layer $layer ($(jq -r '.layers[0].mediaType' "$FOUT/.body"))"
call developer GET "/v2/oci-ghcr/$img/blobs/$layer" -L -o "$ROOT/out/trivy-db.tar.gz" >/dev/null
echo "  blob: HTTP $(code), $(stat -c %s "$ROOT/out/trivy-db.tar.gz") bytes"
adapter() { # METHOD PATH [curl args]: a call to the adapter from a container on the stack network
  local m=$1 p=$2; shift 2
  podman run --rm --network "$NET" -v "$ROOT/out:/out:z" "$P/oci-dockerhub/$(manifest '.image[] | select(.name == "python") | .ref')" \
    python -I -c '
import json, sys, urllib.request
m, url, tok, body = sys.argv[1:5]
data = open(body, "rb").read() if body else None
req = urllib.request.Request(url, data=data, method=m, headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json" if body.endswith(".json") else "application/octet-stream"})
try:
    r = urllib.request.urlopen(req, timeout=600); print(r.status); print(r.read().decode().strip())
except urllib.error.HTTPError as e:
    print(e.code); print(e.read().decode()[:2000].strip())' "$m" "http://scanner-adapter:8080$p" "$SCANNER_ADAPTER_TOKEN" "${1:-}"
}
adapter GET /probe/ready | head -1 | sed 's/^/  ready before the import: HTTP /'
adapter GET /api/v1/vulndb | head -1 | sed 's/^/  GET \/api\/v1\/vulndb before: HTTP /'
adapter PUT /api/v1/vulndb /out/trivy-db.tar.gz | tee "$FOUT/vulndb-import.txt" | tail -1 | head -c 300; echo
adapter GET /api/v1/vulndb | tail -1 | tee "$FOUT/vulndb.json"; echo
adapter GET /probe/ready | head -1 | sed 's/^/  ready after the import: HTTP /'

say "2b. the adapter scans the llama.cpp image from the registry (no network involved)"
lref=$(manifest '.image[] | select(.name == "llama-server") | .ref'); limg=${lref%%:*}; ltag=${lref#*:}
call developer HEAD "/v2/oci-ghcr/$limg/manifests/$ltag" -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' >/dev/null
# The adapter scans one platform's manifest: resolve the index to linux/amd64.
call developer GET "/v2/oci-ghcr/$limg/manifests/$ltag" -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' >/dev/null
ldig=$(jq -r '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64")][0].digest // empty' "$FOUT/.body")
[[ -n $ldig ]] || ldig=$(hdr Docker-Content-Digest)
jq -n --arg u "http://backend:8080" --arg a "Bearer $(tok developer)" --arg r "oci-ghcr/$limg" --arg d "$ldig" \
  '{registry:{url:$u,authorization:$a},artifact:{repository:$r,digest:$d,mime_type:"application/vnd.oci.image.manifest.v1+json"}}' > "$ROOT/out/adapter-scan.json"
adapter POST /api/v1/scan /out/adapter-scan.json | tee "$FOUT/adapter-scan.txt" | tail -1; echo
rm -f "$ROOT/out/adapter-scan.json"   # it holds the developer token
sid=$(tail -1 "$FOUT/adapter-scan.txt" | jq -r .id 2>/dev/null || true)
if [[ -n $sid && $sid != null ]]; then
  for _ in $(seq 90); do
    adapter GET "/api/v1/scan/$sid/report" > "$FOUT/adapter-report.txt"
    [[ $(head -1 "$FOUT/adapter-report.txt") == 200 ]] && break; sleep 5
  done
  echo "  report: HTTP $(head -1 "$FOUT/adapter-report.txt"), $(tail -n +2 "$FOUT/adapter-report.txt" | jq -c '{scanner: .scanner, vulnerabilities: (.vulnerabilities | length)}' 2>/dev/null || tail -c 200 "$FOUT/adapter-report.txt")"
fi

say "3. the configuration of record: export, then plan it against this instance"
mkdir -p "$ROOT/out/config"
api GET /admin/config/export > "$ROOT/out/config/seed.json"
echo "  GET /api/v1/admin/config/export: HTTP $(code), $(jq '.repositories | length' "$ROOT/out/config/seed.json") repositories"
jq -c '.repositories[] | {key, repo_type, format, cache_ttl_seconds, egress: .egress_proxy.mode}' "$ROOT/out/config/seed.json" | head -20
api POST "/admin/config/import?mode=plan" --data-binary "@$ROOT/out/config/seed.json" > "$ROOT/out/config/plan-seed.json"
echo "  plan: HTTP $(code) $(jq -c '{create: (.create|length), update, unchanged: (.unchanged|length), missing_secrets, errors, applicable}' "$ROOT/out/config/plan-seed.json")"

say "4. the inventory of record: every manifest item as the registry serves it now"
"$ROOT/seed/inventory.sh" seed
