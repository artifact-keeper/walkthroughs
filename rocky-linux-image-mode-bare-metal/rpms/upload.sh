#!/usr/bin/env bash
# Upload rpms/out/*.rpm to the Artifact Keeper hosted repo rpm-edge-site and
# confirm the server-generated repodata lists every uploaded NEVRA.
# Re-uploading an existing file is tolerated (HTTP 409 = already there).
# Env: AK (default localhost:30080), REPO (default rpm-edge-site)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AK="${AK:-localhost:30080}"
REPO="${REPO:-rpm-edge-site}"
TOKEN_FILE="$ROOT/registry/.ak-token"
[[ -s "$TOKEN_FILE" ]] || { echo "rpms/upload.sh: $TOKEN_FILE missing; run registry/bootstrap.sh" >&2; exit 1; }
shopt -s nullglob
rpms=("$HERE"/out/*.rpm)
(( ${#rpms[@]} )) || { echo "rpms/upload.sh: no RPMs in $HERE/out; run rpms/build.sh" >&2; exit 1; }

mkdir -p "$HERE/.work"
for f in "${rpms[@]}"; do
  name=$(basename "$f")
  code=$(curl -sS -o "$HERE/.work/upload.out" -w '%{http_code}' -u "admin:$(cat "$TOKEN_FILE")" \
         -T "$f" "http://$AK/rpm/$REPO/packages/$name")
  case "$code" in
    20?) echo "rpms: uploaded $name ($code)";;
    409) echo "rpms: $name already present ($code)";;
    *)   echo "rpms/upload.sh: upload of $name failed: HTTP $code $(cat "$HERE/.work/upload.out")" >&2; exit 1;;
  esac
done

# Verify repodata (server-generated; no createrepo step).
primary=$(curl -fsS "http://$AK/rpm/$REPO/repodata/repomd.xml" \
          | grep -o 'href="repodata/[^"]*primary.xml[^"]*"' | head -1 | sed 's/^href="//; s/"$//')
listed=$(curl -fsS "http://$AK/rpm/$REPO/$primary" | zcat \
         | grep -oE '<name>[^<]+</name>|<version [^>]+/>' | paste - - )
echo "rpms: repodata of $REPO:"
echo "$listed" | sed 's/^/  /'
mkdir -p "$HERE/.work"
for f in "${rpms[@]}"; do
  rel=$(rpm -qp --qf '%{RELEASE}' "$f" 2>/dev/null || basename "$f" | sed -E 's/.*-([^-]+)\.noarch\.rpm$/\1/')
  echo "$listed" | grep -q "rel=\"$rel\"" || { echo "rpms/upload.sh: release $rel of $(basename "$f") missing from repodata" >&2; exit 1; }
done
echo "rpms: all uploaded releases present in repodata"
