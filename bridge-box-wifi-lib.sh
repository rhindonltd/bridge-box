#!/bin/bash
# BridgeBox shared WiFi helpers.
#
# Single source of truth for switching wlan0 between the hotspot and the client
# network in wifi.json, and for returning to hotspot mode. Sourced by:
#   - bridge-box-update.sh   (boot: uses bb_connect_wifi/bb_have_internet for the
#                             download phase, and bb_return_to_hotspot in its trap)
#   - bridge-box-os-update.sh and bridge-box-node-upgrade.sh (maintenance: use
#                             bb_acquire_lock + bb_wifi_online + bb_return_to_hotspot)
# Keeping this the only implementation means all of them behave identically.
#
# Usage:
#   source /home/bridgebox/bridge-box/bridge-box-wifi-lib.sh
#   bb_wifi_online || { echo "no internet"; exit 0; }   # switch to client WiFi
#   ... do network work ...
#   bb_return_to_hotspot                                 # (also runs via trap)
#
# Callers that only need a trap can do:
#   trap bb_return_to_hotspot EXIT
#
# All functions are safe to call whether or not a switch happened.

# --- Shared config (callers may pre-set these before sourcing) ---
BB_IFACE="${BB_IFACE:-wlan0}"
BB_INSTALL_DIR="${BB_INSTALL_DIR:-/home/bridgebox}"
BB_WIFI_CONFIG="${BB_WIFI_CONFIG:-$BB_INSTALL_DIR/wifi.json}"
BB_HOTSPOT_CONNECTION="${BB_HOTSPOT_CONNECTION:-bridge-hotspot}"
BB_NMCLI_TIMEOUT="${BB_NMCLI_TIMEOUT:-60}"
BB_PING_TIMEOUT="${BB_PING_TIMEOUT:-15}"
BB_LOCKFILE="${BB_LOCKFILE:-$BB_INSTALL_DIR/.update.lock}"
# Fixed-path root helper for privileged nmcli ops (used when we're NOT root,
# i.e. the boot update service running as bridgebox). Invoked via sudoers.
BB_WIFI_CTL="/usr/local/bridgebox/bin/wifi-ctl.sh"

# Are we running as root? os-update / node-upgrade run under sudo (root) and can
# drive nmcli directly; the boot update service runs as bridgebox and must route
# privileged operations through the sudo helper.
_bb_is_root() { [ "${EUID:-$(id -u 2>/dev/null || echo 1000)}" = "0" ]; }

# Acquire the shared network lock so this run can't race bridge-box-update.sh
# (or another maintenance run) while any of them switch wlan0. Waits up to
# BB_LOCK_WAIT seconds (default 120) rather than failing instantly, since a
# manual maintenance run can reasonably wait for a boot-time update to finish.
# Returns non-zero if the lock can't be acquired in time.
bb_acquire_lock() {
    local wait="${1:-${BB_LOCK_WAIT:-120}}"
    exec 9>"$BB_LOCKFILE" || return 1
    if ! flock -w "$wait" 9; then
        echo "Another update/maintenance run holds the network lock (waited ${wait}s)."
        return 1
    fi
}

# Return the device to hotspot mode and re-assert NAT. Idempotent.
# Root path drives nmcli directly; non-root routes through the sudo helper.
bb_return_to_hotspot() {
    echo "Returning to hotspot mode..."
    if _bb_is_root; then
        nmcli device disconnect "$BB_IFACE" 2>/dev/null || true
        nmcli connection modify "$BB_HOTSPOT_CONNECTION" connection.autoconnect yes 2>/dev/null || true
        if ! nmcli connection up "$BB_HOTSPOT_CONNECTION" 2>/dev/null; then
            echo "WARNING: failed to bring hotspot '$BB_HOTSPOT_CONNECTION' up."
        fi
    else
        if ! sudo -n "$BB_WIFI_CTL" hotspot; then
            echo "WARNING: wifi-ctl hotspot failed (could not restore hotspot)."
        fi
    fi
    # Re-assert port redirects; switching wlan0 can drop NM's rebuilt NAT rules.
    if ! sudo -n /usr/local/bridgebox/bin/apply-nat.sh 2>/dev/null; then
        echo "WARNING: could not re-apply NAT redirects (guests may not reach the app on 80/443)."
    fi
    echo "Hotspot restored."
}

