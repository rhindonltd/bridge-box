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

# --- Interface roles (dual-adapter) ---
# This box has TWO WiFi radios and they run CONCURRENTLY:
#   AP_IFACE     — the onboard Broadcom (brcmfmac), a PERMANENT hotspot (AP).
#   CLIENT_IFACE — the USB Ralink mt7601U, the client/internet link (wifi.json).
# They never contend, so the hotspot is never taken down to reach the internet.
# Both defaults can be overridden in /home/bridgebox/interfaces.conf (e.g. if the
# kernel names the USB adapter differently). AP_IFACE feeds NAT + captive; the
# client link is brought up here and left up.
AP_IFACE="wlan0"
CLIENT_IFACE="wlan1"
[ -f /home/bridgebox/interfaces.conf ] && . /home/bridgebox/interfaces.conf
IFACE="$AP_IFACE"   # NAT/captive/hotspot below all use the AP interface

APP_PORT=3000
CONNECTION_NAME="bridge-hotspot"
NEW_HOSTNAME="bridge"

echo "=== BridgeBox root setup ==="
echo "Interfaces: AP=$AP_IFACE (hotspot), client=$CLIENT_IFACE (internet)"

# Give NetworkManager/the radios a moment to be ready at boot before we touch them.
nmcli networking connectivity check >/dev/null 2>&1 || true
sleep 3

# --- Hotspot: hostapd, NOT NetworkManager -------------------------------------
# The guest hotspot is run by hostapd (bridge-box-hostapd.service) with a
# dedicated dnsmasq for DHCP + captive DNS (bridge-box-apnet.service). We moved
# off NetworkManager's built-in hotspot because NM's AP beacon (802.11n HT + WMM)
# stops some budget clients — notably Amazon Fire tablets — from associating. A
# stripped-down hostapd beacon fixes that (proven on-device). The SSID/password
# derivation + hotspot-credentials.txt now live in bridge-box-hostapd.sh.
#
# For hostapd to own the AP radio, NetworkManager must LEAVE THAT INTERFACE
# ALONE — but keep managing the CLIENT radio (it still brings up wifi.json). We
# assert an NM "unmanaged" drop-in for the AP interface only.
NM_UNMANAGED="/etc/NetworkManager/conf.d/90-bridgebox-unmanaged.conf"
NEED_NM_RELOAD=0
DESIRED_UNMANAGED="interface-name:$IFACE"
if [ ! -f "$NM_UNMANAGED" ] || ! grep -q "$DESIRED_UNMANAGED" "$NM_UNMANAGED" 2>/dev/null; then
    echo "Marking $IFACE unmanaged in NetworkManager (hostapd owns the AP radio)."
    cat > "$NM_UNMANAGED" <<EOF
# Managed by bridge-box-root.sh — the AP radio ($IFACE) is driven by hostapd,
# not NetworkManager. The client radio stays NM-managed. Do not edit by hand.
[keyfile]
unmanaged-devices=$DESIRED_UNMANAGED
EOF
    NEED_NM_RELOAD=1
fi

# If NM was still holding the AP interface (e.g. a leftover bridge-hotspot
# connection from a pre-hostapd release, or first switch-over), release it so
# hostapd can claim it. Non-fatal.
if nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$CONNECTION_NAME"; then
    echo "Removing legacy NM hotspot connection '$CONNECTION_NAME' (now handled by hostapd)."
    nmcli connection down "$CONNECTION_NAME" 2>/dev/null || true
    nmcli connection delete "$CONNECTION_NAME" 2>/dev/null || true
fi
if [ "$NEED_NM_RELOAD" = "1" ]; then
    nmcli connection reload 2>/dev/null || true
    nmcli device set "$IFACE" managed no 2>/dev/null || true
    sleep 2
fi

# Enable IP forwarding (NM's shared mode used to do this; we do it ourselves).
sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# Start (or restart) the AP services: hostapd first (the beacon), then apnet
# (IP + DHCP + captive DNS). These are supervised units (Restart=on-failure), so
# we just (re)start them here; systemd keeps them up thereafter. Non-fatal: if
# the AP radio is briefly not ready, the units' own restart handles it.
echo "Starting hostapd + AP network services..."
# --no-block: this script runs as the bridge-box-root oneshot, which the AP
# units are ordered After=; a blocking `systemctl restart` would deadlock (the
# restart job can't complete until root finishes, and root waits on it). Queue
# them instead — systemd starts/supervises them per their ordering. At boot the
# units also start on their own (WantedBy=multi-user.target); this restart makes
# a manual re-run of root.sh (e.g. after an interfaces.conf change) re-apply.
systemctl restart --no-block bridge-box-hostapd.service 2>&1 || \
    echo "WARNING: could not queue hostapd restart — check: journalctl -u bridge-box-hostapd"
systemctl restart --no-block bridge-box-apnet.service 2>&1 || \
    echo "WARNING: could not queue AP network restart — check: journalctl -u bridge-box-apnet"

# NAT / port redirect (shared, idempotent script). Guest traffic on the AP
# interface is redirected to the app; the client radio's traffic is untouched.
# (Captive DNS is now handled inside bridge-box-apnet.sh's dnsmasq, so there is
# no separate captive step here any more.)
IFACE="$IFACE" APP_PORT="$APP_PORT" bash /home/bridgebox/bridge-box/bridge-box-nat.sh

# Bring the client radio (CLIENT_IFACE) onto the wifi.json network and LEAVE IT
# UP. With a second, dedicated radio there's no reason to connect on demand and
# disconnect — the internet link can just stay up alongside the hotspot. This is
# best-effort: if there's no wifi.json, no network, or no client adapter, the
# box still serves fine over the hotspot (offline-first). The connect runs as
# root here (boot, before the app) via the shared lib's root path.
if [ -f /home/bridgebox/wifi.json ]; then
    if [ -e "/sys/class/net/$CLIENT_IFACE" ]; then
        echo "Bringing client radio $CLIENT_IFACE onto the wifi.json network..."
        # shellcheck source=bridge-box-wifi-lib.sh
        if . /home/bridgebox/bridge-box/bridge-box-wifi-lib.sh 2>/dev/null; then
            BB_IFACE="$CLIENT_IFACE" bb_connect_wifi || \
                echo "WARNING: client WiFi connect failed — box stays hotspot-only until it succeeds."
        else
            echo "WARNING: wifi lib missing — skipping client WiFi bring-up."
        fi
    else
        echo "No client adapter ($CLIENT_IFACE) present — hotspot-only box."
    fi
else
    echo "No wifi.json — offline box, not bringing up a client link."
fi

sudo hostnamectl set-hostname bridge
sudo sed -i "s/127\.0\.1\.1\s\+.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts

sudo systemctl restart avahi-daemon

echo "=== BridgeBox root setup complete ==="