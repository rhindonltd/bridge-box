#!/bin/bash
# BridgeBox Node.js major-version upgrade (manual, opt-in).
#
# Node is installed from the NodeSource apt repository, pinned to a major line
# (e.g. 24.x). Routine `apt upgrade` — including bridge-box-os-update.sh — only
# moves *within* that major. Crossing to a new major (e.g. 22 -> 24) means
# re-pointing the NodeSource repo and then rebuilding the app against the new
# runtime, so it is deliberately a separate, hands-on step.
#
# Usage (run on the device, with internet, no game in progress):
#   sudo /home/bridgebox/bridge-box/bridge-box-node-upgrade.sh 24
#
# After this, rebuild/redeploy the app so it is built against the new Node:
#   sudo systemctl restart bridge-box-update    # re-runs install/build path
# (or trigger an update cycle if a newer app release is pinned).

set -euo pipefail

TARGET_MAJOR="${1:-}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo." >&2
    exit 1
fi

if ! [[ "$TARGET_MAJOR" =~ ^[0-9]+$ ]]; then
    echo "Usage: $0 <node-major-version>   e.g. $0 24" >&2
    exit 1
fi

if ! timeout 15 ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "No internet — connect the box first. Aborting." >&2
    exit 1
fi

CURRENT=$(node --version 2>/dev/null || echo "none")
echo "=== BridgeBox Node upgrade $(date -Is) ==="
echo "Current Node: $CURRENT  ->  target: v${TARGET_MAJOR}.x"

# Re-point the NodeSource repo at the new major and install.
curl -fsSL "https://deb.nodesource.com/setup_${TARGET_MAJOR}.x" | bash -
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

NEW=$(node --version 2>/dev/null || echo "none")
echo "Node is now: $NEW"

# Rebuild the CURRENT release against the new Node so any native modules are
# recompiled. A plain service restart would NOT rebuild (the update script only
# builds when the remote commit differs), so rebuild the current release here.
INSTALL_DIR="/home/bridgebox"
CURRENT_LINK="$INSTALL_DIR/bridge-box-scorer/current"
if [ -d "$CURRENT_LINK" ]; then
    echo "Rebuilding current release against Node $NEW..."
    RELEASE_PATH="$(readlink -f "$CURRENT_LINK")"
    if sudo -u bridgebox bash -c "cd '$RELEASE_PATH' && { [ -f package-lock.json ] && npm ci || npm install; } && npm run build"; then
        echo "Rebuild OK. Reloading app..."
        sudo -u bridgebox pm2 reload bridge --update-env || sudo -u bridgebox pm2 restart bridge --update-env || true
    else
        echo "WARNING: rebuild failed. The app may not run correctly on the new Node." >&2
        echo "Investigate before relying on this box." >&2
    fi
else
    echo "No current release found to rebuild; skipping app rebuild."
fi

echo
echo "Verify the app: curl -f http://localhost:3000/healthz"
