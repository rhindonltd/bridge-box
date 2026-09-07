#!/bin/bash
# BridgeBox app update + PM2 (bridgebox user)

set -euo pipefail

# --- CONFIG ---
IFACE="wlan0"
INSTALL_DIR="/home/bridgebox"
SCORER_DIR="$INSTALL_DIR/bridge-box-scorer"
CURRENT_LINK="$SCORER_DIR/current"
PREVIOUS_LINK="$SCORER_DIR/previous"
RELEASES_DIR="$SCORER_DIR/releases"
WIFI_CONFIG="$INSTALL_DIR/wifi.json"
REPO_URL="https://github.com/rhindonltd/bridge-box-scorer.git"
HOTSPOT_CONNECTION="bridge-hotspot"
LOCKFILE="$INSTALL_DIR/.update.lock"

# Which git ref to deploy. Override in $INSTALL_DIR/release.conf to pin the
# device to a specific tag/branch for reproducible deployments (#12).
# Example release.conf:  RELEASE_REF="v1.4.0"
RELEASE_REF="main"
[ -f "$INSTALL_DIR/release.conf" ] && . "$INSTALL_DIR/release.conf"

LOGFILE="$INSTALL_DIR/update.log"

# Bounded waits / timeouts (seconds)
WIFI_WAIT_MAX=300        # how long to wait for wifi.json before giving up
NMCLI_TIMEOUT=60         # per nmcli network operation
NPM_INSTALL_TIMEOUT=600  # npm install
NPM_BUILD_TIMEOUT=600    # npm run build
KEEP_RELEASES=3          # how many old releases to retain

