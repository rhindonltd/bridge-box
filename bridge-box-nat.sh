#!/bin/bash
# BridgeBox NAT / port-redirect rules (idempotent).
# Redirects guest HTTP/HTTPS on the hotspot interface to the app on APP_PORT.
# Run as root. Safe to re-run: it flushes and re-adds its own PREROUTING rules,
# so it can be re-asserted after wlan0 has been switched to client mode and back
# (NetworkManager rebuilds routing for the shared connection, which can drop
# these manual redirects). Re-applied by bb_return_to_hotspot in the wifi lib.

set -euo pipefail

IFACE="${IFACE:-wlan0}"
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
