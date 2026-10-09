#!/usr/bin/env bash
# Configure scn-proget (ProGet Free 26.0.12) for the scenarios. Idempotent.
#
# Before this script: a licence key (UI, once: Administration > Licensing & Activation >
# Request a License Key / paste a key; it is kept in the scn-proget-database volume).
#
#   0. /health is 200 (licensed); otherwise exit 3 with the reason
#   1. API key. A fresh ProGet grants the Anonymous user the Administer task ("the default,
#      out of the box configuration ... intended for demonstration purposes only"), so
#      POST /api/api-keys/create works without credentials until step 2. The key (type
#      System, API "feeds") goes into scenarios/.env as PROGET_API_KEY.
#      UI fallback when anonymous is already locked down: log in as Admin >
#      Administration > Security > API Keys > Create API Key > System, check "Feeds API"
#      (Feeds Management) > Save; paste it into scenarios/.env as PROGET_API_KEY=...
#   2. Lock down (UI only on Free: the users API answers "ProGet Free Edition does not
#      support this API"): proget/secure.py with Playwright changes the Admin password
#      (first run: Admin/Admin) to PROGET_ADMIN_PASSWORD (generated into scenarios/.env)
#      and clicks "Remove Anonymous Access" on Administration > Security > Tasks /
#      Permissions. Anonymous keeps "View & Download Packages" (clients need no credential,
#      like the Nexus fragment's anonymous read). PROGET_PY: a python with playwright
#      (default python3). Without one, the script prints the clicks.
#   3. Connectors (Basic auth; ProGet connectors have no bearer field) and conda feeds:
#        ak-virtual      -> https://ak.internal/conda/conda-virtual   (consumer token)
#        ak-internal     -> https://ak.internal/conda/conda-internal  (consumer token)
#        ak-scn-virtual  -> https://ak.internal/conda/scn-virtual     (scn-reader token)
#        scn-fake        -> http://scn-fake-forge:8000                (no auth)
#        cf-direct       -> https://conda.anaconda.org/conda-forge    (no auth)
#      feeds: one per connector, plus merged [ak-virtual, cf-direct] and
#      merged-fake [ak-virtual, scn-fake] (a feed with two connectors is ProGet's merge).
#      Channels on ak-conda-net: http://scn-proget/conda/<feed>
#   The internal CA is trusted through the bundle up.sh mounts (no API step).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
G="http://127.0.0.1:${PROGET_PORT:-30482}"
PROGET_PY=${PROGET_PY:-python3}

# 0. licence
h=$(curl -sS -o "$WORK/proget-health.txt" -w '%{http_code}' "$G/health" || true)
if [[ $h != 200 ]]; then
  echo "proget/bootstrap.sh: /health HTTP $h: $(head -c 200 "$WORK/proget-health.txt")" >&2
  echo "proget/bootstrap.sh: ProGet needs a licence key first (Administration > Licensing & Activation)" >&2
  exit 3
fi
log "licensed: $(curl -sSI "$G/" | tr -d '\r' | grep -iE '^x-proget-(version|edition)' | tr '\n' ' ')"

# 1. API key
key_ok() { [[ -n ${PROGET_API_KEY:-} ]] && [[ $(curl -sS -o /dev/null -w '%{http_code}' -H "X-ApiKey: $PROGET_API_KEY" "$G/api/management/connectors/list") == 200 ]]; }
anon=$(curl -sS -o /dev/null -w '%{http_code}' "$G/api/api-keys/list")
if [[ -n ${PROGET_API_KEY:-} && $anon == 403 ]] && ! key_ok; then
  echo "proget/bootstrap.sh: PROGET_API_KEY in scenarios/.env is refused" >&2; exit 3; fi
