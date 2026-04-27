# SPA Docker Template

Docker template for static single-page apps built with Vite (Vue, React, Svelte, etc.). Single nginx container behind Traefik — no Node.js runtime in production. Optionally proxies `/api` and `/storage` to a sibling backend container so the SPA stays same-origin.

## What's Included

| File | Purpose |
|------|---------|
| `docker/Dockerfile.nginx` | Multi-stage: Node build → nginx serve |
| `docker/nginx.conf` | SPA fallback, PWA-aware cache headers, optional backend proxy |
| `docker/docker-compose.prod.yml` | Production compose with Traefik labels (uses `{{APP_NAME}}`, `{{APP_DOMAIN}}`) |
| `.dockerignore` | Excludes node_modules, dist, etc. |
| `.github/workflows/deploy.yml` | GHA: build single image, deploy via SSH (uses `{{APP_NAME}}`) |

## Quick Start

```bash
# From your app's repo root:
bash /path/to/infrastructure/templates/spa/init.sh <app-name> <app-domain> [backend-host]
```

Examples:

```bash
# SPA with backend proxy (same-origin /api and /storage)
bash /opt/infrastructure/templates/spa/init.sh unimaginable-app unimaginable.phnx-solution.com unimaginable-nginx-1:80

# Pure static SPA (no backend) — proxy blocks are stripped
bash /opt/infrastructure/templates/spa/init.sh marketing-site marketing.phnx-solution.com
```

This copies Docker files into the app repo, replaces `{{APP_NAME}}` / `{{APP_DOMAIN}}` / `{{BACKEND_HOST}}` placeholders, and creates `apps/<name>/docker-compose.yml` in the infrastructure repo.

## Placeholders

| Placeholder | Where | Example |
|-------------|-------|---------|
| `{{APP_NAME}}` | prod compose, deploy workflow | `unimaginable-app` |
| `{{APP_DOMAIN}}` | prod compose | `unimaginable.phnx-solution.com` |
| `{{BACKEND_HOST}}` | `docker/nginx.conf` | `unimaginable-nginx-1:80` |

## Architecture

```
Internet → Cloudflare → Traefik (traefik-public) → nginx (port 80)
                                                       |
                                                  /api/, /storage/   (optional)
                                                       ↓
                                              backend network
                                                       ↓
                                                <backend>-nginx-1
```

The SPA's nginx serves static files for everything except `/api/*` and `/storage/*`, which are proxied to the backend container over the internal `backend` Docker network. The browser never sees a second origin, so no CORS configuration is needed and audio range requests, cookies, and service worker caching all just work.

## Cache Headers

The nginx config is tuned for PWAs:

| Path | Cache-Control |
|------|---------------|
| `/sw.js`, `/registerSW.js`, `/manifest.webmanifest` | `public, max-age=0, must-revalidate` (no cache) |
| `/assets/*`, `/workbox-*.js` | `public, immutable` (1 year — content hashed) |
| `*.png`, `*.svg`, etc. | `public, max-age=7d` |
| Everything else | nginx default → SPA fallback to `/index.html` |

## Local Development

The template does **not** include a local `docker-compose.yml`. Run `npm run dev` natively for fastest feedback. Vite's HMR doesn't benefit from a Docker wrapper for a pure SPA.

## Production

### VPS Setup

```bash
# Pull infrastructure repo (compose file is already in apps/<name>/)
cd /opt/infrastructure && git pull

# No .env or storage volume needed — the SPA is fully self-contained.
```

### Customizing the proxy upstream

Open `docker/nginx.conf` and change the `proxy_pass http://...` directives if your backend container name or port differs. The container name format produced by Docker Compose v2 is `<project>-<service>-<index>` (e.g., the Laravel template's nginx becomes `<app>-nginx-1`).

For more stable cross-project routing, add a network alias on the backend nginx in its compose file:

```yaml
networks:
  backend:
    aliases:
      - <app>-backend
```

Then proxy to `http://<app>-backend` from the SPA.

### Memory

Default 64M per container — pure nginx serving static files is cheap. Adjust in `apps/<name>/docker-compose.yml` if you start serving larger volumes of media directly.

### Deploy

Pushes to `main` trigger the workflow:
1. Builds the nginx image (Node build inside Docker)
2. Pushes to GHCR
3. SSHs to the VPS, pulls the image, recreates the container

There is no migration step — the image is fully self-contained.

## Customization

- **Build command**: defaults to `npm run build`. Edit `docker/Dockerfile.nginx` if you use `pnpm` or a different command.
- **Build output**: defaults to `dist/`. Change the COPY line if your bundler uses a different output dir.
- **Cache headers**: tune `docker/nginx.conf` to match your bundler's output naming conventions.
- **Health endpoint**: `/health` returns 200 — Traefik uses it. Don't remove unless you change the labels.
