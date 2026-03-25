#!/bin/bash
# startup.sh — BridgeBox first-boot & regular startup

set -e

IFACE="wlan0"
APP_PORT=3000
BOX_DIR="/home/bridgebox/bridge-box"
APP_DIR="/home/bridgebox/bridge-box-scorer"
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

# --- 2. Start hotspot for setup / offline scoring ---
echo "Starting hotspot..."
MAC=$(cat /sys/class/net/$IFACE/address | tr -d ':' | tail -c 5 | tr '[:lower:]' '[:upper:]')
HOTSPOT_SSID="BridgeBox-$MAC"
HOTSPOT_PASS="bridgebox"

# Delete old hotspot if exists
nmcli connection delete "$CONNECTION_NAME" 2>/dev/null || true

# Create hotspot connection
nmcli device wifi hotspot \
  ifname "$IFACE" \
  con-name "$CONNECTION_NAME" \
  ssid "$HOTSPOT_SSID" \
  password "$HOTSPOT_PASS"

nmcli connection modify "$CONNECTION_NAME" \
  802-11-wireless.band bg \
  ipv4.method shared \
  connection.autoconnect yes \
  connection.autoconnect-priority 100

echo "Hotspot '$HOTSPOT_SSID' active. Connect to it to configure WiFi."

# --- 3. If first boot, launch captive portal / setup page ---
if [ "$FIRST_BOOT" -eq 1 ]; then
  echo "Waiting for user to submit WiFi credentials via setup page..."
  # Your Next.js app should have /setup route that saves wifi.json
  # Block until wifi.json exists
  while [ ! -f "$WIFI_CONFIG" ]; do
    sleep 5
  done
  echo "WiFi configuration saved."
fi

# --- 4. Attempt to connect to customer WiFi ---
if [ -f "$WIFI_CONFIG" ]; then
  SSID=$(jq -r .ssid "$WIFI_CONFIG")
  PASSWORD=$(jq -r .password "$WIFI_CONFIG")

  echo "Attempting to connect to WiFi: $SSID"
  nmcli device wifi connect "$SSID" password "$PASSWORD" || echo "WiFi connect failed — continuing with hotspot"
fi

# --- 4b. Auto-update if WiFi connected ---
if nmcli -t -f WIFI g | grep -q "enabled"; then
  echo "Checking network connectivity..."
  if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "Network reachable — updating BridgeBox and app..."

    # Update bridge-box repo
    if [ -d "$BOX_DIR/.git" ]; then
      cd "$BOX_DIR"
      git reset --hard
      git clean -fd
      git pull origin main
    fi

    # Update Next.js app repo
    if [ -d "$APP_DIR/.git" ]; then
      cd "$APP_DIR"
      git reset --hard
      git clean -fd
      git pull origin main
      npm install
      npm run build
    fi

    echo "Update complete."
  else
    echo "No internet — skipping update."
  fi
else
  echo "WiFi not connected — skipping update."
fi

# --- 5. Enable IP forwarding & captive portal redirect ---
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf

sudo iptables -t nat -F
sudo iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80 -j REDIRECT --to-port $APP_PORT
sudo iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-port $APP_PORT
sudo netfilter-persistent save

# --- 6. Start Next.js app under PM2 ---
cd "$APP_DIR" || { echo "App directory not found!"; exit 1; }

# Build app if needed
if [ ! -d ".next" ]; then
  npm install
  npm run build
fi

pm2 start npm --name bridge -- start
pm2 save

echo "=== BridgeBox ready ==="
echo "Access scoring UI at http://$HOTSPOT_SSID.local:$APP_PORT"
