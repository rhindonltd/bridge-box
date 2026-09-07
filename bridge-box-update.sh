#!/bin/bash
# BridgeBox boot-time update + app start (bridgebox user).
#
# Three-phase update model (see structure.md):
#   Phase 3 (here, first): if a fully-built release is pending, activate it
#           atomically BEFORE the app starts, so boot comes up on the new code.
#   Phase 1 (here, before app start): if online-capable, download (only) any
#           newer release, then return to hotspot. NO build happens here.
#   Phase 2 (separate bridge-box-build.service): build the downloaded release
#           in the background with no network churn, mark it pending.
#
# Key guarantees:
#   - The app is ALWAYS started, on every exit path (trap), even if the network
#     phase fails — a network problem must never leave the box with no app.
#   - No WiFi<->hotspot switching happens while the app is running: the entire
#     network phase runs BEFORE the app is started.
#   - Phase 1 is bounded by a hard deadline so boot-to-game stays fast.

set -euo pipefail

# --- CONFIG ---
IFACE="wlan0"
INSTALL_DIR="/home/bridgebox"
SCORER_DIR="$INSTALL_DIR/bridge-box-scorer"
CURRENT_LINK="$SCORER_DIR/current"
PREVIOUS_LINK="$SCORER_DIR/previous"
PENDING_LINK="$SCORER_DIR/pending"        # built release awaiting activation
RELEASES_DIR="$SCORER_DIR/releases"
WIFI_CONFIG="$INSTALL_DIR/wifi.json"
REPO_URL="https://github.com/rhindonltd/bridge-box-scorer.git"
HOTSPOT_CONNECTION="bridge-hotspot"
LOCKFILE="$INSTALL_DIR/.update.lock"

# Which git ref to deploy. Override in $INSTALL_DIR/release.conf to pin the
# device to a specific tag/branch for reproducible deployments.
RELEASE_REF="main"
[ -f "$INSTALL_DIR/release.conf" ] && . "$INSTALL_DIR/release.conf"

LOGFILE="$INSTALL_DIR/update.log"

# Bounded waits / timeouts (seconds)
NMCLI_TIMEOUT=45         # per nmcli network operation (fast-fail)
CLONE_TIMEOUT=120        # git clone of a release (download can be larger)
PING_TIMEOUT=10          # internet check
PHASE1_DEADLINE=90       # HARD cap on the whole network phase; then boot anyway

# Shared WiFi helpers (single source of truth for connect / return-to-hotspot).
# Configure the lib for our faster boot-time timeouts before sourcing.
BB_IFACE="$IFACE"
BB_INSTALL_DIR="$INSTALL_DIR"
BB_WIFI_CONFIG="$WIFI_CONFIG"
BB_HOTSPOT_CONNECTION="$HOTSPOT_CONNECTION"
BB_NMCLI_TIMEOUT="$NMCLI_TIMEOUT"
BB_PING_TIMEOUT="$PING_TIMEOUT"
WIFI_LIB="$INSTALL_DIR/bridge-box/bridge-box-wifi-lib.sh"
# Source is non-fatal: the app MUST still boot even if the lib is missing. If it
# can't be sourced we define minimal fallbacks so the trap and skip-update path
# still work (updates are skipped, but the box boots and serves).
# shellcheck source=bridge-box-wifi-lib.sh
if [ -f "$WIFI_LIB" ] && . "$WIFI_LIB"; then
    :
else
    echo "WARNING: WiFi lib unavailable — updates disabled this boot, app will still start."
    bb_connect_wifi() { return 1; }
    bb_have_internet() { return 1; }
    bb_return_to_hotspot() {
        nmcli device disconnect "$IFACE" 2>/dev/null || true
        nmcli connection up "$HOTSPOT_CONNECTION" 2>/dev/null || true
        sudo -n /usr/local/bridgebox/bin/apply-nat.sh 2>/dev/null || true
    }
fi

