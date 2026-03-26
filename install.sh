#!/bin/bash

# install.sh — BridgeBox factory installer (atomic-ready)

set -euo pipefail

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

RELEASES_DIR="$INSTALL_DIR/bridge-box-scorer/releases"
CURRENT_LINK="$INSTALL_DIR/bridge-box-scorer/current"

# --- 1. Ensure running as bridgebox user ---
if [ "$USER" != "bridgebox" ]; then
  echo "Please run as bridgebox user"
  exit 1
fi

# --- 2. Install system dependencies ---
echo "Installing system dependencies..."

sudo DEBIAN_FRONTEND=noninteractive apt-get update

# Pre-answer iptables-persistent
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git curl avahi-daemon iptables iptables-persistent jq

# Install Node.js 22 LTS
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

echo "Configuring sudo permissions..."

sudo mkdir -p /usr/local/bridgebox/bin

sudo tee /usr/local/bridgebox/bin/restart-service.sh > /dev/null <<'EOF'
#!/bin/bash
exec /bin/systemctl restart bridge-box
EOF

sudo tee /usr/local/bridgebox/bin/reboot.sh > /dev/null <<'EOF'
#!/bin/bash
exec /sbin/reboot
EOF

sudo chmod 750 /usr/local/bridgebox/bin/*.sh
sudo chown root:root /usr/local/bridgebox/bin/*.sh

SUDOERS_FILE="/etc/sudoers.d/bridgebox"

sudo bash -c "cat > $SUDOERS_FILE" <<EOF
bridgebox ALL=(ALL) NOPASSWD: /usr/local/bridgebox/bin/restart-service.sh
bridgebox ALL=(ALL) NOPASSWD: /usr/local/bridgebox/bin/reboot.sh
EOF

# Set correct permissions (VERY IMPORTANT)
sudo chmod 440 $SUDOERS_FILE

# Validate sudoers file (fails install if broken)
sudo visudo -cf $SUDOERS_FILE

echo "Sudo permissions configured."

# --- 3. Enable Avahi ---
sudo systemctl enable avahi-daemon
sudo systemctl restart avahi-daemon

# --- 4. Clone bridge-box scripts ---
echo "Cloning bridge-box..."

rm -rf "$BOX_DIR"
git clone "$REPO_BOX" "$BOX_DIR"
chmod +x "$BOX_DIR/startup.sh"

# --- 5. Setup atomic app structure ---
echo "Setting up application..."

mkdir -p "$RELEASES_DIR"

INITIAL_RELEASE="$RELEASES_DIR/app_initial"
rm -rf "$INITIAL_RELEASE"

git clone "$REPO_APP" "$INITIAL_RELEASE"

cd "$INITIAL_RELEASE"

echo "Installing app dependencies..."
npm install

echo "Building app..."
npm run build

# Create symlink to current
ln -sfn "$INITIAL_RELEASE" "$CURRENT_LINK"

# --- 6. Install PM2 ---
if ! command -v pm2 &> /dev/null
then
  echo "Installing PM2..."
  sudo npm install -g pm2
fi

# --- 7. Create hotspot ---
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

# --- 8. Configure iptables ---
echo "Configuring iptables..."

sudo sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
  echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf

sudo iptables -t nat -F
sudo iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80 -j REDIRECT --to-port $APP_PORT
sudo iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-port $APP_PORT

sudo netfilter-persistent save

# --- 9. Install systemd service ---
echo "Installing startup service..."

sudo cp "$BOX_DIR/bridge-box.service" /etc/systemd/system/

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable bridge-box.service

# --- 10. Fix permissions ---
sudo chown -R bridgebox:bridgebox "$INSTALL_DIR"

# --- 11. Done ---
echo "=== Installation complete ==="
echo "WiFi SSID: $HOTSPOT_SSID"
echo "Password: $HOTSPOT_PASS"
echo "Rebooting..."

sudo reboot
