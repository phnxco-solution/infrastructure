# Infrastructure

Shared Docker infrastructure for all apps on a Hostinger VPS (4GB RAM / 2 CPU).

## Stack

- **Traefik v3.3** — reverse proxy, auto-discovers containers via Docker labels
- **MySQL 8.4** — shared database, tuned for 4GB VPS (384M buffer pool, performance_schema OFF)
- **Redis 7 Alpine** — cache, queues, sessions (128mb maxmemory, allkeys-lru, password-protected)

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
├── infrastructure/       # This repo (cloned here)
├── apps/<app-name>/      # Each app repo cloned here
│   ├── docker/           # Dockerfile, compose, nginx, entrypoint
│   └── .env              # Production secrets (not in git)
├── volumes/
│   ├── mysql/            # MySQL data
│   ├── redis/            # Redis data
│   └── apps/<name>/storage/  # Laravel storage dirs
└── backups/
    ├── mysql/            # Daily dumps (14-day retention)
    └── volumes/          # Weekly tars (30-day retention)
```

## Current Apps

| App | Domain | Type |
|-----|--------|------|
| mega-catering | mega-catering.phnx-solution.com | Laravel 12 + Vue 3 |
| we-kwik-gene | wekwikgene.phnx-solution.com | Laravel 12 + Vue 3 |
| phnx-solution | phnx-solution.com | Static HTML |
| endlessly | endlessly.phnx-solution.com | Nuxt 3 SSR |

Traefik dashboard: traefik.phnx-solution.com

## Adding a New App

1. Add Docker files to the app repo: `docker/Dockerfile`, `docker/entrypoint.sh`, `docker/nginx.conf`, `docker/docker-compose.prod.yml`, `.dockerignore`
2. Add `.github/workflows/deploy.yml` (build → GHCR → SSH deploy)
3. Clone repo to `/opt/apps/<name>/` on VPS, add `.env`
4. Traefik auto-discovers via labels — no infrastructure changes needed

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
cd /opt/apps/<name> && docker compose -f docker/docker-compose.prod.yml up -d

# View logs
docker compose logs -f <service>

# Run backup manually
/opt/infrastructure/backups/backup.sh
```
