#!/bin/bash
# BridgeBox AP network services: static IP + DHCP + captive DNS on the AP radio.
#
# When the hotspot was run by NetworkManager's "shared" mode, NM provided three
# things on the AP interface for free: a static IP (10.42.0.1/24), a DHCP server,
# and a dnsmasq we hijacked for the captive portal. Now that hostapd runs the AP
# (see bridge-box-hostapd.sh), WE provide those three things ourselves:
#   1. assign 10.42.0.1/24 to the AP interface,
#   2. run a dedicated dnsmasq bound to the AP interface for DHCP, and
#   3. (unless disabled) make that dnsmasq answer EVERY DNS name with the box IP
#      so guests who open any URL land on the app (captive portal).
#
# This script writes the dnsmasq config, assigns the IP, and exec's dnsmasq in
# the FOREGROUND so systemd (bridge-box-apnet.service) supervises it directly.
# It does NOT run hostapd (that's bridge-box-hostapd.sh) and does NOT touch the
# CLIENT radio or NetworkManager — the box's own outbound DNS on the client link
# is unaffected (our dnsmasq binds the AP interface only).
#
# Run as root (via its systemd unit).

set -uo pipefail

INSTALL_DIR="/home/bridgebox"
DNSMASQ_BIN="/usr/sbin/dnsmasq"
CONF_OUT="/etc/bridgebox/ap-dnsmasq.conf"

# --- Interface role ---
AP_IFACE="wlan0"
# shellcheck disable=SC1091
[ -f "$INSTALL_DIR/interfaces.conf" ] && . "$INSTALL_DIR/interfaces.conf"
IFACE="${AP_IFACE:-wlan0}"

# --- AP network addressing (matches the old NM-shared 10.42.0.0/24) ---
AP_ADDR="10.42.0.1"
AP_CIDR="24"
AP_NETMASK="255.255.255.0"
DHCP_START="10.42.0.10"
DHCP_END="10.42.0.254"
DHCP_LEASE="1h"

# --- Captive portal toggle (same semantics as before) ---
# CAPTIVE_PORTAL="no" in captive.conf disables the DNS hijack; DHCP still runs.
CAPTIVE_PORTAL="yes"
# shellcheck disable=SC1091
[ -f "$INSTALL_DIR/captive.conf" ] && . "$INSTALL_DIR/captive.conf"

# --- Assign the AP interface its static IP (idempotent) ---
# hostapd brings the radio up as an AP but does NOT assign an IP; we do it here.
# `|| true` so a re-run (address already present) doesn't abort under -e-less set.
ip addr add "$AP_ADDR/$AP_CIDR" dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" up 2>/dev/null || true

# --- Write the dnsmasq config ---
mkdir -p "$(dirname "$CONF_OUT")"
{
    echo "# Managed by bridge-box-apnet.sh — do not edit by hand."
    echo "interface=$IFACE"
    echo "bind-interfaces"            # ONLY this interface — never the client radio
    echo "except-interface=lo"
    echo "no-resolv"                  # don't consult upstream for guest queries
    echo "no-hosts"
    echo "dhcp-range=$DHCP_START,$DHCP_END,$AP_NETMASK,$DHCP_LEASE"
    echo "dhcp-option=option:router,$AP_ADDR"
    echo "dhcp-option=option:dns-server,$AP_ADDR"
    if [ "$CAPTIVE_PORTAL" = "yes" ]; then
        # Answer EVERY name with the box IP so any URL opens the app.
        echo "address=/#/$AP_ADDR"
    fi
} > "$CONF_OUT"

if [ "$CAPTIVE_PORTAL" = "yes" ]; then
    echo "bridge-box-apnet: AP $IFACE = $AP_ADDR, DHCP $DHCP_START-$DHCP_END, captive DNS ON (all names -> $AP_ADDR)."
else
    echo "bridge-box-apnet: AP $IFACE = $AP_ADDR, DHCP $DHCP_START-$DHCP_END, captive DNS OFF (DHCP only)."
fi

# exec dnsmasq in the foreground (--keep-in-foreground) so systemd supervises it.
# --conf-file= (empty) stops it reading /etc/dnsmasq.conf or the distro dir; we
# pass our own file explicitly so nothing else leaks in.
exec "$DNSMASQ_BIN" --keep-in-foreground --conf-file="$CONF_OUT"
