#!/usr/bin/env bash
# G10 Cooldown: repodata carries a server-set indexed_timestamp (CEP-47); pixi's
# exclude-newer excludes a package indexed minutes ago. Scratch repo
# conda-gate-cooldown holds acme-core 1.0.0 (built hours ago), and per run
# 1.<epoch>.0 (built now) and 1.<epoch+1>.0 (built now, its build timestamp
# rewritten to 30 days ago: the publisher controls that field, which is why
# the server must set its own).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G10; R=conda-gate-cooldown; O="$ROOT/out/g10"
ensure_repo $R '{"key":"conda-gate-cooldown","name":"gate scratch: cooldown","format":"conda","repo_type":"local","visibility":"internal"}' || exit 1
# Fresh versions every run: deleted names cannot be re-uploaded (immutable), and
# the "new" package must really be minutes old.
N=$(date +%s); NEW="1.$N.0"; OLDDATED="1.$((N + 1)).0"
rm -rf "$O"
OUT_DIR="$O" ACME_CORE_VERSION=$NEW "$ROOT/packages/build.sh" acme-core >/dev/null 2>&1
OUT_DIR="$O" ACME_CORE_VERSION=$OLDDATED "$ROOT/packages/build.sh" acme-core >/dev/null 2>&1
f=$(ls "$O"/noarch/acme-core-$OLDDATED-*.conda); "$GATES_DIR/backdate-conda.sh" "$f" "$f.tmp" $(( ($(date +%s) - 30*86400) * 1000 )) && mv "$f.tmp" "$f"
echo "this run: $NEW built now, $OLDDATED built now with its timestamp set 30 days back"
for f in "$ROOT/packages/out/noarch/acme-core-1.0.0-pyh4616a5c_0.conda" "$O"/noarch/acme-core-*.conda; do
  c=$(http PUT "$U/conda/$R/noarch/$(basename "$f")" admin --data-binary "@$f"); echo "PUT $(basename "$f") -> $c"; done
http GET "$U/conda/$R/noarch/repodata.json" admin >/dev/null
body | jq -r '.["packages.conda"][] | "\(.version)\tbuild timestamp \(.timestamp // "-") (\((.timestamp // 0)/1000 | todate))\tindexed_timestamp \(.indexed_timestamp // "absent")"'
tot=$(body | jq '.["packages.conda"] | length'); n=$(body | jq '[.["packages.conda"][] | select(.indexed_timestamp != null)] | length')
if [[ $n -ge 3 && $n == "$tot" ]]; then
  body | jq -e --arg v "$OLDDATED" '[.["packages.conda"][] | select(.version==$v) | (now*1000 - .indexed_timestamp) < 86400000] | all' >/dev/null \
    && pass $G "every record carries a server-set indexed_timestamp (the backdated $OLDDATED shows its real index time)" \
    || fail $G "indexed_timestamp reflects index time" "$(body | jq -c '[.["packages.conda"][] | {version, indexed_timestamp}]')"
else blocked F10 $G "records carry a server-set indexed_timestamp" "absent on $(( tot - n )) of $tot records"; fi

W="$SP_TMP/g10-project"; rm -rf "$W"; mkdir -p "$W/.pixi"
printf '[repodata-config."https://ak.internal/conda/%s"]\ndisable-sharded = true\n' "$R" > "$W/.pixi/config.toml"
solve() { # exclude-newer [acme-core spec] -> acme-core version chosen
  cat > "$W/pixi.toml" <<TOML
[workspace]
name = "g10"
channels = ["https://ak.internal/conda/$R", "conda-forge"]
platforms = ["linux-64"]
channel-priority = "strict"
exclude-newer = "$1"
[dependencies]
python = "3.12.*"
acme-core = { version = "${2:-*}", channel = "https://ak.internal/conda/$R" }
[exclude-newer]
python = "0d"
TOML
  rm -f "$W/pixi.lock"
  podman run --rm --network "$NET" -v ak-conda-g10-cache:/cache -v "$W:/work:z" -w /work \
    -v "$(admin_auth_file):/run/secrets/a.json:ro,z" -e RATTLER_AUTH_FILE=/run/secrets/a.json "$CLIENT" pixi lock >/dev/null 2>&1
  grep -m1 -oE '^- conda: https://[^ ]*/acme-core-[^-]+-' "$W/pixi.lock" 2>/dev/null | sed -E 's/.*acme-core-([^-]+)-$/\1/'
}
podman volume rm -f ak-conda-g10-cache >/dev/null 2>&1   # repodata must not come from a client cache
v0=$(solve 0d); v1=$(solve 1h "1.0.0|$NEW"); v2=$(solve 1h)
echo "exclude-newer 0d -> acme-core $v0; 1h with acme-core 1.0.0|$NEW -> $v1; 1h unrestricted -> $v2"
[[ $v0 == "$OLDDATED" ]] || fail $G "setup: 0d solve picks the newest" "$v0"
[[ $v1 == 1.0.0 ]] && pass $G "exclude-newer 1h excludes acme-core $NEW built minutes ago (picks 1.0.0)" \
  || fail $G "exclude-newer 1h excludes a package built minutes ago" "picked $v1"
if [[ $v2 == 1.0.0 ]]; then pass $G "exclude-newer excludes a backdated package indexed minutes ago"
elif [[ $v2 == "$OLDDATED" ]]; then fail $G "exclude-newer excludes a backdated package indexed minutes ago" "pixi picked $OLDDATED: it filters on the publisher-set build timestamp; the server-set indexed_timestamp is not used by pixi 0.81.0 (conda/ceps#154)"
else fail $G "exclude-newer solve" "$v2"; fi
