#!/bin/bash
# BridgeBox data backup — safe online snapshots of the SQLite database.
# Uses SQLite's .backup so it is safe to run against a live database.
# Runs periodically via bridge-box-backup.timer.

set -uo pipefail

DATA_DIR="/home/bridgebox/data"
# Prefer a mounted USB stick if present, else keep backups on disk.
USB_DIR="/media/bridgebox"
DISK_BACKUP_DIR="/home/bridgebox/backups"
LOGFILE="/home/bridgebox/backup.log"
KEEP=14   # how many backups to retain per database

# Bounded logging.
MAX_LOG_BYTES=$((2 * 1024 * 1024))
if [ -f "$LOGFILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt "$MAX_LOG_BYTES" ]; then
        tail -c "$((MAX_LOG_BYTES / 2))" "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null || true
        mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null || true
    fi
fi
log() { echo "$(date -Is) $*" >> "$LOGFILE"; }

# Pick a backup destination: first writable USB mount under $USB_DIR, else disk.
choose_dest() {
    if [ -d "$USB_DIR" ]; then
        for m in "$USB_DIR"/*; do
            if [ -d "$m" ] && [ -w "$m" ]; then
                echo "$m/bridge-box-backups"
                return 0
            fi
        done
    fi
    echo "$DISK_BACKUP_DIR"
}

if [ ! -d "$DATA_DIR" ]; then
    log "Data dir $DATA_DIR not found — nothing to back up."
    exit 0
fi

# Find all SQLite databases under the data dir (recursively).
# The app uses multiple databases: a game-index DB, a separate DB per game,
# a player DB and a settings DB — and per-game DBs are created dynamically,
# so we discover them each run rather than hard-coding names.
mapfile -t DBS < <(find "$DATA_DIR" -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \) 2>/dev/null)

if [ "${#DBS[@]}" -eq 0 ]; then
    log "No SQLite databases found under $DATA_DIR."
    exit 0
fi

DEST="$(choose_dest)"
mkdir -p "$DEST" || { log "Cannot create backup dir $DEST"; exit 0; }

STAMP="$(date +%Y%m%d-%H%M%S)"

for DB in "${DBS[@]}"; do
    # Preserve relative path in the backup name so per-game DBs in subdirs
    # don't collide (e.g. games/2026-01-01-game1.sqlite -> games_2026-01-01-game1.sqlite).
    REL="${DB#"$DATA_DIR"/}"
    NAME="${REL//\//_}"
    OUT="$DEST/${NAME}.${STAMP}.bak"
    # .backup is a safe online (hot) backup for a live database.
    if sqlite3 "$DB" ".backup '$OUT'" 2>>"$LOGFILE"; then
        log "Backed up $DB -> $OUT"
    else
        log "Backup FAILED for $DB"
        rm -f "$OUT" 2>/dev/null || true
        continue
    fi

    # Retention: keep the newest $KEEP backups for this db.
    mapfile -t OLD < <(ls -1t "$DEST/${NAME}."*.bak 2>/dev/null | tail -n +"$((KEEP + 1))")
    for f in "${OLD[@]}"; do
        rm -f "$f" 2>/dev/null && log "Pruned old backup $f"
    done
done

sync
log "Backup run complete (dest: $DEST)."
