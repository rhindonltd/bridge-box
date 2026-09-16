#!/bin/bash
# BridgeBox privileged WiFi control (runs as root) — dual-adapter model.
#
# NetworkManager connection changes require root/authorisation. The boot
# online-tasks service and the scorer app both run as the unprivileged
# `bridgebox` user, so they cannot drive nmcli directly. This helper performs
# the privileged operations and is invoked by bridgebox through a fixed-path
# sudoers entry (see install.sh). It reads wifi.json itself (as root) so no
# password is ever passed on the command line.
#
# Dual radio: the box has a PERMANENT hotspot on the AP radio (wlan0) and a
# dedicated CLIENT radio (wlan1, the USB mt7601U). Everything here operates on
# the CLIENT radio only — the hotspot is never taken down, so there is no
# hotspot-down/settle/rescan dance and no shared radio lock any more.
#
# Verbs:
#   connect       — join the wifi.json network on the client radio.
#   hotspot       — ensure the hotspot is up (it should never be down; this is a
#                   safety re-assert, kept for the lib's compatibility shim).
#   scan          — scan on the client radio (app's network picker).
#   test-connect  — test candidate creds on a throwaway profile (client radio).
#   test-cleanup  — remove the throwaway test profile.
#
# Exit non-zero on failure so the caller can react.

set -uo pipefail

# --- Interface roles (see interfaces.conf / bridge-box-root.sh) ---
AP_IFACE="wlan0"
CLIENT_IFACE="wlan1"
[ -f /home/bridgebox/interfaces.conf ] && . /home/bridgebox/interfaces.conf
# This helper only ever touches the client radio.
IFACE="${BB_IFACE:-$CLIENT_IFACE}"

INSTALL_DIR="/home/bridgebox"
WIFI_CONFIG="$INSTALL_DIR/wifi.json"
HOTSPOT_CONNECTION="${BB_HOTSPOT_CONNECTION:-bridge-hotspot}"
NMCLI_TIMEOUT="${BB_NMCLI_TIMEOUT:-45}"
# Dedicated throwaway profile for app-driven credential testing. NEVER touch
# the real hotspot or client profiles from the test verbs.
TEST_PROFILE="bridge-box-wifi-test"

verb="${1:-}"

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

    # Dedicated client radio: no hotspot to drop, no brcmfmac AP->scan settle.
    # Connect WITHOUT deleting first (non-destructive): nmcli reuses/updates any
    # existing saved profile. Only if that fails do we delete the (possibly
    # stale) profile and retry once — so we never throw away a working profile
    # unless we're immediately recreating it.
    _connect() {
        local h="$1"
        if [ "$h" = "yes" ]; then
            timeout "$NMCLI_TIMEOUT" nmcli device wifi connect "$ssid" password "$password" ifname "$IFACE" hidden yes
        else
            timeout "$NMCLI_TIMEOUT" nmcli device wifi connect "$ssid" password "$password" ifname "$IFACE"
        fi
    }
    _try() {
        local h="$1"
        _connect "$h" && return 0
        echo "wifi-ctl: first attempt (hidden=$h) failed; clearing stale profile and retrying once"
        timeout "$NMCLI_TIMEOUT" nmcli connection delete "$ssid" 2>/dev/null || true
        _connect "$h"
    }

    echo "wifi-ctl: connecting client radio $IFACE to $ssid"
    if [ "$hidden" = "yes" ]; then
        _try yes || _try no
    else
        _try no || _try yes
    fi
}

# Ensure the hotspot is up. In the dual-radio model it should never be down, so
# this is just a safety re-assert (idempotent). Kept for the lib compat shim and
# the `hotspot` verb; it does NOT touch the client radio.
ensure_hotspot_up() {
    if nmcli -t -f NAME,STATE connection show --active 2>/dev/null | grep -q "^$HOTSPOT_CONNECTION:activated"; then
        return 0
    fi
    timeout "$NMCLI_TIMEOUT" nmcli connection up "$HOTSPOT_CONNECTION" 2>/dev/null || {
        echo "wifi-ctl: WARNING hotspot '$HOTSPOT_CONNECTION' not active and could not be brought up"
        return 1
    }
}

do_scan() {
    # Scan on the client radio. The hotspot (other radio) is untouched, so this
    # is safe to run any time, even mid-session.
    #
    # Output format: TERSE (`nmcli -t -f SSID,SECURITY,SIGNAL`). This is what the
    # app's parser expects — colon-separated fields, no header/padding/colour.
    # Terse mode is also non-interactive (no pager / no tty behaviour), which
    # avoids the hang we hit with the default tabular output when stdout is a
    # terminal (nmcli would go interactive and get killed by `timeout` -> 124).
    # NOTE for the parser: in -t mode nmcli backslash-escapes any literal colon
    # inside a field (e.g. an SSID with a ':'), so split on UNescaped colons.
    #
    # Also: do NOT use `--rescan yes` on the list. It forces a fresh rescan and
    # BLOCKS until it completes; combined with the standalone rescan below (and
    # NM's ~10-15s rescan rate-limit) that could stall and hit the timeout. We do
    # one best-effort standalone rescan (non-fatal, rate-limit-safe), pause, then
    # LIST with --rescan no so it returns the cached results immediately. `-w`
    # bounds nmcli itself so it can never hang past a few seconds.
    timeout 12 nmcli -w 10 device wifi rescan ifname "$IFACE" 2>/dev/null || true
    sleep 2
    timeout "$NMCLI_TIMEOUT" nmcli -t -f SSID,SECURITY,SIGNAL -w 10 \
        device wifi list ifname "$IFACE" --rescan no
}

do_test_connect() {
    local ssid="$1" password="$2" hidden="${3:-no}"
    if [ -z "$ssid" ] || [ -z "$password" ]; then
        echo "wifi-ctl: test-connect requires <ssid> <password> [hidden]" >&2
        exit 2
    fi

    # Build the throwaway test profile fresh each time, pinned to the client
    # radio so testing never disturbs the hotspot.
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

    echo "wifi-ctl: bringing up test profile for '$ssid' on $IFACE..."
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
    # Tear the test profile down/out. The real client link (if any) is a separate
    # profile and is left alone.
    timeout "$NMCLI_TIMEOUT" nmcli connection down "$TEST_PROFILE" 2>/dev/null || true
    timeout "$NMCLI_TIMEOUT" nmcli connection delete "$TEST_PROFILE" 2>/dev/null || true
}

do_test_cleanup() {
    timeout "$NMCLI_TIMEOUT" nmcli connection down "$TEST_PROFILE" 2>/dev/null || true
    timeout "$NMCLI_TIMEOUT" nmcli connection delete "$TEST_PROFILE" 2>/dev/null || true
    echo "wifi-ctl: test profile cleaned up."
}

case "$verb" in
    connect)      connect_client ;;
    hotspot)      ensure_hotspot_up ;;
    scan)         do_scan ;;
    test-connect) shift; do_test_connect "$@" ;;
    test-cleanup) do_test_cleanup ;;
    *) echo "usage: bridge-box-wifi-ctl.sh {connect|hotspot|scan|test-connect <ssid> <pass> [hidden]|test-cleanup}" >&2; exit 2 ;;
esac
