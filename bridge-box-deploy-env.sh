#!/bin/bash
# Deploy the scorer .env into a release dir before it is built.
#
# The scorer app's .env is gitignored in its own repo but needed at build time,
# and each release is a fresh clone — so provisioning supplies it here. Uses a
# box-local override if present, else the repo template. Single source of truth
# for both install.sh (initial release) and bridge-box-build.sh (Phase 2).
#
# Usage: bridge-box-deploy-env.sh <release-dir>

set -euo pipefail

RELEASE_DIR="${1:?usage: bridge-box-deploy-env.sh <release-dir>}"
INSTALL_DIR="/home/bridgebox"
BOX_LOCAL="$INSTALL_DIR/scorer.env"
TEMPLATE="$INSTALL_DIR/bridge-box/scorer.env.template"

if [ ! -d "$RELEASE_DIR" ]; then
    echo "deploy-env: release dir '$RELEASE_DIR' does not exist" >&2
    exit 1
fi

if [ -f "$BOX_LOCAL" ]; then
    cp "$BOX_LOCAL" "$RELEASE_DIR/.env"
    echo "deploy-env: used box-local $BOX_LOCAL"
elif [ -f "$TEMPLATE" ]; then
    cp "$TEMPLATE" "$RELEASE_DIR/.env"
    echo "deploy-env: used template $TEMPLATE"
else
    echo "deploy-env: WARNING no scorer.env source found — build may fail without .env" >&2
    exit 1
fi

# Ensure the data dirs the app expects exist (absolute paths in the .env).
mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/data/games"
