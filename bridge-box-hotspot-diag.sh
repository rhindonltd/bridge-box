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
echo "  AP (hotspot) interface: $IFACE  (run by hostapd, not NetworkManager)"
echo "  Date:                   $(date -Is 2>/dev/null || date)"

# --- 1. Is the hotspot (hostapd) actually up? --------------------------------
# The hotspot is run by hostapd (bridge-box-hostapd.service), NOT NetworkManager.
line "1. Hotspot (hostapd) state"
if systemctl is-active --quiet bridge-box-hostapd.service; then
    ok "bridge-box-hostapd.service is active"
else
    bad "bridge-box-hostapd.service is NOT active — no hotspot. clients can't join."
    echo "       Check: journalctl -u bridge-box-hostapd -b ; then: sudo systemctl restart bridge-box-root"
fi
if systemctl is-active --quiet bridge-box-apnet.service; then
    ok "bridge-box-apnet.service is active (AP IP + DHCP + captive DNS)"
else
    bad "bridge-box-apnet.service is NOT active — clients would associate but get no IP."
    echo "       Check: journalctl -u bridge-box-apnet -b"
fi
echo "  Radio / AP summary (expect 'type AP'):"
iw dev "$IFACE" info 2>/dev/null | sed 's/^/    /' || true

echo "  hostapd beacon params (Fire-tablet-critical — expect HT/WMM/PMF OFF):"
if [ -f /etc/hostapd/bridge-box.conf ]; then
    grep -E '^(ssid|hw_mode|channel|ieee80211n|wmm_enabled|ieee80211w|wpa|rsn_pairwise)=' \
        /etc/hostapd/bridge-box.conf | sed 's/^/    /'
    echo "    ^ Want: hw_mode=g, ieee80211n=0, wmm_enabled=0, ieee80211w=0, wpa=2, rsn_pairwise=CCMP."
    echo "      These are what let Amazon Fire tablets associate; NM's beacon (HT+WMM) did not."
else
    warn "no /etc/hostapd/bridge-box.conf — hostapd config not generated yet."
fi
echo "  Regulatory domain (informational — self-managed brcmfmac shows phy 'country 99', which is normal):"
iw reg get 2>/dev/null | sed 's/^/    /' || true

# --- 2. (legacy section retained as a no-op note) ----------------------------
line "2. PMF / 802.11w"
if [ -f /etc/hostapd/bridge-box.conf ] && grep -q '^ieee80211w=0' /etc/hostapd/bridge-box.conf; then
    ok "PMF disabled in hostapd (ieee80211w=0) — correct for Fire tablets."
else
    warn "could not confirm ieee80211w=0 in the hostapd config."
fi
# --- 3. DNS hijack + NAT — the captive path (failure mode B) -----------------
line "3. Captive portal plumbing (DNS hijack + NAT 80/443 -> app)"
# The captive DNS hijack now lives in our own dnsmasq config (bridge-box-apnet.sh),
# NOT an NM shared-dnsmasq drop-in.
APDNS="/etc/bridgebox/ap-dnsmasq.conf"
if [ -f "$APDNS" ]; then
    if grep -q '^address=/#/' "$APDNS"; then
        ok "captive DNS hijack present in AP dnsmasq config:"; grep -E '^(interface|dhcp-range|address)=' "$APDNS" | sed 's/^/      /'
    else
        warn "AP dnsmasq config present but no captive hijack (CAPTIVE_PORTAL=no?). DHCP still works."
        grep -E '^(interface|dhcp-range)=' "$APDNS" | sed 's/^/      /'
    fi
else
    bad "No AP dnsmasq config ($APDNS) — clients won't get an IP. Check bridge-box-apnet.service."
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

# --- 4b. Client L3 reachability (does the tablet get an IP + reach the box?) --
line "4b. Client connectivity (DHCP lease + can the box's app be reached on :80)"
echo "  Box address on $IFACE:"
ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print "    " $4}' || true

echo "  DHCP leases handed out by the AP dnsmasq (bridge-box-apnet):"
# Our dnsmasq uses the default lease file; NM-era boxes used a per-iface one.
LEASES=""
for f in /var/lib/misc/dnsmasq.leases \
         /var/lib/NetworkManager/dnsmasq-"$IFACE".leases \
         /var/lib/NetworkManager/dnsmasq-*.leases; do
    [ -f "$f" ] && LEASES="$f" && break
done
if [ -n "$LEASES" ]; then
    if [ -s "$LEASES" ]; then
        sed 's/^/    /' "$LEASES"
        echo "    ^ if your tablet's MAC/IP is here, DHCP is working ($LEASES)."
    else
        warn "lease file $LEASES is EMPTY — no client leased yet (normal if nothing's connected)."
    fi
else
    warn "no dnsmasq lease file found yet — connect a client and re-run."
fi

echo "  ARP/neighbour table (clients the box has actually seen on $IFACE):"
ip neigh show dev "$IFACE" 2>/dev/null | sed 's/^/    /' || true
echo "    ^ expect your tablet's IP (10.42.0.x) in 'REACHABLE'/'STALE' state."

