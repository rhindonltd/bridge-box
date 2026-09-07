#!/bin/bash
# BridgeBox manual OS maintenance (#5).
#
# The automatic boot-time flow deliberately does NOT run `apt upgrade`, so the
# box is predictable and can't be broken by an unattended kernel/firmware change
# while a club is relying on it (see the OS-update policy in structure.md).
#
# Run this by hand, occasionally, when the box has internet and no session is in
# progress, to apply OS security updates:
#
#   sudo /home/bridgebox/bridge-box/bridge-box-os-update.sh
#
# It refuses to run without internet and reminds you to reboot if the kernel
# changed.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo." >&2
    exit 1
fi

# Coordinate with the update service and bring the box online (via the
# wifi.json client network if not already connected); always return to hotspot
# mode afterwards.
# shellcheck source=bridge-box-wifi-lib.sh
. /home/bridgebox/bridge-box/bridge-box-wifi-lib.sh
if ! bb_acquire_lock; then
    echo "Aborting — try again shortly." >&2
    exit 1
fi
trap bb_return_to_hotspot EXIT
if ! bb_wifi_online; then
    echo "Could not get the box online (check wifi.json). Aborting." >&2
    exit 1
fi

echo "=== BridgeBox OS update $(date -Is) ==="

KERNEL_BEFORE=$(uname -r)

DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
DEBIAN_FRONTEND=noninteractive apt-get -y autoremove

KERNEL_AFTER=$(uname -r)  # note: reflects running kernel, not the installed one

echo "=== OS update complete ==="
echo "If a new kernel or firmware was installed, reboot to apply it:"
echo "    sudo reboot"
if [ "$KERNEL_BEFORE" != "$KERNEL_AFTER" ]; then
    echo "Kernel changed ($KERNEL_BEFORE -> $KERNEL_AFTER) — reboot recommended."
fi
