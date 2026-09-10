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
STATE_DIR="$INSTALL_DIR/log-ship"
CURSOR_FILE="$STATE_DIR/cursor"
LOGFILE="$INSTALL_DIR/log-ship.log"
CONF="$INSTALL_DIR/log-ship.conf"

# --- Defaults (overridable in log-ship.conf) ---
# LOG_UNITS: which systemd unit(s) to export. Default: just the app.
LOG_UNITS="bridge-box-app.service"
# EXPORT_DIR: where the file sink writes exports.
EXPORT_DIR="$STATE_DIR/exports"
# EXPORT_FORMAT: journalctl output format (short-iso is human+greppable; use
# 'json' if a downstream service wants structured lines).
EXPORT_FORMAT="short-iso"
# ENDPOINT / TOKEN: reserved for the future HTTPS sink (unused by the file sink).
ENDPOINT=""
TOKEN=""
# EXPORT_KEEP: how many export files to retain (prune older).
EXPORT_KEEP=30
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
#   NOW: file sink — move the batch to a timestamped export file locally.
#   LATER: replace the body with an HTTPS POST, e.g.
#     curl -fsS --max-time 30 -H "Authorization: Bearer $TOKEN" \
#          --data-binary @"$1" "$ENDPOINT"
#   (and, once it posts off-box, run this from the boot online window instead of
#   manually, since it then needs the network.)
# ---------------------------------------------------------------------------
sink_export() {
    local batch="$1"
    local stamp out
    stamp="$(date +%Y%m%d-%H%M%S)"
    out="$EXPORT_DIR/bridge-box-app.${stamp}.log"
    if cp "$batch" "$out"; then
        echo "sink(file): wrote $out ($(wc -l < "$out") lines)"
        # Retention: keep the newest $EXPORT_KEEP exports.
        local old
        old=$(ls -1t "$EXPORT_DIR"/bridge-box-app.*.log 2>/dev/null | tail -n +"$((EXPORT_KEEP + 1))")
        [ -n "$old" ] && echo "$old" | xargs -r rm -f
        return 0
    fi
    echo "sink(file): FAILED to write $out"
    return 1
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
