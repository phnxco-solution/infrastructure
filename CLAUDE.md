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

**Firewall:** 80/443 are Cloudflare-only, enforced in two layers — UFW (host) **and** a `DOCKER-USER` rule with a Cloudflare ipset (`scripts/firewall-docker.sh`, persisted by `docker-cloudflare-firewall.service`) because **Docker bypasses UFW**. SSH is on **41922**, key-only, `AllowUsers deploy`.

## Gotchas (provisioning / migration)

- **Ubuntu 22.10+ SSH socket activation**: `ssh.socket` owns the listen port and ignores `sshd_config`'s `Port`. `setup.sh` disables it, enables `ssh.service`, and restarts. **Reboot after `setup.sh`** (new kernel + a stale sshd can linger on 22). Confirm `ssh -p 41922 deploy@ip` in a second terminal before closing root.
- **Root needs `authorized_keys`** before `setup.sh` — it copies root→deploy and `set -e` aborts if root has no key.
- **Docker bypasses UFW**: container-published 80/443 aren't protected by UFW alone. `firewall-docker.sh` (DOCKER-USER + Cloudflare ipset, run on boot by the systemd unit) enforces Cloudflare-only. Verify off-CF: `curl -I http://<ip>/` must time out.
- **GHCR login required on the VPS** (as `deploy`) before pulling private app images, else `compose pull` → `unauthorized`.
- **Ownership**: `chown -R deploy:deploy /opt/infrastructure` if anything was touched as root. **Never** chown `/opt/volumes` — container UIDs (`999`) own their data dirs and refuse otherwise.
- **DNS last**: don't repoint a host until its app container is up on the target VPS, or Traefik returns 404.
- `cron.allow` is `644` (setgid `crontab` must read it); only `deploy` may SSH (`AllowUsers deploy`).
- **DB GUI over SSH** (TablePlus → dockerized MySQL `127.0.0.1:3306`): the SSH hardening sets `AllowTcpForwarding local` — if it's ever `no`, the GUI logs in but the tunnel is refused ("Failed to create tunnel"). The tunnel user is `deploy`; connection type must be **MySQL** (8.4 uses `caching_sha2_password`), not MariaDB.
- Provider-panel firewall (Hostinger) is separate from UFW — must allow 41922/80/443.

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
| mega-catering | app.megacatering.rs (separate CF zone) | Laravel 12 + Vue 3 |
| phnx-solution | phnx-solution.com | Nuxt 4 SSR (coming-soon page) |
| endlessly | endlessly.phnx-solution.com | Nuxt 3 SSR |
| blogmana | mana.phnx-solution.com | Nuxt SSR |
| unimaginable | unimaginable-api.phnx-solution.com | Laravel 12 (API) |
| unimaginable-app | unimaginable.phnx-solution.com | Vite SPA (Vue 3 PWA) |
| unimaginable-landing | unimaginable.rs (separate CF zone) | Static site (nginx, files in volume) |
| voucher-tracker | voucher-tracker.phnx-solution.com | Nuxt 4 SSR + MySQL (Drizzle) |
| buduci-klasici | buduci-klasici.phnx-solution.com | Laravel 13 + Vue 3 (Inertia SSR) |
| uptime-kuma | status.phnx-solution.com | Uptime monitoring |

Traefik dashboard: traefik.phnx-solution.com

## Adding a New App

**Use the `add-app` skill** (`/add-app`, or just ask to add a new app). It detects what
the app actually needs, scaffolds both repos, verifies the stack locally, commits, and
hands back the manual steps and `gh` commands.

`templates/{laravel,nuxt,spa}/` are file **sources** the skill copies and customises —
not a plan. Copying them verbatim is how you get a Node-only frontend stage that can't
build a Wayfinder app, or an image with `public/hot` in it. The `init.sh` scripts that
used to do that were removed for exactly this reason.

Doing it by hand anyway: read `.claude/skills/add-app/references/detect.md` first, and
`env-contract.md` before writing any `.env` — Laravel's defaults are all
production-wrong and every one of them fails silently.

Traefik auto-discovers via labels, so no other infrastructure change is needed. Every
app still needs, and nothing creates for you: the `/opt/volumes/apps/<name>/storage`
skeleton, a MySQL database and user, and `.env` in `apps/<name>/`.

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

# Log into GHCR (once per VPS, as deploy) — needed to pull private app images
echo '<ghcr-pat>' | docker login ghcr.io -u <github-user> --password-stdin

# Re-apply / inspect the Docker→Cloudflare firewall
sudo systemctl restart docker-cloudflare-firewall.service
sudo iptables -S DOCKER-USER

# Fix repo ownership after root operations (NEVER chown /opt/volumes)
sudo chown -R deploy:deploy /opt/infrastructure

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
| **Site 404 / down** | App container not up, GHCR not logged in, or DNS not proxied | `cd /opt/infrastructure/apps/<name> && docker compose ps`; `docker login ghcr.io` |
| **Origin reachable off-Cloudflare** | DOCKER-USER firewall not applied | `sudo systemctl status docker-cloudflare-firewall; sudo iptables -S DOCKER-USER` |

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
