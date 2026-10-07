#!/usr/bin/env bash
# Publish built packages to conda-staging with `rattler-build upload artifactory`
# (Artifact Keeper accepts the Artifactory-style PUT /conda/<repo>/<subdir>/<file>).
# Runs in the pixi client container on ak-conda-net; the CI token (repo token,
# write on conda-staging only) is the only credential, via RATTLER_AUTH_FILE.
#
# Usage: packages/publish.sh [file.conda...]   (default: everything in packages/out)
# Env:   CHANNEL (default conda-staging)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"
CHANNEL="${CHANNEL:-conda-staging}"
files=("$@")
if ((${#files[@]} == 0)); then mapfile -t files < <(cd "$HERE/out" && ls -1 */*.conda); fi
rc=0
for f in "${files[@]}"; do
  f="${f#"$HERE/out/"}"
  echo "publish: $f -> $CHANNEL"
  podman run --rm --network "$NET" \
    -v ak-conda-pixi-cache:/cache \
    -v "$HERE/out:/out:ro,z" \
    -v "$TOKENS/ci-auth.json:/run/secrets/rattler-auth.json:ro,z" \
    -e RATTLER_AUTH_FILE=/run/secrets/rattler-auth.json \
    localhost/ak-conda/pixi-client:0.81.0 \
    pixi exec --spec "rattler-build==${RATTLER_BUILD_VERSION:-0.76.1}" -- \
      rattler-build upload artifactory --log-style plain \
        --url "$AK_URL/conda" --channel "$CHANNEL" "/out/$f" || rc=1
done
exit $rc
