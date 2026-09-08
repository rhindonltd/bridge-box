#!/bin/bash
# BridgeBox admin CLI — short, memorable wrappers for common tasks.
# Installed as /usr/local/bin/bridge (see install.sh). Usage: `bridge <command>`.
#
# Design notes:
# - The app runs as a native systemd service (bridge-box-app.service); status
#   and logs come from systemctl/journalctl. No PM2.
# - Commands that touch the system (apt, systemctl, reboot) use sudo.
# - This is a thin dispatcher over the existing scripts/units — one source of
#   truth, easy to extend.

set -uo pipefail

BOX_DIR="/home/bridgebox/bridge-box"
INSTALL_DIR="/home/bridgebox"
APP_UNIT="bridge-box-app.service"

cmd="${1:-help}"
shift || true

case "$cmd" in
  status)
    echo "== App service =="
    systemctl status "$APP_UNIT" --no-pager -n 0 2>/dev/null | head -n 5
    echo
    echo "== App health =="
    curl -fsS http://localhost:3000/healthz && echo || echo "healthz not responding"
    ;;

  logs)
    # Follow the app logs. Pass extra args through (e.g. `bridge logs -n 100`).
    exec sudo journalctl -u "$APP_UNIT" -f "$@"
    ;;

  restart)
    echo "Restarting the app..."
    sudo systemctl restart "$APP_UNIT"
    ;;

  update-now)
    echo "Checking for an app update now (downloads; builds in background; live next boot)..."
    # Run strictly sequentially and wait for each to finish, so the download and
    # the build never overlap (they share the network lock and the radio, and
    # overlapping runs cause NetworkManager 'activation enqueued' errors).
    # `restart` on the oneshot update service blocks until it completes; then run
    # the build to completion with --wait.
    sudo systemctl restart bridge-box-update
    sudo systemctl start --wait bridge-box-build
    echo "Done. The new version (if any) activates on next switch-on."
    ;;

  os-update)
    exec sudo "$BOX_DIR/bridge-box-os-update.sh" "$@"
    ;;

  node-upgrade)
    exec sudo "$BOX_DIR/bridge-box-node-upgrade.sh" "$@"
    ;;

  cleanup-pm2)
    # One-off migration cleanup for a box that ran the old PM2-based system.
    # Idempotent and safe on a box that never had PM2. Removes the orphaned PM2
    # daemon/state, the global pm2 package, any pm2 boot unit, and the stale
    # restart-service.sh helper. Does NOT touch the new systemd app service.
    echo "Cleaning up old PM2-based system (safe to run more than once)..."

    if command -v pm2 >/dev/null 2>&1; then
        echo "- Killing any running PM2 daemon (as bridgebox)..."
        sudo -u bridgebox env HOME=/home/bridgebox PM2_HOME=/home/bridgebox/.pm2 pm2 kill >/dev/null 2>&1 || true
    else
        echo "- pm2 not installed; nothing to kill."
    fi

    if [ -d /home/bridgebox/.pm2 ]; then
        echo "- Removing /home/bridgebox/.pm2 (PM2 state/logs)..."
        sudo rm -rf /home/bridgebox/.pm2
    else
        echo "- No /home/bridgebox/.pm2; skipping."
    fi

    if systemctl list-unit-files 2>/dev/null | grep -qi '^pm2-'; then
        unit=$(systemctl list-unit-files 2>/dev/null | grep -i '^pm2-' | awk '{print $1}' | head -n1)
        echo "- Disabling/removing PM2 boot unit ($unit)..."
        sudo systemctl disable --now "$unit" 2>/dev/null || true
        sudo rm -f "/etc/systemd/system/$unit"
        sudo systemctl daemon-reload
    else
        echo "- No pm2 boot unit; skipping."
    fi

    if npm ls -g --depth=0 pm2 >/dev/null 2>&1; then
        echo "- Uninstalling global pm2 npm package..."
        sudo npm uninstall -g pm2 >/dev/null 2>&1 || true
    else
        echo "- Global pm2 package not present; skipping."
    fi

    if [ -e /usr/local/bridgebox/bin/restart-service.sh ]; then
        echo "- Removing stale restart-service.sh sudo helper..."
        sudo rm -f /usr/local/bridgebox/bin/restart-service.sh
    else
        echo "- No stale restart-service.sh; skipping."
    fi

    echo "Cleanup complete. The app runs under bridge-box-app.service now — check: bridge status"
    ;;

  backup-now)
    echo "Running a data backup now..."
    sudo systemctl start bridge-box-backup
    echo "Done. See: bridge logs-backup"
    ;;

  version)
    curl -fsS http://localhost:3000/healthz 2>/dev/null || echo "app not responding"
    ;;

  wifi)
    # Show / set the client WiFi used for updates. `bridge wifi` prints current
    # (password masked); `bridge wifi <ssid> <password> [hidden]` writes it.
    if [ "$#" -eq 0 ]; then
        if [ -f "$INSTALL_DIR/wifi.json" ]; then
            echo "Current wifi.json (password hidden):"
            jq '.password = "***"' "$INSTALL_DIR/wifi.json" 2>/dev/null || cat "$INSTALL_DIR/wifi.json"
        else
            echo "No wifi.json set. Usage: bridge wifi <ssid> <password> [hidden]"
        fi
    else
        ssid="$1"; password="${2:-}"; hidden="${3:-no}"
        if [ -z "$password" ]; then echo "Usage: bridge wifi <ssid> <password> [hidden]"; exit 1; fi
        printf '{\n  "ssid": "%s",\n  "password": "%s",\n  "hidden": "%s"\n}\n' \
            "$ssid" "$password" "$hidden" | sudo -u bridgebox tee "$INSTALL_DIR/wifi.json" >/dev/null
        sudo -u bridgebox chmod 600 "$INSTALL_DIR/wifi.json"
        echo "Saved wifi.json for '$ssid'. It'll be used at the next update/switch-on."
    fi
    ;;

  password)
    echo "Hotspot credentials:"
    cat "$INSTALL_DIR/hotspot-credentials.txt" 2>/dev/null || echo "not found"
    ;;

  reboot)
    sudo systemctl reboot
    ;;

  help|-h|--help)
    cat <<'EOF'
BridgeBox admin — usage: bridge <command>

  status        Show app service status and health check
  logs          Follow the app logs (Ctrl-C to stop)
  restart       Restart the app
  update-now    Check for an app update now (activates on next switch-on)
  os-update     Apply OS security updates (switches to WiFi, then back)
  node-upgrade  Upgrade Node.js to a new major, e.g. bridge node-upgrade 24
  cleanup-pm2   One-off: remove leftovers from the old PM2-based system
  backup-now    Take a data backup now
  version       Show the running app version (from /healthz)
  wifi          Show WiFi config, or set it: bridge wifi <ssid> <password> [hidden]
  password      Show this box's hotspot SSID + password
  reboot        Reboot the box
  help          Show this help
EOF
    ;;

  *)
    echo "Unknown command: $cmd"
    echo "Run 'bridge help' for the list."
    exit 1
    ;;
esac
