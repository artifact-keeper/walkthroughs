#!/usr/bin/env bash
# Step 2: seed. Pull everything in seed/manifest.toml through Artifact Keeper while the seed
# network still has a route out, publish what Acme makes itself, and list what went out.
#   1. images      podman pull through oci-ghcr and oci-dockerhub
#   2. the model   a cache-seed job on hf-hub (#5333), commit-pinned paths only
#   3. Python      Acme's wheel to pypi-local; the agent image, which installs the hash-pinned
#                  lock through the pypi Virtual
#   4. MCP         com.acme/inventory published to mcp-internal; io.github.daedalus/mcp-sqlite3
#                  0.1.3 seeded into mcp-official from the official registry (#5408)
#   5. plugins     offgrid-ops published to plugins-central, then read through the plugins
#                  Remote (#5334), which caches it
#   6. npm         the pi image, which installs pi through npm-remote
# Every step is idempotent: what is already published or cached is skipped or served from the
# cache. The ledger and the UPSTREAM_FETCHED rows record what went out.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../flows/lib.sh"
[[ $(phase) == seed ]] || { echo "seed.sh: the stack is on the site network (make reconnect first)" >&2; exit 1; }
echo "$SMALL_MODEL" > "$ROOT/out/small-model"
echo "seed: model $MODEL_REPO ($MODEL_GGUF)$([[ $SMALL_MODEL == 1 ]] && echo ', SMALL_MODEL=1')"
l0=$(ledger_lines); t0=$(date -u +%FT%TZ)
# the first seed's start: a re-run finds what the first one cached and fetches nothing new
[[ -s "$ROOT/out/seed-started" ]] || echo "$t0" > "$ROOT/out/seed-started"

