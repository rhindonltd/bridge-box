```bash
#!/bin/bash
# startup.sh — BridgeBox runtime (atomic + offline-first)

set -e

IFACE="wlan0"
APP_PORT=3000

INSTALL_DIR="/home/bridgebox"
BOX_DIR="$INSTALL_DIR/bridge-box"
CURRENT_LINK="$INSTALL_DIR/bridge-box-scorer/current"
RELEASES_DIR="$INSTALL_DIR/bridge-box-scorer/releases"

CONNECTION_NAME="bridge-hotspot"
WIFI_CONFIG="$BOX_DIR/wifi.json"

echo "=== BridgeBox Startup ==="

# --- 1. Determine first boot ---
if [ ! -f "$WIFI_CONFIG" ]; then
  echo "No WiFi configuration found — first boot detected"
  FIRST_BOOT=1
else
  FIRST_BOOT=0
fi

# --- 2. Start hotspot ---
echo "Starting hotspot..."

MAC=$(cat /sys/class/net/$IFACE/address | tr -d ':' | tail -c 5 | tr '[:lower:]' '[:upper:]')
HOTSPOT_SSID="BridgeBox-$MAC"
HOTSPOT_PASS="bridgebox"

nmcli connection delete "$CONNECTION_NAME" 2>/dev/null || true

nmcli device wifi hotspot \
  ifname "$IFACE" \
  con-name "$CONNECTION_NAME" \
  ssid "$HOTSPOT_SSID" \
  password "$HOTSPOT_PASS"

nmcli connection modify "$CONNECTION_NAME" \
  ipv4.method shared \
  connection.autoconnect yes \
  connection.autoconnect-priority 100

echo "Hotspot '$HOTSPOT_SSID' active."

# --- 3. Enable captive portal redirect ---
sudo sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
  echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf

sudo iptables -t nat -F
sudo iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80 -j REDIRECT --to-port $APP_PORT
sudo iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-port $APP_PORT
sudo netfilter-persistent save

# --- 4. Start app EARLY (fixes setup deadlock) ---
echo "Starting app..."

cd "$CURRENT_LINK" || { echo "App not found!"; exit 1; }

pm2 delete bridge 2>/dev/null || true
pm2 start npm --name bridge -- start
pm2 save

# --- 5. First boot: wait for WiFi setup ---
if [ "$FIRST_BOOT" -eq 1 ]; then
  echo "Waiting for WiFi setup via web UI..."

  while [ ! -f "$WIFI_CONFIG" ]; do
    sleep 5
  done

  echo "WiFi configuration saved."
fi

# --- 6. Connect to WiFi temporarily ---
if [ -f "$WIFI_CONFIG" ]; then
  SSID=$(jq -r .ssid "$WIFI_CONFIG")
  PASSWORD=$(jq -r .password "$WIFI_CONFIG")

  echo "Attempting WiFi connection: $SSID"

  if nmcli device wifi connect "$SSID" password "$PASSWORD"; then

    echo "WiFi connected. Checking internet..."

    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
      echo "Internet reachable — performing atomic update..."

      ```bash
      echo "Checking for updates..."

      LOCAL_COMMIT=$(git -C "$CURRENT_LINK" rev-parse HEAD 2>/dev/null || echo "none")
      REMOTE_COMMIT=$(git ls-remote https://github.com/rhindonltd/bridge-box-scorer.git refs/heads/main | cut -f1)

      echo "Local:  $LOCAL_COMMIT"
      echo "Remote: $REMOTE_COMMIT"

      NEW_RELEASE="$RELEASES_DIR/$REMOTE_COMMIT"

      if [ "$LOCAL_COMMIT" = "$REMOTE_COMMIT" ]; then
          echo "Already up to date — no update needed."
      else
        echo "Updating to $REMOTE_COMMIT..."
        rm -rf "$NEW_RELEASE"
        git clone https://github.com/rhindonltd/bridge-box-scorer.git "$NEW_RELEASE"
        cd "$NEW_RELEASE"
        npm install
        npm run build
        pm2 stop bridge
        ln -sfn "$NEW_RELEASE" "$CURRENT_LINK"
        cd "$CURRENT_LINK"
        pm2 start npm --name bridge -- start
        pm2 save
        echo "Update complete."
      fi
      ```

      # Cleanup old releases (keep last 3)
      cd "$RELEASES_DIR"
      ls -dt app_* | tail -n +4 | xargs -r rm -rf

    else
      echo "No internet — skipping update."
    fi

    # Disconnect WiFi (return to hotspot-only mode)
    nmcli device disconnect "$IFACE"

  else
    echo "WiFi connection failed — staying in hotspot mode."
  fi
fi

echo "=== BridgeBox ready ==="
echo "Connect to WiFi: $HOTSPOT_SSID"
echo "Open: http://bridge.local:$APP_PORT"
```
