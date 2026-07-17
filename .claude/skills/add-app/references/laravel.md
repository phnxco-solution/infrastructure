# Laravel apps

Source files: `templates/laravel/`. Worked example: `apps/buduci-klasici/` +
the buduci-klasici repo (commits `7cb7a43`, `4f22064`).

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

## When the Vite build needs PHP

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

Without it, verified by `scripts/probe-proxy.php`:

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
   just into the ssr image. (`BundleDetector` looks for `bootstrap/ssr/{ssr,app}.{js,mjs}`.)
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
artifact found in Phase 0. Non-negotiable: `public/hot`, `public/build`, `bootstrap/ssr`.
Drop template lines that don't apply (`storage/clockwork`, `!.env.production`,
`docker-compose.yml`) rather than carrying dead entries.
