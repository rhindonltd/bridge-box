#!/bin/bash
# BridgeBox hotspot diagnostics — figure out WHY a client (e.g. an Amazon Fire
# tablet) can't connect. Read-only: it changes nothing, just reports state and
# (optionally) watches a live join attempt.
#
# Run on the box:   sudo bash /home/bridgebox/bridge-box/bridge-box-hotspot-diag.sh
# Live capture too: sudo bash .../bridge-box-hotspot-diag.sh --watch
#   (then try to join + browse from the tablet; Ctrl-C to stop the capture.)
#
# The two Fire-tablet failure modes it distinguishes:
#   A. Can't ASSOCIATE at all  -> usually PMF (802.11w). Section 2 checks it.
#   B. Associates then says "no internet" / drops -> captive-probe response.
#      Sections 3-4 (+ --watch) show what the probe gets back from the app.

set -uo pipefail

INSTALL_DIR="/home/bridgebox"
CONNECTION_NAME="bridge-hotspot"
APP_PORT="3000"

# Resolve the AP interface the same way the real scripts do.
AP_IFACE="wlan0"
# shellcheck disable=SC1091
[ -f "$INSTALL_DIR/interfaces.conf" ] && . "$INSTALL_DIR/interfaces.conf"
IFACE="${AP_IFACE:-wlan0}"

WATCH="no"
[ "${1:-}" = "--watch" ] && WATCH="yes"

line() { printf '\n==== %s ====\n' "$1"; }
ok()   { printf '  [ ok ] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
bad()  { printf '  [BAD ] %s\n' "$1"; }

line "0. Context"
echo "  AP (hotspot) interface: $IFACE"
echo "  Hotspot connection:     $CONNECTION_NAME"
echo "  Date:                   $(date -Is 2>/dev/null || date)"

# --- 1. Is the hotspot actually up? ------------------------------------------
line "1. Hotspot connection state"
if nmcli -t -f NAME,STATE connection show --active 2>/dev/null | grep -q "^$CONNECTION_NAME:activated"; then
    ok "$CONNECTION_NAME is active"
else
    bad "$CONNECTION_NAME is NOT active — clients can't see/join it at all."
    echo "       Try: sudo systemctl restart bridge-box-root ; then re-run this."
fi
echo "  Radio / AP summary:"
nmcli -f GENERAL.STATE,GENERAL.CONNECTION,WIFI-PROPERTIES.AP device show "$IFACE" 2>/dev/null | sed 's/^/    /' || true
iw dev "$IFACE" info 2>/dev/null | sed 's/^/    /' || true

# --- 2. PMF (802.11w) — failure mode A (can't associate) ---------------------
line "2. PMF / 802.11w (Fire tablets fail to ASSOCIATE if this is on)"
PMF=$(nmcli -g 802-11-wireless-security.pmf connection show "$CONNECTION_NAME" 2>/dev/null || echo "")
case "$PMF" in
    1|disable) ok "PMF is disabled (pmf=$PMF) — correct for Fire tablets." ;;
    "")        warn "Could not read pmf (connection missing?). Expected 1 (disable)." ;;
    *)         bad "PMF is '$PMF' (expected 1/disable). This blocks Fire tablets from associating."
               echo "       Fix: sudo systemctl restart bridge-box-root  (re-applies pmf=disable)" ;;
esac
echo "  Key mgmt / proto (WPA2 vs WPA3 also matters for old clients):"
nmcli -f 802-11-wireless-security.key-mgmt,802-11-wireless-security.proto,802-11-wireless-security.pairwise,802-11-wireless-security.group \
    connection show "$CONNECTION_NAME" 2>/dev/null | sed 's/^/    /' || true

# --- 3. DNS hijack + NAT — the captive path (failure mode B) -----------------
line "3. Captive portal plumbing (DNS hijack + NAT 80/443 -> app)"
DROPIN="/etc/NetworkManager/dnsmasq-shared.d/010-bridgebox-captive.conf"
if [ -f "$DROPIN" ]; then
    ok "DNS hijack drop-in present:"; sed 's/^/      /' "$DROPIN"
else
    warn "No captive DNS drop-in ($DROPIN). Captive portal may be disabled (captive.conf)."
