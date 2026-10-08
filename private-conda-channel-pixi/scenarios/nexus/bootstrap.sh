#!/usr/bin/env bash
# Configure scn-nexus through its REST API only. Idempotent.
#   - admin password: the generated one (initial /nexus-data/admin.password is
#     replaced on first run); scenarios/.env SCN_NEXUS_ADMIN_PASSWORD
#   - Community Edition EULA accepted (required before repositories work)
#   - anonymous read on (clients need no Nexus credentials)
#   - the ak.internal CA in Nexus's truststore
#   - SSRF protection: ak.internal and scn-fake-forge allowed (private addresses)
#   - conda repositories:
#       ak-virtual   proxy  -> https://ak.internal/conda/conda-virtual (consumer token, basic auth)
#       ak-internal  proxy  -> https://ak.internal/conda/conda-internal (consumer token, basic auth)
#       ak-scn-virtual proxy -> https://ak.internal/conda/scn-virtual (scenarios/.tokens/scn-reader.token;
#                    conda-virtual plus a hostile member, made by scenarios/ak-setup.sh)
#       cf-direct    proxy  -> https://conda.anaconda.org/conda-forge (no auth)
#       scn-fake     proxy  -> http://scn-fake-forge:8000 (a channel we control; scenarios/fake-forge.sh)
#       nx-hosted    hosted
#       merged       group  [ak-virtual, cf-direct]
#       merged-fake  group  [ak-virtual, scn-fake]   (precedence test)
# Caching (minutes) on the proxies of Artifact Keeper and of scn-fake-forge:
#   NEXUS_METADATA_MAX_AGE (default 2)  repodata*.json, channeldata.json: how long Nexus serves its
#                                       copy before it asks upstream again (conditional GET, AK 304s)
#   NEXUS_NEGATIVE_TTL     (default 2)  how long a 404 from upstream is remembered
#   NEXUS_CONTENT_MAX_AGE  (default 1440) package files (immutable by name, so a day is fine)
#   The REST API has no defaults; the spike used 1440 for all three. 2 minutes is short on purpose:
#   an allowlist change in Artifact Keeper reaches Nexus clients only after Nexus revalidates,
#   so this value IS the policy propagation delay (S1 measures it). The cost is small: a
#   revalidation is a conditional GET that AK answers 304 when nothing changed. cf-direct
#   (conda.anaconda.org) keeps 1440: it is the public source, not the policy channel.
# Env: UPSTREAM_AUTH=basic|bearer (default basic: consumer:<token>. bearer is accepted by
#      the API but Nexus 3.96.4 never sends it for conda; kept to show that), NEXUS_PORT
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
N="http://127.0.0.1:${NEXUS_PORT:-30481}"
ensure_secret SCN_NEXUS_ADMIN_PASSWORD
PW="$SCN_NEXUS_ADMIN_PASSWORD"
nx() { # METHOD PATH [curl args] -> body + code on last line
  local m=$1 p=$2; shift 2
  curl -sS -u "admin:$PW" -X "$m" -H 'Content-Type: application/json' -w '\n%{http_code}' "$N/service/rest$p" "$@"; }
code_of() { echo "${1##*$'\n'}"; }
body_of() { echo "${1%$'\n'*}"; }
need() { [[ $(code_of "$1") =~ ^($2)$ ]] || { echo "nexus/bootstrap.sh: $3: HTTP $(code_of "$1") $(body_of "$1" | head -c 300)" >&2; exit 1; }; }

curl -fsS -o /dev/null "$N/service/rest/v1/status/writable" || { echo "scn-nexus not up; run scenarios/nexus/up.sh" >&2; exit 1; }

# 1. admin password
if [[ $(curl -sS -o /dev/null -w '%{http_code}' -u "admin:$PW" "$N/service/rest/v1/status/check") != 200 ]]; then
  init=$(podman exec scn-nexus cat /nexus-data/admin.password)
  c=$(curl -sS -o /dev/null -w '%{http_code}' -u "admin:$init" -X PUT -H 'Content-Type: text/plain' \
      --data-binary "$PW" "$N/service/rest/v1/security/users/admin/change-password")
  [[ $c == 204 ]] || { echo "change admin password: HTTP $c" >&2; exit 1; }
  log "admin password set (scenarios/.env SCN_NEXUS_ADMIN_PASSWORD)"
fi

# 2. EULA (Community Edition)
r=$(nx GET /v1/system/eula); need "$r" 200 "GET eula"
if [[ $(body_of "$r" | jq -r .accepted) != true ]]; then
  r=$(nx POST /v1/system/eula -d "$(body_of "$r" | jq -c '.accepted = true')"); need "$r" '200|204' "accept eula"
  log "Community Edition EULA accepted"
fi

# 3. anonymous read
r=$(nx PUT /v1/security/anonymous -d '{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}')
need "$r" 200 "anonymous access"

