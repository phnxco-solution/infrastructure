#!/bin/bash
# Pack everything needed for VPS migration into a single tarball
# Run on the OLD VPS as deploy user (services stay running, apps stop briefly)
#
# Usage: bash /opt/infrastructure/scripts/migrate-pack.sh [--dry-run]

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

INFRA_ROOT="/opt/infrastructure"
VOLUMES_ROOT="/opt/volumes"
STAGING_DIR="/opt/migration-staging"
DATE=$(date +%Y-%m-%d)
OUTPUT_FILE="/opt/migration-pack-${DATE}.tar.gz"
DRY_RUN=false
SUDO_PID=""
MYSQL_CNF_CREATED=false
APPS_STOPPED=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# =============================================================================
# Helpers
# =============================================================================

info()    { echo "  $1"; }
success() { echo "  ✓ $1"; }
warn()    { echo "  ! $1"; }
error()   { echo "  ✗ $1" >&2; }

cleanup() {
  # Restart apps if they were stopped
  if $APPS_STOPPED; then
    echo ""
    echo "=== Restarting app containers ==="
    for dir in "$INFRA_ROOT/apps"/*/; do
      [ -f "$dir/docker-compose.yml" ] || continue
      local app=$(basename "$dir")
      (cd "$dir" && docker compose up -d 2>/dev/null) && info "Started $app" || warn "Failed to start $app"
    done
    APPS_STOPPED=false
  fi

  # Clean MySQL temp credentials
  if $MYSQL_CNF_CREATED; then
    docker exec mysql rm -f /tmp/.pack.cnf 2>/dev/null || true
  fi

  # Remove staging directory
  [ -d "$STAGING_DIR" ] && rm -rf "$STAGING_DIR"

  # Kill sudo keepalive
  [ -n "$SUDO_PID" ] && kill "$SUDO_PID" 2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
# 1. Acquire sudo
# =============================================================================

echo "=== Acquire sudo ==="
sudo -v
while true; do sudo -n true; sleep 50; done 2>/dev/null &
SUDO_PID=$!
success "Sudo credentials cached"

# =============================================================================
# 2. Prerequisites
# =============================================================================

echo "=== Check prerequisites ==="

docker info &>/dev/null || { error "Docker is not accessible"; exit 1; }
success "Docker accessible"

MYSQL_STATUS=$(docker inspect --format='{{.State.Health.Status}}' mysql 2>/dev/null || echo "missing")
[ "$MYSQL_STATUS" = "healthy" ] || { error "MySQL is not healthy (status: $MYSQL_STATUS)"; exit 1; }
success "MySQL is healthy"

[ -f "$INFRA_ROOT/.env" ] || { error "Infrastructure .env not found"; exit 1; }
success "Infrastructure .env exists"

[ -f "$INFRA_ROOT/traefik/certs/origin.pem" ] || { error "TLS cert origin.pem not found"; exit 1; }
[ -f "$INFRA_ROOT/traefik/certs/origin-key.pem" ] || { error "TLS cert origin-key.pem not found"; exit 1; }
success "TLS certificates exist"

command -v python3 &>/dev/null || { error "Python3 is required for manifest generation"; exit 1; }
success "Python3 available"

# =============================================================================
# 3. Discover apps and databases
# =============================================================================

echo "=== Discover apps and databases ==="

APPS=()
for dir in "$INFRA_ROOT/apps"/*/; do
  [ -d "$dir" ] && APPS+=("$(basename "$dir")")
done
info "Apps found: ${APPS[*]}"

# MySQL credentials (same pattern as backup.sh)
docker exec mysql sh -c 'printf "[client]\nuser=root\npassword=%s\n" "$MYSQL_ROOT_PASSWORD" > /tmp/.pack.cnf && chmod 600 /tmp/.pack.cnf'
MYSQL_CNF_CREATED=true

DATABASES=$(docker exec mysql mysql --defaults-extra-file=/tmp/.pack.cnf -N -e \
  "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');" 2>/dev/null)

[ -z "$DATABASES" ] && { error "No databases found"; exit 1; }
info "Databases found: $(echo $DATABASES | tr '\n' ' ')"

# =============================================================================
# 4. Disk space check
# =============================================================================

echo "=== Check disk space ==="

VOLUME_SIZE=$(sudo du -sm "$VOLUMES_ROOT" 2>/dev/null | awk '{print $1}')
AVAILABLE=$(df -m /opt | tail -1 | awk '{print $4}')
REQUIRED=$((VOLUME_SIZE * 2))

info "Volume data: ~${VOLUME_SIZE}MB, Available: ${AVAILABLE}MB, Required: ~${REQUIRED}MB"

if [ "$AVAILABLE" -lt "$REQUIRED" ]; then
  error "Insufficient disk space (need ~${REQUIRED}MB, have ${AVAILABLE}MB)"
  exit 1
fi
success "Disk space sufficient"

# =============================================================================
# Dry-run: show summary and exit
# =============================================================================

if $DRY_RUN; then
  echo ""
  echo "=== Dry Run Summary ==="
  echo ""
  info "Apps: ${APPS[*]}"
  info "Databases: $(echo $DATABASES | tr '\n' ' ')"
  echo ""
  info "Component sizes:"
  info "  Infrastructure .env: $(du -h "$INFRA_ROOT/.env" | cut -f1)"
  info "  TLS certs: $(du -sh "$INFRA_ROOT/traefik/certs/" 2>/dev/null | cut -f1)"
  for app in "${APPS[@]}"; do
    ENV_SIZE="(no .env)"
    [ -f "$INFRA_ROOT/apps/$app/.env" ] && ENV_SIZE=$(du -h "$INFRA_ROOT/apps/$app/.env" | cut -f1)
    info "  App $app .env: $ENV_SIZE"
  done
  sudo du -sh "$VOLUMES_ROOT/redis/" 2>/dev/null | awk '{print "  Redis: "$1}'
  sudo du -sh "$VOLUMES_ROOT/uptime-kuma/" 2>/dev/null | awk '{print "  Uptime Kuma: "$1}'
  for app in "${APPS[@]}"; do
    [ -d "$VOLUMES_ROOT/apps/$app" ] && \
      sudo du -sh "$VOLUMES_ROOT/apps/$app/" 2>/dev/null | awk -v a="$app" '{print "  App "a" volume: "$1}'
  done
  echo ""
  info "Estimated tarball: ~${VOLUME_SIZE}MB (compressed will be smaller)"
  info "Output would be: $OUTPUT_FILE"
  echo ""
  exit 0
fi

# =============================================================================
# 5. Create staging directory
# =============================================================================

echo "=== Create staging directory ==="
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/migration"/{env/apps,app-configs,certs,mysql,redis,uptime-kuma,apps}
success "Staging at $STAGING_DIR"

# =============================================================================
# 6. Stop app containers (consistent snapshot)
# =============================================================================

echo "=== Stop app containers ==="
for dir in "$INFRA_ROOT/apps"/*/; do
  [ -f "$dir/docker-compose.yml" ] || continue
  app=$(basename "$dir")
  if docker compose --project-directory "$dir" ps --quiet 2>/dev/null | grep -q .; then
    docker compose --project-directory "$dir" down 2>/dev/null
    info "Stopped $app"
  else
    info "$app was not running"
  fi
done
APPS_STOPPED=true

# =============================================================================
# 7. Pack .env files
# =============================================================================

echo "=== Pack environment files ==="
cp "$INFRA_ROOT/.env" "$STAGING_DIR/migration/env/infrastructure.env"
success "Infrastructure .env"

for app in "${APPS[@]}"; do
  if [ -f "$INFRA_ROOT/apps/$app/.env" ]; then
    cp "$INFRA_ROOT/apps/$app/.env" "$STAGING_DIR/migration/env/apps/${app}.env"
    success "App $app .env"
  else
    warn "App $app has no .env (skipping)"
  fi
done

# =============================================================================
# 8. Pack app config files (nginx.conf, etc.)
# =============================================================================

echo "=== Pack app config files ==="
for app in "${APPS[@]}"; do
  HAS_CONFIGS=false
  for file in "$INFRA_ROOT/apps/$app"/*; do
    [ -f "$file" ] || continue
    fname=$(basename "$file")
    # Skip .env and docker-compose.yml (handled separately or in git)
    [[ "$fname" == ".env" || "$fname" == "docker-compose.yml" ]] && continue
    mkdir -p "$STAGING_DIR/migration/app-configs/$app"
    cp "$file" "$STAGING_DIR/migration/app-configs/$app/$fname"
    HAS_CONFIGS=true
  done
  $HAS_CONFIGS && success "App $app configs" || info "App $app has no extra configs"
done

# =============================================================================
# 9. Pack TLS certificates
# =============================================================================

echo "=== Pack TLS certificates ==="
cp "$INFRA_ROOT/traefik/certs/origin.pem" "$STAGING_DIR/migration/certs/origin.pem"
cp "$INFRA_ROOT/traefik/certs/origin-key.pem" "$STAGING_DIR/migration/certs/origin-key.pem"
success "Origin certificate and key"

# =============================================================================
# 10. Pack MySQL databases
# =============================================================================

echo "=== Pack MySQL databases ==="
CHECKSUMS=""
for db in $DATABASES; do
  DUMP_FILE="$STAGING_DIR/migration/mysql/${db}.sql.gz"

  DUMP_ERR=$(mktemp)
  if ! docker exec mysql mysqldump --defaults-extra-file=/tmp/.pack.cnf \
    --single-transaction --routines --triggers --events "$db" 2>"$DUMP_ERR" | gzip > "$DUMP_FILE"; then
    error "mysqldump failed for $db: $(cat "$DUMP_ERR")"
    rm -f "$DUMP_FILE" "$DUMP_ERR"
    exit 1
  fi
  rm -f "$DUMP_ERR"

  if [ ! -s "$DUMP_FILE" ] || ! gzip -t "$DUMP_FILE" 2>/dev/null; then
    error "Dump for $db is empty or corrupt"
    exit 1
  fi

  MD5=$(md5sum "$DUMP_FILE" | cut -d' ' -f1)
  CHECKSUMS="$CHECKSUMS\"$db\": \"$MD5\", "
  SIZE=$(du -h "$DUMP_FILE" | cut -f1)
  success "Database $db ($SIZE, md5: ${MD5:0:12}...)"
done

# =============================================================================
# 11. Pack Redis data
# =============================================================================

echo "=== Pack Redis data ==="
REDIS_PASSWORD=$(grep '^REDIS_PASSWORD=' "$INFRA_ROOT/.env" | cut -d= -f2- | tr -d '"' | tr -d "'")

# Trigger safe point-in-time snapshot
docker exec redis redis-cli -a "$REDIS_PASSWORD" BGSAVE 2>/dev/null | grep -v "Warning" || true
INITIAL_SAVE=$(docker exec redis redis-cli -a "$REDIS_PASSWORD" LASTSAVE 2>/dev/null | grep -v "Warning" | tr -d '[:space:]')

info "Waiting for BGSAVE to complete..."
TIMEOUT=60
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  CURRENT_SAVE=$(docker exec redis redis-cli -a "$REDIS_PASSWORD" LASTSAVE 2>/dev/null | grep -v "Warning" | tr -d '[:space:]')
  [ "$CURRENT_SAVE" != "$INITIAL_SAVE" ] && break
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  warn "BGSAVE did not complete within ${TIMEOUT}s — proceeding with last available snapshot"
fi

sudo rsync -a "$VOLUMES_ROOT/redis/" "$STAGING_DIR/migration/redis/"
SIZE=$(du -sh "$STAGING_DIR/migration/redis/" | cut -f1)
success "Redis data ($SIZE)"

# =============================================================================
# 12. Pack Uptime Kuma data
# =============================================================================

echo "=== Pack Uptime Kuma data ==="
# Stop to avoid SQLite WAL corruption
docker compose -f "$INFRA_ROOT/docker-compose.yml" stop uptime-kuma 2>/dev/null || true
sudo rsync -a "$VOLUMES_ROOT/uptime-kuma/" "$STAGING_DIR/migration/uptime-kuma/"
docker compose -f "$INFRA_ROOT/docker-compose.yml" start uptime-kuma 2>/dev/null || true
SIZE=$(du -sh "$STAGING_DIR/migration/uptime-kuma/" | cut -f1)
success "Uptime Kuma data ($SIZE)"

# =============================================================================
# 13. Pack app volumes
# =============================================================================

echo "=== Pack app volumes ==="
APP_MANIFEST=""
for app in "${APPS[@]}"; do
  SRC="$VOLUMES_ROOT/apps/$app"
  if [ -d "$SRC" ] && [ "$(sudo ls -A "$SRC" 2>/dev/null)" ]; then
    mkdir -p "$STAGING_DIR/migration/apps/$app"
    sudo rsync -a "$SRC/" "$STAGING_DIR/migration/apps/$app/"
    DIRS=$(sudo find "$SRC" -mindepth 1 -maxdepth 1 -type d -printf '%f,' 2>/dev/null | sed 's/,$//')
    SIZE=$(sudo du -sh "$SRC" | cut -f1)
    success "App $app volume ($SIZE) — dirs: $DIRS"
    APP_MANIFEST="$APP_MANIFEST\"$app\": {\"dirs\": [$(echo "$DIRS" | sed 's/\([^,]*\)/"\1"/g')]}, "
  else
    warn "App $app has no volume data (skipping)"
    APP_MANIFEST="$APP_MANIFEST\"$app\": {\"dirs\": []}, "
  fi
done

# =============================================================================
# 14. Restart app containers
# =============================================================================

echo "=== Restart app containers ==="
for dir in "$INFRA_ROOT/apps"/*/; do
  [ -f "$dir/docker-compose.yml" ] || continue
  app=$(basename "$dir")
  [ -f "$dir/.env" ] || [[ ! $(grep -c 'env_file' "$dir/docker-compose.yml") -gt 0 ]] || { warn "Skipping $app (no .env)"; continue; }
  (cd "$dir" && docker compose up -d 2>/dev/null) && success "Started $app" || warn "Failed to start $app"
done
APPS_STOPPED=false

# =============================================================================
# 15. Generate manifest
# =============================================================================

echo "=== Generate manifest ==="
GIT_COMMIT=$(cd "$INFRA_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
HOSTNAME_VAL=$(hostname)

# Build app .env presence map
ENV_MAP=""
for app in "${APPS[@]}"; do
  HAS_ENV="false"
  [ -f "$STAGING_DIR/migration/env/apps/${app}.env" ] && HAS_ENV="true"
  ENV_MAP="$ENV_MAP\"$app\": $HAS_ENV, "
done

python3 -c "
import json, datetime
manifest = {
    'version': '1.0',
    'created_at': datetime.datetime.utcnow().isoformat() + 'Z',
    'source_hostname': '$HOSTNAME_VAL',
    'infrastructure_git_commit': '$GIT_COMMIT',
    'components': {
        'env': {
            'infrastructure': True,
            'apps': {${ENV_MAP%,*}}
        },
        'certs': True,
        'mysql': {
            'databases': $(echo "$DATABASES" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().split()))"),
            'checksums': {${CHECKSUMS%,*}}
        },
        'redis': True,
        'uptime_kuma': True,
        'apps': {${APP_MANIFEST%,*}}
    }
}
with open('$STAGING_DIR/migration/manifest.json', 'w') as f:
    json.dump(manifest, f, indent=2)
" 2>/dev/null

success "Manifest generated"

# =============================================================================
# 16. Create tarball
# =============================================================================

echo "=== Create tarball ==="
tar -czf "$OUTPUT_FILE" -C "$STAGING_DIR" migration/
TARBALL_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
success "Created $OUTPUT_FILE ($TARBALL_SIZE)"

# Cleanup staging (trap will handle if we exit early)
rm -rf "$STAGING_DIR"

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "==========================================="
echo "  Migration pack complete"
echo "==========================================="
echo ""
echo "  File: $OUTPUT_FILE"
echo "  Size: $TARBALL_SIZE"
echo "  Apps: ${APPS[*]}"
echo "  DBs:  $(echo $DATABASES | tr '\n' ' ')"
echo ""
echo "  Transfer to new VPS:"
echo "    scp -P 41922 $OUTPUT_FILE deploy@<new-vps-ip>:/opt/"
echo ""
echo "  Then on the new VPS:"
echo "    bash /opt/infrastructure/scripts/migrate-unpack.sh /opt/$(basename "$OUTPUT_FILE")"
echo ""
echo "  IMPORTANT: Delete the tarball from both machines after migration."
echo "  It contains production secrets."
echo ""
