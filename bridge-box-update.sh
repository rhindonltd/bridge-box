#!/bin/bash
# BridgeBox app update + PM2 (bridgebox user)

set -euo pipefail

LOGFILE="/home/bridgebox/update.log"
exec > >(tee -a "$LOGFILE") 2>&1

IFACE="wlan0"
INSTALL_DIR="/home/bridgebox"
CURRENT_LINK="$INSTALL_DIR/bridge-box-scorer/current"
RELEASES_DIR="$INSTALL_DIR/bridge-box-scorer/releases"
WIFI_CONFIG="$INSTALL_DIR/wifi.json"
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
HIDDEN=$(jq -r .hidden "$WIFI_CONFIG")

echo "Connecting to WiFi: $SSID"

# --- 3. CONNECT TO WIFI ---
connect_wifi() {
    nmcli connection delete "$SSID" 2>/dev/null
    if [ "$HIDDEN" = "yes" ]; then
        nmcli device wifi connect "$SSID" password "$PASSWORD" hidden yes
    else

        nmcli device wifi connect "$SSID" password "$PASSWORD"
    fi
}

# First try visible
if connect_wifi "no"; then
    echo "WiFi connected (visible SSID)."
elif connect_wifi "yes"; then
    echo "WiFi connected (hidden SSID)."
else
    echo "WiFi connection failed. Check SSID and password."
    exit 1
fi

# --- 4. CHECK INTERNET AND UPDATE APP ---
if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "Internet available"
    echo "Checking for apt updates..."

    sudo apt update
    sudo apt upgrade

    echo "Checking for bridge-scorer updates..."

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

        echo "Installing dependencies..."
        npm install

        echo "Building app..."
        if ! npm run build; then
            echo "Build failed — aborting update"
            rm -rf "$NEW_RELEASE"
            exit 1
        fi

        echo "Build successful."

        # --- Save current as previous ---
        if [ -L "$CURRENT_LINK" ]; then
            PREV_TARGET=$(readlink -f "$CURRENT_LINK")
            ln -sfn "$PREV_TARGET" "$INSTALL_DIR/bridge-box-scorer/previous"
            echo "Saved previous release: $PREV_TARGET"
        fi

        # --- Switch symlink ---
        ln -sfn "$NEW_RELEASE" "$CURRENT_LINK"
        echo "Switched to new release."

        # --- Zero-downtime reload ---
        echo "Reloading app (zero downtime)..."
        pm2 reload bridge || {
            echo "Reload failed — rolling back..."
            if [ -L "$INSTALL_DIR/bridge-box-scorer/previous" ]; then
                PREV=$(readlink -f "$INSTALL_DIR/bridge-box-scorer/previous")
                ln -sfn "$PREV" "$CURRENT_LINK"
                pm2 reload bridge
                echo "Rollback complete."
            else
                echo "No previous version available!"
            fi
        }

        echo "Cleaning old releases..."
        cd "$RELEASES_DIR" || exit 1
        mapfile -t RELEASES < <(find . -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | awk '{print $2}')
        KEEP=3
        COUNT=0
        for REL in "${RELEASES[@]}"; do
            COUNT=$((COUNT + 1))
            if [ "$COUNT" -le "$KEEP" ]; then
                continue
            fi
            FULL_PATH="$(realpath "$REL")"
            CURRENT_TARGET=$(readlink -f "$CURRENT_LINK" 2>/dev/null || echo "")
            PREVIOUS_TARGET=$(readlink -f "$INSTALL_DIR/bridge-box-scorer/previous" 2>/dev/null || echo "")
            if [ "$FULL_PATH" = "$CURRENT_TARGET" ] || [ "$FULL_PATH" = "$PREVIOUS_TARGET" ]; then
                echo "Skipping active release: $FULL_PATH"
                continue
            fi
            echo "Deleting old release: $FULL_PATH"
            rm -rf "$FULL_PATH"
        done

        echo "Update complete."
    else
        echo "Already up to date."
    fi

else
    echo "No internet — skipping update."
fi

# --- 5. RETURN TO HOTSPOT MODE ---
echo "Disconnecting WiFi (return to hotspot)..."
nmcli device disconnect "$IFACE"

echo "=== BridgeBox ready ==="