if [[ -z ${PROGET_API_KEY:-} ]]; then
  if [[ $anon == 200 ]]; then
    r=$(curl -sS -X POST -H 'Content-Type: application/json' "$G/api/api-keys/create" \
        -d '{"type":"system","displayName":"scenarios-bootstrap","description":"walkthrough scenarios (proget/bootstrap.sh)","systemApis":["feeds"]}')
    k=$(jq -r '.key // empty' <<<"$r"); [[ ${#k} -ge 20 ]] || { echo "api-keys/create: $(jq -c 'del(.key)' <<<"$r" 2>/dev/null | head -c 200)" >&2; exit 1; }
    (umask 077; sed -i '/^PROGET_API_KEY=/d' "$SCN_ENV"; echo "PROGET_API_KEY=$k" >> "$SCN_ENV"); export PROGET_API_KEY=$k
    log "API key created anonymously (Anonymous still had Administer) and stored in scenarios/.env"
  else
    echo "proget/bootstrap.sh: no PROGET_API_KEY and anonymous is locked down (HTTP $anon); create one in the UI (header, step 1)" >&2; exit 3
  fi
fi

# 2. lock down
ensure_secret PROGET_ADMIN_PASSWORD
if [[ $(curl -sS -o /dev/null -w '%{http_code}' "$G/api/api-keys/list") != 403 ]]; then
  if "$PROGET_PY" -c "import playwright" 2>/dev/null; then PROGET_URL=$G "$PROGET_PY" "$SCN_DIR/proget/secure.py"
  else
    echo "proget/bootstrap.sh: Anonymous still has Administer. In the UI: log in as Admin/Admin;" >&2
    echo "  Administration > Security > Built-In Users & Groups > Admin: Password = PROGET_ADMIN_PASSWORD (scenarios/.env), Save;" >&2
    echo "  Administration > Security > Tasks / Permissions: Remove Anonymous Access. Or set PROGET_PY to a python with playwright." >&2
    exit 3
  fi
fi
log "anonymous: api-keys/list HTTP $(curl -sS -o /dev/null -w '%{http_code}' "$G/api/api-keys/list"), connectors/create HTTP $(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "$G/api/management/connectors/create")"
key_ok || { echo "proget/bootstrap.sh: PROGET_API_KEY refused" >&2; exit 3; }

# 3. connectors and feeds
pg() { curl -sS -H "X-ApiKey: $PROGET_API_KEY" -H 'Content-Type: application/json' -w '\n%{http_code}' "$@"; }
code_of() { echo "${1##*$'\n'}"; }
body_of() { echo "${1%$'\n'*}"; }
connector() { # NAME URL [TOKEN-FILE]
  local j r
  j=$(jq -nc --arg n "$1" --arg u "$2" --arg t "$([[ -n ${3:-} ]] && cat "$3")" \
      '{name:$n, url:$u, feedType:"conda", timeout:600} + (if $t != "" then {username:"consumer", password:$t} else {} end)')
  r=$(pg "$G/api/management/connectors/get/$1")
  if [[ $(code_of "$r") == 200 ]]; then r=$(pg -X POST "$G/api/management/connectors/update/$1" -d "$j")
  else r=$(pg -X POST "$G/api/management/connectors/create" -d "$j"); fi
  [[ $(code_of "$r") =~ ^20 ]] || { echo "connector $1: HTTP $(code_of "$r") $(body_of "$r" | head -c 300)" >&2; exit 1; }
  log "connector $1 -> $2${3:+ (basic consumer:<$(basename "$3")>)}"
}
feed() { # NAME CONNECTOR...
  local n=$1 j r; shift
  j=$(jq -nc --arg n "$n" '{name:$n, feedType:"conda", active:true, connectors:$ARGS.positional}' --args "$@")
  r=$(pg "$G/api/management/feeds/get/$n")
  if [[ $(code_of "$r") == 200 ]]; then r=$(pg -X POST "$G/api/management/feeds/update/$n" -d "$j")
  else r=$(pg -X POST "$G/api/management/feeds/create" -d "$j"); fi
  [[ $(code_of "$r") =~ ^20 ]] || { echo "feed $n: HTTP $(code_of "$r") $(body_of "$r" | head -c 300)" >&2; exit 1; }
  log "feed $n [$*] -> http://scn-proget/conda/$n"
}
[[ -s "$SCN_TOKENS/scn-reader.token" ]] || { echo "proget/bootstrap.sh: run scenarios/ak-setup.sh first (scn-reader.token)" >&2; exit 1; }
connector ak-virtual     "$AK_URL/conda/conda-virtual"  "$TOKENS/consumer.token"
connector ak-internal    "$AK_URL/conda/conda-internal" "$TOKENS/consumer.token"
connector ak-scn-virtual "$AK_URL/conda/scn-virtual"    "$SCN_TOKENS/scn-reader.token"
connector scn-fake       http://scn-fake-forge:8000
connector cf-direct      https://conda.anaconda.org/conda-forge
feed ak-virtual ak-virtual
feed ak-internal ak-internal
feed ak-scn-virtual ak-scn-virtual
feed scn-fake scn-fake
feed cf-direct cf-direct
feed merged ak-virtual cf-direct
feed merged-fake ak-virtual scn-fake
