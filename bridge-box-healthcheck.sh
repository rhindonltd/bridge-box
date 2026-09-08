#!/bin/bash
# BridgeBox health check — detects a hung app (process alive, HTTP dead)
# and reloads it. Runs periodically via bridge-box-healthcheck.timer.

set -uo pipefail

APP_URL="http://127.0.0.1:3000/"
# If the scorer app exposes a health endpoint, prefer it (falls back to APP_URL).
HEALTH_URL="http://127.0.0.1:3000/healthz"
LOGFILE="/home/bridgebox/healthcheck.log"

# Bounded logging.
MAX_LOG_BYTES=$((2 * 1024 * 1024))
if [ -f "$LOGFILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt "$MAX_LOG_BYTES" ]; then
        tail -c "$((MAX_LOG_BYTES / 2))" "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null || true
        mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null || true
    fi
fi

log() { echo "$(date -Is) $*" >> "$LOGFILE"; }

# Don't act while an update is in progress (#1): it may be briefly switching
# wlan0 / restarting the app, which would look unhealthy and trigger a needless
# reload right as the update reloads too.
if systemctl is-active --quiet bridge-box-update.service; then
    exit 0
fi

check() {
    # Try the health endpoint first; fall back to the root URL.
    if curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
        return 0
    fi
    curl -fsS --max-time 5 "$APP_URL" >/dev/null 2>&1
}

# Two strikes before acting, to avoid reloading on a transient blip.
if check; then
    exit 0
fi
sleep 5
if check; then
    exit 0
fi

log "App not responding on :3000 — restarting bridge-box-app.service."
if sudo -n /usr/local/bridgebox/bin/restart-app.sh >/dev/null 2>&1; then
    log "app service restart issued."
else
    log "app service restart failed (sudo helper)."
fi
