#!/bin/bash
# Weekly volume backup — run via cron
# Backs up app storage directories, 30-day retention

set -euo pipefail

BACKUP_DIR="/opt/backups/volumes"
SOURCE_DIR="/opt/volumes/apps"
RETENTION_DAYS=30
DATE=$(date +%Y-%m-%d_%H%M)

mkdir -p "$BACKUP_DIR"

if [ -d "$SOURCE_DIR" ]; then
  FILENAME="${BACKUP_DIR}/app-storage_${DATE}.tar.gz"
  tar -czf "$FILENAME" -C "$SOURCE_DIR" .
  echo "[$(date)] Backed up app storage -> $FILENAME"
fi

# Clean old backups
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +${RETENTION_DAYS} -delete
echo "[$(date)] Cleaned backups older than ${RETENTION_DAYS} days"
