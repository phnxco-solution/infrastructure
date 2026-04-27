#!/bin/bash
set -e

if [ $# -lt 2 ]; then
    echo "Usage: bash $(dirname "$0")/init.sh <app-name> <app-domain> [backend-host]"
    echo "Example: bash /path/to/infrastructure/templates/spa/init.sh unimaginable-app unimaginable.phnx-solution.com unimaginable-nginx-1:80"
    echo ""
    echo "If backend-host is omitted, the /api and /storage proxy blocks are removed from nginx.conf."
    exit 1
fi

APP_NAME="$1"
APP_DOMAIN="$2"
BACKEND_HOST="${3:-}"
TEMPLATE_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$TEMPLATE_DIR/../.." && pwd)"

echo "Setting up Docker files for SPA: $APP_NAME ($APP_DOMAIN)"
if [ -n "$BACKEND_HOST" ]; then
    echo "Backend proxy upstream: $BACKEND_HOST"
fi

cp -r "$TEMPLATE_DIR/docker" ./docker
rm -f docker/docker-compose.prod.yml
cp "$TEMPLATE_DIR/.dockerignore" ./.dockerignore
mkdir -p .github/workflows
cp "$TEMPLATE_DIR/.github/workflows/deploy.yml" .github/workflows/deploy.yml

sed -i '' "s/{{APP_NAME}}/$APP_NAME/g" .github/workflows/deploy.yml

if [ -n "$BACKEND_HOST" ]; then
    sed -i '' "s|{{BACKEND_HOST}}|$BACKEND_HOST|g" docker/nginx.conf
else
    # Strip the proxy blocks (from "# Backend API" through the closing brace of /storage/)
    sed -i '' '/# Backend API/,/# SPA fallback/{/# SPA fallback/!d;}' docker/nginx.conf
fi

mkdir -p "$INFRA_ROOT/apps/$APP_NAME"
sed -e "s/{{APP_NAME}}/$APP_NAME/g" -e "s/{{APP_DOMAIN}}/$APP_DOMAIN/g" "$TEMPLATE_DIR/docker/docker-compose.prod.yml" > "$INFRA_ROOT/apps/$APP_NAME/docker-compose.yml"

echo "Done. Files created:"
echo "  docker/Dockerfile.nginx"
echo "  docker/nginx.conf"
echo "  .dockerignore"
echo "  .github/workflows/deploy.yml"
echo "  $INFRA_ROOT/apps/$APP_NAME/docker-compose.yml (production compose)"
