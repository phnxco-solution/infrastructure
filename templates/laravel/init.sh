#!/bin/bash
set -e

if [ $# -lt 2 ]; then
    echo "Usage: bash $(dirname "$0")/init.sh <app-name> <app-domain>"
    echo "Example: bash /path/to/infrastructure/templates/laravel/init.sh mega-catering mega-catering.phnx-solution.com"
    exit 1
fi

APP_NAME="$1"
APP_DOMAIN="$2"
TEMPLATE_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$TEMPLATE_DIR/../.." && pwd)"

echo "Setting up Docker files for: $APP_NAME ($APP_DOMAIN)"

cp -r "$TEMPLATE_DIR/docker" ./docker
rm -f docker/docker-compose.prod.yml
cp "$TEMPLATE_DIR/.dockerignore" ./.dockerignore
cp "$TEMPLATE_DIR/docker-compose.yml" ./docker-compose.yml
mkdir -p .github/workflows
cp "$TEMPLATE_DIR/.github/workflows/deploy.yml" .github/workflows/deploy.yml

sed -i '' "s/{{APP_NAME}}/$APP_NAME/g" .github/workflows/deploy.yml

mkdir -p "$INFRA_ROOT/apps/$APP_NAME"
sed -e "s/{{APP_NAME}}/$APP_NAME/g" -e "s/{{APP_DOMAIN}}/$APP_DOMAIN/g" "$TEMPLATE_DIR/docker/docker-compose.prod.yml" > "$INFRA_ROOT/apps/$APP_NAME/docker-compose.yml"

echo "Done. Files created:"
echo "  docker/Dockerfile"
echo "  docker/Dockerfile.nginx"
echo "  docker/entrypoint.sh"
echo "  docker/nginx.conf"
echo "  docker-compose.yml"
echo "  .dockerignore"
echo "  .github/workflows/deploy.yml"
echo "  $INFRA_ROOT/apps/$APP_NAME/docker-compose.yml (production compose)"
