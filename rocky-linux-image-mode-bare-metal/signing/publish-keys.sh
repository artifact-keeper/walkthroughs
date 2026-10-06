#!/usr/bin/env bash
# Publish the PUBLIC keys consumers need into the Artifact Keeper generic repo
# raw-edge-keys (created by registry/bootstrap.sh, is_public=true), so builds,
# kickstart %pre and nodes fetch them from the same source of truth.
# Idempotent: unchanged files are skipped; a changed file is deleted and re-uploaded
# (AK generic repos are write-once per path unless versioning_enabled).
# Anonymous download URL (Caddy only routes /api/*, not the /general/* native path):
#   http://<host>:30080/api/v1/repositories/raw-edge-keys/download/<file>
# Env: AK (default localhost:30080), REPO (default raw-edge-keys)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AK="${AK:-localhost:30080}"
REPO="${REPO:-raw-edge-keys}"
PUB="$HERE/keys/pub"
TOKEN_FILE="$ROOT/registry/.ak-token"
FILES=(edge-cosign.pub RPM-GPG-KEY-edge RPM-GPG-KEY-Rancher RPM-GPG-KEY-EPEL-10)
[[ -s "$TOKEN_FILE" ]] || { echo "publish-keys.sh: $TOKEN_FILE missing; run registry/bootstrap.sh" >&2; exit 1; }
api="http://$AK/api/v1/repositories/$REPO"
auth=(-H "Authorization: Bearer $(cat "$TOKEN_FILE")")
admin_jwt() {
  local pw; pw=$(sed -n 's/^ADMIN_PASSWORD=//p' "$ROOT/registry/.env")
  curl -fsS -X POST "http://$AK/api/v1/auth/login" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg p "$pw" '{username:"admin",password:$p}')" | jq -r .access_token
}

for f in "${FILES[@]}"; do
  src="$PUB/$f"
  [[ -s "$src" ]] || { echo "publish-keys.sh: $src missing; run signing/gen-keys.sh" >&2; exit 1; }
  want=$(sha256sum "$src" | cut -d' ' -f1)
  have=$(curl -sS "${auth[@]}" "$api/artifacts/$f" | jq -r '.checksum_sha256 // empty' 2>/dev/null || true)
  if [[ "$have" == "$want" ]]; then
    echo "keys: $f unchanged"
  else
    if [[ -n "$have" ]]; then
      # The CI token has read/write scopes only; deleting needs delete:artifacts,
      # so use an admin session for the replacement.
      curl -fsS -H "Authorization: Bearer $(admin_jwt)" -X DELETE "$api/artifacts/$f" >/dev/null
      echo "keys: $f changed, replacing"
    fi
    case "$f" in *.pub) ct=application/x-pem-file ;; *) ct=application/pgp-keys ;; esac
    code=$(curl -sS -o /dev/null -w '%{http_code}' "${auth[@]}" -H "Content-Type: $ct" \
           -X PUT --data-binary "@$src" "$api/artifacts/$f")
    [[ "$code" == 201 || "$code" == 200 ]] || { echo "publish-keys.sh: upload of $f failed: HTTP $code" >&2; exit 1; }
    echo "keys: uploaded $f"
  fi
done

# Prove anonymous reads return the exact bytes.
echo "keys: anonymous download URLs (from the VM use 10.0.2.2, from podman builds host.containers.internal):"
for f in "${FILES[@]}"; do
  url="$api/download/$f"
  got=$(curl -fsS "$url" | sha256sum | cut -d' ' -f1)
  [[ "$got" == "$(sha256sum "$PUB/$f" | cut -d' ' -f1)" ]] || { echo "publish-keys.sh: $url does not match $PUB/$f" >&2; exit 1; }
  echo "  $url"
done