# 4. truststore: the ak.internal CA
fp=$(openssl x509 -in "$CA" -noout -fingerprint -sha1 | cut -d= -f2)
r=$(nx GET /v1/security/ssl/truststore); need "$r" 200 "GET truststore"
if ! body_of "$r" | jq -e --arg fp "$fp" 'any(.[]; .fingerprint == $fp)' >/dev/null; then
  r=$(nx POST /v1/security/ssl/truststore -H 'Content-Type: text/plain' --data-binary @"$CA"); need "$r" '200|201' "add CA to truststore"
  log "ak.internal CA added to the truststore ($fp)"
fi

# 4b. SSRF protection (on by default in 3.96): proxy URLs that resolve to a
# private address are refused at create time. Allow exactly our two hosts by
# name; the guard stays on for everything else.
r=$(nx GET /v1/security/ssrf-protection); need "$r" 200 "GET ssrf-protection"
want=$(body_of "$r" | jq -c '.enabled = true | .allowedDomains = (((.allowedDomains // []) + ["ak.internal","scn-fake-forge"]) | unique)')
have=$(body_of "$r" | jq -c '.allowedDomains // [] | sort')
if [[ "$have" != "$(jq -c '.allowedDomains | sort' <<<"$want")" ]]; then
  r=$(nx PUT /v1/security/ssrf-protection -d "$want"); need "$r" '200|204' "PUT ssrf-protection"
  log "SSRF protection: allowed domains $(jq -c .allowedDomains <<<"$want")"
fi

# 5. repositories (PUT if present, POST if not: the definition here always wins)
auth_json() {
  case "${UPSTREAM_AUTH:-basic}" in
    bearer) jq -nc --arg t "$(consumer_token)" '{type:"bearerToken", bearerToken:$t}' ;;
    basic)  jq -nc --arg t "$(consumer_token)" '{type:"username", username:"consumer", password:$t}' ;;
  esac; }
repo() { # TYPE NAME JSON
  local t=$1 n=$2 j=$3 r
  r=$(nx GET "/v1/repositories/conda/$t/$n")
  if [[ $(code_of "$r") == 200 ]]; then r=$(nx PUT "/v1/repositories/conda/$t/$n" -d "$j"); need "$r" '200|204' "update $n"; log "updated conda $t $n"
  else r=$(nx POST "/v1/repositories/conda/$t" -d "$j"); need "$r" '200|201' "create $n"; log "created conda $t $n"; fi; }
MD_AGE=${NEXUS_METADATA_MAX_AGE:-2} NEG_TTL=${NEXUS_NEGATIVE_TTL:-2} CT_AGE=${NEXUS_CONTENT_MAX_AGE:-1440}
proxy_json() { # NAME URL AUTH_JSON|null [METADATA_MAX_AGE NEGATIVE_TTL]
  jq -nc --arg n "$1" --arg u "$2" --argjson a "$3" --argjson md "${4:-$MD_AGE}" --argjson neg "${5:-$NEG_TTL}" --argjson ct "$CT_AGE" '{
    name:$n, online:true,
    storage:{blobStoreName:"default", strictContentTypeValidation:false},
    proxy:{remoteUrl:$u, contentMaxAge:$ct, metadataMaxAge:$md},
    negativeCache:{enabled:true, timeToLive:$neg},
    httpClient:({blocked:false, autoBlock:true, connection:{useTrustStore:($u | startswith("https://ak.internal")), timeout:600}} + (if $a then {authentication:$a} else {} end))}'; }
A=$(auth_json)
repo proxy ak-virtual  "$(proxy_json ak-virtual  "$AK_URL/conda/conda-virtual"  "$A")"
repo proxy ak-internal "$(proxy_json ak-internal "$AK_URL/conda/conda-internal" "$A")"
[[ -s "$SCN_DIR/.tokens/scn-reader.token" ]] || { echo "nexus/bootstrap.sh: run scenarios/ak-setup.sh first (scn-reader.token)" >&2; exit 1; }
SA=$(jq -nc --arg t "$(<"$SCN_DIR/.tokens/scn-reader.token")" '{type:"username", username:"consumer", password:$t}')
repo proxy ak-scn-virtual "$(proxy_json ak-scn-virtual "$AK_URL/conda/scn-virtual" "$SA")"
repo proxy cf-direct   "$(proxy_json cf-direct https://conda.anaconda.org/conda-forge null 1440 1440)"
repo proxy scn-fake    "$(proxy_json scn-fake http://scn-fake-forge:8000 null)"
repo hosted nx-hosted '{"name":"nx-hosted","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":false,"writePolicy":"allow_once"}}'
repo group merged      '{"name":"merged","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":false},"group":{"memberNames":["ak-virtual","cf-direct"]}}'
repo group merged-fake '{"name":"merged-fake","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":false},"group":{"memberNames":["ak-virtual","scn-fake"]}}'
log "metadata max age ${MD_AGE} min, negative cache ${NEG_TTL} min, content ${CT_AGE} min (AK and scn-fake proxies)"
log "channels (on ak-conda-net): http://scn-nexus:8081/repository/{ak-virtual,ak-internal,ak-scn-virtual,cf-direct,nx-hosted,merged,merged-fake}"
