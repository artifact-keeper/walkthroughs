#!/usr/bin/env bash
# Configure scn-proget for the scenarios through ProGet's HTTP API. Idempotent.
#
# STATUS (2026-10-08): NOT RUN past step 0. ProGet 26.0.12 answers every page and
# API call with "302 -> /administration/licensing" (and /health with 500
# "Product license is not valid") until a licence key is entered. A ProGet Free
# key is free but is issued by Inedo against an e-mail address and a full name
# (Administration > Licensing & Activation > Request a License Key, or
# my.inedo.com); the spike did not register on anyone's behalf.
#
# Manual steps before this script can run (UI only on ProGet Free, which is
# "limited to UI-based security configuration"):
#   1. http://127.0.0.1:30482 -> Administration > Licensing & Activation >
#      change: paste the key (or request a ProGet Free key there).
#   2. Administration > API Keys > Create API Key: type "System", permission
#      "Use/Manage Feeds"; put it in scenarios/.env as PROGET_API_KEY=...
#
# What the script then does (field names from Inedo/pgutil ProGetConnector.cs
# and ProGetFeed.cs; endpoints from the Connector and Feed Management API docs):
#   connector ak-virtual  -> https://ak.internal/conda/conda-virtual, Basic auth
#                            consumer:<consumer token> (connectors have
#                            Username/Password only; no bearer field)
#   connector ak-internal -> https://ak.internal/conda/conda-internal (same auth)
#   connector cf-direct   -> https://conda.anaconda.org/conda-forge
#   feed ak-virtual  [ak-virtual]            feed ak-internal [ak-internal]
#   feed merged      [ak-virtual, cf-direct] (a feed with two connectors)
# Channels would be http://scn-proget/conda/<feed>.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
G="http://127.0.0.1:${PROGET_PORT:-30482}"

# 0. licence
h=$(curl -sS -o "$WORK/proget-health.txt" -w '%{http_code}' "$G/health" || true)
if [[ $h != 200 ]]; then
  echo "proget/bootstrap.sh: /health HTTP $h: $(head -c 200 "$WORK/proget-health.txt")" >&2
  echo "proget/bootstrap.sh: ProGet needs a licence key first (see the header of this script)" >&2
  exit 3
fi
[[ -n "${PROGET_API_KEY:-}" ]] || { echo "proget/bootstrap.sh: PROGET_API_KEY missing in scenarios/.env (UI step 2)" >&2; exit 3; }
pg() { curl -sS -H "X-ApiKey: $PROGET_API_KEY" -H 'Content-Type: application/json' -w '\n%{http_code}' "$@"; }
code_of() { echo "${1##*$'\n'}"; }
body_of() { echo "${1%$'\n'*}"; }

connector() { # NAME URL AUTH(0|1)
  local j r
  j=$(jq -nc --arg n "$1" --arg u "$2" --arg t "$(consumer_token)" --argjson a "$3" \
      '{name:$n, url:$u, feedType:"conda", timeout:600} + (if $a == 1 then {username:"consumer", password:$t} else {} end)')
  r=$(pg "$G/api/management/connectors/get/$1")
  if [[ $(code_of "$r") == 200 ]]; then r=$(pg -X POST "$G/api/management/connectors/update/$1" -d "$j")
  else r=$(pg -X POST "$G/api/management/connectors/create" -d "$j"); fi
  [[ $(code_of "$r") =~ ^20 ]] || { echo "connector $1: HTTP $(code_of "$r") $(body_of "$r" | head -c 300)" >&2; exit 1; }
  log "connector $1 -> $2"
}
feed() { # NAME CONNECTOR...
  local n=$1 j r; shift
  j=$(jq -nc --arg n "$n" --args '{name:$n, feedType:"conda", active:true, connectors:$ARGS.positional}' "$@")
  r=$(pg "$G/api/management/feeds/get/$n")
  if [[ $(code_of "$r") == 200 ]]; then r=$(pg -X POST "$G/api/management/feeds/update/$n" -d "$j")
  else r=$(pg -X POST "$G/api/management/feeds/create" -d "$j"); fi
  [[ $(code_of "$r") =~ ^20 ]] || { echo "feed $n: HTTP $(code_of "$r") $(body_of "$r" | head -c 300)" >&2; exit 1; }
  log "feed $n [$*] -> http://scn-proget/conda/$n"
}
connector ak-virtual  "$AK_URL/conda/conda-virtual"  1
connector ak-internal "$AK_URL/conda/conda-internal" 1
connector cf-direct   https://conda.anaconda.org/conda-forge 0
feed ak-virtual ak-virtual
feed ak-internal ak-internal
feed merged ak-virtual cf-direct
