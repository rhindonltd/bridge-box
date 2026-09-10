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
LOCKFILE="${BB_LOCKFILE:-$INSTALL_DIR/.update.lock}"
# Dedicated throwaway profile for app-driven credential testing. NEVER touch
# the real hotspot or client profiles from the test verbs.
TEST_PROFILE="bridge-box-wifi-test"

verb="${1:-}"

hotspot_down_for_client() {
    # Disable autoconnect first, else NM re-raises the high-priority hotspot and
    # steals the single radio back before we can join a client network.
    timeout "$NMCLI_TIMEOUT" nmcli connection modify "$HOTSPOT_CONNECTION" connection.autoconnect no 2>/dev/null || true
    timeout "$NMCLI_TIMEOUT" nmcli connection down "$HOTSPOT_CONNECTION" 2>/dev/null || true
    # The Pi's Broadcom WiFi (brcmfmac) needs time to leave AP mode before it can
    # scan reliably — scanning too soon causes "brcmf_escan_timeout" and a failed
    # scan (which surfaces as "No network with SSID found"). Give it a generous
    # settle before the first scan.
    sleep 5
}

# Rescan and wait until $1 (an SSID) appears, up to ~N tries. Returns 0 if seen.
# Works around transient brcmfmac escan timeouts by retrying the scan.
wait_for_ssid() {
    local want="$1" tries=6 i
    for (( i=1; i<=tries; i++ )); do
        timeout "$NMCLI_TIMEOUT" nmcli device wifi rescan ifname "$IFACE" 2>/dev/null || true
        sleep 3
        if nmcli -t -f SSID device wifi list ifname "$IFACE" 2>/dev/null | grep -Fxq "$want"; then
            echo "wifi-ctl: SSID '$want' visible (scan $i)"
            return 0
        fi
        echo "wifi-ctl: SSID '$want' not yet visible (scan $i/$tries)"
    done
    return 1
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

    # Wait for NetworkManager to be ready and wlan0 to be free, so we don't hit
    # "New connection activation was enqueued" from a still-settling radio.
    timeout "$NMCLI_TIMEOUT" nmcli networking connectivity check >/dev/null 2>&1 || true
    local waited=0
    while [ "$waited" -lt 10 ]; do
        state=$(nmcli -t -f GENERAL.STATE device show "$IFACE" 2>/dev/null | head -n1)
        case "$state" in *connecting*|*deactivating*) ;; *) break;; esac
        sleep 1; waited=$((waited + 1))
    done

    # Connect WITHOUT deleting first (non-destructive): nmcli reuses/updates any
    # existing saved profile. Only if that fails do we delete the (possibly
    # stale) profile and retry once — so we never throw away a working profile
    # unless we're immediately recreating it. This avoids the "deleted then
    # failed -> box lost its WiFi" footgun.
    _connect() {
        local h="$1"
        if [ "$h" = "yes" ]; then
            timeout "$NMCLI_TIMEOUT" nmcli device wifi connect "$ssid" password "$password" hidden yes
        else
            timeout "$NMCLI_TIMEOUT" nmcli device wifi connect "$ssid" password "$password"
        fi
    }
    _try() {
        local h="$1"
        _connect "$h" && return 0
        echo "wifi-ctl: first attempt (hidden=$h) failed; clearing stale profile and retrying once"
        timeout "$NMCLI_TIMEOUT" nmcli connection delete "$ssid" 2>/dev/null || true
        _connect "$h"
    }

    echo "wifi-ctl: connecting to $ssid"
    if [ "$hidden" = "yes" ]; then
        # Hidden networks don't show in scans — connect directly (with retry).
        _try yes || _try no
    else
        # Wait until the SSID actually appears (handles brcmfmac scan timeouts)
        # before attempting to connect; fall back to trying anyway if the scan
        # never surfaces it (e.g. driver hiccup) rather than giving up outright.
        wait_for_ssid "$ssid" || echo "wifi-ctl: SSID never appeared in scans; trying connect anyway"
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

# ===========================================================================
# App-facing verbs (scan / test-connect / test-cleanup).
#
# The scorer app (running as bridgebox) can't drive NetworkManager directly, so
# it calls these via `sudo -n wifi-ctl.sh <verb>`. They are for the app's
# "connect this box to WiFi" flow: scan for networks, and TEST candidate
# credentials against a throwaway `bridge-box-wifi-test` profile before the app
# writes the chosen network to wifi.json. They:
#   - take the shared network lock (don't race the boot online window),
#   - drop the hotspot (single radio) and ALWAYS restore it on exit (trap),
#   - only ever touch the TEST_PROFILE — never the real hotspot/client config.
# The app does read-only nmcli (diagnostics) and `command -v nmcli` itself.
# ===========================================================================