# --- Bounded logging: truncate log if it grows too large (~5 MB) ---
MAX_LOG_BYTES=$((5 * 1024 * 1024))
if [ -f "$LOGFILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt "$MAX_LOG_BYTES" ]; then
        tail -c "$((MAX_LOG_BYTES / 2))" "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null || true
        mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null || true
    fi
fi
exec > >(tee -a "$LOGFILE") 2>&1

# --- Single-instance lock ---
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "Another bridge-box-update run is in progress — exiting."
    exit 0
fi

echo "=== BridgeBox boot update/start $(date -Is) ==="

# --- Resolve a release's commit for APP_COMMIT (7-char short hash) ---
resolve_commit() {
    local c
    c=$(git -C "$CURRENT_LINK" rev-parse --short HEAD 2>/dev/null || echo "")
    if [ -z "$c" ]; then
        c=$(basename "$(readlink -f "$CURRENT_LINK" 2>/dev/null || echo unknown)")
        if [[ "$c" =~ ^[0-9a-f]{40}$ ]]; then
            c="${c:0:7}"
        fi
    fi
    echo "$c"
}

# --- Start the app (idempotent). Called from the trap so it ALWAYS runs. ---
APP_STARTED=0
start_app() {
    [ "$APP_STARTED" = "1" ] && return 0
    APP_STARTED=1
    export APP_COMMIT="$(resolve_commit)"
    echo "Starting app (commit $APP_COMMIT)..."
    pm2 delete bridge 2>/dev/null || true
    # --cwd (not npm --prefix) so process.cwd() is the release dir.
    if ! APP_COMMIT="$APP_COMMIT" pm2 start npm --name bridge --cwd "$CURRENT_LINK" -- start; then
        echo "ERROR: 'pm2 start' returned non-zero."
    fi
    pm2 save 2>/dev/null || true

    # Verify the process actually registered and is online — don't claim success
    # blindly (a silent start failure is how a broken boot hides itself).
    sleep 3
    if pm2 jlist 2>/dev/null | grep -q '"name":"bridge"'; then
        echo "App started (pm2 shows 'bridge')."
    else
        echo "ERROR: app did not register with PM2. Diagnostics follow:"
        echo "  HOME=$HOME  PM2_HOME=${PM2_HOME:-unset}"
        echo "  which pm2: $(command -v pm2 || echo 'not found')"
        echo "  which npm: $(command -v npm || echo 'not found')"
        pm2 list 2>&1 | tail -n 5 || true
    fi
}

# --- On ANY exit: return to hotspot, re-apply NAT, and guarantee app start ---
finish() {
    bb_return_to_hotspot        # shared helper: hotspot up + re-apply NAT
    start_app                   # the app MUST end up running no matter what
    echo "=== BridgeBox ready $(date -Is) ==="
}
trap finish EXIT

# =====================================================================
# PHASE 3 — activate a pending, fully-built release before the app starts
# =====================================================================
if [ -L "$PENDING_LINK" ]; then
    PENDING_TARGET=$(readlink -f "$PENDING_LINK" 2>/dev/null || echo "")
    if [ -n "$PENDING_TARGET" ] && [ -d "$PENDING_TARGET" ] && [ -f "$PENDING_TARGET/.built" ]; then
        echo "Activating pending release: $PENDING_TARGET"
        if [ -L "$CURRENT_LINK" ]; then
            ln -sfn "$(readlink -f "$CURRENT_LINK")" "$PREVIOUS_LINK"
        fi
        ln -sfn "$PENDING_TARGET" "$CURRENT_LINK"
        rm -f "$PENDING_LINK"
        echo "Activated. current -> $(readlink -f "$CURRENT_LINK")"
    else
        echo "Pending release not fully built — leaving current in place."
        rm -f "$PENDING_LINK"   # stale/incomplete pointer; build service will retry via .needs_build
    fi
fi

# =====================================================================
# PHASE 1 — download-only, BEFORE starting the app, bounded & fast-fail
# =====================================================================
# Skip the whole network phase instantly if there's no WiFi config: an offline
# box must boot to a game with zero delay.
if [ ! -f "$WIFI_CONFIG" ]; then
    echo "No wifi.json — offline box, skipping update, starting app now."
    exit 0   # trap -> finish() returns to hotspot (no-op) and starts the app
fi

# Everything network-related runs under a single hard deadline. If it overruns,
# the subshell is killed and we fall through to starting the app.
network_phase() {
    set +e   # handle failures explicitly with `return 0`; never abort mid-phase

    # Connect to the client WiFi using the shared helper (single source of
    # truth for wifi.json parsing + visible/hidden fallback).
    if ! bb_connect_wifi; then
        echo "WiFi connect failed — skipping update."; return 0
    fi
    if ! bb_have_internet; then
        echo "No internet — skipping update."; return 0
    fi

    mkdir -p "$RELEASES_DIR"

    # Record the running release as 'previous' the first time, for rollback.
    if [ -L "$CURRENT_LINK" ] && [ ! -L "$PREVIOUS_LINK" ]; then
        ln -sfn "$(readlink -f "$CURRENT_LINK")" "$PREVIOUS_LINK"
    fi

    # Resolve target commit (branch or tag).
    local remote_commit
    remote_commit=$(timeout "$NMCLI_TIMEOUT" git ls-remote "$REPO_URL" \
        "refs/heads/$RELEASE_REF" "refs/tags/$RELEASE_REF" | head -n1 | cut -f1)
    if [ -z "$remote_commit" ]; then
        echo "Could not resolve '$RELEASE_REF' on remote — skipping."; return 0
    fi

    # Compare against the NEWEST DOWNLOADED release (not just current), so a
    # release downloaded last session but not yet activated isn't re-downloaded.
    local newest_downloaded=""
    if [ -d "$RELEASES_DIR" ]; then
        newest_downloaded=$(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
            | grep -E '^[0-9a-f]{40}$' | while read -r d; do
                  [ -d "$RELEASES_DIR/$d/.git" ] && echo "$d"; done | head -n1)
    fi

    echo "Target ref: $RELEASE_REF  remote: $remote_commit"
    if [ -d "$RELEASES_DIR/$remote_commit" ]; then
        echo "Release $remote_commit already downloaded — nothing to fetch."
        return 0
    fi

    echo "Downloading new release $remote_commit (no build here)..."
    local new_release="$RELEASES_DIR/$remote_commit"
    [[ "$new_release" == "$RELEASES_DIR/"* ]] || { echo "Unsafe path"; return 0; }
    rm -rf "$new_release"
    if ! timeout "$CLONE_TIMEOUT" git clone "$REPO_URL" "$new_release"; then
        echo "Clone failed — discarding."; rm -rf "$new_release"; return 0
    fi
    if ! git -C "$new_release" checkout -q "$remote_commit"; then
        echo "Checkout failed — discarding."; rm -rf "$new_release"; return 0
    fi
    # Hand off to Phase 2: mark that this release needs building.
    : > "$new_release/.needs_build"
    echo "Downloaded $remote_commit; flagged for background build."
}

echo "Phase 1: network/download (hard deadline ${PHASE1_DEADLINE}s)..."
# Run the network phase in the background and enforce a hard overall deadline.
# If it overruns we kill it and fall through to starting the app. Functions and
# variables are already defined in this shell, so the subshell inherits them.
network_phase &
NP_PID=$!
WAITED=0
while kill -0 "$NP_PID" 2>/dev/null; do
    if [ "$WAITED" -ge "$PHASE1_DEADLINE" ]; then
        echo "Phase 1 exceeded ${PHASE1_DEADLINE}s — killing it and booting the app."
        kill -TERM "$NP_PID" 2>/dev/null || true
        sleep 2
        kill -KILL "$NP_PID" 2>/dev/null || true
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done
wait "$NP_PID" 2>/dev/null || true

# trap (finish) returns to hotspot and starts the app.
exit 0
