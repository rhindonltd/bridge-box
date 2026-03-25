```bash
#!/bin/bash
# install.sh — One-command installer for Bridge Box

set -e

echo "=== Bridge Box Installer ==="

# --- CONFIG ---
IFACE="wlan0"

MAC=$(cat /sys/class/net/$IFACE/address | tr -d ':' | tail -c 5 | tr '[:lower:]' '[:upper:]')
HOTSPOT_SSID="BridgeBox-$MAC"
HOTSPOT_PASS="bridgebox"

CONNECTION_NAME="bridge-hotspot"

APP_PORT=3000
HOSTNAME="bridge"

REPO_BOX="https://github.com/rhindonltd/bridge-box.git"
REPO_APP="https://github.com/rhindonltd/bridge-box-scorer.git"

INSTALL_DIR="/home/bridgebox"
BOX_DIR="$INSTALL_DIR/bridge-box"
APP_DIR="$INSTALL_DIR/bridge-box-scorer"

# --- 1. Ensure running as bridgebox user ---
if [ "$USER" != "bridgebox" ]; then
  echo "Please run as bridgebox user"
  exit 1
fi

# --- 2. Install system dependencies ---
echo "Installing system dependencies..."

sudo DEBIAN_FRONTEND=noninteractive apt-get update

echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git curl avahi-daemon iptables iptables-persistent

# Install modern Node.js
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# --- 3. Enable Avahi ---
sudo systemctl enable avahi-daemon
sudo systemctl restart avahi-daemon

# --- 4. Clone repos ---
echo "Cloning repositories..."

rm -rf "$BOX_DIR"
rm -rf "$APP_DIR"

git clone "$REPO_BOX" "$BOX_DIR"
git clone "$REPO_APP" "$APP_DIR"

# --- 5. Install PM2 ---
if ! command -v pm2 &> /dev/null
then
    echo "Installing PM2..."
    sudo npm install -g pm2
fi

# --- 6. Create hotspot ---
echo "Creating hotspot configuration..."

nmcli connection delete "$CONNECTION_NAME" 2>/dev/null || true

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

# --- 7. Configure iptables ---
echo "Configuring iptables..."

sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf

sudo iptables -t nat -F
sudo iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80 -j REDIRECT --to-port $APP_PORT
sudo iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-port $APP_PORT

sudo netfilter-persistent save

# --- 8. Install systemd service ---
echo "Installing startup service..."

sudo cp "$BOX_DIR/bridge-box.service" /etc/systemd/system/

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable bridge-box.service

# --- 9. Fix permissions ---
sudo chown -R bridgebox:bridgebox "$BOX_DIR"
sudo chown -R bridgebox:bridgebox "$APP_DIR"

# --- 10. Done ---
echo "=== Installation complete ==="
echo "WiFi SSID: $HOTSPOT_SSID"
echo "Password: $HOTSPOT_PASS"
echo "Rebooting..."

sudo reboot
```
