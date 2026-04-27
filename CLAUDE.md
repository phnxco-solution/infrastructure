# Infrastructure

Shared Docker infrastructure for all apps on a Hostinger VPS (4GB RAM / 2 CPU).

## Stack

- **Traefik v3.6** — reverse proxy, auto-discovers containers via Docker labels
- **MySQL 8.4** — shared database, tuned for 4GB VPS (384M buffer pool, performance_schema OFF)
- **Redis 7 Alpine** — cache, queues, sessions (128mb maxmemory, allkeys-lru, password-protected)
- **Uptime Kuma** — self-hosted uptime monitoring with Slack/email alerts (runs on same VPS — pair with external monitor like UptimeRobot for VPS-level coverage)
- **Autoheal** — auto-restarts unhealthy containers using Docker healthchecks

No Meilisearch, no Soketi (add when needed).

## Architecture

```
Internet → Cloudflare (DNS+SSL) → VPS:443 → Traefik (traefik-public network)
                                                |
                                    nginx sidecars (per app, Traefik labels)
                                        |
                                    php-fpm / node containers
                                        |
                                    backend network
                                        |
                                  MySQL + Redis
```

Two Docker networks:
- `traefik-public` — Traefik routes to app nginx containers
- `backend` — apps talk to MySQL and Redis

## VPS Directory Structure

```
/opt/
├── infrastructure/              # This repo (cloned here)
│   ├── docker-compose.yml       # Traefik, MySQL, Redis, etc.
│   ├── apps/                    # Per-app production compose + .env
│   │   ├── mega-catering/
│   │   │   ├── docker-compose.yml
│   │   │   └── .env             # Production secrets (not in git)
│   │   ├── endlessly/
│   │   │   ├── docker-compose.yml
│   │   │   └── .env
│   │   └── phnx-solution/
│   │       ├── docker-compose.yml
│   │       └── .env
│   └── ...
├── volumes/
│   ├── mysql/                   # MySQL data
│   ├── redis/                   # Redis data
│   ├── uptime-kuma/             # Uptime Kuma data
│   └── apps/<name>/
│       ├── storage/             # Laravel/Nuxt storage dirs
│       └── logs/                # Nuxt daily logs (app-YYYY-MM-DD.log)
└── backups/
    ├── mysql/                   # Daily dumps (14-day retention)
    └── volumes/                 # Weekly tars (30-day retention)
```

## Current Apps

| App | Domain | Type |
|-----|--------|------|
| mega-catering | mega-catering.phnx-solution.com | Laravel 12 + Vue 3 |
| phnx-solution | phnx-solution.com | Static HTML |
| endlessly | endlessly.phnx-solution.com | Nuxt 3 SSR |
| unimaginable | api.unimaginable.phnx-solution.com | Laravel 12 (API) |
| unimaginable-app | unimaginable.phnx-solution.com | Vite SPA (Vue 3 PWA) |
| uptime-kuma | status.phnx-solution.com | Uptime monitoring |

Traefik dashboard: traefik.phnx-solution.com

## Adding a New App

1. Run `init.sh` from the template (`templates/laravel/`, `templates/nuxt/`, or `templates/spa/`) — copies Docker files into the app repo and creates a production compose file in `apps/<name>/`
2. Customize as needed (remove unused PHP extensions, adjust memory limits, add scheduler)
3. On VPS: `git pull` the infrastructure repo, add `.env` to `apps/<name>/`
4. Traefik auto-discovers via labels — no other infrastructure changes needed

## Docker Networking for App .env

```
DB_HOST=mysql
REDIS_HOST=redis
REDIS_PASSWORD=<from infrastructure .env>
QUEUE_CONNECTION=redis
CACHE_STORE=redis
SESSION_DRIVER=redis
```

## Commands

```bash
# Start infrastructure
cd /opt/infrastructure && docker compose up -d

# Start an app
cd /opt/infrastructure/apps/<name> && docker compose up -d

# View logs
docker compose logs -f <service>

# Run backup manually
/opt/infrastructure/backups/backup.sh

# Verify OS hardening
bash /opt/infrastructure/scripts/verify-setup.sh

# Migration: pack data on old VPS
bash /opt/infrastructure/scripts/migrate-pack.sh [--dry-run]

# Migration: restore data on new VPS
bash /opt/infrastructure/scripts/migrate-unpack.sh /path/to/tarball [--verify-only]

# Verify migration
bash /opt/infrastructure/scripts/verify-migration.sh
```

## Debugging / Logs

When something breaks, here's where to look:

| What broke | Where to look | Command |
|------------|---------------|---------|
| **Laravel app** | Docker logs (real-time) | `docker logs <app>-app-1 --tail 100` |
| | Persistent daily logs | `cat /opt/volumes/apps/<name>/storage/logs/laravel-$(date +%Y-%m-%d).log` |
| | Worker/scheduler | Same files — shares mounted storage volume |
| **Nuxt app** | Docker logs (real-time) | `docker logs <app>-app-1 --tail 100` |
| | Persistent daily logs | `cat /opt/volumes/apps/<name>/logs/app-$(date +%Y-%m-%d).log` |
| **Nginx sidecar** | Docker logs | `docker logs <app>-nginx-1 --tail 100` |
| **Traefik** | Docker logs (WARN+ only) | `docker logs traefik --tail 100` |
| **MySQL** | Docker logs | `docker logs mysql --tail 100` |
| | Slow query log | `docker exec mysql cat /var/lib/mysql/slow.log` |
| **Redis** | Docker logs | `docker logs redis --tail 100` |
| **Container restarts** | Autoheal + Docker events | `docker events --filter event=restart --since 1h` |

**Log retention:**
- Docker json-file logs: 3 x 10MB (daemon config), lost on container recreation
- Laravel daily logs: 14 days (Laravel default `LOG_DAILY_DAYS`)
- Nuxt daily logs: 14 days (cron cleanup in `scripts/setup.sh`)
- MySQL slow log: rotated weekly (cron in `scripts/setup.sh`)

**Quick searches:**
```bash
# Search Laravel logs for errors today
grep -i error /opt/volumes/apps/<name>/storage/logs/laravel-$(date +%Y-%m-%d).log

# Search Nuxt logs for errors today
grep -i error /opt/volumes/apps/<name>/logs/app-$(date +%Y-%m-%d).log

# Find which container restarted recently
docker ps --filter "status=running" --format "{{.Names}} {{.Status}}" | grep -i restart
```
