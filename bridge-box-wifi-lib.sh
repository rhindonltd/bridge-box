#!/bin/bash
# BridgeBox shared WiFi helpers (dual-adapter model).
#
# This box has TWO WiFi radios that run CONCURRENTLY:
#   AP_IFACE     — onboard Broadcom (brcmfmac): a PERMANENT hotspot (AP).
#   CLIENT_IFACE — USB Ralink mt7601U: the client/internet link (wifi.json).
#
# Because the two radios are independent, reaching the internet NO LONGER means
# taking the hotspot down. There is therefore no "online window", no shared
# radio lock, and no return-to-hotspot dance — the hotspot is simply always up.
# This library now just:
#   - connects the CLIENT radio to the wifi.json network (bb_connect_wifi),
#   - reports/ensures connectivity (bb_have_internet / bb_wifi_online).
#
# The former single-radio primitives (bb_acquire_lock, bb_return_to_hotspot,
# bb_run_online_window) are kept as thin compatibility shims so existing callers
# keep working, but they no longer touch the radio — see the bottom of the file.
#
# Usage:
#   source /home/bridgebox/bridge-box/bridge-box-wifi-lib.sh
#   bb_wifi_online || { echo "no internet"; exit 0; }   # ensure client link up
#   ... do network work (the hotspot is unaffected) ...
#
# All functions are safe to call whether or not the client link is already up.

# --- Shared config (callers may pre-set these before sourcing) ---
# Interface roles. Overridable via /home/bridgebox/interfaces.conf (same file
# bridge-box-root.sh reads) so a box whose USB adapter enumerates differently
# can adjust without editing scripts. BB_IFACE is the CLIENT interface (that's
# the only radio this lib touches); the AP radio is owned by bridge-box-root.sh.
# Precedence: an explicit BB_* env from the caller wins; else interfaces.conf's
# AP_IFACE/CLIENT_IFACE; else the wlan0/wlan1 defaults. Source the file first so
# its values are available, but don't let it clobber a caller's explicit BB_*.
if [ -f "/home/bridgebox/interfaces.conf" ]; then
    # shellcheck disable=SC1091
    . /home/bridgebox/interfaces.conf
fi
BB_AP_IFACE="${BB_AP_IFACE:-${AP_IFACE:-wlan0}}"
BB_CLIENT_IFACE="${BB_CLIENT_IFACE:-${CLIENT_IFACE:-wlan1}}"
# BB_IFACE = the client radio this lib operates on. Callers may override it
# (bridge-box-root.sh sets BB_IFACE="$CLIENT_IFACE" explicitly).
BB_IFACE="${BB_IFACE:-$BB_CLIENT_IFACE}"

BB_INSTALL_DIR="${BB_INSTALL_DIR:-/home/bridgebox}"
BB_WIFI_CONFIG="${BB_WIFI_CONFIG:-$BB_INSTALL_DIR/wifi.json}"
BB_NMCLI_TIMEOUT="${BB_NMCLI_TIMEOUT:-60}"
BB_PING_TIMEOUT="${BB_PING_TIMEOUT:-15}"
# Fixed-path root helper for privileged nmcli ops (used when we're NOT root,
# i.e. the boot online-tasks service running as bridgebox). Invoked via sudoers.
BB_WIFI_CTL="/usr/local/bridgebox/bin/wifi-ctl.sh"

# Are we running as root? os-update / node-upgrade and bridge-box-root.sh run as
# root and can drive nmcli directly; the online-tasks service runs as bridgebox
# and must route privileged operations through the sudo helper.
_bb_is_root() { [ "${EUID:-$(id -u 2>/dev/null || echo 1000)}" = "0" ]; }

