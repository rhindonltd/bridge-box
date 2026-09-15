#!/bin/bash
# BridgeBox manual OS maintenance (#5).
#
# The automatic boot-time flow deliberately does NOT run `apt upgrade`, so the
# box is predictable and can't be broken by an unattended kernel/firmware change
# while a club is relying on it (see the OS-update policy in structure.md).
#
# Run this by hand, occasionally, to apply OS security updates:
#
#   sudo /home/bridgebox/bridge-box/bridge-box-os-update.sh
#
# It refuses to run without internet and reminds you to reboot if the kernel
# changed. It no longer touches the hotspot (that's a separate radio), but the
# apt upgrade + any reboot still disrupt play, so prefer running it when idle.

set -euo pipefail

if [ "${EUID:-$(id -u 2>/dev/null || echo 1000)}" != "0" ]; then
    echo "Please run with sudo." >&2
    exit 1
fi

# Make sure the box is online (the dedicated client radio is normally already
# connected from boot; this is a cheap re-check / best-effort bring-up via
# wifi.json). The hotspot is on a separate radio and is unaffected — no lock, no
# return-to-hotspot needed any more.
# shellcheck source=bridge-box-wifi-lib.sh
. /home/bridgebox/bridge-box/bridge-box-wifi-lib.sh
if ! bb_wifi_online; then
    echo "Could not get the box online (check wifi.json / client adapter). Aborting." >&2
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
