# demo-endlessly

endlessly.phnx-solution.com — Nuxt 4 SSR. Repo: `phnxco-solution/endlessly`

Second deployment of the **same app and the same image** as `apps/endlessly`, used as a
public demo for screenshots and presentation. Own database, own storage, no shared state
with production.

## Services

| Service | Why it exists |
|---|---|
| app | Nitro node server on :3000. Alias `demo-endlessly-node` on the project's default network |
| nginx | Traefik-facing. Answers `/health` and serves `/uploads/` straight off the storage volume |

**nginx is load-bearing, not an optimisation.** Verified by request: `/uploads/probe.txt`
returns 200 through nginx, but the same path requested directly from Nitro on :3000
returns `302 → /login` — the app's auth middleware intercepts it and the file is never
served. Collapsing this to the single-service shape used by `blogmana` / `voucher-tracker`
would 404 every uploaded photo.

No worker, no scheduler: the app has neither: the only out-of-request work is
`drizzle-kit migrate`, which the deploy workflow runs as a one-shot `compose run`.

## Required .env

```
DB_HOST=mysql
DB_PORT=3306
DB_USER=demo_endlessly
DB_PASSWORD=<generated>
DB_NAME=demo_endlessly
NUXT_SESSION_PASSWORD=<32+ chars, MUST differ from production endlessly>
```

`NODE_ENV=production` comes from compose, not `.env`.

Traps:

- **`NUXT_SESSION_PASSWORD` must differ from `apps/endlessly`.** `nuxt-auth-utils` seals
  the session cookie with it, and both sites are under `phnx-solution.com` /
  `dusanimarija.cloud`. Reusing the value means a session minted on one is valid on the
  other. Minimum 32 characters or `nuxt-auth-utils` throws at boot.
- `nuxt.config.ts` has a **hardcoded fallback** session password. Omitting the variable
  does not fail loudly; it silently uses the public default from the repo.
- **`DB_NAME` must not be `endlessly`.** Nothing stops the demo pointing at production's
  database, and a demo writing into it looks like a working deploy.

## First boot

```bash
# Storage skeleton. Chown by NUMBER: the image ends `USER node` = uid 1000, and on
# this VPS `deploy` is 1001 (usanzadunje holds 1000). Creating the tree as either
# root or deploy leaves it unwritable by the container.
mkdir -p /opt/volumes/apps/demo-endlessly/storage/uploads /opt/volumes/apps/demo-endlessly/logs
chown -R 1000:1000 /opt/volumes/apps/demo-endlessly
docker compose exec -T app touch /app/storage/.probe && echo writable
```

Mode 755 owned by 1001 is the trap: the container can read and traverse, so the site
renders normally and only writes fail. Uploads recover as soon as ownership is fixed,
but `docker/entrypoint.sh` opens its daily-log file once at container start — if that
failed, `docker compose restart app` is needed to get logging back.

```sql
CREATE DATABASE demo_endlessly CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'demo_endlessly'@'%' IDENTIFIED BY '<password>';
GRANT ALL PRIVILEGES ON demo_endlessly.* TO 'demo_endlessly'@'%';
FLUSH PRIVILEGES;
```

DNS: proxied A record for `endlessly.phnx-solution.com` → VPS IP. One label under
`phnx-solution.com`, so the default `origin.pem` covers it — no `tls.yml` entry needed.

## Quirks

- **One image, two sites.** `deploy.yml` in the app repo loops
  `DEPLOY_TARGETS: endlessly demo-endlessly`, migrating and recreating each in turn.
  Production is deployed first, so if the demo trips, prod is already live.
- Safe because the two compose projects have distinct `name:` values — `--remove-orphans`
  filters on the `com.docker.compose.project` label, so neither project can reap the
  other's containers. Verified by running `--remove-orphans` in one project against a
  live container in another.
- **Memory is trimmed below prod** (192M/32M vs endlessly's 256M/64M) because this is
  presentational only. Not lower: `nuxt.config.ts` points `@nuxt/image`'s ipx at the
  storage dir, so sharp resizes real photos in-process. Measured idle: app 47 MiB,
  nginx 14 MiB.
- Deploys on every push to the app repo's `main`, same as production. If you need the
  demo pinned to an older build, drop it from `DEPLOY_TARGETS` and update it by hand.
