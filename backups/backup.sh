#!/bin/bash
# Daily MySQL backup — run via cron
# Dumps each database individually, gzipped, 14-day retention

set -euo pipefail

# Source credentials (needed when running via cron)
source /opt/infrastructure/.env

BACKUP_DIR="/opt/backups/mysql"
RETENTION_DAYS=7
DATE=$(date +%Y-%m-%d_%H%M)
HAS_ERROR=0

mkdir -p "$BACKUP_DIR"

# Write temporary defaults file inside the container (avoids password in process list)
docker exec mysql sh -c "printf '[client]\nuser=root\npassword=%s\n' '${MYSQL_ROOT_PASSWORD}' > /tmp/.backup.cnf && chmod 600 /tmp/.backup.cnf"
trap 'docker exec mysql rm -f /tmp/.backup.cnf' EXIT

# Verify MySQL is reachable
if ! docker exec mysql mysqladmin --defaults-extra-file=/tmp/.backup.cnf ping --silent > /dev/null 2>&1; then
  echo "[$(date)] ERROR: MySQL is not running or unreachable" >&2
  exit 1
fi

# Get list of databases (exclude system DBs)
DATABASES=$(docker exec mysql mysql --defaults-extra-file=/tmp/.backup.cnf -N -e \
  "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');")

if [ -z "$DATABASES" ]; then
  echo "[$(date)] ERROR: No databases found to back up" >&2
  exit 1
fi

for DB in $DATABASES; do
  FILENAME="${BACKUP_DIR}/${DB}_${DATE}.sql.gz"
  ERROR_LOG=$(mktemp)

  if ! docker exec mysql mysqldump --defaults-extra-file=/tmp/.backup.cnf --single-transaction "$DB" 2>"$ERROR_LOG" | gzip > "$FILENAME"; then
    echo "[$(date)] ERROR: mysqldump failed for $DB: $(cat "$ERROR_LOG")" >&2
    rm -f "$FILENAME" "$ERROR_LOG"
    HAS_ERROR=1
    continue
  fi

  # Verify backup integrity
  if [ ! -s "$FILENAME" ] || ! gzip -t "$FILENAME" 2>/dev/null; then
    echo "[$(date)] ERROR: Backup for $DB is empty or corrupt" >&2
    ERRORS=$(cat "$ERROR_LOG")
    [ -n "$ERRORS" ] && echo "[$(date)] mysqldump stderr: $ERRORS" >&2
    rm -f "$FILENAME"
    HAS_ERROR=1
  else
    echo "[$(date)] Backed up $DB -> $FILENAME"
  fi

  rm -f "$ERROR_LOG"
done

# Clean old backups
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +${RETENTION_DAYS} -delete
echo "[$(date)] Cleaned backups older than ${RETENTION_DAYS} days"

exit $HAS_ERROR
