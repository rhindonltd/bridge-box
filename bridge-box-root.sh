#!/bin/bash
# BridgeBox root startup — hotspot, firewall, NAT

set -euo pipefail
LOGFILE="/home/bridgebox/root.log"

# Bounded logging: truncate to the most recent ~2.5 MB if it grows past ~5 MB,
# so the log can't slowly fill the disk over the life of the device.
MAX_LOG_BYTES=$((5 * 1024 * 1024))
if [ -f "$LOGFILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt "$MAX_LOG_BYTES" ]; then
        tail -c "$((MAX_LOG_BYTES / 2))" "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null || true
        mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null || true
    fi
fi
exec > >(tee -a "$LOGFILE") 2>&1

IFACE="wlan0"
APP_PORT=3000
CONNECTION_NAME="bridge-hotspot"
NEW_HOSTNAME="bridge"

echo "=== BridgeBox root setup ==="

# Delete old hotspot if exists
nmcli connection delete "$CONNECTION_NAME" 2>/dev/null || true

# Hotspot setup
MAC=$(cat /sys/class/net/$IFACE/address | tr -d ':' | tail -c 5 | tr '[:lower:]' '[:upper:]')
HOTSPOT_SSID="BridgeBox-$MAC"

# Hotspot password: a known, posted credential so any player in the room can
# join quickly (read it off a card/sign on the table). Default is "bridgebox";
# a club can override it by putting HOTSPOT_PASS="..." in
# /home/bridgebox/hotspot.conf. The effective SSID + password are written to
# hotspot-credentials.txt so an admin can print them.
HOTSPOT_PASS="bridgebox"
if [ -f /home/bridgebox/hotspot.conf ]; then
    # shellcheck disable=SC1091
    . /home/bridgebox/hotspot.conf
fi
CREDS_FILE="/home/bridgebox/hotspot-credentials.txt"
{
    echo "SSID: $HOTSPOT_SSID"
    echo "Password: $HOTSPOT_PASS"
} > "$CREDS_FILE"
chown bridgebox:bridgebox "$CREDS_FILE" 2>/dev/null || true
chmod 644 "$CREDS_FILE"

nmcli device wifi hotspot ifname "$IFACE" con-name "$CONNECTION_NAME" ssid "$HOTSPOT_SSID" password "$HOTSPOT_PASS"
nmcli connection modify "$CONNECTION_NAME" ipv4.method shared connection.autoconnect yes connection.autoconnect-priority 100

echo "Hotspot '$HOTSPOT_SSID' active."

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# Captive portal: hijack DNS on the hotspot to the box so guests land on the
# app. This may cycle the hotspot connection to reload dnsmasq, so run it
# BEFORE applying NAT (NAT is applied last to reflect the final link state).
IFACE="$IFACE" HOTSPOT_CONNECTION="$CONNECTION_NAME" /home/bridgebox/bridge-box/bridge-box-captive.sh || \
    echo "WARNING: captive portal setup failed — app still reachable by typing bridge.local."

# NAT / port redirect (shared, idempotent script — same one re-applied after an
# update cycle switches wlan0 and returns to hotspot mode).
IFACE="$IFACE" APP_PORT="$APP_PORT" /home/bridgebox/bridge-box/bridge-box-nat.sh

sudo hostnamectl set-hostname bridge
sudo sed -i "s/127\.0\.1\.1\s\+.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts

sudo systemctl restart avahi-daemon

echo "=== BridgeBox root setup complete ==="