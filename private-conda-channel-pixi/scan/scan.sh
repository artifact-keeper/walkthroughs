#!/usr/bin/env bash
# SBOM, vulnerability scan and blast radius for the built application.
#   1. Syft (+conda-meta-cataloger) and Grype on the image (localhost/acme-analytics:TAG)
#   2. Syft and Grype on the installed environment PROJECT/.pixi/envs/default
#   3. the registry: an environment SBOM from pixi.lock (POST /api/v1/sbom/environment),
#      the lockfile registered as an environment (POST /api/v1/repositories/{key}/environments),
#      and PURL reverse lookups (GET /api/v1/environments/lookup?purl=...)
# Outputs: out/scan/*.json (gitignored) and out/scan/summary.txt
# Env: PROJECT (project-direct), TAG (1.0.0), ENV_REPO (conda-internal), PURLS
# Note: the scanner containers run on the default podman network: Grype downloads
# its vulnerability database from the internet. They are not build clients.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/registry/lib.sh"; load_env
PROJECT="${PROJECT:-project-direct}"; TAG="${TAG:-1.0.0}"; ENV_REPO="${ENV_REPO:-conda-internal}"
O="$ROOT/out/scan"; mkdir -p "$O"; S="$O/summary.txt"; : > "$S"
U=$(AK_HOST_URL)
SYFT=docker.io/anchore/syft:latest; GRYPE=docker.io/anchore/grype:latest
say() { echo "$*" | tee -a "$S"; }

summ() { # name syft.json grype.json
  say "== $1"
  say "  syft packages by type: $(jq -c '[.artifacts[].type] | group_by(.) | map({(.[0]): length}) | add' "$2")"
  say "  conda packages without a purl: $(jq '[.artifacts[] | select(.type=="conda" and (.purl // "") == "")] | length' "$2")"
  say "  grype matches by severity: $(jq -c '[.matches[].vulnerability.severity] | group_by(.) | map({(.[0]): length}) | add // {}' "$3")"
  say "  grype matches by package type: $(jq -c '[.matches[].artifact.type] | group_by(.) | map({(.[0]): length}) | add // {}' "$3")"
  jq -r '.matches[] | select(.artifact.type=="conda" and (.vulnerability.severity=="High" or .vulnerability.severity=="Critical"))
         | "  \(.vulnerability.severity) \(.artifact.name) \(.artifact.version) \(.vulnerability.id) fix=\(.vulnerability.fix.versions|join(","))"' "$3" | sort -u | tee -a "$S"
}

# 1. image
podman save --format oci-archive -o "$O/image.oci.tar" "localhost/acme-analytics:$TAG" >/dev/null 2>&1
podman run --rm -v "$O:/w:z" "$SYFT" oci-archive:/w/image.oci.tar --select-catalogers +conda-meta-cataloger \
  -o syft-json=/w/image.syft.json -o cyclonedx-json=/w/image.cdx.json -q
podman run --rm -v "$O:/w:z" -v ak-conda-grype-db:/.cache/grype "$GRYPE" sbom:/w/image.syft.json -o json --file /w/image.grype.json -q
summ "image localhost/acme-analytics:$TAG" "$O/image.syft.json" "$O/image.grype.json"

# 2. environment directory
if [[ -d "$ROOT/$PROJECT/.pixi/envs/default" ]]; then
  podman run --rm -v "$ROOT/$PROJECT/.pixi/envs/default:/env:ro,z" -v "$O:/w:z" "$SYFT" dir:/env \
    --select-catalogers +conda-meta-cataloger -o syft-json=/w/env.syft.json -q
  podman run --rm -v "$O:/w:z" -v ak-conda-grype-db:/.cache/grype "$GRYPE" sbom:/w/env.syft.json -o json --file /w/env.grype.json -q
  summ "environment $PROJECT/.pixi/envs/default" "$O/env.syft.json" "$O/env.grype.json"
fi

# 3. registry
A=(-H "Authorization: Bearer $(admin_token)")
akcurl -fsS "${A[@]}" -X POST -H 'Content-Type: application/octet-stream' --data-binary "@$ROOT/$PROJECT/pixi.lock" \
  "$U/api/v1/sbom/environment?filename=pixi.lock" -o "$O/registry-env-sbom.json"
say "== registry SBOM from pixi.lock: $(jq -c '{lockfileFormat,sbomFormat,summary,graphs:(.graphs|length),components:(.graphs[0].document.components|length)}' "$O/registry-env-sbom.json")"
say "  sample purl: $(jq -r '.graphs[0].document.components[0]["bom-ref"]' "$O/registry-env-sbom.json")"
akcurl -fsS "${A[@]}" -X POST -H 'Content-Type: application/octet-stream' --data-binary "@$ROOT/$PROJECT/pixi.lock" \
  "$U/api/v1/repositories/$ENV_REPO/environments?filename=pixi.lock&name=acme-analytics" -o "$O/registry-env-register.json"
say "== registered environment: $(jq -c '{id,name,repository,replaced,summary:{distinctPackages:.summary.distinctPackages,edges:.summary.edges}}' "$O/registry-env-register.json")"
read -r -a purls <<<"${PURLS:-pkg:conda/openssl@3.6.4 pkg:conda/acme-core@1.0.0 pkg:pypi/humanize@4.16.0}"
for p in "${purls[@]}"; do
  akcurl -fsS -G -H "Authorization: Bearer $(<"$TOKENS/consumer.token")" --data-urlencode "purl=$p" "$U/api/v1/environments/lookup" > "$O/lookup.json"
  say "  lookup $p (as consumer): $(jq -c '[.hits[] | {repository: .repository.key, path: (.paths[0] // [])}]' "$O/lookup.json")"
done
echo "scan: summary in $S"