# Connect wlan0 to the client network in wifi.json, trying the configured
# visibility first then the other. Returns non-zero if it can't connect.
bb_connect_wifi() {
    if [ ! -f "$BB_WIFI_CONFIG" ]; then
        echo "No wifi.json — cannot switch to client WiFi."
        return 1
    fi
    chmod 600 "$BB_WIFI_CONFIG" 2>/dev/null || true
    if ! jq empty "$BB_WIFI_CONFIG" 2>/dev/null; then
        echo "wifi.json is not valid JSON."
        return 1
    fi

    # Non-root (the boot update service, run as bridgebox) can't drive NM
    # directly — delegate the privileged connect to the root sudo helper, which
    # reads wifi.json itself (no secrets on the command line).
    if ! _bb_is_root; then
        # sudo strips the environment, so the helper uses its own defaults for
        # iface/hotspot (which match ours). It reads wifi.json itself.
        echo "Connecting via privileged helper (running as $(id -un))..."
        sudo -n "$BB_WIFI_CTL" connect
        return $?
    fi

    # Root path (os-update / node-upgrade under sudo): drive nmcli directly.
    local ssid password hidden
    ssid=$(jq -r '.ssid // empty' "$BB_WIFI_CONFIG")
    password=$(jq -r '.password // empty' "$BB_WIFI_CONFIG")
    hidden=$(jq -r '.hidden // "no"' "$BB_WIFI_CONFIG")

    if [ -z "$ssid" ] || [ -z "$password" ]; then
        echo "wifi.json missing ssid or password."
        return 1
    fi

    # Free wlan0 from hotspot/AP mode first. A single WiFi radio can't run as an
    # access point AND scan for/join a client network at the same time. Disable
    # the hotspot's (high-priority) autoconnect so NM can't re-raise it and steal
    # the radio; bb_return_to_hotspot re-enables it.
    echo "Taking hotspot down so wlan0 can join a client network..."
    timeout "$BB_NMCLI_TIMEOUT" nmcli connection modify "$BB_HOTSPOT_CONNECTION" connection.autoconnect no 2>/dev/null || true
    timeout "$BB_NMCLI_TIMEOUT" nmcli connection down "$BB_HOTSPOT_CONNECTION" 2>/dev/null || true
    sleep 2
    timeout "$BB_NMCLI_TIMEOUT" nmcli device wifi rescan ifname "$BB_IFACE" 2>/dev/null || true
    sleep 2

    # Non-destructive: connect first (reuses/updates any saved profile); only
    # delete + retry if that fails, so a transient failure never leaves the box
    # with no profile AND not connected.
    _bb_connect() {
        local h="$1"
        if [ "$h" = "yes" ]; then
            timeout "$BB_NMCLI_TIMEOUT" nmcli device wifi connect "$ssid" password "$password" hidden yes
        else
            timeout "$BB_NMCLI_TIMEOUT" nmcli device wifi connect "$ssid" password "$password"
        fi
    }
    _bb_try() {
        local h="$1"
        _bb_connect "$h" && return 0
        echo "First attempt (hidden=$h) failed; clearing stale profile and retrying once."
        timeout "$BB_NMCLI_TIMEOUT" nmcli connection delete "$ssid" 2>/dev/null || true
        _bb_connect "$h"
    }

    echo "Connecting to WiFi: $ssid"
    if [ "$hidden" = "yes" ]; then
        _bb_try "yes" || _bb_try "no"
    else
        _bb_try "no" || _bb_try "yes"
    fi
}

# True if the box currently has internet.
bb_have_internet() {
    timeout "$BB_PING_TIMEOUT" ping -c 1 8.8.8.8 >/dev/null 2>&1
}

# Bring the box online for maintenance: use existing internet if present,
# otherwise switch to the client WiFi from wifi.json. Returns non-zero if it
# couldn't get online. On success the caller should ensure bb_return_to_hotspot
# runs afterwards (set a trap).
bb_wifi_online() {
    if bb_have_internet; then
        echo "Already online."
        return 0
    fi
    echo "No internet — switching to client WiFi from wifi.json..."
    if ! bb_connect_wifi; then
        echo "Could not connect to client WiFi."
        return 1
    fi
    if bb_have_internet; then
        echo "Online via client WiFi."
        return 0
    fi
    echo "Connected to WiFi but still no internet."
    return 1
}
