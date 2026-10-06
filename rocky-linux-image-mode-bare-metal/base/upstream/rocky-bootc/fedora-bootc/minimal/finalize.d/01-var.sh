#!/bin/bash
# https://gitlab.com/fedora/bootc/base-images/-/issues/28
set -xeuo pipefail
ln -s ../run var/run
# https://gitlab.com/fedora/bootc/tracker/-/issues/58
mkdir -p var/lib/rpm-state
test -d var/tmp || mkdir -m 1777 var/tmp
