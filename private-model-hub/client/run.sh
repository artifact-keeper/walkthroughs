#!/usr/bin/env bash
# Run a command in the workstation container.
#   client/run.sh [-r REPO] [-t TOKEN_NAME] [-h HOME_NAME] [-o] [-e NAME] -- command [args...]
# REPO        sets HF_ENDPOINT=https://ak.internal/huggingface/REPO (no trailing slash)
# TOKEN_NAME  a token from registry/.tokens/<name>.token, passed as HF_TOKEN through the
#             environment only (never on a command line, never written into the home)
# HOME_NAME   a home under out/homes/<name>, mounted at /home/dev; its ~/.cache/huggingface
#             is the client's cache. Default: scratch, wiped first. The same name keeps the
#             cache between runs.
# -o          offline: run on ak-hf-offline (internal network: Caddy and nothing else)
# -e NAME     pass one more variable of this shell's environment by name.
# client/hfcheck.py is mounted read-only at /client/hfcheck.py, out/ at /out. The container runs
# as uid 1000 mapped to your user (--userns keep-id), so everything it writes is yours.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"
home=scratch token="" repo="" net="$NET" env=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r) repo=$2; shift 2 ;;
    -t) token=$2; shift 2 ;;
    -h) home=$2; shift 2 ;;
    -o) net="$OFFLINE_NET"; shift ;;
    -e) env+=(-e "$2"); shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
H="$ROOT/out/homes/$home"
[[ "$home" == scratch ]] && rm -rf "$H"
mkdir -p "$H" "$ROOT/out"
[[ -z "$repo" ]] || env+=(-e "HF_ENDPOINT=$AK_URL/huggingface/$repo")
if [[ -n "$token" ]]; then HF_TOKEN="$(tok "$token")"; export HF_TOKEN; env+=(-e HF_TOKEN); fi
exec podman run --rm -i --network "$net" --userns keep-id:uid=1000,gid=1000 "${env[@]}" \
  -v "$H:/home/dev:z" -v "$HERE/hfcheck.py:/client/hfcheck.py:ro,z" -v "$ROOT/out:/out:z" \
  localhost/ak-hf/workstation:latest "$@"
