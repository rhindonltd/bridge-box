#!/bin/bash

# install.sh — BridgeBox factory installer (atomic-ready)
set -euo pipefail

echo "=== Bridge Box Installer ==="

# --- CONFIG ---
INSTALL_DIR="/home/bridgebox"
BOX_DIR="$INSTALL_DIR/bridge-box"
RELEASES_DIR="$INSTALL_DIR/bridge-box-scorer/releases"
CURRENT_LINK="$INSTALL_DIR/bridge-box-scorer/current"

REPO_BOX="https://github.com/rhindonltd/bridge-box.git"
REPO_APP="https://github.com/rhindonltd/bridge-box-scorer.git"

# --- 1. Ensure running as bridgebox user ---
if [ "$USER" != "bridgebox" ]; then
  echo "Please run as bridgebox user"
  exit 1
fi

# --- 2. Install system dependencies ---
echo "Installing system dependencies..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update

# Pre-answer iptables-persistent prompts
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git curl avahi-daemon iptables iptables-persistent jq sqlite3

# Install Node.js 22 LTS
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

# Install PM2 globally if not installed
if ! command -v pm2 &> /dev/null; then
  echo "Installing PM2..."
  sudo npm install -g pm2
fi

# --- 3. Configure sudo scripts ---
sudo mkdir -p /usr/local/bridgebox/bin

sudo tee /usr/local/bridgebox/bin/restart-service.sh > /dev/null <<'EOF'
#!/bin/bash
exec /bin/systemctl restart bridge-box-update.service
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

sudo chmod 440 $SUDOERS_FILE
sudo visudo -cf $SUDOERS_FILE

# --- 4. Enable Avahi ---
sudo systemctl enable avahi-daemon
sudo systemctl restart avahi-daemon

# --- 5. Clone bridge-box repo ---
echo "Cloning bridge-box repository..."
rm -rf "$BOX_DIR"
git clone "$REPO_BOX" "$BOX_DIR"

# --- 6. Setup atomic app structure ---
echo "Setting up application..."
mkdir -p "$RELEASES_DIR"
INITIAL_RELEASE="$RELEASES_DIR/app_initial"
rm -rf "$INITIAL_RELEASE"
git clone "$REPO_APP" "$INITIAL_RELEASE"

cd "$INITIAL_RELEASE"
npm install
npm run build

ln -sfn "$INITIAL_RELEASE" "$CURRENT_LINK"

# --- 7. Install systemd services ---
echo "Installing systemd service files..."
sudo cp "$BOX_DIR/bridge-box-root.service" /etc/systemd/system/
sudo cp "$BOX_DIR/bridge-box-update.service" /etc/systemd/system/

# --- 8. Enable and start services ---
sudo systemctl daemon-reload
sudo systemctl enable bridge-box-root bridge-box-update
sudo systemctl start bridge-box-root
sudo systemctl start bridge-box-update

# --- 9. Fix permissions ---
sudo chown -R bridgebox:bridgebox "$INSTALL_DIR"

echo "=== Installation complete ==="
echo "Please reboot to finalize setup."