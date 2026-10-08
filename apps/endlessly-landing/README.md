# endlessly-landing

sajt-za-dvoje.phnx-solution.com — Nuxt 4 landing page ("Sajt za dvoje") plus a Gmail
inquiry form. Repo: `phnxco-solution/endlessly-landing` (local:
`~/Projects/www/personal/endlessly-landing`, branch `master`).

## Services

| Service | Why it exists |
|---|---|
| web | `node .output/server/index.mjs` on :3000. Serves the prerendered `/` and handles `GET`/`POST /api/inquiry` |

`/` is prerendered at build time (`nitro.prerender.routes: ['/']`), so Nitro serves it
as a static file. Not an nginx-only site, because the form needs a server. The
reCAPTCHA site key is fetched from `GET /api/inquiry` at runtime, so no value is baked
into the image and the build takes no build args.

`traefik-public` only: the app uses neither MySQL nor Redis (no database client in
`package.json`; rate limiting and duplicate suppression are in-process `Map`s). No
storage mount: nothing writes to disk. It needs **outbound SMTP to smtp.gmail.com:465**
(nodemailer `service: 'gmail'`) and HTTPS to `www.google.com` when reCAPTCHA is on.

## Required .env

```
GMAIL_USER=<gmail address that sends the letters>
GMAIL_APP_PASSWORD=<16-char Google app password; spaces are stripped>
INQUIRY_TO=<the single address that receives every letter>
SITE_ORIGIN=https://sajt-za-dvoje.phnx-solution.com
# Optional: reCAPTCHA v3. Leave both empty to run without it.
RECAPTCHA_SITE_KEY=
RECAPTCHA_SECRET_KEY=
RECAPTCHA_MIN_SCORE=0.5
```

All read from `process.env` per request, so a change needs `docker compose up -d`
(recreate), not a rebuild. `NODE_ENV` comes from compose.

Traps:

- **A missing or invalid Gmail value doesn't fail the boot.** The container starts
  healthy and the form returns 503 ("Slanje pisama trenutno ne radi"). The values must
  also look like email addresses, or they count as missing.
- **reCAPTCHA needs both keys.** One of the two set means reCAPTCHA is off, silently.
- SMTP failures **are** logged (`[inquiry] send failed: <reason>`) and return 502.
  Prove delivery with a real submission after the first deploy.
- `SITE_ORIGIN` is one of the accepted `Origin` values and the base URL for the logo in
  the email. The request's own `Host` is also accepted, so a wrong value doesn't break
  the form behind Traefik. It only breaks the email logo.

## First boot

```bash
# Chown by number: the image runs as `node` = uid 1000; deploy is 1001.
# storage/ is empty and unmounted, and exists only because backup preflight requires it.
mkdir -p /opt/volumes/apps/endlessly-landing/{storage,logs}
sudo chown -R 1000:1000 /opt/volumes/apps/endlessly-landing
```

DNS: proxied A record for `sajt-za-dvoje` in the `phnx-solution.com` zone, added after
the container is up. A single label under the zone, so it rides the default origin
cert.

## Backups

Included, with `database: null` and owner `[1000, 1000]` (the `node` user, checked with
`id` inside the image). There's no database and nothing persistent in storage, so the
archive's value is the app configuration (`.env` with the Gmail app password).

- Template: `backups/config.example.json` registers `endlessly-landing`.
- VPS: `"endlessly-landing": {"database": null, "owner": [1000, 1000]}` to be merged
  into `/etc/infrastructure-backup/config.json`: **pending**.
- Preflight: **pending**. `sudo /opt/infrastructure/backups/backup.sh check`.
- First uploaded run: **pending**. Confirm with
  `sudo /opt/infrastructure/backups/backup.sh list --source drive --app endlessly-landing`.

## Quirks

- **Wrong logs ownership hides all output, including errors.** The entrypoint pipes
  stdout through `awk` into `/app/logs/app-YYYY-MM-DD.log`. If `awk` can't open the
  file, it dies and everything after is lost: no daily file, nothing in `docker logs`.
  The server stays healthy and serves pages, so nothing alerts. The only trace is
  `awk: can't open '/app/logs/app-…log': Permission denied` at the top of
  `docker logs`. Verified locally with the dir owned by 1001: a failed send left no
  line anywhere, while with 1000 it logged `[inquiry] send failed`. Fix the ownership,
  then restart the container.
- **Rate limit keys on `CF-Connecting-IP`.** Behind Traefik the socket peer is always
  Traefik, so the per-IP limit (5/min) would otherwise be shared by every visitor. The
  header is trusted only because the origin accepts Cloudflare traffic alone
  (`DOCKER-USER` ipset). Verified locally: visitor A's 6th attempt → 429, visitor B
  → accepted.
- **Google Fonts are downloaded at build time** (`@nuxt/fonts`) and self-hosted from
  `/_fonts`. The build needs network access, which CI has. The page makes no runtime
  request to Google for fonts.
- No build tools in the image: sharp, tailwind oxide, lightningcss and rollup all
  resolve linux-musl prebuilts from `package-lock.json`. Built for arm64 and amd64.
- Memory: ~29 MiB after 400 page and 100 API requests; limit 128M.
