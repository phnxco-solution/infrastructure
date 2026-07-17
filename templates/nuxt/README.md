# Nuxt SSR Docker Template

Docker template for Nuxt 3/4 SSR apps. Single Node.js container behind Traefik — no nginx sidecar needed.

## Quick Start

Use the **`add-app` skill** (`/add-app`). It copies these files, substitutes
`{{APP_NAME}}`/`{{APP_DOMAIN}}`, customises them against what the app actually needs,
verifies the stack locally, and creates `apps/<name>/docker-compose.yml`.

These are sources, not a finished setup. Two assumptions baked in here bite hard:
the Dockerfile copies Drizzle migration files unconditionally (the build fails for a
Nuxt app without Drizzle), and the entrypoint only runs migrations when
`NODE_ENV != production`. See `.claude/skills/add-app/references/nuxt.md`.

## Files

| File | Purpose |
|------|---------|
| `docker/Dockerfile` | Multi-stage: development, build, production |
| `docker/entrypoint.sh` | Runs drizzle-kit migrations on startup |
| `docker/docker-compose.prod.yml` | Production compose with Traefik labels |
| `docker-compose.yml` | Local development (app + MySQL) |
| `.dockerignore` | Excludes node_modules, .output, .nuxt, etc. |
| `.github/workflows/deploy.yml` | CI/CD: build image, deploy to VPS |

## Placeholders

| Placeholder | Where | Example |
|-------------|-------|---------|
| `{{APP_NAME}}` | prod compose, deploy workflow | `endlessly` |
| `{{APP_DOMAIN}}` | prod compose | `endlessly.phnx-solution.com` |

## Local Development

```bash
docker compose up
```

- App runs at `http://localhost:3000` (or `$APP_PORT`)
- MySQL at `localhost:3307` (or `$EXTERNAL_DB_PORT`)
- Source is volume-mounted with hot reload
- `node_modules` in a named volume to avoid host conflicts

### .env for local dev

```
DB_HOST=mysql
DB_PORT=3306
DB_USER=root
DB_PASSWORD=secret
DB_NAME=nuxt
```

### Database Access

```bash
# MySQL shell
docker compose exec mysql mysql -uroot -p<DB_PASSWORD> <DB_NAME>

# Run a seed file
docker compose exec -T mysql mysql -uroot -p<DB_PASSWORD> <DB_NAME> < seed.sql

# Run a Drizzle seed script
docker compose exec app npx tsx db/seed.ts

# Reset MySQL data (recreates database from scratch)
docker compose down -v
docker compose up
```

## Production

### VPS Setup

```bash
# Create storage directory
mkdir -p /opt/volumes/apps/<app-name>/storage
chown 1000:1000 /opt/volumes/apps/<app-name>/storage

# Pull infrastructure repo (compose file is already in apps/<name>/)
cd /opt/infrastructure && git pull

# Add .env with production values
nano /opt/infrastructure/apps/<app-name>/.env
```

### Environment Variables

```
NODE_ENV=production
DB_HOST=mysql
DB_PORT=3306
DB_USER=<database-user>
DB_PASSWORD=<from infrastructure .env>
DB_NAME=<database-name>
NUXT_SESSION_PASSWORD=<32+ char random string>
```

`DB_HOST=mysql` works because the container joins the `backend` network where MySQL is accessible — same as Laravel apps.

### Architecture

```
Internet → Cloudflare → Traefik (traefik-public) → Nuxt app (port 3000)
                                                         |
                                                    backend network
                                                         |
                                                       MySQL
```

Single container on both networks:
- `traefik-public` — Traefik routes HTTPS traffic to port 3000
- `backend` — app connects to MySQL

### Deploy

Pushes to `main` trigger the GitHub Actions workflow:
1. Builds production Docker image
2. Pushes to GHCR
3. SSHs to VPS, pulls image, recreates container from `/opt/infrastructure/apps/<name>/docker-compose.yml`

## Customization

- **Memory limit**: Default 256M in prod compose. Adjust in the infrastructure repo's `apps/<name>/docker-compose.yml`
- **Migration path**: Default `server/database/migrations/`. Change in Dockerfile if your project uses a different path
- **Build tools**: `python3 make g++` installed in dev/build stages for native addons (sharp, bcrypt). Remove if not needed
- **Storage volume**: Mounted at `/app/storage`. Remove from compose if not needed

## Troubleshooting

### HMR not working in Docker

Add to `nuxt.config.ts`:

```ts
vite: {
  server: {
    watch: {
      usePolling: true,
    },
  },
},
```
