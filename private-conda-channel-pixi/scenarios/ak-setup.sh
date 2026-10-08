#!/usr/bin/env bash
# Artifact Keeper side of the scenario suite. Idempotent; creates only scn-* objects.
#   scn-virtual      virtual  conda-internal (1), conda-fake-upstream (2), conda-forge (3):
#                    conda-virtual with a hostile public member added (S1, S4, S7)
#                    conda-fake-upstream is G4's remote (http://fake-upstream:8000, gates/fake-upstream.sh,
#                    acme-core 99.0.0). Not scn-fake-forge: Artifact Keeper refuses remote upstreams on
#                    private addresses (SSRF guard) except AK_SSRF_ALLOW_PRIVATE_CIDRS, which this stack
#                    sets to the gate's fake upstream only (172.31.40.200/32):
#                      HTTP 400 Upstream URL IP '172.31.40.151' is not allowed (private/internal network)
#   scn-virtual-ci   virtual  conda-internal (1), conda-forge (2), no allowlist:
#                    the unfiltered twin a CI job solves against (S6, allowlist-ci.sh)
#   scenarios/.tokens/scn-reader.token   user token of "consumer", read:artifacts, selector:
#                    the consumer repositories plus the three above; Nexus's upstream
#                    credential for ak-scn-virtual, and the CI solve's credential
#   scenarios/.tokens/scn-reader-auth.json   the same as a RATTLER_AUTH_FILE
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
code() { akapi "$@" -o "$WORK/ak-setup.body" -w '%{http_code}'; }
ensure() { # KEY JSON
  [[ $(code GET "/repositories/$1") == 200 ]] && { log "$1 exists"; return 0; }
  local c; c=$(code POST /repositories -d "$2")
  [[ $c =~ ^20 ]] || { echo "ak-setup.sh: create $1: HTTP $c $(head -c 300 "$WORK/ak-setup.body")" >&2; exit 1; }
  log "created $1"
}
"$ROOT/gates/fake-upstream.sh" up >/dev/null
[[ $(code GET /repositories/conda-fake-upstream) == 200 ]] || { c=$(code POST /repositories -d '{"key":"conda-fake-upstream","name":"gate: fake public upstream","format":"conda","repo_type":"remote","visibility":"internal","upstream_url":"http://fake-upstream:8000"}'); log "created conda-fake-upstream (as G4 does): HTTP $c"; }
ensure scn-virtual '{"key":"scn-virtual","name":"scenario: conda-virtual plus a hostile public member","format":"conda","repo_type":"virtual","visibility":"internal","member_repos":[{"repo_key":"conda-internal","priority":1},{"repo_key":"conda-fake-upstream","priority":2},{"repo_key":"conda-forge","priority":3}]}'
ensure scn-virtual-ci '{"key":"scn-virtual-ci","name":"scenario: unfiltered twin of conda-virtual for CI solves","format":"conda","repo_type":"virtual","visibility":"internal","member_repos":[{"repo_key":"conda-internal","priority":1},{"repo_key":"conda-forge","priority":2}]}'

T="$SCN_TOKENS/scn-reader.token"
ok() { [[ -s "$T" ]] && [[ $(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(<"$T")" "$U/conda/scn-virtual-ci/channeldata.json") == 200 ]]; }
if ok; then log "scn-reader.token still valid"; else
  ids=$(for k in conda-virtual conda-internal conda-forge pypi-remote scn-virtual scn-virtual-ci conda-fake-upstream; do
          akapi GET "/repositories/$k" | jq -r .id; done | jq -R . | jq -sc .)
  # Minted by the consumer itself: admin minting for another user rejects repo_selector (C14).
  CJWT=$(akcurl -fsS -X POST "$U/api/v1/auth/login" -H 'Content-Type: application/json' \
         -d "$(jq -nc --arg p "$(<"$TOKENS/consumer.password")" '{username:"consumer",password:$p}')" | jq -r .access_token)
  r=$(akcurl -sS -X POST "$U/api/v1/auth/tokens" -H "Authorization: Bearer $CJWT" -H 'Content-Type: application/json' \
      -w '\n%{http_code}' -d "$(jq -nc --argjson ids "$ids" \
      '{name:"scn-reader",scopes:["read:artifacts"],expires_in_days:30,repo_selector:{match_repos:$ids}}')")
  [[ ${r##*$'\n'} =~ ^20 ]] || { echo "ak-setup.sh: scn-reader token: HTTP ${r##*$'\n'}" >&2; exit 1; }
  (umask 077; jq -r .token <<<"${r%$'\n'*}" > "$T")
  ok || { echo "ak-setup.sh: scn-reader.token cannot read scn-virtual-ci" >&2; exit 1; }
  log "minted scenarios/.tokens/scn-reader.token (user consumer, read:artifacts, consumer repos + scn-*)"
fi
(umask 077; jq -n --arg h "$AK_HOST" --arg t "$(<"$T")" '{($h): {BearerToken: $t}}' > "$SCN_TOKENS/scn-reader-auth.json")
