# Nuxt SSR apps

Source files: `templates/nuxt/`. Live examples: `apps/voucher-tracker`, `apps/endlessly`,
`apps/blogmana`, `apps/phnx-solution`.

> Less battle-tested than `references/laravel.md`. What follows is read off the templates
> and the deployed composes, not proven through a full onboarding. Run the Phase 0 and
> Phase 4 protocols exactly as for Laravel — they're stack-agnostic — and treat anything
> here as a hypothesis until a command's output confirms it.

## Shape

One service, `web`. Nitro serves the app **and** its static assets, so there is no nginx
sidecar and no second image.

```
web  ->  node .output/server/index.mjs  ->  :3000  ->  traefik-public
```

The service is named `web`, not `app`, deliberately: its DNS alias on the shared
`traefik-public` network would otherwise collide with every other project's `app`.
Keep that name. Traefik's `loadbalancer.server.port` must be `3000`.

Networks: `traefik-public` + `backend` (drop `backend` if it touches neither MySQL nor
Redis). Volumes: `/app/storage` and `/app/logs`.

## Template assumptions to check

| Assumption | Reality | Check |
|---|---|---|
| The app uses Drizzle | The Dockerfile hardcodes `COPY --from=build /app/server/database/migrations` and `drizzle.config.ts`, and installs `drizzle-kit drizzle-orm mysql2` into `/migrate`. **Those COPY lines fail the build for any Nuxt app without Drizzle.** | `grep -n "drizzle" package.json` |
| It's an SSR app | A prerendered/static Nuxt is nginx + a volume (`apps/unimaginable-landing`), not a Node service at all. | `nuxt.config` `ssr:` / `nitro.preset` |
| Native addons | The build stage installs `python3 make g++` for sharp/bcrypt. Drop it if nothing needs compiling. | `grep -n "sharp\|bcrypt" package.json` |
| Health at `/` | Traefik and the container healthcheck both hit `/`. Fine unless `/` is expensive or redirects. | — |

## Migrations do not run at boot

The entrypoint's migrate branch is inverted from what you'd expect:

```sh
if [ "$NODE_ENV" != "production" ]; then
    ./node_modules/.bin/drizzle-kit migrate
```

The production compose sets `NODE_ENV: production`, so **this never fires in production**
— by design, mirroring Laravel's entrypoint. Production migrations belong in the deploy
workflow. Verify the workflow actually runs them before claiming migrations are handled.

## Logging

The entrypoint tees stdout through a FIFO into `/app/logs/app-YYYY-MM-DD.log`, but only
when `NODE_ENV=production`, `/app/logs` exists, **and** the command's basename is
`dumb-init`. Change `CMD` away from `dumb-init` and daily logging silently stops. The
`/opt/volumes/apps/<name>/logs` mount must exist or logs go nowhere; a cron in
`setup.sh` prunes them at 14 days.

## Env

- **`NUXT_PUBLIC_*` are runtime** — they belong in the VPS `.env` via `env_file`, and
  changing them needs a container recreate, not a rebuild.
- **`VITE_*` / anything read via `import.meta.env` at build time bakes in** — those need
  build args, exactly as in `references/laravel.md`. Grep for both in Phase 0; they fail
  differently and the build-time ones fail silently.

## Verification

`references/verify.md` applies, minus the php-fpm and proxy probes. Still mandatory:
build the image, run it, `curl` a real page, and confirm the HTML is server-rendered
rather than an empty root. Check `<title>` and any build-time env actually landed.
