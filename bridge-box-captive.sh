#!/bin/bash
# BridgeBox captive-portal DNS hijack.
#
# Makes every DNS lookup from a device on the hotspot resolve to the box itself,
# so a guest who opens any web address lands on the scoring app (NAT already
# redirects 80/443 -> the app). Combined with the OS connectivity probes, most
# phones will also pop up the "sign in to network" sheet on join.
#
# Scope & safety:
# - The hijack is applied ONLY to NetworkManager's shared-connection dnsmasq
#   (the hotspot), via a dnsmasq.d drop-in. It does NOT change how the box
#   itself resolves names when it dials out to real WiFi for updates.
# - Reversible: remove the drop-in (or set CAPTIVE_PORTAL=no) and restart the
#   hotspot connection.
#
# Run as root (called from bridge-box-root.sh after the hotspot is up).

set -euo pipefail

IFACE="${IFACE:-wlan0}"
HOTSPOT_CONNECTION="${HOTSPOT_CONNECTION:-bridge-hotspot}"
# NetworkManager's shared mode assigns this by default (confirmed on our
# hardware). Used only as a fallback if the live interface lookup is empty.
DEFAULT_HOTSPOT_IP="10.42.0.1"
DROPIN_DIR="/etc/NetworkManager/dnsmasq-shared.d"
DROPIN_FILE="$DROPIN_DIR/010-bridgebox-captive.conf"
CONF="/home/bridgebox/captive.conf"

# Opt-out: a club can disable the portal with CAPTIVE_PORTAL="no" in captive.conf.
CAPTIVE_PORTAL="yes"
[ -f "$CONF" ] && . "$CONF"

if [ "$CAPTIVE_PORTAL" != "yes" ]; then
    echo "Captive portal disabled (captive.conf) — removing any drop-in."
    rm -f "$DROPIN_FILE"
    nmcli connection down "$HOTSPOT_CONNECTION" 2>/dev/null || true
    nmcli connection up "$HOTSPOT_CONNECTION" 2>/dev/null || true
    exit 0
fi

# Derive the box's own IP on the hotspot interface (don't hardcode). Fall back
# to the known NetworkManager shared-mode default if the lookup is empty (e.g.
# a race where the interface has no address yet).
HOTSPOT_IP=$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
if [ -z "$HOTSPOT_IP" ]; then
    HOTSPOT_IP="$DEFAULT_HOTSPOT_IP"
    echo "Could not read $IFACE address; falling back to default $HOTSPOT_IP."
fi

echo "Configuring captive portal: all DNS on $IFACE -> $HOTSPOT_IP"

mkdir -p "$DROPIN_DIR"
# address=/#/<ip> answers EVERY name with the box IP. no-resolv stops the
# shared dnsmasq from consulting upstream resolvers for hotspot clients.
cat > "$DROPIN_FILE" <<EOF
# Managed by bridge-box-captive.sh — do not edit by hand.
address=/#/$HOTSPOT_IP
no-resolv
EOF

# Restart the shared connection so NM's dnsmasq reloads the drop-in.
nmcli connection down "$HOTSPOT_CONNECTION" 2>/dev/null || true
nmcli connection up "$HOTSPOT_CONNECTION" 2>/dev/null || true

echo "Captive portal active (DNS -> $HOTSPOT_IP)."
