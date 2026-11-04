#!/usr/bin/env bash
# Run a command in the workstation container on ak-agents-net.
#   client/run.sh [-h HOME_NAME] [-t TOKEN_NAME] [-i INSTANCE_URL] [-v HOST:CTR] -- command [args...]
# HOME_NAME   a throwaway home under out/homes/<name>, mounted at /home/dev (default: scratch,
#             wiped first). The same name keeps state between runs (marketplaces, installs).
# TOKEN_NAME  a token from registry/.tokens/<name>.token, passed as AK_TOKEN (and as the
#             environment only; nothing is written into the home).
# INSTANCE_URL the instance ak talks to (AK_INSTANCE), default https://ak.internal.
# The plugins/ directory is at /plugins, out/ at /out.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"
home=scratch token="" instance=https://ak.internal extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h) home=$2; shift 2 ;;
    -t) token=$2; shift 2 ;;
    -i) instance=$2; shift 2 ;;
    -v) extra+=(-v "$2"); shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
H="$ROOT/out/homes/$home"
[[ "$home" == scratch ]] && rm -rf "$H"
mkdir -p "$H"
env=(-e "AK_INSTANCE=$instance" -e AK_NO_INPUT=1 -e "AK_FORMAT=${AK_FORMAT:-table}")
# The token goes through the environment of this process (-e AK_TOKEN with no value), so it
# never appears on a command line.
if [[ -n "$token" ]]; then AK_TOKEN="$(tok "$token")"; export AK_TOKEN; env+=(-e AK_TOKEN); fi
exec podman run --rm -i --network "$NET" "${env[@]}" \
  -v "$H:/home/dev:z" -v "$ROOT/plugins:/plugins:ro,z" -v "$ROOT/out:/out:z" "${extra[@]}" \
  localhost/ak-agents/workstation:latest "$@"
