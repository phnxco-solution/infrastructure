# synapse

synapse.phnx-solution.com: Synapse staging (`APP_ENV=staging`), Laravel 13 on PHP 8.5 serving a
Vue 3 SPA (no Inertia, no SSR). Repo: phnxco-solution/synapse. Its `docs/deployment.md` describes
the release pipeline; this file covers the VPS side.

## Services

| Service | Why it exists |
|---|---|
| app | php-fpm; the release also runs the migrations with its image |
| nginx | Traefik-facing, static files baked in; reaches php-fpm only through the `fpm-socket` volume |
| worker | the password reset email is queued (`ResetPasswordNotification implements ShouldQueue`) |
| voice-blue, voice-green | the voice service (`services/voice`, Node) in two slots, of which one takes the calls; Traefik sends it only `/media-stream` |

No scheduler: there is no `Schedule::` anywhere, and `routes/console.php` holds only `inspire`.
Add one with the first scheduled task.

## Required .env

```dotenv
APP_NAME=Synapse
APP_ENV=staging
APP_KEY=                       # php artisan key:generate --show
APP_DEBUG=false
APP_URL=https://synapse.phnx-solution.com

DB_CONNECTION=mysql
DB_HOST=mysql
DB_PORT=3306
DB_DATABASE=synapse
DB_USERNAME=synapse
DB_PASSWORD=

REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=                # from /opt/infrastructure/.env
CACHE_STORE=redis
SESSION_DRIVER=redis
SESSION_SECURE_COOKIE=true
QUEUE_CONNECTION=redis
REDIS_QUEUE_RETRY_AFTER=120    # must exceed the worker's --timeout=90

LOG_CHANNEL=daily

MAIL_MAILER=log                # until the transactional email account exists
MAIL_FROM_ADDRESS=
MAIL_FROM_NAME=Synapse
```

- `APP_ENV` must never be `local`: there, `000000` passes two-factor authentication, so the image
  refuses to start with it and the release fails instead of going live.
- `APP_NAME` prefixes the Redis keys, the cache and the session cookie (`synapse-…`), which keeps
  them apart from the other apps on the shared Redis.
- `APP_URL` must be the https address: trusted hosts answer every other host with a 400, and the
  queued reset email builds its link from it.
- With `MAIL_MAILER=log`, reset emails only reach `storage/logs`.

## First boot

```bash
cd /opt/infrastructure && git pull

sudo mkdir -p /opt/volumes/apps/synapse/storage/{app/public,framework/{cache/data,sessions,views},logs}
sudo chown -R 82:82 /opt/volumes/apps/synapse/storage
```

Database, as MySQL root:

```sql
CREATE DATABASE synapse CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'synapse'@'%' IDENTIFIED BY '<password>';
GRANT ALL PRIVILEGES ON synapse.* TO 'synapse'@'%';
FLUSH PRIVILEGES;
```

Then write `.env` next to this file, register the backup (below), and set the Synapse repo's
GitHub secrets: `VPS_HOST`, `VPS_PORT`, `VPS_USER` and `VPS_SSH_KEY` as for every app, plus
`VPS_KNOWN_HOSTS`, the VPS's SSH host keys, which the release pins. Scan them against the exact
`VPS_HOST` value (`ssh-keyscan -p 41922 <VPS_HOST>`), since a hostname and an IP don't match. There is no `GHCR_PAT`: the release pulls with the workflow's own token. Push the
app's `master` to release, then point a proxied Cloudflare A record for `synapse` at the VPS.

Create the first account, which sets up two-factor authentication at its first sign-in:

```bash
cd /opt/infrastructure/apps/synapse
docker compose exec app php artisan app:create-super-admin
```

Check it:

```bash
docker compose ps
docker compose exec -T app php artisan about
docker compose exec -T app php artisan tinker --execute '$t = microtime(true); Hash::make("x"); echo round((microtime(true) - $t) * 1000), " ms\n";'
```

`about` must show staging, mysql and redis. One password hash must take well under 600 ms, the
app's auth timebox, so sign-in timing never reveals whether an account exists.

## Backups

Included: `"synapse": {"database": "auto", "owner": [82, 82]}` in `backups/config.example.json`.
82:82 is `www-data` in `php:8.5-fpm-alpine`, read off the image. Merge the same entry into
`/etc/infrastructure-backup/config.json` on the VPS, then run
`sudo /opt/infrastructure/backups/backup.sh check` once the database and storage exist.
VPS registration, preflight and the first uploaded set are pending.

## Quirks

- **The release goes further than the Laravel template.** Like the template, it runs
  `docker/deploy.sh` over SSH with the host key pinned and pulls with the workflow's own token.
  On top of that, the checks gate it, the images are smoke-tested against MySQL 8.4 before they
  are pushed, a failed release retags the previous images as `latest` and brings them back up,
  and only a successful one moves `latest` in GHCR.
- **The one-off migrate container is labelled `autoheal=False`.** It inherits the app's FPM health
  check but never starts php-fpm, so it turns unhealthy and autoheal would kill a slow migration.
  It also runs without `--isolated`: a stale lock makes that exit 0 and skip the migrations, and
  the workflow already keeps releases from overlapping.
- **The voice service runs in two slots, so a release never cuts a call.** `voice-blue` and
  `voice-green` share one Traefik service. The release starts the new image in the idle slot and,
  once it is healthy, stops the other in the background. Stopping, a slot answers 503 on `/up`, so
  Traefik sends new calls elsewhere, and gives its live calls up to `stop_grace_period` (11 minutes)
  to end; `VOICE_MAX_CALL_SECONDS` in the compose file must stay 15 seconds or more below it.
  Docker watches `/live`, which answers while the process runs, and turns a slot unhealthy, so
  autoheal restarts it, only after a minute without an answer. A plain `docker compose up -d`
  is safe too: it starts the idle slot while the other finishes its calls before it restarts.
- **The worker health check is `pgrep -f '[a]rtisan queue:work'`.** Without the brackets pgrep
  matches its own `sh -c` and the check always passes.
- **Trusted proxies are listed, not `'*'`.** In Laravel 13, `trustProxies(at: '*')` trusts every
  address, so `request()->ip()` becomes the leftmost `X-Forwarded-For` entry, which the visitor
  sets: rate limits and audit IPs can then be spoofed. Synapse trusts Docker's private ranges, where
  Traefik connects from, and Cloudflare's ranges, which Traefik appends to `X-Forwarded-For`, and
  only `X-Forwarded-For` and `X-Forwarded-Proto`. Keep its list in step with `traefik/traefik.yml`.
- **php-fpm has no network port.** It listens on `/run/php/php-fpm.sock` in the `fpm-socket`
  volume, which only `app` and `nginx` mount. So `app` sits on `backend` alone and `nginx` on
  `traefik-public` alone, and no other app's container can send FastCGI requests to it. The
  volume is tmpfs, so the backup preflight knows it holds nothing to back up.
- **The health check sends the Host header.** Traefik checks Laravel's `/up` with
  `healthcheck.hostname`, because trusted hosts answer a bare container address with a 400, and
  Traefik would then take the site down with a 503.
- **One Dockerfile, two targets.** `production` and `nginx` share one frontend build, which is
  Node-only. The PHP image adds only `pdo_mysql`, `pcntl` and `redis`; nginx is 1.30, and OPcache
  runs without JIT.
