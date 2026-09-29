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
# Box-local locale, written by install.sh. Controls NEXT_PUBLIC_BRIDGE_LOCALE,
# which Next.js bakes into the client bundle at BUILD time — so it must be in
# the .env before every build (initial install AND Phase 2 rebuilds), not just
# the runtime service env. Default matches the app's default.
LOCALE_CONF="$INSTALL_DIR/locale.conf"
DEFAULT_LOCALE="en-GB"
VALID_LOCALES=("en-GB" "en-US")

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

# Inject the locale (NEXT_PUBLIC_BRIDGE_LOCALE). Read the box-local locale.conf
# if present, else fall back to the default. Validate against the known list and
# fall back to the default on anything unexpected (never fail the build over it).
BRIDGE_LOCALE="$DEFAULT_LOCALE"
if [ -f "$LOCALE_CONF" ]; then
    # shellcheck disable=SC1090
    . "$LOCALE_CONF"
    BRIDGE_LOCALE="${BRIDGE_LOCALE:-$DEFAULT_LOCALE}"
fi

_valid=""
for l in "${VALID_LOCALES[@]}"; do
    [ "$BRIDGE_LOCALE" = "$l" ] && _valid=1 && break
done
if [ -z "$_valid" ]; then
    echo "deploy-env: WARNING invalid locale '$BRIDGE_LOCALE' — falling back to $DEFAULT_LOCALE" >&2
    BRIDGE_LOCALE="$DEFAULT_LOCALE"
fi

# Overwrite any NEXT_PUBLIC_BRIDGE_LOCALE that came from the source file, then
# append the effective value so it's authoritative and appears exactly once.
sed -i '/^NEXT_PUBLIC_BRIDGE_LOCALE=/d' "$RELEASE_DIR/.env"
echo "NEXT_PUBLIC_BRIDGE_LOCALE=$BRIDGE_LOCALE" >> "$RELEASE_DIR/.env"
echo "deploy-env: set NEXT_PUBLIC_BRIDGE_LOCALE=$BRIDGE_LOCALE"

# Ensure the data dirs the app expects exist (absolute paths in the .env).
mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/data/games"
