#!/bin/bash
# BridgeBox AP-radio swap TEST (reversible).
#
# Purpose: test whether running the hotspot on the USB mt7601U radio (wlan1)
# instead of the onboard Broadcom (wlan0) lets an Amazon Fire tablet associate.
# The Broadcom AP refuses some clients (Fire tablets) at the 802.11 layer for
# reasons no software setting we tried could shift; the mt7601U is a different
# chipset/driver and may just work.
#
# This is a TEST, not a committed change: it writes interfaces.conf with the
# roles swapped and rebuilds the hotspot cleanly, OR rolls back to the default
# (onboard = hotspot). It changes nothing else and is fully reversible.
#
#   sudo bash bridge-box-ap-swap-test.sh swap     # AP -> wlan1 (USB), client -> wlan0
#   sudo bash bridge-box-ap-swap-test.sh restore  # back to AP -> wlan0, client -> wlan1
#   sudo bash bridge-box-ap-swap-test.sh status   # show current roles + hotspot state
#
# After `swap`, try the Fire tablet. After testing, run `restore` to return to
# the known-good default (or, if swap works and you want it permanent, we wire
# it into provisioning properly — don't rely on this test script long-term).

set -uo pipefail

INSTALL_DIR="/home/bridgebox"
BOX_DIR="$INSTALL_DIR/bridge-box"
IFACES_CONF="$INSTALL_DIR/interfaces.conf"
CONNECTION_NAME="bridge-hotspot"

if [ "$(id -u)" != "0" ]; then
    echo "Run with sudo: sudo bash $0 <swap|restore|status>"
    exit 1
fi

ACTION="${1:-status}"

show_status() {
    echo "=== Current interface roles ==="
    if [ -f "$IFACES_CONF" ]; then
        echo "interfaces.conf:"; sed 's/^/  /' "$IFACES_CONF"
    else
        echo "interfaces.conf: (absent — defaults AP=wlan0, CLIENT=wlan1)"
    fi
    echo
    echo "Radios present:"
    for w in wlan0 wlan1; do
        if [ -e "/sys/class/net/$w" ]; then
            drv=$(basename "$(readlink -f "/sys/class/net/$w/device/driver" 2>/dev/null)" 2>/dev/null || echo "?")
            typ=$(iw dev "$w" info 2>/dev/null | awk '/type/{print $2}')
            echo "  $w: driver=$drv type=${typ:-unknown}"
        else
            echo "  $w: NOT present"
        fi
    done
    echo
    echo "Hotspot connection state:"
    nmcli -t -f NAME,STATE connection show --active 2>/dev/null | grep "^$CONNECTION_NAME:" | sed 's/^/  /' \
        || echo "  $CONNECTION_NAME not active"
}

# Tear down the current hotspot connection so a fresh one is built on the new
# interface (the earlier "Pi got confused" was this step being skipped — the old
# connection stayed pinned to the old radio).
rebuild() {
    local ap_iface="$1" client_iface="$2"
    echo "Setting roles: AP=$ap_iface  CLIENT=$client_iface"
    cat > "$IFACES_CONF" <<EOF
# Written by bridge-box-ap-swap-test.sh ($(date -Is)).
# Remove this file (or run 'restore') to return to defaults (AP=wlan0/CLIENT=wlan1).
AP_IFACE="$ap_iface"
CLIENT_IFACE="$client_iface"
EOF

    echo "Tearing down any existing hotspot + stale radio connections..."
    nmcli connection down "$CONNECTION_NAME" 2>/dev/null || true
    nmcli connection delete "$CONNECTION_NAME" 2>/dev/null || true
    # Also drop any auto client profile so the client radio re-attaches on the
    # right interface when root.sh re-runs.
    nmcli device disconnect "$ap_iface" 2>/dev/null || true

    echo "Re-running bridge-box-root.sh to rebuild hotspot on $ap_iface + client on $client_iface..."
    # root.sh reads interfaces.conf we just wrote and does hotspot+captive+NAT+client.
    bash "$BOX_DIR/bridge-box-root.sh" || echo "WARNING: root.sh returned non-zero (check output above)."

    echo
    echo "Done. Give it ~15s to settle, then:"
    echo "  * check:  sudo bash $0 status"
    echo "  * from the Fire tablet, join the BridgeBox hotspot and test."
}

case "$ACTION" in
    swap)
        echo "### SWAP: hotspot -> wlan1 (USB mt7601U), client link -> wlan0 (onboard)"
        if [ ! -e /sys/class/net/wlan1 ]; then
            echo "ERROR: wlan1 (USB adapter) not present — can't put the AP there."
            exit 1
        fi
        rebuild "wlan1" "wlan0"
        ;;
    restore)
        echo "### RESTORE: default roles — hotspot -> wlan0 (onboard), client -> wlan1 (USB)"
        rebuild "wlan0" "wlan1"
        echo "(interfaces.conf now pins the defaults explicitly; delete it if you prefer the implicit default.)"
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: sudo bash $0 <swap|restore|status>"
        exit 1
        ;;
esac
