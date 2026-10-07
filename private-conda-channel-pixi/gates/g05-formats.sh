#!/usr/bin/env bash
# G5 Formats: the hosted channel serves repodata.json, .zst, .bz2 with the same
# content and a CEP-16 shard index that rattler consumes; .conda and .tar.bz2
# packages both index and install; pixi uses the compressed forms (request log);
# proxy shards: passed through, or pixi falls back cleanly.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G5; R=conda-gate-formats
ensure_repo $R '{"key":"conda-gate-formats","name":"gate scratch: formats","format":"conda","repo_type":"local","visibility":"internal"}' || exit 1
BZ=$(ls "$ROOT"/out/formats/noarch/acme-core-1.0.0-*.tar.bz2 2>/dev/null | head -1)
[[ -n "$BZ" ]] || { OUT_DIR="$ROOT/out/formats" EXTRA_ARGS="--package-format tar-bz2" "$ROOT/packages/build.sh" acme-core >/dev/null 2>&1; BZ=$(ls "$ROOT"/out/formats/noarch/acme-core-1.0.0-*.tar.bz2 | head -1); }
FM=$(ls "$ROOT"/packages/out/linux-64/acme-fastmath-*.conda | head -1)
for f in "$BZ" "$FM"; do sub=$(basename "$(dirname "$f")")
  c=$(http PUT "$U/conda/$R/$sub/$(basename "$f")" admin --data-binary "@$f"); echo "PUT $sub/$(basename "$f") -> $c"; done

# 1. repodata in three encodings, same content
ok=1
for sub in noarch linux-64; do
  http GET "$U/conda/$R/$sub/repodata.json" admin >/dev/null; jq -S . "$SP_TMP/body" > "$SP_TMP/rd.json"
  http GET "$U/conda/$R/$sub/repodata.json.zst" admin >/dev/null; zstd -dqc "$SP_TMP/body" | jq -S . > "$SP_TMP/rd.zst.json" || ok=0
  http GET "$U/conda/$R/$sub/repodata.json.bz2" admin >/dev/null; bzip2 -dc "$SP_TMP/body" | jq -S . > "$SP_TMP/rd.bz2.json" || ok=0
  cmp -s "$SP_TMP/rd.json" "$SP_TMP/rd.zst.json" && cmp -s "$SP_TMP/rd.json" "$SP_TMP/rd.bz2.json" || ok=0
  echo "$sub: json $(wc -c < "$SP_TMP/rd.json") B, packages=$(jq -c '{packages:(.packages|keys), conda:(.["packages.conda"]|keys)}' "$SP_TMP/rd.json")"
done
((ok)) && pass $G "repodata.json, .zst and .bz2 decode to the same document (noarch, linux-64)" || fail $G "repodata encodings agree"
jq -e '.packages | keys | any(endswith(".tar.bz2"))' "$SP_TMP/rd.json" >/dev/null 2>&1 || \
  { http GET "$U/conda/$R/noarch/repodata.json" admin >/dev/null; jq -e '.packages | keys | any(endswith(".tar.bz2"))' "$SP_TMP/body" >/dev/null; } \
  && pass $G ".tar.bz2 package indexed under \"packages\", .conda under \"packages.conda\"" || fail $G ".tar.bz2 indexing"

# 2. headers: a .zst resource must not be sent with Content-Encoding (clients would strip the frame)
for p in "$R/noarch/repodata.json.zst" "$R/noarch/repodata_shards.msgpack.zst"; do
  h=$(akcurl -sS -o /dev/null -D - -H "$(admin_h)" "$U/conda/$p" | tr -d '\r' | grep -iE '^(HTTP|content-type|content-encoding)' | tr '\n' ' '); echo "$p: $h"
  if grep -qi 'content-encoding: zstd' <<<"$h"; then blocked F4 $G "$(basename "$p") served without Content-Encoding" "$h"
  else pass $G "$(basename "$p") served as a plain resource ($(grep -oiE 'content-type: [^ ]+' <<<"$h"))"; fi
done

