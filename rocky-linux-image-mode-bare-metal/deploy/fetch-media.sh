#!/usr/bin/env bash
# Download Rocky pxeboot vmlinuz + initrd.img (and, with STAGE2=local, the 750 MB
# stage2 images/install.img) into deploy/cache/ and verify them against the sha256
# sums in the tree's .treeinfo. Re-runs are no-ops when cached files still match.
# STAGE2=local also lays out state/www/os/{.treeinfo,images/install.img} (symlinks)
# so the installer fetches stage2 from serve-ks.sh instead of dl.rockylinux.org,
# which is what a PXE install server does. (Under KVM the 3 MB/s mirror download of
# install.img was 250 s of a 290 s path to "Starting installer".)
source "$(dirname "$0")/lib.sh"

treeinfo="$CACHE_DIR/treeinfo"
curl -fsSL --retry 3 -o "$treeinfo.new" "$ROCKY_TREE/.treeinfo"
mv "$treeinfo.new" "$treeinfo"

files=(images/pxeboot/vmlinuz images/pxeboot/initrd.img)
[[ "$STAGE2" == local ]] && files+=(images/install.img)
for path in "${files[@]}"; do
  f="$(basename "$path")"
  want="$(awk -F' *= *' -v k="$path" '$1==k {sub(/^sha256:/,"",$2); print $2}' "$treeinfo")"
  [[ -n "$want" ]] || die "no sha256 for $path in $ROCKY_TREE/.treeinfo"
  dest="$CACHE_DIR/$f"
  if [[ -f "$dest" ]] && echo "$want  $dest" | sha256sum -c --status; then
    log "$f cached and verified"
    continue
  fi
  log "downloading $f"
  curl -fsSL --retry 3 -o "$dest.part" "$ROCKY_TREE/$path"
  echo "$want  $dest.part" | sha256sum -c --status || die "$f checksum mismatch"
  mv "$dest.part" "$dest"
  log "$f verified sha256:$want"
done

if [[ "$STAGE2" == local ]]; then
  mkdir -p "$WWW_DIR/os/images"
  ln -sfn "$treeinfo" "$WWW_DIR/os/.treeinfo"
  ln -sfn "$CACHE_DIR/install.img" "$WWW_DIR/os/images/install.img"
  log "stage2 served locally: $STAGE2_URL"
fi
