# Laravel apps

Source files: `templates/laravel/`. Worked example: `apps/buduci-klasici/` +
the buduci-klasici repo (commits `7cb7a43`, `4f22064`).

## What goes where

Copy into the **app repo**, then substitute:

| Template source | Destination | Placeholders |
|---|---|---|
| `docker/Dockerfile` | `docker/Dockerfile` | — |
| `docker/Dockerfile.nginx` | `docker/Dockerfile.nginx` | — |
| `docker/entrypoint.sh` | `docker/entrypoint.sh` | — |
| `docker/nginx.conf` | `docker/nginx.conf` | `{{APP_NAME}}` (the fpm upstream — easy to miss) |
| `.dockerignore` | `.dockerignore` | — |
| `.github/workflows/deploy.yml` | `.github/workflows/deploy.yml` | `{{APP_NAME}}` |
| `docker/docker-compose.prod.yml` | **`<infra>/apps/<name>/docker-compose.yml`** | `{{APP_NAME}}`, `{{APP_DOMAIN}}` |

The last row is the one to notice: the production compose is a template file that lands
in the *infra* repo under a different name, and is **not** copied into the app repo.

The template also ships `docker-compose.yml` (local dev, with MySQL and Redis). Skip it
unless the app actually wants that — most apps here have their own local workflow
(`php artisan dev` + sqlite) that a MySQL compose would contradict. Skipping it also
makes the Dockerfile's `development` target dead weight; drop that too.

After substituting, prove none survive — every stack, every placeholder, not just this
table's:

```bash
grep -rn "{{[A-Z_]*}}" docker/ .github/ <infra>/apps/<name>/
```

Match the pattern, not a memorised list: SPA adds `{{BACKEND_HOST}}` and greping for
Laravel's two returns clean while it ships.

How a survivor fails is not consistent, so don't rely on noticing it:

- `{{APP_NAME}}` in `nginx.conf` is unquoted (`set $fpm_upstream {{APP_NAME}}-fpm:9000;`)
  → nginx won't parse its config, the container won't start. Loud.
- `{{APP_NAME}}` in `deploy.yml` → pushes to a nonsense image name.
- `{{BACKEND_HOST}}` in the SPA's `nginx.conf` is **quoted** → parses fine, container
  starts, site serves, and every `/api` and `/storage` request fails at runtime on a DNS
  lookup for a host called `{{BACKEND_HOST}}`. Silent.

## Contents

