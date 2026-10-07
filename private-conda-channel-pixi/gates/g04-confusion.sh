#!/usr/bin/env bash
# G4 Dependency confusion: acme-core 99.0.0 published on the remote member's
# upstream must not be offered by the virtual channel, and the solve keeps the
# internal version.
#   conda-fake-upstream  remote -> http://fake-upstream:8000 (gates/fake-upstream.sh)
#   conda-virtual-g4     virtual: conda-internal (1), conda-fake-upstream (2)
# The production conda-virtual has conda-forge as its remote member; the test
# uses a channel we control so that "the public channel publishes our name" can
# be staged.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G4
"$GATES_DIR/fake-upstream.sh" up
ensure_repo conda-fake-upstream '{"key":"conda-fake-upstream","name":"gate: fake public upstream","format":"conda","repo_type":"remote","visibility":"internal","upstream_url":"http://fake-upstream:8000"}' || exit 1
ensure_repo conda-virtual-g4 '{"key":"conda-virtual-g4","name":"gate: virtual with a hostile upstream","format":"conda","repo_type":"virtual","visibility":"internal","member_repos":[{"repo_key":"conda-internal","priority":1},{"repo_key":"conda-fake-upstream","priority":2}]}' || exit 1

c=$(http GET "$U/conda/conda-fake-upstream/noarch/repodata.json" admin); echo "remote member alone: HTTP $c, acme-core versions: $(body | jq -c '[.["packages.conda"][]?, .packages[]? | select(.name=="acme-core") | .version]' 2>/dev/null)"
[[ $c == 200 ]] && body | jq -e '[.["packages.conda"][] | select(.name=="acme-core" and .version=="99.0.0")] | length == 1' >/dev/null \
  || { fail $G "setup: the remote member serves acme-core 99.0.0" "HTTP $c $(body | head -c 200)"; exit 0; }

c=$(http GET "$U/conda/conda-virtual-g4/noarch/repodata.json" admin)
vers=$(body | jq -c '[(.["packages.conda"] // {}), (.packages // {}) | .[] | select(.name=="acme-core") | .version] | sort')
echo "conda-virtual-g4 noarch/repodata.json: HTTP $c, acme-core versions offered: $vers"
if [[ $c == 200 && "$vers" == '["1.0.0"]' ]]; then pass $G "virtual channel offers only the hosted acme-core ($vers)"
elif [[ $c == 200 ]] && grep -q '99.0.0' <<<"$vers"; then blocked F1 $G "virtual channel offers only the hosted acme-core" "offers $vers"
else fail $G "virtual channel repodata" "HTTP $c $vers"; fi

# Solve: a project that names acme-core without pinning its channel.
W="$SP_TMP/g4-project"; rm -rf "$W"; mkdir -p "$W"
cat > "$W/pixi.toml" <<TOML
[workspace]
name = "g4"
channels = ["https://ak.internal/conda/conda-virtual-g4", "conda-forge"]
platforms = ["linux-64"]
channel-priority = "strict"
[dependencies]
python = "3.12.*"
acme-core = "*"
TOML
out=$(podman run --rm --network "$NET" -v ak-conda-pixi-cache:/cache -v "$W:/work:z" -w /work \
  -v "$(admin_auth_file):/run/secrets/a.json:ro,z" -e RATTLER_AUTH_FILE=/run/secrets/a.json "$CLIENT" \
  pixi lock 2>&1 | grep -v '^ WARN')
got=$(grep -m1 -oE '^- conda: https://[^ ]*/acme-core-[^-]+-' "$W/pixi.lock" 2>/dev/null | sed -E 's/.*acme-core-([^-]+)-$/\1/')
src=$(grep -m1 -oE '^- conda: https://[^ ]*acme-core-[^ ]*' "$W/pixi.lock" 2>/dev/null | cut -c10-)
echo "solve (unpinned acme-core): version ${got:-none} from ${src:-?}"; [[ -z "$got" ]] && echo "$out" | tail -4
if [[ "$got" == 1.0.0 ]]; then pass $G "unpinned solve through the virtual channel keeps acme-core 1.0.0"
elif [[ "$got" == 99.0.0 ]]; then blocked F1 $G "unpinned solve keeps the internal acme-core" "solver picked 99.0.0 from the virtual channel"
else fail $G "unpinned solve" "$(tail -1 <<<"$out")"; fi

# The client-side pin still protects a project that uses it (defence in depth).
sed -i 's|^acme-core = "\*"|acme-core = { version = "*", channel = "https://ak.internal/conda/conda-internal" }|; s|^channels = \[|channels = ["https://ak.internal/conda/conda-internal", |' "$W/pixi.toml"
out=$(podman run --rm --network "$NET" -v ak-conda-pixi-cache:/cache -v "$W:/work:z" -w /work \
  -v "$(admin_auth_file):/run/secrets/a.json:ro,z" -e RATTLER_AUTH_FILE=/run/secrets/a.json "$CLIENT" \
  pixi lock 2>&1 | grep -v '^ WARN')
got=$(grep -m1 -oE '^- conda: https://[^ ]*/acme-core-[^-]+-' "$W/pixi.lock" 2>/dev/null | sed -E 's/.*acme-core-([^-]+)-$/\1/')
src=$(grep -m1 -oE '^- conda: https://[^ ]*acme-core-[^ ]*' "$W/pixi.lock" 2>/dev/null | cut -c10-)
echo "solve (acme-core pinned to conda-internal): ${got:-none} from ${src:-?}"
[[ "$got" == 1.0.0 ]] && pass $G "pinned solve keeps acme-core 1.0.0 (client-side pin)" || fail $G "pinned solve" "${got:-$(tail -1 <<<"$out")}"
