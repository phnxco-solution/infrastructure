#!/bin/bash
set -e

if [ $# -lt 2 ]; then
    echo "Usage: bash $(dirname "$0")/init.sh <app-name> <app-domain>"
    echo "Example: bash /path/to/infrastructure/templates/nuxt/init.sh endlessly endlessly.phnx-solution.com"
    exit 1
fi

APP_NAME="$1"
APP_DOMAIN="$2"
TEMPLATE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Setting up Docker files for: $APP_NAME ($APP_DOMAIN)"

cp -r "$TEMPLATE_DIR/docker" ./docker
cp "$TEMPLATE_DIR/.dockerignore" ./.dockerignore
cp "$TEMPLATE_DIR/docker-compose.yml" ./docker-compose.yml
mkdir -p .github/workflows
cp "$TEMPLATE_DIR/.github/workflows/deploy.yml" .github/workflows/deploy.yml

sed -i '' "s/{{APP_NAME}}/$APP_NAME/g" docker/docker-compose.prod.yml .github/workflows/deploy.yml
sed -i '' "s/{{APP_DOMAIN}}/$APP_DOMAIN/g" docker/docker-compose.prod.yml

echo "Done. Files created:"
echo "  docker/Dockerfile"
echo "  docker/entrypoint.sh"
echo "  docker/docker-compose.prod.yml"
echo "  docker-compose.yml"
echo "  .dockerignore"
echo "  .github/workflows/deploy.yml"
