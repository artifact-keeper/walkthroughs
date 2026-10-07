#!/usr/bin/env bash
# G7 Promotion gate (policy conda-release-gate on conda-staging):
#   - acme-legacy (vendored vulnerable urllib3) is refused on the scan,
#   - acme-copyleft (GPL-3.0-only) is refused on the license,
#   - acme-core 1.0.<epoch> without an attestation is refused on the attestation,
#   - acme-core 1.0.<epoch> with a verified attestation and a clean scan promotes, and
#     conda-internal's repodata keeps its metadata (depends, md5, license, build).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G7; O="$ROOT/out/g7"; mkdir -p "$O"
ls "$ROOT"/out/negative/noarch/acme-legacy-*.conda >/dev/null 2>&1 || RECIPES_DIR="$ROOT/packages/recipes-negative" OUT_DIR="$ROOT/out/negative" "$ROOT/packages/build.sh" >/dev/null 2>&1
# a fresh clean candidate each run (released versions are immutable, even after deletion)
CV="1.0.$(date +%s)"; rm -f "$O"/noarch/acme-core-*.conda
OUT_DIR="$O" ACME_CORE_VERSION=$CV "$ROOT/packages/build.sh" acme-core >/dev/null 2>&1
UV="1.0.$(( $(date +%s) + 1 ))"
OUT_DIR="$O" ACME_CORE_VERSION=$UV "$ROOT/packages/build.sh" acme-core >/dev/null 2>&1
UNATT=$(ls "$O"/noarch/acme-core-$UV-*.conda)
CORE=$(ls "$O"/noarch/acme-core-$CV-*.conda); LEG=$(ls "$ROOT"/out/negative/noarch/acme-legacy-*.conda); GPL=$(ls "$ROOT"/out/negative/noarch/acme-copyleft-*.conda)
art_id() { akcurl -fsS -H "$(admin_h)" "$U/api/v1/repositories/$1/artifacts?per_page=500" | jq -r --arg p "$2" '.items[] | select(.path==$p) | .id'; }
put_staging() { local f=$1 c; c=$(http PUT "$U/conda/conda-staging/noarch/$(basename "$f")" ci --data-binary "@$f"); echo "publish $(basename "$f") -> conda-staging: HTTP $c"; }
promote() { # path -> prints decision, sets PROMOTED and RULES
  local id; id=$(art_id conda-staging "$1")
  [[ -n "$id" ]] || { PROMOTED=missing; RULES=""; echo "  $1 not in staging"; return; }
  http POST "$U/api/v1/promotion/repositories/conda-staging/artifacts/$id/promote" admin -H 'Content-Type: application/json' \
    -d '{"target_repository":"conda-internal","skip_policy_check":false,"notes":"gate G7"}' >/dev/null
  cp "$SP_TMP/body" "$O/promote-$(basename "$1").json"
  PROMOTED=$(jq -r '.promoted' "$SP_TMP/body"); RULES=$(jq -r '[.policy_violations[]? | .message] | join(" | ")' "$SP_TMP/body")
  echo "  promote $1: promoted=$PROMOTED"; jq -r '.policy_violations[]? | "    [\(.severity)] \(.rule): \(.message)"' "$SP_TMP/body"
  jq -r '.gate_results[]? | "    gate \(.rule): \(if .passed then "passed" else "FAILED" end) (\(.reason))"' "$SP_TMP/body"
}
for f in "$LEG" "$GPL" "$CORE" "$UNATT"; do put_staging "$f"; done
# attest all three with the CI key (so each refusal below is about its own rule)
UPLOAD=1 "$ROOT/packages/attest.sh" "$LEG" "$GPL" "$CORE" 2>&1 | sed 's/^/  /' || true
"$ROOT/packages/scan.sh" conda-staging 2>&1 | grep -E "acme-(legacy|copyleft|core-($CV|$UV))" | sed 's/^/  /' | cut -c1-400

promote "noarch/$(basename "$LEG")"
if [[ $PROMOTED == false ]] && grep -qiE 'cve|vulnerab|severity|critical|high' <<<"$RULES"; then pass $G "vulnerable package (acme-legacy) refused on its scan findings"
elif [[ $PROMOTED == false ]]; then fail $G "vulnerable package refused on its scan findings" "refused, but not for vulnerabilities: $RULES"
else fail $G "vulnerable package refused" "promoted"; fi
promote "noarch/$(basename "$GPL")"
if [[ $PROMOTED == false ]] && grep -qi 'licen' <<<"$RULES"; then pass $G "GPL-3.0-only package (acme-copyleft) refused on the license rule"
else fail $G "GPL package refused on the license rule" "promoted=$PROMOTED $RULES"; fi
promote "noarch/$(basename "$UNATT")"
if [[ $PROMOTED == false ]] && grep -qi 'attestation' <<<"$RULES"; then pass $G "un-attested package (acme-core $UV, clean scan) refused on the attestation rule"
else fail $G "un-attested package refused" "promoted=$PROMOTED $RULES"; fi
promote "noarch/$(basename "$CORE")"
if [[ $PROMOTED == true ]]; then
  pass $G "attested, clean acme-core $CV promotes"
  http GET "$U/conda/conda-internal/noarch/repodata.json" consumer >/dev/null
  rec=$(body | jq -c --arg f "$(basename "$CORE")" '.["packages.conda"][$f] | {build,depends,md5,license,noarch}')
  echo "  conda-internal record: $rec"
  jq -e '(.depends|length) > 0 and (.md5|length) == 32 and .license == "Apache-2.0" and (.build|startswith("py"))' <<<"$rec" >/dev/null \
    && pass $G "promoted package keeps its metadata in conda-internal repodata" || blocked F9 $G "promoted package keeps its metadata" "$rec"
  http GET "$U/conda/conda-internal/noarch/$(basename "$CORE")/attestation" consumer >/dev/null && \
    [[ $(jq -r '.mediaType // empty' "$SP_TMP/body") == *sigstore.bundle* ]] && pass $G "the attestation follows the package to conda-internal" \
    || blocked F9 $G "the attestation follows the package to conda-internal" "$(head -c 120 "$SP_TMP/body")"
elif grep -qi 'attestation' <<<"$RULES"; then
  blocked F6,F7 $G "attested, clean acme-core $CV promotes" "$RULES"
  blocked F9 $G "promoted package keeps its metadata in conda-internal repodata" "not reachable: nothing promotable (seen on main: build \"0\", depends [], md5 \"\", license \"\" after a policy-skipping promotion)"
else fail $G "attested, clean acme-core $CV promotes" "$RULES"; fi
