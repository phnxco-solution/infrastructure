# gift-site-landing

pokloni-sajt.phnx-solution.com — Node 22 static landing page plus a Gmail inquiry form.
Repo: `phnxco-solution/gift-site-landing`

## Services

| Service | Why it exists |
|---|---|
| web | `node server/index.mjs` on :3000. Serves the prebuilt `dist/` and handles `POST /api/inquiry` |

No framework, no bundler: `npm run build` copies `public/` to `dist/`. The only runtime
dependency is nodemailer, installed from the vendored `vendor/nodemailer-10.0.10.tgz`.

Not an nginx-only SPA, because the form needs a server. `traefik-public` only: the app
uses neither MySQL nor Redis (no database client in `package.json`; rate limiting and
duplicate suppression are in-process `Map`s). It needs **outbound SMTP to
smtp.gmail.com:465**.

## Required .env

```
GMAIL_USER=<gmail address that sends the inquiries>
GMAIL_APP_PASSWORD=<16-char Google app password; spaces are stripped>
INQUIRY_TO=<the single address that receives inquiries>
SITE_ORIGIN=https://pokloni-sajt.phnx-solution.com
```

`NODE_ENV`, `HOST` and `PORT` come from compose and override `.env`. Don't copy them
over from the app README: its defaults (`127.0.0.1:5173`) are for local development.

Traps:

- **A missing or invalid Gmail value doesn't fail the boot.** The container starts
  healthy and the form returns 503. The startup log line shows which state you're in:
  `Gmail slanje je podešeno.` (configured) vs `Gmail nije podešen.` (not configured).
- **SMTP failures are not logged.** The handler swallows nodemailer errors and returns
  502, so a wrong app password leaves no trace in `docker logs`. Prove delivery with a
  real submission.
- `SITE_ORIGIN` is one of the accepted `Origin` values. The request's own `Host` is
  also accepted, so a wrong value doesn't break the form behind Traefik.

## First boot

```bash
# Nothing in the container writes to disk. The storage dir exists only because backup
# preflight requires it. Chown by number: the image runs as `node` = uid 1000.
mkdir -p /opt/volumes/apps/gift-site-landing/storage
chown -R 1000:1000 /opt/volumes/apps/gift-site-landing
```

DNS: proxied A record for `pokloni-sajt` in the `phnx-solution.com` zone, added after
the container is up. A single label under the zone, so it rides the default origin
cert.

## Backups

Included, with `database: null` and owner `[1000, 1000]` (the `node` user, checked with
`id` inside the image). There's no database and nothing persistent in storage, so the
archive's value is the app configuration (`.env` with the Gmail app password).

- Template: `backups/config.example.json` registers `gift-site-landing`.
- VPS: `"gift-site-landing": {"database": null, "owner": [1000, 1000]}` merged into
  `/etc/infrastructure-backup/config.json` on 2026-10-08.
- Preflight passed 2026-10-08: `gift-site-landing: database=(none), owner=[1000, 1000]`.
- First uploaded run: **pending**. Confirm after the next 03:00 run with
  `sudo /opt/infrastructure/backups/backup.sh list --source drive --app gift-site-landing`.

## Quirks

- **Healthcheck uses `127.0.0.1`, not `localhost`.** The server binds IPv4 only
  (`HOST=0.0.0.0`) and busybox `wget` resolves `localhost` to `::1` first. Verified
  locally: `localhost` → `Connection refused`, `127.0.0.1` → 200. The other Node apps
  get away with `localhost` because Nitro binds `::`.
- **Rate limit keys on `CF-Connecting-IP`.** Behind Traefik the socket peer is always
  Traefik, so the per-IP limit (5/min) would otherwise be shared by every visitor. The
  header is trusted only because the origin accepts Cloudflare traffic alone
  (`DOCKER-USER` ipset). Verified through Traefik: visitor A's 6th attempt → 429,
  visitor B → accepted.
- Memory: 24.6 MiB after 200 concurrent requests with nodemailer loaded; limit 128M.
