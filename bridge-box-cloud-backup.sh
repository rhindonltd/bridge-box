#!/bin/bash
# BridgeBox CLOUD backup upload JOB (radio-agnostic; assumes already online).
#
# Uploads the box's data to S3 under its own prefix (s3://<bucket>/<box-id>/) as
# CONTENT-ADDRESSED per-DB objects plus a manifest that defines the current
# coherent set. This is the OFF-BOX, opt-in, entitlement-gated counterpart to the
# local-only bridge-box-backup.sh.
#
# Why per-DB objects + a manifest (rather than one big tarball each run):
#   - A box accumulates many per-game DBs under data/games/ over a season; only
#     the ACTIVE game typically changes between switch-ons. Uploading a whole-
#     data/ tarball every time re-sends every historical game for no reason.
#   - So we hash each DB's consistent .backup copy and upload ONLY the ones whose
#     content changed. Objects are content-addressed (keyed by their sha256), so
#     identical content is a no-op even without the local cache, and objects are
#     immutable (an interrupted run can never corrupt an existing object).
#   - A manifest.json (written LAST, after all objects are up) lists the full
#     current set — so restore still gets ONE atomic, self-consistent snapshot
#     to work from, exactly like the old single-tarball did. A timestamped copy
#     under manifests/ keeps history for pruning / point-in-time.
#
# S3 layout per box:
#   objects/<rel-path>.<sha256>.sqlite.gz   # immutable, content-addressed
#   manifest.json                            # the current set (restore reads this)
#   manifests/<stamp>.json                   # history
#
# Mirrors bridge-box-log-ship.sh: all "does it go off-box / where" logic lives in
# the shared cloud lib (bb_cloud_entitlement), everything here is plumbing.
#
# Invariants (see .kiro/steering):
#   - OPT-IN / OFF BY DEFAULT: no cloud-backup.conf => exit 0, local backups
#     untouched (privacy default preserved).
#   - Entitlement-gated: the vendor endpoint can turn this box off remotely; a
#     "backup:false" or unreachable endpoint => exit 0.
#   - NON-FATAL throughout: any failure logs and exits 0 so the boot flow / a
#     manual run never wedges. The hotspot (separate radio) is never touched.
#   - Every network step is `timeout`-wrapped.
#   - NO long-lived AWS keys: short-lived STS creds come from the lib per run.

set -uo pipefail

INSTALL_DIR="/home/bridgebox"
BOX_DIR="$INSTALL_DIR/bridge-box"
DATA_DIR="$INSTALL_DIR/data"
LOG_DIR="$INSTALL_DIR/logs"
LOGFILE="$LOG_DIR/cloud-backup.log"
CLOUD_LIB="$BOX_DIR/bridge-box-cloud-lib.sh"
# Local cache of the sha256 we last uploaded per relative DB path — lets us skip
# the upload attempt entirely for unchanged DBs. Purely an optimisation: even if
# this is stale/missing, content-addressed keys mean re-uploading identical
# content just overwrites an identical object.
STATE_FILE="$DATA_DIR/.cloud-state"
mkdir -p "$LOG_DIR"

# Timeouts (seconds) for the S3 network operations.
S3_TIMEOUT="${S3_TIMEOUT:-300}"

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

echo "=== BridgeBox cloud backup $(date -Is) ==="

# --- Feature gate: configured? ---
if [ ! -f "$CLOUD_LIB" ]; then
    echo "cloud-backup: cloud lib missing — skipping."
    exit 0
fi
# shellcheck source=bridge-box-cloud-lib.sh
. "$CLOUD_LIB"

if ! bb_cloud_enabled; then
    echo "cloud-backup: not configured (no/incomplete cloud-backup.conf) — skipping. Local backups are unaffected."
    exit 0
fi

# --- Tooling ---
if ! command -v aws >/dev/null 2>&1; then
    echo "cloud-backup: AWS CLI not installed — cannot upload. Skipping."
    exit 0
fi

