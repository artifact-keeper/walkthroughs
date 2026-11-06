#!/usr/bin/env bash
# List every item of seed/manifest.toml as Artifact Keeper serves it now, with its SHA-256,
# into out/inventory/<label>.tsv (kind, name, sha256, bytes, served from). Run once before the
# disconnect, at the end of make vet (label seed), and once on the site (label site); gate G7e
# diffs the two. Everything
# is fetched as the developer, the way a client would get it:
#   image   HEAD /v2/<repo>/<image>/manifests/<tag>: the manifest digest
#   model   GET /huggingface/hf-hub/<id>/resolve/<commit>/<file> (the seeded cache) and
#           GET /huggingface/hf-models/<id>/resolve/main/<file> (the vetted copy)
#   python  pip download of the lock, --require-hashes --no-deps, in a fresh python container on
#           the stack's network: every wheel and its hash
#   npm     the packument's tarball for each listed version, and its linux-x64 binary package
#   mcp     GET /mcp/mcp-all/v0.1/servers/<name>/versions/<version>: the entry's document
#   plugin  GET /agentplugins/plugins/<name>/<version>/<name>-<version>.zip
#     inventory.sh LABEL
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../flows/lib.sh"
label=${1:?usage: inventory.sh seed|site}
INV="$ROOT/out/inventory"; mkdir -p "$INV"
T="$INV/$label.tsv"; : > "$T.tmp"
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$@" >> "$T.tmp"; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
size_of() { stat -c %s "$1"; }

while IFS=$'\t' read -r repo ref; do
  img=${ref%%[@:]*}
  if [[ $ref == *@* ]]; then tagdig=${ref#*@}; else tagdig=${ref##*:}; fi   # a digest wins over a tag
  call developer HEAD "/v2/$repo/$img/manifests/$tagdig" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' >/dev/null
  d=$(hdr Docker-Content-Digest); row image "$repo/$ref" "${d#sha256:}" "$(hdr Content-Length)" "$repo HTTP $(code)"
done < <(manifest '.image[] | [.repo, .ref] | @tsv')

f="$FOUT/inv.blob"
for file in $(manifest "$(model_sel) | .files[]"); do
  for src in "hf-hub $MODEL_REV" "hf-models main"; do
    read -r repo rev <<<"$src"
    call developer GET "/huggingface/$repo/$MODEL_REPO/resolve/$rev/$file" -o "$f" >/dev/null
    row model "$repo:$MODEL_REPO/$file" "$( [[ $(code) == 200 ]] && sha_of "$f" || echo "-")" "$( [[ $(code) == 200 ]] && size_of "$f" || echo 0)" "$repo@${rev:0:12} HTTP $(code)"
  done
done
rm -f "$f"

wd="$ROOT/out/inventory/wheels-$label"; rm -rf "$wd"; mkdir -p "$wd"
AK_TOKEN=$(tok developer) podman run --rm -i --network "$NET" --userns keep-id:uid=1000,gid=1000 -e AK_TOKEN \
  -v "$CA:/ca.crt:ro,z" -v "$ROOT/agent:/agent:ro,z" -v "$wd:/w:z" \
  "$P/oci-dockerhub/$(manifest '.image[] | select(.name == "python") | .ref')" bash -euc '
  export PIP_CERT=/ca.crt PIP_DISABLE_PIP_VERSION_CHECK=1 HOME=/tmp
  idx="https://developer:$AK_TOKEN@ak.internal/pypi/pypi/simple/"
  pip download -q --require-hashes --no-deps --index-url "$idx" -d /w -r /agent/requirements.lock
  pip download -q --require-hashes --no-deps --index-url "$idx" -d /w -r /agent/requirements-internal.txt' \
  > "$FOUT/inv-pip-$label.log" 2>&1 || { echo "inventory: pip download failed (out/flows/inv-pip-$label.log)"; tail -5 "$FOUT/inv-pip-$label.log"; }
for w in "$wd"/*; do [[ -f $w ]] && row python "$(basename "$w")" "$(sha_of "$w")" "$(size_of "$w")" "pypi"; done

while IFS=$'\t' read -r name ver; do
  for pkg in "$name" "$name-linux-x64"; do
    call developer GET "/npm/npm-remote/$(jq -rn --arg n "$pkg" '$n | sub("/"; "%2f")')" >/dev/null
    tb=$(jq -r --arg v "$ver" '.versions[$v].dist.tarball // empty' "$FOUT/.body" 2>/dev/null)
    if [[ -n $tb ]]; then
      # the tarball URL follows the Host header: https://ak.internal:<port>/npm/npm-remote/...
      akcurl -sS -H "Authorization: Bearer $(tok developer)" -o "$FOUT/inv.tgz" -w '%{http_code}' "$tb" > "$FOUT/.code" || true
      row npm "$pkg@$ver" "$(sha_of "$FOUT/inv.tgz")" "$(size_of "$FOUT/inv.tgz")" "npm-remote HTTP $(code)"
    else
      row npm "$pkg@$ver" "-" 0 "npm-remote packument HTTP $(code)"
    fi
  done
done < <(manifest '.npm[] | [.name, .version] | @tsv')

while IFS=$'\t' read -r name ver; do
  call developer GET "/mcp/mcp-all/v0.1/servers/$(jq -rn --arg n "$name" '$n|@uri')/versions/$ver" >/dev/null
  # The document as served; its _meta carries per-request fields, so hash the server object.
  s=$(jq -cS '.server // .' "$FOUT/.body" 2>/dev/null | sha256sum | cut -d' ' -f1)
  row mcp "$name@$ver" "$( [[ $(code) == 200 ]] && echo "$s" || echo -)" "$(jq -cS '.server // .' "$FOUT/.body" 2>/dev/null | wc -c)" "mcp-all HTTP $(code)"
done < <(manifest '.mcp[] | [.name, .version] | @tsv')

while IFS=$'\t' read -r name ver; do
  call developer GET "/agentplugins/plugins/$name/$ver/$name-$ver.zip" -o "$FOUT/inv.zip" >/dev/null
  row plugin "$name@$ver" "$( [[ $(code) == 200 ]] && sha_of "$FOUT/inv.zip" || echo -)" "$( [[ $(code) == 200 ]] && size_of "$FOUT/inv.zip" || echo 0)" "plugins HTTP $(code)"
done < <(manifest '.plugin[] | [.name, .version] | @tsv')

sort -t$'\t' -k1,1 -k2,2 "$T.tmp" > "$T"; rm -f "$T.tmp"
echo "inventory: $(wc -l < "$T") items in out/inventory/$label.tsv"
awk -F'\t' '{n[$1]++; if ($3 == "-") bad++} END {for (k in n) printf "  %-7s %d\n", k, n[k]; if (bad) printf "  MISSING %d\n", bad}' "$T" | sort
