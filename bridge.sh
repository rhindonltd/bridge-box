#!/bin/bash
# BridgeBox admin CLI — short, memorable wrappers for common tasks.
# Installed as /usr/local/bin/bridge (see install.sh). Usage: `bridge <command>`.
#
# Design notes:
# - App/PM2 commands run as the `bridgebox` user with HOME/PM2_HOME set, because
#   PM2 is per-user and the app runs under bridgebox's PM2 daemon (running them
#   as root or another user would show an empty/ different PM2).
# - Commands that touch the system (apt, systemctl, reboot) use sudo.
# - This is a thin dispatcher over the existing scripts/units — one source of
#   truth, easy to extend.

set -uo pipefail

BOX_DIR="/home/bridgebox/bridge-box"
INSTALL_DIR="/home/bridgebox"

# Run a command as the bridgebox user with PM2's environment set.
as_bridgebox() {
    sudo -u bridgebox env HOME="$INSTALL_DIR" PM2_HOME="$INSTALL_DIR/.pm2" \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  status)
    echo "== PM2 =="
    as_bridgebox pm2 status
    echo
    echo "== App health =="
    curl -fsS http://localhost:3000/healthz && echo || echo "healthz not responding"
    ;;

  logs)
    # Follow the app logs. Pass extra args through (e.g. `bridge logs --lines 100`).
    as_bridgebox pm2 logs bridge "$@"
    ;;

  restart)
    echo "Restarting the app (re-runs boot update/start flow)..."
    sudo systemctl restart bridge-box-update
    ;;

  update-now)
    echo "Checking for an app update now (downloads; builds in background; live next boot)..."
    sudo systemctl restart bridge-box-update
    sudo systemctl start bridge-box-build
    echo "Done. The new version (if any) activates on next switch-on."
    ;;

  os-update)
    exec sudo "$BOX_DIR/bridge-box-os-update.sh" "$@"
    ;;

  node-upgrade)
    exec sudo "$BOX_DIR/bridge-box-node-upgrade.sh" "$@"
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

  status        Show app (PM2) status and health check
  logs          Follow the app logs (Ctrl-C to stop)
  restart       Restart the app (re-runs the boot update/start flow)
  update-now    Check for an app update now (activates on next switch-on)
  os-update     Apply OS security updates (switches to WiFi, then back)
  node-upgrade  Upgrade Node.js to a new major, e.g. bridge node-upgrade 24
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
