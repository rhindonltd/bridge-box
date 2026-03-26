#!/bin/bash
# BridgeBox app update + PM2 (bridgebox user)

set -euo pipefail

LOGFILE="/home/bridgebox/update.log"
exec > >(tee -a "$LOGFILE") 2>&1

IFACE="wlan0"
INSTALL_DIR="/home/bridgebox"
CURRENT_LINK="$INSTALL_DIR/bridge-box-scorer/current"
RELEASES_DIR="$INSTALL_DIR/bridge-box-scorer/releases"
WIFI_CONFIG="$INSTALL_DIR/bridge-box/wifi.json"
REPO_URL="https://github.com/rhindonltd/bridge-box-scorer.git"

echo "=== BridgeBox app startup ==="

# --- 1. START APP IMMEDIATELY ---
echo "Starting app (hotspot mode)..."

pm2 delete bridge 2>/dev/null || true
pm2 start npm --name bridge -- start --prefix "$CURRENT_LINK"
pm2 save

echo "App started."

# --- 2. WAIT FOR WIFI CONFIG ---
while [ ! -f "$WIFI_CONFIG" ]; do
    echo "Waiting for WiFi configuration..."
    sleep 5
done

echo "WiFi config found."

SSID=$(jq -r .ssid "$WIFI_CONFIG")
PASSWORD=$(jq -r .password "$WIFI_CONFIG")

echo "Connecting to WiFi: $SSID"

# --- 3. CONNECT TO WIFI ---
if nmcli device wifi connect "$SSID" password "$PASSWORD" wifi-sec.key-mgmt wpa-psk; then

    echo "WiFi connected, checking internet..."

    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "Internet available — checking for updates..."

        mkdir -p "$RELEASES_DIR"

        LOCAL_COMMIT=$(git -C "$CURRENT_LINK" rev-parse HEAD 2>/dev/null || echo "none")
        REMOTE_COMMIT=$(git ls-remote "$REPO_URL" refs/heads/main | cut -f1)

        echo "Local:  $LOCAL_COMMIT"
        echo "Remote: $REMOTE_COMMIT"

        if [ "$LOCAL_COMMIT" != "$REMOTE_COMMIT" ]; then
            echo "Updating to $REMOTE_COMMIT..."

            NEW_RELEASE="$RELEASES_DIR/$REMOTE_COMMIT"

            [[ "$NEW_RELEASE" == "$RELEASES_DIR/"* ]] || { echo "Unsafe delete path"; exit 1; }

            rm -rf "$NEW_RELEASE"
            git clone "$REPO_URL" "$NEW_RELEASE"

            cd "$NEW_RELEASE"
            npm install
            npm run build

            echo "Switching release..."

            pm2 stop bridge

            ln -sfn "$NEW_RELEASE" "$CURRENT_LINK"

            pm2 delete bridge 2>/dev/null || true
            pm2 start npm --name bridge -- start --prefix "$CURRENT_LINK"
            pm2 save

            echo "Update complete."
        else
            echo "Already up to date."
        fi

    else
        echo "No internet — skipping update."
    fi

    # --- 4. RETURN TO HOTSPOT MODE ---
    echo "Disconnecting WiFi (return to hotspot)..."
    nmcli device disconnect "$IFACE"

else
    echo "WiFi connection failed."
fi

echo "=== BridgeBox ready ==="