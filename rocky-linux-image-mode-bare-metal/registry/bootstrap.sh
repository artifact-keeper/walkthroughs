#!/usr/bin/env bash
# Idempotently configure Artifact Keeper for the edge PoC:
#   - creates the rpm-* and oci-* repositories (skips any that already exist)
#   - mints a CI API token into .ak-token (reused if it still authenticates)
#   - enables Artifact Keeper repodata signing (sign_metadata) on rpm-edge-site
#   - writes out/edge.repo (+ out/edge.repo.in template, gpgcheck=1) and out/README-urls.md
#
# Env:
#   AK_URL  API/registry base URL used by this script (default http://localhost:$HTTP_PORT)
#   HOST    hostname baked into out/edge.repo baseurls (default localhost;
#           use 10.0.2.2 from a QEMU user-net VM, host.containers.internal
#           from a podman build/run)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/.env"
TOKEN_FILE="$HERE/.ak-token"
OUT="$HERE/out"

[[ -f "$ENV_FILE" ]] || { echo "bootstrap.sh: $ENV_FILE missing; run ./up.sh first" >&2; exit 1; }
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a
HTTP_PORT="${HTTP_PORT:-30080}"
AK_URL="${AK_URL:-http://localhost:${HTTP_PORT}}"
HOST="${HOST:-localhost}"
command -v jq >/dev/null || { echo "bootstrap.sh: jq is required" >&2; exit 1; }

log() { echo "bootstrap: $*"; }

curl -fsS "$AK_URL/readyz" >/dev/null || { echo "bootstrap.sh: $AK_URL/readyz not ready" >&2; exit 1; }

# --- login ------------------------------------------------------------------
login_body=$(jq -nc --arg u admin --arg p "$ADMIN_PASSWORD" '{username:$u,password:$p}')
JWT=$(curl -fsS -X POST "$AK_URL/api/v1/auth/login" \
        -H 'Content-Type: application/json' -d "$login_body" | jq -r .access_token)
[[ -n "$JWT" && "$JWT" != null ]] || { echo "bootstrap.sh: login failed" >&2; exit 1; }
log "logged in as admin"

api() { # api METHOD PATH [JSON]
  local m=$1 p=$2; shift 2
  curl -sS -X "$m" "$AK_URL/api/v1$p" -H "Authorization: Bearer $JWT" \
       -H 'Content-Type: application/json' "$@"
}

# --- repositories -------------------------------------------------------------
# key|format|repo_type|upstream_url|display name
REPOS=(
  "rpm-rocky10-baseos|rpm|remote|https://dl.rockylinux.org/pub/rocky/10/BaseOS/x86_64/os/|Rocky Linux 10 BaseOS (proxy)"
  "rpm-rocky10-appstream|rpm|remote|https://dl.rockylinux.org/pub/rocky/10/AppStream/x86_64/os/|Rocky Linux 10 AppStream (proxy)"
  "rpm-rocky10-extras|rpm|remote|https://dl.rockylinux.org/pub/rocky/10/extras/x86_64/os/|Rocky Linux 10 extras (proxy)"
  "rpm-epel10|rpm|remote|https://dl.fedoraproject.org/pub/epel/10/Everything/x86_64/|EPEL 10 Everything (proxy)"
  # Rancher publishes no el10 path; centos/9 only carries k3s-selinux (el9 build).
  "rpm-k3s|rpm|remote|https://rpm.rancher.io/k3s/stable/common/centos/9/noarch/|Rancher k3s stable (k3s-selinux, el9) (proxy)"
  # RKE2 (EL10 builds). common = rke2-selinux/rke2-common deps (noarch); the minor
  # repo carries rke2-server/agent. 1.36 is the minor of the "stable" channel at
  # https://update.rke2.io/v1-release/channels on 2026-10-05 (1.37 = "latest").
  "rpm-rke2-common|rpm|remote|https://rpm.rancher.io/rke2/stable/common/centos/10/noarch/|Rancher RKE2 common EL10 (proxy)"
  "rpm-rke2-1.36|rpm|remote|https://rpm.rancher.io/rke2/stable/1.36/centos/10/x86_64/|Rancher RKE2 1.36 EL10 (proxy)"
  "rpm-edge-site|rpm|local||Edge site custom RPMs"
  "oci-bootc|docker|local||bootc images"
  "oci-quay-proxy|docker|remote|https://quay.io|quay.io (proxy)"
  "oci-dockerhub-proxy|docker|remote|https://registry-1.docker.io|Docker Hub (proxy)"
  # Public keys consumers need to verify signatures (cosign, RPM GPG, vendor keys).
  # "generic" is AK's raw-file format. Anonymous GET /api/v1/repositories/raw-edge-keys/download/<file>
  # (the native /general/<key>/<file> route exists in the backend but the stock Caddyfile does not route it).
  # Filled by signing/publish-keys.sh.
  "raw-edge-keys|generic|local||Public signing keys (cosign, RPM GPG, vendor keys)"
)

