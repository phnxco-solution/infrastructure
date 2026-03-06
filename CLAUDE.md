# Infrastructure

Shared Docker infrastructure for all apps on a Hostinger VPS (4GB RAM / 2 CPU).

## Stack

- **Traefik v3.3** — reverse proxy, auto-discovers containers via Docker labels
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
│   └── apps/<name>/storage/     # Laravel/Nuxt storage dirs
└── backups/
    ├── mysql/                   # Daily dumps (14-day retention)
    └── volumes/                 # Weekly tars (30-day retention)
```

## Current Apps

| App | Domain | Type |
|-----|--------|------|
| mega-catering | mega-catering.phnx-solution.com | Laravel 12 + Vue 3 |
| we-kwik-gene | wekwikgene.phnx-solution.com | Laravel 12 + Vue 3 |
| phnx-solution | phnx-solution.com | Static HTML |
| endlessly | endlessly.phnx-solution.com | Nuxt 3 SSR |
| uptime-kuma | status.phnx-solution.com | Uptime monitoring |

Traefik dashboard: traefik.phnx-solution.com

## Adding a New App

1. Run `init.sh` from the template (`templates/laravel/` or `templates/nuxt/`) — copies Docker files into the app repo and creates a production compose file in `apps/<name>/`
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
docker compose -f /opt/infrastructure/apps/<name>/docker-compose.yml up -d

# View logs
docker compose logs -f <service>

# Run backup manually
/opt/infrastructure/backups/backup.sh
```