- [Image layout](#image-layout)
- [When the Vite build needs PHP](#when-the-vite-build-needs-php)
- [Build-time env](#build-time-env)
- [Trusted proxies — applies to every Laravel app here](#trusted-proxies--applies-to-every-laravel-app-here)
- [Services](#services)
- [Queue settings that must agree](#queue-settings-that-must-agree)
- [Inertia SSR contract](#inertia-ssr-contract)
- [.dockerignore](#dockerignore)

## Image layout

Two images normally: `<app>` (php-fpm) and `<app>-nginx`. Three with SSR.

The template ships `Dockerfile` + `Dockerfile.nginx`, each with its own Node-only
`frontend` stage — the frontend is built **twice**. That's tolerable when the stage is
`node:22-alpine` + `npm ci`. It is not tolerable once the stage needs PHP, composer
install and vendor.

**When the build needs PHP, collapse into one Dockerfile with targets**
(`base`, `composer-deps`, `frontend`, `production`, `nginx`, `ssr`) and build each image
with `--target`. The frontend stage then builds once and every image reuses it. Give all
targets **one shared gha cache scope** so the expensive stages are cached across runs.

Drop the `development` target unless a local dev compose is actually shipped. Most apps
here have their own local workflow (`php artisan dev` + sqlite) and a compose with MySQL
would contradict it.

## The base stage

Trim extensions against Phase 0 evidence, not the template's defaults (it ships gd, zip,
bcmath and DomPDF fonts; most apps need none). Keep `pdo_mysql, mbstring, xml, dom,
pcntl, opcache` + `redis`. `pcntl` is not optional with a worker — it handles SIGTERM.

**`intl` needs `icu-data-full` on Alpine.** `icu-dev` alone pulls `icu-data-en`, and ICU
then falls back to English for any other locale — *silently*. `Number::format($n, locale:
'sr')` prints `198,450` instead of `198.450`. Nothing fails; the number is just wrong.
Local machines and CI runners have full ICU, so every gate passes and only the container
is broken:

```dockerfile
RUN apk add --no-cache \
    icu-dev \
    icu-data-full \    # not optional — icu-dev alone is English-only
    ...
```

This is the shape of bug the verify phase exists for: a passing build, a healthy
container, and wrong output. If the app is not English-only, render a page with a
formatted number or date in Phase 4 and read it.

`@laravel/vite-plugin-wayfinder` runs `php artisan wayfinder:generate` on `buildStart`.
`laravel-vue-i18n` reads `vendor/laravel/framework/src/Illuminate/Translation/lang/`.

Failure modes differ, and the quiet one is worse:

- **wayfinder**: no PHP → build fails loudly. Fine.
- **laravel-vue-i18n**: no `vendor/` → **build succeeds**, silently omitting the
  framework's translations. Validation messages go missing at runtime.

Fix — base the frontend stage on the PHP base and bring Node in, pinned:

```dockerfile
FROM base AS frontend
# Node from the official image, not apk: apk tracks Alpine's release and drifts
# off the version CI and the ssr stage use.
RUN apk add --no-cache libstdc++
COPY --from=node:22-alpine /usr/local/bin/node /usr/local/bin/node
COPY --from=node:22-alpine /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm
COPY package.json package-lock.json .npmrc ./
RUN npm ci
COPY --from=composer-deps /app/vendor ./vendor
COPY . .
RUN npm run build          # or build:ssr
```

Order matters: `npm ci` before `COPY . .` keeps the dependency layer cached. `vendor`
survives the later `COPY . .` because `.dockerignore` excludes it from the context.

Artisan boots fine here without `.env` or `APP_KEY` — nothing in a stock provider needs
encryption at boot. Copy `.npmrc` so the container build honours the repo's install
behaviour (e.g. `ignore-scripts=true`); Alpine/musl handles it fine despite `-gnu`
pins in `optionalDependencies`, which are inert under Vite 8's rolldown.

## Build-time env

Vite inlines `VITE_*` at build time and `.env` is not in the build context, so anything
read via `import.meta.env` bakes in **empty**. `VITE_APP_NAME` is the usual casualty:
every page title renders `"Laravel"`.

```dockerfile
ARG VITE_APP_NAME="App Name"
ENV VITE_APP_NAME=${VITE_APP_NAME}
RUN npm run build
```

Place `ARG`/`ENV` after `npm ci` so changing the name doesn't bust the dependency layer.
Vite's `loadEnv` merges prefix-matching `process.env` keys, so `ENV` is enough. Grep for
every `import.meta.env.VITE_*` in Phase 0 and give each one a build arg.

## Trusted proxies — applies to every Laravel app here

TLS terminates at Traefik and reaches php-fpm as plain http. Laravel trusts no proxies
unless told to, so `bootstrap/app.php` **must** contain:

```php
$middleware->trustProxies(at: '*');
```

Without it — verified by this skill's `scripts/probe-proxy.php`, run per
`references/verify.md`:

- `$request->ip()` returns Traefik's container IP → every IP-keyed rate limiter shares
  one bucket site-wide, so a throttle meant as spam defence locks out real users
- `$request->isSecure()` is false → `$request->url()` is `http://`
- **signed URLs 403**: `URL::signedRoute()` signs `https://` (from `APP_URL`, in a
  queued Mailable), `hasValidSignature()` rebuilds `http://` → mismatch. Every emailed
  signed link is dead.

`at: '*'` rather than a CIDR: nothing but Traefik can reach fpm, Traefik only answers
Cloudflare (UFW + the DOCKER-USER ipset), and Docker's subnets move.

## Services

Include only what Phase 0 proved:

| Service | Include when | Memory |
|---|---|---|
| `app` | always | 256M |
| `nginx` | always | 64M |
| `worker` | `implements ShouldQueue` found | 192M |
| `scheduler` | `Schedule::` found | 128M |
| `ssr` | Inertia SSR chosen | 192M (measures ~83M) |

`app` needs `default` (with a `<app>-fpm` alias for nginx) **and** `backend`. `worker`
needs `backend`. `nginx` needs `default` + `traefik-public`. `ssr` needs only `default`.

**`ssr` gets no `env_file`** — it renders from the request payload and has no business
holding DB/Redis credentials.

The storage volume shadows the image's `storage/`, so it must exist and be seeded before
first boot — see `references/handoff.md`. Keep it even with no uploads: logs live there.

### The workflow is the other half of the service list

`templates/laravel/.github/workflows/deploy.yml:98` hardcodes:

```
docker compose up -d --no-deps worker scheduler
```

Drop the scheduler per Phase 0 and leave that line alone → `no such service: scheduler`,
**exit 1 under `set -e`**, after app and nginx are already up. Working site, red deploy,
and `docker image prune` never runs. The template workflow also never builds or starts
`ssr`; with SSR on, add the `--target ssr` build/push step and put `ssr` in the up line
(app → ssr → nginx → worker).

Every service added or dropped in `apps/<name>/docker-compose.yml` has a matching edit in
`deploy.yml`. One decision, two files. The same trap exists on Nuxt: its workflow runs
`drizzle-kit migrate` unconditionally, so a non-Drizzle app needs that step removed too.

## Queue settings that must agree

The worker runs `--timeout=90`. `config/queue.php` redis defaults to
`env('REDIS_QUEUE_RETRY_AFTER', 90)`. **Equal is a bug** — `retry_after` must exceed the
timeout or a job can run twice. Set `REDIS_QUEUE_RETRY_AFTER=120` in the VPS `.env`
(no code change needed; it's already env-driven).

## Inertia SSR contract

Four things must all hold. Miss any one and SSR silently degrades to client-side
rendering — the site still works, so it's easy to ship broken.

1. **The bundle must be in the app image.** `HttpGateway` short-circuits when
   `BundleDetector::detect()` finds nothing on disk, *before* any HTTP call. So
   `COPY --from=frontend .../bootstrap/ssr ./bootstrap/ssr` into `production` too, not
   just into the ssr image. (`BundleDetector` checks `config('inertia.ssr.bundle')` first,
   then `bootstrap/ssr/{ssr,app}.{js,mjs}`, then `public/js/{ssr,app}.js` — first hit wins,
   so the commented-out `bundle` line in the stock config is fine to leave alone.)
2. **The URL must be env-driven.** `config/inertia.php` hardcodes
   `'url' => 'http://127.0.0.1:13714'`, unreachable from a sibling container:
   ```php
   'url' => env('INERTIA_SSR_URL', 'http://127.0.0.1:13714'),
   ```
   then `INERTIA_SSR_URL=http://<app>-ssr:13714` in the VPS `.env`, with a matching
   network alias on the ssr service.
3. **The SSR image needs production `node_modules`.** The bundle externalises `vue`,
   `@inertiajs/vue3`, `reka-ui` etc. — it is not self-contained:
   ```dockerfile
   FROM node:22-alpine AS ssr
   WORKDIR /var/www/html
   COPY package.json package-lock.json .npmrc ./
   RUN npm ci --omit=dev && npm cache clean --force
   COPY --from=frontend /var/www/html/bootstrap/ssr ./bootstrap/ssr
   USER node
   CMD ["node", "bootstrap/ssr/app.js"]
   ```
   The bundle self-hosts via `createServer()` on 13714 and serves `/health` and
   `/render`. Healthcheck with busybox wget: `wget -q -O /dev/null http://127.0.0.1:13714/health`.
4. **i18n locale must come from the page, not `<html lang>`.** `laravel-vue-i18n` sets
   `lang: !isServer && document.documentElement.lang ? ... : null` and falls back to
   `fallbackLang`. There is no `document` on the server, so **SSR renders English** while
   the client hydrates to the real locale — a visible flash and a hydration mismatch:
   ```ts
   withApp(app, { page }) {
       app.use(i18nVue, { lang: page.props.locale, fallbackLang: 'en', resolve: ... });
   }
   ```
   Same value on the client, so CSR behaviour is unchanged. Add `locale: string` to the
   `sharedPageProps` declaration in `resources/js/types/global.d.ts`.

Inertia v3 needs no `resources/js/ssr.ts` — `@inertiajs/vite` uses `app.ts` as the SSR
entry, and `laravel-vite-plugin` writes to `bootstrap/ssr/`.

**Deploy order**: app → ssr → nginx → worker. SSR down is a clean CSR fallback (verified:
still HTTP 200), so it never takes the site with it — but bring it up before traffic.

## .dockerignore

Start from `templates/laravel/.dockerignore`, then add every gitignored-but-locally-present
artifact found in Phase 0. Non-negotiable: `public/hot`, `public/build`, `bootstrap/ssr`,
`database/*.sqlite`.

That last one is easy to miss and it corrupts the verify phase. Laravel hides it in a
nested `database/.gitignore` (`*.sqlite*`), so it never shows in the repo root's
`.gitignore` — but `COPY database ./database` in the production stage pulls it in, and a
developer's local sqlite is typically hundreds of KB of real data. Consequences:

- Phase 4's `touch database/database.sqlite && php artisan migrate --force` finds an
  already-migrated file, prints **"Nothing to migrate"**, and the stack you verify serves
  the developer's local data while looking green.
- The image ships that data to GHCR.

CI is unaffected (fresh checkout, file gitignored) — which is exactly why only the local
verify build sees it, and exactly where the skill's "verify by running it" claim lives.
Look for nested `.gitignore` files, not just the root one:

```bash
find . -name .gitignore -not -path "./node_modules/*" -not -path "./vendor/*"
```

Drop template lines that don't apply (`storage/clockwork`, `!.env.production`,
`docker-compose.yml`) rather than carrying dead entries.