# --- Entitlement + short-lived creds ---
if ! bb_cloud_entitlement backup; then
    echo "cloud-backup: not entitled / endpoint unavailable — skipping (exit 0)."
    exit 0
fi
# Tidy exported creds out of the environment on the way out, whatever happens.
trap 'bb_cloud_clear_creds' EXIT

# --- Preconditions ---
if [ ! -d "$DATA_DIR" ]; then
    echo "cloud-backup: no data dir ($DATA_DIR) — nothing to upload. Skipping."
    exit 0
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "cloud-backup: sqlite3 not available — cannot take a consistent snapshot. Skipping."
    exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "cloud-backup: jq not available — cannot build the manifest. Skipping."
    exit 0
fi
# Pick a sha256 tool (Debian has sha256sum; be tolerant on other hosts).
if command -v sha256sum >/dev/null 2>&1; then
    _sha256() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
    _sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
    echo "cloud-backup: no sha256 tool (sha256sum/shasum) — cannot content-address. Skipping."
    exit 0
fi

mapfile -t DBS < <(find "$DATA_DIR" -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \) 2>/dev/null)
if [ "${#DBS[@]}" -eq 0 ]; then
    echo "cloud-backup: no SQLite databases under $DATA_DIR — nothing to upload. Skipping."
    exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
S3_BASE="s3://${BB_CLOUD_BUCKET}/${BB_CLOUD_PREFIX%/}"

# --- Workspace ---
WORK="$(mktemp -d /tmp/bridge-cloud.XXXXXX)"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
# Guarded cleanup: only ever remove our own mktemp workspace.
# shellcheck disable=SC2329  # invoked indirectly via `trap cleanup EXIT` below.
cleanup() {
    case "$WORK" in
        /tmp/bridge-cloud.*) rm -rf "$WORK" 2>/dev/null || true ;;
    esac
    bb_cloud_clear_creds
}
trap cleanup EXIT

# Load the local hash cache ("<rel>\t<sha256>" per line) into an assoc array.
declare -A LAST_HASH=()
if [ -f "$STATE_FILE" ]; then
    while IFS=$'\t' read -r _rel _hash; do
        [ -n "$_rel" ] && LAST_HASH["$_rel"]="$_hash"
    done < "$STATE_FILE"
fi

# We build the manifest entries as we go, and a fresh state cache to write back.
MANIFEST_ENTRIES="$WORK/entries.jsonl"   # one JSON object per line
NEW_STATE="$WORK/state.new"
: > "$MANIFEST_ENTRIES"
: > "$NEW_STATE"

