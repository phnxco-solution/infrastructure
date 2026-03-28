#!/bin/bash
# Restore migration pack on a new VPS
# Run AFTER setup.sh has been run and the repo is cloned
#
# Usage: bash /opt/infrastructure/scripts/migrate-unpack.sh /path/to/migration-pack.tar.gz [--verify-only]

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

INFRA_ROOT="/opt/infrastructure"
VOLUMES_ROOT="/opt/volumes"
STAGING_DIR="/opt/migration-staging"
TARBALL="${1:-}"
VERIFY_ONLY=false
SUDO_PID=""
MYSQL_CNF_CREATED=false

[[ "${2:-}" == "--verify-only" ]] && VERIFY_ONLY=true

# =============================================================================
# Helpers
# =============================================================================

info()    { echo "  $1"; }
success() { echo "  ✓ $1"; }
warn()    { echo "  ! $1"; }
error()   { echo "  ✗ $1" >&2; }

cleanup() {
  [ -d "$STAGING_DIR" ] && rm -rf "$STAGING_DIR"
  if $MYSQL_CNF_CREATED; then
    docker exec mysql rm -f /tmp/.restore.cnf 2>/dev/null || true
  fi
  [ -n "$SUDO_PID" ] && kill "$SUDO_PID" 2>/dev/null || true
}
trap cleanup EXIT

