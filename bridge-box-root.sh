#!/bin/bash
# BridgeBox root startup — hotspot, firewall, NAT

set -euo pipefail
LOGFILE="/home/bridgebox/root.log"
exec > >(tee -a "$LOGFILE") 2>&1

IFACE="wlan0"
APP_PORT=3000
CONNECTION_NAME="bridge-hotspot"

echo "=== BridgeBox root setup ==="

# Delete old hotspot if exists
nmcli connection delete "$CONNECTION_NAME" 2>/dev/null || true

# Hotspot setup
MAC=$(cat /sys/class/net/$IFACE/address | tr -d ':' | tail -c 5 | tr '[:lower:]' '[:upper:]')
HOTSPOT_SSID="BridgeBox-$MAC"
HOTSPOT_PASS="bridgebox"

nmcli device wifi hotspot ifname "$IFACE" con-name "$CONNECTION_NAME" ssid "$HOTSPOT_SSID" password "$HOTSPOT_PASS"
nmcli connection modify "$CONNECTION_NAME" ipv4.method shared connection.autoconnect yes connection.autoconnect-priority 100

echo "Hotspot '$HOTSPOT_SSID' active."

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# NAT / port redirect
iptables -t nat -F
iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80 -j REDIRECT --to-port $APP_PORT
iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-port $APP_PORT
netfilter-persistent save

echo "=== BridgeBox root setup complete ==="