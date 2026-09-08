#!/bin/bash
# BridgeBox privileged WiFi control (runs as root).
#
# NetworkManager connection changes require root/authorisation. The boot update
# service runs as the unprivileged `bridgebox` user, so it cannot drive nmcli
# directly. This helper performs the privileged operations and is invoked by
# bridgebox through a fixed-path sudoers entry (see install.sh). It reads
# wifi.json itself (as root) so no password is ever passed on the command line.
#
# Verbs:
#   connect  — take the hotspot down (disable its autoconnect so it can't grab
#              the radio back), rescan, and join the client network in wifi.json.
#   hotspot  — re-enable the hotspot autoconnect and bring it back up.
#
# Exit non-zero on failure so the caller can react.

set -uo pipefail

IFACE="${BB_IFACE:-wlan0}"
INSTALL_DIR="/home/bridgebox"
WIFI_CONFIG="$INSTALL_DIR/wifi.json"
HOTSPOT_CONNECTION="${BB_HOTSPOT_CONNECTION:-bridge-hotspot}"
NMCLI_TIMEOUT="${BB_NMCLI_TIMEOUT:-45}"

verb="${1:-}"

hotspot_down_for_client() {
    # Disable autoconnect first, else NM re-raises the high-priority hotspot and
    # steals the single radio back before we can join a client network.
    timeout "$NMCLI_TIMEOUT" nmcli connection modify "$HOTSPOT_CONNECTION" connection.autoconnect no 2>/dev/null || true
    timeout "$NMCLI_TIMEOUT" nmcli connection down "$HOTSPOT_CONNECTION" 2>/dev/null || true
    sleep 2
    timeout "$NMCLI_TIMEOUT" nmcli device wifi rescan ifname "$IFACE" 2>/dev/null || true
    sleep 2
}

connect_client() {
    if [ ! -f "$WIFI_CONFIG" ]; then
        echo "wifi-ctl: no wifi.json"; return 1
    fi
    if ! jq empty "$WIFI_CONFIG" 2>/dev/null; then
        echo "wifi-ctl: wifi.json invalid JSON"; return 1
    fi
    local ssid password hidden
    ssid=$(jq -r '.ssid // empty' "$WIFI_CONFIG")
    password=$(jq -r '.password // empty' "$WIFI_CONFIG")
    hidden=$(jq -r '.hidden // "no"' "$WIFI_CONFIG")
    if [ -z "$ssid" ] || [ -z "$password" ]; then
        echo "wifi-ctl: wifi.json missing ssid/password"; return 1
    fi

    hotspot_down_for_client

    _try() {
        local h="$1"
        timeout "$NMCLI_TIMEOUT" nmcli connection delete "$ssid" 2>/dev/null || true
        if [ "$h" = "yes" ]; then
            timeout "$NMCLI_TIMEOUT" nmcli device wifi connect "$ssid" password "$password" hidden yes
        else
            timeout "$NMCLI_TIMEOUT" nmcli device wifi connect "$ssid" password "$password"
        fi
    }

    echo "wifi-ctl: connecting to $ssid"
    if [ "$hidden" = "yes" ]; then
        _try yes || _try no
    else
        _try no || _try yes
    fi
}

return_to_hotspot() {
    timeout "$NMCLI_TIMEOUT" nmcli device disconnect "$IFACE" 2>/dev/null || true
    timeout "$NMCLI_TIMEOUT" nmcli connection modify "$HOTSPOT_CONNECTION" connection.autoconnect yes 2>/dev/null || true
    if ! timeout "$NMCLI_TIMEOUT" nmcli connection up "$HOTSPOT_CONNECTION" 2>/dev/null; then
        echo "wifi-ctl: WARNING failed to bring hotspot up"
        return 1
    fi
}

case "$verb" in
    connect) connect_client ;;
    hotspot) return_to_hotspot ;;
    *) echo "usage: bridge-box-wifi-ctl.sh {connect|hotspot}" >&2; exit 2 ;;
esac