fi
echo "  NAT PREROUTING redirects (expect 80 and 443 -> $APP_PORT on $IFACE):"
if iptables -t nat -S PREROUTING 2>/dev/null | grep -E "dport (80|443)" | sed 's/^/    /'; then :; else
    bad "No 80/443 redirect rules found. Fix: sudo bash $INSTALL_DIR/bridge-box/bridge-box-nat.sh"
fi
echo "  App listening on :$APP_PORT?"
if ss -ltnp 2>/dev/null | grep -q ":$APP_PORT "; then ok "something is listening on :$APP_PORT"; else
    bad "nothing listening on :$APP_PORT — the app isn't up (bridge status)."; fi

# --- 4. What does a probe actually GET BACK? (failure mode B, the key test) --
line "4. Captive-probe responses from the app (the likely culprit)"
echo "  Simulating the OS connectivity probes against the box itself."
echo "  What each OS WANTS:"
echo "    Android/Fire /generate_204 -> HTTP 204 (empty)   OR a 302 to the app"
echo "    iOS /hotspot-detect.html   -> 200 'Success' body OR a 302 to the app"
echo "    Windows /connecttest.txt   -> 200 'Microsoft Connect Test'"
echo "  A plain 200 of the app's HTML, or a 404, is what makes Fire OS say 'no internet'."
# Where to send the probe. The wlan0 PREROUTING redirect (80->3000) only fires
# for packets ARRIVING on wlan0 from a client — NOT for loopback traffic the box
# sends to itself — so curling 127.0.0.1:80 hits nothing (false "???"). Test the
# app DIRECTLY on its real port (what a redirected client packet actually lands
# on). We also try the hotspot IP on :3000 as a cross-check.
PROBE_TARGET="http://127.0.0.1:$APP_PORT"
probe() {
    local host="$1" path="$2"
    local out code loc
    out=$(curl -s -o /dev/null -D - -m 5 -H "Host: $host" "$PROBE_TARGET$path" 2>/dev/null)
    code=$(printf '%s' "$out" | awk 'NR==1{print $2}')
    loc=$(printf '%s' "$out" | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')
    printf '    %-28s -> HTTP %s%s\n' "$path" "${code:-NO-RESPONSE}" "${loc:+  (Location: $loc)}"
}
echo "  (probing the app directly on :$APP_PORT — the port a client's :80 packet is redirected to)"
probe "connectivitycheck.gstatic.com" "/generate_204"
probe "clients3.google.com"           "/generate_204"
probe "www.google.com"                "/gen_204"
probe "captive.apple.com"             "/hotspot-detect.html"
probe "www.msftconnecttest.com"       "/connecttest.txt"
echo
echo "  INTERPRETATION:"
echo "    * 302 with a Location to the app  -> good (OS shows the sheet / lands on app)."
echo "    * 204 for the generate_204 probes -> OS thinks 'online', won't auto-pop (acceptable)."
echo "    * 200 of app HTML / 404 / refused -> THIS is the bug: implement the probe"
echo "      handlers in bridge-box-scorer (see captive-portal-app-contract.md)."

# --- 5. Optional live capture ------------------------------------------------
if [ "$WATCH" = "yes" ]; then
    line "5. Live capture — join + browse from the tablet now (Ctrl-C to stop)"
    if ! command -v tcpdump >/dev/null 2>&1; then
        bad "tcpdump not installed (sudo apt-get install -y tcpdump) — skipping."
    else
        echo "  Watching HTTP/DNS on $IFACE. You'll see the EXACT probe host/path the"
        echo "  Fire tablet uses and whether it even reaches us. Ctrl-C when done."
        echo
        timeout 300 tcpdump -i "$IFACE" -n -s0 -A \
            '(tcp port 80) or (udp port 53)' 2>/dev/null \
            | grep -iE 'GET |Host: |generate_204|gen_204|hotspot-detect|connecttest|ncsi|captive|kindle|fireos' \
            || true
    fi
else
    line "5. (tip) Watch a live join"
    echo "  Re-run with --watch, then join + open a browser on the tablet:"
    echo "    sudo bash $INSTALL_DIR/bridge-box/bridge-box-hotspot-diag.sh --watch"
fi

line "Done"
echo "Summary: section 2 = can it ASSOCIATE (PMF); sections 3-4 = does the probe"
echo "get a captive-friendly answer. Fire-tablet 'no internet' => fix is in the app"
echo "(captive-portal-app-contract.md); can't-even-join => PMF/security in section 2."