echo "cloud-backup: examining ${#DBS[@]} database(s) under $DATA_DIR ..."
uploaded=0
skipped=0
for DB in "${DBS[@]}"; do
    REL="${DB#"$DATA_DIR"/}"          # e.g. players.db  OR  games/g1.sqlite
    STAGED="$STAGE/$REL"
    mkdir -p "$(dirname "$STAGED")"

    # Consistent online (hot) copy — safe against the live app.
    if ! sqlite3 "$DB" ".backup '$STAGED'" 2>>"$LOGFILE"; then
        echo "cloud-backup: snapshot FAILED for $REL — aborting run (data left intact)."
        exit 0
    fi
    # Verify the staged copy before it can be uploaded or referenced.
    CHECK=$(sqlite3 "$STAGED" 'PRAGMA integrity_check;' 2>>"$LOGFILE" || echo "error")
    if [ "$CHECK" != "ok" ]; then
        echo "cloud-backup: integrity check FAILED for $REL (result: $CHECK) — aborting run."
        exit 0
    fi

    # Content hash of the exact bytes we'd store (the .backup copy).
    HASH="$(_sha256 "$STAGED")"
    if [ -z "$HASH" ]; then
        echo "cloud-backup: could not hash $REL — aborting run."
        exit 0
    fi

    OBJ_KEY="objects/${REL}.${HASH}.sqlite.gz"
    # Record a manifest entry for this DB (whether or not we re-upload it —
    # the manifest always describes the FULL current set).
    jq -n --arg path "$REL" --arg sha "$HASH" --arg object "$OBJ_KEY" \
        '{path:$path, sha256:$sha, object:$object}' >> "$MANIFEST_ENTRIES"
    printf '%s\t%s\n' "$REL" "$HASH" >> "$NEW_STATE"

    # Skip the upload if our cache says this exact content is already up.
    if [ "${LAST_HASH[$REL]:-}" = "$HASH" ]; then
        skipped=$((skipped + 1))
        continue
    fi

    # Compress + upload the object. Content-addressed key => uploading identical
    # content is harmless (overwrites an identical object). Objects are never
    # mutated in place, so a partial upload can't corrupt an existing snapshot.
    GZ="$STAGED.gz"
    if ! gzip -c "$STAGED" > "$GZ" 2>>"$LOGFILE"; then
        echo "cloud-backup: compress FAILED for $REL — aborting run."
        exit 0
    fi
    echo "cloud-backup: uploading changed DB $REL -> $OBJ_KEY"
    if ! timeout "$S3_TIMEOUT" aws s3 cp --region "$BB_CLOUD_REGION" \
            "$GZ" "$S3_BASE/$OBJ_KEY" >>"$LOGFILE" 2>&1; then
        echo "cloud-backup: upload FAILED for $REL — aborting run (nothing partially committed; no manifest written)."
        exit 0
    fi
    uploaded=$((uploaded + 1))
done
echo "cloud-backup: $uploaded object(s) uploaded, $skipped unchanged."

# --- Build + upload the manifest LAST (so it only ever references live objects) ---
MANIFEST="$WORK/manifest.json"
if ! jq -s --arg box "$BOX_ID" --arg created "$(date -Is)" \
        '{box_id:$box, created:$created, entries:.}' \
        "$MANIFEST_ENTRIES" > "$MANIFEST" 2>>"$LOGFILE"; then
    echo "cloud-backup: FAILED to build manifest — aborting (objects are up but manifest not advanced)."
    exit 0
fi

MANIFEST_HISTORY_KEY="manifests/${STAMP}.json"
MANIFEST_CURRENT_KEY="manifest.json"

# Upload the timestamped history copy first, then the current pointer. If the
# current-pointer write fails we still have the history copy, and the old
# manifest.json remains valid — restore is never left pointing at nothing.
echo "cloud-backup: writing manifest -> $MANIFEST_HISTORY_KEY"
if ! timeout "$S3_TIMEOUT" aws s3 cp --region "$BB_CLOUD_REGION" \
        "$MANIFEST" "$S3_BASE/$MANIFEST_HISTORY_KEY" >>"$LOGFILE" 2>&1; then
    echo "cloud-backup: manifest upload FAILED — aborting (previous manifest still valid)."
    exit 0
fi
echo "cloud-backup: updating current manifest -> $MANIFEST_CURRENT_KEY"
if ! timeout "$S3_TIMEOUT" aws s3 cp --region "$BB_CLOUD_REGION" \
        "$S3_BASE/$MANIFEST_HISTORY_KEY" "$S3_BASE/$MANIFEST_CURRENT_KEY" >>"$LOGFILE" 2>&1; then
    echo "cloud-backup: WARNING could not update current manifest (history copy is up; restore still uses the previous set)."
    exit 0
fi

# Only now that the manifest is committed do we advance the local hash cache.
mv "$NEW_STATE" "$STATE_FILE" 2>/dev/null || cp "$NEW_STATE" "$STATE_FILE" 2>/dev/null || true
echo "cloud-backup: manifest committed for BOX_ID=$BOX_ID (set of ${#DBS[@]} DB(s))."

