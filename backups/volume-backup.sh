#!/bin/bash
# Weekly volume backup — run via cron
# Backs up each app's storage directory individually, 30-day retention

set -euo pipefail

BACKUP_DIR="/opt/backups/volumes"
SOURCE_DIR="/opt/volumes/apps"
RETENTION_DAYS=30
DATE=$(date +%Y-%m-%d_%H%M)
HAS_ERROR=0

mkdir -p "$BACKUP_DIR"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "[$(date)] ERROR: Source dir $SOURCE_DIR not found" >&2
  exit 1
fi

APPS=$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)

if [ -z "$APPS" ]; then
  echo "[$(date)] ERROR: No app directories found in $SOURCE_DIR" >&2
  exit 1
fi

for APP in $APPS; do
  FILENAME="${BACKUP_DIR}/${APP}_${DATE}.tar.gz"

  if ! tar -czf "$FILENAME" -C "$SOURCE_DIR" "$APP"; then
    echo "[$(date)] ERROR: tar failed for $APP" >&2
    rm -f "$FILENAME"
    HAS_ERROR=1
    continue
  fi

  if [ ! -s "$FILENAME" ] || ! gzip -t "$FILENAME" 2>/dev/null; then
    echo "[$(date)] ERROR: Archive for $APP is empty or corrupt" >&2
    rm -f "$FILENAME"
    HAS_ERROR=1
  else
    echo "[$(date)] Backed up $APP -> $FILENAME"
  fi
done

# Clean old backups
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +${RETENTION_DAYS} -delete
echo "[$(date)] Cleaned backups older than ${RETENTION_DAYS} days"

exit $HAS_ERROR
