#!/usr/bin/env bash
# Ask the registry for one proxied file and show exactly what the gate answered:
#   clients/probe.sh REPO PATH        e.g. clients/probe.sh npm-proxy lodash/-/lodash-4.17.15.tgz
# Prints "HTTP <status> X-AK-Scan=<header or -> <json body if any>" on one line and saves
# the body to clients/out/probe-body. Exit status 0 whatever the registry answered.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../registry/lib.sh"; load_env
repo=${1:?usage: clients/probe.sh REPO PATH}; path=${2:?path}
mkdir -p "$here/out"
case $repo in
  go-*)     prefix=go ;;     cargo-*)  prefix=cargo ;;
  npm-*)    prefix=npm ;;    debian-*) prefix=debian ;;
  alpine-*) prefix=alpine ;; *) echo "probe.sh: cannot tell the format of '$repo' from its key" >&2; exit 2 ;;
esac
hdr=$(mktemp); trap 'rm -f "$hdr"' EXIT
code=$(akcurl -sS -o "$here/out/probe-body" -D "$hdr" -w '%{http_code}' "$(AK_HOST_URL)/$prefix/$repo/$path")
scan=$(awk 'tolower($1)=="x-ak-scan:" {print $2}' "$hdr" | tr -d '\r')
body=""
if grep -qi '^content-type: application/json' "$hdr"; then body=$(jq -c . "$here/out/probe-body" 2>/dev/null || head -c 300 "$here/out/probe-body"); fi
echo "HTTP $code X-AK-Scan=${scan:--} $body"
