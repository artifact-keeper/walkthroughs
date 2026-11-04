#!/usr/bin/env bash
# Run a command in the workstation container on ak-mcp-net.
#   client/run.sh [-h HOME_NAME] [-t TOKEN_NAME] [-v HOST:CTR] [-e NAME] -- command [args...]
# HOME_NAME   a throwaway home under out/homes/<name>, mounted at /home/dev (default: scratch,
#             wiped first). The same name keeps state between runs.
# TOKEN_NAME  a token from registry/.tokens/<name>.token, passed as AK_TOKEN through the
#             environment only (never on a command line, never written into the home).
# -e NAME     pass one more variable of this shell's environment by name.
# servers/ is mounted read-only at /servers, out/ at /out.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"
home=scratch token="" extra=() env=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h) home=$2; shift 2 ;;
    -t) token=$2; shift 2 ;;
    -v) extra+=(-v "$2"); shift 2 ;;
    -e) env+=(-e "$2"); shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
H="$ROOT/out/homes/$home"
[[ "$home" == scratch ]] && rm -rf "$H"
mkdir -p "$H"
if [[ -n "$token" ]]; then AK_TOKEN="$(tok "$token")"; export AK_TOKEN; env+=(-e AK_TOKEN); fi
exec podman run --rm -i --network "$NET" "${env[@]}" \
  -v "$H:/home/dev:z" -v "$ROOT/servers:/servers:ro,z" -v "$ROOT/out:/out:z" "${extra[@]}" \
  localhost/ak-mcp/workstation:latest "$@"
