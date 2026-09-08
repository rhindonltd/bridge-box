#!/bin/bash
# BridgeBox boot-time app update (bridgebox user). DOWNLOAD ONLY — it does NOT
# start the app (that's bridge-box-app.service, supervised by systemd).
#
# Three-phase update model:
#   Phase 3 (here, first): if a fully-built release is pending, activate it
#           (swap `current`) and restart the app service so it runs the new code.
#   Phase 1 (here): if online-capable, download any newer release (no build),
#           then return to hotspot. Build happens in bridge-box-build.service.
#
# The app's availability does NOT depend on this script: it can fail entirely
# and the app keeps running under its own systemd unit. The only network switch
# happens here at boot, before anyone is using the app.

set -uo pipefail

# --- CONFIG ---
IFACE="wlan0"
INSTALL_DIR="/home/bridgebox"
SCORER_DIR="$INSTALL_DIR/bridge-box-scorer"
CURRENT_LINK="$SCORER_DIR/current"
PREVIOUS_LINK="$SCORER_DIR/previous"
PENDING_LINK="$SCORER_DIR/pending"
RELEASES_DIR="$SCORER_DIR/releases"
WIFI_CONFIG="$INSTALL_DIR/wifi.json"
REPO_URL="https://github.com/rhindonltd/bridge-box-scorer.git"
HOTSPOT_CONNECTION="bridge-hotspot"
LOCKFILE="$INSTALL_DIR/.update.lock"
LOGFILE="$INSTALL_DIR/update.log"

RELEASE_REF="main"
[ -f "$INSTALL_DIR/release.conf" ] && . "$INSTALL_DIR/release.conf"

CLONE_TIMEOUT=120
NPM_INSTALL_TIMEOUT=600   # `npm ci` on a Pi can take several minutes
PING_TIMEOUT=10
# Phase 1 now includes `npm ci` (deps must be fetched while online, since a new
# release may change dependencies and Phase 2 has no network). Generous cap —
# nothing user-facing waits on this (the app is its own independent service).
PHASE1_DEADLINE=900

# Shared WiFi helpers (connect / return-to-hotspot; non-root routes via sudo).
BB_IFACE="$IFACE"
BB_INSTALL_DIR="$INSTALL_DIR"
BB_WIFI_CONFIG="$WIFI_CONFIG"
BB_HOTSPOT_CONNECTION="$HOTSPOT_CONNECTION"
BB_PING_TIMEOUT="$PING_TIMEOUT"
WIFI_LIB="$INSTALL_DIR/bridge-box/bridge-box-wifi-lib.sh"
# shellcheck source=bridge-box-wifi-lib.sh
if [ -f "$WIFI_LIB" ]; then . "$WIFI_LIB"; else
    echo "WARNING: wifi lib missing — cannot update this run."
    bb_connect_wifi() { return 1; }
    bb_have_internet() { return 1; }
    bb_return_to_hotspot() { sudo -n /usr/local/bridgebox/bin/wifi-ctl.sh hotspot 2>/dev/null || true; }
fi

