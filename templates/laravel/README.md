# Laravel Docker Template

Production-ready Docker setup for Laravel + Vue apps on the shared infrastructure.

## What's Included

| File | Purpose |
|------|---------|
| `docker/Dockerfile` | Multi-target PHP image (dev + production), OPcache with JIT, Redis, GD |
| `docker/Dockerfile.nginx` | Nginx image with baked-in frontend assets (no shared volumes) |
| `docker/entrypoint.sh` | CONTAINER_ROLE-based startup: migrations, storage link, optimize |
| `docker/nginx.conf` | Gzip, fastcgi buffering, static asset caching, health endpoint (uses `{{APP_NAME}}` for the fpm upstream) |
| `docker/docker-compose.prod.yml` | Production template: app, nginx, worker, scheduler (uses `{{APP_NAME}}`, `{{APP_DOMAIN}}`). **Goes to `apps/<name>/docker-compose.yml` in the infra repo**, not into the app repo. |
| `docker-compose.yml` | Local dev: app, vite, nginx, worker, scheduler, mysql, redis |
| `.dockerignore` | Excludes node_modules, vendor, tests, etc. from Docker context |
| `.github/workflows/deploy.yml` | GHA: builds 2 images (app + nginx), deploys via SSH (uses `{{APP_NAME}}`) |

## Quick Start

Use the **`add-app` skill** (`/add-app`). It copies these files, substitutes the
placeholders, customises them against what the app actually needs, verifies the stack
locally, and creates `apps/<name>/docker-compose.yml`.

These are sources, not a finished setup. Read the section below before assuming this
Dockerfile can build your app — the `frontend` stage is Node-only and a good number of
Laravel apps can't be built that way.

## Placeholders

Three files contain placeholders:

| Placeholder | Files | Example |
|-------------|-------|---------|
| `{{APP_NAME}}` | `docker/docker-compose.prod.yml`, `.github/workflows/deploy.yml`, `docker/nginx.conf` | `mega-catering` |
| `{{APP_DOMAIN}}` | `docker/docker-compose.prod.yml` | `mega-catering.phnx-solution.com` |

`docker/nginx.conf` is the one that gets missed — `{{APP_NAME}}` there is the fpm
upstream (`{{APP_NAME}}-fpm:9000`) and must match the network alias in the production
compose. Left unsubstituted, nginx fails to parse its config and the container won't
start. After substituting, check nothing survived:

```bash
grep -rn "{{APP_NAME}}\|{{APP_DOMAIN}}" docker/ .github/ /path/to/infrastructure/apps/<name>/
```

**The deploy trigger differs per template** — this one fires on `master`; the nuxt and
spa templates fire on `main`. Match it to the app's default branch or the deploy never
runs, silently.

## What to Customize

The template includes all services by default (vite, worker, scheduler). Remove what your project doesn't need — e.g. drop `scheduler` if there are no scheduled commands, `worker` if there are no queued jobs, or `vite` if there's no frontend.

- **Dockerfile** — remove PHP extensions you don't need (gd, intl, bcmath, etc.) or add new ones
- **Dockerfile** — adjust `pm.max_children` in the FPM pool config based on available memory
- **nginx.conf** — adjust `client_max_body_size` if your app handles larger uploads
- **docker-compose.prod.yml** — adjust memory limits per service

## When the Vite build needs PHP

The `frontend` stage in `Dockerfile` and `Dockerfile.nginx` is Node-only. That
breaks for apps whose Vite build reaches back into PHP:

- **`@laravel/vite-plugin-wayfinder`** shells out to `php artisan wayfinder:generate`
  on `buildStart`. No PHP, no `vendor/`, and the build fails outright.
- **`laravel-vue-i18n`** reads the framework's own translations out of
  `vendor/laravel/framework/src/Illuminate/Translation/lang/`. Without `vendor/`
  it doesn't fail — it just bundles without them, and validation messages go
  missing at runtime.

These need the frontend stage to run on the PHP base with `vendor/` copied in and
Node added, rather than `node:22-alpine`. Quick tell: if the app's CI runs
`composer install` before `npm run build`, the Docker build has to as well.

`apps/buduci-klasici` is the worked example. It also folds `Dockerfile.nginx` into
`Dockerfile` as a target, so the (now much more expensive) frontend stage is built
once rather than once per image.

## Staging vs production deploys

The Dockerfile defaults to `composer install --no-dev` (production-correct).
For a staging/dev server where you want faker, ide-helper, pest, etc.
available (e.g. for `db:seed --force`), uncomment the `build-args` block
in `.github/workflows/deploy.yml`:

```yaml
build-args: |
  COMPOSER_NO_DEV=
```

For a real production deploy, leave it commented or remove it and the
`--no-dev` default takes effect.

## Architecture

**Two images are built per app:**
- `ghcr.io/phnxco-solution/<app>:latest` — PHP-FPM with app code and compiled assets
- `ghcr.io/phnxco-solution/<app>-nginx:latest` — Nginx with baked-in static assets

**Entrypoint handles startup tasks** (only for `CONTAINER_ROLE=app`):
- Runs migrations (`--force --isolated` in production)
- Creates storage symlink
- Runs `php artisan optimize` (caches config, routes, views)

**No `docker compose run` needed during deploy** — the entrypoint handles migrations on container start.

## Production Notes

**Worker** uses `--memory=128` as a soft limit so it exits gracefully before hitting Docker's 192M hard ceiling. The `--timeout=90` per-job limit pairs with `stop_grace_period: 120s` to allow the current job to finish on shutdown.

**Scheduler** uses `schedule:work` (foreground daemon, no cron needed). For tasks that must not run twice if you ever scale to multiple containers, add `->onOneServer()` in your schedule definitions — works out of the box with Redis as cache driver.

**Both worker and scheduler** wait for the app container to be healthy before starting (`depends_on`), ensuring migrations have run. Both have healthchecks so Autoheal can restart stuck processes.

**Redis queue config** — set these in your app's `config/queue.php` Redis connection:
- `retry_after: 120` — must be greater than the worker's `--timeout=90`, otherwise jobs can execute twice
- `block_for: 5` — Redis blocks efficiently instead of polling in a tight loop, and SIGTERM is still handled every 5s
