#!/bin/bash
# BridgeBox AP-radio swap TEST (reversible).
#
# Purpose: run the hotspot on a USB WiFi adapter instead of the onboard Broadcom
# (brcmfmac), because the Broadcom AP refuses some clients — notably Amazon Fire
# tablets — at the 802.11 layer, for reasons no software setting we tried could
# shift. The onboard radio then becomes the client/internet link.
#
# IMPORTANT: the adapter used as the AP MUST support AP mode. The old Ralink
# mt7601U does NOT ("Device supports neither AP nor Ad-Hoc mode") — that's a
# dead end. A MediaTek mt7612u (driver mt76x2u) DOES and is the intended AP
# adapter. This script verifies AP capability before switching, so it won't
# leave you with a dead hotspot like a blind swap would.
#
# It identifies radios by DRIVER, not by fragile wlanN names (which shift when
# USB adapters are added/removed), then picks the AP interface as follows:
#   - prefers an AP-capable USB adapter (mt76x2u / mt7612u, etc.)
#   - the onboard brcmfmac becomes the client link.
#
#   sudo bash bridge-box-ap-swap-test.sh status   # show radios, drivers, AP capability
#   sudo bash bridge-box-ap-swap-test.sh swap     # AP -> USB adapter, client -> onboard
#   sudo bash bridge-box-ap-swap-test.sh restore  # back to AP -> onboard (wlan0)
#
# After `swap`, try the Fire tablet. If it works and you want it permanent, we
# wire it into provisioning properly — don't rely on this test script long-term.

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

# driver of a given wlan interface, e.g. brcmfmac / mt76x2u / mt7601u
_drv() { basename "$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null)" 2>/dev/null || echo "?"; }

# Does this interface support AP mode? Parse `iw phy` for "AP" under supported
# interface modes. Returns 0 (yes) / 1 (no).
_supports_ap() {
    local dev="$1" phy
    phy="$(iw dev "$dev" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')"
    [ -n "$phy" ] || return 1
    iw phy "$phy" info 2>/dev/null | awk '/Supported interface modes/{f=1;next} f&&/\* AP$/{print;exit}' | grep -q AP
}

# List wlan interfaces present.
_wlans() { for d in /sys/class/net/wlan*; do [ -e "$d" ] && basename "$d"; done; }

# Pick the best AP interface: first USB adapter (non-brcmfmac) that supports AP.
_pick_ap_iface() {
    local d drv
    for d in $(_wlans); do
        drv="$(_drv "$d")"
        [ "$drv" = "brcmfmac" ] && continue      # onboard = client, skip
        if _supports_ap "$d"; then echo "$d"; return 0; fi
    done
    return 1
}

# Pick the onboard (brcmfmac) interface for the client link.
_pick_onboard() {
    local d
    for d in $(_wlans); do
        [ "$(_drv "$d")" = "brcmfmac" ] && echo "$d" && return 0
    done
    return 1
}

show_status() {
    echo "=== Current interface roles ==="
    if [ -f "$IFACES_CONF" ]; then
        echo "interfaces.conf:"; sed 's/^/  /' "$IFACES_CONF"
    else
        echo "interfaces.conf: (absent — defaults AP=wlan0, CLIENT=wlan1)"
    fi
    echo
    echo "Radios present (driver + AP capability):"
    for w in $(_wlans); do
        if _supports_ap "$w"; then ap="AP-capable: YES"; else ap="AP-capable: NO"; fi
        printf '  %-7s driver=%-10s %s\n' "$w" "$(_drv "$w")" "$ap"
    done
    echo
    echo "Hotspot connection state:"
    nmcli -t -f NAME,STATE connection show --active 2>/dev/null | grep "^$CONNECTION_NAME:" | sed 's/^/  /' \
        || echo "  $CONNECTION_NAME not active"
}

# Tear down the current hotspot cleanly, write interfaces.conf, rebuild via root.sh.
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
    nmcli device disconnect "$ap_iface" 2>/dev/null || true

    echo "Re-running bridge-box-root.sh to rebuild hotspot on $ap_iface + client on $client_iface..."
    bash "$BOX_DIR/bridge-box-root.sh" || echo "WARNING: root.sh returned non-zero (check output above)."

    echo
    echo "Done. Give it ~15s to settle, then:"
    echo "  * check:  sudo bash $0 status"
    echo "  * from the Fire tablet, join the BridgeBox hotspot and test."
}

case "$ACTION" in
    swap)
        echo "### SWAP: hotspot -> AP-capable USB adapter, client link -> onboard Broadcom"
        AP_IF="$(_pick_ap_iface || true)"
        ONBOARD="$(_pick_onboard || true)"
        if [ -z "$AP_IF" ]; then
            echo "ERROR: no AP-capable USB adapter found."
            echo "       Plug in the MediaTek mt7612u adapter and check: sudo bash $0 status"
            echo "       (The old mt7601U does NOT support AP mode and cannot be the hotspot.)"
            exit 1
        fi
        if [ -z "$ONBOARD" ]; then
            echo "WARNING: onboard brcmfmac not found; using the AP adapter for the hotspot and"
            echo "         leaving the client link to whatever remains."
            ONBOARD="wlan0"
        fi
        echo "Chosen: AP=$AP_IF (driver $(_drv "$AP_IF")), CLIENT=$ONBOARD (driver $(_drv "$ONBOARD"))"
        rebuild "$AP_IF" "$ONBOARD"
        ;;
    restore)
        echo "### RESTORE: default roles — hotspot -> wlan0 (onboard), client -> wlan1"
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