say "1. images (podman pull through the registry, from the host)"
: > "$ROOT/out/seed-images.tsv"   # repo, ref, the digest podman pulled (gate G4 compares the site's pull)
while IFS=$'\t' read -r repo ref art; do
  if [[ $art == true ]]; then
    # An OCI artifact, not an image (podman does not pull it): its manifest and its layers
    img=${ref%%:*} tag=${ref#*:}
    call developer GET "/v2/$repo/$img/manifests/$tag" -H 'Accept: application/vnd.oci.image.manifest.v1+json' >/dev/null
    d=$(hdr Docker-Content-Digest)
    for l in $(jq -r '.layers[].digest' "$FOUT/.body"); do call developer GET "/v2/$repo/$img/blobs/$l" -L -o /dev/null >/dev/null; done
    printf '  %-14s %-60s %s (artifact, layers HTTP %s)\n' "$repo" "$ref" "$d" "$(code)"
  else
    d=$(pull_image "$repo" "$ref")
    printf '  %-14s %-60s %s\n' "$repo" "${ref:0:60}" "$d"
    printf '%s\t%s\t%s\n' "$repo" "$ref" "$d" >> "$ROOT/out/seed-images.tsv"
  fi
done < <(manifest '.image[] | [.repo, .ref, (.artifact // false)] | @tsv')

say "2. the model: a cache-seed job on hf-hub, commit-pinned paths ($MODEL_REPO@${MODEL_REV:0:12})"
mapfile -t paths < <(manifest "$(model_sel) | .files[] as \$f | \"\(.repo_id)/resolve/\(.revision)/\(\$f)\"")
paths+=("api/models/$MODEL_REPO/revision/$MODEL_REV")
printf '  %s\n' "${paths[@]}"
api POST /repositories/hf-hub/cache/seed -d "$(jq -nc '{kind:"paths",content:$ARGS.positional,options:{concurrency:2}}' --args "${paths[@]}")" >/dev/null
echo "  POST /api/v1/repositories/hf-hub/cache/seed: HTTP $(code) $(jq -c '{job_id,status,total_items}' "$FOUT/.body")"
job=$(jq -r .job_id "$FOUT/.body")
wait_seed hf-hub "$job" > "$FOUT/seed-hf-hub.json"
jq -c '{status, summary}' "$FOUT/seed-hf-hub.json"
jq -r '.items[] | "  \(.state)\t\(.size_bytes // "-")\t\(.checksum_sha256 // "-" | .[0:16])\t\(.path)\(if .reason then "  (" + .reason + ")" else "" end)"' "$FOUT/seed-hf-hub.json"
echo "$job" > "$ROOT/out/seed-job-hf-hub"

say "3a. Acme's MCP server package: acme-inventory-mcp 1.0.0 to pypi-local"
mkdir -p "$ROOT/out/dist"
read -r whl wsha < <(python3 -I "$ROOT/tools/acme-inventory/build_wheel.py" "$ROOT/out/dist")
echo "  built $(basename "$whl") sha256 $wsha"
grep -q "$wsha" "$ROOT/agent/requirements-internal.txt" || { echo "seed.sh: the wheel's hash is not the one agent/requirements-internal.txt pins" >&2; exit 1; }
call developer GET /pypi/pypi-local/simple/acme-inventory-mcp/ >/dev/null
if [[ $(code) == 200 ]] && grep -q "$(basename "$whl")" "$FOUT/.body"; then echo "  already in pypi-local: skipped"; else
  call publisher POST /pypi/pypi-local/ -F ':action=file_upload' -F 'protocol_version=1' -F 'metadata_version=2.1' \
    -F 'name=acme-inventory-mcp' -F 'version=1.0.0' -F 'filetype=bdist_wheel' -F 'pyversion=py3' \
    -F "sha256_digest=$wsha" -F "content=@$whl" >/dev/null
  echo "  POST /pypi/pypi-local/ (publisher): HTTP $(code) $(head -c 200 "$FOUT/.body")"
fi

say "3b. the agent image: every package of agent/requirements.lock through the pypi Virtual"
[[ -s "$ROOT/agent/requirements.lock" ]] || "$ROOT/agent/lock.sh"
"$ROOT/agent/build.sh" 2>&1 | grep -vE '^(STEP|COPY|--> |Getting image|Copying|Writing manifest|Storing signatures)' | tail -12

say "4a. com.acme/inventory 1.0.0 to mcp-internal (publisher)"
call publisher GET /mcp/mcp-internal/v0.1/servers/com.acme%2Finventory/versions/1.0.0 >/dev/null
if [[ $(code) == 200 ]]; then echo "  already published: skipped"; else
  show publisher POST /mcp/mcp-internal/v0.1/publish -H 'Content-Type: application/json' --data-binary "@$ROOT/tools/acme-inventory/server.json" | head -c 400; echo
fi

say "4b. mcp-official: seed io.github.daedalus/mcp-sqlite3 0.1.3 from registry.modelcontextprotocol.io"
# A targeted seed (#5408): the Remote fetches this one name and version from the official
# registry, records it in its catalog, pins it (an approved pin, as POST catalog/pins) and
# ingests it, through the same outbound path as a sync (ledger, UPSTREAM_FETCHED). No full
# catalog sync is needed: the official registry is about 2,200 pages, which a first sync
# takes several 200-page passes to read.
CAT=/repositories/mcp-official/mcp
while IFS=$'\t' read -r name ver; do
  api POST "$CAT/seed" -d "$(jq -nc --arg n "$name" --arg v "$ver" '{servers:[{name:$n,version:$v}],reason:"reviewed for the off-grid site: local SQLite only, no network"}')" >/dev/null
  echo "  POST /api/v1$CAT/seed $name@$ver: HTTP $(code) $(jq -c '{jobId, status, total}' "$FOUT/.body" 2>/dev/null)"
  surl=$(jq -r '.statusUrl // empty' "$FOUT/.body" 2>/dev/null || true)
  [[ -n $surl ]] || echo "  no seed job: this backend has no POST .../mcp/seed (artifact-keeper#5408, main at 88f23c51 or later); gates G1 and G4 will report $name missing"
  for _ in $(seq 120); do
    [[ -n $surl ]] || break
    call admin GET "$surl" >/dev/null
    jq -e '.status == "completed" or .status == "failed"' "$FOUT/.body" >/dev/null && break
    sleep 2
  done
  jq -c '{status, items: [.items[]? | {name, version, state, reason}]}' "$FOUT/.body" 2>/dev/null || true
  show developer GET "/mcp/mcp-all/v0.1/servers/$(jq -rn --arg n "$name" '$n|@uri')/versions/$ver" | head -c 300; echo
done < <(manifest '.mcp[] | select(.repo == "mcp-official") | [.name, .version] | @tsv')

say "5. offgrid-ops 1.0.0: publish to plugins-central, read it through the plugins Remote"
mkdir -p "$ROOT/out/dist"
zipf="$ROOT/out/dist/offgrid-ops-1.0.0.zip"
python3 -I - "$ROOT/plugins/offgrid-ops" "$zipf" <<'PY'
import pathlib, sys, zipfile
src, out = pathlib.Path(sys.argv[1]), sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
    for p in sorted(x for x in src.rglob("*") if x.is_file()):
        zi = zipfile.ZipInfo(str(p.relative_to(src)), date_time=(2026, 11, 1, 0, 0, 0))
        zi.external_attr = 0o644 << 16; zi.compress_type = zipfile.ZIP_STORED
        z.writestr(zi, p.read_bytes())
PY
psha=$(sha256sum "$zipf" | cut -d' ' -f1)
call publisher GET /agentplugins/plugins-central/offgrid-ops/index.json >/dev/null
if [[ $(code) == 200 ]] && jq -e '.versions[] | select(.version == "1.0.0")' "$FOUT/.body" >/dev/null; then
  echo "  offgrid-ops 1.0.0 is already in plugins-central: skipped"
else
  call publisher PUT /agentplugins/plugins-central/offgrid-ops/1.0.0/offgrid-ops-1.0.0.zip \
    -H "X-Checksum-Sha256: $psha" -H 'Content-Type: application/zip' --data-binary "@$zipf" >/dev/null
  echo "  PUT plugins-central/offgrid-ops/1.0.0/offgrid-ops-1.0.0.zip: HTTP $(code) $(jq -c '{sha256, marketplace_name}' "$FOUT/.body" 2>/dev/null)"
fi
for _ in $(seq 30); do  # the hosted version is listed once its scan clears it
  call developer GET /agentplugins/plugins-central/offgrid-ops/index.json >/dev/null
  [[ $(code) == 200 ]] && jq -e '.latest == "1.0.0"' "$FOUT/.body" >/dev/null && break; sleep 2
done
for doc in marketplace.json offgrid-ops/index.json; do
  call developer GET "/agentplugins/plugins/$doc" >/dev/null
  echo "  GET plugins/$doc (through the Remote): HTTP $(code)"
done
call developer GET /agentplugins/plugins/offgrid-ops/1.0.0/offgrid-ops-1.0.0.zip -o "$FOUT/plugin.zip" >/dev/null
echo "  GET plugins/offgrid-ops/1.0.0/offgrid-ops-1.0.0.zip: HTTP $(code), sha256 $(sha256sum "$FOUT/plugin.zip" | cut -c1-16) (published $(echo "$psha" | cut -c1-16))"

say "6. pi (step 6): its image installs pi through npm-remote"
"$ROOT/pi/build.sh" 2>&1 | grep -vE '^(STEP|COPY|--> |Getting image|Copying|Writing manifest|Storing signatures)' | tail -6


say "what went out while seeding"
echo "  ledger: $(( $(ledger_lines) - l0 )) connections opened (out/ledger/ledger.jsonl), by host:"
jq -r --arg t "$t0" 'select(.t >= $t and .event == "open") | .host' "$LEDGER_FILE" | sort | uniq -c | sort -rn | sed 's/^/    /'
echo "  UPSTREAM_FETCHED audit rows since $t0: $(audit_count UPSTREAM_FETCHED "$t0")"
