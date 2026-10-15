#!/bin/bash
# BridgeBox NAT / port-redirect rules (idempotent).
# Redirects guest HTTP/HTTPS on the AP (hotspot) interface to the app on
# APP_PORT. IFACE must be the AP interface (wlan0) — NOT the client radio.
# Run as root. Safe to re-run: it flushes and re-adds its own PREROUTING rules.
# Applied once at boot by bridge-box-root.sh; also exposed via apply-nat.sh.

set -euo pipefail

# AP (hotspot) interface. An explicit IFACE= from the caller (bridge-box-root.sh
# passes the resolved AP_IFACE) wins; otherwise read the role from the box-local
# interfaces.conf so a standalone run (e.g. apply-nat.sh) still targets the AP
# radio instead of assuming wlan0. IFACE must be the AP radio, NOT the client.
AP_IFACE="wlan0"
[ -f /home/bridgebox/interfaces.conf ] && . /home/bridgebox/interfaces.conf
IFACE="${IFACE:-$AP_IFACE}"
APP_PORT="${APP_PORT:-3000}"

# Ensure forwarding is on (NM 'shared' also does this, belt and braces).
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Rebuild only the redirect rules we own.
iptables -t nat -F PREROUTING
iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80  -j REDIRECT --to-port "$APP_PORT"
iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-port "$APP_PORT"

# Persist so they survive reboot.
netfilter-persistent save >/dev/null 2>&1 || true

echo "NAT redirects applied: $IFACE 80/443 -> $APP_PORT"
