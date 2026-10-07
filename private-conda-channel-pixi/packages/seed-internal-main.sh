#!/usr/bin/env bash
# WORKAROUND for Artifact Keeper main (5e351fc) only. Not part of the walkthrough.
#
# On main, promotion conda-staging -> conda-internal loses the conda metadata
# (repodata shows build "0", depends [], license "", md5 ""; rattler then fails
# with "failed to parse digest"), and the release gate cannot see a CEP-27
# attestation (key-based bundles are refused at upload). Both are fixed in the
# 1.11.0 branch (F6, F7, F9). Until then, to exercise everything downstream
# (lock, image, scanning), this script puts the packages into conda-internal
# directly: it lifts promotion_only, deletes any promoted copies, uploads with
# the admin token, and restores promotion_only. The fixed backend uses
# packages/promote.sh instead.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"; load_env
U=$(AK_HOST_URL); A=(-H "Authorization: Bearer $(admin_token)" -H 'Content-Type: application/json')
patch() { akcurl -sS -o /dev/null -w "seed: conda-internal promotion_only=$1 HTTP %{http_code}\n" -X PATCH "${A[@]}" \
            -d "{\"promotion_only\":$1}" "$U/api/v1/repositories/conda-internal"; }
patch false
trap 'patch true' EXIT
mapfile -t files < <(cd "$HERE/out" && ls -1 */*.conda)
for rel in "${files[@]}"; do
  akcurl -sS -o /dev/null -w "seed: delete conda-internal/$rel HTTP %{http_code}\n" -X DELETE "${A[@]}" \
    "$U/api/v1/repositories/conda-internal/artifacts/$rel"
  akcurl -sS -o /dev/null -w "seed: PUT conda-internal/$rel HTTP %{http_code}\n" -X PUT \
    -H "Authorization: Bearer $(admin_token)" --data-binary "@$HERE/out/$rel" "$U/conda/conda-internal/$rel"
done
