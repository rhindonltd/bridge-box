#!/bin/bash
# BridgeBox boot online-tasks orchestrator (bridgebox user).
#
# Dual-adapter model: the hotspot lives on its own radio and is ALWAYS up, and a
# separate client radio (wlan1) carries the internet link. So there's no radio
# to juggle here — we just do the local activate step, make sure the client link
# is online, and run the network jobs sequentially. (The client link is normally
# already up from boot, in bridge-box-root.sh; bb_wifi_online is a cheap re-check
# / best-effort bring-up.)
#
# Steps:
#   Phase 3 (LOCAL, no network): if a fully-built release is pending, activate
#           it (swap `current`) and restart the app service. Runs first because
#           it needs no connectivity.
#   Network jobs (via bb_run_online_window — now just "ensure online + run"):
#           1. the update DOWNLOAD job (download newer release + npm ci)
#           2. the player-sync job (refresh EBU players.db)
#           3. the movement-sync job (refresh the movement list)
#
# Nothing here starts or blocks the app; a total failure just leaves the box on
# the current release, serving normally. Because the hotspot is never disturbed,
# this is harmless even if it somehow overlapped a session — but it still runs at
# boot, before the app, as the natural place to do it.

set -uo pipefail

INSTALL_DIR="/home/bridgebox"
BOX_DIR="$INSTALL_DIR/bridge-box"
SCORER_DIR="$INSTALL_DIR/bridge-box-scorer"
CURRENT_LINK="$SCORER_DIR/current"
PREVIOUS_LINK="$SCORER_DIR/previous"
PENDING_LINK="$SCORER_DIR/pending"
WIFI_CONFIG="$INSTALL_DIR/wifi.json"
LOG_DIR="$INSTALL_DIR/logs"
LOGFILE="$LOG_DIR/online-tasks.log"
mkdir -p "$LOG_DIR"

# Shared WiFi lib (provides bb_run_online_window + helpers).
WIFI_LIB="$BOX_DIR/bridge-box-wifi-lib.sh"

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

echo "=== BridgeBox online tasks $(date -Is) ==="

# ---------------------------------------------------------------------------
# Phase 3 — LOCAL: activate a pending, fully-built release, then restart app.
# No connectivity needed, so this runs first, before any network jobs.
# ---------------------------------------------------------------------------
if [ -L "$PENDING_LINK" ]; then
    PENDING_TARGET=$(readlink -f "$PENDING_LINK" 2>/dev/null || echo "")
    if [ -n "$PENDING_TARGET" ] && [ -d "$PENDING_TARGET" ] && [ -f "$PENDING_TARGET/.built" ]; then
        echo "activate: pending release $PENDING_TARGET"
        [ -L "$CURRENT_LINK" ] && ln -sfn "$(readlink -f "$CURRENT_LINK")" "$PREVIOUS_LINK"
        ln -sfn "$PENDING_TARGET" "$CURRENT_LINK"
        rm -f "$PENDING_LINK"
        # Only restart if the app is ALREADY running (manual update-now while
        # live). At boot this orchestrator runs Before=bridge-box-app, so the app
        # hasn't started yet — the symlink swap is enough; it'll start fresh on
        # the new release. Restarting at boot is unnecessary and (being ordered
        # before the app) risks a systemd job deadlock. The helper uses
        # --no-block regardless, so the restart is queued, never waited on.
        if systemctl is-active --quiet bridge-box-app.service; then
            echo "activate: app is running — requesting restart onto new release..."
            sudo -n /usr/local/bridgebox/bin/restart-app.sh 2>/dev/null || \
                echo "activate: WARNING could not restart app service (new code runs next boot)."
        else
            echo "activate: app not yet started — it will come up on the new release."
        fi
    else
        echo "activate: pending release not fully built — leaving current in place."
        rm -f "$PENDING_LINK"
    fi
fi

# ---------------------------------------------------------------------------
# Network jobs — ensure the client link is online, then run them sequentially.
# The hotspot (separate radio) is never disturbed.
# ---------------------------------------------------------------------------
if [ ! -f "$WIFI_CONFIG" ]; then
    echo "online-tasks: no wifi.json — offline box, skipping network jobs."
    echo "=== BridgeBox online tasks done (offline) $(date -Is) ==="
    exit 0
fi

if [ ! -f "$WIFI_LIB" ]; then
    echo "online-tasks: wifi lib missing — cannot run network jobs."
    exit 0
fi
# shellcheck source=bridge-box-wifi-lib.sh
. "$WIFI_LIB"

# Jobs are radio-agnostic scripts that assume they're already online. They run
# sequentially (bb_run_online_window now just ensures the client link is up,
# then runs each); each is non-fatal. No hotspot cycle, no lock.
bb_run_online_window \
    "bash $BOX_DIR/bridge-box-update.sh" \
    "bash $BOX_DIR/bridge-box-player-sync.sh" \
    "bash $BOX_DIR/bridge-box-movement-sync.sh"

echo "=== BridgeBox online tasks done $(date -Is) ==="
exit 0
