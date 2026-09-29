#!/bin/bash
# BridgeBox log export / "ship".
#
# Incrementally exports the app's journald logs. Uses a saved journald CURSOR so
# each run only exports entries since the previous successful run (no re-sending
# the whole journal). The cursor is advanced ONLY after a successful export, so a
# failed export is retried next time with no data lost.
#
# SINK: for now the "sink" writes the batch to a timestamped file under a local
# directory. Swapping to an off-box HTTPS POST later is a single-function change
# (see sink_export below) — everything else (cursor handling, batching, config)
# stays the same. Because the file sink is LOCAL, this script needs no network;
# once the sink posts off-box it becomes a job for the boot online window.
#
# Non-fatal throughout. Config is box-local (not in git): /home/bridgebox/log-ship.conf

set -uo pipefail

INSTALL_DIR="/home/bridgebox"
BOX_DIR="$INSTALL_DIR/bridge-box"
STATE_DIR="$INSTALL_DIR/log-ship"
CURSOR_FILE="$STATE_DIR/cursor"
LOG_DIR="$INSTALL_DIR/logs"
LOGFILE="$LOG_DIR/log-ship.log"
CONF="$INSTALL_DIR/log-ship.conf"
CLOUD_LIB="$BOX_DIR/bridge-box-cloud-lib.sh"
mkdir -p "$LOG_DIR"

# --- Defaults (overridable in log-ship.conf) ---
# LOG_UNITS: which systemd unit(s) to export. Default: just the app.
LOG_UNITS="bridge-box-app.service"
# EXPORT_DIR: where the file sink writes exports.
EXPORT_DIR="$STATE_DIR/exports"
# EXPORT_FORMAT: journalctl output format (short-iso is human+greppable; use
# 'json' if a downstream service wants structured lines).
EXPORT_FORMAT="short-iso"
# ENDPOINT / TOKEN: reserved for a bespoke HTTPS sink (unused by the file/S3 sinks).
ENDPOINT=""
TOKEN=""
# EXPORT_KEEP: how many LOCAL export files to retain (prune older).
EXPORT_KEEP=30
# LOG_SHIP_S3: opt-in to ship logs OFF-BOX to S3 (default "no" — local only).
# When "yes" AND the box is cloud-configured AND the entitlement endpoint says
# logs:true, batches are uploaded (write-only) to s3://<bucket>/<box-id>/logs/.
# This is a SEPARATE opt-in from cloud backup, because app logs may contain
# player/game data — enabling it sends that off-box. The S3 bucket/endpoint/
# token themselves come from cloud-backup.conf (via the cloud lib), not here.
LOG_SHIP_S3="no"
# S3_TIMEOUT: bound the upload network call.
S3_TIMEOUT="${S3_TIMEOUT:-120}"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

mkdir -p "$STATE_DIR" "$EXPORT_DIR"