echo "  802.11 ASSOCIATED STATIONS (the link layer — does the device even join?):"
echo "    (run this WHILE the tablet is trying to connect; compare phone vs tablet)"
if command -v iw >/dev/null 2>&1; then
    STATIONS=$(iw dev "$IFACE" station dump 2>/dev/null)
    if [ -n "$STATIONS" ]; then
        printf '%s\n' "$STATIONS" | grep -iE "^Station|signal:|rx bytes|tx bytes|connected time|authorized|authenticated" | sed 's/^/    /'
        echo "    ^ Each 'Station <MAC>' is an associated client. If your phone's MAC"
        echo "      appears but the Fire tablet's NEVER does, the tablet is failing to"
        echo "      ASSOCIATE at the 802.11 layer (not a DHCP/IP/app problem at all)."
        echo "      'authorized: yes' + 'authenticated: yes' = a healthy association."
    else
        warn "no stations associated right now (connect a device and re-run)."
    fi
else
    warn "iw not installed (sudo apt-get install -y iw) — can't list stations."
fi

echo "  Firewall INPUT policy + rules on $IFACE (is client->box :3000/:80 allowed?):"
iptables -S INPUT 2>/dev/null | sed 's/^/    /' || true
echo "  Firewall FORWARD policy (should ACCEPT; NAT handles guest->app redirect):"
iptables -S FORWARD 2>/dev/null | grep -iE "wlan0|10\.42|ACCEPT|DROP|policy" | sed 's/^/    /' || true
echo "    ^ If INPUT policy is DROP with no ACCEPT for 10.42.0.0/24 -> client->box"
echo "      traffic (incl. the app on :3000) is blocked. That = 'No Internet' on a raw IP."

echo "  Can the box reach its OWN app via the hotspot IP (proves app serves on that bind)?"
HS_IP=$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
if [ -n "$HS_IP" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$HS_IP:$APP_PORT/" 2>/dev/null)
    echo "    http://$HS_IP:$APP_PORT/  -> HTTP ${code:-NO-RESPONSE}"
    echo "    ^ If this is NO-RESPONSE, the app is bound to 127.0.0.1 only and NOT to"
    echo "      $HS_IP — so clients can never reach it even though :3000 'is listening'."
fi

# --- 4c. DHCP server health (our dnsmasq via bridge-box-apnet) ----------------
line "4c. Hotspot DHCP (bridge-box-apnet dnsmasq) — leasing to clients?"
if systemctl is-active --quiet bridge-box-apnet.service; then
    ok "bridge-box-apnet.service is active"
else
    bad "bridge-box-apnet.service is NOT active => no DHCP/DNS for clients."
    echo "       Check: journalctl -u bridge-box-apnet -b"
fi
echo "  Our dnsmasq process (should be bound to $IFACE with a --dhcp-range):"
if pgrep -af "dnsmasq.*ap-dnsmasq.conf" >/dev/null 2>&1; then
    pgrep -af "dnsmasq.*ap-dnsmasq.conf" | sed 's/^/    /'
    ok "the AP dnsmasq is running"
else
    bad "no AP dnsmasq (ap-dnsmasq.conf) process running => clients get no IP."
fi
echo "  Recent bridge-box-apnet log lines:"
journalctl -u bridge-box-apnet --no-pager -n 20 2>/dev/null | tail -n 15 | sed 's/^/    /' \
    || echo "    (none / journal unavailable)"

# --- 5. Optional live capture ------------------------------------------------
if [ "$WATCH" = "yes" ]; then
    line "5. Live capture — join + browse from the tablet now (Ctrl-C to stop)"
    if ! command -v tcpdump >/dev/null 2>&1; then
        bad "tcpdump not installed (sudo apt-get install -y tcpdump) — skipping."
    else
        echo "  Watching DHCP + DNS + HTTP on $IFACE. 'Forget' the network on the"
        echo "  tablet and re-join so we see the full sequence: does it DHCP (get an"
        echo "  IP), what probe does it send, and does it then drop? Ctrl-C when done."
        echo
        echo "  Reading the capture:"
        echo "    * BOOTP/DHCP Request+ACK  = the tablet GOT an IP (DHCP is fine)."
        echo "    * no DHCP ACK             = it never leased (device-side refusal)."
        echo "    * a GET to a probe host then silence = it decided 'no internet' + bailed."
        echo
        # Show DHCP (67/68), DNS (53) and HTTP (80) so we can see lease + probe + drop.
        timeout 300 tcpdump -i "$IFACE" -n -s0 \
            '(udp port 67 or udp port 68) or (udp port 53) or (tcp port 80)' 2>/dev/null \
            | grep -iE 'BOOTP|DHCP|Request from|ACK|\.53:|GET |generate_204|gen_204|hotspot-detect|connecttest|ncsi|captive|kindle|fireos|google' \
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
