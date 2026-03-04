#!/bin/bash
# Daily MySQL backup — run via cron
# Dumps each database individually, gzipped, 14-day retention

set -euo pipefail

# Source credentials (needed when running via cron)
source /opt/infrastructure/.env

BACKUP_DIR="/opt/backups/mysql"
RETENTION_DAYS=14
DATE=$(date +%Y-%m-%d_%H%M)

mkdir -p "$BACKUP_DIR"

# Verify MySQL is reachable
if ! docker exec mysql mysqladmin -u root -p"${MYSQL_ROOT_PASSWORD}" ping --silent > /dev/null 2>&1; then
  echo "[$(date)] ERROR: MySQL is not running or unreachable" >&2
  exit 1
fi

# Get list of databases (exclude system DBs)
DATABASES=$(docker exec mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -N -e \
  "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');" 2>/dev/null)

if [ -z "$DATABASES" ]; then
  echo "[$(date)] ERROR: No databases found to back up" >&2
  exit 1
fi

for DB in $DATABASES; do
  FILENAME="${BACKUP_DIR}/${DB}_${DATE}.sql.gz"
  docker exec mysql mysqldump -u root -p"${MYSQL_ROOT_PASSWORD}" --single-transaction "$DB" 2>/dev/null | gzip > "$FILENAME"
  echo "[$(date)] Backed up $DB -> $FILENAME"
done

# Clean old backups
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +${RETENTION_DAYS} -delete
echo "[$(date)] Cleaned backups older than ${RETENTION_DAYS} days"
