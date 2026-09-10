#!/bin/bash

# install.sh — BridgeBox factory installer (atomic-ready)
set -euo pipefail

echo "=== Bridge Box Installer ==="

# --- CONFIG ---
INSTALL_DIR="/home/bridgebox"
BOX_DIR="$INSTALL_DIR/bridge-box"
RELEASES_DIR="$INSTALL_DIR/bridge-box-scorer/releases"
CURRENT_LINK="$INSTALL_DIR/bridge-box-scorer/current"
PROVISIONED_MARKER="$INSTALL_DIR/.provisioned"

# Clear any previous completion marker: while this run is in progress the box
# is NOT fully provisioned. The marker is re-created only on success. This lets
# a reboot-vs-rerun decision be made reliably (see PROVISIONING.md recovery).
rm -f "$PROVISIONED_MARKER"

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

# Install Node.js from the NodeSource apt repo, pinned to a major line.
# NODE_MAJOR controls which line; a plain `apt upgrade` only moves within this
# major (e.g. 24.x.y). Crossing to a new major is a deliberate step — see
# bridge-box-node-upgrade.sh. Override the default by exporting NODE_MAJOR.
NODE_MAJOR="${NODE_MAJOR:-24}"
echo "Installing Node.js ${NODE_MAJOR}.x (LTS)..."
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
node --version

# NOTE: PM2 is intentionally NOT used. The app runs as a native systemd service
# (bridge-box-app.service) supervised directly by systemd (Restart=always).

# --- 3. Configure sudo scripts ---
sudo mkdir -p /usr/local/bridgebox/bin

# Lets bridgebox restart the app service (used by Phase 3 activation and the
# health check) without broad systemctl rights.
# --no-block: QUEUE the restart and return immediately. The callers
# (bridge-box-online-tasks Phase 3, healthcheck) run in contexts ordered around
# bridge-box-app; a blocking `systemctl restart` there deadlocks (the caller
# waits for a restart job that can't run until the caller finishes). Queuing
# avoids that and is fine — nothing needs to wait for the restart to complete.
sudo tee /usr/local/bridgebox/bin/restart-app.sh > /dev/null <<'EOF'
#!/bin/bash
exec /bin/systemctl restart --no-block bridge-box-app.service
EOF

sudo tee /usr/local/bridgebox/bin/reboot.sh > /dev/null <<'EOF'
#!/bin/bash
exec /sbin/reboot
EOF

# Fixed-path wrapper so the app-user can re-apply NAT redirects after an update
# cycle (#2) without broad iptables privileges. Wraps the repo's nat script.
sudo tee /usr/local/bridgebox/bin/apply-nat.sh > /dev/null <<'EOF'
#!/bin/bash
exec /bin/bash /home/bridgebox/bridge-box/bridge-box-nat.sh
EOF

# Fixed-path wrapper for privileged WiFi control. Lets the boot update service
# AND the scorer app (both running as bridgebox) drive NetworkManager via root,
# without granting bridgebox broad NM rights. The wrapped script validates the
# verb; sudoers below allowlists exactly the permitted verbs.
sudo tee /usr/local/bridgebox/bin/wifi-ctl.sh > /dev/null <<'EOF'
#!/bin/bash
exec /bin/bash /home/bridgebox/bridge-box/bridge-box-wifi-ctl.sh "$@"
EOF

