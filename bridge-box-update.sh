#!/bin/bash
# BridgeBox app-update DOWNLOAD job (radio-agnostic).
#
# This is Phase 1 of the update model, as a "job" run INSIDE the online window
# opened by bridge-box-online-tasks.sh (via bb_run_online_window). It ASSUMES
# the box is already online — it does NOT touch the radio, the lock, or traps
# (the online-window orchestrator owns all of that).
#
# It downloads any newer release, deploys .env, and runs `npm ci` WHILE ONLINE
# (a new release may change deps; the offline Phase-2 build has no network), then
# flags the release .needs_build. It never starts the app (that's the app
# service) and never activates a release (that's Phase 3, a local step in the
# orchestrator). Non-fatal throughout.

set -uo pipefail

INSTALL_DIR="/home/bridgebox"
SCORER_DIR="$INSTALL_DIR/bridge-box-scorer"
CURRENT_LINK="$SCORER_DIR/current"
PREVIOUS_LINK="$SCORER_DIR/previous"
RELEASES_DIR="$SCORER_DIR/releases"
REPO_URL="https://github.com/rhindonltd/bridge-box-scorer.git"
LOGFILE="$INSTALL_DIR/update.log"

RELEASE_REF="main"
[ -f "$INSTALL_DIR/release.conf" ] && . "$INSTALL_DIR/release.conf"

CLONE_TIMEOUT=120
NPM_INSTALL_TIMEOUT=600   # `npm ci` on a Pi can take several minutes

# --- Bounded logging ---
MAX_LOG_BYTES=$((5 * 1024 * 1024))
if [ -f "$LOGFILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt "$MAX_LOG_BYTES" ]; then
        tail -c "$((MAX_LOG_BYTES / 2))" "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null || true
        mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null || true
    fi
fi
exec >> "$LOGFILE" 2>&1

echo "=== BridgeBox update download job $(date -Is) ==="

# Assumes online (caller/orchestrator ensured it). Bail cheaply if not.
if ! timeout 15 ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "update: not online — skipping download."
    exit 0
fi

mkdir -p "$RELEASES_DIR"
# Record the running release as 'previous' the first time, for rollback.
[ -L "$CURRENT_LINK" ] && [ ! -L "$PREVIOUS_LINK" ] && \
    ln -sfn "$(readlink -f "$CURRENT_LINK")" "$PREVIOUS_LINK"

# Resolve target commit (branch or tag).
REMOTE_COMMIT=$(timeout 30 git ls-remote "$REPO_URL" \
    "refs/heads/$RELEASE_REF" "refs/tags/$RELEASE_REF" | head -n1 | cut -f1)
if [ -z "$REMOTE_COMMIT" ]; then
    echo "update: could not resolve '$RELEASE_REF' on remote — skipping."
    exit 0
fi

echo "update: target ref $RELEASE_REF -> $REMOTE_COMMIT"
# Compare against the NEWEST DOWNLOADED release (dir named by commit), not just
# 'current', so a release downloaded but not yet activated isn't re-fetched.
if [ -d "$RELEASES_DIR/$REMOTE_COMMIT" ]; then
    echo "update: release $REMOTE_COMMIT already downloaded — nothing to fetch."
    exit 0
fi

echo "update: downloading release $REMOTE_COMMIT..."
NEW_RELEASE="$RELEASES_DIR/$REMOTE_COMMIT"
[[ "$NEW_RELEASE" == "$RELEASES_DIR/"* ]] || { echo "update: unsafe path"; exit 0; }
rm -rf "$NEW_RELEASE"
if ! timeout "$CLONE_TIMEOUT" git clone "$REPO_URL" "$NEW_RELEASE"; then
    echo "update: clone failed — discarding."; rm -rf "$NEW_RELEASE"; exit 0
fi
if ! git -C "$NEW_RELEASE" checkout -q "$REMOTE_COMMIT"; then
    echo "update: checkout failed — discarding."; rm -rf "$NEW_RELEASE"; exit 0
fi

# Supply .env + create data dirs before installing.
if ! bash "$INSTALL_DIR/bridge-box/bridge-box-deploy-env.sh" "$NEW_RELEASE"; then
    echo "update: deploy-env failed — discarding."; rm -rf "$NEW_RELEASE"; exit 0
fi

# Install dependencies WHILE ONLINE (Phase 2's build has no network). Only after
# deps are present do we flag the release for the background build.
echo "update: installing dependencies (npm ci) while online..."
INSTALL_CMD="npm install"
[ -f "$NEW_RELEASE/package-lock.json" ] && INSTALL_CMD="npm ci"
if ! ( cd "$NEW_RELEASE" && timeout "$NPM_INSTALL_TIMEOUT" $INSTALL_CMD ); then
    echo "update: dependency install failed — discarding release."; rm -rf "$NEW_RELEASE"; exit 0
fi

: > "$NEW_RELEASE/.needs_build"
echo "update: downloaded + installed deps for $REMOTE_COMMIT; flagged for background build."
exit 0