for spec in "${REPOS[@]}"; do
  IFS='|' read -r key format rtype upstream name <<<"$spec"
  code=$(api GET "/repositories/$key" -o /dev/null -w '%{http_code}')
  if [[ "$code" == 200 ]]; then
    log "repo $key exists, skipping"; continue
  fi
  body=$(jq -nc --arg k "$key" --arg n "$name" --arg f "$format" --arg t "$rtype" --arg u "$upstream" \
    '{key:$k,name:$n,format:$f,repo_type:$t,is_public:true}
     + (if $u != "" then {upstream_url:$u} else {} end)')
  resp=$(api POST /repositories -d "$body" -w '\n%{http_code}')
  code=${resp##*$'\n'}
  if [[ "$code" =~ ^20 ]]; then
    log "repo $key created ($format/$rtype${upstream:+ -> $upstream})"
  else
    echo "bootstrap.sh: creating $key failed: HTTP $code ${resp%$'\n'*}" >&2; exit 1
  fi
done

# --- CI API token ---------------------------------------------------------------
token_ok() {
  [[ -s "$TOKEN_FILE" ]] || return 1
  [[ "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
        "$AK_URL/api/v1/auth/me")" == 200 ]]
}
if token_ok; then
  log "existing $TOKEN_FILE still valid, reusing"
else
  tbody=$(jq -nc --arg n "ci-$(date -u +%Y%m%dT%H%M%SZ)" \
    '{name:$n,scopes:["read:artifacts","write:artifacts"],expires_in_days:30}')
  tok=$(api POST /users/me/tokens -d "$tbody" | jq -r .token)
  [[ -n "$tok" && "$tok" != null ]] || { echo "bootstrap.sh: token mint failed" >&2; exit 1; }
  (umask 077; printf '%s\n' "$tok" > "$TOKEN_FILE")
  log "minted CI token -> $TOKEN_FILE (user admin, 30 days)"
fi

# --- repodata signing for the hosted RPM repo ----------------------------------------
# Artifact Keeper signs rpm-edge-site's repomd.xml with a server-managed OpenPGP key
# (serves repodata/repomd.xml.asc + repodata/repomd.xml.key), so dnf can use
# repo_gpgcheck=1. The key is created through the signing API (key_type must be
# "gpg" for RPM metadata; "rsa"/"ed25519" are rejected for rpm/debian repos).
sign_repo_metadata() { # sign_repo_metadata REPO_KEY
  local key=$1 rid cfg kid body
  rid=$(api GET "/repositories/$key" | jq -r .id)
  cfg=$(api GET "/signing/repositories/$rid/config")
  if [[ "$(jq -r '.sign_metadata' <<<"$cfg")" == true && "$(jq -r '.signing_key_id // empty' <<<"$cfg")" != "" ]]; then
    log "repodata signing already enabled on $key (key $(jq -r '.key.fingerprint // .signing_key_id' <<<"$cfg"))"
    return 0
  fi
  kid=$(api GET "/signing/keys?repository_id=$rid" | jq -r '[.keys[] | select(.key_type=="gpg" and .is_active)][0].id // empty')
  if [[ -z "$kid" ]]; then
    body=$(jq -nc --arg r "$rid" --arg n "$key repodata" --arg u "Artifact Keeper $key" --arg e "$key@example.invalid" \
      '{name:$n,key_type:"gpg",algorithm:"rsa4096",repository_id:$r,uid_name:$u,uid_email:$e}')
    kid=$(api POST /signing/keys -d "$body" | jq -r '.id // empty')
    [[ -n "$kid" ]] || { echo "bootstrap.sh: creating signing key for $key failed" >&2; exit 1; }
    log "created gpg signing key $kid for $key"
  fi
  api POST "/signing/repositories/$rid/config" -d "$(jq -nc --arg k "$kid" '{signing_key_id:$k,sign_metadata:true}')" \
    | jq -e '.sign_metadata == true' >/dev/null || { echo "bootstrap.sh: enabling sign_metadata on $key failed" >&2; exit 1; }
  log "repodata signing enabled on $key"
}
sign_repo_metadata rpm-edge-site

# --- client config ----------------------------------------------------------------
# Signature policy per repo (iteration 2: no gpgcheck=0 anywhere):
#   gpgcheck=1 everywhere, with the vendor key for proxied repos and our key for rpm-edge-site.
#   repo_gpgcheck=1 where a signed repomd.xml.asc is served: Rocky + Rancher RKE2 upstreams
#   (Artifact Keeper passes the upstream .asc through unchanged) and rpm-edge-site (AK-signed).
#   EPEL 10 and Rancher's k3s el9 tree publish no repomd.xml.asc, so repo_gpgcheck=0 there.
# Rocky's key ships in every Rocky image (rocky-gpg-keys); everything else is fetched
# from the raw-edge-keys repo (signing/publish-keys.sh) or AK's own repomd.xml.key.
KEYS_URL="http://@HOST@:$HTTP_PORT/api/v1/repositories/raw-edge-keys/download"
repo_keys() { # repo_keys KEY -> "gpgkey|repo_gpgcheck"
  case "$1" in
    rpm-rocky10-*)  echo "file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10|1" ;;
    rpm-epel10)     echo "$KEYS_URL/RPM-GPG-KEY-EPEL-10|0" ;;
    rpm-k3s)        echo "$KEYS_URL/RPM-GPG-KEY-Rancher|0" ;;
    rpm-rke2-*)     echo "$KEYS_URL/RPM-GPG-KEY-Rancher|1" ;;
    rpm-edge-site)  echo "$KEYS_URL/RPM-GPG-KEY-edge http://@HOST@:$HTTP_PORT/rpm/rpm-edge-site/repodata/repomd.xml.key|1" ;;
    *)              echo "bootstrap.sh: no signing policy for $1" >&2; exit 1 ;;
  esac
}
mkdir -p "$OUT"
{
  echo "# Generated by registry/bootstrap.sh. All RPM repos served by Artifact Keeper."
  echo "# Template: replace the HOST placeholder everywhere (sed s/@HOST@/<host>/g) with"
  echo "# localhost | 10.0.2.2 (QEMU VM) | host.containers.internal (podman build)."
  echo "# Every package is GPG-checked; repo metadata too where the publisher signs it."
  for spec in "${REPOS[@]}"; do
    IFS='|' read -r key format rtype upstream name <<<"$spec"
    [[ "$format" == rpm ]] || continue
    IFS='|' read -r gpgkey repo_gpg <<<"$(repo_keys "$key")"
    printf '\n[%s]\nname=%s\nbaseurl=http://@HOST@:%s/rpm/%s\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=%s\ngpgkey=%s\nmetadata_expire=6h\n' \
      "$key" "$name" "$HTTP_PORT" "$key" "$repo_gpg" "$gpgkey"
  done
} > "$OUT/edge.repo.in"
sed "s/@HOST@/$HOST/g" "$OUT/edge.repo.in" > "$OUT/edge.repo"
log "wrote $OUT/edge.repo (HOST=$HOST) and $OUT/edge.repo.in"

