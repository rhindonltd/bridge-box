#!/bin/bash
# BridgeBox root startup — hotspot, firewall, NAT

set -euo pipefail
LOG_DIR="/home/bridgebox/logs"
LOGFILE="$LOG_DIR/root.log"
# Create the shared logs dir and hand it to bridgebox: this root unit runs first
# at boot, and the other (bridgebox-user) scripts write their own logs here too.
mkdir -p "$LOG_DIR"
chown bridgebox:bridgebox "$LOG_DIR" 2>/dev/null || true

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

# Give NetworkManager/the radio a moment to be ready at boot before we touch it.
nmcli networking connectivity check >/dev/null 2>&1 || true
sleep 3

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

# Bring the hotspot up, with retries. Don't let a single transient nmcli error
# (e.g. "active connection disappeared" from the radio still settling) abort the
# whole script — that used to fail the unit and, with restart-on-failure, spin.
bring_up_hotspot() {
    local attempt
    for attempt in 1 2 3 4 5; do
        # (Re)create only if it doesn't already exist / previous attempt failed.
        if ! nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$CONNECTION_NAME"; then
            nmcli device wifi hotspot ifname "$IFACE" con-name "$CONNECTION_NAME" \
                ssid "$HOTSPOT_SSID" password "$HOTSPOT_PASS" 2>&1 || true
            nmcli connection modify "$CONNECTION_NAME" ipv4.method shared \
                connection.autoconnect yes connection.autoconnect-priority 100 2>&1 || true
        fi
        # Confirm it's actually active.
        sleep 2
        if nmcli -t -f NAME,STATE connection show --active 2>/dev/null | grep -q "^$CONNECTION_NAME:activated"; then
            echo "Hotspot '$HOTSPOT_SSID' is active (attempt $attempt)."
            return 0
        fi
        echo "Hotspot not active yet (attempt $attempt) — retrying..."
        # Clear a half-made connection before the next attempt.
        nmcli connection delete "$CONNECTION_NAME" 2>/dev/null || true
        sleep 3
    done
    echo "WARNING: could not bring hotspot up after retries."
    return 1
}
bring_up_hotspot || true

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# Captive portal: hijack DNS on the hotspot to the box so guests land on the
# app. This may cycle the hotspot connection to reload dnsmasq, so run it
# BEFORE applying NAT (NAT is applied last to reflect the final link state).
IFACE="$IFACE" HOTSPOT_CONNECTION="$CONNECTION_NAME" bash /home/bridgebox/bridge-box/bridge-box-captive.sh || \
    echo "WARNING: captive portal setup failed — app still reachable by typing bridge.local."

# NAT / port redirect (shared, idempotent script — same one re-applied after an
# update cycle switches wlan0 and returns to hotspot mode).
IFACE="$IFACE" APP_PORT="$APP_PORT" bash /home/bridgebox/bridge-box/bridge-box-nat.sh

sudo hostnamectl set-hostname bridge
sudo sed -i "s/127\.0\.1\.1\s\+.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts

sudo systemctl restart avahi-daemon

echo "=== BridgeBox root setup complete ==="