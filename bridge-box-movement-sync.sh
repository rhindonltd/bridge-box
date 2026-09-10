#!/bin/bash
# BridgeBox movement-list sync JOB (radio-agnostic).
#
# Runs the app's compiled, standalone sync command (dist/sync-movements.js),
# which downloads the movement definitions and writes them into the app's DB.
# This is a "job" run INSIDE the online window opened by
# bridge-box-online-tasks.sh (or the manual `bridge sync-movements`, which also
# wraps it in a window). It ASSUMES the box is already online — it does NOT
# touch the radio, the lock, or traps.
#
# The app owns the fetch/parse/DB write; the sync command is self-migrating,
# idempotent and guarded (a truncated download won't corrupt the DB). This job
# just invokes it with the right env, and is non-fatal.

set -uo pipefail

INSTALL_DIR="/home/bridgebox"
SCORER_DIR="$INSTALL_DIR/bridge-box-scorer"
CURRENT_LINK="$SCORER_DIR/current"
DATA_DIR="$INSTALL_DIR/data"
LOG_DIR="$INSTALL_DIR/logs"
LOGFILE="$LOG_DIR/movement-sync.log"
mkdir -p "$LOG_DIR"

# --- Bounded logging ---
MAX_LOG_BYTES=$((2 * 1024 * 1024))
if [ -f "$LOGFILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt "$MAX_LOG_BYTES" ]; then
        tail -c "$((MAX_LOG_BYTES / 2))" "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null || true
        mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null || true
    fi
fi
exec >> "$LOGFILE" 2>&1

echo "=== BridgeBox movement sync job $(date -Is) ==="

# Assumes online (the online-window orchestrator ensured it). Bail cheaply if not.
if ! timeout 15 ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "movement-sync: not online — skipping (DB left as-is)."
    exit 0
fi

REL="$(readlink -f "$CURRENT_LINK" 2>/dev/null || echo "")"
if [ -z "$REL" ] || [ ! -d "$REL" ]; then
    echo "movement-sync: no current release — skipping."
    exit 0
fi
if [ ! -f "$REL/dist/sync-movements.js" ]; then
    echo "movement-sync: $REL has no dist/sync-movements.js (older release) — skipping."
    exit 0
fi

shim_args=()
[ -f "$REL/scripts/allow-server-only.cjs" ] && shim_args=(-r ./scripts/allow-server-only.cjs)

echo "movement-sync: running dist/sync-movements.js (DATABASE_URL=$DATA_DIR)..."
if ( cd "$REL" && NODE_ENV=production DATABASE_URL="$DATA_DIR" \
        timeout 300 node "${shim_args[@]}" dist/sync-movements.js ); then
    echo "movement-sync: completed OK."
else
    echo "movement-sync: sync command failed (existing DB left intact)."
fi
exit 0
