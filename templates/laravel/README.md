# Laravel Docker Template

Production-ready Docker setup for Laravel + Vue apps on the shared infrastructure.

## What's Included

| File | Purpose |
|------|---------|
| `docker/Dockerfile` | Multi-target PHP image (dev + production), OPcache with JIT, Redis, GD |
| `docker/Dockerfile.nginx` | Nginx image with baked-in frontend assets (no shared volumes) |
| `docker/entrypoint.sh` | CONTAINER_ROLE-based startup: migrations, storage link, optimize |
| `docker/nginx.conf` | Gzip, fastcgi buffering, static asset caching, health endpoint |
| `docker/docker-compose.prod.yml` | Production services: app, nginx, worker (uses `{{APP_NAME}}`, `{{APP_DOMAIN}}`) |
| `docker-compose.yml` | Local dev: app, vite, nginx, worker, mysql, redis |
| `.dockerignore` | Excludes node_modules, vendor, tests, etc. from Docker context |
| `.github/workflows/deploy.yml` | GHA: builds 2 images (app + nginx), deploys via SSH (uses `{{APP_NAME}}`) |

## Quick Start

```bash
# From your Laravel app's repo root:
APP_NAME="my-app"
APP_DOMAIN="my-app.phnx-solution.com"

# Copy all template files
cp -r /opt/infrastructure/templates/laravel/docker ./docker
cp /opt/infrastructure/templates/laravel/.dockerignore ./.dockerignore
cp /opt/infrastructure/templates/laravel/docker-compose.yml ./docker-compose.yml
mkdir -p .github/workflows
cp /opt/infrastructure/templates/laravel/.github/workflows/deploy.yml .github/workflows/deploy.yml

# Replace placeholders
sed -i "s/{{APP_NAME}}/$APP_NAME/g" docker/docker-compose.prod.yml .github/workflows/deploy.yml
sed -i "s/{{APP_DOMAIN}}/$APP_DOMAIN/g" docker/docker-compose.prod.yml
```

## Placeholders

Only two files contain placeholders:

| Placeholder | Files | Example |
|-------------|-------|---------|
| `{{APP_NAME}}` | `docker/docker-compose.prod.yml`, `.github/workflows/deploy.yml` | `mega-catering` |
| `{{APP_DOMAIN}}` | `docker/docker-compose.prod.yml` | `mega-catering.phnx-solution.com` |

## What to Customize

- **Dockerfile**: Remove PHP extensions you don't need (gd, intl, bcmath, etc.) or add new ones
- **Dockerfile**: Adjust `pm.max_children` in the FPM pool config based on available memory
- **nginx.conf**: Adjust `client_max_body_size` if your app handles larger uploads
- **docker-compose.prod.yml**: Adjust memory limits per service
- **docker-compose.prod.yml**: Add a scheduler service if the app has scheduled commands:

```yaml
  scheduler:
    image: ghcr.io/phnxco-solution/<app-name>:latest
    restart: unless-stopped
    env_file: ../.env
    command: php artisan schedule:work
    networks:
      - backend
    deploy:
      resources:
        limits:
          memory: 64M
```

## Architecture

**Two images are built per app:**
- `ghcr.io/phnxco-solution/<app>:latest` — PHP-FPM with app code and compiled assets
- `ghcr.io/phnxco-solution/<app>-nginx:latest` — Nginx with baked-in static assets

**Entrypoint handles startup tasks** (only for `CONTAINER_ROLE=app`):
- Runs migrations (`--force --isolated` in production)
- Creates storage symlink
- Runs `php artisan optimize` (caches config, routes, views)

**No `docker compose run` needed during deploy** — the entrypoint handles migrations on container start.
