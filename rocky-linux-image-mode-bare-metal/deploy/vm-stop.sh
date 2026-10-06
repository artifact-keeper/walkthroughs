#!/usr/bin/env bash
# Clean guest shutdown: ssh poweroff, then ACPI powerdown via QMP, then kill.
source "$(dirname "$0")/lib.sh"
if ! vm_running; then log "VM not running"; rm -f "$QEMU_PIDFILE"; exit 0; fi
pid="$(vm_pid)"
log "stopping VM (pid $pid)"
vssh 'systemctl poweroff' 2>/dev/null || qmp system_powerdown >/dev/null 2>&1 || true
for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || break; sleep 2; done
if kill -0 "$pid" 2>/dev/null; then
  log "guest did not power off in 120s; quitting QEMU"
  qmp quit >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
  sleep 2; kill -9 "$pid" 2>/dev/null || true
fi
rm -f "$QEMU_PIDFILE"
stamp "stop: VM stopped"
