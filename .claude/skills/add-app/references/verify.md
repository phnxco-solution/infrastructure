# Phase 4 — Verify

Mandatory before committing. A green build is not verification: in the worked example
`build-and-push` succeeded in CI while SSR rendered the wrong language, every page title
said "Laravel", and every signed email link 403'd.

Report what was **observed**. "Should work" is not a result.

## Contents

- [1. Build every target](#1-build-every-target)
- [2. Inspect the image](#2-inspect-the-image)
- [3. Run the stack](#3-run-the-stack)
- [4. Probe](#4-probe)
- [5. Prove the failure modes](#5-prove-the-failure-modes)
- [6. Don't break their checks](#6-dont-break-their-checks)
- [Clean up](#clean-up)

## 1. Build every target

```bash
for t in production nginx ssr; do
  DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile --target "$t" -t "verify-$t" .
done
```

Failures here are usually the frontend stage — see `references/laravel.md`.

## 2. Inspect the image

Confirm the build did what was claimed, rather than trusting exit 0:

```bash
docker run --rm verify-production sh -c '
  ls resources/js/routes resources/js/actions   # wayfinder actually generated?
  ls public/build/manifest.json                 # assets present?
  ls public/hot 2>&1                            # MUST be "No such file"
  ls bootstrap/ssr/app.js                       # SSR bundle, if SSR
  node -v; php -v | head -1                     # versions pinned as intended
'
```

## 3. Run the stack

Write a throwaway compose in the scratchpad — app + nginx + ssr, **sqlite**, so no MySQL
is needed. Give services the same **network aliases as production** (`<app>-fpm`,
`<app>-ssr`); the aliases are what's being tested.

```yaml
name: verify
services:
  app:
    image: verify-production
    environment:
      CONTAINER_ROLE: app
      APP_ENV: production
      APP_KEY: base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
      APP_URL: http://localhost:8088
      APP_LOCALE: sr                # the app's real default
      DB_CONNECTION: sqlite
      DB_DATABASE: /var/www/html/database/database.sqlite
      SESSION_DRIVER: file
      CACHE_STORE: file
      QUEUE_CONNECTION: sync
      INERTIA_SSR_URL: http://<app>-ssr:13714
    networks:
      default:
        aliases: [<app>-fpm]
    healthcheck:
      test: ["CMD-SHELL", "SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000 | grep -q pong"]
      interval: 5s
      start_period: 10s
  nginx:
    image: verify-nginx
    ports: ["8088:80"]
    depends_on: { app: { condition: service_healthy } }
  ssr:
    image: verify-ssr
    networks:
      default:
        aliases: [<app>-ssr]
networks: { default: }
```

```bash
docker compose -f verify.yml up -d --wait --wait-timeout 90
docker compose -f verify.yml exec -T app sh -c \
  'touch database/database.sqlite && php artisan migrate --force'
curl -s -o home.html -w "HTTP %{http_code} | %{size_download} bytes\n" http://localhost:8088/
```

## 4. Probe

**Is it actually server-rendered?** Strip `<script>` and count real text nodes. CSR
returns the `data-page` payload and an empty app root; SSR returns rendered markup:

```python
body = html.split('<body', 1)[1]
inner = re.sub(r'<script.*?</script>', '', body, flags=re.S)
text = [t.strip() for t in re.findall(r'>([^<>]{3,45})<', inner) if t.strip()]
# >5 nodes => SSR active. 0 => CSR fallback.
```

Check the `<title>` and `<html lang>` in the same response — that's where a baked-in
`VITE_APP_NAME` and the SSR locale bug both show up.

**Proxy behaviour** (every Laravel app): run `scripts/probe-proxy.php` in the app image.
It must report the forwarded client IP, `isSecure: true`, and `hasValidSignature: true`.

```bash
docker run --rm -e APP_KEY=base64:AAAA... -e APP_URL=https://<domain> \
  -v "$PWD/probe-proxy.php:/tmp/probe.php:ro" verify-production php /tmp/probe.php
```

**Config resolution** — prove each env var you introduced actually lands:

```bash
docker run --rm -e INERTIA_SSR_URL=http://x-ssr:13714 verify-production \
  php artisan tinker --execute="dump(config('inertia.ssr'), (new Inertia\Ssr\BundleDetector)->detect());"
```

> Rebuild before probing. A stale image is the likeliest cause of a confusing result —
> if a config change appears not to have taken, check that first.

## 5. Prove the failure modes

Claims made in a compose comment or a summary must be tested, not assumed:

```bash
docker compose -f verify.yml stop ssr
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8088/   # must be 200 (CSR fallback)
docker compose -f verify.yml start ssr                            # and recovers
```

## 6. Don't break their checks

App-code edits are sometimes unavoidable (trustProxies, SSR locale, env-driven config).
Any edit means running the app's own gates before committing:

```bash
npx vue-tsc --noEmit && npx eslint <changed files> && php artisan test
```

Run these against the tree as it stands at commit time — the user may have committed
work mid-session.

## Clean up

```bash
docker compose -f verify.yml down -v
docker rmi -f verify-production verify-nginx verify-ssr
```

Leave the user's working tree as found. Build artifacts produced by a verification run
(`bootstrap/ssr/`, `public/build/`) are gitignored and harmless — mention them, don't
`rm -rf` them.