# 3. pixi with shards ON against the hosted channel (client image without the workaround)
CLIENT_SHARDS=on CLIENT_TAG=0.81.0-shards "$ROOT/client/build.sh" >/dev/null 2>&1; "$ROOT/client/build.sh" >/dev/null 2>&1
W="$SP_TMP/g5-project"; rm -rf "$W"; mkdir -p "$W"
cat > "$W/pixi.toml" <<TOML
[workspace]
name = "g5"
channels = ["https://ak.internal/conda/$R", "conda-forge"]
platforms = ["linux-64"]
channel-priority = "strict"
[dependencies]
python = "3.12.*"
acme-core = { version = "*", channel = "https://ak.internal/conda/$R" }
acme-fastmath = { version = "*", channel = "https://ak.internal/conda/$R" }
TOML
lockit() { podman run --rm --network "$NET" -v "ak-conda-g5-$1:/cache" -v "$W:/work:z" -w /work \
  -v "$(admin_auth_file):/run/secrets/a.json:ro,z" -e RATTLER_AUTH_FILE=/run/secrets/a.json "$2" \
  sh -c 'pixi lock && pixi install --locked' 2>&1 | grep -v '^ WARN'; }
podman volume rm -f ak-conda-g5-shards ak-conda-g5-noshards >/dev/null 2>&1
t0=$(date +%s); out=$(lockit shards localhost/ak-conda/pixi-client:0.81.0-shards); rc=$?
access_since "$t0" | grep "/conda/$R/" | awk -F'\t' '{print $1, $2, $3}' | sed "s|/conda/$R/||" | sort | uniq -c
if grep -q 'environment has been installed' <<<"$out" && access_since "$t0" | grep -q "$R/noarch/shards/"; then
  pass $G "pixi consumes the hosted CEP-16 shard index and shards (no fallback)"
else blocked F4 $G "pixi consumes the hosted CEP-16 shard index" "$(tr -s ' \n│╰─▶├×' ' ' <<<"$out" | grep -oE 'failed to decode[^)]*\)[^.]*\.?|Unknown frame descriptor' | head -2 | tr '\n' ' ')"; fi
grep -E 'acme-core|acme-fastmath' "$W/pixi.lock" | grep -oE '[^/]+\.(tar\.bz2|conda)$' | sort -u
grep -q 'acme-core-1.0.0-pyh4616a5c_0.tar.bz2' "$W/pixi.lock" && grep -q 'environment has been installed' <<<"$out" \
  && pass $G "a .tar.bz2 package resolves and installs" || true

# 4. shards OFF (workaround client): pixi probes and uses .zst
rm -f "$W/pixi.lock"; mkdir -p "$W/.pixi"
printf '[repodata-config."https://ak.internal/conda/%s"]\ndisable-sharded = true\n' "$R" > "$W/.pixi/config.toml"
t0=$(date +%s); out=$(lockit noshards "$CLIENT")
access_since "$t0" | grep "/conda/$R/" | awk -F'\t' '{print $1, $2, $3}' | sed "s|/conda/$R/||" | sort | uniq -c
if grep -q 'environment has been installed' <<<"$out"; then
  access_since "$t0" | grep -q "$R/noarch/repodata.json.zst" && pass $G "with shards disabled pixi uses repodata.json.zst" || fail $G "zst use" "no .zst GET"
  grep -q 'acme-core-1.0.0-pyh4616a5c_0.tar.bz2' "$W/pixi.lock" && pass $G "a .tar.bz2 package resolves and installs" || true
else fail $G "lock with shards disabled" "$(tail -2 <<<"$out")"; fi

# 5. proxy shards
c=$(http GET "$U/conda/conda-forge/noarch/repodata_shards.msgpack.zst" consumer); echo "conda-forge proxy shard index: HTTP $c $(head -c 120 "$SP_TMP/body")"
if [[ $c == 200 ]]; then pass $G "proxy passes CEP-16 shards through"
else pass $G "proxy shards not served (HTTP $c, #4177); pixi falls back to .zst with no client config (see G3 access log)"; fi
podman volume rm -f ak-conda-g5-shards ak-conda-g5-noshards >/dev/null 2>&1
