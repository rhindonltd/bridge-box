#!/bin/bash
# BridgeBox hotspot via hostapd (replaces NetworkManager's built-in hotspot).
#
# WHY hostapd instead of `nmcli device wifi hotspot`:
#   NetworkManager's AP mode advertises 802.11n (HT) capabilities and WMM in its
#   beacon. Some budget clients — confirmed with Amazon Fire tablets (Fire 7
#   9th-gen) — refuse to ASSOCIATE with such a beacon (they never send a single
#   frame), while modern phones are fine. A stripped-down hostapd beacon (legacy
#   802.11g, no HT, no WMM, no PMF, plain WPA2-PSK/CCMP) lets those clients join.
#   This was proven on-device: the exact config below is what made a Fire 7
#   associate, get a DHCP lease, and load the app, on the onboard Broadcom radio.
#
# This script GENERATES the hostapd config from the box's effective SSID/password
# and then exec's hostapd in the FOREGROUND, so systemd (bridge-box-hostapd.service)
# supervises it directly (Restart=on-failure). It does NOT background itself.
#
# The AP interface's IP address + DHCP + captive DNS are handled separately by
# bridge-box-apnet.sh (this script is ONLY the 802.11 AP/beacon).
#
# Run as root (via its systemd unit).

set -uo pipefail

INSTALL_DIR="/home/bridgebox"
CONF_OUT="/etc/hostapd/bridge-box.conf"
HOSTAPD_BIN="/usr/sbin/hostapd"

# --- Interface role (same resolution as bridge-box-root.sh) ---
AP_IFACE="wlan0"
# shellcheck disable=SC1091
[ -f "$INSTALL_DIR/interfaces.conf" ] && . "$INSTALL_DIR/interfaces.conf"
IFACE="${AP_IFACE:-wlan0}"

# --- SSID: BridgeBox-XXXX derived from the AP radio MAC (matches old behaviour) ---
if [ -r "/sys/class/net/$IFACE/address" ]; then
    MAC=$(tr -d ':' < "/sys/class/net/$IFACE/address" | tail -c 5 | tr '[:lower:]' '[:upper:]')
else
    MAC="0000"
fi
HOTSPOT_SSID="BridgeBox-$MAC"

# --- Password + channel: defaults, overridable in hotspot.conf ---
# HOTSPOT_PASS: the known, posted guest password (default "bridgebox").
# HOTSPOT_CHANNEL: 2.4GHz channel; default 6 (hostapd needs an explicit channel,
#   unlike NM's auto-select). 1/6/11 are the non-overlapping choices.
# HOTSPOT_COUNTRY: deliberately EMPTY by default. The onboard Broadcom is a
#   self-managed-regulatory radio that reports "country 99"; forcing a country
#   code previously caused trouble and the box works without it. Only set this if
#   you know you need it.
HOTSPOT_PASS="bridgebox"
HOTSPOT_CHANNEL="6"
HOTSPOT_COUNTRY=""
# shellcheck disable=SC1091
[ -f "$INSTALL_DIR/hotspot.conf" ] && . "$INSTALL_DIR/hotspot.conf"

# WPA2 passphrase must be 8..63 chars; fall back to the default if misconfigured
# rather than producing a hostapd config that won't start.
if [ "${#HOTSPOT_PASS}" -lt 8 ] || [ "${#HOTSPOT_PASS}" -gt 63 ]; then
    echo "bridge-box-hostapd: HOTSPOT_PASS invalid length (${#HOTSPOT_PASS}); using default."
    HOTSPOT_PASS="bridgebox"
fi

# --- Write the hostapd config ---
# The parameter choices below are LOAD-BEARING for Fire-tablet compatibility:
#   hw_mode=g + ieee80211n=0  -> legacy 802.11g beacon, no HT capabilities
#   wmm_enabled=0             -> no WMM/QoS element
#   ieee80211w=0              -> PMF disabled (802.11w off)
#   wpa=2 / WPA-PSK / CCMP    -> plain WPA2-Personal, no WPA3/SAE/transition
# Do not "modernise" these without re-testing on a Fire tablet.
mkdir -p "$(dirname "$CONF_OUT")"
{
    echo "# Managed by bridge-box-hostapd.sh — do not edit by hand."
    echo "interface=$IFACE"
    echo "driver=nl80211"
    echo "ssid=$HOTSPOT_SSID"
    echo "hw_mode=g"
    echo "channel=$HOTSPOT_CHANNEL"
    echo "ieee80211n=0"
    echo "wmm_enabled=0"
    echo "auth_algs=1"
    echo "wpa=2"
    echo "wpa_key_mgmt=WPA-PSK"
    echo "rsn_pairwise=CCMP"
    echo "ieee80211w=0"
    echo "wpa_passphrase=$HOTSPOT_PASS"
    [ -n "$HOTSPOT_COUNTRY" ] && echo "country_code=$HOTSPOT_COUNTRY"
} > "$CONF_OUT"
chmod 600 "$CONF_OUT"   # contains the passphrase

# Keep the posted-credentials file in sync (same as the old NM path produced).
CREDS_FILE="$INSTALL_DIR/hotspot-credentials.txt"
{
    echo "SSID: $HOTSPOT_SSID"
    echo "Password: $HOTSPOT_PASS"
} > "$CREDS_FILE"
chown bridgebox:bridgebox "$CREDS_FILE" 2>/dev/null || true
chmod 644 "$CREDS_FILE"

echo "bridge-box-hostapd: starting hostapd on $IFACE (SSID $HOTSPOT_SSID, channel $HOTSPOT_CHANNEL)."

# exec in the foreground so systemd is the direct supervisor (its main PID is
# hostapd; Restart=on-failure then does the right thing).
exec "$HOSTAPD_BIN" "$CONF_OUT"
