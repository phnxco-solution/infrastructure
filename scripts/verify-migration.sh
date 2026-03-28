#!/bin/bash
# Verify migration data and services — run after migrate-unpack.sh
# Standalone, re-runnable, read-only (no changes made)
#
# Usage: bash /opt/infrastructure/scripts/verify-migration.sh

set -uo pipefail

INFRA_ROOT="/opt/infrastructure"
VOLUMES_ROOT="/opt/volumes"

PASS=0
FAIL=0
WARN=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ! $1"; WARN=$((WARN + 1)); }

check() {
  if eval "$1" &>/dev/null; then
    pass "$2"
  else
    fail "$2"
  fi
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
echo "=== Infrastructure Services ==="
# =============================================================================

for svc in traefik mysql redis uptime-kuma autoheal; do
  RUNNING=$(docker inspect --format='{{.State.Running}}' "$svc" 2>/dev/null || echo "false")
  if [ "$RUNNING" = "true" ]; then
    HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "none")
    if [ "$HEALTH" = "healthy" ] || [ "$HEALTH" = "none" ]; then
      pass "$svc running" && [ "$HEALTH" = "healthy" ] && true || true
    else
      warn "$svc running but health: $HEALTH"
    fi
  else
    fail "$svc is not running"
  fi
done

# Redis connectivity
REDIS_PASSWORD=$(parse_env_var "$INFRA_ROOT/.env" "REDIS_PASSWORD" 2>/dev/null)
if [ -n "$REDIS_PASSWORD" ]; then
  PONG=$(docker exec redis redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -v "Warning")
  if [ "$PONG" = "PONG" ]; then
    pass "Redis responds to ping"
    KEY_COUNT=$(docker exec redis redis-cli -a "$REDIS_PASSWORD" DBSIZE 2>/dev/null | grep -v "Warning" | grep -oE '[0-9]+')
    if [ "${KEY_COUNT:-0}" -gt 0 ]; then
      pass "Redis has data ($KEY_COUNT keys)"
    else
      warn "Redis is empty (0 keys) — may be expected if cache was cleared"
    fi
  else
    fail "Redis not responding"
  fi
fi

# =============================================================================
echo ""
echo "=== Configuration Files ==="
# =============================================================================

check "test -f '$INFRA_ROOT/.env'" "Infrastructure .env exists"
check "test -f '$INFRA_ROOT/traefik/certs/origin.pem' && test -s '$INFRA_ROOT/traefik/certs/origin.pem'" "TLS cert origin.pem exists and non-empty"
check "test -f '$INFRA_ROOT/traefik/certs/origin-key.pem' && test -s '$INFRA_ROOT/traefik/certs/origin-key.pem'" "TLS cert origin-key.pem exists and non-empty"

for dir in "$INFRA_ROOT/apps"/*/; do
  [ -f "$dir/docker-compose.yml" ] || continue
  app=$(basename "$dir")
  if grep -q 'env_file' "$dir/docker-compose.yml"; then
    if [ -f "$dir/.env" ]; then
      pass "App $app .env exists"
    else
      fail "App $app requires .env but it is missing"
    fi
  fi
done

# =============================================================================
echo ""
echo "=== MySQL Databases ==="
# =============================================================================

MYSQL_STATUS=$(docker inspect --format='{{.State.Health.Status}}' mysql 2>/dev/null || echo "missing")
if [ "$MYSQL_STATUS" != "healthy" ]; then
  fail "MySQL is not healthy — skipping database checks"
else
  # Create temp credentials
  docker exec mysql sh -c 'printf "[client]\nuser=root\npassword=%s\n" "$MYSQL_ROOT_PASSWORD" > /tmp/.verify.cnf && chmod 600 /tmp/.verify.cnf' 2>/dev/null

  DATABASES=$(docker exec mysql mysql --defaults-extra-file=/tmp/.verify.cnf -N -e \
    "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');" 2>/dev/null)

  if [ -n "$DATABASES" ]; then
    for db in $DATABASES; do
      TABLE_COUNT=$(docker exec mysql mysql --defaults-extra-file=/tmp/.verify.cnf -N -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db';" 2>/dev/null)
      if [ "${TABLE_COUNT:-0}" -gt 0 ]; then
        pass "Database $db exists ($TABLE_COUNT tables)"
      else
        fail "Database $db exists but has no tables"
      fi
    done
  else
    fail "No user databases found in MySQL"
  fi

  # Test app database credentials
  for dir in "$INFRA_ROOT/apps"/*/; do
    [ -f "$dir/.env" ] || continue
    app=$(basename "$dir")

    DB_DATABASE=$(parse_env_var "$dir/.env" "DB_DATABASE")
    DB_USERNAME=$(parse_env_var "$dir/.env" "DB_USERNAME")
    DB_PASSWORD=$(parse_env_var "$dir/.env" "DB_PASSWORD")

    [ -z "$DB_DATABASE" ] && DB_DATABASE=$(parse_env_var "$dir/.env" "DB_NAME")
    [ -z "$DB_USERNAME" ] && DB_USERNAME=$(parse_env_var "$dir/.env" "DB_USER")

    if [ -z "$DB_DATABASE" ] || [ -z "$DB_USERNAME" ]; then
      continue
    fi

    # Test authentication with app credentials
    if docker exec mysql mysql -u"$DB_USERNAME" -p"$DB_PASSWORD" -e "USE \`$DB_DATABASE\`; SELECT 1;" &>/dev/null; then
      pass "App $app DB user '$DB_USERNAME' can connect to '$DB_DATABASE'"
    else
      fail "App $app DB user '$DB_USERNAME' cannot connect to '$DB_DATABASE'"
    fi
  done

  docker exec mysql rm -f /tmp/.verify.cnf 2>/dev/null || true