cat > "$OUT/README-urls.md" <<MD
# Artifact Keeper endpoints (generated by bootstrap.sh)

Host used: \`$HOST\` (from a QEMU user-net VM use \`10.0.2.2\`; from a podman
container/build use \`host.containers.internal\`). Port: \`$HTTP_PORT\` (plain HTTP via Caddy).

| What | URL |
|---|---|
| Web UI | http://$HOST:$HTTP_PORT/ |
| API | http://$HOST:$HTTP_PORT/api/v1/ |
| Health | http://$HOST:$HTTP_PORT/livez, http://$HOST:$HTTP_PORT/readyz |
$(for spec in "${REPOS[@]}"; do IFS='|' read -r key format rtype upstream name <<<"$spec"
  if [[ $format == rpm ]]; then echo "| dnf baseurl \`$key\` ($rtype) | http://$HOST:$HTTP_PORT/rpm/$key |"
  elif [[ $format == generic ]]; then echo "| files \`$key\` ($rtype) | http://$HOST:$HTTP_PORT/api/v1/repositories/$key/download/<file> |"
  else echo "| OCI \`$key\` ($rtype) | \`$HOST:$HTTP_PORT/$key/<image>:<tag>\` |"; fi; done)

Upload an RPM to \`rpm-edge-site\`:

    curl -u "admin:\$(cat registry/.ak-token)" -T foo.rpm http://$HOST:$HTTP_PORT/rpm/rpm-edge-site/packages/foo.rpm

Push a bootc image:

    podman login --tls-verify=false -u admin --password-stdin $HOST:$HTTP_PORT < registry/.ak-token
    podman push --tls-verify=false $HOST:$HTTP_PORT/oci-bootc/edge:latest

Pull through the quay.io proxy:

    podman pull --tls-verify=false $HOST:$HTTP_PORT/oci-quay-proxy/rockylinux/rockylinux:10
MD
log "wrote $OUT/README-urls.md"
log "done"
