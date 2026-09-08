#!/bin/bash
# BridgeBox app launcher — ExecStart for bridge-box-app.service.
#
# Runs the scorer app in the FOREGROUND so systemd supervises it directly (no
# PM2). systemd restarts it if it exits (Restart=always in the unit). Resolves
# the active release, sets APP_COMMIT, and execs the entrypoint:
#   1. node dist/server.js   — compiled build (preferred; no tsx/npm)
#   2. tsx server.ts         — interim, for releases predating the compile
# The allow-server-only.cjs require is included only if that shim exists.
#
# `exec` replaces this shell with the node/tsx process, so systemd's main PID is
# the actual app — clean supervision, correct signal handling for shutdown.

set -euo pipefail

INSTALL_DIR="/home/bridgebox"
CURRENT_LINK="$INSTALL_DIR/bridge-box-scorer/current"

rel="$(readlink -f "$CURRENT_LINK" 2>/dev/null || echo "$CURRENT_LINK")"
if [ ! -d "$rel" ]; then
    echo "app-launch: no current release at $CURRENT_LINK" >&2
    exit 1
fi
cd "$rel" || exit 1

# APP_COMMIT for /healthz + footer: git short hash, else trimmed release dir name.
commit="$(git -C "$rel" rev-parse --short HEAD 2>/dev/null || echo "")"
if [ -z "$commit" ]; then
    commit="$(basename "$rel")"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] && commit="${commit:0:7}"
fi
export APP_COMMIT="$commit"
export NODE_ENV="${NODE_ENV:-production}"

shim_args=()
[ -f "$rel/scripts/allow-server-only.cjs" ] && shim_args=(--require ./scripts/allow-server-only.cjs)

if [ -f "$rel/dist/server.js" ]; then
    echo "app-launch: node dist/server.js (commit $APP_COMMIT)"
    exec node "${shim_args[@]}" dist/server.js
elif [ -x "$rel/node_modules/.bin/tsx" ]; then
    echo "app-launch: tsx server.ts (commit $APP_COMMIT)"
    exec "$rel/node_modules/.bin/tsx" "${shim_args[@]}" server.ts
else
    echo "app-launch: no dist/server.js and no tsx in $rel" >&2
    exit 1
fi