# Connect the CLIENT radio (BB_IFACE) to the network in wifi.json. Does NOT
# touch the hotspot (separate radio). Idempotent: if the client is already on
# the right network nmcli just reuses the profile. Returns non-zero if it can't
# connect. Safe to call at boot and from maintenance scripts.
bb_connect_wifi() {
    if [ ! -f "$BB_WIFI_CONFIG" ]; then
        echo "No wifi.json — cannot bring up the client link."
        return 1
    fi
    chmod 600 "$BB_WIFI_CONFIG" 2>/dev/null || true
    if ! jq empty "$BB_WIFI_CONFIG" 2>/dev/null; then
        echo "wifi.json is not valid JSON."
        return 1
    fi

    # Non-root (the online-tasks service, run as bridgebox) can't drive NM
    # directly — delegate to the root sudo helper, which reads wifi.json itself
    # (no secrets on the command line).
    if ! _bb_is_root; then
        echo "Connecting client radio via privileged helper (running as $(id -un))..."
        sudo -n "$BB_WIFI_CTL" connect
        return $?
    fi

    # Root path: drive nmcli directly on the client interface.
    local ssid password hidden
    ssid=$(jq -r '.ssid // empty' "$BB_WIFI_CONFIG")
    password=$(jq -r '.password // empty' "$BB_WIFI_CONFIG")
    hidden=$(jq -r '.hidden // "no"' "$BB_WIFI_CONFIG")

    if [ -z "$ssid" ] || [ -z "$password" ]; then
        echo "wifi.json missing ssid or password."
        return 1
    fi

    # No hotspot juggling: the client radio (BB_IFACE) is dedicated, so we just
    # connect it. Non-destructive: connect first (nmcli reuses/updates any saved
    # profile); only delete + retry if that fails, so a transient failure never
    # leaves the box with no profile AND not connected.
    _bb_connect() {
        local h="$1"
        if [ "$h" = "yes" ]; then
            timeout "$BB_NMCLI_TIMEOUT" nmcli device wifi connect "$ssid" password "$password" ifname "$BB_IFACE" hidden yes
        else
            timeout "$BB_NMCLI_TIMEOUT" nmcli device wifi connect "$ssid" password "$password" ifname "$BB_IFACE"
        fi
    }
    _bb_try() {
        local h="$1"
        _bb_connect "$h" && return 0
        echo "First attempt (hidden=$h) failed; clearing stale profile and retrying once."
        timeout "$BB_NMCLI_TIMEOUT" nmcli connection delete "$ssid" 2>/dev/null || true
        _bb_connect "$h"
    }

    echo "Connecting client radio $BB_IFACE to WiFi: $ssid"
    if [ "$hidden" = "yes" ]; then
        _bb_try "yes" || _bb_try "no"
    else
        _bb_try "no" || _bb_try "yes"
    fi
}

# True if the box currently has internet.
#
# Don't rely on ICMP alone: many club/guest networks block outbound pings to
# 8.8.8.8 while HTTPS (which is all the update/sync jobs actually need) works
# fine. That false "offline" reading silently skips the whole update flow. So
# try, in order: a cheap ping (fast when allowed), then an HTTPS reachability
# probe to a well-known host, then the git remote. Any one succeeding = online.
bb_have_internet() {
    # 1. ICMP — fast path when the network allows it.
    timeout "$BB_PING_TIMEOUT" ping -c 1 8.8.8.8 >/dev/null 2>&1 && return 0
    # 2. HTTPS reachability (curl if present) — the real capability we need.
    if command -v curl >/dev/null 2>&1; then
        timeout "$BB_PING_TIMEOUT" curl -fsS -o /dev/null \
            --connect-timeout "$BB_PING_TIMEOUT" \
            https://github.com >/dev/null 2>&1 && return 0
    fi
    # 3. Last resort: can we reach the app's git remote host at all?
    timeout "$BB_PING_TIMEOUT" bash -c \
        'exec 3<>/dev/tcp/github.com/443' 2>/dev/null && return 0
    return 1
}

# Ensure the box is online: use existing internet if present, otherwise bring
# the client link up from wifi.json. Returns non-zero if it couldn't get online.
# The hotspot is unaffected throughout (separate radio) — callers no longer need
# a return-to-hotspot trap.
bb_wifi_online() {
    if bb_have_internet; then
        echo "Already online."
        return 0
    fi
    echo "No internet — bringing the client link up from wifi.json..."
    if ! bb_connect_wifi; then
        echo "Could not connect the client link."
        return 1
    fi
    if bb_have_internet; then
        echo "Online via client link."
        return 0
    fi
    echo "Client link connected but still no internet."
    return 1
}

# ---------------------------------------------------------------------------
# Compatibility shims (dual-radio: these used to manage the single radio).
#
# With two radios the hotspot is never taken down, so there is nothing to lock,
# no window to open/close, and nothing to restore. These are kept as no-ops (or
# trivial "ensure online") so existing callers — os-update, node-upgrade,
# online-tasks, the *-sync services — keep working unchanged.
# ---------------------------------------------------------------------------

# Was: acquire the single-radio lock. Now a no-op success (nothing to serialize
# — network jobs can run concurrently with the hotspot).
bb_acquire_lock() { return 0; }

# Was: tear the client link down and restore the hotspot. Now a no-op: the
# hotspot never went down. We intentionally LEAVE the client link up so the box
# stays online for the next job. Kept so `trap bb_return_to_hotspot EXIT` in
# older callers is harmless.
bb_return_to_hotspot() { return 0; }

# Was: open ONE online window (lock -> hotspot down -> client -> ... -> hotspot).
# Now: just ensure we're online, then run each job sequentially. No radio
# juggling, no lock, no trap. A job's failure is logged and does not stop later
# jobs. Returns 0 if jobs were attempted, non-zero if the box couldn't get
# online (in which case the jobs — which need internet — are skipped).
bb_run_online_window() {
    if ! bb_wifi_online; then
        echo "online-tasks: could not get online — skipping network jobs."
        return 1
    fi
    local job
    for job in "$@"; do
        echo "online-tasks: running job: $job"
        if ! bash -c "$job"; then
            echo "online-tasks: job failed (continuing): $job"
        fi
    done
    return 0
}
