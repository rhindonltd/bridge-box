#!/bin/bash
# BridgeBox boot online-tasks orchestrator (bridgebox user).
#
# Fork/join model: at boot, BEFORE the app service starts (so no session is
# active), do the one local step that needs no network, then open the online
# window ONCE and run all network jobs inside it, then close it ONCE. This means
# a single hotspot down/up cycle per boot regardless of how many network jobs
# there are — and the app service is entirely independent of all of this.
#
# Steps:
#   Phase 3 (LOCAL, no network): if a fully-built release is pending, activate
#           it (swap `current`) and restart the app service. Runs first, outside
#           the window, because it needs no connectivity.
#   Online window (via bb_run_online_window): run, sequentially —
#           1. the update DOWNLOAD job (download newer release + npm ci)
#           2. the player-sync job (refresh EBU players.db)
#   The window opens once (hotspot down -> client WiFi), runs both jobs, and
#   always closes once (back to hotspot), guaranteed by the lib's trap.
#
# Nothing here starts or blocks the app; a total failure just leaves the box on
# the current release, serving normally.

set -uo pipefail

INSTALL_DIR="/home/bridgebox"
BOX_DIR="$INSTALL_DIR/bridge-box"
SCORER_DIR="$INSTALL_DIR/bridge-box-scorer"
CURRENT_LINK="$SCORER_DIR/current"
PREVIOUS_LINK="$SCORER_DIR/previous"
PENDING_LINK="$SCORER_DIR/pending"
WIFI_CONFIG="$INSTALL_DIR/wifi.json"
LOGFILE="$INSTALL_DIR/online-tasks.log"

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
# No connectivity needed, so this runs OUTSIDE the online window, first.
# ---------------------------------------------------------------------------
if [ -L "$PENDING_LINK" ]; then
    PENDING_TARGET=$(readlink -f "$PENDING_LINK" 2>/dev/null || echo "")
    if [ -n "$PENDING_TARGET" ] && [ -d "$PENDING_TARGET" ] && [ -f "$PENDING_TARGET/.built" ]; then
        echo "activate: pending release $PENDING_TARGET"
        [ -L "$CURRENT_LINK" ] && ln -sfn "$(readlink -f "$CURRENT_LINK")" "$PREVIOUS_LINK"
        ln -sfn "$PENDING_TARGET" "$CURRENT_LINK"
        rm -f "$PENDING_LINK"
        echo "activate: restarting app service..."
        sudo -n /usr/local/bridgebox/bin/restart-app.sh 2>/dev/null || \
            echo "activate: WARNING could not restart app service (new code runs next boot)."
    else
        echo "activate: pending release not fully built — leaving current in place."
        rm -f "$PENDING_LINK"
    fi
fi

# ---------------------------------------------------------------------------
# Online window — run the network jobs inside ONE hotspot down/up cycle.
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
# sequentially inside the single window; each is non-fatal.
bb_run_online_window \
    "bash $BOX_DIR/bridge-box-update.sh" \
    "bash $BOX_DIR/bridge-box-player-sync.sh"

echo "=== BridgeBox online tasks done $(date -Is) ==="
exit 0
