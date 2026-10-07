#!/usr/bin/env bash
# Publish the CI verification key to the registry's public `trust` repo so every
# consumer fetches it from the same place as the CA certificate.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"; load_env
U=$(AK_HOST_URL)
JWT=$(admin_token)
src="$HERE/keys/cosign.pub"; name=conda-ci-cosign.pub
want=$(sha256sum "$src" | cut -d' ' -f1)
have=$(akcurl -sS "$U/api/v1/repositories/trust/download/$name" | sha256sum | cut -d' ' -f1)
if [[ "$have" == "$want" ]]; then echo "keys: trust/$name up to date"; exit 0; fi
akcurl -sS -o /dev/null -H "Authorization: Bearer $JWT" -X DELETE "$U/api/v1/repositories/trust/artifacts/$name" || true
code=$(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $JWT" -H 'Content-Type: application/x-pem-file' \
         -X PUT --data-binary "@$src" "$U/api/v1/repositories/trust/artifacts/$name")
[[ "$code" =~ ^20 ]] || { echo "publish-keys.sh: HTTP $code" >&2; exit 1; }
echo "keys: uploaded trust/$name (anonymous: https://ak.internal/api/v1/repositories/trust/download/$name)"
