#!/bin/bash
# BridgeBox Phase 2 — background build of a downloaded release (bridgebox user).
#
# Runs after bridge-box-online-tasks.service on each boot. Finds a release that was
# downloaded but not yet built (marked with .needs_build by Phase 1), and builds
# it with LOW priority so a live game is not disturbed. On success it marks the
# release .built and points 'pending' at it, so the NEXT boot (Phase 3 in
# bridge-box-online-tasks.sh) activates it. On failure it discards the release.
#
# There is NO network activity here — everything was downloaded in Phase 1.
#
# Power-cut safety: we only ever create a NEW release dir's artifacts and flip
# the 'pending' pointer at the very end. The running app (via 'current') is
# never touched. If the plug is pulled mid-build, the half-built dir still has
# .needs_build (no .built, no pending), so the next boot's build run retries it.

set -uo pipefail

INSTALL_DIR="/home/bridgebox"
SCORER_DIR="$INSTALL_DIR/bridge-box-scorer"
RELEASES_DIR="$SCORER_DIR/releases"
PENDING_LINK="$SCORER_DIR/pending"
CURRENT_LINK="$SCORER_DIR/current"
LOGFILE="$INSTALL_DIR/build.log"
LOCKFILE="$INSTALL_DIR/.update.lock"

# Deps are installed online in Phase 1; this phase only builds (offline).
NPM_BUILD_TIMEOUT=900

# Bounded logging.
MAX_LOG_BYTES=$((5 * 1024 * 1024))
if [ -f "$LOGFILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt "$MAX_LOG_BYTES" ]; then
        tail -c "$((MAX_LOG_BYTES / 2))" "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null || true
        mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null || true
    fi
fi
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== BridgeBox background build $(date -Is) ==="

# Serialize with the update run (shares .update.lock). Wait a little, since the
# update service may still be finishing when we start.
exec 9>"$LOCKFILE"
if ! flock -w 60 9; then
    echo "Could not get lock (update in progress) — will retry next boot."
    exit 0
fi

if [ ! -d "$RELEASES_DIR" ]; then
    echo "No releases dir — nothing to build."
    exit 0
fi

# Find the newest release still awaiting a build.
TO_BUILD=""
while read -r d; do
    [ -f "$RELEASES_DIR/$d/.needs_build" ] && { TO_BUILD="$RELEASES_DIR/$d"; break; }
done < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -nr | awk '{print $2}')

if [ -z "$TO_BUILD" ]; then
    echo "No release needs building."
    exit 0
fi

echo "Building release: $TO_BUILD (low priority)"

# Dependencies + .env are handled ONLINE in Phase 1 (the download job), so
# this phase has no network. If node_modules is missing, Phase 1's npm ci didn't
# complete — don't try to install here (no network); leave .needs_build set so
# Phase 1 retries the download+install next boot, and skip.
if [ ! -d "$TO_BUILD/node_modules" ]; then
    echo "node_modules missing (deps not installed in Phase 1) — discarding this release so Phase 1 re-downloads+installs next boot."
    # Only remove if genuinely under releases/ and not the active release.
    if [[ "$TO_BUILD" == "$RELEASES_DIR/"* ]] && \
       [ "$(readlink -f "$TO_BUILD")" != "$(readlink -f "$CURRENT_LINK" 2>/dev/null)" ]; then
        rm -rf "$TO_BUILD"
    fi
    exit 0
fi

# Low CPU/IO priority so a game in progress stays responsive.
NICE="nice -n 19"
command -v ionice >/dev/null 2>&1 && NICE="ionice -c3 $NICE"

build_one() {
    cd "$TO_BUILD" || return 1
    echo "Building (npm run build, no network)..."
    timeout "$NPM_BUILD_TIMEOUT" $NICE npm run build || return 1
}

if build_one; then
    : > "$TO_BUILD/.built"
    rm -f "$TO_BUILD/.needs_build"
    ln -sfn "$TO_BUILD" "$PENDING_LINK"
    echo "Build OK. Marked pending -> $TO_BUILD (activates next boot)."
else
    echo "Build FAILED — discarding $TO_BUILD."
    # Only remove if it's genuinely under releases/ and not the active release.
    if [[ "$TO_BUILD" == "$RELEASES_DIR/"* ]] && \
       [ "$(readlink -f "$TO_BUILD")" != "$(readlink -f "$CURRENT_LINK" 2>/dev/null)" ]; then
        rm -rf "$TO_BUILD"
    fi
fi

echo "=== Background build done $(date -Is) ==="
