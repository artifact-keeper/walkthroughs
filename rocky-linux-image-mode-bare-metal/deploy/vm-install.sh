#!/usr/bin/env bash
# Unattended kickstart install of the edge image onto a fresh 40G qcow2.
# Anaconda is network-booted from the Rocky mirror's pxeboot kernel/initrd; the
# kickstart pulls the bootc image from Artifact Keeper with `ostreecontainer`.
# QEMU runs with -no-reboot, so the `reboot` at the end of the kickstart makes it exit.
source "$(dirname "$0")/lib.sh"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-2400}"   # 40 min
SERIAL="$STATE_DIR/install-serial.log"

vm_running && die "a VM is running (pid $(vm_pid)); run 'make vm-stop' or 'make vm-clean' first"

# 1. The image must exist before we spend 10 minutes booting an installer.
log "checking $HOST_REGISTRY/$IMAGE_REF"
digest="$(skopeo inspect --no-creds --tls-verify=false "docker://$HOST_REGISTRY/$IMAGE_REF" | jq -r .Digest)" \
  || die "image $HOST_REGISTRY/$IMAGE_REF not found in the registry"
log "image digest $digest"
# Informational only: the installer enforces the signature itself (kickstart %pre policy).
if cosign verify --key "$REPO_ROOT/signing/keys/pub/edge-cosign.pub" --allow-http-registry --insecure-ignore-tlog \
     "$HOST_REGISTRY/${IMAGE_REF%:*}@$digest" >/dev/null 2>&1; then
  log "cosign: $digest is signed by the edge key"
else
  log "cosign: $digest is NOT signed by the edge key; expect the installer to reject it"
fi

# 2. Media, kickstart, HTTP server.
"$DEPLOY_DIR/fetch-media.sh"
"$DEPLOY_DIR/render-ks.sh"
"$DEPLOY_DIR/serve-ks.sh" stop >/dev/null
"$DEPLOY_DIR/serve-ks.sh" start
trap '"$DEPLOY_DIR/serve-ks.sh" stop >/dev/null 2>&1 || true' EXIT

# 3. Fresh disk + private copy of the UEFI variable store.
rm -f "$DISK" "$VARS" "$SERIAL" "$STATE_DIR/boot-serial.log"
qemu-img create -q -f qcow2 "$DISK" "$VM_DISK_SIZE"
cp "$OVMF_VARS_TEMPLATE" "$VARS"
: > "$TIMINGS"
echo "image=$HOST_REGISTRY/$IMAGE_REF digest=$digest" >> "$TIMINGS"

mapfile -t COMMON < <(qemu_common_args)
log "accel: $(qemu_accel_args); ${VM_SMP} vCPU, ${VM_MEM} MiB"
stamp "install: qemu start"
qemu-system-x86_64 "${COMMON[@]}" \
  -netdev user,id=n0 \
  -kernel "$CACHE_DIR/vmlinuz" -initrd "$CACHE_DIR/initrd.img" \
  -append "inst.stage2=$STAGE2_URL inst.ks=http://10.0.2.2:$KS_PORT/ks.cfg inst.text console=ttyS0,115200n8" \
  -serial "file:$SERIAL" -no-reboot \
  -pidfile "$QEMU_PIDFILE" &
qpid=$!

# 4. Follow progress through Anaconda's milestones in the serial log.
pat='Starting installer|Starting automated install|Configuring storage|Installing the software|Performing post-installation|Installation complete|Traceback|An unknown error|kickstart.*error|Pane is dead|reboot: Restarting'
# Signature/policy failures from containers-image / ostree-ext. Anaconda shows them
# in a modal error and then waits forever, so stop as soon as one appears.
sigpat='Source image rejected|A signature was required|Signature for identity|signature verification|[Ii]nvalid signature|policy.*insecureAcceptAnything|refusing usage'
clean_serial() { tr -d '\r' < "$SERIAL" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }
seen=0 start=$SECONDS
while kill -0 "$qpid" 2>/dev/null; do
  if [[ -f "$SERIAL" ]] && clean_serial | grep -aqE "$sigpat"; then
    stamp "install: SIGNATURE VERIFICATION FAILED (+$((SECONDS - start))s)"
    clean_serial | grep -aE -B3 -A6 "$sigpat" | head -40 >&2
    sleep 5; kill "$qpid" 2>/dev/null || true; wait "$qpid" 2>/dev/null || true
    rm -f "$QEMU_PIDFILE"
    die "install aborted: the image failed signature verification (full log: $SERIAL)"
  fi
  if (( SECONDS - start > INSTALL_TIMEOUT )); then
    kill "$qpid" 2>/dev/null || true
    clean_serial | tail -c 4000 >&2 || true
    die "install did not finish within ${INSTALL_TIMEOUT}s"
  fi
  if [[ -f "$SERIAL" ]]; then
    mapfile -t hits < <(clean_serial | grep -aoE "$pat" | awk '!seen[$0]++')
    for ((i = seen; i < ${#hits[@]}; i++)); do stamp "install: ${hits[$i]} (+$((SECONDS - start))s)"; done
    seen=${#hits[@]}
  fi
  sleep 5
done
wait "$qpid" || die "qemu exited with status $?"
rm -f "$QEMU_PIDFILE"

grep -aq 'Installation complete' "$SERIAL" || die "QEMU exited but Anaconda never reported 'Installation complete' (see $SERIAL)"
stamp "install: done in $((SECONDS - start))s"
log "next: make vm-boot"
