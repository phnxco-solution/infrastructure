# buduci-klasici

buduci-klasici.phnx-solution.com — Laravel 13 + Vue 3 + Inertia v3 (SSR).
Repo: `phnxco-solution/buduci-klasici`. A classic-car workshop: public booking,
customer portal, admin desk.

Worked example for the `add-app` skill — the app that motivated most of what's in
`.claude/skills/add-app/references/`.

## Services

| Service | Why it exists |
|---|---|
| `app` | php-fpm. Alias `buduci-klasici-fpm` for nginx. |
| `nginx` | Traefik-facing, Vite assets baked into the image. |
| `worker` | Six Mailables implement `ShouldQueue` (booking, proposal, confirmation mail). |
| `ssr` | Inertia SSR on `buduci-klasici-ssr:13714`. **Fails soft** — if it's down, Inertia swallows the error and serves client-side; verified to still return HTTP 200. No `env_file`: it renders from the request payload and has no use for the app's secrets. ~83M resident against a 192M limit. |

**No scheduler** — no `Schedule::` anywhere in `routes/console.php`, `bootstrap/app.php`
or `app/`, and `app/Console/Commands` is empty.

## Required .env

Full contract in `.claude/skills/add-app/references/env-contract.md`. The ones specific
to this app, all of which fail *silently*:

| Key | Value | If wrong |
|---|---|---|
| `DB_CONNECTION` | `mysql` | Defaults to `sqlite`. `DB_HOST` is ignored, `DB_DATABASE` is read as a filename, migrations run into a throwaway file and report success while MySQL stays empty. This happened on the first deploy. |
| `CACHE_STORE` | `redis` | Defaults to `database` → the worker crash-loops reading `illuminate:queue:restart` from a DB that isn't there. |
| `REDIS_QUEUE_RETRY_AFTER` | `120` | Defaults to `90`, equal to the worker's `--timeout=90`. Jobs can run twice. |
| `INERTIA_SSR_URL` | `http://buduci-klasici-ssr:13714` | Falls back to `127.0.0.1`, unreachable from `app` → SSR silently off, site still fine. |
| `APP_LOCALE` | `sr` | SSR renders per this. |
| `MAIL_MAILER` | `smtp` | `log` = bookings notify nobody. |

Verify with `docker compose exec -T app php artisan about`.

## First boot

```bash
sudo mkdir -p /opt/volumes/apps/buduci-klasici/storage/{app/public,framework/{cache/data,sessions,views},logs}
sudo chown -R 82:82 /opt/volumes/apps/buduci-klasici/storage
```

Not optional — the volume shadows the image's `storage/`, and `php artisan optimize`
can't write its view cache into an empty one, so the container dies on boot. `82` is
`www-data` in `php:8.4-fpm-alpine`.

Then create the MySQL database and user (nothing does it automatically), write `.env`,
and point DNS **last**. No cert work: `*.phnx-solution.com` rides Traefik's default
`origin.pem`.

## Quirks

**The Vite build needs PHP and `vendor/`, not just Node.** `@laravel/vite-plugin-wayfinder`
shells out to `php artisan wayfinder:generate` on `buildStart`, and `laravel-vue-i18n`
reads the framework's translations out of `vendor/`. The Laravel template's Node-only
frontend stage cannot build this app, so `docker/Dockerfile` is a single file with
`production`, `nginx` and `ssr` targets sharing one `frontend` stage built on the PHP
base with Node copied in from `node:22-alpine` (pinned — `apk add nodejs` gives 24).

**`VITE_APP_NAME` is a build arg.** Vite inlines it at build time and `.env` isn't in the
build context; without it every page title renders "Laravel".

**Three app-side changes were needed to deploy this correctly**, all in the app repo:

- `bootstrap/app.php` — `trustProxies(at: '*')`. Without it, `$request->isSecure()` is
  false behind Traefik, so signed proposal links (signed `https`, verified `http`) 403
  for every customer, and the booking throttle keys everyone to Traefik's IP.
- `config/inertia.php` — `url` made env-driven; it was pinned to `127.0.0.1`.
- `resources/js/app.ts` — i18n locale read from `page.props.locale`. `laravel-vue-i18n`
  reads `<html lang>`, which doesn't exist server-side, so SSR rendered English on a
  Serbian site and the client then hydrated to Serbian.
