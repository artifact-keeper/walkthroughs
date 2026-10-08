#!/usr/bin/env bash
# The lockfile is the allowlist: read the conda packages of a solved pixi.lock
# and admit exactly those (name, exact version, subdir) on the virtual channel.
# Records the virtual channel takes from its remote member (conda-forge) that are
# not in the lock disappear from its repodata and channeldata, and their files
# are 404 through the virtual channel. Hosted members are not filtered.
#
# Usage: allowlist/from-lock.sh [--list] [path/to/pixi.lock]   (default: project/pixi.lock)
#        --list prints the lock's conda packages (name, version, subdir, file, channel) as TSV
# Env:   REPO (default conda-virtual), DRY_RUN=1 prints the request body only
# Idempotent: PUT replaces the whole list.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
list=0; [[ "${1:-}" == --list ]] && { list=1; shift; }
LOCK="${1:-$ROOT/project/pixi.lock}"
[[ -f "$LOCK" ]] || { echo "from-lock.sh: $LOCK not found; run make lock" >&2; exit 1; }

# Package entries are the top-level "- conda: <url>" lines under `packages:`.
# The file name is <name>-<version>-<build>.conda|.tar.bz2; name may contain
# dashes, version and build never do. The subdir is the URL's parent directory.
lock_packages() { # -> name version subdir file channel (TSV)
  sed -n '/^packages:/,$ s|^- conda: ||p' "$LOCK" | while read -r url; do
    local file=${url##*/} dir=${url%/*} f
    f=${file%.conda}; f=${f%.tar.bz2}; f=${f%-*}   # drop the build string
    printf '%s\t%s\t%s\t%s\t%s\n' "${f%-*}" "${f##*-}" "${dir##*/}" "$file" "${dir%/*}"
  done
}
if ((list)); then lock_packages; exit 0; fi
entries=$(lock_packages | cut -f1-3 | sort -u | jq -R -s -c '
  split("\n") | map(select(length > 0) | split("\t")) | group_by(.[0], .[1])
  | map({name: .[0][0], version: ("==" + .[0][1]), subdirs: (map(.[2]) | unique)})')
n=$(jq length <<<"$entries")
(( n > 0 )) || { echo "from-lock.sh: no conda packages in $LOCK" >&2; exit 1; }
body=$(jq -c '{enabled: true, entries: .}' <<<"$entries")
log "$n entries from ${LOCK#"$ROOT"/} ($(jq -r '[.[].subdirs[]] | group_by(.) | map("\(.[0]) \(length)") | join(", ")' <<<"$entries"))"
if [[ "${DRY_RUN:-0}" == 1 ]]; then jq . <<<"$body"; exit 0; fi

r=$(api PUT -d "$body")
[[ $(code_of "$r") == 200 ]] || { echo "from-lock.sh: PUT $REPO/allowlist: HTTP $(code_of "$r") $(body_of "$r")" >&2; exit 1; }
log "PUT /api/v1/repositories/$REPO/allowlist -> HTTP 200 $(body_of "$r" | jq -c '{enabled, entry_count}')"
