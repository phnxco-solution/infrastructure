# The app .env contract

`/opt/infrastructure/apps/<name>/.env`, never in git. Injected via `env_file:`.

The danger here is that **every wrong value fails silently**. Laravel's defaults are all
locally-sensible and production-wrong, so a misconfigured app deploys green, reports
healthy, and misbehaves. Read this whenever a deploy "succeeds" but the app is off.

## Contents

- [Silent defaults](#silent-defaults)
- [env_file is not a .env file](#env_file-is-not-a-env-file)
- [The template](#the-template)
- [The one command that proves it](#the-one-command-that-proves-it)

## Silent defaults

| Key | Laravel default | Symptom when left alone |
|---|---|---|
| `DB_CONNECTION` | **`sqlite`** | The worst one. `DB_HOST=mysql` is *ignored*; `DB_DATABASE=<name>` is read as a **SQLite filename**. `migrate` cheerfully creates a throwaway sqlite file inside the `--rm` container and reports 18 migrations DONE — while MySQL stays empty and the running app has no database at all. Log tell: `WARN The SQLite database configured for this application does not exist` followed by `INFO Preparing database.` |
| `CACHE_STORE` | `database` | Cache reads hit the DB. With sqlite the **worker crash-loops**: `select * from "cache" where "key" in (<app>-cache-illuminate:queue:restart)`. Double-quoted identifiers in a log = sqlite/pgsql, never MySQL. |
| `SESSION_DRIVER` | `database` | Sessions in the DB instead of Redis. |
| `QUEUE_CONNECTION` | `database` | The worker's `queue:work redis` argument overrides the connection, so the queue itself still works — which masks the fact that the cache is wrong. |
| `REDIS_QUEUE_RETRY_AFTER` | `90` | Equals the worker's `--timeout=90`. Jobs can execute twice. Must be higher. |
| `APP_ENV` | `production` | Fine — but the entrypoint keys off it: not `local` → runs `optimize` (caches config) instead of `migrate`. |

`.env.example` ships `DB_CONNECTION=sqlite` with the MySQL block commented out. Copying
it and uncommenting `DB_HOST`/`DB_DATABASE` without changing `DB_CONNECTION` is the exact
path to the failure above. **`DB_CONNECTION=mysql` is the single most important line.**

## env_file is not a .env file

Compose's `env_file` sets process environment variables. It does **not** run Laravel's
dotenv, so:

- **No variable interpolation.** `MAIL_FROM_NAME="${APP_NAME}"` copied from
  `.env.example` arrives as the literal string `${APP_NAME}`. Write literal values.
- **No `.env` file exists in the container.** `env()` reads `$_SERVER`, which PHP
  populates from the environment. This works — but `variables_order = "GPCS"` in
  `php.ini-production` means `$_ENV` is empty. Debug via `getenv()`/`$_SERVER`, not `$_ENV`.
- **Values are read only at container *create*.** Editing `.env` and restarting is not
  enough, and the entrypoint's `php artisan optimize` bakes a config cache at boot. Use
  `docker compose up -d --force-recreate`.

UTF-8 and quoted values do survive (`APP_NAME="Budući Klasici"` produced the correct
`buduci-klasici-cache-` prefix).

## The template

```dotenv
APP_NAME="<Display Name>"
APP_ENV=production
APP_KEY=                      # php artisan key:generate --show
APP_DEBUG=false
APP_URL=https://<domain>
APP_LOCALE=<locale>           # SSR renders per this
APP_FALLBACK_LOCALE=en

DB_CONNECTION=mysql           # <- without this nothing below matters
DB_HOST=mysql
DB_PORT=3306
DB_DATABASE=<db>
DB_USERNAME=<user>
DB_PASSWORD=<password>

REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=<from /opt/infrastructure/.env>

CACHE_STORE=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
REDIS_QUEUE_RETRY_AFTER=120   # must exceed the worker's --timeout=90

INERTIA_SSR_URL=http://<app>-ssr:13714   # only if the ssr service exists

MAIL_MAILER=smtp              # `log` = the app silently notifies nobody
MAIL_HOST=
MAIL_PORT=587
MAIL_USERNAME=
MAIL_PASSWORD=
MAIL_FROM_ADDRESS=
MAIL_FROM_NAME="<Display Name>"   # literal — no ${APP_NAME}
```

Add any `NUXT_*` runtime vars for Node apps. Do **not** put `VITE_*` here: those are
build-time and must be build args (`references/laravel.md`).

## The one command that proves it

```bash
docker compose exec -T app php artisan about
```

Reports Environment, Debug Mode, Cache, Database, Queue and Session in one shot — it
catches `DB_CONNECTION=sqlite` and `CACHE_STORE=database` together. Make this the
post-deploy check in every handoff.

If it still reports the old values, the config cache is stale: recreate, don't restart.