fi

# =============================================================================
echo ""
echo "=== App Volumes ==="
# =============================================================================

for dir in "$INFRA_ROOT/apps"/*/; do
  [ -f "$dir/docker-compose.yml" ] || continue
  app=$(basename "$dir")
  vol_dir="$VOLUMES_ROOT/apps/$app"

  if [ -d "$vol_dir" ]; then
    SIZE=$(sudo du -sh "$vol_dir" 2>/dev/null | cut -f1)
    OWNER=$(sudo stat -c '%u:%g' "$vol_dir" 2>/dev/null || echo "unknown")

    APP_TYPE=$(detect_app_type "$dir/docker-compose.yml")
    EXPECTED_OWNER=""
    case "$APP_TYPE" in
      laravel) EXPECTED_OWNER="82:82" ;;
      nuxt)    EXPECTED_OWNER="1000:1000" ;;
      static)  EXPECTED_OWNER="" ;;
    esac

    if [ -n "$EXPECTED_OWNER" ] && [ "$OWNER" != "$EXPECTED_OWNER" ]; then
      warn "App $app volume exists ($SIZE) but ownership is $OWNER (expected $EXPECTED_OWNER)"
    else
      pass "App $app volume exists ($SIZE, owner: $OWNER)"
    fi

    # Type-specific checks
    case "$APP_TYPE" in
      laravel)
        if sudo test -d "$vol_dir/storage/app/public" 2>/dev/null; then
          pass "App $app has storage/app/public/"
        else
          warn "App $app missing storage/app/public/"
        fi
        ;;
      nuxt)
        if sudo test -d "$vol_dir/storage" 2>/dev/null; then
          pass "App $app has storage/"
        else
          warn "App $app missing storage/"
        fi
        ;;
    esac
  else
    warn "App $app has no volume directory"
  fi
done

# =============================================================================
echo ""
echo "=== App Containers ==="
# =============================================================================

for dir in "$INFRA_ROOT/apps"/*/; do
  [ -f "$dir/docker-compose.yml" ] || continue
  app=$(basename "$dir")

  SERVICES=$(cd "$dir" && docker compose ps --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null)
  if [ -z "$SERVICES" ]; then
    fail "App $app has no running containers"
    continue
  fi

  ALL_RUNNING=true
  while IFS= read -r line; do
    svc=$(echo "$line" | awk '{print $1}')
    state=$(echo "$line" | awk '{print $2}')
    health=$(echo "$line" | awk '{print $3}')

    if [ "$state" = "running" ]; then
      if [ "$health" = "healthy" ] || [ -z "$health" ]; then
        pass "App $app/$svc running (health: ${health:-none})"
      else
        warn "App $app/$svc running but health: $health"
      fi
    else
      fail "App $app/$svc state: $state"
      ALL_RUNNING=false
    fi
  done <<< "$SERVICES"
done

# =============================================================================
echo ""
echo "=== Connectivity ==="
# =============================================================================

# Check Traefik is routing
for dir in "$INFRA_ROOT/apps"/*/; do
  [ -f "$dir/docker-compose.yml" ] || continue
  app=$(basename "$dir")

  DOMAIN=$(grep -oP 'Host\(`\K[^`]+' "$dir/docker-compose.yml" 2>/dev/null | head -1)
  [ -z "$DOMAIN" ] && continue

  # Try via Traefik (localhost) — will work if DNS is not pointed yet
  HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" --max-time 5 2>/dev/null || echo "000")

  if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 500 ]; then
    pass "App $app responds via Traefik ($DOMAIN → HTTP $HTTP_CODE)"
  elif [ "$HTTP_CODE" = "000" ]; then
    warn "App $app not reachable via Traefik ($DOMAIN) — DNS may not be pointed yet"
  else
    fail "App $app responds with HTTP $HTTP_CODE ($DOMAIN)"
  fi
done

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "==========================================="
TOTAL=$((PASS + FAIL + WARN))
echo "  Results: $PASS passed, $FAIL failed, $WARN warnings (of $TOTAL checks)"
echo "==========================================="

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "  ISSUES FOUND — review failures above"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo ""
  echo "  PASSED with warnings — review items above"
  exit 0
else
  echo ""
  echo "  ALL CLEAR — migration verified successfully"
  exit 0
fi