wait_healthy() {
  local container=$1 timeout=$2 elapsed=0
  while [ $elapsed -lt "$timeout" ]; do
    local status
    status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")
    [ "$status" = "healthy" ] && return 0
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

detect_app_type() {
  local compose_file="$1"
  if grep -qE 'php-fpm|php artisan|CONTAINER_ROLE' "$compose_file" 2>/dev/null; then
    echo "laravel"
  elif grep -qE 'NODE_ENV|node.*index\.mjs|dumb-init' "$compose_file" 2>/dev/null; then
    echo "nuxt"
  else
    echo "static"
  fi
}

parse_env_var() {
  local file="$1" var="$2"
  grep -E "^${var}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | sed "s/^[\"']//;s/[\"']$//"
}

# =============================================================================
# 1. Validate arguments
# =============================================================================

if [ -z "$TARBALL" ]; then
  echo "Usage: $0 /path/to/migration-pack.tar.gz [--verify-only]"
  exit 1
fi

[ -f "$TARBALL" ] || { error "Tarball not found: $TARBALL"; exit 1; }

# =============================================================================
# 2. Acquire sudo
# =============================================================================

echo "=== Acquire sudo ==="
sudo -v
while true; do sudo -n true; sleep 50; done 2>/dev/null &
SUDO_PID=$!
success "Sudo credentials cached"

# =============================================================================
# 3. Check prerequisites
# =============================================================================

echo "=== Check prerequisites ==="

docker info &>/dev/null || { error "Docker is not accessible"; exit 1; }
success "Docker accessible"

docker network inspect traefik-public &>/dev/null || { error "traefik-public network missing (run setup.sh first)"; exit 1; }
docker network inspect backend &>/dev/null || { error "backend network missing (run setup.sh first)"; exit 1; }
success "Docker networks exist"

[ -f "$INFRA_ROOT/docker-compose.yml" ] || { error "Infrastructure repo not found at $INFRA_ROOT"; exit 1; }
success "Infrastructure repo present"

for dir in "$VOLUMES_ROOT/mysql" "$VOLUMES_ROOT/redis" "$VOLUMES_ROOT/uptime-kuma" "$VOLUMES_ROOT/apps"; do
  [ -d "$dir" ] || { error "Directory $dir missing (run setup.sh first)"; exit 1; }
done
success "Directory structure from setup.sh exists"

# Disk space check
TARBALL_SIZE_MB=$(du -m "$TARBALL" | cut -f1)
REQUIRED_MB=$((TARBALL_SIZE_MB * 3))
AVAILABLE_MB=$(df -m /opt | tail -1 | awk '{print $4}')
if [ "$AVAILABLE_MB" -lt "$REQUIRED_MB" ]; then
  error "Insufficient disk space (need ~${REQUIRED_MB}MB, have ${AVAILABLE_MB}MB)"
  exit 1
fi
success "Disk space sufficient (${AVAILABLE_MB}MB available, ~${REQUIRED_MB}MB needed)"

# =============================================================================
# 4. Extract and validate tarball
# =============================================================================

echo "=== Extract tarball ==="
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
tar -xzf "$TARBALL" -C "$STAGING_DIR"

MANIFEST="$STAGING_DIR/migration/manifest.json"
[ -f "$MANIFEST" ] || { error "No manifest.json in tarball"; exit 1; }
success "Tarball extracted, manifest found"

# Parse manifest
PACKED_DBS=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(' '.join(m['components']['mysql']['databases']))" 2>/dev/null)
PACKED_CHECKSUMS=$(python3 -c "
import json
m = json.load(open('$MANIFEST'))
for db, md5 in m['components']['mysql']['checksums'].items():
    print(f'{db}:{md5}')
" 2>/dev/null)
SOURCE_COMMIT=$(python3 -c "import json; print(json.load(open('$MANIFEST'))['infrastructure_git_commit'])" 2>/dev/null || echo "unknown")
SOURCE_HOST=$(python3 -c "import json; print(json.load(open('$MANIFEST'))['source_hostname'])" 2>/dev/null || echo "unknown")

info "Source: $SOURCE_HOST (commit: $SOURCE_COMMIT)"
info "Databases: $PACKED_DBS"

# Check git commit match
CURRENT_COMMIT=$(cd "$INFRA_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
if [ "$SOURCE_COMMIT" != "$CURRENT_COMMIT" ] && [ "$SOURCE_COMMIT" != "unknown" ]; then
  warn "Git commit mismatch: tarball=$SOURCE_COMMIT, current=$CURRENT_COMMIT"
fi

# =============================================================================
# 5. Verify dump integrity
# =============================================================================

echo "=== Verify dump integrity ==="
for entry in $PACKED_CHECKSUMS; do
  db="${entry%%:*}"
  expected_md5="${entry##*:}"
  dump_file="$STAGING_DIR/migration/mysql/${db}.sql.gz"

  if [ ! -f "$dump_file" ]; then
    error "Dump file missing for database: $db"
    exit 1
  fi

  actual_md5=$(md5sum "$dump_file" | cut -d' ' -f1)
  if [ "$actual_md5" != "$expected_md5" ]; then
    error "Checksum mismatch for $db (expected: $expected_md5, got: $actual_md5)"
    exit 1
  fi

  if ! gzip -t "$dump_file" 2>/dev/null; then
    error "Dump for $db is corrupt (gzip test failed)"
    exit 1
  fi

  success "Database $db dump verified (md5: ${actual_md5:0:12}...)"
done

# =============================================================================
# Verify-only: show summary and exit
# =============================================================================

if $VERIFY_ONLY; then
  echo ""
  echo "=== Verify-Only Summary ==="
  echo ""
  info "Tarball: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
  info "Source: $SOURCE_HOST (commit: $SOURCE_COMMIT)"
  info "Databases: $PACKED_DBS"
  echo ""
  info "Contents:"
  [ -f "$STAGING_DIR/migration/env/infrastructure.env" ] && success "Infrastructure .env" || warn "No infrastructure .env"
  for f in "$STAGING_DIR/migration/env/apps"/*.env; do
    [ -f "$f" ] && success "App $(basename "$f" .env) .env"
  done
  [ -f "$STAGING_DIR/migration/certs/origin.pem" ] && success "TLS certificates" || warn "No TLS certificates"
  [ -d "$STAGING_DIR/migration/redis" ] && success "Redis data" || warn "No Redis data"
  [ -d "$STAGING_DIR/migration/uptime-kuma" ] && success "Uptime Kuma data" || warn "No Uptime Kuma data"
  for d in "$STAGING_DIR/migration/apps"/*/; do
    [ -d "$d" ] && success "App $(basename "$d") volume ($(du -sh "$d" | cut -f1))"
  done
  echo ""
  info "All checksums verified. Ready to unpack."
  echo ""
  exit 0
fi

# =============================================================================
# 6. Confirmation
# =============================================================================

echo ""
echo "  WARNING: This will overwrite ALL data on this VPS:"
echo "    - MySQL databases will be wiped and reimported"
echo "    - Redis data will be replaced"
echo "    - Uptime Kuma data will be replaced"
echo "    - App volumes will be replaced"
echo ""
read -p "  Continue? (y/N) " -n 1 -r
echo ""
[[ $REPLY =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

# =============================================================================
# 7. Stop everything running
# =============================================================================

echo "=== Stop all containers ==="

# Stop apps first
for dir in "$INFRA_ROOT/apps"/*/; do
  [ -f "$dir/docker-compose.yml" ] || continue
  app=$(basename "$dir")
  if docker compose --project-directory "$dir" ps --quiet 2>/dev/null | grep -q .; then
    docker compose --project-directory "$dir" down 2>/dev/null
    info "Stopped $app"
  fi
done

# Stop infrastructure
cd "$INFRA_ROOT"
if docker compose ps --quiet 2>/dev/null | grep -q .; then
  docker compose down 2>/dev/null
  info "Stopped infrastructure"
else
  info "Infrastructure was not running"
fi

# =============================================================================
# 8. Restore .env files
# =============================================================================

echo "=== Restore environment files ==="

if [ -f "$STAGING_DIR/migration/env/infrastructure.env" ]; then
  cp "$STAGING_DIR/migration/env/infrastructure.env" "$INFRA_ROOT/.env"
  chmod 600 "$INFRA_ROOT/.env"
  success "Infrastructure .env"
fi

for env_file in "$STAGING_DIR/migration/env/apps"/*.env; do
  [ -f "$env_file" ] || continue
  app=$(basename "$env_file" .env)
  target="$INFRA_ROOT/apps/$app"
  if [ -d "$target" ]; then
    cp "$env_file" "$target/.env"
    chmod 600 "$target/.env"
    success "App $app .env"
  else
    warn "App $app directory not found on this VPS — skipping .env"
  fi
done

# =============================================================================
# 9. Restore app config files
# =============================================================================

echo "=== Restore app config files ==="
for config_dir in "$STAGING_DIR/migration/app-configs"/*/; do
  [ -d "$config_dir" ] || continue
  app=$(basename "$config_dir")
  target="$INFRA_ROOT/apps/$app"
  if [ -d "$target" ]; then
    cp "$config_dir"* "$target/" 2>/dev/null || true
    success "App $app configs"
  else
    warn "App $app directory not found — skipping configs"
  fi
done

# =============================================================================
# 10. Restore TLS certificates
# =============================================================================

echo "=== Restore TLS certificates ==="
mkdir -p "$INFRA_ROOT/traefik/certs"
cp "$STAGING_DIR/migration/certs/origin.pem" "$INFRA_ROOT/traefik/certs/origin.pem"
cp "$STAGING_DIR/migration/certs/origin-key.pem" "$INFRA_ROOT/traefik/certs/origin-key.pem"
chmod 600 "$INFRA_ROOT/traefik/certs/origin-key.pem"
success "TLS certificates restored"

# =============================================================================
# 11. Wipe MySQL data dir (clean init with restored .env password)
# =============================================================================

echo "=== Prepare MySQL ==="
sudo rm -rf "$VOLUMES_ROOT/mysql/"*
success "MySQL data directory cleared for fresh initialization"

# =============================================================================
# 12. Restore Redis data (before starting containers)
# =============================================================================

echo "=== Restore Redis data ==="
if [ -d "$STAGING_DIR/migration/redis" ] && [ "$(ls -A "$STAGING_DIR/migration/redis" 2>/dev/null)" ]; then
  sudo rsync -a --delete "$STAGING_DIR/migration/redis/" "$VOLUMES_ROOT/redis/"
  success "Redis data restored"
else
  warn "No Redis data in tarball"
fi

# =============================================================================
# 13. Restore Uptime Kuma data (before starting containers)
# =============================================================================

echo "=== Restore Uptime Kuma data ==="
if [ -d "$STAGING_DIR/migration/uptime-kuma" ] && [ "$(ls -A "$STAGING_DIR/migration/uptime-kuma" 2>/dev/null)" ]; then
  sudo rsync -a --delete "$STAGING_DIR/migration/uptime-kuma/" "$VOLUMES_ROOT/uptime-kuma/"
  success "Uptime Kuma data restored"
else
  warn "No Uptime Kuma data in tarball"
fi

# =============================================================================
# 14. Restore app volumes with correct ownership
# =============================================================================

echo "=== Restore app volumes ==="
for app_dir in "$STAGING_DIR/migration/apps"/*/; do
  [ -d "$app_dir" ] || continue
  app=$(basename "$app_dir")
  target="$VOLUMES_ROOT/apps/$app"

  sudo mkdir -p "$target"
  sudo rsync -a --delete "$app_dir" "$target/"

  compose_file="$INFRA_ROOT/apps/$app/docker-compose.yml"
  if [ -f "$compose_file" ]; then
    APP_TYPE=$(detect_app_type "$compose_file")
    case "$APP_TYPE" in
      laravel)
        sudo chown -R 82:82 "$target/"
        success "App $app volume restored (owner: 82:82 www-data/Laravel)"
        ;;
      nuxt)
        sudo chown -R 1000:1000 "$target/"
        success "App $app volume restored (owner: 1000:1000 node/Nuxt)"
        ;;
      static)
        success "App $app volume restored (static, no ownership change)"
        ;;
    esac
  else
    warn "App $app has volume data but no compose file — restored with current ownership"
  fi
done

# =============================================================================
# 15. Start infrastructure
# =============================================================================

echo "=== Start infrastructure ==="
cd "$INFRA_ROOT"
docker compose up -d
success "Infrastructure started (Traefik, MySQL, Redis, Uptime Kuma, Autoheal)"

# =============================================================================
# 16. Wait for MySQL
# =============================================================================

echo "=== Wait for MySQL ==="
info "Waiting for MySQL to initialize and become healthy..."
if wait_healthy mysql 120; then
  success "MySQL is healthy"
else
  error "MySQL did not become healthy within 120s"
  docker logs mysql --tail 20 2>&1 | while read -r line; do info "  $line"; done
  exit 1
fi

# MySQL credentials for import
docker exec mysql sh -c 'printf "[client]\nuser=root\npassword=%s\n" "$MYSQL_ROOT_PASSWORD" > /tmp/.restore.cnf && chmod 600 /tmp/.restore.cnf'
MYSQL_CNF_CREATED=true

# =============================================================================
# 17. Import MySQL dumps
# =============================================================================

echo "=== Import MySQL databases ==="
for dump in "$STAGING_DIR/migration/mysql"/*.sql.gz; do
  [ -f "$dump" ] || continue
  db=$(basename "$dump" .sql.gz)

  info "Importing $db..."

  docker exec mysql mysql --defaults-extra-file=/tmp/.restore.cnf -e \
    "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

  if gunzip -c "$dump" | docker exec -i mysql mysql --defaults-extra-file=/tmp/.restore.cnf \
    --init-command="SET FOREIGN_KEY_CHECKS=0;" "$db"; then
    TABLE_COUNT=$(docker exec mysql mysql --defaults-extra-file=/tmp/.restore.cnf -N -e \
      "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db';" 2>/dev/null)
    success "Database $db imported ($TABLE_COUNT tables)"
  else
    error "Failed to import $db"
    exit 1
  fi
done

# =============================================================================
# 18. Recreate MySQL users from app .env files
# =============================================================================

echo "=== Recreate MySQL users ==="
for dir in "$INFRA_ROOT/apps"/*/; do
  [ -f "$dir/.env" ] || continue
  app=$(basename "$dir")

  # Try Laravel-style vars first, then Nuxt-style
  DB_DATABASE=$(parse_env_var "$dir/.env" "DB_DATABASE")
  DB_USERNAME=$(parse_env_var "$dir/.env" "DB_USERNAME")
  DB_PASSWORD=$(parse_env_var "$dir/.env" "DB_PASSWORD")

  # Fallback to Nuxt-style
  [ -z "$DB_DATABASE" ] && DB_DATABASE=$(parse_env_var "$dir/.env" "DB_NAME")
  [ -z "$DB_USERNAME" ] && DB_USERNAME=$(parse_env_var "$dir/.env" "DB_USER")

  # Fallback to DATABASE_URL
  if [ -z "$DB_DATABASE" ] || [ -z "$DB_USERNAME" ]; then
    DATABASE_URL=$(parse_env_var "$dir/.env" "DATABASE_URL")
    if [ -n "$DATABASE_URL" ]; then
      # Parse mysql://user:password@host:port/database
      DB_USERNAME=$(echo "$DATABASE_URL" | sed -n 's|.*://\([^:]*\):.*|\1|p')
      DB_PASSWORD=$(echo "$DATABASE_URL" | sed -n 's|.*://[^:]*:\([^@]*\)@.*|\1|p')
      DB_DATABASE=$(echo "$DATABASE_URL" | sed -n 's|.*/\([^?]*\).*|\1|p')
    fi
  fi

  [ -z "$DB_DATABASE" ] || [ -z "$DB_USERNAME" ] && continue

  # Escape single quotes in password for SQL
  ESCAPED_PASSWORD=$(echo "$DB_PASSWORD" | sed "s/'/''/g")
  ESCAPED_USERNAME=$(echo "$DB_USERNAME" | sed "s/'/''/g")

  info "Creating user $DB_USERNAME for $DB_DATABASE ($app)"
  # Use printf piped to docker exec -i to avoid shell interpolation of passwords
  printf "CREATE USER IF NOT EXISTS '%s'@'%%' IDENTIFIED BY '%s';\nALTER USER '%s'@'%%' IDENTIFIED BY '%s';\nGRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%%';\nFLUSH PRIVILEGES;\n" \
    "$ESCAPED_USERNAME" "$ESCAPED_PASSWORD" "$ESCAPED_USERNAME" "$ESCAPED_PASSWORD" "$DB_DATABASE" "$ESCAPED_USERNAME" \
    | docker exec -i mysql mysql --defaults-extra-file=/tmp/.restore.cnf 2>/dev/null \
    && success "User $DB_USERNAME → $DB_DATABASE" || warn "Failed to create user for $app"
done

# =============================================================================
# 19. GHCR authentication check
# =============================================================================

echo "=== Docker registry authentication ==="
NEEDS_GHCR=false
for dir in "$INFRA_ROOT/apps"/*/; do
  [ -f "$dir/docker-compose.yml" ] || continue
  grep -q 'ghcr.io' "$dir/docker-compose.yml" && NEEDS_GHCR=true && break
done

if $NEEDS_GHCR; then
  if grep -q "ghcr.io" ~/.docker/config.json 2>/dev/null; then
    success "Already authenticated to ghcr.io"
  else
    warn "Not authenticated to ghcr.io — apps with private images will fail"
    echo ""
    read -p "  Enter GHCR Personal Access Token (or press Enter to skip): " -r GHCR_PAT
    if [ -n "$GHCR_PAT" ]; then
      read -p "  Enter GHCR username: " -r GHCR_USER
      echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin 2>/dev/null \
        && success "Authenticated to ghcr.io" \
        || warn "GHCR authentication failed"
    else
      warn "Skipping GHCR auth — private images will fail to pull"
    fi
  fi
else
  info "No apps use ghcr.io — skipping"
fi

# =============================================================================
# 20. Pull images and start apps
# =============================================================================

echo "=== Start apps ==="
for dir in "$INFRA_ROOT/apps"/*/; do
  [ -f "$dir/docker-compose.yml" ] || continue
  app=$(basename "$dir")

  # Check if .env is required
  if grep -q 'env_file' "$dir/docker-compose.yml" && [ ! -f "$dir/.env" ]; then
    warn "Skipping $app — requires .env file which is missing"
    continue
  fi

  info "Pulling and starting $app..."
  cd "$dir"
  docker compose pull 2>/dev/null || warn "Failed to pull images for $app"
  docker compose up -d 2>/dev/null && success "Started $app" || warn "Failed to start $app"
done

# =============================================================================
# 21. Brief health check
# =============================================================================

echo "=== Health check ==="
sleep 5

for svc in traefik mysql redis uptime-kuma; do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "not running")
  if [ "$STATUS" = "healthy" ]; then
    success "$svc is healthy"
  else
    warn "$svc status: $STATUS"
  fi
done

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "==========================================="
echo "  Migration unpack complete"
echo "==========================================="
echo ""
echo "  Run full verification:"
echo "    bash /opt/infrastructure/scripts/verify-setup.sh"
echo "    bash /opt/infrastructure/scripts/verify-migration.sh"
echo ""
echo "  Remaining steps:"
echo "    1. Delete the tarball: rm $TARBALL"
echo "    2. Update Cloudflare DNS A records to this VPS IP"
echo "    3. Update GitHub Actions secrets in each app repo:"
echo "       - VPS_HOST → new IP"
echo "       - VPS_PORT → 41922"
echo "       - VPS_SSH_KEY → new deploy key"
echo "       - GHCR_PAT → (if changed)"
echo "    4. Monitor logs for 24 hours"
echo ""