# --- Retention: keep the newest $SNAPSHOT_KEEP manifests; GC unreferenced objects ---
KEEP="${SNAPSHOT_KEEP:-30}"
# History manifests, oldest first.
mapfile -t HIST < <(timeout "$S3_TIMEOUT" aws s3 ls --region "$BB_CLOUD_REGION" \
    "$S3_BASE/manifests/" 2>/dev/null | awk '{print $NF}' \
    | grep -E '^[0-9]{8}-[0-9]{6}\.json$' | sort)

if [ "${#HIST[@]}" -gt "$KEEP" ]; then
    PRUNE=$(( ${#HIST[@]} - KEEP ))
    echo "cloud-backup: ${#HIST[@]} manifests, keeping $KEEP — pruning $PRUNE oldest."
    for ((i = 0; i < PRUNE; i++)); do
        old="${HIST[$i]}"
        [ -n "$old" ] || continue
        timeout "$S3_TIMEOUT" aws s3 rm --region "$BB_CLOUD_REGION" \
            "$S3_BASE/manifests/$old" >>"$LOGFILE" 2>&1 \
            && echo "cloud-backup: pruned old manifest $old" \
            || echo "cloud-backup: WARNING failed to prune manifest $old (continuing)."
    done
fi

# Garbage-collect objects no longer referenced by ANY retained manifest. Build
# the set of still-referenced object keys from the retained manifests, then
# delete objects/ keys not in that set. Best-effort: a GC failure never fails the
# run (worst case is orphaned objects, which are harmless and retried next time).
gc_objects() {
    local kept_manifests=() ref="$WORK/referenced.txt" have="$WORK/have.txt"
    : > "$ref"; : > "$have"
    # Retained manifests = newest $KEEP history entries + the current manifest.
    mapfile -t all_hist < <(timeout "$S3_TIMEOUT" aws s3 ls --region "$BB_CLOUD_REGION" \
        "$S3_BASE/manifests/" 2>/dev/null | awk '{print $NF}' \
        | grep -E '^[0-9]{8}-[0-9]{6}\.json$' | sort)
    local start=0
    [ "${#all_hist[@]}" -gt "$KEEP" ] && start=$(( ${#all_hist[@]} - KEEP ))
    for ((i = start; i < ${#all_hist[@]}; i++)); do kept_manifests+=("manifests/${all_hist[$i]}"); done
    kept_manifests+=("manifest.json")

    local m tmp="$WORK/m.json"
    for m in "${kept_manifests[@]}"; do
        if timeout "$S3_TIMEOUT" aws s3 cp --region "$BB_CLOUD_REGION" \
                "$S3_BASE/$m" "$tmp" >>"$LOGFILE" 2>&1; then
            jq -r '.entries[].object' "$tmp" 2>/dev/null >> "$ref" || true
        fi
    done
    sort -u "$ref" -o "$ref"

    # All object keys currently in S3.
    timeout "$S3_TIMEOUT" aws s3 ls --region "$BB_CLOUD_REGION" \
        "$S3_BASE/objects/" --recursive 2>/dev/null \
        | awk '{print $NF}' | sed -n 's#.*/\(objects/.*\)#\1#p' > "$have" || true
    # Fallback: some `aws s3 ls --recursive` outputs the full key already.
    if [ ! -s "$have" ]; then
        timeout "$S3_TIMEOUT" aws s3 ls --region "$BB_CLOUD_REGION" \
            "$S3_BASE/objects/" --recursive 2>/dev/null | awk '{print $NF}' \
            | grep '^objects/' > "$have" || true
    fi

    local key
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        if ! grep -qxF "$key" "$ref"; then
            timeout "$S3_TIMEOUT" aws s3 rm --region "$BB_CLOUD_REGION" \
                "$S3_BASE/$key" >>"$LOGFILE" 2>&1 \
                && echo "cloud-backup: GC removed unreferenced object $key" \
                || echo "cloud-backup: WARNING GC failed to remove $key (continuing)."
        fi
    done < "$have"
}
gc_objects || echo "cloud-backup: object GC hit an error (harmless — orphans retried next run)."

echo "=== BridgeBox cloud backup done $(date -Is) ==="
exit 0