# --- Bounded logging ---
MAX_LOG_BYTES=$((5 * 1024 * 1024))
if [ -f "$LOGFILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt "$MAX_LOG_BYTES" ]; then
        tail -c "$((MAX_LOG_BYTES / 2))" "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null || true
        mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null || true
    fi
fi
exec >> "$LOGFILE" 2>&1

echo "=== BridgeBox update $(date -Is) ==="

# --- Single-instance lock (only guards the network phase) ---
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "Another update run is in progress — exiting."
    exit 0
fi

# Guarantee we ALWAYS return to hotspot mode, however the script exits after
# this point (deadline kill, unexpected error, etc.). Only arm the trap once we
# hold the lock and are about to touch the network. HOTSPOT_RESTORED guards
# against running it twice (explicit call at the end + this trap).
HOTSPOT_RESTORED=0
restore_hotspot_once() {
    [ "$HOTSPOT_RESTORED" = "1" ] && return 0
    HOTSPOT_RESTORED=1
    bb_return_to_hotspot
}
trap restore_hotspot_once EXIT

# =====================================================================
# PHASE 3 — activate a pending, fully-built release, then restart the app
# =====================================================================
if [ -L "$PENDING_LINK" ]; then
    PENDING_TARGET=$(readlink -f "$PENDING_LINK" 2>/dev/null || echo "")
    if [ -n "$PENDING_TARGET" ] && [ -d "$PENDING_TARGET" ] && [ -f "$PENDING_TARGET/.built" ]; then
        echo "Activating pending release: $PENDING_TARGET"
        [ -L "$CURRENT_LINK" ] && ln -sfn "$(readlink -f "$CURRENT_LINK")" "$PREVIOUS_LINK"
        ln -sfn "$PENDING_TARGET" "$CURRENT_LINK"
        rm -f "$PENDING_LINK"
        echo "Activated. Restarting app service..."
        sudo -n /usr/local/bridgebox/bin/restart-app.sh 2>/dev/null || \
            echo "WARNING: could not restart app service (will run new code next boot)."
    else
        echo "Pending release not fully built — leaving current in place."
        rm -f "$PENDING_LINK"
    fi
fi

# =====================================================================
# PHASE 1 — download-only (no build, no app start)
# =====================================================================
if [ ! -f "$WIFI_CONFIG" ]; then
    echo "No wifi.json — offline box, skipping update."
    exit 0
fi

download_phase() {
    set +e
    if ! bb_connect_wifi; then echo "WiFi connect failed — skipping update."; return 0; fi
    if ! bb_have_internet; then echo "No internet — skipping update."; return 0; fi

    mkdir -p "$RELEASES_DIR"
    [ -L "$CURRENT_LINK" ] && [ ! -L "$PREVIOUS_LINK" ] && \
        ln -sfn "$(readlink -f "$CURRENT_LINK")" "$PREVIOUS_LINK"

    local remote_commit
    remote_commit=$(timeout 30 git ls-remote "$REPO_URL" \
        "refs/heads/$RELEASE_REF" "refs/tags/$RELEASE_REF" | head -n1 | cut -f1)
    if [ -z "$remote_commit" ]; then echo "Could not resolve '$RELEASE_REF' — skipping."; return 0; fi

    echo "Target ref: $RELEASE_REF  remote: $remote_commit"
    if [ -d "$RELEASES_DIR/$remote_commit" ]; then
        echo "Release $remote_commit already downloaded — nothing to fetch."
        return 0
    fi

    echo "Downloading release $remote_commit..."
    local new_release="$RELEASES_DIR/$remote_commit"
    [[ "$new_release" == "$RELEASES_DIR/"* ]] || { echo "Unsafe path"; return 0; }
    rm -rf "$new_release"
    if ! timeout "$CLONE_TIMEOUT" git clone "$REPO_URL" "$new_release"; then
        echo "Clone failed — discarding."; rm -rf "$new_release"; return 0
    fi
    if ! git -C "$new_release" checkout -q "$remote_commit"; then
        echo "Checkout failed — discarding."; rm -rf "$new_release"; return 0
    fi

    # Supply .env + create data dirs before installing/building.
    bash "$INSTALL_DIR/bridge-box/bridge-box-deploy-env.sh" "$new_release" || {
        echo "deploy-env failed — discarding."; rm -rf "$new_release"; return 0
    }

    # Install dependencies WHILE ONLINE (a new release may change deps; Phase 2's
    # build runs with no network, so npm ci must happen here). Only after deps
    # are present do we flag the release for the background build (Phase 2).
    echo "Installing dependencies (npm ci) while online..."
    local install_cmd="npm install"
    [ -f "$new_release/package-lock.json" ] && install_cmd="npm ci"
    if ! ( cd "$new_release" && timeout "$NPM_INSTALL_TIMEOUT" $install_cmd ); then
        echo "Dependency install failed — discarding release."; rm -rf "$new_release"; return 0
    fi

    : > "$new_release/.needs_build"
    echo "Downloaded + installed deps for $remote_commit; flagged for background build."
}

echo "Phase 1: network/download (hard deadline ${PHASE1_DEADLINE}s)..."
download_phase &
NP_PID=$!
WAITED=0
while kill -0 "$NP_PID" 2>/dev/null; do
    if [ "$WAITED" -ge "$PHASE1_DEADLINE" ]; then
        echo "Phase 1 exceeded ${PHASE1_DEADLINE}s — aborting network phase."
        kill -TERM "$NP_PID" 2>/dev/null || true; sleep 2; kill -KILL "$NP_PID" 2>/dev/null || true
        break
    fi
    sleep 1; WAITED=$((WAITED + 1))
done
wait "$NP_PID" 2>/dev/null || true

# Return to hotspot now (the EXIT trap also guarantees it if we somehow don't
# reach here).
restore_hotspot_once
echo "=== BridgeBox update done $(date -Is) ==="
exit 0