# --- Bounded logging ---
MAX_LOG_BYTES=$((2 * 1024 * 1024))
if [ -f "$LOGFILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt "$MAX_LOG_BYTES" ]; then
        tail -c "$((MAX_LOG_BYTES / 2))" "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null || true
        mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null || true
    fi
fi
exec >> "$LOGFILE" 2>&1

echo "=== BridgeBox log ship $(date -Is) ==="

# ---------------------------------------------------------------------------
# sink_export <batch-file>
#   The ONLY place that decides where logs go. Returns 0 on success (cursor will
#   advance), non-zero on failure (cursor stays; retried next run).
#
#   Two sinks:
#     - S3 (off-box) when LOG_SHIP_S3="yes" AND the box is cloud-configured AND
#       the entitlement endpoint says logs:true. Upload is WRITE-ONLY to
#       s3://<bucket>/<box-id>/logs/<stamp>.log.gz (the vended creds can't read/
#       list/delete). This runs in the boot online window (needs the network).
#     - Local file (default) otherwise: a timestamped file under EXPORT_DIR, no
#       network. A box that isn't opted in / entitled / online still exports
#       locally and loses nothing.
#
#   The two are a fallback chain: if S3 is enabled but the box isn't entitled or
#   the upload fails, we fall back to the local sink so the batch is still
#   captured and the cursor can safely advance (we never silently drop logs).
# ---------------------------------------------------------------------------

# Local file sink. Returns 0 on success.
_sink_local() {
    local batch="$1" stamp out old
    stamp="$(date +%Y%m%d-%H%M%S)"
    out="$EXPORT_DIR/bridge-box-app.${stamp}.log"
    if cp "$batch" "$out"; then
        echo "sink(file): wrote $out ($(wc -l < "$out") lines)"
        old=$(ls -1t "$EXPORT_DIR"/bridge-box-app.*.log 2>/dev/null | tail -n +"$((EXPORT_KEEP + 1))")
        [ -n "$old" ] && echo "$old" | xargs -r rm -f
        return 0
    fi
    echo "sink(file): FAILED to write $out"
    return 1
}

# Off-box S3 sink (gated). Returns 0 on a successful upload, non-zero otherwise
# (caller then falls back to local). Never fatal.
_sink_s3() {
    local batch="$1"
    # LOG_SHIP_S3 off => not an S3 box at all; leave status alone (the local sink
    # is the intended destination, not a fallback), so don't record a "logs" row.
    [ "$LOG_SHIP_S3" = "yes" ] || return 1
    [ -f "$CLOUD_LIB" ] || { echo "sink(s3): cloud lib missing — using local."; return 1; }
    command -v aws >/dev/null 2>&1 || { echo "sink(s3): aws CLI missing — using local."; return 1; }
    # shellcheck source=bridge-box-cloud-lib.sh
    . "$CLOUD_LIB"
    bb_cloud_enabled || { echo "sink(s3): cloud not configured — using local."; bb_cloud_write_status logs skipped_not_configured; return 1; }
    if ! bb_cloud_entitlement logs; then
        echo "sink(s3): not entitled to ship logs — using local."
        if [ "${BB_CLOUD_ENDPOINT_REACHED:-}" = "yes" ]; then
            bb_cloud_write_status logs not_entitled
        else
            bb_cloud_write_status logs offline
        fi
        return 1
    fi
    # Tidy the short-lived creds out of the environment when we return.
    local stamp gz key
    stamp="$(date +%Y%m%d-%H%M%S)"
    gz="$(mktemp /tmp/bridge-logship.XXXXXX).gz"
    if ! gzip -c "$batch" > "$gz" 2>>"$LOGFILE"; then
        echo "sink(s3): compress FAILED — using local."
        rm -f "$gz" 2>/dev/null || true
        bb_cloud_clear_creds
        return 1
    fi
    key="s3://${BB_CLOUD_BUCKET}/${BB_CLOUD_PREFIX%/}/logs/${stamp}.log.gz"
    echo "sink(s3): uploading $(wc -l < "$batch") line(s) -> $key"
    if timeout "$S3_TIMEOUT" aws s3 cp --region "$BB_CLOUD_REGION" "$gz" "$key" >>"$LOGFILE" 2>&1; then
        echo "sink(s3): uploaded OK."
        rm -f "$gz" 2>/dev/null || true
        bb_cloud_write_status logs ok
        bb_cloud_clear_creds
        return 0
    fi
    echo "sink(s3): upload FAILED — using local."
    rm -f "$gz" 2>/dev/null || true
    bb_cloud_write_status logs error
    bb_cloud_clear_creds
    return 1
}

sink_export() {
    local batch="$1"
    # Try the off-box S3 sink first when enabled; fall back to local on any
    # miss (not enabled / not entitled / offline / error) so we never drop logs.
    if _sink_s3 "$batch"; then
        return 0
    fi
    _sink_local "$batch"
}

# --- Build the journalctl command: incremental via cursor if we have one ---
UNIT_ARGS=()
for u in $LOG_UNITS; do UNIT_ARGS+=(-u "$u"); done

SAVED_CURSOR=""
[ -f "$CURSOR_FILE" ] && SAVED_CURSOR="$(cat "$CURSOR_FILE" 2>/dev/null || echo "")"

BATCH="$(mktemp /tmp/bridge-logship.XXXXXX)"
NEWCUR="$(mktemp /tmp/bridge-logcur.XXXXXX)"
cleanup() { rm -f "$BATCH" "$NEWCUR"; }
trap cleanup EXIT

# --show-cursor prints the final cursor as the last line; we capture it to
# advance only on success. If no saved cursor, export from the start of the
# journal's retained history (first run).
if [ -n "$SAVED_CURSOR" ]; then
    journalctl "${UNIT_ARGS[@]}" --after-cursor="$SAVED_CURSOR" \
        -o "$EXPORT_FORMAT" --no-pager --show-cursor > "$BATCH" 2>/dev/null || true
else
    echo "log-ship: no saved cursor — exporting all retained journal history for these units."
    journalctl "${UNIT_ARGS[@]}" -o "$EXPORT_FORMAT" --no-pager --show-cursor > "$BATCH" 2>/dev/null || true
fi

# The last line of --show-cursor output is: "-- cursor: s=...."; split it off.
CURSOR_LINE="$(grep -a '^-- cursor:' "$BATCH" | tail -n1 || true)"
if [ -n "$CURSOR_LINE" ]; then
    printf '%s\n' "${CURSOR_LINE#-- cursor: }" > "$NEWCUR"
    # Remove the cursor marker line(s) from the batch we export.
    grep -av '^-- cursor:' "$BATCH" > "$BATCH.clean" && mv "$BATCH.clean" "$BATCH"
fi

LINES=$(wc -l < "$BATCH" 2>/dev/null || echo 0)
if [ "$LINES" -eq 0 ]; then
    echo "log-ship: no new log entries since last run — nothing to export."
    # Still advance the cursor if journald gave us a newer one (keeps us current).
    [ -s "$NEWCUR" ] && cp "$NEWCUR" "$CURSOR_FILE"
    echo "=== BridgeBox log ship done (nothing new) $(date -Is) ==="
    exit 0
fi

echo "log-ship: exporting $LINES new log line(s)..."
if sink_export "$BATCH"; then
    # Advance the cursor ONLY on a successful export.
    if [ -s "$NEWCUR" ]; then
        cp "$NEWCUR" "$CURSOR_FILE"
        echo "log-ship: cursor advanced."
    fi
    echo "=== BridgeBox log ship done $(date -Is) ==="
else
    echo "log-ship: export failed — cursor NOT advanced (will retry next run)."
    echo "=== BridgeBox log ship failed $(date -Is) ==="
fi
exit 0
