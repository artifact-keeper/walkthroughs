#!/usr/bin/env bash
# Render deploy/ks.cfg.in -> deploy/state/www/ks.cfg.
# The SSH public key is read here, at render time, so it never lands in git.
source "$(dirname "$0")/lib.sh"

[[ -r "$SSH_PUBKEY" ]] || die "public key $SSH_PUBKEY not found (set SSH_PUBKEY=...)"
key="$(head -n1 "$SSH_PUBKEY")"
[[ "$key" =~ ^(ssh-|ecdsa-|sk-) ]] || die "$SSH_PUBKEY does not look like an OpenSSH public key"
[[ "$key" != *'"'* && "$key" != *'|'* ]] || die "unexpected characters in $SSH_PUBKEY"

mkdir -p "$WWW_DIR"
out="$WWW_DIR/ks.cfg"
sed -e "s|@REGISTRY@|$REGISTRY|g" \
    -e "s|@IMAGE@|$IMAGE_REF|g" \
    -e "s|@IMAGE_REPO@|${IMAGE_REF%:*}|g" \
    -e "s|@SIGNED_REPO@|$HOST_REGISTRY/${IMAGE_REF%:*}|g" \
    -e "s|@KEY_URL@|$KEY_URL|g" \
    -e "s|@HOSTNAME@|$NODE_HOSTNAME|g" \
    -e "s|@SSH_KEY@|$key|g" \
    "${KS_TEMPLATE:-$DEPLOY_DIR/ks.cfg.in}" > "$out"
grep -q '@[A-Z_]*@' "$out" && die "unrendered placeholder left in $out"
log "rendered $out (image $REGISTRY/$IMAGE_REF, host $NODE_HOSTNAME)"