# Acquire the shared lock on fd 8 (fd 9 is used elsewhere). Non-blocking-ish:
# wait briefly, then fail so the app gets a clear "busy" rather than hanging.
_acquire_lock() {
    exec 8>"$LOCKFILE" || return 1
    if ! flock -w 30 8; then
        echo "wifi-ctl: another network operation is in progress — try again shortly." >&2
        return 1
    fi
}

# Restore hotspot + release lock, once, on exit. Set by the app verbs.
_APP_RESTORED=0
_app_restore() {
    [ "$_APP_RESTORED" = "1" ] && return 0
    _APP_RESTORED=1
    return_to_hotspot
    flock -u 8 2>/dev/null || true
    exec 8>&- 2>/dev/null || true
}

do_scan() {
    _acquire_lock || exit 1
    trap _app_restore EXIT
    hotspot_down_for_client
    # Emit the RAW `nmcli device wifi list --rescan yes` output verbatim so the
    # app's existing parser needs no change. A couple of rescans help the
    # Broadcom radio populate results after leaving AP mode.
    timeout "$NMCLI_TIMEOUT" nmcli device wifi rescan ifname "$IFACE" 2>/dev/null || true
    sleep 3
    timeout "$NMCLI_TIMEOUT" nmcli device wifi list --rescan yes
}

do_test_connect() {
    local ssid="$1" password="$2" hidden="${3:-no}"
    if [ -z "$ssid" ] || [ -z "$password" ]; then
        echo "wifi-ctl: test-connect requires <ssid> <password> [hidden]" >&2
        exit 2
    fi
    _acquire_lock || exit 1
    trap _app_restore EXIT
    hotspot_down_for_client

    # Build the throwaway test profile fresh each time.
    timeout "$NMCLI_TIMEOUT" nmcli connection delete "$TEST_PROFILE" 2>/dev/null || true
    if ! timeout "$NMCLI_TIMEOUT" nmcli connection add type wifi con-name "$TEST_PROFILE" \
            ifname "$IFACE" ssid "$ssid" 2>&1; then
        echo "wifi-ctl: could not create test profile"; exit 1
    fi
    timeout "$NMCLI_TIMEOUT" nmcli connection modify "$TEST_PROFILE" \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$password" \
        connection.autoconnect no 2>/dev/null || true
    [ "$hidden" = "yes" ] && timeout "$NMCLI_TIMEOUT" nmcli connection modify "$TEST_PROFILE" \
        802-11-wireless.hidden yes 2>/dev/null || true

    echo "wifi-ctl: bringing up test profile for '$ssid'..."
    if timeout "$NMCLI_TIMEOUT" nmcli connection up "$TEST_PROFILE" 2>&1; then
        # Verify actual internet, not just association.
        if timeout 15 ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            echo "TEST_RESULT: ok (connected + internet)"
        else
            echo "TEST_RESULT: connected-no-internet (associated but no route out)"
        fi
    else
        echo "TEST_RESULT: failed (could not connect — check password/SSID)"
    fi
    # Tear the test profile down/out; the trap then restores the hotspot.
    timeout "$NMCLI_TIMEOUT" nmcli connection down "$TEST_PROFILE" 2>/dev/null || true
    timeout "$NMCLI_TIMEOUT" nmcli connection delete "$TEST_PROFILE" 2>/dev/null || true
}

do_test_cleanup() {
    _acquire_lock || exit 1
    trap _app_restore EXIT
    timeout "$NMCLI_TIMEOUT" nmcli connection down "$TEST_PROFILE" 2>/dev/null || true
    timeout "$NMCLI_TIMEOUT" nmcli connection delete "$TEST_PROFILE" 2>/dev/null || true
    echo "wifi-ctl: test profile cleaned up."
}

case "$verb" in
    connect)      connect_client ;;
    hotspot)      return_to_hotspot ;;
    scan)         do_scan ;;
    test-connect) shift; do_test_connect "$@" ;;
    test-cleanup) do_test_cleanup ;;
    *) echo "usage: bridge-box-wifi-ctl.sh {connect|hotspot|scan|test-connect <ssid> <pass> [hidden]|test-cleanup}" >&2; exit 2 ;;
esac