# --- Bounded logging: truncate log if it grows too large (~5 MB) ---
MAX_LOG_BYTES=$((5 * 1024 * 1024))
if [ -f "$LOGFILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt "$MAX_LOG_BYTES" ]; then
        tail -c "$((MAX_LOG_BYTES / 2))" "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null || true
        mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null || true
    fi
fi
exec > >(tee -a "$LOGFILE") 2>&1

# --- Single-instance lock (#1) ---
# Prevent a second run (e.g. a manual `systemctl restart bridge-box-update`)
# from racing an in-progress update while it is switching wlan0 between hotspot
# and client mode. The health-check timer also refuses to act while we hold this.
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "Another bridge-box-update run is in progress — exiting."
    exit 0
fi

echo "=== BridgeBox app startup $(date -Is) ==="

# --- Always return to hotspot mode, no matter how we exit ---
return_to_hotspot() {
    echo "Returning to hotspot mode..."
    nmcli device disconnect "$IFACE" 2>/dev/null || true
    if ! nmcli connection up "$HOTSPOT_CONNECTION" 2>/dev/null; then
        echo "WARNING: failed to bring hotspot '$HOTSPOT_CONNECTION' up."
    fi
    # Re-assert the port redirects (#2): switching wlan0 to client mode and back
    # can leave NetworkManager's rebuilt routing without our 80/443->app rules.
    if ! sudo -n /usr/local/bridgebox/bin/apply-nat.sh 2>/dev/null; then
        echo "WARNING: could not re-apply NAT redirects (guests may not reach the app on 80/443)."
    fi
    echo "=== BridgeBox ready (hotspot restored) ==="
}
trap return_to_hotspot EXIT

# --- Resolve the running release's commit and expose it to the app ---
# The app reads APP_COMMIT to surface the running version via /healthz and the
# UI footer. Prefer the git HEAD of the current release; fall back to the
# release directory name (which is the commit for updated releases).
resolve_commit() {
    local c
    c=$(git -C "$CURRENT_LINK" rev-parse --short HEAD 2>/dev/null || echo "")
    if [ -z "$c" ]; then
        # Fall back to the release dir name. For updated releases this is the
        # full commit hash — trim to 7 chars so APP_COMMIT format is consistent
        # with the git short hash (#10). For the initial release it is the
        # literal 'app_initial' label until the first update (#11).
        c=$(basename "$(readlink -f "$CURRENT_LINK" 2>/dev/null || echo unknown)")
        if [[ "$c" =~ ^[0-9a-f]{40}$ ]]; then
            c="${c:0:7}"
        fi
    fi
    echo "$c"
}
export APP_COMMIT="$(resolve_commit)"
echo "Running release commit: $APP_COMMIT"

# --- 1. START APP IMMEDIATELY (offline-first, must not depend on network) ---
# Use --cwd (not npm --prefix) so the app's working directory is the release
# dir; --prefix only changes npm's package resolution, not process.cwd() (#3).
# Running from the 'current' symlink means a later `pm2 reload` picks up an
# atomic release swap. Note: PM2 boot resurrection (pm2 startup) is
# intentionally NOT configured — this systemd service is the single start path
# on every boot; adding pm2 startup would create a competing one (#4).
echo "Starting app (hotspot mode)..."
pm2 delete bridge 2>/dev/null || true
APP_COMMIT="$APP_COMMIT" pm2 start npm --name bridge --cwd "$CURRENT_LINK" -- start
pm2 save
echo "App started."

# --- 2. WAIT FOR WIFI CONFIG (bounded) ---
WAITED=0
while [ ! -f "$WIFI_CONFIG" ]; do
    if [ "$WAITED" -ge "$WIFI_WAIT_MAX" ]; then
        echo "No WiFi config after ${WIFI_WAIT_MAX}s — staying in hotspot mode."
        exit 0
    fi
    echo "Waiting for WiFi configuration... (${WAITED}s/${WIFI_WAIT_MAX}s)"
    sleep 5
    WAITED=$((WAITED + 5))
done

echo "WiFi config found."

# Tighten permissions (#9): wifi.json holds the club WiFi password in plaintext.
chmod 600 "$WIFI_CONFIG" 2>/dev/null || true

# --- 2a. Validate wifi.json before using it ---
if ! jq empty "$WIFI_CONFIG" 2>/dev/null; then
    echo "wifi.json is not valid JSON — staying in hotspot mode."
    exit 0
fi

SSID=$(jq -r '.ssid // empty' "$WIFI_CONFIG")
PASSWORD=$(jq -r '.password // empty' "$WIFI_CONFIG")
HIDDEN=$(jq -r '.hidden // "no"' "$WIFI_CONFIG")

if [ -z "$SSID" ] || [ -z "$PASSWORD" ]; then
    echo "wifi.json missing ssid or password — staying in hotspot mode."
    exit 0
fi

echo "Connecting to WiFi: $SSID"

# --- 3. CONNECT TO WIFI (with timeouts) ---
connect_wifi() {
    local hidden="$1"
    timeout "$NMCLI_TIMEOUT" nmcli connection delete "$SSID" 2>/dev/null || true
    if [ "$hidden" = "yes" ]; then
        timeout "$NMCLI_TIMEOUT" nmcli device wifi connect "$SSID" password "$PASSWORD" hidden yes
    else
        timeout "$NMCLI_TIMEOUT" nmcli device wifi connect "$SSID" password "$PASSWORD"
    fi
}

# Prefer the mode the user configured; fall back to the other.
if [ "$HIDDEN" = "yes" ]; then
    connect_wifi "yes" && echo "WiFi connected (hidden SSID)." || {
        echo "Hidden connect failed, trying visible..."
        connect_wifi "no" && echo "WiFi connected (visible SSID)." || {
            echo "WiFi connection failed. Check SSID and password."
            exit 0
        }
    }
else
    connect_wifi "no" && echo "WiFi connected (visible SSID)." || {
        echo "Visible connect failed, trying hidden..."
        connect_wifi "yes" && echo "WiFi connected (hidden SSID)." || {
            echo "WiFi connection failed. Check SSID and password."
            exit 0
        }
    }
fi

# --- 4. CHECK INTERNET AND UPDATE APP ---
if ! timeout 15 ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "No internet — skipping update."
    exit 0
fi

echo "Internet available"
echo "Checking for bridge-scorer updates..."

mkdir -p "$RELEASES_DIR"

# Ensure the currently-running release is recorded as 'previous' so first-ever
# update can still roll back to a known-good version.
if [ -L "$CURRENT_LINK" ] && [ ! -L "$PREVIOUS_LINK" ]; then
    CUR_TARGET=$(readlink -f "$CURRENT_LINK")
    ln -sfn "$CUR_TARGET" "$PREVIOUS_LINK"
    echo "Recorded initial release as previous: $CUR_TARGET"
fi

# Resolve the target ref (#12). RELEASE_REF may be a branch or a tag; try both.
LOCAL_COMMIT=$(git -C "$CURRENT_LINK" rev-parse HEAD 2>/dev/null || echo "none")
REMOTE_COMMIT=$(timeout "$NMCLI_TIMEOUT" git ls-remote "$REPO_URL" \
    "refs/heads/$RELEASE_REF" "refs/tags/$RELEASE_REF" | head -n1 | cut -f1)

echo "Target ref: $RELEASE_REF"
echo "Local:  $LOCAL_COMMIT"
echo "Remote: $REMOTE_COMMIT"

if [ -z "$REMOTE_COMMIT" ]; then
    echo "Could not resolve '$RELEASE_REF' on remote — skipping update."
    exit 0
fi

if [ "$LOCAL_COMMIT" = "$REMOTE_COMMIT" ]; then
    echo "Already up to date."
    exit 0
fi

echo "Updating to $REMOTE_COMMIT..."

NEW_RELEASE="$RELEASES_DIR/$REMOTE_COMMIT"
[[ "$NEW_RELEASE" == "$RELEASES_DIR/"* ]] || { echo "Unsafe delete path"; exit 1; }

rm -rf "$NEW_RELEASE"
if ! timeout "$NMCLI_TIMEOUT" git clone "$REPO_URL" "$NEW_RELEASE"; then
    echo "Clone failed — aborting update."
    rm -rf "$NEW_RELEASE"
    exit 0
fi

# Check out the exact pinned commit so a branch moving mid-clone can't drift.
if ! git -C "$NEW_RELEASE" checkout -q "$REMOTE_COMMIT"; then
    echo "Could not check out $REMOTE_COMMIT — aborting update."
    rm -rf "$NEW_RELEASE"
    exit 0
fi

cd "$NEW_RELEASE"

echo "Installing dependencies..."
if [ -f package-lock.json ]; then
    INSTALL_CMD="npm ci"
else
    INSTALL_CMD="npm install"
fi
if ! timeout "$NPM_INSTALL_TIMEOUT" $INSTALL_CMD; then
    echo "Dependency install failed — aborting update."
    rm -rf "$NEW_RELEASE"
    exit 0
fi

echo "Building app..."
if ! timeout "$NPM_BUILD_TIMEOUT" npm run build; then
    echo "Build failed — aborting update"
    rm -rf "$NEW_RELEASE"
    exit 0
fi

echo "Build successful."

# --- Save current as previous ---
if [ -L "$CURRENT_LINK" ]; then
    PREV_TARGET=$(readlink -f "$CURRENT_LINK")
    ln -sfn "$PREV_TARGET" "$PREVIOUS_LINK"
    echo "Saved previous release: $PREV_TARGET"
fi

# --- Switch symlink ---
ln -sfn "$NEW_RELEASE" "$CURRENT_LINK"
echo "Switched to new release."

# --- Zero-downtime reload ---
# Refresh APP_COMMIT to the newly deployed release so /healthz and the footer
# reflect the running version. --update-env makes PM2 pick up the new value.
export APP_COMMIT="$(resolve_commit)"
echo "Reloading app (zero downtime) at commit $APP_COMMIT..."
APP_COMMIT="$APP_COMMIT" pm2 reload bridge --update-env || {
    echo "Reload failed — rolling back..."
    if [ -L "$PREVIOUS_LINK" ]; then
        PREV=$(readlink -f "$PREVIOUS_LINK")
        ln -sfn "$PREV" "$CURRENT_LINK"
        export APP_COMMIT="$(resolve_commit)"
        APP_COMMIT="$APP_COMMIT" pm2 reload bridge --update-env || pm2 restart bridge --update-env || true
        echo "Rollback complete (commit $APP_COMMIT)."
    else
        echo "No previous version available!"
    fi
}

echo "Cleaning old releases..."
cd "$RELEASES_DIR" || exit 0
mapfile -t RELEASES < <(find . -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | awk '{print $2}')
COUNT=0
for REL in "${RELEASES[@]}"; do
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -le "$KEEP_RELEASES" ]; then
        continue
    fi
    FULL_PATH="$(realpath "$REL")"
    CURRENT_TARGET=$(readlink -f "$CURRENT_LINK" 2>/dev/null || echo "")
    PREVIOUS_TARGET=$(readlink -f "$PREVIOUS_LINK" 2>/dev/null || echo "")
    if [ "$FULL_PATH" = "$CURRENT_TARGET" ] || [ "$FULL_PATH" = "$PREVIOUS_TARGET" ]; then
        echo "Skipping active release: $FULL_PATH"
        continue
    fi
    [[ "$FULL_PATH" == "$RELEASES_DIR/"* ]] || { echo "Unsafe delete path, skipping: $FULL_PATH"; continue; }
    echo "Deleting old release: $FULL_PATH"
    rm -rf "$FULL_PATH"
done

echo "Update complete."
# trap will return the device to hotspot mode on exit.
