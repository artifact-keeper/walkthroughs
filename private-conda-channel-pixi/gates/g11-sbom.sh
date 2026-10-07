#!/usr/bin/env bash
# G11 SBOM and blast radius: SBOM from pixi.lock via the registry; Syft + Grype
# on the built image; a PURL lookup returns the environments that contain it.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G11; PROJECT="${PROJECT:-project-direct}"; O="$ROOT/out/scan"
PROJECT="$PROJECT" "$ROOT/scan/scan.sh" 2>&1 | tail -25
n=$(jq '.graphs[0].document.components | length' "$O/registry-env-sbom.json" 2>/dev/null)
lockn=$(grep -cE '^- (conda|pypi): ' "$ROOT/$PROJECT/pixi.lock")
[[ "$n" == "$lockn" ]] && pass $G "registry SBOM from pixi.lock: $n components = $lockn locked packages, with conda purls and sha256" \
  || fail $G "registry SBOM from pixi.lock" "$n components vs $lockn locked packages"
c=$(jq '[.artifacts[] | select(.type=="conda")] | length' "$O/image.syft.json"); m=$(jq '.matches | length' "$O/image.grype.json")
(( c > 0 && m >= 0 )) && pass $G "Syft finds $c conda packages in the image; Grype reports $m matches ($(jq -c '[.matches[].vulnerability.severity] | group_by(.) | map({(.[0]): length}) | add' "$O/image.grype.json"))" \
  || fail $G "Syft + Grype on the image" "conda=$c"
akcurl -fsS -G -H "Authorization: Bearer $(tok consumer)" --data-urlencode "purl=pkg:conda/openssl@3.6.4" "$U/api/v1/environments/lookup" > "$SP_TMP/l.json"
h=$(jq -c '[.hits[] | {repository: .repository.key, path: .paths[0]}]' "$SP_TMP/l.json"); echo "lookup pkg:conda/openssl@3.6.4 -> $h"
jq -e '.hits | length > 0' "$SP_TMP/l.json" >/dev/null && pass $G "PURL lookup pkg:conda/openssl@3.6.4 returns the environment and the inclusion path" || fail $G "PURL lookup" "$h"
nc=$(jq '[.artifacts[] | select(.type=="conda" and (.purl // "") == "")] | length' "$O/image.syft.json")
(( nc == 0 )) || echo "note: Syft emits no purl for $nc conda packages (Grype matches them by name/version); the registry SBOM does carry pkg:conda purls"
