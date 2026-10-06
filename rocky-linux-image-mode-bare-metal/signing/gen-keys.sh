#!/usr/bin/env bash
# Create (idempotently) every key the PoC signs with, plus the vendor public keys
# that consumers need for gpgcheck=1 on the proxied repos.
#
#   signing/keys/                      (gitignored, mode 700)
#     cosign.key, cosign.pub           cosign key pair for image signatures.
#                                      PoC: COSIGN_PASSWORD="" (unencrypted at rest
#                                      apart from cosign's empty-password scrypt box).
#                                      Production: a real password, a KMS URI, or an HSM.
#     gnupg/                           throwaway GNUPGHOME holding the RPM signing key
#                                      (RSA 4096, no passphrase, PoC only)
#     pub/edge-cosign.pub              public half of cosign.key
#     pub/RPM-GPG-KEY-edge             public half of the RPM signing key (armored)
#     pub/RPM-GPG-KEY-Rancher          https://rpm.rancher.io/public.key
#     pub/RPM-GPG-KEY-EPEL-10          https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-10
#     pub/RPM-GPG-KEY-Rocky-10         copied out of the base image (rocky-gpg-keys RPM),
#                                      only as a reference; consumers use the in-image copy
#
# Nothing private ever leaves signing/keys/. Re-running never regenerates an existing key.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS="$HERE/keys"
PUB="$KEYS/pub"
RPM_UID="${RPM_UID:-Edge Site Signing <edge@example.invalid>}"
BASE_LOCAL="${BASE_LOCAL:-localhost/rocky-bootc-base:10}"
log() { echo "keys: $*"; }

umask 077
mkdir -p "$KEYS" "$PUB"
chmod 700 "$KEYS"

# 1. cosign key pair --------------------------------------------------------------
if [[ -s "$KEYS/cosign.key" && -s "$KEYS/cosign.pub" ]]; then
  log "cosign key pair exists, keeping it"
else
  ( cd "$KEYS" && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix cosign >/dev/null )
  log "generated cosign key pair (COSIGN_PASSWORD empty, PoC only)"
fi
install -m 0644 "$KEYS/cosign.pub" "$PUB/edge-cosign.pub"

# 2. RPM signing key (gpg, throwaway homedir) -------------------------------------------
export GNUPGHOME="$KEYS/gnupg"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
if gpg --batch --list-secret-keys "$RPM_UID" >/dev/null 2>&1; then
  log "RPM signing key exists, keeping it"
else
  gpg --batch --quiet --gen-key <<GPG
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: ${RPM_UID% <*}
Name-Email: $(sed -E 's/.*<(.*)>/\1/' <<<"$RPM_UID")
Expire-Date: 0
%commit
GPG
  log "generated RPM signing key (RSA 4096, no passphrase, PoC only)"
fi
gpg --batch --quiet --armor --export "$RPM_UID" > "$PUB/RPM-GPG-KEY-edge"
fpr=$(gpg --batch --with-colons --list-keys "$RPM_UID" | awk -F: '/^fpr:/ {print $10; exit}')
echo "$fpr" > "$PUB/RPM-GPG-KEY-edge.fingerprint"
# gpg-agent is only needed while signing; do not leave one running on the throwaway homedir.
gpgconf --kill gpg-agent 2>/dev/null || true

# 3. Vendor keys ---------------------------------------------------------------------
fetch() { # fetch URL DEST
  if [[ -s "$2" ]]; then return 0; fi
  curl -fsSL -o "$2.tmp" "$1"
  grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$2.tmp" || { echo "gen-keys.sh: $1 is not an armored key" >&2; rm -f "$2.tmp"; exit 1; }
  mv "$2.tmp" "$2"; log "fetched $(basename "$2") from $1"
}
fetch https://rpm.rancher.io/public.key                              "$PUB/RPM-GPG-KEY-Rancher"
fetch https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-10      "$PUB/RPM-GPG-KEY-EPEL-10"
# Rocky's key ships in the base image (rocky-gpg-keys); keep a copy only for reference.
if [[ ! -s "$PUB/RPM-GPG-KEY-Rocky-10" ]] && podman image exists "$BASE_LOCAL" 2>/dev/null; then
  podman run --rm "$BASE_LOCAL" cat /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10 > "$PUB/RPM-GPG-KEY-Rocky-10"
  log "copied RPM-GPG-KEY-Rocky-10 out of $BASE_LOCAL"
fi
chmod 0644 "$PUB"/*

# 4. Summary (public material only) ------------------------------------------------------
log "public keys in $PUB:"
for f in "$PUB"/*; do
  case "$f" in
    *.pub) printf '  %-28s cosign/ECDSA P-256\n' "$(basename "$f")" ;;
    *.fingerprint) ;;
    *) info="$(gpg --batch --with-colons --import-options show-only --import "$f" 2>/dev/null \
               | awk -F: '/^fpr:/{f=$10} /^uid:/{print f"  "$10; exit}' || true)"
       # Rocky 10's key file also carries a v6 (RFC 9580) key; GnuPG 2.4 cannot parse
       # v6 packets, rpm (Sequoia) can. See docs/findings-signing.md.
       printf '  %-28s %s\n' "$(basename "$f")" "${info:-(not parseable by $(gpg --version | head -1); rpm/Sequoia reads it)}" ;;
  esac
done
