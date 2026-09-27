#!/bin/bash
# BridgeBox CLOUD restore JOB (radio-agnostic; assumes already online).
#
# Downloads this box's current S3 manifest (s3://<bucket>/<box-id>/manifest.json),
# then downloads each per-DB object it references, and lays the SQLite databases
# back into data/. This is the box-swap path: a fresh/replacement box provisioned
# with the SAME BOX_ID pulls the previous box's games + players and comes up on
# them. The manifest defines ONE coherent set, so restore is atomic even though
# the objects are stored/uploaded individually (content-addressed).
#
# SAFETY (this script WRITES app data, so it is deliberately conservative):
#   - Entitlement-gated: only proceeds if the vendor endpoint says this box may
#     RESTORE (restore:true). Not entitled / unreachable => exit 0, no writes.
#   - NON-DESTRUCTIVE BY DEFAULT: refuses to overwrite a POPULATED data/ unless
#     --force is passed. On a fresh box data/ is empty, so the common
#     provision-time path just works; an operator must opt in to clobber a box
#     that already has games.
#   - VERIFIED BEFORE COMMIT: every downloaded object's sha256 is checked against
#     the manifest AND the DB is PRAGMA integrity_check'd in a staging dir first;
#     a corrupt/partial/mismatched set is rejected and data/ is left untouched.
#   - Every network step is `timeout`-wrapped; the hotspot (separate radio) is
#     never touched.
#
# Usage: bridge-box-cloud-restore.sh [--force]
# Exit codes: 0 = restored OR cleanly skipped (not configured/entitled/nothing
#             to do); 1 = refused because data/ is populated and no --force, or a
#             downloaded snapshot failed verification (operator should look).

set -uo pipefail

INSTALL_DIR="/home/bridgebox"
BOX_DIR="$INSTALL_DIR/bridge-box"
DATA_DIR="$INSTALL_DIR/data"
LOG_DIR="$INSTALL_DIR/logs"
LOGFILE="$LOG_DIR/cloud-restore.log"
CLOUD_LIB="$BOX_DIR/bridge-box-cloud-lib.sh"
mkdir -p "$LOG_DIR"

S3_TIMEOUT="${S3_TIMEOUT:-300}"

FORCE="no"
for arg in "$@"; do
    case "$arg" in
        --force) FORCE="yes" ;;
        "") ;;  # tolerate an empty passthrough arg from the CLI wrapper
        *) echo "cloud-restore: ignoring unknown arg '$arg'" ;;
    esac
done

# --- Bounded logging (truncate-on-start guard) ---
MAX_LOG_BYTES=$((2 * 1024 * 1024))
if [ -f "$LOGFILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt "$MAX_LOG_BYTES" ]; then
        tail -c "$((MAX_LOG_BYTES / 2))" "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null || true
        mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null || true
    fi
fi
exec >> "$LOGFILE" 2>&1

echo "=== BridgeBox cloud restore $(date -Is) (force=$FORCE) ==="

# --- Feature gate ---
if [ ! -f "$CLOUD_LIB" ]; then
    echo "cloud-restore: cloud lib missing — skipping."
    exit 0
fi
# shellcheck source=bridge-box-cloud-lib.sh
. "$CLOUD_LIB"

if ! bb_cloud_enabled; then
    echo "cloud-restore: not configured (no/incomplete cloud-backup.conf) — skipping."
    exit 0
fi

if ! command -v aws >/dev/null 2>&1; then
    echo "cloud-restore: AWS CLI not installed — cannot download. Skipping."
    exit 0
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "cloud-restore: sqlite3 not available — cannot verify restored DBs. Skipping."
    exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "cloud-restore: jq not available — cannot read the manifest. Skipping."
    exit 0
fi
if command -v sha256sum >/dev/null 2>&1; then
    _sha256() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
    _sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
    echo "cloud-restore: no sha256 tool (sha256sum/shasum) — cannot verify objects. Skipping."
    exit 0
fi

# --- Overwrite guard: is data/ already populated? ---
# "Populated" = at least one SQLite DB present under data/. On a fresh box this
# is empty and we proceed; otherwise require --force so we never silently clobber
# a box that already has games/players.
data_populated() {
    [ -d "$DATA_DIR" ] || return 1
    local found
    found=$(find "$DATA_DIR" -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \) 2>/dev/null | head -n1)
    [ -n "$found" ]
}

if data_populated && [ "$FORCE" != "yes" ]; then
    echo "cloud-restore: data/ already contains databases and --force was NOT given."
    echo "cloud-restore: REFUSING to overwrite existing data. Re-run with --force to replace it."
    exit 1
fi

# --- Entitlement + short-lived creds ---
if ! bb_cloud_entitlement restore; then
    echo "cloud-restore: not entitled to restore / endpoint unavailable — skipping (exit 0)."
    exit 0
fi
trap 'bb_cloud_clear_creds' EXIT

