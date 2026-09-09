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
    echo "Checking for an app update now (downloads + installs deps in one online window)."
    echo "NOTE: this briefly drops the hotspot to go online — run it when no one is playing."
    # The online-tasks orchestrator opens ONE window and runs the download job
    # (+ player sync); the build then runs to completion. Both blocking (--wait)
    # so they don't overlap on the radio/lock. The new version activates next boot.
    sudo systemctl start --wait bridge-box-online-tasks
    sudo systemctl start --wait bridge-box-build
    echo "Done. The new version (if any) activates on next switch-on."
    ;;

  os-update)
    exec sudo "$BOX_DIR/bridge-box-os-update.sh" "$@"
    ;;

  node-upgrade)
    exec sudo "$BOX_DIR/bridge-box-node-upgrade.sh" "$@"
    ;;

  cleanup-legacy)
    # One-off migration cleanup: remove systemd units this repo used to install
    # but no longer does, so an existing box doesn't keep stale/dangling units
    # after an update. A plain reinstall ADDS the new units but never removes
    # retired ones — this does. Idempotent and safe: only touches units that are
    # no longer part of the current design.
    echo "Removing retired systemd units (safe to run more than once)..."
    RETIRED_UNITS="bridge-box-update.service bridge-box-player-sync.timer"
    changed=0
    for u in $RETIRED_UNITS; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^$u"; then
            echo "- Disabling + removing $u..."
            sudo systemctl disable --now "$u" 2>/dev/null || true
            sudo rm -f "/etc/systemd/system/$u"
            changed=1
        else
            echo "- $u not present; skipping."
        fi
    done
    if [ "$changed" = "1" ]; then
        sudo systemctl daemon-reload
        sudo systemctl reset-failed 2>/dev/null || true
    fi
    echo "Done. Current boot units: root -> online-tasks -> app -> build. Check: systemctl --failed | grep bridge || echo clean"
    ;;

  backup-now)
    echo "Running a data backup now..."
    sudo systemctl start bridge-box-backup
    echo "Done. See: bridge logs-backup"
    ;;

  sync-players)
    echo "Syncing the EBU player list now."
    echo "NOTE: this briefly drops the hotspot to go online — run it when no one is playing."
    sudo systemctl start --wait bridge-box-player-sync
    echo "Done. Details: tail /home/bridgebox/player-sync.log"
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
  cleanup-legacy One-off: remove retired systemd units after an update
  backup-now    Take a data backup now
  sync-players  Update the EBU player list now (briefly drops the hotspot; run when idle)
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
