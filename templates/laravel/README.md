# Laravel Docker Template

Production-ready Docker setup for Laravel + Vue apps on the shared infrastructure.

## What's Included

| File | Purpose |
|------|---------|
| `docker/Dockerfile` | Multi-target PHP image (dev + production), OPcache with JIT, Redis, GD |
| `docker/Dockerfile.nginx` | Nginx image with baked-in frontend assets (no shared volumes) |
| `docker/entrypoint.sh` | CONTAINER_ROLE-based startup: migrations, storage link, optimize |
| `docker/nginx.conf` | Gzip, fastcgi buffering, static asset caching, health endpoint |
| `docker/docker-compose.prod.yml` | Production services: app, nginx, worker, scheduler (uses `{{APP_NAME}}`, `{{APP_DOMAIN}}`) |
| `docker-compose.yml` | Local dev: app, vite, nginx, worker, scheduler, mysql, redis |
| `.dockerignore` | Excludes node_modules, vendor, tests, etc. from Docker context |
| `.github/workflows/deploy.yml` | GHA: builds 2 images (app + nginx), deploys via SSH (uses `{{APP_NAME}}`) |

## Quick Start

Copy the templates into your app repo during development. The files become part of the app repo and get cloned to the VPS with it.

```bash
# From your app's repo root:
bash /path/to/infrastructure/templates/laravel/init.sh my-app my-app.phnx-solution.com
```

This copies all files and replaces `{{APP_NAME}}`/`{{APP_DOMAIN}}` placeholders.

## Placeholders

Only two files contain placeholders:

| Placeholder | Files | Example |
|-------------|-------|---------|
| `{{APP_NAME}}` | `docker/docker-compose.prod.yml`, `.github/workflows/deploy.yml` | `mega-catering` |
| `{{APP_DOMAIN}}` | `docker/docker-compose.prod.yml` | `mega-catering.phnx-solution.com` |

## What to Customize

The template includes all services by default (vite, worker, scheduler). Remove what your project doesn't need — e.g. drop `scheduler` if there are no scheduled commands, `worker` if there are no queued jobs, or `vite` if there's no frontend.

- **Dockerfile** — remove PHP extensions you don't need (gd, intl, bcmath, etc.) or add new ones
- **Dockerfile** — adjust `pm.max_children` in the FPM pool config based on available memory
- **nginx.conf** — adjust `client_max_body_size` if your app handles larger uploads
- **docker-compose.prod.yml** — adjust memory limits per service

## Architecture

**Two images are built per app:**
- `ghcr.io/phnxco-solution/<app>:latest` — PHP-FPM with app code and compiled assets
- `ghcr.io/phnxco-solution/<app>-nginx:latest` — Nginx with baked-in static assets

**Entrypoint handles startup tasks** (only for `CONTAINER_ROLE=app`):
- Runs migrations (`--force --isolated` in production)
- Creates storage symlink
- Runs `php artisan optimize` (caches config, routes, views)

**No `docker compose run` needed during deploy** — the entrypoint handles migrations on container start.