S3_BASE="s3://${BB_CLOUD_BUCKET}/${BB_CLOUD_PREFIX%/}"
MANIFEST_KEY="$S3_BASE/manifest.json"

# --- Download + stage in a temp workspace ---
WORK="$(mktemp -d /tmp/bridge-restore.XXXXXX)"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
# shellcheck disable=SC2329  # invoked indirectly via `trap cleanup EXIT` below.
cleanup() {
    case "$WORK" in
        /tmp/bridge-restore.*) rm -rf "$WORK" 2>/dev/null || true ;;
    esac
    bb_cloud_clear_creds
}
trap cleanup EXIT

MANIFEST="$WORK/manifest.json"
echo "cloud-restore: downloading $MANIFEST_KEY ..."
if ! timeout "$S3_TIMEOUT" aws s3 cp --region "$BB_CLOUD_REGION" \
        "$MANIFEST_KEY" "$MANIFEST" >>"$LOGFILE" 2>&1; then
    echo "cloud-restore: no manifest found for BOX_ID=$BOX_ID (or download failed) — nothing to restore."
    # Nothing to restore is not an error for a brand-new club with no prior box.
    exit 0
fi

if ! jq empty "$MANIFEST" >/dev/null 2>&1; then
    echo "cloud-restore: manifest is not valid JSON — ABORTING, data/ left untouched."
    exit 1
fi

# entries[] = { path, sha256, object }. Count first.
N_ENTRIES=$(jq '.entries | length' "$MANIFEST" 2>/dev/null || echo 0)
if [ "${N_ENTRIES:-0}" -eq 0 ]; then
    echo "cloud-restore: manifest lists no databases — nothing to restore."
    exit 0
fi
echo "cloud-restore: manifest lists $N_ENTRIES database(s); downloading + verifying each before committing ..."

# --- Download each object, verify sha256 vs manifest, then integrity_check ---
# All staging happens under $STAGE/data/<rel-path>; we only touch the live data/
# once EVERY object has been fetched, hash-matched, and integrity-checked.
STAGED_DATA="$STAGE/data"
mkdir -p "$STAGED_DATA"

# Read the manifest into parallel arrays (tab-separated, safe for our paths).
mapfile -t ENTRIES < <(jq -r '.entries[] | [.path, .sha256, .object] | @tsv' "$MANIFEST")
for line in "${ENTRIES[@]}"; do
    IFS=$'\t' read -r REL WANT_SHA OBJ <<< "$line"
    if [ -z "$REL" ] || [ -z "$WANT_SHA" ] || [ -z "$OBJ" ]; then
        echo "cloud-restore: malformed manifest entry — ABORTING, data/ left untouched."
        exit 1
    fi

    GZ="$WORK/dl.gz"
    if ! timeout "$S3_TIMEOUT" aws s3 cp --region "$BB_CLOUD_REGION" \
            "$S3_BASE/$OBJ" "$GZ" >>"$LOGFILE" 2>&1; then
        echo "cloud-restore: FAILED to download object for $REL ($OBJ) — ABORTING, data/ left untouched."
        exit 1
    fi

    STAGED="$STAGED_DATA/$REL"
    mkdir -p "$(dirname "$STAGED")"
    if ! gunzip -c "$GZ" > "$STAGED" 2>>"$LOGFILE"; then
        echo "cloud-restore: FAILED to decompress object for $REL — ABORTING, data/ left untouched."
        exit 1
    fi
    rm -f "$GZ" 2>/dev/null || true

    GOT_SHA="$(_sha256 "$STAGED")"
    if [ "$GOT_SHA" != "$WANT_SHA" ]; then
        echo "cloud-restore: sha256 MISMATCH for $REL (manifest $WANT_SHA, got $GOT_SHA) — ABORTING, data/ left untouched."
        exit 1
    fi

    CHECK=$(sqlite3 "$STAGED" 'PRAGMA integrity_check;' 2>>"$LOGFILE" || echo "error")
    if [ "$CHECK" != "ok" ]; then
        echo "cloud-restore: integrity check FAILED for $REL (result: $CHECK) — ABORTING, data/ left untouched."
        exit 1
    fi
    echo "cloud-restore: verified $REL (sha256 + integrity ok)."
done
echo "cloud-restore: all $N_ENTRIES database(s) downloaded and verified."

# --- Commit: lay the DBs into data/, preserving the relative structure ---
mapfile -t STAGED_ALL < <(find "$STAGED_DATA" -type f 2>/dev/null)
mkdir -p "$DATA_DIR" "$DATA_DIR/games"
for db in "${STAGED_ALL[@]}"; do
    rel="${db#"$STAGED_DATA"/}"
    target="$DATA_DIR/$rel"
    mkdir -p "$(dirname "$target")"
    cp -f "$db" "$target"
    echo "cloud-restore: restored $rel"
done

sync
echo "cloud-restore: restore complete for BOX_ID=$BOX_ID ($N_ENTRIES database(s))."
echo "=== BridgeBox cloud restore done $(date -Is) ==="
exit 0
