#!/usr/bin/env bash
# ssh into the running VM as root (key auth only). Extra args are run as a command.
source "$(dirname "$0")/lib.sh"
vm_running || die "VM is not running; 'make vm-boot' first"
exec ssh "${SSH_OPTS[@]}" -o BatchMode=no root@localhost "$@"