sudo chmod 750 /usr/local/bridgebox/bin/*.sh
sudo chown root:root /usr/local/bridgebox/bin/*.sh

SUDOERS_FILE="/etc/sudoers.d/bridgebox"
# NOTE on arg matching: a bare command path allows ANY args; a path + literal
# args restricts to exactly those. `scan`/`hotspot`/`connect`/`test-cleanup`
# are pinned exactly. `test-connect` takes an SSID/password, so it's allowed
# with a trailing "" (sudo syntax for "any args may follow") — still restricted
# to the test-connect verb of this one script.
sudo bash -c "cat > $SUDOERS_FILE" <<EOF
bridgebox ALL=(ALL) NOPASSWD: /usr/local/bridgebox/bin/restart-app.sh
bridgebox ALL=(ALL) NOPASSWD: /usr/local/bridgebox/bin/reboot.sh
bridgebox ALL=(ALL) NOPASSWD: /usr/local/bridgebox/bin/apply-nat.sh
bridgebox ALL=(ALL) NOPASSWD: /usr/local/bridgebox/bin/wifi-ctl.sh connect
bridgebox ALL=(ALL) NOPASSWD: /usr/local/bridgebox/bin/wifi-ctl.sh hotspot
bridgebox ALL=(ALL) NOPASSWD: /usr/local/bridgebox/bin/wifi-ctl.sh scan
bridgebox ALL=(ALL) NOPASSWD: /usr/local/bridgebox/bin/wifi-ctl.sh test-cleanup
bridgebox ALL=(ALL) NOPASSWD: /usr/local/bridgebox/bin/wifi-ctl.sh test-connect ""
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

# Ensure box scripts are executable before we call one of them.
chmod +x "$BOX_DIR"/*.sh

# Normalise line endings on all scripts first: a CRLF shebang (from a Windows
# checkout) makes direct execution fail with "command not found". Strip any \r
# so the calls below and the systemd services work regardless of checkout OS.
sed -i 's/\r$//' "$BOX_DIR"/*.sh 2>/dev/null || true

# Install the `bridge` admin command into PATH. Symlink to the repo copy so it
# stays current when the repo updates. Admins then run e.g. `bridge status`,
# `bridge os-update`, `bridge help`.
sudo ln -sfn "$BOX_DIR/bridge.sh" /usr/local/bin/bridge
sudo chmod +x "$BOX_DIR/bridge.sh"

# Supply the app's .env (gitignored in the app repo) + create data dirs before
# building the initial release. The prebuild migration and next build need it.
# Invoke via `bash` so this never depends on the exec bit or shebang.
bash "$BOX_DIR/bridge-box-deploy-env.sh" "$INITIAL_RELEASE"

cd "$INITIAL_RELEASE"
npm install
npm run build

ln -sfn "$INITIAL_RELEASE" "$CURRENT_LINK"

# --- 6c. Create backups dir ---
mkdir -p "$INSTALL_DIR/backups"

# --- 7. Install systemd services and timers ---
echo "Installing systemd service files..."
sudo cp "$BOX_DIR/bridge-box-root.service" /etc/systemd/system/
sudo cp "$BOX_DIR/bridge-box-app.service" /etc/systemd/system/
sudo cp "$BOX_DIR/bridge-box-online-tasks.service" /etc/systemd/system/
sudo cp "$BOX_DIR/bridge-box-build.service" /etc/systemd/system/
sudo cp "$BOX_DIR/bridge-box-healthcheck.service" /etc/systemd/system/
sudo cp "$BOX_DIR/bridge-box-healthcheck.timer" /etc/systemd/system/
sudo cp "$BOX_DIR/bridge-box-backup.service" /etc/systemd/system/
sudo cp "$BOX_DIR/bridge-box-backup.timer" /etc/systemd/system/
# player-sync.service is used by the manual `bridge sync-players` path (it wraps
# the sync job in an online window). No player-sync TIMER — sync runs only in
# the boot online window (bridge-box-online-tasks) or manually, never mid-session.
sudo cp "$BOX_DIR/bridge-box-player-sync.service" /etc/systemd/system/
# movement-sync.service mirrors player-sync: manual `bridge sync-movements` path
# (wraps the sync job in an online window). No timer — boot online window or
# manual only, never mid-session.
sudo cp "$BOX_DIR/bridge-box-movement-sync.service" /etc/systemd/system/

# --- 8. Enable and start services ---
# Guard: never enable the app services against a missing or half-built release.
# The 'current' symlink is only created after a successful build in step 6, so
# if it is absent the build did not complete — abort so a reboot can't bring up
# a crash-looping app. Re-running install.sh is the recovery.
if [ ! -e "$CURRENT_LINK" ]; then
  echo "ERROR: $CURRENT_LINK is missing or does not point at a built release."
  echo "The app build (step 6) did not complete. Re-run install.sh."
  exit 1
fi

sudo systemctl daemon-reload
# Boot chain: root -> online-tasks (activate + download + player-sync, one
# online window) -> app -> build. bridge-box-online-tasks and build fire at
# boot via their ordering; player-sync.service has no timer (manual/boot only).
sudo systemctl enable bridge-box-root bridge-box-online-tasks bridge-box-build bridge-box-app
sudo systemctl enable bridge-box-healthcheck.timer bridge-box-backup.timer
sudo systemctl start bridge-box-root
sudo systemctl start bridge-box-online-tasks
sudo systemctl start bridge-box-app          # native systemd app service
# bridge-box-build runs after online-tasks; enabling is enough (it fires at boot).
sudo systemctl start bridge-box-healthcheck.timer
sudo systemctl start bridge-box-backup.timer

# --- 8b. Initialise the EBU player list (soft-deferred) ---
# Try once now so the box ships with a populated players.db. NON-fatal: if
# there's no connectivity the box still provisions fine, and the next boot's
# online window (bridge-box-online-tasks) will populate it. During install the
# box is typically already online (that's how we're fetching everything), so the
# sync job runs directly; if not, it no-ops safely.
echo "Initialising EBU player list (best-effort)..."
sudo chown -R bridgebox:bridgebox "$INSTALL_DIR"   # so the sync writes as bridgebox cleanly
sudo -u bridgebox env HOME="$INSTALL_DIR" \
    bash "$BOX_DIR/bridge-box-player-sync.sh" || \
    echo "Initial player sync did not complete — it will run on the next online boot."

# --- 8c. Initialise the movement list (soft-deferred) ---
# Same best-effort pattern as the player list: try once now so the box ships
# with movements populated. NON-fatal — if there's no connectivity the next
# boot's online window (bridge-box-online-tasks) will populate it.
echo "Initialising movement list (best-effort)..."
sudo -u bridgebox env HOME="$INSTALL_DIR" \
    bash "$BOX_DIR/bridge-box-movement-sync.sh" || \
    echo "Initial movement sync did not complete — it will run on the next online boot."

# --- 9. Fix permissions ---
sudo chown -R bridgebox:bridgebox "$INSTALL_DIR"

# --- 10. Mark provisioning complete ---
# Written only after every step above succeeded. If this file is absent, the
# box was not fully provisioned and install.sh should be re-run before relying
# on a reboot.
date -Is > "$PROVISIONED_MARKER"

echo "=== Installation complete ==="
echo "Please reboot to finalize setup."