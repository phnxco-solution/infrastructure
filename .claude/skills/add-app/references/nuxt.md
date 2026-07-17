# Nuxt SSR apps

Source files: `templates/nuxt/`. Live examples: `apps/voucher-tracker`, `apps/endlessly`,
`apps/blogmana`, `apps/phnx-solution`.

> Less battle-tested than `references/laravel.md`: read off the templates and the deployed
> composes, plus one build test. Run the Phase 0 and Phase 4 protocols exactly as for
> Laravel — they're stack-agnostic — and treat anything here as a hypothesis until a
> command's output confirms it.

App repos live in `~/Projects/www/personal/`. Note `phnx-solution` there is **not** the
app — it's an unrelated workspace. The deployed app builds from
`phnx-solution-coming-soon`. Match the repo to `image:` in `apps/<name>/docker-compose.yml`
rather than trusting the directory name.

## Shape

The template is one service, `web` — Nitro serves the app and its static assets, so no
nginx sidecar and no second image.

```
web  ->  node .output/server/index.mjs  ->  :3000  ->  traefik-public
```

Named `web`, not `app`, deliberately: its DNS alias on the shared `traefik-public`
network would otherwise collide with every other project's `app`. Traefik's
`loadbalancer.server.port` must be `3000`.

**That's the template's shape, not a rule.** `apps/endlessly` is an older shape that
does have an nginx sidecar: service `app` (alias `endlessly-node`) plus `nginx`, which
mounts the storage volume read-only at `/data` to serve uploads directly instead of
pushing them through Nitro. If an app serves user uploads, that's the reason to add a
sidecar — and then `nginx` is the Traefik-facing service and `/health` is its endpoint.

Networks: `traefik-public` + `backend` (drop `backend` if it touches neither MySQL nor
Redis — `apps/phnx-solution` has no database and is on neither). Volumes: `/app/storage`
and `/app/logs`.

## What goes where

`templates/nuxt/README.md` has the file list and what to customise. Two things it's worth
knowing before you open it:

- **`docker/docker-compose.prod.yml` → `<infra>/apps/<name>/docker-compose.yml`.** It's a
  template file that lands in the *infra* repo under a different name, and is not copied
  into the app repo. Same for all three stacks; Phase 3 depends on it.
- Substitute `{{APP_NAME}}` and `{{APP_DOMAIN}}`, then prove none survive with
  `grep -rn "{{[A-Z_]*}}" docker/ .github/ <infra>/apps/<name>/` — match the pattern, not
  a memorised list.

There is no `Dockerfile.nginx` and no `nginx.conf` in this template.

## Template assumptions to check

| Assumption | Reality | Check |
|---|---|---|
| The app uses Drizzle | **Confirmed by build test.** The Dockerfile installs `drizzle-kit drizzle-orm mysql2` into `/migrate`, then COPYs `server/database/migrations`, `drizzle.config.ts` and `/migrate/node_modules`. `COPY --from` of a missing path is a hard failure: a non-Drizzle app dies with `ERROR: "/app/server/database/migrations": not found` after `npm run build` has already succeeded. Delete **all four** — Nitro's `.output` is self-contained, so a non-Drizzle app needs no production `node_modules`. Both blocks are marked `DRIZZLE ONLY` in the template. Worked example: `phnx-solution-coming-soon`. | `grep -n "drizzle" package.json` |
| It's an SSR app | A prerendered/static Nuxt is nginx + a volume (`apps/unimaginable-landing`), not a Node service at all. | `nuxt.config` `ssr:` / `nitro.preset` |
| Native addons | The build stage installs `python3 make g++` for sharp/bcrypt. Drop it if nothing needs compiling. | `grep -n "sharp\|bcrypt" package.json` |
| Health at `/` | Traefik and the container healthcheck both hit `/`. Fine unless `/` is expensive or redirects. | — |

## Migrations do not run at boot — by design

The entrypoint's migrate branch reads oddly at first glance:

```sh
if [ "$NODE_ENV" != "production" ]; then
    ./node_modules/.bin/drizzle-kit migrate
```

The production compose sets `NODE_ENV: production`, so this never fires there. **That is
correct, not a bug** — it mirrors Laravel's entrypoint exactly. Production migrations
belong in the deploy workflow, which runs

```
docker compose run --rm -T web ./node_modules/.bin/drizzle-kit migrate
```

*before* `compose up -d --wait`, so the new image migrates while the old container still
serves traffic. Verified in the template workflow and in all three Drizzle apps.

Two deviations that are deliberate, not drift:

- `apps/endlessly` migrates service `app`, not `web` — its compose names the service
  `app` (the older sidecar shape above). Match the service name to the compose.
- `blogmana` rewrote its entrypoint to migrate on **every** start, and keeps the workflow
  step too. Idempotent — drizzle-kit tracks applied migrations in `__drizzle_migrations`.
  A defensible different choice.
- `phnx-solution` has no migrate step at all, correctly: no database, no `backend`
  network, signups go to a flat file.

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
